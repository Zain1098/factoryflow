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

/// RTV rows are immutable through the Data API. State changes use narrow
/// server RPCs so batch, quantity, cycle, part, vendor, and factory cannot be
/// changed by a generic update payload.
String rtvUpdateRpcName(String status) {
  return status == 'scrapped' || status == 'force_dispatched'
      ? 'resolve_rtv_escalation'
      : 'refresh_rtv_status';
}

/// Offline-first sync engine with exponential backoff and notification alerts.
class SyncService {
  SyncService(
    this._db, {
    Future<bool> Function()? onlineCheck,
  }) : _onlineCheck = onlineCheck;

  final DatabaseService _db;
  final Future<bool> Function()? _onlineCheck;
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
    final onlineCheck = _onlineCheck;
    if (onlineCheck != null) return onlineCheck();
    try {
      final result = await Connectivity()
          .checkConnectivity()
          .timeout(const Duration(seconds: 3));
      return !result.contains(ConnectivityResult.none);
    } catch (_) {
      // A missing/hung platform channel must never block a local transaction.
      // The reconnect listener or next periodic attempt will retry later.
      return false;
    }
  }

  Future<bool> isSupabaseReady() async {
    try {
      final client = Supabase.instance.client;
      // Also check if auth session exists or client is active
      return client.auth.currentSession != null ||
          client.auth.currentUser != null;
    } catch (_) {
      return false;
    }
  }

  Future<SyncResult> syncPending() async {
    if (_isSyncing) return const SyncResult(skipped: true);
    if (!await isOnline()) return const SyncResult(offline: true);
    if (!await isSupabaseReady()) return const SyncResult(skipped: true);

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

          if (tableName == 'productions' && operation == 'insert') {
            final batchNum = payload['batch_number'] as String?;
            final machineId = payload['machine_id'] as String?;
            if (batchNum != null && machineId != null) {
              final cloudExisting = await client
                  .from('productions')
                  .select('id')
                  .eq('batch_number', batchNum)
                  .eq('machine_id', machineId)
                  .limit(1)
                  .maybeSingle()
                  .timeout(const Duration(seconds: 10));

              if (cloudExisting != null && cloudExisting['id'] != recordId) {
                // Duplicate completed stage detected in cloud from another device!
                await _db.markRecordConflict(tableName, recordId);
                await _db.updateSyncStatus(id, 'conflict', attempts: attempts);
                await _db.writeAuditLog(
                  id: const Uuid().v4(),
                  tableName: 'productions',
                  recordId: recordId,
                  action: 'DUPLICATE_STAGE_BLOCKED',
                  changedBy: payload['created_by'] as String? ?? 'unknown',
                  newValue: {
                    'batch_number': batchNum,
                    'machine_id': machineId,
                    'user_id': payload['created_by'],
                    'device_id': 'mobile',
                    'reason':
                        'Duplicate stage detected in cloud from another device.',
                    'timestamp': DateTime.now().toIso8601String(),
                  },
                );
                await _logSyncHistory(
                  tableName: tableName,
                  recordId: recordId,
                  operation: operation,
                  status: 'conflict',
                  errorMessage:
                      'Duplicate stage for batch $batchNum and machine $machineId blocked.',
                );
                conflicts++;
                continue;
              }
            }
          }

          if (operation == 'insert') {
            await client
                .from(tableName)
                .upsert(payload)
                .timeout(const Duration(seconds: 12));
          } else if (operation == 'update') {
            final factoryId = payload['factory_id']?.toString() ?? '';
            if (tableName == 'rtvs') {
              final status = payload['status']?.toString() ?? '';
              final rpcName = rtvUpdateRpcName(status);
              final result = rpcName == 'resolve_rtv_escalation'
                  ? await client.rpc(
                      rpcName,
                      params: {
                        'p_rtv_id': recordId,
                        'p_factory_id': factoryId,
                        'p_action': status,
                        'p_reason': payload['remarks']?.toString() ?? '',
                      },
                    ).timeout(const Duration(seconds: 12))
                  : await client.rpc(
                      rpcName,
                      params: {
                        'p_rtv_id': recordId,
                        'p_factory_id': factoryId,
                      },
                    ).timeout(const Duration(seconds: 12));
              if (result is Map && result['success'] == false) {
                throw StateError(
                  result['error']?.toString() ??
                      'RTV state transition was rejected.',
                );
              }
            } else {
              final updatePayload = Map<String, dynamic>.from(payload)
                ..remove('id')
                ..remove('factory_id');
              await client
                  .from(tableName)
                  .update(updatePayload)
                  .eq('id', recordId)
                  .eq('factory_id', factoryId)
                  .timeout(const Duration(seconds: 12));
            }
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
              await _db.recordSyncConflict(
                entityType: tableName,
                entityId: recordId,
                localPayload: payload,
                serverReason: result['error']?.toString() ?? 'RPC conflict detected',
                suggestedAction: 'review_stock_balance',
              );
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
          } else if (operation == 'production_post') {
            final result = await client.rpc(
              'post_production_stage',
              params: {'p_command': payload},
            ).timeout(const Duration(seconds: 15));
            if (result is Map && result['success'] == false) {
              await _db.markProductionPostingConflict(recordId);
              await _db.updateSyncStatus(id, 'conflict', attempts: attempts);
              await _db.recordSyncConflict(
                entityType: 'productions',
                entityId: recordId,
                localPayload: payload,
                serverReason: result['error']?.toString() ?? 'RPC conflict detected',
                suggestedAction: 'review_production_stock',
              );
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

          if (operation == 'production_post') {
            await _db.markProductionPostingSynced(recordId);
          } else {
            await _db.markRecordSynced(tableName, recordId);
          }
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

      if (failed > 0 && await isSupabaseReady()) {
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
    bool triggerSync = true,
  }) async {
    // Guard: don't queue if workspace not set (would fail RLS on Supabase)
    final factoryId = payload['factory_id']?.toString() ?? '';
    if (factoryId.isEmpty) return;
    await _db.enqueueSync(
      tableName: tableName,
      recordId: recordId,
      operation: 'insert',
      payload: payload,
    );
    if (triggerSync) await schedulePendingSync();
  }

  Future<void> queueUpdate({
    required String tableName,
    required String recordId,
    required Map<String, dynamic> payload,
    bool triggerSync = true,
  }) async {
    final factoryId = payload['factory_id']?.toString() ?? '';
    if (factoryId.isEmpty) return;
    await _db.enqueueSync(
      tableName: tableName,
      recordId: recordId,
      operation: 'update',
      payload: payload,
    );
    if (triggerSync) await schedulePendingSync();
  }

  /// Queues a ledger mutation for the server-side atomic stock RPC.
  Future<void> queueLedger({
    required String recordId,
    required Map<String, dynamic> payload,
    bool triggerSync = true,
  }) async {
    final factoryId = payload['factory_id']?.toString() ?? '';
    if (factoryId.isEmpty) return;
    await _db.enqueueSync(
      tableName: 'stock_ledger',
      recordId: recordId,
      operation: 'ledger',
      payload: payload,
    );
    if (triggerSync) await schedulePendingSync();
  }

  /// Queues one atomic server command containing a production event and every
  /// stock-ledger movement caused by that event.
  Future<void> queueProductionPost({
    required String recordId,
    required Map<String, dynamic> payload,
    bool triggerSync = true,
  }) async {
    final factoryId = payload['factory_id']?.toString() ?? '';
    if (factoryId.isEmpty) return;
    await _db.enqueueSync(
      tableName: 'productions',
      recordId: recordId,
      operation: 'production_post',
      payload: payload,
    );
    if (triggerSync) await schedulePendingSync();
  }

  /// Starts a best-effort sync after the caller's local transaction commits.
  Future<void> schedulePendingSync() async {
    try {
      if (await isOnline()) unawaited(syncPending());
    } catch (_) {
      // Local posting is already durable. Connectivity failures remain pending
      // and the periodic/reconnect worker will retry them later.
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
