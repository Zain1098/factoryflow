import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/master_data_providers.dart';
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
          availableQty: (stockItem['balance'] as num).toDouble(),
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

  Widget _buildForm() {
    final theme = Theme.of(context);
    final apOkAsync = ref.watch(approvedDispatchBatchesProvider);
    final customers = ref.watch(customersProvider);
    final vehicles = ref.watch(vehiclesProvider);
    final drivers = ref.watch(driversProvider);

    return EntryFormScroll(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RecordDateTimePicker(
            value: _recordedAt,
            onChanged: (dt) => setState(() => _recordedAt = dt),
            showTime: false,
          ),
          const SizedBox(height: 16),

          // AP OK Stock — select parts
          Row(
            children: [
              Text(
                'AP OK STOCK — SELECT PARTS',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          apOkAsync.when(
            loading: () => const LinearProgressIndicator(),
            error: (e, _) => ErrorBanner('Could not load AP OK stock: $e'),
            data: (items) {
              final available =
                  items.where((i) => (i['balance'] as num) > 0).toList();
              if (available.isEmpty) {
                return Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Text(
                    'No AP OK stock available.\nComplete AP Inspection first.',
                    textAlign: TextAlign.center,
                  ),
                );
              }
              return Wrap(
                spacing: 8,
                runSpacing: 6,
                children: available.map((item) {
                  final alreadyAdded = _items.any(
                    (dispatchItem) =>
                        dispatchItem.partId == item['id'] &&
                        dispatchItem.batchNumber == item['batch_number'],
                  );
                  final balance = (item['balance'] as num).toInt();
                  return FilterChip(
                    label: Text(
                      '${item['code']} • ${item['batch_number']} '
                      '($balance PCS)',
                    ),
                    selected: alreadyAdded,
                    onSelected: alreadyAdded ? null : (_) => _addPart(item),
                    avatar: alreadyAdded
                        ? const Icon(Icons.check, size: 14)
                        : const Icon(Icons.add, size: 14),
                    selectedColor: theme.colorScheme.primaryContainer,
                  );
                }).toList(),
              );
            },
          ),
          const SizedBox(height: 16),

          // Dispatch items
          if (_items.isEmpty)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 24),
              decoration: BoxDecoration(
                border: Border.all(color: theme.colorScheme.outlineVariant),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Center(
                child: Text(
                  'Tap a part chip above to add it to this dispatch',
                  style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            )
          else ...[
            for (int i = 0; i < _items.length; i++)
              _DispatchItemCard(
                item: _items[i],
                onRemove: () => _removeItem(i),
                onChanged: () => setState(() {}),
              ),
            // Total summary
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color:
                    theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: theme.colorScheme.primary.withValues(alpha: 0.2),),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Total Dispatch',
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.primary,),
                  ),
                  Text(
                    '${_items.fold(0.0, (s, i) => s + i.qty).toInt()} PCS (${_items.length} parts)',
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: theme.colorScheme.primary,),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 20),

          // Customer
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
          const SizedBox(height: 12),

          // Vehicle
          vehicles.when(
            loading: () => const SizedBox.shrink(),
            error: (_, __) => const SizedBox.shrink(),
            data: (list) => Row(
              children: [
                Expanded(
                  child: AppDropdown<String>(
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
                const SizedBox(width: 8),
                IconButton.outlined(
                    onPressed: _addNewVehicle, icon: const Icon(Icons.add),),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Driver
          drivers.when(
            loading: () => const SizedBox.shrink(),
            error: (_, __) => const SizedBox.shrink(),
            data: (list) => Row(
              children: [
                Expanded(
                  child: AppDropdown<String>(
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
                const SizedBox(width: 8),
                IconButton.outlined(
                    onPressed: _addNewDriver, icon: const Icon(Icons.add),),
              ],
            ),
          ),
          const SizedBox(height: 12),

          AppFormField(
            label: 'Challan Number (optional)',
            controller: _challanCtrl,
            prefixIcon: const Icon(Icons.receipt_outlined),
          ),
          const SizedBox(height: 12),

          AppFormField(
            label: 'Remarks (optional)',
            controller: _remarksCtrl,
            maxLines: 2,
            prefixIcon: const Icon(Icons.notes),
          ),

          const SizedBox(height: 20),
          if (_error != null) ErrorBanner(_error!),
          if (_success != null) ...[
            SuccessBanner(_success!),
            if (_savedChallan != null) ...[
              const SizedBox(height: 8),
              Card(
                color: Theme.of(context).colorScheme.secondaryContainer,
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
                            fontWeight: FontWeight.bold,),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
          const SizedBox(height: 12),
          SaveButton(onPressed: _save, isLoading: _isSaving),
          const SizedBox(height: 40),
        ],
      ),
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
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.partCode,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text(
                    item.partName,
                    style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurfaceVariant,),
                  ),
                  Text(
                    'Batch ${item.batchNumber}',
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  Text(
                    'Available: ${item.availableQty.toInt()} PCS',
                    style: TextStyle(
                        fontSize: 11, color: theme.colorScheme.primary,),
                  ),
                ],
              ),
            ),
            SizedBox(
              width: 110,
              child: NumberFormField(
                label: 'Qty',
                controller: item.qtyCtrl,
                allowDecimal: false,
                prefixIcon: const Icon(Icons.send_outlined, size: 16),
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
      ),
    );
  }
}
