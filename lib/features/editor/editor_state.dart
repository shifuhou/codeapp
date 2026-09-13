import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:re_editor/re_editor.dart';

import '../../core/claude/claude_chat.dart';
import '../../core/ssh/ssh_connection.dart';

class OpenFile {
  OpenFile({required this.path, required String text})
      : controller = CodeLineEditingController.fromText(text),
        _savedText = text;

  final String path;
  final CodeLineEditingController controller;
  String _savedText;
  bool get dirty => controller.text != _savedText;
  String get name => path.split('/').last;
  bool saving = false;

  void markSaved() => _savedText = controller.text;
}

/// A tab in the editor area: a file or a Claude session, like VS Code where
/// Claude Code opens as an editor tab next to files.
sealed class WorkspaceTab {
  String get title;
}

class FileTab extends WorkspaceTab {
  FileTab(this.file);
  final OpenFile file;
  @override
  String get title => file.name;
}

class ClaudeTab extends WorkspaceTab {
  ClaudeTab(this.chat, {this.label});
  final ClaudeChat chat;
  String? label;
  @override
  String get title => label ?? (chat.sessionId == null ? 'Claude' : 'Claude ${chat.sessionId!.substring(0, 6)}');
}

/// A terminal running a command (e.g. the original Claude Code TUI). When
/// it closes, [linkedChat] resumes [resumeId] so the chat view continues
/// the same session.
class ShellTab extends WorkspaceTab {
  ShellTab({required this.title, required this.command, this.linkedChat, this.resumeId});
  @override
  final String title;
  final String command;
  final ClaudeChat? linkedChat;
  final String? resumeId;
}

/// Open tabs backed by SFTP (files) and Claude processes (chats).
class EditorState extends ChangeNotifier {
  EditorState(this.conn, this.workDir);
  final SshConnection conn;
  final String workDir;

  final List<WorkspaceTab> tabs = [];
  int activeIndex = -1;
  WorkspaceTab? get active =>
      activeIndex >= 0 && activeIndex < tabs.length ? tabs[activeIndex] : null;

  Iterable<OpenFile> get files => tabs.whereType<FileTab>().map((t) => t.file);
  Iterable<ClaudeChat> get chats => tabs.whereType<ClaudeTab>().map((t) => t.chat);
  OpenFile? get activeFile => switch (active) { FileTab t => t.file, _ => null };
  ClaudeChat? get activeChat => switch (active) { ClaudeTab t => t.chat, _ => null };

  static const maxOpenBytes = 4 * 1024 * 1024;

  Future<OpenFile> open(String path) async {
    final i = tabs.indexWhere((t) => t is FileTab && t.file.path == path);
    if (i >= 0) {
      activeIndex = i;
      notifyListeners();
      return (tabs[i] as FileTab).file;
    }
    final bytes = await conn.readFile(path);
    if (bytes.length > maxOpenBytes) {
      throw StateError('File is too large to open (${bytes.length} bytes)');
    }
    final text = utf8.decode(bytes, allowMalformed: true);
    final f = OpenFile(path: path, text: text);
    f.controller.addListener(notifyListeners);
    tabs.add(FileTab(f));
    activeIndex = tabs.length - 1;
    notifyListeners();
    return f;
  }

  /// Opens (or focuses) a Claude tab. With [sessionId] the stored session is
  /// resumed; without it a fresh session starts on first message.
  ClaudeChat openClaude({String? sessionId, String? label}) {
    if (sessionId != null) {
      final i = tabs.indexWhere((t) => t is ClaudeTab && t.chat.sessionId == sessionId);
      if (i >= 0) {
        activeIndex = i;
        notifyListeners();
        return (tabs[i] as ClaudeTab).chat;
      }
    }
    final chat = ClaudeChat(conn, workDir);
    chat.addListener(notifyListeners);
    tabs.add(ClaudeTab(chat, label: label));
    activeIndex = tabs.length - 1;
    if (sessionId != null) chat.start(resumeSessionId: sessionId);
    notifyListeners();
    return chat;
  }

  ShellTab openShell({required String title, required String command, ClaudeChat? linkedChat, String? resumeId}) {
    final t = ShellTab(title: title, command: command, linkedChat: linkedChat, resumeId: resumeId);
    tabs.add(t);
    activeIndex = tabs.length - 1;
    notifyListeners();
    return t;
  }

  /// The most recent Claude tab, creating one if there is none.
  ClaudeChat latestClaude() {
    final t = tabs.lastWhere((t) => t is ClaudeTab, orElse: () => ClaudeTab(openClaude()));
    return (t as ClaudeTab).chat;
  }

  Future<void> save(OpenFile f) async {
    if (f.saving) return;
    f.saving = true;
    notifyListeners();
    try {
      final data = Uint8List.fromList(utf8.encode(f.controller.text));
      await conn.writeFile(f.path, data);
      f.markSaved();
    } finally {
      f.saving = false;
      notifyListeners();
    }
  }

  Future<void> saveActive() async {
    final f = activeFile;
    if (f != null) await save(f);
  }

  /// Closes a tab. For a Claude tab, [keepRunning] leaves the process on
  /// the server (resume the session later to pick it up); otherwise the
  /// process is stopped.
  void close(WorkspaceTab tab, {bool keepRunning = false}) {
    final i = tabs.indexOf(tab);
    if (i < 0) return;
    tabs.removeAt(i);
    switch (tab) {
      case FileTab t:
        t.file.controller.removeListener(notifyListeners);
        t.file.controller.dispose();
      case ClaudeTab t:
        t.chat.removeListener(notifyListeners);
        if (keepRunning) {
          t.chat.detach().then((_) => t.chat.dispose());
        } else {
          t.chat.stop().then((_) => t.chat.dispose());
        }
      case ShellTab t:
        final chat = t.linkedChat;
        if (chat != null && t.resumeId != null && chats.contains(chat)) {
          chat.start(resumeSessionId: t.resumeId);
          final ci = tabs.indexWhere((x) => x is ClaudeTab && x.chat == chat);
          if (ci >= 0) activeIndex = ci;
        }
    }
    if (activeIndex >= tabs.length) activeIndex = tabs.length - 1;
    notifyListeners();
  }

  void activate(int i) {
    activeIndex = i;
    notifyListeners();
  }

  @override
  void dispose() {
    for (final t in tabs) {
      switch (t) {
        case FileTab f:
          f.file.controller.dispose();
        case ClaudeTab c:
          // Leaving the workspace keeps processes running on the server.
          c.chat.dispose();
        case ShellTab():
          break;
      }
    }
    super.dispose();
  }
}
