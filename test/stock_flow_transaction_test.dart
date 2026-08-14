import 'package:factoryflow/core/constants/stock_stages.dart';
import 'package:factoryflow/core/constants/user_roles.dart';
import 'package:factoryflow/core/database/database_service_native.dart';
import 'package:factoryflow/core/network/sync_service.dart';
import 'package:factoryflow/core/services/alert_producer_service.dart';
import 'package:factoryflow/core/services/stock_ledger_service.dart';
import 'package:factoryflow/features/ap_inspection/ap_inspection_providers.dart';
import 'package:factoryflow/features/final_dispatch/final_dispatch_providers.dart';
import 'package:factoryflow/features/material_receive/material_receive_providers.dart';
import 'package:factoryflow/features/receive_faco/receive_faco_providers.dart';
import 'package:factoryflow/features/rtv/rtv_providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Database sqliteDatabase;
  late DatabaseService databaseService;
  late SyncService syncService;
  late StockLedgerService ledgerService;
  late AlertProducerService alertProducerService;

  setUp(() async {
    sqliteDatabase = sqlite3.openInMemory();
    databaseService = DatabaseService.forTesting(sqliteDatabase);
    await databaseService.setActiveWorkspaceId('factory-a');
    syncService = SyncService(
      databaseService,
      onlineCheck: () async => false,
    );
    ledgerService = StockLedgerService(databaseService, syncService);
    alertProducerService = AlertProducerService(databaseService);
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

  test('material receipt rolls back event ledger and queues together',
      () async {
    sqliteDatabase.execute('''
      CREATE TRIGGER fail_material_sync_queue
      BEFORE INSERT ON sync_queue
      WHEN NEW.table_name = 'material_receives'
      BEGIN
        SELECT RAISE(ABORT, 'forced material queue failure');
      END
    ''');
    final repository = MaterialReceiveRepository(
        databaseService, syncService, ledgerService, alertProducerService,);

    final result = await repository.save(
      partId: 'part-a',
      qty: 100,
      supplierId: 'supplier-a',
      createdBy: 'user-a',
      recordedAt: DateTime.utc(2026, 7, 30, 8),
    );

    expect(result.success, isFalse);
    expect(result.error, contains('No stock was changed'));
    expect(
      sqliteDatabase
          .select('SELECT COUNT(*) AS count FROM material_receives')
          .first['count'],
      0,
    );
    expect(
      sqliteDatabase
          .select('SELECT COUNT(*) AS count FROM stock_ledger')
          .first['count'],
      0,
    );
    expect(
      sqliteDatabase
          .select('SELECT COUNT(*) AS count FROM sync_queue')
          .first['count'],
      0,
    );
  });

  test('purchase order status is queued as a scoped update', () async {
    final repository = PurchaseOrderRepository(databaseService, syncService);
    final saved = await repository.save(
      partId: 'part-a',
      orderedQty: 100,
      supplierId: 'supplier-a',
      createdBy: 'user-a',
      recordedAt: DateTime.utc(2026, 7, 30, 8),
    );
    expect(saved.success, isTrue);

    final updated = await repository.updateStatus(
      saved.recordId!,
      'received',
    );
    expect(updated.success, isTrue);

    final queued = sqliteDatabase.select(
      'SELECT operation, payload FROM sync_queue '
      'WHERE table_name = ? AND record_id = ? '
      'ORDER BY id DESC LIMIT 1',
      ['purchase_orders', saved.recordId],
    );
    expect(queued.single['operation'], 'update');
    expect(queued.single['payload'], contains('"factory_id":"factory-a"'));
  });

  test('Faco receipts support partials and block cumulative over-receipt',
      () async {
    await seedStock(
      id: 'faco-seed',
      partId: 'part-a',
      stage: StockStage.atFaco,
      qty: 100,
    );
    await databaseService.insertRecord('dispatch_to_facos', {
      'id': 'dispatch-a',
      'factory_id': 'factory-a',
      'batch_number': 'BATCH-A',
      'part_id': 'part-a',
      'qty': 100,
      'date': '2026-07-30',
      'time': '08:00',
      'sync_status': 'synced',
    });
    final repository =
        ReceiveFacoRepository(databaseService, syncService, ledgerService);

    final first = await repository.save(
      batchNumber: 'BATCH-A',
      partId: 'part-a',
      qtyReceived: 60,
      dispatchRefId: 'dispatch-a',
      createdBy: 'user-a',
    );
    final tooMuch = await repository.save(
      batchNumber: 'BATCH-A',
      partId: 'part-a',
      qtyReceived: 50,
      dispatchRefId: 'dispatch-a',
      createdBy: 'user-a',
    );
    final finalReceipt = await repository.save(
      batchNumber: 'BATCH-A',
      partId: 'part-a',
      qtyReceived: 40,
      dispatchRefId: 'dispatch-a',
      createdBy: 'user-a',
    );

    expect(first.success, isTrue);
    expect(first.shortageFlag, isTrue);
    expect(tooMuch.success, isFalse);
    expect(tooMuch.error, contains('remaining dispatch quantity (40 PCS)'));
    expect(finalReceipt.success, isTrue);
    expect(finalReceipt.shortageFlag, isFalse);
    expect(
      await databaseService.getCurrentBalance('part-a', 'at_faco'),
      0,
    );
    expect(
      await databaseService.getCurrentBalance('part-a', 'pending_ap'),
      100,
    );
    expect(await repository.getPendingDispatches('part-a'), isEmpty);
    // Insert part so the JOIN in getPendingBatches resolves correctly.
    await databaseService.insertRecord('parts', {
      'id': 'part-a',
      'factory_id': 'factory-a',
      'code': 'A',
      'name': 'Part A',
      'active': 1,
    });
    final pendingAp = await ApInspectionRepository(
      databaseService,
      syncService,
      ledgerService,
    ).getPendingBatches();
    expect(pendingAp.single['batch_number'], 'BATCH-A');
    expect(pendingAp.single['balance'], 100);
  });

  test('Faco receipt requires its selected dispatch and original batch',
      () async {
    await databaseService.insertRecord('dispatch_to_facos', {
      'id': 'dispatch-linked',
      'factory_id': 'factory-a',
      'batch_number': 'BATCH-LINKED',
      'part_id': 'part-a',
      'qty': 10,
      'date': '2026-07-30',
      'time': '08:00',
      'sync_status': 'synced',
    });
    final repository =
        ReceiveFacoRepository(databaseService, syncService, ledgerService);

    final noDispatch = await repository.save(
      batchNumber: 'BATCH-LINKED',
      partId: 'part-a',
      qtyReceived: 1,
      createdBy: 'user-a',
    );
    final wrongBatch = await repository.save(
      batchNumber: 'BATCH-TYPED',
      partId: 'part-a',
      qtyReceived: 1,
      dispatchRefId: 'dispatch-linked',
      createdBy: 'user-a',
    );

    expect(noDispatch.success, isFalse);
    expect(noDispatch.error, contains('original Faco dispatch'));
    expect(wrongBatch.success, isFalse);
    expect(wrongBatch.error, contains('cannot be entered manually'));
  });

  test('AP inspection keeps RTV as stock and final reject as history only',
      () async {
    await databaseService.insertRecord('receive_from_facos', {
      'id': 'faco-receive-a',
      'factory_id': 'factory-a',
      'batch_number': 'BATCH-A',
      'part_id': 'part-a',
      'qty_received': 100,
      'date': '2026-07-30',
      'sync_status': 'synced',
    });
    await seedStock(
      id: 'pending-ap-seed',
      partId: 'part-a',
      stage: StockStage.pendingAp,
      qty: 100,
    );
    final repository =
        ApInspectionRepository(databaseService, syncService, ledgerService);

    final result = await repository.save(
      batchNumber: 'BATCH-A',
      partId: 'part-a',
      qtyChecked: 100,
      approvedQty: 70,
      rejectedQty: 20,
      rtvQty: 10,
      rejectReason: 'Uneven Coating',
      inspectorId: 'user-a',
    );

    expect(result.success, isTrue);
    expect(
      await databaseService.getCurrentBalance('part-a', 'pending_ap'),
      0,
    );
    expect(
      await databaseService.getCurrentBalance('part-a', 'approved_ap'),
      70,
    );
    expect(
      await databaseService.getCurrentBalance('part-a', 'ap_rejected'),
      0,
    );
    expect(
      await databaseService.getCurrentBalance('part-a', 'rtv_stock'),
      10,
    );
  });

  test('AP inspection rejects a batch that was not received from Faco',
      () async {
    await databaseService.insertRecord('receive_from_facos', {
      'id': 'faco-receive-linked',
      'factory_id': 'factory-a',
      'batch_number': 'BATCH-LINKED',
      'part_id': 'part-a',
      'qty_received': 100,
      'date': '2026-07-30',
      'sync_status': 'synced',
    });
    await seedStock(
      id: 'pending-ap-wrong-batch-seed',
      partId: 'part-a',
      stage: StockStage.pendingAp,
      qty: 100,
    );

    final result = await ApInspectionRepository(
      databaseService,
      syncService,
      ledgerService,
    ).save(
      batchNumber: 'BATCH-TYPED',
      partId: 'part-a',
      qtyChecked: 10,
      approvedQty: 10,
      rejectedQty: 0,
      rtvQty: 0,
      rejectReason: 'Uneven Coating',
      inspectorId: 'user-a',
    );

    expect(result.success, isFalse);
    expect(result.error, contains('pending AP batch stock'));
  });

  test('RTV assignment keeps vendor-outstanding stock and blocks reuse',
      () async {
    await databaseService.insertRecord('parts', {
      'id': 'part-a',
      'factory_id': 'factory-a',
      'code': 'A',
      'name': 'Part A',
      'active': 1,
    });
    await databaseService.insertRecord('vendors', {
      'id': 'vendor-a',
      'factory_id': 'factory-a',
      'name': 'Vendor A',
      'active': 1,
    });
    await databaseService.insertRecord('ap_inspections', {
      'id': 'ap-a',
      'factory_id': 'factory-a',
      'batch_number': 'BATCH-A',
      'date': '2026-07-30',
      'part_id': 'part-a',
      'qty_checked': 10,
      'approved_qty': 0,
      'rejected_qty': 10,
      'rtv_qty': 10,
      'sync_status': 'synced',
    });
    await seedStock(
      id: 'rtv-seed',
      partId: 'part-a',
      stage: StockStage.rtvStock,
      qty: 10,
    );
    final repository = RtvRepository(
        databaseService, syncService, ledgerService, alertProducerService,);

    final saved = await repository.save(
      batchNumber: 'BATCH-A',
      partId: 'part-a',
      rtvQty: 10,
      reason: 'Uneven Coating',
      vendorId: 'vendor-a',
      createdBy: 'user-a',
    );
    final duplicate = await repository.save(
      batchNumber: 'BATCH-A',
      partId: 'part-a',
      rtvQty: 1,
      reason: 'Uneven Coating',
      vendorId: 'vendor-a',
      createdBy: 'user-a',
    );

    expect(saved.success, isTrue);
    expect(duplicate.success, isFalse);
    expect(duplicate.error, contains('No AP-rejected RTV quantity'));
    expect(
      await databaseService.getCurrentBalance('part-a', 'rtv_stock'),
      10,
    );
    expect((await repository.getPendingReturns()).single['remaining_qty'], 10);
  });

  test('RTV partial return splits stock and exposes reject-again next cycle',
      () async {
    await databaseService.insertRecord('parts', {
      'id': 'part-a',
      'factory_id': 'factory-a',
      'code': 'A',
      'name': 'Part A',
      'active': 1,
    });
    await databaseService.insertRecord('vendors', {
      'id': 'vendor-a',
      'factory_id': 'factory-a',
      'name': 'Vendor A',
      'active': 1,
    });
    await databaseService.insertRecord('ap_inspections', {
      'id': 'ap-a',
      'factory_id': 'factory-a',
      'batch_number': 'BATCH-A',
      'date': '2026-07-30',
      'part_id': 'part-a',
      'qty_checked': 10,
      'approved_qty': 0,
      'rejected_qty': 10,
      'rtv_qty': 10,
      'sync_status': 'synced',
    });
    await seedStock(
      id: 'rtv-seed',
      partId: 'part-a',
      stage: StockStage.rtvStock,
      qty: 10,
    );
    final repository = RtvRepository(
        databaseService, syncService, ledgerService, alertProducerService,);
    final sent = await repository.save(
      batchNumber: 'BATCH-A',
      partId: 'part-a',
      rtvQty: 10,
      reason: 'Uneven Coating',
      vendorId: 'vendor-a',
      createdBy: 'user-a',
    );

    final returned = await repository.saveReinspection(
      rtvId: sent.recordId!,
      quantityReceived: 6,
      okQty: 4,
      rejectAgainQty: 2,
      createdBy: 'user-a',
    );

    expect(returned.success, isTrue);
    expect(returned.status, 'partially_received');
    expect(
      await databaseService.getCurrentBalance('part-a', 'rtv_stock'),
      6,
    );
    expect(
      await databaseService.getCurrentBalance('part-a', 'approved_ap'),
      4,
    );
    expect((await repository.getPendingReturns()).single['remaining_qty'], 4);
    expect(
      (await repository.getCandidates()).single['available_qty'],
      2,
    );
  });

  test('third RTV rejection escalates and Admin resolution is idempotent',
      () async {
    await databaseService.insertRecord('parts', {
      'id': 'part-a',
      'factory_id': 'factory-a',
      'code': 'A',
      'name': 'Part A',
      'active': 1,
    });
    await databaseService.insertRecord('vendors', {
      'id': 'vendor-a',
      'factory_id': 'factory-a',
      'name': 'Vendor A',
      'active': 1,
    });
    await databaseService.insertRecord('rtvs', {
      'id': 'rtv-cycle-3',
      'factory_id': 'factory-a',
      'batch_number': 'BATCH-A',
      'cycle_number': 3,
      'date': '2026-07-30',
      'part_id': 'part-a',
      'rtv_qty': 5,
      'reason_id': 'Uneven Coating',
      'vendor_id': 'vendor-a',
      'status': 'sent',
      'sync_status': 'synced',
    });
    await seedStock(
      id: 'rtv-seed',
      partId: 'part-a',
      stage: StockStage.rtvStock,
      qty: 5,
    );
    final repository = RtvRepository(
        databaseService, syncService, ledgerService, alertProducerService,);

    final returned = await repository.saveReinspection(
      rtvId: 'rtv-cycle-3',
      quantityReceived: 5,
      okQty: 0,
      rejectAgainQty: 5,
      createdBy: 'quality-a',
    );
    final resolved = await repository.resolveEscalation(
      rtvId: 'rtv-cycle-3',
      action: 'force_dispatched',
      reason: 'Engineering deviation approved',
      resolvedBy: 'admin-a',
      role: UserRole.owner,
    );
    final duplicate = await repository.resolveEscalation(
      rtvId: 'rtv-cycle-3',
      action: 'force_dispatched',
      reason: 'Retry',
      resolvedBy: 'admin-a',
      role: UserRole.owner,
    );

    expect(returned.success, isTrue);
    expect(returned.isEscalated, isTrue);
    expect(resolved.success, isTrue);
    expect(duplicate.success, isFalse);
    expect(
      await databaseService.getCurrentBalance('part-a', 'rtv_stock'),
      0,
    );
    expect(
      await databaseService.getCurrentBalance('part-a', 'approved_ap'),
      5,
    );
    expect(
      sqliteDatabase
          .select('SELECT COUNT(*) AS count FROM audit_log')
          .single['count'],
      1,
    );
  });

  test('final dispatch aggregates duplicate part rows before writing',
      () async {
    await seedStock(
      id: 'approved-seed',
      partId: 'part-a',
      stage: StockStage.approvedAp,
      qty: 100,
    );
    await databaseService.insertRecord('ap_inspections', {
      'id': 'ap-approved-a',
      'factory_id': 'factory-a',
      'batch_number': 'BATCH-A',
      'date': '2026-07-30',
      'part_id': 'part-a',
      'qty_checked': 100,
      'approved_qty': 100,
      'rejected_qty': 0,
      'rtv_qty': 0,
      'sync_status': 'synced',
    });
    final repository = FinalDispatchRepository(
        databaseService, syncService, ledgerService, alertProducerService,);

    final blocked = await repository.saveDispatchSession(
      customerId: 'customer-a',
      items: const [
        DispatchItemInput(
          batchNumber: 'BATCH-A',
          partId: 'part-a',
          partCode: 'A',
          qty: 60,
        ),
        DispatchItemInput(
          batchNumber: 'BATCH-A',
          partId: 'part-a',
          partCode: 'A',
          qty: 50,
        ),
      ],
      createdBy: 'user-a',
    );

    expect(blocked.success, isFalse);
    expect(blocked.error, contains('exceeds batch AP OK stock'));
    expect(
      sqliteDatabase
          .select('SELECT COUNT(*) AS count FROM dispatch_sessions')
          .first['count'],
      0,
    );
    expect(
      await databaseService.getCurrentBalance('part-a', 'approved_ap'),
      100,
    );

    final saved = await repository.saveDispatchSession(
      customerId: 'customer-a',
      items: const [
        DispatchItemInput(
          batchNumber: 'BATCH-A',
          partId: 'part-a',
          partCode: 'A',
          qty: 60,
        ),
        DispatchItemInput(
          batchNumber: 'BATCH-A',
          partId: 'part-a',
          partCode: 'A',
          qty: 40,
        ),
      ],
      createdBy: 'user-a',
      recordedAt: DateTime.utc(2026, 7, 30, 10),
    );

    expect(saved.success, isTrue);
    expect(
      await databaseService.getCurrentBalance('part-a', 'approved_ap'),
      0,
    );
    expect(
      sqliteDatabase
          .select('SELECT COUNT(*) AS count FROM dispatch_sessions')
          .first['count'],
      1,
    );
    expect(
      sqliteDatabase
          .select('SELECT COUNT(*) AS count FROM dispatch_items')
          .first['count'],
      2,
    );
    expect(
      sqliteDatabase
          .select('SELECT DISTINCT batch_number FROM dispatch_items')
          .single['batch_number'],
      'BATCH-A',
    );
  });
}
