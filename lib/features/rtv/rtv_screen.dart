import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/master_data_providers.dart';
import '../../core/widgets/shared_widgets.dart';
import '../auth/auth_providers.dart';
import '../ap_inspection/ap_inspection_providers.dart';
import 'rtv_providers.dart';

class RtvScreen extends ConsumerStatefulWidget {
  const RtvScreen({super.key});

  @override
  ConsumerState<RtvScreen> createState() => _RtvScreenState();
}

class _RtvScreenState extends ConsumerState<RtvScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

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
  DateTime _recordedAt = DateTime.now();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
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
    if (_batchCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Batch number required');
      return;
    }
    if (_partId == null || _vendorId == null || _reason == null) {
      setState(() => _error = 'Please fill all required fields');
      return;
    }
    final qty = double.tryParse(_rtvQtyCtrl.text) ?? 0;
    if (qty <= 0) {
      setState(() => _error = 'Enter valid RTV qty');
      return;
    }

    setState(() { _isSaving = true; _error = null; _success = null; });

    try {
      final user = ref.read(currentUserProvider).value;
      final repo = ref.read(rtvRepositoryProvider);
      final result = await repo.save(
        batchNumber: _batchCtrl.text.trim(),
        partId: _partId!,
        rtvQty: qty,
        reason: _reason!,
        vendorId: _vendorId!,
        expectedReturnDate: _expectedDateCtrl.text.trim().isEmpty ? null : _expectedDateCtrl.text.trim(),
        remarks: _remarksCtrl.text.trim().isEmpty ? null : _remarksCtrl.text.trim(),
        createdBy: user?.id ?? 'unknown',
        recordedAt: _recordedAt,
      );

      if (result.success) {
        setState(() => _success = 'RTV saved! Cycle #${result.cycleNumber}');
        ref.invalidate(rtvListProvider);
        ref.invalidate(rtvStockProvider);
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
    _batchCtrl.clear();
    _rtvQtyCtrl.clear();
    _expectedDateCtrl.clear();
    _remarksCtrl.clear();
    setState(() {
      _partId = null;
      _vendorId = null;
      _reason = null;
      _recordedAt = DateTime.now();
    });
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
            Tab(icon: Icon(Icons.inventory_2_outlined), text: 'RTV Stock'),
            Tab(icon: Icon(Icons.history), text: 'History'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [_buildForm(), const _RtvStockTab(), _buildHistory()],
      ),
    );
  }

  Widget _buildForm() {
    final parts = ref.watch(partsProvider);
    final vendors = ref.watch(vendorsProvider);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
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
            ),
          ),
          const SizedBox(height: 12),

          NumberFormField(
            label: 'RTV Qty (PCS)',
            controller: _rtvQtyCtrl,
            allowDecimal: false,
            prefixIcon: const Icon(Icons.undo),
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
          const SizedBox(height: 40),
        ],
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
                    child: Text(status,
                        style: TextStyle(fontSize: 10, color: _statusColor(status)),),
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

// ─── RTV Stock Tab ────────────────────────────────────────────────────────────
// Shows: vendor ke paas hamara kitna material hai, kab gaya, kyun gaya

class _RtvStockTab extends ConsumerWidget {
  const _RtvStockTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stockAsync = ref.watch(rtvStockProvider);
    final theme = Theme.of(context);

    return stockAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => EmptyState(message: 'Error: $e', icon: Icons.error_outline),
      data: (items) {
        if (items.isEmpty) {
          return const EmptyState(
            message: 'No RTV stock.\nAll returned or none sent yet.',
            icon: Icons.inventory_2_outlined,
          );
        }

        // Group by part for summary
        final totalRtv = items.fold(0.0, (s, r) => s + ((r['rtv_qty'] as num?)?.toDouble() ?? 0));
        final totalCurrent = items.fold(0.0, (s, r) => s + ((r['current_balance'] as num?)?.toDouble() ?? 0));

        return Column(
          children: [
            // Summary banner
            Container(
              margin: const EdgeInsets.all(12),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.deepOrange.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.deepOrange.withValues(alpha: 0.2)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.inventory_2_outlined, color: Colors.deepOrange, size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${totalCurrent.toInt()} PCS at Vendor',
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 16, color: Colors.deepOrange,),
                        ),
                        Text(
                          '${totalRtv.toInt()} PCS total sent for RTV',
                          style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: items.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, i) {
                  final item = items[i];
                  final rtvQty = (item['rtv_qty'] as num?)?.toInt() ?? 0;
                  final currentBalance = (item['current_balance'] as num?)?.toInt() ?? 0;
                  final date = item['date'] as String? ?? '—';
                  final reason = item['reason'] as String? ?? '—';
                  final batch = item['batch_number'] as String? ?? '—';

                  return Card(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                      side: BorderSide(color: Colors.deepOrange.withValues(alpha: 0.2)),
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
                                      '${item['part_code'] ?? ''} – ${item['part_name'] ?? ''}',
                                      style: const TextStyle(fontWeight: FontWeight.bold),
                                    ),
                                    Text(
                                      'Batch: $batch',
                                      style: const TextStyle(
                                          fontFamily: 'monospace', fontSize: 11,),
                                    ),
                                  ],
                                ),
                              ),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    '$rtvQty PCS sent',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: Colors.deepOrange,),
                                  ),
                                  if (currentBalance > 0)
                                    Text(
                                      '$currentBalance PCS at vendor',
                                      style: const TextStyle(
                                          fontSize: 11, color: Colors.orange,),
                                    ),
                                ],
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              _InfoChip(
                                icon: Icons.calendar_today_outlined,
                                label: date,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _InfoChip(
                                  icon: Icons.report_problem_outlined,
                                  label: reason,
                                  color: Colors.orange,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.icon, required this.label, required this.color});
  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 11, color: color)),
      ],
    );
  }
}
