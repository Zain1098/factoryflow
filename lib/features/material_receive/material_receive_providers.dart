import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants/app_constants.dart';
import '../../core/database/database_service.dart';
import '../../core/network/sync_service.dart';
import '../../core/services/alert_producer_service.dart';
import '../../core/services/stock_ledger_service.dart';

const _uuid = Uuid();

const kPoStatuses = ['pending', 'processing', 'received', 'cancelled'];

// ─── Purchase Order Repository ────────────────────────────────────────────────

class PurchaseOrderRepository {
  PurchaseOrderRepository(this._db, this._sync);

  final DatabaseService _db;
  final SyncService _sync;

  String? _lastPoFingerprint;
  DateTime? _lastPoTime;
  PurchaseOrderResult? _lastPoResult;

  Future<PurchaseOrderResult> save({
    required String partId,
    required double orderedQty,
    required String supplierId,
    String? poNumber,
    String? remarks,
    required String createdBy,
    DateTime? recordedAt,
  }) async {
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) {
      return const PurchaseOrderResult(
        success: false,
        error: 'No active factory workspace is selected.',
      );
    }
    if (orderedQty <= 0) {
      return const PurchaseOrderResult(
        success: false,
        error: 'Ordered quantity must be greater than zero.',
      );
    }

    final fingerprint =
        '$factoryId|$partId|$supplierId|$orderedQty|${poNumber?.trim()}';
    if (_lastPoFingerprint == fingerprint &&
        _lastPoTime != null &&
        DateTime.now().difference(_lastPoTime!) < const Duration(seconds: 4)) {
      return _lastPoResult ?? const PurchaseOrderResult(success: true);
    }

    final id = _uuid.v4();
    final now = recordedAt ?? DateTime.now();
    final dateStr =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final timeStr =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    final effectivePoNumber = (poNumber != null && poNumber.trim().isNotEmpty)
        ? poNumber.trim()
        : await generateNextPoNumber(date: now);

    final record = {
      'id': id,
      'factory_id': factoryId,
      'date': dateStr,
      'time': timeStr,
      'part_id': partId,
      'supplier_id': supplierId,
      'ordered_qty': orderedQty,
      'po_number': effectivePoNumber,
      'status': 'pending',
      'remarks': remarks,
      'created_by': createdBy,
      'created_at': now.toIso8601String(),
      'sync_status': 'pending',
    };

    try {
      await _db.runInTransaction(() async {
        await _db.insertRecord('purchase_orders', record);
        await _sync.queueInsert(
          tableName: 'purchase_orders',
          recordId: id,
          payload: record,
          triggerSync: false,
        );
      });
    } catch (_) {
      return const PurchaseOrderResult(
        success: false,
        error: 'Purchase order could not be saved. Please retry.',
      );
    }

    await _sync.schedulePendingSync();
    final result = PurchaseOrderResult(success: true, recordId: id);
    _lastPoFingerprint = fingerprint;
    _lastPoTime = DateTime.now();
    _lastPoResult = result;
    return result;
  }

  Future<PurchaseOrderResult> updateStatus(String id, String status) async {
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) {
      return const PurchaseOrderResult(
        success: false,
        error: 'No active factory workspace is selected.',
      );
    }
    if (!kPoStatuses.contains(status)) {
      return PurchaseOrderResult(
        success: false,
        error: 'Invalid purchase order status: $status',
      );
    }
    try {
      await _db.runInTransaction(() async {
        await _db.updatePurchaseOrderStatus(id, status);
        await _sync.queueUpdate(
          tableName: 'purchase_orders',
          recordId: id,
          payload: {'id': id, 'factory_id': factoryId, 'status': status},
          triggerSync: false,
        );
      });
    } catch (_) {
      return const PurchaseOrderResult(
        success: false,
        error: 'Purchase order status could not be updated. Please retry.',
      );
    }
    await _sync.schedulePendingSync();
    return PurchaseOrderResult(success: true, recordId: id);
  }

  Future<PurchaseOrderResult> update({
    required String id,
    required String partId,
    required double orderedQty,
    required String supplierId,
    String? poNumber,
    String? status,
    String? remarks,
    DateTime? recordedAt,
  }) async {
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) {
      return const PurchaseOrderResult(
        success: false,
        error: 'No active factory workspace is selected.',
      );
    }
    if (orderedQty <= 0) {
      return const PurchaseOrderResult(
        success: false,
        error: 'Ordered quantity must be greater than zero.',
      );
    }

    final updatePayload = <String, dynamic>{
      'part_id': partId,
      'supplier_id': supplierId,
      'ordered_qty': orderedQty,
      'po_number': poNumber,
      'remarks': remarks,
      'sync_status': 'pending',
    };
    if (status != null && kPoStatuses.contains(status)) {
      updatePayload['status'] = status;
    }
    if (recordedAt != null) {
      updatePayload['date'] =
          '${recordedAt.year}-${recordedAt.month.toString().padLeft(2, '0')}-${recordedAt.day.toString().padLeft(2, '0')}';
      updatePayload['time'] =
          '${recordedAt.hour.toString().padLeft(2, '0')}:${recordedAt.minute.toString().padLeft(2, '0')}';
    }

    try {
      await _db.runInTransaction(() async {
        final setClauses = updatePayload.keys.map((k) => '$k = ?').join(', ');
        final values = [...updatePayload.values, factoryId, id];
        _db.db.execute(
          'UPDATE purchase_orders SET $setClauses WHERE factory_id = ? AND id = ?',
          values,
        );
        await _sync.queueUpdate(
          tableName: 'purchase_orders',
          recordId: id,
          payload: {'id': id, 'factory_id': factoryId, ...updatePayload},
          triggerSync: false,
        );
      });
    } catch (e) {
      return PurchaseOrderResult(
        success: false,
        error: 'Purchase order could not be updated: $e',
      );
    }

    await _sync.schedulePendingSync();
    return PurchaseOrderResult(success: true, recordId: id);
  }

  Future<PurchaseOrderResult> delete(String id) async {
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) {
      return const PurchaseOrderResult(
        success: false,
        error: 'No active factory workspace is selected.',
      );
    }

    try {
      await _db.runInTransaction(() async {
        _db.db.execute(
          'DELETE FROM purchase_orders WHERE factory_id = ? AND id = ?',
          [factoryId, id],
        );
        _db.db.execute(
          'UPDATE material_receives SET po_ref_id = NULL WHERE factory_id = ? AND po_ref_id = ?',
          [factoryId, id],
        );
        await _sync.queueDelete(
          tableName: 'purchase_orders',
          recordId: id,
          factoryId: factoryId,
          triggerSync: false,
        );
      });
    } catch (e) {
      return PurchaseOrderResult(
        success: false,
        error: 'Purchase order could not be deleted: $e',
      );
    }

    await _sync.schedulePendingSync();
    return PurchaseOrderResult(success: true, recordId: id);
  }

  Future<List<Map<String, dynamic>>> getOpenForPart(String partId) =>
      _db.getOpenPurchaseOrders(partId);

  Future<Map<String, double>> getPendingRemaining() =>
      _db.getPendingPurchaseOrdersRemaining();

  Future<List<Map<String, dynamic>>> getAll({int limit = 50}) =>
      _db.getAllPurchaseOrders(limit: limit);

  Future<String> generateNextPoNumber({DateTime? date}) async {
    final d = date ?? DateTime.now();
    final day = d.day.toString().padLeft(2, '0');
    final month = d.month.toString().padLeft(2, '0');
    final prefix = 'PO-$day$month-';

    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) {
      return AppConstants.poNumberPattern(d, 1);
    }
    return _db.getNextPoNumber(factoryId, d, prefix);
  }
}

// ─── Material Receive Repository ──────────────────────────────────────────────

class MaterialReceiveRepository {
  MaterialReceiveRepository(this._db, this._sync, this._ledger, this._alerts);

  final DatabaseService _db;
  final SyncService _sync;
  final StockLedgerService _ledger;
  final AlertProducerService _alerts;

  String? _lastReceiveFingerprint;
  DateTime? _lastReceiveTime;
  MaterialReceiveResult? _lastReceiveResult;

  Future<MaterialReceiveResult> save({
    required String partId,
    required double qty,
    required String supplierId,
    String? poNumber,
    String? poRefId, // link to purchase_order id
    double? orderedQty, // from linked PO, for shortfall calc
    String? remarks,
    required String createdBy,
    DateTime? recordedAt,
  }) async {
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) {
      return const MaterialReceiveResult(
        success: false,
        error: 'No active factory workspace is selected.',
      );
    }
    if (qty <= 0) {
      return const MaterialReceiveResult(
        success: false,
        error: 'Received quantity must be greater than zero.',
      );
    }

    final fingerprint =
        '$factoryId|$partId|$supplierId|$qty|${poNumber?.trim()}|$poRefId';
    if (_lastReceiveFingerprint == fingerprint &&
        _lastReceiveTime != null &&
        DateTime.now().difference(_lastReceiveTime!) < const Duration(seconds: 4)) {
      return _lastReceiveResult ?? const MaterialReceiveResult(success: true);
    }

    final id = _uuid.v4();
    final now = recordedAt ?? DateTime.now();
    final dateStr =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final timeStr =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    final effectiveOrderedQty = orderedQty ?? qty;
    final shortfall = (effectiveOrderedQty - qty).clamp(0.0, double.infinity);

    final record = {
      'id': id,
      'factory_id': factoryId,
      'date': dateStr,
      'time': timeStr,
      'supplier_id': supplierId,
      'po_id': poNumber,
      'po_ref_id': poRefId,
      'part_id': partId,
      'qty': qty,
      'ordered_qty': effectiveOrderedQty,
      'shortfall': shortfall,
      'remarks': remarks,
      'created_by': createdBy,
      'created_at': now.toIso8601String(),
      'sync_status': 'pending',
    };

    try {
      await _db.runInTransaction(() async {
        await _db.insertRecord('material_receives', record);

        if (poRefId != null) {
          await _db.updatePurchaseOrderStatus(poRefId, 'received');
          await _sync.queueUpdate(
            tableName: 'purchase_orders',
            recordId: poRefId,
            payload: {
              'id': poRefId,
              'factory_id': factoryId,
              'status': 'received',
            },
            triggerSync: false,
          );
        }

        final ledgerResult = await _ledger.materialReceiveIn(
          partId: partId,
          qty: qty,
          refId: id,
          triggerSync: false,
        );
        if (!ledgerResult.success) {
          throw StockPostingFailure(
            ledgerResult.error ?? 'Unable to update raw material stock.',
          );
        }

        await _sync.queueInsert(
          tableName: 'material_receives',
          recordId: id,
          payload: record,
          triggerSync: false,
        );
      });
    } on StockPostingFailure catch (error) {
      return MaterialReceiveResult(success: false, error: error.message);
    } catch (_) {
      return const MaterialReceiveResult(
        success: false,
        error:
            'Material receipt could not be saved. No stock was changed. Please retry.',
      );
    }

    await _sync.schedulePendingSync();
    unawaited(_alerts.checkLowStock());
    final finalResult = MaterialReceiveResult(
      success: true,
      recordId: id,
      shortfall: shortfall,
    );
    _lastReceiveFingerprint = fingerprint;
    _lastReceiveTime = DateTime.now();
    _lastReceiveResult = finalResult;
    return finalResult;
  }

  Future<MaterialReceiveResult> update({
    required String id,
    required String partId,
    required double qty,
    required String supplierId,
    String? poNumber,
    String? poRefId,
    double? orderedQty,
    String? remarks,
    DateTime? recordedAt,
    required String updatedBy,
  }) async {
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) {
      return const MaterialReceiveResult(
        success: false,
        error: 'No active factory workspace is selected.',
      );
    }
    if (qty <= 0) {
      return const MaterialReceiveResult(
        success: false,
        error: 'Received quantity must be greater than zero.',
      );
    }

    final existingRows = _db.db.select(
      'SELECT * FROM material_receives WHERE factory_id = ? AND id = ?',
      [factoryId, id],
    );
    if (existingRows.isEmpty) {
      return const MaterialReceiveResult(
        success: false,
        error: 'Receipt record not found.',
      );
    }
    final existing = Map<String, dynamic>.from(existingRows.first);
    final oldPartId = existing['part_id'] as String;
    final oldQty = (existing['qty'] as num?)?.toDouble() ?? 0.0;
    final oldPoRefId = existing['po_ref_id'] as String?;

    final effectiveOrderedQty = orderedQty ??
        (existing['ordered_qty'] != null
            ? ((existing['ordered_qty'] as num?)?.toDouble() ?? qty)
            : qty);
    final shortfall = (effectiveOrderedQty - qty).clamp(0.0, double.infinity);

    final updatePayload = <String, dynamic>{
      'supplier_id': supplierId,
      'po_id': poNumber,
      'po_ref_id': poRefId,
      'part_id': partId,
      'qty': qty,
      'ordered_qty': effectiveOrderedQty,
      'shortfall': shortfall,
      'remarks': remarks,
      'sync_status': 'pending',
    };
    if (recordedAt != null) {
      updatePayload['date'] =
          '${recordedAt.year}-${recordedAt.month.toString().padLeft(2, '0')}-${recordedAt.day.toString().padLeft(2, '0')}';
      updatePayload['time'] =
          '${recordedAt.hour.toString().padLeft(2, '0')}:${recordedAt.minute.toString().padLeft(2, '0')}';
    }

    try {
      await _db.runInTransaction(() async {
        // Adjust stock ledger if part or qty changed
        if (oldPartId != partId || oldQty != qty) {
          final outResult = await _ledger.materialReceiveOut(
            partId: oldPartId,
            qty: oldQty,
            refId: id,
            triggerSync: false,
          );
          if (!outResult.success) {
            throw StockPostingFailure(
              outResult.error ?? 'Could not adjust previous stock.',
            );
          }
          final inResult = await _ledger.materialReceiveIn(
            partId: partId,
            qty: qty,
            refId: id,
            triggerSync: false,
          );
          if (!inResult.success) {
            throw StockPostingFailure(
              inResult.error ?? 'Could not update new stock.',
            );
          }
        }

        // Handle PO status transitions
        if (oldPoRefId != null && oldPoRefId != poRefId) {
          await _db.updatePurchaseOrderStatus(oldPoRefId, 'pending');
          await _sync.queueUpdate(
            tableName: 'purchase_orders',
            recordId: oldPoRefId,
            payload: {
              'id': oldPoRefId,
              'factory_id': factoryId,
              'status': 'pending',
            },
            triggerSync: false,
          );
        }
        if (poRefId != null) {
          await _db.updatePurchaseOrderStatus(poRefId, 'received');
          await _sync.queueUpdate(
            tableName: 'purchase_orders',
            recordId: poRefId,
            payload: {
              'id': poRefId,
              'factory_id': factoryId,
              'status': 'received',
            },
            triggerSync: false,
          );
        }

        final setClauses = updatePayload.keys.map((k) => '$k = ?').join(', ');
        final values = [...updatePayload.values, factoryId, id];
        _db.db.execute(
          'UPDATE material_receives SET $setClauses WHERE factory_id = ? AND id = ?',
          values,
        );

        await _sync.queueUpdate(
          tableName: 'material_receives',
          recordId: id,
          payload: {'id': id, 'factory_id': factoryId, ...updatePayload},
          triggerSync: false,
        );
      });
    } on StockPostingFailure catch (error) {
      return MaterialReceiveResult(success: false, error: error.message);
    } catch (e) {
      return MaterialReceiveResult(
        success: false,
        error: 'Material receipt could not be updated: $e',
      );
    }

    await _sync.schedulePendingSync();
    unawaited(_alerts.checkLowStock());
    return MaterialReceiveResult(
      success: true,
      recordId: id,
      shortfall: shortfall,
    );
  }

  Future<MaterialReceiveResult> delete(String id) async {
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) {
      return const MaterialReceiveResult(
        success: false,
        error: 'No active factory workspace is selected.',
      );
    }

    final existingRows = _db.db.select(
      'SELECT * FROM material_receives WHERE factory_id = ? AND id = ?',
      [factoryId, id],
    );
    if (existingRows.isEmpty) {
      return const MaterialReceiveResult(
        success: false,
        error: 'Receipt record not found.',
      );
    }
    final existing = Map<String, dynamic>.from(existingRows.first);
    final partId = existing['part_id'] as String;
    final qty = (existing['qty'] as num?)?.toDouble() ?? 0.0;
    final poRefId = existing['po_ref_id'] as String?;

    try {
      await _db.runInTransaction(() async {
        final outResult = await _ledger.materialReceiveOut(
          partId: partId,
          qty: qty,
          refId: id,
          triggerSync: false,
        );
        if (!outResult.success) {
          throw StockPostingFailure(
            outResult.error ?? 'Could not rollback raw material stock.',
          );
        }

        if (poRefId != null) {
          await _db.updatePurchaseOrderStatus(poRefId, 'pending');
          await _sync.queueUpdate(
            tableName: 'purchase_orders',
            recordId: poRefId,
            payload: {
              'id': poRefId,
              'factory_id': factoryId,
              'status': 'pending',
            },
            triggerSync: false,
          );
        }

        _db.db.execute(
          'DELETE FROM material_receives WHERE factory_id = ? AND id = ?',
          [factoryId, id],
        );

        await _sync.queueDelete(
          tableName: 'material_receives',
          recordId: id,
          factoryId: factoryId,
          triggerSync: false,
        );
      });
    } on StockPostingFailure catch (error) {
      return MaterialReceiveResult(success: false, error: error.message);
    } catch (e) {
      return MaterialReceiveResult(
        success: false,
        error: 'Material receipt could not be deleted: $e',
      );
    }

    await _sync.schedulePendingSync();
    unawaited(_alerts.checkLowStock());
    return MaterialReceiveResult(success: true, recordId: id);
  }

  Future<List<Map<String, dynamic>>> getRecent({int limit = 50, String? date}) async {
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) return [];

    final dateFilter = (date != null && date.trim().isNotEmpty)
        ? date.trim()
        : null;

    final String query;
    final List<dynamic> params;

    if (dateFilter != null) {
      query = 'SELECT mr.*, p.name as part_name, p.code as part_code, s.name as supplier_name '
          'FROM material_receives mr '
          'LEFT JOIN parts p ON p.id = mr.part_id AND p.factory_id = mr.factory_id '
          'LEFT JOIN suppliers s ON s.id = mr.supplier_id AND s.factory_id = mr.factory_id '
          'WHERE mr.factory_id = ? '
          'AND (TRIM(mr.date) = ? OR mr.date LIKE ? OR date(mr.date) = ?) '
          'ORDER BY mr.created_at DESC LIMIT ?';
      params = [factoryId, dateFilter, '$dateFilter%', dateFilter, limit];
    } else {
      query = 'SELECT mr.*, p.name as part_name, p.code as part_code, s.name as supplier_name '
          'FROM material_receives mr '
          'LEFT JOIN parts p ON p.id = mr.part_id AND p.factory_id = mr.factory_id '
          'LEFT JOIN suppliers s ON s.id = mr.supplier_id AND s.factory_id = mr.factory_id '
          'WHERE mr.factory_id = ? '
          'ORDER BY mr.created_at DESC LIMIT ?';
      params = [factoryId, limit];
    }

    final rows = _db.db.select(query, params);
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }
}

// ─── Providers ────────────────────────────────────────────────────────────────

final purchaseOrderRepositoryProvider =
    Provider<PurchaseOrderRepository>((ref) {
  return PurchaseOrderRepository(
    ref.watch(databaseServiceProvider),
    ref.watch(syncServiceProvider),
  );
});

final purchaseOrderListProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  return ref.watch(purchaseOrderRepositoryProvider).getAll();
});

final pendingOrderRemainingProvider =
    FutureProvider<Map<String, double>>((ref) async {
  return ref.watch(purchaseOrderRepositoryProvider).getPendingRemaining();
});

final materialReceiveRepositoryProvider =
    Provider<MaterialReceiveRepository>((ref) {
  return MaterialReceiveRepository(
    ref.watch(databaseServiceProvider),
    ref.watch(syncServiceProvider),
    ref.watch(stockLedgerServiceProvider),
    ref.watch(alertProducerServiceProvider),
  );
});

class MaterialReceiveHistoryDateFilterNotifier extends Notifier<DateTime?> {
  @override
  DateTime? build() => null;

  void setDate(DateTime? date) => state = date;
}

final materialReceiveHistoryDateFilterProvider =
    NotifierProvider<MaterialReceiveHistoryDateFilterNotifier, DateTime?>(
  MaterialReceiveHistoryDateFilterNotifier.new,
);

final materialReceiveListProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final date = ref.watch(materialReceiveHistoryDateFilterProvider);
  final dateStr = date != null
      ? '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}'
      : null;
  return ref.watch(materialReceiveRepositoryProvider).getRecent(date: dateStr);
});


// ─── Result classes ───────────────────────────────────────────────────────────

class PurchaseOrderResult {
  const PurchaseOrderResult({required this.success, this.error, this.recordId});
  final bool success;
  final String? error;
  final String? recordId;
}

class MaterialReceiveResult {
  const MaterialReceiveResult({
    required this.success,
    this.error,
    this.recordId,
    this.shortfall = 0,
  });
  final bool success;
  final String? error;
  final String? recordId;
  final double shortfall;
}
