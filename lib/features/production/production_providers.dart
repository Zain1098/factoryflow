import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/database/database_service.dart';
import '../../core/network/sync_service.dart';
import '../../core/services/stock_ledger_service.dart';

const _uuid = Uuid();

// ─── Production Repository ────────────────────────────────────────────────────

class ProductionRepository {
  ProductionRepository(this._db, this._sync, this._ledger);

  final DatabaseService _db;
  final SyncService _sync;
  final StockLedgerService _ledger;

  /// Generates batch number using machine_code from DB — no hardcoded letters.
  Future<String> generateBatchNumber({
    required String partCode,
    required DateTime date,
    required String machineCode,
  }) async {
    final dateStr =
        '${date.year}${date.month.toString().padLeft(2, '0')}${date.day.toString().padLeft(2, '0')}';
    final prefix = '$partCode-$dateStr-$machineCode';
    final existing = _db.db.select(
      'SELECT COUNT(*) as cnt FROM productions WHERE batch_number LIKE ?',
      ['$prefix%'],
    );
    final seq = (existing.first['cnt'] as int) + 1;
    return '$prefix-${seq.toString().padLeft(3, '0')}';
  }

  Future<ProductionResult> save({
    required String partId,
    required String partCode,
    required String machineId,
    required String machineName,
    required String machineCode,
    required String operatorId,
    required String machineStatusId,
    required double productionQty,
    required double bpRejectQty,
    String? shiftId,
    String? remarks,
    required String createdBy,
    DateTime? recordedAt,
  }) async {
    if (bpRejectQty > productionQty) {
      return const ProductionResult(
        success: false,
        error: 'BP reject qty cannot exceed production qty',
      );
    }

    final id = _uuid.v4();
    final now = recordedAt ?? DateTime.now();
    final dateStr =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final timeStr =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    final batchNumber = await generateBatchNumber(
      partCode: partCode,
      date: now,
      machineCode: machineCode,
    );

    final goodQty = productionQty - bpRejectQty;

    final record = {
      'id': id,
      'factory_id': _db.activeWorkspaceId,
      'batch_number': batchNumber,
      'date': dateStr,
      'time': timeStr,
      'shift_id': shiftId,
      'part_id': partId,
      'machine_id': machineId,
      'operator_id': operatorId,
      'machine_status_id': machineStatusId,
      'production_qty': productionQty,
      'bp_reject_qty': bpRejectQty,
      'good_qty': goodQty,
      'remarks': remarks,
      'created_by': createdBy,
      'created_at': now.toIso8601String(),
      'sync_status': 'pending',
    };

    await _db.insertRecord('productions', record);

    if (goodQty > 0) {
      final ledgerResult = await _ledger.productionToBpStock(
        partId: partId,
        goodQty: goodQty,
        refId: id,
      );
      if (!ledgerResult.success) {
        return ProductionResult(success: false, error: ledgerResult.error);
      }
    }

    // FIXED: Strip good_qty (generated column in Supabase) from sync payload
    final syncPayload = Map<String, dynamic>.from(record)..remove('good_qty');
    await _sync.queueInsert(
      tableName: 'productions',
      recordId: id,
      payload: syncPayload,
    );

    return ProductionResult(success: true, recordId: id, batchNumber: batchNumber);
  }

  Future<List<Map<String, dynamic>>> getRecent({int limit = 30}) async {
    final rows = _db.db.select(
      'SELECT pr.*, p.name as part_name, p.code as part_code, '
      'm.name as machine_name, o.name as operator_name '
      'FROM productions pr '
      'LEFT JOIN parts p ON p.id = pr.part_id '
      'LEFT JOIN machines m ON m.id = pr.machine_id '
      'LEFT JOIN operators o ON o.id = pr.operator_id '
      'ORDER BY pr.created_at DESC LIMIT ?',
      [limit],
    );
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }
}

final productionRepositoryProvider = Provider<ProductionRepository>((ref) {
  return ProductionRepository(
    ref.watch(databaseServiceProvider),
    ref.watch(syncServiceProvider),
    ref.watch(stockLedgerServiceProvider),
  );
});

final productionListProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  return ref.watch(productionRepositoryProvider).getRecent();
});

const kMachineStatuses = ['Running', 'Breakdown', 'Maintenance', 'Idle'];

class ProductionResult {
  const ProductionResult({required this.success, this.error, this.recordId, this.batchNumber});
  final bool success;
  final String? error;
  final String? recordId;
  final String? batchNumber;
}
