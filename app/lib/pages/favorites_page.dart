import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/netease/netease_api.dart';
import '../stores/providers.dart';
import '../../l10n/l10n.dart';
import '../widgets/list/cover_grid.dart';
import '../widgets/dialogs/netease_login_dialog.dart';
import '../widgets/common/login_guide.dart';
import '../widgets/player/s_controls.dart';
import '../widgets/dialogs/track_list_dialog.dart';

/// 收藏页（对齐原项目 Favorites.vue）。
///
/// 网易云收藏三 tab：歌单（user_playlist 过滤 subscribed）/ 专辑
/// （album_sublist）/ 歌手（artist_sublist），点击进入对应详情弹窗。
/// 未登录显示登录引导。
class FavoritesPage extends ConsumerStatefulWidget {
  const FavoritesPage({super.key});

  @override
  ConsumerState<FavoritesPage> createState() => _FavoritesPageState();
}

enum _FavTab { playlist, album, artist }

class _FavoritesPageState extends ConsumerState<FavoritesPage> {
  _FavTab _tab = _FavTab.playlist;

  /// 各 tab 缓存数据（切换保留，登录态变化时清空）。
  final Map<_FavTab, List<CoverItem>> _cache = {};
  final Map<_FavTab, String> _error = {};
  final Set<_FavTab> _loading = {};
  final Set<_FavTab> _loaded = {};

  bool get _loggedIn => ref.read(neteaseAuthProvider) != null;

  @override
  void initState() {
    super.initState();
    if (_loggedIn) _fetch(_tab);
  }

  /// 登录态变化（登录成功 / 退出）时清空缓存并刷新。
  void _onAuthChanged() {
    _cache.clear();
    _error.clear();
    _loading.clear();
    _loaded.clear();
    if (_loggedIn) _fetch(_tab);
  }

  void _switchTab(_FavTab tab) {
    if (tab == _tab) return;
    setState(() => _tab = tab);
    if (_loggedIn && !_loaded.contains(tab)) _fetch(tab);
  }

  Future<void> _fetch(_FavTab tab) async {
    if (_loading.contains(tab)) return;
    setState(() {
      _loading.add(tab);
      _error.remove(tab);
    });
    try {
      final account = ref.read(neteaseAuthProvider);
      final api = ref.read(neteaseApiProvider);
      final List<CoverItem> items;
      switch (tab) {
        case _FavTab.playlist:
          final playlists = await api.userPlaylists(account!.userId);
          items = playlists
              .where((p) => p.subscribed)
              .map((p) => CoverItem(
                    id: p.id,
                    title: p.name,
                    cover: p.cover,
                    subtitle: p.owner ?? '',
                    trackCount: p.trackCount,
                  ))
              .toList();
        case _FavTab.album:
          items = await api.albumSublist();
        case _FavTab.artist:
          items = await api.artistSublist();
      }
      if (!mounted) return;
      setState(() {
        _cache[tab] = items;
        _loaded.add(tab);
        _loading.remove(tab);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error[tab] = '$e';
        _loading.remove(tab);
        _loaded.add(tab);
      });
    }
  }

  void _onCoverTap(CoverItem item) {
    switch (_tab) {
      case _FavTab.playlist:
        showPlaylistDetailDialog(context, item);
      case _FavTab.album:
        showNeteaseAlbumDialog(context, item);
      case _FavTab.artist:
        showNeteaseArtistDialog(context, item);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    ref.listen(neteaseAuthProvider, (_, next) => _onAuthChanged());

    final items = _cache[_tab] ?? const <CoverItem>[];
    final loading = _loading.contains(_tab);
    final error = _error[_tab] ?? '';
    final count = items.length;

    final String subtitle;
    final IconData countIcon;
    switch (_tab) {
      case _FavTab.playlist:
        subtitle = _loggedIn ? l10n.pageFavPlaylistCount(count) : l10n.pageFavPlaylistLoginHint;
        countIcon = Icons.queue_music;
      case _FavTab.album:
        subtitle = _loggedIn ? l10n.pageFavAlbumCount(count) : l10n.pageFavAlbumLoginHint;
        countIcon = Icons.album_outlined;
      case _FavTab.artist:
        subtitle = _loggedIn ? l10n.pageFavArtistCount(count) : l10n.pageFavArtistLoginHint;
        countIcon = Icons.person_outline;
    }

    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── 标题 + tab 切换 ──────────────────────────────────
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
                          color: scheme.onSurfaceVariant
                              .withValues(alpha: 0.75),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                SSegmented<_FavTab>(
                  options: [
                    SSegmentedOption(_FavTab.playlist, l10n.commonPlaylists),
                    SSegmentedOption(_FavTab.album, l10n.commonAlbums),
                    SSegmentedOption(_FavTab.artist, l10n.commonArtists),
                  ],
                  selected: _tab,
                  onChanged: _switchTab,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          const Divider(height: 1),
          // ── 内容区状态机 ─────────────────────────────────────
          Expanded(
            child: !_loggedIn
                ? LoginGuide(
                    icon: Icons.star_outline,
                    title: l10n.pageFavLoginTitle,
                    description: l10n.pageFavLoginDesc,
                    onLogin: () => showNeteaseLoginDialog(context),
                  )
                : loading && !_loaded.contains(_tab)
                ? const Center(
                    child: SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                  )
                : error.isNotEmpty && !_loaded.contains(_tab)
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.error_outline,
                            size: 48, color: scheme.error),
                        const SizedBox(height: 10),
                        Text(l10n.pageFavLoadFailed, style: theme.textTheme.bodyMedium),
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
                          onPressed: () => _fetch(_tab),
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
                          color: scheme.onSurfaceVariant
                              .withValues(alpha: 0.5),
                        ),
                        const SizedBox(height: 10),
                        Text(l10n.pageFavEmpty, style: theme.textTheme.bodyMedium),
                        const SizedBox(height: 4),
                        Text(
                          l10n.pageFavEmptyHint,
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
                    maxCrossAxisExtent: _tab == _FavTab.artist ? 150 : 180,
                  ),
          ),
        ],
      ),
    );
  }
}

