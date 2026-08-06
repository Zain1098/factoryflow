import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../core/database/database_service.dart';
import '../../core/providers/master_data_providers.dart';
import '../../core/models/app_user.dart';
import '../../core/network/sync_service.dart';
import '../../core/providers/batch_config_provider.dart';
import '../../core/providers/production_flow_provider.dart';
import '../../core/constants/app_constants.dart';
import '../../core/services/biometric_service.dart';
import '../../core/services/data_management_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/shared_widgets.dart';
import '../auth/auth_providers.dart';
import '../auth/account_settings_screen.dart';
import '../corrections/corrections_screen.dart';
import '../corrections/conflict_review_screen.dart';
import 'stock_management_screen.dart';

Future<bool> _runSettingsAction(
  BuildContext context,
  Future<void> Function() action, {
  String successMessage = 'Saved on this device. Cloud sync will retry automatically.',
}) async {
  try {
    await action();
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(successMessage)));
    }
    return true;
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          content: Text('Could not save this change. Check workspace and try again.'),
          backgroundColor: Colors.red,
        ));
    }
    return false;
  }
}

// ── App version provider ──────────────────────────────────────────────────────

final _appVersionProvider = FutureProvider<String>((ref) async {
  try {
    // ignore: depend_on_referenced_packages
    final info = await PackageInfo.fromPlatform();
    return '${info.version}+${info.buildNumber}';
  } catch (_) {
    return AppConstants.appVersion;
  }
});

// ── Biometric toggle provider ─────────────────────────────────────────────────────

final _biometricEnabledProvider = FutureProvider<bool>((ref) {
  return ref.watch(biometricServiceProvider).isEnabled();
});

// ── Notification Preferences Provider ────────────────────────────────────────

class _NotifPrefs {
  const _NotifPrefs({
    this.enableNotifications = true,
    this.soundEnabled = true,
    this.vibrationEnabled = true,
    this.productionAlerts = true,
    this.syncAlerts = true,
    this.downtimeAlerts = true,
  });

  final bool enableNotifications;
  final bool soundEnabled;
  final bool vibrationEnabled;
  final bool productionAlerts;
  final bool syncAlerts;
  final bool downtimeAlerts;

  _NotifPrefs copyWith({
    bool? enableNotifications,
    bool? soundEnabled,
    bool? vibrationEnabled,
    bool? productionAlerts,
    bool? syncAlerts,
    bool? downtimeAlerts,
  }) =>
      _NotifPrefs(
        enableNotifications: enableNotifications ?? this.enableNotifications,
        soundEnabled: soundEnabled ?? this.soundEnabled,
        vibrationEnabled: vibrationEnabled ?? this.vibrationEnabled,
        productionAlerts: productionAlerts ?? this.productionAlerts,
        syncAlerts: syncAlerts ?? this.syncAlerts,
        downtimeAlerts: downtimeAlerts ?? this.downtimeAlerts,
      );
}

class _NotifPrefsNotifier extends Notifier<_NotifPrefs> {
  @override
  _NotifPrefs build() {
    _load();
    return const _NotifPrefs();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    state = _NotifPrefs(
      enableNotifications: p.getBool('notif_enabled') ?? true,
      soundEnabled: p.getBool('notif_sound') ?? true,
      vibrationEnabled: p.getBool('notif_vibration') ?? true,
      productionAlerts: p.getBool('notif_production') ?? true,
      syncAlerts: p.getBool('notif_sync') ?? true,
      downtimeAlerts: p.getBool('notif_downtime') ?? true,
    );
  }

  Future<void> _save(_NotifPrefs prefs) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool('notif_enabled', prefs.enableNotifications);
    await p.setBool('notif_sound', prefs.soundEnabled);
    await p.setBool('notif_vibration', prefs.vibrationEnabled);
    await p.setBool('notif_production', prefs.productionAlerts);
    await p.setBool('notif_sync', prefs.syncAlerts);
    await p.setBool('notif_downtime', prefs.downtimeAlerts);
    state = prefs;
  }

  Future<void> toggle(bool Function(_NotifPrefs) getter,
      _NotifPrefs Function(bool) updater, bool val,) async {
    await _save(updater(val));
  }

  Future<void> setEnabled(bool v) =>
      _save(state.copyWith(enableNotifications: v));
  Future<void> setSound(bool v) => _save(state.copyWith(soundEnabled: v));
  Future<void> setVibration(bool v) =>
      _save(state.copyWith(vibrationEnabled: v));
  Future<void> setProductionAlerts(bool v) =>
      _save(state.copyWith(productionAlerts: v));
  Future<void> setSyncAlerts(bool v) => _save(state.copyWith(syncAlerts: v));
  Future<void> setDowntimeAlerts(bool v) =>
      _save(state.copyWith(downtimeAlerts: v));
}

final _notifPrefsProvider =
    NotifierProvider<_NotifPrefsNotifier, _NotifPrefs>(_NotifPrefsNotifier.new);

// ─────────────────────────────────────────────────────────────────────────────

Widget _masterTile(
  BuildContext context,
  IconData icon,
  String title,
  String subtitle,
  Widget page,
) {
  return ListTile(
    leading: Icon(icon),
    title: Text(title),
    subtitle: Text(subtitle),
    trailing: const Icon(Icons.chevron_right),
    onTap: () =>
        Navigator.push(context, MaterialPageRoute<void>(builder: (_) => page)),
  );
}

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  /// Builds avatar widget with network image if available, else first-letter fallback
  static Widget _buildAvatar(BuildContext context, AppUser user) {
    final theme = Theme.of(context);
    if (user.avatarUrl != null && user.avatarUrl!.isNotEmpty) {
      return CircleAvatar(
        radius: 26,
        backgroundColor: theme.colorScheme.primaryContainer,
        child: ClipOval(
          child: Image.network(
            user.avatarUrl!,
            width: 52,
            height: 52,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) =>
                Text(user.name.isNotEmpty ? user.name[0].toUpperCase() : '?'),
          ),
        ),
      );
    }
    return CircleAvatar(
      radius: 26,
      backgroundColor: theme.colorScheme.primaryContainer,
      child: Text(
        user.name.isNotEmpty ? user.name[0].toUpperCase() : '?',
        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 20),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final userState = ref.watch(currentUserProvider);
    if (userState.isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (userState.hasError) {
      return const Scaffold(
        body: EmptyState(
          message: 'Profile could not load. Please reopen Settings.',
          icon: Icons.account_circle_outlined,
        ),
      );
    }
    final user = userState.value;
    final showBatchNumber = ref.watch(batchConfigProvider);
    final theme = Theme.of(context);
    final canManageFactory = user?.role.canManageMasters ?? false;
    final canApproveCorrections = user?.role.canApproveCorrections ?? false;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        centerTitle: false,
      ),
      body: ListView(
        children: [
          // ── User Profile Card ────────────────────────────────────────────────
          if (user != null)
            Container(
              margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    theme.colorScheme.primaryContainer,
                    theme.colorScheme.secondaryContainer,
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(16),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                        builder: (_) => const AccountSettingsScreen(),),),
                child: Row(
                  children: [
                    _buildAvatar(context, user),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(user.name,
                              style: theme.textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.bold),),
                          const SizedBox(height: 2),
                          Text(user.email,
                              style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,),),
                          const SizedBox(height: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2,),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary
                                  .withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              user.role.value.toUpperCase(),
                              style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: theme.colorScheme.primary,
                                  letterSpacing: 1,),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right,
                        color: theme.colorScheme.onSurfaceVariant,),
                  ],
                ),
              ),
            ),

          // ── PRODUCTION ────────────────────────────────────────────────────
          if (canManageFactory) ...[
            const _SectionLabel('Factory Setup'),
            ListTile(
              leading: const Icon(Icons.track_changes_outlined),
              title: const Text('Daily Production Targets'),
              subtitle: const Text('Part-wise and day-wise targets'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                      builder: (_) => const _ProductionTargetsPage(),),),
            ),
            ListTile(
              leading: const Icon(Icons.account_tree_outlined),
              title: const Text('Production Flow'),
              subtitle: const Text('Machine sequence, WIP and dispatch rules'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                      builder: (_) => const _ProductionFlowPage(),),),
            ),
            const Divider(),

            // ── MASTER DATA ──────────────────────────────────────────────────
            const _SectionLabel('Master Data'),
            _masterTile(context, Icons.category_outlined, 'Parts',
                'Add, edit or remove parts', const _PartsPage(),),
            _masterTile(
                context,
                Icons.precision_manufacturing_outlined,
                'Machines',
                'Add, reorder & set machine sequence',
                const _MachinesPage(),),
            _masterTile(context, Icons.people_outline, 'Operators',
                'Add or remove operators', const _OperatorsPage(),),
            _masterTile(context, Icons.local_shipping_outlined, 'Suppliers',
                'Material suppliers', const _SuppliersPage(),),
            _masterTile(context, Icons.store_outlined, 'Vendors (FACO)',
                'Plating vendors', const _VendorsPage(),),
            _masterTile(context, Icons.business_outlined, 'Customers',
                'Final dispatch customers', const _CustomersPage(),),
            _masterTile(context, Icons.person_outlined, 'Drivers',
                'Add or remove drivers', const _DriversPage(),),
            _masterTile(context, Icons.directions_car_outlined, 'Vehicles',
                'Number plates', const _VehiclesPage(),),
            const Divider(),
          ],

          // ── APP SETTINGS ─────────────────────────────────────────────────
          const _SectionLabel('App Settings'),
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('Theme'),
            subtitle: Text(
                themeMode.name[0].toUpperCase() + themeMode.name.substring(1),),
            trailing: SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(
                    value: ThemeMode.light,
                    icon: Icon(Icons.light_mode, size: 18),),
                ButtonSegment(
                    value: ThemeMode.system,
                    icon: Icon(Icons.brightness_auto, size: 18),),
                ButtonSegment(
                    value: ThemeMode.dark,
                    icon: Icon(Icons.dark_mode, size: 18),),
              ],
              selected: {themeMode},
              onSelectionChanged: (s) =>
                  ref.read(themeModeProvider.notifier).setThemeMode(s.first),
              style: const ButtonStyle(
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,),
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.qr_code_2_outlined),
            title: const Text('Batch Number Tracking'),
            subtitle: const Text('Show batch numbers on entries'),
            value: showBatchNumber,
            onChanged: (val) =>
                ref.read(batchConfigProvider.notifier).toggle(val),
          ),
          Consumer(
            builder: (context, ref, _) {
              final biometricAsync = ref.watch(_biometricEnabledProvider);
              final svc = ref.read(biometricServiceProvider);
              return FutureBuilder<bool>(
                future: svc.isAvailable(),
                builder: (context, snap) {
                  final available = snap.data ?? false;
                  return SwitchListTile(
                    secondary: const Icon(Icons.fingerprint),
                    title: const Text('Biometric Lock'),
                    subtitle: Text(available
                        ? 'Fingerprint / face unlock'
                        : 'Not available on this device',),
                    value: biometricAsync.value ?? false,
                    onChanged: available
                        ? (val) async {
                            if (val && !await svc.authenticate()) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Biometric lock was not enabled because authentication was cancelled.',
                                    ),
                                  ),
                                );
                              }
                              return;
                            }
                            await svc.setEnabled(val);
                            ref.invalidate(_biometricEnabledProvider);
                          }
                        : null,
                  );
                },
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.notifications_none_outlined),
            title: const Text('Notifications'),
            subtitle: const Text('Alerts, sound & vibration preferences'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                    builder: (_) => const _NotificationsPage(),),),
          ),
          const Divider(),

          // ── SYSTEM ───────────────────────────────────────────────────────
          const _SectionLabel('System'),
          if (canApproveCorrections) ...[
            ListTile(
              leading: const Icon(Icons.gavel_outlined),
              title: const Text('Correction Requests'),
              subtitle: const Text('Review, approve or reject edit requests'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                      builder: (_) => const CorrectionsScreen(),),),
            ),
            ListTile(
              leading: const Icon(Icons.warning_amber_rounded, color: Colors.orange),
              title: const Text('Sync Conflicts'),
              subtitle: const Text('Review and resolve failed sync records'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                      builder: (_) => const ConflictReviewScreen(),),),
            ),
          ],
          if (canManageFactory)
            ListTile(
              leading: const Icon(Icons.inventory_2_outlined),
              title: const Text('Stock Management'),
              subtitle: const Text('Review balances and post adjustments'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => const StockManagementScreen(),
                ),
              ),
            ),
          if (canManageFactory)
            ListTile(
              leading:
                  const Icon(Icons.delete_sweep_outlined, color: Colors.orange),
              title: const Text('Erase Local Data'),
              subtitle: const Text('Admin-only recovery and reset controls'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                      builder: (_) => const _EraseDataPage(),),),
            ),
          if (user != null)
            ListTile(
              leading:
                  const Icon(Icons.no_accounts_outlined, color: Colors.red),
              title: const Text('Delete My Account',
                  style: TextStyle(color: Colors.red),),
              subtitle: const Text('Remove access and clear local data'),
              onTap: () => _confirmDeleteAccount(context, ref, user),
            ),
          const Divider(),

          // ── ABOUT ────────────────────────────────────────────────────────
          const _SectionLabel('About'),
          Consumer(
            builder: (context, ref, _) {
              final version = ref.watch(_appVersionProvider).value
                  ?? AppConstants.appVersion;
              return ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('ProFlow Manufacturing ERP'),
                subtitle: Text('FactoryFlow v$version'),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.logout, color: Colors.red),
            title: const Text('Sign Out', style: TextStyle(color: Colors.red)),
            onTap: () => _signOut(context, ref),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

// ─── Notifications Page ───────────────────────────────────────────────────────

Future<void> _signOut(BuildContext context, WidgetRef ref) async {
  final pending = await ref.read(databaseServiceProvider).countPendingSync();
  if (!context.mounted) return;
  if (pending > 0) {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Unsynced Work on This Device',
      message:
          '$pending record(s) are still waiting to sync. Signing out now may '
          'make this work unavailable until you sign in on this device again.',
      confirmLabel: 'Sign Out Anyway',
      isDestructive: true,
    );
    if (!confirmed) return;
  }
  await ref.read(currentUserProvider.notifier).signOut();
  if (context.mounted) context.go('/login');
}

class _NotificationsPage extends ConsumerWidget {
  const _NotificationsPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: SingleChildScrollView(
        child: _NotificationsSection(),
      ),
    );
  }
}

// ─── Notifications Section Widget ─────────────────────────────────────────────

class _NotificationsSection extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(_notifPrefsProvider);
    final notifier = ref.read(_notifPrefsProvider.notifier);

    return Column(
      children: [
        SwitchListTile(
          secondary: const Icon(Icons.notifications_active_outlined),
          title: const Text('Enable Notifications'),
          subtitle: const Text('Turn on/off all app notifications'),
          value: prefs.enableNotifications,
          onChanged: notifier.setEnabled,
        ),
        if (prefs.enableNotifications) ...[
          SwitchListTile(
            secondary: const Icon(Icons.volume_up_outlined),
            title: const Text('Notification Sound'),
            value: prefs.soundEnabled,
            onChanged: notifier.setSound,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.vibration_outlined),
            title: const Text('Vibration'),
            value: prefs.vibrationEnabled,
            onChanged: notifier.setVibration,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.precision_manufacturing_outlined),
            title: const Text('Production Alerts'),
            subtitle: const Text('Target miss, shift completion'),
            value: prefs.productionAlerts,
            onChanged: notifier.setProductionAlerts,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.cloud_sync_outlined),
            title: const Text('Sync Status Alerts'),
            subtitle: const Text('Cloud sync success or failure'),
            value: prefs.syncAlerts,
            onChanged: notifier.setSyncAlerts,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.build_circle_outlined),
            title: const Text('Machine Downtime Alerts'),
            subtitle: const Text('Breakdowns and maintenance events'),
            value: prefs.downtimeAlerts,
            onChanged: notifier.setDowntimeAlerts,
          ),
        ],
      ],
    );
  }
}

// ─── Section Label ─────────────────────────────────────────────────────────────

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
        error: (e, _) =>
            const EmptyState(message: 'Unable to load this section. Try again.', icon: Icons.error_outline),
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
                          op['id'] as String, op['name'] as String,),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                      onPressed: () => _confirmDelete(
                          op['id'] as String, op['name'] as String,),
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
      await _runSettingsAction(context, () => repo.insertOperator(resultName!));
    } else {
      await _runSettingsAction(context, () => repo.updateOperator(id, resultName!));
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
    await _runSettingsAction(context, () => ref.read(masterDataRepositoryProvider).deactivateOperator(id), successMessage: 'Operator removed from this device.');
  }
}

class _SuppliersPage extends ConsumerStatefulWidget {
  const _SuppliersPage();
  @override
  ConsumerState<_SuppliersPage> createState() => _SuppliersPageState();
}

class _SuppliersPageState extends ConsumerState<_SuppliersPage> {
  @override
  Widget build(BuildContext context) {
    final suppliers = ref.watch(suppliersProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Suppliers')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showEditDialog(null, null),
        child: const Icon(Icons.add),
      ),
      body: suppliers.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) =>
            const EmptyState(message: 'Unable to load this section. Try again.', icon: Icons.error_outline),
        data: (list) {
          if (list.isEmpty) {
            return const EmptyState(
              message: 'No suppliers yet.\nTap + to add one.',
              icon: Icons.local_shipping_outlined,
            );
          }
          return ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final supplier = list[i];
              final name = supplier['name'] as String;
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor:
                      Theme.of(context).colorScheme.tertiaryContainer,
                  child: Text(name[0].toUpperCase()),
                ),
                title: Text(name),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () => _showEditDialog(
                        supplier['id'] as String,
                        name,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                      onPressed: () => _confirmDelete(
                        supplier['id'] as String,
                        name,
                      ),
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
    String? resultName;
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final ctrl = TextEditingController(text: current ?? '');
        return StatefulBuilder(
          builder: (ctx, setState) {
            void submit() {
              if (ctrl.text.trim().isEmpty) return;
              resultName = ctrl.text.trim();
              Navigator.pop(ctx);
            }

            return AlertDialog(
              title: Text(id == null ? 'Add Supplier' : 'Rename Supplier'),
              content: SingleChildScrollView(
                child: TextField(
                  controller: ctrl,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Name'),
                  textCapitalization: TextCapitalization.words,
                  onSubmitted: (_) => submit(),
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
    if (resultName == null || resultName!.isEmpty) return;
    final repo = ref.read(masterDataRepositoryProvider);
    if (id == null) {
      await _runSettingsAction(context, () => repo.insertSupplier(resultName!));
    } else {
      await _runSettingsAction(context, () => repo.updateSupplier(id, resultName!));
    }
  }

  Future<void> _confirmDelete(String id, String name) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Remove Supplier',
      message: 'Remove "$name"? It will no longer appear in Material Receive.',
      confirmLabel: 'Remove',
      isDestructive: true,
    );
    if (!confirmed) return;
    await _runSettingsAction(context, () => ref.read(masterDataRepositoryProvider).deactivateSupplier(id), successMessage: 'Supplier removed from this device.');
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
        error: (e, _) =>
            const EmptyState(message: 'Unable to load this section. Try again.', icon: Icons.error_outline),
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
                  backgroundColor:
                      Theme.of(context).colorScheme.primaryContainer,
                  child: Text(
                    p['code'] as String,
                    style: const TextStyle(
                        fontSize: 11, fontWeight: FontWeight.bold,),
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
                      onPressed: () => _confirmDelete(
                          p['id'] as String, p['name'] as String,),
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
      String? id, String? currentCode, String? currentName,) async {
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
              if (codeCtrl.text.trim().isEmpty || nameCtrl.text.trim().isEmpty) {
                return;
              }
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
      await _runSettingsAction(context, () => repo.insertPart(code: resultCode!, name: resultName!));
    } else {
      await _runSettingsAction(context, () => repo.updatePart(id, code: resultCode!, name: resultName!));
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
    await _runSettingsAction(context, () => ref.read(masterDataRepositoryProvider).deactivatePart(id), successMessage: 'Part removed from this device.');
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
        error: (e, _) =>
            const EmptyState(message: 'Unable to load this section. Try again.', icon: Icons.error_outline),
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
              await _runSettingsAction(context, () async {
                for (var i = 0; i < reordered.length; i++) {
                  await repo.reorderMachine(reordered[i]['id'] as String, i + 1);
                }
              }, successMessage: 'Machine order saved on this device.');
            },
            itemBuilder: (context, i) {
              final m = list[i];
              return ListTile(
                key: ValueKey(m['id']),
                leading: CircleAvatar(
                  backgroundColor:
                      Theme.of(context).colorScheme.secondaryContainer,
                  child: Text(
                    m['machine_code'] as String? ?? '?',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 12,),
                  ),
                ),
                title: Text(m['name'] as String),
                subtitle: Text(
                    'Code: ${m['machine_code'] ?? '—'} · Seq: ${m['sequence_order']}',),
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
                      onPressed: () => _confirmDelete(
                          m['id'] as String, m['name'] as String,),
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
    String? id,
    String? currentName,
    String? currentCode,
    int? currentSeq,
  ) async {
    String? resultName;
    String? resultCode;
    int? resultSeq;
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final nameCtrl = TextEditingController(text: currentName ?? '');
        final codeCtrl = TextEditingController(text: currentCode ?? '');
        final seqCtrl =
            TextEditingController(text: currentSeq?.toString() ?? '');
        return StatefulBuilder(
          builder: (ctx, setState) {
            void submit() {
              if (nameCtrl.text.trim().isEmpty || codeCtrl.text.trim().isEmpty) {
                return;
              }
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
      await _runSettingsAction(context, () => repo.insertMachine(
        name: resultName!,
        machineCode: resultCode!,
        sequenceOrder: resultSeq ?? 1,
      ));
    } else {
      await _runSettingsAction(context, () => repo.updateMachine(id, name: resultName!, machineCode: resultCode!));
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
    await _runSettingsAction(context, () => ref.read(masterDataRepositoryProvider).deactivateMachine(id), successMessage: 'Machine removed from this device.');
  }
}

// ─── Vendors Page ─────────────────────────────────────────────────────────────

class _VendorsPage extends ConsumerStatefulWidget {
  const _VendorsPage();
  @override
  ConsumerState<_VendorsPage> createState() => _VendorsPageState();
}

class _VendorsPageState extends ConsumerState<_VendorsPage> {
  @override
  Widget build(BuildContext context) {
    final vendors = ref.watch(vendorsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Vendors (FACO / Plating)')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showEditDialog(null, null),
        child: const Icon(Icons.add),
      ),
      body: vendors.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) =>
            const EmptyState(message: 'Unable to load this section. Try again.', icon: Icons.error_outline),
        data: (list) {
          if (list.isEmpty) {
            return const EmptyState(
              message: 'No vendors yet.\nTap + to add a plating vendor.',
              icon: Icons.store_outlined,
            );
          }
          return ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final v = list[i];
              final name =
                  v['name'] as String? ?? v['company_name'] as String? ?? '—';
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor:
                      Theme.of(context).colorScheme.tertiaryContainer,
                  child: const Icon(Icons.store_outlined, size: 20),
                ),
                title: Text(name),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Edit vendor',
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () => _showEditDialog(v['id'] as String, name),
                    ),
                    IconButton(
                      tooltip: 'Deactivate vendor',
                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                      onPressed: () => _confirmDelete(v['id'] as String, name),
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
    String? resultName;
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final ctrl = TextEditingController(text: current ?? '');
        return StatefulBuilder(
          builder: (ctx, setState) {
            return AlertDialog(
              title: Text(id == null ? 'Add Vendor' : 'Edit Vendor'),
              content: SingleChildScrollView(
                child: TextField(
                  controller: ctrl,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Vendor Name',
                    hintText: 'e.g. Al-Madina Plating',
                  ),
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
                    child: const Text('Cancel'),),
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
    // Insert using masterDataRepository — vendors table already exists in DB
    final repository = ref.read(masterDataRepositoryProvider);
    if (id == null) {
      await _runSettingsAction(context, () => repository.insertVendorByName(resultName!));
    } else {
      await _runSettingsAction(context, () => repository.updateVendor(id, resultName!));
    }
  }

  Future<void> _confirmDelete(String id, String name) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Remove Vendor',
      message: 'Remove "$name"?',
      confirmLabel: 'Remove',
      isDestructive: true,
    );
    if (!confirmed) return;
    await _runSettingsAction(context, () => ref.read(masterDataRepositoryProvider).deactivateVendor(id), successMessage: 'Vendor removed from this device.');
  }
}

// ─── Drivers Page ─────────────────────────────────────────────────────────────

class _CustomersPage extends ConsumerStatefulWidget {
  const _CustomersPage();

  @override
  ConsumerState<_CustomersPage> createState() => _CustomersPageState();
}

class _CustomersPageState extends ConsumerState<_CustomersPage> {
  @override
  Widget build(BuildContext context) {
    final customers = ref.watch(customersProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Customers')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showEditDialog(),
        child: const Icon(Icons.add),
      ),
      body: customers.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => EmptyState(
          message: 'Unable to load customers. Try again.',
          icon: Icons.error_outline,
        ),
        data: (items) {
          if (items.isEmpty) {
            return const EmptyState(
              message: 'No customers yet.\nTap + to add one.',
              icon: Icons.business_outlined,
            );
          }
          return ListView.separated(
            itemCount: items.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final item = items[index];
              final name = item['name'] as String? ?? 'Unnamed customer';
              return ListTile(
                leading: const CircleAvatar(
                  child: Icon(Icons.business_outlined, size: 18),
                ),
                title: Text(name),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Edit customer',
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () => _showEditDialog(
                        id: item['id'] as String,
                        currentName: name,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Deactivate customer',
                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                      onPressed: () => _confirmDelete(
                        item['id'] as String,
                        name,
                      ),
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

  Future<void> _showEditDialog({
    String? id,
    String? currentName,
  }) async {
    final controller = TextEditingController(text: currentName ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(id == null ? 'Add Customer' : 'Edit Customer'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Customer Name'),
          onSubmitted: (value) {
            final name = value.trim();
            if (name.isNotEmpty) Navigator.pop(context, name);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty) Navigator.pop(context, name);
            },
            child: Text(id == null ? 'Add' : 'Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null) return;
    final repository = ref.read(masterDataRepositoryProvider);
    if (id == null) {
      await _runSettingsAction(context, () => repository.insertCustomer(result));
    } else {
      await _runSettingsAction(context, () => repository.updateCustomer(id, result));
    }
  }

  Future<void> _confirmDelete(String id, String name) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Deactivate Customer',
      message:
          'Deactivate "$name"? Existing dispatch history will be preserved.',
      confirmLabel: 'Deactivate',
      isDestructive: true,
    );
    if (!confirmed) return;
    await _runSettingsAction(context, () => ref.read(masterDataRepositoryProvider).deactivateCustomer(id), successMessage: 'Customer removed from this device.');
  }
}

class _DriversPage extends ConsumerStatefulWidget {
  const _DriversPage();
  @override
  ConsumerState<_DriversPage> createState() => _DriversPageState();
}

class _DriversPageState extends ConsumerState<_DriversPage> {
  @override
  Widget build(BuildContext context) {
    final drivers = ref.watch(driversProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Drivers')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showEditDialog(null, null),
        child: const Icon(Icons.add),
      ),
      body: drivers.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) =>
            const EmptyState(message: 'Unable to load this section. Try again.', icon: Icons.error_outline),
        data: (list) {
          if (list.isEmpty) {
            return const EmptyState(
              message: 'No drivers yet.\nTap + to add one.',
              icon: Icons.person_outlined,
            );
          }
          return ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final d = list[i];
              final name = d['name'] as String;
              return ListTile(
                leading: CircleAvatar(child: Text(name[0].toUpperCase())),
                title: Text(name),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () => _showEditDialog(d['id'] as String, name),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                      onPressed: () => _confirmDelete(d['id'] as String, name),
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
    String? resultName;
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final ctrl = TextEditingController(text: current ?? '');
        return StatefulBuilder(
          builder: (ctx, setState) {
            return AlertDialog(
              title: Text(id == null ? 'Add Driver' : 'Edit Driver'),
              content: SingleChildScrollView(
                child: TextField(
                  controller: ctrl,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Driver Name'),
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
                    child: const Text('Cancel'),),
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
      await _runSettingsAction(context, () => repo.insertDriver(resultName!));
    } else {
      await _runSettingsAction(context, () => repo.updateDriver(id, resultName!));
    }
  }

  Future<void> _confirmDelete(String id, String name) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Remove Driver',
      message: 'Remove "$name"?',
      confirmLabel: 'Remove',
      isDestructive: true,
    );
    if (!confirmed) return;
    await _runSettingsAction(context, () => ref.read(masterDataRepositoryProvider).deactivateDriver(id), successMessage: 'Driver removed from this device.');
  }
}

// ─── Vehicles Page ────────────────────────────────────────────────────────────

class _VehiclesPage extends ConsumerStatefulWidget {
  const _VehiclesPage();
  @override
  ConsumerState<_VehiclesPage> createState() => _VehiclesPageState();
}

class _VehiclesPageState extends ConsumerState<_VehiclesPage> {
  @override
  Widget build(BuildContext context) {
    final vehicles = ref.watch(vehiclesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Vehicles')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showEditDialog(null, null),
        child: const Icon(Icons.add),
      ),
      body: vehicles.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) =>
            const EmptyState(message: 'Unable to load this section. Try again.', icon: Icons.error_outline),
        data: (list) {
          if (list.isEmpty) {
            return const EmptyState(
              message: 'No vehicles yet.\nTap + to add a number plate.',
              icon: Icons.directions_car_outlined,
            );
          }
          return ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final v = list[i];
              final plate = v['number_plate'] as String? ?? '—';
              return ListTile(
                leading: const CircleAvatar(
                    child: Icon(Icons.directions_car_outlined, size: 18),),
                title: Text(plate),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Edit vehicle',
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () =>
                          _showEditDialog(v['id'] as String, plate),
                    ),
                    IconButton(
                      tooltip: 'Deactivate vehicle',
                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                      onPressed: () => _confirmDelete(v['id'] as String, plate),
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
    String? resultPlate;
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final ctrl = TextEditingController(text: current ?? '');
        return StatefulBuilder(
          builder: (ctx, setState) {
            return AlertDialog(
              title: Text(id == null ? 'Add Vehicle' : 'Edit Vehicle'),
              content: SingleChildScrollView(
                child: TextField(
                  controller: ctrl,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Number Plate',
                    hintText: 'e.g. LHR-1234',
                  ),
                  textCapitalization: TextCapitalization.characters,
                  onSubmitted: (_) {
                    if (ctrl.text.trim().isNotEmpty) {
                      resultPlate = ctrl.text.trim();
                      Navigator.pop(ctx);
                    }
                  },
                ),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Cancel'),),
                FilledButton(
                  onPressed: () {
                    if (ctrl.text.trim().isEmpty) return;
                    resultPlate = ctrl.text.trim();
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
    if (resultPlate == null || resultPlate!.isEmpty) return;
    final repository = ref.read(masterDataRepositoryProvider);
    if (id == null) {
      await _runSettingsAction(context, () => repository.insertVehicle(resultPlate!));
    } else {
      await _runSettingsAction(context, () => repository.updateVehicle(id, resultPlate!));
    }
  }

  Future<void> _confirmDelete(String id, String plate) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Remove Vehicle',
      message: 'Remove "$plate"?',
      confirmLabel: 'Remove',
      isDestructive: true,
    );
    if (!confirmed) return;
    await _runSettingsAction(context, () => ref.read(masterDataRepositoryProvider).deactivateVehicle(id), successMessage: 'Vehicle removed from this device.');
  }
}

// ─── Account Delete Helper ────────────────────────────────────────────────────

Future<void> _confirmDeleteAccount(
  BuildContext context,
  WidgetRef ref,
  AppUser user,
) async {
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

// ─── Database & Sync Status Page ──────────────────────────────────────────────

class _DatabaseSyncStatusPage extends ConsumerStatefulWidget {
  const _DatabaseSyncStatusPage();

  @override
  ConsumerState<_DatabaseSyncStatusPage> createState() =>
      _DatabaseSyncStatusPageState();
}

class _DatabaseSyncStatusPageState
    extends ConsumerState<_DatabaseSyncStatusPage> {
  bool _syncing = false;

  @override
  Widget build(BuildContext context) {
    final pendingState = ref.watch(pendingSyncCountProvider);
    final pendingCount = pendingState.value;
    final isOnline = ref.watch(isOnlineProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Database & Sync Status')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 1. Local Database Status Card
          Card(
            elevation: 0,
            color: Colors.blue.withValues(alpha: 0.08),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: Colors.blue.withValues(alpha: 0.3)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.storage_rounded,
                          color: Colors.blue, size: 28,),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Local App Database',
                              style: theme.textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 2),
                            const Text(
                              'Engine: Local device storage',
                              style:
                                  TextStyle(fontSize: 12, color: Colors.grey),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4,),
                        decoration: BoxDecoration(
                          color: Colors.green.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.check_circle,
                                size: 14, color: Colors.green,),
                            SizedBox(width: 4),
                            Text('Active & Saved',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.green,
                                    fontWeight: FontWeight.bold,),),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Changes are saved locally first, so you can keep working offline. Cloud sync will retry when the account and connection are ready.',
                    style: TextStyle(fontSize: 13, height: 1.4),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // 2. Cloud Sync Status Card
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: theme.dividerColor),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        isOnline
                            ? Icons.cloud_done_outlined
                            : Icons.cloud_off_outlined,
                        color: isOnline ? Colors.indigo : Colors.grey,
                        size: 28,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Cloud Sync (Supabase)',
                              style: theme.textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                            Text(
                              isOnline ? 'Network Connected' : 'Offline Mode',
                              style: TextStyle(
                                  fontSize: 12,
                                  color:
                                      isOnline ? Colors.indigo : Colors.grey,),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Pending Sync Items in Queue:'),
                      Chip(
                        label: Text(
                          pendingCount == null ? 'Checking…' : '$pendingCount pending',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: (pendingCount ?? 0) > 0
                                ? Colors.orange.shade800
                                : Colors.green.shade800,
                          ),
                        ),
                        backgroundColor: (pendingCount ?? 0) > 0
                            ? Colors.orange.withValues(alpha: 0.15)
                            : Colors.green.withValues(alpha: 0.15),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        final res =
                            await ref.read(syncServiceProvider).syncPending();
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                res.synced > 0
                                    ? 'Successfully synced ${res.synced} records to cloud database.'
                                    : (res.offline
                                        ? 'Offline — Device is not connected to internet.'
                                        : 'Local database is fully up to date.'),
                              ),
                            ),
                          );
                        }
                      },
                      icon: const Icon(Icons.sync),
                      label: const Text('Sync Pending Records Now'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // 3. Information Card
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.amber.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, color: Colors.amber, size: 20),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'If sync fails, your local change stays on this device. Reconnect the account or internet, then use “Sync pending now”. Conflicts need an admin review.',
                    style: TextStyle(fontSize: 12, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Multi-Machine Flow Page ──────────────────────────────────────────────────

class _ProductionFlowPage extends ConsumerWidget {
  const _ProductionFlowPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final flow = ref.watch(productionFlowProvider);
    final machines = ref.watch(machinesProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Multi-Machine Flow & Rules')),
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
              'Customize how parts move through machines in your factory. '
              'In Multi-Stage mode (e.g. M1 -> M2 -> M3), half-processed parts remain in BP/WIP stock '
              'and cannot be dispatched to vendors until the final machine finishes.',
              style: TextStyle(fontSize: 13),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Company Production KPI',
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          const Text(
            'This single company rule is used by every dashboard KPI, report, and production alert.',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 8),
          RadioListTile<ProductionCountingMode>(
            contentPadding: EdgeInsets.zero,
            value: ProductionCountingMode.completedOutput,
            groupValue: flow.countingMode,
            onChanged: (mode) {
              if (mode != null) {
                ref.read(productionFlowProvider.notifier).setCountingMode(mode);
              }
            },
            title: const Text('Completed PCS (Recommended)'),
            subtitle: const Text(
              'Count only final-machine good output. Three stages making 450 PCS count as 450 PCS.',
            ),
          ),
          RadioListTile<ProductionCountingMode>(
            contentPadding: EdgeInsets.zero,
            value: ProductionCountingMode.stageWorkload,
            groupValue: flow.countingMode,
            onChanged: (mode) {
              if (mode != null) {
                ref.read(productionFlowProvider.notifier).setCountingMode(mode);
              }
            },
            title: const Text('Stage Workload (All Machine Outputs)'),
            subtitle: const Text(
              'Count each stage output. Three stages making 450 PCS show as 1,350 PCS workload.',
            ),
          ),
          const Divider(),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.account_tree_outlined),
            title: const Text('Enable Multi-Machine Sequence Routing'),
            subtitle: Text(
              flow.enabled
                  ? 'Active — Multi-stage WIP tracking enabled'
                  : 'Disabled — Single machine direct production mode',
            ),
            value: flow.enabled,
            onChanged: (v) async {
              final notifier = ref.read(productionFlowProvider.notifier);
              if (v && flow.requiredMachineIds.isEmpty) {
                final orderedMachines = [
                  ...?machines.value,
                ]..sort(
                    (a, b) => ((a['sequence_order'] as num?)?.toInt() ?? 0)
                        .compareTo((b['sequence_order'] as num?)?.toInt() ?? 0),
                  );
                if (orderedMachines.isNotEmpty) {
                  await notifier.setRequiredMachines(
                    orderedMachines
                        .map((machine) => machine['id'] as String)
                        .toList(growable: false),
                  );
                }
              }
              await notifier.setEnabled(v);
            },
          ),
          if (flow.enabled) ...[
            const Divider(),
            const SizedBox(height: 8),
            Text(
              'Production Mode',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            RadioListTile<ProductionMode>(
              value: ProductionMode.multiStageSequential,
              groupValue: flow.productionMode,
              onChanged: (m) {
                if (m != null) {
                  ref
                      .read(productionFlowProvider.notifier)
                      .setProductionMode(m);
                }
              },
              title: const Text('Multi-Stage Sequential Flow (Recommended)'),
              subtitle: const Text(
                  'Parts pass through Machine 1 -> 2 -> 3. Output is in BP/WIP stock until final machine finishes.',),
            ),
            RadioListTile<ProductionMode>(
              value: ProductionMode.directSingleStage,
              groupValue: flow.productionMode,
              onChanged: (m) {
                if (m != null) {
                  ref
                      .read(productionFlowProvider.notifier)
                      .setProductionMode(m);
                }
              },
              title: const Text('Direct Single-Stage Mode'),
              subtitle: const Text(
                  'Every machine entry immediately counts as completed final production.',),
            ),
            if (flow.productionMode == ProductionMode.directSingleStage) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  'Direct mode does not use a machine route or WIP. Use it only when each machine creates a separate finished product. For one part moving through several machines, select Multi-Stage Sequential Flow above.',
                  style: TextStyle(fontSize: 13),
                ),
              ),
            ],
            if (flow.productionMode == ProductionMode.multiStageSequential) ...[
            const Divider(),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.block_outlined, color: Colors.orange),
              title: const Text(
                  'Require Final Machine Completion for Vendor Dispatch',),
              subtitle: const Text(
                  'Prevent vendor dispatch for batches that have not completed the final sequence machine.',),
              value: flow.requireFinalMachineForDispatch,
              onChanged: (v) => ref
                  .read(productionFlowProvider.notifier)
                  .setRequireFinalMachineForDispatch(v),
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Required Machine Sequence (select in order M1 -> M2 -> M3)',
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
            machines.when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => const Text('Machines could not load. Try again.'),
              data: (list) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: list.map((m) {
                        final id = m['id'] as String;
                        final name = m['name'] as String;
                        final seqIdx = flow.getMachineSequenceIndex(id);
                        final isSelected = flow.requiredMachineIds.contains(id);

                        return FilterChip(
                          avatar: isSelected
                              ? CircleAvatar(
                                  radius: 10,
                                  backgroundColor: theme.colorScheme.primary,
                                  child: Text(
                                    '$seqIdx',
                                    style: const TextStyle(
                                        fontSize: 10,
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,),
                                  ),
                                )
                              : null,
                          label:
                              Text(isSelected ? '$name (Seq $seqIdx)' : name),
                          selected: isSelected,
                          onSelected: (selected) {
                            final updated = [...flow.requiredMachineIds];
                            if (selected) {
                              updated.add(id);
                            } else {
                              updated.remove(id);
                            }
                            ref
                                .read(productionFlowProvider.notifier)
                                .setRequiredMachines(updated);
                          },
                        );
                      }).toList(),
                    ),
                    if (flow.requiredMachineIds.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Text(
                        'Route order',
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      ...flow.requiredMachineIds.asMap().entries.map((entry) {
                        final index = entry.key;
                        final id = entry.value;
                        final machine = list.firstWhere(
                          (item) => item['id'] == id,
                          orElse: () => <String, dynamic>{'name': 'Unknown machine'},
                        );
                        final name = machine['name'] as String? ?? 'Unknown machine';
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: CircleAvatar(
                            radius: 13,
                            child: Text('${index + 1}'),
                          ),
                          title: Text(name),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: 'Move earlier',
                                icon: const Icon(Icons.arrow_upward),
                                onPressed: index == 0
                                    ? null
                                    : () {
                                        final updated = [...flow.requiredMachineIds];
                                        final moved = updated.removeAt(index);
                                        updated.insert(index - 1, moved);
                                        ref.read(productionFlowProvider.notifier)
                                            .setRequiredMachines(updated);
                                      },
                              ),
                              IconButton(
                                tooltip: 'Move later',
                                icon: const Icon(Icons.arrow_downward),
                                onPressed: index == flow.requiredMachineIds.length - 1
                                    ? null
                                    : () {
                                        final updated = [...flow.requiredMachineIds];
                                        final moved = updated.removeAt(index);
                                        updated.insert(index + 1, moved);
                                        ref.read(productionFlowProvider.notifier)
                                            .setRequiredMachines(updated);
                                      },
                              ),
                            ],
                          ),
                        );
                      }),
                    ],
                  ],
                );
              },
            ),
            if (flow.validationError != null) ...[
              const SizedBox(height: 12),
              Text(
                '${flow.validationError} Select at least one active machine.',
                style: TextStyle(
                  color: theme.colorScheme.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            if (flow.requiredMachineIds.isNotEmpty) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                  border:
                      Border.all(color: Colors.green.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.check_circle_outline,
                        color: Colors.green, size: 18,),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Active Sequence: ${flow.requiredMachineIds.length} machines required. Final machine finishes ready stock.',
                        style: const TextStyle(
                            color: Colors.green, fontWeight: FontWeight.w600,),
                      ),
                    ),
                  ],
                ),
              ),
            ],
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
    final factoryId =
        ref.read(databaseServiceProvider).activeWorkspaceId.trim();
    final counts = factoryId.isEmpty
        ? <EraseSection, int>{}
        : await ref
            .read(dataManagementServiceProvider)
            .getSectionCounts(factoryId);
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${section.label} erased.'),
          backgroundColor: Colors.orange,
        ),
      );
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('All transaction data erased.'),
          backgroundColor: Colors.orange,
        ),
      );
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
                          color: Colors.orange.withValues(alpha: 0.4),
                        ),
                      ),
                      child: const Row(
                        children: [
                          Icon(
                            Icons.info_outline,
                            color: Colors.orange,
                            size: 18,
                          ),
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
                          icon: const Icon(
                            Icons.delete_outline,
                            size: 16,
                            color: Colors.red,
                          ),
                          label: const Text(
                            'Erase',
                            style: TextStyle(color: Colors.red),
                          ),
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

// ─── Production Targets Page ──────────────────────────────────────────────────
// Smart grid: select a part → see all 7 days in one table → edit inline.
// "Apply to all days" button fills the whole week in one tap.

class _ProductionTargetsPage extends ConsumerStatefulWidget {
  const _ProductionTargetsPage();
  @override
  ConsumerState<_ProductionTargetsPage> createState() =>
      _ProductionTargetsPageState();
}

class _ProductionTargetsPageState
    extends ConsumerState<_ProductionTargetsPage> {
  static const _dayLabels = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

  // partId → {dayOfWeek → {id, qty}}
  Map<String, Map<int, Map<String, dynamic>>> _targetMap = {};
  List<Map<String, dynamic>> _parts = [];
  String? _selectedPartId;
  bool _loading = true;

  // per-day controllers for the selected part
  final List<TextEditingController> _ctrls =
      List.generate(7, (_) => TextEditingController());

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _ctrls) {
      c.dispose();
    }
    super.dispose();
  }

  void _load() {
    final db = ref.read(databaseServiceProvider);
    final parts = ref.read(partsProvider).value ?? [];
    final targets = db.getTargets();

    // Build map: partId → dayOfWeek → {id, qty}
    final map = <String, Map<int, Map<String, dynamic>>>{};
    for (final t in targets) {
      final pid = t['part_id'] as String? ?? '';
      final day = (t['day_of_week'] as int?) ?? 0;
      map.putIfAbsent(pid, () => {});
      map[pid]![day] = {'id': t['id'], 'qty': t['target_qty']};
    }

    setState(() {
      _parts = parts;
      _targetMap = map;
      _loading = false;
      // auto-select first part
      if (_selectedPartId == null && parts.isNotEmpty) {
        _selectedPartId = parts.first['id'] as String;
      }
      _refreshControllers();
    });
  }

  void _refreshControllers() {
    if (_selectedPartId == null) return;
    final dayMap = _targetMap[_selectedPartId] ?? {};
    for (int d = 0; d < 7; d++) {
      final qty = dayMap[d]?['qty'] as int?;
      _ctrls[d].text = qty != null ? qty.toString() : '';
    }
  }

  void _saveDay(int day) {
    if (_selectedPartId == null) return;
    final qty = int.tryParse(_ctrls[day].text.trim());
    final db = ref.read(databaseServiceProvider);
    final existing = _targetMap[_selectedPartId]?[day];
    if (qty == null || qty <= 0) {
      // delete if cleared
      if (existing != null) {
        db.deleteTarget(existing['id'] as String);
        _targetMap[_selectedPartId]?.remove(day);
      }
      return;
    }
    final id = existing?['id'] as String? ?? const Uuid().v4();
    db.upsertTarget(
        id: id, partId: _selectedPartId!, dayOfWeek: day, targetQty: qty,);
    _targetMap.putIfAbsent(_selectedPartId!, () => {});
    _targetMap[_selectedPartId!]![day] = {'id': id, 'qty': qty};
  }

  /// Fill all 7 days with the value from the first non-empty field, or show dialog.
  void _applyToAllDays() {
    final firstVal = _ctrls.map((c) => int.tryParse(c.text.trim())).firstWhere(
          (v) => v != null && v > 0,
          orElse: () => null,
        );
    if (firstVal == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Enter a target for at least one day first.'),),
      );
      return;
    }
    for (int d = 0; d < 7; d++) {
      _ctrls[d].text = firstVal.toString();
      _saveDay(d);
    }
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('All days set to $firstVal PCS')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_parts.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Daily Production Targets')),
        body: const EmptyState(
          message:
              'No parts found.\nAdd parts first in Settings → Master Data → Parts.',
          icon: Icons.category_outlined,
        ),
      );
    }

    final dayMap = _targetMap[_selectedPartId] ?? {};
    final totalWeekTarget =
        dayMap.values.fold(0, (s, v) => s + ((v['qty'] as int?) ?? 0));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Daily Production Targets'),
        actions: [
          TextButton.icon(
            onPressed: _applyToAllDays,
            icon: const Icon(Icons.copy_all_outlined, size: 18),
            label: const Text('Apply to All Days'),
          ),
        ],
      ),
      body: Column(
        children: [
          // Part selector tabs
          if (_parts.length > 1)
            Container(
              color: theme.colorScheme.surfaceContainerHighest
                  .withValues(alpha: 0.4),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: _parts.map((p) {
                    final pid = p['id'] as String;
                    final isSelected = pid == _selectedPartId;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text('${p['code']} – ${p['name']}'),
                        selected: isSelected,
                        onSelected: (_) {
                          setState(() => _selectedPartId = pid);
                          _refreshControllers();
                        },
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),

          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Info banner
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer
                        .withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline,
                          size: 16, color: theme.colorScheme.primary,),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Set target per day. Leave blank = no target that day. '
                          'Tap "Apply to All Days" to copy one value to all 7 days instantly.',
                          style: TextStyle(
                              fontSize: 12,
                              color: theme.colorScheme.onSurfaceVariant,),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // 7-day grid
                ...List.generate(7, (day) {
                  final isToday = DateTime.now().weekday % 7 == day;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      children: [
                        // Day label
                        Container(
                          width: 52,
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          decoration: BoxDecoration(
                            color: isToday
                                ? theme.colorScheme.primary
                                : theme.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Column(
                            children: [
                              Text(
                                _dayLabels[day],
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                  color: isToday
                                      ? theme.colorScheme.onPrimary
                                      : theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                              if (isToday)
                                Text(
                                  'Today',
                                  style: TextStyle(
                                    fontSize: 9,
                                    color: theme.colorScheme.onPrimary
                                        .withValues(alpha: 0.8),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        // Target input
                        Expanded(
                          child: TextField(
                            controller: _ctrls[day],
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              hintText: 'No target',
                              suffixText: 'PCS',
                              isDense: true,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            onChanged: (_) => _saveDay(day),
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Quick +50 / -50
                        Column(
                          children: [
                            GestureDetector(
                              onTap: () {
                                final v = int.tryParse(_ctrls[day].text) ?? 0;
                                _ctrls[day].text = (v + 50).toString();
                                _saveDay(day);
                                setState(() {});
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 3,),
                                decoration: BoxDecoration(
                                  color: Colors.green.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Text('+50',
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.green,
                                        fontWeight: FontWeight.bold,),),
                              ),
                            ),
                            const SizedBox(height: 4),
                            GestureDetector(
                              onTap: () {
                                final v = int.tryParse(_ctrls[day].text) ?? 0;
                                final newV = (v - 50).clamp(0, 99999);
                                _ctrls[day].text =
                                    newV > 0 ? newV.toString() : '';
                                _saveDay(day);
                                setState(() {});
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 3,),
                                decoration: BoxDecoration(
                                  color: Colors.red.withValues(alpha: 0.10),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Text('-50',
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.red,
                                        fontWeight: FontWeight.bold,),),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                }),

                const Divider(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Weekly Total Target',
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.bold),),
                    Text('$totalWeekTarget PCS',
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.primary,
                            fontSize: 16,),),
                  ],
                ),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
