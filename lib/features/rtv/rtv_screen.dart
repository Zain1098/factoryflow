import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/providers/master_data_providers.dart';
import '../../core/widgets/shared_widgets.dart';
import '../auth/auth_providers.dart';
import '../ap_inspection/ap_inspection_providers.dart';
import '../final_dispatch/final_dispatch_providers.dart';
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
  String? _candidateKey;
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
    _tabController = TabController(length: 4, vsync: this);
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

    setState(() {
      _isSaving = true;
      _error = null;
      _success = null;
    });

    try {
      final user = ref.read(currentUserProvider).value;
      final repo = ref.read(rtvRepositoryProvider);
      final result = await repo.save(
        batchNumber: _batchCtrl.text.trim(),
        partId: _partId!,
        rtvQty: qty,
        reason: _reason!,
        vendorId: _vendorId!,
        expectedReturnDate: _expectedDateCtrl.text.trim().isEmpty
            ? null
            : _expectedDateCtrl.text.trim(),
        remarks:
            _remarksCtrl.text.trim().isEmpty ? null : _remarksCtrl.text.trim(),
        createdBy: user?.id ?? 'unknown',
        recordedAt: _recordedAt,
      );

      if (result.success) {
        setState(() => _success = 'RTV saved! Cycle #${result.cycleNumber}');
        ref.invalidate(rtvListProvider);
        ref.invalidate(rtvCandidatesProvider);
        ref.invalidate(pendingRtvReturnsProvider);
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
      _candidateKey = null;
      _vendorId = null;
      _reason = null;
      _recordedAt = DateTime.now();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Return to Vendor'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.add_circle_outline), text: 'New Entry'),
            Tab(icon: Icon(Icons.assignment_return), text: 'Receive'),
            Tab(icon: Icon(Icons.inventory_2_outlined), text: 'RTV Stock'),
            Tab(icon: Icon(Icons.history), text: 'History'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildForm(),
          const _RtvReturnsTab(),
          const _RtvStockTab(),
          _buildHistory(),
        ],
      ),
    );
  }

  Widget _buildForm() {
    final rtvReasons = ref.watch(rtvReasonsListProvider);
    final vendors = ref.watch(vendorsProvider);
    final candidates = ref.watch(rtvCandidatesProvider);

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
          candidates.when(
            loading: () => const LinearProgressIndicator(),
            error: (e, _) => ErrorBanner('Could not load RTV candidates: $e'),
            data: (list) => AppDropdown<String>(
              label: 'AP Reject Batch',
              isRequired: true,
              prefixIcon: const Icon(Icons.inventory_outlined),
              value: _candidateKey,
              items: list.map((candidate) {
                final key =
                    '${candidate['batch_number']}|${candidate['part_id']}';
                final available =
                    (candidate['available_qty'] as num?)?.toInt() ?? 0;
                return DropdownMenuItem(
                  value: key,
                  child: Text(
                    '${candidate['part_code']} - ${candidate['batch_number']} '
                    '($available PCS)',
                  ),
                );
              }).toList(),
              onChanged: (value) {
                if (value == null) return;
                final selected = list.firstWhere(
                  (candidate) =>
                      '${candidate['batch_number']}|${candidate['part_id']}' ==
                      value,
                );
                setState(() {
                  _candidateKey = value;
                  _batchCtrl.text = selected['batch_number'] as String;
                  _partId = selected['part_id'] as String;
                  _rtvQtyCtrl.text =
                      ((selected['available_qty'] as num?)?.toInt() ?? 0)
                          .toString();
                });
              },
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
              items: list
                  .map(
                    (v) => DropdownMenuItem(
                      value: v['id'] as String,
                      child: Text(v['name'] as String),
                    ),
                  )
                  .toList(),
              onChanged: (v) => setState(() => _vendorId = v),
            ),
          ),
          const SizedBox(height: 12),
          AppDropdown<String>(
            label: 'RTV Reason',
            isRequired: true,
            prefixIcon: const Icon(Icons.report_problem_outlined),
            value: _reason,
            items: (rtvReasons.value ?? kRtvReasonsFallback)
                .map(
                  (r) => DropdownMenuItem(
                    value: r,
                    child: Text(r),
                  ),
                )
                .toList(),
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
    final role = ref.watch(userRoleProvider);
    final canResolveEscalation = role?.canApproveCorrections == true;
    return list.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) =>
          EmptyState(message: 'Error: $e', icon: Icons.error_outline),
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
              title: Text(
                r['batch_number'] ?? '—',
                style: const TextStyle(
                    fontFamily: 'monospace', fontWeight: FontWeight.w600,),
              ),
              subtitle: Text(
                  '${r['vendor_name'] ?? ''} · Cycle $cycle · ${r['date']}',),
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${r['rtv_qty']} PCS',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: _statusColor(status).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      status,
                      style:
                          TextStyle(fontSize: 10, color: _statusColor(status)),
                    ),
                  ),
                  Icon(
                    isSynced ? Icons.cloud_done : Icons.cloud_upload_outlined,
                    size: 12,
                    color: isSynced ? Colors.green : Colors.orange,
                  ),
                ],
              ),
              onTap: status == 'escalated' && canResolveEscalation
                  ? () async {
                      final saved = await showModalBottomSheet<bool>(
                        context: context,
                        isScrollControlled: true,
                        useSafeArea: true,
                        builder: (_) => _RtvResolutionSheet(record: r),
                      );
                      if (saved == true && mounted) {
                        ref.invalidate(rtvListProvider);
                        ref.invalidate(rtvStockProvider);
                        ref.invalidate(apOkStockProvider);
                        ref.invalidate(approvedDispatchBatchesProvider);
                      }
                    }
                  : null,
            );
          },
        );
      },
    );
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'sent':
        return Colors.blue;
      case 'received':
      case 'approved':
      case 'force_dispatched':
        return Colors.green;
      case 'escalated':
      case 'scrapped':
        return Colors.red;
      case 'partially_received':
      case 'rejected_again':
        return Colors.orange;
      default:
        return Colors.orange;
    }
  }
}

// ─── RTV Stock Tab ────────────────────────────────────────────────────────────
// Shows: vendor ke paas hamara kitna material hai, kab gaya, kyun gaya

class _RtvResolutionSheet extends ConsumerStatefulWidget {
  const _RtvResolutionSheet({required this.record});

  final Map<String, dynamic> record;

  @override
  ConsumerState<_RtvResolutionSheet> createState() =>
      _RtvResolutionSheetState();
}

class _RtvResolutionSheetState extends ConsumerState<_RtvResolutionSheet> {
  final _reasonCtrl = TextEditingController();
  String _action = 'scrapped';
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _reasonCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_reasonCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Decision reason is required for the audit log.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final user = ref.read(currentUserProvider).value;
    final result = await ref.read(rtvRepositoryProvider).resolveEscalation(
          rtvId: widget.record['id'] as String,
          action: _action,
          reason: _reasonCtrl.text.trim(),
          resolvedBy: user?.id ?? 'unknown',
          role: ref.read(userRoleProvider),
        );
    if (!mounted) return;
    if (!result.success) {
      setState(() {
        _saving = false;
        _error = result.error ?? 'Admin decision could not be saved.';
      });
      return;
    }
    ref.invalidate(rtvListProvider);
    ref.invalidate(rtvStockProvider);
    ref.invalidate(apOkStockProvider);
    ref.invalidate(approvedDispatchBatchesProvider);
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 20 + bottomInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Resolve Escalated RTV',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 4),
          Text(
            '${widget.record['batch_number']} • Cycle ${widget.record['cycle_number']}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 20),
          AppDropdown<String>(
            label: 'Admin Decision',
            isRequired: true,
            prefixIcon: const Icon(Icons.admin_panel_settings_outlined),
            value: _action,
            items: const [
              DropdownMenuItem(
                value: 'scrapped',
                child: Text('Scrap rejected material'),
              ),
              DropdownMenuItem(
                value: 'force_dispatched',
                child: Text('Approve for dispatch (override)'),
              ),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _action = value);
            },
          ),
          const SizedBox(height: 12),
          AppFormField(
            label: 'Mandatory reason',
            controller: _reasonCtrl,
            maxLines: 3,
            prefixIcon: const Icon(Icons.fact_check_outlined),
          ),
          const SizedBox(height: 8),
          Text(
            _action == 'scrapped'
                ? 'The rejected quantity will be written off from RTV stock.'
                : 'The quantity will move to Approved AP stock and become dispatchable. This override is audit logged.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            ErrorBanner(_error!),
          ],
          const SizedBox(height: 20),
          SaveButton(onPressed: _save, isLoading: _saving),
        ],
      ),
    );
  }
}

class _RtvReturnsTab extends ConsumerWidget {
  const _RtvReturnsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final returns = ref.watch(pendingRtvReturnsProvider);
    return returns.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => EmptyState(
        message: 'Could not load pending RTV returns: $error',
        icon: Icons.error_outline,
      ),
      data: (records) {
        if (records.isEmpty) {
          return const EmptyState(
            message: 'No material is pending return from a vendor.',
            icon: Icons.task_alt,
          );
        }
        return RefreshIndicator(
          onRefresh: () => ref.refresh(pendingRtvReturnsProvider.future),
          child: ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: records.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final record = records[index];
              final remaining = (record['remaining_qty'] as num?)?.toInt() ?? 0;
              return Card(
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor:
                        Theme.of(context).colorScheme.primaryContainer,
                    child: const Icon(Icons.assignment_return),
                  ),
                  title: Text(
                    '${record['part_code']} - ${record['part_name']}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${record['batch_number']}  •  ${record['vendor_name'] ?? 'Vendor'}\n'
                    'Cycle ${record['cycle_number']}  •  $remaining PCS pending',
                  ),
                  isThreeLine: true,
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    final saved = await showModalBottomSheet<bool>(
                      context: context,
                      isScrollControlled: true,
                      useSafeArea: true,
                      builder: (_) => _RtvReturnSheet(record: record),
                    );
                    if (saved == true && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('RTV return and reinspection saved.'),
                        ),
                      );
                    }
                  },
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _RtvReturnSheet extends ConsumerStatefulWidget {
  const _RtvReturnSheet({required this.record});

  final Map<String, dynamic> record;

  @override
  ConsumerState<_RtvReturnSheet> createState() => _RtvReturnSheetState();
}

class _RtvReturnSheetState extends ConsumerState<_RtvReturnSheet> {
  late final TextEditingController _receivedCtrl;
  late final TextEditingController _okCtrl;
  final _rejectCtrl = TextEditingController(text: '0');
  final _remarksCtrl = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final remaining = (widget.record['remaining_qty'] as num?)?.toInt() ?? 0;
    _receivedCtrl = TextEditingController(text: remaining.toString());
    _okCtrl = TextEditingController(text: remaining.toString());
  }

  @override
  void dispose() {
    _receivedCtrl.dispose();
    _okCtrl.dispose();
    _rejectCtrl.dispose();
    _remarksCtrl.dispose();
    super.dispose();
  }

  void _recalculateReject() {
    final received = double.tryParse(_receivedCtrl.text) ?? 0;
    final ok = double.tryParse(_okCtrl.text) ?? 0;
    final rejected = (received - ok).clamp(0, double.infinity);
    _rejectCtrl.text = rejected == rejected.roundToDouble()
        ? rejected.toInt().toString()
        : rejected.toString();
    setState(() {});
  }

  Future<void> _save() async {
    final received = double.tryParse(_receivedCtrl.text) ?? 0;
    final ok = double.tryParse(_okCtrl.text) ?? 0;
    final rejected = double.tryParse(_rejectCtrl.text) ?? 0;
    final remaining = (widget.record['remaining_qty'] as num?)?.toDouble() ?? 0;
    if (received <= 0 || received > remaining) {
      setState(
        () => _error =
            'Received quantity must be between 1 and ${remaining.toInt()} PCS.',
      );
      return;
    }
    if ((ok + rejected - received).abs() > 0.001) {
      setState(
        () => _error = 'OK + Reject Again must equal Quantity Received.',
      );
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    final user = ref.read(currentUserProvider).value;
    final result = await ref.read(rtvRepositoryProvider).saveReinspection(
          rtvId: widget.record['id'] as String,
          quantityReceived: received,
          okQty: ok,
          rejectAgainQty: rejected,
          createdBy: user?.id ?? 'unknown',
          remarks: _remarksCtrl.text.trim().isEmpty
              ? null
              : _remarksCtrl.text.trim(),
        );
    if (!mounted) return;
    if (!result.success) {
      setState(() {
        _saving = false;
        _error = result.error ?? 'RTV return could not be saved.';
      });
      return;
    }

    ref.invalidate(pendingRtvReturnsProvider);
    ref.invalidate(rtvCandidatesProvider);
    ref.invalidate(rtvListProvider);
    ref.invalidate(rtvStockProvider);
    ref.invalidate(apOkStockProvider);
    ref.invalidate(approvedDispatchBatchesProvider);
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 20 + bottomInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Receive RTV Material',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 4),
          Text(
            '${widget.record['part_code']} • ${widget.record['batch_number']} • '
            'Cycle ${widget.record['cycle_number']}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 20),
          NumberFormField(
            label: 'Quantity Received',
            controller: _receivedCtrl,
            allowDecimal: false,
            prefixIcon: const Icon(Icons.move_to_inbox_outlined),
            onChanged: (_) => _recalculateReject(),
          ),
          const SizedBox(height: 12),
          NumberFormField(
            label: 'OK Qty',
            controller: _okCtrl,
            allowDecimal: false,
            prefixIcon: const Icon(Icons.check_circle_outline),
            onChanged: (_) => _recalculateReject(),
          ),
          const SizedBox(height: 12),
          NumberFormField(
            label: 'Reject Again Qty',
            controller: _rejectCtrl,
            allowDecimal: false,
            readOnly: true,
            prefixIcon: const Icon(Icons.replay_circle_filled_outlined),
          ),
          const SizedBox(height: 12),
          AppFormField(
            label: 'Remarks (optional)',
            controller: _remarksCtrl,
            maxLines: 2,
            prefixIcon: const Icon(Icons.notes_outlined),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            ErrorBanner(_error!),
          ],
          const SizedBox(height: 20),
          SaveButton(onPressed: _save, isLoading: _saving),
        ],
      ),
    );
  }
}

class _RtvStockTab extends ConsumerWidget {
  const _RtvStockTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stockAsync = ref.watch(rtvStockProvider);
    final theme = Theme.of(context);

    return stockAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) =>
          EmptyState(message: 'Error: $e', icon: Icons.error_outline),
      data: (items) {
        if (items.isEmpty) {
          return const EmptyState(
            message: 'No RTV stock.\nAll returned or none sent yet.',
            icon: Icons.inventory_2_outlined,
          );
        }

        // Group by part for summary
        final totalRtv = items.fold(
            0.0, (s, r) => s + ((r['rtv_qty'] as num?)?.toDouble() ?? 0),);
        final totalCurrent = items.fold(0.0,
            (s, r) => s + ((r['current_balance'] as num?)?.toDouble() ?? 0),);

        return Column(
          children: [
            // Summary banner
            Container(
              margin: const EdgeInsets.all(12),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.deepOrange.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(12),
                border:
                    Border.all(color: Colors.deepOrange.withValues(alpha: 0.2)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.inventory_2_outlined,
                      color: Colors.deepOrange, size: 28,),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${totalCurrent.toInt()} PCS at Vendor',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            color: Colors.deepOrange,
                          ),
                        ),
                        Text(
                          '${totalRtv.toInt()} PCS total sent for RTV',
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
                  final rtvQty = (item['rtv_qty'] as num?)?.toInt() ?? 0;
                  final currentBalance =
                      (item['current_balance'] as num?)?.toInt() ?? 0;
                  final date = item['date'] as String? ?? '—';
                  final reason = item['reason'] as String? ?? '—';
                  final batch = item['batch_number'] as String? ?? '—';

                  return Card(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                      side: BorderSide(
                          color: Colors.deepOrange.withValues(alpha: 0.2),),
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
                                      style: const TextStyle(
                                          fontWeight: FontWeight.bold,),
                                    ),
                                    Text(
                                      'Batch: $batch',
                                      style: const TextStyle(
                                        fontFamily: 'monospace',
                                        fontSize: 11,
                                      ),
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
                                      color: Colors.deepOrange,
                                    ),
                                  ),
                                  if (currentBalance > 0)
                                    Text(
                                      '$currentBalance PCS at vendor',
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: Colors.orange,
                                      ),
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
  const _InfoChip(
      {required this.icon, required this.label, required this.color,});
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
