import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/master_data_providers.dart';
import '../../core/providers/stock_invalidation_helper.dart';
import '../../core/widgets/barcode_scanner_view.dart';
import '../../core/widgets/defect_photo_picker.dart';
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
  final _remarksCtrl = TextEditingController();
  bool _isSaving = false;
  String? _error;
  String? _success;
  DateTime _recordedAt = DateTime.now();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _batchCtrl.dispose();
    _holdQtyCtrl.dispose();
    _rejectQtyCtrl.dispose();
    _remarksCtrl.dispose();
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
      final okQty = holdQty - rejectQty;

      final result = await repo.save(
        batchNumber: batchVal,
        partId: _partId!,
        machineId: _machineId!,
        inspectedQty: holdQty,
        bpRejectQty: rejectQty,
        rejectReason: rejectQty > 0 ? _rejectReason : null,
        inspectorId: user?.id ?? 'unknown',
        remarks: _remarksCtrl.text.trim().isNotEmpty
            ? _remarksCtrl.text.trim()
            : null,
        recordedAt: _recordedAt,
      );

      if (result.success) {
        HapticFeedback.lightImpact();
        refreshAllStockAndEntryProviders(ref);
        setState(
          () => _success = 'BP Inspection saved! $holdQty PCS inspected: '
              '${okQty.toInt()} PCS OK (in Own BP Stock)'
              '${rejectQty > 0 ? ', ${rejectQty.toInt()} PCS Rejected' : ''}.',
        );
        ref.invalidate(bpInspectionListProvider);
        ref.invalidate(bpHoldStockProvider);
        ref.invalidate(bpRejectedStockProvider);
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
    _remarksCtrl.clear();
    setState(() {
      _partId = null;
      _machineId = null;
      _rejectReason = null;
      _recordedAt = DateTime.now();
    });
  }

  @override
  Widget build(BuildContext context) {
    final holdStockAsync = ref.watch(bpHoldStockProvider);
    final rejectStockAsync = ref.watch(bpRejectedStockProvider);

    final holdCount = holdStockAsync.value?.length ?? 0;
    final rejectCount = rejectStockAsync.value?.length ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('BP Quality & Hold Management'),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            const Tab(
              icon: Icon(Icons.fact_check_outlined, size: 20),
              text: 'New Inspection',
            ),
            Tab(
              icon: Badge(
                isLabelVisible: holdCount > 0,
                label: Text('$holdCount'),
                backgroundColor: Colors.amber.shade800,
                child: const Icon(Icons.pause_circle_outline, size: 20),
              ),
              text: 'Active Holds',
            ),
            Tab(
              icon: Badge(
                isLabelVisible: rejectCount > 0,
                label: Text('$rejectCount'),
                backgroundColor: Colors.red.shade700,
                child: const Icon(Icons.cancel_outlined, size: 20),
              ),
              text: 'Rejected Stock',
            ),
            const Tab(
              icon: Icon(Icons.history_rounded, size: 20),
              text: 'Audit History',
            ),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildForm(),
          const _ActiveBpHoldTab(),
          const _BpRejectedStockTab(),
          const _BpInspectionHistoryTab(),
        ],
      ),
    );
  }

  Widget _buildForm() {
    final rejectReasons = ref.watch(bpRejectReasonsListProvider);
    final parts = ref.watch(partsProvider);
    final machines = ref.watch(machinesProvider);
    final batches = ref.watch(recentBatchesProvider);
    final theme = Theme.of(context);

    final holdQty = double.tryParse(_holdQtyCtrl.text) ?? 0;
    final rejectQty = double.tryParse(_rejectQtyCtrl.text) ?? 0;
    final okQty = (holdQty - rejectQty).clamp(0, double.infinity);

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
            const SectionHeader('Production Batch & Part'),
            batches.when(
              loading: () => const LinearProgressIndicator(),
              error: (error, _) =>
                  ErrorBanner('Could not load production batches: $error'),
              data: (list) => Row(
                children: [
                  Expanded(
                    child: AppDropdown<String>(
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
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    tooltip: 'Scan Batch QR',
                    icon: const Icon(Icons.qr_code_scanner_rounded),
                    onPressed: () async {
                      final scanned = await BarcodeScannerView.scan(
                        context,
                        title: 'Scan Batch Code',
                      );
                      if (scanned != null && scanned.isNotEmpty) {
                        final match = list.firstWhere(
                          (b) =>
                              (b['batch_number'] as String).toLowerCase() ==
                              scanned.toLowerCase(),
                          orElse: () => <String, dynamic>{},
                        );
                        if (match.isNotEmpty) {
                          setState(() {
                            _batchCtrl.text = match['batch_number'] as String;
                            _partId = match['part_id'] as String?;
                            _machineId = match['machine_id'] as String?;
                          });
                        }
                      }
                    },
                  ),
                ],
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
            const SizedBox(height: 16),
            const SectionHeader('Inspection & Clearance Quantities'),
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                'Enter total pieces checked. OK pieces remain in Own BP Stock for Vendor Dispatch. Rejects move to BP Rejected.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
            NumberFormField(
              label: 'Total Inspected / Hold Qty (PCS)',
              controller: _holdQtyCtrl,
              allowDecimal: false,
              prefixIcon: const Icon(Icons.fact_check_outlined),
              onChanged: (_) => setState(() {}),
              validator: (v) {
                if (v == null || v.isEmpty) return 'Required';
                final n = double.tryParse(v);
                if (n == null || n <= 0) return 'Inspected qty must be > 0';
                return null;
              },
            ),
            const SizedBox(height: 6),
            QuantityStepper(
              controller: _holdQtyCtrl,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            NumberFormField(
              label: 'Reject Qty (PCS)',
              controller: _rejectQtyCtrl,
              allowDecimal: false,
              prefixIcon: const Icon(Icons.cancel_outlined, color: Colors.red),
              onChanged: (_) => setState(() {}),
              validator: (v) {
                if (v == null || v.isEmpty) return 'Required';
                final n = double.tryParse(v);
                if (n == null || n < 0) return 'Enter valid quantity';
                final hold = double.tryParse(_holdQtyCtrl.text) ?? 0;
                if (n > hold) return 'Reject cannot exceed inspected qty';
                return null;
              },
            ),
            const SizedBox(height: 6),
            QuantityStepper(
              controller: _rejectQtyCtrl,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            if (holdQty > 0)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.check_circle, color: Colors.green, size: 16),
                              const SizedBox(width: 4),
                              Text('OK (Dispatch Ready)', style: theme.textTheme.labelMedium),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${okQty.toInt()} PCS',
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Colors.green,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(width: 1, height: 40, color: theme.colorScheme.outlineVariant),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.cancel, color: Colors.red, size: 16),
                              const SizedBox(width: 4),
                              Text('Rejected', style: theme.textTheme.labelMedium),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${rejectQty.toInt()} PCS',
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Colors.red,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
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
            const SizedBox(height: 12),
            TextFormField(
              controller: _remarksCtrl,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Inspection Remarks / Notes',
                prefixIcon: Icon(Icons.notes_rounded),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(12)),
                ),
              ),
            ),
            const SizedBox(height: 14),
            DefectPhotoPicker(
              label: 'BP Defect Evidence Photo',
              hint: 'Attach photo of surface finish, dimension, or crack issue',
              onPhotoChanged: (photoPath) {},
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
}

/// ─── TAB 2: ACTIVE BP QC HOLDS ─────────────────────────────────────────────
class _ActiveBpHoldTab extends ConsumerWidget {
  const _ActiveBpHoldTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final holdStockAsync = ref.watch(bpHoldStockProvider);
    final theme = Theme.of(context);

    return holdStockAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => EmptyState(message: 'Error loading holds: $e', icon: Icons.error_outline),
      data: (items) {
        if (items.isEmpty) {
          return const EmptyState(
            message: 'No material currently on BP QC Hold.\nAll cleared BP stock is in Own BP Stock.',
            icon: Icons.check_circle_outline,
          );
        }

        final totalHold = items.fold<double>(
          0.0,
          (sum, item) => sum + ((item['hold_qty'] as num?)?.toDouble() ?? 0.0),
        );

        return Column(
          children: [
            Container(
              margin: const EdgeInsets.all(12),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.amber.shade900, Colors.amber.shade700],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.amber.shade900.withValues(alpha: 0.3),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                children: [
                  const CircleAvatar(
                    backgroundColor: Colors.white24,
                    child: Icon(Icons.pause_circle_filled, color: Colors.white),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Total BP Quarantine / Hold Stock',
                          style: TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${totalHold.toInt()} PCS Across ${items.length} Parts',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                itemCount: items.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final item = items[index];
                  final qty = (item['hold_qty'] as num).toDouble();
                  final partName = item['part_name'] as String? ?? '';
                  final partCode = item['part_code'] as String? ?? '';
                  final reason = item['reason'] as String? ?? 'Quality hold';
                  final holdDate = item['hold_date'] as String? ?? '';
                  final batchNumber = item['batch_number'] as String? ?? 'OPEN-$partCode';

                  return Card(
                    elevation: 1,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                      side: BorderSide(color: theme.colorScheme.outlineVariant),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              CircleAvatar(
                                backgroundColor: Colors.amber.withValues(alpha: 0.15),
                                child: const Icon(Icons.hourglass_top_rounded, color: Colors.amber, size: 20),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '$partCode – $partName',
                                      style: const TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      'Batch: $batchNumber',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: theme.colorScheme.onSurfaceVariant,
                                        fontFamily: 'monospace',
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.amber.shade900.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: Colors.amber.shade700),
                                ),
                                child: Text(
                                  '${qty.toInt()} PCS',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.amber.shade900,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.info_outline, size: 14, color: Colors.grey),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    reason,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (holdDate.isNotEmpty)
                                  Text(
                                    holdDate.length >= 10 ? holdDate.substring(0, 10) : holdDate,
                                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: Colors.teal.shade700,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                              icon: const Icon(Icons.verified_outlined, size: 18),
                              label: const Text('Quality Check & Release Stock'),
                              onPressed: () => _showReleaseDialog(context, ref, item),
                            ),
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

  Future<void> _showReleaseDialog(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic> item,
  ) async {
    final partId = item['part_id'] as String;
    final partCode = item['part_code'] as String? ?? '';
    final partName = item['part_name'] as String? ?? '';
    final totalHoldQty = (item['hold_qty'] as num).toDouble();
    final batchNumber = item['batch_number'] as String? ?? 'OPEN-$partCode';

    final inspectQtyCtrl = TextEditingController(text: '${totalHoldQty.toInt()}');
    final okQtyCtrl = TextEditingController(text: '${totalHoldQty.toInt()}');
    final rejectQtyCtrl = TextEditingController(text: '0');
    final remarksCtrl = TextEditingController();
    String? rejectReason;
    String? localError;
    bool isSubmitting = false;

    final rejectReasons = await ref.read(bpRejectReasonsProvider.future);
    final reasonsList = rejectReasons.isNotEmpty
        ? rejectReasons.map((r) => r['reason'] as String).toList()
        : kBpRejectReasonsFallback;

    if (!context.mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (ctx, setS) {
          final inspectVal = double.tryParse(inspectQtyCtrl.text) ?? 0;
          final okVal = double.tryParse(okQtyCtrl.text) ?? 0;
          final rejectVal = double.tryParse(rejectQtyCtrl.text) ?? 0;

          return Padding(
            padding: EdgeInsets.only(
              left: 20,
              right: 20,
              top: 20,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const CircleAvatar(
                        backgroundColor: Colors.teal,
                        child: Icon(Icons.rule_folder_outlined, color: Colors.white),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Quality Clearance — $partCode',
                              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                            ),
                            Text(
                              partName,
                              style: TextStyle(
                                fontSize: 13,
                                color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(sheetContext),
                      ),
                    ],
                  ),
                  const Divider(height: 24),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.amber.shade900.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.amber.shade700.withValues(alpha: 0.4)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Total Current Hold Stock:'),
                        Text(
                          '${totalHoldQty.toInt()} PCS',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: inspectQtyCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Total Quantity Inspected (PCS) *',
                      prefixIcon: Icon(Icons.fact_check_outlined),
                      border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
                    ),
                    onChanged: (v) {
                      final n = double.tryParse(v) ?? 0;
                      setS(() {
                        okQtyCtrl.text = '${n.toInt()}';
                        rejectQtyCtrl.text = '0';
                      });
                    },
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: okQtyCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'OK Quantity (PCS) *',
                            prefixIcon: Icon(Icons.check_circle_outline, color: Colors.green),
                            border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
                          ),
                          onChanged: (v) {
                            final ok = double.tryParse(v) ?? 0;
                            final total = double.tryParse(inspectQtyCtrl.text) ?? 0;
                            final rej = (total - ok).clamp(0, total);
                            setS(() => rejectQtyCtrl.text = '${rej.toInt()}');
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextFormField(
                          controller: rejectQtyCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Reject Qty (PCS)',
                            prefixIcon: Icon(Icons.cancel_outlined, color: Colors.red),
                            border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
                          ),
                          onChanged: (v) {
                            final rej = double.tryParse(v) ?? 0;
                            final total = double.tryParse(inspectQtyCtrl.text) ?? 0;
                            final ok = (total - rej).clamp(0, total);
                            setS(() => okQtyCtrl.text = '${ok.toInt()}');
                          },
                        ),
                      ),
                    ],
                  ),
                  if (rejectVal > 0) ...[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: rejectReason,
                      decoration: const InputDecoration(
                        labelText: 'Reject Reason *',
                        prefixIcon: Icon(Icons.warning_amber_rounded, color: Colors.red),
                        border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
                      ),
                      items: reasonsList
                          .map((r) => DropdownMenuItem(value: r, child: Text(r)))
                          .toList(),
                      onChanged: (v) => setS(() => rejectReason = v),
                    ),
                  ],
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: remarksCtrl,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Quality Inspector Remarks / Notes',
                      prefixIcon: Icon(Icons.comment_outlined),
                      border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(ctx).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.arrow_forward_rounded, size: 16, color: Colors.green),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                'OK: ${okVal.toInt()} PCS will move to Own BP Stock (Ready for Dispatch)',
                                style: const TextStyle(fontSize: 12, color: Colors.green, fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                        ),
                        if (rejectVal > 0) ...[
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              const Icon(Icons.arrow_forward_rounded, size: 16, color: Colors.red),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  'Reject: ${rejectVal.toInt()} PCS will move to BP Rejected Stock',
                                  style: const TextStyle(fontSize: 12, color: Colors.red, fontWeight: FontWeight.w600),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (localError != null) ...[
                    const SizedBox(height: 10),
                    ErrorBanner(localError!),
                  ],
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: isSubmitting
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                        : const Icon(Icons.check_circle_outline),
                    label: Text(
                      isSubmitting ? 'Posting Quality Clearance...' : 'Confirm Quality Clearance',
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                    ),
                    onPressed: isSubmitting
                        ? null
                        : () async {
                            if (inspectVal <= 0 || inspectVal > totalHoldQty) {
                              setS(() => localError = 'Inspected quantity must be between 1 and ${totalHoldQty.toInt()} PCS.');
                              return;
                            }
                            if ((okVal + rejectVal - inspectVal).abs() > 0.001) {
                              setS(() => localError = 'OK Qty ($okVal) + Reject Qty ($rejectVal) must equal Inspected Qty ($inspectVal).');
                              return;
                            }
                            if (rejectVal > 0 && (rejectReason == null || rejectReason!.trim().isEmpty)) {
                              setS(() => localError = 'Please select a reject reason for the rejected pieces.');
                              return;
                            }

                            setS(() {
                              isSubmitting = true;
                              localError = null;
                            });

                            final user = ref.read(currentUserProvider).value;
                            final result = await ref.read(bpInspectionRepositoryProvider).releaseBpHold(
                                  partId: partId,
                                  batchNumber: batchNumber,
                                  totalQty: inspectVal,
                                  okQty: okVal,
                                  rejectQty: rejectVal,
                                  rejectReason: rejectReason,
                                  inspectorId: user?.id ?? 'Quality Inspector',
                                  remarks: remarksCtrl.text.trim(),
                                );

                            if (!ctx.mounted) return;
                            if (result.success) {
                              HapticFeedback.mediumImpact();
                              refreshAllStockAndEntryProviders(ref);
                              ref.invalidate(bpHoldStockProvider);
                              ref.invalidate(bpInspectionListProvider);
                              ref.invalidate(bpRejectedStockProvider);
                              Navigator.pop(sheetContext);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  backgroundColor: Colors.teal.shade800,
                                  content: Text(
                                    'Quality Clearance posted! ${okVal.toInt()} PCS released to Own BP Stock'
                                    '${rejectVal > 0 ? ', ${rejectVal.toInt()} PCS rejected' : ''}.',
                                  ),
                                ),
                              );
                            } else {
                              setS(() {
                                isSubmitting = false;
                                localError = result.error ?? 'Unable to post clearance.';
                              });
                            }
                          },
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// ─── TAB 3: BP REJECTED STOCK TAB ──────────────────────────────────────────
class _BpRejectedStockTab extends ConsumerWidget {
  const _BpRejectedStockTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stock = ref.watch(bpRejectedStockProvider);
    final theme = Theme.of(context);

    return stock.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => EmptyState(message: 'Error: $error', icon: Icons.error_outline),
      data: (items) {
        if (items.isEmpty) {
          return const EmptyState(
            message: 'No BP rejected stock in quarantine.\nAll rejected items are scrapped and written off.',
            icon: Icons.check_circle_outline,
          );
        }

        final totalReject = items.fold<double>(
          0.0,
          (sum, item) => sum + ((item['qty'] as num?)?.toDouble() ?? 0.0),
        );

        return Column(
          children: [
            Container(
              margin: const EdgeInsets.all(12),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.red.shade900, Colors.red.shade700],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.red.shade900.withValues(alpha: 0.3),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                children: [
                  const CircleAvatar(
                    backgroundColor: Colors.white24,
                    child: Icon(Icons.delete_outline, color: Colors.white),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Total BP Rejected Material Awaiting Scrap',
                          style: TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${totalReject.toInt()} PCS Across ${items.length} Parts',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                itemCount: items.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final item = items[index];
                  final qty = (item['qty'] as num).toDouble();
                  final partCode = item['part_code'] as String? ?? '';
                  final partName = item['part_name'] as String? ?? '';
                  final batchNumber = item['batch_number'] as String? ?? 'OPEN-$partCode';
                  final reason = item['reason'] as String? ?? 'Quality rejection';
                  final rejectDate = item['reject_date'] as String? ?? '';

                  return Card(
                    elevation: 1,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                      side: BorderSide(color: theme.colorScheme.outlineVariant),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              CircleAvatar(
                                backgroundColor: Colors.red.withValues(alpha: 0.15),
                                child: const Icon(Icons.cancel_outlined, color: Colors.red, size: 20),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '$partCode – $partName',
                                      style: const TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      'Batch: $batchNumber',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: theme.colorScheme.onSurfaceVariant,
                                        fontFamily: 'monospace',
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.red.shade900.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: Colors.red.shade400),
                                ),
                                child: Text(
                                  '${qty.toInt()} PCS',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.red.shade800,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.info_outline, size: 14, color: Colors.grey),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    reason,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (rejectDate.isNotEmpty)
                                  Text(
                                    rejectDate.length >= 10 ? rejectDate.substring(0, 10) : rejectDate,
                                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: Colors.red.shade800,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                              icon: const Icon(Icons.delete_forever_outlined, size: 18),
                              label: Text('Finalize Scrap & Write-Off (${qty.toInt()} PCS)'),
                              onPressed: () => _confirm(context, ref, item, qty),
                            ),
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

  Future<void> _confirm(BuildContext context, WidgetRef ref, Map<String, dynamic> item, double qty) async {
    final note = TextEditingController();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Confirm Final BP Scrap Write-Off'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${qty.toInt()} PCS of ${item['part_code']} will be permanently written off from BP rejected physical stock.',
              style: const TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 8),
            const Text(
              'The historical record will be preserved in the database for monthly/yearly audit reports.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: note,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Scrap Reason / Disposal Note *',
                hintText: 'e.g. Sold as scrap, melted, discarded',
                border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade800),
            onPressed: () => Navigator.pop(dialogContext, note.text.trim().isNotEmpty),
            child: const Text('Confirm Scrap Write-Off'),
          ),
        ],
      ),
    );
    if (accepted != true) {
      note.dispose();
      return;
    }
    final user = ref.read(currentUserProvider).value;
    final result = await ref.read(bpInspectionRepositoryProvider).finalizeRejected(
          partId: item['part_id'] as String,
          batchNumber: item['batch_number'] as String? ?? 'OPEN-${item['part_code']}',
          qty: qty,
          createdBy: user?.id ?? 'unknown',
          remarks: note.text,
        );
    note.dispose();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: result.success ? Colors.green.shade800 : Colors.red.shade800,
        content: Text(
          result.success ? 'BP rejected stock permanently scrapped and removed from active inventory.' : (result.error ?? 'Unable to finalize scrap.'),
        ),
      ),
    );
    if (result.success) {
      refreshAllStockAndEntryProviders(ref);
      ref.invalidate(bpRejectedStockProvider);
    }
  }
}

/// ─── TAB 4: BP INSPECTION & HOLD AUDIT HISTORY ─────────────────────────────
class _BpInspectionHistoryTab extends ConsumerStatefulWidget {
  const _BpInspectionHistoryTab();

  @override
  ConsumerState<_BpInspectionHistoryTab> createState() =>
      _BpInspectionHistoryTabState();
}

class _BpInspectionHistoryTabState
    extends ConsumerState<_BpInspectionHistoryTab> {
  String _selectedFilter = 'all'; // 'all', 'inspection', 'hold_release', 'scrap_writeoff', 'stock_adjustment'
  String _searchQuery = '';
  final _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final listAsync = ref.watch(bpInspectionListProvider);
    final theme = Theme.of(context);

    return listAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => EmptyState(
        message: 'Error loading audit history: $e',
        icon: Icons.error_outline,
      ),
      data: (allRecords) {
        if (allRecords.isEmpty) {
          return const EmptyState(
            message:
                'No BP quality inspections, hold releases, or scrap events recorded yet.',
            icon: Icons.fact_check_outlined,
          );
        }

        // Apply filters
        final filtered = allRecords.where((r) {
          final eventType = r['event_type'] as String? ?? 'inspection';
          if (_selectedFilter != 'all' && eventType != _selectedFilter) {
            return false;
          }

          if (_searchQuery.isNotEmpty) {
            final q = _searchQuery.toLowerCase();
            final partName = (r['part_name'] as String? ?? '').toLowerCase();
            final partCode = (r['part_code'] as String? ?? '').toLowerCase();
            final batch = (r['batch_number'] as String? ?? '').toLowerCase();
            final inspector =
                (r['inspector_name'] as String? ?? '').toLowerCase();
            final reason =
                (r['reject_reason_name'] as String? ?? '').toLowerCase();
            final remarks = (r['remarks'] as String? ?? '').toLowerCase();

            return partName.contains(q) ||
                partCode.contains(q) ||
                batch.contains(q) ||
                inspector.contains(q) ||
                reason.contains(q) ||
                remarks.contains(q);
          }
          return true;
        }).toList();

        // Calculate KPI metrics
        final totalInspected = allRecords.fold<double>(
          0.0,
          (s, r) => s + ((r['inspected_qty'] as num?)?.toDouble() ?? 0.0),
        );
        final totalRejected = allRecords.fold<double>(
          0.0,
          (s, r) => s + ((r['bp_reject_qty'] as num?)?.toDouble() ?? 0.0),
        );
        final totalOk = (totalInspected - totalRejected).clamp(0, double.infinity);

        return Column(
          children: [
            // KPI Summary Header
            Container(
              margin: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildKpiItem(
                    label: 'Total Processed',
                    value: '${totalInspected.toInt()}',
                    color: Colors.blue.shade700,
                  ),
                  Container(width: 1, height: 30, color: theme.colorScheme.outlineVariant),
                  _buildKpiItem(
                    label: 'OK Released (BP)',
                    value: '${totalOk.toInt()}',
                    color: Colors.green.shade700,
                  ),
                  Container(width: 1, height: 30, color: theme.colorScheme.outlineVariant),
                  _buildKpiItem(
                    label: 'Rejected / Scrap',
                    value: '${totalRejected.toInt()}',
                    color: Colors.red.shade700,
                  ),
                ],
              ),
            ),

            // Search Bar & Filters
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: TextField(
                controller: _searchCtrl,
                decoration: InputDecoration(
                  hintText: 'Search part, batch, reason, or inspector...',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() => _searchQuery = '');
                          },
                        )
                      : null,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  isDense: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onChanged: (val) => setState(() => _searchQuery = val.trim()),
              ),
            ),
            const SizedBox(height: 8),

            // Filter Chips
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  _filterChip(label: 'All Activities (${allRecords.length})', value: 'all'),
                  const SizedBox(width: 6),
                  _filterChip(label: 'Quality Checks', value: 'inspection'),
                  const SizedBox(width: 6),
                  _filterChip(label: 'Hold Clearances', value: 'hold_release'),
                  const SizedBox(width: 6),
                  _filterChip(label: 'Scrap Write-Offs', value: 'scrap_writeoff'),
                  const SizedBox(width: 6),
                  _filterChip(label: 'Manual Adjustments', value: 'stock_adjustment'),
                ],
              ),
            ),
            const SizedBox(height: 6),

            // List of Records
            Expanded(
              child: filtered.isEmpty
                  ? const Center(
                      child: Text(
                        'No audit records match your search/filter.',
                        style: TextStyle(color: Colors.grey),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, i) {
                        final r = filtered[i];
                        return _buildAuditCard(context, r, theme);
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildKpiItem({
    required String label,
    required String value,
    required Color color,
  }) {
    return Column(
      children: [
        Text(
          value,
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color),
        ),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ],
    );
  }

  Widget _filterChip({required String label, required String value}) {
    final isSelected = _selectedFilter == value;
    return FilterChip(
      selected: isSelected,
      label: Text(label, style: TextStyle(fontSize: 12, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
      onSelected: (_) => setState(() => _selectedFilter = value),
      showCheckmark: false,
    );
  }

  Widget _buildAuditCard(
    BuildContext context,
    Map<String, dynamic> r,
    ThemeData theme,
  ) {
    final eventType = r['event_type'] as String? ?? 'inspection';
    final isSynced = r['sync_status'] == 'synced';
    final inspectedQty = (r['inspected_qty'] as num?)?.toDouble() ?? 0.0;
    final rejectQty = (r['bp_reject_qty'] as num?)?.toDouble() ?? 0.0;
    final okQty = (inspectedQty - rejectQty).clamp(0, double.infinity);
    final partCode = r['part_code'] as String? ?? '—';
    final partName = r['part_name'] as String? ?? '';
    final batchNumber = r['batch_number'] as String? ?? '—';
    final machineName = r['machine_name'] as String?;
    final inspectorName = r['inspector_name'] as String? ?? 'QC Inspector';
    final rejectReason = r['reject_reason_name'] as String? ?? r['reject_reason_id'] as String?;
    final remarks = r['remarks'] as String?;
    final date = r['date'] as String? ?? '';

    // Color and title based on event type
    Color eventColor;
    String eventLabel;
    IconData eventIcon;

    switch (eventType) {
      case 'hold_release':
        eventColor = Colors.teal;
        eventLabel = 'Hold Clearance';
        eventIcon = Icons.verified_outlined;
        break;
      case 'scrap_writeoff':
        eventColor = Colors.red.shade700;
        eventLabel = 'Scrap Write-Off';
        eventIcon = Icons.delete_forever_outlined;
        break;
      case 'stock_adjustment':
        eventColor = Colors.amber.shade800;
        eventLabel = 'Stock Placement';
        eventIcon = Icons.tune;
        break;
      default:
        eventColor = Colors.blue.shade700;
        eventLabel = 'Quality Check';
        eventIcon = Icons.fact_check_outlined;
    }

    return Card(
      elevation: 0.5,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _showRecordDetails(context, r),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    backgroundColor: eventColor.withValues(alpha: 0.15),
                    child: Icon(eventIcon, color: eventColor, size: 20),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              '$partCode – $partName',
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                            ),
                            const Spacer(),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                color: eventColor.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                eventLabel,
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: eventColor,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Batch: $batchNumber${machineName != null ? ' • $machineName' : ''}',
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.onSurfaceVariant,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const Divider(height: 16),
              Row(
                children: [
                  if (eventType == 'scrap_writeoff') ...[
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.red.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        'Scrapped: ${inspectedQty.toInt()} PCS',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.red),
                      ),
                    ),
                  ] else ...[
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.blue.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        'Checked: ${inspectedQty.toInt()} PCS',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.blue),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.green.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        'OK: ${okQty.toInt()} PCS',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.green),
                      ),
                    ),
                    if (rejectQty > 0) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.red.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          'Rej: ${rejectQty.toInt()} PCS',
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.red),
                        ),
                      ),
                    ],
                  ],
                  const Spacer(),
                  Text(
                    date,
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    isSynced ? Icons.cloud_done : Icons.cloud_upload_outlined,
                    size: 14,
                    color: isSynced ? Colors.green : Colors.orange,
                  ),
                ],
              ),
              if (rejectReason != null || (remarks != null && remarks.isNotEmpty)) ...[
                const SizedBox(height: 8),
                Text(
                  '${rejectReason != null ? '$rejectReason: ' : ''}${remarks ?? ''}',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurfaceVariant,
                    fontStyle: FontStyle.italic,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const SizedBox(height: 4),
              Row(
                children: [
                  const Icon(Icons.person_outline, size: 13, color: Colors.grey),
                  const SizedBox(width: 4),
                  Text(
                    inspectorName,
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                  const Spacer(),
                  const Text(
                    'Details →',
                    style: TextStyle(fontSize: 11, color: Colors.teal, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showRecordDetails(BuildContext context, Map<String, dynamic> r) {
    final eventType = r['event_type'] as String? ?? 'inspection';
    final inspectedQty = (r['inspected_qty'] as num?)?.toDouble() ?? 0.0;
    final rejectQty = (r['bp_reject_qty'] as num?)?.toDouble() ?? 0.0;
    final okQty = (inspectedQty - rejectQty).clamp(0, double.infinity);
    final partCode = r['part_code'] as String? ?? '—';
    final partName = r['part_name'] as String? ?? '';
    final batchNumber = r['batch_number'] as String? ?? '—';
    final machineName = r['machine_name'] as String?;
    final inspectorName = r['inspector_name'] as String? ?? 'QC Inspector';
    final rejectReason = r['reject_reason_name'] as String? ?? r['reject_reason_id'] as String?;
    final remarks = r['remarks'] as String?;
    final date = r['date'] as String? ?? '';
    final syncStatus = r['sync_status'] as String? ?? 'synced';

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const CircleAvatar(
                  backgroundColor: Colors.teal,
                  child: Icon(Icons.history_edu_outlined, color: Colors.white),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Audit Details — $partCode',
                        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                      ),
                      Text(
                        partName,
                        style: TextStyle(fontSize: 13, color: Theme.of(ctx).colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
              ],
            ),
            const Divider(height: 24),
            _detailRow('Date', date),
            _detailRow('Event Type', eventType.toUpperCase().replaceAll('_', ' ')),
            _detailRow('Batch Number', batchNumber),
            if (machineName != null) _detailRow('Machine', machineName),
            _detailRow('Inspector / Handled By', inspectorName),
            _detailRow('Total Inspected / Handled', '${inspectedQty.toInt()} PCS'),
            if (eventType != 'scrap_writeoff') ...[
              _detailRow('OK Released (BP Stock)', '${okQty.toInt()} PCS', valueColor: Colors.green),
              _detailRow('Rejected Quantity', '${rejectQty.toInt()} PCS', valueColor: rejectQty > 0 ? Colors.red : null),
            ],
            if (rejectReason != null) _detailRow('Reason / Classification', rejectReason),
            if (remarks != null && remarks.isNotEmpty) _detailRow('Remarks / Notes', remarks),
            _detailRow('Sync Status', syncStatus.toUpperCase(), valueColor: syncStatus == 'synced' ? Colors.green : Colors.orange),
            const SizedBox(height: 20),
            FilledButton.tonal(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close Details'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _detailRow(String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Text(label, style: const TextStyle(fontSize: 13, color: Colors.grey)),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: valueColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

