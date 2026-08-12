import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/app_update_downloader.dart';
import '../../core/services/app_update_service.dart';
import '../../core/services/notification_service.dart';
import '../../core/widgets/shared_widgets.dart';
import '../auth/auth_providers.dart';

class AppUpdateGate extends ConsumerStatefulWidget {
  const AppUpdateGate({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<AppUpdateGate> createState() => _AppUpdateGateState();
}

class _AppUpdateGateState extends ConsumerState<AppUpdateGate>
    with WidgetsBindingObserver {
  bool _started = false;
  int? _optionalPromptedVersion;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ref.listenManual<AppUpdateStatus?>(appUpdateProvider.select((state) => state.value),
        (_, status) {
      if (status?.hasUpdate == true && status?.release != null) {
        NotificationService.instance.showAppUpdate(
          versionCode: status!.release!.versionCode,
          versionName: status.release!.versionName,
          isRequired: status.decision == AppUpdateDecision.mandatory,
        );
      }
      final optionalRelease = status?.release;
      if (status != null &&
          status.decision == AppUpdateDecision.optional &&
          optionalRelease != null &&
          _optionalPromptedVersion != optionalRelease.versionCode) {
        final AppUpdateStatus optionalStatus = status;
        _optionalPromptedVersion = optionalRelease.versionCode;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _showOptionalUpdate(optionalStatus);
        });
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _started) {
      ref.read(appUpdateProvider.notifier).checkInBackground();
    }
  }

  void _checkAfterBootstrap() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await NotificationService.instance.initialize().catchError((_) {});
      if (mounted) await ref.read(appUpdateProvider.notifier).checkInBackground();
    });
  }

  Future<void> _showOptionalUpdate(AppUpdateStatus status) => showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Update available'),
          content: _ReleaseDetails(status: status),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Later'),
            ),
            UpdateDownloadButton(
              release: status.release!,
              label: 'Update now',
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider).value;
    final update = ref.watch(appUpdateProvider).value;
    if (user != null) _checkAfterBootstrap();
    if (update?.isForced == true && update?.release != null) {
      return _ForcedUpdateGate(status: update!);
    }
    return widget.child;
  }
}

class AppUpdateSettingsSection extends ConsumerWidget {
  const AppUpdateSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final installed = ref.watch(installedAppVersionProvider).value;
    final status = ref.watch(appUpdateProvider).value;
    final subtitle = switch (status?.decision) {
      AppUpdateDecision.mandatory => 'Update required by your administrator',
      AppUpdateDecision.optional => 'Version ${status!.release!.versionName} is available',
      AppUpdateDecision.upToDate => "You're up to date",
      _ => installed == null
          ? 'Check for the latest Android APK'
          : 'Installed: ${installed.name}+${installed.code}',
    };
    return Card(
      child: ListTile(
        minVerticalPadding: 11,
        leading: Icon(
          status?.decision == AppUpdateDecision.mandatory
              ? Icons.system_update_alt_rounded
              : Icons.system_update_outlined,
          color: status?.decision == AppUpdateDecision.mandatory
              ? Theme.of(context).colorScheme.error
              : null,
        ),
        title: const Text('App update'),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute<void>(builder: (_) => const AppUpdateDetailsPage()),
        ),
      ),
    );
  }
}

class AppUpdateDetailsPage extends ConsumerStatefulWidget {
  const AppUpdateDetailsPage({super.key});

  @override
  ConsumerState<AppUpdateDetailsPage> createState() => _AppUpdateDetailsPageState();
}

class _AppUpdateDetailsPageState extends ConsumerState<AppUpdateDetailsPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  Future<void> _check() async {
    try {
      await ref.read(appUpdateProvider.notifier).checkNow();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Update check completed.')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not check for updates. You can continue offline.'),
        ),);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final update = ref.watch(appUpdateProvider);
    final status = update.value;
    return Scaffold(
      appBar: AppBar(title: const Text('App update')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (update.isLoading) const LinearProgressIndicator(),
          if (status == null && !update.isLoading)
            const EmptyState(
              icon: Icons.system_update_outlined,
              message: 'No update information has been checked yet.',
            )
          else if (status != null) ...[
            Text('Installed version', style: Theme.of(context).textTheme.labelLarge),
            Text('${status.installed.name}+${status.installed.code}',
                style: Theme.of(context).textTheme.headlineSmall,),
            const SizedBox(height: 20),
            if (status.release == null)
              const Text('No release is currently available. You can continue using the app.')
            else ...[
              _ReleaseDetails(status: status),
              const SizedBox(height: 16),
              if (status.hasUpdate)
                UpdateDownloadButton(
                  release: status.release!,
                  label: 'Download update',
                )
              else
                const ListTile(
                  leading: Icon(Icons.verified_outlined),
                  title: Text("You're up to date"),
                ),
            ],
          ],
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: update.isLoading ? null : _check,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Check for updates'),
          ),
        ],
      ),
    );
  }
}

class _ReleaseDetails extends StatelessWidget {
  const _ReleaseDetails({required this.status, this.centered = false});
  final AppUpdateStatus status;
  final bool centered;

  @override
  Widget build(BuildContext context) {
    final release = status.release!;
    return Column(
      crossAxisAlignment: centered ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      children: [
        Text('Latest: ${release.versionName}+${release.versionCode}',
            textAlign: centered ? TextAlign.center : TextAlign.start,),
        if (release.releaseNotes.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(release.releaseNotes,
              textAlign: centered ? TextAlign.center : TextAlign.start,),
        ],
        if (status.decision == AppUpdateDecision.mandatory) ...[
          const SizedBox(height: 8),
          const Text('Please download and install this update soon to remain compatible.',
              textAlign: TextAlign.center,),
        ],
      ],
    );
  }
}

class _ForcedUpdateGate extends StatelessWidget {
  const _ForcedUpdateGate({required this.status});
  final AppUpdateStatus status;

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: false,
        child: Scaffold(
          body: SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(Icons.system_update_alt_rounded,
                        size: 56, color: Theme.of(context).colorScheme.primary,),
                    const SizedBox(height: 18),
                    Text('Update required',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall,),
                    const SizedBox(height: 12),
                    _ReleaseDetails(status: status, centered: true),
                    const SizedBox(height: 24),
                    UpdateDownloadButton(
                      release: status.release!,
                      label: 'Update now',
                      expanded: true,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

class UpdateDownloadButton extends void StatefulWidget {
  const UpdateDownloadButton({super.key, required this.release, required this.label, this.expanded = false});
  final AppRelease release;
  final String label;
  final bool expanded;

  @override
  State<UpdateDownloadButton> createState() => _UpdateDownloadButtonState();
}

class _UpdateDownloadButtonState extends void State<UpdateDownloadButton> {
  AppUpdateDownloadTask? task0;
  double? progress;
  String? error;

  Future<void> download() async {
    setState(() { error = null; progress = 0; });
    final task = createAppUpdateDownloadTask(
      url: widget.release.downloadUrl,
      sha256: widget.release.sha256,
    );
    task0 = task;
    final result = await task.start(onProgress: (value) {
      if (mounted) setState(() => progress = value);
    },);
    if (!mounted) return;
    setState(() { task0 = null; progress = null; error = result.error; });
    if (result.cancelled) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Update download cancelled.')));
    } else if (!result.succeeded) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result.error!)));
    }
  }

  @override
  void dispose() { task0?.cancel(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    if (task0 != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LinearProgressIndicator(value: progress),
          const SizedBox(height: 8),
          TextButton.icon(onPressed: task0!.cancel, icon: const Icon(Icons.close), label: const Text('Cancel download')),
        ],
      );
    }
    final button = FilledButton.icon(
      onPressed: download,
      icon: const Icon(Icons.download_rounded),
      label: Text(error == null ? widget.label : 'Retry download'),
    );
    return widget.expanded ? button : button;
  }
}
