/// Subsonic / Navidrome / OpenSubsonic 客户端（接收方）——纯 Dart HTTP。
///
/// 对齐 Web 端 services/streaming/subsonic.ts：
///   - 鉴权：每次请求生成 salt + md5(password+salt) 作为 query 参数
///   - 视图 URL（封面/流）用稳定 salt+token 缓存，会话期间不变，便于缓存命中
///   - 响应按 subsonic-response 包装解包，错误码映射（40-44 鉴权 / 50 / 70）
///   - 错误体系统一走 core/streaming（StreamingAuthError 等）
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../netease/track.dart';
import '../streaming/streaming_errors.dart';
import '../streaming/streaming_types.dart';
import 'subsonic_local.dart';
import 'subsonic_models.dart';

const String subsonicApiVersion = '1.16.1';
const String subsonicClientName = 'ArchoeraMusic';

/* ------------------------------------------------------------------ */
/* 客户端                                                              */
/* ------------------------------------------------------------------ */

/// Subsonic 客户端（无状态；每次调用新 salt，除视图 URL 复用稳定缓存）。
class SubsonicClient {
  SubsonicClient(this.config);

  final StreamingServerConfig config;

  static const _requestTimeout = Duration(seconds: 30);
  static final HttpClient _client = HttpClient()..connectionTimeout = const Duration(seconds: 15);

  /// 关闭底层连接池。
  static void closeHttpClient() => _client.close(force: true);

  /// 基础地址：本机内置服务端（isArchoeraServer）连接时自动协商端口。
  String get _base => resolvedServerBaseUrl(config);

  /// 12 字符 hex salt。
  String _newSalt() {
    final rng = Random.secure();
    final bytes = List<int>.generate(6, (_) => rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// 视图用的稳定 salt+token 缓存：同一密码 → 同一组 salt+token。
  final Map<String, Map<String, String>> _viewAuthCache = {};

  Map<String, String> _viewAuthKey() {
    final h = md5.convert(utf8.encode(config.password)).toString().substring(0, 8);
    return {'key': '${config.id}:$h'};
  }

  /// 视图 builder：稳定 salt+token，整会话复用（封面/流 URL 用）。
  Map<String, String> _buildViewAuth() {
    final k = _viewAuthKey()['key']!;
    final cached = _viewAuthCache[k];
    if (cached != null) return Map.of(cached);
    _viewAuthCache.removeWhere((key, _) => key.startsWith('${config.id}:'));
    final params = _buildAuth();
    _viewAuthCache[k] = params;
    return Map.of(params);
  }

  /// 使该服务器的视图鉴权缓存失效（密码变更时调用）。
  void invalidateViewAuth() {
    _viewAuthCache.removeWhere((key, _) => key.startsWith('${config.id}:'));
  }

  /// 每次请求新生成 salt+token（API 调用用）。
  Map<String, String> _buildAuth() {
    final salt = _newSalt();
    final token = md5.convert(utf8.encode(config.password + salt)).toString();
    return {
      'u': config.username,
      't': token,
      's': salt,
      'v': subsonicApiVersion,
      'c': subsonicClientName,
      'f': 'json',
    };
  }

  /// 给已剥离 auth 的 URL 附上当前会话视图鉴权（封面/流 URL 缓存复用）。
  String attachAuthToUrl(String url) {
    try {
      final u = Uri.parse(url);
      final auth = _buildViewAuth();
      final query = Map<String, String>.from(u.queryParameters);
      query.addAll(auth);
      return u.replace(queryParameters: query).toString();
    } catch (_) {
      return url;
    }
  }

  /// 拼出带鉴权 query 的 endpoint URL。
  String _buildUrl(String endpoint, [Map<String, Object> extra = const {}]) {
    final params = _buildAuth();
    for (final e in extra.entries) {
      params[e.key] = e.value.toString();
    }
    return '$_base/rest/$endpoint?${_encode(params)}';
  }

  static String _encode(Map<String, String> params) {
    return params.entries
        .map((e) =>
            '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
  }

  /// 发起 Subsonic 请求并解包；status="failed" 时按错误码抛对应异常。
  Future<Map<String, dynamic>> _callApi(
    String endpoint, [
    Map<String, Object> extra = const {},
  ]) async {
    final url = _buildUrl(endpoint, extra);
    final req = await _client.getUrl(Uri.parse(url)).timeout(_requestTimeout);
    final res = await req.close().timeout(_requestTimeout);
    final status = res.statusCode;
    if (status == 401 || status == 403) {
      throw StreamingAuthError('HTTP $status');
    }
    if (status < 200 || status >= 300) {
      throw StreamingHttpError(status, 'HTTP $status');
    }
    final text = await res.transform(utf8.decoder).join().timeout(_requestTimeout);
    Map<String, dynamic> json;
    try {
      json = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      throw StreamingProtocolError('响应不是合法 JSON');
    }
    final wrap = json['subsonic-response'];
    if (wrap is! Map) throw StreamingProtocolError('响应缺少 subsonic-response 包装');
    final wrapMap = wrap.cast<String, dynamic>();
    if (wrapMap['status'] != 'ok') {
      final err = wrapMap['error'];
      final code = err is Map ? (err['code'] as num?)?.toInt() : null;
      final message = err is Map ? (err['message']?.toString() ?? '') : '';
      throw _subsonicError(code, message);
    }
    return wrapMap;
  }

  /// Subsonic 错误码 → 统一流媒体异常。
  StreamingError _subsonicError(int? code, String message) {
    if (code != null && (code == 40 || code == 41 || code == 42 || code == 43 || code == 44)) {
      return StreamingAuthError(message);
    }
    if (code == 50) return StreamingHttpError(403, message);
    if (code == 70) return StreamingHttpError(404, message);
    return StreamingProtocolError(message);
  }

  /* ------------------------------------------------------------------ */
  /* API                                                                 */
  /* ------------------------------------------------------------------ */

  /// Ping 服务器拿版本号。
  Future<StreamingPingResult> ping() async {
    try {
      final wrap = await _callApi('ping');
      return StreamingPingResult(
        ok: true,
        version: (wrap['serverVersion'] ?? wrap['version'])?.toString(),
      );
    } catch (err) {
      return StreamingPingResult(ok: false, error: err.toString(), code: classifyError(err));
    }
  }

  /// 取流播放 URL（Subsonic 协议无 PlaySessionId）。
  String getStreamUrl(String originalId) =>
      subsonicStreamUrl(_base, originalId, _buildAuth());

  /// 拉专辑列表（按字母排序）。
  Future<List<StreamingAlbum>> listAlbums({int limit = 500, int offset = 0}) async {
    final wrap = await _callApi('getAlbumList2', {
      'type': 'alphabeticalByName',
      'size': limit,
      'offset': offset,
    });
    final list = _list(wrap['albumList2'], 'album', SubsonicAlbum.fromJson);
    final auth = _buildViewAuth();
    return list.map((a) => subsonicAlbumToView(_base, a, auth)).toList();
  }

  /// 拉歌手列表。
  Future<List<StreamingArtist>> listArtists() async {
    final wrap = await _callApi('getArtists');
    final out = <StreamingArtist>[];
    final auth = _buildViewAuth();
    final artists = wrap['artists'];
    final indexes = artists is Map ? artists['index'] : null;
    if (indexes is List) {
      for (final idx in indexes.whereType<Map>()) {
        final artistNodes = idx['artist'];
        if (artistNodes is! List) continue;
        for (final ar in artistNodes.whereType<Map>()) {
          out.add(subsonicArtistToView(
              _base, SubsonicArtist.fromJson(ar.cast<String, dynamic>()), auth));
        }
      }
    }
    return out;
  }

  /// 拉歌单列表。
  Future<List<StreamingPlaylist>> listPlaylists() async {
    final wrap = await _callApi('getPlaylists');
    final list = _list(wrap['playlists'], 'playlist', SubsonicPlaylist.fromJson);
    final auth = _buildViewAuth();
    return list.map((p) => subsonicPlaylistToView(_base, p, auth)).toList();
  }

  /// 拉歌曲列表。
  Future<List<Track>> listSongs({int limit = 100, int offset = 0}) async {
    final wrap = await _callApi('search3', {
      'query': '',
      'songCount': limit,
      'songOffset': offset,
      'artistCount': 0,
      'albumCount': 0,
    });
    return _toTracks(_list(wrap['searchResult3'], 'song', SubsonicSong.fromJson));
  }

  /// 拉指定专辑的歌曲。
  Future<List<Track>> getAlbumSongs(String albumId) async {
    final wrap = await _callApi('getAlbum', {'id': albumId});
    final album = SubsonicAlbum.fromJson(wrap['album'].cast<String, dynamic>());
    return _toTracks(album.song ?? const []);
  }

  /// 拉指定歌单的歌曲。
  Future<List<Track>> getPlaylistSongs(String playlistId) async {
    final wrap = await _callApi('getPlaylist', {'id': playlistId});
    final pl = SubsonicPlaylist.fromJson(wrap['playlist'].cast<String, dynamic>());
    return _toTracks(pl.entry ?? const []);
  }

  /// 拉指定歌手名下的专辑。
  Future<List<StreamingAlbum>> getArtistAlbums(String artistId) async {
    final wrap = await _callApi('getArtist', {'id': artistId});
    final list = _list(wrap['artist'], 'album', SubsonicAlbum.fromJson);
    final auth = _buildViewAuth();
    return list.map((a) => subsonicAlbumToView(_base, a, auth)).toList();
  }

  /// 拉指定歌手名下的所有歌曲（getArtist + 逐个 getAlbum，顺序防打爆服务器）。
  Future<List<Track>> getArtistSongs(String artistId) async {
    final wrap = await _callApi('getArtist', {'id': artistId});
    final albums = _list(wrap['artist'], 'album', SubsonicAlbum.fromJson);
    final tracks = <Track>[];
    for (final al in albums) {
      if (al.id.isEmpty) continue;
      try {
        tracks.addAll(await getAlbumSongs(al.id));
      } catch (_) {
        // 单张专辑失败不影响其它
      }
    }
    return tracks;
  }

  /// 搜索歌曲/专辑/歌手（search3）。
  Future<StreamingSearchResult> search(String query) async {
    final wrap = await _callApi('search3', {
      'query': query,
      'artistCount': 50,
      'albumCount': 50,
      'songCount': 100,
    });
    final auth = _buildViewAuth();
    return StreamingSearchResult(
      songs: _toTracks(_list(wrap['searchResult3'], 'song', SubsonicSong.fromJson)),
      albums: _list(wrap['searchResult3'], 'album', SubsonicAlbum.fromJson)
          .map((a) => subsonicAlbumToView(_base, a, auth))
          .toList(),
      artists: _list(wrap['searchResult3'], 'artist', SubsonicArtist.fromJson)
          .map((a) => subsonicArtistToView(_base, a, auth))
          .toList(),
    );
  }

  /// 取歌词；优先 getLyricsBySongId 转 LRC，失败回退旧 getLyrics。
  Future<String?> getLyrics(String originalId, {String? artist, String? title}) async {
    try {
      final wrap = await _callApi('getLyricsBySongId', {'id': originalId});
      final lyricsList = wrap['lyricsList'];
      if (lyricsList is Map) {
        final structured = lyricsList['structuredLyrics'];
        if (structured is List && structured.isNotEmpty) {
          final line = (structured.first as Map)['line'];
          if (line is List && line.isNotEmpty) {
            return line
                .map((l) {
                  final m = l as Map;
                  return '${formatLrcTimestamp((m['start'] as num? ?? 0).toInt())}'
                      '${m['value'] ?? ''}';
                })
                .join('\n');
          }
        }
      }
    } catch (_) {
      // 旧 Subsonic 没有 getLyricsBySongId，下面回退
    }

    if (artist != null || title != null) {
      try {
        final wrap = await _callApi('getLyrics', {
          'artist': artist ?? '',
          'title': title ?? '',
        });
        final lyrics = wrap['lyrics'];
        if (lyrics is Map) {
          final text = lyrics['value']?.toString() ?? '';
          if (text.trim().isNotEmpty) return text;
        }
      } catch (_) {
        // 没有就没有
      }
    }
    return null;
  }

  List<Track> _toTracks(List<SubsonicSong> songs) {
    final auth = _buildViewAuth();
    return songs.map((s) => subsonicSongToTrack(config.id, _base, s, auth)).toList();
  }

  /// 从响应 map 取 `node` 的 `key` 列表并解析为指定模型。
  static List<T> _list<T>(
    Object? node,
    String key,
    T Function(Map<String, dynamic>) fromJson,
  ) {
    if (node is! Map) return const [];
    final raw = node[key];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => fromJson(e.cast<String, dynamic>()))
        .toList();
  }
}
