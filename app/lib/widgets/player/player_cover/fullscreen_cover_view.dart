// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../player_cover.dart';

/// 全屏封面布局（`coverLayout: fullscreen`）的左侧整幅封面。
///
/// 对齐 SPlayer-Next 的全屏封面（`.full-cover`）：封面铺满左侧整列（无圆角/
/// 阴影，播放暂停不做缩放），右缘经**多段非线性 alpha 渐变**缓缓融入背景——
/// 近半宽度内几乎不透明（0.98@10% → 0.52@52%），尾段长尾收零，形成
/// 「海报渗入背景」的观感；渐隐尾部延伸到歌词列起点之下，不被竖线截断。
///
/// 遮罩实现见 [ShaderMask]（dstIn）。2026-11-03 曾尝试「RepaintBoundary +
/// dstOut 叠加」免每帧离屏层（软件光栅下逐像素等价、测试通过），但真机上
/// dstOut 未被边界隔离、把该区域下层背景擦成深色块——已回退，不要再改。
/// 诊断开关：`ARCHOERA_COVER_MASK=off` 跳过遮罩（见 [coverMaskEnabled]）。
class PlayerFullscreenCover extends StatelessWidget {
  const PlayerFullscreenCover({super.key, required this.cover});

  /// 封面地址（同 [CoverImage]：URL / file:// / 磁盘路径；空则占位）。
  final String? cover;

  /// SPlayer `.full-cover` 的 mask 渐变：alpha 逐段非线性下降，避免暗色
  /// 封面上出现色阶/硬边（线性 0.5→0 的两段渐变会看到台阶）。
  static const List<double> _maskStops = [
    0.00, 0.10, 0.22, 0.32, 0.42, //
    0.52, 0.62, 0.72, 0.82, 0.92, 1.00,
  ];
  static const List<double> _maskAlphas = [
    1.00, 0.98, 0.92, 0.82, 0.68, //
    0.52, 0.36, 0.22, 0.10, 0.03, 0.00,
  ];

  /// 右缘渗入遮罩（保留量）。
  static final LinearGradient _mask = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [for (final a in _maskAlphas) Colors.white.withValues(alpha: a)],
    stops: _maskStops,
  );

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        final h = c.maxHeight;
        final shortSide = w < h ? w : h;
        final image = CoverImage(
          cover: cover,
          width: w,
          height: h,
          radius: 0,
          iconSize: (shortSide * 0.2).clamp(48.0, 140.0),
        );
        if (!coverMaskEnabled) return image;
        return ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (rect) => _mask.createShader(rect),
          child: image,
        );
      },
    );
  }
}
