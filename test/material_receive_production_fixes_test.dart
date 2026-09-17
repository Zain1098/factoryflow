import 'package:factoryflow/core/constants/stock_stages.dart';
import 'package:factoryflow/core/database/database_service_native.dart';
import 'package:factoryflow/core/network/sync_service.dart';
import 'package:factoryflow/core/services/alert_producer_service.dart';
import 'package:factoryflow/core/services/stock_ledger_service.dart';
import 'package:factoryflow/features/material_receive/material_receive_providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Database sqliteDatabase;
  late DatabaseService databaseService;
  late SyncService syncService;
  late StockLedgerService ledgerService;
  late AlertProducerService alertProducerService;
  late PurchaseOrderRepository poRepo;
  late MaterialReceiveRepository receiveRepo;

  setUp(() async {
    sqliteDatabase = sqlite3.openInMemory();
    databaseService = DatabaseService.forTesting(sqliteDatabase);
    await databaseService.setActiveWorkspaceId('factory-test');
    syncService = SyncService(
      databaseService,
      onlineCheck: () async => false,
    );
    ledgerService = StockLedgerService(databaseService, syncService);
    alertProducerService = AlertProducerService(databaseService);
    poRepo = PurchaseOrderRepository(databaseService, syncService);
    receiveRepo = MaterialReceiveRepository(
      databaseService,
      syncService,
      ledgerService,
      alertProducerService,
    );

    // Insert dummy part and supplier
    await databaseService.insertRecord('parts', {
      'id': 'part-1',
      'factory_id': 'factory-test',
      'code': 'P-001',
      'name': 'Test Bolt',
      'active': 1,
    });
    await databaseService.insertRecord('suppliers', {
      'id': 'sup-1',
      'factory_id': 'factory-test',
      'name': 'Vendor Alpha',
      'active': 1,
    });
  });

  tearDown(() {
    sqliteDatabase.close();
  });

  test('Partial Delivery: PO transitions to processing, remains open, then completes', () async {
    // 1. Place PO for 1,000 PCS
    final poResult = await poRepo.save(
      partId: 'part-1',
      orderedQty: 1000,
      supplierId: 'sup-1',
      poNumber: 'PO-1001',
      createdBy: 'tester',
    );
    expect(poResult.success, isTrue);
    final poId = poResult.recordId!;

    // 2. Receive 300 PCS
    final rcv1 = await receiveRepo.save(
      partId: 'part-1',
      qty: 300,
      supplierId: 'sup-1',
      poNumber: 'PO-1001',
      poRefId: poId,
      orderedQty: 1000,
      createdBy: 'tester',
    );
    expect(rcv1.success, isTrue);
    expect(rcv1.shortfall, 700.0);

    // PO status should now be 'processing' (NOT closed/received!)
    final openPos = await poRepo.getOpenForPart('part-1');
    expect(openPos.length, 1);
    expect(openPos.first['status'], 'processing');
    expect((openPos.first['received_qty'] as num).toDouble(), 300.0);
    expect((openPos.first['remaining_qty'] as num).toDouble(), 700.0);

    // 3. Receive remaining 700 PCS
    final rcv2 = await receiveRepo.save(
      partId: 'part-1',
      qty: 700,
      supplierId: 'sup-1',
      poNumber: 'PO-1001',
      poRefId: poId,
      orderedQty: 1000,
      createdBy: 'tester',
    );
    expect(rcv2.success, isTrue);
    expect(rcv2.shortfall, 0.0);

    // Now PO status should transition to 'received' and no longer be open
    final openPosAfter = await poRepo.getOpenForPart('part-1');
    expect(openPosAfter.isEmpty, isTrue);

    final allPos = await poRepo.getAll();
    expect(allPos.first['status'], 'received');
    expect((allPos.first['received_qty'] as num).toDouble(), 1000.0);
    expect((allPos.first['remaining_qty'] as num).toDouble(), 0.0);
  });

  test('Net Delta Edit: allows receipt editing even after material has been consumed in production', () async {
    // 1. Receive 500 PCS of raw material
    final rcv = await receiveRepo.save(
      partId: 'part-1',
      qty: 500,
      supplierId: 'sup-1',
      createdBy: 'tester',
    );
    expect(rcv.success, isTrue);
    final rcvId = rcv.recordId!;

    // Current RM stock is 500
    double rmBalance = await ledgerService.getAvailableStock('part-1', StockStage.rawMaterial);
    expect(rmBalance, 500.0);

    // 2. Production floor consumes 400 PCS (e.g. machine run)
    final outResult = await databaseService.writeStockLedgerEntry(
      id: 'prod-out-1',
      factoryId: 'factory-test',
      partId: 'part-1',
      stage: StockStage.rawMaterial,
      direction: LedgerDirection.out,
      qty: 400,
      refTable: 'productions',
      refId: 'prod-1',
    );
    expect(outResult.success, isTrue);

    // Current available stock is now only 100 PCS
    rmBalance = await ledgerService.getAvailableStock('part-1', StockStage.rawMaterial);
    expect(rmBalance, 100.0);

    // 3. Edit receipt to 550 PCS (+50 delta)
    // Under old code this would fail because it tried to deduct 500 when only 100 was available!
    final update1 = await receiveRepo.update(
      id: rcvId,
      partId: 'part-1',
      qty: 550,
      supplierId: 'sup-1',
      updatedBy: 'tester',
    );
    expect(update1.success, isTrue);

    // Stock should now be 100 + 50 = 150
    rmBalance = await ledgerService.getAvailableStock('part-1', StockStage.rawMaterial);
    expect(rmBalance, 150.0);

    // 4. Edit receipt to 520 PCS (-30 delta)
    final update2 = await receiveRepo.update(
      id: rcvId,
      partId: 'part-1',
      qty: 520,
      supplierId: 'sup-1',
      updatedBy: 'tester',
    );
    expect(update2.success, isTrue);

    // Stock should now be 150 - 30 = 120
    rmBalance = await ledgerService.getAvailableStock('part-1', StockStage.rawMaterial);
    expect(rmBalance, 120.0);
  });

  test('Audit Trail: PO with received material cannot be deleted', () async {
    // 1. Place PO
    final poResult = await poRepo.save(
      partId: 'part-1',
      orderedQty: 200,
      supplierId: 'sup-1',
      poNumber: 'PO-AUDIT-1',
      createdBy: 'tester',
    );
    final poId = poResult.recordId!;

    // 2. Receive material against PO
    await receiveRepo.save(
      partId: 'part-1',
      qty: 100,
      supplierId: 'sup-1',
      poRefId: poId,
      poNumber: 'PO-AUDIT-1',
      orderedQty: 200,
      createdBy: 'tester',
    );

    // 3. Try to delete PO
    final delResult = await poRepo.delete(poId);
    expect(delResult.success, isFalse);
    expect(delResult.error, contains('already been received'));

    // Verify PO still exists in DB
    final allPos = await poRepo.getAll();
    expect(allPos.any((p) => p['id'] == poId), isTrue);
  });

  test('Deleting a receipt recomputes PO status accurately', () async {
    // 1. Place PO for 500 PCS
    final po = await poRepo.save(
      partId: 'part-1',
      orderedQty: 500,
      supplierId: 'sup-1',
      poNumber: 'PO-500',
      createdBy: 'tester',
    );
    final poId = po.recordId!;

    // 2. Receive 200 PCS
    final r1 = await receiveRepo.save(
      partId: 'part-1',
      qty: 200,
      supplierId: 'sup-1',
      poRefId: poId,
      poNumber: 'PO-500',
      orderedQty: 500,
      createdBy: 'tester',
    );

    // 3. Receive 300 PCS (completes order)
    final r2 = await receiveRepo.save(
      partId: 'part-1',
      qty: 300,
      supplierId: 'sup-1',
      poRefId: poId,
      poNumber: 'PO-500',
      orderedQty: 500,
      createdBy: 'tester',
    );

    var pos = await poRepo.getAll();
    expect(pos.first['status'], 'received');

    // 4. Delete the second receipt (300 PCS)
    final delR2 = await receiveRepo.delete(r2.recordId!);
    expect(delR2.success, isTrue);

    // PO status should move back to 'processing' (NOT 'pending', since 200 PCS still exists!)
    pos = await poRepo.getAll();
    expect(pos.first['status'], 'processing');

    // 5. Delete the first receipt (200 PCS)
    final delR1 = await receiveRepo.delete(r1.recordId!);
    expect(delR1.success, isTrue);

    // Now with 0 receipts, PO status should move back to 'pending'
    pos = await poRepo.getAll();
    expect(pos.first['status'], 'pending');
  });

  test('Auto-lookup PO by number finds open order details', () async {
    await poRepo.save(
      partId: 'part-1',
      orderedQty: 750,
      supplierId: 'sup-1',
      poNumber: 'PO-SCAN-99',
      createdBy: 'tester',
    );

    final found = await poRepo.findByPoNumber('PO-SCAN-99');
    expect(found, isNotNull);
    expect(found!['part_code'], 'P-001');
    expect(found['supplier_name'], 'Vendor Alpha');
    expect((found['ordered_qty'] as num).toDouble(), 750.0);
    expect((found['remaining_qty'] as num).toDouble(), 750.0);
  });
}
