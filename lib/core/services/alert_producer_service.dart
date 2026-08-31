import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database_service.dart';
import '../providers/production_flow_provider.dart';
import '../services/notification_service.dart';

final alertProducerServiceProvider = Provider<AlertProducerService>((ref) {
  // Target alerts must use the same completed-production definition as the
  // dashboard. Waiting here avoids treating a saved multi-stage setup as the
  // default single-stage setup during app startup.
  return AlertProducerService(
    ref.watch(databaseServiceProvider),
    productionFlow: () => ref.read(productionFlowProvider),
    ensureProductionFlowLoaded: () =>
        ref.read(productionFlowProvider.notifier).ensureLoaded(),
  );
});

/// Checks business conditions and fires local notifications when thresholds
/// are crossed. Called after stock-changing transactions and on app resume.
/// Never blocks the calling transaction — all failures are swallowed.
class AlertProducerService {
  AlertProducerService(
    this._db, {
    ProductionFlowConfig Function()? productionFlow,
    Future<void> Function()? ensureProductionFlowLoaded,
  })  : _productionFlow = productionFlow,
        _ensureProductionFlowLoaded = ensureProductionFlowLoaded;

  final DatabaseService _db;
  final ProductionFlowConfig Function()? _productionFlow;
  final Future<void> Function()? _ensureProductionFlowLoaded;

  static const double _lowStockThreshold = 50;

  Future<void> checkAll() async {
    await Future.wait([
      _checkLowStock(),
      _checkRtvPending(),
      checkTargetMiss(),
      _checkOpenDowntime(),
    ]);
  }

  Future<void> checkLowStock() => _checkLowStock();
  Future<void> checkRtvPending() => _checkRtvPending();
  Future<void> checkTargetMiss() async {
    final ensureFlowLoaded = _ensureProductionFlowLoaded;
    if (ensureFlowLoaded != null) await ensureFlowLoaded();
    await _checkTargetMiss();
  }
  Future<void> checkOpenDowntime() => _checkOpenDowntime();

  Future<void> _checkLowStock() async {
    try {
      final factoryId = _db.activeWorkspaceId;
      if (factoryId.isEmpty) return;
      final rows = _db.db.select(
        '''SELECT p.name, COALESCE(sl.running_balance, 0) AS balance
           FROM parts p
           LEFT JOIN stock_ledger sl ON sl.factory_id = p.factory_id
             AND sl.part_id = p.id AND sl.stage = 'approved_ap'
             AND sl.rowid = (
               SELECT c.rowid FROM stock_ledger c
               WHERE c.factory_id = p.factory_id
                 AND c.part_id = p.id AND c.stage = 'approved_ap'
               ORDER BY c.created_at DESC, c.rowid DESC LIMIT 1
             )
           WHERE p.factory_id = ? AND p.active = 1
             AND COALESCE(sl.running_balance, 0) > 0
             AND COALESCE(sl.running_balance, 0) < ?''',
        [factoryId, _lowStockThreshold],
      );
      for (final row in rows) {
        final partName = row['name'] as String;
        final balance = (row['balance'] as num).toDouble();
        await NotificationService.instance.showLowStock(
          partName,
          balance,
        );
        await _db.insertInAppNotification(
          title: 'Low Stock Alert: $partName',
          body: '$partName is low on approved stock ($balance PCS remaining). Consider receiving or producing more.',
          type: 'low_stock',
          actionRoute: '/reports/stock',
          factoryId: factoryId,
        );
      }
    } catch (_) {}
  }

  Future<void> _checkRtvPending() async {
    try {
      final factoryId = _db.activeWorkspaceId;
      if (factoryId.isEmpty) return;
      final rows = _db.db.select(
        "SELECT COUNT(*) as cnt FROM rtvs "
        "WHERE factory_id = ? AND status IN ('sent','partially_received')",
        [factoryId],
      );
      final count = rows.first['cnt'] as int;
      if (count > 0) {
        await NotificationService.instance.showRtvPending(count);
        await _db.insertInAppNotification(
          title: 'RTV Pending from Vendors',
          body: '$count batch(es) are currently with vendor for rework/replacement.',
          type: 'rtv',
          actionRoute: '/rtv',
          factoryId: factoryId,
        );
      }
    } catch (_) {}
  }

  Future<void> _checkTargetMiss() async {
    try {
      final factoryId = _db.activeWorkspaceId;
      if (factoryId.isEmpty) return;
      final now = DateTime.now();
      final todayStr =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      final dayOfWeek = now.weekday % 7;
      final targetRow = _db.db.select(
        'SELECT COALESCE(SUM(target_qty),0) AS total FROM target_master '
        'WHERE factory_id = ? AND day_of_week = ?',
        [factoryId, dayOfWeek],
      );
      final target = (targetRow.first['total'] as num?)?.toDouble() ?? 0;
      if (target <= 0) return;
      final flow = _productionFlow?.call();
      final finalMachineId = flow != null &&
              flow.isMultiStage &&
              flow.requiredMachineIds.isNotEmpty
          ? flow.requiredMachineIds.last
          : null;
      final summary = await _db.getTodayProductionSummary(
        todayStr,
        finalMachineId: finalMachineId,
        countAllStageOutput: flow?.countsAllStageOutput ?? false,
      );
      final produced = summary['production'] ?? 0;
      if (produced < target * 0.8) {
        final pct = (produced / target * 100).toStringAsFixed(0);
        await NotificationService.instance.showAlert(
          id: 5,
          title: 'Target Behind',
          body:
              'Today: ${produced.toInt()} / ${target.toInt()} PCS ($pct%)',
          preferenceKey: 'notif_production',
        );
        await _db.insertInAppNotification(
          title: 'Production Target Alert',
          body: 'Production is running behind target today (${produced.toInt()} / ${target.toInt()} PCS, $pct%).',
          type: 'target',
          actionRoute: '/production',
          factoryId: factoryId,
        );
      }
    } catch (_) {}
  }

  Future<void> _checkOpenDowntime() async {
    try {
      final factoryId = _db.activeWorkspaceId;
      if (factoryId.isEmpty) return;
      final rows = _db.db.select(
        'SELECT m.name FROM machine_downtimes md '
        'INNER JOIN machines m ON m.id = md.machine_id '
        'AND m.factory_id = md.factory_id '
        'WHERE md.factory_id = ? AND md.end_time IS NULL '
        'ORDER BY md.start_time DESC LIMIT 1',
        [factoryId],
      );
      if (rows.isNotEmpty) {
        final mName = rows.first['name'] as String;
        await NotificationService.instance
            .showMachineBreakdown(mName);
        await _db.insertInAppNotification(
          title: 'Machine Breakdown: $mName',
          body: '$mName is currently halted in breakdown/maintenance.',
          type: 'downtime',
          actionRoute: '/machine-downtime',
          factoryId: factoryId,
        );
      }
    } catch (_) {}
  }
}
