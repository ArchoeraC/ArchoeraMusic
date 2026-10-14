// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

namespace Archoera.Indexer;

/// <summary>
/// 写入 FTS 倒排（<c>search_fts</c>）的一篇文档分析后词元。
/// 字段与 <c>FtsStore</c> 的 <c>search_fts</c> 列一一对应（顺序一致）；
/// 元数据（<c>track_id</c> / mtime / 世代）随 <see cref="IIndexStore.Put"/> 写入 <c>search_docs</c>。
/// 供上层（<see cref="IndexerEngine"/>）构造，存储后端不感知源语义。
/// </summary>
public sealed class DocTokens
{
    /// <summary>曲库稳定标识（<c>tracks.id</c>，TEXT）。</summary>
    public string TrackId { get; init; } = "";

    public string TitleTok { get; init; } = "";
    public string ArtistTok { get; init; } = "";
    public string AlbumTok { get; init; } = "";
    public string LyricsTok { get; init; } = "";
    public string LyricsTrTok { get; init; } = "";
    public string LyricsRomTok { get; init; } = "";
    /// <summary>
    /// 拼音列（**元数据段**，v4 起与歌词段分列）：title/artist/album/filename 的全拼音节。
    /// 拆列动机见 <see cref="PinyinLyricsTok"/>——这四列才是「元数据」查询该扫的范围。
    /// </summary>
    public string PinyinMetaTok { get; init; } = "";

    /// <summary>
    /// 拼音列（**歌词段**）：合并后的歌词（原文层）全拼音节。
    ///
    /// 为什么与元数据分列（P5 实测）：v3 把两者混在一列，于是 `scope=metadata`（列过滤白名单）
    /// 根本收不住拼音查询——词元本身就在同一列里。分列后元数据查询只扫 `<see cref="PinyinMetaTok"/>`，
    /// 「只搜标题 / 歌手」才真正成立（也顺带缩小该路径的命中集）。
    /// </summary>
    public string PinyinLyricsTok { get; init; } = "";

    /// <summary>首字母列（**元数据段**）：title/artist/album/filename 的拼音首字母串。</summary>
    public string InitialsMetaTok { get; init; } = "";

    /// <summary>首字母列（**歌词段**）：歌词原文层的拼音首字母串。</summary>
    public string InitialsLyricsTok { get; init; } = "";

    /// <summary>
    /// 日文读音列（**元数据段**，v5）：title/artist/album/filename 的假名 / 汉字读音罗马字 bigram。
    ///
    /// **只索引元数据**：歌词的罗马字检索是伪需求（用户按假名 / 汉字搜歌词），而整段歌词的读音
    /// bigram 会把索引推高约 2×（真实 165 首日文库实测 2.42MB → 4.53MB），故不索引歌词读音。
    /// </summary>
    public string ReadingMetaTok { get; init; } = "";
    public string FilenameTok { get; init; } = "";

    /// <summary>索引时的 <c>tracks.file_mtime</c>（脏集判定的版本锚）。</summary>
    public long IndexedMtime { get; init; }

    /// <summary>索引时的 <c>.lrc</c> 侧车 mtime（无侧车 / 子开关关闭时为 0）。</summary>
    public long IndexedLrcMtime { get; init; }

    /// <summary>索引时的 <c>.lrc</c> 侧车字节大小（无侧车 / 子开关关闭时为 0）。</summary>
    public long IndexedLrcSize { get; init; }

    /// <summary>索引时观测到的扫描世代水位线。</summary>
    public long IndexedGeneration { get; init; }
}

/// <summary>增量引擎所需的单文档既有状态快照（只读视图）。</summary>
public readonly record struct DocState(
    long DocId, long Mtime, long LrcMtime, long LrcSize, long Generation);

/// <summary>
/// <c>search_meta</c> 的强类型视图（版本 / 选项 / 世代水位线）。
/// 值来自存储后端，缺失键取默认值。
/// </summary>
public sealed class StoreMeta
{
    public int SchemaVersion { get; set; }
    public int AnalyzerVersion { get; set; }
    public bool IndexLrc { get; set; }
    public bool Pinyin { get; set; }
    public long AppliedGeneration { get; set; }
    public long BuiltAt { get; set; }
    public long FullBuildAt { get; set; }
}

/// <summary>
/// 搜索索引存储接口（设计文档 <c>docs/local-search-index-plan.md</c> §5.1 冻结）。
///
/// 上层（<see cref="IndexerEngine"/>）只依赖本接口；实现可替换（FTS5 / 自研段引擎 §5.5）。
/// 语义：
/// <list type="bullet">
///   <item><see cref="Open"/>：<c>build=true</c> 世代化全量（写 <c>&lt;path&gt;.tmp</c> 后原子替换）；
///         <c>build=false</c> 打开既有库增量维护。</item>
///   <item><see cref="Put"/> / <see cref="Delete"/>：单文档更新（实现内部批量事务）。</item>
///   <item><see cref="Commit"/>：落盘（提交事务 + checkpoint）。</item>
///   <item><see cref="Search"/>：<c>MATCH</c> + 相关性排序。</item>
///   <item><see cref="Optimize"/>：离线 merge（非热路径）。</item>
/// </list>
/// </summary>
public interface IIndexStore : IDisposable
{
    /// <summary>打开存储：<paramref name="build"/>=true 为世代化全量构建，否则增量打开既有库。</summary>
    void Open(string path, bool build);

    /// <summary>当前实现承载的 schema 版本；与既有库不一致时上层应触发全量重建。</summary>
    int SchemaVersion { get; }

    /// <summary>写入/覆盖一篇文档（docId 由上层稳定分配）。</summary>
    void Put(long docId, DocTokens fields);

    /// <summary>按 docId 删除一篇文档（含 FTS 倒排同步清理）。</summary>
    void Delete(long docId);

    /// <summary>提交挂起事务并 checkpoint 落盘。</summary>
    void Commit();

    /// <summary>按 <paramref name="matchExpr"/>（FTS5 MATCH 表达式）检索，返回 (docId, score)，
    /// score 越小越相关（bm25 语义）。</summary>
    /// <summary>
    /// 执行 `MATCH` 查询并返回 BM25 升序命中（<c>limit</c> ≤ 0 = 不限）。
    ///
    /// <paramref name="candidateCap"/>：**候选集上限**（0 = 不限）——`ORDER BY bm25` 必须给全部命中
    /// 打分，宽命中查询（常见拼音 / 首字母 / 高频英文词）成本会随库线性增长；先按 rowid 顺序取
    /// 有界候选（无排序、可提前退出）再排序，把单条延迟钉在上界内。生产默认
    /// <c>FtsStore.DefaultCandidateCap</c>（与 Dart `SearchIndex.defaultCandidateCap` 同值）。
    /// </summary>
    List<(long DocId, double Score)> Search(string matchExpr, int limit, int offset, int candidateCap);

    /// <summary>离线优化（<c>PRAGMA optimize</c> + FTS <c>optimize</c>）。</summary>
    void Optimize();
}

/// <summary>
/// 增量引擎额外需要的管理视图（既有状态 / 元数据 / 批次 / 世代化收尾）。
/// 与冻结接口分离，避免把 FTS5 专属能力泄漏进 <see cref="IIndexStore"/>。
/// </summary>
public interface IIndexStoreAdmin : IIndexStore
{
    /// <summary>内部批量事务的文档条数上限（0 或负数 = 不主动分批）。</summary>
    int BatchSize { get; set; }

    /// <summary>下一个可用的 docId（既有最大 doc_id + 1）。</summary>
    long NextDocId { get; }

    /// <summary>读取 <c>search_meta</c>（缺失键取默认值；库不存在/无表返回默认实例）。</summary>
    StoreMeta ReadMeta();

    /// <summary>读取全部既有文档状态，键为 <c>track_id</c>。</summary>
    Dictionary<string, DocState> LoadState();

    /// <summary>写入/更新 <c>search_meta</c> 的版本、选项与世代键。</summary>
    void WriteMeta(StoreMeta meta);

    /// <summary>世代化收尾：<c>build</c> 模式 fsync 后原子替换为正式库；增量模式为 no-op。</summary>
    void Seal();
}
