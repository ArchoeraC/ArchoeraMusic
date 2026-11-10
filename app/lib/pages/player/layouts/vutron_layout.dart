// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// VutronMusic 经典播放页布局（`vutron`）。
///
/// 对齐 VutronMusic Classic（`CommonPlayer.vue` / `LyricPage.vue`）：
/// - 页面左右两栏各占一半；左栏整体垂直居中，内容左对齐；
/// - 左栏：正方形封面（圆角 12 + 投影）→ 标题 / 副标题 → 进度条 →
///   播放控制（循环 / 上一首 / 播放 / 下一首 / 随机）→ 音量；
/// - 右栏：歌词列表取右栏宽度的 90% 并右对齐，文字左对齐；当前行 95%
///   前景色、其余行 28%，非当前行缩到 0.95；上下 25% 渐隐；
/// - 不渲染页面共享底栏（控制已经在封面下方），但底部单独保留一条细频谱，
///   与其它布局同样消费引擎 `fft` 事件（关闭「频谱可视化」/性能模式时零高度）。
///
/// 低开销取舍：封面投影用 [BoxShadow]（不再复制一张封面做 blur）；歌词复用
/// [PlayerLyricsBlock] 的共享取色/引擎入口（Vutron 预设强制 simple 列表），
/// 只增加左对齐/缩放/遮罩参数；没有逐帧滤镜。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../services/playback/playback_notifier.dart';
import '../../../stores/app_prefs.dart';
import '../../../widgets/common/anim.dart';
import '../../../widgets/list/cover_image.dart';
import '../../../widgets/player/playback_progress_slider.dart';
import '../../../widgets/player/playback_slider.dart';
import '../../../widgets/player/play_pause_button.dart';
import '../../../widgets/player/player_lyrics_block.dart';
import '../../../widgets/player/player_lyrics_slot.dart';
import '../../../widgets/player/player_shared_elements.dart';
import '../../../widgets/player/player_slider_row.dart';
import '../../../widgets/player/spectrum_view.dart';
import 'player_layout.dart';

import 'package:archoera_music/eta/icon/eta_icons.dart';

/// Vutron 两条滑杆的统一轨道粗细（主题默认 3px，按设计稿略粗一档）。
const double _barTrackHeight = 4;

class VutronPlayerLayout extends PlayerLayout {
  const VutronPlayerLayout();

  static const String layoutId = 'vutron';

  /// 封面占主体高度的比例（对齐截图 ≈54vh）。
  static const double coverHeightFraction = 0.54;

  /// 封面占主体宽度的上限（对齐截图 ≈36vw）。
  static const double coverWidthFraction = 0.38;

  @override
  String get id => layoutId;

  /// 控制区在左栏内，不使用页面共享底栏。
  @override
  bool get usesDefaultBottomBar => false;

  /// 经典布局：歌词（含 AMLL 物理墙）左对齐。
  @override
  TextAlign get lyricsAlign => TextAlign.left;

  @override
  Widget buildBody(BuildContext context, PlayerLayoutContext c) {
    // 页面共享底栏（含 90px 频谱）在 vutron 布局下不渲染，底部单独补一条
    // 细频谱，避免该布局完全没有可视化（与其它布局同源：引擎 fft 事件）。
    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, box) {
              final maxByWidth = (box.maxWidth * coverWidthFraction).clamp(
                180.0,
                460.0,
              );
              final coverSize = (box.maxHeight * coverHeightFraction).clamp(
                180.0,
                maxByWidth,
              );
              // 关闭歌词（或没有歌词）时右栏没有内容；开启自动居中时把
              // 左栏整体移到页面中心。用 AnimatedAlign 而不是替换整棵
              // Row：切换时左栏平滑平移，歌词槽同时下滑卸载。
              final showLyrics = c.showLyrics && c.hasLyrics;
              final centered = !showLyrics && c.autoCenterCover;
              return RepaintBoundary(
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // 右栏：歌词容器取右半宽度的 90% 并右对齐
                    // （对齐 `.main-lyric-container`）；显隐由槽负责滑入/滑出。
                    Positioned(
                      top: 0,
                      bottom: 0,
                      right: 0,
                      width: box.maxWidth * 0.5,
                      child: FractionallySizedBox(
                        alignment: Alignment.centerRight,
                        widthFactor: 0.9,
                        child: PlayerLyricsSlot(
                          visible: c.showLyrics,
                          enabled: c.contentMounted && c.hasLyrics,
                          builder: (_) => PlayerSharedElementBoundary(
                            kind: PlayerSharedElement.lyrics,
                            boundaryKey:
                                c.sharedKeys[PlayerSharedElement.lyrics],
                            child: PlayerLyricsBlock(
                              hasLyrics: c.hasLyrics,
                              // 字号由 vutron 预设接管（720p=28px 起随高度缩放）。
                              lyricScale: 1,
                              presentation: PlayerLyricsPresentation.vutron,
                              textAlign: lyricsAlign,
                              fadeEdges: true,
                              onSeek: c.onSeekLyric,
                              dragMs: c.dragMs,
                            ),
                          ),
                        ),
                      ),
                    ),
                    // 左栏：封面 + 信息 + 进度/控制/音量。
                    // 有歌词 → 左半区居中（Alignment(-0.5) = 全宽 25%）；
                    // 无歌词且自动居中 → 整页中心，600ms ease-out 平移。
                    Positioned.fill(
                      child: AnimatedAlign(
                        alignment: centered
                            ? Alignment.center
                            : const Alignment(-0.5, 0),
                        duration: animDuration(
                          context,
                          const Duration(milliseconds: 600),
                        ),
                        curve: kPlayerLayoutTransitionCurve,
                        child: SizedBox(
                          width: coverSize,
                          child: _VutronLeftColumn(size: coverSize, ctx: c),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        const _VutronSpectrum(),
      ],
    );
  }
}

/// vutron 布局底部的细频谱条。
///
/// 关闭「频谱可视化」/ 性能模式时返回零高度，不改变左栏排版。
class _VutronSpectrum extends ConsumerWidget {
  const _VutronSpectrum();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(appPrefsProvider);
    if (!prefs.enableSpectrum || prefs.performanceMode) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 2),
      child: RepaintBoundary(child: SpectrumView(height: 40, opacity: 0.45)),
    );
  }
}

/// 左栏：封面、标题/副标题、进度、控制、音量。
class _VutronLeftColumn extends StatelessWidget {
  const _VutronLeftColumn({required this.size, required this.ctx});

  final double size;
  final PlayerLayoutContext ctx;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final title = ctx.hasContent
        ? (ctx.title.isEmpty ? ctx.l10n.playerBarUntitled : ctx.title)
        : ctx.l10n.playerPageNotPlaying;
    final subtitle = ctx.hasContent ? ctx.subtitle : '';
    final info = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 标题 / 副标题（对齐 .top-part：20/600/.88、14/.70）。
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            color: scheme.onSurface.withValues(alpha: 0.88),
          ),
        ),
        if (subtitle.isNotEmpty) ...[
          const SizedBox(height: 3),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 14,
              color: scheme.onSurface.withValues(alpha: 0.70),
            ),
          ),
        ],
      ],
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 封面（圆角 12；投影用 BoxShadow，不复制图片做模糊）。
        PlayerSharedElementBoundary(
          kind: PlayerSharedElement.cover,
          boundaryKey: ctx.sharedKeys[PlayerSharedElement.cover],
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.35),
                  blurRadius: 28,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            child: CoverImage(
              cover: ctx.current?.cover,
              width: size,
              height: size,
              radius: 12,
              iconSize: (size * 0.28).clamp(48.0, 120.0),
            ),
          ),
        ),
        const SizedBox(height: 22),
        PlayerSharedElementBoundary(
          kind: PlayerSharedElement.info,
          boundaryKey: ctx.sharedKeys[PlayerSharedElement.info],
          child: info,
        ),
        const SizedBox(height: 18),
        // 进度条（细轨道 / 时间 15px，对齐 .progress-bar）。
        PlaybackProgressSlider(
          showTimes: true,
          // 与音量条共用固定时间槽宽 → 两条轨道左右边缘对齐。
          timeGutter: PlayerSliderRow.defaultGutter,
          // 比主题默认 3px 略粗（对齐 SPlayer-Next 的轨道观感）。
          trackHeight: _barTrackHeight,
          // 纯条：不显示高亮球（静止/悬停/拖动都不画）。
          showThumb: false,
          textStyle: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: scheme.onSurface.withValues(alpha: 0.58),
          ),
          dragMs: ctx.dragMs,
          buffering: ctx.buffering,
          enabled: ctx.hasSource,
          onDragChanged: ctx.onDragChanged,
          onSeekEnd: ctx.onSeekEnd,
        ),
        const SizedBox(height: 10),
        _VutronControls(size: size),
        const SizedBox(height: 8),
        const _VutronVolume(),
      ],
    );
  }
}

/// 播放控制：循环 / 上一首 / 播放 / 下一首 / 随机（对齐 .media-controls）。
class _VutronControls extends ConsumerWidget {
  const _VutronControls({required this.size});

  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final state = ref.watch(
      playbackProvider.select(
        (s) => (
          playing: s.playing,
          buffering: s.buffering,
          shuffle: s.shuffle,
          repeat: s.repeatMode,
          hasQueue: s.hasQueue,
          hasContent: s.source != null || s.hasQueue,
        ),
      ),
    );
    final notifier = ref.read(playbackProvider.notifier);
    final canPrevNext = state.hasQueue && !state.buffering;

    Widget control({
      required IconData icon,
      required String tooltip,
      required double iconSize,
      required Color color,
      VoidCallback? onPressed,
    }) => IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      iconSize: iconSize,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: BoxConstraints(
        minWidth: (size / 6).clamp(30.0, 48.0),
        minHeight: 40,
      ),
      color: color,
      icon: Icon(icon),
    );

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        control(
          icon: state.repeat == 'one' ? EtaIcons.repeatOne : EtaIcons.repeat,
          tooltip: l10n.queueRepeatMode,
          iconSize: 16,
          // 与页面其它控制一致：循环开启 → 主题色，顺序播放压暗。
          color: state.repeat == 'off'
              ? scheme.onSurfaceVariant
              : scheme.primary,
          onPressed: state.hasContent ? notifier.cycleRepeatMode : null,
        ),
        control(
          icon: EtaIcons.skipPrevious,
          tooltip: l10n.commonPrevious,
          iconSize: 24,
          color: scheme.onSurface,
          onPressed: canPrevNext ? notifier.playPrevious : null,
        ),
        // 播放键与其它布局一致使用主题色（缓冲时压暗）；形状为椭圆胶囊。
        PlayPauseButton(
          playing: state.playing,
          buffering: state.buffering,
          tooltip: state.playing ? l10n.commonPause : l10n.commonPlay,
          onPressed: state.hasContent ? notifier.toggle : null,
        ),
        control(
          icon: EtaIcons.skipForward,
          tooltip: l10n.commonNext,
          iconSize: 24,
          color: scheme.onSurface,
          onPressed: canPrevNext ? notifier.playNext : null,
        ),
        control(
          icon: EtaIcons.shuffle,
          tooltip: state.shuffle ? l10n.queueShuffleOff : l10n.queueShuffle,
          iconSize: 16,
          color: state.shuffle ? scheme.primary : scheme.onSurfaceVariant,
          onPressed: state.hasContent ? notifier.toggleShuffle : null,
        ),
      ],
    );
  }
}

/// 音量行：图标 + 轨道（与进度条共用 [PlayerSliderRow] 栅格与
/// [PlaybackSlider] 样式，两条轨道左右边缘严格对齐）。
class _VutronVolume extends ConsumerWidget {
  const _VutronVolume();

  /// 音量行高度：比进度条更紧凑，轨道在其中垂直居中。
  static const double _barHeight = 32;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final volume = ref.watch(playbackProvider.select((s) => s.volume));
    final notifier = ref.read(playbackProvider.notifier);
    final muted = volume <= 0.001;
    return PlayerSliderRow(
      leading: IconButton(
        tooltip: muted ? context.l10n.volumeUnmute : context.l10n.volumeMute,
        onPressed: () => unawaited(notifier.setVolume(muted ? 0.7 : 0)),
        iconSize: 16,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 24, minHeight: 32),
        color: scheme.onSurface.withValues(alpha: 0.58),
        icon: Icon(muted ? EtaIcons.volumeOff : EtaIcons.volume),
      ),
      track: PlaybackSlider(
        value: volume.clamp(0.0, 1.0),
        max: 1,
        buffering: false,
        showTooltip: false,
        height: _barHeight,
        trackHeight: _barTrackHeight,
        // 纯条：音量也不显示高亮球。
        showThumb: false,
        // 音量不是「进度」：关闭愚人节的反向映射。
        allowPrank: false,
        onChanged: notifier.previewVolume,
        onChangeEnd: (v) => unawaited(notifier.setVolume(v)),
      ),
    );
  }
}
