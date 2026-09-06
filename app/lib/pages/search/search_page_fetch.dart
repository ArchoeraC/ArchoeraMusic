// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// ignore_for_file: invalid_use_of_protected_member

part of '../search_page.dart';

extension _SearchPageFetch on _SearchPageState {
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

  Map<String, _AggState> _aggStatesOf(_SearchTab tab) =>
      tab == _SearchTab.songs ? _songAgg : _coverAggFor(tab);

  List<MapEntry<String, _AggState>> _failedAggSources(_SearchTab tab) =>
      _aggStatesOf(tab).entries.where((e) => e.value.failed).toList();

  /// 追加下一页并限制累计条数：超 [maxItems] 从尾部截断（保留最新），
  /// 由调用方据返回长度决定是否继续加载。
  List<T> _boundedAppend<T>(List<T> current, List<T> next) {
    if (next.isEmpty) return current;
    final merged = [...current, ...next];
    return merged.length > _SearchPageState._maxTabItems
        ? merged.sublist(merged.length - _SearchPageState._maxTabItems)
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
          hasMore:
              result.hasMore &&
              mergedItems.length < _SearchPageState._maxTabItems,
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
    final page = append ? (loaded ~/ _SearchPageState._pageSize) + 1 : 1;
    if (platform == 'kugou') {
      return ref
          .read(kugouApiProvider)
          .searchSongs(_query, page: page, limit: _SearchPageState._pageSize);
    }
    if (platform == 'qqmusic') {
      return ref
          .read(qqMusicApiProvider)
          .searchSongs(_query, page: page, limit: _SearchPageState._pageSize);
    }
    return ref
        .read(neteaseApiProvider)
        .searchSongs(
          _query,
          offset: append ? loaded : 0,
          limit: _SearchPageState._pageSize,
        );
  }

  /// 聚合搜索（'all'）单曲：网易 + KG + QQ **三方并行、各源独立容错**。
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
  Future<void> _loadSongsFrom(
    List<String> sources, {
    required bool append,
  }) async {
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
        st.loaded = append
            ? st.loaded + a.result!.items.length
            : a.result!.items.length;
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
        hasMore:
            _aggAnyMore(_songAgg) &&
            merged.length < _SearchPageState._maxTabItems,
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
        hasMore:
            result.hasMore &&
            mergedItems.length < _SearchPageState._maxTabItems,
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

  /// KG分类搜索 type（album / author / special）。
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
    final requestSize = qqArtists ? 30 : _SearchPageState._pageSize;
    final page = append ? (loaded ~/ requestSize) + 1 : 1;
    if (platform == 'kugou') {
      return () async {
        final raw = await ref
            .read(kugouApiProvider)
            .searchByType(
              _query,
              type: _kugouCoverType(tab),
              page: page,
              pagesize: _SearchPageState._pageSize,
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
        limit: _SearchPageState._pageSize,
      ),
      _SearchTab.artists => api.searchArtists(
        _query,
        offset: offset,
        limit: _SearchPageState._pageSize,
      ),
      _ => api.searchPlaylists(
        _query,
        offset: offset,
        limit: _SearchPageState._pageSize,
      ),
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
      (p) => _searchCoversFrom(
        p,
        tab: tab,
        append: append,
        loaded: states[p]!.loaded,
      ),
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
        st.loaded = append
            ? st.loaded + a.result!.items.length
            : a.result!.items.length;
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
        hasMore:
            _aggAnyMore(states) &&
            merged.length < _SearchPageState._maxTabItems,
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

  /// 累计非失败来源的 total。
  int _aggTotal(Map<String, _AggState> states) {
    var total = 0;
    for (final st in states.values) {
      if (!st.failed) total += st.total;
    }
    return total;
  }

  /// 任一非失败来源还有更多。
  bool _aggAnyMore(Map<String, _AggState> states) =>
      states.values.any((st) => !st.failed && st.hasMore);

  /// 聚合整批都失败（首屏无任何可用结果）时的错误文案。
  String _aggAllFailedText(Map<String, _AggState> states) {
    final lines = <String>[];
    for (final p in _aggPlatforms) {
      final st = states[p]!;
      if (st.failed) {
        lines.add('${_platformLabel(p)}：${_failureDetail(p, st.error)}');
      }
    }
    return lines.join('\n');
  }
}
