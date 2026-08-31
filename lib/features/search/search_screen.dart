import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/database_service.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/barcode_scanner_view.dart';
import '../../core/widgets/shared_widgets.dart';
import 'batch_genealogy_screen.dart';

enum _SearchMode { batch, challan, partId }

extension on _SearchMode {
  String get label => switch (this) {
        _SearchMode.batch => 'Batch',
        _SearchMode.challan => 'Challan',
        _SearchMode.partId => 'Part ID',
      };

  String get hint => switch (this) {
        _SearchMode.batch => 'e.g. BP-2408-001',
        _SearchMode.challan => 'e.g. CH-1024',
        _SearchMode.partId => 'Paste the part ID',
      };

  String get helper => switch (this) {
        _SearchMode.batch => 'Trace a batch through production, quality and dispatch.',
        _SearchMode.challan => 'Find material or dispatch records by challan number.',
        _SearchMode.partId => 'Find all records linked to one saved part ID.',
      };

  IconData get icon => switch (this) {
        _SearchMode.batch => Icons.qr_code_2_rounded,
        _SearchMode.challan => Icons.receipt_long_outlined,
        _SearchMode.partId => Icons.inventory_2_outlined,
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

  @override
  Widget build(BuildContext context) {
    final query = _searchCtrl.text.trim();
    final results = ref.watch(
      _searchResultsProvider(_SearchRequest(query: query, mode: _mode)),
    );
    final theme = Theme.of(context);
    final isSearching = query.isNotEmpty;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'RECORD FINDER',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.primary,
                      letterSpacing: 1.1,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text('Find a factory record',
                      style: theme.textTheme.headlineSmall,),
                  const SizedBox(height: 6),
                  Text(
                    'Choose what you have, then enter its number.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _searchCtrl,
                    autofocus: true,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: _mode.hint,
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (query.isNotEmpty)
                            IconButton(
                              tooltip: 'Clear search',
                              icon: const Icon(Icons.close_rounded),
                              onPressed: _searchCtrl.clear,
                            ),
                          IconButton(
                            tooltip: 'Scan Barcode / QR',
                            icon: const Icon(Icons.qr_code_scanner_rounded),
                            color: theme.colorScheme.primary,
                            onPressed: () async {
                              final code = await BarcodeScannerView.scan(
                                context,
                                title: 'Scan ${_mode.label}',
                                hint: 'Align barcode or QR code inside the frame',
                              );
                              if (code != null && code.isNotEmpty) {
                                _searchCtrl.text = code;
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: isSearching
                  ? _SearchResults(
                      query: query,
                      mode: _mode,
                      results: results,
                      tableColor: _tableColor,
                      tableIcon: _tableIcon,
                      tableLabel: _tableLabel,
                      qtyLabel: _qtyLabel,
                    )
                  : _SearchGuide(
                      selectedMode: _mode,
                      onSelect: _selectMode,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchGuide extends StatelessWidget {
  const _SearchGuide({required this.selectedMode, required this.onSelect});

  final _SearchMode selectedMode;
  final ValueChanged<_SearchMode> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 116),
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: theme.colorScheme.primary.withValues(alpha: 0.14),
            ),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(selectedMode.icon, color: Colors.white),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  selectedMode.helper,
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.35),
                ),
              ),
            ],
          ),
        ),
        const SectionHeader('Quick search'),
        ..._SearchMode.values.map(
          (mode) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _QuickSearchTile(
              mode: mode,
              selected: mode == selectedMode,
              onTap: () => onSelect(mode),
            ),
          ),
        ),
        const SectionHeader('What you can find'),
        Text(
          'Production, inspections, vendor movement, vendor rework and final dispatch records are searched only in the active workspace.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.45,
          ),
        ),
      ],
    );
  }
}

class _QuickSearchTile extends StatelessWidget {
  const _QuickSearchTile({
    required this.mode,
    required this.selected,
    required this.onTap,
  });

  final _SearchMode mode;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = selected ? theme.colorScheme.primary : AppColors.steelBlueMid;
    return Material(
      color: selected
          ? color.withValues(alpha: 0.10)
          : theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: selected
                  ? color.withValues(alpha: 0.45)
                  : theme.colorScheme.outlineVariant,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(mode.icon, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Search by ${mode.label}',
                        style: theme.textTheme.titleSmall,),
                    const SizedBox(height: 3),
                    Text(mode.hint,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),),
                  ],
                ),
              ),
              Icon(
                selected ? Icons.check_circle_rounded : Icons.arrow_forward_rounded,
                color: color,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SearchResults extends StatelessWidget {
  const _SearchResults({
    required this.query,
    required this.mode,
    required this.results,
    required this.tableColor,
    required this.tableIcon,
    required this.tableLabel,
    required this.qtyLabel,
  });

  final String query;
  final _SearchMode mode;
  final AsyncValue<List<Map<String, dynamic>>> results;
  final Color Function(String) tableColor;
  final IconData Function(String) tableIcon;
  final String Function(String) tableLabel;
  final String Function(Map<String, dynamic>, String) qtyLabel;

  @override
  Widget build(BuildContext context) {
    return results.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => EmptyState(
        message: 'Could not search right now. Please try again.\n$e',
        icon: Icons.error_outline,
      ),
      data: (records) {
        if (records.isEmpty) {
          return EmptyState(
            message: 'No ${mode.label.toLowerCase()} records found for "$query".',
            icon: Icons.search_off_rounded,
          );
        }
        return ListView.separated(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 116),
          itemCount: records.length + 1,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            if (i == 0) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '${records.length} matching record${records.length == 1 ? '' : 's'}',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              );
            }
            final r = records[i - 1];
            final table = r['_table'] as String? ?? '';
            final color = tableColor(table);
            return Material(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(18),
              child: ListTile(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                  side: BorderSide(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
                leading: CircleAvatar(
                  backgroundColor: color.withValues(alpha: 0.12),
                  child: Icon(tableIcon(table), color: color, size: 18),
                ),
                title: Text(
                  r['batch_number'] as String? ?? r['challan_number'] as String? ?? r['supplier_challan'] as String? ?? r['id'] as String? ?? '—',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontFamily: 'monospace',
                      ),
                ),
                subtitle: Text('${tableLabel(table)} · ${r['date'] ?? ''}'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      qtyLabel(r, table),
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                            color: color,
                          ),
                    ),
                    if (r['batch_number'] != null) ...[
                      const SizedBox(width: 4),
                      const Icon(Icons.chevron_right, size: 18, color: Colors.grey),
                    ],
                  ],
                ),
                onTap: r['batch_number'] != null
                    ? () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => BatchGenealogyScreen(
                              batchNumber: r['batch_number'] as String,
                            ),
                          ),
                        );
                      }
                    : null,
              ),
            );
          },
        );
      },
    );
  }
}

Color _tableColor(String table) {
  switch (table) {
    case 'productions': return Colors.teal;
    case 'bp_inspections': return Colors.blue;
    case 'dispatch_to_facos': return Colors.orange;
    case 'receive_from_facos': return Colors.purple;
    case 'ap_inspections': return Colors.green;
    case 'rtvs': return Colors.red;
    case 'final_dispatches': return Colors.indigo;
    default: return Colors.grey;
  }
}

IconData _tableIcon(String table) {
  switch (table) {
    case 'productions': return Icons.precision_manufacturing;
    case 'bp_inspections': return Icons.fact_check;
    case 'dispatch_to_facos': return Icons.local_shipping;
    case 'receive_from_facos': return Icons.move_to_inbox;
    case 'ap_inspections': return Icons.verified;
    case 'rtvs': return Icons.undo;
    case 'final_dispatches': return Icons.send;
    default: return Icons.inventory_2;
  }
}

String _tableLabel(String table) {
  switch (table) {
    case 'productions': return 'Production';
    case 'bp_inspections': return 'BP Inspection';
    case 'dispatch_to_facos': return 'Dispatch to Vendor';
    case 'receive_from_facos': return 'Receive from Vendor';
    case 'ap_inspections': return 'AP Inspection';
    case 'rtvs': return 'RTV';
    case 'final_dispatches': return 'Final Dispatch';
    case 'material_receives': return 'Material Receive';
    default: return table;
  }
}

String _qtyLabel(Map<String, dynamic> record, String table) {
  final qty = record['qty'] ?? record['production_qty'] ?? record['qty_received'] ?? record['dispatch_qty'] ?? record['rtv_qty'] ?? record['qty_checked'];
  if (qty is! num) return '';
  return '${qty.toInt()} PCS';
}
