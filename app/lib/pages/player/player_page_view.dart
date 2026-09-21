// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// ignore_for_file: invalid_use_of_protected_member

part of '../player_page.dart';

extension _PlayerPageView on _PlayerPageState {
  Widget _buildPage(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = context.l10n;
    final notifier = ref.read(playbackProvider.notifier);
    final hasSource = ref.watch(
      playbackProvider.select((s) => s.source != null),
    );
    final source = ref.watch(playbackProvider.select((s) => s.source));
    final current = ref.watch(playbackProvider.select((s) => s.track));
    final title = ref.watch(playbackProvider.select((s) => s.title)) ?? '';
    final subtitle =
        ref.watch(playbackProvider.select((s) => s.subtitle)) ?? '';
    final quality = ref.watch(playbackProvider.select((s) => s.quality));
    final buffering = ref.watch(playbackProvider.select((s) => s.buffering));
    final playing = ref.watch(playbackProvider.select((s) => s.playing));
    final shuffle = ref.watch(playbackProvider.select((s) => s.shuffle));
    final repeatMode = ref.watch(playbackProvider.select((s) => s.repeatMode));
    final hasQueue = ref.watch(playbackProvider.select((s) => s.hasQueue));
    final hasContent = hasSource || hasQueue;
    ref.listen(playbackProvider.select((s) => s.queueIndex), (prev, next) {
      if (prev != null && prev != next) {
        _slideNext = next > prev;
      }
    });
    ref.listen(playbackProvider.select((s) => s.fft), (prev, next) {
      final p = ref.read(appPrefsProvider);
      if (!p.coverBeatScale || p.performanceMode) return;
      final strength = next?.beatStrength ?? 0;
      if (strength <= 0) return;
      _lastBeatStrength = strength;
      _coverPulse.forward(from: 0);
    });
    final canLike =
        current != null &&
        (current.source == 'netease' ||
            current.source == 'kugou' ||
            current.source == 'qqmusic' ||
            current.source == 'neko');
    final liked = canLike
        ? ref.watch(likeControllerProvider).isLiked(current)
        : false;

    final prefs = ref.watch(appPrefsProvider);
    final showLyrics = prefs.showLyricsInPlayer;
    final transitionStyle = prefs.transitionStyle;
    final coverLayout = prefs.coverLayout;
    final coverLyricRatio = prefs.coverLyricRatio;
    final autoCenterCover = prefs.autoCenterCover;
    final autoImmersive = prefs.autoImmersive;
    // 重内容（背景 / 歌词）在路由进入动画结束后才挂载；性能模式直切视为已完成。
    final contentMounted =
        _contentMounted ||
        (MediaQuery.maybeDisableAnimationsOf(context) ?? false);
    final hasLyrics = ref
        .watch(currentLyricsProvider)
        .maybeWhen(data: (l) => l.isNotEmpty, orElse: () => false);

    // 播放页常驻不透明底色：重内容（背景）延迟挂载期间也保证整页不透明，
    // 避免透出下方壳层（进入动画那 500ms 出现白/黑空档）。
    final playerBg =
        theme.extension<AppChromeColors>()?.playerBackground ??
        colorScheme.surface;
    return Scaffold(
      backgroundColor: playerBg,
      // 硬裁切到播放页范围（对齐原版 FullPlayer 根节点 `overflow-hidden`）：
      // 封面背景经 blur/scale 后的绘制不会溢出到播放页之外。
      body: MouseRegion(
        onEnter: (_) {
          if (!mounted) return;
          if (!_pointerInside) setState(() => _pointerInside = true);
          _pokeControls();
        },
        onExit: (_) {
          if (!mounted) return;
          setState(() => _pointerInside = false);
          // 自动沉浸：指针离开窗口立即隐藏控件（含顶栏）。
          if (ref.read(appPrefsProvider).autoImmersive) {
            _hideTimer?.cancel();
            setState(() => _controlsVisible = false);
          }
        },
        cursor: (autoImmersive && !_controlsVisible)
            ? SystemMouseCursors.none
            : MouseCursor.defer,
        child: ClipRect(
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerHover: (_) => _pokeControls(),
            onPointerDown: (_) => _pokeControls(),
            onPointerSignal: (_) => _pokeControls(),
            child: Stack(
              children: [
                Positioned.fill(child: ColoredBox(color: playerBg)),
                if (contentMounted)
                  Positioned.fill(
                    child: PlayerBackground(
                      cover: current?.cover,
                      playing: playing,
                    ),
                  ),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Column(
                      children: [
                        // 自动沉浸：控件隐藏时顶栏一并淡出（普通模式顶栏常驻）。
                        AnimatedOpacity(
                          opacity: (!autoImmersive || _controlsVisible) ? 1 : 0,
                          duration: animDuration(
                            context,
                            const Duration(milliseconds: 300),
                          ),
                          curve: Curves.easeOut,
                          child: IgnorePointer(
                            ignoring: autoImmersive && !_controlsVisible,
                            child: _PlayerTopBar(
                              l10n: l10n,
                              showLyrics: showLyrics,
                              hasLyrics: hasLyrics,
                              colorScheme: colorScheme,
                              current: current,
                              quality: quality,
                              isFullScreen: _isFullScreen,
                              onClose: () => context.pop(),
                              onToggleLyrics: hasLyrics
                                  ? () => ref
                                        .read(appPrefsProvider.notifier)
                                        .setShowLyricsInPlayer(!showLyrics)
                                  : null,
                              onSelectQuality: notifier.setQuality,
                              onToggleFullscreen: _toggleFullscreen,
                            ),
                          ),
                        ),
                        Expanded(
                          child: _PlayerMainBody(
                            source: source,
                            current: current,
                            title: title,
                            subtitle: subtitle,
                            playing: playing,
                            hasContent: hasContent,
                            hasLyrics: hasLyrics,
                            hasSource: hasSource,
                            showLyrics: showLyrics,
                            contentMounted: contentMounted,
                            transitionStyle: transitionStyle,
                            coverLayout: coverLayout,
                            coverLyricRatio: coverLyricRatio,
                            autoCenterCover: autoCenterCover,
                            slideNext: _slideNext,
                            coverPulse: _coverPulse,
                            beatStrength: _lastBeatStrength,
                            l10n: l10n,
                            dragMs: _dragMs,
                            onSeekLyric: hasSource
                                ? (ms) =>
                                      notifier.seek(Duration(milliseconds: ms))
                                : null,
                          ),
                        ),
                        Text(
                          !hasContent
                              ? l10n.playerPageLoadHint
                              : (buffering ? l10n.playerBarBuffering : ''),
                          style: theme.textTheme.bodySmall,
                        ),
                        _PlayerBottomOverlay(
                          controlsVisible: _controlsVisible,
                          theme: theme,
                          dragMs: _dragMs,
                          buffering: buffering,
                          hasSource: hasSource,
                          hasContent: hasContent,
                          hasQueue: hasQueue,
                          canLike: canLike,
                          liked: liked,
                          current: current,
                          shuffle: shuffle,
                          repeatMode: repeatMode,
                          playing: playing,
                          showProgressLyric: prefs.showProgressLyric,
                          onDragChanged: (v) => setState(() => _dragMs = v),
                          onSeekEnd: (_) => setState(() => _dragMs = null),
                          onToggleLike: _toggleLike,
                          onShowComments: () {
                            if (current != null) {
                              showCommentDialog(context, track: current);
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PlayerTopBar extends StatelessWidget {
  const _PlayerTopBar({
    required this.l10n,
    required this.showLyrics,
    required this.hasLyrics,
    required this.colorScheme,
    required this.current,
    required this.quality,
    required this.isFullScreen,
    required this.onClose,
    required this.onToggleLyrics,
    required this.onSelectQuality,
    required this.onToggleFullscreen,
  });

  final AppLocalizations l10n;
  final bool showLyrics;
  final bool hasLyrics;
  final ColorScheme colorScheme;
  final Track? current;
  final String quality;
  final bool isFullScreen;
  final VoidCallback onClose;
  final VoidCallback? onToggleLyrics;
  final ValueChanged<String> onSelectQuality;
  final Future<void> Function() onToggleFullscreen;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: Row(
        children: [
          IconButton(
            tooltip: l10n.playerBarCollapsePlayer,
            onPressed: onClose,
            icon: const Icon(EtaIcons.downSmall),
            iconSize: 32,
          ),
          const SizedBox(width: 4),
          Tooltip(
            message: showLyrics
                ? l10n.playerBarHideLyrics
                : l10n.playerBarShowLyrics,
            child: InkResponse(
              radius: 24,
              onTap: onToggleLyrics,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Icon(
                  EtaIcons.fileMusicOutline,
                  size: 26,
                  color:
                      (showLyrics
                              ? colorScheme.primary
                              : colorScheme.onSurfaceVariant)
                          .withValues(alpha: hasLyrics ? 1 : 0.35),
                ),
              ),
            ),
          ),
          const Spacer(),
          const _SleepTimerButton(),
          // Neko 为直传原文件、无音质档：不展示无意义的音质切换。
          if (current != null && current!.source != 'neko')
            QualityMenu(
              levels: _PlayerPageState._availableLevels(current),
              current: quality,
              onSelected: onSelectQuality,
            ),
          Tooltip(
            message: isFullScreen
                ? l10n.playerBarExitFullscreen
                : l10n.playerBarFullscreen,
            child: IconButton(
              onPressed: onToggleFullscreen,
              icon: Icon(
                isFullScreen ? EtaIcons.fullscreenExit : EtaIcons.fullscreen,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 睡眠定时按钮（播放页顶栏）：预设倒计时 / 自定义 / 播完当前曲 /
/// 到时播完再暂停 / 关闭。
class _SleepTimerButton extends ConsumerWidget {
  const _SleepTimerButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final timer = ref.watch(sleepTimerProvider);
    final prefs = ref.watch(appPrefsProvider);
    final finishTrack = prefs.sleepFinishTrack;
    final remaining = timer.mode == SleepMode.duration
        ? formatClock(timer.remaining)
        : '';
    final tooltip = timer.mode == SleepMode.endOfTrack
        ? l10n.sleepTimerEndOfTrack
        : timer.active
        ? '${l10n.sleepTimer} · $remaining'
        : l10n.sleepTimer;
    return PopupMenuButton<String>(
      tooltip: tooltip,
      icon: Icon(
        EtaIcons.stopwatchOutline,
        color: timer.active ? Theme.of(context).colorScheme.primary : null,
      ),
      onSelected: (v) async {
        final n = ref.read(sleepTimerProvider.notifier);
        if (v == 'finishTrack') {
          ref.read(appPrefsProvider.notifier).setSleepFinishTrack(!finishTrack);
          return;
        }
        if (v == 'off') {
          n.cancel();
          return;
        }
        if (v == 'eot') {
          n.startEndOfTrack();
          return;
        }
        if (v == 'custom') {
          final initial = prefs.sleepTimerCustomMinutes ?? 30;
          final m = await showSleepTimerMinutesDialog(
            context,
            initialMinutes: initial,
          );
          if (m == null) return;
          ref.read(appPrefsProvider.notifier).setSleepTimerCustomMinutes(m);
          n.startDuration(Duration(minutes: m));
          return;
        }
        if (v.startsWith('min:')) {
          final m = int.tryParse(v.substring(4));
          if (m != null) n.startDuration(Duration(minutes: m));
        }
      },
      itemBuilder: (context) => [
        CheckedPopupMenuItem<String>(
          value: 'finishTrack',
          checked: finishTrack,
          child: Text(l10n.sleepTimerFinishTrack),
        ),
        const PopupMenuDivider(),
        for (final m in prefs.sleepTimerPresets)
          PopupMenuItem(
            value: 'min:$m',
            child: Text(l10n.sleepTimerMinutes(m)),
          ),
        PopupMenuItem(value: 'custom', child: Text(l10n.sleepTimerCustom)),
        const PopupMenuDivider(),
        PopupMenuItem(value: 'eot', child: Text(l10n.sleepTimerEndOfTrack)),
        PopupMenuItem(value: 'off', child: Text(l10n.sleepTimerOff)),
      ],
    );
  }
}

class _PlayerMainBody extends StatelessWidget {
  const _PlayerMainBody({
    required this.source,
    required this.current,
    required this.title,
    required this.subtitle,
    required this.playing,
    required this.hasContent,
    required this.hasLyrics,
    required this.hasSource,
    required this.showLyrics,
    required this.contentMounted,
    required this.transitionStyle,
    required this.coverLayout,
    required this.coverLyricRatio,
    required this.autoCenterCover,
    required this.slideNext,
    required this.coverPulse,
    required this.beatStrength,
    required this.l10n,
    required this.onSeekLyric,
    this.dragMs,
  });

  final String? source;
  final Track? current;
  final String title;
  final String subtitle;
  final bool playing;
  final bool hasContent;
  final bool hasLyrics;
  final bool hasSource;
  final bool showLyrics;
  final bool contentMounted;
  final String transitionStyle;
  final String coverLayout;
  final double coverLyricRatio;
  final bool autoCenterCover;
  final bool slideNext;
  final AnimationController coverPulse;
  final double beatStrength;
  final AppLocalizations l10n;
  final ValueChanged<int>? onSeekLyric;

  /// 拖动进度条中的目标位置（毫秒）；null = 未拖动。
  final double? dragMs;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        // 封面布局：默认左右分栏（宽度按占比），全屏封面用更大的左栏。
        final fullscreen = coverLayout == 'fullscreen';
        final coverFraction = fullscreen ? 0.6 : coverLyricRatio;
        final lyricsFraction = fullscreen ? 0.5 : (1 - coverLyricRatio);
        final coverByWidth =
            c.maxWidth * coverFraction * (fullscreen ? 0.95 : 0.85);
        final coverByHeight = c.maxHeight * 0.5;
        final size =
            (coverByWidth < coverByHeight ? coverByWidth : coverByHeight).clamp(
              180.0,
              520.0,
            );
        // 无歌词时封面是否自动居中（全屏封面模式不位移）。
        final coverCentered =
            !fullscreen && autoCenterCover && !(showLyrics && hasLyrics);
        final lyricScale = (MediaQuery.sizeOf(context).height / 1080).clamp(
          0.85,
          1.6,
        );
        final coverKey = current != null
            ? '${current!.source}/${current!.id}'
            : 'local:$source';
        final coverBlock = PlayerCoverBlock(
          size: size,
          current: current,
          hasContent: hasContent,
          title: title,
          subtitle: subtitle,
          playing: playing,
          pulse: coverPulse,
          beatStrength: beatStrength,
          l10n: l10n,
        );
        // 歌词块同样等路由进入动画结束后再挂载（对齐原版 lyricMounted）。
        final lyricsBlock = contentMounted
            ? PlayerLyricsBlock(
                hasLyrics: hasLyrics,
                lyricScale: lyricScale,
                onSeek: onSeekLyric,
                dragMs: dragMs,
              )
            : const SizedBox.shrink();
        return RepaintBoundary(
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                top: 0,
                bottom: 0,
                left: 0,
                width: c.maxWidth * coverFraction,
                child: AnimatedSlide(
                  offset: coverCentered
                      ? const Offset(11 / 18, 0)
                      : Offset.zero,
                  duration: animDuration(
                    context,
                    const Duration(milliseconds: 600),
                  ),
                  curve: Curves.easeOutCubic,
                  child: Align(
                    alignment: Alignment.center,
                    child: RepaintBoundary(
                      child: CoverSwitcher(
                        coverKey: coverKey,
                        slide: transitionStyle == 'slide',
                        next: slideNext,
                        child: coverBlock,
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 0,
                bottom: 0,
                right: 0,
                width: c.maxWidth * lyricsFraction,
                child: IgnorePointer(
                  ignoring: !showLyrics || !hasLyrics,
                  child: AnimatedOpacity(
                    duration: animDuration(
                      context,
                      const Duration(milliseconds: 600),
                    ),
                    curve: Curves.easeOutCubic,
                    opacity: (showLyrics && hasLyrics) ? 1 : 0,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 64),
                      child: RepaintBoundary(child: lyricsBlock),
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

class _PlayerBottomOverlay extends StatelessWidget {
  const _PlayerBottomOverlay({
    required this.controlsVisible,
    required this.theme,
    required this.dragMs,
    required this.buffering,
    required this.hasSource,
    required this.hasContent,
    required this.hasQueue,
    required this.canLike,
    required this.liked,
    required this.current,
    required this.shuffle,
    required this.repeatMode,
    required this.playing,
    required this.showProgressLyric,
    required this.onDragChanged,
    required this.onSeekEnd,
    required this.onToggleLike,
    required this.onShowComments,
  });

  final bool controlsVisible;
  final ThemeData theme;
  final double? dragMs;
  final bool buffering;
  final bool hasSource;
  final bool hasContent;
  final bool hasQueue;
  final bool canLike;
  final bool liked;
  final Track? current;
  final bool shuffle;
  final String repeatMode;
  final bool playing;
  final bool showProgressLyric;
  final ValueChanged<double?> onDragChanged;
  final ValueChanged<double> onSeekEnd;
  final ValueChanged<Track> onToggleLike;
  final VoidCallback onShowComments;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.bottomCenter,
      children: [
        AnimatedOpacity(
          opacity: controlsVisible ? 0.4 : 1,
          duration: animDuration(context, const Duration(milliseconds: 300)),
          curve: Curves.easeOut,
          child: RepaintBoundary(
            child: SizedBox(
              width: double.infinity,
              height: 90,
              child: SpectrumView(height: 90),
            ),
          ),
        ),
        AnimatedOpacity(
          opacity: controlsVisible ? 1 : 0,
          duration: animDuration(context, const Duration(milliseconds: 300)),
          curve: Curves.easeOut,
          child: IgnorePointer(
            ignoring: !controlsVisible,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showProgressLyric) _ProgressLyric(dragMs: dragMs),
                PlaybackProgressSlider(
                  showTimes: true,
                  textStyle: theme.textTheme.bodySmall,
                  dragMs: dragMs,
                  buffering: buffering,
                  enabled: hasSource,
                  onDragChanged: onDragChanged,
                  onSeekEnd: onSeekEnd,
                ),
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: PlayerControlsRow(
                    hasContent: hasContent,
                    hasQueue: hasQueue,
                    canLike: canLike,
                    liked: liked,
                    current: current,
                    shuffle: shuffle,
                    repeatMode: repeatMode,
                    playing: playing,
                    buffering: buffering,
                    onToggleLike: onToggleLike,
                    onShowComments: onShowComments,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 进度条上方的当前歌词行（强迫症：`showProgressLyric`）。
///
/// 独立 Consumer 订阅位置与歌词，避免 50ms 位置更新带动整个播放页重建。
class _ProgressLyric extends ConsumerWidget {
  const _ProgressLyric({this.dragMs});

  /// 拖动进度条中的目标位置（毫秒）；null = 跟随播放器实时位置。
  ///
  /// 拖动时跟随手指（对齐 AMLL：拖动进度条时高亮跟着走），与全屏歌词墙一致。
  final double? dragMs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final pos = ref.watch(
      playbackProvider.select((s) => s.position.inMilliseconds),
    );
    final groups = ref
        .watch(currentLyricsProvider)
        .maybeWhen(data: (l) => l, orElse: () => const <LyricGroup>[]);
    if (groups.isEmpty) return const SizedBox.shrink();
    final i = lyricIndexAt(groups, dragMs?.round() ?? pos);
    if (i < 0 || i >= groups.length) return const SizedBox.shrink();
    final text = groups[i].original.text;
    if (text.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Text(
        text,
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
