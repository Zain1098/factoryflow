import 'dart:convert';

import 'package:factoryflow/core/database/database_service_native.dart';
import 'package:factoryflow/core/network/sync_service.dart';
import 'package:factoryflow/core/providers/production_flow_provider.dart';
import 'package:factoryflow/core/services/stock_ledger_service.dart';
import 'package:factoryflow/features/production/production_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Database sqliteDatabase;
  late DatabaseService databaseService;
  late StockLedgerService ledgerService;
  late ProductionRepository repository;

  setUp(() async {
    sqliteDatabase = sqlite3.openInMemory();
    databaseService = DatabaseService.forTesting(sqliteDatabase);
    await databaseService.setActiveWorkspaceId('factory-a');

    final syncService = SyncService(databaseService);
    ledgerService = StockLedgerService(databaseService, syncService);
    repository = ProductionRepository(
      databaseService,
      syncService,
      ledgerService,
      const ProductionFlowConfig(
        enabled: true,
        requiredMachineIds: ['machine-a1', 'machine-a2'],
      ),
      true,
    );

    await databaseService.insertRecord('productions', {
      'id': 'production-a1',
      'factory_id': 'factory-a',
      'batch_number': 'SHARED-BATCH-001',
      'part_id': 'part-a',
      'machine_id': 'machine-a1',
      'good_qty': 80,
      'created_at': '2026-07-29T08:00:00.000Z',
    });
    await databaseService.insertRecord('productions', {
      'id': 'production-a2',
      'factory_id': 'factory-a',
      'batch_number': 'SHARED-BATCH-001',
      'part_id': 'part-a',
      'machine_id': 'machine-a2',
      'good_qty': 70,
      'created_at': '2026-07-29T09:00:00.000Z',
    });
    await databaseService.insertRecord('productions', {
      'id': 'production-b1',
      'factory_id': 'factory-b',
      'batch_number': 'SHARED-BATCH-001',
      'part_id': 'part-b',
      'machine_id': 'machine-b1',
      'good_qty': 999,
      'created_at': '2026-07-29T10:00:00.000Z',
    });
    await databaseService.insertRecord('stock_ledger', {
      'id': 'raw-stock-a',
      'factory_id': 'factory-a',
      'part_id': 'part-a',
      'stage': 'raw_material',
      'direction': 'IN',
      'qty': 100,
      'running_balance': 100,
      'ref_table': 'material_receives',
      'ref_id': 'receive-a',
      'created_at': '2026-07-29T07:00:00.000Z',
      'sync_status': 'synced',
    });
  });

  tearDown(() {
    sqliteDatabase.close();
  });

  test('batch helpers only return records from the active factory', () async {
    expect(
      repository.getCompletedMachineIds('SHARED-BATCH-001'),
      ['machine-a1', 'machine-a2'],
    );
    expect(repository.getLastCompletedGoodQty('SHARED-BATCH-001'), 70);

    final batchRecords = repository.getBatchRecords('SHARED-BATCH-001');
    expect(batchRecords, hasLength(2));
    expect(
      batchRecords.map((record) => record['factory_id']).toSet(),
      {'factory-a'},
    );

    final recent = await repository.getRecent();
    expect(recent, hasLength(2));
    expect(
      recent.map((record) => record['factory_id']).toSet(),
      {'factory-a'},
    );
  });

  test('production save is blocked when no factory is selected', () async {
    await databaseService.setActiveWorkspaceId('');

    final result = await repository.saveJob(
      partId: 'part-a',
      partCode: 'PART-A',
      entries: [
        MachineEntry(
          machineId: 'machine-a1',
          machineName: 'Bending',
          machineCode: 'B',
          sequenceIndex: 1,
          isFinal: false,
          operatorId: 'operator-a',
          operatorName: 'Operator A',
          shiftId: 'A',
          productionQty: 10,
          rejectQty: 0,
        ),
      ],
      createdBy: 'user-a',
      recordedAt: DateTime.utc(2026, 7, 29, 8),
    );

    expect(result.batchNumber, isEmpty);
    expect(result.error, contains('No active factory workspace'));
    expect(
      sqliteDatabase
          .select('SELECT COUNT(*) AS count FROM stock_ledger')
          .first['count'],
      1,
    );
  });

  test('production insert failure rolls back ledger and sync queue', () async {
    final productionCountBefore = sqliteDatabase
        .select('SELECT COUNT(*) AS count FROM productions')
        .first['count'];
    final ledgerCountBefore = sqliteDatabase
        .select('SELECT COUNT(*) AS count FROM stock_ledger')
        .first['count'];
    final queueCountBefore = sqliteDatabase
        .select('SELECT COUNT(*) AS count FROM sync_queue')
        .first['count'];

    sqliteDatabase.execute('''
      CREATE TRIGGER fail_production_insert
      BEFORE INSERT ON productions
      BEGIN
        SELECT RAISE(ABORT, 'forced production insert failure');
      END
    ''');

    final result = await repository.saveJob(
      partId: 'part-a',
      partCode: 'PART-A',
      entries: [
        MachineEntry(
          machineId: 'machine-a1',
          machineName: 'Bending',
          machineCode: 'B',
          sequenceIndex: 1,
          isFinal: false,
          operatorId: 'operator-a',
          operatorName: 'Operator A',
          shiftId: 'A',
          productionQty: 10,
          rejectQty: 1,
        ),
      ],
      createdBy: 'user-a',
      recordedAt: DateTime.utc(2026, 7, 29, 11),
    );

    expect(result.error, contains('No stock was changed'));
    expect(
      sqliteDatabase
          .select('SELECT COUNT(*) AS count FROM productions')
          .first['count'],
      productionCountBefore,
    );
    expect(
      sqliteDatabase
          .select('SELECT COUNT(*) AS count FROM stock_ledger')
          .first['count'],
      ledgerCountBefore,
    );
    expect(
      sqliteDatabase
          .select('SELECT COUNT(*) AS count FROM sync_queue')
          .first['count'],
      queueCountBefore,
    );
    expect(
      sqliteDatabase
          .select(
            "SELECT running_balance FROM stock_ledger "
            "WHERE factory_id = 'factory-a' AND part_id = 'part-a' "
            "AND stage = 'raw_material' ORDER BY created_at DESC LIMIT 1",
          )
          .first['running_balance'],
      100,
    );
  });

  test('production ledger movements queue the server RPC operation', () async {
    final result = await ledgerService.moveThroughProductionStage(
      partId: 'part-a',
      inputStage: 'raw_material',
      inputStageLabel: 'Raw Material',
      outputStage: 'production_wip_machine-a1',
      outputStageLabel: 'Bending WIP',
      inputQty: 10,
      goodQty: 9,
      rejectQty: 1,
      refId: 'production-new',
      triggerSync: false,
    );

    expect(result.success, isTrue);
    final queued = sqliteDatabase.select(
      'SELECT table_name, operation FROM sync_queue ORDER BY id',
    );
    expect(queued, hasLength(3));
    expect(
      queued.every(
        (row) =>
            row['table_name'] == 'stock_ledger' && row['operation'] == 'ledger',
      ),
      isTrue,
    );
  });

  test('production save queues one atomic command with all ledger rows',
      () async {
    final result = await repository.saveJob(
      partId: 'part-a',
      partCode: 'PART-A',
      entries: [
        MachineEntry(
          machineId: 'machine-a1',
          machineName: 'Bending',
          machineCode: 'B',
          sequenceIndex: 1,
          isFinal: false,
          operatorId: 'operator-a',
          operatorName: 'Operator A',
          shiftId: 'A',
          productionQty: 10,
          rejectQty: 1,
        ),
      ],
      createdBy: 'user-a',
      recordedAt: DateTime.utc(2026, 7, 29, 12),
    );

    expect(result.error, isEmpty);
    final queued = sqliteDatabase.select(
      'SELECT table_name, record_id, operation, payload '
      'FROM sync_queue ORDER BY id',
    );
    expect(queued, hasLength(1));
    expect(queued.single['table_name'], 'productions');
    expect(queued.single['operation'], 'production_post');

    final payload =
        jsonDecode(queued.single['payload'] as String) as Map<String, dynamic>;
    expect(payload['command_id'], queued.single['record_id']);
    expect(payload['factory_id'], 'factory-a');
    expect(payload['device_id'], isNotEmpty);
    expect(payload['user_id'], 'user-a');
    expect(payload['schema_version'], 1);
    expect(payload['app_version'], '1.0.0+1');
    expect(payload['production']['good_qty'], isNull);
    expect(payload['ledger_entries'], hasLength(3));

    final ledgerRows = sqliteDatabase.select(
      "SELECT sync_status FROM stock_ledger "
      "WHERE ref_table = 'productions' AND ref_id = ?",
      [queued.single['record_id']],
    );
    expect(ledgerRows, hasLength(3));
    expect(ledgerRows.every((row) => row['sync_status'] == 'pending'), isTrue);
  });

  test('legacy sync remains available until server migration is activated',
      () async {
    final legacyRepository = ProductionRepository(
      databaseService,
      SyncService(databaseService),
      ledgerService,
      const ProductionFlowConfig(
        enabled: true,
        requiredMachineIds: ['machine-a1', 'machine-a2'],
      ),
      false,
    );

    final result = await legacyRepository.saveJob(
      partId: 'part-a',
      partCode: 'PART-A',
      entries: [
        MachineEntry(
          machineId: 'machine-a1',
          machineName: 'Bending',
          machineCode: 'B',
          sequenceIndex: 1,
          isFinal: false,
          operatorId: 'operator-a',
          operatorName: 'Operator A',
          shiftId: 'A',
          productionQty: 10,
          rejectQty: 0,
        ),
      ],
      createdBy: 'user-a',
      recordedAt: DateTime.utc(2026, 7, 29, 13),
    );

    expect(result.error, isEmpty);
    final queued = sqliteDatabase.select(
      'SELECT table_name, operation FROM sync_queue ORDER BY id',
    );
    expect(queued, hasLength(3));
    expect(
      queued.where((row) => row['operation'] == 'ledger'),
      hasLength(2),
    );
    expect(
      queued.where(
        (row) =>
            row['table_name'] == 'productions' && row['operation'] == 'insert',
      ),
      hasLength(1),
    );
  });
}
