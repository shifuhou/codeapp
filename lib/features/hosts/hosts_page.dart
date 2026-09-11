import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app.dart';
import '../../core/models/host.dart';
import '../../core/ssh/ssh_connection.dart';
import '../../core/storage/host_store.dart';
import '../../core/workspace_session.dart';
import '../workspace/workspace_page.dart';
import 'host_edit_page.dart';

class HostsPage extends ConsumerWidget {
  const HostsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hosts = ref.watch(hostsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('SSH Hosts'),
        actions: [
          IconButton(
            tooltip: 'Add host',
            icon: const Icon(Icons.add),
            onPressed: () => _edit(context, null),
          ),
        ],
      ),
      body: hosts.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Failed to load hosts: $e')),
        data: (list) {
          if (list.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.dns_outlined, size: 56, color: AppColors.textDim),
                  const SizedBox(height: 12),
                  const Text('No hosts yet', style: TextStyle(color: AppColors.textDim)),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: () => _edit(context, null),
                    icon: const Icon(Icons.add),
                    label: const Text('Add SSH host'),
                  ),
                ],
              ),
            );
          }
          return ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final h = list[i];
              return ListTile(
                leading: const Icon(Icons.dns_outlined, color: AppColors.accent),
                title: Text(h.label),
                subtitle: Text(
                  '${h.username}@${h.host}:${h.port}'
                  '${h.remoteDir.isEmpty ? '' : '  •  ${h.remoteDir}'}',
                  style: const TextStyle(color: AppColors.textDim),
                ),
                trailing: PopupMenuButton<String>(
                  onSelected: (v) async {
                    if (v == 'edit') _edit(context, h);
                    if (v == 'delete') {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (c) => AlertDialog(
                          title: Text('Delete ${h.label}?'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
                          ],
                        ),
                      );
                      if (ok == true) ref.read(hostsProvider.notifier).remove(h.id);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'edit', child: Text('Edit')),
                    PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
                onTap: () => connectAndOpen(context, h),
              );
            },
          );
        },
      ),
    );
  }

  void _edit(BuildContext context, HostConfig? host) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => HostEditPage(host: host)),
    );
  }
}

/// Connects to [host] with a progress dialog, then pushes the workspace.
Future<void> connectAndOpen(BuildContext context, HostConfig host) async {
  final nav = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final conn = SshConnection(host);
  var cancelled = false;

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
            conn.close();
            Navigator.pop(c);
          },
          child: const Text('Cancel'),
        ),
      ],
    ),
  );

  try {
    final secrets = await HostStore.instance.loadSecrets(host.id);
    final known = await HostStore.instance.loadKnownHosts();
    final key = '${host.host}:${host.port}';
    await conn.connect(
      secrets,
      knownFingerprint: known[key],
      onTrustHostKey: (fp) => HostStore.instance.saveKnownHost(key, fp),
      onHostKey: (type, fp, changed) async {
        if (!context.mounted) return false;
        final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text(changed ? 'Host key CHANGED' : 'Unknown host key'),
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
                Text('$type\n$fp', style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Reject')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Trust')),
            ],
          ),
        );
        return ok == true;
      },
    );
    if (cancelled) return;
    if (!context.mounted) return;
    nav.pop(); // progress dialog
    final session = WorkspaceSession(conn);
    await nav.push(MaterialPageRoute(
      builder: (_) => ProviderScope(
        overrides: [workspaceProvider.overrideWithValue(session)],
        child: const WorkspacePage(),
      ),
    ));
    await session.dispose();
  } catch (e) {
    conn.close();
    if (cancelled || !context.mounted) return;
    nav.pop();
    messenger.showSnackBar(SnackBar(
      content: Text('Connection failed: $e'),
      backgroundColor: AppColors.err,
      duration: const Duration(seconds: 6),
    ));
  }
}
