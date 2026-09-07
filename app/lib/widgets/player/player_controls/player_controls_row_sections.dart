// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../player_controls_row.dart';

class _PlayerControlsLeftGroup extends StatelessWidget {
  const _PlayerControlsLeftGroup({
    required this.canLike,
    required this.liked,
    required this.current,
    required this.l10n,
    required this.colorScheme,
    required this.onToggleLike,
    required this.onShowComments,
  });

  final bool canLike;
  final bool liked;
  final Track? current;
  final dynamic l10n;
  final ColorScheme colorScheme;
  final ValueChanged<Track> onToggleLike;
  final VoidCallback onShowComments;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.start,
      children: [
        if (canLike)
          CtrlIcon(
            tooltip: liked ? l10n.commonUnlike : l10n.commonLike,
            icon: liked ? EtaIcons.heart : EtaIcons.heartOutline,
            size: 24,
            color: liked ? Colors.redAccent : colorScheme.onSurfaceVariant,
            onPressed: () => onToggleLike(current!),
          ),
        if (canLike) ...[
          const SizedBox(width: 12),
          CtrlIcon(
            tooltip: l10n.menuComment,
            icon: EtaIcons.commentOutline,
            size: 24,
            onPressed: onShowComments,
          ),
        ],
      ],
    );
  }
}

class _PlayerControlsCenterGroup extends StatelessWidget {
  const _PlayerControlsCenterGroup({
    required this.hasContent,
    required this.hasQueue,
    required this.shuffle,
    required this.repeatMode,
    required this.playing,
    required this.buffering,
    required this.l10n,
    required this.colorScheme,
    required this.notifier,
  });

  final bool hasContent;
  final bool hasQueue;
  final bool shuffle;
  final String repeatMode;
  final bool playing;
  final bool buffering;
  final dynamic l10n;
  final ColorScheme colorScheme;
  final PlaybackNotifier notifier;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        CtrlIcon(
          tooltip: shuffle ? l10n.queueShuffleOff : l10n.queueShuffle,
          icon: EtaIcons.shuffle,
          size: 20,
          color: shuffle ? colorScheme.primary : colorScheme.onSurfaceVariant,
          onPressed: hasContent ? notifier.toggleShuffle : null,
        ),
        const SizedBox(width: 12),
        CtrlIcon(
          tooltip: l10n.commonPrevious,
          icon: EtaIcons.skipPrevious,
          size: 26,
          color: colorScheme.onSurface,
          onPressed: hasQueue ? notifier.playPrevious : null,
        ),
        const SizedBox(width: 14),
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
                        ? EtaIcons.pauseCircle
                        : EtaIcons.playCircle,
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
          icon: EtaIcons.skipForward,
          size: 26,
          color: colorScheme.onSurface,
          onPressed: hasQueue ? notifier.playNext : null,
        ),
        const SizedBox(width: 12),
        CtrlIcon(
          tooltip: repeatMode == 'list'
              ? l10n.queueRepeatList
              : l10n.queueRepeatOne,
          icon: repeatMode == 'one' ? EtaIcons.repeatOne : EtaIcons.repeat,
          size: 20,
          color: colorScheme.primary,
          onPressed: hasContent ? notifier.cycleRepeatMode : null,
        ),
      ],
    );
  }
}

class _PlayerControlsRightGroup extends StatelessWidget {
  const _PlayerControlsRightGroup({
    required this.hasQueue,
    required this.l10n,
    required this.onShowQueue,
  });

  final bool hasQueue;
  final dynamic l10n;
  final VoidCallback onShowQueue;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        const HoverVolumeSlider(sliderWidth: 104),
        CtrlIcon(
          tooltip: l10n.playerBarPlaylist,
          icon: EtaIcons.playlist,
          size: 24,
          onPressed: hasQueue ? onShowQueue : null,
        ),
      ],
    );
  }
}
