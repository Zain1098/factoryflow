import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../features/auth/auth_providers.dart';
import '../network/sync_service.dart';
import '../providers/master_data_providers.dart';
import 'app_access_state.dart';

class AppAccessGate extends ConsumerStatefulWidget {
  const AppAccessGate({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<AppAccessGate> createState() => _AppAccessGateState();
}

class _AppAccessGateState extends ConsumerState<AppAccessGate>
    with WidgetsBindingObserver {
  static const _profileProvisioningRetryDelays = <Duration>[
    Duration.zero,
    Duration(milliseconds: 250),
    Duration(milliseconds: 500),
    Duration(milliseconds: 750),
  ];

  Timer? _pollTimer;
  StreamSubscription<AuthState>? _authSubscription;
  bool _checking = false;
  bool _hasVerifiedAccess = false;
  bool _blockedAfterVerification = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _authSubscription = ref.read(supabaseClientProvider)?.auth.onAuthStateChange
        .listen((event) {
      if (event.event == AuthChangeEvent.signedIn ||
          event.event == AuthChangeEvent.tokenRefreshed ||
          event.event == AuthChangeEvent.userUpdated) {
        _blockedAfterVerification = false;
        unawaited(_checkAccess(background: _hasVerifiedAccess));
      }
    });
    unawaited(_checkAccess());
    _pollTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        unawaited(_checkAccess(background: true));
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pollTimer?.cancel();
    _authSubscription?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_checkAccess(background: _hasVerifiedAccess));
    }
  }

  Future<void> _checkAccess({bool background = false}) async {
    if (_checking || _blockedAfterVerification) return;
    final client = ref.read(supabaseClientProvider);
    final session = client?.auth.currentSession;
    if (client == null || session == null) {
      await _allowCachedSession();
      return;
    }

    // A previously authenticated user can safely continue with the encrypted
    // local profile and SQLite data while the network is unavailable. Remote
    // access is checked again on reconnect; local writes remain queued until
    // Supabase is reachable.
    if (!await ref.read(syncServiceProvider).isOnline()) {
      await _allowCachedSession();
      return;
    }

    _checking = true;
    if (!background) ref.read(syncServiceProvider).stopPeriodicSync();
    if (!background) {
      ref.read(appAccessProvider.notifier).set(const AppAccessState.checking());
    }
    try {
      final profile = await _loadProfileAfterProvisioning(
        client,
        userId: session.user.id,
      );

      // A Supabase signedIn event arrives before the password-login flow has
      // necessarily created an older account's app profile/workspace. Treat a
      // temporarily absent profile as an unavailable access decision, never as
      // proof that the user is inactive. This keeps ERP routes and sync closed
      // until verification succeeds without signing a valid new session out.
      if (profile == null) {
        if (!background) ref.read(syncServiceProvider).stopPeriodicSync();
        if (!background) {
          ref.read(appAccessProvider.notifier).set(const AppAccessState(
            status: AppAccessStatus.unavailable,
            title: 'Account setup is not complete',
            message:
                'We could not verify your app profile. Please retry in a moment or contact your administrator.',
          ),);
        }
        return;
      }

      // A completed check for a stale session must not modify the state for a
      // user who signed out or switched accounts while the request was running.
      if (client.auth.currentSession?.user.id != session.user.id) return;
      final profileVerification = verifyProfileActivity(profile['active']);
      if (profileVerification == AppProfileVerification.unresolved) {
        if (!background) ref.read(syncServiceProvider).stopPeriodicSync();
        if (!background) {
          ref.read(appAccessProvider.notifier).set(const AppAccessState(
            status: AppAccessStatus.unavailable,
            title: 'App profile could not be verified',
            message:
                'We could not verify your account status. Please reconnect and try again.',
          ),);
        }
        return;
      }
      if (profileVerification == AppProfileVerification.inactive) {
        _blockedAfterVerification = true;
        ref.read(syncServiceProvider).stopPeriodicSync();
        // Existing sign-out clears local credentials only. We intentionally do
        // not erase ERP/ledger rows locally or remotely from an access gate.
        await ref.read(currentUserProvider.notifier).signOut();
        ref.read(appAccessProvider.notifier).set(const AppAccessState(
          status: AppAccessStatus.blocked,
          title: 'Access unavailable',
          message:
              'Your access is currently unavailable. Please contact your administrator.',
        ),);
        return;
      }

      final raw = await client
          .rpc('platform_maintenance_status')
          .timeout(const Duration(seconds: 12));
      final maintenance = Map<String, dynamic>.from(raw as Map);
      if (maintenance['enabled'] == true) {
        ref.read(appAccessProvider.notifier).set(AppAccessState(
          status: AppAccessStatus.maintenance,
          title: maintenance['title']?.toString().trim().isNotEmpty == true
              ? maintenance['title'].toString()
              : 'Maintenance in progress',
          message: maintenance['message']?.toString().trim().isNotEmpty == true
              ? maintenance['message'].toString()
              : 'Please try again shortly.',
        ),);
        return;
      }

      final needsBootstrap = !_hasVerifiedAccess;
      _hasVerifiedAccess = true;
      if (!background || !ref.read(appAccessProvider).isAllowed) {
        ref.read(appAccessProvider.notifier).set(
          const AppAccessState(status: AppAccessStatus.allowed),
        );
      }
      final sync = ref.read(syncServiceProvider);
      sync.startPeriodicSync();
      if (needsBootstrap) {
        unawaited(sync.hydrateActiveWorkspace());
        unawaited(
          ref.read(masterDataRepositoryProvider).syncMasterDataFromSupabase(),
        );
      }
    } catch (_) {
      // Connectivity plugins can report Wi-Fi/mobile availability even when
      // the internet or Supabase endpoint is unreachable. Do not turn that
      // transient background failure into a login/app-block screen when this
      // device has a valid saved session and local ERP data.
      if (await _allowCachedSession()) return;
      if (!background) ref.read(syncServiceProvider).stopPeriodicSync();
      if (!background) {
        ref.read(appAccessProvider.notifier).set(const AppAccessState(
          status: AppAccessStatus.unavailable,
          title: 'App availability could not be verified',
          message: 'We could not verify app availability. Please reconnect and try again.',
        ),);
      }
    } finally {
      _checking = false;
    }
  }

  Future<bool> _allowCachedSession() async {
    final local = await ref.read(authRepositoryProvider).getLocalSession();
    if (local == null) {
      ref.read(syncServiceProvider).stopPeriodicSync();
      ref.read(appAccessProvider.notifier).set(
        const AppAccessState(status: AppAccessStatus.allowed),
      );
      return false;
    }

    if (!ref.read(appAccessProvider).isAllowed) {
      ref.read(appAccessProvider.notifier).set(
        const AppAccessState(status: AppAccessStatus.allowed),
      );
    }
    // The connectivity listener starts immediately. It sends pending local
    // writes when the connection returns; no user action or screen refresh is
    // needed.
    ref.read(syncServiceProvider).startPeriodicSync();
    return true;
  }

  Future<Map<String, dynamic>?> _loadProfileAfterProvisioning(
    SupabaseClient client, {
    required String userId,
  }) async {
    for (final delay in _profileProvisioningRetryDelays) {
      if (delay != Duration.zero) await Future<void>.delayed(delay);
      if (client.auth.currentSession?.user.id != userId) return null;

      final profile = await client
          .from('users')
          .select('id, active')
          .eq('id', userId)
          .maybeSingle()
          .timeout(const Duration(seconds: 12));
      if (profile != null) return Map<String, dynamic>.from(profile);
    }
    return null;
  }

  void _goToSignIn() {
    _blockedAfterVerification = false;
    ref.read(appAccessProvider.notifier).set(
      const AppAccessState(status: AppAccessStatus.allowed),
    );
  }

  @override
  Widget build(BuildContext context) {
    final access = ref.watch(appAccessProvider);
    if (!access.blocksProtectedRoutes) return widget.child;
    final isBlocked = access.status == AppAccessStatus.blocked;
    final isUnavailable = access.status == AppAccessStatus.unavailable;
    if (access.status == AppAccessStatus.checking) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(
              isBlocked ? Icons.lock_outline : Icons.construction_rounded,
              size: 56,
            ),
            const SizedBox(height: 16),
            Text(access.title ?? 'Access unavailable',
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center,),
            const SizedBox(height: 8),
            Text(access.message ?? '', textAlign: TextAlign.center),
            if (!isBlocked) ...[
              const SizedBox(height: 12),
              const Text(
                'The app is temporarily unavailable due to maintenance or a security reason.',
                textAlign: TextAlign.center,
              ),
            ],
            if (isUnavailable || isBlocked) ...[
              const SizedBox(height: 24),
              FilledButton(
                onPressed: isBlocked ? _goToSignIn : _checkAccess,
                child: Text(isBlocked ? 'Sign in' : 'Retry'),
              ),
            ],
          ],),
        ),
      ),
    );
  }
}
