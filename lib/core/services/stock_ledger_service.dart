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

  /// Moves a pre-plating QC rejection out of BP stock into its own tracked
  /// reject location. Reject material must never disappear from the ledger.
  Future<StockLedgerResult> bpRejectToRejected({
    required String partId,
    required double qty,
    required String refId,
  }) async {
    final outResult = await _writeOut(
      partId: partId,
      stage: StockStage.bpStock,
      qty: qty,
      refTable: 'bp_inspections',
      refId: refId,
    );
    if (!outResult.success) return outResult;

    return _writeIn(
      partId: partId,
      stage: StockStage.bpRejected,
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
    double rtvQty = 0,
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
      final rejectedResult = await _writeIn(
        partId: partId,
        stage: StockStage.apRejected,
        qty: rejectedQty,
        refTable: 'ap_inspections',
        refId: refId,
      );
      if (!rejectedResult.success) return rejectedResult;
    }

    if (rtvQty > 0) {
      return _writeIn(
        partId: partId,
        stage: StockStage.rtvStock,
        qty: rtvQty,
        refTable: 'ap_inspections',
        refId: refId,
      );
    }

    return const StockLedgerResult(success: true);
  }

  /// AP Rejected → scrapped (written off, stock goes to zero)
  Future<StockLedgerResult> apRejectedScrap({
    required String partId,
    required double qty,
    required String refId,
  }) {
    return _writeOut(
      partId: partId,
      stage: StockStage.apRejected,
      qty: qty,
      refTable: 'ap_rejected_actions',
      refId: refId,
    );
  }

  /// AP Rejected → send to Faco vendor (RTV dispatch)
  Future<StockLedgerResult> apRejectedToFaco({
    required String partId,
    required double qty,
    required String refId,
  }) async {
    final outResult = await _writeOut(
      partId: partId,
      stage: StockStage.apRejected,
      qty: qty,
      refTable: 'ap_rejected_actions',
      refId: refId,
    );
    if (!outResult.success) return outResult;
    return _writeIn(
      partId: partId,
      stage: StockStage.atFaco,
      qty: qty,
      refTable: 'ap_rejected_actions',
      refId: refId,
    );
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
      refTable: 'dispatch_items',
      refId: refId,
    );
  }

  Future<double> getAvailableStock(String partId, StockStage stage) {
    return _db.getCurrentBalance(partId, stage.value);
  }

  Future<double> getAvailableStockAtStage(String partId, String stage) {
    return _db.getCurrentBalance(partId, stage);
  }

  /// Moves material through one production machine. Every stage has its own
  /// WIP location, so stock remains traceable even when a batch is completed
  /// over multiple days or devices.
  Future<StockLedgerResult> moveThroughProductionStage({
    required String partId,
    required String inputStage,
    required String inputStageLabel,
    required String outputStage,
    required String outputStageLabel,
    required double inputQty,
    required double goodQty,
    required double rejectQty,
    required String refId,
    bool triggerSync = true,
    bool queueForSync = true,
  }) async {
    final available = await getAvailableStockAtStage(partId, inputStage);
    if (inputQty > available) {
      return StockLedgerResult(
        success: false,
        error:
            'Insufficient $inputStageLabel stock. Available: ${available.toInt()} PCS.',
        availableQty: available,
      );
    }

    final outResult = await _writeCustomStage(
      partId: partId,
      stage: inputStage,
      stageLabel: inputStageLabel,
      direction: LedgerDirection.out,
      qty: inputQty,
      refId: refId,
      triggerSync: triggerSync,
      queueForSync: queueForSync,
    );
    if (!outResult.success) return outResult;

    if (goodQty > 0) {
      final goodResult = await _writeCustomStage(
        partId: partId,
        stage: outputStage,
        stageLabel: outputStageLabel,
        direction: LedgerDirection.in_,
        qty: goodQty,
        refId: refId,
        triggerSync: triggerSync,
        queueForSync: queueForSync,
      );
      if (!goodResult.success) return goodResult;
    }

    if (rejectQty > 0) {
      final rejectResult = await _writeCustomStage(
        partId: partId,
        stage: kProductionRejectedStage,
        stageLabel: 'Production Rejected',
        direction: LedgerDirection.in_,
        qty: rejectQty,
        refId: refId,
        triggerSync: triggerSync,
        queueForSync: queueForSync,
      );
      if (!rejectResult.success) return rejectResult;
    }

    return const StockLedgerResult(success: true);
  }

  Future<double> getTotalStageBalance(StockStage stage) {
    return _db.getTotalBalanceByStage(stage.value);
  }

  /// Manual stock adjustment — writes a ledger entry with ref_table='stock_adjustments'.
  Future<StockLedgerResult> manualAdjustment({
    required String partId,
    required StockStage stage,
    required LedgerDirection direction,
    required double qty,
    required String refId,
  }) {
    return _write(
      partId: partId,
      stage: stage,
      direction: direction,
      qty: qty,
      refTable: 'stock_adjustments',
      refId: refId,
    );
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

  Future<StockLedgerResult> _writeCustomStage({
    required String partId,
    required String stage,
    required String stageLabel,
    required LedgerDirection direction,
    required double qty,
    required String refId,
    required bool triggerSync,
    required bool queueForSync,
  }) async {
    final factoryId = _db.activeWorkspaceId;
    final ledgerId = _uuid.v4();
    final result = await _db.writeStockLedgerEntryForStage(
      id: ledgerId,
      factoryId: factoryId,
      partId: partId,
      stage: stage,
      stageLabel: stageLabel,
      direction: direction,
      qty: qty,
      refTable: 'productions',
      refId: refId,
    );

    if (result.success && queueForSync) {
      await _sync.queueLedger(
        recordId: ledgerId,
        payload: {
          'id': ledgerId,
          'factory_id': factoryId,
          'part_id': partId,
          'stage': stage,
          'direction': direction.value,
          'qty': qty,
          'ref_table': 'productions',
          'ref_id': refId,
        },
        triggerSync: triggerSync,
      );
    }

    return result;
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
      await _sync.queueLedger(
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
