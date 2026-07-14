import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers/master_data_providers.dart';
import '../../core/providers/batch_config_provider.dart';
import '../../core/providers/production_flow_provider.dart';
import '../../core/models/app_user.dart';
import '../../core/services/data_management_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/shared_widgets.dart';
import '../auth/auth_providers.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final user = ref.watch(currentUserProvider).value;
    final showBatchNumber = ref.watch(batchConfigProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          if (user != null)
            ListTile(
              leading: CircleAvatar(
                child: Text(user.name.isNotEmpty ? user.name[0].toUpperCase() : '?'),
              ),
              title: Text(user.name),
              subtitle: Text('${user.role.value} · ${user.email}'),
            ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('Theme'),
            subtitle: Text(themeMode.name[0].toUpperCase() + themeMode.name.substring(1)),
            trailing: SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(value: ThemeMode.light, icon: Icon(Icons.light_mode, size: 18)),
                ButtonSegment(value: ThemeMode.system, icon: Icon(Icons.brightness_auto, size: 18)),
                ButtonSegment(value: ThemeMode.dark, icon: Icon(Icons.dark_mode, size: 18)),
              ],
              selected: {themeMode},
              onSelectionChanged: (s) =>
                  ref.read(themeModeProvider.notifier).setThemeMode(s.first),
              style: const ButtonStyle(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.qr_code_2_outlined),
            title: const Text('Batch Tracking'),
            subtitle: const Text('Enable batch numbers on entries and forms'),
            value: showBatchNumber,
            onChanged: (val) {
              ref.read(batchConfigProvider.notifier).toggle(val);
            },
          ),
          const Divider(),
          const _SectionLabel('Production Flow'),
          ListTile(
            leading: const Icon(Icons.account_tree_outlined),
            title: const Text('Multi-Machine Flow'),
            subtitle: const Text('Define which machines a part must pass through'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => const _ProductionFlowPage()),
            ),
          ),
          const Divider(),
          const _SectionLabel('Master Data'),
          ListTile(
            leading: const Icon(Icons.people_outline),
            title: const Text('Operators'),
            subtitle: const Text('Add, rename or remove operators'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => const _OperatorsPage()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.category_outlined),
            title: const Text('Parts'),
            subtitle: const Text('Add, rename or remove parts'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => const _PartsPage()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.precision_manufacturing_outlined),
            title: const Text('Machines'),
            subtitle: const Text('Add, rename or remove machines'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => const _MachinesPage()),
            ),
          ),
          const Divider(),
          const _SectionLabel('Data Management'),
          ListTile(
            leading: const Icon(Icons.delete_sweep_outlined, color: Colors.orange),
            title: const Text('Erase Data'),
            subtitle: const Text('Clear a section or all transaction records'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => const _EraseDataPage()),
            ),
          ),
          if (user != null)
            ListTile(
              leading: const Icon(Icons.no_accounts_outlined, color: Colors.red),
              title: const Text('Delete My Account',
                  style: TextStyle(color: Colors.red),),
              subtitle: const Text('Remove account access and clear local data'),
              onTap: () => _confirmDeleteAccount(context, ref, user),
            ),
          const Divider(),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('App Version'),
            trailing: Text('1.0.0', style: TextStyle(color: Colors.grey)),
          ),
          const ListTile(
            leading: Icon(Icons.factory_outlined),
            title: Text('FactoryFlow Manufacturing ERP'),
            subtitle: Text('PRD v2.4 — Phase 1'),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.logout, color: Colors.red),
            title: const Text('Sign Out', style: TextStyle(color: Colors.red)),
            onTap: () async {
              await ref.read(currentUserProvider.notifier).signOut();
              if (context.mounted) context.go('/login');
            },
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        label.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

// ─── Operators Page ───────────────────────────────────────────────────────────

class _OperatorsPage extends ConsumerStatefulWidget {
  const _OperatorsPage();
  @override
  ConsumerState<_OperatorsPage> createState() => _OperatorsPageState();
}

class _OperatorsPageState extends ConsumerState<_OperatorsPage> {
  @override
  Widget build(BuildContext context) {
    final operators = ref.watch(operatorsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Operators')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showEditDialog(null, null),
        child: const Icon(Icons.add),
      ),
      body: operators.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(message: 'Error: $e', icon: Icons.error_outline),
        data: (list) {
          if (list.isEmpty) {
            return const EmptyState(
              message: 'No operators yet.\nTap + to add one.',
              icon: Icons.people_outline,
            );
          }
          return ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final op = list[i];
              return ListTile(
                leading: CircleAvatar(
                  child: Text((op['name'] as String)[0].toUpperCase()),
                ),
                title: Text(op['name'] as String),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () => _showEditDialog(op['id'] as String, op['name'] as String),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                      onPressed: () => _confirmDelete(op['id'] as String, op['name'] as String),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _showEditDialog(String? id, String? current) async {
    // Controllers live inside StatefulBuilder so they are never accessed
    // after the dialog is dismissed (fixes "used after disposed" crash).
    String? resultName;
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final ctrl = TextEditingController(text: current ?? '');
        return StatefulBuilder(
          builder: (ctx, setState) {
            return AlertDialog(
              title: Text(id == null ? 'Add Operator' : 'Rename Operator'),
              content: SingleChildScrollView(
                child: TextField(
                  controller: ctrl,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Name'),
                  textCapitalization: TextCapitalization.words,
                  onSubmitted: (_) {
                    if (ctrl.text.trim().isNotEmpty) {
                      resultName = ctrl.text.trim();
                      Navigator.pop(ctx);
                    }
                  },
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () {
                    if (ctrl.text.trim().isEmpty) return;
                    resultName = ctrl.text.trim();
                    Navigator.pop(ctx);
                  },
                  child: Text(id == null ? 'Add' : 'Save'),
                ),
              ],
            );
          },
        );
      },
    );
    if (resultName == null || resultName!.isEmpty) return;
    final repo = ref.read(masterDataRepositoryProvider);
    if (id == null) {
      await repo.insertOperator(resultName!);
    } else {
      await repo.updateOperator(id, resultName!);
    }
  }

  Future<void> _confirmDelete(String id, String name) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Remove Operator',
      message: 'Remove "$name"? They will no longer appear in dropdowns.',
      confirmLabel: 'Remove',
      isDestructive: true,
    );
    if (!confirmed) return;
    await ref.read(masterDataRepositoryProvider).deactivateOperator(id);
  }
}

// ─── Parts Page ───────────────────────────────────────────────────────────────

class _PartsPage extends ConsumerStatefulWidget {
  const _PartsPage();
  @override
  ConsumerState<_PartsPage> createState() => _PartsPageState();
}

class _PartsPageState extends ConsumerState<_PartsPage> {
  @override
  Widget build(BuildContext context) {
    final parts = ref.watch(partsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Parts')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showEditDialog(null, null, null),
        child: const Icon(Icons.add),
      ),
      body: parts.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(message: 'Error: $e', icon: Icons.error_outline),
        data: (list) {
          if (list.isEmpty) {
            return const EmptyState(
              message: 'No parts yet.\nTap + to add one.',
              icon: Icons.category_outlined,
            );
          }
          return ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final p = list[i];
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                  child: Text(
                    p['code'] as String,
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                ),
                title: Text(p['name'] as String),
                subtitle: Text('Code: ${p['code']}'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () => _showEditDialog(
                        p['id'] as String,
                        p['code'] as String,
                        p['name'] as String,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                      onPressed: () => _confirmDelete(p['id'] as String, p['name'] as String),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _showEditDialog(String? id, String? currentCode, String? currentName) async {
    // Controllers live inside StatefulBuilder so they are never accessed
    // after the dialog is dismissed (fixes "used after disposed" crash and
    // the 99903px RenderFlex overflow caused by keyboard insets).
    String? resultCode;
    String? resultName;
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final codeCtrl = TextEditingController(text: currentCode ?? '');
        final nameCtrl = TextEditingController(text: currentName ?? '');
        return StatefulBuilder(
          builder: (ctx, setState) {
            void submit() {
              if (codeCtrl.text.trim().isEmpty || nameCtrl.text.trim().isEmpty) return;
              resultCode = codeCtrl.text.trim();
              resultName = nameCtrl.text.trim();
              Navigator.pop(ctx);
            }
            return AlertDialog(
              title: Text(id == null ? 'Add Part' : 'Edit Part'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: codeCtrl,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: 'Part Code',
                        hintText: 'e.g. V21',
                      ),
                      textCapitalization: TextCapitalization.characters,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: nameCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Part Name',
                        hintText: 'e.g. Valve 21',
                      ),
                      textCapitalization: TextCapitalization.words,
                      onSubmitted: (_) => submit(),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: submit,
                  child: Text(id == null ? 'Add' : 'Save'),
                ),
              ],
            );
          },
        );
      },
    );
    if (resultCode == null || resultName == null) return;
    final repo = ref.read(masterDataRepositoryProvider);
    if (id == null) {
      await repo.insertPart(code: resultCode!, name: resultName!);
    } else {
      await repo.updatePart(id, code: resultCode!, name: resultName!);
    }
  }

  Future<void> _confirmDelete(String id, String name) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Remove Part',
      message: 'Remove "$name"? It will no longer appear in dropdowns.',
      confirmLabel: 'Remove',
      isDestructive: true,
    );
    if (!confirmed) return;
    await ref.read(masterDataRepositoryProvider).deactivatePart(id);
  }
}

// ─── Machines Page ────────────────────────────────────────────────────────────

class _MachinesPage extends ConsumerStatefulWidget {
  const _MachinesPage();
  @override
  ConsumerState<_MachinesPage> createState() => _MachinesPageState();
}

class _MachinesPageState extends ConsumerState<_MachinesPage> {
  @override
  Widget build(BuildContext context) {
    final machines = ref.watch(machinesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Machines')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showEditDialog(null, null, null, null),
        child: const Icon(Icons.add),
      ),
      body: machines.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(message: 'Error: $e', icon: Icons.error_outline),
        data: (list) {
          if (list.isEmpty) {
            return const EmptyState(
              message: 'No machines yet.\nTap + to add one.',
              icon: Icons.precision_manufacturing_outlined,
            );
          }
          return ReorderableListView.builder(
            padding: const EdgeInsets.only(bottom: 80),
            itemCount: list.length,
            onReorderItem: (oldIndex, newIndex) async {
              final reordered = [...list];
              final item = reordered.removeAt(oldIndex);
              reordered.insert(newIndex, item);
              final repo = ref.read(masterDataRepositoryProvider);
              for (var i = 0; i < reordered.length; i++) {
                await repo.reorderMachine(reordered[i]['id'] as String, i + 1);
              }
            },
            itemBuilder: (context, i) {
              final m = list[i];
              return ListTile(
                key: ValueKey(m['id']),
                leading: CircleAvatar(
                  backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
                  child: Text(
                    m['machine_code'] as String? ?? '?',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                  ),
                ),
                title: Text(m['name'] as String),
                subtitle: Text('Code: ${m['machine_code'] ?? '—'} · Seq: ${m['sequence_order']}'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () => _showEditDialog(
                        m['id'] as String,
                        m['name'] as String,
                        m['machine_code'] as String? ?? '',
                        m['sequence_order'] as int,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                      onPressed: () => _confirmDelete(m['id'] as String, m['name'] as String),
                    ),
                    const Icon(Icons.drag_handle, color: Colors.grey),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _showEditDialog(
    String? id, String? currentName, String? currentCode, int? currentSeq,
  ) async {
    // Controllers live inside StatefulBuilder so they are never accessed
    // after the dialog is dismissed (fixes "used after disposed" crash).
    String? resultName;
    String? resultCode;
    int? resultSeq;
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final nameCtrl = TextEditingController(text: currentName ?? '');
        final codeCtrl = TextEditingController(text: currentCode ?? '');
        final seqCtrl = TextEditingController(text: currentSeq?.toString() ?? '');
        return StatefulBuilder(
          builder: (ctx, setState) {
            void submit() {
              if (nameCtrl.text.trim().isEmpty || codeCtrl.text.trim().isEmpty) return;
              resultName = nameCtrl.text.trim();
              resultCode = codeCtrl.text.trim().toUpperCase();
              resultSeq = int.tryParse(seqCtrl.text.trim()) ?? 1;
              Navigator.pop(ctx);
            }
            return AlertDialog(
              title: Text(id == null ? 'Add Machine' : 'Edit Machine'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameCtrl,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: 'Machine Name',
                        hintText: 'e.g. Bending',
                      ),
                      textCapitalization: TextCapitalization.words,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: codeCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Batch Code Letter',
                        hintText: 'e.g. B',
                        helperText: 'Used in batch number generation',
                      ),
                      textCapitalization: TextCapitalization.characters,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: seqCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Sequence Order',
                        hintText: 'e.g. 1',
                      ),
                      keyboardType: TextInputType.number,
                      onSubmitted: (_) => submit(),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: submit,
                  child: Text(id == null ? 'Add' : 'Save'),
                ),
              ],
            );
          },
        );
      },
    );

    if (resultName == null || resultCode == null) return;

    final repo = ref.read(masterDataRepositoryProvider);
    if (id == null) {
      await repo.insertMachine(
        name: resultName!,
        machineCode: resultCode!,
        sequenceOrder: resultSeq ?? 1,
      );
    } else {
      await repo.updateMachine(id, name: resultName!, machineCode: resultCode!);
    }
  }

  Future<void> _confirmDelete(String id, String name) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Remove Machine',
      message: 'Remove "$name"? It will no longer appear in dropdowns.',
      confirmLabel: 'Remove',
      isDestructive: true,
    );
    if (!confirmed) return;
    await ref.read(masterDataRepositoryProvider).deactivateMachine(id);
  }
}

// ─── Account Delete Helper ────────────────────────────────────────────────────

Future<void> _confirmDeleteAccount(
  BuildContext context,
  WidgetRef ref,
  AppUser user,
) async {
  // Controller lives inside StatefulBuilder so it is never accessed after
  // the dialog is dismissed (fixes "used after disposed" crash).
  bool confirmed = false;
  await showDialog<void>(
    context: context,
    builder: (ctx) {
      final ctrl = TextEditingController();
      return StatefulBuilder(
        builder: (ctx, setState) {
          return AlertDialog(
            title: const Text('Delete Account'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'This will remove your account access and clear local app data.\n'
                    'Type DELETE to confirm.',
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: ctrl,
                    autofocus: true,
                    decoration: const InputDecoration(hintText: 'Type DELETE'),
                    onSubmitted: (_) {
                      if (ctrl.text.trim() == 'DELETE') {
                        confirmed = true;
                        Navigator.pop(ctx);
                      }
                    },
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error,
                ),
                onPressed: () {
                  if (ctrl.text.trim() == 'DELETE') {
                    confirmed = true;
                    Navigator.pop(ctx);
                  }
                },
                child: const Text('Delete'),
              ),
            ],
          );
        },
      );
    },
  );
  if (!confirmed) return;
  final svc = ref.read(dataManagementServiceProvider);
  try {
    await svc.deleteAccountData(user: user);
    await ref.read(currentUserProvider.notifier).signOut();
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Account deletion failed: $e'),
        backgroundColor: Theme.of(context).colorScheme.error,
      ),
    );
    return;
  }
  if (context.mounted) context.go('/login');
}

// ─── Production Flow Settings Page ──────────────────────────────────────────

class _ProductionFlowPage extends ConsumerWidget {
  const _ProductionFlowPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final flow = ref.watch(productionFlowProvider);
    final machines = ref.watch(machinesProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Multi-Machine Flow')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Text(
              'When enabled, a batch is marked WIP until all selected machines have recorded production. '
              'Only complete batches can be dispatched to Faco.',
              style: TextStyle(fontSize: 13),
            ),
          ),
          const SizedBox(height: 16),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.account_tree_outlined),
            title: const Text('Enable Multi-Machine Flow'),
            subtitle: Text(flow.enabled ? 'Active — WIP tracking ON' : 'Disabled — single machine mode'),
            value: flow.enabled,
            onChanged: (v) => ref.read(productionFlowProvider.notifier).setEnabled(v),
          ),
          if (flow.enabled) ...[
            const Divider(),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Required Machines (select all that a part must pass through)',
                style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
            machines.when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => Text('Error: $e'),
              data: (list) => Wrap(
                spacing: 8,
                runSpacing: 8,
                children: list.map((m) {
                  final id = m['id'] as String;
                  final name = m['name'] as String;
                  final isSelected = flow.requiredMachineIds.contains(id);
                  return FilterChip(
                    label: Text(name),
                    selected: isSelected,
                    onSelected: (selected) {
                      final updated = [...flow.requiredMachineIds];
                      if (selected) {
                        updated.add(id);
                      } else {
                        updated.remove(id);
                      }
                      ref.read(productionFlowProvider.notifier).setRequiredMachines(updated);
                    },
                  );
                }).toList(),
              ),
            ),
            if (flow.requiredMachineIds.isNotEmpty) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.check_circle_outline, color: Colors.green, size: 18),
                    const SizedBox(width: 8),
                    Text(
                      '${flow.requiredMachineIds.length} machines required for a batch to be Ready',
                      style: const TextStyle(color: Colors.green, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

// ─── Erase Data Page ──────────────────────────────────────────────────────────

class _EraseDataPage extends ConsumerStatefulWidget {
  const _EraseDataPage();
  @override
  ConsumerState<_EraseDataPage> createState() => _EraseDataPageState();
}

class _EraseDataPageState extends ConsumerState<_EraseDataPage> {
  Map<EraseSection, int> _counts = {};
  bool _loading = true;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    _loadCounts();
  }

  Future<void> _loadCounts() async {
    final counts =
        await ref.read(dataManagementServiceProvider).getSectionCounts();
    if (mounted) {
      setState(() {
        _counts = counts;
        _loading = false;
      });
    }
  }

  Future<void> _eraseSection(EraseSection section) async {
    final user = ref.read(currentUserProvider).value;
    if (user == null) return;
    final confirmed = await showConfirmDialog(
      context,
      title: 'Erase ${section.label}',
      message:
          'This will permanently delete ${_counts[section] ?? 0} records.\n'
          'This action cannot be undone.',
      confirmLabel: 'Erase',
      isDestructive: true,
    );
    if (!confirmed) return;
    setState(() => _working = true);
    await ref.read(dataManagementServiceProvider).eraseSection(
          section: section,
          userId: user.id,
          factoryId: user.factoryId,
        );
    await _loadCounts();
    setState(() => _working = false);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${section.label} erased.'),
        backgroundColor: Colors.orange,
      ),);
    }
  }

  Future<void> _eraseAll() async {
    final user = ref.read(currentUserProvider).value;
    if (user == null) return;
    final first = await showConfirmDialog(
      context,
      title: 'Erase All Transaction Data',
      message:
          'Deletes ALL production, dispatch, inspection and ledger records.\n'
          'Master data (parts, machines) will be kept.',
      confirmLabel: 'Yes, Continue',
      isDestructive: true,
    );
    if (!first) return;
    if (!mounted) return;
    final second = await showConfirmDialog(
      context,
      title: 'Final Confirmation',
      message: 'This cannot be undone. Erase all transaction data now?',
      confirmLabel: 'Erase Everything',
      isDestructive: true,
    );
    if (!second) return;
    setState(() => _working = true);
    await ref.read(dataManagementServiceProvider).eraseAllTransactionData(
          userId: user.id,
          factoryId: user.factoryId,
        );
    await _loadCounts();
    setState(() => _working = false);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('All transaction data erased.'),
        backgroundColor: Colors.orange,
      ),);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Erase Data')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              children: [
                ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.orange.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                            color: Colors.orange.withValues(alpha: 0.4),),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.info_outline,
                              color: Colors.orange, size: 18,),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Erased data is permanently removed from this device.',
                              style:
                                  TextStyle(color: Colors.orange, fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'Erase by Section',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    ...EraseSection.values.map((s) {
                      final count = _counts[s] ?? 0;
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(s.label),
                        subtitle: Text('$count records'),
                        trailing: TextButton.icon(
                          icon: const Icon(Icons.delete_outline,
                              size: 16, color: Colors.red,),
                          label: const Text('Erase',
                              style: TextStyle(color: Colors.red),),
                          onPressed: (_working || count == 0)
                              ? null
                              : () => _eraseSection(s),
                        ),
                      );
                    }),
                    const Divider(height: 32),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: theme.colorScheme.error,
                        minimumSize: const Size(double.infinity, 50),
                      ),
                      onPressed: _working ? null : _eraseAll,
                      icon: const Icon(Icons.delete_forever_outlined),
                      label: const Text('Erase All Transaction Data'),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Master data (parts, machines, operators etc.) will not be deleted.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 32),
                  ],
                ),
                if (_working)
                  const ColoredBox(
                    color: Colors.black26,
                    child: Center(child: CircularProgressIndicator()),
                  ),
              ],
            ),
    );
  }
}
