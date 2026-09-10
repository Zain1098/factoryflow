import 'dart:io';

import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'app_update_download_types.dart';

class _AndroidAppUpdateDownloadTask implements AppUpdateDownloadTask {
  _AndroidAppUpdateDownloadTask({
    required this.url,
    required this.expectedSha256,
    this.versionName,
  });

  final Uri url;
  final String? expectedSha256;
  final String? versionName;
  final CancelToken _cancelToken = CancelToken();
  static const _downloadChannel = MethodChannel(
    'com.proflow.factoryflow/app_updates',
  );

  @override
  void cancel() => _cancelToken.cancel('Cancelled by user');

  @override
  Future<AppUpdateDownloadResult> start({void Function(double progress)? onProgress}) async {
    if (!Platform.isAndroid) {
      return const AppUpdateDownloadResult.failure(
        'Android APK updates are available on Android only.',
      );
    }
    File? apk;
    try {
      final directory = await getTemporaryDirectory();
      final localName = versionName != null && versionName!.isNotEmpty
          ? 'FactoryFlow-v$versionName.apk'
          : 'factoryflow-update.apk';
      apk = File(path.join(directory.path, localName));
      if (await apk.exists()) await apk.delete();
      await Dio().download(
        url.toString(),
        apk.path,
        cancelToken: _cancelToken,
        onReceiveProgress: (received, total) {
          if (total > 0) onProgress?.call(received / total);
        },
        options: Options(
          responseType: ResponseType.bytes,
          followRedirects: true,
          maxRedirects: 5,
          validateStatus: (status) => status != null && status >= 200 && status < 300,
          receiveTimeout: const Duration(minutes: 5),
        ),
      );
      if (expectedSha256 != null) {
        final digest = await crypto.sha256.bind(apk.openRead()).first;
        if (digest.toString().toLowerCase() != expectedSha256) {
          await apk.delete();
          return const AppUpdateDownloadResult.failure(
            'Download integrity check failed. Please try again.',
          );
        }
      }
      final savedPath = await _saveVerifiedApkToDownloads(apk);
      final opened = await OpenFilex.open(
        apk.path,
        type: 'application/vnd.android.package-archive',
      );
      if (opened.type != ResultType.done) {
        return AppUpdateDownloadResult.failure(
          'Android installer could not open. Please allow "Install unknown apps" for FactoryFlow in Settings, or install $savedPath from your Downloads folder.',
        );
      }
      return AppUpdateDownloadResult.success(savedPath: savedPath);
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) {
        await _deleteIfPresent(apk);
        return const AppUpdateDownloadResult.cancelled();
      }
      await _deleteIfPresent(apk);
      return const AppUpdateDownloadResult.failure(
        'Download failed. Check your connection and try again.',
      );
    } on StateError catch (error) {
      await _deleteIfPresent(apk);
      return AppUpdateDownloadResult.failure(error.message.toString());
    } catch (_) {
      await _deleteIfPresent(apk);
      return const AppUpdateDownloadResult.failure(
        'Download failed. Please try again.',
      );
    }
  }

  Future<void> _deleteIfPresent(File? file) async {
    if (file != null && await file.exists()) await file.delete();
  }

  Future<String> _saveVerifiedApkToDownloads(File apk) async {
    try {
      final displayName = versionName != null && versionName!.isNotEmpty
          ? 'FactoryFlow-v$versionName.apk'
          : 'FactoryFlow-update.apk';
      final path = await _downloadChannel.invokeMethod<String>('saveApkToDownloads', {
        'sourcePath': apk.path,
        'displayName': displayName,
      });
      return path ?? 'Download/FactoryFlow/$displayName';
    } on PlatformException catch (error) {
      throw StateError(error.message ?? 'Could not save the APK to Downloads.');
    }
  }
}

AppUpdateDownloadTask createPlatformAppUpdateDownloadTask({
  required Uri url,
  required String? sha256,
  String? versionName,
}) => _AndroidAppUpdateDownloadTask(
      url: url,
      expectedSha256: sha256,
      versionName: versionName,
    );
