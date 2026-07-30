import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/database/database_service.dart';
import '../../core/network/sync_service.dart';
import '../../core/services/stock_ledger_service.dart';

const _uuid = Uuid();

const kPoStatuses = ['pending', 'processing', 'received', 'cancelled'];

// ─── Purchase Order Repository ────────────────────────────────────────────────

class PurchaseOrderRepository {
  PurchaseOrderRepository(this._db, this._sync);

  final DatabaseService _db;
  final SyncService _sync;

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

    final id = _uuid.v4();
    final now = recordedAt ?? DateTime.now();
    final dateStr =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final timeStr =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    final record = {
      'id': id,
      'factory_id': factoryId,
      'date': dateStr,
      'time': timeStr,
      'part_id': partId,
      'supplier_id': supplierId,
      'ordered_qty': orderedQty,
      'po_number': poNumber,
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
    return PurchaseOrderResult(success: true, recordId: id);
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

  Future<List<Map<String, dynamic>>> getOpenForPart(String partId) =>
      _db.getOpenPurchaseOrders(partId);

  Future<List<Map<String, dynamic>>> getAll({int limit = 50}) =>
      _db.getAllPurchaseOrders(limit: limit);
}

// ─── Material Receive Repository ──────────────────────────────────────────────

class MaterialReceiveRepository {
  MaterialReceiveRepository(this._db, this._sync, this._ledger);

  final DatabaseService _db;
  final SyncService _sync;
  final StockLedgerService _ledger;

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
    return MaterialReceiveResult(
      success: true,
      recordId: id,
      shortfall: shortfall,
    );
  }

  Future<List<Map<String, dynamic>>> getRecent({int limit = 30}) async {
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) return [];
    final rows = _db.db.select(
      'SELECT mr.*, p.name as part_name, p.code as part_code, s.name as supplier_name '
      'FROM material_receives mr '
      'LEFT JOIN parts p ON p.id = mr.part_id AND p.factory_id = mr.factory_id '
      'LEFT JOIN suppliers s ON s.id = mr.supplier_id AND s.factory_id = mr.factory_id '
      'WHERE mr.factory_id = ? '
      'ORDER BY mr.created_at DESC LIMIT ?',
      [factoryId, limit],
    );
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

final materialReceiveRepositoryProvider =
    Provider<MaterialReceiveRepository>((ref) {
  return MaterialReceiveRepository(
    ref.watch(databaseServiceProvider),
    ref.watch(syncServiceProvider),
    ref.watch(stockLedgerServiceProvider),
  );
});

final materialReceiveListProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  return ref.watch(materialReceiveRepositoryProvider).getRecent();
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
