/// 歌曲列表浮动操作小组件（对齐 SPlayer-Next SongList 右下角浮动按钮组）：
///
/// - [ScrollToTopButton]：回到顶部。滚动超过 [threshold] 时浮现，
///   点击平滑滚动回列表顶部。
/// - [LocatePlayingButton]：定位播放位置。列表中存在当前播放曲目
///   （[playingIndex] >= 0）时浮现，点击平滑滚动到该行。
///
/// 两个组件均依赖宿主传入的 [ScrollController]（同一滚动容器）；批量
/// 选择模式下由宿主决定是否隐藏整组（对齐 SPlayer-Next `!batch.active`）。
library;

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../player/s_controls.dart';

/// 回到顶部浮动按钮：滚动超过阈值自动浮现，点击平滑回顶。
class ScrollToTopButton extends StatefulWidget {
  const ScrollToTopButton({
    super.key,
    required this.controller,
    this.threshold = 100,
  });

  /// 承载列表的滚动控制器（由宿主创建并传给 ListView）。
  final ScrollController controller;

  /// 滚动超过该像素值才显示（对齐 SPlayer-Next `scrollTop > 100`）。
  final double threshold;

  @override
  State<ScrollToTopButton> createState() => _ScrollToTopButtonState();
}

class _ScrollToTopButtonState extends State<ScrollToTopButton> {
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onScroll);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() {
    final offset = widget.controller.hasClients
        ? widget.controller.offset
        : 0.0;
    final next = offset > widget.threshold;
    if (next != _visible && mounted) {
      setState(() => _visible = next);
    }
  }

  void _toTop() {
    if (!widget.controller.hasClients) return;
    widget.controller.animateTo(
      0,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    return _FloatActionButton(
      visible: _visible,
      tooltip: context.l10n.songListScrollTop,
      icon: Icons.keyboard_arrow_up,
      onTap: _toTop,
    );
  }
}

/// 定位播放位置浮动按钮：列表存在当前播放曲目时浮现，点击滚动到该行。
class LocatePlayingButton extends StatelessWidget {
  const LocatePlayingButton({
    super.key,
    required this.controller,
    required this.playingIndex,
    this.itemExtent = 76,
    this.topPadding = 8,
  });

  /// 承载列表的滚动控制器。
  final ScrollController controller;

  /// 当前播放曲目在列表中的索引；< 0 表示不在本列表（隐藏按钮）。
  final int playingIndex;

  /// 行间步进（行高 + 行外上下 padding，SongList 行 = 68 + 8）。
  final double itemExtent;

  /// 列表顶部 padding（滚动目标需补偿，使行顶对齐视口顶）。
  final double topPadding;

  bool get _visible => playingIndex >= 0;

  void _locate() {
    if (!controller.hasClients || !_visible) return;
    final target = playingIndex * itemExtent + topPadding;
    controller.animateTo(
      target,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    return _FloatActionButton(
      visible: _visible,
      tooltip: context.l10n.songListLocatePlaying,
      icon: Icons.my_location,
      onTap: _locate,
    );
  }
}

/// 浮动圆钮通用外观：毛玻璃圆底 + 主色描边 + 阴影，渐显渐隐
/// （对齐 SPlayer-Next `rounded-full bg-surface-panel border-primary/10 shadow-lg`）。
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
    final scheme = Theme.of(context).colorScheme;
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
              color: scheme.surface.withValues(alpha: 0.92),
              border: Border.all(color: scheme.primary.withValues(alpha: 0.18)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.12),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: SButton(
              label: tooltip,
              icon: icon,
              circle: true,
              size: SButtonSize.medium,
              variant: SButtonVariant.ghost,
              onPressed: onTap,
            ),
          ),
        ),
      ),
    );
  }
}
