import 'dart:io';

import 'package:codeapp/core/claude/claude_chat.dart';
import 'package:codeapp/core/claude/claude_protocol.dart';
import 'package:codeapp/core/claude/session_index.dart';
import 'package:codeapp/core/models/host.dart';
import 'package:codeapp/core/ssh/ssh_connection.dart';
import 'package:flutter_test/flutter_test.dart';

ClaudeChat _chat() => ClaudeChat(
      SshConnection(HostConfig(id: 'x', host: 'h', username: 'u')),
      '/home/u/project',
    );

List<String> _lines(String name) =>
    File('test/fixtures/$name').readAsLinesSync().where((l) => l.trim().isNotEmpty).toList();

void main() {
  test('parses a Bash tool call turn recorded from claude 2.1', () {
    final chat = _chat();
    for (final l in _lines('stream_bash.jsonl')) {
      chat.handleLine(l);
    }
    expect(chat.sessionId, '2509f0b1-0c7d-4d5b-aa7f-536046947e35');
    expect(chat.model, isNotNull);

    final tools = chat.items.whereType<ToolCallItem>().toList();
    expect(tools, hasLength(1));
    expect(tools.single.call.name, 'Bash');
    expect(tools.single.call.input['command'], 'echo hello-from-test');
    expect(tools.single.result?.content, 'hello-from-test');
    expect(tools.single.result?.isError, isFalse);

    final texts = chat.items.whereType<AssistantTextItem>().toList();
    expect(texts.last.text, 'hello-from-test');
    expect(texts.last.streaming, isFalse);

    final result = chat.items.whereType<ResultItem>().single;
    expect(result.isError, isFalse);
    expect(result.numTurns, 2);
    expect(chat.busy, isFalse);
  });

  test('surfaces control_request as a pending permission on the tool call', () {
    final chat = _chat();
    final lines = _lines('stream_permission.jsonl');
    // Feed up to and including the first control_request.
    final idx = lines.indexWhere((l) => l.contains('"control_request"'));
    for (final l in lines.take(idx + 1)) {
      chat.handleLine(l);
    }
    final pending = chat.items.whereType<ToolCallItem>().where((t) => t.pendingPermission != null).toList();
    expect(pending, hasLength(1));
    expect(pending.single.call.name, 'Write');
    expect(pending.single.pendingPermission!.requestId, '0489f582-461e-4c88-a9cc-3cfda3c082af');
    expect(pending.single.pendingPermission!.input['file_path'], endsWith('probe.txt'));
    expect(chat.pendingPermissionCount, 1);
  });

  test('encodes the project dir the way Claude Code does', () {
    expect(ClaudeSessionIndex.encodeProjectDir('/home/shifu/codeapp'), '-home-shifu-codeapp');
    expect(ClaudeSessionIndex.encodeProjectDir('/home/a/.config/x_y'), '-home-a--config-x-y');
  });

  test('parses host entry text like VS Code', () {
    final a = HostConfig.parse('shifu@1.2.3.4', id: 'a')!;
    expect((a.username, a.host, a.port), ('shifu', '1.2.3.4', 22));
    final b = HostConfig.parse('ssh -p 2222 root@example.com', id: 'b')!;
    expect((b.username, b.host, b.port), ('root', 'example.com', 2222));
    final c = HostConfig.parse('user@host:2200', id: 'c')!;
    expect((c.username, c.host, c.port), ('user', 'host', 2200));
    final d = HostConfig.parse('justhost', id: 'd')!;
    expect((d.username, d.host, d.port), ('', 'justhost', 22));
    expect(HostConfig.parse('   ', id: 'e'), isNull);
    expect(b.target, 'root@example.com:2222');
  });

  test('shell quoting', () {
    expect(shq("it's"), r"'it'\''s'");
    expect(shq('/a b'), "'/a b'");
  });
}
