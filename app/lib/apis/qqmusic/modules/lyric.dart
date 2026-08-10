/// 歌词（含 QRC 逐字 / 翻译 / 罗马音，对齐 lyric.ts）
library;

import 'dart:convert';

import '../core/qrc.dart';
import '../core/request.dart';
import '../core/types.dart';

String _b64(Object? text) =>
    base64Encode(utf8.encode('${text ?? ''}'));

String? _tryDecrypt(String? hex) {
  if (hex == null || hex.isEmpty) return null;
  try {
    return qmDecryptQrc(hex);
  } catch (_) {
    return null;
  }
}

QmModule qmLyric = (params) async {
  final id = params['id'];
  final name = params['name'] ?? '';
  final artist = params['artist'] ?? '';
  final album = params['album'] ?? '';
  final duration = (params['duration'] as num?)?.toInt() ?? 0;

  final baseParam = <String, dynamic>{
    'albumName': _b64(album),
    'crypt': 1,
    'ct': 19,
    'cv': 2111,
    'interval': duration,
    'lrc_t': 0,
    'qrc': 1,
    'qrc_t': 0,
    'roma': 1,
    'roma_t': 0,
    'singerName': _b64(artist),
    'songID': id is num ? id.toInt() : int.tryParse('$id') ?? 0,
    'songName': _b64(name),
    'trans': 1,
    'trans_t': 0,
    'type': 0,
  };

  try {
    final resp = await qmRequest<Map<String, dynamic>>(
      'music.musichallSong.PlayLyricInfo',
      'GetPlayLyricInfo',
      baseParam,
    );

    final result = <String, dynamic>{'code': 200};

    // 主歌词：按 qrc_t 判断服务端返回的是 QRC 还是 LRC
    final mainDecrypted = _tryDecrypt(resp['lyric'] as String?);
    if (mainDecrypted != null) {
      if ((resp['qrc_t'] ?? 0) == 0) {
        result['lrc'] = mainDecrypted;
      } else {
        result['qrc'] = mainDecrypted;
      }
    }

    // 若只拿到 QRC，再单独请求一次 LRC 格式
    if (result['qrc'] != null && result['lrc'] == null) {
      try {
        final lrcResp = await qmRequest<Map<String, dynamic>>(
          'music.musichallSong.PlayLyricInfo',
          'GetPlayLyricInfo',
          {...baseParam, 'qrc': 0, 'qrc_t': 0},
        );
        final lrcText = _tryDecrypt(lrcResp['lyric'] as String?);
        if (lrcText != null) result['lrc'] = lrcText;
      } catch (_) {
        // 次级失败不影响主结果
      }
    }

    result['trans'] = _tryDecrypt(resp['trans'] as String?);
    result['roma'] = _tryDecrypt(resp['roma'] as String?);
    return result;
  } catch (err) {
    return {'code': 500, 'message': '$err'};
  }
};
