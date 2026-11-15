// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Songloft 流媒体客户端（Dart 侧薄映射）。
///
/// 协议与网络在 Go（`archoera_songloft_*` FFI）完成；本文件只负责：
///   - 现有 [StreamingClient] 接口 → FFI 方法调用；
///   - Songloft DTO → 现有 [Track] / `Streaming*` 模型；
///   - 封面缓存路径（Go 写盘）与后台预取。
library;

import 'dart:async';
import 'dart:io';

import '../../netease/track.dart';
import '../streaming_errors.dart';
import '../streaming_models.dart';
import '../streaming_types.dart';
import 'songloft_session.dart';

class SongloftClient {
  SongloftClient(this.config);

  final StreamingServerConfig config;

  Future<SongloftSession>? _session;

  Future<SongloftSession> _s() async {
    final cached = _session;
    if (cached != null) return cached;
    final f = SongloftSession.ensure(config);
    _session = f;
    try {
      return await f;
    } catch (_) {
      _session = null;
      rethrow;
    }
  }

  Future<StreamingPingResult> ping() async {
    try {
      final s = await _s();
      return StreamingPingResult(ok: true, version: s.version);
    } catch (e) {
      return StreamingPingResult(ok: false, error: '$e');
    }
  }

  Future<List<StreamingAlbum>> listAlbums({
    int limit = 500,
    int offset = 0,
  }) async {
    final s = await _s();
    final data = await s.call('listAlbums', {
      'offset': offset,
      'limit': limit,
      'sort': 'count',
      'order': 'desc',
    });
    final facets = (data['facets'] as List?) ?? const [];
    final out = <StreamingAlbum>[];
    for (final raw in facets.whereType<Map>()) {
      final name = raw['value']?.toString() ?? '';
      if (name.isEmpty) continue;
      final coverId = (raw['coverSongId'] as num?)?.toInt() ?? 0;
      out.add(StreamingAlbum(
        id: name,
        name: name,
        cover: _cover(s, 'song', coverId),
        trackCount: (raw['count'] as num?)?.toInt(),
      ));
    }
    _prefetch(s, 'song',
        out.map((a) => _coverIdFromPathOrUrl(a.cover)).whereType<int>());
    return out;
  }

  Future<List<StreamingArtist>> listArtists() async {
    final s = await _s();
    final data = await s.call('listArtists', {
      'offset': 0,
      'limit': 500,
      'sort': 'count',
      'order': 'desc',
    });
    final facets = (data['facets'] as List?) ?? const [];
    final out = <StreamingArtist>[];
    for (final raw in facets.whereType<Map>()) {
      final name = raw['value']?.toString() ?? '';
      if (name.isEmpty) continue;
      final coverId = (raw['coverSongId'] as num?)?.toInt() ?? 0;
      out.add(StreamingArtist(
        id: name,
        name: name,
        avatar: _cover(s, 'song', coverId),
      ));
    }
    _prefetch(s, 'song',
        out.map((a) => _coverIdFromPathOrUrl(a.avatar)).whereType<int>());
    return out;
  }

  Future<List<StreamingPlaylist>> listPlaylists() async {
    final s = await _s();
    final data = await s.call('listPlaylists', {'offset': 0, 'limit': 500});
    final list = (data['playlists'] as List?) ?? const [];
    final out = <StreamingPlaylist>[];
    for (final raw in list.whereType<Map>()) {
      final id = (raw['id'] as num?)?.toInt() ?? 0;
      if (id <= 0) continue;
      out.add(StreamingPlaylist(
        id: '$id',
        name: raw['name']?.toString() ?? '',
        description: raw['description']?.toString(),
        cover: _cover(s, 'playlist', id),
        trackCount: (raw['song_count'] as num?)?.toInt(),
      ));
    }
    _prefetch(s, 'playlist',
        out.map((p) => int.tryParse(p.id)).whereType<int>());
    return out;
  }

  Future<List<Track>> listSongs({int limit = 100, int offset = 0}) async {
    final s = await _s();
    final data = await s.call('listSongs', {
      'offset': offset,
      'limit': limit,
      'sort': 'added_at',
      'order': 'desc',
    });
    return _mapSongs(s, (data['songs'] as List?) ?? const []);
  }

  Future<List<Track>> getAlbumSongs(String albumId) async {
    final s = await _s();
    final data = await s.call('listSongs', {
      'offset': 0,
      'limit': 500,
      'sort': 'added_at',
      'order': 'desc',
      'album': albumId,
    });
    return _mapSongs(s, (data['songs'] as List?) ?? const []);
  }

  Future<List<Track>> getArtistSongs(String artistId) async {
    final s = await _s();
    final data = await s.call('listSongs', {
      'offset': 0,
      'limit': 500,
      'sort': 'added_at',
      'order': 'desc',
      'artist': artistId,
    });
    return _mapSongs(s, (data['songs'] as List?) ?? const []);
  }

  Future<List<StreamingAlbum>> getArtistAlbums(String artistId) async {
    // Songloft 没有「歌手 → 专辑」聚合端点；保持空列表（详情页仅展示歌曲）。
    return const [];
  }

  Future<List<Track>> getPlaylistSongs(String playlistId) async {
    final id = int.tryParse(playlistId);
    if (id == null || id <= 0) {
      throw StreamingProtocolError('无效的 Songloft 歌单 id: $playlistId');
    }
    final s = await _s();
    final data = await s.call('getPlaylistSongs', {
      'playlistId': id,
      'offset': 0,
      'limit': 500,
    });
    return _mapSongs(s, (data['songs'] as List?) ?? const []);
  }

  Future<String> getStreamUrl(
    String originalId, {
    String streamingQuality = 'original',
  }) async {
    final id = int.tryParse(originalId);
    if (id == null || id <= 0) {
      throw StreamingProtocolError('无效的 Songloft 歌曲 id: $originalId');
    }
    final s = await _s();
    final data = await s.call('getStreamUrl', {
      'songId': id,
      'quality': streamingQuality,
    });
    final url = data['url']?.toString() ?? '';
    if (url.isEmpty) throw StreamingProtocolError('Songloft 未返回播放地址');
    return url;
  }

  Future<StreamingLyrics> getLyrics(
    String originalId, {
    String? artist,
    String? title,
  }) async {
    final id = int.tryParse(originalId);
    if (id == null || id <= 0) return const StreamingLyrics();
    final s = await _s();
    final data = await s.call('getLyrics', {'songId': id});
    String text(String key) => data[key]?.toString().trim() ?? '';
    final lyric = text('lyric');
    final lxlyric = text('lxlyric');
    final tlyric = text('tlyric');
    final rlyric = text('rlyric');
    // 逐字歌词只认服务端自带（lxlyric）；客户端不主动抓取。
    final rich = _richLyric(lxlyric);
    return StreamingLyrics(
      lrc: lyric.isNotEmpty ? lyric : (rich == null && lxlyric.isNotEmpty ? lxlyric : null),
      wordByWord: rich?.content,
      wordFormat: rich?.format ?? 'lrc',
      translation: tlyric.isEmpty ? null : tlyric,
      translationFormat: tlyric.isEmpty ? null : _lyricFormat(tlyric),
      romaji: rlyric.isEmpty ? null : rlyric,
      romajiFormat: rlyric.isEmpty ? null : _lyricFormat(rlyric),
    );
  }

  /* ------------------------------------------------------------------ */
  /* 映射                                                                */
  /* ------------------------------------------------------------------ */

  List<Track> _mapSongs(SongloftSession s, List<dynamic> raw) {
    final out = <Track>[];
    for (final item in raw.whereType<Map>()) {
      final songId = (item['id'] as num?)?.toInt() ?? 0;
      if (songId <= 0) continue;
      final title = item['title']?.toString() ?? '';
      if (title.isEmpty) continue;
      final album = item['album']?.toString() ?? '';
      final artist = item['artist']?.toString() ?? '';
      final duration = ((item['duration'] as num?)?.toDouble() ?? 0) * 1000;
      out.add(Track(
        id: '${config.id}:$songId',
        title: title,
        artists: [TrackArtist(name: artist)],
        album: album.isEmpty ? null : TrackAlbum(name: album),
        duration: duration.round(),
        cover: _cover(s, 'song', songId),
        fileSize: (item['file_size'] as num?)?.toInt(),
        quality: TrackQuality(
          sampleRate: (item['sample_rate'] as num?)?.toInt() ?? 0,
          channels: 2,
          bitRate: ((item['bit_rate'] as num?)?.toInt() ?? 0) * 1000,
          codec: item['format']?.toString() ?? '',
        ),
        source: 'streaming',
        serverId: config.id,
        originalId: '$songId',
      ));
    }
    _prefetch(s, 'song', out
        .map((t) => int.tryParse(t.originalId ?? ''))
        .whereType<int>());
    return out;
  }

  /// 封面：缓存文件已存在则用本地路径，否则回退带 token 的直链。
  String? _cover(SongloftSession s, String kind, int id) {
    if (id <= 0) return null;
    final path = s.coverPath(kind, id);
    if (File(path).existsSync()) return path;
    return s.coverUrl(kind, id);
  }

  int? _coverIdFromPathOrUrl(String? cover) {
    if (cover == null || cover.isEmpty) return null;
    final m = RegExp(r'/(?:songs|playlists)/(\d+)/cover').firstMatch(cover);
    if (m != null) return int.tryParse(m.group(1)!);
    final file = RegExp(r'(?:song|playlist)-(\d+)\.img$').firstMatch(cover);
    return file == null ? null : int.tryParse(file.group(1)!);
  }

  /// 后台预取封面（Go 取二进制写盘），失败静默；下次刷新即用本地路径。
  void _prefetch(SongloftSession s, String kind, Iterable<int> ids) {
    final todo = ids.where((id) => id > 0).take(24).toList();
    if (todo.isEmpty) return;
    unawaited(() async {
      for (final id in todo) {
        if (File(s.coverPath(kind, id)).existsSync()) continue;
        try {
          await s.call('getCover', {'kind': kind, 'id': id});
        } catch (_) {
          // 封面失败不影响列表
        }
      }
    }());
  }
}

/// 识别服务端逐字歌词文本的格式；普通 LRC / 纯文本返回 null。
///
/// 只做**格式标注**，不做内容转换——解析统一交给歌词引擎
/// `parseLyricGroups`（QRC 会先归一化为 YRC）。
/// 识别服务端逐字歌词文本的格式；普通 LRC / 纯文本返回 null。
///
/// 判定顺序很重要：新版 YRC 与 QRC 的行头都是 `[毫秒,毫秒]`，必须先用词级
/// 标记 `(起点,时长,标记)` 区分，否则 QRC 归一化会把新 YRC 整首吞掉。
String? detectStreamingLyricFormat(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  // 新版 YRC：`[起始,时长](绝对起点,时长,标记)字`。
  if (RegExp(r'^\[\d+,\d+\].*\(\d+,\d+,\d+\)', multiLine: true)
      .hasMatch(text)) {
    return 'yrc';
  }
  // YRC / KRC：`<偏移,时长>字`（KRC 可能是 `<偏移,时长,0>`）。
  if (RegExp(r'<\d+,\d+(?:,\d+)?>').hasMatch(text)) return 'yrc';
  // ESLRC：`<mm:ss.xxx>字`。
  if (RegExp(r'<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>').hasMatch(text)) {
    return 'yrc';
  }
  // QRC：行头 `[起始毫秒,时长毫秒]` + 词级 `字(起始,时长)`。
  if (RegExp(r'^\[\d+,\d+\]', multiLine: true).hasMatch(text)) return 'qrc';
  return null;
}

/// 逐字歌词 → 引擎可解析内容（格式识别见 [detectStreamingLyricFormat]）。
({String content, String format})? _richLyric(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  final format = detectStreamingLyricFormat(text);
  if (format == null) return null;
  return (content: text, format: format);
}

/// 翻译 / 罗马音文本的格式标注（不做内容裁剪）。
String _lyricFormat(String raw) => detectStreamingLyricFormat(raw) ?? 'lrc';
