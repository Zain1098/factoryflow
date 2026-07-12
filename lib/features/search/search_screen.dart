import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/database_service.dart';
import '../../core/widgets/shared_widgets.dart';

final _searchQueryProvider = NotifierProvider<_SearchQueryNotifier, String>(_SearchQueryNotifier.new);

class _SearchQueryNotifier extends Notifier<String> {
  @override
  String build() => '';
  void set(String v) => state = v;
}

final _searchResultsProvider = FutureProvider.family<List<Map<String, dynamic>>, String>(
  (ref, query) async {
    if (query.trim().isEmpty) return [];
    final db = ref.watch(databaseServiceProvider);
    return db.searchRecords(batchNumber: query.trim(), limit: 50);
  },
);

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = ref.watch(_searchQueryProvider);
    final results = ref.watch(_searchResultsProvider(query));

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _searchCtrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Search batch, part, challan...',
            border: InputBorder.none,
            prefixIcon: Icon(Icons.search),
          ),
          onChanged: (v) => ref.read(_searchQueryProvider.notifier).set(v),
        ),
        actions: [
          if (_searchCtrl.text.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear),
              onPressed: () {
                _searchCtrl.clear();
                ref.read(_searchQueryProvider.notifier).set('');
              },
            ),
        ],
      ),
      body: query.isEmpty
          ? const EmptyState(
              message: 'Enter a batch number, part code, or challan number to search.',
              icon: Icons.search,
            )
          : results.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => EmptyState(message: 'Search error: $e', icon: Icons.error_outline),
              data: (records) {
                if (records.isEmpty) {
                  return EmptyState(
                    message: 'No results for "$query"',
                    icon: Icons.search_off,
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: records.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final r = records[i];
                    final table = r['_table'] as String? ?? '';
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: _tableColor(table).withValues(alpha: 0.12),
                        child: Icon(_tableIcon(table), color: _tableColor(table), size: 18),
                      ),
                      title: Text(
                        r['batch_number'] as String? ?? r['id'] as String? ?? '—',
                        style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text('${_tableLabel(table)} · ${r['date'] ?? ''}'),
                      trailing: Text(
                        _qtyLabel(r, table),
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    );
                  },
                );
              },
            ),
    );
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
      case 'dispatch_to_facos': return 'Dispatch to Faco';
      case 'receive_from_facos': return 'Receive from Faco';
      case 'ap_inspections': return 'AP Inspection';
      case 'rtvs': return 'RTV';
      case 'final_dispatches': return 'Final Dispatch';
      case 'material_receives': return 'Material Receive';
      default: return table;
    }
  }

  String _qtyLabel(Map<String, dynamic> r, String table) {
    final qty = r['qty'] ?? r['production_qty'] ?? r['qty_received'] ??
        r['dispatch_qty'] ?? r['rtv_qty'] ?? r['qty_checked'];
    if (qty == null) return '';
    return '${(qty as num).toInt()} PCS';
  }
}
