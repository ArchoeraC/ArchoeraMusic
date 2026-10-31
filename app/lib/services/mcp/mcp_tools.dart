// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// MCP 控制的动作层：把播放器 / 队列 / 搜索 / 曲库 / 偏好收敛为一组与传输
/// 无关的方法，并用 [buildMcpTools] 暴露统一的「工具目录」。
///
/// MCP 的 `tools/list` / `tools/call`、REST 的 `/api/tools/*`、WebSocket 的
/// JSON-RPC 请求都共用本目录：一处定义、三处可用，避免协议实现各自漂移。
library;

import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart' show ThemeMode;

import '../../app/theme_provider.dart';
import '../../l10n/l10n.dart';
import '../../stores/app_prefs.dart';
import '../../stores/lyrics_provider.dart';
import '../../stores/providers.dart';
import '../../utils/app_version.dart';
import '../downloader/download_controller.dart';
import '../netease/track.dart';
import '../playback/playback_notifier.dart';
import '../playback/playback_state.dart';
import '../playback/sleep_timer.dart';
import '../scanner/local_track.dart';
import '../scanner/tracks_db.dart';
import '../source/source_platform.dart';
import 'mcp_models.dart';

/// 一个可被 MCP 调用的工具（MCP tool / REST 动作 / WS 方法）。
class McpTool {
  const McpTool({
    required this.name,
    required this.title,
    required this.description,
    required this.capability,
    required this.inputSchema,
    required this.handle,
    this.readOnly = false,
    this.idempotent = true,
    this.openWorld = false,
  });

  /// 稳定方法名（`snake_case`，同时作为 MCP 工具名与 WS 方法名）。
  final String name;

  /// 人类可读标题（MCP `title`）。
  final String title;

  final String description;

  /// 所属能力组（决定是否暴露）。
  final McpCapability capability;

  /// JSON Schema（`type: object`）。
  final Map<String, Object?> inputSchema;

  /// 调用实现；返回 JSON 可序列化结果。
  final Future<Object?> Function(Map<String, dynamic> args) handle;

  final bool readOnly;
  final bool idempotent;

  /// 是否访问外部世界（在线搜索为 true）。
  final bool openWorld;

  /// MCP 工具注解（标准 `ToolAnnotations`）。
  Map<String, Object?> get annotations => {
    'title': title,
    'readOnlyHint': readOnly,
    'destructiveHint': false,
    'idempotentHint': idempotent,
    'openWorldHint': openWorld,
  };
}

/// 动作层：持有一个 Riverpod [Ref]（应用根作用域），并复用有界曲目缓存。
class McpActions {
  McpActions(this._ref, this._tracks);

  final Ref _ref;
  final McpTrackCache _tracks;

  PlaybackState get _state => _ref.read(playbackProvider);
  PlaybackNotifier get _player => _ref.read(playbackProvider.notifier);
  AppPrefs get _prefs => _ref.read(appPrefsProvider);

  Map<String, Object?> _ok() => const {'ok': true};

  // ── 只读 ──────────────────────────────────────────────────────

  Map<String, Object?> status() => playbackStateToJson(_state);

  Map<String, Object?> nowPlaying() {
    final s = _state;
    return {
      'playing': s.playing,
      'buffering': s.buffering,
      'positionMs': s.position.inMilliseconds,
      'durationMs': s.duration.inMilliseconds,
      'track': s.track == null ? null : trackToJson(s.track!),
      'title': s.title,
      'subtitle': s.subtitle,
    };
  }

  Map<String, Object?> appInfo() => {
    'name': 'ArchoeraMusic',
    'version': appVersion,
    'platform': Platform.operatingSystem,
  };

  Map<String, Object?> queueStatus() {
    final s = _state;
    return {
      'index': s.queueIndex,
      'repeatMode': s.repeatMode,
      'shuffle': s.shuffle,
      'tracks': [
        for (var i = 0; i < s.queue.length; i++)
          {
            ...trackToJson(s.queue[i]),
            'index': i,
            'isCurrent': i == s.queueIndex,
          },
      ],
    };
  }

  List<Map<String, Object?>> listSources() {
    final l10n = _ref.read(l10nProvider);
    return [
      for (final p in sourcePlatforms(_ref))
        {
          'source': p.source,
          'label': p.label(l10n),
          'loggedIn': p.loggedIn(_ref),
        },
    ];
  }

  /// 偏好只读视图；[keys] 非空时仅返回其中包含的键。
  ///
  /// 敏感键（含 key/secret/token/password/cookie/credential）一律剔除，
  /// 即使调用方显式点名也不返回。
  Map<String, Object?> preferences({List<String>? keys}) {
    const sensitive = [
      'key',
      'secret',
      'token',
      'password',
      'cookie',
      'credential',
    ];
    final out = <String, Object?>{};
    _prefs.data.forEach((k, v) {
      if (keys != null && !keys.contains(k)) return;
      final lower = k.toLowerCase();
      if (sensitive.any(lower.contains)) return;
      out[k] = v;
    });
    return {'values': out};
  }

  // ── 播放控制 ──────────────────────────────────────────────────

  Future<Object?> play() async {
    if (!_state.playing) _player.toggle();
    return _ok();
  }

  Future<Object?> pause() async {
    if (_state.playing) _player.toggle();
    return _ok();
  }

  Future<Object?> toggle() async {
    _player.toggle();
    return _ok();
  }

  Future<Object?> stop() async {
    await _player.stop();
    return _ok();
  }

  Future<Object?> nextTrack() async {
    await _player.playNext();
    return _ok();
  }

  Future<Object?> previousTrack() async {
    await _player.playPrevious();
    return _ok();
  }

  Future<Object?> seek(int positionMs) async {
    await _player.seek(Duration(milliseconds: positionMs));
    return _ok();
  }

  Future<Object?> setVolume(double volume) async {
    await _player.setVolume(volume.clamp(0.0, 1.0));
    return {'ok': true, 'volume': volume.clamp(0.0, 1.0)};
  }

  Object? setRepeatMode(String mode) {
    if (!repeatModeCycle.contains(mode)) {
      throw McpActionException(
        'invalid_argument',
        'mode 必须是 ${repeatModeCycle.join(' / ')} 之一',
      );
    }
    _player.setRepeatMode(mode);
    return {'ok': true, 'repeatMode': mode};
  }

  Object? setShuffle(bool enabled) {
    _player.setShuffle(enabled);
    return {'ok': true, 'shuffle': enabled};
  }

  Future<Object?> setQuality(String quality) async {
    if (!audioQualityLevels.contains(quality)) {
      throw McpActionException(
        'invalid_argument',
        'quality 必须是 ${audioQualityLevels.join(' / ')} 之一',
      );
    }
    await _player.setQuality(quality);
    return {'ok': true, 'quality': quality};
  }

  // ── 队列 ──────────────────────────────────────────────────────

  /// 解析「曲目引用」：支持完整 `track` 对象、`ref`（`source:id`），
  /// 或 `source` + `id`（本地曲库额外按 id 回退查询）。
  Track resolveTrack(Map<String, dynamic> args) {
    final rawTrack = args['track'];
    if (rawTrack is Map) {
      return Track.fromJson(Map<String, dynamic>.from(rawTrack));
    }
    final ref = _optString(args, 'ref');
    if (ref != null && ref.isNotEmpty) {
      final cached = _tracks.get(ref);
      if (cached != null) return cached;
    }
    var source = _optString(args, 'source');
    var id = _optString(args, 'id');
    // 未缓存时把 ref（`source:id`）拆分为 source + id（两侧均须非空）。
    if ((source == null || source.isEmpty || id == null || id.isEmpty) &&
        ref != null &&
        ref.isNotEmpty) {
      final sep = ref.indexOf(':');
      if (sep > 0 && sep < ref.length - 1) {
        source = ref.substring(0, sep);
        id = ref.substring(sep + 1);
      }
    }
    if (source != null && source.isNotEmpty && id != null && id.isNotEmpty) {
      final cached = _tracks.get('$source:$id');
      if (cached != null) return cached;
      if (source == 'local') {
        final row = _localRowById(id);
        if (row != null) return trackFromRow(row);
      }
      return Track(
        id: id,
        title: _optString(args, 'title') ?? id,
        source: source,
      );
    }
    throw const McpActionException(
      'invalid_argument',
      '缺少曲目引用：请提供 track、ref 或 source+id',
    );
  }

  List<Track> resolveTrackList(Object? raw) {
    if (raw is! List || raw.isEmpty) {
      throw const McpActionException('invalid_argument', 'tracks 必须是非空数组');
    }
    return [for (final item in raw) _resolveItem(item)];
  }

  Track _resolveItem(Object? item) {
    if (item is String) {
      final cached = _tracks.get(item);
      if (cached != null) return cached;
      throw McpActionException('not_found', '未知曲目引用: $item');
    }
    if (item is Map) return resolveTrack(Map<String, dynamic>.from(item));
    throw const McpActionException(
      'invalid_argument',
      'tracks 元素必须是 ref 字符串或曲目对象',
    );
  }

  Future<Object?> playTrack(Map<String, dynamic> args) async {
    final track = resolveTrack(args);
    await _player.playTrack(track);
    return {'ok': true, 'ref': McpTrackCache.refOf(track)};
  }

  Future<Object?> playTracks(List<Track> tracks, {int startIndex = 0}) async {
    await _player.playQueue(tracks, startIndex: startIndex);
    return {'ok': true, 'count': tracks.length, 'startIndex': startIndex};
  }

  Future<Object?> queueAdd(
    List<Track> tracks, {
    String position = 'next',
  }) async {
    for (final track in tracks) {
      if (position == 'end') {
        _player.appendToQueue(track);
      } else {
        _player.insertToQueue(track);
      }
    }
    return {'ok': true, 'count': tracks.length, 'position': position};
  }

  Future<Object?> queuePlayIndex(int index) async {
    final len = _state.queue.length;
    if (index < 0 || index >= len) {
      throw McpActionException('not_found', '队列索引越界: $index（共 $len 首）');
    }
    await _player.playAtIndex(index);
    return _ok();
  }

  Future<Object?> queueRemove(int index) async {
    final len = _state.queue.length;
    if (index < 0 || index >= len) {
      throw McpActionException('not_found', '队列索引越界: $index（共 $len 首）');
    }
    await _player.removeFromQueue(index);
    return _ok();
  }

  Object? queueMove(int from, int to) {
    final len = _state.queue.length;
    if (from < 0 || from >= len || to < 0 || to >= len) {
      throw McpActionException('not_found', '队列索引越界: $from→$to（共 $len 首）');
    }
    _player.moveInQueue(from, to);
    return _ok();
  }

  Future<Object?> queueClear() async {
    await _player.clearQueue();
    return _ok();
  }

  // ── 睡眠定时（播放） ─────────────────────────────────────────

  /// 设置睡眠定时：`minutes > 0` 为倒计时；`endOfTrack` 为「播完当前曲」。
  Object? setSleepTimer({int? minutes, bool endOfTrack = false}) {
    final notifier = _ref.read(sleepTimerProvider.notifier);
    if (endOfTrack) {
      notifier.startEndOfTrack();
      return const {'ok': true, 'mode': 'endOfTrack'};
    }
    if (minutes == null || minutes <= 0) {
      throw const McpActionException(
        'invalid_argument',
        '需要 minutes > 0，或 endOfTrack = true',
      );
    }
    notifier.startDuration(Duration(minutes: minutes));
    return {'ok': true, 'mode': 'duration', 'minutes': minutes};
  }

  Object? cancelSleepTimer() {
    _ref.read(sleepTimerProvider.notifier).cancel();
    return _ok();
  }

  // ── 外观（主题） ─────────────────────────────────────────────

  Object? setThemeMode(String mode) {
    final parsed = switch (mode) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      'system' => ThemeMode.system,
      _ => null,
    };
    if (parsed == null) {
      throw const McpActionException(
        'invalid_argument',
        'mode 必须是 light / dark / system 之一',
      );
    }
    _ref.read(themeModeProvider.notifier).setMode(parsed);
    return {'ok': true, 'mode': mode};
  }

  // ── 收藏（红心） ─────────────────────────────────────────────

  Map<String, Object?> likeStatus(Map<String, dynamic> args) {
    final track = resolveTrack(args);
    final liked = _ref.read(likeControllerProvider).isLiked(track);
    return {'ref': McpTrackCache.refOf(track), 'liked': liked};
  }

  /// 将收藏状态置为 [target]（已一致则不重复请求）。
  Future<Object?> setLiked(Map<String, dynamic> args, bool target) async {
    final track = resolveTrack(args);
    final controller = _ref.read(likeControllerProvider);
    if (controller.isLiked(track) != target) {
      final ok = await controller.toggle(track);
      if (!ok) {
        throw const McpActionException('unavailable', '收藏操作失败（可能未登录或该音源不支持）');
      }
    }
    return {'ok': true, 'liked': target};
  }

  // ── 播放历史 ─────────────────────────────────────────────────

  Map<String, Object?> historyList(int limit) {
    final entries = _ref.read(historyStoreProvider).entries();
    final tracks = <Track>[];
    final out = <Map<String, Object?>>[];
    for (final entry in entries.take(limit)) {
      tracks.add(entry.track);
      out.add({...trackToJson(entry.track), 'playedAt': entry.playedAt});
    }
    _tracks.putAll(tracks);
    return {'total': entries.length, 'entries': out};
  }

  Object? historyClear() {
    _ref.read(historyStoreProvider).clear();
    return _ok();
  }

  // ── 收藏列表 ─────────────────────────────────────────────────

  /// 某音源「我喜欢的」列表（首次访问会触发加载/刷新；未登录返回空）。
  Future<Object?> listLiked({
    required String source,
    required int limit,
  }) async {
    final store = _ref.read(likedStoreProvider);
    await store.ensureLoaded(source);
    final tracks = store.tracks(source);
    _tracks.putAll(tracks);
    return {
      'source': source,
      'total': store.total(source),
      'tracks': tracks.take(limit).map(trackToJson).toList(),
    };
  }

  // ── 歌词 ─────────────────────────────────────────────────────

  /// 当前曲目的歌词行（时间轴有序；无歌词返回空数组）。
  Future<Object?> lyrics() async {
    final groups = await _ref.read(currentLyricsProvider.future);
    final lines = <Map<String, Object?>>[];
    for (final group in groups) {
      lines.add({
        'timeMs': group.original.timeMs,
        'text': group.original.text,
        if (group.translation != null) 'translation': group.translation,
        if (group.romaji != null) 'romaji': group.romaji,
        if (group.isBG) 'isBackground': true,
        if (group.endMs != null) 'endMs': group.endMs,
      });
    }
    return {'count': lines.length, 'lines': lines};
  }

  // ── 下载 ─────────────────────────────────────────────────────

  Map<String, Object?> downloadList(int limit) {
    final tasks = _ref.read(downloadControllerProvider).tasks;
    return {
      'total': tasks.length,
      'tasks': [
        for (final task in tasks.take(limit))
          {
            'taskId': task.taskId,
            'title': task.title,
            'artist': task.artist,
            'album': task.album,
            'source': task.source,
            'quality': task.quality,
            'status': task.status,
            'received': task.received,
            'total': task.total,
            'speed': task.speed,
            'progress': task.progress,
            'filePath': task.filePath,
            'actualQuality': task.actualQuality,
            'error': task.error,
          },
      ],
    };
  }

  /// 入队下载（元数据来自搜索结果 / 曲库 / 收藏列表；URL 解析在下载引擎内）。
  Future<Object?> downloadAdd(Map<String, dynamic> args) async {
    final track = resolveTrack(args);
    final quality = _optString(args, 'quality');
    final notifier = _ref.read(downloadControllerProvider.notifier);
    await notifier.ensureEngine();
    final taskId = notifier.enqueue(track, quality: quality);
    if (taskId == null) {
      throw const McpActionException('unavailable', '下载入队失败（引擎不可用）');
    }
    return {'ok': true, 'taskId': taskId};
  }

  Object? downloadCancel(String taskId) {
    _ref.read(downloadControllerProvider.notifier).cancel(taskId);
    return _ok();
  }

  Object? downloadRemove(String taskId) {
    _ref.read(downloadControllerProvider.notifier).removeTask(taskId);
    return _ok();
  }

  // ── 在线搜索 ──────────────────────────────────────────────────

  Future<Object?> searchOnline({
    required String source,
    required String query,
    required int limit,
    required int page,
  }) async {
    final platform = sourcePlatform(source);
    if (!platform.searchable) {
      throw McpActionException('unsupported', '音源 $source 不支持搜索');
    }
    if (!platform.enabled(_ref)) {
      throw McpActionException('unsupported', '音源 $source 当前未启用');
    }
    final loaded = (page - 1) * limit;
    final res = await platform.searchSongs(
      _ref,
      query,
      append: page > 1,
      loaded: loaded,
      limit: limit,
    );
    _tracks.putAll(res.items);
    return {
      'source': source,
      'query': query,
      'page': page,
      'limit': limit,
      'total': res.total,
      'hasMore': res.hasMore,
      'tracks': res.items.map(trackToJson).toList(),
    };
  }

  Future<Object?> searchAll({
    required String query,
    required int limitPerSource,
  }) async {
    final results = <Map<String, Object?>>[];
    for (final platform in sourcePlatforms(_ref)) {
      try {
        final res = await platform.searchSongs(
          _ref,
          query,
          append: false,
          loaded: 0,
          limit: limitPerSource,
        );
        _tracks.putAll(res.items);
        results.add({
          'source': platform.source,
          'total': res.total,
          'hasMore': res.hasMore,
          'tracks': res.items.map(trackToJson).toList(),
        });
      } catch (e) {
        results.add({
          'source': platform.source,
          'error': '$e',
          'tracks': const <Object?>[],
        });
      }
    }
    return {'query': query, 'results': results};
  }

  // ── 本地曲库 ──────────────────────────────────────────────────

  Map<String, Object?> librarySearch({
    String? query,
    required int limit,
    required int offset,
  }) {
    final db = _openTracksDb();
    try {
      final rows = db.listTracks(limit: limit, offset: offset, query: query);
      final total = db.countTracks(query: query);
      final tracks = rows.map(trackFromRow).toList();
      _tracks.putAll(tracks);
      return {
        'query': query,
        'total': total,
        'offset': offset,
        'limit': limit,
        'tracks': tracks.map(trackToJson).toList(),
      };
    } finally {
      db.close();
    }
  }

  Map<String, Object?> libraryRandom({required int limit}) {
    final db = _openTracksDb();
    try {
      final tracks = db.randomTracks(limit).map(trackFromRow).toList();
      _tracks.putAll(tracks);
      return {'tracks': tracks.map(trackToJson).toList()};
    } finally {
      db.close();
    }
  }

  Map<String, Object?> libraryStats() {
    final db = _openTracksDb();
    try {
      final stats = db.stats();
      return {
        'tracks': stats.count,
        'totalSizeBytes': stats.totalSize,
        'totalDurationMs': stats.totalDurationMs,
      };
    } finally {
      db.close();
    }
  }

  TracksDb _openTracksDb() {
    try {
      return TracksDb.open();
    } catch (e) {
      throw McpActionException('unavailable', '本地曲库不可用: $e');
    }
  }

  TrackRow? _localRowById(String id) {
    try {
      final db = TracksDb.open();
      try {
        return db.trackById(id);
      } finally {
        db.close();
      }
    } catch (_) {
      return null;
    }
  }
}

// ── 参数解析（JSON 值 → 强类型；失败抛 invalid_argument）────────────────

Never _bad(String message) =>
    throw McpActionException('invalid_argument', message);

String? _optString(Map<String, dynamic> args, String key) {
  final v = args[key];
  if (v == null) return null;
  if (v is String) return v;
  _bad('参数 $key 必须是字符串');
}

String _reqString(Map<String, dynamic> args, String key) {
  final v = _optString(args, key);
  if (v == null || v.trim().isEmpty) _bad('缺少必填参数 $key');
  return v.trim();
}

int _optInt(
  Map<String, dynamic> args,
  String key, {
  int? min,
  int? max,
  int? fallback,
}) {
  final v = args[key];
  if (v == null) {
    if (fallback != null) return fallback;
    _bad('缺少必填参数 $key');
  }
  if (v is! num) _bad('参数 $key 必须是整数');
  final i = v.toInt();
  if (min != null && i < min) _bad('参数 $key 不能小于 $min');
  if (max != null && i > max) _bad('参数 $key 不能大于 $max');
  return i;
}

double _reqDouble(
  Map<String, dynamic> args,
  String key, {
  double? min,
  double? max,
}) {
  final v = args[key];
  if (v is! num) _bad('缺少必填数值参数 $key');
  final d = v.toDouble();
  if (min != null && d < min) _bad('参数 $key 不能小于 $min');
  if (max != null && d > max) _bad('参数 $key 不能大于 $max');
  return d;
}

bool _reqBool(Map<String, dynamic> args, String key) {
  final v = args[key];
  if (v is! bool) _bad('缺少必填布尔参数 $key');
  return v;
}

bool? _optBool(Map<String, dynamic> args, String key) {
  final v = args[key];
  if (v == null) return null;
  if (v is bool) return v;
  _bad('参数 $key 必须是布尔值');
}

/// 曲目引用参数 Schema（play_track / 收藏类工具共用）。
Map<String, Object?> _trackProperties() => {
  'ref': _stringProp('曲目引用（source:id）'),
  'track': {'type': 'object', 'description': '完整曲目对象（Track.toJson 形状）'},
  'source': _stringProp('音源（与 id 搭配）'),
  'id': _stringProp('曲目 id（与 source 搭配）'),
  'title': _stringProp('标题（无缓存时的最小曲目）'),
};

Map<String, Object?> _trackArgsSchema() => _schema(_trackProperties());

/// 工具输入 Schema 便捷构造。
Map<String, Object?> _schema(
  Map<String, Object?> properties, {
  List<String> required = const [],
}) => {
  'type': 'object',
  'properties': properties,
  'required': required,
  'additionalProperties': false,
};

Map<String, Object?> _stringProp(
  String description, {
  int? minLength,
  int? maxLength,
}) => {
  'type': 'string',
  'description': description,
  'minLength': ?minLength,
  'maxLength': ?maxLength,
};

Map<String, Object?> _intProp(
  String description, {
  int? min,
  int? max,
  int? default_,
}) => {
  'type': 'integer',
  'description': description,
  'minimum': ?min,
  'maximum': ?max,
  'default': ?default_,
};

Map<String, Object?> _numberProp(
  String description, {
  double? min,
  double? max,
}) => {
  'type': 'number',
  'description': description,
  'minimum': ?min,
  'maximum': ?max,
};

Map<String, Object?> _boolProp(String description) => {
  'type': 'boolean',
  'description': description,
};

Map<String, Object?> _enumProp(String description, List<String> values) => {
  'type': 'string',
  'description': description,
  'enum': values,
};

Map<String, Object?> _arrayProp(
  String description,
  Map<String, Object?> items,
) => {'type': 'array', 'description': description, 'items': items};

/// 构建完整工具目录（顺序即 MCP `tools/list` 顺序）。
List<McpTool> buildMcpTools(McpActions api) => [
  // ── 只读 ──────────────────────────────────────────────────────
  McpTool(
    name: 'get_status',
    title: '获取播放状态',
    description: '返回当前播放状态：播放/缓冲、进度、时长、音量、播放模式、音质与当前曲目。',
    capability: McpCapability.read,
    readOnly: true,
    inputSchema: _schema(const {}),
    handle: (args) async => api.status(),
  ),
  McpTool(
    name: 'get_now_playing',
    title: '获取当前曲目',
    description: '返回当前正在播放（或暂停）的曲目摘要与进度。',
    capability: McpCapability.read,
    readOnly: true,
    inputSchema: _schema(const {}),
    handle: (args) async => api.nowPlaying(),
  ),
  McpTool(
    name: 'get_queue',
    title: '获取播放队列',
    description: '返回当前播放队列（含索引、是否当前曲目）与循环/随机模式。',
    capability: McpCapability.read,
    readOnly: true,
    inputSchema: _schema(const {}),
    handle: (args) async => api.queueStatus(),
  ),
  McpTool(
    name: 'get_info',
    title: '获取服务信息',
    description: '返回应用名称、版本与运行平台。',
    capability: McpCapability.read,
    readOnly: true,
    inputSchema: _schema(const {}),
    handle: (args) async => api.appInfo(),
  ),
  McpTool(
    name: 'list_sources',
    title: '列出可用音源',
    description: '列出当前已启用且可搜索的在线音源及其登录状态。',
    capability: McpCapability.read,
    readOnly: true,
    inputSchema: _schema(const {}),
    handle: (args) async => {'sources': api.listSources()},
  ),

  // ── 播放控制 ──────────────────────────────────────────────────
  McpTool(
    name: 'play',
    title: '播放',
    description: '开始或继续播放（已在播放时不重复操作）。',
    capability: McpCapability.playback,
    idempotent: true,
    inputSchema: _schema(const {}),
    handle: (args) => api.play(),
  ),
  McpTool(
    name: 'pause',
    title: '暂停',
    description: '暂停播放（已暂停时不重复操作）。',
    capability: McpCapability.playback,
    idempotent: true,
    inputSchema: _schema(const {}),
    handle: (args) => api.pause(),
  ),
  McpTool(
    name: 'toggle',
    title: '播放/暂停切换',
    description: '在播放与暂停之间切换。',
    capability: McpCapability.playback,
    idempotent: false,
    inputSchema: _schema(const {}),
    handle: (args) => api.toggle(),
  ),
  McpTool(
    name: 'stop',
    title: '停止',
    description: '停止播放并清空当前播放态。',
    capability: McpCapability.playback,
    idempotent: true,
    inputSchema: _schema(const {}),
    handle: (args) => api.stop(),
  ),
  McpTool(
    name: 'next_track',
    title: '下一首',
    description: '切换到队列中的下一首。',
    capability: McpCapability.playback,
    idempotent: false,
    inputSchema: _schema(const {}),
    handle: (args) => api.nextTrack(),
  ),
  McpTool(
    name: 'previous_track',
    title: '上一首',
    description: '切换到队列中的上一首。',
    capability: McpCapability.playback,
    idempotent: false,
    inputSchema: _schema(const {}),
    handle: (args) => api.previousTrack(),
  ),
  McpTool(
    name: 'seek',
    title: '跳转播放位置',
    description: '将当前曲目跳转到指定毫秒位置。',
    capability: McpCapability.playback,
    inputSchema: _schema(
      {'positionMs': _intProp('目标位置（毫秒）', min: 0)},
      required: ['positionMs'],
    ),
    handle: (args) => api.seek(_optInt(args, 'positionMs', min: 0)),
  ),
  McpTool(
    name: 'set_volume',
    title: '设置音量',
    description: '设置播放音量（0~1）。',
    capability: McpCapability.playback,
    inputSchema: _schema(
      {'volume': _numberProp('音量（0~1）', min: 0, max: 1)},
      required: ['volume'],
    ),
    handle: (args) => api.setVolume(_reqDouble(args, 'volume', min: 0, max: 1)),
  ),
  McpTool(
    name: 'set_repeat_mode',
    title: '设置循环模式',
    description: '设置循环模式：off 顺序播放 / list 列表循环 / one 单曲循环。',
    capability: McpCapability.playback,
    inputSchema: _schema(
      {'mode': _enumProp('循环模式', repeatModeCycle)},
      required: ['mode'],
    ),
    handle: (args) async => api.setRepeatMode(_reqString(args, 'mode')),
  ),
  McpTool(
    name: 'set_shuffle',
    title: '设置随机播放',
    description: '开启或关闭随机播放。',
    capability: McpCapability.playback,
    inputSchema: _schema(
      {'enabled': _boolProp('是否开启随机播放')},
      required: ['enabled'],
    ),
    handle: (args) async => api.setShuffle(_reqBool(args, 'enabled')),
  ),
  McpTool(
    name: 'set_quality',
    title: '设置音质',
    description: '切换当前音质档位（lq/sq/hq/lossless/hi-res）。',
    capability: McpCapability.playback,
    inputSchema: _schema(
      {'quality': _enumProp('音质档位', audioQualityLevels)},
      required: ['quality'],
    ),
    handle: (args) => api.setQuality(_reqString(args, 'quality')),
  ),

  // ── 队列 ──────────────────────────────────────────────────────
  McpTool(
    name: 'play_track',
    title: '播放指定曲目',
    description: '播放指定曲目（优先用搜索结果返回的 ref；也可传完整 track 对象或 source+id）。',
    capability: McpCapability.playback,
    idempotent: false,
    inputSchema: _schema({
      'ref': _stringProp('曲目引用（source:id）'),
      'track': {'type': 'object', 'description': '完整曲目对象（Track.toJson 形状）'},
      'source': _stringProp('音源（与 id 搭配）'),
      'id': _stringProp('曲目 id（与 source 搭配）'),
      'title': _stringProp('标题（无缓存时的最小曲目）'),
    }),
    handle: (args) => api.playTrack(args),
  ),
  McpTool(
    name: 'play_tracks',
    title: '播放曲目列表',
    description: '用给定曲目列表替换播放队列并开始播放。',
    capability: McpCapability.playback,
    idempotent: false,
    inputSchema: _schema(
      {
        'tracks': _arrayProp('曲目引用数组（ref 字符串或曲目对象）', const {}),
        'startIndex': _intProp('起始索引', min: 0, default_: 0),
      },
      required: ['tracks'],
    ),
    handle: (args) async => api.playTracks(
      api.resolveTrackList(args['tracks']),
      startIndex: _optInt(args, 'startIndex', min: 0, fallback: 0),
    ),
  ),
  McpTool(
    name: 'queue_add',
    title: '添加到队列',
    description: '把曲目加入播放队列；position 为 next（当前曲之后，默认）或 end（队尾）。',
    capability: McpCapability.queue,
    inputSchema: _schema(
      {
        'tracks': _arrayProp('曲目引用数组（ref 字符串或曲目对象）', const {}),
        'position': _enumProp('插入位置', const ['next', 'end']),
      },
      required: ['tracks'],
    ),
    handle: (args) async => api.queueAdd(
      api.resolveTrackList(args['tracks']),
      position: _optString(args, 'position') ?? 'next',
    ),
  ),
  McpTool(
    name: 'queue_play_index',
    title: '播放队列指定项',
    description: '播放当前队列中指定索引的曲目。',
    capability: McpCapability.queue,
    idempotent: false,
    inputSchema: _schema(
      {'index': _intProp('队列索引', min: 0)},
      required: ['index'],
    ),
    handle: (args) => api.queuePlayIndex(_optInt(args, 'index', min: 0)),
  ),
  McpTool(
    name: 'queue_remove',
    title: '移除队列项',
    description: '从播放队列移除指定索引的曲目。',
    capability: McpCapability.queue,
    inputSchema: _schema(
      {'index': _intProp('队列索引', min: 0)},
      required: ['index'],
    ),
    handle: (args) => api.queueRemove(_optInt(args, 'index', min: 0)),
  ),
  McpTool(
    name: 'queue_move',
    title: '调整队列顺序',
    description: '把队列中的曲目从 from 移动到 to。',
    capability: McpCapability.queue,
    inputSchema: _schema(
      {'from': _intProp('源索引', min: 0), 'to': _intProp('目标索引', min: 0)},
      required: ['from', 'to'],
    ),
    handle: (args) async => api.queueMove(
      _optInt(args, 'from', min: 0),
      _optInt(args, 'to', min: 0),
    ),
  ),
  McpTool(
    name: 'queue_clear',
    title: '清空队列',
    description: '清空播放队列并停止播放。',
    capability: McpCapability.queue,
    inputSchema: _schema(const {}),
    handle: (args) => api.queueClear(),
  ),

  // ── 在线搜索 ──────────────────────────────────────────────────
  McpTool(
    name: 'search_online',
    title: '在线搜索歌曲',
    description: '在指定音源搜索歌曲，返回带 ref 的曲目列表（可再用于 play_track/queue_add）。',
    capability: McpCapability.search,
    readOnly: true,
    openWorld: true,
    inputSchema: _schema(
      {
        'source': _enumProp('音源', const [
          'netease',
          'kugou',
          'qqmusic',
          'neko',
        ]),
        'query': _stringProp('搜索关键词', minLength: 1, maxLength: 200),
        'limit': _intProp('每页条数', min: 1, max: 50, default_: 20),
        'page': _intProp('页码（从 1 开始）', min: 1, max: 100, default_: 1),
      },
      required: ['source', 'query'],
    ),
    handle: (args) => api.searchOnline(
      source: _reqString(args, 'source'),
      query: _reqString(args, 'query'),
      limit: _optInt(args, 'limit', min: 1, max: 50, fallback: 20),
      page: _optInt(args, 'page', min: 1, max: 100, fallback: 1),
    ),
  ),
  McpTool(
    name: 'search_all',
    title: '跨音源搜索',
    description: '在全部已启用音源同时搜索并汇总结果。',
    capability: McpCapability.search,
    readOnly: true,
    openWorld: true,
    inputSchema: _schema(
      {
        'query': _stringProp('搜索关键词', minLength: 1, maxLength: 200),
        'limitPerSource': _intProp('每个音源条数', min: 1, max: 30, default_: 10),
      },
      required: ['query'],
    ),
    handle: (args) => api.searchAll(
      query: _reqString(args, 'query'),
      limitPerSource: _optInt(
        args,
        'limitPerSource',
        min: 1,
        max: 30,
        fallback: 10,
      ),
    ),
  ),

  // ── 本地曲库 ──────────────────────────────────────────────────
  McpTool(
    name: 'library_search',
    title: '搜索本地曲库',
    description: '按标题/歌手/专辑搜索本地曲库（query 省略则按标题列出全部）。',
    capability: McpCapability.library,
    readOnly: true,
    inputSchema: _schema({
      'query': _stringProp('关键词', maxLength: 200),
      'limit': _intProp('返回条数', min: 1, max: 200, default_: 50),
      'offset': _intProp('偏移', min: 0, default_: 0),
    }),
    handle: (args) async => api.librarySearch(
      query: _optString(args, 'query'),
      limit: _optInt(args, 'limit', min: 1, max: 200, fallback: 50),
      offset: _optInt(args, 'offset', min: 0, fallback: 0),
    ),
  ),
  McpTool(
    name: 'library_random',
    title: '随机本地曲目',
    description: '从本地曲库随机抽取若干曲目。',
    capability: McpCapability.library,
    readOnly: true,
    inputSchema: _schema({
      'limit': _intProp('条数', min: 1, max: 100, default_: 20),
    }),
    handle: (args) async => api.libraryRandom(
      limit: _optInt(args, 'limit', min: 1, max: 100, fallback: 20),
    ),
  ),
  McpTool(
    name: 'library_stats',
    title: '本地曲库统计',
    description: '返回本地曲库曲目数、总大小与总时长。',
    capability: McpCapability.library,
    readOnly: true,
    inputSchema: _schema(const {}),
    handle: (args) async => api.libraryStats(),
  ),

  // ── 偏好只读 ──────────────────────────────────────────────────
  McpTool(
    name: 'get_preferences',
    title: '读取应用偏好',
    description: '只读返回应用偏好（敏感键一律剔除）；可用 keys 限定返回的键。',
    capability: McpCapability.preferences,
    readOnly: true,
    inputSchema: _schema({
      'keys': _arrayProp('仅返回这些键', const {'type': 'string'}),
    }),
    handle: (args) async {
      final raw = args['keys'];
      final keys = raw is List
          ? raw.whereType<String>().toList(growable: false)
          : null;
      return api.preferences(keys: keys);
    },
  ),

  // ── 睡眠定时 ──────────────────────────────────────────────────
  McpTool(
    name: 'set_sleep_timer',
    title: '设置睡眠定时',
    description: '设置倒计时分钟数暂停播放，或用 endOfTrack 在当前曲播完后暂停。',
    capability: McpCapability.playback,
    inputSchema: _schema({
      'minutes': _intProp('倒计时分钟数（>0）', min: 1, max: 600),
      'endOfTrack': _boolProp('播完当前曲后暂停'),
    }),
    handle: (args) async => api.setSleepTimer(
      minutes: _optInt(args, 'minutes', min: 1, max: 600),
      endOfTrack: _optBool(args, 'endOfTrack') ?? false,
    ),
  ),
  McpTool(
    name: 'cancel_sleep_timer',
    title: '取消睡眠定时',
    description: '取消当前睡眠定时。',
    capability: McpCapability.playback,
    inputSchema: _schema(const {}),
    handle: (args) async => api.cancelSleepTimer(),
  ),

  // ── 外观 ──────────────────────────────────────────────────────
  McpTool(
    name: 'set_theme_mode',
    title: '设置主题模式',
    description: '切换亮色 / 暗色 / 跟随系统。',
    capability: McpCapability.appearance,
    inputSchema: _schema(
      {
        'mode': _enumProp('主题模式', const ['light', 'dark', 'system']),
      },
      required: ['mode'],
    ),
    handle: (args) async => api.setThemeMode(_reqString(args, 'mode')),
  ),

  // ── 收藏（红心） ─────────────────────────────────────────────
  McpTool(
    name: 'get_like_status',
    title: '查询收藏状态',
    description: '查询指定曲目是否已被收藏（红心）。',
    capability: McpCapability.collection,
    readOnly: true,
    inputSchema: _trackArgsSchema(),
    handle: (args) async => api.likeStatus(args),
  ),
  McpTool(
    name: 'like_track',
    title: '收藏曲目',
    description: '将指定曲目加入收藏（红心）。',
    capability: McpCapability.collection,
    inputSchema: _trackArgsSchema(),
    handle: (args) => api.setLiked(args, true),
  ),
  McpTool(
    name: 'unlike_track',
    title: '取消收藏曲目',
    description: '将指定曲目移出收藏（红心）。',
    capability: McpCapability.collection,
    inputSchema: _trackArgsSchema(),
    handle: (args) => api.setLiked(args, false),
  ),
  McpTool(
    name: 'list_liked',
    title: '收藏列表',
    description: '返回某音源「我喜欢的」列表（首次访问触发加载；未登录为空）。',
    capability: McpCapability.collection,
    readOnly: true,
    openWorld: true,
    inputSchema: _schema(
      {
        'source': _enumProp('音源', const [
          'netease',
          'kugou',
          'qqmusic',
          'neko',
        ]),
        'limit': _intProp('返回条数', min: 1, max: 500, default_: 100),
      },
      required: ['source'],
    ),
    handle: (args) => api.listLiked(
      source: _reqString(args, 'source'),
      limit: _optInt(args, 'limit', min: 1, max: 500, fallback: 100),
    ),
  ),

  // ── 歌词 ─────────────────────────────────────────────────────
  McpTool(
    name: 'get_lyrics',
    title: '当前歌词',
    description: '返回当前曲目的歌词行（时间轴有序；无歌词为空数组）。',
    capability: McpCapability.lyrics,
    readOnly: true,
    inputSchema: _schema(const {}),
    handle: (args) async => api.lyrics(),
  ),

  // ── 下载 ─────────────────────────────────────────────────────
  McpTool(
    name: 'download_list',
    title: '下载任务列表',
    description: '返回当前下载任务及其状态、进度。',
    capability: McpCapability.download,
    readOnly: true,
    inputSchema: _schema({
      'limit': _intProp('返回条数', min: 1, max: 200, default_: 50),
    }),
    handle: (args) async => api.downloadList(
      _optInt(args, 'limit', min: 1, max: 200, fallback: 50),
    ),
  ),
  McpTool(
    name: 'download_add',
    title: '添加下载',
    description: '把曲目加入下载队列（用 ref / track / source+id 指定；quality 缺省用设置默认档）。',
    capability: McpCapability.download,
    inputSchema: _schema({
      ..._trackProperties(),
      'quality': _enumProp('音质档位', audioQualityLevels),
    }),
    handle: (args) => api.downloadAdd(args),
  ),
  McpTool(
    name: 'download_cancel',
    title: '取消下载',
    description: '取消指定下载任务。',
    capability: McpCapability.download,
    inputSchema: _schema(
      {'taskId': _stringProp('任务 id', minLength: 1)},
      required: ['taskId'],
    ),
    handle: (args) async => api.downloadCancel(_reqString(args, 'taskId')),
  ),
  McpTool(
    name: 'download_remove',
    title: '移除下载任务',
    description: '从下载列表移除任务记录（不删除已下载文件）。',
    capability: McpCapability.download,
    inputSchema: _schema(
      {'taskId': _stringProp('任务 id', minLength: 1)},
      required: ['taskId'],
    ),
    handle: (args) async => api.downloadRemove(_reqString(args, 'taskId')),
  ),

  // ── 播放历史 ─────────────────────────────────────────────────
  McpTool(
    name: 'history_list',
    title: '播放历史',
    description: '按时间倒序返回播放历史（最近在前）。',
    capability: McpCapability.history,
    readOnly: true,
    inputSchema: _schema({
      'limit': _intProp('返回条数', min: 1, max: 500, default_: 50),
    }),
    handle: (args) async =>
        api.historyList(_optInt(args, 'limit', min: 1, max: 500, fallback: 50)),
  ),
  McpTool(
    name: 'history_clear',
    title: '清空播放历史',
    description: '清空全部播放历史（不可恢复）。',
    capability: McpCapability.history,
    inputSchema: _schema(const {}),
    handle: (args) async => api.historyClear(),
  ),
];
