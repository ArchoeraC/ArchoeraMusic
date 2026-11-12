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
    /// v6：<c>search_docs</c> 新增 <c>reading_tok</c>（读音 bigram 原文副本，供兜底趟分档 T1-4）。
    /// v7：<c>search_meta</c> 新增语言画像（<c>has_japanese</c> / <c>has_korean</c> /
    ///     <c>has_han</c> / <c>has_latin</c>），供查询侧跳过不可能命中的兜底趟；
    ///     无表结构变化，仅为让既有库重建后拿到画像。
    /// </summary>
    public const int SchemaVersionValue = 7;

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

    // 模糊层词典（T1-8）：按写入纪元缓存；查询侧只读、不失效。
    private string[]? _fuzzyVocabulary;
    private long _fuzzyVocabularyEpoch = -1;
    private long _writeEpoch;

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
            _conn = new SqliteConnection(ConnectionString(_tmpPath));
            _conn.Open();
            Exec("PRAGMA journal_mode = WAL");
            Exec("PRAGMA synchronous = FULL");
        }
        else
        {
            _tmpPath = _path;
            _conn = new SqliteConnection(ConnectionString(_path));
            _conn.Open();
            Exec("PRAGMA journal_mode = WAL");
            Exec("PRAGMA synchronous = NORMAL");
            Exec("PRAGMA wal_autocheckpoint = 10000");
        }

        EnsureSchema();
        NextDocId = _build ? 1 : ScalarLong("SELECT COALESCE(MAX(doc_id), 0) + 1 FROM search_docs");
    }

    /// <summary>
    /// **只读**打开既有索引（查询侧专用）：不建表、不改 <c>journal_mode</c> / <c>synchronous</c>，
    /// 连接只用于 <see cref="Search"/> / <see cref="ReadMeta"/> / <see cref="ResolveTrackIds"/>。
    /// 查询会话由 <see cref="SearchSession"/> 按路径缓存复用。
    /// </summary>
    public void OpenReadOnly(string path)
    {
        if (_conn != null) throw new InvalidOperationException("存储已打开");
        _path = Path.GetFullPath(path);
        _tmpPath = _path;
        _build = false;
        _conn = new SqliteConnection(ConnectionString(_path, readOnly: true));
        _conn.Open();
        Exec("PRAGMA query_only = ON");
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
                     indexed_generation, schema_version, reading_tok)
                VALUES (@id, @track, @mtime, @lrcM, @lrcS, @gen, @schema, @reading)
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
    /// **候选集上限**（历史参数，已不再裁剪候选；0 = 不限）。
    ///
    /// ⚠ 2026-11-12 撤销：原实现「子查询取有界候选 + 外层排序」会让 FTS5 的
    /// <c>bm25()</c> 在无 <c>MATCH</c> 的外层查询里静默返回 0，相关性排序整体失效。
    /// 该常量与 <c>Search</c> 的 <c>candidateCap</c> 参数仅为 ABI / 请求 JSON 兼容保留，
    /// 排序一律走「含 MATCH 的全命中 bm25 排序」（现实现更快且正确）。
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
        // bm25 排序必须在**含 `MATCH` 的查询块内**求值——FTS5 的 `bm25()` 在
        // `rowid IN (SELECT ... MATCH ...)` 这种外层不匹配的写法里**静默返回 0**，
        // 结果退化为 rowid 顺序而**不报错**（相关性排序整体失效）。
        //
        // 历史教训：candidateCap 最初是为了「先取有界候选再排序」省成本，但它用
        // `WHERE rowid IN (子查询)` 实现，正好踩中上述语义 → 排序失效，且实测并不更快
        // （宽命中时子查询要跑满一遍才 LIMIT，反而更慢）。故该机制已移除，
        // 排序交给 FTS5 全命中打分 —— 实测比错误写法更快且结果正确。
        // candidateCap 参数保留在 ABI 上以兼容旧调用方，但语义上不再裁剪候选。
        cmd.CommandText = $"""
            SELECT rowid, bm25(search_fts, {weights}) AS score
            FROM search_fts
            WHERE search_fts MATCH @q
            ORDER BY score
            LIMIT @limit OFFSET @offset
            """;
        cmd.Parameters.AddWithValue("@q", matchExpr);
        cmd.Parameters.AddWithValue("@limit", limit <= 0 ? -1 : limit);
        cmd.Parameters.AddWithValue("@offset", offset < 0 ? 0 : offset);

        var results = new List<(long, double)>();
        using var reader = cmd.ExecuteReader();
        while (reader.Read())
            results.Add((reader.GetInt64(0), reader.GetDouble(1)));
        return results;
    }

    /// <summary>批量把 <c>doc_id</c> 映射回 <c>track_id</c>（查询结果组装用）。</summary>
    public Dictionary<long, string> ResolveTrackIds(IReadOnlyCollection<long> docIds)
    {        var map = new Dictionary<long, string>(docIds.Count);
        if (docIds.Count == 0) return map;

        var conn = EnsureOpen();
        using var cmd = conn.CreateCommand();
        var names = new List<string>(docIds.Count);
        var index = 0;
        foreach (var docId in docIds)
        {
            var name = "@id" + index++;
            names.Add(name);
            cmd.Parameters.AddWithValue(name, docId);
        }
        cmd.CommandText =
            $"SELECT doc_id, track_id FROM search_docs WHERE doc_id IN ({string.Join(", ", names)})";
        using var reader = cmd.ExecuteReader();
        while (reader.Read()) map[reader.GetInt64(0)] = reader.GetString(1);
        return map;
    }

    /// <summary>
    /// 批量取候选文档的读音 bigram 原文副本（兜底趟分档用；contentless FTS 回读不到）。
    /// 无读音（纯中文 / 纯英文）的文档不进入结果字典。
    /// </summary>
    public Dictionary<long, string> ResolveReadingTexts(IReadOnlyCollection<long> docIds)
    {
        var map = new Dictionary<long, string>(docIds.Count);
        if (docIds.Count == 0) return map;

        var conn = EnsureOpen();
        using var cmd = conn.CreateCommand();
        var names = new List<string>(docIds.Count);
        var index = 0;
        foreach (var docId in docIds)
        {
            var name = "@id" + index++;
            names.Add(name);
            cmd.Parameters.AddWithValue(name, docId);
        }
        cmd.CommandText =
            $"SELECT doc_id, reading_tok FROM search_docs WHERE doc_id IN ({string.Join(", ", names)})";
        using var reader = cmd.ExecuteReader();
        while (reader.Read())
        {
            var text = reader.IsDBNull(1) ? "" : reader.GetString(1);
            if (text.Length > 0) map[reader.GetInt64(0)] = text;
        }
        return map;
    }

    /// <summary>
    /// 加载模糊层词典（T1-8）：索引自身的 FTS 词表里可检索的拉丁 / 数字 term，按字典序。
    ///
    /// 词典不落盘、不改 schema：每次查询会话首次需要模糊趟时用一条临时连接读
    /// <c>fts5vocab</c>，随后按写入纪元缓存（本进程内索引更新会让缓存失效重载）。
    /// 只收 ASCII 小写 / 数字（CJK 由 <see cref="SearchQuery.CjkVariants"/> 负责）。
    ///
    /// 注意：<c>PRAGMA query_only</c> 会连 temp 库一起锁死（无法创建 <c>fts5vocab</c> 虚拟表），
    /// 所以这里用**文件级只读**连接且不设该 pragma——temp 表在内存里，主库不可写。
    /// 读词表失败时返回空集，调用方退回旧的「无词典过滤」行为（不影响可用性）。
    /// </summary>
    public IReadOnlyList<string> LoadFuzzyVocabulary()
    {
        if (_fuzzyVocabulary is { } cached && _fuzzyVocabularyEpoch == _writeEpoch) return cached;
        if (!File.Exists(_path)) return Array.Empty<string>();

        var terms = new List<string>();
        try
        {
            using var conn = new SqliteConnection(ConnectionString(_path, readOnly: true));
            conn.Open();
            using (var create = conn.CreateCommand())
            {
                create.CommandText =
                    "CREATE VIRTUAL TABLE temp.fuzzy_vocab USING fts5vocab(main, search_fts, 'col')";
                create.ExecuteNonQuery();
            }
            using (var query = conn.CreateCommand())
            {
                query.CommandText = """
                    SELECT DISTINCT term FROM temp.fuzzy_vocab
                    WHERE col IN ('title_tok', 'artist_tok', 'album_tok', 'filename_tok',
                                  'lyrics_tok', 'lyrics_tr_tok')
                    ORDER BY term
                    """;
                using var reader = query.ExecuteReader();
                while (reader.Read())
                {
                    if (reader.IsDBNull(0)) continue;
                    var term = reader.GetString(0);
                    if (IsAsciiWord(term)) terms.Add(term);
                }
            }
        }
        catch (Exception ex)
        {
            Log.LogInfo("indexer", $"模糊词典加载失败，退回无词典过滤: {ex.Message}");
            terms.Clear();
        }

        _fuzzyVocabulary = terms.ToArray();
        _fuzzyVocabularyEpoch = _writeEpoch;
        return _fuzzyVocabulary;
    }

    private static bool IsAsciiWord(string term)
    {
        if (term.Length == 0) return false;
        foreach (var c in term)
        {
            if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) continue;
            return false;
        }
        return true;
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
            ApplyMeta(meta, key, value);
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
            ("romaji_lyrics", meta.RomajiLyrics ? "1" : "0"),
            ("applied_generation", meta.AppliedGeneration.ToString(CultureInfo.InvariantCulture)),
            ("built_at", meta.BuiltAt.ToString(CultureInfo.InvariantCulture)),
            ("full_build_at", meta.FullBuildAt.ToString(CultureInfo.InvariantCulture)),
            ("has_japanese", meta.HasJapanese ? "1" : "0"),
            ("has_korean", meta.HasKorean ? "1" : "0"),
            ("has_han", meta.HasHan ? "1" : "0"),
            ("has_latin", meta.HasLatin ? "1" : "0"),
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
            using var conn = new SqliteConnection(ConnectionString(path, readOnly: true));
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
                ApplyMeta(meta, key, value);
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
              indexed_generation INTEGER, schema_version INTEGER,
              reading_tok TEXT NOT NULL DEFAULT ''
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
        cmd.Parameters.AddWithValue("@reading", f.ReadingText);
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
        _writeEpoch++;
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

    /// <summary>
    /// 本模块的 SQLite 连接串：**一律 <c>Pooling=False</c>，勿绕开本方法自拼连接串**。
    ///
    /// 原因（实测回归，见 `tests/EndToEnd.cs` 的 `RepeatedFullBuild`）：世代化替换
    /// （<see cref="Seal"/>）把临时世代 <c>&lt;path&gt;.tmp</c> 用
    /// <see cref="File.Move(string,string,bool)"/> **改名**成正式库，而
    /// Microsoft.Data.Sqlite 默认启用**连接池**——`Close()` 后底层 sqlite3 句柄
    /// （持有文件描述符）仍留在线程池里按连接串复用。于是同一进程内的下一次构建会
    /// 拿到**指向已改名/已 unlink 的 inode** 的陈旧句柄：
    /// <list type="bullet">
    ///   <item>全量构建：写入落到正式库（**绕过了世代化原子替换**），随后
    ///         <c>Fsync(_tmpPath)</c> / <c>File.Move(_tmpPath, …)</c> 找不到 tmp →
    ///         <c>Could not find file '&lt;…&gt;.tmp'</c>，即「同一进程内第二次全量构建
    ///         必然失败」；</item>
    ///   <item>增量构建：写进已 unlink 的旧 inode → **静默丢失更新**（曲库变更后
    ///         新曲目搜不到，直到重启进程）。</item>
    /// </list>
    /// 索引器的连接都是「一次运行一开一关」的短命连接，池化毫无收益，故全部关闭。
    /// </summary>
    internal static string ConnectionString(string path, bool readOnly = false)
        => readOnly
            ? $"Data Source={path};Mode=ReadOnly;Pooling=False"
            : $"Data Source={path};Pooling=False";

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

    private static bool ParseBool(string value)
        => value == "1" || value.Equals("true", StringComparison.OrdinalIgnoreCase);

    /// <summary><see cref="ReadMeta"/> 与 <see cref="PeekMeta"/> 共用的键解析（避免两处漂移）。</summary>
    private static void ApplyMeta(StoreMeta meta, string key, string value)
    {
        switch (key)
        {
            case "schema_version": meta.SchemaVersion = ParseInt(value); break;
            case "analyzer_version": meta.AnalyzerVersion = ParseInt(value); break;
            case "index_lrc": meta.IndexLrc = ParseBool(value); break;
            case "pinyin": meta.Pinyin = ParseBool(value); break;
            case "romaji_lyrics": meta.RomajiLyrics = ParseBool(value); break;
            case "applied_generation": meta.AppliedGeneration = ParseLong(value); break;
            case "built_at": meta.BuiltAt = ParseLong(value); break;
            case "full_build_at": meta.FullBuildAt = ParseLong(value); break;
            case "has_japanese": meta.HasJapanese = ParseBool(value); break;
            case "has_korean": meta.HasKorean = ParseBool(value); break;
            case "has_han": meta.HasHan = ParseBool(value); break;
            case "has_latin": meta.HasLatin = ParseBool(value); break;
        }
    }
}
