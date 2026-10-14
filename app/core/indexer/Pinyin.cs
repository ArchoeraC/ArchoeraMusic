// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

using System.Text;
using ToolGood.Words;

namespace Archoera.Indexer;

/// <summary>
/// 汉字 → 拼音门面（基于 <c>ToolGood.Words</c>，Apache-2.0）。
///
/// 以**连续 CJK 段**为单位调用 ToolGood，利用其**词级多音字消歧**
/// （如 <c>重庆→chong qing</c>、<c>银行→yin hang</c>），而非逐字取主读音。
/// 音节统一归一为纯 ascii 小写（<c>ü</c> 由 ToolGood 直接给出 <c>Nv</c>）；
/// 本类型只做调用与归一，不在查询期做任何转换（拼音生成是索引期成本，
/// 遵守设计文档 §4.5：查询期只解释用户输入）。
///
/// 多音字策略（本期）：由 ToolGood 的词库在段内消歧；未收录读音不额外展开候选。
/// </summary>
public static class Pinyin
{
    /// <summary>
    /// 整段 CJK 的全拼音节序列（纯 ascii 小写，按字符顺序；无读音者跳过）。
    /// 段内词级消歧，比逐字主读音更准确。
    /// </summary>
    public static List<string> FromCjkRun(string run)
    {
        var syllables = new List<string>();
        if (string.IsNullOrEmpty(run)) return syllables;

        var raw = WordsHelper.GetPinyin(run, " ", false);
        foreach (var part in raw.Split(' ', StringSplitOptions.RemoveEmptyEntries))
        {
            var syllable = AsciiLower(part);
            if (syllable.Length > 0) syllables.Add(syllable);
        }
        return syllables;
    }

    /// <summary>
    /// 整段 CJK 的首字母串（纯 ascii 小写，逐字一位；无读音者跳过）。
    /// 与 <see cref="FromCjkRun"/> 同源（ToolGood 首拼音），保证两侧消歧一致。
    /// </summary>
    public static string Initials(string run)
        => string.IsNullOrEmpty(run) ? string.Empty : AsciiLower(WordsHelper.GetFirstPinyin(run));

    /// <summary>
    /// 归一为纯 ascii 小写：只保留字母并转小写（丢弃声调 / 分隔符 / 非字母）。
    /// ToolGood 的输出可能含大写开头或 <c>ü→v</c> 已转写，这里统一收口。
    /// </summary>
    internal static string AsciiLower(string value)
    {
        var builder = new StringBuilder(value.Length);
        foreach (var ch in value)
        {
            if (ch >= 'a' && ch <= 'z') builder.Append(ch);
            else if (ch >= 'A' && ch <= 'Z') builder.Append((char)(ch + 32));
        }
        return builder.ToString();
    }
}
