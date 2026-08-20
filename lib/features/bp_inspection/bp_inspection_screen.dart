import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/master_data_providers.dart';
import '../../core/widgets/shared_widgets.dart';
import '../auth/auth_providers.dart';
import 'bp_inspection_providers.dart';

class BpInspectionScreen extends ConsumerStatefulWidget {
  const BpInspectionScreen({super.key});

  @override
  ConsumerState<BpInspectionScreen> createState() => _BpInspectionScreenState();
}

class _BpInspectionScreenState extends ConsumerState<BpInspectionScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _formKey = GlobalKey<FormState>();

  final _batchCtrl = TextEditingController();
  String? _partId;
  String? _machineId;
  String? _rejectReason;
  final _holdQtyCtrl = TextEditingController();
  final _rejectQtyCtrl = TextEditingController(text: '0');
  bool _isSaving = false;
  String? _error;
  String? _success;
  DateTime _recordedAt = DateTime.now();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _batchCtrl.dispose();
    _holdQtyCtrl.dispose();
    _rejectQtyCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _isSaving = true;
      _error = null;
      _success = null;
    });

    try {
      final user = ref.read(currentUserProvider).value;
      final repo = ref.read(bpInspectionRepositoryProvider);
      final batchVal = _batchCtrl.text.trim();
      if (batchVal.isEmpty) {
        setState(() => _error = 'Select the original Production batch.');
        return;
      }

      final holdQty = double.tryParse(_holdQtyCtrl.text) ?? 0;
      final rejectQty = double.tryParse(_rejectQtyCtrl.text) ?? 0;
      final result = await repo.save(
        batchNumber: batchVal,
        partId: _partId!,
        machineId: _machineId!,
        inspectedQty: holdQty,
        bpRejectQty: rejectQty,
        rejectReason: rejectQty > 0 ? _rejectReason : null,
        inspectorId: user?.id ?? 'unknown',
        remarks: null,
        recordedAt: _recordedAt,
      );

      if (result.success) {
        setState(
          () => _success = 'BP Inspection saved! Hold $holdQty PCS'
              '${rejectQty > 0 ? ', reject $rejectQty PCS' : ' (all OK)'}',
        );
        ref.invalidate(bpInspectionListProvider);
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
    _batchCtrl.clear();
    _holdQtyCtrl.clear();
    _rejectQtyCtrl.text = '0';
    setState(() {
      _partId = null;
      _machineId = null;
      _rejectReason = null;
      _recordedAt = DateTime.now();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('BP Inspection'),
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
    final rejectReasons = ref.watch(bpRejectReasonsListProvider);
    final parts = ref.watch(partsProvider);
    final machines = ref.watch(machinesProvider);
    final batches = ref.watch(recentBatchesProvider);

    return EntryFormScroll(
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
            ...[
              batches.when(
                loading: () => const LinearProgressIndicator(),
                error: (error, _) =>
                    ErrorBanner('Could not load production batches: $error'),
                data: (list) => AppDropdown<String>(
                  label: 'Production Batch',
                  isRequired: true,
                  prefixIcon: const Icon(Icons.qr_code_2),
                  value: _batchCtrl.text.isEmpty ? null : _batchCtrl.text,
                  items: list
                      .map((batch) => DropdownMenuItem(
                            value: batch['batch_number'] as String,
                            child: Text(
                              '${batch['batch_number']} • ${batch['part_code']} - '
                              '${batch['part_name']} • ${batch['machine_name']}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),)
                      .toList(),
                  onChanged: (value) {
                    if (value == null) return;
                    final batch = list.firstWhere(
                      (item) => item['batch_number'] == value,
                    );
                    setState(() {
                      _batchCtrl.text = value;
                      _partId = batch['part_id'] as String?;
                      _machineId = batch['machine_id'] as String?;
                    });
                  },
                  validator: (value) => value == null
                      ? 'Select the original Production batch'
                      : null,
                ),
              ),
              const SizedBox(height: 12),
            ],
            parts.when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => ErrorBanner('Could not load parts: $e'),
              data: (list) => AppDropdown<String>(
                label: 'Part',
                isRequired: true,
                prefixIcon: const Icon(Icons.category_outlined),
                value: _partId,
                items: list
                    .map(
                      (p) => DropdownMenuItem(
                        value: p['id'] as String,
                        child: Text('${p['code']} – ${p['name']}'),
                      ),
                    )
                    .toList(),
                onChanged: (v) => setState(() => _partId = v),
                validator: (v) => v == null ? 'Part is required' : null,
              ),
            ),
            const SizedBox(height: 12),
            machines.when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => ErrorBanner('Could not load machines: $e'),
              data: (list) => AppDropdown<String>(
                label: 'Machine',
                isRequired: true,
                prefixIcon: const Icon(Icons.precision_manufacturing_outlined),
                value: _machineId,
                items: list
                    .map(
                      (m) => DropdownMenuItem(
                        value: m['id'] as String,
                        child: Text(m['name'] as String),
                      ),
                    )
                    .toList(),
                onChanged: (v) => setState(() => _machineId = v),
                validator: (v) => v == null ? 'Machine is required' : null,
              ),
            ),
            const SectionHeader('Hold & Inspection'),
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                'BP inspection is optional — use it when quality needs to hold '
                'parts. Otherwise finished production can go straight to FACO dispatch.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
            NumberFormField(
              label: 'Hold / Inspect Qty (PCS)',
              controller: _holdQtyCtrl,
              allowDecimal: false,
              prefixIcon: const Icon(Icons.pause_circle_outline),
              validator: (v) {
                if (v == null || v.isEmpty) return 'Required';
                final n = double.tryParse(v);
                if (n == null || n <= 0) return 'Hold qty must be > 0';
                return null;
              },
            ),
            const SizedBox(height: 12),
            NumberFormField(
              label: 'Reject Qty (PCS)',
              controller: _rejectQtyCtrl,
              allowDecimal: false,
              prefixIcon: const Icon(Icons.cancel_outlined),
              validator: (v) {
                if (v == null || v.isEmpty) return 'Required';
                final n = double.tryParse(v);
                if (n == null || n < 0) return 'Enter valid quantity';
                final hold = double.tryParse(_holdQtyCtrl.text) ?? 0;
                if (n > hold) return 'Reject cannot exceed hold qty';
                return null;
              },
            ),
            const SizedBox(height: 12),
            AppDropdown<String>(
              label: 'Reject Reason',
              isRequired: false,
              prefixIcon: const Icon(Icons.report_problem_outlined),
              value: _rejectReason,
              items: (rejectReasons.value ?? kBpRejectReasonsFallback)
                  .map(
                    (r) => DropdownMenuItem(
                      value: r,
                      child: Text(r),
                    ),
                  )
                  .toList(),
              onChanged: (v) => setState(() => _rejectReason = v),
              validator: (v) {
                final reject = double.tryParse(_rejectQtyCtrl.text) ?? 0;
                if (reject > 0 && v == null) {
                  return 'Reject reason required when reject > 0';
                }
                return null;
              },
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
    final list = ref.watch(bpInspectionListProvider);
    return list.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) =>
          EmptyState(message: 'Error: $e', icon: Icons.error_outline),
      data: (records) {
        if (records.isEmpty) {
          return const EmptyState(
            message: 'No BP inspections yet.',
            icon: Icons.fact_check_outlined,
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
                backgroundColor: Colors.blue.withValues(alpha: 0.12),
                child:
                    const Icon(Icons.fact_check, color: Colors.blue, size: 20),
              ),
              title: Text(
                r['batch_number'] ?? '—',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                  '${r['part_code'] ?? ''} · hold ${(r['inspected_qty'] as num?)?.toInt() ?? 0}'
                  '${r['reject_reason_id'] != null ? ' · ${r['reject_reason_id']}' : ''}'
                  ' · ${r['date']}'),
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${(r['bp_reject_qty'] as num?)?.toInt() ?? 0} rej',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.red,
                    ),
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
