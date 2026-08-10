/// 歌词（KG，对齐 lyric.ts）
///
/// 两步流程：
/// 1. GET lyrics.kugou.com/search?keyword=&hash=&timelength= → 取第一候选 {id, accesskey, fmt}
/// 2. GET lyrics.kugou.com/download?id=&accesskey=&fmt= → base64 content
///    - fmt=krc：XOR+zlib 解密 → LRC + 逐字 KRC + 翻译 + 罗马音
///    - fmt=lrc：base64 直接 utf8 解码 → 只有 LRC
library;

import 'dart:convert';

import '../core/config.dart';
import '../core/krc.dart';
import '../core/request.dart';
import '../core/types.dart';

KgModule kgLyric = (params) async {
  final hash = params['hash'] as String?;
  if (hash == null || hash.isEmpty) return {'code': 400, 'message': 'hash required'};

  final seconds = kgIntervalToSeconds(params['duration']);

  try {
    // 第 1 步：按 hash+name+时长 查候选
    final name = '${params['name'] ?? ''}';
    final searchUrl = '$kgLyricSearchUrl?ver=1&man=yes&client=pc&lrctxt=1'
        '&keyword=${Uri.encodeComponent(name)}'
        '&hash=${Uri.encodeComponent(hash)}'
        '&timelength=$seconds';
    final searchResp = await kgRequest(searchUrl, headers: kgLyricHeaders);

    final candidates = searchResp['candidates'];
    final candidate = candidates is List && candidates.isNotEmpty
        ? (candidates.first as Map).cast<String, dynamic>()
        : null;
    if (candidate == null) return {'code': 404, 'message': 'no lyric candidate'};

    final krctype = (candidate['krctype'] as num?)?.toInt() ?? 0;
    final contenttype = (candidate['contenttype'] as num?)?.toInt() ?? 0;
    final fmt = krctype == 1 && contenttype != 1 ? 'krc' : 'lrc';

    // 第 2 步：下载 + 解码
    final downloadUrl = '$kgLyricDownloadUrl?ver=1&client=pc&charset=utf8'
        '&id=${Uri.encodeComponent('${candidate['id']}')}'
        '&accesskey=${Uri.encodeComponent('${candidate['accesskey']}')}'
        '&fmt=$fmt';
    final dl = await kgRequest(downloadUrl, headers: kgLyricHeaders);

    final dlContent = dl['content'];
    if (dlContent == null || (dlContent as String).isEmpty) {
      return {'code': 404, 'message': 'empty lyric'};
    }

    final dlFmt = dl['fmt'];
    if (dlFmt == 'krc') {
      final parsed = kgDecodeKrc(dlContent);
      return {
        'code': 200,
        'lrc': parsed.lrc,
        'krc': parsed.krc,
        'trans': parsed.trans.isNotEmpty ? parsed.trans : null,
        'roma': parsed.roma.isNotEmpty ? parsed.roma : null,
      };
    }

    if (dlFmt == 'lrc') {
      return {
        'code': 200,
        'lrc': utf8.decode(base64Decode(dlContent)),
      };
    }

    return {'code': 500, 'message': 'unknown lyric fmt: $dlFmt'};
  } catch (err) {
    return {'code': 500, 'message': '$err'};
  }
};
