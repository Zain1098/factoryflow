import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/database/database_service.dart';
import '../../core/network/sync_service.dart';
import '../../core/constants/stock_stages.dart';
import '../../core/services/stock_ledger_service.dart';

const _uuid = Uuid();

// BP Reject Reasons per PRD 15.2
const kBpRejectReasons = [
  'Crack',
  'Dimension Out of Tolerance',
  'Bend Angle Error',
  'Surface Scratch',
  'Burr/Sharp Edge',
  'Deformation',
  'Incomplete Forming',
];

class BpInspectionRepository {
  BpInspectionRepository(this._db, this._sync, this._ledger);

  final DatabaseService _db;
  final SyncService _sync;
  final StockLedgerService _ledger;

  Future<BpInspectionResult> save({
    required String batchNumber,
    required String partId,
    required String machineId,
    required double bpRejectQty,
    required String rejectReason,
    required String inspectorId,
    String? remarks,
    DateTime? recordedAt,
  }) async {
    // Validate: bpRejectQty <= BP stock available (PRD 4.4)
    final available = await _ledger.getAvailableStock(partId, StockStage.bpStock);
    if (bpRejectQty > available) {
      return BpInspectionResult(
        success: false,
        error: 'Reject qty ($bpRejectQty) exceeds available BP stock ($available)',
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
      'machine_id': machineId,
      'bp_reject_qty': bpRejectQty,
      'reject_reason_id': rejectReason,
      'inspector_id': inspectorId,
      'remarks': remarks,
      'sync_status': 'pending',
    };

    await _db.insertRecord('bp_inspections', record);

    // Write stock ledger: reject qty OUT of BP stock (PRD 7.1)
    if (bpRejectQty > 0) {
      final ledgerResult = await _ledger.bpRejectOut(
        partId: partId,
        qty: bpRejectQty,
        refId: id,
      );
      if (!ledgerResult.success) {
        return BpInspectionResult(success: false, error: ledgerResult.error);
      }
    }

    await _sync.queueInsert(tableName: 'bp_inspections', recordId: id, payload: record);

    return BpInspectionResult(success: true, recordId: id);
  }

  Future<List<Map<String, dynamic>>> getRecent({int limit = 30}) async {
    final rows = _db.db.select(
      'SELECT bi.*, p.name as part_name, p.code as part_code, m.name as machine_name '
      'FROM bp_inspections bi '
      'LEFT JOIN parts p ON p.id = bi.part_id '
      'LEFT JOIN machines m ON m.id = bi.machine_id '
      'ORDER BY bi.date DESC LIMIT ?',
      [limit],
    );
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  /// Get recent batch numbers for autocomplete
  Future<List<String>> getRecentBatches() async {
    final rows = _db.db.select(
      "SELECT DISTINCT batch_number FROM productions ORDER BY created_at DESC LIMIT 20",
    );
    return rows.map((r) => r['batch_number'] as String).toList();
  }
}

final bpInspectionRepositoryProvider = Provider<BpInspectionRepository>((ref) {
  return BpInspectionRepository(
    ref.watch(databaseServiceProvider),
    ref.watch(syncServiceProvider),
    ref.watch(stockLedgerServiceProvider),
  );
});

final bpInspectionListProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  return ref.watch(bpInspectionRepositoryProvider).getRecent();
});

final recentBatchesProvider = FutureProvider<List<String>>((ref) async {
  return ref.watch(bpInspectionRepositoryProvider).getRecentBatches();
});

class BpInspectionResult {
  const BpInspectionResult({required this.success, this.error, this.recordId});
  final bool success;
  final String? error;
  final String? recordId;
}
