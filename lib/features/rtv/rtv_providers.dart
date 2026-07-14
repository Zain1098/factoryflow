import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants/app_constants.dart';
import '../../core/database/database_service.dart';
import '../../core/network/sync_service.dart';
import '../../core/services/stock_ledger_service.dart';

const _uuid = Uuid();

// RTV Reasons per PRD 15.2
const kRtvReasons = [
  'Plating Quality Reject',
  'Vendor Processing Delay',
  'Damaged in Transit',
  'Wrong Quantity Received',
];

const kRtvStatuses = ['pending', 'sent', 'received', 'escalated'];

class RtvRepository {
  RtvRepository(this._db, this._sync, this._ledger);

  final DatabaseService _db;
  final SyncService _sync;
  final StockLedgerService _ledger;

  Future<RtvResult> save({
    required String batchNumber,
    required String partId,
    required double rtvQty,
    required String reason,
    required String vendorId,
    String? expectedReturnDate,
    String? remarks,
    required String createdBy,
    DateTime? recordedAt,
  }) async {
    // Check cycle count (PRD 3.3 — cap at 3)
    final cycleRows = _db.db.select(
      'SELECT COUNT(*) as cnt FROM rtvs WHERE batch_number = ? AND part_id = ?',
      [batchNumber, partId],
    );
    final currentCycles = cycleRows.first['cnt'] as int;
    if (currentCycles >= AppConstants.rtvMaxCycles) {
      return RtvResult(
        success: false,
        error: 'RTV cycle cap (${AppConstants.rtvMaxCycles}) reached. Escalated — Awaiting Admin Decision.',
        isEscalated: true,
      );
    }

    // Check cumulative RTV qty <= AP rejected qty (PRD 3.4)
    final apRows = _db.db.select(
      'SELECT SUM(rejected_qty) as total FROM ap_inspections WHERE batch_number = ? AND part_id = ?',
      [batchNumber, partId],
    );
    final apRejectedTotal = (apRows.first['total'] as num?)?.toDouble() ?? 0;

    final existingRtvRows = _db.db.select(
      'SELECT SUM(rtv_qty) as total FROM rtvs WHERE batch_number = ? AND part_id = ?',
      [batchNumber, partId],
    );
    final existingRtvTotal = (existingRtvRows.first['total'] as num?)?.toDouble() ?? 0;

    if (existingRtvTotal + rtvQty > apRejectedTotal) {
      return RtvResult(
        success: false,
        error: 'Cumulative RTV qty (${existingRtvTotal + rtvQty}) would exceed AP rejected qty ($apRejectedTotal)',
      );
    }

    final cycleNumber = currentCycles + 1;
    final id = _uuid.v4();
    final now = recordedAt ?? DateTime.now();
    final dateStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

    final record = {
      'id': id,
      'factory_id': _db.activeWorkspaceId,
      'batch_number': batchNumber,
      'cycle_number': cycleNumber,
      'date': dateStr,
      'part_id': partId,
      'rtv_qty': rtvQty,
      'reason_id': reason,
      'vendor_id': vendorId,
      'status': 'pending',
      'expected_return_date': expectedReturnDate,
      'actual_return_date': null,
      'remarks': remarks,
      'sync_status': 'pending',
    };

    await _db.insertRecord('rtvs', record);

    // Stock: RTV Stock OUT (PRD 7.1)
    final ledgerResult = await _ledger.rtvOut(
      partId: partId,
      qty: rtvQty,
      refId: id,
    );
    if (!ledgerResult.success) {
      return RtvResult(success: false, error: ledgerResult.error);
    }

    await _sync.queueInsert(tableName: 'rtvs', recordId: id, payload: record);

    return RtvResult(success: true, recordId: id, cycleNumber: cycleNumber);
  }

  Future<List<Map<String, dynamic>>> getRecent({int limit = 30}) async {
    final rows = _db.db.select(
      'SELECT r.*, p.name as part_name, p.code as part_code, v.name as vendor_name '
      'FROM rtvs r '
      'LEFT JOIN parts p ON p.id = r.part_id '
      'LEFT JOIN vendors v ON v.id = r.vendor_id '
      'ORDER BY r.date DESC LIMIT ?',
      [limit],
    );
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }
}

final rtvRepositoryProvider = Provider<RtvRepository>((ref) {
  return RtvRepository(
    ref.watch(databaseServiceProvider),
    ref.watch(syncServiceProvider),
    ref.watch(stockLedgerServiceProvider),
  );
});

final rtvListProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  return ref.watch(rtvRepositoryProvider).getRecent();
});

class RtvResult {
  const RtvResult({
    required this.success,
    this.error,
    this.recordId,
    this.cycleNumber,
    this.isEscalated = false,
  });
  final bool success;
  final String? error;
  final String? recordId;
  final int? cycleNumber;
  final bool isEscalated;
}
