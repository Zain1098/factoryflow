import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/database/database_service.dart';
import '../../core/network/sync_service.dart';
import '../../core/constants/stock_stages.dart';
import '../../core/services/stock_ledger_service.dart';

const _uuid = Uuid();

// BP Reject Reasons per PRD 15.2
const kBpRejectReasons = [
  'Crack',
  'Dimension Out of Tolerance',
  'Bend Angle Error',
  'Surface Scratch',
  'Burr/Sharp Edge',
  'Deformation',
  'Incomplete Forming',
];

class BpInspectionRepository {
  BpInspectionRepository(this._db, this._sync, this._ledger);

  final DatabaseService _db;
  final SyncService _sync;
  final StockLedgerService _ledger;

  Future<BpInspectionResult> save({
    required String batchNumber,
    required String partId,
    required String machineId,
    required double bpRejectQty,
    required String rejectReason,
    required String inspectorId,
    String? remarks,
    DateTime? recordedAt,
  }) async {
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) {
      return const BpInspectionResult(
        success: false,
        error: 'No active factory workspace is selected.',
      );
    }
    if (bpRejectQty < 0) {
      return const BpInspectionResult(
        success: false,
        error: 'Reject quantity cannot be negative.',
      );
    }
    if (batchNumber.trim().isEmpty) {
      return const BpInspectionResult(
        success: false,
        error: 'Original Production batch is required.',
      );
    }
    final productionMatch = _db.db.select(
      'SELECT id FROM productions '
      'WHERE factory_id = ? AND batch_number = ? '
      'AND part_id = ? AND machine_id = ? LIMIT 1',
      [factoryId, batchNumber, partId, machineId],
    );
    if (productionMatch.isEmpty) {
      return const BpInspectionResult(
        success: false,
        error:
            'Selected batch, part, and machine do not match a Production entry.',
      );
    }

    // Validate: bpRejectQty <= BP stock available (PRD 4.4)
    final available =
        await _ledger.getAvailableStock(partId, StockStage.bpStock);
    if (bpRejectQty > available) {
      return BpInspectionResult(
        success: false,
        error:
            'Reject qty ($bpRejectQty) exceeds available BP stock ($available)',
      );
    }

    final id = _uuid.v4();
    final now = recordedAt ?? DateTime.now();
    final dateStr =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

    final record = {
      'id': id,
      'factory_id': factoryId,
      'batch_number': batchNumber,
      'date': dateStr,
      'part_id': partId,
      'machine_id': machineId,
      'bp_reject_qty': bpRejectQty,
      'reject_reason_id': rejectReason,
      'inspector_id': inspectorId,
      'remarks': remarks,
      'sync_status': 'pending',
    };

    try {
      await _db.runInTransaction(() async {
        if (bpRejectQty > 0) {
          final ledgerResult = await _ledger.bpRejectToRejected(
            partId: partId,
            qty: bpRejectQty,
            refId: id,
            triggerSync: false,
          );
          if (!ledgerResult.success) {
            throw StockPostingFailure(
              ledgerResult.error ?? 'Unable to update BP reject stock.',
            );
          }
        }

        await _db.insertRecord('bp_inspections', record);
        await _sync.queueInsert(
          tableName: 'bp_inspections',
          recordId: id,
          payload: record,
          triggerSync: false,
        );
      });
    } on StockPostingFailure catch (error) {
      return BpInspectionResult(success: false, error: error.message);
    } catch (_) {
      return const BpInspectionResult(
        success: false,
        error:
            'BP inspection could not be saved. No stock was changed. Please retry.',
      );
    }

    await _sync.schedulePendingSync();
    return BpInspectionResult(success: true, recordId: id);
  }

  Future<List<Map<String, dynamic>>> getRecent({int limit = 30}) async {
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) return [];
    final rows = _db.db.select(
      'SELECT bi.*, p.name as part_name, p.code as part_code, m.name as machine_name '
      'FROM bp_inspections bi '
      'LEFT JOIN parts p ON p.id = bi.part_id AND p.factory_id = bi.factory_id '
      'LEFT JOIN machines m ON m.id = bi.machine_id AND m.factory_id = bi.factory_id '
      'WHERE bi.factory_id = ? '
      'ORDER BY bi.date DESC LIMIT ?',
      [factoryId, limit],
    );
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  /// Get recent batch numbers for autocomplete
  Future<List<String>> getRecentBatches() async {
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) return [];
    final rows = _db.db.select(
      'SELECT DISTINCT batch_number FROM productions '
      'WHERE factory_id = ? ORDER BY created_at DESC LIMIT 20',
      [factoryId],
    );
    return rows.map((r) => r['batch_number'] as String).toList();
  }

  Future<Map<String, dynamic>?> getLatestBatchStage(
    String batchNumber,
  ) async {
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) return null;
    final rows = _db.db.select(
      'SELECT part_id, machine_id FROM productions '
      'WHERE factory_id = ? AND batch_number = ? '
      'ORDER BY created_at DESC LIMIT 1',
      [factoryId, batchNumber],
    );
    if (rows.isEmpty) return null;
    return Map<String, dynamic>.from(rows.single);
  }
}

final bpInspectionRepositoryProvider = Provider<BpInspectionRepository>((ref) {
  return BpInspectionRepository(
    ref.watch(databaseServiceProvider),
    ref.watch(syncServiceProvider),
    ref.watch(stockLedgerServiceProvider),
  );
});

final bpInspectionListProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  return ref.watch(bpInspectionRepositoryProvider).getRecent();
});

final recentBatchesProvider = FutureProvider<List<String>>((ref) async {
  return ref.watch(bpInspectionRepositoryProvider).getRecentBatches();
});

class BpInspectionResult {
  const BpInspectionResult({required this.success, this.error, this.recordId});
  final bool success;
  final String? error;
  final String? recordId;
}
