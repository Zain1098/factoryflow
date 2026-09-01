import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'report_providers.dart';
import '../../core/widgets/shared_widgets.dart';
import '../../core/services/export_service.dart';

// ─── Reports Hub ──────────────────────────────────────────────────────────────

class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> {
  int _selectedCategoryIndex = 0; // 0 = All, 1 = Production, 2 = Quality, 3 = Inventory
  String _searchQuery = '';
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final range = ref.watch(reportDateRangeProvider);
    final theme = Theme.of(context);

    final allSections = [
      _ReportSection('Production & Output', Colors.teal, [
        _ReportTile(
          'Daily Production Report',
          Icons.today_rounded,
          Colors.teal,
          'Day-wise output, planned target & efficiency',
          () => _push(context, const _DailyProductionReport()),
        ),
        _ReportTile(
          'Machine-wise Production',
          Icons.precision_manufacturing_rounded,
          Colors.blue,
          'Output volume & downtime per machine',
          () => _push(context, const _MachineReport()),
        ),
        _ReportTile(
          'Operator Performance',
          Icons.person_outline_rounded,
          Colors.indigo,
          'Output quantity & average speed per operator',
          () => _push(context, const _OperatorReport()),
        ),
        _ReportTile(
          'Machine Downtime & Maintenance',
          Icons.build_outlined,
          Colors.orange,
          'Breakdown reasons, duration & repair logs',
          () => _push(context, const _DowntimeReport()),
        ),
      ]),
      _ReportSection('Quality & Rejections', Colors.red, [
        _ReportTile(
          'Reject & Defect Analysis',
          Icons.cancel_outlined,
          Colors.red,
          'BP + AP inspection rejections by part & reason',
          () => _push(context, const _RejectReport()),
        ),
        _ReportTile(
          'RTV & Vendor Debit Notes',
          Icons.undo_rounded,
          Colors.deepOrange,
          'Return to vendor summary, debits & recovery',
          () => _push(context, const _RtvReport()),
        ),
        _ReportTile(
          'Hold & Quarantined Material',
          Icons.back_hand_outlined,
          Colors.pink,
          'BP hold & vendor rework aging status',
          () => _push(context, const _HoldReport()),
        ),
      ]),
      _ReportSection('Inventory & Logistics', Colors.green, [
        _ReportTile(
          'Live Stock at All Stages',
          Icons.inventory_2_outlined,
          Colors.green,
          'Current balances across production, vendor & dispatch',
          () => _push(context, const LiveStockReport()),
        ),
        _ReportTile(
          'Vendor Pending Subcontracting',
          Icons.pending_actions_rounded,
          Colors.amber.shade800,
          'Material dispatched to FACO still awaiting return',
          () => _push(context, const _FacoPendingReport()),
        ),
        _ReportTile(
          'Finished Goods Dispatch',
          Icons.local_shipping_outlined,
          Colors.purple,
          'Final customer dispatches, gate passes & invoices',
          () => _push(context, const _DispatchReport()),
        ),
        _ReportTile(
          'Inventory Movement Ledger',
          Icons.swap_horiz_rounded,
          Colors.blueGrey,
          'Complete chronological stock transaction ledger',
          () => _push(context, const _LedgerReport()),
        ),
      ]),
    ];

    // Filter by Category
    List<_ReportSection> displayedSections;
    if (_selectedCategoryIndex == 1) {
      displayedSections = [allSections[0]];
    } else if (_selectedCategoryIndex == 2) {
      displayedSections = [allSections[1]];
    } else if (_selectedCategoryIndex == 3) {
      displayedSections = [allSections[2]];
    } else {
      displayedSections = allSections;
    }

    // Filter by Search Query
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      displayedSections = displayedSections
          .map((sec) {
            final filteredTiles = sec.tiles.where((t) {
              return t.title.toLowerCase().contains(q) ||
                  t.subtitle.toLowerCase().contains(q);
            }).toList();
            return _ReportSection(sec.title, sec.color, filteredTiles);
          })
          .where((sec) => sec.tiles.isNotEmpty)
          .toList();
    }

    return Scaffold(
      backgroundColor: theme.colorScheme.surfaceContainerLowest,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Reports & Analytics',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            Text(
              '${_shortDate(range.from)} – ${_shortDate(range.to)}',
              style: TextStyle(
                fontSize: 11,
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.normal,
              ),
            ),
          ],
        ),
        elevation: 0,
        centerTitle: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.date_range_rounded),
            tooltip: 'Select Custom Date Range',
            color: theme.colorScheme.primary,
            onPressed: () => _pickRange(context, ref, range),
          ),
          IconButton(
            icon: const Icon(Icons.search_rounded),
            onPressed: () => GlobalQuickSearchSheet.show(context),
            tooltip: 'Search / Barcode Lookup',
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          // ── Analytics Range & Header Banner ────────────────────────────────
          _ReportsHero(
            range: range,
            onChooseRange: () => _pickRange(context, ref, range),
          ),

          const SizedBox(height: 12),

          // ── Quick Date Range Preset Chips ──────────────────────────────────
          _DateRangeChips(
            range: range,
            onCustomPick: () => _pickRange(context, ref, range),
          ),

          const SizedBox(height: 14),

          // ── Search & Filter Field ──────────────────────────────────────────
          Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.45),
              ),
            ),
            child: TextField(
              controller: _searchCtrl,
              onChanged: (val) => setState(() => _searchQuery = val.trim()),
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Filter reports by name or metric...',
                hintStyle: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                ),
                prefixIcon: const Icon(Icons.filter_list_rounded, size: 18),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear_rounded, size: 16),
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() => _searchQuery = '');
                        },
                      )
                    : null,
                filled: true,
                fillColor: Colors.transparent,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
              ),
            ),
          ),

          const SizedBox(height: 12),

          // ── Category Pills (All, Production, Quality, Inventory) ───────────
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildCategoryPill(0, 'All Reports (11)', Icons.dashboard_rounded),
                const SizedBox(width: 8),
                _buildCategoryPill(1, 'Production (4)', Icons.precision_manufacturing_rounded),
                const SizedBox(width: 8),
                _buildCategoryPill(2, 'Quality (3)', Icons.fact_check_rounded),
                const SizedBox(width: 8),
                _buildCategoryPill(3, 'Inventory & Dispatch (4)', Icons.inventory_2_rounded),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // ── Report Section Cards ───────────────────────────────────────────
          if (displayedSections.isEmpty) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Column(
                children: [
                  Icon(
                    Icons.search_off_rounded,
                    size: 44,
                    color: theme.colorScheme.outline,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'No reports match "$_searchQuery"',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Try searching for production, reject, stock, downtime...',
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ] else ...[
            for (final section in displayedSections)
              _ReportSectionCard(section: section),
          ],
        ],
      ),
    );
  }

  Widget _buildCategoryPill(int index, String label, IconData icon) {
    final theme = Theme.of(context);
    final isSelected = _selectedCategoryIndex == index;
    return Material(
      color: isSelected
          ? theme.colorScheme.primary
          : theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(10),
      elevation: isSelected ? 1 : 0,
      child: InkWell(
        onTap: () => setState(() => _selectedCategoryIndex = index),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isSelected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 14,
                color: isSelected
                    ? Colors.white
                    : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                  color: isSelected ? Colors.white : theme.colorScheme.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _push(BuildContext context, Widget screen) {
    Navigator.push(context, MaterialPageRoute<void>(builder: (_) => screen));
  }

  String _shortDate(DateTime d) => DateFormat('dd MMM yyyy').format(d);

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
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            scheme.primaryContainer.withValues(alpha: 0.7),
            scheme.surface,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: scheme.primary.withValues(alpha: 0.15),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: scheme.primary,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.analytics_rounded, color: Colors.white, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Plant Intelligence Hub',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Filtered: ${DateFormat('dd MMM').format(range.from)} – ${DateFormat('dd MMM yyyy').format(range.to)}',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onChooseRange,
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.calendar_month_rounded, size: 15, color: scheme.primary),
                      const SizedBox(width: 4),
                      Text(
                        'Dates',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: scheme.primary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DateRangeChips extends ConsumerWidget {
  const _DateRangeChips({required this.range, required this.onCustomPick});
  final DateRange range;
  final VoidCallback onCustomPick;

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
      child: Row(
        children: [
          ...presets.map((p) {
            final isSelected =
                range.fromStr == p.$2.fromStr && range.toStr == p.$2.toStr;
            return Padding(
              padding: const EdgeInsets.only(right: 6),
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
                  fontSize: 11,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(9),
                  side: BorderSide(
                    color: isSelected
                        ? Colors.transparent
                        : Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.4),
                  ),
                ),
              ),
            );
          }),
        ],
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 6),
            child: Row(
              children: [
                Container(
                  width: 3,
                  height: 13,
                  decoration: BoxDecoration(
                    color: section.color,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  section.title.toUpperCase(),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.9,
                    color: section.color,
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: section.color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '${section.tiles.length} REPORTS',
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                      color: section.color,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.45),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.02),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Column(
                children: section.tiles.asMap().entries.map((entry) {
                  final i = entry.key;
                  final tile = entry.value;
                  return Column(
                    children: [
                      _ReportListTile(tile: tile),
                      if (i < section.tiles.length - 1)
                        Divider(
                          height: 1,
                          indent: 62,
                          endIndent: 14,
                          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.35),
                        ),
                    ],
                  );
                }).toList(),
              ),
            ),
          ),
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
      child: InkWell(
        onTap: tile.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: tile.color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(tile.icon, color: tile.color, size: 19),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tile.title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      tile.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.arrow_forward_ios_rounded,
                size: 13,
                color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
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
    this.title,
    this.icon,
    this.color,
    this.subtitle,
    this.onTap,
  );
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
                  child: _ReportDataCards(
                    header: tableHeader,
                    rows: rows,
                    color: color,
                    hasExportAction: onExport != null,
                  ),
                ),
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
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: color.withValues(alpha: 0.06),
      child: SizedBox(
        height: 92,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
          itemCount: cards.length,
          separatorBuilder: (_, __) => const SizedBox(width: 10),
          itemBuilder: (context, index) {
            final card = cards[index];
            return Container(
              width: 132,
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              decoration: BoxDecoration(
                color: scheme.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: color.withValues(alpha: 0.18)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    card.value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 18,
                      color: color,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    card.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            );
          },
        ),
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

class _ReportDataCards extends StatelessWidget {
  const _ReportDataCards({
    required this.header,
    required this.rows,
    required this.color,
    required this.hasExportAction,
  });
  final List<String> header;
  final List<List<String>> rows;
  final Color color;
  final bool hasExportAction;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: EdgeInsets.fromLTRB(16, 14, 16, hasExportAction ? 96 : 28),
      itemCount: rows.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) => _ReportDataCard(
        header: header,
        row: rows[index],
        color: color,
      ),
    );
  }
}

class _ReportDataCard extends StatelessWidget {
  const _ReportDataCard({
    required this.header,
    required this.row,
    required this.color,
  });

  final List<String> header;
  final List<String> row;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final title = row.isEmpty ? '' : row.first;
    final fields = List.generate(
      row.length > 1 ? row.length - 1 : 0,
      (index) => (header[index + 1], row[index + 1]),
    );

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: scheme.onSurface,
            ),
          ),
          if (fields.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: fields
                  .map(
                    (field) => _ReportMetric(
                      label: field.$1,
                      value: field.$2,
                      color: color,
                    ),
                  )
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }
}

class _ReportMetric extends StatelessWidget {
  const _ReportMetric({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(minWidth: 116),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface,
                ),
          ),
        ],
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
        title: 'Vendor Pending Material',
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
        emptyMessage: 'No pending material at vendor',
      );
    });
  }
}

// ─── 9. Live Stock ────────────────────────────────────────────────────────────

class LiveStockReport extends ConsumerWidget {
  const LiveStockReport({super.key, this.partId});

  final String? partId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(liveStockReportProvider);
    return _loadingOrError(async, () {
      final data = async.value!;
      final filteredData = partId == null
          ? data
          : data.where((row) => row.partId == partId).toList();
      final totalAll = filteredData.fold(0.0, (s, r) => s + r.totalStock);
      return _ReportPage(
        title: partId == null ? 'Live Stock' : 'Part Live Stock',
        color: Colors.green,
        summaryCards: [
          _SummaryCard('Total Stock', _n(totalAll)),
          _SummaryCard('Parts', '${filteredData.length}'),
        ],
        tableHeader: const [
          'Part',
          'Raw',
          'Prod Rej',
          'BP',
          'BP Hold',
          'BP Rej',
          'Vendor',
          'Pend AP',
          'Appr AP',
          'AP Rej',
          'RTV Hold',
          'RTV Vendor',
          'Total',
        ],
        rows: filteredData
            .map(
              (r) => [
                r.partCode.isNotEmpty
                    ? r.partCode
                    : r.partName.substring(0, r.partName.length.clamp(0, 10)),
                _n(r.rawMaterial),
                _n(r.productionRejected),
                _n(r.bpStock),
                _n(r.bpHold),
                _n(r.bpRejected),
                _n(r.atFaco),
                _n(r.pendingAp),
                _n(r.approvedAp),
                _n(r.apRejected),
                _n(r.rtvStock),
                _n(r.rtvAtVendor),
                _n(r.totalStock),
              ],
            )
            .toList(),
        emptyMessage: 'No stock data available',
        onExport: filteredData.isEmpty
            ? null
            : () => ExportSheet.show(
                  context: context,
                  onExcel: () => ExportService.exportStockReport(
                    context: context,
                    rows: filteredData,
                    format: ExportFormat.excel,
                  ),
                  onPdf: () => ExportService.exportStockReport(
                    context: context,
                    rows: filteredData,
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
    'production_rejected': 'Prod reject',
    'bp_stock': 'BP',
    'bp_hold': 'BP Hold',
    'bp_rejected': 'BP reject',
    'at_faco': 'Vendor',
    'pending_ap': 'Pend AP',
    'approved_ap': 'Appr AP',
    'ap_rejected': 'AP reject',
    'rtv_stock': 'Vendor rework',
    'rtv_at_vendor': 'At vendor rework',
  };
  return map[stage] ?? stage;
}

String _tableLabel(String table) {
  const map = {
    'productions': 'Prod',
    'material_receives': 'MR',
    'dispatch_to_facos': 'D→Vendor',
    'receive_from_facos': 'R←Vendor',
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
              Tab(icon: Icon(Icons.sync_problem), text: 'Vendor Rework Hold'),
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
    BuildContext context,
    HoldMaterialReportData data,
    ThemeData theme,
  ) {
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
                  child: const Icon(
                    Icons.build_circle_outlined,
                    color: Colors.redAccent,
                  ),
                ),
                title: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${r.partCode} – ${r.partName}',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    Text(
                      '${r.qty.toInt()} PCS',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.redAccent,
                      ),
                    ),
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
    BuildContext context,
    HoldMaterialReportData data,
    ThemeData theme,
  ) {
    if (data.rtvHoldList.isEmpty) {
      return const EmptyState(
          message: 'No stock awaiting vendor rework.',
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
                      child: Text(
                        '${r.partCode} – ${r.partName}',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    Text(
                      '${r.qty.toInt()} PCS',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.orange,
                      ),
                    ),
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
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: ageColor.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '${r.agingDays}d aging',
                          style: TextStyle(
                            color: ageColor,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
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
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
