import 'dart:convert';

enum AuthType { password, key }

/// A saved SSH host. Secrets (password, private key, passphrase) are NOT
/// stored here; they live in the platform secure storage keyed by [id].
class HostConfig {
  HostConfig({
    required this.id,
    required this.name,
    required this.host,
    this.port = 22,
    required this.username,
    this.authType = AuthType.key,
    this.remoteDir = '',
    this.claudeCommand = 'claude',
    this.autoForwardPorts = true,
  });

  final String id;
  String name;
  String host;
  int port;
  String username;
  AuthType authType;

  /// Working directory on the remote for files, terminal and Claude.
  /// Empty means the user's home directory.
  String remoteDir;

  /// Command used to launch Claude Code on the remote (usually `claude`).
  String claudeCommand;

  bool autoForwardPorts;

  String get label => name.isEmpty ? '$username@$host' : name;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'port': port,
        'username': username,
        'authType': authType.name,
        'remoteDir': remoteDir,
        'claudeCommand': claudeCommand,
        'autoForwardPorts': autoForwardPorts,
      };

  static HostConfig fromJson(Map<String, dynamic> j) => HostConfig(
        id: j['id'] as String,
        name: (j['name'] ?? '') as String,
        host: j['host'] as String,
        port: (j['port'] ?? 22) as int,
        username: j['username'] as String,
        authType: AuthType.values.firstWhere(
          (a) => a.name == j['authType'],
          orElse: () => AuthType.key,
        ),
        remoteDir: (j['remoteDir'] ?? '') as String,
        claudeCommand: (j['claudeCommand'] ?? 'claude') as String,
        autoForwardPorts: (j['autoForwardPorts'] ?? true) as bool,
      );

  HostConfig copy() => HostConfig.fromJson(jsonDecode(jsonEncode(toJson())));
}

/// Secrets for a host, loaded from secure storage just before connecting.
class HostSecrets {
  const HostSecrets({this.password, this.privateKey, this.passphrase});
  final String? password;
  final String? privateKey;
  final String? passphrase;
}
