#pragma once

/// Archoera 刮削器 —— 数据结构与接口定义

#include <string>
#include <vector>
#include <optional>
#include <cstdint>
#include <fstream>
#include <algorithm>
#include <cstdlib>
#ifdef _WIN32
// windows.h 会定义 min/max 函数宏，污染本文件及其后所有 STL 头
// （std::min/std::max 被展开成 std::（→ C2589，<list> 等内部解析崩溃）
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#undef min
#undef max
#else
#include <unistd.h>
#endif

namespace archoera::scraper {

/// 根据设备硬件质量自动检测合理的并行度
///
/// 考虑因素：
///   - CPU 核心数（基数）
///   - 总物理内存（设备档次）
///   - 可用内存比例（低内存时降级）
///
/// \param isCpuBound true=CPU密集(贴近核心数), false=I/O bound(可用更高)
/// \param maxOverride 环境变量硬上限（0=不限制）
inline int detectParallelism(bool isCpuBound = false, int maxOverride = 0) {
    // CPU 核心数
    long cpuCount = 0;
#ifdef _WIN32
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    cpuCount = static_cast<long>(si.dwNumberOfProcessors);
#else
    cpuCount = sysconf(_SC_NPROCESSORS_ONLN);
#endif
    if (cpuCount < 1) cpuCount = 2;

    // 总物理内存（MB）
    long totalMemMb = 0;
    long availableMemMb = 0;
#ifdef _WIN32
    MEMORYSTATUSEX ms;
    ms.dwLength = sizeof(ms);
    if (GlobalMemoryStatusEx(&ms)) {
        totalMemMb = static_cast<long>(ms.ullTotalPhys / (1024 * 1024));
        availableMemMb = static_cast<long>(ms.ullAvailPhys / (1024 * 1024));
    }
#else
    std::ifstream meminfo("/proc/meminfo");
    if (meminfo.is_open()) {
        std::string line;
        while (std::getline(meminfo, line)) {
            if (line.rfind("MemTotal:", 0) == 0) {
                // "MemTotal:       16384000 kB"
                auto colon = line.find(':');
                auto valStr = line.substr(colon + 1);
                long kb = std::atol(valStr.c_str());
                if (kb > 0) totalMemMb = kb / 1024;
            } else if (line.rfind("MemAvailable:", 0) == 0) {
                auto colon = line.find(':');
                auto valStr = line.substr(colon + 1);
                long kb = std::atol(valStr.c_str());
                if (kb > 0) availableMemMb = kb / 1024;
            }
        }
    }
#endif

    // 1) CPU 基数
    long base = isCpuBound
        ? std::max(1L, cpuCount)
        : std::max(2L, (cpuCount + 1) / 2);

    // 2) 内存系数（每 worker 256MB）
    const long memPerWorkerMb = 256;
    long memCap = (totalMemMb > 0)
        ? std::max(1L, totalMemMb / memPerWorkerMb)
        : 4;  // 获取不到则保守 4

    // 3) 可用内存比例
    double availRatio = (totalMemMb > 0 && availableMemMb > 0)
        ? static_cast<double>(availableMemMb) / totalMemMb
        : 1.0;
    double memoryPressure = 1.0;
    if (availRatio < 0.2)       memoryPressure = 0.5;
    else if (availRatio < 0.4)  memoryPressure = 0.75;

    // 4) 设备等级上限（最多 8 个并发搜索器）
    long deviceCap = 8;
    if (totalMemMb >= 2048)      deviceCap = 8;
    else if (totalMemMb >= 1024) deviceCap = 4;
    else                         deviceCap = 2;

    // 5) 综合计算
    long raw = static_cast<long>(base * memoryPressure);
    long result = std::min({raw, memCap, deviceCap});

    // 6) 环境变量覆盖（仅降低，不提高——安全原则）
    if (maxOverride > 0)
        result = std::min(result, static_cast<long>(maxOverride));

    return static_cast<int>(std::clamp(result, 1L, 8L));
}

/// 曲目元数据（从 SQLite 读取，用于刮削查询）
struct TrackInfo {
    std::string id;           ///< track id（MD5）
    std::string title;
    std::string artist;
    std::string album;
    std::string albumArtist;
    std::string composer;     ///< 作曲家
    std::string genre;        ///< 流派
    int trackNumber = 0;
    int discNumber = 0;       ///< 碟片编号
    int year = 0;             ///< 年份
    int durationMs = 0;
    std::string filePath;     ///< 音频文件路径（用于写入标签）

    // MusicBrainz 标识符（从文件标签读取，用于判断是否已刮削）
    std::string mbid;         ///< MusicBrainz Recording ID
    std::string albumMbid;    ///< MusicBrainz Album ID
    std::string artistMbid;   ///< MusicBrainz Artist ID
    std::string isrc;         ///< 国际标准录音编码
};

/// 刮削结果（包含完整元数据，将写入音频文件标签）
struct ScrapeResult {
    std::string trackId;
    
    // MusicBrainz 标识符
    std::optional<std::string> mbid;         ///< MusicBrainz Recording ID
    std::optional<std::string> albumMbid;    ///< MusicBrainz Release Group ID
    std::optional<std::string> artistMbid;   ///< MusicBrainz Artist ID
    std::optional<std::string> isrc;         ///< 国际标准录音编码
    
    // 元数据
    std::optional<std::string> title;        ///< 标题（可能被修正）
    std::optional<std::string> artist;       ///< 艺术家（可能被修正）
    std::optional<std::string> album;        ///< 专辑（可能被修正）
    std::optional<std::string> albumArtist;  ///< 专辑艺术家
    std::optional<std::string> composer;     ///< 作曲家
    std::optional<std::string> genre;        ///< 流派
    std::optional<std::string> label;        ///< 唱片公司
    std::optional<int> trackNumber;          ///< 曲目编号
    std::optional<int> trackTotal;           ///< 专辑总曲目数
    std::optional<int> discNumber;           ///< 碟片编号
    std::optional<int> discTotal;            ///< 总碟片数
    std::optional<int> year;                 ///< 年份
    std::optional<std::string> lyrics;       ///< 歌词（纯文本或 LRC）
    
    // 封面数据（JPEG/PNG 二进制）
    std::vector<uint8_t> coverData;          ///< 封面图片数据
    std::string coverMime;                   ///< 封面 MIME 类型（image/jpeg 等）
    
    std::vector<std::string> scrapedSources; ///< 已刮削的数据源
};

/// 刮削队列项
struct QueueItem {
    std::string trackId;
    std::string status;       ///< pending / running / done / failed
    int retries = 0;
    std::string lastError;
};

/// 刮削配置
struct ScraperConfig {
    std::string apiUrl;        ///< TS 层 API 地址
    std::string proxyKey;      ///< SQLite 写入代理密钥
    int batchSize = 10;        ///< 每批处理数量
    int maxRetries = 5;        ///< 最大重试次数（超过后隔离）
    int requestTimeoutMs = 15000;  ///< HTTP 请求超时
    int rateLimitMs = 1000;    ///< MusicBrainz 限速（1 req/sec）
    std::string userAgent = "ArchoeraScraper/1.0";
    bool embedMetadata = true; ///< 是否将元数据嵌入音频文件
    bool embedCover = true;    ///< 是否将封面嵌入音频文件
    bool embedLyrics = true;   ///< 是否将歌词嵌入音频文件

    /// 刮削目录列表（独立于扫描目录）
    /// 刮削器直接扫描这些目录，不依赖 DB tracks 表
    /// 如果为空，回退到从 DB 队列获取（兼容旧模式）
    std::vector<std::string> scrapeDirs;

    /// 是否跳过已刮削的文件（有 MBID 或完整元数据的文件）
    /// 默认 true，避免重复处理已刮削的音乐
    bool skipScraped = true;

    /// 各数据源开关
    bool useMusicBrainz = true; ///< 使用 MusicBrainz（提供 MBID/ISRC/权威元数据）
    bool useDeezer = true;      ///< 使用 Deezer（补充封面与元数据）
    bool useItunes = true;      ///< 使用 iTunes Search（补充封面与元数据）

    /// 中文音乐源开关
    /// 这些源对中文音乐匹配率更高，与 MusicBrainz/Deezer/iTunes 形成互补
    bool useNetease = true;     ///< 使用网易云（中文元数据/歌词/封面）
    bool useQQMusic = true;     ///< 使用 QQ 音乐（中文元数据/歌词/封面）
    bool useKugou = true;       ///< 使用酷狗（中文元数据/歌词/封面）
    bool useKuwo = true;        ///< 使用酷我（中文元数据/歌词/封面）
    bool useMigu = true;        ///< 使用咪咕（中文元数据/封面）

    /// AcoustID 音频指纹配置
    /// 参考 MusicBrainz Picard 的 AcoustID 插件实现
    bool useAcoustID = true;     ///< 是否启用音频指纹识别
    std::string acoustidApiKey = "8XquS7o";  ///< AcoustID 免费 API key（可替换为自己的）
    int acoustidMinScore = 80;   ///< AcoustID 匹配最低得分（0~100），低于此值忽略

    /// 并发查询线程数（多源并发查询时使用）
    /// 由 detectParallelism() 根据设备硬件自动确定。
    int concurrentWorkers = detectParallelism(false, 0);

    /// 单次扫描最大文件数（防止超大目录导致 OOM）
    /// 默认 50000
    int maxScanFiles = 50000;

    /// 扫描时跳过超过此大小的文件（单位 MB）
    /// 默认 500 MB
    int maxFileSizeMb = 500;

    /// 连续文件读取失败达到此数量时停止扫描
    /// 默认 50（防止大量损坏文件拖慢整个扫描）
    int maxScanErrors = 50;

    /// 封面缓存目录（写入音频文件标签后，同步写入此目录供 Subsonic 等服务使用）
    /// 格式：{coverCacheDir}/{trackId}.img
    /// 默认空字符串表示不写入缓存
    std::string coverCacheDir;

    /// scraper-state.db 路径（队列模式直写队列）
    /// FFI 宿主通过 config 注入；CLI 模式沿用 ARCHOERA_SCRAPER_DB_PATH 环境变量
    std::string scraperDbPath;
};

} // namespace archoera::scraper
