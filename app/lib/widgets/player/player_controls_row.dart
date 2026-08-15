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
        // 左组（左对齐）：红心 → 评论（对齐原版 FullPlayer 底栏左组顺序）
        Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              if (canLike)
                CtrlIcon(
                  tooltip: liked ? l10n.commonUnlike : l10n.commonLike,
                  icon: liked ? Icons.favorite : Icons.favorite_border,
                  size: 24,
                  color: liked
                      ? Colors.redAccent
                      : colorScheme.onSurfaceVariant,
                  onPressed: () => onToggleLike(current!),
                ),
              // 评论区（仅网易云/酷狗源，与红心同条件）
              if (canLike) ...[
                const SizedBox(width: 12),
                CtrlIcon(
                  tooltip: l10n.menuComment,
                  icon: Icons.mode_comment_outlined,
                  size: 24,
                  onPressed: onShowComments,
                ),
              ],
            ],
          ),
        ),
        // 中组：控制行 随机 | 上一首 | 播放 | 下一首 | 循环
        SizedBox(
          width: 380,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              CtrlIcon(
                tooltip: shuffle ? l10n.queueShuffleOff : l10n.queueShuffle,
                icon: Icons.shuffle,
                size: 20,
                color: shuffle
                    ? colorScheme.primary
                    : colorScheme.onSurfaceVariant,
                onPressed: hasContent ? notifier.toggleShuffle : null,
              ),
              const SizedBox(width: 12),
              CtrlIcon(
                tooltip: l10n.commonPrevious,
                icon: Icons.skip_previous,
                size: 26,
                color: colorScheme.onSurface,
                onPressed: hasQueue ? notifier.playPrevious : null,
              ),
              const SizedBox(width: 14),
              // 播放/暂停：主轴中心（透明底 + 填充圆 icon）
              Tooltip(
                message: buffering
                    ? l10n.commonLoading
                    : (playing ? l10n.commonPause : l10n.commonPlay),
                child: InkResponse(
                  radius: 28,
                  onTap: hasContent && !buffering ? notifier.toggle : null,
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Icon(
                          playing
                              ? Icons.pause_circle_filled
                              : Icons.play_circle_filled,
                          size: 48,
                          color: colorScheme.primary.withValues(
                            alpha: buffering ? 0.35 : 1,
                          ),
                        ),
                        if (buffering)
                          const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 3),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              CtrlIcon(
                tooltip: l10n.commonNext,
                icon: Icons.skip_next,
                size: 26,
                color: colorScheme.onSurface,
                onPressed: hasQueue ? notifier.playNext : null,
              ),
              const SizedBox(width: 12),
              CtrlIcon(
                tooltip: repeatMode == 'list'
                    ? l10n.queueRepeatList
                    : l10n.queueRepeatOne,
                icon: repeatMode == 'one' ? Icons.repeat_one : Icons.repeat,
                size: 20,
                color: colorScheme.primary,
                onPressed: hasContent ? notifier.cycleRepeatMode : null,
              ),
            ],
          ),
        ),
        // 右组（右对齐）：音量（滑条 + 静音）→ 播放列表
        Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              // 音量：悬浮式控件（hover 800ms 展开滑条，5s 未操作自动
              // 收起；独立 Consumer 订阅，拖动不重建整页）
              const HoverVolumeSlider(sliderWidth: 104),
              CtrlIcon(
                tooltip: l10n.playerBarPlaylist,
                icon: Icons.queue_music,
                size: 24,
                onPressed: hasQueue
                    ? () =>
                          QueuePanel.show(context, style: QueuePanelStyle.slide)
                    : null,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
