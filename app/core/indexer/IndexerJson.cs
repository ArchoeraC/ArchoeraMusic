// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

using System.Buffers;
using System.Text;
using System.Text.Json;

namespace Archoera.Indexer;

/// <summary>索引器运行选项（对齐 FFI <c>options_json</c>）。</summary>
public sealed class IndexerOptions
{
    /// <summary>是否索引 <c>.lrc</c> 侧车歌词（默认 false，设计文档 §4.4）。</summary>
    public bool IndexLrc { get; set; }

    /// <summary>是否生成拼音列（默认 true；false 时 <c>pinyin_tok</c> 留空，供 §7.4 A/B）。</summary>
    public bool Pinyin { get; set; } = true;

    /// <summary>
    /// 是否为日语歌词生成罗马音（T2-9 可选增强，默认 false）。
    ///
    /// 仅在**没有 LRC 音译层**时生效：把已有分析结果里的歌词读音 bigram 落进
    /// <c>lyrics_rom_tok</c>，使罗马字查询可命中歌词。歌词读音体积约为原文的 2×，
    /// 故默认关闭、由用户在设置里显式开启。
    /// </summary>
    public bool RomajiLyrics { get; set; }

    /// <summary>内部批量事务条数（0 = 使用存储默认）。</summary>
    public int Batch { get; set; }

    /// <summary>累计改写多少首曲目后触发 FTS5 全段合并（见 <see cref="StoreMeta.UpdatesSinceMerge"/>）。</summary>
    ///
    /// <remarks>
    /// 合并是 O(索引) 的全库重写（402MB 实测 4.5–13s），**与脏曲数无关**——只改 1 首也要付全额。
    /// 而跳过合并会让 `contentless_delete` 的墓碑累积、查询随之退化（实测 `爱你`：20 曲 +34%、
    /// 60 曲 +73%、120 曲 +103%）。默认 30 是两者之间的折中：常态增量只写不合并（亚秒级），
    /// 累计约 30 首后的一次增量顺带合并，把查询退化压在 ~±40% 以内。
    /// 测试可调小以验证计数与触发。
    /// </remarks>
    public int MergeEveryUpdates { get; set; } = DefaultMergeEveryUpdates;

    /// <summary>合并阈值默认值（见 <see cref="MergeEveryUpdates"/>）。</summary>
    public const int DefaultMergeEveryUpdates = 30;
}

/// <summary>索引进度（stdout JSON / FFI 回调共用）。</summary>
public sealed class IndexerProgress
{
    public string Type { get; set; } = "progress";

    /// <summary>阶段：<c>collect</c> | <c>index</c> | <c>delete</c> | <c>commit</c>。</summary>
    public string Phase { get; set; } = "index";

    public int Total { get; set; }
    public int Processed { get; set; }
    public int Indexed { get; set; }
    public int Deleted { get; set; }
    public string Current { get; set; } = "";
}

/// <summary>索引结果摘要（stdout JSON / FFI 回参共用）。</summary>
public sealed class IndexerResult
{
    public string Type { get; set; } = "done";
    public int Total { get; set; }
    public int Indexed { get; set; }
    public int Deleted { get; set; }
    public int Skipped { get; set; }
    public bool Full { get; set; }
    public long Generation { get; set; }
    public long DurationMs { get; set; }

    /// <summary>
    /// 本次是否执行了 FTS5 全段合并（`optimize`）。合并是 O(索引) 的全库重写，
    /// 会是增量耗时的主要构成——报告/诊断据此区分「写路径慢」与「合并慢」。
    /// </summary>
    public bool Merged { get; set; }

    /// <summary>本次结束后距下次合并还累计了多少首改写（见 <see cref="StoreMeta.UpdatesSinceMerge"/>）。</summary>
    public int UpdatesSinceMerge { get; set; }
}

/// <summary>
/// 手写 JSON 序列化（AOT 安全、无源生成依赖），风格与 scanner 的 <c>ScannerJson</c> 一致。
/// </summary>
internal static class IndexerJson
{
    private static string Write(Action<Utf8JsonWriter> body)
    {
        var buffer = new ArrayBufferWriter<byte>();
        using var writer = new Utf8JsonWriter(buffer, new JsonWriterOptions { Indented = false });
        body(writer);
        writer.Flush();
        return Encoding.UTF8.GetString(buffer.WrittenSpan);
    }

    public static string Analysis(AnalysisResult result) => Write(w =>
    {
        w.WriteStartObject();
        w.WriteString("tokens", result.Tokens);
        w.WriteString("pinyin", result.Pinyin);
        w.WriteString("initials", result.PinyinInitials);
        w.WriteEndObject();
    });

    /// <summary>
    /// 查询侧分析结果（<see cref="Analyzer.AnalyzeQuery"/>）序列化：与索引侧同形
    /// （空格分隔的 <c>tokens</c> / <c>pinyin</c> / <c>initials</c>），供 Dart 的
    /// <c>indexer_analyze</c> 取得含连写全拼切分的词元；另附 <c>defs</c> = 空格连接的
    /// 跨语言候选（<see cref="QueryTokens.CrossLingual"/>，T1，Unihan 释义扩展）。
    /// </summary>
    public static string Analysis(QueryTokens query) => Write(w =>
    {
        w.WriteStartObject();
        w.WriteString("tokens", string.Join(' ', query.Lexical));
        w.WriteString("pinyin", string.Join(' ', query.Pinyin));
        w.WriteString("initials", query.PinyinInitials ?? string.Empty);
        w.WriteString("defs", string.Join(' ', query.CrossLingual));
        w.WriteEndObject();
    });

    public static string Version(int analyzerVersion) => Write(w =>
    {
        w.WriteStartObject();
        w.WriteNumber("analyzerVersion", analyzerVersion);
        w.WriteEndObject();
    });

    public static string Progress(IndexerProgress p) => Write(w =>
    {
        w.WriteStartObject();
        w.WriteString("type", p.Type);
        w.WriteString("phase", p.Phase);
        w.WriteNumber("total", p.Total);
        w.WriteNumber("processed", p.Processed);
        w.WriteNumber("indexed", p.Indexed);
        w.WriteNumber("deleted", p.Deleted);
        w.WriteString("current", p.Current);
        w.WriteEndObject();
    });

    public static string Result(IndexerResult r) => Write(w =>
    {
        w.WriteStartObject();
        w.WriteString("type", r.Type);
        w.WriteNumber("total", r.Total);
        w.WriteNumber("indexed", r.Indexed);
        w.WriteNumber("deleted", r.Deleted);
        w.WriteNumber("skipped", r.Skipped);
        w.WriteBoolean("full", r.Full);
        w.WriteNumber("generation", r.Generation);
        w.WriteNumber("durationMs", r.DurationMs);
        w.WriteBoolean("merged", r.Merged);
        w.WriteNumber("updatesSinceMerge", r.UpdatesSinceMerge);
        w.WriteEndObject();
    });

    /// <summary>
    /// 查询层（<see cref="SearchSession"/>）结果序列化：<c>items</c> 为按趟次合并去重后的
    /// top-k（含 <c>trackId</c> / bm25 <c>score</c>），<c>passes</c> 记录本次实际执行的兜底趟。
    /// </summary>
    public static string QueryResult(SearchResult result) => Write(w =>
    {
        w.WriteStartObject();
        w.WriteString("type", "result");
        w.WriteNumber("count", result.Items.Count);
        w.WritePropertyName("items");
        w.WriteStartArray();
        foreach (var hit in result.Items)
        {
            w.WriteStartObject();
            w.WriteString("trackId", hit.TrackId);
            w.WriteNumber("score", hit.Score);
            w.WriteEndObject();
        }
        w.WriteEndArray();
        w.WritePropertyName("passes");
        w.WriteStartObject();
        w.WriteNumber("pinyinLoose", result.Passes.PinyinLoose);
        w.WriteNumber("reading", result.Passes.Reading);
        w.WriteNumber("crossLingual", result.Passes.CrossLingual);
        w.WriteNumber("fuzzy", result.Passes.Fuzzy);
        w.WriteNumber("cjkFuzzy", result.Passes.CjkFuzzy);
        w.WriteEndObject();
        w.WriteEndObject();
    });

    public static string SearchResults(
        IReadOnlyList<(long DocId, double Score)> rows, IReadOnlyDictionary<long, string> trackIds) => Write(w =>
    {
        w.WriteStartObject();
        w.WriteString("type", "result");
        w.WriteNumber("count", rows.Count);
        w.WritePropertyName("items");
        w.WriteStartArray();
        foreach (var (docId, score) in rows)
        {
            w.WriteStartObject();
            w.WriteNumber("docId", docId);
            if (trackIds.TryGetValue(docId, out var trackId)) w.WriteString("trackId", trackId);
            w.WriteNumber("score", score);
            w.WriteEndObject();
        }
        w.WriteEndArray();
        w.WriteEndObject();
    });
}
