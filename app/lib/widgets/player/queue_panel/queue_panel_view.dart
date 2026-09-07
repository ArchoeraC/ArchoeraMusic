// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../queue_panel.dart';

extension _QueuePanelView on QueuePanel {
  Widget _buildQueuePanel(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final queue = ref.watch(playbackProvider.select((s) => s.queue));

    final body = _buildBody(context, theme, scheme, ref, queue);
    final glass = _glass(context, child: body);
    final noAnim = MediaQuery.maybeDisableAnimationsOf(context) ?? false;

    if (style == QueuePanelStyle.slide) {
      final panel = SizedBox(width: width, child: glass);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Align(
          alignment: Alignment.centerRight,
          child: noAnim
              ? panel
              : SlideTransition(
                  position:
                      Tween<Offset>(
                        begin: const Offset(1, 0),
                        end: Offset.zero,
                      ).animate(
                        CurvedAnimation(
                          parent: animation,
                          curve: Curves.easeOutCubic,
                          reverseCurve: Curves.easeInCubic,
                        ),
                      ),
                  child: panel,
                ),
        ),
      );
    }

    final expand = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    final fade = CurveTween(
      curve: const Interval(0.0, 1.0 / 3.0),
    ).animate(animation);
    final panel = ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight!),
      child: glass,
    );
    return Stack(
      children: [
        Positioned(
          left: anchor!.dx,
          bottom: anchor!.dy,
          width: width,
          child: noAnim
              ? panel
              : ClipRect(
                  child: FadeTransition(
                    opacity: fade,
                    child: SizeTransition(
                      sizeFactor: expand,
                      axis: Axis.vertical,
                      alignment: Alignment.bottomCenter,
                      child: panel,
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildBody(
    BuildContext context,
    ThemeData theme,
    ColorScheme scheme,
    WidgetRef ref,
    List<Track> queue,
  ) {
    final notifier = ref.read(playbackProvider.notifier);
    final l10n = context.l10n;
    final shuffle = ref.watch(playbackProvider.select((s) => s.shuffle));
    final repeatMode = ref.watch(playbackProvider.select((s) => s.repeatMode));
    final queueIndex = ref.watch(playbackProvider.select((s) => s.queueIndex));
    final playing = ref.watch(playbackProvider.select((s) => s.playing));

    final Widget listArea;
    if (style == QueuePanelStyle.slide) {
      listArea = Expanded(
        child: _buildList(
          context,
          queue,
          queueIndex,
          playing,
          notifier,
          scheme,
        ),
      );
    } else {
      listArea = ConstrainedBox(
        constraints: BoxConstraints(maxHeight: (maxHeight ?? 400) - 56),
        child: _buildList(
          context,
          queue,
          queueIndex,
          playing,
          notifier,
          scheme,
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _QueuePanelHeader(
          queueLength: queue.length,
          shuffle: shuffle,
          repeatMode: repeatMode,
          scheme: scheme,
          theme: theme,
          l10n: l10n,
          onToggleShuffle: notifier.toggleShuffle,
          onCycleRepeat: notifier.cycleRepeatMode,
          onClear: queue.isEmpty ? null : notifier.clearQueue,
        ),
        const Divider(height: 1),
        listArea,
      ],
    );
  }

  Widget _buildList(
    BuildContext context,
    List<Track> queue,
    int queueIndex,
    bool playing,
    PlaybackNotifier notifier,
    ColorScheme scheme,
  ) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    if (queue.isEmpty) {
      return _QueuePanelEmpty(theme: theme, scheme: scheme, l10n: l10n);
    }
    return ReorderableListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      buildDefaultDragHandles: false,
      shrinkWrap: style != QueuePanelStyle.slide,
      proxyDecorator: (child, index, animation) =>
          Material(color: Colors.transparent, child: child),
      itemCount: queue.length,
      onReorderItem: (oldIndex, newIndex) =>
          notifier.moveInQueue(oldIndex, newIndex),
      itemBuilder: (context, index) {
        final track = queue[index];
        final current = index == queueIndex;
        return _QueueTile(
          key: ValueKey('${track.source}:${track.id}:$index'),
          track: track,
          index: index,
          current: current,
          playing: current && playing,
          onTap: () => notifier.playAtIndex(index),
          onRemove: () => notifier.removeFromQueue(index),
        );
      },
    );
  }

  Widget _glass(BuildContext context, {required Widget child}) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surface.withValues(alpha: 0.66),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.28),
                blurRadius: 28,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Material(type: MaterialType.transparency, child: child),
        ),
      ),
    );
  }
}

class _QueuePanelHeader extends StatelessWidget {
  const _QueuePanelHeader({
    required this.queueLength,
    required this.shuffle,
    required this.repeatMode,
    required this.scheme,
    required this.theme,
    required this.l10n,
    required this.onToggleShuffle,
    required this.onCycleRepeat,
    required this.onClear,
  });

  final int queueLength;
  final bool shuffle;
  final String repeatMode;
  final ColorScheme scheme;
  final ThemeData theme;
  final dynamic l10n;
  final VoidCallback onToggleShuffle;
  final VoidCallback onCycleRepeat;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 6, 4),
      child: Row(
        children: [
          Icon(EtaIcons.playlist, size: 19, color: scheme.primary),
          const SizedBox(width: 8),
          Text(l10n.queueTitle, style: theme.textTheme.titleMedium),
          const SizedBox(width: 8),
          if (queueLength > 0)
            Text(
              l10n.queueTrackCount(queueLength),
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          const Spacer(),
          IconButton(
            tooltip: shuffle ? l10n.queueShuffleOff : l10n.queueShuffle,
            onPressed: onToggleShuffle,
            visualDensity: VisualDensity.compact,
            icon: Icon(
              EtaIcons.shuffle,
              size: 19,
              color: shuffle ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ),
          IconButton(
            tooltip: switch (repeatMode) {
              'list' => l10n.queueRepeatList,
              'one' => l10n.queueRepeatOne,
              _ => l10n.queueRepeatMode,
            },
            onPressed: onCycleRepeat,
            visualDensity: VisualDensity.compact,
            icon: Icon(
              repeatMode == 'one' ? EtaIcons.repeatOne : EtaIcons.repeat,
              size: 19,
              color: scheme.primary,
            ),
          ),
          IconButton(
            tooltip: l10n.queueClear,
            onPressed: onClear,
            visualDensity: VisualDensity.compact,
            icon: const Icon(EtaIcons.deleteOutline, size: 18),
          ),
          IconButton(
            tooltip: l10n.commonClose,
            onPressed: () => Navigator.of(context).pop(),
            visualDensity: VisualDensity.compact,
            icon: const Icon(EtaIcons.close, size: 18),
          ),
        ],
      ),
    );
  }
}

class _QueuePanelEmpty extends StatelessWidget {
  const _QueuePanelEmpty({
    required this.theme,
    required this.scheme,
    required this.l10n,
  });

  final ThemeData theme;
  final ColorScheme scheme;
  final dynamic l10n;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 160,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              EtaIcons.playlist,
              size: 44,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.35),
            ),
            const SizedBox(height: 10),
            Text(
              l10n.queueEmpty,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              l10n.queueEmptyHint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QueueTile extends StatelessWidget {
  const _QueueTile({
    super.key,
    required this.track,
    required this.index,
    required this.current,
    required this.playing,
    required this.onTap,
    required this.onRemove,
  });

  final Track track;
  final int index;
  final bool current;
  final bool playing;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final titleStyle = theme.textTheme.bodyMedium?.copyWith(
      color: current ? scheme.primary : scheme.onSurface,
      fontWeight: current ? FontWeight.w600 : FontWeight.w400,
    );
    final subtitle = track.subtitle.isEmpty
        ? (track.album?.name ?? '')
        : track.subtitle;

    return ListTile(
      dense: true,
      onTap: onTap,
      leading: SizedBox(
        width: 36,
        child: Center(
          child: current
              ? Icon(
                  playing ? EtaIcons.soundLine : EtaIcons.play,
                  size: 18,
                  color: scheme.primary,
                )
              : Text(
                  '${index + 1}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: index >= 999 ? 10.5 : null,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
        ),
      ),
      title: Row(
        children: [
          CoverImage(
            cover: track.cover,
            width: 30,
            height: 30,
            radius: 6,
            iconSize: 16,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  track.title,
                  style: titleStyle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle.isNotEmpty)
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (track.duration > 0)
            Text(
              formatMs(track.duration),
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ReorderableDragStartListener(
            index: index,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Icon(
                EtaIcons.dotsVertical,
                size: 18,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
              ),
            ),
          ),
          IconButton(
            tooltip: context.l10n.menuRemoveFromQueue,
            visualDensity: VisualDensity.compact,
            onPressed: onRemove,
            icon: Icon(
              EtaIcons.close,
              size: 16,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}
