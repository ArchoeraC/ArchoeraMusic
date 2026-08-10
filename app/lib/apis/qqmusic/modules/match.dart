/// 模糊匹配歌词（对齐 match.ts，组合 search + lyric）
library;

import '../core/types.dart';
import 'lyric.dart';
import 'search.dart';

QmModule qmMatch = (params) async {
  final keywords = params['keywords'];

  final searched = await qmSearch({'keywords': keywords, 'page': 1, 'limit': 1});
  final songs = (searched as Map)['songs'] as List?;
  final song = songs == null || songs.isEmpty ? null : songs.first as Map;
  if (song == null) return {'code': 404, 'message': '未找到匹配的歌曲'};

  final lyricData = await qmLyric({
    'id': int.tryParse('${song['id']}') ?? 0,
    'name': song['name'],
    'artist': song['artist'],
    'album': song['album'],
    'duration': ((song['duration'] as num?) ?? 0) ~/ 1000,
  });
  final ly = lyricData as Map;
  if (ly['code'] != 200) return ly;

  return {
    'code': 200,
    'song': song,
    'lrc': ly['lrc'],
    'qrc': ly['qrc'],
    'trans': ly['trans'],
    'roma': ly['roma'],
  };
};
