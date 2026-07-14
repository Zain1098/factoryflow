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
    final id = _uuid.v4();
    final now = recordedAt ?? DateTime.now();
    final dateStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final timeStr = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    final record = {
      'id': id,
      'factory_id': _db.activeWorkspaceId,
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

    await _db.insertRecord('purchase_orders', record);
    await _sync.queueInsert(tableName: 'purchase_orders', recordId: id, payload: record);

    return PurchaseOrderResult(success: true, recordId: id);
  }

  Future<PurchaseOrderResult> updateStatus(String id, String status) async {
    await _db.updatePurchaseOrderStatus(id, status);
    await _sync.queueInsert(
      tableName: 'purchase_orders',
      recordId: id,
      payload: {'id': id, 'status': status},
    );
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
    String? poRefId,       // link to purchase_order id
    double? orderedQty,    // from linked PO, for shortfall calc
    String? remarks,
    required String createdBy,
    DateTime? recordedAt,
  }) async {
    final id = _uuid.v4();
    final now = recordedAt ?? DateTime.now();
    final dateStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final timeStr = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    final effectiveOrderedQty = orderedQty ?? qty;
    final shortfall = (effectiveOrderedQty - qty).clamp(0.0, double.infinity);

    final record = {
      'id': id,
      'factory_id': _db.activeWorkspaceId,
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

    await _db.insertRecord('material_receives', record);

    // Mark linked PO as received
    if (poRefId != null) {
      await _db.updatePurchaseOrderStatus(poRefId, 'received');
    }

    // Write to stock ledger
    final ledgerResult = await _ledger.materialReceiveIn(
      partId: partId,
      qty: qty,
      refId: id,
    );

    if (!ledgerResult.success) {
      return MaterialReceiveResult(success: false, error: ledgerResult.error);
    }

    await _sync.queueInsert(tableName: 'material_receives', recordId: id, payload: record);

    return MaterialReceiveResult(success: true, recordId: id, shortfall: shortfall);
  }

  Future<List<Map<String, dynamic>>> getRecent({int limit = 30}) async {
    final rows = _db.db.select(
      'SELECT mr.*, p.name as part_name, p.code as part_code, s.name as supplier_name '
      'FROM material_receives mr '
      'LEFT JOIN parts p ON p.id = mr.part_id '
      'LEFT JOIN suppliers s ON s.id = mr.supplier_id '
      'ORDER BY mr.created_at DESC LIMIT ?',
      [limit],
    );
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }
}

// ─── Providers ────────────────────────────────────────────────────────────────

final purchaseOrderRepositoryProvider = Provider<PurchaseOrderRepository>((ref) {
  return PurchaseOrderRepository(
    ref.watch(databaseServiceProvider),
    ref.watch(syncServiceProvider),
  );
});

final purchaseOrderListProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  return ref.watch(purchaseOrderRepositoryProvider).getAll();
});

final materialReceiveRepositoryProvider = Provider<MaterialReceiveRepository>((ref) {
  return MaterialReceiveRepository(
    ref.watch(databaseServiceProvider),
    ref.watch(syncServiceProvider),
    ref.watch(stockLedgerServiceProvider),
  );
});

final materialReceiveListProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
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
