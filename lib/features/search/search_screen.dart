import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/database_service.dart';
import '../../core/widgets/barcode_scanner_view.dart';
import '../../core/widgets/shared_widgets.dart';
import 'batch_genealogy_screen.dart';

enum _SearchMode { batch, challan, partId }

extension on _SearchMode {
  String get label => switch (this) {
        _SearchMode.batch => 'Batch Code',
        _SearchMode.challan => 'Challan No',
        _SearchMode.partId => 'Part ID / Code',
      };

  String get shortLabel => switch (this) {
        _SearchMode.batch => 'Batch',
        _SearchMode.challan => 'Challan',
        _SearchMode.partId => 'Part',
      };

  String get hint => switch (this) {
        _SearchMode.batch => 'Search batch code (e.g. BP-2408-001)',
        _SearchMode.challan => 'Search challan or gate pass (e.g. CH-1024)',
        _SearchMode.partId => 'Enter or paste part ID / code',
      };

  String get helper => switch (this) {
        _SearchMode.batch =>
          'Trace complete batch genealogy across production, quality, vendor & dispatch.',
        _SearchMode.challan =>
          'Find raw material inwards, vendor delivery or dispatch records by challan number.',
        _SearchMode.partId =>
          'Find all historical transactions linked to a specific part item.',
      };

  IconData get icon => switch (this) {
        _SearchMode.batch => Icons.qr_code_2_rounded,
        _SearchMode.challan => Icons.receipt_long_rounded,
        _SearchMode.partId => Icons.category_rounded,
      };
}

@immutable
class _SearchRequest {
  const _SearchRequest({required this.query, required this.mode});

  final String query;
  final _SearchMode mode;

  @override
  bool operator ==(Object other) =>
      other is _SearchRequest && other.query == query && other.mode == mode;

  @override
  int get hashCode => Object.hash(query, mode);
}

final _searchResultsProvider =
    FutureProvider.family<List<Map<String, dynamic>>, _SearchRequest>(
  (ref, request) async {
    final query = request.query.trim();
    if (query.isEmpty) return [];
    final db = ref.watch(databaseServiceProvider);
    return switch (request.mode) {
      _SearchMode.batch => db.searchRecords(batchNumber: query, limit: 50),
      _SearchMode.challan =>
        db.searchRecords(challanNumber: query, limit: 50),
      _SearchMode.partId => db.searchRecords(partId: query, limit: 50),
    };
  },
);

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _searchCtrl = TextEditingController();
  var _mode = _SearchMode.batch;

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(_onSearchChanged);
  }

  void _onSearchChanged() => setState(() {});

  @override
  void dispose() {
    _searchCtrl
      ..removeListener(_onSearchChanged)
      ..dispose();
    super.dispose();
  }

  void _selectMode(_SearchMode mode) {
    setState(() => _mode = mode);
  }

  Future<void> _triggerScan() async {
    final code = await BarcodeScannerView.scan(
      context,
      title: 'Scan ${_mode.label}',
      hint: 'Align barcode or QR code inside the frame',
    );
    if (code != null && code.isNotEmpty) {
      _searchCtrl.text = code;
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = _searchCtrl.text.trim();
    final results = ref.watch(
      _searchResultsProvider(_SearchRequest(query: query, mode: _mode)),
    );
    final theme = Theme.of(context);
    final isSearching = query.isNotEmpty;

    return Scaffold(
      backgroundColor: theme.colorScheme.surfaceContainerLowest,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Record Finder',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            Text(
              'Trace batches, challans & stage entries',
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
            tooltip: 'Scan Barcode / QR',
            icon: const Icon(Icons.qr_code_scanner_rounded),
            color: theme.colorScheme.primary,
            onPressed: _triggerScan,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // ── Search Input & Mode Selector Header ────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Column(
                children: [
                  // Search Bar Card
                  Container(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.03),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: TextField(
                      controller: _searchCtrl,
                      textInputAction: TextInputAction.search,
                      style: const TextStyle(fontSize: 14),
                      decoration: InputDecoration(
                        hintText: _mode.hint,
                        hintStyle: TextStyle(
                          fontSize: 13,
                          color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.65),
                        ),
                        prefixIcon: Icon(
                          _mode.icon,
                          size: 20,
                          color: theme.colorScheme.primary,
                        ),
                        suffixIcon: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (query.isNotEmpty)
                              IconButton(
                                tooltip: 'Clear search',
                                icon: const Icon(Icons.clear_rounded, size: 18),
                                onPressed: _searchCtrl.clear,
                              ),
                            IconButton(
                              tooltip: 'Scan Code',
                              icon: const Icon(Icons.qr_code_scanner_rounded, size: 20),
                              color: theme.colorScheme.primary,
                              onPressed: _triggerScan,
                            ),
                          ],
                        ),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      ),
                    ),
                  ),

                  const SizedBox(height: 10),

                  // Segmented Mode Selector Pills
                  Row(
                    children: _SearchMode.values.map((mode) {
                      final isSelected = mode == _mode;
                      return Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 3),
                          child: Material(
                            color: isSelected
                                ? theme.colorScheme.primary
                                : theme.colorScheme.surface,
                            borderRadius: BorderRadius.circular(10),
                            elevation: isSelected ? 1 : 0,
                            child: InkWell(
                              onTap: () => _selectMode(mode),
                              borderRadius: BorderRadius.circular(10),
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 8),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: isSelected
                                        ? theme.colorScheme.primary
                                        : theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
                                  ),
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      mode.icon,
                                      size: 15,
                                      color: isSelected
                                          ? Colors.white
                                          : theme.colorScheme.onSurfaceVariant,
                                    ),
                                    const SizedBox(width: 5),
                                    Text(
                                      mode.shortLabel,
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: isSelected
                                            ? FontWeight.bold
                                            : FontWeight.w500,
                                        color: isSelected
                                            ? Colors.white
                                            : theme.colorScheme.onSurface,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),

            // ── Main Content Area (Results or Idle Guide) ──────────────────
            Expanded(
              child: isSearching
                  ? _SearchResults(
                      query: query,
                      mode: _mode,
                      results: results,
                    )
                  : _SearchGuide(
                      selectedMode: _mode,
                      onSelect: _selectMode,
                      onScan: _triggerScan,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchGuide extends StatelessWidget {
  const _SearchGuide({
    required this.selectedMode,
    required this.onSelect,
    required this.onScan,
  });

  final _SearchMode selectedMode;
  final ValueChanged<_SearchMode> onSelect;
  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
      children: [
        // Helper Hint Card
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  selectedMode.icon,
                  color: theme.colorScheme.primary,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Search by ${selectedMode.label}',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      selectedMode.helper,
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.onSurfaceVariant,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),

        // Quick Scan CTA Card
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                theme.colorScheme.primaryContainer.withValues(alpha: 0.6),
                theme.colorScheme.surface,
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: theme.colorScheme.primary.withValues(alpha: 0.2),
            ),
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: onScan,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.qr_code_scanner_rounded,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Scan Barcode / QR Code',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                          Text(
                            'Camera scan for physical tags and challan labels',
                            style: TextStyle(
                              fontSize: 11,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.arrow_forward_ios_rounded,
                      size: 14,
                      color: theme.colorScheme.primary,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),

        const SizedBox(height: 18),

        // Searchable Modules Matrix
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 8),
          child: Row(
            children: [
              Container(
                width: 3,
                height: 13,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                'INDEXED FACTORY STAGES',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.0,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
        ),

        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
            ),
          ),
          child: Column(
            children: [
              _buildStageRow(
                icon: Icons.precision_manufacturing_rounded,
                color: Colors.teal,
                title: 'Production Pressing',
                desc: 'Batch origin, machine & operator run',
              ),
              _buildDivider(theme),
              _buildStageRow(
                icon: Icons.fact_check_rounded,
                color: Colors.blue,
                title: 'BP Quality Inspection',
                desc: 'Pass, hold & machine defect checks',
              ),
              _buildDivider(theme),
              _buildStageRow(
                icon: Icons.local_shipping_rounded,
                color: Colors.orange,
                title: 'Vendor Subcontracting',
                desc: 'Sent out & received back challans',
              ),
              _buildDivider(theme),
              _buildStageRow(
                icon: Icons.verified_rounded,
                color: Colors.green,
                title: 'AP Plating Quality',
                desc: 'Vendor acceptance, rejection & rework',
              ),
              _buildDivider(theme),
              _buildStageRow(
                icon: Icons.undo_rounded,
                color: Colors.red,
                title: 'Return to Vendor (RTV)',
                desc: 'Vendor debit notes & returns',
              ),
              _buildDivider(theme),
              _buildStageRow(
                icon: Icons.send_rounded,
                color: Colors.indigo,
                title: 'Final Customer Dispatch',
                desc: 'Delivery challans, invoices & trucks',
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildStageRow({
    required IconData icon,
    required Color color,
    required String title,
    required String desc,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: color, size: 16),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
                ),
                Text(
                  desc,
                  style: const TextStyle(fontSize: 10, color: Colors.grey),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDivider(ThemeData theme) {
    return Divider(
      height: 1,
      indent: 40,
      color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
    );
  }
}

class _SearchResults extends StatelessWidget {
  const _SearchResults({
    required this.query,
    required this.mode,
    required this.results,
  });

  final String query;
  final _SearchMode mode;
  final AsyncValue<List<Map<String, dynamic>>> results;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return results.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => EmptyState(
        message: 'Could not search right now. Please try again.\n$e',
        icon: Icons.error_outline,
      ),
      data: (records) {
        if (records.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
            child: Column(
              children: [
                Icon(
                  Icons.search_off_rounded,
                  size: 48,
                  color: theme.colorScheme.outline,
                ),
                const SizedBox(height: 12),
                Text(
                  'No ${mode.shortLabel.toLowerCase()} records found',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                ),
                const SizedBox(height: 4),
                Text(
                  'No matching results found for "$query". Check spelling or try scanning.',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          );
        }

        return ListView.separated(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
          itemCount: records.length + 1,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            if (i == 0) {
              return Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 4, top: 2),
                child: Text(
                  '${records.length} MATCHING RECORD${records.length == 1 ? '' : 'S'}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.8,
                    color: theme.colorScheme.primary,
                  ),
                ),
              );
            }

            final r = records[i - 1];
            final table = r['_table'] as String? ?? '';
            final color = _tableColor(table);
            final batchNum = r['batch_number'] as String?;
            final primaryCode = batchNum ??
                r['challan_number'] as String? ??
                r['supplier_challan'] as String? ??
                r['id'] as String? ??
                '—';
            final dateStr = r['date'] as String? ?? '';
            final qtyStr = _qtyLabel(r, table);

            return Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(14),
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
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: batchNum != null
                      ? () => Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) => BatchGenealogyScreen(
                                batchNumber: batchNum,
                              ),
                            ),
                          )
                      : () => _showRecordDetailsSheet(context, r, table),
                  child: Padding(
                    padding: const EdgeInsets.all(13),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Top row: Stage badge + Quantity pill
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: color.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(_tableIcon(table), size: 13, color: color),
                                  const SizedBox(width: 4),
                                  Text(
                                    _tableLabel(table).toUpperCase(),
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      color: color,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const Spacer(),
                            if (qtyStr.isNotEmpty)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  qtyStr,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: theme.colorScheme.onSurface,
                                  ),
                                ),
                              ),
                          ],
                        ),

                        const SizedBox(height: 8),

                        // Title: Code/Batch
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                primaryCode,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ),
                            if (batchNum != null)
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    'Genealogy',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: theme.colorScheme.primary,
                                    ),
                                  ),
                                  const SizedBox(width: 2),
                                  Icon(
                                    Icons.arrow_forward_ios_rounded,
                                    size: 11,
                                    color: theme.colorScheme.primary,
                                  ),
                                ],
                              ),
                          ],
                        ),

                        // Date & Extra metadata row
                        if (dateStr.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Icon(
                                Icons.calendar_today_outlined,
                                size: 12,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                dateStr,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showRecordDetailsSheet(
    BuildContext context,
    Map<String, dynamic> record,
    String table,
  ) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: _tableColor(table).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(_tableIcon(table), color: _tableColor(table), size: 20),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _tableLabel(table),
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                          ),
                          Text(
                            'Record Details',
                            style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Divider(),
                ...record.entries.where((e) => !e.key.startsWith('_')).map(
                      (e) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 120,
                              child: Text(
                                e.key.replaceAll('_', ' ').toUpperCase(),
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                '${e.value ?? '—'}',
                                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
              ],
            ),
          ),
        );
      },
    );
  }
}

Color _tableColor(String table) {
  switch (table) {
    case 'productions':
      return Colors.teal;
    case 'bp_inspections':
      return Colors.blue;
    case 'dispatch_to_facos':
      return Colors.orange;
    case 'receive_from_facos':
      return Colors.purple;
    case 'ap_inspections':
      return Colors.green;
    case 'rtvs':
      return Colors.red;
    case 'final_dispatches':
      return Colors.indigo;
    case 'material_receives':
      return Colors.amber.shade800;
    default:
      return Colors.blueGrey;
  }
}

IconData _tableIcon(String table) {
  switch (table) {
    case 'productions':
      return Icons.precision_manufacturing_rounded;
    case 'bp_inspections':
      return Icons.fact_check_rounded;
    case 'dispatch_to_facos':
      return Icons.local_shipping_rounded;
    case 'receive_from_facos':
      return Icons.move_to_inbox_rounded;
    case 'ap_inspections':
      return Icons.verified_rounded;
    case 'rtvs':
      return Icons.undo_rounded;
    case 'final_dispatches':
      return Icons.send_rounded;
    case 'material_receives':
      return Icons.input_rounded;
    default:
      return Icons.inventory_2_rounded;
  }
}

String _tableLabel(String table) {
  switch (table) {
    case 'productions':
      return 'Production';
    case 'bp_inspections':
      return 'BP Inspection';
    case 'dispatch_to_facos':
      return 'Dispatch to Vendor';
    case 'receive_from_facos':
      return 'Receive from Vendor';
    case 'ap_inspections':
      return 'AP Inspection';
    case 'rtvs':
      return 'Return to Vendor (RTV)';
    case 'final_dispatches':
      return 'Final Dispatch';
    case 'material_receives':
      return 'Material Inward';
    default:
      return table;
  }
}

String _qtyLabel(Map<String, dynamic> record, String table) {
  final qty = record['qty'] ??
      record['production_qty'] ??
      record['qty_received'] ??
      record['dispatch_qty'] ??
      record['rtv_qty'] ??
      record['qty_checked'];
  if (qty is! num) return '';
  return '${qty.toInt()} PCS';
}
