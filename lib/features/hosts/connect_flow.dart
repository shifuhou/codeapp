import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app.dart';
import '../../core/models/host.dart';
import '../../core/ssh/connection_manager.dart';
import '../../core/ssh/ssh_connection.dart';
import '../../core/storage/host_store.dart';

/// Returns a live connection for [host], connecting (with prompts) if needed.
/// Returns null if the user cancelled or the connection failed (a snackbar
/// is shown in that case).
Future<HostConnection?> ensureConnected(
  BuildContext context,
  WidgetRef ref,
  HostConfig host,
) async {
  final manager = ref.read(connectionManagerProvider);
  final existing = manager.of(host.id);
  if (existing != null) return existing;

  final messenger = ScaffoldMessenger.of(context);
  final conn = SshConnection(host);
  var cancelled = false;
  var progressOpen = true;

  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (c) => AlertDialog(
      content: Row(
        children: [
          const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 16),
          Expanded(child: Text('Connecting to ${host.label}…')),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            cancelled = true;
            progressOpen = false;
            conn.close();
            Navigator.pop(c);
          },
          child: const Text('Cancel'),
        ),
      ],
    ),
  ).then((_) => progressOpen = false);

  void closeProgress() {
    if (progressOpen && context.mounted) {
      progressOpen = false;
      Navigator.of(context, rootNavigator: true).pop();
    }
  }

  try {
    final known = await HostStore.instance.loadKnownHosts();
    final key = '${host.host}:${host.port}';
    await conn.connect(
      AuthPrompts(
        askPassword: (prompt) => _askSecret(context, prompt, hint: 'Password'),
        askPassphrase: (name) => _askSecret(context, 'Passphrase for $name', hint: 'Passphrase'),
        onHostKey: (type, fp, changed) => _confirmHostKey(context, host, type, fp, changed),
      ),
      knownFingerprint: known[key],
      onTrustHostKey: (fp) => HostStore.instance.saveKnownHost(key, fp),
    );
    if (cancelled) {
      conn.close();
      return null;
    }
    closeProgress();
    manager.register(host, conn);
    return manager.of(host.id);
  } on UserCancelled {
    closeProgress();
    conn.close();
    return null;
  } catch (e) {
    closeProgress();
    conn.close();
    if (!cancelled) {
      messenger.showSnackBar(SnackBar(
        content: Text('Connection failed: $e'),
        backgroundColor: AppColors.err,
        duration: const Duration(seconds: 6),
      ));
    }
    return null;
  }
}

Future<String?> _askSecret(BuildContext context, String prompt, {required String hint}) async {
  if (!context.mounted) return null;
  final c = TextEditingController();
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: Text(prompt, style: const TextStyle(fontSize: 15)),
      content: TextField(
        controller: c,
        autofocus: true,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(hintText: hint),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('OK')),
      ],
    ),
  );
}

Future<bool> _confirmHostKey(
  BuildContext context,
  HostConfig host,
  String type,
  String fp,
  bool changed,
) async {
  if (!context.mounted) return false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(changed ? 'Host key CHANGED' : 'Unknown host'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (changed)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                'The key for this host is different from the one saved before. '
                'This could be a reinstall, or someone intercepting the connection.',
                style: TextStyle(color: AppColors.err),
              ),
            ),
          Text('${host.host}:${host.port}'),
          const SizedBox(height: 6),
          SelectableText('$type\n$fp', style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Reject')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Trust')),
      ],
    ),
  );
  return ok == true;
}
