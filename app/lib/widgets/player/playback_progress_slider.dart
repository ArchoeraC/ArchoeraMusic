import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/playback/playback_notifier.dart';
import '../../utils/format.dart';
import 'playback_slider.dart';

/// 播放进度条（播放条 / 全屏播放器共用）。
///
/// 内部独立订阅位置/时长（50ms 更新只重建本组件），统一处理 clamp、
/// 拖动与松手 seek（错误静默记入播放日志）；父组件通过 [onSeekEnd]
/// 在松手后清理自己的拖动态（如 _dragMs = null）。
class PlaybackProgressSlider extends ConsumerWidget {
  const PlaybackProgressSlider({
    super.key,
    this.showTimes = false,
    this.textStyle,
    this.dragMs,
    this.buffering = false,
    this.enabled = true,
    required this.onDragChanged,
    required this.onSeekEnd,
  });

  /// 是否同时展示左右时间（全屏播放器：pos / dur）；false = 仅滑块。
  final bool showTimes;
  final TextStyle? textStyle;

  /// 拖动中的进度（ms）；null = 跟随播放器实时位置。
  final double? dragMs;
  final bool buffering;

  /// 是否有可播放源（无源时禁用拖动）。
  final bool enabled;
  final ValueChanged<double> onDragChanged;

  /// 松手 seek 完成后的回调（父组件清理拖动态）。
  final ValueChanged<double> onSeekEnd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(playbackProvider.notifier);
    final s = ref.watch(
      playbackProvider.select((s) => (pos: s.position, dur: s.duration)),
    );
    final durMs = s.dur.inMilliseconds;
    final ms = (dragMs ?? s.pos.inMilliseconds)
        .clamp(0, durMs < 1 ? 1 : durMs)
        .toDouble();
    final slider = PlaybackSlider(
      value: ms,
      max: durMs < 1 ? 1 : durMs.toDouble(),
      buffering: buffering,
      onChanged: enabled ? onDragChanged : null,
      onChangeEnd: enabled
          ? (v) async {
              onSeekEnd(v);
              try {
                await notifier.seek(Duration(milliseconds: v.round()));
              } catch (_) {
                // 错误已记入播放日志
              }
            }
          : null,
    );
    if (!showTimes) return slider;
    return Row(
      children: [
        Text(formatClock(s.pos), style: textStyle),
        Expanded(child: slider),
        Text(formatClock(s.dur), style: textStyle),
      ],
    );
  }
}
