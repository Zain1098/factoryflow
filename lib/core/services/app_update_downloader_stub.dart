import 'app_update_download_types.dart';

class _UnsupportedDownloadTask implements AppUpdateDownloadTask {
  @override
  void cancel() {}

  @override
  Future<AppUpdateDownloadResult> start({void Function(double progress)? onProgress}) async =>
      const AppUpdateDownloadResult.failure(
        'Android APK updates are available on Android only.',
      );
}

AppUpdateDownloadTask createPlatformAppUpdateDownloadTask({
  required Uri url,
  required String? sha256,
}) => _UnsupportedDownloadTask();
