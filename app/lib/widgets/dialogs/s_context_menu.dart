/// 自绘右键菜单（对齐 SPlayer-Next SContextMenu 语义，替代 Material
/// 系统菜单观感）。
///
/// 用法：
/// ```dart
/// SContextMenu.show(
///   context,
///   position: globalPosition,
///   items: [
///     SContextMenuItem(label: '播放', icon: Icons.play_arrow, onTap: ...),
///     SContextMenuItem.divider(),
///     SContextMenuItem(label: '删除', icon: Icons.delete, danger: true, onTap: ...),
///   ],
/// );
/// ```
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_theme.dart';
import '../common/anim.dart';

/// 右键菜单项。
class SContextMenuItem {
  const SContextMenuItem({
    required this.label,
    this.icon,
    this.onTap,
    this.danger = false,
    this.disabled = false,
    this.divider = false,
  });

  const SContextMenuItem.divider()
    : label = '',
      icon = null,
      onTap = null,
      danger = false,
      disabled = false,
      divider = true;

  final String label;
  final IconData? icon;
  final VoidCallback? onTap;

  /// 危险操作（删除等，红色文字）。
  final bool danger;
  final bool disabled;

  /// 分隔线项。
  final bool divider;
}

/// 自绘右键菜单（覆盖层实现，点击外部 / ESC 关闭，右/下溢出自动翻转）。
class SContextMenu {
  SContextMenu._();

  /// 菜单宽度。
  static const double menuWidth = 220;

  /// 单项高度。
  static const double itemHeight = 38;

  static void show(
    BuildContext context, {
    required Offset position,
    required List<SContextMenuItem> items,
  }) {
    if (items.isEmpty) return;
    final overlay = Overlay.of(context, rootOverlay: true);
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _SContextMenuOverlay(
        position: position,
        items: items,
        onClose: () => entry.remove(),
      ),
    );
    overlay.insert(entry);
  }
}

class _SContextMenuOverlay extends StatefulWidget {
  const _SContextMenuOverlay({
    required this.position,
    required this.items,
    required this.onClose,
  });

  final Offset position;
  final List<SContextMenuItem> items;
  final VoidCallback onClose;

  @override
  State<_SContextMenuOverlay> createState() => _SContextMenuOverlayState();
}

class _SContextMenuOverlayState extends State<_SContextMenuOverlay> {
  /// 菜单显示动画进度（0→1，入场 scale + fade）。
  double _t = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _t = 1);
    });
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final screen = media.size;
    final pad = media.padding;

    // 估算菜单高度用于溢出翻转
    final dividers = widget.items.where((i) => i.divider).length;
    final estHeight =
        widget.items.length * SContextMenu.itemHeight +
        dividers * 10 + // 分隔线额外间距
        16; // 上下 padding
    final estWidth = SContextMenu.menuWidth;

    var left = widget.position.dx;
    var top = widget.position.dy;
    if (left + estWidth > screen.width - 8) left = screen.width - estWidth - 8;
    if (left < 8) left = 8;
    if (top + estHeight > screen.height - pad.bottom - 8) {
      top = screen.height - pad.bottom - estHeight - 8;
    }
    if (top < pad.top + 8) top = pad.top + 8;

    return Stack(
      children: [
        // 全屏透明遮罩：点击外部关闭
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onClose,
            onSecondaryTapDown: (_) => widget.onClose,
            child: Focus(
              autofocus: true,
              onKeyEvent: (node, event) {
                if (event is KeyDownEvent &&
                    event.logicalKey == LogicalKeyboardKey.escape) {
                  widget.onClose();
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: const SizedBox.expand(),
            ),
          ),
        ),
        // 菜单本体
        Positioned(
          left: left,
          top: top,
          child: TweenAnimationBuilder<double>(
            duration: animDuration(
                context, const Duration(milliseconds: 140)),
            curve: Curves.easeOutCubic,
            tween: Tween(begin: 0, end: _t),
            builder: (context, t, child) => Transform.scale(
              scale: 0.96 + 0.04 * t,
              child: Opacity(opacity: t, child: child),
            ),
            child: Material(
              color: Colors.transparent,
              child: Container(
                width: SContextMenu.menuWidth,
                padding: const EdgeInsets.symmetric(vertical: 6),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(AppRadius.dialog),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.35),
                      blurRadius: 24,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final item in widget.items)
                      item.divider
                          ? Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              child: Divider(
                                height: 1,
                                color: Theme.of(
                                  context,
                                ).colorScheme.outline.withValues(alpha: 0.4),
                              ),
                            )
                          : _MenuItem(item: item, onClose: widget.onClose),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _MenuItem extends StatelessWidget {
  const _MenuItem({required this.item, required this.onClose});

  final SContextMenuItem item;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = item.danger
        ? scheme.error
        : (item.disabled
              ? scheme.onSurfaceVariant.withValues(alpha: 0.4)
              : scheme.onSurface);

    return MouseRegion(
      cursor: (item.disabled || item.onTap == null)
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          hoverColor: item.disabled
              ? Colors.transparent
              : scheme.onSurface.withValues(alpha: 0.06),
          onTap: (item.disabled || item.onTap == null)
              ? null
              : () {
                  onClose();
                  item.onTap!();
                },
          child: SizedBox(
            height: SContextMenu.itemHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  if (item.icon != null) ...[
                    Icon(
                      item.icon,
                      size: 17,
                      color: fg.withValues(alpha: 0.85),
                    ),
                    const SizedBox(width: 10),
                  ] else
                    const SizedBox(width: 27),
                  Text(item.label, style: TextStyle(fontSize: 13.5, color: fg)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
