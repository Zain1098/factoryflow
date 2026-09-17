import 'package:factoryflow/core/constants/stock_stages.dart';
import 'package:factoryflow/core/database/database_service_native.dart';
import 'package:factoryflow/core/network/sync_service.dart';
import 'package:factoryflow/core/providers/production_flow_provider.dart';
import 'package:factoryflow/core/services/stock_ledger_service.dart';
import 'package:factoryflow/features/dispatch_faco/dispatch_faco_providers.dart';
import 'package:factoryflow/features/receive_faco/receive_faco_providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Database sqliteDatabase;
  late DatabaseService databaseService;
  late SyncService syncService;
  late StockLedgerService ledgerService;
  late DispatchFacoRepository dispatchRepo;
  late ReceiveFacoRepository receiveRepo;

  setUp(() async {
    sqliteDatabase = sqlite3.openInMemory();
    databaseService = DatabaseService.forTesting(sqliteDatabase);
    await databaseService.setActiveWorkspaceId('factory-1');
    syncService = SyncService(
      databaseService,
      onlineCheck: () async => false,
    );
    ledgerService = StockLedgerService(databaseService, syncService);
    dispatchRepo = DispatchFacoRepository(
      databaseService,
      syncService,
      ledgerService,
      const ProductionFlowConfig(),
    );
    receiveRepo = ReceiveFacoRepository(databaseService, syncService, ledgerService);

    // Seed test part
    await databaseService.insertRecord('parts', {
      'id': 'part-101',
      'factory_id': 'factory-1',
      'code': 'P-101',
      'name': 'Gear Plate',
    });

    // Seed test vendors
    await databaseService.insertRecord('vendors', {
      'id': 'vendor-101',
      'factory_id': 'factory-1',
      'name': 'Apex Coating Solutions',
    });
    await databaseService.insertRecord('vendors', {
      'id': 'vendor-102',
      'factory_id': 'factory-1',
      'name': 'Precision Heat Treaters',
    });
  });

  tearDown(() {
    sqliteDatabase.close();
  });

  Future<void> seedStock({
    required String id,
    required String partId,
    required StockStage stage,
    required double qty,
  }) async {
    final res = await databaseService.writeStockLedgerEntry(
      id: id,
      factoryId: 'factory-1',
      partId: partId,
      stage: stage,
      direction: LedgerDirection.in_,
      qty: qty,
      refTable: 'test_seed',
      refId: id,
    );
    expect(res.success, isTrue);
  }

  Future<void> seedProductionBatch({
    required String batchNumber,
    required String partId,
    required double qty,
  }) async {
    await databaseService.insertRecord('productions', {
      'id': 'prod-$batchNumber',
      'factory_id': 'factory-1',
      'batch_number': batchNumber,
      'part_id': partId,
      'production_qty': qty,
      'good_qty': qty,
      'date': '2026-09-17',
      'time': '08:00',
      'sync_status': 'synced',
    });
  }

  group('Dispatch to Faco Production Fixes', () {
    test('saveMulti enforces aggregate BP stock check across multiple batches of same part', () async {
      // Seed 300 BP stock
      await seedStock(id: 'seed-bp-1', partId: 'part-101', stage: StockStage.bpStock, qty: 300);
      await seedProductionBatch(batchNumber: 'BATCH-A', partId: 'part-101', qty: 300);
      await seedProductionBatch(batchNumber: 'BATCH-B', partId: 'part-101', qty: 300);

      // Attempt to dispatch 200 + 150 = 350 (exceeds 300 BP stock)
      final lines = [
        const DispatchFacoLineItem(
          partId: 'part-101',
          partCode: 'P-101',
          partName: 'Gear Plate',
          batchNumber: 'BATCH-A',
          qty: 200,
        ),
        const DispatchFacoLineItem(
          partId: 'part-101',
          partCode: 'P-101',
          partName: 'Gear Plate',
          batchNumber: 'BATCH-B',
          qty: 150,
        ),
      ];

      final result = await dispatchRepo.saveMulti(
        vendorId: 'vendor-101',
        items: lines,
        createdBy: 'user-tester',
        recordedAt: DateTime.parse('2026-09-17 12:00:00'),
      );

      expect(result.success, isFalse);
      expect(result.error, contains('total dispatch qty (350) exceeds Own BP Stock (300 PCS)'));

      // Verify no records inserted
      final dispatches = sqliteDatabase.select(
        'SELECT * FROM dispatch_to_facos WHERE part_id = ?',
        ['part-101'],
      );
      expect(dispatches, isEmpty);
    });

    test('deleteDispatchRecord queues deletion tombstone in sync_deletion_queue', () async {
      await seedStock(id: 'seed-bp-2', partId: 'part-101', stage: StockStage.bpStock, qty: 500);
      await seedProductionBatch(batchNumber: 'BATCH-TOMBSTONE', partId: 'part-101', qty: 500);

      final lines = [
        const DispatchFacoLineItem(
          partId: 'part-101',
          partCode: 'P-101',
          partName: 'Gear Plate',
          batchNumber: 'BATCH-TOMBSTONE',
          qty: 100,
        ),
      ];

      final res = await dispatchRepo.saveMulti(
        vendorId: 'vendor-101',
        items: lines,
        createdBy: 'user-tester',
        recordedAt: DateTime.parse('2026-09-17 12:00:00'),
        challannumber: 'CH-DEL-001',
      );
      expect(res.success, isTrue);

      final dispatches = sqliteDatabase.select(
        'SELECT * FROM dispatch_to_facos WHERE part_id = ?',
        ['part-101'],
      );
      expect(dispatches.length, 1);
      final dispatchId = dispatches.first['id'] as String;

      // Delete the record
      final delRes = await dispatchRepo.deleteDispatchRecord(
        dispatchId: dispatchId,
        userId: 'user-tester',
      );
      expect(delRes.success, isTrue);

      // Verify tombstone is present in sync_queue
      final tombstones = sqliteDatabase.select(
        'SELECT * FROM sync_queue WHERE table_name = ? AND record_id = ? AND operation = ?',
        ['dispatch_to_facos', dispatchId, 'delete'],
      );
      expect(tombstones.length, 1);
      expect(tombstones.first['record_id'], dispatchId);
    });

    test('getRecent computes accurate delivery_status and remaining_qty', () async {
      await seedStock(id: 'seed-bp-3', partId: 'part-101', stage: StockStage.bpStock, qty: 1000);
      await seedProductionBatch(batchNumber: 'BATCH-STAT-1', partId: 'part-101', qty: 1000);

      // Dispatch 500
      final dispRes = await dispatchRepo.saveMulti(
        vendorId: 'vendor-101',
        items: [
          const DispatchFacoLineItem(
            partId: 'part-101',
            partCode: 'P-101',
            partName: 'Gear Plate',
            batchNumber: 'BATCH-STAT-1',
            qty: 500,
          ),
        ],
        createdBy: 'user-tester',
        recordedAt: DateTime.parse('2026-09-17 10:00:00'),
        challannumber: 'CH-STAT-01',
      );
      expect(dispRes.success, isTrue);

      var recent = await dispatchRepo.getRecent();
      expect(recent.length, 1);
      expect(recent.first['delivery_status'], 'pending');
      expect((recent.first['remaining_qty'] as num).toDouble(), 500.0);

      final dispatchId = recent.first['id'] as String;

      // Partially receive 200
      final recv1 = await receiveRepo.saveMulti(
        items: [
          ReceiveFacoLineItem(
            partId: 'part-101',
            partCode: 'P-101',
            partName: 'Gear Plate',
            batchNumber: 'BATCH-STAT-1',
            qty: 200,
            dispatchRefId: dispatchId,
          ),
        ],
        createdBy: 'user-tester',
        recordedAt: DateTime.parse('2026-09-17 14:00:00'),
        supplierChallan: 'SUP-01',
      );
      expect(recv1.success, isTrue);

      recent = await dispatchRepo.getRecent();
      expect(recent.first['delivery_status'], 'partial');
      expect((recent.first['remaining_qty'] as num).toDouble(), 300.0);

      // Receive remaining 300
      final recv2 = await receiveRepo.saveMulti(
        items: [
          ReceiveFacoLineItem(
            partId: 'part-101',
            partCode: 'P-101',
            partName: 'Gear Plate',
            batchNumber: 'BATCH-STAT-1',
            qty: 300,
            dispatchRefId: dispatchId,
          ),
        ],
        createdBy: 'user-tester',
        recordedAt: DateTime.parse('2026-09-17 16:00:00'),
        supplierChallan: 'SUP-02',
      );
      expect(recv2.success, isTrue);

      recent = await dispatchRepo.getRecent();
      expect(recent.first['delivery_status'], 'completed');
      expect((recent.first['remaining_qty'] as num).toDouble(), 0.0);
    });
  });

  group('Receive from Faco Production Fixes', () {
    test('getPendingDispatches returns vendor details and supports vendor filter', () async {
      await seedStock(id: 'seed-bp-4', partId: 'part-101', stage: StockStage.bpStock, qty: 1000);
      await seedProductionBatch(batchNumber: 'BATCH-V1', partId: 'part-101', qty: 500);
      await seedProductionBatch(batchNumber: 'BATCH-V2', partId: 'part-101', qty: 500);

      // Dispatch to Vendor 1
      final d1 = await dispatchRepo.saveMulti(
        vendorId: 'vendor-101',
        items: [
          const DispatchFacoLineItem(
            partId: 'part-101',
            partCode: 'P-101',
            partName: 'Gear Plate',
            batchNumber: 'BATCH-V1',
            qty: 250,
          ),
        ],
        createdBy: 'user-tester',
        recordedAt: DateTime.parse('2026-09-17 09:00:00'),
        challannumber: 'CH-V1-001',
      );
      expect(d1.success, isTrue);

      // Dispatch to Vendor 2
      final d2 = await dispatchRepo.saveMulti(
        vendorId: 'vendor-102',
        items: [
          const DispatchFacoLineItem(
            partId: 'part-101',
            partCode: 'P-101',
            partName: 'Gear Plate',
            batchNumber: 'BATCH-V2',
            qty: 350,
          ),
        ],
        createdBy: 'user-tester',
        recordedAt: DateTime.parse('2026-09-17 09:30:00'),
        challannumber: 'CH-V2-002',
      );
      expect(d2.success, isTrue);

      // All pending dispatches for part-101
      final allPending = await receiveRepo.getPendingDispatches('part-101');
      expect(allPending.length, 2);
      expect(
        allPending.any((d) => d['vendor_name'] == 'Apex Coating Solutions' && d['dispatch_challan'] == 'CH-V1-001'),
        isTrue,
      );
      expect(
        allPending.any((d) => d['vendor_name'] == 'Precision Heat Treaters' && d['dispatch_challan'] == 'CH-V2-002'),
        isTrue,
      );

      // Filtered by vendor-101
      final vendor1Pending = await receiveRepo.getPendingDispatches('part-101', vendorId: 'vendor-101');
      expect(vendor1Pending.length, 1);
      expect(vendor1Pending.first['vendor_id'], 'vendor-101');
      expect(vendor1Pending.first['dispatch_challan'], 'CH-V1-001');
    });

    test('lookupPendingDispatch finds pending dispatches by challan or batch', () async {
      await seedStock(id: 'seed-bp-5', partId: 'part-101', stage: StockStage.bpStock, qty: 1000);
      await seedProductionBatch(batchNumber: 'BATCH-SEARCH-XYZ', partId: 'part-101', qty: 500);

      final d = await dispatchRepo.saveMulti(
        vendorId: 'vendor-101',
        items: [
          const DispatchFacoLineItem(
            partId: 'part-101',
            partCode: 'P-101',
            partName: 'Gear Plate',
            batchNumber: 'BATCH-SEARCH-XYZ',
            qty: 120,
          ),
        ],
        createdBy: 'user-tester',
        recordedAt: DateTime.parse('2026-09-17 11:00:00'),
        challannumber: 'CH-SEARCH-999',
      );
      expect(d.success, isTrue);

      // Lookup by challan
      final matchesByChallan = await receiveRepo.lookupPendingDispatch('CH-SEARCH-999');
      expect(matchesByChallan, isNotEmpty);
      final foundByChallan = matchesByChallan.first;
      expect(foundByChallan['batch_number'], 'BATCH-SEARCH-XYZ');
      expect(foundByChallan['vendor_name'], 'Apex Coating Solutions');

      // Lookup by batch
      final matchesByBatch = await receiveRepo.lookupPendingDispatch('BATCH-SEARCH-XYZ');
      expect(matchesByBatch, isNotEmpty);
      final foundByBatch = matchesByBatch.first;
      expect(foundByBatch['dispatch_challan'], 'CH-SEARCH-999');

      // Non-existent lookup returns empty list
      final notFound = await receiveRepo.lookupPendingDispatch('NON-EXISTENT-CODE');
      expect(notFound, isEmpty);
    });

    test('saveMulti enforces aggregate remaining stock check across multiple receive lines for same dispatch', () async {
      await seedStock(id: 'seed-bp-6', partId: 'part-101', stage: StockStage.bpStock, qty: 500);
      await seedProductionBatch(batchNumber: 'BATCH-AGGR-RECV', partId: 'part-101', qty: 500);

      final d = await dispatchRepo.saveMulti(
        vendorId: 'vendor-101',
        items: [
          const DispatchFacoLineItem(
            partId: 'part-101',
            partCode: 'P-101',
            partName: 'Gear Plate',
            batchNumber: 'BATCH-AGGR-RECV',
            qty: 200,
          ),
        ],
        createdBy: 'user-tester',
        recordedAt: DateTime.parse('2026-09-17 10:00:00'),
        challannumber: 'CH-AGGR-01',
      );
      expect(d.success, isTrue);

      final dispatches = await receiveRepo.getPendingDispatches('part-101');
      expect(dispatches.length, 1);
      final dispId = dispatches.first['id'] as String;

      // Two lines pointing to the same dispatch: 150 + 100 = 250 (exceeds 200 remaining)
      final multiLines = [
        ReceiveFacoLineItem(
          partId: 'part-101',
          partCode: 'P-101',
          partName: 'Gear Plate',
          batchNumber: 'BATCH-AGGR-RECV',
          qty: 150,
          dispatchRefId: dispId,
        ),
        ReceiveFacoLineItem(
          partId: 'part-101',
          partCode: 'P-101',
          partName: 'Gear Plate',
          batchNumber: 'BATCH-AGGR-RECV',
          qty: 100,
          dispatchRefId: dispId,
        ),
      ];

      final result = await receiveRepo.saveMulti(
        items: multiLines,
        createdBy: 'user-tester',
        recordedAt: DateTime.parse('2026-09-17 15:00:00'),
      );

      expect(result.success, isFalse);
      expect(result.error, contains('Total received quantity (250) exceeds remaining dispatch quantity (200 PCS)'));

      // Verify no records inserted
      final receives = sqliteDatabase.select(
        'SELECT * FROM receive_from_facos WHERE part_id = ?',
        ['part-101'],
      );
      expect(receives, isEmpty);
    });
  });
}
