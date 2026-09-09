import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/stock_invalidation_helper.dart';
import '../../core/widgets/defect_photo_picker.dart';
import '../../core/widgets/shared_widgets.dart';
import '../auth/auth_providers.dart';
import '../final_dispatch/final_dispatch_providers.dart';
import 'ap_inspection_providers.dart';

class ApInspectionScreen extends ConsumerStatefulWidget {
  const ApInspectionScreen({super.key});

  @override
  ConsumerState<ApInspectionScreen> createState() => _ApInspectionScreenState();
}

class _ApPartEntry {
  _ApPartEntry({
    required this.batchNumber,
    required this.partId,
    required this.partCode,
    required this.partName,
    required this.availableQty,
  });

  final String batchNumber;
  final String partId;
  final String partCode;
  final String partName;
  final double availableQty;

  final checkedCtrl = TextEditingController();
  final rejectedCtrl = TextEditingController(text: '0');
  final rtvQtyCtrl = TextEditingController(text: '0');

  double get checked => double.tryParse(checkedCtrl.text) ?? 0;
  double get rejected => double.tryParse(rejectedCtrl.text) ?? 0;
  double get rtvQty => double.tryParse(rtvQtyCtrl.text) ?? 0;
  double get approved => (checked - rejected - rtvQty).clamp(0, double.infinity);
  bool get isBalanced =>
      (approved + rejected + rtvQty - checked).abs() < 0.001;
  bool get exceedsAvailable => checked > availableQty;

  void dispose() {
    checkedCtrl.dispose();
    rejectedCtrl.dispose();
    rtvQtyCtrl.dispose();
  }
}

class _ApInspectionScreenState extends ConsumerState<ApInspectionScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

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
    for (final e in _entries) {
      e.dispose();
    }
    super.dispose();
  }

  void _addPart(Map<String, dynamic> stockItem) {
    final id = stockItem['id'] as String;
    final batchNumber = stockItem['batch_number'] as String;
    if (_entries.any(
      (entry) => entry.partId == id && entry.batchNumber == batchNumber,
    )) {
      return;
    }
    setState(
      () => _entries.add(
        _ApPartEntry(
          batchNumber: batchNumber,
          partId: id,
          partCode: stockItem['code'] as String,
          partName: stockItem['name'] as String,
          availableQty: (stockItem['balance'] as num).toDouble(),
        ),
      ),
    );
  }

  void _removeEntry(int idx) {
    _entries[idx].dispose();
    setState(() => _entries.removeAt(idx));
  }

  Future<void> _save() async {
    if (_entries.isEmpty) {
      setState(() => _error = 'Add at least one part');
      return;
    }
    for (final e in _entries) {
      if (e.checked <= 0) {
        setState(() => _error = '${e.partCode}: Qty Checked must be > 0');
        return;
      }
      if (e.exceedsAvailable) {
        setState(() => _error =
            '${e.partCode}: Checked (${e.checked.toInt()}) exceeds available stock (${e.availableQty.toInt()})',);
        return;
      }
      if (!e.isBalanced) {
        setState(
          () => _error =
              '${e.partCode}: OK + RTV + Final Reject must equal Checked',
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
      final repo = ref.read(apInspectionRepositoryProvider);

      for (final e in _entries) {
        final result = await repo.save(
          batchNumber: e.batchNumber,
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
          setState(() => _error = '${e.partCode}: ${result.error}');
          return;
        }
      }

      setState(
        () => _success =
            'AP Inspection saved for ${_entries.length} batch item(s).',
      );
      refreshAllStockAndEntryProviders(ref);
      ref.invalidate(apInspectionListProvider);
      ref.invalidate(pendingApStockProvider);
      ref.invalidate(apRejectedStockProvider);
      ref.invalidate(apOkStockProvider);
      ref.invalidate(approvedDispatchBatchesProvider);
      ref.invalidate(rtvStockProvider);
      _reset();
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _reset() {
    for (final e in _entries) {
      e.dispose();
    }
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
            Tab(icon: Icon(Icons.history_outlined), text: 'AP Rejected Stock'),
            Tab(icon: Icon(Icons.history), text: 'History'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [_buildForm(), const _ApRejectedTab(), _buildHistory()],
      ),
    );
  }

  void _openBatchPickerSheet(List<Map<String, dynamic>> items) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _ApBatchPickerSheet(
        items: items,
        selectedEntries: _entries,
        onSelect: (item) {
          _addPart(item);
          Navigator.pop(ctx);
        },
      ),
    );
  }

  Widget _buildForm() {
    final rejectReasons = ref.watch(apRejectReasonsListProvider);
    final theme = Theme.of(context);
    final apStockAsync = ref.watch(pendingApStockProvider);

    final totalChecked = _entries.fold<double>(0, (sum, e) => sum + e.checked);
    final totalApproved = _entries.fold<double>(0, (sum, e) => sum + e.approved);
    final totalRtv = _entries.fold<double>(0, (sum, e) => sum + e.rtvQty);
    final totalRejected = _entries.fold<double>(0, (sum, e) => sum + e.rejected);

    return Column(
      children: [
        Expanded(
          child: EntryFormScroll(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                RecordDateTimePicker(
                  value: _recordedAt,
                  onChanged: (dt) => setState(() => _recordedAt = dt),
                  showTime: false,
                ),
                const SizedBox(height: 12),

                // Card 1: Batch Selection & Source
                EntryInfoSurface(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.inventory_2_outlined, size: 18, color: theme.colorScheme.primary),
                          const SizedBox(width: 8),
                          Text(
                            'PLATED BATCH SELECTION',
                            style: theme.textTheme.labelMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.8,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                          const Spacer(),
                          apStockAsync.maybeWhen(
                            data: (items) => Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                '${items.length} BATCHES READY',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                            ),
                            orElse: () => const SizedBox.shrink(),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      apStockAsync.when(
                        loading: () => const LinearProgressIndicator(),
                        error: (e, _) => ErrorBanner('Could not load AP stock: $e'),
                        data: (items) {
                          if (items.isEmpty) {
                            return Container(
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: theme.colorScheme.outlineVariant),
                              ),
                              child: const Row(
                                children: [
                                  Icon(Icons.inbox_outlined, color: Colors.grey, size: 20),
                                  SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      'No pending plated material in stock.\nReceive material from vendor first.',
                                      style: TextStyle(fontSize: 12, color: Colors.grey),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }

                          final unselectedCount = items.where((i) => !_entries.any(
                            (e) => e.partId == i['id'] && e.batchNumber == i['batch_number'],
                          ),).length;

                          return FilledButton.tonalIcon(
                            onPressed: unselectedCount > 0 ? () => _openBatchPickerSheet(items) : null,
                            icon: const Icon(Icons.add_task_rounded, size: 18),
                            label: Text(
                              _entries.isEmpty
                                  ? 'Select Plated Batch to Inspect ($unselectedCount available)'
                                  : 'Add Another Plated Batch ($unselectedCount remaining)',
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                // Card 2: Batch Entries
                if (_entries.isNotEmpty) ...[
                  for (int i = 0; i < _entries.length; i++)
                    _PartEntryCard(
                      entry: _entries[i],
                      onRemove: () => _removeEntry(i),
                      onChanged: () => setState(() {}),
                    ),
                  const SizedBox(height: 12),

                  // Card 3: Defect & Notes
                  EntryInfoSurface(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.rule_folder_outlined, size: 18, color: theme.colorScheme.primary),
                            const SizedBox(width: 8),
                            Text(
                              'QC NOTES & REASONS',
                              style: theme.textTheme.labelMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.8,
                                color: theme.colorScheme.primary,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        AppDropdown<String>(
                          label: 'Reject Reason (if rejected / RTV)',
                          prefixIcon: const Icon(Icons.report_problem_outlined),
                          value: _rejectReason,
                          items: (rejectReasons.value ?? kApRejectReasonsFallback)
                              .toSet()
                              .toList()
                              .map((r) => DropdownMenuItem(value: r, child: Text(r)))
                              .toList(),
                          onChanged: (v) => setState(() => _rejectReason = v),
                        ),
                      ],
                    ),
                  ),
                ],

                if (_error != null) ...[
                  const SizedBox(height: 10),
                  ErrorBanner(_error!),
                ],
                if (_success != null) ...[
                  const SizedBox(height: 10),
                  SuccessBanner(_success!),
                ],
              ],
            ),
          ),
        ),

        // Sticky Bottom Action Bar
        if (_entries.isNotEmpty)
          StickyBottomActionBar(
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Total Checked: ${totalChecked.toInt()} PCS',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                      Text(
                        '✓ ${totalApproved.toInt()} OK  ·  ↺ ${totalRtv.toInt()} RTV  ·  ✗ ${totalRejected.toInt()} Rej',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                FilledButton.icon(
                  onPressed: _isSaving ? null : _save,
                  icon: _isSaving
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.check_circle_outline, size: 18),
                  label: Text(_isSaving ? 'Saving...' : 'Save Inspection'),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildHistory() {
    final list = ref.watch(apInspectionListProvider);
    return list.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) =>
          EmptyState(message: 'Error: $e', icon: Icons.error_outline),
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
            final approved = (r['approved_qty'] as num?)?.toInt() ?? 0;
            final rejected = (r['rejected_qty'] as num?)?.toInt() ?? 0;
            final rtv = (r['rtv_qty'] as num?)?.toInt() ?? 0;
            return ListTile(
              leading: CircleAvatar(
                backgroundColor: Colors.green.withValues(alpha: 0.12),
                child:
                    const Icon(Icons.verified, color: Colors.green, size: 20),
              ),
              title: Text(
                r['batch_number'] ?? '—',
                style: const TextStyle(
                    fontFamily: 'monospace', fontWeight: FontWeight.w600,),
              ),
              subtitle: Text('${r['part_code'] ?? ''} · ${r['date']}'),
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '✓$approved  ✗$rejected',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  if (rtv > 0)
                    Text(
                      'RTV $rtv',
                      style: const TextStyle(
                          fontSize: 11, color: Colors.deepOrange,),
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
    required this.onRemove,
    required this.onChanged,
  });

  final _ApPartEntry entry;
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
    final hasError = e.checked > 0 && (e.exceedsAvailable || !e.isBalanced);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: hasError
              ? Colors.red.withValues(alpha: 0.5)
              : e.isBalanced && e.checked > 0
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        e.partCode,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 14,),
                      ),
                      Text(
                        e.partName,
                        style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.onSurfaceVariant,),
                      ),
                      Text(
                        'Batch ${e.batchNumber}',
                        style: TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    'Available: ${e.availableQty.toInt()} PCS',
                    style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.onSecondaryContainer,),
                  ),
                ),
                const SizedBox(width: 6),
                InkWell(
                  onTap: () {
                    e.checkedCtrl.text = e.availableQty.toInt().toString();
                    e.rejectedCtrl.text = '0';
                    e.rtvQtyCtrl.text = '0';
                  },
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.done_all, size: 12, color: Colors.green),
                        SizedBox(width: 3),
                        Text('All OK', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.green)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 4),
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
                    label: 'AP Rejected (final decision pending)',
                    controller: e.rejectedCtrl,
                    allowDecimal: false,
                    prefixIcon: const Icon(Icons.cancel_outlined, size: 18),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            NumberFormField(
              label: 'RTV Hold Qty',
              controller: e.rtvQtyCtrl,
              allowDecimal: false,
              prefixIcon: const Icon(Icons.undo, size: 18),
            ),
            if (e.checked > 0) ...[
              const SizedBox(height: 8),
              if (e.exceedsAvailable)
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '⚠ Checked qty exceeds available stock (${e.availableQty.toInt()} PCS)',
                    style: const TextStyle(color: Colors.red, fontSize: 12),
                  ),
                )
              else
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: e.isBalanced
                        ? Colors.green.withValues(alpha: 0.08)
                        : Colors.orange.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Icon(
                            e.isBalanced
                                ? Icons.verified_outlined
                                : Icons.pending_outlined,
                            size: 16,
                            color: e.isBalanced ? Colors.green : Colors.orange,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'OK: ${e.approved.toInt()} PCS',
                            style: TextStyle(
                              color:
                                  e.isBalanced ? Colors.green : Colors.orange,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      Wrap(
                        spacing: 6,
                        children: [
                          if (e.rejected > 0)
                            _SplitChip(
                              label: '✗ ${e.rejected.toInt()} Rejected',
                              color: Colors.red,
                            ),
                          if (e.rtvQty > 0)
                            _SplitChip(
                              label: '↩ ${e.rtvQty.toInt()} RTV',
                              color: Colors.deepOrange,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              if (!e.isBalanced && !e.exceedsAvailable && e.checked > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'OK + Rejected = ${(e.approved + e.rejected).toInt()} / '
                    'Checked ${e.checked.toInt()}. RTV must be within Rejected.',
                    style: const TextStyle(color: Colors.orange, fontSize: 11),
                  ),
                ),
              if (e.rejected > 0 || e.rtvQty > 0) ...[
                const SizedBox(height: 10),
                DefectPhotoPicker(
                  label: 'Plating Defect Photo Evidence',
                  hint: 'Capture plating blister, peel, or rust issue',
                  onPhotoChanged: (path) {},
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

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
        style:
            TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}

// ─── AP Rejected Tab ──────────────────────────────────────────────────────────

class _ApRejectedTab extends ConsumerWidget {
  const _ApRejectedTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stockAsync = ref.watch(apRejectedStockProvider);
    final theme = Theme.of(context);

    return stockAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) =>
          EmptyState(message: 'Error: $e', icon: Icons.error_outline),
      data: (items) {
        if (items.isEmpty) {
          return const EmptyState(
            message: 'No AP rejected stock.\nAll clear!',
            icon: Icons.check_circle_outline,
          );
        }

        final totalQty = items.fold(
            0.0, (s, r) => s + ((r['qty'] as num?)?.toDouble() ?? 0),);

        return Column(
          children: [
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
                          '${totalQty.toInt()} PCS AP Rejected',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            color: Colors.red,
                          ),
                        ),
                        Text(
                          'Company stock until you confirm final write-off or vendor return',
                          style: TextStyle(
                              fontSize: 12,
                              color: theme.colorScheme.onSurfaceVariant,),
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
                  return Card(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                      side:
                          BorderSide(color: Colors.red.withValues(alpha: 0.2)),
                    ),
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: Colors.red.withValues(alpha: 0.1),
                        child: const Icon(Icons.cancel,
                            color: Colors.red, size: 20,),
                      ),
                      title: Text(
                        '${item['part_code'] ?? ''} – ${item['part_name'] ?? ''}',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text('Batch ${item['batch_number']} · Pending final company decision'),
                      trailing: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('${qty.toInt()} PCS', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.red)),
                          TextButton(
                            onPressed: () => _confirmWriteOff(context, ref, item, qty),
                            child: const Text('Finalize'),
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

  Future<void> _confirmWriteOff(BuildContext context, WidgetRef ref, Map<String, dynamic> item, double qty) async {
    final note = TextEditingController();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Confirm final AP rejection'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('${qty.toInt()} PCS will be removed from AP rejected company stock.'),
          const SizedBox(height: 12),
          TextField(controller: note, maxLines: 2, decoration: const InputDecoration(labelText: 'Reason / confirmation note *')),
        ],),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, note.text.trim().isNotEmpty), child: const Text('Confirm write-off')),
        ],
      ),
    );
    if (accepted != true) {
      note.dispose();
      return;
    }
    final user = ref.read(currentUserProvider).value;
    final result = await ref.read(apInspectionRepositoryProvider).scrapRejected(
      partId: item['part_id'] as String,
      batchNumber: item['batch_number'] as String,
      qty: qty,
      createdBy: user?.id ?? 'unknown',
      remarks: note.text,
    );
    note.dispose();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result.success ? 'AP rejected stock finalized.' : (result.error ?? 'Unable to finalize rejection.'))));
    if (result.success) {
      refreshAllStockAndEntryProviders(ref);
      ref.invalidate(apRejectedStockProvider);
    }
  }
}

class _ApBatchPickerSheet extends StatefulWidget {
  const _ApBatchPickerSheet({
    required this.items,
    required this.selectedEntries,
    required this.onSelect,
  });

  final List<Map<String, dynamic>> items;
  final List<_ApPartEntry> selectedEntries;
  final ValueChanged<Map<String, dynamic>> onSelect;

  @override
  State<_ApBatchPickerSheet> createState() => _ApBatchPickerSheetState();
}

class _ApBatchPickerSheetState extends State<_ApBatchPickerSheet> {
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filtered = widget.items.where((item) {
      if (_query.isEmpty) return true;
      final partCode = (item['code'] ?? item['part_code'] ?? '').toString().toLowerCase();
      final partName = (item['name'] ?? item['part_name'] ?? '').toString().toLowerCase();
      final batch = (item['batch_number'] ?? '').toString().toLowerCase();
      return partCode.contains(_query) ||
          partName.contains(_query) ||
          batch.contains(_query);
    }).toList();

    return Container(
      height: MediaQuery.of(context).size.height * 0.75,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 10),
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: theme.dividerColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                const Icon(Icons.inventory_2_outlined, size: 20),
                const SizedBox(width: 8),
                Text(
                  'Select Batch for Inspection',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                Text(
                  '${widget.items.length} Available',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: 'Search part or batch number…',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _query.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() => _query = '');
                        },
                      )
                    : null,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
                isDense: true,
              ),
              onChanged: (val) => setState(() => _query = val.trim().toLowerCase()),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: filtered.isEmpty
                ? Center(
                    child: Text(
                      _query.isEmpty
                          ? 'No batches pending inspection.'
                          : 'No batches matching "$_query"',
                      style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    itemCount: filtered.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      final item = filtered[i];
                      final partId = (item['id'] ?? item['part_id'] ?? '').toString();
                      final batch = (item['batch_number'] ?? '').toString();
                      final availQty = (item['available_qty'] as num?)?.toDouble() ?? 0.0;
                      final isSelected = widget.selectedEntries.any(
                        (e) => e.partId == partId && e.batchNumber == batch,
                      );

                      return Material(
                        color: isSelected
                            ? theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5)
                            : theme.colorScheme.surfaceContainerLowest,
                        borderRadius: BorderRadius.circular(12),
                        child: InkWell(
                          onTap: isSelected ? null : () => widget.onSelect(item),
                          borderRadius: BorderRadius.circular(12),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              children: [
                                CircleAvatar(
                                  radius: 18,
                                  backgroundColor: isSelected
                                      ? theme.colorScheme.outlineVariant
                                      : theme.colorScheme.primaryContainer,
                                  child: Icon(
                                    isSelected ? Icons.check : Icons.precision_manufacturing_outlined,
                                    size: 18,
                                    color: isSelected
                                        ? theme.colorScheme.onSurfaceVariant
                                        : theme.colorScheme.onPrimaryContainer,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${item['part_code'] ?? ''} – ${item['part_name'] ?? ''}',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 13,
                                          color: isSelected
                                              ? theme.colorScheme.onSurfaceVariant
                                              : null,
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        'Batch #$batch',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: theme.colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 3,
                                      ),
                                      decoration: BoxDecoration(
                                        color: isSelected
                                            ? Colors.grey.withValues(alpha: 0.15)
                                            : Colors.teal.withValues(alpha: 0.12),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(
                                        '${availQty.toInt()} PCS',
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                          color: isSelected ? Colors.grey : Colors.teal.shade700,
                                        ),
                                      ),
                                    ),
                                    if (isSelected)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 4),
                                        child: Text(
                                          'Added',
                                          style: TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.w600,
                                            color: theme.colorScheme.primary,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
