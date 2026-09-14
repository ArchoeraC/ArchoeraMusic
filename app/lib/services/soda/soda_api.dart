// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 汽水（soda）播放源门面（对齐 QQ/KG 服务形态）。
///
/// - 底层：`apis/soda`（纯 Dart 直连官方，免登录；出站域名硬校验）；
/// - 搜索 / 专辑 / 歌单 → 归一为 [Track]/[CoverItem]；
/// - 播放：SEO `seo_track` → `url_player_info` → `play_info` 取最高码率直链
///   （免费曲为明文 m4a；VIP 曲可能带 `PlayAuth` 需解密，见报告 §7-P4/P5）；
/// - 歌词：SEO 返回 KRC 逐字（原文；格式 `krc`）。
///
/// 本类不持有网络状态（缓存走 apis 层 LRU），只做解析。
library;

import '../../apis/soda/api.dart';
import '../../apis/soda/core/request.dart';
import '../netease/comment.dart';
import '../netease/netease_api.dart' show CoverItem, SearchResult;
import '../netease/track.dart';

/// 汽水业务异常（解析失败 / 无可播流等；message 可直接展示）。
class SodaApiException implements Exception {
  SodaApiException(this.message, {this.code});

  final String message;

  /// 官方 `status_code`（有则携带；`1000016` = 登录态失效）。
  final int? code;

  @override
  String toString() => message;
}

/// 汽水登录态失效错误码。
const int sodaErrSessionExpired = 1000016;

/// 汽水搜索类型码（对齐 apis/soda/modules/search.dart）。
const int sodaTypeTrack = 0;
const int sodaTypeAlbum = 1;
const int sodaTypePlaylist = 2;

class SodaApi {
  // ── 搜索 ────────────────────────────────────────────────────────────

  Future<SearchResult<Track>> searchSongs(
    String keyword, {
    int page = 1,
    int limit = 20,
  }) {
    return _search(keyword, page: page, limit: limit, type: sodaTypeTrack)
        .then(
          (body) => SearchResult<Track>(
            items: _list(body, 'songs').map(_toTrack).toList(),
            total: _total(body),
            hasMore: body['hasMore'] == true,
          ),
        );
  }

  Future<SearchResult<CoverItem>> searchAlbums(
    String keyword, {
    int page = 1,
    int limit = 20,
  }) {
    return _search(keyword, page: page, limit: limit, type: sodaTypeAlbum)
        .then(
          (body) => SearchResult<CoverItem>(
            items: _list(body, 'albums').map(_toAlbumCover).toList(),
            total: _total(body),
            hasMore: body['hasMore'] == true,
          ),
        );
  }

  Future<SearchResult<CoverItem>> searchPlaylists(
    String keyword, {
    int page = 1,
    int limit = 20,
  }) {
    return _search(keyword, page: page, limit: limit, type: sodaTypePlaylist)
        .then(
          (body) => SearchResult<CoverItem>(
            items: _list(body, 'playlists').map(_toPlaylistCover).toList(),
            total: _total(body),
            hasMore: body['hasMore'] == true,
          ),
        );
  }

  Future<Map<String, dynamic>> _search(
    String keyword, {
    required int page,
    required int limit,
    required int type,
  }) async {
    if (keyword.trim().isEmpty) return const {'code': 200, 'total': 0};
    final body = await _guard(
      () => sodaCall('search', {
        'keywords': keyword,
        'page': page,
        'limit': limit,
        'type': type,
      }),
    );
    return body;
  }

  // ── 播放 ────────────────────────────────────────────────────────────

  /// 解析汽水曲目可播放 URL（按 [quality] 从 `video_model` 多档直链选择）。
  ///
  /// 会员 cookie 登录后，`lossless`/`spatial`/`hi_res` 档位才会出现在直链里；
  /// 付费曲未购/未登录仅返回试听片段（`isFull=false` → 拒绝）。
  Future<String?> resolvePlayUrl(Track track, {String quality = 'hq'}) async {
    if (track.id.isEmpty) throw SodaApiException('汽水：缺少 track id');
    final seo = await _guard(() => sodaCall('seo_track', {'id': track.id}));
    if (seo['code'] != 200) {
      throw SodaApiException('汽水：${seo['message'] ?? '单曲信息获取失败'}');
    }
    if (seo['isFull'] == false) {
      throw SodaApiException('汽水：仅提供试听（需登录 / VIP）');
    }

    final qualities =
        (seo['qualities'] as List?)?.whereType<Map>().toList() ?? const [];
    final chosen = _pickQuality(qualities, _sodaQuality(quality));
    final url = chosen == null ? '' : '${chosen['url'] ?? ''}';
    if (url.isNotEmpty) return url;

    // 回退：老 `url_player_info` → `PlayInfo` 路径。
    final infoUrl = '${seo['playerInfoUrl'] ?? ''}';
    if (infoUrl.isEmpty) throw SodaApiException('汽水：未能获取可播放链接');
    final info = await _guard(() => sodaCall('play_info', {'url': infoUrl}));
    if (info['code'] != 200) {
      final msg = info['message']?.toString();
      throw SodaApiException(
        msg?.isNotEmpty == true ? '汽水：$msg' : '汽水：未能获取可播放链接',
      );
    }
    final fallback = '${info['url'] ?? ''}';
    if (fallback.isEmpty) throw SodaApiException('汽水：未能获取可播放链接');
    final auth = '${info['playAuth'] ?? ''}';
    return auth.isEmpty ? fallback : '$fallback#auth=$auth';
  }

  static const _sodaQualityOrder = <String>[
    'medium',
    'higher',
    'highest',
    'lossless',
    'spatial',
    'hi_res',
  ];

  static String _sodaQuality(String q) => switch (q) {
    'lq' => 'medium',
    'sq' => 'higher',
    'hq' => 'highest',
    'lossless' => 'lossless',
    'hi-res' => 'hi_res',
    _ => 'highest',
  };

  static Map<String, dynamic>? _pickQuality(List<Map> list, String want) {
    if (list.isEmpty) return null;
    for (final m in list) {
      if ('${m['quality']}' == want) return Map<String, dynamic>.from(m);
    }
    final idx = _sodaQualityOrder.indexOf(want);
    final order = <String>[
      ..._sodaQualityOrder.sublist(idx < 0 ? 0 : idx + 1),
      ..._sodaQualityOrder.sublist(0, idx < 0 ? 0 : idx).reversed,
    ];
    for (final q in order) {
      for (final m in list) {
        if ('${m['quality']}' == q) return Map<String, dynamic>.from(m);
      }
    }
    return Map<String, dynamic>.from(list.first);
  }

  /// 汽水 KRC 逐字歌词原文（无歌词返回 null）。
  Future<String?> lyricRaw(Track track) async {
    if (track.id.isEmpty) return null;
    final seo = await _guard(() => sodaCall('seo_track', {'id': track.id}));
    if (seo['code'] != 200) return null;
    final krc = '${seo['lyric'] ?? ''}';
    return krc.isEmpty ? null : krc;
  }

  // ── 详情 ────────────────────────────────────────────────────────────

  /// 歌单单页曲目（`cursor` 为空取首页）。
  Future<({List<Track> songs, String nextCursor, bool hasMore})> playlistTracks(
    String id, {
    String cursor = '',
    int limit = 100,
  }) async {
    if (id.isEmpty) return (songs: const <Track>[], nextCursor: '', hasMore: false);
    final body = await _guard(
      () => sodaCall('playlist', {'id': id, 'cursor': cursor, 'limit': limit}),
    );
    return (
      songs: _list(body, 'songs').map(_toTrack).toList(),
      nextCursor: '${body['nextCursor'] ?? ''}',
      hasMore: body['hasMore'] == true,
    );
  }

  /// 专辑全部曲目。
  Future<List<Track>> albumTracks(String id) async {
    if (id.isEmpty) return const [];
    final body = await _guard(() => sodaCall('album', {'id': id}));
    return _list(body, 'songs').map(_toTrack).toList();
  }

  // ── 评论 ────────────────────────────────────────────────────────────

  /// 歌曲评论（免登录可读；[hot] 热门 / 最新两 Tab）。
  Future<NeteaseCommentPage> songComments(
    String id, {
    int page = 1,
    int limit = 20,
    bool hot = false,
  }) async {
    if (id.isEmpty) {
      return NeteaseCommentPage(
        list: const [],
        total: 0,
        page: page,
        limit: limit,
      );
    }
    final body = await _guard(
      () => sodaCall('comments', {
        'id': id,
        'cursor': (page - 1) * limit,
        'limit': limit,
        'groupType': hot ? 1 : 0,
      }),
    );
    final list = _list(body, 'comments').map(_toComment).toList();
    return NeteaseCommentPage(
      list: list,
      total: (body['total'] as num?)?.toInt() ?? list.length,
      page: page,
      limit: limit,
    );
  }

  /// 发布歌曲评论（需登录）。
  Future<void> sendComment(String id, String text) async {
    if (id.isEmpty || text.trim().isEmpty) return;
    final body = await _guard(
      () => sodaCall('send_comment', {'id': id, 'text': text}),
    );
    if (body['code'] != 200) {
      final code = (body['code'] as num?)?.toInt();
      if (code == sodaErrSessionExpired) sodaClearCookies();
      throw SodaApiException(
        '汽水：${body['message'] ?? '评论发送失败'}',
        code: code,
      );
    }
  }

  static NeteaseComment _toComment(Map<String, dynamic> c) {
    final avatar = c['avatar']?.toString() ?? '';
    final ipLabel = c['ipLabel']?.toString() ?? '';
    return NeteaseComment(
      id: c['id']?.toString() ?? '',
      userName: c['nickname']?.toString() ?? '',
      avatar: avatar.isEmpty ? null : avatar,
      text: c['content']?.toString() ?? '',
      location: ipLabel.isEmpty ? null : ipLabel,
      likedCount: (c['like'] as num?)?.toInt() ?? 0,
      time: (c['time'] as num?)?.toInt(),
    );
  }

  // ── 解析辅助 ─────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _guard(
    Future<Object?> Function() run,
  ) async {
    try {
      final value = await run();
      if (value is Map<String, dynamic>) return value;
      if (value is Map) return Map<String, dynamic>.from(value);
      throw SodaApiException('汽水：响应结构异常');
    } on SodaApiException {
      rethrow;
    } on SodaRequestException catch (e) {
      throw SodaApiException(e.message);
    } catch (err) {
      throw SodaApiException('汽水：$err');
    }
  }

  static List<Map<String, dynamic>> _list(Object? body, String key) {
    if (body is! Map) return const [];
    final raw = body[key];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
  }

  static int _total(Map<String, dynamic> body) =>
      (body['total'] as num?)?.toInt() ?? _list(body, 'songs').length;

  static Track _toTrack(Map<String, dynamic> s) {
    final cover = s['cover']?.toString();
    final albumName = s['album']?.toString() ?? '';
    final artistNames =
        (s['artists'] as List?)?.whereType<String>().toList() ?? const [];
    return Track(
      id: s['id']?.toString() ?? '',
      title: s['name']?.toString() ?? '',
      artists: artistNames.map((n) => TrackArtist(name: n)).toList(),
      album: albumName.isEmpty
          ? null
          : TrackAlbum(
              id: s['albumId']?.toString(),
              name: albumName,
              cover: (cover == null || cover.isEmpty) ? null : cover,
            ),
      duration: (s['duration'] as num?)?.toInt() ?? 0,
      cover: (cover == null || cover.isEmpty) ? null : cover,
      fee: s['vip'] == true ? 1 : 0,
      quality: _qualityOf(s),
      source: 'soda',
    );
  }

  /// 汽水：由 `bit_rates` 归一出的最高档位（无损 → codec=flac；否则按码率）。
  static TrackQuality? _qualityOf(Map<String, dynamic> s) {
    final lossless = s['lossless'] == true;
    final bitRate = (s['bitRate'] as num?)?.toInt() ?? 0;
    if (!lossless && bitRate <= 0) return null;
    return TrackQuality(
      codec: lossless ? 'flac' : 'mp3',
      bitRate: bitRate,
      channels: 2,
    );
  }

  static CoverItem _toAlbumCover(Map<String, dynamic> a) => CoverItem(
    id: a['id']?.toString() ?? '',
    title: a['name']?.toString() ?? '',
    cover: a['cover']?.toString(),
    subtitle: a['artist']?.toString() ?? '',
    trackCount: (a['trackCount'] as num?)?.toInt() ?? 0,
    source: 'soda',
  );

  static CoverItem _toPlaylistCover(Map<String, dynamic> p) => CoverItem(
    id: p['id']?.toString() ?? '',
    title: p['name']?.toString() ?? '',
    cover: p['cover']?.toString(),
    subtitle: p['creator']?.toString() ?? '',
    trackCount: (p['trackCount'] as num?)?.toInt() ?? 0,
    source: 'soda',
  );
}
