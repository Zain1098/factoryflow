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

  Future<List<Map<String, dynamic>>> getRecent({int limit = 100}) async {
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) return [];
    final rows = _db.db.select(
      '''SELECT 
           CASE 
             WHEN bi.remarks LIKE 'Quality Hold Clearance%' THEN 'hold_release'
             ELSE 'inspection'
           END AS event_type,
           bi.id, bi.factory_id, bi.date, bi.batch_number, bi.part_id,
           p.name AS part_name, p.code AS part_code, m.name AS machine_name,
           COALESCE(op.name, bi.inspector_id, 'QC Inspector') AS inspector_name,
           bi.inspected_qty, bi.bp_reject_qty,
           COALESCE(r.reason, bi.reject_reason_id) AS reject_reason_name,
           bi.remarks, bi.photo_url, bi.sync_status,
           bi.rowid AS sort_id
         FROM bp_inspections bi
         LEFT JOIN parts p ON p.id = bi.part_id AND p.factory_id = bi.factory_id
         LEFT JOIN machines m ON m.id = bi.machine_id AND m.factory_id = bi.factory_id
         LEFT JOIN operators op ON op.id = bi.inspector_id AND op.factory_id = bi.factory_id
         LEFT JOIN bp_reject_reasons r ON r.id = bi.reject_reason_id AND r.factory_id = bi.factory_id
         WHERE bi.factory_id = ?

         UNION ALL

         SELECT 
           'scrap_writeoff' AS event_type,
           bra.id, bra.factory_id, bra.date, bra.batch_number, bra.part_id,
           p.name AS part_name, p.code AS part_code, NULL AS machine_name,
           COALESCE(bra.created_by, 'Authorized User') AS inspector_name,
           bra.qty AS inspected_qty, bra.qty AS bp_reject_qty,
           'Permanent Scrap Write-Off' AS reject_reason_name,
           bra.remarks, NULL AS photo_url, bra.sync_status,
           bra.rowid AS sort_id
         FROM bp_rejected_actions bra
         LEFT JOIN parts p ON p.id = bra.part_id AND p.factory_id = bra.factory_id
         WHERE bra.factory_id = ?

         UNION ALL

         SELECT 
           'stock_adjustment' AS event_type,
           sa.id, sa.factory_id, SUBSTR(sa.created_at, 1, 10) AS date,
           COALESCE(sa.batch_number, 'MANUAL-' || p.code) AS batch_number,
           sa.part_id, p.name AS part_name, p.code AS part_code, NULL AS machine_name,
           'Stock Manager' AS inspector_name,
           sa.adjusted_qty AS inspected_qty,
           CASE WHEN sa.stage = 'bp_rejected' THEN sa.adjusted_qty ELSE 0 END AS bp_reject_qty,
           CASE 
             WHEN sa.stage = 'bp_hold' THEN 'Manual BP Hold Placement'
             WHEN sa.stage = 'bp_rejected' THEN 'Manual BP Rejection Placement'
             ELSE 'Stock Adjustment'
           END AS reject_reason_name,
           sa.remarks, NULL AS photo_url, sa.sync_status,
           sa.rowid AS sort_id
         FROM stock_adjustments sa
         LEFT JOIN parts p ON p.id = sa.part_id AND p.factory_id = sa.factory_id
         WHERE sa.factory_id = ? AND sa.stage IN ('bp_hold', 'bp_rejected')

         ORDER BY date DESC, sort_id DESC LIMIT ?''',
      [factoryId, factoryId, factoryId, limit],
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
    if (factoryId.isEmpty) {
      return const BpInspectionResult(
        success: false,
        error: 'No active factory workspace is selected.',
      );
    }
    if (qty <= 0 || remarks.trim().isEmpty) {
      return const BpInspectionResult(
        success: false,
        error: 'Quantity and scrap confirmation note are required.',
      );
    }

    final totalAvailable =
        await _ledger.getAvailableStock(partId, StockStage.bpRejected);
    if (qty > totalAvailable) {
      return BpInspectionResult(
        success: false,
        error:
            'Scrap quantity (${qty.toInt()} PCS) exceeds available BP rejected stock (${totalAvailable.toInt()} PCS).',
      );
    }

    final id = _uuid.v4();
    final now = DateTime.now();
    final record = {
      'id': id,
      'factory_id': factoryId,
      'date':
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}',
      'part_id': partId,
      'batch_number':
          batchNumber.trim().isNotEmpty ? batchNumber.trim() : 'SCRAP',
      'qty': qty,
      'action': 'final_rejected',
      'remarks': remarks.trim(),
      'created_by': createdBy,
      'sync_status': 'pending',
    };

    try {
      await _db.runInTransaction(() async {
        final ledgerResult = await _ledger.bpRejectedScrap(
          partId: partId,
          qty: qty,
          refId: id,
          triggerSync: false,
        );
        if (!ledgerResult.success) {
          throw StockPostingFailure(
            ledgerResult.error ?? 'Unable to finalize BP rejected scrap.',
          );
        }
        await _db.insertRecord('bp_rejected_actions', record);
        await _sync.queueInsert(
          tableName: 'bp_rejected_actions',
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
        error: 'Final rejection could not be saved. No stock was changed.',
      );
    }
    await _sync.schedulePendingSync();
    return BpInspectionResult(success: true, recordId: id);
  }

  Future<List<Map<String, dynamic>>> getBpHoldStock() async {
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) return [];
    final rows = _db.db.select(
      '''SELECT p.id AS part_id, p.code AS part_code, p.name AS part_name,
                COALESCE(sl.running_balance, 0) AS hold_qty,
                COALESCE(sa.remarks, 'Quality check hold') AS reason,
                COALESCE(sa.created_at, sl.created_at) AS hold_date,
                COALESCE(sa.batch_number, 'OPEN-' || p.code) AS batch_number
         FROM parts p
         INNER JOIN stock_ledger sl ON sl.factory_id = p.factory_id
           AND sl.part_id = p.id AND sl.stage = 'bp_hold'
           AND sl.rowid = (
             SELECT candidate.rowid FROM stock_ledger candidate
             WHERE candidate.factory_id = p.factory_id
               AND candidate.part_id = p.id
               AND candidate.stage = 'bp_hold'
             ORDER BY candidate.created_at DESC, candidate.rowid DESC
             LIMIT 1
           )
         LEFT JOIN stock_adjustments sa ON sa.factory_id = p.factory_id
           AND sa.part_id = p.id AND sa.stage = 'bp_hold'
           AND sa.created_at = (
             SELECT MAX(created_at) FROM stock_adjustments
             WHERE factory_id = p.factory_id AND part_id = p.id AND stage = 'bp_hold'
           )
         WHERE p.factory_id = ? AND p.active = 1 AND sl.running_balance > 0
         ORDER BY p.name''',
      [factoryId],
    );
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  /// Releases material from BP Hold into Own BP Stock (OK) and BP Rejected (Reject)
  Future<BpInspectionResult> releaseBpHold({
    required String partId,
    required String batchNumber,
    required double totalQty,
    required double okQty,
    required double rejectQty,
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
    if ((okQty + rejectQty - totalQty).abs() > 0.001) {
      return BpInspectionResult(
        success: false,
        error:
            'OK Qty (${okQty.toInt()}) + Reject Qty (${rejectQty.toInt()}) must equal Total Qty (${totalQty.toInt()}).',
      );
    }
    if (rejectQty > 0 && (rejectReason == null || rejectReason.trim().isEmpty)) {
      return const BpInspectionResult(
        success: false,
        error:
            'Reject reason is required when reject quantity is greater than zero.',
      );
    }

    final id = _uuid.v4();
    final now = recordedAt ?? DateTime.now();
    final dateStr =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

    final record = {
      'id': id,
      'factory_id': factoryId,
      'batch_number': batchNumber.trim().isEmpty ? 'OPEN' : batchNumber.trim(),
      'date': dateStr,
      'part_id': partId,
      'machine_id': null,
      'inspected_qty': totalQty,
      'bp_reject_qty': rejectQty,
      'reject_reason_id': rejectReason,
      'inspector_id': inspectorId,
      'remarks': remarks?.trim().isNotEmpty == true
          ? remarks!.trim()
          : 'Quality Hold Clearance (${okQty.toInt()} OK, ${rejectQty.toInt()} Reject)',
      'sync_status': 'pending',
    };

    try {
      await _db.runInTransaction(() async {
        final ledgerResult = await _ledger.releaseDirectBpHold(
          partId: partId,
          okQty: okQty,
          rejectQty: rejectQty,
          refId: id,
          triggerSync: false,
        );
        if (!ledgerResult.success) {
          throw StockPostingFailure(
            ledgerResult.error ?? 'Unable to update stock for BP hold release.',
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
    } catch (e) {
      return BpInspectionResult(
        success: false,
        error: 'Hold release could not be saved: $e',
      );
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
                SUM(bi.bp_reject_qty) - COALESCE(actions.actioned_qty, 0) AS qty,
                COALESCE(r.reason, bi.reject_reason_id, 'Quality reject') AS reason,
                bi.date AS reject_date
         FROM bp_inspections bi
         INNER JOIN parts p ON p.id = bi.part_id AND p.factory_id = bi.factory_id
         LEFT JOIN bp_reject_reasons r ON r.id = bi.reject_reason_id AND r.factory_id = bi.factory_id
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
    final items = rows.map((r) => Map<String, dynamic>.from(r)).toList();

    // Also include any parts that have BP rejected balance in stock_ledger
    // (e.g. from Settings → Stock Management manual adjustment)
    final bpRejectBalances =
        await _db.getBalancesByStage(StockStage.bpRejected.value);
    for (final row in bpRejectBalances) {
      final partId = row['id'] as String;
      final partCode = row['code'] as String? ?? '';
      final partName = row['name'] as String? ?? '';
      final ledgerBalance = (row['balance'] as num?)?.toDouble() ?? 0.0;
      if (ledgerBalance <= 0) continue;

      final existingBatchSum = items
          .where((i) => i['part_id'] == partId)
          .fold<double>(
            0.0,
            (sum, i) => sum + ((i['qty'] as num?)?.toDouble() ?? 0.0),
          );

      final unbatched = ledgerBalance - existingBatchSum;
      if (unbatched > 0) {
        items.add({
          'part_id': partId,
          'part_code': partCode,
          'part_name': partName,
          'batch_number': 'OPEN-$partCode',
          'qty': unbatched,
          'reason': 'Manual stock entry / opening rejected',
          'reject_date': DateTime.now().toIso8601String().substring(0, 10),
        });
      }
    }

    return items;
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

final bpHoldStockProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) {
  return ref.watch(bpInspectionRepositoryProvider).getBpHoldStock();
});

class BpInspectionResult {
  const BpInspectionResult({required this.success, this.error, this.recordId});
  final bool success;
  final String? error;
  final String? recordId;
}
