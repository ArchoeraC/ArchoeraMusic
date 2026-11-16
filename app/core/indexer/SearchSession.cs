// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

using System.Globalization;
using System.Text.Json;
using Archoera.Text;

namespace Archoera.Indexer;

/// <summary>单次查询请求（FFI JSON 反序列化后的强类型视图）。</summary>
internal sealed class SearchRequest
{
    public string Query { get; init; } = "";

    /// <summary>只搜元数据（标题 / 歌手 / 专辑 / 文件名），不触歌词 / 译文 / 音译。</summary>
    public bool Metadata { get; init; }

    public int Limit { get; init; } = 200;

    public int Offset { get; init; }

    /// <summary>启用模糊趟（拉丁编辑距离 + 中文删除 / 换位）；兜底趟不受此开关影响。</summary>
    public bool Fuzzy { get; init; }

    /// <summary>命中数达到该值即停止继续兜底（默认 1：主趟有命中就不再兜底）。</summary>
    public int MinExact { get; init; } = 1;

    /// <summary>
    /// 候选集上限（**历史参数，已不再裁剪候选**）。
    ///
    /// 保留字段仅为请求 JSON 兼容；<see cref="FtsStore.Search"/> 已忽略它——
    /// 原实现会让 FTS5 的 bm25 静默返回 0、排序整体失效（见设计文档 §4.5）。
    /// </summary>
    public int CandidateCap { get; init; } = FtsStore.DefaultCandidateCap;

    public static SearchRequest Parse(string json)
    {
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        if (root.ValueKind != JsonValueKind.Object)
            throw new InvalidOperationException("request_json 必须是 JSON 对象");

        var query = root.TryGetProperty("query", out var q) && q.ValueKind == JsonValueKind.String
            ? q.GetString() ?? ""
            : "";
        return new SearchRequest
        {
            Query = query,
            Metadata = root.TryGetProperty("scope", out var scope)
                && scope.ValueKind == JsonValueKind.String
                && string.Equals(scope.GetString(), "metadata", StringComparison.OrdinalIgnoreCase),
            Limit = ReadInt(root, "limit", 200),
            Offset = ReadInt(root, "offset", 0),
            Fuzzy = ReadBool(root, "fuzzy", false),
            MinExact = ReadInt(root, "minExact", 1),
            CandidateCap = ReadInt(root, "candidateCap", FtsStore.DefaultCandidateCap),
        };
    }

    private static int ReadInt(JsonElement root, string name, int fallback)
        => root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Number
            && value.TryGetInt32(out var parsed)
            ? parsed
            : fallback;

    private static bool ReadBool(JsonElement root, string name, bool fallback)
        => root.TryGetProperty(name, out var value) && value.ValueKind is JsonValueKind.True or JsonValueKind.False
            ? value.GetBoolean()
            : fallback;
}

/// <summary>
/// 单条命中（bm25 分数越小越相关）。
///
/// <paramref name="Pass"/> 是**命中原由归因**（精度审计 §6.3 / M-7）：本命中由哪一趟召回。
/// 排障时「为什么这首会被搜出」的直接答案；也是「同一条命中不能被低优先趟覆盖」的依据
/// （<see cref="SearchSession"/> 的合并按趟次顺序进行，先到者保留）。
/// </summary>
internal readonly record struct SearchHit(string TrackId, double Score, string Pass);

/// <summary>命中趟次名（与 <see cref="PassCounts"/> 的字段一一对应，供 UI / 日志归因）。</summary>
internal static class SearchPassNames
{
    public const string Lexical = "lexical";
    public const string PinyinLoose = "pinyinLoose";
    public const string Reading = "reading";
    public const string CrossLingual = "crossLingual";
    public const string Fuzzy = "fuzzy";
    public const string CjkFuzzy = "cjkFuzzy";

    /// <summary>
    /// **丢词降级趟**：多词查询命中不足时，从末尾开始逐个丢弃 query 词后重新召回。
    ///
    /// 与 <see cref="Lexical"/> 同属「字面匹配」，只是少了约束——**方向最安全**的放宽
    /// （指标见 <c>docs/local-search-indexer-references.md</c> §6.2）。
    /// </summary>
    public const string DropTokens = "dropTokens";
}

/// <summary>本次查询实际执行的兜底趟（0 / 1；用于诊断与回归计数）。</summary>
internal sealed class PassCounts
{
    public int PinyinLoose { get; set; }
    public int Reading { get; set; }
    public int CrossLingual { get; set; }
    public int Fuzzy { get; set; }
    public int CjkFuzzy { get; set; }
    public int DropTokens { get; set; }
}

/// <summary>查询结果（按趟次合并去重后的 top-k）。</summary>
internal sealed class SearchResult
{
    public List<SearchHit> Items { get; } = new();
    public PassCounts Passes { get; } = new();
}

/// <summary>
/// 只读查询会话：缓存一个 <see cref="FtsStore"/> 连接（按 <c>search.db</c> 路径复用），
/// 在库内执行「主趟 → 拼音宽松 → 日文读音 → 跨语言 → 模糊 → 中文容错」六段渐进查询。
///
/// 查询规则与旧 Dart <c>SearchIndex.search</c> 逐项等价；区别只是执行位置。
/// 所有调用在静态锁下串行——Dart 侧只在 UI isolate 查询，锁只用于防御。
/// </summary>
internal sealed class SearchSession : IDisposable
{
    private static readonly object Sync = new();
    private static SearchSession? _cached;

    private static long _cacheHits;
    private static long _cacheMisses;

    private readonly FtsStore _store;
    private readonly string _path;
    private readonly StoreMeta _meta;

    /// <summary>查询结果 LRU 容量（优化计划 §4-2：128 条 top-k）。</summary>
    internal const int CacheCapacity = 128;

    /// <summary>单条结果超过该条数时不入缓存（防大 limit 的宽命中把内存放大到百 MB 级）。</summary>
    internal const int MaxCachedItems = 500;

    private readonly Dictionary<string, LinkedListNode<CachedQuery>> _cacheIndex =
        new(StringComparer.Ordinal);

    /// <summary>LRU 顺序：头部最新、尾部最旧。</summary>
    private readonly LinkedList<CachedQuery> _cacheOrder = new();

    private SearchSession(string path)
    {
        _path = Path.GetFullPath(path);
        _store = new FtsStore();
        _store.OpenReadOnly(_path);
        var meta = _store.ReadMeta();
        if (meta.SchemaVersion != FtsStore.SchemaVersionValue)
        {
            _store.Dispose();
            throw new InvalidOperationException(
                $"索引 schema 版本不匹配（库 {meta.SchemaVersion}，期望 {FtsStore.SchemaVersionValue}）");
        }
        _meta = meta;
    }

    /// <summary>释放缓存会话（重建索引 / 删除索引 / 退出查询前调用）。</summary>
    public static void CloseCached()
    {
        lock (Sync)
        {
            _cached?.Dispose();
            _cached = null;
        }
    }

    /// <summary>测试接缝：本进程累计的缓存命中次数（<see cref="DebugResetCacheStats"/> 清零）。</summary>
    internal static long DebugCacheHits => Interlocked.Read(ref _cacheHits);

    /// <summary>测试接缝：本进程累计的缓存未命中次数。</summary>
    internal static long DebugCacheMisses => Interlocked.Read(ref _cacheMisses);

    /// <summary>测试接缝：当前缓存的条目数（无会话时为 0）。</summary>
    internal static int DebugCacheCount
    {
        get
        {
            lock (Sync) return _cached?._cacheIndex.Count ?? 0;
        }
    }

    /// <summary>测试接缝：清零命中 / 未命中计数（不清空缓存内容）。</summary>
    internal static void DebugResetCacheStats()
    {
        Interlocked.Exchange(ref _cacheHits, 0);
        Interlocked.Exchange(ref _cacheMisses, 0);
    }

    /// <summary>执行一次查询；路径变化时自动切换会话。</summary>
    public static SearchResult Run(string path, SearchRequest request)
    {
        lock (Sync)
        {
            var full = Path.GetFullPath(path);
            if (_cached is null || !string.Equals(_cached._path, full, StringComparison.Ordinal))
            {
                _cached?.Dispose();
                _cached = new SearchSession(full);
            }
            return _cached.Execute(request);
        }
    }

    /// <summary>
    /// 执行一次查询（带结果 LRU 缓存，见优化计划 §4-2）。
    ///
    /// 输入去抖 250ms + 退格重放会产生同一查询的连续重复调用；命中直接返回上次的
    /// top-k（含 passes），不再走 FTS。缓存由会话实例持有，重建 / 删除 / 关闭索引时
    /// 都由 <see cref="CloseCached"/> 连同会话一起丢弃，无需额外失效逻辑。
    /// 返回的 <see cref="SearchResult"/> 视作只读：调用方（FFI 序列化 / 测试）不得修改。
    /// 线程安全：所有调用在 <see cref="Run"/> 的静态锁下串行，实例内无需再加锁。
    /// </summary>
    private SearchResult Execute(SearchRequest request)
    {
        var key = BuildCacheKey(request);
        if (_cacheIndex.TryGetValue(key, out var node))
        {
            _cacheOrder.Remove(node);
            _cacheOrder.AddFirst(node);
            Interlocked.Increment(ref _cacheHits);
            return node.Value.Result;
        }

        Interlocked.Increment(ref _cacheMisses);
        var result = ExecuteUncached(request);
        if (result.Items.Count > MaxCachedItems) return result;

        _cacheIndex[key] = _cacheOrder.AddFirst(new CachedQuery(key, result));
        if (_cacheIndex.Count > CacheCapacity)
        {
            var oldest = _cacheOrder.Last!;
            _cacheOrder.RemoveLast();
            _cacheIndex.Remove(oldest.Value.Key);
        }
        return result;
    }

    /// <summary>
    /// 缓存键：查询串（trim + 小写）+ 全部影响结果的请求参数 + 会话的 AnalyzerVersion。
    ///
    /// 不做 <see cref="Analyzer"/> 的完整归一化：中文容错趟的变体是先从**原串**取
    /// CJK 子序列再逐个分析的（见 <c>SearchQuery.CjkVariants</c>），深归一化会让两个
    /// 原串落到同一键却可能产出不同变体。trim + 小写只消除对结果无影响的差异
    /// （两侧编译都会归一化 / 去空白）。
    /// </summary>
    private string BuildCacheKey(SearchRequest request)
        => string.Join('\u0001',
            request.Query.Trim().ToLowerInvariant(),
            request.Metadata ? "meta" : "all",
            request.Limit.ToString(CultureInfo.InvariantCulture),
            request.Offset.ToString(CultureInfo.InvariantCulture),
            request.Fuzzy ? "fuzzy" : "exact",
            request.MinExact.ToString(CultureInfo.InvariantCulture),
            request.CandidateCap.ToString(CultureInfo.InvariantCulture),
            _meta.AnalyzerVersion.ToString(CultureInfo.InvariantCulture));

    private SearchResult ExecuteUncached(SearchRequest request)
    {
        var result = new SearchResult();
        var tokens = Analyzer.AnalyzeQuery(request.Query);
        var seen = new HashSet<string>(StringComparer.Ordinal);

        void Merge(string? expression, string pass, IReadOnlyList<string[]>? readingSequences = null)
        {
            if (expression is null) return;
            foreach (var hit in ExecuteMatch(expression, request, pass, readingSequences))
            {
                if (seen.Add(hit.TrackId)) result.Items.Add(hit);
            }
        }

        // 主趟：精确表达式（词法 / 拼音 / 首字母）。
        Merge(SearchQuery.CompileMatch(tokens, request.Metadata), SearchPassNames.Lexical);

        // 丢词降级（精度审计 §18 / §22 / §23）：多词查询主趟不足时，**先试「少匹配一个词」**，
        // 而不是直接放宽到读音 / 拼音 / 跨语言 / 容错。
        //
        // 理由：减词仍是**字面匹配**，只是少了约束；改读音是**换了一个维度**，
        // 语义可能完全无关（`鬱 → yu` 召回 36.8% 全库）。见
        // `docs/local-search-indexer-references.md` §6.2 的方向性区分。
        //
        // **逐轮尝试**（§22）：不能只丢末词就收工——`周杰伦 晴天` 丢掉「晴天」后
        // 仍会靠「周杰伦」返回结果，于是永远轮不到「保留晴天、丢掉周杰伦」这一轮。
        // 每一轮丢一个词、重新召回，命中数达到阈值即停。
        //
        // **按字段亲和度排序**（§23）：位置顺序只是初始猜测；更可靠的信号是
        // 「该词在 title 与 artist 列的命中分布」——只在 title 命中的词是歌名，最后才丢。
        // 这样「晴天 周杰伦」这类反向写法也能正确保留歌名。
        if (result.Items.Count < request.MinExact && SearchQuery.AllowDropTokens)
        {
            var candidates = SearchQuery.DropTokenCandidates(tokens, request.Query);
            if (candidates.Count > 0)
            {
                var (titleCounts, artistCounts) = ProbeFieldAffinity(request.Query, candidates.Count);
                candidates = SearchQuery.OrderDropsByFieldAffinity(
                    candidates, titleCounts, artistCounts);
            }

            foreach (var dropIndex in candidates)
            {
                var dropped = SearchQuery.CompileDropTokens(
                    tokens, request.Query, request.Metadata, dropIndex);
                if (dropped is null) continue;

                result.Passes.DropTokens = 1;
                Merge(dropped, SearchPassNames.DropTokens);

                // 丢掉第 i 个词后仍有后续丢法；但若本轮的命中已明显优于
                // 「丢掉更靠前 / 更靠后的词」，继续尝试也只会得到更宽的结果。
                // 直接以**第一个非空**的丢法为准，既避免取到最宽的结果，
                // 又保证「保留歌名」的丢法排在前面（见 DropTokenCandidates 的方向）。
                if (result.Items.Count >= request.MinExact) break;
            }
        }

        // 兜底趟只在主趟命中不足时付钱（渐进式，绝大多数查询止步于此）。
        if (result.Items.Count < request.MinExact)
        {
            var expression = SearchQuery.CompilePinyinLoose(tokens, request.Metadata);
            if (expression is not null)
            {
                result.Passes.PinyinLoose = 1;
                Merge(expression, SearchPassNames.PinyinLoose);
            }
        }
        if (result.Items.Count < request.MinExact && (_meta.HasJapanese || _meta.HasKorean))
        {
            var expression = SearchQuery.CompileReading(tokens, request.Metadata);
            if (expression is not null)
            {
                result.Passes.Reading = 1;
                // T1-4：读音趟内按「整词前缀 > 整词包含」重排（bm25 只保证连续子串命中）。
                Merge(expression, SearchPassNames.Reading, SearchQuery.ReadingSequences(tokens));
            }
        }
        if (result.Items.Count < request.MinExact)
        {
            // 语言画像（v7）：按候选脚本裁剪，纯英文库不再为汉字段付 MATCH 成本，
            // 但仍保留「汉字查询 → 英文释义候选」方向（反之亦然）。
            var candidates = FilterCrossLingual(tokens.CrossLingual);
            if (candidates.Count > 0)
            {
                tokens.CrossLingual.Clear();
                tokens.CrossLingual.AddRange(candidates);
                var expression = SearchQuery.CompileCrossLingual(tokens, request.Metadata);
                if (expression is not null)
                {
                    result.Passes.CrossLingual = 1;
                    Merge(expression, SearchPassNames.CrossLingual);
                }
            }
        }

        // 模糊趟：仅在调用方显式启用且前几趟仍不足时执行。
        if (!request.Fuzzy || result.Items.Count >= request.MinExact) return result;

        if (SearchQuery.HasFuzzyEligible(tokens))
        {
            result.Passes.Fuzzy = 1;
            // T1-8：先用索引词表过滤变体（只留真实存在且 Damerau ≤1 的 term），
            // 词表加载失败时返回空集 → CompileFuzzy 自动退回旧的变体枚举行为。
            Merge(SearchQuery.CompileFuzzy(tokens, request.Metadata, _store.LoadFuzzyVocabulary()),
                SearchPassNames.Fuzzy);
        }
        if (result.Items.Count >= request.MinExact) return result;

        // 中文容错趟：删除 / 相邻换位变体逐个编译后 OR 进同一趟。
        var variants = SearchQuery.CjkVariants(request.Query);
        if (variants.Count == 0) return result;
        result.Passes.CjkFuzzy = 1;

        var parts = new List<string>(variants.Count);
        foreach (var variant in variants)
        {
            var expression = SearchQuery.CompileMatch(
                Analyzer.AnalyzeQuery(variant), metadata: false);
            if (expression is not null) parts.Add(expression);
        }
        if (parts.Count > 0)
        {
            var joined = parts.Count == 1 ? parts[0] : "(" + string.Join(" OR ", parts) + ")";
            Merge(request.Metadata
                ? $"{{{SearchQuery.MetadataColumns}}} : ({joined})"
                : joined, SearchPassNames.CjkFuzzy);
        }
        return result;
    }

    /// <summary>
    /// 按曲库语言画像裁剪跨语言候选（v7）：汉字候选只可能在库内含汉字时命中，
    /// 拉丁释义候选只可能在库内含拉丁字母时命中。
    ///
    /// 只裁「不可能命中」的方向，不裁整趟——纯英文库里输入「爱」仍能经英文释义候选命中英文标题。
    /// </summary>
    /// <summary>
    /// 探测每个查询词在 title / artist 列的命中数（精度审计 §23）。
    ///
    /// 用于判断「哪个词是歌名」：只在 title 命中、或 title 远多于 artist 的词是歌名，
    /// 应当最后才丢。这样 <c>晴天 周杰伦</c>（反向写法）也能保留歌名。
    ///
    /// **只在丢词趟需要时调用**（主趟 0 命中的多词查询，罕见路径），
    /// 且每个词只做 2 次 COUNT 查询。返回的两个数组与 <c>words</c> 的顺序一一对应。
    /// </summary>
    private (List<int> TitleCounts, List<int> ArtistCounts) ProbeFieldAffinity(
        string query, int wordCount)
    {
        var title = new List<int>(wordCount);
        var artist = new List<int>(wordCount);

        var words = query.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        for (var i = 0; i < wordCount; i++)
        {
            if (i >= words.Length)
            {
                title.Add(0);
                artist.Add(0);
                continue;
            }

            // 用该词自己的词元编译（与检索同源），再限定到单列。
            var tokens = Analyzer.AnalyzeQuery(words[i]);
            var lexical = SearchQuery.CompileMatch(tokens, metadata: false);
            if (lexical is null)
            {
                title.Add(0);
                artist.Add(0);
                continue;
            }

            // 直接复用编译结果，只把列过滤换成单列。CompileMatch 在没有 metadata
            // 时不套列过滤，所以这里包一层。
            title.Add(_store.CountMatches($"{{title_tok}} : ({lexical})"));
            artist.Add(_store.CountMatches($"{{artist_tok}} : ({lexical})"));
        }
        return (title, artist);
    }

    private List<string> FilterCrossLingual(List<string> candidates)
    {
        var output = new List<string>(candidates.Count);
        foreach (var candidate in candidates)
        {
            var han = candidate.Any(ScriptRanges.IsCjk);
            if (han ? !_meta.HasHan : !_meta.HasLatin) continue;
            output.Add(candidate);
        }
        return output;
    }

    private List<SearchHit> ExecuteMatch(
        string expression, SearchRequest request, string pass,
        IReadOnlyList<string[]>? readingSequences = null)
    {
        var rows = _store.Search(expression, request.Limit, request.Offset, request.CandidateCap);
        if (rows.Count == 0) return new List<SearchHit>();

        var trackIds = _store.ResolveTrackIds(rows.Select(r => r.DocId).ToList());
        if (readingSequences is not { Count: > 0 })
        {
            var plain = new List<SearchHit>(rows.Count);
            foreach (var (docId, score) in rows)
            {
                if (trackIds.TryGetValue(docId, out var trackId))
                    plain.Add(new SearchHit(trackId, score, pass));
            }
            return plain;
        }

        // 读音趟：按档位（前缀 > 包含 > 其它）重排，档内仍按 bm25。
        var readings = _store.ResolveReadingTexts(rows.Select(r => r.DocId).ToList());
        var ranked = new List<(SearchHit Hit, int Tier)>(rows.Count);
        foreach (var (docId, score) in rows)
        {
            if (!trackIds.TryGetValue(docId, out var trackId)) continue;
            var tier = readings.TryGetValue(docId, out var text)
                ? ReadingRanker.Score(text, readingSequences)
                : ReadingRanker.OtherTier;
            ranked.Add((new SearchHit(trackId, score, pass), tier));
        }
        return ranked
            .OrderByDescending(entry => entry.Tier)
            .ThenBy(entry => entry.Hit.Score)
            .Select(entry => entry.Hit)
            .ToList();
    }

    /// <summary>LRU 条目：键 + 已合并去重的 top-k 结果（只读共享）。</summary>
    private sealed record CachedQuery(string Key, SearchResult Result);

    public void Dispose() => _store.Dispose();
}
