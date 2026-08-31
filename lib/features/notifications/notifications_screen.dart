import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/database/database_service.dart';
import '../../core/widgets/shared_widgets.dart';
import 'notification_providers.dart';

class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notificationsAsync = ref.watch(inAppNotificationsProvider);
    final selectedCategory = ref.watch(selectedNotificationCategoryProvider);
    final theme = Theme.of(context);

    final categories = <Map<String, String?>>[
      {'label': 'All', 'type': null},
      {'label': 'Low Stock', 'type': 'low_stock'},
      {'label': 'Breakdown', 'type': 'downtime'},
      {'label': 'Targets', 'type': 'target'},
      {'label': 'RTV Pending', 'type': 'rtv'},
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications Hub'),
        actions: [
          IconButton(
            icon: const Icon(Icons.done_all_rounded),
            tooltip: 'Mark all as read',
            onPressed: () async {
              await ref.read(databaseServiceProvider).markAllNotificationsAsRead();
              ref.invalidate(inAppNotificationsProvider);
              ref.invalidate(unreadNotificationCountProvider);
            },
          ),
          PopupMenuButton<String>(
            tooltip: 'More actions',
            onSelected: (val) async {
              if (val == 'clear') {
                final confirmed = await showConfirmDialog(
                  context,
                  title: 'Clear Notifications',
                  message: 'Are you sure you want to delete all notifications?',
                  confirmLabel: 'Clear All',
                  isDestructive: true,
                );
                if (confirmed) {
                  await ref.read(databaseServiceProvider).clearAllNotifications();
                  ref.invalidate(inAppNotificationsProvider);
                  ref.invalidate(unreadNotificationCountProvider);
                }
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'clear',
                child: Row(
                  children: [
                    Icon(Icons.delete_sweep_outlined, size: 20, color: Colors.red),
                    SizedBox(width: 10),
                    Text('Clear all notifications', style: TextStyle(color: Colors.red)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Category Filter Bar ──────────────────────────────────────────
          Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: categories.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, idx) {
                final cat = categories[idx];
                final isSelected = selectedCategory == cat['type'];
                return ChoiceChip(
                  label: Text(cat['label']!),
                  selected: isSelected,
                  onSelected: (_) {
                    ref
                        .read(selectedNotificationCategoryProvider.notifier)
                        .setCategory(cat['type']);
                  },
                );
              },
            ),
          ),
          const Divider(height: 1),

          // ── Notification Items List ──────────────────────────────────────
          Expanded(
            child: notificationsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(
                child: EmptyState(
                  message: 'Could not load notifications.\n$e',
                  icon: Icons.error_outline,
                ),
              ),
              data: (items) {
                if (items.isEmpty) {
                  return const EmptyState(
                    message:
                        'No notifications in this category.\n\nAlerts for low stock, target misses, breakdowns, and RTVs will appear here automatically.',
                    icon: Icons.notifications_none_rounded,
                  );
                }

                return RefreshIndicator(
                  onRefresh: () async {
                    ref.invalidate(inAppNotificationsProvider);
                    ref.invalidate(unreadNotificationCountProvider);
                  },
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
                    itemBuilder: (context, i) {
                      final notif = items[i];
                      final id = notif['id'] as String;
                      final title = notif['title'] as String? ?? 'Notification';
                      final body = notif['body'] as String? ?? '';
                      final type = notif['type'] as String? ?? 'general';
                      final isRead = (notif['is_read'] as int? ?? 0) == 1;
                      final actionRoute = notif['action_route'] as String?;
                      final createdAtStr = notif['created_at'] as String?;
                      final createdAt = createdAtStr != null
                          ? DateTime.tryParse(createdAtStr)?.toLocal()
                          : null;

                      final iconData = _iconForType(type);
                      final iconColor = _colorForType(type);

                      return InkWell(
                        onTap: () async {
                          if (!isRead) {
                            await ref
                                .read(databaseServiceProvider)
                                .markNotificationAsRead(id);
                            ref.invalidate(inAppNotificationsProvider);
                            ref.invalidate(unreadNotificationCountProvider);
                          }
                          if (actionRoute != null && actionRoute.isNotEmpty) {
                            if (context.mounted) {
                              context.push(actionRoute);
                            }
                          }
                        },
                        child: Container(
                          color: isRead
                              ? Colors.transparent
                              : theme.colorScheme.primaryContainer.withValues(alpha: 0.18),
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              CircleAvatar(
                                radius: 20,
                                backgroundColor: iconColor.withValues(alpha: 0.15),
                                child: Icon(iconData, color: iconColor, size: 20),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            title,
                                            style: theme.textTheme.titleSmall?.copyWith(
                                              fontWeight: isRead
                                                  ? FontWeight.w600
                                                  : FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                        if (!isRead)
                                          Container(
                                            width: 8,
                                            height: 8,
                                            margin: const EdgeInsets.only(left: 6),
                                            decoration: BoxDecoration(
                                              color: theme.colorScheme.primary,
                                              shape: BoxShape.circle,
                                            ),
                                          ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      body,
                                      style: theme.textTheme.bodyMedium?.copyWith(
                                        color: theme.colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Text(
                                          createdAt != null
                                              ? DateFormat('dd MMM, hh:mm a').format(createdAt)
                                              : 'Just now',
                                          style: theme.textTheme.labelSmall?.copyWith(
                                            color: theme.colorScheme.onSurfaceVariant
                                                .withValues(alpha: 0.7),
                                          ),
                                        ),
                                        if (actionRoute != null && actionRoute.isNotEmpty)
                                          Row(
                                            children: [
                                              Text(
                                                'View details',
                                                style: theme.textTheme.labelSmall?.copyWith(
                                                  color: theme.colorScheme.primary,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                              Icon(
                                                Icons.chevron_right,
                                                size: 14,
                                                color: theme.colorScheme.primary,
                                              ),
                                            ],
                                          ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  IconData _iconForType(String type) {
    switch (type) {
      case 'low_stock':
        return Icons.inventory_2_outlined;
      case 'downtime':
        return Icons.build_circle_outlined;
      case 'target':
        return Icons.trending_up_rounded;
      case 'rtv':
        return Icons.assignment_return_outlined;
      case 'sync':
        return Icons.sync_problem_rounded;
      case 'correction':
        return Icons.gavel_rounded;
      default:
        return Icons.notifications_active_outlined;
    }
  }

  Color _colorForType(String type) {
    switch (type) {
      case 'low_stock':
        return Colors.orange;
      case 'downtime':
        return Colors.red;
      case 'target':
        return Colors.blue;
      case 'rtv':
        return Colors.deepOrange;
      case 'sync':
        return Colors.amber;
      case 'correction':
        return Colors.purple;
      default:
        return Colors.teal;
    }
  }
}
