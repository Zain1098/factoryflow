import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

class WorkReminder {
  const WorkReminder({
    required this.id,
    required this.hour,
    required this.minute,
    required this.message,
    this.enabled = true,
    this.skipSunday = true,
    this.skipFirstSaturday = true,
    this.skipThirdSaturday = true,
  });

  final int id;
  final int hour;
  final int minute;
  final String message;
  final bool enabled;
  final bool skipSunday;
  final bool skipFirstSaturday;
  final bool skipThirdSaturday;

  WorkReminder copyWith({
    int? hour,
    int? minute,
    String? message,
    bool? enabled,
    bool? skipSunday,
    bool? skipFirstSaturday,
    bool? skipThirdSaturday,
  }) => WorkReminder(
    id: id,
    hour: hour ?? this.hour,
    minute: minute ?? this.minute,
    message: message ?? this.message,
    enabled: enabled ?? this.enabled,
    skipSunday: skipSunday ?? this.skipSunday,
    skipFirstSaturday: skipFirstSaturday ?? this.skipFirstSaturday,
    skipThirdSaturday: skipThirdSaturday ?? this.skipThirdSaturday,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'hour': hour,
    'minute': minute,
    'message': message,
    'enabled': enabled,
    'skip_sunday': skipSunday,
    'skip_first_saturday': skipFirstSaturday,
    'skip_third_saturday': skipThirdSaturday,
  };

  static WorkReminder fromJson(Map<String, dynamic> json) => WorkReminder(
    id: json['id'] as int,
    hour: json['hour'] as int,
    minute: json['minute'] as int,
    message: json['message'] as String,
    enabled: json['enabled'] as bool? ?? true,
    skipSunday: json['skip_sunday'] as bool? ?? true,
    skipFirstSaturday: json['skip_first_saturday'] as bool? ?? true,
    skipThirdSaturday: json['skip_third_saturday'] as bool? ?? true,
  );
}

bool shouldScheduleWorkReminder(WorkReminder reminder, DateTime date) {
  if (reminder.skipSunday && date.weekday == DateTime.sunday) return false;
  if (date.weekday != DateTime.saturday) return true;
  final saturdayNumber = ((date.day - 1) ~/ 7) + 1;
  if (reminder.skipFirstSaturday && saturdayNumber == 1) return false;
  if (reminder.skipThirdSaturday && saturdayNumber == 3) return false;
  return true;
}

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  static const _channelId = 'factoryflow_alerts';
  static const _channelName = 'Factory Alerts';
  static const _reminderChannelId = 'factoryflow_work_reminders';
  static const _reminderChannelName = 'FactoryFlow Work Reminders';
  static const _workReminderKey = 'factoryflow_work_reminders';
  static const _scheduledDays = 90;

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
    await rescheduleWorkReminders();
  }

  Future<List<WorkReminder>> loadWorkReminders() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_workReminderKey);
    if (raw == null) {
      const defaults = [
        WorkReminder(
          id: 1001,
          hour: 10,
          minute: 0,
          message: 'Reminder: enter today\'s factory data.',
        ),
        WorkReminder(
          id: 1002,
          hour: 16,
          minute: 0,
          message: 'Reminder: add today\'s production.',
        ),
      ];
      await _saveWorkReminders(defaults, reschedule: false);
      return defaults;
    }
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .map((value) => WorkReminder.fromJson(Map<String, dynamic>.from(value as Map)))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveWorkReminders(List<WorkReminder> reminders) async {
    final previous = await loadWorkReminders();
    await _saveWorkReminders(reminders, reschedule: false);
    await rescheduleWorkReminders(
      reminders: reminders,
      cancelReminders: [...previous, ...reminders],
    );
  }

  Future<void> _saveWorkReminders(
    List<WorkReminder> reminders, {
    required bool reschedule,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _workReminderKey,
      jsonEncode(reminders.map((reminder) => reminder.toJson()).toList()),
    );
    if (reschedule) await rescheduleWorkReminders(reminders: reminders);
  }

  Future<void> rescheduleWorkReminders({
    List<WorkReminder>? reminders,
    List<WorkReminder>? cancelReminders,
  }) async {
    if (!_initialized || kIsWeb) return;
    final saved = reminders ?? await loadWorkReminders();
    final toCancel = cancelReminders ?? saved;
    for (final reminder in toCancel) {
      for (var day = 0; day < _scheduledDays; day++) {
        await _plugin.cancel(_notificationId(reminder.id, day));
      }
    }
    final preferences = await SharedPreferences.getInstance();
    if (!(preferences.getBool('notif_enabled') ?? true)) return;
    tz.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('Asia/Karachi'));
    final now = tz.TZDateTime.now(tz.local);
    final scheduleMode = await _reminderScheduleMode();
    for (final reminder in saved.where((item) => item.enabled)) {
      for (var day = 0; day < _scheduledDays; day++) {
        final date = now.add(Duration(days: day));
        if (!shouldScheduleWorkReminder(reminder, date)) continue;
        final scheduled = tz.TZDateTime(
          tz.local,
          date.year,
          date.month,
          date.day,
          reminder.hour,
          reminder.minute,
        );
        if (!scheduled.isAfter(now)) continue;
        await _plugin.zonedSchedule(
          _notificationId(reminder.id, day),
          'FactoryFlow reminder',
          reminder.message,
          scheduled,
          const NotificationDetails(
            android: AndroidNotificationDetails(
              _reminderChannelId,
              _reminderChannelName,
              importance: Importance.high,
              priority: Priority.high,
              icon: '@mipmap/ic_launcher',
            ),
          ),
          androidScheduleMode: scheduleMode,
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
        );
      }
    }
  }

  int _notificationId(int reminderId, int day) => reminderId * 1000 + day;

  Future<void> refreshWorkReminders() => rescheduleWorkReminders();

  Future<AndroidScheduleMode> _reminderScheduleMode() async {
    try {
      final android = await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      final canScheduleExactly = await android?.canScheduleExactNotifications();
      return canScheduleExactly == false
          ? AndroidScheduleMode.inexactAllowWhileIdle
          : AndroidScheduleMode.exactAllowWhileIdle;
    } catch (_) {
      return AndroidScheduleMode.inexactAllowWhileIdle;
    }
  }

  Future<void> showAlert({
    required int id,
    required String title,
    required String body,
    String? preferenceKey,
  }) async {
    if (!_initialized) return;
    final preferences = await SharedPreferences.getInstance();
    if (!(preferences.getBool('notif_enabled') ?? true)) return;
    if (preferenceKey != null &&
        !(preferences.getBool(preferenceKey) ?? true)) {
      return;
    }
    final playSound = preferences.getBool('notif_sound') ?? true;
    final enableVibration = preferences.getBool('notif_vibration') ?? true;
    await _plugin.show(
      id,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          importance: Importance.high,
          priority: Priority.high,
          icon: '@mipmap/ic_launcher',
          playSound: playSound,
          enableVibration: enableVibration,
        ),
        iOS: DarwinNotificationDetails(
          presentSound: playSound,
        ),
      ),
    );
  }

  // Sync failures are visible through the compact cloud status control. They
  // are intentionally silent because transient retries are expected offline.
  Future<void> showSyncFailure(int failedCount) async {}

  Future<void> showLowStock(String partName, double qty) => showAlert(
        id: 2,
        title: 'Low Stock Alert',
        body: '$partName has only ${qty.toInt()} PCS remaining.',
        preferenceKey: 'notif_production',
      );

  Future<void> showRtvPending(int count) => showAlert(
        id: 3,
        title: 'RTV Pending',
        body: '$count RTV item(s) awaiting return from vendor.',
        preferenceKey: 'notif_production',
      );

  Future<void> showMachineBreakdown(String machineName) => showAlert(
        id: 4,
        title: 'Machine Breakdown',
        body: '$machineName is currently in breakdown.',
        preferenceKey: 'notif_downtime',
      );

  Future<void> showAppUpdate({
    required int versionCode,
    required String versionName,
    required bool isRequired,
  }) async {
    if (!_initialized) return;
    final preferences = await SharedPreferences.getInstance();
    const key = 'factoryflow_notified_android_release_code';
    if (preferences.getInt(key) == versionCode) return;
    await showAlert(
      id: 6,
      title: 'FactoryFlow update available',
      body: isRequired
          ? 'Version $versionName is required. Open Settings to download it.'
          : 'Version $versionName is ready. Open Settings to download it.',
      preferenceKey: 'notif_updates',
    );
    await preferences.setInt(key, versionCode);
  }
}
