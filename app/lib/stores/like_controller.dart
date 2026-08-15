/// 红心状态控制器（网易云 / 酷狗「我喜欢」双平台统一）。
///
/// 对齐 SPlayer-Next `user.ts` 的 likedSongIds + toggleLike 语义：
/// - 持有各平台已喜欢 id 集合，任意 UI 通过 [isLiked] 查询；
/// - [toggle] 乐观更新 + 失败回滚（失败返回 false 由调用方提示）；
/// - [sync] 按当前登录态刷新两个集合（登录/退出后调用）。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/netease/track.dart';
import 'providers.dart';

class LikeController extends ChangeNotifier {
  LikeController(this._ref);

  final Ref _ref;

  final Set<String> _neteaseIds = {};
  final Set<String> _kugouIds = {};

  bool _syncing = false;

  /// 同步进行中又收到新事件（登录/登出）时置位：当前一轮完成后立即
  /// 用最新登录态再跑一轮——否则登录动作触发的 sync 会被 `_syncing`
  /// 直接丢弃，导致「登录后红心集合不更新」（红心失效，重启才恢复）。
  bool _pending = false;

  /// 是否已成功同步过一次（避免重复全量拉取）。
  bool _loaded = false;
  bool get loaded => _loaded;

  /// 当前曲目是否已喜欢（按 source 路由到对应平台集合）。
  ///
  /// 酷狗以歌曲 hash 为红心键（搜索条目 id 退化为 hash、歌单条目可能为
  /// audio_id，两者不一致会导致红心状态判定失败；hash 是稳定的歌曲标识）。
  /// **hash 统一转小写匹配**：歌单接口存大写、mobilecdn 搜索返回小写，
  /// 与 [songLikeKey] / likedHashSet 保持一致（否则已收藏误标非红心）。
  bool isLiked(Track track) {
    if (track.source == 'kugou') {
      return _kugouIds.contains(
        (track.kugou?.hash ?? track.id).toLowerCase(),
      );
    }
    return _neteaseIds.contains(track.id);
  }

  /// 平台已喜欢 id 集合（'kugou' → 酷狗；其余 → 网易云；SongList 渲染用）。
  Set<String> idsFor(String source) =>
      source == 'kugou' ? _kugouIds : _neteaseIds;

  /// 同步双平台红心集合（各自失败互不影响）。
  ///
  /// 支持「合并重跑」：同步中收到的登录事件（见 [_pending]）不会丢失，
  /// 当前一轮结束后用最新登录态再跑，避免登录动作被 _syncing 吞掉。
  Future<void> sync() async {
    if (_syncing) {
      _pending = true;
      return;
    }
    _syncing = true;
    try {
      do {
        _pending = false;
        await _syncOnce();
      } while (_pending);
    } finally {
      _syncing = false;
    }
  }

  Future<void> _syncOnce() async {
    // 网易云：likelist（需登录）
    final account = _ref.read(neteaseAuthProvider);
    if (account != null) {
      try {
        final ids = await _ref
            .read(neteaseApiProvider)
            .likedIds(account.userId);
        if (!_sameSet(_neteaseIds, ids.toSet())) {
          _neteaseIds
            ..clear()
            ..addAll(ids);
        }
      } catch (_) {
        // 网络失败保留旧集合
      }
    } else {
      _neteaseIds.clear();
    }

    // 酷狗：轻量红心 hash 集合（likedHashSet 只分页取 hash，不构造
    // Track / 不写库 / 不触碰收藏页全量列表），红心状态与列表解耦——
    // 启动同步不做全量拉取，避免被进程退出/写失败影响（sync 语义）
    final kugou = _ref.read(kugouApiProvider);
    if (kugou.session != null) {
      try {
        final ids = await kugou.likedHashSet();
        if (!_sameSet(_kugouIds, ids)) {
          _kugouIds
            ..clear()
            ..addAll(ids);
        }
      } catch (_) {
        // 网络失败保留旧集合
      }
    } else {
      _kugouIds.clear();
    }

    _loaded = true;
    notifyListeners();
  }

  /// 切换红心：乐观更新 + 失败回滚（对齐 SPlayer-Next toggleLike）。
  /// 成功返回 true；失败回滚并返回 false（调用方负责提示）。
  Future<bool> toggle(Track track) async {
    final wasLiked = isLiked(track);
    final target = !wasLiked;

    if (track.source == 'kugou') {
      final key = (track.kugou?.hash ?? track.id).toLowerCase();
      _kugouIds
        ..remove(key)
        ..addAll(target ? {key} : const {});
      notifyListeners();
      try {
        final api = _ref.read(kugouApiProvider);
        if (target) {
          await api.addToLike(track);
        } else {
          await api.removeFromLike(track);
        }
        _applyStoreDelta(track, target);
        return true;
      } catch (_) {
        // 回滚
        _kugouIds
          ..remove(key)
          ..addAll(wasLiked ? {key} : const {});
        notifyListeners();
        return false;
      }
    }

    // 网易云
    _neteaseIds
      ..remove(track.id)
      ..addAll(target ? {track.id} : const {});
    notifyListeners();
    try {
      await _ref.read(neteaseApiProvider).like(track.id, like: target);
      _applyStoreDelta(track, target);
      return true;
    } catch (_) {
      _neteaseIds
        ..remove(track.id)
        ..addAll(wasLiked ? {track.id} : const {});
      notifyListeners();
      return false;
    }
  }

  /// 服务端确认成功后，同步维护收藏列表增量（新喜欢插入头部 /
  /// 取消喜欢移除）并写库——与「刷新=全量重拉+写库」同一持久化语义，
  /// 列表任何变化都落库（local 歌曲不参与平台收藏列表）。
  void _applyStoreDelta(Track track, bool target) {
    if (track.source != 'kugou' && track.source != 'netease') return;
    final store = _ref.read(likedStoreProvider);
    if (target) {
      store.addTrack(track.source, track);
    } else {
      store.removeTrack(track.source, track.source, track.id);
    }
  }

  /// 退出登录清理（登出回调中调用）。
  void reset() {
    _neteaseIds.clear();
    _kugouIds.clear();
    _loaded = false;
    notifyListeners();
  }

  static bool _sameSet(Set<String> a, Set<String> b) {
    if (a.length != b.length) return false;
    for (final id in a) {
      if (!b.contains(id)) return false;
    }
    return true;
  }
}
