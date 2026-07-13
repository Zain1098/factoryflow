import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/master_data_providers.dart';
import '../../core/widgets/shared_widgets.dart';
import '../auth/auth_providers.dart';
import 'ap_inspection_providers.dart';

class ApInspectionScreen extends ConsumerStatefulWidget {
  const ApInspectionScreen({super.key});

  @override
  ConsumerState<ApInspectionScreen> createState() => _ApInspectionScreenState();
}

class _ApInspectionScreenState extends ConsumerState<ApInspectionScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _formKey = GlobalKey<FormState>();

  final _batchCtrl = TextEditingController();
  String? _partId;
  String? _rejectReason;
  final _checkedCtrl = TextEditingController();
  final _approvedCtrl = TextEditingController();
  final _rejectedCtrl = TextEditingController(text: '0');
  bool _isSaving = false;
  String? _error;
  String? _success;
  DateTime _recordedAt = DateTime.now();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _checkedCtrl.addListener(_autoComputeApproved);
    _rejectedCtrl.addListener(_autoComputeApproved);
  }

  void _autoComputeApproved() {
    final checked = double.tryParse(_checkedCtrl.text) ?? 0;
    final rejected = double.tryParse(_rejectedCtrl.text) ?? 0;
    final approved = (checked - rejected).clamp(0, double.infinity);
    final approvedStr = approved.toStringAsFixed(0);
    if (_approvedCtrl.text != approvedStr) {
      _approvedCtrl.text = approvedStr;
    }
    setState(() {});
  }

  @override
  void dispose() {
    _tabController.dispose();
    _batchCtrl.dispose();
    _checkedCtrl.dispose();
    _approvedCtrl.dispose();
    _rejectedCtrl.dispose();
    super.dispose();
  }

  bool get _isBalanced {
    final checked = double.tryParse(_checkedCtrl.text) ?? 0;
    final approved = double.tryParse(_approvedCtrl.text) ?? 0;
    final rejected = double.tryParse(_rejectedCtrl.text) ?? 0;
    return (approved + rejected - checked).abs() < 0.001;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _isSaving = true; _error = null; _success = null; });

    try {
      final user = ref.read(currentUserProvider).value;
      final repo = ref.read(apInspectionRepositoryProvider);
      final result = await repo.save(
        batchNumber: _batchCtrl.text.trim(),
        partId: _partId!,
        qtyChecked: double.parse(_checkedCtrl.text),
        approvedQty: double.tryParse(_approvedCtrl.text) ?? 0,
        rejectedQty: double.tryParse(_rejectedCtrl.text) ?? 0,
        rejectReason: _rejectReason ?? 'N/A',
        inspectorId: user?.id ?? 'unknown',
        recordedAt: _recordedAt,
      );

      if (result.success) {
        setState(() => _success = 'AP Inspection saved!');
        ref.invalidate(apInspectionListProvider);
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
    _checkedCtrl.clear();
    _approvedCtrl.clear();
    _rejectedCtrl.text = '0';
    setState(() { _partId = null; _rejectReason = null; _recordedAt = DateTime.now(); });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AP Inspection'),
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

            const SectionHeader('Inspection Quantities'),

            NumberFormField(
              label: 'Qty Checked (PCS)',
              controller: _checkedCtrl,
              allowDecimal: false,
              prefixIcon: const Icon(Icons.checklist_outlined),
              validator: (v) {
                if (v == null || v.isEmpty) return 'Required';
                final n = double.tryParse(v);
                if (n == null || n <= 0) return 'Must be > 0';
                return null;
              },
            ),
            const SizedBox(height: 12),

            NumberFormField(
              label: 'Rejected Qty (PCS)',
              controller: _rejectedCtrl,
              allowDecimal: false,
              prefixIcon: const Icon(Icons.cancel_outlined),
              validator: (v) {
                final checked = double.tryParse(_checkedCtrl.text) ?? 0;
                final rejected = double.tryParse(v ?? '0') ?? 0;
                if (rejected > checked) return 'Rejected cannot exceed checked ($checked)';
                return null;
              },
            ),
            const SizedBox(height: 8),

            // Approved qty auto-computed display
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _isBalanced
                      ? Colors.green.withValues(alpha: 0.3)
                      : Colors.red.withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _isBalanced ? Icons.verified_outlined : Icons.error_outline,
                    color: _isBalanced ? Colors.green : Colors.red,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  const Text('Approved Qty (auto)', style: TextStyle(color: Colors.green)),
                  const Spacer(),
                  Text(
                    '${_approvedCtrl.text} PCS',
                    style: TextStyle(
                      color: _isBalanced ? Colors.green : Colors.red,
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                ],
              ),
            ),

            if (!_isBalanced && _checkedCtrl.text.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                'Approved + Rejected must equal Checked',
                style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12),
              ),
            ],

            const SectionHeader('Rejection Details'),

            AppDropdown<String>(
              label: 'Reject Reason',
              prefixIcon: const Icon(Icons.report_problem_outlined),
              value: _rejectReason,
              items: kApRejectReasons.map((r) => DropdownMenuItem(
                value: r,
                child: Text(r),
              ),).toList(),
              onChanged: (v) => setState(() => _rejectReason = v),
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
    final list = ref.watch(apInspectionListProvider);
    return list.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => EmptyState(message: 'Error: $e', icon: Icons.error_outline),
      data: (records) {
        if (records.isEmpty) {
          return const EmptyState(
            message: 'No AP inspections yet.',
            icon: Icons.verified_outlined,
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: records.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final r = records[i];
            final isSynced = r['sync_status'] == 'synced';
            final approved = (r['approved_qty'] as num?)?.toInt() ?? 0;
            final rejected = (r['rejected_qty'] as num?)?.toInt() ?? 0;
            return ListTile(
              leading: CircleAvatar(
                backgroundColor: Colors.green.withValues(alpha: 0.12),
                child: const Icon(Icons.verified, color: Colors.green, size: 20),
              ),
              title: Text(r['batch_number'] ?? '—',
                  style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w600),),
              subtitle: Text('${r['part_code'] ?? ''} · ${r['date']}'),
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('✓$approved  ✗$rejected',
                      style: const TextStyle(fontWeight: FontWeight.bold),),
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
