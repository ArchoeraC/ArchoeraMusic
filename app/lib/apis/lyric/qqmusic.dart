// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// QQMusic 歌词匹配（对齐 apis/common/lyric/qqmusic.ts）。
///
/// 两个入口：
/// - [qmGetLyricByPlatformId] 按 QQMusic song id 直取（可选 mid 用于 AMLL TTML DB）
/// - [qmGetLyricByQuery] search → pickBestCandidate → 单次请求拿歌词
///
/// 返回只带原生格式文本（qrc / lrc + 翻译 / 罗马音），不做解析，交给渲染端。
library;

import '../../services/netease/track.dart';
import '../logger.dart';
import '../qqmusic/api.dart';
import '../runtime.dart';
import 'format.dart';
import 'match.dart';
import 'ttml.dart';
import 'types.dart';

/// 按 QQMusic 数字 songID 直取歌词
Future<LyricMatchResult?> qmGetLyricByPlatformId(
  String id, {
  String? mid,
  bool preferRich = true,
}) async {
  final cachePlatform = lyricCachePlatform('qqmusic', preferRich: preferRich);
  final midValue = (mid == null || mid.isEmpty) ? null : mid;
  // 立刻预热 TTML 抓取，与本接口的 lyric 调用并行
  // AMLL DB 里 QM 条目 mid / 数字 id 都可能是 key，依次试
  prefetchTTML('qqmusic', midValue != null ? [midValue, id] : [id]);

  final cached = getRuntime().lyricCache.get(cachePlatform, id);
  if (cached != null) return LyricMatchResult.fromJson(cached);

  try {
    final body = await qmCall('lyric', {'id': id});
    if (body is! Map) return null;
    if (body['code'] != 200) {
      coreLog.warn(
        '[lyric:qqmusic] getByPlatformId($id) code=${body['code']}: '
        '${body['message'] ?? 'no message'}',
      );
      return null;
    }

    final main = pickLyricFormat(
      [
        LyricFormatCandidate(
          content: body['qrc']?.toString(),
          format: 'qrc',
          wordByWord: true,
        ),
        LyricFormatCandidate(content: body['lrc']?.toString(), format: 'lrc'),
      ],
      preferRich: preferRich,
    );
    if (main == null) return null;

    final trans = body['trans']?.toString().trim();
    final roma = body['roma']?.toString().trim();

    final result = LyricMatchResult(
      platform: 'qqmusic',
      format: main.format,
      content: main.content,
      translation: (trans == null || trans.isEmpty) ? null : trans,
      translationFormat: (trans == null || trans.isEmpty) ? null : 'lrc',
      romaji: (roma == null || roma.isEmpty) ? null : roma,
      romajiFormat: (roma == null || roma.isEmpty) ? null : main.format,
      extra: midValue != null ? {'mid': midValue} : null,
    );
    getRuntime().lyricCache.set(cachePlatform, id, result.toJson());
    return result;
  } catch (err) {
    coreLog.warn('[lyric:qqmusic] getByPlatformId($id) failed: $err');
    return null;
  }
}

/// 按 Track 元数据模糊搜索：search → 挑最佳 → 单次请求歌词
Future<LyricMatchResult?> qmGetLyricByQuery(
  Track track, {
  bool preferRich = true,
}) {
  return fetchMatchedLyric(
    platform: 'qqmusic',
    track: track,
    idOf: (extra) => extra['id'] ?? '',
    byId: (id, extra) => qmGetLyricByPlatformId(
      id,
      mid: extra['mid'],
      preferRich: preferRich,
    ),
    search: (keyword) async {
      final candidates = <LyricCandidate<Map<String, String>>>[];
      try {
        final body = await qmCall('search', {'keywords': keyword, 'limit': 25});
        if (body is! Map || body['code'] != 200) return candidates;
        final songs = body['songs'] as List? ?? const [];
        for (final item in songs) {
          final song = (item as Map).cast<String, dynamic>();
          candidates.add(
            LyricCandidate<Map<String, String>>(
              name: song['name']?.toString() ?? '',
              artist: song['artist']?.toString() ?? '',
              album: song['album']?.toString(),
              duration: (song['duration'] as num?)?.toInt(),
              extra: {
                'id': '${song['id']}',
                'mid': '${song['mid'] ?? ''}',
              },
            ),
          );
        }
      } catch (err) {
        coreLog.warn('[lyric:qqmusic] search("$keyword") failed: $err');
      }
      return candidates;
    },
    logMatch: (keyword, hits, best) => coreLog.info(
      '[lyric:qqmusic] fuzzy "$keyword" → $hits hits, best=${best ?? 'none'}',
    ),
  );
}
