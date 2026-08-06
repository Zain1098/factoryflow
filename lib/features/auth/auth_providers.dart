import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
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
const _kPendingSignupKey = 'ff_pending_signup';
const _kSessionMaxAge = Duration(days: 14);

String _safeAuthMessage(Object error, {required String fallback}) {
  final message = error.toString().toLowerCase();
  if (message.contains('otp_expired') ||
      message.contains('token has expired') ||
      message.contains('invalid or expired')) {
    return 'This code has expired or was already used. Request a new code and enter the newest one.';
  }
  if (message.contains('nonce') || message.contains('reauthentication')) {
    return 'The security code is invalid or expired. Request a new code and try again.';
  }
  if (message.contains('rate_limit') ||
      message.contains('over_email_send_rate_limit') ||
      message.contains('429')) {
    return 'Too many email requests. Please wait a few minutes before trying again.';
  }
  return fallback;
}

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

final passwordRecoveryPendingProvider =
    NotifierProvider<_BoolNotifier, bool>(_BoolNotifier.new);

class _BoolNotifier extends Notifier<bool> {
  @override
  bool build() => false;
  void setPending(bool value) => state = value;
}

// ─── Google Sign-In ───────────────────────────────────────────────────────────

final googleSignInProvider = Provider<GoogleSignIn>((ref) {
  return GoogleSignIn.instance;
});

Future<void> initGoogleSignIn() async {
  await GoogleSignIn.instance.initialize(
    serverClientId:
        '758654945175-doo66mvopc0atuppnuak914s2lsg392u.apps.googleusercontent.com',
  );
}

// ─── Secure local session storage ────────────────────────────────────────────

const _secureStorage = FlutterSecureStorage();

Future<void> _saveLocalSession(AppUser user) async {
  await _secureStorage.write(
    key: _kSessionKey,
    value: jsonEncode(user.toJson()),
  );
  await _secureStorage.write(
    key: _kSessionCreatedKey,
    value: DateTime.now().toIso8601String(),
  );
  await _secureStorage.write(
    key: _kSessionProviderKey,
    value: user.authProvider,
  );
}

Future<AppUser?> _loadLocalSession() async {
  try {
    final raw = await _secureStorage.read(key: _kSessionKey);
    if (raw == null) return null;

    final createdStr = await _secureStorage.read(key: _kSessionCreatedKey);
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
  await _secureStorage.deleteAll();
}

Future<void> _savePendingSignup({
  required String email,
  required String profileName,
  required String workspaceName,
}) async {
  await _secureStorage.write(
    key: _kPendingSignupKey,
    value: jsonEncode({
      'email': email.trim().toLowerCase(),
      'profile_name': profileName.trim(),
      'workspace_name': workspaceName.trim(),
    }),
  );
}

Future<Map<String, String>?> _loadPendingSignup(String? email) async {
  try {
    final raw = await _secureStorage.read(key: _kPendingSignupKey);
    if (raw == null || email == null) return null;
    final data = jsonDecode(raw) as Map<String, dynamic>;
    if (data['email'] != email.trim().toLowerCase()) return null;
    return {
      'profile_name': data['profile_name'] as String? ?? '',
      'workspace_name': data['workspace_name'] as String? ?? '',
    };
  } catch (_) {
    return null;
  }
}

Future<void> _clearPendingSignup() =>
    _secureStorage.delete(key: _kPendingSignupKey);

// ─── Auth Repository ──────────────────────────────────────────────────────────

class AuthRepository {
  AuthRepository(this._client, this._googleSignIn);
  final SupabaseClient? _client;
  final GoogleSignIn _googleSignIn;

  User? get currentAuthUser => _client?.auth.currentUser;

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
    var user = await _fetchAppUser(client, userId);
    // Auth can succeed for accounts created before workspace provisioning was
    // enabled (or when provisioning was interrupted). Repair that account
    // before returning null, otherwise the login screen cannot open the app.
    user ??= await _provisionMissingAppUser(
      client,
      userId: userId,
      profileName: response.user?.userMetadata?['profile_name'] as String? ??
          response.user?.email?.split('@').first ??
          email.split('@').first,
    );
    if (user != null && !user.active) {
      await client.auth.signOut();
      await _clearLocalSession();
      throw Exception('This account is no longer active.');
    }
    if (user == null) return null;
    final signedInUser = user.copyWith(authProvider: 'email');
    await _saveLocalSession(signedInUser);
    return signedInUser;
  }

  Future<AppUser?> signInWithGoogle() async {
    final client = _client;
    if (client == null) throw Exception('Server not configured.');

    if (kIsWeb) {
      await client.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: Uri.base.origin,
      );
      return null;
    }

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

      final result = await client.rpc(
        'handle_google_auth_user',
        params: {
          'p_user_id': userId,
          'p_email': googleUser.email,
          'p_name': googleUser.displayName ?? googleUser.email.split('@').first,
          'p_avatar_url': googleUser.photoUrl ?? '',
          'p_workspace_name': 'My Workspace',
        },
      );

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
        if (!appUser.active) {
          await _clearLocalSession();
          await client.auth.signOut(scope: SignOutScope.local);
          throw Exception('This account is no longer active.');
        }
        final signedInUser = appUser.copyWith(
          authProvider: 'google',
          avatarUrl: googleUser.photoUrl ?? appUser.avatarUrl,
        );
        await _saveLocalSession(signedInUser);
        return signedInUser;
      }
      return null;
    } on Exception {
      rethrow;
    }
  }

  Future<AppUser?> getLocalSession() => _loadLocalSession();

  Future<AppUser?> getCurrentAppUser() async {
    final local = await _loadLocalSession();
    final client = _client;
    if (client != null && client.auth.currentUser != null) {
      try {
        final authUser = client.auth.currentUser!;
        var remote = await _fetchAppUser(client, authUser.id);
        final provider = authUser.appMetadata['provider'];
        if (remote == null) {
          final metadata = authUser.userMetadata ?? const <String, dynamic>{};
          if (provider == 'google') {
            await client.rpc(
              'handle_google_auth_user',
              params: {
                'p_user_id': authUser.id,
                'p_email': authUser.email ?? '',
                'p_name': metadata['full_name'] ??
                    metadata['name'] ??
                    authUser.email?.split('@').first ??
                    'User',
                'p_avatar_url':
                    metadata['avatar_url'] ?? metadata['picture'] ?? '',
                'p_workspace_name': 'My Workspace',
              },
            );
          } else {
            await _provisionMissingAppUser(
              client,
              userId: authUser.id,
              profileName: metadata['profile_name'] as String? ??
                  metadata['name'] as String? ??
                  authUser.email?.split('@').first ??
                  'User',
            );
          }
          remote = await _fetchAppUser(client, authUser.id);
        }
        if (remote != null && !remote.active) {
          await _clearLocalSession();
          try {
            await client.auth.signOut(scope: SignOutScope.local);
          } catch (_) {}
          return null;
        }
        if (remote != null) {
          final authEmail = authUser.email?.trim().toLowerCase();
          if (authEmail != null &&
              authEmail.isNotEmpty &&
              authEmail != remote.email.trim().toLowerCase()) {
            try {
              await client.rpc(
                'sync_user_email',
                params: {
                  'p_user_id': authUser.id,
                  'p_new_email': authEmail,
                },
              );
              remote = remote.copyWith(email: authEmail);
            } catch (_) {
              // Profile sync should not block a valid Auth session.
            }
          }
          final restored = remote.copyWith(
            authProvider: provider == 'google' ? 'google' : 'email',
            sessionCreatedAt: local?.sessionCreatedAt,
          );
          await _hydrateLocalWorkspace(client, restored);
          await _saveLocalSession(restored);
          return restored;
        }
      } catch (_) {}
    }
    // Never reuse a cached profile belonging to a different authenticated
    // account (common on shared factory devices after account switching).
    final remoteId = client?.auth.currentUser?.id;
    if (remoteId != null && local?.id != remoteId) return null;
    return local;
  }

  Future<void> _hydrateLocalWorkspace(
    SupabaseClient client,
    AppUser user,
  ) async {
    final factory = await client
        .from('factories')
        .select('id, name')
        .eq('id', user.factoryId)
        .maybeSingle();
    final member = await client
        .from('workspace_members')
        .select('id, role')
        .eq('workspace_id', user.factoryId)
        .eq('user_id', user.id)
        .maybeSingle();
    final db = DatabaseService.instance;
    await db.upsertWorkspace(
      id: user.factoryId,
      name: factory?['name'] as String? ?? 'My Workspace',
      ownerUserId: user.role == UserRole.owner ? user.id : '',
      syncStatus: 'synced',
    );
    await db.upsertWorkspaceMember(
      id: member?['id'] as String? ?? const Uuid().v4(),
      workspaceId: user.factoryId,
      userId: user.id,
      role: member?['role'] as String? ?? user.role.value,
      syncStatus: 'synced',
    );
    await db.setActiveWorkspaceId(user.factoryId);
  }

  Future<AppUser?> signUp({
    required String email,
    required String password,
    required String profileName,
    required String workspaceName,
    required DatabaseService db,
  }) async {
    final client = _client;
    if (client == null) throw Exception('Server not configured.');

    AuthResponse response;
    try {
      response = await client.auth.signUp(
        email: email,
        password: password,
        data: {
          'profile_name': profileName,
          'workspace_name': workspaceName,
        },
      );
    } on AuthException catch (e) {
      throw Exception('Sign-up failed: ${e.message}');
    }
    final userId = response.user?.id;
    if (userId == null) {
      throw Exception('Sign-up failed: email may already be registered.');
    }
    if (response.user?.identities?.isEmpty ?? false) {
      throw Exception(
        'This email is already registered. Please sign in or use reset password.',
      );
    }
    await _savePendingSignup(
      email: email,
      profileName: profileName,
      workspaceName: workspaceName,
    );
    if (response.session == null) return null;

    Map result;
    try {
      result = await client.rpc(
        'create_user_workspace',
        params: {
          'p_profile_name': profileName,
          'p_workspace_name': workspaceName,
        },
      );
    } catch (e) {
      throw Exception('Workspace setup failed: $e');
    }

    final workspaceIdStr = result['workspace_id'] as String;
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
    await _clearPendingSignup();

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

  Future<AppUser> verifySignUpOtp({
    required String email,
    required String token,
    required String profileName,
    required String workspaceName,
    required DatabaseService db,
  }) async {
    final client = _client;
    if (client == null) throw Exception('Server not configured.');
    final response = await client.auth.verifyOTP(
      email: email,
      token: token,
      type: OtpType.signup,
    );
    final userId = response.user?.id;
    if (userId == null || response.session == null) {
      throw Exception('Email verification did not create a valid session.');
    }

    final result = await client.rpc(
      'create_user_workspace',
      params: {
        'p_profile_name': profileName,
        'p_workspace_name': workspaceName,
      },
    );
    final workspaceId = (result as Map)['workspace_id'] as String;
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
    await _clearPendingSignup();

    final user = AppUser(
      id: userId,
      factoryId: workspaceId,
      name: profileName,
      email: response.user?.email ?? email,
      role: UserRole.owner,
    );
    await _saveLocalSession(user);
    return user;
  }

  Future<void> resendSignUpOtp(String email) async {
    final client = _client;
    if (client == null) throw Exception('Server not configured.');
    await client.auth.resend(email: email, type: OtpType.signup);
  }

  // ── Forgot password (OTP-based) ───────────────────────────────────────────

  Future<void> sendPasswordResetOtp(String email) async {
    final client = _client;
    if (client == null) throw Exception('Server not configured.');
    await client.auth.resetPasswordForEmail(email, redirectTo: null);
  }

  Future<void> verifyPasswordResetOtp({
    required String email,
    required String token,
  }) async {
    final client = _client;
    if (client == null) throw Exception('Server not configured.');
    final response = await client.auth.verifyOTP(
      email: email,
      token: token,
      type: OtpType.recovery,
    );
    final recoverySession = response.session;
    final refreshToken = recoverySession?.refreshToken;
    if (recoverySession == null ||
        refreshToken == null ||
        refreshToken.isEmpty) {
      throw Exception('Invalid or expired OTP code.');
    }
    // Ensure the recovery JWT returned by verifyOTP is the active client
    // session before the next screen calls updateUser().
    await client.auth.setSession(refreshToken);
  }

  Future<void> completePasswordReset(String newPassword) async {
    final client = _client;
    if (client == null) throw Exception('Server not configured.');
    if (client.auth.currentSession == null) {
      throw Exception('Recovery session expired. Request a new code.');
    }
    await client.auth.updateUser(UserAttributes(password: newPassword));
    // The recovery session is short-lived and must not become a persistent
    // authenticated session on a shared factory device.
    try {
      await client.auth.signOut(scope: SignOutScope.local);
    } finally {
      await _clearLocalSession();
    }
  }

  // ── Account settings — email/password change (reauthentication OTP) ──────

  /// Sends reauthentication OTP to signed-in user's current email.
  Future<void> sendReauthOtp() async {
    final client = _client;
    if (client == null) throw Exception('Server not configured.');
    await client.auth.reauthenticate();
  }

  /// Verifies reauth OTP then updates email.
  Future<String> verifyAndUpdateEmail({
    required String nonce,
    required String newEmail,
  }) async {
    final client = _client;
    if (client == null) throw Exception('Server not configured.');
    await client.auth.updateUser(
      UserAttributes(email: newEmail, nonce: nonce),
    );
    // With double confirmation enabled, public.users must not be changed
    // until Supabase Auth reports the new email as confirmed.
    return newEmail;
  }

  /// Verifies reauth OTP then updates password.
  Future<void> verifyAndUpdatePassword({
    required String nonce,
    required String newPassword,
  }) async {
    final client = _client;
    if (client == null) throw Exception('Server not configured.');
    await client.auth.updateUser(
      UserAttributes(password: newPassword, nonce: nonce),
    );
  }

  // ── Profile ───────────────────────────────────────────────────────────────

  Future<void> updateProfile({
    required String userId,
    String? name,
    String? avatarUrl,
  }) async {
    final client = _client;
    if (client == null) throw Exception('Server not configured.');
    await client.rpc(
      'update_user_profile',
      params: {
        'p_user_id': userId,
        'p_name': name,
        'p_avatar_url': avatarUrl,
      },
    );
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
      final ext = filePath.split('.').last.toLowerCase();
      final storagePath = '$userId/avatar.$ext';
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

  Future<AppUser?> _provisionMissingAppUser(
    SupabaseClient client, {
    required String userId,
    required String profileName,
  }) async {
    final pending = await _loadPendingSignup(client.auth.currentUser?.email);
    final pendingProfile = pending?['profile_name'];
    final pendingWorkspace = pending?['workspace_name'];
    final result = await client.rpc(
      'create_user_workspace',
      params: {
        'p_profile_name': (pendingProfile ?? profileName).trim().isEmpty
            ? 'User'
            : (pendingProfile ?? profileName).trim(),
        'p_workspace_name': (pendingWorkspace ?? 'My Workspace').trim().isEmpty
            ? 'My Workspace'
            : (pendingWorkspace ?? 'My Workspace').trim(),
      },
    );
    final workspaceId = (result as Map)['workspace_id'] as String?;
    if (workspaceId == null || workspaceId.isEmpty) return null;
    final user = await _fetchAppUser(client, userId);
    if (user != null) await _clearPendingSignup();
    return user;
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
    ref.listen(authStateProvider, (_, next) {
      final authState = next.value;
      if (authState == null) return;
      if (authState.event == AuthChangeEvent.signedIn ||
          authState.event == AuthChangeEvent.tokenRefreshed ||
          authState.event == AuthChangeEvent.userUpdated) {
        unawaited(refresh());
      } else if (authState.event == AuthChangeEvent.signedOut) {
        unawaited(_restoreLocalSessionAfterRemoteSignOut());
      }
    });
    final user = await ref.read(authRepositoryProvider).getCurrentAppUser();
    if (user != null) _onSessionRestored();
    return user;
  }

  Future<void> _restoreLocalSessionAfterRemoteSignOut() async {
    final local = await ref.read(authRepositoryProvider).getLocalSession();
    // A password-recovery sign-out can be delivered after a user has already
    // completed a new password sign-in. Never let that stale event clear the
    // freshly authenticated session and redirect the user back to Login.
    final hasNewRemoteSession =
        ref.read(supabaseClientProvider)?.auth.currentSession != null;
    if (hasNewRemoteSession) return;
    if (local != null) {
      state = AsyncData(local);
      _onSessionRestored();
    } else if (state.value != null) {
      state = const AsyncData(null);
    }
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
    final previous = state.value;
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final user = await ref.read(authRepositoryProvider).signInWithGoogle();
      if (user != null) {
        await ref
            .read(databaseServiceProvider)
            .setActiveWorkspaceId(user.factoryId);
        _onLoginSuccess();
        return user;
      }
      return kIsWeb ? previous : user;
    });
  }

  Future<bool> signUp({
    required String email,
    required String password,
    required String profileName,
    required String workspaceName,
  }) async {
    state = const AsyncLoading();
    var verificationRequired = false;
    state = await AsyncValue.guard(() async {
      final user = await ref.read(authRepositoryProvider).signUp(
            email: email,
            password: password,
            profileName: profileName,
            workspaceName: workspaceName,
            db: ref.read(databaseServiceProvider),
          );
      if (user == null) {
        verificationRequired = true;
        return null;
      }
      _onLoginSuccess();
      return user;
    });
    return verificationRequired && !state.hasError;
  }

  Future<void> verifySignUpOtp({
    required String email,
    required String token,
    required String profileName,
    required String workspaceName,
  }) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final user = await ref.read(authRepositoryProvider).verifySignUpOtp(
            email: email,
            token: token,
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
    final user = state.value;
    if (user != null) {
      await ref
          .read(databaseServiceProvider)
          .setActiveWorkspaceId(user.factoryId);
      _onSessionRestored();
    }
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

  /// Step 1: Send reauth OTP to current email
  Future<String?> sendEmailChangeOtp(String newEmail) async {
    if (ref.read(currentUserProvider).value == null) return 'Not logged in';
    try {
      await ref.read(authRepositoryProvider).sendReauthOtp();
      return null;
    } catch (e) {
      return _safeAuthMessage(
        e,
        fallback: 'Could not send a security code. Please try again.',
      );
    }
  }

  /// Step 2: Verify OTP then update email
  Future<String?> verifyEmailChangeOtp(String code, String newEmail) async {
    final user = ref.read(currentUserProvider).value;
    if (user == null) return 'Not logged in';
    try {
      await ref
          .read(authRepositoryProvider)
          .verifyAndUpdateEmail(nonce: code, newEmail: newEmail);
      return null;
    } catch (e) {
      return _safeAuthMessage(
        e,
        fallback: 'Could not update your email. Please try again.',
      );
    }
  }

  /// Step 1: Send reauth OTP to current email
  Future<String?> sendPasswordChangeOtp(String newPassword) async {
    if (ref.read(currentUserProvider).value == null) return 'Not logged in';
    try {
      await ref.read(authRepositoryProvider).sendReauthOtp();
      return null;
    } catch (e) {
      return _safeAuthMessage(
        e,
        fallback: 'Could not send a security code. Please try again.',
      );
    }
  }

  /// Step 2: Verify OTP then update password
  Future<String?> verifyPasswordChangeOtp(
    String code,
    String newPassword,
  ) async {
    if (ref.read(currentUserProvider).value == null) return 'Not logged in';
    try {
      await ref
          .read(authRepositoryProvider)
          .verifyAndUpdatePassword(nonce: code, newPassword: newPassword);
      return null;
    } catch (e) {
      return _safeAuthMessage(
        e,
        fallback: 'Could not update your password. Please try again.',
      );
    }
  }
}

final accountSettingsProvider =
    AsyncNotifierProvider<AccountSettingsNotifier, void>(
  AccountSettingsNotifier.new,
);
