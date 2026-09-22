// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 红心状态控制器（各平台统一走 `CollectionPlatform` 适配器）。
///
/// - 持有各平台已喜欢 id 集合，任意 UI 通过 [isLiked] 查询；
/// - [toggle] 乐观更新 + 失败回滚（失败返回 false 由调用方提示）；
/// - [sync] 按当前登录态刷新集合（登录/退出后调用）。
///
/// 平台差异（红心键归一、id 集合拉取、收藏/取消、QQ 本机库、Neko 实验开关等）
/// 全部由 `widgets/dialogs/collection_platform.dart` 的适配器提供；**新增音源
/// 只需注册适配器**，本文件无需改动。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/netease/track.dart';
import '../services/qqmusic/qq_liked_store.dart';
import '../widgets/dialogs/collection_platform.dart';
import 'providers.dart';

class LikeController extends ChangeNotifier {
  LikeController(this._ref);

  final Ref _ref;

  final Set<String> _neteaseIds = {};
  final Set<String> _kugouIds = {};

  /// QQ 红心 songmid 集合（本机 + 登录后并入在线；见 [QqLikedStore]）。
  final Set<String> _qqmusicIds = {};

  /// Neko 红心 id 集合（实验性音源；在线权威，未登录/未启用为空）。
  final Set<String> _nekoIds = {};

  bool _syncing = false;

  /// 同步进行中又收到新事件（登录/登出）时置位：当前一轮完成后立即
  /// 用最新登录态再跑一轮——否则登录动作触发的 sync 会被 `_syncing`
  /// 直接丢弃，导致「登录后红心集合不更新」（红心失效，重启才恢复）。
  bool _pending = false;

  /// 是否已成功同步过一次（避免重复全量拉取）。
  bool _loaded = false;
  bool get loaded => _loaded;

  /// 本端「刚 toggle 过」的键（`平台\u0000键` → 时间）。
  ///
  /// 服务端写入不是瞬时的：乐观点亮/熄灭后，若此时权威列表刷新 / 同步返回
  /// 的仍是旧快照，会误把刚点亮的熄灭、刚熄灭的回光。缓冲期内这些键一律
  /// **以本地状态为准**，过期后自动让位给服务端权威（[reconcileGrace]）。
  final Map<String, DateTime> _dirtyKeys = {};

  /// 对账/同步缓冲期：期间本端本地改动优先，避免与「服务端写尚未生效」
  /// 的旧快照竞争。
  static const Duration reconcileGrace = Duration(seconds: 20);

  bool _dirtyOf(String platform, String key) {
    if (key.isEmpty) return false;
    final full = '$platform\u0000$key';
    final at = _dirtyKeys[full];
    if (at == null) return false;
    if (DateTime.now().difference(at) <= reconcileGrace) return true;
    _dirtyKeys.remove(full);
    return false;
  }

  void _markDirty(String platform, String key) {
    if (key.isEmpty) return;
    _pruneDirty();
    _dirtyKeys['$platform\u0000$key'] = DateTime.now();
  }

  void _clearDirty(String platform, String key) {
    if (key.isEmpty) return;
    _dirtyKeys.remove('$platform\u0000$key');
  }

  void _pruneDirty() {
    final now = DateTime.now();
    _dirtyKeys.removeWhere((_, at) => now.difference(at) > reconcileGrace);
  }

  /// 平台集合（新增音源时这里与 [_syncOnce] 的遍历列表同步即可）。
  Set<String> _setFor(String source) {
    switch (source) {
      case 'kugou':
        return _kugouIds;
      case 'qqmusic':
        return _qqmusicIds;
      case 'neko':
        return _nekoIds;
      default:
        return _neteaseIds;
    }
  }

  /// 当前曲目是否已喜欢（按 source 路由到对应平台集合与红心键）。
  bool isLiked(Track track) {
    final key = collectionPlatform(track.source).likeKey(track);
    return key.isNotEmpty && _setFor(track.source).contains(key);
  }

  /// 平台已喜欢 id 集合（SongList 渲染用）。
  Set<String> idsFor(String source) => _setFor(source);

  /// 用服务端权威「我喜欢的」列表对账该平台红心集合（收藏页刷新成功后调用）。
  ///
  /// 仅 [CollectionPlatform.reconcileLiked] 的平台参与（QQ 本机列表不走对账）。
  /// **双向**：权威列表含 → 点亮；不含 → 熄灭；缓冲期内本端刚 toggle 的键
  /// 以本地为准。对账后 notify UI 重绘。
  void reconcileFromAuthoritative(String platform, List<Track> tracks) {
    final adapter = collectionPlatform(platform);
    if (!adapter.reconcileLiked) return;
    final serverKeys = <String>{};
    for (final t in tracks) {
      if (t.source != platform) continue;
      final k = adapter.likeKey(t);
      if (k.isNotEmpty) serverKeys.add(k);
    }
    if (_alignToServer(platform, serverKeys)) notifyListeners();
  }

  /// 手动「同步在线收藏」/ 登录并入后刷新 QQ 红心（**add-only**，对应
  /// [QqLikedStore.mergeOnline] 已并入本机列表的曲目）——使刷新后列表新增
  /// 行的红心即时点亮；缓冲期内本端刚熄灭的键不因在线写未生效而回光。
  void mergeOnlineQq(Iterable<Track> online) {
    final prev = Set<String>.from(_qqmusicIds);
    var changed = false;
    for (final t in online) {
      final mid = qqLikeKey(t);
      if (mid.isEmpty || _qqmusicIds.contains(mid)) continue;
      if (_dirtyOf('qqmusic', mid) && !prev.contains(mid)) continue;
      _qqmusicIds.add(mid);
      changed = true;
    }
    if (changed) notifyListeners();
  }

  /// 以服务端权威键集对齐平台集合（双向）。缓冲期内本端刚 toggle 的键以
  /// 本地状态为准（保留刚点亮 / 不复活刚熄灭）；返回集合是否变化。
  bool _alignToServer(String platform, Set<String> serverKeys) {
    final cur = _setFor(platform);
    _pruneDirty();
    final next = <String>{};
    // 缓冲期内本端刚点亮的键：旧快照未含也保留
    for (final key in cur) {
      if (_dirtyOf(platform, key)) next.add(key);
    }
    for (final key in serverKeys) {
      if (key.isEmpty) continue;
      // 缓冲期内本端刚熄灭的键：服务端滞后仍含也不复活
      if (_dirtyOf(platform, key) && !cur.contains(key)) continue;
      next.add(key);
    }
    if (_sameSet(cur, next)) return false;
    cur
      ..clear()
      ..addAll(next);
    return true;
  }

  /// 同步各平台红心集合（各自失败互不影响）。
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
    // 遍历所有已注册平台（顺序与注册表一致）。未启用（Neko 开关）或不可用
    // （未登录）的平台清空集合；其余拉轻量 id 集合对齐（网络失败保留旧集合）。
    for (final source in const ['netease', 'kugou', 'qqmusic', 'neko']) {
      final adapter = collectionPlatform(source);
      if (!adapter.enabled(_ref) || !adapter.likedAvailable(_ref)) {
        _setFor(source).clear();
        continue;
      }
      try {
        final ids = await adapter.fetchLikedIds(_ref);
        _alignToServer(source, ids);
      } catch (_) {
        // 网络失败保留旧集合
      }
    }
    _loaded = true;
    notifyListeners();
  }

  /// 切换红心：乐观更新 + 失败回滚。
  /// 成功返回 true；失败回滚并返回 false（调用方负责提示）。
  Future<bool> toggle(Track track) async {
    final adapter = collectionPlatform(track.source);
    final key = adapter.likeKey(track);
    if (key.isEmpty) return false;
    final source = track.source;
    final set = _setFor(source);
    final wasLiked = set.contains(key);
    final target = !wasLiked;

    // 缓冲期内服务端写未生效，权威列表刷新不覆盖本端刚做的改动
    _markDirty(source, key);
    set
      ..remove(key)
      ..addAll(target ? {key} : const {});
    notifyListeners();
    try {
      await adapter.setLiked(_ref, track, target);
      _applyStoreDelta(track, target);
      return true;
    } catch (_) {
      _clearDirty(source, key);
      set
        ..remove(key)
        ..addAll(wasLiked ? {key} : const {});
      notifyListeners();
      return false;
    }
  }

  /// 服务端确认成功后，同步维护收藏列表增量（新喜欢插入头部 /
  /// 取消喜欢移除）并写库——与「刷新=全量重拉+写库」同一持久化语义。
  /// QQ 走 [QqLikedStore]、NK 不做本地增量（与既有行为一致）。
  void _applyStoreDelta(Track track, bool target) {
    if (track.source != 'kugou' && track.source != 'netease') return;
    final store = _ref.read(likedStoreProvider);
    if (target) {
      store.addTrack(track.source, track);
    } else {
      store.removeTrack(track.source, track.source, track.id);
    }
  }

  /// 退出登录清理（登出回调中调用；QQ 本机红心不清空，见 [QqLikedStore]）。
  void reset() {
    _neteaseIds.clear();
    _kugouIds.clear();
    _nekoIds.clear();
    // 登出后旧账号的缓冲标记不再适用（对账由重登后新一轮 sync 重算）
    _dirtyKeys.clear();
    // 注：QQ 红心以本机库为主源，登出 QQ 不清空 _qqmusicIds（sync 会按
    // 登录态重算——未登录时仍保留本机 songmid）。
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
