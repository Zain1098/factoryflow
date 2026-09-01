import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/master_data_providers.dart';
import '../../core/widgets/barcode_scanner_view.dart';
import '../../core/widgets/shared_widgets.dart';
import '../auth/auth_providers.dart';
import 'receive_faco_providers.dart';

class ReceiveFacoScreen extends ConsumerStatefulWidget {
  const ReceiveFacoScreen({super.key});

  @override
  ConsumerState<ReceiveFacoScreen> createState() => _ReceiveFacoScreenState();
}

class _ReceiveFacoScreenState extends ConsumerState<ReceiveFacoScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _formKey = GlobalKey<FormState>();

  final _batchCtrl = TextEditingController();
  String? _partId;
  String? _dispatchRefId;
  final _qtyCtrl = TextEditingController();
  final _challanCtrl = TextEditingController();
  final _remarksCtrl = TextEditingController();
  List<Map<String, dynamic>> _pendingDispatches = [];
  bool _isSaving = false;
  String? _error;
  String? _success;
  bool _lastShortage = false;
  DateTime _recordedAt = DateTime.now();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _batchCtrl.dispose();
    _qtyCtrl.dispose();
    _challanCtrl.dispose();
    _remarksCtrl.dispose();
    super.dispose();
  }

  Future<void> _onPartChanged(String? partId) async {
    setState(() {
      _partId = partId;
      _dispatchRefId = null;
      _batchCtrl.clear();
      _pendingDispatches = [];
    });
    if (partId != null) {
      final dispatches = await ref
          .read(receiveFacoRepositoryProvider)
          .getPendingDispatches(partId);
      setState(() => _pendingDispatches = dispatches);
    }
  }

  void _onDispatchChanged(String? dispatchId) {
    if (dispatchId == null) return;
    final dispatch = _pendingDispatches.firstWhere(
      (item) => item['id'] == dispatchId,
    );
    setState(() {
      _dispatchRefId = dispatchId;
      _batchCtrl.text = dispatch['batch_number'] as String? ?? '';
    });
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _isSaving = true;
      _error = null;
      _success = null;
      _lastShortage = false;
    });

    try {
      final user = ref.read(currentUserProvider).value;
      final repo = ref.read(receiveFacoRepositoryProvider);
      final result = await repo.save(
        batchNumber: _batchCtrl.text.trim(),
        partId: _partId!,
        qtyReceived: double.parse(_qtyCtrl.text),
        dispatchRefId: _dispatchRefId,
        supplierChallan:
            _challanCtrl.text.trim().isEmpty ? null : _challanCtrl.text.trim(),
        remarks:
            _remarksCtrl.text.trim().isEmpty ? null : _remarksCtrl.text.trim(),
        createdBy: user?.id ?? 'unknown',
        recordedAt: _recordedAt,
      );

      if (result.success) {
        setState(() {
          _success = 'Receive from vendor saved!';
          _lastShortage = result.shortageFlag;
        });
        ref.invalidate(receiveFacoListProvider);
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
    _qtyCtrl.clear();
    _challanCtrl.clear();
    _remarksCtrl.clear();
    setState(() {
      _partId = null;
      _dispatchRefId = null;
      _pendingDispatches = [];
      _recordedAt = DateTime.now();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Receive from Vendor'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.add_circle_outline), text: 'New Entry'),
            Tab(icon: Icon(Icons.history), text: 'History'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [_buildForm(), _buildHistory()],
      ),
    );
  }

  Widget _buildForm() {
    final parts = ref.watch(partsProvider);

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
              showTime: false,
            ),
            const SizedBox(height: 16),

            const SectionHeader('Select Vendor Dispatch'),

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
                onChanged: _onPartChanged,
                validator: (v) => v == null ? 'Part is required' : null,
              ),
            ),
            const SizedBox(height: 12),

            // A receipt must always be linked to the original Faco dispatch.
            if (_partId != null && _pendingDispatches.isEmpty) ...[
              const Text(
                'No pending vendor dispatch is available for this part.',
                style: TextStyle(color: Colors.orange),
              ),
              const SizedBox(height: 12),
            ],
            if (_pendingDispatches.isNotEmpty) ...[
              AppDropdown<String>(
                label: 'Vendor Dispatch',
                isRequired: true,
                prefixIcon: const Icon(Icons.link),
                value: _dispatchRefId,
                items: _pendingDispatches
                    .map(
                      (d) => DropdownMenuItem(
                        value: d['id'] as String,
                        child: Text(
                          '${d['batch_number']} | ${d['part_code']} - ${d['part_name']} | '
                          '${(d['remaining_qty'] as num).toInt()} PCS left | ${d['date']}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: _onDispatchChanged,
                validator: (value) => value == null
                    ? 'Select the vendor dispatch being received'
                    : null,
              ),
              const SizedBox(height: 12),
            ],

            if (_batchCtrl.text.isNotEmpty) ...[
              Text(
                'Original batch: ${_batchCtrl.text}',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
            ],

            const SectionHeader('Received Quantity'),

            if (_dispatchRefId != null && _pendingDispatches.isNotEmpty) ...[
              Builder(
                builder: (context) {
                  final selected = _pendingDispatches.firstWhere(
                    (d) => d['id'] == _dispatchRefId,
                    orElse: () => <String, dynamic>{},
                  );
                  final rem = (selected['remaining_qty'] as num?)?.toDouble();
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: LiveStockChip(
                      stock: rem,
                      stageName: 'Pending Vendor Return',
                    ),
                  );
                },
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
                if (n == null || n <= 0) return 'Quantity must be > 0';
                return null;
              },
            ),
            const SizedBox(height: 6),
            QuantityStepper(
              controller: _qtyCtrl,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),

            AppFormField(
              label: 'Supplier Challan (optional)',
              controller: _challanCtrl,
              prefixIcon: const Icon(Icons.receipt_outlined),
              suffixIcon: IconButton(
                icon: const Icon(Icons.qr_code_scanner_rounded),
                tooltip: 'Scan Vendor Challan Barcode',
                onPressed: () async {
                  final code = await BarcodeScannerView.scan(
                    context,
                    title: 'Scan Vendor Challan Code',
                  );
                  if (code != null && code.isNotEmpty) {
                    _challanCtrl.text = code;
                  }
                },
              ),
            ),
            const SizedBox(height: 12),

            AppFormField(
              label: 'Remarks (optional)',
              controller: _remarksCtrl,
              maxLines: 2,
              prefixIcon: const Icon(Icons.notes),
            ),

            if (_lastShortage) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                  border:
                      Border.all(color: Colors.orange.withValues(alpha: 0.4)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.warning_amber_outlined, color: Colors.orange),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Shortage detected — received qty is less than dispatched qty.',
                        style: TextStyle(color: Colors.orange),
                      ),
                    ),
                  ],
                ),
              ),
            ],

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

  Widget _buildHistory() {
    final list = ref.watch(receiveFacoListProvider);
    return list.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) =>
          EmptyState(message: 'Error: $e', icon: Icons.error_outline),
      data: (records) {
        if (records.isEmpty) {
          return const EmptyState(
            message: 'No vendor receipts yet.',
            icon: Icons.move_to_inbox_outlined,
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: records.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final r = records[i];
            final shortage = (r['shortage_flag'] as int?) == 1;
            final isSynced = r['sync_status'] == 'synced';
            return ListTile(
              leading: CircleAvatar(
                backgroundColor: Colors.purple.withValues(alpha: 0.12),
                child: const Icon(Icons.move_to_inbox,
                    color: Colors.purple, size: 20,),
              ),
              title: Text(
                r['batch_number'] ?? '—',
                style: const TextStyle(
                    fontFamily: 'monospace', fontWeight: FontWeight.w600,),
              ),
              subtitle: Text('${r['part_code'] ?? ''} · ${r['date']}'),
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (shortage)
                        const Icon(Icons.warning_amber,
                            size: 14, color: Colors.orange,),
                      const SizedBox(width: 4),
                      Text(
                        '${r['qty_received']} PCS',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
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
