// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

using System.Text;

namespace Archoera.Indexer.Tests;

/// <summary>
/// 分析器测试运行器（Exe，不用 xUnit）。
///
/// 读取 <c>tests/vectors/*.tsv</c> 逐行断言分析器三列输出
/// （<c>analyzer.tsv</c> → <see cref="Analyzer.Analyze"/>；<c>query*.tsv</c> → <see cref="Analyzer.AnalyzeQuery"/>），
/// 另含若干不依赖 tsv 的纯断言（版本锚点 / IsCjk / 未命中汉字不崩溃 / 查询侧连写全拼切分）。
/// 任一失败返回非 0。
/// </summary>
public static class Program
{
    private static int _pass;
    private static int _fail;

    public static int Main(string[] args)
    {
        var vectorsDir = ResolveVectorsDir(args);
        if (vectorsDir is null)
        {
            Console.Error.WriteLine("找不到测试向量目录 tests/vectors（可用参数指定）。");
            return 1;
        }

        Console.WriteLine($"vectors: {vectorsDir}");

        RunDirectAssertions();
        EndToEnd.Run();

        var vectorFiles = Directory.GetFiles(vectorsDir, "*.tsv");
        Array.Sort(vectorFiles, StringComparer.Ordinal);
        foreach (var file in vectorFiles)
            RunVectorFile(file);

        Console.WriteLine();
        Console.WriteLine($"PASS {_pass}  FAIL {_fail}");
        if (_fail == 0)
        {
            Console.WriteLine("ALL PASS");
            return 0;
        }
        Console.WriteLine("FAILURES");
        return 1;
    }

    private static void RunDirectAssertions()
    {
        Assert("AnalyzerVersion == 6", Analyzer.AnalyzerVersion == 6,
            Analyzer.AnalyzerVersion.ToString());

        // 假名 / 谚文：子串分词（bigram+unigram），**不进拼音 / 首字母列**。
        // 真实曲库实测：旧实现整段一个 token → 子串 `くらりん` ⊂ `きゅうくらりん` 命中 0。
        var kana = Analyzer.Analyze("きゅうくらりん");
        Assert("假名 tokens 含 bigram きゅ/くら/りん",
            kana.Tokens.Contains("きゅ") && kana.Tokens.Contains("くら") && kana.Tokens.Contains("りん"),
            kana.Tokens);
        Assert("假名 pinyin 为空（不再镜像）", kana.Pinyin.Length == 0, kana.Pinyin);
        Assert("假名 initials 为空", kana.PinyinInitials.Length == 0, kana.PinyinInitials);
        var hangul = Analyzer.Analyze("한국어노래");
        Assert("谚文 tokens 含 bigram 한국/노래",
            hangul.Tokens.Contains("한국") && hangul.Tokens.Contains("노래"), hangul.Tokens);
        Assert("谚文 pinyin 为空", hangul.Pinyin.Length == 0, hangul.Pinyin);

        // 日文读音列（v5）：假名 → 罗马字 bigram；纯中文不产出（零体积 / 零噪声）。
        var ja = Analyzer.Analyze("きゅうくらりん");
        foreach (var bg in new[] { "ky", "yu", "uu", "uk", "ku", "ur", "ra", "ar", "ri", "in" })
            Assert($"读音 bigram 含 '{bg}'", ja.Readings.Contains(bg), ja.Readings);
        Assert("纯中文无读音列", Analyzer.Analyze("晴天").Readings.Length == 0,
            Analyzer.Analyze("晴天").Readings);
        // 整首标记为日文时，纯汉字段也查 Unihan 音训读（米津玄師 这类歌手名）
        var kanjiWithJa = Analyzer.Analyze("愛", includeReadings: true);
        Assert("汉字读音（愛 → ai）", kanjiWithJa.Readings.Contains('a'.ToString() + 'i'),
            kanjiWithJa.Readings);
        Assert("未标记时不产出汉字读音", Analyzer.Analyze("愛").Readings.Length == 0);

        // 分层判定：假名行**不是**拉丁（罗马音）行——旧实现会把日文歌词行划进音译层。
        Assert("假名行不算拉丁", !Archoera.Text.ScriptRanges.IsLatinLine("きゅうくらりん"));
        Assert("谚文行不算拉丁", !Archoera.Text.ScriptRanges.IsLatinLine("한국어"));
        Assert("罗马音行算拉丁", Archoera.Text.ScriptRanges.IsLatinLine("yue liang dai biao"));
        Assert("中英混排行不算拉丁", !Archoera.Text.ScriptRanges.IsLatinLine("月亮 love"));

        Assert("IsCjk('我')", Analyzer.IsCjk('我'));
        Assert("!IsCjk('a')", !Analyzer.IsCjk('a'));
        Assert("!IsCjk('1')", !Analyzer.IsCjk('1'));
        Assert("IsCjk 扩展A '㐂'", Analyzer.IsCjk('\u3402'));

        // 扩展 A 汉字（㐂 U+3402）：ToolGood.Words 覆盖 ext-A（旧 pinyin 表未收录，已不再「未命中」）。
        // 保留「不崩溃且输出确定」的检查（改动后主读音为 xi / 首字母 x）。
        var rare = "\u3402";
        var rareResult = Analyzer.Analyze(rare);
        Assert("扩展A汉字 tokens 保留", rareResult.Tokens == rare, rareResult.Tokens);
        Assert("扩展A汉字 pinyin == xi", rareResult.Pinyin == "xi", rareResult.Pinyin);
        Assert("扩展A汉字 initials == x", rareResult.PinyinInitials == "x", rareResult.PinyinInitials);

        // 查询侧结构化结果。
        Assert("AnalyzeQuery initials", Analyzer.AnalyzeQuery("我爱你").PinyinInitials == "wan",
            Analyzer.AnalyzeQuery("我爱你").PinyinInitials);
        Assert("AnalyzeQuery lexical 数", Analyzer.AnalyzeQuery("我爱你").Lexical.Count == 5,
            Analyzer.AnalyzeQuery("我爱你").Lexical.Count.ToString());
        Assert("AnalyzeQuery pinyin", string.Join(' ', Analyzer.AnalyzeQuery("我爱你").Pinyin) == "wo ai ni");
        Assert("AnalyzeQuery 无 CJK → initials null", Analyzer.AnalyzeQuery("hello").PinyinInitials is null);

        // P4 查询侧连写全拼切分（设计文档 §4.2）：woaini → wo ai ni
        Assert("AnalyzeQuery 连写 woaini", Pinyin(Analyzer.AnalyzeQuery("woaini")) == "wo ai ni",
            Pinyin(Analyzer.AnalyzeQuery("woaini")));
        Assert("AnalyzeQuery 连写 woai", Pinyin(Analyzer.AnalyzeQuery("woai")) == "wo ai",
            Pinyin(Analyzer.AnalyzeQuery("woai")));
        Assert("AnalyzeQuery 连写 zhaoliying", Pinyin(Analyzer.AnalyzeQuery("zhaoliying")) == "zhao li ying",
            Pinyin(Analyzer.AnalyzeQuery("zhaoliying")));
        Assert("AnalyzeQuery 连写 xiaoai", Pinyin(Analyzer.AnalyzeQuery("xiaoai")) == "xiao ai",
            Pinyin(Analyzer.AnalyzeQuery("xiaoai")));
        Assert("AnalyzeQuery 连写 wanzg 不误切", Pinyin(Analyzer.AnalyzeQuery("wanzg")) == "wanzg",
            Pinyin(Analyzer.AnalyzeQuery("wanzg")));
        Assert("AnalyzeQuery 英文 hello 不切分", Pinyin(Analyzer.AnalyzeQuery("hello")) == "hello",
            Pinyin(Analyzer.AnalyzeQuery("hello")));
        // 英文过度切分门控（P4 修复）：最长优先结果含单字母音节 → 整体拒绝。
        Assert("AnalyzeQuery 英文 banana 不切分", Pinyin(Analyzer.AnalyzeQuery("banana")) == "banana",
            Pinyin(Analyzer.AnalyzeQuery("banana")));
        Assert("AnalyzeQuery 英文 adele 不切分", Pinyin(Analyzer.AnalyzeQuery("adele")) == "adele",
            Pinyin(Analyzer.AnalyzeQuery("adele")));
        Assert("AnalyzeQuery 英文 rodeo 不切分", Pinyin(Analyzer.AnalyzeQuery("rodeo")) == "rodeo",
            Pinyin(Analyzer.AnalyzeQuery("rodeo")));
        // 末音节单字母被门控拒绝（旧行为 wo a）。
        Assert("AnalyzeQuery woa 单字母音节不切分", Pinyin(Analyzer.AnalyzeQuery("woa")) == "woa",
            Pinyin(Analyzer.AnalyzeQuery("woa")));
        Assert("AnalyzeQuery wan 单音节不误切", Pinyin(Analyzer.AnalyzeQuery("wan")) == "wan",
            Pinyin(Analyzer.AnalyzeQuery("wan")));
        Assert("AnalyzeQuery 带空格 'wo ai ni' 不变", Pinyin(Analyzer.AnalyzeQuery("wo ai ni")) == "wo ai ni",
            Pinyin(Analyzer.AnalyzeQuery("wo ai ni")));
        Assert("AnalyzeQuery 连写 lexical 仍是整词", string.Join(' ', Analyzer.AnalyzeQuery("woaini").Lexical) == "woaini",
            string.Join(' ', Analyzer.AnalyzeQuery("woaini").Lexical));
        // 索引侧 Analyze 词元输出不变（连写不切分）；v4 的版本递增来自拼音/繁简改走 ToolGood。
        Assert("Analyze 索引侧 woaini 不切分", Analyzer.Analyze("woaini").Pinyin == "woaini",
            Analyzer.Analyze("woaini").Pinyin);

                // ---- 词级多音字消歧（v4，ToolGood.Words）----
        Assert("多音字 重庆 → chong qing", Analyzer.Analyze("重庆").Pinyin == "chong qing",
            Analyzer.Analyze("重庆").Pinyin);
        Assert("多音字 重庆 initials cq", Analyzer.Analyze("重庆").PinyinInitials == "cq",
            Analyzer.Analyze("重庆").PinyinInitials);
        Assert("多音字 银行 → yin hang", Analyzer.Analyze("银行").Pinyin == "yin hang",
            Analyzer.Analyze("银行").Pinyin);
        Assert("多音字 一行 → yi xing", Analyzer.Analyze("一行").Pinyin == "yi xing",
            Analyzer.Analyze("一行").Pinyin);
        Assert("多音字 单田芳 → dan tian fang", Analyzer.Analyze("单田芳").Pinyin == "dan tian fang",
            Analyzer.Analyze("单田芳").Pinyin);
        Assert("拼音 ü → v（女 → nv）", Analyzer.Analyze("女").Pinyin == "nv",
            Analyzer.Analyze("女").Pinyin);
        // 切分确定性：同输入重复调用结果一致。
        Assert("AnalyzeQuery 切分确定性", Pinyin(Analyzer.AnalyzeQuery("woaini")) == Pinyin(Analyzer.AnalyzeQuery("woaini")));

        // ---- NFKC 逐字符兼容折叠（v2） ----
        Assert("NFKC: ﬁ → fi", Analyzer.Analyze("\uFB01").Tokens == "fi", Analyzer.Analyze("\uFB01").Tokens);
        Assert("NFKC: ① → 1", Analyzer.Analyze("\u2460").Tokens == "1", Analyzer.Analyze("\u2460").Tokens);
        Assert("NFKC: Ⅻ → xii", Analyzer.Analyze("\u216B").Tokens == "xii", Analyzer.Analyze("\u216B").Tokens);
        Assert("NFKC: ＡＢＣ → abc", Analyzer.Analyze("\uFF21\uFF22\uFF23").Tokens == "abc",
            Analyzer.Analyze("\uFF21\uFF22\uFF23").Tokens);
        Assert("NFKC: 表意空格 U+3000 → 分隔", Analyzer.Analyze("a\u3000b").Tokens == "a b",
            Analyzer.Analyze("a\u3000b").Tokens);
        // 兼容表意字：U+FA12（晴）→ U+6674（晴）；U+F900（豈）→ NFKC → U+8C48 → 繁转简 → 岂
        Assert("NFKC: 相容表意字 U+FA12 → 晴", Analyzer.Analyze("\uFA12").Tokens == "晴",
            Analyzer.Analyze("\uFA12").Tokens);
        Assert("NFKC: 相容表意字 U+FA12 拼音 qing", Analyzer.Analyze("\uFA12").Pinyin == "qing",
            Analyzer.Analyze("\uFA12").Pinyin);
        Assert("NFKC+繁简: U+F900 → 岂", Analyzer.Analyze("\uF900").Tokens == "岂",
            Analyzer.Analyze("\uF900").Tokens);
        // 查询侧同构：ﬁ 折叠后与 fi 命中同一词元。
        Assert("NFKC 查询侧同构: ﬁ == fi",
            string.Join(' ', Analyzer.AnalyzeQuery("\uFB01").Lexical)
                == string.Join(' ', Analyzer.AnalyzeQuery("fi").Lexical));

        // ---- NFKC 全范围折叠（v3）：非 BMP / 星平面兼容字符 ----
        Assert("NFKC 非BMP: 𝑨(U+1D400) → a", Analyzer.Analyze("\U0001D400").Tokens == "a",
            Analyzer.Analyze("\U0001D400").Tokens);
        Assert("NFKC 非BMP: 𝗔(U+1D5D4) → a", Analyzer.Analyze("\U0001D5D4").Tokens == "a",
            Analyzer.Analyze("\U0001D5D4").Tokens);
        Assert("NFKC 非BMP: 𝟎(U+1D7CE) → 0", Analyzer.Analyze("\U0001D7CE").Tokens == "0",
            Analyzer.Analyze("\U0001D7CE").Tokens);
        Assert("NFKC 非BMP: 𝟏𝟐 → 12", Analyzer.Analyze("\U0001D7CF\U0001D7D0").Tokens == "12",
            Analyzer.Analyze("\U0001D7CF\U0001D7D0").Tokens);
        Assert("NFKC 非BMP 查询侧同构: 𝑨 == a",
            string.Join(' ', Analyzer.AnalyzeQuery("\U0001D400").Lexical)
                == string.Join(' ', Analyzer.AnalyzeQuery("a").Lexical),
            string.Join(' ', Analyzer.AnalyzeQuery("\U0001D400").Lexical));
        // 非法 UTF-16（孤立代理）不崩溃：EnumerateRunes 以 U+FFFD 替代，整串折叠为空词元。
        Assert("NFKC 孤立代理不崩溃", Analyzer.Analyze("\uD83D").Tokens.Length == 0,
            Analyzer.Analyze("\uD83D").Tokens);

        // ---- 英文过度切分门控（v4：已删除 data/en_blocklist.tsv 英文残留阻断表）----
        // 短同形词按取舍不拦截（长度 <6，与 mama(妈妈)/women(我们) 无法区分）。
        Assert("短同形: panda → pan da（不拦截）", Pinyin(Analyzer.AnalyzeQuery("panda")) == "pan da",
            Pinyin(Analyzer.AnalyzeQuery("panda")));
        Assert("短同形: women → wo men（不拦截）", Pinyin(Analyzer.AnalyzeQuery("women")) == "wo men",
            Pinyin(Analyzer.AnalyzeQuery("women")));
        Assert("短同形: mama → ma ma（不拦截）", Pinyin(Analyzer.AnalyzeQuery("mama")) == "ma ma",
            Pinyin(Analyzer.AnalyzeQuery("mama")));
        // 删除阻断表后的已知取舍：长度 ≥6 的英文词不再被拦截，会按音节切分。
        Assert("无阻断表: aiding → ai ding", Pinyin(Analyzer.AnalyzeQuery("aiding")) == "ai ding",
            Pinyin(Analyzer.AnalyzeQuery("aiding")));
        Assert("无阻断表: shanghai → shang hai", Pinyin(Analyzer.AnalyzeQuery("shanghai")) == "shang hai",
            Pinyin(Analyzer.AnalyzeQuery("shanghai")));
        // 真·连写全拼不受影响。
        Assert("连写全拼 zhaoliying 仍切分", Pinyin(Analyzer.AnalyzeQuery("zhaoliying")) == "zhao li ying",
            Pinyin(Analyzer.AnalyzeQuery("zhaoliying")));

        // 内嵌数据表可加载且非空。
        Assert("NFKC 表非空", HanziData.CompatibilityEntryCount > 2000,
            HanziData.CompatibilityEntryCount.ToString());

        // ---- Unihan 释义查询扩展表（T1，2000 行级）----
        Assert("释义表 hanzi2en 非空", HanziData.GlossHanziToEnEntryCount > 20000,
            HanziData.GlossHanziToEnEntryCount.ToString());
        Assert("释义 en2hanzi: love 含 爱(7231)",
            HanziData.TryGetGlossHanzi("love", out var loveCodes)
                && loveCodes.Contains(0x7231),
            "miss");
        Assert("释义 hanzi2en: 爱(7231) 含 love",
            HanziData.TryGetGlossWords(0x7231, out var aiWords)
                && aiWords.Contains("love"),
            "miss");
        Assert("释义 en2hanzi: 未命中返回 false",
            !HanziData.TryGetGlossHanzi("zzzznotaword", out _));

        // ---- 查询侧跨语言候选（T1）----
        var loveQuery = Analyzer.AnalyzeQuery("love");
        Assert("AnalyzeQuery('love') CrossLingual 含 爱",
            loveQuery.CrossLingual.Contains("爱"), string.Join('|', loveQuery.CrossLingual));
        var aiQuery = Analyzer.AnalyzeQuery("爱");
        Assert("AnalyzeQuery('爱') CrossLingual 含 love",
            aiQuery.CrossLingual.Contains("love"), string.Join('|', aiQuery.CrossLingual));
        // 索引侧不改：Analyze 不受释义扩展影响（同词元输出），且无 CrossLingual 概念。
        Assert("索引侧 Analyze('love') 无跨语言副作用",
            Analyzer.Analyze("love").Tokens == "love", Analyzer.Analyze("love").Tokens);
        // 预算：长查询候选不超过 CrossLingualBudget。
        var many = Analyzer.AnalyzeQuery("love like hate big small new old good bad");
        Assert("CrossLingual 预算 ≤ 32", many.CrossLingual.Count <= Analyzer.CrossLingualBudget,
            many.CrossLingual.Count.ToString());
    }

    private static void RunVectorFile(string path)
    {
        Console.WriteLine($"-- {Path.GetFileName(path)}");
        var fileName = Path.GetFileName(path);
        // `query*.tsv` 走查询侧（AnalyzeQuery，含连写全拼切分）；其余走索引侧（Analyze）。
        var querySide = fileName.StartsWith("query", StringComparison.Ordinal);
        foreach (var raw in File.ReadAllLines(path, Encoding.UTF8))
        {
            var line = raw.TrimEnd('\r');
            if (line.Length == 0 || line[0] == '#') continue;

            var cols = line.Split('\t');
            var input = cols.Length > 0 ? cols[0] : string.Empty;
            var expectedTokens = cols.Length > 1 ? cols[1] : "*";
            var expectedPinyin = cols.Length > 2 ? cols[2] : "*";
            var expectedInitials = cols.Length > 3 ? cols[3] : "*";

            var label = $"{fileName} [{input}]";
            if (querySide)
            {
                var query = Analyzer.AnalyzeQuery(input);
                Compare($"{label} tokens", string.Join(' ', query.Lexical), expectedTokens);
                Compare($"{label} pinyin", string.Join(' ', query.Pinyin), expectedPinyin);
                Compare($"{label} initials", query.PinyinInitials ?? string.Empty, expectedInitials);
            }
            else
            {
                var result = Analyzer.Analyze(input);
                Compare($"{label} tokens", result.Tokens, expectedTokens);
                Compare($"{label} pinyin", result.Pinyin, expectedPinyin);
                Compare($"{label} initials", result.PinyinInitials, expectedInitials);
            }
        }
    }

    /// <summary>查询侧全拼音节串（空格分隔），供断言复用。</summary>
    private static string Pinyin(QueryTokens query) => string.Join(' ', query.Pinyin);

    private static void Compare(string label, string actual, string expected)
    {
        if (expected == "*" || actual == expected)
        {
            _pass++;
            return;
        }
        _fail++;
        Console.WriteLine($"FAIL {label}");
        Console.WriteLine($"     expected: [{expected}]");
        Console.WriteLine($"     actual  : [{actual}]");
    }

    private static void Assert(string name, bool ok, string? detail = null)
    {
        if (ok)
        {
            _pass++;
            return;
        }
        _fail++;
        Console.WriteLine($"FAIL {name}{(detail is null ? "" : $" ({detail})")}");
    }

    /// <summary>供其它测试文件（EndToEnd）复用的断言入口。</summary>
    public static void Check(string name, bool ok, string? detail = null) => Assert(name, ok, detail);

    /// <summary>定位向量目录：参数 &gt; 输出目录旁 &gt; 向上查找 tests/vectors。</summary>
    private static string? ResolveVectorsDir(string[] args)
    {
        if (args.Length > 0 && Directory.Exists(args[0])) return args[0];

        var beside = Path.Combine(AppContext.BaseDirectory, "vectors");
        if (Directory.Exists(beside)) return beside;

        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null)
        {
            var candidate = Path.Combine(dir.FullName, "vectors");
            if (Directory.Exists(candidate)) return candidate;
            dir = dir.Parent;
        }
        return null;
    }
}
