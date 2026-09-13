import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:re_editor/re_editor.dart';

import '../../app.dart';
import '../../core/workspace_session.dart';
import '../claude/claude_panel.dart';
import '../terminal/terminal_view.dart';
import '../workspace/context_menu.dart';
import 'editor_state.dart';
import 'languages.dart';

/// The editor group: a tab strip of files and Claude chats, plus the body of
/// the active tab.
class EditorView extends ConsumerWidget {
  const EditorView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final editor = ref.watch(workspaceProvider).editor;
    return ListenableBuilder(
      listenable: editor,
      builder: (context, _) {
        final tab = editor.active;
        return Column(
          children: [
            _TabStrip(editor: editor),
            const Divider(height: 1),
            Expanded(
              child: switch (tab) {
                FileTab t => _Editor(key: ValueKey('file:${t.file.path}'), file: t.file, editor: editor),
                ClaudeTab t => ClaudePanel(key: ValueKey('claude:${identityHashCode(t.chat)}'), chat: t.chat),
                ShellTab t => TerminalPane(key: ValueKey('shell:${identityHashCode(t)}'), initialCommand: t.command),
                null => _Empty(editor: editor),
              },
            ),
          ],
        );
      },
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.editor});
  final EditorState editor;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Open a file from the sidebar', style: TextStyle(color: AppColors.textDim)),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => editor.openClaude(),
            icon: const Icon(Icons.auto_awesome, size: 16),
            label: const Text('New Claude session'),
          ),
        ],
      ),
    );
  }
}

class _TabStrip extends StatelessWidget {
  const _TabStrip({required this.editor});
  final EditorState editor;

  @override
  Widget build(BuildContext context) {
    final f = editor.activeFile;
    return Material(
      color: AppColors.panel,
      child: SizedBox(
        height: 36,
        child: Row(
          children: [
            Expanded(
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: editor.tabs.length,
                itemBuilder: (context, i) {
                  final tab = editor.tabs[i];
                  final active = i == editor.activeIndex;
                  final dirty = tab is FileTab && tab.file.dirty;
                  final busy = tab is ClaudeTab && tab.chat.busy;
                  final needsAttention = tab is ClaudeTab && tab.chat.pendingPermissionCount > 0;
                  return ContextMenuRegion(
                    longPress: false,
                    actions: () => _tabMenu(context, tab),
                    child: InkWell(
                    onTap: () => editor.activate(i),
                    child: Container(
                      padding: const EdgeInsets.only(left: 10, right: 2),
                      decoration: BoxDecoration(
                        color: active ? AppColors.bg : Colors.transparent,
                        border: Border(
                          top: BorderSide(color: active ? AppColors.accent : Colors.transparent, width: 1.5),
                          right: const BorderSide(color: AppColors.border),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            switch (tab) {
                              ClaudeTab() => Icons.auto_awesome,
                              ShellTab() => Icons.terminal,
                              FileTab() => Icons.insert_drive_file_outlined,
                            },
                            size: 13,
                            color: tab is ClaudeTab ? AppColors.accent : AppColors.textDim,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            tab.title,
                            style: TextStyle(
                              fontSize: 12,
                              color: active ? AppColors.text : AppColors.textDim,
                              fontStyle: dirty ? FontStyle.italic : null,
                            ),
                          ),
                          if (busy)
                            const Padding(
                              padding: EdgeInsets.only(left: 6),
                              child: SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.5)),
                            ),
                          if (needsAttention)
                            const Padding(
                              padding: EdgeInsets.only(left: 6),
                              child: Icon(Icons.help_outline, size: 13, color: AppColors.warn),
                            ),
                          IconButton(
                            iconSize: 14,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                            icon: Icon(dirty ? Icons.circle : Icons.close, size: dirty ? 9 : 14),
                            onPressed: () => _close(context, tab),
                          ),
                        ],
                      ),
                    ),
                  ),
                  );
                },
              ),
            ),
            IconButton(
              tooltip: 'New Claude session',
              iconSize: 18,
              icon: const Icon(Icons.add_comment_outlined, color: AppColors.textDim),
              onPressed: () => editor.openClaude(),
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

  List<MenuAction> _tabMenu(BuildContext context, WorkspaceTab tab) {
    final others = editor.tabs.where((t) => t != tab).toList();
    return [
      MenuAction('Close', () => _close(context, tab), icon: Icons.close, shortcut: 'Ctrl+W'),
      MenuAction('Close others', () { for (final t in others) { _close(context, t); } }, enabled: others.isNotEmpty),
      MenuAction('Close all', () { for (final t in editor.tabs.toList()) { _close(context, t); } }),
      MenuAction('Close saved', () {
        for (final t in editor.tabs.toList()) {
          if (t is FileTab && !t.file.dirty) editor.close(t);
        }
      }),
      if (tab is FileTab) ...[
        menuDivider,
        MenuAction('Copy path', () => Clipboard.setData(ClipboardData(text: tab.file.path)), icon: Icons.copy),
        MenuAction('Save', () => _save(context, tab.file), icon: Icons.save_outlined, shortcut: 'Ctrl+S', enabled: tab.file.dirty),
      ],
      if (tab is ClaudeTab) ...[
        menuDivider,
        MenuAction('Copy session id', () => Clipboard.setData(ClipboardData(text: tab.chat.sessionId ?? '')),
            icon: Icons.copy, enabled: tab.chat.sessionId != null),
      ],
    ];
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

  Future<void> _close(BuildContext context, WorkspaceTab tab) async {
    if (tab is FileTab && tab.file.dirty) {
      final r = await showDialog<String>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text('Save changes to ${tab.file.name}?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, 'discard'), child: const Text("Don't save")),
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, 'save'), child: const Text('Save')),
          ],
        ),
      );
      if (r == null) return;
      if (r == 'save' && context.mounted) await _save(context, tab.file);
    }
    if (tab is ClaudeTab && tab.chat.busy) {
      if (!context.mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Claude is still working'),
          content: const Text('Closing the tab stops the current turn. The session can be resumed later.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Close')),
          ],
        ),
      );
      if (ok != true) return;
    }
    editor.close(tab);
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
        toolbarController: _EditorContextMenu(onSave: () => editor.save(file)),
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


/// Right-click / long-press menu inside the code editor.
class _EditorContextMenu implements SelectionToolbarController {
  const _EditorContextMenu({required this.onSave});
  final VoidCallback onSave;

  @override
  void hide(BuildContext context) {}

  @override
  void show({
    required BuildContext context,
    required CodeLineEditingController controller,
    required TextSelectionToolbarAnchors anchors,
    Rect? renderRect,
    required LayerLink layerLink,
    required ValueNotifier<bool> visibility,
  }) {
    final hasSelection = !controller.selection.isCollapsed;
    showContextMenu(context, anchors.primaryAnchor, [
      MenuAction('Cut', controller.cut, icon: Icons.content_cut, shortcut: 'Ctrl+X', enabled: hasSelection),
      MenuAction('Copy', controller.copy, icon: Icons.copy, shortcut: 'Ctrl+C', enabled: hasSelection),
      MenuAction('Paste', controller.paste, icon: Icons.paste, shortcut: 'Ctrl+V'),
      MenuAction('Select all', controller.selectAll, icon: Icons.select_all, shortcut: 'Ctrl+A'),
      menuDivider,
      MenuAction('Undo', controller.undo, icon: Icons.undo, shortcut: 'Ctrl+Z'),
      MenuAction('Redo', controller.redo, icon: Icons.redo, shortcut: 'Ctrl+Y'),
      menuDivider,
      MenuAction('Save', onSave, icon: Icons.save_outlined, shortcut: 'Ctrl+S'),
    ]);
  }
}
