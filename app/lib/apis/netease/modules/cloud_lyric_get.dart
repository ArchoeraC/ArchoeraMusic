/// 云盘歌词（对齐 cloud_lyric_get.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmCloudLyricGet = (query, request) {
  final data = <String, dynamic>{
    'userId': query['uid'],
    'songId': query['sid'],
    'lv': -1,
    'kv': -1,
  };
  return request('/api/cloud/lyric/get', data, nmCreateOption(query, 'eapi'));
};
