import 'package:flutter/material.dart';

import '../../app.dart';

/// A VS Code-like context menu entry.
class MenuAction {
  const MenuAction(this.label, this.onTap, {this.icon, this.shortcut, this.enabled = true, this.danger = false});
  final String label;
  final VoidCallback onTap;
  final IconData? icon;
  final String? shortcut;
  final bool enabled;
  final bool danger;
}

/// A separator between menu groups.
const menuDivider = MenuAction('-', _noop);
void _noop() {}

/// Shows a compact context menu at [position] (global coordinates).
Future<void> showContextMenu(BuildContext context, Offset position, List<MenuAction> actions) async {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final rect = RelativeRect.fromRect(
    Rect.fromLTWH(position.dx, position.dy, 1, 1),
    Offset.zero & overlay.size,
  );
  final picked = await showMenu<MenuAction>(
    context: context,
    position: rect,
    color: AppColors.panelAlt,
    surfaceTintColor: Colors.transparent,
    constraints: const BoxConstraints(minWidth: 200, maxWidth: 320),
    items: [
      for (final a in actions)
        if (identical(a, menuDivider))
          const PopupMenuDivider(height: 8)
        else
          PopupMenuItem<MenuAction>(
            value: a,
            enabled: a.enabled,
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                if (a.icon != null) ...[
                  Icon(a.icon, size: 15, color: a.danger ? AppColors.err : AppColors.textDim),
                  const SizedBox(width: 10),
                ] else
                  const SizedBox(width: 25),
                Expanded(
                  child: Text(
                    a.label,
                    style: TextStyle(fontSize: 13, color: a.danger ? AppColors.err : (a.enabled ? AppColors.text : AppColors.textDim)),
                  ),
                ),
                if (a.shortcut != null)
                  Text(a.shortcut!, style: const TextStyle(fontSize: 11, color: AppColors.textDim)),
              ],
            ),
          ),
    ],
  );
  picked?.onTap();
}

/// Wraps [child] so a right-click (or long-press on touch) opens [actions].
class ContextMenuRegion extends StatelessWidget {
  const ContextMenuRegion({super.key, required this.child, required this.actions, this.longPress = true});
  final Widget child;
  final List<MenuAction> Function() actions;
  final bool longPress;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTapUp: (d) => showContextMenu(context, d.globalPosition, actions()),
      onLongPressStart: longPress ? (d) => showContextMenu(context, d.globalPosition, actions()) : null,
      child: child,
    );
  }
}
