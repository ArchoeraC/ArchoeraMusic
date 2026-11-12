// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

namespace Archoera.Indexer;

/// <summary>
/// 读音兜底趟的**命中分档**（T1-4）。
///
/// 读音趟的 FTS 表达式是「相邻 bigram 短语」，命中只说明查询读音作为**连续子串**出现；
/// bm25 无法区分「整词前缀（标题读音以它开头）」与「中间包含」。这里拿候选的读音
/// bigram 原文副本（<c>search_docs.reading_tok</c>，v6 起保存）做一次 O(候选数 × 序列长)
/// 的复查，按档位重排：
/// <list type="number">
///   <item><see cref="PrefixTier"/>：读音串以查询序列开头（整词前缀命中）；</item>
///   <item><see cref="ContainsTier"/>：读音串中间包含查询序列（整词包含命中）；</item>
///   <item><see cref="OtherTier"/>：其它（理论上不会出现在读音趟结果里，留作兜底）。</item>
/// </list>
///
/// 计划里还有「散 bigram 覆盖率高 / 低」两档；但读音趟表达式要求**全部**查询 bigram
/// 连续出现，散 bigram 命中不会进入该趟，故本实现不产生这两档（见
/// <c>docs/cross-lingual-search-upgrade-plan.md</c> T1-4 的实施说明）。
/// </summary>
internal static class ReadingRanker
{
    /// <summary>整词前缀：读音串以查询 bigram 序列开头。</summary>
    public const int PrefixTier = 3;

    /// <summary>整词包含：读音串中间出现查询 bigram 序列。</summary>
    public const int ContainsTier = 2;

    /// <summary>非连续 / 无读音文本的兜底档。</summary>
    public const int OtherTier = 0;

    /// <summary>
    /// 给单个候选的读音串打分（取所有查询序列变体中的最高档）。
    /// <paramref name="readingText"/> 为空格分隔的读音 bigram 串（索引期原文副本）。
    /// </summary>
    public static int Score(string readingText, IReadOnlyList<string[]> sequences)
    {
        if (readingText.Length == 0 || sequences.Count == 0) return OtherTier;

        var tokens = readingText.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var best = OtherTier;
        foreach (var sequence in sequences)
        {
            if (sequence.Length == 0) continue;
            if (IsPrefix(tokens, sequence)) return PrefixTier;
            if (Contains(tokens, sequence)) best = ContainsTier;
        }
        return best;
    }

    private static bool IsPrefix(string[] tokens, string[] sequence)
    {
        if (tokens.Length < sequence.Length) return false;
        for (var i = 0; i < sequence.Length; i++)
        {
            if (!string.Equals(tokens[i], sequence[i], StringComparison.Ordinal)) return false;
        }
        return true;
    }

    private static bool Contains(string[] tokens, string[] sequence)
    {
        if (tokens.Length < sequence.Length) return false;
        var last = tokens.Length - sequence.Length;
        for (var start = 0; start <= last; start++)
        {
            var matched = true;
            for (var i = 0; i < sequence.Length; i++)
            {
                if (string.Equals(tokens[start + i], sequence[i], StringComparison.Ordinal)) continue;
                matched = false;
                break;
            }
            if (matched) return true;
        }
        return false;
    }
}
