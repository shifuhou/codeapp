import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../app.dart';
import '../../core/workspace_session.dart';

/// Interactive shell on the remote. Keeps its state alive when hidden
/// (wrapped in IndexedStack by the workspace page).
class TerminalPane extends ConsumerStatefulWidget {
  const TerminalPane({super.key});

  @override
  ConsumerState<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends ConsumerState<TerminalPane> {
  final _terminal = Terminal(maxLines: 10000);
  final _controller = TerminalController();
  SSHSession? _session;
  bool _ctrl = false;
  bool _alt = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    _terminal.onOutput = (data) {
      final s = _session;
      if (s == null) return;
      var out = data;
      if (_ctrl && out.length == 1) {
        final c = out.codeUnitAt(0);
        if (c >= 0x40 && c <= 0x7f) out = String.fromCharCode(c & 0x1f);
        setState(() => _ctrl = false);
      }
      if (_alt) {
        out = '\x1b$out';
        setState(() => _alt = false);
      }
      s.write(utf8.encode(out));
    };
    _terminal.onResize = (w, h, pw, ph) => _session?.resizeTerminal(w, h, pw, ph);
    _start();
  }

  Future<void> _start() async {
    final ws = ref.read(workspaceProvider);
    setState(() => _status = null);
    try {
      final s = await ws.conn.shell(
        width: _terminal.viewWidth,
        height: _terminal.viewHeight,
      );
      _session = s;
      s.stdout.cast<List<int>>().transform(utf8.decoder).listen(_terminal.write);
      s.stderr.cast<List<int>>().transform(utf8.decoder).listen(_terminal.write);
      // cd into the workspace folder.
      final dir = ws.workDir;
      if (dir.isNotEmpty) s.write(utf8.encode('cd ${_q(dir)} && clear\n'));
      s.done.then((_) {
        if (!mounted) return;
        setState(() {
          _session = null;
          _status = 'Shell exited';
        });
      });
    } catch (e) {
      setState(() => _status = 'Failed to open shell: $e');
    }
  }

  static String _q(String s) => "'${s.replaceAll("'", "'\\''")}'";

  void _send(String seq) => _session?.write(utf8.encode(seq));

  @override
  void dispose() {
    _session?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = Theme.of(context).platform == TargetPlatform.iOS ||
        Theme.of(context).platform == TargetPlatform.android;
    return Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              TerminalView(
                _terminal,
                controller: _controller,
                autofocus: true,
                backgroundOpacity: 1,
                padding: const EdgeInsets.all(6),
                textStyle: const TerminalStyle(fontSize: 13, fontFamily: 'JetBrains Mono', fontFamilyFallback: monoFamilies),
                theme: TerminalThemes.defaultTheme,
              ),
              if (_status != null)
                Positioned.fill(
                  child: Container(
                    color: Colors.black54,
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_status!, style: const TextStyle(color: AppColors.textDim)),
                          const SizedBox(height: 8),
                          FilledButton(onPressed: _start, child: const Text('Reconnect shell')),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (isMobile) _extraKeys(),
      ],
    );
  }

  /// Keys that phone keyboards lack.
  Widget _extraKeys() {
    Widget k(String label, VoidCallback onTap, {bool active = false}) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Material(
            color: active ? AppColors.accentDim : AppColors.panelAlt,
            borderRadius: BorderRadius.circular(4),
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Text(label, style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
              ),
            ),
          ),
        );
    return Container(
      color: AppColors.panel,
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        children: [
          k('Esc', () => _send('\x1b')),
          k('Tab', () => _send('\t')),
          k('Ctrl', () => setState(() => _ctrl = !_ctrl), active: _ctrl),
          k('Alt', () => setState(() => _alt = !_alt), active: _alt),
          k('^C', () => _send('\x03')),
          k('^D', () => _send('\x04')),
          k('^Z', () => _send('\x1a')),
          k('←', () => _send('\x1b[D')),
          k('↓', () => _send('\x1b[B')),
          k('↑', () => _send('\x1b[A')),
          k('→', () => _send('\x1b[C')),
          k('Home', () => _send('\x1b[H')),
          k('End', () => _send('\x1b[F')),
          k('|', () => _send('|')),
          k('~', () => _send('~')),
          k('-', () => _send('-')),
          k('/', () => _send('/')),
        ],
      ),
    );
  }
}
