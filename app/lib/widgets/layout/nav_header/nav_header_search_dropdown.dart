// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../nav_header.dart';

/// 搜索下拉面板（内联，非弹窗；对齐原版 NavSearch 的搜索历史/热搜/建议）。
///
/// 视觉：与播放条队列面板同款毛玻璃（blur24 + 半透明表面 + 细描边 +
/// 投影）；嵌入式定位，顶边紧贴搜索框底边、顶部圆角归零。
class _SearchDropdown extends ConsumerWidget {
  const _SearchDropdown({
    required this.width,
    required this.query,
    required this.panelCtrl,
    required this.hot,
    required this.hotLoading,
    required this.kugouHot,
    required this.kugouHotLoading,
    required this.suggest,
    required this.suggestLoading,
    required this.onSearch,
    required this.onRemove,
    required this.onClear,
    required this.onPickSong,
    required this.onPickAlbum,
    required this.onPickArtist,
    required this.onPickPlaylist,
  });

  final double width;
  final String query;
  final Animation<double> panelCtrl;
  final List<HotSearchItem> hot;
  final bool hotLoading;
  final List<HotSearchItem> kugouHot;
  final bool kugouHotLoading;
  final SuggestData suggest;
  final bool suggestLoading;
  final ValueChanged<String> onSearch;
  final ValueChanged<String> onRemove;
  final VoidCallback onClear;
  final ValueChanged<SuggestSongItem> onPickSong;
  final ValueChanged<SuggestSimpleItem> onPickAlbum;
  final ValueChanged<SuggestSimpleItem> onPickArtist;
  final ValueChanged<SuggestSimpleItem> onPickPlaylist;

  static const double _radius = 16;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final history = ref.watch(appPrefsProvider).searchHistory;

    final body = query.isNotEmpty
        ? _buildSuggestBody(context, scheme)
        : _buildExploreBody(context, scheme, history);

    final expand = CurvedAnimation(
      parent: panelCtrl,
      curve: Curves.linearToEaseOut,
      reverseCurve: Curves.easeInCubic,
    );
    final fade = CurveTween(
      curve: const Interval(0.0, 0.45),
    ).animate(panelCtrl);

    final panel = ClipRRect(
      borderRadius: const BorderRadius.vertical(
        bottom: Radius.circular(_radius),
      ),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surface.withValues(alpha: 0.66),
            border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.28),
                blurRadius: 28,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Material(
            type: MaterialType.transparency,
            child: SizedBox(
              width: width,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: (MediaQuery.sizeOf(context).height - 120).clamp(
                    200.0,
                    460.0,
                  ),
                ),
                child: ScrollConfiguration(
                  behavior: ScrollConfiguration.of(
                    context,
                  ).copyWith(scrollbars: false),
                  child: SingleChildScrollView(child: body),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    return SizedBox(
      width: width,
      child: ClipRect(
        child: FadeTransition(
          opacity: fade,
          child: SizeTransition(
            sizeFactor: expand,
            axis: Axis.vertical,
            alignment: Alignment.topCenter,
            child: panel,
          ),
        ),
      ),
    );
  }

  Widget _buildExploreBody(
    BuildContext context,
    ColorScheme scheme,
    List<String> history,
  ) {
    final l10n = context.l10n;
    final children = <Widget>[];

    if (history.isNotEmpty) {
      children.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 2),
          child: Row(
            children: [
              Icon(EtaIcons.history, size: 15, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Text(
                l10n.searchHistory,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              InkWell(
                onTap: onClear,
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Text(
                    l10n.searchHistoryClear,
                    style: TextStyle(fontSize: 11.5, color: scheme.primary),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      children.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final word in history)
                _HistoryChip(
                  word: word,
                  onSearch: onSearch,
                  onRemove: onRemove,
                ),
            ],
          ),
        ),
      );
    }

    if (hotLoading) {
      children.add(
        _sectionTitle(
          context,
          EtaIcons.fireOutline,
          l10n.searchHot,
          bottom: 10,
        ),
      );
      children.add(
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    } else if (hot.isNotEmpty) {
      children.add(
        _sectionTitle(
          context,
          EtaIcons.fireOutline,
          l10n.searchHot,
          bottom: 2,
        ),
      );
      for (var i = 0; i < hot.length && i < 20; i++) {
        children.add(_hotTile(scheme, hot[i], i));
      }
      children.add(const SizedBox(height: 6));
    }

    final kugouHotTitle = '${l10n.brandKugou} · ${l10n.searchHot}';
    if (kugouHotLoading) {
      children.add(
        _sectionTitle(
          context,
          EtaIcons.fireOutline,
          kugouHotTitle,
          bottom: 10,
        ),
      );
      children.add(
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    } else if (kugouHot.isNotEmpty) {
      children.add(
        _sectionTitle(
          context,
          EtaIcons.fireOutline,
          kugouHotTitle,
          bottom: 2,
        ),
      );
      for (var i = 0; i < kugouHot.length && i < 20; i++) {
        children.add(_hotTile(scheme, kugouHot[i], i));
      }
      children.add(const SizedBox(height: 6));
    }

    if (children.isEmpty) {
      children.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          child: Row(
            children: [
              Icon(EtaIcons.history, size: 15, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Text(
                l10n.searchHistoryEmpty,
                style: TextStyle(
                  fontSize: 12.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  Widget _hotTile(ColorScheme scheme, HotSearchItem item, int index) {
    return InkWell(
      onTap: () => onSearch(item.keyword),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            SizedBox(
              width: 22,
              child: Text(
                '${index + 1}',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: index < 3
                      ? scheme.primary
                      : scheme.onSurfaceVariant.withValues(alpha: 0.55),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                item.keyword,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
            ),
            if (item.score != null)
              Text(
                '${item.score}',
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.4),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSuggestBody(BuildContext context, ColorScheme scheme) {
    final l10n = context.l10n;
    final children = <Widget>[
      InkWell(
        onTap: () => onSearch(query),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(EtaIcons.search2, size: 16, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.searchQuick(query),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              Icon(EtaIcons.cornerUpLeft, size: 14, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    ];

    if (suggestLoading) {
      children.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 10),
              Text(
                l10n.pageSearching,
                style: TextStyle(
                  fontSize: 12.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    } else {
      if (suggest.songs.isNotEmpty) {
        children.add(
          _sectionTitle(context, EtaIcons.musicOutline, l10n.commonSongs),
        );
        for (final song in suggest.songs) {
          children.add(_suggestSongRow(scheme, song));
        }
      }
      if (suggest.artists.isNotEmpty) {
        children.add(
          _sectionTitle(context, EtaIcons.userOutline, l10n.commonArtists),
        );
        for (final artist in suggest.artists) {
          children.add(_suggestSimpleRow(scheme, artist, EtaIcons.userOutline));
        }
      }
      if (suggest.albums.isNotEmpty) {
        children.add(
          _sectionTitle(context, EtaIcons.albumOutline, l10n.commonAlbums),
        );
        for (final album in suggest.albums) {
          children.add(_suggestSimpleRow(scheme, album, EtaIcons.albumOutline));
        }
      }
      if (suggest.playlists.isNotEmpty) {
        children.add(
          _sectionTitle(
            context,
            EtaIcons.playlistOutline,
            l10n.commonPlaylists,
          ),
        );
        for (final playlist in suggest.playlists) {
          children.add(
            _suggestSimpleRow(scheme, playlist, EtaIcons.playlistOutline),
          );
        }
      }
      if (suggest.isEmpty) {
        children.add(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Text(
              l10n.pageSearchEmpty,
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            ),
          ),
        );
      }
      children.add(const SizedBox(height: 6));
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  Widget _sectionTitle(
    BuildContext context,
    IconData icon,
    String title, {
    double bottom = 2,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(12, 8, 12, bottom),
      child: Row(
        children: [
          Icon(icon, size: 14, color: scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(
            title,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _suggestSongRow(ColorScheme scheme, SuggestSongItem song) {
    final subtitle = [
      if (song.artist != null && song.artist!.isNotEmpty) song.artist!,
      if (song.album != null && song.album!.isNotEmpty) song.album!,
    ].join(' · ');
    return InkWell(
      onTap: () => onPickSong(song),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            Icon(
              EtaIcons.music,
              size: 14,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (song.source == 'kugou') ...[
                        const _SourceDot(),
                        const SizedBox(width: 6),
                      ],
                      Flexible(
                        child: Text(
                          song.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                  if (subtitle.isNotEmpty)
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _suggestSimpleRow(
    ColorScheme scheme,
    SuggestSimpleItem item,
    IconData icon,
  ) {
    return InkWell(
      onTap: () {
        switch (icon) {
          case EtaIcons.userOutline:
            onPickArtist(item);
          case EtaIcons.albumOutline:
            onPickAlbum(item);
          default:
            onPickPlaylist(item);
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            Icon(
              icon,
              size: 14,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Row(
                children: [
                  if (item.source == 'kugou') ...[
                    const _SourceDot(),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
            if (item.subtitle != null && item.subtitle!.isNotEmpty)
              Text(
                item.subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SourceDot extends StatelessWidget {
  const _SourceDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 16,
      height: 16,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFF00A7E0),
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Text(
        '酷',
        style: TextStyle(
          fontSize: 9.5,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
    );
  }
}

class _HistoryChip extends StatelessWidget {
  const _HistoryChip({
    required this.word,
    required this.onSearch,
    required this.onRemove,
  });

  final String word;
  final ValueChanged<String> onSearch;
  final ValueChanged<String> onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => onSearch(word),
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.only(left: 10, top: 5, bottom: 5),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 180),
                child: Text(
                  word,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
            ),
          ),
          InkWell(
            onTap: () => onRemove(word),
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
              child: Icon(
                EtaIcons.close,
                size: 12,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
