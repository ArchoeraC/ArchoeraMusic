/// Subsonic 客户端模型（接收方）——对齐 Web 端 services/streaming/transform.ts。
///
/// 原生 Subsonic 响应节点（SubsonicSong/Album/Artist/Playlist）+ 到现有
/// UI 播放模型（netease/track.dart 的 Track）的转换。
library;

import '../netease/track.dart';
import '../streaming/streaming_models.dart';

/// 统一视图模型（StreamingAlbum/Artist/Playlist、formatLrcTimestamp 等）
/// 已归位 core/streaming，这里原样转发保持既有 import 可用。
export '../streaming/streaming_models.dart';

/// 稳定 Track.id：`${serverId}:${originalId}`。
String subsonicTrackId(String serverId, String originalId) => '$serverId:$originalId';

/// Subsonic song 节点。
class SubsonicSong {
  SubsonicSong({
    required this.id,
    required this.title,
    this.artist,
    this.album,
    this.albumId,
    this.artistId,
    this.duration,
    this.bitRate,
    this.samplingRate,
    this.bitDepth,
    this.channelCount,
    this.suffix,
    this.size,
    this.coverArt,
    this.year,
    this.artists,
    this.displayArtist,
  });

  final String id;
  final String title;
  final String? artist;
  final String? album;
  final String? albumId;
  final String? artistId;
  final int? duration;
  final int? bitRate;
  final int? samplingRate;
  final int? bitDepth;
  final int? channelCount;
  final String? suffix;
  final int? size;
  final String? coverArt;
  final int? year;

  /// OpenSubsonic 扩展：结构化多歌手数组，优先于 [artist]。
  final List<SubsonicArtistRef>? artists;

  /// OpenSubsonic 扩展：服务器选定的显示串。
  final String? displayArtist;

  factory SubsonicSong.fromJson(Map<String, dynamic> json) {
    List<SubsonicArtistRef>? refs;
    final artistsRaw = json['artists'];
    if (artistsRaw is List) {
      refs = artistsRaw
          .whereType<Map>()
          .map((e) => SubsonicArtistRef(
                id: e['id']?.toString(),
                name: e['name']?.toString() ?? '',
              ))
          .toList();
    }
    return SubsonicSong(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      artist: json['artist']?.toString(),
      album: json['album']?.toString(),
      albumId: json['albumId']?.toString(),
      artistId: json['artistId']?.toString(),
      duration: (json['duration'] as num?)?.toInt(),
      bitRate: (json['bitRate'] as num?)?.toInt(),
      samplingRate: (json['samplingRate'] as num?)?.toInt(),
      bitDepth: (json['bitDepth'] as num?)?.toInt(),
      channelCount: (json['channelCount'] as num?)?.toInt(),
      suffix: json['suffix']?.toString(),
      size: (json['size'] as num?)?.toInt(),
      coverArt: json['coverArt']?.toString(),
      year: (json['year'] as num?)?.toInt(),
      artists: refs,
      displayArtist: json['displayArtist']?.toString(),
    );
  }
}

class SubsonicArtistRef {
  SubsonicArtistRef({this.id, required this.name});
  final String? id;
  final String name;
}

/// Subsonic album 节点。
class SubsonicAlbum {
  SubsonicAlbum({
    required this.id,
    required this.name,
    this.artist,
    this.artistId,
    this.coverArt,
    this.songCount,
    this.year,
    this.song,
    this.displayArtist,
  });

  final String id;
  final String name;
  final String? artist;
  final String? artistId;
  final String? coverArt;
  final int? songCount;
  final int? year;
  final List<SubsonicSong>? song;
  final String? displayArtist;

  factory SubsonicAlbum.fromJson(Map<String, dynamic> json) => SubsonicAlbum(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        artist: json['artist']?.toString(),
        artistId: json['artistId']?.toString(),
        coverArt: json['coverArt']?.toString(),
        songCount: (json['songCount'] as num?)?.toInt(),
        year: (json['year'] as num?)?.toInt(),
        song: _songs(json['song']),
        displayArtist: json['displayArtist']?.toString(),
      );
}

/// Subsonic artist 节点。
class SubsonicArtist {
  SubsonicArtist({
    required this.id,
    required this.name,
    this.albumCount,
    this.coverArt,
  });

  final String id;
  final String name;
  final int? albumCount;
  final String? coverArt;

  factory SubsonicArtist.fromJson(Map<String, dynamic> json) => SubsonicArtist(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        albumCount: (json['albumCount'] as num?)?.toInt(),
        coverArt: json['coverArt']?.toString(),
      );
}

/// Subsonic playlist 节点。
class SubsonicPlaylist {
  SubsonicPlaylist({
    required this.id,
    required this.name,
    this.comment,
    this.songCount,
    this.coverArt,
    this.owner,
    this.entry,
  });

  final String id;
  final String name;
  final String? comment;
  final int? songCount;
  final String? coverArt;
  final String? owner;
  final List<SubsonicSong>? entry;

  factory SubsonicPlaylist.fromJson(Map<String, dynamic> json) => SubsonicPlaylist(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        comment: json['comment']?.toString(),
        songCount: (json['songCount'] as num?)?.toInt(),
        coverArt: json['coverArt']?.toString(),
        owner: json['owner']?.toString(),
        entry: _songs(json['entry']),
      );
}

List<SubsonicSong>? _songs(Object? raw) {
  if (raw is! List) return null;
  return raw
      .whereType<Map>()
      .map((e) => SubsonicSong.fromJson(e.cast<String, dynamic>()))
      .toList();
}

/* ------------------------------------------------------------------ */
/* URL 拼接（鉴权 query 由客户端注入）                                  */
/* ------------------------------------------------------------------ */

/// 拼 Subsonic coverArt URL；coverArtId 为空返回 null。
String? subsonicCoverUrl(
  String base,
  String? coverArtId,
  Map<String, String> auth, {
  int? size,
}) {
  if (coverArtId == null || coverArtId.isEmpty) return null;
  final query = Map<String, String>.from(auth)..['id'] = coverArtId;
  if (size != null) query['size'] = '$size';
  return '$base/rest/getCoverArt?${_encodeQuery(query)}';
}

/// 拼 Subsonic stream URL（format=raw 强制原文件 + maxBitRate=0 双保险）。
String subsonicStreamUrl(
  String base,
  String songId,
  Map<String, String> auth,
) {
  final query = Map<String, String>.from(auth)
    ..['id'] = songId
    ..['estimateContentLength'] = 'true'
    ..['format'] = 'raw'
    ..['maxBitRate'] = '0';
  return '$base/rest/stream?${_encodeQuery(query)}';
}

String _encodeQuery(Map<String, String> params) {
  final pairs = params.entries
      .map((e) =>
          '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
      .toList();
  return pairs.join('&');
}

/* ------------------------------------------------------------------ */
/* 转换到现有 UI 播放模型                                               */
/* ------------------------------------------------------------------ */

/// 取 Subsonic 歌曲的歌手列表。
List<TrackArtist> _resolveArtists(SubsonicSong song) {
  if (song.artists != null && song.artists!.isNotEmpty) {
    return song.artists!
        .map((a) => TrackArtist(id: a.id, name: a.name))
        .toList();
  }
  final name = (song.displayArtist ?? song.artist ?? '').trim();
  if (name.isEmpty) return const [];
  return [TrackArtist(id: song.artistId, name: name)];
}

/// Subsonic 歌曲 → 现有 [Track]（source='streaming'）。
///
/// [auth] 为当前会话的鉴权 query（含 u/t/s/v/c/f），用于拼封面 URL。
Track subsonicSongToTrack(
  String serverId,
  String base,
  SubsonicSong song,
  Map<String, String> auth,
) {
  return Track(
    id: subsonicTrackId(serverId, song.id),
    title: song.title,
    artists: _resolveArtists(song),
    album: (song.album != null && song.album!.isNotEmpty)
        ? TrackAlbum(id: song.albumId, name: song.album!)
        : null,
    duration: ((song.duration ?? 0) * 1000).clamp(0, 0x7fffffffffffffff).toInt(),
    // 列表/缩略图用 500，全屏播放器/背景用 1500 兜底原图大小
    cover: subsonicCoverUrl(base, song.coverArt, auth, size: 500),
    coverOriginal: subsonicCoverUrl(base, song.coverArt, auth, size: 1500),
    fileSize: song.size,
    quality: TrackQuality(
      sampleRate: song.samplingRate ?? 0,
      channels: song.channelCount ?? 2,
      bitsPerSample: song.bitDepth ?? 0,
      bitRate: song.bitRate != null ? song.bitRate! * 1000 : 0,
      codec: song.suffix ?? '',
    ),
    source: 'streaming',
    serverId: serverId,
    originalId: song.id,
  );
}

/// Subsonic 专辑 → 统一 [StreamingAlbum]。
StreamingAlbum subsonicAlbumToView(
  String base,
  SubsonicAlbum album,
  Map<String, String> auth,
) {
  return StreamingAlbum(
    id: album.id,
    name: album.name,
    artist: album.displayArtist ?? album.artist,
    cover: subsonicCoverUrl(base, album.coverArt, auth, size: 300),
    trackCount: album.songCount,
    year: album.year,
  );
}

/// Subsonic 歌手 → 统一 [StreamingArtist]。
StreamingArtist subsonicArtistToView(
  String base,
  SubsonicArtist artist,
  Map<String, String> auth,
) {
  return StreamingArtist(
    id: artist.id,
    name: artist.name,
    avatar: subsonicCoverUrl(base, artist.coverArt, auth, size: 300),
    albumCount: artist.albumCount,
  );
}

/// Subsonic 歌单 → 统一 [StreamingPlaylist]。
StreamingPlaylist subsonicPlaylistToView(
  String base,
  SubsonicPlaylist pl,
  Map<String, String> auth,
) {
  return StreamingPlaylist(
    id: pl.id,
    name: pl.name,
    description: pl.comment,
    cover: subsonicCoverUrl(base, pl.coverArt, auth, size: 300),
    trackCount: pl.songCount,
    owner: pl.owner,
  );
}
