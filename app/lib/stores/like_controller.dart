// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 红心状态控制器（NT / KG / QM三平台）。
///
/// - 持有各平台已喜欢 id 集合，任意 UI 通过 [isLiked] 查询；
/// - [toggle] 乐观更新 + 失败回滚（失败返回 false 由调用方提示）；
/// - [sync] 按当前登录态刷新集合（登录/退出后调用）。
///
/// QQ 特殊：红心键为 **songmid**；本机红心存于 [QqLikedStore]（app 自己的
/// 「我喜欢」，离线始终可用），在线同步为**实验接口**（kQqFavExperimental）
/// ——登录 QQ 时并入在线「我喜欢」songmid，写失败回滚本地（见 [_toggleQq]）。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/netease/track.dart';
import '../services/qqmusic/qq_liked_store.dart';
import '../services/qqmusic/qqmusic_api.dart' show kQqFavExperimental;
import 'providers.dart';

class LikeController extends ChangeNotifier {
  LikeController(this._ref);

  final Ref _ref;

  final Set<String> _neteaseIds = {};
  final Set<String> _kugouIds = {};

  /// QQ 红心 songmid 集合（本机 + 登录后并入在线；见 [QqLikedStore]）。
  final Set<String> _qqmusicIds = {};

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

  /// QQ 红心键（songmid；缺失回退 Track.id）。
  static String _qqKey(Track t) => qqLikeKey(t);

  /// 当前曲目是否已喜欢（按 source 路由到对应平台集合）。
  ///
  /// KG以歌曲 hash 为红心键（搜索条目 id 退化为 hash、歌单条目可能为
  /// audio_id，两者不一致会导致红心状态判定失败；hash 是稳定的歌曲标识）。
  /// **hash 统一转小写匹配**：歌单接口存大写、mobilecdn 搜索返回小写，
  /// 与 [songLikeKey] / likedHashSet 保持一致（否则已收藏误标非红心）。
  /// QM以 **songmid** 为红心键（彻底摆脱「QQ 曲目误走 netease id」）。
  bool isLiked(Track track) {
    if (track.source == 'kugou') {
      return _kugouIds.contains((track.kugou?.hash ?? track.id).toLowerCase());
    }
    if (track.source == 'qqmusic') {
      return _qqmusicIds.contains(_qqKey(track));
    }
    return _neteaseIds.contains(track.id);
  }

  /// 平台已喜欢 id 集合（'kugou' → KG hash；'qqmusic' → songmid；
  /// 其余 → NT id；SongList 渲染用）。
  Set<String> idsFor(String source) {
    if (source == 'kugou') return _kugouIds;
    if (source == 'qqmusic') return _qqmusicIds;
    return _neteaseIds;
  }

  /// 用服务端权威「我喜欢的」列表对账该平台红心集合（收藏页刷新成功后调用）。
  ///
  /// - 仅 netease / kugou（服务端权威列表）；QQ 以本机 [QqLikedStore] 为
  ///   主源、其「我喜欢」页红心与列表同源，不走本方法。
  /// - **双向**：权威列表含 → 点亮；不含 → 熄灭（跨设备移除后刷新即熄灭）。
  /// - **缓冲期**（[reconcileGrace]）内本端刚 toggle 的键以本地为准：
  ///   服务端写入尚未生效时不因旧快照误覆盖（刚点亮不清除 / 刚熄灭不复活）。
  ///
  /// 仅当调用方确在展示该平台「我喜欢的」权威列表时才能调用——绝不能把普通
  /// 歌单当收藏集合传进来（会把红心集合整体清空）。对账后 notify UI 重绘。
  void reconcileFromAuthoritative(String platform, List<Track> tracks) {
    if (platform != 'netease' && platform != 'kugou') return;
    final serverKeys = <String>{};
    for (final t in tracks) {
      if (t.source != platform) continue;
      if (platform == 'kugou') {
        final h = (t.kugou?.hash ?? t.id).toLowerCase();
        if (h.isNotEmpty) serverKeys.add(h);
      } else if (t.id.isNotEmpty) {
        serverKeys.add(t.id);
      }
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
    final cur = idsFor(platform);
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

  /// 同步三平台红心集合（各自失败互不影响）。
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
    // NT：likelist（需登录）
    final account = _ref.read(neteaseAuthProvider);
    if (account != null) {
      try {
        final ids = await _ref
            .read(neteaseApiProvider)
            .likedIds(account.userId);
        _alignToServer('netease', ids.toSet());
      } catch (_) {
        // 网络失败保留旧集合
      }
    } else {
      _neteaseIds.clear();
    }

    // KG：轻量红心 hash 集合（likedHashSet 只分页取 hash，不构造
    // Track / 不写库 / 不触碰收藏页全量列表），红心状态与列表解耦——
    // 启动同步不做全量拉取，避免被进程退出/写失败影响（sync 语义）
    final kugou = _ref.read(kugouApiProvider);
    if (kugou.session != null) {
      try {
        final ids = await kugou.likedHashSet();
        _alignToServer('kugou', ids);
      } catch (_) {
        // 网络失败保留旧集合
      }
    } else {
      _kugouIds.clear();
    }

    // QQ：本机红心（QqLikedStore.songmid）恒为主源，无论登录与否都保留；
    // 已登录且实验开关开启时并入在线「我喜欢」songmid（add-only）。
    // 在线拉取失败保留本机集合——「本地红心始终可用，不受在线成败影响」。
    try {
      final qqStore = _ref.read(qqLikedStoreProvider);
      await qqStore.ensureLoaded();
      final local = qqStore.midSet;
      final qqApi = _ref.read(qqMusicApiProvider);
      if (kQqFavExperimental && qqApi.isLoggedIn) {
        try {
          final online = await qqApi.likedSongmids();
          _applyQqLiked(local, online);
        } catch (_) {
          _replaceQqLiked(local);
        }
      } else {
        _replaceQqLiked(local);
      }
    } catch (_) {
      // 本机库加载失败：保留内存态（下次 sync 重试）
    }

    _loaded = true;
    notifyListeners();
  }

  /// 以本机集合为底、并入在线 songmid（add-only）重建 QQ 红心集合；
  /// 缓冲期内本端刚熄灭的键不因在线写未生效而回光。
  void _applyQqLiked(Set<String> local, Iterable<String> online) {
    final prev = Set<String>.from(_qqmusicIds);
    _qqmusicIds
      ..clear()
      ..addAll(local);
    for (final mid in online) {
      if (mid.isEmpty || _qqmusicIds.contains(mid)) continue;
      if (_dirtyOf('qqmusic', mid) && !prev.contains(mid)) continue;
      _qqmusicIds.add(mid);
    }
  }

  void _replaceQqLiked(Set<String> local) {
    _qqmusicIds
      ..clear()
      ..addAll(local);
  }

  /// 切换红心：乐观更新 + 失败回滚。
  /// 成功返回 true；失败回滚并返回 false（调用方负责提示）。
  Future<bool> toggle(Track track) async {
    final wasLiked = isLiked(track);
    final target = !wasLiked;

    if (track.source == 'kugou') {
      final key = (track.kugou?.hash ?? track.id).toLowerCase();
      // 缓冲期内服务端写未生效，权威列表刷新不覆盖本端刚做的改动
      _markDirty('kugou', key);
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
        _clearDirty('kugou', key);
        _kugouIds
          ..remove(key)
          ..addAll(wasLiked ? {key} : const {});
        notifyListeners();
        return false;
      }
    }

    if (track.source == 'qqmusic') {
      return _toggleQq(track);
    }

    // NT
    _markDirty('netease', track.id);
    _neteaseIds
      ..remove(track.id)
      ..addAll(target ? {track.id} : const {});
    notifyListeners();
    try {
      await _ref.read(neteaseApiProvider).like(track.id, like: target);
      _applyStoreDelta(track, target);
      return true;
    } catch (_) {
      _clearDirty('netease', track.id);
      _neteaseIds
        ..remove(track.id)
        ..addAll(wasLiked ? {track.id} : const {});
      notifyListeners();
      return false;
    }
  }

  /// QQ 红心切换。
  ///
  /// - 乐观更新 songmid 集合；
  /// - **已登录 + 实验开关**：调在线写接口（favorite_add/remove）——
  ///   成功才落本机库；失败抛错并**回滚本机**（红心填充态/列表均还原，
  ///   返回 false 由调用方提示）；
  /// - **未登录（或实验关闭）**：仅维护本机红心（QqLikedStore 落盘），
  ///   始终成功——「本地红心始终可用」。
  Future<bool> _toggleQq(Track track) async {
    final wasLiked = isLiked(track);
    final target = !wasLiked;
    final key = _qqKey(track);
    if (key.isEmpty) return false;

    _markDirty('qqmusic', key);
    _qqmusicIds
      ..remove(key)
      ..addAll(target ? {key} : const {});
    notifyListeners();

    try {
      final store = _ref.read(qqLikedStoreProvider);
      final qqApi = _ref.read(qqMusicApiProvider);
      final online = kQqFavExperimental && qqApi.isLoggedIn;
      if (online) {
        // 在线写接口失败 → 抛错走下方回滚（不落本机库）
        await qqApi.like(key, like: target, songId: track.id);
      }
      if (target) {
        await store.add(track);
      } else {
        await store.removeByKey(key);
      }
      return true;
    } catch (_) {
      // 回滚（在线接口失败 / 本机库异常）
      _clearDirty('qqmusic', key);
      _qqmusicIds
        ..remove(key)
        ..addAll(wasLiked ? {key} : const {});
      notifyListeners();
      return false;
    }
  }

  /// 服务端确认成功后，同步维护收藏列表增量（新喜欢插入头部 /
  /// 取消喜欢移除）并写库——与「刷新=全量重拉+写库」同一持久化语义，
  /// 列表任何变化都落库（local 歌曲不参与平台收藏列表）。
  /// QQ 走 [QqLikedStore]（_toggleQq 内部维护），不经过本方法。
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
