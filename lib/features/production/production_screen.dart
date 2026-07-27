import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/master_data_providers.dart';
import '../../core/providers/batch_config_provider.dart';
import '../../core/providers/production_flow_provider.dart';
import '../../core/widgets/shared_widgets.dart';
import '../auth/auth_providers.dart';
import 'production_providers.dart';

class ProductionScreen extends ConsumerStatefulWidget {
  const ProductionScreen({super.key});

  @override
  ConsumerState<ProductionScreen> createState() => _ProductionScreenState();
}

class _SessionEntry {
  _SessionEntry({
    required this.operatorId,
    required this.operatorName,
    required this.machineIds,
    required this.machineNames,
    required this.machineCodes,
    required this.productionQty,
    required this.bpRejectQty,
    required this.status,
    required this.remarks,
  });

  final String operatorId;
  final String operatorName;
  final List<String> machineIds;
  final List<String> machineNames;
  final List<String> machineCodes;
  double productionQty;
  double bpRejectQty;
  String status;
  String remarks;

  double get goodQty => (productionQty - bpRejectQty).clamp(0, double.infinity);
}

class _ProductionScreenState extends ConsumerState<ProductionScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _formKey = GlobalKey<FormState>();

  String? _partId;
  String? _partCode;
  DateTime _recordedAt = DateTime.now();
  String? _wipBatchNumber; // set when continuing a WIP batch

  final List<_SessionEntry> _sessionEntries = [];

  bool _isSaving = false;
  String? _error;
  String? _success;
  List<String> _generatedBatches = [];

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

  Future<void> _saveAll() async {
    if (_partId == null) {
      setState(() => _error = 'Please select a Part first.');
      return;
    }
    if (_sessionEntries.isEmpty) {
      setState(() => _error = 'Please add at least one operator entry.');
      return;
    }

    setState(() { _isSaving = true; _error = null; _success = null; _generatedBatches = []; });

    try {
      final user = ref.read(currentUserProvider).value;
      final repo = ref.read(productionRepositoryProvider);
      final savedBatches = <String>[];

      bool anyWip = false;
      bool anyFinal = false;

      for (final entry in _sessionEntries) {
        for (int i = 0; i < entry.machineIds.length; i++) {
          final result = await repo.save(
            partId: _partId!,
            partCode: _partCode!,
            machineId: entry.machineIds[i],
            machineName: entry.machineNames[i],
            machineCode: entry.machineCodes[i],
            operatorId: entry.operatorId,
            machineStatusId: entry.status,
            productionQty: entry.productionQty,
            bpRejectQty: entry.bpRejectQty,
            remarks: entry.remarks.isEmpty ? null : entry.remarks,
            createdBy: user?.id ?? 'unknown',
            recordedAt: _recordedAt,
            wipBatchNumber: _wipBatchNumber,
          );
          if (result.success && result.batchNumber != null) {
            savedBatches.add(result.batchNumber!);
            if (result.isWip) anyWip = true; else anyFinal = true;
          } else if (!result.success) {
            throw Exception(result.error ?? 'Failed to save entry');
          }
        }
      }

      final msg = anyFinal && !anyWip
          ? '✅ Production complete! Added to BP Stock.'
          : anyWip && !anyFinal
              ? '⏳ Saved as WIP — not yet in BP Stock. Continue on next machine.'
              : '✅ Session saved (mixed WIP + final stages).';

      setState(() {
        _success = msg;
        _generatedBatches = savedBatches;
        _sessionEntries.clear();
      });
      ref.invalidate(productionListProvider);
      ref.invalidate(wipBatchesProvider);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _resetSession() {
    setState(() {
      _partId = null;
      _partCode = null;
      _wipBatchNumber = null;
      _recordedAt = DateTime.now();
      _sessionEntries.clear();
      _error = null;
      _success = null;
      _generatedBatches = [];
    });
  }

  void _showWipSuggestBanner(Map<String, dynamic> wip, ProductionFlowConfig flow) {
    final batchNumber = wip['batch_number'] as String? ?? '';
    final nextMachineId = wip['next_machine_id'] as String?;
    final machines = ref.read(machinesProvider).value ?? [];
    final nextMachineName = nextMachineId != null
        ? (machines.where((m) => m['id'] == nextMachineId).firstOrNull?['name'] as String? ?? 'Next Machine')
        : 'Next Machine';

    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 8),
        backgroundColor: Colors.orange.shade800,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('WIP Batch Found!', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
            Text('Batch $batchNumber needs $nextMachineName next.',
                style: const TextStyle(color: Colors.white70, fontSize: 12),),
          ],
        ),
        action: SnackBarAction(
          label: 'Continue',
          textColor: Colors.yellow,
          onPressed: () {
            setState(() {
              _wipBatchNumber = batchNumber;
            });
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Production Session'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.playlist_add), text: 'Session Entry'),
            Tab(icon: Icon(Icons.pending_actions_outlined), text: 'WIP'),
            Tab(icon: Icon(Icons.history), text: 'History'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [_buildSessionTab(), _buildWipTab(), _buildHistory()],
      ),
    );
  }

  Widget _buildSessionTab() {
    final parts = ref.watch(partsProvider);
    final theme = Theme.of(context);
    final showBatchNumber = ref.watch(batchConfigProvider);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // WIP batch banner — shown when continuing a WIP batch
          if (_wipBatchNumber != null)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.orange.withValues(alpha: 0.4)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.pending_actions_outlined, color: Colors.orange, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Continuing WIP Batch: $_wipBatchNumber',
                      style: const TextStyle(color: Colors.orange, fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _wipBatchNumber = null),
                    child: const Text('Clear', style: TextStyle(color: Colors.orange)),
                  ),
                ],
              ),
            ),
          // Date & Part Selection Card
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'SESSION DETAILS',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  RecordDateTimePicker(
                    value: _recordedAt,
                    onChanged: (dt) => setState(() => _recordedAt = dt),
                  ),
                  const SizedBox(height: 12),
                  parts.when(
                    loading: () => const LinearProgressIndicator(),
                    error: (e, _) => ErrorBanner('Parts load error: $e'),
                    data: (list) => AppDropdown<String>(
                      label: 'Session Part',
                      isRequired: true,
                      prefixIcon: const Icon(Icons.category_outlined),
                      value: _partId,
                      items: list.map((p) => DropdownMenuItem(
                        value: p['id'] as String,
                        child: Text('${p['code']} – ${p['name']}'),
                      ),).toList(),
                      onChanged: (v) {
                        if (v == null) return;
                        final part = list.firstWhere((p) => p['id'] == v);
                        final flow = ref.read(productionFlowProvider);
                        setState(() {
                          _partId = v;
                          _partCode = part['code'] as String;
                          _wipBatchNumber = null;
                        });
                        // Auto-detect WIP batch for this part
                        if (flow.isMultiStage) {
                          final wip = ref.read(productionRepositoryProvider)
                              .getWipBatchForPart(v, flow.requiredMachineIds);
                          if (wip != null) {
                            _showWipSuggestBanner(wip, flow);
                          }
                        }
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Session Entries Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'OPERATORS IN THIS SESSION',
                style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
              ),
              TextButton.icon(
                onPressed: _partId == null ? null : _showAddEntryDialog,
                icon: const Icon(Icons.add),
                label: const Text('Add Operator'),
              ),
            ],
          ),
          const SizedBox(height: 8),

          if (_sessionEntries.isEmpty)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
              decoration: BoxDecoration(
                border: Border.all(color: theme.colorScheme.outlineVariant),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Center(
                child: Column(
                  children: [
                    Icon(
                      Icons.people_outline,
                      size: 40,
                      color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _partId == null
                          ? 'Select a Part at the top to start'
                          : 'No operator entries in this session yet.\nTap "Add Operator" above.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                    ),
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
                  margin: const EdgeInsets.only(bottom: 8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
                  ),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    leading: CircleAvatar(
                      backgroundColor: theme.colorScheme.primaryContainer,
                      child: Text(entry.operatorName[0].toUpperCase()),
                    ),
                    title: Row(
                      children: [
                        Expanded(
                          child: Text(
                            entry.operatorName,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: entry.status == 'Running'
                                ? Colors.green.withValues(alpha: 0.15)
                                : entry.status == 'Breakdown'
                                    ? Colors.red.withValues(alpha: 0.15)
                                    : Colors.orange.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            entry.status,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: entry.status == 'Running'
                                  ? Colors.green
                                  : entry.status == 'Breakdown'
                                      ? Colors.red
                                      : Colors.orange,
                            ),
                          ),
                        ),
                      ],
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 4,
                          children: entry.machineNames
                              .map((m) => Chip(
                                    label: Text(m, style: const TextStyle(fontSize: 10)),
                                    padding: EdgeInsets.zero,
                                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                    visualDensity: VisualDensity.compact,
                                  ),)
                              .toList(),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Prod: ${entry.productionQty.toInt()} | Rej: ${entry.bpRejectQty.toInt()} | Good: ${entry.goodQty.toInt()} PCS',
                          style: TextStyle(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (entry.remarks.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text('Remarks: ${entry.remarks}', style: const TextStyle(fontSize: 11)),
                        ],
                      ],
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.edit_outlined, size: 20),
                          onPressed: () => _showAddEntryDialog(existingEntry: entry, index: idx),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
                          onPressed: () {
                            setState(() {
                              _sessionEntries.removeAt(idx);
                            });
                          },
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),

          if (_sessionEntries.isNotEmpty) ...[
            const SizedBox(height: 24),
            // Session Summary Box
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3)),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Total Production', style: TextStyle(fontWeight: FontWeight.w500)),
                      Text(
                        '${_sessionEntries.fold(0.0, (s, e) => s + e.productionQty).toInt()} PCS',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Total BP Rejects', style: TextStyle(fontWeight: FontWeight.w500)),
                      Text(
                        '${_sessionEntries.fold(0.0, (s, e) => s + e.bpRejectQty).toInt()} PCS',
                        style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.red),
                      ),
                    ],
                  ),
                  const Divider(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Total Good Quantity',
                        style: TextStyle(fontWeight: FontWeight.bold, color: theme.colorScheme.primary),
                      ),
                      Text(
                        '${_sessionEntries.fold(0.0, (s, e) => s + e.goodQty).toInt()} PCS',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: theme.colorScheme.primary),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 24),
          if (_error != null) ErrorBanner(_error!),
          if (_success != null) ...[
            SuccessBanner(_success!),
            if (_generatedBatches.isNotEmpty && showBatchNumber) ...[
              const SizedBox(height: 8),
              Card(
                color: theme.colorScheme.secondaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Generated Batches:',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _generatedBatches.join('\n'),
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _resetSession,
                  child: const Text('Reset Session'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _isSaving || _sessionEntries.isEmpty ? null : _saveAll,
                  child: _isSaving
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('Save Entire Session'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _buildWipTab() {
    final flow = ref.watch(productionFlowProvider);
    final wipAsync = ref.watch(wipBatchesProvider);
    final machines = ref.watch(machinesProvider);
    final theme = Theme.of(context);

    if (!flow.enabled) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.settings_outlined, size: 48, color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4)),
              const SizedBox(height: 12),
              const Text(
                'Multi-Machine Flow is disabled.\nEnable it in Settings → Production Flow.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return wipAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => EmptyState(message: 'Error: $e', icon: Icons.error_outline),
      data: (wips) {
        if (wips.isEmpty) {
          return const EmptyState(
            message: 'No WIP batches.\nAll batches are complete!',
            icon: Icons.check_circle_outline,
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.all(12),
          itemCount: wips.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final w = wips[i];
            final missingIds = (w['missing_machine_ids'] as List).cast<String>();
            final doneIds = (w['done_machine_ids'] as List).cast<String>();
            final allMachines = machines.value ?? [];

            String machineNameById(String id) {
              final m = allMachines.where((m) => m['id'] == id).firstOrNull;
              return m?['name'] as String? ?? id.substring(0, 6);
            }

            return Card(
              margin: const EdgeInsets.symmetric(vertical: 4),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.orange.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
                          ),
                          child: Text(
                            'BP Stock (Stage ${doneIds.length}/${doneIds.length + missingIds.length})',
                            style: const TextStyle(color: Colors.orange, fontWeight: FontWeight.bold, fontSize: 11),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            w['batch_number'] as String? ?? '—',
                            style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w600),
                          ),
                        ),
                        Text(
                          '${(w['total_qty'] as num?)?.toInt() ?? 0} PCS',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text('${w['part_code'] ?? ''} – ${w['part_name'] ?? ''} · ${w['date'] ?? ''}',
                        style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),),
                    const SizedBox(height: 8),
                    // Done machines
                    Wrap(
                      spacing: 6,
                      children: [
                        ...doneIds.map((id) => Chip(
                          avatar: const Icon(Icons.check_circle, size: 14, color: Colors.green),
                          label: Text(machineNameById(id), style: const TextStyle(fontSize: 11)),
                          backgroundColor: Colors.green.withValues(alpha: 0.1),
                          padding: EdgeInsets.zero,
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact,
                        ),),
                        ...missingIds.map((id) => Chip(
                          avatar: const Icon(Icons.pending_outlined, size: 14, color: Colors.orange),
                          label: Text(machineNameById(id), style: const TextStyle(fontSize: 11)),
                          backgroundColor: Colors.orange.withValues(alpha: 0.1),
                          padding: EdgeInsets.zero,
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact,
                        ),),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton.tonal(
                        onPressed: () {
                          setState(() {
                            _wipBatchNumber = w['batch_number'] as String?;
                            _partId = w['part_id'] as String?;
                            _partCode = w['part_code'] as String?;
                          });
                          _tabController.animateTo(0);
                        },
                        child: const Text('Continue This Batch'),
                      ),
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

  Widget _buildHistory() {
    final list = ref.watch(productionListProvider);
    return list.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => EmptyState(message: 'Error: $e', icon: Icons.error_outline),
      data: (records) {
        if (records.isEmpty) {
          return const EmptyState(
            message: 'No production entries yet.\nCreate your first entry.',
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
            return ListTile(
              leading: CircleAvatar(
                backgroundColor: Colors.teal.withValues(alpha: 0.12),
                child: const Icon(Icons.precision_manufacturing, color: Colors.teal, size: 20),
              ),
              title: Text(
                r['batch_number'] ?? '—',
                style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                '${r['machine_name'] ?? ''} · ${r['operator_name'] ?? ''} · ${r['date']}',
              ),
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('$goodQty ok', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.teal)),
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

  Future<void> _showAddEntryDialog({_SessionEntry? existingEntry, int? index}) async {
    final operatorsAsync = ref.read(operatorsProvider);
    final machinesAsync = ref.read(machinesProvider);

    final operators = operatorsAsync.value ?? [];
    final machines = machinesAsync.value ?? [];

    if (operators.isEmpty || machines.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Operators or Machines data is missing. Setup settings first.')),
      );
      return;
    }

    String? localOperatorId = existingEntry?.operatorId ?? (operators.isNotEmpty ? operators[0]['id'] as String : null);
    String? localOperatorName = existingEntry?.operatorName ?? (operators.isNotEmpty ? operators[0]['name'] as String : null);
    final List<String> localMachineIds = existingEntry != null ? List.from(existingEntry.machineIds) : [];
    final List<String> localMachineNames = existingEntry != null ? List.from(existingEntry.machineNames) : [];
    final List<String> localMachineCodes = existingEntry != null ? List.from(existingEntry.machineCodes) : [];

    final prodCtrl = TextEditingController(text: existingEntry?.productionQty.toInt().toString() ?? '');
    final rejectCtrl = TextEditingController(text: existingEntry?.bpRejectQty.toInt().toString() ?? '0');
    final remarksCtrl = TextEditingController(text: existingEntry?.remarks ?? '');
    String localStatus = existingEntry?.status ?? 'Running';

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            void quickAddProd(int val) {
              final curr = int.tryParse(prodCtrl.text) ?? 0;
              prodCtrl.text = (curr + val).toString();
              setDialogState(() {});
            }

            void quickAddReject(int val) {
              final curr = int.tryParse(rejectCtrl.text) ?? 0;
              rejectCtrl.text = (curr + val).clamp(0, 99999).toString();
              setDialogState(() {});
            }

            return AlertDialog(
              title: Text(existingEntry == null ? 'Add Operator Production' : 'Edit Operator Production'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Operator Dropdown
                    AppDropdown<String>(
                      label: 'Operator',
                      isRequired: true,
                      value: localOperatorId,
                      items: operators.map((o) => DropdownMenuItem(
                        value: o['id'] as String,
                        child: Text(o['name'] as String),
                      ),).toList(),
                      onChanged: (v) {
                        if (v == null) return;
                        final match = operators.firstWhere((o) => o['id'] == v);
                        setDialogState(() {
                          localOperatorId = v;
                          localOperatorName = match['name'] as String;
                        });
                      },
                    ),
                    const SizedBox(height: 12),

                    // Machine Multi-select Filter Chips
                    const Text(
                      'Running Machine(s)',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                    const SizedBox(height: 6),
                    Builder(builder: (context) {
                      final flow = ref.read(productionFlowProvider);
                      return Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: machines.map((m) {
                          final mId = m['id'] as String;
                          final mName = m['name'] as String;
                          final mCode = m['machine_code'] as String? ?? mId.substring(0, 1);
                          final isSelected = localMachineIds.contains(mId);
                          final seqIdx = flow.isMultiStage ? flow.getMachineSequenceIndex(mId) : 0;
                          final isFinal = flow.isMultiStage && flow.isFinalMachine(mId);
                          return FilterChip(
                            label: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(mName),
                                if (seqIdx > 0) ...[
                                  const SizedBox(width: 4),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: isFinal ? Colors.green.withValues(alpha: 0.2) : Colors.orange.withValues(alpha: 0.2),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      isFinal ? 'Final' : 'WIP',
                                      style: TextStyle(
                                        fontSize: 9,
                                        fontWeight: FontWeight.bold,
                                        color: isFinal ? Colors.green : Colors.orange,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            selected: isSelected,
                            onSelected: (selected) {
                              setDialogState(() {
                                if (selected) {
                                  localMachineIds.add(mId);
                                  localMachineNames.add(mName);
                                  localMachineCodes.add(mCode);
                                } else {
                                  localMachineIds.remove(mId);
                                  localMachineNames.remove(mName);
                                  localMachineCodes.remove(mCode);
                                }
                              });
                            },
                          );
                        }).toList(),
                      );
                    }),
                    const SizedBox(height: 12),

                    // Status Dropdown
                    AppDropdown<String>(
                      label: 'Status / Condition',
                      isRequired: true,
                      value: localStatus,
                      items: kMachineStatuses.map((s) => DropdownMenuItem(
                        value: s,
                        child: Text(s),
                      ),).toList(),
                      onChanged: (v) => setDialogState(() => localStatus = v ?? 'Running'),
                    ),
                    const SizedBox(height: 12),

                    // Production Qty input with quick adjusters
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: prodCtrl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Production Qty (PCS)',
                              prefixIcon: Icon(Icons.factory_outlined),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 4,
                      children: [50, 100, 200, 500].map((val) => ActionChip(
                        label: Text('+$val'),
                        onPressed: () => quickAddProd(val),
                      ),).toList(),
                    ),
                    const SizedBox(height: 12),

                    // Reject Qty input with quick adjusters
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: rejectCtrl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'BP Reject Qty (PCS)',
                              prefixIcon: Icon(Icons.cancel_outlined),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 4,
                      children: [1, 5, 10, 20].map((val) => ActionChip(
                        label: Text('+$val'),
                        onPressed: () => quickAddReject(val),
                      ),).toList(),
                    ),
                    const SizedBox(height: 12),

                    // Remarks
                    TextFormField(
                      controller: remarksCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Remarks (optional)',
                        prefixIcon: Icon(Icons.notes),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () {
                    if (localOperatorId == null || localMachineIds.isEmpty) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        const SnackBar(content: Text('Please select operator and at least one machine.')),
                      );
                      return;
                    }
                    if (int.tryParse(prodCtrl.text) == null) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        const SnackBar(content: Text('Enter valid production quantity.')),
                      );
                      return;
                    }
                    Navigator.pop(ctx, true);
                  },
                  child: const Text('Add to List'),
                ),
              ],
            );
          },
        );
      },
    );

    if (result == true) {
      final double prod = double.parse(prodCtrl.text);
      final double rej = double.tryParse(rejectCtrl.text) ?? 0;

      final newEntry = _SessionEntry(
        operatorId: localOperatorId!,
        operatorName: localOperatorName!,
        machineIds: localMachineIds,
        machineNames: localMachineNames,
        machineCodes: localMachineCodes,
        productionQty: prod,
        bpRejectQty: rej,
        status: localStatus,
        remarks: remarksCtrl.text.trim(),
      );

      setState(() {
        if (index != null) {
          _sessionEntries[index] = newEntry;
        } else {
          _sessionEntries.add(newEntry);
        }
      });
    }

    prodCtrl.dispose();
    rejectCtrl.dispose();
    remarksCtrl.dispose();
  }
}
