/// 收藏 / 取消收藏歌手（对齐 artist_sub.ts）
/// - t: 1 收藏 / 2 取消，默认 1
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmArtistSub = (query, request) {
  final path = query['t'] == 2 ? '/api/artist/unsub' : '/api/artist/sub';
  final data = <String, dynamic>{'artistId': query['id'], 'artistIds': '[${query['id']}]'};
  return request(path, data, nmCreateOption(query, 'weapi'));
};
