import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markdown_widget/markdown_widget.dart';

import '../../app.dart';
import '../../core/claude/claude_chat.dart';
import '../../core/claude/claude_protocol.dart';
import '../../core/claude/session_index.dart';
import '../../core/workspace_session.dart';

class ClaudePanel extends ConsumerStatefulWidget {
  const ClaudePanel({super.key});

  @override
  ConsumerState<ClaudePanel> createState() => _ClaudePanelState();
}

class _ClaudePanelState extends ConsumerState<ClaudePanel> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  int _lastCount = 0;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    ref.read(workspaceProvider).claude.send(text);
    _focus.requestFocus();
  }

  void _autoScroll(ClaudeChat chat) {
    if (chat.items.length != _lastCount || chat.busy) {
      _lastCount = chat.items.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scroll.hasClients) return;
        final max = _scroll.position.maxScrollExtent;
        if (max - _scroll.offset < 400) _scroll.jumpTo(max);
      });
    }
  }

  Future<void> _pickSession() async {
    final ws = ref.read(workspaceProvider);
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.75,
        child: ProviderScope(
          overrides: [workspaceProvider.overrideWithValue(ws)],
          child: const ClaudeSessionList(pickMode: true),
        ),
      ),
    );
    if (picked == null) return;
    if (picked == '__new__') {
      ws.claude.start();
    } else {
      ws.claude.start(resumeSessionId: picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ws = ref.watch(workspaceProvider);
    final chat = ws.claude;
    return ListenableBuilder(
      listenable: chat,
      builder: (context, _) {
        _autoScroll(chat);
        return Column(
          children: [
            _toolbar(chat),
            const Divider(height: 1),
            Expanded(
              child: chat.items.isEmpty
                  ? _emptyState(chat)
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
                      itemCount: chat.items.length,
                      itemBuilder: (context, i) => _ItemView(item: chat.items[i], chat: chat),
                    ),
            ),
            if (chat.busy) const LinearProgressIndicator(minHeight: 2),
            _inputBar(chat),
          ],
        );
      },
    );
  }

  Widget _toolbar(ClaudeChat chat) {
    return Material(
      color: AppColors.panel,
      child: SizedBox(
        height: 40,
        child: Row(
          children: [
            const SizedBox(width: 8),
            const Icon(Icons.auto_awesome, size: 16, color: AppColors.accent),
            const SizedBox(width: 8),
            Expanded(
              child: InkWell(
                onTap: _pickSession,
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        chat.sessionId == null ? 'New session' : 'Session ${chat.sessionId!.substring(0, 8)}',
                        style: const TextStyle(fontSize: 13),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const Icon(Icons.arrow_drop_down, size: 18),
                    if (chat.model != null)
                      Flexible(
                        child: Text(chat.model!, style: const TextStyle(fontSize: 11, color: AppColors.textDim), overflow: TextOverflow.ellipsis),
                      ),
                  ],
                ),
              ),
            ),
            PopupMenuButton<PermissionMode>(
              tooltip: 'Permission mode',
              icon: Icon(
                switch (chat.permissionMode) {
                  PermissionMode.normal => Icons.shield_outlined,
                  PermissionMode.acceptEdits => Icons.edit_outlined,
                  PermissionMode.plan => Icons.map_outlined,
                  PermissionMode.bypassPermissions => Icons.bolt,
                },
                size: 18,
                color: chat.permissionMode == PermissionMode.bypassPermissions ? AppColors.warn : AppColors.text,
              ),
              initialValue: chat.permissionMode,
              onSelected: chat.setPermissionMode,
              itemBuilder: (_) => [
                for (final m in PermissionMode.values)
                  PopupMenuItem(value: m, child: Text(m.label)),
              ],
            ),
            IconButton(
              tooltip: 'New session',
              icon: const Icon(Icons.add_comment_outlined, size: 18),
              onPressed: () => chat.start(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyState(ClaudeChat chat) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.auto_awesome, size: 40, color: AppColors.textDim),
            const SizedBox(height: 12),
            Text(
              'Claude Code in ${ref.read(workspaceProvider).conn.workDir}',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textDim),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _pickSession,
              icon: const Icon(Icons.history, size: 16),
              label: const Text('Resume a session'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _inputBar(ClaudeChat chat) {
    return Container(
      color: AppColors.panel,
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      child: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.enter): _send,
                  const SingleActivator(LogicalKeyboardKey.numpadEnter): _send,
                },
                child: TextField(
                  controller: _input,
                  focusNode: _focus,
                  minLines: 1,
                  maxLines: 6,
                  textInputAction: TextInputAction.newline,
                  style: const TextStyle(fontSize: 14),
                  decoration: const InputDecoration(
                    hintText: 'Ask Claude… (Shift+Enter for newline)',
                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            if (chat.busy)
              IconButton.filledTonal(
                tooltip: 'Stop',
                icon: const Icon(Icons.stop),
                onPressed: chat.interrupt,
              )
            else
              IconButton.filled(
                tooltip: 'Send',
                icon: const Icon(Icons.arrow_upward),
                onPressed: _send,
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _ItemView extends StatelessWidget {
  const _ItemView({required this.item, required this.chat});
  final ChatItem item;
  final ClaudeChat chat;

  @override
  Widget build(BuildContext context) {
    return switch (item) {
      UserItem u => _bubble(
          align: Alignment.centerRight,
          color: AppColors.accentDim,
          child: SelectableText(u.text, style: const TextStyle(fontSize: 14)),
        ),
      AssistantTextItem a => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: _Markdown(a.text),
        ),
      ThinkingItem t => _Collapsible(
          icon: Icons.psychology_outlined,
          title: 'Thinking',
          child: Text(t.text, style: const TextStyle(fontSize: 12, color: AppColors.textDim, fontStyle: FontStyle.italic)),
        ),
      ToolCallItem t => _ToolCallView(item: t, chat: chat),
      SystemNoteItem s => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: SelectableText(s.text, style: TextStyle(fontSize: 12, color: s.isError ? AppColors.err : AppColors.textDim)),
        ),
      ResultItem r => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            '${r.isError ? 'Error' : 'Done'} • ${(r.durationMs / 1000).toStringAsFixed(1)}s'
            '${r.costUsd > 0 ? ' • \$${r.costUsd.toStringAsFixed(3)}' : ''}',
            style: TextStyle(fontSize: 11, color: r.isError ? AppColors.err : AppColors.textDim),
          ),
        ),
    };
  }

  Widget _bubble({required Alignment align, required Color color, required Widget child}) {
    return Align(
      alignment: align,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: const BoxConstraints(maxWidth: 520),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(10)),
        child: child,
      ),
    );
  }
}

class _Markdown extends StatelessWidget {
  const _Markdown(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return MarkdownBlock(
      data: text,
      selectable: true,
      config: MarkdownConfig.darkConfig.copy(configs: [
        const PConfig(textStyle: TextStyle(fontSize: 14, height: 1.45)),
        PreConfig.darkConfig.copy(
          textStyle: const TextStyle(fontSize: 12, fontFamily: 'JetBrains Mono', fontFamilyFallback: monoFamilies),
          decoration: BoxDecoration(color: AppColors.panelAlt, borderRadius: BorderRadius.circular(6)),
        ),
        CodeConfig(
          style: const TextStyle(fontSize: 13, fontFamily: 'JetBrains Mono', fontFamilyFallback: monoFamilies, backgroundColor: AppColors.panelAlt),
        ),
      ]),
    );
  }
}

class _Collapsible extends StatefulWidget {
  const _Collapsible({required this.icon, required this.title, required this.child, this.trailing, this.initiallyOpen = false});
  final IconData icon;
  final String title;
  final Widget child;
  final Widget? trailing;
  final bool initiallyOpen;

  @override
  State<_Collapsible> createState() => _CollapsibleState();
}

class _CollapsibleState extends State<_Collapsible> {
  late bool _open = widget.initiallyOpen;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.panel,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Row(
                children: [
                  Icon(widget.icon, size: 15, color: AppColors.textDim),
                  const SizedBox(width: 8),
                  Expanded(child: Text(widget.title, style: const TextStyle(fontSize: 12.5), overflow: TextOverflow.ellipsis)),
                  if (widget.trailing != null) widget.trailing!,
                  Icon(_open ? Icons.expand_less : Icons.expand_more, size: 16, color: AppColors.textDim),
                ],
              ),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: widget.child,
            ),
        ],
      ),
    );
  }
}

class _ToolCallView extends StatelessWidget {
  const _ToolCallView({required this.item, required this.chat});
  final ToolCallItem item;
  final ClaudeChat chat;

  String _summary() {
    final i = item.call.input;
    return switch (item.call.name) {
      'Bash' => i['description'] as String? ?? i['command'] as String? ?? '',
      'Read' || 'Write' || 'Edit' || 'MultiEdit' || 'NotebookEdit' => (i['file_path'] as String? ?? '').split('/').last,
      'Glob' || 'Grep' => i['pattern'] as String? ?? '',
      'WebFetch' => i['url'] as String? ?? '',
      'WebSearch' => i['query'] as String? ?? '',
      'Task' || 'Agent' => i['description'] as String? ?? '',
      _ => '',
    };
  }

  @override
  Widget build(BuildContext context) {
    final pending = item.pendingPermission;
    final res = item.result;
    final status = pending != null
        ? const Icon(Icons.help_outline, size: 15, color: AppColors.warn)
        : res == null
            ? (item.permissionDecision == 'deny'
                ? const Icon(Icons.block, size: 15, color: AppColors.err)
                : const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)))
            : Icon(res.isError ? Icons.error_outline : Icons.check, size: 15, color: res.isError ? AppColors.err : AppColors.ok);

    return _Collapsible(
      icon: Icons.build_outlined,
      title: '${item.call.name}  ${_summary()}',
      trailing: Padding(padding: const EdgeInsets.only(right: 6), child: status),
      initiallyOpen: pending != null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _code(_formatInput(item.call)),
          if (pending != null) ...[
            const SizedBox(height: 8),
            Text(
              'Claude wants to use ${pending.toolName}. Allow?',
              style: const TextStyle(fontSize: 12.5, color: AppColors.warn),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                FilledButton(
                  onPressed: () => chat.respondPermission(item, allow: true),
                  child: const Text('Allow'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () => chat.respondPermission(item, allow: false),
                  child: const Text('Deny'),
                ),
              ],
            ),
          ],
          if (res != null && res.content.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            _code(res.content.length > 3000 ? '${res.content.substring(0, 3000)}\n… (${res.content.length} chars)' : res.content,
                error: res.isError),
          ],
        ],
      ),
    );
  }

  static String _formatInput(ToolUseBlock call) {
    final i = call.input;
    switch (call.name) {
      case 'Bash':
        return i['command'] as String? ?? '';
      case 'Write':
        return '${i['file_path']}\n\n${i['content']}';
      case 'Edit':
        return '${i['file_path']}\n\n--- old\n${i['old_string']}\n+++ new\n${i['new_string']}';
      case 'Read':
        return '${i['file_path']}';
    }
    return const JsonEncoder.withIndent('  ').convert(i);
  }

  Widget _code(String text, {bool error = false}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: AppColors.bg, borderRadius: BorderRadius.circular(4)),
      child: SelectableText(
        text,
        style: TextStyle(
          fontSize: 11.5,
          fontFamily: 'JetBrains Mono',
          fontFamilyFallback: monoFamilies,
          color: error ? AppColors.err : AppColors.text,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

/// Sessions stored on the remote for the workspace folder. In [pickMode] the
/// widget pops with the chosen session id (or `__new__`).
class ClaudeSessionList extends ConsumerStatefulWidget {
  const ClaudeSessionList({super.key, this.pickMode = false});
  final bool pickMode;

  @override
  ConsumerState<ClaudeSessionList> createState() => _ClaudeSessionListState();
}

class _ClaudeSessionListState extends ConsumerState<ClaudeSessionList> {
  List<ClaudeSessionInfo>? _sessions;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final list = await ref.read(workspaceProvider).sessions.list();
      if (mounted) setState(() => _sessions = list);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _choose(String id) {
    if (widget.pickMode) {
      Navigator.pop(context, id);
    } else {
      final chat = ref.read(workspaceProvider).claude;
      id == '__new__' ? chat.start() : chat.start(resumeSessionId: id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(workspaceProvider).claude;
    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.add, color: AppColors.accent),
          title: const Text('New session'),
          trailing: IconButton(icon: const Icon(Icons.refresh, size: 18), onPressed: _load),
          onTap: () => _choose('__new__'),
        ),
        const Divider(height: 1),
        Expanded(
          child: _error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(16), child: Text(_error!, style: const TextStyle(color: AppColors.err))))
              : _sessions == null
                  ? const Center(child: CircularProgressIndicator())
                  : _sessions!.isEmpty
                      ? const Center(child: Text('No sessions for this folder yet', style: TextStyle(color: AppColors.textDim)))
                      : ListenableBuilder(
                          listenable: chat,
                          builder: (context, _) => ListView.builder(
                            itemCount: _sessions!.length,
                            itemBuilder: (context, i) {
                              final s = _sessions![i];
                              final current = s.id == chat.sessionId;
                              return ListTile(
                                selected: current,
                                selectedTileColor: AppColors.accentDim.withValues(alpha: 0.4),
                                leading: Icon(Icons.chat_bubble_outline, size: 18, color: current ? AppColors.accent : AppColors.textDim),
                                title: Text(s.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                                subtitle: Text(
                                  '${_ago(s.modified)} • ${s.id.substring(0, 8)}',
                                  style: const TextStyle(fontSize: 11, color: AppColors.textDim),
                                ),
                                trailing: IconButton(
                                  icon: const Icon(Icons.delete_outline, size: 18),
                                  tooltip: 'Delete session',
                                  onPressed: () async {
                                    final ok = await showDialog<bool>(
                                      context: context,
                                      builder: (c) => AlertDialog(
                                        title: const Text('Delete this session?'),
                                        content: Text(s.title),
                                        actions: [
                                          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                                          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
                                        ],
                                      ),
                                    );
                                    if (ok == true) {
                                      await ref.read(workspaceProvider).sessions.delete(s.id);
                                      _load();
                                    }
                                  },
                                ),
                                onTap: () => _choose(s.id),
                              );
                            },
                          ),
                        ),
        ),
      ],
    );
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes}m ago';
    if (d.inDays < 1) return '${d.inHours}h ago';
    if (d.inDays < 30) return '${d.inDays}d ago';
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  }
}
