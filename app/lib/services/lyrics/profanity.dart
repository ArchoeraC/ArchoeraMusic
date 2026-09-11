// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 歌词屏蔽词还原（语义化重建，由「解锁脏话」设置控制）。
///
/// 不再依赖逐条写死的正则（`f\*{2}k` → fuck 之类），而是把被星号遮盖的
/// 片段当作「保留字符 + 通配星号」的模式，在小型词典里按
/// 「等长 + 已知字符逐一匹配」重建原词：
///
/// - `s**t` / `sh*t` / `s***` 等任意遮盖形态都能命中 `shit`；
/// - `f**king`、`m***f***er`、`a**hole` 等长词同样按模式还原；
/// - 同一模式命中多个候选时按词典常见度（顺序）取先者（如 `s**t`
///   优先还原为更常见的 `shit` 而非 `slut`）；
/// - 保留原片段大小写：`F**k` → `Fuck`，`F**K` → `FUCK`。
///
/// 全部为编译期常量 + 长度分桶：精确匹配只做等长字符比对，仅当精确
/// 匹配失败时才为变长遮罩构造一次正则。无第三方依赖、无可感知资源开销；
/// 全星号（`****`）歧义过大不做猜测。
library;

/// 高频脏话 / 粗口词典（按常见度排序，越靠前越优先命中）。
const List<String> _lexicon = [
  'fuck',
  'fucking',
  'fucked',
  'fucker',
  'motherfucker',
  'shit',
  'shitty',
  'bullshit',
  'bitch',
  'cunt',
  'cock',
  'dick',
  'damn',
  'goddamn',
  'ass',
  'asses',
  'asshole',
  'bastard',
  'whore',
  'slut',
  'pussy',
  'piss',
  'crap',
  'suck',
  'sucker',
  'nigga',
  'nigger',
  'faggot',
  'fag',
  'dyke',
  'retard',
  'wanker',
  'prick',
  'twat',
  'bollocks',
  'arse',
  'arsehole',
  'bugger',
  'douche',
  'douchebag',
  'jackass',
  'dipshit',
  'horseshit',
  'batshit',
  'clusterfuck',
  'dumbass',
  'badass',
  'kickass',
  'hardass',
  'blowjob',
  'handjob',
  'hooker',
  'skank',
  'screwed',
  'pissed',
  'cocksucker',
  'cocksucking',
  'motherfucking',
];

/// 词典按长度分桶，匹配时只扫同长度候选。
final Map<int, List<String>> _byLength = () {
  final m = <int, List<String>>{};
  for (final w in _lexicon) {
    (m[w.length] ??= <String>[]).add(w);
  }
  return m;
}();

/// 连续片段：字母 + 至少一个星号（可含结尾星号）。星号视为单字符通配。
final RegExp _maskedRun = RegExp(r'[A-Za-z]*\*[A-Za-z*]*');

/// 还原单个文本中被星号遮盖的脏话（保留大小写）。
String unmaskProfanity(String text) {
  if (text.isEmpty || !text.contains('*')) return text;
  return text.replaceAllMapped(_maskedRun, (m) {
    final masked = m.group(0)!;
    return _resolve(masked) ?? masked;
  });
}

/// 在词典中按模式重建 [masked]；无唯一可信候选时返回 null（保持原样）。
String? _resolve(String masked) {
  // 全星号（无任何已知字符）歧义过大，不猜测。
  var hasKnown = false;
  for (var i = 0; i < masked.length; i++) {
    if (masked.codeUnitAt(i) != 0x2A /* '*' */) {
      hasKnown = true;
      break;
    }
  }
  if (!hasKnown) return null;

  final lower = masked.toLowerCase();
  return _resolveExact(masked, lower) ?? _resolveLoose(masked, lower);
}

/// 等长逐字匹配：每个 `*` 恰好通配一个字母（标准 LRC 遮盖）。
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

/// 变长回退：连续星号段可代表 k~k+2 个字符，兼容 `as**le`、`co**`
/// 这类「星号段代表一整块被抹掉内容」的遮盖写法。
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

/// 按原片段的字母大小写风格还原 [word]。
String _applyCase(String masked, String word) {
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
