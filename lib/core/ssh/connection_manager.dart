import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../models/host.dart';
import 'port_forwarder.dart';
import 'ssh_connection.dart';

/// A live connection to one host plus the things that belong to the host
/// rather than to a folder (port forwards).
class HostConnection {
  HostConnection(this.conn) : ports = PortForwarder(conn) {
    ports.startWatching();
  }
  final SshConnection conn;
  final PortForwarder ports;

  Future<void> dispose() async {
    ports.dispose();
    await conn.close();
    conn.dispose();
  }
}

/// Keeps connections alive across workspaces, like VS Code's Remote view:
/// a host stays "connected" until the user disconnects it.
class ConnectionManager extends ChangeNotifier {
  final Map<String, HostConnection> _live = {};

  /// The connection for a host, connected or not (a dropped one can be
  /// reconnected by whoever holds it).
  HostConnection? of(String hostId) => _live[hostId];

  bool isConnected(String hostId) => _live[hostId]?.conn.isConnected ?? false;

  void register(HostConfig host, SshConnection conn) {
    _live[host.id]?.dispose();
    final hc = HostConnection(conn);
    _live[host.id] = hc;
    conn.addListener(notifyListeners);
    notifyListeners();
  }

  Future<void> disconnect(String hostId) async {
    final c = _live.remove(hostId);
    notifyListeners();
    await c?.dispose();
  }
}

final connectionManagerProvider =
    ChangeNotifierProvider<ConnectionManager>((_) => ConnectionManager());
