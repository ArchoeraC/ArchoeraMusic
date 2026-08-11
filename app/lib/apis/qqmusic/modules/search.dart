/// QM 搜索（对齐 search.ts）
library;

import 'dart:math';

import '../core/config.dart';
import '../core/request.dart';
import '../core/types.dart';

/// 移动端随机 search_id
String _genSearchId() =>
    '${(Random().nextInt(20) * 18014398509481984) + (Random().nextInt(4194304) * 4294967296) + (DateTime.now().millisecondsSinceEpoch % 86400000)}';

Future<Map<String, dynamic>> _searchSongs(
    String keywords, int page, int limit) async {
  final data = await qmRequest<Map<String, dynamic>>(
    'music.search.SearchCgiService',
    'DoSearchForQQMusicMobile',
    {
      'search_id': _genSearchId(),
      'remoteplace': 'search.android.keyboard',
      'query': keywords,
      'search_type': 0,
      'num_per_page': limit,
      'page_num': page,
      'highlight': 0,
      'nqc_flag': 0,
      'multi_zhida': 0,
      'cat': 2,
      'grp': 1,
      'sin': 0,
      'sem': 0,
      'page_id': 1,
    },
  );

  final body = data['body'];
  final items = body is Map ? (body['item_song'] as List?) ?? const [] : const [];
  final songs = items.map((song) {
    final s = song as Map;
    final singer = s['singer'] as List?;
    final album = s['album'];
    final file = s['file'];
    final albumMap = album is Map ? album : const {};
    final fileMap = file is Map ? file : const {};
    return <String, dynamic>{
      'id': '${s['id'] ?? ''}',
      'mid': s['mid'] ?? '',
      'name': s['title'] ?? '',
      'artist': qmFormatSingerName(singer),
      'album': albumMap['name'] ?? '',
      'albumMid': albumMap['mid'] ?? '',
      'duration': ((s['interval'] as num?) ?? 0) * 1000,
      'mediaMid': fileMap['media_mid'] ?? '',
    };
  }).toList();

  final meta = data['meta'];
  final metaMap = meta is Map ? meta : const {};
  final total = metaMap['estimate_sum'] ?? metaMap['sum'] ?? songs.length;
  return {'code': 200, 'total': total, 'songs': songs};
}

QmModule qmSearch = (params) async {
  final keywords = params['keywords'] as String?;
  final page = (params['page'] as num?)?.toInt() ?? 1;
  final limit = (params['limit'] as num?)?.toInt() ?? 30;
  final type = (params['type'] as num?)?.toInt() ?? 0;

  if (keywords == null || keywords.isEmpty) {
    return {'code': 400, 'total': 0, 'message': 'keywords required'};
  }
  // 仅单曲；其他类型由渲染端返回空
  if (type != 0) return {'code': 200, 'total': 0};

  return _searchSongs(keywords, page, limit);
};
