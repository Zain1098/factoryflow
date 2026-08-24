import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/database_service.dart';
import '../../core/widgets/shared_widgets.dart';
import '../auth/auth_providers.dart';
import '../../core/constants/user_roles.dart';

final _conflictsProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final db = ref.watch(databaseServiceProvider);
  final rows = db.db.select(
    "SELECT * FROM sync_conflicts WHERE factory_id = ? "
    "ORDER BY created_at DESC LIMIT 100",
    [db.activeWorkspaceId],
  );
  return rows.map((r) => Map<String, dynamic>.from(r)).toList();
});

class ConflictReviewScreen extends ConsumerWidget {
  const ConflictReviewScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conflicts = ref.watch(_conflictsProvider);
    final role = ref.watch(userRoleProvider);
    final isAdmin = role == UserRole.admin || role == UserRole.owner;

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Sync Conflicts'),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () => ref.invalidate(_conflictsProvider),
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Pending'),
              Tab(text: 'Resolved'),
            ],
          ),
        ),
        body: conflicts.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) =>
              EmptyState(message: 'Error: $e', icon: Icons.error_outline),
          data: (all) {
            final pending =
                all.where((r) => r['status'] == 'pending').toList();
            final resolved =
                all.where((r) => r['status'] != 'pending').toList();
            return TabBarView(
              children: [
                _ConflictList(
                  items: pending,
                  isAdmin: isAdmin,
                  onResolved: () => ref.invalidate(_conflictsProvider),
                  emptyMessage:
                      'No pending conflicts.\nAll sync operations are clean.',
                ),
                _ConflictList(
                  items: resolved,
                  isAdmin: false,
                  onResolved: () {},
                  emptyMessage: 'No resolved conflicts yet.',
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ConflictList extends ConsumerWidget {
  const _ConflictList({
    required this.items,
    required this.isAdmin,
    required this.onResolved,
    required this.emptyMessage,
  });

  final List<Map<String, dynamic>> items;
  final bool isAdmin;
  final VoidCallback onResolved;
  final String emptyMessage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (items.isEmpty) {
      return EmptyState(
        message: emptyMessage,
        icon: Icons.check_circle_outline,
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: items.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final r = items[i];
        final status = r['status'] as String? ?? 'pending';
        final entityType = r['entity_type'] as String? ?? '—';
        final serverReason = r['server_reason'] as String? ?? '—';
        final suggested = r['suggested_action'] as String? ?? '';
        final createdAt = r['created_at'] as String? ?? '';

        return ListTile(
          leading: CircleAvatar(
            backgroundColor: _statusColor(status).withValues(alpha: 0.12),
            child: Icon(
              _statusIcon(status),
              color: _statusColor(status),
              size: 20,
            ),
          ),
          title: Text(
            _entityLabel(entityType),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(serverReason, maxLines: 2, overflow: TextOverflow.ellipsis),
              if (suggested.isNotEmpty)
                Text(
                  'Suggested: ${_suggestedLabel(suggested)}',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              Text(
                createdAt.length > 10 ? createdAt.substring(0, 10) : createdAt,
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ],
          ),
          isThreeLine: true,
          trailing: status == 'pending' && isAdmin
              ? _ActionMenu(
                  conflictId: r['id'] as String,
                  onResolved: onResolved,
                )
              : Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
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
        );
      },
    );
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'resolved':
        return Colors.green;
      case 'cancelled':
        return Colors.grey;
      default:
        return Colors.orange;
    }
  }

  IconData _statusIcon(String status) {
    switch (status) {
      case 'resolved':
        return Icons.check_circle;
      case 'cancelled':
        return Icons.cancel;
      default:
        return Icons.warning_amber_rounded;
    }
  }

  String _entityLabel(String type) {
    const labels = {
      'productions': 'Production Entry',
      'stock_ledger': 'Stock Ledger',
      'material_receives': 'Material Receive',
      'bp_inspections': 'BP Inspection',
      'dispatch_to_facos': 'Dispatch to Vendor',
      'receive_from_facos': 'Receive from Vendor',
      'ap_inspections': 'AP Inspection',
      'rtvs': 'Return to Vendor',
      'rtv_reinspections': 'RTV Reinspection',
      'final_dispatches': 'Final Dispatch',
      'dispatch_sessions': 'Dispatch Session',
      'dispatch_items': 'Dispatch Item',
    };
    return labels[type] ?? type;
  }

  String _suggestedLabel(String action) {
    const labels = {
      'review_stock_balance': 'Review stock balance',
      'review_production_stock': 'Review production stock',
      'cancel_local_entry': 'Cancel local entry',
      'correct_quantity': 'Correct quantity',
      'map_missing_master': 'Map missing master record',
    };
    return labels[action] ?? action;
  }
}

class _ActionMenu extends ConsumerWidget {
  const _ActionMenu({required this.conflictId, required this.onResolved});

  final String conflictId;
  final VoidCallback onResolved;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert),
      onSelected: (action) async {
        final user = ref.read(currentUserProvider).value;
        await ref.read(databaseServiceProvider).resolveConflict(
              conflictId,
              action,
              user?.id ?? 'admin',
            );
        onResolved();
      },
      itemBuilder: (_) => const [
        PopupMenuItem(
          value: 'resolved',
          child: Row(
            children: [
              Icon(Icons.check_circle_outline, color: Colors.green, size: 18),
              SizedBox(width: 8),
              Text('Mark Resolved'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'cancelled',
          child: Row(
            children: [
              Icon(Icons.cancel_outlined, color: Colors.grey, size: 18),
              SizedBox(width: 8),
              Text('Cancel / Dismiss'),
            ],
          ),
        ),
      ],
    );
  }
}
