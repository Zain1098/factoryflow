import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../constants/user_roles.dart';
import '../../features/auth/auth_providers.dart';
import '../../features/auth/login_screen.dart';
import '../../features/dashboard/dashboard_screen.dart';
import '../../features/material_receive/material_receive_screen.dart';
import '../../features/production/production_screen.dart';
import '../../features/machine_downtime/machine_downtime_screen.dart';
import '../../features/bp_inspection/bp_inspection_screen.dart';
import '../../features/dispatch_faco/dispatch_faco_screen.dart';
import '../../features/receive_faco/receive_faco_screen.dart';
import '../../features/ap_inspection/ap_inspection_screen.dart';
import '../../features/rtv/rtv_screen.dart';
import '../../features/final_dispatch/final_dispatch_screen.dart';
import '../../features/reports/reports_screen.dart';
import '../../features/search/search_screen.dart';
import '../../features/notifications/notifications_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/corrections/corrections_screen.dart';
import '../widgets/app_shell.dart';

// ---------------------------------------------------------------------------
// Router provider — watches currentUserProvider for reactive redirects
// ---------------------------------------------------------------------------

final routerProvider = Provider<GoRouter>((ref) {
  // Keep a ChangeNotifier that fires whenever auth state changes
  final authNotifier = _AuthChangeNotifier(ref);

  final router = GoRouter(
    initialLocation: '/login',
    refreshListenable: authNotifier,
    redirect: (context, state) {
      final userAsync = ref.read(currentUserProvider);
      final isLoggedIn = userAsync.value != null;
      final isLoading = userAsync.isLoading;
      final isLoginRoute = state.matchedLocation == '/login';
      final isSplashRoute = state.matchedLocation == '/';

      // Don't redirect while loading
      if (isLoading) return null;

      // Not logged in → go to login (unless already there)
      if (!isLoggedIn && !isLoginRoute && !isSplashRoute) return '/login';

      // Logged in → skip login screen
      if (isLoggedIn && isLoginRoute) return '/dashboard';

      return null;
    },
    routes: [
      GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
      ShellRoute(
        builder: (context, state, child) => AppShell(child: child),
        routes: [
          GoRoute(path: '/dashboard', builder: (_, __) => const DashboardScreen()),
          GoRoute(path: '/entries', builder: (_, __) => const EntriesMenuScreen()),
          GoRoute(path: '/material-receive', builder: (_, __) => const MaterialReceiveScreen()),
          GoRoute(path: '/production', builder: (_, __) => const ProductionScreen()),
          GoRoute(path: '/machine-downtime', builder: (_, __) => const MachineDowntimeScreen()),
          GoRoute(path: '/bp-inspection', builder: (_, __) => const BpInspectionScreen()),
          GoRoute(path: '/dispatch-faco', builder: (_, __) => const DispatchFacoScreen()),
          GoRoute(path: '/receive-faco', builder: (_, __) => const ReceiveFacoScreen()),
          GoRoute(path: '/ap-inspection', builder: (_, __) => const ApInspectionScreen()),
          GoRoute(path: '/rtv', builder: (_, __) => const RtvScreen()),
          GoRoute(path: '/final-dispatch', builder: (_, __) => const FinalDispatchScreen()),
          GoRoute(path: '/search', builder: (_, __) => const SearchScreen()),
          GoRoute(path: '/reports', builder: (_, __) => const ReportsScreen()),
          GoRoute(path: '/notifications', builder: (_, __) => const NotificationsScreen()),
          GoRoute(path: '/settings', builder: (_, __) => const SettingsScreen()),
          GoRoute(path: '/corrections', builder: (_, __) => const CorrectionsScreen()),
        ],
      ),
    ],
  );

  // Keep authNotifier alive as long as router lives
  ref.onDispose(authNotifier.dispose);

  return router;
});

// ---------------------------------------------------------------------------
// Listens to currentUserProvider — notifies router on every auth change
// ---------------------------------------------------------------------------

class _AuthChangeNotifier extends ChangeNotifier {
  _AuthChangeNotifier(Ref ref) {
    _sub = ref.listen<AsyncValue<dynamic>>(currentUserProvider, (_, __) {
      notifyListeners();
    });
  }

  late final ProviderSubscription<AsyncValue<dynamic>> _sub;

  @override
  void dispose() {
    _sub.close();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// Entries menu (role-based)
// ---------------------------------------------------------------------------

class EntriesMenuScreen extends ConsumerWidget {
  const EntriesMenuScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final role = ref.watch(userRoleProvider);
    final entries = _entriesForRole(role);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Entries')),
      body: entries.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.lock_outline, size: 48, color: theme.colorScheme.outline),
                  const SizedBox(height: 12),
                  Text(
                    'No modules available for your role',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: entries.length,
              itemBuilder: (context, index) {
                final entry = entries[index];
                return Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: theme.colorScheme.primaryContainer,
                      child: Icon(entry.icon, color: theme.colorScheme.primary, size: 20),
                    ),
                    title: Text(entry.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(entry.subtitle),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => context.go(entry.route),
                  ),
                );
              },
            ),
    );
  }

  List<_EntryItem> _entriesForRole(UserRole? role) {
    final all = [
      const _EntryItem('Material Receive', 'Raw material intake', '/material-receive', Icons.inventory_2, 'material_receive'),
      const _EntryItem('Production', 'Machine production entry', '/production', Icons.precision_manufacturing, 'production'),
      const _EntryItem('Machine Downtime', 'Breakdown & maintenance', '/machine-downtime', Icons.build, 'machine_downtime'),
      const _EntryItem('BP Inspection', 'Pre-plating QC', '/bp-inspection', Icons.fact_check, 'bp_inspection'),
      const _EntryItem('Dispatch to Faco', 'Send to plating vendor', '/dispatch-faco', Icons.local_shipping, 'dispatch_faco'),
      const _EntryItem('Receive from Faco', 'Receive plated material', '/receive-faco', Icons.move_to_inbox, 'receive_faco'),
      const _EntryItem('AP Inspection', 'Post-plating QC', '/ap-inspection', Icons.verified, 'ap_inspection'),
      const _EntryItem('RTV', 'Return to vendor', '/rtv', Icons.undo, 'rtv'),
      const _EntryItem('Final Dispatch', 'Ship to customer', '/final-dispatch', Icons.send, 'final_dispatch'),
    ];

    if (role == null) return [];
    if (role == UserRole.admin) return all;
    return all.where((e) => role.canAccessModule(e.module)).toList();
  }
}

class _EntryItem {
  const _EntryItem(this.title, this.subtitle, this.route, this.icon, this.module);
  final String title;
  final String subtitle;
  final String route;
  final IconData icon;
  final String module;
}
