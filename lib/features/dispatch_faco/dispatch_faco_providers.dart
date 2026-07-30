import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants/stock_stages.dart';
import '../../core/database/database_service.dart';
import '../../core/network/sync_service.dart';
import '../../core/providers/production_flow_provider.dart';
import '../../core/services/stock_ledger_service.dart';

const _uuid = Uuid();

class DispatchFacoRepository {
  DispatchFacoRepository(this._db, this._sync, this._ledger, this._flow);

  final DatabaseService _db;
  final SyncService _sync;
  final StockLedgerService _ledger;
  final ProductionFlowConfig _flow;

  Future<DispatchFacoResult> save({
    required String batchNumber,
    required String partId,
    required double qty,
    required String vendorId,
    String? vehicleId,
    String? driverId,
    String? challannumber,
    String? remarks,
    required String createdBy,
    DateTime? recordedAt,
  }) async {
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) {
      return const DispatchFacoResult(
        success: false,
        error: 'No active factory workspace is selected.',
      );
    }
    if (qty <= 0) {
      return const DispatchFacoResult(
        success: false,
        error: 'Dispatch quantity must be greater than zero.',
      );
    }

    final candidates = await getRecentBpInspections();
    final matching = candidates.where(
      (candidate) =>
          candidate['batch_number'] == batchNumber &&
          candidate['part_id'] == partId,
    );
    if (matching.isEmpty) {
      return const DispatchFacoResult(
        success: false,
        error: 'No BP-inspected stock is available for this batch and part.',
      );
    }
    final batchAvailable =
        (matching.first['available_qty'] as num?)?.toDouble() ?? 0;
    if (qty > batchAvailable) {
      return DispatchFacoResult(
        success: false,
        error:
            'Dispatch quantity ($qty) exceeds this batch BP-approved stock ($batchAvailable PCS).',
      );
    }
    if (_flow.validationError != null) {
      return DispatchFacoResult(
        success: false,
        error: '${_flow.validationError} Review Production Flow in Settings.',
      );
    }

    // Multi-stage validation: If enabled, check if batch has completed the final machine sequence
    if (_flow.isMultiStage &&
        _flow.requireFinalMachineForDispatch &&
        batchNumber.isNotEmpty) {
      final finalMachineId = _flow.requiredMachineIds.last;
      final check = _db.db.select(
        'SELECT COUNT(*) as cnt FROM productions '
        'WHERE factory_id = ? AND batch_number = ? AND machine_id = ?',
        [factoryId, batchNumber, finalMachineId],
      );
      if ((check.first['cnt'] as int) == 0) {
        final mRow = _db.db.select(
          'SELECT name FROM machines WHERE factory_id = ? AND id = ?',
          [factoryId, finalMachineId],
        );
        final mName = mRow.isNotEmpty
            ? mRow.first['name'] as String
            : 'Final Stage Machine';
        return DispatchFacoResult(
          success: false,
          error:
              'Batch "$batchNumber" is still Work-In-Progress (BP stock). It must complete $mName (Final Sequence) before vendor dispatch.',
        );
      }
    }

    // Validate: qty <= BP stock (PRD 4.5)
    final available =
        await _ledger.getAvailableStock(partId, StockStage.bpStock);
    if (qty > available) {
      return DispatchFacoResult(
        success: false,
        error:
            'Dispatch qty ($qty) exceeds available BP stock ($available PCS)',
      );
    }

    final id = _uuid.v4();
    final now = recordedAt ?? DateTime.now();
    final dateStr =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final timeStr =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    final record = {
      'id': id,
      'factory_id': factoryId,
      'batch_number': batchNumber,
      'date': dateStr,
      'time': timeStr,
      'part_id': partId,
      'qty': qty,
      'vendor_id': vendorId,
      'vehicle_id': vehicleId,
      'driver_id': driverId,
      'challan_number': challannumber,
      'remarks': remarks,
      'created_by': createdBy,
      'sync_status': 'pending',
    };

    // Stock: BP Stock OUT → At Faco IN (PRD 7.1)
    try {
      await _db.runInTransaction(() async {
        final ledgerResult = await _ledger.dispatchToFaco(
          partId: partId,
          qty: qty,
          refId: id,
          triggerSync: false,
        );
        if (!ledgerResult.success) {
          throw StockPostingFailure(
            ledgerResult.error ?? 'Unable to update Faco stock.',
          );
        }

        await _db.insertRecord('dispatch_to_facos', record);
        await _sync.queueInsert(
          tableName: 'dispatch_to_facos',
          recordId: id,
          payload: record,
          triggerSync: false,
        );
      });
    } on StockPostingFailure catch (error) {
      return DispatchFacoResult(success: false, error: error.message);
    } catch (_) {
      return const DispatchFacoResult(
        success: false,
        error:
            'Faco dispatch could not be saved. No stock was changed. Please retry.',
      );
    }

    await _sync.schedulePendingSync();
    return DispatchFacoResult(success: true, recordId: id);
  }

  Future<List<Map<String, dynamic>>> getRecent({int limit = 30}) async {
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) return [];
    final rows = _db.db.select(
      'SELECT df.*, p.name as part_name, p.code as part_code, v.name as vendor_name '
      'FROM dispatch_to_facos df '
      'LEFT JOIN parts p ON p.id = df.part_id AND p.factory_id = df.factory_id '
      'LEFT JOIN vendors v ON v.id = df.vendor_id AND v.factory_id = df.factory_id '
      'WHERE df.factory_id = ? '
      'ORDER BY df.date DESC, df.time DESC LIMIT ?',
      [factoryId, limit],
    );
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

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

  Future<List<Map<String, dynamic>>> getRecentBpInspections() async {
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) return [];
    final finalMachineId =
        _flow.isMultiStage ? _flow.requiredMachineIds.last : null;
    final rows = _db.db.select(
      '''SELECT bi.batch_number, bi.part_id,
                p.code AS part_code, p.name AS part_name,
                MAX(bi.date) AS date,
                COALESCE((
                  SELECT SUM(pr.good_qty)
                  FROM productions pr
                  WHERE pr.factory_id = bi.factory_id
                    AND pr.batch_number = bi.batch_number
                    AND pr.part_id = bi.part_id
                    AND (? IS NULL OR pr.machine_id = ?)
                ), 0)
                - SUM(bi.bp_reject_qty)
                - COALESCE((
                  SELECT SUM(df.qty)
                  FROM dispatch_to_facos df
                  WHERE df.factory_id = bi.factory_id
                    AND df.batch_number = bi.batch_number
                    AND df.part_id = bi.part_id
                ), 0) AS available_qty
         FROM bp_inspections bi
         INNER JOIN parts p ON p.id = bi.part_id
           AND p.factory_id = bi.factory_id
         WHERE bi.factory_id = ?
         GROUP BY bi.factory_id, bi.batch_number, bi.part_id, p.code, p.name
         HAVING available_qty > 0
         ORDER BY date DESC LIMIT 30''',
      [finalMachineId, finalMachineId, factoryId],
    );
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }
}

final dispatchFacoRepositoryProvider = Provider<DispatchFacoRepository>((ref) {
  return DispatchFacoRepository(
    ref.watch(databaseServiceProvider),
    ref.watch(syncServiceProvider),
    ref.watch(stockLedgerServiceProvider),
    ref.watch(productionFlowProvider),
  );
});

final dispatchFacoListProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  return ref.watch(dispatchFacoRepositoryProvider).getRecent();
});

final bpReinspectedBatchesProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  return ref.watch(dispatchFacoRepositoryProvider).getRecentBpInspections();
});

class DispatchFacoResult {
  const DispatchFacoResult({required this.success, this.error, this.recordId});
  final bool success;
  final String? error;
  final String? recordId;
}
