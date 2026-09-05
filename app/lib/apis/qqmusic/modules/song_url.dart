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
const _qqQualityTemplates = <_QualityCandidate>[
  _QualityCandidate('AI00', '.flac', 'hi-res'),
  _QualityCandidate('F000', '.flac', 'lossless'),
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
  final cookieStr = qmSessionToCookieHeader(cookies);
  final gtk = qmHash33(musickey, 5381);
  final guid = _randGuid();

  final body = <String, dynamic>{
    'comm': <String, dynamic>{
      'uin': uin != '0' ? uin : '',
      'format': 'json',
      'ct': 24,
      'cv': 4747474,
      'platform': 'yqq.json',
      'chid': '0',
      'g_tk': gtk,
      'g_tk_new_20200303': gtk,
      'inCharset': 'utf-8',
      'outCharset': 'utf-8',
      'notice': 0,
      'needNewCode': 1,
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
    var sip = 'https://isure.stream.qqmusic.qq.com/';
    if (sipList is List) {
      for (final s in sipList.whereType<String>()) {
        if (s.startsWith('http')) {
          sip = s;
          break;
        }
      }
    }

    for (final cand in candidates) {
      final matchFilename = '${cand.prefix}$fileBase${cand.ext}';
      for (final item in infos.whereType<Map>()) {
        final filename = item['filename'];
        final purl = item['purl'];
        if (filename == matchFilename && purl != null && '$purl'.isNotEmpty) {
          final purlStr = '$purl';
          final url =
              purlStr.startsWith('http') ? purlStr : '$sip$purlStr';
          return <String, dynamic>{
            'code': 200,
            'data': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': mid,
                'url': url,
                'level': cand.level,
                'format': cand.ext.replaceFirst('.', ''),
                'isFallback': cand.level != targetLevel,
              },
            ],
          };
        }
      }
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

