// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// ignore_for_file: invalid_use_of_protected_member

part of '../track_list_dialog.dart';

extension _TrackListDialogView on _TrackListDialogState {
  Widget _buildTrackListDialog(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final playingId = ref.watch(playbackProvider.select((s) => s.trackId));
    final isPlaying = ref.watch(playbackProvider.select((s) => s.playing));
    final window = MediaQuery.sizeOf(context);
    final listHeight = (window.height * 0.6).clamp(300.0, 560.0);

    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 80, vertical: 48),
      clipBehavior: Clip.antiAlias,
      child: GlassDialogSurface(
        radius: BorderRadius.circular(16),
        color: theme.colorScheme.surfaceContainerHigh,
        child: SizedBox(
          width: (MediaQuery.sizeOf(context).width * 0.68).clamp(560.0, 780.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _TrackListHeader(
                title: widget.title,
                subtitle: widget.subtitle,
                cover: widget.cover,
                future: _future,
                l10n: l10n,
                onPlayAll: _playAll,
              ),
              const SizedBox(height: 12),
              const Divider(height: 1),
              Flexible(
                child: FutureBuilder<List<Track>>(
                  future: _future,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return SizedBox(
                        height: listHeight,
                        child: const _DialogSpinner(),
                      );
                    }
                    if (snapshot.hasError) {
                      return SizedBox(
                        height: listHeight,
                        child: _DialogErrorView(
                          message: l10n.commonLoadFailed('${snapshot.error}'),
                          onRetry: _reload,
                        ),
                      );
                    }
                    final tracks = snapshot.data ?? const <Track>[];
                    if (tracks.isEmpty) {
                      return SizedBox(
                        height: listHeight,
                        child: _TrackListEmpty(theme: theme, l10n: l10n),
                      );
                    }
                    return SizedBox(
                      height: listHeight,
                      child: SongList(
                        items: tracks,
                        playingId: playingId,
                        isPlaying: isPlaying,
                        onPlay: _playTrack,
                        onContextMenu: _onTrackMenu,
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

extension _BrowseDialogView on _KugouBrowseDialogState {
  Widget _buildBrowseDialog(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 80, vertical: 48),
      clipBehavior: Clip.antiAlias,
      child: GlassDialogSurface(
        radius: BorderRadius.circular(16),
        color: theme.colorScheme.surfaceContainerHigh,
        child: SizedBox(
          width: (MediaQuery.sizeOf(context).width * 0.72).clamp(600.0, 860.0),
          height: (MediaQuery.sizeOf(context).height * 0.84).clamp(
            460.0,
            660.0,
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 12, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.title,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: l10n.commonClose,
                      visualDensity: VisualDensity.compact,
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close, size: 18),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              const Divider(height: 1),
              Expanded(
                child: FutureBuilder<List<CoverItem>>(
                  future: _future,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const _DialogSpinner();
                    }
                    if (snapshot.hasError) {
                      return _DialogErrorView(
                        message: l10n.commonLoadFailed('${snapshot.error}'),
                        onRetry: _reloadBrowse,
                      );
                    }
                    final items = snapshot.data ?? const <CoverItem>[];
                    if (items.isEmpty) {
                      return Center(
                        child: Text(
                          l10n.commonEmptyContent,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      );
                    }
                    return CoverGrid(
                      items: items,
                      maxCrossAxisExtent: 200,
                      artist: widget.artist,
                      childAspectRatio: widget.artist ? 0.82 : 0.78,
                      onTap: (item) {
                        Navigator.of(context).pop();
                        widget.onItemTap(context, item);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TrackListHeader extends StatelessWidget {
  const _TrackListHeader({
    required this.title,
    required this.subtitle,
    required this.cover,
    required this.future,
    required this.l10n,
    required this.onPlayAll,
  });

  final String title;
  final String? subtitle;
  final String? cover;
  final Future<List<Track>> future;
  final dynamic l10n;
  final Future<void> Function(List<Track>) onPlayAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _HeaderCover(cover: cover),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (subtitle != null && subtitle!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                FutureBuilder<List<Track>>(
                  future: future,
                  builder: (context, snapshot) {
                    if (snapshot.hasData && snapshot.data!.isNotEmpty) {
                      return SButton(
                        label: l10n.trackListPlayAll,
                        icon: Icons.play_arrow_rounded,
                        variant: SButtonVariant.primary,
                        onPressed: () => onPlayAll(snapshot.data!),
                      );
                    }
                    return const SizedBox.shrink();
                  },
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: l10n.commonClose,
            visualDensity: VisualDensity.compact,
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close, size: 18),
          ),
        ],
      ),
    );
  }
}

class _HeaderCover extends StatelessWidget {
  const _HeaderCover({this.cover});

  final String? cover;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final placeholder = Container(
      color: theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
      child: Icon(Icons.music_note, size: 40, color: theme.colorScheme.primary),
    );
    final c = cover;
    if (c == null || c.isEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(width: 96, height: 96, child: placeholder),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Image.network(
        c,
        width: 96,
        height: 96,
        fit: BoxFit.cover,
        cacheWidth: (96 * MediaQuery.devicePixelRatioOf(context)).round(),
        cacheHeight: (96 * MediaQuery.devicePixelRatioOf(context)).round(),
        errorBuilder: (_, _, _) => placeholder,
        loadingBuilder: (context, child, progress) =>
            progress == null ? child : placeholder,
      ),
    );
  }
}

class _TrackListEmpty extends StatelessWidget {
  const _TrackListEmpty({required this.theme, required this.l10n});

  final ThemeData theme;
  final dynamic l10n;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.music_off_outlined,
            size: 42,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 10),
          Text(
            l10n.trackListEmptyDailyLogin(l10n.brandNetease),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _DialogSpinner extends StatelessWidget {
  const _DialogSpinner();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: SizedBox(
        width: 26,
        height: 26,
        child: CircularProgressIndicator(strokeWidth: 2.5),
      ),
    );
  }
}

class _DialogErrorView extends StatelessWidget {
  const _DialogErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline, size: 42, color: theme.colorScheme.error),
          const SizedBox(height: 10),
          Text(message, style: theme.textTheme.bodySmall),
          const SizedBox(height: 14),
          SButton(
            label: l10n.commonRetry,
            icon: Icons.refresh,
            variant: SButtonVariant.secondary,
            onPressed: onRetry,
          ),
        ],
      ),
    );
  }
}
