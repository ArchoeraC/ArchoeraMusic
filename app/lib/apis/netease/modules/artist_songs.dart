/// 歌手全部歌曲（分页，对齐 artist_songs.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmArtistSongs = (query, request) {
  final data = <String, dynamic>{
    'id': query['id'],
    'private_cloud': 'true',
    'work_type': 1,
    'order': query['order'] ?? 'hot',
    'offset': query['offset'] ?? 0,
    'limit': query['limit'] ?? 50,
  };
  return request('/api/v1/artist/songs', data, nmCreateOption(query, 'weapi'));
};
