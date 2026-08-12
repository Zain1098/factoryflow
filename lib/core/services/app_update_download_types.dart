abstract class AppUpdateDownloadTask {
  Future<AppUpdateDownloadResult> start({void Function(double progress)? onProgress});
  void cancel();
}

class AppUpdateDownloadResult {
  const AppUpdateDownloadResult._({this.error, this.cancelled = false});
  const AppUpdateDownloadResult.success() : this._();
  const AppUpdateDownloadResult.failure(String error) : this._(error: error);
  const AppUpdateDownloadResult.cancelled() : this._(cancelled: true);

  final String? error;
  final bool cancelled;
  bool get succeeded => error == null && !cancelled;
}
