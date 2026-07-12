/// Stock pipeline stages per PRD Ch. 7.1
enum StockStage {
  rawMaterial('raw_material', 'Raw Material'),
  bpStock('bp_stock', 'BP Stock'),
  atFaco('at_faco', 'At Faco'),
  pendingAp('pending_ap', 'Pending AP Inspection'),
  approvedAp('approved_ap', 'Approved AP Stock'),
  rtvStock('rtv_stock', 'RTV Stock');

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
