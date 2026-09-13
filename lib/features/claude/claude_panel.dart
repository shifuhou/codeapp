import 'dart:async';
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
import '../workspace/context_menu.dart';

/// One Claude chat, shown as an editor tab.
class ClaudePanel extends ConsumerStatefulWidget {
  const ClaudePanel({super.key, required this.chat});
  final ClaudeChat chat;

  @override
  ConsumerState<ClaudePanel> createState() => _ClaudePanelState();
}

class _ClaudePanelState extends ConsumerState<ClaudePanel> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  int _lastCount = 0;

  /// Per-turn expand/collapse overrides (turn index -> expanded); a global
  /// default set by collapse-all / expand-all.
  final Map<int, bool> _turnOverride = {};
  bool? _allOverride;

  /// Slash-command suggestions for the current input (empty when hidden).
  List<_SlashCommand> _suggestions = [];

  static const _modelChoices = <String, String>{
    'default': 'Default (whatever the CLI is configured with)',
    'opus': 'Claude Opus 5',
    'sonnet': 'Claude Sonnet 5',
    'haiku': 'Claude Haiku 4.5',
    'claude-fable-5-1': 'Claude Fable 5.1',
  };

  late final List<_SlashCommand> _localCommands = [
    _SlashCommand('model', 'Switch model: /model opus|sonnet|haiku|<id>', (a) => _cmdModel(a)),
    _SlashCommand('mode', 'Permission mode: /mode ask|edits|plan|bypass', (a) => _cmdMode(a)),
    _SlashCommand('permissions', 'Same as /mode', (a) => _cmdMode(a)),
    _SlashCommand('usage', 'Show tokens, cost and context size for this session', (_) => _note(widget.chat.usageSummary())),
    _SlashCommand('cost', 'Same as /usage', (_) => _note(widget.chat.usageSummary())),
    _SlashCommand('new', 'Start a new session', (_) => widget.chat.start()),
    _SlashCommand('clear', 'Same as /new', (_) => widget.chat.start()),
    _SlashCommand('resume', 'Pick a stored session to resume', (_) => _pickSession()),
    _SlashCommand('stop', 'Interrupt the current turn', (_) => widget.chat.interrupt()),
    _SlashCommand('compact', 'Ask Claude Code to compact the conversation', (a) => _forward('/compact', a)),
    _SlashCommand('help', 'List commands', (_) => _cmdHelp()),
  ];

  @override
  void initState() {
    super.initState();
    _input.addListener(_onInputChanged);
  }

  void _onInputChanged() {
    final t = _input.text;
    List<_SlashCommand> next = [];
    if (t.startsWith('/') && !t.contains('\n')) {
      final typed = t.split(' ').first.substring(1).toLowerCase();
      final all = [
        ..._localCommands,
        for (final c in widget.chat.cliSlashCommands)
          if (!_localCommands.any((l) => l.name == c)) _SlashCommand(c, 'Claude Code command', (a) => _forward('/$c', a)),
      ];
      next = all.where((c) => c.name.startsWith(typed)).toList();
      if (t.contains(' ') && next.length > 1) next = next.where((c) => c.name == typed).toList();
    }
    if (next.length != _suggestions.length || !identical(next.firstOrNull, _suggestions.firstOrNull)) {
      setState(() => _suggestions = next);
    }
  }

  void _note(String text) => setState(() => widget.chat.items.add(SystemNoteItem(text)));

  void _forward(String cmd, String args) => widget.chat.send(args.isEmpty ? cmd : '$cmd $args');

  Future<void> _cmdModel(String arg) async {
    var id = arg.trim();
    if (id.isEmpty) {
      final picked = await showDialog<String>(
        context: context,
        builder: (c) => SimpleDialog(
          title: const Text('Model'),
          children: [
            for (final e in _modelChoices.entries)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(c, e.key),
                child: Row(children: [
                  Icon(
                    (widget.chat.modelOverride ?? 'default') == e.key ? Icons.radio_button_checked : Icons.radio_button_off,
                    size: 16,
                    color: AppColors.accent,
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Text('${e.key}  ', style: const TextStyle(fontSize: 14))),
                  Text(e.value, style: const TextStyle(fontSize: 12, color: AppColors.textDim)),
                ]),
              ),
          ],
        ),
      );
      if (picked == null) return;
      id = picked;
    }
    await widget.chat.setModel(id);
  }

  Future<void> _cmdMode(String arg) async {
    final a = arg.trim().toLowerCase();
    final m = switch (a) {
      'ask' || 'default' || 'normal' => PermissionMode.normal,
      'edits' || 'acceptedits' || 'auto' => PermissionMode.acceptEdits,
      'plan' => PermissionMode.plan,
      'bypass' || 'bypasspermissions' || 'yolo' => PermissionMode.bypassPermissions,
      _ => null,
    };
    if (m == null) {
      _note('Usage: /mode ask | edits | plan | bypass   (current: ${widget.chat.permissionMode.label})');
      return;
    }
    await widget.chat.setPermissionMode(m);
  }

  void _cmdHelp() {
    final lines = [
      for (final c in _localCommands) '/${c.name}  —  ${c.help}',
      if (widget.chat.cliSlashCommands.isNotEmpty)
        'Claude Code commands: ${widget.chat.cliSlashCommands.map((c) => '/$c').join('  ')}',
    ];
    _note(lines.join('\n'));
  }

  /// Returns true when [text] was handled as a slash command.
  Future<bool> _runSlash(String text) async {
    if (!text.startsWith('/')) return false;
    if (text.trim() == '/') return true; // a bare slash is never a message
    final sp = text.indexOf(' ');
    final name = (sp < 0 ? text.substring(1) : text.substring(1, sp)).toLowerCase();
    final args = sp < 0 ? '' : text.substring(sp + 1).trim();
    final local = _localCommands.where((c) => c.name == name).firstOrNull;
    if (local != null) {
      widget.chat.items.add(UserItem(text));
      setState(() {});
      await local.run(args);
      return true;
    }
    // Unknown here: let Claude Code handle it (custom commands, skills).
    return false;
  }

  void _cycleMode() {
    final all = PermissionMode.values;
    final next = all[(all.indexOf(widget.chat.permissionMode) + 1) % all.length];
    widget.chat.setPermissionMode(next);
  }

  @override
  void dispose() {
    _input.removeListener(_onInputChanged);
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    _focus.requestFocus();
    if (await _runSlash(text)) return;
    widget.chat.send(text);
  }

  void _completeSuggestion() {
    final first = _suggestions.firstOrNull;
    if (first == null) return;
    _input.text = '/${first.name} ';
    _input.selection = TextSelection.collapsed(offset: _input.text.length);
  }

  bool _scrolledOnce = false;

  void _autoScroll(ClaudeChat chat) {
    if (chat.items.length != _lastCount || chat.busy) {
      final firstFill = !_scrolledOnce && chat.items.isNotEmpty;
      _lastCount = chat.items.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scroll.hasClients) return;
        final max = _scroll.position.maxScrollExtent;
        // Always land at the bottom when history first appears; afterwards
        // only follow if the user is already near the bottom.
        if (firstFill || max - _scroll.offset < 400) {
          _scroll.jumpTo(max);
          _scrolledOnce = true;
        }
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
      widget.chat.start();
    } else {
      widget.chat.start(resumeSessionId: picked);
    }
  }

  // ---- turns ---------------------------------------------------------------

  /// Groups the timeline into turns: your message followed by everything
  /// Claude did in response.
  static List<_Turn> _turns(ClaudeChat chat) {
    final turns = <_Turn>[];
    var i = 0;
    for (final item in chat.items) {
      if (item is UserItem || turns.isEmpty) {
        turns.add(_Turn(item is UserItem ? item : null, i < chat.historyItemCount));
      }
      if (item is! UserItem) turns.last.body.add(item);
      i++;
    }
    return turns;
  }

  bool _isExpanded(int index, int count, _Turn t, ClaudeChat chat) {
    final o = _turnOverride[index];
    if (o != null) return o;
    // The turn Claude is working on right now is always open, so new output
    // never lands in a collapsed block.
    if (index == count - 1 && chat.busy) return true;
    if (_allOverride != null) return _allOverride!;
    // Older history turns start collapsed so your own prompts are easy to
    // find; the latest turn and live turns start open.
    return index == count - 1 || !t.fromHistory;
  }

  void _setAll(bool expanded) => setState(() {
        _turnOverride.clear();
        _allOverride = expanded;
      });

  @override
  Widget build(BuildContext context) {
    final chat = widget.chat;
    return ListenableBuilder(
      listenable: chat,
      builder: (context, _) {
        _autoScroll(chat);
        return Column(
          children: [
            _toolbar(chat),
            const Divider(height: 1),
            Expanded(
              child: chat.loadingHistory && chat.items.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : chat.items.isEmpty
                      ? _emptyState(chat)
                      : _turnList(chat),
            ),
            if (chat.busy) const LinearProgressIndicator(key: ValueKey('busy'), minHeight: 2),
            // Keys keep the input's element (and its focus) stable while
            // bars and suggestion lists come and go above it.
            for (final t in chat.pendingPermissions)
              _PermissionBar(key: ValueKey('perm-${t.call.id}'), item: t, chat: chat),
            if (_suggestions.isNotEmpty) KeyedSubtree(key: const ValueKey('suggest'), child: _suggestionList()),
            KeyedSubtree(key: const ValueKey('input'), child: _inputBar(chat)),
          ],
        );
      },
    );
  }

  Widget _turnList(ClaudeChat chat) {
    final turns = _turns(chat);
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      itemCount: turns.length,
      itemBuilder: (context, i) {
        final t = turns[i];
        final expanded = _isExpanded(i, turns.length, t, chat);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (t.user != null) _UserBubble(text: t.user!.text, first: i == 0),
            if (t.body.isNotEmpty)
              _ResponseBlock(
                turn: t,
                chat: chat,
                expanded: expanded,
                live: i == turns.length - 1 && chat.busy,
                onToggle: () => setState(() => _turnOverride[i] = !expanded),
              ),
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
            IconButton(
              tooltip: 'Collapse all responses',
              icon: const Icon(Icons.unfold_less, size: 18),
              onPressed: () => _setAll(false),
            ),
            IconButton(
              tooltip: 'Expand all responses',
              icon: const Icon(Icons.unfold_more, size: 18),
              onPressed: () => _setAll(true),
            ),
            IconButton(
              tooltip: 'Restart with a new session',
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
              'Claude Code in ${ref.read(workspaceProvider).workDir}',
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

  Widget _suggestionList() {
    return Container(
      color: AppColors.panelAlt,
      constraints: const BoxConstraints(maxHeight: 220),
      child: ListView(
        shrinkWrap: true,
        children: [
          for (final c in _suggestions.take(8))
            InkWell(
              onTap: () {
                _input.text = '/${c.name} ';
                _input.selection = TextSelection.collapsed(offset: _input.text.length);
                _focus.requestFocus();
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Row(
                  children: [
                    Text('/${c.name}', style: const TextStyle(fontSize: 13, fontFamily: 'JetBrains Mono', fontFamilyFallback: monoFamilies, color: AppColors.accent)),
                    const SizedBox(width: 12),
                    Expanded(child: Text(c.help, style: const TextStyle(fontSize: 12, color: AppColors.textDim), overflow: TextOverflow.ellipsis)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _modeRow(ClaudeChat chat) {
    final m = chat.permissionMode;
    final (icon, color) = switch (m) {
      PermissionMode.normal => (Icons.shield_outlined, AppColors.textDim),
      PermissionMode.acceptEdits => (Icons.edit_outlined, AppColors.ok),
      PermissionMode.plan => (Icons.map_outlined, AppColors.accent),
      PermissionMode.bypassPermissions => (Icons.bolt, AppColors.warn),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          PopupMenuButton<PermissionMode>(
            tooltip: 'Permission mode (Shift+Tab cycles)',
            initialValue: m,
            onSelected: chat.setPermissionMode,
            itemBuilder: (_) => [
              for (final x in PermissionMode.values)
                PopupMenuItem(
                  value: x,
                  height: 36,
                  child: Row(children: [
                    Icon(x == m ? Icons.radio_button_checked : Icons.radio_button_off, size: 15, color: AppColors.accent),
                    const SizedBox(width: 10),
                    Text(x.label, style: const TextStyle(fontSize: 13)),
                  ]),
                ),
            ],
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                border: Border.all(color: color.withValues(alpha: 0.6)),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon, size: 13, color: color),
                const SizedBox(width: 5),
                Text(m.label, style: TextStyle(fontSize: 11.5, color: color)),
                const Icon(Icons.arrow_drop_down, size: 15, color: AppColors.textDim),
              ]),
            ),
          ),
          const SizedBox(width: 8),
          InkWell(
            onTap: () => _cmdModel(''),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.memory, size: 13, color: AppColors.textDim),
                const SizedBox(width: 5),
                Text(chat.modelOverride ?? chat.model ?? 'default model', style: const TextStyle(fontSize: 11.5, color: AppColors.textDim)),
              ]),
            ),
          ),
          const Spacer(),
          const Text('/ for commands', style: TextStyle(fontSize: 11, color: AppColors.textDim)),
        ],
      ),
    );
  }

  Widget _inputBar(ClaudeChat chat) {
    return Container(
      color: AppColors.panel,
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _modeRow(chat),
            Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.enter): _send,
                  const SingleActivator(LogicalKeyboardKey.numpadEnter): _send,
                  const SingleActivator(LogicalKeyboardKey.tab): _completeSuggestion,
                  const SingleActivator(LogicalKeyboardKey.tab, shift: true): _cycleMode,
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
              IconButton.filledTonal(tooltip: 'Stop', icon: const Icon(Icons.stop), onPressed: chat.interrupt)
            else
              IconButton.filled(tooltip: 'Send', icon: const Icon(Icons.arrow_upward), onPressed: _send),
          ],
        ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _Turn {
  _Turn(this.user, this.fromHistory);
  final UserItem? user;
  final bool fromHistory;
  final List<ChatItem> body = [];

  int get toolCount => body.whereType<ToolCallItem>().length;
  int get textCount => body.whereType<AssistantTextItem>().length;
  bool get hasPendingPermission => body.whereType<ToolCallItem>().any((t) => t.pendingPermission != null);
  bool get hasError =>
      body.any((i) => (i is SystemNoteItem && i.isError) || (i is ResultItem && i.isError));

  /// Last thing Claude said in this turn, for the collapsed preview.
  String get preview {
    for (final item in body.reversed) {
      if (item is AssistantTextItem && item.text.trim().isNotEmpty) {
        return item.text.trim().split('\n').first;
      }
    }
    return '';
  }

  /// Everything Claude said in this turn, for "copy response".
  String get responseText =>
      body.whereType<AssistantTextItem>().map((t) => t.text).join('\n\n');
}

/// Your message. Never collapses, so it is always easy to find.
class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.text, required this.first});
  final String text;
  final bool first;

  @override
  Widget build(BuildContext context) {
    return ContextMenuRegion(
      longPress: false,
      actions: () => [
        MenuAction('Copy message', () => Clipboard.setData(ClipboardData(text: text)), icon: Icons.copy),
      ],
      child: Container(
        margin: EdgeInsets.only(top: first ? 0 : 18, bottom: 6),
        padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
        decoration: BoxDecoration(
          color: AppColors.accentDim.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(8),
          border: const Border(left: BorderSide(color: AppColors.accent, width: 3)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 2, right: 8),
              child: Icon(Icons.person_outline, size: 16, color: AppColors.accent),
            ),
            Expanded(child: SelectableText(text, style: const TextStyle(fontSize: 14, height: 1.4))),
          ],
        ),
      ),
    );
  }
}

/// Everything Claude did in response to one message, behind a header bar
/// that collapses the whole block.
class _ResponseBlock extends StatelessWidget {
  const _ResponseBlock({
    required this.turn,
    required this.chat,
    required this.expanded,
    required this.live,
    required this.onToggle,
  });
  final _Turn turn;
  final ClaudeChat chat;
  final bool expanded;
  final bool live;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final summary = [
      if (turn.toolCount > 0) '${turn.toolCount} tool call${turn.toolCount == 1 ? '' : 's'}',
      if (turn.textCount > 0) '${turn.textCount} message${turn.textCount == 1 ? '' : 's'}',
    ].join(' · ');
    final preview = turn.preview;
    final header = ContextMenuRegion(
      longPress: false,
      actions: () => [
        MenuAction(expanded ? 'Collapse response' : 'Expand response', onToggle, icon: expanded ? Icons.unfold_less : Icons.unfold_more),
        MenuAction('Copy response text', () => Clipboard.setData(ClipboardData(text: turn.responseText)),
            icon: Icons.copy, enabled: turn.responseText.isNotEmpty),
      ],
      child: InkWell(
        onTap: onToggle,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 6, 6),
          child: Row(
            children: [
              Icon(expanded ? Icons.expand_more : Icons.chevron_right, size: 18, color: AppColors.textDim),
              const SizedBox(width: 4),
              const Icon(Icons.auto_awesome, size: 14, color: AppColors.accent),
              const SizedBox(width: 8),
              Text('Claude', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppColors.text)),
              if (summary.isNotEmpty) ...[
                const SizedBox(width: 10),
                Text(summary, style: const TextStyle(fontSize: 12, color: AppColors.textDim)),
              ],
              if (live) ...[
                const SizedBox(width: 10),
                const SizedBox(width: 11, height: 11, child: CircularProgressIndicator(strokeWidth: 1.5)),
              ],
              if (turn.hasPendingPermission) ...[
                const SizedBox(width: 10),
                const Icon(Icons.help_outline, size: 15, color: AppColors.warn),
                const Text(' needs approval', style: TextStyle(fontSize: 12, color: AppColors.warn)),
              ],
              if (turn.hasError) ...[
                const SizedBox(width: 10),
                const Icon(Icons.error_outline, size: 15, color: AppColors.err),
              ],
              const Spacer(),
              if (!expanded && preview.isNotEmpty)
                Flexible(
                  flex: 3,
                  child: Text(preview, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: AppColors.textDim), textAlign: TextAlign.right),
                ),
            ],
          ),
        ),
      ),
    );

    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: expanded ? Colors.transparent : AppColors.panel,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          if (expanded) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [for (final item in turn.body) _ItemView(item: item, chat: chat)],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ItemView extends StatelessWidget {
  const _ItemView({required this.item, required this.chat});
  final ChatItem item;
  final ClaudeChat chat;

  @override
  Widget build(BuildContext context) {
    return switch (item) {
      UserItem u => _UserBubble(text: u.text, first: true),
      AssistantTextItem a => ContextMenuRegion(
          longPress: false,
          actions: () => [
            MenuAction('Copy message', () => Clipboard.setData(ClipboardData(text: a.text)), icon: Icons.copy),
          ],
          child: Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: _Markdown(a.text)),
        ),
      ThinkingItem t => _Collapsible(
          icon: Icons.psychology_outlined,
          title: 'Thinking',
          child: SelectableText(t.text, style: const TextStyle(fontSize: 12, color: AppColors.textDim, fontStyle: FontStyle.italic)),
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
          if (_open) Padding(padding: const EdgeInsets.fromLTRB(10, 0, 10, 10), child: widget.child),
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

    final input = _formatInput(item.call);
    return ContextMenuRegion(
      longPress: false,
      actions: () => [
        MenuAction('Copy tool input', () => Clipboard.setData(ClipboardData(text: input)), icon: Icons.copy),
        MenuAction('Copy tool output', () => Clipboard.setData(ClipboardData(text: res?.content ?? '')),
            icon: Icons.copy, enabled: res != null),
      ],
      child: _Collapsible(
        icon: Icons.build_outlined,
        title: '${item.call.name}  ${_summary()}',
        trailing: Padding(padding: const EdgeInsets.only(right: 6), child: status),
        initiallyOpen: pending != null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _code(input),
            if (pending != null) ...[
              const SizedBox(height: 8),
              Text('Claude wants to use ${pending.toolName}. Allow?', style: const TextStyle(fontSize: 12.5, color: AppColors.warn)),
              const SizedBox(height: 6),
              Row(
                children: [
                  FilledButton(onPressed: () => chat.respondPermission(item, allow: true), child: const Text('Allow')),
                  const SizedBox(width: 8),
                  OutlinedButton(onPressed: () => chat.respondPermission(item, allow: false), child: const Text('Deny')),
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
        style: TextStyle(fontSize: 11.5, fontFamily: 'JetBrains Mono', fontFamilyFallback: monoFamilies, color: error ? AppColors.err : AppColors.text),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

/// Sessions stored on the remote for the workspace folder. In [pickMode] the
/// widget pops with the chosen session id (or `__new__`).
class ClaudeSessionList extends ConsumerStatefulWidget {
  const ClaudeSessionList({super.key, this.pickMode = false, this.onOpened});
  final bool pickMode;

  /// Called after a session was opened as a tab (not in pick mode).
  final VoidCallback? onOpened;

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

  void _choose(String id, {String? title}) {
    if (widget.pickMode) {
      Navigator.pop(context, id);
    } else {
      final editor = ref.read(workspaceProvider).editor;
      id == '__new__' ? editor.openClaude() : editor.openClaude(sessionId: id, label: title);
      widget.onOpened?.call();
    }
  }

  Future<void> _delete(ClaudeSessionInfo s) async {
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
  }

  List<MenuAction> _menu(ClaudeSessionInfo s) => [
        MenuAction('Open', () => _choose(s.id, title: _shortTitle(s.title)), icon: Icons.open_in_new),
        MenuAction('Copy session id', () => Clipboard.setData(ClipboardData(text: s.id)), icon: Icons.copy),
        MenuAction('Copy resume command', () => Clipboard.setData(ClipboardData(text: 'claude --resume ${s.id}')), icon: Icons.terminal),
        menuDivider,
        MenuAction('Delete session', () => _delete(s), icon: Icons.delete_outline, danger: true),
      ];

  @override
  Widget build(BuildContext context) {
    final editor = ref.watch(workspaceProvider).editor;
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
                          listenable: editor,
                          builder: (context, _) => ListView.builder(
                            itemCount: _sessions!.length,
                            itemBuilder: (context, i) {
                              final s = _sessions![i];
                              final current = editor.chats.any((c) => c.sessionId == s.id);
                              return ContextMenuRegion(
                                actions: () => _menu(s),
                                child: ListTile(
                                  selected: current,
                                  selectedTileColor: AppColors.accentDim.withValues(alpha: 0.4),
                                  leading: Icon(Icons.chat_bubble_outline, size: 18, color: current ? AppColors.accent : AppColors.textDim),
                                  title: Text(s.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                                  subtitle: Text('${_ago(s.modified)} • ${s.id.substring(0, 8)}',
                                      style: const TextStyle(fontSize: 11, color: AppColors.textDim)),
                                  onTap: () => _choose(s.id, title: _shortTitle(s.title)),
                                ),
                              );
                            },
                          ),
                        ),
        ),
      ],
    );
  }

  static String _shortTitle(String t) => t.length > 18 ? '${t.substring(0, 18)}…' : t;

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes}m ago';
    if (d.inDays < 1) return '${d.inHours}h ago';
    if (d.inDays < 30) return '${d.inDays}d ago';
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  }
}


class _SlashCommand {
  _SlashCommand(this.name, this.help, this.run);
  final String name;
  final String help;
  final FutureOr<void> Function(String args) run;
}

/// A permission request, pinned above the input so it can never be hidden
/// inside a collapsed block.
class _PermissionBar extends StatelessWidget {
  const _PermissionBar({super.key, required this.item, required this.chat});
  final ToolCallItem item;
  final ClaudeChat chat;

  @override
  Widget build(BuildContext context) {
    final req = item.pendingPermission!;
    final i = item.call.input;
    final detail = switch (item.call.name) {
      'Bash' => i['command'] as String? ?? '',
      'Write' || 'Edit' || 'MultiEdit' || 'Read' || 'NotebookEdit' => i['file_path'] as String? ?? '',
      'WebFetch' => i['url'] as String? ?? '',
      _ => req.description ?? const JsonEncoder.withIndent('  ').convert(i),
    };
    return Container(
      color: AppColors.warn.withValues(alpha: 0.12),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.help_outline, size: 16, color: AppColors.warn),
              const SizedBox(width: 8),
              Text('Allow ${req.toolName}?', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.warn)),
              const Spacer(),
              TextButton(onPressed: () => chat.respondPermission(item, allow: false), child: const Text('Deny')),
              const SizedBox(width: 4),
              OutlinedButton(
                onPressed: () => chat.setPermissionMode(PermissionMode.bypassPermissions),
                child: const Text('Allow all (bypass)'),
              ),
              const SizedBox(width: 4),
              FilledButton(onPressed: () => chat.respondPermission(item, allow: true), child: const Text('Allow')),
            ],
          ),
          if (detail.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 96),
                child: SingleChildScrollView(
                  child: SelectableText(
                    detail.length > 600 ? '${detail.substring(0, 600)}…' : detail,
                    style: const TextStyle(fontSize: 12, fontFamily: 'JetBrains Mono', fontFamilyFallback: monoFamilies),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
