import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/master_data_providers.dart';
import '../../core/widgets/barcode_scanner_view.dart';
import '../../core/widgets/shared_widgets.dart';
import '../auth/auth_providers.dart';
import 'material_receive_providers.dart';

class MaterialReceiveScreen extends ConsumerStatefulWidget {
  const MaterialReceiveScreen({super.key});

  @override
  ConsumerState<MaterialReceiveScreen> createState() => _MaterialReceiveScreenState();
}

class _MaterialReceiveScreenState extends ConsumerState<MaterialReceiveScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Material Receive'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.add_shopping_cart_outlined), text: 'Place Order'),
            Tab(icon: Icon(Icons.move_to_inbox_outlined), text: 'Receive'),
            Tab(icon: Icon(Icons.history), text: 'History'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _PlaceOrderTab(onOrderPlaced: () => _tabController.animateTo(1)),
          _ReceiveMaterialTab(),
          _HistoryTab(),
        ],
      ),
    );
  }
}

// ─── Tab 1: Place Order ───────────────────────────────────────────────────────

class _PlaceOrderTab extends ConsumerStatefulWidget {
  const _PlaceOrderTab({required this.onOrderPlaced});
  final VoidCallback onOrderPlaced;

  @override
  ConsumerState<_PlaceOrderTab> createState() => _PlaceOrderTabState();
}

class _PlaceOrderTabState extends ConsumerState<_PlaceOrderTab> {
  final _formKey = GlobalKey<FormState>();
  String? _partId;
  String? _supplierId;
  final _qtyCtrl = TextEditingController();
  final _poCtrl = TextEditingController();
  final _remarksCtrl = TextEditingController();
  bool _isSaving = false;
  String? _error;
  String? _success;
  DateTime _recordedAt = DateTime.now();

  @override
  void dispose() {
    _qtyCtrl.dispose();
    _poCtrl.dispose();
    _remarksCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _isSaving = true; _error = null; _success = null; });
    try {
      final user = ref.read(currentUserProvider).value;
      final result = await ref.read(purchaseOrderRepositoryProvider).save(
        partId: _partId!,
        orderedQty: double.parse(_qtyCtrl.text),
        supplierId: _supplierId!,
        poNumber: _poCtrl.text.trim().isEmpty ? null : _poCtrl.text.trim(),
        remarks: _remarksCtrl.text.trim().isEmpty ? null : _remarksCtrl.text.trim(),
        createdBy: user?.id ?? 'unknown',
        recordedAt: _recordedAt,
      );
      if (result.success) {
        setState(() => _success = 'Order placed successfully!');
        ref.invalidate(purchaseOrderListProvider);
        _reset();
        widget.onOrderPlaced();
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
    _qtyCtrl.clear();
    _poCtrl.clear();
    _remarksCtrl.clear();
    setState(() {
      _partId = null;
      _supplierId = null;
      _recordedAt = DateTime.now();
    });
  }

  @override
  Widget build(BuildContext context) {
    final parts = ref.watch(partsProvider);
    final suppliers = ref.watch(suppliersProvider);

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
            ),
            const SizedBox(height: 16),

            const SectionHeader('Order Details'),

            parts.when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => ErrorBanner('Could not load parts: $e'),
              data: (list) => AppDropdown<String>(
                label: 'Part',
                isRequired: true,
                prefixIcon: const Icon(Icons.category_outlined),
                value: _partId,
                items: list.map((p) => DropdownMenuItem(
                  value: p['id'] as String,
                  child: Text('${p['code']} – ${p['name']}'),
                ),).toList(),
                onChanged: (v) => setState(() => _partId = v),
                validator: (v) => v == null ? 'Part is required' : null,
              ),
            ),
            const SizedBox(height: 12),

            NumberFormField(
              label: 'Ordered Qty (PCS)',
              controller: _qtyCtrl,
              allowDecimal: false,
              prefixIcon: const Icon(Icons.numbers),
              validator: (v) {
                if (v == null || v.isEmpty) return 'Required';
                final n = double.tryParse(v);
                if (n == null || n <= 0) return 'Must be > 0';
                return null;
              },
            ),
            const SizedBox(height: 12),

            const SectionHeader('Supplier & PO'),

            suppliers.when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => ErrorBanner('Could not load suppliers: $e'),
              data: (list) => AppDropdown<String>(
                label: 'Supplier',
                isRequired: true,
                prefixIcon: const Icon(Icons.business_outlined),
                value: _supplierId,
                items: list.map((s) => DropdownMenuItem(
                  value: s['id'] as String,
                  child: Text(s['name'] as String),
                ),).toList(),
                onChanged: (v) => setState(() => _supplierId = v),
                validator: (v) => v == null ? 'Supplier is required' : null,
              ),
            ),
            const SizedBox(height: 12),

            AppFormField(
              label: 'PO Number (optional)',
              controller: _poCtrl,
              prefixIcon: const Icon(Icons.receipt_outlined),
              hint: 'Leave blank if no PO',
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

            SaveButton(
              onPressed: _save,
              isLoading: _isSaving,
              label: 'Place Order',
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Tab 2: Receive Material ──────────────────────────────────────────────────

class _ReceiveMaterialTab extends ConsumerStatefulWidget {
  @override
  ConsumerState<_ReceiveMaterialTab> createState() => _ReceiveMaterialTabState();
}

class _ReceiveMaterialTabState extends ConsumerState<_ReceiveMaterialTab> {
  final _formKey = GlobalKey<FormState>();
  String? _partId;
  String? _supplierId;
  String? _poRefId;
  double? _poOrderedQty;
  final _qtyCtrl = TextEditingController();
  final _poCtrl = TextEditingController();
  final _remarksCtrl = TextEditingController();
  List<Map<String, dynamic>> _openOrders = [];
  bool _isSaving = false;
  String? _error;
  String? _success;
  double? _lastShortfall;
  DateTime _recordedAt = DateTime.now();

  @override
  void dispose() {
    _qtyCtrl.dispose();
    _poCtrl.dispose();
    _remarksCtrl.dispose();
    super.dispose();
  }

  Future<void> _onPartChanged(String? partId) async {
    setState(() {
      _partId = partId;
      _poRefId = null;
      _poOrderedQty = null;
      _openOrders = [];
    });
    if (partId != null) {
      final orders = await ref
          .read(purchaseOrderRepositoryProvider)
          .getOpenForPart(partId);
      setState(() => _openOrders = orders);
    }
  }

  void _onPoSelected(String? poId) {
    if (poId == null) {
      setState(() { _poRefId = null; _poOrderedQty = null; });
      return;
    }
    final po = _openOrders.firstWhere((o) => o['id'] == poId);
    setState(() {
      _poRefId = poId;
      _poOrderedQty = (po['ordered_qty'] as num).toDouble();
      // Pre-fill supplier from PO
      _supplierId = po['supplier_id'] as String?;
      // Pre-fill qty with ordered qty
      _qtyCtrl.text = _poOrderedQty!.toStringAsFixed(0);
    });
  }

  double get _shortfall {
    if (_poOrderedQty == null) return 0;
    final received = double.tryParse(_qtyCtrl.text) ?? 0;
    return (_poOrderedQty! - received).clamp(0.0, double.infinity);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _isSaving = true; _error = null; _success = null; _lastShortfall = null; });
    try {
      final user = ref.read(currentUserProvider).value;
      final result = await ref.read(materialReceiveRepositoryProvider).save(
        partId: _partId!,
        qty: double.parse(_qtyCtrl.text),
        supplierId: _supplierId!,
        poNumber: _poCtrl.text.trim().isEmpty ? null : _poCtrl.text.trim(),
        poRefId: _poRefId,
        orderedQty: _poOrderedQty,
        remarks: _remarksCtrl.text.trim().isEmpty ? null : _remarksCtrl.text.trim(),
        createdBy: user?.id ?? 'unknown',
        recordedAt: _recordedAt,
      );
      if (result.success) {
        setState(() {
          _success = 'Material received successfully!';
          _lastShortfall = result.shortfall > 0 ? result.shortfall : null;
        });
        ref.invalidate(materialReceiveListProvider);
        ref.invalidate(purchaseOrderListProvider);
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
    _qtyCtrl.clear();
    _poCtrl.clear();
    _remarksCtrl.clear();
    setState(() {
      _partId = null;
      _supplierId = null;
      _poRefId = null;
      _poOrderedQty = null;
      _openOrders = [];
      _recordedAt = DateTime.now();
    });
  }

  @override
  Widget build(BuildContext context) {
    final parts = ref.watch(partsProvider);
    final suppliers = ref.watch(suppliersProvider);
    final shortfall = _shortfall;

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
            ),
            const SizedBox(height: 16),

            const SectionHeader('Part'),

            parts.when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => ErrorBanner('Could not load parts: $e'),
              data: (list) => AppDropdown<String>(
                label: 'Part',
                isRequired: true,
                prefixIcon: const Icon(Icons.category_outlined),
                value: _partId,
                items: list.map((p) => DropdownMenuItem(
                  value: p['id'] as String,
                  child: Text('${p['code']} – ${p['name']}'),
                ),).toList(),
                onChanged: _onPartChanged,
                validator: (v) => v == null ? 'Part is required' : null,
              ),
            ),
            const SizedBox(height: 12),

            // Link to open PO
            if (_openOrders.isNotEmpty) ...[
              AppDropdown<String>(
                label: 'Link to Purchase Order (optional)',
                prefixIcon: const Icon(Icons.link),
                value: _poRefId,
                items: [
                  const DropdownMenuItem(value: null, child: Text('— No link —')),
                  ..._openOrders.map((o) => DropdownMenuItem(
                    value: o['id'] as String,
                    child: Text(
                      '${o['po_number'] ?? 'No PO'} · ${o['ordered_qty']} PCS · ${o['date']} ${o['time'] ?? ''}'.trim(),
                    ),
                  ),),
                ],
                onChanged: _onPoSelected,
              ),
              const SizedBox(height: 12),
            ],

            // Ordered qty info chip
            if (_poOrderedQty != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline, size: 16),
                    const SizedBox(width: 8),
                    Text('Ordered: ${_poOrderedQty!.toStringAsFixed(0)} PCS'),
                  ],
                ),
              ),
            if (_poOrderedQty != null) const SizedBox(height: 12),

            NumberFormField(
              label: 'Qty Received (PCS)',
              controller: _qtyCtrl,
              allowDecimal: false,
              prefixIcon: const Icon(Icons.move_to_inbox_outlined),
              validator: (v) {
                if (v == null || v.isEmpty) return 'Required';
                final n = double.tryParse(v);
                if (n == null || n <= 0) return 'Must be > 0';
                return null;
              },
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),

            // Shortfall display
            if (_poOrderedQty != null && shortfall > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange.withValues(alpha: 0.4)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_outlined, color: Colors.orange, size: 18),
                    const SizedBox(width: 8),
                    Text(
                      'Shortfall: ${shortfall.toStringAsFixed(0)} PCS',
                      style: const TextStyle(color: Colors.orange, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            if (_poOrderedQty != null && shortfall == 0 && _qtyCtrl.text.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.check_circle_outline, color: Colors.green, size: 18),
                    SizedBox(width: 8),
                    Text('Full quantity received', style: TextStyle(color: Colors.green)),
                  ],
                ),
              ),

            const SectionHeader('Supplier & PO'),

            suppliers.when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => ErrorBanner('Could not load suppliers: $e'),
              data: (list) => AppDropdown<String>(
                label: 'Supplier',
                isRequired: true,
                prefixIcon: const Icon(Icons.business_outlined),
                value: _supplierId,
                items: list.map((s) => DropdownMenuItem(
                  value: s['id'] as String,
                  child: Text(s['name'] as String),
                ),).toList(),
                onChanged: (v) => setState(() => _supplierId = v),
                validator: (v) => v == null ? 'Supplier is required' : null,
              ),
            ),
            const SizedBox(height: 12),

            AppFormField(
              label: 'PO / Supplier Challan Number (optional)',
              controller: _poCtrl,
              prefixIcon: const Icon(Icons.receipt_outlined),
              suffixIcon: IconButton(
                icon: const Icon(Icons.qr_code_scanner_rounded),
                tooltip: 'Scan Challan / PO Barcode',
                onPressed: () async {
                  final code = await BarcodeScannerView.scan(
                    context,
                    title: 'Scan Supplier Challan / PO',
                  );
                  if (code != null && code.isNotEmpty) {
                    _poCtrl.text = code;
                  }
                },
              ),
              hint: 'Scan or type PO / Challan number',
            ),
            const SizedBox(height: 12),

            AppFormField(
              label: 'Remarks (optional)',
              controller: _remarksCtrl,
              maxLines: 2,
              prefixIcon: const Icon(Icons.notes),
            ),
            const SizedBox(height: 16),

            // Post-save shortfall banner
            if (_lastShortfall != null && _lastShortfall! > 0)
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange.withValues(alpha: 0.4)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber, color: Colors.orange),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Shortfall of ${_lastShortfall!.toStringAsFixed(0)} PCS recorded.',
                        style: const TextStyle(color: Colors.orange),
                      ),
                    ),
                  ],
                ),
              ),

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

// ─── Tab 3: History ───────────────────────────────────────────────────────────

// ─── Tab 3: History ───────────────────────────────────────────────────────────

class _HistoryTab extends ConsumerStatefulWidget {
  @override
  ConsumerState<_HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends ConsumerState<_HistoryTab>
    with SingleTickerProviderStateMixin {
  late TabController _sub;

  @override
  void initState() {
    super.initState();
    _sub = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _sub.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TabBar(
          controller: _sub,
          tabs: const [
            Tab(icon: Icon(Icons.add_shopping_cart_outlined, size: 18), text: 'Orders Placed'),
            Tab(icon: Icon(Icons.move_to_inbox_outlined, size: 18), text: 'Received Records'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _sub,
            children: [_buildOrdersList(), _buildReceivesList()],
          ),
        ),
      ],
    );
  }

  Widget _buildOrdersList() {
    final list = ref.watch(purchaseOrderListProvider);
    final theme = Theme.of(context);
    return list.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => EmptyState(message: 'Error: $e', icon: Icons.error_outline),
      data: (records) {
        if (records.isEmpty) {
          return const EmptyState(
            message: 'No purchase orders yet.',
            icon: Icons.add_shopping_cart_outlined,
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
          itemCount: records.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            final r = records[i];
            final status = r['status'] as String? ?? 'pending';
            final color = _statusColor(status);
            return Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => _showOrderActionsSheet(context, r),
                onLongPress: () => _showOrderActionsSheet(context, r),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 20,
                        backgroundColor: color.withValues(alpha: 0.12),
                        child: Icon(_statusIcon(status), color: color, size: 20),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${r['part_code'] ?? ''} – ${r['part_name'] ?? ''}',
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '${r['supplier_name'] ?? 'Unknown Supplier'} · ${r['date']} ${r['time'] ?? ''}'.trim(),
                              style: TextStyle(
                                fontSize: 11,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            if (r['po_number'] != null && (r['po_number'] as String).isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(
                                  'PO: ${r['po_number']}',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: theme.colorScheme.primary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            '${(r['ordered_qty'] as num?)?.toStringAsFixed(0) ?? '0'} PCS',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                          ),
                          const SizedBox(height: 4),
                          _StatusChip(status),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildReceivesList() {
    final list = ref.watch(materialReceiveListProvider);
    final theme = Theme.of(context);
    return list.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => EmptyState(message: 'Error: $e', icon: Icons.error_outline),
      data: (records) {
        if (records.isEmpty) {
          return const EmptyState(
            message: 'No material receives yet.',
            icon: Icons.inventory_2_outlined,
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
          itemCount: records.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            final r = records[i];
            final isSynced = r['sync_status'] == 'synced';
            final shortfall = (r['shortfall'] as num?)?.toDouble() ?? 0;
            final orderedQty = (r['ordered_qty'] as num?)?.toDouble();
            final hasPo = r['po_ref_id'] != null || (r['po_id'] != null && (r['po_id'] as String).isNotEmpty);

            return Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => _showReceiveActionsSheet(context, r),
                onLongPress: () => _showReceiveActionsSheet(context, r),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 20,
                        backgroundColor: Colors.brown.withValues(alpha: 0.12),
                        child: const Icon(Icons.inventory_2, color: Colors.brown, size: 20),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${r['part_code'] ?? ''} – ${r['part_name'] ?? ''}',
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '${r['supplier_name'] ?? 'Unknown'} · ${r['date']} ${r['time'] ?? ''}'.trim(),
                              style: TextStyle(
                                fontSize: 11,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            if (hasPo)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(
                                  r['po_id'] != null ? 'PO/Challan: ${r['po_id']}' : 'Linked to PO',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: Colors.brown.shade700,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            '${(r['qty'] as num?)?.toStringAsFixed(0) ?? '0'} PCS',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                          ),
                          const SizedBox(height: 2),
                          if (shortfall > 0)
                            Text(
                              '−${shortfall.toStringAsFixed(0)} short',
                              style: const TextStyle(color: Colors.orange, fontSize: 11, fontWeight: FontWeight.bold),
                            )
                          else if (orderedQty != null)
                            const Text('full qty', style: TextStyle(color: Colors.green, fontSize: 11, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 2),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                isSynced ? Icons.cloud_done_rounded : Icons.cloud_upload_outlined,
                                size: 13,
                                color: isSynced ? Colors.green : Colors.orange,
                              ),
                              const SizedBox(width: 4),
                              const Icon(Icons.more_horiz_rounded, size: 16, color: Colors.grey),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  // ─── Order Actions Bottom Sheet & Dialogs ─────────────────────────────────

  void _showOrderActionsSheet(BuildContext context, Map<String, dynamic> r) {
    final theme = Theme.of(context);
    final status = r['status'] as String? ?? 'pending';

    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.outlineVariant,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    CircleAvatar(
                      backgroundColor: _statusColor(status).withValues(alpha: 0.15),
                      child: Icon(_statusIcon(status), color: _statusColor(status), size: 20),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'PO: ${r['part_code'] ?? ''} (${r['ordered_qty']} PCS)',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                          ),
                          Text(
                            '${r['supplier_name'] ?? ''} · Status: ${status.toUpperCase()}',
                            style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.edit_outlined, color: Colors.blue),
                  title: const Text('Edit Purchase Order', style: TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: const Text('Update quantity, part, supplier, or date'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showEditOrderDialog(context, r);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.swap_horiz_rounded, color: Colors.orange),
                  title: const Text('Update Order Status', style: TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text('Current: $status'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showOrderStatusDialog(context, r['id'] as String, status);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.delete_outline_rounded, color: Colors.red),
                  title: const Text('Delete Purchase Order', style: TextStyle(color: Colors.red, fontWeight: FontWeight.w600)),
                  subtitle: const Text('Permanently remove this order entry'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _confirmDeleteOrder(context, r);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _showEditOrderDialog(BuildContext context, Map<String, dynamic> r) async {
    final parts = await ref.read(partsProvider.future);
    final suppliers = await ref.read(suppliersProvider.future);
    if (!context.mounted) return;

    final id = r['id'] as String;
    String selectedPartId = r['part_id'] as String? ?? (parts.isNotEmpty ? parts.first['id'] as String : '');
    String selectedSupplierId = r['supplier_id'] as String? ?? (suppliers.isNotEmpty ? suppliers.first['id'] as String : '');
    final qtyCtrl = TextEditingController(text: (r['ordered_qty'] as num?)?.toStringAsFixed(0) ?? '');
    final poCtrl = TextEditingController(text: r['po_number'] as String? ?? '');
    final remarksCtrl = TextEditingController(text: r['remarks'] as String? ?? '');
    String selectedStatus = r['status'] as String? ?? 'pending';
    DateTime recordedAt = DateTime.tryParse(r['date'] as String? ?? '') ?? DateTime.now();

    await showDialog<void>(
      context: context,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: const Row(
                children: [
                  Icon(Icons.edit_note_rounded, color: Colors.blue),
                  SizedBox(width: 8),
                  Text('Edit Purchase Order', style: TextStyle(fontSize: 16)),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    RecordDateTimePicker(
                      value: recordedAt,
                      onChanged: (dt) => setDialogState(() => recordedAt = dt),
                    ),
                    const SizedBox(height: 12),
                    AppDropdown<String>(
                      label: 'Part',
                      isRequired: true,
                      value: selectedPartId.isNotEmpty ? selectedPartId : null,
                      items: parts.map((p) => DropdownMenuItem(
                        value: p['id'] as String,
                        child: Text('${p['code']} – ${p['name']}'),
                      ),).toList(),
                      onChanged: (v) {
                        if (v != null) setDialogState(() => selectedPartId = v);
                      },
                    ),
                    const SizedBox(height: 10),
                    NumberFormField(
                      label: 'Ordered Qty (PCS)',
                      controller: qtyCtrl,
                      allowDecimal: false,
                      prefixIcon: const Icon(Icons.numbers),
                    ),
                    const SizedBox(height: 10),
                    AppDropdown<String>(
                      label: 'Supplier',
                      isRequired: true,
                      value: selectedSupplierId.isNotEmpty ? selectedSupplierId : null,
                      items: suppliers.map((s) => DropdownMenuItem(
                        value: s['id'] as String,
                        child: Text(s['name'] as String),
                      ),).toList(),
                      onChanged: (v) {
                        if (v != null) setDialogState(() => selectedSupplierId = v);
                      },
                    ),
                    const SizedBox(height: 10),
                    AppFormField(
                      label: 'PO Number (optional)',
                      controller: poCtrl,
                      prefixIcon: const Icon(Icons.receipt_outlined),
                    ),
                    const SizedBox(height: 10),
                    AppDropdown<String>(
                      label: 'Status',
                      value: selectedStatus,
                      items: kPoStatuses.map((s) => DropdownMenuItem(
                        value: s,
                        child: Text(s.toUpperCase()),
                      ),).toList(),
                      onChanged: (v) {
                        if (v != null) setDialogState(() => selectedStatus = v);
                      },
                    ),
                    const SizedBox(height: 10),
                    AppFormField(
                      label: 'Remarks',
                      controller: remarksCtrl,
                      maxLines: 2,
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogCtx),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () async {
                    final qty = double.tryParse(qtyCtrl.text) ?? 0;
                    if (qty <= 0) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Please enter a valid quantity > 0')),
                      );
                      return;
                    }
                    Navigator.pop(dialogCtx);
                    final result = await ref.read(purchaseOrderRepositoryProvider).update(
                      id: id,
                      partId: selectedPartId,
                      orderedQty: qty,
                      supplierId: selectedSupplierId,
                      poNumber: poCtrl.text.trim().isEmpty ? null : poCtrl.text.trim(),
                      status: selectedStatus,
                      remarks: remarksCtrl.text.trim().isEmpty ? null : remarksCtrl.text.trim(),
                      recordedAt: recordedAt,
                    );
                    if (result.success) {
                      ref.invalidate(purchaseOrderListProvider);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Purchase order updated successfully')),
                        );
                      }
                    } else if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(result.error ?? 'Update failed')),
                      );
                    }
                  },
                  child: const Text('Save Changes'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _showOrderStatusDialog(BuildContext context, String id, String current) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return SimpleDialog(
          title: const Text('Change Order Status'),
          children: kPoStatuses.map((s) {
            final isCurrent = s == current;
            return SimpleDialogOption(
              onPressed: () async {
                Navigator.pop(ctx);
                if (s != current) {
                  await ref.read(purchaseOrderRepositoryProvider).updateStatus(id, s);
                  ref.invalidate(purchaseOrderListProvider);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Order status changed to ${s.toUpperCase()}')),
                    );
                  }
                }
              },
              child: Row(
                children: [
                  Icon(_statusIcon(s), color: _statusColor(s), size: 18),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      s.toUpperCase(),
                      style: TextStyle(
                        fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                        color: isCurrent ? _statusColor(s) : null,
                      ),
                    ),
                  ),
                  if (isCurrent) const Icon(Icons.check, size: 18, color: Colors.green),
                ],
              ),
            );
          }).toList(),
        );
      },
    );
  }

  Future<void> _confirmDeleteOrder(BuildContext context, Map<String, dynamic> r) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete Purchase Order?',
      message: 'Are you sure you want to delete purchase order for ${r['part_code']} (${r['ordered_qty']} PCS)? This action cannot be undone.',
      confirmLabel: 'Delete',
    );
    if (confirmed) {
      final result = await ref.read(purchaseOrderRepositoryProvider).delete(r['id'] as String);
      if (result.success) {
        ref.invalidate(purchaseOrderListProvider);
        ref.invalidate(materialReceiveListProvider);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Purchase order deleted')),
          );
        }
      } else if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result.error ?? 'Delete failed')),
        );
      }
    }
  }

  // ─── Receive Actions Bottom Sheet & Dialogs ───────────────────────────────

  void _showReceiveActionsSheet(BuildContext context, Map<String, dynamic> r) {
    final theme = Theme.of(context);

    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.outlineVariant,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    CircleAvatar(
                      backgroundColor: Colors.brown.withValues(alpha: 0.15),
                      child: const Icon(Icons.inventory_2, color: Colors.brown, size: 20),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${r['part_code'] ?? ''} – ${r['qty']} PCS Received',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                          ),
                          Text(
                            '${r['supplier_name'] ?? 'Unknown'} · ${r['date']} ${r['time'] ?? ''}',
                            style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.edit_outlined, color: Colors.blue),
                  title: const Text('Edit Material Receipt', style: TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: const Text('Adjust quantity received, supplier, PO or date (stock adjusts automatically)'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showEditReceiveDialog(context, r);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.delete_outline_rounded, color: Colors.red),
                  title: const Text('Delete Material Receipt', style: TextStyle(color: Colors.red, fontWeight: FontWeight.w600)),
                  subtitle: const Text('Rolls back Raw Material stock and reopens linked PO'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _confirmDeleteReceive(context, r);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _showEditReceiveDialog(BuildContext context, Map<String, dynamic> r) async {
    final parts = await ref.read(partsProvider.future);
    final suppliers = await ref.read(suppliersProvider.future);
    if (!context.mounted) return;

    final id = r['id'] as String;
    String selectedPartId = r['part_id'] as String? ?? (parts.isNotEmpty ? parts.first['id'] as String : '');
    String selectedSupplierId = r['supplier_id'] as String? ?? (suppliers.isNotEmpty ? suppliers.first['id'] as String : '');
    final qtyCtrl = TextEditingController(text: (r['qty'] as num?)?.toStringAsFixed(0) ?? '');
    final poCtrl = TextEditingController(text: r['po_id'] as String? ?? '');
    final remarksCtrl = TextEditingController(text: r['remarks'] as String? ?? '');
    String? selectedPoRefId = r['po_ref_id'] as String?;
    DateTime recordedAt = DateTime.tryParse(r['date'] as String? ?? '') ?? DateTime.now();

    List<Map<String, dynamic>> openOrders = [];
    if (selectedPartId.isNotEmpty) {
      openOrders = await ref.read(purchaseOrderRepositoryProvider).getOpenForPart(selectedPartId);
    }
    if (!context.mounted) return;

    await showDialog<void>(
      context: context,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: const Row(
                children: [
                  Icon(Icons.edit_note_rounded, color: Colors.brown),
                  SizedBox(width: 8),
                  Text('Edit Material Receipt', style: TextStyle(fontSize: 16)),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    RecordDateTimePicker(
                      value: recordedAt,
                      onChanged: (dt) => setDialogState(() => recordedAt = dt),
                    ),
                    const SizedBox(height: 12),
                    AppDropdown<String>(
                      label: 'Part',
                      isRequired: true,
                      value: selectedPartId.isNotEmpty ? selectedPartId : null,
                      items: parts.map((p) => DropdownMenuItem(
                        value: p['id'] as String,
                        child: Text('${p['code']} – ${p['name']}'),
                      ),).toList(),
                      onChanged: (v) async {
                        if (v != null) {
                          final orders = await ref.read(purchaseOrderRepositoryProvider).getOpenForPart(v);
                          setDialogState(() {
                            selectedPartId = v;
                            selectedPoRefId = null;
                            openOrders = orders;
                          });
                        }
                      },
                    ),
                    const SizedBox(height: 10),
                    NumberFormField(
                      label: 'Qty Received (PCS)',
                      controller: qtyCtrl,
                      allowDecimal: false,
                      prefixIcon: const Icon(Icons.move_to_inbox_outlined),
                    ),
                    const SizedBox(height: 10),
                    AppDropdown<String>(
                      label: 'Supplier',
                      isRequired: true,
                      value: selectedSupplierId.isNotEmpty ? selectedSupplierId : null,
                      items: suppliers.map((s) => DropdownMenuItem(
                        value: s['id'] as String,
                        child: Text(s['name'] as String),
                      ),).toList(),
                      onChanged: (v) {
                        if (v != null) setDialogState(() => selectedSupplierId = v);
                      },
                    ),
                    const SizedBox(height: 10),
                    if (openOrders.isNotEmpty) ...[
                      AppDropdown<String>(
                        label: 'Link to Purchase Order (optional)',
                        value: selectedPoRefId,
                        items: [
                          const DropdownMenuItem(value: null, child: Text('— No link —')),
                          ...openOrders.map((o) => DropdownMenuItem(
                            value: o['id'] as String,
                            child: Text('${o['po_number'] ?? 'No PO'} · ${o['ordered_qty']} PCS'),
                          ),),
                        ],
                        onChanged: (v) => setDialogState(() => selectedPoRefId = v),
                      ),
                      const SizedBox(height: 10),
                    ],
                    AppFormField(
                      label: 'PO / Supplier Challan Number',
                      controller: poCtrl,
                      prefixIcon: const Icon(Icons.receipt_outlined),
                    ),
                    const SizedBox(height: 10),
                    AppFormField(
                      label: 'Remarks',
                      controller: remarksCtrl,
                      maxLines: 2,
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogCtx),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () async {
                    final qty = double.tryParse(qtyCtrl.text) ?? 0;
                    if (qty <= 0) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Please enter a valid received qty > 0')),
                      );
                      return;
                    }
                    final user = ref.read(currentUserProvider).value;
                    Navigator.pop(dialogCtx);
                    final result = await ref.read(materialReceiveRepositoryProvider).update(
                      id: id,
                      partId: selectedPartId,
                      qty: qty,
                      supplierId: selectedSupplierId,
                      poNumber: poCtrl.text.trim().isEmpty ? null : poCtrl.text.trim(),
                      poRefId: selectedPoRefId,
                      remarks: remarksCtrl.text.trim().isEmpty ? null : remarksCtrl.text.trim(),
                      recordedAt: recordedAt,
                      updatedBy: user?.id ?? 'unknown',
                    );
                    if (result.success) {
                      ref.invalidate(materialReceiveListProvider);
                      ref.invalidate(purchaseOrderListProvider);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Material receipt updated & raw material stock adjusted')),
                        );
                      }
                    } else if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(result.error ?? 'Update failed')),
                      );
                    }
                  },
                  child: const Text('Save & Adjust Stock'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _confirmDeleteReceive(BuildContext context, Map<String, dynamic> r) async {
    final qty = (r['qty'] as num?)?.toStringAsFixed(0) ?? '0';
    final part = '${r['part_code'] ?? ''} – ${r['part_name'] ?? ''}';
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete Material Receipt?',
      message: 'Are you sure you want to delete this receipt for $part ($qty PCS)?\n\n'
          '⚠️ Notice:\n'
          '1. $qty PCS will be rolled back (deducted) from Raw Material stock balance.\n'
          '2. Any linked purchase order will be reopened back to Pending status.',
      confirmLabel: 'Delete & Rollback Stock',
    );
    if (confirmed) {
      final result = await ref.read(materialReceiveRepositoryProvider).delete(r['id'] as String);
      if (result.success) {
        ref.invalidate(materialReceiveListProvider);
        ref.invalidate(purchaseOrderListProvider);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Receipt deleted and $qty PCS rolled back from stock')),
          );
        }
      } else if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result.error ?? 'Delete failed')),
        );
      }
    }
  }

  Color _statusColor(String s) {
    switch (s) {
      case 'processing': return Colors.blue;
      case 'received': return Colors.green;
      case 'cancelled': return Colors.red;
      default: return Colors.orange;
    }
  }

  IconData _statusIcon(String s) {
    switch (s) {
      case 'processing': return Icons.hourglass_top_rounded;
      case 'received': return Icons.check_circle_rounded;
      case 'cancelled': return Icons.cancel_rounded;
      default: return Icons.pending_outlined;
    }
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip(this.status);
  final String status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      'processing' => Colors.blue,
      'received' => Colors.green,
      'cancelled' => Colors.red,
      _ => Colors.orange,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        status.toUpperCase(),
        style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.bold),
      ),
    );
  }
}
