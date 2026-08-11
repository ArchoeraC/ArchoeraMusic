/// 收藏 / 取消收藏专辑（对齐 album_sub.ts）
/// - t: 1 收藏 / 2 取消，默认 1
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmAlbumSub = (query, request) {
  final path = query['t'] == 2 ? '/api/album/sub/cancel' : '/api/album/sub';
  final data = <String, dynamic>{'id': query['id']};
  return request(path, data, nmCreateOption(query, 'weapi'));
};
