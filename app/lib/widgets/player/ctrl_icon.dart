import 'package:flutter/material.dart';

/// 透明控制图标（不凸显控件样式：仅图标 + 悬浮提示，无按钮底色；
/// 禁用时整体降透明度）。
class CtrlIcon extends StatelessWidget {
  const CtrlIcon({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.size,
    this.color,
    this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final double size;
  final Color? color;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = color ?? scheme.onSurfaceVariant;
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        radius: size,
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(
            icon,
            size: size,
            color: base.withValues(alpha: onPressed == null ? 0.35 : 1),
          ),
        ),
      ),
    );
  }
}
