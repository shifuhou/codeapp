import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../models/host.dart';

/// Called when the server presents a host key. Return true to trust it.
typedef HostKeyPrompt = Future<bool> Function(
  String keyType,
  String fingerprint,
  bool changed,
);

/// UI callbacks used during authentication. Like VS Code: system keys are
/// tried silently first; the user is only asked when needed.
class AuthPrompts {
  const AuthPrompts({
    required this.askPassword,
    required this.askPassphrase,
    required this.onHostKey,
  });

  /// Ask for a password (or a keyboard-interactive prompt). Null = cancel.
  final Future<String?> Function(String prompt) askPassword;

  /// Ask for the passphrase of an encrypted private key. Null = skip key.
  final Future<String?> Function(String keyName) askPassphrase;
  final HostKeyPrompt onHostKey;
}

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

class UserCancelled implements Exception {
  @override
  String toString() => 'Cancelled';
}

/// One authenticated SSH connection to a host. All features (terminal, files,
/// Claude, port forwarding) multiplex channels over this single connection.
class SshConnection extends ChangeNotifier {
  SshConnection(this.host);

  final HostConfig host;
  SSHClient? _client;
  SftpClient? _sftp;
  String? _homeDir;
  bool _closed = false;
  bool _disposed = false;
  String? error;

  bool get isConnected => _client != null && !_closed;
  SSHClient get client {
    final c = _client;
    if (c == null || _closed) throw StateError('SSH not connected');
    return c;
  }

  String get homeDir => _homeDir ?? '~';

  /// Expands a leading `~` using the remote home directory.
  String expand(String dir) {
    final d = dir.trim();
    if (d.isEmpty || d == '~') return homeDir;
    if (d.startsWith('~/')) return '$homeDir${d.substring(1)}';
    return d;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  // ---- key discovery -------------------------------------------------------

  /// Private key files to try: the host's IdentityFile (if any) followed by
  /// the standard ~/.ssh/id_* files. Empty on phones, which have no ~/.ssh.
  static List<File> candidateKeyFiles(HostConfig host) {
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    final files = <File>[];
    void add(String p) {
      if (home != null && p.startsWith('~')) p = home + p.substring(1);
      final f = File(p);
      if (f.existsSync() && !files.any((x) => x.path == f.path)) files.add(f);
    }

    if (host.identityFile != null) add(host.identityFile!);
    if (home != null) {
      for (final n in ['id_ed25519', 'id_ecdsa', 'id_rsa', 'id_dsa']) {
        add('$home/.ssh/$n');
      }
      final dir = Directory('$home/.ssh');
      if (dir.existsSync()) {
        for (final e in dir.listSync().whereType<File>()) {
          final n = e.uri.pathSegments.last;
          if (n.startsWith('id_') && !n.endsWith('.pub')) add(e.path);
        }
      }
    }
    return files;
  }

  Future<List<SSHKeyPair>> _loadKeys(AuthPrompts prompts) async {
    final pairs = <SSHKeyPair>[];
    for (final f in candidateKeyFiles(host)) {
      String pem;
      try {
        pem = await f.readAsString();
      } catch (_) {
        continue;
      }
      if (!pem.contains('PRIVATE KEY')) continue;
      try {
        pairs.addAll(SSHKeyPair.fromPem(pem));
        continue;
      } catch (_) {
        // Probably encrypted; ask for a passphrase.
      }
      if (!SSHKeyPair.isEncryptedPem(pem)) continue;
      final pass = await prompts.askPassphrase(f.uri.pathSegments.last);
      if (pass == null || pass.isEmpty) continue;
      try {
        pairs.addAll(SSHKeyPair.fromPem(pem, pass));
      } catch (_) {}
    }
    return pairs;
  }

  // ---- connect -------------------------------------------------------------

  Future<void> connect(
    AuthPrompts prompts, {
    required String? knownFingerprint,
    required void Function(String fingerprint) onTrustHostKey,
  }) async {
    final identities = await _loadKeys(prompts);
    final socket = await SSHSocket.connect(
      host.host,
      host.port,
      timeout: const Duration(seconds: 20),
    );

    var cancelled = false;
    final client = SSHClient(
      socket,
      username: host.username.isEmpty
          ? (Platform.environment['USER'] ?? Platform.environment['USERNAME'] ?? 'root')
          : host.username,
      identities: identities.isEmpty ? null : identities,
      onPasswordRequest: () async {
        final p = await prompts.askPassword('Password for ${host.label}');
        if (p == null) cancelled = true;
        return p;
      },
      onUserInfoRequest: (req) async {
        final answers = <String>[];
        for (final p in req.prompts) {
          final label = [req.name, req.instruction, p.promptText]
              .where((s) => s.trim().isNotEmpty)
              .join('\n');
          final a = await prompts.askPassword(label.isEmpty ? 'Password for ${host.label}' : label);
          if (a == null) {
            cancelled = true;
            return null;
          }
          answers.add(a);
        }
        return answers;
      },
      onVerifyHostKey: (type, fp) async {
        // dartssh2 hands us the OpenSSH-style "SHA256:<base64>" text as bytes.
        final text = utf8.decode(fp, allowMalformed: true);
        if (knownFingerprint == text) return true;
        final ok = await prompts.onHostKey(type, text, knownFingerprint != null);
        if (ok) onTrustHostKey(text);
        return ok;
      },
      keepAliveInterval: const Duration(seconds: 15),
    );
    _client = client;
    try {
      await client.authenticated;
    } catch (e) {
      _client = null;
      client.close();
      if (cancelled) throw UserCancelled();
      rethrow;
    }

    client.done.then((_) => _onClosed(null), onError: (Object e) => _onClosed(e));

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

  /// Run a command and return stdout as text.
  Future<String> run(String command, {Duration? timeout}) async {
    final f = client.run(command, stderr: false);
    final out = timeout == null ? await f : await f.timeout(timeout);
    return utf8.decode(out, allowMalformed: true);
  }

  /// Run a command in [dir] through a login shell plus [shellPrelude] so
  /// user-installed tools are on PATH.
  Future<SSHSession> execIn(String dir, String command) {
    final script = '$shellPrelude\ncd ${shq(dir)} 2>/dev/null; $command';
    return client.execute('bash -lc ${shq(script)}');
  }

  Future<SSHSession> shell({int width = 80, int height = 24}) {
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
    final f = await (await sftp()).open(path);
    try {
      return await f.readBytes();
    } finally {
      await f.close();
    }
  }

  Future<void> writeFile(String path, Uint8List data) async {
    final f = await (await sftp()).open(
      path,
      mode: SftpFileOpenMode.create | SftpFileOpenMode.truncate | SftpFileOpenMode.write,
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
