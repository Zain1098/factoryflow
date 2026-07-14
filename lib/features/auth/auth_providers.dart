import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../core/database/database_service.dart';
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
    if (user != null && !user.active) {
      await client.auth.signOut();
      await _clearLocalSession();
      throw Exception('This account is no longer active.');
    }
    if (user != null) {
      await _saveLocalSession(user);
    }
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

  /// Sign up: creates Supabase auth user, calls RPC to create workspace+profile.
  Future<AppUser> signUp({
    required String email,
    required String password,
    required String profileName,
    required String workspaceName,
    required DatabaseService db,
  }) async {
    final client = _client;
    if (client == null) throw Exception('Server not configured.');

    await client.auth.signUp(email: email, password: password);

    // RPC creates factories + users + workspace_members rows
    final result = await client.rpc('create_user_workspace', params: {
      'p_profile_name': profileName,
      'p_workspace_name': workspaceName,
    }) as Map<String, dynamic>;

    final workspaceId = result['workspace_id'] as String;
    final userId = result['user_id'] as String;

    // Persist workspace locally
    await db.upsertWorkspace(
      id: workspaceId,
      name: workspaceName,
      ownerUserId: userId,
      syncStatus: 'synced',
    );
    await db.upsertWorkspaceMember(
      id: const Uuid().v4(),
      workspaceId: workspaceId,
      userId: userId,
      role: 'owner',
      syncStatus: 'synced',
    );
    await db.setActiveWorkspaceId(workspaceId);

    final user = AppUser(
      id: userId,
      factoryId: workspaceId,
      name: profileName,
      email: email,
      role: UserRole.owner,
    );
    await _saveLocalSession(user);
    return user;
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
      if (user != null) {
        // Ensure activeWorkspaceId is set on every login (new device support)
        await ref.read(databaseServiceProvider).setActiveWorkspaceId(user.factoryId);
        _onLoginSuccess();
      }
      return user;
    });
  }

  /// Sign up new user + create workspace.
  Future<void> signUp({
    required String email,
    required String password,
    required String profileName,
    required String workspaceName,
  }) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final user = await ref.read(authRepositoryProvider).signUp(
            email: email,
            password: password,
            profileName: profileName,
            workspaceName: workspaceName,
            db: ref.read(databaseServiceProvider),
          );
      _onLoginSuccess();
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
    // Sync master data only if online — don't block or fail offline users
    _syncMasterDataIfOnline();
  }

  void _onSessionRestored() {
    ref.read(syncServiceProvider).startPeriodicSync();
    _syncMasterDataIfOnline();
  }

  void _syncMasterDataIfOnline() {
    ref.read(syncServiceProvider).isOnline().then((online) {
      if (online) {
        ref.read(masterDataRepositoryProvider).syncMasterDataFromSupabase();
      }
    }).catchError((_) {});
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
