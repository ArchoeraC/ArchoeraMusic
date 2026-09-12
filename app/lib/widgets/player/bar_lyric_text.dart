// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 播放条迷你歌词（时间下方；有歌词时替代迷你频谱）。
///
/// 显示当前行「原文（翻译）」；文本超宽时循环滚动（速度 30px/s、
/// 延迟 2s 启动、两段间距 50px）。
library;

import 'dart:async';
import 'dart:math';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/lyrics/lyric_line.dart';
import '../../services/playback/playback_notifier.dart';
import '../../stores/app_prefs.dart';
import '../../stores/lyrics_provider.dart';
import '../common/anim.dart';

part 'bar_lyric_text/bar_lyric_text_widgets.dart';

/// 迷你歌词（固定高度；无当前行时返回空占位，交由调用方回退频谱）。
class BarLyricText extends ConsumerStatefulWidget {
  const BarLyricText({super.key, required this.height});

  final double height;

  @override
  ConsumerState<BarLyricText> createState() => _BarLyricTextState();
}

class _BarLyricTextState extends ConsumerState<BarLyricText> {
  final Random _rand = Random();
  int _animMs = 180;
  int _lastIdx = -1;

  @override
  Widget build(BuildContext context) => _buildBarLyricText(context);
}

/// 卡拉OK 模式下已唱片段（`lineStartMs + f.startMs <= positionMs`）的累计
/// 文本宽度，用于跟随滚动时定位"当前字"的水平位置。
double _playedTextWidth(
  TextStyle style,
  List<LyricFragment> fragments,
  int lineStartMs,
  int positionMs,
) {
  final played = StringBuffer();
  for (final f in fragments) {
    if (lineStartMs + f.startMs <= positionMs) played.write(f.text);
  }
  if (played.isEmpty) return 0;
  return (TextPainter(
    text: TextSpan(text: played.toString(), style: style),
    maxLines: 1,
    textDirection: TextDirection.ltr,
  )..layout()).width;
}

/// 卡拉OK 超宽跟随滚动（三段式，对齐主流卡拉OK 歌词行为）：
/// - 开头：已唱不足半屏前，文本左对齐静止展示（dx = 0）；
/// - 中部：已唱过半屏后，当前高亮字随进度保持水平居中；
/// - 末尾：唱到尾字时文本右端停在「容器右缘 − em 安全间距」处，视觉上
///   仍贴齐时间「最后一位」。位移经 [TweenAnimationBuilder] 平滑过渡。
