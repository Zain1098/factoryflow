import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/stock_stages.dart';
import '../../core/database/database_service.dart';
import '../../core/services/stock_ledger_service.dart';

// ─── Dashboard Data Model ─────────────────────────────────────────────────────

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

  static const empty = DashboardData(
    rawMaterial: 0, bpStock: 0, atFaco: 0, pendingAp: 0,
    approvedAp: 0, rtvStock: 0, todayProduction: 0, todayBpReject: 0,
    todayApReject: 0, todayDispatch: 0, pendingSyncCount: 0,
  );

  double get totalRejectPct {
    final denom = todayProduction;
    if (denom == 0) return 0;
    return ((todayBpReject + todayApReject) / denom) * 100;
  }
}

// ─── Dashboard Provider ───────────────────────────────────────────────────────

final dashboardProvider = FutureProvider<DashboardData>((ref) async {
  final ledger = ref.watch(stockLedgerServiceProvider);
  final db = ref.watch(databaseServiceProvider);

  final today = DateTime.now();
  final todayStr =
      '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';

  // Stock balances
  final rawMaterial = await ledger.getTotalStageBalance(StockStage.rawMaterial);
  final bpStock = await ledger.getTotalStageBalance(StockStage.bpStock);
  final atFaco = await ledger.getTotalStageBalance(StockStage.atFaco);
  final pendingAp = await ledger.getTotalStageBalance(StockStage.pendingAp);
  final approvedAp = await ledger.getTotalStageBalance(StockStage.approvedAp);
  final rtvStock = await ledger.getTotalStageBalance(StockStage.rtvStock);

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
  );
});
