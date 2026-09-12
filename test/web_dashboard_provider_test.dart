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

    test('FakeDb provides report aliases and live stock stage balances', () {
      final tables = <String, List<Map<String, dynamic>>>{
        'parts': [
          {'id': 'part1', 'name': 'Bracket', 'code': 'BRK-01', 'factory_id': 'f1', 'active': 1},
        ],
        'stock_ledger': [
          {'part_id': 'part1', 'factory_id': 'f1', 'stage': 'raw_material', 'running_balance': 500.0},
          {'part_id': 'part1', 'factory_id': 'f1', 'stage': 'bp_stock', 'running_balance': 200.0},
        ],
        'machines': [
          {'id': 'm1', 'name': 'Press', 'factory_id': 'f1', 'active': 1},
        ],
        'productions': [
          {
            'id': 'pr1',
            'factory_id': 'f1',
            'machine_id': 'm1',
            'part_id': 'part1',
            'date': '2026-09-12',
            'production_qty': 100.0,
            'bp_reject_qty': 5.0,
            'good_qty': 95.0,
          },
        ],
        'machine_downtimes': [
          {
            'id': 'dt1',
            'factory_id': 'f1',
            'machine_id': 'm1',
            'date': '2026-09-12',
            'duration_minutes': 45,
          },
        ],
        'target_master': [
          {'factory_id': 'f1', 'day_of_week': 6, 'target_qty': 1000.0},
        ],
      };

      final fakeDb = FakeDb(tables, () {});

      // 1. Live stock query
      final liveStockRows = fakeDb.select(
        "SELECT p.id, p.name, p.code, COALESCE(MAX(CASE WHEN sl.stage='raw_material' THEN sl.running_balance END), 0) AS raw FROM parts p WHERE p.factory_id = ? AND p.active = 1 GROUP BY p.id, p.name, p.code",
        ['f1'],
      );
      expect(liveStockRows.length, 1);
      expect(liveStockRows.first['raw'], 500.0);
      expect(liveStockRows.first['bp'], 200.0);

      // 2. Machine report query
      final machineRows = fakeDb.select(
        "SELECT m.name AS machine_name, COALESCE(SUM(p.production_qty), 0) AS total_prod FROM machines m WHERE m.factory_id = ? GROUP BY m.id, m.name",
        ['f1'],
      );
      expect(machineRows.length, 1);
      expect(machineRows.first['total_prod'], 100.0);
      expect(machineRows.first['bp_rej'], 5.0);
      expect(machineRows.first['good'], 95.0);
      expect(machineRows.first['downtime_mins'], 45);

      // 3. Downtime grouped by date query
      final dtRows = fakeDb.select(
        "SELECT date, COALESCE(SUM(duration_minutes), 0) AS dt_mins FROM machine_downtimes WHERE factory_id = ? GROUP BY date",
        ['f1'],
      );
      expect(dtRows.length, 1);
      expect(dtRows.first['date'], '2026-09-12');
      expect(dtRows.first['dt_mins'], 45);

      // 4. Daily production query aliases
      final prodRows = fakeDb.select(
        "SELECT p.date, p.machine_id, COALESCE(p.production_qty, 0) AS prod_qty FROM productions p WHERE p.factory_id = ? AND p.date BETWEEN ? AND ?",
        ['f1', '2026-09-01', '2026-09-30'],
      );
      expect(prodRows.length, 1);
      expect(prodRows.first['prod_qty'], 100.0);
      expect(prodRows.first['rej_qty'], 5.0);
      expect(prodRows.first['good_qty'], 95.0);
      expect(prodRows.first['machine_name'], 'Press');
    });
  });
}

