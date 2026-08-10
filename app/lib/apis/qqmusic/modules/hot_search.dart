/// 热搜关键词（对齐 hot_search.ts）
library;

import '../core/request.dart';
import '../core/types.dart';

QmModule qmHotSearch = (params) async {
  final data = await qmRequest<Map<String, dynamic>>(
    'tencent_musicsoso_hotkey.HotkeyService',
    'GetHotkeyForQQMusicPC',
    {'search_id': '', 'uin': 0},
  );

  final list = ((data['vec_hotkey'] as List?) ?? const []).map((item) {
    final it = item as Map;
    return <String, dynamic>{
      'keyword': it['query'] ?? it['title'] ?? '',
      'id': it['id'],
    };
  }).toList();

  return {'code': 200, 'list': list};
};
