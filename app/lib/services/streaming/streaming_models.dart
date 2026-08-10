/// 流媒体统一视图模型 + Jellyfin/Emby 转换（对齐 services/streaming/transform.ts）。
library;

import '../netease/track.dart';
import '../subsonic/subsonic_local.dart';
import 'streaming_http.dart';
import 'streaming_types.dart';

/// 稳定 Track.id：`${serverId}:${originalId}`。
String streamingTrackId(String serverId, String originalId) => '$serverId:$originalId';

/// 专辑视图模型。
class StreamingAlbum {
  const StreamingAlbum({
    required this.id,
    required this.name,
    this.artist,
    this.cover,
    this.trackCount,
    this.year,
  });

  final String id;
  final String name;
  final String? artist;
  final String? cover;
  final int? trackCount;
  final int? year;
}

/// 歌手视图模型。
class StreamingArtist {
  const StreamingArtist({
    required this.id,
    required this.name,
    this.avatar,
    this.albumCount,
  });

  final String id;
  final String name;
  final String? avatar;
  final int? albumCount;
}

/// 歌单视图模型。
class StreamingPlaylist {
  const StreamingPlaylist({
    required this.id,
    required this.name,
    this.description,
    this.cover,
    this.trackCount,
    this.owner,
  });

  final String id;
  final String name;
  final String? description;
  final String? cover;
  final int? trackCount;
  final String? owner;
}

/// 搜索结果聚合。
class StreamingSearchResult {
  const StreamingSearchResult({
    required this.songs,
    required this.albums,
    required this.artists,
  });

  final List<Track> songs;
  final List<StreamingAlbum> albums;
  final List<StreamingArtist> artists;
}

/// 毫秒 → LRC 时间戳 `[mm:ss.xx]`。
String formatLrcTimestamp(int ms) {
  final safe = ms < 0 ? 0 : ms;
  final mm = safe ~/ 60000;
  final ss = (safe % 60000) ~/ 1000;
  final xx = (safe % 1000) ~/ 10;
  String pad2(int n) => n.toString().padLeft(2, '0');
  return '[${pad2(mm)}:${pad2(ss)}.${pad2(xx)}]';
}

/* ------------------------------------------------------------------ */
/* Jellyfin / Emby                                                     */
/* ------------------------------------------------------------------ */

/// Jellyfin/Emby 音频流媒体流信息。
class JellyMediaStream {
  const JellyMediaStream({this.type, this.sampleRate, this.bitDepth, this.channels, this.codec});

  final String? type;
  final int? sampleRate;
  final int? bitDepth;
  final int? channels;
  final String? codec;

  factory JellyMediaStream.fromJson(Map<String, dynamic> json) => JellyMediaStream(
        type: json['Type']?.toString(),
        sampleRate: (json['SampleRate'] as num?)?.toInt(),
        bitDepth: (json['BitDepth'] as num?)?.toInt(),
        channels: (json['Channels'] as num?)?.toInt(),
        codec: json['Codec']?.toString(),
      );
}

/// Jellyfin/Emby 媒体源（MediaSources[0]）。
class JellyMediaSource {
  const JellyMediaSource({this.container, this.bitrate, this.size, this.mediaStreams = const []});

  final String? container;
  final int? bitrate;
  final int? size;
  final List<JellyMediaStream> mediaStreams;

  factory JellyMediaSource.fromJson(Map<String, dynamic> json) {
    final raw = json['MediaStreams'];
    return JellyMediaSource(
      container: json['Container']?.toString(),
      bitrate: (json['Bitrate'] as num?)?.toInt(),
      size: (json['Size'] as num?)?.toInt(),
      mediaStreams: raw is List
          ? raw
              .whereType<Map>()
              .map((e) => JellyMediaStream.fromJson(e.cast<String, dynamic>()))
              .toList()
          : const [],
    );
  }
}

/// Jellyfin/Emby 条目（对齐 transform.ts JellyItem）。
class JellyItem {
  const JellyItem({
    required this.id,
    this.name,
    this.type,
    this.album,
    this.albumId,
    this.albumArtist,
    this.albumArtistId,
    this.artists = const [],
    this.artistItems = const [],
    this.runTimeTicks,
    this.productionYear,
    this.childCount,
    this.primaryImageTag,
    this.albumPrimaryImageTag,
    this.mediaSources = const [],
  });

  final String id;
  final String? name;
  final String? type;
  final String? album;
  final String? albumId;
  final String? albumArtist;
  final String? albumArtistId;
  final List<String> artists;
  final List<JellyArtistRef> artistItems;
  final int? runTimeTicks;
  final int? productionYear;
  final int? childCount;
  final String? primaryImageTag;
  final String? albumPrimaryImageTag;
  final List<JellyMediaSource> mediaSources;

  factory JellyItem.fromJson(Map<String, dynamic> json) {
    List<JellyArtistRef> artistItems = const [];
    final aiRaw = json['ArtistItems'];
    if (aiRaw is List) {
      artistItems = aiRaw
          .whereType<Map>()
          .map((e) => JellyArtistRef(
                id: e['Id']?.toString(),
                name: e['Name']?.toString() ?? '',
              ))
          .toList();
    }
    List<JellyMediaSource> sources = const [];
    final srcRaw = json['MediaSources'];
    if (srcRaw is List) {
      sources = srcRaw
          .whereType<Map>()
          .map((e) => JellyMediaSource.fromJson(e.cast<String, dynamic>()))
          .toList();
    }
    final tags = json['ImageTags'];
    return JellyItem(
      id: json['Id']?.toString() ?? '',
      name: json['Name']?.toString(),
      type: json['Type']?.toString(),
      album: json['Album']?.toString(),
      albumId: json['AlbumId']?.toString(),
      albumArtist: json['AlbumArtist']?.toString(),
      albumArtistId: json['AlbumArtistId']?.toString(),
      artists: json['Artists'] is List
          ? (json['Artists'] as List)
              .map((a) => a?.toString() ?? '')
              .where((s) => s.isNotEmpty)
              .toList()
          : const [],
      artistItems: artistItems,
      runTimeTicks: (json['RunTimeTicks'] as num?)?.toInt(),
      productionYear: (json['ProductionYear'] as num?)?.toInt(),
      childCount: (json['ChildCount'] as num?)?.toInt(),
      primaryImageTag: tags is Map ? tags['Primary']?.toString() : null,
      albumPrimaryImageTag: json['AlbumPrimaryImageTag']?.toString(),
      mediaSources: sources,
    );
  }
}

class JellyArtistRef {
  const JellyArtistRef({this.id, required this.name});
  final String? id;
  final String name;
}

/// Jellyfin/Emby 100ns ticks → 毫秒。
int jellyTicksToMs(int? ticks) => (ticks ?? 0) <= 0 ? 0 : ticks! ~/ 10000;

/// 拼 Jellyfin/Emby 封面图 URL；缺 accessToken 返回 null。
String? jellyImageUrl(
  StreamingServerConfig cfg,
  String itemId, {
  String? tag,
  int? maxHeight,
}) {
  final token = cfg.accessToken;
  if (token == null || token.isEmpty) return null;
  final query = <String, String>{'api_key': token};
  if (tag != null && tag.isNotEmpty) query['tag'] = tag;
  if (maxHeight != null && maxHeight > 0) query['maxHeight'] = '$maxHeight';
  return '${resolvedServerBaseUrl(cfg)}/Items/$itemId/Images/Primary?${encodeQuery(query)}';
}

T? _firstOrNull<T>(List<T> list) => list.isEmpty ? null : list.first;

/// Jellyfin/Emby 音频条目 → 统一 [Track]。
Track jellyItemToTrack(StreamingServerConfig cfg, JellyItem item) {
  final mediaSrc = _firstOrNull(item.mediaSources);
  final audioStream = _firstOrNull(
      item.mediaSources.expand((s) => s.mediaStreams).where((s) => s.type == 'Audio').toList());
  // 没有自己的 imageTag 就不显示封面，避免 fallback 到 album 时的 404 刷屏
  final imageTag = item.primaryImageTag;
  final hasImage = imageTag != null && imageTag.isNotEmpty;
  return Track(
    id: streamingTrackId(cfg.id, item.id),
    source: 'streaming',
    serverId: cfg.id,
    originalId: item.id,
    title: item.name ?? '',
    artists: item.artistItems.isNotEmpty
        ? item.artistItems.map((a) => TrackArtist(id: a.id, name: a.name)).toList()
        : item.artists.map((n) => TrackArtist(name: n)).toList(),
    album: (item.album != null && item.album!.isNotEmpty)
        ? TrackAlbum(id: item.albumId, name: item.album!)
        : null,
    duration: jellyTicksToMs(item.runTimeTicks),
    cover: hasImage ? jellyImageUrl(cfg, item.id, tag: imageTag, maxHeight: 500) : null,
    coverOriginal: hasImage ? jellyImageUrl(cfg, item.id, tag: imageTag, maxHeight: 1500) : null,
    fileSize: mediaSrc?.size,
    quality: TrackQuality(
      sampleRate: audioStream?.sampleRate ?? 0,
      channels: audioStream?.channels ?? 2,
      bitsPerSample: audioStream?.bitDepth ?? 0,
      bitRate: mediaSrc?.bitrate ?? 0,
      codec: audioStream?.codec ?? mediaSrc?.container ?? '',
    ),
  );
}

/// Jellyfin/Emby 专辑条目 → 统一 [StreamingAlbum]。
StreamingAlbum jellyItemToAlbum(StreamingServerConfig cfg, JellyItem item) => StreamingAlbum(
      id: item.id,
      name: item.name ?? '',
      artist: item.albumArtist,
      cover: jellyImageUrl(cfg, item.id, tag: item.primaryImageTag, maxHeight: 300),
      trackCount: item.childCount,
      year: item.productionYear,
    );

/// Jellyfin/Emby 歌手条目 → 统一 [StreamingArtist]。
StreamingArtist jellyItemToArtist(StreamingServerConfig cfg, JellyItem item) => StreamingArtist(
      id: item.id,
      name: item.name ?? '',
      avatar: jellyImageUrl(cfg, item.id, tag: item.primaryImageTag, maxHeight: 300),
      albumCount: item.childCount,
    );

/// Jellyfin/Emby 歌单条目 → 统一 [StreamingPlaylist]。
StreamingPlaylist jellyItemToPlaylist(StreamingServerConfig cfg, JellyItem item) =>
    StreamingPlaylist(
      id: item.id,
      name: item.name ?? '',
      cover: jellyImageUrl(cfg, item.id, tag: item.primaryImageTag, maxHeight: 300),
      trackCount: item.childCount,
    );
