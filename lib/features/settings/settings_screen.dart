import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers/master_data_providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/shared_widgets.dart';
import '../auth/auth_providers.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final user = ref.watch(currentUserProvider).value;

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
          const Divider(),

          // ── Master Data Management ──────────────────────────────────────
          const _SectionLabel('Master Data'),

          ListTile(
            leading: const Icon(Icons.people_outline),
            title: const Text('Operators'),
            subtitle: const Text('Add, rename or remove operators'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => const _OperatorsPage(),
              ),
            ),
          ),

          ListTile(
            leading: const Icon(Icons.category_outlined),
            title: const Text('Parts'),
            subtitle: const Text('Add, rename or remove parts'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => const _PartsPage(),
              ),
            ),
          ),

          ListTile(
            leading: const Icon(Icons.precision_manufacturing_outlined),
            title: const Text('Machines'),
            subtitle: const Text('Add, rename or remove machines'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => const _MachinesPage(),
              ),
            ),
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

class _OperatorsPage extends ConsumerWidget {
  const _OperatorsPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final operators = ref.watch(operatorsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Operators')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showEditDialog(context, ref, null, null),
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
                      onPressed: () => _showEditDialog(
                        context, ref, op['id'] as String, op['name'] as String,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                      onPressed: () => _confirmDelete(context, ref, op['id'] as String, op['name'] as String),
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

  Future<void> _showEditDialog(
    BuildContext context, WidgetRef ref, String? id, String? current,
  ) async {
    final ctrl = TextEditingController(text: current ?? '');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(id == null ? 'Add Operator' : 'Rename Operator'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
          textCapitalization: TextCapitalization.words,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(id == null ? 'Add' : 'Save'),
          ),
        ],
      ),
    );
    if (confirmed != true || ctrl.text.trim().isEmpty) return;
    final repo = ref.read(masterDataRepositoryProvider);
    if (id == null) {
      await repo.insertOperator(ctrl.text.trim());
    } else {
      await repo.updateOperator(id, ctrl.text.trim());
    }
    ref.invalidate(operatorsProvider);
  }

  Future<void> _confirmDelete(
    BuildContext context, WidgetRef ref, String id, String name,
  ) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Remove Operator',
      message: 'Remove "$name"? They will no longer appear in dropdowns.',
      confirmLabel: 'Remove',
      isDestructive: true,
    );
    if (!confirmed) return;
    await ref.read(masterDataRepositoryProvider).deactivateOperator(id);
    ref.invalidate(operatorsProvider);
  }
}

// ─── Parts Page ───────────────────────────────────────────────────────────────

class _PartsPage extends ConsumerWidget {
  const _PartsPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final parts = ref.watch(partsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Parts')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showEditDialog(context, ref, null, null, null),
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
                        context, ref,
                        p['id'] as String,
                        p['code'] as String,
                        p['name'] as String,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                      onPressed: () => _confirmDelete(context, ref, p['id'] as String, p['name'] as String),
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

  Future<void> _showEditDialog(
    BuildContext context, WidgetRef ref,
    String? id, String? currentCode, String? currentName,
  ) async {
    final codeCtrl = TextEditingController(text: currentCode ?? '');
    final nameCtrl = TextEditingController(text: currentName ?? '');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(id == null ? 'Add Part' : 'Edit Part'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: codeCtrl,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Part Code (e.g. V21)'),
              textCapitalization: TextCapitalization.characters,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(labelText: 'Part Name'),
              textCapitalization: TextCapitalization.words,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(id == null ? 'Add' : 'Save'),
          ),
        ],
      ),
    );
    if (confirmed != true || codeCtrl.text.trim().isEmpty || nameCtrl.text.trim().isEmpty) return;
    final repo = ref.read(masterDataRepositoryProvider);
    if (id == null) {
      await repo.insertPart(code: codeCtrl.text.trim(), name: nameCtrl.text.trim());
    } else {
      await repo.updatePart(id, code: codeCtrl.text.trim(), name: nameCtrl.text.trim());
    }
    ref.invalidate(partsProvider);
  }

  Future<void> _confirmDelete(
    BuildContext context, WidgetRef ref, String id, String name,
  ) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Remove Part',
      message: 'Remove "$name"? It will no longer appear in dropdowns.',
      confirmLabel: 'Remove',
      isDestructive: true,
    );
    if (!confirmed) return;
    await ref.read(masterDataRepositoryProvider).deactivatePart(id);
    ref.invalidate(partsProvider);
  }
}

// ─── Machines Page ────────────────────────────────────────────────────────────

class _MachinesPage extends ConsumerWidget {
  const _MachinesPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final machines = ref.watch(machinesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Machines')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showEditDialog(context, ref, null, null, null, null),
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
            onReorder: (oldIndex, newIndex) async {
              if (newIndex > oldIndex) newIndex--;
              final repo = ref.read(masterDataRepositoryProvider);
              // Reassign sequence_order after reorder
              final reordered = [...list];
              final item = reordered.removeAt(oldIndex);
              reordered.insert(newIndex, item);
              for (var i = 0; i < reordered.length; i++) {
                ref.read(masterDataRepositoryProvider);
                repo.reorderMachine(reordered[i]['id'] as String, i + 1);
              }
              ref.invalidate(machinesProvider);
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
                        context, ref,
                        m['id'] as String,
                        m['name'] as String,
                        m['machine_code'] as String? ?? '',
                        m['sequence_order'] as int,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                      onPressed: () => _confirmDelete(context, ref, m['id'] as String, m['name'] as String),
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
    BuildContext context, WidgetRef ref,
    String? id, String? currentName, String? currentCode, int? currentSeq,
  ) async {
    final nameCtrl = TextEditingController(text: currentName ?? '');
    final codeCtrl = TextEditingController(text: currentCode ?? '');
    final seqCtrl = TextEditingController(text: currentSeq?.toString() ?? '');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(id == null ? 'Add Machine' : 'Edit Machine'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Machine Name (e.g. Bending)'),
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: codeCtrl,
              decoration: const InputDecoration(
                labelText: 'Batch Code Letter (e.g. B)',
                helperText: 'Used in batch number generation',
              ),
              textCapitalization: TextCapitalization.characters,
              maxLength: 3,
            ),
            const SizedBox(height: 4),
            TextField(
              controller: seqCtrl,
              decoration: const InputDecoration(labelText: 'Sequence Order (1, 2, 3…)'),
              keyboardType: TextInputType.number,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(id == null ? 'Add' : 'Save'),
          ),
        ],
      ),
    );
    if (confirmed != true ||
        nameCtrl.text.trim().isEmpty ||
        codeCtrl.text.trim().isEmpty) return;
    final seq = int.tryParse(seqCtrl.text) ?? 99;
    final repo = ref.read(masterDataRepositoryProvider);
    if (id == null) {
      await repo.insertMachine(
        name: nameCtrl.text.trim(),
        machineCode: codeCtrl.text.trim().toUpperCase(),
        sequenceOrder: seq,
      );
    } else {
      await repo.updateMachine(
        id,
        name: nameCtrl.text.trim(),
        machineCode: codeCtrl.text.trim().toUpperCase(),
      );
    }
    ref.invalidate(machinesProvider);
  }

  Future<void> _confirmDelete(
    BuildContext context, WidgetRef ref, String id, String name,
  ) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Remove Machine',
      message: 'Remove "$name"? It will no longer appear in dropdowns.',
      confirmLabel: 'Remove',
      isDestructive: true,
    );
    if (!confirmed) return;
    await ref.read(masterDataRepositoryProvider).deactivateMachine(id);
    ref.invalidate(machinesProvider);
  }
}
