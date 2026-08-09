/// 排行榜（对齐 leaderboard.ts）
library;

import '../core/config.dart';
import '../core/request.dart';
import '../core/types.dart';

QmModule qmLeaderboard = (params) async {
  final topid = params['topid'];
  final period = params['period'] ?? '';
  final limit = (params['limit'] as num?)?.toInt() ?? 50;
  final offset = (params['offset'] as num?)?.toInt() ?? 0;

  final data = await qmRequest<Map<String, dynamic>>(
    'musicToplist.ToplistInfoServer',
    'GetDetail',
    {'topid': topid, 'num': limit, 'offset': offset, 'period': period},
  );

  final list = (data['songInfoList'] as List?) ?? const [];
  final songs = list
      .map((item) {
        final song = (item as Map)['songInfo'];
        if (song is! Map) return null;
        final singer = song['singer'] as List?;
        final album = song['album'];
        final albumMap = album is Map ? album : const {};
        return <String, dynamic>{
          'id': '${song['id'] ?? ''}',
          'mid': song['mid'] ?? '',
          'name': song['title'] ?? '',
          'artist': qmFormatSingerName(singer),
          'album': albumMap['name'] ?? '',
          'albumMid': albumMap['mid'] ?? '',
          'duration': ((song['interval'] as num?) ?? 0) * 1000,
        };
      })
      .whereType<Map<String, dynamic>>()
      .toList();

  return {
    'code': 200,
    'title': data['title'] ?? '',
    'subTitle': data['titleDetail'] ?? '',
    'updateTime': data['updateTime'] ?? '',
    'cover': data['headPicUrl'] ?? '',
    'songs': songs,
  };
};
