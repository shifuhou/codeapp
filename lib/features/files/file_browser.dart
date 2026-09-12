import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app.dart';
import '../../core/ssh/ssh_connection.dart';
import '../../core/workspace_session.dart';

class FileBrowser extends ConsumerStatefulWidget {
  const FileBrowser({super.key, this.onOpenFile});
  final void Function(String path)? onOpenFile;

  @override
  ConsumerState<FileBrowser> createState() => _FileBrowserState();
}

class _FileBrowserState extends ConsumerState<FileBrowser> {
  String? _dir;
  List<SftpName>? _entries;
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load(ref.read(workspaceProvider).workDir);
  }

  Future<void> _load(String dir) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final sftp = await ref.read(workspaceProvider).conn.sftp();
      final abs = await sftp.absolute(dir);
      final list = await sftp.listdir(abs);
      list.removeWhere((e) => e.filename == '.' || e.filename == '..');
      list.sort((a, b) {
        final da = a.attr.isDirectory ? 0 : 1;
        final db = b.attr.isDirectory ? 0 : 1;
        if (da != db) return da - db;
        return a.filename.toLowerCase().compareTo(b.filename.toLowerCase());
      });
      if (!mounted) return;
      setState(() {
        _dir = abs;
        _entries = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  String _join(String name) => _dir == '/' ? '/$name' : '$_dir/$name';

  Future<void> _openFile(String path) async {
    final ws = ref.read(workspaceProvider);
    try {
      await ws.editor.open(path);
      widget.onOpenFile?.call(path);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Cannot open: $e')));
      }
    }
  }

  Future<String?> _prompt(String title, {String initial = ''}) async {
    final c = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(controller: c, autofocus: true, autocorrect: false),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('OK')),
        ],
      ),
    );
  }

  Future<void> _entryMenu(SftpName e) async {
    final path = _join(e.filename);
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text(e.filename, style: const TextStyle(fontWeight: FontWeight.bold))),
            ListTile(leading: const Icon(Icons.drive_file_rename_outline), title: const Text('Rename'), onTap: () => Navigator.pop(ctx, 'rename')),
            ListTile(leading: const Icon(Icons.delete_outline), title: const Text('Delete'), onTap: () => Navigator.pop(ctx, 'delete')),
            ListTile(leading: const Icon(Icons.copy), title: const Text('Copy path'), onTap: () => Navigator.pop(ctx, 'copy')),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    final conn = ref.read(workspaceProvider).conn;
    try {
      switch (action) {
        case 'rename':
          final n = await _prompt('Rename', initial: e.filename);
          if (n == null || n.isEmpty || n == e.filename) return;
          await (await conn.sftp()).rename(path, _join(n));
        case 'delete':
          final ok = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text('Delete ${e.filename}?'),
              content: e.attr.isDirectory ? const Text('The folder and everything in it will be removed.') : null,
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
              ],
            ),
          );
          if (ok != true) return;
          if (e.attr.isDirectory) {
            await conn.run('rm -rf ${shq(path)}');
          } else {
            await (await conn.sftp()).remove(path);
          }
        case 'copy':
          await Clipboard.setData(ClipboardData(text: path));
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Copied $path')));
          }
          return;
      }
      _load(_dir!);
    } catch (err) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$err')));
    }
  }

  Future<void> _create({required bool folder}) async {
    final n = await _prompt(folder ? 'New folder name' : 'New file name');
    if (n == null || n.isEmpty) return;
    final conn = ref.read(workspaceProvider).conn;
    final path = _join(n);
    try {
      final sftp = await conn.sftp();
      if (folder) {
        await sftp.mkdir(path);
      } else {
        final f = await sftp.open(path, mode: SftpFileOpenMode.create | SftpFileOpenMode.write | SftpFileOpenMode.exclusive);
        await f.close();
      }
      await _load(_dir!);
      if (!folder) _openFile(path);
    } catch (err) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$err')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ws = ref.watch(workspaceProvider);
    final dir = _dir ?? ws.workDir;
    final segs = dir.split('/').where((s) => s.isNotEmpty).toList();
    return Column(
      children: [
        Material(
          color: AppColors.panel,
          child: SizedBox(
            height: 40,
            child: Row(
              children: [
                Expanded(
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    children: [
                      _crumb('/', '/'),
                      for (var i = 0; i < segs.length; i++)
                        _crumb(segs[i], '/${segs.sublist(0, i + 1).join('/')}'),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.add, size: 20),
                  tooltip: 'New',
                  onSelected: (v) => _create(folder: v == 'folder'),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'file', child: Text('New file')),
                    PopupMenuItem(value: 'folder', child: Text('New folder')),
                  ],
                ),
                IconButton(
                  icon: const Icon(Icons.home_outlined, size: 20),
                  tooltip: 'Workspace folder',
                  onPressed: () => _load(ws.workDir),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh, size: 20),
                  tooltip: 'Refresh',
                  onPressed: () => _load(dir),
                ),
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _loading && _entries == null
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(child: Padding(padding: const EdgeInsets.all(16), child: Text(_error!, style: const TextStyle(color: AppColors.err))))
                  : RefreshIndicator(
                      onRefresh: () => _load(dir),
                      child: ListView.builder(
                        itemCount: (_entries?.length ?? 0) + (dir == '/' ? 0 : 1),
                        itemBuilder: (context, i) {
                          if (dir != '/' && i == 0) {
                            return ListTile(
                              leading: const Icon(Icons.arrow_upward, size: 18),
                              title: const Text('..'),
                              onTap: () => _load(dir.substring(0, dir.lastIndexOf('/')).ifEmpty('/')),
                            );
                          }
                          final e = _entries![dir == '/' ? i : i - 1];
                          final isDir = e.attr.isDirectory;
                          return ListTile(
                            leading: Icon(
                              isDir ? Icons.folder : _iconFor(e.filename),
                              size: 18,
                              color: isDir ? AppColors.warn : AppColors.textDim,
                            ),
                            title: Text(e.filename, overflow: TextOverflow.ellipsis),
                            trailing: isDir ? null : Text(_size(e.attr.size), style: const TextStyle(fontSize: 11, color: AppColors.textDim)),
                            onTap: () => isDir ? _load(_join(e.filename)) : _openFile(_join(e.filename)),
                            onLongPress: () => _entryMenu(e),
                          );
                        },
                      ),
                    ),
        ),
      ],
    );
  }

  Widget _crumb(String label, String path) {
    return TextButton(
      style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 6), minimumSize: Size.zero),
      onPressed: () => _load(path),
      child: Text(label, style: const TextStyle(fontSize: 12, color: AppColors.text)),
    );
  }

  static IconData _iconFor(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return switch (ext) {
      'png' || 'jpg' || 'jpeg' || 'gif' || 'webp' || 'svg' => Icons.image_outlined,
      'md' => Icons.article_outlined,
      'json' || 'yaml' || 'yml' || 'toml' => Icons.data_object,
      'sh' => Icons.terminal,
      _ => Icons.insert_drive_file_outlined,
    };
  }

  static String _size(int? b) {
    if (b == null) return '';
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} K';
    return '${(b / 1024 / 1024).toStringAsFixed(1)} M';
  }
}

extension on String {
  String ifEmpty(String alt) => isEmpty ? alt : this;
}
