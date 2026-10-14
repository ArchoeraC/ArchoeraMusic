// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// FTS5 `MATCH` 表达式编译（**纯函数，无 FFI / 无 IO，可单测**）。
///
/// 把与索引侧同构的分析词元（[AnalyzerTokens]）编译为 FTS5 查询表达式，
/// 语义对齐设计文档 `docs/local-search-index-plan.md` §4 / §5.2 / §9.3：
///   - `Lexical`：词法词元加双引号转义；**连续多个 CJK bigram** 合并为引号短语
///     （`"我爱 爱你"`，要求位置相邻以提升中文短语精度），其余逐个 `AND`；
///     末 token 若为拉丁/数字且 ≥ [minPrefixTokenLength] 则追加 `*`（前缀，边打边搜）；
///   - `Pinyin`：`全拼音节`——单音节 ≥3 字符 `"hao"*`（前缀）；**≥2 音节为相邻短语** `"wo ai ni"`
///     （P5 实测修订：任意位置 `AND` 会把整库几乎全部命中，见 [_pinyinBranch]）；
///     漏字 / 换位由 [compilePinyinLoose] 作为**兜底趟**恢复（见 [minPrefixTokenLength]）；
///   - `Initials`：**列过滤**到首字母列（`initials_meta_tok` / `initials_lyrics_tok`，v4 分列）；≥2 字符前缀；
///   - `Reading`（v5，兜底趟）：拉丁 / 数字词元的字母 bigram `AND` 到读音列
///     （日文假名 / 汉字读音的罗马字；见 [compileReading]）；
///   - `CrossLingual`（T1）：跨语言候选逐个原样 `quoteToken` 后以 `OR` 组合
///     （候选**之间** OR，非 AND；`love` → `"爱" OR "恋" …`）——英文查询召回含对应
///     汉字的内容 / 中文查询召回含英文释义的内容。**默认不并入**主表达式，
///     由 [compileCrossLingual] 作为兜底趟单独执行（见 [compileMatch] 的 `includeCrossLingual`）；
///   - 主趟各支以 `OR` 组合（任一层命中即召回）。
///
/// 安全：所有词元都经 [quoteToken] 转义（内部 `"` 翻倍），杜绝 FTS5 语法
/// 错误与表达式注入；空查询返回 `null`（调用方视为「无关键字」回退原列表）。
library;

import 'script_ranges.dart';
import 'search_models.dart';

/// 元数据列过滤用的 FTS5 列集合（`scope=metadata`；不含歌词 / 译文 / 音译段）。
///
/// v4 起拼音 / 首字母按**元数据段 / 歌词段**分列，故这里只列元数据那两列——
/// `scope=metadata` 于是真正「只搜标题 / 歌手 / 专辑 / 文件名」（旧版混列时收不住，见设计文档 §4.5）。
const String metadataColumns =
    'title_tok artist_tok album_tok filename_tok pinyin_meta_tok initials_meta_tok reading_meta_tok';

/// 索引里存放拼音 / 首字母的列集合（查询该支时列过滤到这两列，避免误匹配标题里的拉丁词元）。
const String pinyinColumns = 'pinyin_meta_tok pinyin_lyrics_tok';
const String initialsColumns = 'initials_meta_tok initials_lyrics_tok';

/// 索引里存放**日文读音**（假名 / 汉字读音 → 罗马字字母 bigram）的列集合（v5）。
///
/// 只有**元数据**读音（标题 / 歌手 / 专辑 / 文件名）：歌词罗马字检索是伪需求，且整段歌词读音
/// bigram 会把索引推高约 2×（见设计文档 §4.2）。
const String readingColumns = 'reading_meta_tok';

/// 单次模糊编译的**变体总数**默认上限（防止长串 / 多词元生成巨型 MATCH，设计文档 §4.6）。
const int defaultMaxFuzzyVariants = 500;

/// 拼音 / 拉丁词元加前缀 `*`（边打边搜）的**最小长度**。
///
/// ≤2 字符的前缀（`"a"*` / `"wo"*` / `"ni"*`）在宽命中集上代价极高：30k 语料实测
/// `"ni"*` 命中 30000/30000、单条 59ms（FTS5 的 `ORDER BY bm25` 要给全部命中打分）。
/// 而 1–2 字符输入本身几乎没有识别力，改精确匹配既便宜又更准；3 字符起才加速前缀。
const int minPrefixTokenLength = 3;

/// 首字母串加前缀 `*` 的**最小长度**（首字母列空间小，2 字符起即可前缀）。
const int minInitialsPrefixLength = 2;

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
/// `{title_tok artist_tok album_tok filename_tok pinyin_tok initials_tok} : (...)`，
/// 只扫元数据段（不触歌词 / 译文 / 音译），见设计文档 §4.5。
///
/// [includeCrossLingual] 默认 false：跨语言支（T1）的候选多为**高频英文词**
/// （`愛` → `love`），`OR` 进表达式会把命中集放大到近乎整库（30k 实测单条 116ms）。
/// 调用方（[SearchIndex.search]）先跑不含该支的精确查询，**仅当命中过窄**时才用
/// [compileCrossLingual] 补一趟——跨语言召回归为「渐进兜底」而非每次都付全价。
String? compileMatch(
  AnalyzerTokens tokens, {
  LocalSearchScope scope = LocalSearchScope.all,
  bool includeCrossLingual = false,
}) {
  final branches = <String>[];

  final lexical = _lexicalBranch(tokens.lexical);
  if (lexical != null) branches.add(lexical);

  final pinyin = _pinyinBranch(tokens.pinyin);
  if (pinyin != null) branches.add(pinyin);

  final initials = _initialsBranch(tokens.initials);
  if (initials != null) branches.add(initials);

  if (includeCrossLingual) {
    final crossLingual = compileCrossLingual(tokens);
    if (crossLingual != null) branches.add(crossLingual);
  }

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
///
/// **调用约定**：本支是**渐进兜底**——[compileMatch] 默认不含它（见其 `includeCrossLingual`），
/// 只有精确查询命中过窄时，调用方才单独用 [compileCrossLingual] 发第二趟。
/// 跨语言支单独成趟的表达式（可选 [scope] 列过滤）；无候选返回 `null`。
String? compileCrossLingual(
  AnalyzerTokens tokens, {
  LocalSearchScope scope = LocalSearchScope.all,
}) {
  final branch = _crossLingualBranch(tokens.crossLingual);
  if (branch == null) return null;
  return scope == LocalSearchScope.metadata ? '{$metadataColumns} : $branch' : branch;
}

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

/// **日文读音分支**（v5，设计文档 §4.2）：把查询里的**拉丁 / 数字词元**拆成字母 bigram **短语**
/// （`"ku ur ra ar ri in"`——要求这些 bigram **连续**，等价于子串检索）后 `AND` 到读音列。
///
/// 为什么是**短语**而不是 `AND`：读数列为整段歌词的罗马字 bigram，`AND`（任意位置）会像当年
/// 拼音音节 `AND` 一样把命中集放大到近乎整库（实测 165 首日文库里任一 3–6 个常见 bigram 组合
/// 都命中 83–85 首）；短语要求**相邻**，正是「查子串」该有的语义（`kurarin` ⊂ `kyuukurarin`）。
///
/// 索引侧读音列存的是「假名 / 汉字读音 → 罗马字」的**字母 bigram**（与 CJK 的字符 bigram 同构），
/// 故 `kurarin` 的 bigram 组能命中 `kyuukurarin` 这类连续子串（子串检索），
/// 而纯汉字歌手名（米津玄師）也能经 Unihan 音训读命中（`kome` / `yone` / `tsu`）。
///
/// 边界：只取长度 ≥ 2 的**非子串脚本**词元（1 字符 bigram 无意义；汉字 / 假名词元由主趟的
/// 字符 bigram 覆盖，不重复）。无可用词元返回 `null`（不加此支）。
/// [scope]=metadata 时只用元数据白名单（其内含 `reading_meta_tok`）。
String? compileReading(
  AnalyzerTokens tokens, {
  LocalSearchScope scope = LocalSearchScope.all,
}) {
  final parts = <String>[];
  for (final token in tokens.lexical) {
    final lower = token.toLowerCase();
    if (lower.length < 2) continue;
    if (lower.runes.any(isIndexedScript)) continue;
    final bigrams = <String>[];
    for (var i = 0; i + 1 < lower.length; i++) {
      bigrams.add(lower.substring(i, i + 2));
    }
    // 单个引号短语 = 相邻 bigram 序列（FTS5 短语语义），等价于对该词元做子串检索。
    if (bigrams.isNotEmpty) parts.add(quoteToken(bigrams.join(' ')));
  }
  if (parts.isEmpty) return null;
  final body = parts.join(' AND ');
  return scope == LocalSearchScope.metadata
      ? '{$metadataColumns} : ($body)'
      : '{$readingColumns} : ($body)';
}

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

  final prefixLast = _isPrefixable(clean.last) && clean.last.length >= minPrefixTokenLength;
  final parts = <String>[];
  for (var k = 0; k < chunks.length; k++) {
    final isLast = k == chunks.length - 1;
    parts.add(isLast && prefixLast ? '${chunks[k]}*' : chunks[k]);
  }
  return parts.join(' AND ');
}

/// 拼音**宽松兜底**支：音节 `AND`（**与位置无关**），末音节 3 字符起加前缀。
///
/// 用途（渐进第二趟）：主支 [compileMatch] 用**相邻短语**（精度高、命中集小），但
/// **漏字 / 换位**（`周伦` → `周杰伦`、`爱我` → `我爱你`）这类「音节齐全但不相邻」的查询需要
/// 位置无关的 `AND` 才能召回——这正是设计 §4.2 期望拼音支提供的容错能力。
/// 仅当短语趟命中不足时才付这笔开销：位置无关的 `AND` 命中集可能很大
/// （30k 实测 `wo ai ni` 任意位置命中 29763/30000、单条 ≈66ms，见 bench/REPORT.md §7）。
///
/// 音节数 <2 返回 `null`（单音节主支本就是前缀形态，无需兜底）。
/// [scope]=metadata 时施加整表达式列过滤（与 [compileMatch] 同规则）。
String? compilePinyinLoose(
  AnalyzerTokens tokens, {
  LocalSearchScope scope = LocalSearchScope.all,
}) {
  final clean = tokens.pinyin
      .map((t) => t.trim())
      .where((t) => t.isNotEmpty)
      .toList();
  if (clean.length < 2) return null;
  final body = _quotedAnd(clean,
      prefixLast: clean.last.length >= minPrefixTokenLength);
  final filtered = '{$pinyinColumns} : ($body)';
  // 元数据范围时，元数据白名单比拼音列集合更窄（只到 pinyin_meta_tok）。
  return scope == LocalSearchScope.metadata
      ? '{$metadataColumns} : ($body)'
      : filtered;
}

/// 拼音分支：`全拼音节` → FTS5 表达式。
///
/// **单音节**：3 字符起 `"wo"*`（前缀，边打边搜）；1–2 字符改精确（见 [minPrefixTokenLength]）。
/// **≥2 音节**：`"wo ai ni"`——**位置相邻短语**（索引侧同一段拼音音节连续入列）。
///
/// 为什么 ≥2 音节改为短语（P5 实测修订，见 `app/core/indexer/bench/REPORT.md`）：
/// 原先的「音节 `AND`（末音节前缀）+ 首音节前缀变体」是**任意位置**的 `AND`，常见拼音
/// 查询会把整个曲库几乎全部命中（30k 语料上 `woaini` 命中 29763/30000），而 FTS5 的
/// `ORDER BY bm25` 必须给全部命中打分——单条查询 131ms，且随曲库线性恶化；
/// 首音节前缀变体是冗余支（语义上被主形态近似覆盖）却独占约 58ms。
/// 短语把「相邻」这一用户真实语义写进查询：命中 4592（30k），延迟 18ms，精度同时更好
/// （用户连写输入本就是一段连续拼音，不相邻的音节匹配纯属噪声）。
///
/// 末音节不再加 `*`：`PinyinSegmenter` 只产出**完整**音节（无法完整切分的输入保留整词，
/// 落到单音节分支），故多音节分支的末音节不存在「打了一半」；实测短语前缀形态
/// （`"wo ai ni"*`）比普通短语更慢（54ms vs 18ms）而召回无增。
String? _pinyinBranch(List<String> terms) {
  final clean = terms
      .map((t) => t.trim())
      .where((t) => t.isNotEmpty)
      .toList();
  if (clean.isEmpty) return null;

  final last = clean.last;
  if (clean.length == 1) {
    // 单音节：3 字符起加前缀（边打边搜）；1–2 字符前缀会把命中集放大到近乎整库。
    final body = _quotedAnd(clean,
        prefixLast: last.length >= minPrefixTokenLength);
    return '{$pinyinColumns} : $body';
  }
  return '{$pinyinColumns} : ${quoteToken(clean.join(' '))}';
}

/// 音节/词元列表 → `"a" AND "b"*`；可对末词元加前缀 `*`（边打边搜）。
String _quotedAnd(
  List<String> terms, {
  bool prefixLast = false,
}) {
  final parts = <String>[];
  for (var i = 0; i < terms.length; i++) {
    final prefixed = i == terms.length - 1 && prefixLast;
    parts.add(prefixed ? '${quoteToken(terms[i])}*' : quoteToken(terms[i]));
  }
  return parts.join(' AND ');
}

/// 首字母串 → `"wan"*`（含空格时逐段 `AND`，末段前缀）；空 / null 返回 null。
/// 首字母分支：**列过滤**命中独立列 `initials_tok`（v3 起）。
///
/// 加 `{initials_tok} :` 前缀是关键——不带列过滤的 `"wan"*` 会去扫**所有**列，
/// 包括拼音列（完 / 万 / 晚…），命中集近乎整库（30k 实测 29985/30000、56ms）。
/// 末段加 `*`（边打边搜）：首字母列空间小（每源每段一个 token），2 字符起可安全前缀。
/// 空 / null 返回 null。
String? _initialsBranch(String? initials) {
  if (initials == null) return null;
  final terms = initials
      .split(RegExp(r'\s+'))
      .where((t) => t.isNotEmpty)
      .toList();
  if (terms.isEmpty) return null;
  final last = terms.last;
  final body = _quotedAnd(terms,
      prefixLast: last.length >= minInitialsPrefixLength);
  // 整体加括号：列过滤与 `OR` 混排时边界更明确（列过滤只作用于本支）。
  return '({$initialsColumns} : $body)';
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

    final prefix = i == clean.length - 1 &&
        _isPrefixable(clean[i]) &&
        clean[i].length >= minPrefixTokenLength;
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

/// 恰为两个**子串脚本**字符的词元（索引 / 查询侧的 bigram 形态）——
/// 脚本集合见 [isIndexedScript]（汉字 / 假名 / 谚文，与原生 `ScriptRanges` 一致）。
bool _isCjkBigram(String token) {
  final runes = token.runes;
  if (runes.length != 2) return false;
  return runes.every(isIndexedScript);
}

/// 拉丁 / 数字词元可加前缀：不含子串脚本字符即为真
/// （分析器输出「子串脚本」与「拉丁/数字」互斥）。
bool _isPrefixable(String token) => !token.runes.any(isIndexedScript);
