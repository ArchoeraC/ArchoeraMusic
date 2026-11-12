// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

using System.Text;

namespace Archoera.Indexer;

/// <summary>
/// 韩文读音（T1-3）：谚文音节 → **国语罗马字（RR）**，写入与日文读音同一条
/// <c>reading_meta_tok</c> 派生列（字母 bigram）。
///
/// 只做**字面转写**（Unicode 公式 <c>AC00 + L*21*28 + V*28 + T</c> 分解初声 / 中声 / 终声）；
/// 连音 / 鼻化 / 腭化等音变**后置迭代**（先用基础形覆盖 `사랑해 → saranghae` 这类无音变词）。
/// 索引侧与查询侧最终都过 <see cref="RomajiCanonical"/> 折叠，两侧口径一致。
/// </summary>
internal static class Korean
{
    /// <summary>初声（19）：ㅇ 作初声不发音。</summary>
    private static readonly string[] Initials =
    {
        "g", "kk", "n", "d", "tt", "r", "m", "b", "pp", "s",
        "ss", "", "j", "jj", "ch", "k", "t", "p", "h",
    };

    /// <summary>中声（21）。</summary>
    private static readonly string[] Vowels =
    {
        "a", "ae", "ya", "yae", "eo", "e", "yeo", "ye", "o", "wa", "wae",
        "oe", "yo", "u", "wo", "we", "wi", "yu", "eu", "ui", "i",
    };

    /// <summary>终声（28）：按 RR 的收音写法（ㅇ → ng，ㅎ → t 等）。</summary>
    private static readonly string[] Finals =
    {
        "", "k", "k", "k", "n", "n", "n", "t", "l", "k", "m",
        "l", "l", "l", "p", "l", "m", "p", "p", "t", "t",
        "ng", "t", "t", "k", "t", "p", "t",
    };

    /// <summary>兼容区 Jamo（U+3131..U+3163）：独立字母（非音节）时的读音。</summary>
    private static readonly string[] Compat =
    {
        "g", "kk", "gs", "n", "nj", "nh", "d", "tt", "r", "lg", "lm", "lb", "ls",
        "lt", "lp", "lh", "m", "b", "pp", "bs", "s", "ss", "ng", "j", "jj", "ch",
        "k", "t", "p", "h",
        "a", "ae", "ya", "yae", "eo", "e", "yeo", "ye", "o", "wa", "wae", "oe",
        "yo", "u", "wo", "we", "wi", "yu", "eu", "ui", "i",
    };

    /// <summary>文本是否含谚文（音节或兼容区 Jamo）。</summary>
    public static bool ContainsHangul(string text)
    {
        foreach (var ch in text)
            if (IsHangul(ch)) return true;
        return false;
    }

    public static bool IsHangul(char c)
        => (c >= '\uAC00' && c <= '\uD7A3') || (c >= '\u3131' && c <= '\u3163');

    /// <summary>谚文串 → RR 罗马字（非谚文字符丢弃；调用方只传连续谚文段）。</summary>
    public static string Romanize(ReadOnlySpan<char> text)
    {
        var sb = new StringBuilder(text.Length * 3);
        foreach (var ch in text)
        {
            if (ch >= '\uAC00' && ch <= '\uD7A3')
            {
                var index = ch - '\uAC00';
                sb.Append(Initials[index / (21 * 28)]);
                sb.Append(Vowels[index % (21 * 28) / 28]);
                sb.Append(Finals[index % 28]);
            }
            else if (ch >= '\u3131' && ch <= '\u3163')
            {
                sb.Append(Compat[ch - '\u3131']);
            }
            else if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9'))
            {
                sb.Append(char.ToLowerInvariant(ch));
            }
        }
        return sb.ToString();
    }
}
