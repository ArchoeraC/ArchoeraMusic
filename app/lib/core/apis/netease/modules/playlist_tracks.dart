/// 歌单增/删歌曲（对齐 playlist_tracks.ts，默认 eapi）
///
/// 服务端 512 表示重复/受限，按 NCM 现行实现重试时把 trackIds 翻倍以强制写入。
library;

import 'dart:convert';

import '../core/option.dart';
import '../core/request.dart';
import '../core/types.dart';

NeteaseModule nmPlaylistTracks = (query, request) async {
  final tracks = (query['tracks'] as String? ?? '').split(',');
  Map<String, dynamic> buildData(List<String> ids) => {
        'op': query['op'],
        'pid': query['pid'],
        'trackIds': jsonEncode(ids),
        'imme': 'true',
      };
  try {
    return await request(
        '/api/playlist/manipulate/tracks', buildData(tracks), nmCreateOption(query));
  } catch (err) {
    if (err is NeteaseRequestError && err.response.body['code'] == 512) {
      return request('/api/playlist/manipulate/tracks', buildData([...tracks, ...tracks]),
          nmCreateOption(query));
    }
    rethrow;
  }
};
