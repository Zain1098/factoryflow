import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/master_data_providers.dart';
import '../../core/providers/production_flow_provider.dart';
import '../../core/widgets/shared_widgets.dart';
import '../auth/auth_providers.dart';
import 'production_repository.dart';


class ProductionScreen extends ConsumerStatefulWidget {
  const ProductionScreen({super.key});

  @override
  ConsumerState<ProductionScreen> createState() => _ProductionScreenState();
}

class _ProductionScreenState extends ConsumerState<ProductionScreen> {
  // Form State
  String? _partId;
  String? _partCode;
  DateTime _recordedAt = DateTime.now();
  late String _shiftId;

  // WIP Continuation State
  String? _wipBatchNumber;
  double? _wipLastGoodQty;
  List<String> _wipDoneMachineIds = [];

  // Session Machine Entries (Entries to be saved in one batch job)
  final List<MachineEntry> _sessionEntries = [];

  // Async & Notification State
  bool _isSaving = false;
  bool _isFlowReady = false;
  bool _didRepairFlow = false;
  String? _flowSetupError;
  String? _error;
  String? _success;
  String? _renderingError;
  void Function(FlutterErrorDetails details)? _previousFlutterErrorHandler;
  late void Function(FlutterErrorDetails details)
      _productionFlutterErrorHandler;

  @override
  void initState() {
    super.initState();
    _shiftId = _suggestShift(DateTime.now());

    // Keep Flutter's normal error reporting, while also showing a concise
    // diagnostic on this screen instead of leaving the operator with a blank
    // production page. It is restored when this route is closed.
    _previousFlutterErrorHandler = FlutterError.onError;
    _productionFlutterErrorHandler = (details) {
      _previousFlutterErrorHandler?.call(details);
      if (!mounted) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _renderingError = details.exceptionAsString();
        });
      });
    };
    FlutterError.onError = _productionFlutterErrorHandler;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _prepareProductionFlow();
    });
  }

  @override
  void dispose() {
    if (FlutterError.onError == _productionFlutterErrorHandler) {
      FlutterError.onError = _previousFlutterErrorHandler;
    }
    super.dispose();
  }

  String _suggestShift(DateTime dateTime) {
    final hour = dateTime.hour;
    // Default shift suggestion by time — actual shift IDs come from DB
    if (hour >= 6 && hour < 14) return 'A';
    if (hour >= 14 && hour < 22) return 'B';
    return 'C';
  }

  bool _isToday(DateTime dt) {
    final now = DateTime.now();
    return dt.year == now.year && dt.month == now.month && dt.day == now.day;
  }

  String _formatDate(DateTime dt) =>
      '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}';

  void _setShift(String shift) => setState(() => _shiftId = shift);

  Future<void> _prepareProductionFlow() async {
    try {
      final notifier = ref.read(productionFlowProvider.notifier);
      await notifier.ensureLoaded();
      if (!mounted) return;

      if (notifier.loadError != null) {
        setState(() {
          _flowSetupError = notifier.loadError;
          _isFlowReady = true;
        });
        return;
      }

      var flow = ref.read(productionFlowProvider);
      final machines = await ref.read(machinesProvider.future);
      if (!mounted) return;

      final repairedFlow = repairProductionFlowConfig(flow, machines);
      if (!identical(repairedFlow, flow)) {
        flow = repairedFlow;
        await notifier.save(flow);
        _didRepairFlow = true;
      }

      setState(() {
        _flowSetupError = flow.validationError;
        _isFlowReady = true;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _flowSetupError =
            'Production setup could not be verified. Check Settings and retry. Details: $error';
        _isFlowReady = true;
      });
    }
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
    final flowError = flow.validationError ?? _flowSetupError;
    if (!_isFlowReady || flowError != null) {
      setState(() {
        _error = flowError ?? 'Production setup is still loading. Please wait.';
      });
      return;
    }

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
          ? 'Saved as WIP. Continue this batch at the next machine.'
          : 'Batch complete. $finalGoodQty PCS is ready for BP / Vendor.';

      setState(() {
        _success = msg;
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
    final matchingParts = parts.where((part) => part['id'] == val);
    if (matchingParts.isEmpty) {
      setState(() {
        _error =
            'The selected part is no longer available. Please select it again.';
      });
      return;
    }
    final match = matchingParts.first;
    final partCode = match['code'] as String?;
    if (partCode == null || partCode.isEmpty) {
      setState(() {
        _error =
            'The selected part has no valid part code. Please update master data.';
      });
      return;
    }
    final flow = ref.read(productionFlowProvider);

    setState(() {
      _partId = val;
      _partCode = partCode;
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
                  style: TextStyle(
                      fontWeight: FontWeight.bold, color: Colors.white,),
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

    // The WIP list is opened as an on-demand sheet, so returning to the
    // underlying entry form is enough after selecting a batch.
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Daily Production'),
        elevation: 1,
        actions: [
          IconButton(
            icon: const Icon(Icons.pending_actions_outlined),
            tooltip: 'Open WIP Batches',
            onPressed: _showWipSheet,
          ),
          IconButton(
            icon: const Icon(Icons.history_outlined),
            tooltip: 'Production History',
            onPressed: _showHistorySheet,
          ),
        ],
      ),
      body: _buildSafeEntryPage(),
    );
  }

  /// Initial production entry view deliberately uses a bounded ListView.
  /// It avoids the nested intrinsic-width flex layout that previously left the
  /// rendering tree incomplete and made the whole page appear blank.
  Widget _buildSafeEntryPage() {
    final partsAsync = ref.watch(partsProvider);
    // Keep the modal's dependent master data alive and loading while the user
    // selects a part. Reading an unwatched FutureProvider from the button tap
    // otherwise restarts it in a loading state on every attempt.
    final machinesAsync = ref.watch(machinesProvider);
    final operatorsAsync = ref.watch(operatorsProvider);
    final isMasterDataLoading =
        machinesAsync.isLoading || operatorsAsync.isLoading;
    final masterDataError = machinesAsync.hasError || operatorsAsync.hasError;
    final flow = ref.watch(productionFlowProvider);
    final rawMaterialAsync = _partId == null
        ? null
        : ref.watch(productionRawMaterialProvider(_partId!));
    final hasWipInput = _wipBatchNumber != null && (_wipLastGoodQty ?? 0) > 0;
    final rawMaterialQty = rawMaterialAsync?.value;
    final hasRawInput = rawMaterialQty != null && rawMaterialQty > 0;
    final inputStockLoading =
        _partId != null && (rawMaterialAsync?.isLoading ?? true);
    final inputStockError = rawMaterialAsync?.hasError ?? false;
    final canAddMachine = _isFlowReady &&
        _flowSetupError == null &&
        _partId != null &&
        !isMasterDataLoading &&
        !masterDataError &&
        !inputStockLoading &&
        !inputStockError &&
        (hasWipInput || hasRawInput);
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_renderingError != null) ...[
          Card(
            color: theme.colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline,
                      color: theme.colorScheme.onErrorContainer,),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SelectableText(
                      'Screen diagnostic: $_renderingError',
                      style:
                          TextStyle(color: theme.colorScheme.onErrorContainer),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (!_isFlowReady)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Row(
                children: [
                  SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 12),
                  Expanded(child: Text('Verifying production workflow…')),
                ],
              ),
            ),
          )
        else if (_flowSetupError != null)
          Card(
            color: theme.colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                _flowSetupError!,
                style: TextStyle(color: theme.colorScheme.onErrorContainer),
              ),
            ),
          )
        else
          Card(
            color: theme.colorScheme.primaryContainer.withValues(alpha: 0.45),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  const Icon(Icons.account_tree_outlined),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      flow.isMultiStage
                          ? 'Active route: ${_productionRouteLabel(flow, machinesAsync.value ?? const [])}'
                          : 'Active route: Raw Material → Finished Production',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (_didRepairFlow) ...[
          const SizedBox(height: 8),
          const Text(
            'Production machine sequence was repaired from active master data.',
            style: TextStyle(color: Colors.green, fontWeight: FontWeight.w600),
          ),
        ],
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Production details', style: theme.textTheme.titleMedium),
                const SizedBox(height: 12),
                RecordDateTimePicker(
                  value: _recordedAt,
                  onChanged: (dt) => setState(() {
                    _recordedAt = dt;
                    _shiftId = _suggestShift(dt);
                  }),
                ),
                if (!_isToday(_recordedAt)) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.orange.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.orange.withValues(alpha: 0.4)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 16),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Backdated entry: ${_recordedAt.day == DateTime.now().subtract(const Duration(days: 1)).day ? 'Yesterday' : _formatDate(_recordedAt)}. Tap date to correct.',
                            style: const TextStyle(fontSize: 12, color: Colors.orange, fontWeight: FontWeight.w500),
                          ),
                        ),
                        TextButton(
                          style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8), minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                          onPressed: () => setState(() {
                            _recordedAt = DateTime.now();
                            _shiftId = _suggestShift(_recordedAt);
                          }),
                          child: const Text('Use Today', style: TextStyle(fontSize: 11)),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                SegmentedButton<String>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 'A', label: Text('Shift A')),
                    ButtonSegment(value: 'B', label: Text('Shift B')),
                    ButtonSegment(value: 'C', label: Text('Shift C')),
                  ],
                  selected: {_shiftId},
                  onSelectionChanged: (value) => _setShift(value.first),
                ),
                const SizedBox(height: 16),
                partsAsync.when(
                  loading: () => const LinearProgressIndicator(),
                  error: (error, _) => Text('Parts could not load: $error'),
                  data: (parts) => OutlinedButton.icon(
                    icon: const Icon(Icons.category_outlined),
                    label: Text(_partId == null
                        ? 'Select finished part'
                        : _partCode ?? 'Selected part',),
                    onPressed: () => _pickPart(parts),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_partId != null) ...[
          const SizedBox(height: 12),
          rawMaterialAsync!.when(
            loading: () => const LinearProgressIndicator(),
            error: (error, _) => Text(
              'Input stock could not be checked: $error',
              style: TextStyle(color: theme.colorScheme.error),
            ),
            data: (rawQty) {
              final availableQty = hasWipInput ? _wipLastGoodQty! : rawQty;
              final available = availableQty > 0;
              return Card(
                color: (available ? Colors.teal : Colors.red)
                    .withValues(alpha: 0.10),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      Icon(
                        available
                            ? Icons.inventory_2_outlined
                            : Icons.warning_amber_outlined,
                        color: available
                            ? Colors.teal.shade800
                            : Colors.red.shade700,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          available
                              ? '${hasWipInput ? 'Previous-stage WIP' : 'Raw material'} available: ${availableQty.toInt()} PCS'
                              : 'No raw material is available for $_partCode. Receive material before entering production.',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
        const SizedBox(height: 16),
        Text('Machine entries', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        if (_sessionEntries.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                  'Select a part, then add each machine stage for this batch.',),
            ),
          )
        else
          ..._sessionEntries.map(
            (entry) {
              final entryIndex = _sessionEntries.indexOf(entry);
              return Card(
                child: ListTile(
                  title: Text(entry.machineName),
                  subtitle: Text(
                      '${entry.operatorName} · Input ${entry.productionQty.toInt()} · OK ${entry.goodQty.toInt()}',),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('${entry.rejectQty.toInt()} reject'),
                      IconButton(
                        icon: const Icon(Icons.edit_outlined),
                        tooltip: 'Edit machine entry',
                        onPressed: () => _showAddEntryModal(
                          existingEntry: entry,
                          index: entryIndex,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: 'Remove machine entry',
                        onPressed: () => setState(
                          () => _sessionEntries.removeAt(entryIndex),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: canAddMachine ? _showAddEntryModal : null,
          icon: isMasterDataLoading
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.add),
          label: Text(isMasterDataLoading
              ? 'Loading machines and operators…'
              : 'Add machine entry',),
        ),
        if (masterDataError) ...[
          const SizedBox(height: 8),
          Text(
            'Machines or operators could not load. Check Settings, then retry.',
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ],
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _isSaving || _sessionEntries.isEmpty ? null : _saveAll,
          icon: const Icon(Icons.save_outlined),
          label: Text(_isSaving ? 'Saving…' : 'Save production job'),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
        ],
        if (_success != null) ...[
          const SizedBox(height: 12),
          Text(_success!, style: const TextStyle(color: Colors.green)),
        ],
      ],
    );
  }

  String _productionRouteLabel(
    ProductionFlowConfig flow,
    List<Map<String, dynamic>> machines,
  ) {
    final namesById = {
      for (final machine in machines)
        if (machine['id'] is String)
          machine['id'] as String:
              machine['name'] as String? ?? 'Unnamed machine',
    };
    final names = flow.requiredMachineIds
        .map((id) => namesById[id] ?? 'Unavailable machine')
        .toList(growable: false);
    return ['Raw Material', ...names, 'Finished Production'].join(' → ');
  }

  Future<void> _pickPart(List<Map<String, dynamic>> parts) async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          children: parts
              .map((part) => ListTile(
                    title: Text('${part['code']} – ${part['name']}'),
                    onTap: () => Navigator.pop(context, part['id'] as String),
                  ),)
              .toList(),
        ),
      ),
    );
    if (selected != null && mounted) _onPartChanged(selected, parts);
  }

  void _showWipSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.82,
        child: _buildWipTab(),
      ),
    );
  }

  void _showHistorySheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.82,
        child: _buildHistoryTab(),
      ),
    );
  }


  Future<void> _showAddEntryModal(
      {MachineEntry? existingEntry, int? index,}) async {
    final operatorsAsync = ref.read(operatorsProvider);
    final machinesAsync = ref.read(machinesProvider);
    final flow = ref.read(productionFlowProvider);

    final operators = operatorsAsync.value ?? [];
    final machines = machinesAsync.value ?? [];

    if (operatorsAsync.isLoading || machinesAsync.isLoading) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Master data is still loading. Please try again.'),),
      );
      return;
    }

    if (operatorsAsync.hasError || machinesAsync.hasError) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Could not load operators or machines. Check Settings and try again.',),
        ),
      );
      return;
    }

    if (operators.isEmpty || machines.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Operators or Machines data missing in Settings.'),),
      );
      return;
    }

    final defaultOperator = operators.first;
    final existingOperatorAvailable = existingEntry != null &&
        operators.any((operator) => operator['id'] == existingEntry.operatorId);
    String localOperatorId = existingOperatorAvailable
        ? existingEntry.operatorId
        : defaultOperator['id'] as String;
    String localOperatorName = existingOperatorAvailable
        ? existingEntry.operatorName
        : defaultOperator['name'] as String;

    // Filter available machines
    final List<Map<String, dynamic>> seqMachines =
        flow.isMultiStage && flow.requiredMachineIds.isNotEmpty
            ? flow.requiredMachineIds
                .map((id) => machines.firstWhere((m) => m['id'] == id,
                    orElse: () => <String, dynamic>{},),)
                .where((m) => m.isNotEmpty)
                .toList()
            : machines;

    if (seqMachines.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No usable machines are configured for this production flow. Update Settings, then try again.',
          ),
        ),
      );
      return;
    }

    final existingMachineAvailable = existingEntry != null &&
        seqMachines.any((machine) => machine['id'] == existingEntry.machineId);

    // Determine default machine selection
    final lastSessionMachineId = _sessionEntries.isNotEmpty
        ? _sessionEntries.last.machineId
        : null;
    final nextSessionMachineId = lastSessionMachineId == null
        ? null
        : flow.getNextMachineId(lastSessionMachineId);
    final firstUnusedMachineId = seqMachines
        .map((machine) => machine['id'] as String)
        .firstWhere(
          (machineId) =>
              !_sessionEntries.any((entry) => entry.machineId == machineId),
          orElse: () => seqMachines.first['id'] as String,
        );
    String localMachineId = existingMachineAvailable
        ? existingEntry.machineId
        : (_wipDoneMachineIds.isNotEmpty
            ? (flow.getNextMachineId(_wipDoneMachineIds.last) ??
                firstUnusedMachineId)
            : (nextSessionMachineId ?? firstUnusedMachineId));

    // Carry the previous stage's operator forward as a suggestion. The user
    // can always choose someone else; this simply removes repeated taps for
    // one person running consecutive machines.
    Map<String, dynamic>? previousStageOperator(String machineId) {
      if (!flow.isMultiStage) return null;
      final sequenceIndex = flow.getMachineSequenceIndex(machineId);
      if (sequenceIndex <= 1) return null;
      final previousMachineId = flow.requiredMachineIds[sequenceIndex - 2];
      MachineEntry? previousEntry;
      for (final entry in _sessionEntries.reversed) {
        if (entry.machineId == previousMachineId) {
          previousEntry = entry;
          break;
        }
      }
      if (previousEntry == null) return null;
      for (final operator in operators) {
        if (operator['id'] == previousEntry.operatorId) return operator;
      }
      return null;
    }

    final suggestedOperator =
        existingEntry == null ? previousStageOperator(localMachineId) : null;
    if (suggestedOperator != null) {
      localOperatorId = suggestedOperator['id'] as String;
      localOperatorName = suggestedOperator['name'] as String;
    }

    // Calculate maximum allowed production qty based on previous stage
    double? maxAllowedProdQty;
    if (_wipLastGoodQty != null) {
      maxAllowedProdQty = _wipLastGoodQty;
    } else if (index != null && index > 0) {
      maxAllowedProdQty = _sessionEntries[index - 1].goodQty;
    } else if (index == null && _sessionEntries.isNotEmpty) {
      maxAllowedProdQty = _sessionEntries.last.goodQty;
    }

    // A first-stage entry must also be bounded by currently available raw
    // material. This prevents an apparently valid quantity (for example 450)
    // from failing only after the operator presses Save.
    if (maxAllowedProdQty == null && _partId != null) {
      try {
        maxAllowedProdQty = await ref.read(
          productionRawMaterialProvider(_partId!).future,
        );
      } catch (_) {
        // The save path performs the authoritative stock check. Keep the
        // modal usable if the read-only preview is temporarily unavailable.
      }
    }

    if (!mounted) return;

    // Availability is only a limit; actual output must always be entered by
    // the user because a machine can produce less than available material.
    final initialProductionQty = existingEntry != null
        ? existingEntry.productionQty.toInt().toString()
        : '';
    final initialRejectQty = existingEntry != null
        ? existingEntry.rejectQty.toInt().toString()
        : '0';
    String localStatus = existingEntry?.status ?? 'Running';

    final savedEntry = await showModalBottomSheet<MachineEntry>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _MachineEntryControllerScope(
        initialProductionQty: initialProductionQty,
        initialRejectQty: initialRejectQty,
        initialRemarks: existingEntry?.remarks ?? '',
        builder: (prodCtrl, rejectCtrl, remarksCtrl) => StatefulBuilder(
          builder: (ctx, setModalState) {
            final selectedMachine = machines.firstWhere(
                (m) => m['id'] == localMachineId,
                orElse: () => machines.first,);
            final mName = selectedMachine['name'] as String? ?? 'Machine';
            final mCode = selectedMachine['machine_code'] as String? ??
                mName.substring(0, 1);
            final seqIdx = flow.isMultiStage
                ? flow.getMachineSequenceIndex(localMachineId)
                : 0;
            final isFinal =
                flow.isMultiStage ? flow.isFinalMachine(localMachineId) : true;
            final previousMachineName = seqIdx > 1
                ? (machines.firstWhere(
                      (m) => m['id'] == flow.requiredMachineIds[seqIdx - 2],
                      orElse: () => <String, dynamic>{},
                    )['name'] as String? ??
                    'Previous Machine')
                : null;
            final inputLocation = previousMachineName == null
                ? 'Raw Material'
                : '$previousMachineName WIP';
            final outputLocation =
                isFinal ? 'Finished Production' : '$mName WIP';

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
                  bottom: MediaQuery.of(ctx).viewInsets.bottom,
                ),
                child: SizedBox(
                  width: double.infinity,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              existingEntry == null
                                  ? 'Add Machine Entry'
                                  : 'Edit Machine Entry',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(
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

                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Theme.of(ctx)
                                .colorScheme
                                .primaryContainer
                                .withValues(alpha: 0.45),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.account_tree_outlined,
                                  color: Theme.of(ctx).colorScheme.primary,),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '$inputLocation  →  $outputLocation',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 12,),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      'Good output moves automatically. Rejects go to Production Rejected.',
                                      style: TextStyle(
                                        color: Theme.of(ctx)
                                            .colorScheme
                                            .onSurfaceVariant,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 14),

                        // Operator Dropdown
                        AppDropdown<String>(
                          label: 'Operator Name',
                          isRequired: true,
                          prefixIcon: const Icon(Icons.person_outline),
                          value: localOperatorId,
                          items: operators
                              .map(
                                (o) => DropdownMenuItem(
                                  value: o['id'] as String,
                                  child: Text(o['name'] as String),
                                ),
                              )
                              .toList(),
                          onChanged: (v) {
                            if (v == null) return;
                            final match =
                                operators.firstWhere((o) => o['id'] == v);
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
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 13,),
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
                            final sIdx = flow.isMultiStage
                                ? flow.getMachineSequenceIndex(mId)
                                : 0;
                            final isFinalM =
                                flow.isMultiStage && flow.isFinalMachine(mId);

                            return ChoiceChip(
                              label: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (sIdx > 0) ...[
                                    Text('#$sIdx ',
                                        style: const TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,),),
                                  ],
                                  Text(name),
                                  if (isDone) ...[
                                    const SizedBox(width: 4),
                                    const Icon(Icons.check_circle,
                                        size: 14, color: Colors.green,),
                                  ] else if (isFinalM) ...[
                                    const SizedBox(width: 4),
                                    const Icon(Icons.star,
                                        size: 12, color: Colors.amber,),
                                  ],
                                ],
                              ),
                              selected: isSelected,
                              onSelected: (selected) {
                                if (selected) {
                                  setModalState(() {
                                    localMachineId = mId;
                                    if (existingEntry == null) {
                                      final suggested = previousStageOperator(mId);
                                      if (suggested != null) {
                                        localOperatorId = suggested['id'] as String;
                                        localOperatorName = suggested['name'] as String;
                                      }
                                    }
                                  });
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
                              .map((s) =>
                                  DropdownMenuItem(value: s, child: Text(s)),)
                              .toList(),
                          onChanged: (v) =>
                              setModalState(() => localStatus = v ?? 'Running'),
                        ),
                        const SizedBox(height: 14),

                        // Input Quantity Field
                        TextFormField(
                          controller: prodCtrl,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: 'Input Quantity (PCS)',
                            helperText: 'Material consumed from $inputLocation',
                            prefixIcon: const Icon(Icons.input_outlined),
                            suffixText: maxAllowedProdQty != null
                                ? 'Max: ${maxAllowedProdQty.toInt()}'
                                : null,
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
                          decoration: InputDecoration(
                            labelText: 'Reject Quantity (PCS)',
                            helperText:
                                'Moves automatically to Production Rejected',
                            errorText: rejVal > prodVal
                                ? 'Reject quantity cannot exceed input quantity.'
                                : null,
                            prefixIcon: const Icon(Icons.cancel_outlined,
                                color: Colors.red,),
                            border: const OutlineInputBorder(),
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
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10,),
                          decoration: BoxDecoration(
                            color: Colors.teal.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                                color: Colors.teal.withValues(alpha: 0.3),),
                          ),
                          child: Row(
                            children: [
                              const Expanded(
                                child: Text(
                                  'Good Output (automatic):',
                                  style: TextStyle(fontWeight: FontWeight.w600),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '${goodVal.toInt()} PCS',
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                    color: Colors.teal,),
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
                            final enteredProd =
                                double.tryParse(prodCtrl.text) ?? 0.0;
                            final enteredRej =
                                double.tryParse(rejectCtrl.text) ?? 0.0;

                            if (enteredProd <= 0) {
                              ScaffoldMessenger.of(ctx).showSnackBar(
                                const SnackBar(
                                    content: Text(
                                        'Please enter a valid production quantity (> 0).',),),
                              );
                              return;
                            }

                            if (enteredRej > enteredProd) {
                              ScaffoldMessenger.of(ctx).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                      'Reject quantity cannot exceed input quantity.',),
                                ),
                              );
                              return;
                            }

                            if (maxAllowedProdQty != null &&
                                enteredProd > maxAllowedProdQty) {
                              ScaffoldMessenger.of(ctx).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'Production Qty (${enteredProd.toInt()}) exceeds previous stage good Qty (${maxAllowedProdQty.toInt()} PCS).',
                                  ),
                                ),
                              );
                              return;
                            }

                            final duplicateMachine = _sessionEntries.any(
                              (entry) =>
                                  entry.machineId == localMachineId &&
                                  entry != existingEntry,
                            );
                            if (duplicateMachine) {
                              ScaffoldMessenger.of(ctx).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'This machine is already added for this batch. Select the next machine stage.',
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
                              shiftId: _shiftId,
                              productionQty: enteredProd,
                              rejectQty: enteredRej,
                              status: localStatus,
                              remarks: remarksCtrl.text.trim(),
                            );

                            Navigator.pop(ctx, entry);
                          },
                          child: Text(existingEntry == null
                              ? 'Add Machine Entry to List'
                              : 'Update Machine Entry',),
                        ),
                        const SizedBox(height: 10),
                      ],
                    ),
                  ),
                ),);
          },
        ),
      ),
    );

    if (!mounted || savedEntry == null) return;
    setState(() {
      if (index != null) {
        _sessionEntries[index] = savedEntry;
      } else {
        _sessionEntries.add(savedEntry);
      }
    });
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
              Icon(Icons.settings_outlined,
                  size: 54,
                  color: theme.colorScheme.onSurfaceVariant
                      .withValues(alpha: 0.4),),
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
      error: (e, _) => EmptyState(
          message: 'Error loading WIP batches: $e', icon: Icons.error_outline,),
      data: (wips) {
        if (wips.isEmpty) {
          return const EmptyState(
            message:
                'No open WIP batches!\nAll production batches are fully completed.',
            icon: Icons.check_circle_outline,
          );
        }

        final machines = machinesAsync.value ?? [];
        String getMachineName(String id) {
          final m = machines.firstWhere((m) => m['id'] == id,
              orElse: () => <String, dynamic>{},);
          return m['name'] as String? ?? id.substring(0, 6);
        }

        return ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: wips.length,
          itemBuilder: (context, i) {
            final w = wips[i];
            final batchNum = w['batch_number'] as String? ?? '';
            final doneIds =
                (w['done_machine_ids'] as List? ?? []).cast<String>();
            final missingIds =
                (w['missing_machine_ids'] as List? ?? []).cast<String>();
            final lastGood = (w['last_good_qty'] as num?)?.toInt() ?? 0;

            final totalStages = doneIds.length + missingIds.length;
            final currentStageNum = doneIds.length;

            return Card(
              margin: const EdgeInsets.only(bottom: 12),
              elevation: 0.5,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(
                    color: Colors.amber.shade700.withValues(alpha: 0.4),),
              ),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4,),
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
                      style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurfaceVariant,),
                    ),
                    const SizedBox(height: 12),

                    // Stage Progress Chips
                    const Text('Stage Progress:',
                        style: TextStyle(
                            fontSize: 11, fontWeight: FontWeight.bold,),),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        ...doneIds.map(
                          (id) => Chip(
                            avatar: const Icon(Icons.check_circle,
                                size: 14, color: Colors.green,),
                            label: Text(getMachineName(id),
                                style: const TextStyle(fontSize: 11),),
                            backgroundColor:
                                Colors.green.withValues(alpha: 0.12),
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                          ),
                        ),
                        ...missingIds.map(
                          (id) => Chip(
                            avatar: const Icon(Icons.hourglass_empty,
                                size: 14, color: Colors.amber,),
                            label: Text(getMachineName(id),
                                style: const TextStyle(fontSize: 11),),
                            backgroundColor:
                                Colors.amber.withValues(alpha: 0.12),
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        TextButton.icon(
                          onPressed: () => _showBatchTrailSheet(batchNum),
                          icon: const Icon(Icons.remove_red_eye_outlined,
                              size: 16,),
                          label: const Text('View History Trail',
                              style: TextStyle(fontSize: 12),),
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
      isScrollControlled: true, // Allow sheet to take more than half screen
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return Padding(
          padding:
              EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Flexible(
                        // Wrap with Flexible to prevent overflow if batchNumber is long
                        child: Text(
                          'Batch Trail: $batchNumber',
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 14,),
                          overflow: TextOverflow.ellipsis,
                        ),
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
                      padding: EdgeInsets.symmetric(vertical: 40),
                      child: Center(child: Text('No stage records found.')),
                    )
                  else
                    ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: records.length,
                      itemBuilder: (context, idx) {
                        final r = records[idx];
                        return ListTile(
                          leading: CircleAvatar(
                            child: Text('${idx + 1}'),
                          ),
                          title: Text(
                              '${r['machine_name']} (${r['operator_name']})',),
                          subtitle: Text(
                              'Date: ${r['date']} ${r['time'] ?? ''} · Status: ${r['machine_status_id']}',),
                          trailing: Text(
                            '${(r['good_qty'] as num?)?.toInt() ?? 0} OK',
                            style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.teal,),
                          ),
                        );
                      },
                    ),
                ],
              ),
            ),
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
      error: (e, _) =>
          EmptyState(message: 'Error: $e', icon: Icons.error_outline),
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
                child: const Icon(Icons.precision_manufacturing,
                    color: Colors.teal, size: 20,),
              ),
              title: Text(
                r['batch_number'] ?? '—',
                style: const TextStyle(
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.bold,
                    fontSize: 13,),
              ),
              subtitle: Text(
                '${r['part_code'] ?? ''} · ${r['machine_name'] ?? ''}\nOperator: ${r['operator_name'] ?? ''} · ${r['date']}',
              ),
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '$goodQty OK',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.teal,
                        fontSize: 14,),
                  ),
                  Text('Prod: $prodQty | Rej: $rejQty',
                      style: const TextStyle(fontSize: 10),),
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

/// Owns the sheet-only controllers so Flutter disposes them only after the
/// bottom-sheet route has fully removed its text fields.
class _MachineEntryControllerScope extends StatefulWidget {
  const _MachineEntryControllerScope({
    required this.initialProductionQty,
    required this.initialRejectQty,
    required this.initialRemarks,
    required this.builder,
  });

  final String initialProductionQty;
  final String initialRejectQty;
  final String initialRemarks;
  final Widget Function(
    TextEditingController productionController,
    TextEditingController rejectController,
    TextEditingController remarksController,
  ) builder;

  @override
  State<_MachineEntryControllerScope> createState() =>
      _MachineEntryControllerScopeState();
}

class _MachineEntryControllerScopeState
    extends State<_MachineEntryControllerScope> {
  late final TextEditingController _productionController;
  late final TextEditingController _rejectController;
  late final TextEditingController _remarksController;

  @override
  void initState() {
    super.initState();
    _productionController = TextEditingController(
      text: widget.initialProductionQty,
    );
    _rejectController = TextEditingController(text: widget.initialRejectQty);
    _remarksController = TextEditingController(text: widget.initialRemarks);
  }

  @override
  void dispose() {
    _productionController.dispose();
    _rejectController.dispose();
    _remarksController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(
    _productionController,
    _rejectController,
    _remarksController,
  );
}
