import 'package:flutter_test/flutter_test.dart';
import 'package:factoryflow/core/widgets/shared_widgets.dart';

void main() {
  group('formatTimeWithoutSeconds tests', () {
    test('strips seconds from HH:mm:ss format', () {
      expect(formatTimeWithoutSeconds('10:35:00'), '10:35');
      expect(formatTimeWithoutSeconds('16:00:00'), '16:00');
      expect(formatTimeWithoutSeconds('23:37:00'), '23:37');
      expect(formatTimeWithoutSeconds('01:05:30'), '01:05');
      expect(formatTimeWithoutSeconds('9:5:00'), '09:05');
    });

    test('preserves already clean HH:mm format', () {
      expect(formatTimeWithoutSeconds('10:35'), '10:35');
      expect(formatTimeWithoutSeconds('16:00'), '16:00');
      expect(formatTimeWithoutSeconds('07:30'), '07:30');
    });

    test('handles subseconds / microseconds', () {
      expect(formatTimeWithoutSeconds('01:14:39.57945'), '01:14');
      expect(formatTimeWithoutSeconds('14:47:45.928844'), '14:47');
    });

    test('handles 12-hour format with AM/PM', () {
      expect(formatTimeWithoutSeconds('10:35:00 AM'), '10:35 AM');
      expect(formatTimeWithoutSeconds('04:15:30 PM'), '04:15 PM');
      expect(formatTimeWithoutSeconds('10:35 AM'), '10:35 AM');
    });

    test('handles full ISO string', () {
      expect(formatTimeWithoutSeconds('2026-09-01T16:00:00+00:00'), isNotEmpty);
      expect(formatTimeWithoutSeconds('2026-09-01 10:35:00'), '10:35');
    });

    test('handles null and empty values gracefully', () {
      expect(formatTimeWithoutSeconds(null), '');
      expect(formatTimeWithoutSeconds(''), '');
      expect(formatTimeWithoutSeconds('   '), '');
    });
  });

  group('formatDateTimeLabel tests', () {
    test('combines date and time without seconds', () {
      expect(formatDateTimeLabel('2026-09-04', '10:35:00'), '2026-09-04 10:35');
      expect(formatDateTimeLabel('2026-09-01', '16:00:00'), '2026-09-01 16:00');
    });

    test('returns only date if time is null or empty', () {
      expect(formatDateTimeLabel('2026-09-04', null), '2026-09-04');
      expect(formatDateTimeLabel('2026-09-04', ''), '2026-09-04');
      expect(formatDateTimeLabel('2026-09-04', '   '), '2026-09-04');
    });

    test('returns only time if date is null or empty', () {
      expect(formatDateTimeLabel(null, '10:35:00'), '10:35');
      expect(formatDateTimeLabel('', '10:35:00'), '10:35');
    });

    test('handles both null or empty', () {
      expect(formatDateTimeLabel(null, null), '');
      expect(formatDateTimeLabel('', ''), '');
    });
  });
}
