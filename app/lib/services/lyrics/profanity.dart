// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 歌词屏蔽词还原（语义化重建，由「解锁脏话」设置控制）。
///
/// 不依赖逐条写死的正则，而是把被遮盖的片段当作「已知字符 + 通配遮盖符」
/// 的模式，在词典里按「等长 + 已知字符逐一匹配」重建原词：
///
/// - 任意遮盖形态 `s**t` / `sh*t` / `s***` / `f**king` / `m***f***er` 都能命中；
/// - 遮盖符不限于 ASCII `*`：全角 `＊`、异体 `﹡ ∗ ✱ ✳ ✴ ❋`、乘号 `×`
///   一并识别（中文歌词常见全角遮盖）；
/// - 全角英数字（`ｆｕｃｋ`）先归一化为半角再匹配；
/// - 同一模式命中多个候选时按词典常见度（顺序）取先者（如 `s**t`
///   优先还原为更常见的 `shit` 而非 `slut`）；
/// - 保留原片段大小写：`F**k` → `Fuck`，`F**K` → `FUCK`。
///
/// 全部为编译期常量 + 长度分桶：精确匹配只做等长字符比对，仅当精确
/// 匹配失败时才为变长遮罩构造一次正则。无第三方依赖、无可感知资源开销；
/// 全遮盖（`****`）歧义过大不做猜测。
library;

/// 遮盖符集合：ASCII `*` + 常见全角/异体（中文歌词常用 `＊`/`×`）。
const String _maskChars = '*＊﹡∗✱✳✴❋×';

/// 非 ASCII 遮盖符（用于快速判断文本是否含遮盖）。
final Set<int> _maskRunes = _maskChars.runes
    .where((r) => r != 0x2A)
    .toSet();

/// 连续片段：字母/数字 + 至少一个遮盖符（可含结尾遮盖符）。遮盖符视为单字符通配。
final RegExp _maskedRun = RegExp(
  '[\\p{L}\\p{N}]*[$_maskChars][\\p{L}\\p{N}$_maskChars]*',
  unicode: true,
);

/// 高频脏话 / 粗口词典（按常见度排序，越靠前越优先命中）。
const List<String> _lexicon = [
  'fuck',
  'fucking',
  'fucked',
  'fucker',
  'fuckers',
  'motherfucker',
  'motherfuckers',
  'motherfucking',
  'clusterfuck',
  'shit',
  'shitty',
  'shitting',
  'shithead',
  'bullshit',
  'horseshit',
  'batshit',
  'dipshit',
  'bitch',
  'bitches',
  'bitching',
  'sonofabitch',
  'cunt',
  'cunts',
  'cock',
  'cocks',
  'cocksucker',
  'cocksucking',
  'dick',
  'dicks',
  'dickhead',
  'damn',
  'goddamn',
  'goddammit',
  'ass',
  'asses',
  'asshole',
  'assholes',
  'asshat',
  'asswipe',
  'dumbass',
  'jackass',
  'badass',
  'kickass',
  'hardass',
  'bastard',
  'bastards',
  'whore',
  'whores',
  'slut',
  'sluts',
  'slutty',
  'pussy',
  'pussies',
  'piss',
  'pissed',
  'pissing',
  'crap',
  'crappy',
  'suck',
  'sucks',
  'sucked',
  'sucker',
  'suckers',
  'nigga',
  'niggas',
  'nigger',
  'niggers',
  'faggot',
  'faggots',
  'fag',
  'fags',
  'dyke',
  'dykes',
  'retard',
  'retarded',
  'retards',
  'wanker',
  'wankers',
  'wank',
  'prick',
  'pricks',
  'twat',
  'twats',
  'bollocks',
  'bollock',
  'arse',
  'arsehole',
  'arseholes',
  'bugger',
  'buggers',
  'douche',
  'douchebag',
  'douchebags',
  'blowjob',
  'blowjobs',
  'handjob',
  'handjobs',
  'hooker',
  'hookers',
  'skank',
  'skanks',
  'screwed',
  'bellend',
  'knob',
  'knobhead',
  'tosser',
  'tossers',
  'shite',
  'feck',
  'fecking',
  'bloody',
];

/// 词典按长度分桶，匹配时只扫同长度候选。
final Map<int, List<String>> _byLength = () {
  final m = <int, List<String>>{};
  for (final w in _lexicon) {
    (m[w.length] ??= <String>[]).add(w);
  }
  return m;
}();

/// 还原单个文本中被遮盖的脏话（保留大小写与未遮盖内容）。
String unmaskProfanity(String text) {
  if (text.isEmpty || !_hasMask(text)) return text;
  return text.replaceAllMapped(_maskedRun, (m) {
    final masked = m.group(0)!;
    return _resolve(masked) ?? masked;
  });
}

/// 文本是否含任一遮盖符（ASCII `*` 或全角/异体）。
bool _hasMask(String s) => s.contains('*') || s.runes.any(_maskRunes.contains);

/// 归一化遮盖片段：遮盖符 → `*`；全角英数字 → 半角。
String _normalizeMask(String s) {
  final buf = StringBuffer();
  for (final r in s.runes) {
    if (r == 0x2A || _maskRunes.contains(r)) {
      buf.write('*');
    } else if (r >= 0xFF01 && r <= 0xFF5E) {
      buf.writeCharCode(r - 0xFEE0); // 全角 ASCII → 半角
    } else if (r == 0x3000) {
      buf.write(' ');
    } else {
      buf.writeCharCode(r);
    }
  }
  return buf.toString();
}

/// 在词典中按模式重建 [masked]；无唯一可信候选时返回 null（保持原样）。
String? _resolve(String masked) {
  final norm = _normalizeMask(masked);
  // 全遮盖（无任何已知字符）歧义过大，不猜测。
  var hasKnown = false;
  for (var i = 0; i < norm.length; i++) {
    if (norm.codeUnitAt(i) != 0x2A /* '*' */) {
      hasKnown = true;
      break;
    }
  }
  if (!hasKnown) return null;

  final lower = norm.toLowerCase();
  return _resolveExact(norm, lower) ?? _resolveLoose(norm, lower);
}

/// 等长逐字匹配：每个 `*` 恰好通配一个字符（标准 LRC 遮盖）。
String? _resolveExact(String masked, String lower) {
  final candidates = _byLength[masked.length];
  if (candidates == null) return null;
  for (final word in candidates) {
    var ok = true;
    for (var i = 0; i < lower.length; i++) {
      final mc = lower.codeUnitAt(i);
      if (mc == 0x2A) continue; // 通配
      if (lower.codeUnitAt(i) != word.codeUnitAt(i)) {
        ok = false;
        break;
      }
    }
    if (ok) return _applyCase(masked, word);
  }
  return null;
}

/// 变长回退：连续遮盖段可代表 k~k+2 个字符，兼容 `as**le`、`co**`
/// 这类「遮盖段代表一整块被抹掉内容」的写法。
String? _resolveLoose(String masked, String lower) {
  final buf = StringBuffer('^');
  var i = 0;
  while (i < lower.length) {
    if (lower[i] == '*') {
      var j = i;
      while (j < lower.length && lower[j] == '*') {
        j++;
      }
      final k = j - i;
      buf.write('.{$k,${k + 2}}');
      i = j;
    } else {
      buf.write(RegExp.escape(lower[i]));
      i++;
    }
  }
  buf.write(r'$');
  final re = RegExp(buf.toString());
  for (final word in _lexicon) {
    if (re.hasMatch(word)) return _applyCase(masked, word);
  }
  return null;
}

/// 按原片段的字母大小写风格还原 [word]（非拉丁词原样返回）。
String _applyCase(String masked, String word) {
  if (!_hasAsciiLetter(word)) return word;
  final letters = masked.replaceAll('*', '');
  if (letters.isEmpty || word.isEmpty) return word;
  // 已知字母全大写 → 全大写。
  if (letters == letters.toUpperCase()) return word.toUpperCase();
  // 首字母大写（且非全大写）→ 仅首字母大写。
  final first = masked[0];
  if (first.codeUnitAt(0) >= 0x41 && first.codeUnitAt(0) <= 0x5A) {
    return word[0].toUpperCase() + word.substring(1);
  }
  return word;
}

bool _hasAsciiLetter(String s) {
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if ((c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)) return true;
  }
  return false;
}
