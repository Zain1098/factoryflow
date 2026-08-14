import 'package:flutter/material.dart';

import '../../core/services/notification_service.dart';
import '../../core/widgets/shared_widgets.dart';

class WorkRemindersPage extends StatefulWidget {
  const WorkRemindersPage({super.key});

  @override
  State<WorkRemindersPage> createState() => _WorkRemindersPageState();
}

class _WorkRemindersPageState extends State<WorkRemindersPage> {
  List<WorkReminder>? _reminders;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final reminders = await NotificationService.instance.loadWorkReminders();
    if (mounted) setState(() => _reminders = reminders);
  }

  Future<void> _save(List<WorkReminder> reminders) async {
    setState(() => _saving = true);
    try {
      await NotificationService.instance.saveWorkReminders(reminders);
      if (mounted) setState(() => _reminders = reminders);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _edit(WorkReminder? existing) async {
    final saved = await showModalBottomSheet<WorkReminder>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ReminderEditor(reminder: existing),
    );
    if (saved == null) return;
    final reminders = [...?_reminders];
    final index = reminders.indexWhere((item) => item.id == saved.id);
    if (index >= 0) {
      reminders[index] = saved;
    } else {
      reminders.add(saved);
    }
    await _save(reminders);
  }

  Future<void> _delete(WorkReminder reminder) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Remove reminder?',
      message: 'This reminder will no longer appear on this device.',
      confirmLabel: 'Remove',
      isDestructive: true,
    );
    if (!confirmed) return;
    await _save(_reminders!.where((item) => item.id != reminder.id).toList());
  }

  @override
  Widget build(BuildContext context) {
    final reminders = _reminders;
    return Scaffold(
      appBar: AppBar(title: const Text('Work reminders')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _saving ? null : () => _edit(null),
        icon: const Icon(Icons.add_alert_outlined),
        label: const Text('Add reminder'),
      ),
      body: reminders == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
              children: [
                Text(
                  'Local reminders',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  'They work without internet. Sundays, first Saturdays, and third Saturdays can be skipped per reminder.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                if (reminders.isEmpty)
                  const EmptyState(
                    icon: Icons.notifications_paused_outlined,
                    message: 'No work reminders yet.\nTap Add reminder to create one.',
                  )
                else
                  ...reminders.map((reminder) => _ReminderCard(
                        reminder: reminder,
                        onTap: _saving ? null : () => _edit(reminder),
                        onEnabledChanged: _saving
                            ? null
                            : (enabled) => _save([
                                  ...reminders.where((item) => item.id != reminder.id),
                                  reminder.copyWith(enabled: enabled),
                                ]..sort((a, b) =>
                                    (a.hour * 60 + a.minute).compareTo(b.hour * 60 + b.minute),),),
                        onDelete: _saving ? null : () => _delete(reminder),
                      ),),
              ],
            ),
    );
  }
}

class _ReminderCard extends StatelessWidget {
  const _ReminderCard({
    required this.reminder,
    required this.onTap,
    required this.onEnabledChanged,
    required this.onDelete,
  });

  final WorkReminder reminder;
  final VoidCallback? onTap;
  final ValueChanged<bool>? onEnabledChanged;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final time = TimeOfDay(hour: reminder.hour, minute: reminder.minute).format(context);
    final skips = <String>[
      if (reminder.skipSunday) 'Sun',
      if (reminder.skipFirstSaturday) '1st Sat',
      if (reminder.skipThirdSaturday) '3rd Sat',
    ];
    return Card(
      child: ListTile(
        enabled: reminder.enabled,
        onTap: onTap,
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(Icons.alarm_outlined, color: Theme.of(context).colorScheme.primary),
        ),
        title: Text(time, style: Theme.of(context).textTheme.titleMedium),
        subtitle: Text(
          '${reminder.message}${skips.isEmpty ? '' : '\nOff: ${skips.join(', ')}'}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Switch(value: reminder.enabled, onChanged: onEnabledChanged),
            IconButton(
              onPressed: onDelete,
              tooltip: 'Remove reminder',
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReminderEditor extends StatefulWidget {
  const _ReminderEditor({this.reminder});
  final WorkReminder? reminder;

  @override
  State<_ReminderEditor> createState() => _ReminderEditorState();
}

class _ReminderEditorState extends State<_ReminderEditor> {
  late TimeOfDay _time;
  late TextEditingController _message;
  late bool _skipSunday;
  late bool _skipFirstSaturday;
  late bool _skipThirdSaturday;

  @override
  void initState() {
    super.initState();
    final reminder = widget.reminder;
    _time = TimeOfDay(hour: reminder?.hour ?? 10, minute: reminder?.minute ?? 0);
    _message = TextEditingController(
      text: reminder?.message ?? 'Reminder: enter today\'s factory data.',
    );
    _skipSunday = reminder?.skipSunday ?? true;
    _skipFirstSaturday = reminder?.skipFirstSaturday ?? true;
    _skipThirdSaturday = reminder?.skipThirdSaturday ?? true;
  }

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  Future<void> _pickTime() async {
    final selected = await showTimePicker(context: context, initialTime: _time);
    if (selected != null && mounted) setState(() => _time = selected);
  }

  void _save() {
    final message = _message.text.trim();
    if (message.isEmpty) return;
    Navigator.pop(
      context,
      WorkReminder(
        id: widget.reminder?.id ?? DateTime.now().microsecondsSinceEpoch.remainder(900000) + 100000,
        hour: _time.hour,
        minute: _time.minute,
        message: message,
        enabled: widget.reminder?.enabled ?? true,
        skipSunday: _skipSunday,
        skipFirstSaturday: _skipFirstSaturday,
        skipThirdSaturday: _skipThirdSaturday,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.reminder == null ? 'Add work reminder' : 'Edit work reminder',
                    style: Theme.of(context).textTheme.titleLarge,),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.schedule_outlined),
                  title: const Text('Reminder time'),
                  subtitle: Text(_time.format(context)),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: _pickTime,
                ),
                TextField(
                  controller: _message,
                  maxLength: 120,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Reminder message',
                    hintText: 'Example: Add today\'s production.',
                  ),
                ),
                const SizedBox(height: 8),
                Text('Skip non-working days', style: Theme.of(context).textTheme.titleSmall),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Sunday off'),
                  value: _skipSunday,
                  onChanged: (value) => setState(() => _skipSunday = value),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('First Saturday off'),
                  value: _skipFirstSaturday,
                  onChanged: (value) => setState(() => _skipFirstSaturday = value),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Third Saturday off'),
                  value: _skipThirdSaturday,
                  onChanged: (value) => setState(() => _skipThirdSaturday = value),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _save,
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('Save reminder'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}
