import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/providers/master_data_providers.dart';
import '../../core/widgets/barcode_scanner_view.dart';
import '../../core/widgets/shared_widgets.dart';
import '../auth/auth_providers.dart';
import 'receive_faco_providers.dart';

class ReceiveFacoScreen extends ConsumerStatefulWidget {
  const ReceiveFacoScreen({super.key});

  @override
  ConsumerState<ReceiveFacoScreen> createState() => _ReceiveFacoScreenState();
}

class _ReceiveFacoScreenState extends ConsumerState<ReceiveFacoScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _formKey = GlobalKey<FormState>();

  final _batchCtrl = TextEditingController();
  String? _partId;
  String? _dispatchRefId;
  final _qtyCtrl = TextEditingController();
  final _challanCtrl = TextEditingController();
  final _remarksCtrl = TextEditingController();
  List<Map<String, dynamic>> _pendingDispatches = [];
  bool _isSaving = false;
  String? _error;
  String? _success;
  bool _lastShortage = false;
  DateTime _recordedAt = DateTime.now();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (mounted) setState(() {});
    });
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

  Future<void> _onPartChanged(String? partId) async {
    setState(() {
      _partId = partId;
      _dispatchRefId = null;
      _batchCtrl.clear();
      _pendingDispatches = [];
    });
    if (partId != null) {
      final dispatches = await ref
          .read(receiveFacoRepositoryProvider)
          .getPendingDispatches(partId);
      setState(() => _pendingDispatches = dispatches);
    }
  }

  void _onDispatchChanged(String? dispatchId) {
    if (dispatchId == null) return;
    final dispatch = _pendingDispatches.firstWhere(
      (item) => item['id'] == dispatchId,
    );
    setState(() {
      _dispatchRefId = dispatchId;
      _batchCtrl.text = dispatch['batch_number'] as String? ?? '';
    });
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _isSaving = true;
      _error = null;
      _success = null;
      _lastShortage = false;
    });

    try {
      final user = ref.read(currentUserProvider).value;
      final repo = ref.read(receiveFacoRepositoryProvider);
      final result = await repo.save(
        batchNumber: _batchCtrl.text.trim(),
        partId: _partId!,
        qtyReceived: double.parse(_qtyCtrl.text),
        dispatchRefId: _dispatchRefId,
        supplierChallan:
            _challanCtrl.text.trim().isEmpty ? null : _challanCtrl.text.trim(),
        remarks:
            _remarksCtrl.text.trim().isEmpty ? null : _remarksCtrl.text.trim(),
        createdBy: user?.id ?? 'unknown',
        recordedAt: _recordedAt,
      );

      if (result.success) {
        setState(() {
          _success = 'Receive from vendor saved!';
          _lastShortage = result.shortageFlag;
        });
        ref.invalidate(receiveFacoListProvider);
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
    _qtyCtrl.clear();
    _challanCtrl.clear();
    _remarksCtrl.clear();
    setState(() {
      _partId = null;
      _dispatchRefId = null;
      _pendingDispatches = [];
      _recordedAt = DateTime.now();
    });
  }

  Future<void> _pickHistoryDate(
    BuildContext context,
    WidgetRef ref,
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
      ref.read(receiveFacoHistoryDateFilterProvider.notifier).setDate(picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedDate = ref.watch(receiveFacoHistoryDateFilterProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Receive from Vendor'),
        actions: [
          if (_tabController.index == 1) ...[
            if (selectedDate != null)
              IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Clear Date Filter',
                onPressed: () {
                  ref
                      .read(receiveFacoHistoryDateFilterProvider.notifier)
                      .setDate(null);
                },
              ),
            Stack(
              alignment: Alignment.topRight,
              children: [
                IconButton(
                  icon: Icon(
                    selectedDate != null
                        ? Icons.calendar_month
                        : Icons.calendar_month_outlined,
                    color: selectedDate != null
                        ? theme.colorScheme.primary
                        : null,
                  ),
                  tooltip:
                      selectedDate != null ? 'Change Date' : 'Filter by Date',
                  onPressed: () =>
                      _pickHistoryDate(context, ref, selectedDate),
                ),
                if (selectedDate != null)
                  Positioned(
                    right: 8,
                    top: 8,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: Colors.green,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
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

            const SectionHeader('Select Vendor Dispatch'),

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
                onChanged: _onPartChanged,
                validator: (v) => v == null ? 'Part is required' : null,
              ),
            ),
            const SizedBox(height: 12),

            // A receipt must always be linked to the original Faco dispatch.
            if (_partId != null && _pendingDispatches.isEmpty) ...[
              const Text(
                'No pending vendor dispatch is available for this part.',
                style: TextStyle(color: Colors.orange),
              ),
              const SizedBox(height: 12),
            ],
            if (_pendingDispatches.isNotEmpty) ...[
              AppDropdown<String>(
                label: 'Vendor Dispatch',
                isRequired: true,
                prefixIcon: const Icon(Icons.link),
                value: _dispatchRefId,
                items: _pendingDispatches
                    .map(
                      (d) => DropdownMenuItem(
                        value: d['id'] as String,
                        child: Text(
                          '${d['batch_number']} | ${d['part_code']} - ${d['part_name']} | '
                          '${(d['remaining_qty'] as num).toInt()} PCS left | ${d['date']}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: _onDispatchChanged,
                validator: (value) => value == null
                    ? 'Select the vendor dispatch being received'
                    : null,
              ),
              const SizedBox(height: 12),
            ],

            if (_batchCtrl.text.isNotEmpty) ...[
              Text(
                'Original batch: ${_batchCtrl.text}',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
            ],

            const SectionHeader('Received Quantity'),

            if (_dispatchRefId != null && _pendingDispatches.isNotEmpty) ...[
              Builder(
                builder: (context) {
                  final selected = _pendingDispatches.firstWhere(
                    (d) => d['id'] == _dispatchRefId,
                    orElse: () => <String, dynamic>{},
                  );
                  final rem = (selected['remaining_qty'] as num?)?.toDouble();
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: LiveStockChip(
                      stock: rem,
                      stageName: 'Pending Vendor Return',
                    ),
                  );
                },
              ),
            ],

            NumberFormField(
              label: 'Qty Received (PCS)',
              controller: _qtyCtrl,
              allowDecimal: false,
              prefixIcon: const Icon(Icons.move_to_inbox_outlined),
              validator: (v) {
                if (v == null || v.isEmpty) return 'Required';
                final n = double.tryParse(v);
                if (n == null || n <= 0) return 'Quantity must be > 0';
                return null;
              },
            ),
            const SizedBox(height: 12),

            AppFormField(
              label: 'Supplier Challan (optional)',
              controller: _challanCtrl,
              prefixIcon: const Icon(Icons.receipt_outlined),
              suffixIcon: IconButton(
                icon: const Icon(Icons.qr_code_scanner_rounded),
                tooltip: 'Scan Vendor Challan Barcode',
                onPressed: () async {
                  final code = await BarcodeScannerView.scan(
                    context,
                    title: 'Scan Vendor Challan Code',
                  );
                  if (code != null && code.isNotEmpty) {
                    _challanCtrl.text = code;
                  }
                },
              ),
            ),
            const SizedBox(height: 12),

            AppFormField(
              label: 'Remarks (optional)',
              controller: _remarksCtrl,
              maxLines: 2,
              prefixIcon: const Icon(Icons.notes),
            ),

            if (_lastShortage) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                  border:
                      Border.all(color: Colors.orange.withValues(alpha: 0.4)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.warning_amber_outlined, color: Colors.orange),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Shortage detected — received qty is less than dispatched qty.',
                        style: TextStyle(color: Colors.orange),
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
    final listAsync = ref.watch(receiveFacoListProvider);
    final selectedDate = ref.watch(receiveFacoHistoryDateFilterProvider);
    final theme = Theme.of(context);
    final user = ref.watch(currentUserProvider).value;

    return Column(
      children: [
        if (selectedDate != null) _buildActiveDateBanner(selectedDate, theme),
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
                        Icons.move_to_inbox_outlined,
                        size: 48,
                        color: theme.colorScheme.onSurfaceVariant
                            .withValues(alpha: 0.4),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        selectedDate != null
                            ? 'No vendor receipts on ${DateFormat('EEEE, dd MMM yyyy').format(selectedDate)}.'
                            : 'No vendor receipts yet.',
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
                                  receiveFacoHistoryDateFilterProvider
                                      .notifier,
                                )
                                .setDate(null);
                          },
                          icon: const Icon(Icons.clear, size: 16),
                          label: const Text('Clear Date Filter'),
                        ),
                      ],
                    ],
                  ),
                );
              }

              // Calculate part-wise totals
              final partTotals = <String, double>{};
              for (final r in records) {
                final pName = (r['part_name'] as String? ??
                        r['part_code'] as String? ??
                        'Unknown')
                    .trim();
                final qty = (r['qty_received'] as num?)?.toDouble() ?? 0.0;
                partTotals[pName] = (partTotals[pName] ?? 0.0) + qty;
              }

              return Stack(
                children: [
                  ListView.separated(
                    padding: EdgeInsets.fromLTRB(
                      12,
                      12,
                      12,
                      selectedDate != null && partTotals.isNotEmpty ? 130 : 24,
                    ),
                    itemCount: records.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (context, i) => _buildReceiptHistoryCard(
                      context,
                      records[i],
                      theme,
                      user,
                    ),
                  ),
                  if (partTotals.isNotEmpty)
                    _buildDailyTotalSummaryBox(
                      partTotals,
                      selectedDate,
                      theme,
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildActiveDateBanner(DateTime selectedDate, ThemeData theme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.primary.withValues(alpha: 0.2),
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.calendar_month,
            size: 20,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  DateFormat('EEEE, dd MMMM yyyy').format(selectedDate),
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                Text(
                  'Filtered by selected receipt date',
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.edit_calendar_outlined, size: 20),
            tooltip: 'Change Date',
            onPressed: () => _pickHistoryDate(context, ref, selectedDate),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 20),
            tooltip: 'Clear Filter',
            onPressed: () {
              ref
                  .read(receiveFacoHistoryDateFilterProvider.notifier)
                  .setDate(null);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildReceiptHistoryCard(
    BuildContext context,
    Map<String, dynamic> r,
    ThemeData theme,
    dynamic user,
  ) {
    final batchNum = (r['batch_number'] as String? ?? '').trim();
    final partCode = (r['part_code'] as String? ?? '—').trim();
    final partName = (r['part_name'] as String? ?? '').trim();
    final vendorName = (r['vendor_name'] as String? ?? 'Vendor').trim();
    final supplierChallan = (r['supplier_challan'] as String?)?.trim();
    final remarks = (r['remarks'] as String?)?.trim();
    final dateStr = r['date'] as String? ?? '';
    final timeStr = formatTimeWithoutSeconds(r['time'] as String?);
    final qtyReceived = (r['qty_received'] as num?)?.toDouble() ?? 0.0;
    final dispatchedQty = (r['dispatched_qty'] as num?)?.toDouble();
    final isShortage = (r['shortage_flag'] as int?) == 1;
    final isSynced = r['sync_status'] == 'synced';

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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    batchNum.isNotEmpty ? batchNum : 'OPEN BATCH',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
                if (isShortage) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.orange.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: Colors.orange.withValues(alpha: 0.4),
                      ),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.warning_amber_rounded,
                          size: 12,
                          color: Colors.orange,
                        ),
                        SizedBox(width: 3),
                        Text(
                          'Shortage',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: Colors.orange,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const Spacer(),
                Icon(
                  isSynced ? Icons.cloud_done : Icons.cloud_upload_outlined,
                  size: 16,
                  color: isSynced ? Colors.green : Colors.orange,
                ),
                const SizedBox(width: 6),
                IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  tooltip: 'Edit Receipt',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () => _showEditReceiptModal(context, r),
                ),
                const SizedBox(width: 10),
                IconButton(
                  icon: const Icon(
                    Icons.delete_outline,
                    size: 18,
                    color: Colors.red,
                  ),
                  tooltip: 'Delete Receipt',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () => _confirmDeleteReceipt(context, r),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Part Info & Received Qty
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        partCode,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      if (partName.isNotEmpty)
                        Text(
                          partName,
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.purple.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: Colors.purple.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Text(
                    '+${qtyReceived == qtyReceived.toInt() ? qtyReceived.toInt() : qtyReceived} PCS',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                      color: Colors.purple,
                    ),
                  ),
                ),
              ],
            ),

            if (dispatchedQty != null) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.blueGrey.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      'Dispatched: ${dispatchedQty == dispatchedQty.toInt() ? dispatchedQty.toInt() : dispatchedQty} PCS',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Colors.blueGrey.shade800,
                      ),
                    ),
                  ),
                ],
              ),
            ],

            const SizedBox(height: 8),

            // Logistics chips
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _buildInfoBadge(
                  Icons.calendar_today_outlined,
                  formatDateTimeLabel(dateStr, timeStr),
                  Colors.grey,
                ),
                if (vendorName.isNotEmpty)
                  _buildInfoBadge(Icons.business, vendorName, Colors.teal),
                if (supplierChallan != null && supplierChallan.isNotEmpty)
                  _buildInfoBadge(
                    Icons.receipt_outlined,
                    'Ch: $supplierChallan',
                    Colors.blueGrey,
                  ),
              ],
            ),

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
          ],
        ),
      ),
    );
  }

  Widget _buildInfoBadge(IconData icon, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: color is MaterialColor ? color.shade800 : color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDailyTotalSummaryBox(
    Map<String, double> partTotals,
    DateTime? selectedDate,
    ThemeData theme,
  ) {
    final grandTotal = partTotals.values.fold(0.0, (sum, q) => sum + q);

    return Positioned(
      right: 12,
      bottom: 12,
      child: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(12),
        color: theme.colorScheme.surfaceContainerHigh,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 240),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: theme.colorScheme.primary.withValues(alpha: 0.3),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.summarize_outlined,
                    size: 14,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    selectedDate != null
                        ? 'Total (${DateFormat('dd MMM').format(selectedDate)})'
                        : 'Total Received',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ],
              ),
              const Divider(height: 8, thickness: 0.5),
              ...partTotals.entries.take(4).map(
                    (e) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1.5),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Text(
                              e.key,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '${e.value == e.value.toInt() ? e.value.toInt() : e.value} PCS',
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              if (partTotals.length > 4)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    '+${partTotals.length - 4} more parts',
                    style: TextStyle(
                      fontSize: 10,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Total Received:',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      '${grandTotal == grandTotal.toInt() ? grandTotal.toInt() : grandTotal} PCS',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showEditReceiptModal(BuildContext context, Map<String, dynamic> r) {
    final receiptId = r['id'] as String;
    final currentQty = (r['qty_received'] as num?)?.toDouble() ?? 0.0;
    final partCode = r['part_code'] as String? ?? '—';
    final partName = r['part_name'] as String? ?? '';
    final batchNum = r['batch_number'] as String? ?? '';
    final vendorName = r['vendor_name'] as String? ?? 'Vendor';

    final qtyCtrl = TextEditingController(
      text: currentQty == currentQty.toInt()
          ? currentQty.toInt().toString()
          : currentQty.toString(),
    );
    final challanCtrl = TextEditingController(
      text: r['supplier_challan'] as String? ?? '',
    );
    final remarksCtrl = TextEditingController(
      text: r['remarks'] as String? ?? '',
    );

    double newQty = currentQty;
    bool isSaving = false;
    String? modalError;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          final qtyDiff = newQty - currentQty;

          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
              left: 16,
              right: 16,
              top: 16,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Edit Vendor Receipt',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            '$partCode – $partName ($batchNum)',
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
                  const Divider(height: 20),

                  if (modalError != null) ...[
                    ErrorBanner(modalError!),
                    const SizedBox(height: 12),
                  ],

                  // Qty Input
                  TextFormField(
                    controller: qtyCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: 'Received Quantity (PCS) *',
                      prefixIcon: const Icon(Icons.numbers_outlined),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onChanged: (val) {
                      setModalState(() {
                        newQty = double.tryParse(val) ?? currentQty;
                      });
                    },
                  ),
                  const SizedBox(height: 8),

                  // Real-time Stock adjustment explanation preview
                  if (qtyDiff != 0)
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: (qtyDiff > 0 ? Colors.purple : Colors.orange)
                            .withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: (qtyDiff > 0 ? Colors.purple : Colors.orange)
                              .withValues(alpha: 0.3),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            qtyDiff > 0
                                ? '▲ Increasing receipt by +${qtyDiff.toInt()} PCS:'
                                : '▼ Decreasing receipt by ${qtyDiff.toInt()} PCS:',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                              color:
                                  qtyDiff > 0 ? Colors.purple : Colors.orange,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            qtyDiff > 0
                                ? '• Moves +${qtyDiff.toInt()} PCS from Vendor Stock ($vendorName) into Pending AP Stock'
                                : '• Returns ${(-qtyDiff).toInt()} PCS from Pending AP Stock back to Vendor Stock ($vendorName)',
                            style: const TextStyle(fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 12),

                  // Supplier Challan
                  TextFormField(
                    controller: challanCtrl,
                    decoration: InputDecoration(
                      labelText: 'Supplier Challan Number',
                      prefixIcon: const Icon(Icons.receipt_outlined),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Remarks
                  TextFormField(
                    controller: remarksCtrl,
                    maxLines: 2,
                    decoration: InputDecoration(
                      labelText: 'Remarks',
                      prefixIcon: const Icon(Icons.notes_outlined),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.purple,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: isSaving
                        ? null
                        : () async {
                            final parsedQty = double.tryParse(qtyCtrl.text);
                            if (parsedQty == null || parsedQty <= 0) {
                              setModalState(() {
                                modalError =
                                    'Enter a valid quantity greater than zero.';
                              });
                              return;
                            }

                            setModalState(() {
                              isSaving = true;
                              modalError = null;
                            });

                            final user = ref.read(currentUserProvider).value;
                            final repo =
                                ref.read(receiveFacoRepositoryProvider);
                            final res = await repo.updateReceiptRecord(
                              receiptId: receiptId,
                              newQty: parsedQty,
                              supplierChallan: challanCtrl.text,
                              remarks: remarksCtrl.text,
                              userId: user?.id ?? 'unknown',
                            );

                            if (!ctx.mounted) return;

                            if (!res.success) {
                              setModalState(() {
                                isSaving = false;
                                modalError = res.error;
                              });
                            } else {
                              Navigator.pop(ctx);
                              ref.invalidate(receiveFacoListProvider);
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Vendor receipt updated & stock adjusted successfully.',
                                    ),
                                    backgroundColor: Colors.green,
                                  ),
                                );
                              }
                            }
                          },
                    icon: isSaving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.check),
                    label: Text(isSaving ? 'Updating...' : 'Save Changes'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _confirmDeleteReceipt(
    BuildContext context,
    Map<String, dynamic> r,
  ) async {
    final receiptId = r['id'] as String;
    final qty = (r['qty_received'] as num?)?.toDouble() ?? 0.0;
    final partCode = r['part_code'] as String? ?? '—';
    final partName = r['part_name'] as String? ?? '';
    final batchNum = r['batch_number'] as String? ?? '';
    final vendorName = r['vendor_name'] as String? ?? 'Vendor';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Vendor Receipt?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Are you sure you want to delete this receipt for $partCode?'),
            const SizedBox(height: 8),
            Text(
              'Batch: $batchNum\nPart: $partName\nQuantity: ${qty.toInt()} PCS\nVendor: $vendorName',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            const Text(
              'Deleting this receipt will automatically revert stock:',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
            ),
            const SizedBox(height: 6),
            Text(
              '• Deduct ${qty.toInt()} PCS from Pending AP Stock',
              style: const TextStyle(
                color: Colors.red,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              '• Return ${qty.toInt()} PCS back into Vendor Stock (At Faco)',
              style: const TextStyle(
                color: Colors.green,
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
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.delete, size: 16),
            label: const Text('Delete & Revert Stock'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final user = ref.read(currentUserProvider).value;
    final repo = ref.read(receiveFacoRepositoryProvider);
    final res = await repo.deleteReceiptRecord(
      receiptId: receiptId,
      userId: user?.id ?? 'unknown',
    );

    if (!context.mounted) return;

    if (!res.success) {
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Cannot Delete Receipt'),
          content: Text(res.error),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } else {
      ref.invalidate(receiveFacoListProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Vendor receipt deleted and stock reversed to Vendor Stock.',
          ),
          backgroundColor: Colors.green,
        ),
      );
    }
  }
}
