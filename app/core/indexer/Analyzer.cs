// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

using System.Text;
using ToolGood.Words;

using Archoera.Text;

namespace Archoera.Indexer;

/// <summary>
/// 可检索字段（枚举序号为 C ABI 契约，P2 定案后不得变更）。
/// </summary>
public enum Field
{
    Title = 0,
    Artist = 1,
    Album = 2,
    LyricsOriginal = 3,
    LyricsTranslation = 4,
    LyricsRomaji = 5,
    Filename = 6,
}

/// <summary>索引侧分析结果（词元 / 全拼 / 首字母三列，均为空格分隔串）。</summary>
public sealed class AnalysisResult
{
    public string Tokens { get; }

    public string Pinyin { get; }

    /// <summary>
    /// 日文读音列（字母 bigram；见 <see cref="Japanese.ReadingBigrams"/>）。
    /// 仅当该源含假名、或调用方标记整首为日文（<c>includeReadings</c>）时非空——
    /// 纯中文曲库不产出，既不增体积也无跨语言噪声。
    /// </summary>
    public string Readings { get; }

    public string PinyinInitials { get; }

    public AnalysisResult(string tokens, string pinyin, string pinyinInitials, string readings)
    {
        Tokens = tokens;
        Pinyin = pinyin;
        PinyinInitials = pinyinInitials;
        Readings = readings;
    }
}

/// <summary>查询侧结构化词元（供调用方按需拼 FTS5 表达式 / 前缀 / 短语）。</summary>
public sealed class QueryTokens
{
    public List<string> Lexical { get; } = new();

    public List<string> Pinyin { get; } = new();

    /// <summary>首字母串；文本不含 CJK 时为 <c>null</c>。</summary>
    public string? PinyinInitials { get; internal set; }

    /// <summary>
    /// 跨语言候选（**仅查询侧**，T1）：由 Unihan 释义扩展表（<c>def_en2hanzi</c> /
    /// <c>def_hanzi2en</c>）派生——拉丁/数字词元 → 候选汉字；CJK 段内的字 → 英文释义词。
    /// 合并去重后总预算 ≤ <see cref="Analyzer.CrossLingualBudget"/>（超出截断）。
    /// 索引侧不使用此列（T1 不重建索引）。
    /// </summary>
    public List<string> CrossLingual { get; } = new();
}

/// <summary>
/// 本地曲库搜索分析器（核心，索引侧 / 查询侧同构）。
///
/// 链：NFKC（逐字符兼容折叠）→ 小写 → 繁转简 → 脚本切分 → 分词
/// （CJK bigram+unigram / 拉丁·数字整词）→ 派生列（全拼 / 首字母）。
/// 语义与设计文档 <c>docs/local-search-index-plan.md</c> §4 一致，
/// <see cref="AnalyzerVersion"/> 作为 schema/analyzer 版本锚点（变更即触发全量重建）。
///
/// 同步、无 IO、无可变静态状态（除惰性数据表），可安全并发调用。
/// </summary>
public static class Analyzer
{
    /// <summary>
    /// 分析器语义版本；任何影响词元输出的变更都必须递增。
    ///
    /// v2：归一化由手写全角折叠升级为**逐字符 NFKC 兼容折叠**（<c>data/nfkc.tsv</c>）——
    /// <c>ﬁ</c>→<c>fi</c>、<c>①</c>→<c>1</c>、兼容表意字折叠等改变词元输出，故递增触发全量重建。
    /// v3：NFKC 表扩展至**全范围**（新增非 BMP / 星平面兼容字符，如数学字母 <c>𝑨</c>→<c>A</c>、
    /// <c>𝟎</c>→<c>0</c>），折叠改为 **rune 遍历**；含非 BMP 字符时词元输出变化，故递增触发全量重建。
    /// v4：拼音 / 繁简 / 全角收敛到 <c>ToolGood.Words</c>（Apache-2.0），GB18030 解码改用框架
    /// <c>CodePagesEncodingProvider</c>，删除自带数据表与英文阻断表。拼音改为**按 CJK 段词级消歧**
    /// （<c>重庆→chong qing</c>、<c>银行→yin hang</c>），繁转简改用 ToolGood 词库，输出与旧表存在
    /// 可达差异，故递增触发全量重建。
    /// v5：**索引内容变化**——<c>LyricsTrTok</c> / <c>LyricsRomTok</c> 不再留空，改由
    /// <see cref="LrcReader"/> 从内嵌歌词 / <c>.lrc</c> 拆分出译文 / 音译层并分别分析入库
    /// （T0 多语言层入库）。译文 / 音译层此前恒空，现被填充，输出变化，故递增触发全量重建。
    /// （T1 的查询侧跨语言候选只改 <see cref="AnalyzeQuery"/>，不影响索引侧词元输出。）
    /// v7：**读音列变化**（T1-1 罗马音规范形）——读音 bigram 由 Hepburn 折叠为规范形
    /// （<c>sh→s</c> / <c>ch→t</c> / <c>ts→t</c> / <c>fu→hu</c> / <c>j→z</c>、促音与长音折叠、
    /// <c>ん</c>+元音→<c>nn</c>+元音），输出变化，故递增触发全量重建。
    /// v8：**助词双写**（T1-2）——<c>は</c> 增加 <c>wa</c>、<c>へ</c> 增加 <c>e</c> 备选拼写
    /// （<c>を</c> 原有 <c>o/wo</c>），修复局部窗口变体未生效的问题，读音列输出变化。
    /// v9：**韩文读音列**（T1-3）——谚文经国语罗马字写入 <c>reading_meta_tok</c>，
    /// 纯韩文曲目从「读音列为空」变为有值，输出变化，故递增触发全量重建。
    /// v10：**去音符号折叠**（T1-5）——<c>é / ü / ñ / ā</c> 等预组合拉丁字母折叠为 ASCII
    /// 基字母，组合音标丢弃；含重音字母的曲目（如 <c>Beyoncé</c>）词元由带音符号变为无音符号，
    /// 输出变化，故递增触发全量重建。
    /// v11：**异体字补齐**（T1-7）——Unihan <c>kSimplifiedVariant</c> 补齐 ToolGood 未覆盖的
    /// 日文新字体（鉄→铁、絵→绘、円→圆…）；含新字体的曲目词元变化，故递增触发全量重建。
    /// </summary>
    public const int AnalyzerVersion = 11;

    /// <summary>查询侧跨语言候选（<see cref="QueryTokens.CrossLingual"/>）合并去重后的总预算。</summary>
    public const int CrossLingualBudget = 32;

    private enum ScriptKind
    {
        None,
        Cjk,

        /// <summary>
        /// 需要子串索引的脚本（假名 / 谚文，见 <see cref="ScriptRanges.IsSubstringScript"/>）：
        /// 与 CJK 同样 <c>bigram + unigram</c> 入索引，但**不进拼音 / 首字母列**
        /// （假名 / 谚文没有拼音读音，镜像只会是噪声与体积；实测假名占真实歌词 9.6%）。
        /// </summary>
        Substring,
        Latin,
        Digit,
    }

    private readonly record struct Segment(ScriptKind Kind, string Text);

    /// <summary>
    /// 汉字判定：CJK 统一表意主区（U+4E00–U+9FFF）+ 扩展 A（U+3400–U+4DBF）
    /// + 兼容表意区（U+F900–U+FAFF）。
    /// 注意：BMP 之外（扩展 B 起）为代理对，本 API 基于 <see cref="char"/>，不覆盖（见报告风险项）。
    /// </summary>
    public static bool IsCjk(char c) => ScriptRanges.IsCjk(c);

    /// <summary>
    /// 索引侧分析：归一化 + 分词 + 拼音列 + 日文读音列。
    ///
    /// [includeReadings] 为真表示调用方判定**整首曲目是日文**（任一源含假名）——此时连
    /// 纯汉字段（如纯汉字歌手名 米津玄師）也查 Unihan 读音表；为假时只有含假名的源才产出读音。
    /// </summary>
    public static AnalysisResult Analyze(string text, bool includeReadings = false)
    {
        var parts = AnalyzeCore(text);
        return new AnalysisResult(
            string.Join(' ', parts.Tokens),
            string.Join(' ', parts.Pinyin),
            string.Join(' ', parts.Initials),
            Japanese.ReadingBigrams(text, includeReadings));
    }

    /// <summary>
    /// 查询侧分析：与索引侧同构，返回结构化词元列表。
    ///
    /// 与索引侧的唯一差异在 <see cref="QueryTokens.Pinyin"/>：对**每个**拼音词元尝试
    /// 连写全拼切分（P4，设计文档 §4.2）——<c>woaini</c> → <c>wo ai ni</c>、
    /// <c>woai</c> → <c>wo ai</c>；CJK 逐字主读音本身即单音节，切分为幂等；
    /// 英文词（<c>hello</c>）无法完整覆盖时保持原整词，即使可完整覆盖也受
    /// <see cref="PinyinSegmenter"/> 的英文过度切分门控约束（<c>banana</c> /
    /// <c>adele</c> 等不再切分）。
    /// </summary>
    public static QueryTokens AnalyzeQuery(string text)
    {
        var parts = AnalyzeCore(text);
        var query = new QueryTokens();
        query.Lexical.AddRange(parts.Tokens);

        var buffer = new List<string>();
        foreach (var token in parts.Pinyin)
        {
            if (PinyinSegmenter.TrySegment(token, buffer)) query.Pinyin.AddRange(buffer);
            else query.Pinyin.Add(token);
        }

        query.PinyinInitials = parts.HasCjk ? string.Join(' ', parts.Initials) : null;
        query.CrossLingual.AddRange(CollectCrossLingual(text));
        RemovePinyinCollisions(query);
        return query;
    }

    /// <summary>
    /// 去噪：Unihan 释义里的罗马化专名（如 <c>周</c> → “Zhou dynasty” 的 <c>zhou</c>）会与
    /// 查询自身拼音音节**同形**——该串已由拼音分支覆盖（且拉丁词元本就同时进入拼音列），
    /// 保留只会引入与拼音层重复的噪声命中（如 <c>周杰美</c> 误命中 <c>周杰伦</c> 的拼音）。
    /// 故丢弃与查询拼音音节逐字相同的候选（保序，仅删重复项）。
    /// </summary>
    private static void RemovePinyinCollisions(QueryTokens query)
    {
        if (query.CrossLingual.Count == 0 || query.Pinyin.Count == 0) return;
        var pinyin = new HashSet<string>(query.Pinyin, StringComparer.Ordinal);
        query.CrossLingual.RemoveAll(pinyin.Contains);
    }

    /// <summary>
    /// 查询侧跨语言候选（T1，Unihan 释义扩展；**不改索引侧**）。
    ///
    /// 规则（合并去重、保序、总预算 ≤ <see cref="CrossLingualBudget"/>，超出截断）：
    /// <list type="bullet">
    ///   <item>拉丁 / 数字段 → <c>def_en2hanzi</c> 查该整词，取候选汉字**码点**转为字符
    ///         （每词生成表侧已 ≤ 8）；</item>
    ///   <item>CJK 段内的每个字 → <c>def_hanzi2en</c> 查该字码点，取英文释义词。</item>
    /// </list>
    /// 拉丁候选优先于 CJK 候选（按分段出现顺序），二者汇入同一预算池。
    /// 输入经 <see cref="Normalize"/>（NFKC + 小写 + 繁转简）后按脚本切分，与索引侧同源。
    /// </summary>
    private static List<string> CollectCrossLingual(string text)
    {
        var result = new List<string>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        if (string.IsNullOrEmpty(text)) return result;

        void Add(string term)
        {
            if (result.Count >= CrossLingualBudget) return;
            if (term.Length == 0 || !seen.Add(term)) return;
            result.Add(term);
        }

        foreach (var segment in SplitSegments(Normalize(text)))
        {
            if (segment.Kind == ScriptKind.Cjk)
            {
                foreach (var ch in segment.Text)
                {
                    if (!HanziData.TryGetGlossWords(ch, out var words)) continue;
                    foreach (var word in words) Add(word);
                }
            }
            else
            {
                if (!HanziData.TryGetGlossHanzi(segment.Text, out var codes)) continue;
                foreach (var cp in codes)
                {
                    if (cp >= 0 && cp <= 0x10FFFF && (cp < 0xD800 || cp > 0xDFFF))
                        Add(char.ConvertFromUtf32(cp));
                }
            }
        }
        return result;
    }

    private sealed class Parts
    {
        public readonly List<string> Tokens = new();
        public readonly List<string> Pinyin = new();
        public readonly List<string> Initials = new();
        public bool HasCjk;
    }

    private static Parts AnalyzeCore(string text)
    {
        var parts = new Parts();
        if (string.IsNullOrEmpty(text)) return parts;

        foreach (var segment in SplitSegments(Normalize(text)))
        {
            if (segment.Kind == ScriptKind.Cjk)
            {
                parts.HasCjk = true;
                AddCjkSegment(segment.Text, parts);
            }
            else if (segment.Kind == ScriptKind.Substring)
            {
                // 假名 / 谚文：只做子串索引（bigram + unigram），不进拼音 / 首字母列。
                AddSubstringSegment(segment.Text, parts);
            }
            else
            {
                // 拉丁 / 数字段：整词原样进入三列。
                parts.Tokens.Add(segment.Text);
                parts.Pinyin.Add(segment.Text);
                parts.Initials.Add(segment.Text);
            }
        }
        return parts;
    }

    /// <summary>
    /// CJK 段分词：先按序输出 bigram（相邻二字，位置连续便于短语），再输出 unigram
    /// （保证单字查询命中）；拼音列按**整段**词级消歧取音节，首字母列合并为一个 token。
    /// </summary>
    private static void AddCjkSegment(string segment, Parts parts)
    {
        if (segment.Length >= 2)
        {
            for (int i = 0; i + 1 < segment.Length; i++)
                parts.Tokens.Add(segment.Substring(i, 2));
        }
        foreach (var ch in segment)
            parts.Tokens.Add(ch.ToString());

        // 整段一次性过 ToolGood：词级多音字消歧（重庆→chong qing）。
        parts.Pinyin.AddRange(Pinyin.FromCjkRun(segment));
        var initials = Pinyin.Initials(segment);
        if (initials.Length > 0) parts.Initials.Add(initials);
    }

    /// <summary>
    /// 假名 / 谚文段分词：<c>bigram + unigram</c>（与 CJK 同构，故子串 / 前缀 / 词组查询都能命中），
    /// **不产出拼音 / 首字母**。
    ///
    /// 旧实现把假名 / 谚文归入「拉丁」分支 → 整段一个 token，子串查询必然落空
    /// （真实库实测：`くらりん` ⊂ `きゅうくらりん`，命中 0）。N-gram 取 2 与汉字一致，
    /// 查询侧同一套 <c>bigram</c> 组合即可（见 Dart <c>_isCjkBigram</c> 的对应实现）。
    /// </summary>
    private static void AddSubstringSegment(string segment, Parts parts)
    {
        if (segment.Length >= 2)
        {
            for (int i = 0; i + 1 < segment.Length; i++)
                parts.Tokens.Add(segment.Substring(i, 2));
        }
        foreach (var ch in segment)
            parts.Tokens.Add(ch.ToString());
    }

    /// <summary>
    /// 逐字符 NFKC 兼容折叠 → **拉丁去音符号折叠** → **异体字补齐（日文新字体 → 简体）**
    /// → 小写 → 繁转简（ToolGood.Words 词库）；
    /// 标点/空白留待 <see cref="SplitSegments"/> 作分隔符丢弃。
    ///
    /// 注意：本程序集以 <c>InvariantGlobalization=true</c> 构建（无 ICU），此时
    /// <c>string.Normalize(NormalizationForm.FormKC)</c> 为**空操作**（其表来自 ICU）。
    /// 故这里以离线表 <c>data/nfkc.tsv</c>（Python <c>unicodedata</c> NFKC）为**唯一事实来源**，
    /// 逐字符做兼容折叠（<c>ﬁ</c>→<c>fi</c>、<c>①</c>→<c>1</c>、全角→半角、兼容表意字→统一表意字、
    /// 数学字母 / 星平面兼容字符→ASCII 等）；未命中保持原字符。
    /// 结果与全球化是否可用无关，索引 / 查询两侧确定一致。
    ///
    /// 折叠以 <see cref="Rune"/>（码点）为单位遍历：非 BMP 码点直接查表替换，避免把代理对拆散；
    /// <see cref="string.EnumerateRunes"/> 遇非法 UTF-16（孤立代理）返回替换字符 <c>U+FFFD</c>，
    /// 不会产生非法代理对、不崩溃。
    ///
    /// 繁转简改用 <c>ToolGood.Words.ToSimplifiedChinese</c>（Apache-2.0）：一次对整串调用
    /// （词级、非逐字），取代原先的 <c>data/simp_trad.tsv</c> 查表。
    ///
    /// **去音符号折叠**（T1-5）：NFKC 只做兼容分解 + 规范合成，重音字母（<c>é</c> / <c>ü</c> /
    /// <c>ñ</c>）折叠后仍是原字符。这里在 NFKC 之后再过一遍 <c>data/accent_fold.tsv</c>
    /// （NFD 派生的「预组合字母 → ASCII 基字母」表），并丢弃组合音标码点，
    /// 使 <c>Beyoncé</c> 与 <c>Beyonce</c>（含分解形 <c>e</c>+U+0301）同形。索引 / 查询两侧
    /// 走同一函数，故不需要额外的查询侧变体。ł / ø / đ / ß 等无规范分解的字母保持原样。
    ///
    /// **异体字补齐**（T1-7）：<c>data/variant_fold.tsv</c> 由 Unihan <c>kSimplifiedVariant</c>
    /// 派生（日文新字体经 <c>kJapaneseOldVariant</c> 串联：鉄→鐵→铁、絵→繪→绘、円→圓→圆），
    /// 只补 ToolGood 繁简词库未覆盖的字符，故不改变既有中文繁简规则。
    /// 索引 / 查询同表，搜「银河铁道」可命中「銀河鉄道の夜」。
    ///
    /// 近似：NFKC 表**仅逐字符应用**——跨字符规范化组合（如 base + combining 合成）不做，
    /// 这与 NFKC 完整语义存在已知偏差（见 <c>tools/gen_hanzi_data.py</c> 与报告）。
    /// </summary>
    private static string Normalize(string text)
    {
        if (text.Length == 0) return text;
        var compat = new StringBuilder(text.Length);
        foreach (var rune in text.EnumerateRunes())
        {
            if (HanziData.TryGetCompatibilityFolded(rune.Value, out var replacement))
                compat.Append(replacement);
            else
                compat.Append(rune.ToString());
        }

        // 兼容折叠可能产出多个字符（如 Ⅻ → xii），故去重音 / 异体补齐需重新遍历一遍。
        var folded = new StringBuilder(compat.Length);
        foreach (var rune in compat.ToString().EnumerateRunes())
        {
            if (HanziData.IsCombiningDiacritic(rune.Value)) continue;
            if (HanziData.TryGetAccentFolded(rune.Value, out var baseLetter))
                folded.Append(baseLetter);
            else if (HanziData.TryGetVariantFolded(rune.Value, out var simplified))
                folded.Append(simplified);
            else
                folded.Append(rune.ToString());
        }

        return WordsHelper.ToSimplifiedChinese(folded.ToString().ToLowerInvariant(), 0);
    }

    /// <summary>脚本切分：连续 CJK / 连续拉丁 / 连续数字各成段；其余（标点等）丢弃并断段。</summary>
    private static List<Segment> SplitSegments(string text)
    {
        var segments = new List<Segment>();
        var builder = new StringBuilder();
        var kind = ScriptKind.None;

        void Flush()
        {
            if (builder.Length == 0) return;
            segments.Add(new Segment(kind, builder.ToString()));
            builder.Clear();
            kind = ScriptKind.None;
        }

        foreach (var ch in text)
        {
            var current = Classify(ch);
            if (current == ScriptKind.None)
            {
                Flush();
                continue;
            }
            if (current != kind) Flush();
            kind = current;
            builder.Append(ch);
        }
        Flush();
        return segments;
    }

    private static ScriptKind Classify(char c)
    {
        if (IsCjk(c)) return ScriptKind.Cjk;
        if (ScriptRanges.IsSubstringScript(c)) return ScriptKind.Substring;
        if (char.IsDigit(c)) return ScriptKind.Digit;
        if (char.IsLetter(c)) return ScriptKind.Latin;
        return ScriptKind.None;
    }
}
