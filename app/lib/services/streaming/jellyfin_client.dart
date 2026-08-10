/// Jellyfin / Emby 客户端（对齐 services/streaming/jellyfin.ts + emby.ts）。
///
/// Emby 是 Jellyfin 的变体：请求头用 `X-Emby-Authorization`、流 URL 追加
/// `Static=true&EnableRemoteMedia=true`。差异均按
/// [StreamingServerConfig.type] 在内部区分，因此 [EmbyClient] 仅继承本类。
///
/// 鉴权：POST /Users/AuthenticateByName 换 AccessToken/UserId。
library;

import 'dart:convert';

import '../netease/track.dart';
import '../subsonic/subsonic_local.dart';
import 'streaming_errors.dart';
import 'streaming_http.dart';
import 'streaming_models.dart';
import 'streaming_session.dart';
import 'streaming_types.dart';

/// Jellyfin 客户端。
class JellyfinClient {
  JellyfinClient(this.config);

  final StreamingServerConfig config;

  static const _clientName = 'Archoera';
  static const _clientVersion = '1.0.0';
  static const _deviceName = 'Archoera Desktop';

  bool get _isEmby => config.type == StreamingServerType.emby;

  /// 派生稳定 deviceId（基于 cfg.id）。
  String _deviceId() => 'archoera-${config.id}';

  /// 拼 MediaBrowser 鉴权 header 字符串。
  String _buildAuthHeader() {
    final parts = <String>[
      'Client="$_clientName"',
      'Device="$_deviceName"',
      'DeviceId="${_deviceId()}"',
      'Version="$_clientVersion"',
    ];
    final token = config.accessToken;
    if (token != null && token.isNotEmpty) parts.add('Token="$token"');
    return 'MediaBrowser ${parts.join(', ')}';
  }

  /// 构造请求头（Emby 用 X-Emby-Authorization，Jellyfin 用 Authorization）。
  Map<String, String> _headers() => {
        'Content-Type': 'application/json',
        if (_isEmby)
          'X-Emby-Authorization': _buildAuthHeader()
        else
          'Authorization': _buildAuthHeader(),
      };

  /// 给已剥离 api_key 的 image URL 附上当前 accessToken；无 token 直接透传。
  String attachAuthToUrl(String url) {
    final token = config.accessToken;
    if (token == null || token.isEmpty) return url;
    try {
      final u = Uri.parse(url);
      final params = Map<String, String>.from(u.queryParameters);
      params['api_key'] = token;
      return u.replace(queryParameters: params).toString();
    } catch (_) {
      return url;
    }
  }

  /// 发起 Jellyfin/Emby 请求；204 返回空 map，2xx 解 JSON。
  Future<Map<String, dynamic>> _callApi(
    String path, {
    String method = 'GET',
    Object? body,
  }) async {
    final url = '${resolvedServerBaseUrl(config)}/${path.replaceFirst(RegExp(r'^/'), '')}';
    final res = await fetchWithTimeout(url, method: method, headers: _headers(), body: body);
    ensureOk(res);
    if (res.statusCode == 204) return const {};
    final text = await readBody(res);
    if (text.isEmpty) return const {};
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) return decoded;
      return const {};
    } catch (_) {
      throw StreamingProtocolError('响应不是合法 JSON');
    }
  }

  /// Ping 服务器拿版本号。
  Future<StreamingPingResult> ping() async {
    try {
      final json = await _callApi('System/Info/Public');
      return StreamingPingResult(ok: true, version: json['Version']?.toString());
    } catch (err) {
      return StreamingPingResult(ok: false, error: err.toString(), code: classifyError(err));
    }
  }

  /// 用账号密码换取 AccessToken/UserId。
  Future<StreamingAuthResult> authenticate() async {
    final json = await _callApi(
      'Users/AuthenticateByName',
      method: 'POST',
      body: {'Username': config.username, 'Pw': config.password},
    );
    final accessToken = json['AccessToken']?.toString();
    final user = json['User'];
    final userId = user is Map ? user['Id']?.toString() : null;
    if (accessToken == null || accessToken.isEmpty || userId == null || userId.isEmpty) {
      throw StreamingProtocolError('登录响应缺少 AccessToken/UserId');
    }
    return StreamingAuthResult(accessToken: accessToken, userId: userId);
  }

  /// 校验已登录并返回 userId；缺 accessToken/userId 抛 [StreamingAuthError]。
  String _requireAuth() {
    final token = config.accessToken;
    final userId = config.userId;
    if (token == null || token.isEmpty || userId == null || userId.isEmpty) {
      throw StreamingAuthError('缺少 accessToken / userId');
    }
    return userId;
  }

  /// 取流播放 URL（universal 端点按 Container/AudioCodec 协商）。
  ///
  /// [playSessionId] 由上层维护（sessionIdForTrack）；不传则随机生成。
  Future<String> getStreamUrl(String originalId, {String? playSessionId}) async {
    final userId = _requireAuth();
    final query = <String, String>{
      'UserId': userId,
      'DeviceId': _deviceId(),
      'Container':
          'mp3,m4a|aac,m4a|alac,m4b|aac,flac,webma|opus,webm|opus,ogg|opus,ogg|vorbis,wav,oga',
      'PlaySessionId': playSessionId ?? newUuid(),
      'api_key': config.accessToken!,
      'StartTimeTicks': '0',
      'EnableRedirection': 'true',
      'EnableRemoteMedia': _isEmby ? 'true' : 'false',
      if (_isEmby) 'Static': 'true',
    };
    return '${resolvedServerBaseUrl(config)}/Audio/$originalId/universal?${encodeQuery(query)}';
  }

  /// 调用 /Users/{id}/Items 拿条目列表。
  Future<List<JellyItem>> _fetchUserItems(String userId, Map<String, Object> query) async {
    final params = query.entries
        .map((e) =>
            '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value.toString())}')
        .join('&');
    final json = await _callApi('Users/$userId/Items?$params');
    return _itemsOf(json);
  }

  List<JellyItem> _itemsOf(Map<String, dynamic> json) {
    final items = json['Items'];
    if (items is! List) return const [];
    return items
        .whereType<Map>()
        .map((e) => JellyItem.fromJson(e.cast<String, dynamic>()))
        .toList();
  }

  /// 拉专辑列表（按字母升序）。
  Future<List<StreamingAlbum>> listAlbums({int limit = 500, int offset = 0}) async {
    final userId = _requireAuth();
    final items = await _fetchUserItems(userId, {
      'IncludeItemTypes': 'MusicAlbum',
      'Recursive': 'true',
      'SortBy': 'SortName',
      'SortOrder': 'Ascending',
      'Limit': limit,
      'StartIndex': offset,
    });
    return items.map((it) => jellyItemToAlbum(config, it)).toList();
  }

  /// 拉歌手列表（/Artists 端点按 AlbumArtist 聚合）。
  Future<List<StreamingArtist>> listArtists() async {
    final userId = _requireAuth();
    final json = await _callApi(
        'Artists?userId=$userId&Recursive=true&SortBy=Name&SortOrder=Ascending');
    return _itemsOf(json).map((it) => jellyItemToArtist(config, it)).toList();
  }

  /// 拉歌单列表。
  Future<List<StreamingPlaylist>> listPlaylists() async {
    final userId = _requireAuth();
    final items = await _fetchUserItems(userId, {
      'IncludeItemTypes': 'Playlist',
      'Recursive': 'true',
      'SortBy': 'SortName',
    });
    return items.map((it) => jellyItemToPlaylist(config, it)).toList();
  }

  /// 拉歌曲列表（按入库时间倒序）。
  Future<List<Track>> listSongs({int limit = 100, int offset = 0}) async {
    final userId = _requireAuth();
    final items = await _fetchUserItems(userId, {
      'IncludeItemTypes': 'Audio',
      'Recursive': 'true',
      'SortBy': 'DateCreated,SortName',
      'SortOrder': 'Descending',
      'Fields': 'MediaSources',
      'Limit': limit,
      'StartIndex': offset,
    });
    return items.map((it) => jellyItemToTrack(config, it)).toList();
  }

  /// 拉指定专辑的歌曲（按碟号、曲号排序）。
  Future<List<Track>> getAlbumSongs(String albumId) async {
    final userId = _requireAuth();
    final items = await _fetchUserItems(userId, {
      'ParentId': albumId,
      'IncludeItemTypes': 'Audio',
      'Fields': 'MediaSources',
      'SortBy': 'ParentIndexNumber,IndexNumber,SortName',
    });
    return items.map((it) => jellyItemToTrack(config, it)).toList();
  }

  /// 拉指定歌单的歌曲。
  Future<List<Track>> getPlaylistSongs(String playlistId) async {
    final userId = _requireAuth();
    final json = await _callApi('Playlists/$playlistId/Items?UserId=$userId&Fields=MediaSources');
    return _itemsOf(json).map((it) => jellyItemToTrack(config, it)).toList();
  }

  /// 拉指定歌手名下的专辑（按年份倒序）。
  Future<List<StreamingAlbum>> getArtistAlbums(String artistId) async {
    final userId = _requireAuth();
    final items = await _fetchUserItems(userId, {
      'AlbumArtistIds': artistId,
      'IncludeItemTypes': 'MusicAlbum',
      'Recursive': 'true',
      'SortBy': 'ProductionYear,SortName',
      'SortOrder': 'Descending',
    });
    return items.map((it) => jellyItemToAlbum(config, it)).toList();
  }

  /// 拉指定歌手名下的所有歌曲（Jellyfin 直接按 ArtistIds 过滤）。
  Future<List<Track>> getArtistSongs(String artistId) async {
    final userId = _requireAuth();
    final items = await _fetchUserItems(userId, {
      'ArtistIds': artistId,
      'IncludeItemTypes': 'Audio',
      'Recursive': 'true',
      'Fields': 'MediaSources',
      'SortBy': 'Album,ParentIndexNumber,IndexNumber,SortName',
    });
    return items.map((it) => jellyItemToTrack(config, it)).toList();
  }

  /// 搜索歌曲/专辑/歌手（三类并发拉取，每类限 50 条）。
  Future<StreamingSearchResult> search(String query) async {
    final userId = _requireAuth();
    Future<List<JellyItem>> byType(String type) => _fetchUserItems(userId, {
          'IncludeItemTypes': type,
          'Recursive': 'true',
          'SearchTerm': query,
          'Fields': 'MediaSources',
          'Limit': 50,
        });
    final results = await Future.wait([
      byType('Audio'),
      byType('MusicAlbum'),
      byType('MusicArtist'),
    ]);
    return StreamingSearchResult(
      songs: results[0].map((it) => jellyItemToTrack(config, it)).toList(),
      albums: results[1].map((it) => jellyItemToAlbum(config, it)).toList(),
      artists: results[2].map((it) => jellyItemToArtist(config, it)).toList(),
    );
  }

  /// 取歌词（Jellyfin 10.8+ /Audio/{id}/Lyrics）；同步行转 LRC，纯文本不加时间戳。
  Future<String?> getLyrics(String originalId) async {
    final token = config.accessToken;
    if (token == null || token.isEmpty) return null;
    try {
      final json = await _callApi('Audio/$originalId/Lyrics');
      final linesRaw = json['Lyrics'];
      final lines = linesRaw is List
          ? linesRaw
              .whereType<Map>()
              .map((l) => (
                    start: (l['Start'] as num?)?.toInt() ?? 0,
                    text: l['Text']?.toString() ?? '',
                  ))
              .toList()
          : <({int start, String text})>[];
      if (lines.isEmpty) return null;
      final meta = json['Metadata'];
      final isSyncedFlag = meta is Map ? meta['IsSynced'] : null;
      final isSynced = isSyncedFlag is bool ? isSyncedFlag : lines.any((l) => l.start > 0);
      if (!isSynced) {
        final text = lines.map((l) => l.text).where((t) => t.isNotEmpty).join('\n');
        return text.isEmpty ? null : text;
      }
      return lines
          .map((l) => '${formatLrcTimestamp(l.start ~/ 10000)}${l.text}')
          .join('\n');
    } catch (_) {
      return null;
    }
  }
}

/// Emby 客户端（Jellyfin 变体，行为全部由 [JellyfinClient] 按 type 区分）。
class EmbyClient extends JellyfinClient {
  EmbyClient(super.config);
}
