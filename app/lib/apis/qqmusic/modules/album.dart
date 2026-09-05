/// QM 专辑歌曲列表（对齐 album.ts）。
library;

import '../core/config.dart';
import '../core/request.dart';
import '../core/types.dart';

Map<String, dynamic> _mapSong(Map song, {String fallbackAlbumMid = ''}) {
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
    'name': song['title'] ?? '',
    'artist': qmFormatSingerName(singer),
    'artists': singer ?? const [],
    'album': albumMap['name'] ?? '',
    'albumMid': albumMap['mid'] ?? fallbackAlbumMid,
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

QmModule qmAlbum = (params) async {
  final mid = '${params['mid'] ?? ''}';
  if (mid.isEmpty) return {'code': 400, 'message': 'mid required'};

  final data = await qmRequest<Map<String, dynamic>>(
    'music.musichallAlbum.AlbumSongList',
    'GetAlbumSongList',
    {'albumMid': mid, 'albumID': 0, 'begin': 0, 'num': 999, 'order': 2},
  );

  final list = (data['songList'] as List?) ?? const [];
  final songs = <Map<String, dynamic>>[];
  for (final entry in list.whereType<Map>()) {
    final song = entry['songInfo'];
    if (song is! Map) continue;
    final s = song;
    final songMid = s['mid'];
    if (songMid == null || '$songMid'.isEmpty) continue;
    songs.add(_mapSong(s, fallbackAlbumMid: mid));
  }
  final total = data['totalNum'];
  return {
    'code': 200,
    'mid': data['albumMid'] ?? mid,
    'total': total is num ? total.toInt() : songs.length,
    'songs': songs,
  };
};

