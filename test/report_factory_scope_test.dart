import 'package:factoryflow/core/database/database_service_native.dart';
import 'package:factoryflow/features/reports/report_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Database sqliteDatabase;
  late DatabaseService databaseService;
  late ProviderContainer container;

  setUp(() async {
    sqliteDatabase = sqlite3.openInMemory();
    databaseService = DatabaseService.forTesting(sqliteDatabase);
    await databaseService.setActiveWorkspaceId('factory-a');
    container = ProviderContainer(
      overrides: [
        databaseServiceProvider.overrideWithValue(databaseService),
      ],
    );
  });

  tearDown(() {
    container.dispose();
    sqliteDatabase.close();
  });

  test('production and live-stock reports stay in the active factory',
      () async {
    final today = DateTime.now();
    final date =
        '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
    await databaseService.insertRecord('parts', {
      'id': 'part-a',
      'factory_id': 'factory-a',
      'code': 'A',
      'name': 'Factory A Part',
      'active': 1,
    });
    await databaseService.insertRecord('parts', {
      'id': 'part-b',
      'factory_id': 'factory-b',
      'code': 'B',
      'name': 'Factory B Part',
      'active': 1,
    });
    await databaseService.insertRecord('productions', {
      'id': 'prod-a',
      'factory_id': 'factory-a',
      'date': date,
      'part_id': 'part-a',
      'production_qty': 10,
      'bp_reject_qty': 1,
      'good_qty': 9,
    });
    await databaseService.insertRecord('productions', {
      'id': 'prod-b',
      'factory_id': 'factory-b',
      'date': date,
      'part_id': 'part-b',
      'production_qty': 999,
      'bp_reject_qty': 0,
      'good_qty': 999,
    });
    await databaseService.insertRecord('stock_ledger', {
      'id': 'stock-a',
      'factory_id': 'factory-a',
      'part_id': 'part-a',
      'stage': 'raw_material',
      'direction': 'IN',
      'qty': 25,
      'running_balance': 25,
      'created_at': '${date}T08:00:00',
    });
    await databaseService.insertRecord('stock_ledger', {
      'id': 'stock-b',
      'factory_id': 'factory-b',
      'part_id': 'part-b',
      'stage': 'raw_material',
      'direction': 'IN',
      'qty': 500,
      'running_balance': 500,
      'created_at': '${date}T08:00:00',
    });

    final production = await container.read(
      dailyProductionReportProvider.future,
    );
    final stock = await container.read(liveStockReportProvider.future);

    expect(production, hasLength(1));
    expect(production.single.totalProduction, 10);
    expect(stock, hasLength(1));
    expect(stock.single.partCode, 'A');
    expect(stock.single.rawMaterial, 25);
  });

  test('dispatch report reads normalized sessions and items by factory',
      () async {
    final today = DateTime.now();
    final date =
        '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
    for (final factory in ['a', 'b']) {
      await databaseService.insertRecord('parts', {
        'id': 'part-$factory',
        'factory_id': 'factory-$factory',
        'code': factory.toUpperCase(),
        'name': 'Part $factory',
        'active': 1,
      });
      await databaseService.insertRecord('customers', {
        'id': 'customer-$factory',
        'factory_id': 'factory-$factory',
        'name': 'Customer $factory',
        'active': 1,
      });
      await databaseService.insertRecord('dispatch_sessions', {
        'id': 'session-$factory',
        'factory_id': 'factory-$factory',
        'date': date,
        'time': '10:00',
        'customer_id': 'customer-$factory',
        'challan_number': 'DC-$factory',
      });
      await databaseService.insertRecord('dispatch_items', {
        'id': 'item-$factory',
        'session_id': 'session-$factory',
        'factory_id': 'factory-$factory',
        'part_id': 'part-$factory',
        'dispatch_qty': factory == 'a' ? 20 : 900,
      });
    }

    final rows = await container.read(dispatchReportProvider.future);

    expect(rows, hasLength(1));
    expect(rows.single.partName, 'Part a');
    expect(rows.single.dispatchQty, 20);
    expect(rows.single.challanNumber, 'DC-a');
  });

  test('global search is factory scoped and uses valid challan columns',
      () async {
    await databaseService.insertRecord('productions', {
      'id': 'prod-a',
      'factory_id': 'factory-a',
      'batch_number': 'SHARED-BATCH',
      'date': '2026-07-30',
      'part_id': 'part-a',
    });
    await databaseService.insertRecord('productions', {
      'id': 'prod-b',
      'factory_id': 'factory-b',
      'batch_number': 'SHARED-BATCH',
      'date': '2026-07-30',
      'part_id': 'part-b',
    });
    await databaseService.insertRecord('dispatch_to_facos', {
      'id': 'dispatch-a',
      'factory_id': 'factory-a',
      'batch_number': 'BATCH-A',
      'date': '2026-07-30',
      'part_id': 'part-a',
      'challan_number': 'FACO-101',
    });
    await databaseService.insertRecord('receive_from_facos', {
      'id': 'receive-a',
      'factory_id': 'factory-a',
      'batch_number': 'BATCH-A',
      'date': '2026-07-30',
      'part_id': 'part-a',
      'supplier_challan': 'SUP-202',
    });

    final batches = await databaseService.searchRecords(
      batchNumber: 'SHARED-BATCH',
    );
    final faco = await databaseService.searchRecords(
      challanNumber: 'FACO-101',
    );
    final supplier = await databaseService.searchRecords(
      challanNumber: 'SUP-202',
    );

    expect(batches, hasLength(1));
    expect(batches.single['factory_id'], 'factory-a');
    expect(faco, hasLength(1));
    expect(faco.single['_table'], 'dispatch_to_facos');
    expect(supplier, hasLength(1));
    expect(supplier.single['_table'], 'receive_from_facos');
  });
}
