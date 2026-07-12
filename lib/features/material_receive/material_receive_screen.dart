import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

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
  final _formKey = GlobalKey<FormState>();

  // Form state
  String? _partId;
  String? _supplierId;
  final _qtyController = TextEditingController();
  final _poController = TextEditingController();
  final _remarksController = TextEditingController();
  bool _isSaving = false;
  String? _error;
  String? _success;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _qtyController.dispose();
    _poController.dispose();
    _remarksController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _isSaving = true; _error = null; _success = null; });

    try {
      final user = ref.read(currentUserProvider).value;
      final repo = ref.read(materialReceiveRepositoryProvider);
      final result = await repo.save(
        partId: _partId!,
        qty: double.parse(_qtyController.text),
        supplierId: _supplierId!,
        poNumber: _poController.text.trim().isEmpty ? null : _poController.text.trim(),
        remarks: _remarksController.text.trim().isEmpty ? null : _remarksController.text.trim(),
        createdBy: user?.id ?? 'unknown',
      );

      if (result.success) {
        setState(() => _success = 'Material receive saved successfully!');
        ref.invalidate(materialReceiveListProvider);
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
    _qtyController.clear();
    _poController.clear();
    _remarksController.clear();
    setState(() { _partId = null; _supplierId = null; });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Material Receive'),
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
    final suppliers = ref.watch(suppliersProvider);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Date/time auto-fill display
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.calendar_today, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    DateFormat('dd MMM yyyy, hh:mm a').format(DateTime.now()),
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text('Auto', style: TextStyle(color: Colors.green, fontSize: 12)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            const SectionHeader('Material Details'),

            // Part dropdown
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
              label: 'Quantity (PCS)',
              controller: _qtyController,
              allowDecimal: false,
              prefixIcon: const Icon(Icons.numbers),
              validator: (v) {
                if (v == null || v.isEmpty) return 'Quantity is required';
                final n = double.tryParse(v);
                if (n == null || n <= 0) return 'Quantity must be > 0';
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
              controller: _poController,
              prefixIcon: const Icon(Icons.receipt_outlined),
              hint: 'Leave blank if no PO',
            ),
            const SizedBox(height: 12),

            const SectionHeader('Remarks'),
            AppFormField(
              label: 'Remarks (optional)',
              controller: _remarksController,
              maxLines: 2,
              prefixIcon: const Icon(Icons.notes),
            ),
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
    final list = ref.watch(materialReceiveListProvider);
    return list.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => EmptyState(message: 'Error: $e', icon: Icons.error_outline),
      data: (records) {
        if (records.isEmpty) {
          return const EmptyState(
            message: 'No material receives yet.\nCreate your first entry.',
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
            return ListTile(
              leading: CircleAvatar(
                backgroundColor: Colors.brown.withValues(alpha: 0.12),
                child: const Icon(Icons.inventory_2, color: Colors.brown, size: 20),
              ),
              title: Text('${r['part_code'] ?? ''} – ${r['part_name'] ?? ''}'),
              subtitle: Text('${r['supplier_name'] ?? 'Unknown'} · ${r['date']}'),
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${r['qty']} PCS',
                    style: const TextStyle(fontWeight: FontWeight.bold),
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
