/// Kugou 歌词匹配（对齐 apis/common/lyric/kugou.ts）。
///
/// 两个入口：
/// - [kgGetLyricByPlatformId] 按 hash 直取（kugou 的主键是 hash，不是数字 id；
///   单 hash 无 name/duration，服务端命中率低，建议走 getByQuery）
/// - [kgGetLyricByQuery] search → pickBestCandidate → 单次请求拿歌词
///
/// 返回只带原生格式文本（krc / lrc + 翻译 / 罗马音），不做解析，交给渲染端。
library;

import '../../services/netease/track.dart';
import '../kugou/api.dart';
import '../logger.dart';
import '../runtime.dart';
import 'fingerprint.dart';
import 'types.dart';
import 'utils.dart';

/// krc 优先，其次 lrc
({String content, String format})? _pickFormatted(String? krc, String? lrc) {
  final krcContent = krc?.trim();
  if (krcContent != null && krcContent.isNotEmpty) {
    return (content: krcContent, format: 'krc');
  }
  final lrcContent = lrc?.trim();
  if (lrcContent != null && lrcContent.isNotEmpty) {
    return (content: lrcContent, format: 'lrc');
  }
  return null;
}

/// Kugou lyric 接口强依赖 hash + name + duration 三者：
/// 只有 hash 时服务端 candidates 基本为空，必须把 name/duration 一并传过去。
Future<LyricMatchResult?> _fetchLyric({
  required String hash,
  String? name,
  int? durationMs,
}) async {
  final cached = getRuntime().lyricCache.get('kugou', hash);
  if (cached != null) return LyricMatchResult.fromJson(cached);

  try {
    final body = await kgCall('lyric', {
      'hash': hash,
      'name': name ?? '',
      'duration': durationMs != null ? (durationMs / 1000).round() : 0,
    });
    if (body is! Map) return null;
    if (body['code'] != 200) {
      coreLog.warn(
        '[lyric:kugou] fetchLyric($hash) code=${body['code']}: '
        '${body['message'] ?? 'no message'}',
      );
      return null;
    }

    final main = _pickFormatted(body['krc']?.toString(), body['lrc']?.toString());
    if (main == null) return null;

    final trans = body['trans']?.toString().trim();
    final roma = body['roma']?.toString().trim();

    final result = LyricMatchResult(
      platform: 'kugou',
      format: main.format,
      content: main.content,
      translation: (trans == null || trans.isEmpty) ? null : trans,
      translationFormat: (trans == null || trans.isEmpty) ? null : 'lrc',
      romaji: (roma == null || roma.isEmpty) ? null : roma,
      romajiFormat: (roma == null || roma.isEmpty) ? null : 'lrc',
    );
    getRuntime().lyricCache.set('kugou', hash, result.toJson());
    return result;
  } catch (err) {
    coreLog.warn('[lyric:kugou] fetchLyric($hash) failed: $err');
    return null;
  }
}

/// 按 Kugou hash 直取（只有 hash 时用；精度受限）
Future<LyricMatchResult?> kgGetLyricByPlatformId(String hash) =>
    _fetchLyric(hash: hash);

/// 按 Track 元数据模糊搜索：search → 挑最佳 → 单次请求歌词
Future<LyricMatchResult?> kgGetLyricByQuery(Track track) async {
  final fingerprint = buildFingerprint(track);
  final cached = getRuntime().lyricMatchCache.get(fingerprint, 'kugou');
  if (cached != null) {
    return _fetchLyric(
      hash: cached.platformId,
      name: track.title,
      durationMs: track.duration,
    );
  }

  final keyword = buildLyricSearchKeyword(track);
  if (keyword.isEmpty) return null;

  final candidates = <LyricCandidate<Map<String, String>>>[];
  try {
    final body = await kgCall('search', {'keywords': keyword, 'limit': 25});
    if (body is! Map || body['code'] != 200) return null;
    final songs = body['songs'] as List? ?? const [];
    for (final item in songs) {
      final song = (item as Map).cast<String, dynamic>();
      candidates.add(LyricCandidate<Map<String, String>>(
        name: song['name']?.toString() ?? '',
        artist: song['artist']?.toString() ?? '',
        album: song['album']?.toString(),
        duration: (song['duration'] as num?)?.toInt(),
        extra: {'hash': song['hash']?.toString() ?? ''},
      ));
    }
  } catch (err) {
    coreLog.warn('[lyric:kugou] search("$keyword") failed: $err');
    return null;
  }

  final best = pickBestCandidate(candidates, track);
  coreLog.info(
    '[lyric:kugou] fuzzy "$keyword" → ${candidates.length} hits, '
    'best=${best?.name ?? 'none'}',
  );
  if (best == null) return null;
  final hash = best.extra['hash'] ?? '';
  getRuntime().lyricMatchCache.set(fingerprint, 'kugou', hash);
  return _fetchLyric(hash: hash, name: best.name, durationMs: best.duration);
}
