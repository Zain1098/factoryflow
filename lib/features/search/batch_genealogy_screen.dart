import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/database_service.dart';
import '../../core/widgets/shared_widgets.dart';

final batchGenealogyProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>, String>((ref, batchNumber) async {
  final db = ref.watch(databaseServiceProvider);
  final cleanBatch = batchNumber.trim();
  if (cleanBatch.isEmpty) return {};

  final factoryId = db.activeWorkspaceId.trim();

  // 1. Productions
  final productions = db.db.select(
    '''SELECT p.*, m.name as machine_name, m.machine_code, op.name as operator_name, pt.name as part_name, pt.code as part_code
       FROM productions p
       LEFT JOIN machines m ON m.id = p.machine_id
       LEFT JOIN operators op ON op.id = p.operator_id
       LEFT JOIN parts pt ON pt.id = p.part_id
       WHERE p.factory_id = ? AND p.batch_number = ?
       ORDER BY p.date ASC, p.time ASC, p.created_at ASC''',
    [factoryId, cleanBatch],
  ).map((r) => Map<String, dynamic>.from(r)).toList();

  // 2. BP Inspections
  final bpInspections = db.db.select(
    '''SELECT bpi.*, r.reason as reject_reason_name, op.name as inspector_name
       FROM bp_inspections bpi
       LEFT JOIN bp_reject_reasons r ON r.id = bpi.reject_reason_id
       LEFT JOIN operators op ON op.id = bpi.inspector_id
       WHERE bpi.factory_id = ? AND bpi.batch_number = ?
       ORDER BY bpi.date ASC, bpi.rowid ASC''',
    [factoryId, cleanBatch],
  ).map((r) => Map<String, dynamic>.from(r)).toList();

  // 3. Dispatch to Faco (Vendor)
  final vendorDispatches = db.db.select(
    '''SELECT df.*, v.name as vendor_name, veh.number_plate as vehicle_plate, d.name as driver_name
       FROM dispatch_to_facos df
       LEFT JOIN vendors v ON v.id = df.vendor_id
       LEFT JOIN vehicles veh ON veh.id = df.vehicle_id
       LEFT JOIN drivers d ON d.id = df.driver_id
       WHERE df.factory_id = ? AND df.batch_number = ?
       ORDER BY df.date ASC, df.time ASC''',
    [factoryId, cleanBatch],
  ).map((r) => Map<String, dynamic>.from(r)).toList();

  // 4. Receive from Faco (Vendor)
  final vendorReceives = db.db.select(
    '''SELECT rf.*
       FROM receive_from_facos rf
       WHERE rf.factory_id = ? AND rf.batch_number = ?
       ORDER BY rf.date ASC, rf.rowid ASC''',
    [factoryId, cleanBatch],
  ).map((r) => Map<String, dynamic>.from(r)).toList();

  // 5. AP Inspections
  final apInspections = db.db.select(
    '''SELECT api.*, r.reason as reject_reason_name, op.name as inspector_name
       FROM ap_inspections api
       LEFT JOIN ap_reject_reasons r ON r.id = api.reject_reason_id
       LEFT JOIN operators op ON op.id = api.inspector_id
       WHERE api.factory_id = ? AND api.batch_number = ?
       ORDER BY api.date ASC, api.rowid ASC''',
    [factoryId, cleanBatch],
  ).map((r) => Map<String, dynamic>.from(r)).toList();

  // 6. RTVs
  final rtvs = db.db.select(
    '''SELECT r.*, v.name as vendor_name, rr.reason as rtv_reason_name
       FROM rtvs r
       LEFT JOIN vendors v ON v.id = r.vendor_id
       LEFT JOIN rtv_reasons rr ON rr.id = r.reason_id
       WHERE r.factory_id = ? AND r.batch_number = ?
       ORDER BY r.date ASC''',
    [factoryId, cleanBatch],
  ).map((r) => Map<String, dynamic>.from(r)).toList();

  // 7. Final Dispatches
  final finalDispatches = db.db.select(
    '''SELECT fd.*, c.name as customer_name, veh.number_plate as vehicle_plate, d.name as driver_name
       FROM final_dispatches fd
       LEFT JOIN customers c ON c.id = fd.customer_id
       LEFT JOIN vehicles veh ON veh.id = fd.vehicle_id
       LEFT JOIN drivers d ON d.id = fd.driver_id
       WHERE fd.factory_id = ? AND fd.batch_number = ?
       ORDER BY fd.date ASC''',
    [factoryId, cleanBatch],
  ).map((r) => Map<String, dynamic>.from(r)).toList();

  // Part info if found in productions
  String partName = '';
  String partCode = '';
  if (productions.isNotEmpty) {
    partName = productions.first['part_name'] as String? ?? '';
    partCode = productions.first['part_code'] as String? ?? '';
  }

  return {
    'batch_number': cleanBatch,
    'part_name': partName,
    'part_code': partCode,
    'productions': productions,
    'bp_inspections': bpInspections,
    'vendor_dispatches': vendorDispatches,
    'vendor_receives': vendorReceives,
    'ap_inspections': apInspections,
    'rtvs': rtvs,
    'final_dispatches': finalDispatches,
  };
});

class BatchGenealogyScreen extends ConsumerWidget {
  const BatchGenealogyScreen({super.key, required this.batchNumber});

  final String batchNumber;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final dataAsync = ref.watch(batchGenealogyProvider(batchNumber));

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Batch Traceability Timeline', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            Text(batchNumber, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
      ),
      body: dataAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: EmptyState(
            message: 'Error loading batch traceability: $e',
            icon: Icons.error_outline,
          ),
        ),
        data: (data) {
          final productions = (data['productions'] as List? ?? []).cast<Map<String, dynamic>>();
          final bpInspections = (data['bp_inspections'] as List? ?? []).cast<Map<String, dynamic>>();
          final vendorDispatches = (data['vendor_dispatches'] as List? ?? []).cast<Map<String, dynamic>>();
          final vendorReceives = (data['vendor_receives'] as List? ?? []).cast<Map<String, dynamic>>();
          final apInspections = (data['ap_inspections'] as List? ?? []).cast<Map<String, dynamic>>();
          final rtvs = (data['rtvs'] as List? ?? []).cast<Map<String, dynamic>>();
          final finalDispatches = (data['final_dispatches'] as List? ?? []).cast<Map<String, dynamic>>();

          final isEmpty = productions.isEmpty &&
              bpInspections.isEmpty &&
              vendorDispatches.isEmpty &&
              vendorReceives.isEmpty &&
              apInspections.isEmpty &&
              rtvs.isEmpty &&
              finalDispatches.isEmpty;

          if (isEmpty) {
            return EmptyState(
              message: 'No journey records found for batch "$batchNumber".\nMake sure the batch number was entered correctly.',
              icon: Icons.search_off_rounded,
            );
          }

          final partName = data['part_name'] as String? ?? '';
          final partCode = data['part_code'] as String? ?? '';

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // ── Header Batch Card ────────────────────────────────────────
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      theme.colorScheme.primaryContainer,
                      theme.colorScheme.surfaceContainerHighest,
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(Icons.qr_code_2_rounded, color: theme.colorScheme.onPrimary, size: 28),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            batchNumber,
                            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                          ),
                          if (partName.isNotEmpty)
                            Text(
                              '$partName ($partCode)',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          const SizedBox(height: 4),
                          Text(
                            'Complete Genealogy & Process Audit',
                            style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.primary),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              Text(
                'LIFECYCLE EVENTS',
                style: theme.textTheme.labelSmall?.copyWith(
                  letterSpacing: 1.1,
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 12),

              // ── 1. Production Stages ─────────────────────────────────────
              for (var i = 0; i < productions.length; i++)
                _buildTimelineTile(
                  context,
                  isFirst: i == 0,
                  isLast: false,
                  icon: Icons.precision_manufacturing_rounded,
                  iconColor: Colors.teal,
                  title: 'Production: ${productions[i]['machine_name'] ?? "Machine"}',
                  subtitle: '${productions[i]['date']} · Shift ${productions[i]['shift_id'] ?? "A"} · Op: ${productions[i]['operator_name'] ?? "—"}',
                  content: Row(
                    children: [
                      _badge('Input: ${(productions[i]['production_qty'] as num?)?.toInt() ?? 0} PCS', Colors.teal),
                      const SizedBox(width: 8),
                      _badge('Good: ${(productions[i]['good_qty'] as num?)?.toInt() ?? 0} PCS', Colors.green),
                      if (((productions[i]['bp_reject_qty'] as num?) ?? 0) > 0) ...[
                        const SizedBox(width: 8),
                        _badge('Reject: ${(productions[i]['bp_reject_qty'] as num?)?.toInt()} PCS', Colors.red),
                      ],
                    ],
                  ),
                ),

              // ── 2. BP Inspections ────────────────────────────────────────
              for (final bp in bpInspections)
                _buildTimelineTile(
                  context,
                  isFirst: false,
                  isLast: false,
                  icon: Icons.fact_check_rounded,
                  iconColor: Colors.indigo,
                  title: 'BP Quality Inspection',
                  subtitle: '${bp['date']} · Inspector: ${bp['inspector_name'] ?? "—"}',
                  content: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          _badge('Inspected: ${(bp['inspected_qty'] as num?)?.toInt() ?? 0} PCS', Colors.indigo),
                          if (((bp['bp_reject_qty'] as num?) ?? 0) > 0) ...[
                            const SizedBox(width: 8),
                            _badge('BP Reject: ${(bp['bp_reject_qty'] as num?)?.toInt()} PCS', Colors.red),
                          ],
                        ],
                      ),
                      if (bp['reject_reason_name'] != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            'Reason: ${bp['reject_reason_name']}',
                            style: const TextStyle(color: Colors.red, fontSize: 12, fontWeight: FontWeight.w500),
                          ),
                        ),
                    ],
                  ),
                ),

              // ── 3. Vendor Dispatches ─────────────────────────────────────
              for (final vd in vendorDispatches)
                _buildTimelineTile(
                  context,
                  isFirst: false,
                  isLast: false,
                  icon: Icons.local_shipping_outlined,
                  iconColor: Colors.amber.shade800,
                  title: 'Dispatched to Vendor: ${vd['vendor_name'] ?? "Vendor"}',
                  subtitle: '${vd['date']} · Challan: ${vd['challan_number'] ?? "—"}',
                  content: Row(
                    children: [
                      _badge('Qty: ${(vd['qty'] as num?)?.toInt() ?? 0} PCS', Colors.amber.shade800),
                      if (vd['vehicle_plate'] != null) ...[
                        const SizedBox(width: 8),
                        _badge('Veh: ${vd['vehicle_plate']}', Colors.grey),
                      ],
                    ],
                  ),
                ),

              // ── 4. Vendor Receipts ───────────────────────────────────────
              for (final vr in vendorReceives)
                _buildTimelineTile(
                  context,
                  isFirst: false,
                  isLast: false,
                  icon: Icons.move_to_inbox_rounded,
                  iconColor: Colors.blueGrey,
                  title: 'Received from Vendor',
                  subtitle: '${vr['date']} · Supplier Challan: ${vr['supplier_challan'] ?? "—"}',
                  content: Row(
                    children: [
                      _badge('Received: ${(vr['qty_received'] as num?)?.toInt() ?? 0} PCS', Colors.blueGrey),
                      if ((vr['shortage_flag'] as int? ?? 0) == 1) ...[
                        const SizedBox(width: 8),
                        _badge('Shortage Reported', Colors.red),
                      ],
                    ],
                  ),
                ),

              // ── 5. AP Inspections ────────────────────────────────────────
              for (final ap in apInspections)
                _buildTimelineTile(
                  context,
                  isFirst: false,
                  isLast: false,
                  icon: Icons.verified_outlined,
                  iconColor: Colors.teal,
                  title: 'AP Quality Inspection (After Plating)',
                  subtitle: '${ap['date']} · Inspector: ${ap['inspector_name'] ?? "—"}',
                  content: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          _badge('Checked: ${(ap['qty_checked'] as num?)?.toInt() ?? 0} PCS', Colors.blue),
                          const SizedBox(width: 8),
                          _badge('Approved: ${(ap['approved_qty'] as num?)?.toInt() ?? 0} PCS', Colors.green),
                          if (((ap['rejected_qty'] as num?) ?? 0) > 0) ...[
                            const SizedBox(width: 8),
                            _badge('Rejected: ${(ap['rejected_qty'] as num?)?.toInt()} PCS', Colors.red),
                          ],
                        ],
                      ),
                      if (ap['reject_reason_name'] != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            'Reason: ${ap['reject_reason_name']}',
                            style: const TextStyle(color: Colors.red, fontSize: 12, fontWeight: FontWeight.w500),
                          ),
                        ),
                    ],
                  ),
                ),

              // ── 6. RTVs ──────────────────────────────────────────────────
              for (final rtv in rtvs)
                _buildTimelineTile(
                  context,
                  isFirst: false,
                  isLast: false,
                  icon: Icons.assignment_return_outlined,
                  iconColor: Colors.deepOrange,
                  title: 'RTV: Returned to Vendor',
                  subtitle: '${rtv['date']} · Vendor: ${rtv['vendor_name'] ?? "—"} · Cycle: ${rtv['cycle_number'] ?? 1}',
                  content: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          _badge('RTV Qty: ${(rtv['rtv_qty'] as num?)?.toInt() ?? 0} PCS', Colors.deepOrange),
                          const SizedBox(width: 8),
                          _badge('Status: ${(rtv['status'] as String? ?? "pending").toUpperCase()}', Colors.purple),
                        ],
                      ),
                      if (rtv['rtv_reason_name'] != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text('Reason: ${rtv['rtv_reason_name']}', style: const TextStyle(fontSize: 12)),
                        ),
                    ],
                  ),
                ),

              // ── 7. Final Customer Dispatch ───────────────────────────────
              for (var i = 0; i < finalDispatches.length; i++)
                _buildTimelineTile(
                  context,
                  isFirst: false,
                  isLast: i == finalDispatches.length - 1,
                  icon: Icons.check_circle_rounded,
                  iconColor: Colors.green,
                  title: 'Final Dispatched to Customer: ${finalDispatches[i]['customer_name'] ?? "Customer"}',
                  subtitle: '${finalDispatches[i]['date']} · Challan: ${finalDispatches[i]['challan_number'] ?? "—"}',
                  content: Row(
                    children: [
                      _badge('Dispatched: ${(finalDispatches[i]['dispatch_qty'] as num?)?.toInt() ?? 0} PCS', Colors.green),
                      if (finalDispatches[i]['vehicle_plate'] != null) ...[
                        const SizedBox(width: 8),
                        _badge('Veh: ${finalDispatches[i]['vehicle_plate']}', Colors.grey),
                      ],
                    ],
                  ),
                ),

              const SizedBox(height: 32),
            ],
          );
        },
      ),
    );
  }

  Widget _buildTimelineTile(
    BuildContext context, {
    required bool isFirst,
    required bool isLast,
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required Widget content,
  }) {
    final theme = Theme.of(context);
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Timeline indicator line
          SizedBox(
            width: 40,
            child: Column(
              children: [
                Container(
                  width: 2,
                  height: 12,
                  color: isFirst ? Colors.transparent : theme.colorScheme.outlineVariant,
                ),
                CircleAvatar(
                  radius: 14,
                  backgroundColor: iconColor.withValues(alpha: 0.15),
                  child: Icon(icon, size: 16, color: iconColor),
                ),
                Expanded(
                  child: Container(
                    width: 2,
                    color: isLast ? Colors.transparent : theme.colorScheme.outlineVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          // Content card
          Expanded(
            child: Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 11)),
                  const SizedBox(height: 8),
                  content,
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _badge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.bold),
      ),
    );
  }
}
