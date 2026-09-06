// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 全屏播放器底部控制区（拆分自 player_page.dart 的 `_buildControlsRow`）。
///
/// 左组（红心）- 中组（随机/上一首/播放/下一首/循环）- 右组（音量/
/// 播放列表）。透明底、不凸显控件样式；播放控制经内部 Consumer 直接
/// 调用 playback notifier，红心切换经 [onToggleLike] 回由页面处理
/// （需登录提示）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../services/netease/track.dart';
import '../../../services/playback/playback_notifier.dart';
import 'ctrl_icon.dart';
import 'hover_volume_control.dart';
import 'queue_panel.dart';

part 'player_controls/player_controls_row_sections.dart';

/// 全屏播放器底部控制区（无状态；notifier 由内部读取）。
class PlayerControlsRow extends ConsumerWidget {
  const PlayerControlsRow({
    super.key,
    required this.hasContent,
    required this.hasQueue,
    required this.canLike,
    required this.liked,
    required this.current,
    required this.shuffle,
    required this.repeatMode,
    required this.playing,
    required this.buffering,
    required this.onToggleLike,
    required this.onShowComments,
  });

  /// 有内容 = 引擎源或在播/恢复的队列（模式切换可用）。
  final bool hasContent;

  final bool hasQueue;
  final bool canLike;
  final bool liked;
  final Track? current;
  final bool shuffle;
  final String repeatMode;
  final bool playing;
  final bool buffering;

  /// 红心切换（由页面处理失败提示）。
  final ValueChanged<Track> onToggleLike;

  /// 打开评论区（由页面处理，需当前曲目）。
  final VoidCallback onShowComments;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final notifier = ref.read(playbackProvider.notifier);
    return Row(
      children: [
        Expanded(
          child: _PlayerControlsLeftGroup(
            canLike: canLike,
            liked: liked,
            current: current,
            l10n: l10n,
            colorScheme: colorScheme,
            onToggleLike: onToggleLike,
            onShowComments: onShowComments,
          ),
        ),
        SizedBox(
          width: 380,
          child: _PlayerControlsCenterGroup(
            hasContent: hasContent,
            hasQueue: hasQueue,
            shuffle: shuffle,
            repeatMode: repeatMode,
            playing: playing,
            buffering: buffering,
            l10n: l10n,
            colorScheme: colorScheme,
            notifier: notifier,
          ),
        ),
        Expanded(
          child: _PlayerControlsRightGroup(
            hasQueue: hasQueue,
            l10n: l10n,
            onShowQueue: () =>
                QueuePanel.show(context, style: QueuePanelStyle.slide),
          ),
        ),
      ],
    );
  }
}
