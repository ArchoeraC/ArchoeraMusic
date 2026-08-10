/// 歌单详情（对齐 song_list.ts，走 c.y.qq.com GET 接口）
library;

import 'dart:convert';
import 'dart:io';

import '../core/config.dart';
import '../core/types.dart';

const _songListUrl =
    'https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg?type=1&json=1&utf8=1&onlysonglist=0&platform=yqq&needNewCode=0';

QmModule qmSongList = (params) async {
  final id = params['id'];

  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final req = await client.getUrl(Uri.parse('$_songListUrl&disstid=$id'));
    qmHeaders.forEach((k, v) => req.headers.set(k, v));
    final res = await req.close().timeout(const Duration(seconds: 15));
    final bytes = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    final data = jsonDecode(utf8.decode(bytes, allowMalformed: true)) as Map<String, dynamic>;

    final cdList = data['cdlist'] as List?;
    final cd = cdList == null || cdList.isEmpty ? null : cdList.first as Map;
    if (cd == null) return {'code': 404, 'message': '歌单不存在'};

    final songs = ((cd['songlist'] as List?) ?? const []).map((item) {
      final it = item as Map;
      final singer = it['singer'] as List?;
      return <String, dynamic>{
        'id': '${it['songid'] ?? ''}',
        'mid': it['songmid'] ?? '',
        'name': it['songname'] ?? '',
        'artist': qmFormatSingerName(singer),
        'album': it['albumname'] ?? '',
        'albumMid': it['albummid'] ?? '',
        'duration': ((it['interval'] as num?) ?? 0) * 1000,
      };
    }).toList();

    return {
      'code': 200,
      'id': cd['disstid'],
      'name': cd['dissname'] ?? '',
      'description': cd['desc'] ?? '',
      'creator': cd['nickname'] ?? '',
      'cover': cd['logo'] ?? '',
      'playCount': cd['visitnum'] ?? 0,
      'songs': songs,
    };
  } finally {
    client.close();
  }
};
