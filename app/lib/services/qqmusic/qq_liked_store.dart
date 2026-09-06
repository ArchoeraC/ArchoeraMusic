// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// QM红心收藏（「我喜欢」）**本机持久化数据源**。
///
/// QQ 平台与NT/KG不同：在线收藏接口为**社区逆向实验 RPC**
/// （见 apis/qqmusic/modules/favorite.dart 调研），不可作为收藏唯一真源。
/// 因此 QQ 红心以**本机列表为主**——任意 QQ 曲目可离线点亮红心并持久化，
/// 不受在线成败影响；登录 QQ 后再把在线「我喜欢」（dirid=201）**并入**
/// 本地（add-only，绝不用在线列表覆盖/清空本地）。
///
/// - 持久化：`<dataDir>/qq_liked.json`（Track 全量 JSON，最新收藏在前）；
/// - [LikeController] 的红心 songmid 集合由此派生（红心状态与「我喜欢」
///   页列表同源，页内切歌/移除后状态实时一致）；
/// - 「我喜欢」页 QQ 平台直接以本 store 为数据源（不走 LikedStore 的
///   服务器缓存语义）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../netease/track.dart';
import '../../stores/data_dir.dart';

/// QQ 红心键：songmid 优先，缺失回退 Track.id（对齐 song_row.songLikeKey /
/// LikeController 的 qqmusic 路由键）。
String qqLikeKey(Track t) {
  final mid = t.qqmusic?.mid;
  return (mid != null && mid.isNotEmpty) ? mid : t.id;
}

/// 本机 QQ「我喜欢」列表（ChangeNotifier：页面直接订阅）。
class QqLikedStore extends ChangeNotifier {
  /// [dir] 数据目录覆写（仅测试注入；null 时用 [resolveDataDir]）。
  QqLikedStore({String? dir}) : _dirOverride = dir {
    _loadFut = _load();
  }

  final String? _dirOverride;

  /// 缓存/文件内平台 user key（本机列表与账号无关，登录与否都保留）。
  static const String userKey = 'local';

  List<Track> _tracks = const [];
  bool _loading = false;
  bool _loaded = false;
  String _error = '';

  /// 一次加载（幂等；LikeController/LikedPage 均先 ensureLoaded）。
  Future<void>? _loadFut;
  Future<void> ensureLoaded() => _loadFut ??= _load();

  bool get loaded => _loaded;
  bool get loading => _loading;
  String get error => _error;

  /// 本机 QQ「我喜欢」曲目（最新收藏在前，只读视图）。
  List<Track> get tracks => _tracks;

  /// 本机 QQ 红心 songmid 集合（红心填充态判定用）。
  Set<String> get midSet =>
      {for (final t in _tracks) if (qqLikeKey(t).isNotEmpty) qqLikeKey(t)};

  bool containsMid(String mid) =>
      mid.isNotEmpty && _tracks.any((t) => qqLikeKey(t) == mid);

  String get _filePath =>
      '${_dirOverride ?? resolveDataDir()}/qq_liked.json';

  Future<void> _load() async {
    _loading = true;
    notifyListeners();
    try {
      final file = File(_filePath);
      if (!await file.exists()) {
        _tracks = const [];
        return;
      }
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw);
      final list = decoded is Map ? decoded['tracks'] : decoded;
      final tracks = <Track>[];
      if (list is List) {
        final seen = <String>{};
        for (final item in list.whereType<Map>()) {
          try {
            final t = Track.fromJson(Map<String, dynamic>.from(item));
            final key = qqLikeKey(t);
            if (key.isEmpty || !seen.add(key)) continue;
            tracks.add(t);
          } catch (_) {
            // 单条损坏跳过（不阻断整库）
          }
        }
        _tracks = tracks;
      }
    } catch (e) {
      _error = '$e';
      // 读失败保留空列表（下次写入会重建），本地红心从零开始但不崩
      _tracks = const [];
    } finally {
      _loading = false;
      _loaded = true;
      notifyListeners();
    }
  }

  // ── 写路径（内存即改 + 落盘队列，串行防并发写坏文件） ──────────────

  Future<void> _writeChain = Future.value();

  /// 等待挂起的写盘完成（测试 / 主动落盘时用；正常路径为后台队列）。
  Future<void> flush() => _writeChain;

  void _scheduleWrite() {
    final snapshot = List<Track>.from(_tracks);
    _writeChain = _writeChain.then((_) async {
      try {
        final dir = File(_filePath).parent;
        if (!await dir.exists()) await dir.create(recursive: true);
        await File(_filePath).writeAsString(
          jsonEncode({
            'version': 1,
            'updatedAt': DateTime.now().millisecondsSinceEpoch,
            'tracks': snapshot.map((t) => t.toJson()).toList(),
          }),
        );
      } catch (e) {
        debugPrint('[qq_liked] 写盘失败（不影响内存红心）: $e');
      }
    });
  }

  /// 点亮红心（幂等：同 mid 已存在则忽略）。插入列表头部（最新在前）。
  Future<void> add(Track t) async {
    await _loadFut;
    final key = qqLikeKey(t);
    if (key.isEmpty) return;
    if (containsMid(key)) return;
    _tracks = [t, ..._tracks];
    _loaded = true;
    notifyListeners();
    _scheduleWrite();
  }

  /// 取消红心（按红心键移除；同时兼容按数字 id 移除兜底）。
  Future<void> removeByKey(String key) async {
    await _loadFut;
    if (key.isEmpty) return;
    final before = _tracks.length;
    _tracks = _tracks
        .where((t) => qqLikeKey(t) != key && t.id != key)
        .toList();
    if (_tracks.length == before) return;
    notifyListeners();
    _scheduleWrite();
  }

  /// 并入在线「我喜欢」（实验接口）：仅把本地缺失的在线曲目追加进本地
  /// 列表（add-only，**绝不清空/覆盖本地**），并统一落盘一次。
  Future<int> mergeOnline(List<Track> online) async {
    await _loadFut;
    if (online.isEmpty) return 0;
    final added = <Track>[];
    final seen = {...midSet};
    for (final t in online) {
      final key = qqLikeKey(t);
      if (key.isEmpty || !seen.add(key)) continue;
      added.add(t);
    }
    if (added.isEmpty) return 0;
    _tracks = [...added, ..._tracks];
    _loaded = true;
    notifyListeners();
    _scheduleWrite();
    return added.length;
  }
}
