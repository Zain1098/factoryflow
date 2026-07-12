import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/models/app_user.dart';
import '../../core/constants/user_roles.dart';

// ---------------------------------------------------------------------------
// Safe Supabase access — guard against "not initialized" crash
// ---------------------------------------------------------------------------

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

/// Auth state stream — empty stream when Supabase is not configured
final authStateProvider = StreamProvider<AuthState>((ref) {
  if (!_supabaseReady) return const Stream.empty();
  return Supabase.instance.client.auth.onAuthStateChange;
});

// ---------------------------------------------------------------------------
// Auth Repository
// ---------------------------------------------------------------------------

class AuthRepository {
  AuthRepository(this._client);

  final SupabaseClient? _client;

  User? get currentAuthUser => _client?.auth.currentUser;

  Future<AppUser?> signIn({
    required String email,
    required String password,
  }) async {
    final client = _client;
    if (client == null) throw Exception('Supabase is not configured. Check your .env file.');

    final response = await client.auth.signInWithPassword(
      email: email,
      password: password,
    );
    final userId = response.user?.id;
    if (userId == null) return null;
    return _fetchAppUser(client, userId);
  }

  Future<AppUser?> getCurrentAppUser() async {
    final client = _client;
    if (client == null) return null;
    final userId = client.auth.currentUser?.id;
    if (userId == null) return null;
    return _fetchAppUser(client, userId);
  }

  Future<void> sendPasswordResetEmail(String email) async {
    final client = _client;
    if (client == null) throw Exception('Supabase is not configured.');
    await client.auth.resetPasswordForEmail(email);
  }

  Future<AppUser?> _fetchAppUser(SupabaseClient client, String userId) async {
    final data = await client
        .from('users')
        .select()
        .eq('id', userId)
        .maybeSingle();
    if (data == null) return null;
    return AppUser.fromJson(data);
  }

  Future<void> signOut() async {
    await _client?.auth.signOut();
  }
}

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return AuthRepository(ref.watch(supabaseClientProvider));
});

// ---------------------------------------------------------------------------
// CurrentUserNotifier
// ---------------------------------------------------------------------------

class CurrentUserNotifier extends AsyncNotifier<AppUser?> {
  @override
  Future<AppUser?> build() async {
    final repo = ref.read(authRepositoryProvider);
    return repo.getCurrentAppUser();
  }

  Future<void> signIn(String email, String password) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final repo = ref.read(authRepositoryProvider);
      return repo.signIn(email: email, password: password);
    });
  }

  /// Dev-only bypass — only available in debug builds
  void devLogin() {
    assert(() {
      state = const AsyncData(AppUser(
        id: 'dev-admin-001',
        factoryId: '00000000-0000-0000-0000-000000000001',
        name: 'Dev Admin',
        email: 'admin@factoryflow.dev',
        role: UserRole.admin,
      ));
      return true;
    }(), 'devLogin is only available in debug mode');

    // Fallback for release builds where assert is a no-op (never reached)
    if (kDebugMode) {
      state = const AsyncData(AppUser(
        id: 'dev-admin-001',
        factoryId: '00000000-0000-0000-0000-000000000001',
        name: 'Dev Admin',
        email: 'admin@factoryflow.dev',
        role: UserRole.admin,
      ));
    }
  }

  Future<void> signOut() async {
    await ref.read(authRepositoryProvider).signOut();
    state = const AsyncData(null);
  }

  Future<void> refresh() async {
    state = await AsyncValue.guard(() async {
      return ref.read(authRepositoryProvider).getCurrentAppUser();
    });
  }
}

final currentUserProvider = AsyncNotifierProvider<CurrentUserNotifier, AppUser?>(
  CurrentUserNotifier.new,
);

final userRoleProvider = Provider<UserRole?>((ref) {
  return ref.watch(currentUserProvider).value?.role;
});
