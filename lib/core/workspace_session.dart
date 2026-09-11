import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'claude/claude_chat.dart';
import 'claude/session_index.dart';
import 'models/host.dart';
import 'ssh/port_forwarder.dart';
import 'ssh/ssh_connection.dart';
import '../features/editor/editor_state.dart';

/// Everything that lives for the duration of one open workspace (one host).
class WorkspaceSession {
  WorkspaceSession(this.conn)
      : ports = PortForwarder(conn),
        claude = ClaudeChat(conn),
        sessions = ClaudeSessionIndex(conn),
        editor = EditorState(conn) {
    ports.autoForward = conn.host.autoForwardPorts;
  }

  final SshConnection conn;
  final PortForwarder ports;
  final ClaudeChat claude;
  final ClaudeSessionIndex sessions;
  final EditorState editor;

  HostConfig get host => conn.host;

  Future<void> dispose() async {
    ports.dispose();
    claude.dispose();
    editor.dispose();
    await conn.close();
  }
}

/// Overridden per workspace subtree with `ProviderScope(overrides: ...)`.
final workspaceProvider = Provider<WorkspaceSession>(
  (_) => throw UnimplementedError('workspaceProvider must be overridden'),
);
