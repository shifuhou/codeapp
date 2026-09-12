/// An SSH host, either saved by the user or read from ~/.ssh/config.
class HostConfig {
  HostConfig({
    required this.id,
    required this.host,
    this.port = 22,
    this.username = '',
    this.alias,
    this.identityFile,
    this.fromSshConfig = false,
    List<String>? recentDirs,
  }) : recentDirs = recentDirs ?? [];

  final String id;
  String host;
  int port;
  String username;

  /// `Host` alias from ~/.ssh/config, shown as the label when present.
  String? alias;

  /// `IdentityFile` from ~/.ssh/config (may contain ~).
  String? identityFile;
  final bool fromSshConfig;

  /// Folders opened on this host, most recent first.
  List<String> recentDirs;

  String get label => alias ?? (username.isEmpty ? host : '$username@$host');
  String get target =>
      '${username.isEmpty ? '' : '$username@'}$host${port == 22 ? '' : ':$port'}';

  Map<String, dynamic> toJson() => {
        'id': id,
        'host': host,
        'port': port,
        'username': username,
        if (alias != null) 'alias': alias,
        if (identityFile != null) 'identityFile': identityFile,
        'recentDirs': recentDirs,
      };

  static HostConfig fromJson(Map<String, dynamic> j) => HostConfig(
        id: j['id'] as String,
        host: j['host'] as String,
        port: (j['port'] ?? 22) as int,
        username: (j['username'] ?? '') as String,
        alias: j['alias'] as String?,
        identityFile: j['identityFile'] as String?,
        recentDirs: ((j['recentDirs'] ?? []) as List).cast<String>(),
      );

  /// Parses `user@host`, `user@host:2222` or `ssh -p 2222 user@host`.
  static HostConfig? parse(String input, {required String id}) {
    var s = input.trim();
    if (s.isEmpty) return null;
    int port = 22;
    final p = RegExp(r'(?:^|\s)-p\s*(\d+)').firstMatch(s);
    if (p != null) {
      port = int.parse(p.group(1)!);
      s = s.replaceFirst(p.group(0)!, ' ');
    }
    s = s.replaceFirst(RegExp(r'^ssh\s+'), '').trim();
    final parts = s.split(RegExp(r'\s+'));
    if (parts.isEmpty) return null;
    var target = parts.first;
    String user = '';
    final at = target.lastIndexOf('@');
    if (at >= 0) {
      user = target.substring(0, at);
      target = target.substring(at + 1);
    }
    final colon = target.lastIndexOf(':');
    if (colon >= 0 && !target.contains('[')) {
      port = int.tryParse(target.substring(colon + 1)) ?? port;
      target = target.substring(0, colon);
    }
    if (target.isEmpty) return null;
    return HostConfig(id: id, host: target, port: port, username: user);
  }
}
