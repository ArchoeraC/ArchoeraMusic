// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../s_context_menu.dart';

extension _SContextMenuOverlayView on _SContextMenuOverlayState {
  Widget _buildSContextMenuOverlay(BuildContext context) {
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
            duration: animDuration(context, const Duration(milliseconds: 140)),
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

extension _MenuItemView on _MenuItem {
  Widget _buildMenuItem(BuildContext context) {
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
