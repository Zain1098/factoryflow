/// Build-time configuration for services that the mobile app may contact.
///
/// Values are supplied by CI or the local run command with `--dart-define`.
/// A Supabase anon key is intentionally a public client identifier; access is
/// protected by Supabase Auth and Row Level Security, never by hiding it here.
class AppConfig {
  const AppConfig({required this.supabaseUrl, required this.supabaseAnonKey});

  const AppConfig.fromEnvironment()
      : supabaseUrl = const String.fromEnvironment(
          'SUPABASE_URL',
          defaultValue: 'https://xejhgfyeichkibepgjii.supabase.co',
        ),
        supabaseAnonKey = const String.fromEnvironment(
          'SUPABASE_ANON_KEY',
          defaultValue:
              'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InhlamhnZnllaWNoa2liZXBnamlpIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODM3OTEzNzQsImV4cCI6MjA5OTM2NzM3NH0.3uyqB2-1-W9rMmt5sovfbSzLB7sGtK0tlRgmZwspbH4',
        );

  final String supabaseUrl;
  final String supabaseAnonKey;

  bool get hasValidSupabaseConfiguration {
    final uri = Uri.tryParse(supabaseUrl.trim());
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host.endsWith('.supabase.co') &&
        (uri.path.isEmpty || uri.path == '/') &&
        supabaseAnonKey.trim().isNotEmpty;
  }
}
