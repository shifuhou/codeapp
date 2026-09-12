import 'dart:io';

import 'package:codeapp/core/claude/claude_protocol.dart';
import 'package:codeapp/core/claude/session_index.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses a stored transcript into chat items', () {
    final jsonl = File('test/fixtures/transcript.jsonl').readAsStringSync();
    final items = ClaudeSessionIndex.parseTranscript(jsonl);

    final users = items.whereType<UserItem>().toList();
    // Human prompts only: the task-notification line and the meta
    // "[Image: ...]" line must not show up as prompts.
    expect(users, hasLength(2));
    expect(users.first.text, startsWith('我现在想做一个'));
    expect(users.every((u) => !u.text.contains('<task-notification>')), isTrue);

    final tools = items.whereType<ToolCallItem>().toList();
    expect(tools, hasLength(1));
    expect(tools.single.call.name, 'Bash');
    expect(tools.single.result, isNotNull);
    expect(tools.single.result!.content, contains('total 8'));

    expect(items.whereType<AssistantTextItem>(), isNotEmpty);
    expect(items.first, isA<UserItem>());
  });

  test('session listing prefers ai-title and hides sdk sessions', () {
    const listing = '''
@@FILE aaaa-1 1700000000 1000
{"type":"ai-title","aiTitle":"轻量级云端IDE与Claude集成"}
{"type":"summary","summary":"old summary"}
{"type":"user","entrypoint":"claude-vscode","message":{"role":"user","content":[{"type":"text","text":"hello"}]}}
@@FILE bbbb-2 1700000100 2000

{"type":"summary","summary":"A summary title"}
{"type":"user","entrypoint":"cli","message":{"role":"user","content":"typed in terminal"}}
@@FILE cccc-3 1700000200 3000


{"type":"user","entrypoint":"sdk-cli","message":{"role":"user","content":"Reply with PONG"}}
@@FILE dddd-4 1700000300 4000


{"type":"user","entrypoint":"cli","message":{"role":"user","content":[{"type":"text","text":"<command-name>/clear</command-name> then real text"}]}}
''';
    final list = ClaudeSessionIndex.parseListing(listing);
    expect(list.map((s) => s.id), ['aaaa-1', 'bbbb-2', 'dddd-4']);
    expect(list[0].title, '轻量级云端IDE与Claude集成');
    expect(list[1].title, 'A summary title');
    expect(list[2].title, 'then real text');
    expect(list[0].sizeBytes, 1000);
  });
}
