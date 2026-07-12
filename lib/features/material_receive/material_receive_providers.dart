import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants/app_constants.dart';
import '../../core/database/database_service.dart';
import '../../core/network/sync_service.dart';
import '../../core/services/stock_ledger_service.dart';

const _uuid = Uuid();

// ─── Material Receive Repository ──────────────────────────────────────────────

class MaterialReceiveRepository {
  MaterialReceiveRepository(this._db, this._sync, this._ledger);

  final DatabaseService _db;
  final SyncService _sync;
  final StockLedgerService _ledger;

  Future<MaterialReceiveResult> save({
    required String partId,
    required double qty,
    required String supplierId,
    String? poNumber,
    String? remarks,
    required String createdBy,
  }) async {
    final id = _uuid.v4();
    final now = DateTime.now();
    final dateStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final timeStr = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    final record = {
      'id': id,
      'factory_id': AppConstants.defaultFactoryId,
      'date': dateStr,
      'time': timeStr,
      'supplier_id': supplierId,
      'po_id': poNumber,
      'part_id': partId,
      'qty': qty,
      'remarks': remarks,
      'created_by': createdBy,
      'created_at': now.toIso8601String(),
      'sync_status': 'pending',
    };

    await _db.insertRecord('material_receives', record);

    // Write to stock ledger
    final ledgerResult = await _ledger.materialReceiveIn(
      partId: partId,
      qty: qty,
      refId: id,
    );

    if (!ledgerResult.success) {
      return MaterialReceiveResult(success: false, error: ledgerResult.error);
    }

    // Queue sync
    await _sync.queueInsert(tableName: 'material_receives', recordId: id, payload: record);

    return MaterialReceiveResult(success: true, recordId: id);
  }

  Future<List<Map<String, dynamic>>> getRecent({int limit = 30}) async {
    final rows = _db.db.select(
      'SELECT mr.*, p.name as part_name, p.code as part_code, s.name as supplier_name '
      'FROM material_receives mr '
      'LEFT JOIN parts p ON p.id = mr.part_id '
      'LEFT JOIN suppliers s ON s.id = mr.supplier_id '
      'ORDER BY mr.created_at DESC LIMIT ?',
      [limit],
    );
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  Future<void> syncFromSupabase() async {
    try {
      final client = Supabase.instance.client;
      final rows = await client
          .from('material_receives')
          .select()
          .eq('factory_id', AppConstants.defaultFactoryId)
          .order('created_at');
      for (final row in rows) {
        await _db.insertRecord('material_receives', row);
      }
    } catch (_) {}
  }
}

final materialReceiveRepositoryProvider = Provider<MaterialReceiveRepository>((ref) {
  return MaterialReceiveRepository(
    ref.watch(databaseServiceProvider),
    ref.watch(syncServiceProvider),
    ref.watch(stockLedgerServiceProvider),
  );
});

final materialReceiveListProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final repo = ref.watch(materialReceiveRepositoryProvider);
  return repo.getRecent();
});

class MaterialReceiveResult {
  const MaterialReceiveResult({required this.success, this.error, this.recordId});
  final bool success;
  final String? error;
  final String? recordId;
}
