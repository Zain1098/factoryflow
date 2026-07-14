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

// One part row in the session
class _ApPartEntry {
  _ApPartEntry({required this.partId, required this.partName});

  final String partId;
  final String partName;

  final checkedCtrl = TextEditingController();
  final rejectedCtrl = TextEditingController(text: '0');

  final rtvQtyCtrl = TextEditingController(text: '0');

  double get checked => double.tryParse(checkedCtrl.text) ?? 0;
  double get rejected => double.tryParse(rejectedCtrl.text) ?? 0;
  double get rtvQty => double.tryParse(rtvQtyCtrl.text) ?? 0;
  double get approved => (checked - rejected - rtvQty).clamp(0, double.infinity);
  bool get isBalanced => (approved + rejected + rtvQty - checked).abs() < 0.001;
  bool get isRtvValid => rtvQty >= 0 && rtvQty <= checked;

  void dispose() {
    checkedCtrl.dispose();
    rejectedCtrl.dispose();
    rtvQtyCtrl.dispose();
  }
}

class _ApInspectionScreenState extends ConsumerState<ApInspectionScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  final _batchCtrl = TextEditingController();
  String? _rejectReason;
  DateTime _recordedAt = DateTime.now();
  final List<_ApPartEntry> _entries = [];

  bool _isSaving = false;
  String? _error;
  String? _success;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _batchCtrl.dispose();
    for (final e in _entries) e.dispose();
    super.dispose();
  }

  void _addPart(Map<String, dynamic> part) {
    final id = part['id'] as String;
    if (_entries.any((e) => e.partId == id)) return;
    setState(() => _entries.add(_ApPartEntry(
      partId: id,
      partName: '${part['code']} – ${part['name']}',
    )));
  }

  void _removeEntry(int idx) {
    _entries[idx].dispose();
    setState(() => _entries.removeAt(idx));
  }

  Future<void> _save() async {
    if (_batchCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Batch number required');
      return;
    }
    if (_entries.isEmpty) {
      setState(() => _error = 'Add at least one part');
      return;
    }
    for (final e in _entries) {
      if (e.checked <= 0) {
        setState(() => _error = '${e.partName}: Qty Checked must be > 0');
        return;
      }
      if (!e.isBalanced) {
        setState(() => _error = '${e.partName}: Approved + Rejected ≠ Checked');
        return;
      }
      if (!e.isRtvValid) {
        setState(() => _error = '${e.partName}: RTV qty invalid');
        return;
      }
    }

    setState(() { _isSaving = true; _error = null; _success = null; });

    try {
      final user = ref.read(currentUserProvider).value;
      final repo = ref.read(apInspectionRepositoryProvider);

      for (final e in _entries) {
        final result = await repo.save(
          batchNumber: _batchCtrl.text.trim(),
          partId: e.partId,
          qtyChecked: e.checked,
          approvedQty: e.approved,
          rejectedQty: e.rejected,
          rejectReason: _rejectReason ?? 'N/A',
          inspectorId: user?.id ?? 'unknown',
          recordedAt: _recordedAt,
          rtvQty: e.rtvQty,
        );
        if (!result.success) {
          setState(() => _error = '${e.partName}: ${result.error}');
          return;
        }
      }

      setState(() => _success = 'AP Inspection saved for ${_entries.length} part(s)!');
      ref.invalidate(apInspectionListProvider);
      ref.invalidate(apRejectedStockProvider);
      _reset();
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _reset() {
    _batchCtrl.clear();
    for (final e in _entries) e.dispose();
    setState(() {
      _entries.clear();
      _rejectReason = null;
      _recordedAt = DateTime.now();
    });
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
            Tab(icon: Icon(Icons.warning_amber_outlined), text: 'AP Rejected'),
            Tab(icon: Icon(Icons.history), text: 'History'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [_buildForm(), const _ApRejectedStockTab(), _buildHistory()],
      ),
    );
  }

  Widget _buildForm() {
    final parts = ref.watch(partsProvider);
    final theme = Theme.of(context);

    return SingleChildScrollView(
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

          const SectionHeader('Batch & Reject Reason'),
          AppFormField(
            label: 'Batch Number',
            controller: _batchCtrl,
            prefixIcon: const Icon(Icons.qr_code_2),
            validator: (v) => v == null || v.trim().isEmpty ? 'Required' : null,
          ),
          const SizedBox(height: 12),
          AppDropdown<String>(
            label: 'Reject Reason (common)',
            prefixIcon: const Icon(Icons.report_problem_outlined),
            value: _rejectReason,
            items: kApRejectReasons.map((r) => DropdownMenuItem(
              value: r, child: Text(r),
            )).toList(),
            onChanged: (v) => setState(() => _rejectReason = v),
          ),
          const SizedBox(height: 20),

          const SectionHeader('Parts Inspected Today'),
          parts.when(
            loading: () => const LinearProgressIndicator(),
            error: (e, _) => ErrorBanner('Could not load parts: $e'),
            data: (list) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: list.map((p) {
                    final alreadyAdded = _entries.any((e) => e.partId == p['id']);
                    return FilterChip(
                      label: Text('${p['code']}'),
                      selected: alreadyAdded,
                      onSelected: alreadyAdded ? null : (_) => _addPart(p),
                      avatar: alreadyAdded ? const Icon(Icons.check, size: 14) : null,
                    );
                  }).toList(),
                ),
                if (_entries.isEmpty) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    decoration: BoxDecoration(
                      border: Border.all(color: theme.colorScheme.outlineVariant),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Center(
                      child: Text(
                        'Tap a part chip above to add it',
                        style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),

          for (int i = 0; i < _entries.length; i++)
            _PartEntryCard(
              entry: _entries[i],
              index: i,
              onRemove: () => _removeEntry(i),
              onChanged: () => setState(() {}),
            ),

          const SizedBox(height: 20),
          if (_error != null) ErrorBanner(_error!),
          if (_success != null) SuccessBanner(_success!),
          const SizedBox(height: 12),
          SaveButton(onPressed: _save, isLoading: _isSaving),
          const SizedBox(height: 40),
        ],
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
            final rtv = (r['rtv_qty'] as num?)?.toInt() ?? 0;
            return ListTile(
              leading: CircleAvatar(
                backgroundColor: Colors.green.withValues(alpha: 0.12),
                child: const Icon(Icons.verified, color: Colors.green, size: 20),
              ),
              title: Text(r['batch_number'] ?? '—',
                  style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w600)),
              subtitle: Text('${r['part_code'] ?? ''} · ${r['date']}'),
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('✓$approved  ✗$rejected',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  if (rtv > 0)
                    Text(
                      'RTV $rtv',
                      style: const TextStyle(fontSize: 11, color: Colors.deepOrange),
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

// ─── Per-Part Entry Card ──────────────────────────────────────────────────────

class _PartEntryCard extends StatefulWidget {
  const _PartEntryCard({
    required this.entry,
    required this.index,
    required this.onRemove,
    required this.onChanged,
  });

  final _ApPartEntry entry;
  final int index;
  final VoidCallback onRemove;
  final VoidCallback onChanged;

  @override
  State<_PartEntryCard> createState() => _PartEntryCardState();
}

class _PartEntryCardState extends State<_PartEntryCard> {
  @override
  void initState() {
    super.initState();
    widget.entry.checkedCtrl.addListener(_rebuild);
    widget.entry.rejectedCtrl.addListener(_rebuild);
    widget.entry.rtvQtyCtrl.addListener(_rebuild);
  }

  void _rebuild() => setState(() {});

  @override
  void dispose() {
    widget.entry.checkedCtrl.removeListener(_rebuild);
    widget.entry.rejectedCtrl.removeListener(_rebuild);
    widget.entry.rtvQtyCtrl.removeListener(_rebuild);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: e.isBalanced && e.checked > 0
              ? Colors.green.withValues(alpha: 0.4)
              : theme.colorScheme.outlineVariant,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(e.partName,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18, color: Colors.red),
                  onPressed: widget.onRemove,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: NumberFormField(
                    label: 'Checked',
                    controller: e.checkedCtrl,
                    allowDecimal: false,
                    prefixIcon: const Icon(Icons.checklist_outlined, size: 18),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: NumberFormField(
                    label: 'AP Rejected',
                    controller: e.rejectedCtrl,
                    allowDecimal: false,
                    prefixIcon: const Icon(Icons.cancel_outlined, size: 18),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            NumberFormField(
              label: 'RTV Stock',
              controller: e.rtvQtyCtrl,
              allowDecimal: false,
              prefixIcon: const Icon(Icons.undo, size: 18),
            ),
            if (e.checked > 0) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: e.isBalanced
                      ? Colors.green.withValues(alpha: 0.08)
                      : Colors.red.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(
                          e.isBalanced ? Icons.verified_outlined : Icons.error_outline,
                          size: 16,
                          color: e.isBalanced ? Colors.green : Colors.red,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Approved: ${e.approved.toInt()} PCS',
                          style: TextStyle(
                            color: e.isBalanced ? Colors.green : Colors.red,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    if (e.rejected > 0)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.red.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '✗ ${e.rejected.toInt()} → AP Rejected',
                          style: const TextStyle(
                            color: Colors.red,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (e.rtvQty > 0) ...[
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerRight,
                  child: _SplitChip(
                    label: '${e.rtvQty.toInt()} PCS -> RTV Stock',
                    color: Colors.deepOrange,
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

// ─── AP Rejected Stock Tab ────────────────────────────────────────────────────

class _SplitChip extends StatelessWidget {
  const _SplitChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _ApRejectedStockTab extends ConsumerWidget {
  const _ApRejectedStockTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stockAsync = ref.watch(apRejectedStockProvider);
    final theme = Theme.of(context);

    return stockAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => EmptyState(message: 'Error: $e', icon: Icons.error_outline),
      data: (items) {
        if (items.isEmpty) {
          return const EmptyState(
            message: 'No AP rejected stock.\nAll clear!',
            icon: Icons.check_circle_outline,
          );
        }

        final totalQty = items.fold(0.0, (s, r) => s + ((r['qty'] as num?)?.toDouble() ?? 0));

        return Column(
          children: [
            // Summary banner
            Container(
              margin: const EdgeInsets.all(12),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.red.withValues(alpha: 0.2)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber, color: Colors.red, size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${totalQty.toInt()} PCS pending action',
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 16, color: Colors.red),
                        ),
                        Text(
                          'Scrap (write off) or Send to Faco vendor',
                          style: TextStyle(
                              fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
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
                  final qty = (item['qty'] as num?)?.toDouble() ?? 0;
                  return _ApRejectedCard(
                    partId: item['part_id'] as String,
                    partCode: item['part_code'] as String? ?? '',
                    partName: item['part_name'] as String? ?? '',
                    qty: qty,
                    onAction: () {
                      ref.invalidate(apRejectedStockProvider);
                    },
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

class _ApRejectedCard extends ConsumerStatefulWidget {
  const _ApRejectedCard({
    required this.partId,
    required this.partCode,
    required this.partName,
    required this.qty,
    required this.onAction,
  });

  final String partId;
  final String partCode;
  final String partName;
  final double qty;
  final VoidCallback onAction;

  @override
  ConsumerState<_ApRejectedCard> createState() => _ApRejectedCardState();
}

class _ApRejectedCardState extends ConsumerState<_ApRejectedCard> {
  bool _loading = false;

  Future<void> _scrap() async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Scrap Rejected Stock',
      message:
          'Mark ${widget.qty.toInt()} PCS of ${widget.partName} as scrapped?\n'
          'This will remove them from stock permanently.',
      confirmLabel: 'Scrap',
      isDestructive: true,
    );
    if (!confirmed) return;

    setState(() => _loading = true);
    final user = ref.read(currentUserProvider).value;
    final repo = ref.read(apInspectionRepositoryProvider);
    final result = await repo.scrapRejected(
      partId: widget.partId,
      qty: widget.qty,
      createdBy: user?.id ?? 'unknown',
    );
    setState(() => _loading = false);

    if (!mounted) return;
    if (result.success) {
      widget.onAction();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Scrapped successfully'), backgroundColor: Colors.orange),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.error ?? 'Failed'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _sendToFaco() async {
    final vendors = ref.read(vendorsProvider).value ?? [];
    if (vendors.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No vendors found. Add vendors in Settings.')),
      );
      return;
    }

    String? selectedVendorId;
    double sendQty = widget.qty;
    final qtyCtrl = TextEditingController(text: widget.qty.toInt().toString());

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('Send to Faco Vendor'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Part: ${widget.partCode} – ${widget.partName}'),
              const SizedBox(height: 12),
              AppDropdown<String>(
                label: 'Vendor',
                isRequired: true,
                prefixIcon: const Icon(Icons.local_shipping_outlined),
                value: selectedVendorId,
                items: vendors.map((v) => DropdownMenuItem(
                  value: v['id'] as String,
                  child: Text(v['name'] as String),
                )).toList(),
                onChanged: (v) => setS(() => selectedVendorId = v),
              ),
              const SizedBox(height: 12),
              NumberFormField(
                label: 'Qty to Send (max ${widget.qty.toInt()})',
                controller: qtyCtrl,
                allowDecimal: false,
                prefixIcon: const Icon(Icons.move_up_outlined),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (selectedVendorId == null) return;
                final q = double.tryParse(qtyCtrl.text) ?? 0;
                if (q <= 0 || q > widget.qty) return;
                sendQty = q;
                Navigator.pop(ctx, true);
              },
              child: const Text('Confirm Dispatch'),
            ),
          ],
        ),
      ),
    );

    qtyCtrl.dispose();
    if (confirmed != true || selectedVendorId == null) return;

    setState(() => _loading = true);
    final user = ref.read(currentUserProvider).value;
    final repo = ref.read(apInspectionRepositoryProvider);
    final result = await repo.sendToFaco(
      partId: widget.partId,
      qty: sendQty,
      vendorId: selectedVendorId!,
      createdBy: user?.id ?? 'unknown',
    );
    setState(() => _loading = false);

    if (!mounted) return;
    if (result.success) {
      widget.onAction();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Sent to Faco — stock moved to At Faco'),
            backgroundColor: Colors.green),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.error ?? 'Failed'), backgroundColor: Colors.red),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.red.withValues(alpha: 0.25)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(widget.partCode,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, color: Colors.red, fontSize: 12)),
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(widget.partName, style: const TextStyle(fontWeight: FontWeight.w600))),
                Text(
                  '${widget.qty.toInt()} PCS',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.red),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_loading)
              const Center(child: CircularProgressIndicator())
            else
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _scrap,
                      icon: const Icon(Icons.delete_outline, size: 16, color: Colors.red),
                      label: const Text('Scrap (Done)', style: TextStyle(color: Colors.red)),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.red),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _sendToFaco,
                      icon: const Icon(Icons.local_shipping_outlined, size: 16),
                      label: const Text('Send to Faco'),
                      style: FilledButton.styleFrom(backgroundColor: Colors.orange),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
