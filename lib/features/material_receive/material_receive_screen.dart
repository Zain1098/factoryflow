import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/master_data_providers.dart';
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
            const SizedBox(height: 8),

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
            Tab(text: 'Orders'),
            Tab(text: 'Received'),
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
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: records.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final r = records[i];
            final status = r['status'] as String? ?? 'pending';
            return ListTile(
              leading: CircleAvatar(
                backgroundColor: _statusColor(status).withValues(alpha: 0.12),
                child: Icon(_statusIcon(status), color: _statusColor(status), size: 20),
              ),
              title: Text(
                '${r['part_code'] ?? ''} – ${r['part_name'] ?? ''}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text('${r['supplier_name'] ?? ''} · ${r['date']} ${r['time'] ?? ''}'.trim()),
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${r['ordered_qty']} PCS',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  _StatusChip(status),
                ],
              ),
              onLongPress: status != 'received'
                  ? () => _showStatusDialog(context, r['id'] as String, status)
                  : null,
            );
          },
        );
      },
    );
  }

  Widget _buildReceivesList() {
    final list = ref.watch(materialReceiveListProvider);
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
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: records.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final r = records[i];
            final isSynced = r['sync_status'] == 'synced';
            final shortfall = (r['shortfall'] as num?)?.toDouble() ?? 0;
            final orderedQty = (r['ordered_qty'] as num?)?.toDouble();
            return ListTile(
              leading: CircleAvatar(
                backgroundColor: Colors.brown.withValues(alpha: 0.12),
                child: const Icon(Icons.inventory_2, color: Colors.brown, size: 20),
              ),
              title: Text('${r['part_code'] ?? ''} – ${r['part_name'] ?? ''}'),
              subtitle: Text(
                '${r['supplier_name'] ?? 'Unknown'} · ${r['date']} ${r['time'] ?? ''}'.trim(),
              ),
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${r['qty']} PCS',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  if (shortfall > 0)
                    Text(
                      '−${shortfall.toStringAsFixed(0)} short',
                      style: const TextStyle(color: Colors.orange, fontSize: 11),
                    )
                  else if (orderedQty != null)
                    const Text('full', style: TextStyle(color: Colors.green, fontSize: 11)),
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

  Future<void> _showStatusDialog(BuildContext context, String id, String current) async {
    final next = current == 'pending' ? 'processing' : null;
    if (next == null) return;
    final confirmed = await showConfirmDialog(
      context,
      title: 'Update Status',
      message: 'Mark this order as "$next"?',
      confirmLabel: 'Update',
    );
    if (confirmed) {
      await ref.read(purchaseOrderRepositoryProvider).updateStatus(id, next);
      ref.invalidate(purchaseOrderListProvider);
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
      case 'processing': return Icons.hourglass_top;
      case 'received': return Icons.check_circle;
      case 'cancelled': return Icons.cancel;
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
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        status,
        style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}
