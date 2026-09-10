// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using TagLibFile = TagLib.File;

namespace Archoera.Scanner;

/// <summary>
/// 扫描引擎核心
///
/// 职责：
/// 1. 递归收集目录下的音频文件（带安全限制，自动去重）
/// 2. 全量/增量分流：全量清空重建，增量加载快照到内存
/// 3. 用 TagLibSharp 并行解析元数据 + 提取封面 + 提取歌词
/// 4. 有界队列批量写入 SQLite（直写）
/// 5. 快照残留清理（已从磁盘删除的曲目）
/// 6. trained 文件统一移入 quarantine 目录
/// 7. 通过 stdout 输出 JSON 进度（TS 层监听）
///
/// 崩溃安全：
///   - _scanner_errors 表持久化失败计数，crash 后不丢失"已知坏文件"状态
///   - _scanner_trained 表持久化待隔离标记，crash 后扫描引擎重启时可继续
/// </summary>
public sealed class ScannerEngine
{
    /// <summary>支持的音频扩展名（小写，无点）</summary>
    /// <remarks>
    /// 2026-09-04 扩容：wma/mka/mpc/mpp/mp2/aifc——均为「内核可自研解码」
    /// 且 TagLibSharp 2.3.0 实测可提元数据/时长（见 docs/format-support-matrix.md §2）。
    /// 注：tta/asf/mp1/dts/ac3/mlp/amr/awb/latm/caf/au/w64 内核可解但 TagLib 无元数据，
    /// 若需收录须走「内核 Info 兜底」（产品决策项），暂不进白名单。
    /// </remarks>
    private static readonly HashSet<string> AudioExt = new(StringComparer.OrdinalIgnoreCase)
    {
        "mp3", "flac", "ogg", "opus", "oga", "m4a", "aac", "wav",
        "ape", "wv", "dsf", "dsd", "dff", "mp4", "aiff", "aif",
        // 2026-09-04：自研解码族（TagLib 实测可提元数据）
        "wma", "mka", "mpc", "mpp", "mp+", "mp2", "aifc",
        // 2026-09-04 追加：m4b（音频书=mp4 容器）/ webm（音频，内核 matroska 已认）
        "m4b", "webm",
    };

    private readonly IScannerDatabase _db;
    private readonly string _coverCacheDir;
    private readonly string _quarantineDir;
    private readonly AdaptiveBatchSize _adaptiveBatch;
    private readonly bool _incremental;

    /// <summary>生效的音频扩展名集合（内置白名单 ∪ 用户额外扩展名）。</summary>
    private readonly HashSet<string> _audioExt;

    /// <summary>进度回调（FFI 模式注入；CLI 模式为 null 时走 stdout JSON）</summary>
    private readonly Action<ScanProgress>? _progressSink;

    private readonly long _maxFileSizeBytes;
    private readonly int _maxScanFiles;
    private readonly int _maxScanErrors;
    private readonly int _maxParallelism;

    private sealed class ScanCounters
    {
        public int Scanned;
        public int Upserted;
        public int Errors;
        public int Trained;
        public int ConsecutiveErrors;
    }

    public ScannerEngine(
        IScannerDatabase db,
        string coverCacheDir,
        string quarantineDir,
        int batchSize = 50,
        bool incremental = true,
        long? maxFileSizeBytes = null,
        int? maxScanFiles = null,
        int? maxScanErrors = null,
        int? maxParallelism = null,
        IReadOnlyCollection<string>? extraExtensions = null,
        Action<ScanProgress>? progressSink = null)
    {
        _db = db;
        _coverCacheDir = coverCacheDir;
        _quarantineDir = quarantineDir;
        _adaptiveBatch = new AdaptiveBatchSize(batchSize); // batchSize = 0 不限，作为用户上限
        _incremental = incremental;
        _progressSink = progressSink;

        // 扩展名白名单：内置 + 用户额外追加（去点、小写、去重由 HashSet 保证）
        _audioExt = (extraExtensions is { Count: > 0 })
            ? new HashSet<string>(AudioExt, StringComparer.OrdinalIgnoreCase)
            : AudioExt;
        if (extraExtensions is { Count: > 0 })
        {
            foreach (var e in extraExtensions)
            {
                var ext = e.TrimStart('.').ToLowerInvariant();
                if (ext.Length > 0) _audioExt.Add(ext);
            }
        }

        // 安全限制：默认与 C++ 刮削器保持一致
        _maxFileSizeBytes = maxFileSizeBytes ?? (500L * 1024 * 1024);
        _maxScanFiles = maxScanFiles ?? 50000;
        _maxScanErrors = maxScanErrors ?? 50;

        // 并发数：优先构造函数参数 → 环境变量 → AdaptiveConcurrency
        if (maxParallelism.HasValue)
            _maxParallelism = maxParallelism.Value;
        else if (int.TryParse(Environment.GetEnvironmentVariable("SCANNER_MAX_PARALLELISM"), out var envP))
            _maxParallelism = envP;
        else
            _maxParallelism = AdaptiveConcurrency.ForIOBound();
        if (_maxParallelism < 1) _maxParallelism = AdaptiveConcurrency.ForIOBound();

        // 内核并发协商：把 scanner 依自身指标（AdaptiveConcurrency/内存/可用内存）
        // 算出的并行度下发给自研内核（metadata 池/限流参考）。内核不可用时静默跳过。
        KernelMetadata.SetConcurrency(_maxParallelism);
        LogInfo(KernelMetadata.Available
            ? $"内核元数据直桥: 可用（结构化 ABI，无 JSON），协商并发={_maxParallelism}"
            : "内核元数据直桥: 不可用，元数据回退 TagLibSharp");
    }

    /// <summary>
    /// 启动扫描
    ///
    /// 扫描流程：
    ///   1. 递归收集文件
    ///   2. 全量/增量分流：全量清空重建，增量加载快照到内存
    ///   3. 并行解析文件，从内存快照 TryRemove（不变跳过），错误文件标记 trained
    ///   4. 批量 upsert 新/变更的数据
    ///   5. 快照残留 = 磁盘已删除 → 清理 DB 记录
    ///   6. trained 文件统一移入 quarantine 目录并清理 DB 记录
    /// </summary>
    public ScanResult Scan(List<string> dirs, CancellationToken ct = default)
    {
        var sw = Stopwatch.StartNew();
        var result = new ScanResult();
        var progress = new ScanProgress { Scanning = true, StartedAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() };
        var counters = new ScanCounters();

        // 1. 收集文件（自动去重，防止重叠目录导致同一文件被处理两次）
        LogInfo($"开始扫描 (incremental={_incremental}, parallelism={_maxParallelism}): {string.Join(", ", dirs)}");
        var files = CollectFiles(dirs, progress, ct);
        if (files.Count > _maxScanFiles)
        {
            LogWarn($"文件数量 {files.Count} 超过上限 {_maxScanFiles}，将截断处理");
            files = files.Take(_maxScanFiles).ToList();
        }
        progress.Total = files.Count;
        EmitProgress(progress);
        LogInfo($"发现 {files.Count} 个音频文件");

        // 2. 全量扫描模式：清空所有曲目记录 + 错误记录
        //    增量扫描模式：加载 tracks 快照到内存做比对（无需 _scanner_blueprint 表）
        ConcurrentDictionary<string, (long Mtime, long Size)>? trackSnapshot = null;
        if (!_incremental)
        {
            LogInfo("全量扫描模式：清空所有曲目记录 + 错误记录");
            try { _db.ClearAllTracksAsync(ct).GetAwaiter().GetResult(); }
            catch (Exception ex) { LogWarn($"清空曲目失败: {ex.Message}"); }
            try { _db.ClearParseErrorsAsync(ct).GetAwaiter().GetResult(); }
            catch (Exception ex) { LogWarn($"清空错误记录失败: {ex.Message}"); }
            try { _db.ClearStagedTracksAsync(ct).GetAwaiter().GetResult(); }
            catch (Exception ex) { LogWarn($"清空 staging 失败: {ex.Message}"); }
        }
        else
        {
            LogInfo("增量扫描模式：加载已有曲目快照...");
            try { trackSnapshot = _db.LoadTrackSnapshotAsync(ct).GetAwaiter().GetResult(); }
            catch (Exception ex) { LogWarn($"加载快照失败，将退化到全量扫描: {ex.Message}"); }
            try { _db.ClearStagedTracksAsync(ct).GetAwaiter().GetResult(); }
            catch (Exception ex) { LogWarn($"清空 staging 失败: {ex.Message}"); }
        }

        // 4. 并行解析 + 有界队列批量写入（BlockingCollection，满则背压阻塞解析线程）
        var queue = new BlockingCollection<TrackMetadata>(new ConcurrentQueue<TrackMetadata>(), 1024);
        var writerThread = new Thread(() => WriterLoop(queue, counters, ct))
        { IsBackground = true, Name = "scanner-writer" };
        writerThread.Start();

        // 2.5 一次性加载错误路径快照到内存（全量模式已清空，增量模式加载 fail_count >= 3 的路径）
        //     避免并行循环中每文件查 DB 导致的锁竞争串行化
        var errorSnapshot = new Dictionary<string, ErrorFileState>(StringComparer.Ordinal);
        if (_incremental)
        {
            try
            {
                errorSnapshot = _db.LoadErrorSnapshotAsync(ct).GetAwaiter().GetResult();
                LogInfo($"加载错误快照: {errorSnapshot.Count} 个异常路径状态");
            }
            catch (Exception ex) { LogWarn($"加载错误快照失败: {ex.Message}"); }
        }

        var parserOptions = new ParallelOptions
        {
            MaxDegreeOfParallelism = _maxParallelism,
            CancellationToken = ct,
        };

        // seenPaths：线程安全地跟踪已处理文件，防止 Parallel.ForEachAsync 重复处理
        var seenPaths = new ConcurrentDictionary<string, byte>(StringComparer.OrdinalIgnoreCase);

        var lastEmit = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var currentPath = string.Empty;

        try
        {
            Parallel.For(0, files.Count, parserOptions, i =>
            {
                var file = files[i];
                ct.ThrowIfCancellationRequested();

                // 防止重复处理：同一路径只处理一次
                if (!seenPaths.TryAdd(file, 0))
                    return;

                Volatile.Write(ref currentPath, file);

                // 增量扫描：从内存快照 TryRemove，不变跳过
                bool shouldSkip = false;
                var fi = SafeFileInfo(file);
                if (trackSnapshot != null && fi != null && fi.Exists)
                {
                    if (trackSnapshot.TryRemove(file, out var cached))
                    {
                        var unchanged = cached.Mtime > 0
                            && cached.Mtime == ToUnixMs(fi.LastWriteTimeUtc)
                            && cached.Size == fi.Length;
                        if (unchanged) shouldSkip = true;
                    }
                }
                if (shouldSkip)
                {
                    Interlocked.Increment(ref counters.Scanned);
                    TryEmitProgress(ref lastEmit, progress, counters, Volatile.Read(ref currentPath));
                    return;
                }

                // 错误文件跳过检查：从内存快照判断连续解析失败 >= 3 次 → 标记隔离
                // （避免每文件查 DB，消除锁竞争串行化瓶颈）
                var currentMtime = fi?.Exists == true ? ToUnixMs(fi.LastWriteTimeUtc) : 0;
                if (errorSnapshot.TryGetValue(file, out var errorState) &&
                    errorState.FailCount >= 3 &&
                    errorState.MtimeAtLastFail == currentMtime)
                {
                    LogWarn($"标记损坏文件（待隔离 trained）: {file}");
                    try { _db.MarkTrainedAsync(file, ct).GetAwaiter().GetResult(); }
                    catch (Exception ex) { LogWarn($"标记隔离失败 {file}: {ex.Message}"); }
                    Interlocked.Increment(ref counters.Trained);
                    Interlocked.Increment(ref counters.Scanned);
                    TryEmitProgress(ref lastEmit, progress, counters, Volatile.Read(ref currentPath));
                    return;
                }

                var track = ParseFile(file);
                if (track != null)
                {
                    if (errorSnapshot.ContainsKey(file))
                    {
                        try { _db.ClearParseErrorAsync(file, ct).GetAwaiter().GetResult(); }
                        catch (Exception ex) { LogWarn($"清理异常记录失败 {file}: {ex.Message}"); }
                        try { _db.UnmarkTrainedAsync(file, ct).GetAwaiter().GetResult(); }
                        catch (Exception ex) { LogWarn($"清理 trained 标记失败 {file}: {ex.Message}"); }
                    }
                    Interlocked.Exchange(ref counters.ConsecutiveErrors, 0);
                    queue.Add(track, ct);
                    Interlocked.Increment(ref counters.Upserted);
                }
                else
                {
                    var errCount = Interlocked.Increment(ref counters.ConsecutiveErrors);
                    Interlocked.Increment(ref counters.Errors);
                    // 记录解析失败到 _scanner_errors 表（含具体原因）
                    try
                    {
                        var fileFailCount = _db.RecordParseErrorAsync(file, "parse_failed", ct).GetAwaiter().GetResult();
                        if (fileFailCount >= 3)
                        {
                            LogWarn($"异常文件达到隔离阈值，加入 trained: {file}");
                            _db.MarkTrainedAsync(file, ct).GetAwaiter().GetResult();
                            Interlocked.Increment(ref counters.Trained);
                        }
                    }
                    catch (Exception ex)
                    {
                        LogWarn($"记录异常文件失败 {file}: {ex.Message}");
                    }
                    if (errCount >= _maxScanErrors)
                    {
                        LogError($"连续失败达到上限 {_maxScanErrors}，中止扫描");
                        throw new InvalidOperationException($"连续解析失败超过 {_maxScanErrors} 次");
                    }
                }

                Interlocked.Increment(ref counters.Scanned);
                TryEmitProgress(ref lastEmit, progress, counters, Volatile.Read(ref currentPath));
            });
        }
        catch (OperationCanceledException)
        {
            // 正常取消，不记为错误
        }
        catch (AggregateException ae) when (ae.InnerExceptions.All(e => e is OperationCanceledException))
        {
            // Parallel.For 取消时可能包装为 AggregateException(OCE) —— 视为正常取消
        }
        catch (Exception ex)
        {
            LogError($"扫描异常: {ex.Message}");
            Interlocked.Increment(ref counters.Errors);
        }
        finally
        {
            queue.CompleteAdding();
        }

        writerThread.Join();
        result.Scanned = Volatile.Read(ref counters.Scanned);
        result.Upserted = Volatile.Read(ref counters.Upserted);
        result.Errors = Volatile.Read(ref counters.Errors);
        result.Trained = Volatile.Read(ref counters.Trained);

        if (!ct.IsCancellationRequested)
        {
            try
            {
                _db.MergeStagedTracksAsync(ct).GetAwaiter().GetResult();
            }
            catch (Exception ex)
            {
                LogError($"合并 staging 曲目失败: {ex.Message}");
                Interlocked.Increment(ref counters.Errors);
            }
        }

        // 4. 清理快照残留（＝磁盘已删除的文件）
        if (!ct.IsCancellationRequested && trackSnapshot != null && !trackSnapshot.IsEmpty)
        {
            var stale = trackSnapshot.Keys.ToList();
            try
            {
                var deleted = _db.DeleteTracksByPathsAsync(stale, ct).GetAwaiter().GetResult();
                if (deleted > 0)
                {
                    result.Deleted = deleted;
                    LogInfo($"清理 {deleted} 条失效记录");
                }
            }
            catch (Exception ex)
            {
                LogError($"清理失效记录失败: {ex.Message}");
            }
        }

        // 5. 排空写队列，确保所有 trained 标记和错误记录已持久化
        try { _db.FlushAsync(ct).GetAwaiter().GetResult(); }
        catch (Exception ex) { LogWarn($"drain 写队列失败: {ex.Message}"); }

        // 6. 统一处理隔离文件：移入 quarantine 目录并清理数据库记录
        if (!ct.IsCancellationRequested)
        {
            try { QuarantineTrainedFiles(ct); }
            catch (Exception ex) { LogError($"隔离处理异常: {ex.Message}"); }
        }

        result.Total = files.Count;
        result.Canceled = ct.IsCancellationRequested;
        sw.Stop();
        LogInfo($"扫描完成: {result.Scanned}/{result.Total}（upsert={result.Upserted}, delete={result.Deleted}, trained={result.Trained}, errors={result.Errors}, {sw.ElapsedMilliseconds}ms）");
        return result;
    }

    /// <summary>
    /// 统一处理已标记 trained 的文件：
    /// 1. 从 _scanner_trained 表读出所有待隔离路径
    /// 2. 将文件从原始位置移入 quarantine 目录（以 MD5 前缀防重名）
    /// 3. 从 tracks 表删除对应记录（如果是之前解析成功的文件后损坏）
    /// 4. 从 _scanner_errors 表删除对应错误记录
    /// 5. 清空 _scanner_trained 表
    /// </summary>
    private void QuarantineTrainedFiles(CancellationToken ct)
    {
        var paths = _db.GetTrainedPathsAsync(ct).GetAwaiter().GetResult();
        if (paths.Count == 0) return;

        LogInfo($"开始隔离 {paths.Count} 个损坏文件 → {_quarantineDir}");
        Directory.CreateDirectory(_quarantineDir);

        var moved = 0;
        var failedMove = new List<string>();

        foreach (var path in paths)
        {
            if (ct.IsCancellationRequested) break;

            try
            {
                if (!File.Exists(path))
                {
                    // 文件已被手动删除，只清记录
                    moved++;
                    continue;
                }

                // 以 MD5(path) + 原文件名 防止重名冲突
                var hash = Md5Hex(path);
                var name = Path.GetFileName(path);
                var dest = Path.Combine(_quarantineDir, $"{hash}_{name}");

                // 如果目标已存在（理论上不会），追加数字后缀
                var counter = 1;
                while (File.Exists(dest))
                {
                    dest = Path.Combine(_quarantineDir, $"{hash}_{counter}_{name}");
                    counter++;
                }

                File.Move(path, dest);
                moved++;
            }
            catch (Exception ex)
            {
                LogWarn($"隔离文件失败 {path}: {ex.Message}");
                failedMove.Add(path);
            }
        }

        // 清理 tracks 和 errors 中所有已标记 trained 的记录
        try
        {
            var delTracks = _db.DeleteTracksByPathsAsync(paths, ct).GetAwaiter().GetResult();
            if (delTracks > 0) LogInfo($"隔离后清理 {delTracks} 条曲目记录");
        }
        catch (Exception ex) { LogWarn($"清理隔离曲目记录失败: {ex.Message}"); }

        try
        {
            var delErrors = _db.DeleteParseErrorsByPathsAsync(paths, ct).GetAwaiter().GetResult();
            if (delErrors > 0) LogInfo($"隔离后清理 {delErrors} 条错误记录");
        }
        catch (Exception ex) { LogWarn($"清理隔离错误记录失败: {ex.Message}"); }

        _db.ClearTrainedAsync(ct).GetAwaiter().GetResult();

        if (failedMove.Count > 0)
            LogWarn($"隔离完成: {moved}/{paths.Count} 成功, {failedMove.Count} 移动失败（记录已清理）");
        else
            LogInfo($"隔离完成: {moved} 个文件已移入 {_quarantineDir}");
    }

    /// <summary>
    /// 写线程：从有界队列攒批写入 SQLite，根据写入耗时 + 系统内存动态调整批量大小。
    /// 目标每批写入 ~300ms，快则加量、慢则减量，每批都评估。
    /// </summary>
    private void WriterLoop(BlockingCollection<TrackMetadata> queue, ScanCounters counters, CancellationToken ct)
    {
        var dynamicBatchSize = _adaptiveBatch.Initial();
        LogInfo($"写入线程启动，初始批量大小: {dynamicBatchSize}");
        var batch = new List<TrackMetadata>(dynamicBatchSize);

        foreach (var track in queue.GetConsumingEnumerable())
        {
            batch.Add(track);
            if (batch.Count >= dynamicBatchSize)
            {
                var elapsedMs = FlushBatch(batch, counters, ct);
                var previous = dynamicBatchSize;
                dynamicBatchSize = _adaptiveBatch.Adjust(previous, elapsedMs);
                if (dynamicBatchSize != previous)
                    LogInfo($"批量调整: {previous} → {dynamicBatchSize} (上批耗时 {elapsedMs:F0}ms)");
            }
        }
        if (batch.Count > 0)
            FlushBatch(batch, counters, ct);
    }

    private double FlushBatch(List<TrackMetadata> batch, ScanCounters counters, CancellationToken ct)
    {
        var sw = Stopwatch.StartNew();
        try
        {
            _db.StageTracksAsync(batch, ct).GetAwaiter().GetResult();
        }
        catch (Exception ex)
        {
            LogError($"批量写入失败: {ex.Message}");
            Interlocked.Add(ref counters.Errors, batch.Count);
        }
        finally
        {
            batch.Clear();
        }
        return sw.Elapsed.TotalMilliseconds;
    }

    /// <summary>
    /// 递归收集音频文件，枚举过程中周期性上报进度
    /// </summary>
    private List<string> CollectFiles(List<string> dirs, ScanProgress progress, CancellationToken ct)
    {
        var result = new List<string>();
        var lastEmit = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        foreach (var dir in dirs)
        {
            if (ct.IsCancellationRequested) break;
            WalkAsync(dir, result, progress, ref lastEmit, ct);
            if (result.Count >= _maxScanFiles) break;
        }
        return result;
    }

    private void WalkAsync(string dir, List<string> result, ScanProgress progress, ref long lastEmit, CancellationToken ct)
    {
        IEnumerable<string> entries;
        try { entries = Directory.EnumerateFileSystemEntries(dir, "*", new EnumerationOptions { IgnoreInaccessible = true, RecurseSubdirectories = false }); }
        catch (UnauthorizedAccessException) { return; }
        catch (DirectoryNotFoundException) { return; }

        foreach (var full in entries)
        {
            if (ct.IsCancellationRequested) return;
            if (result.Count >= _maxScanFiles) return;

            try
            {
                var attr = File.GetAttributes(full);
                if (attr.HasFlag(FileAttributes.Directory))
                {
                    WalkAsync(full, result, progress, ref lastEmit, ct);
                }
                else
                {
                    var ext = Path.GetExtension(full).TrimStart('.').ToLowerInvariant();
                    if (_audioExt.Contains(ext))
                    {
                        result.Add(full);
                        // 每发现文件都更新 total，但限制广播频率（每 200ms 最多一次）
                        progress.Total = result.Count;
                        var now = NowMs();
                        if (now - lastEmit > 200)
                        {
                            EmitProgress(progress);
                            lastEmit = now;
                        }
                    }
                }
            }
            catch { /* 软链接/权限等跳过 */ }
        }
    }

    /// <summary>
    /// 解析单个音频文件
    /// </summary>
    private TrackMetadata? ParseFile(string filePath)
    {
        var info = SafeFileInfo(filePath);
        if (info == null || !info.Exists) return null;

        // 安全预检：跳过空文件 / 超大文件
        if (info.Length == 0 || info.Length > _maxFileSizeBytes)
        {
            LogWarn($"跳过异常文件 {filePath}: size={info.Length}");
            return null;
        }

        var id = Md5Hex(filePath);

        // 优先自研内核元数据快路径（结构化 C ABI，无 JSON，不解码 PCM）；
        // 内核不可用 / 不支持该格式 / 打开失败 → 回退 TagLibSharp。
        if (KernelMetadata.Supported(filePath))
        {
            var km = KernelMetadata.TryOpen(filePath);
            if (km != null)
            {
                var built = FromKernel(km, filePath, info, id);
                if (built != null) return built;
            }
        }

        TagLibFile tag;
        try
        {
            tag = TagLibFile.Create(filePath);
        }
        catch (Exception ex)
        {
            LogWarn($"解析失败 {filePath}: {ex.Message}");
            return null;
        }

        var props = tag.Properties;
        var audioProps = props.AudioSampleRate > 0 ? props : null;

        // 标题
        var title = string.IsNullOrWhiteSpace(tag.Tag.Title)
            ? Path.GetFileNameWithoutExtension(filePath)
            : tag.Tag.Title;

        // 歌手
        var artists = tag.Tag.Performers?
            .Where(n => !string.IsNullOrWhiteSpace(n))
            .Select(n => new ArtistRef { Name = n })
            .ToList();
        if (artists == null || artists.Count == 0)
            artists = new List<ArtistRef> { new() { Name = "未知歌手" } };

        // 专辑
        AlbumRef? album = null;
        if (!string.IsNullOrWhiteSpace(tag.Tag.Album))
        {
            album = new AlbumRef
            {
                Name = tag.Tag.Album,
                Year = tag.Tag.Year > 0 ? (int?)tag.Tag.Year : null,
                Artist = tag.Tag.Performers?.FirstOrDefault(),
            };
        }

        // 时长（毫秒）
        var duration = (long)Math.Round(tag.Properties.Duration.TotalMilliseconds);

        // 封面（统一写 ${id}.img，与 TS 层 serveTrackCover 读取路径一致）
        string? cover = null;
        var pictures = tag.Tag.Pictures;
        if (pictures != null && pictures.Length > 0)
            cover = TryWriteCover(pictures[0].Data.Data, id);

        // 歌词（TagLibSharp 2.3.0 中 Tag.Lyrics 是 string，不是 string[]）
        var lyricsRaw = tag.Tag.Lyrics;
        string? lyrics = string.IsNullOrWhiteSpace(lyricsRaw) ? null : lyricsRaw.Trim();

        // 编解码信息
        var codec = audioProps?.Description;
        var sampleRate = audioProps?.AudioSampleRate > 0 ? audioProps?.AudioSampleRate : null;
        var bitRate = audioProps?.AudioBitrate > 0 ? audioProps?.AudioBitrate : null;
        var channels = audioProps?.AudioChannels > 0 ? audioProps?.AudioChannels : null;
        var bitsPerSample = audioProps?.BitsPerSample > 0 ? audioProps?.BitsPerSample : null;

        return new TrackMetadata
        {
            Id = id,
            Path = filePath,
            Title = title,
            Track = tag.Tag.Track > 0 ? (int?)tag.Tag.Track : null,
            Artists = artists,
            Album = album,
            Duration = duration,
            Cover = cover,
            Codec = codec,
            SampleRate = sampleRate,
            BitRate = bitRate,
            Channels = channels,
            BitsPerSample = bitsPerSample,
            FileSize = info.Length,
            Mtime = ToUnixMs(info.LastWriteTimeUtc),
            Ctime = ToUnixMs(info.CreationTimeUtc),
            Lyrics = lyrics,
        };
    }

    /* ------------------------------------------------------------------ */
    /* 工具                                                                */
    /* ------------------------------------------------------------------ */

    /// <summary>
    /// 由自研内核元数据（zk_metadata_*，无 JSON）构造 TrackMetadata。
    /// 标准字段缺失时用同名标签兜底；与 TagLib 路径产出语义对齐。
    /// </summary>
    private TrackMetadata? FromKernel(KernelMetadata.Meta m, string filePath,
                                      FileInfo info, string id)
    {
        var title = string.IsNullOrWhiteSpace(m.Title)
            ? Path.GetFileNameWithoutExtension(filePath)
            : m.Title;

        var artistName = !string.IsNullOrWhiteSpace(m.Artist)
            ? m.Artist
            : FirstNonEmpty(m.Tag("artist"), m.Tag("albumartist"));
        var artists = new List<ArtistRef>();
        if (!string.IsNullOrWhiteSpace(artistName))
        {
            foreach (var n in artistName!.Split(
                         new[] { ';', '/', '\u3001' },
                         StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            {
                artists.Add(new ArtistRef { Name = n });
            }
        }
        if (artists.Count == 0) artists.Add(new ArtistRef { Name = "未知歌手" });

        AlbumRef? album = null;
        if (!string.IsNullOrWhiteSpace(m.Album))
        {
            album = new AlbumRef
            {
                Name = m.Album!,
                Year = ParseYear(m.Date) ?? ParseYear(m.Tag("date")),
                Artist = artists[0].Name,
            };
        }

        var duration = m.DurationUs > 0 ? (long)Math.Round(m.DurationUs / 1000.0) : 0;

        var cover = m.Cover is { Length: > 0 } ? TryWriteCover(m.Cover, id) : null;

        var lyrics = FirstNonEmpty(m.Tag("lyrics"), m.Tag("unsyncedlyrics"),
                                   m.Tag("unsynchronisedlyrics"));
        if (!string.IsNullOrWhiteSpace(lyrics)) lyrics = lyrics!.Trim();

        return new TrackMetadata
        {
            Id = id,
            Path = filePath,
            Title = title!,
            Track = ParseInt(m.Tag("tracknumber")) ?? ParseInt(m.Tag("track")),
            Artists = artists,
            Album = album,
            Duration = duration,
            Cover = cover,
            Codec = m.Codec,
            SampleRate = m.SampleRate > 0 ? m.SampleRate : null,
            BitRate = null,
            Channels = m.Channels > 0 ? m.Channels : null,
            BitsPerSample = m.BitsPerSample > 0 ? m.BitsPerSample : null,
            FileSize = info.Length,
            Mtime = ToUnixMs(info.LastWriteTimeUtc),
            Ctime = ToUnixMs(info.CreationTimeUtc),
            Lyrics = lyrics,
        };
    }

    /// <summary>封面统一写 ${id}.img（与 TS 层 serveTrackCover 读取路径一致）。</summary>
    private string? TryWriteCover(byte[] data, string id)
    {
        try
        {
            Directory.CreateDirectory(_coverCacheDir);
            var coverPath = Path.Combine(_coverCacheDir, $"{id}.img");
            File.WriteAllBytes(coverPath, data);
            return $"/api/music/cover/{id}";
        }
        catch (Exception ex)
        {
            LogWarn($"封面写入失败 {id}: {ex.Message}");
            return null;
        }
    }

    private static string? FirstNonEmpty(params string?[] values)
    {
        foreach (var v in values)
        {
            if (!string.IsNullOrWhiteSpace(v)) return v;
        }
        return null;
    }

    private static int? ParseInt(string? s)
        => int.TryParse(s?.Trim(), out var v) && v > 0 ? v : null;

    private static int? ParseYear(string? s)
    {
        if (string.IsNullOrWhiteSpace(s)) return null;
        var t = s.Trim();
        return t.Length >= 4 && int.TryParse(t.AsSpan(0, 4), out var y) && y > 0 ? y : null;
    }

    private static FileInfo? SafeFileInfo(string path)
    {
        try { return new FileInfo(path); }
        catch { return null; }
    }

    private void TryEmitProgress(ref long lastEmit, ScanProgress p, ScanCounters counters, string current)
    {
        var now = NowMs();
        var prev = Interlocked.Read(ref lastEmit);
        if (now - prev <= 500) return;
        if (Interlocked.CompareExchange(ref lastEmit, now, prev) != prev) return;

        EmitProgress(new ScanProgress
        {
            Scanning = p.Scanning,
            StartedAt = p.StartedAt,
            Total = p.Total,
            Scanned = Volatile.Read(ref counters.Scanned),
            Current = current,
            Upserted = Volatile.Read(ref counters.Upserted),
            Errors = Volatile.Read(ref counters.Errors),
            Trained = Volatile.Read(ref counters.Trained),
        });
    }

    private static string Md5Hex(string input)
    {
        var bytes = MD5.HashData(Encoding.UTF8.GetBytes(input));
        return Convert.ToHexString(bytes).ToLowerInvariant();
    }

    private static long ToUnixMs(DateTime dt)
    {
        return new DateTimeOffset(dt).ToUnixTimeMilliseconds();
    }

    private static long NowMs() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

    private void EmitProgress(ScanProgress p)
    {
        if (_progressSink != null)
        {
            _progressSink(p);
            return;
        }
        // CLI 模式：stdout 输出 JSON（TS 层监听）
        Console.WriteLine(ScannerJson.Progress(p));
    }

    private static void LogInfo(string msg) => Console.Error.WriteLine($"[scanner] {msg}");
    private static void LogWarn(string msg) => Console.Error.WriteLine($"[scanner] WARN: {msg}");
    private static void LogError(string msg) => Console.Error.WriteLine($"[scanner] ERROR: {msg}");
}
