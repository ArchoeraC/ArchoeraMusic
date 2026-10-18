// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../player_cover.dart';

/// 全屏封面布局（`coverLayout: fullscreen`）的左侧整幅封面。
///
/// 对齐原项目 FullPlayer 的全屏封面：封面铺满左侧整列（无圆角/阴影，
/// 播放暂停不做缩放），右缘渐隐融入背景。渐隐边界优先使用带低频噪声的
/// 片元着色器（`cover_mask.frag`），以横向直线为基础做轻微起伏，避免机械
/// 的直线；着色器不可用时回退到同形状的 `LinearGradient`。
class PlayerFullscreenCover extends StatefulWidget {
  const PlayerFullscreenCover({super.key, required this.cover});

  /// 封面地址（同 [CoverImage]：URL / file:// / 磁盘路径；空则占位）。
  final String? cover;

  @override
  State<PlayerFullscreenCover> createState() => _PlayerFullscreenCoverState();
}

class _PlayerFullscreenCoverState extends State<PlayerFullscreenCover> {
  ui.FragmentProgram? _program;
  bool _loadRequested = false;

  @override
  void initState() {
    super.initState();
    _ensureProgram();
  }

  void _ensureProgram() {
    if (_loadRequested) return;
    _loadRequested = true;
    CoverMaskShader.load().then((program) {
      if (!mounted || program == null) return;
      setState(() => _program = program);
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        final h = c.maxHeight;
        final shortSide = w < h ? w : h;
        return _mask(
          CoverImage(
            cover: widget.cover,
            width: w,
            height: h,
            radius: 0,
            iconSize: (shortSide * 0.2).clamp(48.0, 140.0),
          ),
        );
      },
    );
  }

  Widget _mask(Widget child) {
    final program = _program;
    if (program == null) {
      // 测试环境 / 着色器加载失败：回退到同形状的横向直线渐变。
      return ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (rect) => LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            Colors.white,
            Colors.white,
            Colors.white.withValues(alpha: 0.92),
            Colors.white.withValues(alpha: 0.65),
            Colors.white.withValues(alpha: 0.30),
            Colors.white.withValues(alpha: 0.10),
            Colors.white.withValues(alpha: 0),
            Colors.white.withValues(alpha: 0),
          ],
          stops: const [0, 0.45, 0.60, 0.72, 0.82, 0.88, 0.92, 1],
        ).createShader(rect),
        child: child,
      );
    }
    // 每首封面一个稳定相位，让弧线的起伏各不相同（同一封面切回来仍一致）。
    final seed = ((widget.cover?.hashCode ?? 0) & 0xFFFF) / 4096.0;
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (rect) {
        final shader = program.fragmentShader();
        shader
          ..setFloat(CoverMaskUniforms.size, rect.width)
          ..setFloat(CoverMaskUniforms.size + 1, rect.height)
          ..setFloat(CoverMaskUniforms.seed, seed);
        return shader;
      },
      child: child,
    );
  }
}
