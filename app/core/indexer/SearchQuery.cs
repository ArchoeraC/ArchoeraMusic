// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

using System.Text;
using Archoera.Text;

namespace Archoera.Indexer;

/// <summary>
/// FTS5 <c>MATCH</c> 表达式编译（**纯函数，无 IO，可单测**）。
///
/// 与旧 Dart 实现（<c>search_query.dart</c> / <c>search_cjk_fuzzy.dart</c>）逐字符等价：
/// 查询编译是搜索召回的核心规则，放在索引器内可让 Dart 只做 UI 调度与模型映射。
///
/// 语义：
/// <list type="bullet">
///   <item><b>词法支</b>：连续多个 CJK / 假名 / 谚文 bigram 合并为引号短语，其余逐个
///         <c>AND</c>；末词元为拉丁 / 数字且 ≥3 字符时加前缀 <c>*</c>。</item>
///   <item><b>拼音支</b>：单音节 ≥3 字符前缀；≥2 音节为相邻短语（位置无关的宽松形态与
///         模糊音扩展只在兜底趟 <see cref="CompilePinyinLoose"/> 中使用）。</item>
///   <item><b>首字母支</b>：列过滤到首字母列，末段 ≥2 字符前缀。</item>
///   <item><b>读音支</b>：拉丁 / 数字词元的字母 bigram 短语 <c>AND</c> 到读音列。</item>
///   <item><b>跨语言支</b>：候选逐个加引号后以 <c>OR</c> 组合（候选之间 OR）。</item>
///   <item><b>模糊支</b>：拉丁 / 数字词元展开编辑距离 ≤1 变体 OR 组，其余与主趟一致。</item>
/// </list>
/// 安全：所有词元都经 <see cref="Quote"/> 转义（内部 <c>"</c> 翻倍），杜绝 FTS5 语法错误与注入。
/// </summary>
internal static class SearchQuery
{
    /// <summary>元数据列过滤用的 FTS5 列集合（<c>scope=metadata</c>；不含歌词 / 译文 / 音译段）。</summary>
    public const string MetadataColumns =
        "title_tok artist_tok album_tok filename_tok pinyin_meta_tok initials_meta_tok reading_meta_tok";

    /// <summary>
    /// **可见文本列**：用户在界面上实际能看到的元数据（歌名 / 歌手 / 专辑），
    /// 外加文件名。<b>不含</b>拼音 / 首字母 / 读音这些**派生转写列**。
    ///
    /// 用于单字查询的列门控（<see cref="RequireMetadataForSingleChar"/>）：
    /// 一个汉字只在「歌名 / 歌手 / 专辑」里出现才构成检索意图，出现在**派生转写列**
    /// 里毫无意义（那里存的是拉丁转写，汉字查询在其中恒为 0 命中）。
    ///
    /// 拉丁单字则相反——<c>a</c> 在 <c>pinyin_meta_tok</c> 命中 2,109 首、
    /// <c>initials_meta_tok</c> 1,465 首，而标题只有 618 首；真实库实测
    /// 限定可见文本后 <c>a</c> 2,473→1,205、<c>e</c> 1,702→319。
    /// </summary>
    public const string VisibleTextColumns = "title_tok artist_tok album_tok filename_tok";

    /// <summary>索引里存放拼音的列集合。</summary>
    public const string PinyinColumns = "pinyin_meta_tok pinyin_lyrics_tok";

    /// <summary>索引里存放首字母的列集合。</summary>
    public const string InitialsColumns = "initials_meta_tok initials_lyrics_tok";

    /// <summary>
    /// 索引里存放读音的列集合：元数据读音（始终产出）+ 音译歌词列（LRC 音译整词，
    /// 或开启 T2-9「歌词罗马音生成」后的歌词读音 bigram）。
    ///
    /// 读音趟匹配的是**相邻 bigram 短语**，整词内容不会被 bigram 短语误命中；
    /// 反之用户键入整词时仍可命中整词。
    /// </summary>
    public const string ReadingColumns = "reading_meta_tok lyrics_rom_tok";

    /// <summary>单次模糊编译的变体总数默认上限（防止长串 / 多词元生成巨型 MATCH）。</summary>
    public const int DefaultMaxFuzzyVariants = 500;

    /// <summary>单次中文容错的变体总数默认上限。</summary>
    public const int DefaultMaxCjkVariants = 200;

    /// <summary>CJK 子序列长度硬上限：超长（粘贴整段文本）放弃容错，避免 O(L²) 膨胀。</summary>
    public const int MaxCjkQueryLength = 64;

    /// <summary>拼音 / 拉丁词元加前缀 <c>*</c> 的最小长度。</summary>
    public const int MinPrefixTokenLength = 3;

    /// <summary>首字母串加前缀 <c>*</c> 的最小长度。</summary>
    public const int MinInitialsPrefixLength = 2;

    /// <summary>
    /// 首字母支的**整体最小长度**：低于该长度的首字母串**不生成首字母支**。
    ///
    /// 单个汉字的首字母是**单个字母**（<c>恨 → h</c>、<c>爱 → a</c>、<c>痛 → t</c>），
    /// 而单字母 token 在真实曲库里密集存在（歌词整行「啊 / 哦 / 嗯」、文件名 <c>t164</c>、
    /// 单字标题 <c>A</c> / <c>I</c>）。旧实现在末词元 &lt;2 字符时**不加前缀**、按精确 term
    /// 匹配，于是任意单字查询都能把整库捞进来（合成库实测 400/400），这是「库内无匹配
    /// 仍返回大量无关结果」的最直接成因。
    ///
    /// 门控取 2：<c>qt</c>（晴天）/ <c>wan</c>（我爱你）这类真实的双字母以上首字母检索
    /// 完全不受影响；只有退化到单字母时才放弃该支（词法 / 拼音支仍在）。
    ///
    /// 参考：Navidrome <c>ftsQueryDegraded</c>（有效 token 全 ≤2 字符即判「查询退化」）、
    /// Typesense <c>min_len_1typo=4</c>、Bleve <c>FuzzyQuery.prefix_length</c>。
    /// 详见 <c>docs/local-search-recall-precision-audit.md</c> §2.2 / §6.2。
    /// </summary>
    public const int MinInitialsBranchLength = 2;

    /// <summary>
    /// 跨语言释义支的**最小 CJK 字数**：单字查询不生成跨语言候选。
    ///
    /// Unihan 释义对单字极度发散（<c>痛 → ache / bitter / pain / sad / sorry</c>、
    /// <c>好 → excellent / fine / good / well</c>），而这些英文词在曲库里普遍存在，
    /// 单字查询因此会被放大到近乎整库。≥2 字（<c>月亮</c>、<c>银河</c>）的释义显著更聚焦，
    /// 保留原有召回。拉丁词 → 汉字方向不受此限（<c>love → 爱</c> 仍可用）。
    ///
    /// 详见 <c>docs/local-search-recall-precision-audit.md</c> §2.4 / §6.2。
    /// </summary>
    public const int MinCrossLingualCjkLength = 2;

    /// <summary>
    /// CJK 容错（删除 / 换位）的**最小字数**：低于该字数不生成变体。
    ///
    /// 两字查询删掉一个字后必然退化成**单字**（<c>爱情 → 爱 / 情</c>），而单字查询本身
    /// 已是宽覆盖（见 <see cref="MinInitialsBranchLength"/>），等于把两字查询放大成两次
    /// 单字查询（合成库实测「想你」返回 130 条）。三字以上删一字仍保留区分度
    /// （<c>我的爱 → 我的 / 的爱</c>），维持原行为。
    ///
    /// 详见 <c>docs/local-search-recall-precision-audit.md</c> §2.5 / §6.2。
    /// </summary>
    public const int MinCjkFuzzyLength = 3;

    /// <summary>
    /// 拉丁模糊趟的**最小词长**：短于此长度不做编辑距离扩展。
    ///
    /// 2 字符词（<c>ai</c> / <c>go</c> / <c>ye</c>）的 ≤1 变体几乎覆盖全部高频二元组，
    /// 放宽收益远低于噪声成本，故一律不扩展。取 **3**：
    /// <list type="bullet">
    ///   <item>Elasticsearch <c>Fuzziness.AUTO</c> 正是「&lt;3 字符 → 0 个编辑」；</item>
    ///   <item>Typesense <c>min_len_1typo=4</c> 更保守，但那会连带砍掉 3 字符词的拼音召回
    ///         （回归用例 <c>FuzzyVocabularyRecall</c>：<c>woo</c> 的删除变体 <c>wo</c>
    ///         只存在于拼音列，是 T1-8 词表回退路径的唯一覆盖）；</item>
    ///   <item>本项目的模糊趟本来就只在主趟 0 命中后才执行，噪声面已受短路约束。</item>
    /// </list>
    /// 详见 <c>docs/local-search-recall-precision-audit.md</c> §6.2。
    /// </summary>
    public const int MinFuzzyWordLength = 3;

    /// <summary>
    /// **读音支的脚本门控**：CJK 输入不生成拼音支 / 首字母支，除非满足下列任一放宽条件。
    ///
    /// 这是「库内无匹配仍返回大量无关结果」的**根治门控**（精度审计 §12）。
    ///
    /// 问题链路：主趟是三支平铺 <c>OR</c>——
    /// <code>词法支("鬱") OR 拼音支(pinyin_* : "yu") OR 首字母支(initials_* : "y")</code>
    /// <c>鬱</c> 在 4.8 万首库里**字面命中 0**，但拼音 <c>yu</c> 命中 17,955 首、
    /// 首字母 <c>y</c> 命中 8,389 首，<c>0 OR 17955 OR 8389 = 17,955</c>。
    /// 即「字面零命中」根本不是停下来的理由——OR 的其他支还有结果。
    /// 同类实测：<c>籲</c> 11,848 / <c>迌</c> 5,675 / <c>龗</c> 5,331 / <c>靐</c> 4,159。
    ///
    /// **为什么按脚本分流**：CJK 输入产出的拼音是**派生的**（<c>鬱 → yu</c>），
    /// 与用户意图无关；拉丁输入产出的拼音**就是用户录入的字面**（<c>qiingtian</c>），
    /// 是明确的「用拼音找中文歌」意图。二者表面特征相同（字面 0 命中），
    /// 只能靠脚本区分——详见审计 §12.7 的反例（<c>qiingtian</c> 字面 0 命中但属合法检索）。
    ///
    /// 参考：Typesense 对 <c>zh/ko/ja</c> locale 直接关闭模糊遍历
    /// （<c>src/index.cpp:5096-5099</c>）；Meilisearch <c>typo_tokens_threshold=1</c>
    /// 的「精确优先」原则。<c>docs/local-search-indexer-references.md</c> §4.0 / §6.3。
    ///
    /// **回退方式**：把该常量语义去掉（或改为「总是允许」）即恢复旧行为，无需重建索引。
    /// </summary>
    public static readonly bool RequireLatinForReadingBranch = true;

    /// <summary>
    /// 上述门控的**放宽阈值**：CJK 字数达到该值时仍允许读音支。
    ///
    /// 单字查询（<c>鬱</c>）的拼音只有 2 个字符（<c>yu</c>），是最短的共享前缀，
    /// 几乎必然泛滥；多字查询（<c>周杰伦</c> → <c>zhou jie lun</c>）的拼音串更长、
    /// 组合更独特，放宽收益大于噪声成本。
    ///
    /// 取 2：单字被拦，两字及以上保留（与 <see cref="MinCrossLingualCjkLength"/> 同档）。
    /// </summary>
    public const int ReadingBranchMinCjkLength = 2;

    /// <summary>
    /// 替换容错的受限字母表（编辑距离 ≤1 的替换集合，刻意不用完整 26 字母）。
    /// 依据「元音误拼 + 键盘邻键 + 视觉 / 语音混淆」，每个字母只给少量候选。
    /// </summary>
    private static readonly Dictionary<char, string> SubstitutionAlternatives = new()
    {
        ['a'] = "eiou",
        ['e'] = "aiou",
        ['i'] = "aeou",
        ['o'] = "aeiu",
        ['u'] = "aeio",
        ['b'] = "pv",
        ['p'] = "b",
        ['v'] = "bf",
        ['f'] = "v",
        ['d'] = "t",
        ['t'] = "d",
        ['c'] = "ksz",
        ['k'] = "csq",
        ['s'] = "cz",
        ['z'] = "s",
        ['g'] = "j",
        ['j'] = "g",
        ['m'] = "n",
        ['n'] = "m",
        ['l'] = "r",
        ['r'] = "l",
        ['q'] = "k",
        ['w'] = "v",
    };

    /// <summary>拼音兜底趟**每个音节**的变体上限（含原形；T1-6 模糊音扩展）。</summary>
    public const int MaxPinyinVariantsPerSyllable = 4;

    /// <summary>
    /// 拼音兜底趟**每次查询**的变体总预算（跨音节累计）。
    ///
    /// 每个音节最多 <see cref="MaxPinyinVariantsPerSyllable"/> 个变体，但音节数没有天然上限：
    /// <c>woainima</c> 切出 4 个音节 → 最多 16 个变体组合。预算耗尽后，
    /// 剩余音节**从尾部往前**退回纯原形（不做模糊音扩展）。
    ///
    /// 取值 16：足够覆盖常见 2–3 音节查询的完整扩展
    /// （<c>qingtian</c> = 2 音节 × 2 变体共 4 个、<c>zhoujielun</c> = 3 音节共 6 个），
    /// 又能拦住超长输入的组合爆炸。参考 Meilisearch 派生阶段的候选上限
    /// （<c>MAX_ONE_TYPO_COUNT = 150</c> / <c>MAX_TWO_TYPOS_COUNT = 50</c>，
    /// <c>crates/milli/src/search/new/limits.rs</c>）——那里限制「一个词派生多少候选词」，
    /// 与这里限制「一次查询展开多少变体」同构，只是我们在更小的曲库上运行故取更紧的值。
    /// <c>docs/local-search-indexer-references.md</c> §3.6。
    /// </summary>
    public static readonly int DefaultMaxPinyinVariants = 16;

    /// <summary>声母模糊音对（双向）：平翘舌、n/l、f/h（方言常见混淆）。</summary>
    private static readonly (string A, string B)[] PinyinInitialFuzz =
    {
        ("zh", "z"),
        ("ch", "c"),
        ("sh", "s"),
        ("n", "l"),
        ("f", "h"),
    };

    /// <summary>韵母模糊音对（双向，仅匹配词尾）：前后鼻音。</summary>
    private static readonly (string A, string B)[] PinyinFinalFuzz =
    {
        ("ang", "an"),
        ("eng", "en"),
        ("ing", "in"),
    };

    /// <summary>把单个词元转义为 FTS5 双引号字符串（内部 <c>"</c> 翻倍）。</summary>
    public static string Quote(string token) => "\"" + token.Replace("\"", "\"\"") + "\"";

    /// <summary>编译主趟表达式；无可匹配内容返回 <c>null</c>。</summary>
    public static string? CompileMatch(QueryTokens tokens, bool metadata, bool includeCrossLingual = false)
    {
        var branches = new List<string>();
        Add(branches, LexicalBranch(tokens.Lexical));

        var readingAllowed = AllowReadingBranch(tokens);
        if (readingAllowed)
        {
            // 拉丁单字（`a` / `s` / `z`）是真实的首字母检索，必须保留首字母支；
            // 但**拼音支**对单字母毫无区分力（`a` 在 pinyin_meta 命中 2,109 首），故排除。
            var latinSingle = IsLatinSingleChar(tokens);
            if (!latinSingle) Add(branches, PinyinBranch(tokens.Pinyin));
            Add(branches, InitialsBranch(tokens.PinyinInitials));
        }
        if (includeCrossLingual) Add(branches, CrossLingualBranch(tokens.CrossLingual, tokens.Lexical));

        // 单字查询的列门控（精度审计 §14 / §15）。
        if (RestrictSingleCharToMetadata(tokens))
        {
            if (branches.Count == 0) return null;
            var joined = string.Join(" OR ", branches);
            // 汉字单字：只认可见文本（歌名 / 歌手 / 专辑 / 文件名），派生转写列对汉字恒为 0 命中。
            // 拉丁单字：额外放开首字母列（真实的首字母检索），但仍不含歌词。
            var cols = tokens.HasCjk ? VisibleTextColumns : SingleCharLatinColumns;
            return $"{{{cols}}} : ({joined})";
        }
        return JoinBranches(branches, metadata);
    }

    /// <summary>
    /// 拉丁单字查询允许的列集合：可见文本 + 首字母（真实的首字母检索）。
    /// <b>不含</b> <c>pinyin_meta_tok</c>——单个字母在拼音列里毫无区分力
    /// （真实库实测 <c>a</c> 命中 2,109 首，而标题只有 618 首）。
    /// <b>不含</b>任何歌词列。
    /// </summary>
    public const string SingleCharLatinColumns =
        "title_tok artist_tok album_tok filename_tok initials_meta_tok";

    /// <summary>
    /// **精确 / 前缀分层**：末词的前缀匹配是否同时保留精确词。
    ///
    /// 现状：末词直接加 <c>*</c>（<c>"love"*</c>），精确命中与前缀命中在 bm25 里拿不到
    /// 任何区分——「歌词含 love」与「歌词含 lovesongs」评分同档。
    ///
    /// 改为 <c>("love" OR "love"*)</c>：精确词是前缀词的**子集**，所以
    /// **命中集合完全不变**（真实库实测：<c>love</c> 1,297 → 1,297、差分 0），
    /// 但 bm25 会因精确词的更高 IDF 把「含字面词」的行排到前面。
    ///
    /// 真实库实测（48,759 首）：
    /// <list type="bullet">
    ///   <item><c>love</c> 仅前缀 top-5 = <c>30176 / 37171 / 36345 / 49794 / 46599</c>；</item>
    ///   <item>改为 <c>(love OR love*)</c> 后 top-5 = <c>19523 / 110 / 36345 / 20213 / 17554</c>，
    ///         与「仅精确查询」的 top-5 <b>完全一致</b>。</item>
    /// </list>
    ///
    /// 参考：Navidrome <c>buildFTS5Query</c> 的 <c>(token OR token*)</c>
    /// （<c>persistence/sql_search_fts.go:169-177</c>，注释原文「The OR adds no matches
    /// (exact ⊂ prefix) but gives bm25 a high-IDF exact-term hit」）。
    /// <c>docs/local-search-indexer-references.md</c> §2.2。
    ///
    /// **回退方式**：改为 <c>false</c> 即恢复「纯前缀」，无需重建索引。
    /// </summary>
    public static readonly bool PairExactWithPrefix = true;

    /// <summary>把末词编译为 <c>("tok" OR "tok"*)</c> 或 <c>"tok"*</c>。</summary>
    private static string PrefixTerm(string token) =>
        PairExactWithPrefix ? $"({Quote(token)} OR {Quote(token)}*)" : Quote(token) + "*";

    /// <summary>
    /// **丢词降级**：多词查询命中不足时，从末尾开始逐个丢弃查询词后重新召回。
    ///
    /// 这是三种放宽方向里**唯一安全**的一种（精度审计 §18）：
    /// <list type="bullet">
    ///   <item><b>减词</b>（本项）：<c>夜 雨 恨</c> → <c>夜 AND 雨</c>——仍是字面匹配；</item>
    ///   <item>改读音：<c>鬱 → yu</c>——换了维度，语义可能完全无关；</item>
    ///   <item>返回空：会误伤拼音检索（§12.7）。</item>
    /// </list>
    ///
    /// 参考 Meilisearch <c>TermsMatchingStrategy::Last</c>（默认策略：
    /// <c>cost = 1 + last_term_idx - term_idx</c>，从末词往前丢，
    /// <c>query_graph.rs:402-404</c> 的 <c>res.pop()</c> 保证至少留 1 个词）
    /// 与 Typesense <c>drop_tokens_threshold</c>（默认 1，先右后左，最多 2 个方向）。
    ///
    /// **回退方式**：改为 <c>false</c> 即恢复「不做丢词降级」，无需重建索引。
    /// </summary>
    public static readonly bool AllowDropTokens = true;

    /// <summary>
    /// 生成丢词降级的 MATCH 表达式：把 <paramref name="query"/> 按空白切成词，
    /// 丢掉末词后对剩余部分重新编译。
    ///
    /// 返回 <c>null</c> 表示不适用（单词查询、或丢词后无可匹配内容）。
    ///
    /// **为什么按原始串切词而不是复用 <paramref name="tokens"/>**：CJK 词元已被展平成
    /// bigram 序列（<c>周杰伦 晴天</c> → <c>周杰 杰伦 晴天 …</c>），丢失了「词」的边界；
    /// 丢词必须以用户输入的空格分隔单位为准。
    /// </summary>
    public static string? CompileDropTokens(QueryTokens tokens, string query, bool metadata)
    {
        if (!AllowDropTokens) return null;

        var words = SplitQueryWords(query);
        // 单「词」查询没得丢——丢到 0 个词就变成任意结果，必须禁止。
        if (words.Count < 2) return null;

        // 只丢**末词**（此方法为单轮版本，保留给需要精确控制调用方的场景）。
        return CompileDropTokens(tokens, query, metadata, words.Count - 1);
    }

    /// <summary>
    /// 丢掉第 <paramref name="dropIndex"/> 个词后的 MATCH 表达式；不适用时返回 <c>null</c>。
    /// </summary>
    internal static string? CompileDropTokens(
        QueryTokens tokens, string query, bool metadata, int dropIndex)
    {
        var words = SplitQueryWords(query);
        if (words.Count < 2 || dropIndex < 0 || dropIndex >= words.Count) return null;

        var keptWords = words.Where((_, i) => i != dropIndex).ToList();
        if (keptWords.Count == 0) return null;

        var kept = string.Join(' ', keptWords);
        var keptTokens = Analyzer.AnalyzeQuery(kept);
        if (keptTokens.Lexical.Count == 0) return null;

        // 用保持的词的「词法支 + 读音支」重新编译，但**不包含跨语言 / 容错**——
        // 本趟的语义是「字面少匹配一个词」，不是放宽匹配维度。
        var expression = CompileMatch(keptTokens, metadata);
        if (expression is null) return null;

        // 若丢词后的表达式与原始表达式完全一致（例如该词本就无词元），则无意义。
        var original = CompileMatch(tokens, metadata);
        return string.Equals(expression, original, StringComparison.Ordinal) ? null : expression;
    }

    /// <summary>
    /// 丢词降级的**候选丢法**，按优先级排序。
    ///
    /// **为什么不是「从末词往前丢」**：Meilisearch 的 <c>Last</c> 策略假设「尾部词
    /// 最不重要」，这在英文查询里通常成立（修饰语后置）。但中文音乐检索的主流写法是
    /// **「歌手 + 歌名」**（<c>周杰伦 晴天</c>、<c>陈奕迅 十年</c>），
    /// 歌名恰恰在**尾部**且是最该保留的部分——照搬 <c>Last</c> 会把最有价值的词先丢掉。
    ///
    /// 参考 Meilisearch 的另一种策略 <c>Frequency</c>
    /// （<c>query_graph.rs:303-343</c>：按词的文档频率降序丢，先丢高频泛词）——
    /// 它的思路是「越常见的词越不重要」，不依赖词的位置。
    ///
    /// 我们的折中（**不引入查询期 df 统计**）：先丢**首位**词，再依次往后丢。
    /// 依据：中文音乐查询里首词常是「泛化的歌手名 / 类型词」，尾词更可能是具体曲名；
    /// 拉丁查询（<c>love story</c>）则尾词常是修饰语，故按**脚本**区分方向。
    ///
    /// 返回顺序即尝试顺序：调用方应逐轮尝试并在**命中足够时停止**，
    /// 而不是取第一轮的结果（否则丢掉尾词后就再也不会试「保留尾词」的丢法）。
    /// </summary>
    public static IReadOnlyList<int> DropTokenCandidates(QueryTokens tokens, string query)
    {
        var words = SplitQueryWords(query);
        if (words.Count < 2) return Array.Empty<int>();

        // 中文（含 CJK）查询：优先丢**首位**词（通常是歌手名），保留尾部曲名。
        // 纯拉丁查询：沿用 Meilisearch `Last` 的从尾部丢。
        var indices = new List<int>(words.Count - 1);
        if (tokens.HasCjk)
        {
            for (var i = 0; i < words.Count; i++) indices.Add(i);
        }
        else
        {
            for (var i = words.Count - 1; i >= 0; i--) indices.Add(i);
        }
        return indices;
    }

    /// <summary>
    /// 按**元数据字段命中分布**重排丢词候选：越像「歌名」的词越靠后（越晚丢）。
    ///
    /// 精度审计 §23：仅靠位置猜「谁是歌名」在反向写法（<c>晴天 周杰伦</c>）下会猜错。
    /// 更可靠的信号是**该词在 title 列与 artist 列的命中分布**：
    /// <list type="bullet">
    ///   <item>某词只在 title 命中、或 title 远多于 artist → 它是**歌名**，最后才丢；</item>
    ///   <item>某词在 artist 命中更多 → 它是**歌手**，优先丢；</item>
    ///   <item>两边都没有 / 相等 → 保持原顺序（信息不足，不猜）。</item>
    /// </list>
    ///
    /// 真实库验证（48,759 首）：<c>晴天</c> title 22 / artist 1 → 判为歌名（正确）；
    /// <c>周杰伦</c> 在库里 0/0 → 信息不足，保持位置顺序。
    ///
    /// <paramref name="titleCounts"/> / <paramref name="artistCounts"/> 与
    /// <paramref name="words"/> 一一对应（由调用方用 <c>FtsStore.CountMatches</c> 填入）。
    ///
    /// **成本**：每个词 2 次计数查询。仅在**主趟 0 命中的多词查询**上执行，
    /// 属于罕见路径；且计数查询走 FTS5 的 COUNT 优化，实测单次 &lt;1ms。
    /// </summary>
    public static IReadOnlyList<int> OrderDropsByFieldAffinity(
        IReadOnlyList<int> candidates,
        IReadOnlyList<int> titleCounts,
        IReadOnlyList<int> artistCounts)
    {
        if (candidates.Count <= 1) return candidates;

        // 每个词的「歌名倾向」：title 命中数 - artist 命中数。
        // 正值越大越像歌名 → 越晚丢；负值越大越像歌手 → 越早丢。
        int Affinity(int index)
        {
            if (index < 0 || index >= titleCounts.Count || index >= artistCounts.Count) return 0;
            return titleCounts[index] - artistCounts[index];
        }

        // 稳定排序：倾向低的先丢；倾向相同则保持原候选顺序。
        // 预先记录每项在原候选里的位置，避免在比较函数里反复 O(n) 查找。
        var positions = new Dictionary<int, int>(candidates.Count);
        for (var i = 0; i < candidates.Count; i++) positions[candidates[i]] = i;

        var ordered = candidates.ToList();
        ordered.Sort((a, b) =>
        {
            var cmp = Affinity(a).CompareTo(Affinity(b));
            if (cmp != 0) return cmp;
            return positions[a].CompareTo(positions[b]);
        });
        return ordered;
    }

    /// <summary>
    /// 按空白切分查询串为「词」（保留原始片段，供丢词重编译）。
    ///
    /// 只按空格 / 制表符切；CJK 不切（<c>周杰伦</c> 是一个词，丢词不会把它拆成两半）。
    /// </summary>
    private static List<string> SplitQueryWords(string query)
    {
        var words = new List<string>();
        foreach (var part in query.Split(
            (char[]?)null, StringSplitOptions.RemoveEmptyEntries))
        {
            words.Add(part);
        }
        return words;
    }

    /// <summary>
    /// **单字查询的列门控**：查询只含一个字符时，词法支限定在元数据列（标题 / 歌手 /
    /// 专辑 / 文件名），不扫歌词列。
    ///
    /// 问题（精度审计 §11.3 N-1）：<see cref="JoinBranches"/> 只在 <c>metadata == true</c>
    /// 时套列过滤；默认的 <c>scope=all</c> 下**词法支没有任何列限定**，于是单字查询直接扫
    /// <c>lyrics_tok</c>。真实库实测（48,759 首）：
    /// <list type="bullet">
    ///   <item><c>恨</c>：标题等元数据仅 **38** 首，歌词里 **1,311** 首 → 放大 **34.5×**；</item>
    ///   <item><c>黑</c>：246 vs 2,548（10.4×）；<c>爱</c>：2,012 vs 12,620（6.3×）。</item>
    /// </list>
    ///
    /// **为什么单字要区别对待**：一个汉字在歌词里的 df 极高（<c>的</c> 覆盖全库 42.6%），
    /// 「歌词含某个字」几乎不构成检索意图；而「标题 / 歌手 / 专辑含某个字」是明确意图
    /// （搜「爱」找歌名带「爱」的歌）。多字查询不受影响——两字以上的组合已足够独特。
    ///
    /// 实测收益（§11.5.1）：单字召回从五位数降到百~千级，<c>恨</c> 1,311→38（−97%）。
    ///
    /// 参考：Typesense 的 <c>query_by</c> 字段权重机制（字段本身就是召回范围）、
    /// Navidrome 把元数据与歌词分表索引（<c>media_file_fts</c> 不含歌词）。
    /// <c>docs/local-search-indexer-references.md</c> §2.3。
    ///
    /// **回退方式**：把该常量改为 <c>false</c> 即恢复旧行为（单字也扫歌词列），无需重建索引。
    /// </summary>
    public static readonly bool RequireMetadataForSingleChar = true;

    /// <summary>
    /// <see cref="RequireMetadataForSingleChar"/> 的判定：查询是否「只有一个字符」。
    ///
    /// 用词法词元里**去重后的可见字符数**衡量（与 <see cref="CjkCharCount"/> 同源），
    /// 所以 <c>愛</c>（繁简折叠后为 <c>爱</c>）与 <c>爱</c> 判定一致，都是单字。
    /// </summary>
    private static bool RestrictSingleCharToMetadata(QueryTokens tokens)
    {
        if (!RequireMetadataForSingleChar) return false;
        return VisibleCharCount(tokens.Lexical) is 1;
    }

    /// <summary>
    /// 查询是否为「单个拉丁字母」（<c>a</c> / <c>s</c> / <c>z</c>）。
    ///
    /// 这类查询是真实存在的（真实查询日志里有 17 个：<c>s</c> / <c>e</c> / <c>a</c> /
    /// <c>l</c> / <c>p</c> / <c>h</c> / <c>t</c> / <c>b</c> / <c>g</c> / <c>w</c> /
    /// <c>y</c> / <c>d</c> / <c>z</c> / <c>i</c> / <c>c</c> / <c>E</c> / <c>G</c>），
    /// 用途通常是**首字母检索**（输 <c>z</c> 找周杰伦）。
    ///
    /// 所以拉丁单字**保留首字母支**，但排除拼音支（单字母在拼音列里毫无区分力）。
    /// </summary>
    private static bool IsLatinSingleChar(QueryTokens tokens)
    {
        if (VisibleCharCount(tokens.Lexical) != 1) return false;
        foreach (var token in tokens.Lexical)
        {
            foreach (var ch in token)
            {
                if (char.IsWhiteSpace(ch)) continue;
                return ch is >= 'a' and <= 'z' or >= 'A' and <= 'Z';
            }
        }
        return false;
    }

    /// <summary>词法词元里去重后的可见字符数（空白不计）。</summary>
    private static int VisibleCharCount(IReadOnlyList<string>? lexical)
    {
        if (lexical is null || lexical.Count == 0) return 0;
        var chars = new HashSet<char>();
        foreach (var token in lexical)
        {
            foreach (var ch in token)
            {
                if (!char.IsWhiteSpace(ch)) chars.Add(ch);
            }
        }
        return chars.Count;
    }

    /// <summary>
    /// 读音支（拼音 / 首字母）是否允许进入主趟——**脚本分流门控**。
    ///
    /// 见 <see cref="RequireLatinForReadingBranch"/>：CJK 输入产出的拼音是派生的，
    /// 与检索意图无关；只有「拉丁输入」或「CJK 字数达到
    /// <see cref="ReadingBranchMinCjkLength"/>」时才允许读音支参与 OR。
    ///
    /// 为何放行拉丁输入：<c>qiingtian</c> 这类查询字面命中为 0，但它是用户
    /// **明确用拼音找中文歌**的意图，必须保留（审计 §12.7 的误伤反例）。
    /// </summary>
    private static bool AllowReadingBranch(QueryTokens tokens)
    {
        if (!RequireLatinForReadingBranch) return true;
        if (!tokens.HasCjk) return true;
        return CjkCharCount(tokens.Lexical) >= ReadingBranchMinCjkLength;
    }

    /// <summary>跨语言候选分支（T1）：候选逐字加引号后 OR；无候选返回 <c>null</c>。</summary>
    public static string? CompileCrossLingual(QueryTokens tokens, bool metadata)
    {
        var branch = CrossLingualBranch(tokens.CrossLingual, tokens.Lexical);
        if (branch is null) return null;
        return metadata ? $"{{{MetadataColumns}}} : {branch}" : branch;
    }

    /// <summary>
    /// 拼音宽松兜底支：音节位置无关 <c>AND</c>，末音节 ≥3 字符前缀；&lt;2 音节返回 <c>null</c>。
    ///
    /// **模糊音扩展**（T1-6）：每个音节（仅限有效拼音音节，英文词不扩展）按声母
    /// <c>zh/z、ch/c、sh/s、n/l、f/h</c> 与韵母 <c>ang/an、eng/en、ing/in</c> 生成
    /// 至多 <see cref="MaxPinyinVariantsPerSyllable"/> 个变体（原形 + 声母 + 韵母 + 两者组合），
    /// 同一音节内 <c>OR</c>，音节之间仍 <c>AND</c>。只出现在兜底趟，不增加主趟成本。
    ///
    /// **总变体预算**（<see cref="DefaultMaxPinyinVariants"/>）：音节数 × 每音节变体数
    /// 超过预算时，**从尾部音节开始退回纯原形**（不做模糊音扩展）。
    /// 参考 Meilisearch 的派生阶段候选上限（<c>MAX_ONE_TYPO_COUNT = 150</c> /
    /// <c>MAX_TWO_TYPOS_COUNT = 50</c>，<c>crates/milli/src/search/new/limits.rs</c>）——
    /// 那里限制的是「一个词派生出多少候选词」，与这里限制「一次查询展开多少变体」同构。
    /// 详见 <c>docs/local-search-indexer-references.md</c> §3.6。
    /// </summary>
    public static string? CompilePinyinLoose(QueryTokens tokens, bool metadata)
    {
        var clean = Clean(tokens.Pinyin);
        if (clean.Count < 2) return null;

        // 总变体预算：从**尾部音节**开始分配（尾部通常是查询里最不确定的部分，
        // 首音节往往承载主要语义——与 Meilisearch `Last` 策略「首词最不可丢」一致）。
        // 预算耗尽后，剩余音节退回纯原形（不做模糊音扩展）。
        var budget = Math.Max(1, DefaultMaxPinyinVariants);
        var variantsPerSyllable = new List<string>[clean.Count];
        for (var i = clean.Count - 1; i >= 0; i--)
        {
            var take = Math.Min(MaxPinyinVariantsPerSyllable, budget);
            var variants = PinyinFuzzyVariants(clean[i], take);
            variantsPerSyllable[i] = variants;
            budget = Math.Max(0, budget - variants.Count);
        }

        var chunks = new List<string>(clean.Count);
        for (var i = 0; i < clean.Count; i++)
        {
            var prefix = i == clean.Count - 1 && clean[i].Length >= MinPrefixTokenLength;
            var variants = variantsPerSyllable[i];
            if (variants.Count == 1)
            {
                chunks.Add(prefix ? Quote(variants[0]) + "*" : Quote(variants[0]));
                continue;
            }
            var group = string.Join(
                " OR ", variants.Select(v => prefix ? Quote(v) + "*" : Quote(v)));
            chunks.Add("(" + group + ")");
        }

        var body = string.Join(" AND ", chunks);
        return metadata
            ? $"{{{MetadataColumns}}} : ({body})"
            : $"{{{PinyinColumns}}} : ({body})";
    }

    /// <summary>
    /// 单个音节的模糊音变体（含原形，最多 <paramref name="maxVariants"/> 个）：
    /// 原形 → 声母替换 → 韵母替换 → 两者组合。非有效拼音音节（英文词）原样返回。
    /// </summary>
    private static List<string> PinyinFuzzyVariants(string syllable, int maxVariants)
    {
        var output = new List<string> { syllable };
        if (maxVariants <= 1 || !PinyinSegmenter.IsSyllable(syllable)) return output;

        var initial = SwapAffix(syllable, PinyinInitialFuzz, prefix: true);
        var final = SwapAffix(syllable, PinyinFinalFuzz, prefix: false);

        void Add(string? candidate)
        {
            if (candidate is null || candidate.Length == 0) return;
            if (output.Count >= maxVariants) return;
            if (!output.Contains(candidate, StringComparer.Ordinal)) output.Add(candidate);
        }

        Add(initial);
        Add(final);
        if (initial is not null) Add(SwapAffix(initial, PinyinFinalFuzz, prefix: false));
        return output;
    }

    /// <summary>
    /// 在词首（声母）或词尾（韵母）把模糊音对的一侧换成另一侧；无匹配返回 <c>null</c>。
    /// 两侧都试（双向），故「输入正确拼音」与「输入方言混淆拼音」都能召回。
    /// </summary>
    private static string? SwapAffix(
        string text, (string A, string B)[] pairs, bool prefix)
    {
        foreach (var (a, b) in pairs)
        {
            if (prefix)
            {
                if (text.StartsWith(a, StringComparison.Ordinal)) return b + text[a.Length..];
                if (text.StartsWith(b, StringComparison.Ordinal)) return a + text[b.Length..];
            }
            else
            {
                if (text.EndsWith(a, StringComparison.Ordinal)) return text[..^a.Length] + b;
                if (text.EndsWith(b, StringComparison.Ordinal)) return text[..^b.Length] + a;
            }
        }
        return null;
    }

    /// <summary>日文读音兜底支：拉丁 / 数字词元的字母 bigram 短语 AND 到读音列；无词元返回 <c>null</c>。</summary>
    public static string? CompileReading(QueryTokens tokens, bool metadata)
    {
        var parts = new List<string>();
        foreach (var token in tokens.Lexical)
        {
            // 罗马字规范形（T1-1）：Hepburn / Kunrei 折叠后与索引侧同构；
            // 「ん + 元音」额外给放宽变体，两候选 OR（原始形态始终保留）。
            var sequences = ReadingSequences(token);
            if (sequences.Count == 0) continue;

            // 单个引号短语 = 相邻 bigram 序列（FTS5 短语语义），等价于对该词元做子串检索。
            var phrases = sequences.Select(s => Quote(string.Join(' ', s))).ToList();
            parts.Add(phrases.Count == 1 ? phrases[0] : $"({string.Join(" OR ", phrases)})");
        }
        if (parts.Count == 0) return null;
        var body = string.Join(" AND ", parts);
        return metadata
            ? $"{{{MetadataColumns}}} : ({body})"
            : $"{{{ReadingColumns}}} : ({body})";
    }

    /// <summary>
    /// 查询中可走读音趟的词元的 <b>规范形 bigram 序列</b>（每个拼写变体一条）；
    /// 供 <see cref="ReadingRanker"/> 判定「前缀 / 包含」档位（T1-4）。
    /// </summary>
    public static List<string[]> ReadingSequences(QueryTokens tokens)
    {
        var output = new List<string[]>();
        foreach (var token in tokens.Lexical) AddReadingSequences(token, output);
        return output;
    }

    private static List<string[]> ReadingSequences(string token)
    {
        var output = new List<string[]>();
        AddReadingSequences(token, output);
        return output;
    }

    private static void AddReadingSequences(string token, List<string[]> output)
    {
        var lower = token.ToLowerInvariant();
        if (lower.Length < 2 || HasIndexedScript(lower)) return;

        foreach (var variant in RomajiCanonical.Variants(lower))
        {
            if (variant.Length < 2) continue;
            var bigrams = new List<string>(variant.Length - 1);
            for (var i = 0; i + 1 < variant.Length; i++) bigrams.Add(variant.Substring(i, 2));
            if (bigrams.Count > 0) output.Add(bigrams.ToArray());
        }
    }

    /// <summary>查询是否含可做编辑距离扩展的拉丁 / 数字词法词元。</summary>
    public static bool HasFuzzyEligible(QueryTokens tokens) => tokens.Lexical.Any(IsFuzzyEligible);

    /// <summary>编译模糊（容错）表达式：拉丁 / 数字词元换成编辑距离 ≤1 变体 OR 组。</summary>
    public static string? CompileFuzzy(
        QueryTokens tokens, bool metadata, int maxVariants = DefaultMaxFuzzyVariants)
        => CompileFuzzy(tokens, metadata, vocabulary: null, maxVariants);

    /// <summary>
    /// 同上，但用索引词表（T1-8）过滤候选：只保留索引里确实存在、且与查询词
    /// Damerau 距离 ≤1 的 term；词表为空（加载失败 / 空库）时退回无词典行为。
    /// </summary>
    public static string? CompileFuzzy(
        QueryTokens tokens, bool metadata, IReadOnlyList<string>? vocabulary,
        int maxVariants = DefaultMaxFuzzyVariants)
    {
        var branches = new List<string>();
        Add(branches, FuzzyLexicalBranch(tokens.Lexical, maxVariants, vocabulary));
        Add(branches, PinyinBranch(tokens.Pinyin));
        Add(branches, InitialsBranch(tokens.PinyinInitials));
        return JoinBranches(branches, metadata);
    }

    /// <summary>
    /// 生成 CJK 编辑距离 ≤1 变体（删除任一字符 / 相邻换位）；不含原串，去重保序。
    /// 子序列长度 &lt;<see cref="MinCjkFuzzyLength"/> 或 &gt;<see cref="MaxCjkQueryLength"/> 返回空。
    ///
    /// 下限取 3（精度审计 §2.5）：两字查询删一字必然退化成单字，而单字查询本身宽覆盖，
    /// 等于把两字查询放大成两次单字查询。
    /// </summary>
    public static List<string> CjkVariants(string query, int maxVariants = DefaultMaxCjkVariants)
    {
        var sequence = CjkSubsequence(query);
        if (sequence.Length < MinCjkFuzzyLength || sequence.Length > MaxCjkQueryLength)
            return new List<string>();

        var output = new List<string>();
        var seen = new HashSet<string>(StringComparer.Ordinal) { sequence };

        void Add(string candidate)
        {
            if (candidate.Length == 0) return;
            if (seen.Add(candidate)) output.Add(candidate);
        }

        // 删除：去掉任一字符（用户多打一字）。
        for (var i = 0; i < sequence.Length; i++) Add(sequence.Remove(i, 1));
        // 相邻换位（跳过相同字符对：换位无意义且与原串相同）。
        for (var i = 0; i + 1 < sequence.Length; i++)
        {
            if (sequence[i] == sequence[i + 1]) continue;
            var chars = sequence.ToCharArray();
            (chars[i], chars[i + 1]) = (chars[i + 1], chars[i]);
            Add(new string(chars));
        }

        if (output.Count > maxVariants) return output.GetRange(0, maxVariants);
        return output;
    }

    /* ------------------------------------------------------------------ */
    /* 分支                                                                */
    /* ------------------------------------------------------------------ */

    private static string? LexicalBranch(IReadOnlyList<string> terms)
    {
        var clean = Clean(terms);
        if (clean.Count == 0) return null;

        // 每个 chunk 记住它「单独对应」的词元（短语块为 null），便于后续按词元改写。
        var chunks = new List<string>();
        var chunkTerm = new List<string?>();
        var i = 0;
        while (i < clean.Count)
        {
            if (IsCjkBigram(clean[i]))
            {
                var j = i;
                while (j < clean.Count && IsCjkBigram(clean[j])) j++;
                var run = clean.GetRange(i, j - i);
                // 连续 ≥2 个 bigram → 引号短语；单个 bigram → 原样加引号。
                chunks.Add(Quote(run.Count >= 2 ? string.Join(' ', run) : run[0]));
                // 单个 bigram 仍是独立词元，可用于前缀改写；短语块不行。
                chunkTerm.Add(run.Count >= 2 ? null : run[0]);
                i = j;
            }
            else
            {
                chunks.Add(Quote(clean[i]));
                chunkTerm.Add(clean[i]);
                i++;
            }
        }

        var prefixLast = IsPrefixable(clean[^1]) && clean[^1].Length >= MinPrefixTokenLength;
        if (prefixLast && chunks.Count > 0)
            chunks[^1] = PrefixTerm(clean[^1]);

        // 单个 CJK 字：索引里已无「中间字」的 unigram（Analyzer.KeepCjkEdgeUnigrams），
        // 必须改走前缀 `字*` 才能命中以该字开头的 bigram；否则只能命中段首 / 段末的字
        // （精度审计 §17）。只改「独立成块」的单字，短语块保持原样。
        for (var k = 0; k < chunks.Count; k++)
        {
            var term = chunkTerm[k];
            if (term is null || !IsSingleCjkChar(term)) continue;
            chunks[k] = PrefixTerm(term);
        }

        return string.Join(" AND ", chunks);
    }

    private static string? PinyinBranch(IReadOnlyList<string> terms)
    {
        var clean = Clean(terms);
        if (clean.Count == 0) return null;
        if (clean.Count == 1)
            return $"{{{PinyinColumns}}} : {QuotedAnd(clean, clean[^1].Length >= MinPrefixTokenLength)}";
        return $"{{{PinyinColumns}}} : {Quote(string.Join(' ', clean))}";
    }

    private static string? InitialsBranch(string? initials)
    {
        if (string.IsNullOrWhiteSpace(initials)) return null;
        var terms = initials.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).ToList();
        if (terms.Count == 0) return null;
        // 门控（精度审计 §2.2）：单字母首字母串**不生成该支**。单个汉字查询会产出单字母
        // （恨→h / 爱→a / 痛→t），而单字母 token 在歌词（整行「啊」）、文件名（t164）、
        // 单字标题（A / I）里密集存在——按精确 term 匹配会命中整库。
        if (string.Concat(terms).Length < MinInitialsBranchLength) return null;
        var body = QuotedAnd(terms, terms[^1].Length >= MinInitialsPrefixLength);
        // 整体加括号：列过滤与 OR 混排时边界更明确（列过滤只作用于本支）。
        // 注意多列过滤必须用**花括号**：FTS5 的 `a b : expr` 是「列 a 后接词元 b」，
        // 不是列集合，会静默返回空集（本分支因此从不命中）。
        return $"({{{InitialsColumns}}} : {body})";
    }

    /// <summary>
    /// 跨语言候选分支。**汉字侧单字门控**（精度审计 §2.4）：查询只含一个汉字时，
    /// 丢掉「汉字 → 英文释义词」方向的候选（Unihan 对单字释义极度发散：
    /// <c>痛 → ache / bitter / pain / sad / sorry</c>，会把这个查询放大到近乎整库）；
    /// 「拉丁词 → 候选汉字」方向（<c>love → 爱</c>）不受影响。
    ///
    /// 判定依据是**查询侧 CJK 词法词元去重后的字数**，不看候选本身——这样
    /// <c>爱</c>（候选 fond/like/love）与 <c>痛</c> 一致被裁，而 <c>月亮</c>（候选 moon 等）保留。
    /// </summary>
    private static string? CrossLingualBranch(IReadOnlyList<string> terms, IReadOnlyList<string>? lexical)
    {
        var clean = Clean(terms);
        if (clean.Count == 0) return null;
        var cjkChars = CjkCharCount(lexical);
        if (cjkChars > 0 && cjkChars < MinCrossLingualCjkLength)
        {
            // 单字汉字查询：只保留「拉丁 → 汉字」方向的候选（CJK 形态），
            // 丢掉英文释义词（非 CJK 形态）。
            clean = clean.Where(IsCjkText).ToList();
            if (clean.Count == 0) return null;
        }
        return clean.Count == 1
            ? Quote(clean[0])
            : "(" + string.Join(" OR ", clean.Select(Quote)) + ")";
    }

    /// <summary>查询侧 CJK 词法词元里**去重后的汉字个数**（bigram 会重复计数，故按字符集去重）。</summary>
    private static int CjkCharCount(IReadOnlyList<string>? lexical)
    {
        if (lexical is null || lexical.Count == 0) return 0;
        var chars = new HashSet<char>();
        foreach (var token in lexical)
        {
            foreach (var ch in token)
            {
                if (ScriptRanges.IsCjk(ch)) chars.Add(ch);
            }
        }
        return chars.Count;
    }

    /// <summary>整串是否只由 CJK / 假名 / 谚文构成（跨语言候选归属判定用）。</summary>
    private static bool IsCjkText(string text)
    {
        if (text.Length == 0) return false;
        foreach (var ch in text)
        {
            if (!IsIndexedScript(ch)) return false;
        }
        return true;
    }

    /// <summary>单个变体前缀下最多枚举多少个真实词条；超过则退回前缀匹配（避免枚举爆炸）。</summary>
    private const int MaxExactTermsPerVariant = 32;

    private static string? FuzzyLexicalBranch(
        IReadOnlyList<string> terms, int maxVariants, IReadOnlyList<string>? vocabulary)
    {
        var clean = Clean(terms);
        if (clean.Count == 0) return null;

        var useVocabulary = vocabulary is { Count: > 0 };
        var expandable = new List<int>();
        for (var i = 0; i < clean.Count; i++)
        {
            if (IsFuzzyEligible(clean[i])) expandable.Add(i);
        }

        // 每个可扩展词元 → 一批**已加引号**的 FTS 表达式（精确 term 或前缀形态）。
        var groups = new Dictionary<int, List<string>>();
        foreach (var i in expandable)
        {
            var prefix = i == clean.Count - 1
                && IsPrefixable(clean[i])
                && clean[i].Length >= MinPrefixTokenLength;
            if (!useVocabulary)
            {
                groups[i] = EditDistanceOneVariants(clean[i])
                    .Select(v => prefix ? Quote(v) + "*" : Quote(v))
                    .ToList();
                continue;
            }

            var limited = vocabulary!.Count > 0 && maxVariants > 0
                ? VocabularyExpressions(clean[i], vocabulary, maxVariants)
                : new List<string>();
            groups[i] = limited;
        }

        var total = groups.Values.Sum(list => list.Count);
        if (!useVocabulary && total > maxVariants && expandable.Count > 0)
        {
            // 预算超限：只扩展最后一个可扩展词元（并截断），其余退回精确。
            var last = expandable[^1];
            var lastPrefix = last == clean.Count - 1
                && IsPrefixable(clean[last])
                && clean[last].Length >= MinPrefixTokenLength;
            var full = EditDistanceOneVariants(clean[last])
                .Select(v => lastPrefix ? Quote(v) + "*" : Quote(v))
                .ToList();
            groups.Clear();
            groups[last] = full.Count > maxVariants ? full.GetRange(0, maxVariants) : full;
        }

        var chunks = new List<string>();
        var index = 0;
        while (index < clean.Count)
        {
            if (IsCjkBigram(clean[index]))
            {
                var j = index;
                while (j < clean.Count && IsCjkBigram(clean[j])) j++;
                var run = clean.GetRange(index, j - index);
                chunks.Add(Quote(run.Count >= 2 ? string.Join(' ', run) : run[0]));
                index = j;
                continue;
            }

            var prefix = index == clean.Count - 1
                && IsPrefixable(clean[index])
                && clean[index].Length >= MinPrefixTokenLength;
            if (groups.TryGetValue(index, out var list) && list.Count > 0)
            {
                chunks.Add(list.Count == 1 ? list[0] : "(" + string.Join(" OR ", list) + ")");
            }
            else if (useVocabulary && IsFuzzyEligible(clean[index]))
            {
                // 词表只覆盖文本列（见 FtsStore.LoadFuzzyVocabulary）；拼音 / 首字母 /
                // 读音列里的词条不在其中，所以「词表无候选」≠「索引里不存在」。
                // 退回无词表的变体枚举，保住旧召回（如 "woo" 的删除变体 "wo" 只存在于拼音列）。
                var bare = EditDistanceOneVariants(clean[index])
                    .Select(v => prefix ? Quote(v) + "*" : Quote(v))
                    .ToList();
                if (bare.Count > maxVariants) bare = bare.GetRange(0, maxVariants);
                chunks.Add(bare.Count == 1 ? bare[0] : "(" + string.Join(" OR ", bare) + ")");
            }
            else
            {
                var quoted = Quote(clean[index]);
                chunks.Add(prefix ? quoted + "*" : quoted);
            }
            index++;
        }
        return string.Join(" AND ", chunks);
    }

    /// <summary>
    /// 词典化的模糊候选（T1-8）：对每个编辑距离 ≤1 变体，取词表中同前缀的真实词条，
    /// 再用 Myers 位并行复核 Damerau 距离 ≤1；前缀下词条过多时退回前缀匹配（保留旧召回）。
    /// </summary>
    private static List<string> VocabularyExpressions(
        string word, IReadOnlyList<string> vocabulary, int maxVariants)
    {
        var output = new List<string>();
        var seen = new HashSet<string>(StringComparer.Ordinal);

        foreach (var variant in EditDistanceOneVariants(word))
        {
            var (start, end) = FuzzyVocabulary.PrefixRange(vocabulary, variant);
            if (end <= start) continue;

            if (end - start <= MaxExactTermsPerVariant)
            {
                for (var i = start; i < end && output.Count < maxVariants; i++)
                {
                    var term = vocabulary[i];
                    if (!FuzzyVocabulary.WithinOne(word, term)) continue;
                    if (seen.Add(term)) output.Add(Quote(term));
                }
                continue;
            }

            // 变体过短 / 过于常见：前缀匹配保留旧召回（否则要枚举上千词条）。
            var expression = Quote(variant) + "*";
            if (seen.Add(expression) && output.Count < maxVariants) output.Add(expression);
        }

        return output;
    }

    /* ------------------------------------------------------------------ */
    /* 工具                                                                */
    /* ------------------------------------------------------------------ */

    private static string? JoinBranches(List<string> branches, bool metadata)
    {
        if (branches.Count == 0) return null;
        var joined = string.Join(" OR ", branches);
        if (metadata)
        {
            // 列过滤必须作用于「整个」表达式——FTS5 中 `col : a AND b` 只过滤 `a`。
            return $"{{{MetadataColumns}}} : ({joined})";
        }
        return branches.Count == 1 ? joined : $"({joined})";
    }

    private static void Add(List<string> branches, string? branch)
    {
        if (branch is not null) branches.Add(branch);
    }

    private static List<string> Clean(IReadOnlyList<string> terms)
    {
        var clean = new List<string>(terms.Count);
        foreach (var term in terms)
        {
            var trimmed = term.Trim();
            if (trimmed.Length > 0) clean.Add(trimmed);
        }
        return clean;
    }

    private static string QuotedAnd(IReadOnlyList<string> terms, bool prefixLast)
    {
        var parts = new List<string>(terms.Count);
        for (var i = 0; i < terms.Count; i++)
        {
            var prefixed = i == terms.Count - 1 && prefixLast;
            parts.Add(prefixed ? PrefixTerm(terms[i]) : Quote(terms[i]));
        }
        return string.Join(" AND ", parts);
    }

    /// <summary>生成 <paramref name="word"/> 的编辑距离 ≤1 变体（含原词首位；去重保序）。</summary>
    private static List<string> EditDistanceOneVariants(string word)
    {
        var output = new List<string> { word };
        var seen = new HashSet<string>(StringComparer.Ordinal) { word };

        void Add(string candidate)
        {
            if (candidate.Length > 0 && seen.Add(candidate)) output.Add(candidate);
        }

        // 删除：去掉任一字符。
        for (var i = 0; i < word.Length; i++) Add(word.Remove(i, 1));
        // 相邻换位（跳过相同字符对）。
        for (var i = 0; i + 1 < word.Length; i++)
        {
            if (word[i] == word[i + 1]) continue;
            var chars = word.ToCharArray();
            (chars[i], chars[i + 1]) = (chars[i + 1], chars[i]);
            Add(new string(chars));
        }
        // 替换：逐位用受限候选替换。**首字符除外**（见 FirstCharTypoCostsTwo）。
        for (var i = FirstCharTypoCostsTwo ? 1 : 0; i < word.Length; i++)
        {
            if (!SubstitutionAlternatives.TryGetValue(word[i], out var alternatives)) continue;
            foreach (var ch in alternatives)
                Add(word.Substring(0, i) + ch + word.Substring(i + 1));
        }
        return output;
    }

    /// <summary>
    /// **首字符错误算 2 个错误**：本项目的模糊趟只有「编辑距离 ≤1」一档，
    /// 因此首字符不同的替换变体**直接不生成**（等价于把它推到 2 错档并放弃）。
    ///
    /// 理由：首字符错误往往意味着匹配到了一个**完全不同的词**——
    /// Meilisearch 为此专门把「首字符不同」的 1-错候选降级到 2-错档
    /// （<c>compute_derivations.rs:137-142</c>，注释原文
    /// 「in the case the typo is on the first letter, we know the number of typo is two」；
    /// 其 DFA 用 <c>Intersection(build_dfa(word,1), Complement(StartsWith(first_char)))</c>
    /// 表达，<c>:120-124</c>）。
    ///
    /// 注意只影响 <b>替换</b>：**删除**与**相邻换位**不改变词首，仍然保留
    /// （<c>hlelo → hello</c> 是换位、<c>helo → hello</c> 是删除，都属真实的输入错误）。
    /// 拼音模糊音（<c>zh/z</c>、<c>n/l</c>）走独立的 <c>PinyinFuzzyVariants</c>，不受影响——
    /// 那是**已知的方言混淆规则**，不是无方向的编辑距离。
    ///
    /// 参考：<c>docs/local-search-indexer-references.md</c> §3.4。
    ///
    /// **回退方式**：改为 <c>false</c> 即恢复「首字符也可替换」，无需重建索引。
    /// </summary>
    public static readonly bool FirstCharTypoCostsTwo = true;

    /// <summary>恰为两个子串脚本字符的词元（索引 / 查询侧 bigram 形态）。</summary>
    private static bool IsCjkBigram(string token)
    {
        var runes = token.EnumerateRunes().ToArray();
        return runes.Length == 2
            && runes.All(r => r.Value <= char.MaxValue && IsIndexedScript((char)r.Value));
    }

    /// <summary>
    /// 词元是否为**单个 CJK 字符**（汉字 / 假名 / 谚文）。
    ///
    /// 这类词元在 v14 起的索引里**不一定**作为独立 unigram 存在（只有段首 / 段末保留），
    /// 所以查询必须改走前缀 <c>字*</c>（精度审计 §17）。
    /// </summary>
    private static bool IsSingleCjkChar(string token)
    {
        var runes = token.EnumerateRunes().ToArray();
        return runes.Length == 1
            && runes[0].Value <= char.MaxValue
            && IsIndexedScript((char)runes[0].Value);
    }

    /// <summary>拉丁 / 数字词元可加前缀：不含子串脚本字符即为真。</summary>
    private static bool IsPrefixable(string token)
        => !token.EnumerateRunes().Any(r => r.Value <= char.MaxValue && IsIndexedScript((char)r.Value));

    /// <summary>
    /// 纯小写拉丁 / 数字词元且长度 ≥ <see cref="MinFuzzyWordLength"/>（可做编辑距离扩展）。
    ///
    /// 短词门控（精度审计 §6.2）：<c>ai</c> / <c>go</c> / <c>ye</c> 这类 2–3 字符词的
    /// ≤1 变体覆盖了太多高频短词，放宽收益远低于噪声成本。取 4 与 Typesense
    /// <c>min_len_1typo</c> 默认值一致。
    /// </summary>
    private static bool IsFuzzyEligible(string token)
    {
        if (token.Length < MinFuzzyWordLength) return false;
        foreach (var rune in token.EnumerateRunes())
        {
            var isLower = rune.Value >= 0x61 && rune.Value <= 0x7A;
            var isDigit = rune.Value >= 0x30 && rune.Value <= 0x39;
            if (!isLower && !isDigit) return false;
        }
        return true;
    }

    /// <summary>需要子串索引的脚本：汉字 + 假名 + 谚文（与 Dart <c>isIndexedScript</c> 一致）。</summary>
    private static bool IsIndexedScript(char c)
        => ScriptRanges.IsCjk(c) || ScriptRanges.IsSubstringScript(c);

    private static bool HasIndexedScript(string token)
        => token.EnumerateRunes().Any(r => r.Value <= char.MaxValue && IsIndexedScript((char)r.Value));

    /// <summary>取查询中的 CJK / 假名 / 谚文子序列（去其它字符，保序）。</summary>
    private static string CjkSubsequence(string query)
    {
        var buffer = new StringBuilder(query.Length);
        foreach (var ch in query)
        {
            if (IsIndexedScript(ch)) buffer.Append(ch);
        }
        return buffer.ToString();
    }
}
