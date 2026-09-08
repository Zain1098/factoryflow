import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

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
    required this.partAvailableQty,
    required this.batchNumber,
    required VoidCallback onQtyChanged,
  }) {
    qtyCtrl.addListener(onQtyChanged);
  }

  final String partId;
  final String partCode;
  final String partName;
  final double availableQty;
  final double partAvailableQty;
  final String batchNumber;
  final TextEditingController qtyCtrl = TextEditingController();

  double get qty => double.tryParse(qtyCtrl.text.trim()) ?? 0;

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
  bool _isSaving = false;
  String? _error;
  String? _success;
  DateTime _recordedAt = DateTime.now();
  final List<_FacoLine> _items = [];
  String? _selectedPartId;

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
    for (final item in _items) {
      item.dispose();
    }
    super.dispose();
  }

  void _onQtyChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  double get _totalDispatchQty =>
      _items.fold<double>(0.0, (sum, item) => sum + item.qty);

  double get _totalAvailableQty =>
      _items.fold<double>(0.0, (sum, item) => sum + item.availableQty);

  void _addPart(Map<String, dynamic> stock) {
    final id = stock['part_id'] as String;
    final batchNumber = stock['batch_number'] as String;
    if (_items.any((i) => i.partId == id && i.batchNumber == batchNumber)) {
      return;
    }
    setState(() {
      _items.add(
        _FacoLine(
          partId: id,
          partCode: stock['part_code'] as String? ?? '',
          partName: stock['part_name'] as String? ?? '',
          availableQty: (stock['available_qty'] as num?)?.toDouble() ?? 0,
          partAvailableQty:
              (stock['part_available_qty'] as num?)?.toDouble() ?? 0,
          batchNumber: batchNumber,
          onQtyChanged: _onQtyChanged,
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
      setState(() => _error = 'Select at least one batch to dispatch.');
      return;
    }
    if (_vendorId == null) {
      setState(() => _error = 'Vendor is required.');
      return;
    }
    for (final item in _items) {
      if (item.qty <= 0) {
        setState(
          () =>
              _error = 'Enter dispatch quantity for batch ${item.batchNumber}.',
        );
        return;
      }
      if (item.qty > item.availableQty) {
        setState(
          () => _error =
              '${item.partCode} (${item.batchNumber}): quantity exceeds available ${item.availableQty.toInt()} PCS.',
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
      final result = await ref.read(dispatchFacoRepositoryProvider).saveMulti(
            items: _items
                .map(
                  (i) => DispatchFacoLineItem(
                    partId: i.partId,
                    partCode: i.partCode,
                    partName: i.partName,
                    qty: i.qty,
                    batchNumber: i.batchNumber,
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
        final totalPcs = _totalDispatchQty.toInt();
        setState(
          () => _success =
              'Dispatched ${_items.length} batch(es) totaling $totalPcs PCS to vendor successfully!',
        );
        ref.invalidate(dispatchFacoListProvider);
        ref.invalidate(bpReinspectedBatchesProvider);
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
    setState(() {
      _items.clear();
      _selectedPartId = null;
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
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
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
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
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
    final selectedDate = ref.watch(dispatchFacoHistoryDateFilterProvider);
    final isHistoryTab = _tabController.index == 1;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Dispatch to Vendor'),
        actions: isHistoryTab
            ? [
                IconButton(
                  icon: Icon(
                    selectedDate != null
                        ? Icons.event_available
                        : Icons.calendar_month_outlined,
                    color: selectedDate != null ? Colors.amber : null,
                  ),
                  tooltip: selectedDate != null
                      ? 'Change Date (${DateFormat('dd MMM').format(selectedDate)})'
                      : 'Filter by Date',
                  onPressed: () => _pickHistoryDate(context, selectedDate),
                ),
                if (selectedDate != null)
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Show All Records',
                    onPressed: () {
                      ref
                          .read(dispatchFacoHistoryDateFilterProvider.notifier)
                          .setDate(null);
                      ref.invalidate(dispatchFacoListProvider);
                    },
                  ),
              ]
            : null,
        bottom: TabBar(
          controller: _tabController,
          onTap: (_) => setState(() {}),
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
    final batchesAsync = ref.watch(bpReinspectedBatchesProvider);
    final theme = Theme.of(context);

    final partTotals = <String, int>{};
    for (final item in _items) {
      if (item.qty > 0) {
        final label =
            item.partCode.isNotEmpty ? item.partCode : item.batchNumber;
        partTotals[label] = (partTotals[label] ?? 0) + item.qty.toInt();
      }
    }

    return Stack(
      children: [
        SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            16,
            16,
            16,
            partTotals.isNotEmpty ? 150 : 24,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
          RecordDateTimePicker(
            value: _recordedAt,
            onChanged: (dt) => setState(() => _recordedAt = dt),
          ),
          const SizedBox(height: 16),
          const SectionHeader('Select Part & Batches'),
          const Text(
            'Pick a part to view its ready batches. Tap a batch to add it for dispatch.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 12),
          batchesAsync.when(
            loading: () => const LinearProgressIndicator(),
            error: (e, _) =>
                ErrorBanner('Could not load dispatchable batches: $e'),
            data: (list) {
              if (list.isEmpty) {
                return Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.amber.shade300),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.info_outline, color: Colors.orange, size: 20),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'No finished production batches available for vendor dispatch.',
                          style: TextStyle(color: Colors.orange, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                );
              }

              final parts = <String, Map<String, dynamic>>{};
              for (final batch in list) {
                parts.putIfAbsent(batch['part_id'] as String, () => batch);
              }

              final availableBatches = list
                  .where((batch) => batch['part_id'] == _selectedPartId)
                  .where(
                    (batch) => !_items.any(
                      (item) =>
                          item.partId == batch['part_id'] &&
                          item.batchNumber == batch['batch_number'],
                    ),
                  )
                  .toList();

              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AppDropdown<String>(
                    label: 'Part',
                    isRequired: true,
                    prefixIcon: const Icon(Icons.category_outlined),
                    value: _selectedPartId,
                    items: parts.entries
                        .map(
                          (entry) => DropdownMenuItem(
                            value: entry.key,
                            child: Text(
                              '${entry.value['part_code']} – ${entry.value['part_name']}',
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (partId) =>
                        setState(() => _selectedPartId = partId),
                  ),
                  if (_selectedPartId != null) ...[
                    const SizedBox(height: 12),
                    if (availableBatches.isEmpty)
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.grey.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Row(
                          children: [
                            Icon(
                              Icons.check_circle_outline,
                              color: Colors.green,
                              size: 18,
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'All available batches for this part are added below.',
                                style:
                                    TextStyle(fontSize: 12, color: Colors.grey),
                              ),
                            ),
                          ],
                        ),
                      )
                    else ...[
                      const Text(
                        'Available Batches (Tap to Add):',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: availableBatches.map((batch) {
                          final bNum = batch['batch_number'] as String;
                          final avail = (batch['available_qty'] as num).toInt();
                          return ActionChip(
                            avatar: const Icon(
                              Icons.add_circle,
                              size: 16,
                              color: Colors.blue,
                            ),
                            label: Text('$bNum ($avail PCS)'),
                            labelStyle: const TextStyle(
                              fontWeight: FontWeight.w500,
                              fontSize: 12,
                            ),
                            backgroundColor:
                                Colors.blue.withValues(alpha: 0.06),
                            side: BorderSide(
                              color: Colors.blue.withValues(alpha: 0.3),
                            ),
                            onPressed: () => _addPart(batch),
                          );
                        }).toList(),
                      ),
                    ],
                  ],
                ],
              );
            },
          ),
          const SizedBox(height: 16),

          // ─── Selected Batches Section ─────────────────────────────────────
          if (_items.isNotEmpty) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Dispatch Batches (${_items.length})',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                TextButton.icon(
                  onPressed: () {
                    for (final item in _items) {
                      item.qtyCtrl.text = item.availableQty.toInt().toString();
                    }
                    _onQtyChanged();
                  },
                  icon: const Icon(Icons.flash_on, size: 16),
                  label: const Text(
                    'Fill All Max',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ...List.generate(_items.length, (index) {
              final item = _items[index];
              final hasOverQty = item.qty > item.availableQty;
              return Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(
                    color: hasOverQty
                        ? Colors.red
                        : Colors.grey.withValues(alpha: 0.25),
                    width: hasOverQty ? 1.5 : 1,
                  ),
                ),
                margin: const EdgeInsets.only(bottom: 10),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.blue.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              item.batchNumber,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                                color: Colors.blue,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '${item.partCode} · ${item.partName}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          InkWell(
                            onTap: () => _removePart(index),
                            borderRadius: BorderRadius.circular(16),
                            child: const Padding(
                              padding: EdgeInsets.all(4),
                              child: Icon(
                                Icons.close,
                                size: 18,
                                color: Colors.grey,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Available in batch: ${item.availableQty.toInt()} PCS',
                            style: TextStyle(
                              fontSize: 11,
                              color: hasOverQty
                                  ? Colors.red
                                  : Colors.grey.shade700,
                              fontWeight: hasOverQty
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                          GestureDetector(
                            onTap: () {
                              item.qtyCtrl.text =
                                  item.availableQty.toInt().toString();
                              _onQtyChanged();
                            },
                            child: Text(
                              'Max: ${item.availableQty.toInt()}',
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.blue,
                                fontWeight: FontWeight.w600,
                                decoration: TextDecoration.underline,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: item.qtyCtrl,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        decoration: InputDecoration(
                          labelText: 'Dispatch Qty (PCS)',
                          hintText: 'Enter quantity',
                          isDense: true,
                          prefixIcon: const Icon(Icons.numbers, size: 18),
                          errorText: hasOverQty
                              ? 'Exceeds batch available (${item.availableQty.toInt()} PCS)'
                              : null,
                          suffixIcon: item.qtyCtrl.text.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear, size: 16),
                                  onPressed: () {
                                    item.qtyCtrl.clear();
                                    _onQtyChanged();
                                  },
                                )
                              : null,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),

            // ─── Real-Time Live Total Calculator Card ───────────────────────
            Container(
              margin: const EdgeInsets.symmetric(vertical: 8),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.blue.shade800,
                    Colors.indigo.shade900,
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.blue.withValues(alpha: 0.25),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Row(
                        children: [
                          Icon(
                            Icons.calculate_outlined,
                            color: Colors.white70,
                            size: 18,
                          ),
                          SizedBox(width: 6),
                          Text(
                            'LIVE DISPATCH TOTAL',
                            style: TextStyle(
                              color: Colors.white70,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.8,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '${_items.length} ${_items.length == 1 ? "Batch" : "Batches"}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Total To Dispatch',
                            style:
                                TextStyle(color: Colors.white60, fontSize: 12),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${_totalDispatchQty.toInt()} PCS',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 26,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ],
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            'Available: ${_totalAvailableQty.toInt()} PCS',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 11,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Remaining: ${(_totalAvailableQty - _totalDispatchQty).toInt()} PCS',
                            style: TextStyle(
                              color:
                                  (_totalAvailableQty - _totalDispatchQty) < 0
                                      ? Colors.redAccent.shade100
                                      : Colors.greenAccent.shade100,
                              fontWeight: FontWeight.w600,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 16),
          const SectionHeader('Vendor & Logistics'),
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
          const SizedBox(height: 12),
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
          SaveButton(
            onPressed: _save,
            isLoading: _isSaving,
            label: _totalDispatchQty > 0
                ? 'Save Dispatch (${_totalDispatchQty.toInt()} PCS)'
                : 'Save Dispatch',
          ),
        ],
      ),
    ),
    if (partTotals.isNotEmpty)
      Positioned(
        bottom: 16,
        right: 16,
        child: _buildDailyTotalSummaryBox(
          context,
          partTotals,
          theme,
          title: 'LIVE DISPATCH TOTAL',
        ),
      ),
  ],
);
  }

  Future<void> _pickHistoryDate(
    BuildContext context,
    DateTime? current,
  ) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: current ?? now,
      firstDate: DateTime(2023),
      lastDate: now.add(const Duration(days: 1)),
    );
    if (picked != null) {
      ref.read(dispatchFacoHistoryDateFilterProvider.notifier).setDate(picked);
      ref.invalidate(dispatchFacoListProvider);
    }
  }

  Map<String, int> _calculatePartDispatchTotals(
    List<Map<String, dynamic>> records,
  ) {
    final totals = <String, int>{};
    for (final r in records) {
      final code = (r['part_code'] as String?)?.trim();
      final name = (r['part_name'] as String?)?.trim();
      final label = (code != null && code.isNotEmpty)
          ? code
          : (name != null && name.isNotEmpty ? name : 'Unknown');
      final qty = (r['qty'] as num?)?.toInt() ?? 0;
      totals[label] = (totals[label] ?? 0) + qty;
    }
    return totals;
  }

  Widget _buildHistory() {
    final theme = Theme.of(context);
    final selectedDate = ref.watch(dispatchFacoHistoryDateFilterProvider);
    final listAsync = ref.watch(dispatchFacoListProvider);

    return Column(
      children: [
        if (selectedDate != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color:
                    theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: theme.colorScheme.primary.withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.event_available_rounded,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          DateFormat('EEEE, dd MMMM yyyy').format(selectedDate),
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.onSurface,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          'Filtered by selected dispatch date',
                          style: TextStyle(
                            fontSize: 10,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.edit_calendar_outlined, size: 18),
                    tooltip: 'Change Date',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _pickHistoryDate(context, selectedDate),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    tooltip: 'Clear Date Filter (Show All)',
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      ref
                          .read(dispatchFacoHistoryDateFilterProvider.notifier)
                          .setDate(null);
                      ref.invalidate(dispatchFacoListProvider);
                    },
                  ),
                ],
              ),
            ),
          ),
        Expanded(
          child: listAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: EmptyState(
                  message: 'Error: $e',
                  icon: Icons.error_outline,
                ),
              ),
            ),
            data: (records) {
              if (records.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.local_shipping_outlined,
                        size: 48,
                        color: theme.colorScheme.onSurfaceVariant
                            .withValues(alpha: 0.4),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        selectedDate != null
                            ? 'No dispatch records on ${DateFormat('EEEE, dd MMM yyyy').format(selectedDate)}.'
                            : 'No vendor dispatches yet.',
                        style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (selectedDate != null) ...[
                        const SizedBox(height: 10),
                        OutlinedButton.icon(
                          onPressed: () {
                            ref
                                .read(
                                  dispatchFacoHistoryDateFilterProvider
                                      .notifier,
                                )
                                .setDate(null);
                            ref.invalidate(dispatchFacoListProvider);
                          },
                          icon: const Icon(Icons.clear, size: 16),
                          label: const Text('Show All Records'),
                        ),
                      ],
                    ],
                  ),
                );
              }

              final partTotals = _calculatePartDispatchTotals(records);

              return Stack(
                children: [
                  ListView.separated(
                    padding: EdgeInsets.fromLTRB(
                      12,
                      8,
                      12,
                      partTotals.isNotEmpty ? 150 : 24,
                    ),
                    itemCount: records.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      return _buildDispatchHistoryCard(
                        context,
                        records[i],
                        theme,
                      );
                    },
                  ),
                  if (partTotals.isNotEmpty)
                    Positioned(
                      bottom: 16,
                      right: 16,
                      child: _buildDailyTotalSummaryBox(
                        context,
                        partTotals,
                        theme,
                        title: selectedDate != null
                            ? 'DAY DISPATCH (${DateFormat('dd MMM').format(selectedDate)})'
                            : 'TOTAL DISPATCHED',
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildDispatchHistoryCard(
    BuildContext context,
    Map<String, dynamic> r,
    ThemeData theme,
  ) {
    final isSynced = r['sync_status'] == 'synced';
    final qty = (r['qty'] as num?)?.toInt() ?? 0;
    final receivedQty = (r['received_qty'] as num?)?.toInt() ?? 0;
    final hasReceived = receivedQty > 0;
    final partCode = (r['part_code'] as String? ?? '—').trim();
    final partName = (r['part_name'] as String? ?? '').trim();
    final batchNum = (r['batch_number'] as String? ?? '').trim();
    final vendorName = (r['vendor_name'] as String? ?? '—').trim();
    final vehicle = (r['vehicle_number'] as String?)?.trim();
    final driver = (r['driver_name'] as String?)?.trim();
    final challan = (r['challan_number'] as String?)?.trim();
    final remarks = (r['remarks'] as String?)?.trim();
    final dateStr = r['date'] as String? ?? '';
    final timeStr = formatTimeWithoutSeconds(r['time'] as String?);

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top Header: Batch & Actions
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.blue.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    batchNum.isNotEmpty ? batchNum : 'NO BATCH',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      color: Colors.blue,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    partName.isNotEmpty ? '$partCode · $partName' : partCode,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                // Edit Icon
                IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 19),
                  tooltip: 'Edit Dispatch',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _showEditDispatchModal(r),
                ),
                // Delete Icon
                IconButton(
                  icon: const Icon(
                    Icons.delete_outline,
                    size: 19,
                    color: Colors.redAccent,
                  ),
                  tooltip: 'Delete Dispatch & Revert Stock',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _confirmDeleteDispatch(r),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Vendor & Logistics Info
            Row(
              children: [
                Icon(
                  Icons.business_outlined,
                  size: 15,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Vendor: $vendorName',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ),
                Text(
                  '$dateStr ${timeStr.isNotEmpty ? "· $timeStr" : ""}',
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),

            if ((vehicle != null && vehicle.isNotEmpty) ||
                (driver != null && driver.isNotEmpty) ||
                (challan != null && challan.isNotEmpty)) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  if (vehicle != null && vehicle.isNotEmpty)
                    _buildInfoBadge(Icons.local_shipping, vehicle, Colors.grey),
                  if (driver != null && driver.isNotEmpty)
                    _buildInfoBadge(Icons.person, driver, Colors.grey),
                  if (challan != null && challan.isNotEmpty)
                    _buildInfoBadge(
                      Icons.receipt,
                      'Ch: $challan',
                      Colors.blueGrey,
                    ),
                ],
              ),
            ],

            if (remarks != null && remarks.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                'Remarks: $remarks',
                style: TextStyle(
                  fontSize: 11,
                  fontStyle: FontStyle.italic,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],

            const SizedBox(height: 10),
            const Divider(height: 1),
            const SizedBox(height: 8),

            // Bottom Quantities & Status Bar
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Dispatched Qty',
                      style: TextStyle(fontSize: 10, color: Colors.grey),
                    ),
                    Text(
                      '$qty PCS',
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 16,
                        color: Colors.blue,
                      ),
                    ),
                  ],
                ),
                if (hasReceived)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.teal.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.inventory_2_outlined,
                          size: 13,
                          color: Colors.teal,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Received: $receivedQty PCS',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: Colors.teal,
                          ),
                        ),
                      ],
                    ),
                  ),
                Row(
                  children: [
                    Icon(
                      isSynced ? Icons.cloud_done : Icons.cloud_upload_outlined,
                      size: 16,
                      color: isSynced ? Colors.green : Colors.orange,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      isSynced ? 'Synced' : 'Local',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: isSynced ? Colors.green : Colors.orange,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoBadge(IconData icon, String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w500,
              color: Colors.grey.shade800,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDailyTotalSummaryBox(
    BuildContext context,
    Map<String, int> partTotals,
    ThemeData theme, {
    String title = 'TOTAL DISPATCHED',
  }) {
    final grandTotal = partTotals.values.fold<int>(0, (sum, val) => sum + val);

    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(12),
      color: Colors.blue.shade900,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 240),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white24, width: 1),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.local_shipping,
                      size: 13,
                      color: Colors.white70,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ],
                ),
                Text(
                  '$grandTotal PCS',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Divider(color: Colors.white24, height: 1),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 110),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: partTotals.entries.map((e) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Flexible(
                            child: Text(
                              '${e.key} :',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${e.value} PCS',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showEditDispatchModal(Map<String, dynamic> record) async {
    final vendors = ref.read(vendorsProvider).value ?? [];
    final vehicles = ref.read(vehiclesProvider).value ?? [];
    final drivers = ref.read(driversProvider).value ?? [];

    final currentQty = (record['qty'] as num?)?.toDouble() ?? 0.0;
    final qtyCtrl = TextEditingController(text: currentQty.toInt().toString());
    final challanCtrl =
        TextEditingController(text: record['challan_number'] as String? ?? '');
    final remarksCtrl =
        TextEditingController(text: record['remarks'] as String? ?? '');

    String localVendorId = record['vendor_id'] as String? ??
        (vendors.isNotEmpty ? vendors.first['id'] as String : '');
    String? localVehicleId = record['vehicle_id'] as String?;
    String? localDriverId = record['driver_id'] as String?;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          return Padding(
            padding:
                EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Edit Vendor Dispatch',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                          Text(
                            '${record['part_code']} · Batch: ${record['batch_number']}',
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const Divider(),
                  const SizedBox(height: 10),

                  // Quantity
                  TextFormField(
                    controller: qtyCtrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: 'Dispatch Quantity (PCS)',
                      helperText:
                          'Stock between BP Stock and Vendor Stock will adjust automatically',
                      prefixIcon: Icon(Icons.numbers),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Vendor Dropdown
                  if (vendors.isNotEmpty) ...[
                    AppDropdown<String>(
                      label: 'Vendor',
                      isRequired: true,
                      prefixIcon: const Icon(Icons.business_outlined),
                      value: localVendorId.isNotEmpty
                          ? localVendorId
                          : vendors.first['id'] as String,
                      items: vendors
                          .map(
                            (v) => DropdownMenuItem(
                              value: v['id'] as String,
                              child: Text(v['name'] as String),
                            ),
                          )
                          .toList(),
                      onChanged: (v) {
                        if (v != null) setModalState(() => localVendorId = v);
                      },
                    ),
                    const SizedBox(height: 12),
                  ],

                  // Vehicle Dropdown
                  AppDropdown<String>(
                    label: 'Vehicle (optional)',
                    prefixIcon: const Icon(Icons.local_shipping_outlined),
                    value: localVehicleId,
                    items: vehicles
                        .map(
                          (v) => DropdownMenuItem(
                            value: v['id'] as String,
                            child: Text(v['number_plate'] as String),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setModalState(() => localVehicleId = v),
                  ),
                  const SizedBox(height: 12),

                  // Driver Dropdown
                  AppDropdown<String>(
                    label: 'Driver (optional)',
                    prefixIcon: const Icon(Icons.person_outlined),
                    value: localDriverId,
                    items: drivers
                        .map(
                          (d) => DropdownMenuItem(
                            value: d['id'] as String,
                            child: Text(d['name'] as String),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setModalState(() => localDriverId = v),
                  ),
                  const SizedBox(height: 12),

                  // Challan
                  TextFormField(
                    controller: challanCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Challan Number (optional)',
                      prefixIcon: Icon(Icons.receipt_outlined),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Remarks
                  TextFormField(
                    controller: remarksCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Remarks (optional)',
                      prefixIcon: Icon(Icons.notes_outlined),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 18),

                  FilledButton(
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: () async {
                      final newQty =
                          double.tryParse(qtyCtrl.text.trim()) ?? 0.0;
                      if (newQty <= 0) {
                        ScaffoldMessenger.of(ctx).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Please enter a valid dispatch quantity (> 0).',
                            ),
                          ),
                        );
                        return;
                      }

                      final user = ref.read(currentUserProvider).value;
                      final repo = ref.read(dispatchFacoRepositoryProvider);
                      final result = await repo.updateDispatchRecord(
                        dispatchId: record['id'] as String,
                        newQty: newQty,
                        vendorId: localVendorId,
                        vehicleId: localVehicleId,
                        driverId: localDriverId,
                        challanNumber: challanCtrl.text.trim().isEmpty
                            ? null
                            : challanCtrl.text.trim(),
                        remarks: remarksCtrl.text.trim().isEmpty
                            ? null
                            : remarksCtrl.text.trim(),
                        userId: user?.id ?? 'unknown',
                      );

                      if (!ctx.mounted) return;
                      if (!result.success) {
                        ScaffoldMessenger.of(ctx).showSnackBar(
                          SnackBar(
                            content: Text(result.error),
                            backgroundColor: Colors.red,
                          ),
                        );
                        return;
                      }

                      Navigator.pop(ctx);
                      ref.invalidate(dispatchFacoListProvider);
                      ref.invalidate(bpReinspectedBatchesProvider);

                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Dispatch record updated and stock adjusted successfully.',
                          ),
                          backgroundColor: Colors.green,
                        ),
                      );
                    },
                    child: const Text('Save Changes & Adjust Stock'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _confirmDeleteDispatch(Map<String, dynamic> record) async {
    final qty = (record['qty'] as num?)?.toInt() ?? 0;
    final partCode = record['part_code'] as String? ?? '—';
    final batchNum = record['batch_number'] as String? ?? '—';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.red),
            SizedBox(width: 8),
            Text('Delete Dispatch?'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Part: $partCode · Batch: $batchNum',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            Text(
              'Vendor: ${record['vendor_name']} · Date: ${record['date']}',
            ),
            const SizedBox(height: 12),
            const Text(
              'Deleting this dispatch will automatically revert stock:',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
            ),
            const SizedBox(height: 6),
            Text(
              '• Return $qty PCS back into Own BP Stock',
              style: const TextStyle(
                color: Colors.green,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              '• Deduct $qty PCS from Vendor Stock (At Faco)',
              style: const TextStyle(
                color: Colors.red,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            icon: const Icon(Icons.delete_outline, size: 18),
            label: const Text('Delete & Return Stock'),
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final user = ref.read(currentUserProvider).value;
      final repo = ref.read(dispatchFacoRepositoryProvider);
      final result = await repo.deleteDispatchRecord(
        dispatchId: record['id'] as String,
        userId: user?.id ?? 'unknown',
        reason: 'User deleted vendor dispatch from history',
      );

      if (!mounted) return;
      if (result.success) {
        ref.invalidate(dispatchFacoListProvider);
        ref.invalidate(bpReinspectedBatchesProvider);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Dispatch deleted. $qty PCS returned to Own BP Stock.',
            ),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result.error),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
}
