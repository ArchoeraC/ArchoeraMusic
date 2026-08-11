import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/netease/netease_api.dart';
import '../stores/providers.dart';
import '../../l10n/l10n.dart';
import '../widgets/list/cover_grid.dart';
import '../widgets/dialogs/netease_login_dialog.dart';
import '../widgets/dialogs/kugou_login_button.dart';
import '../widgets/common/login_guide.dart';
import '../widgets/player/s_controls.dart';
import '../widgets/dialogs/track_list_dialog.dart';

/// 收藏页（对齐原项目 Favorites.vue）。
///
/// 平台切换（网易云 / 酷狗）：网易云三 tab（歌单 / 专辑 / 歌手）保持原逻辑；
/// 酷狗按 MoeKoeMusic Library.vue 对 `/v7/get_all_list` 的分类拆成
/// 「创建的歌单 / 收藏的歌单 / 收藏的专辑」三 tab。未登录对应平台显示登录引导。
class FavoritesPage extends ConsumerStatefulWidget {
  const FavoritesPage({super.key});

  @override
  ConsumerState<FavoritesPage> createState() => _FavoritesPageState();
}

enum _Platform { netease, kugou }

/// 网易云收藏 tab。
enum _FavTab { playlist, album, artist }

/// 酷狗曲库 tab（对齐 MoeKoeMusic Library.vue 分类）。
enum _KgTab { created, collectedPlaylist, collectedAlbum }

class _FavoritesPageState extends ConsumerState<FavoritesPage> {
  _Platform _platform = _Platform.netease;
  _FavTab _tab = _FavTab.playlist;
  _KgTab _kgTab = _KgTab.created;

  /// 各 tab 缓存数据（key：'netease.playlist' / 'kugou.created' 等；切换保留，
  /// 登录态变化时清空）。
  final Map<String, List<CoverItem>> _cache = {};
  final Map<String, String> _error = {};
  final Set<String> _loading = {};
  final Set<String> _loaded = {};

  bool get _neteaseLoggedIn => ref.read(neteaseAuthProvider) != null;
  bool get _kugouLoggedIn => ref.read(kugouApiProvider).session != null;

  /// 当前平台是否已登录（内容区据此显示数据或登录引导）。
  bool get _loggedIn =>
      _platform == _Platform.kugou ? _kugouLoggedIn : _neteaseLoggedIn;

  String get _cacheKey =>
      '${_platform.name}.'
      '${_platform == _Platform.kugou ? _kgTab.name : _tab.name}';

  /// 酷狗三个 tab 的 key（一次 `/v7/get_all_list` 拉全部分类）。
  static const _kgKeys = [
    'kugou.created',
    'kugou.collectedPlaylist',
    'kugou.collectedAlbum',
  ];

  @override
  void initState() {
    super.initState();
    if (_loggedIn) _fetch();
  }

  /// 登录态变化（登录成功 / 退出）时清空缓存并刷新。
  void _onAuthChanged() {
    _cache.clear();
    _error.clear();
    _loading.clear();
    _loaded.clear();
    if (_loggedIn) _fetch();
  }

  void _switchPlatform(_Platform platform) {
    if (platform == _platform) return;
    setState(() => _platform = platform);
    if (_loggedIn && !_loaded.contains(_cacheKey)) _fetch();
  }

  void _switchTab(_FavTab tab) {
    if (tab == _tab) return;
    setState(() => _tab = tab);
    if (_loggedIn && !_loaded.contains(_cacheKey)) _fetch();
  }

  void _switchKgTab(_KgTab tab) {
    if (tab == _kgTab) return;
    setState(() => _kgTab = tab);
    if (_loggedIn && !_loaded.contains(_cacheKey)) _fetch();
  }

  Future<void> _fetch() async {
    final key = _cacheKey;
    if (_loading.contains(key)) return;
    setState(() {
      _loading.add(key);
      _error.remove(key);
    });
    try {
      if (_platform == _Platform.kugou) {
        final lib = await ref.read(kugouApiProvider).userLibrary();
        // 一次拉取填充全部分类（切换 tab 不再重复请求）
        _cache['kugou.created'] = lib.createdPlaylists
            .map((i) => i.toCoverItem())
            .toList();
        _cache['kugou.collectedPlaylist'] = lib.collectedPlaylists
            .map((i) => i.toCoverItem())
            .toList();
        _cache['kugou.collectedAlbum'] = lib.collectedAlbums
            .map((i) => i.toCoverItem())
            .toList();
      } else {
        final account = ref.read(neteaseAuthProvider);
        final api = ref.read(neteaseApiProvider);
        final List<CoverItem> items;
        switch (_tab) {
          case _FavTab.playlist:
            final playlists = await api.userPlaylists(account!.userId);
            items = playlists
                .where((p) => p.subscribed)
                .map(
                  (p) => CoverItem(
                    id: p.id,
                    title: p.name,
                    cover: p.cover,
                    subtitle: p.owner ?? '',
                    trackCount: p.trackCount,
                  ),
                )
                .toList();
          case _FavTab.album:
            items = await api.albumSublist();
          case _FavTab.artist:
            items = await api.artistSublist();
        }
        _cache[key] = items;
      }
      if (!mounted) return;
      setState(() {
        _loading.remove(key);
        _loaded.addAll(_platform == _Platform.kugou ? _kgKeys : [key]);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error[key] = '$e';
        _loading.remove(key);
        _loaded.add(key);
      });
    }
  }

  void _onCoverTap(CoverItem item) {
    if (_platform == _Platform.kugou) {
      // 「我喜欢」为个人歌单，走 likedTracks 个人链路（listid→
      // /v4/get_list_all_file）；其余歌单/收藏专辑统一用公开歌单接口
      // 打开（global_collection_id；对齐 MoeKoeMusic 跳转 PlaylistDetail）
      if (item.title == '我喜欢') {
        showKugouTracksDialog(
          context,
          title: item.title,
          cover: item.cover,
          loadTracks: (ref) => ref.read(kugouApiProvider).likedTracks(),
        );
        return;
      }
      showKugouPlaylistDetailDialog(context, item);
      return;
    }
    switch (_tab) {
      case _FavTab.playlist:
        showPlaylistDetailDialog(context, item);
      case _FavTab.album:
        showNeteaseAlbumDialog(context, item);
      case _FavTab.artist:
        showNeteaseArtistDialog(context, item);
    }
  }

  Future<void> _login() async {
    if (_platform == _Platform.kugou) {
      await showDialog<bool>(
        context: context,
        barrierColor: Colors.black.withValues(alpha: 0.5),
        barrierDismissible: false,
        builder: (_) => const KgQrLoginDialog(),
      );
    } else {
      showNeteaseLoginDialog(context);
    }
  }

  @override
  Widget build(BuildContext context) {
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
                ? LoginGuide(
                    icon: Icons.star_outline,
                    title: l10n.pageFavLoginTitle,
                    description: _platform == _Platform.kugou
                        ? l10n.pageFavKugouLoginDesc
                        : l10n.pageFavLoginDesc,
                    onLogin: _login,
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
