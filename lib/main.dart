import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/database/database_service.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';

/// Global flag — true when Supabase URL+key are valid and initialized
final supabaseConnectedProvider = Provider<bool>((_) => false);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ── Step 1: Local SQLite DB (offline-first, PRD 7.6) ──────────────────
  await DatabaseService.instance.initialize();
  await DatabaseService.instance.seedDemoData();

  // ── Step 2: Supabase (optional — app works offline without it) ─────────
  bool supabaseConnected = false;
  try {
    await dotenv.load(fileName: '.env');
    final url = dotenv.env['SUPABASE_URL']?.trim() ?? '';
    final key = dotenv.env['SUPABASE_ANON_KEY']?.trim() ?? '';

    // Validate URL looks like a Supabase project URL (not the REST endpoint)
    final isValidUrl = url.isNotEmpty &&
        url.startsWith('https://') &&
        url.contains('.supabase.co') &&
        !url.endsWith('/rest/v1/') &&
        !url.endsWith('/rest/v1');

    if (isValidUrl && key.isNotEmpty) {
      await Supabase.initialize(
        url: url,
        anonKey: key,
        authOptions: const FlutterAuthClientOptions(
          authFlowType: AuthFlowType.pkce,
          autoRefreshToken: true,
        ),
      );
      supabaseConnected = true;
    } else if (url.isNotEmpty) {
      debugPrint(
        '[FactoryFlow] ⚠️ Invalid SUPABASE_URL in .env — '
        'must be https://<project>.supabase.co (no /rest/v1/ suffix)',
      );
    }
  } catch (e) {
    debugPrint('[FactoryFlow] Supabase init failed: $e — running in offline mode');
  }

  runApp(ProviderScope(
    overrides: [
      supabaseConnectedProvider.overrideWithValue(supabaseConnected),
    ],
    child: const FactoryFlowApp(),
  ));
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
