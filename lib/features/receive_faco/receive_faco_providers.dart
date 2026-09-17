import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants/stock_stages.dart';
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
  }) {
    return saveMulti(
      items: [
        ReceiveFacoLineItem(
          partId: partId,
          partCode: '',
          partName: '',
          qty: qtyReceived,
          batchNumber: batchNumber,
          dispatchRefId: dispatchRefId,
        ),
      ],
      supplierChallan: supplierChallan,
      remarks: remarks,
      createdBy: createdBy,
      recordedAt: recordedAt,
    );
  }

  Future<ReceiveFacoResult> saveMulti({
    required List<ReceiveFacoLineItem> items,
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
    if (items.isEmpty) {
      return const ReceiveFacoResult(
        success: false,
        error: 'Add at least one batch to receive.',
      );
    }

    for (final item in items) {
      if (item.qty <= 0) {
        return ReceiveFacoResult(
          success: false,
          error:
              'Received quantity for ${item.partCode.isNotEmpty ? item.partCode : item.batchNumber} must be greater than zero.',
        );
      }
    }

    final now = recordedAt ?? DateTime.now();
    final dateStr =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

    final recordsToInsert = <Map<String, dynamic>>[];
    final ledgerActions = <({String partId, double qty, String refId})>[];
    bool anyShortage = false;
    double? lastDispatchedQty;

    // Aggregate requested quantities per dispatchRefId and per part across all items
    final Map<String, double> requestedByDispatchRef = {};
    final Map<String, double> requestedByPart = {};
    for (final item in items) {
      final ref = item.dispatchRefId ?? 'OPEN-AT-FACO-${item.partId}';
      requestedByDispatchRef[ref] =
          (requestedByDispatchRef[ref] ?? 0.0) + item.qty;
      requestedByPart[item.partId] =
          (requestedByPart[item.partId] ?? 0.0) + item.qty;
    }

    final Set<String> validatedRefs = {};

    for (final item in items) {
      final partId = item.partId;
      final qtyReceived = item.qty;
      final dispatchRefId = item.dispatchRefId;
      double? dispatchedQty;
      bool shortageFlag = false;

      if (dispatchRefId != null && dispatchRefId.startsWith('OPEN-AT-FACO-')) {
        final availableVendorStock =
            await _ledger.getAvailableStock(partId, StockStage.atFaco);
        final totalOpenReq =
            requestedByDispatchRef[dispatchRefId] ?? qtyReceived;
        if (totalOpenReq > availableVendorStock) {
          return ReceiveFacoResult(
            success: false,
            error:
                'Total received quantity (${totalOpenReq.toInt()}) exceeds available Vendor Stock (${availableVendorStock.toInt()} PCS).',
          );
        }
        dispatchedQty = availableVendorStock;
        shortageFlag = qtyReceived < availableVendorStock;
      } else if (dispatchRefId != null) {
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
        dispatchedQty = (rows.first['qty'] as num?)?.toDouble() ?? 0.0;
        final receivedRows = _db.db.select(
          'SELECT COALESCE(SUM(qty_received), 0) AS received '
          'FROM receive_from_facos '
          'WHERE factory_id = ? AND dispatch_ref_id = ?',
          [factoryId, dispatchRefId],
        );
        final alreadyReceived =
            (receivedRows.firstOrNull?['received'] as num?)?.toDouble() ?? 0.0;
        final remaining = dispatchedQty - alreadyReceived;
        if (remaining <= 0) {
          return const ReceiveFacoResult(
            success: false,
            error: 'This vendor dispatch has already been received in full.',
          );
        }

        if (!validatedRefs.contains(dispatchRefId)) {
          validatedRefs.add(dispatchRefId);
          final totalDispReq =
              requestedByDispatchRef[dispatchRefId] ?? qtyReceived;
          if (totalDispReq > remaining) {
            return ReceiveFacoResult(
              success: false,
              error:
                  'Total received quantity (${totalDispReq.toInt()}) exceeds remaining dispatch quantity (${remaining.toInt()} PCS).',
            );
          }
        }
        shortageFlag = qtyReceived < remaining;
      } else {
        final availableVendorStock =
            await _ledger.getAvailableStock(partId, StockStage.atFaco);
        final totalPartReq = requestedByPart[partId] ?? qtyReceived;
        if (totalPartReq > availableVendorStock) {
          return ReceiveFacoResult(
            success: false,
            error:
                'Total received quantity (${totalPartReq.toInt()}) exceeds available Vendor Stock (${availableVendorStock.toInt()} PCS).',
          );
        }
        dispatchedQty = availableVendorStock;
        shortageFlag = qtyReceived < availableVendorStock;
      }

      if (shortageFlag) anyShortage = true;
      lastDispatchedQty = dispatchedQty;

      final id = _uuid.v4();
      final effectiveBatch =
          item.batchNumber.trim().isNotEmpty ? item.batchNumber.trim() : 'OPEN';

      final record = {
        'id': id,
        'factory_id': factoryId,
        'batch_number': effectiveBatch,
        'date': dateStr,
        'part_id': partId,
        'qty_received': qtyReceived,
        'dispatch_ref_id': dispatchRefId ?? 'OPEN-AT-FACO-$partId',
        'supplier_challan': supplierChallan?.trim().isEmpty == true ? null : supplierChallan?.trim(),
        'shortage_flag': shortageFlag ? 1 : 0,
        'remarks': remarks?.trim().isEmpty == true ? null : remarks?.trim(),
        'created_by': createdBy,
        'sync_status': 'pending',
      };

      recordsToInsert.add(record);
      ledgerActions.add((partId: partId, qty: qtyReceived, refId: id));
    }

    try {
      await _db.runInTransaction(() async {
        for (var i = 0; i < recordsToInsert.length; i++) {
          final record = recordsToInsert[i];
          final action = ledgerActions[i];

          final ledgerResult = await _ledger.receiveFromFaco(
            partId: action.partId,
            qty: action.qty,
            refId: action.refId,
            triggerSync: false,
          );
          if (!ledgerResult.success) {
            throw StockPostingFailure(
              ledgerResult.error ?? 'Unable to update vendor receipt stock.',
            );
          }

          await _db.insertRecord('receive_from_facos', record);
          final syncPayload = Map<String, dynamic>.from(record);
          await _sync.queueInsert(
            tableName: 'receive_from_facos',
            recordId: action.refId,
            payload: syncPayload,
            triggerSync: false,
          );
        }
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
      recordId: recordsToInsert.firstOrNull?['id'] as String?,
      shortageFlag: anyShortage,
      dispatchedQty: lastDispatchedQty,
    );
  }

  Future<List<Map<String, dynamic>>> getRecent({
    int limit = 50,
    String? date,
  }) async {
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) return [];

    final whereClause = date != null
        ? 'WHERE rf.factory_id = ? AND (TRIM(rf.date) = ? OR rf.date LIKE ? OR date(rf.date) = ?) '
        : 'WHERE rf.factory_id = ? ';
    final params =
        date != null ? [factoryId, date, '$date%', date] : [factoryId, limit];
    final orderBy = date != null
        ? 'ORDER BY rf.date DESC, rf.rowid DESC'
        : 'ORDER BY rf.date DESC, rf.rowid DESC LIMIT ?';

    final rows = _db.db.select(
      '''SELECT rf.*,
                p.name as part_name,
                p.code as part_code,
                v.name as vendor_name,
                df.qty as dispatched_qty,
                df.batch_number as dispatch_batch_number,
                df.challan_number as dispatch_challan
         FROM receive_from_facos rf
         LEFT JOIN parts p ON p.id = rf.part_id AND p.factory_id = rf.factory_id
         LEFT JOIN dispatch_to_facos df ON df.id = rf.dispatch_ref_id AND df.factory_id = rf.factory_id
         LEFT JOIN vendors v ON v.id = df.vendor_id AND v.factory_id = rf.factory_id
         $whereClause
         $orderBy''',
      params,
    );
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  /// Safely delete a vendor receipt record and revert its stock movement.
  /// Reversal:
  /// - Deducts received qty from pendingAp (Pending AP Inspection)
  /// - Returns received qty back to at_faco (Vendor Stock)
  /// If material was already inspected or consumed downstream, deletion is blocked!
  Future<({bool success, String error})> deleteReceiptRecord({
    required String receiptId,
    required String userId,
    String reason = 'Vendor receipt deleted by user',
  }) async {
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) {
      return (success: false, error: 'No active factory workspace selected.');
    }

    final rows = _db.db.select(
      'SELECT * FROM receive_from_facos WHERE factory_id = ? AND id = ?',
      [factoryId, receiptId],
    );
    if (rows.isEmpty) {
      return (success: false, error: 'Receipt record not found.');
    }

    final rec = rows.first;
    final partId = rec['part_id'] as String;
    final qtyReceived = (rec['qty_received'] as num?)?.toDouble() ?? 0.0;

    // Downstream safety: Check if pendingAp stock has enough balance.
    // If pendingAp < qtyReceived, downstream AP inspection has already consumed this material.
    final currentPendingAp =
        await _ledger.getAvailableStock(partId, StockStage.pendingAp);
    if (currentPendingAp < qtyReceived) {
      return (
        success: false,
        error:
            'Cannot delete receipt: Available Pending AP stock (${currentPendingAp.toInt()} PCS) is less than receipt quantity (${qtyReceived.toInt()} PCS). Downstream AP Inspection has already consumed this material.',
      );
    }

    try {
      await _db.runInTransaction(() async {
        // Revert stock: Deduct from Pending AP, Return to Vendor Stock
        final outPendingResult = await _ledger.manualAdjustment(
          partId: partId,
          stage: StockStage.pendingAp,
          direction: LedgerDirection.out,
          qty: qtyReceived,
          refId: 'REC-REV-$receiptId',
          triggerSync: false,
        );
        if (!outPendingResult.success) {
          throw StockPostingFailure(
            outPendingResult.error ?? 'Failed to deduct from Pending AP stock.',
          );
        }

        final inVendorResult = await _ledger.manualAdjustment(
          partId: partId,
          stage: StockStage.atFaco,
          direction: LedgerDirection.in_,
          qty: qtyReceived,
          refId: 'REC-REV-$receiptId',
          triggerSync: false,
        );
        if (!inVendorResult.success) {
          throw StockPostingFailure(
            inVendorResult.error ?? 'Failed to return to Vendor stock.',
          );
        }

        // Back up before deleting
        await _db.backupAndDeleteRecord(
          table: 'receive_from_facos',
          recordId: receiptId,
          userId: userId,
          factoryId: factoryId,
          reason: reason,
        );

        await _sync.queueDelete(
          tableName: 'receive_from_facos',
          recordId: receiptId,
          factoryId: factoryId,
          triggerSync: false,
        );
      });
    } on StockPostingFailure catch (e) {
      return (success: false, error: e.message);
    } catch (e) {
      return (success: false, error: 'Failed to delete receipt: $e');
    }

    await _sync.schedulePendingSync();
    return (success: true, error: '');
  }

  /// Safely update a vendor receipt record and automatically adjust stock differences.
  Future<({bool success, String error})> updateReceiptRecord({
    required String receiptId,
    required double newQty,
    String? supplierChallan,
    String? remarks,
    required String userId,
  }) async {
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) {
      return (success: false, error: 'No active factory workspace selected.');
    }
    if (newQty <= 0) {
      return (
        success: false,
        error: 'Received quantity must be greater than zero.',
      );
    }

    final rows = _db.db.select(
      'SELECT * FROM receive_from_facos WHERE factory_id = ? AND id = ?',
      [factoryId, receiptId],
    );
    if (rows.isEmpty) {
      return (success: false, error: 'Receipt record not found.');
    }

    final rec = rows.first;
    final partId = rec['part_id'] as String;
    final oldQty = (rec['qty_received'] as num?)?.toDouble() ?? 0.0;
    final dispatchRefId = rec['dispatch_ref_id'] as String?;
    final qtyDiff = newQty - oldQty;

    // Dispatched qty check for shortage recalculation & capacity
    double? dispatchedQty;
    if (dispatchRefId != null && !dispatchRefId.startsWith('OPEN-')) {
      final dispRows = _db.db.select(
        'SELECT qty FROM dispatch_to_facos WHERE factory_id = ? AND id = ?',
        [factoryId, dispatchRefId],
      );
      if (dispRows.isNotEmpty) {
        dispatchedQty = (dispRows.first['qty'] as num?)?.toDouble() ?? 0.0;
        final otherReceipts = _db.db.select(
          'SELECT COALESCE(SUM(qty_received), 0) AS total_other '
          'FROM receive_from_facos WHERE factory_id = ? AND dispatch_ref_id = ? AND id != ?',
          [factoryId, dispatchRefId, receiptId],
        );
        final otherTotal =
            (otherReceipts.firstOrNull?['total_other'] as num?)?.toDouble() ?? 0.0;
        if (newQty + otherTotal > dispatchedQty) {
          final maxAllowed = dispatchedQty - otherTotal;
          return (
            success: false,
            error:
                'Received qty (${newQty.toInt()}) exceeds remaining dispatch qty (${maxAllowed.toInt()} PCS).',
          );
        }
      }
    }

    if (qtyDiff > 0) {
      // User is increasing received quantity: requires more stock from Vendor (atFaco)
      final availableAtFaco =
          await _ledger.getAvailableStock(partId, StockStage.atFaco);
      if (availableAtFaco < qtyDiff) {
        return (
          success: false,
          error:
              'Cannot increase receipt: Available Vendor Stock (${availableAtFaco.toInt()} PCS) is less than additional required (${qtyDiff.toInt()} PCS).',
        );
      }
    } else if (qtyDiff < 0) {
      // User is reducing received quantity: requires returning material from Pending AP
      final reduction = -qtyDiff;
      final currentPendingAp =
          await _ledger.getAvailableStock(partId, StockStage.pendingAp);
      if (currentPendingAp < reduction) {
        return (
          success: false,
          error:
              'Cannot reduce receipt: Available Pending AP stock (${currentPendingAp.toInt()} PCS) is less than reduction (${reduction.toInt()} PCS). Downstream AP Inspection has already consumed this material.',
        );
      }
    }

    final isShortage = dispatchedQty != null && newQty < dispatchedQty;

    try {
      await _db.runInTransaction(() async {
        if (qtyDiff > 0) {
          // Move additional from atFaco -> pendingAp
          final outResult = await _ledger.manualAdjustment(
            partId: partId,
            stage: StockStage.atFaco,
            direction: LedgerDirection.out,
            qty: qtyDiff,
            refId: 'REC-UPD-$receiptId',
            triggerSync: false,
          );
          if (!outResult.success) {
            throw StockPostingFailure(
              outResult.error ?? 'Failed to deduct from Vendor stock.',
            );
          }

          final inResult = await _ledger.manualAdjustment(
            partId: partId,
            stage: StockStage.pendingAp,
            direction: LedgerDirection.in_,
            qty: qtyDiff,
            refId: 'REC-UPD-$receiptId',
            triggerSync: false,
          );
          if (!inResult.success) {
            throw StockPostingFailure(
              inResult.error ?? 'Failed to add to Pending AP stock.',
            );
          }
        } else if (qtyDiff < 0) {
          // Return reduction from pendingAp -> atFaco
          final reduction = -qtyDiff;
          final outResult = await _ledger.manualAdjustment(
            partId: partId,
            stage: StockStage.pendingAp,
            direction: LedgerDirection.out,
            qty: reduction,
            refId: 'REC-UPD-$receiptId',
            triggerSync: false,
          );
          if (!outResult.success) {
            throw StockPostingFailure(
              outResult.error ?? 'Failed to deduct from Pending AP stock.',
            );
          }

          final inResult = await _ledger.manualAdjustment(
            partId: partId,
            stage: StockStage.atFaco,
            direction: LedgerDirection.in_,
            qty: reduction,
            refId: 'REC-UPD-$receiptId',
            triggerSync: false,
          );
          if (!inResult.success) {
            throw StockPostingFailure(
              inResult.error ?? 'Failed to return to Vendor stock.',
            );
          }
        }

        // Update database row
        _db.db.execute(
          '''UPDATE receive_from_facos
             SET qty_received = ?,
                 supplier_challan = ?,
                 remarks = ?,
                 shortage_flag = ?,
                 sync_status = 'pending'
             WHERE factory_id = ? AND id = ?''',
          [
            newQty,
            supplierChallan?.trim().isEmpty == true
                ? null
                : supplierChallan?.trim(),
            remarks?.trim().isEmpty == true ? null : remarks?.trim(),
            isShortage ? 1 : 0,
            factoryId,
            receiptId,
          ],
        );

        final updatedRows = _db.db.select(
          'SELECT * FROM receive_from_facos WHERE factory_id = ? AND id = ?',
          [factoryId, receiptId],
        );
        if (updatedRows.isNotEmpty) {
          final payload = Map<String, dynamic>.from(updatedRows.first);
          await _sync.queueUpdate(
            tableName: 'receive_from_facos',
            recordId: receiptId,
            payload: payload,
            triggerSync: false,
          );
        }
      });
    } on StockPostingFailure catch (e) {
      return (success: false, error: e.message);
    } catch (e) {
      return (success: false, error: 'Failed to update receipt: $e');
    }

    await _sync.schedulePendingSync();
    return (success: true, error: '');
  }

  Future<List<Map<String, dynamic>>> getPendingDispatches(
    String partId, {
    String? vendorId,
  }) async {
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) return [];

    final where = StringBuffer('df.factory_id = ? AND df.part_id = ?');
    final params = <Object?>[factoryId, partId];
    if (vendorId != null && vendorId.isNotEmpty) {
      where.write(' AND df.vendor_id = ?');
      params.add(vendorId);
    }

    final rows = _db.db.select(
      '''SELECT df.id, df.batch_number, df.qty, df.date, df.time,
                df.vendor_id, v.name AS vendor_name,
                COALESCE(df.challan_number, '') AS dispatch_challan,
                p.code AS part_code, p.name AS part_name,
                df.qty - COALESCE(SUM(rf.qty_received), 0) AS remaining_qty
         FROM dispatch_to_facos df
         LEFT JOIN parts p ON p.id = df.part_id AND p.factory_id = df.factory_id
         LEFT JOIN vendors v ON v.id = df.vendor_id AND v.factory_id = df.factory_id
         LEFT JOIN receive_from_facos rf
           ON rf.factory_id = df.factory_id AND rf.dispatch_ref_id = df.id
         WHERE $where
         GROUP BY df.id, df.batch_number, df.qty, df.date, df.time, df.vendor_id, v.name, df.challan_number, p.code, p.name
         HAVING df.qty - COALESCE(SUM(rf.qty_received), 0) > 0
         ORDER BY df.date DESC LIMIT 30''',
      params,
    );
    final list = rows.map((r) => Map<String, dynamic>.from(r)).toList();

    // Check if there is manual / opening at_faco stock in the stock ledger
    // (Only added when viewing all pending dispatches, not filtered to a single vendor)
    if (vendorId == null || vendorId.isEmpty) {
      final totalAtVendor =
          await _ledger.getAvailableStock(partId, StockStage.atFaco);
      final trackedDispatches = list.fold<double>(
        0.0,
        (sum, r) => sum + ((r['remaining_qty'] as num?)?.toDouble() ?? 0.0),
      );
      final unbatched = totalAtVendor - trackedDispatches;

      if (unbatched > 0) {
        final partRows = _db.db.select(
          'SELECT code, name FROM parts WHERE factory_id = ? AND id = ?',
          [factoryId, partId],
        );
        final code =
            partRows.isNotEmpty ? partRows.first['code'] as String? ?? '' : '';
        final name =
            partRows.isNotEmpty ? partRows.first['name'] as String? ?? '' : '';

        list.add({
          'id': 'OPEN-AT-FACO-$partId',
          'batch_number': 'OPEN-$code',
          'qty': unbatched,
          'date': DateTime.now().toIso8601String().substring(0, 10),
          'part_code': code,
          'part_name': name,
          'vendor_name': 'Opening Vendor Stock',
          'dispatch_challan': 'OPEN',
          'remaining_qty': unbatched,
        });
      }
    }

    return list;
  }

  /// Fast lookup of pending dispatch by challan number, batch number, or code
  /// Used for barcode scanning and quick search.
  Future<List<Map<String, dynamic>>> lookupPendingDispatch(String query) async {
    final factoryId = _db.activeWorkspaceId.trim();
    final q = query.trim();
    if (factoryId.isEmpty || q.isEmpty) return [];

    final rows = _db.db.select(
      '''SELECT df.id, df.batch_number, df.qty, df.date, df.time,
                df.part_id, df.vendor_id, v.name AS vendor_name,
                COALESCE(df.challan_number, '') AS dispatch_challan,
                p.code AS part_code, p.name AS part_name,
                df.qty - COALESCE(SUM(rf.qty_received), 0) AS remaining_qty
         FROM dispatch_to_facos df
         LEFT JOIN parts p ON p.id = df.part_id AND p.factory_id = df.factory_id
         LEFT JOIN vendors v ON v.id = df.vendor_id AND v.factory_id = df.factory_id
         LEFT JOIN receive_from_facos rf
           ON rf.factory_id = df.factory_id AND rf.dispatch_ref_id = df.id
         WHERE df.factory_id = ?
           AND (df.challan_number = ? OR df.batch_number = ? OR df.challan_number LIKE ? OR df.batch_number LIKE ?)
         GROUP BY df.id, df.batch_number, df.qty, df.date, df.time, df.part_id, df.vendor_id, v.name, df.challan_number, p.code, p.name
         HAVING df.qty - COALESCE(SUM(rf.qty_received), 0) > 0
         ORDER BY df.date DESC LIMIT 10''',
      [factoryId, q, q, '%$q%', '%$q%'],
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

class ReceiveFacoHistoryDateFilterNotifier extends Notifier<DateTime?> {
  @override
  DateTime? build() => null;

  void setDate(DateTime? date) => state = date;
}

final receiveFacoHistoryDateFilterProvider =
    NotifierProvider<ReceiveFacoHistoryDateFilterNotifier, DateTime?>(
  ReceiveFacoHistoryDateFilterNotifier.new,
);

final receiveFacoListProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final date = ref.watch(receiveFacoHistoryDateFilterProvider);
  final dateStr = date != null
      ? '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}'
      : null;
  return ref.watch(receiveFacoRepositoryProvider).getRecent(date: dateStr);
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

class ReceiveFacoLineItem {
  const ReceiveFacoLineItem({
    required this.partId,
    required this.partCode,
    required this.partName,
    required this.qty,
    required this.batchNumber,
    this.dispatchRefId,
  });

  final String partId;
  final String partCode;
  final String partName;
  final double qty;
  final String batchNumber;
  final String? dispatchRefId;
}

