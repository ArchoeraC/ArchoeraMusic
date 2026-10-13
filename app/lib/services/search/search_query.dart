// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// FTS5 `MATCH` 表达式编译（**纯函数，无 FFI / 无 IO，可单测**）。
///
/// 把与索引侧同构的分析词元（[AnalyzerTokens]）编译为 FTS5 查询表达式，
/// 语义对齐设计文档 `docs/local-search-index-plan.md` §4 / §5.2 / §9.3：
///   - `Lexical`：词法词元加双引号转义；**连续多个 CJK bigram** 合并为引号短语
///     （`"我爱 爱你"`，要求位置相邻以提升中文短语精度），其余逐个 `AND`；
///     末 token 若为拉丁/数字则追加 `*`（前缀，边打边搜）；
///   - `Pinyin`：音节 `AND`，末音节 `*`；音节数 ≥2 时额外提供「首音节前缀」变体
///     （见 [_pinyinBranch]，P4）；
///   - `Initials`：首字母串 `"wan"*`；
///   - `CrossLingual`（T1）：跨语言候选逐个原样 `quoteToken` 后以 `OR` 组合
///     （候选**之间** OR，非 AND；`love` → `"爱" OR "恋" …`）——英文查询召回含对应
///     汉字的内容 / 中文查询召回含英文释义的内容；
///   - 四支以 `OR` 组合（任一层命中即召回）。
///
/// 安全：所有词元都经 [quoteToken] 转义（内部 `"` 翻倍），杜绝 FTS5 语法
/// 错误与表达式注入；空查询返回 `null`（调用方视为「无关键字」回退原列表）。
library;

import 'search_models.dart';

/// 元数据列过滤用的 FTS5 列集合（`scope=metadata`；不含歌词 / 译文 / 音译段）。
const String metadataColumns =
    'title_tok artist_tok album_tok filename_tok pinyin_tok';

/// 单次模糊编译的**变体总数**默认上限（防止长串 / 多词元生成巨型 MATCH，设计文档 §4.6）。
const int defaultMaxFuzzyVariants = 500;

/// 替换容错的**受限字母表**（编辑距离 ≤ 1 的替换集合，刻意不用完整 26 字母）。
///
/// 依据「元音误拼 + 键盘邻键 + 视觉/语音混淆」，每个字母只给少量候选，控制变体膨胀：
///   - 元音互替（`a`/`e`/`i`/`o`/`u`）——英文拼写错字最常发生在元音（`hello`→`hallo`）；
///   - 常见辅音组（`{c,k,s,z}`、`{b,p,v}`、`{d,t}`、`{m,n}`、`{l,r}`、`{g,j}`、`{f,v}`）。
/// 未列出的字母（如 `h`/`y`/`x`）不做替换（宁可少扩也不要噪声）。
const Map<String, String> _substitutionAlternatives = {
  'a': 'eiou',
  'e': 'aiou',
  'i': 'aeou',
  'o': 'aeiu',
  'u': 'aeio',
  'b': 'pv',
  'p': 'b',
  'v': 'bf',
  'f': 'v',
  'd': 't',
  't': 'd',
  'c': 'ksz',
  'k': 'csq',
  's': 'cz',
  'z': 's',
  'g': 'j',
  'j': 'g',
  'm': 'n',
  'n': 'm',
  'l': 'r',
  'r': 'l',
  'q': 'k',
  'w': 'v',
};

/// 把单个词元转义为 FTS5 双引号字符串（内部 `"` 翻倍）。
///
/// 例：`a"b` → `"a""b"`；`a*b` → `"a*b"`（`*` 在引号内为字面量）。
String quoteToken(String token) => '"${token.replaceAll('"', '""')}"';

/// 编译为 FTS5 `MATCH` 表达式；无可匹配内容返回 `null`。
///
/// [scope] 为 [LocalSearchScope.metadata] 时对整个表达式施加前缀列过滤
/// `{title_tok artist_tok album_tok filename_tok pinyin_tok} : (...)`，
/// 只扫元数据段（不触歌词 / 译文 / 音译），见设计文档 §4.5。
String? compileMatch(
  AnalyzerTokens tokens, {
  LocalSearchScope scope = LocalSearchScope.all,
}) {
  final branches = <String>[];

  final lexical = _lexicalBranch(tokens.lexical);
  if (lexical != null) branches.add(lexical);

  final pinyin = _pinyinBranch(tokens.pinyin);
  if (pinyin != null) branches.add(pinyin);

  final initials = _initialsBranch(tokens.initials);
  if (initials != null) branches.add(initials);

  final crossLingual = _crossLingualBranch(tokens.crossLingual);
  if (crossLingual != null) branches.add(crossLingual);

  if (branches.isEmpty) return null;

  final joined = branches.join(' OR ');
  if (scope == LocalSearchScope.metadata) {
    // 列过滤必须作用于「整个」表达式——FTS5 中 `col : a AND b` 只过滤 `a`，
    // 故统一加括号：`{cols} : (a OR b)` / `{cols} : (a AND b)`。
    return '{$metadataColumns} : ($joined)';
  }
  return branches.length == 1 ? joined : '($joined)';
}

/// 跨语言候选分支（T1）：逐个 `quoteToken` 后以 **OR** 组合（候选之间 OR，非 AND）。
///
/// 候选由原生分析器（`Analyzer.AnalyzeQuery` → Unihan 释义扩展）产出：英文词 → 候选
/// 汉字、CJK 字 → 英文释义词。**不加前缀 `*`**（候选为完整词 / 字，避免过度召回）；
/// 空列表返回 null（不加此支）。单个候选不加包裹括号，多个候选整体加括号以便与
/// 其它分支的 `AND` / `OR` 优先级隔离（FTS5 中 `AND` 比 `OR` 结合更紧）。
String? _crossLingualBranch(List<String> terms) {
  final clean = terms
      .map((t) => t.trim())
      .where((t) => t.isNotEmpty)
      .toList();
  if (clean.isEmpty) return null;
  if (clean.length == 1) return quoteToken(clean.first);
  return '(${clean.map(quoteToken).join(' OR ')})';
}

/// 查询是否含**可做编辑距离扩展**的拉丁/数字词法词元（决定是否需要第二趟模糊查询）。
///
/// 纯 CJK 查询无需模糊（拼音分支已覆盖同音错字）；只有拉丁词元才可能因拼写错误而漏召回。
bool hasFuzzyEligible(AnalyzerTokens tokens) =>
    tokens.lexical.any(_isFuzzyEligible);

/// 编译**模糊（容错）** FTS5 `MATCH` 表达式（**纯函数**，设计文档 §4.6 模糊 / 容错）。
///
/// 与 [compileMatch] 的唯一差异：**拉丁/数字词法词元**扩展为「编辑距离 ≤ 1 的变体 OR 组」，
/// 其余分支（CJK 词法 / 拼音 / 首字母）与精确路径完全一致——拼音分支天然覆盖
/// **同音错字**（错字与正字拼音相同 → 命中），故不在此重复扩展。
///
/// 变体规则（确定性，无词典 / 无外部数据）：
///   - **删除**：去掉任一字符（L 个）；
///   - **相邻换位**：交换相邻两字符（L-1 个，跳过相同字符对）；
///   - **替换**：逐位用 [_substitutionAlternatives] 的受限候选替换；
///   - **不含插入**（把 `helo` 补回 `hello` 成本高，交由「查询侧正确、索引侧错字」的主场景反向覆盖）。
///   - 原词始终保留在变体首位，故模糊表达式天然是精确表达式的**超集**。
///
/// 变体全部经 [quoteToken] 转义（与精确分支同源，杜绝语法错误 / 注入）；末个拉丁词元
/// 若可前缀（[_isPrefixable]），其**每个**变体都追加 `*`（边打边搜语义一致）。
///
/// [maxVariants] 为本次编译的变体总数上限：总量超限时**只扩展最后一个拉丁词元**
/// （并截断到上限），其余拉丁词元退回精确，保证不产生巨型 `MATCH`。
/// 无任何分支（空查询）返回 `null`。
String? compileFuzzy(
  AnalyzerTokens tokens, {
  LocalSearchScope scope = LocalSearchScope.all,
  int maxVariants = defaultMaxFuzzyVariants,
}) {
  final branches = <String>[];

  final lexical = _fuzzyLexicalBranch(tokens.lexical, maxVariants);
  if (lexical != null) branches.add(lexical);

  // 拼音分支与精确一致：同音错字已由「同拼音」天然覆盖（见上）。
  final pinyin = _pinyinBranch(tokens.pinyin);
  if (pinyin != null) branches.add(pinyin);

  final initials = _initialsBranch(tokens.initials);
  if (initials != null) branches.add(initials);

  if (branches.isEmpty) return null;

  final joined = branches.join(' OR ');
  if (scope == LocalSearchScope.metadata) {
    return '{$metadataColumns} : ($joined)';
  }
  return branches.length == 1 ? joined : '($joined)';
}

/// 词法分支：连续多个 CJK bigram 合并为引号短语，其余逐个 `"tok"` `AND`。
///
/// - 多个**连续** CJK bigram（二字词元）→ 引号短语 `"我爱 爱你"`：FTS5 短语要求
///   词元位置相邻，比逐个 `AND` 更精确（设计文档 §4.1「保留位置供短语 / 邻近查询」）。
/// - 单个 bigram、unigram、拉丁/数字词元 → 维持逐个加引号 `AND`（现状）。
/// - 末词元若为拉丁/数字（[_isPrefixable]）追加 `*`（前缀，边打边搜）。
///
/// 空列表（或全空白）返回 null。
String? _lexicalBranch(List<String> terms) {
  final clean = terms
      .map((t) => t.trim())
      .where((t) => t.isNotEmpty)
      .toList();
  if (clean.isEmpty) return null;

  final chunks = <String>[];
  var i = 0;
  while (i < clean.length) {
    if (_isCjkBigram(clean[i])) {
      var j = i;
      while (j < clean.length && _isCjkBigram(clean[j])) {
        j++;
      }
      final run = clean.sublist(i, j);
      // 连续 ≥2 个 bigram → 引号短语；单个 bigram → 原样加引号（维持现状）。
      chunks.add(run.length >= 2 ? quoteToken(run.join(' ')) : quoteToken(run.first));
      i = j;
    } else {
      chunks.add(quoteToken(clean[i]));
      i++;
    }
  }

  final prefixLast = _isPrefixable(clean.last);
  final parts = <String>[];
  for (var k = 0; k < chunks.length; k++) {
    final isLast = k == chunks.length - 1;
    parts.add(isLast && prefixLast ? '${chunks[k]}*' : chunks[k]);
  }
  return parts.join(' AND ');
}

/// 拼音分支：音节 `AND`，末音节前缀；音节数 ≥2 时额外 OR 一个「首音节前缀」变体。
///
/// 现状（主形态）：末音节允许 `*`——覆盖「边打边搜」时末音节未输完（`woai` → `wo` + `ai*`）。
/// P4 变体：当音节数 ≥2，再提供「首音节也允许前缀」的形态（`w ai ni` → `"w"* AND "ai" AND "ni"*`），
/// 覆盖**首音节未输完 / 非末尾音节残缺**的混合输入——主形态无法命中（`"w"` 精确匹配不到 `wo`）。
///
/// 取舍：只对首音节放宽前缀（不选「全前缀」），把过度召回转到一个短音节上；
/// 变体与主形态以 `OR` 组合，结果仍由 BM25 排序，属受控放大召回。
String? _pinyinBranch(List<String> terms) {
  final clean = terms
      .map((t) => t.trim())
      .where((t) => t.isNotEmpty)
      .toList();
  if (clean.isEmpty) return null;

  final primary = _quotedAnd(clean, prefixFirst: false, prefixLast: true);
  if (clean.length < 2) return primary;

  final variant = _quotedAnd(clean, prefixFirst: true, prefixLast: true);
  return '($primary OR $variant)';
}

/// 音节/词元列表 → `"a" AND "b"*`；可选对首 / 末词元加前缀 `*`。
String _quotedAnd(
  List<String> terms, {
  required bool prefixFirst,
  required bool prefixLast,
}) {
  final parts = <String>[];
  for (var i = 0; i < terms.length; i++) {
    final prefixed =
        (i == 0 && prefixFirst) || (i == terms.length - 1 && prefixLast);
    parts.add(prefixed ? '${quoteToken(terms[i])}*' : quoteToken(terms[i]));
  }
  return parts.join(' AND ');
}

/// 首字母串 → `"wan"*`（含空格时逐段 `AND`，末段前缀）；空 / null 返回 null。
String? _initialsBranch(String? initials) {
  if (initials == null) return null;
  final terms = initials
      .split(RegExp(r'\s+'))
      .where((t) => t.isNotEmpty)
      .toList();
  if (terms.isEmpty) return null;
  return _quotedAnd(terms, prefixFirst: false, prefixLast: true);
}

/// 模糊词法分支：与 [_lexicalBranch] 同构，但把拉丁/数字词元换成**变体 OR 组**。
///
/// 变体预算：先按可扩展词元估算总变体数；超 [maxVariants] 时只保留**最后一个**
/// 可扩展词元（并截断），其余退回精确，避免巨型表达式。
String? _fuzzyLexicalBranch(List<String> terms, int maxVariants) {
  final clean = terms
      .map((t) => t.trim())
      .where((t) => t.isNotEmpty)
      .toList();
  if (clean.isEmpty) return null;

  final expandable = <int>[
    for (var i = 0; i < clean.length; i++)
      if (_isFuzzyEligible(clean[i])) i,
  ];

  // 每个可扩展词元的变体（含原词）。预算足够则全用；超限只留末个（截断）。
  var variants = <int, List<String>>{
    for (final i in expandable) i: _editDistanceOneVariants(clean[i]),
  };
  final total = variants.values.fold<int>(0, (sum, list) => sum + list.length);
  if (total > maxVariants && expandable.isNotEmpty) {
    final last = expandable.last;
    final full = _editDistanceOneVariants(clean[last]);
    variants = {
      last: full.length > maxVariants ? full.sublist(0, maxVariants) : full,
    };
  }

  final chunks = <String>[];
  var i = 0;
  while (i < clean.length) {
    if (_isCjkBigram(clean[i])) {
      // 与精确路径一致：连续 bigram 合并为引号短语。
      var j = i;
      while (j < clean.length && _isCjkBigram(clean[j])) {
        j++;
      }
      final run = clean.sublist(i, j);
      chunks.add(run.length >= 2 ? quoteToken(run.join(' ')) : quoteToken(run.first));
      i = j;
      continue;
    }

    final prefix = i == clean.length - 1 && _isPrefixable(clean[i]);
    final list = variants[i];
    if (list != null && list.isNotEmpty) {
      final group = list
          .map((v) => prefix ? '${quoteToken(v)}*' : quoteToken(v))
          .join(' OR ');
      chunks.add('($group)');
    } else {
      final quoted = quoteToken(clean[i]);
      chunks.add(prefix ? '$quoted*' : quoted);
    }
    i++;
  }
  return chunks.join(' AND ');
}

/// 生成 `word` 的**编辑距离 ≤ 1** 变体（含原词，首个元素；去重保序）。
///
/// 覆盖删除（全部位置）、相邻换位、受限字母表替换；不含插入。仅对纯 ASCII
/// `a`–`z0`–`9` 词元调用（见 [_isFuzzyEligible]），故按码元切分安全。
List<String> _editDistanceOneVariants(String word) {
  final out = <String>[word];
  final seen = <String>{word};

  void add(String candidate) {
    if (candidate.isNotEmpty && seen.add(candidate)) out.add(candidate);
  }

  // 删除：去掉任一字符。
  for (var i = 0; i < word.length; i++) {
    add(word.substring(0, i) + word.substring(i + 1));
  }
  // 相邻换位（跳过相同字符对，避免与原词重复 / 无意义）。
  for (var i = 0; i + 1 < word.length; i++) {
    if (word[i] == word[i + 1]) continue;
    add(word.substring(0, i) +
        word[i + 1] +
        word[i] +
        word.substring(i + 2));
  }
  // 替换：逐位用受限候选替换。
  for (var i = 0; i < word.length; i++) {
    final alternatives = _substitutionAlternatives[word[i]];
    if (alternatives == null) continue;
    for (final ch in alternatives.split('')) {
      add(word.substring(0, i) + ch + word.substring(i + 1));
    }
  }
  return out;
}

/// 拉丁 / 数字词元（纯 `a`–`z0`–`9`，无 CJK / 标点）——可做编辑距离扩展。
bool _isFuzzyEligible(String token) {
  if (token.isEmpty) return false;
  for (final rune in token.runes) {
    final isLower = rune >= 0x61 && rune <= 0x7A;
    final isDigit = rune >= 0x30 && rune <= 0x39;
    if (!isLower && !isDigit) return false;
  }
  return true;
}

/// 恰为两个 CJK 字符的词元（索引 / 查询侧的 bigram 形态）。
bool _isCjkBigram(String token) {
  final runes = token.runes;
  if (runes.length != 2) return false;
  return runes.every(_isCjk);
}

/// 拉丁 / 数字词元可加前缀：不含 CJK 即为真（分析器输出 CJK 与拉丁/数字互斥）。
bool _isPrefixable(String token) => !token.runes.any(_isCjk);

bool _isCjk(int rune) =>
    (rune >= 0x3400 && rune <= 0x4DBF) || // 扩展 A
    (rune >= 0x4E00 && rune <= 0x9FFF) || // 统一表意主区
    (rune >= 0xF900 && rune <= 0xFAFF); // 兼容表意区
