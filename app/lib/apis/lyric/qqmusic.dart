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
import 'fingerprint.dart';
import 'ttml.dart';
import 'types.dart';
import 'utils.dart';

/// qrc 优先，其次 lrc
({String content, String format})? _pickFormatted(String? qrc, String? lrc) {
  final qrcContent = qrc?.trim();
  if (qrcContent != null && qrcContent.isNotEmpty) {
    return (content: qrcContent, format: 'qrc');
  }
  final lrcContent = lrc?.trim();
  if (lrcContent != null && lrcContent.isNotEmpty) {
    return (content: lrcContent, format: 'lrc');
  }
  return null;
}

/// 按 QQMusic 数字 songID 直取歌词
Future<LyricMatchResult?> qmGetLyricByPlatformId(String id, [String? mid]) async {
  // 立刻预热 TTML 抓取，与本接口的 lyric 调用并行
  // AMLL DB 里 QM 条目 mid / 数字 id 都可能是 key，依次试
  prefetchTTML('qqmusic', mid != null ? [mid, id] : [id]);

  final cached = getRuntime().lyricCache.get('qqmusic', id);
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

    final main = _pickFormatted(body['qrc']?.toString(), body['lrc']?.toString());
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
      extra: mid != null ? {'mid': mid} : null,
    );
    getRuntime().lyricCache.set('qqmusic', id, result.toJson());
    return result;
  } catch (err) {
    coreLog.warn('[lyric:qqmusic] getByPlatformId($id) failed: $err');
    return null;
  }
}

/// 按 Track 元数据模糊搜索：search → 挑最佳 → 单次请求歌词
Future<LyricMatchResult?> qmGetLyricByQuery(Track track) async {
  final fingerprint = buildFingerprint(track);
  final cached = getRuntime().lyricMatchCache.get(fingerprint, 'qqmusic');
  if (cached != null) {
    return qmGetLyricByPlatformId(
      cached.platformId,
      cached.extra?['mid'] as String?,
    );
  }

  final keyword = buildLyricSearchKeyword(track);
  if (keyword.isEmpty) return null;

  final candidates = <LyricCandidate<Map<String, String>>>[];
  try {
    final body = await qmCall('search', {'keywords': keyword, 'limit': 25});
    if (body is! Map || body['code'] != 200) return null;
    final songs = body['songs'] as List? ?? const [];
    for (final item in songs) {
      final song = (item as Map).cast<String, dynamic>();
      candidates.add(LyricCandidate<Map<String, String>>(
        name: song['name']?.toString() ?? '',
        artist: song['artist']?.toString() ?? '',
        album: song['album']?.toString(),
        duration: (song['duration'] as num?)?.toInt(),
        extra: {'id': '${song['id']}', 'mid': '${song['mid'] ?? ''}'},
      ));
    }
  } catch (err) {
    coreLog.warn('[lyric:qqmusic] search("$keyword") failed: $err');
    return null;
  }

  final best = pickBestCandidate(candidates, track);
  coreLog.info(
    '[lyric:qqmusic] fuzzy "$keyword" → ${candidates.length} hits, '
    'best=${best?.name ?? 'none'}',
  );
  if (best == null) return null;
  final mid = best.extra['mid'];
  getRuntime().lyricMatchCache.set(
    fingerprint,
    'qqmusic',
    best.extra['id'] ?? '',
    mid == null || mid.isEmpty ? null : {'mid': mid},
  );
  return qmGetLyricByPlatformId(best.extra['id'] ?? '', best.extra['mid']);
}
