/// 订阅 / 取消订阅歌单（对齐 playlist_subscribe.ts，走 eapi）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmPlaylistSubscribe = (query, request) {
  final action = query['t'] == 2 ? 'unsubscribe' : 'subscribe';
  final data = <String, dynamic>{'id': query['id']};
  return request('/api/playlist/$action', data, nmCreateOption(query, 'eapi'));
};
