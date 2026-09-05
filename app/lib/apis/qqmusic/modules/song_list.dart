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
    final req = await client.getUrl(
      Uri.parse('$_songListUrl&disstid=${Uri.encodeQueryComponent('$id')}'),
    );
    <String, String>{...qmHeaders, 'Referer': 'https://y.qq.com/'}.forEach(
      (k, v) => req.headers.set(k, v),
    );
    final res = await req.close().timeout(const Duration(seconds: 15));
    final bytes = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    // c.y.qq.com 偶发以 jsonCallback(...) JSONP 包裹返回（对齐 TS 去壳逻辑）
    final text = utf8.decode(bytes, allowMalformed: true).trim();
    final unwrapped = text
        .replaceFirst(RegExp(r'^jsonCallback\s*\('), '')
        .replaceFirst(RegExp(r'\)\s*;?\s*$'), '');
    final data = jsonDecode(unwrapped) as Map<String, dynamic>;

    final cdList = data['cdlist'] as List?;
    final cd = cdList == null || cdList.isEmpty ? null : cdList.first as Map;
    if (cd == null) return {'code': 404, 'message': '歌单不存在'};

    final songs = ((cd['songlist'] as List?) ?? const []).whereType<Map>().map((it) {
      final singer = it['singer'] as List?;
      final pay = it['pay'];
      final payMap = pay is Map ? pay : const <String, dynamic>{};
      return <String, dynamic>{
        'id': '${it['songid'] ?? ''}',
        'mid': it['songmid'] ?? '',
        'name': it['songname'] ?? '',
        'artist': qmFormatSingerName(singer),
        'artists': singer ?? const [],
        'album': it['albumname'] ?? '',
        'albumMid': it['albummid'] ?? '',
        'duration': ((it['interval'] as num?) ?? 0) * 1000,
        'mediaMid': it['strMediaMid'] ?? '',
        'pay': payMap,
        'size128': _numOf(it['size128']),
        'size320': _numOf(it['size320']),
        'sizeApe': _numOf(it['sizeape']),
        'sizeFlac': _numOf(it['sizeflac']),
        'sizeOgg': _numOf(it['sizeogg']),
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
      'total': cd['songnum'] ?? songs.length,
      'songs': songs,
    };
  } finally {
    client.close();
  }
};

int _numOf(dynamic v) =>
    v is num ? v.toInt() : (v != null ? int.tryParse('$v') ?? 0 : 0);

