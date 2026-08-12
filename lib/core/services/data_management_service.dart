import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../database/database_service.dart';
import '../models/app_user.dart';
import '../network/sync_service.dart';

final dataManagementServiceProvider = Provider<DataManagementService>((ref) {
  return DataManagementService(
    ref.watch(databaseServiceProvider),
    ref.watch(syncServiceProvider),
  );
});

/// Sections that can be independently erased.
enum EraseSection {
  productions('productions', 'Production Records'),
  materialReceives('material_receives', 'Material Receive Records'),
  dispatches('final_dispatches', 'Final Dispatch Records'),
  stockLedger('stock_ledger', 'Stock Ledger'),
  machineDowntimes('machine_downtimes', 'Machine Downtime Records'),
  bpInspections('bp_inspections', 'BP Inspection Records'),
  apInspections('ap_inspections', 'AP Inspection Records'),
  rtvs('rtvs', 'RTV Records'),
  dispatchFaco('dispatch_to_facos', 'Dispatch to Faco Records'),
  receiveFaco('receive_from_facos', 'Receive from Faco Records');

  const EraseSection(this.table, this.label);
  final String table;
  final String label;
}

class DataManagementService {
  DataManagementService(this._db, this._sync);

  final DatabaseService _db;
  final SyncService _sync;

  // Tables that are transaction data (safe to erase with backup)
  static const _allTransactionTables = [
    'productions',
    'material_receives',
    'final_dispatches',
    'stock_ledger',
    'machine_downtimes',
    'bp_inspections',
    'ap_inspections',
    'rtvs',
    'dispatch_to_facos',
    'receive_from_facos',
    'rtv_reinspections',
    'purchase_orders',
    'correction_requests',
  ];

  /// Silently backs up [table] to backup_records, then erases it.
  /// User sees nothing — backup is invisible.
  Future<void> eraseSection({
    required EraseSection section,
    required String userId,
    required String factoryId,
  }) async {
    await _db.runInTransaction(() async {
      await _db.backupTable(
        table: section.table,
        userId: userId,
        factoryId: factoryId,
        reason: 'user_erase_section',
      );
      _db.eraseTableForFactory(section.table, factoryId);
      _db.eraseQueuedChangesForFactory(factoryId, [section.table]);
    });
    // Push backup records to Supabase silently.
    await _pushBackupsToSupabase(userId: userId, factoryId: factoryId);
  }

  /// Backs up ALL transaction tables then erases them.
  /// Master data (parts, machines etc.) is preserved.
  Future<void> eraseAllTransactionData({
    required String userId,
    required String factoryId,
  }) async {
    await _db.runInTransaction(() async {
      for (final table in _allTransactionTables) {
        await _db.backupTable(
          table: table,
          userId: userId,
          factoryId: factoryId,
          reason: 'user_erase_all',
        );
        _db.eraseTableForFactory(table, factoryId);
      }
      _db.eraseQueuedChangesForFactory(factoryId, _allTransactionTables);
    });
    await _pushBackupsToSupabase(userId: userId, factoryId: factoryId);
  }

  /// Backs up master data + all transaction data, then clears everything.
  /// Used before account deletion.
  Future<void> eraseEverything({
    required String userId,
    required String factoryId,
  }) async {
    const allTables = [
      'productions', 'material_receives', 'final_dispatches', 'stock_ledger',
      'machine_downtimes', 'bp_inspections', 'ap_inspections', 'rtvs',
      'dispatch_to_facos', 'receive_from_facos', 'rtv_reinspections',
      'purchase_orders', 'correction_requests', 'dispatch_sessions',
      'dispatch_items', 'ap_rejected_actions', 'rtv_reinspections',
      'parts', 'machines', 'suppliers', 'vendors', 'customers',
      'operators', 'vehicles', 'drivers', 'target_master',
      'shifts', 'bp_reject_reasons', 'ap_reject_reasons', 'rtv_reasons',
      'audit_log', 'sync_conflicts', 'draft_forms',
    ];
    await _db.runInTransaction(() async {
      for (final table in allTables) {
        await _db.backupTable(
          table: table,
          userId: userId,
          factoryId: factoryId,
          reason: 'account_deletion',
        );
        _db.eraseTableForFactory(table, factoryId);
      }
      _db.eraseQueuedChangesForFactory(factoryId, allTables);
    });
    await _pushBackupsToSupabase(userId: userId, factoryId: factoryId);
  }

  /// Archives the account profile + local data, requests remote deactivation,
  /// then clears local app data. Backup handling stays invisible to the user.
  Future<void> deleteAccountData({required AppUser user}) async {
    await _db.createBackupRecord(
      sourceTable: 'users',
      sourceRecordId: user.id,
      userId: user.id,
      factoryId: user.factoryId,
      data: user.toJson(),
      reason: 'account_deletion',
    );
    await eraseEverything(userId: user.id, factoryId: user.factoryId);
    await _requestRemoteAccountDeletion(user.id);
    await _pushBackupsToSupabase(userId: user.id, factoryId: user.factoryId);
  }

  /// Row counts for each erasable section — shown in UI.
  Future<Map<EraseSection, int>> getSectionCounts(String factoryId) async {
    final map = <EraseSection, int>{};
    for (final s in EraseSection.values) {
      map[s] = await _db.countTableRowsForFactory(s.table, factoryId);
    }
    return map;
  }

  /// Pushes pending backup_records to Supabase silently.
  /// Failures are ignored — local backup already exists.
  Future<void> _pushBackupsToSupabase({
    required String userId,
    required String factoryId,
  }) async {
    if (!await _sync.isOnline()) return;
    try {
      final client = Supabase.instance.client;
      final pending = _db.db.select(
        "SELECT * FROM backup_records WHERE sync_status = 'pending' "
        'AND user_id = ? AND factory_id = ? LIMIT 200',
        [userId, factoryId],
      );
      if (pending.isEmpty) return;
      final rows = pending.map((r) {
        final m = Map<String, dynamic>.from(r);
        final rawJson = m['data_json'];
        if (rawJson is String) {
          m['data_json'] = jsonDecode(rawJson);
        }
        return m;
      }).toList();
      await client.from('backup_records').upsert(rows).timeout(
            const Duration(seconds: 20),
          );
      for (final row in pending) {
        _db.db.execute(
          "UPDATE backup_records SET sync_status = 'synced' WHERE id = ?",
          [row['id']],
        );
      }
    } catch (_) {
      // Supabase push failed — local backup still safe
    }
  }

  Future<void> _requestRemoteAccountDeletion(String userId) async {
    if (!await _sync.isOnline()) return;
    try {
      await Supabase.instance.client.rpc(
        'request_account_deletion',
        params: {'p_user_id': userId},
      ).timeout(const Duration(seconds: 15));
    } catch (_) {
      try {
        await Supabase.instance.client
            .from('users')
            .update({'active': false})
            .eq('id', userId)
            .timeout(const Duration(seconds: 15));
      } catch (_) {
        // Remote deactivation can be retried from admin tooling later.
      }
    }
    // Auth deletion must happen server-side. The Edge Function verifies that
    // public.users.active is false before removing auth.users.
    await Supabase.instance.client.functions
        .invoke('delete-account')
        .timeout(const Duration(seconds: 20));
  }
}
