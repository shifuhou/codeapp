import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../ssh/ssh_connection.dart';
import 'claude_daemon.dart';
import 'claude_protocol.dart';
import 'session_index.dart';

/// Drives one `claude -p` process on the remote and turns its stream-json
/// output into a chat timeline.
///
/// The process is a [ClaudeDaemon]: it lives on the server, detached from the
/// SSH connection, so a dropped connection (phone locked) does not interrupt
/// it. The app attaches by tailing its log and can re-attach later; the log
/// replays everything (including what the app sent) to rebuild the state.
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

  /// Slash commands the CLI reported in its init message (custom commands
  /// and the built-ins it supports in this mode).
  List<String> cliSlashCommands = [];

  /// Session totals accumulated from `result` messages.
  double totalCostUsd = 0;
  int totalInputTokens = 0;
  int totalOutputTokens = 0;
  int totalCacheReadTokens = 0;
  int totalCacheWriteTokens = 0;
  int totalDurationMs = 0;
  int turnsCompleted = 0;

  /// Context size of the last request (input + cache tokens).
  int lastContextTokens = 0;

  /// Latest TodoWrite list (content/status/activeForm maps).
  List<Map<String, dynamic>> todos = [];

  /// Permission requests waiting for an answer, oldest first.
  List<ToolCallItem> get pendingPermissions =>
      items.whereType<ToolCallItem>().where((t) => t.pendingPermission != null).toList();

  final _pendingControl = <String, Completer<Map<String, dynamic>>>{};

  ClaudeDaemon? _daemon;
  SSHSession? _tail;
  SSHSession? _writer;
  StreamSubscription? _tailSub;

  /// A process exists on the server (as far as we know).
  bool get isRunning => _daemon != null;

  /// We are currently following the process output.
  bool attached = false;

  /// Bytes of log still being replayed after an attach; while > 0 the lines
  /// are history, and nothing is written back to the process.
  int _replayRemaining = 0;
  bool get replaying => _replayRemaining > 0;

  bool busy = false; // a turn is in progress
  String? lastError;
  Timer? _aliveTimer;

  bool _disposed = false;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  AssistantTextItem? _streamingText;
  final Map<String, ToolCallItem> _toolCalls = {};

  /// Start (or resume) a Claude process. Safe to call when already running:
  /// the existing process is stopped first. Resuming a session that still
  /// has a live process on the server attaches to it instead of starting a
  /// new one.
  Future<void> start({String? resumeSessionId}) async {
    await stop();
    _resetTimeline();
    sessionId = resumeSessionId;
    _notify();

    final index = ClaudeSessionIndex(conn, workDir);
    var histBytes = 0;
    if (resumeSessionId != null) {
      try {
        final live = await ClaudeDaemon.liveBySession(conn, workDir: workDir);
        final did = live[resumeSessionId];
        if (did != null) {
          _daemon = ClaudeDaemon(conn, did);
          final meta = await _daemon!.meta();
          histBytes = int.tryParse(meta['hist_bytes'] ?? '') ?? 0;
          await _loadHistory(index, resumeSessionId, maxBytes: histBytes);
          await _attach();
          return;
        }
        histBytes = await index.transcriptSize(resumeSessionId);
      } catch (e) {
        items.add(SystemNoteItem('Could not check for a running process: $e', isError: true));
      }
      await _loadHistory(index, resumeSessionId, maxBytes: histBytes);
    }

    final args = <String>[
      claudeCommand,
      '-p',
      '--input-format', 'stream-json',
      '--output-format', 'stream-json',
      '--verbose',
      '--include-partial-messages',
      '--permission-prompt-tool', 'stdio',
      // Lets a live session be switched to bypassPermissions later; the
      // actual mode is still --permission-mode.
      '--dangerously-skip-permissions',
      '--permission-mode', permissionMode.cliValue,
      if (resumeSessionId != null) ...['--resume', resumeSessionId],
      if (modelOverride != null && modelOverride!.isNotEmpty) ...['--model', modelOverride!],
    ];
    try {
      _daemon = await ClaudeDaemon.start(
        conn,
        id: const Uuid().v4(),
        workDir: workDir,
        command: args.map(shq).join(' '),
        env: 'CLAUDE_CODE_ENTRYPOINT=$entrypoint',
        histBytes: histBytes,
      );
      await _attach();
    } catch (e) {
      _fail('Failed to start Claude: $e');
    }
  }

  void _resetTimeline() {
    items.clear();
    _toolCalls.clear();
    _streamingText = null;
    lastError = null;
    historyItemCount = 0;
    todos = [];
    _pendingControl.clear();
  }

  Future<void> _loadHistory(ClaudeSessionIndex index, String id, {int? maxBytes}) async {
    loadingHistory = true;
    _notify();
    try {
      final history = await index.loadTranscript(id, maxBytes: maxBytes);
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

  /// Follow the process log. Everything already in the log is replayed
  /// first (rebuilding live state), then new output streams in.
  Future<void> _attach() async {
    final d = _daemon;
    if (d == null) return;
    await _closeChannels();
    // Drop live items from a previous attach; history stays.
    if (items.length > historyItemCount) items.removeRange(historyItemCount, items.length);
    _toolCalls.removeWhere((_, t) => !items.contains(t));
    _streamingText = null;
    busy = false;
    todos = [];
    _pendingControl.clear();

    try {
      final size = await conn.run('stat -c %s ${shq('${d.dir}/out.log')} 2>/dev/null || echo 0');
      _replayRemaining = int.tryParse(size.trim()) ?? 0;
      final t = await d.tail();
      _tail = t;
      _tailSub = t.stdout.cast<List<int>>().map((chunk) {
        if (_replayRemaining > 0) {
          _replayRemaining -= chunk.length;
          if (_replayRemaining <= 0) {
            _replayRemaining = 0;
            scheduleMicrotask(_onReplayDone);
          }
        }
        return chunk;
      }).transform(utf8.decoder).transform(const LineSplitter()).listen(
            _onLine,
            onError: (e) => _onDetached('stream error: $e'),
            onDone: () => _onDetached(null),
          );
      attached = true;
      if (_replayRemaining == 0) _onReplayDone();
      _aliveTimer?.cancel();
      _aliveTimer = Timer.periodic(const Duration(seconds: 20), (_) => _checkAlive());
    } catch (e) {
      _fail('Could not attach to Claude: $e');
    }
    _notify();
  }

  /// Called once the pre-existing log has been consumed.
  void _onReplayDone() {
    // Anything the process is still waiting on gets the current policy.
    if (permissionMode == PermissionMode.bypassPermissions) {
      for (final t in pendingPermissions) {
        if (!t.isQuestion) respondPermission(t, allow: true);
      }
    }
    _checkAlive();
    _notify();
  }

  Future<void> _checkAlive() async {
    final d = _daemon;
    if (d == null || !conn.isConnected) return;
    try {
      if (await d.isAlive()) return;
    } catch (_) {
      return;
    }
    final err = (await conn.run('tail -c 2000 ${shq('${d.dir}/err.log')} 2>/dev/null')).trim();
    final code = (await conn.run('cat ${shq('${d.dir}/exit')} 2>/dev/null')).trim();
    _daemon = null;
    _aliveTimer?.cancel();
    if (code.isNotEmpty && code != '0') {
      _fail('Claude exited with code $code${err.isEmpty ? '' : ':\n$err'}');
    } else if (busy) {
      _fail('Claude process ended unexpectedly${err.isEmpty ? '' : ':\n$err'}');
    }
    busy = false;
    _streamingText = null;
    await _closeChannels();
    await d.cleanup();
    _notify();
  }

  void _onDetached(String? why) {
    attached = false;
    _tail = null;
    _tailSub = null;
    _notify();
  }

  /// Re-attach after the SSH connection came back.
  Future<void> reattach() async {
    if (_daemon == null || attached) return;
    await _attach();
  }

  Future<void> _closeChannels() async {
    await _tailSub?.cancel();
    _tailSub = null;
    try {
      _tail?.close();
    } catch (_) {}
    _tail = null;
    try {
      _writer?.close();
    } catch (_) {}
    _writer = null;
    attached = false;
  }

  void _fail(String msg) {
    lastError = msg;
    items.add(SystemNoteItem(msg, isError: true));
    busy = false;
    _notify();
  }

  /// Stop following without killing the process (it keeps working on the
  /// server; resume the session later to pick it up).
  Future<void> detach() async {
    _aliveTimer?.cancel();
    await _closeChannels();
    _daemon = null;
    busy = false;
    _streamingText = null;
    _notify();
  }

  /// Kill the process on the server.
  Future<void> stop() async {
    _aliveTimer?.cancel();
    final d = _daemon;
    _daemon = null;
    await _closeChannels();
    if (d != null) {
      try {
        await d.kill();
      } catch (_) {}
    }
    busy = false;
    _streamingText = null;
    _notify();
  }

  Future<void> _write(Map<String, dynamic> obj) async {
    if (replaying) return; // never answer the past
    final d = _daemon;
    if (d == null) return;
    var w = _writer;
    if (w == null) {
      try {
        w = await d.writer();
        _writer = w;
        w.done.then((_) {
          if (identical(_writer, w)) _writer = null;
        });
      } catch (e) {
        _fail('Cannot reach Claude: $e');
        return;
      }
    }
    w.write(Uint8List.fromList(utf8.encode('${jsonEncode(obj)}\n')));
  }

  Future<void> send(String text) async {
    if (text.trim().isEmpty) return;
    if (!isRunning) await start(resumeSessionId: sessionId);
    if (!isRunning) return;
    if (!attached) await reattach();
    // The message comes back through the log (tee), which adds the bubble;
    // flip busy now so the UI reacts immediately.
    busy = true;
    _notify();
    await _write({
      'type': 'user',
      'message': {'role': 'user', 'content': text},
    });
  }

  /// Switch permission mode without restarting: the CLI accepts a
  /// `set_permission_mode` control request mid-session. New processes get the
  /// mode as a flag.
  Future<void> setPermissionMode(PermissionMode m) async {
    if (m == permissionMode) return;
    final prev = permissionMode;
    permissionMode = m;
    _notify();
    if (m == PermissionMode.bypassPermissions) {
      // Anything already waiting is approved by the new mode.
      for (final t in pendingPermissions) {
        if (!t.isQuestion) respondPermission(t, allow: true);
      }
    }
    if (!isRunning) return;
    final r = await _control({'subtype': 'set_permission_mode', 'mode': m.cliValue});
    if (r != null && r['subtype'] == 'error') {
      if (m == PermissionMode.bypassPermissions) {
        // The CLI refused, but the app answers every permission request
        // itself, so bypass still works from this side.
        items.add(SystemNoteItem('Permission mode: ${m.label} (approved by the app; CLI said: ${r['error']})'));
      } else {
        permissionMode = prev;
        items.add(SystemNoteItem('Could not switch permission mode: ${r['error']}', isError: true));
      }
    } else {
      items.add(SystemNoteItem('Permission mode: ${m.label}'));
    }
    _notify();
  }

  /// Switch model. Live sessions take a `set_model` control request; the
  /// choice also applies to the next process start.
  Future<void> setModel(String? modelId) async {
    modelOverride = (modelId == null || modelId.isEmpty || modelId == 'default') ? null : modelId;
    if (!isRunning) {
      _notify();
      return;
    }
    final r = await _control({'subtype': 'set_model', if (modelOverride != null) 'model': modelOverride});
    if (r != null && r['subtype'] == 'error') {
      items.add(SystemNoteItem('Could not switch model: ${r['error']}', isError: true));
    } else {
      model = modelOverride ?? model;
      items.add(SystemNoteItem('Model: ${modelOverride ?? 'default'}'));
    }
    _notify();
  }

  /// Sends a control request and waits (briefly) for its response.
  Future<Map<String, dynamic>?> _control(Map<String, dynamic> request) async {
    if (!isRunning) return null;
    final id = 'req-${DateTime.now().microsecondsSinceEpoch}';
    final c = Completer<Map<String, dynamic>>();
    _pendingControl[id] = c;
    _write({'type': 'control_request', 'request_id': id, 'request': request});
    try {
      return await c.future.timeout(const Duration(seconds: 10));
    } catch (_) {
      return null;
    } finally {
      _pendingControl.remove(id);
    }
  }

  /// Summary for `/usage`.
  String usageSummary() {
    String k(int n) => n >= 1000 ? '${(n / 1000).toStringAsFixed(1)}k' : '$n';
    return [
      'Session ${sessionId?.substring(0, 8) ?? '(new)'} · model ${model ?? modelOverride ?? 'default'} · ${permissionMode.label}',
      'Turns: $turnsCompleted · time ${(totalDurationMs / 1000).toStringAsFixed(0)}s · cost \$${totalCostUsd.toStringAsFixed(4)}',
      'Tokens: in ${k(totalInputTokens)} · out ${k(totalOutputTokens)} · cache read ${k(totalCacheReadTokens)} · cache write ${k(totalCacheWriteTokens)}',
      'Last request context: ${k(lastContextTokens)} tokens',
    ].join('\n');
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

  void respondPermission(ToolCallItem item, {required bool allow, String? message, List<Map<String, dynamic>>? updatedPermissions}) {
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
            ? {
                'behavior': 'allow',
                'updatedInput': req.input,
                if (updatedPermissions != null && updatedPermissions.isNotEmpty) 'updatedPermissions': updatedPermissions,
              }
            : {'behavior': 'deny', 'message': message ?? 'User denied this action'},
      },
    });
    _notify();
  }

  /// Allow and remember: applies the CLI's suggested rule (written to the
  /// project's .claude/settings.local.json, like the original prompt's
  /// "always allow"), or a plain rule for the tool when none was suggested.
  void allowAlways(ToolCallItem item) {
    final req = item.pendingPermission;
    if (req == null) return;
    final rules = req.suggestions.where((s) => s['behavior'] == 'allow').toList();
    respondPermission(item, allow: true, updatedPermissions: rules.isNotEmpty
        ? rules
        : [
            {
              'type': 'addRules',
              'rules': [{'toolName': req.toolName}],
              'behavior': 'allow',
              'destination': 'localSettings',
            }
          ]);
    items.add(SystemNoteItem('Always allow: ${req.alwaysAllowLabel}'));
    _notify();
  }

  /// Answers an AskUserQuestion: the CLI reads the choices back from
  /// `updatedInput.answers` (question text -> chosen label(s)).
  void answerQuestion(ToolCallItem item, Map<String, String> answers) {
    final req = item.pendingPermission;
    if (req == null) return;
    item.pendingPermission = null;
    item.permissionDecision = 'allow';
    _write({
      'type': 'control_response',
      'response': {
        'subtype': 'success',
        'request_id': req.requestId,
        'response': {
          'behavior': 'allow',
          'updatedInput': {...req.input, 'answers': answers},
        },
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
        _onAssistant(o['message'] as Map<String, dynamic>? ?? {}, parent: o['parent_tool_use_id'] as String?);
      case 'user':
        _onUser(o['message'] as Map<String, dynamic>? ?? {}, parent: o['parent_tool_use_id'] as String?);
      case 'control_request':
        if (_isOurs(o)) {
          _onOwnControlRequest(o);
        } else {
          _onControlRequest(o);
        }
      case 'control_response':
        final r = (o['response'] as Map?)?.cast<String, dynamic>() ?? {};
        final id = r['request_id'];
        final c = _pendingControl[id];
        if (c != null) {
          c.complete(r);
        } else {
          _onOwnPermissionAnswer(r);
        }
      case 'result':
        _onResult(o);
      default:
        break; // rate_limit_event etc.
    }
    _notify();
  }

  /// Lines we wrote ourselves (they pass through the log via tee).
  static bool _isOurs(Map<String, dynamic> o) {
    final sub = (o['request'] as Map?)?['subtype'];
    return sub == 'interrupt' || sub == 'set_permission_mode' || sub == 'set_model';
  }

  /// Replaying our own mode/model switches restores the state they set.
  void _onOwnControlRequest(Map<String, dynamic> o) {
    if (!replaying) return;
    final req = (o['request'] as Map?)?.cast<String, dynamic>() ?? {};
    switch (req['subtype']) {
      case 'set_permission_mode':
        final m = PermissionMode.values.where((x) => x.cliValue == req['mode']).firstOrNull;
        if (m != null) permissionMode = m;
      case 'set_model':
        modelOverride = req['model'] as String?;
    }
  }

  /// A replayed answer we gave to a permission request.
  void _onOwnPermissionAnswer(Map<String, dynamic> r) {
    final id = r['request_id'];
    for (final t in pendingPermissions) {
      if (t.pendingPermission!.requestId == id) {
        final behavior = (r['response'] as Map?)?['behavior'];
        t.pendingPermission = null;
        t.permissionDecision = behavior == 'allow' ? 'allow' : 'deny';
      }
    }
  }

  void _onSystem(Map<String, dynamic> o) {
    if (o['subtype'] == 'init') {
      final sid = o['session_id'] as String?;
      if (sid != null && sid != sessionId) {
        sessionId = sid;
        _daemon?.setSession(sid).catchError((_) {});
      } else if (sid != null && replaying) {
        sessionId = sid;
      } else if (sid != null) {
        _daemon?.setSession(sid).catchError((_) {});
      }
      model = o['model'] as String?;
      final sc = o['slash_commands'];
      if (sc is List) cliSlashCommands = sc.whereType<String>().toList();
      final pm = o['permissionMode'] as String?;
      if (pm != null) {
        if (replaying) {
          // The log knows better than a fresh app what mode the process is in.
          permissionMode = PermissionMode.values.firstWhere((m) => m.cliValue == pm, orElse: () => permissionMode);
        } else if (pm != permissionMode.cliValue) {
          // --dangerously-skip-permissions makes the CLI start in bypass; the
          // app's chosen mode is the truth, so put the CLI back to it.
          _control({'subtype': 'set_permission_mode', 'mode': permissionMode.cliValue});
        }
      }
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

  /// Where a message lands: the main timeline, or inside the tool call
  /// that spawned the subagent producing it.
  List<ChatItem> _sink(String? parent) => (parent == null ? null : _toolCalls[parent]?.children) ?? items;

  void _onAssistant(Map<String, dynamic> msg, {String? parent}) {
    final content = msg['content'];
    if (content is! List) return;
    final sink = _sink(parent);
    // The final assistant message supersedes the streamed partial text.
    final st = _streamingText;
    if (st != null && parent == null) {
      items.remove(st);
      _streamingText = null;
    }
    for (final raw in content) {
      final b = ContentBlock.fromJson((raw as Map).cast<String, dynamic>());
      switch (b) {
        case TextBlock():
          if (b.text.trim().isNotEmpty) sink.add(AssistantTextItem(b.text));
        case ThinkingBlock():
          if (b.text.trim().isNotEmpty) sink.add(ThinkingItem(b.text));
        case ToolUseBlock():
          final item = ToolCallItem(b);
          _toolCalls[b.id] = item;
          sink.add(item);
          if (b.name == 'TodoWrite') {
            final t = b.input['todos'];
            if (t is List) todos = [for (final x in t) if (x is Map) x.cast<String, dynamic>()];
          } else if (b.name == 'TaskUpdate') {
            // Newer CLIs track work as tasks: TaskCreate (id comes back in
            // the result) and TaskUpdate(taskId, status, subject?).
            final id = '${b.input['taskId']}';
            final t = todos.where((x) => x['id'] == id).firstOrNull;
            if (t != null) {
              if (b.input['status'] != null) t['status'] = b.input['status'];
              if (b.input['subject'] != null) t['content'] = b.input['subject'];
              if (b.input['activeForm'] != null) t['activeForm'] = b.input['activeForm'];
              todos = [...todos];
            }
          }
        case ToolResultBlock():
        case null:
          break;
      }
    }
  }

  void _onUser(Map<String, dynamic> msg, {String? parent}) {
    final content = msg['content'];
    if (content is String) {
      // Our own prompt, echoed through the log.
      if (parent == null) {
        items.add(UserItem(content));
        busy = true;
      }
      return;
    }
    if (content is! List) return;
    for (final raw in content) {
      final b = ContentBlock.fromJson((raw as Map).cast<String, dynamic>());
      if (b is ToolResultBlock) {
        final item = _toolCalls[b.toolUseId];
        if (item != null) {
          item.result = b;
          if (item.call.name == 'TaskCreate' && !b.isError) {
            final id = RegExp(r'#(\d+)').firstMatch(b.content)?.group(1);
            if (id != null && !todos.any((x) => x['id'] == id)) {
              todos = [
                ...todos,
                {
                  'id': id,
                  'content': item.call.input['subject'] ?? item.call.input['description'] ?? 'Task #$id',
                  'activeForm': item.call.input['activeForm'],
                  'status': 'pending',
                },
              ];
            }
          }
        } else {
          _sink(parent).add(SystemNoteItem(b.content, isError: b.isError));
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
      suggestions: [
        for (final s in (req['permission_suggestions'] as List? ?? const []))
          if (s is Map) s.cast<String, dynamic>(),
      ],
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
    if (permissionMode == PermissionMode.bypassPermissions && !item.isQuestion && !replaying) {
      item.pendingPermission = pr;
      respondPermission(item, allow: true);
      return;
    }
    item.pendingPermission = pr;
  }

  void _onResult(Map<String, dynamic> o) {
    busy = false;
    if (!replaying) Future.delayed(const Duration(seconds: 2), _checkAlive);
    _streamingText?.streaming = false;
    _streamingText = null;
    sessionId = o['session_id'] as String? ?? sessionId;
    final isError = o['is_error'] == true;
    turnsCompleted++;
    totalCostUsd = (o['total_cost_usd'] as num?)?.toDouble() ?? totalCostUsd;
    totalDurationMs += (o['duration_ms'] as num?)?.toInt() ?? 0;
    final u = (o['usage'] as Map?)?.cast<String, dynamic>();
    if (u != null) {
      int n(String key) => (u[key] as num?)?.toInt() ?? 0;
      totalInputTokens += n('input_tokens');
      totalOutputTokens += n('output_tokens');
      totalCacheReadTokens += n('cache_read_input_tokens');
      totalCacheWriteTokens += n('cache_creation_input_tokens');
      lastContextTokens = n('input_tokens') + n('cache_read_input_tokens') + n('cache_creation_input_tokens');
    }
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
    _aliveTimer?.cancel();
    _closeChannels();
    super.dispose();
  }
}
