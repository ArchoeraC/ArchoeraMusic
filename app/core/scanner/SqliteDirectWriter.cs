using System.Collections.Concurrent;
using System.Text.Json;
using System.Threading.Channels;
using Microsoft.Data.Sqlite;

namespace Archoera.Scanner;

/// <summary>
/// SQLite 直写器
///
/// 扫描器直接打开 SQLite 写入，数据不经过 Node.js / V8 堆。
/// 使用 WAL 模式与 Node.js better-sqlite3 共享同一个 DB 文件。
///
/// 并发模型：
///   - 写队列（Channel<Action>）+ 单后台消费者线程，所有写操作串行化执行
///   - 并行循环线程入队后立即返回，不被写操作阻塞
///   - 读操作直接执行（SQLite WAL 支持并发读）
///
/// 增量扫描策略（无需 _scanner_blueprint 表）：
///   1. LoadTrackSnapshotAsync → 从 tracks 表加载全量 path→(mtime,size) 到内存
///   2. 引擎逐文件 TryRemove，不变跳过，变更/新增解析写入
///   3. 引擎遍历完后调 DeleteTracksByPathsAsync 删除内存快照残留（= 已删除的文件）
///   4. _scanner_errors 表提供持久化错误追踪，crash 后重启扫描仍可跳过已知坏文件
///   5. _scanner_trained 表记录待隔离文件，扫描完成后引擎统一移入 quarantine 目录
/// </summary>
public sealed class SqliteDirectWriter : IScannerDatabase, IDisposable
{
    private readonly SqliteConnection _conn;
    /// <summary>写队列：所有 SQLite 写操作排队在此，单消费者串行执行</summary>
    private readonly Channel<Action> _writeChannel;
    /// <summary>后台写消费者任务</summary>
    private readonly Task _writeLoop;
    /// <summary>是否已释放</summary>
    private bool _disposed;

    public SqliteDirectWriter(string dbPath)
    {
        _conn = new SqliteConnection($"Data Source={dbPath}");
        _conn.Open();

        using var pragma = _conn.CreateCommand();
        pragma.CommandText = "PRAGMA journal_mode = WAL";
        pragma.ExecuteNonQuery();

        // 自建表（幂等）：脱离 sidecar 后 scanner 独立可用；
        // schema 与 sidecar database/index.ts 完全一致，已有表时无副作用
        EnsureTracksTable();

        // 初始化写队列 + 后台消费者（有界 4096 + Wait，队列满时 EnqueueWrite 自然阻塞调用者）
        _writeChannel = Channel.CreateBounded<Action>(new BoundedChannelOptions(4096)
        {
            FullMode = BoundedChannelFullMode.Wait,
            SingleWriter = false,
        });
        _writeLoop = Task.Run(WriteLoop);
    }

    /// <summary>
    /// 后台写循环：单消费者，从 Channel 串行取出执行
    /// 此线程是唯一写入 SQLite 的线程，无需额外锁
    /// </summary>
    private async Task WriteLoop()
    {
        try
        {
            while (await _writeChannel.Reader.WaitToReadAsync().ConfigureAwait(false))
            {
                while (_writeChannel.Reader.TryRead(out var work))
                {
                    work();
                }
            }
        }
        catch (ChannelClosedException) { }
    }

    /// <summary>
    /// 入队一个写操作并等待完成（通道满时阻塞，形成背压）
    /// </summary>
    private async Task EnqueueWrite(Action work)
    {
        var tcs = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        await _writeChannel.Writer.WriteAsync(() =>
        {
            try { work(); tcs.TrySetResult(); }
            catch (Exception ex) { tcs.TrySetException(ex); }
        }).ConfigureAwait(false);
        await tcs.Task.ConfigureAwait(false);
    }

    /// <summary>
    /// 入队一个有返回值的写操作并等待完成（通道满时阻塞，形成背压）
    /// </summary>
    private async Task<T> EnqueueWrite<T>(Func<T> work)
    {
        var tcs = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        await _writeChannel.Writer.WriteAsync(() =>
        {
            try { tcs.TrySetResult(work()); }
            catch (Exception ex) { tcs.TrySetException(ex); }
        }).ConfigureAwait(false);
        return await tcs.Task.ConfigureAwait(false);
    }

    /// <summary>
    /// 入队一个写操作，不等待完成（fire-and-forget）
    /// </summary>
    private void EnqueueFireAndForget(Action work)
    {
        _writeChannel.Writer.TryWrite(work);
    }

    /// <summary>
    /// 等待写队列排空（隔离等需要最新持久化数据的阶段前调用）
    /// </summary>
    public async Task FlushAsync(CancellationToken ct = default)
    {
        var tcs = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        await _writeChannel.Writer.WriteAsync(() => tcs.TrySetResult()).ConfigureAwait(false);
        await tcs.Task.ConfigureAwait(false);
    }

    // ============ 读操作（直接同步执行，无需队列） ============

    public Task<ConcurrentDictionary<string, (long Mtime, long Size)>> LoadTrackSnapshotAsync(CancellationToken ct = default)
    {
        return Task.Run(() =>
        {
            ct.ThrowIfCancellationRequested();
            var dict = new ConcurrentDictionary<string, (long, long)>(StringComparer.Ordinal);
            using var cmd = _conn.CreateCommand();
            cmd.CommandText = "SELECT path, COALESCE(file_mtime, 0), COALESCE(file_size, 0) FROM tracks";
            using var reader = cmd.ExecuteReader();
            while (reader.Read())
            {
                dict[reader.GetString(0)] = (reader.GetInt64(1), reader.GetInt64(2));
            }
            return dict;
        }, ct);
    }

    public Task<bool> ShouldSkipErrorFileAsync(string path, long currentMtimeMs, CancellationToken ct = default)
    {
        // 保留此方法供其他实现使用，当前引擎已改用 LoadErrorSnapshotAsync 内存快照
        return Task.Run(() =>
        {
            EnsureErrorTable();
            using var cmd = _conn.CreateCommand();
            cmd.CommandText = "SELECT fail_count FROM _scanner_errors WHERE path = @path";
            cmd.Parameters.AddWithValue("@path", path);
            using var reader = cmd.ExecuteReader();
            if (!reader.Read()) return false;
            return reader.GetInt32(0) >= 3;
        }, ct);
    }

    public Task<HashSet<string>> LoadErrorSnapshotAsync(CancellationToken ct = default)
    {
        return Task.Run(() =>
        {
            var set = new HashSet<string>(StringComparer.Ordinal);
            EnsureErrorTable();
            using var cmd = _conn.CreateCommand();
            cmd.CommandText = "SELECT path FROM _scanner_errors WHERE fail_count >= 3";
            using var reader = cmd.ExecuteReader();
            while (reader.Read())
                set.Add(reader.GetString(0));
            return set;
        }, ct);
    }

    public Task<List<string>> GetTrainedPathsAsync(CancellationToken ct = default)
    {
        return Task.Run(() =>
        {
            var list = new List<string>();
            EnsureTrainedTable();
            using var cmd = _conn.CreateCommand();
            cmd.CommandText = "SELECT path FROM _scanner_trained";
            using var reader = cmd.ExecuteReader();
            while (reader.Read())
                list.Add(reader.GetString(0));
            return list;
        }, ct);
    }

    // ============ 写操作（入队执行） ============

    public Task UpsertTracksAsync(List<TrackMetadata> tracks, CancellationToken ct = default)
    {
        if (tracks.Count == 0) return Task.CompletedTask;
        return EnqueueWrite(() => UpsertTracks(tracks, ct));
    }

    public Task<int> DeleteTracksByPathsAsync(List<string> paths, CancellationToken ct = default)
    {
        if (paths.Count == 0) return Task.FromResult(0);
        return EnqueueWrite(() => DeleteTracksByPaths(paths, ct));
    }

    public Task ClearAllTracksAsync(CancellationToken ct = default)
    {
        return EnqueueWrite(() =>
        {
            using var cmd = _conn.CreateCommand();
            cmd.CommandText = "DELETE FROM tracks";
            cmd.ExecuteNonQuery();
        });
    }

    public Task ClearParseErrorsAsync(CancellationToken ct = default)
    {
        return EnqueueWrite(() =>
        {
            EnsureErrorTable();
            using var cmd = _conn.CreateCommand();
            cmd.CommandText = "DELETE FROM _scanner_errors";
            cmd.ExecuteNonQuery();
        });
    }

    public Task<int> DeleteParseErrorsByPathsAsync(List<string> paths, CancellationToken ct = default)
    {
        if (paths.Count == 0) return Task.FromResult(0);
        return EnqueueWrite(() =>
        {
            int count = 0;
            EnsureErrorTable();
            using var tx = _conn.BeginTransaction();
            using var cmd = _conn.CreateCommand();
            cmd.CommandText = "DELETE FROM _scanner_errors WHERE path = @path";
            var param = cmd.Parameters.Add("@path", SqliteType.Text);
            foreach (var p in paths)
            {
                param.Value = p;
                count += cmd.ExecuteNonQuery();
            }
            tx.Commit();
            return count;
        });
    }

    public Task ClearTrainedAsync(CancellationToken ct = default)
    {
        return EnqueueWrite(() =>
        {
            EnsureTrainedTable();
            using var cmd = _conn.CreateCommand();
            cmd.CommandText = "DELETE FROM _scanner_trained";
            cmd.ExecuteNonQuery();
        });
    }

    /// <summary>
    /// 记录解析失败（fire-and-forget 入队，不阻塞调用者）
    /// </summary>
    public Task RecordParseErrorAsync(string path, string errorMessage, CancellationToken ct = default)
    {
        var fi = SafeFileInfo(path);
        long mtime = fi?.Exists == true ? ToUnixMs(fi.LastWriteTimeUtc) : 0;

        EnqueueFireAndForget(() =>
        {
            EnsureErrorTable();
            using var cmd = _conn.CreateCommand();
            cmd.CommandText = @"
                INSERT INTO _scanner_errors (path, fail_count, last_fail_time, last_error, mtime_at_last_fail)
                VALUES (@path, 1, @now, @error, @mtime)
                ON CONFLICT(path) DO UPDATE SET
                    fail_count = fail_count + 1,
                    last_fail_time = excluded.last_fail_time,
                    last_error = excluded.last_error,
                    mtime_at_last_fail = excluded.mtime_at_last_fail
            ";
            cmd.Parameters.AddWithValue("@path", path);
            cmd.Parameters.AddWithValue("@now", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
            cmd.Parameters.AddWithValue("@error", errorMessage);
            cmd.Parameters.AddWithValue("@mtime", mtime);
            cmd.ExecuteNonQuery();
        });

        return Task.CompletedTask;
    }

    /// <summary>
    /// 标记待隔离（fire-and-forget 入队，不阻塞调用者）
    /// </summary>
    public Task MarkTrainedAsync(string path, CancellationToken ct = default)
    {
        EnqueueFireAndForget(() =>
        {
            EnsureTrainedTable();
            using var cmd = _conn.CreateCommand();
            cmd.CommandText = "INSERT OR IGNORE INTO _scanner_trained (path) VALUES (@path)";
            cmd.Parameters.AddWithValue("@path", path);
            cmd.ExecuteNonQuery();
        });

        return Task.CompletedTask;
    }

    // ============ 内部方法 ============

    /// <summary>
    /// 幂等创建 tracks 表 + 索引。schema 对齐 sidecar/database/index.ts，
    /// 保证 scanner 脱离 sidecar 独立运行（Flutter 直连时同样适用）。
    /// </summary>
    private void EnsureTracksTable()
    {
        using var cmd = _conn.CreateCommand();
        cmd.CommandText = @"
            CREATE TABLE IF NOT EXISTS tracks (
                id TEXT PRIMARY KEY,
                path TEXT NOT NULL UNIQUE,
                title TEXT NOT NULL,
                track INTEGER,
                artists TEXT NOT NULL DEFAULT '[]',
                album TEXT,
                duration INTEGER NOT NULL,
                cover TEXT,
                codec TEXT,
                sample_rate INTEGER,
                bit_rate INTEGER,
                channels INTEGER,
                bits_per_sample INTEGER,
                file_size INTEGER NOT NULL,
                file_mtime INTEGER,
                file_ctime INTEGER,
                scanned_at INTEGER NOT NULL,
                lyrics TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_tracks_title ON tracks(title);
            CREATE INDEX IF NOT EXISTS idx_tracks_album ON tracks(album);
        ";
        cmd.ExecuteNonQuery();
    }

    private void UpsertTracks(List<TrackMetadata> tracks, CancellationToken ct)
    {
        using var tx = _conn.BeginTransaction();
        using var cmd = _conn.CreateCommand();
        cmd.CommandText = @"
            INSERT INTO tracks
                (id, path, title, track, artists, album, duration, cover,
                 codec, sample_rate, bit_rate, channels, bits_per_sample,
                 file_size, file_mtime, file_ctime, scanned_at, lyrics)
            VALUES
                (@id, @path, @title, @track, @artists, @album, @duration, @cover,
                 @codec, @sampleRate, @bitRate, @channels, @bitsPerSample,
                 @fileSize, @fileMtime, @fileCtime, @scannedAt, @lyrics)
            ON CONFLICT(id) DO UPDATE SET
                path = excluded.path,
                title = excluded.title,
                track = excluded.track,
                artists = excluded.artists,
                album = excluded.album,
                duration = excluded.duration,
                cover = excluded.cover,
                codec = excluded.codec,
                sample_rate = excluded.sample_rate,
                bit_rate = excluded.bit_rate,
                channels = excluded.channels,
                bits_per_sample = excluded.bits_per_sample,
                file_size = excluded.file_size,
                file_mtime = excluded.file_mtime,
                file_ctime = excluded.file_ctime,
                scanned_at = excluded.scanned_at,
                lyrics = excluded.lyrics
        ";

        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

        foreach (var t in tracks)
        {
            ct.ThrowIfCancellationRequested();

            cmd.Parameters.Clear();
            cmd.Parameters.AddWithValue("@id", t.Id);
            cmd.Parameters.AddWithValue("@path", t.Path);
            cmd.Parameters.AddWithValue("@title", t.Title);
            cmd.Parameters.AddWithValue("@track", (object?)t.Track ?? DBNull.Value);
            cmd.Parameters.AddWithValue("@artists",
                JsonSerializer.Serialize(t.Artists, ScannerJsonContext.Default.ListArtistRef));
            cmd.Parameters.AddWithValue("@album", t.Album != null
                ? JsonSerializer.Serialize(t.Album, ScannerJsonContext.Default.AlbumRef)
                : DBNull.Value);
            cmd.Parameters.AddWithValue("@duration", t.Duration);
            cmd.Parameters.AddWithValue("@cover", (object?)t.Cover ?? DBNull.Value);
            cmd.Parameters.AddWithValue("@codec", (object?)t.Codec ?? DBNull.Value);
            cmd.Parameters.AddWithValue("@sampleRate", (object?)t.SampleRate ?? DBNull.Value);
            cmd.Parameters.AddWithValue("@bitRate", (object?)t.BitRate ?? DBNull.Value);
            cmd.Parameters.AddWithValue("@channels", (object?)t.Channels ?? DBNull.Value);
            cmd.Parameters.AddWithValue("@bitsPerSample", (object?)t.BitsPerSample ?? DBNull.Value);
            cmd.Parameters.AddWithValue("@fileSize", t.FileSize);
            cmd.Parameters.AddWithValue("@fileMtime", t.Mtime);
            cmd.Parameters.AddWithValue("@fileCtime", t.Ctime);
            cmd.Parameters.AddWithValue("@scannedAt", now);
            cmd.Parameters.AddWithValue("@lyrics", (object?)t.Lyrics ?? DBNull.Value);

            cmd.ExecuteNonQuery();
        }

        tx.Commit();
    }

    private int DeleteTracksByPaths(List<string> paths, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        int count = 0;
        using var tx = _conn.BeginTransaction();
        using var cmd = _conn.CreateCommand();
        cmd.CommandText = "DELETE FROM tracks WHERE path = @path";
        var param = cmd.Parameters.Add("@path", SqliteType.Text);
        foreach (var p in paths)
        {
            param.Value = p;
            count += cmd.ExecuteNonQuery();
        }
        tx.Commit();
        return count;
    }

    private void EnsureErrorTable()
    {
        using var cmd = _conn.CreateCommand();
        cmd.CommandText = @"
            CREATE TABLE IF NOT EXISTS _scanner_errors (
                path TEXT PRIMARY KEY,
                fail_count INTEGER NOT NULL DEFAULT 1,
                last_fail_time INTEGER NOT NULL,
                last_error TEXT NOT NULL DEFAULT '',
                mtime_at_last_fail INTEGER NOT NULL DEFAULT 0
            )";
        cmd.ExecuteNonQuery();
    }

    private void EnsureTrainedTable()
    {
        using var cmd = _conn.CreateCommand();
        cmd.CommandText = @"
            CREATE TABLE IF NOT EXISTS _scanner_trained (
                path TEXT PRIMARY KEY
            )";
        cmd.ExecuteNonQuery();
    }

    private static FileInfo? SafeFileInfo(string path)
    {
        try { return new FileInfo(path); }
        catch { return null; }
    }

    private static long ToUnixMs(DateTime dt)
    {
        return new DateTimeOffset(dt).ToUnixTimeMilliseconds();
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;

        // 关闭写队列，等待消费者完成
        _writeChannel.Writer.TryComplete();
        try { _writeLoop.Wait(TimeSpan.FromSeconds(5)); }
        catch { /* 超时忽略 */ }

        if (_conn == null) return;
        try { _conn.Close(); }
        catch { }
        _conn.Dispose();
    }
}
