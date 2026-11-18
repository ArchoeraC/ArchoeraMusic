# 本地曲库索引器：外部实现参照调研

> 状态：**调研完成（2026-11-16），未实施**——结论供 §12「字面零命中仍返回大量结果」
> 与 §11「单字查询过宽」的修复选型参考。
> 关联：[local-search-recall-precision-audit.md](local-search-recall-precision-audit.md)（问题复现与量化）、
> [local-search-index-plan.md](local-search-index-plan.md)（架构与验收基线）、
> [licensing.md](licensing.md)、[acknowledgements.md](acknowledgements.md)。
> **本机参考克隆不入库**，位于 `/home/betastudio2/文档/SPlayer-Next/`。

---

## 0. 许可证红线（先读）

| 参考项目 | 许可证 | 本项目可借鉴范围 |
|---|---|---|
| `meilisearch` | 核心 MIT / 企业版 BUSL | 算法思想、参数值 |
| `navidrome` | GPL-3.0 | **仅思想与方法**，禁止移植代码 |
| `typesense` | GPL-3.0 | **仅思想与参数值**，禁止移植代码 |
| `fts5-cjk` | MIT | 可借鉴实现细节（仍建议自行实现） |
| `sqlite-better-trigram` | 公有领域 | 无限制 |

本项目为 **AGPL-3.0-or-later**。参照 GPL-3.0 项目时遵循与
[rendering-reference-research.md](rendering-reference-research.md) 相同的约束：
**只借鉴思想、方法与参数结论**，**禁止逐行/逐段移植其代码**，
**禁止照搬其标识符命名**（`CONTRIBUTING.md`「命名原创」，自有符号统一 `era_` / 既有前缀）。

---

## 1. 参照仓库清单

| 目录 | 仓库 | commit | 定位 |
|---|---|---|---|
| `navidrome` | `navidrome/navidrome` | `2ae6def` | **最贴近**：音乐库 + SQLite FTS5 |
| `meilisearch` | `meilisearch/meilisearch` | `1b78265` | 排序规则流水线的教科书实现 |
| `typesense` | `typesense/typesense` | `208890d` | 查询降级参数（drop tokens） |
| `fts5-cjk` | `Ray0907/fts5-cjk` | `79c52da` | CJK bigram 分词与单字取舍 |
| `sqlite-better-trigram` | `streetwriters/sqlite-better-trigram` | `851f99f` | trigram 短词处理 |

---

## 2. Navidrome：与我们最同构的参照

同样是「音乐库 + SQLite FTS5 + bm25」，实现思路可直接对照。

### 2.1 `ftsQueryDegraded`：查询「退化」判定

`persistence/sql_search_fts.go:308-350`。

**核心思想**：用户输入在分词后如果**丢掉了大量区分性内容**（`1+` → `1`、`C++` → `C`），
拿它去 MATCH 只会得到极度宽泛的结果，此时**不走 FTS，改走 LIKE 兜底**
（`persistence/sql_search_fts.go:355-366`）。

判定规则：
- 原文全是字母数字 → 没丢内容 → 未退化；
- 剥离标点后**所有**有效 token 都 ≤2 字符 → 退化；
- 引号短语内部 token 同样检查。

> **对我们的直接启示**：这与我们的致命问题是**同一类判断**——「这个查询还剩多少区分能力」。
> 但我们的问题比它更严重：Navidrome 退化后走 LIKE（精确子串），
> 我们是退化后**仍然放宽到读音支**，等于朝反方向走。

### 2.2 `(token OR token*)`：一个 OR 同时拿到精确与前缀

`persistence/sql_search_fts.go:169-177`：

```go
prefixTokens[i] = t + "*"                    // 仅用于退化判定
wrappedTokens[i] = "(" + t + " OR " + t + "*)"  // 实际查询
```

注释说明了理由：**精确 ⊆ 前缀**，所以 OR 不增加命中数，
但给 bm25 一个高 IDF 的精确词命中，使「含字面词」的行排在「仅前缀匹配」之前。

> **这是极低成本的分层排序**：不换引擎、不改 schema、不加排序规则，
> 只用一个 OR 就让 bm25 自然分层。我们目前**没有**这个机制——
> 我们的前缀是单纯加 `*`（`SearchQuery.LexicalBranch` / `PinyinBranch`），
> 精确命中与前缀命中在 bm25 里拿不到这个区分。

### 2.3 列权重分级（10 档起步）

`persistence/sql_search_fts.go:201-230`：`title 10.0 / album 5.0 / artist 3.0 / ... 1.0`。

标题给到 10，长尾列给 1，**档距是 2 倍以上**。我们的权重（`FtsStore.cs:63-78`）是
`title 4.0 / artist 3.0 / album 2.0 / lyrics 1.5 / pinyin_meta 2.0 / initials_meta 2.0`，
档距很窄，且 `pinyin_meta` 与 `album` 同档——这正是噪声能排到前排的原因之一（见审计 §12.4）。

### 2.4 两阶段查询

`persistence/sql_search_fts.go:270-290`：Phase 1 只做 FTS MATCH + bm25 排序拿 rowid，
Phase 2 再 join 业务表做复杂排序。注释理由是复杂 `ORDER BY` 不能进 Phase 1。

> 我们已经是这个结构（`FtsStore.Search` 只回 `rowid + score`，再
> `ResolveTrackIds`），无需改动。

---

## 3. Meilisearch：排序流水线（分桶而非打分）

### 3.1 核心设计：`next_bucket`

`crates/milli/src/search/new/ranking_rules.rs:31-58` 定义 `RankingRule` trait，
关键方法是 `next_bucket(universe) -> Option<RankingRuleOutput>`。

**每个规则只在前一规则「打平」的文档集合上继续分桶**，是严格字典序
（lexicographic），**不存在「某维度分高可以补偿另一维度分低」**。

默认规则顺序（`crates/milli/src/search/new/ranking_rules.rs:115-120`）：
`words → typo → proximity → attributeRank → sort → wordPosition → exactness`。

### 3.2 `words` 规则：成本恒为 0 的边

`crates/milli/src/search/new/ranking_rule_graph/words/mod.rs:40-47`：

```rust
fn build_edges(...) -> Result<Vec<(u32, Interned<Self::Condition>)>> {
    Ok(vec![(0, conditions_interner.insert(WordsCondition { term: to_term.clone() }))])
}
```

每条边成本**恒为 0**。「匹配了几个查询词」不是靠加权，而是靠
**「跳过某个词节点」的代价**自然产生：

- 跳过节点的代价 = `ignoring_factor * term_ids.len()`（`ranking_rule_graph/build.rs:49-65`）；
- `rank = next_max_cost - cost`（`graph_based_ranking_rule.rs:250`）→ **丢词越少，桶越靠前**；
- 分数结构体就是「已匹配词数 / 总词数」（`score_details.rs:584-599`）。

### 3.2.1 `TermsMatchingStrategy`：最接近 min-should-match 的机制

`crates/milli/src/search/new/query_graph.rs:346-406`。三种策略：

| 策略 | 行为 | 位置 |
|---|---|---|
| `Last`（**默认**） | **从最后一个词往前丢**，`cost = 1 + last_term_idx - term_idx` | `query_graph.rs:346-377` |
| `Frequency` | 按词频降序丢，先丢高频泛词 | `query_graph.rs:303-343` |
| `All` | 任何词都不许丢 | `graph_based_ranking_rule.rs:189` |

**「至少保留 1 个词」的保证**：`query_graph.rs:402-404` 的 `res.pop()` 把代价最高
（最不该删）的那一批从删除列表里摘掉；短语词与 `mandatory` 词直接不参与删除（:388-391）。

> **这个默认策略对我们的场景极其贴合**：「夜 雨 恨」这类查询，
> 把 `恨` 这个最不像主题词的尾部丢掉，保留 `夜`/`雨`，**仍是字面匹配**。
> 对比我们现在的做法：主趟 0 命中 → 直接放宽到读音支 → 换义。
> **「少匹配一个词」与「改读音匹配」是本质不同的两种放宽方向。**

### 3.3 词长 → 错误数阶梯

`crates/milli/src/index.rs:48-49`：

```rust
pub const DEFAULT_MIN_WORD_LEN_ONE_TYPO: u8 = 5;
pub const DEFAULT_MIN_WORD_LEN_TWO_TYPOS: u8 = 9;
```

即 **1–4 字符不允许错、5–8 允许 1 错、9+ 允许 2 错**，硬上限 2 错。

**注意**：我们审计文档 §3.1 引用的 5/9 与此一致。但这条**只适用于拉丁词**——
中文拼音音节只有约 400 个，5/9 的阶梯毫无意义（审计 §12.9 已实测）。

### 3.4 首字符错误算 **2** 个错误

`crates/milli/src/search/new/query_term/compute_derivations.rs:137-142`：

```rust
// in the case the typo is on the first letter, we know the number of typo is two
if get_first(derived_word) != get_first(word) && !finished_two_typo_words { ... }
```

实现技巧：`Intersection(build_dfa(word,1,is_prefix), Complement(&StartsWith(get_first(word))))`
（:120-124）——「1 个错误且首字符不同」的候选**直接划入 two-typo 集合**。

> **原因**：首字符错误往往意味着匹配到了一个完全不同的词（`caturday` ≠ `saturday`）。

### 3.5 前缀只作用于**最后一个**词

`crates/milli/src/search/new/query_term/parse_query.rs:79-114`：是否前缀**完全取决于
token 流里还有没有下一个 token**（`peekable.peek().is_some()`）。

补充约束：
- 短语内**永不**为前缀（`parse_query.rs:343-355` 硬编码 `is_prefix: false`）；
- 用户「词后带空格」时视为非前缀（`tests/ngram_split_words.rs:12`）。

> 我们的 `MinPrefixTokenLength = 3` 门控只管**长度**，不管**位置**——
> 也就是说我们对每个末词加 `*`，但没检查它是不是真的末词。需核对
> `SearchQuery.LexicalBranch` 的 `prefixLast` 是否已正确限定（注释显示是 `k == chunks.Count - 1`，
> 这部分是对的）。

### 3.6 候选数量硬上限：**按候选词数**，不是按变体数

`crates/milli/src/search/new/limits.rs:1-17`：

```rust
pub const MAX_TOKEN_COUNT: usize = 1_000;
pub const MAX_PREFIX_COUNT: usize = 1_000;
pub const MAX_ONE_TYPO_COUNT: usize = 150;
pub const MAX_TWO_TYPOS_COUNT: usize = 50;
```

关键：**截断发生在派生阶段**（`compute_derivations.rs:64-66 / 97-99 / 129-134`），
以「已收集集合长度」为条件，在 FST 流式遍历中**按字典序**截断 → **确定性的**，不是随机采样。

> 我们现在的 `DefaultMaxFuzzyVariants = 500`（`SearchQuery.cs:51`）是按**变体数**，
> 语义不同：`yu` 展开成 105 个拼音 term 时，我们没有任何「候选词太多就放弃」的闸门。
> 这需要一个真正按「候选词数」计数的上限。

---

## 4. Typesense：查询降级（drop tokens）

### 4.0 ⚠️ Typesense 对 CJK **直接关闭**纠错

`src/index.cpp:5096-5099`：

```cpp
const auto& locale = search_field.locale;
if(locale != "" && (locale == "zh" || locale == "ko" || locale == "ja")) {
    // disable fuzzy trie traversal for CJK locales
    field_num_typos = 0;
}
```

**这是本次调研中对我们最有冲击力的一条**：一个成熟的商业级搜索引擎，在 CJK 场景下
**直接把编辑距离容错关掉**。原因不难理解——CJK 没有「拼写变体」的概念，
字形相近 ≠ 语义相近，模糊匹配只会制造噪声。

> **对照我们的实现**：我们不但没有关闭，还额外**发明了**「CJK 删字/换位容错」
> （`SearchQuery.CjkVariants`，审计 §2.1 第 5 趟），以及「汉字 → 拼音 → 前缀」
> 这条 Typesense 完全没有的链路。审计 §12 实测的 `鬱 → yu → 17,955 条`
> 正是这条自造链路的产物。

### 4.1 `drop_tokens_threshold` 默认值 = **1**

`include/index.h:747`：`static const int DROP_TOKENS_THRESHOLD = 1;`

语义：**当结果数少于该阈值时，丢弃一部分 token 重试**
（`src/index.cpp:4044`）。

### 4.2 丢弃策略：先右后左，至少留一个词

`src/index.cpp:4064-4107`。**注意：实现与注释不一致**——注释说「丢弃命中数最少的 token」，
实际是**按位置从一端逐个丢**：

| 参数 | 值 | 位置 |
|---|---|---|
| 默认方向 | `right_to_left`（**先丢句尾**） | `include/index.h:121` |
| 参与丢弃的 token 上限 | 20 | `index.cpp:4054` |
| 方向数上限 | 2（一轮丢到底后换向） | `index.cpp:4069-4076` |
| 最少保留 | 1 个 token | `index.cpp:4076` |

### 4.3 `typo_tokens_threshold` 默认值 = **1**

`include/index.h:731`。语义：**精确命中达到 1 条就不再放宽 typo**
（`src/index.cpp:5254-5262`）。

> 这正是我们缺的「精确优先」原则的形式化：**先跑一次零纠错查询，够了就停**。
> 我们是反的——主趟 0 命中就一路放宽到读音支（审计 §2.5 的「短路悖论」）。

### 4.4 `min_len_1typo = 4` / `min_len_2typo = 7`

`src/collection.cpp:9723-9724`；判定 `src/index.cpp:7168-7196`：

```
len < 4  → 0 个编辑
len < 7  → 至多 1 个
else     → 至多 2 个
```

比 Meilisearch 的 5/9 **更激进**（4 字符就允许纠错）。另有前置门禁：
纯数字 token 默认不纠错（`enable_typos_for_numerical_tokens=false`，`collection.cpp:9786`）。

### 4.5 `_text_match` 是**位域分桶**，frequency 完全不参与

`include/match_score.h:56-68`，单字段得分：

```
words_present(8b) << 40  |  unique_words(8b) << 32  |  (255-total_cost)(8b) << 24
| (100-distance)(8b) << 16 | exact_match(4b) << 12 | (255-max_offset)(8b) << 4 | synonym(4b)
```

**关键**：`frequency` **完全没有进入打分**，只用于 ART 遍历（`src/art.cpp:1159-1162`）。

> **对我们的直接启示**：我们用 bm25，TF（词频）会主导评分，导致
> **长文本列（歌词）天然压过短文本列（标题）**。Typesense 明确把 frequency 排除在相关性之外。
> 结合审计 §11.3 N-1（单字查询扫歌词列），我们的 `lyrics_tok` 既有高 df 又有 TF 放大器。
>
> 可行做法：给歌词列权重设为 0（`bm25(t, 4.0, 3.0, 2.0, 0, 0, 0, ...)`，
> 让歌词只参与「是否命中」不参与「排多前」），或者干脆走 §6 的 #1（去 unigram）。

### 4.6 字段权重上限 15，且优先级低于「匹配词数」

`include/index.h:737` `FIELD_MAX_WEIGHT = 15`；默认按 `query_by` 顺序递减
（`collection.cpp:4925-4930`）。聚合顺序（`index.cpp:5440-5455`）：

```
tokens_matched(4b) > best_field_score(48b) > field_weight(8b) > num_matching_fields(3b)
```

**即「匹配了几个词」的优先级高于「命中哪个字段」**——与 Meilisearch 的 `words` 规则第一位一致。

### 4.7 前缀只作用于末 token（与 Meilisearch 一致）

`src/collection.cpp:3306 / 3339`，条件均为 `i == tokens.size() - 1`。
默认 `prefix = true`（`collection.cpp:9725`）。

---

## 5. `fts5-cjk`：单字与 bigram 的取舍（对我们最关键的发现）

这个项目的取舍直接对应我们审计 §12 的根因。

### 5.1 默认 `unigram 0`：单字只索引**段首尾**

`cjk.c:217-222` 注释：

> Without `unigram 1`, the first and last character of a run also get positions of
> their own, so a character next to Latin text or digits (第38條, 5月) is a token,
> and 茶* finds a run-final 茶.

即：**中间的单字不单独建 token**，但首尾字符仍在。

### 5.2 实测（本地编译 `cjk.so` 后验证）

```sql
CREATE VIRTUAL TABLE t USING fts5(body, tokenize='cjk');
INSERT INTO t VALUES ('我爱北京天安门');
INSERT INTO t VALUES ('爱情故事');
INSERT INTO t VALUES ('可爱的你');

SELECT body FROM t WHERE t MATCH '爱';    -- 只命中「爱情故事」（段首字）
SELECT body FROM t WHERE t MATCH '爱*';   -- 命中全部三条（含中间/句尾）
```

**结论**：去掉 unigram 后，单字查询**不会丢召回**——
只要把单字查询改为 `字*`（前缀形式），中间字、句尾字都能命中（实测 `爱*` 命中三条，
含 `我爱北京` 的中间字与 `可爱的你` 的中间字）。

命中的范围由 **bigram 的 df** 决定，而不是由单字的 df 决定：
`爱*` 匹配的是所有以 `爱` 开头的 bigram（`我爱` / `爱北` / `爱情` / `爱故` … 的**首位**），
而不是所有含 `爱` 的文档。

### 5.3 真实库上的量化（我们的 48,759 首）

`fts5vocab` 统计 `lyrics_tok` 列：

| 单字 unigram | df | 该字开头最大 bigram | df |
|---|---|---|---|
| `的` | **20,787（42.6%）** | `的X` | 5,631 |
| `我` | 14,727 | | |
| `心` | 13,916 | | |
| `你` | 12,886 | | |
| `爱` | 12,120 | `爱X` | 1,924 |

**这就是噪声的结构性根源**：单字 unigram 的 df 是 bigram 的**3–4 倍**。
`title_tok` 同理：`爱` unigram 覆盖 1,388 首，而 `爱X` bigram 最大只有 133 首。

### 5.4 索引体积代价

`README.md:142`（47k 法条文章实测）：

| 分词方案 | 体积 |
|---|---|
| `unicode61` | 11.7 MB |
| `cjk`（bigram，无 unigram） | 18.3 MB |
| `cjk unigram 1` | 26.3 MB |
| `trigram` | 27.7 MB |

多索引 unigram 的代价是 **+44%**。

### 5.5 `cjk_query()`：无命中时按「命中数最多」切分

`README.md:60-66`：`cjk_query(text, 'table')` 对一个无命中的 CJK 词，
**按「切分后各部分命中数最多」的位置切成 2 段，最多切 3 段**（≤12 字的词），
每次调用最多 256 次探测。

> 这是「用户输入的长词库里没有 → 自动拆成有命中的子词」的工程实现。
> 对我们的价值：`爱如潮水` 这类整词无命中的情况，
> 可以改判为 `爱如 AND 如潮 AND 潮水`（我们已经在用 bigram 短语，等价），
> 但「按命中数选切分点」这一层我们没做。

---

## 6. 汇总：八个可落地的机制，按性价比排序

| # | 机制 | 来源 | 对我们的作用 | 成本 |
|---|---|---|---|---|
| 0 | **CJK 直接关闭编辑距离纠错** | Typesense §4.0 | 我们自造的「CJK 删字/换位」与「汉字→拼音→前缀」链路是 §12 噪声的来源；成熟引擎在 CJK 下**直接关掉纠错** | 改 `SearchQuery`（`CjkVariants` 门控），**无需重建** |
| 1 | **去 unigram，单字改走 bigram 前缀** | `fts5-cjk` §5 | **根治** §12 的「单字扫全库」：单字 df 从 42.6% 降到 ~11% | 改 `Analyzer.AddCjkSegment` + `AnalyzerVersion` 递增 + 全量重建；索引体积 **−30%** |
| 2 | **`(token OR token*)`** | Navidrome §2.2 | 零成本的精确/前缀分层，让字面命中排在前缀命中之前 | 改 `SearchQuery` 几个分支的拼接，**无需重建** |
| 3 | **查询退化判定** | Navidrome §2.1 | 判定「这个查询还有多少区分力」，退化时**不许放宽到读音支** | 新增判定函数 + 在 `CompileMatch` 前置检查 |
| 4 | **从末词往前丢 token（`Last` 策略）** | Meilisearch §3.2.1 / Typesense §4.2 | 多词无命中时「少匹配一个词」而非「改读音」——**安全方向的放宽**，且保证至少留 1 词 | 应用层循环（`SearchSession`），**无需重建** |
| 5 | **`typo_tokens_threshold = 1`：精确优先** | Typesense §4.3 | 精确命中 ≥1 条就不再放宽。我们是反的（0 命中就放宽到读音） | 改 `SearchSession` 的趟次判定，**无需重建** |
| 6 | **按候选词数设闸（150 / 50）** | Meilisearch §3.6 | `yu` 展开成 105 个 term 时中止读音支 | 改 `CompilePinyin`，**无需重建** |
| 7 | **frequency 不参与相关性打分** | Typesense §4.5 | 我们 bm25 的 TF 让歌词列压过标题列，与 N-1 的高 df 叠加 | 调 `Bm25Weights`（歌词权重→0），**无需重建** |

### 6.1 与审计 §12.6 的对应关系

| 审计 §12.6 方案 | 本文参照 |
|---|---|
| P0「读音支须以字面支有命中为前置」 | Navidrome §2.1 退化判定（#3）+ Typesense §4.3 精确优先（#5） |
| P0「短拼音 term 前缀判定反转」 | Meilisearch §3.6 候选上限（#6）+ `fts5-cjk` §5（#1） |
| P1「df 门控（分列设阈值）」 | `fts5-cjk` §5.3 提供结构依据（#1 更彻底） |
| P2「字面 0 命中直接返回空」 | **不推荐**：正确方向是「少匹配词」（#4），不是「返回空」也不是「改读音」 |

### 6.2 一个重要的方向性区分（本文最重要的结论）

面对「多词查询命中不足」，有三种放宽方式，**安全性完全不同**：

| 方向 | 例子 | 性质 | 谁在用 |
|---|---|---|---|
| **减词** | `夜 雨 恨` → `夜 AND 雨` | ✅ 仍是字面匹配，只是少了约束 | Meilisearch `Last` / Typesense drop tokens |
| **改读音** | `鬱` → `yu` | ❌ 换了一个维度，语义可能完全无关 | **我们当前的实现** |
| **返回空** | `鬱` → `[]` | ⚠️ 最严格，但会误伤拼音检索（审计 §12.7） | 简单但不可取 |

**我们目前只会第 2 种和第 3 种，唯独缺最安全的第 1 种。**

### 6.3 我们的实现比三个参照都「更宽松」的地方

这是本次调研最值得警惕的结论：

| 能力 | Navidrome | Meilisearch | Typesense | **我们** |
|---|---|---|---|---|
| CJK 编辑距离纠错 | 无 | 无 | **显式关闭** | ✅ **自造**（`CjkVariants`） |
| 汉字 → 拼音检索 | 无 | 无 | 无 | ✅ **有** |
| 汉字 → 首字母 | 无 | 无 | 无 | ✅ **有** |
| 汉字 → 英文释义 | 无 | 无 | 无 | ✅ **有**（跨语言支） |
| 多词降级（减词） | 无 | ✅ | ✅ | ❌ **无** |
| 精确优先短路 | — | ✅ | ✅ | ❌ **反着来** |

**读法**：前三列是「别人不做的我们做了」——这本身不一定是错（拼音检索对中文用户是真实需求），
但**我们没有配套任何门控**，而所有成熟引擎都有。第四、五行是「别人做的我们没做」——
偏偏这两项正是**防止放宽失控**的机制。

---

## 7. 建议的实施顺序

> **进度（2026-11-16）**：§6 列的机制**全部落地**——
> #0（CJK 读音支门控）、#1（去中间字 unigram）、#2（`(token OR token*)` 精确/前缀分层）、
> #3（查询退化判定 / 单字按脚本分列）、#4（丢词降级）、#5（拼音变体总预算）、
> #6（首字符错误算 2 错）、#7（歌词列降权），见审计 §13–§21。
> df 门控（Lucene `maxQueryFrequency` 一类）评估后不做，理由见审计 §19.8 / §21.7。
>
> **⚠️ 关于 #1 的预期修正**：本文 §5.4 引用的「+44% / 降 30%」体积数字来自
> `fts5-cjk` 的 **bigram → trigram** 对比，**不是**「去 unigram」的收益。
> 真实实测（20k 首语料）：v13 257 MB → v14 256 MB，**体积几乎不变**；
> 收益在召回质量（单字词表 −20%），不在空间。

**第零步（最小改动，直击致命问题）**：#5 + #0。—— ✅ **已落地（#0）**，见审计 §13。
- `typo_tokens_threshold` 语义：**精确命中 ≥1 条就不再放宽**（#5，**未做**）；
- CJK 纠错门控（#0）：CJK 单字查询不生成读音支（拼音 / 首字母），
  拉丁输入与多字 CJK 保留；
- 效果：生僻字从五位数降到个位数/零，合法拼音检索零退化。

**第零·五步（列门控）**：单字查询限元数据列。—— ✅ **已落地**，见审计 §14。
- 单字召回再降 84%~95%（`心` 14,279 → 1,142）；
- 多字 / 拼音查询不受影响。

**第一步（收益最大，需重建）**：#1 去 unigram。
- 单字查询从「扫全库」自动收敛到 bigram 前缀范围；
- 顺带把索引体积降 ~30%；
- **注意**：单字查询必须同步改为 `字*` 前缀形式（已在 §5.2 实测：`爱*` 仍能命中中间字与句尾字，
  **召回不丢**）；若仍用精确 `爱`，则只会命中「以该字开头的段」，召回会大幅下降。
- 需用审计 §8.1 的负例集与 §12.1 的 7 个生僻字验证。

**第二步（零重建成本）**：#2 + #3 + #7。
- 都只改查询编译或权重表，不动索引；
- `(token OR token*)` 做精确/前缀分层（#2）—— ✅ **已落地**，见审计 §16；
  命中集合零变化、精确命中排序显著提前；
- 退化判定堵住读音支（#3，部分由 §13 覆盖），歌词列降权消除 TF 放大（#7，**未做**）。

**第三步**：#4 + #5 + #6 作为兜底与闸门。—— ✅ **#4 已落地**（审计 §18），#5 / #6 未做。
- 丢词降级：主趟不足时先「少匹配一个词」（仍字面匹配），再考虑读音 / 拼音放宽；
- 这是三种放宽方向里唯一安全的一种（见 §6.2）。

> **红线**：任何改动前先固化审计 §12.1 的 7 个字（`鬱`/`籲`/`迌`/`龗`/`靐`/`驫`/`鸞`）
> 与 §12.7 的 3 个合法拼音查询（`qingtian`/`yewang`/`zhoujielun`）作为**双向回归向量**：
> 前者必须显著收敛，后者必须不退化。

---

## 8. 未决问题

1. **单字查询的召回语义变化**：去 unigram 后 `爱*` 匹配「以爱开头的 bigram」而非
   「任何含爱的位置」。实测表明中间字仍能命中（§5.2），但**命中集合确实变了**——
   需要真实查询日志对比新旧结果集，确认用户可感知的召回损失。
2. **`(token OR token*)` 在中文 bigram 上是否有意义**：bigram 本身就是二字符，
   前缀语义需实测（`爱X*` 等价于 `爱X` 全集？）。
3. **退化判定阈值**：Navidrome 用「所有 token ≤2 字符」，中文场景需重新校准。
4. **是否引入 trigram**：`fts5-cjk` 数据显示 trigram 体积最大（27.7 MB），
   且 2 字查询完全失效，对中文曲库不划算。
5. **`TermsMatchingStrategy` 的丢词方向**：Meilisearch 默认从**末词**往前丢。
   中文查询里末词未必是最不重要的（`周杰伦 晴天` 的末词「晴天」是主题），
   需要确定中文场景该按位置丢还是按词频丢（`Frequency` 策略）。
6. **拼音检索要不要保留、以什么形式保留**：三个参照项目**都没有**汉字→拼音检索。
   但真实日志里有 `qingtian` / `zhoujielun` 这类查询（审计 §12.7），说明这是真实需求。
   合理的折中是：**拉丁输入走拼音检索**（用户明确在打拼音），
   **汉字输入不走拼音支**（`鬱 → yu` 这类必然是噪声）。这一条需要产品确认。
7. **是否照 Typesense 关闭 CJK 纠错**：Typesense 强制 `num_typos=0`，
   但我们是本地曲库，用户打错字是真实场景（`孤勇者` → `孤永者`）。
   可能的分层：**中文查询允许「换位」但不允许「删字」**（删字会退化为单字，见审计 §9.2 第 6 条）。
