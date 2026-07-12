import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/sync_service.dart';
import '../../core/widgets/shared_widgets.dart';
import '../auth/auth_providers.dart';
import 'dashboard_providers.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dashAsync = ref.watch(dashboardProvider);
    final user = ref.watch(currentUserProvider).value;
    final syncCount = ref.watch(pendingSyncCountProvider);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('FactoryFlow', style: TextStyle(fontWeight: FontWeight.bold)),
            if (user != null)
              Text(
                '${user.name} · ${user.role.value}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        actions: [
          syncCount.when(
            data: (count) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: SyncBadge(count: count),
            ),
            loading: () => const SizedBox.shrink(),
            error: (_, __) => const SizedBox.shrink(),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(dashboardProvider),
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: dashAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(
          message: 'Could not load dashboard.\n$e',
          icon: Icons.error_outline,
          action: FilledButton(
            onPressed: () => ref.invalidate(dashboardProvider),
            child: const Text('Retry'),
          ),
        ),
        data: (data) => RefreshIndicator(
          onRefresh: () async => ref.invalidate(dashboardProvider),
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              // ── Stock Pipeline ──
              _sectionLabel(context, 'Live Stock Pipeline'),
              _stockGrid(context, data),

              // ── Today's Production ──
              _sectionLabel(context, "Today's Activity"),
              _todayGrid(context, data),

              // ── KPIs ──
              _sectionLabel(context, 'Key Metrics'),
              _kpiList(context, data),

              // ── Quick Actions ──
              _sectionLabel(context, 'Quick Entry'),
              _quickActions(context),

              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionLabel(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 20, top: 16, bottom: 4),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _stockGrid(BuildContext context, DashboardData data) {
    final stocks = [
      _StockEntry('Raw Material', data.rawMaterial, Icons.inventory_2_outlined, Colors.brown),
      _StockEntry('BP Stock', data.bpStock, Icons.check_circle_outline, Colors.blue),
      _StockEntry('At Faco', data.atFaco, Icons.local_shipping_outlined, Colors.orange),
      _StockEntry('Pending AP', data.pendingAp, Icons.hourglass_empty, Colors.purple),
      _StockEntry('Approved AP', data.approvedAp, Icons.verified_outlined, Colors.green),
      _StockEntry('RTV Stock', data.rtvStock, Icons.undo, Colors.red),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          childAspectRatio: 1.4,
          crossAxisSpacing: 0,
          mainAxisSpacing: 0,
        ),
        itemCount: stocks.length,
        itemBuilder: (context, i) {
          final s = stocks[i];
          return StockCard(
            label: s.label,
            value: _fmt(s.qty),
            icon: s.icon,
            color: s.color,
            subtitle: 'PCS',
          );
        },
      ),
    );
  }

  Widget _todayGrid(BuildContext context, DashboardData data) {
    final items = [
      _StockEntry("Production", data.todayProduction, Icons.precision_manufacturing, Colors.teal),
      _StockEntry("BP Reject", data.todayBpReject, Icons.cancel_outlined, Colors.red),
      _StockEntry("AP Reject", data.todayApReject, Icons.remove_circle_outline, Colors.deepOrange),
      _StockEntry("Dispatched", data.todayDispatch, Icons.send_outlined, Colors.indigo),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          childAspectRatio: 1.4,
        ),
        itemCount: items.length,
        itemBuilder: (context, i) {
          final s = items[i];
          return StockCard(
            label: s.label,
            value: _fmt(s.qty),
            icon: s.icon,
            color: s.color,
            subtitle: 'Today',
          );
        },
      ),
    );
  }

  Widget _kpiList(BuildContext context, DashboardData data) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          KpiTile(
            label: 'Overall Reject %',
            value: '${data.totalRejectPct.toStringAsFixed(1)}%',
            icon: Icons.trending_down,
            isAlert: data.totalRejectPct > 5,
          ),
          const SizedBox(height: 8),
          KpiTile(
            label: 'At Faco (Pending Return)',
            value: _fmt(data.atFaco),
            icon: Icons.pending_outlined,
            isAlert: data.atFaco > 500,
          ),
          const SizedBox(height: 8),
          KpiTile(
            label: 'RTV Pending Reinspection',
            value: _fmt(data.rtvStock),
            icon: Icons.undo,
            isAlert: data.rtvStock > 0,
          ),
        ],
      ),
    );
  }

  Widget _quickActions(BuildContext context) {
    final actions = [
      const _QuickAction('Production', Icons.precision_manufacturing, '/production', Colors.teal),
      const _QuickAction('Material\nReceive', Icons.inventory_2, '/material-receive', Colors.brown),
      const _QuickAction('BP\nInspection', Icons.fact_check, '/bp-inspection', Colors.blue),
      const _QuickAction('Dispatch\nFaco', Icons.local_shipping, '/dispatch-faco', Colors.orange),
    ];

    return SizedBox(
      height: 100,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: actions.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (context, i) {
          final a = actions[i];
          return InkWell(
            onTap: () => context.go(a.route),
            borderRadius: BorderRadius.circular(12),
            child: Container(
              width: 90,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: a.color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: a.color.withValues(alpha: 0.3)),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(a.icon, color: a.color, size: 28),
                  const SizedBox(height: 8),
                  Text(
                    a.label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: a.color,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  String _fmt(double v) => v == v.toInt() ? v.toInt().toString() : v.toStringAsFixed(1);
}

class _StockEntry {
  const _StockEntry(this.label, this.qty, this.icon, this.color);
  final String label;
  final double qty;
  final IconData icon;
  final Color color;
}

class _QuickAction {
  const _QuickAction(this.label, this.icon, this.route, this.color);
  final String label;
  final IconData icon;
  final String route;
  final Color color;
}
