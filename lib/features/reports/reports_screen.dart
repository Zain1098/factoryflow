import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'report_providers.dart';
import '../../core/widgets/shared_widgets.dart';
import '../../core/services/export_service.dart';

// ─── Reports Hub ──────────────────────────────────────────────────────────────

class ReportsScreen extends ConsumerWidget {
  const ReportsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final range = ref.watch(reportDateRangeProvider);
    final theme = Theme.of(context);

    final sections = [
      _ReportSection('Production', Colors.teal, [
        _ReportTile(
          'Daily Production',
          Icons.today,
          Colors.teal,
          'Day-wise output, target & efficiency',
          () => _push(context, const _DailyProductionReport()),
        ),
        _ReportTile(
          'Machine-wise',
          Icons.precision_manufacturing,
          Colors.blue,
          'Output & downtime per machine',
          () => _push(context, const _MachineReport()),
        ),
        _ReportTile(
          'Operator-wise',
          Icons.person_outline,
          Colors.indigo,
          'Output & avg per operator',
          () => _push(context, const _OperatorReport()),
        ),
        _ReportTile(
          'Machine Downtime',
          Icons.build_outlined,
          Colors.orange,
          'Breakdown & maintenance log',
          () => _push(context, const _DowntimeReport()),
        ),
      ]),
      _ReportSection('Quality', Colors.red, [
        _ReportTile(
          'Reject Analysis',
          Icons.cancel_outlined,
          Colors.red,
          'BP + AP rejection by part & date',
          () => _push(context, const _RejectReport()),
        ),
        _ReportTile(
          'RTV Analysis',
          Icons.undo,
          Colors.deepOrange,
          'Return to vendor summary & status',
          () => _push(context, const _RtvReport()),
        ),
        _ReportTile(
          'Hold Material',
          Icons.back_hand_outlined,
          Colors.redAccent,
          'BP QC hold & active RTV aging',
          () => _push(context, const _HoldReport()),
        ),
      ]),
      _ReportSection('Inventory & Dispatch', Colors.green, [
        _ReportTile(
          'Live Stock',
          Icons.inventory_2_outlined,
          Colors.green,
          'Current stock at every stage',
          () => _push(context, const _LiveStockReport()),
        ),
        _ReportTile(
          'Faco Pending',
          Icons.pending_outlined,
          Colors.amber,
          'Material still at Faco vendor',
          () => _push(context, const _FacoPendingReport()),
        ),
        _ReportTile(
          'Dispatch Report',
          Icons.send_outlined,
          Colors.purple,
          'Final dispatch to customers',
          () => _push(context, const _DispatchReport()),
        ),
        _ReportTile(
          'Inventory Movement',
          Icons.swap_horiz,
          Colors.blueGrey,
          'Full stock ledger movement',
          () => _push(context, const _LedgerReport()),
        ),
      ]),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Reports'),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.date_range, size: 18),
            label: Text(
              '${_shortDate(range.from)} – ${_shortDate(range.to)}',
              style: const TextStyle(fontSize: 12),
            ),
            onPressed: () => _pickRange(context, ref, range),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _ReportsHero(
            range: range,
            onChooseRange: () => _pickRange(context, ref, range),
          ),
          const SizedBox(height: 18),
          Text(
            'QUICK RANGE',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              letterSpacing: 1.1,
            ),
          ),
          _DateRangeChips(range: range),
          const SizedBox(height: 14),
          for (final section in sections)
            _ReportSectionCard(section: section),
        ],
      ),
    );
  }

  void _push(BuildContext context, Widget screen) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
  }

  String _shortDate(DateTime d) => DateFormat('dd MMM').format(d);

  Future<void> _pickRange(
    BuildContext context,
    WidgetRef ref,
    DateRange current,
  ) async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
      initialDateRange: DateTimeRange(start: current.from, end: current.to),
    );
    if (picked != null) {
      ref.read(reportDateRangeProvider.notifier).set(
            DateRange(picked.start, picked.end),
          );
    }
  }
}

// ─── Date Range Quick Chips ───────────────────────────────────────────────────

class _ReportsHero extends StatelessWidget {
  const _ReportsHero({required this.range, required this.onChooseRange});

  final DateRange range;
  final VoidCallback onChooseRange;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.66),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: scheme.primary,
              borderRadius: BorderRadius.circular(15),
            ),
            child: Icon(Icons.analytics_outlined, color: scheme.onPrimary),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Factory insights', style: theme.textTheme.titleMedium),
                const SizedBox(height: 3),
                Text(
                  '${DateFormat('dd MMM').format(range.from)} - ${DateFormat('dd MMM yyyy').format(range.to)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton.filledTonal(
            tooltip: 'Choose report dates',
            onPressed: onChooseRange,
            icon: const Icon(Icons.calendar_month_outlined, size: 20),
          ),
        ],
      ),
    );
  }
}

class _DateRangeChips extends ConsumerWidget {
  const _DateRangeChips({required this.range});
  final DateRange range;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final presets = [
      ('Today', DateRange.today()),
      ('This Week', DateRange.thisWeek()),
      ('This Month', DateRange.thisMonth()),
      ('Last 30d', DateRange.last30()),
    ];

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: presets.map((p) {
          final isSelected =
              range.fromStr == p.$2.fromStr && range.toStr == p.$2.toStr;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text(p.$1),
              selected: isSelected,
              onSelected: (_) =>
                  ref.read(reportDateRangeProvider.notifier).set(p.$2),
              selectedColor: Theme.of(context).colorScheme.primary,
              labelStyle: TextStyle(
                color: isSelected
                    ? Theme.of(context).colorScheme.onPrimary
                    : Theme.of(context).colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(11),
                side: BorderSide(
                  color: isSelected
                      ? Colors.transparent
                      : Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

// ─── Section Header ───────────────────────────────────────────────────────────

class _ReportSectionCard extends StatelessWidget {
  const _ReportSectionCard({required this.section});
  final _ReportSection section;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 5, 8, 7),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: section.color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(section.title, style: theme.textTheme.titleSmall),
                const Spacer(),
                Text(
                  '${section.tiles.length} REPORTS',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 9,
                  ),
                ),
              ],
            ),
          ),
          ...section.tiles.map((tile) => _ReportListTile(tile: tile)),
        ],
      ),
    );
  }
}

class _ReportListTile extends StatelessWidget {
  const _ReportListTile({required this.tile});
  final _ReportTile tile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: tile.onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: tile.color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(tile.icon, color: tile.color, size: 21),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tile.title, style: theme.textTheme.titleSmall),
                    const SizedBox(height: 3),
                    Text(
                      tile.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.arrow_forward_rounded,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Models ───────────────────────────────────────────────────────────────────

class _ReportSection {
  const _ReportSection(this.title, this.color, this.tiles);
  final String title;
  final Color color;
  final List<_ReportTile> tiles;
}

class _ReportTile {
  const _ReportTile(
      this.title, this.icon, this.color, this.subtitle, this.onTap,);
  final String title;
  final IconData icon;
  final Color color;
  final String subtitle;
  final VoidCallback onTap;
}

// ─── Shared Report Scaffold ───────────────────────────────────────────────────

class _ReportPage extends ConsumerWidget {
  const _ReportPage({
    required this.title,
    required this.color,
    required this.summaryCards,
    required this.tableHeader,
    required this.rows,
    required this.emptyMessage,
    this.onExport,
  });

  final String title;
  final Color color;
  final List<_SummaryCard> summaryCards;
  final List<String> tableHeader;
  final List<List<String>> rows;
  final String emptyMessage;

  /// Optional export callback. When provided, shows a FAB for export.
  final VoidCallback? onExport;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final range = ref.watch(reportDateRangeProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: Text(
                '${_fmt(range.from)} – ${_fmt(range.to)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: onExport != null
          ? FloatingActionButton.extended(
              onPressed: onExport,
              icon: const Icon(Icons.ios_share_rounded),
              label: const Text('Export'),
              backgroundColor: color,
              foregroundColor: Colors.white,
            )
          : null,
      body: rows.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.inbox_outlined,
                    size: 56,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurfaceVariant
                        .withValues(alpha: 0.4),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    emptyMessage,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            )
          : Column(
              children: [
                if (summaryCards.isNotEmpty) _SummaryRow(summaryCards, color),
                Expanded(
                    child: _DataTable(
                        header: tableHeader, rows: rows, color: color,),),
              ],
            ),
    );
  }

  String _fmt(DateTime d) => DateFormat('dd MMM yy').format(d);
}

// ─── Summary Row ──────────────────────────────────────────────────────────────

class _SummaryRow extends StatelessWidget {
  const _SummaryRow(this.cards, this.color);
  final List<_SummaryCard> cards;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: color.withValues(alpha: 0.06),
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      child: Row(
        children: cards
            .map(
              (c) => Expanded(
                child: Column(
                  children: [
                    Text(
                      c.value,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                        color: color,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      c.label,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 10,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            )
            .toList(),
      ),
    );
  }
}

class _SummaryCard {
  const _SummaryCard(this.label, this.value);
  final String label;
  final String value;
}

// ─── Data Table ───────────────────────────────────────────────────────────────

class _DataTable extends StatelessWidget {
  const _DataTable(
      {required this.header, required this.rows, required this.color,});
  final List<String> header;
  final List<List<String>> rows;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SingleChildScrollView(
        child: DataTable(
          headingRowColor:
              WidgetStateProperty.all(color.withValues(alpha: 0.1)),
          headingTextStyle: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 12,
            color: color,
          ),
          dataTextStyle: theme.textTheme.bodySmall,
          columnSpacing: 20,
          horizontalMargin: 16,
          columns: header.map((h) => DataColumn(label: Text(h))).toList(),
          rows: rows
              .map(
                (r) => DataRow(
                  cells: r.map((c) => DataCell(Text(c))).toList(),
                ),
              )
              .toList(),
        ),
      ),
    );
  }
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

String _n(double v) =>
    v == v.toInt() ? v.toInt().toString() : v.toStringAsFixed(1);
String _pct(double v) => '${v.toStringAsFixed(1)}%';
String _mins(int m) => m >= 60 ? '${(m / 60).toStringAsFixed(1)}h' : '${m}m';

Widget _loadingOrError(AsyncValue<dynamic> async, Widget Function() builder) {
  return async.when(
    loading: () => const Center(child: CircularProgressIndicator()),
    error: (e, _) => Center(child: Text('Error: $e')),
    data: (_) => builder(),
  );
}

// ─── 1. Daily Production Report ───────────────────────────────────────────────

class _DailyProductionReport extends ConsumerWidget {
  const _DailyProductionReport();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(dailyProductionReportProvider);
    final range = ref.watch(reportDateRangeProvider);
    return _loadingOrError(async, () {
      final data = async.value!;
      return _ReportPage(
        title: 'Daily Production',
        color: Colors.teal,
        summaryCards: [
          _SummaryCard('Finished OK', _n(data.totalGood)),
          _SummaryCard('All-stage Reject', _n(data.totalBpReject)),
          _SummaryCard('Final Input', _n(data.totalProd)),
          _SummaryCard('Avg Eff.', _pct(data.avgEfficiency)),
          _SummaryCard('Rej %', _pct(data.overallRejectPct)),
        ],
        tableHeader: const [
          'Date',
          'Final Input',
          'All Rej',
          'Finished OK',
          'Target',
          'Eff %',
          'Rej %',
        ],
        rows: data
            .map(
              (r) => [
                _fmtDate(r.date),
                _n(r.totalProduction),
                _n(r.bpReject),
                _n(r.goodQty),
                _n(r.target),
                _pct(r.efficiency),
                _pct(r.rejectPct),
              ],
            )
            .toList(),
        emptyMessage: 'No production data for selected range',
        onExport: data.isEmpty
            ? null
            : () => ExportSheet.show(
                  context: context,
                  onExcel: () => ExportService.exportProductionReport(
                    context: context,
                    rows: data,
                    fromDate: range.fromStr,
                    toDate: range.toStr,
                    format: ExportFormat.excel,
                  ),
                  onPdf: () => ExportService.exportProductionReport(
                    context: context,
                    rows: data,
                    fromDate: range.fromStr,
                    toDate: range.toStr,
                    format: ExportFormat.pdf,
                  ),
                ),
      );
    });
  }
}

// ─── 2. Machine Report ────────────────────────────────────────────────────────

class _MachineReport extends ConsumerWidget {
  const _MachineReport();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(machineReportProvider);
    return _loadingOrError(async, () {
      final data = async.value!;
      final totalProd = data.fold(0.0, (s, r) => s + r.totalProduction);
      final totalDt = data.fold(0, (s, r) => s + r.downtimeMinutes);
      return _ReportPage(
        title: 'Machine-wise Report',
        color: Colors.blue,
        summaryCards: [
          _SummaryCard('Total Prod', _n(totalProd)),
          _SummaryCard('Machines', '${data.length}'),
          _SummaryCard('Total Downtime', _mins(totalDt)),
        ],
        tableHeader: const [
          'Machine',
          'Production',
          'BP Rej',
          'Good',
          'Rej %',
          'Downtime',
          'Days',
        ],
        rows: data
            .map(
              (r) => [
                r.machineName,
                _n(r.totalProduction),
                _n(r.bpReject),
                _n(r.goodQty),
                _pct(r.rejectPct),
                _mins(r.downtimeMinutes),
                '${r.runDays}',
              ],
            )
            .toList(),
        emptyMessage: 'No machine data for selected range',
      );
    });
  }
}

// ─── 3. Operator Report ───────────────────────────────────────────────────────

class _OperatorReport extends ConsumerWidget {
  const _OperatorReport();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(operatorReportProvider);
    return _loadingOrError(async, () {
      final data = async.value!;
      final totalProd = data.fold(0.0, (s, r) => s + r.totalProduction);
      return _ReportPage(
        title: 'Operator-wise Report',
        color: Colors.indigo,
        summaryCards: [
          _SummaryCard('Total Prod', _n(totalProd)),
          _SummaryCard('Operators', '${data.length}'),
        ],
        tableHeader: const [
          'Operator',
          'Production',
          'BP Rej',
          'Good',
          'Rej %',
          'Days',
          'Avg/Day',
        ],
        rows: data
            .map(
              (r) => [
                r.operatorName,
                _n(r.totalProduction),
                _n(r.bpReject),
                _n(r.goodQty),
                _pct(r.rejectPct),
                '${r.runDays}',
                _n(r.avgPerDay),
              ],
            )
            .toList(),
        emptyMessage: 'No operator data for selected range',
      );
    });
  }
}

// ─── 4. Downtime Report ───────────────────────────────────────────────────────

class _DowntimeReport extends ConsumerWidget {
  const _DowntimeReport();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(downtimeReportProvider);
    final range = ref.watch(reportDateRangeProvider);
    return _loadingOrError(async, () {
      final data = async.value!;
      final totalMins = data.fold(0, (s, r) => s + r.durationMinutes);
      return _ReportPage(
        title: 'Machine Downtime',
        color: Colors.orange,
        summaryCards: [
          _SummaryCard('Total Events', '${data.length}'),
          _SummaryCard('Total Downtime', _mins(totalMins)),
        ],
        tableHeader: const [
          'Date',
          'Machine',
          'Start',
          'End',
          'Duration',
          'Reason',
        ],
        rows: data
            .map(
              (r) => [
                _fmtDate(r.date),
                r.machineName,
                r.startTime,
                r.endTime ?? 'Ongoing',
                _mins(r.durationMinutes),
                r.reason.length > 20
                    ? '${r.reason.substring(0, 20)}…'
                    : r.reason,
              ],
            )
            .toList(),
        emptyMessage: 'No downtime events for selected range',
        onExport: data.isEmpty
            ? null
            : () => ExportSheet.show(
                  context: context,
                  onExcel: () => ExportService.exportDowntimeReport(
                    context: context,
                    rows: data,
                    fromDate: range.fromStr,
                    toDate: range.toStr,
                    format: ExportFormat.excel,
                  ),
                  onPdf: () => ExportService.exportDowntimeReport(
                    context: context,
                    rows: data,
                    fromDate: range.fromStr,
                    toDate: range.toStr,
                    format: ExportFormat.pdf,
                  ),
                ),
      );
    });
  }
}

// ─── 5. Reject Analysis ───────────────────────────────────────────────────────

class _RejectReport extends ConsumerWidget {
  const _RejectReport();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(rejectAnalysisProvider);
    final range = ref.watch(reportDateRangeProvider);
    return _loadingOrError(async, () {
      final data = async.value!;
      final totalBp = data.fold(0.0, (s, r) => s + r.bpReject);
      final totalAp = data.fold(0.0, (s, r) => s + r.apReject);
      final totalProd = data.fold(0.0, (s, r) => s + r.production);
      final overallPct =
          totalProd > 0 ? ((totalBp + totalAp) / totalProd * 100) : 0.0;
      return _ReportPage(
        title: 'Reject Analysis',
        color: Colors.red,
        summaryCards: [
          _SummaryCard('BP Reject', _n(totalBp)),
          _SummaryCard('AP Reject', _n(totalAp)),
          _SummaryCard('Total Rej', _n(totalBp + totalAp)),
          _SummaryCard('Overall %', _pct(overallPct)),
        ],
        tableHeader: const [
          'Date',
          'Part',
          'Production',
          'BP Rej',
          'AP Rej',
          'Total',
          'Rej %',
        ],
        rows: data
            .map(
              (r) => [
                _fmtDate(r.date),
                r.partName.length > 12
                    ? '${r.partName.substring(0, 12)}…'
                    : r.partName,
                _n(r.production),
                _n(r.bpReject),
                _n(r.apReject),
                _n(r.totalReject),
                _pct(r.rejectPct),
              ],
            )
            .toList(),
        emptyMessage: 'No reject data for selected range',
        onExport: data.isEmpty
            ? null
            : () => ExportSheet.show(
                  context: context,
                  onExcel: () => ExportService.exportQualityReport(
                    context: context,
                    rows: data,
                    fromDate: range.fromStr,
                    toDate: range.toStr,
                    format: ExportFormat.excel,
                  ),
                  onPdf: () => ExportService.exportQualityReport(
                    context: context,
                    rows: data,
                    fromDate: range.fromStr,
                    toDate: range.toStr,
                    format: ExportFormat.pdf,
                  ),
                ),
      );
    });
  }
}

// ─── 6. RTV Report ───────────────────────────────────────────────────────────

class _RtvReport extends ConsumerWidget {
  const _RtvReport();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(rtvReportProvider);
    return _loadingOrError(async, () {
      final data = async.value!;
      return _ReportPage(
        title: 'RTV Analysis',
        color: Colors.deepOrange,
        summaryCards: [
          _SummaryCard('Total RTV', _n(data.totalRtvQty)),
          _SummaryCard('Pending', '${data.pendingCount}'),
          _SummaryCard('Entries', '${data.length}'),
        ],
        tableHeader: const [
          'Date',
          'Part',
          'Vendor',
          'Qty',
          'Status',
          'Exp. Return',
          'Cycle',
        ],
        rows: data
            .map(
              (r) => [
                _fmtDate(r.date),
                r.partName.length > 10
                    ? '${r.partName.substring(0, 10)}…'
                    : r.partName,
                r.vendorName.length > 10
                    ? '${r.vendorName.substring(0, 10)}…'
                    : r.vendorName,
                _n(r.rtvQty),
                r.status,
                r.expectedReturn != null ? _fmtDate(r.expectedReturn!) : '—',
                '#${r.cycleNumber}',
              ],
            )
            .toList(),
        emptyMessage: 'No RTV data for selected range',
      );
    });
  }
}

// ─── 7. Dispatch Report ───────────────────────────────────────────────────────

class _DispatchReport extends ConsumerWidget {
  const _DispatchReport();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(dispatchReportProvider);
    return _loadingOrError(async, () {
      final data = async.value!;
      return _ReportPage(
        title: 'Dispatch Report',
        color: Colors.purple,
        summaryCards: [
          _SummaryCard('Total Dispatched', _n(data.totalDispatched)),
          _SummaryCard('Entries', '${data.length}'),
        ],
        tableHeader: const [
          'Date',
          'Part',
          'Customer',
          'Qty',
          'Challan',
          'Vehicle',
        ],
        rows: data
            .map(
              (r) => [
                _fmtDate(r.date),
                r.partName.length > 12
                    ? '${r.partName.substring(0, 12)}…'
                    : r.partName,
                r.customerName.length > 12
                    ? '${r.customerName.substring(0, 12)}…'
                    : r.customerName,
                _n(r.dispatchQty),
                r.challanNumber.isEmpty ? '—' : r.challanNumber,
                r.vehicleNumber.isEmpty ? '—' : r.vehicleNumber,
              ],
            )
            .toList(),
        emptyMessage: 'No dispatch data for selected range',
      );
    });
  }
}

// ─── 8. Faco Pending ─────────────────────────────────────────────────────────

class _FacoPendingReport extends ConsumerWidget {
  const _FacoPendingReport();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(facoPendingReportProvider);
    return _loadingOrError(async, () {
      final data = async.value!;
      final totalPending = data.fold(0.0, (s, r) => s + r.pending);
      return _ReportPage(
        title: 'Faco Pending Material',
        color: Colors.amber,
        summaryCards: [
          _SummaryCard('Total Pending', _n(totalPending)),
          _SummaryCard('Parts', '${data.length}'),
        ],
        tableHeader: const [
          'Part',
          'Vendor',
          'Dispatched',
          'Received',
          'Pending',
          'Since',
        ],
        rows: data
            .map(
              (r) => [
                r.partName.length > 12
                    ? '${r.partName.substring(0, 12)}…'
                    : r.partName,
                r.vendorName.length > 10
                    ? '${r.vendorName.substring(0, 10)}…'
                    : r.vendorName,
                _n(r.dispatched),
                _n(r.received),
                _n(r.pending),
                _fmtDate(r.oldestDate),
              ],
            )
            .toList(),
        emptyMessage: 'No pending material at Faco',
      );
    });
  }
}

// ─── 9. Live Stock ────────────────────────────────────────────────────────────

class _LiveStockReport extends ConsumerWidget {
  const _LiveStockReport();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(liveStockReportProvider);
    return _loadingOrError(async, () {
      final data = async.value!;
      final totalAll = data.fold(0.0, (s, r) => s + r.totalStock);
      return _ReportPage(
        title: 'Live Stock',
        color: Colors.green,
        summaryCards: [
          _SummaryCard('Total Stock', _n(totalAll)),
          _SummaryCard('Parts', '${data.length}'),
        ],
        tableHeader: const [
          'Part',
          'Raw',
          'BP',
          'Faco',
          'Pend AP',
          'Appr AP',
          'AP Rej',
          'RTV',
          'Total',
        ],
        rows: data
            .map(
              (r) => [
                r.partCode.isNotEmpty
                    ? r.partCode
                    : r.partName.substring(0, r.partName.length.clamp(0, 10)),
                _n(r.rawMaterial),
                _n(r.bpStock),
                _n(r.atFaco),
                _n(r.pendingAp),
                _n(r.approvedAp),
                _n(r.apRejected),
                _n(r.rtvStock),
                _n(r.totalStock),
              ],
            )
            .toList(),
        emptyMessage: 'No stock data available',
        onExport: data.isEmpty
            ? null
            : () => ExportSheet.show(
                  context: context,
                  onExcel: () => ExportService.exportStockReport(
                    context: context,
                    rows: data,
                    format: ExportFormat.excel,
                  ),
                  onPdf: () => ExportService.exportStockReport(
                    context: context,
                    rows: data,
                    format: ExportFormat.pdf,
                  ),
                ),
      );
    });
  }
}

// ─── 10. Ledger Movement ─────────────────────────────────────────────────────

class _LedgerReport extends ConsumerWidget {
  const _LedgerReport();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(ledgerMovementProvider);
    return _loadingOrError(async, () {
      final data = async.value!;
      return _ReportPage(
        title: 'Inventory Movement',
        color: Colors.blueGrey,
        summaryCards: [
          _SummaryCard('Entries', '${data.length}'),
        ],
        tableHeader: const [
          'Date',
          'Part',
          'Stage',
          'In/Out',
          'Qty',
          'Balance',
          'Source',
        ],
        rows: data
            .map(
              (r) => [
                _fmtDate(r.date),
                r.partName.length > 10
                    ? '${r.partName.substring(0, 10)}…'
                    : r.partName,
                _stageLabel(r.stage),
                r.direction == 'in' ? '▲ IN' : '▼ OUT',
                _n(r.qty),
                _n(r.runningBalance),
                _tableLabel(r.refTable),
              ],
            )
            .toList(),
        emptyMessage: 'No ledger entries for selected range',
      );
    });
  }
}

// ─── Label Helpers ────────────────────────────────────────────────────────────

String _fmtDate(String iso) {
  try {
    final d = DateTime.parse(iso);
    return DateFormat('dd MMM').format(d);
  } catch (_) {
    return iso;
  }
}

String _stageLabel(String stage) {
  const map = {
    'raw_material': 'Raw',
    'bp_stock': 'BP',
    'at_faco': 'Faco',
    'pending_ap': 'Pend AP',
    'approved_ap': 'Appr AP',
    'rtv_stock': 'RTV',
  };
  return map[stage] ?? stage;
}

String _tableLabel(String table) {
  const map = {
    'productions': 'Prod',
    'material_receives': 'MR',
    'dispatch_to_facos': 'D→Faco',
    'receive_from_facos': 'R←Faco',
    'ap_inspections': 'AP Insp',
    'bp_inspections': 'BP Insp',
    'rtvs': 'RTV',
    'final_dispatches': 'Dispatch',
  };
  return map[table] ?? table;
}

// ─── Hold Material Report Screen ────────────────────────────────────────────────

class _HoldReport extends ConsumerWidget {
  const _HoldReport();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reportAsync = ref.watch(holdMaterialReportProvider);
    final theme = Theme.of(context);

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Hold Material Report'),
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.warning_amber), text: 'BP QC Hold'),
              Tab(icon: Icon(Icons.sync_problem), text: 'RTV Hold (AP)'),
            ],
          ),
        ),
        body: reportAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) =>
              EmptyState(message: 'Error: $e', icon: Icons.error_outline),
          data: (data) {
            return TabBarView(
              children: [
                _buildBpHoldTab(context, data, theme),
                _buildRtvHoldTab(context, data, theme),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildBpHoldTab(
      BuildContext context, HoldMaterialReportData data, ThemeData theme,) {
    if (data.bpHoldList.isEmpty) {
      return const EmptyState(
        message: 'No material currently on BP QC Hold.',
        icon: Icons.check_circle_outline,
      );
    }

    return Column(
      children: [
        _buildSummaryCard(
          theme,
          title: 'Total BP Rejections / QC Hold',
          value: '${data.totalBpHold.toInt()} PCS',
          icon: Icons.warning_amber,
          color: Colors.redAccent,
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: data.bpHoldList.length,
            separatorBuilder: (_, __) => const Divider(),
            itemBuilder: (context, i) {
              final r = data.bpHoldList[i];
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: Colors.redAccent.withValues(alpha: 0.1),
                  child: const Icon(Icons.build_circle_outlined,
                      color: Colors.redAccent,),
                ),
                title: Row(
                  children: [
                    Expanded(
                        child: Text('${r.partCode} – ${r.partName}',
                            style:
                                const TextStyle(fontWeight: FontWeight.bold),),),
                    Text('${r.qty.toInt()} PCS',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.redAccent,),),
                  ],
                ),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 4.0),
                  child: Text(
                    'Machine: ${r.machineName} · Reason: ${r.reason} · Date: ${_fmtDate(r.date)}',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildRtvHoldTab(
      BuildContext context, HoldMaterialReportData data, ThemeData theme,) {
    if (data.rtvHoldList.isEmpty) {
      return const EmptyState(
        message: 'No active RTV (Post-Plating) Hold.',
        icon: Icons.check_circle_outline,
      );
    }

    return Column(
      children: [
        _buildSummaryCard(
          theme,
          title: 'Total RTV Pending Reinspection',
          value: '${data.totalRtvHold.toInt()} PCS',
          icon: Icons.sync_problem,
          color: Colors.orange,
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: data.rtvHoldList.length,
            separatorBuilder: (_, __) => const Divider(),
            itemBuilder: (context, i) {
              final r = data.rtvHoldList[i];
              final ageColor = r.agingDays > 10
                  ? Colors.red
                  : (r.agingDays > 5 ? Colors.orange : Colors.green);
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: Colors.orange.withValues(alpha: 0.1),
                  child: const Icon(Icons.undo, color: Colors.orange),
                ),
                title: Row(
                  children: [
                    Expanded(
                        child: Text('${r.partCode} – ${r.partName}',
                            style:
                                const TextStyle(fontWeight: FontWeight.bold),),),
                    Text('${r.qty.toInt()} PCS',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, color: Colors.orange,),),
                  ],
                ),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 4.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Vendor: ${r.vendorName} · Status: ${r.status}'),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2,),
                        decoration: BoxDecoration(
                          color: ageColor.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '${r.agingDays}d aging',
                          style: TextStyle(
                              color: ageColor,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildSummaryCard(
    ThemeData theme, {
    required String title,
    required String value,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 28),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,),),
                const SizedBox(height: 4),
                Text(value,
                    style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: color,),),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
