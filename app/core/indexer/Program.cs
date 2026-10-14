// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

using Microsoft.Data.Sqlite;

namespace Archoera.Indexer;

/// <summary>
/// Archoera 本地曲库搜索索引器 CLI。
///
/// 用法：
///   archoera-indexer build [--full] [--index-lrc] [--no-pinyin] [--db &lt;library.db&gt;]
///                          [--index &lt;search.db&gt;] [--batch &lt;n&gt;]
///   archoera-indexer query &lt;text&gt; [--index &lt;search.db&gt;] [--limit &lt;n&gt;] [--raw]
///   archoera-indexer analyze &lt;field&gt; &lt;text&gt;
///   archoera-indexer version
///
/// stdout：JSON 进度 / 结果（TS / Dart 风格，与 scanner 一致）；stderr：人类日志。
/// exit code：0=成功，1=参数 / 运行错误，2=取消。
/// </summary>
public static class Program
{
    public static int Main(string[] args)
    {
        if (args.Length == 0)
        {
            PrintUsage();
            return 1;
        }

        return args[0].ToLowerInvariant() switch
        {
            "build" => RunBuild(args[1..]),
            "query" => RunQuery(args[1..]),
            "analyze" => RunAnalyze(args[1..]),
            "version" => RunVersion(),
            "-h" or "--help" or "help" => PrintUsage(),
            _ => UnknownCommand(args[0]),
        };
    }

    /* ------------------------------------------------------------------ */
    /* build                                                               */
    /* ------------------------------------------------------------------ */

    private static int RunBuild(string[] args)
    {
        var full = false;
        var options = new IndexerOptions();
        string? dbPath = null;
        string? indexPath = null;

        for (int i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--full": case "-f": full = true; break;
                case "--index-lrc": options.IndexLrc = true; break;
                case "--no-pinyin": options.Pinyin = false; break;
                case "--db": if (i + 1 < args.Length) dbPath = args[++i]; break;
                case "--index": if (i + 1 < args.Length) indexPath = args[++i]; break;
                case "--batch": if (i + 1 < args.Length && int.TryParse(args[++i], out var b)) options.Batch = b; break;
                case "--help": case "-h": PrintUsage(); return 0;
            }
        }

        dbPath ??= Environment.GetEnvironmentVariable("ARCHOERA_DB_PATH");
        if (string.IsNullOrEmpty(dbPath))
        {
            Log.LogError("indexer", "缺少源曲库路径：请设置 ARCHOERA_DB_PATH 或使用 --db <library.db>。");
            return 1;
        }
        if (!File.Exists(dbPath))
        {
            Log.LogError("indexer", $"源曲库不存在: {dbPath}");
            return 1;
        }
        indexPath ??= Path.Combine(Path.GetDirectoryName(Path.GetFullPath(dbPath)) ?? ".", "search.db");

        Log.LogInfo("indexer", $"library={dbPath}");
        Log.LogInfo("indexer", $"index={indexPath} full={full} index_lrc={options.IndexLrc} pinyin={options.Pinyin}");

        using var cts = new CancellationTokenSource();
        Console.CancelKeyPress += (_, e) => { e.Cancel = true; cts.Cancel(); };

        using var store = new FtsStore();
        var engine = new IndexerEngine(store, p => Console.WriteLine(IndexerJson.Progress(p)));
        try
        {
            var result = engine.Run(dbPath, indexPath, full, options, cts.Token);
            Console.WriteLine(IndexerJson.Result(result));
            return 0;
        }
        catch (OperationCanceledException)
        {
            Log.LogWarn("indexer", "已取消");
            return 2;
        }
        catch (Exception ex)
        {
            Log.LogFatal("indexer", $"FATAL: {ex}");
            return 1;
        }
    }

    /* ------------------------------------------------------------------ */
    /* query（调试：跑 bm25 排序）                                          */
    /* ------------------------------------------------------------------ */

    private static int RunQuery(string[] args)
    {
        if (args.Length == 0 || args[0].StartsWith('-'))
        {
            Console.Error.WriteLine("用法: indexer query <text> [--index <search.db>] [--limit <n>] [--raw]");
            return 1;
        }

        var text = args[0];
        var raw = false;
        var limit = 20;
        string? indexPath = null;

        for (int i = 1; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--raw": raw = true; break;
                case "--index": if (i + 1 < args.Length) indexPath = args[++i]; break;
                case "--limit": if (i + 1 < args.Length && int.TryParse(args[++i], out var n)) limit = n; break;
            }
        }

        indexPath ??= Path.Combine(Directory.GetCurrentDirectory(), "search.db");
        if (!File.Exists(indexPath))
        {
            Log.LogError("indexer", $"索引不存在: {indexPath}");
            return 1;
        }

        // 默认把输入当“人话”，经同一分析器归一为词元（AND 短语）；--raw 则原样作 FTS5 表达式。
        var matchExpr = raw ? text : BuildMatchExpression(text);
        Log.LogInfo("indexer", $"MATCH: {matchExpr}");

        using var store = new FtsStore();
        store.Open(indexPath, build: false);
        // CLI 是人工判读工具：默认**不限候选**（0），看真实全量排序（生产走 candidateCap）。
        var rows = store.Search(matchExpr, limit, 0, 0);

        // 附加 track_id 便于人工判读（只读连接，WAL 下可并发）
        var trackIds = ResolveTrackIds(indexPath, rows.Select(r => r.DocId).ToList());
        Console.WriteLine(IndexerJson.SearchResults(rows, trackIds));
        return 0;
    }

    /// <summary>把查询文本经分析器归一为 FTS5 MATCH 表达式（词元以空格 = 隐式 AND）。</summary>
    private static string BuildMatchExpression(string text)
    {
        var query = Analyzer.AnalyzeQuery(text);
        var tokens = query.Lexical.Where(t => t.Length > 0).ToList();
        if (tokens.Count == 0) return "\"\"";
        return string.Join(' ', tokens);
    }

    private static Dictionary<long, string> ResolveTrackIds(string indexPath, List<long> docIds)
    {
        var map = new Dictionary<long, string>();
        if (docIds.Count == 0) return map;
        try
        {
            using var conn = new SqliteConnection($"Data Source={indexPath};Mode=ReadOnly");
            conn.Open();
            using var cmd = conn.CreateCommand();
            var names = new List<string>();
            for (int i = 0; i < docIds.Count; i++)
            {
                names.Add("@p" + i);
                cmd.Parameters.AddWithValue("@p" + i, docIds[i]);
            }
            cmd.CommandText = $"SELECT doc_id, track_id FROM search_docs WHERE doc_id IN ({string.Join(',', names)})";
            using var reader = cmd.ExecuteReader();
            while (reader.Read()) map[reader.GetInt64(0)] = reader.GetString(1);
        }
        catch (Exception ex)
        {
            Log.LogWarn("indexer", $"解析 track_id 失败: {ex.Message}");
        }
        return map;
    }

    /* ------------------------------------------------------------------ */
    /* analyze / version（P1 保留）                                         */
    /* ------------------------------------------------------------------ */

    private static int RunAnalyze(string[] args)
    {
        if (args.Length < 2)
        {
            Console.Error.WriteLine("用法: indexer analyze <field> <text>");
            return 1;
        }
        if (!TryParseField(args[0], out _))
        {
            Console.Error.WriteLine($"未知字段: {args[0]}（可用: title/artist/album/lyrics/lyrics_tr/lyrics_rom/filename 或 0..6）");
            return 1;
        }

        Console.WriteLine(IndexerJson.Analysis(Analyzer.Analyze(args[1])));
        return 0;
    }

    private static int RunVersion()
    {
        Console.WriteLine(IndexerJson.Version(Analyzer.AnalyzerVersion));
        return 0;
    }

    private static int PrintUsage()
    {
        Console.Error.WriteLine("""
            Archoera 本地曲库搜索索引器

            用法:
              archoera-indexer build [--full] [--index-lrc] [--no-pinyin]
                                     [--db <library.db>] [--index <search.db>] [--batch <n>]
                  构建 / 增量更新搜索索引（默认增量）。stdout 输出 JSON 进度与结果。
              archoera-indexer query <text> [--index <search.db>] [--limit <n>] [--raw]
                  调试查询（bm25 排序）。默认经分析器归一；--raw 传入原始 FTS5 MATCH 表达式。
              archoera-indexer analyze <field> <text>
                  分析文本，stdout 输出 {"tokens":"...","pinyin":"...","initials":"..."}
              archoera-indexer version
                  输出版本锚点 {"analyzerVersion":1}
              archoera-indexer -h | --help
                  打印本用法

            环境变量:
              ARCHOERA_DB_PATH  源曲库路径（build 的默认 --db）

            字段（<field>，大小写不敏感，或 0..6）:
              title | artist | album | lyrics | lyrics_tr | lyrics_rom | filename
            """);
        return 0;
    }

    private static int UnknownCommand(string command)
    {
        Console.Error.WriteLine($"未知命令: {command}");
        PrintUsage();
        return 1;
    }

    private static bool TryParseField(string value, out Field field)
    {
        switch (value.ToLowerInvariant())
        {
            case "title": field = Field.Title; return true;
            case "artist" or "artists": field = Field.Artist; return true;
            case "album": field = Field.Album; return true;
            case "lyrics" or "lyrics_original": field = Field.LyricsOriginal; return true;
            case "lyrics_tr" or "lyricstr" or "translation": field = Field.LyricsTranslation; return true;
            case "lyrics_rom" or "lyricsrom" or "romaji": field = Field.LyricsRomaji; return true;
            case "filename": field = Field.Filename; return true;
        }

        if (int.TryParse(value, out var index) && index >= 0 && index <= (int)Field.Filename)
        {
            field = (Field)index;
            return true;
        }

        field = default;
        return false;
    }
}
