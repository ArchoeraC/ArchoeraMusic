part of 'netease_api.dart';

/// 搜索域（cloudsearch）：歌曲 / 专辑 / 歌手 / 歌单。
mixin NeteaseSearchApi on NeteaseApiBase {
  /// cloudsearch type 编码（对齐原项目）。
  static const _typeSongs = 1;
  static const _typeAlbums = 10;
  static const _typeArtists = 100;
  static const _typePlaylists = 1000;

  /// 搜索歌曲（cloudsearch type=1）。
  Future<SearchResult<Track>> searchSongs(
    String keyword, {
    int offset = 0,
    int limit = 50,
  }) => _search(
    keyword: keyword,
    type: _typeSongs,
    offset: offset,
    limit: limit,
    countKey: 'songCount',
    parse: _parseSongs,
  );

  /// 搜索专辑（cloudsearch type=10）。
  Future<SearchResult<CoverItem>> searchAlbums(
    String keyword, {
    int offset = 0,
    int limit = 50,
  }) => _search(
    keyword: keyword,
    type: _typeAlbums,
    offset: offset,
    limit: limit,
    countKey: 'albumCount',
    parse: _parseAlbums,
  );

  /// 搜索歌手（cloudsearch type=100）。
  Future<SearchResult<CoverItem>> searchArtists(
    String keyword, {
    int offset = 0,
    int limit = 50,
  }) => _search(
    keyword: keyword,
    type: _typeArtists,
    offset: offset,
    limit: limit,
    countKey: 'artistCount',
    parse: _parseArtists,
  );

  /// 搜索歌单（cloudsearch type=1000）。
  Future<SearchResult<CoverItem>> searchPlaylists(
    String keyword, {
    int offset = 0,
    int limit = 50,
  }) => _search(
    keyword: keyword,
    type: _typePlaylists,
    offset: offset,
    limit: limit,
    countKey: 'playlistCount',
    parse: _parsePlaylists,
  );

  /// 统一 cloudsearch 调用与分页元数据（hasMore = offset + len < total）。
  Future<SearchResult<T>> _search<T>({
    required String keyword,
    required int type,
    required int offset,
    required int limit,
    required String countKey,
    required List<T> Function(Map<String, dynamic> result) parse,
  }) async {
    final body = await _call('cloudsearch', {
      'keywords': keyword,
      'type': type,
      'offset': offset,
      'limit': limit,
    });
    final result = body?['result'];
    if (result is! Map<String, dynamic>) {
      return SearchResult(items: const [], total: 0, hasMore: false);
    }
    final items = parse(result);
    final total = (result[countKey] as num?)?.toInt() ?? items.length;
    return SearchResult(
      items: items,
      total: total,
      hasMore: offset + items.length < total,
    );
  }

  /// 解析歌曲搜索结果（对齐 songsToTracks）。
  static List<Track> _parseSongs(Map<String, dynamic> result) {
    final songs = result['songs'];
    if (songs is! List) return const [];
    return songs
        .whereType<Map<String, dynamic>>()
        .map(Track.fromNeteaseSong)
        .toList();
  }

  /// 解析专辑搜索结果（对齐 albumToCover）。
  static List<CoverItem> _parseAlbums(Map<String, dynamic> result) {
    final albums = result['albums'];
    if (albums is! List) return const [];
    return albums.whereType<Map<String, dynamic>>().map((album) {
      final artists = (album['artists'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map((a) => a['name']?.toString() ?? '')
          .join(' / ');
      return CoverItem(
        id: album['id'].toString(),
        title: album['name']?.toString() ?? '',
        cover: withPicSize(album['picUrl']?.toString()),
        subtitle: artists,
        trackCount: (album['size'] as num?)?.toInt() ?? 0,
      );
    }).toList();
  }

  /// 解析歌手搜索结果（对齐 artistToCover）。
  static List<CoverItem> _parseArtists(Map<String, dynamic> result) {
    final artists = result['artists'];
    if (artists is! List) return const [];
    return artists.whereType<Map<String, dynamic>>().map((artist) {
      final pic = artist['img1v1Url'] ?? artist['picUrl'];
      return CoverItem(
        id: artist['id'].toString(),
        title: artist['name']?.toString() ?? '',
        cover: withPicSize(pic?.toString()),
        trackCount: (artist['albumSize'] as num?)?.toInt() ?? 0,
      );
    }).toList();
  }

  /// 解析歌单搜索结果（对齐 playlistToCover）。
  static List<CoverItem> _parsePlaylists(Map<String, dynamic> result) {
    final playlists = result['playlists'];
    if (playlists is! List) return const [];
    return playlists.whereType<Map<String, dynamic>>().map((playlist) {
      return CoverItem(
        id: playlist['id'].toString(),
        title: playlist['name']?.toString() ?? '',
        cover: withPicSize(playlist['coverImgUrl']?.toString()),
        subtitle: playlist['creator']?['nickname']?.toString() ?? '',
        trackCount: (playlist['trackCount'] as num?)?.toInt() ?? 0,
      );
    }).toList();
  }
}
