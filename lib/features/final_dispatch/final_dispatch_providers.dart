import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants/app_constants.dart';
import '../../core/database/database_service.dart';
import '../../core/network/sync_service.dart';
import '../../core/constants/stock_stages.dart';
import '../../core/services/stock_ledger_service.dart';

const _uuid = Uuid();

class FinalDispatchRepository {
  FinalDispatchRepository(this._db, this._sync, this._ledger);

  final DatabaseService _db;
  final SyncService _sync;
  final StockLedgerService _ledger;

  Future<FinalDispatchResult> save({
    required String batchNumber,
    required String partId,
    required String customerId,
    required double dispatchQty,
    String? vehicleId,
    String? driverId,
    String? challanNumber,
    String? remarks,
    required String createdBy,
  }) async {
    // Validate: dispatchQty <= Approved AP stock (PRD 4.10)
    final available = await _ledger.getAvailableStock(partId, StockStage.approvedAp);
    if (dispatchQty > available) {
      return FinalDispatchResult(
        success: false,
        error: 'Dispatch qty ($dispatchQty) exceeds approved AP stock ($available PCS)',
      );
    }

    final id = _uuid.v4();
    final now = DateTime.now();
    final dateStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

    final record = {
      'id': id,
      'factory_id': AppConstants.defaultFactoryId,
      'batch_number': batchNumber,
      'date': dateStr,
      'part_id': partId,
      'customer_id': customerId,
      'dispatch_qty': dispatchQty,
      'vehicle_id': vehicleId,
      'driver_id': driverId,
      'challan_number': challanNumber,
      'remarks': remarks,
      'created_by': createdBy,
      'sync_status': 'pending',
    };

    await _db.insertRecord('final_dispatches', record);

    // Stock: Approved AP OUT (PRD 7.1)
    final ledgerResult = await _ledger.finalDispatch(
      partId: partId,
      qty: dispatchQty,
      refId: id,
    );
    if (!ledgerResult.success) {
      return FinalDispatchResult(success: false, error: ledgerResult.error);
    }

    await _sync.queueInsert(tableName: 'final_dispatches', recordId: id, payload: record);

    return FinalDispatchResult(success: true, recordId: id);
  }

  Future<List<Map<String, dynamic>>> getRecent({int limit = 30}) async {
    final rows = _db.db.select(
      'SELECT fd.*, p.name as part_name, p.code as part_code, c.name as customer_name '
      'FROM final_dispatches fd '
      'LEFT JOIN parts p ON p.id = fd.part_id '
      'LEFT JOIN customers c ON c.id = fd.customer_id '
      'ORDER BY fd.date DESC LIMIT ?',
      [limit],
    );
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  Future<String?> getDefaultCustomerId() async {
    final rows = _db.db.select(
      'SELECT id FROM customers WHERE is_default = 1 LIMIT 1',
    );
    if (rows.isEmpty) return null;
    return rows.first['id'] as String;
  }
}

final finalDispatchRepositoryProvider = Provider<FinalDispatchRepository>((ref) {
  return FinalDispatchRepository(
    ref.watch(databaseServiceProvider),
    ref.watch(syncServiceProvider),
    ref.watch(stockLedgerServiceProvider),
  );
});

final finalDispatchListProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  return ref.watch(finalDispatchRepositoryProvider).getRecent();
});

class FinalDispatchResult {
  const FinalDispatchResult({required this.success, this.error, this.recordId});
  final bool success;
  final String? error;
  final String? recordId;
}
