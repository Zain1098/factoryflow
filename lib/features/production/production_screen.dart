import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/batch_config_provider.dart';
import '../../core/providers/master_data_providers.dart';
import '../../core/providers/production_flow_provider.dart';
import '../../core/widgets/shared_widgets.dart';
import '../auth/auth_providers.dart';
import 'production_providers.dart';

class ProductionScreen extends ConsumerStatefulWidget {
  const ProductionScreen({super.key});

  @override
  ConsumerState<ProductionScreen> createState() => _ProductionScreenState();
}

class _ProductionScreenState extends ConsumerState<ProductionScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // Form State
  String? _partId;
  String? _partCode;
  DateTime _recordedAt = DateTime.now();

  // WIP Continuation State
  String? _wipBatchNumber;
  double? _wipLastGoodQty;
  List<String> _wipDoneMachineIds = [];

  // Session Machine Entries (Entries to be saved in one batch job)
  final List<MachineEntry> _sessionEntries = [];

  // Async & Notification State
  bool _isSaving = false;
  String? _error;
  String? _success;
  String? _savedBatchNumber;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _resetForm() {
    setState(() {
      _partId = null;
      _partCode = null;
      _wipBatchNumber = null;
      _wipLastGoodQty = null;
      _wipDoneMachineIds.clear();
      _recordedAt = DateTime.now();
      _sessionEntries.clear();
      _error = null;
      _success = null;
      _savedBatchNumber = null;
    });
  }

  Future<void> _saveAll() async {
    if (_partId == null) {
      setState(() => _error = 'Please select a Part first.');
      return;
    }
    if (_sessionEntries.isEmpty) {
      setState(() => _error = 'Please add at least one machine entry.');
      return;
    }

    final flow = ref.read(productionFlowProvider);

    // Multi-stage validation across session entries
    if (flow.isMultiStage && _sessionEntries.length > 1) {
      for (int i = 1; i < _sessionEntries.length; i++) {
        final prevGood = _sessionEntries[i - 1].goodQty;
        if (_sessionEntries[i].productionQty > prevGood) {
          setState(() {
            _error =
                '${_sessionEntries[i].machineName} production (${_sessionEntries[i].productionQty.toInt()}) '
                'cannot exceed previous stage good quantity (${prevGood.toInt()} PCS).';
          });
          return;
        }
      }
    }

    setState(() {
      _isSaving = true;
      _error = null;
      _success = null;
      _savedBatchNumber = null;
    });

    try {
      final user = ref.read(currentUserProvider).value;
      final repo = ref.read(productionRepositoryProvider);

      final result = await repo.saveJob(
        partId: _partId!,
        partCode: _partCode!,
        entries: _sessionEntries,
        createdBy: user?.id ?? 'unknown',
        recordedAt: _recordedAt,
        existingBatchNumber: _wipBatchNumber,
      );

      if (result.error.isNotEmpty) {
        setState(() => _error = result.error);
        return;
      }

      final isWip = result.isWip;
      final finalGoodQty = _sessionEntries.last.goodQty.toInt();

      final msg = isWip
          ? '⏳ Production saved as WIP Batch (${result.batchNumber}). Raw material is held in WIP stock until final machine completion.'
          : '✅ Production Batch Complete (${result.batchNumber})! $finalGoodQty PCS moved to BP (Vendor) Stock.';

      setState(() {
        _success = msg;
        _savedBatchNumber = result.batchNumber;
        _sessionEntries.clear();
        _wipBatchNumber = null;
        _wipLastGoodQty = null;
        _wipDoneMachineIds.clear();
      });

      ref.invalidate(productionListProvider);
      ref.invalidate(wipBatchesProvider);
    } catch (e) {
      setState(() => _error = 'Error saving production: $e');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _onPartChanged(String? val, List<Map<String, dynamic>> parts) {
    if (val == null) return;
    final match = parts.firstWhere((p) => p['id'] == val);
    final flow = ref.read(productionFlowProvider);

    setState(() {
      _partId = val;
      _partCode = match['code'] as String;
      _wipBatchNumber = null;
      _wipLastGoodQty = null;
      _wipDoneMachineIds.clear();
      _sessionEntries.clear();
      _error = null;
      _success = null;
    });

    // Check for open WIP batch for this part
    if (flow.isMultiStage) {
      final wip = ref.read(productionRepositoryProvider).getWipBatchForPart(
            val,
            flow.requiredMachineIds,
          );
      if (wip != null) {
        _suggestWipContinuation(wip);
      }
    }
  }

  void _suggestWipContinuation(Map<String, dynamic> wip) {
    final batchNum = wip['batch_number'] as String? ?? '';
    final lastGood = (wip['last_good_qty'] as num?)?.toDouble() ?? 0.0;
    final doneIds = (wip['done_machine_ids'] as List? ?? []).cast<String>();

    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 8),
        backgroundColor: Colors.indigo.shade900,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.pending_actions, color: Colors.amber, size: 18),
                SizedBox(width: 6),
                Text(
                  'Active WIP Batch Found!',
                  style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              'Batch: $batchNum (${doneIds.length} stage(s) done, ${lastGood.toInt()} PCS available)',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
        action: SnackBarAction(
          label: 'Continue Batch',
          textColor: Colors.amber,
          onPressed: () {
            setState(() {
              _wipBatchNumber = batchNum;
              _wipLastGoodQty = lastGood;
              _wipDoneMachineIds = doneIds;
            });
          },
        ),
      ),
    );
  }

  void _continueWipBatch(Map<String, dynamic> wip) {
    final batchNum = wip['batch_number'] as String;
    final partId = wip['part_id'] as String;
    final partCode = wip['part_code'] as String? ?? '';
    final lastGood = (wip['last_good_qty'] as num?)?.toDouble() ?? 0.0;
    final doneIds = (wip['done_machine_ids'] as List? ?? []).cast<String>();

    setState(() {
      _partId = partId;
      _partCode = partCode;
      _wipBatchNumber = batchNum;
      _wipLastGoodQty = lastGood;
      _wipDoneMachineIds = doneIds;
      _sessionEntries.clear();
      _error = null;
      _success = null;
    });

    _tabController.animateTo(0);
  }

  @override
  Widget build(BuildContext context) {
    final wipListAsync = ref.watch(wipBatchesProvider);
    final wipCount = wipListAsync.value?.length ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Daily Production'),
        elevation: 1,
        bottom: TabBar(
          controller: _tabController,
          indicatorWeight: 3,
          tabs: [
            const Tab(
              icon: Icon(Icons.precision_manufacturing_outlined),
              text: 'New Entry',
            ),
            Tab(
              icon: Badge.count(
                count: wipCount,
                isLabelVisible: wipCount > 0,
                child: const Icon(Icons.pending_actions_outlined),
              ),
              text: 'WIP Batches',
            ),
            const Tab(
              icon: Icon(Icons.history_outlined),
              text: 'History',
            ),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildSessionTab(),
          _buildWipTab(),
          _buildHistoryTab(),
        ],
      ),
    );
  }

  // ─── TAB 1: NEW ENTRY ───────────────────────────────────────────────────────

  Widget _buildSessionTab() {
    final partsAsync = ref.watch(partsProvider);
    final theme = Theme.of(context);
    final showBatchConfig = ref.watch(batchConfigProvider);
    final flow = ref.watch(productionFlowProvider);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 1. Active WIP Batch Continuation Banner
          if (_wipBatchNumber != null)
            Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.amber.shade900.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.amber.shade700.withValues(alpha: 0.4)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.link, color: Colors.amber.shade800, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Continuing WIP Batch: $_wipBatchNumber',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.amber.shade900,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        color: Colors.amber.shade900,
                        tooltip: 'Cancel WIP Continuation',
                        onPressed: () {
                          setState(() {
                            _wipBatchNumber = null;
                            _wipLastGoodQty = null;
                            _wipDoneMachineIds.clear();
                          });
                        },
                      ),
                    ],
                  ),
                  if (_wipLastGoodQty != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Input Qty available from previous stage: ${_wipLastGoodQty!.toInt()} PCS',
                      style: TextStyle(fontSize: 12, color: Colors.amber.shade900),
                    ),
                  ],
                ],
              ),
            ),

          // 2. Main Entry Details Card (Date, Time, Part Selection)
          Card(
            elevation: 0.5,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'PRODUCTION HEADER',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.8,
                        ),
                      ),
                      if (flow.isMultiStage)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            'Multi-Stage Sequence Active',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.onPrimaryContainer,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  RecordDateTimePicker(
                    value: _recordedAt,
                    onChanged: (dt) => setState(() => _recordedAt = dt),
                  ),
                  const SizedBox(height: 14),
                  partsAsync.when(
                    loading: () => const LinearProgressIndicator(),
                    error: (e, _) => ErrorBanner('Failed to load parts: $e'),
                    data: (parts) => AppDropdown<String>(
                      label: 'Select Finished Part',
                      isRequired: true,
                      prefixIcon: const Icon(Icons.category_outlined),
                      value: _partId,
                      items: parts
                          .map((p) => DropdownMenuItem(
                                value: p['id'] as String,
                                child: Text('${p['code']} – ${p['name']}'),
                              ),)
                          .toList(),
                      onChanged: (v) => _onPartChanged(v, parts),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),

          // 3. Operator Machine Entries Section Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'MACHINE & OPERATOR ENTRIES',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Record each machine step for this batch',
                    style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
              FilledButton.icon(
                onPressed: _partId == null ? null : () => _showAddEntryModal(),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add Machine Entry'),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // 4. List of Session Entries or Empty Card
          if (_sessionEntries.isEmpty)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 20),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLowest,
                border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Center(
                child: Column(
                  children: [
                    Icon(
                      Icons.precision_manufacturing,
                      size: 44,
                      color: theme.colorScheme.primary.withValues(alpha: 0.4),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _partId == null
                          ? 'Step 1: Select a Part above'
                          : 'No machine entries added yet.',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (_partId != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Tap "+ Add Machine Entry" to record Operator A or B production.',
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            )
          else
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _sessionEntries.length,
              itemBuilder: (context, idx) {
                final entry = _sessionEntries[idx];

                return Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(
                      color: entry.isFinal
                          ? Colors.green.withValues(alpha: 0.5)
                          : theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            CircleAvatar(
                              radius: 14,
                              backgroundColor: entry.isFinal
                                  ? Colors.green.withValues(alpha: 0.2)
                                  : theme.colorScheme.primaryContainer,
                              child: Text(
                                '${entry.sequenceIndex > 0 ? entry.sequenceIndex : idx + 1}',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: entry.isFinal
                                      ? Colors.green.shade900
                                      : theme.colorScheme.onPrimaryContainer,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Text(
                                        entry.machineName,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 14,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      if (entry.isFinal)
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 6, vertical: 2,),
                                          decoration: BoxDecoration(
                                            color: Colors.green.shade100,
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                          child: Text(
                                            'FINAL STAGE (BP)',
                                            style: TextStyle(
                                              fontSize: 9,
                                              fontWeight: FontWeight.bold,
                                              color: Colors.green.shade900,
                                            ),
                                          ),
                                        )
                                      else if (flow.isMultiStage)
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 6, vertical: 2,),
                                          decoration: BoxDecoration(
                                            color: Colors.amber.shade100,
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                          child: Text(
                                            'WIP STAGE',
                                            style: TextStyle(
                                              fontSize: 9,
                                              fontWeight: FontWeight.bold,
                                              color: Colors.amber.shade900,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Operator: ${entry.operatorName} · Status: ${entry.status}',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.edit_outlined, size: 18),
                              onPressed: () => _showAddEntryModal(existingEntry: entry, index: idx),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline, color: Colors.red, size: 18),
                              onPressed: () {
                                setState(() {
                                  _sessionEntries.removeAt(idx);
                                });
                              },
                            ),
                          ],
                        ),
                        const Divider(height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: [
                            _buildStatItem('Prod Qty', '${entry.productionQty.toInt()} PCS', theme),
                            _buildStatItem('Rejects', '${entry.rejectQty.toInt()} PCS', theme,
                                color: Colors.red.shade700,),
                            _buildStatItem(
                              'Good (OK)',
                              '${entry.goodQty.toInt()} PCS',
                              theme,
                              color: Colors.teal.shade800,
                              isBold: true,
                            ),
                          ],
                        ),
                        if (entry.remarks.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                            'Remarks: ${entry.remarks}',
                            style: const TextStyle(fontSize: 11, fontStyle: FontStyle.italic),
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),

          // 5. Session Summary Calculation
          if (_sessionEntries.isNotEmpty) ...[
            const SizedBox(height: 16),
            _buildSessionSummaryCard(theme, flow),
          ],

          const SizedBox(height: 20),

          // 6. Action Result Banners
          if (_error != null) ErrorBanner(_error!),
          if (_success != null) ...[
            SuccessBanner(_success!),
            if (_savedBatchNumber != null && showBatchConfig) ...[
              const SizedBox(height: 8),
              Card(
                color: theme.colorScheme.secondaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      const Icon(Icons.qr_code, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Saved Batch Number:',
                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                            ),
                            Text(
                              _savedBatchNumber!,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],

          const SizedBox(height: 16),

          // 7. Save & Reset Action Buttons
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _resetForm,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Reset Form'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: FilledButton.icon(
                  onPressed: _isSaving || _sessionEntries.isEmpty ? null : _saveAll,
                  icon: _isSaving
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.save_outlined, size: 18),
                  label: Text(_isSaving ? 'Saving...' : 'Save Production Job'),
                ),
              ),
            ],
          ),

          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _buildStatItem(String label, String val, ThemeData theme,
      {Color? color, bool isBold = false,}) {
    return Column(
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 10, color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 2),
        Text(
          val,
          style: TextStyle(
            fontSize: 13,
            fontWeight: isBold ? FontWeight.bold : FontWeight.w600,
            color: color ?? theme.colorScheme.onSurface,
          ),
        ),
      ],
    );
  }

  Widget _buildSessionSummaryCard(ThemeData theme, ProductionFlowConfig flow) {
    final lastEntry = _sessionEntries.last;
    final totalRejects = _sessionEntries.fold(0.0, (sum, e) => sum + e.rejectQty).toInt();
    final netGoodQty = lastEntry.goodQty.toInt();
    final willCompleteBatch = !_sessionEntries.any((e) => !e.isFinal) ||
        (flow.requiredMachineIds.isNotEmpty &&
            flow.requiredMachineIds.last == lastEntry.machineId);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.assessment_outlined, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text(
                'PRODUCTION SUMMARY',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  color: theme.colorScheme.primary,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Machine Steps in this Entry:', style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
              Text('${_sessionEntries.length} machine(s)', style: const TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Total BP Rejects:', style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
              Text('$totalRejects PCS', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red.shade700)),
            ],
          ),
          const Divider(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    willCompleteBatch ? 'Final Good Qty (BP Stock):' : 'Intermediate Good Qty (WIP):',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                  Text(
                    willCompleteBatch
                        ? 'Will be added to BP (Vendor-ready) Stock'
                        : 'Held in WIP Stock until final machine finishes',
                    style: TextStyle(fontSize: 10, color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
              Text(
                '$netGoodQty PCS',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                  color: willCompleteBatch ? Colors.teal.shade800 : Colors.amber.shade900,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ─── ADD / EDIT ENTRY MODAL ──────────────────────────────────────────────────

  Future<void> _showAddEntryModal({MachineEntry? existingEntry, int? index}) async {
    final operatorsAsync = ref.read(operatorsProvider);
    final machinesAsync = ref.read(machinesProvider);
    final flow = ref.read(productionFlowProvider);

    final operators = operatorsAsync.value ?? [];
    final machines = machinesAsync.value ?? [];

    if (operators.isEmpty || machines.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Operators or Machines data missing in Settings.')),
      );
      return;
    }

    String localOperatorId = existingEntry?.operatorId ?? operators.first['id'] as String;
    String localOperatorName = existingEntry?.operatorName ?? operators.first['name'] as String;

    // Filter available machines
    final List<Map<String, dynamic>> seqMachines = flow.isMultiStage && flow.requiredMachineIds.isNotEmpty
        ? flow.requiredMachineIds
            .map((id) => machines.firstWhere((m) => m['id'] == id, orElse: () => <String, dynamic>{}))
            .where((m) => m.isNotEmpty)
            .toList()
        : machines;

    // Determine default machine selection
    String localMachineId = existingEntry?.machineId ??
        (_wipDoneMachineIds.isNotEmpty
            ? (flow.getNextMachineId(_wipDoneMachineIds.last) ?? seqMachines.first['id'] as String)
            : seqMachines.first['id'] as String);

    // Calculate maximum allowed production qty based on previous stage
    double? maxAllowedProdQty;
    if (_wipLastGoodQty != null) {
      maxAllowedProdQty = _wipLastGoodQty;
    } else if (index != null && index > 0) {
      maxAllowedProdQty = _sessionEntries[index - 1].goodQty;
    } else if (index == null && _sessionEntries.isNotEmpty) {
      maxAllowedProdQty = _sessionEntries.last.goodQty;
    }

    final prodCtrl = TextEditingController(
      text: existingEntry != null
          ? existingEntry.productionQty.toInt().toString()
          : (maxAllowedProdQty != null ? maxAllowedProdQty.toInt().toString() : ''),
    );
    final rejectCtrl = TextEditingController(
      text: existingEntry != null ? existingEntry.rejectQty.toInt().toString() : '0',
    );
    final remarksCtrl = TextEditingController(text: existingEntry?.remarks ?? '');
    String localStatus = existingEntry?.status ?? 'Running';

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            final selectedMachine = machines.firstWhere((m) => m['id'] == localMachineId, orElse: () => machines.first);
            final mName = selectedMachine['name'] as String? ?? 'Machine';
            final mCode = selectedMachine['machine_code'] as String? ?? mName.substring(0, 1);
            final seqIdx = flow.isMultiStage ? flow.getMachineSequenceIndex(localMachineId) : 0;
            final isFinal = flow.isMultiStage ? flow.isFinalMachine(localMachineId) : true;

            final prodVal = double.tryParse(prodCtrl.text) ?? 0.0;
            final rejVal = double.tryParse(rejectCtrl.text) ?? 0.0;
            final goodVal = (prodVal - rejVal).clamp(0, double.infinity);

            void quickAddProd(int add) {
              final current = double.tryParse(prodCtrl.text) ?? 0.0;
              prodCtrl.text = (current + add).toInt().toString();
              setModalState(() {});
            }

            void quickAddRej(int add) {
              final current = double.tryParse(rejectCtrl.text) ?? 0.0;
              rejectCtrl.text = (current + add).toInt().toString();
              setModalState(() {});
            }

            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
                top: 20,
                left: 16,
                right: 16,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          existingEntry == null ? 'Add Machine Entry' : 'Edit Machine Entry',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ],
                    ),
                    const Divider(),
                    const SizedBox(height: 8),

                    // Operator Dropdown
                    AppDropdown<String>(
                      label: 'Operator Name',
                      isRequired: true,
                      prefixIcon: const Icon(Icons.person_outline),
                      value: localOperatorId,
                      items: operators
                          .map((o) => DropdownMenuItem(
                                value: o['id'] as String,
                                child: Text(o['name'] as String),
                              ),)
                          .toList(),
                      onChanged: (v) {
                        if (v == null) return;
                        final match = operators.firstWhere((o) => o['id'] == v);
                        setModalState(() {
                          localOperatorId = v;
                          localOperatorName = match['name'] as String;
                        });
                      },
                    ),
                    const SizedBox(height: 14),

                    // Machine Selection Chips
                    const Text(
                      'Running Machine',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: seqMachines.map((m) {
                        final mId = m['id'] as String;
                        final name = m['name'] as String;
                        final isSelected = mId == localMachineId;
                        final isDone = _wipDoneMachineIds.contains(mId);
                        final sIdx = flow.isMultiStage ? flow.getMachineSequenceIndex(mId) : 0;
                        final isFinalM = flow.isMultiStage && flow.isFinalMachine(mId);

                        return ChoiceChip(
                          label: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (sIdx > 0) ...[
                                Text('#$sIdx ', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                              ],
                              Text(name),
                              if (isDone) ...[
                                const SizedBox(width: 4),
                                const Icon(Icons.check_circle, size: 14, color: Colors.green),
                              ] else if (isFinalM) ...[
                                const SizedBox(width: 4),
                                const Icon(Icons.star, size: 12, color: Colors.amber),
                              ],
                            ],
                          ),
                          selected: isSelected,
                          onSelected: (selected) {
                            if (selected) {
                              setModalState(() => localMachineId = mId);
                            }
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 14),

                    // Status Dropdown
                    AppDropdown<String>(
                      label: 'Machine Status / Condition',
                      isRequired: true,
                      prefixIcon: const Icon(Icons.build_circle_outlined),
                      value: localStatus,
                      items: kMachineStatuses
                          .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                          .toList(),
                      onChanged: (v) => setModalState(() => localStatus = v ?? 'Running'),
                    ),
                    const SizedBox(height: 14),

                    // Production Quantity Field
                    TextFormField(
                      controller: prodCtrl,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: 'Production Qty (PCS)',
                        prefixIcon: const Icon(Icons.factory_outlined),
                        suffixText: maxAllowedProdQty != null ? 'Max: ${maxAllowedProdQty.toInt()}' : null,
                        border: const OutlineInputBorder(),
                      ),
                      onChanged: (_) => setModalState(() {}),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      children: [50, 100, 200, 500].map((val) {
                        return ActionChip(
                          label: Text('+$val'),
                          onPressed: () => quickAddProd(val),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 14),

                    // Reject Quantity Field
                    TextFormField(
                      controller: rejectCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'BP Reject Qty (PCS)',
                        prefixIcon: Icon(Icons.cancel_outlined, color: Colors.red),
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (_) => setModalState(() {}),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      children: [1, 5, 10, 20].map((val) {
                        return ActionChip(
                          label: Text('+$val'),
                          onPressed: () => quickAddRej(val),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 14),

                    // Calculated Good Qty Preview
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.teal.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.teal.withValues(alpha: 0.3)),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Calculated Good Qty (OK):', style: TextStyle(fontWeight: FontWeight.w600)),
                          Text(
                            '${goodVal.toInt()} PCS',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.teal),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),

                    // Remarks Field
                    TextFormField(
                      controller: remarksCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Remarks / Downtime Notes (optional)',
                        prefixIcon: Icon(Icons.notes_outlined),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Add Entry Action Button
                    FilledButton(
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: () {
                        final enteredProd = double.tryParse(prodCtrl.text) ?? 0.0;
                        final enteredRej = double.tryParse(rejectCtrl.text) ?? 0.0;

                        if (enteredProd <= 0) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            const SnackBar(content: Text('Please enter a valid production quantity (> 0).')),
                          );
                          return;
                        }

                        if (maxAllowedProdQty != null && enteredProd > maxAllowedProdQty) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            SnackBar(
                              content: Text(
                                'Production Qty (${enteredProd.toInt()}) exceeds previous stage good Qty (${maxAllowedProdQty.toInt()} PCS).',
                              ),
                            ),
                          );
                          return;
                        }

                        final entry = MachineEntry(
                          machineId: localMachineId,
                          machineName: mName,
                          machineCode: mCode,
                          sequenceIndex: seqIdx,
                          isFinal: isFinal,
                          operatorId: localOperatorId,
                          operatorName: localOperatorName,
                          productionQty: enteredProd,
                          rejectQty: enteredRej,
                          status: localStatus,
                          remarks: remarksCtrl.text.trim(),
                        );

                        setState(() {
                          if (index != null) {
                            _sessionEntries[index] = entry;
                          } else {
                            _sessionEntries.add(entry);
                          }
                        });

                        Navigator.pop(ctx);
                      },
                      child: Text(existingEntry == null ? 'Add Machine Entry to List' : 'Update Machine Entry'),
                    ),
                    const SizedBox(height: 10),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    prodCtrl.dispose();
    rejectCtrl.dispose();
    remarksCtrl.dispose();
  }

  // ─── TAB 2: WIP BATCHES ─────────────────────────────────────────────────────

  Widget _buildWipTab() {
    final flow = ref.watch(productionFlowProvider);
    final wipAsync = ref.watch(wipBatchesProvider);
    final machinesAsync = ref.watch(machinesProvider);
    final theme = Theme.of(context);

    if (!flow.enabled) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.settings_outlined, size: 54, color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4)),
              const SizedBox(height: 14),
              Text(
                'Multi-Stage Flow is currently disabled.\nEnable it in Settings → Production Flow to track WIP batches.',
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    }

    return wipAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => EmptyState(message: 'Error loading WIP batches: $e', icon: Icons.error_outline),
      data: (wips) {
        if (wips.isEmpty) {
          return const EmptyState(
            message: 'No open WIP batches!\nAll production batches are fully completed.',
            icon: Icons.check_circle_outline,
          );
        }

        final machines = machinesAsync.value ?? [];
        String getMachineName(String id) {
          final m = machines.firstWhere((m) => m['id'] == id, orElse: () => <String, dynamic>{});
          return m['name'] as String? ?? id.substring(0, 6);
        }

        return ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: wips.length,
          itemBuilder: (context, i) {
            final w = wips[i];
            final batchNum = w['batch_number'] as String? ?? '';
            final doneIds = (w['done_machine_ids'] as List? ?? []).cast<String>();
            final missingIds = (w['missing_machine_ids'] as List? ?? []).cast<String>();
            final lastGood = (w['last_good_qty'] as num?)?.toInt() ?? 0;

            final totalStages = doneIds.length + missingIds.length;
            final currentStageNum = doneIds.length;

            return Card(
              margin: const EdgeInsets.only(bottom: 12),
              elevation: 0.5,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(color: Colors.amber.shade700.withValues(alpha: 0.4)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.amber.shade100,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            'WIP (Stage $currentStageNum/$totalStages)',
                            style: TextStyle(
                              color: Colors.amber.shade900,
                              fontWeight: FontWeight.bold,
                              fontSize: 11,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            batchNum,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        Text(
                          '$lastGood PCS',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${w['part_code']} – ${w['part_name']} · Date: ${w['date']}',
                      style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 12),

                    // Stage Progress Chips
                    const Text('Stage Progress:', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        ...doneIds.map((id) => Chip(
                              avatar: const Icon(Icons.check_circle, size: 14, color: Colors.green),
                              label: Text(getMachineName(id), style: const TextStyle(fontSize: 11)),
                              backgroundColor: Colors.green.withValues(alpha: 0.12),
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                            ),),
                        ...missingIds.map((id) => Chip(
                              avatar: const Icon(Icons.hourglass_empty, size: 14, color: Colors.amber),
                              label: Text(getMachineName(id), style: const TextStyle(fontSize: 11)),
                              backgroundColor: Colors.amber.withValues(alpha: 0.12),
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                            ),),
                      ],
                    ),
                    const SizedBox(height: 12),

                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        TextButton.icon(
                          onPressed: () => _showBatchTrailSheet(batchNum),
                          icon: const Icon(Icons.remove_red_eye_outlined, size: 16),
                          label: const Text('View History Trail', style: TextStyle(fontSize: 12)),
                        ),
                        FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.amber.shade900,
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () => _continueWipBatch(w),
                          icon: const Icon(Icons.play_arrow, size: 16),
                          label: const Text('Continue Batch'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showBatchTrailSheet(String batchNumber) {
    final repo = ref.read(productionRepositoryProvider);
    final records = repo.getBatchRecords(batchNumber);

    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Batch Trail: $batchNumber',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const Divider(),
              if (records.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: Center(child: Text('No stage records found.')),
                )
              else
                Expanded(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: records.length,
                    itemBuilder: (context, idx) {
                      final r = records[idx];
                      return ListTile(
                        leading: CircleAvatar(
                          child: Text('${idx + 1}'),
                        ),
                        title: Text('${r['machine_name']} (${r['operator_name']})'),
                        subtitle: Text('Date: ${r['date']} ${r['time'] ?? ''} · Status: ${r['machine_status_id']}'),
                        trailing: Text(
                          '${(r['good_qty'] as num?)?.toInt() ?? 0} OK',
                          style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.teal),
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  // ─── TAB 3: PRODUCTION HISTORY ──────────────────────────────────────────────

  Widget _buildHistoryTab() {
    final historyAsync = ref.watch(productionListProvider);

    return historyAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => EmptyState(message: 'Error: $e', icon: Icons.error_outline),
      data: (records) {
        if (records.isEmpty) {
          return const EmptyState(
            message: 'No production records created yet.',
            icon: Icons.precision_manufacturing_outlined,
          );
        }

        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: records.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final r = records[i];
            final isSynced = r['sync_status'] == 'synced';
            final goodQty = (r['good_qty'] as num?)?.toInt() ?? 0;
            final prodQty = (r['production_qty'] as num?)?.toInt() ?? 0;
            final rejQty = (r['bp_reject_qty'] as num?)?.toInt() ?? 0;

            return ListTile(
              leading: CircleAvatar(
                backgroundColor: Colors.teal.withValues(alpha: 0.12),
                child: const Icon(Icons.precision_manufacturing, color: Colors.teal, size: 20),
              ),
              title: Text(
                r['batch_number'] ?? '—',
                style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold, fontSize: 13),
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 2),
                  Text('${r['part_code'] ?? ''} · Machine: ${r['machine_name'] ?? ''}'),
                  Text('Operator: ${r['operator_name'] ?? ''} · Date: ${r['date']}'),
                ],
              ),
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '$goodQty OK',
                    style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.teal, fontSize: 14),
                  ),
                  Text('Prod: $prodQty | Rej: $rejQty', style: const TextStyle(fontSize: 10)),
                  const SizedBox(height: 2),
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
