// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

namespace Archoera.Text;

/// <summary>
/// 字符脚本分类（**scanner 与 indexer 共用同一源文件**，各自 csproj 显式 <c>Compile Include</c>）——
/// 分词的「哪些脚本要子串索引」与歌词分层里「什么才算拉丁（罗马音）」都以这里为唯一事实来源，
/// 避免两套实现漂移。
///
/// 背景（P5 真实曲库实测）：真实库以日文为主（82/165 首歌词含假名），而旧实现只有
/// <c>CJK 表意</c> 一类需要子串索引，假名 / 谚文落进「拉丁」分支 → **整段一个 token**，
/// 于是子串查询（`くらりん` ⊂ `きゅうくらりん`）命中 0；同时假名被镜像进拼音 / 首字母列
/// （假名占歌词 9.6%，等于同一段文本存三份）。
/// </summary>
public static class ScriptRanges
{
    /// <summary>汉字：CJK 统一表意主区 + 扩展 A + 兼容表意区。</summary>
    public static bool IsCjk(char c)
        => (c >= '\u3400' && c <= '\u4DBF')
        || (c >= '\u4E00' && c <= '\u9FFF')
        || (c >= '\uF900' && c <= '\uFAFF');

    /// <summary>
    /// **需要子串索引的脚本**：假名（平 / 片 / 半角 / 片假名音标扩展）+ 谚文（音节 / 字母 / 兼容字母）。
    ///
    /// 这些脚本与汉字同样以 <c>bigram + unigram</c> 入索引（子串 / 前缀 / 词组都能命中），
    /// 但**不进拼音 / 首字母列**（假名与谚文没有拼音读音，镜像过去只会是噪声与体积）。
    /// </summary>
    public static bool IsSubstringScript(char c)
        => IsKana(c) || IsHangul(c);

    /// <summary>假名：平假名 / 片假名 / 片假名音标扩展 / 半角片假名。</summary>
    public static bool IsKana(char c)
        => (c >= '\u3040' && c <= '\u309F')   // 平假名
        || (c >= '\u30A0' && c <= '\u30FF')   // 片假名
        || (c >= '\u31F0' && c <= '\u31FF')   // 片假名音标扩展
        || (c >= '\uFF66' && c <= '\uFF9D');  // 半角片假名（NFKC 亦会折叠成全角）

    /// <summary>谚文：音节 + 字母（Jamo）+ 兼容字母。</summary>
    public static bool IsHangul(char c)
        => (c >= '\uAC00' && c <= '\uD7AF')   // 谚文音节
        || (c >= '\u1100' && c <= '\u11FF')   // 谚文字母
        || (c >= '\u3130' && c <= '\u318F');  // 谚文兼容字母

    /// <summary>拉丁字母（含 Latin-1 补充与 Latin 扩展 A/B）——用于「这一行是不是罗马音」的判定。</summary>
    public static bool IsLatinLetter(char c)
        => (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
        || (c >= '\u00C0' && c <= '\u024F');

    /// <summary>
    /// 是否为**纯拉丁行**（含拉丁字母、且不含汉字 / 假名 / 谚文）——译文层与音译层的保守判定。
    ///
    /// 旧实现用「不含 CJK 且含字母」判拉丁，于是**假名行会被当成罗马音**（真实库实测：
    /// 日文歌词行被划进「音译」层）。现在只有真正的拉丁字母才算，希腊 / 西里尔等按「非拉丁」处理
    /// （它们同样不是罗马音）。
    /// </summary>
    public static bool IsLatinLine(string text)
    {
        var hasLatin = false;
        foreach (var ch in text)
        {
            if (IsCjk(ch) || IsSubstringScript(ch)) return false;
            if (IsLatinLetter(ch)) hasLatin = true;
        }
        return hasLatin;
    }
}
