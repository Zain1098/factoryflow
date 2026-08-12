import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/database/database_service.dart';
import '../../core/network/sync_service.dart';
import '../../core/constants/stock_stages.dart';
import '../../core/services/alert_producer_service.dart';
import '../../core/services/stock_ledger_service.dart';

const _uuid = Uuid();

class DispatchItemInput {
  const DispatchItemInput({
    required this.batchNumber,
    required this.partId,
    required this.partCode,
    required this.qty,
  });
  final String batchNumber;
  final String partId;
  final String partCode;
  final double qty;
}

class FinalDispatchRepository {
  FinalDispatchRepository(this._db, this._sync, this._ledger, this._alerts);

  final DatabaseService _db;
  final SyncService _sync;
  final StockLedgerService _ledger;
  final AlertProducerService _alerts;

  /// Save a multi-part dispatch session
  Future<FinalDispatchResult> saveDispatchSession({
    required String customerId,
    required List<DispatchItemInput> items,
    String? vehicleId,
    String? driverId,
    String? challanNumber,
    String? remarks,
    required String createdBy,
    DateTime? recordedAt,
  }) async {
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) {
      return const FinalDispatchResult(
        success: false,
        error: 'No active factory workspace is selected.',
      );
    }
    if (items.isEmpty) {
      return const FinalDispatchResult(
        success: false,
        error: 'Add at least one dispatch item.',
      );
    }

    final requestedByPart = <String, double>{};
    final requestedByBatchPart = <String, double>{};
    final partCodeById = <String, String>{};
    for (final item in items) {
      if (item.batchNumber.trim().isEmpty) {
        return FinalDispatchResult(
          success: false,
          error: '${item.partCode}: Original batch number is required.',
        );
      }
      if (item.qty <= 0) {
        return FinalDispatchResult(
          success: false,
          error:
              '${item.partCode}: Dispatch quantity must be greater than zero.',
        );
      }
      requestedByPart[item.partId] =
          (requestedByPart[item.partId] ?? 0) + item.qty;
      final batchKey = '${item.batchNumber}|${item.partId}';
      requestedByBatchPart[batchKey] =
          (requestedByBatchPart[batchKey] ?? 0) + item.qty;
      partCodeById[item.partId] = item.partCode;
    }

    for (final entry in requestedByBatchPart.entries) {
      final separator = entry.key.indexOf('|');
      final batchNumber = entry.key.substring(0, separator);
      final partId = entry.key.substring(separator + 1);
      final rows = _db.db.select(
        '''SELECT
             COALESCE((
               SELECT SUM(ai.approved_qty)
               FROM ap_inspections ai
               WHERE ai.factory_id = ? AND ai.batch_number = ?
                 AND ai.part_id = ?
             ), 0) -
             COALESCE((
               SELECT SUM(di.dispatch_qty)
               FROM dispatch_items di
               WHERE di.factory_id = ? AND di.batch_number = ?
                 AND di.part_id = ?
             ), 0) AS available_qty''',
        [
          factoryId,
          batchNumber,
          partId,
          factoryId,
          batchNumber,
          partId,
        ],
      );
      final batchAvailable =
          (rows.single['available_qty'] as num?)?.toDouble() ?? 0;
      if (entry.value > batchAvailable) {
        return FinalDispatchResult(
          success: false,
          error:
              '$batchNumber: Dispatch qty (${entry.value.toInt()}) exceeds batch AP OK stock (${batchAvailable.toInt()} PCS)',
        );
      }
    }

    for (final entry in requestedByPart.entries) {
      final available =
          await _ledger.getAvailableStock(entry.key, StockStage.approvedAp);
      if (entry.value > available) {
        return FinalDispatchResult(
          success: false,
          error:
              '${partCodeById[entry.key]}: Dispatch qty (${entry.value.toInt()}) exceeds AP OK stock (${available.toInt()} PCS)',
        );
      }
    }

    final sessionId = _uuid.v4();
    final now = recordedAt ?? DateTime.now();
    final dateStr =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final timeStr =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    // Auto-generate challan if not provided
    final challan = challanNumber ?? _generateChallan(dateStr);

    final sessionRecord = {
      'id': sessionId,
      'factory_id': factoryId,
      'date': dateStr,
      'time': timeStr,
      'customer_id': customerId,
      'vehicle_id': vehicleId,
      'driver_id': driverId,
      'challan_number': challan,
      'remarks': remarks,
      'created_by': createdBy,
      'sync_status': 'pending',
    };

    try {
      await _db.runInTransaction(() async {
        await _db.insertRecord('dispatch_sessions', sessionRecord);
        await _sync.queueInsert(
          tableName: 'dispatch_sessions',
          recordId: sessionId,
          payload: sessionRecord,
          triggerSync: false,
        );

        for (final item in items) {
          final itemId = _uuid.v4();
          final itemRecord = {
            'id': itemId,
            'session_id': sessionId,
            'factory_id': factoryId,
            'part_id': item.partId,
            'batch_number': item.batchNumber,
            'dispatch_qty': item.qty,
            'sync_status': 'pending',
          };
          final ledgerResult = await _ledger.finalDispatch(
            partId: item.partId,
            qty: item.qty,
            refId: itemId,
            triggerSync: false,
          );
          if (!ledgerResult.success) {
            throw StockPostingFailure(
              ledgerResult.error ?? 'Unable to update AP OK stock.',
            );
          }

          await _db.insertRecord('dispatch_items', itemRecord);
          await _sync.queueInsert(
            tableName: 'dispatch_items',
            recordId: itemId,
            payload: itemRecord,
            triggerSync: false,
          );
        }
      });
    } on StockPostingFailure catch (error) {
      return FinalDispatchResult(success: false, error: error.message);
    } catch (_) {
      return const FinalDispatchResult(
        success: false,
        error:
            'Final dispatch could not be saved. No stock was changed. Please retry.',
      );
    }

    await _sync.schedulePendingSync();
    unawaited(_alerts.checkLowStock());
    return FinalDispatchResult(
      success: true,
      recordId: sessionId,
      challanNumber: challan,
    );
  }

  String _generateChallan(String dateStr) {
    final factoryId = _db.activeWorkspaceId.trim();
    final existing = _db.db.select(
      'SELECT COUNT(*) as cnt FROM dispatch_sessions '
      'WHERE factory_id = ? AND date = ?',
      [factoryId, dateStr],
    );
    final seq = (existing.first['cnt'] as int) + 1;
    final compact = dateStr.replaceAll('-', '');
    return 'DC-$compact-${seq.toString().padLeft(3, '0')}';
  }

  /// Returns dispatch sessions with their items, grouped for history view
  Future<List<Map<String, dynamic>>> getRecent({int limit = 30}) async {
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) return [];
    final sessions = _db.db.select(
      '''SELECT ds.*, c.name as customer_name,
                v.number_plate as vehicle_plate, d.name as driver_name
         FROM dispatch_sessions ds
         LEFT JOIN customers c ON c.id = ds.customer_id AND c.factory_id = ds.factory_id
         LEFT JOIN vehicles v ON v.id = ds.vehicle_id AND v.factory_id = ds.factory_id
         LEFT JOIN drivers d ON d.id = ds.driver_id AND d.factory_id = ds.factory_id
         WHERE ds.factory_id = ?
         ORDER BY ds.date DESC, ds.time DESC LIMIT ?''',
      [factoryId, limit],
    );

    final result = <Map<String, dynamic>>[];
    for (final session in sessions) {
      final items = _db.db.select(
        '''SELECT di.*, p.code as part_code, p.name as part_name
           FROM dispatch_items di
           LEFT JOIN parts p ON p.id = di.part_id AND p.factory_id = di.factory_id
           WHERE di.factory_id = ? AND di.session_id = ?
           ORDER BY p.name''',
        [factoryId, session['id']],
      );
      final map = Map<String, dynamic>.from(session);
      map['items'] = items.map((r) => Map<String, dynamic>.from(r)).toList();
      result.add(map);
    }
    return result;
  }

  Future<String?> getDefaultCustomerId() async {
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) return null;
    final rows = _db.db.select(
      'SELECT id FROM customers '
      'WHERE factory_id = ? AND is_default = 1 LIMIT 1',
      [factoryId],
    );
    if (rows.isEmpty) return null;
    return rows.first['id'] as String;
  }

  Future<List<Map<String, dynamic>>> getApprovedBatches() async {
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) return [];
    final rows = _db.db.select(
      '''WITH approved AS (
           SELECT factory_id, batch_number, part_id,
                  SUM(approved_qty) AS approved_qty
           FROM ap_inspections
           WHERE factory_id = ?
           GROUP BY factory_id, batch_number, part_id
         ),
         dispatched AS (
           SELECT factory_id, batch_number, part_id,
                  SUM(dispatch_qty) AS dispatched_qty
           FROM dispatch_items
           WHERE factory_id = ? AND batch_number IS NOT NULL
           GROUP BY factory_id, batch_number, part_id
         )
         SELECT p.id, p.code, p.name, approved.batch_number,
                approved.approved_qty -
                  COALESCE(dispatched.dispatched_qty, 0) AS balance
         FROM approved
         INNER JOIN parts p ON p.id = approved.part_id
           AND p.factory_id = approved.factory_id
         LEFT JOIN dispatched
           ON dispatched.factory_id = approved.factory_id
          AND dispatched.batch_number = approved.batch_number
          AND dispatched.part_id = approved.part_id
         WHERE approved.approved_qty -
                 COALESCE(dispatched.dispatched_qty, 0) > 0
         ORDER BY approved.batch_number, p.code''',
      [factoryId, factoryId],
    );
    return rows.map((row) => Map<String, dynamic>.from(row)).toList();
  }
}

final finalDispatchRepositoryProvider =
    Provider<FinalDispatchRepository>((ref) {
  return FinalDispatchRepository(
    ref.watch(databaseServiceProvider),
    ref.watch(syncServiceProvider),
    ref.watch(stockLedgerServiceProvider),
    ref.watch(alertProducerServiceProvider),
  );
});

final finalDispatchListProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  return ref.watch(finalDispatchRepositoryProvider).getRecent();
});

final approvedDispatchBatchesProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  return ref.watch(finalDispatchRepositoryProvider).getApprovedBatches();
});

class FinalDispatchResult {
  const FinalDispatchResult({
    required this.success,
    this.error,
    this.recordId,
    this.challanNumber,
  });
  final bool success;
  final String? error;
  final String? recordId;
  final String? challanNumber;
}
