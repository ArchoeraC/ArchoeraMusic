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
            current.source == 'qqmusic');
    final liked = canLike
        ? ref.watch(likeControllerProvider).isLiked(current)
        : false;

    final prefs = ref.watch(appPrefsProvider);
    final showLyrics = prefs.showLyricsInPlayer;
    final transitionStyle = prefs.transitionStyle;
    final hasLyrics = ref
        .watch(currentLyricsProvider)
        .maybeWhen(data: (l) => l.isNotEmpty, orElse: () => false);

    return Scaffold(
      body: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerHover: (_) => _pokeControls(),
        onPointerDown: (_) => _pokeControls(),
        onPointerSignal: (_) => _pokeControls(),
        child: Stack(
          children: [
            Positioned.fill(
              child: PlayerBackground(cover: current?.cover, playing: playing),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  children: [
                    _PlayerTopBar(
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
                        transitionStyle: transitionStyle,
                        slideNext: _slideNext,
                        coverPulse: _coverPulse,
                        beatStrength: _lastBeatStrength,
                        l10n: l10n,
                        onSeekLyric: hasSource
                            ? (ms) => notifier.seek(Duration(milliseconds: ms))
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
          if (current != null)
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
    required this.transitionStyle,
    required this.slideNext,
    required this.coverPulse,
    required this.beatStrength,
    required this.l10n,
    required this.onSeekLyric,
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
  final String transitionStyle;
  final bool slideNext;
  final AnimationController coverPulse;
  final double beatStrength;
  final AppLocalizations l10n;
  final ValueChanged<int>? onSeekLyric;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final coverByWidth = c.maxWidth * 0.45 * 0.85;
        final coverByHeight = c.maxHeight * 0.5;
        final size =
            (coverByWidth < coverByHeight ? coverByWidth : coverByHeight).clamp(
              180.0,
              520.0,
            );
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
        final lyricsBlock = PlayerLyricsBlock(
          hasLyrics: hasLyrics,
          lyricScale: lyricScale,
          onSeek: onSeekLyric,
        );
        return RepaintBoundary(
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                top: 0,
                bottom: 0,
                left: 0,
                width: c.maxWidth * 0.45,
                child: AnimatedSlide(
                  offset: showLyrics && hasLyrics
                      ? Offset.zero
                      : const Offset(11 / 18, 0),
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
                width: c.maxWidth * 0.55,
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
