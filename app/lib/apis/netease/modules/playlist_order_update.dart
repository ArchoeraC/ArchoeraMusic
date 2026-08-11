/// 调整"我的歌单"显示顺序（对齐 playlist_order_update.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmPlaylistOrderUpdate = (query, request) {
  final data = <String, dynamic>{'ids': query['ids']};
  return request('/api/playlist/order/update', data, nmCreateOption(query, 'weapi'));
};
