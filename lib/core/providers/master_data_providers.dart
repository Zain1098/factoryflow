import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../core/database/database_service.dart';
import '../../core/network/sync_service.dart';

const _uuid = Uuid();

// ─── Master Data Revision Counter ────────────────────────────────────────────
// Incrementing this invalidates ALL master data providers at once.
final masterDataRevProvider =
    NotifierProvider<_RevNotifier, int>(_RevNotifier.new);

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

final machinesProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  ref.watch(masterDataRevProvider);
  return ref.watch(databaseServiceProvider).getActiveMachines();
});

final suppliersProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  ref.watch(masterDataRevProvider);
  return ref.watch(databaseServiceProvider).getActiveSuppliers();
});

final vendorsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  ref.watch(masterDataRevProvider);
  return ref.watch(databaseServiceProvider).getActiveVendors();
});

final customersProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  ref.watch(masterDataRevProvider);
  return ref.watch(databaseServiceProvider).getActiveCustomers();
});

final operatorsProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  ref.watch(masterDataRevProvider);
  return ref.watch(databaseServiceProvider).getActiveOperators();
});

final vehiclesProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  ref.watch(masterDataRevProvider);
  return ref.watch(databaseServiceProvider).getVehicles();
});

final driversProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  ref.watch(masterDataRevProvider);
  return ref.watch(databaseServiceProvider).getDrivers();
});

final shiftsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  ref.watch(masterDataRevProvider);
  return ref.watch(databaseServiceProvider).getActiveShifts();
});

final bpRejectReasonsProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  ref.watch(masterDataRevProvider);
  return ref.watch(databaseServiceProvider).getActiveBpRejectReasons();
});

final apRejectReasonsProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  ref.watch(masterDataRevProvider);
  return ref.watch(databaseServiceProvider).getActiveApRejectReasons();
});

final rtvReasonsProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  ref.watch(masterDataRevProvider);
  return ref.watch(databaseServiceProvider).getActiveRtvReasons();
});

// ─── Master Data Repository ───────────────────────────────────────────────────

class MasterDataRepository {
  MasterDataRepository(this._db, this._sync, this._ref);

  final DatabaseService _db;
  final SyncService _sync;
  final Ref _ref;

  void _bump() => _ref.read(masterDataRevProvider.notifier).bump();

  String get _factoryId {
    final value = _db.activeWorkspaceId.trim();
    if (value.isEmpty) {
      throw StateError('No active company workspace is selected.');
    }
    return value;
  }

  Future<void> _queueUpsert(
    String table,
    String id,
    Map<String, dynamic> values,
  ) {
    return _sync.queueInsert(
      tableName: table,
      recordId: id,
      payload: {
        'id': id,
        'factory_id': _factoryId,
        ...values,
      },
    );
  }

  Future<void> _queueUpdate(
    String table,
    String id,
    Map<String, dynamic> values,
  ) {
    return _sync.queueUpdate(
      tableName: table,
      recordId: id,
      payload: {
        'id': id,
        'factory_id': _factoryId,
        ...values,
      },
    );
  }

  Future<void> _deactivate(String table, String id) async {
    _db.db.execute(
      'UPDATE $table SET active = 0 WHERE id = ? AND factory_id = ?',
      [id, _factoryId],
    );
    await _queueUpdate(table, id, {'active': false});
    _bump();
  }

  Future<String> insertPart({
    required String code,
    required String name,
    String uom = 'PCS',
  }) async {
    final id = _uuid.v4();
    final data = {
      'id': id,
      'factory_id': _factoryId,
      'code': code,
      'name': name,
      'uom': uom,
      'active': 1,
    };
    await _db.insertRecord('parts', data);
    await _queueUpsert('parts', id, {
      'code': code,
      'name': name,
      'uom': uom,
      'active': true,
    });
    _bump();
    return id;
  }

  Future<void> updatePart(
    String id, {
    required String code,
    required String name,
  }) async {
    _db.db.execute(
      'UPDATE parts SET code = ?, name = ? WHERE id = ? AND factory_id = ?',
      [code, name, id, _factoryId],
    );
    await _queueUpdate('parts', id, {'code': code, 'name': name});
    _bump();
  }

  Future<void> deactivatePart(String id) async {
    await _deactivate('parts', id);
  }

  Future<String> insertOperator(String name) async {
    final id = _uuid.v4();
    final data = {
      'id': id,
      'factory_id': _factoryId,
      'name': name,
      'active': 1,
    };
    await _db.insertRecord('operators', data);
    await _queueUpsert('operators', id, {'name': name, 'active': true});
    _bump();
    return id;
  }

  Future<void> updateOperator(String id, String name) async {
    _db.db.execute(
      'UPDATE operators SET name = ? WHERE id = ? AND factory_id = ?',
      [name, id, _factoryId],
    );
    await _queueUpdate('operators', id, {'name': name});
    _bump();
  }

  Future<void> deactivateOperator(String id) async {
    await _deactivate('operators', id);
  }

  Future<String> insertSupplier(String name) async {
    final id = _uuid.v4();
    final data = {
      'id': id,
      'factory_id': _factoryId,
      'name': name,
      'active': 1,
    };
    await _db.insertRecord('suppliers', data);
    await _queueUpsert('suppliers', id, {'name': name, 'active': true});
    _bump();
    return id;
  }

  Future<void> updateSupplier(String id, String name) async {
    _db.db.execute(
      'UPDATE suppliers SET name = ? WHERE id = ? AND factory_id = ?',
      [name, id, _factoryId],
    );
    await _queueUpdate('suppliers', id, {'name': name});
    _bump();
  }

  Future<void> deactivateSupplier(String id) async {
    await _deactivate('suppliers', id);
  }

  Future<String> insertMachine({
    required String name,
    required String machineCode,
    required int sequenceOrder,
  }) async {
    final id = _uuid.v4();
    final data = {
      'id': id,
      'factory_id': _factoryId,
      'name': name,
      'machine_code': machineCode,
      'sequence_order': sequenceOrder,
      'active': 1,
    };
    await _db.insertRecord('machines', data);
    await _queueUpsert('machines', id, {
      'name': name,
      'machine_code': machineCode,
      'sequence_order': sequenceOrder,
      'active': true,
    });
    _bump();
    return id;
  }

  Future<void> updateMachine(
    String id, {
    required String name,
    required String machineCode,
  }) async {
    _db.db.execute(
      'UPDATE machines SET name = ?, machine_code = ? '
      'WHERE id = ? AND factory_id = ?',
      [name, machineCode, id, _factoryId],
    );
    await _queueUpdate(
      'machines',
      id,
      {'name': name, 'machine_code': machineCode},
    );
    _bump();
  }

  Future<void> deactivateMachine(String id) async {
    await _deactivate('machines', id);
  }

  Future<void> reorderMachine(String id, int sequenceOrder) async {
    _db.db.execute(
      'UPDATE machines SET sequence_order = ? '
      'WHERE id = ? AND factory_id = ?',
      [sequenceOrder, id, _factoryId],
    );
    await _queueUpdate('machines', id, {'sequence_order': sequenceOrder});
    _bump();
  }

  Future<String> insertVendor(String name) async {
    final id = _uuid.v4();
    final data = {
      'id': id,
      'factory_id': _factoryId,
      'name': name,
      'active': 1,
    };
    await _db.insertRecord('vendors', data);
    await _queueUpsert('vendors', id, {'name': name, 'active': true});
    _bump();
    return id;
  }

  // alias used by settings screen
  Future<String> insertVendorByName(String name) => insertVendor(name);

  Future<void> updateVendor(String id, String name) async {
    _db.db.execute(
      'UPDATE vendors SET name = ? WHERE id = ? AND factory_id = ?',
      [name, id, _factoryId],
    );
    await _queueUpdate('vendors', id, {'name': name});
    _bump();
  }

  Future<void> deactivateVendor(String id) async {
    await _deactivate('vendors', id);
  }

  Future<void> updateDriver(String id, String name) async {
    _db.db.execute(
      'UPDATE drivers SET name = ? WHERE id = ? AND factory_id = ?',
      [name, id, _factoryId],
    );
    await _queueUpdate('drivers', id, {'name': name});
    _bump();
  }

  Future<void> deactivateDriver(String id) async {
    await _deactivate('drivers', id);
  }

  Future<void> updateVehicle(String id, String numberPlate) async {
    _db.db.execute(
      'UPDATE vehicles SET number_plate = ? WHERE id = ? AND factory_id = ?',
      [numberPlate, id, _factoryId],
    );
    await _queueUpdate('vehicles', id, {'number_plate': numberPlate});
    _bump();
  }

  Future<void> deactivateVehicle(String id) async {
    await _deactivate('vehicles', id);
  }

  Future<String> insertVehicle(String numberPlate) async {
    final id = _uuid.v4();
    final data = {
      'id': id,
      'factory_id': _factoryId,
      'number_plate': numberPlate,
      'active': 1,
    };
    await _db.insertRecord('vehicles', data);
    await _queueUpsert(
      'vehicles',
      id,
      {'number_plate': numberPlate, 'active': true},
    );
    _bump();
    return id;
  }

  Future<String> insertDriver(String name) async {
    final id = _uuid.v4();
    final data = {
      'id': id,
      'factory_id': _factoryId,
      'name': name,
      'active': 1,
    };
    await _db.insertRecord('drivers', data);
    await _queueUpsert('drivers', id, {'name': name, 'active': true});
    _bump();
    return id;
  }

  Future<String> insertCustomer(String name) async {
    final id = _uuid.v4();
    final data = {
      'id': id,
      'factory_id': _factoryId,
      'name': name,
      'active': 1,
    };
    await _db.insertRecord('customers', data);
    await _queueUpsert('customers', id, {'name': name, 'active': true});
    _bump();
    return id;
  }

  Future<void> updateCustomer(String id, String name) async {
    _db.db.execute(
      'UPDATE customers SET name = ? WHERE id = ? AND factory_id = ?',
      [name, id, _factoryId],
    );
    await _queueUpdate('customers', id, {'name': name});
    _bump();
  }

  Future<void> deactivateCustomer(String id) => _deactivate('customers', id);

  // ── Supabase remote sync for master tables ──
  Future<void> syncMasterDataFromSupabase() async {
    try {
      final client = Supabase.instance.client;
      final factoryId = _db.activeWorkspaceId;
      const tables = [
        'parts', 'machines', 'suppliers', 'vendors', 'customers',
        'operators', 'vehicles', 'drivers',
        'shifts', 'bp_reject_reasons', 'ap_reject_reasons', 'rtv_reasons',
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
      _bump();
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
