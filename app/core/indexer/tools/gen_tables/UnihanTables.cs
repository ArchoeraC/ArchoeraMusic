// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// 索引器构建期数据表生成：NFKC 折叠 / 日文读音 / Unihan 释义三张表。
//
// 从原 `tools/gen_hanzi_data.py` 迁移而来（跨语言计划 §4.3 硬性门禁：
// 构建期工具链收敛到 .NET 一套，`python3` 从构建依赖中删除）。
//
// 迁移要求（§4.3 第 4 条）：**逐字节复现**既有 TSV，否则会被误判为词元变化而
// 触发用户侧全量重建。校对方式见 `tools/verify_tables.sh`。
//
// 许可：三张表均派生自 Unicode（Unicode License），详见 THIRD-PARTY-LICENSES.md。

using System.Globalization;
using System.Text;

namespace Archoera.Indexer.Tools;

/// <summary>NFKC / 日文读音 / Unihan 释义表的构建期生成器（纯 .NET，无 Python 依赖）。</summary>
internal static class UnihanTables
{
    /// <summary>解析 <c>U+XXXX</c> 形式的码点（构建期工具内自足，不依赖 Program 的本地函数）。</summary>
    private static bool TryParseCodePoint(string text, out int codePoint)
    {
        codePoint = 0;
        var span = text.AsSpan().Trim();
        if (span.Length < 3 || span[0] != 'U' || span[1] != '+') return false;
        return int.TryParse(span[2..], NumberStyles.HexNumber, CultureInfo.InvariantCulture, out codePoint);
    }

public static List<(int CodePoint, string Folded)> BuildNfkcRows()
{
    var rows = new List<(int, string)>();
    for (var cp = 0; cp < 0x110000; cp++)
    {
        if (cp >= 0xD800 && cp <= 0xDFFF) continue; // 代理区不构成独立字符
        var text = char.ConvertFromUtf32(cp);
        // 归一结果含控制符 / TAB / 换行 → 跳过（保持原字符，保证单行可解析）。
        var bad = false;
        foreach (var ch in text)
        {
            if (ch < 0x20 || ch == '\t' || ch == '\n' || ch == '\r') { bad = true; break; }
        }
        if (bad) continue;

        // .NET 的规范化 API 会拒绝含非法 Unicode 码点（如 NUL）的输入，
        // 而 Python 的 unicodedata 照常返回原字符；两者对控制字符的处理因此等价于
        // 「原样保留」，但必须在调用前拦掉，否则整轮生成直接抛异常。
        string folded;
        try
        {
            folded = text.Normalize(NormalizationForm.FormKC);
        }
        catch (ArgumentException)
        {
            continue;
        }
        if (folded == text) continue;
        var codes = string.Join(' ', folded.EnumerateRunes()
            .Select(r => r.Value.ToString("X4", CultureInfo.InvariantCulture)));
        rows.Add((cp, codes));
    }
    return rows;
}

public static void WriteNfkcTable(string output, List<(int CodePoint, string Folded)> rows)
{
    var builder = new StringBuilder();
    builder.AppendLine("# Archoera indexer 逐字符 NFKC 兼容折叠表（生成，勿手改）");
    builder.AppendLine("# 来源: Unicode NFKC 规范分解 + 组合（FormKC）");
    builder.AppendLine("# 字段: HEXCODE<TAB>HEXOUT1 HEXOUT2 ...；输入/输出均为码点十六进制、空格分隔");
    builder.AppendLine("# 生成: tools/gen_tables（cd app/core/indexer && dotnet run --project tools/gen_tables）");
    builder.AppendLine("# 近似: 逐字符应用；跨字符规范化组合（base+combining 合成）不覆盖");
    builder.AppendLine("# 跳过: 代理区 U+D800..U+DFFF；归一结果含控制符 / TAB / 换行 的码点");
    foreach (var (cp, folded) in rows)
    {
        builder.Append(cp.ToString("X4", CultureInfo.InvariantCulture));
        builder.Append('\t');
        builder.Append(folded);
        builder.AppendLine();
    }
    File.WriteAllText(output, builder.ToString(), new UTF8Encoding(false));
    Console.WriteLine($"nfkc.tsv         : {rows.Count} 条 -> {output}");
}

public static List<(int CodePoint, string Readings)> BuildJapaneseReadingRows(string zipPath)
{
    if (!File.Exists(zipPath))
        throw new FileNotFoundException($"缺少 Unihan 数据：{Path.GetFullPath(zipPath)}", zipPath);

    var readings = new SortedDictionary<int, List<string>>();
    foreach (var (cp, tag, value) in ReadUnihanRows(zipPath, "Unihan_Readings.txt"))
    {
        if (tag != "kJapanese") continue;
        if (!IsIndexerHanziRange(cp)) continue;
        var kana = CleanJapaneseReading(value);
        if (kana.Count == 0) continue;
        if (!readings.TryGetValue(cp, out var slot))
        {
            slot = new List<string>();
            readings[cp] = slot;
        }
        foreach (var k in kana)
        {
            if (!slot.Contains(k, StringComparer.Ordinal)) slot.Add(k);
        }
    }
    return readings.Select(kv => (kv.Key, string.Join(' ', kv.Value))).ToList();
}

/// <summary>Unihan <c>kJapanese</c> 值 → 有序假名读音（去送假名标记 <c>.</c> / <c>-</c>，去重保序）。</summary>
public static List<string> CleanJapaneseReading(string value)
{
    var output = new List<string>();
    var seen = new HashSet<string>(StringComparer.Ordinal);
    foreach (var raw in value.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))
    {
        var kana = raw.Replace(".", "", StringComparison.Ordinal)
                      .Replace("-", "", StringComparison.Ordinal);
        if (kana.Length == 0 || !seen.Add(kana)) continue;
        output.Add(kana);
    }
    return output;
}

public static void WriteJapaneseReadingsTable(string output, List<(int CodePoint, string Readings)> rows)
{
    var builder = new StringBuilder();
    builder.AppendLine("# Archoera indexer 日文读音表（生成，勿手改）：汉字码点 → 假名读音（音读 / 训读）");
    builder.AppendLine("# 来源: Unicode Unihan kJapanese（Unicode License，https://www.unicode.org/license.txt）");
    builder.AppendLine("# 字段: HEXCODE<TAB>KANA1 KANA2 ...（假名原样；送假名标记 . / - 已去）");
    builder.AppendLine("# 生成: tools/gen_tables（确定、可重跑）");
    builder.AppendLine("# 用途: 索引期把读音转罗马字写入 reading_* 列（运行时用 data/kana_romaji.tsv 转换）");
    builder.AppendLine("# 范围: 仅 CJK 统一表意主区 + 扩展 A + 兼容表意区（与索引侧汉字范围一致）");
    foreach (var (cp, kana) in rows)
    {
        builder.Append(cp.ToString("X4", CultureInfo.InvariantCulture));
        builder.Append('\t');
        builder.Append(kana);
        builder.AppendLine();
    }
    File.WriteAllText(output, builder.ToString(), new UTF8Encoding(false));
    Console.WriteLine($"ja_readings.tsv  : {rows.Count} 字 -> {output}");
}

/// <summary>英文停用词（与 Python 版 <c>STOPWORDS</c> 逐项一致）。</summary>
private static readonly HashSet<string> GlossStopwords = new(StringComparer.Ordinal)
{
    "a", "an", "the", "this", "that", "these", "those",
    "of", "to", "and", "or", "but", "nor", "so", "as", "at", "by", "for", "from", "in",
    "into", "onto", "on", "with", "without",
    "is", "are", "was", "were", "be", "been", "being", "am", "do", "does", "did", "done",
    "it", "its", "he", "she", "they", "them", "their", "his", "her", "hers", "him",
    "we", "us", "our", "you", "your", "i", "me", "my", "mine",
    "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
    "used", "use", "using", "also", "same", "very", "more", "most", "much", "many",
    "variant", "variants", "form", "forms", "old", "ancient", "name", "names", "surname",
    "clan", "river",
    "non", "japanese", "chinese", "korean", "cantonese", "mandarin",
    "etc", "ie", "eg", "abbreviation",
};

/// <summary>每个英文词最多保留的候选汉字数（与 Python 版 <c>EN2HANZI_MAX</c> 一致）。</summary>
internal const int En2HanziMax = 8;

public static (Dictionary<string, List<int>> En2Hanzi, SortedDictionary<int, List<string>> Hanzi2En)
    BuildGlossTables(string zipPath)
{
    if (!File.Exists(zipPath))
        throw new FileNotFoundException($"缺少 Unihan 数据：{Path.GetFullPath(zipPath)}", zipPath);

    var hanzi2en = new SortedDictionary<int, List<string>>();
    foreach (var (cp, tag, value) in ReadUnihanRows(zipPath, "Unihan_Readings.txt"))
    {
        if (tag != "kDefinition") continue;
        var words = ParseDefinition(value);
        if (words.Count == 0) continue;
        hanzi2en[cp] = words.OrderBy(w => w, StringComparer.Ordinal).ToList();
    }

    var en2hanzi = new Dictionary<string, List<int>>(StringComparer.Ordinal);
    foreach (var (cp, words) in hanzi2en)
    {
        foreach (var word in words)
        {
            if (!en2hanzi.TryGetValue(word, out var list))
            {
                list = new List<int>();
                en2hanzi[word] = list;
            }
            list.Add(cp);
        }
    }

    // 主区优先（U+4E00–U+9FFF 常用字），同级按码点升序；每词截断到 En2HanziMax。
    static (int Tier, int CodePoint) Rank(int cp) => (cp is >= 0x4E00 and <= 0x9FFF ? 0 : 1, cp);
    foreach (var word in en2hanzi.Keys.ToList())
    {
        en2hanzi[word] = en2hanzi[word]
            .Distinct()
            .OrderBy(Rank)
            .Take(En2HanziMax)
            .ToList();
    }

    return (en2hanzi, hanzi2en);
}

/// <summary>
/// Unihan <c>kDefinition</c> → 规范英文词集合。
///
/// 词首边界 <c>(?&lt;![a-z0-9])</c> 用于避免序数后缀碎片（<c>13th</c> 曾被切出 <c>th</c>，
/// 实测覆盖 10.7% 文档且无释义信息）；T2-8 已固化该规则。
/// </summary>
public static List<string> ParseDefinition(string value)
{
    var cleaned = ParenAnnotationRegex.Replace(value, " ").ToLowerInvariant();
    var words = new SortedSet<string>(StringComparer.Ordinal);
    foreach (System.Text.RegularExpressions.Match match in GlossWordRegex.Matches(cleaned))
    {
        var word = match.Value.TrimEnd('\'', '-');
        if (word.Length >= 2 && !GlossStopwords.Contains(word)) words.Add(word);
    }
    return words.ToList();
}

/// <summary>去掉 <c>(...)</c> / <c>[...]</c> 括注。</summary>
private static readonly System.Text.RegularExpressions.Regex ParenAnnotationRegex =
    new(@"\([^)]*\)|\[[^\]]*\]", System.Text.RegularExpressions.RegexOptions.Compiled);

/// <summary>
/// 词形切分：<c>[a-z][a-z'-]+</c>，且**词首不得紧跟字母 / 数字**——
/// 否则 <c>13th</c> 会被切出 <c>th</c>（T2-8 修掉的噪音）。
/// </summary>
private static readonly System.Text.RegularExpressions.Regex GlossWordRegex =
    new(@"(?<![a-z0-9])[a-z][a-z'\-]+", System.Text.RegularExpressions.RegexOptions.Compiled);

public static void WriteEn2HanziTable(string output, Dictionary<string, List<int>> table)
{
    var builder = new StringBuilder();
    builder.AppendLine("# Archoera indexer Unihan 释义查询扩展：英文词 → 候选汉字码点（T1，查询侧用）");
    builder.AppendLine("# 来源: Unicode Unihan kDefinition（Unicode License，https://www.unicode.org/license.txt）");
    builder.AppendLine($"# 字段: WORD<TAB>HEX1 HEX2 ...；HEX 为汉字码点（去重、主区优先+码点升序、每词 ≤ {En2HanziMax}）");
    builder.AppendLine("# 生成: tools/gen_tables（去括注/小写/停用词过滤，确定可重跑）");
    foreach (var word in table.Keys.OrderBy(w => w, StringComparer.Ordinal))
    {
        builder.Append(word);
        builder.Append('\t');
        builder.Append(string.Join(' ', table[word].Select(cp => cp.ToString("X4", CultureInfo.InvariantCulture))));
        builder.AppendLine();
    }
    File.WriteAllText(output, builder.ToString(), new UTF8Encoding(false));
    Console.WriteLine($"def_en2hanzi.tsv : {table.Count} 词，候选码点共 " +
                      $"{table.Values.Sum(v => v.Count)} -> {output}");
}

public static void WriteHanzi2EnTable(string output, SortedDictionary<int, List<string>> table)
{
    var builder = new StringBuilder();
    builder.AppendLine("# Archoera indexer Unihan 释义查询扩展：汉字码点 → 英文词列表（T1，查询侧用）");
    builder.AppendLine("# 来源: Unicode Unihan kDefinition（Unicode License，https://www.unicode.org/license.txt）");
    builder.AppendLine("# 字段: HEXCODE<TAB>WORD1 WORD2 ...；WORD 去重、字典序");
    builder.AppendLine("# 生成: tools/gen_tables（去括注/小写/停用词过滤，确定可重跑）");
    foreach (var (cp, words) in table)
    {
        builder.Append(cp.ToString("X4", CultureInfo.InvariantCulture));
        builder.Append('\t');
        builder.Append(string.Join(' ', words));
        builder.AppendLine();
    }
    File.WriteAllText(output, builder.ToString(), new UTF8Encoding(false));
    Console.WriteLine($"def_hanzi2en.tsv : {table.Count} 字 -> {output}");
}

/// <summary>逐行读取 Unihan zip 内某个 txt（`U+XXXX\tTAG\tVALUE`，跳过注释与空行）。</summary>
public static IEnumerable<(int CodePoint, string Tag, string Value)> ReadUnihanRows(
    string zipPath, string entryName)
{
    using var archive = System.IO.Compression.ZipFile.OpenRead(zipPath);
    var entry = archive.GetEntry(entryName)
        ?? throw new InvalidOperationException($"Unihan.zip 缺少 {entryName}");
    using var stream = entry.Open();
    using var reader = new StreamReader(stream, Encoding.UTF8);
    while (reader.ReadLine() is { } line)
    {
        if (line.Length == 0 || line[0] == '#') continue;
        var cols = line.Split('\t');
        if (cols.Length != 3) continue;
        if (!TryParseCodePoint(cols[0], out var cp)) continue;
        yield return (cp, cols[1], cols[2]);
    }
}

/// <summary>索引侧汉字范围（主区 + 扩展 A + 兼容表意），与 <c>Analyzer.IsCjk</c> 一致。</summary>
public static bool IsIndexerHanziRange(int cp) =>
    cp is >= 0x3400 and <= 0x4DBF or >= 0x4E00 and <= 0x9FFF or >= 0xF900 and <= 0xFAFF;

}
