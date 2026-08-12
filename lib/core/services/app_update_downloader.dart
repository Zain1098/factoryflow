import 'app_update_downloader_stub.dart'
    if (dart.library.io) 'app_update_downloader_io.dart';
import 'app_update_download_types.dart';

export 'app_update_download_types.dart';

AppUpdateDownloadTask createAppUpdateDownloadTask({
  required Uri url,
  required String? sha256,
}) => createPlatformAppUpdateDownloadTask(url: url, sha256: sha256);
