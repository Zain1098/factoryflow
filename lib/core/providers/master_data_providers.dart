import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants/app_constants.dart';
import '../../core/database/database_service.dart';
import '../../core/network/sync_service.dart';

const _uuid = Uuid();

// ─── Master Data Providers ────────────────────────────────────────────────────

final partsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final db = ref.watch(databaseServiceProvider);
  return db.getActiveParts();
});

final machinesProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final db = ref.watch(databaseServiceProvider);
  return db.getActiveMachines();
});

final suppliersProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final db = ref.watch(databaseServiceProvider);
  return db.getActiveSuppliers();
});

final vendorsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final db = ref.watch(databaseServiceProvider);
  return db.getActiveVendors();
});

final customersProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final db = ref.watch(databaseServiceProvider);
  return db.getActiveCustomers();
});

final operatorsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final db = ref.watch(databaseServiceProvider);
  return db.getActiveOperators();
});

final vehiclesProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final db = ref.watch(databaseServiceProvider);
  return db.getVehicles();
});

final driversProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final db = ref.watch(databaseServiceProvider);
  return db.getDrivers();
});

// ─── Master Data Repository ───────────────────────────────────────────────────

class MasterDataRepository {
  MasterDataRepository(this._db, this._sync);

  final DatabaseService _db;
  final SyncService _sync;

  Future<String> insertPart({required String code, required String name, String uom = 'PCS'}) async {
    final id = _uuid.v4();
    final data = {
      'id': id,
      'factory_id': AppConstants.defaultFactoryId,
      'code': code,
      'name': name,
      'uom': uom,
      'active': 1,
    };
    await _db.insertRecord('parts', data);
    await _sync.queueInsert(tableName: 'parts', recordId: id, payload: data);
    return id;
  }

  Future<void> updatePart(String id, {required String code, required String name}) async {
    _db.db.execute('UPDATE parts SET code = ?, name = ? WHERE id = ?', [code, name, id]);
    await _sync.queueInsert(tableName: 'parts', recordId: id, payload: {'id': id, 'code': code, 'name': name});
  }

  Future<void> deactivatePart(String id) async {
    _db.db.execute('UPDATE parts SET active = 0 WHERE id = ?', [id]);
  }

  Future<String> insertOperator(String name) async {
    final id = _uuid.v4();
    final data = {
      'id': id,
      'factory_id': AppConstants.defaultFactoryId,
      'name': name,
      'active': 1,
    };
    await _db.insertRecord('operators', data);
    await _sync.queueInsert(tableName: 'operators', recordId: id, payload: data);
    return id;
  }

  Future<void> updateOperator(String id, String name) async {
    _db.db.execute('UPDATE operators SET name = ? WHERE id = ?', [name, id]);
    await _sync.queueInsert(tableName: 'operators', recordId: id, payload: {'id': id, 'name': name});
  }

  Future<void> deactivateOperator(String id) async {
    _db.db.execute('UPDATE operators SET active = 0 WHERE id = ?', [id]);
  }

  Future<String> insertMachine({required String name, required String machineCode, required int sequenceOrder}) async {
    final id = _uuid.v4();
    final data = {
      'id': id,
      'factory_id': AppConstants.defaultFactoryId,
      'name': name,
      'machine_code': machineCode,
      'sequence_order': sequenceOrder,
      'active': 1,
    };
    await _db.insertRecord('machines', data);
    await _sync.queueInsert(tableName: 'machines', recordId: id, payload: data);
    return id;
  }

  Future<void> updateMachine(String id, {required String name, required String machineCode}) async {
    _db.db.execute('UPDATE machines SET name = ?, machine_code = ? WHERE id = ?', [name, machineCode, id]);
    await _sync.queueInsert(tableName: 'machines', recordId: id, payload: {'id': id, 'name': name, 'machine_code': machineCode});
  }

  Future<void> deactivateMachine(String id) async {
    _db.db.execute('UPDATE machines SET active = 0 WHERE id = ?', [id]);
  }

  Future<void> reorderMachine(String id, int sequenceOrder) async {
    _db.db.execute('UPDATE machines SET sequence_order = ? WHERE id = ?', [sequenceOrder, id]);
  }

  Future<String> insertVehicle(String numberPlate) async {
    final id = _uuid.v4();
    final data = {
      'id': id,
      'factory_id': AppConstants.defaultFactoryId,
      'number_plate': numberPlate,
      'active': 1,
    };
    await _db.insertRecord('vehicles', data);
    await _sync.queueInsert(tableName: 'vehicles', recordId: id, payload: data);
    return id;
  }

  Future<String> insertDriver(String name) async {
    final id = _uuid.v4();
    final data = {
      'id': id,
      'factory_id': AppConstants.defaultFactoryId,
      'name': name,
      'active': 1,
    };
    await _db.insertRecord('drivers', data);
    await _sync.queueInsert(tableName: 'drivers', recordId: id, payload: data);
    return id;
  }

  // ── Supabase remote sync for master tables ──
  Future<void> syncMasterDataFromSupabase() async {
    try {
      final client = Supabase.instance.client;
      const factoryId = AppConstants.defaultFactoryId;

      final tables = ['parts', 'machines', 'suppliers', 'vendors', 'customers', 'operators', 'vehicles', 'drivers'];
      for (final table in tables) {
        final rows = await client.from(table).select().eq('factory_id', factoryId);
        for (final row in rows) {
          await _db.insertRecord(table, _convertBool(row));
        }
      }
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
  );
});
