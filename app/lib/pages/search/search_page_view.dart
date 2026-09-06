// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../search_page.dart';

extension _SearchPageView on _SearchPageState {
  Widget _buildPage(BuildContext context) {
    final l10n = context.l10n;
    // 选择性订阅（播放位置/FFT 50ms 更新不重建列表）
    final playingId = ref.watch(playbackProvider.select((s) => s.trackId));
    final isPlaying = ref.watch(playbackProvider.select((s) => s.playing));
    final coverRadius = ref.watch(appPrefsProvider).coverRadius;
    // 红心集合：聚合/单平台混来源结果按行键合并（NT id + KG hash
    // + QQ songmid，与 songLikeKey / LikeController 一致）。
    final like = ref.watch(likeControllerProvider);
    final rowLikedIds = {
      ...like.idsFor('netease'),
      ...like.idsFor('kugou'),
      ...like.idsFor('qqmusic'),
    };

    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SearchPageHeader(
            query: _query,
            platform: _platform,
            tabs: _tabs,
            onPlatformChanged: _switchPlatform,
          ),
          const Divider(height: 1),
          Expanded(
            child: _buildContent(
              l10n: l10n,
              playingId: playingId,
              isPlaying: isPlaying,
              coverRadius: coverRadius,
              rowLikedIds: rowLikedIds,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent({
    required AppLocalizations l10n,
    required String? playingId,
    required bool isPlaying,
    required double coverRadius,
    required Set<String> rowLikedIds,
  }) {
    if (_query.isEmpty) {
      return SearchEmptyState(
        icon: Icons.travel_explore,
        title: l10n.pageSearchInputHint,
        subtitle: l10n.pageSearchInputSubtitle,
      );
    }
    if (_error.isNotEmpty) {
      return SearchErrorState(message: _error, onRetry: _retryFromError);
    }
    if (_initialLoading) {
      return SearchEmptyState(
        icon: Icons.hourglass_top,
        title: l10n.pageSearching,
      );
    }
    if (_emptyResult) {
      return SearchEmptyState(
        icon: Icons.search_off,
        title: l10n.pageSearchEmpty,
        subtitle: l10n.pageSearchEmptyHint,
      );
    }
    return Column(
      children: [
        _SearchAggFailureBanner(
          visible: _platform == 'all',
          failed: _failedAggSources(_tab),
          platformLabel: _platformLabel,
          failureDetail: _failureDetail,
          isCooling: (source) =>
              source == 'qqmusic' && _sourceCooldown.cooling('qqmusic'),
          onRetry: _tab == _SearchTab.songs
              ? _retrySongsSource
              : (source) => _retryCoversSource(_tab, source),
        ),
        Expanded(
          child: IndexedStack(
            index: _tabs.index,
            children: [
              SongList(
                items: _songs.items,
                playingId: playingId,
                isPlaying: isPlaying,
                onPlay: _playTrack,
                hasMore: _songs.hasMore,
                loadingMore: _songs.loadingMore,
                showSource: _platform == 'all',
                likedIds: rowLikedIds,
                onToggleLike: _toggleLike,
                onContextMenu: _onTrackMenu,
                onReachBottom: () => _fetch(append: true),
              ),
              CoverGrid(
                items: _albums.items,
                loading: _albums.loadingMore,
                hasMore: _albums.hasMore,
                radius: coverRadius,
                showSource: _platform == 'all',
                onTap: _onCoverTap,
                onReachBottom: () => _fetch(append: true),
              ),
              CoverGrid(
                items: _artists.items,
                loading: _artists.loadingMore,
                hasMore: _artists.hasMore,
                radius: coverRadius,
                showSource: _platform == 'all',
                onTap: _onCoverTap,
                onReachBottom: () => _fetch(append: true),
              ),
              CoverGrid(
                items: _playlists.items,
                loading: _playlists.loadingMore,
                hasMore: _playlists.hasMore,
                radius: coverRadius,
                showSource: _platform == 'all',
                onTap: _onCoverTap,
                onReachBottom: () => _fetch(append: true),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SearchPageHeader extends StatelessWidget {
  const _SearchPageHeader({
    required this.query,
    required this.platform,
    required this.tabs,
    required this.onPlatformChanged,
  });

  final String query;
  final String platform;
  final TabController tabs;
  final ValueChanged<String> onPlatformChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(
                  query.isEmpty ? l10n.commonSearch : query,
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                    color: theme.colorScheme.onSurface,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 16),
              SSegmented<String>(
                options: [
                  SSegmentedOption('netease', l10n.platformNetease),
                  SSegmentedOption('kugou', l10n.platformKugou),
                  SSegmentedOption('qqmusic', l10n.platformQQMusic),
                  SSegmentedOption('all', l10n.platformAll),
                ],
                selected: platform,
                onChanged: onPlatformChanged,
              ),
            ],
          ),
          const SizedBox(height: 12),
          TabBar(
            controller: tabs,
            // TabAlignment.start 仅对可滚动 TabBar 有效：必须 isScrollable，
            // 否则指示条偏移与标签不一致。
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: l10n.commonSongs),
              Tab(text: l10n.commonAlbums),
              Tab(text: l10n.commonArtists),
              Tab(text: l10n.commonPlaylists),
            ],
          ),
        ],
      ),
    );
  }
}

class _SearchAggFailureBanner extends StatelessWidget {
  const _SearchAggFailureBanner({
    required this.visible,
    required this.failed,
    required this.platformLabel,
    required this.failureDetail,
    required this.isCooling,
    required this.onRetry,
  });

  final bool visible;
  final List<MapEntry<String, _AggState>> failed;
  final String Function(String source) platformLabel;
  final String Function(String source, Object? err) failureDetail;
  final bool Function(String source) isCooling;
  final ValueChanged<String> onRetry;

  @override
  Widget build(BuildContext context) {
    if (!visible || failed.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final items = <Widget>[];
    for (final entry in failed) {
      final source = entry.key;
      final detail = failureDetail(source, entry.value.error).trim();
      final cooling = isCooling(source);
      items.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 1),
              child: Icon(Icons.cloud_off_outlined, size: 18),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.searchSourceFailed(platformLabel(source)),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (detail.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Text(
                        detail,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: cooling ? null : () => onRetry(source),
              child: Text(l10n.commonRetry),
            ),
          ],
        ),
      );
      items.add(const SizedBox(height: 6));
    }
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: theme.colorScheme.error.withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: items,
      ),
    );
  }
}
