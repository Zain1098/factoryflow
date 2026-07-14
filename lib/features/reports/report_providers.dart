import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/database_service.dart';

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

  static DateRange thisMonth() {
    final now = DateTime.now();
    return DateRange(DateTime(now.year, now.month, 1), now);
  }

  static DateRange last30() {
    final now = DateTime.now();
    return DateRange(now.subtract(const Duration(days: 29)), now);
  }
}

// ─── Date Range Provider ──────────────────────────────────────────────────────

class _DateRangeNotifier extends Notifier<DateRange> {
  @override
  DateRange build() => DateRange.thisMonth();
  void set(DateRange r) => state = r;
}

final reportDateRangeProvider =
    NotifierProvider<_DateRangeNotifier, DateRange>(_DateRangeNotifier.new);

// ─── 1. Daily Production Report ───────────────────────────────────────────────

class DailyProductionRow {
  const DailyProductionRow({
    required this.date,
    required this.totalProduction,
    required this.bpReject,
    required this.goodQty,
    required this.target,
    required this.efficiency,
    required this.rejectPct,
  });
  final String date;
  final double totalProduction;
  final double bpReject;
  final double goodQty;
  final double target;
  final double efficiency;
  final double rejectPct;
}

final dailyProductionReportProvider =
    FutureProvider.autoDispose<List<DailyProductionRow>>((ref) async {
  final db = ref.watch(databaseServiceProvider);
  final range = ref.watch(reportDateRangeProvider);

  final rows = db.db.select('''
    SELECT
      p.date,
      COALESCE(SUM(p.production_qty), 0) AS total_prod,
      COALESCE(SUM(p.bp_reject_qty), 0) AS bp_rej,
      COALESCE(SUM(p.good_qty), 0) AS good,
      COALESCE(t.target, 0) AS target
    FROM productions p
    LEFT JOIN (
      SELECT day_of_week, SUM(target_qty) AS target FROM target_master GROUP BY day_of_week
    ) t ON t.day_of_week = (CAST(strftime('%w', p.date) AS INTEGER))
    WHERE p.date BETWEEN ? AND ?
    GROUP BY p.date
    ORDER BY p.date DESC
  ''', [range.fromStr, range.toStr],);

  return rows.map((r) {
    final prod = (r['total_prod'] as num).toDouble();
    final bp = (r['bp_rej'] as num).toDouble();
    final good = (r['good'] as num).toDouble();
    final target = (r['target'] as num).toDouble();
    return DailyProductionRow(
      date: r['date'] as String,
      totalProduction: prod,
      bpReject: bp,
      goodQty: good,
      target: target,
      efficiency: target > 0 ? (prod / target * 100).clamp(0, 999) : 0,
      rejectPct: prod > 0 ? (bp / prod * 100) : 0,
    );
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

  final rows = db.db.select('''
    SELECT
      m.name AS machine_name,
      COALESCE(SUM(p.production_qty), 0) AS total_prod,
      COALESCE(SUM(p.bp_reject_qty), 0) AS bp_rej,
      COALESCE(SUM(p.good_qty), 0) AS good,
      COUNT(DISTINCT p.date) AS run_days,
      COALESCE(dt.downtime_mins, 0) AS downtime_mins
    FROM machines m
    LEFT JOIN productions p ON p.machine_id = m.id AND p.date BETWEEN ? AND ?
    LEFT JOIN (
      SELECT machine_id, SUM(duration_minutes) AS downtime_mins
      FROM machine_downtimes WHERE date BETWEEN ? AND ?
      GROUP BY machine_id
    ) dt ON dt.machine_id = m.id
    WHERE m.active = 1
    GROUP BY m.id, m.name
    ORDER BY total_prod DESC
  ''', [range.fromStr, range.toStr, range.fromStr, range.toStr],);

  return rows.map((r) {
    final prod = (r['total_prod'] as num).toDouble();
    final bp = (r['bp_rej'] as num).toDouble();
    return MachineReportRow(
      machineName: r['machine_name'] as String,
      totalProduction: prod,
      bpReject: bp,
      goodQty: (r['good'] as num).toDouble(),
      rejectPct: prod > 0 ? (bp / prod * 100) : 0,
      downtimeMinutes: (r['downtime_mins'] as num).toInt(),
      runDays: (r['run_days'] as num).toInt(),
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

  final rows = db.db.select('''
    SELECT
      o.name AS op_name,
      COALESCE(SUM(p.production_qty), 0) AS total_prod,
      COALESCE(SUM(p.bp_reject_qty), 0) AS bp_rej,
      COALESCE(SUM(p.good_qty), 0) AS good,
      COUNT(DISTINCT p.date) AS run_days
    FROM operators o
    LEFT JOIN productions p ON p.operator_id = o.id AND p.date BETWEEN ? AND ?
    WHERE o.active = 1
    GROUP BY o.id, o.name
    ORDER BY total_prod DESC
  ''', [range.fromStr, range.toStr],);

  return rows.map((r) {
    final prod = (r['total_prod'] as num).toDouble();
    final bp = (r['bp_rej'] as num).toDouble();
    final days = (r['run_days'] as num).toInt();
    return OperatorReportRow(
      operatorName: r['op_name'] as String,
      totalProduction: prod,
      bpReject: bp,
      goodQty: (r['good'] as num).toDouble(),
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

  final rows = db.db.select('''
    SELECT dt.date, m.name AS machine_name,
           dt.start_time, dt.end_time,
           COALESCE(dt.duration_minutes, 0) AS duration_minutes,
           COALESCE(dt.reason, '') AS reason
    FROM machine_downtimes dt
    LEFT JOIN machines m ON m.id = dt.machine_id
    WHERE dt.date BETWEEN ? AND ?
    ORDER BY dt.date DESC, dt.start_time DESC
  ''', [range.fromStr, range.toStr],);

  return rows.map((r) => DowntimeRow(
        date: r['date'] as String,
        machineName: r['machine_name'] as String? ?? '—',
        startTime: r['start_time'] as String? ?? '',
        endTime: r['end_time'] as String?,
        durationMinutes: (r['duration_minutes'] as num).toInt(),
        reason: r['reason'] as String,
      ),).toList();
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

  final rows = db.db.select('''
    SELECT
      p.date,
      pt.name AS part_name,
      COALESCE(SUM(p.production_qty), 0) AS production,
      COALESCE(SUM(p.bp_reject_qty), 0) AS bp_rej,
      COALESCE(ap.ap_rej, 0) AS ap_rej
    FROM productions p
    LEFT JOIN parts pt ON pt.id = p.part_id
    LEFT JOIN (
      SELECT part_id, date, SUM(rejected_qty) AS ap_rej
      FROM ap_inspections WHERE date BETWEEN ? AND ?
      GROUP BY part_id, date
    ) ap ON ap.part_id = p.part_id AND ap.date = p.date
    WHERE p.date BETWEEN ? AND ?
    GROUP BY p.date, p.part_id
    ORDER BY p.date DESC
  ''', [range.fromStr, range.toStr, range.fromStr, range.toStr],);

  return rows.map((r) {
    final prod = (r['production'] as num).toDouble();
    final bp = (r['bp_rej'] as num).toDouble();
    final ap = (r['ap_rej'] as num).toDouble();
    final total = bp + ap;
    return RejectAnalysisRow(
      date: r['date'] as String,
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

  final rows = db.db.select('''
    SELECT r.date, pt.name AS part_name, v.name AS vendor_name,
           r.rtv_qty, r.status, r.expected_return_date, r.cycle_number
    FROM rtvs r
    LEFT JOIN parts pt ON pt.id = r.part_id
    LEFT JOIN vendors v ON v.id = r.vendor_id
    WHERE r.date BETWEEN ? AND ?
    ORDER BY r.date DESC
  ''', [range.fromStr, range.toStr],);

  return rows.map((r) => RtvReportRow(
        date: r['date'] as String,
        partName: r['part_name'] as String? ?? '—',
        vendorName: r['vendor_name'] as String? ?? '—',
        rtvQty: (r['rtv_qty'] as num).toDouble(),
        status: r['status'] as String? ?? 'pending',
        expectedReturn: r['expected_return_date'] as String?,
        cycleNumber: (r['cycle_number'] as num?)?.toInt() ?? 1,
      ),).toList();
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

  final rows = db.db.select('''
    SELECT fd.date, pt.name AS part_name, c.name AS customer_name,
           fd.dispatch_qty, COALESCE(fd.challan_number,'') AS challan,
           COALESCE(v.number_plate,'') AS vehicle
    FROM final_dispatches fd
    LEFT JOIN parts pt ON pt.id = fd.part_id
    LEFT JOIN customers c ON c.id = fd.customer_id
    LEFT JOIN vehicles v ON v.id = fd.vehicle_id
    WHERE fd.date BETWEEN ? AND ?
    ORDER BY fd.date DESC
  ''', [range.fromStr, range.toStr],);

  return rows.map((r) => DispatchReportRow(
        date: r['date'] as String,
        partName: r['part_name'] as String? ?? '—',
        customerName: r['customer_name'] as String? ?? '—',
        dispatchQty: (r['dispatch_qty'] as num).toDouble(),
        challanNumber: r['challan'] as String,
        vehicleNumber: r['vehicle'] as String,
      ),).toList();
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

  final rows = db.db.select('''
    SELECT
      pt.name AS part_name,
      v.name AS vendor_name,
      COALESCE(SUM(df.qty), 0) AS dispatched,
      COALESCE(rf.received, 0) AS received,
      MIN(df.date) AS oldest_date
    FROM dispatch_to_facos df
    LEFT JOIN parts pt ON pt.id = df.part_id
    LEFT JOIN vendors v ON v.id = df.vendor_id
    LEFT JOIN (
      SELECT part_id, SUM(qty_received) AS received
      FROM receive_from_facos GROUP BY part_id
    ) rf ON rf.part_id = df.part_id
    GROUP BY df.part_id, df.vendor_id
    HAVING (COALESCE(SUM(df.qty), 0) - COALESCE(rf.received, 0)) > 0
    ORDER BY oldest_date ASC
  ''');

  return rows.map((r) {
    final disp = (r['dispatched'] as num).toDouble();
    final recv = (r['received'] as num).toDouble();
    return FacoPendingRow(
      partName: r['part_name'] as String? ?? '—',
      vendorName: r['vendor_name'] as String? ?? '—',
      dispatched: disp,
      received: recv,
      pending: (disp - recv).clamp(0, double.infinity),
      oldestDate: r['oldest_date'] as String? ?? '—',
    );
  }).toList();
});

// ─── 9. Live Stock Report ─────────────────────────────────────────────────────

class LiveStockRow {
  const LiveStockRow({
    required this.partName,
    required this.partCode,
    required this.rawMaterial,
    required this.bpStock,
    required this.atFaco,
    required this.pendingAp,
    required this.approvedAp,
    required this.rtvStock,
    required this.totalStock,
  });
  final String partName;
  final String partCode;
  final double rawMaterial;
  final double bpStock;
  final double atFaco;
  final double pendingAp;
  final double approvedAp;
  final double rtvStock;
  final double totalStock;
}

final liveStockReportProvider =
    FutureProvider.autoDispose<List<LiveStockRow>>((ref) async {
  final db = ref.watch(databaseServiceProvider);

  final rows = db.db.select('''
    SELECT
      p.name, p.code,
      COALESCE(MAX(CASE WHEN sl.stage='raw_material' THEN sl.running_balance END), 0) AS raw,
      COALESCE(MAX(CASE WHEN sl.stage='bp_stock' THEN sl.running_balance END), 0) AS bp,
      COALESCE(MAX(CASE WHEN sl.stage='at_faco' THEN sl.running_balance END), 0) AS faco,
      COALESCE(MAX(CASE WHEN sl.stage='pending_ap' THEN sl.running_balance END), 0) AS pap,
      COALESCE(MAX(CASE WHEN sl.stage='approved_ap' THEN sl.running_balance END), 0) AS aap,
      COALESCE(MAX(CASE WHEN sl.stage='rtv_stock' THEN sl.running_balance END), 0) AS rtv
    FROM parts p
    LEFT JOIN stock_ledger sl ON sl.part_id = p.id
      AND sl.created_at = (
        SELECT MAX(created_at) FROM stock_ledger
        WHERE part_id = p.id AND stage = sl.stage
      )
    WHERE p.active = 1
    GROUP BY p.id, p.name, p.code
    ORDER BY p.name
  ''');

  return rows.map((r) {
    final raw = (r['raw'] as num).toDouble();
    final bp = (r['bp'] as num).toDouble();
    final faco = (r['faco'] as num).toDouble();
    final pap = (r['pap'] as num).toDouble();
    final aap = (r['aap'] as num).toDouble();
    final rtv = (r['rtv'] as num).toDouble();
    return LiveStockRow(
      partName: r['name'] as String,
      partCode: r['code'] as String? ?? '',
      rawMaterial: raw,
      bpStock: bp,
      atFaco: faco,
      pendingAp: pap,
      approvedAp: aap,
      rtvStock: rtv,
      totalStock: raw + bp + faco + pap + aap + rtv,
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

  final rows = db.db.select('''
    SELECT sl.date, pt.name AS part_name, sl.stage,
           sl.direction, sl.qty, sl.running_balance, sl.ref_table
    FROM stock_ledger sl
    LEFT JOIN parts pt ON pt.id = sl.part_id
    WHERE sl.date BETWEEN ? AND ?
    ORDER BY sl.created_at DESC
    LIMIT 500
  ''', [range.fromStr, range.toStr],);

  return rows.map((r) => LedgerMovementRow(
        date: r['date'] as String,
        partName: r['part_name'] as String? ?? '—',
        stage: r['stage'] as String,
        direction: r['direction'] as String,
        qty: (r['qty'] as num).toDouble(),
        runningBalance: (r['running_balance'] as num).toDouble(),
        refTable: r['ref_table'] as String? ?? '—',
      ),).toList();
});

// ─── Summary Totals Helpers ───────────────────────────────────────────────────

extension DailyProductionSummary on List<DailyProductionRow> {
  double get totalProd => fold(0, (s, r) => s + r.totalProduction);
  double get totalBpReject => fold(0, (s, r) => s + r.bpReject);
  double get totalGood => fold(0, (s, r) => s + r.goodQty);
  double get avgEfficiency => isEmpty ? 0 : fold(0.0, (s, r) => s + r.efficiency) / length;
  double get overallRejectPct => totalProd > 0 ? (totalBpReject / totalProd * 100) : 0;
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
  final range = ref.watch(reportDateRangeProvider);

  // 1. Fetch BP Inspections (Hold Before Plating)
  final bpRows = db.db.select('''
    SELECT bi.date, p.code as part_code, p.name as part_name, m.name as machine_name, bi.bp_reject_qty, bi.reject_reason_id
    FROM bp_inspections bi
    LEFT JOIN parts p ON p.id = bi.part_id
    LEFT JOIN machines m ON m.id = bi.machine_id
    WHERE bi.date BETWEEN ? AND ?
    ORDER BY bi.date DESC
  ''', [range.fromStr, range.toStr]);

  final bpHoldList = bpRows.map((r) {
    return BpHoldRow(
      date: r['date'] as String,
      partCode: r['part_code'] as String? ?? '—',
      partName: r['part_name'] as String? ?? '—',
      machineName: r['machine_name'] as String? ?? '—',
      qty: (r['bp_reject_qty'] as num).toDouble(),
      reason: r['reject_reason_id'] as String? ?? '—',
    );
  }).toList();

  // 2. Fetch Active RTV Stock (Hold After Plating)
  final rtvRows = db.db.select('''
    SELECT r.date, p.code as part_code, p.name as part_name, v.name as vendor_name, r.rtv_qty, r.status
    FROM rtvs r
    LEFT JOIN parts p ON p.id = r.part_id
    LEFT JOIN vendors v ON v.id = r.vendor_id
    WHERE r.status != 'received' AND r.date BETWEEN ? AND ?
    ORDER BY r.date DESC
  ''', [range.fromStr, range.toStr]);

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
      qty: (r['rtv_qty'] as num).toDouble(),
      status: r['status'] as String? ?? 'pending',
      agingDays: aging,
    );
  }).toList();

  return HoldMaterialReportData(
    bpHoldList: bpHoldList,
    rtvHoldList: rtvHoldList,
  );
});
