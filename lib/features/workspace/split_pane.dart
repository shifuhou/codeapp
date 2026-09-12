import 'package:flutter/material.dart';

import '../../app.dart';

/// Two children separated by a draggable divider, like VS Code's sash.
/// [firstSize] is the size of the first child along [axis].
class SplitPane extends StatelessWidget {
  const SplitPane({
    super.key,
    required this.axis,
    required this.first,
    required this.second,
    required this.firstSize,
    required this.onResize,
    this.minFirst = 120,
    this.minSecond = 120,
    this.firstAtEnd = false,
  });

  final Axis axis;
  final Widget first;
  final Widget second;
  final double firstSize;
  final ValueChanged<double> onResize;
  final double minFirst;
  final double minSecond;

  /// When true the sized child is placed after the flexible one (e.g. a
  /// bottom terminal panel or a right-hand panel).
  final bool firstAtEnd;

  @override
  Widget build(BuildContext context) {
    final horizontal = axis == Axis.horizontal;
    return LayoutBuilder(
      builder: (context, constraints) {
        final total = horizontal ? constraints.maxWidth : constraints.maxHeight;
        final size = firstSize.clamp(minFirst, (total - minSecond).clamp(minFirst, double.infinity));
        final sized = SizedBox(width: horizontal ? size : null, height: horizontal ? null : size, child: first);
        final divider = _Sash(
          axis: axis,
          onDrag: (delta) => onResize((firstSize + (firstAtEnd ? -delta : delta)).clamp(minFirst, total - minSecond)),
        );
        final children = firstAtEnd
            ? [Expanded(child: second), divider, sized]
            : [sized, divider, Expanded(child: second)];
        return horizontal
            ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: children)
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
      },
    );
  }
}

class _Sash extends StatefulWidget {
  const _Sash({required this.axis, required this.onDrag});
  final Axis axis;
  final ValueChanged<double> onDrag;

  @override
  State<_Sash> createState() => _SashState();
}

class _SashState extends State<_Sash> {
  bool _hover = false;
  bool _drag = false;

  @override
  Widget build(BuildContext context) {
    final horizontal = widget.axis == Axis.horizontal;
    final active = _hover || _drag;
    return MouseRegion(
      cursor: horizontal ? SystemMouseCursors.resizeColumn : SystemMouseCursors.resizeRow,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => setState(() => _drag = true),
        onPanEnd: (_) => setState(() => _drag = false),
        onPanCancel: () => setState(() => _drag = false),
        onPanUpdate: (d) => widget.onDrag(horizontal ? d.delta.dx : d.delta.dy),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: horizontal ? 5 : null,
          height: horizontal ? null : 5,
          color: active ? AppColors.accent.withValues(alpha: 0.6) : AppColors.border,
        ),
      ),
    );
  }
}
