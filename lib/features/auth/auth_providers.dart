import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/models/app_user.dart';
import '../../core/constants/user_roles.dart';
import '../../core/network/sync_service.dart';
import '../../core/providers/master_data_providers.dart';

// ─── Supabase guard ───────────────────────────────────────────────────────────

bool get _supabaseReady {
  try {
    Supabase.instance.client;
    return true;
  } catch (_) {
    return false;
  }
}

final supabaseClientProvider = Provider<SupabaseClient?>((ref) {
  if (!_supabaseReady) return null;
  return Supabase.instance.client;
});

final authStateProvider = StreamProvider<AuthState>((ref) {
  if (!_supabaseReady) return const Stream.empty();
  return Supabase.instance.client.auth.onAuthStateChange;
});

// ─── Local session storage ────────────────────────────────────────────────────

const _kSessionKey = 'ff_local_session';

Future<void> _saveLocalSession(AppUser user) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kSessionKey, jsonEncode(user.toJson()));
}

Future<AppUser?> _loadLocalSession() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kSessionKey);
    if (raw == null) return null;
    return AppUser.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  } catch (_) {
    return null;
  }
}

Future<void> _clearLocalSession() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_kSessionKey);
}

// ─── Auth Repository ──────────────────────────────────────────────────────────

class AuthRepository {
  AuthRepository(this._client);
  final SupabaseClient? _client;

  User? get currentAuthUser => _client?.auth.currentUser;

  /// Online login — saves session locally on success.
  Future<AppUser?> signIn({
    required String email,
    required String password,
  }) async {
    final client = _client;
    if (client == null) {
      throw Exception(
        'Server not configured. Use offline login or contact admin.',
      );
    }
    final response = await client.auth.signInWithPassword(
      email: email,
      password: password,
    );
    final userId = response.user?.id;
    if (userId == null) return null;
    final user = await _fetchAppUser(client, userId);
    if (user != null) await _saveLocalSession(user);
    return user;
  }

  /// Returns cached local session — no network needed.
  Future<AppUser?> getLocalSession() => _loadLocalSession();

  /// Try to refresh from Supabase; fall back to local session silently.
  Future<AppUser?> getCurrentAppUser() async {
    // Always try local first — instant, no network
    final local = await _loadLocalSession();

    // If Supabase is ready and we have a live auth session, refresh in bg
    final client = _client;
    if (client != null && client.auth.currentUser != null) {
      _fetchAppUser(client, client.auth.currentUser!.id).then((remote) {
        if (remote != null) _saveLocalSession(remote);
      }).catchError((_) {});
    }

    return local;
  }

  Future<void> sendPasswordResetEmail(String email) async {
    final client = _client;
    if (client == null) throw Exception('Server not configured.');
    await client.auth.resetPasswordForEmail(email);
  }

  Future<AppUser?> _fetchAppUser(SupabaseClient client, String userId) async {
    final data =
        await client.from('users').select().eq('id', userId).maybeSingle();
    if (data == null) return null;
    return AppUser.fromJson(data);
  }

  Future<void> signOut() async {
    await _clearLocalSession();
    try {
      await _client?.auth.signOut();
    } catch (_) {}
  }
}

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return AuthRepository(ref.watch(supabaseClientProvider));
});

// ─── CurrentUserNotifier ──────────────────────────────────────────────────────

class CurrentUserNotifier extends AsyncNotifier<AppUser?> {
  @override
  Future<AppUser?> build() async {
    // Load local session instantly — no network call
    final user = await ref.read(authRepositoryProvider).getLocalSession();
    if (user != null) _onSessionRestored();
    return user;
  }

  /// Full online sign-in.
  Future<void> signIn(String email, String password) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final user = await ref
          .read(authRepositoryProvider)
          .signIn(email: email, password: password);
      if (user != null) _onLoginSuccess();
      return user;
    });
  }

  /// Use existing local session without network.
  Future<void> continueOffline() async {
    final user = await ref.read(authRepositoryProvider).getLocalSession();
    if (user != null) {
      state = AsyncData(user);
      _onSessionRestored();
    }
  }

  void _onLoginSuccess() {
    ref.read(syncServiceProvider).startPeriodicSync();
    ref.read(masterDataRepositoryProvider).syncMasterDataFromSupabase();
  }

  void _onSessionRestored() {
    // Start sync in background — won't block UI
    ref.read(syncServiceProvider).startPeriodicSync();
  }

  /// Dev-only bypass — debug builds only.
  void devLogin() {
    if (!kDebugMode) return;
    const user = AppUser(
      id: 'dev-admin-001',
      factoryId: '00000000-0000-0000-0000-000000000001',
      name: 'Dev Admin',
      email: 'admin@factoryflow.dev',
      role: UserRole.admin,
    );
    _saveLocalSession(user);
    state = const AsyncData(user);
    _onLoginSuccess();
  }

  Future<void> signOut() async {
    ref.read(syncServiceProvider).stopPeriodicSync();
    await ref.read(authRepositoryProvider).signOut();
    state = const AsyncData(null);
  }

  Future<void> refresh() async {
    state = await AsyncValue.guard(
      () => ref.read(authRepositoryProvider).getCurrentAppUser(),
    );
  }
}

final currentUserProvider =
    AsyncNotifierProvider<CurrentUserNotifier, AppUser?>(
  CurrentUserNotifier.new,
);

final userRoleProvider = Provider<UserRole?>((ref) {
  return ref.watch(currentUserProvider).value?.role;
});
