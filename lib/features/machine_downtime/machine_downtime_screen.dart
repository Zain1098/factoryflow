import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/providers/master_data_providers.dart';
import '../../core/widgets/shared_widgets.dart';
import '../auth/auth_providers.dart';
import 'machine_downtime_providers.dart';

class MachineDowntimeScreen extends ConsumerStatefulWidget {
  const MachineDowntimeScreen({super.key});

  @override
  ConsumerState<MachineDowntimeScreen> createState() => _MachineDowntimeScreenState();
}

class _MachineDowntimeScreenState extends ConsumerState<MachineDowntimeScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _formKey = GlobalKey<FormState>();

  String? _machineId;
  String? _operatorId;
  final _reasonCtrl = TextEditingController();
  final _remarksCtrl = TextEditingController();
  TimeOfDay _startTime = TimeOfDay.now();
  TimeOfDay? _endTime;
  bool _isSaving = false;
  String? _error;
  String? _success;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _reasonCtrl.dispose();
    _remarksCtrl.dispose();
    super.dispose();
  }

  String _formatTime(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _pickTime(bool isStart) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: isStart ? _startTime : (_endTime ?? TimeOfDay.now()),
    );
    if (picked != null) {
      setState(() {
        if (isStart) {
          _startTime = picked;
        } else {
          _endTime = picked;
        }
      });
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _isSaving = true; _error = null; _success = null; });

    try {
      final user = ref.read(currentUserProvider).value;
      final repo = ref.read(machineDowntimeRepositoryProvider);
      final result = await repo.save(
        machineId: _machineId!,
        startTime: _formatTime(_startTime),
        endTime: _endTime != null ? _formatTime(_endTime!) : null,
        reason: _reasonCtrl.text.trim(),
        operatorId: _operatorId,
        remarks: _remarksCtrl.text.trim().isEmpty ? null : _remarksCtrl.text.trim(),
        createdBy: user?.id ?? 'unknown',
      );

      if (result.success) {
        setState(() => _success = 'Downtime entry saved!');
        ref.invalidate(machineDowntimeListProvider);
        _reset();
      } else {
        setState(() => _error = result.error ?? 'Save failed');
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _reset() {
    _formKey.currentState?.reset();
    _reasonCtrl.clear();
    _remarksCtrl.clear();
    setState(() {
      _machineId = null;
      _operatorId = null;
      _startTime = TimeOfDay.now();
      _endTime = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Machine Downtime'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.add_circle_outline), text: 'New Entry'),
            Tab(icon: Icon(Icons.history), text: 'History'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [_buildForm(), _buildHistory()],
      ),
    );
  }

  Widget _buildForm() {
    final machines = ref.watch(machinesProvider);
    final operators = ref.watch(operatorsProvider);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.calendar_today, size: 18),
                  const SizedBox(width: 8),
                  Text(DateFormat('dd MMM yyyy').format(DateTime.now())),
                  const Spacer(),
                  const Text('Auto', style: TextStyle(color: Colors.green, fontSize: 12)),
                ],
              ),
            ),
            const SizedBox(height: 16),

            const SectionHeader('Machine & Operator'),

            machines.when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => ErrorBanner('Could not load machines: $e'),
              data: (list) => AppDropdown<String>(
                label: 'Machine',
                isRequired: true,
                prefixIcon: const Icon(Icons.precision_manufacturing_outlined),
                value: _machineId,
                items: list.map((m) => DropdownMenuItem(
                  value: m['id'] as String,
                  child: Text(m['name'] as String),
                ),).toList(),
                onChanged: (v) => setState(() => _machineId = v),
                validator: (v) => v == null ? 'Machine is required' : null,
              ),
            ),
            const SizedBox(height: 12),

            operators.when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => ErrorBanner('Could not load operators: $e'),
              data: (list) => AppDropdown<String>(
                label: 'Operator (optional)',
                prefixIcon: const Icon(Icons.person_outlined),
                value: _operatorId,
                items: list.map((o) => DropdownMenuItem(
                  value: o['id'] as String,
                  child: Text(o['name'] as String),
                ),).toList(),
                onChanged: (v) => setState(() => _operatorId = v),
              ),
            ),
            const SizedBox(height: 16),

            const SectionHeader('Downtime Period'),

            Row(
              children: [
                Expanded(
                  child: _TimePickerTile(
                    label: 'Start Time',
                    time: _startTime,
                    onTap: () => _pickTime(true),
                    color: Colors.orange,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _TimePickerTile(
                    label: 'End Time (optional)',
                    time: _endTime,
                    onTap: () => _pickTime(false),
                    color: Colors.green,
                  ),
                ),
              ],
            ),

            if (_endTime != null) ...[
              const SizedBox(height: 8),
              _DurationDisplay(start: _startTime, end: _endTime!),
            ],

            const SizedBox(height: 16),
            const SectionHeader('Reason'),

            AppFormField(
              label: 'Reason',
              controller: _reasonCtrl,
              prefixIcon: const Icon(Icons.build_outlined),
              validator: (v) => v == null || v.trim().isEmpty ? 'Reason is required' : null,
            ),
            const SizedBox(height: 12),

            AppFormField(
              label: 'Remarks (optional)',
              controller: _remarksCtrl,
              maxLines: 2,
              prefixIcon: const Icon(Icons.notes),
            ),

            const SizedBox(height: 16),
            if (_error != null) ErrorBanner(_error!),
            if (_success != null) SuccessBanner(_success!),
            const SizedBox(height: 16),
            SaveButton(onPressed: _save, isLoading: _isSaving),
          ],
        ),
      ),
    );
  }

  Widget _buildHistory() {
    final list = ref.watch(machineDowntimeListProvider);
    return list.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => EmptyState(message: 'Error: $e', icon: Icons.error_outline),
      data: (records) {
        if (records.isEmpty) {
          return const EmptyState(
            message: 'No downtime entries yet.',
            icon: Icons.build_outlined,
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: records.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final r = records[i];
            final duration = r['duration_minutes'] as int?;
            final isSynced = r['sync_status'] == 'synced';
            return ListTile(
              leading: CircleAvatar(
                backgroundColor: Colors.orange.withValues(alpha: 0.12),
                child: const Icon(Icons.build, color: Colors.orange, size: 20),
              ),
              title: Text(r['machine_name'] ?? '—'),
              subtitle: Text('${r['reason']} · ${r['date']}'),
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    duration != null ? '${duration}m' : 'Ongoing',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: duration == null ? Colors.orange : null,
                    ),
                  ),
                  Icon(
                    isSynced ? Icons.cloud_done : Icons.cloud_upload_outlined,
                    size: 14,
                    color: isSynced ? Colors.green : Colors.orange,
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _TimePickerTile extends StatelessWidget {
  const _TimePickerTile({
    required this.label,
    required this.time,
    required this.onTap,
    required this.color,
  });

  final String label;
  final TimeOfDay? time;
  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        decoration: BoxDecoration(
          border: Border.all(color: theme.colorScheme.outline),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),),
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(Icons.access_time, size: 16, color: color),
                const SizedBox(width: 6),
                Text(
                  time != null
                      ? '${time!.hour.toString().padLeft(2, '0')}:${time!.minute.toString().padLeft(2, '0')}'
                      : 'Tap to set',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: time != null ? color : theme.colorScheme.onSurfaceVariant,
                    fontWeight: time != null ? FontWeight.bold : null,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DurationDisplay extends StatelessWidget {
  const _DurationDisplay({required this.start, required this.end});
  final TimeOfDay start;
  final TimeOfDay end;

  @override
  Widget build(BuildContext context) {
    final startMin = start.hour * 60 + start.minute;
    final endMin = end.hour * 60 + end.minute;
    final diff = endMin - startMin;
    if (diff <= 0) return const SizedBox.shrink();

    final h = diff ~/ 60;
    final m = diff % 60;
    final label = h > 0 ? '${h}h ${m}m' : '${m}m';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.blue.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.timer_outlined, size: 18, color: Colors.blue),
          const SizedBox(width: 8),
          Text('Duration: $label',
              style: const TextStyle(color: Colors.blue, fontWeight: FontWeight.w600),),
        ],
      ),
    );
  }
}
