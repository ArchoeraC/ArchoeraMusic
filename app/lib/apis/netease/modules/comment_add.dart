/// 发送歌曲评论（对齐 NeteaseCloudMusicApi comment.ts action=add）。
///
/// 需登录（weapi + MUSIC_U）。`threadId` 为 `R_SO_4_<songId>`；成功返回
/// `{code: 200, comment: {...}}`，重复评论返回 code 505。
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmCommentAdd = (query, request) {
  final data = <String, dynamic>{
    'threadId': 'R_SO_4_${query['id']}',
    'content': query['content'],
  };
  return request(
    '/api/v1/resource/comments/add',
    data,
    nmCreateOption(query, 'weapi'),
  );
};
