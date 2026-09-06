// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// ignore_for_file: invalid_use_of_protected_member

part of '../liked_page.dart';

extension _LikedPageView on _LikedPageState {
  Widget _buildPage(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    final playingId = ref.watch(playbackProvider.select((s) => s.trackId));
    final isPlaying = ref.watch(playbackProvider.select((s) => s.playing));
    ref.listen(neteaseAuthProvider, (prev, next) {
      _onAuthChanged('netease');
    });
    ref.listen(kugouApiProvider.select((s) => s.session?.userid), (prev, next) {
      if (prev != next) _onAuthChanged('kugou');
    });
    ref.listen(qqMusicApiProvider.select((s) => s.isLoggedIn), (prev, next) {
      if (prev != next) _onAuthChanged(_LikedPageState._qqPlatform);
    });

    final neteaseStore = ref.watch(likedStoreProvider);
    final qqStore = ref.watch(qqLikedStoreProvider);
    final store = _platform == _LikedPageState._qqPlatform
        ? null
        : neteaseStore;
    final qq = _platform == _LikedPageState._qqPlatform;
    final qqTracks = qqStore.tracks;
    final qqLoaded = qqStore.loaded;
    final qqLoading = qqStore.loading && !qqLoaded;
    final qqError = qqStore.error;

    final subtitle = !_loggedIn
        ? (qq
              ? ''
              : (_platform == 'kugou'
                    ? l10n.pageLikedKugouLoginHint
                    : l10n.pageLikedNeteaseLoginHint))
        : qq
        ? (qqTracks.isEmpty
              ? l10n.pageLikedQqHint
              : l10n.commonSongCountHint(qqTracks.length))
        : l10n.commonSongCountHint(store!.total(_platform));

    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _LikedHeader(
            subtitle: subtitle,
            platform: _platform,
            loggedIn: _loggedIn,
            qq: qq,
            qqLoaded: qqLoaded,
            qqTracks: qqTracks,
            qqLoggedIn: _qqLoggedIn,
            resolving: _resolving,
            store: store,
            onPlayAll: _playAll,
            onSwitchPlatform: _switchPlatform,
            onRefresh: qq
                ? _refreshQqOnline
                : () => neteaseStore.refresh(_platform, writeCache: true),
          ),
          const SizedBox(height: 12),
          const Divider(height: 1),
          Expanded(
            child: _buildContent(
              theme: theme,
              scheme: scheme,
              l10n: l10n,
              store: store,
              qqStore: qqStore,
              qq: qq,
              qqTracks: qqTracks,
              qqLoaded: qqLoaded,
              qqLoading: qqLoading,
              qqError: qqError,
              playingId: playingId,
              isPlaying: isPlaying,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent({
    required ThemeData theme,
    required ColorScheme scheme,
    required AppLocalizations l10n,
    required LikedStore? store,
    required QqLikedStore qqStore,
    required bool qq,
    required List<Track> qqTracks,
    required bool qqLoaded,
    required bool qqLoading,
    required String qqError,
    required String? playingId,
    required bool isPlaying,
  }) {
    if (qq) {
      if (qqLoading) {
        return const Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
        );
      }
      if (qqError.isNotEmpty && qqTracks.isEmpty) {
        return _LikedErrorState(
          message: qqError,
          onRetry: () => _qqStore.ensureLoaded(),
        );
      }
      if (qqTracks.isEmpty) {
        return _QqEmptyState(
          loggedIn: _qqLoggedIn,
          l10n: l10n,
          scheme: scheme,
          theme: theme,
          onLogin: _showQqLogin,
          onSync: _refreshQqOnline,
        );
      }
      return SongList(
        items: qqTracks,
        playingId: playingId,
        isPlaying: isPlaying,
        onPlay: _playTrack,
        onContextMenu: _onTrackMenu,
        likedIds: qqStore.midSet,
        onToggleLike: _toggleLike,
      );
    }
    if (!_loggedIn) {
      return StreamingEmptyState(
        icon: Icons.favorite_outline,
        title: l10n.pageLikedLoginTitle,
        subtitle: _platform == 'kugou'
            ? l10n.pageLikedKugouLoginDesc
            : l10n.pageLikedNeteaseLoginDesc,
        buttonLabel: l10n.navHeaderQrLogin,
        buttonIcon: Icons.qr_code_2,
        onButton: () async {
          if (_platform == 'kugou') {
            await showDialog<bool>(
              context: context,
              barrierColor: Colors.black.withValues(alpha: 0.5),
              barrierDismissible: false,
              builder: (_) => const KgQrLoginDialog(),
            );
          } else {
            showNeteaseLoginDialog(context);
          }
        },
      );
    }
    if (store!.loading(_platform) && !store.loaded(_platform)) {
      return const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      );
    }
    if (store.error(_platform).isNotEmpty && !store.loaded(_platform)) {
      return _LikedErrorCard(
        theme: theme,
        scheme: scheme,
        title: l10n.pageLikedLoadFailed,
        message: store.error(_platform),
        onRetry: () => store.refresh(_platform, writeCache: true),
      );
    }
    if (store.tracks(_platform).isEmpty) {
      return _LikedEmptyState(
        theme: theme,
        scheme: scheme,
        title: l10n.pageLikedEmpty,
        message: _platform == 'kugou'
            ? l10n.pageLikedKugouEmptyHint
            : l10n.pageLikedNeteaseEmptyHint,
      );
    }
    return SongList(
      items: store.tracks(_platform),
      playingId: playingId,
      isPlaying: isPlaying,
      onPlay: _playTrack,
      onContextMenu: _onTrackMenu,
      likedIds: ref.watch(likeControllerProvider).idsFor(_platform),
      onToggleLike: _toggleLike,
    );
  }
}

class _LikedHeader extends StatelessWidget {
  const _LikedHeader({
    required this.subtitle,
    required this.platform,
    required this.loggedIn,
    required this.qq,
    required this.qqLoaded,
    required this.qqTracks,
    required this.qqLoggedIn,
    required this.resolving,
    required this.store,
    required this.onPlayAll,
    required this.onSwitchPlatform,
    required this.onRefresh,
  });

  final String subtitle;
  final String platform;
  final bool loggedIn;
  final bool qq;
  final bool qqLoaded;
  final List<Track> qqTracks;
  final bool qqLoggedIn;
  final bool resolving;
  final LikedStore? store;
  final Future<void> Function() onPlayAll;
  final ValueChanged<String> onSwitchPlatform;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.sidebarLiked,
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 13,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.75),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (loggedIn &&
              (qq
                  ? qqLoaded && qqTracks.isNotEmpty
                  : store!.loaded(platform) &&
                        store!.tracks(platform).isNotEmpty)) ...[
            SButton(
              label: l10n.commonPlayAll,
              icon: Icons.play_arrow_rounded,
              variant: SButtonVariant.primary,
              loading: resolving,
              onPressed: onPlayAll,
            ),
            const SizedBox(width: 12),
          ],
          SSegmented<String>(
            options: [
              SSegmentedOption('netease', l10n.platformNetease),
              SSegmentedOption('kugou', l10n.platformKugou),
              SSegmentedOption('qqmusic', l10n.platformQQMusic),
            ],
            selected: platform,
            onChanged: onSwitchPlatform,
          ),
          const SizedBox(width: 12),
          if (loggedIn &&
              (qq
                  ? qqLoaded && (qqTracks.isNotEmpty || qqLoggedIn)
                  : store!.loaded(platform) &&
                        store!.tracks(platform).isNotEmpty))
            SButton(
              label: qq ? l10n.pageLikedQqSyncOnline : l10n.commonRefresh,
              icon: Icons.sync,
              variant: SButtonVariant.secondary,
              onPressed: onRefresh,
            ),
        ],
      ),
    );
  }
}

class _QqEmptyState extends StatelessWidget {
  const _QqEmptyState({
    required this.loggedIn,
    required this.l10n,
    required this.scheme,
    required this.theme,
    required this.onLogin,
    required this.onSync,
  });

  final bool loggedIn;
  final AppLocalizations l10n;
  final ColorScheme scheme;
  final ThemeData theme;
  final VoidCallback onLogin;
  final VoidCallback onSync;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.favorite_border,
            size: 48,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 10),
          Text(l10n.pageLikedQqEmptyTitle, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              l10n.pageLikedQqEmptyHint,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (!loggedIn)
            SButton(
              label: l10n.pageLikedQqLoginSync,
              icon: Icons.qr_code_2,
              variant: SButtonVariant.secondary,
              onPressed: onLogin,
            )
          else
            SButton(
              label: l10n.pageLikedQqSyncOnline,
              icon: Icons.sync,
              variant: SButtonVariant.secondary,
              onPressed: onSync,
            ),
        ],
      ),
    );
  }
}

class _LikedErrorState extends StatelessWidget {
  const _LikedErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline, size: 48, color: scheme.error),
          const SizedBox(height: 10),
          Text(
            message,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 14),
          SButton(
            label: context.l10n.commonRetry,
            icon: Icons.refresh,
            variant: SButtonVariant.secondary,
            onPressed: onRetry,
          ),
        ],
      ),
    );
  }
}

class _LikedErrorCard extends StatelessWidget {
  const _LikedErrorCard({
    required this.theme,
    required this.scheme,
    required this.title,
    required this.message,
    required this.onRetry,
  });

  final ThemeData theme;
  final ColorScheme scheme;
  final String title;
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline, size: 48, color: scheme.error),
          const SizedBox(height: 10),
          Text(title, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 4),
          Text(
            message,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 14),
          SButton(
            label: context.l10n.commonRetry,
            icon: Icons.refresh,
            variant: SButtonVariant.secondary,
            onPressed: onRetry,
          ),
        ],
      ),
    );
  }
}

class _LikedEmptyState extends StatelessWidget {
  const _LikedEmptyState({
    required this.theme,
    required this.scheme,
    required this.title,
    required this.message,
  });

  final ThemeData theme;
  final ColorScheme scheme;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.favorite_border,
            size: 48,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 10),
          Text(title, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 4),
          Text(
            message,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
