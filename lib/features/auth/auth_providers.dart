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

final passwordRecoveryPendingProvider = NotifierProvider<_BoolNotifier, bool>(_BoolNotifier.new);

class _BoolNotifier extends Notifier<bool> {
  @override
  bool build() => false;
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

const _secureStorage = FlutterSecureStorage(
  aOptions: AndroidOptions(encryptedSharedPreferences: true),
);

Future<void> _saveLocalSession(AppUser user) async {
  await _secureStorage.write(
      key: _kSessionKey, value: jsonEncode(user.toJson()),);
  await _secureStorage.write(
      key: _kSessionCreatedKey, value: DateTime.now().toIso8601String(),);
  await _secureStorage.write(
      key: _kSessionProviderKey, value: user.authProvider,);
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
      throw Exception(
          'Server not configured. Use offline login or contact admin.',);
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
    if (user == null) return null;
    final signedInUser = user.copyWith(authProvider: 'email');
    await _saveLocalSession(signedInUser);
    return signedInUser;
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

  /// Returns cached local session — no network needed.
  Future<AppUser?> getLocalSession() => _loadLocalSession();

  /// Try to refresh from Supabase; fall back to local session silently.
  Future<AppUser?> getCurrentAppUser() async {
    final local = await _loadLocalSession();
    final client = _client;
    if (client != null && client.auth.currentUser != null) {
      try {
        final authUser = client.auth.currentUser!;
        var remote = await _fetchAppUser(client, authUser.id);
        final provider = authUser.appMetadata['provider'];
        if (remote == null && provider == 'google') {
          final metadata = authUser.userMetadata ?? const <String, dynamic>{};
          await client.rpc('handle_google_auth_user', params: {
            'p_user_id': authUser.id,
            'p_email': authUser.email ?? '',
            'p_name': metadata['full_name'] ??
                metadata['name'] ??
                authUser.email?.split('@').first ??
                'User',
            'p_avatar_url': metadata['avatar_url'] ??
                metadata['picture'] ??
                '',
            'p_workspace_name': 'My Workspace',
          },);
          remote = await _fetchAppUser(client, authUser.id);
        }
        if (remote != null) {
          final restored = remote.copyWith(
            authProvider: provider == 'google' ? 'google' : 'email',
            sessionCreatedAt: local?.sessionCreatedAt,
          );
          await _hydrateLocalWorkspace(client, restored);
          await _saveLocalSession(restored);
          return restored;
        }
      } catch (_) {
        // Offline startup keeps the last verified local session usable.
      }
    }
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

  /// Sign up: creates auth user, immediately signs in to get a valid JWT,
  /// then calls the RPC (which needs auth.uid() to be set).
  Future<AppUser?> signUp({
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

    // Step 2: Sign in only if signUp didn't return a session.
    if (response.session == null) {
      return null;
    }

    // Step 3: Call RPC — auth.uid() is now valid
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

    final result = await client.rpc('create_user_workspace', params: {
      'p_profile_name': profileName,
      'p_workspace_name': workspaceName,
    },);
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

  Future<void> sendPasswordResetEmail(String email) async {
    final client = _client;
    if (client == null) throw Exception('Server not configured.');
    await client.auth.resetPasswordForEmail(
      email,
      redirectTo: 'com.proflow.factoryflow://login-callback',
    );
  }

  /// Sends Supabase Auth's real reauthentication OTP to the signed-in user's
  /// verified email. No OTP is generated or returned to the mobile client.
  Future<void> sendReauthenticationOtp() async {
    final client = _client;
    if (client == null) throw Exception('Server not configured.');
    await client.auth.reauthenticate();
  }

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

  Future<String> updateAuthEmail({
    required String newEmail,
    required String nonce,
  }) async {
    final client = _client;
    if (client == null) throw Exception('Server not configured.');
    final response = await client.auth.updateUser(
      UserAttributes(email: newEmail, nonce: nonce),
    );
    return response.user?.email ?? newEmail;
  }

  Future<void> changePassword(String newPassword,
      {required String nonce,}) async {
    final client = _client;
    if (client == null) throw Exception('Server not configured.');
    await client.auth.updateUser(
      UserAttributes(password: newPassword, nonce: nonce),
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
    ref.listen(authStateProvider, (_, next) {
      final authState = next.value;
      if (authState == null) return;
      if (authState.event == AuthChangeEvent.passwordRecovery) {
        ref.read(passwordRecoveryPendingProvider.notifier).state = true;
      }
      if (authState.event == AuthChangeEvent.signedIn ||
          authState.event == AuthChangeEvent.tokenRefreshed ||
          authState.event == AuthChangeEvent.userUpdated) {
        unawaited(refresh());
      } else if (authState.event == AuthChangeEvent.signedOut) {
        // Keep the 14-day local session when Supabase signs out (expired
        // refresh token / offline). Only clear after explicit signOut().
        unawaited(_restoreLocalSessionAfterRemoteSignOut());
      }
    });
    final user =
        await ref.read(authRepositoryProvider).getCurrentAppUser();
    if (user != null) _onSessionRestored();
    return user;
  }

  Future<void> _restoreLocalSessionAfterRemoteSignOut() async {
    final local = await ref.read(authRepositoryProvider).getLocalSession();
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
      // Web OAuth redirects away; keep prior session until callback lands.
      // Mobile returning null is an error — surface as no profile.
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

  Future<String?> sendEmailChangeOtp(String newEmail) async {
    final user = ref.read(currentUserProvider).value;
    if (user == null) return 'Not logged in';
    try {
      await ref.read(authRepositoryProvider).sendReauthenticationOtp();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<String?> verifyEmailChangeOtp(String code, String newEmail) async {
    final user = ref.read(currentUserProvider).value;
    if (user == null) return 'Not logged in';
    try {
      final confirmedEmail = await ref
          .read(authRepositoryProvider)
          .updateAuthEmail(newEmail: newEmail, nonce: code);
      await ref
          .read(currentUserProvider.notifier)
          .refreshUser(user.copyWith(email: confirmedEmail));
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<String?> sendPasswordChangeOtp(String newPassword) async {
    final user = ref.read(currentUserProvider).value;
    if (user == null) return 'Not logged in';
    try {
      await ref.read(authRepositoryProvider).sendReauthenticationOtp();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<String?> verifyPasswordChangeOtp(
    String code,
    String newPassword,
  ) async {
    final user = ref.read(currentUserProvider).value;
    if (user == null) return 'Not logged in';
    try {
      await ref
          .read(authRepositoryProvider)
          .changePassword(newPassword, nonce: code);
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
