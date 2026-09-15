// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// QM 单曲播放链接解析（对齐 song_url.ts，music.vkey.GetVkey）。
///
/// 支持 QQ 扫码凭据的直链解析及多音质降级；访客（无 cookie，
/// uin=0）也能对免费歌曲取到可播 URL（VIP/无版权曲目按接口返回语义返回
/// 403 + 提示，不做任何绕过）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../core/config.dart';
import '../core/credential.dart';
import '../core/request.dart';
import '../core/types.dart';

class _QualityCandidate {
  const _QualityCandidate(this.prefix, this.ext, this.level);

  final String prefix;
  final String ext;
  final String level;
}

/// 音质顺位（高 → 低）
///
/// 前缀对照：`RS01` 臻品音质（Hi-Res 24bit）、`AI00` 臻品母带、`Q001`/`Q000`
/// 全景声（Atmos 5.1/2.0）、`F000` 无损 FLAC、`O801` 640k OGG、`M800` 320k、
/// `M500` 128k、`C400` m4a。
/// 高解析多前缀依次降级（服务端对无权档位返回空 purl，自动跳到下一档）。
const _qqQualityTemplates = <_QualityCandidate>[
  _QualityCandidate('RS01', '.flac', 'hi-res'),
  _QualityCandidate('AI00', '.flac', 'hi-res'),
  _QualityCandidate('Q001', '.flac', 'hi-res'),
  _QualityCandidate('Q000', '.flac', 'hi-res'),
  _QualityCandidate('F000', '.flac', 'lossless'),
  _QualityCandidate('O801', '.ogg', 'hq'),
  _QualityCandidate('M800', '.mp3', 'hq'),
  _QualityCandidate('M500', '.mp3', 'sq'),
  _QualityCandidate('C400', '.m4a', 'lq'),
];

/// 根据首选音质生成顺位候选列表
List<_QualityCandidate> _qualityCandidates(String preferredLevel) {
  final target = preferredLevel.toLowerCase();
  final index = _qqQualityTemplates.indexWhere((t) => t.level == target);
  if (index >= 0) return _qqQualityTemplates.sublist(index);
  return _qqQualityTemplates;
}

String _randGuid() {
  final r = Random();
  final sb = StringBuffer();
  for (var i = 0; i < 32; i++) {
    sb.write(r.nextInt(16).toRadixString(16));
  }
  return sb.toString();
}

/// 轻量探活：拉候选 URL 前 256 字节，确认 2xx 且非文本/JSON/HTML。
/// 对齐 Mineraudio 的音频探测——避免把「HTTP 200 但其实是错误页/空体」的
/// purl 交给播放器/下载器。探测失败时回落首个非空 purl（不因探测不可靠而丢源）。
Future<bool> _probePlayable(HttpClient client, String url) async {
  try {
    final req = await client.getUrl(Uri.parse(url));
    req.headers.set('Range', 'bytes=0-255');
    req.headers.set('User-Agent', qmWebUa);
    req.headers.set('Referer', 'https://y.qq.com/');
    final res = await req.close().timeout(const Duration(seconds: 4));
    final status = res.statusCode;
    if (status != 200 && status != 206) return false;
    final mime = res.headers.contentType?.mimeType ?? '';
    if (mime.contains('text') ||
        mime.contains('json') ||
        mime.contains('xml') ||
        mime.contains('html')) {
      return false;
    }
    final bytes = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    return bytes.length >= 64;
  } catch (_) {
    return false;
  }
}

QmModule qmSongUrl = (params) async {
  final mid = '${params['mid'] ?? params['id'] ?? ''}'.trim();
  if (mid.isEmpty) return {'code': 400, 'message': 'missing mid'};

  final mediaMid = '${params['mediaMid'] ?? ''}'.trim();
  final fileBase = mediaMid.isNotEmpty ? mediaMid : '$mid$mid';

  final targetLevel = '${params['level'] ?? 'hq'}';
  final candidates = _qualityCandidates(targetLevel);
  final filenames = candidates.map((c) => '${c.prefix}$fileBase${c.ext}').toList();

  final cookies = qmGetQQMusicCookies();
  final uin = qmGetQQMusicUin();
  final musickey = cookies['qm_keyst'] ?? cookies['qqmusic_key'] ?? '';
  final loggedIn = uin != '0' && musickey.isNotEmpty;
  final cookieStr = qmSessionToCookieHeader(cookies);
  final gtk = qmHash33(musickey, 5381);
  final guid = _randGuid();

  final body = <String, dynamic>{
    'comm': <String, dynamic>{
      'uin': loggedIn ? uin : '',
      'format': 'json',
      // 登录态用桌面 ct=19（下发完整音质字段）；访客用 ct=24（对齐 Mineraudio）。
      'ct': loggedIn ? 19 : 24,
      'cv': 4747474,
      'platform': 'yqq.json',
      'chid': '0',
      'g_tk': gtk,
      'g_tk_new_20200303': gtk,
      'inCharset': 'utf-8',
      'outCharset': 'utf-8',
      'notice': 0,
      'needNewCode': 1,
      // 关键：本模块自建请求体，绕过 qmRequest，必须显式带 authst，
      // 否则登录账号被当访客，VIP / 高音质档位取不到 purl。
      if (loggedIn) 'authst': musickey,
      if (loggedIn) 'tmeLoginType': 2,
    },
    'req_0': <String, dynamic>{
      'module': 'music.vkey.GetVkey',
      'method': 'UrlGetVkey',
      'param': <String, dynamic>{
        'guid': guid,
        'songmid': filenames.map((_) => mid).toList(),
        'filename': filenames,
        'songtype': filenames.map((_) => 0).toList(),
        'uin': uin != '0' ? uin : '',
        // 对齐 Mineraudio / go-music-lib：登录标记 + 移动平台号。
        'loginflag': 1,
        'platform': '20',
        'ctx': 0,
      },
    },
  };

  final headers = <String, String>{
    'Content-Type': 'application/json',
    'Cookie': ?cookieStr,
    'Referer': 'https://y.qq.com/',
    'Origin': 'https://y.qq.com',
    'User-Agent': qmWebUa,
  };

  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final req = await client.postUrl(Uri.parse(qmApiUrl));
    headers.forEach((k, v) => req.headers.set(k, v));
    req.add(utf8.encode(jsonEncode(body)));
    final res = await req.close().timeout(const Duration(seconds: 8));
    final bytes = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    final json = jsonDecode(utf8.decode(bytes, allowMalformed: true)) as Map;

    Map<String, dynamic>? data;
    if (json['code'] == 0) {
      final req0 = json['req_0'];
      if (req0 is Map && req0['code'] == 0 && req0['data'] is Map) {
        data = Map<String, dynamic>.from(req0['data'] as Map);
      }
    }
    final infos = (data?['midurlinfo'] as List?) ?? const [];
    final sipList = data?['sip'];
    final sips = <String>[];
    if (sipList is List) {
      for (final s in sipList.whereType<String>()) {
        if (s.startsWith('http')) sips.add(s);
      }
    }
    if (sips.isEmpty) sips.add('https://isure.stream.qqmusic.qq.com/');

    // 按音质顺位找候选 purl；对每个候选 URL 探活，返回首个真正可播的。
    // 探测全部失败时回落首个非空 purl（与旧行为一致，不丢源）。
    Map<String, dynamic>? fallback;
    for (final cand in candidates) {
      final matchFilename = '${cand.prefix}$fileBase${cand.ext}';
      for (final item in infos.whereType<Map>()) {
        if (item['filename'] != matchFilename) continue;
        final purl = item['purl'];
        if (purl == null || '$purl'.isEmpty) continue;
        final purlStr = '$purl';
        final urls = purlStr.startsWith('http')
            ? <String>[purlStr]
            : sips.map((s) => '$s$purlStr').toList();
        for (final url in urls) {
          final payload = <String, dynamic>{
            'id': mid,
            'url': url,
            'level': cand.level,
            'format': cand.ext.replaceFirst('.', ''),
            'isFallback': cand.level != targetLevel,
          };
          fallback ??= payload;
          if (await _probePlayable(client, url)) {
            return <String, dynamic>{
              'code': 200,
              'data': <Map<String, dynamic>>[payload],
            };
          }
        }
      }
    }
    if (fallback != null) {
      return <String, dynamic>{
        'code': 200,
        'data': <Map<String, dynamic>>[fallback],
      };
    }
  } catch (err) {
    // 请求异常 → 统一落到下方 403（与 TS 语义一致：避免抛出细节）
  } finally {
    client.close();
  }

  return <String, dynamic>{
    'code': 403,
    'message': '无法获取播放链接，可能需要 VIP 或无版权',
    'data': <Map<String, dynamic>>[<String, dynamic>{'id': mid, 'url': ''}],
  };
};

