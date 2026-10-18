// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../player_cover.dart';

/// 全屏封面布局（`coverLayout: fullscreen`）的左侧整幅封面。
///
/// 对齐原项目 FullPlayer 的全屏封面：封面铺满左侧整列（无圆角/阴影，
/// 播放暂停不做缩放），右缘用横向渐隐融入背景，避免与右侧歌词区之间
/// 出现生硬的分界线。曲目信息不再压在封面下方，由播放页放到歌词上方
/// （见 `player_page_view.dart` 的 `_FullscreenTrackInfo`）。
class PlayerFullscreenCover extends StatelessWidget {
  const PlayerFullscreenCover({super.key, required this.cover});

  /// 封面地址（同 [CoverImage]：URL / file:// / 磁盘路径；空则占位）。
  final String? cover;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        final h = c.maxHeight;
        final shortSide = w < h ? w : h;
        return ShaderMask(
          // dstIn：用渐变 alpha 当遮罩，保留封面自身颜色，只让右缘渐隐。
          blendMode: BlendMode.dstIn,
          // 以左缘中点为圆心的径向遮罩：渐隐边界是一条弧线而不是竖线。
          // 半径按短边计，右侧刚好在 92% 半径处收尾；文字起点处 alpha 很低。
          shaderCallback: (rect) => RadialGradient(
            center: Alignment.centerLeft,
            radius: 1.0,
            colors: [
              Colors.white,
              Colors.white,
              Colors.white.withValues(alpha: 0.60),
              Colors.white.withValues(alpha: 0.20),
              Colors.white.withValues(alpha: 0),
            ],
            stops: const [0, 0.65, 0.78, 0.85, 0.92],
          ).createShader(rect),
          child: CoverImage(
            cover: cover,
            width: w,
            height: h,
            radius: 0,
            iconSize: (shortSide * 0.2).clamp(48.0, 140.0),
          ),
        );
      },
    );
  }
}
