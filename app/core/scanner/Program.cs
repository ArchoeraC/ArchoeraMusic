using System.IO;
using System.Text.Json;
using TagLibFile = TagLib.File;

namespace Archoera.Scanner;

/// <summary>
/// Archoera 扫描引擎入口
///
/// 用法：
///   archoera-scanner scan [--dirs &lt;dir1,dir2&gt;] [--full] [--batch &lt;n&gt;]
///   archoera-scanner parse &lt;file&gt;
///
/// 环境变量：
///   ARCHOERA_DATA_DIR   数据目录（默认 <cwd>/data）
///   ARCHOERA_MUSIC_DIR  音乐根目录
///   ARCHOERA_DB_PATH    SQLite 数据库路径（必须设置，直写模式）
///   SCANNER_MAX_PARALLELISM  并行解析数（默认 = 2 * CPU 核数）
///   SCANNER_MAX_FILE_SIZE_MB  文件大小上限 MB（默认 500）
///   SCANNER_MAX_SCAN_FILES    文件数量上限（默认 50000）
///   SCANNER_MAX_SCAN_ERRORS   连续错误上限（默认 50）
///
/// 输出：
///   stdout：JSON 格式进度/结果（TS 层监听）
///   stderr：人类可读日志
///   exit code：0=成功，1=错误，2=取消
/// </summary>
public static class Program
{
    public static async Task<int> Main(string[] args)
    {
        var dataDir = Environment.GetEnvironmentVariable("ARCHOERA_DATA_DIR")
            ?? Path.GetFullPath(Path.Combine(Directory.GetCurrentDirectory(), "data"));
        var defaultMusicDir = Environment.GetEnvironmentVariable("ARCHOERA_MUSIC_DIR")
            ?? Path.Combine(dataDir, "music");
        var coverCacheDir = Path.Combine(dataDir, "cache", "covers");
        var quarantineDir = Path.Combine(dataDir, "quarantine");

        // 安全限制环境变量
        var maxFileSizeMb = int.TryParse(Environment.GetEnvironmentVariable("SCANNER_MAX_FILE_SIZE_MB"), out var mf) ? mf : 500;
        var maxScanFiles = int.TryParse(Environment.GetEnvironmentVariable("SCANNER_MAX_SCAN_FILES"), out var sf) ? sf : 50000;
        var maxScanErrors = int.TryParse(Environment.GetEnvironmentVariable("SCANNER_MAX_SCAN_ERRORS"), out var se) ? se : 50;
        var maxParallelism = int.TryParse(Environment.GetEnvironmentVariable("SCANNER_MAX_PARALLELISM"), out var mp)
            ? mp : AdaptiveConcurrency.ForIOBound();

        if (args.Length == 0)
        {
            PrintUsage();
            return 1;
        }

        var command = args[0].ToLowerInvariant();
        return command switch
        {
            "scan" => await RunScan(args[1..], defaultMusicDir, coverCacheDir, quarantineDir, maxFileSizeMb, maxScanFiles, maxScanErrors, maxParallelism),
            "parse" => await RunParse(args[1..], coverCacheDir),
            "-h" or "--help" or "help" => PrintUsage(),
            _ => UnknownCommand(command),
        };
    }

    private static async Task<int> RunScan(
        string[] args, string defaultMusicDir, string coverCacheDir, string quarantineDir,
        int maxFileSizeMb, int maxScanFiles, int maxScanErrors, int maxParallelism)
    {
        string? dirs = null;
        var full = false;
        var batch = 0; // 0 = 不限，由 AdaptiveBatchSize 根据内存自动决定

        for (int i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--dirs":
                case "-d":
                    if (i + 1 < args.Length) dirs = args[++i];
                    break;
                case "--full":
                case "-f":
                    full = true;
                    break;
                case "--batch":
                case "-b":
                    if (i + 1 < args.Length && int.TryParse(args[++i], out var b)) batch = b;
                    break;
                case "--help":
                case "-h":
                    Console.WriteLine("用法: archoera-scanner scan [--dirs <dir1,dir2>] [--full] [--batch <n>]");
                    return 0;
            }
        }

        var dirList = string.IsNullOrEmpty(dirs)
            ? new List<string> { defaultMusicDir }
            : dirs.Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).ToList();

        var dbPath = Environment.GetEnvironmentVariable("ARCHOERA_DB_PATH");
        if (string.IsNullOrEmpty(dbPath))
        {
            Console.Error.WriteLine("[scanner] 错误: 未设置 ARCHOERA_DB_PATH 环境变量。直写模式需要数据库路径。");
            return 1;
        }

        // 直写模式：扫描器直接操作 SQLite，数据不经过 Node.js / V8 堆
        Console.Error.WriteLine($"[scanner] 直写模式: {dbPath}");
        using var db = new SqliteDirectWriter(dbPath);
        var engine = new ScannerEngine(db, coverCacheDir, quarantineDir, batch, !full,
            maxFileSizeBytes: maxFileSizeMb * 1024L * 1024L,
            maxScanFiles: maxScanFiles,
            maxScanErrors: maxScanErrors,
            maxParallelism: maxParallelism);

        using var cts = new CancellationTokenSource();
        Console.CancelKeyPress += (_, e) => { e.Cancel = true; cts.Cancel(); };

        try
        {
            var result = await engine.ScanAsync(dirList, cts.Token);
            Console.WriteLine(JsonSerializer.Serialize(result, ScannerJsonContext.Default.ScanResult));
            return result.Canceled ? 2 : 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[scanner] FATAL: {ex}");
            return 1;
        }
    }

    private static async Task<int> RunParse(string[] args, string coverCacheDir)
    {
        if (args.Length == 0 || args[0].StartsWith('-'))
        {
            Console.Error.WriteLine("用法: archoera-scanner parse <file>");
            return 1;
        }

        var file = args[0];
        var track = await Task.Run(() => ParseSingleFile(file, coverCacheDir));
        if (track != null)
        {
            Console.WriteLine(JsonSerializer.Serialize(track, ScannerJsonContext.Default.TrackMetadata));
            return 0;
        }
        Console.Error.WriteLine($"[scanner] 解析失败: {file}");
        return 1;
    }

    private static int PrintUsage()
    {
        Console.Error.WriteLine("""
            Archoera 音乐库扫描引擎

            用法:
              archoera-scanner scan [--dirs <dir1,dir2>] [--full] [--batch <n>]
                  扫描音乐库（默认增量）
              archoera-scanner parse <file>
                  解析单个文件元数据（调试用）

            选项:
              --dirs, -d    扫描目录（逗号分隔，默认 $ARCHOERA_MUSIC_DIR）
              --full, -f    全量扫描（清空数据库重新构建）
              --batch, -b   批量写入上限（默认 0=不限，由系统内存自动决定）

            环境变量:
              ARCHOERA_DB_PATH             SQLite 数据库路径（必需）
              ARCHOERA_DATA_DIR            数据目录（默认 <cwd>/data）
              ARCHOERA_MUSIC_DIR           音乐根目录
              SCANNER_MAX_PARALLELISM     并行解析数（默认 = 2 * CPU 核数）
              SCANNER_MAX_FILE_SIZE_MB    文件大小上限 MB（默认 500）
              SCANNER_MAX_SCAN_FILES      文件数量上限（默认 50000）
              SCANNER_MAX_SCAN_ERRORS     连续错误上限（默认 50）
            """);
        return 0;
    }

    private static int UnknownCommand(string command)
    {
        Console.Error.WriteLine($"未知命令: {command}");
        PrintUsage();
        return 1;
    }

    /// <summary>
    /// 单文件解析（parse 命令用，与 ScannerEngine.ParseFile 逻辑一致）
    /// </summary>
    private static TrackMetadata? ParseSingleFile(string filePath, string coverCacheDir)
    {
        FileInfo info;
        try { info = new FileInfo(filePath); }
        catch { return null; }
        if (!info.Exists) return null;

        TagLibFile tag;
        try { tag = TagLibFile.Create(filePath); }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[scanner] 解析失败 {filePath}: {ex.Message}");
            return null;
        }

        var id = Md5Hex(filePath);
        var props = tag.Properties;
        var audioProps = props.AudioSampleRate > 0 ? props : null;

        var title = string.IsNullOrWhiteSpace(tag.Tag.Title)
            ? Path.GetFileNameWithoutExtension(filePath)
            : tag.Tag.Title;

        var artists = tag.Tag.Performers?
            .Where(n => !string.IsNullOrWhiteSpace(n))
            .Select(n => new ArtistRef { Name = n })
            .ToList();
        if (artists == null || artists.Count == 0)
            artists = new List<ArtistRef> { new() { Name = "未知歌手" } };

        AlbumRef? album = null;
        if (!string.IsNullOrWhiteSpace(tag.Tag.Album))
        {
            album = new AlbumRef
            {
                Name = tag.Tag.Album,
                Year = tag.Tag.Year > 0 ? (int?)tag.Tag.Year : null,
                Artist = tag.Tag.Performers?.FirstOrDefault(),
            };
        }

        var duration = (long)Math.Round(tag.Properties.Duration.TotalMilliseconds);

        string? cover = null;
        var pictures = tag.Tag.Pictures;
        if (pictures != null && pictures.Length > 0)
        {
            try
            {
                Directory.CreateDirectory(coverCacheDir);
                var coverPath = Path.Combine(coverCacheDir, $"{id}.img");
                var pic = pictures[0];
                File.WriteAllBytes(coverPath, pic.Data.Data);
                cover = $"/api/music/cover/{id}";
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"[scanner] 封面写入失败 {filePath}: {ex.Message}");
            }
        }

        // 歌词（TagLibSharp 2.3.0 中 Tag.Lyrics 是 string，不是 string[]）
        var lyricsRaw = tag.Tag.Lyrics;
        string? lyrics = string.IsNullOrWhiteSpace(lyricsRaw) ? null : lyricsRaw.Trim();

        return new TrackMetadata
        {
            Id = id,
            Path = filePath,
            Title = title,
            Track = tag.Tag.Track > 0 ? (int?)tag.Tag.Track : null,
            Artists = artists,
            Album = album,
            Duration = duration,
            Cover = cover,
            Codec = audioProps?.Description,
            SampleRate = audioProps?.AudioSampleRate > 0 ? audioProps?.AudioSampleRate : null,
            BitRate = audioProps?.AudioBitrate > 0 ? audioProps?.AudioBitrate : null,
            Channels = audioProps?.AudioChannels > 0 ? audioProps?.AudioChannels : null,
            BitsPerSample = audioProps?.BitsPerSample > 0 ? audioProps?.BitsPerSample : null,
            FileSize = info.Length,
            Mtime = new DateTimeOffset(info.LastWriteTimeUtc).ToUnixTimeMilliseconds(),
            Ctime = new DateTimeOffset(info.CreationTimeUtc).ToUnixTimeMilliseconds(),
            Lyrics = lyrics,
        };
    }

    private static string Md5Hex(string input)
    {
        var bytes = System.Security.Cryptography.MD5.HashData(System.Text.Encoding.UTF8.GetBytes(input));
        return Convert.ToHexString(bytes).ToLowerInvariant();
    }
}
