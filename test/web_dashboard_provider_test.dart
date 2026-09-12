import 'package:factoryflow/core/database/database_service_web.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Web FakeDb aggregate queries', () {
    test('FakeDb returns aggregate sum and count correctly even when empty', () {
      final tables = <String, List<Map<String, dynamic>>>{
        'productions': [],
        'machine_downtimes': [],
        'correction_requests': [],
        'machines': [
          {'id': 'm1', 'name': 'Bending', 'factory_id': 'f1', 'active': 1},
        ],
      };

      final fakeDb = FakeDb(tables, () {});

      // 1. SELECT machines
      final machines = fakeDb.select(
        'SELECT id, name FROM machines WHERE factory_id = ? AND active = 1',
        ['f1'],
      );
      expect(machines.length, 1);
      expect(machines.first['name'], 'Bending');

      // 2. Aggregate SUM on empty productions
      final mProd = fakeDb.select(
        'SELECT SUM(production_qty) as qty FROM productions '
        'WHERE factory_id = ? AND machine_id = ? AND date = ?',
        ['f1', 'm1', '2026-09-12'],
      );
      expect(mProd.isNotEmpty, isTrue);
      expect(mProd.first['qty'], 0.0);

      // 3. Aggregate COALESCE SUM
      final wProd = fakeDb.select(
        'SELECT COALESCE(SUM(CASE WHEN ? = 1 THEN good_qty ELSE 0 END), 0) as qty '
        'FROM productions WHERE factory_id = ? AND date = ?',
        [1, 'f1', '2026-09-12'],
      );
      expect(wProd.isNotEmpty, isTrue);
      expect(wProd.first['qty'], 0.0);

      // 4. Aggregate COUNT
      final pendingCorrectionRows = fakeDb.select(
        "SELECT COUNT(*) as cnt FROM correction_requests "
        "WHERE factory_id = ? AND status = 'pending'",
        ['f1'],
      );
      expect(pendingCorrectionRows.isNotEmpty, isTrue);
      expect(pendingCorrectionRows.first['cnt'], 0);

      // 5. Downtime aggregate SUM
      final downtimeRows = fakeDb.select(
        'SELECT COALESCE(SUM(duration_minutes), 0) as total_mins '
        'FROM machine_downtimes WHERE factory_id = ? AND date = ?',
        ['f1', '2026-09-12'],
      );
      expect(downtimeRows.isNotEmpty, isTrue);
      expect(downtimeRows.first['total_mins'], 0.0);
    });

    test('FakeDb correctly sums existing rows', () {
      final tables = <String, List<Map<String, dynamic>>>{
        'productions': [
          {
            'id': 'p1',
            'factory_id': 'f1',
            'machine_id': 'm1',
            'date': '2026-09-12',
            'production_qty': 150.0,
          },
          {
            'id': 'p2',
            'factory_id': 'f1',
            'machine_id': 'm1',
            'date': '2026-09-12',
            'production_qty': 250.0,
          },
        ],
      };

      final fakeDb = FakeDb(tables, () {});

      final mProd = fakeDb.select(
        'SELECT SUM(production_qty) as qty FROM productions '
        'WHERE factory_id = ? AND machine_id = ? AND date = ?',
        ['f1', 'm1', '2026-09-12'],
      );
      expect(mProd.length, 1);
      expect(mProd.first['qty'], 400.0);
    });
  });
}
