// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

using System.Text;
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

        // 侧车歌词（t3）：含时间轴 / 元数据标签，应只取文本行
        File.WriteAllText(Path.Combine(dirB, "song3.lrc"),
            "[by:test]\n[00:01.00]蓝蓝的天\n[00:02.50]白云飘\n", new UTF8Encoding(false));

        // ---- 全量构建 ----
        var full = RunEngine(db, index, full: true, lrc: false);
        Program.Check("全量: total==4", full.Total == 4, full.Total.ToString());
        Program.Check("全量: indexed==4", full.Indexed == 4, full.Indexed.ToString());
        Program.Check("全量: full==true", full.Full);
        Program.Check("全量: generation==5", full.Generation == 5, full.Generation.ToString());
        Program.Check("全量: search.db 存在", File.Exists(index));
        Program.Check("世代化: 无 search.db.tmp", !File.Exists(index + ".tmp"));
        Program.Check("世代化: 无 search.db.tmp-wal", !File.Exists(index + ".tmp-wal"));

        Program.Check("meta.analyzer_version==5", Meta(index, "analyzer_version") == "5", Meta(index, "analyzer_version"));
        Program.Check("meta.schema_version==2", Meta(index, "schema_version") == "2", Meta(index, "schema_version"));
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
        Program.Check("contentless: search_docs 无 token 文本列（title_tok/pinyin_tok）",
            Scalar(index, "SELECT COUNT(*) FROM pragma_table_info('search_docs') WHERE name IN ('title_tok','pinyin_tok')") == 0);
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
        // 拼音（全拼短语）与首字母（单 token）
        Program.Check("MATCH pinyin 短语 'wo ai ni' 命中 t1", MatchContainsTrack(index, "\"wo ai ni\"", "t1"));
        Program.Check("MATCH 首字母 'wanzg' 命中 t1", MatchContainsTrack(index, "wanzg", "t1"));
        // P4 连写全拼：查询侧把 woaini 切为 wo/ai/ni，末音节前缀 → 命中 t1（镜像 Dart compileMatch）
        var woaini = Analyzer.AnalyzeQuery("woaini").Pinyin;
        Program.Check("E2E 连写全拼分析 == wo ai ni", string.Join(' ', woaini) == "wo ai ni",
            string.Join(' ', woaini));
        var woainiExpr = string.Join(" AND ", woaini.Select(
            (t, i) => $"\"{t}\"{(i == woaini.Count - 1 ? "*" : string.Empty)}"));
        Program.Check($"MATCH 连写全拼表达式 {woainiExpr} 命中 t1",
            MatchContainsTrack(index, woainiExpr, "t1"), woainiExpr);
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
        }

        File.WriteAllText(Path.Combine(dir, "sidecar.lrc"),
            "[00:01.00]月亮代表我的心\n[00:02.00]轻轻地\n", new UTF8Encoding(false));
        File.WriteAllText(Path.Combine(dir, "sidecar.trans.lrc"),
            "[00:01.00]The moon represents my heart\n[00:02.00]gently\n", new UTF8Encoding(false));
        File.WriteAllText(Path.Combine(dir, "sidecar.romaji.lrc"),
            "[00:01.00]yue liang dai biao wo de xin\n[00:02.00]qing qing de\n", new UTF8Encoding(false));
        File.WriteAllText(Path.Combine(dir, "notrans.lrc"), "[00:01.00]没有翻译\n", new UTF8Encoding(false));
        File.WriteAllText(Path.Combine(dir, "dual.lrc"),
            "[00:01.00]你好世界\n[00:01.00]hello world\n[00:01.00]ni hao shi jie\n", new UTF8Encoding(false));

        var result = RunEngine(db, index, full: true, lrc: true);
        Program.Check("层拆分: indexed==5", result.Indexed == 5, result.Indexed.ToString());

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
        Exec(conn, """
            CREATE TABLE tracks (
                id TEXT PRIMARY KEY, path TEXT NOT NULL UNIQUE, title TEXT NOT NULL,
                track INTEGER, artists TEXT NOT NULL DEFAULT '[]', album TEXT,
                duration INTEGER NOT NULL, cover TEXT, codec TEXT, sample_rate INTEGER,
                bit_rate INTEGER, channels INTEGER, bits_per_sample INTEGER,
                file_size INTEGER NOT NULL, file_mtime INTEGER, file_ctime INTEGER,
                scanned_at INTEGER NOT NULL, lyrics TEXT, loudness_lufs REAL, loudness_peak REAL
            )
            """);
        if (generation.HasValue)
        {
            Exec(conn, "CREATE TABLE _scanner_meta (generation INTEGER)");
            Exec(conn, $"INSERT INTO _scanner_meta (generation) VALUES ({generation.Value})");
        }
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
