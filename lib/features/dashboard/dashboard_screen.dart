import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/app_user.dart';
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
        leading: user != null
            ? Padding(
                padding: const EdgeInsets.all(8),
                child: _buildUserAvatar(user),
              )
            : null,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'FactoryFlow',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
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
              // ── First-time setup banner ──
              if (data.rawMaterial == 0 &&
                  data.bpStock == 0 &&
                  data.todayProduction == 0)
                _buildSetupBanner(context),

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

  Widget _buildUserAvatar(AppUser user) {
    if (user.avatarUrl != null && user.avatarUrl!.isNotEmpty) {
      return CircleAvatar(
        backgroundImage: NetworkImage(user.avatarUrl!),
        onBackgroundImageError: (_, __) {},
        child: null,
      );
    }
    return const CircleAvatar(
      child: Icon(Icons.person, size: 20),
    );
  }

  Widget _buildSetupBanner(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.blue.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.blue.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.rocket_launch_outlined,
            color: Colors.blue,
            size: 28,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Welcome to FactoryFlow!',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.blue,
                  ),
                ),
                const SizedBox(height: 2),
                const Text(
                  'Get started by adding Parts and initial stock in Settings.',
                  style: TextStyle(fontSize: 12, color: Colors.blue),
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: () => context.go('/settings'),
                  icon: const Icon(Icons.settings_outlined, size: 16),
                  label: const Text('Go to Settings'),
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.blue,
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                  ),
                ),
              ],
            ),
          ),
        ],
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
    final isDark = theme.brightness == Brightness.dark;
    final eff = data.targetEfficiency;
    final displayEff =
        eff.isNaN || eff.isInfinite ? 0.0 : eff.clamp(0.0, 100.0);
    final effColor = displayEff >= 80
        ? const Color(0xFF1E9E8F)
        : displayEff >= 50
            ? const Color(0xFFE09F3E)
            : const Color(0xFFCF3030);
    final qualityOk = data.totalRejectPct <= 5.0;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          colors: isDark
              ? [const Color(0xFF1A2540), const Color(0xFF161B22)]
              : [const Color(0xFF2B4C7E), const Color(0xFF3D6494)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color:
                const Color(0xFF2B4C7E).withValues(alpha: isDark ? 0.4 : 0.3),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          // ── Circular arc gauge ──
          SizedBox(
            width: 100,
            height: 100,
            child: CustomPaint(
              painter: _ArcGaugePainter(
                progress: displayEff / 100,
                color: effColor,
                trackColor: Colors.white.withValues(alpha: 0.12),
              ),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${displayEff.toStringAsFixed(0)}%',
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        height: 1,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'efficiency',
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.white.withValues(alpha: 0.6),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 20),
          // ── Stats ──
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Today's Output",
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.white.withValues(alpha: 0.6),
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 4),
                RichText(
                  text: TextSpan(
                    children: [
                      TextSpan(
                        text: _fmt(data.todayProduction),
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          height: 1,
                        ),
                      ),
                      TextSpan(
                        text: ' / ${_fmt(data.todayTarget)} PCS',
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.white.withValues(alpha: 0.55),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                // ── Quality pill ──
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    _StatPill(
                      label: qualityOk ? 'Quality OK' : 'High Reject',
                      value: '${data.totalRejectPct.toStringAsFixed(1)}%',
                      color: qualityOk
                          ? const Color(0xFF1E9E8F)
                          : const Color(0xFFCF3030),
                      icon: qualityOk
                          ? Icons.check_circle_outline
                          : Icons.warning_amber_rounded,
                    ),
                    const SizedBox(width: 8),
                    _StatPill(
                      label: 'Dispatched',
                      value: _fmt(data.todayDispatch),
                      color: Colors.white.withValues(alpha: 0.7),
                      icon: Icons.send_outlined,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMachineStatusSection(BuildContext context, DashboardData data) {
    final theme = Theme.of(context);
    if (data.machineStatuses.isEmpty) return const SizedBox.shrink();

    final runningCount = data.machinesRunning;
    final total = data.totalMachines;
    final allRunning = runningCount == total;

    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header row ──
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.precision_manufacturing_outlined,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Machine Status',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: allRunning
                        ? const Color(0xFF1E9E8F).withValues(alpha: 0.1)
                        : Colors.orange.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: allRunning
                          ? const Color(0xFF1E9E8F).withValues(alpha: 0.4)
                          : Colors.orange.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Text(
                    '$runningCount / $total Running',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color:
                          allRunning ? const Color(0xFF1E9E8F) : Colors.orange,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            // ── Machine cards ──
            ...data.machineStatuses.map((m) {
              final isRunning = m.status == 'Running';
              final isBreakdown = m.status == 'Breakdown';
              final statusColor = isRunning
                  ? const Color(0xFF1E9E8F)
                  : isBreakdown
                      ? const Color(0xFFCF3030)
                      : const Color(0xFFE09F3E);
              final statusIcon = isRunning
                  ? Icons.play_circle_outline
                  : isBreakdown
                      ? Icons.error_outline
                      : Icons.pause_circle_outline;

              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    // Status dot
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: statusColor,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: statusColor.withValues(alpha: 0.5),
                            blurRadius: 4,
                            spreadRadius: 1,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    // Machine name
                    Expanded(
                      flex: 3,
                      child: Text(
                        m.name,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w500),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    // Qty
                    Text(
                      '${_fmt(m.todayQty)} pcs',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(width: 10),
                    // Status badge
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(statusIcon, size: 11, color: statusColor),
                          const SizedBox(width: 4),
                          Text(
                            m.status,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: statusColor,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildWeeklyChart(BuildContext context, DashboardData data) {
    final theme = Theme.of(context);
    if (data.weeklyData.isEmpty) return const SizedBox.shrink();

    final maxVal =
        data.weeklyData.map((d) => d.qty).reduce((a, b) => a > b ? a : b);
    final limit = maxVal == 0 ? 100.0 : maxVal;
    final todayIndex = data.weeklyData.length - 1;

    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header ──
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.bar_chart_rounded,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  'Weekly Output',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                Text(
                  '7-day trend',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            // ── Bars ──
            SizedBox(
              height: 140,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: List.generate(data.weeklyData.length, (i) {
                  final d = data.weeklyData[i];
                  final ratio = (d.qty / limit).clamp(0.0, 1.0);
                  final barH = ratio * 96 + 4;
                  final isToday = i == todayIndex;
                  final barColor = isToday
                      ? theme.colorScheme.primary
                      : theme.colorScheme.primary.withValues(alpha: 0.35);

                  return Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          // qty label — only show if > 0
                          if (d.qty > 0)
                            Text(
                              _fmt(d.qty),
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight:
                                    isToday ? FontWeight.w700 : FontWeight.w500,
                                color: isToday
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.onSurfaceVariant,
                              ),
                            )
                          else
                            const SizedBox(height: 12),
                          const SizedBox(height: 3),
                          // Bar
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 600),
                            curve: Curves.easeOut,
                            width: double.infinity,
                            height: barH,
                            decoration: BoxDecoration(
                              borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(6),
                              ),
                              color: barColor,
                              boxShadow: isToday
                                  ? [
                                      BoxShadow(
                                        color: theme.colorScheme.primary
                                            .withValues(alpha: 0.3),
                                        blurRadius: 8,
                                        offset: const Offset(0, 3),
                                      ),
                                    ]
                                  : null,
                            ),
                          ),
                          const SizedBox(height: 6),
                          // Day label
                          Text(
                            d.dayLabel,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight:
                                  isToday ? FontWeight.w700 : FontWeight.w400,
                              color: isToday
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          // Today dot
                          if (isToday) ...[
                            const SizedBox(height: 3),
                            Container(
                              width: 4,
                              height: 4,
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primary,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                }),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStockGrid(BuildContext context, DashboardData data) {
    final theme = Theme.of(context);
    final stocks = [
      _StockEntry(
        'Raw Material',
        data.rawMaterial,
        Icons.inventory_2_outlined,
        const Color(0xFF795548),
      ),
      _StockEntry(
        'Bending WIP',
        data.bendingWip,
        Icons.rotate_right,
        const Color(0xFFF57F17),
      ),
      _StockEntry(
        'Notching WIP',
        data.notchingWip,
        Icons.content_cut,
        const Color(0xFFE65100),
      ),
      _StockEntry(
        'End Forming WIP',
        data.endFormingWip,
        Icons.change_circle_outlined,
        const Color(0xFFBF360C),
      ),
      _StockEntry(
        'Prod. Rejected',
        data.productionRejected,
        Icons.cancel_outlined,
        const Color(0xFFCF3030),
      ),
      _StockEntry(
        'BP Stock',
        data.bpStock,
        Icons.check_circle_outline,
        const Color(0xFF2B4C7E),
      ),
      _StockEntry(
        'BP Rejected',
        data.bpRejected,
        Icons.cancel_outlined,
        const Color(0xFFCF3030),
      ),
      _StockEntry(
        'At Faco (Plating)',
        data.atFaco,
        Icons.local_shipping_outlined,
        const Color(0xFF6A1B9A),
      ),
      _StockEntry(
        'Pending AP Insp.',
        data.pendingAp,
        Icons.hourglass_top_outlined,
        const Color(0xFF283593),
      ),
      _StockEntry(
        'AP Approved',
        data.approvedAp,
        Icons.verified_outlined,
        const Color(0xFF1E9E8F),
      ),
      _StockEntry(
        'AP Rejected',
        data.apRejected,
        Icons.warning_amber_outlined,
        const Color(0xFFE64A19),
      ),
      _StockEntry(
        'RTV Outstanding',
        data.rtvStock,
        Icons.undo,
        const Color(0xFFCF3030),
      ),
    ];

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 1.75,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: stocks.length,
      itemBuilder: (context, i) {
        final s = stocks[i];
        return Container(
          decoration: BoxDecoration(
            color: theme.cardTheme.color ?? theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: theme.dividerColor,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Stack(
              children: [
                // Left accent bar
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: Container(
                    width: 4,
                    color: s.color,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(5),
                            decoration: BoxDecoration(
                              color: s.color.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(7),
                            ),
                            child: Icon(s.icon, color: s.color, size: 13),
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Text(
                              s.label,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.w600,
                              ),
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _fmt(s.qty),
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.onSurface,
                          height: 1,
                        ),
                      ),
                      Text(
                        'PCS',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant
                              .withValues(alpha: 0.6),
                          fontSize: 9,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildTodayGrid(BuildContext context, DashboardData data) {
    final theme = Theme.of(context);
    final items = [
      _StockEntry(
        'Production',
        data.todayProduction,
        Icons.precision_manufacturing,
        const Color(0xFF1E9E8F),
      ),
      _StockEntry(
        'BP Reject',
        data.todayBpReject,
        Icons.cancel_outlined,
        const Color(0xFFCF3030),
      ),
      _StockEntry(
        'AP Reject',
        data.todayApReject,
        Icons.remove_circle_outline,
        const Color(0xFFE64A19),
      ),
      _StockEntry(
        'Dispatched',
        data.todayDispatch,
        Icons.send_outlined,
        const Color(0xFF2B4C7E),
      ),
    ];

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 1.75,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final s = items[i];
        return Container(
          decoration: BoxDecoration(
            color: s.color.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: s.color.withValues(alpha: 0.2),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: s.color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(s.icon, color: s.color, size: 15),
              ),
              const SizedBox(height: 8),
              Text(
                _fmt(s.qty),
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: s.color,
                  height: 1,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                s.label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w500,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildKpiList(BuildContext context, DashboardData data) {
    final theme = Theme.of(context);

    final kpis = [
      _KpiEntry(
        label: 'Overall Reject Rate',
        value: '${data.totalRejectPct.toStringAsFixed(1)}%',
        icon: Icons.trending_down_rounded,
        color: data.totalRejectPct > 5.0
            ? const Color(0xFFCF3030)
            : const Color(0xFF1E9E8F),
        isAlert: data.totalRejectPct > 5.0,
        subtitle: data.totalRejectPct > 5.0
            ? 'Above 5% threshold'
            : 'Within acceptable range',
      ),
      _KpiEntry(
        label: 'At Faco (Plating)',
        value: '${_fmt(data.atFaco)} PCS',
        icon: Icons.local_shipping_outlined,
        color: data.atFaco > 500
            ? const Color(0xFFE09F3E)
            : const Color(0xFF2B4C7E),
        isAlert: data.atFaco > 500,
        subtitle: data.atFaco > 500 ? 'High volume at vendor' : 'At vendor',
      ),
      _KpiEntry(
        label: 'Pending AP Inspection',
        value: '${_fmt(data.pendingAp)} PCS',
        icon: Icons.hourglass_top_outlined,
        color: data.pendingAp > 200
            ? const Color(0xFFE09F3E)
            : const Color(0xFF283593),
        isAlert: data.pendingAp > 200,
        subtitle:
            data.pendingAp > 200 ? 'Needs attention' : 'Awaiting inspection',
      ),
      _KpiEntry(
        label: 'RTV Outstanding',
        value: '${_fmt(data.rtvStock)} PCS',
        icon: Icons.undo_rounded,
        color: data.rtvStock > 0
            ? const Color(0xFFCF3030)
            : const Color(0xFF1E9E8F),
        isAlert: data.rtvStock > 0,
        subtitle: data.rtvStock > 0 ? 'Return to vendor pending' : 'All clear',
      ),
      if (data.pendingApprovals > 0)
        _KpiEntry(
          label: 'Pending Approvals',
          value: '${data.pendingApprovals}',
          icon: Icons.pending_actions_outlined,
          color: const Color(0xFFCF3030),
          isAlert: true,
          subtitle: 'Correction requests waiting',
        ),
    ];

    return Column(
      children: kpis.map((k) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Container(
            decoration: BoxDecoration(
              color: theme.cardTheme.color ?? theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: theme.dividerColor),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                // Icon box
                Container(
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    color: k.color.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(k.icon, color: k.color, size: 18),
                ),
                const SizedBox(width: 14),
                // Label + subtitle
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        k.label,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        k.subtitle,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant
                              .withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // Value + alert dot
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      k.value,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: k.color,
                      ),
                    ),
                    if (k.isAlert) ...[
                      const SizedBox(height: 3),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: k.color.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'Alert',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            color: k.color,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildQuickActions(BuildContext context) {
    final theme = Theme.of(context);
    final actions = [
      const _QuickAction(
        'Production',
        Icons.precision_manufacturing,
        '/production',
        Color(0xFF1E9E8F),
      ),
      const _QuickAction(
        'Material Receive',
        Icons.inventory_2_outlined,
        '/material-receive',
        Color(0xFF795548),
      ),
      const _QuickAction(
        'BP Inspection',
        Icons.fact_check_outlined,
        '/bp-inspection',
        Color(0xFF2B4C7E),
      ),
      const _QuickAction(
        'Dispatch Faco',
        Icons.local_shipping_outlined,
        '/dispatch-faco',
        Color(0xFFE09F3E),
      ),
    ];

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 2.8,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: actions.length,
      itemBuilder: (context, i) {
        final a = actions[i];
        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => context.push(a.route),
            borderRadius: BorderRadius.circular(14),
            child: Container(
              decoration: BoxDecoration(
                color: theme.cardTheme.color ?? theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: theme.dividerColor),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: a.color.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(a.icon, color: a.color, size: 18),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      a.label,
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurface,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Icon(
                    Icons.arrow_forward_ios_rounded,
                    size: 12,
                    color: theme.colorScheme.onSurfaceVariant
                        .withValues(alpha: 0.4),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  String _fmt(double v) =>
      v == v.toInt() ? v.toInt().toString() : v.toStringAsFixed(1);
}

// ── Arc Gauge Painter ────────────────────────────────────────────────────────
class _ArcGaugePainter extends CustomPainter {
  const _ArcGaugePainter({
    required this.progress,
    required this.color,
    required this.trackColor,
  });
  final double progress;
  final Color color;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    const startAngle = 2.356; // 135 degrees in radians
    const sweepAngle = 4.712; // 270 degrees
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width / 2) - 8;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final trackPaint = Paint()
      ..color = trackColor
      ..strokeWidth = 8
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final progressPaint = Paint()
      ..color = color
      ..strokeWidth = 8
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(rect, startAngle, sweepAngle, false, trackPaint);
    if (progress > 0) {
      canvas.drawArc(
        rect,
        startAngle,
        sweepAngle * progress.clamp(0.0, 1.0),
        false,
        progressPaint,
      );
    }
  }

  @override
  bool shouldRepaint(_ArcGaugePainter old) =>
      old.progress != progress || old.color != color;
}

// ── Stat Pill ─────────────────────────────────────────────────────────────────
class _StatPill extends StatelessWidget {
  const _StatPill({
    required this.label,
    required this.value,
    required this.color,
    required this.icon,
  });
  final String label;
  final String value;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 5),
          Text(
            '$label: $value',
            style: TextStyle(
              fontSize: 11,
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _KpiEntry {
  const _KpiEntry({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    required this.isAlert,
    required this.subtitle,
  });
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  final bool isAlert;
  final String subtitle;
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
