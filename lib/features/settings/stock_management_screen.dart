import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants/stock_stages.dart';
import '../../core/database/database_service.dart';
import '../../core/network/sync_service.dart';
import '../../core/services/stock_ledger_service.dart';
import '../auth/auth_providers.dart';
import '../final_dispatch/final_dispatch_providers.dart';

// ── Providers ─────────────────────────────────────────────────────────────────

final _stockOverviewProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final db = ref.watch(databaseServiceProvider);
  final parts = await db.getActiveParts();
  final result = <Map<String, dynamic>>[];
  for (final part in parts) {
    final partId = part['id'] as String;
    final balances = <String, double>{};
    for (final stage in StockStage.values) {
      balances[stage.value] = await db.getCurrentBalance(partId, stage.value);
    }
    result.add({...part, 'balances': balances});
  }
  return result;
});

final _adjustmentHistoryProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
  return ref.watch(databaseServiceProvider).getStockAdjustments();
});

// ── Screen ────────────────────────────────────────────────────────────────────

class StockManagementScreen extends ConsumerStatefulWidget {
  const StockManagementScreen({super.key});

  @override
  ConsumerState<StockManagementScreen> createState() =>
      _StockManagementScreenState();
}

class _StockManagementScreenState extends ConsumerState<StockManagementScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final role = ref.watch(userRoleProvider);
    if (role == null || !role.canAdjustStock) {
      return const Scaffold(
        body: Center(
          child: Text('Stock adjustments are restricted to Owner and Admin.'),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Stock Management'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [Tab(text: 'Overview'), Tab(text: 'History')],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: const [_OverviewTab(), _HistoryTab()],
      ),
    );
  }
}

// ── Overview Tab ──────────────────────────────────────────────────────────────

class _OverviewTab extends ConsumerWidget {
  const _OverviewTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overview = ref.watch(_stockOverviewProvider);
    return overview.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (parts) {
        if (parts.isEmpty) {
          return const Center(
            child: Text('No parts found. Add parts in Settings → Parts.'),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: parts.length,
          itemBuilder: (context, i) => _PartStockCard(part: parts[i]),
        );
      },
    );
  }
}

class _PartStockCard extends ConsumerWidget {
  const _PartStockCard({required this.part});
  final Map<String, dynamic> part;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final canAdjustStock = ref.watch(userRoleProvider)?.canAdjustStock ?? false;
    final balances = part['balances'] as Map<String, double>;
    final nonZero =
        StockStage.values.where((s) => (balances[s.value] ?? 0) > 0).toList();

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 16,
                  backgroundColor: theme.colorScheme.primaryContainer,
                  child: Text(
                    part['code'] as String,
                    style: const TextStyle(
                        fontSize: 10, fontWeight: FontWeight.bold,),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    part['name'] as String,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                if (canAdjustStock)
                  TextButton.icon(
                    icon: const Icon(Icons.tune, size: 16),
                    label: const Text('Adjust'),
                    onPressed: () => _showAdjustDialog(context, ref, balances),
                  ),
              ],
            ),
            if (nonZero.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: nonZero.map((s) {
                  return Chip(
                    label: Text(
                      '${s.label}: ${_fmt(balances[s.value]!)}',
                      style: const TextStyle(fontSize: 11),
                    ),
                    padding: EdgeInsets.zero,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  );
                }).toList(),
              ),
            ] else
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'No stock recorded',
                  style: TextStyle(
                      fontSize: 12, color: theme.colorScheme.onSurfaceVariant,),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _showAdjustDialog(
    BuildContext context,
    WidgetRef ref,
    Map<String, double> balances,
  ) async {
    final partId = part['id'] as String;
    final partName = part['name'] as String;

    StockStage selectedStage = StockStage.rawMaterial;
    String adjustMode = 'set';
    final qtyCtrl = TextEditingController();
    final remarkCtrl = TextEditingController();
    String? errorMsg;
    List<Map<String, dynamic>> approvedBatches;
    try {
      approvedBatches = await ref.read(approvedDispatchBatchesProvider.future);
    } catch (_) {
      approvedBatches = const [];
    }
    String? selectedBatchNumber;
    final openingBatchNumber = 'OPEN-${part['code'] as String}';

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          final batchesForPart = approvedBatches
              .where((batch) => batch['id'] == partId)
              .toList();
          Map<String, dynamic>? selectedBatch;
          for (final batch in batchesForPart) {
            if (batch['batch_number'] == selectedBatchNumber) {
              selectedBatch = batch;
              break;
            }
          }
          final needsTraceBatch = selectedStage == StockStage.bpStock ||
              selectedStage == StockStage.approvedAp;
          final isApprovedAp = selectedStage == StockStage.approvedAp;
          final currentQty = isApprovedAp
              ? (selectedBatch?['balance'] as num?)?.toDouble() ?? 0
              : balances[selectedStage.value] ?? 0;
          return AlertDialog(
            title: Text('Adjust Stock — $partName'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DropdownButtonFormField<StockStage>(
                    initialValue: selectedStage,
                    isExpanded: true,
                    menuMaxHeight: 360,
                    decoration: const InputDecoration(
                      labelText: 'Stock location',
                      helperText: 'Choose where this physical stock is currently sitting.',
                    ),
                    items: StockStage.values
                        .map((s) =>
                            DropdownMenuItem(value: s, child: Text(s.label)),)
                        .toList(),
                    onChanged: (v) => setS(() {
                      selectedStage = v!;
                      selectedBatchNumber =
                          (v == StockStage.bpStock || v == StockStage.approvedAp)
                              ? openingBatchNumber
                              : null;
                    }),
                  ),
                  if (needsTraceBatch) ...[
                    const SizedBox(height: 12),
                    if (isApprovedAp && batchesForPart.isNotEmpty)
                      DropdownButtonFormField<String>(
                        initialValue: selectedBatchNumber,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Trace batch',
                          helperText: 'Use the opening batch for stock that existed before this app.',
                        ),
                        items: [
                          DropdownMenuItem<String>(
                            value: openingBatchNumber,
                            child: Text('$openingBatchNumber · Opening stock'),
                          ),
                          ...batchesForPart.map((batch) => DropdownMenuItem<String>(
                                value: batch['batch_number'] as String,
                                child: Text(
                                  '${batch['batch_number']} · ${_fmt((batch['balance'] as num).toDouble())} PCS',
                                ),
                              ),),
                        ],
                        onChanged: (value) =>
                            setS(() => selectedBatchNumber = value),
                      )
                    else
                      InputDecorator(
                        decoration: const InputDecoration(
                          labelText: 'Trace batch',
                          helperText: 'Created automatically so later dispatch stays traceable.',
                        ),
                        child: Text('$openingBatchNumber · Opening stock'),
                      ),
                  ],
                  if (!needsTraceBatch && selectedStage != StockStage.rawMaterial)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        'This reconciles the ledger only. It does not create a production, inspection, or vendor batch.',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  const SizedBox(height: 8),
                  Text(
                    'Current: ${_fmt(currentQty)} PCS',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final mode in const ['set', 'add', 'subtract'])
                        ChoiceChip(
                          label: Text(mode == 'set'
                              ? 'Set balance'
                              : mode == 'add'
                                  ? 'Add stock'
                                  : 'Subtract stock',),
                          selected: adjustMode == mode,
                          onSelected: (_) => setS(() => adjustMode = mode),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: qtyCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Quantity',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: remarkCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Reason / Remark *',
                      border: OutlineInputBorder(),
                    ),
                    maxLines: 2,
                  ),
                  if (errorMsg != null) ...[
                    const SizedBox(height: 8),
                    Text(errorMsg!,
                        style:
                            const TextStyle(color: Colors.red, fontSize: 12),),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel'),),
              FilledButton(
                onPressed: () async {
                  final qty = double.tryParse(qtyCtrl.text.trim());
                  if (qty == null || qty < 0) {
                    setS(() => errorMsg = 'Enter a valid quantity.');
                    return;
                  }
                  if (remarkCtrl.text.trim().isEmpty) {
                    setS(() => errorMsg = 'Remark is required.');
                    return;
                  }
                  if (needsTraceBatch && selectedBatchNumber == null) {
                    setS(() => errorMsg = 'Select the trace batch.');
                    return;
                  }
                  Navigator.pop(ctx);
                  final result = await _applyAdjustment(
                    ref: ref,
                    partId: partId,
                    stage: selectedStage,
                    currentQty: currentQty,
                    adjustMode: adjustMode,
                    qty: qty,
                    remark: remarkCtrl.text.trim(),
                    batchNumber: selectedBatchNumber,
                  );
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(result ?? 'Stock adjustment saved.'),
                        backgroundColor: result == null ? Colors.green : Colors.red,
                      ),
                    );
                  }
                },
                child: const Text('Apply'),
              ),
            ],
          );
        },
      ),
    );
    qtyCtrl.dispose();
    remarkCtrl.dispose();
  }

  Future<String?> _applyAdjustment({
    required WidgetRef ref,
    required String partId,
    required StockStage stage,
    required double currentQty,
    required String adjustMode,
    required double qty,
    required String remark,
    String? batchNumber,
  }) async {
    final role = ref.read(userRoleProvider);
    if (role == null || !role.canAdjustStock) {
      return 'You are not allowed to adjust stock.';
    }
    final db = ref.read(databaseServiceProvider);
    final sync = ref.read(syncServiceProvider);
    final ledger = ref.read(stockLedgerServiceProvider);
    final user = ref.read(currentUserProvider).value;
    final factoryId = db.activeWorkspaceId;

    double adjustedQty;
    double newQty;
    LedgerDirection direction;

    switch (adjustMode) {
      case 'set':
        final diff = qty - currentQty;
        if (diff == 0) return 'Quantity is already set to this value.';
        adjustedQty = diff.abs();
        newQty = qty;
        direction = diff > 0 ? LedgerDirection.in_ : LedgerDirection.out;
      case 'add':
        if (qty == 0) return 'Quantity must be greater than zero.';
        adjustedQty = qty;
        newQty = currentQty + qty;
        direction = LedgerDirection.in_;
      case 'subtract':
        if (qty == 0) return 'Quantity must be greater than zero.';
        adjustedQty = qty;
        newQty = currentQty - qty;
        direction = LedgerDirection.out;
      default:
        return 'Invalid adjustment mode.';
    }

    if (newQty < 0) return 'Quantity cannot be below zero.';
    final adjId = const Uuid().v4();
    final adjData = {
      'id': adjId,
      'factory_id': factoryId,
      'user_id': user?.id,
      'part_id': partId,
      'batch_number': batchNumber,
      'stage': stage.value,
      'previous_qty': currentQty,
      'adjusted_qty':
          direction == LedgerDirection.out ? -adjustedQty : adjustedQty,
      'new_qty': newQty,
      'remarks': remark,
      'created_at': DateTime.now().toIso8601String(),
      'sync_status': 'pending',
    };

    try {
      await db.runInTransaction(() async {
        final result = await ledger.manualAdjustment(
          partId: partId,
          stage: stage,
          direction: direction,
          qty: adjustedQty,
          refId: adjId,
          triggerSync: false,
        );
        if (!result.success) {
          throw StockPostingFailure(
            result.error ?? 'Unable to adjust stock.',
          );
        }
        await db.insertStockAdjustment(adjData);
        await sync.queueInsert(
          tableName: 'stock_adjustments',
          recordId: adjId,
          payload: adjData,
          triggerSync: false,
        );
      });
    } on StockPostingFailure catch (error) {
      return error.message;
    } catch (_) {
      return 'Could not save the adjustment. No stock was changed.';
    }
    await sync.schedulePendingSync();

    ref.invalidate(_stockOverviewProvider);
    ref.invalidate(_adjustmentHistoryProvider);
    ref.invalidate(approvedDispatchBatchesProvider);
    return null;
  }

  String _fmt(double v) =>
      v == v.toInt() ? v.toInt().toString() : v.toStringAsFixed(1);
}

// ── History Tab ───────────────────────────────────────────────────────────────

class _HistoryTab extends ConsumerWidget {
  const _HistoryTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(_adjustmentHistoryProvider);
    return history.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (items) {
        if (items.isEmpty) {
          return const Center(child: Text('No adjustments recorded yet.'));
        }
        return ListView.separated(
          padding: const EdgeInsets.all(12),
          itemCount: items.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) => _AdjustmentTile(item: items[i]),
        );
      },
    );
  }
}

class _AdjustmentTile extends StatelessWidget {
  const _AdjustmentTile({required this.item});
  final Map<String, dynamic> item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final adjustedQty = (item['adjusted_qty'] as num).toDouble();
    final isPositive = adjustedQty >= 0;
    final stage = StockStage.values.firstWhere(
      (s) => s.value == item['stage'],
      orElse: () => StockStage.rawMaterial,
    );
    final createdAt = DateTime.tryParse(item['created_at'] as String? ?? '');

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      leading: CircleAvatar(
        radius: 18,
        backgroundColor: isPositive
            ? Colors.green.withValues(alpha: 0.15)
            : Colors.red.withValues(alpha: 0.15),
        child: Icon(
          isPositive ? Icons.add : Icons.remove,
          color: isPositive ? Colors.green : Colors.red,
          size: 18,
        ),
      ),
      title: Text(
        '${item['part_name'] ?? item['part_id']} · ${stage.label}'
        '${item['batch_number'] == null ? '' : ' · ${item['batch_number']}'}',
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${_fmt(item['previous_qty'])} → ${_fmt(item['new_qty'])} PCS  '
            '(${isPositive ? '+' : ''}${_fmt(adjustedQty)})',
            style: TextStyle(
              color: isPositive ? Colors.green : Colors.red,
              fontWeight: FontWeight.w600,
              fontSize: 12,
            ),
          ),
          if ((item['remarks'] as String?)?.isNotEmpty == true)
            Text(
              item['remarks'] as String,
              style: TextStyle(
                  fontSize: 11, color: theme.colorScheme.onSurfaceVariant,),
            ),
          if (createdAt != null)
            Text(
              _formatDate(createdAt),
              style: TextStyle(
                  fontSize: 11, color: theme.colorScheme.onSurfaceVariant,),
            ),
        ],
      ),
    );
  }

  String _fmt(dynamic v) {
    final d = (v as num?)?.toDouble() ?? 0;
    return d == d.toInt() ? d.toInt().toString() : d.toStringAsFixed(1);
  }

  String _formatDate(DateTime dt) {
    final months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${dt.day} ${months[dt.month - 1]} ${dt.year}  '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}
