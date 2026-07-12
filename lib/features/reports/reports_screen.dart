import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';


class ReportsScreen extends ConsumerWidget {
  const ReportsScreen({super.key});

  static const _reports = [
    _ReportItem('Daily Production', Icons.today, 'Production summary by day'),
    _ReportItem('Machine-wise Report', Icons.precision_manufacturing, 'Output per machine'),
    _ReportItem('Operator-wise Report', Icons.person, 'Output per operator'),
    _ReportItem('Machine Downtime', Icons.build, 'Breakdown & maintenance log'),
    _ReportItem('BP Reject Analysis', Icons.cancel, 'Pre-plating rejection trends'),
    _ReportItem('AP Reject Analysis', Icons.remove_circle, 'Post-plating rejection trends'),
    _ReportItem('RTV Analysis', Icons.undo, 'Return to vendor summary'),
    _ReportItem('Vendor Performance', Icons.business, 'Faco turnaround & quality'),
    _ReportItem('Dispatch Report', Icons.send, 'Final dispatch to customers'),
    _ReportItem('Faco Pending Material', Icons.pending, 'Material still at Faco'),
    _ReportItem('Current Live Stock', Icons.inventory, 'Stock at every stage'),
    _ReportItem('Inventory Movement', Icons.swap_horiz, 'Full ledger movement'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Reports')),
      body: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _reports.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final r = _reports[i];
          return ListTile(
            leading: CircleAvatar(
              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
              child: Icon(r.icon, size: 20, color: Theme.of(context).colorScheme.primary),
            ),
            title: Text(r.title),
            subtitle: Text(r.subtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showComingSoon(context, r.title),
          );
        },
      ),
    );
  }

  void _showComingSoon(BuildContext context, String title) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$title — coming in next sprint')),
    );
  }
}

class _ReportItem {
  const _ReportItem(this.title, this.icon, this.subtitle);
  final String title;
  final IconData icon;
  final String subtitle;
}
