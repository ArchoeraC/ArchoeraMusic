// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 全屏播放器歌词区（拆分自 player_page.dart 的 `_buildLyricsBlock`）。
///
/// 当前行居中高亮 + 点击 seek。独立 Consumer 订阅播放位置/歌词/样式
/// 偏好——50ms 位置更新只重建本区，不波及页面其余部分（对齐全屏
/// 播放器的性能设计）。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/lyrics/lyric_line.dart';
import '../../../services/playback/playback_notifier.dart';
import '../../../stores/app_prefs.dart';
import '../../../stores/lyrics_provider.dart';
import '../../../theme/cover_color.dart';
import 'lyrics_v7/lyrics_physics_wall.dart';
import 'lyrics_view.dart';
import 'package:archoera_music/eta/icon/eta_icons.dart';

/// 全屏播放器歌词区（无状态；位置/歌词/样式由内部 Consumer 订阅）。
class PlayerLyricsBlock extends ConsumerWidget {
  const PlayerLyricsBlock({
    super.key,
    required this.hasLyrics,
    required this.lyricScale,
    this.onSeek,
    this.dragMs,
  });

  /// 是否有歌词（无歌词显示空态占位图标）。
  final bool hasLyrics;

  /// 歌词字号/行高按窗口高度自适应的缩放系数。
  final double lyricScale;

  /// 点击歌词行 seek 回调（参数为毫秒；无可播源时为 null → 禁用点击）。
  final ValueChanged<int>? onSeek;

  /// 拖动进度条中的目标位置（毫秒）；null = 跟随播放器实时位置。
  ///
  /// 拖动时把该位置直接喂给歌词引擎，让**高亮与滚动跟随手指**（对齐 AMLL：
  /// 拖动进度条时高亮跟着走），同时冻结内部时钟——拖动位置是「用户目标」，
  /// 不能当成播放推进来外推。
  final double? dragMs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    if (!hasLyrics) {
      return Center(
        child: Icon(
          EtaIcons.fileMusicOutline,
          size: 64,
          color: colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
        ),
      );
    }
    final pos = ref.watch(
      playbackProvider.select((s) => s.position.inMilliseconds),
    );
    final playing = ref.watch(playbackProvider.select((s) => s.playing));
    // 拖动进度条时用「拖动位置」驱动歌词（高亮/滚动跟随手指），并冻结时钟：
    // 此时不是播放推进，不能让它外推。
    final drag = dragMs;
    final effPos = drag?.round() ?? pos;
    final effPlaying = drag == null && playing;
    final groups = ref
        .watch(currentLyricsProvider)
        .maybeWhen(data: (l) => l, orElse: () => const <LyricGroup>[]);
    final prefs = ref.watch(appPrefsProvider);
    // 自适应字号：随窗口高度缩放（关闭则固定 px）。
    final scale = prefs.lyricAdaptiveFontSize ? lyricScale : 1.0;
    final fontSize = prefs.lyricFontSize * scale;
    final lineHeight = prefs.lyricLineHeight * scale;
    final fontWeight = FontWeight.values.firstWhere(
      (w) => w.value == prefs.lyricFontWeight,
      orElse: () => FontWeight.w600,
    );
    // 高亮颜色优先级：跟随封面主色（强迫症） > 跟随软件主题色 > 自定义色。
    final coverAccent = ref.watch(coverColorProvider);
    final playedColor = (prefs.followCoverColor && coverAccent != null)
        ? coverAccent
        : (prefs.lyricFollowAccent
              ? colorScheme.primary
              : Color(prefs.lyricPlayedColor));
    final unplayedColor = Color(prefs.lyricUnplayedColor);
    // 全屏播放器始终显示翻译：设置项「显示翻译」仅作用于播放条迷你歌词
    // （见 bar_lyric_text_widgets.dart），不在此处受其控制。
    const showTranslation = true;
    // 引擎切换：simple（旧实现）/ amll（AMLL 歌词墙）
    final wall =
        prefs.lyricEngine == 'amll'
            ? AmllPhysicsWall(
                groups: groups,
                positionMs: effPos,
                playing: effPlaying, // 播放中时内部时钟按 vsync 插值
                // 字号与 simple 引擎一致：受「自适应字号」开关控制
                // （开启则随窗口高度缩放）。
                fontSize: fontSize,
                fontFamily: prefs.fontFamily,
                fontWeight: fontWeight,
                playedColor: playedColor,
                unplayedColor: unplayedColor,
                showTranslation: showTranslation,
                showRomanization: prefs.showRomanization,
                alignFraction: prefs.amllAlignFraction,
                inactiveAlpha: prefs.amllInactiveAlpha,
                wordSweep: prefs.amllWordSweep,
                hidePassed: prefs.amllHidePassed,
                enableScale: prefs.amllEnableScale,
                blurQuality: LyricsBlurQuality.parse(prefs.amllBlurQuality),
                springPreset: prefs.amllSpringPreset,
                animate: !ref.read(appPrefsProvider).performanceMode,
                onSeek: onSeek ?? (_) {},
              )
            : LyricsView(
                groups: groups,
                positionMs: effPos,
                fontSize: fontSize,
                lineHeight: lineHeight,
                fontWeight: fontWeight,
                playedColor: playedColor,
                unplayedColor: unplayedColor,
                showTranslation: showTranslation,
                showRomanization: prefs.showRomanization,
                onSeek: onSeek,
              );
    return ClipRect(child: wall);
  }
}
