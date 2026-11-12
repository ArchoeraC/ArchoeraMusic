# 跨语言搜索增强灰度计划

> 策略：**先在本仓库（ArchoeraMusic 索引器）落地并验证这批纯规则跨语言技术，
> 验证通过后再移植到 NekoMusic（Java 后端）**——用我们自己的曲库与测试基建当灰度试验田。
> 搜索的硬性要求是「快」：所有方案都在现有「渐进兜底趟」架构内做加法，不加常驻查询成本。
> 本文档是计划，不含代码改动；每项实施前需按 §5 门槛评审。

## 1. 现状核实（v5 已覆盖的部分，勿重复建设）

查询侧已是**四趟渐进架构**（`app/core/indexer/SearchSession.cs`；Dart `search_index.dart`
只是薄 FFI 客户端，经 `indexer_query` 调用）：
主趟（精确表达式）→ 拼音宽松兜底（漏字/换位）→ **日文读音兜底**（拉丁词元 bigram
AND 到 `reading_meta_tok`）→ **跨语言兜底**（`love` → `"爱" OR "恋"`，Unihan 释义）。
另有受限替换容错（元音互替/邻键，变体预算 500）与 3 字符起前缀的门控。
**所以「拉丁搜日文歌」「英文搜中文歌」已部分可用；真正缺口如下。**

另两条「中文 → 日文歌」通路现状：
**拼音已通**（`Pinyin.FromCjkRun` 对任意 Han 段出拼音，「新宝島→xinbao dao」进 `pinyin_meta_tok`，
查询侧 `PinyinSegmenter` 切分后短语命中）；
**汉字异体未通**（简体查询 vs 日文新字体，见缺口 #8 / T1-7）；
**词义级不可行且列为非目标**（无翻译词典，只能靠歌词译文层 `lyrics_tr_tok` 兜底）。

## 2. 真实缺口（逐项核实过）

| # | 缺口 | 根因 |
|---|---|---|
| 1 | Kunrei/wapuro 罗马音输入落空：`situke` 搜不到「shitsuke」 | 索引侧读音列只产 Hepburn 主拼 bigram；读音兜底趟是 bigram **AND**，`si`/`tu` 不在索引里 → 整支落空。变体表有 Kunrei 数据但索引期 `primaryOnly: true`，查询侧窗口展开没覆盖到这层 |
| 2 | 助词 は/へ/を 失配：`kimi wa` 搜不到「君は」的读音 | `Japanese.cs` 无助词特判（grep 证实），词组内 は→ha；且 wa/ha 歧义无法靠机械替换消解（`watashi` 的 wa 不是助词） |
| 3 | 韩文拉丁查询不命中：`gangnam` 搜不到「강남」 | 谚文只按 substring script bigram 进词法层，无读音派生列 |
| 4 | 跨语言命中排序弱：兜底趟命中排在主趟命中之后（正确），但同为兜底趟内无精细档位，罗马音整词前缀命中与散 bigram 命中同档 | 兜底趟只做召回，无分层打分 |
| 5 | 拉丁 accent：`beyonce` 搜不到 `Beyoncé` | NFKC v3 兼容折叠不含去音符号折叠 |
| 6 | 拼音侧的音节级模糊（z/zh、an/ang、en/eng）未覆盖 | 现有容错是单字符替换+漏字/换位；`an→ang` 需插入音变，不在集合内 |
| 7 | 歌词罗马音生成 | 只索引已有 romaji，无离线生成（已作为可选增强实现，见 T2-9） |
| 8 | **简体查询搜不到日文新字体歌名**：搜「银河铁道」不命中「銀河鉄道の夜」 | 归一化链是 ToolGood `ToSimplifiedChinese`（简繁词典）；日文新字体（絵/円/変/広/鉄）不在简繁映射内时两侧原样保留——索引里的新字体与用户输入的简体字永不互相同一。拼音路径不受影响（`Pinyin.FromCjkRun` 对任意 Han 段出拼音，「新宝島→xinbao dao」已通）；词义级（「天空之城」→「君をのせて」）无翻译词典不可行，由歌词译文层（`lyrics_tr_tok`）兜底，列为非目标 |

## 3. 技术项清单

### T1 第一批（按优先级排序，每项独立可验证）

| 项 | 内容 | 验证方法 | 移植到 NekoMusic 的对应物 |
|---|---|---|---|
| T1-1 罗马音规范形 | ✅ **已实施（2026-11-11）**：`RomajiCanonical.Apply` 在读音列索引期与拉丁查询侧**双端归一**（sh→s、ch→t、ts→t、fu→hu、j→z、长音折叠 ou/oo→o、促音折叠、`ん`+元音→`nn+元音`；查询侧对 `n`+元音额外给放宽变体 OR）。**AnalyzerVersion 6→7** 触发全量重建 | vectors：`しつけ` 读音含 `si/it/tu/uk/ke`、`がっこう` 无 `kk`、`きんえん` 含 `nn`；查询表达式 `shitsuke`≡`situke`；端到端 `shitsuke`/`situke` 同时命中 | Java `RomajiCanonicalizer`，NekoMusic `JapaneseRomanizer` 的 Kuromoji 读音接在同一 canonical 之后 |
| T1-2 助词双写 | ✅ **已实施（2026-11-11）**：`data/kana_romaji.tsv` 给 `は` 增加 `wa`、`へ` 增加 `e`（`を` 原有 `o/wo`），索引期同假名段内双写；同时**修复局部窗口变体从未生效**的缺陷（旧实现把罗马字拼回假名串，非假名被跳过），窗口改为按假名单元直接转写并去重。**AnalyzerVersion 7→8** | vectors：`きみは` 读音含 `ha`/`wa`、`へ` 含 `e`、`を` 含 `wo`/`o`；端到端 `kimi wa`/`kimi ha` 均命中「きみは」 | NekoMusic 索引期同规则双写（成本可忽略） |
| T1-3 韩文罗马字 | ✅ **已实施（2026-11-11）**：新增 `Korean.cs`（`Initials` 19 / `Vowels` 21 / `Finals` 28 三表 + 兼容区 Jamo U+3131..U+3163），按 `AC00 + L*21*28 + V*28 + T` 分解初/中/终声 → 国语院 RR 逐字转写；`Japanese.ReadingBigrams` 的读音列 gate 与分支扩到谚文段，结果写入 `reading_meta_tok` 同路大 bigram。**只做字面转写**，连音/鼻化/腭化留后置迭代。**AnalyzerVersion 8→9** 触发全量重建 | vectors：`사랑해 → saranghae`、`한국 → hanguk`、读音 bigram 非空；端到端 `sarang` / `saranghae` 均命中「사랑해」 | NekoMusic 新 util，复用 `title_reading`/`artist_reading` 列 |
| T1-4 跨语言命中分层 | ✅ **已实施（2026-11-11）**：读音兜底趟新增 `ReadingRanker` 后置分档——`search_docs` v6 增 `reading_tok`（读音 bigram 原文副本，单曲数十字节；contentless FTS 回读不到 token 文本），命中候选回读后按「**整词前缀 3 > 整词包含 2 > 其它 0**」重排，档内仍按 bm25。cross-lingual 趟沿用 bm25 列权重（title 4.0 > artist 3.0 > … > lyrics 1.5），已天然实现「元数据命中 > 歌词命中」分层。**Schema 5→6** 触发重建（AnalyzerVersion 不变）。计划中的「散 bigram 高/低覆盖」两档实际不可达：读音表达式要求**全部**查询 bigram **连续**出现，散命中不会进入该趟，故按可达档位落地（详见 `ReadingRanker` 注释） | vectors：前缀 / 包含 / 不连续三档；端到端 `shitsuke` 中「しつけ」(前缀) 排在「きみのしつけ」(包含) 之前；分档只在读音趟对 ≤ limit 候选做一次 `IN` 查询 + 字符串比较，无额外 FTS 扫描 | NekoMusic `MusicSearchRanker` 按同一档位表实现（其候选在内存中，可直接取文本） |
| T1-5 accent folding | ✅ **已实施（2026-11-11）**：新增 `data/accent_fold.tsv`（488 条，NFD 派生的「预组合拉丁字母 → ASCII 基字母」表），在 `Analyzer.Normalize` 的 NFKC 之后应用，并丢弃组合音标码点（é 与 e+U+0301 同形）；索引 / 查询共用同一函数。表由 **纯 .NET** 生成器 `tools/gen_tables` 产出（无需 Python / ICU 运行时）。**AnalyzerVersion 9→10**；ł/ø/đ 等无规范分解字母保持原样（已知限制） | vectors：`Beyoncé → beyonce`、`e+U+0301 → beyonce`、`Señor über ā → senor uber a`、`Łódź → łodz` | 并入 NekoMusic `TextNormalizer`（同一 TSV 可直接复用） |
| T1-6 拼音音节级模糊 | ✅ **已实施（2026-11-11）**：`SearchQuery.CompilePinyinLoose` 对每个**有效拼音音节**（`PinyinSegmenter.IsSyllable` 门控，英文词不扩展）按声母 `zh/z、ch/c、sh/s、n/l、f/h`、韵母 `ang/an、eng/en、ing/in` **双向**展开（原形 + 声母 + 韵母 + 组合，每音节 ≤4），同音节 `OR`、音节间 `AND`；只存在于兜底趟，主路径零成本、**不递增 AnalyzerVersion** | vectors：`周伦` → `(zhou OR zou) AND (lun* OR nun*)`、`zongguo` → `(zong OR zhong) ∧ guo`、`shanghai` 4 变体封顶、`hello world` 不套用 n/l·f/h；端到端 `zoulun` 仅走拼音兜底命中「周杰伦」 | NekoMusic `PinyinUtil.searchVariants` 同规则 + `MusicSearchRanker` 降档 |
| T1-7 日文新字体归一 | ✅ **已实施（2026-11-11）**：实测确认 ToolGood 繁简词库**不覆盖**日文新字体（`鉄/絵/円/広/変/楽/駅` 原样保留，而其旧字体 `鐵/繪/圓/廣/變/樂/驛` 能正常转简）。新增 `data/variant_fold.tsv`（3170 条）：从 Unihan `kSimplifiedVariant` 取繁→简，日文新字体经 `kJapaneseOldVariant` 串联旧字体再取简体（`鉄→鐵→铁`），并**只保留 ToolGood 未覆盖的字符**，不覆盖既有中文繁简规则；在 `Analyzer.Normalize` 中于 ToolGood 之前应用，索引 / 查询双端同表。表由 `tools/gen_tables` 从 `reference/unihan/Unihan.zip` 生成。**AnalyzerVersion 10→11** | vectors：`鉄道→铁道`、`絵→绘`、`広島→广岛`、`楽園→乐园`、`銀河鉄道 ≡ 银河铁道` 词元；端到端搜「银河铁道」主趟命中「銀河鉄道の夜」且不触发兜底 | NekoMusic `TextNormalizer` 管线同表复用（该侧 ChineseConverter 同样只有简繁词典） |
| T1-8 模糊层词典化 | ✅ **已实施（2026-11-11）**：不做 SymSpell 删除词典落盘，直接以**索引真实词表**做变体过滤——`FtsStore.LoadFuzzyVocabulary()` 从 `fts5vocab(main, search_fts, 'col')` 懒加载 `DISTINCT term`（只留 ASCII 词，按写入纪元 `_writeEpoch` 缓存失效），`FuzzyVocabulary.PrefixRange` 二分取前缀区间，`MyersWithinOne`（位并行 Levenshtein ≤1，>64 字符退回有界 DP）叠加相邻换位做精筛；`VocabularyExpressions` 对区间 ≤32 的词条逐个精确复核后入表达式，区间过大退回前缀匹配，某可扩展词元无候选则整支返回 `null`（不再枚举不存在变体）。词表**不落盘、不改 schema、不递增 AnalyzerVersion**；加载失败自动退回旧「500 变体枚举」行为 | 黄金向量：`hlelo` 命中词表 `hello` 且不产出 `ehllo`；端到端 `hlelo` 仅由模糊趟召回（`Fuzzy==1`）；3000 曲确定性语料 qbench（limit=10000）`latin_typo` 5.31→5.05ms、`latin_swap` 5.26→5.08ms；limit=50 时 `latin_typo` 4.26→4.09ms、`latin_swap` 5.26→4.16ms（词表仅 3755 条，收益约 3–5%） | NekoMusic 查询侧同构（其变体展开更朴素，收益更大） |

**范围外（本期明确不做，避免评审遗漏追问）**：西里尔/希腊/阿拉伯/天城文等其它文字的
拉丁转写不在本期范围——机制上与 T1-3 同型（Unicode 数据派生映射表），表可后加，
但各语言转写标准的正确性验证成本高，等真实曲库需求出现再立项。

### T2 第二批（依赖 T1 结论或需先权衡）

| 项 | 内容 | 说明 |
|---|---|---|
| T2-7 助词容错矩阵 | T1-2 上线后用真实查询日志确认双写是否足够 | 决定移植侧是否同规则 |
| T2-8 Unihan 释义扩展调优 | ✅ **已实施（2026-11-11）**：实测固化参数——① 单英文词候选上限沿用生成表侧 `EN2HANZI_MAX = 8`；② 查询侧总预算 `Analyzer.CrossLingualBudget = 32` 实测**单词查询永不触及**（42 条代表查询候选数 min 0 / med 8 / max 9），3 词典型查询仍在预算内，仅 ≥4 个英文词的长查询才截断，故保留 32 作多词安全阀；③ 修掉 `kDefinition` 解析噪音——旧正则 `[a-z][a-z'-]+` 会把 `13th lunar mansion` 切成 `th`，实测 `th` 作为候选覆盖 10.7% 文档（322/3000）且无释义信息；改为词首不得紧跟字母/数字后重生成 `def_en2hanzi.tsv` / `def_hanzi2en.tsv`（48 个汉字受影响，去掉 `th/nd/rd/st/jyu/saan` 碎片）。两张表仅查询侧使用，**不递增 AnalyzerVersion**、无需重建索引 | 测量方法：一次性探针编译生产 `Analyzer` / `SearchQuery` / `FtsStore` 源码，对 3000 曲确定性语料统计候选 df 与「预算 → 延迟 / 命中」曲线。结果：B=8 与 B=32 延迟无差异（拉丁词 ≤ 0.1ms，成本由主导候选决定）；42 条查询中 20 条出现 1–4 个 df≥50% 的高频候选（合并覆盖 96–100%），另 20 条覆盖为 0——前者来自合成语料的小词表，属上界而非预算问题。修复后 `心` / `星` 候选由 10 降至 9，`th` 的 322 次命中归零 |
| T2-9 歌词罗马音生成 | ✅ **已实施（2026-11-11，可选增强 / 默认关）**：原先「本期不做」的体积与质量顾虑，改由**用户显式开关**消化——`IndexerOptions.RomajiLyrics`（FFI `romaji_lyrics`、CLI `--romaji-lyrics`、设置「生成歌词罗马音索引」，默认 false）开启后，对**无 LRC 音译层**且含假名的歌词，复用已有分析结果 `lyrics.Readings`（`Japanese.ReadingBigrams` 的字母 bigram）填入 `lyrics_rom_tok`；有用户音译时**不覆盖**。查询侧 `SearchQuery.ReadingColumns` 扩为 `reading_meta_tok lyrics_rom_tok`，读音趟（相邻 bigram 短语）因此可命中生成列，LRC 音译的整词内容不会被 bigram 短语误命中。`StoreMeta.RomajiLyrics` + meta 键 `romaji_lyrics` 记录开关，切换即触发全量重建；schema 仍为 v7（只增 meta 键）。默认关闭时体积 / 读音质量与既有行为完全一致，开启后索引约 2×（真实 165 首 2.42MB→4.53MB） | 端到端：开关关时生成列为空；开启后 `空は青い` 的 `そら` 可由 `sora` 读音趟命中、`tK` 的用户音译整词仍在；开关切换 `result.Full==true`。NekoMusic 若有 Kuromoji 可换更高质量读音，机制同构 |

## 4. 查询速度优化（「快」是硬要求）

现有架构已经便宜：兜底趟只在主趟命中不足时才付钱、前缀 ≥3 字符门控、变体预算 500、
列过滤收窄。在此之上按性价比排序：

1. ✅ **曲库语言画像（收益最大，2026-11-11 已实施）**：`search_meta` 记
   `has_japanese` / `has_korean` / `has_han` / `has_latin` 四位（**schema v7**），
   构建收尾时从**索引内容列**（标题 / 歌手 / 专辑 / 文件名 / 歌词 / 译文 / 音译）的字符脚本统计得出，
   不含由它们派生的拼音 / 首字母 / 读音列（否则纯中文库会因拼音被误判为「含拉丁」）。
   增量构建承接旧画像做 OR（删掉最后一首日文歌后位可能仍为 true，只意味着不裁剪，结果正确）。
   查询侧：无日 / 韩内容时**永久跳过读音兜底趟**；跨语言趟按候选脚本**定向裁剪**——
   `has_han=false` 时丢掉汉字候选（不可能命中），`has_latin=false` 时丢掉英文释义候选；
   因此纯英文库仍保留「爱 → love」方向，不是把整趟砍掉（比原计划更保守，避免误伤召回）。
   绝大多数纯英文曲库从四趟降到两趟，主路径零改动。
   实现在 [IndexerEngine.cs](file:///home/betastudio2/文档/ArchoeraMusic/app/core/indexer/IndexerEngine.cs) 的
   `ScriptProfile` 与 [SearchSession.cs](file:///home/betastudio2/文档/ArchoeraMusic/app/core/indexer/SearchSession.cs) 的
   `FilterCrossLingual`；测试见 `SearchLayerTests.LanguageProfile`。
2. ✅ **查询结果 LRU 缓存（2026-11-12 已实施）**：`SearchSession` 实例内按
   「查询串（trim + 小写）+ scope + limit / offset / fuzzy / minExact / candidateCap
   + AnalyzerVersion」做 **128 条 LRU**（字典 + 双向链表），命中直接返回上次的
   top-k 与 `passes`，不再走 FTS。单条结果 **> 500 条不入缓存**，防止大 `limit`
   的宽命中把 128 条放大到百 MB 级。输入去抖 250ms + 退格重放是高频重复查询，
   收益集中在「退格回到已搜过的前缀」。缓存随会话一起丢弃——重建 / 删除索引 /
   关闭总开关本就调用 `indexer_query_close`（`SearchSession.CloseCached`），
   无需额外失效逻辑；返回结果按只读共享（高亮缓存 `_cache` 同模式先例）。
   测试见 `SearchLayerTests.QueryResultCache`（重复命中 / 参数不串键 / 容量淘汰 /
   CloseCached 失效）。
3. **兜底趟合并决策**：画像显示日文占比高的曲库，读音兜底支可并入主趟 OR
   （列过滤后该支本来就便宜），省一次往返；占比低的维持独立趟。以 qbench 数据定阈值。
4. **大命中集早停**：主趟命中数超过阈值（如 500）即视为「命中充足」，跳过全部兜底趟——
   大命中集本身说明查询词识别力强，兜底只会加噪声。现有「命中过窄才兜底」的粗判据换成
   显式阈值。
5. **变体预算复核**：500 的上限对长查询仍可能造出巨型 MATCH；按词元数动态收紧
   （如每词元 ≤8 变体 × 词元数上限）。
6. 每项优化前后用 qbench 记录 P50/P95 与命中数，防「提速丢召回」。

### 4.1 经典算法方案评估（非神经网络向量）

**神经网络 embedding 向量检索不采用**：违反纯规则红线；对短查询歌名搜索没有
精度优势（需要模型推理与 ANN 索引两条额外成本）；本方案的跨语言问题本质是
**确定性映射**（拼音/罗马音/新字体），查表即可解，不需要语义空间。

以下经典算法有真实提速空间，按适用侧列出（均为确定性、离线可构建）：

| 算法 | 作用点 | 收益 | 适用侧 |
|---|---|---|---|
| **SymSpell**（预生成删除变体词典） | 模糊层重构：把「查询侧枚举替换/漏字变体（上限 500）」换成词典 O(1) 查找 | 模糊趟变体爆炸归零；编辑距离 ≤2 的容错比当前受限替换更宽却更快 | 本仓库查询侧、NekoMusic 查询侧 |
| **Myers 位并行编辑距离**（bit-vector DP） | 兜底趟候选的**后置精筛**：粗筛结果再按编辑距离 ≤1/2 复核，替代大 MATCH 表达式 | 单候选 O(m⌈m/w⌉)，替代指数级变体展开 | 两侧通用 |
| **Roaring Bitmap 倒排** | NekoMusic 自研 2-gram 歌词索引的 `Map<String, Set<Integer>>` postings → 位图 AND/OR | 万级候选集合交并从哈希集遍历变为字长位运算，内存同步下降 | NekoMusic（本仓库走 FTS5，无需自建） |
| **64-bit gram sketch 预过滤**（SimHash/MinHash 思想，纯哈希无模型） | NekoMusic 歌词索引给每首歌存 64 位 n-gram 指纹；查询先按 popcount 重叠粗排，>阈值才进全文打分 | 20k 候选扫描砍到数百，配合 `MAX_CANDIDATE_SCAN` 上限 | NekoMusic 歌词侧；本仓库歌词若未来脱离 FTS5 同样适用 |
| **WAND / MaxScore top-k**（按 gram IDF 上界剪枝） | NekoMusic 内存打分器：预计算 gram 上界分，累加不足当前 top-k 门槛即跳过该候选 | 避免给全部候选打满分；FTS5 无法用（黑盒），仅自研打分侧 | NekoMusic；本仓库仅 FTS5 外的后置排序 |
| **Aho-Corasick 自动机** | 查询 gram 在候选文本的连续命中检测（现有「顺序扫描」的加速） | 多模式单遍 O(n+m)，连续性 bonus 的开销从 O(候选×gram) 降为线性 | NekoMusic 歌词打分；本仓库 T1-4 分层如做后置验证可复用 |

**取舍结论**：
- 本仓库主路径是 FTS5 黑盒，位图/WAND 类优化**用不上也不必用**；值得做的是
  **模糊层词典化**与 Myers 后置精筛（T1-8 已实施）。
- **落地形态与最初设想不同**：本仓库不单独构建 / 落盘 SymSpell 删除词典——索引的
  `fts5vocab` 本身就是真实词表，直接懒加载后按「变体前缀区间 + Myers ≤1 / 相邻换位
  精筛」收敛，少一份需要随曲库增量维护的派生数据（删除词典的失效与重建是额外复杂度）。
  这也意味着模糊音对不需要「注入 SymSpell 替换规则」：它们已在 T1-6 的拼音兜底趟里。
- NekoMusic 侧是自研内存索引，Roaring Bitmap + gram sketch + WAND 三件套
  是其 2-gram 歌词索引在万级曲库下保住「快」的关键，移植时整体带走；
  若其查询侧也有真实词表可枚举，T1-8 的「词表过滤」形态可直接复用，无需另建删除词典。
- 所有算法只动**查询路径的候选收敛与打分**，不触碰索引生成规则本身；
  引入前一律过 §5 门槛（qbench P50/P95 + 命中数对比）。

### 4.2 词典路线的体积与精度预算（免词典的可行边界）

先说调研结论：**免词典的跨语言语义检索不存在**（现有方案如 Symphonym 音素嵌入、
decipherment 转写学习全部依赖神经网络或音素词典，arXiv 2601.06932 / NAACL 2009 Ravi）。
但这不是损失——搜索需要的不是「词义」，而是**确定性的音译映射**，它可以完全做到
KB~MB 级，与 GB 词库无关：

| 数据 | 体量 | 性质 | 备注 |
|---|---|---|---|
| 假名→罗马字表 | ~2 KB | 纯映射，无词典 | 已有（kana_romaji.tsv） |
| 谚文 jamo/RR 表 | ~4 KB | Unicode 公式 + 映射，无词典 | T1-3 |
| accent / 全角折叠表 | ~10 KB | 纯映射 | T1-5 |
| 新字体→简体表 | ~50 KB | Unihan kSimplifiedVariant 派生 | T1-7 |
| **音节级语音桥** | ~30 KB | 拼音 ~410 音节 / 罗马字 ~100 音节 → 粗粒度音类（如 前后鼻音、平翘舌、sh/si 类）→ 等价类查表 | **无任何词数据**，给跨系统模糊（`xindong`≈`shindou`）兜底 |
| 汉字逐字读音表（kMandarin/kJapanese/kKorean 全集） | 1–2 MB | **逐字**，无分词无词库 | Unihan 派生；多音字全变体枚举 |

关键认知：**搜索不需要消歧**。词级词典（ToolGood 词库、Kuromoji IPADIC）的价值是
生成「正确」读音；而检索是召回导向——多音字全枚举进索引，精度损失由排序兜底。
因此：

1. **本仓库现状已达标**：ToolGood 词库是 NuGet 依赖不占包体，派生表合计 < 3 MB。
2. **NekoMusic 移植侧的体积机会**：元数据读音生成可不带 Kuromoji（IPADIC 约 15 MB），
   直接用逐字读音表（1–2 MB）+ 全变体枚举；Kuromoji 只保留给**歌词正文**罗马音回填
   （散文分词质量有价值）。若接受精度损失，歌词侧也可用 marisa-trie 的 **Java 移植**
   压缩高频词表（< 1 MB）替代——marisa-trie 原生是 C++，本仓库侧禁用（§4.3），
   此处仅指 NekoMusic（JVM 已在依赖内）。
3. **精度注意点**（对应「词典查找准确性」）：逐字表的多音字误报（如「长」→chang/zhang
   全进索引）靠三层收敛——FTS 短语相邻性（已在 pinyin 分支生效）、兜底趟降档（T1-4）、
   黄金向量实测精度。词典**不决定召回正确性**，只影响噪音率，可量化、可调。
4. **词典查找优化**：查询速度上 `Dictionary<int,…>` 已是 O(1)，**FST/DAWG 的收益只在包体
   压缩**（参考 Lucene 术语表 FST 共享前缀后缀、DAWG 实测 125k 词 → 800 KB），
   不是查询加速手段。因此按体积分档：
   - 表合计 ≤3 MB → 维持 TSV `EmbeddedResource` + `Lazy<Dictionary>`（现状，零新依赖、
     NativeAOT 安全）；
   - 包体成为问题时 → **纯 C# 实现的 DAWG/FST**（不引入 marisa-trie 等 C++ 库，
     否则会破坏「一套 .NET 工具链」的构建约束），用 `gen_tables`（见 §4.3）编译。
5. **激进结论**：**「小词典 + 表映射」路线可以把跨语言数据总量压在 ~3 MB 以内**，
   不需要也做不到真正的免词典语义检索；逐字读音表在检索场景下「词典不精确」的代价
   可控，值得作为 NekoMusic 移植的默认方案而非备选。

### 4.3 零大运行时约束（硬性）

**现状澄清**：运行时**不依赖 Python**。索引器是 .NET 10 NativeAOT 的
`indexer-ffi.so`，数据表以 `EmbeddedResource` 编入程序集，拼音/繁简由
ToolGood.Words（NuGet，静态编入）提供，SQLite 由 `libe_sqlite3` 随包分发；
Python 只出现在 [build.sh](../../app/core/indexer/build.sh) 的「表缺失时生成」分支，
而 `data/*.tsv` 已入库，正常构建根本不触发。`bench/*.py` 属开发期工具，不入产物。

但这条约束对新增方案是**硬性门禁**：

1. **禁止新增运行时依赖**：不得引入 Python/Rust/C++ 运行时、不得调用外部进程、
   不得在运行时读外部词典文件（一律 `EmbeddedResource` + NativeAOT 安全代码）。
2. **构建期工具链收敛到 .NET 一套**：新增表（T1-7 新字体映射、音节级语音桥、
   逐字读音表、Kunrei 变体表）**不得再扩展 `gen_hanzi_data.py`**。迁移方案：
   把 `tools/gen_hanzi_data.py` 改写为 **C# 控制台工具 `tools/gen_tables`**
   （同一 .NET SDK，无第二套工具链），能力对照：

   | 现有 Python 能力 | .NET 等价实现 |
   |---|---|
   | `unicodedata.normalize('NFKC', ch)` 逐码点遍历 | `Rune` 遍历 + `string.Normalize(NormalizationForm.FormKC)` |
   | Unihan.zip 文本解析（kMandarin/kJapanese/kDefinition/kSimplifiedVariant） | `System.IO.Compression` + `Encoding.UTF8` 逐行解析（纯文本格式） |
   | 码点十六进制读写 | `Rune.Value` / `Rune.ToString` |
   | 表输出 TSV | `File.WriteAllText`（确定性、可重跑、带生成头注释） |

   中文分词/多音字消歧用现有 ToolGood.Words（已在依赖内），不引入新库。
3. **CI 与本地构建只允许 .NET SDK**：表生成作为 `dotnet run --project tools/gen_tables`
   由 `build.sh` 调用，`python3` 从构建依赖中删除，`build.sh` 的 python3 分支一并移除。
4. **迁移期兼容**：`gen_tables` 首版必须**逐字节复现**现有 5 张表（golden 校验：
   重新生成后与仓库内 TSV 做 checksum 比对），确认无差异后才删 Python 脚本——
   表内容一变就会误触发全量重建，这一步不可省。
5. **NekoMusic 移植侧不适用此约束**（Java 服务端自有 JVM），但其产物（映射表）
   必须是语言中立的数据文件，便于两侧共用同一份 golden checksum。

## 5. 灰度门槛（每项从 T1 进入移植清单的条件）

1. 黄金向量全绿（新增样例先行入表，规则改动先改向量再改实现）；
2. qbench P95 不高于基线 +10%，索引体积增幅记录在案；
3. 标注查询集召回@k / MRR 有可量化提升（沿用 local-search-index-plan.md §2.3 方法）；
4. `AnalyzerVersion` 递增次数攒批合并，避免用户侧反复全量重建。

## 6. 移植映射表（灰度完成后执行，见 NekoMusic 仓库《跨语言搜索与歌词索引增强方案.md》）

| 本仓库组件 | NekoMusic 对应物 |
|---|---|
| `Analyzer` + `TextNormalizer`（NFKC/繁简/accent） | Java `TextNormalizer`（同一管线 + 版本锚） |
| `kana_romaji.tsv` + `RomajiCanonicalizer` | `JapaneseRomanizer` 变体表重构 + canonical util |
| `ja_readings.tsv`（Unihan kJapanese） | Kuromoji reading=`*` 的第二级兜底 |
| T1-6 模糊音规则与预算 | `PinyinUtil.searchVariants` + `MusicSearchRanker` 档位 |
| T1-3 jamo/RR 实现 | Java 同公式 util → `title_reading`/`artist_reading` |
| T1-4 兜底趟分档 | `MusicSearchRanker` 档位表（该侧无多趟架构，直接按档打分） |
| T1-7 新字体→简体表 | `ChineseConverter` 输出后追加同表归一（`TextNormalizer` 管线内） |
| T1-8 + §4.1 算法 | SymSpell 删除变体词典、Roaring Bitmap、gram sketch、WAND 三件套整体移植 |
| 四趟渐进 + 语言画像 + LRU 思路 | LIKE 候选筛选下的「ASCII 词条才挂读音/拼音分支」已是同思想；缓存照搬 |

## 7. 红线

- 全程纯规则：查表、Unicode 公式、字符串改写；不引入任何 AI/统计模型推理。
- 不动手：本文档评审通过前不改 `Analyzer`、`Japanese.cs`、`SearchQuery.cs` 等任何实现。
- 改动 `AnalyzerVersion` 语义的项必须递增版本并说明（变更即触发全量重建）。
- 任何新增查询成本必须走「兜底趟/画像门控」路径，不得进入主趟常驻开销。
