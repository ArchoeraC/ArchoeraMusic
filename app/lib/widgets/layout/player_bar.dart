// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../services/netease/track.dart';
import '../../services/playback/playback_notifier.dart';
import '../../services/lyrics/lyric_line.dart';
import '../../stores/app_prefs.dart';
import '../../stores/providers.dart';
import '../../stores/lyrics_provider.dart';
import '../../l10n/l10n.dart';
import '../../theme/app_theme.dart';
import '../../utils/format.dart';
import '../list/cover_image.dart';
import '../player/bar_lyric_text.dart';
import '../player/hover_volume_control.dart';
import '../player/playback_progress_slider.dart';
import '../player/queue_panel.dart';
import '../player/spectrum_view.dart';
import '../common/toast.dart';
import '../common/anim.dart';

part 'player_bar/player_bar_view.dart';
part 'player_bar/player_bar_sections.dart';
part 'player_bar/player_bar_widgets.dart';

/// 底部播放条（对齐原项目 PlayerBar.vue，应用壳常驻，§10.7）。
///
/// 布局：顶部进度条（拖动 seek，后端重启引擎）+
/// 主体行 = 左「封面 + 曲名/副标题」（点击展开全屏播放器）+ 播放控制
/// + 右「时间 + 迷你频谱」。
class PlayerBar extends ConsumerStatefulWidget {
  const PlayerBar({super.key});

  @override
  ConsumerState<PlayerBar> createState() => _PlayerBarState();
}

class _PlayerBarState extends ConsumerState<PlayerBar> {
  /// 拖动中的进度（ms）；null = 跟随播放器实时位置。
  double? _dragMs;

  @override
  Widget build(BuildContext context) => _buildPlayerBar(context);

  void _setDragMs(double? value) {
    setState(() => _dragMs = value);
  }

  void _clearDragMs() {
    setState(() => _dragMs = null);
  }
}
