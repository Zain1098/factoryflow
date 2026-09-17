// Web database adapter — sqlite3/dart:ffi is not available on web.
// Uses browser local storage for local-first UI and sync-queue persistence.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../constants/app_constants.dart';
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
  Stream<void> get onSyncEnqueued => const Stream.empty();
  SharedPreferences? _prefs;
  static const _storageKey = 'factoryflow_web_database_v1';
  Timer? _persistDebounce;
  bool _isPersisting = false;
  bool _needsPersistAgain = false;

  // Expose a fake "db" object so call sites that use db.select() still compile
  FakeDb get db => FakeDb(_tables, () => unawaited(_persist()));

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

  Future<void> _persist({bool immediate = false}) async {
    final prefs = _prefs;
    if (prefs == null) return;
    if (immediate) {
      _persistDebounce?.cancel();
      await _doPersist();
      return;
    }
    _persistDebounce?.cancel();
    _persistDebounce = Timer(const Duration(milliseconds: 100), () {
      unawaited(_doPersist());
    });
  }

  Future<void> _doPersist() async {
    final prefs = _prefs;
    if (prefs == null) return;
    if (_isPersisting) {
      _needsPersistAgain = true;
      return;
    }
    _isPersisting = true;
    try {
      final encoded = jsonEncode({'tables': _tables, 'sync_queue': _syncQueue});
      await prefs.setString(_storageKey, encoded);
    } catch (_) {
    } finally {
      _isPersisting = false;
      if (_needsPersistAgain) {
        _needsPersistAgain = false;
        unawaited(_doPersist());
      }
    }
  }

  Future<T> runInTransaction<T>(Future<T> Function() action) => action();

  Future<double> getCurrentBalance(String partId, String stage) async {
    final totals = await getBalancesByStage(stage);
    final row = totals.firstWhere(
      (r) => r['id'] == partId,
      orElse: () => <String, dynamic>{},
    );
    return (row['balance'] as num?)?.toDouble() ?? 0.0;
  }

  Future<double> getTotalBalanceByStage(String stage) async {
    final totals = await getAllStageTotals();
    return totals[stage] ?? 0.0;
  }

  Future<Map<String, double>> getAllStageTotals() async {
    final factoryId = activeWorkspaceId;
    if (factoryId.isEmpty) return {};
    final ledger = _tables['stock_ledger'] ?? [];
    final latestByPartStage = <String, Map<String, dynamic>>{};
    for (final row in ledger) {
      if (row['factory_id'] != factoryId) continue;
      final key = '${row['part_id']}_${row['stage']}';
      final existing = latestByPartStage[key];
      if (existing == null) {
        latestByPartStage[key] = row;
      } else {
        final existingTime = existing['created_at']?.toString() ?? '';
        final thisTime = row['created_at']?.toString() ?? '';
        if (thisTime.compareTo(existingTime) >= 0) {
          latestByPartStage[key] = row;
        }
      }
    }
    final map = <String, double>{};
    for (final row in latestByPartStage.values) {
      final stage = row['stage']?.toString();
      final bal = (row['running_balance'] as num?)?.toDouble() ?? 0.0;
      if (stage != null) {
        map[stage] = (map[stage] ?? 0.0) + bal;
      }
    }
    return map;
  }

  Future<Map<String, double>> getTodayProductionSummary(
    String todayStr, {
    String? finalMachineId,
    bool countAllStageOutput = false,
  }) async {
    final factoryId = activeWorkspaceId;
    if (factoryId.isEmpty) {
      return {
        'production': 0,
        'bp_reject': 0,
        'ap_reject': 0,
        'dispatched': 0,
      };
    }
    final prods = (_tables['productions'] ?? [])
        .where((r) => r['factory_id'] == factoryId && r['date'] == todayStr);
    double prodQty = 0;
    double bpRej = 0;
    for (final r in prods) {
      final gQty = (r['good_qty'] as num?)?.toDouble() ?? 0.0;
      final bRej = (r['bp_reject_qty'] as num?)?.toDouble() ?? 0.0;
      if (countAllStageOutput ||
          finalMachineId == null ||
          r['machine_id'] == finalMachineId) {
        prodQty += gQty;
      }
      bpRej += bRej;
    }
    final apInsps = (_tables['ap_inspections'] ?? [])
        .where((r) => r['factory_id'] == factoryId && r['date'] == todayStr);
    double apRej = 0;
    for (final r in apInsps) {
      apRej += (r['ap_reject_qty'] as num?)?.toDouble() ?? 0.0;
    }
    final disps = (_tables['final_dispatches'] ?? [])
        .where((r) => r['factory_id'] == factoryId && r['date'] == todayStr);
    double dispQty = 0;
    for (final r in disps) {
      dispQty += (r['qty'] as num?)?.toDouble() ?? 0.0;
    }
    return {
      'production': prodQty,
      'bp_reject': bpRej,
      'ap_reject': apRej,
      'dispatched': dispQty,
    };
  }

  Future<double> getTodayTarget(int dayOfWeek) async {
    final factoryId = activeWorkspaceId;
    if (factoryId.isEmpty) return 0;
    final targets = (_tables['target_master'] ?? [])
        .where((r) => r['factory_id'] == factoryId);
    final dayTargets = targets.where((r) => r['day_of_week'] == dayOfWeek);
    double total = 0;
    for (final t in dayTargets) {
      total += (t['target_qty'] as num?)?.toDouble() ?? 0;
    }
    if (total > 0) return total;
    return targets.isNotEmpty ? 0 : 500;
  }

  Future<List<Map<String, dynamic>>> getBalancesByStage(String stage) async {
    final factoryId = activeWorkspaceId;
    if (factoryId.isEmpty) return [];
    final ledger = _tables['stock_ledger'] ?? [];
    final parts = _tables['parts'] ?? [];
    final latestByPart = <String, Map<String, dynamic>>{};
    for (final row in ledger) {
      if (row['factory_id'] != factoryId || row['stage'] != stage) continue;
      final partId = row['part_id']?.toString() ?? '';
      final existing = latestByPart[partId];
      if (existing == null) {
        latestByPart[partId] = row;
      } else {
        final existingTime = existing['created_at']?.toString() ?? '';
        final thisTime = row['created_at']?.toString() ?? '';
        if (thisTime.compareTo(existingTime) >= 0) {
          latestByPart[partId] = row;
        }
      }
    }
    final result = <Map<String, dynamic>>[];
    for (final entry in latestByPart.entries) {
      final part = parts.cast<Map<String, dynamic>>().firstWhere(
            (p) => p['id'] == entry.key,
            orElse: () => <String, dynamic>{},
          );
      final bal = (entry.value['running_balance'] as num?)?.toDouble() ?? 0.0;
      if (bal > 0) {
        result.add({
          'id': entry.key,
          'code': part['code'] ?? '',
          'name': part['name'] ?? '',
          'balance': bal,
        });
      }
    }
    return result;
  }

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
    if (rows.isEmpty) return;
    final local = _tables.putIfAbsent(table, () => []);
    final remoteMap = <String, Map<String, dynamic>>{};
    for (final remote in rows) {
      final id = remote['id']?.toString();
      if (id != null && id.isNotEmpty) {
        remoteMap[id] = remote;
      }
    }
    if (remoteMap.isEmpty) return;

    local.removeWhere((row) {
      final id = row['id']?.toString();
      if (id != null && remoteMap.containsKey(id)) {
        return row['sync_status'] != 'pending';
      }
      return false;
    });
    for (final remote in remoteMap.values) {
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
  Future<String?> recomputePurchaseOrderStatus(String poId) async => null;
  Future<double> getPurchaseOrderTotalReceived(String poId) async => 0.0;
  Future<Map<String, dynamic>?> findPurchaseOrderByNumber(String poNumber) async => null;
  Future<Map<String, double>> getPendingPurchaseOrdersRemaining() async => {};

  Future<String> getNextPoNumber(
    String factoryId,
    DateTime date,
    String prefix,
  ) async {
    final list = _tables['purchase_orders'] ?? [];
    int maxSeq = 0;
    for (final row in list) {
      if (row['factory_id'] == factoryId) {
        final po = row['po_number'] as String?;
        if (po != null && po.startsWith(prefix)) {
          final remainder = po.substring(prefix.length);
          final seq = int.tryParse(remainder);
          if (seq != null && seq > maxSeq) {
            maxSeq = seq;
          }
        }
      }
    }
    return AppConstants.poNumberPattern(date, maxSeq + 1);
  }

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
            operator['factory_id'] == activeWorkspaceId && operator['active'] != 0,)
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

  Future<void> updateStockLedgerRunningBalance(
    String id,
    double runningBalance,
  ) async {
    for (final row in _tables['stock_ledger'] ?? const []) {
      if (row['id'] == id) {
        row['running_balance'] = runningBalance;
        row['sync_status'] = 'synced';
        break;
      }
    }
    await _persist();
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
      'name': 'Plating Vendor',
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

  Future<void> insertInAppNotification({
    required String title,
    required String body,
    required String type,
    String? actionRoute,
    String? factoryId,
  }) async {
    final effectiveFactoryId = (factoryId ?? activeWorkspaceId).trim();
    final id = const Uuid().v4();
    final now = DateTime.now().toIso8601String();
    await insertRecord('in_app_notifications', {
      'id': id,
      'factory_id': effectiveFactoryId,
      'title': title,
      'body': body,
      'type': type,
      'action_route': actionRoute,
      'is_read': 0,
      'created_at': now,
    });
  }

  Future<List<Map<String, dynamic>>> getInAppNotifications({
    String? type,
    int limit = 100,
  }) async {
    final list = _tables['in_app_notifications'] ?? [];
    var filtered = list.cast<Map<String, dynamic>>();
    final factoryId = activeWorkspaceId.trim();
    if (factoryId.isNotEmpty) {
      filtered = filtered.where((n) => n['factory_id'] == factoryId).toList();
    }
    if (type != null) {
      filtered = filtered.where((n) => n['type'] == type).toList();
    }
    return filtered.take(limit).toList();
  }

  Future<int> getUnreadNotificationCount() async {
    final list = _tables['in_app_notifications'] ?? [];
    var filtered = list.cast<Map<String, dynamic>>().where((n) => n['is_read'] == 0);
    final factoryId = activeWorkspaceId.trim();
    if (factoryId.isNotEmpty) {
      filtered = filtered.where((n) => n['factory_id'] == factoryId);
    }
    return filtered.length;
  }

  Future<void> markNotificationAsRead(String id) async {
    final list = _tables['in_app_notifications'] ?? [];
    for (final n in list) {
      if (n['id'] == id) n['is_read'] = 1;
    }
  }

  Future<void> markAllNotificationsAsRead() async {
    final list = _tables['in_app_notifications'] ?? [];
    final factoryId = activeWorkspaceId.trim();
    for (final n in list) {
      if (factoryId.isEmpty || n['factory_id'] == factoryId) {
        n['is_read'] = 1;
      }
    }
  }

  Future<void> clearAllNotifications() async {
    final factoryId = activeWorkspaceId.trim();
    if (factoryId.isEmpty) {
      _tables['in_app_notifications'] = [];
    } else {
      _tables['in_app_notifications'] = (_tables['in_app_notifications'] ?? [])
          .where((n) => n['factory_id'] != factoryId)
          .toList();
    }
  }

  void dispose() {}
}

/// Fake db object so existing code calling db.select(...) compiles on web
class FakeDb {
  FakeDb(this._tables, this._onChanged);
  final Map<String, List<Map<String, dynamic>>> _tables;
  final void Function() _onChanged;

  List<Map<String, dynamic>> select(
    String sql, [
    List<Object?> params = const [],
  ]) {
    print('FAKEDB_SELECT: ${sql.replaceAll(RegExp(r'\s+'), ' ').substring(0, sql.length > 80 ? 80 : sql.length)} | params: $params');
    // Special case 1: Reject Analysis query (WITH bp_inspection_rejects / all_dates_parts)
    if (sql.contains('all_dates_parts') || sql.contains('bp_inspection_rejects')) {
      final factoryId = params.isNotEmpty ? params[0]?.toString() : null;
      final fromDate = params.length > 1 ? params[1]?.toString() : null;
      final toDate = params.length > 2 ? params[2]?.toString() : null;

      final productions = _tables['productions'] ?? [];
      final bpInspections = _tables['bp_inspections'] ?? [];
      final apInspections = _tables['ap_inspections'] ?? [];
      final adjustments = _tables['stock_adjustments'] ?? [];
      final parts = {for (final p in _tables['parts'] ?? []) p['id']?.toString(): p['name']?.toString()};

      final grouped = <String, Map<String, dynamic>>{};

      // Productions
      for (final p in productions) {
        if (factoryId != null && p['factory_id'] != factoryId) continue;
        final date = p['date']?.toString() ?? '';
        if (fromDate != null && date.compareTo(fromDate) < 0) continue;
        if (toDate != null && date.compareTo(toDate) > 0) continue;
        final partId = p['part_id']?.toString() ?? '';
        final key = '$date|$partId';
        final entry = grouped.putIfAbsent(key, () => {
          'date': date,
          'part_name': parts[partId] ?? '—',
          'production': 0.0,
          'bp_rej': 0.0,
          'ap_rej': 0.0,
        },);
        entry['production'] = (entry['production'] as double) +
            ((p['production_qty'] as num?)?.toDouble() ?? 0.0);
        entry['bp_rej'] = (entry['bp_rej'] as double) +
            ((p['bp_reject_qty'] as num?)?.toDouble() ?? 0.0);
      }

      // BP QC Inspections
      for (final b in bpInspections) {
        if (factoryId != null && b['factory_id'] != factoryId) continue;
        final date = b['date']?.toString() ?? '';
        if (fromDate != null && date.compareTo(fromDate) < 0) continue;
        if (toDate != null && date.compareTo(toDate) > 0) continue;
        final partId = b['part_id']?.toString() ?? '';
        final key = '$date|$partId';
        final entry = grouped.putIfAbsent(key, () => {
          'date': date,
          'part_name': parts[partId] ?? '—',
          'production': 0.0,
          'bp_rej': 0.0,
          'ap_rej': 0.0,
        },);
        entry['bp_rej'] = (entry['bp_rej'] as double) +
            ((b['bp_reject_qty'] as num?)?.toDouble() ?? 0.0);
      }

      // AP QC Inspections
      for (final a in apInspections) {
        if (factoryId != null && a['factory_id'] != factoryId) continue;
        final date = a['date']?.toString() ?? '';
        if (fromDate != null && date.compareTo(fromDate) < 0) continue;
        if (toDate != null && date.compareTo(toDate) > 0) continue;
        final partId = a['part_id']?.toString() ?? '';
        final key = '$date|$partId';
        final entry = grouped.putIfAbsent(key, () => {
          'date': date,
          'part_name': parts[partId] ?? '—',
          'production': 0.0,
          'bp_rej': 0.0,
          'ap_rej': 0.0,
        },);
        entry['ap_rej'] = (entry['ap_rej'] as double) +
            ((a['rejected_qty'] as num?)?.toDouble() ?? 0.0);
      }

      // Stock adjustments (bp_rejected)
      for (final sa in adjustments) {
        if (factoryId != null && sa['factory_id'] != factoryId) continue;
        final stage = sa['stage']?.toString();
        if (stage != 'bp_rejected' && stage != 'production_rejected') continue;
        final createdAt = sa['created_at']?.toString() ?? '';
        final date = createdAt.length >= 10 ? createdAt.substring(0, 10) : createdAt;
        if (fromDate != null && date.compareTo(fromDate) < 0) continue;
        if (toDate != null && date.compareTo(toDate) > 0) continue;
        final partId = sa['part_id']?.toString() ?? '';
        final key = '$date|$partId';
        final entry = grouped.putIfAbsent(key, () => {
          'date': date,
          'part_name': parts[partId] ?? '—',
          'production': 0.0,
          'bp_rej': 0.0,
          'ap_rej': 0.0,
        },);
        entry['bp_rej'] = (entry['bp_rej'] as double) +
            ((sa['adjusted_qty'] as num?)?.toDouble() ?? 0.0);
      }

      final list = grouped.values
          .where((e) =>
              (e['production'] as double) > 0 ||
              (e['bp_rej'] as double) > 0 ||
              (e['ap_rej'] as double) > 0,)
          .toList();
      list.sort((a, b) => (b['date'] as String).compareTo(a['date'] as String));
      return list;
    }

    // Special case 2: BP Rejected Stock combined query
    if (sql.contains('cr.batch_number') ||
        (sql.contains('bp_rejected_actions') && sql.contains('actioned_qty'))) {
      final factoryId = params.isNotEmpty ? params[0]?.toString() : null;
      final bpInspections = _tables['bp_inspections'] ?? [];
      final productions = _tables['productions'] ?? [];
      final actions = _tables['bp_rejected_actions'] ?? [];
      final parts = {
        for (final p in _tables['parts'] ?? []) p['id']?.toString(): p,
      };
      final machines = {
        for (final m in _tables['machines'] ?? []) m['id']?.toString(): m['name']?.toString(),
      };
      final reasons = {
        for (final r in _tables['bp_reject_reasons'] ?? [])
          r['id']?.toString(): r['reason']?.toString(),
      };

      // Actioned scrap write-offs
      final actionedMap = <String, double>{};
      for (final a in actions) {
        if (factoryId != null && a['factory_id'] != factoryId) continue;
        if (a['action'] != 'final_rejected') continue;
        final partId = a['part_id']?.toString() ?? '';
        final batch = a['batch_number']?.toString() ?? '';
        final k = '$partId|$batch';
        actionedMap[k] =
            (actionedMap[k] ?? 0.0) + ((a['qty'] as num?)?.toDouble() ?? 0.0);
      }

      final batchMap = <String, Map<String, dynamic>>{};

      // 1. BP Inspections
      for (final bi in bpInspections) {
        if (factoryId != null && bi['factory_id'] != factoryId) continue;
        final rej = (bi['bp_reject_qty'] as num?)?.toDouble() ?? 0.0;
        if (rej <= 0) continue;
        final partId = bi['part_id']?.toString() ?? '';
        final batch = bi['batch_number']?.toString() ?? '';
        final key = '$partId|$batch';
        final part = parts[partId];
        if (part == null) continue;
        final reasonId = bi['reject_reason_id']?.toString();
        final reasonName = reasons[reasonId] ?? reasonId ?? 'Quality QC reject';

        final entry = batchMap.putIfAbsent(key, () => {
          'part_id': partId,
          'part_code': part['code']?.toString() ?? '',
          'part_name': part['name']?.toString() ?? '',
          'batch_number': batch,
          'qty': 0.0,
          'reasons': <String>{},
          'reject_date': bi['date']?.toString() ?? '',
          'sources': <String>{},
        },);
        entry['qty'] = (entry['qty'] as double) + rej;
        (entry['reasons'] as Set<String>).add(reasonName);
        (entry['sources'] as Set<String>).add('BP QC Inspection');
        final curD = entry['reject_date'] as String;
        final newD = bi['date']?.toString() ?? '';
        if (newD.compareTo(curD) > 0) entry['reject_date'] = newD;
      }

      // 2. Productions
      for (final pr in productions) {
        if (factoryId != null && pr['factory_id'] != factoryId) continue;
        final rej = (pr['bp_reject_qty'] as num?)?.toDouble() ?? 0.0;
        if (rej <= 0) continue;
        final partId = pr['part_id']?.toString() ?? '';
        final batch = pr['batch_number']?.toString() ?? '';
        final key = '$partId|$batch';
        final part = parts[partId];
        if (part == null) continue;
        final machId = pr['machine_id']?.toString();
        final machName = machines[machId] ?? 'Machine';
        final reasonName = 'Machine Reject: $machName';
        final sourceName = 'Machine: $machName';

        final entry = batchMap.putIfAbsent(key, () => {
          'part_id': partId,
          'part_code': part['code']?.toString() ?? '',
          'part_name': part['name']?.toString() ?? '',
          'batch_number': batch,
          'qty': 0.0,
          'reasons': <String>{},
          'reject_date': pr['date']?.toString() ?? '',
          'sources': <String>{},
        },);
        entry['qty'] = (entry['qty'] as double) + rej;
        (entry['reasons'] as Set<String>).add(reasonName);
        (entry['sources'] as Set<String>).add(sourceName);
        final curD = entry['reject_date'] as String;
        final newD = pr['date']?.toString() ?? '';
        if (newD.compareTo(curD) > 0) entry['reject_date'] = newD;
      }

      final result = <Map<String, dynamic>>[];
      for (final entry in batchMap.values) {
        final key = '${entry['part_id']}|${entry['batch_number']}';
        final actioned = actionedMap[key] ?? 0.0;
        final totalRej = entry['qty'] as double;
        final remaining = totalRej - actioned;
        if (remaining > 0) {
          result.add({
            'part_id': entry['part_id'],
            'part_code': entry['part_code'],
            'part_name': entry['part_name'],
            'batch_number': entry['batch_number'],
            'qty': remaining,
            'reason': (entry['reasons'] as Set<String>).join(', '),
            'reject_date': entry['reject_date'],
            'source': (entry['sources'] as Set<String>).join(', '),
          });
        }
      }
      result.sort((a, b) =>
          (b['reject_date'] as String).compareTo(a['reject_date'] as String),);
      return result;
    }

    // Special case 3: BP Audit History query (UNION across bp_inspections, actions, adjustments, productions)
    if (sql.contains('scrap_writeoff') && sql.contains('bp_inspections')) {
      final factoryId = params.isNotEmpty ? params[0]?.toString() : null;
      final limit = params.isNotEmpty && params.last is int ? params.last as int : 100;
      final bpInspections = _tables['bp_inspections'] ?? [];
      final actions = _tables['bp_rejected_actions'] ?? [];
      final adjustments = _tables['stock_adjustments'] ?? [];
      final productions = _tables['productions'] ?? [];
      final parts = {
        for (final p in _tables['parts'] ?? []) p['id']?.toString(): p,
      };
      final machines = {
        for (final m in _tables['machines'] ?? []) m['id']?.toString(): m['name']?.toString(),
      };
      final operators = {
        for (final op in _tables['operators'] ?? []) op['id']?.toString(): op['name']?.toString(),
      };
      final reasons = {
        for (final r in _tables['bp_reject_reasons'] ?? [])
          r['id']?.toString(): r['reason']?.toString(),
      };

      final combined = <Map<String, dynamic>>[];

      // 1. bp_inspections
      for (final bi in bpInspections) {
        if (factoryId != null && bi['factory_id'] != factoryId) continue;
        final part = parts[bi['part_id']?.toString()];
        final isHoldClearance = (bi['remarks']?.toString() ?? '')
            .startsWith('Quality Hold Clearance');
        final reasonId = bi['reject_reason_id']?.toString();
        combined.add({
          'event_type': isHoldClearance ? 'hold_release' : 'inspection',
          'id': bi['id'],
          'factory_id': bi['factory_id'],
          'date': bi['date'],
          'batch_number': bi['batch_number'],
          'part_id': bi['part_id'],
          'part_name': part?['name'] ?? '—',
          'part_code': part?['code'] ?? '—',
          'machine_name': machines[bi['machine_id']?.toString()],
          'inspector_name': operators[bi['inspector_id']?.toString()] ??
              bi['inspector_id'] ??
              'QC Inspector',
          'inspected_qty': (bi['inspected_qty'] as num?)?.toDouble() ?? 0.0,
          'bp_reject_qty': (bi['bp_reject_qty'] as num?)?.toDouble() ?? 0.0,
          'reject_reason_name': reasons[reasonId] ?? reasonId,
          'remarks': bi['remarks'],
          'photo_url': bi['photo_url'],
          'sync_status': bi['sync_status'] ?? 'synced',
        });
      }

      // 2. bp_rejected_actions (scrap_writeoff)
      for (final a in actions) {
        if (factoryId != null && a['factory_id'] != factoryId) continue;
        final part = parts[a['part_id']?.toString()];
        final qty = (a['qty'] as num?)?.toDouble() ?? 0.0;
        combined.add({
          'event_type': 'scrap_writeoff',
          'id': a['id'],
          'factory_id': a['factory_id'],
          'date': a['date'],
          'batch_number': a['batch_number'],
          'part_id': a['part_id'],
          'part_name': part?['name'] ?? '—',
          'part_code': part?['code'] ?? '—',
          'machine_name': null,
          'inspector_name': a['created_by'] ?? 'Authorized User',
          'inspected_qty': qty,
          'bp_reject_qty': qty,
          'reject_reason_name': 'Permanent Scrap Write-Off',
          'remarks': a['remarks'],
          'photo_url': null,
          'sync_status': a['sync_status'] ?? 'synced',
        });
      }

      // 3. stock_adjustments
      for (final sa in adjustments) {
        if (factoryId != null && sa['factory_id'] != factoryId) continue;
        final stage = sa['stage']?.toString();
        if (stage != 'bp_hold' && stage != 'bp_rejected') continue;
        final part = parts[sa['part_id']?.toString()];
        final qty = (sa['adjusted_qty'] as num?)?.toDouble() ?? 0.0;
        final createdAt = sa['created_at']?.toString() ?? '';
        final date = createdAt.length >= 10 ? createdAt.substring(0, 10) : createdAt;
        combined.add({
          'event_type': 'stock_adjustment',
          'id': sa['id'],
          'factory_id': sa['factory_id'],
          'date': date,
          'batch_number': sa['batch_number'] ?? 'MANUAL-${part?['code'] ?? ''}',
          'part_id': sa['part_id'],
          'part_name': part?['name'] ?? '—',
          'part_code': part?['code'] ?? '—',
          'machine_name': null,
          'inspector_name': 'Stock Manager',
          'inspected_qty': qty,
          'bp_reject_qty': stage == 'bp_rejected' ? qty : 0.0,
          'reject_reason_name': stage == 'bp_hold'
              ? 'Manual BP Hold Placement'
              : 'Manual BP Rejection Placement',
          'remarks': sa['remarks'],
          'photo_url': null,
          'sync_status': sa['sync_status'] ?? 'synced',
        });
      }

      // 4. productions with bp_reject_qty > 0
      for (final pr in productions) {
        if (factoryId != null && pr['factory_id'] != factoryId) continue;
        final rej = (pr['bp_reject_qty'] as num?)?.toDouble() ?? 0.0;
        if (rej <= 0) continue;
        final part = parts[pr['part_id']?.toString()];
        final machName = machines[pr['machine_id']?.toString()];
        combined.add({
          'event_type': 'machine_reject',
          'id': pr['id'],
          'factory_id': pr['factory_id'],
          'date': pr['date'],
          'batch_number': pr['batch_number'],
          'part_id': pr['part_id'],
          'part_name': part?['name'] ?? '—',
          'part_code': part?['code'] ?? '—',
          'machine_name': machName,
          'inspector_name': operators[pr['operator_id']?.toString()] ??
              pr['created_by'] ??
              'Machine Operator',
          'inspected_qty': (pr['production_qty'] as num?)?.toDouble() ?? 0.0,
          'bp_reject_qty': rej,
          'reject_reason_name': machName != null
              ? 'Machine Reject ($machName)'
              : 'Machine Production Rejection',
          'remarks': pr['remarks'] ?? 'Rejected at machine during production',
          'photo_url': null,
          'sync_status': pr['sync_status'] ?? 'synced',
        });
      }

      combined.sort((a, b) =>
          (b['date']?.toString() ?? '').compareTo(a['date']?.toString() ?? ''),);
      return combined.take(limit).toList();
    }

    // Custom handler for stock_ledger bp_hold query in holdMaterialReportProvider
    if (sql.contains('stock_ledger') && sql.contains('bp_hold')) {
      final factoryId = params.isNotEmpty ? params[0]?.toString() : null;
      final fromDate = params.length >= 3 ? params[1]?.toString() : null;
      final toDate = params.length >= 3 ? params[2]?.toString() : null;

      final ledger = List<Map<String, dynamic>>.from(_tables['stock_ledger'] ?? const []);
      final parts = {for (var p in (_tables['parts'] ?? const [])) p['id']?.toString(): p};
      final machines = {for (var m in (_tables['machines'] ?? const [])) m['id']?.toString(): m['name']?.toString()};
      final adjustments = {for (var sa in (_tables['stock_adjustments'] ?? const [])) sa['id']?.toString(): sa};
      final bpInspections = {for (var bi in (_tables['bp_inspections'] ?? const [])) bi['id']?.toString(): bi};

      var rows = ledger.where((l) {
        if (factoryId != null && l['factory_id']?.toString() != factoryId) return false;
        if (l['stage']?.toString() != 'bp_hold') return false;
        if (fromDate != null && toDate != null) {
          final d = l['date']?.toString() ?? '';
          if (d.compareTo(fromDate) < 0 || d.compareTo(toDate) > 0) return false;
        }
        return true;
      }).toList();

      rows.sort((a, b) => (b['date']?.toString() ?? '').compareTo(a['date']?.toString() ?? ''));

      return rows.map((r) {
        final part = parts[r['part_id']?.toString()];
        final sa = adjustments[r['ref_id']?.toString()];
        final bi = bpInspections[r['ref_id']?.toString()];
        final machineName = bi != null ? machines[bi['machine_id']?.toString()] : null;
        final reason = sa?['remarks'] ?? bi?['remarks'] ?? 'BP quality hold';
        final qty = (r['qty'] as num?)?.toDouble() ?? 0.0;
        final runningBalance = (r['running_balance'] as num?)?.toDouble() ?? 0.0;

        return {
          'date': r['date']?.toString() ?? '',
          'part_code': part?['code']?.toString() ?? '—',
          'part_name': part?['name']?.toString() ?? '—',
          'reason': reason.toString(),
          'qty': qty,
          'running_balance': runningBalance,
          'direction': r['direction']?.toString() ?? 'in',
          'machine_name': machineName ?? 'BP Inspection',
        };
      }).toList();
    }

    // Custom handler for stock_ledger rtv_stock query in holdMaterialReportProvider
    if (sql.contains('stock_ledger') && (sql.contains('rtv_stock') || sql.contains('rtv_at_vendor'))) {
      final factoryId = params.isNotEmpty ? params[0]?.toString() : null;
      final fromDate = params.length >= 3 ? params[1]?.toString() : null;
      final toDate = params.length >= 3 ? params[2]?.toString() : null;

      final ledger = List<Map<String, dynamic>>.from(_tables['stock_ledger'] ?? const []);
      final parts = {for (var p in (_tables['parts'] ?? const [])) p['id']?.toString(): p};
      final vendors = {for (var v in (_tables['vendors'] ?? const [])) v['id']?.toString(): v['name']?.toString()};
      final adjustments = {for (var sa in (_tables['stock_adjustments'] ?? const [])) sa['id']?.toString(): sa};
      final rtvs = {for (var rtv in (_tables['rtvs'] ?? const [])) rtv['id']?.toString(): rtv};

      var rows = ledger.where((l) {
        if (factoryId != null && l['factory_id']?.toString() != factoryId) return false;
        final stage = l['stage']?.toString();
        if (stage != 'rtv_stock' && stage != 'rtv_at_vendor') return false;
        if (fromDate != null && toDate != null) {
          final d = l['date']?.toString() ?? '';
          if (d.compareTo(fromDate) < 0 || d.compareTo(toDate) > 0) return false;
        }
        return true;
      }).toList();

      rows.sort((a, b) => (b['date']?.toString() ?? '').compareTo(a['date']?.toString() ?? ''));

      return rows.map((r) {
        final part = parts[r['part_id']?.toString()];
        final sa = adjustments[r['ref_id']?.toString()];
        final rtv = rtvs[r['ref_id']?.toString()];
        final vendorName = rtv != null ? vendors[rtv['vendor_id']?.toString()] : sa?['remarks'];
        final qty = (r['qty'] as num?)?.toDouble() ?? 0.0;
        final runningBalance = (r['running_balance'] as num?)?.toDouble() ?? 0.0;

        return {
          'date': r['date']?.toString() ?? '',
          'part_code': part?['code']?.toString() ?? '—',
          'part_name': part?['name']?.toString() ?? '—',
          'vendor_name': vendorName?.toString() ?? 'Awaiting vendor rework',
          'qty': qty,
          'running_balance': runningBalance,
          'direction': r['direction']?.toString() ?? 'in',
          'stage': r['stage']?.toString() ?? 'rtv_stock',
        };
      }).toList();
    }

    final tableMatch =
        RegExp(r'FROM\s+(\w+)', caseSensitive: false).firstMatch(sql);
    final table = tableMatch?.group(1);
    if (table == null) return const [];
    var rows = List<Map<String, dynamic>>.from(_tables[table] ?? const []);

    // Filter factory_id = ?
    final fidMatch =
        RegExp(r'factory_id\s*=\s*\?', caseSensitive: false).firstMatch(sql);
    if (fidMatch != null && params.isNotEmpty) {
      final before = sql.substring(0, fidMatch.start);
      final idx = '?'.allMatches(before).length;
      if (idx < params.length && params[idx] != null) {
        rows = rows.where((row) => row['factory_id'] == params[idx]).toList();
      }
    }

    // Filter machine_id = ?
    final midMatch =
        RegExp(r'machine_id\s*=\s*\?', caseSensitive: false).firstMatch(sql);
    if (midMatch != null && params.isNotEmpty) {
      final before = sql.substring(0, midMatch.start);
      final idx = '?'.allMatches(before).length;
      if (idx < params.length && params[idx] != null) {
        rows = rows.where((row) => row['machine_id'] == params[idx]).toList();
      }
    }

    // Filter date = ?
    final dateMatch =
        RegExp(r'\bdate\s*=\s*\?', caseSensitive: false).firstMatch(sql);
    if (dateMatch != null && params.isNotEmpty) {
      final before = sql.substring(0, dateMatch.start);
      final idx = '?'.allMatches(before).length;
      if (idx < params.length && params[idx] != null) {
        rows = rows.where((row) => row['date'] == params[idx]).toList();
      }
    }

    // Filter date BETWEEN ? AND ?
    final betweenMatch = RegExp(
      r'\bdate\s+BETWEEN\s+\?\s+AND\s+\?',
      caseSensitive: false,
    ).firstMatch(sql);
    if (betweenMatch != null && params.isNotEmpty) {
      final before = sql.substring(0, betweenMatch.start);
      final idx = '?'.allMatches(before).length;
      if (idx + 1 < params.length &&
          params[idx] != null &&
          params[idx + 1] != null) {
        final fromStr = params[idx].toString();
        final toStr = params[idx + 1].toString();
        rows = rows.where((row) {
          final d = row['date']?.toString();
          if (d == null) return false;
          return d.compareTo(fromStr) >= 0 && d.compareTo(toStr) <= 0;
        }).toList();
      }
    }

    // Filter active = 1
    if (sql.toLowerCase().contains('active = 1')) {
      rows = rows.where((row) => row['active'] == 1 || row['active'] == true).toList();
    }

    // Filter end_time IS NULL
    if (sql.toLowerCase().contains('end_time is null')) {
      rows = rows.where((row) => row['end_time'] == null).toList();
    }

    // Filter status = 'pending'
    if (sql.toLowerCase().contains("status = 'pending'")) {
      rows = rows.where((row) => row['status'] == 'pending').toList();
    }

    final isTopLevelCount = RegExp(
      r'^\s*SELECT\s+(?:DISTINCT\s+)?(?:COALESCE\s*\(\s*)?COUNT\s*\(',
      caseSensitive: false,
    ).hasMatch(sql);
    final isTopLevelSum = RegExp(
      r'^\s*SELECT\s+(?:DISTINCT\s+)?(?:COALESCE\s*\(\s*)?SUM\s*\(',
      caseSensitive: false,
    ).hasMatch(sql);
    final hasGroupBy =
        RegExp(r'\bGROUP\s+BY\b', caseSensitive: false).hasMatch(sql);

    // Aggregate queries without GROUP BY always return exactly 1 row in SQL
    if (!hasGroupBy && (isTopLevelCount || isTopLevelSum)) {
      final isCount = isTopLevelCount;
      final isSum = isTopLevelSum;
      final aliasMatch =
          RegExp(r'\bAS\s+(\w+)', caseSensitive: false).firstMatch(sql);
      final alias = aliasMatch?.group(1) ?? (isCount ? 'cnt' : 'qty');

      if (isCount) {
        return [
          <String, dynamic>{alias: rows.length},
        ];
      } else if (isSum) {
        final colMatch = RegExp(
          r'SUM\s*\(\s*(?:CASE\b.*?THEN\s+(\w+)|(\w+))',
          caseSensitive: false,
        ).firstMatch(sql);
        final colName = colMatch?.group(1) ?? colMatch?.group(2);
        double sum = 0.0;
        if (colName != null) {
          for (final row in rows) {
            final val = row[colName];
            if (val is num) {
              sum += val.toDouble();
            } else if (val != null) {
              sum += double.tryParse(val.toString()) ?? 0.0;
            }
          }
        }
        return [
          <String, dynamic>{alias: sum},
        ];
      }
    }

    // Special query: Live Stock report (parts with stock_ledger stages)
    if (table == 'parts' && sql.contains("sl.stage='raw_material'")) {
      final ledgerRows = _tables['stock_ledger'] ?? [];
      final result = <Map<String, dynamic>>[];
      for (final part in rows) {
        final partId = part['id'];
        final factoryId = part['factory_id'];
        final partLedger = ledgerRows
            .where((l) => l['part_id'] == partId && l['factory_id'] == factoryId)
            .toList();

        double getLatestStageBalance(String stage) {
          final matches = partLedger.where((l) => l['stage'] == stage).toList();
          if (matches.isEmpty) return 0.0;
          final last = matches.last;
          return (last['running_balance'] as num?)?.toDouble() ??
              (last['balance'] as num?)?.toDouble() ??
              0.0;
        }

        result.add({
          'id': partId,
          'name': part['name'] ?? '',
          'code': part['code'] ?? '',
          'raw': getLatestStageBalance('raw_material'),
          'production_rejected': getLatestStageBalance('production_rejected'),
          'bp': getLatestStageBalance('bp_stock'),
          'bp_hold': getLatestStageBalance('bp_hold'),
          'bp_rejected': getLatestStageBalance('bp_rejected'),
          'faco': getLatestStageBalance('at_faco'),
          'pap': getLatestStageBalance('pending_ap'),
          'aap': getLatestStageBalance('approved_ap'),
          'aprej': getLatestStageBalance('ap_rejected'),
          'rtv': getLatestStageBalance('rtv_stock'),
          'rtv_vendor': getLatestStageBalance('rtv_at_vendor'),
        });
      }
      return result;
    }

    // Special query: Machine Report (machines with productions & downtimes)
    if (table == 'machines' && hasGroupBy && sql.contains('total_prod')) {
      final productions = _tables['productions'] ?? [];
      final downtimes = _tables['machine_downtimes'] ?? [];
      final machines = _tables['machines'] ?? [];
      final factoryId = params.isNotEmpty ? params.last?.toString() : null;
      final fromDate = params.isNotEmpty ? params[0]?.toString() : null;
      final toDate = params.length > 1 ? params[1]?.toString() : null;

      final result = <Map<String, dynamic>>[];
      for (final m in machines) {
        if (factoryId != null && m['factory_id']?.toString() != factoryId) continue;
        if (m['active'] != 1 && m['active'] != true) continue;

        final mId = m['id']?.toString();
        final fId = m['factory_id']?.toString();

        final mProds = productions.where((p) {
          if (p['machine_id']?.toString() != mId || p['factory_id']?.toString() != fId) return false;
          if (fromDate != null && toDate != null) {
            final d = p['date']?.toString() ?? '';
            if (d.compareTo(fromDate) < 0 || d.compareTo(toDate) > 0) return false;
          }
          return true;
        }).toList();

        final mDts = downtimes.where((d) {
          if (d['machine_id']?.toString() != mId || d['factory_id']?.toString() != fId) return false;
          if (fromDate != null && toDate != null) {
            final dDate = d['date']?.toString() ?? '';
            if (dDate.compareTo(fromDate) < 0 || dDate.compareTo(toDate) > 0) return false;
          }
          return true;
        }).toList();

        double totalProd = 0.0;
        double bpRej = 0.0;
        double good = 0.0;
        final runDaysSet = <String>{};
        for (final p in mProds) {
          totalProd += (p['production_qty'] as num?)?.toDouble() ?? 0.0;
          bpRej += (p['bp_reject_qty'] as num?)?.toDouble() ?? 0.0;
          good += (p['good_qty'] as num?)?.toDouble() ?? 0.0;
          if (p['date'] != null) runDaysSet.add(p['date'].toString());
        }

        int dtMins = 0;
        for (final d in mDts) {
          dtMins += (d['duration_minutes'] as num?)?.toInt() ?? 0;
        }

        result.add({
          'machine_id': mId,
          'machine_name': m['name'] ?? '',
          'total_prod': totalProd,
          'bp_rej': bpRej,
          'good': good,
          'run_days': runDaysSet.length,
          'downtime_mins': dtMins,
        });
      }
      result.sort((a, b) => ((b['total_prod'] as num?) ?? 0).compareTo((a['total_prod'] as num?) ?? 0));
      return result;
    }

    // Special query: Machine parts breakdown query
    if (table == 'productions' && sql.contains('machine_id') && sql.contains('part_id') && hasGroupBy && sql.contains('good_qty')) {
      final factoryId = params.isNotEmpty ? params[0]?.toString() : null;
      final fromDate = params.length > 1 ? params[1]?.toString() : null;
      final toDate = params.length > 2 ? params[2]?.toString() : null;

      final productions = _tables['productions'] ?? [];
      final parts = {for (var p in (_tables['parts'] ?? const [])) p['id']?.toString(): p};

      final grouped = <String, Map<String, dynamic>>{};
      for (final p in productions) {
        if (factoryId != null && p['factory_id']?.toString() != factoryId) continue;
        if (fromDate != null && toDate != null) {
          final d = p['date']?.toString() ?? '';
          if (d.compareTo(fromDate) < 0 || d.compareTo(toDate) > 0) continue;
        }
        final mId = p['machine_id']?.toString() ?? '';
        final ptId = p['part_id']?.toString() ?? '';
        final key = '${mId}__$ptId';

        final part = parts[ptId];
        final prodQty = (p['production_qty'] as num?)?.toDouble() ?? 0.0;
        final goodQty = (p['good_qty'] as num?)?.toDouble() ?? 0.0;
        final rejQty = (p['bp_reject_qty'] as num?)?.toDouble() ?? 0.0;

        if (!grouped.containsKey(key)) {
          grouped[key] = {
            'machine_id': mId,
            'part_id': ptId,
            'part_name': part?['name'] ?? '—',
            'part_code': part?['code'] ?? '—',
            'qty': 0.0,
            'good_qty': 0.0,
            'reject_qty': 0.0,
          };
        }
        grouped[key]!['qty'] = (grouped[key]!['qty'] as double) + prodQty;
        grouped[key]!['good_qty'] = (grouped[key]!['good_qty'] as double) + goodQty;
        grouped[key]!['reject_qty'] = (grouped[key]!['reject_qty'] as double) + rejQty;
      }
      final list = grouped.values.toList();
      list.sort((a, b) => ((b['qty'] as num?) ?? 0).compareTo((a['qty'] as num?) ?? 0));
      return list;
    }

    // Special query: Operator Report (operators with productions)
    if (table == 'operators' && hasGroupBy && sql.contains('total_prod')) {
      final productions = _tables['productions'] ?? [];
      final result = <Map<String, dynamic>>[];
      for (final o in rows) {
        final oId = o['id'];
        final fId = o['factory_id'];
        final oProds = productions
            .where((p) => p['operator_id'] == oId && p['factory_id'] == fId)
            .toList();

        double totalProd = 0.0;
        double bpRej = 0.0;
        double good = 0.0;
        final runDaysSet = <String>{};
        for (final p in oProds) {
          totalProd += (p['production_qty'] as num?)?.toDouble() ?? 0.0;
          bpRej += (p['bp_reject_qty'] as num?)?.toDouble() ?? 0.0;
          good += (p['good_qty'] as num?)?.toDouble() ?? 0.0;
          if (p['date'] != null) runDaysSet.add(p['date'].toString());
        }

        result.add({
          'op_name': o['name'] ?? '',
          'total_prod': totalProd,
          'bp_rej': bpRej,
          'good': good,
          'run_days': runDaysSet.length,
        });
      }
      return result;
    }

    // Special query: Downtimes grouped by date
    if (table == 'machine_downtimes' && hasGroupBy && sql.contains('GROUP BY date')) {
      final dateMap = <String, int>{};
      for (final r in rows) {
        final date = r['date']?.toString() ?? '';
        final mins = (r['duration_minutes'] as num?)?.toInt() ?? 0;
        dateMap[date] = (dateMap[date] ?? 0) + mins;
      }
      return dateMap.entries
          .map((e) => <String, dynamic>{'date': e.key, 'dt_mins': e.value})
          .toList();
    }

    // Special query: Target Master grouped by day_of_week
    if (table == 'target_master' && hasGroupBy && sql.contains('day_of_week')) {
      final dowMap = <int, double>{};
      for (final r in rows) {
        final dow = (r['day_of_week'] as num?)?.toInt() ?? 0;
        final tgt = (r['target_qty'] as num?)?.toDouble() ??
            (r['target'] as num?)?.toDouble() ??
            0.0;
        dowMap[dow] = (dowMap[dow] ?? 0.0) + tgt;
      }
      return dowMap.entries
          .map((e) => <String, dynamic>{'day_of_week': e.key, 'target': e.value})
          .toList();
    }

    // General Join & Alias enrichment for all rows
    final partsMap = {for (final p in _tables['parts'] ?? []) p['id']: p};
    final vendorsMap = {for (final v in _tables['vendors'] ?? []) v['id']: v};
    final machinesMap = {for (final m in _tables['machines'] ?? []) m['id']: m};
    final operatorsMap = {for (final o in _tables['operators'] ?? []) o['id']: o};
    final shiftsMap = {for (final s in _tables['shifts'] ?? []) s['id']: s};

    final enriched = rows.map((r) {
      final map = Map<String, dynamic>.from(r);

      // Foreign key lookups
      if (map['part_id'] != null && partsMap.containsKey(map['part_id'])) {
        final p = partsMap[map['part_id']]!;
        map.putIfAbsent('part_name', () => p['name'] ?? '—');
        map.putIfAbsent('part_code', () => p['code'] ?? '—');
      }
      if (map['vendor_id'] != null && vendorsMap.containsKey(map['vendor_id'])) {
        map.putIfAbsent('vendor_name', () => vendorsMap[map['vendor_id']]!['name'] ?? '—');
      }
      if (map['machine_id'] != null && machinesMap.containsKey(map['machine_id'])) {
        map.putIfAbsent('machine_name', () => machinesMap[map['machine_id']]!['name'] ?? '—');
      }
      if (map['operator_id'] != null && operatorsMap.containsKey(map['operator_id'])) {
        map.putIfAbsent('op_name', () => operatorsMap[map['operator_id']]!['name'] ?? '—');
        map.putIfAbsent('operator_name', () => operatorsMap[map['operator_id']]!['name'] ?? '—');
      }
      if (map['shift_id'] != null && shiftsMap.containsKey(map['shift_id'])) {
        map.putIfAbsent('shift_name', () => shiftsMap[map['shift_id']]!['name'] ?? '—');
      }

      // Column alias synonyms
      if (map.containsKey('production_qty')) {
        map.putIfAbsent('prod_qty', () => map['production_qty']);
        map.putIfAbsent('total_prod', () => map['production_qty']);
        map.putIfAbsent('production', () => map['production_qty']);
      }
      if (map.containsKey('bp_reject_qty')) {
        map.putIfAbsent('rej_qty', () => map['bp_reject_qty']);
        map.putIfAbsent('bp_rej', () => map['bp_reject_qty']);
      }
      if (!map.containsKey('good_qty') || map['good_qty'] == null) {
        final prod = (map['production_qty'] as num?)?.toDouble() ?? 0.0;
        final rej = (map['bp_reject_qty'] as num?)?.toDouble() ?? 0.0;
        map['good_qty'] = (prod - rej).clamp(0.0, double.infinity);
      }
      map.putIfAbsent('good', () => map['good_qty']);
      if (map.containsKey('duration_minutes')) {
        map.putIfAbsent('dt_mins', () => map['duration_minutes']);
        map.putIfAbsent('downtime_mins', () => map['duration_minutes']);
      }
      if (map.containsKey('target_qty')) {
        map.putIfAbsent('target', () => map['target_qty']);
      }
      if (map.containsKey('running_balance')) {
        map.putIfAbsent('qty', () => map['running_balance']);
        map.putIfAbsent('balance', () => map['running_balance']);
      }
      if (map.containsKey('balance')) {
        map.putIfAbsent('available_qty', () => map['balance']);
      }
      if (map.containsKey('qty')) {
        map.putIfAbsent('dispatch_qty', () => map['qty']);
        map.putIfAbsent('dispatched', () => map['qty']);
        map.putIfAbsent('remaining_qty', () => map['qty']);
        map.putIfAbsent('rtv_qty', () => map['qty']);
      }
      if (map.containsKey('qty_received')) {
        map.putIfAbsent('received', () => map['qty_received']);
      }
      map.putIfAbsent('run_days', () => 1);

      return map;
    }).toList();

    return enriched;
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
