# 本地曲库搜索索引：歌词模糊搜索设计（Local Library Search Index）

> 状态：**设计草案（未实施）** 2026-10-13
> 范围：为本地曲库增加索引能力，支持**歌词 / 元数据的模糊搜索**（中文优先），
> 重点是 **拼音搜索**与**多语言歌词层（原文 / 译文 / 音译）搜索**；
> `.lrc` 侧车歌词**可选索引（子开关，默认关闭）**。
> **总开关**：索引器整体**默认关闭**，由用户在设置中**手动开启**后才会加载模块 / 建库 / 查询
> （关闭时行为与现状一致，见 §2.4）。
> 关联：[local-library.md](local-library.md)（扫描与刮削）、[lyrics-amll-alignment.md](lyrics-amll-alignment.md)（歌词表现层）、
> [architecture.md](architecture.md)、[licensing.md](licensing.md)。
> 参考实现：KDE **Baloo + KFileMetaData**（`/…/SPlayer-Next/KDE Searcher`）、
> Groonga `TokenBigram`、Lucene `CJKBigramFilter`、Xapian `CJK_NGRAM`、SQLite FTS5 `trigram`。
> 实现语言：**C#（NativeAOT）**，与 `scanner` 同栈（见 §9.1）。

---

## 0. TL;DR

- **目标**：本地 `tracks` + 歌词可"模糊搜"——中文子串、**拼音 / 首字母**、**译文 / 音译层**、繁简互通、英文前缀 / 子串、字段加权、BM25 排序；`.lrc` 侧车歌词可选纳入（子开关，默认关闭）。
- **默认关闭**：整套索引能力受一个**总开关**（设置项 `启用本地曲库搜索索引`，**默认关**）门控；
  未开启时**不加载 indexer 模块、不建 `search.db`、不接管搜索**，搜索回退现有 `LIKE`，行为同现状（§2.4）。
- **核心判断**：这类搜索能不能用，取决于 **分析器（analyzer）+ 查询语义 + 排序**，**与存储引擎无关**。
  先做对分析器，存储先用现成的 **SQLite FTS5**（可替换），不要把力气先花在自研引擎上。
- **算力归属**：拼音 / 繁简 / 译文 的生成是**建索引时的一次性（增量）成本**，**不在查询路径上**；
  查询只分析用户输入的那几个字。因此**不拖慢搜索**——真正影响查询的是**索引体积**，用列过滤 + 分级权重 + 增量缓存控制（§4.5、§7.4）。
- **架构**：`scanner`（既有，写 `library.db`，源真值）→ **`indexer`（新，独立组件，C#，读 `library.db`，写 `search.db`）** → Dart 查询。indexer 仅在总开关开启时经模块注册表按需加载（[module-on-demand-load-plan.md](module-on-demand-load-plan.md)）。
- **查询侧不需要原生模块**：Dart `sqlite3` 直接跑 FTS5 查询；只有**构建 / 分析**在原生侧。
- **非目标**：在线曲库 / 在线歌词（本地数据不依赖）；**离线机器翻译**（只索引已有译文）；设备级 wear leveling。

---

## 1. 背景

### 1.1 现状（代码位置）

- 本地曲库 = SQLite `library.db`，`tracks` 表（`app/core/scanner/SqliteDirectWriter.cs`），
  由 C# NativeAOT `scanner` 直写，Dart 用 `sqlite3` FFI 读（`app/lib/services/scanner/tracks_db.dart`）。
- 现有"搜索"：`title LIKE '%q%' OR artists LIKE '%q%' OR album LIKE '%q%'`（`tracks_db.dart:134`）：
  - 前导通配符 `%q%` **用不上索引**；
  - **完全不覆盖歌词**；
  - 无排序语义。
- 歌词：内嵌标签写入 `tracks.lyrics`（`kfilemetadata` `Property::Lyrics` → `taglibextractor`），
  列表查询**懒加载**不携带（`tracks_db.dart` 显式列）。
- 歌词**已有原文 / 译文 / 音译（罗马音）三层模型**：
  `LyricMatchResult{content, translation, romaji}`（`lib/apis/lyric/types.dart`）、
  `LyricLine{translation, romaji}`（`lib/services/lyrics/lyric_line.dart`）。
- **`.lrc` 侧车文件当前不被读取**（`local_lyric_source.dart` 只取内嵌标签 + `library.db`）；
  本设计**首次引入**对 `.lrc` 的读取（可选，默认关闭，§4.4）。

### 1.2 参考实现（Baloo + KFileMetaData）为什么"几乎无法使用"

对着源码逐条：

| 环节 | 位置 | 问题 |
|---|---|---|
| **分词** | `baloo/src/engine/termgenerator.cpp` | 仅 `QTextBoundaryFinder(Word)`（UAX#29 词边界），**无 CJK 切分、无 n-gram**。源码注释自认："most CJK characters do not trigger a StartOfItem … everything in front of a StartOfItem has to be committed"，即**一整段连续中文（到标点）被当作一个词元**。 |
| **查询** | `baloo/src/lib/searchstore.cpp` `constructContainsQuery` → `constructEqualsQuery` | "Contains" 实为**前缀匹配**（单词元、≥3 字节）或**精确短语**（多词元按位置相邻）。**没有子串、没有模糊 / 编辑距离**。 |
| **正则** | `baloo/src/engine/postingdb.cpp` `regexpIter` | 子串只能靠它，但**未接入正常查询路径**，且仍是词表前缀扫描。 |
| **排序** | `baloo/src/lib/searchstore.cpp` `sortResults` + `query.cpp`（`SortAuto`） | **按 `mtime` 倒序**，**无 BM25 / TF-IDF**。 |

结论：中文歌词里，除了"整段开头"，任何子串都搜不到（"我爱你中国" 是单个词元，搜"中国"不命中），
且命中顺序按文件时间。**失败在分析器 / 查询 / 排序三件套，不在存储层**——它的存储（`doctermscodec`
前向编码、`positioncodec` delta+varint、`postingdb` 前缀游标）反而是可借鉴的原料。

> 另：歌词**确实被索引**了（`kfilemetadata/src/propertyinfo.cpp` `Property::Lyrics` 的
> `shouldBeIndexed = true`），所以这不是覆盖率 bug。

### 1.3 目标 / 非目标

**目标**：本地曲库（`tracks` + 歌词）支持：
1. 中文**子串 / 词**搜索（"爱你" → 命中"我好爱你啊"）；
2. **拼音搜索**：全拼（`woaini`）、首字母（`wan`）、混合（`woai`）/ 模糊拼音；
3. **多语言歌词层**：**原文 / 译文（翻译）/ 音译（罗马音）** 三层都可被检索（按内容语言各自分析）；
4. **繁简互通**（搜简体命中繁体歌词）；
5. 英文**前缀 / 子串**；
6. **字段加权**（标题 > 歌手 > 专辑 > 歌词）与 **BM25 相关性排序**；
7. **`.lrc` 侧车歌词**纳入索引（**子开关控制，默认关闭**，见 §4.4；总开关关闭时不适用）；
8. 分页、搜索范围可选、结果高亮（可选）。

**非目标**：
- 在线源 / 在线歌词搜索（本地数据，不依赖网络）；
- **离线机器翻译**（只索引文件 / 标签 / `.lrc` 中**已有**的译文，不现场翻译）；
- 跨库联邦搜索；设备级磨损均衡；把索引做成"可变事务型主库"。

---

## 2. 需求与验收

### 2.1 功能需求

- 查询字段：`title | artists | album | lyrics（原文） | lyrics_tr（译文） | lyrics_rom（音译） | filename`（可组合）。
- 匹配模式：子串、前缀、短语、**拼音（全拼 / 首字母 / 混合）**、**译文 / 音译层**、繁简（见 §4）。
- **总开关**：设置项 `启用本地曲库搜索索引`（**默认关**）；关闭时整套索引能力不生效（§2.4）。
- **`.lrc` 侧车歌词**：受子设置项 `索引 .lrc 侧车歌词`（默认 **关**）控制；仅总开关开启时可用，开启后与内嵌歌词一起纳入。
- 输出：按 BM25 相关度（+ 少量 recency 兜底）排序的 `track id` 列表，可翻页。
- 交互：输入去抖（沿用 `library_store_core.dart` 的 250ms）；空查询 = 原列表。

### 2.2 非功能需求（预算，待实测校准）

| 指标 | 目标 |
|---|---|
| 首次全量构建（25k 曲、含歌词 + 拼音 + 译文 + `.lrc`；**总开关开启后**） | ≤ 2–5 min（后台；与解析解耦，含拼音生成） |
| 增量更新（变更 K 首） | ≈ K 成正比，秒级 |
| 查询延迟 P50 / P95 | ≤ 20ms / ≤ 80ms |
| 索引体积 | ≈ 歌词语料量级（~100–300 MB @ 25k 曲） |
| 峰值内存 | ≤ 数百 MB，可限（批大小自适应） |
| 平台 | Linux / macOS / Windows，**进程内 FFI、无提权、无子进程**（遵守 AGENTS.md） |

### 2.3 验收基线

用一组标注中文歌词查询（§8）对比四种 analyzer 的召回@k / MRR，**先用数据定分析器参数**，再谈存储。

### 2.4 总开关与默认行为（**默认关闭，用户手动开启**）

索引器是**可选增强**，不是默认能力。整套能力由一个总开关门控：

- **设置项** `启用本地曲库搜索索引`，**默认关**（`false`）。
- **关闭时（默认态，等价现状）**：
  - **不加载** indexer 原生模块（不 `acquire`，符合 [module-on-demand-load-plan.md](module-on-demand-load-plan.md) 的按需语义）；
  - **不构建 / 不更新** `search.db`，**不调度**任何增量；
  - 搜索**回退**现有 `title/artists/album LIKE '%q%'`（`tracks_db.dart`），结果与排序同现状；
  - 不读 `.lrc` 侧车。
- **开启时**：
  - 经模块注册表按需加载 indexer → 首次**全量构建** `search.db`（后台，§3、§7），完成后增量维护；
  - 搜索切换到 FTS5 `MATCH + bm25()`（§5、§9.3）；`.lrc` 子开关此时才生效。
- **开关切换语义**：
  - 关 → 开：若 `search.db` 不存在，触发全量构建；已存在则按世代增量收敛（不阻塞 UI）。
  - 开 → 关：立即停止调度与查询接管，回退 `LIKE`；**取消在途构建**（透传 `indexer_cancel`，
    在途关键段 await 后因总开关已关而不重开连接）；`search.db` 作为**派生数据**默认**保留**
    （避免每次开关都全量重建），设置页另提供「重建索引 / 删除索引」动作；用户删除即释放空间，下次开启再建。
  - **应用启动时**：若总开关已开，**后台触发一次预构建**（`SearchService.warmUpOnStartup`，
    不阻塞首帧、失败静默降级、幂等）；关闭时**不触碰**模块 / `search.db`。
- **失败降级**：模块加载 / 构建失败**不阻断**搜索——自动回退 `LIKE` 并在设置页提示（索引是派生数据，可随时重建）。
- 这是**用户可见、可回退**的能力：默认零成本、零磁盘占用，用户显式开启后才付出构建时间与索引体积（§7.1）。

---

## 3. 总体架构

```
┌────────────┐  写（既有，源真值）   ┌──────────────┐   读+分析    ┌────────────┐
│  scanner   │ ───────────────────▶ │  library.db  │ ───────────▶ │  indexer    │
│ (C#/AOT)   │   tracks(+lyrics)    │  (SQLite)    │  世代/增量   │ (C#/AOT 新) │
└────────────┘                      └──────────────┘              └─────┬──────┘
                                                                        │ 顺序写
                                                     ┌──────────────────▼───────────────┐
                                                     │ search.db（FTS5；世代化、可重建） │
                                                     └──────────────────▲───────────────┘
                                                                        │ 查询（MATCH + bm25）
                                        ┌──────────────┐   只读+SQL    │
                                        │  Dart UI     │ ──────────────┘
                                        │ (sqlite3 FFI)│   ← 分析器词元经 indexer_analyze FFI 取得
                                        └──────────────┘
```

要点：

1. **scanner 与 indexer 分离**：扫描在用户等待路径上；索引构建离线 / 空闲调度，避免拖慢扫描进度。
2. **索引不是源真值**：`library.db` 是唯一真值；`search.db` 可随时删除重建（`search.db` 落后是可接受的短暂状态）。
3. **查询侧零原生依赖**：Dart `sqlite3` 直接对 `search.db` 跑 FTS5 `MATCH` + `bm25()`；
   唯一共享的是**分析器**——通过 `indexer_analyze` FFI 取词元串，保证测试向量一致（避免 Dart / C# 双实现漂移）。
4. **生命周期**：indexer 为独立 NativeAOT 模块，与 scanner 同级；仅在**总开关开启**时经模块注册表按需
   `acquire`，**常驻、不卸载**（NativeAOT 后台线程无法安全 `dlclose`，见 `docs/module-on-demand-load-plan.md`）；
   总开关关闭时不加载（§2.4）。
5. **默认关闭**：总开关默认关（§2.4）。关闭时上图整条 indexer / `FTS5` 链路**不参与**，Dart 搜索直接走
   `library.db` 的 `LIKE`（现状）。

---

## 4. 分析器（本项目真正的核心）

分析器对**索引**与**查询**必须**同构**。总链：

```
归一化 → 脚本切分 → 分词（CJK bigram / 拉丁整词） → 派生层（拼音 / 译文 / 音译 / 繁简） → 词元流
```

### 4.1 归一化与分词

1. **归一化**：NFKC（逐字符兼容折叠，全范围含非 BMP / 星平面，离线表 `data/nfkc.tsv`）→ 小写 → 全角转半角 → **繁转简** → 去标点 / 折叠空白。
2. **脚本切分**：按字符类分 CJK / 拉丁 / 数字 / 其它。
3. **分词**：
   - **CJK → bigram（n=2）**；单字回退 **unigram**（保证 1 字查询可命中）。
     > 依据：Groonga 默认 `TokenBigram`、Lucene `CJKBigramFilter`、Xapian `CJK_NGRAM`。
     > bigram 在中文上是精度 / 召回的惯用折中（优于 unigram，接近词级切分且无需词典）。
   - **拉丁 / 数字 → 整词**（不 n-gram）；查询侧允许**前缀**（`love` → `love*`）。
4. **词元流**：输出以空格分隔的词元串，交 FTS5 `unicode61` 存储（§5）；保留位置供短语 / 邻近查询。
   查询侧对**连续多个 CJK bigram** 改用引号短语（`"我爱 爱你"`，要求位置相邻）提升中文短语精度（P4）。

### 4.2 拼音搜索（重点之一）

对**任意含 CJK 的层**生成拼音，写入独立列：

- **全拼**：`我爱你` → 音节 `wo` / `ai` / `ni`（音节间空格，作独立 token）；
- **首字母**：`我爱你` → `wan`（整串作单 token）；
- **混合**：查询侧把 `woaini` / `woai` / `wan` 都归一成"音节目元"与"首字母元"两种形态再匹配。

索引侧与查询侧一致：

- 全拼：查询串切分为音节 → `AND` / 短语；**末音节允许 `prefix`**（`woai` → `wo` + `ai*`），支持边打边搜；
  查询侧对**连写拉丁**按有效音节切分（`woaini` → `wo ai ni`；完整覆盖才切、否则保留整词如 `hello`），
  音节数 ≥2 时追加「首音节前缀」变体以覆盖 `w ai ni` 一类混合输入（P4）；
  **英文过度切分门控**（P4 修复）：最长优先结果须满足「音节数 ≥2 且每个音节长度 ≥2」，
  否则整体拒绝（`banana` 不再切成 `ban an a`、`adele` 不再切成 `a de le`），宁可少切也不要误切；
  已知残留 `panda` → `pan da`（短同形词与 `mama`(妈妈) / `women`(我们) 无法区分，不拦截）；
  长度 ≥6 的英文词（`aiding` / `shanghai`）不再有阻断表保护，会按音节切分
  （`ai ding` / `shang hai`）——方向 A 重构已删除 `data/en_blocklist.tsv`，此为已知取舍；
- 首字母：查询首字母串直接匹配；
- **多音字**：默认取主读音；高频多音字可索引**受控的多个候选**（膨胀是否可接受 → §8 评估）。
- 数据来源与许可：见 §9.4。

### 4.3 多语言歌词层：原文 / 译文 / 音译（重点之二）

歌词常是**多层**（见 [lyrics-amll-alignment.md](lyrics-amll-alignment.md)：译文行、音译 / 罗马音行）：

- **层来源**：① 内嵌标签 `tracks.lyrics`（可能含多语言行）；② `.lrc` 侧车（§4.4）；③ 歌词管线解析后的**原文行 / 译文行 / 音译行**。
- **层模型已存在**：管线本就区分三层——`LyricMatchResult.content / translation / romaji`（`lib/apis/lyric/types.dart`）
  与 `LyricLine.translation / romaji`（`lib/services/lyrics/lyric_line.dart`）；indexer 直接消费该模型，不必另造。
- **每层独立列**：`lyrics_tok`（原文）/ `lyrics_tr_tok`（译文）/ `lyrics_rom_tok`（音译），使：
  - 搜**译文**（如中文翻译）能命中；
  - 搜**音译 / 罗马音**能命中；
  - 排序可对**原文**层加权更高，避免译文喧宾夺主。
- **按内容语言选分析器**：中文层 → bigram + 拼音；英文层 → 拉丁整词 + 前缀。
- **本期实现（T0，已落地）**：indexer 从**内嵌 `tracks.lyrics`** 与 `.lrc` 侧车按
  **相同时间戳多行**启发式（第 1 行原文、其后纯拉丁行音译、其余首个非拉丁行译文；
  另有显式 `<name>.trans.lrc` / `<name>.romaji.lrc` 侧车）拆分原文 / 译文 / 音译三层，
  分别写入 `lyrics_tok` / `lyrics_tr_tok` / `lyrics_rom_tok`；纯文本整体归原文，
  无译文 / 音译则对应列空。原文层**不回退**（不把译文 / 音译混入）。`AnalyzerVersion` 4→5 触发全量重建。
- **不现场翻译**：只索引**已有**译文（§1.3）。**跨语言检索**已**部分实现**（T1，见 §11.9）：
  查询侧用 Unihan 释义扩展把英文词 → 候选汉字、汉字 → 英文词作为**第 4 条 `OR` 分支**
  （仅查询侧，不改索引内容 / 不递增 `AnalyzerVersion`）；更高覆盖率的**向量检索 / MT**
  仍不在本期（T2 另立）。

### 4.4 `.lrc` 侧车歌词（可选，默认关闭；总开关关闭时不适用）

- 约定：与音频同目录、同名 `.lrc`（大小写不敏感）。
- 子设置项 `索引 .lrc 侧车歌词`（默认 **关**）；**仅当总开关「启用本地曲库搜索索引」开启时才有意义**；
  关闭时不读、不索引，行为同现状。
- 解析：复用现有 LRC 解析（`app/lib/services/lyrics/`），只取**文本行**（丢时间轴）。
- 增量：`.lrc` 的 `(mtime, size)` 纳入脏集（§6）——侧车改动 → 该曲重索引。

### 4.5 算力归属与"为什么不拖慢搜索"

必须正面回答你担心的这一点：

- **生成（重）在索引时**：拼音 / 繁简 / 逐层分析对**全库文本**跑一次（增量只跑脏文档），
  是后台一次性成本；C# 多线程 + 批处理，不阻塞 UI、不阻塞扫描（§3）。
- **查询（轻）在查询时**：只分析**用户输入的那几个字**，与库大小**无关**。
- **真正影响查询速度的是索引体积**（多列 → 段更多）。对策：
  1. **列过滤**：`MATCH '{lyrics_tok} : ...'` 只扫指定列，元数据查询不触歌词段；
  2. **分级权重**：`bm25()` 权重集中；
  3. **可选物理分离**：把最重的歌词（含拼音 / 译文）索引放**单独 FTS 表 / 文件**，元数据查询完全不触达；
  4. **缓存**：每曲分析结果持久化在 `search_docs`，重索引只重算脏曲；
  5. 铁律：**绝不把拼音 / 翻译放在查询路径上做**——那才是"拖慢搜索"的根源。

### 4.6 参考实现对照

| 引擎 | CJK 分词 | 子串 | 模糊 / 容错 | 拼音 | 译文 / 多语言 | 排序 |
|---|---|---|---|---|---|---|
| **Baloo** | 无（词边界，整段一词元） | ❌（仅词表前缀） | ❌ | ❌ | ❌ | ❌（按 mtime） |
| **Groonga** (`TokenBigram`) | **bigram**；拉丁整词（`unify_alphabet/digit/symbol`）| ✅ | 短语 / `loose_*` | ❌ | ❌ | ✅ BM25 |
| **Lucene** `CJKBigramFilter` | **bigram**（CJK）| ✅ | 分析器组合 | ❌ | 多字段（自建） | ✅ BM25 |
| **Xapian** `CJK_NGRAM` | **n-gram** | ✅ | CJK n-gram | ❌ | ❌ | ✅ |
| **FTS5** `trigram` | **trigram**（全字符）| ✅（≥3 字符）| ✅ 一定程度 | ❌ | 多列 | ✅ `bm25()` |
| **Meilisearch** | char n-gram + 字典 | ✅ | ✅ 前缀 + 编辑距离 | ❌ | 多字段 | ✅ |

> 拼音 / 繁简 / 译文层 **所有通用引擎都不提供**，必须我们自己预处理——这正是"自研分析器"的价值，
> 也是 Baloo 与现成引擎都缺的一环。

**本期容错实现（P4，`search_query.dart` / `search_cjk_fuzzy.dart` / `search_index.dart`）**：
不引入索引侧词典 / 触发器，在**查询编译**侧做**分级（三趟）**：

1. 第一趟精确 `compileMatch`（现状三支 OR）；命中数 ≥ 阈值（默认 1）→ 直接返回，**不触发**后续；
2. 命中不足且查询含**拉丁/数字词法词元**时，第二趟 `compileFuzzy`：把这些词元展开为
   **编辑距离 ≤ 1 的变体 OR 组**（删除 / 相邻换位 / **受限字母表替换**，不含插入；原词保留），
   变体仍逐个转义、末词元仍加前缀 `*`；单次变体总数受 `maxVariants`（默认 500）约束，
   超限只扩展末个拉丁词元。拼音分支天然覆盖**同音错字**（错字与正字拼音相同 → 命中），
   故不重复扩展；模糊仅为精确的**超集**，召回放大由 BM25 排序约束；
3. 仍不足且查询含 **CJK** 时，第三趟 `_runCjkVariants`：取查询的 **CJK 子序列**生成
   **编辑距离 ≤ 1 变体**（**删除任一字符 / 相邻换位**，预算默认 ≤ 200 变体，
   纯 Dart `cjkVariants`；不含插入），每个变体经**原生分析器**（`indexer_analyze`，
   保证同构，不在 Dart 重实现分词）分析 → `compileMatch`，再合并为**单条** OR
   `MATCH` 一次查询；结果与前面趟次合并去重、原始优先。
   失败（无分析器 / 无变体 / 编译为空）仍降级返回。**覆盖边界**：
   拼音分支是「**音节 AND、与位置无关**」，故纯 CJK 的**漏字（音节子集）/ 换位（音节集合不变）**
   其实已被第一趟拼音覆盖；第三趟的增量价值主要在**查询多打一字 / 打错成非同音字**
   （删除错字后子集命中，如 `周杰美`→`周杰`）。**替换型非同音错字（周杰伦→周杰轮）**
   仍需相似字表，**不在本期**。

**跨语言查询扩展（T1，`Analyzer.AnalyzeQuery` + `search_query.dart`）**：与容错并列的第 4 条查询分支——
原生分析器用 Unihan 释义扩展（`data/def_en2hanzi.tsv` / `data/def_hanzi2en.tsv`，`EmbeddedResource` 内嵌）
把拉丁 / 数字词映射为候选汉字、CJK 字映射为英文释义词，逐候选 `quoteToken` 以 `OR` 组合（总预算 ≤ 32、
去重、并剔除与查询拼音音节同形的噪声候选）；空则不加此支。**仅改查询侧**（`AnalyzeQuery`），
索引侧 `Analyze` 与索引内容不变，故 T1 自身不递增 `AnalyzerVersion`。

**结果高亮（P4，`search_highlight.dart` / `search_highlight_pinyin.dart`）**：字面匹配之外，
索引开启且已加载分析器时，用查询词元（`pinyin` / `initials`）在**展示文本的 CJK 段**内做
连续 / 前缀匹配，命中汉字区间（`woaini` / `wan` 命中「我爱你」越段高亮）；按 `(text, query)`
记忆化、只对可视行调用，关闭态零成本。

---

## 5. 存储层（`IndexStore`，可替换）

### 5.1 接口

引擎只是实现细节，先冻结接口：

```
interface IndexStore {
  open(path, mode);                 // mode: build | read
  schemaVersion();                  // 版本不匹配 → 触发重建
  put(docId, fields: DocTokens);    // 写入一篇文档的分析后词元
  delete(docId);
  commit();                         // 落盘 / 换世代
  search(tokens, fields, limit, offset) -> List<(docId, score)>;
  optimize();                       // 离线 merge（非热路径）
}
```

### 5.2 实现 A（推荐先行）：SQLite FTS5

- 库文件：`search.db`（与 `library.db` 分离，便于独立重建 / 分介质放置）。
- 结构：**预分词**后写入内容列，交给 `unicode61` 存储（**无需自定义 C tokenizer**，可移植）：

```sql
CREATE TABLE search_docs (
  doc_id         INTEGER PRIMARY KEY,     -- 映射 tracks.id
  track_id       TEXT NOT NULL UNIQUE,
  title_tok      TEXT, artist_tok TEXT, album_tok TEXT,
  lyrics_tok     TEXT,                    -- 原文
  lyrics_tr_tok  TEXT,                    -- 译文
  lyrics_rom_tok TEXT,                    -- 音译 / 罗马音
  pinyin_tok     TEXT,                    -- 原文拼音（全拼音节 + 首字母）
  filename_tok   TEXT,
  indexed_mtime  INTEGER, indexed_generation INTEGER, schema_version INTEGER
);
CREATE VIRTUAL TABLE search_fts USING fts5(
  title_tok, artist_tok, album_tok,
  lyrics_tok, lyrics_tr_tok, lyrics_rom_tok, pinyin_tok, filename_tok,
  content='search_docs', content_rowid='doc_id',
  tokenize='unicode61'
);
```

- 排序：`ORDER BY bm25(search_fts, w_title, w_artist, w_album, w_lyrics, w_lyrics_tr, w_lyrics_rom, w_pinyin, w_filename)`。
  权重示例：标题 4.0 / 歌手 3.0 / 专辑 2.0 / **原文歌词 1.5** / 拼音 2.0 / **译文 1.0** / **音译 0.5** / 文件名 1.0（评审时定）。
- `.lrc` 开关开启时，侧车文本行并入 `lyrics_tok`（保留来源标记以便排歧）。
- **列过滤**：元数据查询用 `MATCH '{title_tok artist_tok album_tok} : ...'`，不触歌词 / 拼音列（§4.5）。
- 查询：查询串经**同一分析器** → 词元 → 拼 `MATCH` 表达式（含 `prefix` / 引号短语）。
- **为什么不用触发器 / external-content + 自定义 tokenizer**：
  1. 分析器无法在纯 SQL 触发器里运行；
  2. 自定义 FTS5 tokenizer 需要 C 扩展且要在**每个**连接注册（Dart + C#），复杂度高；
  3. 两个写入者（scanner / Dart）会让触发器同步易错。
  故由 **indexer 独占写**，`search.db` 只读多连接（WAL）。

> 快速基线（用于 §8 评估）：可直接用 FTS5 `tokenize='trigram'` 零分析器起步，
> 但 trigram 对 <3 字符查询无效、且无拼音 / 繁简，仅作对照。

### 5.3 构建策略：世代化（崩溃安全 + locality）

- 构建到 `search.db.tmp` → `fsync` → **原子 rename** 替换 `search.db` → 删除旧世代。
- 好处：写入全程**顺序**（从零顺序分配页），且写入**分散到不同世代文件**——
  对 HDD / 闪存 / COW 文件系统（Btrfs/ZFS/APFS）的**写局部性**最友好；
  读路径读只读的旧世代直到切换。
- 重建立即可重来；索引损坏 = 删除重建。

### 5.4 冷热分离

`play_count / rating / last_played` 等**高频小写**绝不进倒排索引——它们放独立的小可变表（普通 B-tree / 甚至追加日志）。
搜索索引只接受**批量 / 低频**变更（导入、纠错）。这是本轮讨论最重要的设计规则。

### 5.5 实现 B（条件触发）

仅当 §7 实测 FTS5 在目标介质（尤其 HDD）上 **checkpoint 随机回写**导致 locality / 磨损不达标时，
才在 `IndexStore` 之后实现自研 **KV 分离 LSM / append-only 段**
（postings 进追加 value-log，`term→offset` 目录可变，后台 compact）。
此时它**有测量支撑**，而不是先验假设。

---

## 6. 增量与一致性

- **源真值**：`library.db`。indexer 只读它，写 `search.db`。
- **总开关门控**：增量调度**仅在总开关开启时**运行（§2.4）；关闭时既不构建也不维护，
  `search.db` 冻结（保留但不再更新），搜索回退 `LIKE`。
- **世代水位线**：scanner 每轮扫描递增 `scan_generation`（新增元数据表 `_scanner_meta(generation INTEGER)`）；
  `search.db` 记 `applied_generation` 与每篇 `indexed_mtime`。
- **脏集判定**（确定性，不靠"猜"）：

  ```
  待处理 = tracks 中：新增 或 file_mtime ≠ indexed_mtime 或 indexed_generation < applied_generation
  待删除 = search_docs.track_id 不在 tracks 中
  ```

- **`.lrc` 侧车**（总开关 + 子开关均开启时）：侧车 `(mtime, size)` 变化 → 该曲重索引；关闭**子开关** → 侧车内容从索引移除（总开关关闭时整体冻结，§2.4）。切换子开关即时触发一次增量收敛（P4），无需手动「重建索引」。
- **分析器 / schema 版本**：`analyzer_version` / `schema_version` 变化 → 强制**全量重建**（拼音 / 译文派生随之刷新）。
- `applied_generation < scan_generation` ⇒ 索引落后（可触发增量）。
- **read-your-writes 不保证**（索引是派生数据）：搜索可短暂落后于曲库，符合预期；
  用户可见的"改了标签但还没搜到"由"空闲自动增量"收敛。
- **崩溃恢复**：世代化构建（§5.3）保证 `search.db` 要么旧、要么新，不会半写。

---

## 7. 性能与平台（locality / 磨损）

### 7.1 量级估计

- 25k 曲 × 2–8 KB 歌词 ≈ **50–200 MB** 语料；bigram 词元流 + 拼音 + 译文层后，**索引 ≈ 1.5–3× 语料**（含拼音 / 译文列）。
- **索引仍约为媒体体积的 0.1–1%**（230 GiB 媒体 vs 数百 MB 索引）；"超量索引载不进内存"不成立。

### 7.2 SQLite 的真实弱点与对策

- **WAL 写入是顺序的**，但 **checkpoint 会把页按原页号写回主库原位 → 随机写**
  （HDD 寻道；闪存擦除块 RMW）。
- 对策：**世代化构建**（§5.3，从零顺序写 + 分散到多文件）+ **延迟 / 合并 checkpoint**
  （调大 `wal_autocheckpoint`，扫描结束一次性 `wal_checkpoint(TRUNCATE)`）+ 冷热分离（§5.4）。
- 四类介质（HDD / eMMC-SD / COW FS / NVMe）的**共同分母**：**顺序 + 批量 + 低频 + 轮转**。

### 7.3 测量（先量再定）

- 分阶段计时：collect / read / parse / **analyze（拼音 + 分层）** / write / merge / commit。
- 写入量：`/proc/self/io` 的 `write_bytes`（Linux）；外部 `iostat`；索引体积。
- 查询：P50 / P95 延迟。

### 7.4 查询延迟不被拼音 / 翻译拖累

- 拼音 / 繁简 / 译文全部在**索引期**计算；查询期只分析用户输入串（§4.5）。
- 索引变大只增**体积 / 构建时间**，不增**单次查询**的算法复杂度（FTS5 仍是 postings 归并 + 列过滤）。
- 验收需实测：**开 / 关拼音与译文列**两种配置下的查询延迟差异（预期 < 2×，且绝对值仍远低于 80ms）。

---

## 8. 评估 harness（**先做这一步**）

目的：**用真实中文歌词量化"是否可用"，据此定分析器参数**，再决定存储。

- 输入：`library.db` 的 `tracks.lyrics`（抽样 N 首，含中英文）；`.lrc` 开关下的侧车样本。
- 对照 4 种 analyzer：
  1. `Baloo 式`（词边界 + 前缀）——基线；
  2. `FTS5 trigram`；
  3. `bigram`（CJK）+ 拉丁整词；
  4. `bigram + 拼音（全拼 / 首字母）+ 繁简 + 译文层`。
- 查询集：人工标注的**中文子串 / 短语 / 拼音（全拼 / 首字母 / 混合） / 错字 / 繁体 / 译文查询**。
- 指标：召回@k、MRR、NDCG@k、构建耗时、索引体积、查询延迟（开 / 关拼音与译文列）。
- 产出：**analyzer 规范定案**（n 取值、拼音粒度、多音字策略、字段权重）。

建议以脚本 + 小样本先行（可复用 `app/core/scanner/bench` 的形式）。

---

## 9. 模块与集成（对齐仓库约定）

### 9.1 新原生模块 `app/core/indexer`（C# NativeAOT，与 scanner 并列）

```
app/core/indexer/
  indexer.csproj            # net10.0 / NativeAOT / AllowUnsafeBlocks
  Program.cs                # CLI: indexer build [--full] [--index-lrc]
  IndexerEngine.cs          # 增量调度 + 分层分析 + 写 FTS5
  Analyzer.cs               # 归一化 / bigram / 繁简 / 分层（核心）
  Pinyin.cs                 # 汉字→拼音（全拼 + 首字母；多音字候选）
  LrcReader.cs              # .lrc 侧车读取（开关控制）
  FtsStore.cs               # IndexStore 的 FTS5 实现
  indexer-ffi/Ffi.cs        # C ABI 导出
  build.sh
  THIRD-PARTY-LICENSES.md
  tests/                    # 分析器测试向量
```

> 语言已定：**C#（NativeAOT）**，与 `scanner` 同栈——直接复用中文处理生态与构建链。
> （曾评估"分析器放 Dart 后台 isolate"，因与扫描器分属两套中文处理、且大库构建更慢而**否决**。）

### 9.2 C ABI（结构化，遵循 scanner 的"无 JSON 传参 / 可 JSON 回参"风格）

```c
// 构建（增量 / 全量）
int  indexer_run(const char* db_path,      // library.db
                 const char* index_path,   // search.db
                 int full,                 // 1=重建，0=增量
                 const char* options_json, // 选项（如 {"index_lrc":false,"pinyin":true}）
                 void (*on_progress)(const char* json),
                 const char** out_result, int* out_len);
int  indexer_cancel(void);
void indexer_free(const char* ptr);
// 分析器共享（查询侧 Dart 调用，保证同构；含拼音 / 分层归一）
int  indexer_analyze(const char* text, int field,
                     const char** out_tokens, int* out_len);
void indexer_set_log_sink(void (*sink)(int, const char*, const char*), int min_level);
```

### 9.3 Dart 侧

- `lib/services/search/`：`search_index.dart`（打开 `search.db`、`MATCH`、`bm25`）、`search_bindings.dart`（FFI：run/cancel/analyze）、`search_models.dart`。
- 注册：`NativeModule.indexer`（`native_lib_paths.dart`）、`native_library_registry.dart`、`native_integrity.dart`；
  **仅在总开关开启时 `acquire`**（关闭不加载，§2.4）。
- **设置入口**：总开关 `启用本地曲库搜索索引`（默认关）+ 子项 `索引 .lrc 侧车歌词`（默认关，仅在总开关开启时可用）
  + 动作「重建索引 / 删除索引」。关闭时 Dart 侧不打开 `search.db`、不调 `indexer_*` FFI。
- UI：音乐库搜索框 / 全局搜索接入（排序替换现有 `LIKE`）；沿用 250ms 去抖；总开关关闭时保持现状 `LIKE`。
- **歌词命中行内片段**（`search_lyric_snippet.dart`）：结果因歌词命中（标题 / 歌手 / 专辑无字面高亮）
  时，行内显示命中歌词窗口（次要样式、单行省略，`SongRow.lyricSnippet`）。片段在**页加载异步路径**
  批量取歌词（`TracksDb.lyricsByIds`）算好缓存到 `LibraryState.lyricSnippets`，行渲染只同步查表；
  **拼音 / 首字母命中歌词无字面片段**（返回 null，不显示）。关闭态零成本。

### 9.4 构建与打包

- `app/core/build-linux.sh` / `build-macos.sh` / `build_windows.bat` 增加 `indexer` 步骤（镜像 scanner：`dotnet publish` + `libe_sqlite3`）。
- 打包清单（含 Nix / installers）同步。
- **许可证**：SQLite FTS5 = public domain（随 `libe_sqlite3`，已与 scanner 同版本同实例）；
  **拼音 / 繁简 / 全角**已采用 **`ToolGood.Words`**（Apache-2.0，版本固定 3.1.0.3），
  已按 [licensing.md](licensing.md) 核对许可证并登记
  `app/core/indexer/THIRD-PARTY-LICENSES.md`；NativeAOT 已验证可用
  （`<TrimmerRootAssembly Include="ToolGood.Words" />` 保根，`dotnet publish -p:PublishAot=true` 实跑通过）。
  GB18030 / GBK 解码改用 .NET 框架内置 `CodePagesEncodingProvider`（无额外依赖）。
  自带数据表（pinyin / simp_trad / gb18030 / en_blocklist）与英文阻断表已随之删除，
  仅保留 `data/nfkc.tsv`（ToolGood 不折叠 `ﬁ` / `①` 等兼容字）。

---

## 10. 里程碑

| 阶段 | 内容 | 产出 |
|---|---|---|
| **P0** | 评估 harness + 查询集 | analyzer 参数定案（§8） |
| **P1** | 分析器库（bigram / 拼音 / 繁简 / 分层）+ 测试向量 | `Analyzer.cs` / `Pinyin.cs` + 单测 |
| **P2** | indexer 组件 + `FtsStore` + 增量 + **总开关 + `.lrc` 子开关** + FFI | `indexer build` 可跑通，世代化产出 `search.db`；总开关默认关 |
| **P3** | Dart 查询（**拼音 / 译文 / 音译层**）+ UI 接入（**总开关默认关、按需加载**）+ 排序 | 开启后搜索可用、按相关度排序；关闭时回退 `LIKE` |
| **P4** | 增强：容错 / 短语 / 高亮 / 拼音模糊 | 质量打磨 |
| **P5** | **条件**：自研段引擎（§5.5） | 仅当 §7 测得 FTS5 不达标 |

---

## 11. 风险与开放问题

1. **译文 / 音译数据的可得性**：本地曲目的三层中，译文 / 音译**不一定存在**——内嵌标签通常只有原文，
   译文 / 音译可能在 `.lrc` 侧车中。管线模型已支持三层（`LyricMatchResult{content, translation, romaji}` /
   `LyricLine{translation, romaji}`），但**本地是否有译文**决定"翻译搜索"的实际覆盖率 → P0 评估时统计。
2. **拼音 / 繁简库**：许可证 + NativeAOT 兼容——已采用 ToolGood.Words（Apache-2.0，
   版本固定 3.1.0.3），NativeAOT 实测可用（见 §9.4）。
3. **多音字策略**：主读音 vs 多候选（膨胀）——由 §8 评估定。
4. **`.lrc` 约定**：同名匹配 / 大小写；编码按 BOM（UTF-8/UTF-16）→ 严格 UTF-8 试解码 →
   **GB18030**（.NET 框架内置 `CodePagesEncodingProvider`，覆盖 GBK 及 4 字节序列）解码，
   失败回退 UTF-8 替换。
5. **索引体积 / 构建耗时**：大库（含拼音 + 译文 + `.lrc`）退化验证。
6. **并发**：多 isolate / 多次打开的读写并发（WAL 只读多连接 OK；写独占）。
7. **模块常驻**：NativeAOT 无法安全卸载（scanner 已验证），indexer 同样常驻，内存需可控。
8. **与在线搜索 UI 的边界**：本地索引与既有在线 `search_page` 的整合与结果分区。
9. **跨语言检索**（如英文查询命中中文歌词）：**T0 + T1 已部分实现**——T0 多语言层入库
   （译文 / 音译作为独立列，§4.3）+ T1 Unihan 释义查询扩展（英文 ↔ 汉字候选第 4 分支，单向**词级**，
   依赖 Unihan `kDefinition` 的覆盖与精度）。**T2**（向量检索 / MT，句级 / 语义召回、双向高覆盖）
   **另立设计**；已知风险：`.lrc` 分层歧义、释义精度、同形噪声（候选与拼音 / 多义字同形）、
   短语级未覆盖。
10. **总开关默认关的语义**：关闭时 `search.db` 冻结（可保留），重新开启后须先按世代增量收敛，
    期间搜索可能短暂落后（派生数据，可接受）；首次开启的全量构建时间随库大小增长（§7.1），
    需在设置页给出进度与「可随时关闭 / 回退」的明确提示。

---

## 12. 一句话总结

> 让歌词"搜得到"，靠的是 **analyzer（CJK bigram + 拼音 + 繁简 + 译文/音译分层）+ 查询语义 + BM25**，
> 不是存储引擎。拼音 / 翻译是**索引期**成本，**不拖慢查询**。先做评估定分析器，再用
> **FTS5（世代化、可替换）** 落地；自研存储只在 §7 实测证明 locality / 磨损不达标时才值得，
> 且必须放在 `IndexStore` 接口之后。**整套能力默认关闭**（总开关 `启用本地曲库搜索索引`），
> 用户手动开启后才加载模块 / 建库；关闭即回退现状 `LIKE`（§2.4）。
