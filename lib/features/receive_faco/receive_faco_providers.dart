import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/database/database_service.dart';
import '../../core/network/sync_service.dart';
import '../../core/services/stock_ledger_service.dart';

const _uuid = Uuid();

class ReceiveFacoRepository {
  ReceiveFacoRepository(this._db, this._sync, this._ledger);

  final DatabaseService _db;
  final SyncService _sync;
  final StockLedgerService _ledger;

  Future<ReceiveFacoResult> save({
    required String batchNumber,
    required String partId,
    required double qtyReceived,
    String? dispatchRefId,
    String? supplierChallan,
    String? remarks,
    required String createdBy,
    DateTime? recordedAt,
  }) async {
    // Shortage check: compare with dispatched qty (PRD 3.7 — allowed, flagged)
    double? dispatchedQty;
    bool shortageFlag = false;
    if (dispatchRefId != null) {
      final rows = _db.db.select(
        'SELECT qty FROM dispatch_to_facos WHERE id = ?',
        [dispatchRefId],
      );
      if (rows.isNotEmpty) {
        dispatchedQty = (rows.first['qty'] as num).toDouble();
        shortageFlag = qtyReceived < dispatchedQty;
      }
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
      'qty_received': qtyReceived,
      'dispatch_ref_id': dispatchRefId,
      'supplier_challan': supplierChallan,
      'shortage_flag': shortageFlag ? 1 : 0,
      'remarks': remarks,
      'created_by': createdBy,
      'sync_status': 'pending',
    };

    // Stock: At Faco OUT → Pending AP IN (PRD 7.1)
    final ledgerResult = await _ledger.receiveFromFaco(
      partId: partId,
      qty: qtyReceived,
      refId: id,
    );
    if (!ledgerResult.success) {
      return ReceiveFacoResult(success: false, error: ledgerResult.error);
    }

    await _db.insertRecord('receive_from_facos', record);

    await _sync.queueInsert(tableName: 'receive_from_facos', recordId: id, payload: record);

    return ReceiveFacoResult(
      success: true,
      recordId: id,
      shortageFlag: shortageFlag,
      dispatchedQty: dispatchedQty,
    );
  }

  Future<List<Map<String, dynamic>>> getRecent({int limit = 30}) async {
    final rows = _db.db.select(
      'SELECT rf.*, p.name as part_name, p.code as part_code '
      'FROM receive_from_facos rf '
      'LEFT JOIN parts p ON p.id = rf.part_id '
      'ORDER BY rf.date DESC LIMIT ?',
      [limit],
    );
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  Future<List<Map<String, dynamic>>> getPendingDispatches(String partId) async {
    final rows = _db.db.select(
      'SELECT id, batch_number, qty, date FROM dispatch_to_facos WHERE part_id = ? ORDER BY date DESC LIMIT 20',
      [partId],
    );
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }
}

final receiveFacoRepositoryProvider = Provider<ReceiveFacoRepository>((ref) {
  return ReceiveFacoRepository(
    ref.watch(databaseServiceProvider),
    ref.watch(syncServiceProvider),
    ref.watch(stockLedgerServiceProvider),
  );
});

final receiveFacoListProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  return ref.watch(receiveFacoRepositoryProvider).getRecent();
});

class ReceiveFacoResult {
  const ReceiveFacoResult({
    required this.success,
    this.error,
    this.recordId,
    this.shortageFlag = false,
    this.dispatchedQty,
  });
  final bool success;
  final String? error;
  final String? recordId;
  final bool shortageFlag;
  final double? dispatchedQty;
}
