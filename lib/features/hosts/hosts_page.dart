import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../app.dart';
import '../../core/models/host.dart';
import '../../core/ssh/connection_manager.dart';
import '../../core/storage/host_store.dart';
import '../../core/workspace_session.dart';
import '../workspace/workspace_page.dart';
import 'connect_flow.dart';
import 'folder_picker_page.dart';

/// VS Code "Remotes (Tunnels/SSH)" style tree: hosts, each expandable to
/// its recently opened folders.
class HostsPage extends ConsumerStatefulWidget {
  const HostsPage({super.key});

  @override
  ConsumerState<HostsPage> createState() => _HostsPageState();
}

class _HostsPageState extends ConsumerState<HostsPage> {
  final _expanded = <String>{};

  @override
  Widget build(BuildContext context) {
    final hosts = ref.watch(hostsProvider);
    final manager = ref.watch(connectionManagerProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Remotes (SSH)'),
        actions: [
          IconButton(
            tooltip: 'Refresh (re-read ~/.ssh/config)',
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.read(hostsProvider.notifier).reload(),
          ),
          IconButton(
            tooltip: 'Add new SSH host',
            icon: const Icon(Icons.add),
            onPressed: _addHost,
          ),
        ],
      ),
      body: hosts.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Failed to load hosts: $e')),
        data: (list) {
          if (list.isEmpty) return _empty();
          return ListView(
            children: [
              for (final h in list) ..._hostRows(h, manager.isConnected(h.id)),
            ],
          );
        },
      ),
    );
  }

  Widget _empty() {
    final hasConfig = HostStore.sshDir != null;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.dns_outlined, size: 56, color: AppColors.textDim),
          const SizedBox(height: 12),
          Text(
            hasConfig ? 'No hosts in ~/.ssh/config yet' : 'No hosts yet',
            style: const TextStyle(color: AppColors.textDim),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _addHost,
            icon: const Icon(Icons.add),
            label: const Text('Add new SSH host'),
          ),
        ],
      ),
    );
  }

  List<Widget> _hostRows(HostConfig h, bool connected) {
    final open = _expanded.contains(h.id) || connected;
    return [
      ListTile(
        contentPadding: const EdgeInsets.only(left: 4, right: 4),
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              iconSize: 18,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              icon: Icon(open ? Icons.expand_more : Icons.chevron_right),
              onPressed: () => setState(() {
                open ? _expanded.remove(h.id) : _expanded.add(h.id);
              }),
            ),
            Icon(
              connected ? Icons.computer : Icons.computer_outlined,
              size: 20,
              color: connected ? AppColors.ok : AppColors.textDim,
            ),
          ],
        ),
        title: Row(
          children: [
            Flexible(child: Text(h.label, overflow: TextOverflow.ellipsis)),
            if (connected)
              const Padding(
                padding: EdgeInsets.only(left: 8),
                child: Text('connected', style: TextStyle(fontSize: 12, color: AppColors.textDim)),
              ),
          ],
        ),
        subtitle: h.alias != null && h.alias != h.host
            ? Text(h.target, style: const TextStyle(fontSize: 11, color: AppColors.textDim))
            : null,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Connect and open folder',
              iconSize: 18,
              icon: const Icon(Icons.arrow_forward),
              onPressed: () => _openFolderPicker(h),
            ),
            PopupMenuButton<String>(
              iconSize: 18,
              onSelected: (v) => _hostMenu(h, v),
              itemBuilder: (_) => [
                if (connected) const PopupMenuItem(value: 'disconnect', child: Text('Disconnect')),
                if (!h.fromSshConfig) const PopupMenuItem(value: 'edit', child: Text('Edit')),
                if (!h.fromSshConfig) const PopupMenuItem(value: 'delete', child: Text('Remove')),
                if (h.fromSshConfig) const PopupMenuItem(enabled: false, value: '', child: Text('From ~/.ssh/config')),
              ],
            ),
          ],
        ),
        onTap: () => setState(() {
          open ? _expanded.remove(h.id) : _expanded.add(h.id);
        }),
      ),
      if (open)
        for (final d in h.recentDirs)
          ListTile(
            contentPadding: const EdgeInsets.only(left: 64, right: 8),
            dense: true,
            title: Row(
              children: [
                Text(_baseName(d), style: const TextStyle(color: AppColors.text)),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(d, style: const TextStyle(fontSize: 12, color: AppColors.textDim), overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
            onTap: () => openWorkspace(context, ref, h, d),
            onLongPress: () => ref.read(hostsProvider.notifier).removeRecentDir(h.id, d),
          ),
      if (open && h.recentDirs.isEmpty)
        const ListTile(
          contentPadding: EdgeInsets.only(left: 64),
          dense: true,
          title: Text('No folders opened yet', style: TextStyle(fontSize: 12, color: AppColors.textDim)),
        ),
    ];
  }

  static String _baseName(String p) => p.split('/').where((s) => s.isNotEmpty).lastOrNull ?? '/';

  Future<void> _openFolderPicker(HostConfig h) async {
    final hc = await ensureConnected(context, ref, h);
    if (hc == null || !mounted) return;
    setState(() => _expanded.add(h.id));
    final dir = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => FolderPickerPage(host: h, hostConn: hc)),
    );
    if (dir != null && mounted) openWorkspace(context, ref, h, dir);
  }

  Future<void> _hostMenu(HostConfig h, String action) async {
    switch (action) {
      case 'disconnect':
        await ref.read(connectionManagerProvider).disconnect(h.id);
      case 'edit':
        _addHost(existing: h);
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text('Remove ${h.label}?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Remove')),
            ],
          ),
        );
        if (ok == true) {
          await ref.read(connectionManagerProvider).disconnect(h.id);
          await ref.read(hostsProvider.notifier).remove(h.id);
        }
    }
  }

  /// Single-line entry like VS Code: `user@host`, `user@host:2222`,
  /// or `ssh -p 2222 user@host`.
  Future<void> _addHost({HostConfig? existing}) async {
    final c = TextEditingController(text: existing?.target ?? '');
    String? err;
    final result = await showDialog<HostConfig>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(existing == null ? 'Add new SSH host' : 'Edit SSH host'),
          content: TextField(
            controller: c,
            autofocus: true,
            autocorrect: false,
            decoration: InputDecoration(
              hintText: 'user@hostname  or  ssh -p 2222 user@host',
              errorText: err,
            ),
            onSubmitted: (_) => _submitHost(ctx, c.text, existing, (e) => setS(() => err = e)),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => _submitHost(ctx, c.text, existing, (e) => setS(() => err = e)),
              child: Text(existing == null ? 'Add' : 'Save'),
            ),
          ],
        ),
      ),
    );
    if (result != null) await ref.read(hostsProvider.notifier).upsert(result);
  }

  void _submitHost(BuildContext ctx, String text, HostConfig? existing, void Function(String?) setErr) {
    final parsed = HostConfig.parse(text, id: existing?.id ?? const Uuid().v4());
    if (parsed == null) {
      setErr('Enter something like user@hostname');
      return;
    }
    if (existing != null) parsed.recentDirs = existing.recentDirs;
    Navigator.pop(ctx, parsed);
  }
}

/// Opens [dir] on [host] in the workspace screen, connecting first if needed.
Future<void> openWorkspace(BuildContext context, WidgetRef ref, HostConfig host, String dir) async {
  final hc = await ensureConnected(context, ref, host);
  if (hc == null || !context.mounted) return;
  final abs = hc.conn.expand(dir);
  await ref.read(hostsProvider.notifier).addRecentDir(host.id, abs);
  final session = WorkspaceSession(hc, abs);
  if (!context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => ProviderScope(
      overrides: [workspaceProvider.overrideWithValue(session)],
      child: const WorkspacePage(),
    ),
  ));
  await session.dispose();
}
