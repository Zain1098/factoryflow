import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants/stock_stages.dart';
import '../../core/database/database_service.dart';
import '../../core/providers/stock_invalidation_helper.dart';
import '../../core/services/stock_ledger_service.dart';
import '../../core/widgets/barcode_scanner_view.dart';
import '../../core/widgets/shared_widgets.dart';
import '../auth/auth_providers.dart';

final _partsListProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  return ref.watch(databaseServiceProvider).getActiveParts();
});

final _physicalAuditHistoryProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final db = ref.watch(databaseServiceProvider);
  final factoryId = db.activeWorkspaceId.trim();
  if (factoryId.isEmpty) return [];
  final rows = db.db.select(
    '''SELECT pc.*, p.name as part_name, p.code as part_code
       FROM physical_counts pc
       LEFT JOIN parts p ON p.id = pc.part_id
       WHERE pc.factory_id = ?
       ORDER BY pc.counted_at DESC LIMIT 50''',
    [factoryId],
  );
  return rows.map((r) => Map<String, dynamic>.from(r)).toList();
});

class PhysicalStockAuditScreen extends ConsumerStatefulWidget {
  const PhysicalStockAuditScreen({super.key});

  @override
  ConsumerState<PhysicalStockAuditScreen> createState() =>
      _PhysicalStockAuditScreenState();
}

class _PhysicalStockAuditScreenState
    extends ConsumerState<PhysicalStockAuditScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  String? _selectedPartId;
  String? _selectedPartCode;
  StockStage _selectedStage = StockStage.rawMaterial;
  double _systemQty = 0.0;
  bool _isLoadingStock = false;
  final _countedQtyCtrl = TextEditingController();
  final _remarksCtrl = TextEditingController();
  bool _isPosting = false;
  String? _errorMessage;
  String? _successMessage;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    _countedQtyCtrl.dispose();
    _remarksCtrl.dispose();
    super.dispose();
  }

  Future<void> _fetchSystemStock(String partId, StockStage stage) async {
    setState(() => _isLoadingStock = true);
    final db = ref.read(databaseServiceProvider);
    final balance = await db.getCurrentBalance(partId, stage.value);
    if (!mounted) return;
    setState(() {
      _systemQty = balance;
      _isLoadingStock = false;
    });
  }

  Future<void> _postAudit() async {
    final countedStr = _countedQtyCtrl.text.trim();
    if (countedStr.isEmpty || _selectedPartId == null) {
      setState(() => _errorMessage = 'Please select a part and enter counted quantity.');
      return;
    }

    final countedQty = double.tryParse(countedStr);
    if (countedQty == null || countedQty < 0) {
      setState(() => _errorMessage = 'Please enter a valid non-negative quantity.');
      return;
    }

    setState(() {
      _isPosting = true;
      _errorMessage = null;
      _successMessage = null;
    });

    final db = ref.read(databaseServiceProvider);
    final user = ref.read(currentUserProvider).value;
    final factoryId = db.activeWorkspaceId.trim();
    final variance = countedQty - _systemQty;
    final id = const Uuid().v4();
    final now = DateTime.now().toIso8601String();
    final remarks = _remarksCtrl.text.trim().isEmpty
        ? 'Physical stock audit adjustment'
        : _remarksCtrl.text.trim();

    try {
      // 1. Insert physical_counts record
      await db.insertRecord('physical_counts', {
        'id': id,
        'factory_id': factoryId,
        'part_id': _selectedPartId,
        'stage': _selectedStage.value,
        'counted_qty': countedQty,
        'system_qty': _systemQty,
        'variance': variance,
        'counted_by': user?.name ?? 'Admin',
        'counted_at': now,
        'status': 'approved',
        'approved_by': user?.id,
        'approved_at': now,
        'remarks': remarks,
        'sync_status': 'pending',
      });

      // 2. If variance exists, write compensating Stock Ledger entry
      if (variance != 0) {
        final direction =
            variance > 0 ? LedgerDirection.in_ : LedgerDirection.out;
        final adjustQty = variance.abs();

        await ref.read(stockLedgerServiceProvider).manualAdjustment(
              partId: _selectedPartId!,
              stage: _selectedStage,
              direction: direction,
              qty: adjustQty,
              refId: id,
            );

        // Also record in stock_adjustments for audit history
        // For bp_stock stage, include the opening batch number so this stock
        // is visible as a dispatchable batch in the Dispatch to Vendor screen.
        final batchNumber = _selectedStage == StockStage.bpStock && _selectedPartCode != null
            ? 'OPEN-$_selectedPartCode'
            : null;
        await db.insertRecord('stock_adjustments', {
          'id': const Uuid().v4(),
          'factory_id': factoryId,
          'user_id': user?.id ?? 'system',
          'part_id': _selectedPartId,
          'batch_number': batchNumber,
          'stage': _selectedStage.value,
          'previous_qty': _systemQty,
          'adjusted_qty': variance,
          'new_qty': countedQty,
          'remarks': remarks,
          'created_at': now,
          'sync_status': 'pending',
        });
      }

      await db.insertInAppNotification(
        title: 'Stock Audit Reconciled',
        body: 'Physical count for ${_selectedStage.label} updated to $countedQty PCS (Variance: ${variance >= 0 ? "+$variance" : "$variance"}).',
        type: 'low_stock',
        actionRoute: '/reports/stock',
        factoryId: factoryId,
      );

      ref.invalidate(_physicalAuditHistoryProvider);
      refreshAllStockAndEntryProviders(ref);

      if (mounted) {
        HapticFeedback.lightImpact();
        setState(() {
          _isPosting = false;
          _successMessage = 'Stock audit posted successfully! System stock reconciled to $countedQty PCS.';
          _systemQty = countedQty;
          _countedQtyCtrl.clear();
          _remarksCtrl.clear();
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isPosting = false;
          _errorMessage = 'Could not post stock audit: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final user = ref.watch(currentUserProvider).value;
    final canAudit = user?.role.canAdjustStock ?? false;

    if (!canAudit) {
      return Scaffold(
        appBar: AppBar(title: const Text('Physical Stock Audit')),
        body: const EmptyState(
          message: 'Physical stock reconciliation is restricted to Owner and Admin roles.',
          icon: Icons.lock_outline_rounded,
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Physical Stock Audit & Count'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(icon: Icon(Icons.calculate_outlined, size: 18), text: 'New Audit'),
            Tab(icon: Icon(Icons.history_rounded, size: 18), text: 'Audit Log'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _buildAuditFormTab(theme),
          _buildAuditHistoryTab(theme),
        ],
      ),
    );
  }

  Widget _buildAuditFormTab(ThemeData theme) {
    final partsAsync = ref.watch(_partsListProvider);
    final countedVal = double.tryParse(_countedQtyCtrl.text.trim()) ?? _systemQty;
    final variance = _selectedPartId == null ? 0.0 : countedVal - _systemQty;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // ── 1. Part Selection ──
        partsAsync.when(
          loading: () => const LinearProgressIndicator(),
          error: (e, _) => Text('Error loading parts: $e'),
          data: (parts) {
            return Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _selectedPartId,
                    decoration: InputDecoration(
                      labelText: 'Select Part to Audit',
                      prefixIcon: const Icon(Icons.inventory_2_outlined),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    items: parts
                        .map(
                          (p) => DropdownMenuItem(
                            value: p['id'] as String,
                            child: Text('${p['name']} (${p['code']})'),
                          ),
                        )
                        .toList(),
                    onChanged: (val) {
                      if (val != null) {
                        final part = parts.firstWhere((p) => p['id'] == val, orElse: () => <String, dynamic>{});
                        setState(() {
                          _selectedPartId = val;
                          _selectedPartCode = part['code'] as String?;
                        });
                        _fetchSystemStock(val, _selectedStage);
                      }
                    },
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  tooltip: 'Scan Part QR',
                  icon: const Icon(Icons.qr_code_scanner_rounded),
                  onPressed: () async {
                    final scanned = await BarcodeScannerView.scan(
                      context,
                      title: 'Scan Part Code',
                    );
                    if (scanned != null && scanned.isNotEmpty) {
                      final matched = parts.firstWhere(
                        (p) =>
                            (p['code'] as String).toLowerCase() ==
                                scanned.toLowerCase() ||
                            p['id'] == scanned,
                        orElse: () => <String, dynamic>{},
                      );
                      if (matched.isNotEmpty) {
                        final id = matched['id'] as String;
                        setState(() {
                          _selectedPartId = id;
                          _selectedPartCode = matched['code'] as String?;
                        });
                        _fetchSystemStock(id, _selectedStage);
                      }
                    }
                  },
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 16),

        // ── 2. Stock Stage Selector ──
        DropdownButtonFormField<StockStage>(
          initialValue: _selectedStage,
          decoration: InputDecoration(
            labelText: 'Stock Stage / Location',
            prefixIcon: const Icon(Icons.category_outlined),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          items: StockStage.values
              .map(
                (s) => DropdownMenuItem(
                  value: s,
                  child: Text(s.label),
                ),
              )
              .toList(),
          onChanged: (s) {
            if (s != null) {
              setState(() => _selectedStage = s);
              if (_selectedPartId != null) {
                _fetchSystemStock(_selectedPartId!, s);
              }
            }
          },
        ),
        const SizedBox(height: 16),

        // ── 3. Current System Stock Display Card ──
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('System Recorded Stock', style: theme.textTheme.labelMedium),
                  const SizedBox(height: 4),
                  if (_isLoadingStock)
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    Text(
                      '${_systemQty.toInt()} PCS',
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                ],
              ),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.account_balance_wallet_outlined, color: theme.colorScheme.primary),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // ── 4. Actual Physical Counted Field ──
        TextFormField(
          controller: _countedQtyCtrl,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: 'Actual Physical Count (PCS)',
            helperText: 'Enter the actual quantity physically verified on floor',
            prefixIcon: const Icon(Icons.pin_outlined),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 14),

        // ── 5. Real-Time Variance Calculation Card ──
        if (_selectedPartId != null && _countedQtyCtrl.text.isNotEmpty)
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: variance == 0
                  ? Colors.green.withValues(alpha: 0.1)
                  : variance < 0
                      ? Colors.red.withValues(alpha: 0.1)
                      : Colors.blue.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: variance == 0
                    ? Colors.green.withValues(alpha: 0.4)
                    : variance < 0
                        ? Colors.red.withValues(alpha: 0.4)
                        : Colors.blue.withValues(alpha: 0.4),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  variance == 0
                      ? Icons.check_circle_outline
                      : variance < 0
                          ? Icons.trending_down_rounded
                          : Icons.trending_up_rounded,
                  color: variance == 0
                      ? Colors.green
                      : variance < 0
                          ? Colors.red
                          : Colors.blue,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        variance == 0
                            ? 'Physical Count Matches System Stock'
                            : variance < 0
                                ? 'Shortage Detected (Stock Loss)'
                                : 'Surplus Detected (Stock Gain)',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: variance == 0
                              ? Colors.green
                              : variance < 0
                                  ? Colors.red
                                  : Colors.blue,
                        ),
                      ),
                      Text(
                        'Variance: ${variance > 0 ? "+${variance.toInt()}" : "${variance.toInt()}"} PCS',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 14),

        // ── 6. Remarks Field ──
        TextFormField(
          controller: _remarksCtrl,
          decoration: InputDecoration(
            labelText: 'Audit Remarks / Reason',
            hintText: 'e.g. Month-end cycle count, physical recount verified',
            prefixIcon: const Icon(Icons.notes_rounded),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        const SizedBox(height: 16),

        if (_errorMessage != null) ErrorBanner(_errorMessage!),
        if (_successMessage != null) SuccessBanner(_successMessage!),
        const SizedBox(height: 16),

        // ── 7. Reconcile & Post Button ──
        FilledButton.icon(
          onPressed: _isPosting || _selectedPartId == null ? null : _postAudit,
          icon: _isPosting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Icon(Icons.check_circle_outline_rounded),
          label: Text(_isPosting ? 'Posting Reconciliation...' : 'Reconcile & Update Ledger'),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      ],
    );
  }

  Widget _buildAuditHistoryTab(ThemeData theme) {
    final historyAsync = ref.watch(_physicalAuditHistoryProvider);

    return historyAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error loading history: $e')),
      data: (logs) {
        if (logs.isEmpty) {
          return const EmptyState(
            message: 'No physical stock audit records found.\nNew audits will appear here.',
            icon: Icons.history_toggle_off_rounded,
          );
        }

        return RefreshIndicator(
          onRefresh: () async => ref.invalidate(_physicalAuditHistoryProvider),
          child: ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: logs.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, i) {
              final log = logs[i];
              final variance = (log['variance'] as num?)?.toDouble() ?? 0.0;
              final countedAt = DateTime.tryParse(log['counted_at']?.toString() ?? '');

              return Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            '${log['part_name'] ?? "Part"} (${log['part_code'] ?? ""})',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: variance == 0
                                ? Colors.green.withValues(alpha: 0.12)
                                : variance < 0
                                    ? Colors.red.withValues(alpha: 0.12)
                                    : Colors.blue.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            variance == 0
                                ? '0 DIFF'
                                : variance < 0
                                    ? '${variance.toInt()} SHORT'
                                    : '+${variance.toInt()} GAIN',
                            style: TextStyle(
                              color: variance == 0
                                  ? Colors.green
                                  : variance < 0
                                      ? Colors.red
                                      : Colors.blue,
                              fontWeight: FontWeight.bold,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Text(
                          'Stage: ${log['stage'] ?? "—"}',
                          style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 12),
                        ),
                        const Spacer(),
                        Text(
                          'System: ${(log['system_qty'] as num?)?.toInt() ?? 0} → Counted: ${(log['counted_qty'] as num?)?.toInt() ?? 0} PCS',
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
                        ),
                      ],
                    ),
                    if (log['remarks'] != null && (log['remarks'] as String).isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          'Remarks: ${log['remarks']}',
                          style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 11),
                        ),
                      ),
                    const SizedBox(height: 6),
                    Text(
                      countedAt != null ? DateFormat('dd MMM yyyy, hh:mm a').format(countedAt.toLocal()) : '',
                      style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}
