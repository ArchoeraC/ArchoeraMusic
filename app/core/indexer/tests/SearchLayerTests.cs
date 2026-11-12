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
        EscapingSafety();
        CjkVariants();
        ReadingTiers();
        ProgressiveQuery();
        LanguageProfile();
        QueryResultCache();
        FuzzyVocabularyRecall();
        RankingIntegrity();
    }

    /* ------------------------------------------------------------------ */
    /* 编译黄金向量                                                        */
    /* ------------------------------------------------------------------ */

    private static void CompilerGolden()
    {
        var tokens = Analyzer.AnalyzeQuery("我爱你");
        const string expected = "(\"我爱 爱你\" AND \"我\" AND \"爱\" AND \"你\""
            + " OR {pinyin_meta_tok pinyin_lyrics_tok} : \"wo ai ni\""
            + " OR ({initials_meta_tok initials_lyrics_tok} : \"wan\"*))";
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

    /// <summary>
    /// 转义安全：查询串里的 FTS5 语法字符（<c>"</c> / <c>*</c> / <c>(</c> / <c>:</c> /
    /// <c>OR</c>）必须被当作**字面量**，不得闭合引号、不得改变表达式结构。
    ///
    /// 这是 <c>SearchQuery.Quote</c> 的安全契约（原 Dart 侧同名用例在查询层下沉后
    /// 未同步，此组补齐）：注入尝试要么整体被引号包裹，要么内部 <c>"</c> 翻倍。
    /// </summary>
    private static void EscapingSafety()
    {
        Program.Check("转义: 双引号翻倍",
            SearchQuery.Quote("a\"b") == "\"a\"\"b\"", SearchQuery.Quote("a\"b"));
        Program.Check("转义: 仅引号 → 四引号",
            SearchQuery.Quote("\"") == "\"\"\"\"", SearchQuery.Quote("\""));

        // 语法字符按字面量加引号（不构成 FTS5 语法）。
        Program.Check("转义: * ( : 按字面量加引号",
            SearchQuery.CompileMatch(Tokens(lexical: new[] { "a*b", "(", ":" }), metadata: false)
                == "\"a*b\" AND \"(\" AND \":\"",
            SearchQuery.CompileMatch(Tokens(lexical: new[] { "a*b", "(", ":" }), metadata: false) ?? "<null>");

        // 注入尝试：闭合引号后插 OR —— 整体加引号后 `""` 翻倍，结构不破。
        // 末词元 ≥3 字符照常加前缀 `*`（合法行为），关键是**没有**产生真实 OR 运算符。
        var injected = SearchQuery.CompileMatch(Tokens(lexical: new[] { "x\" OR \"y" }), metadata: false);
        Program.Check("转义: 注入 OR 被当字面量",
            injected == "\"x\"\" OR \"\"y\"*", injected ?? "<null>");
        Program.Check("转义: 注入不产生额外 OR 分支",
            injected is not null
                && injected.Count(c => c == '"') == 6
                && !injected.StartsWith('('),
            injected ?? "<null>");

        // 含引号的「类 bigram」不入短语（仅 1 个 CJK 字符），仍逐字转义。
        var quoted = SearchQuery.CompileMatch(Tokens(lexical: new[] { "我\"", "\"爱" }), metadata: false);
        Program.Check("转义: 含引号类 bigram 不合并成短语",
            quoted == "\"我\"\"\" AND \"\"\"爱\"", quoted ?? "<null>");

        // 首字母串含引号 / 空格：列过滤仍闭合（列过滤前缀不被词元内容带偏）。
        var initials = SearchQuery.CompileMatch(Tokens(initials: "a\"b"), metadata: false);
        Program.Check("转义: 首字母含引号仍闭合列过滤",
            initials == "({initials_meta_tok initials_lyrics_tok} : \"a\"\"b\"*)",
            initials ?? "<null>");

        // 跨语言候选含引号：同样按字面量转义。
        var cross = SearchQuery.CompileCrossLingual(
            Tokens(crossLingual: new[] { "l\"ove" }), metadata: false);
        Program.Check("转义: 跨语言候选含引号",
            cross == "\"l\"\"ove\"", cross ?? "<null>");
    }

    /// <summary>构造指定列最小查询词元（其余列留空），供转义用例精确控制输入。</summary>
    private static QueryTokens Tokens(
        IEnumerable<string>? lexical = null,
        IEnumerable<string>? crossLingual = null,
        string? initials = null)
    {
        var tokens = new QueryTokens();
        if (lexical is not null) tokens.Lexical.AddRange(lexical);
        if (crossLingual is not null) tokens.CrossLingual.AddRange(crossLingual);
        tokens.PinyinInitials = initials;
        return tokens;
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
                // 文件名给多字母名：单字母 `a.mp3` 会进首字母列，令 `爱`（首字母 a）
                // 在主趟就命中，掩盖「反向跨语言兜底」这条断言的真实路径。
                EndToEnd.InsertTrack(conn, "p1", Path.Combine(media, "love-me.mp3"), "Love Me",
                    """[{"name":"ADELE"}]""", null, "love me love me", 1000);
                EndToEnd.InsertTrack(conn, "p2", Path.Combine(media, "hello-world.mp3"), "Hello World",
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
    /* 模糊词表回退（T1-8 召回保护）                                       */
    /* ------------------------------------------------------------------ */

    private static void FuzzyVocabularyRecall()
    {
        var root = Path.Combine(
            Path.GetTempPath(), "archoera-fuzzy-vocab-" + Guid.NewGuid().ToString("N"));
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
                EndToEnd.InsertTrack(conn, "p1", Path.Combine(media, "a.mp3"), "我",
                    "[]", null, null, 1000);
                EndToEnd.InsertTrack(conn, "p2", Path.Combine(media, "b.mp3"), "Hello",
                    """[{"name":"ADELE"}]""", null, null, 2000);
            }
            EndToEnd.RunEngine(db, index, full: true, lrc: false);
            SearchSession.CloseCached();

            // "woo" 的删除变体 "wo" 只存在于拼音列（曲名「我」），而词表只扫文本列。
            // 词表非空（hello / adele）时，旧实现会因「无候选」整支放弃 → 丢召回。
            var pinyinHit = Run(index, "woo", fuzzy: true);
            Program.Check("模糊词表: 无候选时回退枚举并命中拼音列",
                Has(pinyinHit, "p1") && pinyinHit.Passes.Fuzzy == 1, Dump(pinyinHit));

            // 词表有候选时仍走词典化路径：hlelo → hello。
            var vocabHit = Run(index, "hlelo", fuzzy: true);
            Program.Check("模糊词表: 有候选时仍走词表", Has(vocabHit, "p2"), Dump(vocabHit));
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

    /// <summary>
    /// **排序完整性回归**（守一个曾经静默失效的生产 bug）。
    ///
    /// 历史：`FtsStore.Search` 早期用
    /// <c>WHERE rowid IN (SELECT rowid ... MATCH ? LIMIT @cap) ORDER BY bm25(...)</c>
    /// 实现「候选集上限」。FTS5 的 <c>bm25()</c> **只在含 MATCH 的查询块内求值**，
    /// 该写法的外层查询不匹配 → 每行分数恒为 <c>0</c>，排序退化成 rowid 顺序，
    /// **不报错也不抛异常**，等于相关性排序整体失效（默认 cap=5000 时对所有查询生效）。
    ///
    /// 本用例用「文档相关度差异明显」的语料断言**顺序**（而非仅命中集合），
    /// 一旦有人重新引入同类写法，分数会退化为相同值、顺序断言立刻失败。
    /// </summary>
    private static void RankingIntegrity()
    {
        var root = Path.Combine(
            Path.GetTempPath(), "archoera-ranking-" + Guid.NewGuid().ToString("N"));
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
                // 三首歌的区别只在「标题命中」vs「仅歌词命中」的次数，便于用 bm25 列权重
                // 拉开差距：标题命中（权重 4.0）应稳定排在仅歌词命中（1.5）之前。
                EndToEnd.InsertTrack(conn, "title", Path.Combine(media, "t.mp3"), "晴天",
                    """[{"name":"A"}]""", null, null, 1000);
                EndToEnd.InsertTrack(conn, "lyrics", Path.Combine(media, "l.mp3"), "别的名字",
                    """[{"name":"B"}]""", null, "晴天", 2000);
                EndToEnd.InsertTrack(conn, "both", Path.Combine(media, "b.mp3"), "晴天",
                    """[{"name":"C"}]""", null, "晴天 晴天 晴天", 3000);
            }
            EndToEnd.RunEngine(db, index, full: true, lrc: false);
            SearchSession.CloseCached();

            using var store = new FtsStore();
            store.OpenReadOnly(index);

            // 直查 FtsStore：分数的**区分度**是排序有效性的直接证据。
            var expression = SearchQuery.CompileMatch(Analyzer.AnalyzeQuery("晴天"), metadata: false);
            Program.Check("排序完整性: 表达式可编译", expression is not null, expression ?? "<null>");
            var rows = store.Search(expression!, limit: 100, offset: 0,
                candidateCap: FtsStore.DefaultCandidateCap);
            Program.Check("排序完整性: 命中 3 首", rows.Count == 3, rows.Count.ToString());

            var distinct = rows.Select(r => Math.Round(r.Score, 6)).Distinct().Count();
            Program.Check(
                "排序完整性: bm25 分数有区分度（退化时全为 0）",
                distinct > 1,
                $"不同分值 {distinct} 个：" + string.Join(',', rows.Select(r => r.Score.ToString("F4"))));

            // 顺序：标题命中（权重更高）必须排在仅歌词命中之前。
            var trackIds = store.ResolveTrackIds(rows.Select(r => r.DocId).ToList());
            var order = rows.Select(r => trackIds[r.DocId]).ToList();
            var titleRank = order.IndexOf("title");
            var lyricsRank = order.IndexOf("lyrics");
            Program.Check(
                "排序完整性: 标题命中排在仅歌词命中之前",
                titleRank >= 0 && lyricsRank >= 0 && titleRank < lyricsRank,
                "顺序=" + string.Join(',', order));

            // candidateCap 不应改变结果（该参数保留仅为 ABI 兼容）。
            var capped = store.Search(expression!, limit: 100, offset: 0, candidateCap: 500);
            var cappedIds = store.ResolveTrackIds(capped.Select(r => r.DocId).ToList());
            Program.Check(
                "排序完整性: candidateCap 不再裁剪候选（结果一致）",
                capped.Select(r => cappedIds[r.DocId]).SequenceEqual(order),
                string.Join(',', capped.Select(r => cappedIds[r.DocId])));
        }
        finally
        {
            SearchSession.CloseCached();
            EndToEnd.TryDelete(root);
        }
    }

    private static string Dump(SearchResult result)
        => "[" + string.Join(',', result.Items.Select(hit => hit.TrackId))
            + $"] pinyin={result.Passes.PinyinLoose} reading={result.Passes.Reading}"
            + $" cross={result.Passes.CrossLingual} fuzzy={result.Passes.Fuzzy}"
            + $" cjk={result.Passes.CjkFuzzy}";
}
