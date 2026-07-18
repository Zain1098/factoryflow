import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../core/database/database_service.dart';
import '../../core/models/app_user.dart';
import '../../core/constants/user_roles.dart';
import '../../core/network/sync_service.dart';
import '../../core/providers/master_data_providers.dart';

// ─── Supabase connected flag (overridden in main.dart) ────────────────────────

final supabaseConnectedProvider = Provider<bool>((ref) => false);

// ─── Constants ────────────────────────────────────────────────────────────────

const _kSessionKey = 'ff_local_session';
const _kSessionCreatedKey = 'ff_session_created';
const _kSessionProviderKey = 'ff_auth_provider';
const _kSessionMaxAge = Duration(days: 14);

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

// ─── Google Sign-In ───────────────────────────────────────────────────────────

final googleSignInProvider = Provider<GoogleSignIn>((ref) {
  return GoogleSignIn.instance;
});

Future<void> initGoogleSignIn() async {
  await GoogleSignIn.instance.initialize();
}

// ─── Local session storage ────────────────────────────────────────────────────

Future<void> _saveLocalSession(AppUser user) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kSessionKey, jsonEncode(user.toJson()));
  await prefs.setString(_kSessionCreatedKey, DateTime.now().toIso8601String());
  await prefs.setString(_kSessionProviderKey, user.authProvider);
}

Future<AppUser?> _loadLocalSession() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kSessionKey);
    if (raw == null) return null;

    final createdStr = prefs.getString(_kSessionCreatedKey);
    if (createdStr != null) {
      final created = DateTime.tryParse(createdStr);
      if (created != null &&
          DateTime.now().difference(created) > _kSessionMaxAge) {
        await _clearLocalSession();
        return null;
      }
    }

    var user = AppUser.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    if (createdStr != null) {
      final created = DateTime.tryParse(createdStr);
      if (created != null) user = user.copyWith(sessionCreatedAt: created);
    }
    return user;
  } catch (_) {
    return null;
  }
}

Future<void> _clearLocalSession() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_kSessionKey);
  await prefs.remove(_kSessionCreatedKey);
  await prefs.remove(_kSessionProviderKey);
}

// ─── Auth Repository ──────────────────────────────────────────────────────────

class AuthRepository {
  AuthRepository(this._client, this._googleSignIn);
  final SupabaseClient? _client;
  final GoogleSignIn _googleSignIn;

  User? get currentAuthUser => _client?.auth.currentUser;

  /// Email/password sign-in.
  Future<AppUser?> signIn({
    required String email,
    required String password,
  }) async {
    final client = _client;
    if (client == null) {
      throw Exception('Server not configured. Use offline login or contact admin.');
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
      await _saveLocalSession(user.copyWith(authProvider: 'email'));
    }
    return user;
  }

  /// Google Sign-In.
  /// Web: uses Supabase OAuth redirect (google_sign_in doesn't support web).
  /// Mobile: uses google_sign_in package + signInWithIdToken.
  Future<AppUser?> signInWithGoogle() async {
    final client = _client;
    if (client == null) throw Exception('Server not configured.');

    if (kIsWeb) {
      // Triggers browser redirect — Supabase handles the OAuth callback.
      // The auth state stream will fire on return; caller gets null here.
      await client.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: Uri.base.origin,
      );
      return null;
    }

    // Mobile path
    try {
      final googleUser = await _googleSignIn.authenticate();
      final googleAuth = googleUser.authentication;
      if (googleAuth.idToken == null) throw Exception('No Google ID token');

      final supabaseResponse = await client.auth.signInWithIdToken(
        provider: OAuthProvider.google,
        idToken: googleAuth.idToken!,
      );
      final userId = supabaseResponse.user?.id;
      if (userId == null) throw Exception('No user from Google auth');

      final result = await client.rpc('handle_google_auth_user', params: {
        'p_user_id': userId,
        'p_email': googleUser.email,
        'p_name': googleUser.displayName ?? googleUser.email.split('@').first,
        'p_avatar_url': googleUser.photoUrl ?? '',
        'p_workspace_name': 'My Workspace',
      });

      final workspaceId = result['workspace_id'] as String;
      final isNew = result['is_new'] as bool? ?? false;
      if (isNew) {
        final db = DatabaseService.instance;
        await db.upsertWorkspace(
          id: workspaceId,
          name: 'My Workspace',
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
      }

      final appUser = await _fetchAppUser(client, userId);
      if (appUser != null) {
        await _saveLocalSession(appUser.copyWith(
          authProvider: 'google',
          avatarUrl: googleUser.photoUrl ?? appUser.avatarUrl,
        ));
      }
      return appUser;
    } on Exception {
      rethrow;
    }
  }

  /// Returns cached local session — no network needed.
  Future<AppUser?> getLocalSession() => _loadLocalSession();

  /// Try to refresh from Supabase; fall back to local session silently.
  Future<AppUser?> getCurrentAppUser() async {
    final local = await _loadLocalSession();
    final client = _client;
    if (client != null && client.auth.currentUser != null) {
      _fetchAppUser(client, client.auth.currentUser!.id).then((remote) {
        if (remote != null) {
          _saveLocalSession(
            remote.copyWith(sessionCreatedAt: local?.sessionCreatedAt),
          );
        }
      }).catchError((_) {});
    }
    return local;
  }

  /// Sign up: creates auth user, immediately signs in to get a valid JWT,
  /// then calls the RPC (which needs auth.uid() to be set).
  Future<AppUser> signUp({
    required String email,
    required String password,
    required String profileName,
    required String workspaceName,
    required DatabaseService db,
  }) async {
    final client = _client;
    if (client == null) throw Exception('Server not configured.');

    // Step 1: Create auth user
    AuthResponse response;
    try {
      response = await client.auth.signUp(email: email, password: password);
    } on AuthException catch (e) {
      throw Exception('Sign-up failed: ${e.message}');
    }
    final userId = response.user?.id;
    if (userId == null) {
      throw Exception('Sign-up failed: email may already be registered.');
    }

    // Step 2: Sign in immediately so auth.uid() is valid for the RPC.
    // signUp alone does not always establish an active JWT session.
    try {
      await client.auth.signInWithPassword(email: email, password: password);
    } on AuthException catch (e) {
      throw Exception('Auto sign-in after signup failed: ${e.message}');
    }

    // Step 3: Call RPC — auth.uid() is now valid
    Map result;
    try {
      result = await client.rpc('create_user_workspace', params: {
        'p_profile_name': profileName,
        'p_workspace_name': workspaceName,
      });
    } catch (e) {
      throw Exception('Workspace setup failed: $e');
    }

    final workspaceIdStr = result['workspace_id'] as String;

    // Step 4: Persist locally
    await db.upsertWorkspace(
      id: workspaceIdStr,
      name: workspaceName,
      ownerUserId: userId,
      syncStatus: 'synced',
    );
    await db.upsertWorkspaceMember(
      id: const Uuid().v4(),
      workspaceId: workspaceIdStr,
      userId: userId,
      role: 'owner',
      syncStatus: 'synced',
    );
    await db.setActiveWorkspaceId(workspaceIdStr);

    final user = AppUser(
      id: userId,
      factoryId: workspaceIdStr,
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

  Future<String> generateOtp({
    required String userId,
    required String purpose,
    required String newValue,
  }) async {
    final client = _client;
    if (client == null) throw Exception('Server not configured.');
    final result = await client.rpc('generate_otp', params: {
      'p_user_id': userId,
      'p_purpose': purpose,
      'p_new_value': newValue,
    });
    return result as String;
  }

  Future<Map<String, dynamic>> verifyOtp({
    required String userId,
    required String code,
    required String purpose,
  }) async {
    final client = _client;
    if (client == null) throw Exception('Server not configured.');
    final result = await client.rpc('verify_otp', params: {
      'p_user_id': userId,
      'p_code': code,
      'p_purpose': purpose,
    });
    return result as Map<String, dynamic>;
  }

  Future<void> updateProfile({
    required String userId,
    String? name,
    String? avatarUrl,
  }) async {
    final client = _client;
    if (client == null) throw Exception('Server not configured.');
    await client.rpc('update_user_profile', params: {
      'p_user_id': userId,
      'p_name': name,
      'p_avatar_url': avatarUrl,
    });
  }

  Future<void> updateAuthEmail({
    required String userId,
    required String newEmail,
  }) async {
    final client = _client;
    if (client == null) throw Exception('Server not configured.');
    await client.rpc('update_user_email_after_otp', params: {
      'p_user_id': userId,
      'p_new_email': newEmail,
    });
  }

  Future<void> changePassword(String newPassword) async {
    final client = _client;
    if (client == null) throw Exception('Server not configured.');
    await client.auth.updateUser(UserAttributes(password: newPassword));
  }

  Future<String?> uploadAvatar({
    required String userId,
    required String filePath,
  }) async {
    final client = _client;
    if (client == null) return null;
    try {
      final file = io.File(filePath);
      final bytes = await file.readAsBytes();
      final ext = filePath.split('.').last;
      final storagePath = 'avatars/$userId.$ext';
      await client.storage.from('avatars').uploadBinary(
        storagePath,
        bytes,
        fileOptions: const FileOptions(upsert: true),
      );
      return client.storage.from('avatars').getPublicUrl(storagePath);
    } catch (_) {
      return null;
    }
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
    await _googleSignIn.signOut();
  }
}

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return AuthRepository(
    ref.watch(supabaseClientProvider),
    ref.watch(googleSignInProvider),
  );
});

// ─── CurrentUserNotifier ──────────────────────────────────────────────────────

class CurrentUserNotifier extends AsyncNotifier<AppUser?> {
  @override
  Future<AppUser?> build() async {
    final user = await ref.read(authRepositoryProvider).getLocalSession();
    if (user != null) _onSessionRestored();
    return user;
  }

  Future<void> signIn(String email, String password) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final user = await ref
          .read(authRepositoryProvider)
          .signIn(email: email, password: password);
      if (user != null) {
        await ref
            .read(databaseServiceProvider)
            .setActiveWorkspaceId(user.factoryId);
        _onLoginSuccess();
      }
      return user;
    });
  }

  Future<void> signInWithGoogle() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final user = await ref.read(authRepositoryProvider).signInWithGoogle();
      if (user != null) {
        await ref
            .read(databaseServiceProvider)
            .setActiveWorkspaceId(user.factoryId);
        _onLoginSuccess();
      }
      return user;
    });
  }

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

  Future<void> continueOffline() async {
    final user = await ref.read(authRepositoryProvider).getLocalSession();
    if (user != null) {
      state = AsyncData(user);
      _onSessionRestored();
    }
  }

  void _onLoginSuccess() {
    ref.read(syncServiceProvider).startPeriodicSync();
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

  Future<void> refreshUser(AppUser updatedUser) async {
    final merged = updatedUser.copyWith(
      sessionCreatedAt: state.value?.sessionCreatedAt,
    );
    await _saveLocalSession(merged);
    state = AsyncData(merged);
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

// ─── Account Settings Notifier ────────────────────────────────────────────────

class AccountSettingsNotifier extends AsyncNotifier<void> {
  @override
  Future<void> build() => Future.value();

  Future<String?> updateName(String newName) async {
    final user = ref.read(currentUserProvider).value;
    if (user == null) return 'Not logged in';
    try {
      await ref
          .read(authRepositoryProvider)
          .updateProfile(userId: user.id, name: newName);
      await ref
          .read(currentUserProvider.notifier)
          .refreshUser(user.copyWith(name: newName));
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<String?> uploadAndUpdateAvatar(String filePath) async {
    final user = ref.read(currentUserProvider).value;
    if (user == null) return 'Not logged in';
    try {
      final url = await ref
          .read(authRepositoryProvider)
          .uploadAvatar(userId: user.id, filePath: filePath);
      if (url == null) return 'Failed to upload image';
      await ref
          .read(authRepositoryProvider)
          .updateProfile(userId: user.id, avatarUrl: url);
      await ref
          .read(currentUserProvider.notifier)
          .refreshUser(user.copyWith(avatarUrl: url));
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<String?> sendEmailChangeOtp(String newEmail) async {
    final user = ref.read(currentUserProvider).value;
    if (user == null) return 'Not logged in';
    try {
      await ref.read(authRepositoryProvider).generateOtp(
            userId: user.id,
            purpose: 'email_change',
            newValue: newEmail,
          );
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<String?> verifyEmailChangeOtp(String code, String newEmail) async {
    final user = ref.read(currentUserProvider).value;
    if (user == null) return 'Not logged in';
    try {
      final result = await ref.read(authRepositoryProvider).verifyOtp(
            userId: user.id,
            code: code,
            purpose: 'email_change',
          );
      if (result['success'] != true) {
        return result['error'] as String? ?? 'OTP verification failed';
      }
      await ref
          .read(authRepositoryProvider)
          .updateAuthEmail(userId: user.id, newEmail: newEmail);
      await ref
          .read(currentUserProvider.notifier)
          .refreshUser(user.copyWith(email: newEmail));
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<String?> sendPasswordChangeOtp(String newPassword) async {
    final user = ref.read(currentUserProvider).value;
    if (user == null) return 'Not logged in';
    try {
      await ref.read(authRepositoryProvider).generateOtp(
            userId: user.id,
            purpose: 'password_change',
            newValue: newPassword,
          );
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<String?> verifyPasswordChangeOtp(
      String code, String newPassword) async {
    final user = ref.read(currentUserProvider).value;
    if (user == null) return 'Not logged in';
    try {
      final result = await ref.read(authRepositoryProvider).verifyOtp(
            userId: user.id,
            code: code,
            purpose: 'password_change',
          );
      if (result['success'] != true) {
        return result['error'] as String? ?? 'OTP verification failed';
      }
      await ref.read(authRepositoryProvider).changePassword(newPassword);
      return null;
    } catch (e) {
      return e.toString();
    }
  }
}

final accountSettingsProvider =
    AsyncNotifierProvider<AccountSettingsNotifier, void>(
  AccountSettingsNotifier.new,
);
