import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../constants/user_roles.dart';
import '../../features/auth/auth_providers.dart';
import '../../features/auth/login_screen.dart';
import '../../features/dashboard/dashboard_screen.dart';
import '../../features/material_receive/material_receive_screen.dart';
import '../../features/production/production_page.dart';
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
import '../widgets/shared_widgets.dart';

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

      // Don't redirect while loading initial session
      if (isLoading) return null;

      // Not logged in → go to login
      if (!isLoggedIn && !isLoginRoute) return '/login';

      // Logged in → skip login screen
      if (isLoggedIn && isLoginRoute) return '/dashboard';

      if (isLoggedIn) {
        final role = userAsync.value!.role;
        final module = _moduleForLocation(state.matchedLocation);
        if (module != null && !role.canAccessModule(module)) {
          return '/dashboard';
        }
        if (_isOwnerOnlyLocation(state.matchedLocation) &&
            !role.canManageMasters) {
          return '/dashboard';
        }
      }

      return null;
    },
    routes: [
      GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
      ShellRoute(
        builder: (context, state, child) => AppShell(child: child),
        routes: [
          GoRoute(
            path: '/dashboard',
            builder: (_, __) => const DashboardScreen(),
          ),
          GoRoute(
            path: '/entries',
            builder: (_, __) => const EntriesMenuScreen(),
          ),
          GoRoute(
            path: '/material-receive',
            builder: (_, __) => const MaterialReceiveScreen(),
          ),
          GoRoute(
            path: '/production',
            builder: (_, __) => const ProductionScreen(),
          ),
          GoRoute(
            path: '/machine-downtime',
            builder: (_, __) => const MachineDowntimeScreen(),
          ),
          GoRoute(
            path: '/bp-inspection',
            builder: (_, __) => const BpInspectionScreen(),
          ),
          GoRoute(
            path: '/dispatch-faco',
            builder: (_, __) => const DispatchFacoScreen(),
          ),
          GoRoute(
            path: '/receive-faco',
            builder: (_, __) => const ReceiveFacoScreen(),
          ),
          GoRoute(
            path: '/ap-inspection',
            builder: (_, __) => const ApInspectionScreen(),
          ),
          GoRoute(path: '/rtv', builder: (_, __) => const RtvScreen()),
          GoRoute(
            path: '/final-dispatch',
            builder: (_, __) => const FinalDispatchScreen(),
          ),
          GoRoute(path: '/search', builder: (_, __) => const SearchScreen()),
          GoRoute(path: '/reports', builder: (_, __) => const ReportsScreen()),
          GoRoute(
            path: '/reports/live-stock',
            builder: (_, state) => LiveStockReport(
              partId: state.uri.queryParameters['partId'],
            ),
          ),
          GoRoute(
            path: '/notifications',
            builder: (_, __) => const NotificationsScreen(),
          ),
          GoRoute(
            path: '/settings',
            builder: (_, __) => const SettingsScreen(),
          ),
          GoRoute(
            path: '/corrections',
            builder: (_, __) => const CorrectionsScreen(),
          ),
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

String? _moduleForLocation(String location) {
  const modules = {
    '/material-receive': 'material_receive',
    '/production': 'production',
    '/machine-downtime': 'machine_downtime',
    '/bp-inspection': 'bp_inspection',
    '/dispatch-faco': 'dispatch_faco',
    '/receive-faco': 'receive_faco',
    '/ap-inspection': 'ap_inspection',
    '/rtv': 'rtv',
    '/final-dispatch': 'final_dispatch',
  };
  return modules[location];
}

bool _isOwnerOnlyLocation(String location) {
  return location == '/settings' || location == '/corrections';
}

class _AuthChangeNotifier extends ChangeNotifier {
  _AuthChangeNotifier(Ref ref) {
    _sub = ref.listen<AsyncValue<dynamic>>(currentUserProvider, (_, __) {
      notifyListeners();
    });
    _recoverySub = ref.listen<bool>(passwordRecoveryPendingProvider, (_, __) {
      notifyListeners();
    });
  }

  late final ProviderSubscription<AsyncValue<dynamic>> _sub;
  late final ProviderSubscription<bool> _recoverySub;

  @override
  void dispose() {
    _sub.close();
    _recoverySub.close();
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
                  Icon(
                    Icons.lock_outline,
                    size: 48,
                    color: theme.colorScheme.outline,
                  ),
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
          : GridView.builder(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 1.12,
              ),
              itemCount: entries.length,
              itemBuilder: (context, index) {
                final entry = entries[index];
                final colors = [
                  const Color(0xFF789FD5),
                  const Color(0xFF77A682),
                  const Color(0xFFD39A39),
                  const Color(0xFFD77E8B),
                ];
                return SoftActionTile(
                  title: entry.title,
                  subtitle: entry.subtitle,
                  icon: entry.icon,
                  color: colors[index % colors.length],
                  onTap: () => context.push(entry.route),
                );
              },
            ),
    );
  }

  List<_EntryItem> _entriesForRole(UserRole? role) {
    final all = [
      const _EntryItem(
        'Material Receive',
        'Raw material intake',
        '/material-receive',
        Icons.inventory_2,
        'material_receive',
      ),
      const _EntryItem(
        'Daily Production',
        'Machine production entry',
        '/production',
        Icons.precision_manufacturing,
        'production',
      ),
      const _EntryItem(
        'Machine Downtime',
        'Breakdown & maintenance',
        '/machine-downtime',
        Icons.build,
        'machine_downtime',
      ),
      const _EntryItem(
        'BP Inspection',
        'Pre-plating QC',
        '/bp-inspection',
        Icons.fact_check,
        'bp_inspection',
      ),
      const _EntryItem(
        'Dispatch to Faco',
        'Send to plating vendor',
        '/dispatch-faco',
        Icons.local_shipping,
        'dispatch_faco',
      ),
      const _EntryItem(
        'Receive from Faco',
        'Receive plated material',
        '/receive-faco',
        Icons.move_to_inbox,
        'receive_faco',
      ),
      const _EntryItem(
        'AP Inspection',
        'Post-plating QC',
        '/ap-inspection',
        Icons.verified,
        'ap_inspection',
      ),
      const _EntryItem('RTV', 'Return to vendor', '/rtv', Icons.undo, 'rtv'),
      const _EntryItem(
        'Final Dispatch',
        'Ship to customer',
        '/final-dispatch',
        Icons.send,
        'final_dispatch',
      ),
    ];

    if (role == null) return [];
    if (role == UserRole.admin || role == UserRole.owner) return all;
    return all.where((e) => role.canAccessModule(e.module)).toList();
  }
}

class _EntryItem {
  const _EntryItem(
    this.title,
    this.subtitle,
    this.route,
    this.icon,
    this.module,
  );
  final String title;
  final String subtitle;
  final String route;
  final IconData icon;
  final String module;
}
