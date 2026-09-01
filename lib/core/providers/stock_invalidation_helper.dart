import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/ap_inspection/ap_inspection_providers.dart';
import '../../features/bp_inspection/bp_inspection_providers.dart';
import '../../features/dashboard/dashboard_providers.dart';
import '../../features/dispatch_faco/dispatch_faco_providers.dart';
import '../../features/final_dispatch/final_dispatch_providers.dart';
import '../../features/machine_downtime/machine_downtime_providers.dart';
import '../../features/material_receive/material_receive_providers.dart';
import '../../features/production/production_repository.dart';
import '../../features/receive_faco/receive_faco_providers.dart';
import '../../features/rtv/rtv_providers.dart';
import 'master_data_providers.dart';

/// Invalidate all stock, ledger, and entry providers so changes made in
/// Settings → Stock Management or Physical Stock Audit instantly update
/// across Entries pages, Dashboard, and Reports.
void refreshAllStockAndEntryProviders(WidgetRef ref) {
  // Bump master data revision to refresh parts, machines, suppliers, vendors
  ref.read(masterDataRevProvider.notifier).bump();

  // Invalidate Dashboard KPI & Stock Summary
  ref.invalidate(dashboardProvider);

  // Invalidate Dispatch to Vendor batch providers
  ref.invalidate(bpReinspectedBatchesProvider);
  ref.invalidate(bpStockPartsForDispatchProvider);

  // Invalidate Inspection & Batch Stock providers used in Entries
  ref.invalidate(approvedDispatchBatchesProvider);
  ref.invalidate(recentBatchesProvider);
  ref.invalidate(pendingApStockProvider);
  ref.invalidate(apRejectedStockProvider);
  ref.invalidate(bpRejectedStockProvider);
  ref.invalidate(bpHoldStockProvider);
  ref.invalidate(rtvCandidatesProvider);
  ref.invalidate(rtvStockProvider);
  ref.invalidate(pendingRtvReturnsProvider);

  // Invalidate History Lists across Entries
  ref.invalidate(materialReceiveListProvider);
  ref.invalidate(purchaseOrderListProvider);
  ref.invalidate(productionListProvider);
  ref.invalidate(wipBatchesProvider);
  ref.invalidate(bpInspectionListProvider);
  ref.invalidate(dispatchFacoListProvider);
  ref.invalidate(receiveFacoListProvider);
  ref.invalidate(apInspectionListProvider);
  ref.invalidate(rtvListProvider);
  ref.invalidate(finalDispatchListProvider);
  ref.invalidate(machineDowntimeListProvider);
}
