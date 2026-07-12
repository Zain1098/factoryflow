import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../constants/app_constants.dart';
import '../database/database_service.dart';

final syncServiceProvider = Provider<SyncService>((ref) {
  return SyncService(ref.watch(databaseServiceProvider));
});

/// Periodically polls pending sync count — properly cancellable stream
final pendingSyncCountProvider = StreamProvider<int>((ref) {
  final db = ref.watch(databaseServiceProvider);
  // Stream.periodic is properly cancelled when provider is disposed
  return Stream.periodic(const Duration(seconds: 5), (_) => 0)
      .asyncExpand((_) => Stream.fromFuture(db.countPendingSync()))
      .asBroadcastStream();
});

final connectivityProvider = StreamProvider<List<ConnectivityResult>>((ref) {
  return Connectivity().onConnectivityChanged;
});

/// Offline-first sync engine per PRD Ch. 7.6 and Ch. 8.
class SyncService {
  SyncService(this._db);

  final DatabaseService _db;
  Timer? _syncTimer;
  bool _isSyncing = false;

  void startPeriodicSync() {
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(const Duration(seconds: 30), (_) => syncPending());
  }

  void stopPeriodicSync() {
    _syncTimer?.cancel();
  }

  Future<bool> isOnline() async {
    final result = await Connectivity().checkConnectivity();
    return !result.contains(ConnectivityResult.none);
  }

  Future<SyncResult> syncPending() async {
    if (_isSyncing) return const SyncResult(skipped: true);
    if (!await isOnline()) return const SyncResult(offline: true);

    _isSyncing = true;
    int synced = 0;
    int failed = 0;
    int conflicts = 0;

    try {
      final client = Supabase.instance.client;
      final items = await _db.getPendingSyncItems();

      for (final item in items) {
        final id = item['id'] as int;
        final attempts = (item['attempts'] as int? ?? 0) + 1;

        try {
          final tableName = item['table_name'] as String;
          final operation = item['operation'] as String;
          final payload = jsonDecode(item['payload'] as String) as Map<String, dynamic>;

          if (operation == 'insert') {
            await client.from(tableName).upsert(payload);
          } else if (operation == 'ledger') {
            final result = await client.rpc('write_stock_ledger_entry', params: payload);
            if (result is Map && result['success'] == false) {
              await _db.markRecordConflict(tableName, item['record_id'] as String);
              await _db.updateSyncStatus(id, 'conflict', attempts: attempts);
              conflicts++;
              continue;
            }
          }

          await _db.markRecordSynced(tableName, item['record_id'] as String);
          await _db.updateSyncStatus(id, 'synced', attempts: attempts);
          synced++;
        } catch (e) {
          if (attempts >= AppConstants.syncRetryMaxAttempts) {
            await _db.updateSyncStatus(id, 'failed', attempts: attempts);
            failed++;
          } else {
            await _db.updateSyncStatus(id, 'pending', attempts: attempts);
          }
        }
      }
    } catch (_) {
      // Supabase not configured — keep items pending
    } finally {
      _isSyncing = false;
    }

    return SyncResult(synced: synced, failed: failed, conflicts: conflicts);
  }

  Future<void> queueInsert({
    required String tableName,
    required String recordId,
    required Map<String, dynamic> payload,
  }) async {
    await _db.enqueueSync(
      tableName: tableName,
      recordId: recordId,
      operation: 'insert',
      payload: payload,
    );
    if (await isOnline()) {
      unawaited(syncPending());
    }
  }
}

class SyncResult {
  const SyncResult({
    this.synced = 0,
    this.failed = 0,
    this.conflicts = 0,
    this.offline = false,
    this.skipped = false,
  });

  final int synced;
  final int failed;
  final int conflicts;
  final bool offline;
  final bool skipped;
}
