// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 歌词数据模型 + LRC 解析（§10.2 歌词流水线第一步）。
///
/// 数据源：apis 包 lyric 层（纯 Dart 直连，nmGetLyricByQuery 等）取回的原生歌词文本，
/// 本模块解析为时间轴有序行；KRC 解密与解码在 apis 包内完成（kgDecodeKrc），
/// QRC 解密在 apis 包内完成（qmDecryptQrc），其**逐字正文**（含 XML 外壳）
/// 由本模块 [convertQrcToYrc] 归一化（Flutter 零依赖实现）。
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
/// 来源：NT YRC（`<start,dur>字`）与KG KRC（解密后同为 LX
/// 字级格式）；[startMs] 是相对**所在行起始**的偏移（毫秒）。
class LyricFragment {
  const LyricFragment({
    required this.text,
    required this.startMs,
    this.durationMs,
    this.synthetic = false,
  });

  /// 片段文本（一个字/词）。
  final String text;

  /// 相对行起始的偏移（毫秒）。
  final int startMs;

  /// 片段时长（毫秒；仅信息展示用，不参与高亮判定）。
  final int? durationMs;

  /// 是否为按行窗口**推算**的合成片段（非源数据）。
  ///
  /// 合成片段用于让传统单行歌词也能扫亮；因其时长由估算而来，不应触发
  /// 「长音强调」脉冲（见 `resolveWordAnim`）。
  final bool synthetic;
}

/// 一组歌词（原文 + 可选翻译 + 可选逐字片段，按行对齐）。
class LyricGroup {
  const LyricGroup({
    required this.original,
    this.translation,
    this.translationFragments,
    this.romaji,
    this.romajiFragments,
    this.fragments,
    this.endMs,
    this.isBG = false,
  });

  final LyricLine original;

  /// 该行翻译文本（与原文行时间对齐；无翻译为 null）。
  final String? translation;

  /// 翻译的合成逐字片段（无逐字时间的翻译按行窗口推算，供扫亮；
  /// 与 [translation] 文本拼接一致；无翻译/未启用为 null）。
  final List<LyricFragment>? translationFragments;

  /// 该行音译（罗马音）文本（与原文行时间对齐；无音译为 null）。
  final String? romaji;

  /// 音译（罗马音）的合成逐字片段（同 [translationFragments]）。
  final List<LyricFragment>? romajiFragments;

  /// 增强型逐字片段（行内按 [LyricFragment.startMs] 升序；
  /// 普通 LRC 行为 null，或由合成器按行窗口推算）。
  final List<LyricFragment>? fragments;

  /// 行结束时间（毫秒，取下一行起始；末行由调用方/引擎用默认时长兜底）。
  /// 由解析器按有序时间轴后置计算，供 AMLL 引擎做连续滚动与逐字时长。
  final int? endMs;

  /// 背景人声行（整行被圆括号包裹，对齐 AMLL `isBG`）。
  ///
  /// 渲染为更小、更暗、挂在主行下方的一行（不单独占一个纵向槽位）。
  final bool isBG;
}

/// 解析 LRC 文本 → 时间轴有序行。
///
/// 支持 `[mm:ss.xx]` / `[mm:ss:xx]` / `[mm:ss]` 多时间标签叠加
/// （同一行多个时间戳 = 重复歌词）；忽略元数据标签（[ti:]/[ar:] 等
/// 无正文的行）与空行。
///
/// [keepEmpty] 为 true 时保留空正文行（翻译歌词常见前几行为空串
/// 占位，如 KRC 译文首行 `[00:00.000] `——丢弃会把翻译时间轴整体
/// 错位：0ms 主行错误挂上后续翻译）。默认 false（普通 LRC 跳过空行）。
List<LyricLine> parseLrc(String lrc, {bool keepEmpty = false}) {
  final lines = <LyricLine>[];
  final re = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');
  for (final raw in lrc.split('\n')) {
    final matches = re.allMatches(raw).toList();
    if (matches.isEmpty) continue;
    final text = raw.replaceAll(re, '').trim();
    if (text.isEmpty && !keepEmpty) continue;
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

/// QRC 行头：`[起始毫秒,时长毫秒]`（与本项目其它格式的正则区分：逗号分隔）。
final RegExp _qrcLineRe = RegExp(r'^\[(\d+),(\d+)\](.*)$');

/// QRC 字级时间标记：`(起始毫秒,时长毫秒)`（绝对时间，文字在前）。
final RegExp _qrcTimeRe = RegExp(r'\((\d+),(\d+)\)');

/// 毫秒 → `[m:ss.xxx]`（与 [parseLrc] 接受的 LRC 时间标签一致）。
String _fmtMsTag(int ms) {
  final safe = ms < 0 ? 0 : ms;
  final m = safe ~/ 60000;
  final s = (safe % 60000) ~/ 1000;
  final f = safe % 1000;
  return '[$m:${s.toString().padLeft(2, '0')}.${f.toString().padLeft(3, '0')}]';
}

/// 解开 QRC 的 XML 外壳（`<Lyric_1 LyricContent="..."/>`）。
///
/// 云端 QRC 响应是 XML、正文放在 `LyricContent` 属性里（内含**真实换行**）；
/// 已是纯文本则原样返回。XML 实体按常见五元组还原（`&#10;` 换行等）。
String _unwrapQrcXml(String raw) {
  final t = raw.trimLeft();
  const marker = 'LyricContent="';
  if (!t.startsWith('<') || !t.contains(marker)) return raw;
  final start = t.indexOf(marker) + marker.length;
  final end = t.lastIndexOf('"');
  if (end <= start) return raw;
  return t
      .substring(start, end)
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&#10;', '\n')
      .replaceAll('&#13;', '\r')
      .replaceAll('&amp;', '&');
}

/// 解析 QRC 单行字级内容为 (文字, 绝对起始, 时长) 序列。
///
/// QRC 正文形如 `字(start,dur)字(start,dur)...`：**文字在前、时间在后**，
/// 文本可含裸括号（仅 `(` 后紧跟数字才算时间标记）；右括号若紧跟时间标记
/// 则是正文而非配对符。逐字对齐 AMLL `parseQRC.parseWords`。
List<({String text, int start, int dur})> _parseQrcWords(String rest) {
  final words = <({String text, int start, int dur})>[];
  var pos = 0;
  while (pos < rest.length) {
    var ti = rest.indexOf('(', pos);
    while (ti != -1) {
      final hasDigit = ti + 1 < rest.length &&
          rest.codeUnitAt(ti + 1) >= 0x30 &&
          rest.codeUnitAt(ti + 1) <= 0x39;
      if (hasDigit) break;
      ti = rest.indexOf('(', ti + 1);
    }
    if (ti == -1) break;
    final m = _qrcTimeRe.matchAsPrefix(rest, ti);
    if (m == null) break;
    final start = int.parse(m.group(1)!);
    final dur = int.parse(m.group(2)!);
    // 时间标记前被跳过的裸 `(` 视为正文。
    for (var i = pos; i < ti; i++) {
      if (rest.codeUnitAt(i) == 0x28) {
        words.add((text: '(', start: start, dur: dur));
      }
    }
    final text = rest.substring(pos, ti).replaceAll('(', '');
    if (text.isNotEmpty) words.add((text: text, start: start, dur: dur));
    pos = m.end;
    if (pos < rest.length && rest.codeUnitAt(pos) == 0x29) {
      words.add((text: ')', start: start, dur: dur));
      pos++;
    }
  }
  return words;
}

/// QRC（QQ 音乐逐字）→ 传统 YRC 归一化文本。
///
/// QRC 与 YRC 的行头都是 `[起始,时长]` 毫秒，但字级为 `字(起始,时长)`
/// （**文字在前、时间为绝对值**）；归一化为 `[m:ss.xxx]<相对起始,时长>字`，
/// 后续交 [parseLyricGroups] 统一按字级标签解析。
///
/// 未识别为 QRC（无 `[毫秒,毫秒]` 行头）时返回空串，调用方可据此回退。
String convertQrcToYrc(String raw) {
  final content = _unwrapQrcXml(raw);
  final out = StringBuffer();
  for (final rawLine in content.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    final m = _qrcLineRe.firstMatch(line);
    if (m == null) continue;
    final lineStart = int.parse(m.group(1)!);
    final words = _parseQrcWords(m.group(3)!);
    if (words.isEmpty) continue;
    out.write(_fmtMsTag(lineStart));
    for (final w in words) {
      final rel = w.start - lineStart;
      out.write('<${rel < 0 ? 0 : rel},${w.dur}>');
      out.write(w.text);
    }
    out.write('\n');
  }
  return out.toString();
}

/// 内容是否为 QRC：显式 `format == 'qrc'`，或云端 XML 外壳包裹的 QRC。
bool _isQrcContent(String content, String format) {
  if (format == 'qrc') return true;
  final t = content.trimLeft();
  return t.startsWith('<') && t.contains('LyricContent="');
}

/// 解析翻译 / 音译（罗马音）行。
///
/// 子行通常已是标准 LRC，但 QQ 的罗马音同样以 QRC XML 返回（`romajiFormat`
/// 标为 qrc）；先按 QRC 归一化再走 [parseLrc]，并剥掉可能残留的字级标签
/// （`<start,dur>`），保证译文/罗马音行是纯文本。
List<LyricLine> _parseSubLines(String text, String? format) {
  if (text.trim().isEmpty) return const [];
  var t = text;
  if (_isQrcContent(t, format ?? '')) {
    final converted = convertQrcToYrc(t);
    if (converted.trim().isNotEmpty) t = converted;
  }
  final out = parseLrc(t, keepEmpty: true);
  if (!t.contains('<')) return out;
  return [
    for (final l in out)
      LyricLine(
        timeMs: l.timeMs,
        text: l.text.replaceAll(RegExp(r'<[^>]*>'), '').trim(),
      ),
  ];
}

/// 行级时间标签（LRC / YRC / KRC / QRC 归一化后统一为 `[mm:ss(.xxx)]`）。
final RegExp _reLineTs = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');

/// YRC / KRC 字级标签：`<相对行首偏移,时长>`（逗号分隔）。
final RegExp _reYrcFrag = RegExp(r'<(\d+),(\d+)>([^<\r\n]*)');

/// ESLRC 字级标签：`<mm:ss(.xxx)>字`（尖括号内是时间，冒号分隔）。
final RegExp _reEslrcFrag =
    RegExp(r'<(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?>([^<]*)');

/// `[mm:ss(.xxx)]` 时间标签匹配 → 毫秒（毫秒段右补零到 3 位）。
int _tsToMs(Match m) {
  final min = int.parse(m.group(1)!);
  final sec = int.parse(m.group(2)!);
  final fracStr = m.group(3) ?? '';
  final frac = fracStr.isEmpty
      ? 0
      : int.parse(fracStr.padRight(3, '0').substring(0, 3));
  return min * 60000 + sec * 1000 + frac;
}

/// 解析中的「词」：文本 + 绝对/相对起始。
class _Frag {
  _Frag(this.text, {this.startMs});
  final String text;
  final int? startMs;
}

/// 解析出的一行（主行或背景子行），逐字片段为相对本行 `timeMs` 的偏移。
class _LyricRow {
  _LyricRow({
    required this.timeMs,
    required this.text,
    this.fragments,
    this.isBg = false,
    this.endHint,
  });
  final int timeMs;
  String text;
  List<LyricFragment>? fragments;
  bool isBg;

  /// 行尾显式结束时间（如 ESLRC 末尾的 `<mm:ss>` 空标签）；null 表示按下一行推算。
  final int? endHint;
}

/// 解析一行原文为 0..n 个 [_LyricRow]（多时间戳 = 重复行；尾随和声另起背景行）。
///
/// 逐字来源按优先级：YRC/KRC（`<偏移,时长>`）→ ESLRC（`<mm:ss>字`）→
/// 增强 LRC（行内 `[mm:ss]字`）→ 普通整行。对齐 AMLL `parseLRC` 分支顺序。
List<_LyricRow> _parseRawLine(String raw) {
  // 行首连续时间标签 = 行时间（多标签 = 同一行重复多次）。
  final leads = <int>[];
  var textStart = 0;
  for (final m in _reLineTs.allMatches(raw)) {
    if (m.start != textStart) break;
    leads.add(_tsToMs(m));
    textStart = m.end;
  }
  if (leads.isEmpty) return const [];
  final rest = raw.substring(textStart);
  if (rest.trim().isEmpty) return const [];

  // 1) YRC / KRC：<偏移,时长>字（偏移相对行首）。
  if (_reYrcFrag.hasMatch(rest)) {
    final frags = <LyricFragment>[];
    for (final fm in _reYrcFrag.allMatches(rest)) {
      final t = fm.group(3)!;
      if (t.isEmpty) continue;
      frags.add(LyricFragment(
        text: t,
        startMs: int.parse(fm.group(1)!),
        durationMs: int.parse(fm.group(2)!),
      ));
    }
    if (frags.isNotEmpty) {
      final text = frags.map((f) => f.text).join().trim();
      if (text.isNotEmpty) return _finalizeRows(leads, text, frags);
    }
  }

  // 2) ESLRC：<mm:ss(.xxx)>字（绝对时间）；末尾空标签 = 行结束时间。
  if (_reEslrcFrag.hasMatch(rest)) {
    final matches = _reEslrcFrag.allMatches(rest).toList();
    final words = <_Frag>[];
    for (final fm in matches) {
      final t = fm.group(4)!;
      if (t.isEmpty) continue;
      words.add(_Frag(t, startMs: _tsToMs(fm)));
    }
    int? endHint;
    if (matches.isNotEmpty && matches.last.group(4)!.isEmpty) {
      endHint = _tsToMs(matches.last);
    }
    final row = _wordRows(words, endHint: endHint);
    if (row != null) return row;
  }

  // 3) 增强 LRC：行内 [mm:ss]字[mm:ss]（至少两个标签且标签间有文本）。
  final enh = _enhancedWords(raw);
  if (enh != null) {
    final row = _wordRows(enh);
    if (row != null) return row;
  }

  // 4) 普通整行（剥掉可能残留的 YRC 标签）。
  return _finalizeRows(leads, rest.replaceAll(_reYrcFrag, '').trim(), null);
}

/// 由绝对时间词序列构造行（行时间取首词起始），并做背景人声处理。
List<_LyricRow>? _wordRows(List<_Frag> words, {int? endHint}) {
  if (words.isEmpty) return null;
  final lineTime = words.first.startMs ?? 0;
  final frags = <LyricFragment>[];
  for (var i = 0; i < words.length; i++) {
    final w = words[i];
    final start = (w.startMs ?? lineTime) - lineTime;
    int? dur;
    if (i + 1 < words.length && words[i + 1].startMs != null) {
      final d = words[i + 1].startMs! - (w.startMs ?? lineTime);
      if (d > 0) dur = d;
    }
    frags.add(LyricFragment(
      text: w.text,
      startMs: start < 0 ? 0 : start,
      durationMs: dur,
    ));
  }
  final text = frags.map((f) => f.text).join().trim();
  if (text.isEmpty) return null;
  return _finalizeRows([lineTime], text, frags, endHint: endHint);
}

/// 增强 LRC 词序列：扫描行内全部 `[mm:ss]`，标签之间的文本为前一个标签开始的词。
///
/// 仅当「标签之间的词」非空才视为逐字（`[t1][t2]重复行` 这类纯多行标签仍走
/// 普通重复行分支），与 AMLL `parseLrcWords` 的 `words.length === 0` 判据一致。
List<_Frag>? _enhancedWords(String raw) {
  final ms = _reLineTs.allMatches(raw).toList();
  if (ms.length < 2) return null;
  final words = <_Frag>[];
  for (var i = 0; i + 1 < ms.length; i++) {
    final text = raw.substring(ms[i].end, ms[i + 1].start);
    if (text.isEmpty) continue;
    words.add(_Frag(text, startMs: _tsToMs(ms[i])));
  }
  if (words.isEmpty) return null;
  final tail = raw.substring(ms.last.end);
  if (tail.isNotEmpty) words.add(_Frag(tail, startMs: _tsToMs(ms.last)));
  return words;
}

/// 统一收尾：整行背景人声剥括号 + 行内尾随和声拆分为背景子行 + 按时间戳展开。
List<_LyricRow> _finalizeRows(
  List<int> leads,
  String rawText,
  List<LyricFragment>? rawFrags, {
  int? endHint,
}) {
  var text = rawText;
  var fragments = rawFrags == null ? null : List.of(rawFrags);
  final bg = isBgText(text);

  // 行内尾随和声「主歌词（和声）」→ 单独背景子行（整行括号包裹除外）。
  String? subText;
  List<LyricFragment>? subFrags;
  if (bg) {
    if (fragments == null || fragments.isEmpty) {
      text = text.substring(1, text.length - 1).trim();
    } else {
      trimBgParentheses(fragments);
      text = fragments.map((f) => f.text).join().trim();
    }
    if (text.isEmpty) return const [];
  } else {
    final split = _splitTrailingBg(text, fragments);
    if (split != null) {
      text = split.mainText;
      fragments = split.mainFrags;
      subText = split.bgText;
      subFrags = split.bgFrags;
    }
  }

  final rows = <_LyricRow>[];
  for (final t in leads) {
    rows.add(_LyricRow(
      timeMs: t,
      text: text,
      fragments: fragments == null ? null : List.of(fragments),
      isBg: bg,
      endHint: endHint,
    ));
    if (subText != null) {
      final offset =
          (subFrags != null && subFrags.isNotEmpty) ? subFrags.first.startMs : 0;
      rows.add(_LyricRow(
        timeMs: t + offset,
        text: subText,
        fragments: subFrags == null ? null : _rebaseFrags(subFrags, offset),
        isBg: true,
      ));
    }
  }
  return rows;
}

/// 逐字片段整体平移（背景子行相对主行时间的偏移）。
List<LyricFragment> _rebaseFrags(List<LyricFragment> frags, int offset) => [
  for (final f in frags)
    LyricFragment(
      text: f.text,
      startMs: f.startMs - offset,
      durationMs: f.durationMs,
      synthetic: f.synthetic,
    ),
];

/// 行内尾随和声拆分结果。
typedef _BgSplit = ({
  String mainText,
  List<LyricFragment>? mainFrags,
  String bgText,
  List<LyricFragment>? bgFrags,
});

/// 把「主歌词（和声）」拆成主行 + 尾随背景段（对齐 AMLL `splitTrailingBackground`）。
///
/// 仅当行尾以 `)`/`）` 收尾、能找到前置开括号、且开括号前仍有主歌词时拆分；
/// 日文注音「漢字（かんじ）」不拆（汉字后的假名注音）。
_BgSplit? _splitTrailingBg(String text, List<LyricFragment>? frags) {
  if (frags != null && frags.isNotEmpty) return _splitTrailingFrags(frags);
  return _splitTrailingPlain(text);
}

_BgSplit? _splitTrailingPlain(String text) {
  final t = text.trimRight();
  if (t.length < 3) return null;
  if (!_isCloseParen(t.codeUnitAt(t.length - 1))) return null;
  var open = -1;
  for (var k = t.length - 2; k >= 1; k--) {
    if (_isOpenParen(t.codeUnitAt(k))) {
      open = k;
      break;
    }
  }
  if (open <= 0) return null;
  final mainText = t.substring(0, open).trimRight();
  final bgText = t.substring(open + 1, t.length - 1).trim();
  if (mainText.isEmpty || bgText.isEmpty) return null;
  if (_isRubyTail(mainText, bgText)) return null;
  return (mainText: mainText, mainFrags: null, bgText: bgText, bgFrags: null);
}

_BgSplit? _splitTrailingFrags(List<LyricFragment> frags) {
  final joined = frags.map((f) => f.text).join();
  final trimmed = joined.trimRight();
  if (trimmed.length < 3) return null;
  if (!_isCloseParen(trimmed.codeUnitAt(trimmed.length - 1))) return null;
  // 从第 2 个片段起找「以开括号开头」的片段作为背景段起点（需保留主歌词）。
  var bi = -1;
  for (var i = 1; i < frags.length; i++) {
    final lead = frags[i].text.length - frags[i].text.trimLeft().length;
    final s = frags[i].text.substring(lead);
    if (s.isNotEmpty && _isOpenParen(s.codeUnitAt(0))) {
      bi = i;
      break;
    }
  }
  if (bi <= 0) return null;

  final mainFrags = [for (var i = 0; i < bi; i++) frags[i]];
  final bgFrags = [for (var i = bi; i < frags.length; i++) frags[i]];

  // 剥掉背景段首片段的「前导空白 + 一个开括号」。
  final f0 = bgFrags.first;
  final lead = f0.text.length - f0.text.trimLeft().length;
  var t0 = f0.text.substring(lead);
  if (t0.isNotEmpty && _isOpenParen(t0.codeUnitAt(0))) t0 = t0.substring(1);
  bgFrags[0] = LyricFragment(
    text: t0,
    startMs: f0.startMs,
    durationMs: f0.durationMs,
  );
  // 剥掉背景段末片段的「一个闭括号 + 尾随空白」。
  final li = bgFrags.length - 1;
  final fl = bgFrags[li];
  var tl = fl.text.trimRight();
  if (tl.isNotEmpty && _isCloseParen(tl.codeUnitAt(tl.length - 1))) {
    tl = tl.substring(0, tl.length - 1);
  }
  bgFrags[li] = LyricFragment(
    text: tl,
    startMs: fl.startMs,
    durationMs: fl.durationMs,
  );
  bgFrags.removeWhere((f) => f.text.isEmpty);
  if (bgFrags.isEmpty) return null;

  final mainText = mainFrags.map((f) => f.text).join().trim();
  final bgText = bgFrags.map((f) => f.text).join().trim();
  if (mainText.isEmpty || bgText.isEmpty) return null;
  if (_isRubyTail(mainText, bgText)) return null;
  return (
    mainText: mainText,
    mainFrags: mainFrags,
    bgText: bgText,
    bgFrags: bgFrags,
  );
}

bool _isOpenParen(int c) => c == 0x28 || c == 0xFF08; // ( （
bool _isCloseParen(int c) => c == 0x29 || c == 0xFF09; // ) ）

/// 是否为日文汉字后的假名注音：前字为汉字且括号内仅假名 / 长音符 / 空白。
bool _isRubyTail(String mainText, String inner) {
  if (mainText.isEmpty || inner.isEmpty) return false;
  if (!_isHan(mainText.runes.last)) return false;
  for (final r in inner.runes) {
    if (r == 0x20 || r == 0x09 || r == 0x30FC) continue;
    if ((r >= 0x3040 && r <= 0x30FF) || (r >= 0x31F0 && r <= 0x31FF)) continue;
    return false;
  }
  return true;
}

bool _isHan(int r) =>
    (r >= 0x4E00 && r <= 0x9FFF) ||
    (r >= 0x3400 && r <= 0x4DBF) ||
    (r >= 0xF900 && r <= 0xFAFF);

/// 解析主歌词（LRC / YRC / KRC / QRC / ESLRC / 增强 LRC）+ 可选翻译
/// → 时间轴有序、逐行对齐的歌词组。
///
/// - 行级时间戳格式同 [parseLrc]；多时间戳 = 重复行；
/// - QRC 先经 [convertQrcToYrc] 归一化（兼容历史缓存里的未解包 XML）；
/// - YRC/KRC 的 `<偏移,时长>字`、ESLRC 的 `<mm:ss>字`、增强 LRC 的行内
///   `[mm:ss]字` 都解析为 [LyricFragment]（行内相对偏移）；
/// - 行内尾随和声「主歌词（和声）」拆为紧随的背景行（对齐 AMLL）；
/// - 翻译 / 音译（罗马音）按各自 [translationFormat] / [romajiFormat]
///   解析（QQ 罗马音为 QRC），再按「时间最近」归属到主行（容差 4s）。
List<LyricGroup> parseLyricGroups({
  required String content,
  required String format,
  String? translation,
  String? translationFormat,
  String? romaji,
  String? romajiFormat,
}) {
  // QRC 归一化：format 标记为 qrc，或内容带 XML 外壳（旧缓存未解包）。
  // 归一化无产出时保留原文，避免把「误标 qrc 的普通歌词」整首吞掉。
  var main = content;
  if (_isQrcContent(content, format)) {
    final converted = convertQrcToYrc(content);
    if (converted.trim().isNotEmpty) main = converted;
  }

  final rows = <_LyricRow>[];
  for (final raw in main.split('\n')) {
    rows.addAll(_parseRawLine(raw));
  }
  // 稳定排序：时间相同保持文档顺序（主行在前、背景子行紧随其后）。
  final order = List.generate(rows.length, (i) => i)
    ..sort((a, b) {
      final c = rows[a].timeMs.compareTo(rows[b].timeMs);
      return c != 0 ? c : a.compareTo(b);
    });
  final sorted = [for (final i in order) rows[i]];

  // 翻译对齐：每个主行挂「时间最近」的翻译行（容差内）
  // 翻译保留空正文行（keepEmpty）：KRC 译文首行常为空串占位，若丢弃
  // 会让翻译时间轴错位——0ms 主行会错误挂上后续真实翻译（如《登神》
  // 首行"NewJeans - 登神 (GODS)"错挂 1263ms 的"长阶"）。
  final transLines = _parseSubLines(translation ?? '', translationFormat);
  final transTimes = [for (final t in transLines) t.timeMs];
  final romaLines = _parseSubLines(romaji ?? '', romajiFormat);
  final romaTimes = [for (final t in romaLines) t.timeMs];

  /// 取与 [timeMs] 最近的行文本（容差 4s；空文本视为无内容）。
  String? nearestAt(List<LyricLine> lines, List<int> times, int timeMs) {
    if (times.isEmpty) return null;
    var lo = 0, hi = times.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (times[mid] < timeMs) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    var best = lo;
    final dCur = (timeMs - times[lo]).abs();
    if (lo > 0 && (timeMs - times[lo - 1]).abs() < dCur) best = lo - 1;
    if ((timeMs - times[best]).abs() > 4000) return null;
    // 空文本视为无内容（空串渲染会占行高）
    final t = lines[best].text;
    return t.isEmpty ? null : t;
  }

  String? transAt(int timeMs) => nearestAt(transLines, transTimes, timeMs);
  String? romaAt(int timeMs) => nearestAt(romaLines, romaTimes, timeMs);

  // 交错翻译合并：本地下载（KG等）的 LRC 常见「主行 + 同时间戳译文」
  // 的交错结构（`[mm:ss.xx]原文` 后紧跟 `[mm:ss.xx]译文`，如
  // `[00:37.472]僕は強くならなきゃいけない` + `[00:37.472]必须要让自己变得强大起来`）。
  // 若两行视为独立主行，译文会占一个时间轴槽位、译文也无法挂到主行
  // （渲染时把译文当当前行、原文行反而短暂缺失）。仅在**未单独提供**
  // translation 参数时启用合并——在线平台（NT/KG API）主歌词与
  // 翻译分开返回，content 内不会交错，合并反而会误吞主行。
  // 背景人声行（含尾随和声子行）不参与合并。
  final interleaved = translation == null || translation.trim().isEmpty;
  final groups = <LyricGroup>[];
  final hints = <int?>[];
  for (final row in sorted) {
    final last = groups.isEmpty ? null : groups.last;
    if (interleaved &&
        !row.isBg &&
        last != null &&
        !last.isBG &&
        row.timeMs == last.original.timeMs &&
        last.translation == null) {
      // 同时间戳的下一行 → 挂为上一行的翻译，不单独成行
      groups[groups.length - 1] = LyricGroup(
        original: last.original,
        translation: row.text,
        romaji: last.romaji,
        fragments: last.fragments,
        isBG: last.isBG,
      );
      continue;
    }
    groups.add(LyricGroup(
      original: LyricLine(timeMs: row.timeMs, text: row.text),
      // 背景人声行不挂翻译/音译（同一时间戳的译文属于主行，避免重复）。
      translation: row.isBg ? null : transAt(row.timeMs),
      romaji: row.isBg ? null : romaAt(row.timeMs),
      fragments: row.fragments,
      isBG: row.isBg,
    ));
    hints.add(row.endHint);
  }

  // 行结束时间后置计算：下一行起始即本行结束（末行给默认 4s 兜底）。
  // 显式行尾（ESLRC 末尾空标签）优先；主行后紧跟的**同时间**背景子行不占用
  // 「下一行」边界（它挂在主行上，不改变主行的高亮窗口）；异时间的背景行
  // （如独立和声段）照常作边界。
  final n = groups.length;
  final ends = List<int>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    // 同时间的背景子行跟随主行窗口（含主行的显式行尾）。
    if (groups[i].isBG &&
        hints[i] == null &&
        i > 0 &&
        !groups[i - 1].isBG &&
        groups[i - 1].original.timeMs == groups[i].original.timeMs) {
      ends[i] = ends[i - 1];
      continue;
    }
    if (hints[i] != null) {
      ends[i] = hints[i]!;
      continue;
    }
    var j = i + 1;
    if (!groups[i].isBG) {
      while (j < n &&
          groups[j].isBG &&
          groups[j].original.timeMs == groups[i].original.timeMs) {
        j++;
      }
    }
    ends[i] = j < n ? groups[j].original.timeMs : groups[i].original.timeMs + 4000;
  }
  // 同步把缺失的逐字时长按「下一字/行尾」补齐（对齐 AMLL 字级推进）。
  return List.generate(n, (i) {
    final g = groups[i];
    final end = ends[i];
    return LyricGroup(
      original: g.original,
      translation: g.translation,
      romaji: g.romaji,
      fragments: _fillFragmentDurations(g.fragments, g.original.timeMs, end),
      endMs: end,
      isBG: g.isBG,
    );
  });
}

/// 整行是否被圆括号包裹（半角 `()` 或全角 `（）`）——背景人声判定，
/// 对齐 AMLL `isBackgroundVocalText` / `checkIsBG`。
bool isBgText(String text) {
  if (text.length < 2) return false;
  final a = text.codeUnitAt(0);
  final b = text.codeUnitAt(text.length - 1);
  final open = a == 0x28 || a == 0xFF08; // ( （
  final close = b == 0x29 || b == 0xFF09; // ) ）
  return open && close;
}

/// 剥掉背景人声行首尾片段的括号（就地修改），并丢弃因此变空的片段。
void trimBgParentheses(List<LyricFragment> frags) {
  if (frags.isEmpty) return;
  final first = frags.first;
  if (first.text.isNotEmpty) {
    frags[0] = LyricFragment(
      text: first.text.substring(1),
      startMs: first.startMs,
      durationMs: first.durationMs,
      synthetic: first.synthetic,
    );
  }
  final lastIdx = frags.length - 1;
  final last = frags[lastIdx];
  if (last.text.isNotEmpty) {
    frags[lastIdx] = LyricFragment(
      text: last.text.substring(0, last.text.length - 1),
      startMs: last.startMs,
      durationMs: last.durationMs,
      synthetic: last.synthetic,
    );
  }
  frags.removeWhere((f) => f.text.isEmpty);
}

/// 补齐逐字片段的缺失时长：以「下一字起始（或行尾）」为当前字结束。
/// AMLL 逐字推进依赖每个 word 的 endTime；缺失时若整行等分会与源
/// 逐字时间轴错位，取最近邻更稳。
List<LyricFragment>? _fillFragmentDurations(
  List<LyricFragment>? frags,
  int lineStart,
  int lineEnd,
) {
  if (frags == null || frags.isEmpty) return frags;
  if (frags.every((f) => f.durationMs != null && f.durationMs! > 0)) {
    return frags;
  }
  final out = <LyricFragment>[];
  for (var j = 0; j < frags.length; j++) {
    final f = frags[j];
    var dur = f.durationMs;
    if (dur == null || dur <= 0) {
      final nextStart = j + 1 < frags.length
          ? frags[j + 1].startMs
          : (lineEnd - lineStart);
      dur = nextStart - f.startMs;
      if (dur <= 0) dur = 400;
    }
    out.add(LyricFragment(
      text: f.text,
      startMs: f.startMs,
      durationMs: dur,
      synthetic: f.synthetic,
    ));
  }
  return out;
}

// ── 无逐字时间的整行歌词：按行窗口合成卡拉OK 扫亮片段 ──────────────

/// 合成扫亮的「每单位」毫秒数（CJK 每字 / 拉丁每字符）。
///
/// 传统单行 LRC 只有行时间；用它估算演唱时长（见 [synthesizeSweepFragments]）。
const int kSyntheticSweepPerUnitMs = 240;

/// 合成扫亮的最短 / 最长估算时长（毫秒），避免极短行一闪而过、长间奏拖得过慢。
const int kSyntheticSweepMinMs = 600;
const int kSyntheticSweepMaxMs = 10000;

/// 合成扫亮的字/词原子（文本 + 权重 = 非空白字符数）。
class _SweepAtom {
  const _SweepAtom(this.text, this.weight);
  final String text;
  final int weight;
}

bool _isSweepSpace(int r) =>
    r == 0x20 || r == 0x09 || r == 0x0A || r == 0x0D || r == 0x0C || r == 0x3000;

/// 是否 CJK（汉字 / 假名 / 谚文）——逐字成原子；其余按空白分词。
bool _isSweepCjk(int r) =>
    (r >= 0x3040 && r <= 0x30FF) ||
    (r >= 0x3400 && r <= 0x4DBF) ||
    (r >= 0x4E00 && r <= 0x9FFF) ||
    (r >= 0xAC00 && r <= 0xD7AF) ||
    (r >= 0xF900 && r <= 0xFAFF);

/// 把整行文本切成扫亮原子（拼接结果与原文完全一致）。
///
/// CJK 逐字、拉丁/其它按空白分词；空白附在前一个原子尾部（保持拼接一致）。
/// 对齐 SPlayer-Next `split-words.ts` 的切分策略。
List<_SweepAtom> _splitSweepAtoms(String text) {
  final runes = text.runes.toList();
  final atoms = <_SweepAtom>[];
  final buf = StringBuffer();
  void flush() {
    if (buf.isEmpty) return;
    final s = buf.toString();
    var w = 0;
    for (final r in s.runes) {
      if (!_isSweepSpace(r)) w++;
    }
    atoms.add(_SweepAtom(s, w > 0 ? w : 1));
    buf.clear();
  }

  var i = 0;
  while (i < runes.length) {
    final r = runes[i];
    if (_isSweepCjk(r)) {
      flush();
      final sb = StringBuffer(String.fromCharCode(r));
      i++;
      while (i < runes.length && _isSweepSpace(runes[i])) {
        sb.write(String.fromCharCode(runes[i]));
        i++;
      }
      atoms.add(_SweepAtom(sb.toString(), 1));
      continue;
    }
    if (_isSweepSpace(r)) {
      buf.write(String.fromCharCode(r));
      flush();
      i++;
      continue;
    }
    buf.write(String.fromCharCode(r));
    i++;
  }
  flush();
  return atoms;
}

/// 为「无逐字时间」的整行歌词按行窗口合成卡拉OK 扫亮片段。
///
/// 把窗口 `[startMs, endMs]` 按字/词权重分摊成逐字片段（[startMs] 相对行首、
/// [durationMs] 已填充），使 AMLL 引擎的扫亮动效对传统单行歌词也生效，
/// 传入翻译 / 音译文本即可让附属小字同样扫亮。
///
/// 行窗口远长于自然演唱时长时（长间奏），扫亮在**估算时长**
/// （`总权重 × [kSyntheticSweepPerUnitMs]`，钳制到
/// [[kSyntheticSweepMinMs], [kSyntheticSweepMaxMs]]）内完成，余下保持全亮；
/// 窗口更短则按窗口时长扫完（快歌不拖）。
///
/// 文本为空或窗口 ≤ 0 时返回 null（调用方回退整行绘制）。
List<LyricFragment>? synthesizeSweepFragments(
  String text,
  int startMs,
  int endMs,
) {
  final window = endMs - startMs;
  if (text.trim().isEmpty || window <= 0) return null;
  final atoms = _splitSweepAtoms(text);
  if (atoms.isEmpty) return null;
  var total = 0;
  for (final a in atoms) {
    total += a.weight;
  }
  if (total <= 0) return null;
  final estimated = (total * kSyntheticSweepPerUnitMs)
      .clamp(kSyntheticSweepMinMs, kSyntheticSweepMaxMs)
      .round();
  final sweep = window < estimated ? window : estimated;

  final out = <LyricFragment>[];
  var acc = 0;
  for (var i = 0; i < atoms.length; i++) {
    final a = atoms[i];
    final rel = (sweep * acc) ~/ total;
    acc += a.weight;
    final end = i == atoms.length - 1 ? sweep : (sweep * acc) ~/ total;
    var dur = end - rel;
    if (dur <= 0) dur = 1;
    out.add(LyricFragment(
      text: a.text,
      startMs: rel,
      durationMs: dur,
      synthetic: true,
    ));
  }
  return out;
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
