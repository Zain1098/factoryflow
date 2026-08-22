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

/// One part's current balances across the factory pipeline. Keeping the
/// dashboard view model part-scoped prevents a large total from hiding which
/// component actually needs attention.
class DashboardPartStock {
  const DashboardPartStock({
    required this.partId,
    required this.partCode,
    required this.partName,
    required this.stageBalances,
  });

  final String partId;
  final String partCode;
  final String partName;
  final Map<String, double> stageBalances;

  double get totalStock =>
      stageBalances.values.fold<double>(0, (total, balance) => total + balance);
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
    required this.partStocks,
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
  final List<DashboardPartStock> partStocks;

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
    partStocks: [],
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
  // Both normal vendor processing and RTV vendor returns are physically with
  // vendors; the dashboard headline must not hide the latter.
  final atFaco = (stageTotals[StockStage.atFaco.value] ?? 0.0) +
      (stageTotals[StockStage.rtvAtVendor.value] ?? 0.0);
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

  // Build the dashboard stock view from the same per-part balances used by
  // operational screens. Totals remain available for KPIs, while the UI can
  // now show exactly which part is sitting at each stage.
  final stageLabels = <String, String>{
    StockStage.rawMaterial.value: 'Raw Material',
    kProductionRejectedStage: 'Production Rejected',
    StockStage.bpStock.value: 'BP Stock',
    StockStage.bpRejected.value: 'BP Rejected',
    StockStage.atFaco.value: 'At Faco',
    StockStage.pendingAp.value: 'Pending AP',
    StockStage.approvedAp.value: 'AP Approved',
    StockStage.apRejected.value: 'AP Rejected',
    StockStage.rtvStock.value: 'RTV',
  };
  if (sequence.isNotEmpty) {
    stageLabels[productionWipStage(sequence[0])] = 'Bending WIP';
  }
  if (sequence.length > 1) {
    stageLabels[productionWipStage(sequence[1])] = 'Notching WIP';
  }
  if (sequence.length > 2) {
    stageLabels[productionWipStage(sequence[2])] = 'End Forming WIP';
  }

  final perStageRows = await Future.wait(
    stageLabels.keys.map((stage) => db.getBalancesByStage(stage)),
  );
  final partStockRows = <String, Map<String, dynamic>>{};
  for (var index = 0; index < perStageRows.length; index++) {
    final stage = stageLabels.keys.elementAt(index);
    for (final row in perStageRows[index]) {
      final partId = row['id'] as String;
      final part = partStockRows.putIfAbsent(
        partId,
        () => {
          'code': row['code'] as String? ?? '',
          'name': row['name'] as String? ?? 'Unnamed part',
          'balances': <String, double>{},
        },
      );
      (part['balances'] as Map<String, double>)[stage] =
          (row['balance'] as num?)?.toDouble() ?? 0;
    }
  }
  final partStocks = partStockRows.entries
      .map(
        (entry) => DashboardPartStock(
          partId: entry.key,
          partCode: entry.value['code'] as String,
          partName: entry.value['name'] as String,
          stageBalances: Map.unmodifiable(
            entry.value['balances'] as Map<String, double>,
          ),
        ),
      )
      .toList()
    ..sort((a, b) => a.partName.compareTo(b.partName));

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
    partStocks: partStocks,
  );
});
