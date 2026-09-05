/// QM 歌手详情、热门歌曲与专辑（对齐 artist.ts）。
library;

import '../core/config.dart';
import '../core/request.dart';
import '../core/types.dart';

Map<String, dynamic> _mapSong(Map song) {
  final singer = song['singer'] as List?;
  final album = song['album'];
  final file = song['file'];
  final albumMap = album is Map ? album : const <String, dynamic>{};
  final fileMap = file is Map ? file : const <String, dynamic>{};
  final pay = song['pay'];
  final payMap = pay is Map ? pay : const <String, dynamic>{};
  final priceAlbum = (payMap['price_album'] as num?)?.toInt() ?? 0;
  final payMonth = (payMap['pay_month'] as num?)?.toInt() ?? 0;
  return <String, dynamic>{
    'id': '${song['id'] ?? ''}',
    'mid': song['mid'] ?? '',
    'name': song['title'] ?? song['name'] ?? '',
    'artist': qmFormatSingerName(singer),
    'artists': singer ?? const [],
    'album': albumMap['name'] ?? '',
    'albumMid': albumMap['mid'] ?? '',
    'duration': ((song['interval'] as num?) ?? 0) * 1000,
    'mediaMid': fileMap['media_mid'] ?? '',
    'pay': {
      'payalbum': payMonth == 0 && priceAlbum > 0 ? 1 : 0,
      'payplay': (payMap['pay_play'] as num?)?.toInt() ?? 0,
    },
    'size128': _numOf(fileMap['size_128mp3']),
    'size320': _numOf(fileMap['size_320mp3']),
    'sizeApe': _numOf(fileMap['size_ape']),
    'sizeFlac': _numOf(fileMap['size_flac']),
    'sizeOgg': _numOf(fileMap['size_192ogg']),
    'sizeHiRes': _firstOf(fileMap['size_new']),
    'hiResSampleRate': _numOf(fileMap['hires_sample']),
    'hiResBitDepth': _numOf(fileMap['hires_bitdepth']),
  };
}

int _numOf(dynamic v) =>
    v is num ? v.toInt() : (v != null ? int.tryParse('$v') ?? 0 : 0);

int _firstOf(dynamic list) =>
    list is List && list.isNotEmpty ? _numOf(list.first) : 0;

QmModule qmArtist = (params) async {
  final mid = '${params['mid'] ?? ''}';
  if (mid.isEmpty) return {'code': 400, 'message': 'mid required'};
  final offset = (params['offset'] as num?)?.toInt() ?? 0;
  final limit = (params['limit'] as num?)?.toInt() ?? 50;
  final includeAlbums = params['includeAlbums'] != false;

  final songsFuture = qmRequest<Map<String, dynamic>>(
    'musichall.song_list_server',
    'GetSingerSongList',
    {'singerMid': mid, 'order': 1, 'begin': offset, 'num': limit},
    session: false,
  );
  final albumsFuture = includeAlbums
      ? qmRequest<Map<String, dynamic>>(
          'music.web_singer_info_svr',
          'get_singer_album',
          {
            'singermid': mid,
            'order': 'time',
            'begin': 0,
            'num': 200,
            'exstatus': 1,
          },
          session: false,
        )
      : Future.value(<String, dynamic>{'list': const [], 'total': 0});

  final results = await Future.wait([songsFuture, albumsFuture]);
  final songsData = results[0];
  final albumsData = results[1];

  final list = (songsData['songList'] as List?) ?? const [];
  final songs = <Map<String, dynamic>>[];
  for (final entry in list.whereType<Map>()) {
    final song = entry['songInfo'];
    if (song is! Map) continue;
    if (song['mid'] == null || '${song['mid']}'.isEmpty) continue;
    songs.add(_mapSong(song));
  }

  final albumList = (albumsData['list'] as List?) ?? const [];
  final albums = albumList.whereType<Map>().map((a) => <String, dynamic>{
    'id': a['album_mid'] ?? '',
    'name': a['album_name'] ?? '',
    'artist': a['singer_name'] ?? '',
    'trackCount': _nestedCount(a),
    'publishTime': a['pub_time'],
  }).toList();

  final totalNum = songsData['totalNum'];
  final albumTotal = albumsData['total'];
  return {
    'code': 200,
    'artist': {
      'mid': songsData['singerMid'] ?? mid,
      'name': albums.isNotEmpty ? albums.first['artist'] ?? '' : '',
      'songCount': totalNum is num ? totalNum.toInt() : songs.length,
      'albumCount': albumTotal is num ? albumTotal.toInt() : albums.length,
    },
    'songs': songs,
    'albums': albums,
  };
};

int _nestedCount(Map a) {
  final latest = a['latest_song'];
  if (latest is Map) {
    final count = latest['song_count'];
    if (count is num) return count.toInt();
  }
  return 0;
}
