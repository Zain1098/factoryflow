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
  late ProductionRepository repository;

  setUp(() async {
    sqliteDatabase = sqlite3.openInMemory();
    databaseService = DatabaseService.forTesting(sqliteDatabase);
    await databaseService.setActiveWorkspaceId('factory-a');

    final syncService = SyncService(databaseService);
    repository = ProductionRepository(
      databaseService,
      syncService,
      StockLedgerService(databaseService, syncService),
      const ProductionFlowConfig(
        enabled: true,
        requiredMachineIds: ['machine-a1', 'machine-a2'],
      ),
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
      0,
    );
  });
}
