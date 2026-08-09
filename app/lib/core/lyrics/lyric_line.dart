/// 歌词数据模型 + LRC 解析（§10.2 歌词流水线第一步）。
///
/// 数据源：apis 包 lyric 层（纯 Dart 直连，nmGetLyricByQuery 等）取回的原生歌词文本，
/// 本模块解析为时间轴有序行；KRC/QRC 等格式解密与解析同样在 apis 包内完成
/// （qmDecryptQrc / kgDecodeKrc，Flutter 零依赖实现）。
library;

/// 一行歌词（毫秒时间戳 + 文本）。
class LyricLine {
  const LyricLine({required this.timeMs, required this.text});

  /// 行起始时间（毫秒）。
  final int timeMs;

  /// 行文本（原文；翻译行由 [LyricGroup.translation] 承载）。
  final String text;
}

/// 增强型歌词的逐字/逐词片段（卡拉OK 高亮粒度）。
///
/// 来源：网易云 YRC（`<start,dur>字`）与酷狗 KRC（解密后同为 LX
/// 字级格式）；[startMs] 是相对**所在行起始**的偏移（毫秒）。
class LyricFragment {
  const LyricFragment({
    required this.text,
    required this.startMs,
    this.durationMs,
  });

  /// 片段文本（一个字/词）。
  final String text;

  /// 相对行起始的偏移（毫秒）。
  final int startMs;

  /// 片段时长（毫秒；仅信息展示用，不参与高亮判定）。
  final int? durationMs;
}

/// 一组歌词（原文 + 可选翻译 + 可选逐字片段，按行对齐）。
class LyricGroup {
  const LyricGroup({required this.original, this.translation, this.fragments});

  final LyricLine original;

  /// 该行翻译文本（与原文行时间对齐；无翻译为 null）。
  final String? translation;

  /// 增强型逐字片段（行内按 [LyricFragment.startMs] 升序；
  /// 普通 LRC 行为 null）。
  final List<LyricFragment>? fragments;
}

/// 解析 LRC 文本 → 时间轴有序行。
///
/// 支持 `[mm:ss.xx]` / `[mm:ss:xx]` / `[mm:ss]` 多时间标签叠加
/// （同一行多个时间戳 = 重复歌词）；忽略元数据标签（[ti:]/[ar:] 等
/// 无正文的行）与空行。
List<LyricLine> parseLrc(String lrc) {
  final lines = <LyricLine>[];
  final re = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');
  for (final raw in lrc.split('\n')) {
    final matches = re.allMatches(raw).toList();
    if (matches.isEmpty) continue;
    final text = raw.replaceAll(re, '').trim();
    if (text.isEmpty) continue;
    for (final m in matches) {
      final min = int.parse(m.group(1)!);
      final sec = int.parse(m.group(2)!);
      final fracStr = m.group(3) ?? '';
      final frac = fracStr.isEmpty
          ? 0
          : int.parse(fracStr.padRight(3, '0').substring(0, 3));
      lines.add(LyricLine(
        timeMs: min * 60000 + sec * 1000 + frac,
        text: text,
      ));
    }
  }
  lines.sort((a, b) => a.timeMs.compareTo(b.timeMs));
  return lines;
}

/// 解析主歌词（LRC / YRC / KRC 的 LX 字级格式）+ 可选翻译
/// → 时间轴有序、逐行对齐的歌词组。
///
/// - 主歌词时间戳格式同 [parseLrc]；
/// - YRC/KRC 的 `<start,dur>字` 字级标签解析为 [LyricFragment]（行内偏移）；
/// - 翻译按「时间最近」归属到主行（容差 4s，避免前奏/间隔误挂）。
List<LyricGroup> parseLyricGroups({
  required String content,
  required String format,
  String? translation,
}) {
  final reTs = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');
  final reFrag = RegExp(r'<(\d+),(\d+)>([^<\r\n]*)');

  final lines = <LyricLine>[];
  final frags = <List<LyricFragment>?>[];
  for (final raw in content.split('\n')) {
    final matches = reTs.allMatches(raw).toList();
    if (matches.isEmpty) continue;
    final body = raw.replaceAll(reTs, '');
    // 字级标签（仅 YRC/KRC 含）；无标签 = 普通 LRC 行
    final fragments = <LyricFragment>[];
    for (final fm in reFrag.allMatches(body)) {
      final text = fm.group(3)!;
      if (text.isEmpty) continue;
      fragments.add(LyricFragment(
        text: text,
        startMs: int.parse(fm.group(1)!),
        durationMs: int.parse(fm.group(2)!),
      ));
    }
    final text = fragments.isEmpty
        ? body.replaceAll(reFrag, '').trim()
        : fragments.map((f) => f.text).join().trim();
    if (text.isEmpty) continue;
    for (final m in matches) {
      final min = int.parse(m.group(1)!);
      final sec = int.parse(m.group(2)!);
      final fracStr = m.group(3) ?? '';
      final frac = fracStr.isEmpty
          ? 0
          : int.parse(fracStr.padRight(3, '0').substring(0, 3));
      lines.add(LyricLine(
        timeMs: min * 60000 + sec * 1000 + frac,
        text: text,
      ));
      frags.add(fragments.isEmpty ? null : List.of(fragments));
    }
  }
  // 按时间排序（frags 同步）
  final order = List.generate(lines.length, (i) => i)
    ..sort((a, b) => lines[a].timeMs.compareTo(lines[b].timeMs));
  final sortedLines = [for (final i in order) lines[i]];
  final sortedFrags = [for (final i in order) frags[i]];

  // 翻译对齐：每个主行挂「时间最近」的翻译行（容差内）
  final transLines = (translation == null || translation.trim().isEmpty)
      ? const <LyricLine>[]
      : parseLrc(translation);
  final transTimes = [for (final t in transLines) t.timeMs];
  String? transAt(int timeMs) {
    if (transTimes.isEmpty) return null;
    var lo = 0, hi = transTimes.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (transTimes[mid] < timeMs) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    var best = lo;
    final dCur = (timeMs - transTimes[lo]).abs();
    if (lo > 0 && (timeMs - transTimes[lo - 1]).abs() < dCur) best = lo - 1;
    if ((timeMs - transTimes[best]).abs() > 4000) return null;
    return transLines[best].text;
  }

  return [
    for (var i = 0; i < sortedLines.length; i++)
      LyricGroup(
        original: sortedLines[i],
        translation: transAt(sortedLines[i].timeMs),
        fragments: sortedFrags[i],
      ),
  ];
}

/// 由播放位置（毫秒）取当前歌词组索引；无命中返回 -1。
int lyricIndexAt(List<LyricGroup> groups, int positionMs) {
  if (groups.isEmpty) return -1;
  var lo = 0;
  var hi = groups.length - 1;
  var ans = -1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    if (groups[mid].original.timeMs <= positionMs) {
      ans = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return ans;
}
