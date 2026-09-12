// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Archoera 刮削器 FFI 库（C ABI）
///
/// 复用 Archoera 刮削引擎（header-only ScraperEngine），通过事件队列与宿主通信，
/// 避免进程 spawn 与本地端口：
///   - 状态/进度经事件队列上报：阻塞等待（archoera_scraper_wait_event，默认）或
///     轮询（archoera_scraper_poll_event，调试/回退）——wait 语义对齐音频引擎
///     archoera_mediaengine_wait_event（事件驱动推送，空闲零唤醒）
///   - 队列模式取曲目走内存表注入（archoera_scraper_enqueue），无 HTTP
///   - 引擎在独立 pthread 中执行（Dart VM 不向其发送中断信号，网络 IO 安全）
///
/// 生命周期（单实例语义；cancelFlag 为全局共享，勿并发多 handle）：
///   handle = archoera_scraper_create(configJson)
///   archoera_scraper_enqueue(handle, trackJson) × N   （队列模式可选）
///   archoera_scraper_run(handle)                      （后台线程执行）
///   阻塞 archoera_scraper_wait_event(handle,buf,cap,timeout) → >0/0/-1
///      （或轮询 archoera_scraper_poll_event(handle) → JSON | NULL）
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
#include <chrono>
#include <deque>
#include <filesystem>
#include <memory>
#include <system_error>
#include <unordered_map>
#include <stdexcept>
#include <cctype>
#include <algorithm>

using json = nlohmann::json;
namespace scraper = archoera::scraper;

#ifdef _WIN32
#define ARCHOERA_SCRAPER_API __declspec(dllexport)
#else
#define ARCHOERA_SCRAPER_API
#endif

extern "C" {

/// 事件队列：固定容量环形缓冲（互斥保护）+ 阻塞等待（wait_event 语义）。
///
/// 同步模型对齐音频引擎 mediaengine_lib.c 的 wait_event/condvar/destroy：
///   - push：事件入队后 signal——唤醒阻塞在 wait 的接收线程；**队列满时丢最旧
///     保留最新**（进度事件是幂等的「最新状态」语义，终态 done/empty/error
///     必在队尾，绝不能因满被丢弃——否则宿主永远等不到终态）；
///   - wait：有事件立即 pop；无事件在条件变量上睡眠（事件低频，空闲零唤醒）；
///     支持限时（timeout_ms>=0，超时返 0）与永久（<0）等待；
///   - destroyed_：destroy 置位并 broadcast——唤醒全部 wait 立即返 -1，
///     此后 push 不再入队、wait 不再交付事件（stop 后的残留事件被丢弃）；
///   - waiters_ / drainCv_：destroy 等在 wait 内的调用方退出（waiters_ 归零）
///     后才释放句柄内存——wait_event 与 destroy 可在不同线程并发调用，无 UAF。
class EventQueue {
public:
    explicit EventQueue(size_t cap) : cap_(cap) {}

    bool push(std::string&& ev) {
        std::lock_guard<std::mutex> lk(mu_);
        if (destroyed_) return false;          // 销毁后不再入队
        if (q_.size() >= cap_) q_.pop_front(); // 满 → 丢最旧（进度帧），保最新
        q_.push_back(std::move(ev));
        cv_.notify_one();  // 唤醒阻塞中的 wait
        return true;
    }

    /// 非阻塞取一条（poll_event 回退）；空返回 false
    bool pop(std::string& out) {
        std::lock_guard<std::mutex> lk(mu_);
        if (q_.empty()) return false;
        out = std::move(q_.front());
        q_.pop_front();
        return true;
    }

    /// 阻塞取一条。返回：>0 事件已写入 out；0 超时无事件；-1 销毁已开始。
    /// timeout_ms < 0 永久等待；>= 0 最多等该毫秒（超时返 0）。
    int wait(std::string& out, int timeout_ms) {
        std::unique_lock<std::mutex> lk(mu_);
        ++waiters_;
        const bool timed = (timeout_ms >= 0);
        std::chrono::steady_clock::time_point deadline;
        if (timed) {
            deadline = std::chrono::steady_clock::now()
                       + std::chrono::milliseconds(timeout_ms);
        }
        int r = 0;
        for (;;) {
            if (destroyed_) { r = -1; break; }  // destroy 已开始：不再交付事件
            if (!q_.empty()) {
                out = std::move(q_.front());
                q_.pop_front();
                r = 1;
                break;
            }
            if (timed) {
                if (std::chrono::steady_clock::now() >= deadline) {
                    r = 0;
                    break;
                }
                cv_.wait_until(lk, deadline);
            } else {
                cv_.wait(lk);
            }
        }
        if (--waiters_ == 0) drainCv_.notify_one();  // 通知 destroy 的 drain 等待
        return r;
    }

    /// destroy 启动：置销毁标志并唤醒全部阻塞中的 wait（立即返 -1）。
    void beginDestroy() {
        std::lock_guard<std::mutex> lk(mu_);
        destroyed_ = true;
        cv_.notify_all();
    }

    /// destroy 收尾：等仍在 wait 内的调用方退出（看到 destroyed → -1 后自行
    /// 归还）。有界等待作防御兜底——正常 wait 见 destroyed_ 即返回，只差调度。
    void drainWaiters() {
        std::unique_lock<std::mutex> lk(mu_);
        if (waiters_ == 0) return;
        auto deadline = std::chrono::steady_clock::now()
                        + std::chrono::seconds(2);
        while (waiters_ > 0) {
            if (drainCv_.wait_until(lk, deadline) == std::cv_status::timeout) {
                break;  // 异常调用方不归还也不永久挂 destroy
            }
        }
    }

private:
    size_t cap_;
    std::deque<std::string> q_;
    std::mutex mu_;
    std::condition_variable cv_;
    std::condition_variable drainCv_;
    bool destroyed_ = false;
    int waiters_ = 0;
};

struct ScraperHandle {
    scraper::ScraperConfig cfg;
    std::unique_ptr<scraper::ScraperEngine> engine;   // 在 run 线程内构造
    std::thread worker;
    std::atomic<bool> done{false};
    std::atomic<bool> running{false};
    bool daemonMode = false;
    bool organizeMode = false;       // 仅目录整理（不联网、不写标签，按模板移动文件）
    std::string organizeTargetDir;   // 整理目标目录（空 → error）
    std::string organizePattern;     // 整理模板（见 runOrganize 默认值）
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
    h->organizeMode = (mode == "organize");
    h->interval = parseInt(j, "interval", 60);
    h->organizeTargetDir = parseStr(j, "organizeTargetDir", "");
    h->organizePattern = parseStr(j, "organizePattern", "");

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
// 仅目录整理（organize：不联网、不写标签，按模板把文件移动到目标目录树）
// 语义：
//   - 模板只决定「目录层级」，文件始终保留原始 basename（不改名）；
//   - 模板末段若形如文件名（含扩展）则视为文件名模板丢弃，仅取目录段；
//   - 目标已存在冲突追加 " (2)" " (3)"…，极端情况加时间戳；
//   - 移动失败（跨设备等）回退复制+删除源；不清理源目录。
// ---------------------------------------------------------------------------

namespace fs = std::filesystem;

/// 整理默认模板。
static const char* kOrganizeDefaultPattern = "{artist}/{album}/{track}. {title}.{ext}";

/// 清理路径段：去控制字符/非法字符、压缩空白、去首尾空白与点、限长。
static std::string orgSanitize(std::string s) {
    s.erase(std::remove_if(s.begin(), s.end(), [](unsigned char c) { return c < 0x20; }),
            s.end());
    for (char& c : s) {
        if (c == '/' || c == '\\' || c == ':' || c == '*' || c == '?' ||
            c == '"' || c == '<' || c == '>' || c == '|') {
            c = '_';
        }
    }
    std::string out;
    bool lastSpace = false;
    for (char c : s) {
        if (std::isspace(static_cast<unsigned char>(c))) {
            if (!lastSpace && !out.empty()) out += ' ';
            lastSpace = true;
        } else {
            out += c;
            lastSpace = false;
        }
    }
    while (!out.empty() && out.front() == '.') out.erase(out.begin());
    while (!out.empty() && out.back() == '.') out.pop_back();
    if (out.size() > 200) out = out.substr(0, 200);
    if (out.empty()) out = "Unknown";
    return out;
}

/// 编号两位补零（<=0 → 空串，模板中该段被过滤）。
static std::string orgPad(int n) {
    if (n <= 0) return "";
    char buf[32];
    std::snprintf(buf, sizeof(buf), "%02d", n);
    return buf;
}

/// 由模板 + 标签渲染目标「目录」段列表（末段若像文件名则剥离）。
static std::vector<std::string> orgBuildDirSegments(const std::string& pattern,
                                                     const scraper::TrackInfo& t,
                                                     const std::string& ext) {
    const std::string artist =
        orgSanitize(t.albumArtist.empty() ? (t.artist.empty() ? "Unknown Artist" : t.artist)
                                          : t.albumArtist);
    const std::string album = orgSanitize(t.album.empty() ? "Unknown Album" : t.album);
    const std::string genre = orgSanitize(t.genre.empty() ? "Unknown Genre" : t.genre);
    const std::string year = t.year > 0 ? std::to_string(t.year) : "";
    const std::string disc = orgPad(t.discNumber);
    const std::string track = orgPad(t.trackNumber);
    const std::string title = orgSanitize(t.title.empty() ? "Unknown Title" : t.title);

    std::string result = pattern;
    const char* kTokens[][2] = {
        {"{albumArtist}", artist.c_str()}, {"{artist}", artist.c_str()},
        {"{album}", album.c_str()},        {"{genre}", genre.c_str()},
        {"{year}", year.c_str()},          {"{disc}", disc.c_str()},
        {"{track}", track.c_str()},        {"{title}", title.c_str()},
        {"{ext}", ext.c_str()},
    };
    // 先替换长 token（albumArtist）再替换 artist，避免部分匹配。
    for (const auto& kv : kTokens) {
        size_t pos = 0;
        while ((pos = result.find(kv[0], pos)) != std::string::npos) {
            result.replace(pos, std::strlen(kv[0]), kv[1]);
            pos += std::strlen(kv[1]);
        }
    }

    std::vector<std::string> segments;
    std::string cur;
    for (char c : result) {
        if (c == '/' || c == '\\') {
            if (!cur.empty()) segments.push_back(cur);
            cur.clear();
        } else {
            cur += c;
        }
    }
    if (!cur.empty()) segments.push_back(cur);

    if (segments.empty()) return segments;
    // 末段形如文件（含扩展点且扩展部分为字母数字）→ 视为文件名模板段，丢弃。
    const std::string last = segments.back();
    const size_t dot = last.find_last_of('.');
    if (dot != std::string::npos && dot + 1 < last.size()) {
        bool alnum = true;
        for (size_t i = dot + 1; i < last.size(); ++i) {
            if (!std::isalnum(static_cast<unsigned char>(last[i]))) { alnum = false; break; }
        }
        if (alnum) segments.pop_back();
    }
    return segments;
}

/// 扩展名（小写、无点；识别不到返回空串）。
static std::string orgFileExt(const std::string& path) {
    const size_t dot = path.find_last_of('.');
    if (dot == std::string::npos || dot + 1 >= path.size()) return "";
    std::string ext = path.substr(dot + 1);
    std::transform(ext.begin(), ext.end(), ext.begin(), ::tolower);
    return ext;
}

/// 目标存在冲突则追加序号；返回最终 dest（含目录创建）。
static std::filesystem::path orgResolveDest(const std::filesystem::path& dest) {
    std::error_code ec;
    if (!fs::exists(dest, ec)) return dest;
    ec.clear();
    const std::string base = scraper::pathToUtf8(dest.stem());
    const std::string ext = scraper::pathToUtf8(dest.extension());
    for (int i = 2; i <= 999; ++i) {
        fs::path cand = dest.parent_path() /
                        scraper::utf8ToPath(base + " (" + std::to_string(i) + ")" + ext);
        if (!fs::exists(cand, ec)) return cand;
        ec.clear();
    }
    // 极端情况：附加时间戳
    return dest.parent_path() /
           scraper::utf8ToPath(
               base + "_" + std::to_string(
                                std::chrono::duration_cast<std::chrono::milliseconds>(
                                    std::chrono::system_clock::now().time_since_epoch())
                                    .count()) +
               ext);
}

/// 执行仅目录整理；事件（progress/done/empty/error）写入 handle 事件队列。
static void runOrganize(ScraperHandle* h) {
    const auto& dirs = h->cfg.scrapeDirs;
    const std::string target = h->organizeTargetDir;
    std::string pattern = h->organizePattern.empty() ? kOrganizeDefaultPattern
                                                     : h->organizePattern;

    auto pushEvent = [h](json ev) { h->events.push(ev.dump()); };

    try {
        if (dirs.empty() || target.empty()) {
            pushEvent({{"type", "error"},
                       {"message", "整理目录与目标目录不能为空（config.dirs / organizeTargetDir）"}});
            return;
        }
        std::error_code ec;
        const fs::path targetRoot = fs::absolute(scraper::utf8ToPath(target), ec);
        if (ec || !fs::is_directory(targetRoot, ec)) {
            pushEvent({{"type", "error"},
                       {"message", "整理目标目录不存在或不可访问: " + target}});
            return;
        }
        fs::create_directories(targetRoot, ec);  // 幂等，确保可写

        // 扫描源目录读取标签（含文件名优先回退，忽略 readTags 失败的文件）
        scraper::FileScanner scanner(h->cfg);
        auto tracks = scanner.scanDirs(dirs);
        const int total = static_cast<int>(tracks.size());
        if (tracks.empty()) {
            pushEvent({{"type", "empty"}, {"message", "目录中无音频文件"}});
            pushEvent({{"type", "done"},
                       {"total", 0}, {"scraped", 0}, {"success", 0}, {"failed", 0},
                       {"skipped", 0}, {"notFound", 0}, {"canceled", false}});
            return;
        }

        pushEvent({{"type", "progress"},
                   {"total", total}, {"scraped", 0}, {"success", 0}, {"failed", 0},
                   {"skipped", 0}, {"notFound", 0},
                   {"current", "准备整理 " + std::to_string(total) + " 个文件"}});

        int moved = 0, skipped = 0, failed = 0;
        bool canceled = false;
        json failures = json::array();

        for (int i = 0; i < total; ++i) {
            if (scraper::cancelFlag().load(std::memory_order_relaxed)) {
                canceled = true;
                break;
            }
            const scraper::TrackInfo& t = tracks[i];
            const std::string from = t.filePath;
            if (from.empty()) { failed++; continue; }

            const std::string ext = orgFileExt(from);
            auto segs = orgBuildDirSegments(pattern, t, ext);
            const fs::path fromPath = scraper::utf8ToPath(from);
            fs::path destDir = targetRoot;
            for (const auto& seg : segs) destDir /= scraper::utf8ToPath(seg);
            fs::path dest = destDir / fromPath.filename();
            std::error_code ec2;
            // 规范化比较：已在目标位置则跳过
            fs::path canonFrom = fs::absolute(fromPath, ec2);
            fs::path canonTo = fs::absolute(dest, ec2);
            if (ec2) { failed++; continue; }
            if (canonFrom == canonTo) { skipped++; }
            else {
                dest = orgResolveDest(dest);
                fs::create_directories(dest.parent_path(), ec2);
                if (ec2) {
                    failed++;
                    failures.push_back({{"file", from},
                                        {"reason", "创建目录失败: " + ec2.message()}});
                } else {
                    std::error_code ec3;
                    fs::rename(canonFrom, dest, ec3);
                    if (ec3) {
                        // 跨设备（EXDEV）等 → 复制 + 删除源
                        std::error_code ecCopy, ecDel;
                        fs::copy_file(canonFrom, dest,
                                      fs::copy_options::overwrite_existing, ecCopy);
                        if (!ecCopy) {
                            fs::remove(canonFrom, ecDel);
                            if (ecDel) {
                                failed++;
                                failures.push_back(
                                    {{"file", from},
                                     {"reason", "复制后删除源失败: " + ecDel.message()}});
                            } else {
                                moved++;
                            }
                        } else {
                            failed++;
                            failures.push_back({{"file", from},
                                                {"reason", "移动失败: " + ecCopy.message()}});
                        }
                    } else {
                        moved++;
                    }
                }
            }

            pushEvent({{"type", "progress"},
                       {"total", total}, {"scraped", i + 1}, {"success", moved},
                       {"failed", failed}, {"skipped", skipped}, {"notFound", 0},
                       {"current", scraper::pathToUtf8(fromPath.filename())}});
        }

        // 终态 done 事件的 failures 只保留前 100 条，防止整批全失败时事件 JSON
        // 过大（宿主事件缓冲固定容量，超长终态 JSON 被截断 → 解析失败 = 会话悬挂）。
        if (failures.size() > 100) {
            json capped = json::array();
            for (int k = 0; k < 100; ++k) capped.push_back(failures[k]);
            failures = std::move(capped);
        }

        pushEvent({{"type", "done"},
                   {"total", total}, {"scraped", moved + skipped + failed},
                   {"success", moved},
                   {"failed", failed}, {"skipped", skipped}, {"notFound", 0},
                   {"canceled", canceled}, {"failures", failures}});
    } catch (const std::exception& e) {
        pushEvent({{"type", "error"}, {"message", std::string("仅目录整理失败: ") + e.what()}});
    } catch (...) {
        pushEvent({{"type", "error"}, {"message", "仅目录整理失败: unknown fatal error"}});
    }
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
        // 上一轮取消可能残留全局取消标志 → 新一轮开始时复位（engine/organize 均依赖）
        scraper::cancelFlag().store(false, std::memory_order_relaxed);

        if (h->organizeMode) {
            // 仅目录整理：独立路径，无需构造 ScraperEngine（不需要 scraper-state.db / 网络）
            runOrganize(h);
            h->running.store(false);
            h->done.store(true);
            return;
        }

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

/// 阻塞取一条事件 JSON（事件驱动推送；Dart 事件泵在独立接收 isolate 中调用，
/// 替代「Dart 定时 poll_event 轮询」——事件低频，空闲零唤醒、零轮询开销）。
///
/// @param handle     刮削器句柄
/// @param buf        事件缓冲（调用方分配）
/// @param cap        缓冲容量
/// @param timeout_ms 等待上限（毫秒）：<0 永久等待；>=0 最多等该毫秒，超时返 0。
///
/// @return >0 事件字节长度（写入 buf，'\0' 结尾；每行一条 JSON 事件）；
///         0 超时无事件；-1 已销毁（destroy 已开始，唤醒等待者并告知——调用方
///         应退出取事件循环，勿再对本句柄调用任何函数）。
///
/// 并发/生命周期契约（对齐 audio-engine 的 archoera_mediaengine_wait_event）：
///   - 有事件立即返回（事件入队即唤醒，非轮询）；
///   - destroy 会唤醒所有阻塞中的 wait_event（返回 -1），并在释放句柄前等
///     wait_event 内的调用方退出（waiters drain）——wait_event 与 destroy 可在
///     不同线程并发调用；同一句柄建议单线程阻塞取事件（Dart 事件泵即单接收
///     isolate）；
///   - 销毁开始后 wait_event 不再交付事件（残留事件被丢弃）；
///   - 保留 archoera_scraper_poll_event 兼容（轮询调试回退用）。
ARCHOERA_SCRAPER_API int archoera_scraper_wait_event(void* handle, char* buf,
                                                     int cap, int timeout_ms) {
    auto* h = static_cast<ScraperHandle*>(handle);
    if (!h || !buf || cap <= 0) return 0;
    std::string ev;
    int r = h->events.wait(ev, timeout_ms);
    if (r <= 0) return r;  // 0 超时 / -1 已销毁
    size_t n = ev.size();
    if (n > static_cast<size_t>(cap) - 1) n = static_cast<size_t>(cap) - 1;
    memcpy(buf, ev.data(), n);
    buf[n] = '\0';
    return static_cast<int>(n);
}

/// 销毁句柄：置销毁标志 + 唤醒阻塞中的 wait_event → 取消 + 等待工作线程结束
/// → 等 wait_event 内调用方退出（drain）→ 释放资源。
ARCHOERA_SCRAPER_API void archoera_scraper_destroy(void* handle) {
    auto* h = static_cast<ScraperHandle*>(handle);
    if (!h) return;
    if (h->running.load()) {
        scraper::cancelFlag().store(true, std::memory_order_relaxed);
    }
    // 1) 置销毁标志并唤醒全部阻塞中的 wait_event（立即返 -1）。先于 join：
    //    阻塞的接收线程尽快退场，不被慢 join（网络 IO 中断）拖住。
    h->events.beginDestroy();
    // 2) join worker 线程（无论是否 running，joinable 未 join 会 std::terminate）
    if (h->worker.joinable()) h->worker.join();
    h->engine.reset();
    // 3) drain：等仍在 wait_event 内的调用方退出（看到 destroyed → -1 后自行
    //    归还，wait_event 已不触碰本句柄）才允许释放内存。
    h->events.drainWaiters();
    delete h;
}

} // extern "C"
