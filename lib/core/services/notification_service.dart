import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  static const _channelId = 'factoryflow_alerts';
  static const _channelName = 'Factory Alerts';

  Future<void> initialize() async {
    if (_initialized || kIsWeb) return;

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: false,
    );

    await _plugin.initialize(
      const InitializationSettings(android: android, iOS: ios),
    );

    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();

    _initialized = true;
  }

  Future<void> showAlert({
    required int id,
    required String title,
    required String body,
  }) async {
    if (!_initialized) return;
    await _plugin.show(
      id,
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          importance: Importance.high,
          priority: Priority.high,
          icon: '@mipmap/ic_launcher',
        ),
        iOS: DarwinNotificationDetails(),
      ),
    );
  }

  Future<void> showSyncFailure(int failedCount) => showAlert(
        id: 1,
        title: 'Sync Failed',
        body: '$failedCount record(s) failed to sync. Check connection.',
      );

  Future<void> showLowStock(String partName, double qty) => showAlert(
        id: 2,
        title: 'Low Stock Alert',
        body: '$partName has only ${qty.toInt()} PCS remaining.',
      );

  Future<void> showRtvPending(int count) => showAlert(
        id: 3,
        title: 'RTV Pending',
        body: '$count RTV item(s) awaiting return from vendor.',
      );

  Future<void> showMachineBreakdown(String machineName) => showAlert(
        id: 4,
        title: 'Machine Breakdown',
        body: '$machineName is currently in breakdown.',
      );
}
