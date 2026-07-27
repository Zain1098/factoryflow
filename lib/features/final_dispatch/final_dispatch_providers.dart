import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/database/database_service.dart';
import '../../core/network/sync_service.dart';
import '../../core/constants/stock_stages.dart';
import '../../core/services/stock_ledger_service.dart';

const _uuid = Uuid();

class DispatchItemInput {
  const DispatchItemInput({
    required this.partId,
    required this.partCode,
    required this.qty,
  });
  final String partId;
  final String partCode;
  final double qty;
}

class FinalDispatchRepository {
  FinalDispatchRepository(this._db, this._sync, this._ledger);

  final DatabaseService _db;
  final SyncService _sync;
  final StockLedgerService _ledger;

  /// Save a multi-part dispatch session
  Future<FinalDispatchResult> saveDispatchSession({
    required String customerId,
    required List<DispatchItemInput> items,
    String? vehicleId,
    String? driverId,
    String? challanNumber,
    String? remarks,
    required String createdBy,
    DateTime? recordedAt,
  }) async {
    // Validate all items against AP OK stock
    for (final item in items) {
      final available = await _ledger.getAvailableStock(item.partId, StockStage.approvedAp);
      if (item.qty > available) {
        return FinalDispatchResult(
          success: false,
          error: '${item.partCode}: Dispatch qty (${item.qty.toInt()}) exceeds AP OK stock (${available.toInt()} PCS)',
        );
      }
    }

    final sessionId = _uuid.v4();
    final now = recordedAt ?? DateTime.now();
    final dateStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final timeStr = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    // Auto-generate challan if not provided
    final challan = challanNumber ?? _generateChallan(dateStr);

    final sessionRecord = {
      'id': sessionId,
      'factory_id': _db.activeWorkspaceId,
      'date': dateStr,
      'time': timeStr,
      'customer_id': customerId,
      'vehicle_id': vehicleId,
      'driver_id': driverId,
      'challan_number': challan,
      'remarks': remarks,
      'created_by': createdBy,
      'sync_status': 'pending',
    };

    await _db.insertRecord('dispatch_sessions', sessionRecord);

    // Save each item + deduct from AP OK stock
    for (final item in items) {
      final itemId = _uuid.v4();
      final itemRecord = {
        'id': itemId,
        'session_id': sessionId,
        'factory_id': _db.activeWorkspaceId,
        'part_id': item.partId,
        'dispatch_qty': item.qty,
        'sync_status': 'pending',
      };
      await _db.insertRecord('dispatch_items', itemRecord);

      final ledgerResult = await _ledger.finalDispatch(
        partId: item.partId,
        qty: item.qty,
        refId: itemId,
      );
      if (!ledgerResult.success) {
        return FinalDispatchResult(success: false, error: ledgerResult.error);
      }

      await _sync.queueInsert(tableName: 'dispatch_items', recordId: itemId, payload: itemRecord);
    }

    await _sync.queueInsert(tableName: 'dispatch_sessions', recordId: sessionId, payload: sessionRecord);

    return FinalDispatchResult(success: true, recordId: sessionId, challanNumber: challan);
  }

  String _generateChallan(String dateStr) {
    final existing = _db.db.select(
      "SELECT COUNT(*) as cnt FROM dispatch_sessions WHERE date = ?",
      [dateStr],
    );
    final seq = (existing.first['cnt'] as int) + 1;
    final compact = dateStr.replaceAll('-', '');
    return 'DC-$compact-${seq.toString().padLeft(3, '0')}';
  }

  /// Returns dispatch sessions with their items, grouped for history view
  Future<List<Map<String, dynamic>>> getRecent({int limit = 30}) async {
    final sessions = _db.db.select(
      '''SELECT ds.*, c.name as customer_name,
                v.number_plate as vehicle_plate, d.name as driver_name
         FROM dispatch_sessions ds
         LEFT JOIN customers c ON c.id = ds.customer_id
         LEFT JOIN vehicles v ON v.id = ds.vehicle_id
         LEFT JOIN drivers d ON d.id = ds.driver_id
         ORDER BY ds.date DESC, ds.time DESC LIMIT ?''',
      [limit],
    );

    final result = <Map<String, dynamic>>[];
    for (final session in sessions) {
      final items = _db.db.select(
        '''SELECT di.*, p.code as part_code, p.name as part_name
           FROM dispatch_items di
           LEFT JOIN parts p ON p.id = di.part_id
           WHERE di.session_id = ?
           ORDER BY p.name''',
        [session['id']],
      );
      final map = Map<String, dynamic>.from(session);
      map['items'] = items.map((r) => Map<String, dynamic>.from(r)).toList();
      result.add(map);
    }
    return result;
  }

  Future<String?> getDefaultCustomerId() async {
    final rows = _db.db.select('SELECT id FROM customers WHERE is_default = 1 LIMIT 1');
    if (rows.isEmpty) return null;
    return rows.first['id'] as String;
  }
}

final finalDispatchRepositoryProvider = Provider<FinalDispatchRepository>((ref) {
  return FinalDispatchRepository(
    ref.watch(databaseServiceProvider),
    ref.watch(syncServiceProvider),
    ref.watch(stockLedgerServiceProvider),
  );
});

final finalDispatchListProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  return ref.watch(finalDispatchRepositoryProvider).getRecent();
});

class FinalDispatchResult {
  const FinalDispatchResult({required this.success, this.error, this.recordId, this.challanNumber});
  final bool success;
  final String? error;
  final String? recordId;
  final String? challanNumber;
}
