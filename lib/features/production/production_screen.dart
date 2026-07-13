import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/master_data_providers.dart';
import '../../core/widgets/shared_widgets.dart';
import '../auth/auth_providers.dart';
import 'production_providers.dart';

class ProductionScreen extends ConsumerStatefulWidget {
  const ProductionScreen({super.key});

  @override
  ConsumerState<ProductionScreen> createState() => _ProductionScreenState();
}

class _ProductionScreenState extends ConsumerState<ProductionScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _formKey = GlobalKey<FormState>();

  String? _partId;
  String? _partCode;
  // null = 'All Machines' mode, otherwise single machine id
  String? _machineId;
  String? _machineName;
  String? _machineSeq;
  String? _operatorId;
  String _machineStatus = 'Running';
  final _prodQtyCtrl = TextEditingController();
  final _bpRejectCtrl = TextEditingController(text: '0');
  final _remarksCtrl = TextEditingController();
  bool _allMachines = false;

  bool _isSaving = false;
  String? _error;
  String? _success;
  String? _lastBatchNumber;
  DateTime _recordedAt = DateTime.now();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _prodQtyCtrl.dispose();
    _bpRejectCtrl.dispose();
    _remarksCtrl.dispose();
    super.dispose();
  }

  double get _goodQty {
    final prod = double.tryParse(_prodQtyCtrl.text) ?? 0;
    final reject = double.tryParse(_bpRejectCtrl.text) ?? 0;
    return (prod - reject).clamp(0, double.infinity);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _isSaving = true; _error = null; _success = null; });

    try {
      final user = ref.read(currentUserProvider).value;
      final repo = ref.read(productionRepositoryProvider);
      final result = await repo.save(
        partId: _partId!,
        partCode: _partCode!,
        machineId: _allMachines ? 'all' : _machineId!,
        machineName: _machineName!,
        machineCode: _machineSeq!,
        operatorId: _operatorId!,
        machineStatusId: _machineStatus,
        productionQty: double.parse(_prodQtyCtrl.text),
        bpRejectQty: double.tryParse(_bpRejectCtrl.text) ?? 0,
        remarks: _remarksCtrl.text.trim().isEmpty ? null : _remarksCtrl.text.trim(),
        createdBy: user?.id ?? 'unknown',
        recordedAt: _recordedAt,
      );

      if (result.success) {
        setState(() {
          _success = 'Production saved! Batch: ${result.batchNumber}';
          _lastBatchNumber = result.batchNumber;
        });
        ref.invalidate(productionListProvider);
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
    _formKey.currentState?.reset();
    _prodQtyCtrl.clear();
    _bpRejectCtrl.text = '0';
    _remarksCtrl.clear();
    setState(() {
      _partId = null; _partCode = null;
      _machineId = null; _machineName = null; _machineSeq = null;
      _operatorId = null; _machineStatus = 'Running';
      _allMachines = false;
      _recordedAt = DateTime.now();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Production Entry'),
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
    final machines = ref.watch(machinesProvider);
    final operators = ref.watch(operatorsProvider);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Date/time picker
            RecordDateTimePicker(
              value: _recordedAt,
              onChanged: (dt) => setState(() => _recordedAt = dt),
            ),
            const SizedBox(height: 16),

            const SectionHeader('Part & Machine'),

            parts.when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => ErrorBanner('Parts load error: $e'),
              data: (list) => AppDropdown<String>(
                label: 'Part',
                isRequired: true,
                prefixIcon: const Icon(Icons.category_outlined),
                value: _partId,
                items: list.map((p) => DropdownMenuItem(
                  value: p['id'] as String,
                  child: Text('${p['code']} – ${p['name']}'),
                ),).toList(),
                onChanged: (v) {
                  if (v == null) return;
                  final part = list.firstWhere((p) => p['id'] == v);
                  setState(() {
                    _partId = v;
                    _partCode = part['code'] as String;
                  });
                },
                validator: (v) => v == null ? 'Part is required' : null,
              ),
            ),
            const SizedBox(height: 12),

            machines.when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => ErrorBanner('Machines load error: $e'),
              data: (list) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // All Machines toggle
                  Row(
                    children: [
                      Expanded(
                        child: _allMachines
                            ? InputDecorator(
                                decoration: const InputDecoration(
                                  labelText: 'Machine',
                                  prefixIcon: Icon(Icons.precision_manufacturing_outlined),
                                ),
                                child: const Text('All Machines'),
                              )
                            : AppDropdown<String>(
                                label: 'Machine',
                                isRequired: true,
                                prefixIcon: const Icon(Icons.precision_manufacturing_outlined),
                                value: _machineId,
                                items: list.map((m) => DropdownMenuItem(
                                  value: m['id'] as String,
                                  child: Text(m['name'] as String),
                                ),).toList(),
                                onChanged: (v) {
                                  if (v == null) return;
                                  final m = list.firstWhere((m) => m['id'] == v);
                                  setState(() {
                                    _machineId = v;
                                    _machineName = m['name'] as String;
                                    _machineSeq = m['machine_code'] as String? ?? v.substring(0, 1);
                                  });
                                },
                                validator: (v) => (!_allMachines && v == null) ? 'Machine is required' : null,
                              ),
                      ),
                      const SizedBox(width: 8),
                      Tooltip(
                        message: 'All Machines',
                        child: FilterChip(
                          label: const Text('All'),
                          selected: _allMachines,
                          onSelected: (v) => setState(() {
                            _allMachines = v;
                            if (v) {
                              _machineId = null;
                              _machineName = 'All';
                              _machineSeq = 'A';
                            } else {
                              _machineId = null;
                              _machineName = null;
                              _machineSeq = null;
                            }
                          }),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            operators.when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => ErrorBanner('Operators load error: $e'),
              data: (list) => AppDropdown<String>(
                label: 'Operator',
                isRequired: true,
                prefixIcon: const Icon(Icons.person_outlined),
                value: _operatorId,
                items: list.map((o) => DropdownMenuItem(
                  value: o['id'] as String,
                  child: Text(o['name'] as String),
                ),).toList(),
                onChanged: (v) => setState(() => _operatorId = v),
                validator: (v) => v == null ? 'Operator is required' : null,
              ),
            ),
            const SizedBox(height: 12),

            AppDropdown<String>(
              label: 'Machine Status',
              isRequired: true,
              prefixIcon: const Icon(Icons.traffic_outlined),
              value: _machineStatus,
              items: kMachineStatuses.map((s) => DropdownMenuItem(
                value: s,
                child: Text(s),
              ),).toList(),
              onChanged: (v) => setState(() => _machineStatus = v ?? 'Running'),
            ),

            const SectionHeader('Production Quantities'),

            NumberFormField(
              label: 'Production Qty (PCS)',
              controller: _prodQtyCtrl,
              allowDecimal: false,
              prefixIcon: const Icon(Icons.factory_outlined),
              validator: (v) {
                if (v == null || v.isEmpty) return 'Required';
                final n = double.tryParse(v);
                if (n == null || n < 0) return 'Enter valid quantity (0 allowed)';
                return null;
              },
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),

            NumberFormField(
              label: 'BP Reject Qty (PCS)',
              controller: _bpRejectCtrl,
              allowDecimal: false,
              prefixIcon: const Icon(Icons.cancel_outlined),
              validator: (v) {
                final prod = double.tryParse(_prodQtyCtrl.text) ?? 0;
                final reject = double.tryParse(v ?? '0') ?? 0;
                if (reject > prod) return 'Reject cannot exceed production qty ($prod)';
                return null;
              },
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),

            // Good qty display
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.check_circle_outline, color: Colors.green, size: 20),
                  const SizedBox(width: 12),
                  const Text('Good Qty (auto-computed)', style: TextStyle(color: Colors.green)),
                  const Spacer(),
                  Text(
                    '${_goodQty.toStringAsFixed(0)} PCS',
                    style: const TextStyle(
                      color: Colors.green,
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                ],
              ),
            ),

            const SectionHeader('Remarks'),
            AppFormField(
              label: 'Remarks (optional)',
              controller: _remarksCtrl,
              maxLines: 2,
              prefixIcon: const Icon(Icons.notes),
            ),

            if (_lastBatchNumber != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.qr_code_2, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Last Batch: $_lastBatchNumber',
                        style: const TextStyle(fontWeight: FontWeight.w600, fontFamily: 'monospace'),
                      ),
                    ),
                  ],
                ),
              ),
            ],

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
    final list = ref.watch(productionListProvider);
    return list.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => EmptyState(message: 'Error: $e', icon: Icons.error_outline),
      data: (records) {
        if (records.isEmpty) {
          return const EmptyState(
            message: 'No production entries yet.\nCreate your first entry.',
            icon: Icons.precision_manufacturing_outlined,
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: records.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final r = records[i];
            final isSynced = r['sync_status'] == 'synced';
            final goodQty = (r['good_qty'] as num?)?.toInt() ?? 0;
            return ListTile(
              leading: CircleAvatar(
                backgroundColor: Colors.teal.withValues(alpha: 0.12),
                child: const Icon(Icons.precision_manufacturing, color: Colors.teal, size: 20),
              ),
              title: Text(r['batch_number'] ?? '—',
                style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w600),),
              subtitle: Text(
                '${r['machine_name'] ?? ''} · ${r['operator_name'] ?? ''} · ${r['date']}',),
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('$goodQty ok', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.teal)),
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

  String _machineSeqLetter(int seq) {
    // Kept for backward compat — new code uses machine_code from DB directly
    switch (seq) {
      case 1: return 'B';
      case 2: return 'N';
      case 3: return 'E';
      default: return seq.toString();
    }
  }
}
