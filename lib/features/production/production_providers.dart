import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

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
  double productionQty;
  double rejectQty;
  String status;
  String remarks;

  double get goodQty => (productionQty - rejectQty).clamp(0, double.infinity);

  MachineEntry copyWith({
    String? operatorId,
    String? operatorName,
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
        productionQty: productionQty ?? this.productionQty,
        rejectQty: rejectQty ?? this.rejectQty,
        status: status ?? this.status,
        remarks: remarks ?? this.remarks,
      );
}

// ─── Repository ───────────────────────────────────────────────────────────────

class ProductionRepository {
  ProductionRepository(this._db, this._sync, this._ledger, this._flow);

  final DatabaseService _db;
  final SyncService _sync;
  final StockLedgerService _ledger;
  final ProductionFlowConfig _flow;

  Future<String> _generateBatchNumber({
    required String partCode,
    required DateTime date,
    required String machineCode,
  }) async {
    final dateStr =
        '${date.year}${date.month.toString().padLeft(2, '0')}${date.day.toString().padLeft(2, '0')}';
    final prefix = '$partCode-$dateStr-$machineCode';
    final existing = _db.db.select(
      'SELECT COUNT(*) as cnt FROM productions WHERE batch_number LIKE ?',
      ['$prefix%'],
    );
    final seq = (existing.first['cnt'] as int) + 1;
    return '$prefix-${seq.toString().padLeft(3, '0')}';
  }

  /// Get good qty of the last completed machine for a batch.
  double? getLastCompletedGoodQty(String batchNumber) {
    final rows = _db.db.select(
      'SELECT good_qty FROM productions WHERE batch_number = ? ORDER BY created_at DESC LIMIT 1',
      [batchNumber],
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

    // Validate WIP batch belongs to same part & validate against last completed stage
    if (existingBatchNumber != null) {
      final check = _db.db.select(
        'SELECT part_id FROM productions WHERE batch_number = ? LIMIT 1',
        [existingBatchNumber],
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

    final now = recordedAt;
    final dateStr =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final timeStr =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    final batchNumber = existingBatchNumber ??
        await _generateBatchNumber(
          partCode: partCode,
          date: now,
          machineCode: entries.first.machineCode,
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

    for (final entry in entries) {
      final id = _uuid.v4();
      final record = {
        'id': id,
        'factory_id': _db.activeWorkspaceId,
        'batch_number': batchNumber,
        'date': dateStr,
        'time': timeStr,
        'part_id': partId,
        'machine_id': entry.machineId,
        'operator_id': entry.operatorId,
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

      final syncPayload = Map<String, dynamic>.from(record)..remove('good_qty');
      await _sync.queueInsert(
        tableName: 'productions',
        recordId: id,
        payload: syncPayload,
      );
    }

    if (!isWip) {
      final finalEntry = entries.lastWhere(
        (e) => e.isFinal,
        orElse: () => entries.last,
      );
      if (finalEntry.goodQty > 0) {
        final ledgerId = _uuid.v4();
        final ledgerResult = await _ledger.productionToBpStock(
          partId: partId,
          goodQty: finalEntry.goodQty,
          refId: ledgerId,
        );
        if (!ledgerResult.success) {
          return (
            batchNumber: batchNumber,
            isWip: false,
            error: ledgerResult.error ?? 'Stock ledger write failed.',
          );
        }
      }
    }

    return (batchNumber: batchNumber, isWip: isWip, error: '');
  }

  List<String> getCompletedMachineIds(String batchNumber) {
    final rows = _db.db.select(
      'SELECT machine_id FROM productions WHERE batch_number = ?',
      [batchNumber],
    );
    return rows.map((r) => r['machine_id'] as String).toList();
  }

  List<String> getPendingMachineIds(String batchNumber) {
    final done = getCompletedMachineIds(batchNumber).toSet();
    return _flow.requiredMachineIds.where((id) => !done.contains(id)).toList();
  }

  /// Returns the first open WIP batch for a given part, or null if none.
  Map<String, dynamic>? getWipBatchForPart(
      String partId, List<String> requiredMachineIds,) {
    if (requiredMachineIds.isEmpty) return null;
    final rows = _db.db.select(
      'SELECT batch_number, part_id, date, '
      'GROUP_CONCAT(machine_id) as done_machines '
      'FROM productions '
      'WHERE factory_id = ? AND part_id = ? '
      'GROUP BY batch_number '
      'ORDER BY date DESC, batch_number DESC LIMIT 20',
      [_db.activeWorkspaceId, partId],
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
    if (required.isEmpty) return [];

    final rows = _db.db.select(
      'SELECT pr.batch_number, pr.part_id, pr.date, '
      'p.name as part_name, p.code as part_code, '
      'GROUP_CONCAT(pr.machine_id) as done_machines '
      'FROM productions pr '
      'LEFT JOIN parts p ON p.id = pr.part_id '
      'WHERE pr.factory_id = ? '
      'GROUP BY pr.batch_number, pr.part_id '
      'ORDER BY pr.date DESC, pr.batch_number DESC LIMIT 200',
      [_db.activeWorkspaceId],
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
        map['last_good_qty'] = getLastCompletedGoodQty(row['batch_number'] as String) ?? 0.0;
        wip.add(map);
      }
    }
    return wip;
  }

  List<Map<String, dynamic>> getBatchRecords(String batchNumber) {
    final rows = _db.db.select(
      'SELECT pr.*, m.name as machine_name, m.machine_code, o.name as operator_name '
      'FROM productions pr '
      'LEFT JOIN machines m ON m.id = pr.machine_id '
      'LEFT JOIN operators o ON o.id = pr.operator_id '
      'WHERE pr.batch_number = ? '
      'ORDER BY pr.created_at ASC',
      [batchNumber],
    );
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  Future<List<Map<String, dynamic>>> getRecent({int limit = 50}) async {
    final rows = _db.db.select(
      'SELECT pr.*, p.name as part_name, p.code as part_code, '
      'm.name as machine_name, m.sequence_order, o.name as operator_name '
      'FROM productions pr '
      'LEFT JOIN parts p ON p.id = pr.part_id '
      'LEFT JOIN machines m ON m.id = pr.machine_id '
      'LEFT JOIN operators o ON o.id = pr.operator_id '
      'WHERE pr.factory_id = ? '
      'ORDER BY pr.created_at DESC LIMIT ?',
      [_db.activeWorkspaceId, limit],
    );
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }
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
