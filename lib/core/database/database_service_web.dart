// Web database adapter — sqlite3/dart:ffi is not available on web.
// Uses browser local storage for local-first UI and sync-queue persistence.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../constants/stock_stages.dart';

final databaseServiceProvider = Provider<DatabaseService>((ref) {
  return DatabaseService.instance;
});

class DatabaseService {
  DatabaseService._();
  static final DatabaseService instance = DatabaseService._();

  // In-memory tables
  final Map<String, List<Map<String, dynamic>>> _tables = {};
  final List<Map<String, dynamic>> _syncQueue = [];
  int _nextSyncId = 1;
  bool _initialized = false;
  SharedPreferences? _prefs;
  static const _storageKey = 'factoryflow_web_database_v1';

  // Expose a fake "db" object so call sites that use db.select() still compile
  _FakeDb get db => _FakeDb(_tables, () => unawaited(_persist()));

  Future<void> initialize() async {
    if (_initialized) return;
    _prefs = await SharedPreferences.getInstance();
    final raw = _prefs!.getString(_storageKey);
    if (raw != null) {
      try {
        final saved = jsonDecode(raw) as Map<String, dynamic>;
        final savedTables = saved['tables'] as Map<String, dynamic>?;
        if (savedTables != null) {
          for (final entry in savedTables.entries) {
            final rows = entry.value as List<dynamic>? ?? const [];
            _tables[entry.key] = rows
                .whereType<Map>()
                .map((row) => Map<String, dynamic>.from(row))
                .toList();
          }
        }
        final savedQueue = saved['sync_queue'] as List<dynamic>? ?? const [];
        _syncQueue.addAll(savedQueue
            .whereType<Map>()
            .map((row) => Map<String, dynamic>.from(row)),);
        final maxId = _syncQueue
            .map((row) => row['id'] as int? ?? 0)
            .fold<int>(0, (max, id) => id > max ? id : max);
        _nextSyncId = maxId + 1;
      } catch (_) {
        _tables.clear();
        _syncQueue.clear();
      }
    }
    _initialized = true;
  }

  Future<void> _persist() async {
    final prefs = _prefs;
    if (prefs == null) return;
    await prefs.setString(
      _storageKey,
      jsonEncode({'tables': _tables, 'sync_queue': _syncQueue}),
    );
  }

  Future<T> runInTransaction<T>(Future<T> Function() action) => action();

  Future<double> getCurrentBalance(String partId, String stage) async => 0;
  Future<double> getTotalBalanceByStage(String stage) async => 0;

  Future<Map<String, double>> getAllStageTotals() async => {};

  Future<Map<String, double>> getTodayProductionSummary(
    String todayStr, {
    String? finalMachineId,
    bool countAllStageOutput = false,
  }) async =>
      {
        'production': 0,
        'bp_reject': 0,
        'ap_reject': 0,
        'dispatched': 0,
      };

  Future<double> getTodayTarget(int dayOfWeek) async => 0;

  Future<List<Map<String, dynamic>>> getBalancesByStage(String stage) async =>
      [];

  Future<void> updateCorrectionStatus({
    required String id,
    required String status,
    String? reviewedBy,
    String? reviewRemarks,
  }) async {
    final rows = _tables['correction_requests'] ?? [];
    final matches = rows.where((item) => item['id'] == id);
    if (matches.isEmpty) return;
    final row = matches.first;
    if (row['factory_id'] != activeWorkspaceId) return;
    row['status'] = status;
    row['reviewed_by'] = reviewedBy;
    row['review_remarks'] = reviewRemarks;
    row['reviewed_at'] = DateTime.now().toIso8601String();
    await _persist();
  }

  Future<void> writeAuditLog({
    required String id,
    required String tableName,
    required String recordId,
    required String action,
    required String changedBy,
    Map<String, dynamic>? oldValue,
    Map<String, dynamic>? newValue,
  }) async {}

  Future<void> upsertRemoteRecords(String table, List<Map<String, dynamic>> rows) async {
    final local = _tables.putIfAbsent(table, () => []);
    for (final remote in rows) {
      final id = remote['id']?.toString();
      if (id == null || id.isEmpty) continue;
      final index = local.indexWhere((row) => row['id']?.toString() == id);
      if (index >= 0 && local[index]['sync_status'] == 'pending') continue;
      local.removeWhere((row) => row['id']?.toString() == id);
      local.add({...remote, 'sync_status': 'synced'});
    }
    await _persist();
  }

  Future<List<Map<String, dynamic>>> getOpenPurchaseOrders(
          String partId,) async =>
      [];
  Future<List<Map<String, dynamic>>> getAllPurchaseOrders(
          {int limit = 50,}) async =>
      [];
  Future<void> updatePurchaseOrderStatus(String id, String status) async {}

  Future<List<Map<String, dynamic>>> getActiveParts() async =>
      List<Map<String, dynamic>>.from(_tables['parts'] ?? []);

  Future<List<Map<String, dynamic>>> getActiveMachines() async =>
      List<Map<String, dynamic>>.from(_tables['machines'] ?? []);

  Future<List<Map<String, dynamic>>> getActiveSuppliers() async =>
      List<Map<String, dynamic>>.from(_tables['suppliers'] ?? []);

  Future<List<Map<String, dynamic>>> getActiveVendors() async =>
      List<Map<String, dynamic>>.from(_tables['vendors'] ?? []);

  Future<List<Map<String, dynamic>>> getActiveCustomers() async =>
      List<Map<String, dynamic>>.from(_tables['customers'] ?? []);

  Future<List<Map<String, dynamic>>> getActiveOperators() async {
    final operators = List<Map<String, dynamic>>.from(_tables['operators'] ?? [])
        .where((operator) =>
            operator['factory_id'] == activeWorkspaceId && operator['active'] != 0)
        .toList();
    operators.sort((a, b) {
      final order = (a['sort_order'] as num? ?? 0)
          .compareTo(b['sort_order'] as num? ?? 0);
      return order != 0
          ? order
          : (a['name']?.toString() ?? '').compareTo(b['name']?.toString() ?? '');
    });
    return operators;
  }

  Future<List<Map<String, dynamic>>> getVehicles() async =>
      List<Map<String, dynamic>>.from(_tables['vehicles'] ?? []);

  Future<List<Map<String, dynamic>>> getDrivers() async =>
      List<Map<String, dynamic>>.from(_tables['drivers'] ?? []);

  Future<List<Map<String, dynamic>>> getActiveShifts() async =>
      List<Map<String, dynamic>>.from(_tables['shifts'] ?? []);

  Future<List<Map<String, dynamic>>> getActiveBpRejectReasons() async =>
      List<Map<String, dynamic>>.from(_tables['bp_reject_reasons'] ?? []);

  Future<List<Map<String, dynamic>>> getActiveApRejectReasons() async =>
      List<Map<String, dynamic>>.from(_tables['ap_reject_reasons'] ?? []);

  Future<List<Map<String, dynamic>>> getActiveRtvReasons() async =>
      List<Map<String, dynamic>>.from(_tables['rtv_reasons'] ?? []);

  List<Map<String, dynamic>> getTargets() =>
      List<Map<String, dynamic>>.from(_tables['target_master'] ?? []);

  void upsertTarget({
    required String id,
    required String partId,
    required int dayOfWeek,
    required int targetQty,
  }) {
    _tables.putIfAbsent('target_master', () => []);
    final list = _tables['target_master']!;
    final idx = list.indexWhere((r) => r['id'] == id);
    final row = {
      'id': id,
      'factory_id': activeWorkspaceId,
      'part_id': partId,
      'day_of_week': dayOfWeek,
      'target_qty': targetQty,
    };
    if (idx >= 0) {
      list[idx] = row;
    } else {
      list.add(row);
    }
  }

  void deleteTarget(String id) {
    _tables['target_master']?.removeWhere((r) => r['id'] == id);
  }

  Future<void> recordSyncConflict({
    required String entityType,
    required String entityId,
    required Map<String, dynamic> localPayload,
    required String serverReason,
    Map<String, dynamic>? serverState,
    String? suggestedAction,
  }) async {}

  Future<void> resolveConflict(
      String id, String resolution, String reviewer,) async {}

  // ── Workspace methods ────────────────────────────────────────────────────

  Future<void> setActiveWorkspaceId(String workspaceId) async {
    _tables.putIfAbsent('app_settings', () => []);
    final list = _tables['app_settings']!;
    final idx = list.indexWhere((r) => r['key'] == 'active_workspace_id');
    if (idx >= 0) {
      list[idx] = {'key': 'active_workspace_id', 'value': workspaceId};
    } else {
      list.add({'key': 'active_workspace_id', 'value': workspaceId});
    }
    await _persist();
  }

  Future<String> getOrCreateDeviceId() async {
    _tables.putIfAbsent('app_settings', () => []);
    final list = _tables['app_settings']!;
    final idx = list.indexWhere((r) => r['key'] == 'device_id');
    if (idx >= 0) return list[idx]['value']?.toString() ?? '';

    final deviceId = const Uuid().v4();
    list.add({'key': 'device_id', 'value': deviceId});
    return deviceId;
  }

  String get activeWorkspaceId {
    final list = _tables['app_settings'] ?? [];
    final idx = list.indexWhere((r) => r['key'] == 'active_workspace_id');
    if (idx < 0) return '';
    return list[idx]['value']?.toString() ?? '';
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

  Future<void> insertRecord(String table, Map<String, dynamic> data) async {
    _tables.putIfAbsent(table, () => []);
    final list = _tables[table]!;
    final idx = list.indexWhere((r) => r['id'] == data['id']);
    if (idx >= 0) {
      list[idx] = data;
    } else {
      list.add(Map<String, dynamic>.from(data));
    }
    await _persist();
  }

  Future<void> enqueueSync({
    required String tableName,
    required String recordId,
    required String operation,
    required Map<String, dynamic> payload,
  }) async {
    if (operation == 'update') {
      _syncQueue.removeWhere((item) =>
          item['table_name'] == tableName &&
          item['record_id'] == recordId &&
          item['operation'] == 'update' &&
          item['status'] == 'pending',);
    }
    _syncQueue.add({
      'id': _nextSyncId++,
      'table_name': tableName,
      'record_id': recordId,
      'operation': operation,
      'payload': jsonEncode(payload),
      'attempts': 0,
      'status': 'pending',
      'created_at': DateTime.now().toIso8601String(),
      'next_retry_at': null,
    });
    await _persist();
  }

  Future<List<Map<String, dynamic>>> getPendingSyncItems() async {
    final workspaceId = activeWorkspaceId.trim();
    if (workspaceId.isEmpty) return const [];
    return _syncQueue
        .where((item) {
          if (item['status'] != 'pending') return false;
          final retryAt = item['next_retry_at']?.toString();
          if (retryAt != null && retryAt.compareTo(DateTime.now().toIso8601String()) > 0) {
            return false;
          }
          final payload = jsonDecode(item['payload'] as String);
          return payload is Map && payload['factory_id'] == workspaceId;
        })
        .take(50)
        .map(Map<String, dynamic>.from)
        .toList();
  }

  Future<int> countPendingSync() async =>
      (await getPendingSyncItems()).length;
  Future<void> updateSyncStatus(
    int id,
    String status, {
    int? attempts,
    String? nextRetryAt,
  }) async {
    final item = _syncQueue.cast<Map<String, dynamic>>().firstWhere(
          (row) => row['id'] == id,
          orElse: () => <String, dynamic>{},
        );
    if (item.isEmpty) return;
    item['status'] = status;
    if (attempts != null) item['attempts'] = attempts;
    item['last_attempt_at'] = DateTime.now().toIso8601String();
    item['next_retry_at'] = nextRetryAt;
    await _persist();
  }
  Future<void> markRecordSynced(String table, String id) async {
    _setSyncStatus(table, id, 'synced');
  }
  Future<void> markRecordConflict(String table, String id) async {
    _setSyncStatus(table, id, 'conflict');
  }

  void _setSyncStatus(String table, String id, String status) {
    final row = (_tables[table] ?? []).cast<Map<String, dynamic>>().firstWhere(
          (item) => item['id'] == id,
          orElse: () => <String, dynamic>{},
        );
    if (row.isNotEmpty) row['sync_status'] = status;
    unawaited(_persist());
  }

  Future<List<Map<String, dynamic>>> getProductionLedgerEntries(
    String productionId,
  ) async {
    return (_tables['stock_ledger'] ?? [])
        .where(
          (row) =>
              row['ref_table'] == 'productions' &&
              row['ref_id'] == productionId,
        )
        .map(Map<String, dynamic>.from)
        .toList();
  }

  Future<void> markProductionPostingSynced(String productionId) async {
    _setPostingSyncStatus(productionId, 'synced');
  }

  Future<void> markProductionPostingConflict(String productionId) async {
    _setPostingSyncStatus(productionId, 'conflict');
  }

  void _setPostingSyncStatus(String productionId, String status) {
    for (final row in _tables['productions'] ?? const []) {
      if (row['id'] == productionId) row['sync_status'] = status;
    }
    for (final row in _tables['stock_ledger'] ?? const []) {
      if (row['ref_table'] == 'productions' && row['ref_id'] == productionId) {
        row['sync_status'] = status;
      }
    }
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
    return const StockLedgerResult(success: true, newBalance: 0);
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
    return const StockLedgerResult(success: true, newBalance: 0);
  }

  Future<List<Map<String, dynamic>>> searchRecords({
    String? batchNumber,
    String? partId,
    String? challanNumber,
    String? dateFrom,
    String? dateTo,
    int limit = 50,
  }) async =>
      [];

  Future<void> backupTable({
    required String table,
    required String userId,
    required String factoryId,
    required String reason,
  }) async {
    final rows = List<Map<String, dynamic>>.from(_tables[table] ?? const [])
        .where((row) => row['factory_id'] == factoryId)
        .toList(growable: false);
    for (final row in rows) {
      await createBackupRecord(
        sourceTable: table,
        sourceRecordId: row['id']?.toString() ??
            DateTime.now().microsecondsSinceEpoch.toString(),
        userId: userId,
        factoryId: factoryId,
        data: row,
        reason: reason,
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
    final backups = _tables.putIfAbsent('backup_records', () => []);
    backups.add({
      'id': 'backup-${DateTime.now().microsecondsSinceEpoch}',
      'factory_id': factoryId,
      'user_id': userId,
      'source_table': sourceTable,
      'source_record_id': sourceRecordId,
      'data_json': jsonEncode(data),
      'backup_reason': reason,
      'backed_up_at': DateTime.now().toIso8601String(),
      'sync_status': 'pending',
    });
    await _persist();
  }

  void eraseTable(String table) {
    _tables[table] = [];
  }

  void eraseTableForFactory(String table, String factoryId) {
    final rows = _tables[table];
    if (rows == null) return;
    rows.removeWhere((row) => row['factory_id'] == factoryId);
    unawaited(_persist());
  }

  void eraseQueuedChangesForFactory(
    String factoryId,
    Iterable<String> tables,
  ) {
    final allowedTables = tables.toSet();
    final rows = _tables['sync_queue'];
    if (rows == null) return;
    rows.removeWhere((row) {
      if (!allowedTables.contains(row['table_name'])) return false;
      final rawPayload = row['payload'];
      try {
        final payload = rawPayload is String
            ? jsonDecode(rawPayload) as Map<String, dynamic>
            : Map<String, dynamic>.from(rawPayload as Map);
        return payload['factory_id']?.toString() == factoryId;
      } catch (_) {
        return false;
      }
    });
    unawaited(_persist());
  }

  Future<void> backupAndDeleteRecord({
    required String table,
    required String recordId,
    required String userId,
    required String factoryId,
    required String reason,
  }) async {
    final rows = _tables[table] ?? [];
    final index = rows.indexWhere((row) => row['id'] == recordId);
    if (index < 0) return;
    await createBackupRecord(
      sourceTable: table,
      sourceRecordId: recordId,
      userId: userId,
      factoryId: factoryId,
      data: rows[index],
      reason: reason,
    );
    rows.removeAt(index);
  }

  Future<int> countTableRows(String table) async => _tables[table]?.length ?? 0;

  Future<int> countTableRowsForFactory(
    String table,
    String factoryId,
  ) async =>
      (_tables[table] ?? const [])
          .where((row) => row['factory_id'] == factoryId)
          .length;

  Future<List<Map<String, dynamic>>> getStockAdjustments({
    String? partId,
    int limit = 100,
  }) async {
    final list =
        List<Map<String, dynamic>>.from(_tables['stock_adjustments'] ?? []);
    final workspaceRows = list
        .where((r) => r['factory_id'] == activeWorkspaceId)
        .toList();
    final filtered = partId != null
        ? workspaceRows.where((r) => r['part_id'] == partId).toList()
        : workspaceRows;
    filtered.sort((a, b) =>
        (b['created_at'] as String).compareTo(a['created_at'] as String),);
    return filtered.take(limit).toList();
  }

  Future<void> insertStockAdjustment(Map<String, dynamic> data) async {
    await insertRecord('stock_adjustments', data);
  }

  Future<void> seedDemoData() async {
    const factoryId = '00000000-0000-0000-0000-000000000001';
    await insertRecord('parts', {
      'id': 'part-001',
      'factory_id': factoryId,
      'code': 'V21',
      'name': 'Part V21',
      'uom': 'PCS',
      'active': 1,
    });
    await insertRecord('parts', {
      'id': 'part-002',
      'factory_id': factoryId,
      'code': 'V22',
      'name': 'Part V22',
      'uom': 'PCS',
      'active': 1,
    });
    await insertRecord('machines', {
      'id': 'mach-001',
      'factory_id': factoryId,
      'name': 'Bending',
      'sequence_order': 1,
      'active': 1,
    });
    await insertRecord('machines', {
      'id': 'mach-002',
      'factory_id': factoryId,
      'name': 'Notching',
      'sequence_order': 2,
      'active': 1,
    });
    await insertRecord('machines', {
      'id': 'mach-003',
      'factory_id': factoryId,
      'name': 'End Forming',
      'sequence_order': 3,
      'active': 1,
    });
    await insertRecord('suppliers', {
      'id': 'sup-001',
      'factory_id': factoryId,
      'name': 'Steel Supplier',
      'active': 1,
    });
    await insertRecord('vendors', {
      'id': 'ven-001',
      'factory_id': factoryId,
      'name': 'Faco',
      'active': 1,
    });
    await insertRecord('customers', {
      'id': 'cust-001',
      'factory_id': factoryId,
      'name': 'Thal',
      'is_default': 1,
      'active': 1,
    });
    await insertRecord('operators', {
      'id': 'op-001',
      'factory_id': factoryId,
      'name': 'Operator 1',
      'active': 1,
    });
    await insertRecord('operators', {
      'id': 'op-002',
      'factory_id': factoryId,
      'name': 'Operator 2',
      'active': 1,
    });
  }

  void dispose() {}
}

/// Fake db object so existing code calling db.select(...) compiles on web
class _FakeDb {
  _FakeDb(this._tables, this._onChanged);
  final Map<String, List<Map<String, dynamic>>> _tables;
  final void Function() _onChanged;

  List<Map<String, dynamic>> select(
    String sql, [
    List<Object?> params = const [],
  ]) {
    final tableMatch = RegExp(r'FROM\s+(\w+)', caseSensitive: false).firstMatch(sql);
    final table = tableMatch?.group(1);
    if (table == null) return const [];
    var rows = List<Map<String, dynamic>>.from(_tables[table] ?? const []);
    if (sql.toLowerCase().contains('where') && params.isNotEmpty) {
      if (sql.toLowerCase().contains('factory_id = ?')) {
        rows = rows.where((row) => row['factory_id'] == params.last).toList();
      }
    }
    if (sql.toLowerCase().contains('count(*)')) {
      return [<String, dynamic>{'cnt': rows.length}];
    }
    return rows.map(Map<String, dynamic>.from).toList();
  }

  void execute(String sql, [List<Object?> params = const []]) {
    final match = RegExp(
      r'UPDATE\s+(\w+)\s+SET\s+(.+?)\s+WHERE\s+id\s*=\s*\?\s+AND\s+factory_id\s*=\s*\?',
      caseSensitive: false,
    ).firstMatch(sql);
    if (match == null || params.length < 2) return;
    final table = match.group(1)!;
    final assignments = match.group(2)!.split(',');
    final id = params[params.length - 2];
    final factoryId = params.last;
    final row = (_tables[table] ?? []).cast<Map<String, dynamic>>().firstWhere(
          (item) => item['id'] == id && item['factory_id'] == factoryId,
          orElse: () => <String, dynamic>{},
        );
    if (row.isEmpty) return;
    if (assignments.length == 1 && assignments.first.contains('active')) {
      row['active'] = 0;
    }
    for (var i = 0; i < assignments.length && i < params.length - 2; i++) {
      final column = assignments[i].split('=').first.trim();
      row[column] = params[i];
    }
    _onChanged();
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
