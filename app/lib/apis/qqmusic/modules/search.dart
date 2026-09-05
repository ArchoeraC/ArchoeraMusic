/// QM 四分类搜索（对齐 search.ts）
library;

import 'dart:math';

import '../core/config.dart';
import '../core/request.dart';
import '../core/types.dart';

String _secureUrl(String? url) =>
    (url ?? '').replaceFirst(RegExp('^http:'), 'https:');

String _stripHighlight(String? text) =>
    (text ?? '').replaceAll(RegExp(r'</?em>'), '');

/// 移动端随机 search_id（对齐 TS：group ∈ [1,20]，r ∈ [0,4194304]）。
String _genSearchId() =>
    '${((Random().nextInt(20) + 1) * 18014398509481984) + (Random().nextInt(4194305) * 4294967296) + (DateTime.now().millisecondsSinceEpoch % 86400000)}';

/// 服务端单页硬上限：超过会被静默当作非法返回空（实测 num_per_page>50 直接
/// 空结果）；歌手搜索（search_type=1）上限更严（>30 即空，见上游 SPlayer
/// search.ts 的换算注释）。
int _capPerPage(int searchType, int limit) => searchType == 1
    ? limit.clamp(1, 30)
    : limit.clamp(1, 50);

Map<String, dynamic> _mapSong(Map song) {
  final singer = song['singer'] as List?;
  final album = song['album'];
  final file = song['file'];
  final albumMap = album is Map ? album : const <String, dynamic>{};
  final fileMap = file is Map ? file : const <String, dynamic>{};
  final pay = song['pay'];
  final payMap = pay is Map ? pay : const <String, dynamic>{};
  final payPlay = (payMap['pay_play'] as num?)?.toInt() ?? 0;
  final priceAlbum = (payMap['price_album'] as num?)?.toInt() ?? 0;
  final payMonth = (payMap['pay_month'] as num?)?.toInt() ?? 0;
  final albumMid = albumMap['mid'] ?? '';
  final albumPmid = albumMap['pmid'] ?? '';
  final pictureMid = (albumMid ?? albumPmid ?? '').toString();

  final artists = singer ?? const [];
  return <String, dynamic>{
    'id': '${song['id'] ?? ''}',
    'mid': song['mid'] ?? '',
    'name': song['title'] ?? '',
    'artist': qmFormatSingerName(singer),
    'artists': artists,
    'album': albumMap['name'] ?? albumMap['title'] ?? '',
    'albumMid': albumMid,
    'duration': ((song['interval'] as num?) ?? 0) * 1000,
    'mediaMid': fileMap['media_mid'] ?? '',
    'pay': {
      'payalbum': payMonth == 0 && priceAlbum > 0 ? 1 : 0,
      'payplay': payPlay,
    },
    'size128': _numOf(fileMap['size_128mp3']),
    'size320': _numOf(fileMap['size_320mp3']),
    'sizeApe': _numOf(fileMap['size_ape']),
    'sizeFlac': _numOf(fileMap['size_flac']),
    'sizeOgg': _numOf(fileMap['size_192ogg']),
    'sizeHiRes': (fileMap['size_new'] is List &&
            (fileMap['size_new'] as List).isNotEmpty)
        ? _numOf((fileMap['size_new'] as List).first)
        : 0,
    'hiResSampleRate': _numOf(fileMap['hires_sample']),
    'hiResBitDepth': _numOf(fileMap['hires_bitdepth']),
    'cover': pictureMid.isEmpty
        ? ''
        : 'https://y.gtimg.cn/music/photo_new/T002R300x300M000$pictureMid.jpg',
    'coverOriginal': pictureMid.isEmpty
        ? ''
        : 'https://y.gtimg.cn/music/photo_new/T002R800x800M000$pictureMid.jpg',
  };
}

int _numOf(dynamic v) => v is num ? v.toInt() : (v != null ? int.tryParse('$v') ?? 0 : 0);

Map<String, dynamic> _mapAlbum(Map album) {
  final singerList = album['singer_list'] as List?;
  return <String, dynamic>{
    'id': album['albummid'] ?? '${album['id'] ?? ''}',
    'name': album['name'] ?? '',
    'cover': _secureUrl(album['pic']?.toString()),
    'artist': album['singer'] ?? qmFormatSingerName(singerList),
    'artistMid': singerList != null && singerList.isNotEmpty
        ? (singerList.first as Map)['mid'] ?? ''
        : '',
    'trackCount': _numOf(album['song_num']),
  };
}

Map<String, dynamic> _mapArtist(Map artist) => <String, dynamic>{
  'id': artist['singerMID'] ?? '${artist['singerID'] ?? ''}',
  'name': artist['singerName'] ?? '',
  'cover': _secureUrl((artist['singerPic'] ?? artist['iconurl'])?.toString()),
  'albumCount': _numOf(artist['albumNum']),
  'songCount': _numOf(artist['songNum']),
};

Map<String, dynamic> _mapPlaylist(Map playlist) => <String, dynamic>{
  'id': playlist['dissid'] ?? '',
  'name': _stripHighlight(playlist['dissname']?.toString()),
  'cover': _secureUrl((playlist['logo'] ?? playlist['layer_url'])?.toString()),
  'creator': playlist['nickname'] ?? '',
  'trackCount': _numOf(playlist['songnum']),
  'playCount': _numOf(playlist['listennum']),
};

Future<Map<String, dynamic>> _searchMobile(
  String keywords,
  int page,
  int limit,
  int searchType,
) async {
  final data = await qmRequest<Map<String, dynamic>>(
    'music.search.SearchCgiService',
    'DoSearchForQQMusicMobile',
    {
      'searchid': _genSearchId(),
      'query': keywords,
      'page_num': page,
      'num_per_page': _capPerPage(searchType, limit),
      'search_type': searchType,
      'highlight': true,
      'grp': 1,
      'selectors': <String, dynamic>{},
      'vec_selectors': <dynamic>[],
    },
    session: false,
  );
  final body = data['body'];
  final meta = data['meta'];
  final metaMap = meta is Map ? meta : const <String, dynamic>{};
  return <String, dynamic>{'body': body is Map ? body : const {}, 'sum': metaMap['sum']};
}

Future<Map<String, dynamic>> _searchSongs(
    String keywords, int page, int limit) async {
  final resp = await _searchMobile(keywords, page, limit, 0);
  final body = resp['body'] as Map;
  final items = (body['item_song'] as List?) ?? const [];
  final songs = items.whereType<Map>().map(_mapSong).toList();
  return {'code': 200, 'total': resp['sum'] ?? songs.length, 'songs': songs};
}

Future<Map<String, dynamic>> _searchAlbums(
    String keywords, int page, int limit) async {
  final resp = await _searchMobile(keywords, page, limit, 2);
  final body = resp['body'] as Map;
  final items = (body['item_album'] as List?) ?? const [];
  final albums = items.whereType<Map>().map(_mapAlbum).toList();
  return {'code': 200, 'total': resp['sum'] ?? albums.length, 'albums': albums};
}

Future<Map<String, dynamic>> _searchArtists(
    String keywords, int page, int limit) async {
  final resp = await _searchMobile(keywords, page, limit, 1);
  final body = resp['body'] as Map;
  final items = (body['singer'] as List?) ?? const [];
  final artists = items.whereType<Map>().map(_mapArtist).toList();
  return {
    'code': 200,
    'total': resp['sum'] ?? artists.length,
    'artists': artists,
  };
}

Future<Map<String, dynamic>> _searchPlaylists(
    String keywords, int page, int limit) async {
  final resp = await _searchMobile(keywords, page, limit, 3);
  final body = resp['body'] as Map;
  final items = (body['item_songlist'] as List?) ?? const [];
  final playlists = items.whereType<Map>().map(_mapPlaylist).toList();
  return {
    'code': 200,
    'total': resp['sum'] ?? playlists.length,
    'playlists': playlists,
  };
}

/// 类型码：0 单曲 / 8 专辑 / 9 歌手 / 2 歌单（对齐 TS search.ts）。
QmModule qmSearch = (params) async {
  final keywords = params['keywords'] as String?;
  final page = (params['page'] as num?)?.toInt() ?? 1;
  final limit = (params['limit'] as num?)?.toInt() ?? 30;
  final type = (params['type'] as num?)?.toInt() ?? 0;

  if (keywords == null || keywords.isEmpty) {
    return {'code': 400, 'total': 0, 'message': 'keywords required'};
  }
  switch (type) {
    case 0:
      return _searchSongs(keywords, page, limit);
    case 8:
      return _searchAlbums(keywords, page, limit);
    case 9:
      return _searchArtists(keywords, page, limit);
    case 2:
      return _searchPlaylists(keywords, page, limit);
    default:
      return {'code': 400, 'total': 0, 'message': 'unsupported search type: $type'};
  }
};

