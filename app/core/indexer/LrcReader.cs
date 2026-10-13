// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

using System.Text;
using System.Text.RegularExpressions;

namespace Archoera.Indexer;

/// <summary>
/// <c>.lrc</c> 侧车歌词读取结果（分层：原文 / 译文 / 音译）。
/// </summary>
public sealed class LrcContent
{
    /// <summary>是否存在同名侧车（主 <c>.lrc</c> 或 <c>.trans.lrc</c> / <c>.romaji.lrc</c>）。</summary>
    public bool Exists { get; init; }

    /// <summary>
    /// **原文层**：去时间轴 / 标签后的纯文本行（以 <c>\n</c> 连接）；无原文时为空串。
    /// 时间轴分组下取每组第 1 行，非 LRC 纯文本整体归此层。
    /// </summary>
    public string Original { get; init; } = "";

    /// <summary>**译文层**（以 <c>\n</c> 连接）；无译文时为空串。</summary>
    public string Translation { get; init; } = "";

    /// <summary>**音译 / 罗马音层**（以 <c>\n</c> 连接）；无音译时为空串。</summary>
    public string Romaji { get; init; } = "";

    /// <summary>原文层别名（等价 <see cref="Original"/>，保留既有字段语义）。</summary>
    public string Text => Original;

    /// <summary>侧车 mtime（Unix 毫秒，取各侧车最大）；不存在时为 0。</summary>
    public long Mtime { get; init; }

    /// <summary>侧车字节大小（各侧车求和）；不存在时为 0。</summary>
    public long Size { get; init; }

    /// <summary>原文层有效文本行数。</summary>
    public int LineCount { get; init; }
}

/// <summary>
/// <c>.lrc</c> 侧车读取与**三层拆分**（原文 / 译文 / 音译；设计文档 §4.3 / §4.4）。
///
/// 约定（大小写不敏感）：主侧车与音频**同目录、同 basename** 的 <c>.lrc</c>；
/// 另识别显式分层侧车 <c>&lt;name&gt;.trans.lrc</c>（译文）/ <c>&lt;name&gt;.romaji.lrc</c>（音译）。
///
/// 分层启发式（保守，确定性；不覆盖时对应层为空）：
/// <list type="bullet">
///   <item>解析主 <c>.lrc</c> 为有序 <c>(时间戳, 文本)</c> 条目；**相同时间戳的连续多行**
///         视为同一条目多层：第 1 行 → 原文，其后按位置 第 2 行 → 译文 / 第 3 行 → 音译；
///         若第 2 行纯拉丁而第 3 行非拉丁则对调；仅一行时按是否纯拉丁判为音译 / 译文；</item>
///   <item>显式侧车存在时其文本行**直接进入**对应层（替换内嵌推断）；</item>
///   <item>无时间轴的纯文本（非 LRC）整体作为原文；无译文 / 音译则对应层空串。</item>
/// </list>
/// 原文层**不回退**：只取每组第 1 行 + 无时间轴行，绝不把译文 / 音译混入原文
/// （避免检索语义混淆，见报告风险）。
///
/// 编码识别顺序：BOM（UTF-8 / UTF-16 LE / BE）→ 无 BOM 时严格 UTF-8 试解码 →
/// .NET 框架内置 CodePages 的 **GB18030** 解码（覆盖 GBK / GB18030，含 4 字节序列）；
/// 解码失败回退 UTF-8 替换（不崩溃）。
/// </summary>
public static class LrcReader
{
    /// <summary>侧车探测结果（不读取内容；用于脏集判定；聚合主 / 译文 / 音译三层侧车）。</summary>
    public readonly record struct LrcProbe(bool Exists, string? Path, long Mtime, long Size)
    {
        /// <summary>无侧车。</summary>
        public static readonly LrcProbe None = new(false, null, 0, 0);
    }

    /// <summary>匹配 LRC 方括号标签（时间轴 / 元数据），如 <c>[00:12.34]</c>、<c>[by:foo]</c>。</summary>
    private static readonly Regex TagRegex = new(@"\[[^\]]*\]", RegexOptions.Compiled);

    /// <summary>匹配 LRC 时间轴标签，如 <c>[00:12.34]</c> / <c>[1:02]</c>（用于同时间戳分组）。</summary>
    private static readonly Regex TimeRegex =
        new(@"\[\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?\]", RegexOptions.Compiled);

    /// <summary>解析后的单条 LRC 条目：时间戳标签原文（无时间轴时为 <c>null</c>）+ 文本。</summary>
    private readonly record struct LrcEntry(string? Timestamp, string Text);

    /// <summary>文本拆分后的三层（空层为空串）。供内嵌歌词与 <c>.lrc</c> 共用同一启发式。</summary>
    public readonly record struct LrcLayers(string Original, string Translation, string Romaji)
    {
        /// <summary>三空层。</summary>
        public static readonly LrcLayers Empty = new("", "", "");
    }

    /// <summary>
    /// 把**原始歌词文本**（内嵌 <c>tracks.lyrics</c> 或 <c>.lrc</c> 内容）按 §4.3 启发式
    /// 拆为原文 / 译文 / 音译三层；内嵌与侧车共用同一实现（保证语义一致）。
    /// 无时间轴的纯文本整体归原文；无法判定的层为空串。
    /// </summary>
    public static LrcLayers SplitText(string raw)
    {
        if (string.IsNullOrEmpty(raw)) return LrcLayers.Empty;
        var originals = new List<string>();
        var trans = new List<string>();
        var romaji = new List<string>();
        SplitLayers(ExtractEntries(raw), originals, trans, romaji);
        return new LrcLayers(
            string.Join('\n', originals),
            string.Join('\n', trans),
            string.Join('\n', romaji));
    }

    /// <summary>
    /// 探测音频对应的侧车（仅 stat mtime/size，不读内容）。聚合主 <c>.lrc</c> 与
    /// <c>.trans.lrc</c> / <c>.romaji.lrc</c>：<see cref="LrcProbe.Exists"/> 为「任一存在」，
    /// <c>Mtime</c> 取最大、<c>Size</c> 求和，使任一层侧车变动都能被脏集识别。
    /// 无任何侧车返回 <see cref="LrcProbe.None"/>。
    /// </summary>
    public static LrcProbe Probe(string audioPath)
    {
        var (main, trans, romaji) = FindSidecars(audioPath);
        bool exists = false;
        string? first = null;
        long mtime = 0, size = 0;
        foreach (var path in new[] { main, trans, romaji })
        {
            if (path is null) continue;
            try
            {
                var info = new FileInfo(path);
                if (!info.Exists) continue;
                exists = true;
                first ??= path;
                var m = new DateTimeOffset(info.LastWriteTimeUtc).ToUnixTimeMilliseconds();
                if (m > mtime) mtime = m;
                size += info.Length;
            }
            catch
            {
                // 单个 stat 失败不影响其它侧车的判定
            }
        }
        return exists ? new LrcProbe(true, first, mtime, size) : LrcProbe.None;
    }

    /// <summary>
    /// 读取音频路径对应的侧车歌词并**分三层**；不存在任何侧车时返回
    /// <see cref="LrcContent.Exists"/>=false（其余层为空串）。
    /// </summary>
    public static LrcContent Read(string audioPath)
    {
        var probe = Probe(audioPath);
        if (!probe.Exists) return new LrcContent { Exists = false };

        var (main, trans, romaji) = FindSidecars(audioPath);

        // 主 .lrc：按同时间戳多层启发式拆分；显式分层侧车存在时替换对应层。
        var layers = main is not null && TryDecode(main) is { } raw
            ? SplitText(raw)
            : LrcLayers.Empty;

        var original = layers.Original;
        var translation = trans is not null ? JoinLines(TryDecodeLines(trans)) : layers.Translation;
        var romanized = romaji is not null ? JoinLines(TryDecodeLines(romaji)) : layers.Romaji;

        return new LrcContent
        {
            Exists = true,
            Original = original,
            Translation = translation,
            Romaji = romanized,
            Mtime = probe.Mtime,
            Size = probe.Size,
            LineCount = original.Length == 0 ? 0 : original.Split('\n').Length,
        };
    }

    /// <summary>
    /// 定位主 <c>.lrc</c>（大小写不敏感）。为确定性，命中多个时取文件名序最小者。
    /// 目录不存在 / 无法枚举时返回 <c>null</c>。
    /// </summary>
    public static string? FindSidecar(string audioPath) => FindSidecars(audioPath).Main;

    /// <summary>
    /// 一次性枚举目录，返回（主 <c>&lt;stem&gt;.lrc</c> / 译文 <c>&lt;stem&gt;.trans.lrc</c> /
    /// 音译 <c>&lt;stem&gt;.romaji.lrc</c>），均大小写不敏感。每类命中多个时取文件名序最小者。
    /// 目录不存在 / 无法枚举时返回全 <c>null</c>。
    /// </summary>
    private static (string? Main, string? Trans, string? Romaji) FindSidecars(string audioPath)
    {
        var directory = Path.GetDirectoryName(audioPath);
        if (string.IsNullOrEmpty(directory) || !Directory.Exists(directory)) return (null, null, null);

        var stem = Path.GetFileNameWithoutExtension(audioPath);
        if (string.IsNullOrEmpty(stem)) return (null, null, null);

        List<string> files;
        try
        {
            files = Directory.EnumerateFiles(directory)
                .Where(f => string.Equals(Path.GetExtension(f), ".lrc", StringComparison.OrdinalIgnoreCase))
                .OrderBy(f => Path.GetFileName(f), StringComparer.Ordinal)
                .ToList();
        }
        catch (Exception ex)
        {
            Log.LogWarn("indexer", $"枚举目录失败 {directory}: {ex.Message}");
            return (null, null, null);
        }

        string? main = null, trans = null, romaji = null;
        foreach (var file in files)
        {
            var name = Path.GetFileNameWithoutExtension(file);
            if (main is null && string.Equals(name, stem, StringComparison.OrdinalIgnoreCase))
                main = file;
            else if (trans is null && string.Equals(name, stem + ".trans", StringComparison.OrdinalIgnoreCase))
                trans = file;
            else if (romaji is null && string.Equals(name, stem + ".romaji", StringComparison.OrdinalIgnoreCase))
                romaji = file;
        }
        return (main, trans, romaji);
    }

    /// <summary>剥离方括号标签与空行，返回纯文本行。</summary>
    private static List<string> ExtractTextLines(string raw)
    {
        var lines = new List<string>();
        foreach (var rawLine in raw.Split('\n'))
        {
            var line = TagRegex.Replace(rawLine.TrimEnd('\r'), " ").Trim();
            if (line.Length > 0) lines.Add(line);
        }
        return lines;
    }

    /// <summary>解析为有序条目：文本 = 剥离**所有**方括号标签后 trim；空文本行丢弃。</summary>
    private static List<LrcEntry> ExtractEntries(string raw)
    {
        var entries = new List<LrcEntry>();
        foreach (var rawLine in raw.Split('\n'))
        {
            var line = rawLine.TrimEnd('\r');
            var text = TagRegex.Replace(line, " ").Trim();
            if (text.Length == 0) continue;
            var match = TimeRegex.Match(line);
            entries.Add(new LrcEntry(match.Success ? match.Value : null, text));
        }
        return entries;
    }

    /// <summary>
    /// 顺序条目 → 三层：**相同时间戳的连续行**归为同一条目多层；无时间戳行各自为原文。
    /// 原文只取每组第 1 行（不回退）。
    /// </summary>
    private static void SplitLayers(
        List<LrcEntry> entries, List<string> originals, List<string> trans, List<string> romaji)
    {
        var i = 0;
        while (i < entries.Count)
        {
            var entry = entries[i];
            if (entry.Timestamp is null)
            {
                originals.Add(entry.Text);
                i++;
                continue;
            }

            var group = new List<string> { entry.Text };
            var j = i;
            while (j + 1 < entries.Count && entries[j + 1].Timestamp == entry.Timestamp)
            {
                j++;
                group.Add(entries[j].Text);
            }
            ClassifyGroup(group, originals, trans, romaji);
            i = j + 1;
        }
    }

    /// <summary>
    /// 单条时间戳分组 → 层：第 1 行原文；后两行按位置 第 2 行译文 / 第 3 行音译。
    /// 修正：若第 2 行为纯拉丁且第 3 行非拉丁，则二者对调（纯拉丁更可能是音译）。
    /// 组内仅 1 行时按纯拉丁否判为音译 / 译文。
    /// </summary>
    private static void ClassifyGroup(
        List<string> group, List<string> originals, List<string> trans, List<string> romaji)
    {
        originals.Add(group[0]);
        if (group.Count < 2) return;

        var rest = group.GetRange(1, group.Count - 1);
        if (rest.Count == 1)
        {
            if (IsLatinLine(rest[0])) romaji.Add(rest[0]);
            else trans.Add(rest[0]);
            return;
        }

        if (IsLatinLine(rest[0]) && !IsLatinLine(rest[1]))
        {
            romaji.Add(rest[0]);
            trans.Add(rest[1]);
        }
        else
        {
            trans.Add(rest[0]);
            romaji.Add(rest[1]);
        }
    }

    /// <summary>纯拉丁行（含字母、不含任何 CJK 字符）——音译 / 罗马音的保守判定。</summary>
    private static bool IsLatinLine(string text)
    {
        var hasLetter = false;
        foreach (var ch in text)
        {
            if (Analyzer.IsCjk(ch)) return false;
            if (char.IsLetter(ch)) hasLetter = true;
        }
        return hasLetter;
    }

    /// <summary>解码失败返回 <c>null</c>（记录告警，不抛）。</summary>
    private static string? TryDecode(string path)
    {
        try { return Decode(path); }
        catch (Exception ex)
        {
            Log.LogWarn("indexer", $"读取 .lrc 失败 {path}: {ex.Message}");
            return null;
        }
    }

    /// <summary>解码并取文本行；解码失败返回空列表（不抛）。</summary>
    private static List<string> TryDecodeLines(string path)
        => TryDecode(path) is { } raw ? ExtractTextLines(raw) : new List<string>();

    private static string JoinLines(List<string> lines) => string.Join('\n', lines);

    /// <summary>
    /// 解码：先按 BOM 识别 UTF-8 / UTF-16 LE|BE；无 BOM 时先做**严格 UTF-8 试解码**
    /// （含非法序列即失败），失败则走 .NET 框架内置 CodePages 的 GB18030 解码
    /// （覆盖 GBK / GB18030，含 4 字节序列），最终以 UTF-8 替换
    /// （非法字节替换为 <c>U+FFFD</c>，不抛异常）兜底。
    /// </summary>
    private static string Decode(string path)
    {
        var bytes = File.ReadAllBytes(path);
        if (bytes.Length == 0) return string.Empty;

        // 1) BOM：UTF-8 / UTF-16 LE / BE（剥掉 BOM 后按对应编码解码）。
        if (bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF)
            return Encoding.UTF8.GetString(bytes, 3, bytes.Length - 3);
        if (bytes.Length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE)
            return Encoding.Unicode.GetString(bytes, 2, bytes.Length - 2);
        if (bytes.Length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF)
            return Encoding.BigEndianUnicode.GetString(bytes, 2, bytes.Length - 2);

        // 2) 无 BOM：严格 UTF-8 试解码（非法序列抛 DecoderFallbackException）。
        try { return StrictUtf8.GetString(bytes); }
        catch (DecoderFallbackException) { /* 非 UTF-8，继续尝试 GB18030 */ }

        // 3) GB18030 / GBK 解码（框架 CodePages）。
        if (TryDecodeGb18030(bytes, out var gb18030)) return gb18030;

        // 4) 兜底：UTF-8 替换（合法字节照常、非法字节变 U+FFFD，不崩溃）。
        return ReplacingUtf8.GetString(bytes);
    }

    /// <summary>严格 UTF-8 解码器（禁用替换，非法序列即抛异常）。</summary>
    private static readonly UTF8Encoding StrictUtf8 =
        new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);

    /// <summary>宽松 UTF-8 解码器（非法字节替换为 U+FFFD）。</summary>
    private static readonly UTF8Encoding ReplacingUtf8 =
        new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: false);

    /// <summary>
    /// GB18030 解码器（框架 CodePages）。首次访问时注册
    /// <see cref="CodePagesEncodingProvider"/>（幂等、进程级一次）；
    /// 非法字节以 <c>U+FFFD</c> 替换（与既有语义一致），4 字节序列由框架正确解码。
    /// </summary>
    private static readonly Encoding Gb18030 = CreateGb18030();

    private static Encoding CreateGb18030()
    {
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
        return Encoding.GetEncoding(
            "GB18030",
            EncoderFallback.ReplacementFallback,
            DecoderFallback.ReplacementFallback);
    }

    /// <summary>
    /// GB18030 / GBK 解码（框架 CodePages，按字节走，不抛异常）。空输入返回 <c>false</c>；
    /// 否则解码（非法字节 → <c>U+FFFD</c>）并返回 <c>true</c>。
    /// </summary>
    public static bool TryDecodeGb18030(ReadOnlySpan<byte> bytes, out string text)
    {
        if (bytes.Length == 0)
        {
            text = string.Empty;
            return false;
        }

        text = Gb18030.GetString(bytes);
        return true;
    }
}
