import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app.dart';
import '../../core/workspace_session.dart';
import '../claude/claude_panel.dart';
import '../editor/editor_state.dart';
import '../editor/editor_view.dart';
import '../files/file_browser.dart';
import '../ports/ports_view.dart';
import '../terminal/terminal_view.dart';
import 'context_menu.dart';
import 'split_pane.dart';

/// Main screen for a connected folder. Wide layouts mimic VS Code: a
/// resizable sidebar, an editor group (files + Claude tabs) and a closable,
/// resizable terminal panel at the bottom. Phones get a bottom nav bar.
class WorkspacePage extends ConsumerStatefulWidget {
  const WorkspacePage({super.key});

  @override
  ConsumerState<WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends ConsumerState<WorkspacePage> with WidgetsBindingObserver {
  int _tab = 1; // phone: Files, Editor, Terminal, Claude, Ports
  bool _reconnecting = false;
  int _reconnectAttempt = 0;
  String? _reconnectError;
  int _sideTab = 0;
  bool _sidebarOpen = true;
  bool _terminalOpen = true;
  bool _terminalMax = false;
  double _sidebarWidth = 280;
  double _terminalHeight = 260;
  StreamSubscription? _portSub;
  // GlobalKey keeps the shell alive when the panel is hidden or moved.
  final _terminalKey = GlobalKey<TerminalPaneState>();
  late final _terminal = TerminalPane(key: _terminalKey);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadLayout();
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
    ws.runInTerminal = (cmd) {
      setState(() => _terminalOpen = true);
      WidgetsBinding.instance.addPostFrameCallback((_) => _terminalKey.currentState?.runCommand(cmd));
    };
    // Start with one Claude tab, like opening Claude Code in VS Code.
    if (ws.editor.tabs.isEmpty) ws.editor.openClaude();
  }

  Future<void> _loadLayout() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _sidebarWidth = p.getDouble('layout.sidebarWidth') ?? _sidebarWidth;
      _terminalHeight = p.getDouble('layout.terminalHeight') ?? _terminalHeight;
      _terminalOpen = p.getBool('layout.terminalOpen') ?? _terminalOpen;
      _sidebarOpen = p.getBool('layout.sidebarOpen') ?? _sidebarOpen;
    });
  }

  Future<void> _saveLayout() async {
    final p = await SharedPreferences.getInstance();
    await p.setDouble('layout.sidebarWidth', _sidebarWidth);
    await p.setDouble('layout.terminalHeight', _terminalHeight);
    await p.setBool('layout.terminalOpen', _terminalOpen);
    await p.setBool('layout.sidebarOpen', _sidebarOpen);
  }

  void _onConn() {
    final ws = ref.read(workspaceProvider);
    if (!ws.conn.isConnected && mounted && !_reconnecting) _reconnectLoop();
    if (mounted) setState(() {});
  }

  /// Phones drop the socket whenever the screen locks; Claude keeps running
  /// on the server, so just get the connection back and re-attach.
  Future<void> _reconnectLoop() async {
    final ws = ref.read(workspaceProvider);
    if (!ws.conn.canReconnect) return;
    _reconnecting = true;
    _reconnectAttempt = 0;
    _reconnectError = null;
    if (mounted) setState(() {});
    while (mounted && !ws.conn.isConnected) {
      _reconnectAttempt++;
      try {
        await ws.conn.reconnect();
      } catch (e) {
        _reconnectError = '$e';
        if (mounted) setState(() {});
        // Back off: 1s, 2s, 4s, … capped at 15s.
        final wait = Duration(seconds: (1 << (_reconnectAttempt - 1).clamp(0, 4)).clamp(1, 15));
        await Future.delayed(wait);
      }
    }
    _reconnecting = false;
    if (!mounted) return;
    setState(() {});
    if (ws.conn.isConnected) {
      for (final c in ws.editor.chats) {
        c.reattach();
      }
      _terminalKey.currentState?.restart();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      final ws = ref.read(workspaceProvider);
      if (!ws.conn.isConnected && !_reconnecting) {
        _reconnectLoop();
      } else if (ws.conn.isConnected) {
        // The socket may be dead without us knowing yet; a cheap probe tells.
        ws.conn.run('true', timeout: const Duration(seconds: 5)).catchError((_) => '');
        for (final c in ws.editor.chats) {
          if (!c.attached) c.reattach();
        }
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _portSub?.cancel();
    ref.read(workspaceProvider).conn.removeListener(_onConn);
    super.dispose();
  }

  Widget _reconnectBanner(WorkspaceSession ws) {
    if (ws.conn.isConnected) return const SizedBox.shrink();
    return Material(
      color: AppColors.warn.withValues(alpha: 0.15),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Connection lost. Reconnecting${_reconnectAttempt > 1 ? ' (attempt $_reconnectAttempt)' : ''}… '
                'Claude keeps running on the server.'
                '${_reconnectError == null ? '' : '  $_reconnectError'}',
                style: const TextStyle(fontSize: 12, color: AppColors.warn),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(onPressed: _reconnecting ? null : _reconnectLoop, child: const Text('Retry now')),
          ],
        ),
      ),
    );
  }

  Future<bool> _confirmLeave() async {
    final ws = ref.read(workspaceProvider);
    final dirty = ws.editor.files.where((f) => f.dirty).length;
    final busy = ws.editor.chats.where((c) => c.busy).length;
    if (dirty == 0 && busy == 0) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text([
          if (dirty > 0) '$dirty unsaved file${dirty == 1 ? '' : 's'}',
          if (busy > 0) '$busy Claude session${busy == 1 ? '' : 's'} still working',
        ].join(', ')),
        content: const Text('Leave this folder anyway? Claude sessions can be resumed later.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Stay')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Leave')),
        ],
      ),
    );
    return ok == true;
  }

  void _toggleTerminal() => setState(() {
        _terminalOpen = !_terminalOpen;
        _saveLayout();
      });

  void _toggleSidebar() => setState(() {
        _sidebarOpen = !_sidebarOpen;
        _saveLayout();
      });

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
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.backquote, control: true): _toggleTerminal,
          const SingleActivator(LogicalKeyboardKey.keyB, control: true): _toggleSidebar,
          const SingleActivator(LogicalKeyboardKey.keyB, meta: true): _toggleSidebar,
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            appBar: AppBar(
              toolbarHeight: 44,
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
                if (wide) ...[
                  IconButton(
                    tooltip: 'Toggle sidebar (Ctrl+B)',
                    icon: Icon(Icons.view_sidebar_outlined, color: _sidebarOpen ? AppColors.text : AppColors.textDim),
                    onPressed: _toggleSidebar,
                  ),
                  IconButton(
                    tooltip: 'Toggle terminal (Ctrl+`)',
                    icon: Icon(Icons.terminal, color: _terminalOpen ? AppColors.text : AppColors.textDim),
                    onPressed: _toggleTerminal,
                  ),
                ],
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
                          onPressed: () => setState(() {
                            if (wide) {
                              _sidebarOpen = true;
                              _sideTab = 2;
                            } else {
                              _tab = 4;
                            }
                          }),
                        ),
                ),
              ],
            ),
            body: Column(
              children: [
                _reconnectBanner(ws),
                Expanded(child: wide ? _wide(context) : _narrow(context)),
                if (wide) _statusBar(ws),
              ],
            ),
            bottomNavigationBar: wide
                ? null
                : NavigationBar(
                    selectedIndex: _tab,
                    onDestinationSelected: (i) => setState(() {
                      _tab = i;
                      if (i == 3) {
                        final ws = ref.read(workspaceProvider);
                        ws.editor.latestClaude();
                        final idx = ws.editor.tabs.lastIndexWhere((t) => t is ClaudeTab);
                        if (idx >= 0) ws.editor.activate(idx);
                        _tab = 1;
                      }
                    }),
                    destinations: const [
                      NavigationDestination(icon: Icon(Icons.folder_outlined), label: 'Files'),
                      NavigationDestination(icon: Icon(Icons.edit_note), label: 'Editor'),
                      NavigationDestination(icon: Icon(Icons.terminal), label: 'Terminal'),
                      NavigationDestination(icon: Icon(Icons.auto_awesome), label: 'Claude'),
                      NavigationDestination(icon: Icon(Icons.cable), label: 'Ports'),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  Widget _narrow(BuildContext context) {
    return IndexedStack(
      index: _tab,
      children: [
        Column(
          children: [
            Material(
              color: AppColors.panel,
              child: Row(children: [_sideButton(0, Icons.folder_outlined, 'Files'), _sideButton(1, Icons.history, 'Sessions')]),
            ),
            const Divider(height: 1),
            Expanded(
              child: IndexedStack(
                index: _sideTab == 1 ? 1 : 0,
                children: [
                  FileBrowser(onOpenFile: (_) => setState(() => _tab = 1)),
                  ClaudeSessionList(onOpened: () => setState(() => _tab = 1)),
                ],
              ),
            ),
          ],
        ),
        const EditorView(),
        _terminal,
        const SizedBox.shrink(), // Claude: redirects to the editor tab
        const PortsView(),
      ],
    );
  }

  Widget _wide(BuildContext context) {
    final sidebar = Column(
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
            children: const [FileBrowser(), ClaudeSessionList(), PortsView()],
          ),
        ),
      ],
    );

    final terminalPanel = _TerminalPanel(
      terminal: _terminal,
      maximized: _terminalMax,
      onClose: _toggleTerminal,
      onToggleMax: () => setState(() => _terminalMax = !_terminalMax),
      onKill: () => _terminalKey.currentState?.restart(),
    );

    Widget main;
    if (!_terminalOpen) {
      // Hidden, not disposed: the shell keeps running.
      main = Column(
        children: [
          const Expanded(child: EditorView()),
          Offstage(offstage: true, child: SizedBox(height: 0, child: _terminal)),
        ],
      );
    } else if (_terminalMax) {
      main = terminalPanel;
    } else {
      main = SplitPane(
        axis: Axis.vertical,
        firstAtEnd: true,
        first: terminalPanel,
        second: const EditorView(),
        firstSize: _terminalHeight,
        minFirst: 80,
        minSecond: 120,
        onResize: (v) => setState(() {
          _terminalHeight = v;
          _saveLayout();
        }),
      );
    }

    if (!_sidebarOpen) return main;
    return SplitPane(
      axis: Axis.horizontal,
      first: sidebar,
      second: main,
      firstSize: _sidebarWidth,
      minFirst: 160,
      minSecond: 400,
      onResize: (v) => setState(() {
        _sidebarWidth = v;
        _saveLayout();
      }),
    );
  }

  /// VS Code-style status bar: the obvious place to get the terminal back.
  Widget _statusBar(WorkspaceSession ws) {
    Widget item(IconData icon, String label, VoidCallback onTap, {bool active = false, String? tooltip}) {
      return Tooltip(
        message: tooltip ?? label,
        child: InkWell(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            color: active ? Colors.white.withValues(alpha: 0.08) : null,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 13, color: Colors.white),
                const SizedBox(width: 5),
                Text(label, style: const TextStyle(fontSize: 11.5, color: Colors.white)),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      height: 22,
      color: const Color(0xFF0E639C),
      child: Row(
        children: [
          item(Icons.cloud_done_outlined, '${ws.host.label}: ${ws.dirName}', () => Navigator.of(context).maybePop(),
              tooltip: ws.workDir),
          const Spacer(),
          ListenableBuilder(
            listenable: ws.ports,
            builder: (_, _) => ws.ports.forwards.isEmpty
                ? const SizedBox.shrink()
                : item(Icons.cable, '${ws.ports.forwards.length} port${ws.ports.forwards.length == 1 ? '' : 's'}',
                    () => setState(() {
                          _sidebarOpen = true;
                          _sideTab = 2;
                        })),
          ),
          item(Icons.view_sidebar_outlined, 'Sidebar', _toggleSidebar, active: _sidebarOpen, tooltip: 'Toggle sidebar (Ctrl+B)'),
          item(Icons.terminal, 'Terminal', _toggleTerminal, active: _terminalOpen, tooltip: 'Toggle terminal (Ctrl+`)'),
        ],
      ),
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
              bottom: BorderSide(color: selected ? AppColors.accent : Colors.transparent, width: 2),
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

/// Bottom panel chrome around the terminal: title, maximize, close.
class _TerminalPanel extends StatelessWidget {
  const _TerminalPanel({
    required this.terminal,
    required this.maximized,
    required this.onClose,
    required this.onToggleMax,
    required this.onKill,
  });
  final Widget terminal;
  final bool maximized;
  final VoidCallback onClose;
  final VoidCallback onToggleMax;
  final VoidCallback onKill;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ContextMenuRegion(
          longPress: false,
          actions: () => [
            MenuAction(maximized ? 'Restore panel size' : 'Maximize panel', onToggleMax, icon: maximized ? Icons.close_fullscreen : Icons.open_in_full),
            MenuAction('Hide panel', onClose, icon: Icons.close, shortcut: 'Ctrl+`'),
            menuDivider,
            MenuAction('Kill terminal and restart', onKill, icon: Icons.delete_outline, danger: true),
          ],
          child: Material(
          color: AppColors.panel,
          child: SizedBox(
            height: 30,
            child: Row(
              children: [
                const SizedBox(width: 12),
                const Text('TERMINAL', style: TextStyle(fontSize: 11, letterSpacing: 1, color: AppColors.textDim)),
                const Spacer(),
                IconButton(
                  tooltip: 'Kill terminal and start a new shell',
                  iconSize: 16,
                  icon: const Icon(Icons.delete_outline),
                  onPressed: onKill,
                ),
                IconButton(
                  tooltip: maximized ? 'Restore panel size' : 'Maximize panel',
                  iconSize: 16,
                  icon: Icon(maximized ? Icons.close_fullscreen : Icons.open_in_full),
                  onPressed: onToggleMax,
                ),
                IconButton(
                  tooltip: 'Hide panel (Ctrl+`)',
                  iconSize: 16,
                  icon: const Icon(Icons.close),
                  onPressed: onClose,
                ),
              ],
            ),
          ),
        ),
        ),
        const Divider(height: 1),
        Expanded(child: terminal),
      ],
    );
  }
}
