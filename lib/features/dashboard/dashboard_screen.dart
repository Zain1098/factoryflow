import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/app_user.dart';
import '../../core/network/sync_service.dart';
import '../../core/widgets/app_shell.dart';
import '../../core/widgets/shared_widgets.dart';
import '../auth/auth_providers.dart';
import '../notifications/notification_providers.dart';
import 'dashboard_providers.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dashAsync = ref.watch(dashboardProvider);
    final user = ref.watch(currentUserProvider).value;
    final theme = Theme.of(context);
    final isOnline = ref.watch(isOnlineProvider);
    final pendingSync = ref.watch(pendingSyncCountProvider).value ?? 0;
    final unreadNotifs = ref.watch(unreadNotificationCountProvider).value ?? 0;

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
            Text(
              user == null ? 'FactoryFlow' : 'Hello, ${user.name}!',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
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
          IconButton(
            icon: const Icon(Icons.search_rounded),
            onPressed: () => GlobalQuickSearchSheet.show(context),
            tooltip: 'Quick Batch / Stock Search',
          ),
          SyncStatusButton(
            isOnline: isOnline,
            pendingCount: pendingSync,
            compact: true,
          ),
          IconButton(
            icon: Badge.count(
              count: unreadNotifs,
              isLabelVisible: unreadNotifs > 0,
              child: const Icon(Icons.notifications_none_rounded),
            ),
            onPressed: () => context.push('/notifications'),
            tooltip: 'Notifications',
          ),
        ],
      ),
      body: dashAsync.when(
        loading: () => const Padding(
          padding: EdgeInsets.all(16),
          child: Column(
            children: [
              SkeletonShimmerLoader(height: 120, borderRadius: 16),
              SizedBox(height: 16),
              Row(
                children: [
                  Expanded(child: SkeletonShimmerLoader(height: 90, borderRadius: 12)),
                  SizedBox(width: 12),
                  Expanded(child: SkeletonShimmerLoader(height: 90, borderRadius: 12)),
                ],
              ),
              SizedBox(height: 16),
              SkeletonShimmerLoader(height: 200, borderRadius: 16),
            ],
          ),
        ),
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
              _buildPastelOverview(context, data),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Quick entry',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => context.go('/entries'),
                    child: const Text('View all'),
                  ),
                ],
              ),
              _buildPastelQuickActions(context),
              const SizedBox(height: 14),
              // ── First-time setup banner ──
              if (data.rawMaterial == 0 &&
                  data.bpStock == 0 &&
                  data.todayProduction == 0)
                _buildSetupBanner(context),

              // ── Top Premium Efficiency Header ──
              _buildEfficiencyHeader(context, data),
              const SizedBox(height: 16),

              // ── Industrial OEE Overall Equipment Effectiveness ──
              _buildOeeCard(context, data),
              const SizedBox(height: 16),

              // ── Machine Status Row ──
              // ── Weekly Production Chart ──
              _buildWeeklyChart(context, data),
              const SizedBox(height: 16),

              // ── Live Stock Pipeline ──
              _buildSectionLabel(context, 'Live Stock by Part'),
              _buildPartStockList(context, data),
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
              _buildMachineStatusSection(context, data),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPastelOverview(BuildContext context, DashboardData data) {
    final efficiency = data.targetEfficiency.clamp(0.0, 100.0);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Today’s progress',
                    style: Theme.of(context).textTheme.titleSmall,),
                const SizedBox(height: 8),
                Text('${efficiency.toStringAsFixed(0)}%',
                    style: Theme.of(context)
                        .textTheme
                        .headlineMedium
                        ?.copyWith(fontWeight: FontWeight.w700),),
                Text(
                    '${_fmt(data.todayProduction)} of ${_fmt(data.todayTarget)} PCS target',
                    style: Theme.of(context).textTheme.bodySmall,),
                const SizedBox(height: 12),
                if (data.pendingSyncCount > 0)
                  Text(
                    '${data.pendingSyncCount} record(s) pending sync',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: scheme.onPrimaryContainer,
                        ),
                  ),
                if (data.pendingSyncCount > 0) const SizedBox(height: 8),
                FilledButton.tonalIcon(
                  onPressed: () => context.push('/production'),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Add production'),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 82,
            height: 82,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 76,
                  height: 76,
                  child: CircularProgressIndicator(
                    value: efficiency / 100,
                    strokeWidth: 8,
                    strokeCap: StrokeCap.round,
                    backgroundColor:
                        scheme.onPrimaryContainer.withValues(alpha: 0.16),
                    color: scheme.primary,
                  ),
                ),
                Text('${_fmt(data.todayProduction)} PCS',
                    style: Theme.of(context).textTheme.labelSmall,),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPastelQuickActions(BuildContext context) {
    final actions = [
      (
        'Production',
        'Record machine output',
        Icons.precision_manufacturing_outlined,
        '/production',
        const Color(0xFF789FD5)
      ),
      (
        'Material',
        'Receive raw stock',
        Icons.inventory_2_outlined,
        '/material-receive',
        const Color(0xFF77A682)
      ),
      (
        'Inspection',
        'Quality check',
        Icons.fact_check_outlined,
        '/bp-inspection',
        const Color(0xFFD39A39)
      ),
      (
        'Dispatch',
        'Send to customer',
        Icons.local_shipping_outlined,
        '/final-dispatch',
        const Color(0xFFD77E8B)
      ),
    ];
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 1.17,
      ),
      itemCount: actions.length,
      itemBuilder: (context, index) {
        final action = actions[index];
        return SoftActionTile(
          title: action.$1,
          subtitle: action.$2,
          icon: action.$3,
          color: action.$5,
          onTap: () => context.push(action.$4),
        );
      },
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
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(
            Icons.rocket_launch_outlined,
            color: scheme.primary,
            size: 28,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Welcome to FactoryFlow!',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Get started by adding Parts and initial stock in Settings.',
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: () => context.go('/settings'),
                  icon: const Icon(Icons.settings_outlined, size: 16),
                  label: const Text('Go to Settings'),
                  style: FilledButton.styleFrom(
                    backgroundColor: scheme.primary,
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

  Widget _buildOeeCard(BuildContext context, DashboardData data) {
    final theme = Theme.of(context);
    final oee = data.oeeScore;
    final oeeColor = oee >= 85
        ? const Color(0xFF1E9E8F)
        : oee >= 65
            ? const Color(0xFFE09F3E)
            : const Color(0xFFCF3030);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: theme.colorScheme.outlineVariant),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: oeeColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(Icons.analytics_outlined, color: oeeColor, size: 18),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Overall Equipment Effectiveness (OEE)',
                    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: oeeColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: oeeColor.withValues(alpha: 0.3)),
                ),
                child: Text(
                  '${oee.toStringAsFixed(1)}% OEE',
                  style: TextStyle(color: oeeColor, fontWeight: FontWeight.bold, fontSize: 12),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _buildOeePillar(
                  context,
                  title: 'Availability',
                  rate: data.availabilityRate * 100,
                  subtext: data.todayDowntimeMins > 0
                      ? '${data.todayDowntimeMins.toInt()}m downtime'
                      : '0m downtime',
                  color: data.availabilityRate >= 0.9 ? Colors.green : Colors.orange,
                  icon: Icons.timer_outlined,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildOeePillar(
                  context,
                  title: 'Performance',
                  rate: (data.performanceRate * 100).clamp(0.0, 100.0),
                  subtext: '${_fmt(data.todayProduction)} / ${_fmt(data.todayTarget)} PCS',
                  color: data.performanceRate >= 0.8 ? Colors.blue : Colors.amber.shade800,
                  icon: Icons.speed_rounded,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildOeePillar(
                  context,
                  title: 'Quality',
                  rate: data.qualityRate * 100,
                  subtext: '${(100 - data.totalRejectPct).clamp(0.0, 100.0).toStringAsFixed(1)}% yield',
                  color: data.qualityRate >= 0.95 ? Colors.teal : Colors.red,
                  icon: Icons.verified_user_outlined,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildOeePillar(
    BuildContext context, {
    required String title,
    required double rate,
    required String subtext,
    required Color color,
    required IconData icon,
  }) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.labelSmall?.copyWith(fontSize: 10, fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${rate.toStringAsFixed(0)}%',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: color,
              height: 1,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subtext,
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 9,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            overflow: TextOverflow.ellipsis,
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

  Widget _buildPartStockList(BuildContext context, DashboardData data) {
    final theme = Theme.of(context);
    if (data.partStocks.isEmpty) {
      return const EmptyState(
        icon: Icons.inventory_2_outlined,
        message: 'No active parts available yet.',
      );
    }

    return Column(
      children: data.partStocks.map((part) {
        final balances = part.stageBalances.entries
            .where((entry) => entry.value != 0)
            .toList();
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              onTap: () => context.push(
                '/reports/live-stock?partId=${Uri.encodeQueryComponent(part.partId)}',
              ),
              borderRadius: BorderRadius.circular(16),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: theme.cardTheme.color ?? theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: theme.dividerColor),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary
                                .withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            Icons.inventory_2_outlined,
                            color: theme.colorScheme.primary,
                            size: 18,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                part.partCode.isEmpty
                                    ? part.partName
                                    : part.partCode,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              if (part.partCode.isNotEmpty)
                                Text(
                                  part.partName,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                            ],
                          ),
                        ),
                        Text(
                          '${_fmt(part.totalStock)} PCS',
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          Icons.chevron_right_rounded,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (balances.isEmpty)
                      Text(
                        'No stock recorded',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      )
                    else
                      Wrap(
                        spacing: 7,
                        runSpacing: 7,
                        children: balances
                            .map(
                              (entry) => _PartStockPill(
                                label: _stockStageLabel(entry.key),
                                qty: entry.value,
                              ),
                            )
                            .toList(),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  String _stockStageLabel(String stage) {
    const labels = {
      'raw_material': 'Raw',
      'production_rejected': 'Prod reject',
      'bp_stock': 'BP',
      'bp_rejected': 'BP reject',
      'at_faco': 'At Vendor',
      'pending_ap': 'Pending AP',
      'approved_ap': 'AP approved',
      'ap_rejected': 'AP reject',
      'rtv_stock': 'RTV',
    };
    if (stage.startsWith('production_wip_')) return 'WIP';
    return labels[stage] ?? stage;
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
        label: 'At Vendor',
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

class _PartStockPill extends StatelessWidget {
  const _PartStockPill({required this.label, required this.qty});

  final String label;
  final double qty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        '$label ${qty == qty.toInt() ? qty.toInt() : qty.toStringAsFixed(1)}',
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
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

