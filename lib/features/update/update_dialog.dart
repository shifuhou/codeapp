import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app.dart';
import '../../core/update/update_service.dart';
import 'self_update.dart';

/// Checks for updates and shows the result. [silent] suppresses the "you are
/// up to date" and error toasts (for an automatic check at startup).
Future<void> checkForUpdate(BuildContext context, {bool silent = false}) async {
  final svc = UpdateService();
  UpdateInfo info;
  try {
    if (!silent) _toast(context, 'Checking for updates…');
    info = await svc.check();
  } catch (e) {
    if (!silent && context.mounted) _toast(context, 'Update check failed: $e', error: true);
    return;
  }
  if (!context.mounted) return;
  if (!info.isNewer) {
    if (!silent) _toast(context, 'You are on the latest version (${info.currentVersion})');
    return;
  }
  await showDialog(context: context, builder: (_) => _UpdateDialog(info: info));
}

void _toast(BuildContext context, String msg, {bool error = false}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(msg), backgroundColor: error ? AppColors.err : null, behavior: SnackBarBehavior.floating),
  );
}

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({required this.info});
  final UpdateInfo info;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  double? _progress;
  String? _status;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    return AlertDialog(
      title: const Text('Update available'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460, maxHeight: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${info.currentVersion}  →  ${info.latestLabel}', style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            if (info.notes.isNotEmpty)
              Flexible(
                child: SingleChildScrollView(
                  child: Text(info.notes, style: const TextStyle(fontSize: 12.5, color: AppColors.textDim)),
                ),
              ),
            if (_status != null) ...[
              const SizedBox(height: 12),
              Text(_status!, style: const TextStyle(fontSize: 12.5)),
              const SizedBox(height: 6),
              LinearProgressIndicator(value: _progress),
            ],
            if (!info.canSelfUpdate && info.platform == UpdatePlatform.ios) ...[
              const SizedBox(height: 12),
              const Text('iOS cannot self-update. Open the release page and reinstall the signed build.',
                  style: TextStyle(fontSize: 12, color: AppColors.warn)),
            ],
            if (!info.canSelfUpdate && info.platform == UpdatePlatform.android) ...[
              const SizedBox(height: 12),
              const Text('Android will download the APK and open the installer; approve the install to finish.',
                  style: TextStyle(fontSize: 12, color: AppColors.textDim)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Later')),
        TextButton(
          onPressed: _busy ? null : () => launchUrl(Uri.parse(info.releaseUrl), mode: LaunchMode.externalApplication),
          child: const Text('Release page'),
        ),
        if (info.assetUrl != null)
          FilledButton(
            onPressed: _busy ? null : _install,
            child: Text(info.canSelfUpdate ? 'Update now' : 'Download'),
          ),
      ],
    );
  }

  Future<void> _install() async {
    final info = widget.info;
    setState(() {
      _busy = true;
      _status = 'Downloading ${info.assetName}…';
      _progress = null;
    });
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/${info.assetName}');
      await downloadFile(info.assetUrl!, file, onProgress: (r, t) {
        if (mounted) setState(() => _progress = t > 0 ? r / t : null);
      });

      if (info.platform == UpdatePlatform.android) {
        setState(() => _status = 'Opening installer…');
        await openAndroidInstaller(file);
        if (mounted) Navigator.pop(context);
        return;
      }

      if (info.canSelfUpdate) {
        setState(() {
          _status = 'Installing and restarting…';
          _progress = null;
        });
        await applyDesktopUpdate(file);
        // applyDesktopUpdate relaunches and exits; control does not return.
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = 'Failed: $e';
        });
      }
    }
  }
}
