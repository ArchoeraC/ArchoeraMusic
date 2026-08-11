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

  /// 是否已成功同步过一次（避免重复全量拉取）。
  bool _loaded = false;
  bool get loaded => _loaded;

  /// 当前曲目是否已喜欢（按 source 路由到对应平台集合）。
  ///
  /// 酷狗以歌曲 hash 为红心键（搜索条目 id 退化为 hash、歌单条目可能为
  /// audio_id，两者不一致会导致红心状态判定失败；hash 是稳定的歌曲标识）。
  bool isLiked(Track track) {
    if (track.source == 'kugou') {
      return _kugouIds.contains(track.kugou?.hash ?? track.id);
    }
    return _neteaseIds.contains(track.id);
  }

  /// 平台已喜欢 id 集合（'kugou' → 酷狗；其余 → 网易云；SongList 渲染用）。
  Set<String> idsFor(String source) =>
      source == 'kugou' ? _kugouIds : _neteaseIds;

  /// 同步双平台红心集合（各自失败互不影响）。
  Future<void> sync() async {
    if (_syncing) return;
    _syncing = true;
    try {
      // 网易云：likelist（需登录）
      final account = _ref.read(neteaseAuthProvider);
      if (account != null) {
        try {
          final ids = await _ref.read(neteaseApiProvider).likedIds(account.userId);
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

      // 酷狗：找「我喜欢」歌单拉全量（需登录）
      final kugou = _ref.read(kugouApiProvider);
      if (kugou.session != null) {
        try {
          final tracks = await kugou.likedTracks();
          final ids = tracks.map((t) => t.kugou?.hash ?? t.id).toSet();
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
    } finally {
      _syncing = false;
    }
  }

  /// 切换红心：乐观更新 + 失败回滚（对齐 SPlayer-Next toggleLike）。
  /// 成功返回 true；失败回滚并返回 false（调用方负责提示）。
  Future<bool> toggle(Track track) async {
    final wasLiked = isLiked(track);
    final target = !wasLiked;

    if (track.source == 'kugou') {
      final key = track.kugou?.hash ?? track.id;
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
      return true;
    } catch (_) {
      _neteaseIds
        ..remove(track.id)
        ..addAll(wasLiked ? {track.id} : const {});
      notifyListeners();
      return false;
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
