// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

using Archoera.Text;
using System.Globalization;
using System.Text;

namespace Archoera.Indexer;

/// <summary>
/// 日文读音映射（索引期）：**假名 → 罗马字**（<c>data/kana_romaji.tsv</c>）+
/// **汉字 → 音读 / 训读罗马字**（<c>data/ja_readings.tsv</c>，派生自 Unihan
/// <c>kJapaneseOn</c> / <c>kJapaneseKun</c>，Unicode License，见
/// <c>tools/gen_hanzi_data.py</c> 与同目录 THIRD-PARTY-LICENSES.md）。
///
/// 产出写进独立的 <c>reading_meta_tok</c> / <c>reading_lyrics_tok</c> 列，内容为**字母 bigram**
/// （与 CJK 的 bigram 索引同构）：查询侧把罗马字查询串也 bigram 成 `AND` 组即可命中去重后的
/// 连续子串（`kurarin` ⊂ `kyuukurarin`）。ribun 见设计文档 §4.2。
///
/// 设计取舍（真实日文曲库实测驱动）：
/// <list type="bullet">
///   <item>**只在「看起来是日文」的文本上产出**（该源含假名，或整首曲目任一源含假名）——
///         纯中文曲库不产生这些列，既不增加体积也不引入跨语言噪声；</item>
///   <item>假名罗马字给 **Hepburn 主拼 + 常见 Kunrei 变体**（し → shi/si、つ → tsu/tu …）。
///         变体只为提高键入召回（有人按训令式打字）；变体展开**按「主拼整串 + 每个歧义假名的
///         局部窗口」**计算，成本线性、与串长无关（不做整串变体笛卡尔积，避免长歌词行指数膨胀）；</item>
///   <item>促音「っ」重复后一音节首辅音（まって → matte）、长音「ー」延长前一元音
///         （数据 → deeta）；长元音用重复元音表示，不用 macron（便于纯 ASCII 键入）；</item>
///   <item>**已知限制**：汉字读音来自 Unihan 单字 <c>kJapaneseOn/Kun</c>，**不含人名 / 地名
///         的 nanori**（如 米津 = yonezu 的连读），故 `yonezu` 这类跨字训读不命中；
///         单字读音仍可用（`kome` / `yone` / `tsu` / `shin`）。补齐需 nanori 词表（另立任务）。</item>
/// </list>
/// </summary>
internal static class Japanese
{
    /// <summary>假名罗马字表（最长匹配：先试 2 字符，再试 1 字符）；值为**空格分隔**的拼写变体。</summary>
    private static readonly Lazy<Dictionary<string, string[]>> KanaTable = new(static () =>
    {
        var table = new Dictionary<string, string[]>(StringComparer.Ordinal);
        foreach (var line in ReadResourceLines("Archoera.Indexer.data.kana_romaji.tsv"))
        {
            var cols = line.Split('\t');
            if (cols.Length < 2) continue;
            var variants = cols[1].Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (variants.Length > 0) table[cols[0]] = variants;
        }
        return table;
    });

    /// <summary>汉字 → 假名读音列表（Unihan kJapaneseOn / kJapaneseKun）。</summary>
    private static readonly Lazy<Dictionary<int, string[]>> KanjiReadings = new(static () =>
    {
        var table = new Dictionary<int, string[]>();
        foreach (var line in ReadResourceLines("Archoera.Indexer.data.ja_readings.tsv"))
        {
            var cols = line.Split('\t');
            if (cols.Length < 2) continue;
            if (!int.TryParse(cols[0], NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var cp))
                continue;
            var kana = cols[1].Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (kana.Length > 0) table[cp] = kana;
        }
        return table;
    });

    /// <summary>整串变体展开的预算（每个假名逐个窗口计算，故实际只影响局部窗口大小）。</summary>
    private const int MaxVariantsPerRun = 64;

    /// <summary>文本是否含假名（平 / 片 / 半角）——判断「这首曲目要不要产出日文读音列」。</summary>
    public static bool ContainsKana(string text)
    {
        foreach (var ch in text)
        {
            if (ScriptRanges.IsKana(ch)) return true;
        }
        return false;
    }

    /// <summary>文本是否含汉字（决定是否需要查读音表）。</summary>
    private static bool ContainsCjk(string text)
    {
        foreach (var ch in text)
        {
            if (ScriptRanges.IsCjk(ch)) return true;
        }
        return false;
    }

    /// <summary>
    /// 生成读音列的 **bigram 词元串**（空格分隔的 2 字符字母 bigram）。
    ///
    /// [includeKanjiReadings] 为真时（调用方判定「整首曲目是日文」）连**纯汉字段**也查读音表
    /// （真实曲库里歌手名常常是纯汉字，如 米津玄師）；否则只对含假名的段产出。
    /// 无假名且未启用汉字读音 → 返回空串（纯中文曲库零成本）。
    /// </summary>
    public static string ReadingBigrams(string text, bool includeKanjiReadings)
    {
        if (string.IsNullOrEmpty(text)) return "";
        if (!ContainsKana(text) && !(includeKanjiReadings && ContainsCjk(text))) return "";

        // **必须按出现顺序发射**（与 CJK 分词一致）：读数列要支持「相邻 bigram 短语」= 子串检索，
        // 排序 / 去重都会破坏相邻语义（早期用 SortedSet 导致所有短语查询命中 0）。
        var bigrams = new List<string>();
        var buffer = new StringBuilder();

        // 逐字符推进：假名段按最长匹配转罗马字；汉字段取读音（可选）。
        var i = 0;
        while (i < text.Length)
        {
            var ch = text[i];

            if (ScriptRanges.IsKana(ch))
            {
                // 收集连续假名段（含促音 / 长音标记），整段算主拼 + 局部变体
                var start = i;
                while (i < text.Length && ScriptRanges.IsKana(text[i])) i++;
                AddKanaRunBigrams(text.AsSpan(start, i - start), bigrams);
                continue;
            }

            if (includeKanjiReadings && ScriptRanges.IsCjk(ch))
            {
                // 单个汉字读音（不含跨字连读；见类注释的已知限制）
                if (KanjiReadings.Value.TryGetValue(char.ConvertToUtf32(text, i), out var readings))
                {
                    foreach (var reading in readings)
                    {
                        buffer.Clear();
                        var romaji = ToRomaji(reading, primaryOnly: true);
                        if (romaji.Length > 0) AddBigrams(romaji, bigrams);
                    }
                }
                if (char.IsHighSurrogate(ch) && i + 1 < text.Length) i += 2; else i++;
                continue;
            }

            i++;
        }

        return string.Join(' ', bigrams);
    }

    /// <summary>
    /// 一个假名段的 bigram：**主拼整串** + **每个歧义假名的局部 3 假名窗口**。
    ///
    /// 为什么不用整串变体笛卡尔积：长歌词行里歧义假名可能有十几个，展开会指数膨胀；
    /// 局部窗口把成本钉在 O(段长 × 变体数)，且**每个**歧义假名都能被覆盖。
    /// </summary>
    private static void AddKanaRunBigrams(ReadOnlySpan<char> run, List<string> bigrams)
    {
        var text = run.ToString();

        // 1) 主拼整串（Hepburn 首选拼写）
        var primary = ToRomaji(text, primaryOnly: true);
        if (primary.Length > 0) AddBigrams(primary, bigrams);

        // 2) 局部窗口：下标 i 处若有多个拼写变体，用「i-1..i+1」三字窗口各自算一遍
        var units = SplitKanaUnits(text);
        var variantCount = 0;
        for (var i = 0; i < units.Count && variantCount < MaxVariantsPerRun; i++)
        {
            if (Variants(units[i]).Length < 2) continue;

            foreach (var alt in Variants(units[i]))
            {
                if (variantCount++ >= MaxVariantsPerRun) break;
                var window = new StringBuilder();
                for (var k = Math.Max(0, i - 1); k <= Math.Min(units.Count - 1, i + 1); k++)
                {
                    window.Append(k == i ? alt : Variants(units[k])[0]);
                }
                var romaji = ToRomaji(window.ToString(), primaryOnly: true);
                if (romaji.Length > 0) AddBigrams(romaji, bigrams);
            }
        }
    }

    /// <summary>把假名串按 2 字符（拗音等）优先切成「单元」序列（促音 / 长音各自成单元）。</summary>
    private static List<string> SplitKanaUnits(string text)
    {
        var units = new List<string>();
        var i = 0;
        while (i < text.Length)
        {
            var two = i + 1 < text.Length ? text.Substring(i, 2) : "";
            if (two.Length == 2 && KanaTable.Value.ContainsKey(two))
            {
                units.Add(two);
                i += 2;
            }
            else
            {
                units.Add(text[i].ToString());
                i++;
            }
        }
        return units;
    }

    private static string[] Variants(string unit)
        => KanaTable.Value.TryGetValue(unit, out var v) ? v : new[] { unit };

    /// <summary>
    /// 假名串 → 罗马字（[primaryOnly] 为真只取首选拼写）。
    /// 促音「っ」重复后一音节首辅音；长音「ー」延长前一元音；其余按最长匹配查表。
    /// </summary>
    private static string ToRomaji(string kana, bool primaryOnly)
    {
        var sb = new StringBuilder(kana.Length * 2);
        var pendingGeminate = false;
        var i = 0;
        while (i < kana.Length)
        {
            var two = i + 1 < kana.Length ? kana.Substring(i, 2) : "";
            string? unit = null;
            if (two.Length == 2 && KanaTable.Value.ContainsKey(two)) { unit = two; i += 2; }
            else if (KanaTable.Value.ContainsKey(kana[i].ToString())) { unit = kana[i].ToString(); i += 1; }
            else { i++; continue; }   // 非假名：跳过（调用方已按段切分）

            if (unit == "っ")
            {
                pendingGeminate = true;
                continue;
            }

            if (unit == "ー")
            {
                // 长音：延长前一元音（无前元音时忽略）
                var last = LastVowel(sb);
                if (last != 0) sb.Append(last);
                continue;
            }

            var spelling = Variants(unit)[0];
            if (pendingGeminate)
            {
                pendingGeminate = false;
                if (spelling.Length > 0) sb.Append(spelling[0]);   // 促音 = 重复后一音节首辅音
            }
            sb.Append(spelling);

            if (!primaryOnly) { /* 变体由调用方按窗口展开，此处只产出主拼 */ }
        }
        return sb.ToString();
    }

    private static char LastVowel(StringBuilder sb)
    {
        for (var i = sb.Length - 1; i >= 0; i--)
        {
            var c = sb[i];
            if ("aeiou".IndexOf(c) >= 0) return c;
            if (c == 'n') return '\0';
        }
        return '\0';
    }

    /// <summary>字母 bigram（含单字符本体，便于 1 字符查询）；只保留 ASCII 字母与数字。</summary>
    private static void AddBigrams(string romaji, List<string> bigrams)
    {
        var normalized = new StringBuilder(romaji.Length);
        foreach (var c in romaji)
        {
            var lower = char.ToLowerInvariant(c);
            if ((lower >= 'a' && lower <= 'z') || (lower >= '0' && lower <= '9')) normalized.Append(lower);
        }
        var s = normalized.ToString();
        if (s.Length == 0) return;
        if (s.Length == 1)
        {
            bigrams.Add(s);
            return;
        }
        for (var i = 0; i + 1 < s.Length; i++)
            bigrams.Add(s.Substring(i, 2));
    }

    /// <summary>读取内嵌表（<c>#</c> 注释 / 空行跳过）；缺失时返回空序列（**不抛**）。</summary>
    private static IEnumerable<string> ReadResourceLines(string logicalName)
    {
        var assembly = typeof(Japanese).Assembly;
        using var stream = assembly.GetManifestResourceStream(logicalName);
        if (stream is null) yield break;   // 资源缺失：降级为空表（调用方得到空读音，不崩）
        using var reader = new StreamReader(stream, Encoding.UTF8);
        string? line;
        while ((line = reader.ReadLine()) is not null)
        {
            if (line.Length == 0 || line[0] == '#') continue;
            yield return line;
        }
    }
}
