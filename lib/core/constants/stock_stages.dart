/// Stock pipeline stages per PRD Ch. 7.1
enum StockStage {
  rawMaterial('raw_material', 'Raw Material'),
  bpStock('bp_stock', 'Own BP Stock'),
  bpHold('bp_hold', 'BP Hold / Inspection'),
  bpRejected('bp_rejected', 'BP Rejected'),
  atFaco('at_faco', 'Vendor Stock (Sent Out)'),
  pendingAp('pending_ap', 'Pending AP Inspection'),
  approvedAp('approved_ap', 'Own Finished (AP OK / Ready Dispatch)'),
  apRejected('ap_rejected', 'AP Rejected (Awaiting Final Decision)'),
  rtvStock('rtv_stock', 'AP RTV Hold (Awaiting Vendor Return)');

  const StockStage(this.value, this.label);
  final String value;
  final String label;

  static StockStage? fromValue(String value) {
    for (final stage in StockStage.values) {
      if (stage.value == value) return stage;
    }
    return null;
  }
}

/// A production WIP location is tied to the machine that produced it instead
/// of a hard-coded machine name. This keeps the stock flow correct if the
/// factory later changes its production sequence.
String productionWipStage(String machineId) => 'production_wip_$machineId';

const kProductionRejectedStage = 'production_rejected';

enum LedgerDirection {
  in_('IN'),
  out('OUT');

  const LedgerDirection(this.value);
  final String value;
}

enum SyncStatus {
  synced('synced'),
  pending('pending'),
  conflict('conflict'),
  failed('failed');

  const SyncStatus(this.value);
  final String value;
}
