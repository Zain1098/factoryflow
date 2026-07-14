import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/database/database_service.dart';
import '../../core/network/sync_service.dart';
import '../../core/constants/stock_stages.dart';
import '../../core/services/stock_ledger_service.dart';

const _uuid = Uuid();

// AP Reject Reasons per PRD 15.2
const kApRejectReasons = [
  'Plating Peel-off',
  'Uneven Coating',
  'Rust/Corrosion Spot',
  'Discoloration',
  'Plating Thickness Out of Spec',
  'Handling Damage',
];

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
    required String rejectReason,
    required String inspectorId,
    String? remarks,
    DateTime? recordedAt,
  }) async {
    // Validate: approved + rejected = checked (PRD 4.7, 5.3)
    if ((approvedQty + rejectedQty - qtyChecked).abs() > 0.001) {
      return ApInspectionResult(
        success: false,
        error: 'Approved ($approvedQty) + Rejected ($rejectedQty) must equal Checked ($qtyChecked)',
      );
    }

    // Validate: qtyChecked <= Pending AP stock
    final available = await _ledger.getAvailableStock(partId, StockStage.pendingAp);
    if (qtyChecked > available) {
      return ApInspectionResult(
        success: false,
        error: 'Checked qty ($qtyChecked) exceeds pending AP stock ($available PCS)',
      );
    }

    final id = _uuid.v4();
    final now = recordedAt ?? DateTime.now();
    final dateStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

    final record = {
      'id': id,
      'factory_id': _db.activeWorkspaceId,
      'batch_number': batchNumber,
      'date': dateStr,
      'part_id': partId,
      'qty_checked': qtyChecked,
      'approved_qty': approvedQty,
      'rejected_qty': rejectedQty,
      'reject_reason_id': rejectReason,
      'inspector_id': inspectorId,
      'remarks': remarks,
      'sync_status': 'pending',
    };

    await _db.insertRecord('ap_inspections', record);

    // Stock split: Pending AP OUT → Approved AP IN + RTV Stock IN (PRD 7.1)
    final ledgerResult = await _ledger.apInspectionSplit(
      partId: partId,
      checkedQty: qtyChecked,
      approvedQty: approvedQty,
      rejectedQty: rejectedQty,
      refId: id,
    );
    if (!ledgerResult.success) {
      return ApInspectionResult(success: false, error: ledgerResult.error);
    }

    await _sync.queueInsert(tableName: 'ap_inspections', recordId: id, payload: record);

    return ApInspectionResult(success: true, recordId: id);
  }

  Future<List<Map<String, dynamic>>> getRecent({int limit = 30}) async {
    final rows = _db.db.select(
      'SELECT ai.*, p.name as part_name, p.code as part_code '
      'FROM ap_inspections ai '
      'LEFT JOIN parts p ON p.id = ai.part_id '
      'ORDER BY ai.date DESC LIMIT ?',
      [limit],
    );
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }
}

final apInspectionRepositoryProvider = Provider<ApInspectionRepository>((ref) {
  return ApInspectionRepository(
    ref.watch(databaseServiceProvider),
    ref.watch(syncServiceProvider),
    ref.watch(stockLedgerServiceProvider),
  );
});

final apInspectionListProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  return ref.watch(apInspectionRepositoryProvider).getRecent();
});

class ApInspectionResult {
  const ApInspectionResult({required this.success, this.error, this.recordId});
  final bool success;
  final String? error;
  final String? recordId;
}
