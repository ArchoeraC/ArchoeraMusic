/// 「我喜欢」收藏列表全局数据源（ChangeNotifier，由 Riverpod provider 持有）。
///
/// **只管列表全量**：酷狗 / 网易云收藏 Track 一次拉全、缓存秒开。
/// 红心状态与列表解耦——LikeController.sync 走各平台轻量 id 集合
/// （网易云 likelist / 酷狗 likedHashSet 只取 hash），不经过这里，
/// 避免启动同步触发全量拉取（与收藏页并行双拉、被进程退出/写失败干扰）。
///
/// 缓存策略（对齐 SPlayer-Next 库加载）：进收藏页先读 SQLite 缓存
/// 「秒开」，后台 SWR 全量拉取替换上屏并回写缓存——回写在后台 isolate
/// （LikedCacheStore 内部 [Isolate.run]），不阻塞 UI。
/// 无分页：列表一次持有全量 Track（元数据轻量，千级仅数 MB）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../stores/providers.dart';
import '../netease/track.dart';
import 'liked_cache.dart';

/// 平台收藏列表状态（内存态；与磁盘缓存解耦）。
class _PlatformLiked {
  List<Track> tracks = const [];
  int total = 0;
  bool loaded = false;
  bool loading = false;
  String error = '';
  bool initialized = false;
  bool refreshing = false;
}

/// 全局「我喜欢」数据源（'netease' | 'kugou' 双平台，全量 + 缓存）。
class LikedStore extends ChangeNotifier {
  LikedStore(this._ref);

  final Ref _ref;

  final Map<String, _PlatformLiked> _platforms = {};

  _PlatformLiked _state(String platform) =>
      _platforms.putIfAbsent(platform, _PlatformLiked.new);

  /// 平台当前已加载歌曲（全量，按收藏先后，最新在前）。
  List<Track> tracks(String platform) => _state(platform).tracks;

  /// 平台收藏总数（接口返回；缓存命中时为缓存总数）。
  int total(String platform) => _state(platform).total;

  /// 平台是否已有可展示数据（缓存或网络成功）。
  bool loaded(String platform) => _state(platform).loaded;

  /// 平台首屏加载中（无任何数据时页面显示 loading）。
  bool loading(String platform) => _state(platform).loading;

  /// 平台加载错误（无缓存时的失败信息）。
  String error(String platform) => _state(platform).error;

  /// 当前平台登录用户 key（网易云 uid / 酷狗 userid），缓存键。
  String? _userKey(String platform) {
    if (platform == 'kugou') {
      return _ref.read(kugouApiProvider).session?.userid;
    }
    return _ref.read(neteaseAuthProvider)?.userId;
  }

  /// 首次进入：缓存秒开 + 网络刷新全量。幂等（重复调用忽略）。
  ///
  /// 缓存读取失败**不阻断**网络刷新（降级为直接加载并记录）——否则
  /// initialized 已置位、后续 ensureLoaded 全部短路，刷新被永久跳过
  /// （历史「无法加载」根因）。
  Future<void> ensureLoaded(String platform) async {
    final s = _state(platform);
    if (s.initialized) return;
    s.initialized = true;
    try {
      await _hydrateFromCache(platform);
    } catch (e) {
      debugPrint('[liked] 缓存读取失败（降级直接加载）: $e');
    }
    await refresh(platform);
  }

  /// 刷新：全量拉取替换上屏并**回写 SQLite 缓存**（缓存「秒开」的前提——
  /// 否则每次进收藏页都全量重拉，数据库形同虚设）。拉取失败保留旧缓存
  /// 展示（下次进入仍可秒开，不误删快照）。
  Future<void> refresh(String platform, {bool writeCache = true}) async {
    final s = _state(platform);
    if (s.refreshing) return;
    s.refreshing = true;
    s.loading = true;
    s.error = '';
    notifyListeners();
    try {
      final key = _userKey(platform);
      if (key == null) return; // 未登录由页面显示登录引导
      final tracks = await _fetchAll(platform);
      s.tracks = tracks;
      s.total = tracks.length;
      s.loaded = true;
      if (writeCache) {
        try {
          await LikedCacheStore.shared.replace(platform, key, tracks);
        } catch (e) {
          debugPrint('[liked] 缓存写回失败（不影响展示）: $e');
        }
      }
    } catch (e) {
      // 有缓存时静默保留缓存展示；无缓存才报错
      if (s.tracks.isEmpty) s.error = '$e';
      s.loaded = true;
    } finally {
      s.refreshing = false;
      s.loading = false;
      notifyListeners();
    }
  }

  /// 增量更新：新喜欢一首歌时插入列表头部（最新在前）并**写库**——
  /// 与「刷新=全量重拉+写库」同一持久化语义：列表任何变化都落库，
  /// 否则新喜欢的歌在下次全量刷新前从列表/缓存快照中缺失。
  ///
  /// 仅当列表已加载（进过收藏页）时维护；未加载时跳过——全量刷新
  /// 自然会包含该歌，无需维护。
  Future<void> addTrack(String platform, Track t) async {
    final s = _state(platform);
    if (!s.loaded) return;
    // 防重复插入（幂等）
    if (s.tracks.any((x) => x.source == t.source && x.id == t.id)) return;
    s.tracks = [t, ...s.tracks];
    s.total = s.tracks.length;
    notifyListeners();
    final key = _userKey(platform);
    if (key == null) return;
    try {
      await LikedCacheStore.shared.replace(platform, key, s.tracks);
    } catch (e) {
      debugPrint('[liked] 缓存增量写入失败: $e');
    }
  }

  /// 取消喜欢后从列表移除该行（不重新拉取），并同步重写缓存快照
  /// （显式操作写回——否则重启后已取消的歌会从缓存「复活」）。
  Future<void> removeTrack(String platform, String source, String id) async {
    final s = _state(platform);
    final before = s.tracks.length;
    s.tracks = s.tracks
        .where((t) => !(t.source == source && t.id == id))
        .toList();
    if (s.tracks.length == before) return;
    s.total = s.tracks.length;
    notifyListeners();
    final key = _userKey(platform);
    if (key == null) return;
    try {
      await LikedCacheStore.shared.replace(platform, key, s.tracks);
    } catch (e) {
      debugPrint('[liked] 缓存移除失败: $e');
    }
  }

  /// 重置平台（登录态变化时调用，下次 [ensureLoaded] 重新加载）。
  void reset(String platform) {
    final s = _state(platform);
    s.initialized = false;
    s.tracks = const [];
    s.total = 0;
    s.loaded = false;
    s.loading = false;
    s.error = '';
    s.refreshing = false; // 清 refreshing，避免重置后刷新被旧请求挡住
    notifyListeners();
  }

  // ── 内部实现 ────────────────────────────────────────────────

  /// 读缓存全量上屏（无缓存则跳过）。
  Future<void> _hydrateFromCache(String platform) async {
    final key = _userKey(platform);
    if (key == null) return;
    final store = LikedCacheStore.shared;
    final cachedTotal = await store.total(platform, key);
    if (cachedTotal == null || cachedTotal == 0) return;
    final cached = await store.loadAll(platform, key);
    if (cached.isEmpty) return;
    final s = _state(platform);
    s.tracks = cached;
    s.total = cachedTotal;
    s.loaded = true;
    notifyListeners();
  }

  /// 全量拉取当前平台收藏（酷狗 likedTracks / 网易云 likedSongs，
  /// 均为循环翻页拉满）。
  Future<List<Track>> _fetchAll(String platform) async {
    if (platform == 'kugou') {
      return _ref.read(kugouApiProvider).likedTracks();
    }
    final account = _ref.read(neteaseAuthProvider);
    if (account == null) return const <Track>[];
    return _ref.read(neteaseApiProvider).likedSongs(account.userId);
  }
}
