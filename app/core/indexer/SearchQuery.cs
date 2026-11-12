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
        Add(branches, PinyinBranch(tokens.Pinyin));
        Add(branches, InitialsBranch(tokens.PinyinInitials));
        if (includeCrossLingual) Add(branches, CrossLingualBranch(tokens.CrossLingual));
        return JoinBranches(branches, metadata);
    }

    /// <summary>跨语言候选分支（T1）：候选逐字加引号后 OR；无候选返回 <c>null</c>。</summary>
    public static string? CompileCrossLingual(QueryTokens tokens, bool metadata)
    {
        var branch = CrossLingualBranch(tokens.CrossLingual);
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
    /// </summary>
    public static string? CompilePinyinLoose(QueryTokens tokens, bool metadata)
    {
        var clean = Clean(tokens.Pinyin);
        if (clean.Count < 2) return null;

        var chunks = new List<string>(clean.Count);
        for (var i = 0; i < clean.Count; i++)
        {
            var prefix = i == clean.Count - 1 && clean[i].Length >= MinPrefixTokenLength;
            var variants = PinyinFuzzyVariants(clean[i], MaxPinyinVariantsPerSyllable);
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
    /// 子序列长度 &lt;2 或 &gt;<see cref="MaxCjkQueryLength"/> 返回空。
    /// </summary>
    public static List<string> CjkVariants(string query, int maxVariants = DefaultMaxCjkVariants)
    {
        var sequence = CjkSubsequence(query);
        if (sequence.Length < 2 || sequence.Length > MaxCjkQueryLength) return new List<string>();

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

        var chunks = new List<string>();
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
                i = j;
            }
            else
            {
                chunks.Add(Quote(clean[i]));
                i++;
            }
        }

        var prefixLast = IsPrefixable(clean[^1]) && clean[^1].Length >= MinPrefixTokenLength;
        for (var k = 0; k < chunks.Count; k++)
        {
            if (k == chunks.Count - 1 && prefixLast) chunks[k] += "*";
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
        var body = QuotedAnd(terms, terms[^1].Length >= MinInitialsPrefixLength);
        // 整体加括号：列过滤与 OR 混排时边界更明确（列过滤只作用于本支）。
        // 注意多列过滤必须用**花括号**：FTS5 的 `a b : expr` 是「列 a 后接词元 b」，
        // 不是列集合，会静默返回空集（本分支因此从不命中）。
        return $"({{{InitialsColumns}}} : {body})";
    }

    private static string? CrossLingualBranch(IReadOnlyList<string> terms)
    {
        var clean = Clean(terms);
        if (clean.Count == 0) return null;
        return clean.Count == 1
            ? Quote(clean[0])
            : "(" + string.Join(" OR ", clean.Select(Quote)) + ")";
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
                // 词典确认该词元没有任何 Damerau ≤1 的真实词条：模糊趟不可能命中，整支放弃。
                return null;
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
            parts.Add(prefixed ? Quote(terms[i]) + "*" : Quote(terms[i]));
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
        // 替换：逐位用受限候选替换。
        for (var i = 0; i < word.Length; i++)
        {
            if (!SubstitutionAlternatives.TryGetValue(word[i], out var alternatives)) continue;
            foreach (var ch in alternatives)
                Add(word.Substring(0, i) + ch + word.Substring(i + 1));
        }
        return output;
    }

    /// <summary>恰为两个子串脚本字符的词元（索引 / 查询侧 bigram 形态）。</summary>
    private static bool IsCjkBigram(string token)
    {
        var runes = token.EnumerateRunes().ToArray();
        return runes.Length == 2
            && runes.All(r => r.Value <= char.MaxValue && IsIndexedScript((char)r.Value));
    }

    /// <summary>拉丁 / 数字词元可加前缀：不含子串脚本字符即为真。</summary>
    private static bool IsPrefixable(string token)
        => !token.EnumerateRunes().Any(r => r.Value <= char.MaxValue && IsIndexedScript((char)r.Value));

    /// <summary>纯小写拉丁 / 数字词元（可做编辑距离扩展）。</summary>
    private static bool IsFuzzyEligible(string token)
    {
        if (token.Length == 0) return false;
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
