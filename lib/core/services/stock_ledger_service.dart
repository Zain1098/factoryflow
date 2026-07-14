import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../constants/stock_stages.dart';
import '../database/database_service.dart';
import '../network/sync_service.dart';

final stockLedgerServiceProvider = Provider<StockLedgerService>((ref) {
  return StockLedgerService(
    ref.watch(databaseServiceProvider),
    ref.watch(syncServiceProvider),
  );
});

/// Central stock ledger service — PRD Ch. 7.1
/// Every transaction module must use this for stock movements.
class StockLedgerService {
  StockLedgerService(this._db, this._sync);

  final DatabaseService _db;
  final SyncService _sync;
  final _uuid = const Uuid();

  Future<StockLedgerResult> materialReceiveIn({
    required String partId,
    required double qty,
    required String refId,
  }) {
    return _writeIn(
      partId: partId,
      stage: StockStage.rawMaterial,
      qty: qty,
      refTable: 'material_receives',
      refId: refId,
    );
  }

  Future<StockLedgerResult> productionToBpStock({
    required String partId,
    required double goodQty,
    required String refId,
  }) {
    return _writeIn(
      partId: partId,
      stage: StockStage.bpStock,
      qty: goodQty,
      refTable: 'productions',
      refId: refId,
    );
  }

  Future<StockLedgerResult> bpRejectOut({
    required String partId,
    required double qty,
    required String refId,
  }) {
    return _writeOut(
      partId: partId,
      stage: StockStage.bpStock,
      qty: qty,
      refTable: 'bp_inspections',
      refId: refId,
    );
  }

  Future<StockLedgerResult> dispatchToFaco({
    required String partId,
    required double qty,
    required String refId,
  }) async {
    final outResult = await _writeOut(
      partId: partId,
      stage: StockStage.bpStock,
      qty: qty,
      refTable: 'dispatch_to_facos',
      refId: refId,
    );
    if (!outResult.success) return outResult;

    return _writeIn(
      partId: partId,
      stage: StockStage.atFaco,
      qty: qty,
      refTable: 'dispatch_to_facos',
      refId: refId,
    );
  }

  Future<StockLedgerResult> receiveFromFaco({
    required String partId,
    required double qty,
    required String refId,
  }) async {
    final outResult = await _writeOut(
      partId: partId,
      stage: StockStage.atFaco,
      qty: qty,
      refTable: 'receive_from_facos',
      refId: refId,
    );
    if (!outResult.success) return outResult;

    return _writeIn(
      partId: partId,
      stage: StockStage.pendingAp,
      qty: qty,
      refTable: 'receive_from_facos',
      refId: refId,
    );
  }

  Future<StockLedgerResult> apInspectionSplit({
    required String partId,
    required double checkedQty,
    required double approvedQty,
    required double rejectedQty,
    required String refId,
  }) async {
    final outResult = await _writeOut(
      partId: partId,
      stage: StockStage.pendingAp,
      qty: checkedQty,
      refTable: 'ap_inspections',
      refId: refId,
    );
    if (!outResult.success) return outResult;

    if (approvedQty > 0) {
      final approvedResult = await _writeIn(
        partId: partId,
        stage: StockStage.approvedAp,
        qty: approvedQty,
        refTable: 'ap_inspections',
        refId: refId,
      );
      if (!approvedResult.success) return approvedResult;
    }

    if (rejectedQty > 0) {
      return _writeIn(
        partId: partId,
        stage: StockStage.rtvStock,
        qty: rejectedQty,
        refTable: 'ap_inspections',
        refId: refId,
      );
    }

    return const StockLedgerResult(success: true);
  }

  Future<StockLedgerResult> rtvOut({
    required String partId,
    required double qty,
    required String refId,
  }) {
    return _writeOut(
      partId: partId,
      stage: StockStage.rtvStock,
      qty: qty,
      refTable: 'rtvs',
      refId: refId,
    );
  }

  Future<StockLedgerResult> rtvReturnOk({
    required String partId,
    required double okQty,
    required String refId,
  }) {
    return _writeIn(
      partId: partId,
      stage: StockStage.approvedAp,
      qty: okQty,
      refTable: 'rtv_reinspections',
      refId: refId,
    );
  }

  Future<StockLedgerResult> finalDispatch({
    required String partId,
    required double qty,
    required String refId,
  }) {
    return _writeOut(
      partId: partId,
      stage: StockStage.approvedAp,
      qty: qty,
      refTable: 'final_dispatches',
      refId: refId,
    );
  }

  Future<double> getAvailableStock(String partId, StockStage stage) {
    return _db.getCurrentBalance(partId, stage.value);
  }

  Future<double> getTotalStageBalance(StockStage stage) {
    return _db.getTotalBalanceByStage(stage.value);
  }

  Future<StockLedgerResult> _writeIn({
    required String partId,
    required StockStage stage,
    required double qty,
    required String refTable,
    required String refId,
  }) {
    return _write(
      partId: partId,
      stage: stage,
      direction: LedgerDirection.in_,
      qty: qty,
      refTable: refTable,
      refId: refId,
    );
  }

  Future<StockLedgerResult> _writeOut({
    required String partId,
    required StockStage stage,
    required double qty,
    required String refTable,
    required String refId,
  }) {
    return _write(
      partId: partId,
      stage: stage,
      direction: LedgerDirection.out,
      qty: qty,
      refTable: refTable,
      refId: refId,
    );
  }

  Future<StockLedgerResult> _write({
    required String partId,
    required StockStage stage,
    required LedgerDirection direction,
    required double qty,
    required String refTable,
    required String refId,
  }) async {
    final factoryId = _db.activeWorkspaceId;
    final ledgerId = _uuid.v4();
    final result = await _db.writeStockLedgerEntry(
      id: ledgerId,
      factoryId: factoryId,
      partId: partId,
      stage: stage,
      direction: direction,
      qty: qty,
      refTable: refTable,
      refId: refId,
    );

    if (result.success) {
      await _sync.queueInsert(
        tableName: 'stock_ledger',
        recordId: ledgerId,
        payload: {
          'id': ledgerId,
          'factory_id': factoryId,
          'part_id': partId,
          'stage': stage.value,
          'direction': direction.value,
          'qty': qty,
          'ref_table': refTable,
          'ref_id': refId,
        },
      );
    }

    return result;
  }
}
