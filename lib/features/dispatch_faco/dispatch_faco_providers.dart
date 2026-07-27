import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants/stock_stages.dart';
import '../../core/database/database_service.dart';
import '../../core/network/sync_service.dart';
import '../../core/providers/production_flow_provider.dart';
import '../../core/services/stock_ledger_service.dart';

const _uuid = Uuid();

class DispatchFacoRepository {
  DispatchFacoRepository(this._db, this._sync, this._ledger, this._flow);

  final DatabaseService _db;
  final SyncService _sync;
  final StockLedgerService _ledger;
  final ProductionFlowConfig _flow;

  Future<DispatchFacoResult> save({
    required String batchNumber,
    required String partId,
    required double qty,
    required String vendorId,
    String? vehicleId,
    String? driverId,
    String? challannumber,
    String? remarks,
    required String createdBy,
    DateTime? recordedAt,
  }) async {
    // Multi-stage validation: If enabled, check if batch has completed the final machine sequence
    if (_flow.isMultiStage && _flow.requireFinalMachineForDispatch && batchNumber.isNotEmpty) {
      final finalMachineId = _flow.requiredMachineIds.last;
      final check = _db.db.select(
        'SELECT COUNT(*) as cnt FROM productions WHERE batch_number = ? AND machine_id = ?',
        [batchNumber, finalMachineId],
      );
      if ((check.first['cnt'] as int) == 0) {
        final mRow = _db.db.select('SELECT name FROM machines WHERE id = ?', [finalMachineId]);
        final mName = mRow.isNotEmpty ? mRow.first['name'] as String : 'Final Stage Machine';
        return DispatchFacoResult(
          success: false,
          error: 'Batch "$batchNumber" is still Work-In-Progress (BP stock). It must complete $mName (Final Sequence) before vendor dispatch.',
        );
      }
    }

    // Validate: qty <= BP stock (PRD 4.5)
    final available = await _ledger.getAvailableStock(partId, StockStage.bpStock);
    if (qty > available) {
      return DispatchFacoResult(
        success: false,
        error: 'Dispatch qty ($qty) exceeds available BP stock ($available PCS)',
      );
    }

    final id = _uuid.v4();
    final now = recordedAt ?? DateTime.now();
    final dateStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final timeStr = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    final record = {
      'id': id,
      'factory_id': _db.activeWorkspaceId,
      'batch_number': batchNumber,
      'date': dateStr,
      'time': timeStr,
      'part_id': partId,
      'qty': qty,
      'vendor_id': vendorId,
      'vehicle_id': vehicleId,
      'driver_id': driverId,
      'challan_number': challannumber,
      'remarks': remarks,
      'created_by': createdBy,
      'sync_status': 'pending',
    };

    await _db.insertRecord('dispatch_to_facos', record);

    // Stock: BP Stock OUT → At Faco IN (PRD 7.1)
    final ledgerResult = await _ledger.dispatchToFaco(
      partId: partId,
      qty: qty,
      refId: id,
    );
    if (!ledgerResult.success) {
      return DispatchFacoResult(success: false, error: ledgerResult.error);
    }

    await _sync.queueInsert(tableName: 'dispatch_to_facos', recordId: id, payload: record);

    return DispatchFacoResult(success: true, recordId: id);
  }

  Future<List<Map<String, dynamic>>> getRecent({int limit = 30}) async {
    final rows = _db.db.select(
      'SELECT df.*, p.name as part_name, p.code as part_code, v.name as vendor_name '
      'FROM dispatch_to_facos df '
      'LEFT JOIN parts p ON p.id = df.part_id '
      'LEFT JOIN vendors v ON v.id = df.vendor_id '
      'ORDER BY df.date DESC, df.time DESC LIMIT ?',
      [limit],
    );
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  Future<List<String>> getRecentBatches() async {
    final rows = _db.db.select(
      "SELECT DISTINCT batch_number FROM productions ORDER BY created_at DESC LIMIT 20",
    );
    return rows.map((r) => r['batch_number'] as String).toList();
  }

  Future<List<Map<String, dynamic>>> getRecentBpInspections() async {
    final rows = _db.db.select(
      'SELECT DISTINCT bi.batch_number, bi.part_id, p.code as part_code, p.name as part_name, bi.date '
      'FROM bp_inspections bi '
      'LEFT JOIN parts p ON p.id = bi.part_id '
      'ORDER BY bi.date DESC LIMIT 30'
    );
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }
}

final dispatchFacoRepositoryProvider = Provider<DispatchFacoRepository>((ref) {
  return DispatchFacoRepository(
    ref.watch(databaseServiceProvider),
    ref.watch(syncServiceProvider),
    ref.watch(stockLedgerServiceProvider),
    ref.watch(productionFlowProvider),
  );
});

final dispatchFacoListProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  return ref.watch(dispatchFacoRepositoryProvider).getRecent();
});

final bpReinspectedBatchesProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  return ref.watch(dispatchFacoRepositoryProvider).getRecentBpInspections();
});

class DispatchFacoResult {
  const DispatchFacoResult({required this.success, this.error, this.recordId});
  final bool success;
  final String? error;
  final String? recordId;
}
