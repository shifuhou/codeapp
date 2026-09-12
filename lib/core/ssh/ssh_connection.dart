import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../models/host.dart';

/// Called when the server presents a host key. Return true to trust it.
typedef HostKeyPrompt = Future<bool> Function(
  String keyType,
  String fingerprint,
  bool changed,
);

/// Shell prelude that makes user-installed tools visible in a non-interactive
/// shell. `bash -l` skips most of ~/.bashrc, which is where nvm and friends
/// usually live, so `claude` would otherwise be "not found".
const shellPrelude = r'''
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/npm-global/bin:$HOME/.npm/bin:$HOME/bin:$HOME/.claude/local:/usr/local/bin:/opt/homebrew/bin:$PATH"
[ -s "$HOME/.nvm/nvm.sh" ] && . "$HOME/.nvm/nvm.sh" >/dev/null 2>&1
for __d in "$HOME/.nvm/versions/node"/*/bin "$HOME/.volta/bin" "$HOME/.fnm/aliases/default/bin" "$HOME/.bun/bin"; do [ -d "$__d" ] && PATH="$__d:$PATH"; done
''';

/// Quote a string for POSIX sh single quotes.
String shq(String s) => "'${s.replaceAll("'", "'\\''")}'";

/// One authenticated SSH connection to a host. All features (terminal, files,
/// Claude, port forwarding) multiplex channels over this single connection.
class SshConnection extends ChangeNotifier {
  SshConnection(this.host);

  final HostConfig host;
  SSHClient? _client;
  SftpClient? _sftp;
  String? _homeDir;
  bool _closed = false;
  String? error;

  bool get isConnected => _client != null && !_closed;
  SSHClient get client {
    final c = _client;
    if (c == null || _closed) throw StateError('SSH not connected');
    return c;
  }

  /// Absolute working directory on the remote (host.remoteDir or $HOME).
  String get workDir {
    final d = host.remoteDir.trim();
    if (d.isEmpty) return _homeDir ?? '~';
    if (d.startsWith('~')) return (_homeDir ?? '~') + d.substring(1);
    return d;
  }

  String get homeDir => _homeDir ?? '~';

  Future<void> connect(
    HostSecrets secrets, {
    required HostKeyPrompt onHostKey,
    required String? knownFingerprint,
    required void Function(String fingerprint) onTrustHostKey,
  }) async {
    final socket = await SSHSocket.connect(
      host.host,
      host.port,
      timeout: const Duration(seconds: 20),
    );

    List<SSHKeyPair>? identities;
    if (host.authType == AuthType.key) {
      final pem = secrets.privateKey;
      if (pem == null || pem.trim().isEmpty) {
        throw StateError('No private key saved for this host');
      }
      identities = SSHKeyPair.fromPem(pem, secrets.passphrase);
    }

    final client = SSHClient(
      socket,
      username: host.username,
      identities: identities,
      onPasswordRequest: () => secrets.password ?? '',
      onVerifyHostKey: (type, fp) async {
        // dartssh2 hands us the OpenSSH-style "SHA256:<base64>" text as bytes.
        final text = utf8.decode(fp, allowMalformed: true);
        if (knownFingerprint == text) return true;
        final ok = await onHostKey(type, text, knownFingerprint != null);
        if (ok) onTrustHostKey(text);
        return ok;
      },
      keepAliveInterval: const Duration(seconds: 15),
    );
    _client = client;
    await client.authenticated;

    client.done.then((_) => _onClosed(null), onError: (Object e) => _onClosed(e));

    // Resolve $HOME so relative dirs and ~ work everywhere.
    try {
      _homeDir = (await run('printf %s "\$HOME"')).trim();
      if (_homeDir!.isEmpty) _homeDir = null;
    } catch (_) {}
    _notify();
  }

  void _onClosed(Object? e) {
    if (_closed) return;
    _closed = true;
    error = e?.toString();
    _sftp = null;
    _notify();
  }

  bool _disposed = false;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Run a command and return stdout as text.
  Future<String> run(String command, {Duration? timeout}) async {
    final f = client.run(command, stderr: false);
    final out = timeout == null ? await f : await f.timeout(timeout);
    return utf8.decode(out, allowMalformed: true);
  }

  /// Run a command in [workDir] through a login shell so PATH additions from
  /// ~/.profile / ~/.bashrc (nvm, npm-global, ...) are visible.
  Future<SSHSession> execInWorkDir(String command) {
    final script = '$shellPrelude\ncd ${shq(workDir)} 2>/dev/null; $command';
    return client.execute('bash -lc ${shq(script)}');
  }

  Future<SSHSession> shell({int width = 80, int height = 24}) async {
    return client.shell(
      pty: SSHPtyConfig(width: width, height: height, type: 'xterm-256color'),
    );
  }

  Future<SftpClient> sftp() async {
    final existing = _sftp;
    if (existing != null) return existing;
    final s = await client.sftp();
    _sftp = s;
    return s;
  }

  Future<Uint8List> readFile(String path) async {
    final s = await sftp();
    final f = await s.open(path);
    try {
      return await f.readBytes();
    } finally {
      await f.close();
    }
  }

  Future<void> writeFile(String path, Uint8List data) async {
    final s = await sftp();
    final f = await s.open(
      path,
      mode: SftpFileOpenMode.create |
          SftpFileOpenMode.truncate |
          SftpFileOpenMode.write,
    );
    try {
      await f.writeBytes(data);
    } finally {
      await f.close();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      _sftp?.close();
    } catch (_) {}
    try {
      _client?.close();
    } catch (_) {}
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    close();
    super.dispose();
  }
}
