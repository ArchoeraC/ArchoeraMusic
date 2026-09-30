// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

part of '../library_store.dart';

/// 曲库分页窗口（有界 LRU 页缓存）。
///
/// 列表项高度固定（见 `SongList`），UI 按全局 index → 页号
/// （`index ~/ pageSize`）→ 页内行号映射；本 mixin 只保留视口附近的
/// [maxResidentPages] 页，滚出视口的远端页按 LRU 淘汰，滚回时再按需
/// `listTracks(limit, offset, query)` 重查 SQL，因此常驻内存为 O(视口)。
///
/// 并发约定：
/// - build 期间只允许调用 [ensureIndex]（内部 `scheduleMicrotask` 延后到
///   构建之后再改 provider 状态，避免「build 中修改 provider」）；
/// - 取页以 [_pagerEpoch] 作废过期结果（搜索 / 重载 / 删除后旧页不得回填）。
mixin _LibraryStorePager on Notifier<LibraryState> {
  /// 每页载入曲目数（分页窗口）。
  static const int pageSize = 300;

  /// 常驻页上限：超出即按 LRU 淘汰最久未用页（约 6×300 行，O(视口)）。
  static const int maxResidentPages = 6;

  /// 最多同时进行的取页数（快速滚动时抑制 SQL / 连接风暴）。
  static const int maxConcurrentFetches = 4;

  /// 页号 → 最近使用序号（越大越新）；仅驻留页有效。
  final Map<int, int> _pageRecency = {};
  int _recencyClock = 0;

  /// 在途取页：页号 → 发起时的 epoch（用于去重与过期判定）。
  final Map<int, int> _inFlight = {};

  /// 取页失败的页（本次 epoch 内不再重试，避免 DB 错误时每帧空转）。
  final Set<int> _failedPages = {};

  /// 页缓存代次：reload（搜索 / 扫描 / 删除）时自增，作废在途结果。
  int _pagerEpoch = 0;

  int _pageCount(int total) => (total + pageSize - 1) ~/ pageSize;

  /// 当前代次是否有取页在途。
  bool get _hasInFlight => _inFlight.containsValue(_pagerEpoch);

  /// 清空页缓存 + 载入第一页（含当前搜索条件）+ 曲库聚合统计。
  Future<void> _reloadTracks() async {
    _pagerEpoch++;
    _pageRecency.clear();
    _failedPages.clear();
    final epoch = _pagerEpoch;
    try {
      final db = TracksDb.open();
      final query = state.searchQuery;
      final tracks = db.listTracks(limit: pageSize, query: query);
      final count = db.countTracks(query: query);
      final stats = db.stats();
      db.close();
      if (epoch != _pagerEpoch) return; // 期间又发生一次 reload：本次作废
      final pages = <int, List<TrackRow>>{};
      if (tracks.isNotEmpty) {
        pages[0] = tracks;
        _pageRecency[0] = ++_recencyClock;
      }
      state = state.copyWith(
        trackPages: pages,
        totalCount: count,
        totalSizeBytes: stats.totalSize,
        totalDurationMs: stats.totalDurationMs,
        hasMore: pages.length < _pageCount(count),
        loadingMore: _hasInFlight,
        error: null,
      );
    } catch (_) {
      if (epoch != _pagerEpoch) return;
      state = state.copyWith(
        trackPages: const {},
        totalCount: 0,
        totalSizeBytes: 0,
        totalDurationMs: 0,
        hasMore: false,
        loadingMore: _hasInFlight,
        error: null,
      );
    }
  }

  /// 按全局 index 取已驻留行；未驻留返回 null。
  ///
  /// 只读 + 仅更新内部 LRU 标记，不触发重建，可安全在 build 期间调用。
  TrackRow? _rowAt(int index) {
    if (index < 0 || index >= state.totalCount) return null;
    final page = index ~/ pageSize;
    final rows = state.trackPages[page];
    if (rows == null) return null;
    final off = index - page * pageSize;
    if (off >= rows.length) return null;
    _pageRecency[page] = ++_recencyClock;
    return rows[off];
  }

  /// 声明视口需要全局 [index] 所在页；未驻留则异步取页。
  ///
  /// build 期间调用安全：只置在途标记（普通字段），状态变更延后到微任务。
  void _ensureIndex(int index) {
    if (index < 0 || index >= state.totalCount) return;
    final page = index ~/ pageSize;
    if (state.trackPages.containsKey(page)) return;
    if (_failedPages.contains(page)) return; // 本次 epoch 已失败：不再重试
    final epoch = _pagerEpoch;
    if (_inFlight[page] == epoch) return;
    if (_inFlight.length >= maxConcurrentFetches) return; // 下一帧重建会重试
    _inFlight[page] = epoch;
    scheduleMicrotask(() => unawaited(_fetchPage(page, epoch)));
  }

  /// 预取当前最高驻留页之后的一页（滚动触底加速；末页 / 已在途忽略）。
  Future<void> _loadMore() async {
    final pages = state.trackPages.keys;
    if (pages.isEmpty) return;
    var highest = -1;
    for (final p in pages) {
      if (p > highest) highest = p;
    }
    final next = highest + 1;
    if (next >= _pageCount(state.totalCount)) return;
    if (state.trackPages.containsKey(next)) return;
    if (_failedPages.contains(next)) return;
    final epoch = _pagerEpoch;
    if (_inFlight[next] == epoch) return;
    _inFlight[next] = epoch;
    await _fetchPage(next, epoch);
  }

  /// 当前曲目（如正在播放项）的全局 index；不在任何驻留页则返回 -1。
  int _playingIndexOf(String? id) {
    if (id == null || id.isEmpty) return -1;
    for (final entry in state.trackPages.entries) {
      final rows = entry.value;
      for (var i = 0; i < rows.length; i++) {
        if (rows[i].id == id) return entry.key * pageSize + i;
      }
    }
    return -1;
  }

  Future<void> _fetchPage(int page, int epoch) async {
    if (epoch != _pagerEpoch) {
      if (_inFlight[page] == epoch) _inFlight.remove(page);
      return;
    }
    // 微任务/直接调用时已离开 build：可安全置加载态（尾部加载指示用）。
    if (!state.loadingMore) state = state.copyWith(loadingMore: true);
    List<TrackRow>? rows;
    try {
      final db = TracksDb.open();
      rows = db.listTracks(
        limit: pageSize,
        offset: page * pageSize,
        query: state.searchQuery,
      );
      db.close();
    } catch (_) {
      rows = null;
    }
    if (_inFlight[page] == epoch) _inFlight.remove(page);
    // 期间 searchQuery / 曲库已变（epoch 自增）：丢弃过期结果。
    if (epoch != _pagerEpoch) {
      state = state.copyWith(loadingMore: _hasInFlight);
      return;
    }
    if (rows == null) {
      _failedPages.add(page); // 记录失败，避免每帧重试空转
      state = state.copyWith(loadingMore: _hasInFlight);
      return;
    }
    _insertPage(page, rows);
  }

  /// 插入一页；驻留超限时按 LRU 淘汰最久未用页（刚插入页不参与淘汰）。
  void _insertPage(int page, List<TrackRow> rows) {
    final next = Map<int, List<TrackRow>>.of(state.trackPages);
    _failedPages.remove(page);
    next[page] = rows;
    _pageRecency[page] = ++_recencyClock;
    while (next.length > maxResidentPages) {
      int? victim;
      var oldest = 1 << 30;
      for (final p in next.keys) {
        if (p == page) continue;
        final r = _pageRecency[p] ?? 0;
        if (r < oldest) {
          oldest = r;
          victim = p;
        }
      }
      if (victim == null) break;
      next.remove(victim);
      _pageRecency.remove(victim);
    }
    state = state.copyWith(
      trackPages: next,
      hasMore: next.length < _pageCount(state.totalCount),
      loadingMore: _hasInFlight,
      error: null,
    );
  }
}
