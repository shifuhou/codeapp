import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'claude/claude_chat.dart';
import 'claude/session_index.dart';
import 'models/host.dart';
import 'ssh/connection_manager.dart';
import 'ssh/port_forwarder.dart';
import 'ssh/ssh_connection.dart';
import '../features/editor/editor_state.dart';

/// One open folder on one host: the second layer of the VS Code-style model
/// (host = connection, workspace = folder). The connection outlives it.
class WorkspaceSession {
  WorkspaceSession(this.hostConn, this.workDir)
      : claude = ClaudeChat(hostConn.conn, workDir),
        sessions = ClaudeSessionIndex(hostConn.conn, workDir),
        editor = EditorState(hostConn.conn);

  final HostConnection hostConn;
  final String workDir;
  final ClaudeChat claude;
  final ClaudeSessionIndex sessions;
  final EditorState editor;

  SshConnection get conn => hostConn.conn;
  PortForwarder get ports => hostConn.ports;
  HostConfig get host => conn.host;
  String get dirName => workDir.split('/').where((s) => s.isNotEmpty).lastOrNull ?? '/';

  Future<void> dispose() async {
    claude.dispose();
    editor.dispose();
  }
}

/// Overridden per workspace subtree with `ProviderScope(overrides: ...)`.
final workspaceProvider = Provider<WorkspaceSession>(
  (_) => throw UnimplementedError('workspaceProvider must be overridden'),
);
