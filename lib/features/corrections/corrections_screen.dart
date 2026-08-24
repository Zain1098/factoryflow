import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/database_service.dart';
import '../../core/widgets/shared_widgets.dart';
import '../auth/auth_providers.dart';

final _correctionsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final db = ref.watch(databaseServiceProvider);
  final workspaceId = db.activeWorkspaceId.trim();
  if (workspaceId.isEmpty) return [];
  final rows = db.db.select(
    '''
    SELECT * FROM correction_requests
    WHERE factory_id = ?
    ORDER BY requested_at DESC
    LIMIT 50
    ''',
    [workspaceId],
  );
  return rows.map((r) => Map<String, dynamic>.from(r)).toList();
});

class CorrectionsScreen extends ConsumerWidget {
  const CorrectionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final corrections = ref.watch(_correctionsProvider);
    final role = ref.watch(userRoleProvider);
    final isApprover = role?.canApproveCorrections ?? false;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Correction Requests'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(_correctionsProvider),
          ),
        ],
      ),
      body: corrections.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(message: 'Error: $e', icon: Icons.error_outline),
        data: (records) {
          if (records.isEmpty) {
            return const EmptyState(
              message: 'No correction requests.\n\nAfter day rollover, edits require a correction request approved by Admin.',
              icon: Icons.gavel_outlined,
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
                // FIXED: Show human-readable table label instead of raw table name
                title: Text(
                  '${_tableLabel(r['table_name'] as String? ?? '')} — ${_shortId(r['record_id'] as String? ?? '')}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(r['reason'] as String? ?? '—'),
                trailing: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: _statusColor(status).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        status.toUpperCase(),
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: _statusColor(status),
                        ),
                      ),
                    ),
                    if (isApprover && status == 'pending') ...[
                      const SizedBox(height: 4),
                      const Text('Tap to review',
                          style: TextStyle(fontSize: 10, color: Colors.grey),),
                    ],
                  ],
                ),
                onTap: isApprover && status == 'pending'
                    ? () => _showReviewDialog(context, ref, r)
                    : null,
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _showReviewDialog(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic> record,
  ) async {
    final remarksCtrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Review Correction Request'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Module: ${_tableLabel(record['table_name'] as String? ?? '')}'),
            const SizedBox(height: 4),
            Text('Reason: ${record['reason']}'),
            const SizedBox(height: 12),
            TextField(
              controller: remarksCtrl,
              decoration: const InputDecoration(
                labelText: 'Admin remarks',
                border: OutlineInputBorder(),
              ),
              maxLines: 2,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          OutlinedButton(
            onPressed: () => Navigator.pop(ctx, 'rejected'),
            child: const Text('Reject'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'approved'),
            child: const Text('Approve'),
          ),
        ],
      ),
    );

    if (result != null) {
      final user = ref.read(currentUserProvider).value;
      // FIXED: Use repository method that also enqueues sync — no raw SQL bypass
      await ref.read(databaseServiceProvider).updateCorrectionStatus(
        id: record['id'] as String,
        status: result,
        reviewedBy: user?.id,
        reviewRemarks: remarksCtrl.text.trim(),
      );
      ref.invalidate(_correctionsProvider);
    }
  }

  String _tableLabel(String table) {
    const labels = {
      'productions': 'Production Entry',
      'material_receives': 'Material Receive',
      'machine_downtimes': 'Machine Downtime',
      'bp_inspections': 'BP Inspection',
      'dispatch_to_facos': 'Dispatch to Vendor',
      'receive_from_facos': 'Receive from Vendor',
      'ap_inspections': 'AP Inspection',
      'rtvs': 'Return to Vendor',
      'final_dispatches': 'Final Dispatch',
    };
    return labels[table] ?? table;
  }

  /// Shows only the first 8 chars of a UUID for readability.
  String _shortId(String id) => id.length > 8 ? '#${id.substring(0, 8)}' : '#$id';

  Color _statusColor(String status) {
    switch (status) {
      case 'approved': return Colors.green;
      case 'rejected': return Colors.red;
      default: return Colors.orange;
    }
  }

  IconData _statusIcon(String status) {
    switch (status) {
      case 'approved': return Icons.check_circle;
      case 'rejected': return Icons.cancel;
      default: return Icons.pending;
    }
  }
}
