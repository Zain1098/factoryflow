import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/providers/master_data_providers.dart';
import '../../core/widgets/shared_widgets.dart';
import '../auth/auth_providers.dart';
import 'rtv_providers.dart';

class RtvScreen extends ConsumerStatefulWidget {
  const RtvScreen({super.key});

  @override
  ConsumerState<RtvScreen> createState() => _RtvScreenState();
}

class _RtvScreenState extends ConsumerState<RtvScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _formKey = GlobalKey<FormState>();

  final _batchCtrl = TextEditingController();
  String? _partId;
  String? _vendorId;
  String? _reason;
  final _rtvQtyCtrl = TextEditingController();
  final _expectedDateCtrl = TextEditingController();
  final _remarksCtrl = TextEditingController();
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
    _rtvQtyCtrl.dispose();
    _expectedDateCtrl.dispose();
    _remarksCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now().add(const Duration(days: 7)),
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null) {
      _expectedDateCtrl.text =
          '${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _isSaving = true; _error = null; _success = null; });

    try {
      final user = ref.read(currentUserProvider).value;
      final repo = ref.read(rtvRepositoryProvider);
      final result = await repo.save(
        batchNumber: _batchCtrl.text.trim(),
        partId: _partId!,
        rtvQty: double.parse(_rtvQtyCtrl.text),
        reason: _reason!,
        vendorId: _vendorId!,
        expectedReturnDate: _expectedDateCtrl.text.trim().isEmpty ? null : _expectedDateCtrl.text.trim(),
        remarks: _remarksCtrl.text.trim().isEmpty ? null : _remarksCtrl.text.trim(),
        createdBy: user?.id ?? 'unknown',
      );

      if (result.success) {
        setState(() => _success = 'RTV saved! Cycle #${result.cycleNumber}');
        ref.invalidate(rtvListProvider);
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
    _rtvQtyCtrl.clear();
    _expectedDateCtrl.clear();
    _remarksCtrl.clear();
    setState(() { _partId = null; _vendorId = null; _reason = null; });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('RTV — Return to Vendor'),
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
    final vendors = ref.watch(vendorsProvider);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // RTV cycle cap warning
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.info_outline, color: Colors.orange, size: 18),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Max 3 RTV cycles per batch. After 3, status is escalated to Admin.',
                      style: TextStyle(color: Colors.orange, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

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
              label: 'RTV Qty (PCS)',
              controller: _rtvQtyCtrl,
              allowDecimal: false,
              prefixIcon: const Icon(Icons.undo),
              validator: (v) {
                if (v == null || v.isEmpty) return 'Required';
                final n = double.tryParse(v);
                if (n == null || n <= 0) return 'Must be > 0';
                return null;
              },
            ),

            const SectionHeader('Vendor & Reason'),

            vendors.when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => ErrorBanner('Could not load vendors: $e'),
              data: (list) => AppDropdown<String>(
                label: 'Vendor',
                isRequired: true,
                prefixIcon: const Icon(Icons.business_outlined),
                value: _vendorId,
                items: list.map((v) => DropdownMenuItem(
                  value: v['id'] as String,
                  child: Text(v['name'] as String),
                ),).toList(),
                onChanged: (v) => setState(() => _vendorId = v),
                validator: (v) => v == null ? 'Vendor is required' : null,
              ),
            ),
            const SizedBox(height: 12),

            AppDropdown<String>(
              label: 'RTV Reason',
              isRequired: true,
              prefixIcon: const Icon(Icons.report_problem_outlined),
              value: _reason,
              items: kRtvReasons.map((r) => DropdownMenuItem(
                value: r,
                child: Text(r),
              ),).toList(),
              onChanged: (v) => setState(() => _reason = v),
              validator: (v) => v == null ? 'Reason is required' : null,
            ),
            const SizedBox(height: 12),

            AppFormField(
              label: 'Expected Return Date (optional)',
              controller: _expectedDateCtrl,
              readOnly: true,
              prefixIcon: const Icon(Icons.event_outlined),
              suffixIcon: IconButton(
                icon: const Icon(Icons.calendar_month),
                onPressed: _pickDate,
              ),
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
    final list = ref.watch(rtvListProvider);
    return list.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => EmptyState(message: 'Error: $e', icon: Icons.error_outline),
      data: (records) {
        if (records.isEmpty) {
          return const EmptyState(
            message: 'No RTV entries yet.',
            icon: Icons.undo,
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: records.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final r = records[i];
            final isSynced = r['sync_status'] == 'synced';
            final cycle = r['cycle_number'] as int? ?? 1;
            final status = r['status'] as String? ?? 'pending';
            return ListTile(
              leading: CircleAvatar(
                backgroundColor: Colors.red.withValues(alpha: 0.12),
                child: const Icon(Icons.undo, color: Colors.red, size: 20),
              ),
              title: Text(r['batch_number'] ?? '—',
                  style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w600),),
              subtitle: Text('${r['vendor_name'] ?? ''} · Cycle $cycle · ${r['date']}'),
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('${r['rtv_qty']} PCS',
                      style: const TextStyle(fontWeight: FontWeight.bold),),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: _statusColor(status).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      status,
                      style: TextStyle(fontSize: 10, color: _statusColor(status)),
                    ),
                  ),
                  Icon(
                    isSynced ? Icons.cloud_done : Icons.cloud_upload_outlined,
                    size: 12,
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

  Color _statusColor(String status) {
    switch (status) {
      case 'sent': return Colors.blue;
      case 'received': return Colors.green;
      case 'escalated': return Colors.red;
      default: return Colors.orange;
    }
  }
}
