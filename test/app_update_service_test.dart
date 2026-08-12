import 'package:flutter_test/flutter_test.dart';
import 'package:factoryflow/core/services/app_update_service.dart';

AppRelease release({
  int versionCode = 4,
  int minimumSupportedVersionCode = 2,
  bool isMandatory = false,
}) =>
    AppRelease(
      versionName: '1.0.$versionCode',
      versionCode: versionCode,
      minimumSupportedVersionCode: minimumSupportedVersionCode,
      downloadUrl: Uri.parse('https://github.com/example/factoryflow.apk'),
      releaseNotes: 'Test release',
      sha256: null,
      isMandatory: isMandatory,
      publishedAt: null,
    );

void main() {
  group('evaluateAppUpdate', () {
    test('has no update for the same or newer version code', () {
      expect(
        evaluateAppUpdate(installedCode: 4, release: release()),
        AppUpdateDecision.upToDate,
      );
      expect(
        evaluateAppUpdate(installedCode: 5, release: release()),
        AppUpdateDecision.upToDate,
      );
    });

    test('treats no release as unavailable without blocking the app', () {
      expect(
        evaluateAppUpdate(installedCode: 4, release: null),
        AppUpdateDecision.unavailable,
      );
    });

    test('offers an optional update inside the supported range', () {
      expect(
        evaluateAppUpdate(installedCode: 3, release: release()),
        AppUpdateDecision.optional,
      );
    });

    test('requires an update below the minimum supported code', () {
      expect(
        evaluateAppUpdate(installedCode: 1, release: release()),
        AppUpdateDecision.mandatory,
      );
    });

    test('honours a mandatory release even inside the supported range', () {
      expect(
        evaluateAppUpdate(
          installedCode: 3,
          release: release(isMandatory: true),
        ),
        AppUpdateDecision.mandatory,
      );
    });

    test('rejects malformed release metadata', () {
      expect(
        AppRelease.tryParse({
          'version_name': '1.0.2',
          'version_code': 2,
          'minimum_supported_version_code': 1,
          'download_url': 'http://example.com/app.apk',
        }),
        isNull,
      );
    });

    test('rejects malformed version code', () {
      expect(
        AppRelease.tryParse({
          'version_name': '1.0.2',
          'version_code': 'not-a-number',
          'minimum_supported_version_code': 1,
          'download_url': 'https://github.com/example/factoryflow.apk',
        }),
        isNull,
      );
    });

    test('uses a cached forced policy after a network failure', () {
      final policy = cachedForcedRelease(
        installedCode: 1,
        cachedRelease: release(minimumSupportedVersionCode: 2),
      );
      expect(policy, isNotNull);
      expect(policy!.versionCode, 4);
    });

    test('does not enforce an optional cached policy', () {
      expect(
        cachedForcedRelease(
          installedCode: 3,
          cachedRelease: release(),
        ),
        isNull,
      );
    });
  });
}
