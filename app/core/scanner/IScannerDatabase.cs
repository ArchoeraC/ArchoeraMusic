using System.Collections.Concurrent;

namespace Archoera.Scanner;

/// <summary>
/// 扫描器数据库操作抽象
/// </summary>
public interface IScannerDatabase
{
    /// <summary>批量 upsert 曲目</summary>
    Task UpsertTracksAsync(List<TrackMetadata> tracks, CancellationToken ct = default);

    /// <summary>
    /// 加载所有曲目的快照（path → (mtime, size)），用于增量扫描比对。
    /// 快照中的残留 = 磁盘已删除的文件，由调用方负责清理。
    /// </summary>
    Task<ConcurrentDictionary<string, (long Mtime, long Size)>> LoadTrackSnapshotAsync(CancellationToken ct = default);

    /// <summary>删除指定路径列表的曲目</summary>
    Task<int> DeleteTracksByPathsAsync(List<string> paths, CancellationToken ct = default);

    /// <summary>清空所有曲目记录（全量扫描用）</summary>
    Task ClearAllTracksAsync(CancellationToken ct = default);

    /// <summary>记录文件解析失败</summary>
    Task RecordParseErrorAsync(string path, string errorMessage, CancellationToken ct = default);

    /// <summary>检查文件是否应跳过（连续失败超限）</summary>
    Task<bool> ShouldSkipErrorFileAsync(string path, long currentMtimeMs, CancellationToken ct = default);

    /// <summary>一次性加载所有达到隔离阈值的错误路径集合，供并行循环内存查询</summary>
    Task<HashSet<string>> LoadErrorSnapshotAsync(CancellationToken ct = default);

    /// <summary>清除所有错误记录（全量扫描时调用）</summary>
    Task ClearParseErrorsAsync(CancellationToken ct = default);

    /// <summary>删除指定路径的错误记录（隔离后清理用）</summary>
    Task<int> DeleteParseErrorsByPathsAsync(List<string> paths, CancellationToken ct = default);

    /// <summary>标记文件为待隔离（trained），扫描完成后由引擎统一移动</summary>
    Task MarkTrainedAsync(string path, CancellationToken ct = default);

    /// <summary>获取所有待隔离的文件路径</summary>
    Task<List<string>> GetTrainedPathsAsync(CancellationToken ct = default);

    /// <summary>清空待隔离表（隔离完成后调用）</summary>
    Task ClearTrainedAsync(CancellationToken ct = default);

    /// <summary>等待所有挂起的写操作持久化（隔离等需要读取最新数据的阶段前调用）</summary>
    Task FlushAsync(CancellationToken ct = default);
}
