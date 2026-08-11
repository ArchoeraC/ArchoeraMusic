part of 'netease_api.dart';

/// 发现 / 推荐域（主页）：推荐歌单、每日推荐、热门歌手、新碟上架。
mixin NeteaseDiscoverApi on NeteaseApiBase {
  /// 推荐歌单（personalized，无需登录，对齐原版首页「推荐歌单」）。
  Future<List<CoverItem>> personalized({int limit = 30}) async {
    final body = await _call('personalized', {'limit': limit});
    final list = body?['result'];
    if (list is! List) return const [];
    return list.whereType<Map<String, dynamic>>().map((p) {
      final creator = p['creator'];
      return CoverItem(
        id: p['id'].toString(),
        title: p['name']?.toString() ?? '',
        cover: withPicSize(p['picUrl']?.toString()),
        subtitle:
            p['copywriter']?.toString() ??
            (creator is Map<String, dynamic>
                ? creator['nickname']?.toString() ?? ''
                : ''),
        trackCount: (p['trackCount'] as num?)?.toInt() ?? 0,
      );
    }).toList();
  }

  /// 每日推荐歌曲（recommend_songs，需登录；未登录返回空）。
  Future<List<Track>> recommendSongs() async {
    final body = await _call('recommend_songs', const {});
    final songs = body?['data']?['dailySongs'];
    if (songs is! List) return const [];
    return songs
        .whereType<Map<String, dynamic>>()
        .map(Track.fromNeteaseSong)
        .toList();
  }

  /// 热门歌手（top_artists，无需登录）。
  Future<List<CoverItem>> topArtists({int limit = 12}) async {
    final body = await _call('top_artists', {'limit': limit});
    final artists = body?['artists'];
    if (artists is! List) return const [];
    return artists.whereType<Map<String, dynamic>>().map((a) {
      final pic = a['img1v1Url'] ?? a['picUrl'];
      return CoverItem(
        id: a['id'].toString(),
        title: a['name']?.toString() ?? '',
        cover: withPicSize(pic?.toString()),
        subtitle: (a['albumSize'] as num?)?.toInt() == null
            ? ''
            : '${a['albumSize']} 张专辑',
      );
    }).toList();
  }

  /// 新碟上架（album_new，无需登录）。
  Future<List<CoverItem>> newAlbums({int limit = 12}) async {
    final body = await _call('album_new', {'limit': limit});
    final raw = body?['albums'] ?? body?['data']?['albums'];
    final albums = raw is List ? raw : const [];
    return albums.whereType<Map<String, dynamic>>().map((a) {
      final artist = a['artist'] ?? a['artists'];
      final artistName = artist is Map<String, dynamic>
          ? artist['name']?.toString() ?? ''
          : artist is List &&
                artist.isNotEmpty &&
                artist.first is Map<String, dynamic>
          ? (artist.first as Map<String, dynamic>)['name']?.toString() ?? ''
          : '';
      return CoverItem(
        id: a['id'].toString(),
        title: a['name']?.toString() ?? '',
        cover: withPicSize(
          a['picUrl']?.toString() ?? a['blurPicUrl']?.toString(),
        ),
        subtitle: artistName,
        trackCount: (a['size'] as num?)?.toInt() ?? 0,
      );
    }).toList();
  }
}
