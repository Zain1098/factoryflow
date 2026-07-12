import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

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
  final _rejectQtyCtrl = TextEditingController(text: '0');
  bool _isSaving = false;
  String? _error;
  String? _success;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _batchCtrl.dispose();
    _rejectQtyCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _isSaving = true; _error = null; _success = null; });

    try {
      final user = ref.read(currentUserProvider).value;
      final repo = ref.read(bpInspectionRepositoryProvider);
      final result = await repo.save(
        batchNumber: _batchCtrl.text.trim(),
        partId: _partId!,
        machineId: _machineId!,
        bpRejectQty: double.tryParse(_rejectQtyCtrl.text) ?? 0,
        rejectReason: _rejectReason!,
        inspectorId: user?.id ?? 'unknown',
        remarks: null,
      );

      if (result.success) {
        setState(() => _success = 'BP Inspection saved!');
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
    _rejectQtyCtrl.text = '0';
    setState(() { _partId = null; _machineId = null; _rejectReason = null; });
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
    final parts = ref.watch(partsProvider);
    final machines = ref.watch(machinesProvider);
    final batches = ref.watch(recentBatchesProvider);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.calendar_today, size: 18),
                  const SizedBox(width: 8),
                  Text(DateFormat('dd MMM yyyy').format(DateTime.now())),
                  const Spacer(),
                  const Text('Auto', style: TextStyle(color: Colors.green, fontSize: 12)),
                ],
              ),
            ),
            const SizedBox(height: 16),

            const SectionHeader('Batch & Part'),

            // Batch number with autocomplete
            batches.when(
              loading: () => AppFormField(
                label: 'Batch Number',
                controller: _batchCtrl,
                prefixIcon: const Icon(Icons.qr_code_2),
                validator: (v) => v == null || v.trim().isEmpty ? 'Batch number required' : null,
              ),
              error: (_, __) => AppFormField(
                label: 'Batch Number',
                controller: _batchCtrl,
                prefixIcon: const Icon(Icons.qr_code_2),
                validator: (v) => v == null || v.trim().isEmpty ? 'Batch number required' : null,
              ),
              data: (list) => Autocomplete<String>(
                optionsBuilder: (textEditingValue) {
                  if (textEditingValue.text.isEmpty) return list;
                  return list.where((b) =>
                      b.toLowerCase().contains(textEditingValue.text.toLowerCase()),);
                },
                onSelected: (v) {
                  _batchCtrl.text = v;
                  setState(() {});
                },
                fieldViewBuilder: (ctx, ctrl, focusNode, onSubmit) {
                  return TextFormField(
                    controller: ctrl,
                    focusNode: focusNode,
                    onChanged: (v) => _batchCtrl.text = v,
                    decoration: const InputDecoration(
                      labelText: 'Batch Number',
                      prefixIcon: Icon(Icons.qr_code_2),
                    ),
                    validator: (v) => v == null || v.trim().isEmpty ? 'Batch number required' : null,
                  );
                },
              ),
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

            machines.when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => ErrorBanner('Could not load machines: $e'),
              data: (list) => AppDropdown<String>(
                label: 'Machine',
                isRequired: true,
                prefixIcon: const Icon(Icons.precision_manufacturing_outlined),
                value: _machineId,
                items: list.map((m) => DropdownMenuItem(
                  value: m['id'] as String,
                  child: Text(m['name'] as String),
                ),).toList(),
                onChanged: (v) => setState(() => _machineId = v),
                validator: (v) => v == null ? 'Machine is required' : null,
              ),
            ),

            const SectionHeader('Rejection Details'),

            AppDropdown<String>(
              label: 'Reject Reason',
              isRequired: true,
              prefixIcon: const Icon(Icons.report_problem_outlined),
              value: _rejectReason,
              items: kBpRejectReasons.map((r) => DropdownMenuItem(
                value: r,
                child: Text(r),
              ),).toList(),
              onChanged: (v) => setState(() => _rejectReason = v),
              validator: (v) => v == null ? 'Reject reason is required' : null,
            ),
            const SizedBox(height: 12),

            NumberFormField(
              label: 'BP Reject Qty (PCS)',
              controller: _rejectQtyCtrl,
              allowDecimal: false,
              prefixIcon: const Icon(Icons.cancel_outlined),
              validator: (v) {
                if (v == null || v.isEmpty) return 'Required';
                final n = double.tryParse(v);
                if (n == null || n < 0) return 'Enter valid quantity';
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
      error: (e, _) => EmptyState(message: 'Error: $e', icon: Icons.error_outline),
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
                child: const Icon(Icons.fact_check, color: Colors.blue, size: 20),
              ),
              title: Text(r['batch_number'] ?? '—',
                  style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w600),),
              subtitle: Text('${r['part_code'] ?? ''} · ${r['reject_reason_id'] ?? ''} · ${r['date']}'),
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${r['bp_reject_qty']} rej',
                    style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.red),
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
