/// 热门评论（对齐 comment_hot.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmCommentHot = (query, request) {
  final type = query['type'] ?? 'R_SO_4_';
  final data = <String, dynamic>{
    'rid': query['id'],
    'limit': query['limit'] ?? 20,
    'offset': query['offset'] ?? 0,
    'beforeTime': query['before'] ?? 0,
  };
  return request(
    '/api/v1/resource/hotcomments/$type${query['id']}',
    data,
    nmCreateOption(query, 'weapi'),
  );
};
