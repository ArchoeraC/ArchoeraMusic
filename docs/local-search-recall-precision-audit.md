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
>
> **2026-11-16 晚：S0 已完成**（真实 48,759 首 `search.db` + 1,262 条真实查询日志）。
> 见新增的 §11——单字查询的问题被实锤且**比合成库更严重**，同时暴露了
> 三条原审计未列出的放大器。D-4 的数据也已核对（旧库 v12 确有数字污染，新库 v13 待验证）。

---

## 11. S0 真实库诊断结果（2026-11-16，只读）

> 数据来源：一份他人服务器的 `search.db`（SQLite FTS5，**48,759 首**，`schema_version=7` /
> `analyzer_version=**12**`，即 **D-4 修复前**的索引）+ 同库导出的 MySQL `_music.sql`
> （含 `user_search_history` **1,262 条真实查询**，唯一 1,162 条）。
> 全部为只读操作：`fts5vocab` 统计 + 现成 CLI `query --session` / `--raw`，未改代码、未重编索引。
> ⚠️ 该库 `analyzer_version=12`，**不能**用来验证 D-4 修复是否生效；它的价值是「修复前的基线」。

### 11.1 诊断 A2/A1：单字符 token 的真实分布（M-1、M-2、D-4）

`initials_meta_tok` 单字符 term 共 **122 个**，最高覆盖 **2,132 首（4.37%）**：

| term | doc | 覆盖率 | term | doc | 覆盖率 |
|---|---|---|---|---|---|
| `2` | 2,132 | 4.37% | `x` | 1,191 | 2.44% |
| `s` | 1,778 | 3.65% | `i` | 1,077 | 2.21% |
| `a` | 1,465 | 3.00% | `y` | 1,067 | 2.19% |
| `1` | 1,373 | 2.82% | `t` | 855 | 1.75% |
| `b` | 1,340 | 2.75% | `h` | 726 | 1.49% |

**判读**：§7.2 的门限是「>5% 即成立且严重」，实测**没有一个单字母超过 5%**（最高 3.65%）。
按文档原判据 M-1 只能算「中等」。**但这个判据低估了问题**——见 §11.2：真正的放大器不是
单个 token 的覆盖率，而是**首字母支把「任意单字母」当成召回条件**，与 token 自身频率无关。

D-4 残留（旧库 v12，预期会中）：`initials_meta_tok` 与 `pinyin_meta_tok` 各有 **648 个**
含数字的 term，累计 **13,975** doc 引用，头部是 `2 / 1 / 3 / 4 / 27 / 2024` 这类纯数字。
这是文件名（`track01`、`0001`、年份）混入的来源，与 D-4 描述一致。

### 11.2 诊断 B：单字查询的真实召回（本节是本次最重要的结论）

用 1,262 条真实查询里的**单字查询**跑生产路径（`query --session --limit 60000`）：

| 统计项 | 真实值 |
|---|---|
| 唯一单字查询 | **98** 条（占全部唯一查询 8.4%） |
| 命中数**中位数** | **9,242 首** |
| 命中数**最大** | **29,613 首**（`新`，占全库 60.7%） |
| 命中 **> 5,000** 的 | **78 / 98（79.6%）** |
| 命中 **> 1,000** 的 | **94 / 98（95.9%）** |
| 命中 0 的 | **1 / 98**（`。` 标点） |

命中数 top：`新 29613` / `辞 28774` / `有 25848` / `十 24331` / `是 24331` / `士 24331` /
`晴 23163` / `置 22223` / `神 21145` / `近 20457` / `花 20185` / `颜 19968` / `燕 19968` / `不 19362`。

**这就是用户反馈「没有可匹配的媒体时仍返回一堆」的实貌**：一个单字查询在 4.8 万首库里
返回五位数结果，而且这些结果绝大多数与查询字毫无关系。

#### 逐支拆解（`--raw`，量化各支的边际贡献）

| 查询 | 词法支 | 拼音支 | 首字母支 | 三支并集 | **仅首字母贡献** | 仅拼音贡献 |
|---|---|---|---|---|---|---|
| 爱 | 12,620 | 13,978 | 5,850 | 16,291 | **2,313** | 1,358 |
| 恨 | 1,311 | 5,144 | 7,718 | 12,557 | **7,413** | 3,833 |
| 痛 | 3,828 | 10,535 | 6,861 | 14,100 | **3,565** | 6,707 |
| 想 | 11,711 | 18,776 | 8,795 | 22,476 | **3,700** | 7,065 |
| 黑 | 2,548 | 3,287 | 7,718 | 10,410 | **7,123** | 739 |
| 雨 | 5,414 | 17,955 | 8,389 | 21,088 | **3,133** | 12,541 |
| 心 | 14,279 | 25,965 | 8,795 | 29,394 | **3,429** | 11,686 |

三个可直接读出的结论：

1. **首字母支与查询语义无关**：`恨` 与 `黑` 的首字母支**返回完全相同的 7,718 条**（都是 `h`）。
   `爱` 与 `想` 的 `a` / `x` 同样是一刀切的整字母命中。这证明它不是一个「弱相关」信号，
   而是**一个与查询无关的常量集合**。
2. **首字母支的边际贡献可以超过词法支本身**：`恨` 的词法支只有 1,311 条，首字母支独占 7,413 条
   ——**真正的「恨」被 5.6 倍的噪声淹没**。`黑` 是 2,548 : 7,123。
3. **拼音支是更大的放大器**（`心` +11,686、`雨` +12,541）：`xin*` / `yu*` 这类「单音节 + 前缀」
   命中所有 `xin` / `yu` 开头的拼音词（`xing`、`xingfu`、`yuan`、`yue`…），语义上同样无关。

### 11.3 新发现的三条放大器（原审计 §2 未列出）

#### N-1（**确认为 bug**）`metadata=false` 时词法支没有任何列过滤

`SearchQuery.JoinBranches`（`SearchQuery.cs:639-649`）只在 `metadata == true` 时套
`{MetadataColumns} : (...)`；`metadata == false`（即 `scope=all`）时，主趟的**词法支对全列
（含 `lyrics_tok` / `lyrics_tr_tok` / `lyrics_rom_tok`）生效**。注意拼音支与首字母支**自身带列过滤**
（`{pinyin_meta_tok pinyin_lyrics_tok}` / `{initials_meta_tok initials_lyrics_tok}`），
所以 `scope=all` 下**唯一会扩散到歌词列的就是词法支**。后果是「单字查询扫全库歌词」：

| 查询 | 仅标题/歌手/专辑/文件名 | 全列（含歌词） | 放大倍数 |
|---|---|---|---|
| 爱 | 2,012 | 12,620 | **6.3×** |
| 黑 | 246 | 2,548 | **10.4×** |
| 恨 | 38 | 1,311 | **34.5×** |

`恨` 一词：标题里只有 38 首歌含「恨」，歌词里 1,311 首——一个字的歌词命中把元数据精确命中
稀释了 34 倍。Dart 侧 `LocalSearchScope.all` 是默认值（`search_service.dart:166`），
所以**绝大多数真实查询走的都是这条放大路径**。

> 这条是否算 bug 取决于产品意图：歌词搜索本身是特性（「搜歌词找歌」），不该直接关掉。
> 但**单字**在歌词列上的 df 极高，应当像 Lucene `maxQueryFrequency` 那样按 df 降档，
> 而不是与标题命中同池同权竞争。

#### N-2 单字全角/半角、标点的空召回边界不一致

98 条单字查询里唯一返回 0 条的是 `。`（中文句号）。而 `。` 与 `.` 在分析器里归一行为不同，
说明**标点类输入的分词结果不稳定**——用户搜歌词里常见的一行标点会得到完全空的结果，
而搜另一个等价形态可能有结果。属低优先级，但应补进 §8.1 的负例集。

#### N-3 `--session` 的 `pass` 归因对单字查询**不可用**

所有单字查询的 `passes` 都是 `{pinyinLoose:0, reading:0, crossLingual:0, fuzzy:0, cjkFuzzy:0}`，
每条命中的 `pass` 全是 `lexical`。原因是 `CompileMatch` 把**词法 / 拼音 / 首字母三条支
平铺 OR 后交给同一趟**（§2.1），M-7 只在「趟」级别归因，**支级别没有归因**。

这直接限制了排障能力：看到 `pass=lexical` 无法判断这条是标题命中、还是首字母 `h` 的噪声。
**建议把 `SearchPassNames.Lexical` 拆成 `lexical` / `pinyin` / `initials` 三个值**，
或给 `SearchHit` 增加 `branch` 字段（成本远低于 §6.3 原设想的 `field` 级归因，
只需在 `CompileMatch` 内把三支改为三次 `Merge`）。

### 11.4 对原审计结论的修正

| 原结论 | 真实库修正 |
|---|---|
| §2.2「单字查询命中整库」（合成库 400/400） | **真实库同样成立，但不到整库**：中位 9,242 / 48,759 = **19%**，最高 61%。严重度维持「高」，机制描述要改——不是「400 全中」，而是「几条与查询无关的支叠加出五位数结果」 |
| §7.2「单字母覆盖 >5% 即成立且严重」 | **判据需下修**：实测最高仅 3.65%，但后果依然严重。覆盖率**不是**合适的指标，应改为「**该支的边际贡献 / 词法支命中数**」（`恨` = 5.6×） |
| §2.6「initials_meta = 2.0 权重过高」 | **确认**，且更严重：不只是权重高，而是**召回集合本身与查询无关**，加权只是让噪声排得更靠前 |
| M-1 修复（`MinInitialsBranchLength = 2`） | **仍有效且必要**，但**不足以**解决问题——拼音支（`xin*`/`yu*`）是同级放大器，M-2 的优先级应从「待定档」提到 **P0** |
| D-4 修复（去掉 filename） | 旧库 v12 确有 648 个数字 term / 13,975 doc 引用，**污染真实存在**；新库 v13 效果需在重建后复测 |

### 11.5 按真实数据排出的优先级（替换 §8 的建议顺序）

| 优先级 | 动作 | 依据 | 预期收益 |
|---|---|---|---|
| **P0** | 单字查询**只查元数据列**（或对 lyrics 列做 df 降档） | §11.3 N-1：`恨` 34.5× 放大 | 单字召回从五位数降到千级 |
| **P0** | 拼音支单音节加 df 门控（`maxQueryFrequency`） | §11.2：`心` +11,686、`雨` +12,541 | 直接砍掉最大的噪声源 |
| **P1** | 支级别归因（`lexical` / `pinyin` / `initials` 三值） | §11.3 N-3：现有 `pass` 对单字完全不可用 | 后续所有改动可量化 |
| **P1** | 单字查询在 UI 侧显式降级提示（「单字查询结果较宽泛」） | §11.2：79.6% 单字查询 >5,000 条 | 产品层的止损，零算法风险 |
| **P2** | 分层排序（§6.1 S3） | §11.1：噪声与真命中同池 BM25 | 排名质量 |
| **P2** | M-2 词长阶梯（3→4 需重新评估） | §5.0 曾因回归 `FuzzyVocabularyRecall` 保守取 3 | 长尾 |

> **验证方法**：上述每项落地后，用同一份 `queries_all.txt` + 同一份 `search.db` 重跑，
> 对比「单字查询命中数中位数」与「top-10 是否包含字面命中」。这个基线已经建立
> （中位 9,242 / 79.6% 超 5,000），改动效果可直接量化，不再靠感觉。

#### 11.5.1 P0 收益的离线验证（仅元数据列，未改代码）

把单字查询的词法支限制到 `MetadataColumns`（`title/artist/album/filename` + `pinyin_meta/initials_meta/reading_meta`）后：

| 查询 | 当前（全列） | 仅元数据列 | 降幅 |
|---|---|---|---|
| 爱 | 12,620 | **2,012** | −84% |
| 恨 | 1,311 | **38** | −97% |
| 痛 | 3,828 | **98** | −97% |
| 想 | 11,711 | **805** | −93% |
| 黑 | 2,548 | **246** | −90% |
| 雨 | 5,414 | **753** | −86% |
| 心 | 14,279 | **1,142** | −92% |
| 新 | 3,254 | **613** | −81% |

即「单字查询一律只查元数据列」这一条，就能把单字召回整体压到**百~千级**（中位数从 9,242 降到
约 500–800），且不需要改索引、不需要重建。**这是当前投入产出比最高的一条改动。**

> 注意：这会**放弃「用单个字搜歌词」**（例如搜「痛」不再返回歌词里只有这一个字的歌）。
> 是否可接受需要产品判断；折中方案是**保留歌词列但做 df 降档**
> （`doc/48759 > 1%` 的单字 term 不参与歌词列召回），既保住高频字之外的歌词搜索，
> 又消除 `爱` / `心` / `想` 这类超高频字的泛滥。

---

## 12. 致命问题复现：**字面零命中仍返回大量无关结果**（2026-11-16）

> 这是本文档**最严重**的一条，优先级高于 §11 的全部内容。
> 用户原话：「对于没有匹配项，会返回大量完全无关的搜索项目，这是致命问题」。
> 全部结论均由真实库（48,759 首）只读复现，未改代码。

### 12.1 现象：用「库里根本没有的字」查询

取生僻字（几乎不可能出现在任何歌名 / 歌词里）逐个查询，同时记录
**字面命中数**（`--raw '"<字>"'`，即纯词法）与**生产路径命中数**（`--session`）：

| 查询 | 拼音 / 首字母 | 字面命中 | 生产路径返回 | 判定 |
|---|---|---|---|---|
| `鬱` | `yu` / `y` | **0** | **17,955** | 占全库 **36.8%** |
| `籲` | `yu` / `y` | **0** | **11,848** | 占全库 24.3% |
| `迌` | `tu` / `t` | **0** | **5,675** | |
| `龗` | `ling` / `l` | **0** | **5,331** | |
| `靐` | `bing` / `b` | **0** | **4,159** | |
| `驫` | `biao` / `b` | **0** | **2,279** | |
| `鸞` | `luan` / `l` | **0** | **1,743** | |
| `齉` | `nang` / `n` | **0** | **224** | |
| `龘` | 无读音 | **0** | **0** | ✅ 唯一正确的一类 |
| `鱻` | 无读音 | **0** | **0** | ✅ |

> ⚠️ **注**：`鬱` 经繁简折叠后归一为 `郁`（NFKC + ToolGood 繁转简），所以「字面命中 0」
> 指的是**折叠后的 `郁`** 也查不到那些噪声曲目——噪声纯粹来自拼音支。
> 修复后 `鬱` 返回的 479 条正是**字面真含「郁」**的曲目（正确命中），见 §12.11。

**关键观察**：`鬱` 与 `籲` 字面命中都是 **0**，却分别返回了 17,955 和 11,848 条结果。
这两个字在 4.8 万首库里**一次都没出现过**。用户看到的就是「搜一个不存在的字，出来半个曲库」。

反过来，`龘` / `鱻` 返回 0——因为它们**没有拼音**（`Analyzer` 的 `def_hanzi2pinyin` 查不到），
所以拼音支与首字母支都不生成。**这恰好反证了根因就在读音支。**

### 12.2 根因：读音支在**字面零命中**时仍然无条件生效

`SearchSession.ExecuteUncached`（`SearchSession.cs:272`）的主趟是**三条支平铺 OR**：

```
词法支("鬱")  OR  拼音支(pinyin_* : "yu")  OR  首字母支(initials_* : "y")
```

FTS5 里 OR 的语义是「**任一**支命中即召回」。于是：

1. 词法支 `"鬱"` → **0 条**（库里真没有这个字）；
2. 拼音支 `pinyin_* : "yu"` → **17,955 条**；
3. `0 OR 17955 OR 8389` = **17,955 条**。

**「字面零命中」根本不构成停下来的理由**——因为 OR 的其他支还有结果。
`MinExact`（默认 1）判的是「主趟总命中数 < 1 才继续兜底」，
而主趟此时已经有 17,955 条，于是**连兜底趟都不需要跑，这就已经是最终结果**。

### 12.3 为什么是 `yu` 而不是 `yu*`（比分词更隐蔽）

`鬱` 的拼音是 `yu`（长度 2），小于 `MinPrefixTokenLength = 3`，所以**不加 `*`**，
走的是 `QuotedAnd(clean, false)` → 精确 term `"yu"`。

看起来「精确匹配」应该安全，但 **FTS5 存的是分词后的 term**：`明月` → `ming yue`，
于是 `pinyin_meta_tok` 里 `yu` 这个 term 覆盖了所有含「月 / 雨 / 玉 / 语 / 遇 / 宇 / 羽…」的歌。
实测 `pinyin_meta_tok` 中 `yu` 开头的 term 有 **105 个**、累计 **10,113** doc，其中单个 `yu` 就占 **3,865**。

> 即：**短拼音（≤2 字符）走「精确」比走「前缀」更危险**，因为它精确地命中了
> 一个在所有复合音节里都会出现的**共享前缀 term**。

`靐`（`bing`，长度 4 → 加 `*`）同理：`bing` / `bing*` 都是 **4,140** 条
（`bing` 已覆盖「冰 / 病 / 并 / 兵 / 禀 / 炳…」全部复合词）。

### 12.4 为什么噪声还能排在前面（排序也失效了）

`FtsStore.Bm25Weights` 给 `pinyin_meta = 2.0`，与 `album` 同档，
只比 `title = 4.0` 低一档。实测 top-5：

```
搜「鬱」仅拼音支 top5:  (33313,-2.44) (38477,-2.43) (34508,-2.42) (17737,-2.42) (21825,-2.41)
```

这些曲目与「鬱」的关系**仅仅是拼音里含 `yu` 这个音节**。由于
（a）没有任何字面命中参与竞争，（b）拼音列有 2.0 的高权重，
噪声会稳定排在最前面——用户翻十页也找不到任何相关结果，因为**相关结果根本不存在**。

### 12.5 与 §11 的关系

§11 说的是「**有**匹配时结果太宽」（中位 9,242）。本节是更严重的一类：
「**完全没有**匹配时仍返回大量结果」。

两者的**共同根因是同一个**：读音支（拼音 / 首字母）没有「字面命中」这一前提约束，
且与字面命中同池同权竞争。所以 §11.5 的两条 P0（单字限元数据列、拼音支 df 门控）
**不能解决本节问题**——它们只缩小噪音集合，不改变「音近即算命中」的语义。

### 12.6 修复方向（按优先级）

| 优先级 | 方案 | 说明 | 风险 |
|---|---|---|---|
| **P0** | **读音支必须以「字面支有命中」为前置** | 若词法支命中为 0，读音支应**降为兜底趟**（而不是主趟内平级 OR），并受 `MinExact` 约束；显示上标注「按读音猜测」 | 会砍掉「只记得读音、不记得字」的检索。折中：只在 `limit` 内少量返回并明确标注 |
| **P0** | **（替代上一条，更精确）按查询脚本分流** | **CJK 单字**且字面 0 命中 → 不返回读音结果；**拉丁词**（`qingtian` / `yewang`）→ 维持拼音检索；**CJK 多字** → 走 bigram 短语不受影响。见 §12.7 | 需在 `CompileMatch` 里按 `QueryTokens` 的脚本画像分流；不会误伤拼音检索 |
| **P0** | **短拼音 term 的前缀判定反转** | 长度 ≤2 的拼音**不生成精确 term**（`yu` 这类共享前缀）；或要求**整音节匹配**而非 term 匹配 | 需 `PinyinSegmenter` 提供音节边界信息 |
| **P1** | **df 门控（分列设定，非 1%）** | `pinyin_meta_tok` 阈值 ~5%、`pinyin_lyrics_tok` 阈值 ~10%（§12.9）。注意 **1% 阈值在中文拼音列上无效**，会误砍 `qingtian` 的 `qing`(4.08%) | 需在查询期拿 df（`fts5vocab` 或缓存），有额外成本 |
| **P1** | **分层排序**：读音支命中不能与字面命中同池 | `pinyin_meta = 2.0` 使噪声排前 | 即 §6.1 S3 |
| **P2** | 字面 0 命中时**直接返回空**（严格模式） | 最激进，但**会误伤拼音检索**（§12.7），故不宜作 P0 | 需产品决策 |

> **验证向量（直接可用）**：`鬱`/`籲`/`迌`/`龗`/`靐`/`驫`/`鸞` 这 7 个字
> 在真实库上字面命中均为 **0**，修复后生产路径**必须显著小于当前值**（目标：0 或
> 仅返回带「按读音猜测」标注的少量结果）。
> 对照组 `龘`/`鱻` 当前已经返回 0，修复后**必须仍为 0**（不能因改动引入回归）。

### 12.7 关键约束：**不能**简单地把「字面 0 命中」等同于「返回空」

这是本节最重要的设计约束。实测反例——真实用户日志里的**合法拼音检索**：

| 查询 | 字面命中 | 生产路径 | 性质 |
|---|---|---|---|
| `qingtian` | **0** | 369 | ✅ 合法：用户用拼音找「晴天」 |
| `yewang` | **0** | 159 | ✅ 合法：拼音找「夜王 / 夜望」 |
| `zhoujielun` | 1 | 376 | ✅ 合法：拼音找「周杰伦」 |
| `鬱` | **0** | 17,955 | ❌ 噪声：字面不存在，读音也无意义 |

**两者的表面特征完全相同（字面 0 命中）**，所以**任何「字面 0 → 返回空」的规则都会误杀拼音检索**。
这也是 §12.6 里「直接返回空」被列为 P2（而非 P0）的原因。

#### 可区分的信号

| 信号 | 噪声（`鬱`） | 合法（`qingtian`） | 可否用于判定 |
|---|---|---|---|
| 查询脚本 | CJK 汉字 | 拉丁字母 | ✅ **最强信号**：CJK 单字走读音支几乎必然是噪声；拉丁词走拼音是明确意图 |
| 拼音支命中数 / 全库 | 17,955（37%） | 369（0.8%） | ✅ 强信号，即 df 门控 |
| 首字母支命中数 | 8,389（17%） | 未触发 | ✅ 组合信号 |
| 字面命中 | 0 | 0 | ❌ **无法区分** |

**结论**：修复必须**按查询脚本分流**，不能一刀切：

- **CJK 单字 + 字面 0 命中** → 读音支降为兜底或直接不返回（本节的目标）；
- **拉丁词** → 维持现有拼音 / 首字母检索（用户明确在用拼音找歌）；
- **CJK 多字** → 走 bigram 短语，实测 `爱如潮水` = 17 条、`孤勇者` = 2 条，**不受影响**。

> 顺带修正一个易错点：多字 CJK 的「字面命中」不能用整串 phrase 来衡量。
> `"爱如潮水"` 作为 phrase 是 **0**，但生产路径用的是 bigram 短语 `"爱如 如潮 潮水"` = **17**，
> 生产结果 18 条是正确的。用整串 phrase 当基线会**高估**问题严重性。

### 12.8 离线验证：CJK 单字 + 字面 0 → 读0 是可行的

对 8 个生僻字，无论走「仅词法支」还是「仅元数据列」，**全部返回 0**：

| 字 | 仅词法支 | 仅元数据列 |
|---|---|---|
| 鬱 / 籲 / 迌 / 龗 / 靐 / 驫 / 鸞 / 齉 | **0** | **0** |

而正常查询（字面有命中的）保持原有量级：

| 查询 | 字面 | 生产 | 说明 |
|---|---|---|---|
| 夜曲 | 25 | 2,039 | 读音支仍在工作（歌词含「夜曲」的拼音） |
| 米津 | 154 | 1,656 | |
| 晴天 | 235 | 607 | |
| 爱如潮水 | 17（bigram） | 18 | |

即**按脚本分流后，噪声清零、正常查询无损**——这是 §12.6 中 P0 方案可行的实证。

### 12.9 df 门控的**列级**差异（1% 阈值必须分列设定）

`pinyin_meta_tok`（元数据拼音）与 `pinyin_lyrics_tok`（歌词拼音）的 df 分布差了一个数量级：

| term | `pinyin_meta_tok` | `pinyin_lyrics_tok` |
|---|---|---|
| `qing` | 1,988（4.08%） | **22,838（46.84%）** |
| `tian` | 2,580（5.29%） | **18,285（37.50%）** |
| `yu` | 3,865（7.93%） | **16,699（34.25%）** |

**为什么这很重要**：单音节 vs 多音节在同一列里的收敛效果完全不同：

| 查询 | `pinyin_meta_tok` | `pinyin_lyrics_tok` | 生产路径 |
|---|---|---|---|
| `qing AND tian`（`qingtian`，双音节） | **200** | 14,258 | 369 |
| `yu`（`鬱`，单音节） | 3,865 | 16,699 | **17,955** |

结论：**多音节查询靠 AND 自然收敛（meta 列 200 条），单音节查询没有任何收敛手段**。
所以 df 门控必须**分列**设定：

- `pinyin_meta_tok`：阈值取 **~5%** 以上才砍（`yu` 7.93% / `qing` 4.08% 处于边界，
  单纯按 1% 砍会把 `qing` 也砍掉，进而误伤 `qingtian`）；
- `pinyin_lyrics_tok`：阈值取 **~10%** 以上（`qing` 46.84% / `tian` 37.5% / `yu` 34.25%
  全部远超，砍掉后可消除歌词拼音对单音查询的放大）。

> ⚠️ **§12.6 表里「`doc/total > 1%`」这一条是按 Lucene 英文默认值套用的，在中文拼音列上不成立**。
> 中文拼音的 term 天然高度重合（音节只有约 400 个），1% 阈值会砍掉几乎所有正常查询。
> 实测证据：`qingtian` 的 `qing`（4.08%）与 `鬱` 的 `yu`（7.93%）在 1% 阈值下**都会被砍**，
> 但前者是合法检索、后者是噪声。**df 阈值无法单独区分二者，必须配合 §12.7 的脚本分流。**

### 12.10 最终结论

| 问题 | 是否成立 | 根因 | 最优修复 |
|---|---|---|---|
| 字面零命中返回大量无关结果 | ✅ **确认，致命** | 主趟三支平级 OR，读音支不看字面 | **按查询脚本分流**（§12.7）+ 单音节不生成读音支 |
| 单字查询过宽（§11） | ✅ 确认 | 词法支扫歌词列 + 拼音 / 首字母放大器 | 单字限元数据列 + df 门控 |
| 拼音检索（`qingtian`） | — 属正常功能 | — | **必须保留**，修复不得误伤 |

**一句话**：读音支（拼音 / 首字母）必须在**「字面支有命中」**或**「查询是拉丁拼音」**的前提下才允许参与召回；
当前实现把这三条支作为**平级 OR**，导致一个库里不存在的汉字仅凭读音就能召回 37% 的曲库。

---

## 13. 已落地：读音支脚本分流门控（2026-11-16）

> 针对 §12 致命问题的**第一刀**，已实现并通过真实库验证。
> 改动仅涉及查询编译，**不改索引、不需重建**。

### 13.1 改动内容

| 文件 | 改动 |
|---|---|
| `Analyzer.cs` | `QueryTokens` 新增 `HasCjk`（查询文本是否含 CJK 段） |
| `SearchQuery.cs` | 新增 `RequireLatinForReadingBranch` / `ReadingBranchMinCjkLength` 两个常量与 `AllowReadingBranch()` |
| `SearchQuery.cs` | `CompileMatch` 中拼音支 / 首字母支改为**条件生成** |

核心逻辑（`SearchQuery.AllowReadingBranch`）：

```
查询不含 CJK        → 允许读音支（拉丁输入 = 明确用拼音找歌）
查询含 CJK 且字数 ≥2 → 允许读音支（多字拼音串更独特）
查询含 CJK 且字数 =1 → 【拦截】不生成拼音支 / 首字母支
```

### 13.2 真实库验证结果（48,759 首）

**生僻字（噪声侧，应显著收敛）**：

| 查询 | 修复前 | 修复后 | 变化 |
|---|---|---|---|
| `鬱` | 17,955 | **479** | **−97%**（剩余 479 条是字面真含「郁」的正确命中） |
| `籲` | 11,848 | **11** | **−99.9%** |
| `迌` | 5,675 | **0** | 清空 |
| `龗` | 5,331 | **0** | 清空 |
| `靐` | 4,159 | **0** | 清空 |
| `驫` | 2,279 | **2** | −99.9% |
| `鸞` | 1,743 | **21** | −98.8% |
| `齉` | 224 | **0** | 清空 |
| `龘` / `鱻` | 0 | 0 | 不变（无读音，本就不生成读音支） |

**合法检索（必须不退化）**：

| 查询 | 修复前 | 修复后 | 结论 |
|---|---|---|---|
| `qingtian`（拼音） | 369 | **369** | ✅ 不变（拉丁输入走拼音支） |
| `yewang`（拼音） | 159 | **159** | ✅ 不变 |
| `zhoujielun`（拼音） | 376 | **376** | ✅ 不变 |
| `xingfu`（拼音） | 1,277 | **1,277** | ✅ 不变 |
| `周杰伦`（中文） | 479 | **479** | ✅ 不变（2 字，达阈值） |

**单字中文本的高频字（顺带收敛）**：

| 查询 | 修复前 | 修复后 | 变化 |
|---|---|---|---|
| `心` | 29,613 | **14,279** | −52% |
| `雨` | 17,955 | **5,414** | −70% |
| `爱` | 13,978 | **12,620** | −10% |

### 13.3 关键设计取舍

1. **为什么不按「字面是否 0 命中」判断**：`qingtian` / `yewang` 字面也是 0 命中，
   但它们是合法的拼音检索（§12.7）。**脚本才是可区分的信号**。
2. **为什么单字拦截、多字放行**：`鬱 → yu` 是 2 字符的共享前缀，必然泛滥；
   `周杰伦 → zhou jie lun` 是三个音节的长串，组合足够独特。阈值取 2 与
   `MinCrossLingualCjkLength` 同档。
3. **`愛` 未变的原因**：繁体 `愛` 折叠为简体 `爱`（1 个 CJK 字），本应被拦截，
   但 `爱` 的**词法支本身**命中 12,620 条（`lyrics_tok` 里真含「爱」），
   这部分是正确命中，不属于本次要消除的噪声。

### 13.4 尚未解决（本条门控覆盖不到的部分）

| 残留问题 | 说明 | 对应方案 |
|---|---|---|
| 单字仍扫歌词列 | `爱` 12,620 / `心` 14,279 仍来自 `lyrics_tok` 的字面命中 | §11.5 P0：单字限元数据列，或去 unigram（references §6 #1） |
| 多字查询仍可能放宽到读音支 | `周杰伦` 2 字达阈值，若字面 0 命中仍会走拼音 | 需配合「精确优先短路」（references §6 #5） |
| `愛` 类同形字噪声 | 繁简折叠后无法区分用户意图 | 需 df 门控（references §6 #6） |

### 13.5 参考依据

- Typesense 对 `zh/ko/ja` locale **直接关闭**模糊遍历（`src/index.cpp:5096-5099`）；
- Meilisearch `typo_tokens_threshold=1` 的「精确优先」原则；
- Navidrome `ftsQueryDegraded` 的「查询区分力」判定思路。

详见 [local-search-indexer-references.md](local-search-indexer-references.md) §4.0 / §6.3。

---

## 14. 已落地：单字查询列门控（2026-11-16）

> §13 之后的第二刀，针对 §11.3 N-1（`scope=all` 下词法支无列过滤）。
> 同样**不改索引、不需重建**。

### 14.1 问题回顾

`SearchQuery.JoinBranches` 只在 `metadata == true` 时套列过滤；默认的 `scope=all` 下
**词法支没有任何列限定**，于是单字查询直接扫 `lyrics_tok`。真实库实测放大倍数：

| 查询 | 仅元数据列 | 全列（含歌词） | 放大 |
|---|---|---|---|
| `恨` | 38 | 1,311 | **34.5×** |
| `黑` | 246 | 2,548 | 10.4× |
| `爱` | 2,012 | 12,620 | 6.3× |

一个汉字在歌词里的 df 极高（`的` 覆盖全库 **42.6%**），「歌词含某个字」几乎不构成检索意图；
而「标题 / 歌手 / 专辑含某个字」是明确意图（搜「爱」找歌名带「爱」的歌）。

### 14.2 改动内容

| 文件 | 改动 |
|---|---|
| `SearchQuery.cs` | 新增 `RequireMetadataForSingleChar` / `RestrictSingleCharToMetadata()` / `VisibleCharCount()` |
| `SearchQuery.cs` | `CompileMatch` 改用「`metadata` 为真 **或** 单字判定成立」决定是否套列过滤 |

判定：词法词元里**去重后的可见字符数 == 1** → 限定元数据列
（`MetadataColumns` = title / artist / album / filename / pinyin_meta / initials_meta / reading_meta）。
繁简折叠后判定一致（`愛` → `爱` 仍是单字）。

### 14.3 真实库验证（48,759 首）

相比 §13 落地后的状态：

| 查询 | §13 后 | §14 后 | 变化 |
|---|---|---|---|
| `爱` | 12,620 | **2,012** | −84% |
| `心` | 14,279 | **1,142** | −92% |
| `雨` | 5,414 | **753** | −86% |
| `黑` | 2,548 | **246** | −90% |
| `不` | 16,485 | **1,977** | −88% |
| `回` | 8,271 | **547** | −93% |
| `全` | 5,328 | **274** | −95% |
| `少` | 4,789 | **437** | −91% |
| `鬱` | 479 | **89** | −81% |
| `籲` | 11 | **0** | 清空 |

**合法检索全部不变**（多字 / 拼音查询不受单字门控影响）：

| 查询 | 期望 | 实测 |
|---|---|---|
| `qingtian` | 369 | **369** ✅ |
| `yewang` | 159 | **159** ✅ |
| `zhoujielun` | 376 | **376** ✅ |
| `xingfu` | 1,277 | **1,277** ✅ |
| `周杰伦` | 479 | **479** ✅ |
| `爱如潮水` | 18 | **18** ✅ |
| `夜曲` | 2,039 | **2,039** ✅ |

### 14.4 累计效果（§12 → §13 → §14）

以 §12 复现的致命问题为基线：

| 查询 | §12 原始 | §13 读音支门控 | §14 列门控 | 累计 |
|---|---|---|---|---|
| `鬱` | 17,955 | 479 | **89** | **−99.5%** |
| `籲` | 11,848 | 11 | **0** | **−100%** |
| `迌` | 5,675 | 0 | **0** | **−100%** |
| `龗` | 5,331 | 0 | **0** | **−100%** |
| `靐` | 4,159 | 0 | **0** | **−100%** |
| `爱` | 13,978 | 12,620 | **2,012** | −86% |
| `心` | 29,613 | 14,279 | **1,142** | **−96%** |
| `雨` | 17,955 | 5,414 | **753** | **−96%** |

### 14.5 回归

- `archoera-indexer-tests`：**508 项全 PASS**（§13 新增 7 项、§14 新增 3 项）
- 两条新负例均已通过「关开关 → 用例失败」验证其有效性：
  - 关闭 `RequireMetadataForSingleChar` → `负例: 单字查询不靠歌词命中召回` 报出 `[love,hate]`
  - 关闭 `RequireLatinForReadingBranch` → `负例: 单字 CJK 主趟不含拼音支` 报出 `("郁" OR {...} : "yu")`
- `dart analyze lib`：0 issue

### 14.6 两处测试断言的调整（如实记录）

§14 的行为改变导致两条既有断言失效，均已按**新契约**修正，而非放宽标准：

1. `查询层: offset 翻页不重复`：原用单字 `爱` 翻页，但单字查询现在限元数据列，
   本库标题含「爱」只有 1 首，无法翻页 → 改用两字 `邓丽`（t2 / t5 的共同歌手前缀）。
2. 该用例原来隐含「单字查询会返回歌词命中」，与 §14 的新契约冲突，故换查询词而非改断言强度。

### 14.7 仍未覆盖

| 残留 | 说明 | 下一步 |
|---|---|---|
| 单字查询仍需扫元数据拼音列 | `MetadataColumns` 含 `pinyin_meta_tok`，`爱` 的 2,012 条里仍有拼音贡献 | 拼音支已有 df 门控需求（§12.9） |
| 两字以上查询仍扫歌词列 | 属**预期行为**（「搜歌词找歌」是真实特性） | 保留 |
| 单字无法搜歌词 | 产品取舍：单字在歌词里几乎无区分力 | 需产品确认是否可接受 |

---

## 15. 单字列门控的精确化（2026-11-16）

> §14 落地后，根据产品判断「单字应只对应歌名 / 歌手，不应对应歌词」进一步收窄。
> 本节替换 §14 的列集合选择。

### 15.1 为什么 §14 的列集合不够精确

§14 用的是 `MetadataColumns`（title / artist / album / filename / pinyin_meta /
initials_meta / reading_meta）。问题在于它**混入了派生转写列**。实测各列贡献：

| 查询 | title | artist | album | filename | pinyin_meta | initials_meta | reading_meta |
|---|---|---|---|---|---|---|---|
| `爱` | 1,388 | 228 | 1,032 | 0 | **0** | **0** | **0** |
| `心` | 699 | 217 | 556 | 0 | **0** | **0** | **0** |
| `你` | 1,769 | 71 | 1,256 | 0 | **0** | **0** | **0** |

**汉字**在派生转写列里恒为 0 命中（那里存的是拉丁转写），所以对汉字查询而言
§14 的集合**实际等价于**可见文本列——行为正确，但语义表述不准确。

**拉丁单字**则完全不同：

| 查询 | title | artist | album | pinyin_meta | initials_meta | lyrics |
|---|---|---|---|---|---|---|
| `a` | 618 | 221 | 583 | **2,109** | **1,465** | 1,028 |
| `s` | 475 | 158 | 481 | **945** | **1,778** | 642 |
| `z` | 31 | 115 | 24 | 159 | **711** | — |

单字母在拼音列里毫无区分力（`a` 2,109 首），但在首字母列里是**真实的首字母检索**
（`z` → 711 首，真实查询日志里确实有 17 个拉丁单字查询：`s`/`e`/`a`/`l`/`p`/`h`/`t`/
`b`/`g`/`w`/`y`/`d`/`z`/`i`/`c`/`E`/`G`）。

### 15.2 新方案：按脚本分列

| 查询类型 | 列集合 | 理由 |
|---|---|---|
| **汉字单字** | `VisibleTextColumns`（title / artist / album / filename） | 派生转写列对汉字恒为 0 命中，收窄只是语义明确 |
| **拉丁单字** | `SingleCharLatinColumns`（可见文本 + `initials_meta_tok`） | 保留真实的首字母检索，但排除拼音列（无区分力） |

新增常量：

| 常量 | 值 |
|---|---|
| `SearchQuery.VisibleTextColumns` | `title_tok artist_tok album_tok filename_tok` |
| `SearchQuery.SingleCharLatinColumns` | 上述 + `initials_meta_tok` |

> ⚠️ **实现注意**：列过滤作用于**整个 OR 表达式**，所以词法支 `"z"` 也会在
> `initials_meta_tok` 上匹配——这**恰好**实现了首字母检索（`z` 匹配首字母串），
> 与单独生成首字母支的效果等价。而 `MinInitialsBranchLength = 2` 的门控仍然生效：
> 单字母**不会生成独立的拼音 / 首字母支**，只是列过滤放开了首字母列。

### 15.3 实测结果（48,759 首）

**汉字单字（行为不变，语义更准）**：

| 查询 | §14 | §15 | 命中来源 |
|---|---|---|---|
| `爱` | 2,012 | **2,012** | 全部来自 title/artist/album |
| `心` | 1,142 | **1,142** | 同上 |
| `你` | 2,221 | **2,221** | 同上 |
| `鬱` | 89 | **89** | 同上 |

**拉丁单字（消除拼音噪声，保留首字母检索）**：

| 查询 | §14 | §15 | 变化 | 剩余来源 |
|---|---|---|---|---|
| `z` | — | **711** | — | §14 前的原始值 7,794 → −91% |
| `a` | 2,473 | **1,465** | −41% | 原始 9,073 → −84% |
| `e` | 1,702 | **363** | −79% | 原始 4,103 → −91% |
| `o` | 2,022 | **255** | −87% | 原始 3,092 → −92% |
| `s` | 1,778 | **1,778** | 不变 | 原始 9,469 → −81% |

**多字 / 拼音查询：零变化**

| 查询 | 期望 | 实测 |
|---|---|---|
| `qingtian` | 369 | **369** ✅ |
| `yewang` | 159 | **159** ✅ |
| `zhoujielun` | 376 | **376** ✅ |
| `xingfu` | 1,277 | **1,277** ✅ |
| `周杰伦` | 479 | **479** ✅ |
| `夜曲` | 2,039 | **2,039** ✅ |
| `爱如潮水` | 18 | **18** ✅ |

### 15.4 回归

- `archoera-indexer-tests`：**510 项全 PASS**（§15 调整 1 条、新增 2 条）
- 三条新负例均通过「关开关 → 用例失败」验证：
  - `负例: 单字 CJK 主趟限定可见文本列`
  - `负例: 拉丁单字排除拼音列`
  - `正例: 拉丁单字保留首字母列`
- `dart analyze lib`：0 issue

### 15.5 产物语义总结

单字查询现在的语义：

```
汉字单字（爱 / 心 / 你）  →  只在歌名 / 歌手 / 专辑 / 文件名里找
拉丁单字（a / z / e）      →  在歌名 / 歌手 / 专辑 / 文件名 + 首字母串里找
两者都不搜歌词，都不搜拼音列
```

这符合「单字几乎没有区分力，只应作为名字的一部分被检索」的产品判断。

---

## 16. 已落地：精确 / 前缀分层（2026-11-16）

> 参考 Navidrome 的 `(token OR token*)`（[references](local-search-indexer-references.md) §2.2）。
> **不改索引、不需重建**，且**命中集合完全不变**。

### 16.1 问题

末词直接加 `*`（`"love"*`），精确命中与前缀命中在 bm25 里拿不到任何区分——
「歌词含 love」与「歌词含 lovesongs」评分同档。真实库：

| | 数量 |
|---|---|
| 字面含 `love`（精确） | **947** 首 |
| 前缀召回（`love*`，含 lovesongs / lovely…） | **1,297** 首 |

即 350 首是「仅前缀匹配」，却与 947 首精确匹配混排。

### 16.2 方案

末词编译为 `("love" OR "love"*)` 而非 `"love"*`。

**关键性质**：精确词是前缀词的**子集**，所以 OR **不增加任何命中**
（真实库实测差分 0，见 §16.4），但 bm25 会因精确词的更高 IDF 把含字面词的行排到前面。

### 16.3 为什么只改主趟

分层只在**主趟**（`LexicalBranch` 的末词、`QuotedAnd` 的首字母 / 拼音末音节）有意义。
兜底趟（`CompilePinyinLoose` / `CompileFuzzy` / `CompileCjkFuzzy`）本就是「放宽」语义，
在那里做精确/前缀分层没有意义，故**保持不变**。

### 16.4 命中集合不变（实测）

| 查询 | 改动前 | 改动后 |
|---|---|---|
| `love` | 1,297 | **1,297** |
| `night` | 512 | **512** |
| `周杰伦` | 479 | **479** |
| `qingtian` | 369 | **369** |
| `爱如潮水` | 18 | **18** |
| `夜曲` | 2,039 | **2,039** |
| `爱` / `心` | 2,012 / 1,142 | **2,012 / 1,142** |
| `z` | 711 | **711** |

**全部零变化**，符合 `exact ⊂ prefix` 的理论预期。

### 16.5 排序改善（实测）

| 查询 | 改动前 top-5 | 改动后 top-5 |
|---|---|---|
| `love` | 30176 / 37171 / 36345 / 49794 / **19523** | **19523** / 110 / 36345 / 16158 / 343 |
| `night` | 32960 / 18167 / 25503 / 27707 / 49102 | **9322** / 48937 / 25982 / 12029 / 44502 |
| `周杰伦` | 4843 / 4200 / 15760 / 26126 / 30401 | **4200** / 15760 / 26126 / 30401 / 14844 |
| `qingtian`（拼音） | 31956 / 31955 / 34639 / 15896 / 33814 | **完全相同**（5/5 同位） |

`love` 的 19523 从第 5 位升到第 1 位。交叉验证：改动后的 top-5 前 3 位与
「仅精确查询」(`"love"`) 的 top-5 **完全一致**（19523 / 110 / 36345），
证明字面命中确实被优先了。

拼音查询 `qingtian` 完全不变——符合预期（它走拼音支，不经过词法前缀分层）。

### 16.6 回归

- `archoera-indexer-tests`：**510 项全 PASS**
- 更新了 4 条编译黄金向量（反映新契约，非放宽标准）：
  - `查询编译器: 我爱你 主趟` → 末词变为 `("wan" OR "wan"*)`
  - `查询编译器: metadata 列过滤` → 同上
  - `转义: 注入 OR 被当字面量` → 新表达式
  - `转义: 首字母含引号仍闭合列过滤` → 新表达式
- 新增 `CountUnquotedOr()` 辅助函数，把「注入不产生额外 OR 分支」从
  「数引号个数」改为**语义断言**「引号外的 OR 只有 1 个」——前者会随表达式形态
  变化而失效，后者才是真正要验证的性质。
- `dart analyze lib`：0 issue

### 16.7 累计进度

| 阶段 | 内容 | 状态 |
|---|---|---|
| §13 | 读音支脚本门控（CJK 单字不生成拼音 / 首字母支） | ✅ |
| §14 | 单字查询限元数据列 | ✅ |
| §15 | 按脚本分列（汉字 → 可见文本；拉丁 → +首字母） | ✅ |
| §16 | 精确 / 前缀分层 | ✅ |
| §17 | 去中间字 unigram（bigram + 首尾 unigram） | ✅ |
| §18 | 丢词降级（多词不足时先减词，而非改读音） | ✅ |
| §19 | 歌词列降权（压制 df + TF 双重放大） | ✅ |
| §20 | 拼音变体总预算（防组合爆炸） | ✅ |
| §21 | 首字符错误算 2 错 | ✅ |
| §22 | 丢词方向修正（中文保留尾部歌名） | ✅ |
| §23 | 元数据字段判定（按 title/artist 分布识别歌名） | ✅ |
| — | df 门控（评估后不做，见 §19.8） | ⬜ |

---

## 17. 已落地：去中间字 unigram（2026-11-16，需重建索引）

> 唯一一处**改动索引内容**的优化，因此 `AnalyzerVersion` 13 → 14，需全量重建。

### 17.1 问题：单字 unigram 是噪声的结构性根源

v13 给 CJK 段的**每个字**都建了 unigram。真实库（48,759 首）实测 df：

| 单字 | unigram df | 占全库 |
|---|---|---|
| `的` | 20,787 | **42.6%** |
| `我` | 14,727 | 30.2% |
| `心` | 13,916 | 28.5% |
| `你` | 12,886 | 26.4% |
| `爱` | 12,120 | 24.9% |

而**以该字开头的 bigram** 覆盖要小得多（`的X` 最大 5,631，约单字 df 的 27%）。

### 17.2 方案：只给段首 / 段末建 unigram

参考 `fts5-cjk` 的默认行为（[references](local-search-indexer-references.md) §5.1）：
CJK 段索引 **bigram + 段首 unigram + 段末 unigram**，中间字只由 bigram 覆盖。
查询侧把单字改成前缀 `字*`。

**为什么必须保留首尾**：本地 FTS5 实测证明，只有 bigram 时**段末尾的字彻底查不到**
——它只作为某个 bigram 的第二个字符存在，而以它开头的 bigram 不存在。
补上首尾 unigram 后，首字 / 中间字 / 末字都能被 `字*` 命中：

```
「我爱北京」→ bigram: 我爱 爱北 北京
              首尾 unigram: 我 京
              ✓ 我* / 爱* / 北*（靠 北京 的 bigram）/ 京*
```

### 17.3 实测：索引体积**没有**下降 30%（预期修正）

| 版本 | 体积（20k 首语料） | `title_tok` 单字 term | 双字 term |
|---|---|---|---|
| v13 | 257 MB | 2,330 | 6,562 |
| v14 | 256 MB | **1,852（−20%）** | 6,562 |

**原先预期「降 30%」是误读**：那个数字来自 `fts5-cjk` 的 bigram → trigram 对比，
与「去 unigram」无关。实际体积几乎不变——FTS 条目量由 bigram 主导，
单字只是词表的一小部分。**收益在召回质量，不在空间**。

### 17.4 召回不丢（真实曲库验证）

本机真实库（115 首，日 / 中混合）重建 v14 后，**中间字仍可召回**：

| 标题 | 中间字 | 单字查询命中 |
|---|---|---|
| 心跳不止 | `跳` | ✅ 1 |
| 直到拥抱 | `到` | ✅ 1 |
| 不要说再见 | `要` | ✅ 1 |
| 轻轻地 | `轻` | ✅ 1 |

机制说明：`跳` 在索引中没有自己的 unigram，但 `心跳` 这个 bigram 存在，
前缀 `跳*` 命中它——**这正是设计意图**：单字查询收敛到「以该字开头的 bigram」。

### 17.5 改动清单

| 文件 | 改动 |
|---|---|
| `Analyzer.cs` | `AnalyzerVersion` 13 → **14**；新增 `KeepCjkEdgeUnigrams` 开关；`AddCjkSegment` 只建首尾 unigram |
| `SearchQuery.cs` | 新增 `IsSingleCjkChar()`；`LexicalBranch` 对独立成块的单字改走 `PrefixTerm` |
| `tests/vectors/analyzer.tsv` | 5 行分词黄金向量按新契约更新 |
| `tests/vectors/query.tsv` | 1 行（`我爱你`）更新 |
| `tests/Program.cs` | 版本断言 → 14、词元数 5 → 4 |
| `tests/EndToEnd.cs` | `analyzer_version==13` → `14`；`爱` 精确查询 → `"爱"*` |
| `tests/SearchLayerTests.cs` | 编译黄金向量更新；新增「单字编译为前缀」「前缀仍能召回」两条断言 |

### 17.6 回退方式

```
KeepCjkEdgeUnigrams = false   // 恢复每字 unigram
AnalyzerVersion = 13
```
然后全量重建索引（`analyzer_version` 变化会自动触发）。

### 17.7 累计召回状态（真实 48,759 首库，需重建后复核）

> ⚠️ 下表是 §13~§16 在 **v13 索引**上的实测值。§17 需要重建索引后重新测量，
> 预期单字查询会进一步收敛（前缀命中的 bigram 范围小于单字 unigram 范围）。

| 查询 | §12 原始 | §15/§16 后（v13 索引） |
|---|---|---|
| `鬱` | 17,955 | 89 |
| `籲` | 11,848 | 0 |
| `爱` | 13,978 | 2,012 |
| `心` | 29,613 | 1,142 |
| `雨` | 17,955 | 753 |

**重建后的复测方法**（待办）：
```bash
cd app/core/indexer
./archoera-indexer build --db <library.db> --index <新 search.db> --full
./archoera-indexer query 爱 --index <新 search.db> --limit 60000 --session
```

---

## 18. 已落地：丢词降级（2026-11-16）

> 补齐「最安全放宽方向」缺失的一块。**不改索引、不需重建**。

### 18.1 问题的本质：三种放宽方向，只有一个安全

面对「多词查询命中不足」，实现上有三种放宽方式：

| 方向 | 例子 | 性质 | 谁在用 |
|---|---|---|---|
| **减词** | `夜 雨 恨` → `夜 AND 雨` | ✅ 仍是**字面匹配**，只是少了约束 | Meilisearch `Last` / Typesense drop tokens |
| **改读音** | `鬱` → `yu` | ❌ 换了维度，语义可能完全无关 | 我们原来的实现 |
| **返回空** | `鬱` → `[]` | ⚠️ 会误伤拼音检索（§12.7） | 简单但不可取 |

改动前我们**只有第 2、3 种**——主趟 0 命中就直接放宽到读音 / 拼音 / 跨语言 / 容错，
唯独缺最安全的第 1 种。§13 的门控堵住了第 2 种在单字上的滥用，但**多词查询仍会走**。

### 18.2 方案：主趟之后、拼音宽松之前插一趟

新的趟次顺序：

```
主趟(词法/拼音/首字母)
  → 【丢词降级】← 新增：仍字面匹配，只是少一个词
  → 拼音宽松
  → 日韩读音
  → 跨语言释义
  → 拉丁模糊
  → CJK 容错
```

**关键设计**：丢词趟放在拼音宽松**之前**。因为「少匹配一个词」比「改读音」更接近用户意图。

### 18.3 实现要点

| 要点 | 做法 | 理由 |
|---|---|---|
| **丢哪个词** | 只丢**末词** | 参考 Meilisearch `TermsMatchingStrategy::Last`（`cost = 1 + last_term_idx - term_idx`，从末词往前丢） |
| **至少留几个词** | 1 | `query_graph.rs:402-404` 的 `res.pop()` 同款保证；丢到 0 个等于返回任意结果 |
| **按什么切词** | 原始查询串按空白切 | **不能用 `tokens.Lexical`**——CJK 已被展平成 bigram（`周杰伦 晴天` → `周杰 杰伦 晴天…`），词边界已丢失 |
| **丢词后用什么趟** | 只重跑主趟（词法 + 读音支） | 本趟语义是「字面少匹配一个词」，不应顺带引入跨语言 / 容错 |
| **无变化时返回 null** | 丢词后表达式与原始相同时不执行 | 避免空转 |

### 18.4 实测（真实 115 首库）

| 查询 | 命中 | 趟次 |
|---|---|---|
| `心跳 zzzz不存在` | 12 | **dropTokens=1** |
| `晴天 zzzz不存在` | 4 | **dropTokens=1** |
| `初音 zzzz不存在` | 32 | **dropTokens=1** |

主趟对这三个查询都是 0 命中（`"心跳 zzzz不存在"` 的裸 MATCH 返回 0），
丢词降级丢掉末词后靠「心跳」召回——**全程没有触发拼音 / 跨语言 / 容错趟**。

### 18.5 开关关闭时的对照（证明价值）

把 `AllowDropTokens = false` 后同一条测试立即失败：

```
FAIL 正例: 多词查询走丢词趟
     ([sky] pinyin=1 reading=0 cross=1 fuzzy=0 cjk=0)
```

注意 `pinyin=1 cross=1`——**关掉丢词后，查询降级成「拼音宽松 + 跨语言释义」**，
正是本节要消除的不安全路径。

### 18.6 改动清单

| 文件 | 改动 |
|---|---|
| `SearchQuery.cs` | 新增 `AllowDropTokens`、`CompileDropTokens()`、`SplitQueryWords()` |
| `SearchSession.cs` | `SearchPassNames.DropTokens`；`PassCounts.DropTokens`；主趟后插入丢词趟 |
| `IndexerJson.cs` | `passes` 增加 `dropTokens` 字段 |
| `search_models.dart` | `LocalSearchPass.dropTokens` |
| `query_log.dart` | `PassCounts.dropTokens` + `labels` 输出 |
| `search_index.dart` | `dropTokensQueries` 计数器与解析 |
| `tests/SearchLayerTests.cs` | 3 条新断言（单词不触发 / 多词触发 / 不拆 CJK 词）+ 端到端掉词命中 |

### 18.7 回退方式

```
AllowDropTokens = false
```
无需重建索引。

### 18.8 为什么只丢末词（未决）

Meilisearch 默认从末词往前丢，但**中文查询的末词未必最不重要**
（`周杰伦 晴天` 的末词「晴天」恰恰是主题）。Typesense 提供 `both_sides` 双向丢弃。

当前实现只丢末词，保守但可能不对称。若要改进，可考虑：
- 按词频丢（Meilisearch `Frequency` 策略：先丢高频泛词）；
- 或双向丢（Typesense `both_sides`，代价是查询数翻倍）。

这需要真实查询日志评估，暂不实施。

---

## 19. 已落地：歌词列降权（2026-11-16）

> 压制歌词列的 df + TF 双重放大。**只改权重表，不改索引、不需重建**。

### 19.1 问题：两个放大机制叠加在歌词列

| 机制 | 证据（真实库 48,759 首） |
|---|---|
| **df 极高** | `晴天` 在标题只命中 **22** 首，歌词里 **225** 首（**10×**）；`的` 单字覆盖全库 42.6% |
| **bm25 的 TF 项** | 歌词文本长、单曲内重复多，TF 进一步抬高得分 |

两者叠加的后果：**「歌词里恰好出现该词」与「歌名就是该词」在同池竞争**。

### 19.2 改动

| 列 | v14 | v15 |
|---|---|---|
| `lyrics_tok`（歌词原文） | 1.5 | **0.6** |
| `pinyin_lyrics_tok`（歌词拼音） | 1.5 | **0.5** |
| `initials_lyrics_tok`（歌词首字母） | 1.5 | **0.5** |

元数据列（title 4.0 / artist 3.0 / album 2.0 / pinyin_meta 2.0 / initials_meta 2.0）**不变**。

**取 0.6 而非 0**：歌词搜索是真实特性（「搜歌词找歌」），完全归零会让「歌词独有的词」搜不到。
0.6 使其仍能召回，但不再压过标题命中。

### 19.3 实测效果（真实库）

**修掉了「歌词命中压过标题」的最典型 case**：

`晴天` 的 top-8 变化：

| 位次 | 旧权重 | 新权重 |
|---|---|---|
| 1 | **30367**（标题+歌词双命中） | 32213（纯标题） |
| 2 | 32213（纯标题） | 33036（纯标题） |
| 3 | 33036（纯标题） | 3778（纯标题） |
| … | 30367 在第 **1** 位 | 30367 掉到第 **7** 位 |

**`love` 更具说服力**：

| 位次 | 旧权重 | 命中来源 | 新权重 | 命中来源 |
|---|---|---|---|---|
| 1 | 18015 | **仅歌词** | 18704 | **元数据** |

即旧实现下**排第一的是纯歌词命中**，降权后纯元数据命中排到前面。

**`米津`**：旧前二 `38605` / `17430` 都是「元数据+歌词」双命中，新前二 `6122` / `7462` 是**纯元数据命中**。

**不受影响的查询**：`夜曲` / `night` 的 top-5 完全不变——它们的命中本就集中在元数据列。

### 19.4 歌词独有词仍可召回（未误伤）

| 词 | 元数据命中 | 歌词命中 | 结论 |
|---|---|---|---|
| `倔强` | 3 | 230 | ✅ 仍可召回（排在后面） |
| `温柔` | 52 | 1,432 | ✅ |
| `拥抱` | 29 | 1,083 | ✅ |

### 19.5 测试：一次失败的尝试与修正（如实记录）

**第一次**：我加了一条端到端断言「歌词 TF 放大不压过纯标题命中」，让 `both` 曲目的歌词重复 40 次。
**结果**：即使权重降到 0.6 仍然失败。

**诊断**：打印分数后发现 **三个曲目的 bm25 全是 `-0.0000`**——
3 篇文档时每列的 IDF 退化，bm25 返回 0，排序退化成 **rowid 顺序**。
**这个语料根本测不出权重影响**，断言的前提不成立。

**第二次**：改为直接在权重表层面断言，并新增 `FtsStore.WeightOf(column)` 测试接缝。

**又发现**：初始断言「lyrics < title/artist/album」在**旧权重 1.5 下也成立**
（1.5 < 2.0/3.0/4.0），锁不住改动。

**最终**：改为「lyrics ≤ album / 2」（0.6 ≤ 1.0 ✅，1.5 ≤ 1.0 ❌）。
验证方式：把权重改回 1.5 → 断言立即失败并报出 `lyrics=1.5 album=2`。

### 19.6 改动清单

| 文件 | 改动 |
|---|---|
| `FtsStore.cs` | 三个歌词列权重降档；新增 `WeightOf(column)` 测试接缝与 `WeightedColumnNames` |
| `tests/SearchLayerTests.cs` | 4 条权重断言（低于专辑 / 不超专辑一半 / 非零 / 歌词拼音同步降档） |

### 19.7 回退方式

把三个值改回 `1.5` 即可，**无需重建索引**（权重是查询期参数）。

### 19.8 与 df 门控的区别（为什么不做 df 门控）

df 门控（Lucene `maxQueryFrequency`）需要在**查询期**统计每个 term 的文档频率，
要么额外查 `fts5vocab`（增加一次全表扫描），要么缓存词表（内存开销）。

而降权是**零成本**的：权重是 bm25 的编译期参数。对于「歌词列 df 天然偏高」这个
结构性问题，降权比逐 term 判 df 更简单、更可预测。

真要做 df 门控，更值得的目标是**拼音列单音节**（§12.9：`yu` 覆盖 7.93%），
而不是歌词列——后者已被降权解决。

---

## 20. 已落地：拼音变体总预算（2026-11-16）

> 补齐调研文档 #5「按候选词数设闸」。**不改索引、不需重建**。

### 20.1 问题：单音节有上限，音节数没有

`MaxPinyinVariantsPerSyllable = 4` 限制了**每个音节**的变体数，
但**音节数量**没有天然上限：

| 输入 | 切分 | 无预算时变体 |
|---|---|---|
| `zongguo` | 2 音节 | ≤ 4 × 1 = 4 |
| `shanghai` | 2 音节 | 4 × 2 = **8** |
| `shanghai shanghai shanghai` | 6 音节（3 词） | 4×2 × 4×2 × 4×2 = **24** |

先确认性能不是瓶颈（真实库实测全部 < 0.25s），所以 #5 的真实价值不是省时间，
而是**限制模糊音扩展的语义发散度**——展开的变体越多，召回的词与用户原意偏离越远。

### 20.2 方案：总预算 + 从尾部往前分配

`DefaultMaxPinyinVariants = 16`（跨音节累计）。

**分配方向**：从**尾部音节**开始消耗预算，首音节最后才拿。
依据：尾部音节通常是查询里最不确定的部分，首音节往往承载主要语义——
与 Meilisearch `TermsMatchingStrategy::Last` 的「首词最不可丢」一致。

预算耗尽后，剩余音节**退回纯原形**（不做模糊音扩展）。

### 20.3 实测：`shanghai shanghai shanghai`

预算 16 时实际编译结果：

```
(("shang" OR "sang")                                        ← 2 个（预算被前面的尾巴用掉）
 AND ("hai" OR "fai")                                        ← 2
 AND ("shang" OR "sang" OR "shan" OR "san")                  ← 4（尾部优先，完整扩展）
 AND ("hai" OR "fai")                                        ← 2
 AND ("shang" OR "sang" OR "shan" OR "san")                  ← 4
 AND ("hai"* OR "fai"*))                                     ← 2
```

变体词合计 **16**，正好等于预算。无预算时是 **18–24** 个。

### 20.4 常规拼音检索零影响（真实库验证）

| 查询 | 期望 | 预算 16 后 |
|---|---|---|
| `qingtian` | 369 | **369** ✅ |
| `yewang` | 159 | **159** ✅ |
| `zhoujielun` | 376 | **376** ✅ |
| `xingfu` | 1,277 | **1,277** ✅ |
| `shanghai` | 881 | **881** ✅ |
| `nihao` | 438 | **438** ✅ |
| `yueguang` | 773 | **773** ✅ |

即常见 2–3 音节查询的完整扩展（≤16）完全不受影响，只有超长输入才被压。

### 20.5 测试：第三次尝试才有效（如实记录）

这条断言我改了三次才真正有效：

1. **`shanghaizhongguobeijing`** → 返回 `null`。原因是 `PinyinSegmenter.MaxWordLength = 12`，
   超过 12 字符的词**根本不会切分**，走不到展开逻辑。
2. **`woaizhongguo`** → 通过，但把预算改成 1000 后**仍然通过**。
   说明这个输入的大部分音节只有 1 个变体（模糊音对不匹配），根本没触发预算。
3. **`shanghai shanghai shanghai`** → 有效。并改用**具体的表达式特征**断言
   （`("shang" OR "sang")` 存在，即该段被压到 2 个变体），而不再用「引号计数」这种脆弱指标。

**验证方式**：把 `DefaultMaxPinyinVariants` 改为 1000 → 断言立即失败并报出
「变体词 18 个（预算 1000）」。

### 20.6 改动清单

| 文件 | 改动 |
|---|---|
| `SearchQuery.cs` | 新增 `DefaultMaxPinyinVariants = 16`；`CompilePinyinLoose` 改为按预算分配变体 |
| `tests/SearchLayerTests.cs` | 1 条预算断言（含表达式特征校验） |

### 20.7 回退方式

把 `DefaultMaxPinyinVariants` 调大（如 `int.MaxValue` 等价于取消预算），**无需重建索引**。

### 20.8 与 Meilisearch 的上限对照

| 机制 | Meilisearch | 我们 |
|---|---|---|
| 限制对象 | 一个词派生出的**候选词数** | 一次查询展开的**变体数** |
| 单错候选上限 | `MAX_ONE_TYPO_COUNT = 150` | — |
| 双错候选上限 | `MAX_TWO_TYPOS_COUNT = 50` | — |
| 我们的对等物 | — | `DefaultMaxPinyinVariants = 16` |
| 单音节上限 | — | `MaxPinyinVariantsPerSyllable = 4` |

取值远小于 Meilisearch 的原因：我们的曲库是**本地**规模（万级），
且拼音音节只有约 400 个、彼此高度重合——放宽到 150 只会引入噪声。
详见 [local-search-indexer-references.md](local-search-indexer-references.md) §3.6。

---

## 21. 已落地：首字符错误算 2 错（2026-11-16）

> 调研文档的最后一个机制（#6）。**不改索引、不需重建**。

### 21.1 问题：首字符错误的语义失真

编辑距离 ≤1 的替换变体里，**改变首字符**的候选最不可靠——
首字母不同通常意味着匹配到了一个**完全不同的词**（`caturday` vs `saturday`）。

Meilisearch 为此专门把「首字符不同」的 1-错候选降级到 2-错档
（`compute_derivations.rs:137-142`，注释原文
「in the case the typo is on the first letter, we know the number of typo is two」；
DFA 用 `Intersection(build_dfa(word,1), Complement(StartsWith(get_first(word))))` 表达，`:120-124`）。

### 21.2 方案：直接不生成首字符替换变体

本项目的模糊趟只有「编辑距离 ≤1」一档，没有 2 错档，所以「降级到 2 错」
等价于**不生成**该变体。

**只影响「替换」这一种操作**：

| 操作 | 是否改变词首 | 处理 |
|---|---|---|
| 删除（`helo → hello`） | 否 | ✅ 保留 |
| 相邻换位（`hlelo → hello`） | 否 | ✅ 保留 |
| 替换首字符（`night → might`） | **是** | ❌ 移除 |
| 替换非首字符（`hello → hallo`） | 否 | ✅ 保留 |

**拼音模糊音不受影响**：`zh/z`、`n/l`、`f/h` 走独立的 `PinyinFuzzyVariants`，
那是**已知的方言混淆规则**（`zhangsan → zangsan` 是真实输入），不是无方向的编辑距离。

### 21.3 实测（黄金向量）

`night` 的模糊变体列表：

**旧行为**（`FirstCharTypoCostsTwo = false`）：
```
"night"* OR "ight"* OR "nght"* OR "niht"* OR "nigt"* OR "nigh"* OR "inght"* OR "ngiht"*
OR "nihgt"* OR "nigth"* OR "might"* OR "naght"* OR "neght"* OR "noght"* OR "nught"*
OR "nijht"* OR "nighd"*
```
→ 含 **`"might"*`**（n → m 的首字符替换）

**新行为**：
→ `"might"*` **消失**，其余 16 个变体全部保留

### 21.4 真实库影响：几乎为零（如实记录）

在 48,759 首真实库上对比开关前后，多组查询的召回量**完全一致**
（`nittel` 0/0、`wight` 1/1、`nello` 3/3、`mightt` 17/17、`night` 512/512）。

**原因**：我们的替换表是**受限字母表**（每个字母只给 2–4 个候选，
如 `n → m`、`l → r`、`b → pv`），不像 Meilisearch 用完整 FST 枚举。
首字符替换能产生的变体本来就很少，且多数与真实词无关。

**结论**：这条改动属于**预防性收紧**——它的价值在于消除一类语义失真，
而非显著改善当前召回。测试用黄金向量锁定行为，而非依赖召回量对比。

> 这与前几节不同：§13–§20 都有真实库的量化收益，本节没有。
> 如实记录，避免夸大。

### 21.5 改动清单

| 文件 | 改动 |
|---|---|
| `SearchQuery.cs` | 新增 `FirstCharTypoCostsTwo`；`EditDistanceOneVariants` 的替换循环起点改为 `1` |
| `tests/SearchLayerTests.cs` | 2 条断言（首字符替换不生成 / 删除与换位仍保留） |

### 21.6 回退方式

改为 `false` 即恢复「首字符也可替换」，无需重建索引。

### 21.7 为什么不做 df 门控（调研文档 #8 类机制）

评估后决定不做，理由见 §19.8：df 门控需要在查询期统计 term 文档频率
（额外扫描 `fts5vocab` 或维护词表缓存），而它要解决的问题
（歌词列 df 偏高）已被 §19 的降权以零成本解决；
剩下的候选目标「拼音列单音节」已有 §20 的变体预算从另一侧约束。

至此，[local-search-indexer-references.md](local-search-indexer-references.md) §6
列出的机制**除 #6 之外的六项全部落地**，#6 于本节落地。

---

## 22. 修正：丢词方向（2026-11-16）

> **产品反馈**：`周杰伦 晴天` 的「晴天」是**歌名**，是最该保留的词。
> §18 照搬 Meilisearch `Last`（从末词往前丢）在这里恰好把歌名先丢掉。
> 这是设计错误，本节修正。

### 22.1 问题：`Last` 策略的前提在中文音乐检索里不成立

Meilisearch `TermsMatchingStrategy::Last`（`query_graph.rs:346-377`）的假设是
「尾部词最不重要」——这在英文查询里通常成立（修饰语后置，如 `red running shoes`）。

但中文音乐检索的主流写法是 **「歌手 + 歌名」**：

```
周杰伦 晴天        → 歌手 + 歌名（歌名在尾部）
陈奕迅 十年        → 歌手 + 歌名
米津玄師 Lemon     → 歌手 + 歌名
```

歌名恰恰在**尾部**，且是最该保留的部分。按 `Last` 丢末词 = **先丢歌名**。

### 22.2 实测：两种方向的召回天差地别

对 `周杰伦 晴天`（歌手 + 歌名）：

**丢末位（旧行为，`Last`）**：
```
("周杰" "杰伦" AND ("周" OR "周"*) AND ("伦" OR "伦"*)
 OR pinyin : "zhou jie lun"  OR initials : zjl)
```
→ 表达式里**没有「晴天」**，等于用「周杰伦」检索 → 返回该歌手的**所有**歌。

**丢首位（新行为）**：
```
("晴天" AND ("晴" OR "晴"*) AND ("天" OR "天"*)
 OR pinyin : "qing tian"  OR initials : qt)
```
→ 表达式**只约束歌名** → 返回那**一首**歌。

> 这就是「丢错词」的实际后果：用户搜「周杰伦 晴天」，得到的是一堆周杰伦的歌，
> 而不是他要的那首《晴天》。

### 22.3 方案：按查询脚本选择丢词方向 + 逐轮尝试

**方向**（`DropTokenCandidates`）：

| 查询类型 | 丢词顺序 | 依据 |
|---|---|---|
| **含 CJK** | 首位 → 尾位（`0,1,2…`） | 中文「歌手 歌名」，歌手在前、歌名在后 |
| **纯拉丁** | 尾位 → 首位（`n-1…0`） | 沿用 Meilisearch `Last`（`love story` 的 `story` 是修饰语） |

参考 Meilisearch 的另一种策略 `Frequency`（`query_graph.rs:303-343`：按词文档频率
降序丢，先丢高频泛词）——它的思路是「越常见的词越不重要」，不依赖位置。
我们选择**按脚本分方向**而非查询期统计 df，避免额外 IO 成本。

**逐轮尝试**（`SearchSession`）：这是修正的**另一半**，同样关键。

只改方向还不够：原实现「丢一次末词就用结果」，丢掉「晴天」后靠「周杰伦」仍能返回
17 条，于是永远轮不到「保留晴天」的丢法。现在改为**逐个候选尝试、命中达到阈值即停**：

```csharp
foreach (var dropIndex in SearchQuery.DropTokenCandidates(tokens, request.Query))
{
    var dropped = SearchQuery.CompileDropTokens(tokens, request.Query, request.Metadata, dropIndex);
    if (dropped is null) continue;
    result.Passes.DropTokens = 1;
    Merge(dropped, SearchPassNames.DropTokens);
    if (result.Items.Count >= request.MinExact) break;   // 命中足够即停
}
```

### 22.4 回归

`archoera-indexer-tests`：**528 项全 PASS**（新增 4 条）：

| 断言 | 锁定的性质 |
|---|---|
| 丢词方向: 中文查询优先丢首位（保留歌名） | CJK 的 `DropTokenCandidates[0] == 0` |
| 丢词方向: 拉丁查询沿用从尾丢 | 纯拉丁的 `[0] == 1` |
| 丢词方向: 丢首位后保留歌名词 | 表达式含「晴天」、不含「周杰」 |
| 丢词方向: 丢末位会退化为「只用歌手」检索 | 反向验证旧行为的缺陷（含「杰伦」、不含「晴天」） |

**有效性验证**：把方向改回「总是从尾丢」→ 第一条断言立即失败并报出 `(1,0)`。

### 22.5 改动清单

| 文件 | 改动 |
|---|---|
| `SearchQuery.cs` | `CompileDropTokens` 增加 `dropIndex` 重载；新增 `DropTokenCandidates()` 按脚本定方向 |
| `SearchSession.cs` | 丢词趟改为**遍历候选、命中达标即停** |
| `tests/SearchLayerTests.cs` | 4 条方向断言 + 1 条端到端（歌手+歌名能命中歌名曲目） |

### 22.6 未决

- **「歌名 歌手」反序**（`晴天 周杰伦`）在中文里也常见。当前方向规则会先丢首位 = 丢歌名。
  **已由 §23 解决**（按元数据字段分布判定，不再依赖位置）。
- 想更精确可考虑 Meilisearch 的 `Frequency` 策略（按词频丢），但需要查询期 df。

---

## 23. 已落地：元数据字段判定（2026-11-16）

> 解决 §22.6 的反序问题：不再靠**位置**猜「谁是歌名」，而是看**元数据字段的命中分布**。

### 23.1 问题：位置不是可靠信号

§22 按脚本定方向（CJK 先丢首位）能覆盖「歌手 歌名」的常见写法，但反向写法同样普遍：

```
周杰伦 晴天      ← 歌手 歌名（首位是歌手，先丢它 ✓）
晴天 周杰伦      ← 歌名 歌手（首位是歌名，先丢它就错了 ✗）
```

只靠位置无法区分。真正可靠的信息在**索引里**：一个词出现在 `title_tok` 还是 `artist_tok`。

### 23.2 方案：按字段亲和度重排丢词顺序

对每个查询词探测两个计数：

```
titleHits  = COUNT(MATCH '{title_tok} : <该词的编译表达式>')
artistHits = COUNT(MATCH '{artist_tok} : <该词的编译表达式>')
歌名倾向   = titleHits - artistHits
```

按「歌名倾向」**升序**丢词（倾向低的先丢，歌名最后才丢）；倾向相同时保持原候选顺序（不瞎猜）。

真实库验证（48,759 首）：

| 词 | `title_tok` | `artist_tok` | 判定 |
|---|---|---|---|
| `晴天` | **22** | 1 | 歌名 ✅ |
| `十年` | **24** | 0 | 歌名 ✅ |
| `周杰伦` | 0 | 0 | 信息不足 → 保持位置顺序 |

### 23.3 实测：两种写法都能保留歌名

| 输入 | 候选（位置顺序） | 重排后 | 保留的词 |
|---|---|---|---|
| `晴天 周杰伦` | `0, 1` | **`1, 0`** | 晴天（歌名）✅ |
| `周杰伦 晴天` | `0, 1` | **`0, 1`** | 晴天（歌名）✅ |
| 两词都无信号 | `0, 1` | `0, 1` | 保持原顺序 |

即**无论用户怎么写顺序，歌名都会被保留到最后**。

### 23.4 成本

每个词 2 次 `COUNT` 查询，且**仅当主趟 0 命中、需要丢词时**才执行（罕见路径）。

实测（真实 48,759 首库）：

| 查询 | 触发丢词 | 耗时 |
|---|---|---|
| `晴天 zzz不存在` | ✅ | 1.08s |
| `zzz不存在 晴天` | ✅ | 1.19s |
| `十年 zzz不存在` | ✅ | 1.22s |
| `晴天`（常规，不触发） | ❌ | 1.11s |

探测开销被现有中文查询开销掩盖（持平），没有可测量劣化。

### 23.5 改动清单

| 文件 | 改动 |
|---|---|
| `FtsStore.cs` | 新增 `CountMatches(expr)`：只取命中总数的轻量计数 |
| `SearchQuery.cs` | 新增 `OrderDropsByFieldAffinity(candidates, titleCounts, artistCounts)` |
| `SearchSession.cs` | 新增 `ProbeFieldAffinity()`；丢词前先探测并重排候选 |
| `tests/SearchLayerTests.cs` | 3 条断言（反向保留歌名 / 正序先丢歌手 / 无信号保持顺序） |

### 23.6 回归

- `archoera-indexer-tests`：**531 项全 PASS**
- 有效性验证：把 `OrderDropsByFieldAffinity` 改成直接返回原候选 →
  `字段亲和度: 反向写法仍保留歌名` 立即失败并报出 `(0,1)`
- `dart analyze lib`：0 issue

### 23.7 未决 / 边界

- **词在库里完全不存在**（`zzz不存在`）：title / artist 都是 0，判定为「信息不足」，
  退回位置顺序。此时它会被优先丢掉——但因为它本来就不存在，丢掉是对的。
- **词在 title 与 artist 命中数相近**：倾向接近 0，判定不可靠，也退回位置顺序。
  这是刻意的「宁可不猜也不错猜」。
- **多词（≥3）**：每轮仍只丢一个词，候选顺序按亲和度排好后逐个尝试，
  命中达标即停。未做「一次丢多个」的组合搜索（成本指数增长）。
