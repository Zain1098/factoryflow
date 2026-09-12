import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/stock_stages.dart';
import '../../core/database/database_service.dart';
import '../../core/providers/production_flow_provider.dart';
import '../../core/widgets/shared_widgets.dart';

// ─── Date Range Model ─────────────────────────────────────────────────────────

class DateRange {
  const DateRange(this.from, this.to);
  final DateTime from;
  final DateTime to;

  String get fromStr => _fmt(from);
  String get toStr => _fmt(to);

  static String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static DateRange today() {
    final now = DateTime.now();
    return DateRange(now, now);
  }

  static DateRange thisWeek() {
    final now = DateTime.now();
    final from = now.subtract(Duration(days: now.weekday - 1));
    return DateRange(from, now);
  }

  static DateRange yesterday() {
    final y = DateTime.now().subtract(const Duration(days: 1));
    return DateRange(y, y);
  }

  static DateRange thisMonth() {
    final now = DateTime.now();
    return DateRange(DateTime(now.year, now.month, 1), now);
  }

  static DateRange last30() {
    final now = DateTime.now();
    return DateRange(now.subtract(const Duration(days: 29)), now);
  }
}

// ─── Shift Filter Provider ───────────────────────────────────────────────────
/// null = All Shifts, 'A' = Shift A, 'B' = Shift B, 'C' = Shift C
class _ShiftFilterNotifier extends Notifier<String?> {
  @override
  String? build() => null;
  void set(String? s) => state = s;
}

final reportShiftFilterProvider =
    NotifierProvider<_ShiftFilterNotifier, String?>(_ShiftFilterNotifier.new);

// ─── Date Range Provider ──────────────────────────────────────────────────────

class _DateRangeNotifier extends Notifier<DateRange> {
  @override
  DateRange build() => DateRange.thisMonth();
  void set(DateRange r) => state = r;
}

final reportDateRangeProvider =
    NotifierProvider<_DateRangeNotifier, DateRange>(_DateRangeNotifier.new);

// ─── 1. Daily Production Report ───────────────────────────────────────────────

class DailyPartProduction {
  const DailyPartProduction({
    required this.partId,
    required this.partName,
    required this.partCode,
    required this.qty,
    this.goodQty = 0,
    this.rejectQty = 0,
  });
  final String partId;
  final String partName;
  final String partCode;
  final double qty;
  final double goodQty;
  final double rejectQty;
}

class DailyProductionRow {
  const DailyProductionRow({
    required this.date,
    required this.totalProduction,
    required this.bpReject,
    required this.goodQty,
    required this.target,
    required this.efficiency,
    required this.rejectPct,
    this.shiftAGood = 0,
    this.shiftBGood = 0,
    this.shiftCGood = 0,
    this.shiftAProd = 0,
    this.shiftBProd = 0,
    this.shiftCProd = 0,
    this.downtimeMinutes = 0,
    this.parts = const [],
  });
  final String date;
  final double totalProduction;
  final double bpReject;
  final double goodQty;
  final double target;
  final double efficiency;
  final double rejectPct;
  final double shiftAGood;
  final double shiftBGood;
  final double shiftCGood;
  final double shiftAProd;
  final double shiftBProd;
  final double shiftCProd;
  final int downtimeMinutes;
  final List<DailyPartProduction> parts;

  String get partsSummary => parts.isEmpty
      ? '—'
      : parts.map((p) => '${p.partName} (${p.qty.toInt()} PCS)').join(', ');
}

final dailyProductionReportProvider =
    FutureProvider.autoDispose<List<DailyProductionRow>>((ref) async {
  final db = ref.watch(databaseServiceProvider);
  final range = ref.watch(reportDateRangeProvider);
  final flow = ref.watch(productionFlowProvider);
  final shiftFilter = ref.watch(reportShiftFilterProvider);
  final factoryId = db.activeWorkspaceId.trim();
  if (factoryId.isEmpty) return [];

  // Active machine sequence order
  final machineRows = db.db.select(
    'SELECT id, name, sequence_order FROM machines WHERE factory_id = ? AND active = 1 ORDER BY sequence_order ASC, id ASC',
    [factoryId],
  );
  final machineSeqMap = <String, int>{};
  for (var i = 0; i < machineRows.length; i++) {
    final mId = machineRows[i]['id']?.toString() ?? '';
    final seq = (machineRows[i]['sequence_order'] as num?)?.toInt() ?? (i + 1);
    machineSeqMap[mId] = seq;
  }
  final effectiveFinalMachineId = (flow.isMultiStage && flow.requiredMachineIds.isNotEmpty)
      ? flow.requiredMachineIds.last
      : (machineRows.isNotEmpty ? machineRows.last['id']?.toString() : null);

  // 1. Fetch raw production entries within date range with part info
  final prodRows = db.db.select(
    '''
    SELECT
      p.date,
      p.machine_id,
      p.shift_id,
      p.part_id,
      pt.name AS part_name,
      pt.code AS part_code,
      s.name AS shift_name,
      COALESCE(p.production_qty, 0) AS prod_qty,
      COALESCE(p.bp_reject_qty, 0) AS rej_qty,
      COALESCE(p.good_qty, p.production_qty - COALESCE(p.bp_reject_qty, 0)) AS good_qty
    FROM productions p
    LEFT JOIN parts pt ON pt.id = p.part_id AND pt.factory_id = p.factory_id
    LEFT JOIN shifts s ON s.id = p.shift_id AND s.factory_id = p.factory_id
    WHERE p.factory_id = ? AND p.date BETWEEN ? AND ?
    ORDER BY p.date DESC
    ''',
    [factoryId, range.fromStr, range.toStr],
  );

  // 2. Fetch downtime grouped by date
  final dtRows = db.db.select(
    '''
    SELECT date, COALESCE(SUM(duration_minutes), 0) AS dt_mins
    FROM machine_downtimes
    WHERE factory_id = ? AND date BETWEEN ? AND ?
    GROUP BY date
    ''',
    [factoryId, range.fromStr, range.toStr],
  );
  final downtimeMap = <String, int>{};
  for (final r in dtRows) {
    final d = r['date'] as String?;
    if (d != null) {
      downtimeMap[d] = ((r['dt_mins'] ?? r['duration_minutes']) as num?)?.toInt() ?? 0;
    }
  }

  // 3. Fetch day-of-week targets
  final targetRows = db.db.select(
    '''
    SELECT day_of_week, SUM(target_qty) AS target
    FROM target_master
    WHERE factory_id = ?
    GROUP BY day_of_week
    ''',
    [factoryId],
  );
  final targetMap = <int, double>{};
  for (final r in targetRows) {
    final dow = ((r['day_of_week']) as num?)?.toInt();
    if (dow != null) {
      targetMap[dow] = ((r['target'] ?? r['target_qty']) as num?)?.toDouble() ?? 0.0;
    }
  }

  // 4. Group production entries by date
  final groupedByDate = <String, List<Map<String, dynamic>>>{};
  for (final row in prodRows) {
    final date = row['date']?.toString();
    if (date != null && date.isNotEmpty) {
      groupedByDate.putIfAbsent(date, () => []).add(row);
    }
  }

  // Ensure dates with downtime are also included if relevant
  for (final d in downtimeMap.keys) {
    groupedByDate.putIfAbsent(d, () => []);
  }

  final sortedDates = groupedByDate.keys.toList()..sort((a, b) => b.compareTo(a));

  final dailyRows = <DailyProductionRow>[];

  for (final d in sortedDates) {
    final rowsForDate = groupedByDate[d]!;
    final dtMins = downtimeMap[d] ?? 0;

    // Filter by shift if shiftFilter is applied
    final filteredRows = rowsForDate.where((row) {
      if (shiftFilter == null || shiftFilter.isEmpty) return true;
      final shiftStr = (row['shift_name'] as String?) ??
          (row['shift_id'] as String?) ??
          '';
      return shiftStr.toUpperCase().contains(shiftFilter.toUpperCase());
    }).toList();

    // Rejections across all machines on this date (actual loss)
    double dayTotalReject = 0.0;
    for (final row in filteredRows) {
      final rej = ((row['rej_qty'] ?? row['bp_reject_qty']) as num?)?.toDouble() ?? 0.0;
      dayTotalReject += rej;
    }

    // Group filtered rows by part_id
    final partGroups = <String, List<Map<String, dynamic>>>{};
    for (final row in filteredRows) {
      final partId = row['part_id']?.toString() ?? 'unknown';
      partGroups.putIfAbsent(partId, () => []).add(row);
    }

    double dayTotalProd = 0.0;
    double dayTotalGood = 0.0;
    double shiftAGood = 0.0;
    double shiftAProd = 0.0;
    double shiftBGood = 0.0;
    double shiftBProd = 0.0;
    double shiftCGood = 0.0;
    double shiftCProd = 0.0;

    final partsList = <DailyPartProduction>[];

    for (final entry in partGroups.entries) {
      final partId = entry.key;
      final pRows = entry.value;
      final partName = pRows.first['part_name'] as String? ?? 'Part';
      final partCode = pRows.first['part_code'] as String? ?? '';

      // Determine the final/furthest machine stage for this part on this date
      // to avoid summing across multiple machines for the same piece flow
      final hasFinalMachineEntry = effectiveFinalMachineId != null &&
          pRows.any((r) => r['machine_id'] == effectiveFinalMachineId);

      final String selectedMachineId;
      if (hasFinalMachineEntry) {
        selectedMachineId = effectiveFinalMachineId;
      } else if (pRows.length > 1) {
        // Pick the machine with the highest sequence order
        Map<String, dynamic>? furthestRow;
        int maxSeq = -1;
        for (final r in pRows) {
          final mId = r['machine_id']?.toString() ?? '';
          final seq = machineSeqMap[mId] ?? 0;
          if (seq > maxSeq) {
            maxSeq = seq;
            furthestRow = r;
          }
        }
        selectedMachineId = furthestRow?['machine_id']?.toString() ??
            pRows.last['machine_id']?.toString() ??
            '';
      } else {
        selectedMachineId = pRows.first['machine_id']?.toString() ?? '';
      }

      final stageRows =
          pRows.where((r) => r['machine_id'] == selectedMachineId).toList();

      double partProd = 0.0;
      double partGood = 0.0;
      double partRej = 0.0;

      for (final r in stageRows) {
        final prod = ((r['prod_qty'] ?? r['production_qty']) as num?)?.toDouble() ?? 0.0;
        final rej = ((r['rej_qty'] ?? r['bp_reject_qty']) as num?)?.toDouble() ?? 0.0;
        final good = ((r['good_qty']) as num?)?.toDouble() ??
            (prod - rej).clamp(0.0, double.infinity);

        partProd += prod;
        partGood += good;
        partRej += rej;

        // Shift breakdown for this part
        final shiftStr = ((r['shift_name'] as String?) ??
                (r['shift_id'] as String?) ??
                '')
            .toUpperCase();
        if (shiftStr.contains('B') || shiftStr == 'B') {
          shiftBProd += prod;
          shiftBGood += good;
        } else if (shiftStr.contains('C') || shiftStr == 'C') {
          shiftCProd += prod;
          shiftCGood += good;
        } else {
          shiftAProd += prod;
          shiftAGood += good;
        }
      }

      dayTotalProd += partProd;
      dayTotalGood += partGood;

      if (partProd > 0 || partGood > 0) {
        partsList.add(
          DailyPartProduction(
            partId: partId,
            partName: partName,
            partCode: partCode,
            qty: partGood > 0 ? partGood : partProd,
            goodQty: partGood,
            rejectQty: partRej,
          ),
        );
      }
    }

    // Sort parts by qty descending
    partsList.sort((a, b) => b.qty.compareTo(a.qty));

    // Calculate target for this weekday: SQLite strftime('%w') 0=Sunday, 6=Saturday.
    double target = 0.0;
    try {
      final parsed = DateTime.parse(d);
      final sqliteDow = parsed.weekday % 7; // Sunday (7) becomes 0
      target = targetMap[sqliteDow] ?? 0.0;
    } catch (_) {}

    final efficiency =
        target > 0 ? (dayTotalGood / target * 100).clamp(0.0, 999.0) : 0.0;
    final rejectPct =
        dayTotalProd > 0 ? (dayTotalReject / dayTotalProd * 100) : 0.0;

    dailyRows.add(
      DailyProductionRow(
        date: d,
        totalProduction: dayTotalProd,
        bpReject: dayTotalReject,
        goodQty: dayTotalGood,
        target: target,
        efficiency: efficiency,
        rejectPct: rejectPct,
        shiftAGood: shiftAGood,
        shiftBGood: shiftBGood,
        shiftCGood: shiftCGood,
        shiftAProd: shiftAProd,
        shiftBProd: shiftBProd,
        shiftCProd: shiftCProd,
        downtimeMinutes: dtMins,
        parts: partsList,
      ),
    );
  }

  return dailyRows.where((r) {
    // If shift filtered, only return rows that have activity or downtime
    if (shiftFilter != null && shiftFilter.isNotEmpty) {
      return r.totalProduction > 0 || r.bpReject > 0 || r.goodQty > 0;
    }
    return true;
  }).toList();
});

// ─── 2. Machine-wise Report ───────────────────────────────────────────────────

class MachineReportRow {
  const MachineReportRow({
    required this.machineName,
    required this.totalProduction,
    required this.bpReject,
    required this.goodQty,
    required this.rejectPct,
    required this.downtimeMinutes,
    required this.runDays,
  });
  final String machineName;
  final double totalProduction;
  final double bpReject;
  final double goodQty;
  final double rejectPct;
  final int downtimeMinutes;
  final int runDays;
}

final machineReportProvider =
    FutureProvider.autoDispose<List<MachineReportRow>>((ref) async {
  final db = ref.watch(databaseServiceProvider);
  final range = ref.watch(reportDateRangeProvider);
  final factoryId = db.activeWorkspaceId.trim();
  if (factoryId.isEmpty) return [];

  final rows = db.db.select(
    '''
    SELECT
      m.name AS machine_name,
      COALESCE(SUM(p.production_qty), 0) AS total_prod,
      COALESCE(SUM(p.bp_reject_qty), 0) AS bp_rej,
      COALESCE(SUM(p.good_qty), 0) AS good,
      COUNT(DISTINCT p.date) AS run_days,
      COALESCE(dt.downtime_mins, 0) AS downtime_mins
    FROM machines m
    LEFT JOIN productions p ON p.factory_id = m.factory_id
      AND p.machine_id = m.id AND p.date BETWEEN ? AND ?
    LEFT JOIN (
      SELECT factory_id, machine_id, SUM(duration_minutes) AS downtime_mins
      FROM machine_downtimes
      WHERE factory_id = ? AND date BETWEEN ? AND ?
      GROUP BY factory_id, machine_id
    ) dt ON dt.factory_id = m.factory_id AND dt.machine_id = m.id
    WHERE m.factory_id = ? AND m.active = 1
    GROUP BY m.id, m.name
    ORDER BY total_prod DESC
  ''',
    [
      range.fromStr,
      range.toStr,
      factoryId,
      range.fromStr,
      range.toStr,
      factoryId,
    ],
  );

  return rows.map((r) {
    final prod = ((r['total_prod'] ?? r['production_qty']) as num?)?.toDouble() ?? 0.0;
    final bp = ((r['bp_rej'] ?? r['bp_reject_qty']) as num?)?.toDouble() ?? 0.0;
    return MachineReportRow(
      machineName: r['machine_name'] as String? ?? '—',
      totalProduction: prod,
      bpReject: bp,
      goodQty: ((r['good'] ?? r['good_qty']) as num?)?.toDouble() ?? 0.0,
      rejectPct: prod > 0 ? (bp / prod * 100) : 0,
      downtimeMinutes: ((r['downtime_mins'] ?? r['duration_minutes']) as num?)?.toInt() ?? 0,
      runDays: ((r['run_days']) as num?)?.toInt() ?? 0,
    );
  }).toList();
});

// ─── 3. Operator-wise Report ──────────────────────────────────────────────────

class OperatorReportRow {
  const OperatorReportRow({
    required this.operatorName,
    required this.totalProduction,
    required this.bpReject,
    required this.goodQty,
    required this.rejectPct,
    required this.runDays,
    required this.avgPerDay,
  });
  final String operatorName;
  final double totalProduction;
  final double bpReject;
  final double goodQty;
  final double rejectPct;
  final int runDays;
  final double avgPerDay;
}

final operatorReportProvider =
    FutureProvider.autoDispose<List<OperatorReportRow>>((ref) async {
  final db = ref.watch(databaseServiceProvider);
  final range = ref.watch(reportDateRangeProvider);
  final factoryId = db.activeWorkspaceId.trim();
  if (factoryId.isEmpty) return [];

  final rows = db.db.select(
    '''
    SELECT
      o.name AS op_name,
      COALESCE(SUM(p.production_qty), 0) AS total_prod,
      COALESCE(SUM(p.bp_reject_qty), 0) AS bp_rej,
      COALESCE(SUM(p.good_qty), 0) AS good,
      COUNT(DISTINCT p.date) AS run_days
    FROM operators o
    LEFT JOIN productions p ON p.factory_id = o.factory_id
      AND p.operator_id = o.id AND p.date BETWEEN ? AND ?
    WHERE o.factory_id = ? AND o.active = 1
    GROUP BY o.id, o.name
    ORDER BY total_prod DESC
  ''',
    [range.fromStr, range.toStr, factoryId],
  );

  return rows.map((r) {
    final prod = ((r['total_prod'] ?? r['production_qty']) as num?)?.toDouble() ?? 0.0;
    final bp = ((r['bp_rej'] ?? r['bp_reject_qty']) as num?)?.toDouble() ?? 0.0;
    final days = ((r['run_days']) as num?)?.toInt() ?? 0;
    return OperatorReportRow(
      operatorName: r['op_name'] as String? ?? '—',
      totalProduction: prod,
      bpReject: bp,
      goodQty: ((r['good'] ?? r['good_qty']) as num?)?.toDouble() ?? 0.0,
      rejectPct: prod > 0 ? (bp / prod * 100) : 0,
      runDays: days,
      avgPerDay: days > 0 ? prod / days : 0,
    );
  }).toList();
});

// ─── 4. Machine Downtime Report ───────────────────────────────────────────────

class DowntimeRow {
  const DowntimeRow({
    required this.date,
    required this.machineName,
    required this.startTime,
    required this.endTime,
    required this.durationMinutes,
    required this.reason,
  });
  final String date;
  final String machineName;
  final String startTime;
  final String? endTime;
  final int durationMinutes;
  final String reason;
}

final downtimeReportProvider =
    FutureProvider.autoDispose<List<DowntimeRow>>((ref) async {
  final db = ref.watch(databaseServiceProvider);
  final range = ref.watch(reportDateRangeProvider);
  final factoryId = db.activeWorkspaceId.trim();
  if (factoryId.isEmpty) return [];

  final rows = db.db.select(
    '''
    SELECT dt.date, m.name AS machine_name,
           dt.start_time, dt.end_time,
           COALESCE(dt.duration_minutes, 0) AS duration_minutes,
           COALESCE(dt.reason, '') AS reason
    FROM machine_downtimes dt
    LEFT JOIN machines m ON m.id = dt.machine_id
      AND m.factory_id = dt.factory_id
    WHERE dt.factory_id = ? AND dt.date BETWEEN ? AND ?
    ORDER BY dt.date DESC, dt.start_time DESC
  ''',
    [factoryId, range.fromStr, range.toStr],
  );

  return rows
      .map(
        (r) => DowntimeRow(
          date: r['date'] as String? ?? '',
          machineName: r['machine_name'] as String? ?? '—',
          startTime: r['start_time'] as String? ?? '',
          endTime: r['end_time'] as String?,
          durationMinutes: ((r['duration_minutes'] ?? r['dt_mins']) as num?)?.toInt() ?? 0,
          reason: r['reason'] as String? ?? '—',
        ),
      )
      .toList();
});

// ─── 5. Reject Analysis (BP + AP combined) ───────────────────────────────────

class RejectAnalysisRow {
  const RejectAnalysisRow({
    required this.date,
    required this.partName,
    required this.bpReject,
    required this.apReject,
    required this.totalReject,
    required this.production,
    required this.rejectPct,
  });
  final String date;
  final String partName;
  final double bpReject;
  final double apReject;
  final double totalReject;
  final double production;
  final double rejectPct;
}

final rejectAnalysisProvider =
    FutureProvider.autoDispose<List<RejectAnalysisRow>>((ref) async {
  final db = ref.watch(databaseServiceProvider);
  final range = ref.watch(reportDateRangeProvider);
  final factoryId = db.activeWorkspaceId.trim();
  if (factoryId.isEmpty) return [];

  final rows = db.db.select(
    '''
    WITH bp_inspection_rejects AS (
      SELECT factory_id, part_id, date, SUM(bp_reject_qty) AS qty
      FROM bp_inspections
      WHERE factory_id = ? AND date BETWEEN ? AND ?
      GROUP BY factory_id, part_id, date
    ), ap_inspection_rejects AS (
      SELECT factory_id, part_id, date, SUM(rejected_qty) AS qty
      FROM ap_inspections
      WHERE factory_id = ? AND date BETWEEN ? AND ?
      GROUP BY factory_id, part_id, date
    ), prod_rejects AS (
      SELECT factory_id, part_id, date, SUM(production_qty) AS production, SUM(bp_reject_qty) AS mach_rej
      FROM productions
      WHERE factory_id = ? AND date BETWEEN ? AND ?
      GROUP BY factory_id, part_id, date
    ), manual_adj_rejects AS (
      SELECT factory_id, part_id, SUBSTR(created_at, 1, 10) AS date,
             SUM(CASE WHEN stage = 'bp_rejected' THEN adjusted_qty ELSE 0 END) AS bp_adj,
             SUM(CASE WHEN stage = 'production_rejected' THEN adjusted_qty ELSE 0 END) AS prod_adj
      FROM stock_adjustments
      WHERE factory_id = ? AND stage IN ('bp_rejected', 'production_rejected')
        AND SUBSTR(created_at, 1, 10) BETWEEN ? AND ?
      GROUP BY factory_id, part_id, SUBSTR(created_at, 1, 10)
    ), all_dates_parts AS (
      SELECT factory_id, part_id, date FROM bp_inspection_rejects
      UNION SELECT factory_id, part_id, date FROM ap_inspection_rejects
      UNION SELECT factory_id, part_id, date FROM prod_rejects
      UNION SELECT factory_id, part_id, date FROM manual_adj_rejects
    )
    SELECT adp.date, pt.name AS part_name,
           COALESCE(pr.production, 0) AS production,
           COALESCE(pr.mach_rej, 0) + COALESCE(bi.qty, 0) + COALESCE(ma.bp_adj, 0) + COALESCE(ma.prod_adj, 0) AS bp_rej,
           COALESCE(ap.qty, 0) AS ap_rej
    FROM all_dates_parts adp
    INNER JOIN parts pt ON pt.id = adp.part_id AND pt.factory_id = adp.factory_id
    LEFT JOIN prod_rejects pr ON pr.factory_id = adp.factory_id AND pr.part_id = adp.part_id AND pr.date = adp.date
    LEFT JOIN bp_inspection_rejects bi ON bi.factory_id = adp.factory_id AND bi.part_id = adp.part_id AND bi.date = adp.date
    LEFT JOIN ap_inspection_rejects ap ON ap.factory_id = adp.factory_id AND ap.part_id = adp.part_id AND ap.date = adp.date
    LEFT JOIN manual_adj_rejects ma ON ma.factory_id = adp.factory_id AND ma.part_id = adp.part_id AND ma.date = adp.date
    ORDER BY adp.date DESC, pt.name
  ''',
    [
      factoryId,
      range.fromStr,
      range.toStr,
      factoryId,
      range.fromStr,
      range.toStr,
      factoryId,
      range.fromStr,
      range.toStr,
      factoryId,
      range.fromStr,
      range.toStr,
    ],
  );

  return rows.map((r) {
    final prod = ((r['production'] ?? r['production_qty']) as num?)?.toDouble() ?? 0.0;
    final bp = ((r['bp_rej'] ?? r['bp_reject_qty']) as num?)?.toDouble() ?? 0.0;
    final ap = ((r['ap_rej'] ?? r['rejected_qty']) as num?)?.toDouble() ?? 0.0;
    final total = bp + ap;
    return RejectAnalysisRow(
      date: r['date'] as String? ?? '',
      partName: r['part_name'] as String? ?? '—',
      bpReject: bp,
      apReject: ap,
      totalReject: total,
      production: prod,
      rejectPct: prod > 0 ? (total / prod * 100) : 0,
    );
  }).toList();
});

// ─── 6. RTV Analysis ─────────────────────────────────────────────────────────

class RtvReportRow {
  const RtvReportRow({
    required this.date,
    required this.partName,
    required this.vendorName,
    required this.rtvQty,
    required this.status,
    required this.expectedReturn,
    required this.cycleNumber,
  });
  final String date;
  final String partName;
  final String vendorName;
  final double rtvQty;
  final String status;
  final String? expectedReturn;
  final int cycleNumber;
}

final rtvReportProvider =
    FutureProvider.autoDispose<List<RtvReportRow>>((ref) async {
  final db = ref.watch(databaseServiceProvider);
  final range = ref.watch(reportDateRangeProvider);
  final factoryId = db.activeWorkspaceId.trim();
  if (factoryId.isEmpty) return [];

  final rows = db.db.select(
    '''
    SELECT r.date, pt.name AS part_name, v.name AS vendor_name,
           r.rtv_qty, r.status, r.expected_return_date, r.cycle_number
    FROM rtvs r
    LEFT JOIN parts pt ON pt.id = r.part_id AND pt.factory_id = r.factory_id
    LEFT JOIN vendors v ON v.id = r.vendor_id AND v.factory_id = r.factory_id
    WHERE r.factory_id = ? AND r.date BETWEEN ? AND ?
    ORDER BY r.date DESC
  ''',
    [factoryId, range.fromStr, range.toStr],
  );

  return rows
      .map(
        (r) => RtvReportRow(
          date: r['date'] as String? ?? '',
          partName: r['part_name'] as String? ?? '—',
          vendorName: r['vendor_name'] as String? ?? '—',
          rtvQty: ((r['rtv_qty'] ?? r['qty']) as num?)?.toDouble() ?? 0.0,
          status: r['status'] as String? ?? 'pending',
          expectedReturn: r['expected_return_date'] as String?,
          cycleNumber: (r['cycle_number'] as num?)?.toInt() ?? 1,
        ),
      )
      .toList();
});

// ─── 7. Dispatch Report ───────────────────────────────────────────────────────

class DispatchReportRow {
  const DispatchReportRow({
    required this.date,
    required this.partName,
    required this.customerName,
    required this.dispatchQty,
    required this.challanNumber,
    required this.vehicleNumber,
  });
  final String date;
  final String partName;
  final String customerName;
  final double dispatchQty;
  final String challanNumber;
  final String vehicleNumber;
}

final dispatchReportProvider =
    FutureProvider.autoDispose<List<DispatchReportRow>>((ref) async {
  final db = ref.watch(databaseServiceProvider);
  final range = ref.watch(reportDateRangeProvider);
  final factoryId = db.activeWorkspaceId.trim();
  if (factoryId.isEmpty) return [];

  final rows = db.db.select(
    '''
    SELECT ds.date, pt.name AS part_name, c.name AS customer_name,
           di.dispatch_qty, COALESCE(ds.challan_number,'') AS challan,
           COALESCE(v.number_plate,'') AS vehicle
    FROM dispatch_sessions ds
    INNER JOIN dispatch_items di ON di.factory_id = ds.factory_id
      AND di.session_id = ds.id
    LEFT JOIN parts pt ON pt.id = di.part_id AND pt.factory_id = di.factory_id
    LEFT JOIN customers c ON c.id = ds.customer_id
      AND c.factory_id = ds.factory_id
    LEFT JOIN vehicles v ON v.id = ds.vehicle_id
      AND v.factory_id = ds.factory_id
    WHERE ds.factory_id = ? AND ds.date BETWEEN ? AND ?
    ORDER BY ds.date DESC, ds.time DESC
  ''',
    [factoryId, range.fromStr, range.toStr],
  );

  return rows
      .map(
        (r) => DispatchReportRow(
          date: r['date'] as String? ?? '',
          partName: r['part_name'] as String? ?? '—',
          customerName: r['customer_name'] as String? ?? '—',
          dispatchQty: ((r['dispatch_qty'] ?? r['qty']) as num?)?.toDouble() ?? 0.0,
          challanNumber: r['challan'] as String? ?? '—',
          vehicleNumber: r['vehicle'] as String? ?? '—',
        ),
      )
      .toList();
});

// ─── 8. Faco Pending Material ─────────────────────────────────────────────────

class FacoPendingRow {
  const FacoPendingRow({
    required this.partName,
    required this.vendorName,
    required this.dispatched,
    required this.received,
    required this.pending,
    required this.oldestDate,
  });
  final String partName;
  final String vendorName;
  final double dispatched;
  final double received;
  final double pending;
  final String oldestDate;
}

final facoPendingReportProvider =
    FutureProvider.autoDispose<List<FacoPendingRow>>((ref) async {
  final db = ref.watch(databaseServiceProvider);
  final factoryId = db.activeWorkspaceId.trim();
  if (factoryId.isEmpty) return [];

  final rows = db.db.select(
    '''
    SELECT
      df.part_id,
      pt.name AS part_name,
      v.name AS vendor_name,
      COALESCE(SUM(df.qty), 0) AS dispatched,
      COALESCE(SUM(rf.received), 0) AS received,
      MIN(df.date) AS oldest_date
    FROM dispatch_to_facos df
    LEFT JOIN parts pt ON pt.id = df.part_id AND pt.factory_id = df.factory_id
    LEFT JOIN vendors v ON v.id = df.vendor_id AND v.factory_id = df.factory_id
    LEFT JOIN (
      SELECT factory_id, dispatch_ref_id, SUM(qty_received) AS received
      FROM receive_from_facos
      WHERE factory_id = ?
      GROUP BY factory_id, dispatch_ref_id
    ) rf ON rf.factory_id = df.factory_id AND rf.dispatch_ref_id = df.id
    WHERE df.factory_id = ?
    GROUP BY df.part_id, df.vendor_id
    HAVING (COALESCE(SUM(df.qty), 0) - COALESCE(SUM(rf.received), 0)) > 0
    ORDER BY oldest_date ASC
  ''',
    [factoryId, factoryId],
  );

  final list = rows.map((r) {
    final disp = ((r['dispatched'] ?? r['qty']) as num?)?.toDouble() ?? 0.0;
    final recv = ((r['received'] ?? r['qty_received']) as num?)?.toDouble() ?? 0.0;
    return FacoPendingRow(
      partName: r['part_name'] as String? ?? '—',
      vendorName: r['vendor_name'] as String? ?? '—',
      dispatched: disp,
      received: recv,
      pending: (disp - recv).clamp(0, double.infinity),
      oldestDate: r['oldest_date'] as String? ?? '—',
    );
  }).toList();

  // Also include any parts with active at_faco balance in stock_ledger
  final atFacoBalances =
      await db.getBalancesByStage(StockStage.atFaco.value);
  for (final b in atFacoBalances) {
    final partName = b['name'] as String? ?? '';
    final ledgerQty = (b['balance'] as num?)?.toDouble() ?? 0.0;
    if (ledgerQty <= 0) continue;

    final trackedSum = list
        .where((item) => item.partName == partName)
        .fold<double>(0.0, (sum, item) => sum + item.pending);
    final unbatched = ledgerQty - trackedSum;
    if (unbatched > 0) {
      list.add(
        FacoPendingRow(
          partName: partName,
          vendorName: 'Assigned Vendor',
          dispatched: unbatched,
          received: 0,
          pending: unbatched,
          oldestDate: 'Opening Stock',
        ),
      );
    }
  }

  return list;
});

// ─── 9. Live Stock Report ─────────────────────────────────────────────────────

class LiveStockRow {
  const LiveStockRow({
    required this.partId,
    required this.partName,
    required this.partCode,
    required this.rawMaterial,
    required this.productionRejected,
    required this.bpStock,
    required this.bpHold,
    required this.bpRejected,
    required this.atFaco,
    required this.pendingAp,
    required this.approvedAp,
    required this.apRejected,
    required this.rtvStock,
    required this.rtvAtVendor,
    required this.totalStock,
  });
  final String partId;
  final String partName;
  final String partCode;
  final double rawMaterial;
  final double productionRejected;
  final double bpStock;
  final double bpHold;
  final double bpRejected;
  final double atFaco;
  final double pendingAp;
  final double approvedAp;
  final double apRejected;
  final double rtvStock;
  final double rtvAtVendor;
  final double totalStock;

  /// Combined BP Rejection (Machine Scrap + Inspection Rejection)
  double get totalCombinedBpRejection => productionRejected + bpRejected;

  /// Group 1: Total BP Pipeline (Raw + BP Stock + BP Hold + BP Reject)
  double get totalBpGroup =>
      rawMaterial + bpStock + bpHold + totalCombinedBpRejection;

  /// Group 2: Total AP Pipeline (At Vendor + Pending AP + Approved AP + AP Reject + Vendor Rework Hold + At Vendor for Rework)
  double get totalApPipeline =>
      atFaco + pendingAp + approvedAp + apRejected + rtvStock + rtvAtVendor;

  /// Group 2 (Internal AP phase only): Pend + Appr + Rej + Rtv
  double get totalApGroup =>
      pendingAp + approvedAp + apRejected + rtvStock;

  /// Group 3: Total With Vendor (Subcontracting + Rework)
  double get totalVendorGroup => atFaco + rtvAtVendor;
}

final liveStockReportProvider =
    FutureProvider.autoDispose<List<LiveStockRow>>((ref) async {
  final db = ref.watch(databaseServiceProvider);
  final factoryId = db.activeWorkspaceId.trim();
  if (factoryId.isEmpty) return [];

  final rows = db.db.select(
    '''
    SELECT
      p.id, p.name, p.code,
      COALESCE(MAX(CASE WHEN sl.stage='raw_material' THEN sl.running_balance END), 0) AS raw,
      COALESCE(MAX(CASE WHEN sl.stage='production_rejected' THEN sl.running_balance END), 0) AS production_rejected,
      COALESCE(MAX(CASE WHEN sl.stage='bp_stock' THEN sl.running_balance END), 0) AS bp,
      COALESCE(MAX(CASE WHEN sl.stage='bp_hold' THEN sl.running_balance END), 0) AS bp_hold,
      COALESCE(MAX(CASE WHEN sl.stage='bp_rejected' THEN sl.running_balance END), 0) AS bp_rejected,
      COALESCE(MAX(CASE WHEN sl.stage='at_faco' THEN sl.running_balance END), 0) AS faco,
      COALESCE(MAX(CASE WHEN sl.stage='pending_ap' THEN sl.running_balance END), 0) AS pap,
      COALESCE(MAX(CASE WHEN sl.stage='approved_ap' THEN sl.running_balance END), 0) AS aap,
      COALESCE(MAX(CASE WHEN sl.stage='ap_rejected' THEN sl.running_balance END), 0) AS aprej,
      COALESCE(MAX(CASE WHEN sl.stage='rtv_stock' THEN sl.running_balance END), 0) AS rtv
      ,COALESCE(MAX(CASE WHEN sl.stage='rtv_at_vendor' THEN sl.running_balance END), 0) AS rtv_vendor
    FROM parts p
    LEFT JOIN stock_ledger sl ON sl.factory_id = p.factory_id
      AND sl.part_id = p.id
      AND sl.rowid = (
        SELECT current_row.rowid FROM stock_ledger current_row
        WHERE current_row.factory_id = p.factory_id
          AND current_row.part_id = p.id
          AND current_row.stage = sl.stage
        ORDER BY current_row.created_at DESC, current_row.rowid DESC
        LIMIT 1
      )
    WHERE p.factory_id = ? AND p.active = 1
    GROUP BY p.id, p.name, p.code
    ORDER BY p.name
  ''',
    [factoryId],
  );

  return rows.map((r) {
    final raw = (r['raw'] as num?)?.toDouble() ?? 0.0;
    final productionRejected = (r['production_rejected'] as num?)?.toDouble() ?? 0.0;
    final bp = (r['bp'] as num?)?.toDouble() ?? 0.0;
    final bpHold = (r['bp_hold'] as num?)?.toDouble() ?? 0.0;
    final bpRejected = (r['bp_rejected'] as num?)?.toDouble() ?? 0.0;
    final faco = (r['faco'] as num?)?.toDouble() ?? 0.0;
    final pap = (r['pap'] as num?)?.toDouble() ?? 0.0;
    final aap = (r['aap'] as num?)?.toDouble() ?? 0.0;
    final aprej = (r['aprej'] as num?)?.toDouble() ?? 0.0;
    final rtv = (r['rtv'] as num?)?.toDouble() ?? 0.0;
    final rtvAtVendor = (r['rtv_vendor'] as num?)?.toDouble() ?? 0.0;

    // Merge machine production rejection directly into BP Rejection
    final mergedBpRejected = bpRejected + productionRejected;

    return LiveStockRow(
      partId: r['id'] as String? ?? '',
      partName: r['name'] as String? ?? '—',
      partCode: r['code'] as String? ?? '',
      rawMaterial: raw,
      productionRejected: 0.0,
      bpStock: bp,
      bpHold: bpHold,
      bpRejected: mergedBpRejected,
      atFaco: faco,
      pendingAp: pap,
      approvedAp: aap,
      apRejected: aprej,
      rtvStock: rtv,
      rtvAtVendor: rtvAtVendor,
      totalStock: raw + bp + bpHold + mergedBpRejected + faco + pap + aap + aprej + rtv + rtvAtVendor,
    );
  }).toList();
});

// ─── 10. Inventory Movement (Ledger) ─────────────────────────────────────────

class LedgerMovementRow {
  const LedgerMovementRow({
    required this.date,
    required this.partName,
    required this.stage,
    required this.direction,
    required this.qty,
    required this.runningBalance,
    required this.refTable,
  });
  final String date;
  final String partName;
  final String stage;
  final String direction;
  final double qty;
  final double runningBalance;
  final String refTable;
}

final ledgerMovementProvider =
    FutureProvider.autoDispose<List<LedgerMovementRow>>((ref) async {
  final db = ref.watch(databaseServiceProvider);
  final range = ref.watch(reportDateRangeProvider);
  final factoryId = db.activeWorkspaceId.trim();
  if (factoryId.isEmpty) return [];

  final rows = db.db.select(
    '''
    SELECT sl.date, pt.name AS part_name, sl.stage,
           sl.direction, sl.qty, sl.running_balance, sl.ref_table
    FROM stock_ledger sl
    LEFT JOIN parts pt ON pt.id = sl.part_id AND pt.factory_id = sl.factory_id
    WHERE sl.factory_id = ? AND sl.date BETWEEN ? AND ?
    ORDER BY sl.created_at DESC
    LIMIT 500
  ''',
    [factoryId, range.fromStr, range.toStr],
  );

  return rows
      .map(
        (r) => LedgerMovementRow(
          date: r['date'] as String? ?? '',
          partName: r['part_name'] as String? ?? '—',
          stage: r['stage'] as String? ?? '',
          direction: r['direction'] as String? ?? '',
          qty: ((r['qty'] ?? r['running_balance']) as num?)?.toDouble() ?? 0.0,
          runningBalance: ((r['running_balance'] ?? r['qty']) as num?)?.toDouble() ?? 0.0,
          refTable: r['ref_table'] as String? ?? '—',
        ),
      )
      .toList();
});

// ─── Summary Totals Helpers ───────────────────────────────────────────────────

extension DailyProductionSummary on List<DailyProductionRow> {
  double get totalProd => fold(0, (s, r) => s + r.totalProduction);
  double get totalBpReject => fold(0, (s, r) => s + r.bpReject);
  double get totalGood => fold(0, (s, r) => s + r.goodQty);
  double get avgEfficiency =>
      isEmpty ? 0 : fold(0.0, (s, r) => s + r.efficiency) / length;
  double get overallRejectPct =>
      totalProd > 0 ? (totalBpReject / totalProd * 100) : 0;
}

extension DispatchSummary on List<DispatchReportRow> {
  double get totalDispatched => fold(0, (s, r) => s + r.dispatchQty);
}

extension RtvSummary on List<RtvReportRow> {
  double get totalRtvQty => fold(0, (s, r) => s + r.rtvQty);
  int get pendingCount => where((r) => r.status == 'pending').length;
}

// ─── 11. Hold Material Report ─────────────────────────────────────────────────

class BpHoldRow {
  const BpHoldRow({
    required this.date,
    required this.partCode,
    required this.partName,
    required this.machineName,
    required this.qty,
    required this.reason,
  });
  final String date;
  final String partCode;
  final String partName;
  final String machineName;
  final double qty;
  final String reason;
}

class RtvHoldRow {
  const RtvHoldRow({
    required this.date,
    required this.partCode,
    required this.partName,
    required this.vendorName,
    required this.qty,
    required this.status,
    required this.agingDays,
  });
  final String date;
  final String partCode;
  final String partName;
  final String vendorName;
  final double qty;
  final String status;
  final int agingDays;
}

class HoldMaterialReportData {
  const HoldMaterialReportData({
    required this.bpHoldList,
    required this.rtvHoldList,
  });
  final List<BpHoldRow> bpHoldList;
  final List<RtvHoldRow> rtvHoldList;

  double get totalBpHold => bpHoldList.fold(0.0, (s, r) => s + r.qty);
  double get totalRtvHold => rtvHoldList.fold(0.0, (s, r) => s + r.qty);
}

final holdMaterialReportProvider =
    FutureProvider.autoDispose<HoldMaterialReportData>((ref) async {
  final db = ref.watch(databaseServiceProvider);
  final factoryId = db.activeWorkspaceId.trim();
  if (factoryId.isEmpty) {
    return const HoldMaterialReportData(
      bpHoldList: [],
      rtvHoldList: [],
    );
  }

  // Read the current ledger balance, not historical inspection rows. Opening
  // stock and later adjustments must be visible here as soon as they are saved.
  final bpRows = db.db.select(
    '''
    SELECT sl.date, p.code as part_code, p.name as part_name,
           COALESCE(sa.remarks, bi.remarks, 'BP quality hold') AS reason,
           sl.running_balance AS qty
    FROM stock_ledger sl
    INNER JOIN parts p ON p.id = sl.part_id AND p.factory_id = sl.factory_id
    LEFT JOIN stock_adjustments sa ON sa.id = sl.ref_id
      AND sa.factory_id = sl.factory_id
    LEFT JOIN bp_inspections bi ON bi.id = sl.ref_id
      AND bi.factory_id = sl.factory_id
    WHERE sl.factory_id = ? AND sl.stage = 'bp_hold'
      AND sl.rowid = (
        SELECT current_row.rowid FROM stock_ledger current_row
        WHERE current_row.factory_id = sl.factory_id
          AND current_row.part_id = sl.part_id
          AND current_row.stage = sl.stage
        ORDER BY current_row.created_at DESC, current_row.rowid DESC LIMIT 1
      )
      AND sl.running_balance > 0
    ORDER BY sl.date DESC
  ''',
    [factoryId],
  );

  final bpHoldList = bpRows.map((r) {
    return BpHoldRow(
      date: r['date'] as String? ?? '',
      partCode: r['part_code'] as String? ?? '—',
      partName: r['part_name'] as String? ?? '—',
      machineName: 'BP Hold',
      qty: ((r['qty'] ?? r['running_balance']) as num?)?.toDouble() ?? 0.0,
      reason: r['reason'] as String? ?? '—',
    );
  }).toList();

  // RTV held inside the company is distinct from material already sent to a
  // vendor for rework. This tab reports only the former.
  final rtvRows = db.db.select(
    '''
    SELECT sl.date, p.code as part_code, p.name as part_name,
           COALESCE(sa.remarks, 'Awaiting vendor rework') AS vendor_name,
           sl.running_balance AS qty
    FROM stock_ledger sl
    INNER JOIN parts p ON p.id = sl.part_id AND p.factory_id = sl.factory_id
    LEFT JOIN stock_adjustments sa ON sa.id = sl.ref_id
      AND sa.factory_id = sl.factory_id
    WHERE sl.factory_id = ? AND sl.stage = 'rtv_stock'
      AND sl.rowid = (
        SELECT current_row.rowid FROM stock_ledger current_row
        WHERE current_row.factory_id = sl.factory_id
          AND current_row.part_id = sl.part_id
          AND current_row.stage = sl.stage
        ORDER BY current_row.created_at DESC, current_row.rowid DESC LIMIT 1
      )
      AND sl.running_balance > 0
    ORDER BY sl.date DESC
  ''',
    [factoryId],
  );

  final rtvHoldList = rtvRows.map((r) {
    final rtvDateStr = r['date'] as String;
    int aging = 0;
    try {
      final parsedDate = DateTime.parse(rtvDateStr);
      aging = DateTime.now().difference(parsedDate).inDays;
    } catch (_) {}

    return RtvHoldRow(
      date: rtvDateStr,
      partCode: r['part_code'] as String? ?? '—',
      partName: r['part_name'] as String? ?? '—',
      vendorName: r['vendor_name'] as String? ?? '—',
      qty: ((r['qty'] ?? r['running_balance']) as num?)?.toDouble() ?? 0.0,
      status: 'awaiting_vendor_rework',
      agingDays: aging,
    );
  }).toList();

  return HoldMaterialReportData(
    bpHoldList: bpHoldList,
    rtvHoldList: rtvHoldList,
  );
});

// ─── 12. Vendor Movement (Sent & Received Detailed Logs) ──────────────────────

class VendorDispatchRow {
  const VendorDispatchRow({
    required this.id,
    required this.date,
    required this.time,
    required this.partName,
    required this.vendorName,
    required this.qty,
    required this.challanNumber,
    required this.batchNumber,
    required this.remarks,
  });
  final String id;
  final String date;
  final String time;
  final String partName;
  final String vendorName;
  final double qty;
  final String challanNumber;
  final String batchNumber;
  final String remarks;
}

class VendorReceiveRow {
  const VendorReceiveRow({
    required this.id,
    required this.date,
    required this.partName,
    required this.vendorName,
    required this.qtyReceived,
    required this.supplierChallan,
    required this.batchNumber,
    required this.remarks,
    required this.dispatchChallan,
  });
  final String id;
  final String date;
  final String partName;
  final String vendorName;
  final double qtyReceived;
  final String supplierChallan;
  final String batchNumber;
  final String remarks;
  final String dispatchChallan;
}

class VendorMovementData {
  const VendorMovementData({
    required this.dispatches,
    required this.receipts,
  });
  final List<VendorDispatchRow> dispatches;
  final List<VendorReceiveRow> receipts;

  double get totalDispatched =>
      dispatches.fold(0.0, (sum, item) => sum + item.qty);
  double get totalReceived =>
      receipts.fold(0.0, (sum, item) => sum + item.qtyReceived);
  double get netPending => (totalDispatched - totalReceived).clamp(0, double.infinity);
}

final vendorMovementProvider =
    FutureProvider.autoDispose<VendorMovementData>((ref) async {
  final db = ref.watch(databaseServiceProvider);
  final range = ref.watch(reportDateRangeProvider);
  final factoryId = db.activeWorkspaceId.trim();
  if (factoryId.isEmpty) {
    return const VendorMovementData(dispatches: [], receipts: []);
  }

  // 1. Dispatches to Vendor
  final dRows = db.db.select(
    '''
    SELECT df.id, df.date, df.time, pt.name AS part_name, v.name AS vendor_name,
           df.qty, COALESCE(df.challan_number, '') AS challan_number,
           COALESCE(df.batch_number, '') AS batch_number,
           COALESCE(df.remarks, '') AS remarks
    FROM dispatch_to_facos df
    LEFT JOIN parts pt ON pt.id = df.part_id AND pt.factory_id = df.factory_id
    LEFT JOIN vendors v ON v.id = df.vendor_id AND v.factory_id = df.factory_id
    WHERE df.factory_id = ? AND df.date BETWEEN ? AND ?
    ORDER BY df.date DESC, df.time DESC
  ''',
    [factoryId, range.fromStr, range.toStr],
  );

  final dispatches = dRows
      .map(
        (r) => VendorDispatchRow(
          id: r['id'] as String? ?? '',
          date: r['date'] as String? ?? '',
          time: formatTimeWithoutSeconds(r['time'] as String?),
          partName: r['part_name'] as String? ?? '—',
          vendorName: r['vendor_name'] as String? ?? '—',
          qty: ((r['qty'] ?? r['dispatch_qty']) as num?)?.toDouble() ?? 0.0,
          challanNumber: r['challan_number'] as String? ?? '—',
          batchNumber: r['batch_number'] as String? ?? '—',
          remarks: r['remarks'] as String? ?? '',
        ),
      )
      .toList();

  // 2. Receipts from Vendor
  final rRows = db.db.select(
    '''
    SELECT rf.id, rf.date, pt.name AS part_name, v.name AS vendor_name,
           rf.qty_received, COALESCE(rf.supplier_challan, '') AS supplier_challan,
           COALESCE(rf.batch_number, '') AS batch_number,
           COALESCE(rf.remarks, '') AS remarks,
           COALESCE(df.challan_number, '') AS dispatch_challan
    FROM receive_from_facos rf
    LEFT JOIN parts pt ON pt.id = rf.part_id AND pt.factory_id = rf.factory_id
    LEFT JOIN dispatch_to_facos df ON df.id = rf.dispatch_ref_id AND df.factory_id = rf.factory_id
    LEFT JOIN vendors v ON v.id = df.vendor_id AND v.factory_id = df.factory_id
    WHERE rf.factory_id = ? AND rf.date BETWEEN ? AND ?
    ORDER BY rf.date DESC
  ''',
    [factoryId, range.fromStr, range.toStr],
  );

  final receipts = rRows
      .map(
        (r) => VendorReceiveRow(
          id: r['id'] as String? ?? '',
          date: r['date'] as String? ?? '',
          partName: r['part_name'] as String? ?? '—',
          vendorName: r['vendor_name'] as String? ?? '—',
          qtyReceived: ((r['qty_received'] ?? r['received']) as num?)?.toDouble() ?? 0.0,
          supplierChallan: r['supplier_challan'] as String? ?? '—',
          batchNumber: r['batch_number'] as String? ?? '—',
          remarks: r['remarks'] as String? ?? '',
          dispatchChallan: r['dispatch_challan'] as String? ?? '—',
        ),
      )
      .toList();

  return VendorMovementData(
    dispatches: dispatches,
    receipts: receipts,
  );
});
