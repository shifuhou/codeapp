import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'ssh_connection.dart';

class ForwardedPort {
  ForwardedPort({
    required this.remotePort,
    required this.localPort,
    required this.server,
  });
  final int remotePort;
  final int localPort;
  final ServerSocket server;
  int connections = 0;

  String get localUrl => 'http://127.0.0.1:$localPort';
}

class DetectedPort {
  DetectedPort(this.port, this.process);
  final int port;
  final String process;
}

/// Local port forwarding (like `ssh -L`) plus auto-detection of new listening
/// ports on the remote, the way VS Code Remote does it.
class PortForwarder extends ChangeNotifier {
  PortForwarder(this.conn);

  final SshConnection conn;
  final Map<int, ForwardedPort> forwards = {};
  final Map<int, DetectedPort> detected = {};
  final Set<int> _seen = {};
  final Set<int> ignored = {};
  Timer? _timer;
  bool autoForward = true;
  bool _polling = false;
  bool _disposed = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Fired with a remote port that was just auto-forwarded.
  final newForwardEvents = StreamController<ForwardedPort>.broadcast();

  static const _ignoredPorts = {22, 53, 111, 631, 25, 5353, 68, 67};

  void setAutoForward(bool v) {
    autoForward = v;
    _notify();
  }

  void startWatching({Duration every = const Duration(seconds: 4)}) {
    _timer?.cancel();
    _timer = Timer.periodic(every, (_) => _poll());
    _poll(initial: true);
  }

  void stopWatching() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _poll({bool initial = false}) async {
    if (_polling || !conn.isConnected) return;
    _polling = true;
    try {
      final ports = await _listListeningPorts();
      final now = ports.keys.toSet();
      detected
        ..clear()
        ..addAll(ports);
      for (final p in now) {
        final isNew = !_seen.contains(p);
        _seen.add(p);
        if (initial || !isNew) continue;
        if (autoForward && !ignored.contains(p) && !forwards.containsKey(p)) {
          try {
            final fp = await forward(p);
            newForwardEvents.add(fp);
          } catch (_) {}
        }
      }
      _seen.removeWhere((p) => !now.contains(p));
      _notify();
    } catch (_) {
      // Connection hiccup; try again next tick.
    } finally {
      _polling = false;
    }
  }

  @visibleForTesting
  Future<Map<int, DetectedPort>> listListeningPorts() => _listListeningPorts();

  /// Reads /proc/net/tcp{,6} which exists on every Linux box (no `ss` or
  /// `netstat` needed). State 0A == LISTEN.
  Future<Map<int, DetectedPort>> _listListeningPorts() async {
    final out = await conn.run(
      'cat /proc/net/tcp /proc/net/tcp6 2>/dev/null; '
      'echo __PROCS__; '
      '(ss -Hltnp 2>/dev/null || true)',
      timeout: const Duration(seconds: 8),
    );
    final result = <int, DetectedPort>{};
    final parts = out.split('__PROCS__');
    for (final line in parts.first.split('\n')) {
      final cols = line.trim().split(RegExp(r'\s+'));
      if (cols.length < 4 || cols[3] != '0A') continue;
      final local = cols[1];
      final idx = local.lastIndexOf(':');
      if (idx < 0) continue;
      final port = int.tryParse(local.substring(idx + 1), radix: 16);
      if (port == null || _ignoredPorts.contains(port)) continue;
      // Skip ports bound to loopback only? No: those are exactly the dev
      // servers we want to forward, so keep everything.
      result[port] = DetectedPort(port, '');
    }
    if (parts.length > 1) {
      for (final line in parts[1].split('\n')) {
        final m = RegExp(r':(\d+)\s.*users:\(\("([^"]+)"').firstMatch(line);
        if (m == null) continue;
        final port = int.tryParse(m.group(1)!);
        if (port != null && result.containsKey(port)) {
          result[port] = DetectedPort(port, m.group(2)!);
        }
      }
    }
    return result;
  }

  Future<ForwardedPort> forward(int remotePort, {int? localPort}) async {
    final existing = forwards[remotePort];
    if (existing != null) return existing;
    ServerSocket server;
    try {
      server = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        localPort ?? remotePort,
      );
    } on SocketException {
      // Local port busy: pick any free port.
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    }
    final fp = ForwardedPort(
      remotePort: remotePort,
      localPort: server.port,
      server: server,
    );
    forwards[remotePort] = fp;
    server.listen((socket) async {
      fp.connections++;
      _notify();
      try {
        final ch = await conn.client.forwardLocal('127.0.0.1', remotePort);
        unawaited(socket.addStream(ch.stream).catchError((_) {}));
        unawaited(ch.sink.addStream(socket).catchError((_) {}));
        await Future.any([ch.done, socket.done]).catchError((_) {});
        await ch.close().catchError((_) {});
      } catch (_) {
      } finally {
        try {
          socket.destroy();
        } catch (_) {}
        fp.connections--;
        _notify();
      }
    }, onError: (_) {});
    _notify();
    return fp;
  }

  Future<void> stop(int remotePort) async {
    final fp = forwards.remove(remotePort);
    if (fp == null) return;
    await fp.server.close();
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    stopWatching();
    for (final fp in forwards.values) {
      fp.server.close();
    }
    forwards.clear();
    newForwardEvents.close();
    super.dispose();
  }
}
