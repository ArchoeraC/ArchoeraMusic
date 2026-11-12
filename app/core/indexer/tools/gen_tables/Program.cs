// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// 索引器构建期数据表生成（纯 .NET，无 Python / 外部运行时依赖）。
// 在 app/core/indexer 下执行：dotnet run --project tools/gen_tables
//
// 生成两张表（均为 `HEXCODE<TAB>HEXOUT`，`#` 注释头由 HanziData 跳过）：
//
// 1) data/accent_fold.tsv —— 拉丁去音符号折叠（T1-5）
//    `nfkc.tsv` 是逐字符 NFKC（兼容分解 + 规范合成），重音字母（é / ü / ñ / ā …）
//    在 NFKC 后仍是带音符号的同一个字符，不会被折叠。搜索侧需要把
//    「Beyoncé ↔ Beyonce」视为同一串，故用 **NFD 规范分解**取出
//    「ASCII 基字母 + 组合音标」的字符，只保留基字母。
//    只收录「NFD 分解形 = 单个 ASCII 字母 + 若干组合音标」的字符；
//    ł / ø / đ / ß / æ / œ / ð / þ 等无规范分解的字母不在表内（保持原样）。
//    组合音标本身（U+0300–U+036F 等）由运行时直接丢弃，不写入此表。
//
// 2) data/variant_fold.tsv —— 异体字 → 简体补齐（T1-7，主要覆盖日文新字体）
//    来源 `reference/unihan/Unihan.zip` 的 Unihan_Variants.txt：
//      - 直接 `kSimplifiedVariant`（繁 → 简）；
//      - 日文新字体经 `kJapaneseOldVariant`（新字体 → 旧字体）再查 `kSimplifiedVariant`
//        （鉄 → 鐵 → 铁、絵 → 繪 → 绘、円 → 圓 → 圆 …）。
//    **只补 ToolGood.Words 的缺口**：源字符经 `ToSimplifiedChinese` 后若已改变，
//    说明繁简词库已覆盖，不重复写入；未改变（日文新字体多属此类）才入表。
//    这样不会覆盖既有中文繁简规则，只补齐「搜『银河铁道』命中『銀河鉄道の夜』」这一类。
//
// 许可：Unicode 规范分解 / Unihan 变体属性属事实数据（Unicode License）。

using System.Globalization;
using System.IO.Compression;
using System.Text;
using ToolGood.Words;

const string accentOutput = "data/accent_fold.tsv";
const string variantOutput = "data/variant_fold.tsv";
const string unihanZip = "../../../reference/unihan/Unihan.zip";

WriteAccentTable(accentOutput, BuildAccentRows());
WriteVariantTable(variantOutput, BuildVariantRows(unihanZip));

static List<(int CodePoint, char Base)> BuildAccentRows()
{
    // 拉丁字母可能带音符号的码点区段（Basic Latin 无重音，跳过）。
    var ranges = new (int From, int To)[]
    {
        (0x00C0, 0x024F), // Latin-1 Supplement + Latin Extended-A/B
        (0x1E00, 0x1EFF), // Latin Extended Additional
        (0x2C60, 0x2C7F), // Latin Extended-C
        (0xA720, 0xA7FF), // Latin Extended-D
        (0xAB30, 0xAB6F), // Latin Extended-E
    };

    var rows = new List<(int CodePoint, char Base)>();
    foreach (var (from, to) in ranges)
    {
        for (var cp = from; cp <= to; cp++)
        {
            var text = char.ConvertFromUtf32(cp);
            var decomposed = text.Normalize(NormalizationForm.FormD);
            if (decomposed.Length < 2 || decomposed == text) continue;

            var baseLetter = decomposed[0];
            if (!char.IsAsciiLetter(baseLetter)) continue;

            var marksOnly = true;
            for (var i = 1; i < decomposed.Length; i++)
            {
                if (!IsCombiningDiacritic(decomposed[i]))
                {
                    marksOnly = false;
                    break;
                }
            }
            if (!marksOnly) continue;

            rows.Add((cp, baseLetter));
        }
    }
    return rows;
}

static List<(int CodePoint, int Target)> BuildVariantRows(string zipPath)
{
    if (!File.Exists(zipPath))
        throw new FileNotFoundException($"缺少 Unihan 数据：{Path.GetFullPath(zipPath)}", zipPath);

    var simplified = new Dictionary<int, int>();
    var japaneseOld = new Dictionary<int, int>();

    using (var zip = ZipFile.OpenRead(zipPath))
    {
        var entry = zip.GetEntry("Unihan_Variants.txt")
            ?? throw new InvalidDataException("Unihan.zip 缺少 Unihan_Variants.txt");
        using var reader = new StreamReader(entry.Open(), Encoding.UTF8);
        while (reader.ReadLine() is { } line)
        {
            if (line.Length == 0 || line[0] == '#') continue;
            var cols = line.Split('\t');
            if (cols.Length < 3) continue;
            if (!TryParseCodePoint(cols[0], out var cp)) continue;
            if (!TryParseFirstCodePoint(cols[2], out var target)) continue;
            if (cp == target) continue;

            switch (cols[1])
            {
                case "kSimplifiedVariant":
                    simplified.TryAdd(cp, target);
                    break;
                case "kJapaneseOldVariant":
                    japaneseOld.TryAdd(cp, target);
                    break;
            }
        }
    }

    var candidates = new SortedDictionary<int, int>();
    foreach (var (cp, target) in simplified) candidates.TryAdd(cp, target);
    // 新字体 → 旧字体 → 简体（旧字体没有简体目标时跳过）。
    foreach (var (cp, oldForm) in japaneseOld)
    {
        if (simplified.TryGetValue(oldForm, out var target)) candidates.TryAdd(cp, target);
    }

    var rows = new List<(int CodePoint, int Target)>();
    foreach (var (cp, target) in candidates)
    {
        var source = char.ConvertFromUtf32(cp);
        // ToolGood.Words 已能折叠的繁简字不重复入表，避免覆盖既有中文规则。
        if (WordsHelper.ToSimplifiedChinese(source, 0) != source) continue;
        rows.Add((cp, target));
    }
    return rows;
}

static void WriteAccentTable(string output, List<(int CodePoint, char Base)> rows)
{
    var builder = new StringBuilder();
    builder.AppendLine("# Archoera indexer 拉丁去音符号折叠表（生成，勿手改）");
    builder.AppendLine("# 来源: Unicode 规范分解（NFD）——仅收录「ASCII 基字母 + 组合音标」的预组合拉丁字母");
    builder.AppendLine("# 字段: HEXCODE<TAB>HEXOUT（输入/输出均为单码点十六进制）");
    builder.AppendLine("# 生成: tools/gen_tables（cd app/core/indexer && dotnet run --project tools/gen_tables）");
    builder.AppendLine("# 不含: ł / ø / đ / ß / æ / œ / ð / þ 等无规范分解的字母；组合音标由运行时直接丢弃");
    foreach (var (cp, baseLetter) in rows)
    {
        builder.Append(cp.ToString("X4", CultureInfo.InvariantCulture));
        builder.Append('\t');
        builder.Append(((int)baseLetter).ToString("X4", CultureInfo.InvariantCulture));
        builder.AppendLine();
    }
    File.WriteAllText(output, builder.ToString(), new UTF8Encoding(false));
    Console.WriteLine($"accent_fold.tsv : {rows.Count} 条 -> {output}");
}

static void WriteVariantTable(string output, List<(int CodePoint, int Target)> rows)
{
    var builder = new StringBuilder();
    builder.AppendLine("# Archoera indexer 异体字 → 简体补齐表（生成，勿手改）");
    builder.AppendLine("# 来源: reference/unihan/Unihan.zip · kSimplifiedVariant（日文新字体经 kJapaneseOldVariant 串联）");
    builder.AppendLine("# 范围: 仅 ToolGood.Words 繁简词库未覆盖的字符（主要是日文新字体：鉄/絵/円/広/変/楽/駅…）");
    builder.AppendLine("# 字段: HEXCODE<TAB>HEXOUT（输入/输出均为单码点十六进制）");
    builder.AppendLine("# 生成: tools/gen_tables（cd app/core/indexer && dotnet run --project tools/gen_tables）");
    foreach (var (cp, target) in rows)
    {
        builder.Append(cp.ToString("X4", CultureInfo.InvariantCulture));
        builder.Append('\t');
        builder.Append(target.ToString("X4", CultureInfo.InvariantCulture));
        builder.AppendLine();
    }
    File.WriteAllText(output, builder.ToString(), new UTF8Encoding(false));
    Console.WriteLine($"variant_fold.tsv : {rows.Count} 条 -> {output}");
}

static bool TryParseCodePoint(string text, out int codePoint)
{
    codePoint = 0;
    var span = text.AsSpan().Trim();
    if (span.Length < 3 || span[0] != 'U' || span[1] != '+') return false;
    return int.TryParse(span[2..], NumberStyles.HexNumber, CultureInfo.InvariantCulture, out codePoint);
}

static bool TryParseFirstCodePoint(string value, out int codePoint)
{
    codePoint = 0;
    var first = value.Split(' ', 2)[0];
    var annotation = first.IndexOf('<');
    if (annotation >= 0) first = first[..annotation];
    return TryParseCodePoint(first, out codePoint);
}

static bool IsCombiningDiacritic(char ch) => ch is
    >= '\u0300' and <= '\u036F' or
    >= '\u1AB0' and <= '\u1AFF' or
    >= '\u1DC0' and <= '\u1DFF' or
    >= '\u20D0' and <= '\u20FF' or
    >= '\uFE20' and <= '\uFE2F';
