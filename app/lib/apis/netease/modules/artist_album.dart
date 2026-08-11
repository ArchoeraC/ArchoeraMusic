/// 歌手专辑列表（对齐 artist_album.ts）
library;

import '../core/option.dart';
import '../core/types.dart';

NeteaseModule nmArtistAlbum = (query, request) {
  final data = <String, dynamic>{
    'limit': query['limit'] ?? 30,
    'offset': query['offset'] ?? 0,
    'total': true,
  };
  return request('/api/artist/albums/${query['id']}', data, nmCreateOption(query, 'weapi'));
};
