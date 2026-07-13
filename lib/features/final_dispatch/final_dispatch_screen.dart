import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/master_data_providers.dart';
import '../../core/widgets/shared_widgets.dart';
import '../auth/auth_providers.dart';
import 'final_dispatch_providers.dart';

class FinalDispatchScreen extends ConsumerStatefulWidget {
  const FinalDispatchScreen({super.key});

  @override
  ConsumerState<FinalDispatchScreen> createState() => _FinalDispatchScreenState();
}

class _FinalDispatchScreenState extends ConsumerState<FinalDispatchScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _formKey = GlobalKey<FormState>();

  final _batchCtrl = TextEditingController();
  String? _partId;
  String? _customerId;
  String? _vehicleId;
  String? _driverId;
  final _qtyCtrl = TextEditingController();
  final _challanCtrl = TextEditingController();
  final _remarksCtrl = TextEditingController();
  bool _isSaving = false;
  String? _error;
  String? _success;
  DateTime _recordedAt = DateTime.now();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadDefaultCustomer();
  }

  Future<void> _loadDefaultCustomer() async {
    final id = await ref.read(finalDispatchRepositoryProvider).getDefaultCustomerId();
    if (mounted && id != null) setState(() => _customerId = id);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _batchCtrl.dispose();
    _qtyCtrl.dispose();
    _challanCtrl.dispose();
    _remarksCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _isSaving = true; _error = null; _success = null; });

    try {
      final user = ref.read(currentUserProvider).value;
      final repo = ref.read(finalDispatchRepositoryProvider);
      final result = await repo.save(
        batchNumber: _batchCtrl.text.trim(),
        partId: _partId!,
        customerId: _customerId!,
        dispatchQty: double.parse(_qtyCtrl.text),
        vehicleId: _vehicleId,
        driverId: _driverId,
        challanNumber: _challanCtrl.text.trim().isEmpty ? null : _challanCtrl.text.trim(),
        remarks: _remarksCtrl.text.trim().isEmpty ? null : _remarksCtrl.text.trim(),
        createdBy: user?.id ?? 'unknown',
        recordedAt: _recordedAt,
      );

      if (result.success) {
        setState(() => _success = 'Final Dispatch saved!');
        ref.invalidate(finalDispatchListProvider);
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
    _formKey.currentState?.reset();
    _batchCtrl.clear();
    _qtyCtrl.clear();
    _challanCtrl.clear();
    _remarksCtrl.clear();
    setState(() {
      _partId = null; _vehicleId = null; _driverId = null;
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
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) {
      final id = await ref.read(masterDataRepositoryProvider).insertVehicle(result);
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
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) {
      final id = await ref.read(masterDataRepositoryProvider).insertDriver(result);
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
    final parts = ref.watch(partsProvider);
    final customers = ref.watch(customersProvider);
    final vehicles = ref.watch(vehiclesProvider);
    final drivers = ref.watch(driversProvider);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            RecordDateTimePicker(
              value: _recordedAt,
              onChanged: (dt) => setState(() => _recordedAt = dt),
              showTime: false,
            ),
            const SizedBox(height: 16),

            const SectionHeader('Batch & Part'),

            AppFormField(
              label: 'Batch Number',
              controller: _batchCtrl,
              prefixIcon: const Icon(Icons.qr_code_2),
              validator: (v) => v == null || v.trim().isEmpty ? 'Batch number required' : null,
            ),
            const SizedBox(height: 12),

            parts.when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => ErrorBanner('Could not load parts: $e'),
              data: (list) => AppDropdown<String>(
                label: 'Part',
                isRequired: true,
                prefixIcon: const Icon(Icons.category_outlined),
                value: _partId,
                items: list.map((p) => DropdownMenuItem(
                  value: p['id'] as String,
                  child: Text('${p['code']} – ${p['name']}'),
                ),).toList(),
                onChanged: (v) => setState(() => _partId = v),
                validator: (v) => v == null ? 'Part is required' : null,
              ),
            ),
            const SizedBox(height: 12),

            NumberFormField(
              label: 'Dispatch Qty (PCS)',
              controller: _qtyCtrl,
              allowDecimal: false,
              prefixIcon: const Icon(Icons.send_outlined),
              validator: (v) {
                if (v == null || v.isEmpty) return 'Required';
                final n = double.tryParse(v);
                if (n == null || n <= 0) return 'Must be > 0';
                return null;
              },
            ),

            const SectionHeader('Customer'),

            customers.when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => ErrorBanner('Could not load customers: $e'),
              data: (list) => AppDropdown<String>(
                label: 'Customer',
                isRequired: true,
                prefixIcon: const Icon(Icons.person_pin_outlined),
                value: _customerId,
                items: list.map((c) => DropdownMenuItem(
                  value: c['id'] as String,
                  child: Text(c['name'] as String),
                ),).toList(),
                onChanged: (v) => setState(() => _customerId = v),
                validator: (v) => v == null ? 'Customer is required' : null,
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
                      items: list.map((v) => DropdownMenuItem(
                        value: v['id'] as String,
                        child: Text(v['number_plate'] as String),
                      ),).toList(),
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
                      items: list.map((d) => DropdownMenuItem(
                        value: d['id'] as String,
                        child: Text(d['name'] as String),
                      ),).toList(),
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
      ),
    );
  }

  Widget _buildHistory() {
    final list = ref.watch(finalDispatchListProvider);
    return list.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => EmptyState(message: 'Error: $e', icon: Icons.error_outline),
      data: (records) {
        if (records.isEmpty) {
          return const EmptyState(
            message: 'No final dispatches yet.',
            icon: Icons.send_outlined,
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
                backgroundColor: Colors.indigo.withValues(alpha: 0.12),
                child: const Icon(Icons.send, color: Colors.indigo, size: 20),
              ),
              title: Text(r['batch_number'] ?? '—',
                  style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w600),),
              subtitle: Text('${r['customer_name'] ?? ''} · ${r['date']}'),
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('${r['dispatch_qty']} PCS',
                      style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.indigo),),
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
