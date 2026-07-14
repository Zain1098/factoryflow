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
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('FactoryFlow', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            if (user != null)
              Text(
                '${user.name} · ${user.role.value}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
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
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            children: [
              // ── Top Premium Efficiency Header ──
              _buildEfficiencyHeader(context, data),
              const SizedBox(height: 16),

              // ── Machine Status Row ──
              _buildMachineStatusSection(context, data),
              const SizedBox(height: 16),

              // ── Weekly Production Chart ──
              _buildWeeklyChart(context, data),
              const SizedBox(height: 16),

              // ── Live Stock Pipeline ──
              _buildSectionLabel(context, 'Live Stock Pipeline'),
              _buildStockGrid(context, data),
              const SizedBox(height: 16),

              // ── Today's Activity ──
              _buildSectionLabel(context, "Today's Activity"),
              _buildTodayGrid(context, data),
              const SizedBox(height: 16),

              // ── Key Metrics & Alerts ──
              _buildSectionLabel(context, 'Key Metrics'),
              _buildKpiList(context, data),
              const SizedBox(height: 16),

              // ── Quick Actions ──
              _buildSectionLabel(context, 'Quick Entry'),
              _buildQuickActions(context),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionLabel(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, top: 8, bottom: 8),
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

  Widget _buildEfficiencyHeader(BuildContext context, DashboardData data) {
    final theme = Theme.of(context);
    final eff = data.targetEfficiency;
    final displayEff = eff.isNaN || eff.isInfinite ? 0.0 : eff;

    return Card(
      margin: EdgeInsets.zero,
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            colors: [
              theme.colorScheme.primaryContainer,
              theme.colorScheme.surface,
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Today\'s Production Efficiency',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onPrimaryContainer.withValues(alpha: 0.8),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${_fmt(data.todayProduction)} / ${_fmt(data.todayTarget)} PCS',
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ],
                ),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.speed,
                    color: theme.colorScheme.primary,
                    size: 28,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: (displayEff / 100).clamp(0.0, 1.0),
                minHeight: 10,
                backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.1),
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${displayEff.toStringAsFixed(1)}% of Today\'s Target',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onPrimaryContainer.withValues(alpha: 0.8),
                  ),
                ),
                Text(
                  data.totalRejectPct > 5.0 ? 'High Rejection Alert' : 'Healthy Quality',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: data.totalRejectPct > 5.0 ? Colors.red : Colors.green,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMachineStatusSection(BuildContext context, DashboardData data) {
    final theme = Theme.of(context);
    if (data.machineStatuses.isEmpty) return const SizedBox.shrink();

    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.precision_manufacturing_outlined, size: 20),
                const SizedBox(width: 8),
                Text(
                  'Machines Running status',
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                Text(
                  '${data.machinesRunning} / ${data.totalMachines} Running',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: data.machineStatuses.map((m) {
                  final color = m.status == 'Running'
                      ? Colors.green
                      : m.status == 'Breakdown'
                          ? Colors.red
                          : Colors.amber;
                  return Container(
                    margin: const EdgeInsets.only(right: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: color.withValues(alpha: 0.25)),
                    ),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 5,
                          backgroundColor: color,
                        ),
                        const SizedBox(width: 8),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              m.name,
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                            ),
                            Text(
                              '${m.status} · ${_fmt(m.todayQty)} pcs',
                              style: const TextStyle(fontSize: 10, color: Colors.grey),
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWeeklyChart(BuildContext context, DashboardData data) {
    final theme = Theme.of(context);
    if (data.weeklyData.isEmpty) return const SizedBox.shrink();

    final maxVal = data.weeklyData.map((d) => d.qty).reduce((a, b) => a > b ? a : b);
    final limit = maxVal == 0 ? 100.0 : maxVal;

    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Weekly Output Trend',
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 120,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: data.weeklyData.map((d) {
                  final ratio = (d.qty / limit).clamp(0.0, 1.0);
                  final barHeight = ratio * 80 + 4; // minimum height to show something

                  return Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text(
                        _fmt(d.qty),
                        style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      Container(
                        width: 14,
                        height: barHeight,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(4),
                          gradient: LinearGradient(
                            colors: [
                              theme.colorScheme.primary,
                              theme.colorScheme.primary.withValues(alpha: 0.5),
                            ],
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        d.dayLabel,
                        style: const TextStyle(fontSize: 10, color: Colors.grey),
                      ),
                    ],
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStockGrid(BuildContext context, DashboardData data) {
    final stocks = [
      _StockEntry('Raw Material', data.rawMaterial, Icons.inventory_2_outlined, Colors.brown),
      _StockEntry('BP Stock', data.bpStock, Icons.check_circle_outline, Colors.blue),
      _StockEntry('At Faco', data.atFaco, Icons.local_shipping_outlined, Colors.orange),
      _StockEntry('Pending AP', data.pendingAp, Icons.hourglass_empty, Colors.purple),
      _StockEntry('Approved AP', data.approvedAp, Icons.verified_outlined, Colors.green),
      _StockEntry('AP Rejected', data.apRejected, Icons.warning_amber_outlined, Colors.deepOrange),
      _StockEntry('RTV Stock', data.rtvStock, Icons.undo, Colors.red),
    ];

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 1.8,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: stocks.length,
      itemBuilder: (context, i) {
        final s = stocks[i];
        return Card(
          margin: EdgeInsets.zero,
          elevation: 0.5,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: Colors.grey.withValues(alpha: 0.15)),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  children: [
                    Icon(s.icon, color: s.color, size: 16),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        s.label,
                        style: const TextStyle(fontSize: 11, color: Colors.grey, fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '${_fmt(s.qty)} PCS',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildTodayGrid(BuildContext context, DashboardData data) {
    final items = [
      _StockEntry("Production", data.todayProduction, Icons.precision_manufacturing, Colors.teal),
      _StockEntry("BP Reject", data.todayBpReject, Icons.cancel_outlined, Colors.red),
      _StockEntry("AP Reject", data.todayApReject, Icons.remove_circle_outline, Colors.deepOrange),
      _StockEntry("Dispatched", data.todayDispatch, Icons.send_outlined, Colors.indigo),
    ];

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 1.8,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final s = items[i];
        return Card(
          margin: EdgeInsets.zero,
          elevation: 0.5,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: Colors.grey.withValues(alpha: 0.15)),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  children: [
                    Icon(s.icon, color: s.color, size: 16),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        s.label,
                        style: const TextStyle(fontSize: 11, color: Colors.grey, fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '${_fmt(s.qty)} PCS',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildKpiList(BuildContext context, DashboardData data) {
    return Column(
      children: [
        KpiTile(
          label: 'Overall Reject %',
          value: '${data.totalRejectPct.toStringAsFixed(1)}%',
          icon: Icons.trending_down,
          isAlert: data.totalRejectPct > 5.0,
        ),
        const SizedBox(height: 8),
        KpiTile(
          label: 'At Faco (Plating Vendor)',
          value: '${_fmt(data.atFaco)} PCS',
          icon: Icons.pending_outlined,
          isAlert: data.atFaco > 500.0,
        ),
        const SizedBox(height: 8),
        KpiTile(
          label: 'RTV Reinspection Stock',
          value: '${_fmt(data.rtvStock)} PCS',
          icon: Icons.undo,
          isAlert: data.rtvStock > 0.0,
        ),
      ],
    );
  }

  Widget _buildQuickActions(BuildContext context) {
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
        itemCount: actions.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (context, i) {
          final a = actions[i];
          return InkWell(
            onTap: () => context.go(a.route),
            borderRadius: BorderRadius.circular(16),
            child: Container(
              width: 95,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: a.color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(16),
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
                      fontWeight: FontWeight.bold,
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
