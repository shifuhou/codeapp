import 'dart:convert';

import '../ssh/ssh_connection.dart';

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

/// Lists Claude Code sessions stored on the remote under
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

  Future<List<ClaudeSessionInfo>> list() async {
    // For each session file (newest first) print: id, mtime, size, then the
    // first summary line and the first user line, truncated.
    final script = '''
d=${shq(projectDir)}
[ -d "\$d" ] || exit 0
cd "\$d"
for f in \$(ls -t *.jsonl 2>/dev/null); do
  echo "@@FILE \${f%.jsonl} \$(stat -c '%Y %s' "\$f" 2>/dev/null || stat -f '%m %z' "\$f")"
  grep -m1 '"type":"summary"' "\$f" 2>/dev/null | head -c 1000
  echo
  grep -m1 '"type":"user"' "\$f" 2>/dev/null | head -c 4000
  echo
done
''';
    final out = await conn.run('bash -c ${shq(script)}',
        timeout: const Duration(seconds: 20));
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
      final summaryLine = i + 1 < lines.length ? lines[i + 1] : '';
      final userLine = i + 2 < lines.length ? lines[i + 2] : '';
      var title = _extractSummary(summaryLine) ?? _extractUserText(userLine) ?? '';
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

  String? _extractSummary(String line) {
    if (line.trim().isEmpty) return null;
    try {
      final o = jsonDecode(line) as Map<String, dynamic>;
      final s = o['summary'];
      if (s is String && s.trim().isNotEmpty) return s;
    } catch (_) {}
    return null;
  }

  String? _extractUserText(String line) {
    if (line.trim().isEmpty) return null;
    // The line may be truncated by head -c; try full parse then fall back to
    // a regex on the "text" field.
    try {
      final o = jsonDecode(line) as Map<String, dynamic>;
      final c = o['message']?['content'];
      if (c is String) return _clean(c);
      if (c is List) {
        for (final b in c) {
          if (b is Map && b['type'] == 'text') return _clean(b['text'] as String? ?? '');
        }
      }
    } catch (_) {
      final m = RegExp(r'"text":"((?:[^"\\]|\\.)*)').firstMatch(line);
      if (m != null) {
        try {
          return _clean(jsonDecode('"${m.group(1)}"') as String);
        } catch (_) {
          return _clean(m.group(1)!);
        }
      }
    }
    return null;
  }

  String _clean(String s) {
    // Strip slash-command wrappers Claude Code stores in the transcript.
    s = s.replaceAll(RegExp(r'<command-[a-z-]+>[^<]*</command-[a-z-]+>'), ' ');
    s = s.replaceAll(RegExp(r'<[^>]+>'), ' ');
    return s.trim();
  }

  Future<void> delete(String id) async {
    await conn.run('rm -f ${shq('$projectDir/$id.jsonl')}');
  }
}
