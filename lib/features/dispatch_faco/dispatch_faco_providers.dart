import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants/stock_stages.dart';
import '../../core/database/database_service.dart';
import '../../core/network/sync_service.dart';
import '../../core/providers/production_flow_provider.dart';
import '../../core/services/stock_ledger_service.dart';

const _uuid = Uuid();

class DispatchFacoLineItem {
  const DispatchFacoLineItem({
    required this.partId,
    required this.partCode,
    required this.partName,
    required this.qty,
    this.batchNumber,
  });

  final String partId;
  final String partCode;
  final String partName;
  final double qty;
  final String? batchNumber;
}

class DispatchFacoRepository {
  DispatchFacoRepository(this._db, this._sync, this._ledger, this._flow);

  final DatabaseService _db;
  final SyncService _sync;
  final StockLedgerService _ledger;
  final ProductionFlowConfig _flow;

  /// Parts with available Own BP Stock that can go to FACO (BP inspection optional).
  Future<List<Map<String, dynamic>>> getAvailableBpStockParts() async {
    final rows = await _db.getBalancesByStage(StockStage.bpStock.value);
    return rows
        .where((r) => ((r['balance'] as num?)?.toDouble() ?? 0) > 0)
        .map((r) => Map<String, dynamic>.from(r))
        .toList();
  }

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
  }) {
    return saveMulti(
      items: [
        DispatchFacoLineItem(
          partId: partId,
          partCode: '',
          partName: '',
          qty: qty,
          batchNumber: batchNumber,
        ),
      ],
      vendorId: vendorId,
      vehicleId: vehicleId,
      driverId: driverId,
      challannumber: challannumber,
      remarks: remarks,
      createdBy: createdBy,
      recordedAt: recordedAt,
    );
  }

  Future<DispatchFacoResult> saveMulti({
    required List<DispatchFacoLineItem> items,
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
    if (items.isEmpty) {
      return const DispatchFacoResult(
        success: false,
        error: 'Add at least one part to dispatch.',
      );
    }
    for (final item in items) {
      if ((item.batchNumber ?? '').trim().isEmpty) {
        return const DispatchFacoResult(
          success: false,
          error: 'Select an available trace batch before dispatching to vendor.',
        );
      }
      if (item.qty <= 0) {
        return DispatchFacoResult(
          success: false,
          error: 'Quantity for ${item.partCode} must be greater than zero.',
        );
      }
    }
    if (_flow.validationError != null) {
      return DispatchFacoResult(
        success: false,
        error: '${_flow.validationError} Review Production Flow in Settings.',
      );
    }

    for (final item in items) {
      final isOpeningBatch = item.batchNumber!.startsWith('OPEN-');
      final batchPart = _db.db.select(
        'SELECT id FROM productions '
        'WHERE factory_id = ? AND batch_number = ? AND part_id = ? LIMIT 1',
        [factoryId, item.batchNumber, item.partId],
      );
      if (batchPart.isEmpty && !isOpeningBatch) {
        return DispatchFacoResult(
          success: false,
          error: '${item.partCode}: selected batch does not belong to this part.',
        );
      }
      final available =
          await _ledger.getAvailableStock(item.partId, StockStage.bpStock);
      if (item.qty > available) {
        return DispatchFacoResult(
          success: false,
          error:
              '${item.partCode}: dispatch qty (${item.qty.toInt()}) exceeds Own BP Stock (${available.toInt()} PCS)',
        );
      }

      if (!isOpeningBatch) {
        final finalMachineId =
            _flow.isMultiStage ? _flow.requiredMachineIds.last : null;
        final batchRows = _db.db.select(
          '''SELECT COALESCE((
               SELECT SUM(output.good_qty) FROM productions output
               WHERE output.factory_id = ? AND output.batch_number = ?
                 AND output.part_id = ?
                 AND (? IS NULL OR output.machine_id = ?)
             ), 0) - COALESCE((
               SELECT SUM(bi.bp_reject_qty) FROM bp_inspections bi
               WHERE bi.factory_id = ? AND bi.batch_number = ?
                 AND bi.part_id = ?
             ), 0) - COALESCE((
               SELECT SUM(df.qty) FROM dispatch_to_facos df
               WHERE df.factory_id = ? AND df.batch_number = ?
                 AND df.part_id = ?
             ), 0) AS available_qty''',
          [
            factoryId,
            item.batchNumber,
            item.partId,
            finalMachineId,
            finalMachineId,
            factoryId,
            item.batchNumber,
            item.partId,
            factoryId,
            item.batchNumber,
            item.partId,
          ],
        );
        final batchAvailable =
            (batchRows.single['available_qty'] as num?)?.toDouble() ?? 0;
        if (item.qty > batchAvailable) {
          return DispatchFacoResult(
            success: false,
            error:
                '${item.partCode}: dispatch qty exceeds this batch balance (${batchAvailable.toInt()} PCS).',
          );
        }
      }

      if (!isOpeningBatch &&
          _flow.isMultiStage &&
          _flow.requireFinalMachineForDispatch &&
          (item.batchNumber ?? '').isNotEmpty) {
        final finalMachineId = _flow.requiredMachineIds.last;
        final check = _db.db.select(
          'SELECT COUNT(*) as cnt FROM productions '
          'WHERE factory_id = ? AND batch_number = ? AND machine_id = ?',
          [factoryId, item.batchNumber, finalMachineId],
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
              'Batch "${item.batchNumber}" must complete $mName before vendor dispatch.',
          );
        }
      }
    }

    final now = recordedAt ?? DateTime.now();
    final dateStr =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final timeStr =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    final savedIds = <String>[];
    try {
      await _db.runInTransaction(() async {
        for (final item in items) {
          final id = _uuid.v4();
          final record = {
            'id': id,
            'factory_id': factoryId,
            'batch_number': item.batchNumber ?? '',
            'date': dateStr,
            'time': timeStr,
            'part_id': item.partId,
            'qty': item.qty,
            'vendor_id': vendorId,
            'vehicle_id': vehicleId,
            'driver_id': driverId,
            'challan_number': challannumber,
            'remarks': remarks,
            'created_by': createdBy,
            'sync_status': 'pending',
          };

          final ledgerResult = await _ledger.dispatchToFaco(
            partId: item.partId,
            qty: item.qty,
            refId: id,
            triggerSync: false,
          );
          if (!ledgerResult.success) {
            throw StockPostingFailure(
              ledgerResult.error ?? 'Unable to update vendor stock.',
            );
          }

          await _db.insertRecord('dispatch_to_facos', record);
          await _sync.queueInsert(
            tableName: 'dispatch_to_facos',
            recordId: id,
            payload: record,
            triggerSync: false,
          );
          savedIds.add(id);
        }
      });
    } on StockPostingFailure catch (error) {
      return DispatchFacoResult(success: false, error: error.message);
    } catch (_) {
      return const DispatchFacoResult(
        success: false,
        error:
            'Vendor dispatch could not be saved. No stock was changed. Please retry.',
      );
    }

    await _sync.schedulePendingSync();
    return DispatchFacoResult(success: true, recordId: savedIds.first);
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

  /// Finished production and opening-stock batches with quantity still
  /// available for vendor dispatch.
  /// A formal BP inspection is optional, but any recorded BP rejects still
  /// reduce the batch quantity that can be dispatched.
  Future<List<Map<String, dynamic>>> getRecentBpInspections() async {
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) return [];
    final finalMachineId =
        _flow.isMultiStage ? _flow.requiredMachineIds.last : null;
    final rows = _db.db.select(
      '''SELECT pr.batch_number, pr.part_id,
                p.code AS part_code, p.name AS part_name,
                MAX(pr.date) AS date,
                COALESCE((
                  SELECT SUM(output.good_qty)
                  FROM productions output
                  WHERE output.factory_id = pr.factory_id
                    AND output.batch_number = pr.batch_number
                    AND output.part_id = pr.part_id
                    AND (? IS NULL OR output.machine_id = ?)
                ), 0)
                - COALESCE((
                  SELECT SUM(bi.bp_reject_qty)
                  FROM bp_inspections bi
                  WHERE bi.factory_id = pr.factory_id
                    AND bi.batch_number = pr.batch_number
                    AND bi.part_id = pr.part_id
                ), 0)
                - COALESCE((
                  SELECT SUM(df.qty) FROM dispatch_to_facos df
                  WHERE df.factory_id = pr.factory_id
                    AND df.batch_number = pr.batch_number
                    AND df.part_id = pr.part_id
                ), 0) AS available_qty
         FROM productions pr
         INNER JOIN parts p ON p.id = pr.part_id
           AND p.factory_id = pr.factory_id
         WHERE pr.factory_id = ?
         GROUP BY pr.factory_id, pr.batch_number, pr.part_id, p.code, p.name
         HAVING available_qty > 0
         ORDER BY date DESC LIMIT 30''',
      [finalMachineId, finalMachineId, factoryId],
    );
    final batches = rows.map((r) => Map<String, dynamic>.from(r)).toList();

    final openingRows = _db.db.select(
      '''SELECT COALESCE(NULLIF(sa.batch_number, ''), 'OPEN-' || p.code) AS batch_number,
                sa.part_id, p.code AS part_code,
                p.name AS part_name, MAX(sa.created_at) AS date,
                SUM(sa.adjusted_qty) - COALESCE((
                  SELECT SUM(df.qty) FROM dispatch_to_facos df
                  WHERE df.factory_id = sa.factory_id
                    AND df.batch_number = COALESCE(NULLIF(sa.batch_number, ''), 'OPEN-' || p.code)
                    AND df.part_id = sa.part_id
                ), 0) AS available_qty
         FROM stock_adjustments sa
         INNER JOIN parts p ON p.id = sa.part_id AND p.factory_id = sa.factory_id
         WHERE sa.factory_id = ? AND sa.stage = 'bp_stock'
         GROUP BY sa.factory_id, COALESCE(NULLIF(sa.batch_number, ''), 'OPEN-' || p.code), sa.part_id, p.code, p.name
         HAVING available_qty > 0
         ORDER BY date DESC LIMIT 30''',
      [factoryId],
    );
    batches.addAll(openingRows.map((r) => Map<String, dynamic>.from(r)));

    // Ensure any remaining BP stock recorded in the stock ledger is also
    // available as a dispatchable OPEN-{code} batch if not fully covered
    // by production/adjustment batch rows above.
    final bpBalances = await _db.getBalancesByStage(StockStage.bpStock.value);
    for (final partBalance in bpBalances) {
      final partId = partBalance['id'] as String;
      final partCode = partBalance['code'] as String? ?? '';
      final partName = partBalance['name'] as String? ?? '';
      final ledgerBalance = (partBalance['balance'] as num?)?.toDouble() ?? 0.0;
      if (ledgerBalance <= 0) continue;

      final existingBatchSum = batches
          .where((b) => b['part_id'] == partId)
          .fold<double>(0.0, (sum, b) => sum + ((b['available_qty'] as num?)?.toDouble() ?? 0.0),);

      final unbatched = ledgerBalance - existingBatchSum;
      if (unbatched > 0) {
        final openBatchNumber = 'OPEN-$partCode';
        final existingOpenIndex = batches.indexWhere(
            (b) => b['part_id'] == partId && b['batch_number'] == openBatchNumber,);
        if (existingOpenIndex >= 0) {
          batches[existingOpenIndex]['available_qty'] =
              ((batches[existingOpenIndex]['available_qty'] as num?)?.toDouble() ?? 0.0) + unbatched;
        } else {
          batches.add({
            'batch_number': openBatchNumber,
            'part_id': partId,
            'part_code': partCode,
            'part_name': partName,
            'date': DateTime.now().toIso8601String().substring(0, 10),
            'available_qty': unbatched,
          });
        }
      }
    }

    final partTotals = <String, double>{};
    for (final batch in batches) {
      final partId = batch['part_id'] as String;
      partTotals[partId] = (partTotals[partId] ?? 0) +
          ((batch['available_qty'] as num?)?.toDouble() ?? 0);
    }
    return batches
        .map((batch) => {
              ...batch,
              'part_available_qty': partTotals[batch['part_id']] ?? 0,
            },)
        .toList();
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

final bpStockPartsForDispatchProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  return ref.watch(dispatchFacoRepositoryProvider).getAvailableBpStockParts();
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
