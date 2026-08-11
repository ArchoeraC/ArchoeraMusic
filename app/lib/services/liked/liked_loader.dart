/// 「我喜欢」收藏列表分页加载器（ChangeNotifier）。
///
/// 借鉴 SPlayer-Next 库加载策略（IndexedDB 缓存 + 先缓存上屏再网络刷新）：
/// - **缓存秒开**：进页面先读 SQLite 缓存（已加载段）立即渲染；
/// - **SWR 后台刷新**：随后拉取最新第一页替换上屏并回写缓存；
/// - **按需加载**：滚动触底才拉下一页（网易云 song_detail 批量补详情 /
///   酷狗 get_list_all_file 单页），不一次性暴力拉全量；
/// - **内存友好**：列表只持有已加载段，Track 对象随滚动增量生成，
///   全量收藏不常驻（GC 友好）。
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../stores/providers.dart';
import '../netease/track.dart';
import 'liked_cache.dart';

/// 单页拉取结果。
typedef LikedPageResult = (List<Track>, int);

/// 「我喜欢」列表控制器：统一网易云 / 酷狗的分页 + 缓存策略。
class LikedListController extends ChangeNotifier {
  LikedListController(this._ref, {required this.platform});

  final WidgetRef _ref;

  /// 'netease' | 'kugou'。
  final String platform;

  /// 网易云 song_detail 每批补详情条数（一次调用即可补 300 首）。
  static const int neteasePageSize = 300;

  /// 酷狗 get_list_all_file 每页条数（接口固定上限）。
  static const int kugouPageSize = 60;

  List<Track> _tracks = const [];
  int _total = 0;
  bool _loaded = false;
  bool _loading = false;
  bool _loadingMore = false;
  String _error = '';

  bool _initialized = false;
  bool _refreshing = false;
  int _nextOffset = 0;

  /// 网易云歌单 trackIds（进页面刷新时拉一次，触底加载复用，避免
  /// 每页重复请求「我喜欢的音乐」歌单详情）。
  List<String>? _neteaseIds;

  /// 当前已加载歌曲（按收藏先后，最新在前）。
  List<Track> get tracks => _tracks;

  /// 收藏总数（接口返回；缓存命中时为缓存总数）。
  int get total => _total;

  /// 是否已有可展示数据（缓存或网络成功）。
  bool get loaded => _loaded;

  /// 首屏加载中（无任何数据时页面显示 loading）。
  bool get loading => _loading;

  bool get loadingMore => _loadingMore;

  String get error => _error;

  /// 触底加载更多可用（已加载数 < 总数）。
  bool get hasMore => _loaded && _tracks.length < _total;

  /// 当前平台登录用户 key（网易云 uid / 酷狗 userid），缓存键。
  String? get _userKey {
    if (platform == 'kugou') {
      return _ref.read(kugouApiProvider).session?.userid;
    }
    return _ref.read(neteaseAuthProvider)?.userId;
  }

  static LikedCacheStore _cacheStore() => LikedCacheStore.shared;

  /// 首次进入：缓存秒开 + SWR 后台刷新第一页。幂等（重复调用忽略）。
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    await _hydrateFromCache();
    await refresh();
  }

  /// SWR 刷新：拉最新第一页替换上屏，并回写缓存。
  Future<void> refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    _loading = true;
    _error = '';
    notifyListeners();
    try {
      final key = _userKey;
      if (key == null) return; // 未登录由页面显示登录引导
      // 网易云刷新时重新拉 trackIds（收藏可能已变化）
      _neteaseIds = null;
      final (page, total) = await _fetchPage(0);
      _tracks = page;
      _total = total;
      _nextOffset = page.length;
      _loaded = true;
      _cacheStore().replace(platform, key, page, total: total);
    } catch (e) {
      // 有缓存时静默保留缓存展示；无缓存才报错
      if (_tracks.isEmpty) _error = '$e';
      _loaded = true;
    } finally {
      _loading = false;
      _refreshing = false;
      notifyListeners();
    }
  }

  /// 触底加载下一页（增量追加 + 缓存增量落盘）。
  Future<void> loadMore() async {
    if (!hasMore || _loadingMore || _refreshing) return;
    _loadingMore = true;
    notifyListeners();
    try {
      final (page, total) = await _fetchPage(_nextOffset);
      if (page.isEmpty) {
        // 接口已无更多，按实际条数收敛 total
        _total = _tracks.length;
        return;
      }
      final startIndex = _tracks.length;
      final merged = [..._tracks, ...page];
      _tracks = merged;
      _total = total;
      _nextOffset = merged.length;
      final key = _userKey;
      if (key != null) {
        _cacheStore().append(
          platform,
          key,
          page,
          startIndex: startIndex,
          total: total,
        );
      }
    } catch (_) {
      // 触底加载失败静默（保留已加载部分，下次滚动再试）
    } finally {
      _loadingMore = false;
      notifyListeners();
    }
  }

  /// 取消喜欢后从列表移除该行（不重新拉取）。
  void removeTrack(String source, String id) {
    final before = _tracks.length;
    _tracks = _tracks
        .where((t) => !(t.source == source && t.id == id))
        .toList();
    if (_tracks.length != before) {
      _total = _tracks.length;
      notifyListeners();
    }
  }

  /// 重置（登录态变化 / 切换平台时调用，下次 init 重新加载）。
  void reset() {
    _initialized = false;
    _tracks = const [];
    _total = 0;
    _loaded = false;
    _loading = false;
    _loadingMore = false;
    _error = '';
    _nextOffset = 0;
    _neteaseIds = null;
    notifyListeners();
  }

  // ── 内部实现 ────────────────────────────────────────────────

  /// 读缓存已加载段上屏（无缓存则跳过）。
  Future<void> _hydrateFromCache() async {
    final key = _userKey;
    if (key == null) return;
    final store = _cacheStore();
    final cachedTotal = store.total(platform, key);
    if (cachedTotal == null || cachedTotal == 0) return;
    final cached = store.loadRange(platform, key, limit: neteasePageSize);
    if (cached.isEmpty) return;
    _tracks = cached;
    _total = cachedTotal;
    _nextOffset = cached.length;
    _loaded = true;
    notifyListeners();
  }

  /// 拉取 [offset] 起的单页数据（酷狗按页号映射；网易云按 trackIds 切片）。
  Future<LikedPageResult> _fetchPage(int offset) async {
    if (platform == 'kugou') {
      final page = offset ~/ kugouPageSize + 1;
      return _ref
          .read(kugouApiProvider)
          .likedTracksPage(page: page, pagesize: kugouPageSize);
    }
    final account = _ref.read(neteaseAuthProvider);
    if (account == null) return (const <Track>[], 0);
    final api = _ref.read(neteaseApiProvider);
    _neteaseIds ??= await api.likedTrackIds(account.userId);
    final ids = _neteaseIds!;
    if (offset >= ids.length) return (const <Track>[], ids.length);
    final end = math.min(offset + neteasePageSize, ids.length);
    final tracks = await api.songsDetailByIds(ids.sublist(offset, end));
    return (tracks, ids.length);
  }
}
