import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../core/database/database_service.dart';
import '../../core/network/sync_service.dart';

const _uuid = Uuid();

// ─── Master Data Revision Counter ────────────────────────────────────────────
// Incrementing this invalidates ALL master data providers at once.
final masterDataRevProvider = NotifierProvider<_RevNotifier, int>(_RevNotifier.new);

class _RevNotifier extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

// ─── Master Data Providers ────────────────────────────────────────────────────

final partsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  ref.watch(masterDataRevProvider); // rebuild when rev changes
  return ref.watch(databaseServiceProvider).getActiveParts();
});

final machinesProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  ref.watch(masterDataRevProvider);
  return ref.watch(databaseServiceProvider).getActiveMachines();
});

final suppliersProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  ref.watch(masterDataRevProvider);
  return ref.watch(databaseServiceProvider).getActiveSuppliers();
});

final vendorsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  ref.watch(masterDataRevProvider);
  return ref.watch(databaseServiceProvider).getActiveVendors();
});

final customersProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  ref.watch(masterDataRevProvider);
  return ref.watch(databaseServiceProvider).getActiveCustomers();
});

final operatorsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  ref.watch(masterDataRevProvider);
  return ref.watch(databaseServiceProvider).getActiveOperators();
});

final vehiclesProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  ref.watch(masterDataRevProvider);
  return ref.watch(databaseServiceProvider).getVehicles();
});

final driversProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  ref.watch(masterDataRevProvider);
  return ref.watch(databaseServiceProvider).getDrivers();
});

// ─── Master Data Repository ───────────────────────────────────────────────────

class MasterDataRepository {
  MasterDataRepository(this._db, this._sync, this._ref);

  final DatabaseService _db;
  final SyncService _sync;
  final Ref _ref;

  void _bump() => _ref.read(masterDataRevProvider.notifier).bump();

  Future<String> insertPart(
      {required String code, required String name, String uom = 'PCS',}) async {
    final id = _uuid.v4();
    final data = {
      'id': id,
      'factory_id': _db.activeWorkspaceId,
      'code': code,
      'name': name,
      'uom': uom,
      'active': 1,
    };
    await _db.insertRecord('parts', data);
    await _sync.queueInsert(tableName: 'parts', recordId: id, payload: data);
    _bump();
    return id;
  }

  Future<void> updatePart(String id,
      {required String code, required String name,}) async {
    _db.db.execute(
        'UPDATE parts SET code = ?, name = ? WHERE id = ?', [code, name, id],);
    await _sync.queueInsert(
        tableName: 'parts',
        recordId: id,
        payload: {
          'id': id,
          'factory_id': _db.activeWorkspaceId,
          'code': code,
          'name': name,
        },);
    _bump();
  }

  Future<void> deactivatePart(String id) async {
    _db.db.execute('UPDATE parts SET active = 0 WHERE id = ?', [id]);
    _bump();
  }

  Future<String> insertOperator(String name) async {
    final id = _uuid.v4();
    final data = {
      'id': id,
      'factory_id': _db.activeWorkspaceId,
      'name': name,
      'active': 1,
    };
    await _db.insertRecord('operators', data);
    await _sync.queueInsert(
        tableName: 'operators', recordId: id, payload: data,);
    _bump();
    return id;
  }

  Future<void> updateOperator(String id, String name) async {
    _db.db.execute('UPDATE operators SET name = ? WHERE id = ?', [name, id]);
    await _sync.queueInsert(
        tableName: 'operators',
        recordId: id,
        payload: {
          'id': id,
          'factory_id': _db.activeWorkspaceId,
          'name': name,
        },);
    _bump();
  }

  Future<void> deactivateOperator(String id) async {
    _db.db.execute('UPDATE operators SET active = 0 WHERE id = ?', [id]);
    _bump();
  }

  Future<String> insertSupplier(String name) async {
    final id = _uuid.v4();
    final data = {
      'id': id,
      'factory_id': _db.activeWorkspaceId,
      'name': name,
      'active': 1,
    };
    await _db.insertRecord('suppliers', data);
    await _sync.queueInsert(tableName: 'suppliers', recordId: id, payload: data);
    _bump();
    return id;
  }

  Future<void> updateSupplier(String id, String name) async {
    _db.db.execute('UPDATE suppliers SET name = ? WHERE id = ?', [name, id]);
    await _sync.queueInsert(
        tableName: 'suppliers',
        recordId: id,
        payload: {
          'id': id,
          'factory_id': _db.activeWorkspaceId,
          'name': name,
        },);
    _bump();
  }

  Future<void> deactivateSupplier(String id) async {
    _db.db.execute('UPDATE suppliers SET active = 0 WHERE id = ?', [id]);
    _bump();
  }

  Future<String> insertMachine(
      {required String name,
      required String machineCode,
      required int sequenceOrder,}) async {
    final id = _uuid.v4();
    final data = {
      'id': id,
      'factory_id': _db.activeWorkspaceId,
      'name': name,
      'machine_code': machineCode,
      'sequence_order': sequenceOrder,
      'active': 1,
    };
    await _db.insertRecord('machines', data);
    await _sync.queueInsert(tableName: 'machines', recordId: id, payload: data);
    _bump();
    return id;
  }

  Future<void> updateMachine(String id,
      {required String name, required String machineCode,}) async {
    _db.db.execute(
        'UPDATE machines SET name = ?, machine_code = ? WHERE id = ?',
        [name, machineCode, id],);
    await _sync.queueInsert(
        tableName: 'machines',
        recordId: id,
        payload: {
          'id': id,
          'factory_id': _db.activeWorkspaceId,
          'name': name,
          'machine_code': machineCode,
        },);
    _bump();
  }

  Future<void> deactivateMachine(String id) async {
    _db.db.execute('UPDATE machines SET active = 0 WHERE id = ?', [id]);
    _bump();
  }

  Future<void> reorderMachine(String id, int sequenceOrder) async {
    _db.db.execute('UPDATE machines SET sequence_order = ? WHERE id = ?',
        [sequenceOrder, id],);
    _bump();
  }

  Future<String> insertVehicle(String numberPlate) async {
    final id = _uuid.v4();
    final data = {
      'id': id,
      'factory_id': _db.activeWorkspaceId,
      'number_plate': numberPlate,
      'active': 1,
    };
    await _db.insertRecord('vehicles', data);
    await _sync.queueInsert(tableName: 'vehicles', recordId: id, payload: data);
    _bump();
    return id;
  }

  Future<String> insertDriver(String name) async {
    final id = _uuid.v4();
    final data = {
      'id': id,
      'factory_id': _db.activeWorkspaceId,
      'name': name,
      'active': 1,
    };
    await _db.insertRecord('drivers', data);
    await _sync.queueInsert(tableName: 'drivers', recordId: id, payload: data);
    _bump();
    return id;
  }

  // ── Supabase remote sync for master tables ──
  Future<void> syncMasterDataFromSupabase() async {
    try {
      final client = Supabase.instance.client;
      final factoryId = _db.activeWorkspaceId;
      const tables = [
        'parts', 'machines', 'suppliers', 'vendors',
        'customers', 'operators', 'vehicles', 'drivers',
      ];
      for (final table in tables) {
        final rows = await client
            .from(table)
            .select()
            .eq('factory_id', factoryId)
            .timeout(const Duration(seconds: 12));
        for (final row in rows) {
          await _db.insertRecord(table, _convertBool(row));
        }
      }
      _bump(); // refresh all providers after remote sync
    } catch (_) {
      // Offline — use local cache
    }
  }

  Map<String, dynamic> _convertBool(Map<String, dynamic> row) {
    return row.map((k, v) => MapEntry(k, v is bool ? (v ? 1 : 0) : v));
  }
}

final masterDataRepositoryProvider = Provider<MasterDataRepository>((ref) {
  return MasterDataRepository(
    ref.watch(databaseServiceProvider),
    ref.watch(syncServiceProvider),
    ref,
  );
});
