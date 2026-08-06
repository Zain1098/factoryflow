import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../constants/app_constants.dart';
import '../../features/auth/auth_providers.dart';
import '../network/sync_service.dart';
import '../services/alert_producer_service.dart';

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell>
    with WidgetsBindingObserver {
  DateTime? _lastBackPress;
  Timer? _idleTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _resetIdleTimer();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _idleTimer?.cancel();
    super.dispose();
  }

  void _resetIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(
      const Duration(minutes: AppConstants.sessionTimeoutMinutes),
      _expireIdleSession,
    );
  }

  Future<void> _expireIdleSession() async {
    if (!mounted || ref.read(currentUserProvider).value == null) return;
    await ref.read(currentUserProvider.notifier).signOut();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'Session expired after inactivity. Please sign in again.')),
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(alertProducerServiceProvider).checkAll();
    }
  }

  Future<bool> _onWillPop() async {
    final location = GoRouterState.of(context).matchedLocation;
    final router = GoRouter.of(context);
    if (router.canPop()) {
      router.pop();
      return false;
    }

    // Direct/deep links have no stack. Return entry forms to Entries and
    // settings sub-pages to Settings; other top-level pages return Dashboard.
    if (location != '/dashboard') {
      if (_isEntryRoute(location) && location != '/entries') {
        context.go('/entries');
      } else if (_isSettingsRoute(location) && location != '/settings') {
        context.go('/settings');
      } else {
        context.go('/dashboard');
      }
      return false;
    }
    // On dashboard: double-tap back to exit
    final now = DateTime.now();
    if (_lastBackPress == null ||
        now.difference(_lastBackPress!) > const Duration(seconds: 2)) {
      _lastBackPress = now;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Press back again to exit'),
          duration: Duration(seconds: 2),
        ),
      );
      return false;
    }
    await SystemNavigator.pop();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final isOnline = ref.watch(isOnlineProvider);
    final pendingSync = ref.watch(pendingSyncCountProvider).value ?? 0;

    // Always intercept so entry pages pop to Entries (or prior stack)
    // instead of jumping straight to Dashboard when the shell has no stack.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop) await _onWillPop();
      },
      child: Listener(
        onPointerDown: (_) => _resetIdleTimer(),
        child: Scaffold(
          body: Column(
            children: [
              if (!isOnline)
                MaterialBanner(
                  backgroundColor:
                      Theme.of(context).colorScheme.surfaceContainerHighest,
                  leading: const Icon(Icons.cloud_off_outlined,
                      color: Colors.orange),
                  content: Text(
                    pendingSync > 0
                        ? 'Offline — $pendingSync record(s) will sync when connected.'
                        : 'Offline mode — all saved data is available.',
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                  actions: const [SizedBox.shrink()],
                ),
              Expanded(child: widget.child),
            ],
          ),
          bottomNavigationBar: Container(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: Theme.of(context).dividerColor),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.06),
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: NavigationBar(
                selectedIndex: _calculateIndex(context),
                onDestinationSelected: (index) => _onTap(context, index),
                destinations: const [
                  NavigationDestination(
                    icon: Icon(Icons.dashboard_outlined),
                    selectedIcon: Icon(Icons.dashboard),
                    label: 'Dashboard',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.edit_note_outlined),
                    selectedIcon: Icon(Icons.edit_note),
                    label: 'Entries',
                  ),
                  NavigationDestination(
                      icon: Icon(Icons.search), label: 'Search'),
                  NavigationDestination(
                    icon: Icon(Icons.assessment_outlined),
                    selectedIcon: Icon(Icons.assessment),
                    label: 'Reports',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.settings_outlined),
                    selectedIcon: Icon(Icons.settings),
                    label: 'Settings',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  int _calculateIndex(BuildContext context) {
    final location = GoRouterState.of(context).matchedLocation;
    if (location.startsWith('/dashboard')) return 0;
    if (_isEntryRoute(location)) return 1;
    if (location.startsWith('/search')) return 2;
    if (location.startsWith('/reports')) return 3;
    if (_isSettingsRoute(location)) return 4;
    return 0;
  }

  bool _isEntryRoute(String location) {
    const entryRoutes = [
      '/entries',
      '/material-receive',
      '/production',
      '/machine-downtime',
      '/bp-inspection',
      '/dispatch-faco',
      '/receive-faco',
      '/ap-inspection',
      '/rtv',
      '/final-dispatch',
    ];
    return entryRoutes.any(location.startsWith);
  }

  bool _isSettingsRoute(String location) {
    const settingsRoutes = [
      '/settings',
      '/notifications',
      '/corrections',
    ];
    return settingsRoutes.any(location.startsWith);
  }

  void _onTap(BuildContext context, int index) {
    switch (index) {
      case 0:
        context.go('/dashboard');
      case 1:
        context.go('/entries');
      case 2:
        context.go('/search');
      case 3:
        context.go('/reports');
      case 4:
        context.go('/settings');
    }
  }
}
