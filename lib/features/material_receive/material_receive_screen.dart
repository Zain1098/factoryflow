import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

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

class _CardSectionHeader extends StatelessWidget {
  const _CardSectionHeader({
    required this.icon,
    required this.title,
    this.badge,
  });

  final IconData icon;
  final String title;
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Text(
            title.toUpperCase(),
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: theme.colorScheme.primary,
            ),
          ),
          if (badge != null) ...[
            const Spacer(),
            badge!,
          ],
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
  DateTime? _lastSubmitTime;
  String? _error;
  String? _success;
  DateTime _recordedAt = DateTime.now();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _generatePoNumber();
    });
  }

  Future<void> _generatePoNumber() async {
    final po = await ref
        .read(purchaseOrderRepositoryProvider)
        .generateNextPoNumber(date: _recordedAt);
    if (mounted) {
      setState(() {
        _poCtrl.text = po;
      });
    }
  }

  @override
  void dispose() {
    _qtyCtrl.dispose();
    _poCtrl.dispose();
    _remarksCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final now = DateTime.now();
    if (_isSaving ||
        (_lastSubmitTime != null &&
            now.difference(_lastSubmitTime!) <
                const Duration(milliseconds: 1500))) {
      return;
    }
    _lastSubmitTime = now;
    if (!_formKey.currentState!.validate()) return;
    _isSaving = true;
    setState(() {
      _error = null;
      _success = null;
    });

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
    _remarksCtrl.clear();
    setState(() {
      _partId = null;
      _supplierId = null;
      _recordedAt = DateTime.now();
    });
    _generatePoNumber();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final parts = ref.watch(partsProvider);
    final suppliers = ref.watch(suppliersProvider);

    return EntryFormScroll(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            RecordDateTimePicker(
              value: _recordedAt,
              onChanged: (dt) {
                final oldDate = _recordedAt;
                setState(() => _recordedAt = dt);
                if (oldDate.day != dt.day || oldDate.month != dt.month) {
                  if (_poCtrl.text.trim().isEmpty) {
                    _generatePoNumber();
                  }
                }
              },
            ),
            const SizedBox(height: 10),

            // Card 1: Order Identification
            EntryInfoSurface(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _CardSectionHeader(
                    icon: Icons.tag_rounded,
                    title: 'Order Identification',
                    badge: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        'AUTO-GENERATED',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                  ),
                  AppFormField(
                    label: 'PO Number',
                    controller: _poCtrl,
                    prefixIcon: const Icon(Icons.receipt_outlined),
                    hint: 'e.g. PO-0709-01 (editable)',
                    suffixIcon: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_poCtrl.text.isNotEmpty)
                          IconButton(
                            icon: const Icon(Icons.clear, size: 20),
                            tooltip: 'Clear',
                            onPressed: () => setState(() => _poCtrl.clear()),
                          ),
                        IconButton(
                          icon: const Icon(Icons.refresh, size: 20),
                          tooltip: 'Generate new PO',
                          onPressed: _generatePoNumber,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),

            // Card 2: Material & Supplier
            EntryInfoSurface(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _CardSectionHeader(
                    icon: Icons.inventory_2_outlined,
                    title: 'Material & Vendor',
                  ),
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
                  const SizedBox(height: 10),
                  NumberFormField(
                    label: 'Ordered Qty (PCS)',
                    controller: _qtyCtrl,
                    allowDecimal: false,
                    prefixIcon: const Icon(Icons.format_list_numbered_rounded),
                    validator: (v) {
                      if (v == null || v.isEmpty) return 'Required';
                      final n = double.tryParse(v);
                      if (n == null || n <= 0) return 'Must be > 0';
                      return null;
                    },
                  ),
                  const SizedBox(height: 10),
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
                  const SizedBox(height: 10),
                  AppFormField(
                    label: 'Remarks (optional)',
                    controller: _remarksCtrl,
                    maxLines: 2,
                    prefixIcon: const Icon(Icons.notes),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            if (_error != null) ErrorBanner(_error!),
            if (_success != null) SuccessBanner(_success!),
            if (_error != null || _success != null) const SizedBox(height: 10),

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
  double? _poRemainingQty;
  double? _poReceivedQty;
  final _qtyCtrl = TextEditingController();
  final _poCtrl = TextEditingController();
  final _remarksCtrl = TextEditingController();
  List<Map<String, dynamic>> _openOrders = [];
  bool _isSaving = false;
  DateTime? _lastSubmitTime;
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
      _poRemainingQty = null;
      _poReceivedQty = null;
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
      setState(() {
        _poRefId = null;
        _poOrderedQty = null;
        _poRemainingQty = null;
        _poReceivedQty = null;
      });
      return;
    }
    final po = _openOrders.firstWhere((o) => o['id'] == poId);
    final ordered = ((po['ordered_qty'] ?? po['qty']) as num?)?.toDouble() ?? 0.0;
    final rcv = (po['received_qty'] as num?)?.toDouble() ?? 0.0;
    final rem = ((po['remaining_qty'] as num?)?.toDouble() ?? (ordered - rcv)).clamp(0.0, double.infinity);

    setState(() {
      _poRefId = poId;
      _poOrderedQty = ordered;
      _poReceivedQty = rcv;
      _poRemainingQty = rem;
      // Pre-fill supplier from PO
      _supplierId = po['supplier_id'] as String?;
      // Pre-fill qty with remaining balance if partial, otherwise ordered qty
      _qtyCtrl.text = rem > 0 ? rem.toStringAsFixed(0) : ordered.toStringAsFixed(0);
      // Auto-fill PO / Challan field with linked PO number
      final poNum = (po['po_number'] as String?)?.trim();
      if (poNum != null && poNum.isNotEmpty) {
        _poCtrl.text = poNum;
      }
    });
  }

  double get _shortfall {
    if (_poOrderedQty == null) return 0;
    final received = double.tryParse(_qtyCtrl.text) ?? 0;
    final target = _poRemainingQty ?? _poOrderedQty!;
    return (target - received).clamp(0.0, double.infinity);
  }

  double get _excess {
    if (_poOrderedQty == null) return 0;
    final received = double.tryParse(_qtyCtrl.text) ?? 0;
    final target = _poRemainingQty ?? _poOrderedQty!;
    return (received - target).clamp(0.0, double.infinity);
  }

  Future<void> _save() async {
    final now = DateTime.now();
    if (_isSaving ||
        (_lastSubmitTime != null &&
            now.difference(_lastSubmitTime!) <
                const Duration(milliseconds: 1500))) {
      return;
    }
    _lastSubmitTime = now;
    if (!_formKey.currentState!.validate()) return;
    _isSaving = true;
    setState(() {
      _error = null;
      _success = null;
      _lastShortfall = null;
    });

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
      _poRemainingQty = null;
      _poReceivedQty = null;
      _openOrders = [];
      _recordedAt = DateTime.now();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final parts = ref.watch(partsProvider);
    final suppliers = ref.watch(suppliersProvider);
    final shortfall = _shortfall;
    final excess = _excess;

    return EntryFormScroll(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            RecordDateTimePicker(
              value: _recordedAt,
              onChanged: (dt) => setState(() => _recordedAt = dt),
            ),
            const SizedBox(height: 10),

            // Card 1: Intake Item & Purchase Order Link
            EntryInfoSurface(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _CardSectionHeader(
                    icon: Icons.category_outlined,
                    title: 'Intake Item',
                  ),
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
                  if (_openOrders.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    AppDropdown<String>(
                      label: 'Link to Purchase Order (optional)',
                      prefixIcon: const Icon(Icons.link),
                      value: _poRefId,
                      items: [
                        const DropdownMenuItem(value: null, child: Text('— No link (Independent) —')),
                        ..._openOrders.map((o) {
                          final poNum = (o['po_number'] as String?)?.trim();
                          final displayPo = (poNum != null && poNum.isNotEmpty) ? poNum : 'PO';
                          final ordStr = (o['ordered_qty'] as num?)?.toStringAsFixed(0) ?? '0';
                          final rcvStr = (o['received_qty'] as num?)?.toStringAsFixed(0) ?? '0';
                          final remStr = (o['remaining_qty'] as num?)?.toStringAsFixed(0) ?? '0';
                          return DropdownMenuItem(
                            value: o['id'] as String,
                            child: Text('$displayPo · $rcvStr / $ordStr ($remStr Rem)'),
                          );
                        }),
                      ],
                      onChanged: _onPoSelected,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 10),

            // Card 2: Quantity & Live Reconciliation
            EntryInfoSurface(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _CardSectionHeader(
                    icon: Icons.balance_rounded,
                    title: 'Quantity & Reconciliation',
                    badge: _poOrderedQty != null
                        ? Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: (excess > 0
                                      ? Colors.blue
                                      : (shortfall > 0 ? Colors.orange : Colors.green))
                                  .withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: (excess > 0
                                        ? Colors.blue
                                        : (shortfall > 0 ? Colors.orange : Colors.green))
                                    .withValues(alpha: 0.4),
                              ),
                            ),
                            child: Text(
                              excess > 0
                                  ? 'EXCESS: +${excess.toStringAsFixed(0)} PCS'
                                  : (shortfall > 0
                                      ? 'PENDING: ${shortfall.toStringAsFixed(0)} PCS'
                                      : 'ORDER FULFILLED'),
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: excess > 0
                                    ? Colors.blue.shade800
                                    : (shortfall > 0
                                        ? Colors.orange.shade800
                                        : Colors.green.shade800),
                              ),
                            ),
                          )
                        : null,
                  ),
                  if (_poOrderedQty != null) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      margin: const EdgeInsets.only(bottom: 10),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                children: [
                                  const Icon(Icons.assignment_outlined, size: 16),
                                  const SizedBox(width: 6),
                                  Text('Total PO Ordered:', style: theme.textTheme.bodySmall),
                                ],
                              ),
                              Text(
                                '${_poOrderedQty!.toStringAsFixed(0)} PCS',
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                              ),
                            ],
                          ),
                          if (_poReceivedQty != null && _poReceivedQty! > 0) ...[
                            const SizedBox(height: 4),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    const Icon(Icons.check_circle_outline, size: 16, color: Colors.green),
                                    const SizedBox(width: 6),
                                    Text('Previously Received:', style: theme.textTheme.bodySmall),
                                  ],
                                ),
                                Text(
                                  '${_poReceivedQty!.toStringAsFixed(0)} PCS',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13,
                                    color: Colors.green,
                                  ),
                                ),
                              ],
                            ),
                          ],
                          if (_poRemainingQty != null) ...[
                            const SizedBox(height: 4),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    const Icon(Icons.hourglass_bottom, size: 16, color: Colors.orange),
                                    const SizedBox(width: 6),
                                    Text('Remaining Balance:', style: theme.textTheme.bodySmall),
                                  ],
                                ),
                                Text(
                                  '${_poRemainingQty!.toStringAsFixed(0)} PCS',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                    color: Colors.orange.shade800,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
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
                      if (n == null || n <= 0) return 'Must be > 0';
                      return null;
                    },
                    onChanged: (_) => setState(() {}),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),

            // Card 3: Vendor & Challan Reference
            EntryInfoSurface(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _CardSectionHeader(
                    icon: Icons.local_shipping_outlined,
                    title: 'Supplier & Challan',
                  ),
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
                  const SizedBox(height: 10),
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
                        if (code != null && code.trim().isNotEmpty) {
                          final cleanCode = code.trim();
                          _poCtrl.text = cleanCode;
                          final match = await ref
                              .read(purchaseOrderRepositoryProvider)
                              .findByPoNumber(cleanCode);
                          if (match != null && mounted) {
                            final matchPartId = match['part_id'] as String?;
                            if (matchPartId != null) {
                              await _onPartChanged(matchPartId);
                              _onPoSelected(match['id'] as String?);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'Auto-linked to PO: $cleanCode (${match['part_code']})',
                                  ),
                                  duration: const Duration(seconds: 2),
                                ),
                              );
                            }
                          }
                        }
                      },
                    ),
                    hint: 'Scan or type PO / Challan number',
                  ),
                  const SizedBox(height: 10),
                  AppFormField(
                    label: 'Remarks (optional)',
                    controller: _remarksCtrl,
                    maxLines: 2,
                    prefixIcon: const Icon(Icons.notes),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

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
                        style: const TextStyle(color: Colors.orange, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),

            if (_error != null) ErrorBanner(_error!),
            if (_success != null) SuccessBanner(_success!),
            if (_error != null || _success != null) const SizedBox(height: 10),

            SaveButton(onPressed: _save, isLoading: _isSaving),
          ],
        ),
      ),
    );
  }
}

// ─── Tab 3: History ───────────────────────────────────────────────────────────

DateTime _parseRecordedAt(String? dateStr, String? timeStr) {
  if (dateStr == null || dateStr.trim().isEmpty) return DateTime.now();
  final d = DateTime.tryParse(dateStr.trim()) ?? DateTime.now();
  if (timeStr != null && timeStr.contains(':')) {
    final parts = timeStr.split(':');
    final h = int.tryParse(parts[0]) ?? 0;
    final m = int.tryParse(parts[1]) ?? 0;
    return DateTime(d.year, d.month, d.day, h, m);
  }
  return d;
}

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
                              '${r['supplier_name'] ?? 'Unknown Supplier'} · ${formatDateTimeLabel(r['date'] as String?, r['time'] as String?)}'.trim(),
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
                          if (r['received_qty'] != null && (r['received_qty'] as num) > 0)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                '${(r['received_qty'] as num).toInt()} rcv · ${(r['remaining_qty'] as num?)?.toInt() ?? 0} rem',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: (r['remaining_qty'] as num? ?? 0) <= 0
                                      ? Colors.green.shade700
                                      : Colors.blue.shade800,
                                ),
                              ),
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

  Future<void> _pickReceiveHistoryDate(
    BuildContext context,
    DateTime? currentDate,
  ) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: currentDate ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      helpText: 'Select Material Receive Date',
    );
    if (picked != null) {
      ref
          .read(materialReceiveHistoryDateFilterProvider.notifier)
          .setDate(picked);
      ref.invalidate(materialReceiveListProvider);
    }
  }

  Map<String, int> _calculatePartReceivedTotals(List<Map<String, dynamic>> records) {
    final map = <String, int>{};
    for (final r in records) {
      final code = (r['part_code'] as String? ?? '—').trim();
      final qty = (r['qty'] as num?)?.toInt() ?? 0;
      map[code] = (map[code] ?? 0) + qty;
    }
    return map;
  }

  Widget _buildReceivesList() {
    final list = ref.watch(materialReceiveListProvider);
    final selectedDate = ref.watch(materialReceiveHistoryDateFilterProvider);
    final remainingAsync = ref.watch(pendingOrderRemainingProvider);
    final theme = Theme.of(context);

    return Column(
      children: [
        // Date Filter Header Bar
        InkWell(
          onTap: () => _pickReceiveHistoryDate(context, selectedDate),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: selectedDate != null
                  ? Colors.brown.withValues(alpha: 0.08)
                  : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
              border: Border(
                bottom: BorderSide(
                  color: selectedDate != null
                      ? Colors.brown.withValues(alpha: 0.3)
                      : theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
                ),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.calendar_month_outlined,
                  size: 16,
                  color: selectedDate != null ? Colors.brown : theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        selectedDate != null
                            ? '${DateFormat('EEEE').format(selectedDate)}, ${formatAppDate(selectedDate)}'
                            : 'All Received Dates',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: selectedDate != null ? Colors.brown : null,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        selectedDate != null
                            ? 'Filtered by selected receive date'
                            : 'Tap to filter by specific date',
                        style: TextStyle(
                          fontSize: 10,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.edit_calendar_outlined, size: 18),
                  tooltip: 'Change Date',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _pickReceiveHistoryDate(context, selectedDate),
                ),
                if (selectedDate != null)
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    tooltip: 'Clear Date Filter (Show All)',
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      ref
                          .read(materialReceiveHistoryDateFilterProvider.notifier)
                          .setDate(null);
                      ref.invalidate(materialReceiveListProvider);
                    },
                  ),
              ],
            ),
          ),
        ),

        // History Content with Floating Summary Box
        Expanded(
          child: list.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => EmptyState(message: 'Error: $e', icon: Icons.error_outline),
            data: (records) {
              final remainingMap = remainingAsync.value ?? <String, double>{};
              final dayReceivedMap = _calculatePartReceivedTotals(records);

              if (records.isEmpty) {
                return Stack(
                  children: [
                    Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.inventory_2_outlined,
                            size: 48,
                            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            selectedDate != null
                                ? 'No receipts on ${DateFormat('EEEE').format(selectedDate)}, ${formatAppDate(selectedDate)}.'
                                : 'No material receives yet.',
                            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                          ),
                          if (selectedDate != null) ...[
                            const SizedBox(height: 10),
                            OutlinedButton.icon(
                              onPressed: () {
                                ref
                                    .read(materialReceiveHistoryDateFilterProvider.notifier)
                                    .setDate(null);
                                ref.invalidate(materialReceiveListProvider);
                              },
                              icon: const Icon(Icons.clear, size: 16),
                              label: const Text('Show All Records'),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (remainingMap.isNotEmpty)
                      Positioned(
                        bottom: 16,
                        right: 16,
                        child: _buildRemainingSummaryBox(
                          context,
                          remainingMap,
                          dayReceivedMap,
                          selectedDate,
                          theme,
                        ),
                      ),
                  ],
                );
              }

              return Stack(
                children: [
                  ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 160),
                    itemCount: records.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      final r = records[i];
                      final isSynced = r['sync_status'] == 'synced';
                      final shortfall = (r['shortfall'] as num?)?.toDouble() ?? 0;
                      final orderedQty = (r['ordered_qty'] as num?)?.toDouble();
                      final hasPo = r['po_ref_id'] != null ||
                          (r['po_id'] != null && (r['po_id'] as String).isNotEmpty);

                      return Card(
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                          side: BorderSide(
                            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                          ),
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
                                  child: const Icon(
                                    Icons.inventory_2,
                                    color: Colors.brown,
                                    size: 20,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${r['part_code'] ?? ''} – ${r['part_name'] ?? ''}',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 13,
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        '${r['supplier_name'] ?? 'Unknown'} · ${formatDateTimeLabel(r['date'] as String?, r['time'] as String?)}'.trim(),
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: theme.colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                      if (hasPo)
                                        Padding(
                                          padding: const EdgeInsets.only(top: 2),
                                          child: Text(
                                            r['po_id'] != null
                                                ? 'PO/Challan: ${r['po_id']}'
                                                : 'Linked to PO',
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
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    if (shortfall > 0)
                                      Text(
                                        '−${shortfall.toStringAsFixed(0)} short',
                                        style: const TextStyle(
                                          color: Colors.orange,
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      )
                                    else if (orderedQty != null)
                                      const Text(
                                        'full qty',
                                        style: TextStyle(
                                          color: Colors.green,
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    const SizedBox(height: 2),
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          isSynced
                                              ? Icons.cloud_done_rounded
                                              : Icons.cloud_upload_outlined,
                                          size: 13,
                                          color: isSynced ? Colors.green : Colors.orange,
                                        ),
                                        const SizedBox(width: 4),
                                        const Icon(
                                          Icons.more_horiz_rounded,
                                          size: 16,
                                          color: Colors.grey,
                                        ),
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
                  ),
                  Positioned(
                    bottom: 16,
                    right: 16,
                    child: _buildRemainingSummaryBox(
                      context,
                      remainingMap,
                      dayReceivedMap,
                      selectedDate,
                      theme,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildRemainingSummaryBox(
    BuildContext context,
    Map<String, double> remainingParts,
    Map<String, int> dayReceivedTotals,
    DateTime? selectedDate,
    ThemeData theme,
  ) {
    final grandRemaining =
        remainingParts.values.fold<double>(0.0, (sum, val) => sum + val);
    final grandDayReceived =
        dayReceivedTotals.values.fold<int>(0, (sum, val) => sum + val);

    final title = selectedDate != null
        ? 'REMAINING (${formatAppDate(selectedDate)})'
        : 'REMAINING ORDERS';

    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(12),
      color: const Color(0xFF3E2723), // Deep warm brown container
      child: Container(
        constraints: const BoxConstraints(maxWidth: 245, minWidth: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: Colors.orangeAccent.withValues(alpha: 0.4),
            width: 1.5,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Top Header: Title & Total Remaining
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.pending_actions_rounded,
                      size: 13,
                      color: Colors.orangeAccent,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.orangeAccent,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 8),
                Text(
                  '${grandRemaining == grandRemaining.toInt() ? grandRemaining.toInt() : grandRemaining.toStringAsFixed(1)} PCS',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Divider(color: Colors.white24, height: 1),
            const SizedBox(height: 6),

            // Part-wise breakdown of remaining quantities
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 110),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: remainingParts.isEmpty
                      ? [
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.check_circle_outline,
                                  size: 13,
                                  color: Colors.greenAccent,
                                ),
                                SizedBox(width: 6),
                                Text(
                                  'All Orders Fulfilled',
                                  style: TextStyle(
                                    color: Colors.greenAccent,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ]
                      : remainingParts.entries.map((e) {
                          final valStr = e.value == e.value.toInt()
                              ? '${e.value.toInt()}'
                              : e.value.toStringAsFixed(1);
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Flexible(
                                  child: Text(
                                    '${e.key} :',
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  '$valStr PCS',
                                  style: const TextStyle(
                                    color: Colors.orangeAccent,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          );
                        }).toList(),
                ),
              ),
            ),

            // If a date is selected and receives occurred, show day received sub-bar
            if (selectedDate != null && grandDayReceived > 0) ...[
              const SizedBox(height: 5),
              const Divider(color: Colors.white24, height: 1),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Day Received:',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    '$grandDayReceived PCS',
                    style: const TextStyle(
                      color: Colors.greenAccent,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
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
    DateTime recordedAt = _parseRecordedAt(r['date'] as String?, r['time'] as String?);

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
    final receivedQty = (r['received_qty'] as num?)?.toDouble() ?? 0.0;
    if (receivedQty > 0) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.warning_amber_rounded, color: Colors.red, size: 36),
          title: const Text('Cannot Delete Order'),
          content: Text(
            'Material (${receivedQty.toInt()} PCS) has already been received against this Purchase Order (${r['po_number'] ?? r['part_code']}).\n\n'
            'To preserve the factory audit trail and inventory integrity, please delete the associated material receipts first before deleting this order.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }

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
                            '${r['supplier_name'] ?? 'Unknown'} · ${formatDateTimeLabel(r['date'] as String?, r['time'] as String?)}',
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
    DateTime recordedAt = _parseRecordedAt(r['date'] as String?, r['time'] as String?);

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
                          ...openOrders.map((o) {
                            final poNum = (o['po_number'] as String?)?.trim();
                            final displayPo = (poNum != null && poNum.isNotEmpty) ? poNum : 'PO';
                            final qtyStr = (o['ordered_qty'] as num?)?.toStringAsFixed(0) ?? '0';
                            return DropdownMenuItem(
                              value: o['id'] as String,
                              child: Text('$displayPo · $qtyStr PCS'),
                            );
                          }),
                        ],
                        onChanged: (v) => setDialogState(() {
                          selectedPoRefId = v;
                          if (v != null) {
                            final match = openOrders.firstWhere((o) => o['id'] == v);
                            final poNum = (match['po_number'] as String?)?.trim();
                            if (poNum != null && poNum.isNotEmpty) {
                              poCtrl.text = poNum;
                            }
                          }
                        }),
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
