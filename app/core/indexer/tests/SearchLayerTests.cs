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
        RecallPrecisionGates();
    }

    /* ------------------------------------------------------------------ */
    /* 召回精度门控（精度审计 §8.1 负例集）                                */
    /* ------------------------------------------------------------------ */

    /// <summary>
    /// 针对「库内无可匹配媒体却返回一堆无关结果」的**负例集**（见
    /// <c>docs/local-search-recall-precision-audit.md</c> §8.1）。
    ///
    /// 这些都是「不该命中」的断言，与 qbench 的召回评测互补——后者只衡量
    /// 「该找到的找到没」，测不出误召回。
    /// </summary>
    private static void RecallPrecisionGates()
    {
        var root = Path.Combine(
            Path.GetTempPath(), "archoera-recall-gates-" + Guid.NewGuid().ToString("N"));
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
                // 反例曲：**完全不含「爱」**，但歌词含整行单字「啊」（首字母 a 的燃料）、
                // 歌手/标题分别以 h / t 开头（单字母首字母的燃料）。
                EndToEnd.InsertTrack(conn, "hate", Path.Combine(media, "h1.mp3"), "恨",
                    """[{"name":"某人"}]""", "专辑", "我恨你\n啊", 1000);
                // 单字标题：会产出单字母首字母 token（A）。
                EndToEnd.InsertTrack(conn, "single", Path.Combine(media, "a.mp3"), "A",
                    """[{"name":"Band"}]""", null, null, 2000);
                // 英文反例：歌词含 love / like（跨语言候选的目标），但标题不含中文。
                EndToEnd.InsertTrack(conn, "en", Path.Combine(media, "en.mp3"), "Someone Like You",
                    """[{"name":"Adele"}]""", null, "I heard that you're settled down, love is all", 3000);
                // 正例：标题真含「爱」。
                EndToEnd.InsertTrack(conn, "love", Path.Combine(media, "love.mp3"), "爱",
                    """[{"name":"邓丽君"}]""", null, "我爱你", 4000);
                // 正例：四字标题（拼音 / 首字母检索应在门控后仍可用）。
                EndToEnd.InsertTrack(conn, "sky", Path.Combine(media, "sky.mp3"), "晴天",
                    """[{"name":"周杰伦"}]""", null, null, 5000);
            }
            EndToEnd.RunEngine(db, index, full: true, lrc: false);
            SearchSession.CloseCached();

            // 负例 1（M-1）：单字查询不得因首字母支而命中单字母 token 的歌。
            // 修前：「爱」的首字母支是精确 `"a"`，命中标题 A / 歌词整行「啊」→ 整库。
            var ai = Run(index, "爱", fuzzy: true);
            Program.Check("负例: 单字查询不命中单字母首字母 token",
                !Has(ai, "single"), Dump(ai));
            Program.Check("负例: 单字查询不命中「恨」那首",
                !Has(ai, "hate"), Dump(ai));
            Program.Check("负例: 单字查询仍命中真含该字的歌",
                Has(ai, "love"), Dump(ai));

            // 负例 2（M-5）：单字汉字不走英文释义方向。
            Program.Check("负例: 单字查询不命中英文 love 歌",
                !Has(ai, "en") && ai.Passes.CrossLingual == 0, Dump(ai));

            // 负例 3：单字「痛」（库内完全没有）必须返回空。
            var pain = Run(index, "痛", fuzzy: true);
            Program.Check("负例: 库内无匹配的单字查询返回空",
                pain.Items.Count == 0, Dump(pain));

            // ---------------------------------------------------------------
            // v14 分词：CJK 段不给中间字建 unigram（精度审计 §17）
            //
            // 「爱」在 t1 的歌词「我爱你」里处于**中间位置**，索引中只有 bigram
            // `我爱` / `爱你` 与首尾 unigram `我` / `你`；它本身没有 unigram。
            // 单字查询必须走前缀 `"爱"*` 才能命中（命中以「爱」开头的 bigram）。
            // 这里直接验证编译产物，确保没有退化成精确匹配。
            // ---------------------------------------------------------------
            var singleMatch = SearchQuery.CompileMatch(Analyzer.AnalyzeQuery("爱"), metadata: false);
            Program.Check("分词: 单字 CJK 查询编译为前缀形式",
                singleMatch is not null
                && singleMatch.Contains("\"爱\"*")
                && !singleMatch.Contains("\"爱\" AND")
                && !singleMatch.EndsWith("\"爱\")"),
                singleMatch ?? "<null>");

            // 正例：中间字仍可被召回（title 里「爱」在 t1 标题「晴天」不存在，
            // 故这里用歌手 / 标题真含「爱」的曲目验证前缀可达）。
            var midChar = Run(index, "爱", fuzzy: true);
            Program.Check("正例: 单字前缀仍能召回",
                midChar.Items.Count > 0, Dump(midChar));

            // 丢词方向（精度审计 §22）：多词查询主趟不足时，先丢**首位**词（歌手），
            // 保留尾部的歌名。见下方的编译层断言与端到端断言。
            //
            // 负例：单词查询**不得**触发丢词（丢到 0 个词等于返回任意结果）。
            var single = Run(index, "晴天", fuzzy: true);
            Program.Check("负例: 单词查询不触发丢词趟",
                single.Passes.DropTokens == 0, Dump(single));

            // 正例：末词库内不存在时，丢掉末词后仍能命中前一词。
            var dropped = Run(index, "晴天 zzz不存在的词", fuzzy: true);
            Program.Check("正例: 多词查询走丢词趟",
                dropped.Passes.DropTokens == 1, Dump(dropped));
            Program.Check("正例: 丢词后命中前一词的歌",
                Has(dropped, "sky"), Dump(dropped));

            // 负例：丢词只按「词」为单位，不拆 CJK 词内部。
            var keptWhole = SearchQuery.CompileDropTokens(
                Analyzer.AnalyzeQuery("月亮代表我的心"), "月亮代表我的心", metadata: false);
            Program.Check("负例: 单个 CJK 词不触发丢词",
                keptWhole is null, keptWhole ?? "<null>");

            // 关键正例（精度审计 §22）：中文「歌手 歌名」查询必须能命中歌名那首。
            // 本库 t1 = 歌名「晴天」/ 歌手「周杰伦」，故查「周杰伦 晴天」应命中 t1。
            // 无论走主趟还是丢词趟，**结果都必须包含歌名对应的曲目**——
            // 这是「保留歌名」这一语义的可观察断言。
            var singerTitle = Run(index, "周杰伦 晴天", fuzzy: true);
            Program.Check("正例: 歌手+歌名查询能命中歌名曲目",
                Has(singerTitle, "sky"), Dump(singerTitle));

            // 正例保护：两字以上首字母检索仍可用（qt → 晴天）。
            var qt = Run(index, "qt", fuzzy: true);
            Program.Check("正例: 双字母首字母检索仍命中", Has(qt, "sky"), Dump(qt));

            // 正例保护：拼音检索仍可用（qingtian → 晴天）。
            var pinyin = Run(index, "qingtian", fuzzy: true);
            Program.Check("正例: 全拼检索仍命中", Has(pinyin, "sky"), Dump(pinyin));

            // 负例 4（M-3）：两字查询不得走 CJK 容错（删一字必然退化为单字）。
            // 「爱情」在库内不存在；修前 CJK 容错会删掉一个字 → 退化成「爱」/「情」的
            // 完整单字查询（连拼音与首字母支一并带上）。
            // 注意：≥2 字的**跨语言**释义是刻意保留的（「爱情」→ love 命中「爱」那首
            // 属合理语义相邻），故此处只断言 CJK 容错趟未执行。
            var loveWord = Run(index, "爱情", fuzzy: true);
            Program.Check("负例: 两字查询不启用 CJK 容错趟",
                loveWord.Passes.CjkFuzzy == 0, Dump(loveWord));

            // 正例保护：三字以上的容错仍然生效（周杰美 → 周杰伦 的同类场景由
            // ProgressiveQuery 覆盖；此处只断言门控没有误伤三字变体生成）。
            Program.Check("正例: 三字仍生成容错变体",
                SearchQuery.CjkVariants("月亮代").Count > 0);

            // ---------------------------------------------------------------
            // 读音支脚本分流（精度审计 §12 / §13）
            //
            // 核心负例：单字 CJK 输入的拼音是**派生**的，与检索意图无关。
            // 修前「鬱 → yu」字面 0 命中却返回 17,955 条（真实库，占全库 36.8%），
            // 因为主趟是 词法 OR 拼音 OR 首字母 的平级组合。
            // ---------------------------------------------------------------

            // 负例 5：单字 CJK 查询**不得**生成拼音支 / 首字母支。
            // 注意：主趟现在会被限定到元数据列，而元数据列集合**本身包含**
            // pinyin_meta_tok / initials_meta_tok，所以不能靠「表达式里有没有这些列名」
            // 判断；改为直接断言分支未生成（编译结果不应含拼音音节字面量）。
            var yuTokens = Analyzer.AnalyzeQuery("郁");
            Program.Check("门控: 单字 CJK 标记 HasCjk",
                yuTokens.HasCjk, "HasCjk=" + yuTokens.HasCjk);
            var yuMatch = SearchQuery.CompileMatch(yuTokens, metadata: false);
            Program.Check("负例: 单字 CJK 主趟不含拼音支",
                yuMatch is not null && !yuMatch.Contains("\"yu\""), yuMatch ?? "<null>");
            Program.Check("负例: 单字 CJK 主趟不含首字母支",
                yuMatch is not null && !yuMatch.Contains("\"y\"*"), yuMatch ?? "<null>");
            // 单字 CJK 查询必须限定到**可见文本列**（歌名 / 歌手 / 专辑 / 文件名），
            // 既不扫歌词，也不扫拼音 / 首字母等派生转写列（精度审计 §15）。
            Program.Check("负例: 单字 CJK 主趟限定可见文本列",
                yuMatch is not null
                && yuMatch.Contains("{" + SearchQuery.VisibleTextColumns + "}")
                && !yuMatch.Contains("lyrics_tok")
                && !yuMatch.Contains("pinyin_meta_tok"),
                yuMatch ?? "<null>");

            // 正例：拉丁单字保留首字母列（真实的首字母检索，日志里有 17 个这类查询），
            // 但排除拼音列（单字母在拼音列毫无区分力）。
            var latinSingleMatch = SearchQuery.CompileMatch(
                Analyzer.AnalyzeQuery("z"), metadata: false);
            Program.Check("正例: 拉丁单字保留首字母列",
                latinSingleMatch is not null && latinSingleMatch.Contains("initials_meta_tok"),
                latinSingleMatch ?? "<null>");
            Program.Check("负例: 拉丁单字排除拼音列",
                latinSingleMatch is not null && !latinSingleMatch.Contains("pinyin_meta_tok"),
                latinSingleMatch ?? "<null>");

            // 正例：拉丁输入**必须**保留读音支（用户明确用拼音找中文歌）。
            // 反例保护：`qingtian` 字面 0 命中但属合法检索，若被拦会误伤。
            var latinTokens = Analyzer.AnalyzeQuery("qingtian");
            Program.Check("门控: 拉丁输入不标记 HasCjk",
                !latinTokens.HasCjk, "HasCjk=" + latinTokens.HasCjk);
            var latinMatch = SearchQuery.CompileMatch(latinTokens, metadata: false);
            Program.Check("正例: 拉丁输入保留拼音支",
                latinMatch is not null && latinMatch.Contains("pinyin_meta_tok"), latinMatch ?? "<null>");

            // 正例：两字以上的 CJK 查询仍保留读音支（多音节串组合更独特）。
            var multiTokens = Analyzer.AnalyzeQuery("周杰伦");
            var multiMatch = SearchQuery.CompileMatch(multiTokens, metadata: false);
            Program.Check("正例: 多字 CJK 保留拼音支",
                multiMatch is not null && multiMatch.Contains("pinyin_meta_tok"), multiMatch ?? "<null>");

            // 端到端：生僻字在库内完全不存在 → 必须返回空（不受读音支放大）。
            var rare = Run(index, "龗", fuzzy: true);
            Program.Check("负例: 生僻字不因读音支放大召回",
                rare.Items.Count == 0, Dump(rare));

            // ---------------------------------------------------------------
            // 单字查询列门控（精度审计 §11.5 P0 / §14）
            //
            // 单字查询限定到元数据列后**不得**再靠歌词命中召回。
            // 本段库里 "hate" 标题「恨」、歌词「我恨你 / 啊」；
            // "love" 标题「爱」、歌词「我爱你」。
            // 搜「爱」应命中 love（标题），不得命中 hate（歌词不含爱，本来就无关）。
            // 更强的负例：搜「恨」——hate 的标题确实含「恨」，属正例；
            // 故这里改为断言「单字查询不因歌词列而扩大召回」：
            // 搜「你」在库内只出现在歌词里（"我恨你" / "我爱你"），
            // 限定元数据列后应返回空。
            // ---------------------------------------------------------------
            var singleNi = Run(index, "你", fuzzy: true);
            Program.Check("负例: 单字查询不靠歌词命中召回",
                singleNi.Items.Count == 0, Dump(singleNi));
            Program.Check("正例: 单字查询仍命中标题含该字的歌",
                Has(Run(index, "爱", fuzzy: true), "love"), Dump(Run(index, "爱", fuzzy: true)));
        }
        finally
        {
            SearchSession.CloseCached();
            EndToEnd.TryDelete(root);
        }
    }

    /* ------------------------------------------------------------------ */
    /* 编译黄金向量                                                        */
    /* ------------------------------------------------------------------ */

    private static void CompilerGolden()
    {
        var tokens = Analyzer.AnalyzeQuery("我爱你");
        // 末词前缀改为 (exact OR prefix) 分层（精度审计 §16），命中集合不变、排序更准。
        // v14：CJK 段不再给中间字建 unigram，故 tokens 里没有「爱」；
        // 末词「你」是单个 CJK 字，走前缀 `("你" OR "你"*)`。
        const string expected = "(\"我爱 爱你\" AND (\"我\" OR \"我\"*) AND (\"你\" OR \"你\"*)"
            + " OR {pinyin_meta_tok pinyin_lyrics_tok} : \"wo ai ni\""
            + " OR ({initials_meta_tok initials_lyrics_tok} : (\"wan\" OR \"wan\"*)))";
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

        // 丢词方向（精度审计 §22）：中文「歌手 + 歌名」查询应优先丢**首位**（歌手），
        // 因为歌名在尾部且是最该保留的部分；纯拉丁查询沿用 Meilisearch `Last`（先丢尾）。
        var cjkDropOrder = SearchQuery.DropTokenCandidates(
            Analyzer.AnalyzeQuery("周杰伦 晴天"), "周杰伦 晴天");
        Program.Check("丢词方向: 中文查询优先丢首位（保留歌名）",
            cjkDropOrder.Count == 2 && cjkDropOrder[0] == 0,
            string.Join(',', cjkDropOrder));
        var latinDropOrder = SearchQuery.DropTokenCandidates(
            Analyzer.AnalyzeQuery("love story"), "love story");
        Program.Check("丢词方向: 拉丁查询沿用从尾丢",
            latinDropOrder.Count == 2 && latinDropOrder[0] == 1,
            string.Join(',', latinDropOrder));
        // 方向差异的可观察证明（§22 的核心）：
        //   丢首位 → 只剩歌名（精确，返回那首歌）
        //   丢末位 → 只剩歌手（宽泛，返回该歌手所有歌）—— 这正是旧行为的缺陷
        var keepSinger = SearchQuery.CompileDropTokens(
            Analyzer.AnalyzeQuery("周杰伦 晴天"), "周杰伦 晴天", false, 1);
        Program.Check("丢词方向: 丢末位会退化为「只用歌手」检索",
            keepSinger is not null
                && keepSinger.Contains("杰伦", StringComparison.Ordinal)
                && !keepSinger.Contains("晴天", StringComparison.Ordinal),
            keepSinger ?? "<null>");
        // 按字段亲和度重排（§23）：title 命中多的词更像歌名，应**最后**才丢。
        //
        // 「晴天 周杰伦」（反向写法）：晴天 title 22 / artist 1，周杰伦 0/0。
        // 位置顺序会先丢索引 0（晴天 = 歌名，错）；亲和度应把晴天排到最后。
        var reordered = SearchQuery.OrderDropsByFieldAffinity(
            new[] { 0, 1 }, new[] { 22, 0 }, new[] { 1, 0 });
        Program.Check("字段亲和度: 反向写法仍保留歌名",
            reordered.Count == 2 && reordered[0] == 1,
            string.Join(',', reordered));

        // 「周杰伦 晴天」（正序）：候选 0,1，周杰伦 0/0、晴天 22/1 → 仍先丢 0。
        var forward = SearchQuery.OrderDropsByFieldAffinity(
            new[] { 0, 1 }, new[] { 0, 22 }, new[] { 0, 1 });
        Program.Check("字段亲和度: 正序写法先丢歌手",
            forward.Count == 2 && forward[0] == 0,
            string.Join(',', forward));

        // 信息不足（两词都 0/0）时保持原候选顺序，不瞎猜。
        var unknown = SearchQuery.OrderDropsByFieldAffinity(
            new[] { 0, 1 }, new[] { 0, 0 }, new[] { 0, 0 });
        Program.Check("字段亲和度: 无信号时保持位置顺序",
            unknown.Count == 2 && unknown[0] == 0 && unknown[1] == 1,
            string.Join(',', unknown));

        // 丢掉首位「周杰伦」后，表达式必须**只**约束「晴天」。
        var keepTitle = SearchQuery.CompileDropTokens(
            Analyzer.AnalyzeQuery("周杰伦 晴天"), "周杰伦 晴天", false, 0);
        Program.Check("丢词方向: 丢首位后保留歌名词",
            keepTitle is not null
                && keepTitle.Contains("\"晴天\"", StringComparison.Ordinal)
                && !keepTitle.Contains("\"周杰\"", StringComparison.Ordinal),
            keepTitle ?? "<null>");

        // 变体总预算（精度审计 §20）：多词多音节输入不得组合爆炸。
        // `shanghai` 单次产出 4 × 2 = 8 个变体；两段共 16，正好卡在预算边界。
        // 追加第三段后若无预算约束会到 24，有预算则应被压住。
        var budgeted = SearchQuery.CompilePinyinLoose(
            Analyzer.AnalyzeQuery("shanghai shanghai shanghai"), metadata: false);
        // 变体词数 = 表达式里被引号包住的 term 数。
        var variantTerms = budgeted is null ? 0 : budgeted.Split('"').Length / 2;
        Program.Check("查询编译器: 多音节拼音受变体总预算约束",
            budgeted is not null
                && variantTerms <= SearchQuery.DefaultMaxPinyinVariants
                // 预算 16 时每段被压到 2 个变体（无预算时应各 4 个，共 24）
                && budgeted.Contains("(\"shang\" OR \"sang\")", StringComparison.Ordinal),
            $"变体词 {variantTerms} 个（预算 {SearchQuery.DefaultMaxPinyinVariants}）：{budgeted}");
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

        // 首字符错误算 2 错（精度审计 §21）：`night` 的首字母 n 的替换候选是 m，
        // 旧行为会产出 "might"（首字符不同的 1-错变体）。
        var firstChar = SearchQuery.CompileFuzzy(Analyzer.AnalyzeQuery("night"), metadata: false);
        Program.Check("查询编译器: 首字符替换变体不生成（首错算 2 错）",
            firstChar is not null
                && !firstChar.Contains("\"might\"", StringComparison.Ordinal)
                && !firstChar.Contains("\"night\" OR \"might\"", StringComparison.Ordinal),
            firstChar ?? "<null>");
        // 删除 / 换位不改变首字符，必须保留。
        Program.Check("查询编译器: 首字符无关的变体仍保留",
            firstChar is not null
                && firstChar.Contains("\"nigh\"", StringComparison.Ordinal)   // 删除末字
                && firstChar.Contains("\"nigth\"", StringComparison.Ordinal), // 相邻换位
            firstChar ?? "<null>");

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
        // 末词元 ≥3 字符照常做精确/前缀分层（合法行为），关键是**引号内内容未被撕裂**。
        var injected = SearchQuery.CompileMatch(Tokens(lexical: new[] { "x\" OR \"y" }), metadata: false);
        Program.Check("转义: 注入 OR 被当字面量",
            injected == "(\"x\"\" OR \"\"y\" OR \"x\"\" OR \"\"y\"*)", injected ?? "<null>");
        // 用户输入里的 ` OR ` 必须留在引号内：表达式里**唯一合法的 OR** 是分层引入的那个。
        Program.Check("转义: 注入不产生额外 OR 分支",
            injected is not null && CountUnquotedOr(injected) == 1, injected ?? "<null>");

        // 含引号的「类 bigram」不入短语（仅 1 个 CJK 字符），仍逐字转义。
        var quoted = SearchQuery.CompileMatch(Tokens(lexical: new[] { "我\"", "\"爱" }), metadata: false);
        Program.Check("转义: 含引号类 bigram 不合并成短语",
            quoted == "\"我\"\"\" AND \"\"\"爱\"", quoted ?? "<null>");

        // 首字母串含引号 / 空格：列过滤仍闭合（列过滤前缀不被词元内容带偏）。
        var initials = SearchQuery.CompileMatch(Tokens(initials: "a\"b"), metadata: false);
        Program.Check("转义: 首字母含引号仍闭合列过滤",
            initials == "({initials_meta_tok initials_lyrics_tok} : (\"a\"\"b\" OR \"a\"\"b\"*))",
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
        // 三字起仍生成变体（删一字 / 相邻换位，去重保序）。
        Program.Check("中文变体: 三字 周杰美 → 删除×3 + 换位×2",
            Join(SearchQuery.CjkVariants("周杰美")) == "杰美,周美,周杰,杰周美,周美杰",
            Join(SearchQuery.CjkVariants("周杰美")));
        Program.Check("中文变体: 相同字相邻换位去重",
            !SearchQuery.CjkVariants("一一一").Contains("一一一"),
            Join(SearchQuery.CjkVariants("一一一")));
        Program.Check("中文变体: 单字不生成",
            SearchQuery.CjkVariants("我").Count == 0);
        // 门控（精度审计 §2.5）：两字查询删一字必然退化成单字，等于把两字查询放大成
        // 两次单字查询（合成库实测「想你」返回 130 条）。故 <3 字一律不生成变体。
        Program.Check("中文变体: 两字不生成（防退化为单字）",
            SearchQuery.CjkVariants("周伦").Count == 0
                && SearchQuery.CjkVariants("想你").Count == 0);
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
            // 注意：用**两字查询**验证翻页——单字查询会被限定到元数据列（精度审计 §14），
            // 而本库标题含「爱」的只有 t2 一首，不足以翻页。
            // 「邓丽」是 t2 / t5 共同歌手「邓丽君」的前两字，稳定命中 2 条。
            var page1 = Run(index, "邓丽", limit: 1);
            var page2 = Run(index, "邓丽", limit: 1, offset: 1);
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

            // 反方向保留：**多字**汉字查询仍经英文释义候选命中英文标题。
            var loveWord = Run(index, "恋爱", fuzzy: true);
            Program.Check("语言画像: 多字汉字查询仍跨语言命中英文标题", Has(loveWord, "p1"),
                Dump(loveWord));
            Program.Check("语言画像: 汉字方向跨语言趟执行一次",
                loveWord.Passes.CrossLingual == 1, Dump(loveWord));

            // **单字门控**（精度审计 §2.4 / M-5）：单个汉字不生成英文释义方向。
            // Unihan 对单字释义极度发散（痛 → ache/bitter/pain/sad/sorry），在含大量
            // 英文歌词的库里会把单字查询放大到近乎整库。此处断言：纯拉丁库里搜「爱」
            // 不再命中 Love Me（旧行为会命中）。
            var singleHan = Run(index, "爱", fuzzy: true);
            Program.Check("语言画像: 单字汉字不走跨语言释义",
                !Has(singleHan, "p1") && singleHan.Passes.CrossLingual == 0,
                Dump(singleHan));
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

    /// <summary>
    /// 统计不在双引号内的 <c> OR </c> 出现次数（FTS5 的真实 OR 运算符）。
    /// 用于验证「用户输入里的 OR 被转义成字面量」——转义后它落在引号内，
    /// 只有分层引入的 OR 才算真实运算符。
    /// </summary>
    private static int CountUnquotedOr(string expression)
    {
        var count = 0;
        var inQuote = false;
        for (var i = 0; i < expression.Length; i++)
        {
            if (expression[i] == '"')
            {
                // FTS5 的转义是连续两个引号（""），不切换引号状态。
                if (inQuote && i + 1 < expression.Length && expression[i + 1] == '"')
                {
                    i++;
                    continue;
                }
                inQuote = !inQuote;
                continue;
            }
            if (!inQuote && expression.AsSpan(i).StartsWith(" OR "))
            {
                count++;
            }
        }
        return count;
    }

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
                // 拉开差距：标题命中（权重 4.0）应稳定排在仅歌词命中（0.6）之前。
                EndToEnd.InsertTrack(conn, "title", Path.Combine(media, "t.mp3"), "晴天",
                    """[{"name":"A"}]""", null, null, 1000);
                EndToEnd.InsertTrack(conn, "lyrics", Path.Combine(media, "l.mp3"), "别的名字",
                    """[{"name":"B"}]""", null, "晴天", 2000);
                // 歌词里高频重复（TF 放大）：v15 歌词降权要保证它**不会**压过纯标题命中。
                // 注意标题**不含**「晴天」，否则两处标题命中本身就合理更强。
                EndToEnd.InsertTrack(conn, "both", Path.Combine(media, "b.mp3"), "另一首歌",
                    """[{"name":"C"}]""", null,
                    string.Join(" ", Enumerable.Repeat("晴天", 40)), 3000);
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

            // v15 歌词降权（精度审计 §19）：直接在权重表层面断言，不依赖 bm25 分值。
            //
            // 为什么不在这个小语料上用 bm25 验证顺序：3 篇文档时每列的 IDF 退化，
            // bm25 会返回 0.0（「分数有区分度」断言在真实库才成立），排序退化成 rowid 顺序。
            // 真实权重效果用 48k 首曲库验证（见审计 §19.3）。
            //
            // 断言强度：歌词权重必须**明显低于**最弱的元数据列（album = 2.0），
            // 而不只是「低于 title」——后者在 v15 之前（1.5 < 4.0）也成立，锁定不住改动。
            Program.Check(
                "排序权重: 歌词列权重低于专辑列（v15 降权）",
                FtsStore.WeightOf("lyrics_tok") < FtsStore.WeightOf("album_tok"),
                $"lyrics={FtsStore.WeightOf("lyrics_tok")} album={FtsStore.WeightOf("album_tok")}");
            Program.Check(
                "排序权重: 歌词列权重不超过专辑的一半",
                FtsStore.WeightOf("lyrics_tok") <= FtsStore.WeightOf("album_tok") / 2,
                $"lyrics={FtsStore.WeightOf("lyrics_tok")} album={FtsStore.WeightOf("album_tok")}");
            Program.Check(
                "排序权重: 歌词列仍保有非零可召回权重",
                FtsStore.WeightOf("lyrics_tok") > 0.0,
                $"lyrics={FtsStore.WeightOf("lyrics_tok")}");
            Program.Check(
                "排序权重: 歌词拼音列权重同步降档",
                FtsStore.WeightOf("pinyin_lyrics_tok") <= FtsStore.WeightOf("album_tok") / 2,
                $"pinyin_lyrics={FtsStore.WeightOf("pinyin_lyrics_tok")}");

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
