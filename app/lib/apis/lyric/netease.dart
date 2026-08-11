/// Netease 歌词匹配（对齐 apis/common/lyric/netease.ts）。
///
/// 两个入口：
/// - [nmGetLyricByPlatformId] 按 Netease song id 直取
/// - [nmGetLyricByQuery] search → pickBestCandidate → 单次请求拿歌词
/// - [nmGetLrcByPlatformId] / [nmGetLrcByQuery] 返回标准 LRC 文本（供 Subsonic 等场景）
///
/// 返回只带原生格式文本（yrc / lrc + 翻译 / 罗马音），不做解析，交给渲染端。
library;

import 'dart:convert';

import '../../services/netease/track.dart';
import '../logger.dart';
import '../netease/api.dart';
import '../runtime.dart';
import 'fingerprint.dart';
import 'ttml.dart';
import 'types.dart';
import 'utils.dart';

/// `{ lyric: string }` 结构取文本
String? _lyricText(Object? obj) => obj is Map ? obj['lyric']?.toString() : null;

/// ── 网易云新版 YRC 格式转换 ─────────────────────────────────────
///
/// 新版 YRC（lyric_new 近年版式，如《错位时空》艾辰版）与旧版不同：
/// - 元数据行是 JSON：`{"t":-1000,"c":[{"tx":"作词: "},{"tx":"周仁"}]}`
/// - 歌词行行级时间标签是 `[start,dur]`（毫秒），字级标签是
///   `(start,dur,flag)字`，与旧版 `<start,dur>字` 不兼容。
/// parseLyricGroups 只认 `[mm:ss.xx]` + `<start,dur>`，直接喂新版内容
/// 会整行丢弃（解析 0 行 → 歌词不显示），故在此归一化为旧版格式。

/// 新版行级标签（`[ms,dur]`，行首）
final RegExp _newYrcLineRe = RegExp(r'\[\d+,\d+\]');

/// 新版字级标签（`(start,dur,flag)text`；text 到下一个 '(' 前，可含空格）
final RegExp _newYrcFragRe = RegExp(r'\((\d+),(\d+),\d+\)([^(\r\n]*)');

/// 是否新版 YRC 格式（JSON 元数据行，或任一行 `[ms,dur]` 时间轴）
bool _isNewYrcFormat(String content) {
  final t = content.trimLeft();
  if (t.startsWith('{')) return true;
  for (final line in t.split('\n')) {
    if (_newYrcLineRe.matchAsPrefix(line.trim()) != null) return true;
  }
  return false;
}

String _fmtMs(int ms) {
  final m = ms ~/ 60000;
  final s = (ms % 60000) ~/ 1000;
  final f = ms % 1000;
  return '[$m:${s.toString().padLeft(2, '0')}.${f.toString().padLeft(3, '0')}]';
}

/// 新版 YRC → 传统 YRC（保留逐字标签，兼容 parseLyricGroups）。
/// - JSON 元数据行 → `[mm:ss.xxx]文本`（负时间戳归零）
/// - `[start,dur](start,dur,flag)字` 行 → `[mm:ss.xxx]<rel,dur>字`
///   （字级 start 转为相对行首偏移；标签间的普通文本补 `<0,0>` 保留）
/// - 其余行（标准 LRC 等）原样保留。
String convertNeteaseNewYrc(String yrc) {
  final out = StringBuffer();
  for (final raw in yrc.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;

    if (line.startsWith('{')) {
      // JSON 元数据行
      try {
        final obj = jsonDecode(line);
        final t = (obj['t'] as num?)?.toInt() ?? 0;
        final c = obj['c'];
        if (c is List && c.isNotEmpty) {
          final text = c
              .map((e) => (e is Map ? e['tx']?.toString() : null) ?? '')
              .join()
              .trim();
          if (text.isNotEmpty) out.writeln('${_fmtMs(t < 0 ? 0 : t)}$text');
        }
      } catch (_) {
        out.writeln(line); // 非 JSON（罕见）原样保留
      }
      continue;
    }

    final m = _newYrcLineRe.matchAsPrefix(line);
    if (m != null) {
      final comma = line.indexOf(',');
      final bracket = line.indexOf(']');
      final start = int.tryParse(line.substring(1, comma)) ?? 0;
      if (comma > 0 && bracket > comma) {
        final body = line.substring(bracket + 1);
        final sb = StringBuffer();
        var pos = 0;
        for (final fm in _newYrcFragRe.allMatches(body)) {
          final plain = body.substring(pos, fm.start);
          if (plain.isNotEmpty) {
            sb.write('<0,0>');
            sb.write(plain);
          }
          final rel = (int.tryParse(fm.group(1)!) ?? 0) - start;
          sb.write('<${rel < 0 ? 0 : rel},${fm.group(2)}>');
          sb.write(fm.group(3) ?? '');
          pos = fm.end;
        }
        if (pos < body.length) {
          final tail = body.substring(pos);
          if (tail.isNotEmpty) {
            sb.write('<0,0>');
            sb.write(tail);
          }
        }
        final text = sb.toString().trim();
        if (text.isNotEmpty) out.writeln('${_fmtMs(start)}$text');
      }
      continue;
    }

    out.writeln(line);
  }
  return out.toString();
}

/// 新版 YRC → 纯 LRC（剥掉字级标签；翻译/罗马音用，避免标签混入译文）。
String convertNeteaseNewYrcToLrc(String yrc) =>
    convertNeteaseNewYrc(yrc).replaceAll(RegExp(r'<[^>]*>'), '');

/// 主歌词：yrc 优先，其次 lrc（新版 yrc 自动归一化）
({String content, String format})? _pickMain(String? yrc, String? lrc) {
  final yrcContent = yrc?.trim();
  if (yrcContent != null && yrcContent.isNotEmpty) {
    return (
      content: _isNewYrcFormat(yrcContent)
          ? convertNeteaseNewYrc(yrcContent)
          : yrcContent,
      format: 'yrc',
    );
  }
  final lrcContent = lrc?.trim();
  if (lrcContent != null && lrcContent.isNotEmpty) {
    return (content: lrcContent, format: 'lrc');
  }
  return null;
}

/// 翻译 / 罗马音：`ytlrc` / `yromalrc` 时间戳更贴 YRC 行边界，优先选用
({String content, String format})? _pickSub(String? yPaired, String? plain) {
  final preferred = yPaired?.trim();
  if (preferred != null && preferred.isNotEmpty) {
    return (
      content: _isNewYrcFormat(preferred)
          ? convertNeteaseNewYrcToLrc(preferred)
          : preferred,
      format: 'lrc',
    );
  }
  final fallback = plain?.trim();
  if (fallback != null && fallback.isNotEmpty) {
    return (content: fallback, format: 'lrc');
  }
  return null;
}

/// 按 id 直取歌词
Future<LyricMatchResult?> nmGetLyricByPlatformId(String id) async {
  // 立刻预热 TTML 抓取
  prefetchTTML('netease', [id]);
  // 缓存命中直接返回
  final cached = getRuntime().lyricCache.get('netease', id);
  if (cached != null) return LyricMatchResult.fromJson(cached);

  try {
    final res = await nmCallNetease('lyric_new', {'id': id});
    if (res.status != 200 || res.body['code'] != 200) return null;
    // 主歌词：yrc > lrc
    final main = _pickMain(_lyricText(res.body['yrc']), _lyricText(res.body['lrc']));
    if (main == null) return null;
    // 翻译 / 罗马音
    final trans = _pickSub(_lyricText(res.body['ytlrc']), _lyricText(res.body['tlyric']));
    final roma = _pickSub(_lyricText(res.body['yromalrc']), _lyricText(res.body['romalrc']));
    final result = LyricMatchResult(
      platform: 'netease',
      format: main.format,
      content: main.content,
      translation: trans?.content,
      translationFormat: trans?.format,
      romaji: roma?.content,
      romajiFormat: roma?.format,
    );
    getRuntime().lyricCache.set('netease', id, result.toJson());
    return result;
  } catch (err) {
    coreLog.warn('[lyric:netease] getByPlatformId($id) failed: $err');
    return null;
  }
}

/// 按 Track 元数据模糊搜索：search → 挑最佳 → 单次请求歌词
Future<LyricMatchResult?> nmGetLyricByQuery(Track track) async {
  // 命中映射缓存：跳过 search → 直接走 byId
  final fingerprint = buildFingerprint(track);
  final cached = getRuntime().lyricMatchCache.get(fingerprint, 'netease');
  if (cached != null) return nmGetLyricByPlatformId(cached.platformId);

  final keyword = buildLyricSearchKeyword(track);
  if (keyword.isEmpty) return null;

  // 搜索 + 归一化
  final candidates = <LyricCandidate<Map<String, String>>>[];
  try {
    final res = await nmCallNetease('search', {
      'keywords': keyword,
      'type': 1,
      'limit': 20,
    });
    if (res.status != 200) return null;
    final result = res.body['result'];
    final songs = result is Map ? (result['songs'] as List? ?? const []) : const [];
    for (final item in songs) {
      final song = (item as Map).cast<String, dynamic>();
      final artists = (song['artists'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map((a) => a['name']?.toString() ?? '');
      final album = song['album'];
      candidates.add(LyricCandidate<Map<String, String>>(
        name: song['name']?.toString() ?? '',
        artist: artists.join(' / '),
        album: album is Map ? album['name']?.toString() : null,
        duration: (song['duration'] as num?)?.toInt(),
        extra: {'id': '${song['id']}'},
      ));
    }
  } catch (err) {
    coreLog.warn('[lyric:netease] search("$keyword") failed: $err');
    return null;
  }

  final best = pickBestCandidate(candidates, track);
  coreLog.info(
    '[lyric:netease] fuzzy "$keyword" → ${candidates.length} hits, '
    'best=${best?.name ?? 'none'}',
  );
  if (best == null) return null;
  getRuntime().lyricMatchCache.set(fingerprint, 'netease', best.extra['id'] ?? '');
  return nmGetLyricByPlatformId(best.extra['id'] ?? '');
}

/// 按 id 直取标准 LRC 文本（含 [mm:ss.xx] 时间戳）。
/// 供 Subsonic 等需要标准 LRC 的场景使用，避免 YRC 富文本格式。
Future<String?> nmGetLrcByPlatformId(String id) async {
  try {
    // 优先旧版 /api/song/lyric（_nmclfl:1 返回标准 LRC 文本）
    final res = await nmCallNetease('lyric', {'id': id});
    if (res.status == 200 && res.body['code'] == 200) {
      final lrc = _lyricText(res.body['lrc'])?.trim();
      if (lrc != null && lrc.isNotEmpty && lrc.startsWith('[')) return lrc;
    }
    // 回退新版 lyric_new
    final r2 = await nmCallNetease('lyric_new', {'id': id});
    if (r2.status == 200 && r2.body['code'] == 200) {
      final lrc2 = _lyricText(r2.body['lrc'])?.trim();
      if (lrc2 != null && lrc2.isNotEmpty && lrc2.startsWith('[')) return lrc2;
    }
    return null;
  } catch (err) {
    coreLog.warn('[lyric:netease] getLrcByPlatformId($id) failed: $err');
    return null;
  }
}

/// 按 Track 元数据模糊搜索并返回标准 LRC 文本。
/// 复用 [nmGetLyricByQuery] 的搜索与匹配缓存，命中后单独取 LRC 字段。
Future<String?> nmGetLrcByQuery(Track track) async {
  final fingerprint = buildFingerprint(track);
  var matchedId = getRuntime().lyricMatchCache.get(fingerprint, 'netease')?.platformId;
  if (matchedId == null || matchedId.isEmpty) {
    // 触发搜索 + 缓存 id（结果中的 YRC 此处不用）
    await nmGetLyricByQuery(track);
    matchedId = getRuntime().lyricMatchCache.get(fingerprint, 'netease')?.platformId;
  }
  if (matchedId == null || matchedId.isEmpty) return null;
  return nmGetLrcByPlatformId(matchedId);
}
