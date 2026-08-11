/// 流媒体客户端统一入口（对齐 services/streaming/index.ts）。
///
/// 按 [StreamingServerConfig.type] 分发到具体协议实现（Subsonic 家族 /
/// Jellyfin / Emby），并提供 cover URL 鉴权剥离/刷新的公共工具。
library;

import '../netease/track.dart';
import '../subsonic/subsonic_client.dart';
import '../subsonic/subsonic_local.dart';
import 'jellyfin_client.dart';
import 'streaming_models.dart';
import 'streaming_types.dart';

/// Subsonic 协议家族类型集合。
const Set<StreamingServerType> subsonicTypes = {
  StreamingServerType.subsonic,
  StreamingServerType.navidrome,
  StreamingServerType.opensubsonic,
  StreamingServerType.airsonic,
  StreamingServerType.gonic,
  StreamingServerType.lms,
};

/// 是否 Subsonic 协议家族。
bool isSubsonicType(StreamingServerType type) => subsonicTypes.contains(type);

/// Subsonic cover URL 中需剥离的鉴权参数。
const List<String> _subsonicAuthKeys = ['u', 't', 's', 'v', 'c', 'f'];

/// Jellyfin/Emby image URL 中需剥离的鉴权参数。
const String _jellyAuthKey = 'api_key';

/// 剥离 cover/image URL 中的鉴权参数（用于落盘前清洗）。
String? stripCoverAuth(String? url, StreamingServerType type) {
  if (url == null || url.isEmpty) return url;
  try {
    final u = Uri.parse(url);
    final params = Map<String, String>.from(u.queryParameters);
    if (isSubsonicType(type)) {
      for (final k in _subsonicAuthKeys) {
        params.remove(k);
      }
    } else if (type == StreamingServerType.jellyfin ||
        type == StreamingServerType.emby) {
      params.remove(_jellyAuthKey);
    }
    return u.replace(queryParameters: params).toString();
  } catch (_) {
    return url;
  }
}

/// 用当前会话凭据刷新 cover/image URL（先剥离再附上当前 token）。
///
/// Jellyfin/Emby 在未连接时（无 accessToken）只剥离不附加，连接成功后再调一次。
String? refreshCoverAuth(String? url, StreamingServerConfig cfg) {
  final stripped = stripCoverAuth(url, cfg.type);
  if (stripped == null || stripped.isEmpty) return stripped;
  if (isSubsonicType(cfg.type)) {
    return SubsonicClient(cfg).attachAuthToUrl(stripped);
  }
  if (cfg.type == StreamingServerType.jellyfin ||
      cfg.type == StreamingServerType.emby) {
    return JellyfinClient(cfg).attachAuthToUrl(stripped);
  }
  return stripped;
}

/// 是否需要 token 鉴权（Jellyfin/Emby 走 AuthenticateByName，Subsonic 系不走）。
bool needsAccessToken(StreamingServerType type) =>
    type == StreamingServerType.jellyfin || type == StreamingServerType.emby;

/// 流媒体客户端（统一入口，无状态分发）。
class StreamingClient {
  StreamingClient(this.config);

  final StreamingServerConfig config;

  SubsonicClient? get _sub =>
      isSubsonicType(config.type) ? SubsonicClient(config) : null;

  JellyfinClient? get _jelly =>
      (config.type == StreamingServerType.jellyfin ||
              config.type == StreamingServerType.emby)
          ? JellyfinClient(config)
          : null;

  UnsupportedError _unsupported() =>
      UnsupportedError('不支持的服务器类型: ${config.type.name}');

  /// Ping 服务器拿版本号。
  Future<StreamingPingResult> ping() {
    // 本机内置服务端（isArchoeraServer）协商不可用：先给明确提示，
    // 避免连接落到默认端口报笼统的网络错误。
    if (config.isArchoeraServer && SubsonicLocalServer.port == null) {
      return Future.value(StreamingPingResult(
        ok: false,
        error: '未检测到本机 ArchoeraMusic 服务端：请先启动本机内置服务端，'
            '或关闭「连接 ArchoeraMusic 服务端」开关，手动填写主机和端口',
      ));
    }
    final sub = _sub;
    if (sub != null) return sub.ping();
    final jelly = _jelly;
    if (jelly != null) return jelly.ping();
    return Future.value(
      StreamingPingResult(ok: false, error: '不支持的服务器类型: ${config.type.name}'),
    );
  }

  /// 用账号密码换 AccessToken/UserId（仅 jellyfin/emby）。
  Future<StreamingAuthResult> authenticate() {
    final jelly = _jelly;
    if (jelly != null) return jelly.authenticate();
    throw StateError('${config.type.name} 不需要 accessToken 鉴权');
  }

  /// 拉专辑列表。
  Future<List<StreamingAlbum>> listAlbums({int limit = 500, int offset = 0}) {
    final sub = _sub;
    if (sub != null) return sub.listAlbums(limit: limit, offset: offset);
    final jelly = _jelly;
    if (jelly != null) return jelly.listAlbums(limit: limit, offset: offset);
    throw _unsupported();
  }

  /// 拉歌手列表。
  Future<List<StreamingArtist>> listArtists() {
    final sub = _sub;
    if (sub != null) return sub.listArtists();
    final jelly = _jelly;
    if (jelly != null) return jelly.listArtists();
    throw _unsupported();
  }

  /// 拉歌单列表。
  Future<List<StreamingPlaylist>> listPlaylists() {
    final sub = _sub;
    if (sub != null) return sub.listPlaylists();
    final jelly = _jelly;
    if (jelly != null) return jelly.listPlaylists();
    throw _unsupported();
  }

  /// 拉歌曲列表。
  Future<List<Track>> listSongs({int limit = 100, int offset = 0}) {
    final sub = _sub;
    if (sub != null) return sub.listSongs(limit: limit, offset: offset);
    final jelly = _jelly;
    if (jelly != null) return jelly.listSongs(limit: limit, offset: offset);
    throw _unsupported();
  }

  /// 拉指定专辑的歌曲。
  Future<List<Track>> getAlbumSongs(String albumId) {
    final sub = _sub;
    if (sub != null) return sub.getAlbumSongs(albumId);
    final jelly = _jelly;
    if (jelly != null) return jelly.getAlbumSongs(albumId);
    throw _unsupported();
  }

  /// 拉指定歌单的歌曲。
  Future<List<Track>> getPlaylistSongs(String playlistId) {
    final sub = _sub;
    if (sub != null) return sub.getPlaylistSongs(playlistId);
    final jelly = _jelly;
    if (jelly != null) return jelly.getPlaylistSongs(playlistId);
    throw _unsupported();
  }

  /// 拉指定歌手名下的专辑。
  Future<List<StreamingAlbum>> getArtistAlbums(String artistId) {
    final sub = _sub;
    if (sub != null) return sub.getArtistAlbums(artistId);
    final jelly = _jelly;
    if (jelly != null) return jelly.getArtistAlbums(artistId);
    throw _unsupported();
  }

  /// 拉指定歌手名下的所有歌曲。
  Future<List<Track>> getArtistSongs(String artistId) {
    final sub = _sub;
    if (sub != null) return sub.getArtistSongs(artistId);
    final jelly = _jelly;
    if (jelly != null) return jelly.getArtistSongs(artistId);
    throw _unsupported();
  }

  /// 搜索歌曲/专辑/歌手聚合结果。
  Future<StreamingSearchResult> search(String query) {
    final sub = _sub;
    if (sub != null) return sub.search(query);
    final jelly = _jelly;
    if (jelly != null) return jelly.search(query);
    throw _unsupported();
  }

  /// 取流播放 URL；[playSessionId] 仅 jellyfin/emby 用（上层 sessionIdForTrack）。
  Future<String> getStreamUrl(String originalId, {String? playSessionId}) async {
    final sub = _sub;
    if (sub != null) return sub.getStreamUrl(originalId);
    final jelly = _jelly;
    if (jelly != null) return jelly.getStreamUrl(originalId, playSessionId: playSessionId);
    throw _unsupported();
  }

  /// 取歌词；[artist]/[title] 仅 Subsonic 旧端点回退用。
  Future<String?> getLyrics(String originalId, {String? artist, String? title}) {
    final sub = _sub;
    if (sub != null) return sub.getLyrics(originalId, artist: artist, title: title);
    final jelly = _jelly;
    if (jelly != null) return jelly.getLyrics(originalId);
    return Future.value(null);
  }
}
