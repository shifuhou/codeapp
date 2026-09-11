import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:re_editor/re_editor.dart';

import '../../app.dart';
import '../../core/workspace_session.dart';
import 'editor_state.dart';
import 'languages.dart';

class EditorView extends ConsumerWidget {
  const EditorView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final editor = ref.watch(workspaceProvider).editor;
    return ListenableBuilder(
      listenable: editor,
      builder: (context, _) {
        final f = editor.active;
        return Column(
          children: [
            _TabBar(editor: editor),
            const Divider(height: 1),
            Expanded(
              child: f == null
                  ? const Center(child: Text('Open a file from the Files tab', style: TextStyle(color: AppColors.textDim)))
                  : _Editor(key: ValueKey(f.path), file: f, editor: editor),
            ),
          ],
        );
      },
    );
  }
}

class _TabBar extends StatelessWidget {
  const _TabBar({required this.editor});
  final EditorState editor;

  @override
  Widget build(BuildContext context) {
    final f = editor.active;
    return Material(
      color: AppColors.panel,
      child: SizedBox(
        height: 36,
        child: Row(
          children: [
            Expanded(
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: editor.files.length,
                itemBuilder: (context, i) {
                  final file = editor.files[i];
                  final active = i == editor.activeIndex;
                  return InkWell(
                    onTap: () => editor.activate(i),
                    child: Container(
                      padding: const EdgeInsets.only(left: 12, right: 4),
                      color: active ? AppColors.bg : Colors.transparent,
                      child: Row(
                        children: [
                          Text(
                            file.name,
                            style: TextStyle(
                              fontSize: 12,
                              color: active ? AppColors.text : AppColors.textDim,
                              fontStyle: file.dirty ? FontStyle.italic : null,
                            ),
                          ),
                          IconButton(
                            iconSize: 14,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                            icon: Icon(file.dirty ? Icons.circle : Icons.close, size: file.dirty ? 9 : 14),
                            onPressed: () => _close(context, file),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            if (f != null)
              IconButton(
                tooltip: 'Save (Ctrl/Cmd+S)',
                iconSize: 18,
                icon: f.saving
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(Icons.save_outlined, color: f.dirty ? AppColors.accent : AppColors.textDim),
                onPressed: f.dirty && !f.saving ? () => _save(context, f) : null,
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _save(BuildContext context, OpenFile f) async {
    try {
      await editor.save(f);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Save failed: $e'), backgroundColor: AppColors.err));
      }
    }
  }

  Future<void> _close(BuildContext context, OpenFile f) async {
    if (f.dirty) {
      final r = await showDialog<String>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text('Save changes to ${f.name}?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, 'discard'), child: const Text("Don't save")),
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, 'save'), child: const Text('Save')),
          ],
        ),
      );
      if (r == null) return;
      if (r == 'save' && context.mounted) await _save(context, f);
    }
    editor.close(f);
  }
}

class _Editor extends StatelessWidget {
  const _Editor({super.key, required this.file, required this.editor});
  final OpenFile file;
  final EditorState editor;

  @override
  Widget build(BuildContext context) {
    final theme = highlightThemeFor(file.name);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): () => editor.save(file),
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): () => editor.save(file),
      },
      child: CodeEditor(
        controller: file.controller,
        wordWrap: false,
        style: CodeEditorStyle(
          fontSize: 13,
          fontFamily: monoFamilies.first,
          fontFamilyFallback: monoFamilies,
          backgroundColor: AppColors.bg,
          textColor: AppColors.text,
          cursorColor: AppColors.accent,
          cursorLineColor: const Color(0xFF282828),
          selectionColor: AppColors.accentDim,
          codeTheme: theme,
        ),
        indicatorBuilder: (context, editingController, chunkController, notifier) {
          return Row(
            children: [
              DefaultCodeLineNumber(
                controller: editingController,
                notifier: notifier,
                textStyle: const TextStyle(fontSize: 12, color: AppColors.textDim),
              ),
              DefaultCodeChunkIndicator(width: 16, controller: chunkController, notifier: notifier),
            ],
          );
        },
      ),
    );
  }
}
