/// 歌曲评论（对齐 comment_music.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmCommentMusic = (query, request) {
  final data = <String, dynamic>{
    'rid': query['id'],
    'limit': query['limit'] ?? 20,
    'offset': query['offset'] ?? 0,
    'beforeTime': query['before'] ?? 0,
  };
  return request(
    '/api/v1/resource/comments/R_SO_4_${query['id']}',
    data,
    nmCreateOption(query, 'weapi'),
  );
};
