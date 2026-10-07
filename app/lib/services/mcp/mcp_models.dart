// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// MCP 控制服务的数据模型与序列化辅助（与传输层解耦）。
///
/// 本文件不依赖 `dart:io`，可在测试中直接构造；MCP / REST / WebSocket
/// 三个入口共用同一套能力分组、配置与 JSON 视图。
library;

import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart' show immutable, setEquals;

import '../netease/track.dart';
import '../playback/playback_state.dart';

/// 能力组：控制面暴露的每组工具独立开关（默认全关）。
///
/// - [read]：读取播放状态 / 当前曲目 / 队列 / 服务信息；
/// - [playback]：播放 / 暂停 / 切歌 / 跳转 / 音量 / 播放模式 / 音质 / 睡眠定时；
/// - [queue]：队列增删改查；
/// - [search]：在线音源搜索；
/// - [library]：本地曲库查询；
/// - [preferences]：应用偏好只读；
/// - [appearance]：主题模式切换；
/// - [collection]：收藏（红心）状态查询/切换 + 收藏列表；
/// - [history]：播放历史查询与清空；
/// - [lyrics]：当前曲目歌词只读；
/// - [download]：下载任务查询 / 入队 / 取消。
enum McpCapability {
  read('read'),
  playback('playback'),
  queue('queue'),
  search('search'),
  library('library'),
  preferences('preferences'),
  appearance('appearance'),
  collection('collection'),
  history('history'),
  lyrics('lyrics'),
  download('download');

  const McpCapability(this.id);

  /// 稳定 id（写入偏好键与 JSON，不随枚举名变化）。
  final String id;

  /// 由 id 解析（未知返回 null）。
  static McpCapability? fromId(String id) {
    for (final c in values) {
      if (c.id == id) return c;
    }
    return null;
  }
}

/// 服务运行配置（由偏好派生；值相等即无需重启监听）。
@immutable
class McpConfig {
  const McpConfig({
    required this.enabled,
    required this.port,
    required this.accessKey,
    required this.allowKeyless,
    required this.allowLan,
    required this.capabilities,
  });

  /// 关闭态（不监听端口，不暴露任何能力）。
  static const McpConfig disabled = McpConfig(
    enabled: false,
    port: 0,
    accessKey: '',
    allowKeyless: false,
    allowLan: false,
    capabilities: <McpCapability>{},
  );

  final bool enabled;
  final int port;
  final String accessKey;
  final bool allowKeyless;

  /// 是否允许局域网访问（绑定 `0.0.0.0` 而非回环）。
  final bool allowLan;

  final Set<McpCapability> capabilities;

  bool has(McpCapability capability) => capabilities.contains(capability);

  McpConfig copyWith({
    bool? enabled,
    int? port,
    String? accessKey,
    bool? allowKeyless,
    bool? allowLan,
    Set<McpCapability>? capabilities,
  }) => McpConfig(
    enabled: enabled ?? this.enabled,
    port: port ?? this.port,
    accessKey: accessKey ?? this.accessKey,
    allowKeyless: allowKeyless ?? this.allowKeyless,
    allowLan: allowLan ?? this.allowLan,
    capabilities: capabilities ?? this.capabilities,
  );

  @override
  bool operator ==(Object other) =>
      other is McpConfig &&
      other.enabled == enabled &&
      other.port == port &&
      other.accessKey == accessKey &&
      other.allowKeyless == allowKeyless &&
      other.allowLan == allowLan &&
      setEquals(other.capabilities, capabilities);

  @override
  int get hashCode => Object.hash(
    enabled,
    port,
    accessKey,
    allowKeyless,
    allowLan,
    Object.hashAllUnordered(capabilities),
  );
}

/// 控制动作失败（参数非法 / 目标不存在 / 能力未启用等）。
///
/// [code] 为稳定的机器可读错误码（如 `invalid_argument` / `not_found` /
/// `unsupported`），供 REST 与 MCP 统一映射。
class McpActionException implements Exception {
  const McpActionException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'McpActionException($code): $message';
}

/// 有界的「搜索/查询结果 → 曲目」缓存。
///
/// MCP 先拿到 `ref`（`source:id`），随后的播放 / 入队只回传该 ref，避免重复
/// 传递整份曲目对象；缓存按插入顺序淘汰，绝不无界增长。
class McpTrackCache {
  McpTrackCache({this.maxEntries = 500});

  final int maxEntries;
  final LinkedHashMap<String, Track> _entries = LinkedHashMap<String, Track>();

  /// 稳定引用（`source:id`）。
  static String refOf(Track track) => '${track.source}:${track.id}';

  void put(Track track) {
    final key = refOf(track);
    if (key.endsWith(':')) return; // 无 id 不入缓存
    _entries.remove(key);
    _entries[key] = track;
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  void putAll(Iterable<Track> tracks) => tracks.forEach(put);

  /// 命中即刷新为最近使用（LRU 语义）。
  Track? get(String ref) {
    final track = _entries.remove(ref);
    if (track == null) return null;
    _entries[ref] = track;
    return track;
  }
}

/// 曲目摘要视图（列表/当前曲目统一形状；`ref` 用于后续动作引用）。
Map<String, Object?> trackToJson(Track track) => {
  'ref': McpTrackCache.refOf(track),
  'id': track.id,
  'source': track.source,
  'title': track.title,
  'artists': track.artists.map((a) => a.name).toList(),
  'album': track.album?.name,
  'durationMs': track.duration,
  'cover': track.cover,
  'fee': track.fee,
  'isOriginal': track.isOriginal,
  if (track.localPath != null) 'localPath': track.localPath,
  if (track.serverId != null) 'serverId': track.serverId,
  if (track.originalId != null) 'originalId': track.originalId,
};

/// 播放状态视图。
Map<String, Object?> playbackStateToJson(PlaybackState state) => {
  'playing': state.playing,
  'buffering': state.buffering,
  'positionMs': state.position.inMilliseconds,
  'durationMs': state.duration.inMilliseconds,
  'volume': state.volume,
  'quality': state.quality,
  'repeatMode': state.repeatMode,
  'shuffle': state.shuffle,
  'source': state.source,
  'track': state.track == null ? null : trackToJson(state.track!),
  'title': state.title,
  'subtitle': state.subtitle,
  'queueIndex': state.queueIndex,
  'queueLength': state.queue.length,
};

/// 恒定时间字符串比较（密钥校验，避免计时侧信道）。
bool constantTimeEquals(String? a, String? b) {
  if (a == null || b == null) return false;
  final x = utf8.encode(a);
  final y = utf8.encode(b);
  var diff = x.length ^ y.length;
  final n = x.length > y.length ? x.length : y.length;
  for (var i = 0; i < n; i++) {
    final xb = i < x.length ? x[i] : 0;
    final yb = i < y.length ? y[i] : 0;
    diff |= xb ^ yb;
  }
  return diff == 0;
}
