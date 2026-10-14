// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

using ToolGood.Words;

namespace Archoera.Indexer;

/// <summary>
/// 查询侧「连写全拼」切分器（P4，设计文档 §4.2「混合」）。
///
/// 背景：查询 <c>woaini</c>（无空格）经脚本切分后是**拉丁整词**，索引里的拼音却是
/// 分音节的 <c>wo ai ni</c>，故无法命中。本类把纯拉丁词按**有效拼音音节**切分：
/// <list type="bullet">
///   <item>音节清单**惰性**由 ToolGood.Words 遍历 CJK 范围（U+3400–U+9FFF，跳过代理）
///         调 <c>GetAllPinyin</c> 去重派生并缓存，不内嵌数据表 / 不依赖外部文件
///         （首次约 20–30 ms，之后查询零成本）；</item>
///   <item>仅对纯 ASCII 小写字母（<c>a</c>–<c>z</c>）尝试切分，数字 / 混合串原样保留；</item>
///   <item>要求**完整覆盖**（整个词都能切成音节），否则返回 <c>false</c>——
///         英文词如 <c>hello</c> / <c>zjl</c> 不会被错误切分。</item>
/// </list>
///
/// 歧义策略（确定性）：**最长音节优先**。用一次自底向上的可达性 DP 保证「最长优先」
/// 不会把本身可完整覆盖的串误判为不可切分；每个位置在同长度音节唯一（无重复），
/// 故切分结果唯一且与调用顺序无关。
///
/// 英文过度切分门控（P4 修复）：仅「完整覆盖」仍会把 <c>banana</c>（→<c>ban an a</c>）、
/// <c>adele</c>（→<c>a de le</c>）等英文词误切。故在最长优先结果上追加**确定性门控**：
/// <list type="bullet">
///   <item>词长 2..12（更短的无需切、更长的多为英文 / 非连写拼音，宁可少切）；</item>
///   <item>音节数 ≥2（单音节 = 整词，切分无意义）；</item>
///   <item>**每个音节长度 ≥2**（拼音单字母音节仅 <c>a</c>/<c>o</c>/<c>e</c> 等，
///         连写查询里单独出现多为英文词尾 / 词首，如 <c>banana</c> 的末 <c>a</c>、
///         <c>adele</c> 的首 <c>a</c>）；</item>
/// </list>
/// 门控施加在**最长优先结果**上（而非约束 DP）：这样 <c>banana</c> 被 <c>ban an a</c>
/// 的单个 <c>a</c> 拒掉，不会退而求其次切出 <c>ba na na</c> 重新引入误切。
/// 取舍：宁可少切（漏召回）也不要误切（噪声召回）；<c>woaini</c> / <c>woai</c> /
/// <c>zhaoliying</c> / <c>xiaoai</c> 等真·连写全拼仍可切分。
/// 已知残留：短同形词 <c>panda</c> → <c>pan da</c>、<c>women</c> → <c>wo men</c>、
/// <c>mama</c> → <c>ma ma</c> 仍会切分——它们与常用拼音同形且过短，无法区分，
/// 保持不拦截以免误伤真拼音（<c>mama</c>=妈妈）。
/// 长度 ≥6 的英文词（<c>aiding</c> / <c>shanghai</c> 等）不再有阻断表保护，
/// 会按音节切分（如 <c>ai ding</c> / <c>shang hai</c>）——这是删除英文阻断表后的
/// 已知取舍（见报告风险项）。
///
/// 只读、无 IO、无可变静态状态（除惰性音节表），可安全并发调用。
/// </summary>
internal static class PinyinSegmenter
{
    /// <summary>可切分词长下限（更短无意义）。</summary>
    private const int MinWordLength = 2;

    /// <summary>可切分词长上限（更长多为英文单词 / 非连写拼音）。</summary>
    private const int MaxWordLength = 12;

    /// <summary>音节数下限（单音节 = 整词）。</summary>
    private const int MinSyllableCount = 2;

    /// <summary>音节长度下限（单字母音节仅 a/o/e，连写查询里单独出现多为英文残留）。</summary>
    private const int MinSyllableLength = 2;

    /// <summary>派生音节清单时遍历的 CJK 码点范围（含扩展 A）。</summary>
    private const int CjkScanStart = 0x3400;

    private const int CjkScanEnd = 0x9FFF;

    private sealed class SyllableTable
    {
        public required IReadOnlySet<string> Items { get; init; }

        public required int MaxLength { get; init; }
    }

    /// <summary>
    /// 音节清单：惰性由 ToolGood.Words 遍历 CJK 范围派生（去重、纯 ascii 小写）。
    /// 无外部数据表依赖；首次构建约 20–30 ms，构建一次后缓存复用。
    /// </summary>
    private static readonly Lazy<SyllableTable> Table = new(static () =>
    {
        var items = new HashSet<string>(StringComparer.Ordinal);
        var maxLength = 0;
        for (var cp = CjkScanStart; cp <= CjkScanEnd; cp++)
        {
            if (cp is >= 0xD800 and <= 0xDFFF) continue; // 代理区不构成独立字符
            var readings = WordsHelper.GetAllPinyin((char)cp, false);
            if (readings is null) continue;
            foreach (var reading in readings)
            {
                var syllable = Pinyin.AsciiLower(reading);
                if (syllable.Length == 0) continue;
                items.Add(syllable);
                if (syllable.Length > maxLength) maxLength = syllable.Length;
            }
        }
        return new SyllableTable { Items = items, MaxLength = maxLength };
    });

    /// <summary>
    /// 尝试把一个纯 ASCII 拉丁词按有效拼音音节**完整**切分。
    /// 成功时把音节序列写入 <paramref name="syllables"/>（先清空）并返回 <c>true</c>；
    /// 非纯 <c>a</c>–<c>z</c> / 空串 / 长度越界 / 无法完整覆盖 /
    /// 不满足门控（音节数 &lt;2 或存在单字母音节）→ 返回 <c>false</c>（调用方保留原整词）。
    /// </summary>
    public static bool TrySegment(string word, List<string> syllables)
    {
        syllables.Clear();
        if (word.Length < MinWordLength || word.Length > MaxWordLength) return false;

        var table = Table.Value;
        var n = word.Length;
        for (var i = 0; i < n; i++)
        {
            if (word[i] < 'a' || word[i] > 'z') return false;
        }

        // reachable[i]：从 i 起可完整切分到结尾；choice[i]：该位置的**最长可行**音节长度。
        var reachable = new bool[n + 1];
        var choice = new int[n + 1];
        reachable[n] = true;
        for (var i = n - 1; i >= 0; i--)
        {
            var limit = Math.Min(table.MaxLength, n - i);
            for (var length = limit; length >= 1; length--)
            {
                if (!reachable[i + length]) continue;
                if (!table.Items.Contains(word.Substring(i, length))) continue;
                reachable[i] = true;
                choice[i] = length;
                break;
            }
        }
        if (!reachable[0]) return false;

        // 先按最长优先还原切分，再对结果施加门控（见类注释：门控在结果上，不约束 DP）。
        var count = 0;
        for (var i = 0; i < n;)
        {
            var length = choice[i];
            if (length < MinSyllableLength)
            {
                syllables.Clear();
                return false;
            }
            syllables.Add(word.Substring(i, length));
            count++;
            i += length;
        }
        if (count < MinSyllableCount)
        {
            syllables.Clear();
            return false;
        }
        return true;
    }
}
