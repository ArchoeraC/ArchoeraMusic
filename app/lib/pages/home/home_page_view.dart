// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../home_page.dart';

extension _HomePageView on _HomePageState {
  Widget _buildPage(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    final account = ref.watch(neteaseAuthProvider);
    final coverRadius = ref.watch(appPrefsProvider).coverRadius;

    final greeting = _greetingText(l10n);
    final name = account?.nickname.isNotEmpty == true
        ? account!.nickname
        : l10n.greetingFallback;

    return Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 18, 24, 24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1400),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _HomeHeader(
                  l10n: l10n,
                  scheme: scheme,
                  greeting: greeting,
                  name: name,
                ),
                const SizedBox(height: 20),
                HomeDailyHero(
                  loggedIn: account != null,
                  title: l10n.pageHomeDaily,
                  subtitleLoggedIn: l10n.pageHomeDailyLoggedIn,
                  subtitleLoginHint: l10n.pageHomeDailyLoginHint,
                  playLabel: l10n.pageHomeDailyPlay,
                  loginLabel: l10n.pageHomeDailyLogin,
                  onPlay: _openDaily,
                ),
                const SizedBox(height: 20),
                _HomeQuickActions(
                  l10n: l10n,
                  onOpenDaily: _openDaily,
                  onOpenRank: _openRank,
                  onOpenPlaylistSquare: _openPlaylistSquare,
                  onOpenArtists: _openMoreArtists,
                ),
                const SizedBox(height: 24),
                if (_loading && !_data.loaded)
                  const _HomeLoading()
                else if (_error.isNotEmpty && !_data.loaded)
                  _HomeError(
                    theme: theme,
                    l10n: l10n,
                    error: _error,
                    onRetry: _fetchAll,
                  )
                else
                  _HomeSections(
                    l10n: l10n,
                    data: _data,
                    coverRadius: coverRadius,
                    loading: _loading,
                    onOpenMorePlaylists: _openMorePlaylists,
                    onOpenMoreAlbums: _openMoreAlbums,
                    onOpenMoreArtists: _openMoreArtists,
                    onOpenPlaylist: _openPlaylist,
                    onOpenAlbum: _openAlbum,
                    onOpenArtist: _openArtist,
                    onPlayPlaylist: _playAllPlaylist,
                    onPlayAlbum: _playAllAlbum,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HomeHeader extends StatelessWidget {
  const _HomeHeader({
    required this.l10n,
    required this.scheme,
    required this.greeting,
    required this.name,
  });

  final AppLocalizations l10n;
  final ColorScheme scheme;
  final String greeting;
  final String name;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.pageHomeTitle,
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          l10n.pageHomeGreeting(greeting, name),
          style: TextStyle(
            fontSize: 13,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.75),
          ),
        ),
      ],
    );
  }
}

class _HomeQuickActions extends StatelessWidget {
  const _HomeQuickActions({
    required this.l10n,
    required this.onOpenDaily,
    required this.onOpenRank,
    required this.onOpenPlaylistSquare,
    required this.onOpenArtists,
  });

  final AppLocalizations l10n;
  final VoidCallback onOpenDaily;
  final VoidCallback onOpenRank;
  final VoidCallback onOpenPlaylistSquare;
  final VoidCallback onOpenArtists;

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 4,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 2.3,
      children: [
        HomeActionCard(
          icon: Icons.wb_sunny_outlined,
          title: l10n.pageHomeDaily,
          subtitle: l10n.trackListDailyRecommendSubtitle,
          onTap: onOpenDaily,
        ),
        HomeActionCard(
          icon: Icons.leaderboard_outlined,
          title: l10n.pageHomeRankTitle,
          subtitle: l10n.pageHomeRankSubtitle,
          onTap: onOpenRank,
        ),
        HomeActionCard(
          icon: Icons.queue_music_outlined,
          title: l10n.pageHomePlaylistSquare,
          subtitle: l10n.pageHomePlaylistSquareSubtitle,
          onTap: onOpenPlaylistSquare,
        ),
        HomeActionCard(
          icon: Icons.mic_external_on_outlined,
          title: l10n.commonArtists,
          subtitle: l10n.pageHomeArtistSubtitle,
          onTap: onOpenArtists,
        ),
      ],
    );
  }
}

class _HomeLoading extends StatelessWidget {
  const _HomeLoading();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 80),
      child: Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      ),
    );
  }
}

class _HomeError extends StatelessWidget {
  const _HomeError({
    required this.theme,
    required this.l10n,
    required this.error,
    required this.onRetry,
  });

  final ThemeData theme;
  final AppLocalizations l10n;
  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 60),
      child: Center(
        child: Column(
          children: [
            Icon(Icons.cloud_off_outlined, size: 44, color: scheme.error),
            const SizedBox(height: 10),
            Text(l10n.pageHomeLoadFailed, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 4),
            Text(
              error,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 14),
            SButton(
              label: l10n.commonRetry,
              icon: Icons.refresh,
              variant: SButtonVariant.secondary,
              onPressed: onRetry,
            ),
          ],
        ),
      ),
    );
  }
}

class _HomeSections extends StatelessWidget {
  const _HomeSections({
    required this.l10n,
    required this.data,
    required this.coverRadius,
    required this.loading,
    required this.onOpenMorePlaylists,
    required this.onOpenMoreAlbums,
    required this.onOpenMoreArtists,
    required this.onOpenPlaylist,
    required this.onOpenAlbum,
    required this.onOpenArtist,
    required this.onPlayPlaylist,
    required this.onPlayAlbum,
  });

  final AppLocalizations l10n;
  final _HomeData data;
  final double coverRadius;
  final bool loading;
  final VoidCallback onOpenMorePlaylists;
  final VoidCallback onOpenMoreAlbums;
  final VoidCallback onOpenMoreArtists;
  final ValueChanged<CoverItem> onOpenPlaylist;
  final ValueChanged<CoverItem> onOpenAlbum;
  final ValueChanged<CoverItem> onOpenArtist;
  final Future<void> Function(CoverItem) onPlayPlaylist;
  final Future<void> Function(CoverItem) onPlayAlbum;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HomeSectionTitle(
          title: l10n.pageHomePlaylists,
          subtitle: l10n.pageHomePlaylistsSubtitle,
          moreLabel: l10n.commonMore,
          onMore: onOpenMorePlaylists,
        ),
        CoverRail(
          items: data.playlists,
          onTap: onOpenPlaylist,
          onPlay: onPlayPlaylist,
          radius: coverRadius,
          cardWidth: 150,
          height: 198,
          loading: loading && data.playlists.isEmpty,
        ),
        const SizedBox(height: 26),
        HomeSectionTitle(
          title: l10n.pageHomeNewAlbums,
          subtitle: l10n.pageHomeNewAlbumsSubtitle,
          moreLabel: l10n.commonMore,
          onMore: onOpenMoreAlbums,
        ),
        CoverRail(
          items: data.albums,
          onTap: onOpenAlbum,
          onPlay: onPlayAlbum,
          radius: coverRadius,
          cardWidth: 150,
          height: 198,
          loading: loading && data.albums.isEmpty,
        ),
        const SizedBox(height: 26),
        HomeSectionTitle(
          title: l10n.pageHomeHotArtists,
          subtitle: l10n.pageHomeHotArtistsSubtitle,
          moreLabel: l10n.commonMore,
          onMore: onOpenMoreArtists,
        ),
        CoverRail(
          items: data.artists,
          onTap: onOpenArtist,
          artist: true,
          radius: coverRadius,
          cardWidth: 150,
          height: 198,
          loading: loading && data.artists.isEmpty,
        ),
      ],
    );
  }
}
