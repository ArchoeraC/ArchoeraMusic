/// 听歌排行（对齐 user_record.ts；type: 1 最近一周；0 所有时间）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmUserRecord = (query, request) {
  final data = <String, dynamic>{
    'uid': query['uid'],
    'type': query['type'] ?? 0,
  };
  return request('/api/v1/play/record', data, nmCreateOption(query, 'weapi'));
};
