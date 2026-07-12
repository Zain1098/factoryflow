import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
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
          // User info
          if (user != null)
            ListTile(
              leading: CircleAvatar(
                child: Text(user.name.isNotEmpty ? user.name[0].toUpperCase() : '?'),
              ),
              title: Text(user.name),
              subtitle: Text('${user.role.value} · ${user.email}'),
            ),
          const Divider(),

          // Theme
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

          // App info
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

          // Sign out
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
