import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../constants/app_constants.dart';
import '../constants/stock_stages.dart';

final databaseServiceProvider = Provider<DatabaseService>((ref) {
  return DatabaseService.instance;
});

class DatabaseService {
  DatabaseService._();
  static final DatabaseService instance = DatabaseService._();

  Database? _db;
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'factoryflow.sqlite');
    _db = sqlite3.open(path);
    _createTables();
    _initialized = true;
  }

  Database get db {
    if (_db == null) throw StateError('DatabaseService not initialized');
    return _db!;
  }

  void _createTables() {
    final statements = [
      '''CREATE TABLE IF NOT EXISTS parts (
        id TEXT PRIMARY KEY, factory_id TEXT, code TEXT, name TEXT,
        uom TEXT DEFAULT 'PCS', active INTEGER DEFAULT 1)''',
      '''CREATE TABLE IF NOT EXISTS machines (
        id TEXT PRIMARY KEY, factory_id TEXT, name TEXT,
        sequence_order INTEGER, active INTEGER DEFAULT 1)''',
      '''CREATE TABLE IF NOT EXISTS suppliers (
        id TEXT PRIMARY KEY, factory_id TEXT, name TEXT, active INTEGER DEFAULT 1)''',
      '''CREATE TABLE IF NOT EXISTS vendors (
        id TEXT PRIMARY KEY, factory_id TEXT, name TEXT, active INTEGER DEFAULT 1)''',
      '''CREATE TABLE IF NOT EXISTS customers (
        id TEXT PRIMARY KEY, factory_id TEXT, name TEXT,
        is_default INTEGER DEFAULT 0, active INTEGER DEFAULT 1)''',
      '''CREATE TABLE IF NOT EXISTS operators (
        id TEXT PRIMARY KEY, factory_id TEXT, name TEXT, active INTEGER DEFAULT 1)''',
      '''CREATE TABLE IF NOT EXISTS vehicles (
        id TEXT PRIMARY KEY, factory_id TEXT, number_plate TEXT, active INTEGER DEFAULT 1)''',
      '''CREATE TABLE IF NOT EXISTS drivers (
        id TEXT PRIMARY KEY, factory_id TEXT, name TEXT, active INTEGER DEFAULT 1)''',
      '''CREATE TABLE IF NOT EXISTS material_receives (
        id TEXT PRIMARY KEY, factory_id TEXT, date TEXT, time TEXT,
        supplier_id TEXT, po_id TEXT, part_id TEXT, qty REAL,
        remarks TEXT, created_by TEXT, created_at TEXT,
        sync_status TEXT DEFAULT 'pending')''',
      '''CREATE TABLE IF NOT EXISTS productions (
        id TEXT PRIMARY KEY, factory_id TEXT, batch_number TEXT, date TEXT, time TEXT,
        shift_id TEXT, part_id TEXT, machine_id TEXT, operator_id TEXT,
        machine_status_id TEXT, production_qty REAL, bp_reject_qty REAL DEFAULT 0,
        good_qty REAL, remarks TEXT, created_by TEXT, created_at TEXT,
        sync_status TEXT DEFAULT 'pending')''',
      '''CREATE TABLE IF NOT EXISTS machine_downtimes (
        id TEXT PRIMARY KEY, factory_id TEXT, machine_id TEXT, date TEXT,
        start_time TEXT, end_time TEXT, duration_minutes INTEGER,
        reason TEXT, operator_id TEXT, photo_url TEXT, remarks TEXT,
        created_by TEXT, sync_status TEXT DEFAULT 'pending')''',
      '''CREATE TABLE IF NOT EXISTS bp_inspections (
        id TEXT PRIMARY KEY, factory_id TEXT, batch_number TEXT, date TEXT,
        part_id TEXT, machine_id TEXT, bp_reject_qty REAL, reject_reason_id TEXT,
        inspector_id TEXT, photo_url TEXT, remarks TEXT,
        sync_status TEXT DEFAULT 'pending')''',
      '''CREATE TABLE IF NOT EXISTS dispatch_to_facos (
        id TEXT PRIMARY KEY, factory_id TEXT, batch_number TEXT, date TEXT, time TEXT,
        part_id TEXT, qty REAL, vendor_id TEXT, vehicle_id TEXT, driver_id TEXT,
        challan_number TEXT, remarks TEXT, created_by TEXT,
        sync_status TEXT DEFAULT 'pending')''',
      '''CREATE TABLE IF NOT EXISTS receive_from_facos (
        id TEXT PRIMARY KEY, factory_id TEXT, batch_number TEXT, date TEXT,
        part_id TEXT, qty_received REAL, dispatch_ref_id TEXT, supplier_challan TEXT,
        shortage_flag INTEGER DEFAULT 0, remarks TEXT, created_by TEXT,
        sync_status TEXT DEFAULT 'pending')''',
      '''CREATE TABLE IF NOT EXISTS ap_inspections (
        id TEXT PRIMARY KEY, factory_id TEXT, batch_number TEXT, date TEXT,
        part_id TEXT, qty_checked REAL, approved_qty REAL, rejected_qty REAL,
        reject_reason_id TEXT, inspector_id TEXT, photo_url TEXT, remarks TEXT,
        sync_status TEXT DEFAULT 'pending')''',
      '''CREATE TABLE IF NOT EXISTS rtvs (
        id TEXT PRIMARY KEY, factory_id TEXT, batch_number TEXT, cycle_number INTEGER,
        date TEXT, part_id TEXT, rtv_qty REAL, reason_id TEXT, vendor_id TEXT,
        status TEXT DEFAULT 'pending', expected_return_date TEXT,
        actual_return_date TEXT, photo_url TEXT, remarks TEXT,
        sync_status TEXT DEFAULT 'pending')''',
      '''CREATE TABLE IF NOT EXISTS rtv_reinspections (
        id TEXT PRIMARY KEY, factory_id TEXT, rtv_id TEXT, date TEXT,
        quantity_received REAL, ok_qty REAL, reject_again_qty REAL,
        next_action TEXT, remarks TEXT, sync_status TEXT DEFAULT 'pending')''',
      '''CREATE TABLE IF NOT EXISTS final_dispatches (
        id TEXT PRIMARY KEY, factory_id TEXT, batch_number TEXT, date TEXT,
        part_id TEXT, customer_id TEXT, dispatch_qty REAL, vehicle_id TEXT,
        driver_id TEXT, challan_number TEXT, photo_url TEXT, remarks TEXT,
        created_by TEXT, sync_status TEXT DEFAULT 'pending')''',
      '''CREATE TABLE IF NOT EXISTS stock_ledger (
        id TEXT PRIMARY KEY, factory_id TEXT, date TEXT, time TEXT,
        part_id TEXT, stage TEXT, direction TEXT, qty REAL,
        ref_table TEXT, ref_id TEXT, running_balance REAL,
        created_at TEXT, sync_status TEXT DEFAULT 'pending')''',
      '''CREATE TABLE IF NOT EXISTS sync_queue (
        id INTEGER PRIMARY KEY AUTOINCREMENT, table_name TEXT, record_id TEXT,
        operation TEXT, payload TEXT, attempts INTEGER DEFAULT 0,
        status TEXT DEFAULT 'pending', created_at TEXT, last_attempt_at TEXT)''',
      '''CREATE TABLE IF NOT EXISTS correction_requests (
        id TEXT PRIMARY KEY, factory_id TEXT, table_name TEXT, record_id TEXT,
        requested_by TEXT, requested_at TEXT, reason TEXT,
        old_value_json TEXT, proposed_value_json TEXT, status TEXT,
        reviewed_by TEXT, reviewed_at TEXT)''',
      '''CREATE INDEX IF NOT EXISTS idx_ledger_part_stage ON stock_ledger(part_id, stage)''',
      '''CREATE INDEX IF NOT EXISTS idx_ledger_date ON stock_ledger(date)''',
      '''CREATE INDEX IF NOT EXISTS idx_batch ON productions(batch_number)''',
    ];
    for (final sql in statements) {
      db.execute(sql);
    }
  }

  Future<double> getCurrentBalance(String partId, String stage) async {
    final result = db.select(
      'SELECT running_balance FROM stock_ledger WHERE part_id = ? AND stage = ? ORDER BY created_at DESC LIMIT 1',
      [partId, stage],
    );
    if (result.isEmpty) return 0;
    return (result.first['running_balance'] as num).toDouble();
  }

  Future<double> getTotalBalanceByStage(String stage) async {
    final parts = await getActiveParts();
    double total = 0;
    for (final part in parts) {
      total += await getCurrentBalance(part['id'] as String, stage);
    }
    return total;
  }

  Future<List<Map<String, dynamic>>> getActiveParts() async {
    final result = db.select('SELECT * FROM parts WHERE active = 1 ORDER BY name');
    return result.map(_rowToMap).toList().cast<Map<String, dynamic>>();
  }

  Future<List<Map<String, dynamic>>> getActiveMachines() async {
    final result = db.select('SELECT * FROM machines WHERE active = 1 ORDER BY sequence_order');
    return result.map(_rowToMap).toList().cast<Map<String, dynamic>>();
  }

  Future<List<Map<String, dynamic>>> getActiveSuppliers() async {
    final result = db.select('SELECT * FROM suppliers WHERE active = 1 ORDER BY name');
    return result.map(_rowToMap).toList().cast<Map<String, dynamic>>();
  }

  Future<List<Map<String, dynamic>>> getActiveVendors() async {
    final result = db.select('SELECT * FROM vendors WHERE active = 1 ORDER BY name');
    return result.map(_rowToMap).toList().cast<Map<String, dynamic>>();
  }

  Future<List<Map<String, dynamic>>> getActiveCustomers() async {
    final result = db.select('SELECT * FROM customers WHERE active = 1 ORDER BY name');
    return result.map(_rowToMap).toList().cast<Map<String, dynamic>>();
  }

  Future<List<Map<String, dynamic>>> getActiveOperators() async {
    final result = db.select('SELECT * FROM operators WHERE active = 1 ORDER BY name');
    return result.map(_rowToMap).toList().cast<Map<String, dynamic>>();
  }

  Future<List<Map<String, dynamic>>> getVehicles() async {
    final result = db.select('SELECT * FROM vehicles WHERE active = 1 ORDER BY number_plate');
    return result.map(_rowToMap).toList().cast<Map<String, dynamic>>();
  }

  Future<List<Map<String, dynamic>>> getDrivers() async {
    final result = db.select('SELECT * FROM drivers WHERE active = 1 ORDER BY name');
    return result.map(_rowToMap).toList().cast<Map<String, dynamic>>();
  }

  Future<void> insertRecord(String table, Map<String, dynamic> data) async {
    final columns = data.keys.join(', ');
    final placeholders = List.filled(data.length, '?').join(', ');
    db.execute(
      'INSERT OR REPLACE INTO $table ($columns) VALUES ($placeholders)',
      data.values.toList(),
    );
  }

  Future<void> enqueueSync({
    required String tableName,
    required String recordId,
    required String operation,
    required Map<String, dynamic> payload,
  }) async {
    db.execute(
      '''INSERT INTO sync_queue (table_name, record_id, operation, payload, created_at)
         VALUES (?, ?, ?, ?, ?)''',
      [tableName, recordId, operation, jsonEncode(payload), DateTime.now().toIso8601String()],
    );
  }

  Future<List<Map<String, dynamic>>> getPendingSyncItems() async {
    final result = db.select(
      "SELECT * FROM sync_queue WHERE status = 'pending' ORDER BY created_at",
    );
    return result.map(_rowToMap).toList().cast<Map<String, dynamic>>();
  }

  Future<int> countPendingSync() async {
    final result = db.select("SELECT COUNT(*) as cnt FROM sync_queue WHERE status = 'pending'");
    return result.first['cnt'] as int;
  }

  Future<void> updateSyncStatus(int id, String status, {int? attempts}) async {
    if (attempts != null) {
      db.execute(
        'UPDATE sync_queue SET status = ?, attempts = ?, last_attempt_at = ? WHERE id = ?',
        [status, attempts, DateTime.now().toIso8601String(), id],
      );
    } else {
      db.execute('UPDATE sync_queue SET status = ? WHERE id = ?', [status, id]);
    }
  }

  Future<void> markRecordSynced(String table, String id) async {
    db.execute("UPDATE $table SET sync_status = 'synced' WHERE id = ?", [id]);
  }

  Future<void> markRecordConflict(String table, String id) async {
    db.execute("UPDATE $table SET sync_status = 'conflict' WHERE id = ?", [id]);
  }

  Future<StockLedgerResult> writeStockLedgerEntry({
    required String id,
    required String factoryId,
    required String partId,
    required StockStage stage,
    required LedgerDirection direction,
    required double qty,
    required String refTable,
    required String refId,
  }) async {
    final currentBalance = await getCurrentBalance(partId, stage.value);
    final newBalance = direction == LedgerDirection.in_
        ? currentBalance + qty
        : currentBalance - qty;

    if (newBalance < 0) {
      return StockLedgerResult(
        success: false,
        error: 'Insufficient stock. Available: $currentBalance ${stage.label}',
        availableQty: currentBalance,
      );
    }

    final now = DateTime.now();
    await insertRecord('stock_ledger', {
      'id': id,
      'factory_id': factoryId,
      'date': now.toIso8601String(),
      'time': '${now.hour}:${now.minute.toString().padLeft(2, '0')}',
      'part_id': partId,
      'stage': stage.value,
      'direction': direction.value,
      'qty': qty,
      'ref_table': refTable,
      'ref_id': refId,
      'running_balance': newBalance,
      'created_at': now.toIso8601String(),
      'sync_status': 'pending',
    });

    return StockLedgerResult(success: true, newBalance: newBalance);
  }

  Future<List<Map<String, dynamic>>> searchRecords({
    String? batchNumber,
    String? partId,
    String? dateFrom,
    String? dateTo,
    int limit = 50,
  }) async {
    final results = <Map<String, dynamic>>[];
    final tables = [
      'productions', 'bp_inspections', 'dispatch_to_facos', 'receive_from_facos',
      'ap_inspections', 'rtvs', 'final_dispatches', 'material_receives',
    ];

    for (final table in tables) {
      final conditions = <String>[];
      final params = <Object?>[];

      if (batchNumber != null && _hasBatchColumn(table)) {
        conditions.add('batch_number LIKE ?');
        params.add('%$batchNumber%');
      }
      if (partId != null) { conditions.add('part_id = ?'); params.add(partId); }
      if (dateFrom != null) { conditions.add('date >= ?'); params.add(dateFrom); }
      if (dateTo != null) { conditions.add('date <= ?'); params.add(dateTo); }

      var sql = 'SELECT * FROM $table';
      if (conditions.isNotEmpty) sql += ' WHERE ${conditions.join(' AND ')}';
      sql += ' ORDER BY date DESC LIMIT $limit';

      final rows = db.select(sql, params);
      for (final row in rows) {
        final map = _rowToMap(row);
        map['_table'] = table;
        results.add(map);
      }
    }
    return results;
  }

  bool _hasBatchColumn(String table) =>
      !['material_receives', 'machine_downtimes'].contains(table);

  Map<String, dynamic> _rowToMap(Row row) => Map<String, dynamic>.from(row);

  Future<void> seedDemoData() async {
    const factoryId = AppConstants.defaultFactoryId;
    final parts = [
      {'id': 'part-001', 'factory_id': factoryId, 'code': 'V21', 'name': 'Part V21', 'uom': 'PCS', 'active': 1},
      {'id': 'part-002', 'factory_id': factoryId, 'code': 'V22', 'name': 'Part V22', 'uom': 'PCS', 'active': 1},
    ];
    final machines = [
      {'id': 'mach-001', 'factory_id': factoryId, 'name': 'Bending', 'sequence_order': 1, 'active': 1},
      {'id': 'mach-002', 'factory_id': factoryId, 'name': 'Notching', 'sequence_order': 2, 'active': 1},
      {'id': 'mach-003', 'factory_id': factoryId, 'name': 'End Forming', 'sequence_order': 3, 'active': 1},
    ];
    for (final p in parts) {
      await insertRecord('parts', p);
    }
    for (final m in machines) {
      await insertRecord('machines', m);
    }
    await insertRecord('suppliers', {'id': 'sup-001', 'factory_id': factoryId, 'name': 'Steel Supplier', 'active': 1});
    await insertRecord('vendors', {'id': 'ven-001', 'factory_id': factoryId, 'name': 'Faco', 'active': 1});
    await insertRecord('customers', {'id': 'cust-001', 'factory_id': factoryId, 'name': 'Thal', 'is_default': 1, 'active': 1});
    await insertRecord('operators', {'id': 'op-001', 'factory_id': factoryId, 'name': 'Operator 1', 'active': 1});
    await insertRecord('operators', {'id': 'op-002', 'factory_id': factoryId, 'name': 'Operator 2', 'active': 1});
  }

  void dispose() {
    _db?.dispose();
    _db = null;
    _initialized = false;
  }
}

class StockLedgerResult {
  const StockLedgerResult({
    required this.success,
    this.newBalance,
    this.error,
    this.availableQty,
  });
  final bool success;
  final double? newBalance;
  final String? error;
  final double? availableQty;
}
