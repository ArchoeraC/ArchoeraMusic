// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

using System.Globalization;
using System.Text;

namespace Archoera.Indexer;

/// <summary>
/// 内嵌 Unicode NFKC 兼容折叠表（<c>data/nfkc.tsv</c>）的加载与查询。
///
/// 表由 <c>tools/gen_hanzi_data.py</c> 离线生成，以 <c>EmbeddedResource</c> 编入程序集
/// （csproj 内固定 <c>LogicalName</c>，无动态反射），NativeAOT 安全。
/// 仅在首次访问时惰性加载一次并缓存为字典；线程安全性由 <see cref="Lazy{T}"/> 保证。
///
/// 拼音 / 繁简 / 全角与 GB18030 解码已收敛到外部库与框架：
/// <list type="bullet">
///   <item>拼音（含词级多音字消歧）与繁转简、全角半角 → <c>ToolGood.Words</c>（Apache-2.0，
///         <see cref="Pinyin"/> / <see cref="Analyzer"/> 调用），不再内嵌数据表；</item>
///   <item>GB18030 / GBK 解码 → .NET 框架内置 <c>CodePagesEncodingProvider</c>
///         （<see cref="LrcReader"/> 调用），不再内嵌双字节表。</item>
/// </list>
/// 本类因此只保留 NFKC 兼容折叠（ToolGood 不折叠 <c>ﬁ</c> / <c>①</c> 等兼容字）
/// 与查询侧 Unihan 释义扩展表。
///
/// 表格式：<c>HEXCODE&lt;TAB&gt;HEXOUT1 HEXOUT2 …</c>（输入 / 输出均为码点十六进制，
/// <c>#</c> 开头为注释行，解析时跳过）。
///
/// 另含 **Unihan 释义查询扩展** 双向表（T1，仅查询侧使用，不改索引侧）：
/// <list type="bullet">
///   <item><c>def_en2hanzi.tsv</c>：<c>WORD&lt;TAB&gt;HEX1 HEX2 …</c>（英文词 → 候选汉字码点）；</item>
///   <item><c>def_hanzi2en.tsv</c>：<c>HEXCODE&lt;TAB&gt;WORD1 WORD2 …</c>（汉字码点 → 英文词）。</item>
/// </list>
/// 供 <see cref="Analyzer.AnalyzeQuery"/> 生成跨语言候选分支（英文查询召回含对应汉字的内容，
/// 反之亦然）。同一份 <c>Lazy</c> 惰性加载、只读缓存、线程安全。
/// </summary>
internal static class HanziData
{
    private const string CompatibilityResource = "Archoera.Indexer.data.nfkc.tsv";
    private const string GlossEnToHanziResource = "Archoera.Indexer.data.def_en2hanzi.tsv";
    private const string GlossHanziToEnResource = "Archoera.Indexer.data.def_hanzi2en.tsv";

    /// <summary>
    /// 逐字符 NFKC 兼容折叠表（全范围，含非 BMP）：码点 → 已解码的折叠结果字符串。
    /// 由 <c>tools/gen_hanzi_data.py</c> 以 Python <c>unicodedata</c> 离线生成（逐字符）。
    /// </summary>
    private static readonly Lazy<Dictionary<int, string>> CompatibilityTable =
        new(static () => LoadCodePoints(CompatibilityResource));

    /// <summary>英文词 → 候选汉字**码点**列表（Unihan kDefinition，T1 查询侧）。</summary>
    private static readonly Lazy<Dictionary<string, IReadOnlyList<int>>> GlossEnToHanziTable =
        new(static () => LoadGlossCodes(GlossEnToHanziResource));

    /// <summary>汉字**码点** → 英文词列表（Unihan kDefinition，T1 查询侧）。</summary>
    private static readonly Lazy<Dictionary<int, IReadOnlyList<string>>> GlossHanziToEnTable =
        new(static () => LoadGlossWords(GlossHanziToEnResource));

    /// <summary>
    /// 逐字符 NFKC 兼容折叠查表：命中时经 <paramref name="folded"/> 回传折叠结果
    /// （可能多字符、甚至非 BMP）；未命中（或已是 NFKC 形）返回 <c>false</c>，
    /// 调用方应保持原码点。表**逐字符应用**——跨字符规范化组合（base + combining 合成）
    /// 不在此表范围，由调用方（<see cref="Analyzer"/>）在注释中声明为已知近似。
    /// </summary>
    public static bool TryGetCompatibilityFolded(int codePoint, out string folded)
        => CompatibilityTable.Value.TryGetValue(codePoint, out folded!);

    /// <summary>NFKC 兼容折叠表条目数（诊断用；触发加载）。</summary>
    public static int CompatibilityEntryCount => CompatibilityTable.Value.Count;

    /// <summary>
    /// Unihan 释义查询扩展（英文 → 候选汉字码点）：命中时经 <paramref name="codes"/> 回传
    /// 该词的候选汉字**码点**（去重、主区优先 + 码点升序、每词 ≤ 8）；未命中返回 <c>false</c>。
    /// 仅查询侧（<see cref="Analyzer.AnalyzeQuery"/>）使用，索引侧不调用（T1 不重建索引）。
    /// </summary>
    public static bool TryGetGlossHanzi(string word, out IReadOnlyList<int> codes)
    {
        codes = Array.Empty<int>();
        return !string.IsNullOrEmpty(word) && GlossEnToHanziTable.Value.TryGetValue(word, out codes!);
    }

    /// <summary>
    /// Unihan 释义查询扩展（汉字码点 → 英文词）：命中时经 <paramref name="words"/> 回传
    /// 该字的英文释义词（去重、字典序）；未命中返回 <c>false</c>。仅查询侧使用。
    /// </summary>
    public static bool TryGetGlossWords(int code, out IReadOnlyList<string> words)
        => GlossHanziToEnTable.Value.TryGetValue(code, out words!);

    /// <summary>释义扩展表条目数（诊断用；触发加载）。</summary>
    public static int GlossHanziToEnEntryCount => GlossHanziToEnTable.Value.Count;

    /// <summary>加载 <c>WORD&lt;TAB&gt;HEX1 HEX2 …</c> 表：值为候选**码点**列表。</summary>
    private static Dictionary<string, IReadOnlyList<int>> LoadGlossCodes(string resource)
    {
        var map = new Dictionary<string, IReadOnlyList<int>>(StringComparer.Ordinal);
        foreach (var (key, value) in ReadStringRows(resource))
        {
            var codes = new List<int>();
            foreach (var part in value.Split(' ', StringSplitOptions.RemoveEmptyEntries))
            {
                if (int.TryParse(part, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var cp))
                    codes.Add(cp);
            }
            if (codes.Count > 0) map[key] = codes;
        }
        return map;
    }

    /// <summary>加载 <c>HEXCODE&lt;TAB&gt;WORD1 WORD2 …</c> 表：值为英文词列表。</summary>
    private static Dictionary<int, IReadOnlyList<string>> LoadGlossWords(string resource)
    {
        var map = new Dictionary<int, IReadOnlyList<string>>();
        foreach (var (key, value) in ReadRows(resource))
        {
            var words = value.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (words.Length > 0) map[key] = words;
        }
        return map;
    }

    /// <summary>加载 <c>HEXCODE&lt;TAB&gt;HEXOUT1 HEXOUT2 …</c> 表：值为**码点**序列解码后的字符串
    /// （可含非 BMP，如映射到星平面的数学字母）。</summary>
    private static Dictionary<int, string> LoadCodePoints(string resource)
    {
        var map = new Dictionary<int, string>();
        foreach (var (key, value) in ReadRows(resource))
        {
            var text = DecodeCodePoints(value);
            if (text.Length > 0) map[key] = text;
        }
        return map;
    }

    /// <summary>空格分隔的十六进制**码点** → 字符串；跳过代理区 / 越界值，非 BMP 以代理对编码。</summary>
    private static string DecodeCodePoints(string value)
    {
        var builder = new StringBuilder(value.Length / 4);
        foreach (var part in value.Split(' ', StringSplitOptions.RemoveEmptyEntries))
        {
            if (int.TryParse(part, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var cp)
                && cp >= 0 && cp <= 0x10FFFF && (cp < 0xD800 || cp > 0xDFFF))
            {
                builder.Append(char.ConvertFromUtf32(cp));
            }
        }
        return builder.ToString();
    }

    /// <summary>逐行解析 <c>HEXCODE&lt;TAB&gt;VALUE</c>；跳过注释/空行/畸形行。</summary>
    private static IEnumerable<(int Key, string Value)> ReadRows(string resource)
    {
        using var stream = OpenResource(resource);
        using var reader = new StreamReader(stream, Encoding.UTF8);
        string? line;
        while ((line = reader.ReadLine()) is not null)
        {
            if (line.Length == 0 || line[0] == '#') continue;
            var tab = line.IndexOf('\t');
            if (tab <= 0 || tab == line.Length - 1) continue;
            if (!int.TryParse(line.AsSpan(0, tab), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var key))
                continue;
            yield return (key, line[(tab + 1)..]);
        }
    }

    /// <summary>逐行解析 <c>KEY&lt;TAB&gt;VALUE</c>（KEY 为**字符串**英文词）；跳过注释/空行/畸形行。</summary>
    private static IEnumerable<(string Key, string Value)> ReadStringRows(string resource)
    {
        using var stream = OpenResource(resource);
        using var reader = new StreamReader(stream, Encoding.UTF8);
        string? line;
        while ((line = reader.ReadLine()) is not null)
        {
            if (line.Length == 0 || line[0] == '#') continue;
            var tab = line.IndexOf('\t');
            if (tab <= 0 || tab == line.Length - 1) continue;
            yield return (line[..tab], line[(tab + 1)..]);
        }
    }

    private static Stream OpenResource(string name)
    {
        var stream = typeof(HanziData).Assembly.GetManifestResourceStream(name);
        return stream ?? throw new InvalidOperationException($"内嵌数据表缺失: {name}");
    }
}
