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
/// - 不渲染页面共享底栏（控制已经在封面下方）。
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
import '../../../widgets/list/cover_image.dart';
import '../../../widgets/player/playback_progress_slider.dart';
import '../../../widgets/player/player_lyrics_block.dart';
import '../../../widgets/player/player_lyrics_slot.dart';
import 'player_layout.dart';

import 'package:archoera_music/eta/icon/eta_icons.dart';

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
    return LayoutBuilder(
      builder: (context, box) {
        final maxByWidth = (box.maxWidth * coverWidthFraction).clamp(
          180.0,
          460.0,
        );
        final coverSize = (box.maxHeight * coverHeightFraction).clamp(
          180.0,
          maxByWidth,
        );
        return RepaintBoundary(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 左栏：封面 + 信息 + 进度/控制/音量（整体垂直居中）。
              Expanded(
                child: Center(
                  child: SizedBox(
                    width: coverSize,
                    child: _VutronLeftColumn(size: coverSize, ctx: c),
                  ),
                ),
              ),
              // 右栏：歌词容器取 90% 宽并右对齐（对齐 `.main-lyric-container`）。
              Expanded(
                child: FractionallySizedBox(
                  alignment: Alignment.centerRight,
                  widthFactor: 0.9,
                  child: PlayerLyricsSlot(
                    visible: c.showLyrics,
                    enabled: c.contentMounted && c.hasLyrics,
                    builder: (_) => RepaintBoundary(
                      child: PlayerLyricsBlock(
                        hasLyrics: c.hasLyrics,
                        // 字号由 vutron 预设接管（720p=28px 起随高度缩放）。
                        lyricScale: 1,
                        presentation: PlayerLyricsPresentation.vutron,
                        textAlign: lyricsAlign,
                        onSeek: c.onSeekLyric,
                        dragMs: c.dragMs,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 封面（圆角 12；投影用 BoxShadow，不复制图片做模糊）。
        DecoratedBox(
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
        const SizedBox(height: 22),
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
        const SizedBox(height: 18),
        // 进度条（4px 轨道 / 时间 15px，对齐 .progress-bar）。
        PlaybackProgressSlider(
          showTimes: true,
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
        _VutronVolume(size: size),
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
      required double alpha,
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
      color: scheme.onSurface.withValues(alpha: alpha),
      icon: Icon(icon),
    );

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        control(
          icon: state.repeat == 'one' ? EtaIcons.repeatOne : EtaIcons.repeat,
          tooltip: l10n.queueRepeatMode,
          iconSize: 16,
          alpha: state.repeat == 'off' ? 0.38 : 0.88,
          onPressed: state.hasContent ? notifier.cycleRepeatMode : null,
        ),
        control(
          icon: EtaIcons.skipPrevious,
          tooltip: l10n.commonPrevious,
          iconSize: 24,
          alpha: 0.88,
          onPressed: canPrevNext ? notifier.playPrevious : null,
        ),
        IconButton(
          tooltip: state.playing ? l10n.commonPause : l10n.commonPlay,
          onPressed: state.hasContent && !state.buffering
              ? notifier.toggle
              : null,
          iconSize: 40,
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          constraints: BoxConstraints(
            minWidth: (size / 5).clamp(40.0, 56.0),
            minHeight: 48,
          ),
          color: scheme.onSurface.withValues(alpha: 0.92),
          icon: Icon(
            state.playing ? EtaIcons.pauseCircle : EtaIcons.playCircle,
          ),
        ),
        control(
          icon: EtaIcons.skipForward,
          tooltip: l10n.commonNext,
          iconSize: 24,
          alpha: 0.88,
          onPressed: canPrevNext ? notifier.playNext : null,
        ),
        control(
          icon: EtaIcons.shuffle,
          tooltip: state.shuffle ? l10n.queueShuffleOff : l10n.queueShuffle,
          iconSize: 16,
          alpha: state.shuffle ? 0.88 : 0.38,
          onPressed: state.hasContent ? notifier.toggleShuffle : null,
        ),
      ],
    );
  }
}

/// 音量行：图标 + 轨道（对齐 Vutron 第二条 .progress-bar）。
class _VutronVolume extends ConsumerWidget {
  const _VutronVolume({required this.size});

  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final volume = ref.watch(playbackProvider.select((s) => s.volume));
    final notifier = ref.read(playbackProvider.notifier);
    final muted = volume <= 0.001;
    return Row(
      children: [
        IconButton(
          tooltip: muted ? context.l10n.volumeUnmute : context.l10n.volumeMute,
          onPressed: () => unawaited(notifier.setVolume(muted ? 0.7 : 0)),
          iconSize: 16,
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 24, minHeight: 32),
          color: scheme.onSurface.withValues(alpha: 0.58),
          icon: Icon(muted ? EtaIcons.volumeOff : EtaIcons.volume),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: _VutronVolumeBar(
            value: volume.clamp(0.0, 1.0),
            onChanged: notifier.previewVolume,
            onChangeEnd: (v) => unawaited(notifier.setVolume(v)),
          ),
        ),
      ],
    );
  }
}

/// 精简音量条：2px 圆角轨道 + 6px 圆点，20px 高命中区。
///
/// Vutron 的音量条是一条细线，Material [Slider]（3px 轨道 + 10px 圆点 +
/// 56px 高命中区）在左栏里显得过粗，因此这里自绘一条更轻的轨道；拖动时
/// 只预览（引擎命令合并），松手落盘，与页面其它音量控件语义一致。
class _VutronVolumeBar extends StatelessWidget {
  const _VutronVolumeBar({
    required this.value,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final double value;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  static const double _trackInset = 4;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, box) {
        double valueAt(Offset local) {
          final usable = (box.maxWidth - _trackInset * 2).clamp(
            1.0,
            double.infinity,
          );
          return ((local.dx - _trackInset) / usable).clamp(0.0, 1.0);
        }

        return MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) {
              final v = valueAt(d.localPosition);
              onChanged(v);
              onChangeEnd(v);
            },
            onHorizontalDragStart: (d) => onChanged(valueAt(d.localPosition)),
            onHorizontalDragUpdate: (d) => onChanged(valueAt(d.localPosition)),
            // 拖动期间父层已通过 previewVolume 更新 value，松手落盘当前值。
            onHorizontalDragEnd: (_) => onChangeEnd(value),
            child: SizedBox(
              height: 20,
              child: CustomPaint(
                painter: _VutronVolumeBarPainter(
                  value: value.clamp(0.0, 1.0),
                  active: scheme.onSurface.withValues(alpha: 0.80),
                  inactive: scheme.onSurface.withValues(alpha: 0.18),
                  thumb: scheme.onSurface.withValues(alpha: 0.90),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _VutronVolumeBarPainter extends CustomPainter {
  const _VutronVolumeBarPainter({
    required this.value,
    required this.active,
    required this.inactive,
    required this.thumb,
  });

  final double value;
  final Color active;
  final Color inactive;
  final Color thumb;

  @override
  void paint(Canvas canvas, Size size) {
    const inset = _VutronVolumeBar._trackInset;
    const trackHeight = 2.0;
    final left = inset;
    final width = (size.width - inset * 2).clamp(0.0, double.infinity);
    final cy = size.height / 2;
    final track = RRect.fromLTRBR(
      left,
      cy - trackHeight / 2,
      left + width,
      cy + trackHeight / 2,
      const Radius.circular(trackHeight / 2),
    );
    canvas.drawRRect(track, Paint()..color = inactive);
    final filled = width * value;
    if (filled > 0) {
      canvas.drawRRect(
        RRect.fromLTRBR(
          left,
          cy - trackHeight / 2,
          left + filled,
          cy + trackHeight / 2,
          const Radius.circular(trackHeight / 2),
        ),
        Paint()..color = active,
      );
    }
    canvas.drawCircle(Offset(left + filled, cy), 3, Paint()..color = thumb);
  }

  @override
  bool shouldRepaint(_VutronVolumeBarPainter old) =>
      old.value != value ||
      old.active != active ||
      old.inactive != inactive ||
      old.thumb != thumb;
}
