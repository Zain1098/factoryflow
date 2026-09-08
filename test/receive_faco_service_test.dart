import 'package:factoryflow/core/constants/stock_stages.dart';
import 'package:factoryflow/core/database/database_service_native.dart';
import 'package:factoryflow/core/network/sync_service.dart';
import 'package:factoryflow/core/services/stock_ledger_service.dart';
import 'package:factoryflow/features/receive_faco/receive_faco_providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Database sqliteDatabase;
  late DatabaseService databaseService;
  late SyncService syncService;
  late StockLedgerService ledgerService;
  late ReceiveFacoRepository receiveFacoRepo;

  setUp(() async {
    sqliteDatabase = sqlite3.openInMemory();
    databaseService = DatabaseService.forTesting(sqliteDatabase);
    await databaseService.setActiveWorkspaceId('factory-a');
    syncService = SyncService(
      databaseService,
      onlineCheck: () async => false,
    );
    ledgerService = StockLedgerService(databaseService, syncService);
    receiveFacoRepo = ReceiveFacoRepository(databaseService, syncService, ledgerService);

    // Seed base tables
    await databaseService.insertRecord('parts', {
      'id': 'part-v21',
      'factory_id': 'factory-a',
      'code': 'V21',
      'name': 'Bracket Front',
    });

    await databaseService.insertRecord('vendors', {
      'id': 'vendor-abc',
      'factory_id': 'factory-a',
      'name': 'ABC Coaters',
    });

    await databaseService.insertRecord('dispatch_to_facos', {
      'id': 'dispatch-001',
      'factory_id': 'factory-a',
      'vendor_id': 'vendor-abc',
      'batch_number': 'BATCH-V21-001',
      'part_id': 'part-v21',
      'qty': 500,
      'date': '2026-09-08',
      'time': '10:00',
      'sync_status': 'synced',
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
    final result = await databaseService.writeStockLedgerEntry(
      id: id,
      factoryId: 'factory-a',
      partId: partId,
      stage: stage,
      direction: LedgerDirection.in_,
      qty: qty,
      refTable: 'test_seed',
      refId: id,
    );
    expect(result.success, isTrue);
  }

  test('getRecent supports date filtering and part/vendor joins', () async {
    await databaseService.insertRecord('receive_from_facos', {
      'id': 'rec-1',
      'factory_id': 'factory-a',
      'batch_number': 'BATCH-V21-001',
      'date': '2026-09-08',
      'part_id': 'part-v21',
      'qty_received': 300,
      'dispatch_ref_id': 'dispatch-001',
      'supplier_challan': 'CH-999',
      'shortage_flag': 1,
      'remarks': 'Morning delivery',
      'created_by': 'user-1',
      'sync_status': 'synced',
    });

    await databaseService.insertRecord('receive_from_facos', {
      'id': 'rec-2',
      'factory_id': 'factory-a',
      'batch_number': 'BATCH-V21-001',
      'date': '2026-09-07',
      'part_id': 'part-v21',
      'qty_received': 200,
      'dispatch_ref_id': 'dispatch-001',
      'supplier_challan': 'CH-888',
      'shortage_flag': 0,
      'remarks': 'Previous day delivery',
      'created_by': 'user-1',
      'sync_status': 'synced',
    });

    final all = await receiveFacoRepo.getRecent(limit: 10);
    expect(all.length, 2);
    expect(all.first['part_code'], 'V21');
    expect(all.first['vendor_name'], 'ABC Coaters');

    final filtered = await receiveFacoRepo.getRecent(date: '2026-09-08');
    expect(filtered.length, 1);
    expect(filtered.single['id'], 'rec-1');
    expect(filtered.single['qty_received'], 300);

    final emptyDate = await receiveFacoRepo.getRecent(date: '2026-09-01');
    expect(emptyDate, isEmpty);
  });

  test('deleteReceiptRecord safely reverts pendingAp stock to atFaco', () async {
    await seedStock(id: 'seed-faco', partId: 'part-v21', stage: StockStage.atFaco, qty: 200);
    await seedStock(id: 'seed-pap', partId: 'part-v21', stage: StockStage.pendingAp, qty: 300);

    await databaseService.insertRecord('receive_from_facos', {
      'id': 'rec-del-1',
      'factory_id': 'factory-a',
      'batch_number': 'BATCH-V21-001',
      'date': '2026-09-08',
      'part_id': 'part-v21',
      'qty_received': 300,
      'dispatch_ref_id': 'dispatch-001',
      'supplier_challan': 'CH-001',
      'shortage_flag': 1,
      'remarks': 'To be deleted',
      'created_by': 'user-1',
      'sync_status': 'synced',
    });

    final delResult = await receiveFacoRepo.deleteReceiptRecord(
      receiptId: 'rec-del-1',
      userId: 'user-1',
      reason: 'Wrong delivery received',
    );

    expect(delResult.success, isTrue);

    final papStock = await databaseService.getCurrentBalance('part-v21', 'pending_ap');
    final facoStock = await databaseService.getCurrentBalance('part-v21', 'at_faco');
    expect(papStock, 0);
    expect(facoStock, 500);

    final remaining = sqliteDatabase.select('SELECT * FROM receive_from_facos WHERE id = ?', ['rec-del-1']);
    expect(remaining, isEmpty);

    final backups = sqliteDatabase.select('SELECT * FROM backup_records WHERE source_record_id = ?', ['rec-del-1']);
    expect(backups.length, 1);
    expect(backups.single['backup_reason'], 'Wrong delivery received');
  });

  test('deleteReceiptRecord blocks deletion if downstream AP Inspection has already consumed stock', () async {
    await seedStock(id: 'seed-pap', partId: 'part-v21', stage: StockStage.pendingAp, qty: 100);

    await databaseService.insertRecord('receive_from_facos', {
      'id': 'rec-downstream-1',
      'factory_id': 'factory-a',
      'batch_number': 'BATCH-V21-001',
      'date': '2026-09-08',
      'part_id': 'part-v21',
      'qty_received': 300,
      'dispatch_ref_id': 'dispatch-001',
      'supplier_challan': 'CH-001',
      'shortage_flag': 1,
      'remarks': 'Partially inspected downstream',
      'created_by': 'user-1',
      'sync_status': 'synced',
    });

    final delResult = await receiveFacoRepo.deleteReceiptRecord(
      receiptId: 'rec-downstream-1',
      userId: 'user-1',
    );

    expect(delResult.success, isFalse);
    expect(delResult.error, contains('Downstream AP Inspection has already consumed this material'));

    final remaining = sqliteDatabase.select('SELECT * FROM receive_from_facos WHERE id = ?', ['rec-downstream-1']);
    expect(remaining, isNotEmpty);
  });

  test('updateReceiptRecord handles increase and decrease correctly with ledger reconciliation', () async {
    await seedStock(id: 'seed-faco', partId: 'part-v21', stage: StockStage.atFaco, qty: 200);
    await seedStock(id: 'seed-pap', partId: 'part-v21', stage: StockStage.pendingAp, qty: 300);

    await databaseService.insertRecord('receive_from_facos', {
      'id': 'rec-upd-1',
      'factory_id': 'factory-a',
      'batch_number': 'BATCH-V21-001',
      'date': '2026-09-08',
      'part_id': 'part-v21',
      'qty_received': 300,
      'dispatch_ref_id': 'dispatch-001',
      'supplier_challan': 'CH-ORIG',
      'shortage_flag': 1,
      'remarks': 'Original',
      'created_by': 'user-1',
      'sync_status': 'synced',
    });

    final overResult = await receiveFacoRepo.updateReceiptRecord(
      receiptId: 'rec-upd-1',
      newQty: 550, userId: 'user-1',
      supplierChallan: 'CH-EDIT',
      remarks: 'Over receipt',
    );
    expect(overResult.success, isFalse);
    expect(overResult.error, contains('exceeds remaining dispatch qty'));

    final incResult = await receiveFacoRepo.updateReceiptRecord(
      receiptId: 'rec-upd-1',
      newQty: 400, userId: 'user-1',
      supplierChallan: 'CH-EDIT-1',
      remarks: 'Increased to 400',
    );
    expect(incResult.success, isTrue);

    var papStock = await databaseService.getCurrentBalance('part-v21', 'pending_ap');
    var facoStock = await databaseService.getCurrentBalance('part-v21', 'at_faco');
    expect(papStock, 400);
    expect(facoStock, 100);

    final decResult = await receiveFacoRepo.updateReceiptRecord(
      receiptId: 'rec-upd-1',
      newQty: 250, userId: 'user-1',
      supplierChallan: 'CH-EDIT-2',
      remarks: 'Decreased to 250',
    );
    expect(decResult.success, isTrue);

    papStock = await databaseService.getCurrentBalance('part-v21', 'pending_ap');
    facoStock = await databaseService.getCurrentBalance('part-v21', 'at_faco');
    expect(papStock, 250);
    expect(facoStock, 250);

    final row = sqliteDatabase.select('SELECT * FROM receive_from_facos WHERE id = ?', ['rec-upd-1']).single;
    expect(row['qty_received'], 250);
    expect(row['supplier_challan'], 'CH-EDIT-2');
    expect(row['remarks'], 'Decreased to 250');
    expect(row['shortage_flag'], 1);
  });
}
