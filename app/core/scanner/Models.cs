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
/// AOT 安全的 JSON 序列化上下文（source-gen）。
///
/// NativeAOT 共享库（scanner-ffi）下 System.Text.Json 反射序列化不可用，
/// 必须使用 source-gen 上下文。命名/忽略策略与原反射配置一致：
/// 小驼峰、不缩进、忽略 null；LongTimestampConverter 通过属性级
/// [JsonConverter] 标注参与生成。
/// </summary>
[JsonSourceGenerationOptions(
    PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase,
    WriteIndented = false,
    DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull)]
[JsonSerializable(typeof(TrackMetadata))]
[JsonSerializable(typeof(ScanProgress))]
[JsonSerializable(typeof(ScanResult))]
[JsonSerializable(typeof(string[]))]
[JsonSerializable(typeof(ArtistRef))]
[JsonSerializable(typeof(AlbumRef))]
[JsonSerializable(typeof(List<ArtistRef>))]
public sealed partial class ScannerJsonContext : JsonSerializerContext
{
}
