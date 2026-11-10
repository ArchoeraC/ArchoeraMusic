// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 播放页的播放/暂停主键：椭圆胶囊填充底色 + 反色字形。
///
/// 取代旧的「纯圆形图标」（`EtaIcons.playCircle/pauseCircle`）：旧观感是
/// 一个正圆轮廓，新观感是一条横向拉长的胶囊——主题色实心底 + 反色
/// 三角/双竖线，播放页（Vutron 左栏控制与共享底栏）共用同一枚按钮，
/// 切换布局时不会出现两种形状。
///
/// 低开销：只有一次隐式动画（底色/字形淡入淡出），无离屏层；性能模式下
/// 由 [animDuration] 归零直切。
library;

import 'package:material_ui/material_ui.dart';

import '../../theme/app_theme.dart';
import '../common/anim.dart';

import 'package:archoera_music/eta/icon/eta_icons.dart';

class PlayPauseButton extends StatelessWidget {
  const PlayPauseButton({
    super.key,
    required this.playing,
    required this.onPressed,
    this.buffering = false,
    this.height = 48,
    this.tooltip,
  });

  /// 当前是否在播放（决定字形：播放三角 / 暂停双竖线）。
  final bool playing;

  /// 点击回调；`null` = 无内容，胶囊压成低对比的禁用态。
  final VoidCallback? onPressed;

  /// 缓冲中：底色压暗并显示进度圈，同时不接受点击。
  final bool buffering;

  /// 胶囊高度；宽度按 [widthFactor] 横向拉伸成椭圆。
  final double height;

  final String? tooltip;

  /// 横向拉伸比例：参考设计稿的胶囊约为 1.55:1（横向椭圆）。
  static const double widthFactor = 1.55;

  double get width => height * widthFactor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasContent = onPressed != null;
    final interactive = hasContent && !buffering;

    final Color fill = !hasContent
        ? scheme.onSurface.withValues(alpha: 0.10)
        : scheme.primary.withValues(alpha: buffering ? 0.35 : 1);
    final Color glyph = !hasContent
        ? scheme.onSurfaceVariant.withValues(alpha: 0.7)
        : scheme.onPrimary;

    Widget button = MouseRegion(
      cursor: interactive ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: Semantics(
        button: true,
        enabled: interactive,
        label: tooltip,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            hoverColor: glyph.withValues(alpha: interactive ? 0.12 : 0),
            splashColor: glyph.withValues(alpha: 0.16),
            onTap: interactive ? onPressed : null,
            child: AnimatedContainer(
              duration: animDuration(
                context,
                const Duration(milliseconds: 180),
              ),
              curve: Curves.easeOut,
              width: width,
              height: height,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
              child: AnimatedSwitcher(
                duration: animDuration(
                  context,
                  const Duration(milliseconds: 160),
                ),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: ScaleTransition(scale: animation, child: child),
                ),
                child: buffering
                    ? SizedBox(
                        key: const ValueKey('buffering'),
                        width: height * 0.42,
                        height: height * 0.42,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.4,
                          color: glyph,
                        ),
                      )
                    : Icon(
                        playing ? EtaIcons.pause : EtaIcons.play,
                        key: ValueKey(playing),
                        // 播放三角视觉偏轻，稍稍放大一点与暂停双竖线等重。
                        size: height * (playing ? 0.46 : 0.48),
                        color: glyph,
                      ),
              ),
            ),
          ),
        ),
      ),
    );
    if (tooltip != null) {
      button = Tooltip(message: tooltip!, child: button);
    }
    return button;
  }
}
