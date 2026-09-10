abstract class AppUpdateDownloadTask {
  Future<AppUpdateDownloadResult> start({void Function(double progress)? onProgress});
  void cancel();
}

class AppUpdateDownloadResult {
  const AppUpdateDownloadResult._({
    this.error,
    this.cancelled = false,
    this.savedPath,
  });
  const AppUpdateDownloadResult.success({String? savedPath})
      : this._(savedPath: savedPath);
  const AppUpdateDownloadResult.failure(String error) : this._(error: error);
  const AppUpdateDownloadResult.cancelled() : this._(cancelled: true);

  final String? error;
  final bool cancelled;
  final String? savedPath;
  bool get succeeded => error == null && !cancelled;
}
