// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

using System.Diagnostics;
using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace Archoera.Indexer;

/// <summary>阶段一（脏集探测）轻量行：仅 <c>id/path/file_mtime</c>，**不含歌词 / 元数据大列**。</summary>
internal sealed class TrackProbe
{
    public string Id { get; init; } = "";
    public string Path { get; init; } = "";
    public long Mtime { get; init; }
}

/// <summary>曲库 <c>tracks</c> 行的分析期只读投影（阶段二按脏 id 取内容）。</summary>
internal sealed class TrackRecord
{
    public string Id { get; init; } = "";
    public string Path { get; init; } = "";
    public string Title { get; init; } = "";
    public string ArtistText { get; init; } = "";
    public string AlbumText { get; init; } = "";
    public string Lyrics { get; init; } = "";
    public long Mtime { get; init; }
}

/// <summary>
/// 增量调度 + 分层分析 + 写 FTS5（设计文档 §3 / §4 / §6）。
///
/// 数据源：只读 <c>library.db</c> 的 <c>tracks</c> 表（scanner 写的源真值）；
/// 输出：经 <see cref="IIndexStore"/> 写 <c>search.db</c>。**不修改 scanner / library.db**。
///
/// **两阶段**（设计文档 §2.2「增量 ≈ K 成正比」）：
/// <list type="number">
///   <item><b>脏集探测</b>：只读轻量列 <c>id/path/file_mtime</c>（不含 lyrics/title/artists/album），
///         结合既有 <see cref="DocState"/> 与 <c>.lrc</c> <c>(mtime,size)</c> 判定脏 <c>track_id</c>；
///         全量模式所有 id 皆脏。</item>
///   <item><b>取内容 + 分析</b>：仅按脏 id 分块取完整列（<c>WHERE id IN (…)</c>，块大小
///         <see cref="ContentChunkSize"/>）并 <see cref="IIndexStore.Put"/>；无脏曲零内容读取。</item>
/// </list>
/// 删除判定仍只用阶段一的 id 集合（<c>state</c> 中不在 <c>tracks</c> 的 <c>track_id</c>）。
/// 脏集规则（确定性，无 sleep / 轮询）：
/// <list type="bullet">
///   <item>新增/变更 = <c>track_id</c> 不在索引，或 <c>file_mtime ≠ indexed_mtime</c>；</item>
///   <item><c>.lrc</c> 侧车 <c>(mtime,size)</c> 与已索引不符（含子开关关→开 / 开→关的清理）；</item>
///   <item>schema / analyzer 版本或拼音开关不一致 → 强制全量。</item>
/// </list>
/// 同步执行（run-to-completion），由调用方在后台线程调度；通过
/// <see cref="Action{T}"/> 上报进度、<see cref="CancellationToken"/> 取消。
/// </summary>
public sealed class IndexerEngine
{
    private const int ProgressEvery = 50;

    /// <summary>阶段二按脏 id 取内容的单次分块大小（减少 SQL 往返；参数化、id 为 TEXT）。</summary>
    private const int ContentChunkSize = 500;

    private readonly IIndexStore _store;
    private readonly Action<IndexerProgress>? _progress;

    /// <summary>
    /// 阶段二「取内容」SQL 的执行次数（分块查询计数）。
    /// 测试用：增量无脏曲时应为 0，证明未读取歌词 / 元数据大列。
    /// </summary>
    internal int ContentQueries { get; private set; }

    public IndexerEngine(IIndexStore store, Action<IndexerProgress>? progress = null)
    {
        _store = store;
        _progress = progress;
    }

    /// <summary>
    /// 构建 / 增量更新索引。
    /// </summary>
    /// <param name="libraryPath">源 <c>library.db</c> 路径（只读）。</param>
    /// <param name="indexPath">目标 <c>search.db</c> 路径。</param>
    /// <param name="full">true = 强制全量；false = 增量（版本不符时自动升级为全量）。</param>
    public IndexerResult Run(
        string libraryPath, string indexPath, bool full, IndexerOptions options,
        CancellationToken cancellationToken = default)
    {
        var stopwatch = Stopwatch.StartNew();
        var builtAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

        if (!File.Exists(libraryPath))
            throw new FileNotFoundException("源曲库不存在", libraryPath);

        // 版本 / 选项判定（在打开存储前预读既有元数据，避免无谓重建）
        var prev = FtsStore.PeekMeta(indexPath);
        var needFull = full
            || prev is null
            || prev.SchemaVersion != _store.SchemaVersion
            || prev.AnalyzerVersion != Analyzer.AnalyzerVersion
            || prev.Pinyin != options.Pinyin;

        _store.Open(indexPath, needFull);
        if (_store is not IIndexStoreAdmin admin)
            throw new InvalidOperationException("存储实现未提供增量管理视图（IIndexStoreAdmin）。");
        if (options.Batch > 0) admin.BatchSize = options.Batch;

        var state = needFull ? new Dictionary<string, DocState>(StringComparer.Ordinal) : admin.LoadState();
        var nextDocId = needFull ? 1L : admin.NextDocId;

        long generation = ReadScannerGeneration(libraryPath);

        var total = CountTracks(libraryPath);
        int processed = 0, indexed = 0, deleted = 0;

        void Fire(string phase, string current) => _progress?.Invoke(new IndexerProgress
        {
            Phase = phase,
            Total = total,
            Processed = processed,
            Indexed = indexed,
            Deleted = deleted,
            Current = current,
        });

        Fire("collect", needFull ? "full" : "incremental");

        // ---- 阶段一：轻量脏集探测（仅 id/path/file_mtime + .lrc stat） ----
        var dirty = new List<DirtyTrack>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var probe in ReadTrackProbes(libraryPath, cancellationToken))
        {
            cancellationToken.ThrowIfCancellationRequested();
            processed++;
            seen.Add(probe.Id);

            // .lrc 只 stat（不读内容）
            var lrc = options.IndexLrc ? LrcReader.Probe(probe.Path) : LrcReader.LrcProbe.None;
            long curLrcM = lrc.Exists ? lrc.Mtime : 0;
            long curLrcS = lrc.Exists ? lrc.Size : 0;

            var isDirty = needFull;
            if (!isDirty)
            {
                if (!state.TryGetValue(probe.Id, out var existing))
                {
                    isDirty = true;
                }
                else
                {
                    isDirty = existing.Mtime != probe.Mtime
                        || (options.IndexLrc
                            ? existing.LrcMtime != curLrcM || existing.LrcSize != curLrcS
                            : existing.LrcMtime != 0 || existing.LrcSize != 0);
                }
            }

            if (isDirty)
                dirty.Add(new DirtyTrack { Id = probe.Id, Path = probe.Path, Lrc = lrc });

            if (processed % ProgressEvery == 0) Fire("collect", probe.Path);
        }
        total = seen.Count;

        // ---- 阶段二：仅对脏 id 分块取内容 + 分析 + 写 FTS（无脏曲 = 零内容读取） ----
        if (dirty.Count > 0)
        {
            for (int offset = 0; offset < dirty.Count; offset += ContentChunkSize)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var chunk = dirty.GetRange(offset, Math.Min(ContentChunkSize, dirty.Count - offset));
                var contents = ReadTrackContents(libraryPath, chunk, cancellationToken);
                ContentQueries++;

                foreach (var item in chunk)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    if (!contents.TryGetValue(item.Id, out var track))
                    {
                        // 阶段一与阶段二之间曲目被并发删除：跳过（下一轮按删除收敛）
                        Log.LogWarn("indexer", $"曲目在索引过程中消失，跳过: {item.Id}");
                        continue;
                    }

                    var docId = state.TryGetValue(item.Id, out var st) ? st.DocId : nextDocId++;
                    _store.Put(docId, BuildTokens(track, item.Lrc, options, generation));
                    indexed++;

                    if (indexed % ProgressEvery == 0) Fire("index", item.Path);
                }
            }
        }

        var skipped = total - indexed;

        // 删除：既有文档中 track_id 已不在 tracks（含全量下的空集→无操作）
        if (!needFull)
        {
            foreach (var (trackId, st) in state)
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (seen.Contains(trackId)) continue;
                _store.Delete(st.DocId);
                deleted++;
            }
        }

        Fire("commit", "");

        admin.WriteMeta(new StoreMeta
        {
            IndexLrc = options.IndexLrc,
            Pinyin = options.Pinyin,
            AppliedGeneration = generation,
            BuiltAt = builtAt,
            FullBuildAt = needFull ? builtAt : (prev?.FullBuildAt ?? builtAt),
        });

        _store.Optimize();
        _store.Commit();
        admin.Seal();

        stopwatch.Stop();
        Fire("done", "");

        return new IndexerResult
        {
            Total = total,
            Indexed = indexed,
            Deleted = deleted,
            Skipped = skipped,
            Full = needFull,
            Generation = generation,
            DurationMs = stopwatch.ElapsedMilliseconds,
        };
    }

    /// <summary>阶段一脏曲项：轻量探测结果 + 已 stat 的 <c>.lrc</c> 供阶段二复用（免重复探测）。</summary>
    private sealed class DirtyTrack
    {
        public string Id { get; init; } = "";
        public string Path { get; init; } = "";
        public LrcReader.LrcProbe Lrc { get; init; }
    }

    /* ------------------------------------------------------------------ */
    /* 分层分析                                                            */
    /* ------------------------------------------------------------------ */

    private static DocTokens BuildTokens(TrackRecord track, LrcReader.LrcProbe probe, IndexerOptions options, long generation)
    {
        var title = Analyzer.Analyze(track.Title);
        var artist = Analyzer.Analyze(track.ArtistText);
        var album = Analyzer.Analyze(track.AlbumText);

        // 内嵌歌词可能本身是 LRC（含时间轴 / 多语言同时间戳行），与 .lrc 侧车**一致**
        // 走同一分层启发式（LrcReader.SplitText）：原文 / 译文 / 音译分别入库。
        var embedded = LrcReader.SplitText(track.Lyrics);
        var sidecar = LrcReader.LrcLayers.Empty;
        if (options.IndexLrc && probe.Exists)
        {
            var lrc = LrcReader.Read(track.Path);
            if (lrc.Exists) sidecar = new LrcReader.LrcLayers(lrc.Original, lrc.Translation, lrc.Romaji);
        }

        var lyrics = Analyzer.Analyze(JoinLayers(embedded.Original, sidecar.Original));
        var translation = Analyzer.Analyze(JoinLayers(embedded.Translation, sidecar.Translation));
        var romaji = Analyzer.Analyze(JoinLayers(embedded.Romaji, sidecar.Romaji));
        var filename = Analyzer.Analyze(Path.GetFileNameWithoutExtension(track.Path));

        return new DocTokens
        {
            TrackId = track.Id,
            TitleTok = title.Tokens,
            ArtistTok = artist.Tokens,
            AlbumTok = album.Tokens,
            LyricsTok = lyrics.Tokens,
            LyricsTrTok = translation.Tokens,
            LyricsRomTok = romaji.Tokens,
            PinyinTok = options.Pinyin
                ? CombinePinyin(title, artist, album, lyrics, filename)
                : "",
            FilenameTok = filename.Tokens,
            IndexedMtime = track.Mtime,
            IndexedLrcMtime = probe.Exists ? probe.Mtime : 0,
            IndexedLrcSize = probe.Exists ? probe.Size : 0,
            IndexedGeneration = generation,
        };
    }

    /// <summary>拼接内嵌层与侧车层文本（非空者以 <c>\n</c> 连接）；两者皆空返回空串。</summary>
    private static string JoinLayers(string embedded, string sidecar)
    {
        if (embedded.Length == 0) return sidecar;
        if (sidecar.Length == 0) return embedded;
        return embedded + "\n" + sidecar;
    }

    /// <summary>
    /// 拼音列 = 各源（title/artist/album/lyrics/filename）的全拼 + 首字母，空格连接。
    /// 空串段自动跳过，避免多余空格。
    /// </summary>
    private static string CombinePinyin(params AnalysisResult[] sources)
    {
        var parts = new List<string>();
        foreach (var source in sources)
        {
            if (source.Pinyin.Length > 0) parts.Add(source.Pinyin);
            if (source.PinyinInitials.Length > 0) parts.Add(source.PinyinInitials);
        }
        return string.Join(' ', parts);
    }

    /* ------------------------------------------------------------------ */
    /* library.db 只读访问                                                 */
    /* ------------------------------------------------------------------ */

    private static SqliteConnection OpenLibraryReadOnly(string libraryPath)
    {
        var conn = new SqliteConnection($"Data Source={libraryPath};Mode=ReadOnly");
        conn.Open();
        return conn;
    }

    /// <summary>
    /// 轻量曲目计数（仅用于首条进度上报，不含任何列载荷）；失败时回退 0（不影响主流程）。
    /// </summary>
    private static int CountTracks(string libraryPath)
    {
        try
        {
            using var conn = OpenLibraryReadOnly(libraryPath);
            using var cmd = conn.CreateCommand();
            cmd.CommandText = "SELECT COUNT(*) FROM tracks";
            var value = cmd.ExecuteScalar();
            return value is null || value is DBNull
                ? 0
                : Convert.ToInt32(value, System.Globalization.CultureInfo.InvariantCulture);
        }
        catch (Exception ex)
        {
            Log.LogWarn("indexer", $"统计 tracks 失败: {ex.Message}");
            return 0;
        }
    }

    /// <summary>阶段一：流式读取轻量列（<c>id/path/file_mtime</c>），不含歌词 / 元数据大列。</summary>
    private static IEnumerable<TrackProbe> ReadTrackProbes(string libraryPath, CancellationToken ct)
    {
        using var conn = OpenLibraryReadOnly(libraryPath);
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "SELECT id, path, file_mtime FROM tracks ORDER BY id";
        using var reader = cmd.ExecuteReader();
        while (reader.Read())
        {
            ct.ThrowIfCancellationRequested();
            yield return new TrackProbe
            {
                Id = reader.IsDBNull(0) ? "" : reader.GetString(0),
                Path = reader.IsDBNull(1) ? "" : reader.GetString(1),
                Mtime = reader.IsDBNull(2) ? 0 : reader.GetInt64(2),
            };
        }
    }

    /// <summary>
    /// 阶段二：按脏 id 分块取完整列（<c>WHERE id IN (…)</c>，参数化、<c>id</c> 为 TEXT），
    /// 返回按 <c>id</c> 索引的字典。仅对脏曲调用。
    /// </summary>
    private static Dictionary<string, TrackRecord> ReadTrackContents(
        string libraryPath, List<DirtyTrack> chunk, CancellationToken ct)
    {
        var map = new Dictionary<string, TrackRecord>(StringComparer.Ordinal);
        using var conn = OpenLibraryReadOnly(libraryPath);
        using var cmd = conn.CreateCommand();

        var placeholders = new string[chunk.Count];
        for (int i = 0; i < chunk.Count; i++)
        {
            placeholders[i] = "@p" + i;
            cmd.Parameters.AddWithValue(placeholders[i], chunk[i].Id);
        }
        cmd.CommandText =
            $"SELECT id, path, title, artists, album, lyrics, file_mtime FROM tracks WHERE id IN ({string.Join(',', placeholders)})";

        using var reader = cmd.ExecuteReader();
        while (reader.Read())
        {
            ct.ThrowIfCancellationRequested();
            var record = new TrackRecord
            {
                Id = reader.IsDBNull(0) ? "" : reader.GetString(0),
                Path = reader.IsDBNull(1) ? "" : reader.GetString(1),
                Title = reader.IsDBNull(2) ? "" : reader.GetString(2),
                ArtistText = ParseArtists(reader.IsDBNull(3) ? null : reader.GetString(3)),
                AlbumText = ParseAlbum(reader.IsDBNull(4) ? null : reader.GetString(4)),
                Lyrics = reader.IsDBNull(5) ? "" : reader.GetString(5),
                Mtime = reader.IsDBNull(6) ? 0 : reader.GetInt64(6),
            };
            map[record.Id] = record;
        }
        return map;
    }

    /// <summary>解析 scanner 写入的 <c>artists</c> JSON 数组 <c>[{"name":"…"}]</c> 为空格连接文本。</summary>
    private static string ParseArtists(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return "";
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (doc.RootElement.ValueKind != JsonValueKind.Array) return "";
            var names = new List<string>();
            foreach (var element in doc.RootElement.EnumerateArray())
            {
                if (element.ValueKind == JsonValueKind.Object
                    && element.TryGetProperty("name", out var name)
                    && name.ValueKind == JsonValueKind.String)
                {
                    var value = name.GetString();
                    if (!string.IsNullOrWhiteSpace(value)) names.Add(value);
                }
            }
            return string.Join(' ', names);
        }
        catch (JsonException)
        {
            return "";
        }
    }

    /// <summary>解析 scanner 写入的 <c>album</c> JSON 对象 <c>{"name":"…"}</c> 的 name。</summary>
    private static string ParseAlbum(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return "";
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (doc.RootElement.ValueKind != JsonValueKind.Object) return "";
            if (doc.RootElement.TryGetProperty("name", out var name) && name.ValueKind == JsonValueKind.String)
                return name.GetString() ?? "";
            return "";
        }
        catch (JsonException)
        {
            return "";
        }
    }

    /// <summary>
    /// 读取 <c>_scanner_meta(generation INTEGER)</c> 的世代水位线（只读）。
    /// 表/行缺失时返回 0（前向兼容，不报错）。
    /// </summary>
    private static long ReadScannerGeneration(string libraryPath)
    {
        try
        {
            using var conn = OpenLibraryReadOnly(libraryPath);
            using (var probe = conn.CreateCommand())
            {
                probe.CommandText = "SELECT 1 FROM sqlite_master WHERE type='table' AND name='_scanner_meta' LIMIT 1";
                if (probe.ExecuteScalar() is null) return 0;
            }
            using var cmd = conn.CreateCommand();
            cmd.CommandText = "SELECT generation FROM _scanner_meta LIMIT 1";
            var value = cmd.ExecuteScalar();
            return value is null || value is DBNull ? 0 : Convert.ToInt64(value, System.Globalization.CultureInfo.InvariantCulture);
        }
        catch (Exception ex)
        {
            Log.LogWarn("indexer", $"读取 _scanner_meta 失败（按世代 0 处理）: {ex.Message}");
            return 0;
        }
    }
}
