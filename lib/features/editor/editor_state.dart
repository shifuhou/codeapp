import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:re_editor/re_editor.dart';

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

/// Open editor tabs backed by SFTP.
class EditorState extends ChangeNotifier {
  EditorState(this.conn);
  final SshConnection conn;

  final List<OpenFile> files = [];
  int activeIndex = -1;
  OpenFile? get active =>
      activeIndex >= 0 && activeIndex < files.length ? files[activeIndex] : null;

  static const maxOpenBytes = 4 * 1024 * 1024;

  Future<OpenFile> open(String path) async {
    final i = files.indexWhere((f) => f.path == path);
    if (i >= 0) {
      activeIndex = i;
      notifyListeners();
      return files[i];
    }
    final bytes = await conn.readFile(path);
    if (bytes.length > maxOpenBytes) {
      throw StateError('File is too large to open (${bytes.length} bytes)');
    }
    final text = utf8.decode(bytes, allowMalformed: true);
    final f = OpenFile(path: path, text: text);
    f.controller.addListener(notifyListeners);
    files.add(f);
    activeIndex = files.length - 1;
    notifyListeners();
    return f;
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
    final f = active;
    if (f != null) await save(f);
  }

  void close(OpenFile f) {
    final i = files.indexOf(f);
    if (i < 0) return;
    f.controller.removeListener(notifyListeners);
    files.removeAt(i);
    f.controller.dispose();
    if (activeIndex >= files.length) activeIndex = files.length - 1;
    notifyListeners();
  }

  void activate(int i) {
    activeIndex = i;
    notifyListeners();
  }

  @override
  void dispose() {
    for (final f in files) {
      f.controller.dispose();
    }
    super.dispose();
  }
}
