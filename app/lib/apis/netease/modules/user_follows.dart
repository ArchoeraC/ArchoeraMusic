/// 关注列表（TA 关注的人，对齐 user_follows.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmUserFollows = (query, request) {
  final data = <String, dynamic>{
    'offset': query['offset'] ?? 0,
    'limit': query['limit'] ?? 30,
    'order': true,
  };
  return request('/api/user/getfollows/${query['uid']}', data, nmCreateOption(query, 'weapi'));
};
