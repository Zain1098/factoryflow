import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database_service.dart';
import '../services/notification_service.dart';

final alertProducerServiceProvider = Provider<AlertProducerService>((ref) {
  return AlertProducerService(ref.watch(databaseServiceProvider));
});

/// Checks business conditions and fires local notifications when thresholds
/// are crossed. Called after stock-changing transactions and on app resume.
/// Never blocks the calling transaction — all failures are swallowed.
class AlertProducerService {
  AlertProducerService(this._db);

  final DatabaseService _db;

  static const double _lowStockThreshold = 50;

  Future<void> checkAll() async {
    await Future.wait([
      _checkLowStock(),
      _checkRtvPending(),
      _checkTargetMiss(),
      _checkOpenDowntime(),
    ]);
  }

  Future<void> checkLowStock() => _checkLowStock();
  Future<void> checkRtvPending() => _checkRtvPending();
  Future<void> checkTargetMiss() => _checkTargetMiss();
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
        await NotificationService.instance.showLowStock(
          row['name'] as String,
          (row['balance'] as num).toDouble(),
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
      if (count > 0) await NotificationService.instance.showRtvPending(count);
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
      final prodRow = _db.db.select(
        'SELECT COALESCE(SUM(good_qty),0) AS total FROM productions '
        'WHERE factory_id = ? AND date = ?',
        [factoryId, todayStr],
      );
      final produced = (prodRow.first['total'] as num?)?.toDouble() ?? 0;
      if (produced < target * 0.8) {
        await NotificationService.instance.showAlert(
          id: 5,
          title: 'Target Behind',
          body:
              'Today: ${produced.toInt()} / ${target.toInt()} PCS (${(produced / target * 100).toStringAsFixed(0)}%)',
          preferenceKey: 'notif_production',
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
        await NotificationService.instance
            .showMachineBreakdown(rows.first['name'] as String);
      }
    } catch (_) {}
  }
}
