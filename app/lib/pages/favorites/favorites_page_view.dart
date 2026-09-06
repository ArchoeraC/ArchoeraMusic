// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../favorites_page.dart';

extension _FavoritesPageView on _FavoritesPageState {
  Widget _buildFavoritesPage(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    ref.listen(neteaseAuthProvider, (_, next) => _onAuthChanged());
    ref.listen(kugouApiProvider, (_, next) => _onAuthChanged());

    final items = _cache[_cacheKey] ?? const <CoverItem>[];
    final loading = _loading.contains(_cacheKey);
    final error = _error[_cacheKey] ?? '';
    final count = items.length;

    // ── 副标题 / 空态图标（按平台 + 分类） ───────────────────────
    final String subtitle;
    final IconData countIcon;
    if (_platform == _Platform.kugou) {
      countIcon = Icons.library_music_outlined;
      subtitle = switch (_kgTab) {
        _KgTab.created =>
          _kugouLoggedIn
              ? l10n.pageFavKgCreatedCount(count)
              : l10n.pageFavKgCreatedLoginHint,
        _KgTab.collectedPlaylist =>
          _kugouLoggedIn
              ? l10n.pageFavKgCollectedPlaylistCount(count)
              : l10n.pageFavKgCollectedPlaylistLoginHint,
        _KgTab.collectedAlbum =>
          _kugouLoggedIn
              ? l10n.pageFavKgCollectedAlbumCount(count)
              : l10n.pageFavKgCollectedAlbumLoginHint,
      };
    } else {
      switch (_tab) {
        case _FavTab.playlist:
          subtitle = _neteaseLoggedIn
              ? l10n.pageFavPlaylistCount(count)
              : l10n.pageFavPlaylistLoginHint;
          countIcon = Icons.queue_music;
        case _FavTab.album:
          subtitle = _neteaseLoggedIn
              ? l10n.pageFavAlbumCount(count)
              : l10n.pageFavAlbumLoginHint;
          countIcon = Icons.album_outlined;
        case _FavTab.artist:
          subtitle = _neteaseLoggedIn
              ? l10n.pageFavArtistCount(count)
              : l10n.pageFavArtistLoginHint;
          countIcon = Icons.person_outline;
      }
    }

    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── 标题 + 平台切换 ────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.sidebarFavorites,
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
                          color: scheme.onSurfaceVariant.withValues(
                            alpha: 0.75,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                SSegmented<_Platform>(
                  options: [
                    SSegmentedOption(_Platform.netease, l10n.platformNetease),
                    SSegmentedOption(_Platform.kugou, l10n.platformKugou),
                  ],
                  selected: _platform,
                  onChanged: _switchPlatform,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // ── 分类 tab ────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SSegmented<Object>(
                options: _platform == _Platform.kugou
                    ? [
                        SSegmentedOption(_KgTab.created, l10n.pageFavKgCreated),
                        SSegmentedOption(
                          _KgTab.collectedPlaylist,
                          l10n.pageFavKgCollectedPlaylist,
                        ),
                        SSegmentedOption(
                          _KgTab.collectedAlbum,
                          l10n.pageFavKgCollectedAlbum,
                        ),
                      ]
                    : [
                        SSegmentedOption(
                          _FavTab.playlist,
                          l10n.commonPlaylists,
                        ),
                        SSegmentedOption(_FavTab.album, l10n.commonAlbums),
                        SSegmentedOption(_FavTab.artist, l10n.commonArtists),
                      ],
                selected: _platform == _Platform.kugou ? _kgTab : _tab,
                onChanged: (v) {
                  if (_platform == _Platform.kugou) {
                    _switchKgTab(v as _KgTab);
                  } else {
                    _switchTab(v as _FavTab);
                  }
                },
              ),
            ),
          ),
          const SizedBox(height: 12),
          const Divider(height: 1),
          // ── 内容区状态机 ─────────────────────────────────────
          Expanded(
            child: !_loggedIn
                ? StreamingEmptyState(
                    icon: Icons.star_outline,
                    title: l10n.pageFavLoginTitle,
                    subtitle: _platform == _Platform.kugou
                        ? l10n.pageFavKugouLoginDesc
                        : l10n.pageFavLoginDesc,
                    buttonLabel: l10n.navHeaderQrLogin,
                    buttonIcon: Icons.qr_code_2,
                    onButton: _login,
                  )
                : loading && !_loaded.contains(_cacheKey)
                ? const Center(
                    child: SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                  )
                : error.isNotEmpty && !_loaded.contains(_cacheKey)
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.error_outline,
                          size: 48,
                          color: scheme.error,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          l10n.pageFavLoadFailed,
                          style: theme.textTheme.bodyMedium,
                        ),
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
                          onPressed: _fetch,
                        ),
                      ],
                    ),
                  )
                : items.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          countIcon,
                          size: 48,
                          color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          l10n.pageFavEmpty,
                          style: theme.textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _platform == _Platform.kugou
                              ? l10n.pageFavKugouEmptyHint
                              : l10n.pageFavEmptyHint,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  )
                : CoverGrid(
                    items: items,
                    onTap: _onCoverTap,
                    maxCrossAxisExtent:
                        _platform == _Platform.netease && _tab == _FavTab.artist
                        ? 150
                        : 180,
                  ),
          ),
        ],
      ),
    );
  }
}
