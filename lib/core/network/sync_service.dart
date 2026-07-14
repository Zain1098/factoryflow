import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../constants/app_constants.dart';
import '../database/database_service.dart';
import '../services/notification_service.dart';

final syncServiceProvider = Provider<SyncService>((ref) {
  return SyncService(ref.watch(databaseServiceProvider));
});

/// Polls pending sync count every 30 s — only when provider is alive.
final pendingSyncCountProvider = StreamProvider<int>((ref) {
  final db = ref.watch(databaseServiceProvider);
  return Stream.periodic(const Duration(seconds: 15), (_) => 0)
      .asyncExpand((_) => Stream.fromFuture(db.countPendingSync()))
      .asBroadcastStream();
});

/// Emits current connectivity immediately, then streams changes.
final connectivityProvider =
    StreamProvider<List<ConnectivityResult>>((ref) async* {
  final connectivity = Connectivity();
  yield await connectivity.checkConnectivity();
  yield* connectivity.onConnectivityChanged;
});

/// Simple bool: true = at least one non-none interface available.
final isOnlineProvider = Provider<bool>((ref) {
  final conn = ref.watch(connectivityProvider).value;
  if (conn == null) return true; // assume online until proven otherwise
  return !conn.contains(ConnectivityResult.none);
});

/// Columns that are GENERATED in Supabase and must be stripped before upsert.
const _generatedColumns = {'good_qty'};

/// Offline-first sync engine with exponential backoff and notification alerts.
class SyncService {
  SyncService(this._db);

  final DatabaseService _db;
  Timer? _syncTimer;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  bool _isSyncing = false;

  void startPeriodicSync() {
    if (_syncTimer != null) return;
    _syncTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => syncPending(),
    );
    _connectivitySubscription =
        Connectivity().onConnectivityChanged.listen((results) {
      if (!results.contains(ConnectivityResult.none)) {
        unawaited(syncPending());
      }
    });
    unawaited(syncPending());
  }

  void stopPeriodicSync() {
    _syncTimer?.cancel();
    _syncTimer = null;
    _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
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
        final tableName = item['table_name'] as String;
        final operation = item['operation'] as String;
        final recordId = item['record_id'] as String;

        try {
          var payload =
              jsonDecode(item['payload'] as String) as Map<String, dynamic>;

          // Strip generated columns so Supabase doesn't reject the upsert
          payload = Map.from(payload)
            ..removeWhere((k, _) => _generatedColumns.contains(k))
            ..remove('sync_status');

          if (operation == 'insert' || operation == 'update') {
            await client
                .from(tableName)
                .upsert(payload)
                .timeout(const Duration(seconds: 12));
          } else if (operation == 'delete') {
            await client
                .from(tableName)
                .delete()
                .eq('id', recordId)
                .timeout(const Duration(seconds: 12));
          } else if (operation == 'ledger') {
            final result = await client.rpc(
              'write_stock_ledger_entry',
              params: {
                'p_id': payload['id'],
                'p_factory_id': payload['factory_id'],
                'p_part_id': payload['part_id'],
                'p_stage': payload['stage'],
                'p_direction': payload['direction'],
                'p_qty': payload['qty'],
                'p_ref_table': payload['ref_table'],
                'p_ref_id': payload['ref_id'],
              },
            ).timeout(const Duration(seconds: 12));
            if (result is Map && result['success'] == false) {
              await _db.markRecordConflict(tableName, recordId);
              await _db.updateSyncStatus(id, 'conflict', attempts: attempts);
              await _logSyncHistory(
                tableName: tableName,
                recordId: recordId,
                operation: operation,
                status: 'conflict',
                errorMessage:
                    result['error']?.toString() ?? 'RPC conflict detected',
              );
              conflicts++;
              continue;
            }
          }

          await _db.markRecordSynced(tableName, recordId);
          await _db.updateSyncStatus(id, 'synced', attempts: attempts);
          await _logSyncHistory(
            tableName: tableName,
            recordId: recordId,
            operation: operation,
            status: 'synced',
          );
          synced++;
        } catch (e) {
          final errorStr = _sanitizeSyncError(e);
          if (attempts >= AppConstants.syncRetryMaxAttempts) {
            await _db.updateSyncStatus(id, 'failed', attempts: attempts);
            await _logSyncHistory(
              tableName: tableName,
              recordId: recordId,
              operation: operation,
              status: 'failed',
              errorMessage: errorStr,
            );
            failed++;
          } else {
            final retryAt = DateTime.now().add(backoffDelay(attempts));
            await _db.updateSyncStatus(
              id,
              'pending',
              attempts: attempts,
              nextRetryAt: retryAt.toIso8601String(),
            );
            await _logSyncHistory(
              tableName: tableName,
              recordId: recordId,
              operation: operation,
              status: 'retry',
              errorMessage: 'Attempt $attempts: $errorStr',
            );
          }
        }
      }

      if (failed > 0) {
        await NotificationService.instance.showSyncFailure(failed);
      }
    } catch (e) {
      // Only swallow if Supabase is not configured at all
      if (!e.toString().contains('not initialized') &&
          !e.toString().contains('No Supabase')) {
        rethrow;
      }
    } finally {
      _isSyncing = false;
    }

    return SyncResult(synced: synced, failed: failed, conflicts: conflicts);
  }

  Future<void> _logSyncHistory({
    required String tableName,
    required String recordId,
    required String operation,
    required String status,
    String? errorMessage,
  }) async {
    try {
      await _db.insertRecord('sync_history_logs', {
        'id': const Uuid().v4(),
        'table_name': tableName,
        'record_id': recordId,
        'operation': operation,
        'status': status,
        'error_message': errorMessage ?? '',
        'created_at': DateTime.now().toIso8601String(),
      });
    } catch (_) {
      // Prevent failure in writing sync history from breaking sync loop
    }
  }

  String _sanitizeSyncError(Object error) {
    final message = error
        .toString()
        .replaceAll(
          RegExp(
            r'(apikey|authorization|bearer)\s*[:=]\s*\S+',
            caseSensitive: false,
          ),
          '[redacted]',
        )
        .replaceAll(RegExp(r'eyJ[a-zA-Z0-9_.-]+'), '[redacted]');
    return message.length <= 500 ? message : '${message.substring(0, 500)}…';
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

  // Exponential backoff delay (not used for timer but available for manual retry)
  Duration backoffDelay(int attempt) {
    final seconds =
        AppConstants.syncRetryBaseDelay.inSeconds * pow(2, attempt - 1);
    return Duration(seconds: seconds.toInt().clamp(2, 300));
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
