import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/database_service.dart';

class SelectedNotificationCategoryNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void setCategory(String? category) => state = category;
}

final selectedNotificationCategoryProvider =
    NotifierProvider<SelectedNotificationCategoryNotifier, String?>(
  SelectedNotificationCategoryNotifier.new,
);

final inAppNotificationsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final db = ref.watch(databaseServiceProvider);
  final category = ref.watch(selectedNotificationCategoryProvider);
  return db.getInAppNotifications(type: category, limit: 100);
});

final unreadNotificationCountProvider =
    FutureProvider.autoDispose<int>((ref) async {
  final db = ref.watch(databaseServiceProvider);
  return db.getUnreadNotificationCount();
});
