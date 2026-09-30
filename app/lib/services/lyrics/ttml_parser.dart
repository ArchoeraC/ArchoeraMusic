// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// TTML 歌词解析（Apple Music / AMLL DB 风格）→ [LyricGroup]。
///
/// 零新增依赖：自带一个容错 XML 扫描器（Flutter SDK 无内置 XML 解析，
/// 也不为此引入 pub 包），只取所需结构，遇到未知标签 / 属性一律忽略。
///
/// 支持范围：
/// - 根 `<tt>` / `<body>` / `<div>` / `<p>` 结构；仅解析 `<p>` 行；
/// - 行属性 `begin` / `end`（TTML 时间），缺失时由行内计时 `<span>` 推断；
/// - `<span begin end>` 逐词（[LyricFragment]，时间为相对行首偏移）；
/// - `ttm:role="x-bg"` 背景人声行（递归按行解析，紧跟主行输出）；
/// - `ttm:role="x-translation"` / `x-roman` 译文与音译（译文按语言择优）。
///
/// 属性名做命名空间容错：`ttm:role` / `role`、`xml:lang` / `lang` 均可。
///
/// 输出满足 [LyricGroup] 的既有约束：逐词 [LyricFragment.startMs] 为相对行首
/// 偏移；`fragments` 拼接文本等于行原文（否则渲染端应回退整行绘制）；背景行
/// 紧跟其主行；整表按 [LyricLine.timeMs] 升序。
library;

import 'lyric_line.dart';

/// 解析 TTML 时间串为毫秒。
///
/// - `"1.234s"`（无冒号）→ `(1.234 * 1000).round()`；
/// - `"mm:ss[.fff]"` / `"hh:mm:ss[.fff]"`：小数部分右补零到 3 位后截断
///   （`.5` → 500ms，`.1234` → 123ms）；
/// - 空串或无法识别 → 0。
int parseTtmlTime(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return 0;
  if (!s.contains(':')) {
    // 无冒号：秒（可带 s 后缀）→ 毫秒四舍五入。
    final body = s.endsWith('s') || s.endsWith('S')
        ? s.substring(0, s.length - 1)
        : s;
    final n = double.tryParse(body);
    if (n == null) return 0;
    return (n * 1000).round();
  }
  final parts = s.split(':');
  // 末段 = 秒（可带小数），倒数第二段 = 分，倒数第三段 = 时。
  final secPart = parts.last;
  var seconds = 0;
  var millis = 0;
  final dot = secPart.indexOf('.');
  if (dot >= 0) {
    seconds = int.tryParse(secPart.substring(0, dot)) ?? 0;
    final frac = secPart.substring(dot + 1);
    // 右补零到 3 位后截断（TTML 小数位数不定）。
    final padded = frac.length >= 3 ? frac.substring(0, 3) : frac.padRight(3, '0');
    millis = int.tryParse(padded) ?? 0;
  } else {
    seconds = int.tryParse(secPart) ?? 0;
  }
  final minutes =
      parts.length >= 2 ? int.tryParse(parts[parts.length - 2]) ?? 0 : 0;
  final hours =
      parts.length >= 3 ? int.tryParse(parts[parts.length - 3]) ?? 0 : 0;
  return ((hours * 3600) + (minutes * 60) + seconds) * 1000 + millis;
}

/// 解析 TTML 歌词文本为按时间升序的歌词组。
///
/// - [preferredLang] 用于在同行的多个 `x-translation` 候选里择优；
/// - 输入不含 `<tt>` 根或解析失败时返回 `const []`（本函数不抛异常）。
List<LyricGroup> parseTtmlLyrics(String ttml, {String preferredLang = 'zh-CN'}) {
  if (ttml.isEmpty || !_hasTtRoot(ttml)) return const [];
  try {
    final top = _XmlScanner(ttml).parse();
    _XmlNode? root;
    for (final n in top) {
      if (n.isElement && _localName(n.name!) == 'tt') {
        root = n;
        break;
      }
    }
    if (root == null) return const [];

    final pNodes = <_XmlNode>[];
    _collectParagraphs(root, pNodes);
    if (pNodes.isEmpty) return const [];

    final mainLines = [
      for (final p in pNodes) _parseLineNode(p, preferredLang, isBg: false),
    ];
    // 稳定排序：时间相同则保持文档顺序（Dart 的 List.sort 不保证稳定）。
    final order = List<int>.generate(mainLines.length, (i) => i)
      ..sort((a, b) {
        final c = mainLines[a].beginMs.compareTo(mainLines[b].beginMs);
        return c != 0 ? c : a.compareTo(b);
      });

    final out = <LyricGroup>[];
    for (final i in order) {
      final line = mainLines[i];
      out.add(_toGroup(line));
      // 背景人声行紧跟主行（不按时间轴单独排序）。
      for (final bg in line.backgrounds) {
        out.add(_toGroup(bg));
      }
    }
    return out;
  } catch (_) {
    // 容错优先：任何异常都退化为「无 TTML 歌词」，不打断播放链路。
    return const [];
  }
}

// ---------------------------------------------------------------------------
// 行解析
// ---------------------------------------------------------------------------

/// 行内片段：计时 `<span>` 为计时片段，纯文本节点为未计时片段。
///
/// [beginMs] / [endMs] 为绝对毫秒；未计时片段在行时间确定后统一补齐。
class _Piece {
  _Piece(this.text, {this.beginMs, this.endMs});

  String text;
  int? beginMs;
  int? endMs;

  bool get timed => beginMs != null && endMs != null;
}

/// 一个译文候选（文本 + 语言标签）。
class _Translation {
  _Translation(this.text, this.lang);

  final String text;
  final String? lang;
}

/// 解析结果：行时间、文本、片段、译文 / 音译与背景子行。
class _ParsedLine {
  _ParsedLine({
    required this.beginMs,
    required this.endMs,
    required this.text,
    required this.pieces,
    required this.hasTimedWords,
    required this.isBg,
    this.translation,
    this.romaji,
    List<_ParsedLine>? backgrounds,
  }) : backgrounds = backgrounds ?? const [];

  final int beginMs;
  final int endMs;
  final String text;
  final List<_Piece> pieces;
  final bool hasTimedWords;
  final bool isBg;
  final String? translation;
  final String? romaji;
  final List<_ParsedLine> backgrounds;
}

/// 把一个 `<p>`（或 `x-bg` 的 `<span>`）解析为 [_ParsedLine]。
///
/// 二者结构一致，区别仅在于 [isBg]（背景行需要剥首尾圆括号）。
_ParsedLine _parseLineNode(
  _XmlNode el,
  String preferredLang, {
  required bool isBg,
}) {
  final pieces = <_Piece>[];
  final backgrounds = <_ParsedLine>[];
  final translations = <_Translation>[];
  String? romaji;
  var hasTimedWords = false;

  final children = el.children;
  // 预处理：最后一个计时 span 的下标，用于丢弃行尾空白。
  var lastTimed = -1;
  for (var i = 0; i < children.length; i++) {
    if (_isTimedSpan(children[i])) lastTimed = i;
  }

  for (var i = 0; i < children.length; i++) {
    final c = children[i];
    if (c.isText) {
      final t = c.text ?? '';
      if (t.trim().isEmpty) {
        // 仅保留两段计时 span 之间的空白（首尾空白丢弃），折叠为一个空格。
        if (t.isNotEmpty && pieces.isNotEmpty && i < lastTimed) {
          pieces.add(_Piece(' '));
        }
      } else {
        // 非空文本节点 = 未计时片段（用行起止兜底）。
        pieces.add(_Piece(t));
      }
      continue;
    }
    if (!c.isElement) continue;
    if (_localName(c.name!) != 'span') continue;

    final role = _attrLocal(c, 'role');
    if (role == 'x-translation') {
      final text = _spanText(c).trim();
      if (text.isNotEmpty) {
        translations.add(_Translation(text, _attrLocal(c, 'lang')));
      }
      continue;
    }
    if (role == 'x-roman') {
      final text = _spanText(c).trim();
      romaji ??= text.isEmpty ? null : text;
      continue;
    }
    if (role == 'x-bg') {
      backgrounds.add(_parseLineNode(c, preferredLang, isBg: true));
      continue;
    }

    final begin = _attrLocal(c, 'begin');
    final end = _attrLocal(c, 'end');
    final text = _spanText(c);
    if (begin != null && end != null) {
      // 计时词：两端齐全才算逐词。
      hasTimedWords = true;
      pieces.add(_Piece(
        text,
        beginMs: parseTtmlTime(begin),
        endMs: parseTtmlTime(end),
      ));
    } else {
      pieces.add(_Piece(text));
    }
  }

  // 行时间：属性优先；缺失则用计时词的最小起 / 最大止推断。
  final attrBegin = _attrLocal(el, 'begin');
  final attrEnd = _attrLocal(el, 'end');
  var minStart = -1;
  var maxEnd = -1;
  for (final p in pieces) {
    if (!p.timed) continue;
    if (minStart < 0 || p.beginMs! < minStart) minStart = p.beginMs!;
    if (maxEnd < 0 || p.endMs! > maxEnd) maxEnd = p.endMs!;
  }
  final beginMs =
      attrBegin != null ? parseTtmlTime(attrBegin) : (minStart >= 0 ? minStart : 0);
  final endMs =
      attrEnd != null ? parseTtmlTime(attrEnd) : (maxEnd >= 0 ? maxEnd : beginMs);

  // 补齐未计时片段：空白取相邻计时词边界，实义文本用行起止兜底。
  for (var i = 0; i < pieces.length; i++) {
    final p = pieces[i];
    if (p.timed) continue;
    if (p.text.trim().isEmpty) {
      var start = beginMs;
      for (var k = i - 1; k >= 0; k--) {
        final q = pieces[k];
        if (q.endMs != null) {
          start = q.endMs!;
          break;
        }
      }
      var end = endMs;
      for (var k = i + 1; k < pieces.length; k++) {
        final q = pieces[k];
        if (q.beginMs != null) {
          end = q.beginMs!;
          break;
        }
      }
      p.beginMs = start;
      p.endMs = end < start ? start : end;
    } else {
      p.beginMs = beginMs;
      p.endMs = endMs;
    }
  }

  // 背景行：剥掉最外层的一对圆括号（半角 / 全角）。
  if (isBg) _stripBgParentheses(pieces);

  final text = pieces.map((p) => p.text).join().trim();
  return _ParsedLine(
    beginMs: beginMs,
    endMs: endMs,
    text: text,
    pieces: pieces,
    hasTimedWords: hasTimedWords,
    isBg: isBg,
    translation: _pickTranslation(translations, preferredLang),
    romaji: romaji,
    backgrounds: backgrounds,
  );
}

/// 组装 [LyricGroup]：仅当存在计时词时给出 `fragments`。
LyricGroup _toGroup(_ParsedLine line) {
  List<LyricFragment>? fragments;
  if (line.hasTimedWords) {
    fragments = [
      for (final p in line.pieces)
        LyricFragment(
          text: p.text,
          startMs: _clampNonNeg((p.beginMs ?? line.beginMs) - line.beginMs),
          durationMs: _clampNonNeg((p.endMs ?? p.beginMs ?? line.beginMs) -
              (p.beginMs ?? line.beginMs)),
        ),
    ];
  }
  return LyricGroup(
    original: LyricLine(timeMs: line.beginMs, text: line.text),
    translation: line.translation,
    romaji: line.romaji,
    fragments: fragments,
    endMs: line.endMs,
    isBG: line.isBg,
  );
}

int _clampNonNeg(int v) => v < 0 ? 0 : v;

// ---------------------------------------------------------------------------
// 译文语言择优
// ---------------------------------------------------------------------------

/// 从同行多个 `x-translation` 候选中挑一个。
///
/// 顺序：规范化后与 [preferredLang] 完全相同 → 基语言（`-` 前）相同 →
/// 候选全无语言标签时取第一个 → 否则无译文。
String? _pickTranslation(List<_Translation> cands, String preferredLang) {
  if (cands.isEmpty) return null;
  final want = _normalizeLang(preferredLang);
  for (final c in cands) {
    if (_hasLang(c) && _normalizeLang(c.lang!) == want) return c.text;
  }
  final wantBase = _baseLang(want);
  for (final c in cands) {
    if (_hasLang(c) && _baseLang(_normalizeLang(c.lang!)) == wantBase) {
      return c.text;
    }
  }
  if (cands.every((c) => !_hasLang(c))) return cands.first.text;
  return null;
}

bool _hasLang(_Translation c) => c.lang != null && c.lang!.trim().isNotEmpty;

String _normalizeLang(String s) => s.trim().toLowerCase().replaceAll('_', '-');

String _baseLang(String s) {
  final i = s.indexOf('-');
  return i < 0 ? s : s.substring(0, i);
}

// ---------------------------------------------------------------------------
// 背景行括号剥离
// ---------------------------------------------------------------------------

/// 剥掉背景行首个非空片段的开头 `(`/`（` 与末个非空片段的结尾 `)`/`）`。
void _stripBgParentheses(List<_Piece> pieces) {
  for (final p in pieces) {
    if (p.text.isEmpty) continue;
    final c = p.text.codeUnitAt(0);
    if (c == 0x28 || c == 0xFF08) p.text = p.text.substring(1);
    break;
  }
  for (var i = pieces.length - 1; i >= 0; i--) {
    final p = pieces[i];
    if (p.text.isEmpty) continue;
    final last = p.text.length - 1;
    final c = p.text.codeUnitAt(last);
    if (c == 0x29 || c == 0xFF09) p.text = p.text.substring(0, last);
    break;
  }
  pieces.removeWhere((p) => p.text.isEmpty);
}

// ---------------------------------------------------------------------------
// 轻量容错 XML 扫描器
// ---------------------------------------------------------------------------

/// 扫描器节点：元素（[name] 非空）或文本（[name] 为空，正文在 [text]）。
class _XmlNode {
  _XmlNode(this.name, this.attrs) : text = null;

  _XmlNode.text(this.text)
      : name = null,
        attrs = const <String, String>{};

  final String? name;
  final Map<String, String> attrs;
  final String? text;
  final List<_XmlNode> children = [];

  bool get isText => name == null;
  bool get isElement => name != null;
}

/// 极简容错 XML 扫描器：只保留元素 / 属性 / 文本，忽略注释、PI、DOCTYPE。
///
/// 不做命名空间校验、不做标签配对校验——TTML 描述性歌词不会嵌套同名标签；
/// 解析失败时调用方（[parseTtmlLyrics]）以 `try/catch` 兜底为空。
class _XmlScanner {
  _XmlScanner(this._src);

  final String _src;
  int _i = 0;

  /// 扫描整个文档，返回顶层节点序列。
  List<_XmlNode> parse() => _nodes();

  List<_XmlNode> _nodes() {
    final nodes = <_XmlNode>[];
    final sb = StringBuffer();
    while (_i < _src.length) {
      final lt = _src.indexOf('<', _i);
      if (lt < 0) {
        sb.write(_src.substring(_i));
        _i = _src.length;
        break;
      }
      if (lt > _i) {
        sb.write(_src.substring(_i, lt));
        _i = lt;
      }
      if (_src.startsWith('<!--', _i)) {
        final end = _src.indexOf('-->', _i + 4);
        _i = end < 0 ? _src.length : end + 3;
        continue;
      }
      if (_src.startsWith('<![CDATA[', _i)) {
        final end = _src.indexOf(']]>', _i + 9);
        final stop = end < 0 ? _src.length : end;
        sb.write(_src.substring(_i + 9, stop));
        _i = end < 0 ? _src.length : end + 3;
        continue;
      }
      if (_src.startsWith('<!', _i) || _src.startsWith('<?', _i)) {
        final close = _src.startsWith('<?', _i) ? '?>' : '>';
        final end = _src.indexOf(close, _i + 2);
        _i = end < 0 ? _src.length : end + close.length;
        continue;
      }
      if (_src.startsWith('</', _i)) {
        // 闭合标签：冲刷文本并交还上层（递归解析的自然边界）。
        _flush(nodes, sb);
        final end = _src.indexOf('>', _i + 2);
        _i = end < 0 ? _src.length : end + 1;
        return nodes;
      }
      final elem = _readElement();
      if (elem == null) {
        _i++;
        continue;
      }
      _flush(nodes, sb);
      nodes.add(elem);
    }
    _flush(nodes, sb);
    return nodes;
  }

  /// 读取一个起始标签（含属性），非自闭合时递归读取其子节点。
  _XmlNode? _readElement() {
    var j = _i + 1;
    final nameStart = j;
    while (j < _src.length && !_isNameEnd(_src.codeUnitAt(j))) {
      j++;
    }
    final name = _src.substring(nameStart, j);
    if (name.isEmpty) return null;

    final attrs = <String, String>{};
    var selfClosing = false;
    while (j < _src.length) {
      while (j < _src.length && _isWs(_src.codeUnitAt(j))) {
        j++;
      }
      if (j >= _src.length) break;
      final c = _src.codeUnitAt(j);
      if (c == 0x3E) {
        j++;
        break;
      }
      if (c == 0x2F) {
        selfClosing = true;
        j++;
        continue;
      }
      final aStart = j;
      while (j < _src.length) {
        final cc = _src.codeUnitAt(j);
        if (cc == 0x3D || cc == 0x3E || _isWs(cc) || cc == 0x2F) break;
        j++;
      }
      final aName = _src.substring(aStart, j);
      var aValue = '';
      while (j < _src.length && _isWs(_src.codeUnitAt(j))) {
        j++;
      }
      if (j < _src.length && _src.codeUnitAt(j) == 0x3D) {
        j++;
        while (j < _src.length && _isWs(_src.codeUnitAt(j))) {
          j++;
        }
        if (j < _src.length) {
          final q = _src.codeUnitAt(j);
          if (q == 0x22 || q == 0x27) {
            j++;
            final end = _src.indexOf(String.fromCharCode(q), j);
            final stop = end < 0 ? _src.length : end;
            aValue = _src.substring(j, stop);
            j = end < 0 ? _src.length : end + 1;
          } else {
            final vStart = j;
            while (j < _src.length &&
                !_isWs(_src.codeUnitAt(j)) &&
                _src.codeUnitAt(j) != 0x3E) {
              j++;
            }
            aValue = _src.substring(vStart, j);
          }
        }
      }
      if (aName.isNotEmpty) attrs[aName] = _decodeEntities(aValue);
    }
    _i = j;

    final node = _XmlNode(name, attrs);
    if (!selfClosing) node.children.addAll(_nodes());
    return node;
  }

  void _flush(List<_XmlNode> nodes, StringBuffer sb) {
    if (sb.isEmpty) return;
    nodes.add(_XmlNode.text(_decodeEntities(sb.toString())));
    sb.clear();
  }
}

bool _isWs(int c) =>
    c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0C;

bool _isNameEnd(int c) => _isWs(c) || c == 0x2F || c == 0x3E;

/// 解码常见实体与数字实体；未识别的实体原样保留。
String _decodeEntities(String s) {
  if (!s.contains('&')) return s;
  final sb = StringBuffer();
  var i = 0;
  while (i < s.length) {
    final amp = s.indexOf('&', i);
    if (amp < 0) {
      sb.write(s.substring(i));
      break;
    }
    sb.write(s.substring(i, amp));
    final semi = s.indexOf(';', amp + 1);
    if (semi < 0) {
      sb.write(s.substring(amp));
      break;
    }
    final decoded = _decodeEntity(s.substring(amp + 1, semi));
    if (decoded == null) {
      sb.write(s.substring(amp, semi + 1));
    } else {
      sb.write(decoded);
    }
    i = semi + 1;
  }
  return sb.toString();
}

String? _decodeEntity(String e) {
  switch (e) {
    case 'amp':
      return '&';
    case 'lt':
      return '<';
    case 'gt':
      return '>';
    case 'quot':
      return '"';
    case 'apos':
      return "'";
    case 'nbsp':
      return '\u00A0';
  }
  if (e.startsWith('#x') || e.startsWith('#X')) {
    final v = int.tryParse(e.substring(2), radix: 16);
    return v == null || v < 0 || v > 0x10FFFF ? null : String.fromCharCode(v);
  }
  if (e.startsWith('#')) {
    final v = int.tryParse(e.substring(1));
    return v == null || v < 0 || v > 0x10FFFF ? null : String.fromCharCode(v);
  }
  return null;
}

// ---------------------------------------------------------------------------
// 结构 / 属性工具
// ---------------------------------------------------------------------------

/// 输入是否含 `<tt>` 根（快速短路，避免对纯文本做完整扫描）。
bool _hasTtRoot(String s) =>
    RegExp(r'<tt[\s>/]').firstMatch(s) != null ||
    s.trimLeft().startsWith('<tt') ||
    s.contains('<tt>');

/// 收集文档中所有 `<p>` 元素（文档顺序，不递归进 `<p>` 内部）。
void _collectParagraphs(_XmlNode node, List<_XmlNode> out) {
  for (final c in node.children) {
    if (!c.isElement) continue;
    if (_localName(c.name!) == 'p') {
      out.add(c);
    } else {
      _collectParagraphs(c, out);
    }
  }
}

/// 取带前缀名的本地名（`ttm:role` → `role`）。
String _localName(String qualified) {
  final i = qualified.lastIndexOf(':');
  return i < 0 ? qualified : qualified.substring(i + 1);
}

/// 命名空间容错的属性查找：先精确名，再按本地名匹配。
String? _attrLocal(_XmlNode node, String local) {
  final exact = node.attrs[local];
  if (exact != null) return exact;
  for (final e in node.attrs.entries) {
    if (_localName(e.key) == local) return e.value;
  }
  return null;
}

/// `<span begin end>` 且非译文 / 音译 / 背景角色 = 计时词。
bool _isTimedSpan(_XmlNode c) {
  if (!c.isElement || _localName(c.name!) != 'span') return false;
  final role = _attrLocal(c, 'role');
  if (role == 'x-bg' || role == 'x-translation' || role == 'x-roman') {
    return false;
  }
  return _attrLocal(c, 'begin') != null && _attrLocal(c, 'end') != null;
}

/// 拼接 span 内文本，跳过嵌套的译文 / 音译 / 背景 span。
String _spanText(_XmlNode node) {
  final sb = StringBuffer();
  _collectText(node, sb);
  return sb.toString();
}

void _collectText(_XmlNode node, StringBuffer sb) {
  for (final c in node.children) {
    if (c.isText) {
      sb.write(c.text);
      continue;
    }
    if (!c.isElement || _localName(c.name!) != 'span') continue;
    final role = _attrLocal(c, 'role');
    if (role == 'x-bg' || role == 'x-translation' || role == 'x-roman') {
      continue;
    }
    _collectText(c, sb);
  }
}
