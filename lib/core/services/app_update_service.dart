import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../features/auth/auth_providers.dart';

enum AppUpdateDecision { unavailable, upToDate, optional, mandatory }

class InstalledAppVersion {
  const InstalledAppVersion({required this.name, required this.code});

  final String name;
  final int code;

  static Future<InstalledAppVersion> fromPlatform() async {
    final info = await PackageInfo.fromPlatform();
    return InstalledAppVersion(
      name: info.version.trim().isEmpty ? 'Unknown' : info.version.trim(),
      code: int.tryParse(info.buildNumber) ?? 0,
    );
  }
}

class AppRelease {
  const AppRelease({
    required this.versionName,
    required this.versionCode,
    required this.minimumSupportedVersionCode,
    required this.downloadUrl,
    required this.releaseNotes,
    required this.sha256,
    required this.isMandatory,
    required this.publishedAt,
  });

  final String versionName;
  final int versionCode;
  final int minimumSupportedVersionCode;
  final Uri downloadUrl;
  final String releaseNotes;
  final String? sha256;
  final bool isMandatory;
  final DateTime? publishedAt;

  static AppRelease? tryParse(Object? response) {
    if (response is! Map) return null;
    final value = Map<String, dynamic>.from(response);
    final versionName = value['version_name']?.toString().trim() ?? '';
    final versionCode = _positiveInt(value['version_code']);
    final minimumCode = _positiveInt(value['minimum_supported_version_code']);
    final url = Uri.tryParse(value['download_url']?.toString().trim() ?? '');
    final hash = value['sha256']?.toString().trim();
    if (versionName.isEmpty ||
        versionCode == null ||
        minimumCode == null ||
        minimumCode > versionCode ||
        url == null ||
        url.scheme != 'https' ||
        url.host.isEmpty ||
        (hash != null && hash.isNotEmpty && !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(hash))) {
      debugPrint('Ignoring malformed Android release metadata.');
      return null;
    }
    return AppRelease(
      versionName: versionName,
      versionCode: versionCode,
      minimumSupportedVersionCode: minimumCode,
      downloadUrl: url,
      releaseNotes: value['release_notes']?.toString().trim() ?? '',
      sha256: hash == null || hash.isEmpty ? null : hash.toLowerCase(),
      isMandatory: value['is_mandatory'] == true,
      publishedAt: DateTime.tryParse(value['published_at']?.toString() ?? ''),
    );
  }

  static int? _positiveInt(Object? value) {
    final parsed = value is int ? value : int.tryParse(value?.toString() ?? '');
    return parsed != null && parsed > 0 ? parsed : null;
  }
}

class AppUpdateStatus {
  const AppUpdateStatus({
    required this.installed,
    required this.release,
    required this.decision,
  });

  final InstalledAppVersion installed;
  final AppRelease? release;
  final AppUpdateDecision decision;

  bool get hasUpdate =>
      decision == AppUpdateDecision.optional || decision == AppUpdateDecision.mandatory;

  bool get isForced => decision == AppUpdateDecision.mandatory;
}

AppUpdateDecision evaluateAppUpdate({
  required int installedCode,
  required AppRelease? release,
}) {
  if (release == null || installedCode <= 0) return AppUpdateDecision.unavailable;
  if (installedCode >= release.versionCode) return AppUpdateDecision.upToDate;
  if (installedCode < release.minimumSupportedVersionCode || release.isMandatory) {
    return AppUpdateDecision.mandatory;
  }
  return AppUpdateDecision.optional;
}

AppRelease? cachedForcedRelease({
  required int installedCode,
  required AppRelease? cachedRelease,
}) {
  return evaluateAppUpdate(installedCode: installedCode, release: cachedRelease) ==
          AppUpdateDecision.mandatory
      ? cachedRelease
      : null;
}

class AppUpdateService {
  AppUpdateService(this._client);
  final SupabaseClient? _client;
  static const _cachedReleaseKey = 'factoryflow_cached_android_release';

  Future<AppUpdateStatus> check() async {
    final installed = await InstalledAppVersion.fromPlatform();
    if (_client == null || _client.auth.currentSession == null) {
      return AppUpdateStatus(
        installed: installed,
        release: null,
        decision: AppUpdateDecision.unavailable,
      );
    }
    try {
      final response = await _client
          .rpc('platform_android_release')
          .timeout(const Duration(seconds: 8));
      final release = AppRelease.tryParse(response);
      if (release != null && response is Map) {
        await _cacheRelease(Map<String, dynamic>.from(response));
      }
      return AppUpdateStatus(
        installed: installed,
        release: release,
        decision: evaluateAppUpdate(installedCode: installed.code, release: release),
      );
    } catch (error) {
      debugPrint('Android update check unavailable: $error');
      final cachedRelease = await _loadMandatoryCachedRelease(installed.code);
      return AppUpdateStatus(
        installed: installed,
        release: cachedRelease,
        decision: evaluateAppUpdate(
          installedCode: installed.code,
          release: cachedRelease,
        ),
      );
    }
  }

  Future<void> _cacheRelease(Map<String, dynamic> response) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(_cachedReleaseKey, jsonEncode(response));
    } catch (_) {
      // The update feature remains usable without a local metadata cache.
    }
  }

  Future<AppRelease?> _loadMandatoryCachedRelease(int installedCode) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(_cachedReleaseKey);
      if (raw == null) return null;
      final release = AppRelease.tryParse(jsonDecode(raw));
      return cachedForcedRelease(
        installedCode: installedCode,
        cachedRelease: release,
      );
    } catch (_) {
      return null;
    }
  }
}

final appUpdateServiceProvider = Provider<AppUpdateService>((ref) {
  return AppUpdateService(ref.watch(supabaseClientProvider));
});

final installedAppVersionProvider = FutureProvider<InstalledAppVersion>((ref) {
  return InstalledAppVersion.fromPlatform();
});

class AppUpdateNotifier extends AsyncNotifier<AppUpdateStatus?> {
  @override
  AppUpdateStatus? build() => null;

  Future<AppUpdateStatus> checkNow() async {
    state = const AsyncLoading();
    final status = await ref.read(appUpdateServiceProvider).check();
    state = AsyncData(status);
    return status;
  }

  /// Startup checks must not put the entire app in a loading state. The
  /// Settings page calls [checkNow] when the user explicitly asks to refresh.
  Future<AppUpdateStatus> checkInBackground() async {
    final status = await ref.read(appUpdateServiceProvider).check();
    state = AsyncData(status);
    return status;
  }
}

final appUpdateProvider =
    AsyncNotifierProvider<AppUpdateNotifier, AppUpdateStatus?>(AppUpdateNotifier.new);
