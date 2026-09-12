import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../ssh/ssh_connection.dart';
import 'claude_protocol.dart';
import 'session_index.dart';

/// Drives one `claude -p` process on the remote over an SSH exec channel and
/// turns its stream-json output into a chat timeline.
///
/// The process stays alive across turns (stream-json input) so it behaves
/// like an interactive session; `sessionId` can be resumed later.
class ClaudeChat extends ChangeNotifier {
  ClaudeChat(this.conn, this.workDir);

  final SshConnection conn;
  final String workDir;

  /// Command used to launch Claude Code on the remote.
  static const claudeCommand = 'claude';

  /// Tag sessions the way the VS Code extension does so they are listed in
  /// both places (plain `-p` runs are tagged `sdk-cli` and hidden).
  static const entrypoint = 'claude-vscode';

  /// True while the stored transcript of a resumed session is loading.
  bool loadingHistory = false;

  /// Number of leading [items] that came from the stored transcript.
  int historyItemCount = 0;

  final List<ChatItem> items = [];
  String? sessionId;
  String? model;
  PermissionMode permissionMode = PermissionMode.normal;
  String? modelOverride;

  SSHSession? _session;
  StreamSubscription? _stdoutSub;
  StreamSubscription? _stderrSub;
  bool get isRunning => _session != null;
  bool busy = false; // a turn is in progress
  String? lastError;
  final _stderrBuf = StringBuffer();

  bool _disposed = false;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  AssistantTextItem? _streamingText;
  final Map<String, ToolCallItem> _toolCalls = {};

  /// Start (or resume) a Claude process. Safe to call when already running:
  /// the existing process is stopped first.
  Future<void> start({String? resumeSessionId}) async {
    await stop();
    items.clear();
    _toolCalls.clear();
    _streamingText = null;
    lastError = null;
    sessionId = resumeSessionId;
    historyItemCount = 0;
    _notify();

    if (resumeSessionId != null) {
      loadingHistory = true;
      _notify();
      try {
        final history = await ClaudeSessionIndex(conn, workDir).loadTranscript(resumeSessionId);
        items.addAll(history);
        historyItemCount = history.length;
        for (final t in history.whereType<ToolCallItem>()) {
          _toolCalls[t.call.id] = t;
        }
      } catch (e) {
        items.add(SystemNoteItem('Could not load history: $e', isError: true));
      }
      loadingHistory = false;
      _notify();
    }

    final args = <String>[
      claudeCommand,
      '-p',
      '--input-format', 'stream-json',
      '--output-format', 'stream-json',
      '--verbose',
      '--include-partial-messages',
      '--permission-prompt-tool', 'stdio',
      '--permission-mode', permissionMode.cliValue,
      if (resumeSessionId != null) ...['--resume', resumeSessionId],
      if (modelOverride != null && modelOverride!.isNotEmpty) ...[
        '--model',
        modelOverride!,
      ],
    ];
    final cmd = args.map(shq).join(' ');

    try {
      final s = await conn.execIn(workDir, 'CLAUDE_CODE_ENTRYPOINT=$entrypoint exec $cmd');
      _session = s;
      _stdoutSub = s.stdout
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_onLine, onError: (e) => _fail('stdout error: $e'));
      _stderrSub = s.stderr
          .cast<List<int>>()
          .transform(utf8.decoder)
          .listen((t) => _stderrBuf.write(t));
      s.done.then((_) => _onExit());
    } catch (e) {
      _fail('Failed to start Claude: $e');
    }
    _notify();
  }

  void _fail(String msg) {
    lastError = msg;
    items.add(SystemNoteItem(msg, isError: true));
    busy = false;
    _notify();
  }

  void _onExit() {
    final code = _session?.exitCode;
    _session = null;
    busy = false;
    final err = _stderrBuf.toString().trim();
    if (code != null && code != 0) {
      _fail('Claude exited with code $code${err.isEmpty ? '' : ':\n$err'}');
    } else if (err.isNotEmpty && items.isEmpty) {
      items.add(SystemNoteItem(err));
    }
    _streamingText?.streaming = false;
    _streamingText = null;
    _notify();
  }

  Future<void> stop() async {
    final s = _session;
    _session = null;
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;
    if (s != null) {
      try {
        s.close();
        // Wait for the process to exit so its final transcript writes land
        // before callers touch the session file (e.g. delete it).
        await s.done.timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
    busy = false;
    _streamingText = null;
    _notify();
  }

  void _write(Map<String, dynamic> obj) {
    final s = _session;
    if (s == null) return;
    s.write(Uint8List.fromList(utf8.encode('${jsonEncode(obj)}\n')));
  }

  Future<void> send(String text) async {
    if (text.trim().isEmpty) return;
    if (!isRunning) await start(resumeSessionId: sessionId);
    if (!isRunning) return;
    items.add(UserItem(text));
    busy = true;
    _notify();
    _write({
      'type': 'user',
      'message': {'role': 'user', 'content': text},
    });
  }

  /// Permission mode is a process flag, so changing it restarts the process
  /// while keeping the same session.
  Future<void> setPermissionMode(PermissionMode m) async {
    if (m == permissionMode) return;
    permissionMode = m;
    if (isRunning) {
      await start(resumeSessionId: sessionId);
    } else {
      _notify();
    }
  }

  /// Ask the CLI to interrupt the current turn (like pressing Esc).
  void interrupt() {
    if (!isRunning) return;
    _write({
      'type': 'control_request',
      'request_id': 'int-${DateTime.now().microsecondsSinceEpoch}',
      'request': {'subtype': 'interrupt'},
    });
  }

  void respondPermission(ToolCallItem item, {required bool allow, String? message}) {
    final req = item.pendingPermission;
    if (req == null) return;
    item.pendingPermission = null;
    item.permissionDecision = allow ? 'allow' : 'deny';
    _write({
      'type': 'control_response',
      'response': {
        'subtype': 'success',
        'request_id': req.requestId,
        'response': allow
            ? {'behavior': 'allow', 'updatedInput': req.input}
            : {'behavior': 'deny', 'message': message ?? 'User denied this action'},
      },
    });
    _notify();
  }

  int get pendingPermissionCount =>
      items.whereType<ToolCallItem>().where((t) => t.pendingPermission != null).length;

  // ---- protocol ------------------------------------------------------------

  @visibleForTesting
  void handleLine(String line) => _onLine(line);

  void _onLine(String line) {
    if (line.trim().isEmpty) return;
    Map<String, dynamic> o;
    try {
      o = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      items.add(SystemNoteItem(line));
      _notify();
      return;
    }
    switch (o['type']) {
      case 'system':
        _onSystem(o);
      case 'stream_event':
        _onStreamEvent(o['event'] as Map<String, dynamic>? ?? {});
      case 'assistant':
        _onAssistant(o['message'] as Map<String, dynamic>? ?? {});
      case 'user':
        _onUser(o['message'] as Map<String, dynamic>? ?? {});
      case 'control_request':
        _onControlRequest(o);
      case 'result':
        _onResult(o);
      default:
        break; // rate_limit_event, control_response, etc.
    }
    _notify();
  }

  void _onSystem(Map<String, dynamic> o) {
    if (o['subtype'] == 'init') {
      sessionId = o['session_id'] as String? ?? sessionId;
      model = o['model'] as String?;
    }
  }

  void _onStreamEvent(Map<String, dynamic> ev) {
    switch (ev['type']) {
      case 'content_block_delta':
        final delta = ev['delta'] as Map<String, dynamic>? ?? {};
        if (delta['type'] == 'text_delta') {
          final t = delta['text'] as String? ?? '';
          final cur = _streamingText;
          if (cur == null) {
            final n = AssistantTextItem(t, streaming: true);
            _streamingText = n;
            items.add(n);
          } else {
            cur.text += t;
          }
        }
      case 'content_block_stop':
        // Keep the streamed item; it will be replaced by the final
        // `assistant` message that follows.
        break;
    }
  }

  void _onAssistant(Map<String, dynamic> msg) {
    final content = msg['content'];
    if (content is! List) return;
    // The final assistant message supersedes the streamed partial text.
    final st = _streamingText;
    if (st != null) {
      items.remove(st);
      _streamingText = null;
    }
    for (final raw in content) {
      final b = ContentBlock.fromJson((raw as Map).cast<String, dynamic>());
      switch (b) {
        case TextBlock():
          if (b.text.trim().isNotEmpty) items.add(AssistantTextItem(b.text));
        case ThinkingBlock():
          if (b.text.trim().isNotEmpty) items.add(ThinkingItem(b.text));
        case ToolUseBlock():
          final item = ToolCallItem(b);
          _toolCalls[b.id] = item;
          items.add(item);
        case ToolResultBlock():
        case null:
          break;
      }
    }
  }

  void _onUser(Map<String, dynamic> msg) {
    final content = msg['content'];
    if (content is! List) return;
    for (final raw in content) {
      final b = ContentBlock.fromJson((raw as Map).cast<String, dynamic>());
      if (b is ToolResultBlock) {
        final item = _toolCalls[b.toolUseId];
        if (item != null) {
          item.result = b;
        } else {
          items.add(SystemNoteItem(b.content, isError: b.isError));
        }
      }
    }
  }

  void _onControlRequest(Map<String, dynamic> o) {
    final req = (o['request'] as Map?)?.cast<String, dynamic>() ?? {};
    if (req['subtype'] != 'can_use_tool') return;
    final pr = PermissionRequest(
      requestId: o['request_id'] as String,
      toolName: req['tool_name'] as String? ?? '?',
      input: (req['input'] as Map?)?.cast<String, dynamic>() ?? {},
      toolUseId: req['tool_use_id'] as String?,
      description: req['description'] as String?,
    );
    ToolCallItem? item;
    if (pr.toolUseId != null) item = _toolCalls[pr.toolUseId!];
    if (item == null) {
      item = ToolCallItem(ToolUseBlock(
        id: pr.toolUseId ?? pr.requestId,
        name: pr.toolName,
        input: pr.input,
      ));
      _toolCalls[item.call.id] = item;
      items.add(item);
    }
    if (permissionMode == PermissionMode.bypassPermissions) {
      item.pendingPermission = pr;
      respondPermission(item, allow: true);
      return;
    }
    item.pendingPermission = pr;
  }

  void _onResult(Map<String, dynamic> o) {
    busy = false;
    _streamingText?.streaming = false;
    _streamingText = null;
    sessionId = o['session_id'] as String? ?? sessionId;
    final isError = o['is_error'] == true;
    items.add(ResultItem(
      isError: isError,
      durationMs: (o['duration_ms'] as num?)?.toInt() ?? 0,
      costUsd: (o['total_cost_usd'] as num?)?.toDouble() ?? 0,
      numTurns: (o['num_turns'] as num?)?.toInt() ?? 0,
    ));
    if (isError) {
      final r = o['result'];
      if (r is String && r.isNotEmpty) items.add(SystemNoteItem(r, isError: true));
    }
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }
}
