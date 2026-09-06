// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../scroll_float_actions.dart';

extension _SongListFloatActionsView on _SongListFloatActionsState {
  Widget _buildSongListFloatActions(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => _onHoverEnter(),
      onExit: (_) => _onHoverExit(),
      child: IgnorePointer(
        ignoring: !_visible,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 180),
          opacity: _visible ? 1 : 0,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ScrollToTopButton(
                controller: widget.controller,
                threshold: widget.threshold,
              ),
              const SizedBox(height: 12),
              LocatePlayingButton(
                controller: widget.controller,
                playingIndex: widget.playingIndex,
                itemExtent: widget.itemExtent,
                topPadding: widget.topPadding,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

extension _ScrollToTopButtonView on _ScrollToTopButtonState {
  Widget _buildScrollToTopButton(BuildContext context) {
    return _FloatActionButton(
      visible: _visible,
      tooltip: context.l10n.songListScrollTop,
      icon: Icons.keyboard_arrow_up,
      onTap: _toTop,
    );
  }
}

extension _LocatePlayingButtonView on LocatePlayingButton {
  Widget _buildLocatePlayingButton(BuildContext context) {
    return _FloatActionButton(
      visible: _visible,
      tooltip: context.l10n.songListLocatePlaying,
      icon: Icons.my_location,
      onTap: _locate,
    );
  }
}

/// 浮动圆钮通用外观：主题化毛玻璃圆底 + 描边 + 阴影，随深浅色重建
/// （背景/描边/图标颜色全部取自 Theme.colorScheme，避免独立于主题）。
class _FloatActionButton extends StatelessWidget {
  const _FloatActionButton({
    required this.visible,
    required this.tooltip,
    required this.icon,
    required this.onTap,
  });

  final bool visible;
  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    // 显式按深浅色二值化，不依赖 scheme 可能被宿主/背景层覆盖的 surface 角色。
    final bg = dark ? const Color(0xFF262B3A) : const Color(0xFFFFFFFF);
    final border = dark
        ? Colors.white.withValues(alpha: 0.14)
        : Colors.black.withValues(alpha: 0.12);
    final fg = dark ? const Color(0xFFE6E8EF) : const Color(0xFF1E1F24);
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 180),
        opacity: visible ? 1 : 0,
        child: Tooltip(
          message: tooltip,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: bg,
              border: Border.all(color: border),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: dark ? 0.28 : 0.12),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: SizedBox(
              width: 44,
              height: 44,
              child: Center(
                child: IconButton(
                  tooltip: tooltip,
                  onPressed: onTap,
                  iconSize: 18,
                  padding: EdgeInsets.zero,
                  // 只让图标核心区域拦截点击：圆盘其余部分不参与命中测试，
                  // 避免浮钮整块挡住下层列表行（长期遮挡问题）。
                  constraints: const BoxConstraints.tightFor(
                    width: 26,
                    height: 26,
                  ),
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.transparent,
                    foregroundColor: fg,
                    disabledForegroundColor: fg.withValues(alpha: 0.5),
                  ),
                  icon: Icon(icon),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
