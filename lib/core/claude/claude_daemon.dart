import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

import '../ssh/ssh_connection.dart';

/// A Claude Code process that lives on the server, not on the SSH
/// connection: started detached with its stdin on a FIFO and its stdout in
/// a log file, so the phone can lock, the SSH drop, and the process keeps
/// working. The app "attaches" by tailing the log and appending to the FIFO,
/// and can re-attach any time. Everything the app writes is also appended
/// to the log (via tee) so a replay of the log reconstructs the full state.
///
/// Layout on the remote: `~/.codeapp/sessions/<id>/` with
///   in.fifo   stdin of the process
///   out.log   stdout (stream-json) plus our own input lines, in order
///   err.log   stderr
///   pid       process-group leader
///   exit      exit code, written when the process ends
///   meta      key=value lines: workdir, hist_bytes, session
class ClaudeDaemon {
  ClaudeDaemon(this.conn, this.id);

  final SshConnection conn;

  /// Our own id for the daemon directory (not the Claude session id, which
  /// is only known after the process reports it).
  final String id;

  static String root(SshConnection c) => '${c.homeDir}/.codeapp/sessions';
  String get dir => '${root(conn)}/$id';

  /// Starts a detached process running [command] (a shell snippet, already
  /// quoted) in [workDir]. [histBytes] records how much of the session
  /// transcript existed before this process, so a later attach can load
  /// exactly that as history and replay the log for the rest.
  static Future<ClaudeDaemon> start(
    SshConnection conn, {
    required String id,
    required String workDir,
    required String command,
    required String env,
    int histBytes = 0,
  }) async {
    final d = ClaudeDaemon(conn, id);
    final dd = shq(d.dir);
    final script = '''
mkdir -p $dd
[ -p $dd/in.fifo ] || mkfifo $dd/in.fifo
: > $dd/out.log; : > $dd/err.log; rm -f $dd/exit
printf 'workdir=%s\\nhist_bytes=%s\\nstarted=%s\\n' ${shq(workDir)} $histBytes "\$(date +%s)" > $dd/meta
cd ${shq(workDir)} || exit 90
setsid nohup bash -c ${shq('exec 0<>$dd/in.fifo; $env $command >> $dd/out.log 2>> $dd/err.log; echo \$? > $dd/exit')} >/dev/null 2>&1 < /dev/null &
echo \$! > $dd/pid
echo started
''';
    final s = await conn.execIn(workDir, script);
    final out = await utf8.decodeStream(s.stdout.cast<List<int>>());
    if (!out.contains('started')) {
      throw StateError('Could not start Claude on the remote: ${out.trim()}');
    }
    return d;
  }

  /// Records the Claude session id once the process reported it, so the
  /// daemon can be found again by session.
  Future<void> setSession(String sessionId) =>
      conn.run('echo session=${shq(sessionId)} >> ${shq(dir)}/meta');

  Future<bool> isAlive() async {
    final out = await conn.run(
      'p=\$(cat ${shq(dir)}/pid 2>/dev/null) && [ -n "\$p" ] && kill -0 "\$p" 2>/dev/null && echo alive || echo dead',
    );
    return out.contains('alive');
  }

  Future<Map<String, String>> meta() async {
    final out = await conn.run('cat ${shq(dir)}/meta 2>/dev/null');
    final m = <String, String>{};
    for (final l in out.split('\n')) {
      final i = l.indexOf('=');
      if (i > 0) m[l.substring(0, i)] = l.substring(i + 1);
    }
    return m;
  }

  /// Follows out.log from the beginning. The caller parses lines; stopping
  /// means closing the returned session.
  Future<SSHSession> tail() =>
      conn.client.execute('tail -c +1 -F ${shq(dir)}/out.log 2>/dev/null');

  /// A channel whose stdin is appended to the log and fed to the process.
  Future<SSHSession> writer() =>
      conn.client.execute('tee -a ${shq(dir)}/out.log > ${shq(dir)}/in.fifo');

  /// Kills the process group and removes the directory.
  Future<void> kill() async {
    await conn.run(
      'p=\$(cat ${shq(dir)}/pid 2>/dev/null); [ -n "\$p" ] && kill -- -"\$p" 2>/dev/null; sleep 0.2; rm -rf ${shq(dir)}',
    );
  }

  /// Removes the directory of a finished process.
  Future<void> cleanup() => conn.run('rm -rf ${shq(dir)}');

  /// Live daemons keyed by Claude session id (only those that have reported
  /// one), for the given workspace folder.
  static Future<Map<String, String>> liveBySession(SshConnection conn, {String? workDir}) async {
    final r = shq(root(conn));
    final out = await conn.run('''
for d in $r/*/; do
  [ -f "\$d/pid" ] || continue
  p=\$(cat "\$d/pid"); kill -0 "\$p" 2>/dev/null || continue
  s=\$(sed -n 's/^session=//p' "\$d/meta" 2>/dev/null | tail -n1)
  w=\$(sed -n 's/^workdir=//p' "\$d/meta" 2>/dev/null | head -n1)
  [ -n "\$s" ] && echo "\$s \$(basename "\$d") \$w"
done 2>/dev/null
''');
    final m = <String, String>{};
    for (final l in out.split('\n')) {
      final parts = l.trim().split(' ');
      if (parts.length < 2) continue;
      if (workDir != null && parts.length > 2 && parts.sublist(2).join(' ') != workDir) continue;
      m[parts[0]] = parts[1];
    }
    return m;
  }

  /// Removes directories of dead processes older than a day.
  static Future<void> sweep(SshConnection conn) async {
    final r = shq(root(conn));
    await conn.run('''
for d in $r/*/; do
  [ -f "\$d/pid" ] || continue
  p=\$(cat "\$d/pid"); kill -0 "\$p" 2>/dev/null && continue
  find "\$d" -maxdepth 0 -mmin +1440 -exec rm -rf {} + 2>/dev/null
done 2>/dev/null; true
''');
  }
}
