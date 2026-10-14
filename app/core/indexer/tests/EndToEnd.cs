// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

using System.Text;
using Archoera.Lyrics;
using Microsoft.Data.Sqlite;

namespace Archoera.Indexer.Tests;

/// <summary>
/// 端到端 round-trip：用 Microsoft.Data.Sqlite 建一个 <c>library.db</c> fixture，
/// 跑 <see cref="IndexerEngine"/> 全量 / 增量，直接对 <c>search.db</c>（FTS5）断言：
/// <list type="bullet">
///   <item>全量：世代化产出（无 <c>.tmp</c>）、<c>search_meta</c>、行数、MATCH 命中
///         （中文子串 / 繁体经分析、拼音 / 首字母、拉丁前缀）；</item>
///   <item>增量：改 mtime 只重算该曲；删除曲目从 <c>search_docs</c>/<c>search_fts</c> 移除；</item>
///   <item><c>.lrc</c> 子开关开 / 关各一次（并入 / 清理）；</item>
///   <item><c>_scanner_meta</c> 缺失时世代按 0、不报错（前向兼容）。</item>
/// </list>
/// </summary>
internal static class EndToEnd
{
    public static void Run()
    {
        var root = Path.Combine(Path.GetTempPath(), "archoera-indexer-e2e-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            FullAndIncremental(root);
            MissingScannerMeta(root);
            LrcReading(root);
            SidecarDirectoryCache(root);
            MultilingualLayers(root);
        }
        finally
        {
            TryDelete(root);
        }
    }

    /* ------------------------------------------------------------------ */
    /* 主流程：全量 → 增量 → 删除 → .lrc 开关                              */
    /* ------------------------------------------------------------------ */

    private static void FullAndIncremental(string root)
    {
        var db = Path.Combine(root, "library.db");
        var index = Path.Combine(root, "search.db");
        var dirA = Path.Combine(root, "a");
        var dirB = Path.Combine(root, "b");
        Directory.CreateDirectory(dirA);
        Directory.CreateDirectory(dirB);

        var song1 = Path.Combine(dirA, "song1.mp3");
        var song2 = Path.Combine(dirA, "song2.mp3");
        var song3 = Path.Combine(dirB, "song3.mp3");
        var song4 = Path.Combine(dirB, "delete-me.mp3");

        CreateLibrary(db, generation: 5);
        using (var conn = Open(db))
        {
            // t1：简体内嵌歌词 + LRC 时间轴标签
            InsertTrack(conn, "t1", song1, "晴天", """[{"name":"周杰伦"}]""", """{"name":"叶惠美"}""",
                "[00:12.34]我爱你中国\n[00:15.00]我爱你", 1000);
            // t2：繁体歌词（索引期归一为简体）
            InsertTrack(conn, "t2", song2, "爱", """[{"name":"邓丽君"}]""", """{"name":"经典"}""", "我愛你", 2000);
            InsertTrack(conn, "t3", song3, "Hello World", """[{"name":"ADELE"}]""", """{"name":"25"}""", null, 3000);
            InsertTrack(conn, "t4", song4, "Delete Me", "[]", null, "将被删除", 4000);
        }

        // 侧车歌词（t3）：由**扫描器写入 library.db**（索引器只读 DB）。
        // 含时间轴 / 元数据标签，索引器经共享 LrcReader.FromRawTexts 只取文本行。
        using (var conn = Open(db))
        {
            SetSidecar(conn, "t3",
                "[by:test]\n[00:01.00]蓝蓝的天\n[00:02.50]白云飘\n");
        }

        // ---- 全量构建 ----
        var full = RunEngine(db, index, full: true, lrc: false);
        Program.Check("全量: total==4", full.Total == 4, full.Total.ToString());
        Program.Check("全量: indexed==4", full.Indexed == 4, full.Indexed.ToString());
        Program.Check("全量: full==true", full.Full);
        Program.Check("全量: generation==5", full.Generation == 5, full.Generation.ToString());
        Program.Check("全量: search.db 存在", File.Exists(index));
        Program.Check("世代化: 无 search.db.tmp", !File.Exists(index + ".tmp"));
        Program.Check("世代化: 无 search.db.tmp-wal", !File.Exists(index + ".tmp-wal"));

        Program.Check("meta.analyzer_version==6", Meta(index, "analyzer_version") == "6", Meta(index, "analyzer_version"));
        Program.Check("meta.schema_version==5", Meta(index, "schema_version") == "5", Meta(index, "schema_version"));
        Program.Check("meta.index_lrc==0", Meta(index, "index_lrc") == "0", Meta(index, "index_lrc"));
        Program.Check("meta.pinyin==1", Meta(index, "pinyin") == "1", Meta(index, "pinyin"));
        Program.Check("meta.applied_generation==5", Meta(index, "applied_generation") == "5", Meta(index, "applied_generation"));

        Program.Check("search_docs COUNT==4", Scalar(index, "SELECT COUNT(*) FROM search_docs") == 4,
            Scalar(index, "SELECT COUNT(*) FROM search_docs").ToString());
        Program.Check("search_fts 有 4 行", Scalar(index, "SELECT COUNT(*) FROM search_fts") == 4,
            Scalar(index, "SELECT COUNT(*) FROM search_fts").ToString());

        // ---- contentless v2 语义 ----
        Program.Check("contentless: search_docs 仅 7 列元数据",
            Scalar(index, "SELECT COUNT(*) FROM pragma_table_info('search_docs')") == 7,
            Scalar(index, "SELECT COUNT(*) FROM pragma_table_info('search_docs')").ToString());
        Program.Check("contentless: search_docs 无 token 文本列（title_tok/pinyin_meta_tok）",
            Scalar(index, "SELECT COUNT(*) FROM pragma_table_info('search_docs') WHERE name IN ('title_tok','pinyin_meta_tok')") == 0);
        Program.Check("contentless: 列过滤 {title_tok} : (\"晴天\") 命中 t1",
            MatchContainsTrack(index, "{title_tok} : (\"晴天\")", "t1"));
        Program.Check("contentless: 短语 \"wo ai ni\" 命中 t1",
            MatchContainsTrack(index, "\"wo ai ni\"", "t1"));
        Program.Check("contentless: bm25 权重查询可执行",
            Scalar(index, "SELECT COUNT(*) FROM (SELECT bm25(search_fts,4.0,3.0,2.0,1.5,1.0,0.5,2.0,1.0) "
                + "FROM search_fts WHERE search_fts MATCH 'hello')") == 1);
        Program.Check("contentless: FTS optimize 后可查（无内容残影）",
            Scalar(index, "SELECT COUNT(*) FROM search_fts WHERE search_fts MATCH 'hello'") == 1);

        // FTS MATCH：中文子串（原始已归一，无需分析器）
        Program.Check("MATCH '爱你' 命中 2（t1/t2）", MatchCount(index, "爱你") == 2,
            MatchCount(index, "爱你").ToString());
        // 繁体查询：原始 '愛' 命中 0（unicode61 不归一），经分析器归一后命中 t2（及 t1）
        Program.Check("MATCH 原始 '愛' ==0（需分析器）", MatchCount(index, "愛") == 0,
            MatchCount(index, "愛").ToString());
        Program.Check("MATCH 分析('愛') 命中 t2", MatchCount(index, Analyzed("愛")) >= 1);
        Program.Check("分析('愛') 命中 t2 的 doc", MatchContainsTrack(index, Analyzed("愛"), "t2"));
        // 拼音（全拼相邻短语）与首字母（v4：元数据/歌词分列）
        Program.Check("MATCH pinyin 短语 'wo ai ni' 命中 t1", MatchContainsTrack(index, "\"wo ai ni\"", "t1"));
        Program.Check("MATCH 首字母 'wanzg' 命中 t1", MatchContainsTrack(index, "wanzg", "t1"));
        // v4 分列：**元数据**首字母（晴天 → qt）在 initials_meta_tok；
        // **歌词**首字母（我爱你中国 → wanzg）在 initials_lyrics_tok。
        Program.Check("首字母列过滤 {initials_meta_tok} : 'qt'（标题首字母）命中 t1",
            MatchContainsTrack(index, "{initials_meta_tok} : \"qt\"", "t1"));
        Program.Check("首字母列过滤 {initials_lyrics_tok} : 'wanzg'（歌词首字母）命中 t1",
            MatchContainsTrack(index, "{initials_lyrics_tok} : \"wanzg\"", "t1"));
        Program.Check("歌词首字母不在 initials_meta_tok（v4 分列）",
            !MatchContainsTrack(index, "{initials_meta_tok} : \"wanzg\"", "t1"));
        // 首字母串（wan / wanzg…）不在拼音两列 → 拼音列过滤下不命中
        Program.Check("拼音两列 : 'wanzg' 不命中（首字母已拆出）",
            !MatchContainsTrack(index, "{pinyin_meta_tok pinyin_lyrics_tok} : \"wanzg\"", "t1"));
        // v4 分列：歌词拼音不在元数据拼音列 → 元数据范围的列过滤收得住（旧版混列时收不住）
        Program.Check("歌词拼音不在 pinyin_meta_tok（v4 分列）",
            MatchContainsTrack(index, "{pinyin_lyrics_tok} : \"wo ai ni\"", "t1")
            && !MatchContainsTrack(index, "{pinyin_meta_tok} : \"wo ai ni\"", "t1"));
        // 连写全拼（查询侧 woaini → wo ai ni，镜像 Dart compileMatch 的相邻短语）
        var woaini = Analyzer.AnalyzeQuery("woaini").Pinyin;
        Program.Check("E2E 连写全拼分析 == wo ai ni", string.Join(' ', woaini) == "wo ai ni",
            string.Join(' ', woaini));
        Program.Check("MATCH 连写全拼短语 \"wo ai ni\" 命中 t1",
            MatchContainsTrack(index, "\"wo ai ni\"", "t1"));
        // 拉丁前缀 / 整词
        Program.Check("MATCH 'hello' 命中 t3", MatchContainsTrack(index, "hello", "t3"));
        Program.Check("MATCH 前缀 'hel*' 命中 t3", MatchContainsTrack(index, "hel*", "t3"));

        // ---- 增量：改 t1 的 file_mtime ----
        Exec(db, "UPDATE tracks SET file_mtime = 9999 WHERE id = 't1'");
        var (inc, incQueries) = RunEngineDetailed(db, index, full: false, lrc: false);
        Program.Check("增量(改 mtime): full==false", !inc.Full);
        Program.Check("增量(改 mtime): indexed==1", inc.Indexed == 1, inc.Indexed.ToString());
        Program.Check("增量(改 mtime): deleted==0", inc.Deleted == 0, inc.Deleted.ToString());
        Program.Check("增量(改 mtime): skipped==3", inc.Skipped == 3, inc.Skipped.ToString());
        Program.Check("增量(改 mtime): 仅 1 次内容查询（未全库读歌词）", incQueries == 1, incQueries.ToString());
        Program.Check("增量: t1 indexed_mtime 已更新", DocScalar(index, "t1", "indexed_mtime") == 9999,
            DocScalar(index, "t1", "indexed_mtime").ToString());

        // ---- 增量：删除 t4（无脏曲 → 零内容读取）----
        Exec(db, "DELETE FROM tracks WHERE id = 't4'");
        var (del, delQueries) = RunEngineDetailed(db, index, full: false, lrc: false);
        Program.Check("删除: deleted==1", del.Deleted == 1, del.Deleted.ToString());
        Program.Check("删除: 仅删除、无内容查询", delQueries == 0, delQueries.ToString());
        Program.Check("删除: search_docs COUNT==3", Scalar(index, "SELECT COUNT(*) FROM search_docs") == 3,
            Scalar(index, "SELECT COUNT(*) FROM search_docs").ToString());
        Program.Check("删除: t4 不在 search_docs", Scalar(index, "SELECT COUNT(*) FROM search_docs WHERE track_id='t4'") == 0,
            Scalar(index, "SELECT COUNT(*) FROM search_docs WHERE track_id='t4'").ToString());
        Program.Check("删除: 歌词 '删除' 不再命中", MatchCount(index, Analyzed("删除")) == 0,
            MatchCount(index, Analyzed("删除")).ToString());
        Program.Check("删除: search_fts 无 t4 残留",
            Scalar(index, "SELECT COUNT(*) FROM search_fts WHERE rowid NOT IN (SELECT doc_id FROM search_docs)") == 0,
            Scalar(index, "SELECT COUNT(*) FROM search_fts WHERE rowid NOT IN (SELECT doc_id FROM search_docs)").ToString());

        // ---- .lrc 子开关：开（并入）----
        var lrcOn = RunEngine(db, index, full: false, lrc: true);
        Program.Check(".lrc 开: t3 被重算（indexed==1）", lrcOn.Indexed == 1, lrcOn.Indexed.ToString());
        Program.Check(".lrc 开: meta.index_lrc==1", Meta(index, "index_lrc") == "1", Meta(index, "index_lrc"));
        Program.Check(".lrc 开: indexed_lrc_size>0", DocScalar(index, "t3", "indexed_lrc_size") > 0,
            DocScalar(index, "t3", "indexed_lrc_size").ToString());
        Program.Check(".lrc 开: MATCH 侧车文本 '蓝蓝的天' 命中 t3",
            MatchContainsTrack(index, Analyzed("蓝蓝的天"), "t3"));

        // ---- .lrc 子开关：关（清理）----
        var lrcOff = RunEngine(db, index, full: false, lrc: false);
        Program.Check(".lrc 关: t3 被重算（清理）", lrcOff.Indexed == 1, lrcOff.Indexed.ToString());
        Program.Check(".lrc 关: meta.index_lrc==0", Meta(index, "index_lrc") == "0", Meta(index, "index_lrc"));
        Program.Check(".lrc 关: indexed_lrc_size==0", DocScalar(index, "t3", "indexed_lrc_size") == 0,
            DocScalar(index, "t3", "indexed_lrc_size").ToString());
        Program.Check(".lrc 关: 侧车文本不再命中", MatchCount(index, Analyzed("蓝蓝的天")) == 0,
            MatchCount(index, Analyzed("蓝蓝的天")).ToString());

        // ---- 无变更：全 skipped，且零内容查询（未读歌词）----
        var (idle, idleQueries) = RunEngineDetailed(db, index, full: false, lrc: false);
        Program.Check("无变更: indexed==0 && deleted==0", idle.Indexed == 0 && idle.Deleted == 0,
            $"indexed={idle.Indexed} deleted={idle.Deleted}");
        Program.Check("无变更: 零内容查询（未全库读歌词）", idleQueries == 0, idleQueries.ToString());
    }

    /* ------------------------------------------------------------------ */
    /* _scanner_meta 缺失：前向兼容                                        */
    /* ------------------------------------------------------------------ */

    private static void MissingScannerMeta(string root)
    {
        var db = Path.Combine(root, "lib-nometa.db");
        var index = Path.Combine(root, "idx-nometa.db");
        CreateLibrary(db, generation: null);
        using (var conn = Open(db))
        {
            InsertTrack(conn, "m1", Path.Combine(root, "m1.mp3"), "歌", "[]", null, "测试", 10);
        }

        var result = RunEngine(db, index, full: true, lrc: false);
        Program.Check("无 _scanner_meta: 不报错且 generation==0", result.Generation == 0, result.Generation.ToString());
        Program.Check("无 _scanner_meta: applied_generation==0", Meta(index, "applied_generation") == "0",
            Meta(index, "applied_generation"));
        Program.Check("无 _scanner_meta: 仍建索引", Scalar(index, "SELECT COUNT(*) FROM search_docs") == 1,
            Scalar(index, "SELECT COUNT(*) FROM search_docs").ToString());
    }

    /* ------------------------------------------------------------------ */
    /* .lrc 目录清单缓存（O(曲目 × 目录条目) → O(曲目 + 目录条目)）          */
    /* ------------------------------------------------------------------ */

    /// <summary>
    /// 侧车目录清单缓存的语义：命中 / 大小写不敏感 / 确定性取文件名序最小者 /
    /// 三类侧车（主 · trans · romaji）/ 目录内容变动后立即可见 / 显式清空缓存。
    /// </summary>
    private static void SidecarDirectoryCache(string root)
    {
        var dir = Path.Combine(root, "sidecar-cache");
        Directory.CreateDirectory(dir);
        var audio = Path.Combine(dir, "song.mp3");

        LrcReader.ResetDirectoryCache();
        Program.Check("lrc 缓存: 空目录无侧车", LrcReader.FindSidecar(audio) is null,
            LrcReader.FindSidecar(audio) ?? "(null)");

        // 主侧车（小写）+ 显式分层侧车：一次目录枚举后应三类都能解析
        var main = Path.Combine(dir, "song.lrc");
        var trans = Path.Combine(dir, "song.TRANS.LRC"); // 大小写不敏感
        var romaji = Path.Combine(dir, "song.romaji.lrc");
        File.WriteAllText(main, "[00:01.00]原文\n", new UTF8Encoding(false));
        File.WriteAllText(trans, "译文\n", new UTF8Encoding(false));
        File.WriteAllText(romaji, "yi wen\n", new UTF8Encoding(false));
        LrcReader.ResetDirectoryCache();

        var layers = LrcReader.Read(audio);
        Program.Check("lrc 缓存: 主侧车命中", layers.Exists && layers.Text == "原文", layers.Text);
        Program.Check("lrc 缓存: 译文层命中", layers.Translation == "译文", layers.Translation);
        Program.Check("lrc 缓存: 音译层命中", layers.Romaji == "yi wen", layers.Romaji);

        // 同名多份（仅大小写 / 名字序不同）→ 取文件名序（Ordinal）最小者，确定性
        var dupUpper = Path.Combine(dir, "SONG.lrc");
        var dupLower = Path.Combine(dir, "Song.lrc");
        File.WriteAllText(dupUpper, "[00:01.00]大写\n", new UTF8Encoding(false));
        File.WriteAllText(dupLower, "[00:01.00]小写\n", new UTF8Encoding(false));
        LrcReader.ResetDirectoryCache();
        // Ordinal 序：'S'(0x53) < 's'(0x73)，且 'O'(0x4F) < 'o'(0x6F) → SONG.lrc 胜出
        Program.Check("lrc 缓存: 同名取 Ordinal 最小者", LrcReader.FindSidecar(audio) == dupUpper,
            Path.GetFileName(LrcReader.FindSidecar(audio) ?? "(null)"));

        // 新增侧车且**目录 mtime 前进**（显式推进，避免依赖 FS 时间粒度）→ 缓存失效、立即可见
        var added = Path.Combine(dir, "added.mp3");
        Program.Check("lrc 缓存: 新曲目初始无侧车", LrcReader.FindSidecar(added) is null);
        var addedLrc = Path.Combine(dir, "added.lrc");
        File.WriteAllText(addedLrc, "[00:01.00]新增\n", new UTF8Encoding(false));
        Directory.SetLastWriteTimeUtc(dir, Directory.GetLastWriteTimeUtc(dir).AddSeconds(2));
        Program.Check("lrc 缓存: 目录 mtime 变化后可见", LrcReader.FindSidecar(added) == addedLrc,
            Path.GetFileName(LrcReader.FindSidecar(added) ?? "(null)"));

        // 显式清空缓存（每次构建开始前调用）：清后仍能正确解析
        Program.Check("lrc 缓存: Reset 返回清理条目数", LrcReader.ResetDirectoryCache() >= 1);
        Program.Check("lrc 缓存: Reset 后主侧车仍命中", LrcReader.FindSidecar(audio) == dupUpper,
            Path.GetFileName(LrcReader.FindSidecar(audio) ?? "(null)"));

        // ---- BeginScan（扫描器入口）：本轮**信任**目录 mtime，但侧车**文件**仍逐个 stat ----
        var scanDir = Path.Combine(root, "sidecar-scan-scope");
        Directory.CreateDirectory(scanDir);
        var scanAudio = Path.Combine(scanDir, "s.mp3");
        var scanLrc = Path.Combine(scanDir, "s.lrc");
        File.WriteAllText(scanLrc, "[00:01.00]第一版\n", new UTF8Encoding(false));
        LrcReader.BeginScan();
        var first = LrcReader.Find(scanAudio);
        Program.Check("lrc 扫描域: 首轮可见", first.Exists && first.Main == scanLrc,
            Path.GetFileName(first.Main ?? "(null)"));

        // 侧车**内容**改写（同名）：仍必须看到新 mtime/size —— 这是「信任目录 mtime」安全的前提
        var beforeMtime = first.Mtime;
        File.WriteAllText(scanLrc, "[00:01.00]第二版内容更长一点\n", new UTF8Encoding(false));
        File.SetLastWriteTimeUtc(scanLrc, DateTime.UtcNow.AddSeconds(5));
        var rewritten = LrcReader.Find(scanAudio);
        Program.Check("lrc 扫描域: 同名改写仍逐个 stat（mtime 前进）",
            rewritten.Mtime > beforeMtime && rewritten.Size != first.Size,
            $"{rewritten.Mtime}>{beforeMtime} size={rewritten.Size}/{first.Size}");

        // 本轮**新增**侧车：信任目录 mtime → 本轮不发现（与 scanner 对媒体文件的语义一致：
        // 扫描中途落盘的由下一轮发现）；下一轮 BeginScan 即可见
        var lateAudio = Path.Combine(scanDir, "late.mp3");
        Program.Check("lrc 扫描域: 新曲目本轮无侧车", !LrcReader.Find(lateAudio).Exists);
        var lateLrc = Path.Combine(scanDir, "late.lrc");
        File.WriteAllText(lateLrc, "[00:01.00]迟到\n", new UTF8Encoding(false));
        Program.Check("lrc 扫描域: 本轮新增侧车不在本轮生效（信任目录语义）",
            !LrcReader.Find(lateAudio).Exists, "(应在下一轮可见)");
        LrcReader.BeginScan();
        Program.Check("lrc 扫描域: 下一轮可见新侧车", LrcReader.Find(lateAudio).Main == lateLrc,
            Path.GetFileName(LrcReader.Find(lateAudio).Main ?? "(null)"));
    }

    /* ------------------------------------------------------------------ */
    /* .lrc 编码 / 标签剥离                                                */
    /* ------------------------------------------------------------------ */

    private static void LrcReading(string root)
    {
        var dir = Path.Combine(root, "lrc");
        Directory.CreateDirectory(dir);
        var audio = Path.Combine(dir, "enc.mp3");
        var sidecar = Path.Combine(dir, "enc.LRC"); // 大小写不敏感
        File.WriteAllText(sidecar, "[00:01.00]第一行\n[ar:某人]\n\n[00:02.00]第二行\n", new UTF8Encoding(true));
        var read = LrcReader.Read(audio);
        Program.Check("lrc: 存在", read.Exists);
        Program.Check("lrc: 大小写不敏感命中", LrcReader.FindSidecar(audio) is not null);
        Program.Check("lrc: 标签已剥离", read.Text == "第一行\n第二行", read.Text.Replace("\n", "\\n"));
        Program.Check("lrc: 行数==2", read.LineCount == 2, read.LineCount.ToString());
        Program.Check("lrc: size>0", read.Size > 0, read.Size.ToString());

        // UTF-16 LE（BOM）
        var audio16 = Path.Combine(dir, "u16.mp3");
        var sidecar16 = Path.Combine(dir, "u16.lrc");
        File.WriteAllText(sidecar16, "[00:01.00]你好世界\n", new UnicodeEncoding(bigEndian: false, byteOrderMark: true));
        var read16 = LrcReader.Read(audio16);
        Program.Check("lrc: UTF-16LE 解码", read16.Exists && read16.Text == "你好世界", read16.Text);

        // GBK / GB18030 双字节（无 BOM）：严格 UTF-8 失败 → 表解码。
        var audioGb = Path.Combine(dir, "gbk.mp3");
        var sidecarGb = Path.Combine(dir, "gbk.lrc");
        byte[] gbk =
        {
            0x5B, 0x30, 0x30, 0x3A, 0x30, 0x31, 0x2E, 0x30, 0x30, 0x5D, // [00:01.00]
            0xC4, 0xE3, 0xBA, 0xC3, 0xCA, 0xC0, 0xBD, 0xE7,             // 你好世界（GBK）
            0x0A,
        };
        File.WriteAllBytes(sidecarGb, gbk);
        var readGb = LrcReader.Read(audioGb);
        Program.Check("lrc: GBK 解码", readGb.Exists && readGb.Text == "你好世界", readGb.Text);

        // GBK 混排 ASCII 标签与中文，多行；标签剥离后应得中文文本。
        var audioGb2 = Path.Combine(dir, "gbk2.mp3");
        var sidecarGb2 = Path.Combine(dir, "gbk2.lrc");
        var gbk2 = new List<byte>();
        gbk2.AddRange(Encoding.ASCII.GetBytes("[by:test]\n[00:02.00]"));
        gbk2.AddRange(new byte[] { 0xC0, 0xB6, 0xCC, 0xEC, 0xB0, 0xD7, 0xD4, 0xC6 }); // 蓝天白云（GBK）
        gbk2.Add(0x0A);
        File.WriteAllBytes(sidecarGb2, gbk2.ToArray());
        var readGb2 = LrcReader.Read(audioGb2);
        Program.Check("lrc: GBK 混排解码", readGb2.Exists && readGb2.Text == "蓝天白云", readGb2.Text);

        // 无侧车
        Program.Check("lrc: 无侧车 Exists=false", !LrcReader.Read(Path.Combine(dir, "none.mp3")).Exists);
    }

    /* ------------------------------------------------------------------ */
    /* 多语言层拆分（T0）：内嵌双语 / .trans.lrc / .romaji.lrc / 纯文本    */
    /* ------------------------------------------------------------------ */

    private static void MultilingualLayers(string root)
    {
        var db = Path.Combine(root, "layers.db");
        var index = Path.Combine(root, "layers-idx.db");
        var dir = Path.Combine(root, "layers");
        Directory.CreateDirectory(dir);

        var songB = Path.Combine(dir, "bilingual.mp3");   // 内嵌双语（同时间戳 3 行）
        var songC = Path.Combine(dir, "sidecar.mp3");      // 显式 .trans / .romaji 侧车
        var songD = Path.Combine(dir, "plain.mp3");        // 纯文本内嵌
        var songE = Path.Combine(dir, "notrans.mp3");      // 无译文
        var songH = Path.Combine(dir, "dual.mp3");         // 双语主 .lrc（同时间戳 3 行）
        var songDup = Path.Combine(dir, "dup.mp3");        // 内嵌 == 侧车（去重用例）
        var songOne = Path.Combine(dir, "one.mp3");        // 仅内嵌（对照组）

        CreateLibrary(db, generation: 1);
        using (var conn = Open(db))
        {
            InsertTrack(conn, "tB", songB, "双语", "[]", null,
                "[00:01.00]我爱你\n[00:01.00]I love you\n[00:01.00]wo ai ni\n"
                + "[00:02.00]再见\n[00:02.00]goodbye", 1);
            InsertTrack(conn, "tC", songC, "侧车", "[]", null, null, 2);
            InsertTrack(conn, "tD", songD, "纯文本", "[]", null, "只此一行原文", 3);
            InsertTrack(conn, "tE", songE, "无译文", "[]", null, "没有翻译", 4);
            InsertTrack(conn, "tH", songH, "双语LRC", "[]", null, null, 5);
            // 去重用例：tDUP 的内嵌与侧车**同一文本**；tONE 只有内嵌（同文本）——
            // 除侧车外两行完全一致，故 FTS 各列 token 数应逐列相同（去重生效）。
            InsertTrack(conn, "tDUP", songDup, "去重", "[]", null, "[00:02.00]相同歌词内容", 6);
            InsertTrack(conn, "tONE", songOne, "去重", "[]", null, "[00:02.00]相同歌词内容", 7);
        }

        File.WriteAllText(Path.Combine(dir, "dual.lrc"),
            "[00:01.00]你好世界\n[00:01.00]hello world\n[00:01.00]ni hao shi jie\n", new UTF8Encoding(false));

        // tC / tE / tH 的侧车文本由**扫描器写入 library.db**（索引器只读 DB）：
        // 原始文本保时间轴，索引器经共享 LrcReader.FromRawTexts 拆层。
        using (var conn = Open(db))
        {
            SetSidecar(conn, "tC",
                "[00:01.00]月亮代表我的心\n[00:02.00]轻轻地\n",
                "[00:01.00]The moon represents my heart\n[00:02.00]gently\n",
                "[00:01.00]yue liang dai biao wo de xin\n[00:02.00]qing qing de\n");
            SetSidecar(conn, "tE", "[00:01.00]没有翻译\n");
            SetSidecar(conn, "tH",
                "[00:01.00]你好世界\n[00:01.00]hello world\n[00:01.00]ni hao shi jie\n");
            // 与内嵌同文本（仅时间轴不同）→ 归一后相同 → 应只索引一份
            SetSidecar(conn, "tDUP", "[00:01.00]相同歌词内容\n");
        }

        var result = RunEngine(db, index, full: true, lrc: true);
        Program.Check("层拆分: indexed==7", result.Indexed == 7, result.Indexed.ToString());

        // 内嵌与侧车**完全相同** → 只索引一份（真实曲库 126/151 首属这种情形，否则同一段
        // 文本在倒排里存两遍）。判定用 FTS 的逐列 token 数（`search_fts_docsize`）：两行除
        // 侧车外完全一致，故去重生效时 docsize 逐列相同（未去重则歌词 / 拼音列翻倍）。
        var dupSize = DocSizeHex(index, "tDUP");
        var oneSize = DocSizeHex(index, "tONE");
        Program.Check("去重: 内嵌==侧车时 docsize 与仅内嵌完全一致",
            dupSize.Length > 0 && dupSize == oneSize, $"{dupSize} vs {oneSize}");

        // 内嵌双语（同时间戳 3 行）：原文 / 译文 / 音译分别入列，互不掺混。
        Program.Check("层拆分: 内嵌原文 '我爱你' 命中原文列 tB",
            MatchContainsTrack(index, "{lyrics_tok} : (" + Analyzed("我爱你") + ")", "tB"));
        Program.Check("层拆分: 内嵌英文译文 'love' 命中译文列 tB",
            MatchContainsTrack(index, "{lyrics_tr_tok} : \"love\"", "tB"));
        Program.Check("层拆分: 内嵌罗马音 'wo' 命中音译列 tB",
            MatchContainsTrack(index, "{lyrics_rom_tok} : \"wo\"", "tB"));
        Program.Check("层拆分: 原文列不含译文 'love'（不回退）",
            !MatchContainsTrack(index, "{lyrics_tok} : \"love\"", "tB"));
        Program.Check("层拆分: 译文列不含原文 '我'",
            MatchCount(index, "{lyrics_tr_tok} : \"我\"") == 0);

        // 显式侧车：主 .lrc 原文入原文列；.trans.lrc / .romaji.lrc 各入对应层。
        Program.Check("侧车: 主 .lrc 原文 '月亮' 命中原文列 tC",
            MatchContainsTrack(index, "{lyrics_tok} : \"月亮\"", "tC"));
        Program.Check("侧车: .trans.lrc 'moon' 命中译文列 tC",
            MatchContainsTrack(index, "{lyrics_tr_tok} : \"moon\"", "tC"));
        Program.Check("侧车: .romaji.lrc 'yue' 命中音译列 tC",
            MatchContainsTrack(index, "{lyrics_rom_tok} : \"yue\"", "tC"));

        // 双语主 .lrc（同时间戳 3 行）：英文译文可被英文查询命中，罗马音命中音译列。
        Program.Check("双语.lrc: 原文 '你好' 命中原文列 tH",
            MatchContainsTrack(index, "{lyrics_tok} : \"你好\"", "tH"));
        Program.Check("双语.lrc: 英文译文 'hello' 命中译文列 tH",
            MatchContainsTrack(index, "{lyrics_tr_tok} : \"hello\"", "tH"));
        Program.Check("双语.lrc: 罗马音 'hao' 命中音译列 tH",
            MatchContainsTrack(index, "{lyrics_rom_tok} : \"hao\"", "tH"));

        // 纯文本：整体入原文列；译文 / 音译层空。
        Program.Check("纯文本: '只此' 命中原文列 tD",
            MatchContainsTrack(index, "{lyrics_tok} : \"只此\"", "tD"));
        Program.Check("纯文本: 译文列为空",
            MatchCount(index, "{lyrics_tr_tok} : \"只此\"") == 0);

        // 无译文：原文命中；译文 / 音译层空。
        Program.Check("无译文: '没有翻译' 命中原文列 tE",
            MatchContainsTrack(index, "{lyrics_tok} : (" + Analyzed("没有翻译") + ")", "tE"));
        Program.Check("无译文: 译文列空（tE 不命中）",
            !MatchContainsTrack(index, "{lyrics_tr_tok} : (" + Analyzed("没有翻译") + ")", "tE"));

        // T1 素材就位（查询侧跨语言候选由 Dart 编译，这里验证索引内容可供召回）：
        // 英文词 love 的候选汉字含「爱」；英文查询经候选「爱」可命中含「爱」的中文内容（tB 原文）。
        Program.Check("T1 素材: AnalyzeQuery('love') 候选含 爱",
            Analyzer.AnalyzeQuery("love").CrossLingual.Contains("爱"));
        Program.Check("T1 素材: 候选 '爱' 命中 tB 原文",
            MatchContainsTrack(index, "{lyrics_tok} : \"爱\"", "tB"));
        // 反向：汉字「爱」的英文释义词含 love；可命中含 love 的英文层（tB 译文）。
        Program.Check("T1 素材: AnalyzeQuery('爱') 候选含 love",
            Analyzer.AnalyzeQuery("爱").CrossLingual.Contains("love"));
        Program.Check("T1 素材: 候选 'love' 命中 tB 译文",
            MatchContainsTrack(index, "{lyrics_tr_tok} : \"love\"", "tB"));
    }

    /* ------------------------------------------------------------------ */
    /* 引擎 / fixture 辅助                                                 */
    /* ------------------------------------------------------------------ */

    private static IndexerResult RunEngine(string db, string index, bool full, bool lrc)
        => RunEngineDetailed(db, index, full, lrc).Result;

    /// <summary>运行引擎并回传阶段二「取内容」SQL 次数（用于断言未全库读歌词）。</summary>
    private static (IndexerResult Result, int ContentQueries) RunEngineDetailed(
        string db, string index, bool full, bool lrc)
    {
        using var store = new FtsStore();
        var engine = new IndexerEngine(store);
        var result = engine.Run(db, index, full, new IndexerOptions { IndexLrc = lrc, Pinyin = true });
        return (result, engine.ContentQueries);
    }

    private static void CreateLibrary(string path, long? generation)
    {
        if (File.Exists(path)) File.Delete(path);
        using var conn = Open(path);
        // 与 scanner 的 tracks 表同形（v3：含 .lrc 侧车列——**扫描器写入、索引器只读**）。
        Exec(conn, """
            CREATE TABLE tracks (
                id TEXT PRIMARY KEY, path TEXT NOT NULL UNIQUE, title TEXT NOT NULL,
                track INTEGER, artists TEXT NOT NULL DEFAULT '[]', album TEXT,
                duration INTEGER NOT NULL, cover TEXT, codec TEXT, sample_rate INTEGER,
                bit_rate INTEGER, channels INTEGER, bits_per_sample INTEGER,
                file_size INTEGER NOT NULL, file_mtime INTEGER, file_ctime INTEGER,
                scanned_at INTEGER NOT NULL, lyrics TEXT, loudness_lufs REAL, loudness_peak REAL,
                lyrics_lrc TEXT, lyrics_lrc_trans TEXT, lyrics_lrc_romaji TEXT,
                lrc_mtime INTEGER, lrc_size INTEGER, lrc_checked INTEGER
            )
            """);
        if (generation.HasValue)
        {
            Exec(conn, "CREATE TABLE _scanner_meta (generation INTEGER)");
            Exec(conn, $"INSERT INTO _scanner_meta (generation) VALUES ({generation.Value})");
        }
    }

    /// <summary>
    /// 写入 scanner 负责的 <c>.lrc</c> 侧车列（**索引器只读 DB**，不再读文件系统）：
    /// 存**原始文本**（保时间轴，播放侧也用同一份），mtime/size 供脏集判定。
    /// </summary>
    private static void SetSidecar(
        SqliteConnection conn, string id, string? main, string? trans = null, string? romaji = null,
        long mtime = 100)
    {
        var exists = main is not null || trans is not null || romaji is not null;
        using var cmd = conn.CreateCommand();
        cmd.CommandText =
            "UPDATE tracks SET lyrics_lrc=@m, lyrics_lrc_trans=@t, lyrics_lrc_romaji=@r, "
            + "lrc_mtime=@mt, lrc_size=@s, lrc_checked=1 WHERE id=@id";
        cmd.Parameters.AddWithValue("@m", (object?)main ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@t", (object?)trans ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@r", (object?)romaji ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@mt", exists ? mtime : 0);
        cmd.Parameters.AddWithValue("@s", (main?.Length ?? 0) + (trans?.Length ?? 0) + (romaji?.Length ?? 0));
        cmd.Parameters.AddWithValue("@id", id);
        cmd.ExecuteNonQuery();
    }

    private static void InsertTrack(
        SqliteConnection conn, string id, string path, string title,
        string artists, string? album, string? lyrics, long mtime)
    {
        using var cmd = conn.CreateCommand();
        cmd.CommandText = """
            INSERT INTO tracks (id, path, title, artists, album, duration, file_size, file_mtime,
                                file_ctime, scanned_at, lyrics)
            VALUES (@id, @path, @title, @artists, @album, 0, 0, @mtime, 0, 0, @lyrics)
            """;
        cmd.Parameters.AddWithValue("@id", id);
        cmd.Parameters.AddWithValue("@path", path);
        cmd.Parameters.AddWithValue("@title", title);
        cmd.Parameters.AddWithValue("@artists", artists);
        cmd.Parameters.AddWithValue("@album", (object?)album ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@mtime", mtime);
        cmd.Parameters.AddWithValue("@lyrics", (object?)lyrics ?? DBNull.Value);
        cmd.ExecuteNonQuery();
    }

    private static SqliteConnection Open(string path)
    {
        var conn = new SqliteConnection($"Data Source={path}");
        conn.Open();
        return conn;
    }

    private static void Exec(SqliteConnection conn, string sql)
    {
        using var cmd = conn.CreateCommand();
        cmd.CommandText = sql;
        cmd.ExecuteNonQuery();
    }

    private static void Exec(string path, string sql)
    {
        using var conn = Open(path);
        Exec(conn, sql);
    }

    private static string? Meta(string index, string key)
    {
        using var conn = new SqliteConnection($"Data Source={index};Mode=ReadOnly");
        conn.Open();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "SELECT value FROM search_meta WHERE key = @k";
        cmd.Parameters.AddWithValue("@k", key);
        return cmd.ExecuteScalar() as string;
    }

    private static long Scalar(string index, string sql)
    {
        using var conn = new SqliteConnection($"Data Source={index};Mode=ReadOnly");
        conn.Open();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = sql;
        var value = cmd.ExecuteScalar();
        return value is null || value is DBNull ? 0 : Convert.ToInt64(value);
    }

    private static long DocScalar(string index, string trackId, string column)
    {
        using var conn = new SqliteConnection($"Data Source={index};Mode=ReadOnly");
        conn.Open();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = $"SELECT {column} FROM search_docs WHERE track_id = @t";
        cmd.Parameters.AddWithValue("@t", trackId);
        var value = cmd.ExecuteScalar();
        return value is null || value is DBNull ? 0 : Convert.ToInt64(value);
    }

    private static int MatchCount(string index, string matchExpr)
    {
        using var conn = new SqliteConnection($"Data Source={index};Mode=ReadOnly");
        conn.Open();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "SELECT COUNT(*) FROM search_fts WHERE search_fts MATCH @q";
        cmd.Parameters.AddWithValue("@q", matchExpr);
        var value = cmd.ExecuteScalar();
        return value is null || value is DBNull ? 0 : Convert.ToInt32(value);
    }

    private static bool MatchContainsTrack(string index, string matchExpr, string trackId)
    {
        using var conn = new SqliteConnection($"Data Source={index};Mode=ReadOnly");
        conn.Open();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = """
            SELECT COUNT(*) FROM search_fts f
            JOIN search_docs d ON d.doc_id = f.rowid
            WHERE search_fts MATCH @q AND d.track_id = @t
            """;
        cmd.Parameters.AddWithValue("@q", matchExpr);
        cmd.Parameters.AddWithValue("@t", trackId);
        var value = cmd.ExecuteScalar();
        return value is not null && value is not DBNull && Convert.ToInt32(value) > 0;
    }

    /// <summary>与 CLI <c>query</c> 同构：把“人话”经分析器归一为空格连接的 MATCH 表达式。</summary>
    /// <summary>FTS 逐列 token 数（`search_fts_docsize.size` 的十六进制），用于判「是否重复索引」。</summary>
    private static string DocSizeHex(string index, string trackId)
    {
        using var conn = new SqliteConnection($"Data Source={index};Mode=ReadOnly");
        conn.Open();
        using var cmd = conn.CreateCommand();
        cmd.CommandText =
            "SELECT hex(sz) FROM search_fts_docsize "
            + "WHERE id = (SELECT doc_id FROM search_docs WHERE track_id = @t)";
        cmd.Parameters.AddWithValue("@t", trackId);
        return cmd.ExecuteScalar()?.ToString() ?? "";
    }

    private static string Analyzed(string text)
    {
        var tokens = Analyzer.AnalyzeQuery(text).Lexical.Where(t => t.Length > 0).ToList();
        return tokens.Count == 0 ? "\"\"" : string.Join(' ', tokens);
    }

    private static void TryDelete(string dir)
    {
        try { if (Directory.Exists(dir)) Directory.Delete(dir, recursive: true); }
        catch { /* 临时目录清理失败不影响测试结果 */ }
    }
}
