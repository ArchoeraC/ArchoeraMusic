// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

using System.Buffers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Archoera.Scanner;

/// <summary>
/// 宽松 long JSON 转换器：同时接受整数和浮点数值，四舍五入为 long。
/// 用于处理 TS 端 fs.statSync().mtimeMs 返回的浮点毫秒时间戳。
/// </summary>
public sealed class LongTimestampConverter : JsonConverter<long>
{
    public override long Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType == JsonTokenType.Number)
        {
            if (reader.TryGetInt64(out var l)) return l;
            if (reader.TryGetDouble(out var d)) return (long)Math.Round(d);
        }
        if (reader.TokenType == JsonTokenType.String && long.TryParse(reader.GetString(), out var parsed))
            return parsed;
        throw new JsonException($"无法将 {reader.TokenType} 转换为 long");
    }

    public override void Write(Utf8JsonWriter writer, long value, JsonSerializerOptions options)
        => writer.WriteNumberValue(value);
}

/// <summary>
/// 曲目元数据（对应 TS 层 UpsertTrack）
/// </summary>
public sealed class TrackMetadata
{
    public string Id { get; set; } = "";
    public string Path { get; set; } = "";
    public string Title { get; set; } = "";
    public int? Track { get; set; }
    public List<ArtistRef> Artists { get; set; } = new();
    public AlbumRef? Album { get; set; }
    public long Duration { get; set; } // 毫秒
    public string? Cover { get; set; } // HTTP 路由 URL
    public string? Codec { get; set; }
    public int? SampleRate { get; set; }
    public int? BitRate { get; set; }
    public int? Channels { get; set; }
    public int? BitsPerSample { get; set; }
    public long FileSize { get; set; }
    [JsonConverter(typeof(LongTimestampConverter))]
    public long Mtime { get; set; } // 毫秒
    [JsonConverter(typeof(LongTimestampConverter))]
    public long Ctime { get; set; } // 毫秒
    public string? Lyrics { get; set; }
}

public sealed class ArtistRef
{
    [JsonPropertyName("name")]
    public string Name { get; set; } = "";
}

public sealed class AlbumRef
{
    [JsonPropertyName("name")]
    public string Name { get; set; } = "";
    [JsonPropertyName("year")]
    public int? Year { get; set; }
    [JsonPropertyName("artist")]
    public string? Artist { get; set; }
}

public readonly record struct ErrorFileState(int FailCount, long MtimeAtLastFail);

/// <summary>
/// 扫描进度（通过 stdout JSON 输出给 TS 层）
/// </summary>
public sealed class ScanProgress
{
    [JsonPropertyName("type")]
    public string Type { get; set; } = "progress";
    [JsonPropertyName("scanning")]
    public bool Scanning { get; set; }
    [JsonPropertyName("scanned")]
    public int Scanned { get; set; }
    [JsonPropertyName("total")]
    public int Total { get; set; }
    [JsonPropertyName("current")]
    public string Current { get; set; } = "";
    [JsonPropertyName("upserted")]
    public int Upserted { get; set; }
    [JsonPropertyName("errors")]
    public int Errors { get; set; }
    /// <summary>被永久隔离的损坏文件数</summary>
    [JsonPropertyName("trained")]
    public int Trained { get; set; }
    /// <summary>扫描开始时间戳（毫秒），仅日志用，不序列化</summary>
    [JsonIgnore]
    public long StartedAt { get; set; }
}

/// <summary>
/// 扫描结果摘要
/// </summary>
public sealed class ScanResult
{
    [JsonPropertyName("type")]
    public string Type { get; set; } = "done";
    [JsonPropertyName("total")]
    public int Total { get; set; }
    [JsonPropertyName("scanned")]
    public int Scanned { get; set; }
    [JsonPropertyName("upserted")]
    public int Upserted { get; set; }
    [JsonPropertyName("deleted")]
    public int Deleted { get; set; }
    [JsonPropertyName("canceled")]
    public bool Canceled { get; set; }
    [JsonPropertyName("errors")]
    public int Errors { get; set; }
    /// <summary>被永久隔离的损坏文件数（ScanResult）</summary>
    [JsonPropertyName("trained")]
    public int Trained { get; set; }
}

/// <summary>
/// 手写 JSON 序列化（AOT 安全、无源生成依赖）。
///
/// 原 System.Text.Json source-gen 上下文（ScannerJsonContext）在部分 IDE/设计时
/// 构建下未被源生成器处理 → 报「未实现抽象成员 / 缺 Default」的假错。改为直接
/// Utf8JsonWriter/JsonDocument：语义与旧上下文一致（小驼峰、不缩进、忽略 null），
/// 且 NativeAOT 完全安全、IDE 无源生成器也可编译。
/// </summary>
public static class ScannerJson
{
    private static string Write(Action<Utf8JsonWriter> body)
    {
        var buf = new ArrayBufferWriter<byte>();
        using var w = new Utf8JsonWriter(buf, new JsonWriterOptions { Indented = false });
        body(w);
        w.Flush();
        return Encoding.UTF8.GetString(buf.WrittenSpan);
    }

    private static void WriteArtist(Utf8JsonWriter w, ArtistRef a)
    {
        w.WriteStartObject();
        w.WriteString("name", a.Name);
        w.WriteEndObject();
    }

    private static void WriteAlbum(Utf8JsonWriter w, AlbumRef a)
    {
        w.WriteStartObject();
        w.WriteString("name", a.Name);
        if (a.Year.HasValue) w.WriteNumber("year", a.Year.Value);
        if (a.Artist != null) w.WriteString("artist", a.Artist);
        w.WriteEndObject();
    }

    public static string ArtistRefs(List<ArtistRef> artists) => Write(w =>
    {
        w.WriteStartArray();
        foreach (var a in artists) WriteArtist(w, a);
        w.WriteEndArray();
    });

    public static string Album(AlbumRef a) => Write(w => WriteAlbum(w, a));

    public static string Track(TrackMetadata t) => Write(w =>
    {
        w.WriteStartObject();
        w.WriteString("id", t.Id);
        w.WriteString("path", t.Path);
        w.WriteString("title", t.Title);
        if (t.Track.HasValue) w.WriteNumber("track", t.Track.Value);
        w.WritePropertyName("artists");
        w.WriteStartArray();
        foreach (var a in t.Artists) WriteArtist(w, a);
        w.WriteEndArray();
        if (t.Album != null)
        {
            w.WritePropertyName("album");
            WriteAlbum(w, t.Album);
        }
        w.WriteNumber("duration", t.Duration);
        if (t.Cover != null) w.WriteString("cover", t.Cover);
        if (t.Codec != null) w.WriteString("codec", t.Codec);
        if (t.SampleRate.HasValue) w.WriteNumber("sampleRate", t.SampleRate.Value);
        if (t.BitRate.HasValue) w.WriteNumber("bitRate", t.BitRate.Value);
        if (t.Channels.HasValue) w.WriteNumber("channels", t.Channels.Value);
        if (t.BitsPerSample.HasValue) w.WriteNumber("bitsPerSample", t.BitsPerSample.Value);
        w.WriteNumber("fileSize", t.FileSize);
        w.WriteNumber("mtime", t.Mtime);
        w.WriteNumber("ctime", t.Ctime);
        if (t.Lyrics != null) w.WriteString("lyrics", t.Lyrics);
        w.WriteEndObject();
    });

    public static string Progress(ScanProgress p) => Write(w =>
    {
        w.WriteStartObject();
        w.WriteString("type", p.Type);
        w.WriteBoolean("scanning", p.Scanning);
        w.WriteNumber("scanned", p.Scanned);
        w.WriteNumber("total", p.Total);
        w.WriteString("current", p.Current);
        w.WriteNumber("upserted", p.Upserted);
        w.WriteNumber("errors", p.Errors);
        w.WriteNumber("trained", p.Trained);
        w.WriteNumber("startedAt", p.StartedAt);
        w.WriteEndObject();
    });

    public static string Result(ScanResult r) => Write(w =>
    {
        w.WriteStartObject();
        w.WriteString("type", r.Type);
        w.WriteNumber("total", r.Total);
        w.WriteNumber("scanned", r.Scanned);
        w.WriteNumber("upserted", r.Upserted);
        w.WriteNumber("deleted", r.Deleted);
        w.WriteBoolean("canceled", r.Canceled);
        w.WriteNumber("errors", r.Errors);
        w.WriteNumber("trained", r.Trained);
        w.WriteEndObject();
    });

    /// <summary>解析 string[] JSON；失败/非数组 → 单元素回退（与旧行为一致）</summary>
    public static List<string> ParseStringArray(string text)
    {
        try
        {
            using var doc = JsonDocument.Parse(text);
            if (doc.RootElement.ValueKind == JsonValueKind.Array)
            {
                var list = new List<string>();
                foreach (var el in doc.RootElement.EnumerateArray())
                    list.Add(el.GetString() ?? "");
                return list;
            }
        }
        catch
        {
            // fallthrough → 单元素回退
        }
        return new List<string> { text };
    }
}
