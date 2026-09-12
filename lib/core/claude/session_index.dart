import 'dart:convert';

import '../ssh/ssh_connection.dart';
import 'claude_protocol.dart';

class ClaudeSessionInfo {
  ClaudeSessionInfo({
    required this.id,
    required this.title,
    required this.modified,
    required this.sizeBytes,
  });
  final String id;
  final String title;
  final DateTime modified;
  final int sizeBytes;
}

/// Reads Claude Code sessions stored on the remote under
/// `~/.claude/projects/<encoded cwd>/<session>.jsonl`.
class ClaudeSessionIndex {
  ClaudeSessionIndex(this.conn, this.workDir);
  final SshConnection conn;
  final String workDir;

  /// Claude Code encodes the project path by replacing every character that
  /// is not a letter or digit with '-'.
  static String encodeProjectDir(String absPath) =>
      absPath.replaceAll(RegExp(r'[^A-Za-z0-9]'), '-');

  String get projectDir =>
      '${conn.homeDir}/.claude/projects/${encodeProjectDir(workDir)}';

  /// Sessions started programmatically (Agent SDK, `claude -p` from scripts)
  /// are hidden, like the VS Code extension does. Our own sessions are
  /// tagged `claude-vscode` (see ClaudeChat) so they show up in both.
  static const hiddenEntrypoints = {'sdk-cli', 'sdk-ts', 'sdk-py'};

  Future<List<ClaudeSessionInfo>> list() async {
    // For each session file (newest first) print a header line and then
    // three probe lines: latest ai-title, first summary, first user message.
    final script = '''
d=${shq(projectDir)}
[ -d "\$d" ] || exit 0
cd "\$d"
for f in \$(ls -t *.jsonl 2>/dev/null); do
  echo "@@FILE \${f%.jsonl} \$(stat -c '%Y %s' "\$f" 2>/dev/null || stat -f '%m %z' "\$f")"
  grep '"type":"ai-title"' "\$f" 2>/dev/null | tail -n1 | head -c 2000
  echo
  grep -m1 '"type":"summary"' "\$f" 2>/dev/null | head -c 2000
  echo
  grep -m1 '"type":"user"' "\$f" 2>/dev/null | head -c 6000
  echo
done
''';
    final out = await conn.run('bash -c ${shq(script)}',
        timeout: const Duration(seconds: 30));
    return parseListing(out);
  }

  static List<ClaudeSessionInfo> parseListing(String out) {
    final result = <ClaudeSessionInfo>[];
    final lines = out.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final l = lines[i];
      if (!l.startsWith('@@FILE ')) continue;
      final parts = l.substring(7).trim().split(' ');
      if (parts.isEmpty) continue;
      final id = parts[0];
      final mtime = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
      final size = parts.length > 2 ? int.tryParse(parts[2]) ?? 0 : 0;
      final titleLine = i + 1 < lines.length ? lines[i + 1] : '';
      final summaryLine = i + 2 < lines.length ? lines[i + 2] : '';
      final userLine = i + 3 < lines.length ? lines[i + 3] : '';
      final user = _tryJson(userLine);
      final entry = user?['entrypoint'];
      if (entry is String && hiddenEntrypoints.contains(entry)) continue;
      var title = _field(titleLine, 'aiTitle') ??
          _field(summaryLine, 'summary') ??
          _userText(user, userLine) ??
          '';
      title = title.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (title.length > 120) title = '${title.substring(0, 120)}…';
      if (title.isEmpty) title = '(empty session)';
      result.add(ClaudeSessionInfo(
        id: id,
        title: title,
        modified: DateTime.fromMillisecondsSinceEpoch(mtime * 1000),
        sizeBytes: size,
      ));
    }
    return result;
  }

  static Map<String, dynamic>? _tryJson(String line) {
    if (line.trim().isEmpty) return null;
    try {
      return jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static String? _field(String line, String key) {
    final o = _tryJson(line);
    final v = o?[key];
    if (v is String && v.trim().isNotEmpty) return v;
    // Truncated line: fall back to a regex.
    final m = RegExp('"$key":"((?:[^"\\\\]|\\\\.)*)"').firstMatch(line);
    if (m != null) {
      try {
        return jsonDecode('"${m.group(1)}"') as String;
      } catch (_) {}
    }
    return null;
  }

  static String? _userText(Map<String, dynamic>? o, String rawLine) {
    if (o != null) {
      final t = userTextOf(o);
      if (t != null && t.isNotEmpty) return t;
    }
    final m = RegExp(r'"text":"((?:[^"\\]|\\.)*)').firstMatch(rawLine);
    if (m != null) {
      try {
        return cleanUserText(jsonDecode('"${m.group(1)}"') as String);
      } catch (_) {
        return cleanUserText(m.group(1)!);
      }
    }
    return null;
  }

  /// Visible text of a `user` transcript line, or null if it is not a human
  /// message (tool results, meta notes, system reminders...).
  static String? userTextOf(Map<String, dynamic> o) {
    if (o['isMeta'] == true) return null;
    final c = o['message']?['content'];
    String text;
    if (c is String) {
      text = c;
    } else if (c is List) {
      final parts = <String>[];
      for (final b in c) {
        if (b is! Map) continue;
        if (b['type'] == 'text') parts.add(b['text'] as String? ?? '');
        if (b['type'] == 'image') parts.add('[image]');
        if (b['type'] == 'tool_result') return null;
      }
      text = parts.join('\n');
    } else {
      return null;
    }
    text = cleanUserText(text);
    return text.isEmpty ? null : text;
  }

  static String cleanUserText(String s) {
    // Drop harness-injected blocks (system reminders, task notifications,
    // slash-command wrappers) and keep what the person actually typed.
    s = s.replaceAll(RegExp(r'<system-reminder>[\s\S]*?</system-reminder>'), ' ');
    s = s.replaceAll(RegExp(r'<task-notification>[\s\S]*?</task-notification>'), ' ');
    s = s.replaceAll(RegExp(r'<command-[a-z-]+>[^<]*</command-[a-z-]+>'), ' ');
    s = s.replaceAll(RegExp(r'<local-command-[a-z-]+>[\s\S]*?</local-command-[a-z-]+>'), ' ');
    s = s.replaceAll(RegExp(r'\[Image: original[^\]]*\]'), '[image]');
    return s.trim();
  }

  // ---- transcript ----------------------------------------------------------

  static const maxTranscriptBytes = 8 * 1024 * 1024;

  /// Loads the stored conversation so it can be shown when resuming.
  Future<List<ChatItem>> loadTranscript(String sessionId) async {
    final path = '$projectDir/$sessionId.jsonl';
    final out = await conn.run(
      'tail -c $maxTranscriptBytes ${shq(path)} 2>/dev/null',
      timeout: const Duration(seconds: 60),
    );
    return parseTranscript(out);
  }

  static List<ChatItem> parseTranscript(String jsonl) {
    final items = <ChatItem>[];
    final tools = <String, ToolCallItem>{};
    for (final line in const LineSplitter().convert(jsonl)) {
      final o = _tryJson(line);
      if (o == null) continue; // e.g. the first partial line after tail -c
      if (o['isSidechain'] == true) continue;
      switch (o['type']) {
        case 'user':
          final c = o['message']?['content'];
          if (c is List) {
            var attached = false;
            for (final b in c) {
              if (b is! Map || b['type'] != 'tool_result') continue;
              attached = true;
              final r = ContentBlock.fromJson(b.cast<String, dynamic>());
              if (r is ToolResultBlock) tools[r.toolUseId]?.result = r;
            }
            if (attached) break;
          }
          final t = userTextOf(o);
          if (t != null) items.add(UserItem(t));
        case 'assistant':
          final c = o['message']?['content'];
          if (c is! List) break;
          for (final raw in c) {
            if (raw is! Map) continue;
            final b = ContentBlock.fromJson(raw.cast<String, dynamic>());
            switch (b) {
              case TextBlock():
                if (b.text.trim().isNotEmpty) items.add(AssistantTextItem(b.text));
              case ThinkingBlock():
                if (b.text.trim().isNotEmpty) items.add(ThinkingItem(b.text));
              case ToolUseBlock():
                final item = ToolCallItem(b);
                tools[b.id] = item;
                items.add(item);
              default:
                break;
            }
          }
      }
    }
    return items;
  }

  Future<void> delete(String id) async {
    await conn.run('rm -f ${shq('$projectDir/$id.jsonl')}');
  }
}
