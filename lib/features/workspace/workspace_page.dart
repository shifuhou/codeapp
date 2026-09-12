import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app.dart';
import '../../core/workspace_session.dart';
import '../claude/claude_panel.dart';
import '../editor/editor_view.dart';
import '../files/file_browser.dart';
import '../ports/ports_view.dart';
import '../terminal/terminal_view.dart';

/// Main screen for a connected host. Wide layouts show three columns like
/// VS Code; narrow (phone) layouts use a bottom navigation bar.
class WorkspacePage extends ConsumerStatefulWidget {
  const WorkspacePage({super.key});

  @override
  ConsumerState<WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends ConsumerState<WorkspacePage> {
  int _tab = 3; // start on Claude
  int _sideTab = 0;
  StreamSubscription? _portSub;
  late final _terminal = const TerminalPane(key: ValueKey('terminal'));

  @override
  void initState() {
    super.initState();
    final ws = ref.read(workspaceProvider);
    _portSub = ws.ports.newForwardEvents.stream.listen((fp) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Forwarded remote port ${fp.remotePort} → ${fp.localUrl}'),
        action: SnackBarAction(label: 'Open', onPressed: () => openForwardedPort(context, fp)),
        duration: const Duration(seconds: 6),
      ));
    });
    ws.conn.addListener(_onConn);
  }

  void _onConn() {
    final ws = ref.read(workspaceProvider);
    if (!ws.conn.isConnected && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Disconnected${ws.conn.error == null ? '' : ': ${ws.conn.error}'}'),
        backgroundColor: AppColors.err,
      ));
    }
  }

  @override
  void dispose() {
    _portSub?.cancel();
    ref.read(workspaceProvider).conn.removeListener(_onConn);
    super.dispose();
  }

  Future<bool> _confirmLeave() async {
    final ws = ref.read(workspaceProvider);
    final dirty = ws.editor.files.where((f) => f.dirty).length;
    if (dirty == 0) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('$dirty unsaved file${dirty == 1 ? '' : 's'}'),
        content: const Text('Leave this folder and discard unsaved changes?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Stay')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Leave')),
        ],
      ),
    );
    return ok == true;
  }

  @override
  Widget build(BuildContext context) {
    final ws = ref.watch(workspaceProvider);
    final wide = MediaQuery.sizeOf(context).width >= 900;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final leave = await _confirmLeave();
        if (leave && context.mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Row(
            children: [
              ListenableBuilder(
                listenable: ws.conn,
                builder: (_, _) => Icon(
                  Icons.circle,
                  size: 10,
                  color: ws.conn.isConnected ? AppColors.ok : AppColors.err,
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(text: ws.dirName),
                    TextSpan(text: '  ${ws.host.label}', style: const TextStyle(fontSize: 12, color: AppColors.textDim)),
                  ]),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          actions: [
            ListenableBuilder(
              listenable: ws.ports,
              builder: (_, _) => ws.ports.forwards.isEmpty
                  ? const SizedBox.shrink()
                  : IconButton(
                      tooltip: 'Forwarded ports',
                      icon: Badge(
                        label: Text('${ws.ports.forwards.length}'),
                        child: const Icon(Icons.cable),
                      ),
                      onPressed: () => setState(() => wide ? _sideTab = 2 : _tab = 4),
                    ),
            ),
          ],
        ),
        body: wide ? _wide(context) : _narrow(context),
        bottomNavigationBar: wide
            ? null
            : NavigationBar(
                selectedIndex: _tab,
                onDestinationSelected: (i) => setState(() => _tab = i),
                destinations: const [
                  NavigationDestination(icon: Icon(Icons.folder_outlined), label: 'Files'),
                  NavigationDestination(icon: Icon(Icons.edit_note), label: 'Editor'),
                  NavigationDestination(icon: Icon(Icons.terminal), label: 'Terminal'),
                  NavigationDestination(icon: Icon(Icons.auto_awesome), label: 'Claude'),
                  NavigationDestination(icon: Icon(Icons.cable), label: 'Ports'),
                ],
              ),
      ),
    );
  }

  Widget _narrow(BuildContext context) {
    return IndexedStack(
      index: _tab,
      children: [
        FileBrowser(onOpenFile: (_) => setState(() => _tab = 1)),
        const EditorView(),
        _terminal,
        const ClaudePanel(),
        const PortsView(),
      ],
    );
  }

  Widget _wide(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 280,
          child: Column(
            children: [
              Material(
                color: AppColors.panel,
                child: Row(
                  children: [
                    _sideButton(0, Icons.folder_outlined, 'Files'),
                    _sideButton(1, Icons.history, 'Sessions'),
                    _sideButton(2, Icons.cable, 'Ports'),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: IndexedStack(
                  index: _sideTab,
                  children: const [
                    FileBrowser(),
                    ClaudeSessionList(),
                    PortsView(),
                  ],
                ),
              ),
            ],
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          flex: 3,
          child: Column(
            children: [
              const Expanded(flex: 3, child: EditorView()),
              const Divider(height: 1),
              Expanded(flex: 2, child: _terminal),
            ],
          ),
        ),
        const VerticalDivider(width: 1),
        const SizedBox(width: 420, child: ClaudePanel()),
      ],
    );
  }

  Widget _sideButton(int i, IconData icon, String label) {
    final selected = _sideTab == i;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _sideTab = i),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: selected ? AppColors.accent : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: selected ? AppColors.text : AppColors.textDim),
              Text(label, style: TextStyle(fontSize: 10, color: selected ? AppColors.text : AppColors.textDim)),
            ],
          ),
        ),
      ),
    );
  }
}
