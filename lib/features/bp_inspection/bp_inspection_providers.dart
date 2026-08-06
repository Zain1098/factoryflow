import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/database/database_service.dart';
import '../../core/network/sync_service.dart';
import '../../core/constants/stock_stages.dart';
import '../../core/services/stock_ledger_service.dart';

import '../../core/providers/master_data_providers.dart';

const _uuid = Uuid();

// Fallback reasons used only when DB has no configured reasons yet.
const kBpRejectReasonsFallback = [
  'Crack',
  'Dimension Out of Tolerance',
  'Bend Angle Error',
  'Surface Scratch',
  'Burr/Sharp Edge',
  'Deformation',
  'Incomplete Forming',
];

/// Live BP reject reasons from DB, falling back to defaults.
final bpRejectReasonsListProvider = FutureProvider<List<String>>((ref) async {
  final rows = await ref.watch(bpRejectReasonsProvider.future);
  if (rows.isEmpty) return kBpRejectReasonsFallback;
  return rows.map((r) => r['reason'] as String).toList();
});

class BpInspectionRepository {
  BpInspectionRepository(this._db, this._sync, this._ledger);

  final DatabaseService _db;
  final SyncService _sync;
  final StockLedgerService _ledger;

  Future<BpInspectionResult> save({
    required String batchNumber,
    required String partId,
    required String machineId,
    required double inspectedQty,
    required double bpRejectQty,
    String? rejectReason,
    required String inspectorId,
    String? remarks,
    DateTime? recordedAt,
  }) async {
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) {
      return const BpInspectionResult(
        success: false,
        error: 'No active factory workspace is selected.',
      );
    }
    if (inspectedQty <= 0) {
      return const BpInspectionResult(
        success: false,
        error: 'Hold / inspected quantity must be greater than zero.',
      );
    }
    if (bpRejectQty < 0) {
      return const BpInspectionResult(
        success: false,
        error: 'Reject quantity cannot be negative.',
      );
    }
    if (bpRejectQty > inspectedQty) {
      return BpInspectionResult(
        success: false,
        error:
            'Reject qty ($bpRejectQty) cannot exceed hold qty ($inspectedQty).',
      );
    }
    if (bpRejectQty > 0 &&
        (rejectReason == null || rejectReason.trim().isEmpty)) {
      return const BpInspectionResult(
        success: false,
        error:
            'Reject reason is required when reject quantity is greater than zero.',
      );
    }
    if (batchNumber.trim().isEmpty) {
      return const BpInspectionResult(
        success: false,
        error: 'Original Production batch is required.',
      );
    }
    final productionMatch = _db.db.select(
      'SELECT id FROM productions '
      'WHERE factory_id = ? AND batch_number = ? '
      'AND part_id = ? AND machine_id = ? LIMIT 1',
      [factoryId, batchNumber, partId, machineId],
    );
    if (productionMatch.isEmpty) {
      return const BpInspectionResult(
        success: false,
        error:
            'Selected batch, part, and machine do not match a Production entry.',
      );
    }

    final available =
        await _ledger.getAvailableStock(partId, StockStage.bpStock);
    if (inspectedQty > available) {
      return BpInspectionResult(
        success: false,
        error:
            'Hold qty ($inspectedQty) exceeds available BP stock ($available)',
      );
    }

    final id = _uuid.v4();
    final now = recordedAt ?? DateTime.now();
    final dateStr =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

    final record = {
      'id': id,
      'factory_id': factoryId,
      'batch_number': batchNumber,
      'date': dateStr,
      'part_id': partId,
      'machine_id': machineId,
      'inspected_qty': inspectedQty,
      'bp_reject_qty': bpRejectQty,
      'reject_reason_id': rejectReason,
      'inspector_id': inspectorId,
      'remarks': remarks,
      'sync_status': 'pending',
    };

    try {
      await _db.runInTransaction(() async {
        final ledgerResult = await _ledger.bpHoldResolve(
          partId: partId,
          inspectedQty: inspectedQty,
          rejectQty: bpRejectQty,
          refId: id,
          triggerSync: false,
        );
        if (!ledgerResult.success) {
          throw StockPostingFailure(
            ledgerResult.error ?? 'Unable to update BP inspection stock.',
          );
        }

        await _db.insertRecord('bp_inspections', record);
        await _sync.queueInsert(
          tableName: 'bp_inspections',
          recordId: id,
          payload: record,
          triggerSync: false,
        );
      });
    } on StockPostingFailure catch (error) {
      return BpInspectionResult(success: false, error: error.message);
    } catch (_) {
      return const BpInspectionResult(
        success: false,
        error:
            'BP inspection could not be saved. No stock was changed. Please retry.',
      );
    }

    await _sync.schedulePendingSync();
    return BpInspectionResult(success: true, recordId: id);
  }

  Future<List<Map<String, dynamic>>> getRecent({int limit = 30}) async {
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) return [];
    final rows = _db.db.select(
      'SELECT bi.*, p.name as part_name, p.code as part_code, m.name as machine_name '
      'FROM bp_inspections bi '
      'LEFT JOIN parts p ON p.id = bi.part_id AND p.factory_id = bi.factory_id '
      'LEFT JOIN machines m ON m.id = bi.machine_id AND m.factory_id = bi.factory_id '
      'WHERE bi.factory_id = ? '
      'ORDER BY bi.date DESC LIMIT ?',
      [factoryId, limit],
    );
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  /// Production batches that can be selected for BP inspection.  The human
  /// batch code remains stable, while the extra context prevents choosing the
  /// wrong batch when several parts were produced on the same day.
  Future<List<Map<String, dynamic>>> getRecentBatches() async {
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) return [];
    final rows = _db.db.select(
      '''SELECT pr.batch_number, pr.part_id, pr.machine_id,
                p.code AS part_code, p.name AS part_name,
                m.name AS machine_name, pr.created_at
         FROM productions pr
         LEFT JOIN parts p ON p.id = pr.part_id AND p.factory_id = pr.factory_id
         LEFT JOIN machines m ON m.id = pr.machine_id AND m.factory_id = pr.factory_id
         WHERE pr.factory_id = ?
           AND pr.created_at = (
             SELECT MAX(latest.created_at) FROM productions latest
             WHERE latest.factory_id = pr.factory_id
               AND latest.batch_number = pr.batch_number
               AND latest.part_id = pr.part_id
           )
         ORDER BY pr.created_at DESC LIMIT 30''',
      [factoryId],
    );
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  Future<Map<String, dynamic>?> getLatestBatchStage(
    String batchNumber,
  ) async {
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) return null;
    final rows = _db.db.select(
      'SELECT part_id, machine_id FROM productions '
      'WHERE factory_id = ? AND batch_number = ? '
      'ORDER BY created_at DESC LIMIT 1',
      [factoryId, batchNumber],
    );
    if (rows.isEmpty) return null;
    return Map<String, dynamic>.from(rows.single);
  }

  Future<double> availableBpStock(String partId) {
    return _ledger.getAvailableStock(partId, StockStage.bpStock);
  }
}

final bpInspectionRepositoryProvider = Provider<BpInspectionRepository>((ref) {
  return BpInspectionRepository(
    ref.watch(databaseServiceProvider),
    ref.watch(syncServiceProvider),
    ref.watch(stockLedgerServiceProvider),
  );
});

final bpInspectionListProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  return ref.watch(bpInspectionRepositoryProvider).getRecent();
});

final recentBatchesProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  return ref.watch(bpInspectionRepositoryProvider).getRecentBatches();
});

class BpInspectionResult {
  const BpInspectionResult({required this.success, this.error, this.recordId});
  final bool success;
  final String? error;
  final String? recordId;
}
