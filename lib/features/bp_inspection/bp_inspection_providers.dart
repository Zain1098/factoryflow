import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/database/database_service.dart';
import '../../core/network/sync_service.dart';
import '../../core/constants/stock_stages.dart';
import '../../core/providers/production_flow_provider.dart';
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
  BpInspectionRepository(this._db, this._sync, this._ledger, [this._flow]);

  final DatabaseService _db;
  final SyncService _sync;
  final StockLedgerService _ledger;
  final ProductionFlowConfig? _flow;

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
    if (_flow?.isMultiStage == true &&
        machineId != _flow!.requiredMachineIds.last) {
      return const BpInspectionResult(
        success: false,
        error: 'Complete the final production machine before BP inspection.',
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

    final batchRows = _db.db.select(
      '''SELECT COALESCE((
           SELECT SUM(good_qty) FROM productions
           WHERE factory_id = ? AND batch_number = ?
             AND part_id = ? AND machine_id = ?
         ), 0) - COALESCE((
           SELECT SUM(inspected_qty) FROM bp_inspections
           WHERE factory_id = ? AND batch_number = ? AND part_id = ?
         ), 0) AS available_qty''',
      [
        factoryId,
        batchNumber,
        partId,
        machineId,
        factoryId,
        batchNumber,
        partId,
      ],
    );
    final batchAvailable =
        (batchRows.single['available_qty'] as num?)?.toDouble() ?? 0;
    if (inspectedQty > batchAvailable) {
      return BpInspectionResult(
        success: false,
        error:
            'Inspection qty (${inspectedQty.toInt()}) exceeds this batch balance (${batchAvailable.toInt()} PCS).',
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
    final finalMachineId =
        _flow?.isMultiStage == true ? _flow!.requiredMachineIds.last : null;
    final rows = _db.db.select(
      '''SELECT pr.batch_number, pr.part_id, pr.machine_id,
                p.code AS part_code, p.name AS part_name,
                m.name AS machine_name, pr.created_at
         FROM productions pr
         LEFT JOIN parts p ON p.id = pr.part_id AND p.factory_id = pr.factory_id
         LEFT JOIN machines m ON m.id = pr.machine_id AND m.factory_id = pr.factory_id
         WHERE pr.factory_id = ?
           AND (? IS NULL OR pr.machine_id = ?)
           AND pr.created_at = (
             SELECT MAX(latest.created_at) FROM productions latest
             WHERE latest.factory_id = pr.factory_id
               AND latest.batch_number = pr.batch_number
               AND latest.part_id = pr.part_id
           )
         ORDER BY pr.created_at DESC LIMIT 30''',
      [factoryId, finalMachineId, finalMachineId],
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

  Future<BpInspectionResult> finalizeRejected({
    required String partId,
    required String batchNumber,
    required double qty,
    required String createdBy,
    required String remarks,
  }) async {
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) return const BpInspectionResult(success: false, error: 'No active factory workspace is selected.');
    if (batchNumber.trim().isEmpty || qty <= 0 || remarks.trim().isEmpty) return const BpInspectionResult(success: false, error: 'Batch, quantity and final-rejection note are required.');
    final id = _uuid.v4();
    final now = DateTime.now();
    final record = {
      'id': id, 'factory_id': factoryId,
      'date': '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}',
      'part_id': partId, 'batch_number': batchNumber.trim(), 'qty': qty, 'action': 'final_rejected',
      'remarks': remarks.trim(), 'created_by': createdBy, 'sync_status': 'pending',
    };
    try {
      await _db.runInTransaction(() async {
        final ledgerResult = await _ledger.bpRejectedScrap(partId: partId, qty: qty, refId: id, triggerSync: false);
        if (!ledgerResult.success) throw StockPostingFailure(ledgerResult.error ?? 'Unable to finalize BP rejected stock.');
        await _db.insertRecord('bp_rejected_actions', record);
        await _sync.queueInsert(tableName: 'bp_rejected_actions', recordId: id, payload: record, triggerSync: false);
      });
    } on StockPostingFailure catch (error) {
      return BpInspectionResult(success: false, error: error.message);
    } catch (_) {
      return const BpInspectionResult(success: false, error: 'Final rejection could not be saved. No stock was changed.');
    }
    await _sync.schedulePendingSync();
    return BpInspectionResult(success: true, recordId: id);
  }

  Future<List<Map<String, dynamic>>> getRejectedStock() async {
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) return [];
    final rows = _db.db.select(
      '''SELECT p.id AS part_id, p.code AS part_code, p.name AS part_name,
                bi.batch_number,
                SUM(bi.bp_reject_qty) - COALESCE(actions.actioned_qty, 0) AS qty
         FROM bp_inspections bi
         INNER JOIN parts p ON p.id = bi.part_id AND p.factory_id = bi.factory_id
         LEFT JOIN (
           SELECT factory_id, part_id, batch_number, SUM(qty) AS actioned_qty
           FROM bp_rejected_actions WHERE action = 'final_rejected'
           GROUP BY factory_id, part_id, batch_number
         ) actions ON actions.factory_id = bi.factory_id
           AND actions.part_id = bi.part_id AND actions.batch_number = bi.batch_number
         WHERE bi.factory_id = ? AND p.active = 1
         GROUP BY bi.factory_id, bi.part_id, bi.batch_number, p.code, p.name, actions.actioned_qty
         HAVING SUM(bi.bp_reject_qty) - COALESCE(actions.actioned_qty, 0) > 0
         ORDER BY bi.batch_number DESC, p.name''',
      [factoryId],
    );
    return rows.map((row) => Map<String, dynamic>.from(row)).toList();
  }
}

final bpInspectionRepositoryProvider = Provider<BpInspectionRepository>((ref) {
  return BpInspectionRepository(
    ref.watch(databaseServiceProvider),
    ref.watch(syncServiceProvider),
    ref.watch(stockLedgerServiceProvider),
    ref.watch(productionFlowProvider),
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

final bpRejectedStockProvider = FutureProvider<List<Map<String, dynamic>>>((ref) {
  return ref.watch(bpInspectionRepositoryProvider).getRejectedStock();
});

class BpInspectionResult {
  const BpInspectionResult({required this.success, this.error, this.recordId});
  final bool success;
  final String? error;
  final String? recordId;
}
