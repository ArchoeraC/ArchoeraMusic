// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

using System.Collections.Concurrent;
using Microsoft.Data.Sqlite;

namespace Archoera.Scanner;

/// <summary>
/// SQLite 直写器（同步写者模型）
///
/// 扫描器直接打开 SQLite 写入，数据不经过 Node.js / V8 堆；WAL 与 Node 侧共享 DB。
///
/// 并发模型（2026-09-10 去 async 化）：
///   - 写：`BlockingCollection<Action>`（有界）+ **专用写线程**串行执行；入队即返回
///     （队列满则阻塞=背压），**不做每批 TCS/async 状态机**；
///   - 读：独立**读连接** + 锁，在调用线程同步执行（SQLite WAL 支持读写并发）；
///   - 结果型写（需返回计数）用事件同步等待，非热路径；
///   - `Flush` 同步等待写队列排空。
/// </summary>
public sealed class SqliteDirectWriter : IScannerDatabase, IDisposable
{
    private readonly SqliteConnection _conn;      // 仅写线程使用
    private readonly SqliteConnection _readConn;  // 仅读方法使用
    private readonly System.Threading.Lock _readLock = new();
    /// <summary>写队列：有界，满时入队阻塞（背压）</summary>
    private readonly BlockingCollection<Action> _queue = new(new ConcurrentQueue<Action>(), 4096);
    /// <summary>专用写线程</summary>
    private readonly Thread _writer;
    /// <summary>是否已释放</summary>
    private bool _disposed;

    public SqliteDirectWriter(string dbPath)
    {
        _conn = new SqliteConnection($"Data Source={dbPath}");
        _conn.Open();

        using (var pragma = _conn.CreateCommand())
        {
            pragma.CommandText = "PRAGMA journal_mode = WAL";
            pragma.ExecuteNonQuery();
        }
        using (var sync = _conn.CreateCommand())
        {
            sync.CommandText = "PRAGMA synchronous = NORMAL";
            sync.ExecuteNonQuery();
        }

        // 自建表（幂等）：脱离 sidecar 后 scanner 独立可用；
        // schema 与 sidecar database/index.ts 完全一致，已有表时无副作用
        EnsureTracksTable();
        EnsureStageTable();
        EnsureLoudnessColumns(); // 旧库补列（幂等；新建库已在 CREATE 中含列）
        EnsureSidecarColumns();  // 同上：.lrc 侧车列（v3）

        // 读连接（WAL 下可并发读）
        _readConn = new SqliteConnection($"Data Source={dbPath}");
        _readConn.Open();

        // 专用写线程：串行消费队列（单写者，免锁）
        _writer = new Thread(() =>
        {
            try
            {
                foreach (var work in _queue.GetConsumingEnumerable())
                {
                    try { work(); }
                    catch (Exception ex)
                    {
                        // 写失败不可静默（否则数据丢失无感知）：路由统一日志，继续处理后续
                        Log.LogError("scanner", $"sqlite 写操作失败: {ex}");
                    }
                }
            }
            catch (ObjectDisposedException) { }
        })
        { IsBackground = true, Name = "scanner-sqlite-writer" };
        _writer.Start();
    }

    /// <summary>入队一个写操作（队列满则阻塞=背压）；不等待完成</summary>
    private void Enqueue(Action work)
    {
        try { _queue.Add(work); }
        catch (InvalidOperationException) { /* 已 CompleteAdding（释放中） */ }
    }

    /// <summary>入队并等待完成（结果型写；非热路径）</summary>
    private void EnqueueAndWait(Action work)
    {
        using var done = new ManualResetEventSlim(false);
        Enqueue(() =>
        {
            try { work(); }
            finally { done.Set(); }
        });
        done.Wait();
    }

    /// <summary>fire-and-forget 写（返回已完成 Task，兼容既有 await 调用点；无每批 TCS）</summary>
    private Task EnqueueWrite(Action work)
    {
        Enqueue(work);
        return Task.CompletedTask;
    }

    /// <summary>结果型写：同步等待写线程执行完毕并返回结果（非热路径）</summary>
    private Task<T> EnqueueWrite<T>(Func<T> work)
    {
        T result = default!;
        EnqueueAndWait(() => result = work());
        return Task.FromResult(result);
    }

    /// <summary>
    /// 等待写队列排空（隔离等需要最新持久化数据的阶段前调用；同步）
    /// </summary>
    public Task FlushAsync(CancellationToken ct = default)
    {
        using var done = new ManualResetEventSlim(false);
        Enqueue(() => done.Set());
        done.Wait();
        return Task.CompletedTask;
    }

    // ============ 读操作（独立读连接 + 锁，调用线程同步执行） ============

    public Task<ConcurrentDictionary<string, TrackSnapshot>> LoadTrackSnapshotAsync(CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        var dict = new ConcurrentDictionary<string, TrackSnapshot>(StringComparer.Ordinal);
        lock (_readLock)
        {
            using var cmd = _readConn.CreateCommand();
            // .lrc 侧车状态一并载入：媒体未变但侧车变化（或存量库 lrc_checked 为空）
            // 时仍需补一次侧车列，故不能只看 (mtime, size)。
            cmd.CommandText =
                "SELECT path, COALESCE(file_mtime, 0), COALESCE(file_size, 0), " +
                "COALESCE(lrc_mtime, 0), COALESCE(lrc_size, 0), COALESCE(lrc_checked, 0) FROM tracks";
            using var reader = cmd.ExecuteReader();
            while (reader.Read())
            {
                dict[reader.GetString(0)] = new TrackSnapshot(
                    reader.GetInt64(1), reader.GetInt64(2),
                    reader.GetInt64(3), reader.GetInt64(4), reader.GetInt64(5) != 0);
            }
        }
        return Task.FromResult(dict);
    }

    public Task<bool> ShouldSkipErrorFileAsync(string path, long currentMtimeMs, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        lock (_readLock)
        {
            EnsureErrorTableOn(_readConn);
            using var cmd = _readConn.CreateCommand();
            cmd.CommandText = "SELECT fail_count, mtime_at_last_fail FROM _scanner_errors WHERE path = @path";
            cmd.Parameters.AddWithValue("@path", path);
            using var reader = cmd.ExecuteReader();
            if (!reader.Read()) return Task.FromResult(false);
            return Task.FromResult(reader.GetInt32(0) >= 3 && reader.GetInt64(1) == currentMtimeMs);
        }
    }

    public Task<Dictionary<string, ErrorFileState>> LoadErrorSnapshotAsync(CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        var map = new Dictionary<string, ErrorFileState>(StringComparer.Ordinal);
        lock (_readLock)
        {
            EnsureErrorTableOn(_readConn);
            using var cmd = _readConn.CreateCommand();
            cmd.CommandText = "SELECT path, fail_count, mtime_at_last_fail FROM _scanner_errors";
            using var reader = cmd.ExecuteReader();
            while (reader.Read())
                map[reader.GetString(0)] = new ErrorFileState(reader.GetInt32(1), reader.GetInt64(2));
        }
        return Task.FromResult(map);
    }

    public Task<List<string>> GetTrainedPathsAsync(CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        var list = new List<string>();
        lock (_readLock)
        {
            EnsureTrainedTableOn(_readConn);
            using var cmd = _readConn.CreateCommand();
            cmd.CommandText = "SELECT path FROM _scanner_trained";
            using var reader = cmd.ExecuteReader();
            while (reader.Read())
                list.Add(reader.GetString(0));
        }
        return Task.FromResult(list);
    }

    // ============ 写操作（入队执行；fire-and-forget，队列满即背压） ============

    public Task StageTracksAsync(List<TrackMetadata> tracks, CancellationToken ct = default)
    {
        if (tracks.Count == 0) return Task.CompletedTask;
        // 快照：调用方（引擎）在入队后会立即 Clear 复用 batch，不能捕获原引用
        var snapshot = new List<TrackMetadata>(tracks);
        Enqueue(() => InsertStageTracks(snapshot, ct));
        return Task.CompletedTask;
    }

    public Task ClearStagedTracksAsync(CancellationToken ct = default)
    {
        Enqueue(() =>
        {
            using var cmd = _conn.CreateCommand();
            cmd.CommandText = "DELETE FROM _scanner_stage_tracks";
            cmd.ExecuteNonQuery();
        });
        return Task.CompletedTask;
    }

    public Task MergeStagedTracksAsync(CancellationToken ct = default)
    {
        return EnqueueWrite(() =>
        {
            ct.ThrowIfCancellationRequested();
            using var tx = _conn.BeginTransaction();
            using var cmd = _conn.CreateCommand();
            cmd.CommandText = @"
                INSERT INTO tracks
                    (id, path, title, track, artists, album, duration, cover,
                     codec, sample_rate, bit_rate, channels, bits_per_sample,
                     file_size, file_mtime, file_ctime, scanned_at, lyrics,
                     loudness_lufs, loudness_peak,
                     lyrics_lrc, lyrics_lrc_trans, lyrics_lrc_romaji, lrc_mtime, lrc_size, lrc_checked)
                SELECT
                    id, path, title, track, artists, album, duration, cover,
                    codec, sample_rate, bit_rate, channels, bits_per_sample,
                    file_size, file_mtime, file_ctime, scanned_at, lyrics,
                    loudness_lufs, loudness_peak,
                    lyrics_lrc, lyrics_lrc_trans, lyrics_lrc_romaji, lrc_mtime, lrc_size, lrc_checked
                FROM _scanner_stage_tracks
                WHERE true
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
                    lyrics = excluded.lyrics,
                    -- 普通扫描（未开 --analyze-loudness）staging 为 NULL：保留已分析值。
                    loudness_lufs = COALESCE(excluded.loudness_lufs, tracks.loudness_lufs),
                    loudness_peak = COALESCE(excluded.loudness_peak, tracks.loudness_peak),
                    -- .lrc 侧车：本轮**探测过**（`lrc_checked` 非空）就照 staging 原值取
                    -- ——包括「侧车被删掉」时的 NULL（否则会残留旧文本）；
                    -- 本轮未探测（staging 为 NULL）才保留既有值。
                    lyrics_lrc = CASE WHEN excluded.lrc_checked IS NULL
                        THEN tracks.lyrics_lrc ELSE excluded.lyrics_lrc END,
                    lyrics_lrc_trans = CASE WHEN excluded.lrc_checked IS NULL
                        THEN tracks.lyrics_lrc_trans ELSE excluded.lyrics_lrc_trans END,
                    lyrics_lrc_romaji = CASE WHEN excluded.lrc_checked IS NULL
                        THEN tracks.lyrics_lrc_romaji ELSE excluded.lyrics_lrc_romaji END,
                    lrc_mtime = CASE WHEN excluded.lrc_checked IS NULL
                        THEN tracks.lrc_mtime ELSE excluded.lrc_mtime END,
                    lrc_size = CASE WHEN excluded.lrc_checked IS NULL
                        THEN tracks.lrc_size ELSE excluded.lrc_size END,
                    lrc_checked = COALESCE(excluded.lrc_checked, tracks.lrc_checked);
                DELETE FROM _scanner_stage_tracks;
            ";
            cmd.ExecuteNonQuery();
            tx.Commit();
        });
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
    public Task<int> RecordParseErrorAsync(string path, string errorMessage, CancellationToken ct = default)
    {
        var fi = SafeFileInfo(path);
        long mtime = fi?.Exists == true ? ToUnixMs(fi.LastWriteTimeUtc) : 0;

        return EnqueueWrite(() =>
        {
            EnsureErrorTable();
            using var tx = _conn.BeginTransaction();
            using var select = _conn.CreateCommand();
            select.CommandText = "SELECT fail_count, mtime_at_last_fail FROM _scanner_errors WHERE path = @path";
            select.Parameters.AddWithValue("@path", path);

            int nextCount = 1;
            using (var reader = select.ExecuteReader())
            {
                if (reader.Read())
                {
                    var prevCount = reader.GetInt32(0);
                    var prevMtime = reader.GetInt64(1);
                    nextCount = prevMtime == mtime ? prevCount + 1 : 1;
                }
            }

            using var upsert = _conn.CreateCommand();
            upsert.CommandText = @"
                INSERT INTO _scanner_errors (path, fail_count, last_fail_time, last_error, mtime_at_last_fail)
                VALUES (@path, @count, @now, @error, @mtime)
                ON CONFLICT(path) DO UPDATE SET
                    fail_count = excluded.fail_count,
                    last_fail_time = excluded.last_fail_time,
                    last_error = excluded.last_error,
                    mtime_at_last_fail = excluded.mtime_at_last_fail
            ";
            upsert.Parameters.AddWithValue("@path", path);
            upsert.Parameters.AddWithValue("@count", nextCount);
            upsert.Parameters.AddWithValue("@now", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
            upsert.Parameters.AddWithValue("@error", errorMessage);
            upsert.Parameters.AddWithValue("@mtime", mtime);
            upsert.ExecuteNonQuery();
            tx.Commit();
            return nextCount;
        });
    }

    public Task ClearParseErrorAsync(string path, CancellationToken ct = default)
    {
        return EnqueueWrite(() =>
        {
            EnsureErrorTable();
            using var cmd = _conn.CreateCommand();
            cmd.CommandText = "DELETE FROM _scanner_errors WHERE path = @path";
            cmd.Parameters.AddWithValue("@path", path);
            cmd.ExecuteNonQuery();
        });
    }

    /// <summary>
    /// 标记待隔离（入队并等待，确保主动隔离链路语义明确）
    /// </summary>
    public Task MarkTrainedAsync(string path, CancellationToken ct = default)
    {
        return EnqueueWrite(() =>
        {
            EnsureTrainedTable();
            using var cmd = _conn.CreateCommand();
            cmd.CommandText = "INSERT OR IGNORE INTO _scanner_trained (path) VALUES (@path)";
            cmd.Parameters.AddWithValue("@path", path);
            cmd.ExecuteNonQuery();
        });
    }

    public Task UnmarkTrainedAsync(string path, CancellationToken ct = default)
    {
        return EnqueueWrite(() =>
        {
            EnsureTrainedTable();
            using var cmd = _conn.CreateCommand();
            cmd.CommandText = "DELETE FROM _scanner_trained WHERE path = @path";
            cmd.Parameters.AddWithValue("@path", path);
            cmd.ExecuteNonQuery();
        });
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
                lyrics TEXT,
                loudness_lufs REAL,
                loudness_peak REAL,
                lyrics_lrc TEXT,
                lyrics_lrc_trans TEXT,
                lyrics_lrc_romaji TEXT,
                lrc_mtime INTEGER,
                lrc_size INTEGER,
                lrc_checked INTEGER
            );
            CREATE INDEX IF NOT EXISTS idx_tracks_title ON tracks(title);
            CREATE INDEX IF NOT EXISTS idx_tracks_album ON tracks(album);
        ";
        cmd.ExecuteNonQuery();
    }

    private void EnsureStageTable()
    {
        using var cmd = _conn.CreateCommand();
        cmd.CommandText = @"
            CREATE TABLE IF NOT EXISTS _scanner_stage_tracks (
                id TEXT NOT NULL,
                path TEXT NOT NULL,
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
                lyrics TEXT,
                loudness_lufs REAL,
                loudness_peak REAL,
                lyrics_lrc TEXT,
                lyrics_lrc_trans TEXT,
                lyrics_lrc_romaji TEXT,
                lrc_mtime INTEGER,
                lrc_size INTEGER,
                lrc_checked INTEGER
            )
        ";
        cmd.ExecuteNonQuery();
    }

    private void InsertStageTracks(List<TrackMetadata> tracks, CancellationToken ct)
    {
        using var tx = _conn.BeginTransaction();
        using var cmd = _conn.CreateCommand();
        cmd.CommandText = @"
            INSERT INTO _scanner_stage_tracks
                (id, path, title, track, artists, album, duration, cover,
                 codec, sample_rate, bit_rate, channels, bits_per_sample,
                 file_size, file_mtime, file_ctime, scanned_at, lyrics,
                 loudness_lufs, loudness_peak,
                 lyrics_lrc, lyrics_lrc_trans, lyrics_lrc_romaji, lrc_mtime, lrc_size, lrc_checked)
            VALUES
                (@id, @path, @title, @track, @artists, @album, @duration, @cover,
                 @codec, @sampleRate, @bitRate, @channels, @bitsPerSample,
                 @fileSize, @fileMtime, @fileCtime, @scannedAt, @lyrics,
                 @loudnessLufs, @loudnessPeak,
                 @lyricsLrc, @lyricsLrcTrans, @lyricsLrcRomaji, @lrcMtime, @lrcSize, @lrcChecked)
        ";

        // 仅侧车变更（媒体未变）的项走 UPDATE：只写 .lrc 列 + 锚点，绝不覆盖已解析的元数据。
        using var sidecarCmd = _conn.CreateCommand();
        sidecarCmd.Transaction = tx;
        sidecarCmd.CommandText = @"
            UPDATE tracks SET
                lyrics_lrc = @lyricsLrc,
                lyrics_lrc_trans = @lyricsLrcTrans,
                lyrics_lrc_romaji = @lyricsLrcRomaji,
                lrc_mtime = @lrcMtime,
                lrc_size = @lrcSize,
                lrc_checked = @lrcChecked
            WHERE id = @id
        ";

        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

        foreach (var t in tracks)
        {
            ct.ThrowIfCancellationRequested();

            if (t.SidecarOnly)
            {
                sidecarCmd.Parameters.Clear();
                sidecarCmd.Parameters.AddWithValue("@id", t.Id);
                sidecarCmd.Parameters.AddWithValue("@lyricsLrc", (object?)t.LyricsLrc ?? DBNull.Value);
                sidecarCmd.Parameters.AddWithValue("@lyricsLrcTrans", (object?)t.LyricsLrcTrans ?? DBNull.Value);
                sidecarCmd.Parameters.AddWithValue("@lyricsLrcRomaji", (object?)t.LyricsLrcRomaji ?? DBNull.Value);
                sidecarCmd.Parameters.AddWithValue("@lrcMtime", (object?)t.LrcMtime ?? DBNull.Value);
                sidecarCmd.Parameters.AddWithValue("@lrcSize", (object?)t.LrcSize ?? DBNull.Value);
                sidecarCmd.Parameters.AddWithValue("@lrcChecked", (object?)t.LrcChecked ?? DBNull.Value);
                sidecarCmd.ExecuteNonQuery();
                continue;
            }

            cmd.Parameters.Clear();
            cmd.Parameters.AddWithValue("@id", t.Id);
            cmd.Parameters.AddWithValue("@path", t.Path);
            cmd.Parameters.AddWithValue("@title", t.Title);
            cmd.Parameters.AddWithValue("@track", (object?)t.Track ?? DBNull.Value);
            cmd.Parameters.AddWithValue("@artists",
                ScannerJson.ArtistRefs(t.Artists));
            cmd.Parameters.AddWithValue("@album", t.Album != null
                ? ScannerJson.Album(t.Album!)
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
            cmd.Parameters.AddWithValue("@loudnessLufs", (object?)t.LoudnessLufs ?? DBNull.Value);
            cmd.Parameters.AddWithValue("@loudnessPeak", (object?)t.LoudnessPeak ?? DBNull.Value);
            cmd.Parameters.AddWithValue("@lyricsLrc", (object?)t.LyricsLrc ?? DBNull.Value);
            cmd.Parameters.AddWithValue("@lyricsLrcTrans", (object?)t.LyricsLrcTrans ?? DBNull.Value);
            cmd.Parameters.AddWithValue("@lyricsLrcRomaji", (object?)t.LyricsLrcRomaji ?? DBNull.Value);
            cmd.Parameters.AddWithValue("@lrcMtime", (object?)t.LrcMtime ?? DBNull.Value);
            cmd.Parameters.AddWithValue("@lrcSize", (object?)t.LrcSize ?? DBNull.Value);
            cmd.Parameters.AddWithValue("@lrcChecked", (object?)t.LrcChecked ?? DBNull.Value);

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

    private void EnsureErrorTable() => EnsureErrorTableOn(_conn);

    private static void EnsureErrorTableOn(SqliteConnection c)
    {
        using var cmd = c.CreateCommand();
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

    private void EnsureTrainedTable() => EnsureTrainedTableOn(_conn);

    private static void EnsureTrainedTableOn(SqliteConnection c)
    {
        using var cmd = c.CreateCommand();
        cmd.CommandText = @"
            CREATE TABLE IF NOT EXISTS _scanner_trained (
                path TEXT PRIMARY KEY
            )";
        cmd.ExecuteNonQuery();
    }

    /// <summary>
    /// 幂等迁移：为**已存在**的 tracks / staging 表补 `loudness_lufs` /
    /// `loudness_peak` 列（新建库已在 CREATE TABLE 中带列）。以 PRAGMA table_info
    /// 判定缺失后再 ALTER TABLE ADD COLUMN，重复运行无副作用。
    /// </summary>
    private void EnsureLoudnessColumns()
    {
        EnsureLoudnessColumnsOn(_conn, "tracks");
        EnsureLoudnessColumnsOn(_conn, "_scanner_stage_tracks");
    }

    private static void EnsureLoudnessColumnsOn(SqliteConnection c, string table)
    {
        var existing = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        using (var probe = c.CreateCommand())
        {
            probe.CommandText = $"PRAGMA table_info({table})";
            using var reader = probe.ExecuteReader();
            while (reader.Read()) existing.Add(reader.GetString(1)); // 列 1 = name
        }
        foreach (var col in LoudnessColumns)
        {
            if (existing.Contains(col)) continue;
            using var alter = c.CreateCommand();
            alter.CommandText = $"ALTER TABLE {table} ADD COLUMN {col} REAL";
            alter.ExecuteNonQuery();
        }
    }

    /// <summary>
    /// 幂等迁移：为**已存在**的 tracks / staging 表补 <c>.lrc</c> 侧车列
    /// （新建库已在 CREATE TABLE 中带列）。列类型不同，故单独处理（见 <see cref="EnsureLoudnessColumns"/>）。
    /// </summary>
    private void EnsureSidecarColumns()
    {
        EnsureSidecarColumnsOn(_conn, "tracks");
        EnsureSidecarColumnsOn(_conn, "_scanner_stage_tracks");
    }

    private static void EnsureSidecarColumnsOn(SqliteConnection c, string table)
    {
        var existing = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        using (var probe = c.CreateCommand())
        {
            probe.CommandText = $"PRAGMA table_info({table})";
            using var reader = probe.ExecuteReader();
            while (reader.Read()) existing.Add(reader.GetString(1));
        }
        foreach (var (col, type) in SidecarColumns)
        {
            if (existing.Contains(col)) continue;
            using var alter = c.CreateCommand();
            alter.CommandText = $"ALTER TABLE {table} ADD COLUMN {col} {type}";
            alter.ExecuteNonQuery();
        }
    }

    /// <summary>.lrc 侧车列（顺序固定；迁移 / CREATE 共用）。新增列只需追加，勿改动既有名字。</summary>
    private static readonly (string Name, string Type)[] SidecarColumns =
    {
        ("lyrics_lrc", "TEXT"),
        ("lyrics_lrc_trans", "TEXT"),
        ("lyrics_lrc_romaji", "TEXT"),
        ("lrc_mtime", "INTEGER"),
        ("lrc_size", "INTEGER"),
        ("lrc_checked", "INTEGER"),
    };

    /// <summary>响度分析列（顺序固定；迁移/CREATE 共用）。</summary>
    private static readonly string[] LoudnessColumns = { "loudness_lufs", "loudness_peak" };

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

        // 关闭写队列，等待写线程完成
        try { _queue.CompleteAdding(); } catch { }
        try { _writer.Join(TimeSpan.FromSeconds(5)); } catch { }

        try { _conn.Close(); } catch { }
        _conn.Dispose();
        try { _readConn.Close(); } catch { }
        _readConn.Dispose();
        _queue.Dispose();
    }
}
