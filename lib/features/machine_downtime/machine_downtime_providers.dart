import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants/app_constants.dart';
import '../../core/database/database_service.dart';
import '../../core/network/sync_service.dart';

const _uuid = Uuid();

class MachineDowntimeRepository {
  MachineDowntimeRepository(this._db, this._sync);

  final DatabaseService _db;
  final SyncService _sync;

  Future<DowntimeResult> save({
    required String machineId,
    required String startTime,
    String? endTime,
    required String reason,
    String? operatorId,
    String? remarks,
    required String createdBy,
    DateTime? recordedAt,
  }) async {
    // Validate end_time > start_time (PRD 4.3)
    if (endTime != null && endTime.isNotEmpty) {
      final start = _parseTime(startTime);
      final end = _parseTime(endTime);
      if (end != null && start != null && !end.isAfter(start)) {
        return const DowntimeResult(success: false, error: 'End time must be after start time');
      }
    }

    final id = _uuid.v4();
    final now = recordedAt ?? DateTime.now();
    final dateStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

    int? durationMinutes;
    if (endTime != null && endTime.isNotEmpty) {
      final start = _parseTime(startTime);
      final end = _parseTime(endTime);
      if (start != null && end != null) {
        durationMinutes = end.difference(start).inMinutes;
      }
    }

    final record = {
      'id': id,
      'factory_id': AppConstants.defaultFactoryId,
      'machine_id': machineId,
      'date': dateStr,
      'start_time': startTime,
      'end_time': endTime?.isEmpty == true ? null : endTime,
      'duration_minutes': durationMinutes,
      'reason': reason,
      'operator_id': operatorId,
      'remarks': remarks,
      'created_by': createdBy,
      'sync_status': 'pending',
    };

    await _db.insertRecord('machine_downtimes', record);
    await _sync.queueInsert(tableName: 'machine_downtimes', recordId: id, payload: record);

    return DowntimeResult(success: true, recordId: id);
  }

  Future<List<Map<String, dynamic>>> getRecent({int limit = 30}) async {
    final rows = _db.db.select(
      'SELECT md.*, m.name as machine_name, o.name as operator_name '
      'FROM machine_downtimes md '
      'LEFT JOIN machines m ON m.id = md.machine_id '
      'LEFT JOIN operators o ON o.id = md.operator_id '
      'ORDER BY md.date DESC, md.start_time DESC LIMIT ?',
      [limit],
    );
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  DateTime? _parseTime(String timeStr) {
    final parts = timeStr.split(':');
    if (parts.length < 2) return null;
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day,
        int.tryParse(parts[0]) ?? 0, int.tryParse(parts[1]) ?? 0,);
  }
}

final machineDowntimeRepositoryProvider = Provider<MachineDowntimeRepository>((ref) {
  return MachineDowntimeRepository(
    ref.watch(databaseServiceProvider),
    ref.watch(syncServiceProvider),
  );
});

final machineDowntimeListProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  return ref.watch(machineDowntimeRepositoryProvider).getRecent();
});

class DowntimeResult {
  const DowntimeResult({required this.success, this.error, this.recordId});
  final bool success;
  final String? error;
  final String? recordId;
}
