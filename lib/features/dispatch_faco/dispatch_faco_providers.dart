import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants/app_constants.dart';
import '../../core/database/database_service.dart';
import '../../core/network/sync_service.dart';
import '../../core/constants/stock_stages.dart';
import '../../core/services/stock_ledger_service.dart';

const _uuid = Uuid();

class DispatchFacoRepository {
  DispatchFacoRepository(this._db, this._sync, this._ledger);

  final DatabaseService _db;
  final SyncService _sync;
  final StockLedgerService _ledger;

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
  }) async {
    // Validate: qty <= BP stock (PRD 4.5)
    final available = await _ledger.getAvailableStock(partId, StockStage.bpStock);
    if (qty > available) {
      return DispatchFacoResult(
        success: false,
        error: 'Dispatch qty ($qty) exceeds available BP stock ($available PCS)',
      );
    }

    final id = _uuid.v4();
    final now = DateTime.now();
    final dateStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final timeStr = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    final record = {
      'id': id,
      'factory_id': AppConstants.defaultFactoryId,
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
}

final dispatchFacoRepositoryProvider = Provider<DispatchFacoRepository>((ref) {
  return DispatchFacoRepository(
    ref.watch(databaseServiceProvider),
    ref.watch(syncServiceProvider),
    ref.watch(stockLedgerServiceProvider),
  );
});

final dispatchFacoListProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  return ref.watch(dispatchFacoRepositoryProvider).getRecent();
});

class DispatchFacoResult {
  const DispatchFacoResult({required this.success, this.error, this.recordId});
  final bool success;
  final String? error;
  final String? recordId;
}
