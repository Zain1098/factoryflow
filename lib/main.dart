import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/config/app_config.dart';
import 'core/access/app_access_gate.dart';
import 'core/database/database_service.dart';
import 'core/router/app_router.dart';
import 'core/services/biometric_service.dart';
import 'core/services/notification_service.dart';
import 'core/theme/app_theme.dart';
import 'features/auth/auth_providers.dart';
import 'features/settings/app_update_widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ── Step 1: Local SQLite (must succeed — app cannot run without it) ────
  try {
    await DatabaseService.instance.initialize();
  } catch (e) {
    // DB failed — show error screen, do not proceed
    runApp(_DbErrorApp(error: e.toString()));
    return;
  }

  // ── Step 2: Supabase (optional — 5 s timeout so offline users aren't blocked)
  const config = AppConfig.fromEnvironment();
  bool supabaseConnected = false;
  if (config.hasValidSupabaseConfiguration) {
    try {
      await Supabase.initialize(
        url: config.supabaseUrl.trim(),
        // ignore: deprecated_member_use
        anonKey: config.supabaseAnonKey.trim(),
        authOptions: const FlutterAuthClientOptions(
          authFlowType: AuthFlowType.pkce,
          autoRefreshToken: true,
        ),
      ).timeout(const Duration(seconds: 5));
      supabaseConnected = true;
      // Initialize Google Sign-In after Supabase is ready
      await initGoogleSignIn().catchError((_) {});
    } catch (e) {
      // Offline or misconfigured — app continues in offline mode.
      debugPrint('Supabase init failed: $e');
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

  // Notification init is fire-and-forget — never blocks startup.
  NotificationService.instance.initialize().catchError((_) {});
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
      builder: (context, child) => AppAccessGate(
        child: _BiometricGuard(
          child: AppUpdateGate(child: child ?? const SizedBox.shrink()),
        ),
      ),
    );
  }
}

// ── Biometric Guard ──────────────────────────────────────────────────────────

/// Wraps the entire app. If biometric lock is enabled, shows an auth prompt
/// before revealing the app content. Re-prompts if the app is resumed.
class _BiometricGuard extends StatefulWidget {
  const _BiometricGuard({required this.child});
  final Widget child;

  @override
  State<_BiometricGuard> createState() => _BiometricGuardState();
}

class _BiometricGuardState extends State<_BiometricGuard>
    with WidgetsBindingObserver {
  bool _unlocked = false;
  bool _checking = true;
  final _biometric = BiometricService();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkAndPrompt();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_unlocked) {
      _checkAndPrompt();
    }
    // Lock again when app goes to background
    if (state == AppLifecycleState.paused) {
      _biometric.isEnabled().then((enabled) {
        if (enabled && mounted) setState(() => _unlocked = false);
      });
    }
  }

  Future<void> _checkAndPrompt() async {
    final enabled = await _biometric.isEnabled();
    if (!enabled) {
      if (mounted) setState(() { _unlocked = true; _checking = false; });
      return;
    }
    if (mounted) setState(() => _checking = false);
    final success = await _biometric.authenticate();
    if (mounted) setState(() => _unlocked = success);
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!_unlocked) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.fingerprint, size: 72, color: Colors.grey),
              const SizedBox(height: 16),
              const Text(
                'Biometric lock is enabled',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _checkAndPrompt,
                icon: const Icon(Icons.lock_open_outlined),
                label: const Text('Authenticate'),
              ),
            ],
          ),
        ),
      );
    }
    return widget.child;
  }
}

/// Shown only when SQLite initialization fails (rare, e.g. storage permission).
class _DbErrorApp extends StatelessWidget {
  const _DbErrorApp({required this.error});
  final String error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.storage_rounded, size: 56, color: Colors.red),
                const SizedBox(height: 16),
                const Text(
                  'Storage Error',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  'Could not open local database.\nPlease restart the app or free up storage.\n\n$error',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.grey),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
