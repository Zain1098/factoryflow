import 'dart:convert';

import 'package:factoryflow/core/database/database_service_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Database sqliteDatabase;
  late DatabaseService databaseService;

  setUp(() {
    sqliteDatabase = sqlite3.openInMemory();
    databaseService = DatabaseService.forTesting(sqliteDatabase);
  });

  tearDown(() {
    sqliteDatabase.close();
  });

  test('settings erase only removes the selected company records', () async {
    await databaseService.insertRecord('productions', {
      'id': 'production-a',
      'factory_id': 'factory-a',
      'batch_number': 'A-001',
    });
    await databaseService.insertRecord('productions', {
      'id': 'production-b',
      'factory_id': 'factory-b',
      'batch_number': 'B-001',
    });

    await databaseService.backupTable(
      table: 'productions',
      userId: 'admin-a',
      factoryId: 'factory-a',
      reason: 'test_erase',
    );
    databaseService.eraseTableForFactory('productions', 'factory-a');

    final remaining = sqliteDatabase.select(
      'SELECT id, factory_id FROM productions ORDER BY id',
    );
    expect(remaining, hasLength(1));
    expect(remaining.single['id'], 'production-b');

    final backups = sqliteDatabase.select(
      'SELECT source_record_id, factory_id FROM backup_records',
    );
    expect(backups, hasLength(1));
    expect(backups.single['source_record_id'], 'production-a');
    expect(backups.single['factory_id'], 'factory-a');
  });

  test('settings erase cancels only matching company sync mutations', () async {
    for (final factoryId in ['factory-a', 'factory-b']) {
      await databaseService.enqueueSync(
        tableName: 'productions',
        recordId: 'production-$factoryId',
        operation: 'insert',
        payload: {
          'id': 'production-$factoryId',
          'factory_id': factoryId,
        },
      );
    }

    databaseService.eraseQueuedChangesForFactory(
      'factory-a',
      ['productions'],
    );

    final queue = sqliteDatabase.select(
      'SELECT payload FROM sync_queue ORDER BY id',
    );
    expect(queue, hasLength(1));
    final payload =
        jsonDecode(queue.single['payload'] as String) as Map<String, dynamic>;
    expect(payload['factory_id'], 'factory-b');
  });
}
