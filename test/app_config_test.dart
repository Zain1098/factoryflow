import 'package:factoryflow/core/config/app_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppConfig', () {
    test('accepts a root Supabase project URL with an anon key', () {
      const config = AppConfig(
        supabaseUrl: 'https://factoryflow.supabase.co',
        supabaseAnonKey: 'public-anon-key',
      );

      expect(config.hasValidSupabaseConfiguration, isTrue);
    });

    test('rejects REST endpoints and missing values', () {
      const restEndpoint = AppConfig(
        supabaseUrl: 'https://factoryflow.supabase.co/rest/v1',
        supabaseAnonKey: 'public-anon-key',
      );
      const missingKey = AppConfig(
        supabaseUrl: 'https://factoryflow.supabase.co',
        supabaseAnonKey: '',
      );

      expect(restEndpoint.hasValidSupabaseConfiguration, isFalse);
      expect(missingKey.hasValidSupabaseConfiguration, isFalse);
    });
  });
}
