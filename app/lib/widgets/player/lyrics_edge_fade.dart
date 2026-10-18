// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 歌词区上下渐隐遮罩（对齐 SPlayer-Next `.lyric-area` 的 mask）。
///
/// SPlayer 的取值不是 0→1 线性：
/// ```
/// linear-gradient(180deg,
///   0        0,
///   .6       5%,
///   1        10%,
///   1        75%,
///   .6       85%,
///   0        100%)
/// ```
/// 顶部只用 10% 完成淡入、底部 25% 淡出，中间大段保持完全不透明；比
/// 「上下各 25% 线性渐变」更干净，不会让歌词整体发灰。用 `ShaderMask`
/// （dstIn）实现，逐帧只做一次遮罩合成。
library;

import 'package:material_ui/material_ui.dart';

/// 歌词区上下渐隐（见库注释）。
class LyricsEdgeFade extends StatelessWidget {
  const LyricsEdgeFade({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (rect) => const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Color(0x00FFFFFF),
          Color(0x99FFFFFF), // 60%
          Color(0xFFFFFFFF),
          Color(0xFFFFFFFF),
          Color(0x99FFFFFF), // 60%
          Color(0x00FFFFFF),
        ],
        stops: [0, 0.05, 0.10, 0.75, 0.85, 1.0],
      ).createShader(rect),
      child: child,
    );
  }
}
