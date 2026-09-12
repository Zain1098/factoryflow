import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/master_data_providers.dart';
import '../../core/providers/stock_invalidation_helper.dart';
import '../../core/widgets/defect_photo_picker.dart';
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
  String? _photoUrl;
  TimeOfDay _startTime = TimeOfDay.now();
  TimeOfDay? _endTime;
  bool _isSaving = false;
  String? _error;
  String? _success;
  DateTime _recordedAt = DateTime.now();

  static const List<String> _quickReasons = [
    'Power Outage',
    'Mechanical Fault',
    'Tool / Die Change',
    'Maintenance / Oiling',
    'Material Shortage',
    'Electrical Fault',
    'Operator Absent',
  ];

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

  TimeOfDay? _parseTimeOfDay(String? timeStr) {
    if (timeStr == null || !timeStr.contains(':')) return null;
    final parts = timeStr.split(':');
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    return TimeOfDay(hour: h, minute: m);
  }

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

  void _addMinutesToEndTime(int minutes) {
    final base = _endTime ?? _startTime;
    final now = DateTime.now();
    final dt = DateTime(now.year, now.month, now.day, base.hour, base.minute)
        .add(Duration(minutes: minutes));
    setState(() {
      _endTime = TimeOfDay(hour: dt.hour, minute: dt.minute);
    });
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _isSaving = true;
      _error = null;
      _success = null;
    });

    try {
      final user = ref.read(currentUserProvider).value;
      final repo = ref.read(machineDowntimeRepositoryProvider);
      final result = await repo.save(
        machineId: _machineId!,
        startTime: _formatTime(_startTime),
        endTime: _endTime != null ? _formatTime(_endTime!) : null,
        reason: _reasonCtrl.text.trim(),
        operatorId: _operatorId,
        photoUrl: _photoUrl,
        remarks: _remarksCtrl.text.trim().isEmpty ? null : _remarksCtrl.text.trim(),
        createdBy: user?.id ?? 'unknown',
        recordedAt: _recordedAt,
      );

      if (result.success) {
        setState(() => _success = 'Downtime entry recorded successfully!');
        refreshAllStockAndEntryProviders(ref);
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

  String _getDurationPreview() {
    if (_endTime == null) return 'Ongoing Halt';
    final startMin = _startTime.hour * 60 + _startTime.minute;
    final endMin = _endTime!.hour * 60 + _endTime!.minute;
    final diff = endMin - startMin;
    if (diff < 0) return 'Invalid duration';
    final h = diff ~/ 60;
    final m = diff % 60;
    if (h > 0) {
      return m > 0 ? '$h hr $m min' : '$h hr';
    }
    return '$m min';
  }

  void _reset() {
    _formKey.currentState?.reset();
    _reasonCtrl.clear();
    _remarksCtrl.clear();
    setState(() {
      _machineId = null;
      _operatorId = null;
      _photoUrl = null;
      _startTime = TimeOfDay.now();
      _endTime = null;
      _recordedAt = DateTime.now();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Machine Downtime'),
        bottom: TabBar(
          controller: _tabController,
          indicatorSize: TabBarIndicatorSize.tab,
          tabs: const [
            Tab(icon: Icon(Icons.add_circle_outline, size: 20), text: 'Log Halt'),
            Tab(icon: Icon(Icons.history, size: 20), text: 'Halt History'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [_buildForm(theme), _buildHistory(theme)],
      ),
    );
  }

  Widget _buildForm(ThemeData theme) {
    final machines = ref.watch(machinesProvider);
    final operators = ref.watch(operatorsProvider);
    final allDowntimes = ref.watch(machineDowntimeListProvider).value ?? [];
    final activeHalts = allDowntimes
        .where((r) => r['end_time'] == null || r['end_time'].toString().isEmpty)
        .toList();

    return Form(
      key: _formKey,
      child: Column(
        children: [
          Expanded(
            child: EntryFormScroll(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (activeHalts.isNotEmpty) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.red.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.warning_amber_rounded, color: Colors.red, size: 20),
                              const SizedBox(width: 8),
                              Text(
                                '${activeHalts.length} Machine(s) Currently Halted',
                                style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.red),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          ...activeHalts.map((h) => Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        '${h['machine_name'] ?? 'Machine'}: ${h['reason'] ?? 'Halted'} (Started ${formatTimeWithoutSeconds(h['start_time'] as String?)})',
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                    ),
                                    TextButton.icon(
                                      icon: const Icon(Icons.stop_circle_outlined, size: 16),
                                      label: const Text('End Halt', style: TextStyle(fontSize: 12)),
                                      onPressed: () => _showEditModal(h),
                                      style: TextButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                        minimumSize: Size.zero,
                                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                      ),
                                    ),
                                  ],
                                ),
                              ),),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],

                  if (_error != null) ...[
                    ErrorBanner(_error!),
                    const SizedBox(height: 12),
                  ],
                  if (_success != null) ...[
                    SuccessBanner(_success!),
                    const SizedBox(height: 12),
                  ],

                  // ── Card 1: Machine & Operator ──
                  EntryInfoSurface(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const _CardSectionHeader(
                          icon: Icons.precision_manufacturing_outlined,
                          title: 'Machine & Assigned Operator',
                        ),
                        const SizedBox(height: 14),
                        RecordDateTimePicker(
                          value: _recordedAt,
                          onChanged: (dt) => setState(() => _recordedAt = dt),
                          showTime: false,
                        ),
                        const SizedBox(height: 12),
                        machines.when(
                          loading: () => const LinearProgressIndicator(),
                          error: (e, _) => ErrorBanner('Could not load machines: $e'),
                          data: (list) => AppDropdown<String>(
                            label: 'Machine',
                            isRequired: true,
                            prefixIcon: const Icon(Icons.precision_manufacturing_outlined),
                            value: _machineId,
                            items: list
                                .map((m) => DropdownMenuItem(
                                      value: m['id'] as String,
                                      child: Text(m['name'] as String),
                                    ),)
                                .toList(),
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
                            prefixIcon: const Icon(Icons.person_outline),
                            value: _operatorId,
                            items: list
                                .map((o) => DropdownMenuItem(
                                      value: o['id'] as String,
                                      child: Text(o['name'] as String),
                                    ),)
                                .toList(),
                            onChanged: (v) => setState(() => _operatorId = v),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  // ── Card 2: Downtime Period & Quick Durations ──
                  EntryInfoSurface(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const _CardSectionHeader(
                          icon: Icons.timelapse_outlined,
                          title: 'Downtime Period & Duration',
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Expanded(
                              child: _TimePickerTile(
                                label: 'Start Time',
                                time: _startTime,
                                onTap: () => _pickTime(true),
                                color: Colors.orange.shade700,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _TimePickerTile(
                                label: 'End Time (Blank = Ongoing)',
                                time: _endTime,
                                onTap: () => _pickTime(false),
                                color: Colors.teal.shade700,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Text(
                              'Quick End:',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Wrap(
                              spacing: 6,
                              children: [
                                _QuickTimeChip(
                                  label: 'Now',
                                  onTap: () => setState(() => _endTime = TimeOfDay.now()),
                                ),
                                _QuickTimeChip(
                                  label: '+15m',
                                  onTap: () => _addMinutesToEndTime(15),
                                ),
                                _QuickTimeChip(
                                  label: '+30m',
                                  onTap: () => _addMinutesToEndTime(30),
                                ),
                                _QuickTimeChip(
                                  label: '+1h',
                                  onTap: () => _addMinutesToEndTime(60),
                                ),
                                if (_endTime != null)
                                  InkWell(
                                    onTap: () => setState(() => _endTime = null),
                                    borderRadius: BorderRadius.circular(6),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                                      child: Text(
                                        'Clear',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: theme.colorScheme.error,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                        if (_endTime != null) ...[
                          const SizedBox(height: 10),
                          _DurationDisplay(start: _startTime, end: _endTime!),
                        ] else ...[
                          const SizedBox(height: 10),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            decoration: BoxDecoration(
                              color: Colors.orange.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
                            ),
                            child: const Row(
                              children: [
                                Icon(Icons.info_outline, size: 16, color: Colors.orange),
                                SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Halt is marked Ongoing. Active breakdown alerts will trigger until halt is ended.',
                                    style: TextStyle(fontSize: 11, color: Colors.orange),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  // ── Card 3: Reason & Photo Evidence ──
                  EntryInfoSurface(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const _CardSectionHeader(
                          icon: Icons.build_circle_outlined,
                          title: 'Reason & Evidence',
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Quick Presets',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: _quickReasons.map((r) {
                            final isSelected = _reasonCtrl.text.trim() == r;
                            return ChoiceChip(
                              label: Text(r, style: const TextStyle(fontSize: 12)),
                              selected: isSelected,
                              onSelected: (val) {
                                setState(() {
                                  _reasonCtrl.text = val ? r : '';
                                });
                              },
                              visualDensity: VisualDensity.compact,
                              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            );
                          }).toList(),
                        ),
                        const SizedBox(height: 12),
                        AppFormField(
                          label: 'Reason Description',
                          controller: _reasonCtrl,
                          prefixIcon: const Icon(Icons.warning_amber_rounded),
                          validator: (v) =>
                              v == null || v.trim().isEmpty ? 'Reason is required' : null,
                        ),
                        const SizedBox(height: 12),
                        AppFormField(
                          label: 'Remarks (optional)',
                          controller: _remarksCtrl,
                          maxLines: 2,
                          prefixIcon: const Icon(Icons.notes),
                        ),
                        const SizedBox(height: 14),
                        DefectPhotoPicker(
                          label: 'Breakdown / Defect Photo',
                          hint: 'Attach photo of broken component or issue',
                          initialPhotoUrl: _photoUrl,
                          onPhotoChanged: (path) => setState(() => _photoUrl = path),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
          StickyBottomActionBar(
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _getDurationPreview(),
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: _endTime == null ? Colors.red : theme.colorScheme.primary,
                        ),
                      ),
                      Text(
                        '${_formatTime(_startTime)} ➔ ${_endTime != null ? _formatTime(_endTime!) : 'Ongoing'}',
                        style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                SaveButton(
                  onPressed: _save,
                  isLoading: _isSaving,
                  label: 'Log Downtime',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHistory(ThemeData theme) {
    final list = ref.watch(machineDowntimeListProvider);
    return list.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => EmptyState(message: 'Error: $e', icon: Icons.error_outline),
      data: (records) {
        if (records.isEmpty) {
          return const EmptyState(
            message: 'No downtime entries recorded yet.',
            icon: Icons.build_outlined,
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          itemCount: records.length,
          itemBuilder: (context, i) {
            final r = records[i];
            final duration = r['duration_minutes'] as int?;
            final isSynced = r['sync_status'] == 'synced';
            final isOngoing = r['end_time'] == null || r['end_time'].toString().isEmpty;
            final photoUrl = r['photo_url'] as String?;

            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: EntryInfoSurface(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: (isOngoing ? Colors.red : Colors.orange)
                                .withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            isOngoing ? Icons.warning_amber_rounded : Icons.build_outlined,
                            color: isOngoing ? Colors.red : Colors.orange.shade800,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                r['machine_name'] ?? 'Machine',
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                r['reason'] ?? 'Unspecified halt',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                        // Ongoing / Duration Badge
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: isOngoing
                                ? Colors.red.withValues(alpha: 0.12)
                                : Colors.teal.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                isOngoing ? Icons.fiber_manual_record : Icons.timer_outlined,
                                size: 12,
                                color: isOngoing ? Colors.red : Colors.teal,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                isOngoing ? 'Ongoing' : '${duration ?? 0}m',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: isOngoing ? Colors.red : Colors.teal,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // Detail chips row
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        _DetailTag(
                          icon: Icons.calendar_today_outlined,
                          label: formatAppDate(r['date']),
                        ),
                        _DetailTag(
                          icon: Icons.access_time,
                          label:
                              '${formatTimeWithoutSeconds(r['start_time'] as String?)} - ${r['end_time'] != null && r['end_time'].toString().isNotEmpty ? formatTimeWithoutSeconds(r['end_time'] as String?) : 'Now'}',
                        ),
                        if (r['operator_name'] != null)
                          _DetailTag(
                            icon: Icons.person_outline,
                            label: r['operator_name'].toString(),
                          ),
                        if (photoUrl != null && photoUrl.isNotEmpty)
                          const _DetailTag(
                            icon: Icons.photo_outlined,
                            label: 'Photo',
                            color: Colors.blue,
                          ),
                      ],
                    ),
                    if (r['remarks'] != null && r['remarks'].toString().isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        'Remarks: ${r['remarks']}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontStyle: FontStyle.italic,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const Divider(height: 14),
                    // Action footer
                    Row(
                      children: [
                        Icon(
                          isSynced ? Icons.cloud_done : Icons.cloud_upload_outlined,
                          size: 14,
                          color: isSynced ? Colors.green : Colors.orange,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          isSynced ? 'Synced' : 'Pending sync',
                          style: TextStyle(
                            fontSize: 11,
                            color: isSynced ? Colors.green : Colors.orange,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.edit_outlined, size: 18),
                          tooltip: 'Edit Downtime',
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          onPressed: () => _showEditModal(r),
                        ),
                        const SizedBox(width: 14),
                        IconButton(
                          icon: Icon(
                            Icons.delete_outline,
                            size: 18,
                            color: theme.colorScheme.error,
                          ),
                          tooltip: 'Delete Entry',
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          onPressed: () => _confirmDelete(r),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showEditModal(Map<String, dynamic> record) {
    final id = record['id'] as String;
    String machineId = record['machine_id'] as String;
    String? operatorId = record['operator_id'] as String?;
    final reasonCtrl = TextEditingController(text: record['reason'] as String? ?? '');
    final remarksCtrl = TextEditingController(text: record['remarks'] as String? ?? '');
    TimeOfDay startTime = _parseTimeOfDay(record['start_time'] as String?) ?? TimeOfDay.now();
    TimeOfDay? endTime = _parseTimeOfDay(record['end_time'] as String?);
    String? photoUrl = record['photo_url'] as String?;
    bool isSaving = false;
    String? modalError;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (modalCtx, setModalState) {
            final machines = ref.watch(machinesProvider);
            final operators = ref.watch(operatorsProvider);
            final theme = Theme.of(modalCtx);

            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(modalCtx).viewInsets.bottom,
                left: 16,
                right: 16,
                top: 16,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.edit_note, size: 22),
                        const SizedBox(width: 8),
                        Text(
                          'Edit Downtime Entry',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.pop(modalCtx),
                        ),
                      ],
                    ),
                    const Divider(),
                    const SizedBox(height: 8),
                    machines.when(
                      loading: () => const LinearProgressIndicator(),
                      error: (e, _) => Text('Error: $e'),
                      data: (list) => AppDropdown<String>(
                        label: 'Machine',
                        isRequired: true,
                        value: machineId,
                        items: list
                            .map((m) => DropdownMenuItem(
                                  value: m['id'] as String,
                                  child: Text(m['name'] as String),
                                ),)
                            .toList(),
                        onChanged: (v) {
                          if (v != null) setModalState(() => machineId = v);
                        },
                      ),
                    ),
                    const SizedBox(height: 10),
                    operators.when(
                      loading: () => const LinearProgressIndicator(),
                      error: (e, _) => Text('Error: $e'),
                      data: (list) => AppDropdown<String>(
                        label: 'Operator (optional)',
                        value: operatorId,
                        items: list
                            .map((o) => DropdownMenuItem(
                                  value: o['id'] as String,
                                  child: Text(o['name'] as String),
                                ),)
                            .toList(),
                        onChanged: (v) => setModalState(() => operatorId = v),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: _TimePickerTile(
                            label: 'Start Time',
                            time: startTime,
                            color: Colors.orange.shade700,
                            onTap: () async {
                              final picked = await showTimePicker(
                                context: modalCtx,
                                initialTime: startTime,
                              );
                              if (picked != null) {
                                setModalState(() => startTime = picked);
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _TimePickerTile(
                            label: 'End Time',
                            time: endTime,
                            color: Colors.teal.shade700,
                            onTap: () async {
                              final picked = await showTimePicker(
                                context: modalCtx,
                                initialTime: endTime ?? TimeOfDay.now(),
                              );
                              if (picked != null) {
                                setModalState(() => endTime = picked);
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    AppFormField(
                      label: 'Reason',
                      controller: reasonCtrl,
                    ),
                    const SizedBox(height: 10),
                    AppFormField(
                      label: 'Remarks (optional)',
                      controller: remarksCtrl,
                      maxLines: 2,
                    ),
                    if (modalError != null) ...[
                      const SizedBox(height: 8),
                      ErrorBanner(modalError!),
                    ],
                    const SizedBox(height: 16),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: isSaving
                          ? null
                          : () async {
                              if (reasonCtrl.text.trim().isEmpty) {
                                setModalState(() => modalError = 'Reason is required');
                                return;
                              }
                              setModalState(() {
                                isSaving = true;
                                modalError = null;
                              });
                              final repo = ref.read(machineDowntimeRepositoryProvider);
                              final res = await repo.update(
                                id: id,
                                machineId: machineId,
                                startTime: _formatTime(startTime),
                                endTime: endTime != null ? _formatTime(endTime!) : null,
                                reason: reasonCtrl.text.trim(),
                                operatorId: operatorId,
                                photoUrl: photoUrl,
                                remarks: remarksCtrl.text.trim().isEmpty
                                    ? null
                                    : remarksCtrl.text.trim(),
                              );
                              if (!modalCtx.mounted) return;
                              if (res.success) {
                                ref.invalidate(machineDowntimeListProvider);
                                Navigator.pop(modalCtx);
                                if (!mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Downtime entry updated!')),
                                );
                              } else {
                                setModalState(() {
                                  isSaving = false;
                                  modalError = res.error ?? 'Update failed';
                                });
                              }
                            },
                      child: isSaving
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Save Changes'),
                    ),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _confirmDelete(Map<String, dynamic> record) {
    final id = record['id'] as String;
    final mName = record['machine_name'] ?? 'this machine';
    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Delete Downtime Log?'),
        content: Text('Are you sure you want to remove the halt entry for $mName?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () async {
              Navigator.pop(dialogCtx);
              final repo = ref.read(machineDowntimeRepositoryProvider);
              final res = await repo.delete(id);
              if (!mounted) return;
              if (res.success) {
                ref.invalidate(machineDowntimeListProvider);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Downtime entry deleted.')),
                );
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Failed: ${res.error}')),
                );
              }
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}

class _DetailTag extends StatelessWidget {
  const _DetailTag({
    required this.icon,
    required this.label,
    this.color,
  });

  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = color ?? theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: c),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(fontSize: 11, color: c, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}

class _QuickTimeChip extends StatelessWidget {
  const _QuickTimeChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.25),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          border: Border.all(color: theme.colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
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
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.teal.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.timer_outlined, size: 16, color: Colors.teal),
          const SizedBox(width: 8),
          Text(
            'Halt Duration: $label',
            style: const TextStyle(color: Colors.teal, fontWeight: FontWeight.w600, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _CardSectionHeader extends StatelessWidget {
  const _CardSectionHeader({required this.icon, required this.title});
  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 18, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.bold,
            color: theme.colorScheme.primary,
          ),
        ),
      ],
    );
  }
}

