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
          bottomNavigationBar: _FloatingBottomNavigation(
            selectedIndex: _calculateIndex(context),
            onSelected: (index) => _onTap(context, index),
          ),
        ),
      ),
    );
  }

  int _calculateIndex(BuildContext context) {
    final location = GoRouterState.of(context).matchedLocation;
    if (_isEntryRoute(location)) return 0;
    if (location.startsWith('/reports')) return 1;
    if (location.startsWith('/dashboard')) return 2;
    if (location.startsWith('/search')) return 3;
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
        context.go('/entries');
        return;
      case 1:
        context.go('/reports');
        return;
      case 2:
        context.go('/dashboard');
        return;
      case 3:
        context.go('/search');
        return;
      case 4:
        context.go('/settings');
        return;
    }
  }
}

/// Compact, app-wide access to automatic cloud sync. Detailed pages are only
/// needed where an administrator must resolve an actual conflict.
class SyncStatusButton extends ConsumerWidget {
  const SyncStatusButton({
    required this.isOnline,
    required this.pendingCount,
    this.compact = false,
  });

  final bool isOnline;
  final int pendingCount;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final color = !isOnline
        ? Colors.orange
        : pendingCount > 0
            ? Colors.indigo
            : Colors.green;
    final icon = !isOnline
        ? Icons.cloud_off_outlined
        : pendingCount > 0
            ? Icons.cloud_sync_outlined
            : Icons.cloud_done_outlined;
    final label = !isOnline
        ? 'Offline'
        : pendingCount > 0
            ? '$pendingCount pending'
            : 'Synced';

    final action = compact
        ? IconButton.filledTonal(
            onPressed: () => _showSyncSheet(context, ref),
            icon: Icon(icon),
            tooltip: 'Cloud sync: $label',
            style: IconButton.styleFrom(foregroundColor: color),
          )
        : FloatingActionButton.extended(
            heroTag: 'cloud-sync-status',
            backgroundColor: Theme.of(context).colorScheme.surface,
            foregroundColor: color,
            elevation: 3,
            onPressed: () => _showSyncSheet(context, ref),
            icon: Icon(icon),
            label: Text(label),
          );

    return Semantics(
      button: true,
      label: 'Cloud sync status: $label',
      child: Tooltip(
        message: 'Cloud sync: $label',
        child: action,
      ),
    );
  }

  Future<void> _showSyncSheet(BuildContext context, WidgetRef ref) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        var syncing = false;
        return StatefulBuilder(
          builder: (context, setSheetState) => Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Cloud Sync',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(
                  !isOnline
                      ? 'Offline. Changes are safely saved on this device and will sync automatically after reconnecting.'
                      : pendingCount > 0
                          ? '$pendingCount record(s) are waiting to sync automatically.'
                          : 'All saved records are synced to the cloud.',
                ),
                if (pendingCount > 0) ...[
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: !isOnline || syncing
                          ? null
                          : () async {
                              setSheetState(() => syncing = true);
                              final result = await ref
                                  .read(syncServiceProvider)
                                  .syncPending();
                              if (!context.mounted) return;
                              setSheetState(() => syncing = false);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(result.synced > 0
                                      ? '${result.synced} record(s) synced.'
                                      : result.offline
                                          ? 'Still offline. Sync will retry automatically.'
                                          : 'Sync is already up to date.'),
                                ),
                              );
                            },
                      icon: syncing
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.sync),
                      label: Text(syncing ? 'Syncing...' : 'Sync now'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// A compact five-destination bar with the dashboard lifted above its center.
/// Route selection remains in [AppShell], so forms and nested pages retain
/// their existing navigation behaviour.
class _FloatingBottomNavigation extends StatelessWidget {
  const _FloatingBottomNavigation({
    required this.selectedIndex,
    required this.onSelected,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final surface = scheme.surface;

    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: SizedBox(
        height: 86,
        child: Stack(
          alignment: Alignment.topCenter,
          clipBehavior: Clip.none,
          children: [
            Positioned(
              top: 22,
              left: 0,
              right: 0,
              bottom: 0,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: surface,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: theme.dividerColor),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.07),
                      blurRadius: 18,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: _BottomNavIconButton(
                        label: 'Entries',
                        icon: Icons.edit_note_outlined,
                        selectedIcon: Icons.edit_note,
                        selected: selectedIndex == 0,
                        onTap: () => onSelected(0),
                      ),
                    ),
                    Expanded(
                      child: _BottomNavIconButton(
                        label: 'Reports',
                        icon: Icons.assessment_outlined,
                        selectedIcon: Icons.assessment,
                        selected: selectedIndex == 1,
                        onTap: () => onSelected(1),
                      ),
                    ),
                    const SizedBox(width: 76),
                    Expanded(
                      child: _BottomNavIconButton(
                        label: 'Search',
                        icon: Icons.search_outlined,
                        selectedIcon: Icons.search,
                        selected: selectedIndex == 3,
                        onTap: () => onSelected(3),
                      ),
                    ),
                    Expanded(
                      child: _BottomNavIconButton(
                        label: 'Settings',
                        icon: Icons.settings_outlined,
                        selectedIcon: Icons.settings,
                        selected: selectedIndex == 4,
                        onTap: () => onSelected(4),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            _DashboardNavButton(
              selected: selectedIndex == 2,
              onTap: () => onSelected(2),
            ),
          ],
        ),
      ),
    );
  }
}

class _BottomNavIconButton extends StatelessWidget {
  const _BottomNavIconButton({
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = selected ? scheme.primary : scheme.onSurfaceVariant;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Tooltip(
        message: label,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(20),
            child: Center(
              child: AnimatedScale(
                scale: selected ? 1.08 : 1,
                duration: const Duration(milliseconds: 160),
                child: Icon(selected ? selectedIcon : icon, color: color),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DashboardNavButton extends StatelessWidget {
  const _DashboardNavButton({required this.selected, required this.onTap});

  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: 'Dashboard',
      child: Tooltip(
        message: 'Dashboard',
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          child: InkResponse(
            onTap: onTap,
            radius: 42,
            containedInkWell: true,
            customBorder: const CircleBorder(),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: 70,
              height: 70,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                  colors: [
                    Color(0xFF4A2FE7),
                    Color(0xFF135CF0),
                    Color(0xFF28B8FF),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF246CF5)
                        .withValues(alpha: selected ? 0.45 : 0.28),
                    blurRadius: selected ? 18 : 13,
                    spreadRadius: selected ? 2 : 0,
                    offset: const Offset(0, 7),
                  ),
                ],
              ),
              child: const Icon(
                Icons.home_rounded,
                color: Colors.white,
                size: 31,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
