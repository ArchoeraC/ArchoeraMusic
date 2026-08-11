/// Archoera 刮削器 FFI 库（C ABI）
///
/// 复用 Archoera 刮削引擎（header-only ScraperEngine），通过事件队列与宿主通信，
/// 避免进程 spawn 与本地端口：
///   - 状态/进度经事件队列轮询（archoera_scraper_poll_event）
///   - 队列模式取曲目走内存表注入（archoera_scraper_enqueue），无 HTTP
///   - 引擎在独立 pthread 中执行（Dart VM 不向其发送中断信号，网络 IO 安全）
///
/// 生命周期（单实例语义；cancelFlag 为全局共享，勿并发多 handle）：
///   handle = archoera_scraper_create(configJson)
///   archoera_scraper_enqueue(handle, trackJson) × N   （队列模式可选）
///   archoera_scraper_run(handle)                      （后台线程执行）
///   轮询 archoera_scraper_poll_event(handle) → JSON | NULL
///   archoera_scraper_cancel(handle)                   （可选，文件边界安全退出）
///   archoera_scraper_is_done(handle) → 1/0
///   archoera_scraper_destroy(handle)
///
/// configJson 字段（对齐 ScraperConfig）：
///   dirs: string[]           刮削目录（空 → DB 队列模式）
///   scraperDbPath: string    scraper-state.db 路径（必需）
///   coverCacheDir: string    封面缓存目录（可选）
///   apiUrl / proxyKey        本地 HTTP 兜底（默认空 → 纯 provider，无端口）
///   batchSize / maxRetries / requestTimeoutMs / rateLimitMs / userAgent
///   embedMetadata / embedCover / embedLyrics / skipScraped
///   useMusicBrainz / useDeezer / useItunes / useNetease / useQQMusic
///   useKugou / useKuwo / useMigu / useAcoustID / acoustidApiKey / acoustidMinScore
///   concurrentWorkers / maxScanFiles / maxFileSizeMb / maxScanErrors
///   mode: "once" | "daemon"  （默认 once）
///   interval: int            daemon 间隔秒（默认 60）

#include "scraper_engine.h"
#include <nlohmann/json.hpp>
#include <cstring>
#include <string>
#include <vector>
#include <thread>
#include <atomic>
#include <mutex>
#include <condition_variable>
#include <deque>
#include <memory>
#include <unordered_map>
#include <stdexcept>

using json = nlohmann::json;
namespace scraper = archoera::scraper;

#ifdef _WIN32
#define ARCHOERA_SCRAPER_API __declspec(dllexport)
#else
#define ARCHOERA_SCRAPER_API
#endif

extern "C" {

/// 事件队列：固定容量环形缓冲（互斥保护），poll_event 非阻塞取首条
class EventQueue {
public:
    explicit EventQueue(size_t cap) : cap_(cap) {}

    bool push(std::string&& ev) {
        std::lock_guard<std::mutex> lk(mu_);
        if (q_.size() >= cap_) return false;  // 满则丢弃（宿主应高频轮询）
        q_.push_back(std::move(ev));
        return true;
    }

    /// 取一条；空返回 false
    bool pop(std::string& out) {
        std::lock_guard<std::mutex> lk(mu_);
        if (q_.empty()) return false;
        out = std::move(q_.front());
        q_.pop_front();
        return true;
    }

private:
    size_t cap_;
    std::deque<std::string> q_;
    std::mutex mu_;
};

struct ScraperHandle {
    scraper::ScraperConfig cfg;
    std::unique_ptr<scraper::ScraperEngine> engine;   // 在 run 线程内构造
    std::thread worker;
    std::atomic<bool> done{false};
    std::atomic<bool> running{false};
    bool daemonMode = false;
    int interval = 60;
    std::unordered_map<std::string, json> tracks;      // 队列模式内存曲目表
    EventQueue events{512};
    std::string errbuf;
    std::mutex tracksMu;
};

static std::string parseStr(const json& j, const char* key, const std::string& dflt) {
    auto it = j.find(key);
    return (it != j.end() && it->is_string()) ? it->get<std::string>() : dflt;
}

static bool parseBool(const json& j, const char* key, bool dflt) {
    auto it = j.find(key);
    return (it != j.end() && it->is_boolean()) ? it->get<bool>() : dflt;
}

static int parseInt(const json& j, const char* key, int dflt) {
    auto it = j.find(key);
    return (it != j.end() && it->is_number_integer()) ? it->get<int>() : dflt;
}

/// 解析 config JSON → ScraperConfig；失败返回 false 并写 err
static bool parseConfig(const char* configJson, ScraperHandle* h) {
    json j;
    try {
        j = json::parse(configJson);
    } catch (const json::exception& e) {
        h->errbuf = std::string("config JSON 解析失败: ") + e.what();
        return false;
    }

    scraper::ScraperConfig& c = h->cfg;
    // 目录
    if (j.contains("dirs") && j["dirs"].is_array()) {
        for (const auto& d : j["dirs"]) {
            if (d.is_string()) c.scrapeDirs.push_back(d.get<std::string>());
        }
    }
    c.scraperDbPath = parseStr(j, "scraperDbPath", "");
    c.coverCacheDir = parseStr(j, "coverCacheDir", "");
    c.apiUrl = parseStr(j, "apiUrl", "");
    c.proxyKey = parseStr(j, "proxyKey", "dev-proxy-key");

    c.batchSize = parseInt(j, "batchSize", c.batchSize);
    c.maxRetries = parseInt(j, "maxRetries", c.maxRetries);
    c.requestTimeoutMs = parseInt(j, "requestTimeoutMs", c.requestTimeoutMs);
    c.rateLimitMs = parseInt(j, "rateLimitMs", c.rateLimitMs);
    c.userAgent = parseStr(j, "userAgent", c.userAgent);

    c.embedMetadata = parseBool(j, "embedMetadata", c.embedMetadata);
    c.embedCover = parseBool(j, "embedCover", c.embedCover);
    c.embedLyrics = parseBool(j, "embedLyrics", c.embedLyrics);
    c.skipScraped = parseBool(j, "skipScraped", c.skipScraped);

    c.useMusicBrainz = parseBool(j, "useMusicBrainz", c.useMusicBrainz);
    c.useDeezer = parseBool(j, "useDeezer", c.useDeezer);
    c.useItunes = parseBool(j, "useItunes", c.useItunes);
    c.useNetease = parseBool(j, "useNetease", c.useNetease);
    c.useQQMusic = parseBool(j, "useQQMusic", c.useQQMusic);
    c.useKugou = parseBool(j, "useKugou", c.useKugou);
    c.useKuwo = parseBool(j, "useKuwo", c.useKuwo);
    c.useMigu = parseBool(j, "useMigu", c.useMigu);
    c.useAcoustID = parseBool(j, "useAcoustID", c.useAcoustID);
    c.acoustidApiKey = parseStr(j, "acoustidApiKey", c.acoustidApiKey);
    c.acoustidMinScore = parseInt(j, "acoustidMinScore", c.acoustidMinScore);

    c.concurrentWorkers = parseInt(j, "concurrentWorkers", c.concurrentWorkers);
    c.maxScanFiles = parseInt(j, "maxScanFiles", c.maxScanFiles);
    c.maxFileSizeMb = parseInt(j, "maxFileSizeMb", c.maxFileSizeMb);
    c.maxScanErrors = parseInt(j, "maxScanErrors", c.maxScanErrors);

    std::string mode = parseStr(j, "mode", "once");
    h->daemonMode = (mode == "daemon");
    h->interval = parseInt(j, "interval", 60);

    return true;
}

/// 队列取曲目：查内存表，未命中返回空串
static std::string trackProviderCb(const std::unordered_map<std::string, json>& tracks,
                                   const std::mutex& tracksMu,
                                   const std::string& trackId) {
    std::lock_guard<std::mutex> lk(const_cast<std::mutex&>(tracksMu));
    auto it = tracks.find(trackId);
    if (it == tracks.end()) return "";
    return it->second.dump();
}

// ---------------------------------------------------------------------------
// C ABI
// ---------------------------------------------------------------------------

/// 创建刮削器句柄。仅解析 config（无网络 IO），立即返回。
/// 失败返回 NULL，错误信息见 archoera_scraper_errbuf。
ARCHOERA_SCRAPER_API void* archoera_scraper_create(const char* configJson) {
    if (!configJson) return nullptr;
    auto* h = new ScraperHandle();
    if (!parseConfig(configJson, h)) {
        std::string err = h->errbuf;
        delete h;
        errno = 0;  // 不依赖 errno
        // 将错误留在静态缓冲不可行；改为抛给调用方：返回 NULL 前打印到 stderr
        std::cerr << "[archoera_scraper] " << err << std::endl;
        return nullptr;
    }
    return h;
}

/// 获取上次错误信息（仅 create 失败时可靠；运行期错误走 error 事件）
ARCHOERA_SCRAPER_API const char* archoera_scraper_errbuf(void* handle) {
    auto* h = static_cast<ScraperHandle*>(handle);
    return h ? h->errbuf.c_str() : "invalid handle";
}

/// 注入一条曲目（队列模式）。trackJson 与 /api/db/tracks/:id 响应同构。
/// 返回 1 成功 / 0 失败（格式非法或已在运行）。
ARCHOERA_SCRAPER_API int archoera_scraper_enqueue(void* handle, const char* trackJson) {
    auto* h = static_cast<ScraperHandle*>(handle);
    if (!h || !trackJson || h->running.load()) return 0;
    json j;
    try {
        j = json::parse(trackJson);
    } catch (...) {
        return 0;
    }
    std::string id = j.value("id", "");
    if (id.empty()) return 0;
    {
        std::lock_guard<std::mutex> lk(h->tracksMu);
        h->tracks[id] = std::move(j);
    }
    return 1;
}

/// 启动刮削（后台线程）。引擎构造 + 网络 IO 全部在 pthread 内执行。
/// 返回 1 已启动 / 0 已在运行或句柄无效。
ARCHOERA_SCRAPER_API int archoera_scraper_run(void* handle) {
    auto* h = static_cast<ScraperHandle*>(handle);
    if (!h) return 0;
    bool expected = false;
    if (!h->running.compare_exchange_strong(expected, true)) return 0;
    h->done.store(false);

    h->worker = std::thread([h]() {
        try {
            h->engine.reset(new scraper::ScraperEngine(h->cfg));

            // 状态事件 → 事件队列
            h->engine->setStatusCallback([h](const json& ev) {
                h->events.push(ev.dump());
            });

            // 队列取曲目 → 内存表（非端口化）
            h->engine->setTrackProvider(
                [h](const std::string& trackId) -> std::string {
                    return trackProviderCb(h->tracks, h->tracksMu, trackId);
                });

            if (h->daemonMode) {
                h->engine->runDaemon(h->interval > 0 ? h->interval : 60);
            } else {
                h->engine->runOnce();
            }
        } catch (const std::exception& e) {
            json err = {{"type", "error"}, {"message", e.what()}};
            h->events.push(err.dump());
        } catch (...) {
            json err = {{"type", "error"}, {"message", "unknown fatal error"}};
            h->events.push(err.dump());
        }

        // 清空内存曲目表，释放占用
        {
            std::lock_guard<std::mutex> lk(h->tracksMu);
            h->tracks.clear();
        }
        h->engine.reset();
        h->running.store(false);
        h->done.store(true);
    });

    return 1;
}

/// 是否已结束本轮（线程退出）
ARCHOERA_SCRAPER_API int archoera_scraper_is_done(void* handle) {
    auto* h = static_cast<ScraperHandle*>(handle);
    return (h && h->done.load()) ? 1 : 0;
}

/// 是否正在运行
ARCHOERA_SCRAPER_API int archoera_scraper_is_running(void* handle) {
    auto* h = static_cast<ScraperHandle*>(handle);
    return (h && h->running.load()) ? 1 : 0;
}

/// 取消：设置全局取消标志，引擎在下一个文件边界安全退出
ARCHOERA_SCRAPER_API void archoera_scraper_cancel(void* handle) {
    auto* h = static_cast<ScraperHandle*>(handle);
    if (!h) return;
    scraper::cancelFlag().store(true, std::memory_order_relaxed);
}

/// 取一条事件 JSON（progress / done / empty / error）；无则返回 NULL。
/// 返回值指向内部缓冲，下一次 poll 或 destroy 前有效。
ARCHOERA_SCRAPER_API const char* archoera_scraper_poll_event(void* handle) {
    auto* h = static_cast<ScraperHandle*>(handle);
    if (!h) return nullptr;
    thread_local std::string out;  // Dart FFI 立即拷贝
    if (h->events.pop(out)) return out.c_str();
    return nullptr;
}

/// 销毁句柄：取消 + 等待工作线程结束 + 释放资源。
ARCHOERA_SCRAPER_API void archoera_scraper_destroy(void* handle) {
    auto* h = static_cast<ScraperHandle*>(handle);
    if (!h) return;
    if (h->running.load()) {
        scraper::cancelFlag().store(true, std::memory_order_relaxed);
    }
    // 无论是否 running，worker 线程都必须在析构前 join（std::thread 析构
    // 时 joinable 未 join 会 std::terminate）。
    if (h->worker.joinable()) h->worker.join();
    h->engine.reset();
    delete h;
}

} // extern "C"
