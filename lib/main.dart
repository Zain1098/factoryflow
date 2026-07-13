import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/config/app_config.dart';
import 'core/database/database_service.dart';
import 'core/router/app_router.dart';
import 'core/services/notification_service.dart';
import 'core/theme/app_theme.dart';

// ---------------------------------------------------------------------------
// Supabase connection state, overridden once after application initialization.
// ---------------------------------------------------------------------------
final supabaseConnectedProvider = Provider<bool>((_) => false);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ── Step 1: Local SQLite DB (offline-first) ────────────────────────────
  await DatabaseService.instance.initialize();
  await DatabaseService.instance.seedDemoData();

  // ── Step 2: Local notifications ────────────────────────────────────────
  await NotificationService.instance.initialize();

  // ── Step 3: Supabase (optional — app works fully offline without it) ───
  // Credentials are injected at build time via --dart-define, never loaded
  // from an asset or local .env file.
  // Build command:
  //   flutter run --dart-define=SUPABASE_URL=https://xxx.supabase.co \
  //               --dart-define=SUPABASE_ANON_KEY=eyJ...
  const config = AppConfig.fromEnvironment();
  bool supabaseConnected = false;
  if (config.hasValidSupabaseConfiguration) {
    try {
      await Supabase.initialize(
        url: config.supabaseUrl.trim(),
        anonKey: config.supabaseAnonKey.trim(),
        authOptions: const FlutterAuthClientOptions(
          authFlowType: AuthFlowType.pkce,
          autoRefreshToken: true,
        ),
      );
      supabaseConnected = true;
    } catch (_) {
      // The app remains usable offline. Do not log service configuration.
    }
  }

  runApp(
    ProviderScope(
      overrides: [
        supabaseConnectedProvider.overrideWith((_) => supabaseConnected),
      ],
      child: const FactoryFlowApp(),
    ),
  );
}

class FactoryFlowApp extends ConsumerWidget {
  const FactoryFlowApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    final themeMode = ref.watch(themeModeProvider);

    return MaterialApp.router(
      title: 'FactoryFlow',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeMode,
      routerConfig: router,
    );
  }
}
