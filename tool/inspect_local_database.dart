import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

void main(List<String> arguments) {
  if (arguments.length != 1) {
    stderr
        .writeln('Usage: dart run tool/inspect_local_database.dart <db-path>');
    exitCode = 64;
    return;
  }

  final database = sqlite3.open(arguments.single, mode: OpenMode.readOnly);
  try {
    _printRows(
      'workspaces',
      database.select(
        'SELECT id, name, active, created_at FROM workspaces ORDER BY created_at',
      ),
    );
    _printRows(
      'machines',
      database.select(
        'SELECT id, factory_id, name, machine_code, sequence_order, active '
        'FROM machines ORDER BY factory_id, sequence_order',
      ),
    );
    _printRows(
      'parts',
      database.select(
        'SELECT id, factory_id, code, name, active '
        'FROM parts ORDER BY factory_id, code',
      ),
    );
    _printRows(
      'stock balances',
      database.select(
        'SELECT factory_id, part_id, stage, '
        'ROUND(SUM(CASE WHEN direction = "IN" THEN qty ELSE -qty END), 3) '
        'AS balance '
        'FROM stock_ledger GROUP BY factory_id, part_id, stage '
        'ORDER BY factory_id, part_id, stage',
      ),
    );
    _printRows(
      'recent productions',
      database.select(
        'SELECT id, factory_id, batch_number, part_id, machine_id, '
        'production_qty, bp_reject_qty, good_qty, sync_status, created_at '
        'FROM productions ORDER BY created_at DESC LIMIT 20',
      ),
    );
    _printRows(
      'sync queue',
      database.select(
        'SELECT table_name, record_id, operation, status, attempts, '
        'last_attempt_at, next_retry_at, created_at '
        'FROM sync_queue ORDER BY id DESC LIMIT 30',
      ),
    );
    _printRows(
      'production events missing ledger movements',
      database.select(
        'SELECT p.id, p.factory_id, p.batch_number, p.part_id, p.machine_id, '
        'p.production_qty, p.good_qty, p.sync_status '
        'FROM productions p '
        'WHERE NOT EXISTS ('
        '  SELECT 1 FROM stock_ledger sl '
        '  WHERE sl.factory_id = p.factory_id '
        '    AND sl.ref_table = "productions" AND sl.ref_id = p.id'
        ') ORDER BY p.created_at DESC',
      ),
    );
    _printRows(
      'orphan production ledger movements',
      database.select(
        'SELECT sl.id, sl.factory_id, sl.part_id, sl.stage, sl.direction, '
        'sl.qty, sl.ref_id, sl.sync_status '
        'FROM stock_ledger sl '
        'WHERE sl.ref_table = "productions" AND NOT EXISTS ('
        '  SELECT 1 FROM productions p '
        '  WHERE p.factory_id = sl.factory_id AND p.id = sl.ref_id'
        ') ORDER BY sl.created_at DESC',
      ),
    );
    _printRows(
      'RTV over-receipts',
      database.select(
        'SELECT r.id, r.factory_id, r.batch_number, r.cycle_number, '
        'r.rtv_qty, COALESCE(SUM(rr.quantity_received), 0) AS received_qty '
        'FROM rtvs r LEFT JOIN rtv_reinspections rr '
        'ON rr.factory_id = r.factory_id AND rr.rtv_id = r.id '
        'GROUP BY r.id HAVING COALESCE(SUM(rr.quantity_received), 0) > r.rtv_qty',
      ),
    );
    if (_hasColumn(database, 'dispatch_items', 'batch_number')) {
      _printRows(
        'legacy dispatch items missing batch traceability',
        database.select(
          'SELECT di.id, di.factory_id, di.session_id, di.part_id, '
          'di.dispatch_qty, ds.date, ds.challan_number '
          'FROM dispatch_items di '
          'LEFT JOIN dispatch_sessions ds ON ds.id = di.session_id '
          'AND ds.factory_id = di.factory_id '
          'WHERE di.batch_number IS NULL OR TRIM(di.batch_number) = ""',
        ),
      );
    } else {
      stdout.writeln(
        '\n[legacy dispatch items missing batch traceability] '
        'batch_number column not installed yet',
      );
    }
  } finally {
    database.close();
  }
}

bool _hasColumn(Database database, String table, String column) {
  return database
      .select('PRAGMA table_info($table)')
      .any((row) => row['name'] == column);
}

void _printRows(String label, ResultSet rows) {
  stdout.writeln('\n[$label] ${rows.length}');
  for (final row in rows) {
    stdout.writeln(Map<String, Object?>.from(row));
  }
}
