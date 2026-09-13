/// Models for the Claude Code `--output-format stream-json` protocol.
library;

sealed class ContentBlock {
  const ContentBlock();

  static ContentBlock? fromJson(Map<String, dynamic> j) {
    switch (j['type']) {
      case 'text':
        return TextBlock(j['text'] as String? ?? '');
      case 'thinking':
        return ThinkingBlock(j['thinking'] as String? ?? '');
      case 'tool_use':
        return ToolUseBlock(
          id: j['id'] as String,
          name: j['name'] as String,
          input: (j['input'] as Map?)?.cast<String, dynamic>() ?? {},
        );
      case 'tool_result':
        final c = j['content'];
        String text;
        if (c is String) {
          text = c;
        } else if (c is List) {
          text = c
              .map((e) => e is Map && e['type'] == 'text' ? e['text'] : '')
              .join('\n');
        } else {
          text = '';
        }
        return ToolResultBlock(
          toolUseId: j['tool_use_id'] as String,
          content: text,
          isError: j['is_error'] == true,
        );
    }
    return null;
  }
}

class TextBlock extends ContentBlock {
  const TextBlock(this.text);
  final String text;
}

class ThinkingBlock extends ContentBlock {
  const ThinkingBlock(this.text);
  final String text;
}

class ToolUseBlock extends ContentBlock {
  const ToolUseBlock({
    required this.id,
    required this.name,
    required this.input,
  });
  final String id;
  final String name;
  final Map<String, dynamic> input;
}

class ToolResultBlock extends ContentBlock {
  const ToolResultBlock({
    required this.toolUseId,
    required this.content,
    required this.isError,
  });
  final String toolUseId;
  final String content;
  final bool isError;
}

/// A permission request from Claude Code (`control_request` /
/// `can_use_tool`). The CLI blocks until we answer.
class PermissionRequest {
  PermissionRequest({
    required this.requestId,
    required this.toolName,
    required this.input,
    required this.toolUseId,
    this.description,
  });
  final String requestId;
  final String toolName;
  final Map<String, dynamic> input;
  final String? toolUseId;
  final String? description;
}

/// Chat timeline items rendered by the UI.
sealed class ChatItem {
  ChatItem();
  final DateTime time = DateTime.now();
}

class UserItem extends ChatItem {
  UserItem(this.text);
  final String text;
}

class AssistantTextItem extends ChatItem {
  AssistantTextItem(this.text, {this.streaming = false});
  String text;
  bool streaming;
}

class ThinkingItem extends ChatItem {
  ThinkingItem(this.text);
  String text;
}

class ToolCallItem extends ChatItem {
  ToolCallItem(this.call);
  final ToolUseBlock call;
  ToolResultBlock? result;
  PermissionRequest? pendingPermission;
  String? permissionDecision; // 'allow' | 'deny'

  /// AskUserQuestion is delivered as a permission request whose answer is
  /// the user's choice, so it needs its own UI rather than Allow/Deny.
  bool get isQuestion => call.name == 'AskUserQuestion';

  /// Parsed questions for [isQuestion] items.
  List<UserQuestion> get questions {
    final qs = (pendingPermission?.input ?? call.input)['questions'];
    if (qs is! List) return const [];
    return [
      for (final q in qs)
        if (q is Map)
          UserQuestion(
            question: q['question'] as String? ?? '',
            header: q['header'] as String? ?? '',
            multiSelect: q['multiSelect'] == true,
            options: [
              for (final o in (q['options'] as List? ?? const []))
                if (o is Map) (label: o['label'] as String? ?? '', description: o['description'] as String? ?? ''),
            ],
          ),
    ];
  }
}

class UserQuestion {
  const UserQuestion({required this.question, required this.header, required this.multiSelect, required this.options});
  final String question;
  final String header;
  final bool multiSelect;
  final List<({String label, String description})> options;
}

class SystemNoteItem extends ChatItem {
  SystemNoteItem(this.text, {this.isError = false});
  final String text;
  final bool isError;
}

class ResultItem extends ChatItem {
  ResultItem({
    required this.isError,
    required this.durationMs,
    required this.costUsd,
    required this.numTurns,
  });
  final bool isError;
  final int durationMs;
  final double costUsd;
  final int numTurns;
}

enum PermissionMode { normal, acceptEdits, plan, bypassPermissions }

extension PermissionModeX on PermissionMode {
  String get cliValue => switch (this) {
        PermissionMode.normal => 'default',
        PermissionMode.acceptEdits => 'acceptEdits',
        PermissionMode.plan => 'plan',
        PermissionMode.bypassPermissions => 'bypassPermissions',
      };

  String get label => switch (this) {
        PermissionMode.normal => 'Ask before tools',
        PermissionMode.acceptEdits => 'Auto-accept edits',
        PermissionMode.plan => 'Plan mode',
        PermissionMode.bypassPermissions => 'Bypass permissions',
      };
}
