// End-to-end test of the core layer against a real sshd on localhost.
// Runs only when LOCAL_SSH=1 (needs your own key in ~/.ssh/authorized_keys):
//   LOCAL_SSH=1 flutter test test/integration/local_ssh_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:codeapp/core/claude/claude_protocol.dart';
import 'package:codeapp/core/models/host.dart';
import 'package:codeapp/core/ssh/ssh_connection.dart';
import 'package:codeapp/core/workspace_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final enabled = Platform.environment['LOCAL_SSH'] == '1';
  final home = Platform.environment['HOME']!;
  final user = Platform.environment['USER'] ?? Platform.environment['LOGNAME']!;
  final keyPath = Platform.environment['LOCAL_SSH_KEY'] ?? '$home/.ssh/id_rsa';
  final workDir = Platform.environment['LOCAL_SSH_DIR'] ?? Directory.current.path;

  late WorkspaceSession ws;

  setUpAll(() async {
    if (!enabled) return;
    final host = HostConfig(
      id: 'local',
      name: 'local',
      host: '127.0.0.1',
      username: user,
      remoteDir: workDir,
    );
    final conn = SshConnection(host);
    await conn.connect(
      HostSecrets(privateKey: File(keyPath).readAsStringSync()),
      knownFingerprint: null,
      onTrustHostKey: (_) {},
      onHostKey: (type, fp, changed) async {
        stdout.writeln('host key $type $fp');
        return true;
      },
    );
    ws = WorkspaceSession(conn);
  });

  tearDownAll(() async {
    if (enabled) await ws.dispose();
  });

  test('connects, resolves home and workDir, runs commands', () async {
    final who = (await ws.conn.run('whoami')).trim();
    expect(who, user);
    expect(ws.conn.homeDir, home);
    expect(ws.conn.workDir, workDir);
    final s = await ws.conn.execInWorkDir('pwd');
    final out = utf8.decode(await s.stdout.fold<List<int>>([], (a, b) => a..addAll(b)));
    expect(out.trim(), workDir);
  }, skip: !enabled);

  test('sftp read/write round trip', () async {
    final path = '$workDir/.codeapp_sftp_test.txt';
    final data = 'hello ${DateTime.now()}\n';
    await ws.conn.writeFile(path, utf8.encode(data));
    final back = utf8.decode(await ws.conn.readFile(path));
    expect(back, data);
    final f = await ws.editor.open(path);
    expect(f.controller.text, data);
    f.controller.text = '$data second line\n';
    expect(f.dirty, isTrue);
    await ws.editor.save(f);
    expect(f.dirty, isFalse);
    expect(utf8.decode(await ws.conn.readFile(path)), '$data second line\n');
    await (await ws.conn.sftp()).remove(path);
  }, skip: !enabled);

  test('lists Claude sessions for the folder', () async {
    final list = await ws.sessions.list();
    stdout.writeln('sessions: ${list.length}');
    for (final s in list.take(3)) {
      stdout.writeln('  ${s.id.substring(0, 8)} ${s.modified} ${s.title}');
    }
    expect(list, isNotEmpty);
    expect(list.first.title, isNotEmpty);
  }, skip: !enabled);

  test('detects a listening port and forwards traffic through SSH', () async {
    // "Remote" HTTP server (it is localhost, but traffic still goes through
    // the SSH direct-tcpip channel, which is what we want to verify).
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) {
      req.response
        ..write('pong from ${server.port}')
        ..close();
    });
    try {
      final ports = await ws.ports.listListeningPorts();
      expect(ports.keys, contains(server.port));

      final fp = await ws.ports.forward(server.port, localPort: 0);
      expect(fp.localPort, isNot(server.port));
      final client = HttpClient();
      final req = await client.getUrl(Uri.parse('${fp.localUrl}/'));
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      expect(body, 'pong from ${server.port}');
      client.close();
      await ws.ports.stop(server.port);
      expect(ws.ports.forwards, isEmpty);
    } finally {
      await server.close();
    }
  }, skip: !enabled);

  test('runs Claude Code headless and gets a reply', () async {
    final chat = ws.claude;
    chat.modelOverride = 'claude-haiku-4-5-20251001';
    final done = Completer<void>();
    chat.addListener(() {
      if (!chat.busy && chat.items.whereType<ResultItem>().isNotEmpty && !done.isCompleted) {
        done.complete();
      }
      if (chat.lastError != null && !done.isCompleted) done.complete();
    });
    await chat.send('Reply with exactly the single word PONG and nothing else. Do not use any tools.');
    await done.future.timeout(const Duration(seconds: 120));
    for (final it in chat.items) {
      stdout.writeln('  ${it.runtimeType}: ${switch (it) {
        AssistantTextItem a => a.text,
        SystemNoteItem s => s.text,
        UserItem u => u.text,
        ResultItem r => 'error=${r.isError} turns=${r.numTurns}',
        _ => '',
      }}');
    }
    expect(chat.lastError, isNull);
    expect(chat.sessionId, isNotNull);
    final texts = chat.items.whereType<AssistantTextItem>().map((t) => t.text).join();
    expect(texts.toUpperCase(), contains('PONG'));
    expect(chat.items.whereType<ResultItem>().single.isError, isFalse);

    // The process should still be alive for a second turn.
    expect(chat.isRunning, isTrue);
    await chat.stop();
  }, skip: !enabled);
}
