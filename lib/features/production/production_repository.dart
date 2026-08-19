import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants/app_constants.dart';
import '../../core/constants/stock_stages.dart';
import '../../core/database/database_service.dart';
import '../../core/network/sync_service.dart';
import '../../core/providers/production_flow_provider.dart';
import '../../core/services/stock_ledger_service.dart';

const _uuid = Uuid();

const kMachineStatuses = ['Running', 'Breakdown', 'Maintenance', 'Idle'];

// ─── Models ───────────────────────────────────────────────────────────────────

class MachineEntry {
  MachineEntry({
    required this.machineId,
    required this.machineName,
    required this.machineCode,
    required this.sequenceIndex,
    required this.isFinal,
    required this.operatorId,
    required this.operatorName,
    required this.shiftId,
    required this.productionQty,
    required this.rejectQty,
    this.status = 'Running',
    this.remarks = '',
  });

  final String machineId;
  final String machineName;
  final String machineCode;
  final int sequenceIndex;
  final bool isFinal;
  final String operatorId;
  final String operatorName;
  final String shiftId;
  double productionQty;
  double rejectQty;
  String status;
  String remarks;

  double get goodQty => (productionQty - rejectQty).clamp(0, double.infinity);

  MachineEntry copyWith({
    String? operatorId,
    String? operatorName,
    String? shiftId,
    double? productionQty,
    double? rejectQty,
    String? status,
    String? remarks,
  }) =>
      MachineEntry(
        machineId: machineId,
        machineName: machineName,
        machineCode: machineCode,
        sequenceIndex: sequenceIndex,
        isFinal: isFinal,
        operatorId: operatorId ?? this.operatorId,
        operatorName: operatorName ?? this.operatorName,
        shiftId: shiftId ?? this.shiftId,
        productionQty: productionQty ?? this.productionQty,
        rejectQty: rejectQty ?? this.rejectQty,
        status: status ?? this.status,
        remarks: remarks ?? this.remarks,
      );
}

// ─── Repository ───────────────────────────────────────────────────────────────

class ProductionRepository {
  ProductionRepository(
    this._db,
    this._sync,
    this._ledger,
    this._flow, [
    this._atomicProductionSyncEnabled =
        AppConstants.atomicProductionSyncEnabled,
  ]);

  final DatabaseService _db;
  final SyncService _sync;
  final StockLedgerService _ledger;
  final ProductionFlowConfig _flow;
  final bool _atomicProductionSyncEnabled;

  String? get _activeFactoryId {
    final factoryId = _db.activeWorkspaceId.trim();
    return factoryId.isEmpty ? null : factoryId;
  }

  Future<String> _generateBatchNumber({
    required String partCode,
    required DateTime date,
    required String factoryId,
  }) async {
    final dateStr = '${(date.year % 100).toString().padLeft(2, '0')}'
        '${date.month.toString().padLeft(2, '0')}'
        '${date.day.toString().padLeft(2, '0')}';
    final prefix = '$partCode-$dateStr';
    final existing = _db.db.select(
      'SELECT COUNT(DISTINCT batch_number) as cnt FROM productions '
      'WHERE factory_id = ? AND batch_number LIKE ?',
      [factoryId, '$prefix%'],
    );
    final seq = (existing.first['cnt'] as int) + 1;
    return AppConstants.batchNumberPattern(partCode, date, seq);
  }

  /// Get good qty of the last completed machine for a batch.
  double? getLastCompletedGoodQty(String batchNumber) {
    final factoryId = _activeFactoryId;
    if (factoryId == null) return null;
    final rows = _db.db.select(
      'SELECT good_qty FROM productions '
      'WHERE factory_id = ? AND batch_number = ? '
      'ORDER BY created_at DESC LIMIT 1',
      [factoryId, batchNumber],
    );
    if (rows.isNotEmpty) {
      return (rows.first['good_qty'] as num?)?.toDouble();
    }
    return null;
  }

  /// Save a list of [MachineEntry] records for one production job.
  Future<({String batchNumber, bool isWip, String error})> saveJob({
    required String partId,
    required String partCode,
    required List<MachineEntry> entries,
    required String createdBy,
    required DateTime recordedAt,
    String? existingBatchNumber,
  }) async {
    if (entries.isEmpty) {
      return (batchNumber: '', isWip: false, error: 'No entries to save.');
    }

    final flowError = _flow.validationError;
    if (flowError != null) {
      return (
        batchNumber: '',
        isWip: false,
        error: '$flowError Open Settings > Production Flow and review it.',
      );
    }

    final factoryId = _activeFactoryId;
    if (factoryId == null) {
      return (
        batchNumber: '',
        isWip: false,
        error:
            'No active factory workspace is selected. Open Settings and select a workspace.',
      );
    }

    // Validate: each stage qty <= previous stage good qty
    for (int i = 1; i < entries.length; i++) {
      final prevGood = entries[i - 1].goodQty;
      if (entries[i].productionQty > prevGood) {
        return (
          batchNumber: '',
          isWip: false,
          error:
              '${entries[i].machineName} qty (${entries[i].productionQty.toInt()}) '
              'exceeds ${entries[i - 1].machineName} good qty (${prevGood.toInt()}).',
        );
      }
    }

    for (final entry in entries) {
      if (entry.rejectQty > entry.productionQty) {
        return (
          batchNumber: '',
          isWip: false,
          error:
              '${entry.machineName}: reject quantity cannot exceed input quantity.',
        );
      }
    }

    // Validate WIP batch belongs to same part & validate against last completed stage
    if (existingBatchNumber != null) {
      final check = _db.db.select(
        'SELECT part_id FROM productions '
        'WHERE factory_id = ? AND batch_number = ? LIMIT 1',
        [factoryId, existingBatchNumber],
      );
      if (check.isNotEmpty && check.first['part_id'] != partId) {
        return (
          batchNumber: '',
          isWip: false,
          error: 'This WIP batch belongs to a different part.',
        );
      }

      final lastGood = getLastCompletedGoodQty(existingBatchNumber);
      if (lastGood != null && entries.first.productionQty > lastGood) {
        return (
          batchNumber: '',
          isWip: false,
          error:
              'First machine (${entries.first.machineName}) qty (${entries.first.productionQty.toInt()}) '
              'exceeds previous completed stage good qty (${lastGood.toInt()}).',
        );
      }
    }

    // ─── Duplicate Stage Validation (Before local SQLite insert) ─────────────
    final submittedMachineIds = <String>{};
    for (final entry in entries) {
      if (submittedMachineIds.contains(entry.machineId)) {
        final auditId = _uuid.v4();
        await _db.writeAuditLog(
          id: auditId,
          tableName: 'productions',
          recordId: entry.machineId,
          action: 'DUPLICATE_STAGE_BLOCKED',
          changedBy: createdBy,
          newValue: {
            'batch_number': existingBatchNumber ?? 'NEW_BATCH',
            'machine_id': entry.machineId,
            'machine_name': entry.machineName,
            'user_id': createdBy,
            'device_id': 'mobile',
            'reason': 'Duplicate machine ID within same submission.',
            'timestamp': DateTime.now().toIso8601String(),
          },
        );
        return (
          batchNumber: existingBatchNumber ?? '',
          isWip: false,
          error:
              'This production stage has already been completed by another user or device.',
        );
      }
      submittedMachineIds.add(entry.machineId);
    }

    if (existingBatchNumber != null) {
      final existingDoneMachineIds =
          getCompletedMachineIds(existingBatchNumber);
      for (final entry in entries) {
        if (existingDoneMachineIds.contains(entry.machineId)) {
          final auditId = _uuid.v4();
          await _db.writeAuditLog(
            id: auditId,
            tableName: 'productions',
            recordId: entry.machineId,
            action: 'DUPLICATE_STAGE_BLOCKED',
            changedBy: createdBy,
            newValue: {
              'batch_number': existingBatchNumber,
              'machine_id': entry.machineId,
              'machine_name': entry.machineName,
              'user_id': createdBy,
              'device_id': 'mobile',
              'reason':
                  'Machine ${entry.machineName} already completed for batch $existingBatchNumber.',
              'timestamp': DateTime.now().toIso8601String(),
            },
          );

          return (
            batchNumber: existingBatchNumber,
            isWip: false,
            error:
                'This production stage has already been completed by another user or device.',
          );
        }
      }
    }

    final now = recordedAt;
    final dateStr =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final timeStr =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    final batchNumber = existingBatchNumber ??
        await _generateBatchNumber(
          partCode: partCode,
          date: now,
          factoryId: factoryId,
        );

    final savedMachineIds = existingBatchNumber != null
        ? getCompletedMachineIds(existingBatchNumber)
        : <String>[];

    for (final entry in entries) {
      savedMachineIds.add(entry.machineId);
    }

    final allRequired = _flow.requiredMachineIds;
    final isComplete = !_flow.isMultiStage ||
        allRequired.every((id) => savedMachineIds.contains(id));
    final isWip = !isComplete;
    final deviceId = await _db.getOrCreateDeviceId();

    // Validate the complete batch before recording anything. The in-memory
    // balances include earlier entries in this same submission, so Bending →
    // Notching → End Forming can be saved together without falsely reporting
    // an insufficient WIP balance.
    final projectedBalances = <String, double>{};
    for (final entry in entries) {
      final route = _stockRouteFor(entry);
      final available = projectedBalances[route.inputStage] ??
          await _ledger.getAvailableStockAtStage(partId, route.inputStage);
      if (entry.productionQty > available) {
        return (
          batchNumber: batchNumber,
          isWip: isWip,
          error:
              'Insufficient ${route.inputStageLabel} stock for ${entry.machineName}. '
              'Available: ${available.toInt()} PCS.',
        );
      }
      projectedBalances[route.inputStage] = available - entry.productionQty;
      projectedBalances[route.outputStage] =
          (projectedBalances[route.outputStage] ??
                  await _ledger.getAvailableStockAtStage(
                    partId,
                    route.outputStage,
                  )) +
              entry.goodQty;
    }

    try {
      await _db.runInTransaction(() async {
        for (final entry in entries) {
          final id = _uuid.v4();
          final route = _stockRouteFor(entry);

          final ledgerResult = await _ledger.moveThroughProductionStage(
            partId: partId,
            inputStage: route.inputStage,
            inputStageLabel: route.inputStageLabel,
            outputStage: route.outputStage,
            outputStageLabel: route.outputStageLabel,
            inputQty: entry.productionQty,
            goodQty: entry.goodQty,
            rejectQty: entry.rejectQty,
            refId: id,
            triggerSync: false,
            queueForSync: !_atomicProductionSyncEnabled,
          );
          if (!ledgerResult.success) {
            throw _ProductionPostingFailure(
              ledgerResult.error ?? 'Unable to update production stock.',
            );
          }

          final record = {
            'id': id,
            'factory_id': factoryId,
            'batch_number': batchNumber,
            'date': dateStr,
            'time': timeStr,
            'part_id': partId,
            'machine_id': entry.machineId,
            'operator_id': entry.operatorId,
            'shift_id': entry.shiftId,
            'machine_status_id': entry.status,
            'production_qty': entry.productionQty,
            'bp_reject_qty': entry.rejectQty,
            'good_qty': entry.goodQty,
            'remarks': entry.remarks.isEmpty ? null : entry.remarks,
            'created_by': createdBy,
            'created_at': now.toIso8601String(),
            'sync_status': 'pending',
          };
          await _db.insertRecord('productions', record);

          final syncPayload = Map<String, dynamic>.from(record)
            ..remove('good_qty')
            ..remove('sync_status');
          if (_atomicProductionSyncEnabled) {
            final ledgerEntries = await _db.getProductionLedgerEntries(id);
            await _sync.queueProductionPost(
              recordId: id,
              payload: {
                'command_id': id,
                'device_id': deviceId,
                'user_id': createdBy,
                'factory_id': factoryId,
                'created_at': now.toUtc().toIso8601String(),
                'schema_version': AppConstants.syncEnvelopeSchemaVersion,
                'app_version': AppConstants.appVersion,
                'production': syncPayload,
                'ledger_entries': ledgerEntries,
              },
              triggerSync: false,
            );
          } else {
            await _sync.queueInsert(
              tableName: 'productions',
              recordId: id,
              payload: syncPayload,
              triggerSync: false,
            );
          }
        }
      });
    } on _ProductionPostingFailure catch (error) {
      return (
        batchNumber: batchNumber,
        isWip: isWip,
        error: '${error.message} No stock was changed.',
      );
    } catch (_) {
      return (
        batchNumber: batchNumber,
        isWip: isWip,
        error:
            'Production could not be saved. No stock was changed. Please retry.',
      );
    }

    await _sync.schedulePendingSync();
    return (batchNumber: batchNumber, isWip: isWip, error: '');
  }

  _ProductionStockRoute _stockRouteFor(MachineEntry entry) {
    if (!_flow.isMultiStage) {
      return const _ProductionStockRoute(
        inputStage: 'raw_material',
        inputStageLabel: 'Raw Material',
        outputStage: 'bp_stock',
        outputStageLabel: 'Finished Production',
      );
    }

    final sequenceIndex = _flow.requiredMachineIds.indexOf(entry.machineId);
    final inputStage = sequenceIndex <= 0
        ? 'raw_material'
        : productionWipStage(_flow.requiredMachineIds[sequenceIndex - 1]);
    final inputLabel =
        sequenceIndex <= 0 ? 'Raw Material' : 'Previous Machine WIP';
    final outputStage =
        entry.isFinal ? 'bp_stock' : productionWipStage(entry.machineId);

    return _ProductionStockRoute(
      inputStage: inputStage,
      inputStageLabel: inputLabel,
      outputStage: outputStage,
      outputStageLabel:
          entry.isFinal ? 'Finished Production' : '${entry.machineName} WIP',
    );
  }

  List<String> getCompletedMachineIds(String batchNumber) {
    final factoryId = _activeFactoryId;
    if (factoryId == null) return [];
    final rows = _db.db.select(
      'SELECT machine_id FROM productions '
      'WHERE factory_id = ? AND batch_number = ?',
      [factoryId, batchNumber],
    );
    return rows.map((r) => r['machine_id'] as String).toList();
  }

  List<String> getPendingMachineIds(String batchNumber) {
    final done = getCompletedMachineIds(batchNumber).toSet();
    return _flow.requiredMachineIds.where((id) => !done.contains(id)).toList();
  }

  /// Returns the first open WIP batch for a given part, or null if none.
  Map<String, dynamic>? getWipBatchForPart(
    String partId,
    List<String> requiredMachineIds,
  ) {
    final factoryId = _activeFactoryId;
    if (factoryId == null || requiredMachineIds.isEmpty) return null;
    final rows = _db.db.select(
      'SELECT batch_number, part_id, date, '
      'GROUP_CONCAT(machine_id) as done_machines '
      'FROM productions '
      'WHERE factory_id = ? AND part_id = ? '
      'GROUP BY batch_number '
      'ORDER BY date DESC, batch_number DESC LIMIT 20',
      [factoryId, partId],
    );
    for (final row in rows) {
      final done = (row['done_machines'] as String? ?? '')
          .split(',')
          .where((s) => s.isNotEmpty)
          .toSet();
      final missing =
          requiredMachineIds.where((id) => !done.contains(id)).toList();
      if (missing.isNotEmpty) {
        final batchNum = row['batch_number'] as String;
        final lastGood = getLastCompletedGoodQty(batchNum);
        return {
          'batch_number': batchNum,
          'part_id': row['part_id'],
          'date': row['date'],
          'done_machine_ids': done.toList(),
          'missing_machine_ids': missing,
          'next_machine_id': missing.first,
          'last_good_qty': lastGood ?? 0.0,
        };
      }
    }
    return null;
  }

  Future<List<Map<String, dynamic>>> getWipBatches() async {
    final required = _flow.requiredMachineIds;
    final factoryId = _activeFactoryId;
    if (factoryId == null || required.isEmpty) return [];

    final rows = _db.db.select(
      'SELECT pr.batch_number, pr.part_id, pr.date, '
      'p.name as part_name, p.code as part_code, '
      'GROUP_CONCAT(pr.machine_id) as done_machines '
      'FROM productions pr '
      'LEFT JOIN parts p ON p.id = pr.part_id '
      'AND p.factory_id = pr.factory_id '
      'WHERE pr.factory_id = ? '
      'GROUP BY pr.batch_number, pr.part_id '
      'ORDER BY pr.date DESC, pr.batch_number DESC LIMIT 200',
      [factoryId],
    );

    final wip = <Map<String, dynamic>>[];
    for (final row in rows) {
      final done = (row['done_machines'] as String? ?? '')
          .split(',')
          .where((s) => s.isNotEmpty)
          .toSet();
      final missing = required.where((id) => !done.contains(id)).toList();
      if (missing.isNotEmpty) {
        final map = Map<String, dynamic>.from(row);
        map['done_machine_ids'] = done.toList();
        map['missing_machine_ids'] = missing;
        map['next_machine_id'] = missing.first;
        map['last_good_qty'] =
            getLastCompletedGoodQty(row['batch_number'] as String) ?? 0.0;
        wip.add(map);
      }
    }
    return wip;
  }

  List<Map<String, dynamic>> getBatchRecords(String batchNumber) {
    final factoryId = _activeFactoryId;
    if (factoryId == null) return [];
    final rows = _db.db.select(
      'SELECT pr.*, m.name as machine_name, m.machine_code, o.name as operator_name '
      'FROM productions pr '
      'LEFT JOIN machines m ON m.id = pr.machine_id '
      'AND m.factory_id = pr.factory_id '
      'LEFT JOIN operators o ON o.id = pr.operator_id '
      'AND o.factory_id = pr.factory_id '
      'WHERE pr.factory_id = ? AND pr.batch_number = ? '
      'ORDER BY pr.created_at ASC',
      [factoryId, batchNumber],
    );
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  Future<List<Map<String, dynamic>>> getRecent({int limit = 50}) async {
    final factoryId = _activeFactoryId;
    if (factoryId == null) return [];
    final rows = _db.db.select(
      'SELECT pr.*, p.name as part_name, p.code as part_code, '
      'm.name as machine_name, m.sequence_order, o.name as operator_name '
      'FROM productions pr '
      'LEFT JOIN parts p ON p.id = pr.part_id '
      'AND p.factory_id = pr.factory_id '
      'LEFT JOIN machines m ON m.id = pr.machine_id '
      'AND m.factory_id = pr.factory_id '
      'LEFT JOIN operators o ON o.id = pr.operator_id '
      'AND o.factory_id = pr.factory_id '
      'WHERE pr.factory_id = ? '
      'ORDER BY pr.created_at DESC LIMIT ?',
      [factoryId, limit],
    );
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }
}

class _ProductionStockRoute {
  const _ProductionStockRoute({
    required this.inputStage,
    required this.inputStageLabel,
    required this.outputStage,
    required this.outputStageLabel,
  });

  final String inputStage;
  final String inputStageLabel;
  final String outputStage;
  final String outputStageLabel;
}

class _ProductionPostingFailure implements Exception {
  const _ProductionPostingFailure(this.message);

  final String message;
}

final productionRepositoryProvider = Provider<ProductionRepository>((ref) {
  return ProductionRepository(
    ref.watch(databaseServiceProvider),
    ref.watch(syncServiceProvider),
    ref.watch(stockLedgerServiceProvider),
    ref.watch(productionFlowProvider),
  );
});

final productionListProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  return ref.watch(productionRepositoryProvider).getRecent();
});

final wipBatchesProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final flow = ref.watch(productionFlowProvider);
  if (!flow.enabled || flow.requiredMachineIds.isEmpty) return [];
  return ref.watch(productionRepositoryProvider).getWipBatches();
});

/// Fast, read-only stock check used by the production header. Showing this
/// before entry saves operators from completing a form that cannot be posted.
final productionRawMaterialProvider =
    FutureProvider.family<double, String>((ref, partId) {
  return ref.watch(stockLedgerServiceProvider).getAvailableStock(
        partId,
        StockStage.rawMaterial,
      );
});
