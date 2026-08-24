import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/database/database_service.dart';
import '../../core/network/sync_service.dart';
import '../../core/constants/stock_stages.dart';
import '../../core/services/stock_ledger_service.dart';

import '../../core/providers/master_data_providers.dart';

const _uuid = Uuid();

// Fallback reasons used only when DB has no configured reasons yet.
const kApRejectReasonsFallback = [
  'Plating Peel-off', 'Uneven Coating', 'Rust/Corrosion Spot',
  'Discoloration', 'Plating Thickness Out of Spec', 'Handling Damage',
];

/// Live AP reject reasons from DB, falling back to defaults.
final apRejectReasonsListProvider = FutureProvider<List<String>>((ref) async {
  final rows = await ref.watch(apRejectReasonsProvider.future);
  if (rows.isEmpty) return kApRejectReasonsFallback;
  return rows.map((r) => r['reason'] as String).toList();
});

class ApInspectionRepository {
  ApInspectionRepository(this._db, this._sync, this._ledger);

  final DatabaseService _db;
  final SyncService _sync;
  final StockLedgerService _ledger;

  Future<ApInspectionResult> save({
    required String batchNumber,
    required String partId,
    required double qtyChecked,
    required double approvedQty,
    required double rejectedQty,
    double rtvQty = 0,
    required String rejectReason,
    required String inspectorId,
    String? remarks,
    DateTime? recordedAt,
  }) async {
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) {
      return const ApInspectionResult(
        success: false,
        error: 'No active factory workspace is selected.',
      );
    }
    if (qtyChecked <= 0 || approvedQty < 0 || rejectedQty < 0 || rtvQty < 0) {
      return const ApInspectionResult(
        success: false,
        error: 'Inspection quantities must be valid positive values.',
      );
    }
    if (batchNumber.trim().isEmpty) {
      return const ApInspectionResult(
        success: false,
        error: 'Select the original vendor receipt batch before AP inspection.',
      );
    }
    if ((approvedQty + rejectedQty + rtvQty - qtyChecked).abs() > 0.001) {
      return ApInspectionResult(
        success: false,
        error:
            'OK ($approvedQty) + RTV hold ($rtvQty) + AP rejected ($rejectedQty) must equal Checked ($qtyChecked)',
      );
    }
    final batchRows = _db.db.select(
      '''SELECT COALESCE((
           SELECT SUM(qty_received)
           FROM receive_from_facos
           WHERE factory_id = ? AND batch_number = ? AND part_id = ?
         ), 0) - COALESCE((
           SELECT SUM(qty_checked)
           FROM ap_inspections
           WHERE factory_id = ? AND batch_number = ? AND part_id = ?
         ), 0) AS available_qty''',
      [factoryId, batchNumber, partId, factoryId, batchNumber, partId],
    );
    final batchAvailable =
        (batchRows.single['available_qty'] as num?)?.toDouble() ?? 0;
    if (qtyChecked > batchAvailable) {
      return ApInspectionResult(
        success: false,
        error:
            '$batchNumber: Checked qty (${qtyChecked.toInt()}) exceeds pending AP batch stock (${batchAvailable.toInt()} PCS).',
      );
    }
    final available =
        await _ledger.getAvailableStock(partId, StockStage.pendingAp);
    if (qtyChecked > available) {
      return ApInspectionResult(
        success: false,
        error:
            'Checked qty ($qtyChecked) exceeds pending AP stock ($available PCS)',
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
      'qty_checked': qtyChecked,
      'approved_qty': approvedQty,
      'rejected_qty': rejectedQty,
      'rtv_qty': rtvQty,
      'reject_reason_id': rejectReason,
      'inspector_id': inspectorId,
      'remarks': remarks,
      'sync_status': 'pending',
    };

    // Pending AP OUT → AP OK, AP rejected, and RTV-hold stock.
    try {
      await _db.runInTransaction(() async {
        final ledgerResult = await _ledger.apInspectionSplit(
          partId: partId,
          checkedQty: qtyChecked,
          approvedQty: approvedQty,
          rejectedQty: rejectedQty,
          rtvQty: rtvQty,
          refId: id,
          triggerSync: false,
        );
        if (!ledgerResult.success) {
          throw StockPostingFailure(
            ledgerResult.error ?? 'Unable to update AP inspection stock.',
          );
        }

        await _db.insertRecord('ap_inspections', record);
        await _sync.queueInsert(
          tableName: 'ap_inspections',
          recordId: id,
          payload: record,
          triggerSync: false,
        );
      });
    } on StockPostingFailure catch (error) {
      return ApInspectionResult(success: false, error: error.message);
    } catch (_) {
      return const ApInspectionResult(
        success: false,
        error:
            'AP inspection could not be saved. No stock was changed. Please retry.',
      );
    }

    await _sync.schedulePendingSync();
    return ApInspectionResult(success: true, recordId: id);
  }

  Future<List<Map<String, dynamic>>> getRecent({int limit = 30}) async {
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) return [];
    final rows = _db.db.select(
      'SELECT ai.*, p.name as part_name, p.code as part_code '
      'FROM ap_inspections ai '
      'LEFT JOIN parts p ON p.id = ai.part_id AND p.factory_id = ai.factory_id '
      'WHERE ai.factory_id = ? '
      'ORDER BY ai.date DESC LIMIT ?',
      [factoryId, limit],
    );
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  /// Batch-specific material received from vendor but not yet AP inspected.
  /// Keeping the original batch here preserves end-to-end traceability.
  Future<List<Map<String, dynamic>>> getPendingBatches() async {
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) return [];
    final rows = _db.db.select(
      '''WITH received AS (
           SELECT factory_id, batch_number, part_id,
                  SUM(qty_received) AS received_qty
           FROM receive_from_facos
           WHERE factory_id = ?
           GROUP BY factory_id, batch_number, part_id
         ),
         inspected AS (
           SELECT factory_id, batch_number, part_id,
                  SUM(qty_checked) AS inspected_qty
           FROM ap_inspections
           WHERE factory_id = ?
           GROUP BY factory_id, batch_number, part_id
         )
         SELECT p.id, p.code, p.name, received.batch_number,
                received.received_qty -
                  COALESCE(inspected.inspected_qty, 0) AS balance
         FROM received
         INNER JOIN parts p ON p.id = received.part_id
           AND p.factory_id = received.factory_id
         LEFT JOIN inspected ON inspected.factory_id = received.factory_id
           AND inspected.batch_number = received.batch_number
           AND inspected.part_id = received.part_id
         WHERE received.received_qty -
                 COALESCE(inspected.inspected_qty, 0) > 0
         ORDER BY received.batch_number, p.code''',
      [factoryId, factoryId],
    );
    return rows.map((row) => Map<String, dynamic>.from(row)).toList();
  }

  // ── AP Rejected Stock ──────────────────────────────────────────────────────

  /// Returns AP rejected balances by source batch.
  Future<List<Map<String, dynamic>>> getApRejectedStock() async {
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) return [];
    final rows = _db.db.select(
      '''SELECT p.id AS part_id, p.code AS part_code, p.name AS part_name,
                ai.batch_number,
                SUM(ai.rejected_qty) - COALESCE(actions.actioned_qty, 0) AS qty
         FROM ap_inspections ai
         INNER JOIN parts p ON p.id = ai.part_id AND p.factory_id = ai.factory_id
         LEFT JOIN (
           SELECT factory_id, part_id, batch_number, SUM(qty) AS actioned_qty
           FROM ap_rejected_actions WHERE action IN ('scrapped', 'sent_to_faco')
           GROUP BY factory_id, part_id, batch_number
         ) actions ON actions.factory_id = ai.factory_id
           AND actions.part_id = ai.part_id AND actions.batch_number = ai.batch_number
         WHERE ai.factory_id = ? AND p.active = 1
         GROUP BY ai.factory_id, ai.part_id, ai.batch_number, p.code, p.name, actions.actioned_qty
         HAVING SUM(ai.rejected_qty) - COALESCE(actions.actioned_qty, 0) > 0
         ORDER BY ai.batch_number DESC, p.name''',
      [factoryId],
    );
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  /// RTV outstanding grouped by vendor, batch and cycle.
  Future<List<Map<String, dynamic>>> getRtvStock() async {
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) return [];
    final rows = _db.db.select(
      '''SELECT r.date, r.batch_number, r.rtv_qty,
                r.reason_id AS reason, r.cycle_number, r.status,
                p.id AS part_id, p.code AS part_code, p.name AS part_name,
                v.name AS vendor_name,
                r.rtv_qty - COALESCE(SUM(rr.quantity_received), 0)
                  AS current_balance
         FROM rtvs r
         INNER JOIN parts p ON p.id = r.part_id
           AND p.factory_id = r.factory_id
         LEFT JOIN vendors v ON v.id = r.vendor_id
           AND v.factory_id = r.factory_id
         LEFT JOIN rtv_reinspections rr ON rr.rtv_id = r.id
           AND rr.factory_id = r.factory_id
         WHERE r.factory_id = ?
           AND r.status IN ('sent', 'partially_received')
         GROUP BY r.id, p.id, p.code, p.name, v.name
         HAVING r.rtv_qty - COALESCE(SUM(rr.quantity_received), 0) > 0
         ORDER BY r.date DESC LIMIT 100''',
      [factoryId],
    );
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  /// Scrap AP rejected qty (write off — mark done)
  Future<ApInspectionResult> scrapRejected({
    required String partId,
    required String batchNumber,
    required double qty,
    required String createdBy,
    String? remarks,
  }) async {
    return _postRejectedAction(
      partId: partId,
      batchNumber: batchNumber,
      qty: qty,
      action: 'scrapped',
      createdBy: createdBy,
      remarks: remarks,
      postStock: (id) => _ledger.apRejectedScrap(
        partId: partId,
        qty: qty,
        refId: id,
        triggerSync: false,
      ),
    );
  }

  /// Send AP rejected qty to vendor for rework.
  Future<ApInspectionResult> sendToFaco({
    required String partId,
    required String batchNumber,
    required double qty,
    required String vendorId,
    required String createdBy,
    String? remarks,
  }) async {
    return _postRejectedAction(
      partId: partId,
      batchNumber: batchNumber,
      qty: qty,
      action: 'sent_to_faco',
      vendorId: vendorId,
      createdBy: createdBy,
      remarks: remarks,
      postStock: (id) => _ledger.apRejectedToFaco(
        partId: partId,
        qty: qty,
        refId: id,
        triggerSync: false,
      ),
    );
  }

  Future<ApInspectionResult> _postRejectedAction({
    required String partId,
    required String batchNumber,
    required double qty,
    required String action,
    String? vendorId,
    required String createdBy,
    String? remarks,
    required Future<StockLedgerResult> Function(String id) postStock,
  }) async {
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) {
      return const ApInspectionResult(
        success: false,
        error: 'No active factory workspace is selected.',
      );
    }
    if (batchNumber.trim().isEmpty || qty <= 0) {
      return const ApInspectionResult(
        success: false,
        error: 'Batch and action quantity are required.',
      );
    }

    final id = _uuid.v4();
    final now = DateTime.now();
    final dateStr =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

    final record = {
      'id': id,
      'factory_id': factoryId,
      'date': dateStr,
      'part_id': partId,
      'batch_number': batchNumber.trim(),
      'qty': qty,
      'action': action,
      'vendor_id': vendorId,
      'remarks': remarks,
      'created_by': createdBy,
      'sync_status': 'pending',
    };

    try {
      await _db.runInTransaction(() async {
        final ledgerResult = await postStock(id);
        if (!ledgerResult.success) {
          throw StockPostingFailure(
            ledgerResult.error ?? 'Unable to update AP rejected stock.',
          );
        }
        await _db.insertRecord('ap_rejected_actions', record);
        await _sync.queueInsert(
          tableName: 'ap_rejected_actions',
          recordId: id,
          payload: record,
          triggerSync: false,
        );
      });
    } on StockPostingFailure catch (error) {
      return ApInspectionResult(success: false, error: error.message);
    } catch (_) {
      return const ApInspectionResult(
        success: false,
        error: 'Action could not be saved. No stock was changed. Please retry.',
      );
    }

    await _sync.schedulePendingSync();
    return ApInspectionResult(success: true, recordId: id);
  }
}

final apInspectionRepositoryProvider = Provider<ApInspectionRepository>((ref) {
  return ApInspectionRepository(
    ref.watch(databaseServiceProvider),
    ref.watch(syncServiceProvider),
    ref.watch(stockLedgerServiceProvider),
  );
});

final apInspectionListProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  return ref.watch(apInspectionRepositoryProvider).getRecent();
});

final apRejectedStockProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  return ref.watch(apInspectionRepositoryProvider).getApRejectedStock();
});

/// After Plating stock waiting for AP inspection
final pendingApStockProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  return ref.watch(apInspectionRepositoryProvider).getPendingBatches();
});

/// AP OK stock ready for final dispatch
final apOkStockProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  return ref.watch(databaseServiceProvider).getBalancesByStage('approved_ap');
});

/// RTV stock — vendor-wise breakdown
final rtvStockProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  return ref.watch(apInspectionRepositoryProvider).getRtvStock();
});

class ApInspectionResult {
  const ApInspectionResult({required this.success, this.error, this.recordId});
  final bool success;
  final String? error;
  final String? recordId;
}
