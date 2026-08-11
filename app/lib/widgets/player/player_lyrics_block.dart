/// 全屏播放器歌词区（拆分自 player_page.dart 的 `_buildLyricsBlock`）。
///
/// 当前行居中高亮 + 点击 seek。独立 Consumer 订阅播放位置/歌词/样式
/// 偏好——50ms 位置更新只重建本区，不波及页面其余部分（对齐全屏
/// 播放器的性能设计）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/lyrics/lyric_line.dart';
import '../../../services/playback/playback_notifier.dart';
import '../../../stores/app_prefs.dart';
import '../../../stores/lyrics_provider.dart';
import 'lyrics_view.dart';

/// 全屏播放器歌词区（无状态；位置/歌词/样式由内部 Consumer 订阅）。
class PlayerLyricsBlock extends ConsumerWidget {
  const PlayerLyricsBlock({
    super.key,
    required this.hasLyrics,
    required this.lyricScale,
    this.onSeek,
  });

  /// 是否有歌词（无歌词显示空态占位图标）。
  final bool hasLyrics;

  /// 歌词字号/行高按窗口高度自适应的缩放系数。
  final double lyricScale;

  /// 点击歌词行 seek 回调（参数为毫秒；无可播源时为 null → 禁用点击）。
  final ValueChanged<int>? onSeek;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    if (!hasLyrics) {
      return Center(
        child: Icon(
          Icons.lyrics_outlined,
          size: 64,
          color: colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
        ),
      );
    }
    final pos = ref.watch(
      playbackProvider.select((s) => s.position.inMilliseconds),
    );
    final groups = ref
        .watch(currentLyricsProvider)
        .maybeWhen(data: (l) => l, orElse: () => const <LyricGroup>[]);
    final prefs = ref.watch(appPrefsProvider);
    return ClipRect(
      child: LyricsView(
        groups: groups,
        positionMs: pos,
        fontSize: prefs.lyricFontSize * lyricScale,
        lineHeight: prefs.lyricLineHeight * lyricScale,
        playedColor: Color(prefs.lyricPlayedColor),
        unplayedColor: Color(prefs.lyricUnplayedColor),
        showTranslation: prefs.showTranslation,
        onSeek: onSeek,
      ),
    );
  }
}
