/// Build-time configuration for services that the mobile app may contact.
///
/// Values are supplied by CI or the local run command with `--dart-define`.
/// A Supabase anon key is intentionally a public client identifier; access is
/// protected by Supabase Auth and Row Level Security, never by hiding it here.
class AppConfig {
  const AppConfig({required this.supabaseUrl, required this.supabaseAnonKey});

  const AppConfig.fromEnvironment()
      : supabaseUrl = const String.fromEnvironment('SUPABASE_URL'),
        supabaseAnonKey = const String.fromEnvironment('SUPABASE_ANON_KEY');

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
