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
    await databaseService.setActiveWorkspaceId('factory-1');
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

  test('Daily register correctly aggregates work order sent, physical received, and computes running balance matching paper book', () async {
    // 1. Insert Master Data: Parts & Vendors
    await databaseService.insertRecord('parts', {
      'id': 'part-v21',
      'factory_id': 'factory-1',
      'name': 'Product V21',
      'code': 'V21',
      'active': 1,
    });
    await databaseService.insertRecord('vendors', {
      'id': 'vendor-apex',
      'factory_id': 'factory-1',
      'name': 'Apex Machining',
      'active': 1,
    });

    // 2. Set DateRange to September 2026
    final fromDate = DateTime(2026, 9, 1);
    final toDate = DateTime(2026, 9, 14);
    container.read(reportDateRangeProvider.notifier).set(DateRange(fromDate, toDate));
    container.read(vendorMovementPartFilterProvider.notifier).set('part-v21');

    // 3. Insert dispatches and receipts matching the user's manual photo:
    // 3-Sep-26: Work Order Sent = 1000, Received = 0
    await databaseService.insertRecord('dispatch_to_facos', {
      'id': 'd-1',
      'factory_id': 'factory-1',
      'date': '2026-09-03',
      'time': '10:00:00',
      'part_id': 'part-v21',
      'vendor_id': 'vendor-apex',
      'qty': 1000,
      'challan_number': 'CH-001',
      'batch_number': 'B-1',
      'remarks': 'Day 3 batch',
    });

    // 4-Sep-26: Work Order Sent = 1000, Received = 1000
    await databaseService.insertRecord('dispatch_to_facos', {
      'id': 'd-2',
      'factory_id': 'factory-1',
      'date': '2026-09-04',
      'time': '11:00:00',
      'part_id': 'part-v21',
      'vendor_id': 'vendor-apex',
      'qty': 1000,
      'challan_number': 'CH-002',
      'batch_number': 'B-2',
      'remarks': 'Day 4 batch',
    });
    await databaseService.insertRecord('receive_from_facos', {
      'id': 'r-1',
      'factory_id': 'factory-1',
      'date': '2026-09-04',
      'part_id': 'part-v21',
      'qty_received': 1000,
      'dispatch_ref_id': 'd-1',
      'supplier_challan': 'SUP-001',
      'batch_number': 'B-1',
      'remarks': 'Received full',
    });

    // 11-Sep-26: Work Order Sent = 0, Received = 500
    await databaseService.insertRecord('receive_from_facos', {
      'id': 'r-2',
      'factory_id': 'factory-1',
      'date': '2026-09-11',
      'part_id': 'part-v21',
      'qty_received': 500,
      'dispatch_ref_id': 'd-2',
      'supplier_challan': 'SUP-002',
      'batch_number': 'B-2',
      'remarks': 'Partial return',
    });

    // 14-Sep-26: Work Order Sent = 1000, Received = 500
    await databaseService.insertRecord('dispatch_to_facos', {
      'id': 'd-3',
      'factory_id': 'factory-1',
      'date': '2026-09-14',
      'time': '09:30:00',
      'part_id': 'part-v21',
      'vendor_id': 'vendor-apex',
      'qty': 1000,
      'challan_number': 'CH-003',
      'batch_number': 'B-3',
    });
    await databaseService.insertRecord('receive_from_facos', {
      'id': 'r-3',
      'factory_id': 'factory-1',
      'date': '2026-09-14',
      'part_id': 'part-v21',
      'qty_received': 500,
      'dispatch_ref_id': 'd-2',
      'supplier_challan': 'SUP-003',
      'batch_number': 'B-2',
    });

    // Fetch vendor movement data
    final data = await container.read(vendorMovementProvider.future);

    // Totals
    expect(data.totalDispatched, 3000.0); // 1000 + 1000 + 1000
    expect(data.totalReceived, 2000.0);   // 1000 + 500 + 500
    expect(data.netPending, 1000.0);      // 3000 - 2000 = 1000 pending at vendor

    // Check Daily Movements (latest day first in dailyMovements)
    final sep14 = data.dailyMovements.firstWhere((d) => d.rawDate == '2026-09-14');
    expect(sep14.workOrderQty, 1000.0);
    expect(sep14.physicalQty, 500.0);
    expect(sep14.dayDifference, 500.0);
    expect(sep14.runningBalance, 1000.0); // Running balance on 14-Sep matches user's notebook (-1000 pending)
    expect(sep14.dispatches, hasLength(1));
    expect(sep14.receipts, hasLength(1));

    final sep11 = data.dailyMovements.firstWhere((d) => d.rawDate == '2026-09-11');
    expect(sep11.workOrderQty, 0.0);
    expect(sep11.physicalQty, 500.0);
    expect(sep11.dayDifference, -500.0);
    expect(sep11.runningBalance, 500.0); // Running balance on 11-Sep matches user's notebook (-500 pending)

    final sep04 = data.dailyMovements.firstWhere((d) => d.rawDate == '2026-09-04');
    expect(sep04.workOrderQty, 1000.0);
    expect(sep04.physicalQty, 1000.0);
    expect(sep04.runningBalance, 1000.0); // Running balance on 4-Sep matches user's notebook (-1000 pending)

    final sep03 = data.dailyMovements.firstWhere((d) => d.rawDate == '2026-09-03');
    expect(sep03.workOrderQty, 1000.0);
    expect(sep03.physicalQty, 0.0);
    expect(sep03.runningBalance, 1000.0); // Running balance on 3-Sep matches user's notebook (-1000 pending)

    // Check empty day (e.g. 2026-09-01)
    final sep01 = data.dailyMovements.firstWhere((d) => d.rawDate == '2026-09-01');
    expect(sep01.hasMovement, false);
    expect(sep01.workOrderQty, 0.0);
    expect(sep01.physicalQty, 0.0);
  });
}
