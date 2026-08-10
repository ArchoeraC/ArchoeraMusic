/// 单曲详情（对齐 song_info.ts）
library;

import '../core/config.dart';
import '../core/request.dart';
import '../core/types.dart';

QmModule qmSongInfo = (params) async {
  final mid = params['mid'];
  final data = await qmRequest<Map<String, dynamic>>(
    'music.pf_song_detail_svr',
    'get_song_detail_yqq',
    {'song_type': 0, 'song_mid': mid},
  );

  final track = data['track_info'];
  if (track is! Map) return {'code': 404, 'message': 'song not found'};

  final singer = track['singer'] as List?;
  final album = track['album'];
  final albumMap = album is Map ? album : const {};
  return {
    'code': 200,
    'song': {
      'id': '${track['id'] ?? ''}',
      'mid': track['mid'] ?? '',
      'name': track['title'] ?? '',
      'artist': qmFormatSingerName(singer),
      'album': albumMap['name'] ?? '',
      'albumMid': albumMap['mid'] ?? '',
      'duration': ((track['interval'] as num?) ?? 0) * 1000,
      'file': track['file'],
    },
  };
};
