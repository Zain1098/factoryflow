import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../network/sync_service.dart';

class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isOnline = ref.watch(isOnlineProvider);
    final pendingSync = ref.watch(pendingSyncCountProvider).value ?? 0;

    return Scaffold(
      body: Column(
        children: [
          if (!isOnline)
            MaterialBanner(
              backgroundColor:
                  Theme.of(context).colorScheme.surfaceContainerHighest,
              leading: const Icon(Icons.cloud_off_outlined, color: Colors.orange),
              content: Text(
                pendingSync > 0
                    ? 'Offline — $pendingSync record(s) will sync when connected.'
                    : 'Offline mode — all saved data is available.',
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
              actions: const [SizedBox.shrink()],
            ),
          Expanded(child: child),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _calculateIndex(context),
        onDestinationSelected: (index) => _onTap(context, index),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.dashboard_outlined),
              selectedIcon: Icon(Icons.dashboard),
              label: 'Dashboard'),
          NavigationDestination(
              icon: Icon(Icons.edit_note_outlined),
              selectedIcon: Icon(Icons.edit_note),
              label: 'Entries'),
          NavigationDestination(icon: Icon(Icons.search), label: 'Search'),
          NavigationDestination(
              icon: Icon(Icons.assessment_outlined),
              selectedIcon: Icon(Icons.assessment),
              label: 'Reports'),
          NavigationDestination(icon: Icon(Icons.more_horiz), label: 'More'),
        ],
      ),
    );
  }

  int _calculateIndex(BuildContext context) {
    final location = GoRouterState.of(context).matchedLocation;
    if (location.startsWith('/dashboard')) return 0;
    if (_isEntryRoute(location)) return 1;
    if (location.startsWith('/search')) return 2;
    if (location.startsWith('/reports')) return 3;
    return 4;
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
        _showMoreMenu(context);
    }
  }

  void _showMoreMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.notifications_outlined),
              title: const Text('Notifications'),
              onTap: () {
                Navigator.pop(ctx);
                context.go('/notifications');
              },
            ),
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: const Text('Settings'),
              onTap: () {
                Navigator.pop(ctx);
                context.go('/settings');
              },
            ),
            ListTile(
              leading: const Icon(Icons.gavel_outlined),
              title: const Text('Corrections'),
              onTap: () {
                Navigator.pop(ctx);
                context.go('/corrections');
              },
            ),
          ],
        ),
      ),
    );
  }
}
