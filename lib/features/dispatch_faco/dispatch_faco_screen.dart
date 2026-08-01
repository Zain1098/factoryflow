import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/batch_config_provider.dart';
import '../../core/providers/master_data_providers.dart';
import '../../core/widgets/shared_widgets.dart';
import '../auth/auth_providers.dart';
import 'dispatch_faco_providers.dart';

class DispatchFacoScreen extends ConsumerStatefulWidget {
  const DispatchFacoScreen({super.key});

  @override
  ConsumerState<DispatchFacoScreen> createState() => _DispatchFacoScreenState();
}

class _FacoLine {
  _FacoLine({
    required this.partId,
    required this.partCode,
    required this.partName,
    required this.availableQty,
    this.batchNumber,
  });

  final String partId;
  final String partCode;
  final String partName;
  final double availableQty;
  final String? batchNumber;
  final qtyCtrl = TextEditingController();

  double get qty => double.tryParse(qtyCtrl.text) ?? 0;

  void dispose() => qtyCtrl.dispose();
}

class _DispatchFacoScreenState extends ConsumerState<DispatchFacoScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  String? _vendorId;
  String? _vehicleId;
  String? _driverId;
  final _challanCtrl = TextEditingController();
  final _remarksCtrl = TextEditingController();
  final _batchCtrl = TextEditingController();
  bool _isSaving = false;
  String? _error;
  String? _success;
  DateTime _recordedAt = DateTime.now();
  final List<_FacoLine> _items = [];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _challanCtrl.dispose();
    _remarksCtrl.dispose();
    _batchCtrl.dispose();
    for (final item in _items) {
      item.dispose();
    }
    super.dispose();
  }

  void _addPart(Map<String, dynamic> stock) {
    final id = stock['id'] as String;
    if (_items.any((i) => i.partId == id)) return;
    setState(() {
      _items.add(
        _FacoLine(
          partId: id,
          partCode: stock['code'] as String? ?? '',
          partName: stock['name'] as String? ?? '',
          availableQty: (stock['balance'] as num?)?.toDouble() ?? 0,
          batchNumber: _batchCtrl.text.trim().isEmpty
              ? null
              : _batchCtrl.text.trim(),
        ),
      );
    });
  }

  void _removePart(int index) {
    setState(() {
      _items[index].dispose();
      _items.removeAt(index);
    });
  }

  Future<void> _save() async {
    if (_items.isEmpty) {
      setState(() => _error = 'Select at least one part to dispatch.');
      return;
    }
    if (_vendorId == null) {
      setState(() => _error = 'Vendor is required.');
      return;
    }
    for (final item in _items) {
      if (item.qty <= 0) {
        setState(() => _error = 'Enter qty for ${item.partCode}.');
        return;
      }
      if (item.qty > item.availableQty) {
        setState(() => _error =
            '${item.partCode}: qty exceeds available ${item.availableQty.toInt()} PCS.',);
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
      final result = await ref.read(dispatchFacoRepositoryProvider).saveMulti(
            items: _items
                .map(
                  (i) => DispatchFacoLineItem(
                    partId: i.partId,
                    partCode: i.partCode,
                    partName: i.partName,
                    qty: i.qty,
                    batchNumber: i.batchNumber ??
                        (_batchCtrl.text.trim().isEmpty
                            ? null
                            : _batchCtrl.text.trim()),
                  ),
                )
                .toList(),
            vendorId: _vendorId!,
            vehicleId: _vehicleId,
            driverId: _driverId,
            challannumber: _challanCtrl.text.trim().isEmpty
                ? null
                : _challanCtrl.text.trim(),
            remarks: _remarksCtrl.text.trim().isEmpty
                ? null
                : _remarksCtrl.text.trim(),
            createdBy: user?.id ?? 'unknown',
            recordedAt: _recordedAt,
          );

      if (result.success) {
        setState(() => _success =
            'Dispatched ${_items.length} part(s) to FACO successfully!',);
        ref.invalidate(dispatchFacoListProvider);
        ref.invalidate(bpStockPartsForDispatchProvider);
        _reset();
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
    for (final item in _items) {
      item.dispose();
    }
    _challanCtrl.clear();
    _remarksCtrl.clear();
    _batchCtrl.clear();
    setState(() {
      _items.clear();
      _vendorId = null;
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
        title: const Text('Dispatch to Faco'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.add_circle_outline), text: 'New Entry'),
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
    final vendors = ref.watch(vendorsProvider);
    final vehicles = ref.watch(vehiclesProvider);
    final drivers = ref.watch(driversProvider);
    final stockParts = ref.watch(bpStockPartsForDispatchProvider);
    final showBatch = ref.watch(batchConfigProvider);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RecordDateTimePicker(
            value: _recordedAt,
            onChanged: (dt) => setState(() => _recordedAt = dt),
          ),
          const SizedBox(height: 16),
          const SectionHeader('Parts to Dispatch'),
          const Text(
            'Select which parts (and qty) are going to FACO from Own BP Stock. '
            'BP inspection is optional — only needed when quality holds material.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 12),
          if (showBatch) ...[
            AppFormField(
              label: 'Batch Number (optional)',
              controller: _batchCtrl,
              prefixIcon: const Icon(Icons.qr_code_2),
              hint: 'Link a production batch if needed',
            ),
            const SizedBox(height: 12),
          ],
          stockParts.when(
            loading: () => const LinearProgressIndicator(),
            error: (e, _) => ErrorBanner('Could not load BP stock: $e'),
            data: (list) {
              if (list.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'No Own BP Stock available. Finish production first.',
                    style: TextStyle(color: Colors.orange),
                  ),
                );
              }
              return AppDropdown<String>(
                label: 'Add Part',
                isRequired: false,
                prefixIcon: const Icon(Icons.category_outlined),
                value: null,
                items: list
                    .where((p) => !_items.any((i) => i.partId == p['id']))
                    .map(
                      (p) => DropdownMenuItem(
                        value: p['id'] as String,
                        child: Text(
                          '${p['code']} – ${p['name']} '
                          '(${(p['balance'] as num).toInt()} PCS)',
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (id) {
                  if (id == null) return;
                  final match = list.firstWhere((p) => p['id'] == id);
                  _addPart(match);
                },
              );
            },
          ),
          const SizedBox(height: 12),
          ...List.generate(_items.length, (index) {
            final item = _items[index];
            return Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${item.partCode} – ${item.partName}',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () => _removePart(index),
                        ),
                      ],
                    ),
                    Text(
                      'Available: ${item.availableQty.toInt()} PCS',
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    const SizedBox(height: 8),
                    NumberFormField(
                      label: 'Dispatch Qty (PCS)',
                      controller: item.qtyCtrl,
                      allowDecimal: false,
                      prefixIcon: const Icon(Icons.numbers),
                      validator: (v) {
                        if (v == null || v.isEmpty) return 'Required';
                        final n = double.tryParse(v);
                        if (n == null || n <= 0) return 'Qty must be > 0';
                        if (n > item.availableQty) {
                          return 'Exceeds available';
                        }
                        return null;
                      },
                    ),
                  ],
                ),
              ),
            );
          }),

          const SectionHeader('Vendor'),
          vendors.when(
            loading: () => const LinearProgressIndicator(),
            error: (e, _) => ErrorBanner('Could not load vendors: $e'),
            data: (list) => AppDropdown<String>(
              label: 'Vendor',
              isRequired: true,
              prefixIcon: const Icon(Icons.business_outlined),
              value: _vendorId,
              items: list
                  .map(
                    (v) => DropdownMenuItem(
                      value: v['id'] as String,
                      child: Text(v['name'] as String),
                    ),
                  )
                  .toList(),
              onChanged: (v) => setState(() => _vendorId = v),
              validator: (v) => v == null ? 'Vendor is required' : null,
            ),
          ),

          const SectionHeader('Transport (Optional)'),
          vehicles.when(
            loading: () => const LinearProgressIndicator(),
            error: (e, _) => const SizedBox.shrink(),
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
                  onPressed: _addNewVehicle,
                  icon: const Icon(Icons.add),
                  tooltip: 'Add new vehicle',
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          drivers.when(
            loading: () => const LinearProgressIndicator(),
            error: (e, _) => const SizedBox.shrink(),
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
                  onPressed: _addNewDriver,
                  icon: const Icon(Icons.add),
                  tooltip: 'Add new driver',
                ),
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
          const SizedBox(height: 16),
          if (_error != null) ErrorBanner(_error!),
          if (_success != null) SuccessBanner(_success!),
          const SizedBox(height: 16),
          SaveButton(onPressed: _save, isLoading: _isSaving),
        ],
      ),
    );
  }

  Widget _buildHistory() {
    final list = ref.watch(dispatchFacoListProvider);
    return list.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) =>
          EmptyState(message: 'Error: $e', icon: Icons.error_outline),
      data: (records) {
        if (records.isEmpty) {
          return const EmptyState(
            message: 'No dispatches to Faco yet.',
            icon: Icons.local_shipping_outlined,
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: records.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final r = records[i];
            final isSynced = r['sync_status'] == 'synced';
            return ListTile(
              leading: CircleAvatar(
                backgroundColor: Colors.orange.withValues(alpha: 0.12),
                child: const Icon(Icons.local_shipping,
                    color: Colors.orange, size: 20,),
              ),
              title: Text(
                '${r['part_code'] ?? '—'} · ${r['batch_number'] ?? ''}'.trim(),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text('${r['vendor_name'] ?? ''} · ${r['date']}'),
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${r['qty']} PCS',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Icon(
                    isSynced ? Icons.cloud_done : Icons.cloud_upload_outlined,
                    size: 14,
                    color: isSynced ? Colors.green : Colors.orange,
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
