import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/stock_stages.dart';
import '../../core/database/database_service.dart';
import '../../core/providers/production_flow_provider.dart';

class DashboardMachineStatus {
  const DashboardMachineStatus({
    required this.name,
    required this.status,
    required this.todayQty,
  });
  final String name;
  final String status;
  final double todayQty;
}

class DashboardWeeklyData {
  const DashboardWeeklyData({
    required this.dayLabel,
    required this.qty,
  });
  final String dayLabel;
  final double qty;
}

class DashboardData {
  const DashboardData({
    required this.rawMaterial,
    required this.bendingWip,
    required this.notchingWip,
    required this.endFormingWip,
    required this.bpStock,
    required this.bpRejected,
    required this.atFaco,
    required this.pendingAp,
    required this.approvedAp,
    required this.apRejected,
    required this.rtvStock,
    required this.productionRejected,
    required this.todayProduction,
    required this.todayBpReject,
    required this.todayApReject,
    required this.todayDispatch,
    required this.pendingSyncCount,
    required this.todayTarget,
    required this.machinesRunning,
    required this.totalMachines,
    required this.pendingApprovals,
    required this.machineStatuses,
    required this.weeklyData,
  });

  final double rawMaterial;
  final double bendingWip;
  final double notchingWip;
  final double endFormingWip;
  final double bpStock;
  final double bpRejected;
  final double atFaco;
  final double pendingAp;
  final double approvedAp;
  final double apRejected;
  final double rtvStock;
  final double productionRejected;
  final double todayProduction;
  final double todayBpReject;
  final double todayApReject;
  final double todayDispatch;
  final int pendingSyncCount;
  final double todayTarget;
  final int machinesRunning;
  final int totalMachines;
  final int pendingApprovals;
  final List<DashboardMachineStatus> machineStatuses;
  final List<DashboardWeeklyData> weeklyData;

  static const empty = DashboardData(
    rawMaterial: 0,
    bendingWip: 0,
    notchingWip: 0,
    endFormingWip: 0,
    bpStock: 0,
    bpRejected: 0,
    atFaco: 0,
    pendingAp: 0,
    approvedAp: 0,
    apRejected: 0,
    rtvStock: 0,
    productionRejected: 0,
    todayProduction: 0,
    todayBpReject: 0,
    todayApReject: 0,
    todayDispatch: 0,
    pendingSyncCount: 0,
    todayTarget: 0,
    machinesRunning: 3,
    totalMachines: 3,
    pendingApprovals: 0,
    machineStatuses: [],
    weeklyData: [],
  );

  double get totalRejectPct {
    final denom = todayProduction;
    if (denom == 0) return 0;
    return ((todayBpReject + todayApReject) / denom) * 100;
  }

  double get targetEfficiency {
    if (todayTarget == 0) return 0;
    return (todayProduction / todayTarget) * 100;
  }
}

// ─── Dashboard Provider ───────────────────────────────────────────────────────

final dashboardProvider = FutureProvider<DashboardData>((ref) async {
  final db = ref.watch(databaseServiceProvider);
  // Register the dependency before awaiting, then use the loaded value below.
  // Without this, the initial default (single-stage) state can briefly sum all
  // machine entries for a saved multi-stage factory configuration.
  ref.watch(productionFlowProvider);
  await ref.read(productionFlowProvider.notifier).ensureLoaded();
  final flow = ref.read(productionFlowProvider);
  final factoryId = db.activeWorkspaceId;
  if (factoryId.isEmpty) return DashboardData.empty;

  final today = DateTime.now();
  final todayStr =
      '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';

  // Stock balances
  final stageTotals = await db.getAllStageTotals();
  final rawMaterial = stageTotals[StockStage.rawMaterial.value] ?? 0.0;
  final bpStock = stageTotals[StockStage.bpStock.value] ?? 0.0;
  final bpRejected = stageTotals[StockStage.bpRejected.value] ?? 0.0;
  final atFaco = stageTotals[StockStage.atFaco.value] ?? 0.0;
  final pendingAp = stageTotals[StockStage.pendingAp.value] ?? 0.0;
  final approvedAp = stageTotals[StockStage.approvedAp.value] ?? 0.0;
  final apRejected = stageTotals[StockStage.apRejected.value] ?? 0.0;
  final rtvStock = stageTotals[StockStage.rtvStock.value] ?? 0.0;
  final productionRejected = stageTotals[kProductionRejectedStage] ?? 0.0;

  // Read WIP from the stock ledger, rather than inferring it from production
  // history. This preserves correct quantities when a stage has rejects or a
  // batch is processed across multiple days.
  final sequence = flow.requiredMachineIds;
  final bendingWip = sequence.isNotEmpty
      ? await db.getTotalBalanceByStage(productionWipStage(sequence[0]))
      : 0.0;
  final notchingWip = sequence.length > 1
      ? await db.getTotalBalanceByStage(productionWipStage(sequence[1]))
      : 0.0;
  final endFormingWip = sequence.length > 2
      ? await db.getTotalBalanceByStage(productionWipStage(sequence[2]))
      : 0.0;

  // Today's production totals
  final finalMachineId =
      flow.isMultiStage && sequence.isNotEmpty ? sequence.last : null;
  final todaySummary = await db.getTodayProductionSummary(
    todayStr,
    finalMachineId: finalMachineId,
    countAllStageOutput: flow.countsAllStageOutput,
  );
  final todayProd = todaySummary['production'] ?? 0;
  final todayBp = todaySummary['bp_reject'] ?? 0;
  final todayAp = todaySummary['ap_reject'] ?? 0;
  final todayDisp = todaySummary['dispatched'] ?? 0;

  // Pending sync count
  final syncCount = await db.countPendingSync();

  // Active targets for today
  final weekday = today.weekday % 7; // Sunday=0, Monday=1 ... Saturday=6
  final todayTarget = await db.getTodayTarget(weekday);

  // Machine list and statuses
  final machinesList = db.db.select(
    'SELECT id, name FROM machines WHERE factory_id = ? AND active = 1',
    [factoryId],
  );
  final List<DashboardMachineStatus> machineStatuses = [];
  int machinesRunning = 0;

  for (final m in machinesList) {
    final mId = m['id'] as String;
    final mName = m['name'] as String;

    // Check if currently down today (has downtime entry with null end_time)
    final downtime = db.db.select(
      'SELECT id FROM machine_downtimes '
      'WHERE factory_id = ? AND machine_id = ? AND date = ? '
      'AND end_time IS NULL LIMIT 1',
      [factoryId, mId, todayStr],
    );

    // Sum of today's production on this machine
    final mProd = db.db.select(
      'SELECT SUM(production_qty) as qty FROM productions '
      'WHERE factory_id = ? AND machine_id = ? AND date = ?',
      [factoryId, mId, todayStr],
    );
    final mQty = (mProd.first['qty'] as num?)?.toDouble() ?? 0.0;

    String status = 'Running';
    if (downtime.isNotEmpty) {
      status = 'Breakdown';
    } else if (mQty == 0) {
      status = 'Idle';
    }

    if (status == 'Running') {
      machinesRunning++;
    }

    machineStatuses.add(
      DashboardMachineStatus(
        name: mName,
        status: status,
        todayQty: mQty,
      ),
    );
  }

  final totalMachines = machineStatuses.length;

  // Weekly data (last 7 days production)
  final List<DashboardWeeklyData> weeklyData = [];
  for (int i = 6; i >= 0; i--) {
    final dateVal = today.subtract(Duration(days: i));
    final dStr =
        '${dateVal.year}-${dateVal.month.toString().padLeft(2, '0')}-${dateVal.day.toString().padLeft(2, '0')}';
    final dLabel = '${dateVal.day}/${dateVal.month}';

    final wProd = db.db.select(
      'SELECT COALESCE(SUM(CASE '
      'WHEN ? = 1 THEN good_qty '
      'WHEN (? IS NULL OR machine_id = ?) THEN good_qty ELSE 0 END), 0) as qty '
      'FROM productions WHERE factory_id = ? AND date = ?',
      [
        flow.countsAllStageOutput ? 1 : 0,
        finalMachineId,
        finalMachineId,
        factoryId,
        dStr,
      ],
    );
    final wQty = (wProd.first['qty'] as num?)?.toDouble() ?? 0.0;

    weeklyData.add(DashboardWeeklyData(dayLabel: dLabel, qty: wQty));
  }

  // Pending approvals
  final pendingCorrectionRows = db.db.select(
    "SELECT COUNT(*) as cnt FROM correction_requests "
    "WHERE factory_id = ? AND status = 'pending'",
    [factoryId],
  );
  final pendingApprovals =
      (pendingCorrectionRows.first['cnt'] as num?)?.toInt() ?? 0;

  return DashboardData(
    rawMaterial: rawMaterial,
    bendingWip: bendingWip,
    notchingWip: notchingWip,
    endFormingWip: endFormingWip,
    bpStock: bpStock,
    bpRejected: bpRejected,
    atFaco: atFaco,
    pendingAp: pendingAp,
    approvedAp: approvedAp,
    apRejected: apRejected,
    rtvStock: rtvStock,
    productionRejected: productionRejected,
    todayProduction: todayProd,
    todayBpReject: todayBp,
    todayApReject: todayAp,
    todayDispatch: todayDisp,
    pendingSyncCount: syncCount,
    todayTarget: todayTarget,
    machinesRunning: machinesRunning,
    totalMachines: totalMachines,
    pendingApprovals: pendingApprovals,
    machineStatuses: machineStatuses,
    weeklyData: weeklyData,
  );
});
