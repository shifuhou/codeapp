import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app.dart';
import '../../core/models/host.dart';
import '../../core/ssh/connection_manager.dart';
import '../../core/storage/host_store.dart';

/// Second layer after connecting: pick a folder to open on the host.
/// Recent folders on top, then a browsable remote directory listing.
/// Pops with the chosen absolute path.
class FolderPickerPage extends ConsumerStatefulWidget {
  const FolderPickerPage({super.key, required this.host, required this.hostConn});
  final HostConfig host;
  final HostConnection hostConn;

  @override
  ConsumerState<FolderPickerPage> createState() => _FolderPickerPageState();
}

class _FolderPickerPageState extends ConsumerState<FolderPickerPage> {
  String? _dir;
  List<SftpName>? _entries;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load(widget.hostConn.conn.homeDir);
  }

  Future<void> _load(String dir) async {
    setState(() => _error = null);
    try {
      final sftp = await widget.hostConn.conn.sftp();
      final abs = await sftp.absolute(dir);
      final list = (await sftp.listdir(abs))
          .where((e) => e.attr.isDirectory && e.filename != '.' && e.filename != '..')
          .toList()
        ..sort((a, b) {
          final ha = a.filename.startsWith('.') ? 1 : 0;
          final hb = b.filename.startsWith('.') ? 1 : 0;
          if (ha != hb) return ha - hb;
          return a.filename.toLowerCase().compareTo(b.filename.toLowerCase());
        });
      if (!mounted) return;
      setState(() {
        _dir = abs;
        _entries = list;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  String _join(String name) => _dir == '/' ? '/$name' : '$_dir/$name';

  Future<void> _newFolder() async {
    final c = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New folder'),
        content: TextField(
          controller: c,
          autofocus: true,
          autocorrect: false,
          decoration: InputDecoration(hintText: 'Folder name in $_dir'),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Create and open')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    try {
      await (await widget.hostConn.conn.sftp()).mkdir(_join(name));
      if (mounted) Navigator.pop(context, _join(name));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final host = ref.watch(hostsProvider).value?.firstWhere((h) => h.id == widget.host.id, orElse: () => widget.host) ?? widget.host;
    final dir = _dir ?? widget.hostConn.conn.homeDir;
    final segs = dir.split('/').where((s) => s.isNotEmpty).toList();
    return Scaffold(
      appBar: AppBar(
        title: Text('Open folder on ${host.label}'),
        actions: [
          IconButton(tooltip: 'New folder here', icon: const Icon(Icons.create_new_folder_outlined), onPressed: _newFolder),
        ],
      ),
      body: Column(
        children: [
          if (host.recentDirs.isNotEmpty) ...[
            const _Header('Recent'),
            for (final d in host.recentDirs.take(8))
              ListTile(
                dense: true,
                leading: const Icon(Icons.history, size: 18, color: AppColors.textDim),
                title: Text(d.split('/').where((s) => s.isNotEmpty).lastOrNull ?? '/'),
                subtitle: Text(d, style: const TextStyle(fontSize: 11, color: AppColors.textDim)),
                onTap: () => Navigator.pop(context, d),
              ),
            const Divider(height: 1),
          ],
          const _Header('Browse'),
          SizedBox(
            height: 36,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                _crumb('/', '/'),
                for (var i = 0; i < segs.length; i++) _crumb(segs[i], '/${segs.sublist(0, i + 1).join('/')}'),
              ],
            ),
          ),
          Expanded(
            child: _error != null
                ? Center(child: Text(_error!, style: const TextStyle(color: AppColors.err)))
                : _entries == null
                    ? const Center(child: CircularProgressIndicator())
                    : ListView.builder(
                        itemCount: _entries!.length,
                        itemBuilder: (context, i) {
                          final e = _entries![i];
                          return ListTile(
                            dense: true,
                            leading: const Icon(Icons.folder, size: 18, color: AppColors.warn),
                            title: Text(e.filename),
                            trailing: TextButton(
                              onPressed: () => Navigator.pop(context, _join(e.filename)),
                              child: const Text('Open'),
                            ),
                            onTap: () => _load(_join(e.filename)),
                          );
                        },
                      ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => Navigator.pop(context, dir),
                  icon: const Icon(Icons.folder_open),
                  label: Text('Open $dir', overflow: TextOverflow.ellipsis),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _crumb(String label, String path) => TextButton(
        style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 6), minimumSize: Size.zero),
        onPressed: () => _load(path),
        child: Text(label, style: const TextStyle(fontSize: 12, color: AppColors.text)),
      );
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(text.toUpperCase(), style: const TextStyle(fontSize: 11, color: AppColors.textDim, letterSpacing: 1)),
        ),
      );
}
