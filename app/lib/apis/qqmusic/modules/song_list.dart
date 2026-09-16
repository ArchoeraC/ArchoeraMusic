// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 歌单详情（对齐 music-lib/qq `fetchPlaylistDetail`，走 c.y.qq.com / i.y.qq.com
/// 的 fcgi GET；无需签名）。
///
/// - 主端点 `i.y.qq.com/qzone-music/...`，失败回退 `c.y.qq.com/qzone/...`；
/// - `onlysong=0` 让服务端返回歌单信息 + 曲目（`cdlist[0]`，含 `logo` 封面）；
/// - 返回可能被 `jsonCallback(...)` JSONP 包裹，统一去壳。
library;

import 'dart:convert';
import 'dart:io';

import '../core/config.dart';
import '../core/types.dart';

/// 歌单详情端点（主 + 回退，对齐 music-lib/qq）。
const _songListEndpoints = <String>[
  'https://i.y.qq.com/qzone-music/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg',
  'https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg',
];

Uri _songListUri(String endpoint, String id) => Uri.parse(endpoint).replace(
  queryParameters: <String, String>{
    'type': '1',
    'json': '1',
    'utf8': '1',
    'onlysong': '0',
    'disstid': id,
    'format': 'json',
    'g_tk': '5381',
    'loginUin': '0',
    'hostUin': '0',
    'inCharset': 'utf8',
    'outCharset': 'utf-8',
    'notice': '0',
    'platform': 'yqq',
    'needNewCode': '0',
  },
);

/// 去 JSONP 外壳（`jsonCallback({...})` / 任意 `xxx({...})`）。
Map<String, dynamic> _unwrapJsonp(String text) {
  var s = text.trim();
  final open = s.indexOf('(');
  if (open >= 0 && s.endsWith(')')) {
    s = s.substring(open + 1, s.length - 1).trim();
  }
  return jsonDecode(s) as Map<String, dynamic>;
}

QmModule qmSongList = (params) async {
  final id = '${params['id'] ?? ''}';

  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    Map<String, dynamic>? data;
    Object? lastErr;
    for (final endpoint in _songListEndpoints) {
      try {
        final req = await client.getUrl(_songListUri(endpoint, id));
        <String, String>{
          ...qmHeaders,
          'Referer': 'https://y.qq.com/',
        }.forEach((k, v) => req.headers.set(k, v));
        final res = await req.close().timeout(const Duration(seconds: 15));
        final bytes = await res.fold<List<int>>(
          <int>[],
          (a, b) => a..addAll(b),
        );
        final decoded = _unwrapJsonp(utf8.decode(bytes, allowMalformed: true));
        final cdList = decoded['cdlist'] as List?;
        if (cdList != null && cdList.isNotEmpty) {
          data = decoded;
          break;
        }
        lastErr = 'empty cdlist';
      } catch (e) {
        lastErr = e;
      }
    }
    if (data == null) {
      return {'code': 404, 'message': '歌单不存在或获取失败：$lastErr'};
    }

    final cd = (data['cdlist'] as List).first as Map;

    final songs = ((cd['songlist'] as List?) ?? const []).whereType<Map>().map((
      it,
    ) {
      final singer = it['singer'] as List?;
      final pay = it['pay'];
      final payMap = pay is Map ? pay : const <String, dynamic>{};
      final albumMid = it['albummid'] ?? it['albumMid'] ?? '';
      return <String, dynamic>{
        'id': '${it['songid'] ?? ''}',
        'mid': it['songmid'] ?? '',
        'name': it['songname'] ?? '',
        'artist': qmFormatSingerName(singer),
        'artists': singer ?? const [],
        'album': it['albumname'] ?? '',
        'albumMid': albumMid,
        'cover': albumMid.toString().isEmpty
            ? ''
            : 'https://y.gtimg.cn/music/photo_new/T002R300x300M000$albumMid.jpg',
        'coverOriginal': albumMid.toString().isEmpty
            ? ''
            : 'https://y.gtimg.cn/music/photo_new/T002R800x800M000$albumMid.jpg',
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
      'cover': qmNormalizeCover(cd['logo']?.toString()),
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
