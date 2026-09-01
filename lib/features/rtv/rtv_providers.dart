import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants/app_constants.dart';
import '../../core/constants/stock_stages.dart';
import '../../core/constants/user_roles.dart';
import '../../core/database/database_service.dart';
import '../../core/network/sync_service.dart';
import '../../core/services/alert_producer_service.dart';
import '../../core/services/stock_ledger_service.dart';

import '../../core/providers/master_data_providers.dart';

const _uuid = Uuid();

const kRtvStatuses = [
  'sent', 'partially_received', 'approved', 'rejected_again',
  'escalated', 'scrapped', 'force_dispatched',
];

// Fallback reasons used only when DB has no configured reasons yet.
const kRtvReasonsFallback = [
  'Plating Quality Reject', 'Vendor Processing Delay',
  'Damaged in Transit', 'Wrong Quantity Received',
];

/// Live RTV reasons from DB, falling back to defaults.
final rtvReasonsListProvider = FutureProvider<List<String>>((ref) async {
  final rows = await ref.watch(rtvReasonsProvider.future);
  if (rows.isEmpty) return kRtvReasonsFallback;
  return rows.map((r) => r['reason'] as String).toList();
});

class RtvRepository {
  RtvRepository(this._db, this._sync, this._ledger, this._alerts);

  final DatabaseService _db;
  final SyncService _sync;
  final StockLedgerService _ledger;
  final AlertProducerService _alerts;

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
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) {
      return const RtvResult(
        success: false,
        error: 'No active factory workspace is selected.',
      );
    }
    if (rtvQty <= 0) {
      return const RtvResult(
        success: false,
        error: 'RTV quantity must be greater than zero.',
      );
    }

    // Check cycle count (PRD 3.3 — cap at 3)
    final cycleRows = _db.db.select(
      'SELECT COUNT(*) as cnt FROM rtvs '
      'WHERE factory_id = ? AND batch_number = ? AND part_id = ?',
      [factoryId, batchNumber, partId],
    );
    final currentCycles = cycleRows.first['cnt'] as int;
    if (currentCycles >= AppConstants.rtvMaxCycles) {
      return const RtvResult(
        success: false,
        error:
            'RTV cycle cap (${AppConstants.rtvMaxCycles}) reached. Escalated — Awaiting Admin Decision.',
        isEscalated: true,
      );
    }

    final candidates = await getCandidates();
    final matchingCandidates = candidates.where(
      (candidate) =>
          candidate['batch_number'] == batchNumber &&
          candidate['part_id'] == partId,
    );
    if (matchingCandidates.isEmpty) {
      return const RtvResult(
        success: false,
        error:
            'No AP-rejected RTV quantity is available for this batch and part.',
      );
    }
    final batchAvailable =
        (matchingCandidates.first['available_qty'] as num?)?.toDouble() ?? 0;
    if (rtvQty > batchAvailable) {
      return RtvResult(
        success: false,
        error:
            'RTV quantity ($rtvQty) exceeds this batch availability ($batchAvailable PCS).',
      );
    }

    final availableRtvStock =
        await _ledger.getAvailableStock(partId, StockStage.rtvStock);
    final outstandingRows = _db.db.select(
      '''SELECT COALESCE(SUM(
           r.rtv_qty - COALESCE((
             SELECT SUM(rr.quantity_received)
             FROM rtv_reinspections rr
             WHERE rr.factory_id = r.factory_id AND rr.rtv_id = r.id
           ), 0)
         ), 0) AS qty
         FROM rtvs r
         WHERE r.factory_id = ? AND r.part_id = ?
           AND r.status NOT IN ('scrapped', 'force_dispatched')''',
      [factoryId, partId],
    );
    final outstandingQty =
        (outstandingRows.first['qty'] as num?)?.toDouble() ?? 0;
    final unassignedStock =
        (availableRtvStock - outstandingQty).clamp(0, double.infinity);
    if (rtvQty > unassignedStock) {
      return RtvResult(
        success: false,
        error: 'RTV qty ($rtvQty) exceeds unassigned RTV stock '
            '($unassignedStock PCS). Existing vendor-outstanding stock is not reusable.',
      );
    }

    final cycleNumber = currentCycles + 1;
    final id = _uuid.v4();
    final now = recordedAt ?? DateTime.now();
    final dateStr =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

    final record = {
      'id': id,
      'factory_id': factoryId,
      'batch_number': batchNumber,
      'cycle_number': cycleNumber,
      'date': dateStr,
      'part_id': partId,
      'rtv_qty': rtvQty,
      'reason_id': reason,
      'vendor_id': vendorId,
      'status': 'sent',
      'expected_return_date': expectedReturnDate,
      'actual_return_date': null,
      'remarks': remarks,
      'sync_status': 'pending',
    };

    try {
      await _db.runInTransaction(() async {
        // AP inspection creates company RTV Hold. This save is the explicit
        // vendor-send action, so it posts the matching stock movement.
        final ledgerResult = await _ledger.rtvSendToVendor(
          partId: partId,
          qty: rtvQty,
          refId: id,
          triggerSync: false,
        );
        if (!ledgerResult.success) {
          throw StockPostingFailure(
            ledgerResult.error ?? 'Unable to move RTV stock to vendor.',
          );
        }
        await _db.insertRecord('rtvs', record);
        await _sync.queueInsert(
          tableName: 'rtvs',
          recordId: id,
          payload: record,
          triggerSync: false,
        );
      });
    } on StockPostingFailure catch (error) {
      return RtvResult(success: false, error: error.message);
    } catch (_) {
      return const RtvResult(
        success: false,
        error: 'RTV could not be saved. No stock was changed. Please retry.',
      );
    }

    await _sync.schedulePendingSync();
    unawaited(_alerts.checkRtvPending());
    return RtvResult(success: true, recordId: id, cycleNumber: cycleNumber);
  }

  Future<List<Map<String, dynamic>>> getCandidates() async {
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) return [];
    final rows = _db.db.select(
      '''SELECT ai.batch_number, ai.part_id,
                p.code AS part_code, p.name AS part_name,
                SUM(ai.rtv_qty) AS allocated_qty,
                COALESCE((
                  SELECT SUM(r.rtv_qty)
                  FROM rtvs r
                  WHERE r.factory_id = ai.factory_id
                    AND r.batch_number = ai.batch_number
                    AND r.part_id = ai.part_id
                ), 0) AS assigned_qty,
                COALESCE((
                  SELECT SUM(rr.reject_again_qty)
                  FROM rtv_reinspections rr
                  INNER JOIN rtvs r ON r.id = rr.rtv_id
                    AND r.factory_id = rr.factory_id
                  WHERE r.factory_id = ai.factory_id
                    AND r.batch_number = ai.batch_number
                    AND r.part_id = ai.part_id
                ), 0) AS repeat_qty
         FROM ap_inspections ai
         INNER JOIN parts p ON p.id = ai.part_id
           AND p.factory_id = ai.factory_id
         WHERE ai.factory_id = ? AND ai.rtv_qty > 0
         GROUP BY ai.factory_id, ai.batch_number, ai.part_id, p.code, p.name
         ORDER BY ai.date, p.code''',
      [factoryId],
    );
    final list = rows.map((row) {
      final item = Map<String, dynamic>.from(row);
      item['available_qty'] =
          ((item['allocated_qty'] as num?)?.toDouble() ?? 0) +
              ((item['repeat_qty'] as num?)?.toDouble() ?? 0) -
              ((item['assigned_qty'] as num?)?.toDouble() ?? 0);
      return item;
    }).where((item) {
      return ((item['available_qty'] as num?)?.toDouble() ?? 0) > 0;
    }).toList();

    // Check if there is manual / opening rtv_stock in the stock ledger
    final rtvStockBalances =
        await _db.getBalancesByStage(StockStage.rtvStock.value);
    for (final row in rtvStockBalances) {
      final partId = row['id'] as String;
      final partCode = row['code'] as String? ?? '';
      final partName = row['name'] as String? ?? '';
      final ledgerBalance = (row['balance'] as num?)?.toDouble() ?? 0.0;
      if (ledgerBalance <= 0) continue;

      final existingSum = list
          .where((i) => i['part_id'] == partId)
          .fold<double>(
            0.0,
            (sum, i) => sum + ((i['available_qty'] as num?)?.toDouble() ?? 0.0),
          );

      final unbatched = ledgerBalance - existingSum;
      if (unbatched > 0) {
        list.add({
          'part_id': partId,
          'part_code': partCode,
          'part_name': partName,
          'batch_number': 'OPEN-$partCode',
          'available_qty': unbatched,
          'allocated_qty': unbatched,
          'assigned_qty': 0,
          'repeat_qty': 0,
        });
      }
    }

    return list;
  }

  Future<List<Map<String, dynamic>>> getPendingReturns() async {
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) return [];
    final rows = _db.db.select(
      '''SELECT r.*, p.code AS part_code, p.name AS part_name,
                v.name AS vendor_name,
                r.rtv_qty - COALESCE(SUM(rr.quantity_received), 0)
                  AS remaining_qty
         FROM rtvs r
         INNER JOIN parts p ON p.id = r.part_id
           AND p.factory_id = r.factory_id
         LEFT JOIN vendors v ON v.id = r.vendor_id
           AND v.factory_id = r.factory_id
         LEFT JOIN rtv_reinspections rr ON rr.rtv_id = r.id
           AND rr.factory_id = r.factory_id
         WHERE r.factory_id = ?
           AND r.status IN ('sent', 'partially_received')
         GROUP BY r.id, p.code, p.name, v.name
         HAVING r.rtv_qty - COALESCE(SUM(rr.quantity_received), 0) > 0
         ORDER BY r.date, r.cycle_number''',
      [factoryId],
    );
    return rows.map((row) => Map<String, dynamic>.from(row)).toList();
  }

  Future<RtvReinspectionResult> saveReinspection({
    required String rtvId,
    required double quantityReceived,
    required double okQty,
    required double rejectAgainQty,
    required String createdBy,
    String? remarks,
    DateTime? recordedAt,
  }) async {
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) {
      return const RtvReinspectionResult(
        success: false,
        error: 'No active factory workspace is selected.',
      );
    }
    if (quantityReceived <= 0 || okQty < 0 || rejectAgainQty < 0) {
      return const RtvReinspectionResult(
        success: false,
        error: 'Return quantities must be valid positive values.',
      );
    }
    if ((okQty + rejectAgainQty - quantityReceived).abs() > 0.001) {
      return const RtvReinspectionResult(
        success: false,
        error: 'OK + Reject Again must equal Quantity Received.',
      );
    }

    final rtvRows = _db.db.select(
      '''SELECT r.*,
                r.rtv_qty - COALESCE((
                  SELECT SUM(rr.quantity_received)
                  FROM rtv_reinspections rr
                  WHERE rr.factory_id = r.factory_id AND rr.rtv_id = r.id
                ), 0) AS remaining_qty
         FROM rtvs r
         WHERE r.id = ? AND r.factory_id = ?''',
      [rtvId, factoryId],
    );
    if (rtvRows.isEmpty) {
      return const RtvReinspectionResult(
        success: false,
        error: 'The selected RTV record was not found in this factory.',
      );
    }
    final rtv = Map<String, dynamic>.from(rtvRows.single);
    final remainingQty = (rtv['remaining_qty'] as num?)?.toDouble() ?? 0;
    if (quantityReceived > remainingQty) {
      return RtvReinspectionResult(
        success: false,
        error:
            'Received quantity ($quantityReceived) exceeds RTV remaining quantity ($remainingQty PCS).',
      );
    }

    final cycleNumber = (rtv['cycle_number'] as num?)?.toInt() ?? 1;
    final isFullReturn = (quantityReceived - remainingQty).abs() < 0.001;
    final isEscalated =
        rejectAgainQty > 0 && cycleNumber >= AppConstants.rtvMaxCycles;
    final status = !isFullReturn
        ? 'partially_received'
        : isEscalated
            ? 'escalated'
            : rejectAgainQty > 0
                ? 'rejected_again'
                : 'approved';
    final nextAction = isEscalated
        ? 'admin_decision'
        : rejectAgainQty > 0
            ? 'rtv_again'
            : 'approved';
    final id = _uuid.v4();
    final now = recordedAt ?? DateTime.now();
    final dateStr =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final record = {
      'id': id,
      'factory_id': factoryId,
      'rtv_id': rtvId,
      'date': dateStr,
      'quantity_received': quantityReceived,
      'ok_qty': okQty,
      'reject_again_qty': rejectAgainQty,
      'next_action': nextAction,
      'remarks': remarks,
      'sync_status': 'pending',
    };

    try {
      await _db.runInTransaction(() async {
        final ledgerResult = await _ledger.rtvReinspectionSplit(
          partId: rtv['part_id'] as String,
          quantityReceived: quantityReceived,
          okQty: okQty,
          rejectAgainQty: rejectAgainQty,
          refId: id,
          triggerSync: false,
        );
        if (!ledgerResult.success) {
          throw StockPostingFailure(
            ledgerResult.error ?? 'Unable to post RTV return stock.',
          );
        }
        await _db.insertRecord('rtv_reinspections', record);
        await _sync.queueInsert(
          tableName: 'rtv_reinspections',
          recordId: id,
          payload: record,
          triggerSync: false,
        );

        _db.db.execute(
          'UPDATE rtvs SET status = ?, actual_return_date = ?, '
          'sync_status = ? WHERE id = ? AND factory_id = ?',
          [
            status,
            isFullReturn ? dateStr : null,
            'pending',
            rtvId,
            factoryId,
          ],
        );
        await _sync.queueUpdate(
          tableName: 'rtvs',
          recordId: rtvId,
          payload: {
            'id': rtvId,
            'factory_id': factoryId,
            'status': status,
            'actual_return_date': isFullReturn ? dateStr : null,
          },
          triggerSync: false,
        );
      });
    } on StockPostingFailure catch (error) {
      return RtvReinspectionResult(success: false, error: error.message);
    } catch (_) {
      return const RtvReinspectionResult(
        success: false,
        error:
            'RTV return could not be saved. No stock was changed. Please retry.',
      );
    }

    await _sync.schedulePendingSync();
    unawaited(_alerts.checkRtvPending());
    return RtvReinspectionResult(
      success: true,
      recordId: id,
      status: status,
      isEscalated: isEscalated,
    );
  }

  Future<RtvResult> resolveEscalation({
    required String rtvId,
    required String action,
    required String reason,
    required String resolvedBy,
    required UserRole? role,
  }) async {
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) {
      return const RtvResult(
        success: false,
        error: 'No active factory workspace is selected.',
      );
    }
    if (role != UserRole.admin && role != UserRole.owner) {
      return const RtvResult(
        success: false,
        error: 'Only an Admin can resolve an escalated RTV.',
      );
    }
    if (reason.trim().isEmpty) {
      return const RtvResult(
        success: false,
        error: 'Admin decision reason is required.',
      );
    }
    if (action != 'scrapped' && action != 'force_dispatched') {
      return const RtvResult(success: false, error: 'Invalid Admin action.');
    }

    final rows = _db.db.select(
      '''SELECT r.*, COALESCE((
           SELECT SUM(rr.reject_again_qty)
           FROM rtv_reinspections rr
           WHERE rr.factory_id = r.factory_id AND rr.rtv_id = r.id
         ), 0) AS escalated_qty
         FROM rtvs r
         WHERE r.id = ? AND r.factory_id = ? AND r.status = 'escalated' ''',
      [rtvId, factoryId],
    );
    if (rows.isEmpty) {
      return const RtvResult(
        success: false,
        error: 'This RTV is no longer awaiting an Admin decision.',
      );
    }
    final rtv = Map<String, dynamic>.from(rows.single);
    final qty = (rtv['escalated_qty'] as num?)?.toDouble() ?? 0;
    if (qty <= 0) {
      return const RtvResult(
        success: false,
        error: 'No escalated RTV quantity is available to resolve.',
      );
    }

    final auditId = _uuid.v4();
    final now = DateTime.now().toIso8601String();
    final audit = {
      'id': auditId,
      'factory_id': factoryId,
      'table_name': 'rtvs',
      'record_id': rtvId,
      'action': 'resolve_escalation_$action',
      'old_value_json': jsonEncode({'status': 'escalated'}),
      'new_value_json': jsonEncode({
        'status': action,
        'quantity': qty,
        'reason': reason.trim(),
      }),
      'changed_by': resolvedBy,
      'changed_at': now,
      'sync_status': 'pending',
    };

    try {
      await _db.runInTransaction(() async {
        final ledgerResult = action == 'scrapped'
            ? await _ledger.rtvEscalationScrap(
                partId: rtv['part_id'] as String,
                qty: qty,
                refId: rtvId,
                triggerSync: false,
              )
            : await _ledger.rtvEscalationForceDispatch(
                partId: rtv['part_id'] as String,
                qty: qty,
                refId: rtvId,
                triggerSync: false,
              );
        if (!ledgerResult.success) {
          throw StockPostingFailure(
            ledgerResult.error ?? 'Unable to resolve escalated RTV stock.',
          );
        }

        _db.db.execute(
          'UPDATE rtvs SET status = ?, remarks = ?, sync_status = ? '
          'WHERE id = ? AND factory_id = ? AND status = ?',
          [action, reason.trim(), 'pending', rtvId, factoryId, 'escalated'],
        );
        await _sync.queueUpdate(
          tableName: 'rtvs',
          recordId: rtvId,
          payload: {
            'id': rtvId,
            'factory_id': factoryId,
            'status': action,
            'remarks': reason.trim(),
          },
          triggerSync: false,
        );
        await _db.insertRecord('audit_log', audit);
        await _sync.queueInsert(
          tableName: 'audit_log',
          recordId: auditId,
          payload: audit,
          triggerSync: false,
        );
      });
    } on StockPostingFailure catch (error) {
      return RtvResult(success: false, error: error.message);
    } catch (_) {
      return const RtvResult(
        success: false,
        error:
            'RTV decision could not be saved. No stock was changed. Please retry.',
      );
    }

    await _sync.schedulePendingSync();
    return RtvResult(success: true, recordId: rtvId);
  }

  Future<List<Map<String, dynamic>>> getRecent({int limit = 30}) async {
    final factoryId = _db.activeWorkspaceId.trim();
    if (factoryId.isEmpty) return [];
    final rows = _db.db.select(
      'SELECT r.*, p.name as part_name, p.code as part_code, v.name as vendor_name '
      'FROM rtvs r '
      'LEFT JOIN parts p ON p.id = r.part_id AND p.factory_id = r.factory_id '
      'LEFT JOIN vendors v ON v.id = r.vendor_id AND v.factory_id = r.factory_id '
      'WHERE r.factory_id = ? '
      'ORDER BY r.date DESC LIMIT ?',
      [factoryId, limit],
    );
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }
}

final rtvRepositoryProvider = Provider<RtvRepository>((ref) {
  return RtvRepository(
    ref.watch(databaseServiceProvider),
    ref.watch(syncServiceProvider),
    ref.watch(stockLedgerServiceProvider),
    ref.watch(alertProducerServiceProvider),
  );
});

final rtvListProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  return ref.watch(rtvRepositoryProvider).getRecent();
});

final rtvCandidatesProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  return ref.watch(rtvRepositoryProvider).getCandidates();
});

final pendingRtvReturnsProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  return ref.watch(rtvRepositoryProvider).getPendingReturns();
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

class RtvReinspectionResult {
  const RtvReinspectionResult({
    required this.success,
    this.error,
    this.recordId,
    this.status,
    this.isEscalated = false,
  });

  final bool success;
  final String? error;
  final String? recordId;
  final String? status;
  final bool isEscalated;
}
