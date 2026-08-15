part of 'netease_api.dart';

/// 热搜词条（对齐原项目 HotSearchItem）。
class HotSearchItem {
  const HotSearchItem({
    required this.keyword,
    this.content,
    this.iconUrl,
    this.score,
  });

  final String keyword;

  /// 描述/补充（如「本周上升」）。
  final String? content;

  /// 图标 url（如品牌图标）。
  final String? iconUrl;

  /// 热度。
  final int? score;
}

/// 搜索建议-歌曲（对齐原项目 SuggestSongItem）。
class SuggestSongItem {
  const SuggestSongItem({
    required this.id,
    required this.name,
    this.artist,
    this.album,
    this.source = 'netease',
  });

  final String id;
  final String name;

  /// 多个歌手用 " / " 连接。
  final String? artist;
  final String? album;

  /// 来源平台（'netease' / 'kugou'；酷狗建议条目只有 songid，点击播放需
  /// 按其 source 分发解析——网易云用 id 直取，酷狗先经搜索补 hash）。
  final String source;
}

/// 搜索建议-简单条目（歌手 / 专辑 / 歌单，对齐原项目 SuggestSimpleItem）。
class SuggestSimpleItem {
  const SuggestSimpleItem({
    required this.id,
    required this.name,
    this.subtitle,
    this.source = 'netease',
  });

  final String id;
  final String name;
  final String? subtitle;

  /// 来源平台（'netease' / 'kugou'；酷狗专辑条目点击需按其 source 分发
  /// 到酷狗专辑详情弹窗——albumid 不能用于网易云专辑接口）。
  final String source;
}

/// 搜索建议（分类：歌曲 / 专辑 / 歌手 / 歌单）。
class SuggestData {
  const SuggestData({
    this.songs = const [],
    this.albums = const [],
    this.artists = const [],
    this.playlists = const [],
  });

  final List<SuggestSongItem> songs;
  final List<SuggestSimpleItem> albums;
  final List<SuggestSimpleItem> artists;
  final List<SuggestSimpleItem> playlists;

  bool get isEmpty =>
      songs.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty;
}

/// 搜索域（cloudsearch）：歌曲 / 专辑 / 歌手 / 歌单 + 热搜 / 建议。
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

  /// 网易云热搜（search_hot_detail；仅网易云，对齐原项目 getHotSearches，
  /// 按热度排序，过滤空关键词）。接口失败返回空列表。
  Future<List<HotSearchItem>> searchHot() async {
    final body = await _call('search_hot_detail', const {});
    final data = body?['data'];
    if (data is! List) return const [];
    return data
        .whereType<Map<String, dynamic>>()
        .where((row) => (row['searchWord']?.toString() ?? '').isNotEmpty)
        .map((row) => HotSearchItem(
              keyword: row['searchWord'].toString(),
              content: row['content']?.toString(),
              iconUrl: row['iconUrl']?.toString(),
              score: (row['score'] as num?)?.toInt(),
            ))
        .toList();
  }

  /// 网易云搜索建议（search_suggest web；对齐原项目 getSearchSuggest，
  /// 分类歌曲 / 专辑 / 歌手 / 歌单）。关键词空或失败返回空集。
  Future<SuggestData> searchSuggest(String keyword) async {
    final word = keyword.trim();
    if (word.isEmpty) return const SuggestData();
    final body = await _call('search_suggest', {'keywords': word, 'type': 'web'});
    final result = body?['result'];
    if (result is! Map<String, dynamic>) return const SuggestData();
    final songs = (result['songs'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((song) {
      final artists = (song['artists'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map((a) => a['name']?.toString() ?? '')
          .where((n) => n.isNotEmpty)
          .join(' / ');
      return SuggestSongItem(
        id: song['id'].toString(),
        name: song['name']?.toString() ?? '',
        artist: artists.isEmpty ? null : artists,
        album: song['album']?['name']?.toString(),
      );
    }).toList();
    final albums = (result['albums'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((album) => SuggestSimpleItem(
              id: album['id'].toString(),
              name: album['name']?.toString() ?? '',
              subtitle: album['artist']?['name']?.toString(),
            ))
        .toList();
    final artists = (result['artists'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((artist) => SuggestSimpleItem(
              id: artist['id'].toString(),
              name: artist['name']?.toString() ?? '',
            ))
        .toList();
    final playlists = (result['playlists'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((playlist) => SuggestSimpleItem(
              id: playlist['id'].toString(),
              name: playlist['name']?.toString() ?? '',
            ))
        .toList();
    return SuggestData(
      songs: songs,
      albums: albums,
      artists: artists,
      playlists: playlists,
    );
  }
}
