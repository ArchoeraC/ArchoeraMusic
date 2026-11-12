// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

using System.Text;

namespace Archoera.Indexer;

/// <summary>
/// 罗马字**规范形**（T1-1）：把 Hepburn / Kunrei 两套拼写折叠成同一串，消除
/// 「索引按 Hepburn 生成、用户按训令式键入」造成的读音趟落空。
///
/// 折叠规则（逐字符、确定性、纯 ASCII；非字母原样忽略由上层的清洗负责）：
/// <list type="bullet">
///   <item><c>sh → s</c>、<c>ch → t</c>、<c>ts → t</c>（し / ち / つ 的训令式写法）；</item>
///   <item><c>fu → hu</c>、<c>j → z</c>（ふ / じ 系）；</item>
///   <item>**促音折叠**：重复辅音压成一个（<c>matchi → matti → mati</c>、<c>gakkou → gakou</c>），
///         使用户漏打「っ」也能命中；<c>nn</c> 不折叠（它承载「ん」的边界信息）；</item>
///   <item>**长音折叠**：<c>ou / oo → o</c>（<c>toukyou → tokyo</c>）。</item>
/// </list>
///
/// 索引侧在生成读音 bigram 前调用 <see cref="Apply"/>；查询侧在编译读音趟前调用
/// <see cref="Variants"/>（额外给出「ん + 元音 → nn」变体，与索引侧的生成规则对齐）。
/// </summary>
internal static class RomajiCanonical
{
    /// <summary>规范形：折叠 Hepburn / Kunrei 差异、促音与长音。</summary>
    public static string Apply(string romaji)
    {
        if (romaji.Length == 0) return romaji;
        var folded = FoldSpelling(romaji);
        folded = FoldGeminates(folded);
        return FoldLongVowels(folded);
    }

    /// <summary>
    /// 查询侧候选：规范形 + 「ん + 元音」放宽变体（把 <c>n</c>+元音写成 <c>nn</c>+元音）。
    ///
    /// 索引侧无法只靠罗马字区分「ん」与「な行」，故在**生成时**用假名上下文决定 <c>nn</c>；
    /// 查询侧不知道键入者写的是哪种，故两个候选都试（原始规范形保留，绝不降低召回）。
    /// </summary>
    public static IReadOnlyList<string> Variants(string token)
    {
        var canonical = Apply(token);
        var relaxed = RelaxN(canonical);
        return string.Equals(canonical, relaxed, StringComparison.Ordinal)
            ? new[] { canonical }
            : new[] { canonical, relaxed };
    }

    /// <summary>sh→s、ch→t、ts→t、fu→hu、j→z（最长匹配优先）。</summary>
    private static string FoldSpelling(string s)
    {
        var sb = new StringBuilder(s.Length);
        for (var i = 0; i < s.Length; i++)
        {
            var c = s[i];
            var next = i + 1 < s.Length ? s[i + 1] : '\0';
            switch (c)
            {
                case 't' when next == 's':
                    sb.Append('t');
                    i++;
                    break;
                case 's' when next == 'h':
                    sb.Append('s');
                    i++;
                    break;
                case 'c' when next == 'h':
                    sb.Append('t');
                    i++;
                    break;
                case 'f' when next == 'u':
                    sb.Append("hu");
                    i++;
                    break;
                case 'j':
                    sb.Append('z');
                    break;
                default:
                    sb.Append(c);
                    break;
            }
        }
        return sb.ToString();
    }

    /// <summary>重复辅音压成一个；<c>nn</c> 保留（ん 的边界标记），元音不折叠。</summary>
    private static string FoldGeminates(string s)
    {
        var sb = new StringBuilder(s.Length);
        foreach (var c in s)
        {
            if (sb.Length > 0 && sb[^1] == c && IsFoldableConsonant(c)) continue;
            sb.Append(c);
        }
        return sb.ToString();
    }

    private static bool IsFoldableConsonant(char c)
        => c is >= 'a' and <= 'z' && "aeioun".IndexOf(c) < 0;

    /// <summary>ou / oo → o（长音）。</summary>
    private static string FoldLongVowels(string s)
    {
        var sb = new StringBuilder(s.Length);
        for (var i = 0; i < s.Length; i++)
        {
            var c = s[i];
            if (c == 'o' && i + 1 < s.Length && (s[i + 1] == 'u' || s[i + 1] == 'o'))
            {
                sb.Append('o');
                i++;
                continue;
            }
            sb.Append(c);
        }
        return sb.ToString();
    }

    /// <summary>把「n + 元音」放宽成「nn + 元音」（已出现的 nn 不重复扩展）。</summary>
    private static string RelaxN(string s)
    {
        if (s.Length < 2) return s;
        var sb = new StringBuilder(s.Length + 2);
        for (var i = 0; i < s.Length; i++)
        {
            var c = s[i];
            if (c == 'n' && i + 1 < s.Length && "aeiou".IndexOf(s[i + 1]) >= 0)
            {
                // 已是 nn + 元音（前一个字符就是 n）→ 不重复加。
                if (sb.Length > 0 && sb[^1] == 'n') { sb.Append(c); continue; }
                sb.Append("nn");
                continue;
            }
            sb.Append(c);
        }
        return sb.ToString();
    }
}
