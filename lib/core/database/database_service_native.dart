import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import '../constants/stock_stages.dart';

final databaseServiceProvider = Provider<DatabaseService>((ref) {
  return DatabaseService.instance;
});

class DatabaseService {
  DatabaseService._();

  /// Creates an isolated database service for repository and migration tests.
  ///
  /// Production code must continue using [instance].
  DatabaseService.forTesting(Database database) {
    _db = database;
    _db!.execute('PRAGMA foreign_keys=ON');
    _createTables();
    _initialized = true;
  }

  static final DatabaseService instance = DatabaseService._();

  Database? _db;
  bool _initialized = false;
  bool _transactionInProgress = false;

  Future<void> initialize() async {
    if (_initialized) return;
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'factoryflow.sqlite');
    _db = sqlite3.open(path);
    _db!.execute('PRAGMA journal_mode=WAL');
    _db!.execute('PRAGMA foreign_keys=ON');
    _createTables();
    _initialized = true;
  }

  Database get db {
    if (_db == null) throw StateError('DatabaseService not initialized');
    return _db!;
  }

  /// Runs local-only writes as one atomic SQLite transaction.
  ///
  /// [action] must not perform network or platform I/O. All production event,
  /// ledger, and sync-queue writes use the same database connection and either
  /// commit together or roll back together.
  Future<T> runInTransaction<T>(Future<T> Function() action) async {
    if (_transactionInProgress) {
      throw StateError('Nested database transactions are not supported.');
    }

    _transactionInProgress = true;
    var transactionStarted = false;
    try {
      db.execute('BEGIN IMMEDIATE');
      transactionStarted = true;
      final result = await action();
      db.execute('COMMIT');
      return result;
    } catch (_) {
      if (transactionStarted) db.execute('ROLLBACK');
      rethrow;
    } finally {
      _transactionInProgress = false;
    }
  }

  void _createTables() {
    final statements = [
      '''CREATE TABLE IF NOT EXISTS app_settings (
        key TEXT PRIMARY KEY,
        value TEXT)''',
      '''CREATE TABLE IF NOT EXISTS workspaces (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        owner_user_id TEXT,
        created_at TEXT,
        active INTEGER DEFAULT 1,
        sync_status TEXT DEFAULT 'pending')''',
      '''CREATE TABLE IF NOT EXISTS workspace_members (
        id TEXT PRIMARY KEY,
        workspace_id TEXT NOT NULL,
        user_id TEXT NOT NULL,
        role TEXT NOT NULL DEFAULT 'owner',
        status TEXT NOT NULL DEFAULT 'active',
        joined_at TEXT,
        sync_status TEXT DEFAULT 'pending')''',
      'CREATE INDEX IF NOT EXISTS idx_workspace_members_user ON workspace_members(user_id)',
      'CREATE INDEX IF NOT EXISTS idx_workspace_members_workspace ON workspace_members(workspace_id)',
      '''CREATE TABLE IF NOT EXISTS parts (
        id TEXT PRIMARY KEY, factory_id TEXT, code TEXT, name TEXT,
        uom TEXT DEFAULT 'PCS', active INTEGER DEFAULT 1)''',
      '''CREATE TABLE IF NOT EXISTS machines (
        id TEXT PRIMARY KEY, factory_id TEXT, name TEXT, machine_code TEXT,
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
      '''CREATE TABLE IF NOT EXISTS target_master (
        id TEXT PRIMARY KEY, factory_id TEXT, part_id TEXT,
        day_of_week INTEGER, target_qty INTEGER, effective_from TEXT)''',
      '''CREATE TABLE IF NOT EXISTS purchase_orders (
        id TEXT PRIMARY KEY, factory_id TEXT, date TEXT, time TEXT,
        part_id TEXT, supplier_id TEXT, ordered_qty REAL,
        po_number TEXT, status TEXT DEFAULT 'pending',
        remarks TEXT, created_by TEXT, created_at TEXT,
        sync_status TEXT DEFAULT 'pending')''',
      '''CREATE TABLE IF NOT EXISTS material_receives (
        id TEXT PRIMARY KEY, factory_id TEXT, date TEXT, time TEXT,
        supplier_id TEXT, po_id TEXT, po_ref_id TEXT,
        part_id TEXT, qty REAL, ordered_qty REAL,
        shortfall REAL DEFAULT 0,
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
        rtv_qty REAL DEFAULT 0,
        reject_reason_id TEXT, inspector_id TEXT, photo_url TEXT, remarks TEXT,
        sync_status TEXT DEFAULT 'pending')''',
      '''CREATE TABLE IF NOT EXISTS ap_rejected_actions (
        id TEXT PRIMARY KEY, factory_id TEXT, date TEXT,
        part_id TEXT, qty REAL, action TEXT,
        vendor_id TEXT, remarks TEXT,
        created_by TEXT, sync_status TEXT DEFAULT 'pending')''',
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
      '''CREATE TABLE IF NOT EXISTS dispatch_sessions (
        id TEXT PRIMARY KEY, factory_id TEXT, date TEXT, time TEXT,
        customer_id TEXT, vehicle_id TEXT, driver_id TEXT,
        challan_number TEXT, remarks TEXT, created_by TEXT,
        sync_status TEXT DEFAULT 'pending')''',
      '''CREATE TABLE IF NOT EXISTS dispatch_items (
        id TEXT PRIMARY KEY, session_id TEXT NOT NULL, factory_id TEXT,
        part_id TEXT, dispatch_qty REAL,
        sync_status TEXT DEFAULT 'pending')''',
      'CREATE INDEX IF NOT EXISTS idx_dispatch_items_session ON dispatch_items(session_id)',
      'CREATE INDEX IF NOT EXISTS idx_dispatch_sessions_date ON dispatch_sessions(date)',
      '''CREATE TABLE IF NOT EXISTS stock_ledger (
        id TEXT PRIMARY KEY, factory_id TEXT, date TEXT, time TEXT,
        part_id TEXT, stage TEXT, direction TEXT, qty REAL,
        ref_table TEXT, ref_id TEXT, running_balance REAL,
        created_at TEXT, sync_status TEXT DEFAULT 'pending')''',
      '''CREATE TABLE IF NOT EXISTS sync_queue (
        id INTEGER PRIMARY KEY AUTOINCREMENT, table_name TEXT, record_id TEXT,
        operation TEXT, payload TEXT, attempts INTEGER DEFAULT 0,
        status TEXT DEFAULT 'pending', created_at TEXT, last_attempt_at TEXT,
        next_retry_at TEXT)''',
      '''CREATE TABLE IF NOT EXISTS sync_history_logs (
        id TEXT PRIMARY KEY, table_name TEXT, record_id TEXT,
        operation TEXT, status TEXT, error_message TEXT, created_at TEXT)''',
      '''CREATE TABLE IF NOT EXISTS correction_requests (
        id TEXT PRIMARY KEY, factory_id TEXT, table_name TEXT, record_id TEXT,
        requested_by TEXT, requested_at TEXT, reason TEXT,
        old_value_json TEXT, proposed_value_json TEXT, status TEXT DEFAULT 'pending',
        reviewed_by TEXT, reviewed_at TEXT, sync_status TEXT DEFAULT 'pending')''',
      '''CREATE TABLE IF NOT EXISTS audit_log (
        id TEXT PRIMARY KEY, factory_id TEXT, table_name TEXT, record_id TEXT,
        action TEXT, old_value_json TEXT, new_value_json TEXT,
        changed_by TEXT, changed_at TEXT, device TEXT,
        sync_status TEXT DEFAULT 'pending')''',
      '''CREATE TABLE IF NOT EXISTS backup_records (
        id TEXT PRIMARY KEY,
        factory_id TEXT,
        user_id TEXT,
        source_table TEXT NOT NULL,
        source_record_id TEXT NOT NULL,
        data_json TEXT NOT NULL,
        backup_reason TEXT,
        backed_up_at TEXT NOT NULL,
        sync_status TEXT DEFAULT 'pending')''',
      '''CREATE TABLE IF NOT EXISTS stock_adjustments (
        id TEXT PRIMARY KEY,
        factory_id TEXT,
        user_id TEXT,
        part_id TEXT,
        stage TEXT,
        previous_qty REAL,
        adjusted_qty REAL,
        new_qty REAL,
        remarks TEXT,
        created_at TEXT,
        sync_status TEXT DEFAULT 'pending')''',
      'CREATE INDEX IF NOT EXISTS idx_backup_user ON backup_records(user_id)',
      'CREATE INDEX IF NOT EXISTS idx_backup_table ON backup_records(source_table)',
      'CREATE INDEX IF NOT EXISTS idx_backup_at ON backup_records(backed_up_at)',
      'CREATE INDEX IF NOT EXISTS idx_stock_adj_part ON stock_adjustments(part_id)',
      'CREATE INDEX IF NOT EXISTS idx_stock_adj_created ON stock_adjustments(created_at)',
      // Indexes
      'CREATE INDEX IF NOT EXISTS idx_ledger_part_stage ON stock_ledger(part_id, stage)',
      'CREATE INDEX IF NOT EXISTS idx_ledger_date ON stock_ledger(date)',
      'CREATE INDEX IF NOT EXISTS idx_ledger_created ON stock_ledger(created_at)',
      'CREATE INDEX IF NOT EXISTS idx_batch ON productions(batch_number)',
      'CREATE INDEX IF NOT EXISTS idx_productions_date ON productions(date)',
      'CREATE INDEX IF NOT EXISTS idx_dispatches_date ON final_dispatches(date)',
      'CREATE INDEX IF NOT EXISTS idx_sync_queue_status ON sync_queue(status)',
      'CREATE INDEX IF NOT EXISTS idx_material_receives_part ON material_receives(part_id)',
      'CREATE INDEX IF NOT EXISTS idx_productions_part ON productions(part_id)',
      'CREATE INDEX IF NOT EXISTS idx_productions_machine ON productions(machine_id)',
      'CREATE INDEX IF NOT EXISTS idx_productions_operator ON productions(operator_id)',
      'CREATE INDEX IF NOT EXISTS idx_bp_inspections_part ON bp_inspections(part_id)',
      'CREATE INDEX IF NOT EXISTS idx_bp_inspections_machine ON bp_inspections(machine_id)',
      'CREATE INDEX IF NOT EXISTS idx_dispatch_to_facos_part ON dispatch_to_facos(part_id)',
      'CREATE INDEX IF NOT EXISTS idx_dispatch_to_facos_vendor ON dispatch_to_facos(vendor_id)',
      'CREATE INDEX IF NOT EXISTS idx_receive_from_facos_part ON receive_from_facos(part_id)',
      'CREATE INDEX IF NOT EXISTS idx_receive_from_facos_dispatch ON receive_from_facos(dispatch_ref_id)',
      'CREATE INDEX IF NOT EXISTS idx_ap_inspections_part ON ap_inspections(part_id)',
      'CREATE INDEX IF NOT EXISTS idx_rtvs_part ON rtvs(part_id)',
      'CREATE INDEX IF NOT EXISTS idx_rtvs_vendor ON rtvs(vendor_id)',
      'CREATE INDEX IF NOT EXISTS idx_final_dispatches_part ON final_dispatches(part_id)',
      'CREATE INDEX IF NOT EXISTS idx_final_dispatches_customer ON final_dispatches(customer_id)',
    ];
    for (final sql in statements) {
      db.execute(sql);
    }
    _applyCompatibilityMigrations();
  }

  /// Adds non-destructive columns required by newer application versions.
  void _applyCompatibilityMigrations() {
    final columns = db.select('PRAGMA table_info(sync_queue)');
    final hasNextRetryAt = columns.any((row) => row['name'] == 'next_retry_at');
    if (!hasNextRetryAt) {
      db.execute('ALTER TABLE sync_queue ADD COLUMN next_retry_at TEXT');
    }
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_sync_queue_due '
      'ON sync_queue(status, next_retry_at, created_at)',
    );

    // material_receives: add po_ref_id, ordered_qty, shortfall if missing
    final mrCols = db.select('PRAGMA table_info(material_receives)');
    final mrNames = mrCols.map((r) => r['name'] as String).toSet();
    if (!mrNames.contains('po_ref_id')) {
      db.execute('ALTER TABLE material_receives ADD COLUMN po_ref_id TEXT');
    }
    if (!mrNames.contains('ordered_qty')) {
      db.execute('ALTER TABLE material_receives ADD COLUMN ordered_qty REAL');
    }
    if (!mrNames.contains('shortfall')) {
      db.execute(
          'ALTER TABLE material_receives ADD COLUMN shortfall REAL DEFAULT 0');
    }

    // productions: add good_qty if missing (older DBs)
    final prodCols = db.select('PRAGMA table_info(productions)');
    final prodNames = prodCols.map((r) => r['name'] as String).toSet();
    if (!prodNames.contains('good_qty')) {
      db.execute('ALTER TABLE productions ADD COLUMN good_qty REAL');
      // backfill
      db.execute(
          'UPDATE productions SET good_qty = production_qty - COALESCE(bp_reject_qty, 0) WHERE good_qty IS NULL');
    }

    final apCols = db.select('PRAGMA table_info(ap_inspections)');
    final apNames = apCols.map((r) => r['name'] as String).toSet();
    if (!apNames.contains('rtv_qty')) {
      db.execute(
          'ALTER TABLE ap_inspections ADD COLUMN rtv_qty REAL DEFAULT 0');
    }
  }

  Future<void> setActiveWorkspaceId(String workspaceId) async {
    db.execute(
      'INSERT OR REPLACE INTO app_settings (key, value) VALUES (?, ?)',
      ['active_workspace_id', workspaceId],
    );
  }

  String get activeWorkspaceId {
    final rows = db.select(
      'SELECT value FROM app_settings WHERE key = ? LIMIT 1',
      ['active_workspace_id'],
    );
    if (rows.isEmpty) return '';
    return rows.first['value']?.toString() ?? '';
  }

  Future<void> upsertWorkspace({
    required String id,
    required String name,
    required String ownerUserId,
    String syncStatus = 'pending',
  }) async {
    await insertRecord('workspaces', {
      'id': id,
      'name': name,
      'owner_user_id': ownerUserId,
      'created_at': DateTime.now().toIso8601String(),
      'active': 1,
      'sync_status': syncStatus,
    });
  }

  Future<void> upsertWorkspaceMember({
    required String id,
    required String workspaceId,
    required String userId,
    required String role,
    String status = 'active',
    String syncStatus = 'pending',
  }) async {
    await insertRecord('workspace_members', {
      'id': id,
      'workspace_id': workspaceId,
      'user_id': userId,
      'role': role,
      'status': status,
      'joined_at': DateTime.now().toIso8601String(),
      'sync_status': syncStatus,
    });
  }

  // ── Stock Ledger ──────────────────────────────────────────────────────────

  Future<double> getCurrentBalance(String partId, String stage) async {
    final result = db.select(
      'SELECT running_balance FROM stock_ledger '
      'WHERE part_id = ? AND stage = ? ORDER BY created_at DESC LIMIT 1',
      [partId, stage],
    );
    if (result.isEmpty) return 0;
    return (result.first['running_balance'] as num).toDouble();
  }

  /// FIXED: Single aggregated query instead of N+1 per-part queries.
  Future<double> getTotalBalanceByStage(String stage) async {
    final result = db.select(
      '''SELECT COALESCE(SUM(sl.running_balance), 0) AS total
         FROM stock_ledger sl
         INNER JOIN (
           SELECT part_id, MAX(created_at) AS max_at
           FROM stock_ledger
           WHERE stage = ?
           GROUP BY part_id
         ) latest ON sl.part_id = latest.part_id
                  AND sl.created_at = latest.max_at
                  AND sl.stage = ?''',
      [stage, stage],
    );
    return (result.first['total'] as num?)?.toDouble() ?? 0;
  }

  /// Returns per-part balances for a stage in a single query.
  Future<List<Map<String, dynamic>>> getBalancesByStage(String stage) async {
    final result = db.select(
      '''SELECT p.id, p.code, p.name, p.uom,
                COALESCE(sl.running_balance, 0) AS balance
         FROM parts p
         LEFT JOIN stock_ledger sl ON sl.part_id = p.id AND sl.stage = ?
           AND sl.created_at = (
             SELECT MAX(created_at) FROM stock_ledger
             WHERE part_id = p.id AND stage = ?
           )
         WHERE p.active = 1
         ORDER BY p.name''',
      [stage, stage],
    );
    return result.map(_rowToMap).toList().cast<Map<String, dynamic>>();
  }

  // ── Dashboard Queries (single-pass) ──────────────────────────────────────

  /// Returns all 6 stage totals in a single SQL query.
  Future<Map<String, double>> getAllStageTotals() async {
    final result = db.select(
      '''SELECT sl.stage, COALESCE(SUM(sl.running_balance), 0) AS total
         FROM stock_ledger sl
         INNER JOIN (
           SELECT part_id, stage, MAX(created_at) AS max_at
           FROM stock_ledger
           GROUP BY part_id, stage
         ) latest ON sl.part_id = latest.part_id
                  AND sl.stage = latest.stage
                  AND sl.created_at = latest.max_at
         GROUP BY sl.stage''',
    );
    final map = <String, double>{};
    for (final row in result) {
      map[row['stage'] as String] = (row['total'] as num).toDouble();
    }
    return map;
  }

  /// Today's production summary in a single query.
  Future<Map<String, double>> getTodayProductionSummary(String todayStr) async {
    final prod = db.select(
      'SELECT COALESCE(SUM(production_qty),0) AS prod, '
      'COALESCE(SUM(bp_reject_qty),0) AS bp_rej '
      'FROM productions WHERE date = ?',
      [todayStr],
    );
    final ap = db.select(
      'SELECT COALESCE(SUM(rejected_qty),0) AS ap_rej FROM ap_inspections WHERE date = ?',
      [todayStr],
    );
    final disp = db.select(
      'SELECT COALESCE(SUM(dispatch_qty),0) AS dispatched FROM final_dispatches WHERE date = ?',
      [todayStr],
    );
    return {
      'production': (prod.first['prod'] as num).toDouble(),
      'bp_reject': (prod.first['bp_rej'] as num).toDouble(),
      'ap_reject': (ap.first['ap_rej'] as num).toDouble(),
      'dispatched': (disp.first['dispatched'] as num).toDouble(),
    };
  }

  /// Today's target — sum of all part targets for the given day-of-week.
  /// Falls back to 500 only if NO targets are configured at all.
  Future<double> getTodayTarget(int dayOfWeek) async {
    final result = db.select(
      'SELECT COALESCE(SUM(target_qty), 0) AS total FROM target_master WHERE day_of_week = ?',
      [dayOfWeek],
    );
    final total = (result.first['total'] as num?)?.toDouble() ?? 0;
    if (total > 0) return total;
    // No targets configured — check if any targets exist at all
    final anyRow = db.select('SELECT COUNT(*) as cnt FROM target_master');
    final hasAny = (anyRow.first['cnt'] as int) > 0;
    return hasAny ? 0 : 500; // 500 only as first-run default
  }

  // ── Target Master CRUD ────────────────────────────────────────────────────

  List<Map<String, dynamic>> getTargets() {
    final result = db.select(
      'SELECT tm.*, p.name as part_name, p.code as part_code '
      'FROM target_master tm '
      'LEFT JOIN parts p ON p.id = tm.part_id '
      'ORDER BY p.name, tm.day_of_week',
    );
    return result.map(_rowToMap).toList().cast<Map<String, dynamic>>();
  }

  void upsertTarget({
    required String id,
    required String partId,
    required int dayOfWeek,
    required int targetQty,
  }) {
    db.execute(
      'INSERT OR REPLACE INTO target_master (id, factory_id, part_id, day_of_week, target_qty, effective_from) '
      'VALUES (?, ?, ?, ?, ?, ?)',
      [
        id,
        activeWorkspaceId,
        partId,
        dayOfWeek,
        targetQty,
        DateTime.now().toIso8601String().substring(0, 10)
      ],
    );
  }

  void deleteTarget(String id) {
    db.execute('DELETE FROM target_master WHERE id = ?', [id]);
  }

  // ── Master Data ───────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> getActiveParts() async {
    final result = db.select(
      'SELECT * FROM parts WHERE active = 1 AND factory_id = ? ORDER BY name',
      [activeWorkspaceId],
    );
    return result.map(_rowToMap).toList().cast<Map<String, dynamic>>();
  }

  Future<List<Map<String, dynamic>>> getActiveMachines() async {
    final result = db.select(
      'SELECT * FROM machines WHERE active = 1 AND factory_id = ? ORDER BY sequence_order',
      [activeWorkspaceId],
    );
    return result.map(_rowToMap).toList().cast<Map<String, dynamic>>();
  }

  Future<List<Map<String, dynamic>>> getActiveSuppliers() async {
    final result = db.select(
      'SELECT * FROM suppliers WHERE active = 1 AND factory_id = ? ORDER BY name',
      [activeWorkspaceId],
    );
    return result.map(_rowToMap).toList().cast<Map<String, dynamic>>();
  }

  Future<List<Map<String, dynamic>>> getActiveVendors() async {
    final result = db.select(
      'SELECT * FROM vendors WHERE active = 1 AND factory_id = ? ORDER BY name',
      [activeWorkspaceId],
    );
    return result.map(_rowToMap).toList().cast<Map<String, dynamic>>();
  }

  Future<List<Map<String, dynamic>>> getActiveCustomers() async {
    final result = db.select(
      'SELECT * FROM customers WHERE active = 1 AND factory_id = ? ORDER BY name',
      [activeWorkspaceId],
    );
    return result.map(_rowToMap).toList().cast<Map<String, dynamic>>();
  }

  Future<List<Map<String, dynamic>>> getActiveOperators() async {
    final result = db.select(
      'SELECT * FROM operators WHERE active = 1 AND factory_id = ? ORDER BY name',
      [activeWorkspaceId],
    );
    return result.map(_rowToMap).toList().cast<Map<String, dynamic>>();
  }

  Future<List<Map<String, dynamic>>> getVehicles() async {
    final result = db.select(
      'SELECT * FROM vehicles WHERE active = 1 AND factory_id = ? ORDER BY number_plate',
      [activeWorkspaceId],
    );
    return result.map(_rowToMap).toList().cast<Map<String, dynamic>>();
  }

  Future<List<Map<String, dynamic>>> getDrivers() async {
    final result = db.select(
      'SELECT * FROM drivers WHERE active = 1 AND factory_id = ? ORDER BY name',
      [activeWorkspaceId],
    );
    return result.map(_rowToMap).toList().cast<Map<String, dynamic>>();
  }

  // ── CRUD ──────────────────────────────────────────────────────────────────

  Future<void> insertRecord(String table, Map<String, dynamic> data) async {
    final columns = data.keys.join(', ');
    final placeholders = List.filled(data.length, '?').join(', ');
    db.execute(
      'INSERT OR REPLACE INTO $table ($columns) VALUES ($placeholders)',
      data.values.toList(),
    );
  }

  // ── Sync Queue ────────────────────────────────────────────────────────────

  Future<void> enqueueSync({
    required String tableName,
    required String recordId,
    required String operation,
    required Map<String, dynamic> payload,
  }) async {
    db.execute(
      'INSERT INTO sync_queue (table_name, record_id, operation, payload, created_at) '
      'VALUES (?, ?, ?, ?, ?)',
      [
        tableName,
        recordId,
        operation,
        jsonEncode(payload),
        DateTime.now().toIso8601String(),
      ],
    );
  }

  Future<List<Map<String, dynamic>>> getPendingSyncItems() async {
    final result = db.select(
      "SELECT * FROM sync_queue WHERE status = 'pending' "
      'AND (next_retry_at IS NULL OR next_retry_at <= ?) '
      'ORDER BY created_at LIMIT 50',
      [DateTime.now().toIso8601String()],
    );
    return result.map(_rowToMap).toList().cast<Map<String, dynamic>>();
  }

  Future<int> countPendingSync() async {
    final result = db.select(
      "SELECT COUNT(*) as cnt FROM sync_queue WHERE status = 'pending'",
    );
    return result.first['cnt'] as int;
  }

  Future<void> updateSyncStatus(
    int id,
    String status, {
    int? attempts,
    String? nextRetryAt,
  }) async {
    db.execute(
      'UPDATE sync_queue SET status = ?, attempts = COALESCE(?, attempts), '
      'last_attempt_at = ?, next_retry_at = ? WHERE id = ?',
      [status, attempts, DateTime.now().toIso8601String(), nextRetryAt, id],
    );
  }

  Future<void> markRecordSynced(String table, String id) async {
    db.execute("UPDATE $table SET sync_status = 'synced' WHERE id = ?", [id]);
  }

  Future<void> markRecordConflict(String table, String id) async {
    db.execute("UPDATE $table SET sync_status = 'conflict' WHERE id = ?", [id]);
  }

  // ── Correction Requests ───────────────────────────────────────────────────

  /// FIXED: Proper method instead of raw SQL in corrections_screen.dart.
  Future<void> updateCorrectionStatus({
    required String id,
    required String status,
    String? reviewedBy,
  }) async {
    db.execute(
      'UPDATE correction_requests SET status = ?, reviewed_by = ?, reviewed_at = ? WHERE id = ?',
      [status, reviewedBy, DateTime.now().toIso8601String(), id],
    );
    await enqueueSync(
      tableName: 'correction_requests',
      recordId: id,
      operation: 'update',
      payload: {'id': id, 'status': status, 'reviewed_by': reviewedBy},
    );
  }

  // ── Audit Log ─────────────────────────────────────────────────────────────

  Future<void> writeAuditLog({
    required String id,
    required String tableName,
    required String recordId,
    required String action,
    required String changedBy,
    Map<String, dynamic>? oldValue,
    Map<String, dynamic>? newValue,
  }) async {
    db.execute(
      'INSERT INTO audit_log (id, factory_id, table_name, record_id, action, '
      'old_value_json, new_value_json, changed_by, changed_at) VALUES (?,?,?,?,?,?,?,?,?)',
      [
        id,
        activeWorkspaceId,
        tableName,
        recordId,
        action,
        oldValue != null ? jsonEncode(oldValue) : null,
        newValue != null ? jsonEncode(newValue) : null,
        changedBy,
        DateTime.now().toIso8601String(),
      ],
    );
  }

  // ── Stock Ledger Write ────────────────────────────────────────────────────

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
    return writeStockLedgerEntryForStage(
      id: id,
      factoryId: factoryId,
      partId: partId,
      stage: stage.value,
      stageLabel: stage.label,
      direction: direction,
      qty: qty,
      refTable: refTable,
      refId: refId,
    );
  }

  Future<StockLedgerResult> writeStockLedgerEntryForStage({
    required String id,
    required String factoryId,
    required String partId,
    required String stage,
    required String stageLabel,
    required LedgerDirection direction,
    required double qty,
    required String refTable,
    required String refId,
  }) async {
    final currentBalance = await getCurrentBalance(partId, stage);
    final newBalance = direction == LedgerDirection.in_
        ? currentBalance + qty
        : currentBalance - qty;

    if (newBalance < 0) {
      return StockLedgerResult(
        success: false,
        error: 'Insufficient stock. Available: $currentBalance $stageLabel',
        availableQty: currentBalance,
      );
    }

    final now = DateTime.now();
    await insertRecord('stock_ledger', {
      'id': id,
      'factory_id': factoryId,
      'date': now.toIso8601String().substring(0, 10),
      'time':
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
      'part_id': partId,
      'stage': stage,
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

  // ── Search ────────────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> searchRecords({
    String? batchNumber,
    String? partId,
    String? challanNumber,
    String? dateFrom,
    String? dateTo,
    int limit = 50,
  }) async {
    final results = <Map<String, dynamic>>[];
    final tables = [
      'productions',
      'bp_inspections',
      'dispatch_to_facos',
      'receive_from_facos',
      'ap_inspections',
      'rtvs',
      'final_dispatches',
      'material_receives',
    ];

    for (final table in tables) {
      final conditions = <String>[];
      final params = <Object?>[];

      if (batchNumber != null && _hasBatchColumn(table)) {
        conditions.add('batch_number LIKE ?');
        params.add('%$batchNumber%');
      }
      if (partId != null) {
        conditions.add('part_id = ?');
        params.add(partId);
      }
      if (challanNumber != null && _hasChallanColumn(table)) {
        conditions.add('(challan_number LIKE ? OR supplier_challan LIKE ?)');
        params.addAll(['%$challanNumber%', '%$challanNumber%']);
      }
      if (dateFrom != null) {
        conditions.add('date >= ?');
        params.add(dateFrom);
      }
      if (dateTo != null) {
        conditions.add('date <= ?');
        params.add(dateTo);
      }

      if (conditions.isEmpty) continue;

      var sql =
          'SELECT * FROM $table WHERE ${conditions.join(' AND ')} ORDER BY date DESC LIMIT $limit';
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

  bool _hasChallanColumn(String table) => [
        'dispatch_to_facos',
        'receive_from_facos',
        'final_dispatches',
      ].contains(table);

  Map<String, dynamic> _rowToMap(Row row) => Map<String, dynamic>.from(row);

  // ── Purchase Orders ───────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> getOpenPurchaseOrders(
      String partId) async {
    final result = db.select(
      "SELECT po.*, p.code as part_code, p.name as part_name, s.name as supplier_name "
      "FROM purchase_orders po "
      "LEFT JOIN parts p ON p.id = po.part_id "
      "LEFT JOIN suppliers s ON s.id = po.supplier_id "
      "WHERE po.part_id = ? AND po.status != 'received' "
      "ORDER BY po.created_at DESC LIMIT 20",
      [partId],
    );
    return result.map(_rowToMap).toList().cast<Map<String, dynamic>>();
  }

  Future<List<Map<String, dynamic>>> getAllPurchaseOrders(
      {int limit = 50}) async {
    final result = db.select(
      "SELECT po.*, p.code as part_code, p.name as part_name, s.name as supplier_name "
      "FROM purchase_orders po "
      "LEFT JOIN parts p ON p.id = po.part_id "
      "LEFT JOIN suppliers s ON s.id = po.supplier_id "
      "ORDER BY po.created_at DESC LIMIT ?",
      [limit],
    );
    return result.map(_rowToMap).toList().cast<Map<String, dynamic>>();
  }

  Future<void> updatePurchaseOrderStatus(String id, String status) async {
    db.execute(
        'UPDATE purchase_orders SET status = ? WHERE id = ?', [status, id]);
  }

  // ── Backup & Erase ────────────────────────────────────────────────────

  /// Backs up every row of [table] into backup_records before erasing.
  Future<void> backupTable({
    required String table,
    required String userId,
    required String factoryId,
    required String reason,
  }) async {
    final rows = db.select('SELECT * FROM $table');
    final now = DateTime.now().toIso8601String();
    for (final row in rows) {
      final id = const Uuid().v4();
      db.execute(
        'INSERT OR IGNORE INTO backup_records '
        '(id, factory_id, user_id, source_table, source_record_id, data_json, backup_reason, backed_up_at, sync_status) '
        'VALUES (?,?,?,?,?,?,?,?,?)',
        [
          id,
          factoryId,
          userId,
          table,
          row['id']?.toString() ?? id,
          jsonEncode(Map<String, dynamic>.from(row)),
          reason,
          now,
          'pending',
        ],
      );
    }
  }

  Future<void> createBackupRecord({
    required String sourceTable,
    required String sourceRecordId,
    required String userId,
    required String factoryId,
    required Map<String, dynamic> data,
    required String reason,
  }) async {
    db.execute(
      'INSERT OR IGNORE INTO backup_records '
      '(id, factory_id, user_id, source_table, source_record_id, data_json, backup_reason, backed_up_at, sync_status) '
      'VALUES (?,?,?,?,?,?,?,?,?)',
      [
        const Uuid().v4(),
        factoryId,
        userId,
        sourceTable,
        sourceRecordId,
        jsonEncode(data),
        reason,
        DateTime.now().toIso8601String(),
        'pending',
      ],
    );
  }

  /// Erases all rows from [table]. Call backupTable first.
  void eraseTable(String table) {
    db.execute('DELETE FROM $table');
  }

  /// Backs up then erases a single record by id.
  Future<void> backupAndDeleteRecord({
    required String table,
    required String recordId,
    required String userId,
    required String factoryId,
    required String reason,
  }) async {
    final rows = db.select('SELECT * FROM $table WHERE id = ?', [recordId]);
    if (rows.isEmpty) return;
    final now = DateTime.now().toIso8601String();
    final backupId = const Uuid().v4();
    db.execute(
      'INSERT OR IGNORE INTO backup_records '
      '(id, factory_id, user_id, source_table, source_record_id, data_json, backup_reason, backed_up_at, sync_status) '
      'VALUES (?,?,?,?,?,?,?,?,?)',
      [
        backupId,
        factoryId,
        userId,
        table,
        recordId,
        jsonEncode(Map<String, dynamic>.from(rows.first)),
        reason,
        now,
        'pending',
      ],
    );
    db.execute('DELETE FROM $table WHERE id = ?', [recordId]);
  }

  // ── Stock Adjustments ─────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> getStockAdjustments({
    String? partId,
    int limit = 100,
  }) async {
    final where = partId != null ? 'WHERE sa.part_id = ?' : '';
    final params = partId != null ? [partId, limit] : [limit];
    final result = db.select(
      '''SELECT sa.*, p.name as part_name, p.code as part_code
         FROM stock_adjustments sa
         LEFT JOIN parts p ON p.id = sa.part_id
         $where
         ORDER BY sa.created_at DESC LIMIT ?''',
      params,
    );
    return result.map(_rowToMap).toList().cast<Map<String, dynamic>>();
  }

  Future<void> insertStockAdjustment(Map<String, dynamic> data) async {
    await insertRecord('stock_adjustments', data);
  }

  Future<int> countTableRows(String table) async {
    final r = db.select('SELECT COUNT(*) as cnt FROM $table');
    return r.first['cnt'] as int;
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
