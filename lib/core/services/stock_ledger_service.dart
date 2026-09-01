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
    bool triggerSync = true,
  }) {
    return _writeIn(
      partId: partId,
      stage: StockStage.rawMaterial,
      qty: qty,
      refTable: 'material_receives',
      refId: refId,
      triggerSync: triggerSync,
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

  /// Moves inspected material into BP Hold (quality has not cleared it yet).
  Future<StockLedgerResult> bpHoldFromStock({
    required String partId,
    required double qty,
    required String refId,
    bool triggerSync = true,
  }) async {
    final outResult = await _writeOut(
      partId: partId,
      stage: StockStage.bpStock,
      qty: qty,
      refTable: 'bp_inspections',
      refId: refId,
      triggerSync: triggerSync,
    );
    if (!outResult.success) return outResult;

    return _writeIn(
      partId: partId,
      stage: StockStage.bpHold,
      qty: qty,
      refTable: 'bp_inspections',
      refId: refId,
      triggerSync: triggerSync,
    );
  }

  /// Completes a BP hold: reject → bp_rejected, approved → back to bp_stock.
  Future<StockLedgerResult> bpHoldResolve({
    required String partId,
    required double inspectedQty,
    required double rejectQty,
    required String refId,
    bool triggerSync = true,
  }) async {
    if (inspectedQty <= 0) {
      return const StockLedgerResult(
        success: false,
        error: 'Inspected quantity must be greater than zero.',
      );
    }
    if (rejectQty < 0 || rejectQty > inspectedQty) {
      return const StockLedgerResult(
        success: false,
        error: 'Reject quantity must be between 0 and inspected quantity.',
      );
    }

    final holdResult = await bpHoldFromStock(
      partId: partId,
      qty: inspectedQty,
      refId: refId,
      triggerSync: triggerSync,
    );
    if (!holdResult.success) return holdResult;

    final approvedQty = inspectedQty - rejectQty;
    if (rejectQty > 0) {
      final rejectOut = await _writeOut(
        partId: partId,
        stage: StockStage.bpHold,
        qty: rejectQty,
        refTable: 'bp_inspections',
        refId: refId,
        triggerSync: triggerSync,
      );
      if (!rejectOut.success) return rejectOut;

      final rejectIn = await _writeIn(
        partId: partId,
        stage: StockStage.bpRejected,
        qty: rejectQty,
        refTable: 'bp_inspections',
        refId: refId,
        triggerSync: triggerSync,
      );
      if (!rejectIn.success) return rejectIn;
    }

    if (approvedQty > 0) {
      final okOut = await _writeOut(
        partId: partId,
        stage: StockStage.bpHold,
        qty: approvedQty,
        refTable: 'bp_inspections',
        refId: refId,
        triggerSync: triggerSync,
      );
      if (!okOut.success) return okOut;

      return _writeIn(
        partId: partId,
        stage: StockStage.bpStock,
        qty: approvedQty,
        refTable: 'bp_inspections',
        refId: refId,
        triggerSync: triggerSync,
      );
    }

    return const StockLedgerResult(success: true);
  }

  /// Releases material that is ALREADY sitting in BP Hold (e.g. from manual hold/quarantine):
  /// - okQty moves from bp_hold to bp_stock (Own BP Stock -> ready for vendor dispatch)
  /// - rejectQty moves from bp_hold to bp_rejected (BP Rejected)
  Future<StockLedgerResult> releaseDirectBpHold({
    required String partId,
    required double okQty,
    required double rejectQty,
    required String refId,
    bool triggerSync = true,
  }) async {
    final total = okQty + rejectQty;
    if (total <= 0) {
      return const StockLedgerResult(
        success: false,
        error: 'Total released quantity must be greater than zero.',
      );
    }
    final currentHold = await getAvailableStock(partId, StockStage.bpHold);
    if (total > currentHold) {
      return StockLedgerResult(
        success: false,
        error:
            'Release quantity (${total.toInt()} PCS) exceeds available BP Hold stock (${currentHold.toInt()} PCS).',
      );
    }

    if (rejectQty > 0) {
      final rejectOut = await _writeOut(
        partId: partId,
        stage: StockStage.bpHold,
        qty: rejectQty,
        refTable: 'bp_inspections',
        refId: refId,
        triggerSync: triggerSync,
      );
      if (!rejectOut.success) return rejectOut;

      final rejectIn = await _writeIn(
        partId: partId,
        stage: StockStage.bpRejected,
        qty: rejectQty,
        refTable: 'bp_inspections',
        refId: refId,
        triggerSync: triggerSync,
      );
      if (!rejectIn.success) return rejectIn;
    }

    if (okQty > 0) {
      final okOut = await _writeOut(
        partId: partId,
        stage: StockStage.bpHold,
        qty: okQty,
        refTable: 'bp_inspections',
        refId: refId,
        triggerSync: triggerSync,
      );
      if (!okOut.success) return okOut;

      final okIn = await _writeIn(
        partId: partId,
        stage: StockStage.bpStock,
        qty: okQty,
        refTable: 'bp_inspections',
        refId: refId,
        triggerSync: triggerSync,
      );
      if (!okIn.success) return okIn;
    }

    return const StockLedgerResult(success: true);
  }

  /// Moves a pre-plating QC rejection out of BP stock into its own tracked
  /// reject location. Reject material must never disappear from the ledger.
  Future<StockLedgerResult> bpRejectToRejected({
    required String partId,
    required double qty,
    required String refId,
    bool triggerSync = true,
  }) async {
    final outResult = await _writeOut(
      partId: partId,
      stage: StockStage.bpStock,
      qty: qty,
      refTable: 'bp_inspections',
      refId: refId,
      triggerSync: triggerSync,
    );
    if (!outResult.success) return outResult;

    return _writeIn(
      partId: partId,
      stage: StockStage.bpRejected,
      qty: qty,
      refTable: 'bp_inspections',
      refId: refId,
      triggerSync: triggerSync,
    );
  }

  Future<StockLedgerResult> dispatchToFaco({
    required String partId,
    required double qty,
    required String refId,
    bool triggerSync = true,
  }) async {
    final outResult = await _writeOut(
      partId: partId,
      stage: StockStage.bpStock,
      qty: qty,
      refTable: 'dispatch_to_facos',
      refId: refId,
      triggerSync: triggerSync,
    );
    if (!outResult.success) return outResult;

    return _writeIn(
      partId: partId,
      stage: StockStage.atFaco,
      qty: qty,
      refTable: 'dispatch_to_facos',
      refId: refId,
      triggerSync: triggerSync,
    );
  }

  Future<StockLedgerResult> receiveFromFaco({
    required String partId,
    required double qty,
    required String refId,
    bool triggerSync = true,
  }) async {
    final outResult = await _writeOut(
      partId: partId,
      stage: StockStage.atFaco,
      qty: qty,
      refTable: 'receive_from_facos',
      refId: refId,
      triggerSync: triggerSync,
    );
    if (!outResult.success) return outResult;

    return _writeIn(
      partId: partId,
      stage: StockStage.pendingAp,
      qty: qty,
      refTable: 'receive_from_facos',
      refId: refId,
      triggerSync: triggerSync,
    );
  }

  Future<StockLedgerResult> apInspectionSplit({
    required String partId,
    required double checkedQty,
    required double approvedQty,
    required double rejectedQty,
    double rtvQty = 0,
    required String refId,
    bool triggerSync = true,
  }) async {
    final outResult = await _writeOut(
      partId: partId,
      stage: StockStage.pendingAp,
      qty: checkedQty,
      refTable: 'ap_inspections',
      refId: refId,
      triggerSync: triggerSync,
    );
    if (!outResult.success) return outResult;

    if (approvedQty > 0) {
      final approvedResult = await _writeIn(
        partId: partId,
        stage: StockStage.approvedAp,
        qty: approvedQty,
        refTable: 'ap_inspections',
        refId: refId,
        triggerSync: triggerSync,
      );
      if (!approvedResult.success) return approvedResult;
    }

    // Keep AP rejects in company stock until an authorized user confirms the
    // final write-off.  A rejection is not automatically a disposal.
    if (rejectedQty > 0) {
      final rejectedResult = await _writeIn(
        partId: partId,
        stage: StockStage.apRejected,
        qty: rejectedQty,
        refTable: 'ap_inspections',
        refId: refId,
        triggerSync: triggerSync,
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
        triggerSync: triggerSync,
      );
    }

    return const StockLedgerResult(success: true);
  }

  /// AP Rejected → scrapped (written off, stock goes to zero)
  Future<StockLedgerResult> apRejectedScrap({
    required String partId,
    required double qty,
    required String refId,
    bool triggerSync = true,
  }) {
    return _writeOut(
      partId: partId,
      stage: StockStage.apRejected,
      qty: qty,
      refTable: 'ap_rejected_actions',
      refId: refId,
      triggerSync: triggerSync,
    );
  }

  /// BP Rejected → final write-off after the company confirms disposal.
  Future<StockLedgerResult> bpRejectedScrap({
    required String partId,
    required double qty,
    required String refId,
    bool triggerSync = true,
  }) {
    return _writeOut(
      partId: partId,
      stage: StockStage.bpRejected,
      qty: qty,
      refTable: 'bp_rejected_actions',
      refId: refId,
      triggerSync: triggerSync,
    );
  }

  /// AP Rejected → send to Faco vendor (RTV dispatch)
  Future<StockLedgerResult> apRejectedToFaco({
    required String partId,
    required double qty,
    required String refId,
    bool triggerSync = true,
  }) async {
    final outResult = await _writeOut(
      partId: partId,
      stage: StockStage.apRejected,
      qty: qty,
      refTable: 'ap_rejected_actions',
      refId: refId,
      triggerSync: triggerSync,
    );
    if (!outResult.success) return outResult;
    return _writeIn(
      partId: partId,
      stage: StockStage.atFaco,
      qty: qty,
      refTable: 'ap_rejected_actions',
      refId: refId,
      triggerSync: triggerSync,
    );
  }

  Future<StockLedgerResult> rtvOut({
    required String partId,
    required double qty,
    required String refId,
    bool triggerSync = true,
  }) {
    return _writeOut(
      partId: partId,
      stage: StockStage.rtvStock,
      qty: qty,
      refTable: 'rtvs',
      refId: refId,
      triggerSync: triggerSync,
    );
  }

  /// Explicit RTV dispatch: hold stock leaves the factory only when the user
  /// confirms this vendor-send action.
  Future<StockLedgerResult> rtvSendToVendor({
    required String partId,
    required double qty,
    required String refId,
    bool triggerSync = true,
  }) async {
    final out = await rtvOut(
      partId: partId,
      qty: qty,
      refId: refId,
      triggerSync: triggerSync,
    );
    if (!out.success) return out;
    return _writeIn(
      partId: partId,
      stage: StockStage.rtvAtVendor,
      qty: qty,
      refTable: 'rtvs',
      refId: refId,
      triggerSync: triggerSync,
    );
  }

  Future<StockLedgerResult> rtvReturnOk({
    required String partId,
    required double okQty,
    required String refId,
    bool triggerSync = true,
  }) {
    return _writeIn(
      partId: partId,
      stage: StockStage.approvedAp,
      qty: okQty,
      refTable: 'rtv_reinspections',
      refId: refId,
      triggerSync: triggerSync,
    );
  }

  /// Receives material back from an RTV cycle and records the reinspection
  /// outcome. Rejected-again pieces remain in RTV stock so they can be sent in
  /// the next cycle; approved pieces move to dispatch-ready AP stock.
  Future<StockLedgerResult> rtvReinspectionSplit({
    required String partId,
    required double quantityReceived,
    required double okQty,
    required double rejectAgainQty,
    required String refId,
    bool triggerSync = true,
  }) async {
    if ((okQty + rejectAgainQty - quantityReceived).abs() > 0.001) {
      return const StockLedgerResult(
        success: false,
        error: 'RTV OK + Reject Again must equal the received quantity.',
      );
    }

    final outResult = await _writeOut(
      partId: partId,
      stage: StockStage.rtvAtVendor,
      qty: quantityReceived,
      refTable: 'rtv_reinspections',
      refId: refId,
      triggerSync: triggerSync,
    );
    if (!outResult.success) return outResult;

    if (okQty > 0) {
      final okResult = await rtvReturnOk(
        partId: partId,
        okQty: okQty,
        refId: refId,
        triggerSync: triggerSync,
      );
      if (!okResult.success) return okResult;
    }

    if (rejectAgainQty > 0) {
      return _writeIn(
        partId: partId,
        stage: StockStage.rtvStock,
        qty: rejectAgainQty,
        refTable: 'rtv_reinspections',
        refId: refId,
        triggerSync: triggerSync,
      );
    }

    return const StockLedgerResult(success: true);
  }

  /// Resolves an escalated RTV by writing the rejected pieces off.
  Future<StockLedgerResult> rtvEscalationScrap({
    required String partId,
    required double qty,
    required String refId,
    bool triggerSync = true,
  }) {
    return _writeOut(
      partId: partId,
      stage: StockStage.rtvStock,
      qty: qty,
      refTable: 'rtvs',
      refId: refId,
      triggerSync: triggerSync,
    );
  }

  /// Admin override: moves escalated RTV pieces into approved AP stock so they
  /// can enter the normal final-dispatch flow.
  Future<StockLedgerResult> rtvEscalationForceDispatch({
    required String partId,
    required double qty,
    required String refId,
    bool triggerSync = true,
  }) async {
    final outResult = await rtvEscalationScrap(
      partId: partId,
      qty: qty,
      refId: refId,
      triggerSync: triggerSync,
    );
    if (!outResult.success) return outResult;
    return _writeIn(
      partId: partId,
      stage: StockStage.approvedAp,
      qty: qty,
      refTable: 'rtvs',
      refId: refId,
      triggerSync: triggerSync,
    );
  }

  Future<StockLedgerResult> finalDispatch({
    required String partId,
    required double qty,
    required String refId,
    bool triggerSync = true,
  }) {
    return _writeOut(
      partId: partId,
      stage: StockStage.approvedAp,
      qty: qty,
      refTable: 'dispatch_items',
      refId: refId,
      triggerSync: triggerSync,
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
    bool triggerSync = true,
  }) {
    return _write(
      partId: partId,
      stage: stage,
      direction: direction,
      qty: qty,
      refTable: 'stock_adjustments',
      refId: refId,
      triggerSync: triggerSync,
    );
  }

  Future<StockLedgerResult> _writeIn({
    required String partId,
    required StockStage stage,
    required double qty,
    required String refTable,
    required String refId,
    bool triggerSync = true,
  }) {
    return _write(
      partId: partId,
      stage: stage,
      direction: LedgerDirection.in_,
      qty: qty,
      refTable: refTable,
      refId: refId,
      triggerSync: triggerSync,
    );
  }

  Future<StockLedgerResult> _writeOut({
    required String partId,
    required StockStage stage,
    required double qty,
    required String refTable,
    required String refId,
    bool triggerSync = true,
  }) {
    return _write(
      partId: partId,
      stage: stage,
      direction: LedgerDirection.out,
      qty: qty,
      refTable: refTable,
      refId: refId,
      triggerSync: triggerSync,
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
    bool triggerSync = true,
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
        triggerSync: triggerSync,
      );
    }

    return result;
  }
}

class StockPostingFailure implements Exception {
  const StockPostingFailure(this.message);

  final String message;

  @override
  String toString() => message;
}
