// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

using System.Globalization;
using System.Runtime.InteropServices;
using Microsoft.Data.Sqlite;

namespace Archoera.Indexer;

/// <summary>
/// <see cref="IIndexStore"/> 的 SQLite FTS5 实现（设计文档 §5.2）。
///
/// 要点：
/// <list type="bullet">
///   <item>schema 严格冻结（<c>search_docs</c> / <c>search_fts</c> / <c>search_meta</c>）；
///         FTS 列序 = bm25 权重序，不得改动（P3 Dart 对同一 schema 查询）。</item>
///   <item><b>contentless FTS（v2）</b>：<c>search_fts</c> 以 <c>content=''</c> +
///         <c>contentless_delete=1</c> 建表，倒排只存 postings / 位置，**不重复保存 token 文本**；
///         <c>search_docs</c> 仅保留元数据（doc_id / track_id / mtime / 世代 / schema）。
///         这消除了 external-content 方案下内容列文本的重复存储（P5 体积超标根因）。</item>
///   <item>写入：内容行 <c>INSERT OR REPLACE</c> 后，对同 doc 先 <c>DELETE FROM search_fts
///         WHERE rowid=…</c>（contentless_delete 允许删旧倒排，未命中为空操作）再
///         <c>INSERT INTO search_fts(rowid, …)</c> 重建倒排；不再需要 external-content 的
///         <c>'delete'</c> 命令式同步。</item>
///   <item>世代化全量（§5.3）：<c>build=true</c> 写 <c>&lt;path&gt;.tmp</c>，收尾 fsync 后
///         原子 <see cref="File.Move(string,string,bool)"/> 替换；绝不半写。</item>
///   <item>增量：直接打开既有库（WAL），<c>synchronous=NORMAL</c>、调大
///         <c>wal_autocheckpoint</c>，内部按 <see cref="BatchSize"/> 批量事务。</item>
/// </list>
/// 仅 indexer 写（独占）；读侧（P3 Dart）多连接只读。
/// </summary>
public sealed class FtsStore : IIndexStoreAdmin
{
    /// <summary>
    /// schema 版本；schema 变更必须递增（触发全量重建）。
    /// v2：external-content → contentless（<c>search_docs</c> 去掉 token 文本列）。
    /// v3：新增独立列 <c>initials_tok</c>（首字母从 <c>pinyin_tok</c> 拆出，见 <see cref="Bm25Weights"/>）。
    /// </summary>
    public const int SchemaVersionValue = 5;

    /// <summary>FTS 列（顺序 = bm25 权重顺序，冻结）。</summary>
    private const string FtsColumns =
        "title_tok, artist_tok, album_tok, lyrics_tok, lyrics_tr_tok, lyrics_rom_tok, "
        + "pinyin_meta_tok, pinyin_lyrics_tok, reading_meta_tok, "
        + "filename_tok, initials_meta_tok, initials_lyrics_tok";

    /// <summary>
    /// bm25 权重，顺序与 <see cref="FtsColumns"/> 严格一致：
    /// title 4.0 / artist 3.0 / album 2.0 / lyrics 1.5 / lyrics_tr 1.0 / lyrics_rom 0.5 /
    /// pinyin_meta 2.0 / pinyin_lyrics 1.5 / filename 1.0 / initials_meta 2.0 / initials_lyrics 1.5
    /// （设计文档 §5.2 / 交付约定）。
    ///
    /// <c>initials_tok</c> 是**独立列**（v3 起）：v2 把首字母串混在 <c>pinyin_tok</c> 里，
    /// 于是首字母查询（`"wan"*`）会命中拼音音节（完 / 万 / 晚…），命中集近乎整库
    /// （30k 语料实测 `"wan"*` 命中 29985/30000、单条 56ms）——独立成列后首字母只与
    /// 真正的首字母串互比。其权重取 2.0（与拼音同档：二者都是「同一批字段的另一种写法」）。
    /// </summary>
    private static readonly double[] Bm25Weights =
    {
        4.0,  // title
        3.0,  // artist
        2.0,  // album
        1.5,  // lyrics（原文）
        1.0,  // lyrics_tr（译文）
        0.5,  // lyrics_rom（音译）
        2.0,  // pinyin_meta（元数据拼音：与 title/artist 同档）
        1.5,  // pinyin_lyrics（歌词拼音：与歌词原文同档）
        2.0,  // reading_meta（日文读音：与拼音同档；**只索引元数据**——歌词罗马字检索是伪需求，
              //        且整段歌词读音 bigram 会把索引推高约 2×，见设计文档 §4.2）
        1.0,  // filename
        2.0,  // initials_meta
        1.5,  // initials_lyrics
    };

    private SqliteConnection? _conn;
    private SqliteTransaction? _tx;
    private string _path = "";
    private string _tmpPath = "";
    private bool _build;
    private int _pending;
    private bool _sealed;
    private bool _disposed;

    /// <inheritdoc />
    public int SchemaVersion => SchemaVersionValue;

    /// <inheritdoc />
    public int BatchSize { get; set; } = 500;

    /// <inheritdoc />
    public long NextDocId { get; private set; } = 1;

    /// <inheritdoc />
    public void Open(string path, bool build)
    {
        if (_conn != null) throw new InvalidOperationException("存储已打开");
        _path = Path.GetFullPath(path);
        _build = build;

        if (build)
        {
            _tmpPath = _path + ".tmp";
            // 清掉上次未完成的临时世代（含 WAL 侧车）；旧正式库保留到原子替换为止
            DeleteFileAndSidecars(_tmpPath);
            _conn = new SqliteConnection($"Data Source={_tmpPath}");
            _conn.Open();
            Exec("PRAGMA journal_mode = WAL");
            Exec("PRAGMA synchronous = FULL");
        }
        else
        {
            _tmpPath = _path;
            _conn = new SqliteConnection($"Data Source={_path}");
            _conn.Open();
            Exec("PRAGMA journal_mode = WAL");
            Exec("PRAGMA synchronous = NORMAL");
            Exec("PRAGMA wal_autocheckpoint = 10000");
        }

        EnsureSchema();
        NextDocId = _build ? 1 : ScalarLong("SELECT COALESCE(MAX(doc_id), 0) + 1 FROM search_docs");
    }

    /// <inheritdoc />
    public void Put(long docId, DocTokens f)
    {
        var conn = EnsureOpen();
        EnsureTx();

        // 1) upsert 元数据行（明确 schema_version；contentless FTS 不依赖内容表旧值）
        using (var up = conn.CreateCommand())
        {
            up.Transaction = _tx;
            up.CommandText = """
                INSERT OR REPLACE INTO search_docs
                    (doc_id, track_id, indexed_mtime, indexed_lrc_mtime, indexed_lrc_size,
                     indexed_generation, schema_version)
                VALUES (@id, @track, @mtime, @lrcM, @lrcS, @gen, @schema)
                """;
            AddMetaParameters(up, docId, f);
            up.ExecuteNonQuery();
        }

        // 2) 清旧倒排（新文档无行则空操作；contentless_delete=1 允许按 rowid 删除）
        using (var del = conn.CreateCommand())
        {
            del.Transaction = _tx;
            del.CommandText = "DELETE FROM search_fts WHERE rowid = @id";
            del.Parameters.AddWithValue("@id", docId);
            del.ExecuteNonQuery();
        }

        // 3) 建新倒排（contentless：显式传入全部 token 列值）
        using (var ins = conn.CreateCommand())
        {
            ins.Transaction = _tx;
            ins.CommandText = $"""
                INSERT INTO search_fts (rowid, {FtsColumns})
                VALUES (@id, @title, @artist, @album, @lyrics, @tr, @rom,
                        @pinyinMeta, @pinyinLyrics, @readingMeta,
                        @filename, @initialsMeta, @initialsLyrics)
                """;
            AddTokenParameters(ins, docId, f);
            ins.ExecuteNonQuery();
        }

        AfterWrite();
    }

    /// <inheritdoc />
    public void Delete(long docId)
    {
        var conn = EnsureOpen();
        EnsureTx();

        using (var del = conn.CreateCommand())
        {
            del.Transaction = _tx;
            del.CommandText = "DELETE FROM search_fts WHERE rowid = @id";
            del.Parameters.AddWithValue("@id", docId);
            del.ExecuteNonQuery();
        }
        using (var rm = conn.CreateCommand())
        {
            rm.Transaction = _tx;
            rm.CommandText = "DELETE FROM search_docs WHERE doc_id = @id";
            rm.Parameters.AddWithValue("@id", docId);
            rm.ExecuteNonQuery();
        }

        AfterWrite();
    }

    /// <inheritdoc />
    public void Commit()
    {
        var conn = EnsureOpen();
        CommitTx();
        using var cp = conn.CreateCommand();
        cp.CommandText = "PRAGMA wal_checkpoint(TRUNCATE)";
        cp.ExecuteNonQuery();
    }

    /// <inheritdoc />
    public void Optimize()
    {
        var conn = EnsureOpen();
        CommitTx();
        using (var opt = conn.CreateCommand())
        {
            opt.CommandText = "PRAGMA optimize";
            opt.ExecuteNonQuery();
        }
        using (var fts = conn.CreateCommand())
        {
            fts.CommandText = "INSERT INTO search_fts(search_fts) VALUES('optimize')";
            fts.ExecuteNonQuery();
        }
    }

    /// <summary>
    /// **候选集上限**（宽命中查询的工作量上界；0 = 不限）。与 Dart 侧
    /// `SearchIndex.defaultCandidateCap` 是同一个策略：先按 rowid 顺序取有界候选（无排序、
    /// 可提前退出），再只给这批候选做 bm25 排序——`ORDER BY bm25` 否则要给**全部命中**打分。
    /// </summary>
    public const int DefaultCandidateCap = 5000;

    /// <inheritdoc />
    public List<(long DocId, double Score)> Search(
        string matchExpr, int limit, int offset, int candidateCap)
    {
        var conn = EnsureOpen();
        CommitTx(); // 让未落盘的写入对查询可见（调试用途）

        var weights = string.Join(", ", Bm25Weights.Select(
            w => w.ToString(CultureInfo.InvariantCulture)));
        using var cmd = conn.CreateCommand();
        // candidateCap > 0：先取有界候选再排序；= 0：原路径（全部命中打分），供对照。
        cmd.CommandText = candidateCap > 0
            ? $"""
                SELECT rowid, bm25(search_fts, {weights}) AS score
                FROM search_fts
                WHERE rowid IN (
                    SELECT rowid FROM search_fts WHERE search_fts MATCH @q LIMIT @cap
                )
                ORDER BY score
                LIMIT @limit OFFSET @offset
                """
            : $"""
                SELECT rowid, bm25(search_fts, {weights}) AS score
                FROM search_fts
                WHERE search_fts MATCH @q
                ORDER BY score
                LIMIT @limit OFFSET @offset
                """;
        cmd.Parameters.AddWithValue("@q", matchExpr);
        if (candidateCap > 0) cmd.Parameters.AddWithValue("@cap", candidateCap);
        cmd.Parameters.AddWithValue("@limit", limit <= 0 ? -1 : limit);
        cmd.Parameters.AddWithValue("@offset", offset < 0 ? 0 : offset);

        var results = new List<(long, double)>();
        using var reader = cmd.ExecuteReader();
        while (reader.Read())
            results.Add((reader.GetInt64(0), reader.GetDouble(1)));
        return results;
    }

    /* ------------------------------------------------------------------ */
    /* 增量引擎管理视图                                                    */
    /* ------------------------------------------------------------------ */

    /// <inheritdoc />
    public StoreMeta ReadMeta()
    {
        var meta = new StoreMeta();
        var conn = EnsureOpen();
        if (!TableExists(conn, "search_meta")) return meta;

        using var cmd = conn.CreateCommand();
        cmd.CommandText = "SELECT key, value FROM search_meta";
        using var reader = cmd.ExecuteReader();
        while (reader.Read())
        {
            var key = reader.GetString(0);
            var value = reader.IsDBNull(1) ? "" : reader.GetString(1);
            switch (key)
            {
                case "schema_version": meta.SchemaVersion = ParseInt(value); break;
                case "analyzer_version": meta.AnalyzerVersion = ParseInt(value); break;
                case "index_lrc": meta.IndexLrc = value == "1" || value.Equals("true", StringComparison.OrdinalIgnoreCase); break;
                case "pinyin": meta.Pinyin = value == "1" || value.Equals("true", StringComparison.OrdinalIgnoreCase); break;
                case "applied_generation": meta.AppliedGeneration = ParseLong(value); break;
                case "built_at": meta.BuiltAt = ParseLong(value); break;
                case "full_build_at": meta.FullBuildAt = ParseLong(value); break;
            }
        }
        return meta;
    }

    /// <inheritdoc />
    public void WriteMeta(StoreMeta meta)
    {
        var conn = EnsureOpen();
        EnsureTx();
        using var cmd = conn.CreateCommand();
        cmd.Transaction = _tx;
        cmd.CommandText = """
            INSERT INTO search_meta (key, value) VALUES (@key, @value)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """;
        var key = cmd.Parameters.Add("@key", SqliteType.Text);
        var value = cmd.Parameters.Add("@value", SqliteType.Text);
        foreach (var (k, v) in new (string, string)[]
        {
            ("schema_version", SchemaVersionValue.ToString(CultureInfo.InvariantCulture)),
            ("analyzer_version", Analyzer.AnalyzerVersion.ToString(CultureInfo.InvariantCulture)),
            ("index_lrc", meta.IndexLrc ? "1" : "0"),
            ("pinyin", meta.Pinyin ? "1" : "0"),
            ("applied_generation", meta.AppliedGeneration.ToString(CultureInfo.InvariantCulture)),
            ("built_at", meta.BuiltAt.ToString(CultureInfo.InvariantCulture)),
            ("full_build_at", meta.FullBuildAt.ToString(CultureInfo.InvariantCulture)),
        })
        {
            key.Value = k;
            value.Value = v;
            cmd.ExecuteNonQuery();
        }
    }

    /// <inheritdoc />
    public Dictionary<string, DocState> LoadState()
    {
        var conn = EnsureOpen();
        var state = new Dictionary<string, DocState>(StringComparer.Ordinal);
        if (!TableExists(conn, "search_docs")) return state;

        using var cmd = conn.CreateCommand();
        cmd.CommandText = """
            SELECT track_id, doc_id, indexed_mtime, indexed_lrc_mtime, indexed_lrc_size, indexed_generation
            FROM search_docs
            """;
        using var reader = cmd.ExecuteReader();
        while (reader.Read())
        {
            state[reader.GetString(0)] = new DocState(
                reader.GetInt64(1),
                reader.IsDBNull(2) ? 0 : reader.GetInt64(2),
                reader.IsDBNull(3) ? 0 : reader.GetInt64(3),
                reader.IsDBNull(4) ? 0 : reader.GetInt64(4),
                reader.IsDBNull(5) ? 0 : reader.GetInt64(5));
        }
        return state;
    }

    /// <inheritdoc />
    public void Seal()
    {
        if (_sealed) return;
        _sealed = true;
        var conn = EnsureOpen();
        CommitTx();

        using (var cp = conn.CreateCommand())
        {
            cp.CommandText = "PRAGMA wal_checkpoint(TRUNCATE)";
            cp.ExecuteNonQuery();
        }

        if (_build)
        {
            // 关闭连接（WAL 侧车随之清理），fsync 临时库，再原子替换正式库
            CloseConnection();
            Fsync(_tmpPath);
            File.Move(_tmpPath, _path, overwrite: true);
            // POSIX：rename 后 fsync 父目录，增强掉电持久性；Windows 目录 fsync 不适用，安全跳过
            FsyncDirectory(_path);
            DeleteFileAndSidecars(_tmpPath); // 极端情况下残留的 -wal/-shm
            Log.LogInfo("indexer", $"世代化替换完成: {_tmpPath} -> {_path}");
        }
    }

    /// <inheritdoc />
    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        try
        {
            CommitTx();
        }
        catch (Exception ex)
        {
            Log.LogWarn("indexer", $"关闭前提交失败: {ex.Message}");
        }

        var wasSealed = _sealed;
        CloseConnection();

        // 未 Seal 的世代化构建 = 中途失败：丢弃临时世代，绝不半写正式库
        if (_build && !wasSealed)
        {
            DeleteFileAndSidecars(_tmpPath);
            Log.LogWarn("indexer", "全量构建未完成，已丢弃临时世代（正式库不受影响）");
        }
    }

    /* ------------------------------------------------------------------ */
    /* 静态辅助                                                            */
    /* ------------------------------------------------------------------ */

    /// <summary>
    /// 预检：只读打开既有 <paramref name="path"/>，读取版本 / 选项元数据。
    /// 库不存在 / 无 <c>search_meta</c> / 读取失败 → <c>null</c>（调用方按全量处理）。
    /// </summary>
    public static StoreMeta? PeekMeta(string path)
    {
        try
        {
            if (!File.Exists(path)) return null;
            using var conn = new SqliteConnection($"Data Source={path};Mode=ReadOnly");
            conn.Open();
            if (!TableExists(conn, "search_meta")) return null;

            var meta = new StoreMeta();
            using var cmd = conn.CreateCommand();
            cmd.CommandText = "SELECT key, value FROM search_meta";
            using var reader = cmd.ExecuteReader();
            while (reader.Read())
            {
                var key = reader.GetString(0);
                var value = reader.IsDBNull(1) ? "" : reader.GetString(1);
                switch (key)
                {
                    case "schema_version": meta.SchemaVersion = ParseInt(value); break;
                    case "analyzer_version": meta.AnalyzerVersion = ParseInt(value); break;
                    case "index_lrc": meta.IndexLrc = value == "1" || value.Equals("true", StringComparison.OrdinalIgnoreCase); break;
                    case "pinyin": meta.Pinyin = value == "1" || value.Equals("true", StringComparison.OrdinalIgnoreCase); break;
                    case "applied_generation": meta.AppliedGeneration = ParseLong(value); break;
                    case "built_at": meta.BuiltAt = ParseLong(value); break;
                    case "full_build_at": meta.FullBuildAt = ParseLong(value); break;
                }
            }
            return meta;
        }
        catch (Exception ex)
        {
            Log.LogWarn("indexer", $"读取既有索引元数据失败（按全量处理）: {ex.Message}");
            return null;
        }
    }

    /// <summary>
    /// 预检：既有 <paramref name="path"/> 的 schema/analyzer 版本是否与当前代码一致。
    /// 库不存在 / 无 <c>search_meta</c> / 版本不符 → <c>false</c>（调用方应触发全量）。
    /// </summary>
    public static bool VersionsMatch(string path)
    {
        var meta = PeekMeta(path);
        return meta is not null
            && meta.SchemaVersion == SchemaVersionValue
            && meta.AnalyzerVersion == Analyzer.AnalyzerVersion;
    }

    /* ------------------------------------------------------------------ */
    /* 内部实现                                                            */
    /* ------------------------------------------------------------------ */

    private void EnsureSchema()
    {
        Exec("""
            CREATE TABLE IF NOT EXISTS search_docs (
              doc_id INTEGER PRIMARY KEY,
              track_id TEXT NOT NULL UNIQUE,
              indexed_mtime INTEGER, indexed_lrc_mtime INTEGER, indexed_lrc_size INTEGER,
              indexed_generation INTEGER, schema_version INTEGER
            )
            """);
        // contentless FTS5：倒排只存 postings / 位置，不重复保存 token 文本；
        // contentless_delete=1 允许按 rowid 删除（覆盖 / 增量删除）。
        Exec($"""
            CREATE VIRTUAL TABLE IF NOT EXISTS search_fts USING fts5(
              {FtsColumns},
              content='', contentless_delete=1, tokenize='unicode61'
            )
            """);
        Exec("CREATE TABLE IF NOT EXISTS search_meta (key TEXT PRIMARY KEY, value TEXT)");
    }

    /// <summary>元数据行（<c>search_docs</c>）的公用参数。</summary>
    private void AddMetaParameters(SqliteCommand cmd, long docId, DocTokens f)
    {
        cmd.Parameters.AddWithValue("@id", docId);
        cmd.Parameters.AddWithValue("@track", f.TrackId);
        cmd.Parameters.AddWithValue("@mtime", f.IndexedMtime);
        cmd.Parameters.AddWithValue("@lrcM", f.IndexedLrcMtime);
        cmd.Parameters.AddWithValue("@lrcS", f.IndexedLrcSize);
        cmd.Parameters.AddWithValue("@gen", f.IndexedGeneration);
        cmd.Parameters.AddWithValue("@schema", SchemaVersionValue);
    }

    /// <summary>FTS 倒排行（全部 token 列）的公用参数。</summary>
    private static void AddTokenParameters(SqliteCommand cmd, long docId, DocTokens f)
    {
        cmd.Parameters.AddWithValue("@id", docId);
        cmd.Parameters.AddWithValue("@title", f.TitleTok);
        cmd.Parameters.AddWithValue("@artist", f.ArtistTok);
        cmd.Parameters.AddWithValue("@album", f.AlbumTok);
        cmd.Parameters.AddWithValue("@lyrics", f.LyricsTok);
        cmd.Parameters.AddWithValue("@tr", f.LyricsTrTok);
        cmd.Parameters.AddWithValue("@rom", f.LyricsRomTok);
        cmd.Parameters.AddWithValue("@pinyinMeta", f.PinyinMetaTok);
        cmd.Parameters.AddWithValue("@pinyinLyrics", f.PinyinLyricsTok);
        cmd.Parameters.AddWithValue("@readingMeta", f.ReadingMetaTok);
        cmd.Parameters.AddWithValue("@filename", f.FilenameTok);
        cmd.Parameters.AddWithValue("@initialsMeta", f.InitialsMetaTok);
        cmd.Parameters.AddWithValue("@initialsLyrics", f.InitialsLyricsTok);
    }

    private void AfterWrite()
    {
        _pending++;
        if (BatchSize > 0 && _pending >= BatchSize) CommitTx();
    }

    private void EnsureTx()
    {
        if (_tx != null) return;
        _tx = EnsureOpen().BeginTransaction();
        _pending = 0;
    }

    private void CommitTx()
    {
        if (_tx == null) return;
        _tx.Commit();
        _tx.Dispose();
        _tx = null;
        _pending = 0;
    }

    private SqliteConnection EnsureOpen()
        => _conn ?? throw new InvalidOperationException("存储尚未打开（Open 未调用）");

    private void CloseConnection()
    {
        if (_conn == null) return;
        try { _conn.Close(); } catch { /* 忽略关闭异常 */ }
        _conn.Dispose();
        _conn = null;
        _tx = null;
    }

    private void Exec(string sql)
    {
        using var cmd = EnsureOpen().CreateCommand();
        cmd.CommandText = sql;
        cmd.ExecuteNonQuery();
    }

    private long ScalarLong(string sql)
    {
        using var cmd = EnsureOpen().CreateCommand();
        cmd.CommandText = sql;
        var value = cmd.ExecuteScalar();
        return value is null || value is DBNull ? 0 : Convert.ToInt64(value, CultureInfo.InvariantCulture);
    }

    private static bool TableExists(SqliteConnection conn, string table)
    {
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "SELECT 1 FROM sqlite_master WHERE type IN ('table','view') AND name = @name LIMIT 1";
        cmd.Parameters.AddWithValue("@name", table);
        return cmd.ExecuteScalar() != null;
    }

    private static void Fsync(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
        stream.Flush(flushToDisk: true);
    }

    /// <summary>
    /// POSIX：对文件所在目录执行 fsync（rename 落盘的持久性保障，设计文档 §5.3）。
    /// Windows 目录 fsync 不适用，直接跳过；打开 / fsync 失败仅告警，不抛错。
    /// </summary>
    private static void FsyncDirectory(string filePath)
    {
        if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows)) return;
        var directory = Path.GetDirectoryName(Path.GetFullPath(filePath));
        if (string.IsNullOrEmpty(directory)) return;

        int fd = -1;
        try
        {
            fd = PosixOpen(directory, O_RDONLY);
            if (fd < 0)
            {
                Log.LogWarn("indexer", $"目录 fsync 打开失败（已忽略）: {directory}");
                return;
            }
            PosixFsync(fd);
        }
        catch (Exception ex)
        {
            Log.LogWarn("indexer", $"目录 fsync 失败（已忽略）: {ex.Message}");
        }
        finally
        {
            if (fd >= 0) PosixClose(fd);
        }
    }

    private const int O_RDONLY = 0;

    [DllImport("libc", SetLastError = true)]
    private static extern int open(string pathname, int flags);

    [DllImport("libc", SetLastError = true)]
    private static extern int fsync(int fd);

    [DllImport("libc", SetLastError = true)]
    private static extern int close(int fd);

    private static int PosixOpen(string pathname, int flags) => open(pathname, flags);
    private static int PosixFsync(int fd) => fsync(fd);
    private static int PosixClose(int fd) => close(fd);

    private static void DeleteFileAndSidecars(string path)
    {
        foreach (var candidate in new[] { path, path + "-wal", path + "-shm", path + "-journal" })
        {
            try
            {
                if (File.Exists(candidate)) File.Delete(candidate);
            }
            catch (Exception ex)
            {
                Log.LogWarn("indexer", $"清理文件失败 {candidate}: {ex.Message}");
            }
        }
    }

    private static int ParseInt(string value)
        => int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var v) ? v : 0;

    private static long ParseLong(string value)
        => long.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var v) ? v : 0;
}
