// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

namespace Archoera.Indexer.Tests;

/// <summary>
/// 查询层（<see cref="SearchQuery"/> + <see cref="SearchSession"/>）测试。
///
/// 覆盖两件事：
/// <list type="bullet">
///   <item><b>编译黄金向量</b>：主趟 / metadata 列过滤 / 拼音宽松 / 日文读音 / 跨语言 /
///         模糊 / 中文变体，确保 C# 编译器与旧 Dart 实现逐字符等价；</item>
///   <item><b>端到端渐进查询</b>：真实建库后验证「精确 → 拼音 → 读音 → 跨语言 → 模糊 →
///         中文容错」的命中与 <c>passes</c> 计数。</item>
/// </list>
/// </summary>
internal static class SearchLayerTests
{
    public static void Run()
    {
        CompilerGolden();
        CjkVariants();
        ReadingTiers();
        ProgressiveQuery();
        LanguageProfile();
        QueryResultCache();
    }

    /* ------------------------------------------------------------------ */
    /* 编译黄金向量                                                        */
    /* ------------------------------------------------------------------ */

    private static void CompilerGolden()
    {
        var tokens = Analyzer.AnalyzeQuery("我爱你");
        const string expected = "(\"我爱 爱你\" AND \"我\" AND \"爱\" AND \"你\""
            + " OR {pinyin_meta_tok pinyin_lyrics_tok} : \"wo ai ni\""
            + " OR (initials_meta_tok initials_lyrics_tok : \"wan\"*))";
        var match = SearchQuery.CompileMatch(tokens, metadata: false);
        Program.Check("查询编译器: 我爱你 主趟", match == expected, match ?? "<null>");

        var meta = SearchQuery.CompileMatch(tokens, metadata: true);
        const string metaPrefix =
            "{title_tok artist_tok album_tok filename_tok pinyin_meta_tok initials_meta_tok reading_meta_tok} : ";
        Program.Check("查询编译器: metadata 列过滤",
            meta == metaPrefix + expected, meta ?? "<null>");

        var loose = SearchQuery.CompilePinyinLoose(Analyzer.AnalyzeQuery("周伦"), metadata: false);
        Program.Check("查询编译器: 周伦 拼音宽松含 n/l 模糊音",
            loose == "{pinyin_meta_tok pinyin_lyrics_tok} : ((\"zhou\" OR \"zou\") AND (\"lun\"* OR \"nun\"*))",
            loose ?? "<null>");

        // T1-6 模糊音：平翘舌 / 前后鼻音双向扩展（仅兜底趟）。
        var zongguo = SearchQuery.CompilePinyinLoose(Analyzer.AnalyzeQuery("zongguo"), metadata: false);
        Program.Check("查询编译器: zongguo 扩展 zh",
            zongguo == "{pinyin_meta_tok pinyin_lyrics_tok} : ((\"zong\" OR \"zhong\") AND \"guo\"*)",
            zongguo ?? "<null>");
        var shanghai = SearchQuery.CompilePinyinLoose(Analyzer.AnalyzeQuery("shanghai"), metadata: false);
        Program.Check("查询编译器: shanghai 声母+韵母组合（≤4 变体）",
            shanghai == "{pinyin_meta_tok pinyin_lyrics_tok}"
                + " : ((\"shang\" OR \"sang\" OR \"shan\" OR \"san\") AND (\"hai\"* OR \"fai\"*))",
            shanghai ?? "<null>");
        // 英文词不是有效拼音音节 → 不套用 n/l、f/h 规则。
        var english = SearchQuery.CompilePinyinLoose(Analyzer.AnalyzeQuery("hello world"), metadata: false);
        Program.Check("查询编译器: 英文词不扩展模糊音",
            english is not null && !english.Contains("fello", StringComparison.Ordinal)
                && !english.Contains("world\"* OR", StringComparison.Ordinal)
                && english.Contains("\"world\"*", StringComparison.Ordinal),
            english ?? "<null>");

        var reading = SearchQuery.CompileReading(Analyzer.AnalyzeQuery("kurarin"), metadata: false);
        Program.Check("查询编译器: kurarin 读音 bigram 短语",
            reading == "{reading_meta_tok lyrics_rom_tok} : (\"ku ur ra ar ri in\")", reading ?? "<null>");

        // T1-1 规范形：Hepburn / Kunrei 折叠成同一表达式。
        var shitsuke = SearchQuery.CompileReading(Analyzer.AnalyzeQuery("shitsuke"), metadata: false);
        Program.Check("查询编译器: shitsuke 折叠为规范形",
            shitsuke == "{reading_meta_tok lyrics_rom_tok} : (\"si it tu uk ke\")", shitsuke ?? "<null>");
        var situke = SearchQuery.CompileReading(Analyzer.AnalyzeQuery("situke"), metadata: false);
        Program.Check("查询编译器: shitsuke / situke 一致", situke == shitsuke, situke ?? "<null>");
        var kinen = SearchQuery.CompileReading(Analyzer.AnalyzeQuery("kinen"), metadata: false);
        Program.Check("查询编译器: ん+元音 放宽变体 OR",
            kinen == "{reading_meta_tok lyrics_rom_tok} : ((\"ki in ne en\" OR \"ki in nn ne en\"))",
            kinen ?? "<null>");

        var cross = SearchQuery.CompileCrossLingual(Analyzer.AnalyzeQuery("love"), metadata: false);
        Program.Check("查询编译器: love 跨语言候选含 爱",
            cross is not null && cross.Contains("\"爱\"", StringComparison.Ordinal),
            cross ?? "<null>");

        var fuzzy = SearchQuery.CompileFuzzy(Analyzer.AnalyzeQuery("hello"), metadata: false);
        Program.Check("查询编译器: hello 模糊变体",
            fuzzy is not null
                && fuzzy.StartsWith('(')
                && fuzzy.Contains("\"hello\"*", StringComparison.Ordinal)
                && fuzzy.Contains("\"helo\"*", StringComparison.Ordinal)
                && fuzzy.Contains("\"ehllo\"*", StringComparison.Ordinal)
                && fuzzy.Contains("\"hallo\"*", StringComparison.Ordinal),
            fuzzy ?? "<null>");

        // T1-8 模糊层词典化：Myers 距离判定 + 词表过滤。
        var vocabulary = new[] { "hello", "hello world", "help", "hlelo", "yellow" };
        Program.Check("Myers: helo/hello ≤1", FuzzyVocabulary.WithinOne("helo", "hello"));
        Program.Check("Myers: hlelo/hello 换位算 1", FuzzyVocabulary.WithinOne("hlelo", "hello"));
        Program.Check("Myers: hello/help >1", !FuzzyVocabulary.WithinOne("hello", "help"));
        Program.Check("Myers: 同词距离 0", FuzzyVocabulary.WithinOne("abc", "abc"));
        var range = FuzzyVocabulary.PrefixRange(vocabulary, "hello");
        Program.Check("模糊词典: 前缀区间", range.Start == 0 && range.End == 2,
            $"{range.Start}-{range.End}");

        var vocabFuzzy = SearchQuery.CompileFuzzy(Analyzer.AnalyzeQuery("hlelo"), false, vocabulary);
        Program.Check("查询编译器: 模糊词典保留真实词条",
            vocabFuzzy is not null && vocabFuzzy.Contains("\"hello\"", StringComparison.Ordinal),
            vocabFuzzy ?? "<null>");
        Program.Check("查询编译器: 模糊词典不再枚举不存在变体",
            vocabFuzzy is not null && !vocabFuzzy.Contains("\"ehllo\"", StringComparison.Ordinal),
            vocabFuzzy ?? "<null>");

        Program.Check("查询编译器: 纯 CJK 无模糊可扩展项",
            !SearchQuery.HasFuzzyEligible(Analyzer.AnalyzeQuery("晴天")));
        Program.Check("查询编译器: 拉丁可模糊",
            SearchQuery.HasFuzzyEligible(Analyzer.AnalyzeQuery("hello")));
    }

    private static void CjkVariants()
    {
        Program.Check("中文变体: 周伦 → 伦 / 周 / 伦周",
            Join(SearchQuery.CjkVariants("周伦")) == "伦,周,伦周",
            Join(SearchQuery.CjkVariants("周伦")));
        Program.Check("中文变体: 一一 去重（换位无意义）",
            Join(SearchQuery.CjkVariants("一一")) == "一",
            Join(SearchQuery.CjkVariants("一一")));
        Program.Check("中文变体: 单字不生成",
            SearchQuery.CjkVariants("我").Count == 0);
        Program.Check("中文变体: 纯拉丁不生成",
            SearchQuery.CjkVariants("hello").Count == 0);
        Program.Check("中文变体: 超长放弃",
            SearchQuery.CjkVariants(new string('我', SearchQuery.MaxCjkQueryLength + 1)).Count == 0);
        Program.Check("中文变体: 预算截断",
            SearchQuery.CjkVariants("春夏秋冬东南西北金木水火土风雨雷电山川", maxVariants: 5).Count == 5);
    }

    private static void ReadingTiers()
    {
        var sequences = SearchQuery.ReadingSequences(Analyzer.AnalyzeQuery("shitsuke"));
        Program.Check("读音分档: shitsuke 规范形 bigram 序列",
            sequences.Count == 1 && string.Join(' ', sequences[0]) == "si it tu uk ke",
            sequences.Count == 1 ? string.Join(' ', sequences[0]) : "<none>");

        Program.Check("读音分档: 前缀档",
            ReadingRanker.Score("si it tu uk ke te es su to", sequences) == ReadingRanker.PrefixTier,
            ReadingRanker.Score("si it tu uk ke te es su to", sequences).ToString());
        Program.Check("读音分档: 包含档",
            ReadingRanker.Score("ki im mi in no si it tu uk ke", sequences) == ReadingRanker.ContainsTier,
            ReadingRanker.Score("ki im mi in no si it tu uk ke", sequences).ToString());
        Program.Check("读音分档: 不连续不算命中",
            ReadingRanker.Score("si it tu to uk ke", sequences) == ReadingRanker.OtherTier,
            ReadingRanker.Score("si it tu to uk ke", sequences).ToString());
        Program.Check("读音分档: 无读音文本落兜底档",
            ReadingRanker.Score("", sequences) == ReadingRanker.OtherTier);
    }

    /* ------------------------------------------------------------------ */
    /* 端到端渐进查询                                                      */
    /* ------------------------------------------------------------------ */

    private static void ProgressiveQuery()
    {
        var root = Path.Combine(
            Path.GetTempPath(), "archoera-search-layer-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var db = Path.Combine(root, "library.db");
            var index = Path.Combine(root, "search.db");
            var media = Path.Combine(root, "media");
            Directory.CreateDirectory(media);

            EndToEnd.CreateLibrary(db, generation: 1);
            using (var conn = EndToEnd.Open(db))
            {
                EndToEnd.InsertTrack(conn, "t1", Path.Combine(media, "a.mp3"), "晴天",
                    """[{"name":"周杰伦"}]""", """{"name":"范特西"}""",
                    "[00:01.00]我爱你中国\n[00:02.00]我爱你", 1000);
                EndToEnd.InsertTrack(conn, "t2", Path.Combine(media, "b.mp3"), "爱",
                    """[{"name":"邓丽君"}]""", """{"name":"经典"}""", "我愛你", 2000);
                EndToEnd.InsertTrack(conn, "t3", Path.Combine(media, "c.mp3"), "Hello World",
                    """[{"name":"ADELE"}]""", """{"name":"25"}""", null, 3000);
                EndToEnd.InsertTrack(conn, "t4", Path.Combine(media, "d.mp3"), "きゅうくらりん",
                    """[{"name":"花譜"}]""", null, null, 4000);
                EndToEnd.InsertTrack(conn, "t5", Path.Combine(media, "e.mp3"), "月亮代表我的心",
                    """[{"name":"邓丽君"}]""", null, "月亮代表我的心", 5000);
                EndToEnd.InsertTrack(conn, "t6", Path.Combine(media, "f.mp3"), "Love Story",
                    """[{"name":"Taylor Swift"}]""", null, null, 6000);
                EndToEnd.InsertTrack(conn, "t7", Path.Combine(media, "g.mp3"), "しつけ",
                    """[{"name":"テスト"}]""", null, null, 7000);
                EndToEnd.InsertTrack(conn, "t8", Path.Combine(media, "h.mp3"), "きみは",
                    """[{"name":"テスト"}]""", null, null, 8000);
                EndToEnd.InsertTrack(conn, "t9", Path.Combine(media, "i.mp3"), "사랑해",
                    """[{"name":"테스트"}]""", null, null, 9000);
                EndToEnd.InsertTrack(conn, "t10", Path.Combine(media, "j.mp3"), "銀河鉄道の夜",
                    """[{"name":"銀河"}]""", null, null, 10000);
                EndToEnd.InsertTrack(conn, "t11", Path.Combine(media, "k.mp3"), "きみのしつけ",
                    """[{"name":"テスト"}]""", null, null, 11000);
            }

            var built = EndToEnd.RunEngine(db, index, full: true, lrc: false);
            Program.Check("查询层: 建库 11 首", built.Indexed == 11, built.Indexed.ToString());

            // T1-8：模糊词典直接读索引自身的 FTS 词表（不落盘、不改 schema）。
            using (var store = new FtsStore())
            {
                store.OpenReadOnly(index);
                var meta = store.ReadMeta();
                Program.Check("语言画像: 混合库四项齐全",
                    meta.HasJapanese && meta.HasKorean && meta.HasHan && meta.HasLatin,
                    $"{meta.HasJapanese}/{meta.HasKorean}/{meta.HasHan}/{meta.HasLatin}");

                var vocabulary = store.LoadFuzzyVocabulary();
                Program.Check("模糊词典: 从 FTS 词表加载", vocabulary.Count > 10,
                    vocabulary.Count.ToString());
                Program.Check("模糊词典: 只含 ASCII 词元",
                    vocabulary.All(t => t.All(c => (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'))));
            }

            // 1) 主趟精确：中文标题命中且不付兜底成本。
            var sunny = Run(index, "晴天");
            Program.Check("查询层: 晴天 命中 t1", Has(sunny, "t1"), Dump(sunny));
            Program.Check("查询层: 晴天 不触发任何兜底",
                sunny.Passes.PinyinLoose == 0 && sunny.Passes.Reading == 0
                && sunny.Passes.CrossLingual == 0 && sunny.Passes.Fuzzy == 0
                && sunny.Passes.CjkFuzzy == 0,
                Dump(sunny));

            // 2) 拼音宽松兜底：漏字（周伦 ⊂ 周杰伦）。
            var zhouLun = Run(index, "周伦", fuzzy: true);
            Program.Check("查询层: 周伦 拼音兜底命中 t1", Has(zhouLun, "t1"), Dump(zhouLun));
            Program.Check("查询层: 周伦 只走拼音兜底",
                zhouLun.Passes.PinyinLoose == 1 && zhouLun.Passes.CjkFuzzy == 0,
                Dump(zhouLun));

            // 3) 中文容错兜底：错字（周杰美 → 周杰）。
            var zhouJieMei = Run(index, "周杰美", fuzzy: true);
            Program.Check("查询层: 周杰美 中文容错命中 t1", Has(zhouJieMei, "t1"), Dump(zhouJieMei));
            Program.Check("查询层: 周杰美 cjkFuzzy == 1",
                zhouJieMei.Passes.CjkFuzzy == 1, Dump(zhouJieMei));

            // 4) 日文读音兜底：拉丁罗马字 → 假名标题。
            var kurarin = Run(index, "kurarin", fuzzy: true);
            Program.Check("查询层: kurarin 读音兜底命中 t4", Has(kurarin, "t4"), Dump(kurarin));
            Program.Check("查询层: kurarin reading == 1",
                kurarin.Passes.Reading == 1, Dump(kurarin));

            // 4b) 罗马音规范形（T1-1）：Hepburn / Kunrei 互搜「しつけ」。
            var hepburn = Run(index, "shitsuke", fuzzy: true);
            Program.Check("查询层: shitsuke 规范形命中 t7", Has(hepburn, "t7"), Dump(hepburn));
            var kunrei = Run(index, "situke", fuzzy: true);
            Program.Check("查询层: situke 规范形命中 t7", Has(kunrei, "t7"), Dump(kunrei));

            // 4b-2) 读音分档（T1-4）：整词前缀（しつけ）排在整词包含（きみのしつけ）之前。
            Program.Check("查询层: shitsuke 前缀档排在包含档前",
                Rank(hepburn, "t7") >= 0 && Rank(hepburn, "t11") >= 0
                && Rank(hepburn, "t7") < Rank(hepburn, "t11"),
                Dump(hepburn));

            // 4c) 助词双写（T1-2）：は 同时索引 ha / wa。
            var kimiWa = Run(index, "kimi wa", fuzzy: true);
            Program.Check("查询层: kimi wa 命中 t8", Has(kimiWa, "t8"), Dump(kimiWa));
            var kimiHa = Run(index, "kimi ha", fuzzy: true);
            Program.Check("查询层: kimi ha 命中 t8", Has(kimiHa, "t8"), Dump(kimiHa));

            // 4d) 韩文读音（T1-3）：谚文 → 国语罗马字。
            var sarang = Run(index, "sarang", fuzzy: true);
            Program.Check("查询层: sarang 读音兜底命中 t9", Has(sarang, "t9"), Dump(sarang));
            var saranghae = Run(index, "saranghae", fuzzy: true);
            Program.Check("查询层: saranghae 读音兜底命中 t9", Has(saranghae, "t9"), Dump(saranghae));

            // 4e) 拼音模糊音（T1-6）：zou → zhou（z/zh 双向），lun 原样。
            var zouLun = Run(index, "zoulun", fuzzy: true);
            Program.Check("查询层: zoulun 模糊音命中 t1", Has(zouLun, "t1"), Dump(zouLun));
            Program.Check("查询层: zoulun 只走拼音兜底",
                zouLun.Passes.PinyinLoose == 1 && zouLun.Passes.Fuzzy == 0
                && zouLun.Passes.CjkFuzzy == 0, Dump(zouLun));

            // 4f) 日文新字体归一（T1-7）：简体查询命中新字体标题，主趟即中。
            var galaxy = Run(index, "银河铁道");
            Program.Check("查询层: 银河铁道 命中 t10（新字体归一）", Has(galaxy, "t10"), Dump(galaxy));
            Program.Check("查询层: 新字体归一不付兜底",
                galaxy.Passes.PinyinLoose == 0 && galaxy.Passes.Reading == 0
                && galaxy.Passes.CrossLingual == 0, Dump(galaxy));

            // 5) 跨语言兜底：英文释义 → 中文标题。
            var moon = Run(index, "moon", fuzzy: true);
            Program.Check("查询层: moon 跨语言命中 t5", Has(moon, "t5"), Dump(moon));
            Program.Check("查询层: moon crossLingual == 1",
                moon.Passes.CrossLingual == 1, Dump(moon));

            // 6) 拉丁精确：不触发模糊。
            var hello = Run(index, "hello");
            Program.Check("查询层: hello 命中 t3", Has(hello, "t3"), Dump(hello));
            Program.Check("查询层: hello 不触发模糊", hello.Passes.Fuzzy == 0, Dump(hello));

            // 7) 拉丁模糊趟：无可召回时仍按约定计一次趟次。
            var greetings = Run(index, "greetings", fuzzy: true);
            Program.Check("查询层: greetings fuzzy == 1",
                greetings.Passes.Fuzzy == 1, Dump(greetings));
            Program.Check("查询层: greetings 无命中",
                greetings.Items.Count == 0, Dump(greetings));

            // 7b) 模糊层词典化（T1-8）：换位拼错仍命中，且只走模糊趟。
            var typo = Run(index, "hlelo", fuzzy: true);
            Program.Check("查询层: hlelo 模糊命中 t3", Has(typo, "t3"), Dump(typo));
            Program.Check("查询层: hlelo 命中来自模糊趟",
                typo.Passes.Fuzzy == 1 && typo.Passes.PinyinLoose == 0
                && typo.Passes.CrossLingual == 0 && typo.Passes.CjkFuzzy == 0, Dump(typo));

            // 8) metadata 范围只搜元数据，不触歌词。
            var artist = Run(index, "周杰伦", metadata: true);
            Program.Check("查询层: metadata 搜歌手命中 t1", Has(artist, "t1"), Dump(artist));
            var lyricsOnly = Run(index, "我爱你", metadata: true);
            Program.Check("查询层: metadata 不搜歌词", !Has(lyricsOnly, "t1"), Dump(lyricsOnly));

            // 9) limit / offset 翻页。
            var page1 = Run(index, "爱", limit: 1);
            var page2 = Run(index, "爱", limit: 1, offset: 1);
            Program.Check("查询层: limit == 1", page1.Items.Count == 1, Dump(page1));
            Program.Check("查询层: offset 翻页不重复",
                page1.Items.Count == 1 && page2.Items.Count == 1
                && page1.Items[0].TrackId != page2.Items[0].TrackId,
                Dump(page1) + " | " + Dump(page2));
        }
        finally
        {
            SearchSession.CloseCached();
            EndToEnd.TryDelete(root);
        }
    }

    /* ------------------------------------------------------------------ */
    /* 曲库语言画像（v7）                                                  */
    /* ------------------------------------------------------------------ */

    private static void LanguageProfile()
    {
        var root = Path.Combine(
            Path.GetTempPath(), "archoera-lang-profile-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var db = Path.Combine(root, "library.db");
            var index = Path.Combine(root, "search.db");
            var media = Path.Combine(root, "media");
            Directory.CreateDirectory(media);

            EndToEnd.CreateLibrary(db, generation: 1);
            using (var conn = EndToEnd.Open(db))
            {
                EndToEnd.InsertTrack(conn, "p1", Path.Combine(media, "a.mp3"), "Love Me",
                    """[{"name":"ADELE"}]""", null, "love me love me", 1000);
                EndToEnd.InsertTrack(conn, "p2", Path.Combine(media, "b.mp3"), "Hello World",
                    """[{"name":"ADELE"}]""", null, null, 2000);
            }
            EndToEnd.RunEngine(db, index, full: true, lrc: false);

            using (var store = new FtsStore())
            {
                store.OpenReadOnly(index);
                var meta = store.ReadMeta();
                Program.Check("语言画像: 纯拉丁库只置拉丁位",
                    !meta.HasJapanese && !meta.HasKorean && !meta.HasHan && meta.HasLatin,
                    $"{meta.HasJapanese}/{meta.HasKorean}/{meta.HasHan}/{meta.HasLatin}");
            }

            // 读音趟：库内无日 / 韩内容 → 直接跳过，不编译也不执行。
            var kurarin = Run(index, "kurarin", fuzzy: true);
            Program.Check("语言画像: 纯拉丁库跳过读音趟", kurarin.Passes.Reading == 0, Dump(kurarin));

            // 跨语言趟：汉字候选不可能命中 → 被裁掉，整趟不执行。
            var moon = Run(index, "moon", fuzzy: true);
            Program.Check("语言画像: 纯拉丁库裁剪汉字候选",
                moon.Passes.CrossLingual == 0, Dump(moon));

            // 反方向保留：汉字查询仍经英文释义候选命中英文标题。
            var ai = Run(index, "爱", fuzzy: true);
            Program.Check("语言画像: 汉字查询仍跨语言命中英文标题", Has(ai, "p1"), Dump(ai));
            Program.Check("语言画像: 汉字方向跨语言趟执行一次",
                ai.Passes.CrossLingual == 1, Dump(ai));
        }
        finally
        {
            SearchSession.CloseCached();
            EndToEnd.TryDelete(root);
        }
    }

    /* ------------------------------------------------------------------ */
    /* 查询结果 LRU（优化计划 §4-2）                                        */
    /* ------------------------------------------------------------------ */

    private static void QueryResultCache()
    {
        var root = Path.Combine(
            Path.GetTempPath(), "archoera-query-cache-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var db = Path.Combine(root, "library.db");
            var index = Path.Combine(root, "search.db");
            var media = Path.Combine(root, "media");
            Directory.CreateDirectory(media);

            EndToEnd.CreateLibrary(db, generation: 1);
            using (var conn = EndToEnd.Open(db))
            {
                EndToEnd.InsertTrack(conn, "c1", Path.Combine(media, "a.mp3"), "晴天",
                    """[{"name":"周杰伦"}]""", null, "晴天 晴天", 1000);
                EndToEnd.InsertTrack(conn, "c2", Path.Combine(media, "b.mp3"), "Hello",
                    """[{"name":"ADELE"}]""", null, null, 2000);
            }
            EndToEnd.RunEngine(db, index, full: true, lrc: false);

            SearchSession.CloseCached();
            SearchSession.DebugResetCacheStats();

            // 1) 同一请求第二次直接命中（返回同一结果实例），不再走 FTS。
            var first = Run(index, "晴天");
            var second = Run(index, "晴天");
            Program.Check("查询缓存: 重复查询命中", ReferenceEquals(first, second),
                "两次返回不是同一实例");
            Program.Check("查询缓存: 命中 / 未命中计数",
                SearchSession.DebugCacheHits == 1 && SearchSession.DebugCacheMisses == 1,
                $"{SearchSession.DebugCacheHits}/{SearchSession.DebugCacheMisses}");
            Program.Check("查询缓存: 命中结果仍正确", Has(second, "c1"), Dump(second));

            // 2) scope / limit / offset 不同的请求不串键。
            var metadata = Run(index, "晴天", metadata: true);
            var limit = Run(index, "晴天", limit: 5);
            var offset = Run(index, "晴天", limit: 1, offset: 1);
            Program.Check("查询缓存: scope 不串", !ReferenceEquals(first, metadata),
                "metadata 与全库查询共用同一结果");
            Program.Check("查询缓存: limit / offset 不串",
                !ReferenceEquals(first, limit) && !ReferenceEquals(limit, offset),
                "翻页参数不同却共用同一结果");
            Program.Check("查询缓存: 各参数组合结果正确",
                Has(metadata, "c1") && first.Items.Count >= limit.Items.Count,
                Dump(metadata) + " | " + Dump(limit) + " | " + Dump(offset));

            // 3) 首尾空白差异视为同一查询（编译侧本就忽略空白）。
            var hitsBefore = SearchSession.DebugCacheHits;
            Run(index, " 晴天 ");
            Program.Check("查询缓存: 空白差异命中同一键",
                SearchSession.DebugCacheHits == hitsBefore + 1,
                $"{SearchSession.DebugCacheHits}/{hitsBefore}");

            // 4) CloseCached（重建 / 删除索引 / 关闭开关）丢弃整个缓存。
            Program.Check("查询缓存: 会话内已积累条目",
                SearchSession.DebugCacheCount > 0, SearchSession.DebugCacheCount.ToString());
            SearchSession.CloseCached();
            Program.Check("查询缓存: CloseCached 清空",
                SearchSession.DebugCacheCount == 0, SearchSession.DebugCacheCount.ToString());
            var missesBefore = SearchSession.DebugCacheMisses;
            Run(index, "晴天");
            Program.Check("查询缓存: 重建后重新执行",
                SearchSession.DebugCacheMisses == missesBefore + 1,
                $"{SearchSession.DebugCacheMisses}/{missesBefore}");

            // 5) 容量上限：写入 > 128 条不同查询后仍只保留 128 条，最旧的被淘汰。
            SearchSession.CloseCached();
            SearchSession.DebugResetCacheStats();
            for (var i = 0; i <= SearchSession.CacheCapacity; i++) Run(index, "miss" + i);
            Program.Check("查询缓存: 容量封顶",
                SearchSession.DebugCacheCount == SearchSession.CacheCapacity,
                SearchSession.DebugCacheCount.ToString());
            var evictedBefore = SearchSession.DebugCacheMisses;
            Run(index, "miss0");
            Program.Check("查询缓存: 最旧条目被淘汰后重查",
                SearchSession.DebugCacheMisses == evictedBefore + 1,
                $"{SearchSession.DebugCacheMisses}/{evictedBefore}");
        }
        finally
        {
            SearchSession.CloseCached();
            EndToEnd.TryDelete(root);
        }
    }

    /* ------------------------------------------------------------------ */
    /* 辅助                                                                */
    /* ------------------------------------------------------------------ */

    private static SearchResult Run(
        string index, string query, bool fuzzy = false, bool metadata = false,
        int limit = 200, int offset = 0)
        => SearchSession.Run(index, new SearchRequest
        {
            Query = query,
            Fuzzy = fuzzy,
            Metadata = metadata,
            Limit = limit,
            Offset = offset,
        });

    private static bool Has(SearchResult result, string trackId)
        => result.Items.Any(hit => string.Equals(hit.TrackId, trackId, StringComparison.Ordinal));

    private static int Rank(SearchResult result, string trackId)
    {
        for (var i = 0; i < result.Items.Count; i++)
        {
            if (string.Equals(result.Items[i].TrackId, trackId, StringComparison.Ordinal)) return i;
        }
        return -1;
    }

    private static string Join(IReadOnlyList<string> values) => string.Join(',', values);

    private static string Dump(SearchResult result)
        => "[" + string.Join(',', result.Items.Select(hit => hit.TrackId))
            + $"] pinyin={result.Passes.PinyinLoose} reading={result.Passes.Reading}"
            + $" cross={result.Passes.CrossLingual} fuzzy={result.Passes.Fuzzy}"
            + $" cjk={result.Passes.CjkFuzzy}";
}
