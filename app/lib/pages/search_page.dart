import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/netease/netease_api.dart';
import '../services/netease/track.dart';
import '../services/playback/playback_notifier.dart';
import '../stores/app_prefs.dart';
import '../stores/providers.dart';
import '../../l10n/l10n.dart';
import '../widgets/list/cover_grid.dart';
import '../widgets/player/s_controls.dart';
import '../widgets/dialogs/s_context_menu.dart';
import '../widgets/common/toast.dart';
import '../widgets/list/song_list.dart';
import '../widgets/dialogs/track_context_menu.dart';
import '../widgets/dialogs/track_list_dialog.dart';
import '../widgets/search/search_empty_state.dart';
import '../widgets/search/search_error_state.dart';

/// 搜索页（对齐原项目 Search.vue）。
///
/// 4 个 Tab（歌曲 / 专辑 / 歌手 / 歌单），各 Tab 独立分页状态：
/// 关键词变化清空重拉（offset 0），触底 append 下一页（PAGE_SIZE=50）。
/// 点击歌曲 → 侧车 song_url 解析播放 URL → PlaybackNotifier.load 完整转码播放。
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key, this.initialQuery = ''});

  final String initialQuery;

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

/// 单个 Tab 的分页状态（对齐 Search.vue 的 `TabState<T>`）。
class _TabState<T> {
  const _TabState({
    this.items = const [],
    this.total = 0,
    this.hasMore = false,
    this.loaded = false,
    this.loading = false,
    this.loadingMore = false,
  });

  final List<T> items;
  final int total;
  final bool hasMore;
  final bool loaded;
  final bool loading;
  final bool loadingMore;

  _TabState<T> copyWith({
    List<T>? items,
    int? total,
    bool? hasMore,
    bool? loaded,
    bool? loading,
    bool? loadingMore,
  }) {
    return _TabState<T>(
      items: items ?? this.items,
      total: total ?? this.total,
      hasMore: hasMore ?? this.hasMore,
      loaded: loaded ?? this.loaded,
      loading: loading ?? this.loading,
      loadingMore: loadingMore ?? this.loadingMore,
    );
  }
}

enum _SearchTab { songs, albums, artists, playlists }

class _SearchPageState extends ConsumerState<SearchPage>
    with SingleTickerProviderStateMixin {
  static const _pageSize = 50;

  /// 单 tab 累计条数上限：超过即截断并停 more（防无限加载撑爆内存）。
  static const _maxTabItems = 300;

  late final TabController _tabs;

  _TabState<Track> _songs = const _TabState();
  _TabState<CoverItem> _albums = const _TabState();
  _TabState<CoverItem> _artists = const _TabState();
  _TabState<CoverItem> _playlists = const _TabState();

  String _query = '';
  String _error = '';

  /// 搜索平台（'netease' / 'kugou' / 'all' 聚合；酷狗支持歌曲/专辑/歌手/歌单分类）。
  String _platform = 'netease';

  /// 聚合搜索：各平台已加载条数（分开获取、合并展示时的分页锚点）。
  int _aggNeteaseLoaded = 0;
  int _aggKugouLoaded = 0;

  /// 是否正在解析播放源（防连点）。
  bool _resolving = false;

  @override
  void initState() {
    super.initState();
    _query = widget.initialQuery.trim();
    _tabs = TabController(length: 4, vsync: this);
    _tabs.addListener(_onTabChanged);
    if (_query.isNotEmpty) {
      unawaited(_fetch(append: false));
    }
  }

  @override
  void didUpdateWidget(SearchPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 路由 query 变化（NavHeader 新搜索）：重置并按新关键词重拉
    final q = widget.initialQuery.trim();
    if (q != oldWidget.initialQuery.trim() && q != _query) {
      _query = q;
      _resetAll();
      if (_query.isNotEmpty) unawaited(_fetch(append: false));
    }
  }

  @override
  void dispose() {
    _tabs.removeListener(_onTabChanged);
    _tabs.dispose();
    super.dispose();
  }

  _SearchTab get _tab =>
      _SearchTab.values[_tabs.index.clamp(0, _SearchTab.values.length - 1)];

  void _onTabChanged() {
    if (!_tabs.indexIsChanging) return;
    // 切换 tab：未拉过则按需请求（对齐 Search.vue watch activeTab）
    if (_query.isNotEmpty && !_currentState.loaded) {
      unawaited(_fetch(append: false));
    }
    setState(() {});
  }

  /// 切换搜索平台（酷狗仅歌曲，聚合=两平台并行合并；对齐 MineRadio 分开获取）。
  void _switchPlatform(String platform) {
    if (platform == _platform) return;
    setState(() => _platform = platform);
    _resetAll();
    if (_query.isNotEmpty) unawaited(_fetch(append: false));
  }

  /// 清空所有 tab 状态（对齐 resetStates）。
  void _resetAll() {
    setState(() {
      _songs = const _TabState();
      _albums = const _TabState();
      _artists = const _TabState();
      _playlists = const _TabState();
      _aggNeteaseLoaded = 0;
      _aggKugouLoaded = 0;
      _error = '';
    });
  }

  _TabState<dynamic> get _currentState => switch (_tab) {
    _SearchTab.songs => _songs,
    _SearchTab.albums => _albums,
    _SearchTab.artists => _artists,
    _SearchTab.playlists => _playlists,
  };

  /// 当前 tab 首页加载中。
  bool get _initialLoading => _currentState.loading && !_currentState.loaded;

  /// 当前 tab 已加载且为空。
  bool get _emptyResult => _currentState.loaded && _currentState.items.isEmpty;

  /// 追加下一页并限制累计条数：超 [maxItems] 从尾部截断（保留最新），
  /// 由调用方据返回长度决定是否继续加载。
  List<T> _boundedAppend<T>(List<T> current, List<T> next) {
    if (next.isEmpty) return current;
    final merged = [...current, ...next];
    return merged.length > _maxTabItems
        ? merged.sublist(merged.length - _maxTabItems)
        : merged;
  }

  Future<void> _fetch({required bool append}) async {
    if (_query.isEmpty) return;
    final tab = _tab;
    if (tab == _SearchTab.songs) {
      await _fetchSongs(append: append);
    } else {
      await _fetchCovers(append: append);
    }
  }

  Future<void> _fetchSongs({required bool append}) async {
    final state = _songs;
    if (append) {
      if (!state.loaded || state.loadingMore || !state.hasMore) return;
      _songs = state.copyWith(loadingMore: true);
    } else {
      if (state.loading) return;
      _songs = state.copyWith(loading: true);
    }
    setState(() {});
    _error = '';
    try {
      final SearchResult<Track> result;
      if (_platform == 'all') {
        // 聚合搜索（对齐 MineRadio「分开获取 + 聚合搜索」）：两平台并行
        // 请求，各自按已加载条数取下一页，合并到一个列表展示。
        final results = await Future.wait<SearchResult<Track>>([
          ref
              .read(neteaseApiProvider)
              .searchSongs(
                _query,
                offset: append ? _aggNeteaseLoaded : 0,
                limit: _pageSize,
              ),
          ref
              .read(kugouApiProvider)
              .searchSongs(
                _query,
                page: append ? (_aggKugouLoaded ~/ _pageSize) + 1 : 1,
                limit: _pageSize,
              ),
        ]);
        final ne = results[0];
        final kg = results[1];
        final mergedHasMore = ne.hasMore || kg.hasMore;
        if (!mounted) return;
        final mergedItems = _boundedAppend(_songs.items, [
          ...ne.items,
          ...kg.items,
        ]);
        setState(() {
          if (append) {
            _aggNeteaseLoaded += ne.items.length;
            _aggKugouLoaded += kg.items.length;
          } else {
            _aggNeteaseLoaded = ne.items.length;
            _aggKugouLoaded = kg.items.length;
          }
          _songs = _songs.copyWith(
            items: mergedItems,
            total: ne.total + kg.total,
            hasMore: mergedHasMore && mergedItems.length < _maxTabItems,
            loaded: true,
            loading: false,
            loadingMore: false,
          );
        });
        return;
      }
      if (_platform == 'kugou') {
        result = await ref
            .read(kugouApiProvider)
            .searchSongs(
              _query,
              page: append ? (state.items.length ~/ _pageSize) + 1 : 1,
              limit: _pageSize,
            );
      } else {
        final api = ref.read(neteaseApiProvider);
        result = await api.searchSongs(
          _query,
          offset: append ? state.items.length : 0,
          limit: _pageSize,
        );
      }
      if (!mounted) return;
      final mergedItems = _boundedAppend(_songs.items, result.items);
      setState(() {
        _songs = _songs.copyWith(
          items: mergedItems,
          total: result.total,
          hasMore: result.hasMore && mergedItems.length < _maxTabItems,
          loaded: true,
          loading: false,
          loadingMore: false,
        );
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _songs = _songs.copyWith(loading: false, loadingMore: false);
      });
    }
  }

  Future<void> _fetchCovers({required bool append}) async {
    final current = switch (_tab) {
      _SearchTab.albums => _albums,
      _SearchTab.artists => _artists,
      _SearchTab.playlists => _playlists,
      _ => null,
    };
    if (current == null) return;
    if (append) {
      if (!current.loaded || current.loadingMore || !current.hasMore) return;
      _setCoverState(_tab, current.copyWith(loadingMore: true));
    } else {
      if (current.loading) return;
      _setCoverState(_tab, current.copyWith(loading: true));
    }
    _error = '';
    try {
      final SearchResult<CoverItem> result;
      if (_platform == 'kugou') {
        // 酷狗分类搜索（complexsearch v1：album / author / special）
        final api = ref.read(kugouApiProvider);
        final type = switch (_tab) {
          _SearchTab.albums => 'album',
          _SearchTab.artists => 'author',
          _ => 'special',
        };
        final raw = await api.searchByType(
          _query,
          type: type,
          page: append ? (current.items.length ~/ _pageSize) + 1 : 1,
          pagesize: _pageSize,
        );
        result = SearchResult<CoverItem>(
          items: raw.items.whereType<CoverItem>().toList(),
          total: raw.total,
          hasMore: raw.hasMore,
        );
      } else {
        final api = ref.read(neteaseApiProvider);
        final offset = append ? current.items.length : 0;
        result = switch (_tab) {
          _SearchTab.albums => await api.searchAlbums(
            _query,
            offset: offset,
            limit: _pageSize,
          ),
          _SearchTab.artists => await api.searchArtists(
            _query,
            offset: offset,
            limit: _pageSize,
          ),
          _ => await api.searchPlaylists(
            _query,
            offset: offset,
            limit: _pageSize,
          ),
        };
      }
      if (!mounted) return;
      final mergedItems = _boundedAppend(current.items, result.items);
      final merged = _TabState<CoverItem>(
        items: mergedItems,
        total: result.total,
        hasMore: result.hasMore && mergedItems.length < _maxTabItems,
        loaded: true,
        loading: false,
        loadingMore: false,
      );
      setState(() => _setCoverState(_tab, merged));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _setCoverState(
          _tab,
          current.copyWith(loading: false, loadingMore: false),
        );
      });
    }
  }

  void _setCoverState(_SearchTab tab, _TabState<CoverItem> state) {
    switch (tab) {
      case _SearchTab.albums:
        _albums = state;
      case _SearchTab.artists:
        _artists = state;
      case _SearchTab.playlists:
        _playlists = state;
      default:
        break;
    }
  }

  /// 点击歌曲：解析播放 URL → 后台完整转码播放（不阻塞 UI）。
  Future<void> _playTrack(Track track) async {
    if (_resolving) return;
    setState(() => _resolving = true);
    try {
      final String? url;
      if (track.source == 'kugou' && track.kugou != null) {
        url = await ref.read(kugouApiProvider).resolvePlayUrl(track.kugou!);
      } else if (track.source == 'netease') {
        url = await ref.read(neteaseApiProvider).resolvePlayUrl(track.id);
      } else {
        url = null;
      }
      if (!mounted) return;
      if (url == null) {
        _toast(context.l10n.trackListNoPlayableSource);
        return;
      }
      _toast(context.l10n.pageSearchLoadingTrack(track.title));
      // 完整转码在后台执行，await 会阻塞到转码完成，故不等待
      unawaited(_loadUrl(url, track));
    } catch (e) {
      if (mounted) _toast(context.l10n.trackListPlaySourceFailed('$e'));
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  Future<void> _loadUrl(String url, Track track) async {
    try {
      // 插入当前播放之后并播放（队列/切歌可用）
      await ref
          .read(playbackProvider.notifier)
          .playNow(track, resolvedUrl: url);
    } catch (_) {
      // 错误已记入播放日志
    }
  }

  void _toast(String message) => toast(message);

  /// 专辑 / 歌手 / 歌单点击（按平台分发详情弹窗）。
  void _onCoverTap(CoverItem item) {
    if (_platform == 'kugou') {
      switch (_tab) {
        case _SearchTab.playlists:
          showKugouPlaylistDetailDialog(context, item);
        case _SearchTab.albums:
          showKugouAlbumDialog(context, item);
        case _SearchTab.artists:
          showKugouArtistDialog(context, item);
        default:
          break;
      }
      return;
    }
    switch (_tab) {
      case _SearchTab.playlists:
        showPlaylistDetailDialog(context, item);
      default:
        _toast(context.l10n.pageSearchDetailComingSoon(item.title));
    }
  }

  /// 歌曲右键菜单（通用在线曲目菜单 + 页内歌手占位）。
  void _onTrackMenu(Track track, Offset global) {
    showTrackContextMenu(
      context,
      ref: ref,
      track: track,
      position: global,
      onPlay: () => _playTrack(track),
      extra: [
        SContextMenuItem(
          label: context.l10n.menuViewArtist,
          icon: Icons.person_outline,
          onTap: () => _toast(context.l10n.pageSearchArtistComingSoon),
        ),
      ],
    );
  }

  /// 行内红心切换：失败提示登录（对齐「我喜欢」页 _toggleLike 语义；
  /// 成功由 SongList 红心填充态即时反馈，不再 toast）。
  Future<void> _toggleLike(Track track) async {
    final controller = ref.read(likeControllerProvider);
    final ok = await controller.toggle(track);
    if (!mounted) return;
    if (!ok) {
      _toast(track.source == 'kugou'
          ? context.l10n.toastLoginRequiredKugou
          : context.l10n.toastLoginRequiredNetease);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    // 选择性订阅（播放位置/FFT 50ms 更新不重建列表）
    final playingId = ref.watch(playbackProvider.select((s) => s.trackId));
    final isPlaying = ref.watch(playbackProvider.select((s) => s.playing));
    final coverRadius = ref.watch(appPrefsProvider).coverRadius;
    // 红心集合：聚合搜索混平台结果，按行键合并（网易云 id + 酷狗 hash，
    // 与 songLikeKey / LikeController 一致）——修复「已收藏歌曲在搜索结果
    // 中显示为非红心」（此前 SongList 未收到 likedIds）。
    final like = ref.watch(likeControllerProvider);
    final likedIds = {...like.idsFor('netease'), ...like.idsFor('kugou')};

    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 顶栏：标题 + 搜索框 + Tab
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Text(
                        _query.isEmpty ? l10n.commonSearch : _query,
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
                    // 平台切换（对齐原项目平台筛选；酷狗暂仅歌曲；聚合=合并多平台）
                    SSegmented<String>(
                      options: [
                        SSegmentedOption('netease', l10n.platformNetease),
                        SSegmentedOption('kugou', l10n.platformKugou),
                        SSegmentedOption('all', l10n.platformAll),
                      ],
                      selected: _platform,
                      onChanged: _switchPlatform,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TabBar(
                  controller: _tabs,
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
          ),
          const Divider(height: 1),
          // 内容区状态机
          Expanded(
            child: _query.isEmpty
                ? SearchEmptyState(
                    icon: Icons.travel_explore,
                    title: l10n.pageSearchInputHint,
                    subtitle: l10n.pageSearchInputSubtitle,
                  )
                : _error.isNotEmpty
                ? SearchErrorState(
                    message: _error,
                    onRetry: () => _fetch(append: false),
                  )
                : _initialLoading
                ? SearchEmptyState(
                    icon: Icons.hourglass_top,
                    title: l10n.pageSearching,
                  )
                : _emptyResult
                ? SearchEmptyState(
                    icon: Icons.search_off,
                    title: l10n.pageSearchEmpty,
                    subtitle: l10n.pageSearchEmptyHint,
                  )
                : IndexedStack(
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
                        likedIds: likedIds,
                        onToggleLike: _toggleLike,
                        onContextMenu: _onTrackMenu,
                        onReachBottom: () => _fetch(append: true),
                      ),
                      CoverGrid(
                        items: _albums.items,
                        loading: _albums.loadingMore,
                        hasMore: _albums.hasMore,
                        radius: coverRadius,
                        onTap: _onCoverTap,
                        onReachBottom: () => _fetch(append: true),
                      ),
                      CoverGrid(
                        items: _artists.items,
                        loading: _artists.loadingMore,
                        hasMore: _artists.hasMore,
                        radius: coverRadius,
                        onTap: _onCoverTap,
                        onReachBottom: () => _fetch(append: true),
                      ),
                      CoverGrid(
                        items: _playlists.items,
                        loading: _playlists.loadingMore,
                        hasMore: _playlists.hasMore,
                        radius: coverRadius,
                        onTap: _onCoverTap,
                        onReachBottom: () => _fetch(append: true),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
