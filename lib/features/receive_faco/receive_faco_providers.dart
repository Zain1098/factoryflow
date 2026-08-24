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
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) {
      return const ReceiveFacoResult(
        success: false,
        error: 'No active factory workspace is selected.',
      );
    }
    if (qtyReceived <= 0) {
      return const ReceiveFacoResult(
        success: false,
        error: 'Received quantity must be greater than zero.',
      );
    }

    // Shortage check: compare with dispatched qty (PRD 3.7 — allowed, flagged)
    if (dispatchRefId == null) {
      return const ReceiveFacoResult(
        success: false,
        error: 'Select the original vendor dispatch before receiving material.',
      );
    }
    double? dispatchedQty;
    bool shortageFlag = false;
    final rows = _db.db.select(
      'SELECT qty, batch_number FROM dispatch_to_facos '
      'WHERE factory_id = ? AND id = ? AND part_id = ?',
      [factoryId, dispatchRefId, partId],
    );
    if (rows.isEmpty) {
      return const ReceiveFacoResult(
        success: false,
        error: 'The selected vendor dispatch is no longer available.',
      );
    }
    final dispatchBatch = rows.first['batch_number'] as String? ?? '';
    if (dispatchBatch.isEmpty || dispatchBatch != batchNumber) {
      return const ReceiveFacoResult(
        success: false,
        error:
            'Select the original vendor dispatch; batch numbers cannot be entered manually.',
      );
    }
    dispatchedQty = (rows.first['qty'] as num).toDouble();
    final receivedRows = _db.db.select(
      'SELECT COALESCE(SUM(qty_received), 0) AS received '
      'FROM receive_from_facos '
      'WHERE factory_id = ? AND dispatch_ref_id = ?',
      [factoryId, dispatchRefId],
    );
    final alreadyReceived =
        (receivedRows.first['received'] as num).toDouble();
    final remaining = dispatchedQty - alreadyReceived;
    if (remaining <= 0) {
      return const ReceiveFacoResult(
        success: false,
        error: 'This vendor dispatch has already been received in full.',
      );
    }
    if (qtyReceived > remaining) {
      return ReceiveFacoResult(
        success: false,
        error:
            'Received quantity (${qtyReceived.toInt()}) exceeds the remaining dispatch quantity (${remaining.toInt()} PCS).',
      );
    }
    shortageFlag = qtyReceived < remaining;

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
      'qty_received': qtyReceived,
      'dispatch_ref_id': dispatchRefId,
      'supplier_challan': supplierChallan,
      'shortage_flag': shortageFlag ? 1 : 0,
      'remarks': remarks,
      'created_by': createdBy,
      'sync_status': 'pending',
    };

    // Stock: At vendor OUT → Pending AP IN (PRD 7.1)
    try {
      await _db.runInTransaction(() async {
        final ledgerResult = await _ledger.receiveFromFaco(
          partId: partId,
          qty: qtyReceived,
          refId: id,
          triggerSync: false,
        );
        if (!ledgerResult.success) {
          throw StockPostingFailure(
            ledgerResult.error ?? 'Unable to update vendor receipt stock.',
          );
        }

        await _db.insertRecord('receive_from_facos', record);
        final syncPayload = Map<String, dynamic>.from(record)
          ..['shortage_flag'] = shortageFlag;
        await _sync.queueInsert(
          tableName: 'receive_from_facos',
          recordId: id,
          payload: syncPayload,
          triggerSync: false,
        );
      });
    } on StockPostingFailure catch (error) {
      return ReceiveFacoResult(success: false, error: error.message);
    } catch (_) {
      return const ReceiveFacoResult(
        success: false,
        error:
            'Vendor receipt could not be saved. No stock was changed. Please retry.',
      );
    }

    await _sync.schedulePendingSync();
    return ReceiveFacoResult(
      success: true,
      recordId: id,
      shortageFlag: shortageFlag,
      dispatchedQty: dispatchedQty,
    );
  }

  Future<List<Map<String, dynamic>>> getRecent({int limit = 30}) async {
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) return [];
    final rows = _db.db.select(
      'SELECT rf.*, p.name as part_name, p.code as part_code '
      'FROM receive_from_facos rf '
      'LEFT JOIN parts p ON p.id = rf.part_id AND p.factory_id = rf.factory_id '
      'WHERE rf.factory_id = ? '
      'ORDER BY rf.date DESC LIMIT ?',
      [factoryId, limit],
    );
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  Future<List<Map<String, dynamic>>> getPendingDispatches(String partId) async {
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) return [];
    final rows = _db.db.select(
      '''SELECT df.id, df.batch_number, df.qty, df.date,
                p.code AS part_code, p.name AS part_name,
                df.qty - COALESCE(SUM(rf.qty_received), 0) AS remaining_qty
         FROM dispatch_to_facos df
         LEFT JOIN parts p ON p.id = df.part_id AND p.factory_id = df.factory_id
         LEFT JOIN receive_from_facos rf
           ON rf.factory_id = df.factory_id AND rf.dispatch_ref_id = df.id
         WHERE df.factory_id = ? AND df.part_id = ?
         GROUP BY df.id, df.batch_number, df.qty, df.date, p.code, p.name
         HAVING df.qty - COALESCE(SUM(rf.qty_received), 0) > 0
         ORDER BY df.date DESC LIMIT 20''',
      [factoryId, partId],
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

final receiveFacoListProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
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
