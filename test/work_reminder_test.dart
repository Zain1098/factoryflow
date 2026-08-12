import 'package:factoryflow/core/services/notification_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const reminder = WorkReminder(
    id: 1,
    hour: 10,
    minute: 0,
    message: 'Enter data',
  );

  test('work reminder skips Sunday and the first and third Saturdays', () {
    expect(shouldScheduleWorkReminder(reminder, DateTime(2026, 8, 2)), isFalse);
    expect(shouldScheduleWorkReminder(reminder, DateTime(2026, 8, 1)), isFalse);
    expect(shouldScheduleWorkReminder(reminder, DateTime(2026, 8, 8)), isTrue);
    expect(shouldScheduleWorkReminder(reminder, DateTime(2026, 8, 15)), isFalse);
    expect(shouldScheduleWorkReminder(reminder, DateTime(2026, 8, 17)), isTrue);
  });
}
