import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/database_service.dart';
import '../../core/widgets/shared_widgets.dart';
import '../auth/auth_providers.dart';
import '../../core/constants/user_roles.dart';

final _correctionsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final db = ref.watch(databaseServiceProvider);
  final rows = db.db.select(
    'SELECT * FROM correction_requests ORDER BY requested_at DESC LIMIT 50',
  );
  return rows.map((r) => Map<String, dynamic>.from(r)).toList();
});

class CorrectionsScreen extends ConsumerWidget {
  const CorrectionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final corrections = ref.watch(_correctionsProvider);
    final role = ref.watch(userRoleProvider);
    final isAdmin = role == UserRole.admin;

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
                title: Text('${r['table_name']} · ${r['record_id']}',
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 13),),
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
                    if (isAdmin && status == 'pending') ...[
                      const SizedBox(height: 4),
                      const Text('Tap to review',
                          style: TextStyle(fontSize: 10, color: Colors.grey),),
                    ],
                  ],
                ),
                onTap: isAdmin && status == 'pending'
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
            Text('Table: ${record['table_name']}'),
            Text('Reason: ${record['reason']}'),
            const SizedBox(height: 12),
            TextField(
              controller: remarksCtrl,
              decoration: const InputDecoration(
                labelText: 'Admin remarks (required for rejection)',
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
      final db = ref.read(databaseServiceProvider);
      db.db.execute(
        'UPDATE correction_requests SET status = ?, reviewed_at = ? WHERE id = ?',
        [result, DateTime.now().toIso8601String(), record['id']],
      );
      ref.invalidate(_correctionsProvider);
    }
  }

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
