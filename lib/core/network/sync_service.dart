import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../constants/app_constants.dart';
import '../access/app_access_state.dart';
import '../database/database_service.dart';
import '../services/notification_service.dart';

final syncServiceProvider = Provider<SyncService>((ref) {
  return SyncService(
    ref.watch(databaseServiceProvider),
    accessAllowed: () => ref.read(appAccessProvider).isAllowed,
  );
});

/// Polls pending sync count every 30 s — only when provider is alive.
final pendingSyncCountProvider = StreamProvider<int>((ref) {
  final db = ref.watch(databaseServiceProvider);
  return (() async* {
    yield await db.countPendingSync();
    while (true) {
      await Future<void>.delayed(const Duration(seconds: 15));
      yield await db.countPendingSync();
    }
  })().asBroadcastStream();
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
  if (conn == null) return false; // do not trigger cloud writes before probe
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
    bool Function()? accessAllowed,
  })  : _onlineCheck = onlineCheck,
        _accessAllowed = accessAllowed;

  final DatabaseService _db;
  final Future<bool> Function()? _onlineCheck;
  final bool Function()? _accessAllowed;
  Timer? _syncTimer;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  bool _isSyncing = false;

  void startPeriodicSync() {
    if (_accessAllowed?.call() != true) return;
    if (_syncTimer != null) return;
    _syncTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(syncPending().then<void>((_) {}, onError: (_) {})),
    );
    _connectivitySubscription =
        Connectivity().onConnectivityChanged.listen((results) {
      if (!results.contains(ConnectivityResult.none)) {
        unawaited(syncPending().then<void>((_) {}, onError: (_) {}));
      }
    });
    unawaited(syncPending().then<void>((_) {}, onError: (_) {}));
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

  /// Pulls the active company's shared records onto a newly signed-in mobile.
  /// Pending local records are never overwritten; normal upload remains the
  /// source of truth for offline work made on this device.
  Future<int> hydrateActiveWorkspace() async {
    if (_accessAllowed?.call() != true) return 0;
    if (!await isOnline() || !await isSupabaseReady()) return 0;
    if (await _db.countPendingSync() > 0) return 0;
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) return 0;
    const tables = [
      'parts', 'machines', 'suppliers', 'vendors', 'customers', 'operators',
      'vehicles', 'drivers', 'shifts', 'bp_reject_reasons', 'ap_reject_reasons',
      'rtv_reasons', 'target_master', 'purchase_orders', 'material_receives',
      'productions', 'machine_downtimes', 'bp_inspections', 'bp_rejected_actions', 'dispatch_to_facos',
      'receive_from_facos', 'ap_inspections', 'ap_rejected_actions', 'rtvs',
      'rtv_reinspections', 'final_dispatches', 'dispatch_sessions', 'dispatch_items',
      'stock_ledger', 'correction_requests', 'physical_counts', 'stock_adjustments',
    ];
    var imported = 0;
    final client = Supabase.instance.client;
    for (final table in tables) {
      try {
        final response = await client.from(table).select().eq('factory_id', factoryId)
            .timeout(const Duration(seconds: 12));
        final rows = (response as List)
            .map((row) => Map<String, dynamic>.from(row as Map))
            .toList();
        await _db.upsertRemoteRecords(table, rows);
        imported += rows.length;
      } catch (_) {
        // Older hosted databases may not yet contain every additive table.
        // Continue importing the tables that are available to this app version.
      }
    }
    return imported;
  }

  Future<SyncResult> syncPending() async {
    if (_accessAllowed?.call() != true) return const SyncResult(skipped: true);
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

          final activeWorkspaceId = _db.activeWorkspaceId.trim();
          final payloadWorkspaceId = payload['factory_id']?.toString().trim() ?? '';
          if (activeWorkspaceId.isEmpty || payloadWorkspaceId != activeWorkspaceId) {
            await _db.updateSyncStatus(id, 'conflict', attempts: attempts);
            await _logSyncHistory(
              tableName: tableName,
              recordId: recordId,
              operation: operation,
              status: 'conflict',
              errorMessage: 'Workspace changed before this item was synced.',
            );
            conflicts++;
            continue;
          }

          // Strip generated columns so Supabase doesn't reject the upsert
          payload = Map.from(payload)
            ..removeWhere((k, _) => _generatedColumns.contains(k))
            ..remove('sync_status')
            ..remove('_sync_metadata');

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

          if (operation == 'workspace_transaction_reset') {
            final result = await client.rpc(
              'erase_workspace_transaction_data',
              params: {'p_factory_id': payload['factory_id']},
            ).timeout(const Duration(seconds: 20));
            if (result is Map && result['success'] == false) {
              throw StateError(
                result['error']?.toString() ?? 'Workspace reset was rejected.',
              );
            }
          } else if (operation == 'insert') {
            final rows = await client
                .from(tableName)
                .upsert(payload)
                .select('id')
                .timeout(const Duration(seconds: 12));
            if (rows.isEmpty) throw StateError('Cloud insert was not accepted.');
          } else if (operation == 'correction_review') {
            final result = await client.rpc(
              'review_correction_request',
              params: {
                'p_id': recordId,
                'p_status': payload['status'],
                'p_remarks': payload['review_remarks'] ?? '',
              },
            ).timeout(const Duration(seconds: 12));
            if (result is Map && result['success'] == false) {
              throw StateError(
                result['error']?.toString() ?? 'Correction review was rejected.',
              );
            }
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
              final rows = await client
                  .from(tableName)
                  .update(updatePayload)
                  .eq('id', recordId)
                  .eq('factory_id', factoryId)
                  .select('id')
                  .timeout(const Duration(seconds: 12));
              if (rows.isEmpty) {
                throw StateError('Cloud update was rejected or record was not found.');
              }
            }
          } else if (operation == 'delete') {
            final factoryId = payload['factory_id']?.toString() ?? '';
            final rows = await client
                .from(tableName)
                .delete()
                .eq('id', recordId)
                .eq('factory_id', factoryId)
                .select('id')
                .timeout(const Duration(seconds: 12));
            if (rows.isEmpty) {
              throw StateError('Cloud delete was rejected or record was not found.');
            }
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
          } else if (operation != 'workspace_transaction_reset') {
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
        await _logSyncHistory(
          tableName: 'sync_queue',
          recordId: '',
          operation: 'batch',
          status: 'failed',
          errorMessage: _sanitizeSyncError(e),
        );
        failed++;
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
    final factoryId = payload['factory_id']?.toString() ?? '';
    if (factoryId.isEmpty) {
      throw StateError('Select a company workspace before saving settings.');
    }
    await _db.enqueueSync(
      tableName: tableName,
      recordId: recordId,
      operation: 'insert',
      payload: await _withSyncMetadata(payload),
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
    if (factoryId.isEmpty) {
      throw StateError('Select a company workspace before saving settings.');
    }
    await _db.enqueueSync(
      tableName: tableName,
      recordId: recordId,
      operation: 'update',
      payload: await _withSyncMetadata(payload),
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
    if (factoryId.isEmpty) {
      throw StateError('Select a company workspace before saving data.');
    }
    await _db.enqueueSync(
      tableName: 'stock_ledger',
      recordId: recordId,
      operation: 'ledger',
      payload: await _withSyncMetadata(payload),
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
    if (factoryId.isEmpty) {
      throw StateError('Select a company workspace before saving production.');
    }
    await _db.enqueueSync(
      tableName: 'productions',
      recordId: recordId,
      operation: 'production_post',
      payload: await _withSyncMetadata(payload),
    );
    if (triggerSync) await schedulePendingSync();
  }

  /// Starts a best-effort sync after the caller's local transaction commits.
  Future<void> schedulePendingSync() async {
    try {
      if (_accessAllowed?.call() == true && await isOnline()) {
        unawaited(syncPending().then<void>((_) {}, onError: (_) {}));
      }
    } catch (_) {
      // Local posting is already durable. Connectivity failures remain pending
      // and the periodic/reconnect worker will retry them later.
    }
  }

  Future<Map<String, dynamic>> _withSyncMetadata(
    Map<String, dynamic> payload,
  ) async {
    String? userId;
    try {
      userId = Supabase.instance.client.auth.currentUser?.id;
    } catch (_) {
      // Local/offline mode can start before Supabase initialization.
    }
    final deviceId = await _db.getOrCreateDeviceId();
    return {
      ...payload,
      '_sync_metadata': {
        'command_id': payload['command_id'] ?? const Uuid().v4(),
        'device_id': deviceId,
        'user_id': payload['user_id'] ?? userId,
        'factory_id': payload['factory_id'],
        'created_at': payload['created_at'] ?? DateTime.now().toUtc().toIso8601String(),
        'schema_version': AppConstants.syncEnvelopeSchemaVersion,
        'app_version': AppConstants.appVersion,
      },
    };
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
    this.errorMessage,
  });

  final int synced;
  final int failed;
  final int conflicts;
  final bool offline;
  final bool skipped;
  final String? errorMessage;
}
