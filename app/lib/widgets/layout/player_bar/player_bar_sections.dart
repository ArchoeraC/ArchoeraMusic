part of '../player_bar.dart';

extension _PlayerBarSections on _PlayerBarState {
  Widget _buildBarContent({
    required BuildContext context,
    required ThemeData theme,
    required PlaybackNotifier notifier,
    required Track? track,
    required String? title,
    required String? subtitle,
    required bool buffering,
    required bool playing,
    required bool hasSource,
    required bool hasQueue,
    required bool hasContent,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 22,
          child: PlaybackProgressSlider(
            dragMs: _dragMs,
            buffering: buffering,
            enabled: hasSource,
            onDragChanged: _setDragMs,
            onSeekEnd: (_) => _clearDragMs(),
          ),
        ),
        SizedBox(
          height: 60,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                _buildLeftSection(
                  context: context,
                  theme: theme,
                  track: track,
                  title: title,
                  subtitle: subtitle,
                  buffering: buffering,
                  hasContent: hasContent,
                ),
                _buildCenterControls(
                  context: context,
                  notifier: notifier,
                  buffering: buffering,
                  playing: playing,
                  hasQueue: hasQueue,
                  hasContent: hasContent,
                ),
                _buildRightSection(
                  context: context,
                  theme: theme,
                  track: track,
                  hasQueue: hasQueue,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLeftSection({
    required BuildContext context,
    required ThemeData theme,
    required Track? track,
    required String? title,
    required String? subtitle,
    required bool buffering,
    required bool hasContent,
  }) {
    final l10n = context.l10n;
    return Expanded(
      child: Row(
        children: [
          Tooltip(
            message: l10n.playerBarOpenPlayer,
            child: _BarCover(
              cover: track?.cover,
              onTap: hasContent ? () => context.push('/player') : null,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title ?? l10n.playerBarUntitled,
                  style: theme.textTheme.titleSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  hasContent
                      ? (buffering ? l10n.playerBarBuffering : (subtitle ?? ''))
                      : l10n.playerBarIdleHint,
                  style: theme.textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCenterControls({
    required BuildContext context,
    required PlaybackNotifier notifier,
    required bool buffering,
    required bool playing,
    required bool hasQueue,
    required bool hasContent,
  }) {
    final l10n = context.l10n;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: l10n.commonPrevious,
          onPressed: hasQueue ? notifier.playPrevious : null,
          icon: const Icon(EtaIcons.skipPrevious),
        ),
        IconButton(
          tooltip: buffering ? l10n.commonLoading : l10n.playerBarPlayPause,
          onPressed: hasContent && !buffering ? notifier.toggle : null,
          icon: buffering
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(playing ? EtaIcons.pause : EtaIcons.play),
        ),
        IconButton(
          tooltip: l10n.commonNext,
          onPressed: hasQueue ? notifier.playNext : null,
          icon: const Icon(EtaIcons.skipForward),
        ),
      ],
    );
  }

  Widget _buildRightSection({
    required BuildContext context,
    required ThemeData theme,
    required Track? track,
    required bool hasQueue,
  }) {
    final l10n = context.l10n;
    return Expanded(
      child: Align(
        alignment: Alignment.centerRight,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 150,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Consumer(
                    builder: (context, ref, _) {
                      final s = ref.watch(
                        playbackProvider.select(
                          (s) => (pos: s.position, dur: s.duration),
                        ),
                      );
                      return Text(
                        '${formatClock(s.pos)} / ${formatClock(s.dur)}',
                        style: theme.textTheme.bodySmall,
                      );
                    },
                  ),
                  const SizedBox(height: 4),
                  const SizedBox(width: 120, height: 12, child: _BarInfoArea()),
                ],
              ),
            ),
            const HoverVolumeSlider(sliderWidth: 72),
            Builder(
              builder: (btnCtx) => IconButton(
                tooltip: l10n.playerBarPlaylist,
                onPressed: hasQueue
                    ? () => QueuePanel.show(
                        context,
                        style: QueuePanelStyle.popup,
                        anchor: _anchorOf(btnCtx),
                      )
                    : null,
                icon: const Icon(EtaIcons.playlist),
              ),
            ),
            if (track != null &&
                (track.source == 'netease' || track.source == 'kugou'))
              _BarLikeButton(track: track),
          ],
        ),
      ),
    );
  }

  Widget _buildFloatingPlayerBar({
    required ThemeData theme,
    required AppChromeColors chrome,
    required bool imageMode,
    required Widget bar,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 14),
      child: Align(
        alignment: Alignment.bottomCenter,
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(30),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.35),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(30),
              child: _glass(
                imageMode,
                child: Material(
                  color: chrome.playerBarBackground,
                  clipBehavior: Clip.antiAlias,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(30),
                    side: BorderSide(
                      color: theme.colorScheme.primary.withValues(alpha: 0.12),
                    ),
                  ),
                  child: SafeArea(top: false, child: bar),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDockedPlayerBar({
    required AppChromeColors chrome,
    required bool imageMode,
    required Widget bar,
  }) {
    return _glass(
      imageMode,
      child: Material(
        color: chrome.playerBarBackground,
        elevation: 8,
        child: SafeArea(child: bar),
      ),
    );
  }
}
