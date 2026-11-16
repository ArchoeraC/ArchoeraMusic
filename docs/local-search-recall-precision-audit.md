# 本地曲库搜索：召回精度审计与参照方案

> 状态：**审计 + 首批门控已落地**（2026-11-16）。审计部分为只读分析；
> 已实施的改动见 §5.0「本次已落地的门控一览」，**未做压力测试 / 基准**。
> 范围：**仅本地曲库搜索**（`app/core/indexer/` + `app/lib/services/search/`）。
> 在线多源搜索（`search_page` / 各平台 API）**不在本文范围**——那条链路的召回由服务端决定。
> 关联：[local-search-index-plan.md](local-search-index-plan.md)（架构与验收基线）、
> [cross-lingual-search-upgrade-plan.md](cross-lingual-search-upgrade-plan.md)（跨语言增强）。
> 触发问题：用户反馈「没有可匹配的媒体时仍返回大量无关结果」，以及「搜『爱』出现『恨』」。

---

## 1. 结论摘要

1. **「爱 → 恨」不是语义替换造成的。** 逐字核实：`爱` 的跨语言候选是 `fond / like / love`，
   `恨` 的候选是 `dislike / hate / hatred / resent`，**交集为空**（`data/def_hanzi2en.tsv` 中
   `7231 → "fond like love"`、`6068 → "dislike hate hatred resent"`）；单字查询也**不触发** CJK 容错
   （`CjkVariants` 要求中文字序列长度 ≥ 2，`SearchQuery.cs:363-370`）。
   所以这个现象只可能来自下面三类**宽覆盖误命中**或**索引内容污染**，需要真实数据才能定论（§7）。
2. **真正可确认的严重缺陷是「单字查询无门控」**：主趟的**首字母分支**对单个汉字会生成
   **精确单字母**匹配（`SearchQuery.cs:439-451` + `Pinyin.cs:45-46`），而单字母 token 在真实曲库里
   密集存在（歌词整行「啊 / 哦 / 嗯」、文件名 `track01`、单字标题 `A`/`I`/`K`）。
   合成库（400 首不含「痛」的歌）实测：搜 `痛` → 主趟命中 **400/400**。
3. **第二放大器是 CJK 容错的「删一字」**：`爱情` → `爱` / `情` / `情爱`，且每个变体**带着拼音与首字母支
   重新编译**（`SearchSession.cs:319-336`），等于把两字查询退化成两次单字查询。
   合成库实测：搜 `想你` 主趟 0 条，整个会话返回 **130 条**。
4. **架构层面缺四样东西**（对照 Meilisearch / Lucene / Elasticsearch / Typesense / Solr / Navidrome 均已内置）：
   - **按匹配类型分层**（精确 / 前缀 / 拼音 / 首字母 / 跨语言 / 容错不同池，不共用一个 BM25；
     参照 Meilisearch `ranking_rules`、Navidrome `(token OR token*)`）；
   - **短查询门控**（词长/字数不够就不许放宽——所有成熟引擎的第一道闸；参照 Typesense
     `min_len_1typo=4 / min_len_2typo=7`、ES `Fuzziness.AUTO` 3/6、Lucene `maxQueryFrequency=0.01`、
     Bleve `prefix_length`、pg_trgm 词级阈值 0.6 > 整串 0.3）；
   - **多词最少命中数**（「几个词里必须命中几个」应可分级表达，而不是只有「整趟跑 / 不跑」；
     参照 Solr `mm` 的 `3<90%` 分段表达式、Typesense `drop_tokens_threshold`）；
   - **命中原由归因**（现在 ABI 只回 `docId/trackId/score`，无法判断是谁命中的）。
5. 索引侧另有 6 处已确认的污染入口（§4），其中 **D-3 脏集判定只认 mtime** 与
   **D-4 文件名混入拼音/首字母列** 影响面最大，且**都可以在不碰召回逻辑的前提下独立验证**。

**本次已落地（2026-11-16，未做压力测试）**：M-1 / M-3 / M-5 的门控、M-7 的趟次归因、D-4 的
索引去污，外加一套 8 条断言的正负例回归（`SearchLayerTests.RecallPrecisionGates`）。
`AnalyzerVersion` 12 → 13（D-4 属索引内容变化，触发全量重建）。详见 §5.0 与 §8。

---

## 2. 现状机制（逐项可核对）

### 2.1 查询侧：一趟主查 + 五趟兜底

入口 `SearchSession.ExecuteUncached`（`app/core/indexer/SearchSession.cs:256-344`），
每趟结束用 `result.Items.Count < request.MinExact` 决定是否继续（`MinExact` 默认 1，`SearchSession.cs:27`）：

| # | 趟 | 编译函数 | 触发条件 | 列 |
|---|---|---|---|---|
| 1 | 主趟 | `SearchQuery.CompileMatch`（`SearchQuery.cs:179`） | 总是 | 全部 |
| 2 | 拼音宽松 | `CompilePinyinLoose`（`:147`） | 主趟 < MinExact | `pinyin_*` |
| 2.5 | 日文/韩文读音 | `CompileReading`（`:222`） | 同上 **且** 库画像含日/韩 | `reading_meta_tok`, `lyrics_rom_tok` |
| 3 | 跨语言释义 | `CompileCrossLingual`（`:132`） | 同上 | 全部 |
| 4 | 拉丁模糊 | `CompileFuzzy`（`:279`） | 同上 **且** `fuzzy=true` | 全部 |
| 5 | CJK 删除/换位 | `CjkVariants`（`:302`）→ 逐个 `CompileMatch` | 同上 | 全部 |

**主趟是三条支的平铺 OR**（`JoinBranches`，`SearchQuery.cs:639-649`）：

```
词法支(AND)  OR  拼音支(列过滤)  OR  首字母支(列过滤)   [跨语言支不并入]
```

三条支各自独立召回，结果**进同一个 BM25 池**，靠列权重区分（`FtsStore.cs:63-78`）。

### 2.2 首字母支为何对单字失控（核心缺陷）

`Pinyin.Initials`（`app/core/indexer/Pinyin.cs:45-46`）对**每个 CJK 段**取首字母串：

| 输入 | initials token | 说明 |
|---|---|---|
| `恨` | `h` | 单字 → 单字母 |
| `某人` | `mr` | 一行歌词 → 两个字母 |
| `晴天` | `qt` | |
| `啊` | `a` | **歌词里极常见的整行语气词** |
| `t164` / `track01` | `t` + `164` / `track01` | 文件名（见 D-4） |

`InitialsBranch`（`SearchQuery.cs:439-451`）在末词元 `>= MinInitialsPrefixLength`（=2，`:63`）时加 `*`，
**否则按精确 term 匹配**。于是任何**单字 CJK 查询**都会生成一个**精确单字母**：

```
「爱」→ ("爱" OR pinyin:{ai}  OR {initials_*}: "a")
「恨」→ ("恨" OR pinyin:{hen*} OR {initials_*}: "h")   ← 注意 pinyin 还加了前缀 *
「痛」→ ("痛" OR pinyin:{tong*} OR {initials_*}: "t")
```

> **合成库复现**（400 首，字池刻意不含「痛」）：`initials_meta_tok` 中出现 `t`，`doc=400`，
> 即整库 400 首全部命中，`CompileMatch` 返回 400 条。
> 这是「没有匹配媒体却返回一堆」最直接、最可复现的成因。
> 同库查 `恨`：`initials` 支 345 条、主趟 0 条（该库无 `h` 开头名字）、跨语言 0 条 → 全部被
> 短路逻辑吸收，正好说明**同一机制在不同语料上表现完全不同**，必须用真实数据判定。

### 2.3 拼音支的前缀无门控

`PinyinBranch`（`SearchQuery.cs:430-437`）：

- 单音节：`clean[^1].Length >= MinPrefixTokenLength`（=3）时加 `*`。
- **多音节**：整串用引号短语，**不加前缀**。

也就是 `恨 → hen*` 会命中 `henry`；`ai`（2 字符）不加前缀，精确匹配 `ai`。
这是「短拼音 + 前缀」的典型过宽组合，成熟引擎都用**词长 → 允许错误数**的阶梯来卡（§3）。

### 2.4 跨语言支无强度门控

`Analyzer.CollectCrossLingual`（`Analyzer.cs:217-251`）对 CJK 段**逐字**查 `def_hanzi2en`，
把释义词全部塞进候选（预算 `CrossLingualBudget = 32`，`Analyzer.cs:121`）：

| 查询 | 候选 |
|---|---|
| `爱` | fond, like, love |
| `恨` | dislike, hate, hatred, resent |
| `痛` | ache, bitter, pain, sad, sorry |
| `好` | excellent, fine, good, well |
| `人` | else, man, mankind, people, someone |

反向（拉丁 → 汉字）同样发散：`love → 喜 恋 愛 憘 憙 戀 爱 疼`（8 个），`good → 佳 功 吉 咊 善 塡 填 好`。

`FilterCrossLingual`（`SearchSession.cs:353-363`）**只按脚本画像裁剪**（库里有汉字吗 / 有拉丁吗），
不看语义强度、不看词频。对单字查询这几乎等于「无条件放宽」。

### 2.5 短路条件的悖论

`MinExact = 1` 的效果是**双向**的：

- 主趟**有 1 条**（哪怕只是首字母 `a` 的误命中）→ 后面的严格趟全部不跑，用户看不到更好的结果；
- 主趟**0 条** → 一路放宽到跨语言 / 容错，噪声反而全量涌入。

「有弱命中就停」与「无命中就放宽」这两条同时存在，使结果质量对语料分布极度敏感——
这正是「同一份代码在不同曲库上表现差异巨大」的机制原因。

### 2.6 排序：单池 BM25

`FtsStore.Search`（`FtsStore.cs:258-292`）一次性 `MATCH + bm25(权重)` 全排序。列权重
（`FtsStore.cs:63-78`）：title 4.0 / artist 3.0 / album 2.0 / lyrics 1.5 / lyrics_tr 1.0 /
lyrics_rom 0.5 / pinyin_meta 2.0 / pinyin_lyrics 1.5 / reading_meta 2.0 / filename 1.0 /
initials_meta 2.0 / initials_lyrics 1.5。

**问题**：`initials_meta = 2.0` 与 `pinyin_meta = 2.0` 同档。首字母本就是「同一批字段的另一种写法」，
但**它是丢失信息的写法**——`a` 可能是「爱」也可能是「啊」。用 2.0 的权重让它与真实词法命中
在同一池里竞争，等于给弱信号高优先级。除读音趟有 `ReadingRanker` 重排（`ReadingRanker.cs:27-33`）外，
其余各趟都没有匹配类型档位。

---

## 3. 参照实现：成熟引擎如何防止「短查询被过度放宽」

> 选型标准：**能直接映射到 FTS5 + 现有六趟架构**、**参数可抄**、**不引入服务本体**。
> 桌面端不可能内嵌 Meilisearch/Typesense 服务，但它们的**规则**可以照搬。

### 3.1 Meilisearch（`crates/milli`）——最贴合的目标形态

| 机制 | 位置 | 具体做法 | 对我们的映射 |
|---|---|---|---|
| **按词长分级允许错误数** | `meilisearch-types/src/settings.rs` 的 `MinWordSizeTyposSetting` | `oneTypo` 默认 **5**、`twoTypos` 默认 **9**：「apple」允许 1 个错，「app」不允许；校验要求 `twoTypos >= oneTypo` | `CompileFuzzy` / `CompilePinyinLoose` 之前先算词长 → 0/1 个编辑 |
| **前缀只作用于最后一个词** | `search/new/query_term/parse_query.rs` | `peekable.peek().is_some()` → 非末词一律**非前缀**；末词才 `is_prefix` | 我们已对「末词元」加 `*`，但**没有排除短词**，需补长度门 |
| **零/一/二错分层枚举** | `search/new/query_term/mod.rs`（`zero_typo_subset` / `one_typo_subset` / `two_typo_subset`） | 三种子集各自独立，用 `NTypoTermSubset` 交集/并集运算；**不是**一个大 OR | 对应我们「精确 / 拼音 / 容错」三支应各自成趟、各自成池 |
| **候选数量硬上限** | `search/new/limits.rs` | `MAX_ONE_TYPO_COUNT = 150`、`MAX_TWO_TYPOS_COUNT = 50`、`MAX_PREFIX_COUNT = 1000` | 我们有 `DefaultMaxFuzzyVariants = 500`（`SearchQuery.cs:51`），但**按变体数**而非**按候选词**——语义不同，值得对齐 |
| **排序规则是显式列表** | `meilisearch-types/src/settings.rs` 的 `ranking_rules` 默认值 | `["words","typo","proximity","attributeRank","sort","wordPosition","exactness"]` | 我们只有 BM25 + 一处 `ReadingRanker`；可引入「匹配类型」作为第一排序键 |

**可直接抄的三条**：① 5/9 词长阶梯；② 前缀只给末词且要有最小长度；③ 匹配类型作为高于 BM25 的排序键。

### 3.2 Elasticsearch `Fuzziness.AUTO`——最小的改动成本

`Fuzziness.java#asDistance(String)`：

```java
final int len = termLen(text);
if (len < lowDistance) return 0;        // 默认 lowDistance = 3
else if (len < highDistance) return 1;  // 默认 highDistance = 6
else return 2;
```

即 **<3 字符 → 0 个编辑；3–5 → 1；≥6 → 2**。这套阈值被大量产品验证过，且实现只有三行。
我们的拉丁模糊趟目前**完全不做词长门控**（`CompileFuzzy` 对任意长度词元展开）。

### 3.3 Apache Lucene

| 机制 | 位置 | 做法 |
|---|---|---|
| `FuzzyQuery` 自适应 | `lucene/core/.../FuzzyQuery.java` | 文档明确：`maxEdits` 必须小于较短 term 的长度——「`abcd` 配 `maxEdits=2` 不会匹配 `ab`」。防止短词被编辑距离吃掉 |
| `DirectSpellChecker` 的多重门 | `lucene/suggest/.../DirectSpellChecker.java` | `minQueryLength` 默认 **4**（更短不纠错）、`maxQueryFrequency` 默认 **0.01**（查询词在 >1% 文档中出现则**不纠错**——因为高频词本身就是用户想要的）、`maxEdits`、`minPrefix`（默认 1）、`maxInspections`（默认 5） |

> **`maxQueryFrequency` 这个思路我们完全没有**，但它恰好命中本项目的病灶：
> 高频单字母/单音节 token（`a`、`t`、`hen`）正是「不该被当成模糊目标」的词。
> 索引里现成有 `fts5vocab`（`FtsStore.LoadFuzzyVocabulary`，`FtsStore.cs:357-399` 已经在读
> `term/doc` 计数），**实现成本为零**：`doc/total > 阈值` 的 term 直接不参与放宽。

### 3.4 Typesense

| 参数 | 默认 | 位置 | 含义 |
|---|---|---|---|
| `min_len_1typo` | **4** | `include/collection.h` | 短于 4 字符不做 1 个错 |
| `min_len_2typo` | **7** | 同上 | 短于 7 字符不做 2 个错 |
| `drop_tokens_threshold` | **1** | `include/index.h`（`DROP_TOKENS_THRESHOLD = 1`） | 命中数低于此值才**逐个丢弃**查询中最不匹配的 token |
| `typo_tokens_threshold` | **1** | 同上（`TYPO_TOKENS_THRESHOLD = 1`） | 命中数低于此值才启用拼写纠错 |
| `prioritize_exact_match` | **true** | 同上 | 精确命中强制排在纠正命中之前 |
| `num_typos` / `prefixes` / `infixes` | `[2]` / `[true]` / `off` | 同上 | **按字段**配置，可对 title 宽松、对 lyrics 严格 |

`Index::get_bounded_typo_cost`（`src/index.cpp`）给出可直接抄的公式：

```cpp
if (token_len < min_len_1typo) return 0;               // 太短：禁止纠错
if (token_len < min_len_2typo) return min(max_cost, 1); // 只允许 1 个错
return min(max_cost, 2);
```

> **`drop_tokens_threshold` 与我们的 `MinExact` 是相反策略**：我们是「丢**趟**」（整支兜底不跑），
> Typesense 是「丢**词**」（保留多词查询里最匹配的那个词）。后者对「`夜 雨 恨`」这类多词查询
> 更合理——我们现在会因为整句不命中而放宽到跨语言，把整库捞进来。

### 3.5 Groonga —— `match_escalation_threshold`

`doc/source/reference/commands/select.rst`：命中数 **≤** 阈值时才升级检索策略，
默认 **0**（= 只有 0 命中才升级）；`-1` 表示**永不升级**。

这正是我们 `MinExact` 的原始思想，但 Groonga 额外把「升级」限制成**三种明确的策略**
（完全一致 → 非分词（前缀） → 部分一致），每级都有清晰的语义边界。
我们的六趟**语义边界模糊**（拼音宽松 / 跨语言 / 容错都属于「更松」，但松的方向不同，
且都共用同一套编译函数），这是结果不可解释的根源。

### 3.6 Navidrome —— 同为「音乐库 + FTS5」，最接近的工程参照

`persistence/sql_search_fts.go`（Go，直接对 SQLite FTS5，与我们的技术栈几乎同构）：

| 机制 | 做法 | 对我们的价值 |
|---|---|---|
| **`(token OR token*)` 双形态** | 每个词元同时给「精确」与「前缀」两种写法，注释明确：`exact ⊂ prefix`，命中集合不变，但让 **BM25 给精确 term 更高的 IDF 分**，从而把字面命中排在纯前缀命中之前 | **极高**。我们目前是「要么精确要么前缀」，没有双形态；这是**零召回代价的排序改进** |
| **查询退化检测 `ftsQueryDegraded`** | 若所有有效 token 长度 ≤ 2（且原文含被剥离的特殊字符），判定「查询已退化」→ **直接回退 LIKE**，不放宽到 FTS | **极高**。这就是我们缺的「短查询门控」，且实现只需数 token 长度 |
| **显式 `AND` 连接** | 注释：FTS5 空格隐式 AND 与括号 OR 组混用会出错，故显式写 `AND` | 我们 `LexicalBranch` 已显式 `AND`，但 `JoinBranches` 的 OR 组合值得复核 |
| **按表定义 BM25 列权重** | `ftsColumnDefs` 声明式表（title 10.0 / album 5.0 / artist 3.0 / search_participants 2.0 / search_normalized 1.0），`init()` 预计算列过滤与权重串 | 我们是硬编码数组（`FtsStore.cs:63-78`），可对齐成声明式，便于评审权重 |
| **标点内嵌名处理** | `R.E.M.` → 短语；`a-ha` / `AC/DC` → `("a ha" OR aha*)` | 中英混排曲库的 `Jay-Z`、`AC/DC` 会踩到，值得借鉴 |
| **CJK 显式分支** | `containsCJK()` 判定后走不同策略（unicode61 对 CJK 会把整句当一个 token） | 我们已用 CJK bigram+unigram 解决，可作交叉验证 |

### 3.7 Apache Solr —— `mm`（Minimum Should Match）

`dismax-query-parser.adoc` §`mm`：默认 `q.op=AND` 时 `mm=100%`（全部词必中），
否则 `mm=0%`（全部可选）。关键是它把「要匹配几个词」表达成**可分级公式**而不只是一个布尔：

| 写法 | 含义 |
|---|---|
| `3` | 至少 3 个子句命中（与总词数无关） |
| `-2` | 至少「总数 − 2」个命中 |
| `75%` | 至少 75%（向下取整）命中 |
| `-25%` | 最多允许 25% 缺失 |
| `3<90%` | **≤3 个词时全要；>3 个词时只要 90%** |
| `2<-25% 9<-3` | 分段条件：1–2 全要；3–9 最多缺 25%；>9 最多缺 3 个 |

**对本项目的直接价值**：我们现在的 `MinExact` 只有一个标量（默认 1），
既管「停止兜底」又隐含「至少要几个命中」，语义含混。
Solr 的 `3<90%` 这种**分段条件**正好表达我们需要的策略：

```
1 个词 → 必须命中（不给任何放宽）
2 个词 → 必须命中 ≥2（禁止退化成单字，治 M-3）
≥3 个词 → 允许命中 ≥ ceil(2/3)，其余词走兜底
```

### 3.8 Bleve 与 PostgreSQL `pg_trgm` —— 两个「短词不该纠错」的独立佐证

| 实现 | 机制 | 数值 |
|---|---|---|
| **Bleve**（Go，FTS 库）`search/query/fuzzy.go` | `FuzzyQuery` 的 `prefix_length` + `fuzziness`；文档明确「默认 fuzziness = 1」，且 `prefix_length` 内的字符**不参与**编辑距离——等价于「短词根本没机会纠错」 | `fuzziness` 默认 **1** |
| **PostgreSQL `pg_trgm`**（`contrib/pg_trgm/trgm_op.c`） | 三元组相似度的三个独立阈值档：整串 / 词级 / 严格词级 | `similarity_threshold = 0.3`、`word_similarity_threshold = 0.6`、`strict_word_similarity_threshold = 0.5`（**词级阈值显著高于整串**） |

> `pg_trgm` 的「词级阈值 0.6 > 整串阈值 0.3」是同一思想的第三种表述：
> **越短的比较单元，越需要更高的相似度门槛**。
> 我们的问题正好相反——`a` / `t` / `hen` 这些极短单元用的是**最低**的门槛（精确匹配即可命中）。
> Bleve 的 `prefix_length` 则给出另一种实现路径：把前 N 个字符**冻结**，只有剩余部分允许编辑，
> 天然阻止短词被纠错（因为剩余长度为 0）。

### 3.9 参照方案对照表（按「对本项目的性价比」排序）

| 优先级 | 借鉴对象 | 具体机制 | 解决我们的哪个失效模式 |
|---|---|---|---|
| **P0-1** | Navidrome `ftsQueryDegraded` + Bleve `prefix_length` | 有效 token 全 ≤2 字符（且原文含被剥离的字符）→ 判定退化，禁止放宽 | M-1 单字查询无门控 / M-3 |
| **P0-2** | Typesense `get_bounded_typo_cost` | 词长 → 允许编辑数（4/7） | M-2 拼音前缀无门控 / M-5 模糊无门控 |
| **P0-3** | Lucene `maxQueryFrequency` | 高频 term 不纠错（用现成 `fts5vocab`） | M-1（`a`/`t` 这类高频单字母） |
| **P0-4** | Solr `mm` 分段条件 | 「词数 → 最少命中数」写成 `3<90%` 形式 | M-3 两字退化为单字、M-6 短路悖论 |
| **P1-1** | Navidrome `(token OR token*)` | 双形态让 BM25 偏向字面命中 | M-4 单池排序、弱信号压过强信号 |
| **P1-2** | Meilisearch `ranking_rules` | 匹配类型作为高于 BM25 的第一排序键 | M-4（与 `ReadingRanker` 同思路，扩到全趟） |
| **P2-1** | Typesense `drop_tokens_threshold` | 命中不足时先丢「最不匹配的词」而非整趟放宽 | M-3 短路悖论 |
| **P2-2** | Groonga `match_escalation` | 把「放宽」限定成语义明确的 2–3 级 | 六趟语义边界模糊 |
| **P2-3** | pg_trgm 词级阈值 | 短比较单元用更高相似度门槛 | 校准 CJK bigram 的 df 阈值（§9.2 未决 3） |

### 3.10 参照来源（便于复核，均为 2026-11 时点的 `master`/`main`）

| 项目 | 许可证 | 具体文件 | 我们抄的是 |
|---|---|---|---|
| [meilisearch/meilisearch](https://github.com/meilisearch/meilisearch) | MIT | `crates/milli/src/search/new/query_term/{mod,parse_query,compute_derivations,ntypo_subset}.rs`、`crates/milli/src/search/new/limits.rs`、`crates/meilisearch-types/src/settings.rs`（`MinWordSizeTyposSetting`、`ranking_rules`） | 词长→错误数阶梯 5/9、前缀只给末词、零/一/二错分层、`ranking_rules` 排序键列表 |
| [elastic/elasticsearch](https://github.com/elastic/elasticsearch) | SSPL/Elastic | `server/src/main/java/org/elasticsearch/common/unit/Fuzziness.java`（`asDistance`） | `AUTO` 阈值 3/6 |
| [apache/lucene](https://github.com/apache/lucene) | Apache-2.0 | `lucene/core/.../search/FuzzyQuery.java`、`lucene/suggest/.../search/spell/DirectSpellChecker.java` | 「maxEdits 必须小于较短 term 长度」、`maxQueryFrequency=0.01`、`minQueryLength=4` |
| [typesense/typesense](https://github.com/typesense/typesense) | GPL-3.0 | `include/collection.h`（`min_len_1typo=4`/`min_len_2typo=7`）、`include/index.h`（`DROP_TOKENS_THRESHOLD`/`TYPO_TOKENS_THRESHOLD`）、`src/index.cpp`（`get_bounded_typo_cost`） | 词长阶梯公式、`drop_tokens_threshold`、`prioritize_exact_match` |
| [groonga/groonga](https://github.com/groonga/groonga) | LGPL-2.1 | `doc/source/reference/commands/select.rst`（`match_escalation_threshold` / `match_escalation`）、`doc/source/spec/search.rst` | 「命中数 ≤ 阈值才升级」+ 升级策略分级 |
| [navidrome/navidrome](https://github.com/navidrome/navidrome) | GPL-3.0 | `persistence/sql_search_fts.go`、`db/migrations/20260220173400_add_fts5_search.go` | `ftsQueryDegraded`（≤2 字符退化）、`(token OR token*)` 双形态、声明式 BM25 列权重表 |
| [apache/solr](https://github.com/apache/solr) | Apache-2.0 | `solr/solr-ref-guide/modules/query-guide/pages/dismax-query-parser.adoc`（`mm`） | 多词查询的「最少命中词数」分段表达式 |
| [blevesearch/bleve](https://github.com/blevesearch/bleve) | Apache-2.0 | `search/query/fuzzy.go` | `prefix_length` 冻结前缀 → 短词天然不纠错 |
| [postgres/postgres](https://github.com/postgres/postgres) | PostgreSQL | `contrib/pg_trgm/trgm_op.c` | 词级阈值 0.6 > 整串 0.3（短单元要更高门槛） |

> **许可证提示**：Typesense / Navidrome 是 GPL-3.0，Groonga 是 LGPL-2.1。
> 本项目 **AGPL-3.0-or-later**，与本仓库兼容性需按 `docs/licensing.md` 与
> `docs/license-audit-2026-11.md` 的既有流程评估——**但本文只借鉴「参数与规则」，
> 不复制代码**，属独立实现，不构成衍生作品。若后续要移植代码片段，必须先过许可证评审。

---

## 4. 索引侧污染入口（与「数据污染」对应）

| ID | 问题 | 位置 | 机制 | 验证方式 |
|---|---|---|---|---|
| **D-1** | LRC 分层**按行位置猜** | `app/core/shared/lyrics/LrcReader.cs:390-445`（`SplitLayers` / `ClassifyGroup`） | 同一时间戳的第 1 行=原文、第 2 行=译文、第 3 行=音译；仅用「是否纯拉丁」做一次对调修正 | 取一份真实多语 LRC，打印三层输出对照原文 |
| **D-2** | 内嵌 + 侧车**并集** | `IndexerEngine.cs:392-398`（`JoinLayers`） | **完全相同**才去重；部分重叠（旧版歌词 + 新版侧车）两份都入索引 | 构造「内嵌=旧版、侧车=新版」的曲目，搜旧版独有词应**不命中**却命中 |
| **D-3** | 脏集只认 `file_mtime` + lrc `mtime/size` | `IndexerEngine.cs:188-191` | 标题/歌手/歌词被改写但 mtime 未变（或 mtime 精度/时区导致相等）→ 旧词元永久保留 | 直接改 `library.db` 的 `tracks.title`（不动文件），增量后搜新标题应命中却未命中 |
| **D-4** | **文件名混入拼音/首字母列** | `IndexerEngine.cs:365`、`:369`（`CombinePinyin(title, artist, album, filename)` / `CombineInitials(...)`） | 文件名已被独立索引到 `filename_tok`，却又进 `pinyin_meta_tok` / `initials_meta_tok` | 看 §7 的 `fts5vocab` 输出：`initials_meta_tok` 里出现 `t` / `164` 之类即中 |
| **D-5** | 日文汉字标题走中文拼音 | `Analyzer.cs:293-306`（`AddCjkSegment`） | `米津玄師` → `mi jin xuan shi`；纯汉字日文标题（无假名）不产读音列 | 对日文曲库统计 `pinyin_meta_tok` 非空但 `reading_meta_tok` 为空的比例 |
| **D-6** | 折叠链单向改写 | `Analyzer.cs:361-384`（`Normalize`） | NFKC → accent fold → variant fold → ToolGood 繁简，链式改写可能改动原意（尤其是非中文字符） | 抽样比对「原始标题」与「入库 token」的可读性 |

> **D-4 与 D-1/D-2/D-3 是「数据污染」的四条主线索**，且都不依赖召回逻辑，可以**独立先修**。
> 其中 D-4 修起来最安全（只需从 `CombinePinyin/CombineInitials` 里去掉 `filename` 参数，
> `filename_tok` 列不受影响），但**仍需评审确认**：去掉后「文件名搜歌」是否仍完整
> （答：`filename_tok` 本来就是整词索引，不依赖拼音列）。

---

## 5. 失效模式清单（供真实数据逐条验证）

> **实施状态（2026-11-16）**：M-1 / M-3 / M-5 已按 §6.2 落地门控，M-7 已落地归因，
> D-4 已修复。逐项见表内「状态」列；**均未做压力测试，只保证编译与既有回归全绿**。
> 真实库上的效果仍需 §7 诊断复核。

| ID | 失效模式 | 机制位置 | 合成库是否复现 | 状态 | 真实库待验 |
|---|---|---|---|---|---|
| **M-1** | 单字查询命中整库 | §2.2 首字母支精确单字母 | ✅ 400/400 | ✅ **已修**：`MinInitialsBranchLength = 2`（单字母首字母串不生成该支） | 统计 `initials_meta_tok` 单字母 term 的 `doc` 覆盖率 |
| **M-2** | 短拼音前缀过宽 | §2.3 `hen*` → `henry` | ✅ | ⬜ 未改（保留现状，待真实数据定档） | 统计 3–4 字符拼音的命中数分布 |
| **M-3** | 两字查询退化为两次单字 | §2.5 / `SearchSession.cs:319-341` | ✅ 130 条 | ✅ **已修**：`MinCjkFuzzyLength = 3`（两字不生成删字变体） | 对比 `MinExact=1` 与 `=50` 的结果集差异 |
| **M-4** | 首字母/拼音命中压过词法命中 | §2.6 同池 BM25，`initials_meta=2.0` | ⚠️ 部分 | ⬜ 未改（分层排序是较大改动，留给 S3） | 取「字面完全命中」的曲目，看其排名是否被非字面命中的歌挤下 |
| **M-5** | 跨语言释义对单字无条件发散 | §2.4 | ✅ | ✅ **已修**：`MinCrossLingualCjkLength = 2`（单字不生成英文释义方向） | 统计单字查询的跨语言趟命中数与相关性 |
| **M-6** | 「一命中就停」掩盖更好结果 | §2.5 | — | ⬜ 未改（需改 `MinExact` 语义，影响 UI 结果数显示） | 对同一查询比较 `MinExact=1 / 50 / 500` 的 top-10 |
| **M-7** | 结果无归因，无法排障 | `IndexerJson.cs:191-209` | — | ✅ **已修**：`SearchHit.Pass` + JSON `pass` 字段 + Dart `LocalSearchPass` | 用真实查询核对归因是否符合预期 |
| **M-8** | 索引残留（D-1~D-3） | §4 | — | ⬜ 未改（需 schema 变更 + 全量重建） | 见 §7 诊断脚本 |

### 5.0 本次已落地的门控一览（便于评审对照代码）

| 常量 | 位置 | 值 | 作用 |
|---|---|---|---|
| `SearchQuery.MinInitialsBranchLength` | `SearchQuery.cs` | **2** | 单字母首字母串不生成首字母支 → 单字查询不再整库命中（M-1） |
| `SearchQuery.MinCrossLingualCjkLength` | `SearchQuery.cs` | **2** | 单字查询丢掉「汉字 → 英文释义」方向（M-5） |
| `SearchQuery.MinCjkFuzzyLength` | `SearchQuery.cs` | **3** | 两字查询不生成删字 / 换位变体（M-3） |
| `SearchQuery.MinFuzzyWordLength` | `SearchQuery.cs` | **3** | 2 字符拉丁词不做编辑距离扩展 |
| `AnalyzerVersion` | `Analyzer.cs` | **12 → 13** | D-4 去掉文件名混入拼音 / 首字母列，需全量重建 |

**刻意未修的**（避免在无真实数据时用感觉换召回）：
- `MinFuzzyWordLength` 取 **3**（ES `AUTO` 的边界）而不是 Typesense 的 4——因为取 4 会砍掉
  3 字符词的拼音召回，回归用例 `FuzzyVocabularyRecall`（`woo` → `wo` ⊂ 拼音列）是其唯一覆盖。
- 首字母支**整体保留**（只是不支持单字母）：`qt` / `wan` 这类真实检索完全不受影响。
- 跨语言支对 ≥2 字的释义**完全保留**：单字发散是主要噪声源，多字释义显著更聚焦。

### 5.1 关于「爱 → 恨」的排查建议（不要先改逻辑）

按 §1 第 1 条的排除结果，剩下三种可能，**按概率从高到低**：

1. **M-1 的宽覆盖误命中**：搜 `爱` 时首字母支 `a` 命中大量含「啊」的歌词，其中恰好有「恨」的歌，
   用户看到的是「一堆不相关结果里有一条像反义」。→ 用 §7 的逐支诊断确认命中字段。
   **该路径已在本次修复中关闭**，可用新增负例 `RecallPrecisionGates` 复核。
2. **M-5 的跨语言发散**：某首英文歌歌词同时含 `love` 与 `hate`（流行歌极常见），
   跨语言支命中 `love` 把它带进来，用户看到标题里没有「爱」却出现。
   **单字方向已关闭**；若该歌是经 ≥2 字查询召回的，仍属预期行为。
3. **D-1/D-2/D-3 的索引污染**：那首歌的索引里真的存在「爱」（来自旧歌词 / 误分层译文），
   而当前文件已经不含。→ 对比「库里此刻的歌词」与「索引里的 token」即可判定。**未修**。

**结论：本次修复覆盖了机制上可确定的路径（M-1 / M-3 / M-5 的单字与两字部分、D-4），
但 D-1~D-3 的索引污染与 M-4/M-6 的排序问题仍需真实 `search.db` 才能定档。**
必须先把 M-7（归因）与 §7 的诊断跑通。

---

## 6. 目标设计（待评审，不含实现）

### 6.1 分层原则

```
第 0 层  硬门控（不做任何放宽的前提判断）
        ├─ 查询长度 / 词数 / 是否退化（M-1、M-3）
        └─ 高频 term 检测（Lucene maxQueryFrequency 思路，M-1、M-2）
第 1 层  字面精确（词法，含 CJK bigram 短语）        ← 必须独立成池
第 2 层  字面前缀（仅末词、且有最小长度）            ← 与第 1 层同池但低档
第 3 层  读音改写（拼音 / 首字母 / 日韩读音）        ← 独立成池，降档
第 4 层  跨语言释义
第 5 层  编辑距离容错（受词长阶梯约束）
第 6 层  CJK 删除 / 换位
```

**关键改动**：第 1–2 层和第 3–6 层**不能共用一个 BM25 池**。现在的实现是主趟内三支平铺 OR，
`initials_meta = 2.0` 让第 3 层与第 1 层平权竞争。参照 Meilisearch 的 `ranking_rules`，
**匹配层本身应当是比 BM25 更高优先级的排序键**（与现有 `ReadingRanker` 同思路，`ReadingRanker.cs:27-33`
已经证明这个模式在本项目可行）。

### 6.2 门控参数草案（全部可配置、可回退）

| 门控 | 草案值 | 依据 | 影响 |
|---|---|---|---|
| 首字母支最小长度 | **≥2 字符**（`a` 不生成首字母支） | Navidrome `ftsQueryDegraded`（≤2 退化）+ Typesense `min_len_1typo=4` | **直接消除 M-1**；不影响 `wan` / `qt` 这类真实首字母检索 |
| 首字母支单字母 `*` | **不生成** | 同上 | 同上 |
| 拼音前缀最小长度 | 保持 3（已是）**且**该拼音音节数 ≥1 | 现状 | 无变化 |
| 拉丁模糊最小长度 | **4**（1 错）/ **7**（2 错，本项目目前只有 ≤1） | Typesense `min_len_1typo=4` / `min_len_2typo=7`；ES `AUTO` 3/6 | `abcxyz` 这类长词仍可纠错，`ai`/`go`/`ye` 不再纠错 |
| 高频 term 不纠错 | `doc/total > 1%` | Lucene `maxQueryFrequency = 0.01` | 用现成 `fts5vocab` 计数，零额外成本 |
| CJK 容错触发 | 中文字序列 **≥3**（现 ≥2） | 两字删一字必然退化为单字（M-3） | `爱情` 不再生成 `爱`/`情`；`我的爱`（3 字）仍可用 |
| 跨语言支单字 | **禁止**（仅 ≥2 字或拉丁词） | §2.4 单字发散 | 直接消除 M-5 的单字部分 |
| `MinExact` 语义 | 改为「**字面层**命中数 ≥ N 才停止」而非「任意层」 | Groonga `match_escalation_threshold=0` + Typesense `typo_tokens_threshold=1` | 消除 M-6：首字母误命中不再短路真正的字面检索 |
| 最少命中词数（多词查询） | 词数 1 → 1（不放开）；2 → 2（禁止退化）；≥3 → `ceil(2n/3)` | Solr `mm` 分段条件 `3<90%` + Typesense `drop_tokens_threshold=1` | 消除 M-3 的多词退化，且不需要「丢趟」 |
| 前缀冻结（可选，与上二选一） | 前 `prefix_length` 个字符必须精确，其余才允许编辑 | Bleve `FuzzyQuery.prefix_length` | 与「拉丁模糊最小长度」互为替代实现，二者择一即可 |

> **每一项都能单独回退**，且互不依赖——建议按「一个门控 = 一次改动 = 一组黄金向量」推进，
> 不做「一次性重写查询层」。

### 6.3 归因（M-7）

最小可行改动是**扩展 ABI 返回值**（不改 schema、不重编索引）：

```jsonc
// indexer_query 现有：items: [{ docId, trackId, score }]
// 目标：每条命中附命中信息
{ "docId": 42, "trackId": "…", "score": -12.3,
  "pass": "lexical",              // lexical | prefix | pinyin | initials | reading | crossLingual | fuzzy | cjkFuzzy
  "field": "lyrics_tok",          // 命中的列（可用 FTS5 的 auxiliary function 或逐列复核得出）
  "match": "恨" }                 // 实际命中的词元（便于排查「爱→恨」类问题）
```

实现路径有两条，**二选一即可**：
1. **逐趟返回**：每趟本来就在 `Merge` 里独立执行（`SearchSession.cs:262-269`），把「趟名」带上即可，
   `field` 可用 `FtsStore` 的列过滤**逐列复核**（候选集已 ≤ limit，成本可控）。
2. **FTS5 `highlight()`/`snippet()`**：contentless 表不可用，故只有路径 1 可行。

> 注意：`contentless_delete=1` 的 FTS 无法回读原文（`FtsStore.cs:18-25` 注释已说明），
> 这正是 `reading_tok` 需要单独存副本的原因（`search_docs` v6）。若要在 UI 显示「命中哪个字段」，
> 需要类似地为「命中列」存一份最小元数据，**或**在查询时逐列复核（推荐后者，不改 schema）。

### 6.4 索引侧修复（D-1~D-6，独立于查询逻辑）

| ID | 建议 | 风险 |
|---|---|---|
| D-1 | 低置信分层**不入搜索字段**（宁可少召回）：同一时间戳多行时，只取第 1 行入原文列；其余行标记来源但权重归零，或仅在显式 `.trans.lrc` 存在时才启用译文列 | 会降低「自动识别双语歌词」的召回，需真实数据评估覆盖率 |
| D-2 | 侧车**优先**而非并集（或按 `lrc_mtime` 取新者） | 内嵌歌词独有的内容会丢，需确认扫描器已把侧车完整覆盖 |
| D-3 | 脏集加**内容指纹**（规范化后的 title/artist/album/lyrics 各层 hash） | 需 schema 变更 + 全量重建；成本在构建期，不在查询期 |
| D-4 | `CombinePinyin/CombineInitials` **去掉 filename 参数** | 极低（`filename_tok` 独立存在） |

**实施状态（2026-11-16）**：
- **D-4 已修**：`IndexerEngine.BuildTokens` 不再把 `filename` 传给 `CombinePinyin/CombineInitials`，
  `AnalyzerVersion` 12 → 13（触发全量重建）。`filename` 仍独立进 `filename_tok` 与 `reading_meta_tok`，
  「用文件名搜歌」不受影响。
- **D-1 / D-2 / D-3 / D-5 / D-6 未修**：都需真实库评估（分层覆盖率 / 侧车覆盖率 / 内容指纹的
  schema 变更 / 日文曲库占比 / 折叠链实际改写样本），在拿到数据前改动等于用感觉换召回。
| D-5 | 日文曲目**不给汉字段产中文拼音**（或另开一列），改用 Unihan 日语音读 | 需 `AnalyzerVersion` 递增；影响日文曲库召回方式 |
| D-6 | 折叠链加**可回溯日志**（调试模式记录「原串 → 归一串」） | 无功能影响，纯诊断 |

---

## 7. 数据需求与零改码诊断（**在动代码之前做**）

> 前提：服务器属于他人，只能争取到数据库。下列诊断**全部是只读 SQL / 现成 CLI**，无需改代码、无需重编。

### 7.1 需要拿到的文件

| 文件 | 必要性 | 用途 |
|---|---|---|
| `library.db`（**加 `-wal` / `-shm`**） | **必需** | 源真值，判断 D-2/D-3（索引与源是否一致） |
| `search.db`（**加 `-wal` / `-shm`**） | **必需** | 索引侧污染与 token 分布（M-1/M-2/D-4/D-5） |
| `last_session.json` | 可选 | 复现当时的开关状态（是否开了 `.lrc` 索引 / 罗马音生成） |
| 一份**出问题的查询清单**（查询串 + 用户期望 + 实际看到的歌） | **强烈建议** | 没有这个就只能靠统计猜；有它可以直接定位到趟/字段 |

> ⚠️ 三个文件必须**同一时刻**取，否则 WAL 未合并会导致 `search.db` 与 `library.db` 对不上
> （`FtsStore` 明确用 `Pooling=False` 读当前文件，`tests/EndToEnd.cs:764-772` 有同款注释）。

### 7.2 诊断 A：单字母 / 短 token 覆盖（对应 M-1、M-2、D-4）

```sql
-- 在 search.db 上执行（只读；temp 表在内存，不改主库）
CREATE VIRTUAL TABLE temp.v USING fts5vocab(main, search_fts, 'col');

-- A1. 首字母列里的单字母 term 及其文档覆盖
SELECT term, doc FROM temp.v
WHERE col = 'initials_meta_tok' AND length(term) = 1
ORDER BY doc DESC;

-- A2. 各列单字符 term 数量（判断「单字查询会不会扫全库」）
SELECT col, COUNT(*) FROM temp.v WHERE length(term) = 1 GROUP BY col;

-- A3. 文件名混入的痕迹：首字母列里的纯数字 / trackXX 形态
SELECT term, doc FROM temp.v
WHERE col = 'initials_meta_tok' AND term GLOB '*[0-9]*'
ORDER BY doc DESC LIMIT 20;
```

**判读**：若 A1 里出现 `doc / 总曲数 > 5%` 的单字母（如 `a`、`t`），M-1 成立且严重。
A3 若有大量命中，D-4 成立。

> **⚠️ 本次改动后 A1 / A3 只能用于「历史数据回溯」**：新构建的索引里，
> 单字母首字母 token 仍可能存在（来自标题 / 歌手 / 专辑，例如标题就是 `A`），
> 但**不再由文件名贡献**，且**查询侧已不会用它们生成首字母支**（`MinInitialsBranchLength=2`）。
> 所以「库里还有单字母 token」本身不再是问题，**问题在于查得到**——用 §8.1 的负例集验证更直接。
> 反过来：若在**新库**上 A3 仍有大量纯数字 / `trackXX` 形态，说明 D-4 的修复没生效
> （多半是没重建索引，检查 `search_meta.analyzer_version` 是否为 `13`）。

### 7.3 诊断 B：同一查询逐支拆解（对应 M-1~M-6、M-7）

```bash
# 用发布包里的 CLI（只读，不改索引）
archoera-indexer query '爱' --index <search.db> --raw '{initials_meta_tok initials_lyrics_tok} : "a"'
archoera-indexer query '爱' --index <search.db> --raw '"爱"'
archoera-indexer query '爱' --index <search.db> --raw '"fond" OR "like" OR "love"'
```

> ⚠️ **注意**：不带 `--raw` 时 CLI 只跑词法支（`Program.cs:184-191` 的 `BuildMatchExpression` 仅取
> `Lexical`），**看不到真实主趟行为**。必须用 `--raw` 逐支手工构造，或改用 §7.4 的导出方式。

> **✅ 本次改动后可以直接看归因**：`indexer query --session` 走**生产查询路径**
> （六趟渐进 + 每条命中带 `pass` 字段：`lexical` / `pinyinLoose` / `reading` /
> `crossLingual` / `fuzzy` / `cjkFuzzy`），无需逐支手工构造即可回答「这首歌是哪一趟召回的」：
>
> ```bash
> archoera-indexer query '爱' --index <search.db> --limit 50 --session
> # → {"items":[{"trackId":"..","score":..,"pass":"lexical"}, ...],"passes":{...}}
> ```
>
> 不带 `--session` 时仍走裸 MATCH（`SearchResults`，无 `pass` 字段）——那只是单条表达式的
> 排名预览，**不代表生产行为**。
>
> 判读：若某条命中的 `pass` 是 `crossLingual` / `fuzzy` / `cjkFuzzy`，而不含字面「爱」，
> 那是兜底趟贡献的（属预期）；若 `pass` 是 `lexical` 但标题 / 歌词里都看不到「爱」，
> 才是真正需要排查的索引污染（D-1~D-3）。

### 7.4 诊断 C：索引内容 vs 源内容（对应 D-1~D-3）

```sql
-- 在 library.db 上执行：抽出可疑曲目的源文本
SELECT id, title, artists, album, lyrics, lyrics_lrc, lyrics_lrc_trans, lyrics_lrc_romaji
FROM tracks WHERE id IN ('…');

-- 在 search.db 上执行：确认该曲已被索引（不能回读 token，只能确认存在与版本）
SELECT track_id, indexed_mtime, indexed_lrc_mtime, indexed_lrc_size,
       indexed_generation, schema_version
FROM search_docs WHERE track_id = '…';
```

**判读**：若 `tracks.file_mtime` 与 `search_docs.indexed_mtime` 相等，但用户报告的歌词内容已变化
→ **D-3 成立**（mtime 未变但内容变了，正是脏集判定的盲区）。
若 `indexed_mtime` 落后于 `file_mtime` → 只是增量没跑完，属正常滞后。

### 7.5 诊断 D：语言画像与列填充率（对应 D-5）

```sql
SELECT key, value FROM search_meta;   -- analyzer_version / schema_version / has_japanese / has_han / …
```

再用 A2 的结果对照：若 `has_japanese=true` 但 `reading_meta_tok` 的单字符 term 极少、
而 `pinyin_meta_tok` 异常丰富 → 纯汉字日文标题被中文拼音覆盖，**D-5 成立**。

### 7.6 诊断 E：复现「爱 → 恨」

拿到出问题的曲目 id 后：

1. 在 `library.db` 里 `SELECT lyrics` 等字段，确认**源文本**是否真含「爱」；
2. 若源不含「爱」→ 索引污染（D-1/D-2/D-3），按 §7.4 继续；
3. 若源含「爱」（例如歌词里确实有「爱」）→ **不是缺陷**，是用户没意识到歌词命中
   （此时 M-7 归因缺失就是真正的产品问题）；
4. 若源既不含「爱」也不含其拼音/首字母/跨语言候选，却仍被召回 → 用 7.3 逐支定位，
   这是唯一需要**立即修**的硬缺陷。

---

## 8. 推进顺序（建议）

| 阶段 | 内容 | 前置 | 产出 |
|---|---|---|---|
| **S0** | 按 §7 跑诊断，拿到真实数据 | 用户提供 DB | 一份「失效模式实际分布」表，替换本文 §5 的合成数据 |
| **S1** | M-7 归因（趟名 + 命中列） | S0 | 之后所有改动都可量化对比。✅ **已落地（趟名部分）**，`field` 仍待做 |
| **S2** | 硬门控（§6.2 前两条：首字母 ≥2、单字禁跨语言） | S0 | 直接消除 M-1/M-5 的最严重部分，**风险最低**。✅ **已落地** |
| **S3** | 分层排序（§6.1 第 1–2 层 vs 3–6 层分池） | S1 | 消除 M-4。⬜ 未做（改动面最大，需真实数据支撑） |
| **S4** | 索引侧 D-4（去掉 filename 混入）→ D-1/D-2 → D-3（指纹） | S0 | 消除污染源，**建议按此顺序**（风险递增）。✅ **D-4 已落地**，其余未做 |
| **S5** | 词长阶梯 + 高频 term 门控（P0-2/P0-3） | S1 | 收紧 M-2/M-5，需 qbench 验证召回无损。🟡 **词长门控已落地**（`MinFuzzyWordLength=3`），高频 term 未做 |
| **S5b** | 多词最少命中数（Solr `mm` 式分段） | S1 | 消除 M-3，且不牺牲单词查询的召回。⬜ 未做 |
| **S6** | 评测固化：负例集（「库里没有的字」必须返回空）+ 正例集 | S1 | 防回归。✅ **已落地**（`SearchLayerTests.RecallPrecisionGates`，8 条断言） |

> **2026-11-16 实际执行说明**：按「先按可能疑点改、只保证编译通过」的要求，本次落地了
> **S1（趟名归因）/ S2（硬门控）/ S4-D4（索引去污）/ S5 的词长部分 / S6（负例集）**，
> 跳过了 S3（分层排序）、S5b（mm 分段）、S5 的高频 term 门控，以及 D-1/D-2/D-3/D-5/D-6。
> **未做任何压力测试 / 基准**（遵循仓库红线与本次要求），只跑了既有回归 + 新增负例：
> `dotnet build`（CLI / tests / FFI 三个项目）全绿、`archoera-indexer-tests` 498 项全 PASS、
> `dart analyze lib` 0 issue、相关 Flutter 测试全绿。

### 8.1 必须先建立的负例集（针对本次反馈）

> 现有 qbench 金标准是「曲库文本字面包含目标字串」，**天然测不出误召回**——
> 它只衡量「该找到的找到了没」，不衡量「不该找到的有没有混进来」。这是评测基建的缺口。

建议新增（每条都应是 **P@k 与「返回总数」双断言**）：

1. 曲库无「爱」字 → 搜 `爱` 必须返回**空**（或仅返回字面含「爱」的曲目）；
2. 曲库有「恨」但无「爱」→ 搜 `爱` 必须**不返回**那首「恨」；
3. 曲库仅有单字母标题（`A`/`I`）→ 搜 `爱` 必须**不返回**它们；
4. 曲库仅英文歌 → 搜中文单字 → 空（除非启用了跨语言且有对应释义命中，需显式断言）；
5. 两字查询无命中 → 不得退化为单字结果（M-3）；
6. 含单字母 token 的歌词（整行「啊」）→ 搜单字查询时**不得**因首字母支而全库命中（M-1）；
7. 多词查询部分不命中（`夜 雨 恨`）→ 必须按 §6.2「最少命中词数」返回，而非整库放宽（M-3/M-6）。

---

## 9. 红线与未决问题

### 9.1 红线

- **不换引擎**：FTS5 保留。上述所有机制都是「查询编译 + 排序」层面，不涉及存储改造。
- **不引入服务本体**：Meilisearch / Typesense / PGroonga 只作规则参照，桌面端不内嵌。
- **不靠调 `limit` 降噪**：`limit` 只影响取多少条，不改变命中集合（`library_search_rank.dart` 已论证）。
- **任何门控改动都必须先有负例向量**（§8.1），否则等于用感觉换召回。
- **凡涉及 `AnalyzerVersion` 的改动攒批**（`cross-lingual-search-upgrade-plan.md` §5 第 4 条）。

### 9.2 未决

1. **首字母支是否要恢复单字母检索？** 本次已禁用（`MinInitialsBranchLength = 2`）。
   若确有用户用 `a` 搜「爱」，可改为「降档」而非禁用。建议先统计真实查询日志
   （`services/search/query_log.dart` 已在记录）中单字母查询的占比与命中数。
   **回退方式**：把该常量改回 1 即恢复旧行为（无其他耦合）。
2. **D-1 的保守化会掉多少召回？** 需要真实双语 LRC 覆盖率数据。
3. **高频 term 阈值 1%（Lucene 默认）对中文是否合适？** 中文 bigram 的 df 分布与英文词差异极大，
   需在真实库上用 §7.2 A2 的数据校准。
4. **`MinExact` 改语义会影响现有 UI 的「结果数」显示**（`totalCount` = 命中 id 数，
   `library_store_pager.dart:52-126`），需同步确认。
5. **跨语言支对单字禁用后，「英文搜中文单字」是否还有价值？** 「拉丁词 → 汉字」方向
   （`love → 爱`）**未受影响**，被禁用的只是「汉字单字 → 英文释义」方向；
   若发现反方向也有噪声，可同样加字数门控。
6. **CJK 容错提到 3 字后，「两字打错」是否仍有召回需求？** 两字查询删一字必然退化成单字
   （本次修复的正是这一点）。若真实数据表明两字错字很常见，可改为「仅换位、不删除」的
   两字变体（换位不改变字数，不会退化）。

### 9.3 本次改动的回退清单（评审用）

| 改动 | 回退方式 | 是否需要重建索引 |
|---|---|---|
| 单字母首字母支门控 | `MinInitialsBranchLength` 改回 1 | ❌ 不需要 |
| 单字跨语言门控 | `MinCrossLingualCjkLength` 改回 1 | ❌ 不需要 |
| 两字 CJK 容错门控 | `MinCjkFuzzyLength` 改回 2 | ❌ 不需要 |
| 短词模糊门控 | `MinFuzzyWordLength` 改回 1 | ❌ 不需要 |
| 文件名退出拼音 / 首字母列（D-4） | 恢复 `CombinePinyin/CombineInitials` 的 filename 参数，并把 `AnalyzerVersion` 改回 12 | ✅ 需要 |
| 趟次归因（`pass` 字段） | 删除 `SearchHit.Pass` 与 JSON 字段；Dart 侧 `LocalSearchPass` 可保留（缺省 lexical） | ❌ 不需要 |

---

## 10. 一句话总结

> 本次反馈的两个症状里，**「没有匹配却返回一堆」已定位到确定机制**（单字查询 → 首字母支精确单字母
> → 整库命中；两字查询 → CJK 容错删一字 → 退化为单字），**「爱 → 恨」尚未复现**，只可能来自宽覆盖
> 误命中或索引污染，必须用真实 DB 定论。修复方向不是「把匹配调严格」，而是补齐成熟引擎都有的三件事：
> **短查询门控**（Navidrome `ftsQueryDegraded` + Bleve `prefix_length` / Typesense `min_len_1typo=4,7` /
> ES `AUTO` 3-6 / Lucene `maxQueryFrequency=0.01` / pg_trgm 词级阈值 0.6 > 整串 0.3）、
> **按匹配类型分层排序**（Meilisearch `ranking_rules` / Navidrome `(token OR token*)`）、
> **命中原由归因**；多词查询用 Solr `mm` 分段条件（`3<90%`）表达「最少命中词数」。
> 索引侧的 6 个污染入口可独立先修，其中「文件名混入拼音/首字母列」风险最低。
>
> **2026-11-16 已落地第一批**：M-1/M-3/M-5 门控（首字母 ≥2 字符、CJK 容错 ≥3 字、单字禁跨语言释义）、
> M-7 趟次归因（`pass` 字段贯穿 C# → JSON → Dart）、D-4 索引去污（`AnalyzerVersion` 12→13）、
> 8 条正负例回归。**未做压力测试，只保证编译与 498 项既有回归全绿。**
> 下一步仍是**拿到真实 `library.db` + `search.db` 跑 §7 的只读诊断**，再决定 S3/S5b 与 D-1~D-3 是否值得动。
