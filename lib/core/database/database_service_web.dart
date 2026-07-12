// Web stub — sqlite3/dart:ffi not available on web.
// Uses in-memory storage so the app can run on Chrome for UI testing.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../constants/stock_stages.dart';

final databaseServiceProvider = Provider<DatabaseService>((ref) {
  return DatabaseService.instance;
});

class DatabaseService {
  DatabaseService._();
  static final DatabaseService instance = DatabaseService._();

  // In-memory tables
  final Map<String, List<Map<String, dynamic>>> _tables = {};
  bool _initialized = false;

  // Expose a fake "db" object so call sites that use db.select() still compile
  _FakeDb get db => _FakeDb(_tables);

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
  }

  Future<double> getCurrentBalance(String partId, String stage) async => 0;
  Future<double> getTotalBalanceByStage(String stage) async => 0;

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

  Future<List<Map<String, dynamic>>> getActiveOperators() async =>
      List<Map<String, dynamic>>.from(_tables['operators'] ?? []);

  Future<List<Map<String, dynamic>>> getVehicles() async =>
      List<Map<String, dynamic>>.from(_tables['vehicles'] ?? []);

  Future<List<Map<String, dynamic>>> getDrivers() async =>
      List<Map<String, dynamic>>.from(_tables['drivers'] ?? []);

  Future<void> insertRecord(String table, Map<String, dynamic> data) async {
    _tables.putIfAbsent(table, () => []);
    final list = _tables[table]!;
    final idx = list.indexWhere((r) => r['id'] == data['id']);
    if (idx >= 0) {
      list[idx] = data;
    } else {
      list.add(Map<String, dynamic>.from(data));
    }
  }

  Future<void> enqueueSync({
    required String tableName,
    required String recordId,
    required String operation,
    required Map<String, dynamic> payload,
  }) async {}

  Future<List<Map<String, dynamic>>> getPendingSyncItems() async => [];
  Future<int> countPendingSync() async => 0;
  Future<void> updateSyncStatus(int id, String status, {int? attempts}) async {}
  Future<void> markRecordSynced(String table, String id) async {}
  Future<void> markRecordConflict(String table, String id) async {}

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

  Future<List<Map<String, dynamic>>> searchRecords({
    String? batchNumber,
    String? partId,
    String? dateFrom,
    String? dateTo,
    int limit = 50,
  }) async => [];

  Future<void> seedDemoData() async {
    const factoryId = '00000000-0000-0000-0000-000000000001';
    await insertRecord('parts', {'id': 'part-001', 'factory_id': factoryId, 'code': 'V21', 'name': 'Part V21', 'uom': 'PCS', 'active': 1});
    await insertRecord('parts', {'id': 'part-002', 'factory_id': factoryId, 'code': 'V22', 'name': 'Part V22', 'uom': 'PCS', 'active': 1});
    await insertRecord('machines', {'id': 'mach-001', 'factory_id': factoryId, 'name': 'Bending', 'sequence_order': 1, 'active': 1});
    await insertRecord('machines', {'id': 'mach-002', 'factory_id': factoryId, 'name': 'Notching', 'sequence_order': 2, 'active': 1});
    await insertRecord('machines', {'id': 'mach-003', 'factory_id': factoryId, 'name': 'End Forming', 'sequence_order': 3, 'active': 1});
    await insertRecord('suppliers', {'id': 'sup-001', 'factory_id': factoryId, 'name': 'Steel Supplier', 'active': 1});
    await insertRecord('vendors', {'id': 'ven-001', 'factory_id': factoryId, 'name': 'Faco', 'active': 1});
    await insertRecord('customers', {'id': 'cust-001', 'factory_id': factoryId, 'name': 'Thal', 'is_default': 1, 'active': 1});
    await insertRecord('operators', {'id': 'op-001', 'factory_id': factoryId, 'name': 'Operator 1', 'active': 1});
    await insertRecord('operators', {'id': 'op-002', 'factory_id': factoryId, 'name': 'Operator 2', 'active': 1});
  }

  void dispose() {}
}

/// Fake db object so existing code calling db.select(...) compiles on web
class _FakeDb {
  _FakeDb(this._tables);
  final Map<String, List<Map<String, dynamic>>> _tables;

  List<Map<String, dynamic>> select(String sql, [List<Object?> params = const []]) => [];

  void execute(String sql, [List<Object?> params = const []]) {}
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
