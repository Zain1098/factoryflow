import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/stock_stages.dart';
import '../../core/database/database_service.dart';
import '../../core/services/stock_ledger_service.dart';

class DashboardData {
  const DashboardData({
    required this.rawMaterial,
    required this.bpStock,
    required this.atFaco,
    required this.pendingAp,
    required this.approvedAp,
    required this.rtvStock,
    required this.todayProduction,
    required this.todayBpReject,
    required this.todayApReject,
    required this.todayDispatch,
    required this.pendingSyncCount,
    required this.todayTarget,
    required this.machinesRunning,
    required this.totalMachines,
    required this.pendingApprovals,
  });

  final double rawMaterial;
  final double bpStock;
  final double atFaco;
  final double pendingAp;
  final double approvedAp;
  final double rtvStock;
  final double todayProduction;
  final double todayBpReject;
  final double todayApReject;
  final double todayDispatch;
  final int pendingSyncCount;
  final double todayTarget;
  final int machinesRunning;
  final int totalMachines;
  final int pendingApprovals;

  static const empty = DashboardData(
    rawMaterial: 0, bpStock: 0, atFaco: 0, pendingAp: 0,
    approvedAp: 0, rtvStock: 0, todayProduction: 0, todayBpReject: 0,
    todayApReject: 0, todayDispatch: 0, pendingSyncCount: 0,
    todayTarget: 500, machinesRunning: 3, totalMachines: 3, pendingApprovals: 0,
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
  final ledger = ref.watch(stockLedgerServiceProvider);
  final db = ref.watch(databaseServiceProvider);

  final today = DateTime.now();
  final todayStr =
      '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';

  // Stock balances (bulk query in a single DB round-trip)
  final stageTotals = await db.getAllStageTotals();
  final rawMaterial = stageTotals[StockStage.rawMaterial.value] ?? 0.0;
  final bpStock = stageTotals[StockStage.bpStock.value] ?? 0.0;
  final atFaco = stageTotals[StockStage.atFaco.value] ?? 0.0;
  final pendingAp = stageTotals[StockStage.pendingAp.value] ?? 0.0;
  final approvedAp = stageTotals[StockStage.approvedAp.value] ?? 0.0;
  final rtvStock = stageTotals[StockStage.rtvStock.value] ?? 0.0;

  // Today's production totals
  final prodRows = db.db.select(
    "SELECT SUM(production_qty) as total_prod, SUM(bp_reject_qty) as total_bp FROM productions WHERE date = ?",
    [todayStr],
  );
  final todayProd = (prodRows.first['total_prod'] as num?)?.toDouble() ?? 0;
  final todayBp = (prodRows.first['total_bp'] as num?)?.toDouble() ?? 0;

  // Today's AP rejects
  final apRows = db.db.select(
    "SELECT SUM(rejected_qty) as total_ap FROM ap_inspections WHERE date = ?",
    [todayStr],
  );
  final todayAp = (apRows.first['total_ap'] as num?)?.toDouble() ?? 0;

  // Today's dispatches
  final dispRows = db.db.select(
    "SELECT SUM(dispatch_qty) as total FROM final_dispatches WHERE date = ?",
    [todayStr],
  );
  final todayDisp = (dispRows.first['total'] as num?)?.toDouble() ?? 0;

  // Pending sync count
  final syncCount = await db.countPendingSync();

  // 1. Get active targets for today (mapped to DB day_of_week)
  final weekday = today.weekday % 7; // Sunday=0, Monday=1, etc.
  final targetRows = db.db.select(
    "SELECT SUM(target_qty) as total_target FROM target_master WHERE day_of_week = ?",
    [weekday],
  );
  final todayTarget = (targetRows.first['total_target'] as num?)?.toDouble() ?? 500.0;

  // 2. Machine monitoring status
  final activeMachinesCountRows = db.db.select(
    "SELECT COUNT(*) as cnt FROM machines WHERE active = 1",
  );
  final totalMachines = (activeMachinesCountRows.first['cnt'] as num?)?.toInt() ?? 3;

  final activeDowntimes = db.db.select(
    "SELECT COUNT(DISTINCT machine_id) as cnt FROM machine_downtimes WHERE date = ? AND end_time IS NULL",
    [todayStr],
  );
  final machinesDown = (activeDowntimes.first['cnt'] as num?)?.toInt() ?? 0;
  final machinesRunning = (totalMachines - machinesDown).clamp(0, totalMachines);

  // 3. Pending approvals
  final pendingCorrectionRows = db.db.select(
    "SELECT COUNT(*) as cnt FROM correction_requests WHERE status = 'pending'",
  );
  final pendingApprovals = (pendingCorrectionRows.first['cnt'] as num?)?.toInt() ?? 0;

  return DashboardData(
    rawMaterial: rawMaterial,
    bpStock: bpStock,
    atFaco: atFaco,
    pendingAp: pendingAp,
    approvedAp: approvedAp,
    rtvStock: rtvStock,
    todayProduction: todayProd,
    todayBpReject: todayBp,
    todayApReject: todayAp,
    todayDispatch: todayDisp,
    pendingSyncCount: syncCount,
    todayTarget: todayTarget,
    machinesRunning: machinesRunning,
    totalMachines: totalMachines,
    pendingApprovals: pendingApprovals,
  );
});
