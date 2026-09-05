import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../apis/qqmusic/core/request.dart' show QmErrorKind;
import '../services/netease/netease_api.dart';
import '../services/netease/track.dart';
import '../services/playback/playback_notifier.dart';
import '../services/qqmusic/qqmusic_api.dart' show QqApiException;
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
import '../widgets/search/search_source_state.dart';

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

/// 聚合搜索中单个平台的游标（各平台分页锚点：已加载条数 + 是否还有更多）。
///
/// 还记录该源最近一次失败（[failed]/[error]/[failedAt]），用于「该源暂不可
/// 用」占位 + 手动重试（成功清除）。
class _AggState {
  int loaded = 0;
  bool hasMore = true;
  int total = 0;
  bool failed = false;
  Object? error;
  DateTime? failedAt;
}

/// 参与聚合搜索的平台（netease 用 offset / kugou·qqmusic 用 page 游标）。
const _aggPlatforms = ['netease', 'kugou', 'qqmusic'];

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

  /// 搜索平台（'netease' / 'kugou' / 'qqmusic' / 'all' 聚合）。
  String _platform = 'netease';

  /// 聚合搜索（'all'）：**songs** tab 各平台分页游标。
  final Map<String, _AggState> _songAgg = {
    for (final p in _aggPlatforms) p: _AggState(),
  };

  /// 聚合搜索（'all'）：**albums/artists/playlists** tab 各平台分页游标。
  final Map<_SearchTab, Map<String, _AggState>> _coverAgg = {};

  /// 来源失败后的退避闸门（防连打触发更强风控）。
  final SearchSourceCooldown _sourceCooldown = SearchSourceCooldown();

  Map<String, _AggState> _coverAggFor(_SearchTab tab) =>
      _coverAgg.putIfAbsent(tab, () {
        return {for (final p in _aggPlatforms) p: _AggState()};
      });

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

  /// 切换搜索平台（'netease' / 'kugou' / 'qqmusic' 单平台；'all' 三方
  /// 并行合并——songs 与 albums/artists/playlists 各 tab 均聚合）。
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
      for (final st in _songAgg.values) {
        st
          ..loaded = 0
          ..hasMore = true
          ..total = 0
          ..failed = false
          ..error = null
          ..failedAt = null;
      }
      for (final map in _coverAgg.values) {
        for (final st in map.values) {
          st
            ..loaded = 0
            ..hasMore = true
            ..total = 0
            ..failed = false
            ..error = null
            ..failedAt = null;
        }
      }
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
      if (_platform == 'all') {
        await _fetchSongsAll(append: append);
        return;
      }
      final result = await _searchSongsFrom(
        _platform,
        append: append,
        loaded: state.items.length,
      );
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
      if (_platform == 'qqmusic') _sourceCooldown.markFailed('qqmusic');
      setState(() {
        _error = _failureDetail(_platform, e);
        _songs = _songs.copyWith(loading: false, loadingMore: false);
      });
    }
  }

  /// 单个平台搜索单曲（[loaded] = 该平台已累计条数，append 时据此取下一页；
  /// netease 用 offset，kugou/qqmusic 用 page）。
  Future<SearchResult<Track>> _searchSongsFrom(
    String platform, {
    required bool append,
    required int loaded,
  }) {
    final page = append ? (loaded ~/ _pageSize) + 1 : 1;
    if (platform == 'kugou') {
      return ref
          .read(kugouApiProvider)
          .searchSongs(_query, page: page, limit: _pageSize);
    }
    if (platform == 'qqmusic') {
      return ref
          .read(qqMusicApiProvider)
          .searchSongs(_query, page: page, limit: _pageSize);
    }
    return ref.read(neteaseApiProvider).searchSongs(
      _query,
      offset: append ? loaded : 0,
      limit: _pageSize,
    );
  }

  /// 聚合搜索（'all'）单曲：网易 + 酷狗 + QQ **三方并行、各源独立容错**。
  ///
  /// 任一源失败只标记该源（展示「该源暂不可用」占位 + 手动重试），成功源
  /// 照常展示——修复「QQ 一源失败 → 整页 all 聚合一起失败」的问题。
  Future<void> _fetchSongsAll({required bool append}) async {
    final active = append
        ? _aggPlatforms
            .where((p) => _songAgg[p]!.hasMore && !_songAgg[p]!.failed)
            .toList()
        : _aggPlatforms;
    if (active.isEmpty) return;
    await _loadSongsFrom(active, append: append);
  }

  /// 对给定来源集合并行拉一页（各源独立 try/catch），并合并进当前列表。
  Future<void> _loadSongsFrom(List<String> sources, {required bool append}) async {
    final attempts = await fetchSourcesIndependently<Track>(
      sources,
      (p) => _searchSongsFrom(p, append: append, loaded: _songAgg[p]!.loaded),
    );
    if (!mounted) return;
    final okItems = <Track>[];
    var anyOk = false;
    for (final a in attempts) {
      final st = _songAgg[a.source]!;
      if (a.ok) {
        anyOk = true;
        st
          ..failed = false
          ..error = null
          ..failedAt = null
          ..total = a.result!.total
          ..hasMore = a.result!.hasMore;
        st.loaded = append ? st.loaded + a.result!.items.length : a.result!.items.length;
        okItems.addAll(a.result!.items);
        if (a.source == 'qqmusic') _sourceCooldown.clear('qqmusic');
      } else {
        st
          ..failed = true
          ..error = a.error
          ..failedAt = DateTime.now()
          ..hasMore = false;
        if (a.source == 'qqmusic') _sourceCooldown.markFailed('qqmusic');
      }
    }
    final merged = _boundedAppend(_songs.items, okItems);
    setState(() {
      final showError = !anyOk && merged.isEmpty && !append;
      if (showError) {
        _error = _aggAllFailedText(_songAgg);
      } else if (anyOk) {
        _error = '';
      }
      _songs = _songs.copyWith(
        items: merged,
        total: _aggTotal(_songAgg),
        hasMore: _aggAnyMore(_songAgg) && merged.length < _maxTabItems,
        loaded: _songs.loaded || anyOk,
        loading: false,
        loadingMore: false,
      );
    });
  }

  /// 单曲 tab：手动重试某个失败来源（从该源断点续拉，不影响其它来源）。
  Future<void> _retrySongsSource(String source) async {
    final st = _songAgg[source];
    if (st == null || !st.failed) return;
    if (_songs.loading || _songs.loadingMore) return;
    if (source == 'qqmusic' && _sourceCooldown.cooling('qqmusic')) {
      _toast(context.l10n.searchWaitRetry);
      return;
    }
    _songs = _songs.copyWith(loadingMore: true);
    setState(() {});
    await _loadSongsFrom([source], append: true);
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
      if (_platform == 'all') {
        await _fetchCoversAll(append: append);
        return;
      }
      final result = await _searchCoversFrom(
        _platform,
        tab: _tab,
        append: append,
        loaded: current.items.length,
      );
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
      if (_platform == 'qqmusic') _sourceCooldown.markFailed('qqmusic');
      setState(() {
        _error = _failureDetail(_platform, e);
        _setCoverState(
          _tab,
          current.copyWith(loading: false, loadingMore: false),
        );
      });
    }
  }

  /// 酷狗分类搜索 type（album / author / special）。
  static String _kugouCoverType(_SearchTab tab) => switch (tab) {
    _SearchTab.albums => 'album',
    _SearchTab.artists => 'author',
    _ => 'special',
  };

  /// 单个平台专辑/歌手/歌单下一页（[loaded] = 该平台已累计条数）。
  Future<SearchResult<CoverItem>> _searchCoversFrom(
    String platform, {
    required _SearchTab tab,
    required bool append,
    required int loaded,
  }) {
    // QQ 歌手搜索单页上限 30（>30 服务端返回空），其余 50：分页除数跟随
    // 实际请求量，避免页号漂移。
    final qqArtists = platform == 'qqmusic' && tab == _SearchTab.artists;
    final requestSize = qqArtists ? 30 : _pageSize;
    final page = append ? (loaded ~/ requestSize) + 1 : 1;
    if (platform == 'kugou') {
      return () async {
        final raw = await ref
            .read(kugouApiProvider)
            .searchByType(
              _query,
              type: _kugouCoverType(tab),
              page: page,
              pagesize: _pageSize,
            );
        return SearchResult<CoverItem>(
          items: raw.items.whereType<CoverItem>().toList(),
          total: raw.total,
          hasMore: raw.hasMore,
        );
      }();
    }
    if (platform == 'qqmusic') {
      final api = ref.read(qqMusicApiProvider);
      return switch (tab) {
        _SearchTab.albums => api.searchAlbums(
          _query,
          page: page,
          limit: requestSize,
        ),
        _SearchTab.artists => api.searchArtists(
          _query,
          page: page,
          limit: requestSize,
        ),
        _ => api.searchPlaylists(_query, page: page, limit: requestSize),
      };
    }
    final api = ref.read(neteaseApiProvider);
    final offset = append ? loaded : 0;
    return switch (tab) {
      _SearchTab.albums => api.searchAlbums(
        _query,
        offset: offset,
        limit: _pageSize,
      ),
      _SearchTab.artists => api.searchArtists(
        _query,
        offset: offset,
        limit: _pageSize,
      ),
      _ => api.searchPlaylists(_query, offset: offset, limit: _pageSize),
    };
  }

  /// 聚合专辑/歌手/歌单（'all'）：三方并行、各源独立容错（见 _fetchSongsAll）。
  Future<void> _fetchCoversAll({required bool append}) async {
    final tab = _tab;
    final states = _coverAggFor(tab);
    final active = append
        ? _aggPlatforms
            .where((p) => states[p]!.hasMore && !states[p]!.failed)
            .toList()
        : _aggPlatforms;
    if (active.isEmpty) return;
    await _loadCoversFrom(tab, active, append: append);
  }

  /// 对给定来源集合并行拉一页（各源独立容错），合并进对应 cover tab。
  Future<void> _loadCoversFrom(
    _SearchTab tab,
    List<String> sources, {
    required bool append,
  }) async {
    final states = _coverAggFor(tab);
    final attempts = await fetchSourcesIndependently<CoverItem>(
      sources,
      (p) => _searchCoversFrom(p, tab: tab, append: append, loaded: states[p]!.loaded),
    );
    if (!mounted) return;
    final current = _coverOf(tab);
    if (current == null) return;
    final okItems = <CoverItem>[];
    var anyOk = false;
    for (final a in attempts) {
      final st = states[a.source]!;
      if (a.ok) {
        anyOk = true;
        st
          ..failed = false
          ..error = null
          ..failedAt = null
          ..total = a.result!.total
          ..hasMore = a.result!.hasMore;
        st.loaded = append ? st.loaded + a.result!.items.length : a.result!.items.length;
        okItems.addAll(a.result!.items);
        if (a.source == 'qqmusic') _sourceCooldown.clear('qqmusic');
      } else {
        st
          ..failed = true
          ..error = a.error
          ..failedAt = DateTime.now()
          ..hasMore = false;
        if (a.source == 'qqmusic') _sourceCooldown.markFailed('qqmusic');
      }
    }
    final merged = _boundedAppend(current.items, okItems);
    setState(() {
      final showError = !anyOk && merged.isEmpty && !append;
      if (showError) {
        _error = _aggAllFailedText(states);
      } else if (anyOk) {
        _error = '';
      }
      final next = _TabState<CoverItem>(
        items: merged,
        total: _aggTotal(states),
        hasMore: _aggAnyMore(states) && merged.length < _maxTabItems,
        loaded: current.loaded || anyOk,
        loading: false,
        loadingMore: false,
      );
      _setCoverState(tab, next);
    });
  }

  /// cover tab：手动重试某个失败来源（断点续拉，不影响其它来源）。
  Future<void> _retryCoversSource(_SearchTab tab, String source) async {
    final states = _coverAggFor(tab);
    final st = states[source];
    if (st == null || !st.failed) return;
    final cur = _coverOf(tab);
    if (cur == null || cur.loading || cur.loadingMore) return;
    if (source == 'qqmusic' && _sourceCooldown.cooling('qqmusic')) {
      _toast(context.l10n.searchWaitRetry);
      return;
    }
    _setCoverState(tab, cur.copyWith(loadingMore: true));
    setState(() {});
    await _loadCoversFrom(tab, [source], append: true);
  }

  /// 当前 tab 对应 cover 状态。
  _TabState<CoverItem>? _coverOf(_SearchTab tab) => switch (tab) {
    _SearchTab.albums => _albums,
    _SearchTab.artists => _artists,
    _SearchTab.playlists => _playlists,
    _ => null,
  };

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

  // ── 聚合「各源独立」辅助（失败标记 / 退避 / 文案） ────────────────

  /// 累计非失败来源的 total。
  static int _aggTotal(Map<String, _AggState> states) {
    var total = 0;
    for (final st in states.values) {
      if (!st.failed) total += st.total;
    }
    return total;
  }

  /// 任一非失败来源还有更多。
  static bool _aggAnyMore(Map<String, _AggState> states) =>
      states.values.any((st) => !st.failed && st.hasMore);

  /// 当前 tab 聚合游标（songs → _songAgg；cover tab → _coverAggFor）。
  Map<String, _AggState> _aggStatesOf(_SearchTab tab) =>
      tab == _SearchTab.songs ? _songAgg : _coverAggFor(tab);

  /// 当前 tab 已失败的来源（用于横幅展示 + 重试按钮）。
  List<MapEntry<String, _AggState>> _failedAggSources(_SearchTab tab) =>
      _aggStatesOf(tab).entries.where((e) => e.value.failed).toList();

  /// 聚合整批都失败（首屏无任何可用结果）时的错误文案。
  String _aggAllFailedText(Map<String, _AggState> states) {
    final lines = <String>[];
    for (final p in _aggPlatforms) {
      final st = states[p]!;
      if (st.failed) lines.add('${_platformLabel(p)}：${_failureDetail(p, st.error)}');
    }
    return lines.join('\n');
  }

  /// 单来源失败的说明文案：QQ 走本地化分类；其余平台保留原始异常。
  String _failureDetail(String source, Object? err) {
    if (source == 'qqmusic' && err is QqApiException) {
      return _qqFailureText(err);
    }
    return '$err';
  }

  /// QQ 失败文案映射：风控 → 带内码提示；网络 → 网络提示；业务码 → 带码。
  String _qqFailureText(QqApiException e) {
    final l = context.l10n;
    final kind = e.kind;
    if (kind == QmErrorKind.risk) return l.searchQqRiskDetail(e.code ?? 0);
    if (kind == QmErrorKind.transient) return l.searchNetworkError;
    if (kind == QmErrorKind.code) {
      return l.searchPlatformError('${e.code ?? '?'}');
    }
    return e.message;
  }

  /// 错误态（SearchErrorState / 聚合全败）的重试入口：QQ 失败后先退避，
  /// 避免连打把风控阈值刷得更高。
  void _retryFromError() {
    final qqInvolved = _platform == 'qqmusic' || _platform == 'all';
    if (qqInvolved && _sourceCooldown.cooling('qqmusic')) {
      _toast(context.l10n.searchWaitRetry);
      return;
    }
    unawaited(_fetch(append: false));
  }

  /// 平台显示名（横幅「{source}」用）。
  String _platformLabel(String source) {
    final l = context.l10n;
    return switch (source) {
      'netease' => l.platformNetease,
      'kugou' => l.platformKugou,
      'qqmusic' => l.platformQQMusic,
      _ => source,
    };
  }

  /// 聚合搜索：当前 tab 存在失败来源时的「该源暂不可用」横幅（成功源不受影响，
  /// 失败源带手动重试；QQ 在冷却期内按钮禁用）。
  Widget _aggFailureBanner() {
    if (_platform != 'all') return const SizedBox.shrink();
    final failed = _failedAggSources(_tab);
    if (failed.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final onRetry = _tab == _SearchTab.songs
        ? _retrySongsSource
        : (String s) => _retryCoversSource(_tab, s);
    final items = <Widget>[];
    for (final entry in failed) {
      final source = entry.key;
      final st = entry.value;
      final detail = _failureDetail(source, st.error).trim();
      final qqCooling = source == 'qqmusic' && _sourceCooldown.cooling('qqmusic');
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
                    l10n.searchSourceFailed(_platformLabel(source)),
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
              onPressed: qqCooling ? null : () => onRetry(source),
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
      } else if (track.source == 'qqmusic') {
        url = await ref.read(qqMusicApiProvider).resolvePlayUrl(track);
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
  ///
  /// 聚合（'all'）下结果混三方平台，按 **CoverItem.source** 分发到对应
  /// 平台详情弹窗（网易云歌单/专辑/歌手、酷狗、QQ 均已接通曲目列表）。
  void _onCoverTap(CoverItem item) {
    final src = _platform == 'all' ? item.source : _platform;
    if (src == 'kugou') {
      _openKugouCover(item);
      return;
    }
    if (src == 'qqmusic') {
      _openQqCover(item);
      return;
    }
    _openNeteaseCover(item);
  }

  void _openNeteaseCover(CoverItem item) {
    switch (_tab) {
      case _SearchTab.playlists:
        showPlaylistDetailDialog(context, item);
      case _SearchTab.albums:
        showNeteaseAlbumDialog(context, item);
      case _SearchTab.artists:
        showNeteaseArtistDialog(context, item);
      default:
        break;
    }
  }

  void _openKugouCover(CoverItem item) {
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
  }

  void _openQqCover(CoverItem item) {
    switch (_tab) {
      case _SearchTab.playlists:
        showQqPlaylistDetailDialog(context, item);
      case _SearchTab.albums:
        showQqAlbumDetailDialog(context, item);
      case _SearchTab.artists:
        showQqArtistDetailDialog(context, item);
      default:
        break;
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

  /// 红心失败提示（各平台独立文案；QQ 在线同步失败提示实验接口可读错误）。
  String _likeFailText(String source) {
    final l10n = context.l10n;
    return switch (source) {
      'kugou' => l10n.toastLoginRequiredKugou,
      'qqmusic' => l10n.toastQqLikeSyncFailed,
      _ => l10n.toastLoginRequiredNetease,
    };
  }

  /// 行内红心切换：失败提示登录（对齐「我喜欢」页 _toggleLike 语义；
  /// 成功由 SongList 红心填充态即时反馈，不再 toast）。QQ 走本地红心
  /// （未登录也成功）；仅登录后的在线实验收藏失败才回滚并提示。
  Future<void> _toggleLike(Track track) async {
    final controller = ref.read(likeControllerProvider);
    final ok = await controller.toggle(track);
    if (!mounted) return;
    if (!ok) {
      _toast(_likeFailText(track.source));
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
    // 红心集合：聚合/单平台混来源结果按行键合并（网易云 id + 酷狗 hash
    // + QQ songmid，与 songLikeKey / LikeController 一致）。QQ 音乐红心键
    // 为 songmid（字母数字），与网易云数字 id 不会串扰；union 集合对三种
    // 行键均有效——修复「已收藏歌曲显示为非红心」与「QQ 曲目误走网易云键」。
    final like = ref.watch(likeControllerProvider);
    final likedIds = {
      ...like.idsFor('netease'),
      ...like.idsFor('kugou'),
      ...like.idsFor('qqmusic'),
    };
    final rowLikedIds = likedIds;
    // QQ 音乐红心已接入（本机 + 在线实验）：任意平台（含 'all' 聚合与
    // qqmusic 单平台）行内红心可用。
    final onToggleLike = _toggleLike;

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
                    // 平台切换（对齐原项目平台筛选；QQ 音乐四分类同酷狗；
                    // 聚合=合并网易云+酷狗）
                    SSegmented<String>(
                      options: [
                        SSegmentedOption('netease', l10n.platformNetease),
                        SSegmentedOption('kugou', l10n.platformKugou),
                        SSegmentedOption('qqmusic', l10n.platformQQMusic),
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
                    onRetry: _retryFromError,
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
                : Column(
                    children: [
                      _aggFailureBanner(),
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
                              onToggleLike: onToggleLike,
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
                  ),
          ),
        ],
      ),
    );
  }
}
