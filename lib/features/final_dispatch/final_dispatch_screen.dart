import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/master_data_providers.dart';
import '../../core/providers/stock_invalidation_helper.dart';
import '../../core/services/export_service.dart';
import '../../core/widgets/shared_widgets.dart';
import '../auth/auth_providers.dart';
import '../ap_inspection/ap_inspection_providers.dart';
import 'final_dispatch_providers.dart';

class FinalDispatchScreen extends ConsumerStatefulWidget {
  const FinalDispatchScreen({super.key});

  @override
  ConsumerState<FinalDispatchScreen> createState() =>
      _FinalDispatchScreenState();
}

class _DispatchItem {
  _DispatchItem({
    required this.batchNumber,
    required this.partId,
    required this.partCode,
    required this.partName,
    required this.availableQty,
  });

  final String batchNumber;
  final String partId;
  final String partCode;
  final String partName;
  final double availableQty;
  final qtyCtrl = TextEditingController();

  double get qty => double.tryParse(qtyCtrl.text) ?? 0;
  bool get exceedsAvailable => qty > availableQty;

  void dispose() => qtyCtrl.dispose();
}

class _FinalDispatchScreenState extends ConsumerState<FinalDispatchScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  String? _customerId;
  String? _vehicleId;
  String? _driverId;
  final _challanCtrl = TextEditingController();
  final _remarksCtrl = TextEditingController();
  DateTime _recordedAt = DateTime.now();
  final List<_DispatchItem> _items = [];

  bool _isSaving = false;
  String? _error;
  String? _success;
  String? _savedChallan;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadDefaultCustomer();
  }

  Future<void> _loadDefaultCustomer() async {
    final id =
        await ref.read(finalDispatchRepositoryProvider).getDefaultCustomerId();
    if (mounted && id != null) setState(() => _customerId = id);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _challanCtrl.dispose();
    _remarksCtrl.dispose();
    for (final item in _items) {
      item.dispose();
    }
    super.dispose();
  }

  void _addPart(Map<String, dynamic> stockItem) {
    final id = stockItem['id'] as String;
    final batchNumber = stockItem['batch_number'] as String;
    if (_items.any(
      (item) => item.partId == id && item.batchNumber == batchNumber,
    )) {
      return;
    }
    setState(
      () => _items.add(
        _DispatchItem(
          batchNumber: batchNumber,
          partId: id,
          partCode: stockItem['code'] as String,
          partName: stockItem['name'] as String,
          availableQty: ((stockItem['balance'] ?? stockItem['available_qty']) as num?)?.toDouble() ?? 0.0,
        ),
      ),
    );
  }

  void _removeItem(int idx) {
    _items[idx].dispose();
    setState(() => _items.removeAt(idx));
  }

  Future<void> _save() async {
    if (_customerId == null) {
      setState(() => _error = 'Please select a customer');
      return;
    }
    if (_items.isEmpty) {
      setState(() => _error = 'Add at least one part to dispatch');
      return;
    }
    for (final item in _items) {
      if (item.qty <= 0) {
        setState(() => _error = '${item.partCode}: Enter dispatch qty');
        return;
      }
      if (item.exceedsAvailable) {
        setState(
          () => _error =
              '${item.partCode}: Qty (${item.qty.toInt()}) exceeds available AP OK stock (${item.availableQty.toInt()})',
        );
        return;
      }
    }

    setState(() {
      _isSaving = true;
      _error = null;
      _success = null;
    });

    try {
      final user = ref.read(currentUserProvider).value;
      final repo = ref.read(finalDispatchRepositoryProvider);

      final result = await repo.saveDispatchSession(
        customerId: _customerId!,
        vehicleId: _vehicleId,
        driverId: _driverId,
        challanNumber:
            _challanCtrl.text.trim().isEmpty ? null : _challanCtrl.text.trim(),
        remarks:
            _remarksCtrl.text.trim().isEmpty ? null : _remarksCtrl.text.trim(),
        createdBy: user?.id ?? 'unknown',
        recordedAt: _recordedAt,
        items: _items
            .map(
              (i) => DispatchItemInput(
                batchNumber: i.batchNumber,
                partId: i.partId,
                partCode: i.partCode,
                qty: i.qty,
              ),
            )
            .toList(),
      );

      if (result.success) {
        final totalQty = _items.fold(0.0, (s, i) => s + i.qty).toInt();
        setState(() {
          _success =
              '✅ Dispatch saved! ${_items.length} part(s), $totalQty PCS total.';
          _savedChallan = result.challanNumber;
        });
        ref.invalidate(finalDispatchListProvider);
        ref.invalidate(approvedDispatchBatchesProvider);
        ref.invalidate(apOkStockProvider);
        refreshAllStockAndEntryProviders(ref);
        _reset();
        _loadDefaultCustomer();
      } else {
        setState(() => _error = result.error ?? 'Save failed');
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _reset() {
    _challanCtrl.clear();
    _remarksCtrl.clear();
    for (final item in _items) {
      item.dispose();
    }
    setState(() {
      _items.clear();
      _vehicleId = null;
      _driverId = null;
      _recordedAt = DateTime.now();
    });
  }

  Future<void> _addNewVehicle() async {
    final ctrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Vehicle'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(labelText: 'Number Plate'),
          autofocus: true,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel'),),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) {
      final id =
          await ref.read(masterDataRepositoryProvider).insertVehicle(result);
      ref.invalidate(vehiclesProvider);
      setState(() => _vehicleId = id);
    }
  }

  Future<void> _addNewDriver() async {
    final ctrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Driver'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(labelText: 'Driver Name'),
          autofocus: true,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel'),),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) {
      final id =
          await ref.read(masterDataRepositoryProvider).insertDriver(result);
      ref.invalidate(driversProvider);
      setState(() => _driverId = id);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Final Dispatch'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.send_outlined), text: 'New Dispatch'),
            Tab(icon: Icon(Icons.history), text: 'History'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [_buildForm(), _buildHistory()],
      ),
    );
  }

  void _openBatchPickerSheet(List<Map<String, dynamic>> items) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _FinalDispatchBatchPickerSheet(
        items: items,
        selectedItems: _items,
        onSelect: (item) {
          _addPart(item);
          Navigator.pop(ctx);
        },
      ),
    );
  }

  Widget _buildForm() {
    final theme = Theme.of(context);
    final apOkAsync = ref.watch(approvedDispatchBatchesProvider);
    final customers = ref.watch(customersProvider);
    final vehicles = ref.watch(vehiclesProvider);
    final drivers = ref.watch(driversProvider);
    final totalQty = _items.fold<double>(0, (s, i) => s + i.qty);

    return Column(
      children: [
        Expanded(
          child: EntryFormScroll(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_error != null) ...[
                  ErrorBanner(_error!),
                  const SizedBox(height: 12),
                ],
                if (_success != null) ...[
                  SuccessBanner(_success!),
                  if (_savedChallan != null) ...[
                    const SizedBox(height: 8),
                    Card(
                      color: theme.colorScheme.secondaryContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            const Icon(Icons.receipt_long_outlined),
                            const SizedBox(width: 8),
                            Text(
                              'Challan: $_savedChallan',
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                ],

                // Card 1: Dispatch Header & Customer
                EntryInfoSurface(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _CardSectionHeader(
                        icon: Icons.local_shipping_outlined,
                        title: 'Customer & Dispatch Details',
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: RecordDateTimePicker(
                              value: _recordedAt,
                              onChanged: (dt) => setState(() => _recordedAt = dt),
                              showTime: false,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: AppFormField(
                              label: 'Challan Number',
                              controller: _challanCtrl,
                              hint: 'Auto-generated if empty',
                              prefixIcon: const Icon(Icons.receipt_outlined),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      customers.when(
                        loading: () => const LinearProgressIndicator(),
                        error: (e, _) => ErrorBanner('Could not load customers: $e'),
                        data: (list) => AppDropdown<String>(
                          label: 'Customer',
                          isRequired: true,
                          prefixIcon: const Icon(Icons.person_pin_outlined),
                          value: _customerId,
                          items: list
                              .map(
                                (c) => DropdownMenuItem(
                                  value: c['id'] as String,
                                  child: Text(c['name'] as String),
                                ),
                              )
                              .toList(),
                          onChanged: (v) => setState(() => _customerId = v),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                // Card 2: Logistics & Transport
                EntryInfoSurface(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _CardSectionHeader(
                        icon: Icons.commute_outlined,
                        title: 'Transport & Logistics',
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: vehicles.when(
                              loading: () => const SizedBox.shrink(),
                              error: (_, __) => const SizedBox.shrink(),
                              data: (list) => AppDropdown<String>(
                                label: 'Vehicle (optional)',
                                prefixIcon: const Icon(Icons.local_shipping_outlined),
                                value: _vehicleId,
                                items: list
                                    .map(
                                      (v) => DropdownMenuItem(
                                        value: v['id'] as String,
                                        child: Text(v['number_plate'] as String),
                                      ),
                                    )
                                    .toList(),
                                onChanged: (v) => setState(() => _vehicleId = v),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton.outlined(
                            onPressed: _addNewVehicle,
                            icon: const Icon(Icons.add),
                            tooltip: 'Add Vehicle',
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: drivers.when(
                              loading: () => const SizedBox.shrink(),
                              error: (_, __) => const SizedBox.shrink(),
                              data: (list) => AppDropdown<String>(
                                label: 'Driver (optional)',
                                prefixIcon: const Icon(Icons.person_outlined),
                                value: _driverId,
                                items: list
                                    .map(
                                      (d) => DropdownMenuItem(
                                        value: d['id'] as String,
                                        child: Text(d['name'] as String),
                                      ),
                                    )
                                    .toList(),
                                onChanged: (v) => setState(() => _driverId = v),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton.outlined(
                            onPressed: _addNewDriver,
                            icon: const Icon(Icons.add),
                            tooltip: 'Add Driver',
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      AppFormField(
                        label: 'Remarks / Delivery Notes (optional)',
                        controller: _remarksCtrl,
                        maxLines: 2,
                        prefixIcon: const Icon(Icons.notes),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                // Card 3: Finished Goods Items
                EntryInfoSurface(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: _CardSectionHeader(
                              icon: Icons.inventory_2_outlined,
                              title: 'Finished Goods to Dispatch',
                            ),
                          ),
                          if (_items.isNotEmpty)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primaryContainer,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                '${_items.length} Selected',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: theme.colorScheme.onPrimaryContainer,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      apOkAsync.when(
                        loading: () => const LinearProgressIndicator(),
                        error: (e, _) => ErrorBanner('Could not load AP OK stock: $e'),
                        data: (items) {
                          final available = items
                              .where((i) => ((i['balance'] as num?)?.toDouble() ?? 0) > 0)
                              .toList();
                          if (available.isEmpty) {
                            return Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: theme.colorScheme.outlineVariant),
                              ),
                              child: const Column(
                                children: [
                                  Icon(Icons.inventory_outlined, size: 36, color: Colors.grey),
                                  SizedBox(height: 8),
                                  Text(
                                    'No AP OK stock available for dispatch.\nPerform AP Inspection first to approve parts.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(color: Colors.grey),
                                  ),
                                ],
                              ),
                            );
                          }

                          final unselectedCount = available.where((i) => !_items.any(
                            (item) => item.partId == i['id'] && item.batchNumber == i['batch_number'],
                          ),).length;

                          return FilledButton.tonalIcon(
                            onPressed: unselectedCount > 0 ? () => _openBatchPickerSheet(available) : null,
                            icon: const Icon(Icons.add_shopping_cart, size: 18),
                            label: Text(
                              _items.isEmpty
                                  ? 'Select AP OK Batches (${available.length} available)'
                                  : 'Add Another Batch ($unselectedCount remaining)',
                            ),
                          );
                        },
                      ),
                      if (_items.isNotEmpty) ...[
                        const SizedBox(height: 14),
                        for (int i = 0; i < _items.length; i++)
                          _DispatchItemCard(
                            item: _items[i],
                            onRemove: () => _removeItem(i),
                            onChanged: () => setState(() {}),
                          ),
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: theme.colorScheme.primary.withValues(alpha: 0.2),
                            ),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Total Dispatch Qty',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                              Text(
                                '${totalQty.toInt()} PCS (${_items.length} parts)',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
        StickyBottomActionBar(
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${totalQty.toInt()} PCS',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    Text(
                      '${_items.length} items ready',
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              SaveButton(
                onPressed: _save,
                isLoading: _isSaving,
                label: 'Confirm Dispatch',
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildHistory() {
    final list = ref.watch(finalDispatchListProvider);
    return list.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) =>
          EmptyState(message: 'Error: $e', icon: Icons.error_outline),
      data: (sessions) {
        if (sessions.isEmpty) {
          return const EmptyState(
            message: 'No dispatches yet.',
            icon: Icons.send_outlined,
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.all(12),
          itemCount: sessions.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            final session = sessions[i];
            final items =
                (session['items'] as List).cast<Map<String, dynamic>>();
            final totalQty = items.fold(
                0,
                (s, item) =>
                    s + ((item['dispatch_qty'] as num?)?.toInt() ?? 0),);
            final isSynced = session['sync_status'] == 'synced';

            return Card(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: Colors.indigo.withValues(alpha: 0.2)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3,),
                          decoration: BoxDecoration(
                            color: Colors.indigo.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            session['date'] as String? ?? '—',
                            style: const TextStyle(
                              color: Colors.indigo,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            session['customer_name'] as String? ?? '—',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        Text(
                          '$totalQty PCS',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            color: Colors.indigo,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Icon(
                          isSynced
                              ? Icons.cloud_done
                              : Icons.cloud_upload_outlined,
                          size: 14,
                          color: isSynced ? Colors.green : Colors.orange,
                        ),
                      ],
                    ),
                    if (session['challan_number'] != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Challan: ${session['challan_number']}',
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 12,),
                      ),
                    ],
                    if (session['vehicle_plate'] != null ||
                        session['driver_name'] != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        [
                          if (session['vehicle_plate'] != null)
                            '🚛 ${session['vehicle_plate']}',
                          if (session['driver_name'] != null)
                            '👤 ${session['driver_name']}',
                        ].join('  '),
                        style: TextStyle(
                            fontSize: 12,
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,),
                      ),
                    ],
                    const SizedBox(height: 8),
                    const Divider(height: 1),
                    const SizedBox(height: 8),
                    // Parts list
                    ...items.map(
                      (item) => Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(
                          children: [
                            const Icon(Icons.circle,
                                size: 6, color: Colors.indigo,),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '${item['part_code'] ?? ''} - '
                                '${item['part_name'] ?? ''}'
                                '${item['batch_number'] == null ? '' : ' • ${item['batch_number']}'}',
                                style: const TextStyle(fontSize: 13),
                              ),
                            ),
                            Text(
                              '${(item['dispatch_qty'] as num?)?.toInt() ?? 0} PCS',
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600, fontSize: 13,),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.picture_as_pdf_outlined, size: 16),
                        label: const Text('Print Gate Pass PDF', style: TextStyle(fontSize: 12)),
                        onPressed: () {
                          final challanNum = session['challan_number'] as String? ?? 'CH-${session['id']}';
                          ExportService.exportDeliveryChallanPdf(
                            context: context,
                            challanNumber: challanNum,
                            date: session['date'] as String? ?? '',
                            customerName: session['customer_name'] as String? ?? 'Customer',
                            vehicleNumber: session['vehicle_plate'] as String? ?? '—',
                            driverName: session['driver_name'] as String? ?? '—',
                            items: items
                                .map(
                                  (it) => {
                                    'part_name': it['part_name'],
                                    'part_code': it['part_code'],
                                    'batch_number': it['batch_number'],
                                    'qty': it['dispatch_qty'],
                                  },
                                )
                                .toList(),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

// ─── Dispatch Item Card ───────────────────────────────────────────────────────

class _DispatchItemCard extends StatefulWidget {
  const _DispatchItemCard({
    required this.item,
    required this.onRemove,
    required this.onChanged,
  });

  final _DispatchItem item;
  final VoidCallback onRemove;
  final VoidCallback onChanged;

  @override
  State<_DispatchItemCard> createState() => _DispatchItemCardState();
}

class _DispatchItemCardState extends State<_DispatchItemCard> {
  @override
  void initState() {
    super.initState();
    widget.item.qtyCtrl.addListener(() => setState(() {}));
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: item.exceedsAvailable
              ? Colors.red.withValues(alpha: 0.5)
              : item.qty > 0
                  ? Colors.green.withValues(alpha: 0.4)
                  : theme.colorScheme.outlineVariant,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${item.partCode} – ${item.partName}',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Batch #${item.batchNumber}',
                        style: TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    'Avail: ${item.availableQty.toInt()} PCS',
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                InkWell(
                  onTap: () {
                    item.qtyCtrl.text = item.availableQty.toInt().toString();
                    widget.onChanged();
                  },
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.done_all, size: 12, color: Colors.green),
                        SizedBox(width: 3),
                        Text(
                          'All',
                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.green),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  icon: const Icon(Icons.close, size: 18, color: Colors.red),
                  onPressed: widget.onRemove,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
            const SizedBox(height: 10),
            NumberFormField(
              label: 'Dispatch Quantity (PCS)',
              controller: item.qtyCtrl,
              allowDecimal: false,
              prefixIcon: const Icon(Icons.local_shipping_outlined, size: 18),
            ),
            if (item.exceedsAvailable)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '⚠ Exceeds available AP OK balance (${item.availableQty.toInt()} PCS)',
                  style: const TextStyle(color: Colors.red, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CardSectionHeader extends StatelessWidget {
  const _CardSectionHeader({required this.icon, required this.title});
  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 18, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.bold,
            color: theme.colorScheme.primary,
          ),
        ),
      ],
    );
  }
}

class _FinalDispatchBatchPickerSheet extends StatefulWidget {
  const _FinalDispatchBatchPickerSheet({
    required this.items,
    required this.selectedItems,
    required this.onSelect,
  });

  final List<Map<String, dynamic>> items;
  final List<_DispatchItem> selectedItems;
  final ValueChanged<Map<String, dynamic>> onSelect;

  @override
  State<_FinalDispatchBatchPickerSheet> createState() =>
      _FinalDispatchBatchPickerSheetState();
}

class _FinalDispatchBatchPickerSheetState
    extends State<_FinalDispatchBatchPickerSheet> {
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filtered = widget.items.where((item) {
      if (_query.isEmpty) return true;
      final code = (item['code'] ?? '').toString().toLowerCase();
      final name = (item['name'] ?? '').toString().toLowerCase();
      final batch = (item['batch_number'] ?? '').toString().toLowerCase();
      return code.contains(_query) ||
          name.contains(_query) ||
          batch.contains(_query);
    }).toList();

    return Container(
      height: MediaQuery.of(context).size.height * 0.75,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 10),
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: theme.dividerColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                const Icon(Icons.inventory_2_outlined, size: 20),
                const SizedBox(width: 8),
                Text(
                  'Select Finished Goods to Dispatch',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                Text(
                  '${widget.items.length} Available',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: 'Search part name, code, or batch…',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _query.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() => _query = '');
                        },
                      )
                    : null,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
                isDense: true,
              ),
              onChanged: (val) =>
                  setState(() => _query = val.trim().toLowerCase()),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: filtered.isEmpty
                ? Center(
                    child: Text(
                      _query.isEmpty
                          ? 'No batches available for dispatch.'
                          : 'No batches matching "$_query"',
                      style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    itemCount: filtered.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      final item = filtered[i];
                      final id = item['id'] as String;
                      final batch = item['batch_number'] as String;
                      final balance = ((item['balance'] ?? item['available_qty']) as num?)?.toDouble() ?? 0.0;
                      final isSelected = widget.selectedItems.any(
                        (d) => d.partId == id && d.batchNumber == batch,
                      );

                      return Material(
                        color: isSelected
                            ? theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5)
                            : theme.colorScheme.surfaceContainerLowest,
                        borderRadius: BorderRadius.circular(12),
                        child: InkWell(
                          onTap: isSelected ? null : () => widget.onSelect(item),
                          borderRadius: BorderRadius.circular(12),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              children: [
                                CircleAvatar(
                                  radius: 18,
                                  backgroundColor: isSelected
                                      ? theme.colorScheme.outlineVariant
                                      : theme.colorScheme.primaryContainer,
                                  child: Icon(
                                    isSelected ? Icons.check : Icons.local_shipping_outlined,
                                    size: 18,
                                    color: isSelected
                                        ? theme.colorScheme.onSurfaceVariant
                                        : theme.colorScheme.onPrimaryContainer,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${item['code']} – ${item['name']}',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 13,
                                          color: isSelected
                                              ? theme.colorScheme.onSurfaceVariant
                                              : null,
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        'Batch #$batch',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: theme.colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 3,
                                      ),
                                      decoration: BoxDecoration(
                                        color: isSelected
                                            ? Colors.grey.withValues(alpha: 0.15)
                                            : Colors.indigo.withValues(alpha: 0.12),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(
                                        '${balance.toInt()} PCS',
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                          color: isSelected ? Colors.grey : Colors.indigo,
                                        ),
                                      ),
                                    ),
                                    if (isSelected)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 4),
                                        child: Text(
                                          'Added',
                                          style: TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.w600,
                                            color: theme.colorScheme.primary,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

