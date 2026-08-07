import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/user_roles.dart';
import '../../core/widgets/shared_widgets.dart';
import '../auth/auth_providers.dart';

final _workspaceMembersProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final client = ref.watch(supabaseClientProvider);
  if (client == null) throw StateError('Cloud workspace is not configured.');
  final rows = await client.rpc('list_workspace_members');
  return (rows as List)
      .map((row) => Map<String, dynamic>.from(row as Map))
      .toList();
});

class TeamMembersScreen extends ConsumerWidget {
  const TeamMembersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final members = ref.watch(_workspaceMembersProvider);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Team Members')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showInviteSheet(context, ref),
        icon: const Icon(Icons.person_add_alt_1_outlined),
        label: const Text('Add member'),
      ),
      body: members.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => EmptyState(
          icon: Icons.cloud_off_outlined,
          message: 'Could not load team members. Check cloud setup and try again.',
        ),
        data: (rows) => RefreshIndicator(
          onRefresh: () async => ref.invalidate(_workspaceMembersProvider),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer.withValues(alpha: .62),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(children: [
                  Icon(Icons.groups_2_outlined, color: theme.colorScheme.primary),
                  const SizedBox(width: 12),
                  Expanded(child: Text(
                    'Each person signs in with their own email. Their role controls what they can enter or view.',
                    style: theme.textTheme.bodyMedium,
                  )),
                ]),
              ),
              const SizedBox(height: 18),
              Text('${rows.length} active workspace member${rows.length == 1 ? '' : 's'}', style: theme.textTheme.labelLarge),
              const SizedBox(height: 8),
              if (rows.isEmpty)
                const EmptyState(icon: Icons.group_off_outlined, message: 'No members yet. Add your first team member.'),
              ...rows.map((member) => _MemberCard(member: member, onTap: () => _showMemberSheet(context, ref, member))),
            ],
          ),
        ),
      ),
    );
  }
}

class _MemberCard extends StatelessWidget {
  const _MemberCard({required this.member, required this.onTap});
  final Map<String, dynamic> member;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = member['status'] == 'active';
    return Card(child: ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      leading: CircleAvatar(child: Text((member['name']?.toString().trim().isNotEmpty ?? false) ? member['name'].toString().trim()[0].toUpperCase() : '?')),
      title: Text(member['name']?.toString() ?? 'Unnamed'),
      subtitle: Text('${member['email'] ?? ''}\n${member['role'] ?? ''}${active ? '' : ' · Inactive'}'),
      isThreeLine: true,
      trailing: member['role'] == 'owner' ? Icon(Icons.verified_rounded, color: theme.colorScheme.primary) : const Icon(Icons.chevron_right_rounded),
      onTap: member['role'] == 'owner' ? null : onTap,
    ));
  }
}

Future<void> _showInviteSheet(BuildContext context, WidgetRef ref) async {
  final email = TextEditingController();
  var role = UserRole.productionIncharge.value;
  final formKey = GlobalKey<FormState>();
  await showModalBottomSheet<void>(
    context: context, isScrollControlled: true,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.fromLTRB(20, 18, 20, MediaQuery.viewInsetsOf(sheetContext).bottom + 20),
      child: StatefulBuilder(builder: (context, setState) => Form(
        key: formKey,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Add team member', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 6),
          const Text('Create a one-time join code for this exact email. Share the code securely with the employee.'),
          const SizedBox(height: 18),
          AppFormField(label: 'Employee email', controller: email, keyboardType: TextInputType.emailAddress, prefixIcon: const Icon(Icons.email_outlined), validator: (value) => value != null && RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value.trim()) ? null : 'Enter a valid email'),
          const SizedBox(height: 12),
          AppDropdown<String>(label: 'Role', value: role, prefixIcon: const Icon(Icons.badge_outlined), items: UserRole.values.where((item) => item != UserRole.owner).map((item) => DropdownMenuItem(value: item.value, child: Text(item.value))).toList(), onChanged: (value) => setState(() => role = value ?? role)),
          const SizedBox(height: 18),
          FilledButton.icon(onPressed: () async {
            if (!formKey.currentState!.validate()) return;
            try {
              final result = await ref.read(supabaseClientProvider)!.rpc('create_workspace_invite', params: {'p_email': email.text.trim(), 'p_role': role});
              if (!context.mounted) return;
              Navigator.pop(context);
              await _showJoinCode(context, result['code']?.toString() ?? '', email.text.trim());
            } catch (_) {
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not create join code. Check role and cloud connection.'), backgroundColor: Colors.red));
            }
          }, icon: const Icon(Icons.key_outlined), label: const Text('Create join code')),
        ]),
      )),
    ),
  );
  email.dispose();
}

Future<void> _showJoinCode(BuildContext context, String code, String email) => showDialog<void>(context: context, builder: (context) => AlertDialog(
  title: const Text('Join code created'),
  content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text('Give this code only to $email.'), const SizedBox(height: 16),
    SelectableText(code, style: Theme.of(context).textTheme.headlineSmall?.copyWith(letterSpacing: 2, fontWeight: FontWeight.w800)),
    const SizedBox(height: 12), const Text('They enter it during signup. It works once and only with this email.'),
  ]),
  actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Done')), FilledButton.icon(onPressed: () async { await Clipboard.setData(ClipboardData(text: code)); if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Join code copied.'))); }, icon: const Icon(Icons.copy_outlined), label: const Text('Copy'))],
));

Future<void> _showMemberSheet(BuildContext context, WidgetRef ref, Map<String, dynamic> member) async {
  var role = member['role']?.toString() ?? UserRole.management.value;
  var active = member['status'] == 'active';
  await showModalBottomSheet<void>(context: context, builder: (sheetContext) => StatefulBuilder(builder: (context, setState) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 18, 20, 24), child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(member['name']?.toString() ?? 'Member', style: Theme.of(context).textTheme.titleLarge), const SizedBox(height: 4), Text(member['email']?.toString() ?? ''), const SizedBox(height: 18),
      AppDropdown<String>(label: 'Role', value: role, items: UserRole.values.where((item) => item != UserRole.owner).map((item) => DropdownMenuItem(value: item.value, child: Text(item.value))).toList(), onChanged: (value) => setState(() => role = value ?? role)),
      SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Active access'), subtitle: Text(active ? 'Can sign in and use assigned modules' : 'Sign-in is blocked'), value: active, onChanged: (value) => setState(() => active = value)),
      const SizedBox(height: 12), FilledButton(onPressed: () async { try { await ref.read(supabaseClientProvider)!.rpc('update_workspace_member', params: {'p_member_id': member['id'], 'p_role': role, 'p_status': active ? 'active' : 'inactive'}); ref.invalidate(_workspaceMembersProvider); if (context.mounted) Navigator.pop(context); } catch (_) { if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not update this member.'), backgroundColor: Colors.red)); } }, child: const Text('Save access')),
    ]),
  )));
}
