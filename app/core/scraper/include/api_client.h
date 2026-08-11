#pragma once

/// Archoera 刮削器 —— 多源 API 客户端（header-only）
///
/// 包含：
/// - MusicBrainzClient: 查询元数据（MBID / ISRC / genre / composer 等）
/// - CoverArtArchiveClient: 获取专辑封面
/// - LrclibClient: 获取歌词
/// - DeezerClient / ItunesClient: 西方音乐补充源
/// - NeteaseClient / QQMusicClient / KugouClient / KuwoClient / MiguClient:
///   中文音乐源（多源并发 + 评分匹配），对中文音乐匹配率更高

#include "scraper.h"
#include <curl/curl.h>
#include <nlohmann/json.hpp>
#include <openssl/evp.h>
#include <openssl/bn.h>
#include <openssl/rand.h>
#include <stdexcept>
#include <thread>
#include <cstdio>
#include <chrono>
#include <iostream>
#include <algorithm>
#include <cctype>
#include <vector>
#include <future>
#include <mutex>
#include <queue>
#include <functional>
#include <condition_variable>
#include <type_traits>
#include <ctime>
#include <unordered_map>

#ifdef _WIN32
// MSVC 无 POSIX gmtime_r / popen / pclose，映射到 _s / _p 变体
#define gmtime_r(tp, tm) gmtime_s((tm), (tp))
#define popen _popen
#define pclose _pclose
#endif

namespace archoera::scraper {

using json = nlohmann::json;

inline static size_t writeCb(char* ptr, size_t size, size_t nmemb, void* userdata) {
    auto* buf = static_cast<std::string*>(userdata);
    buf->append(ptr, size * nmemb);
    return size * nmemb;
}

inline static size_t writeBinaryCb(char* ptr, size_t size, size_t nmemb, void* userdata) {
    auto* buf = static_cast<std::vector<uint8_t>*>(userdata);
    buf->insert(buf->end(), reinterpret_cast<uint8_t*>(ptr), 
                reinterpret_cast<uint8_t*>(ptr) + size * nmemb);
    return size * nmemb;
}

/// 从图片二进制数据头部检测 MIME 类型
inline static std::string detectImageMime(const std::vector<uint8_t>& data) {
    if (data.size() < 4) return "image/jpeg";
    if (data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF) return "image/jpeg";
    if (data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4E && data[3] == 0x47) return "image/png";
    if (data[0] == 0x47 && data[1] == 0x49 && data[2] == 0x46 && data[3] == 0x38) return "image/gif";
    if (data.size() >= 12 && data[0] == 0x52 && data[1] == 0x49 && data[2] == 0x46 && data[3] == 0x46 &&
        data[8] == 0x57 && data[9] == 0x45 && data[10] == 0x42 && data[11] == 0x50) return "image/webp";
    return "image/jpeg";
}

/// 归一化字符串：小写 + 移除非字母数字 ASCII 字符 + 保留 UTF-8 多字节字符
inline static std::string normalize(const std::string& s) {
    std::string out;
    out.reserve(s.size());
    for (size_t i = 0; i < s.size(); ) {
        unsigned char c = static_cast<unsigned char>(s[i]);
        if (c < 0x80) {
            if (std::isalnum(c)) {
                out.push_back(static_cast<char>(std::tolower(c)));
            }
            ++i;
        } else {
            size_t charLen = 1;
            if ((c & 0xE0) == 0xC0) charLen = 2;
            else if ((c & 0xF0) == 0xE0) charLen = 3;
            else if ((c & 0xF8) == 0xF0) charLen = 4;
            for (size_t k = 0; k < charLen && i < s.size(); ++k, ++i) {
                out.push_back(s[i]);
            }
        }
    }
    return out;
}

/// 计算编辑距离相似度（0~1）
inline static double similarity(const std::string& a, const std::string& b) {
    std::string na = normalize(a);
    std::string nb = normalize(b);
    if (na.empty() && nb.empty()) return 1.0;
    if (na.empty() || nb.empty()) return 0.0;
    if (na == nb) return 1.0;
    if (na.find(nb) != std::string::npos || nb.find(na) != std::string::npos) return 0.85;

    std::vector<int> prev(nb.size() + 1), curr(nb.size() + 1);
    for (size_t j = 0; j <= nb.size(); ++j) prev[j] = static_cast<int>(j);
    for (size_t i = 1; i <= na.size(); ++i) {
        curr[0] = static_cast<int>(i);
        for (size_t j = 1; j <= nb.size(); ++j) {
            int cost = (na[i - 1] == nb[j - 1]) ? 0 : 1;
            curr[j] = std::min({prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost});
        }
        std::swap(prev, curr);
    }
    int dist = prev[nb.size()];
    int maxLen = static_cast<int>(std::max(na.size(), nb.size()));
    return maxLen > 0 ? 1.0 - static_cast<double>(dist) / maxLen : 0.0;
}

/// URL 编码（curl_easy_escape 包装）
inline static std::string urlEncode(const std::string& raw) {
    CURL* curl = curl_easy_init();
    if (!curl) return raw;
    char* escaped = curl_easy_escape(curl, raw.c_str(), raw.size());
    std::string result(escaped ? escaped : raw);
    curl_free(escaped);
    curl_easy_cleanup(curl);
    return result;
}

/// MusicBrainz API 客户端
class MusicBrainzClient {
public:
    explicit MusicBrainzClient(const ScraperConfig& cfg)
        : cfg_(cfg), lastReq_(std::chrono::steady_clock::now() - std::chrono::hours(1))
    {
        curl_ = curl_easy_init();
        if (!curl_) throw std::runtime_error("curl_easy_init 失败");
    }

    ~MusicBrainzClient() {
        if (curl_) curl_easy_cleanup(curl_);
    }

    MusicBrainzClient(const MusicBrainzClient&) = delete;
    MusicBrainzClient& operator=(const MusicBrainzClient&) = delete;

    /// 查询曲目元数据（按 artist + title）
    ScrapeResult queryRecording(const TrackInfo& track) {
        rateLimit();
        ScrapeResult result;
        result.trackId = track.id;

        std::string url = "https://musicbrainz.org/ws/2/recording/?query=recording:\"" +
            urlEncode(track.title) + "\"%20AND%20artist:\"" +
            urlEncode(track.artist) + "\"&fmt=json&limit=1";

        std::string body;
        long code = 0;
        if (httpGet(url, body, &code) && code == 200) {
            try {
                auto j = json::parse(body);
                if (j.contains("recordings") && !j["recordings"].empty()) {
                    auto& rec = j["recordings"][0];
                    if (rec.contains("id")) result.mbid = rec["id"].get<std::string>();
                    if (rec.contains("isrcs") && !rec["isrcs"].empty()) {
                        result.isrc = rec["isrcs"][0].get<std::string>();
                    }
                    if (rec.contains("releases") && !rec["releases"].empty()) {
                        auto& rel = rec["releases"][0];
                        if (rel.contains("release-group") && rel["release-group"].contains("id")) {
                            result.albumMbid = rel["release-group"]["id"].get<std::string>();
                        }
                    }
                    result.scrapedSources.push_back("musicbrainz");
                }
            } catch (const json::exception& e) {
                lastError_ = std::string("JSON 解析失败: ") + e.what();
            }
        } else {
            lastError_ = "MusicBrainz 查询失败: HTTP " + std::to_string(code);
        }

        // 如有 MBID，查询详细元数据
        if (result.mbid) {
            rateLimit();
            std::string detailUrl = "https://musicbrainz.org/ws/2/recording/" +
                *result.mbid + "?inc=genres+labels+artist-credits+releases+isrcs+artist-rels+recording-rels&fmt=json";
            std::string detailBody;
            long detailCode = 0;
            if (httpGet(detailUrl, detailBody, &detailCode) && detailCode == 200) {
                try {
                    auto j = json::parse(detailBody);
                    
                    // 流派
                    if (j.contains("genres") && !j["genres"].empty()) {
                        result.genre = j["genres"][0]["name"].get<std::string>();
                    }
                    
                    // 唱片公司
                    if (j.contains("releases") && !j["releases"].empty()) {
                        auto& rel = j["releases"][0];
                        if (rel.contains("label-info") && !rel["label-info"].empty()) {
                            if (rel["label-info"][0].contains("label") &&
                                rel["label-info"][0]["label"].contains("name")) {
                                result.label = rel["label-info"][0]["label"]["name"].get<std::string>();
                            }
                        }
                        
                        // 年份
                        if (rel.contains("date") && rel["date"].is_string()) {
                            std::string dateStr = rel["date"].get<std::string>();
                            if (dateStr.length() >= 4) {
                                try {
                                    result.year = std::stoi(dateStr.substr(0, 4));
                                } catch (...) {}
                            }
                        }
                        
                        // 曲目编号
                        if (rel.contains("media") && rel["media"].is_array() && !rel["media"].empty()) {
                            auto& media = rel["media"][0];
                            // 碟片总数
                            result.discTotal = static_cast<int>(rel["media"].size());
                            if (media.contains("position")) {
                                result.discNumber = media["position"].get<int>();
                            }
                            if (media.contains("track-count")) {
                                result.trackTotal = media["track-count"].get<int>();
                            }
                            if (media.contains("tracks") && media["tracks"].is_array()) {
                                for (auto& t : media["tracks"]) {
                                    if (t.contains("recording") && t["recording"].contains("id") &&
                                        t["recording"]["id"] == *result.mbid) {
                                        if (t.contains("position")) {
                                            result.trackNumber = t["position"].get<int>();
                                        }
                                        break;
                                    }
                                }
                            }
                        }
                    }
                    
                    // 艺术家 MBID
                    if (j.contains("artist-credit") && !j["artist-credit"].empty()) {
                        if (j["artist-credit"][0].contains("artist") &&
                            j["artist-credit"][0]["artist"].contains("id")) {
                            result.artistMbid = j["artist-credit"][0]["artist"]["id"].get<std::string>();
                        }
                        
                        // 艺术家名称（修正）
                        if (j["artist-credit"][0].contains("name")) {
                            result.artist = j["artist-credit"][0]["name"].get<std::string>();
                        }
                    }
                    
                    // 作曲家（从 artist-rels 中提取）
                    if (j.contains("relations") && j["relations"].is_array()) {
                        for (auto& rel : j["relations"]) {
                            if (rel.contains("type") && rel["type"] == "composer" &&
                                rel.contains("artist") && rel["artist"].contains("name")) {
                                result.composer = rel["artist"]["name"].get<std::string>();
                                break;
                            }
                        }
                    }
                    
                } catch (const json::exception& e) {
                    lastError_ = std::string("详细元数据解析失败: ") + e.what();
                }
            }
        }

        // 校验 MusicBrainz 返回结果是否与原始文件元数据匹配
        // 如果不匹配，保留 MBID/ISRC 等标识符，但清空可能被错误覆盖的元数据字段，
        // 避免将不相关音乐的封面/歌词/流派写入用户文件。
        if (result.mbid) {
            std::string mbArtist = result.artist.value_or("");
            std::string mbTitle = result.title.value_or("");
            // MB 未返回 artist/title 时，用文件名解析值回填，防止下游源
            // （Deezer/iTunes）通过 mergeIdentity 填入不相关结果（如机翻名）。
            bool artistOK;
            if (mbArtist.empty()) {
                result.artist = track.artist;
                artistOK = true;
            } else {
                artistOK = isSimilar(track.artist, mbArtist) ||
                           (!track.albumArtist.empty() && isSimilar(track.albumArtist, mbArtist));
            }
            bool titleOK;
            if (mbTitle.empty()) {
                result.title = track.title;
                titleOK = true;
            } else {
                titleOK = isSimilar(track.title, mbTitle);
            }
            if (!artistOK || !titleOK) {
                std::cerr << "[scraper]   ⚠ MusicBrainz 匹配结果可疑，放弃覆盖元数据: "
                          << "原始=" << track.artist << " - " << track.title
                          << ", MB=" << mbArtist << " - " << mbTitle << std::endl;
                // 仅保留 MusicBrainz 标识符，其余元数据字段置空
                result.title.reset();
                result.artist.reset();
                result.album.reset();
                result.albumArtist.reset();
                result.composer.reset();
                result.genre.reset();
                result.label.reset();
                result.trackNumber.reset();
                result.discNumber.reset();
                result.year.reset();
                // 不获取封面和歌词，因为 release 可能不匹配
                result.albumMbid.reset();
            }
        }

        return result;
    }

    const std::string& lastError() const { return lastError_; }

    // rateLimit / httpGet 对外开放，供 MetadataResolver 指纹回退使用
    void rateLimit() {
        auto now = std::chrono::steady_clock::now();
        auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(now - lastReq_);
        if (elapsed.count() < cfg_.rateLimitMs) {
            std::this_thread::sleep_for(
                std::chrono::milliseconds(cfg_.rateLimitMs - elapsed.count()));
        }
        lastReq_ = std::chrono::steady_clock::now();
    }

    bool httpGet(const std::string& url, std::string& body, long* code) {
        body.clear();
        curl_easy_setopt(curl_, CURLOPT_URL, url.c_str());
        curl_easy_setopt(curl_, CURLOPT_WRITEFUNCTION, writeCb);
        curl_easy_setopt(curl_, CURLOPT_WRITEDATA, &body);
        curl_easy_setopt(curl_, CURLOPT_USERAGENT, cfg_.userAgent.c_str());
        curl_easy_setopt(curl_, CURLOPT_TIMEOUT_MS, cfg_.requestTimeoutMs);
        curl_easy_setopt(curl_, CURLOPT_FOLLOWLOCATION, 1L);

        CURLcode res = curl_easy_perform(curl_);
        if (code) curl_easy_getinfo(curl_, CURLINFO_RESPONSE_CODE, code);
        return res == CURLE_OK;
    }

 private:

    /// 判断两个字符串是否相似（阈值 0.65）
    static bool isSimilar(const std::string& a, const std::string& b) {
        return similarity(a, b) >= 0.65;
    }

    CURL* curl_ = nullptr;
    const ScraperConfig& cfg_;
    std::chrono::steady_clock::time_point lastReq_;
    std::string lastError_;
};

/// Cover Art Archive 客户端
class CoverArtArchiveClient {
public:
    explicit CoverArtArchiveClient(const ScraperConfig& cfg)
        : cfg_(cfg)
    {
        curl_ = curl_easy_init();
        if (!curl_) throw std::runtime_error("curl_easy_init 失败");
    }

    ~CoverArtArchiveClient() {
        if (curl_) curl_easy_cleanup(curl_);
    }

    CoverArtArchiveClient(const CoverArtArchiveClient&) = delete;
    CoverArtArchiveClient& operator=(const CoverArtArchiveClient&) = delete;

    /// 获取专辑封面
    bool fetchCover(const std::string& albumMbid, ScrapeResult& result) {
        std::string url = "https://coverartarchive.org/release/" + albumMbid + "/front";
        
        std::vector<uint8_t> data;
        long code = 0;
        if (httpGetBinary(url, data, &code) && code == 200 && !data.empty()) {
            result.coverData = std::move(data);
            result.coverMime = detectImageMime(result.coverData);
            std::cerr << "[scraper]   Cover Art Archive 封面下载成功: " << result.coverData.size()
                      << " bytes, mime=" << result.coverMime << std::endl;
            return true;
        }
        std::cerr << "[scraper]   Cover Art Archive 下载失败: HTTP " << code
                  << ", 数据大小=" << data.size() << std::endl;
        return false;
    }

    const std::string& lastError() const { return lastError_; }

private:
    bool httpGetBinary(const std::string& url, std::vector<uint8_t>& data, long* code) {
        data.clear();
        curl_easy_setopt(curl_, CURLOPT_URL, url.c_str());
        curl_easy_setopt(curl_, CURLOPT_WRITEFUNCTION, writeBinaryCb);
        curl_easy_setopt(curl_, CURLOPT_WRITEDATA, &data);
        curl_easy_setopt(curl_, CURLOPT_USERAGENT, cfg_.userAgent.c_str());
        curl_easy_setopt(curl_, CURLOPT_TIMEOUT_MS, cfg_.requestTimeoutMs);
        curl_easy_setopt(curl_, CURLOPT_FOLLOWLOCATION, 1L);

        CURLcode res = curl_easy_perform(curl_);
        if (code) curl_easy_getinfo(curl_, CURLINFO_RESPONSE_CODE, code);
        return res == CURLE_OK;
    }

    CURL* curl_ = nullptr;
    const ScraperConfig& cfg_;
    std::string lastError_;
};

/// LRCLIB 歌词客户端
class LrclibClient {
public:
    explicit LrclibClient(const ScraperConfig& cfg)
        : cfg_(cfg)
    {
        curl_ = curl_easy_init();
        if (!curl_) throw std::runtime_error("curl_easy_init 失败");
    }

    ~LrclibClient() {
        if (curl_) curl_easy_cleanup(curl_);
    }

    LrclibClient(const LrclibClient&) = delete;
    LrclibClient& operator=(const LrclibClient&) = delete;

    /// 获取歌词
    bool fetchLyrics(const std::string& artist, const std::string& title, 
                     const std::string& album, int durationSec, ScrapeResult& result) {
        std::string url = "https://lrclib.net/api/get";
        url += "?artist_name=" + urlEncode(artist);
        url += "&track_name=" + urlEncode(title);
        if (!album.empty()) {
            url += "&album_name=" + urlEncode(album);
        }
        if (durationSec > 0) {
            url += "&duration=" + std::to_string(durationSec);
        }

        std::string body;
        long code = 0;
        if (httpGet(url, body, &code) && code == 200) {
            try {
                auto j = json::parse(body);
                // 优先使用同步歌词，否则使用纯文本歌词
                if (j.contains("syncedLyrics") && j["syncedLyrics"].is_string() && 
                    !j["syncedLyrics"].get<std::string>().empty()) {
                    result.lyrics = j["syncedLyrics"].get<std::string>();
                    return true;
                }
                if (j.contains("plainLyrics") && j["plainLyrics"].is_string() &&
                    !j["plainLyrics"].get<std::string>().empty()) {
                    result.lyrics = j["plainLyrics"].get<std::string>();
                    return true;
                }
            } catch (const json::exception& e) {
                lastError_ = std::string("歌词 JSON 解析失败: ") + e.what();
            }
        }
        return false;
    }

    const std::string& lastError() const { return lastError_; }

private:
    bool httpGet(const std::string& url, std::string& body, long* code) {
        body.clear();
        curl_easy_setopt(curl_, CURLOPT_URL, url.c_str());
        curl_easy_setopt(curl_, CURLOPT_WRITEFUNCTION, writeCb);
        curl_easy_setopt(curl_, CURLOPT_WRITEDATA, &body);
        curl_easy_setopt(curl_, CURLOPT_USERAGENT, cfg_.userAgent.c_str());
        curl_easy_setopt(curl_, CURLOPT_TIMEOUT_MS, cfg_.requestTimeoutMs);
        curl_easy_setopt(curl_, CURLOPT_FOLLOWLOCATION, 1L);

        CURLcode res = curl_easy_perform(curl_);
        if (code) curl_easy_getinfo(curl_, CURLINFO_RESPONSE_CODE, code);
        return res == CURLE_OK;
    }

    CURL* curl_ = nullptr;
    const ScraperConfig& cfg_;
    std::string lastError_;
};

/// Deezer API 客户端（公开 API，无需 Key）
/// 用于：元数据补充、封面 fallback
class DeezerClient {
public:
    explicit DeezerClient(const ScraperConfig& cfg) : cfg_(cfg) {
        curl_ = curl_easy_init();
        if (!curl_) throw std::runtime_error("curl_easy_init 失败");
    }
    ~DeezerClient() { if (curl_) curl_easy_cleanup(curl_); }

    DeezerClient(const DeezerClient&) = delete;
    DeezerClient& operator=(const DeezerClient&) = delete;

    /// 按 artist + title 搜索曲目，填充元数据和封面 URL
    /// 返回是否找到可接受的匹配
    bool searchTrack(const std::string& artist, const std::string& title,
                     ScrapeResult& result, std::string& outCoverUrl) {
        outCoverUrl.clear();
        if (artist.empty() && title.empty()) return false;

        std::string q;
        if (!artist.empty()) q += "artist:\"" + artist + "\"";
        if (!artist.empty() && !title.empty()) q += " ";
        if (!title.empty()) q += "track:\"" + title + "\"";

        std::string url = "https://api.deezer.com/search/track?q=" + urlEncode(q) + "&limit=5";
        std::string body;
        long code = 0;
        if (!httpGet(url, body, &code) || code != 200) return false;

        try {
            auto j = json::parse(body);
            if (!j.contains("data") || j["data"].empty()) return false;

            // 文件名优先匹配：artist 与 title 必须分别达标，任一不匹配则舍弃
            // 权重评分仅用于同台竞技排序，不用于放行判断
            double bestScore = -1.0;
            json best;
            for (auto& item : j["data"]) {
                std::string dzArtist = item.contains("artist") && item["artist"].contains("name")
                                           ? item["artist"]["name"].get<std::string>()
                                           : "";
                std::string dzTitle = item.contains("title") ? item["title"].get<std::string>() : "";
                double artistSim = similarity(artist, dzArtist);
                double titleSim = similarity(title, dzTitle);
                if (artistSim < 0.5 || titleSim < 0.5) continue;  // 任一不匹配 → 舍弃
                double s = artistSim + titleSim;
                if (s > bestScore) {
                    bestScore = s;
                    best = item;
                }
            }
            if (bestScore < 0.0) return false;  // 无任何候选通过 artist+title 双门槛

            // 填充元数据
            if (best.contains("title")) result.title = best["title"].get<std::string>();
            if (best.contains("artist") && best["artist"].contains("name")) {
                result.artist = best["artist"]["name"].get<std::string>();
            }
            if (best.contains("album") && best["album"].contains("title")) {
                result.album = best["album"]["title"].get<std::string>();
            }
            if (best.contains("album") && best["album"].contains("cover_big")) {
                outCoverUrl = best["album"]["cover_big"].get<std::string>();
            } else if (best.contains("album") && best["album"].contains("cover")) {
                outCoverUrl = best["album"]["cover"].get<std::string>();
            }
            if (best.contains("track_position")) {
                result.trackNumber = best["track_position"].get<int>();
            }
            if (best.contains("disk_number")) {
                result.discNumber = best["disk_number"].get<int>();
            }
            // 年份（release_date 格式："2020-03-15"）
            if (best.contains("release_date") && best["release_date"].is_string()) {
                std::string rd = best["release_date"].get<std::string>();
                if (rd.length() >= 4) {
                    try { result.year = std::stoi(rd.substr(0, 4)); } catch (...) {}
                }
            }
            result.scrapedSources.push_back("deezer");
            return true;
        } catch (const json::exception& e) {
            lastError_ = std::string("Deezer JSON 解析失败: ") + e.what();
        }
        return false;
    }

    /// 下载封面图片
    bool fetchCover(const std::string& coverUrl, ScrapeResult& result) {
        if (coverUrl.empty()) return false;
        std::vector<uint8_t> data;
        long code = 0;
        if (httpGetBinary(coverUrl, data, &code) && code == 200 && !data.empty()) {
            result.coverData = std::move(data);
            result.coverMime = detectImageMime(result.coverData);
            std::cerr << "[scraper]   Deezer 封面下载成功: " << result.coverData.size()
                      << " bytes, mime=" << result.coverMime << std::endl;
            return true;
        }
        std::cerr << "[scraper]   Deezer 封面下载失败: HTTP " << code
                  << ", 数据大小=" << data.size() << std::endl;
        return false;
    }

    const std::string& lastError() const { return lastError_; }

private:
    bool httpGet(const std::string& url, std::string& body, long* code) {
        body.clear();
        curl_easy_setopt(curl_, CURLOPT_URL, url.c_str());
        curl_easy_setopt(curl_, CURLOPT_WRITEFUNCTION, writeCb);
        curl_easy_setopt(curl_, CURLOPT_WRITEDATA, &body);
        curl_easy_setopt(curl_, CURLOPT_USERAGENT, cfg_.userAgent.c_str());
        curl_easy_setopt(curl_, CURLOPT_TIMEOUT_MS, cfg_.requestTimeoutMs);
        curl_easy_setopt(curl_, CURLOPT_FOLLOWLOCATION, 1L);
        CURLcode res = curl_easy_perform(curl_);
        if (code) curl_easy_getinfo(curl_, CURLINFO_RESPONSE_CODE, code);
        return res == CURLE_OK;
    }

    bool httpGetBinary(const std::string& url, std::vector<uint8_t>& data, long* code) {
        data.clear();
        curl_easy_setopt(curl_, CURLOPT_URL, url.c_str());
        curl_easy_setopt(curl_, CURLOPT_WRITEFUNCTION, writeBinaryCb);
        curl_easy_setopt(curl_, CURLOPT_WRITEDATA, &data);
        curl_easy_setopt(curl_, CURLOPT_USERAGENT, cfg_.userAgent.c_str());
        curl_easy_setopt(curl_, CURLOPT_TIMEOUT_MS, cfg_.requestTimeoutMs);
        curl_easy_setopt(curl_, CURLOPT_FOLLOWLOCATION, 1L);
        CURLcode res = curl_easy_perform(curl_);
        if (code) curl_easy_getinfo(curl_, CURLINFO_RESPONSE_CODE, code);
        return res == CURLE_OK;
    }

    CURL* curl_ = nullptr;
    const ScraperConfig& cfg_;
    std::string lastError_;
};

/// iTunes Search API 客户端（公开 API，无需 Key）
/// 用于：元数据补充、封面 fallback
class ItunesClient {
public:
    explicit ItunesClient(const ScraperConfig& cfg) : cfg_(cfg) {
        curl_ = curl_easy_init();
        if (!curl_) throw std::runtime_error("curl_easy_init 失败");
    }
    ~ItunesClient() { if (curl_) curl_easy_cleanup(curl_); }

    ItunesClient(const ItunesClient&) = delete;
    ItunesClient& operator=(const ItunesClient&) = delete;

    bool searchTrack(const std::string& artist, const std::string& title,
                     ScrapeResult& result, std::string& outCoverUrl) {
        outCoverUrl.clear();
        if (artist.empty() && title.empty()) return false;

        std::string term = artist + " " + title;
        std::string url = "https://itunes.apple.com/search?term=" + urlEncode(term)
                        + "&entity=song&limit=10";
        std::string body;
        long code = 0;
        if (!httpGet(url, body, &code) || code != 200) return false;

        try {
            auto j = json::parse(body);
            if (!j.contains("results") || j["results"].empty()) return false;

            // 文件名优先匹配：artist 与 title 必须分别达标，任一不匹配则舍弃
            double bestScore = -1.0;
            json best;
            for (auto& item : j["results"]) {
                std::string itArtist = item.contains("artistName") ? item["artistName"].get<std::string>() : "";
                std::string itTitle = item.contains("trackName") ? item["trackName"].get<std::string>() : "";
                double artistSim = similarity(artist, itArtist);
                double titleSim = similarity(title, itTitle);
                if (artistSim < 0.5 || titleSim < 0.5) continue;  // 任一不匹配 → 舍弃
                double s = artistSim + titleSim;
                if (s > bestScore) {
                    bestScore = s;
                    best = item;
                }
            }
            if (bestScore < 0.0) return false;  // 无任何候选通过 artist+title 双门槛

            if (best.contains("trackName")) result.title = best["trackName"].get<std::string>();
            if (best.contains("artistName")) result.artist = best["artistName"].get<std::string>();
            if (best.contains("collectionName")) result.album = best["collectionName"].get<std::string>();
            if (best.contains("primaryGenreName")) result.genre = best["primaryGenreName"].get<std::string>();
            if (best.contains("trackNumber")) result.trackNumber = best["trackNumber"].get<int>();
            if (best.contains("discNumber")) result.discNumber = best["discNumber"].get<int>();
            // 年份（releaseDate 格式："2020-01-15T08:00:00Z"）
            if (best.contains("releaseDate") && best["releaseDate"].is_string()) {
                std::string rd = best["releaseDate"].get<std::string>();
                if (rd.length() >= 4) {
                    try { result.year = std::stoi(rd.substr(0, 4)); } catch (...) {}
                }
            }
            if (best.contains("artworkUrl600")) {
                outCoverUrl = best["artworkUrl600"].get<std::string>();
            } else if (best.contains("artworkUrl100")) {
                outCoverUrl = best["artworkUrl100"].get<std::string>();
            }
            result.scrapedSources.push_back("itunes");
            return true;
        } catch (const json::exception& e) {
            lastError_ = std::string("iTunes JSON 解析失败: ") + e.what();
        }
        return false;
    }

    bool fetchCover(const std::string& coverUrl, ScrapeResult& result) {
        if (coverUrl.empty()) return false;
        std::vector<uint8_t> data;
        long code = 0;
        if (httpGetBinary(coverUrl, data, &code) && code == 200 && !data.empty()) {
            result.coverData = std::move(data);
            result.coverMime = detectImageMime(result.coverData);
            std::cerr << "[scraper]   iTunes 封面下载成功: " << result.coverData.size()
                      << " bytes, mime=" << result.coverMime << std::endl;
            return true;
        }
        std::cerr << "[scraper]   iTunes 封面下载失败: HTTP " << code
                  << ", 数据大小=" << data.size() << std::endl;
        return false;
    }

    const std::string& lastError() const { return lastError_; }

private:
    bool httpGet(const std::string& url, std::string& body, long* code) {
        body.clear();
        curl_easy_setopt(curl_, CURLOPT_URL, url.c_str());
        curl_easy_setopt(curl_, CURLOPT_WRITEFUNCTION, writeCb);
        curl_easy_setopt(curl_, CURLOPT_WRITEDATA, &body);
        curl_easy_setopt(curl_, CURLOPT_USERAGENT, cfg_.userAgent.c_str());
        curl_easy_setopt(curl_, CURLOPT_TIMEOUT_MS, cfg_.requestTimeoutMs);
        curl_easy_setopt(curl_, CURLOPT_FOLLOWLOCATION, 1L);
        CURLcode res = curl_easy_perform(curl_);
        if (code) curl_easy_getinfo(curl_, CURLINFO_RESPONSE_CODE, code);
        return res == CURLE_OK;
    }

    bool httpGetBinary(const std::string& url, std::vector<uint8_t>& data, long* code) {
        data.clear();
        curl_easy_setopt(curl_, CURLOPT_URL, url.c_str());
        curl_easy_setopt(curl_, CURLOPT_WRITEFUNCTION, writeBinaryCb);
        curl_easy_setopt(curl_, CURLOPT_WRITEDATA, &data);
        curl_easy_setopt(curl_, CURLOPT_USERAGENT, cfg_.userAgent.c_str());
        curl_easy_setopt(curl_, CURLOPT_TIMEOUT_MS, cfg_.requestTimeoutMs);
        curl_easy_setopt(curl_, CURLOPT_FOLLOWLOCATION, 1L);
        CURLcode res = curl_easy_perform(curl_);
        if (code) curl_easy_getinfo(curl_, CURLINFO_RESPONSE_CODE, code);
        return res == CURLE_OK;
    }

    CURL* curl_ = nullptr;
    const ScraperConfig& cfg_;
    std::string lastError_;
};

// ============================================================================
// 中文音乐源客户端基类
// ============================================================================

/// 中文音乐源搜索结果（统一格式，便于多源合并）
struct ChineseSong {
    std::string id;          ///< 歌曲 ID（各平台自有 ID）
    std::string name;        ///< 歌曲名
    std::string artist;      ///< 艺术家（多人用逗号分隔）
    std::string album;       ///< 专辑名
    std::string albumImg;    ///< 封面 URL
    std::string year;        ///< 年份
    std::string resource;    ///< 来源标识：netease/qmusic/kugou/kuwo/migu
};

/// 中文音乐源抽象基类：提供公共 HTTP 工具与匹配评分
class ChineseMusicClientBase {
public:
    explicit ChineseMusicClientBase(const ScraperConfig& cfg) : cfg_(cfg) {
        curl_ = curl_easy_init();
        if (!curl_) throw std::runtime_error("curl_easy_init 失败");
    }
    virtual ~ChineseMusicClientBase() {
        if (curl_) curl_easy_cleanup(curl_);
    }

    ChineseMusicClientBase(const ChineseMusicClientBase&) = delete;
    ChineseMusicClientBase& operator=(const ChineseMusicClientBase&) = delete;

    /// 搜索曲目：返回候选列表（按匹配度排序后取前 N）
    virtual std::vector<ChineseSong> searchTrack(const std::string& artist,
                                                  const std::string& title) = 0;

    /// 获取歌词（同步歌词优先）
    virtual std::string fetchLyrics(const std::string& songId) { (void)songId; return ""; }

    /// 下载封面图片（带防盗链 Referer）
    bool fetchCover(const std::string& coverUrl, ScrapeResult& result,
                    const std::string& referer = "") {
        if (coverUrl.empty()) return false;
        std::vector<uint8_t> data;
        long code = 0;
        // 构建请求头：部分中文源封面需要 Referer 防盗链
        std::vector<std::pair<std::string, std::string>> hdrs;
        if (!referer.empty()) {
            hdrs.push_back({"Referer", referer});
        }
        if (httpGetBinaryWithHeaders(coverUrl, data, &code, hdrs) && code == 200 && !data.empty()) {
            result.coverData = std::move(data);
            result.coverMime = ::archoera::scraper::detectImageMime(result.coverData);
            std::cerr << "[scraper]   中文源封面下载成功: " << result.coverData.size()
                      << " bytes, mime=" << result.coverMime << std::endl;
            return true;
        }
        std::cerr << "[scraper]   中文源封面下载失败: HTTP " << code
                  << ", 数据大小=" << data.size()
                  << (referer.empty() ? "" : ", referer=" + referer)
                  << std::endl;
        return false;
    }

    /// 将 ChineseSong 转换为 ScrapeResult（用于合并到最终结果）
    static void toScrapeResult(const ChineseSong& song, ScrapeResult& result,
                                const std::string& resource) {
        if (!song.name.empty()) result.title = song.name;
        if (!song.artist.empty()) result.artist = song.artist;
        if (!song.album.empty()) result.album = song.album;
        if (!song.year.empty()) {
            try {
                // 取前 4 位作为年份
                if (song.year.length() >= 4) {
                    result.year = std::stoi(song.year.substr(0, 4));
                }
            } catch (...) {}
        }
        result.scrapedSources.push_back(resource);
    }

    const std::string& lastError() const { return lastError_; }

    /// 标题/艺术家匹配评分
    /// 返回 0/1/2：0=不匹配，1=包含，2=完全相同
    static int matchScore(const std::string& myValue, const std::string& uValue) {
        if (myValue.empty() || uValue.empty()) return 0;
        std::string a = toLower(myValue);
        std::string b = toLower(uValue);
        // 去空格
        a.erase(std::remove(a.begin(), a.end(), ' '), a.end());
        b.erase(std::remove(b.begin(), b.end(), ' '), b.end());
        if (a.empty() || b.empty()) return 0;
        if (a == b) return 2;
        if (a.find(b) != std::string::npos || b.find(a) != std::string::npos) return 1;
        return 0;
    }

    /// 多艺术家匹配（用逗号分隔时分别评分）
    static int matchArtist(const std::string& myValue, const std::string& uValue) {
        auto comma = uValue.find(',');
        if (comma != std::string::npos) {
            std::string first = uValue.substr(0, comma);
            std::string second = uValue.substr(comma + 1);
            // 去空格
            first.erase(std::remove(first.begin(), first.end(), ' '), first.end());
            second.erase(std::remove(second.begin(), second.end(), ' '), second.end());
            return matchScore(myValue, first) + matchScore(myValue, second);
        }
        return matchScore(myValue, uValue);
    }

    static std::string toLower(const std::string& s) {
        std::string out;
        out.reserve(s.size());
        for (unsigned char c : s) {
            // ASCII 字符 -> tolower; UTF-8 多字节字符直接保留
            out.push_back(c < 0x80 ? static_cast<char>(std::tolower(c)) : static_cast<char>(c));
        }
        return out;
    }

protected:
    bool httpGet(const std::string& url, std::string& body, long* code,
                 const std::vector<std::pair<std::string, std::string>>& headers = {}) {
        body.clear();
        curl_easy_setopt(curl_, CURLOPT_URL, url.c_str());
        curl_easy_setopt(curl_, CURLOPT_WRITEFUNCTION, writeCb);
        curl_easy_setopt(curl_, CURLOPT_WRITEDATA, &body);
        curl_easy_setopt(curl_, CURLOPT_USERAGENT, cfg_.userAgent.c_str());
        curl_easy_setopt(curl_, CURLOPT_TIMEOUT_MS, cfg_.requestTimeoutMs);
        curl_easy_setopt(curl_, CURLOPT_FOLLOWLOCATION, 1L);

        struct curl_slist* hdrList = nullptr;
        for (const auto& h : headers) {
            hdrList = curl_slist_append(hdrList, (h.first + ": " + h.second).c_str());
        }
        if (hdrList) curl_easy_setopt(curl_, CURLOPT_HTTPHEADER, hdrList);

        CURLcode res = curl_easy_perform(curl_);
        if (code) curl_easy_getinfo(curl_, CURLINFO_RESPONSE_CODE, code);
        curl_easy_setopt(curl_, CURLOPT_HTTPHEADER, nullptr);
        if (hdrList) curl_slist_free_all(hdrList);
        return res == CURLE_OK;
    }

    bool httpGetBinary(const std::string& url, std::vector<uint8_t>& data, long* code) {
        data.clear();
        curl_easy_setopt(curl_, CURLOPT_HTTPHEADER, nullptr);  // 清除上次请求残留的请求头
        curl_easy_setopt(curl_, CURLOPT_URL, url.c_str());
        curl_easy_setopt(curl_, CURLOPT_WRITEFUNCTION, writeBinaryCb);
        curl_easy_setopt(curl_, CURLOPT_WRITEDATA, &data);
        curl_easy_setopt(curl_, CURLOPT_USERAGENT, cfg_.userAgent.c_str());
        curl_easy_setopt(curl_, CURLOPT_TIMEOUT_MS, cfg_.requestTimeoutMs);
        curl_easy_setopt(curl_, CURLOPT_FOLLOWLOCATION, 1L);
        CURLcode res = curl_easy_perform(curl_);
        if (code) curl_easy_getinfo(curl_, CURLINFO_RESPONSE_CODE, code);
        return res == CURLE_OK;
    }

    /// HTTP GET 二进制数据（支持自定义请求头，用于封面防盗链 Referer）
    bool httpGetBinaryWithHeaders(const std::string& url, std::vector<uint8_t>& data, long* code,
                                  const std::vector<std::pair<std::string, std::string>>& headers = {}) {
        data.clear();
        curl_easy_setopt(curl_, CURLOPT_URL, url.c_str());
        curl_easy_setopt(curl_, CURLOPT_WRITEFUNCTION, writeBinaryCb);
        curl_easy_setopt(curl_, CURLOPT_WRITEDATA, &data);
        curl_easy_setopt(curl_, CURLOPT_USERAGENT, cfg_.userAgent.c_str());
        curl_easy_setopt(curl_, CURLOPT_TIMEOUT_MS, cfg_.requestTimeoutMs);
        curl_easy_setopt(curl_, CURLOPT_FOLLOWLOCATION, 1L);

        struct curl_slist* hdrList = nullptr;
        for (const auto& h : headers) {
            hdrList = curl_slist_append(hdrList, (h.first + ": " + h.second).c_str());
        }
        if (hdrList) curl_easy_setopt(curl_, CURLOPT_HTTPHEADER, hdrList);

        CURLcode res = curl_easy_perform(curl_);
        if (code) curl_easy_getinfo(curl_, CURLINFO_RESPONSE_CODE, code);
        curl_easy_setopt(curl_, CURLOPT_HTTPHEADER, nullptr);
        if (hdrList) curl_slist_free_all(hdrList);
        return res == CURLE_OK;
    }

    /// HTTP POST 请求
    /// @param postData 请求体（application/x-www-form-urlencoded 或 JSON 字符串）
    bool httpPost(const std::string& url, const std::string& postData,
                  std::string& body, long* code,
                  const std::vector<std::pair<std::string, std::string>>& headers = {}) {
        body.clear();
        curl_easy_setopt(curl_, CURLOPT_URL, url.c_str());
        curl_easy_setopt(curl_, CURLOPT_WRITEFUNCTION, writeCb);
        curl_easy_setopt(curl_, CURLOPT_WRITEDATA, &body);
        curl_easy_setopt(curl_, CURLOPT_USERAGENT, cfg_.userAgent.c_str());
        curl_easy_setopt(curl_, CURLOPT_TIMEOUT_MS, cfg_.requestTimeoutMs);
        curl_easy_setopt(curl_, CURLOPT_FOLLOWLOCATION, 1L);
        curl_easy_setopt(curl_, CURLOPT_POST, 1L);
        curl_easy_setopt(curl_, CURLOPT_POSTFIELDS, postData.c_str());
        curl_easy_setopt(curl_, CURLOPT_POSTFIELDSIZE, static_cast<long>(postData.size()));

        struct curl_slist* hdrList = nullptr;
        for (const auto& h : headers) {
            hdrList = curl_slist_append(hdrList, (h.first + ": " + h.second).c_str());
        }
        if (hdrList) curl_easy_setopt(curl_, CURLOPT_HTTPHEADER, hdrList);

        CURLcode res = curl_easy_perform(curl_);
        if (code) curl_easy_getinfo(curl_, CURLINFO_RESPONSE_CODE, code);

        // 重置为 GET 模式并清除自定义请求头
        curl_easy_setopt(curl_, CURLOPT_HTTPGET, 1L);
        curl_easy_setopt(curl_, CURLOPT_HTTPHEADER, nullptr);
        if (hdrList) curl_slist_free_all(hdrList);

        return res == CURLE_OK;
    }

    CURL* curl_ = nullptr;
    const ScraperConfig& cfg_;
    std::string lastError_;
};

/// 网易云音乐客户端
/// 使用 weapi 加密接口搜索（更完整的结果），回退到公开 API
class NeteaseClient : public ChineseMusicClientBase {
public:
    explicit NeteaseClient(const ScraperConfig& cfg) : ChineseMusicClientBase(cfg) {}

    std::vector<ChineseSong> searchTrack(const std::string& artist,
                                          const std::string& title) override {
        (void)artist;
        std::vector<ChineseSong> songs;

        // 优先使用公开 API（不需要加密，更稳定）
        std::string url = "https://music.163.com/api/search/get/web?s=" +
                          urlEncode(title) + "&type=1&limit=10&offset=0";
        std::string body;
        long code = 0;
        std::vector<std::pair<std::string, std::string>> pubHdrs = {
            {"Referer", "https://music.163.com/"},
            {"User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"},
        };
        if (httpGet(url, body, &code, pubHdrs) && code == 200) {
            parsePublicSearch(body, songs);
            std::cerr << "[scraper]   网易云公开 API 返回 " << songs.size() << " 条结果" << std::endl;
        } else {
            std::cerr << "[scraper]   网易云公开 API 失败: HTTP " << code
                      << "，尝试 weapi..." << std::endl;
        }

        // 公开 API 无结果时回退到 weapi 加密搜索
        if (songs.empty() && encryptedSearch(title, songs)) {
            std::cerr << "[scraper]   网易云 weapi 搜索返回 " << songs.size() << " 条结果" << std::endl;
        }
        // weapi 失败时回退到 linuxapi（AES-128-ECB，无需 RSA，更可靠）
        if (songs.empty()) {
            linuxapiSearch(title, songs);
        }

        // 公开 API 缺少 picUrl（只有 picId），用 linuxapi 获取正确封面 URL
        if (!songs.empty() && songs[0].albumImg.empty()) {
            std::vector<ChineseSong> lsongs;
            if (linuxapiSearch(title, lsongs) && !lsongs.empty()) {
                // 按 song id 匹配，覆盖 albumImg
                for (auto& song : songs) {
                    for (const auto& ls : lsongs) {
                        if (song.id == ls.id && !ls.albumImg.empty()) {
                            song.albumImg = ls.albumImg;
                            break;
                        }
                    }
                }
                std::cerr << "[scraper]   网易云 linuxapi 回填封面: "
                          << lsongs.size() << " 条结果" << std::endl;
            }
        }

        return songs;
    }

    std::string fetchLyrics(const std::string& songId) override {
        if (songId.empty()) return "";
        std::string lrc = encryptedLyrics(songId);
        if (!lrc.empty()) return lrc;

        // 回退到公开歌词 API
        std::string url = "https://music.163.com/api/song/lyric?lv=-1&kv=-1&tv=-1&id=" + songId;
        std::string body;
        long code = 0;
        std::vector<std::pair<std::string, std::string>> hdrs = {
            {"Referer", "https://music.163.com"},
        };
        if (!httpGet(url, body, &code, hdrs) || code != 200) return "";
        try {
            auto j = json::parse(body);
            return j.value("lrc", json::object()).value("lyric", "");
        } catch (const json::exception&) {
            return "";
        }
    }

private:
    // ====================================================================
    // 网易云 weapi 加密算法
    //
    // 算法流程（基于对 NetEase Music 网页版客户端 JS 的逆向分析）：
    //   1. 用固定 nonce 做 AES-128-CBC 加密 → enc1
    //   2. 生成 16 字节随机 key，用此 key 对 enc1 做 AES-128-CBC 加密 → params
    //   3. RSA-OAEP 加密随机 key（文本反转 + 大数模幂） → encSecKey
    //   4. POST params + encSecKey
    //
    // 加密常量来自 NetEase Music 网页版客户端代码，为公开 API 规范
    // ====================================================================

    /// AES-128-ECB 加密 + PKCS7 填充 + 大写 Hex 输出（linuxapi 使用）
    static std::string aes128ecbHex(const std::string& input, const std::string& key) {
        if (key.size() != 16) return "";

        std::string padded = input;
        unsigned char padVal = static_cast<unsigned char>(16 - input.size() % 16);
        padded.append(padVal, static_cast<char>(padVal));

        EVP_CIPHER_CTX* ctx = EVP_CIPHER_CTX_new();
        if (!ctx) return "";
        if (EVP_EncryptInit_ex(ctx, EVP_aes_128_ecb(), nullptr,
                               (const unsigned char*)key.data(), nullptr) != 1) {
            EVP_CIPHER_CTX_free(ctx);
            return "";
        }
        EVP_CIPHER_CTX_set_padding(ctx, 0);

        unsigned char cipherBuf[8192];
        int outLen = 0;
        if (EVP_EncryptUpdate(ctx, cipherBuf, &outLen,
                              (unsigned char*)padded.data(), padded.size()) != 1) {
            EVP_CIPHER_CTX_free(ctx);
            return "";
        }
        int finalLen = 0;
        if (EVP_EncryptFinal_ex(ctx, cipherBuf + outLen, &finalLen) != 1) {
            EVP_CIPHER_CTX_free(ctx);
            return "";
        }
        outLen += finalLen;
        EVP_CIPHER_CTX_free(ctx);

        std::string hex;
        hex.reserve(outLen * 2);
        for (int i = 0; i < outLen; i++) {
            char buf[4];
            std::snprintf(buf, sizeof(buf), "%02X", cipherBuf[i]);
            hex += buf;
        }
        return hex;
    }

    /// linuxapi 搜索（AES-128-ECB，无需 RSA——weapi 失败时的可靠回退）
    bool linuxapiSearch(const std::string& keyword, std::vector<ChineseSong>& songs) {
        static const char* LINUX_API_KEY = "rFgB&h#%2?^eDg:Q";
        json payload = {
            {"method", "POST"},
            {"url", "https://music.163.com/api/cloudsearch/pc"},
            {"params", {{"s", keyword}, {"type", 1}, {"limit", 10}, {"offset", 0}}}
        };
        std::string encrypted = aes128ecbHex(payload.dump(), LINUX_API_KEY);
        if (encrypted.empty()) return false;

        std::string postData = "eparams=" + encrypted;
        std::string body;
        long code = 0;

        std::vector<std::pair<std::string, std::string>> hdrs = {
            {"Referer", "https://music.163.com"},
            {"Content-Type", "application/x-www-form-urlencoded"},
            {"User-Agent", "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"},
            {"Cookie", "os=linux; deviceId=NMUSIC"},
        };
        if (!httpPost("https://music.163.com/api/linux/forward",
                       postData, body, &code, hdrs) || code != 200) {
            std::cerr << "[scraper]   网易云 linuxapi 失败: HTTP " << code
                      << ", body=" << body.substr(0, 200) << std::endl;
            return false;
        }

        try {
            auto j = json::parse(body);
            auto result = j.value("result", json::object());
            for (auto& entry : result.value("songs", json::array())) {
                ChineseSong cs;
                cs.id = std::to_string(entry.value("id", 0));
                cs.name = entry.value("name", "");
                std::string singers;
                for (auto& a : entry.value("ar", json::array())) {
                    if (!singers.empty()) singers += ",";
                    singers += a.value("name", "");
                }
                cs.artist = singers;
                auto al = entry.value("al", json::object());
                cs.album = al.value("name", "");
                cs.albumImg = al.value("picUrl", "");
                cs.resource = "netease";
                songs.push_back(std::move(cs));
            }
            std::cerr << "[scraper]   网易云 linuxapi 返回 " << songs.size() << " 条结果" << std::endl;
            return !songs.empty();
        } catch (const json::exception& e) {
            std::cerr << "[scraper]   网易云 linuxapi 解析失败: " << e.what() << std::endl;
            return false;
        }
    }

    /// 加密搜索请求（weapi），返回是否成功
    bool encryptedSearch(const std::string& keyword, std::vector<ChineseSong>& songs) {
        json params = {
            {"s", keyword}, {"type", 1},
            {"limit", 10}, {"offset", 0},
            {"csrf_token", ""}
        };
        auto formData = buildWeapiForm(params.dump());
        if (formData.empty()) return false;

        std::string body;
        long code = 0;
        std::vector<std::pair<std::string, std::string>> hdrs = {
            {"Referer", "https://music.163.com/"},
            {"Content-Type", "application/x-www-form-urlencoded"},
            {"User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"},
            {"Cookie", "__remember_me=true"},
        };
        if (!httpPost("https://music.163.com/weapi/cloudsearch/get/web",
                       formData, body, &code, hdrs) || code != 200) {
            std::cerr << "[scraper]   网易云 weapi POST 失败: HTTP " << code
                      << ", body=" << body.substr(0, 200) << std::endl;
            return false;
        }
        parseWeapiSearch(body, songs);
        if (songs.empty()) {
            std::cerr << "[scraper]   网易云 weapi 返回 0 条结果, body=" << body.substr(0, 300) << std::endl;
        }
        return !songs.empty();
    }

    /// 加密歌词请求（linuxapi：AES-128-ECB，比 weapi 更可靠）
    std::string encryptedLyrics(const std::string& songId) {
        int64_t sid = 0;
        try { sid = std::stoll(songId); } catch (...) { return ""; }

        static const char* LINUX_API_KEY = "rFgB&h#%2?^eDg:Q";
        json payload = {
            {"method", "POST"},
            {"url", "https://music.163.com/api/song/lyric?id=" + std::to_string(sid) + "&lv=-1&kv=-1&tv=-1"},
            {"params", {{"id", std::to_string(sid)}}}
        };
        std::string encrypted = aes128ecbHex(payload.dump(), LINUX_API_KEY);
        if (encrypted.empty()) return "";

        std::string postData = "eparams=" + encrypted;
        std::string body;
        long code = 0;

        std::vector<std::pair<std::string, std::string>> hdrs = {
            {"Referer", "https://music.163.com"},
            {"Content-Type", "application/x-www-form-urlencoded"},
            {"User-Agent", "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/60.0.3112.90 Safari/537.36"},
            {"Cookie", "os=linux; deviceId=NMUSIC"},
        };
        if (!httpPost("https://music.163.com/api/linux/forward",
                       postData, body, &code, hdrs) || code != 200) {
            return "";
        }
        try {
            auto j = json::parse(body);
            return j.value("lrc", json::object()).value("lyric", "");
        } catch (const json::exception&) {
            return "";
        }
    }

    /// 构造 weapi 加密表单数据：params=base64(AES(...))&encSecKey=hex(RSA(...))
    static std::string buildWeapiForm(const std::string& plaintext) {
        // Step 1: 用固定 nonce 做第一层 AES
        std::string layer1 = aes128cbc(plaintext, WEB_NETESE_NONCE_KEY);
        if (layer1.empty()) return "";

        // Step 2: 生成临时随机密钥
        std::string tmpKey = generateRandomKey();

        // Step 3: 用随机密钥做第二层 AES
        std::string encParams = aes128cbc(layer1, tmpKey);
        if (encParams.empty()) return "";

        // Step 4: RSA 加密随机密钥
        std::string encKey = rsaEncrypt(tmpKey);

        // Step 5: 返回表单编码数据
        return "params=" + percentEncode(encParams) + "&encSecKey=" + encKey;
    }

    /// AES-128-CBC 加密 + PKCS7 填充 + Base64 输出
    static std::string aes128cbc(const std::string& input, const std::string& key) {
        if (key.size() != 16) return "";

        // PKCS7 padding
        std::string padded = input;
        unsigned char padVal = static_cast<unsigned char>(16 - input.size() % 16);
        padded.append(padVal, static_cast<char>(padVal));

        // IV = "0102030405060708"
        unsigned char iv[16] = {0x30,0x31,0x30,0x32,0x30,0x33,0x30,0x34,
                                0x30,0x35,0x30,0x36,0x30,0x37,0x30,0x38};

        unsigned char cipherBuf[4096];
        int outLen = 0, finalLen = 0;
        EVP_CIPHER_CTX* ctx = EVP_CIPHER_CTX_new();
        if (!ctx) return "";

        int ok = 1;
        ok = ok && EVP_EncryptInit_ex(ctx, EVP_aes_128_cbc(), nullptr,
                                      reinterpret_cast<const unsigned char*>(key.data()), iv);
        ok = ok && EVP_EncryptUpdate(ctx, cipherBuf, &outLen,
                                     reinterpret_cast<const unsigned char*>(padded.data()),
                                     static_cast<int>(padded.size()));
        ok = ok && EVP_EncryptFinal_ex(ctx, cipherBuf + outLen, &finalLen);
        EVP_CIPHER_CTX_free(ctx);
        if (!ok) return "";

        outLen += finalLen;

        // Base64 encode
        static const char b64[] =
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        std::string result;
        result.reserve((outLen + 2) / 3 * 4);
        for (int i = 0; i < outLen; i += 3) {
            unsigned int n = static_cast<unsigned char>(cipherBuf[i]) << 16;
            if (i + 1 < outLen) n |= static_cast<unsigned char>(cipherBuf[i + 1]) << 8;
            if (i + 2 < outLen) n |= static_cast<unsigned char>(cipherBuf[i + 2]);
            result.push_back(b64[(n >> 18) & 0x3F]);
            result.push_back(b64[(n >> 12) & 0x3F]);
            result.push_back((i + 1 < outLen) ? b64[(n >> 6) & 0x3F] : '=');
            result.push_back((i + 2 < outLen) ? b64[n & 0x3F] : '=');
        }
        return result;
    }

    /// RSA 加密（文本反转 + 大数模幂）
    static std::string rsaEncrypt(const std::string& input) {
        std::string rev(input.rbegin(), input.rend());

        // 转 hex
        std::string hexIn;
        for (unsigned char c : rev) {
            char buf[4];
            std::snprintf(buf, sizeof(buf), "%02x", c);
            hexIn += buf;
        }

        BN_CTX* ctx = BN_CTX_new();
        BIGNUM* base = BN_new();
        BIGNUM* exp = BN_new();
        BIGNUM* mod = BN_new();
        BIGNUM* res = BN_new();

        BN_hex2bn(&base, hexIn.c_str());
        BN_hex2bn(&exp, NETESE_PUB_EXPONENT);
        BN_hex2bn(&mod, NETESE_MODULUS);

        BN_mod_exp(res, base, exp, mod, ctx);

        char* hexOut = BN_bn2hex(res);
        std::string result(hexOut);
        OPENSSL_free(hexOut);

        BN_free(base); BN_free(exp); BN_free(mod); BN_free(res);
        BN_CTX_free(ctx);

        // 补齐 256 位十六进制
        if (result.size() < 256) {
            result = std::string(256 - result.size(), '0') + result;
        }
        return result;
    }

    /// 生成 16 字节 hex 随机密钥
    static std::string generateRandomKey() {
        unsigned char buf[16];
        RAND_bytes(buf, sizeof(buf));
        std::string hex;
        for (int i = 0; i < 16; ++i) {
            char h[4];
            std::snprintf(h, sizeof(h), "%02x", buf[i]);
            hex += h;
        }
        return hex.substr(0, 16);
    }

    /// URL 百分号编码（静态版本，不依赖 curl_）
    static std::string percentEncode(const std::string& s) {
        std::string out;
        for (unsigned char c : s) {
            if (std::isalnum(c) || c == '-' || c == '_' || c == '.' || c == '~') {
                out.push_back(c);
            } else {
                char buf[4];
                std::snprintf(buf, sizeof(buf), "%%%02X", c);
                out += buf;
            }
        }
        return out;
    }

    // ====================================================================
    // 搜索结果解析
    // ====================================================================

    /// 解析公开 API 搜索结果（字段：artists/album/picUrl）
    static void parsePublicSearch(const std::string& body,
                                   std::vector<ChineseSong>& songs) {
        try {
            auto j = json::parse(body);
            auto result = j.value("result", json::object());
            for (auto& entry : result.value("songs", json::array())) {
                ChineseSong cs;
                cs.id = std::to_string(entry.value("id", 0));
                cs.name = entry.value("name", "");
                std::string singers;
                for (auto& a : entry.value("artists", json::array())) {
                    if (!singers.empty()) singers += ",";
                    singers += a.value("name", "");
                }
                cs.artist = singers;
                cs.album = entry.value("album", json::object()).value("name", "");
                // Netease public API: 优先取 picUrl, 否则取 pic
                // 注意: picId 不是 CDN hash，不能用 picId 构造 URL
                auto album = entry.value("album", json::object());
                cs.albumImg = album.value("picUrl", "");
                if (cs.albumImg.empty()) {
                    cs.albumImg = album.value("pic", "");
                }
                // picId 无法构造有效封面 URL，albumImg 为空时由 linuxapi 回退填充
                // 首个结果输出调试信息
                if (songs.empty()) {
                    std::cerr << "[scraper]   网易云公开 API 首个结果: name=" << cs.name
                              << ", artist=" << cs.artist
                              << ", album=" << cs.album
                              << ", albumImg=" << (cs.albumImg.empty() ? "(空，需要linuxapi回填)" : cs.albumImg)
                              << ", album.keys=";
                    for (auto& [k, v] : album.items()) {
                        std::cerr << k << ",";
                    }
                    std::cerr << std::endl;
                }
                cs.resource = "netease";
                songs.push_back(std::move(cs));
            }
        } catch (const json::exception&) {}
    }

    /// 解析 weapi 搜索结果（字段：ar/al/publishTime）
    static void parseWeapiSearch(const std::string& body,
                                  std::vector<ChineseSong>& songs) {
        try {
            auto j = json::parse(body);
            auto result = j.value("result", json::object());
            for (auto& entry : result.value("songs", json::array())) {
                ChineseSong cs;
                cs.id = std::to_string(entry.value("id", 0));
                cs.name = entry.value("name", "");
                // weapi 字段名不同：ar (artists), al (album)
                std::string singers;
                for (auto& a : entry.value("ar", json::array())) {
                    if (!singers.empty()) singers += ",";
                    singers += a.value("name", "");
                }
                cs.artist = singers;
                auto al = entry.value("al", json::object());
                cs.album = al.value("name", "");
                cs.albumImg = al.value("picUrl", "");
                // 首个结果输出调试信息
                if (songs.empty()) {
                    std::cerr << "[scraper]   网易云 weapi 首个结果: name=" << cs.name
                              << ", artist=" << cs.artist
                              << ", album=" << cs.album
                              << ", albumImg=" << cs.albumImg << std::endl;
                }
                // 从毫秒时间戳提取年份
                if (entry.contains("publishTime") && entry["publishTime"].is_number()) {
                    auto pts = entry["publishTime"].get<int64_t>();
                    if (pts > 0) {
                        auto t = static_cast<time_t>(pts / 1000);
                        struct tm gmt;
                        gmtime_r(&t, &gmt);
                        char yr[8];
                        int year = std::clamp(gmt.tm_year + 1900, 0, 9999);
                        std::snprintf(yr, sizeof(yr), "%04d", year);
                        cs.year = yr;
                    }
                }
                cs.resource = "netease";
                songs.push_back(std::move(cs));
            }
        } catch (const json::exception&) {}
    }

    // 网易云 weapi 加密常量
    // 来源：对 NetEase Music 网页版客户端 JavaScript 的逆向分析
    // 这些常量是公开的 API 规范，多個开源项目独立分析得到相同值
    static constexpr const char* WEB_NETESE_NONCE_KEY = "0CoJUm6Qyw8W8jud";
    static constexpr const char* NETESE_PUB_EXPONENT = "010001";
    static constexpr const char* NETESE_MODULUS =
        "00e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7"
        "b725152b3ab17a876aea8a5aa76d2e417629ec4ee341f56135fccf695280"
        "104e0312ecbda92557c93870114af6c9d05c4f7f0c3685b7a46bee255932"
        "575cce10b424d813cfe4875d3e82047b97ddef52741d546b8e289dc6935b"
        "3ece0462db0a22b8e7";
};

/// QQ 音乐客户端
/// 使用 musicu.fcg 搜索接口
class QQMusicClient : public ChineseMusicClientBase {
public:
    explicit QQMusicClient(const ScraperConfig& cfg) : ChineseMusicClientBase(cfg) {}

    std::vector<ChineseSong> searchTrack(const std::string& artist,
                                          const std::string& title) override {
        (void)artist;
        std::vector<ChineseSong> songs;
        std::string url = "https://u.y.qq.com/cgi-bin/musicu.fcg";

        // 构造搜索请求体（匹配 QQMusic API 要求的完整字段）
        json payload = {
            {"comm", {
                {"wid", ""},
                {"tmeAppID", "qqmusic"},
                {"authst", ""},
                {"uid", ""},
                {"gray", "0"},
                {"OpenUDID", "2d484d3157d4ed482e406e6c5fdcf8c3d3275deb"},
                {"ct", "6"},
                {"patch", "2"},
                {"psrf_qqopenid", ""},
                {"sid", ""},
                {"psrf_access_token_expiresAt", ""},
                {"cv", "80600"},
                {"gzip", "0"},
                {"qq", ""},
                {"nettype", "2"},
                {"psrf_qqunionid", ""},
                {"psrf_qqaccess_token", ""},
                {"tmeLoginType", "2"}
            }},
            {"music.search.SearchCgiService.DoSearchForQQMusicDesktop", {
                {"module", "music.search.SearchCgiService"},
                {"method", "DoSearchForQQMusicDesktop"},
                {"param", {
                    {"num_per_page", 10},
                    {"page_num", 1},
                    {"remoteplace", "txt.mac.search"},
                    {"search_type", 0},
                    {"query", title},
                    {"grp", 1},
                    {"searchid", generateUUID()},
                    {"nqc_flag", 0}
                }}
            }}
        };

        std::string jsonBody = payload.dump();

        std::string body;
        long code = 0;
        std::vector<std::pair<std::string, std::string>> hdrs = {
            {"Referer", "https://y.qq.com/portal/profile.html"},
            {"Content-Type", "application/json; charset=UTF-8"},
            {"User-Agent", "QQ%E9%9F%B3%E4%B9%90/73222 CFNetwork/1406.0.3 Darwin/22.4.0"},
        };
        if (!httpPost(url, jsonBody, body, &code, hdrs) || code != 200) {
            std::cerr << "[scraper]   QQ音乐 POST 失败: HTTP " << code << std::endl;
            return songs;
        }

        try {
            auto j = json::parse(body);
            auto resp = j.value("music.search.SearchCgiService.DoSearchForQQMusicDesktop", json::object());
            auto data = resp.value("data", json::object());
            auto bodyObj = data.value("body", json::object());
            auto songObj = bodyObj.value("song", json::object());
            auto list = songObj.value("list", json::array());
            for (auto& entry : list) {
                ChineseSong cs;
                cs.id = entry.value("mid", "");
                cs.name = entry.value("title", "");
                auto singers = entry.value("singer", json::array());
                std::string artistStr;
                for (size_t i = 0; i < singers.size(); ++i) {
                    if (i > 0) artistStr += ",";
                    artistStr += singers[i].value("name", "");
                }
                cs.artist = artistStr;
                auto album = entry.value("album", json::object());
                cs.album = album.value("title", "");
                auto albumMid = album.value("mid", "");
                if (!albumMid.empty()) {
                    cs.albumImg = "http://y.qq.com/music/photo_new/T002R300x300M000" +
                                  albumMid + ".jpg";
                }
                cs.year = entry.value("time_public", "");
                cs.resource = "qmusic";
                songs.push_back(std::move(cs));
            }
            std::cerr << "[scraper]   QQ音乐返回 " << songs.size() << " 条结果"
                      << (songs.empty() ? "" : ", 首个albumImg=" + songs[0].albumImg)
                      << std::endl;
        } catch (const json::exception& e) {
            lastError_ = std::string("QQ音乐 JSON 解析失败: ") + e.what();
        }
        return songs;
    }

    std::string fetchLyrics(const std::string& songMid) override {
        if (songMid.empty()) return "";
        std::string url = "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg"
                          "?songmid=" + songMid +
                          "&g_tk=5381&format=json"
                          "&inCharset=utf-8&outCharset=utf-8"
                          "&platform=h5&needNewCode=1";
        std::string body;
        long code = 0;
        std::vector<std::pair<std::string, std::string>> hdrs = {
            {"Referer", "https://y.qq.com"},
        };
        if (!httpGet(url, body, &code, hdrs) || code != 200) return "";
        try {
            auto j = json::parse(body);
            std::string lyricB64 = j.value("lyric", "");
            if (lyricB64.empty()) return "";
            return decodeBase64(lyricB64);
        } catch (const json::exception&) {
            return "";
        }
    }

private:
    /// 生成 UUID 格式的 searchid（QQ 音乐搜索请求需要）
    static std::string generateUUID() {
        unsigned char buf[16];
        RAND_bytes(buf, sizeof(buf));
        // 格式: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
        char hex[37];
        std::snprintf(hex, sizeof(hex),
            "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
            buf[0], buf[1], buf[2], buf[3],
            buf[4], buf[5], buf[6], buf[7],
            buf[8], buf[9], buf[10], buf[11],
            buf[12], buf[13], buf[14], buf[15]);
        return hex;
    }

    /// Base64 解码（QQ 音乐歌词为 Base64 编码）
    static std::string decodeBase64(const std::string& encoded) {
        static const std::string table =
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        std::vector<int> indexMap(256, -1);
        for (int i = 0; i < 64; ++i) indexMap[table[i]] = i;
        std::string out;
        int bits = 0, accum = -8;
        for (unsigned char c : encoded) {
            if (indexMap[c] == -1) break;
            bits = (bits << 6) + indexMap[c];
            accum += 6;
            if (accum >= 0) {
                out.push_back(static_cast<char>((bits >> accum) & 0xFF));
                accum -= 8;
            }
        }
        return out;
    }
};

/// 酷狗音乐客户端
/// 使用带 MD5 签名的搜索接口
class KugouClient : public ChineseMusicClientBase {
public:
    explicit KugouClient(const ScraperConfig& cfg) : ChineseMusicClientBase(cfg) {}

    std::vector<ChineseSong> searchTrack(const std::string& artist,
                                          const std::string& title) override {
        (void)artist;
        std::vector<ChineseSong> songs;

        if (searchSignedApi(title, songs)) return songs;

        // 签名接口失败时回退到移动端 API
        return searchMobile(title);
    }

    std::string fetchLyrics(const std::string& hash) override {
        if (hash.empty()) return "";
        std::string url = "http://m.kugou.com/app/i/krc.php?cmd=100&timelength=999999&hash=" + hash;
        std::string body;
        long code = 0;
        if (!httpGet(url, body, &code) || code != 200) return "";
        return body;
    }

private:
    /// 使用签名验证的搜索接口
    bool searchSignedApi(const std::string& keyword, std::vector<ChineseSong>& songs) {
        auto now = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::system_clock::now().time_since_epoch()).count();
        std::string ts = std::to_string(now);

        // 构造签名（API 要求的带盐值签名参数）
        const std::string kugouSalt = "NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt";
        std::string raw =
            kugouSalt + "bitrate=0clienttime=" + ts +
            "clientver=2000dfid=-inputtype=0iscorrection=1isfuzzy=0keyword=" + keyword +
            "mid=" + ts +
            "page=1pagesize=10platform=WebFilterprivilege_filter=0srcappid=2919tag=em"
            "userid=-1uuid=" + ts +
            kugouSalt;

        std::string sig;
        {
            unsigned char digest[EVP_MAX_MD_SIZE];
            unsigned int len = 0;
            EVP_Digest(raw.c_str(), raw.size(), digest, &len, EVP_md5(), nullptr);
            std::string hex;
            for (unsigned int i = 0; i < len; ++i) {
                char buf[3];
                std::snprintf(buf, sizeof(buf), "%02x", digest[i]);
                hex += buf;
            }
            sig = hex;
        }

        std::string url =
            "https://complexsearch.kugou.com/v2/search/song"
            "?keyword=" + urlEncode(keyword) +
            "&page=1&pagesize=10&bitrate=0&isfuzzy=0&tag=em"
            "&inputtype=0&platform=WebFilter&userid=-1"
            "&clientver=2000&iscorrection=1&privilege_filter=0"
            "&srcappid=2919"
            "&clienttime=" + ts +
            "&mid=" + ts +
            "&uuid=" + ts +
            "&dfid=-&signature=" + sig;

        std::string body;
        long code = 0;
        std::vector<std::pair<std::string, std::string>> hdrs = {
            {"Referer", "https://www.kugou.com"},
            {"User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"},
        };
        if (!httpGet(url, body, &code, hdrs) || code != 200) {
            std::cerr << "[scraper]   酷狗签名 API 失败: HTTP " << code << std::endl;
            return false;
        }

        try {
            auto j = json::parse(body);
            auto data = j.value("data", json::object());
            auto lists = data.value("lists", json::array());
            for (auto& entry : lists) {
                ChineseSong cs;
                cs.id = entry.value("FileHash", "");
                // 清理搜索结果中的高亮标签
                cs.name = sanitizeHighlight(entry.value("SongName", ""));
                cs.artist = normalizeArtists(entry.value("SingerName", ""));
                cs.album = entry.value("AlbumName", "");
                cs.albumImg = resolveCoverUrl(entry.value("Image", ""));
                cs.year = entry.value("PublishTime", "");
                cs.resource = "kugou";
                songs.push_back(std::move(cs));
            }
            std::cerr << "[scraper]   酷狗返回 " << songs.size() << " 条结果"
                      << (songs.empty() ? "" : ", 首个albumImg=" + songs[0].albumImg)
                      << std::endl;
        } catch (const json::exception& e) {
            lastError_ = std::string("酷狗 JSON 解析失败: ") + e.what();
        }
        return !songs.empty();
    }

    /// 移动端搜索回退
    std::vector<ChineseSong> searchMobile(const std::string& keyword) {
        std::vector<ChineseSong> songs;
        std::string url = "https://msearchcdn.kugou.com/api/v3/search/song"
                          "?keyword=" + urlEncode(keyword) +
                          "&page=1&pagesize=10&version=9108";
        std::string body;
        long code = 0;
        std::vector<std::pair<std::string, std::string>> hdrs = {
            {"Referer", "https://m.kugou.com"},
            {"User-Agent", "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"},
        };
        if (!httpGet(url, body, &code, hdrs) || code != 200) return songs;

        try {
            auto j = json::parse(body);
            auto data = j.value("data", json::object());
            auto info = data.value("info", json::array());
            for (auto& entry : info) {
                ChineseSong cs;
                cs.id = entry.value("hash", "");
                cs.name = entry.value("songname", "");
                cs.artist = entry.value("singername", "");
                cs.album = entry.value("albumname", "");
                cs.albumImg = entry.value("albumpic", "");
                cs.year = "";
                cs.resource = "kugou";
                songs.push_back(std::move(cs));
            }
        } catch (const json::exception&) {}
        return songs;
    }

    /// 去除搜索结果中的 HTML 高亮标签
    static std::string sanitizeHighlight(const std::string& input) {
        std::string out;
        for (size_t i = 0; i < input.size(); ++i) {
            if (input[i] == '<') {
                while (i < input.size() && input[i] != '>') ++i;
                continue;
            }
            out += input[i];
        }
        return out;
    }

    /// 规范化歌手字符串（将 、 分隔符替换为英文逗号）
    static std::string normalizeArtists(const std::string& raw) {
        std::string out = sanitizeHighlight(raw);
        // 替换全角顿号 、 (U+3001, UTF-8: \xE3\x80\x81) 为英文逗号
        // 注意：必须匹配完整 UTF-8 序列，逐字节替换会损坏其他中文字符
        std::string::size_type pos = 0;
        while ((pos = out.find("\xE3\x80\x81", pos)) != std::string::npos) {
            out.replace(pos, 3, ",");
            pos += 1;
        }
        // 清理多余逗号
        std::string cleaned;
        bool prevComma = false;
        for (unsigned char c : out) {
            if (c == ',') {
                if (!prevComma) { cleaned += ','; prevComma = true; }
            } else {
                cleaned += c;
                prevComma = false;
            }
        }
        // 去掉首尾逗号
        if (!cleaned.empty() && cleaned.front() == ',') cleaned.erase(cleaned.begin());
        if (!cleaned.empty() && cleaned.back() == ',') cleaned.pop_back();
        return cleaned;
    }

    /// 解析封面 URL（替换尺寸占位符）
    static std::string resolveCoverUrl(const std::string& url) {
        std::string out = url;
        std::string::size_type pos;
        while ((pos = out.find("{size}")) != std::string::npos) {
            out.replace(pos, 6, "150");
        }
        return out;
    }
};

/// 酷我音乐客户端
class KuwoClient : public ChineseMusicClientBase {
public:
    explicit KuwoClient(const ScraperConfig& cfg) : ChineseMusicClientBase(cfg) {}

    std::vector<ChineseSong> searchTrack(const std::string& artist,
                                          const std::string& title) override {
        (void)artist;
        std::vector<ChineseSong> songs;
        std::string url = "http://www.kuwo.cn/api/www/search/searchMusicBykeyWord?key=" +
                          urlEncode(title) + "&pn=1&rn=10&httpsStatus=1";
        std::string body;
        long code = 0;
        auto hdrs = buildHeaders();
        if (!httpGet(url, body, &code, hdrs) || code != 200) {
            std::cerr << "[scraper]   酷我 API 失败: HTTP " << code << std::endl;
            return songs;
        }

        try {
            auto j = json::parse(body);
            auto data = j.value("data", json::object());
            for (auto& entry : data.value("list", json::array())) {
                ChineseSong cs;
                cs.id = std::to_string(entry.value("rid", 0));
                cs.name = entry.value("name", "");
                cs.artist = entry.value("artist", "");
                cs.album = entry.value("album", "");
                cs.albumImg = entry.value("albumpic", "");
                cs.year = "";
                cs.resource = "kuwo";
                songs.push_back(std::move(cs));
            }
            std::cerr << "[scraper]   酷我返回 " << songs.size() << " 条结果"
                      << (songs.empty() ? "" : ", 首个albumImg=" + songs[0].albumImg)
                      << std::endl;
        } catch (const json::exception& e) {
            lastError_ = std::string("酷我 JSON 解析失败: ") + e.what();
        }
        return songs;
    }

    std::string fetchLyrics(const std::string& musicId) override {
        if (musicId.empty()) return "";
        // 酷我歌词接口：songinfoandlrc 返回 JSON 格式歌词
        std::string url = "http://kuwo.cn/newh5/singles/songinfoandlrc"
                          "?musicId=" + musicId +
                          "&httpsStatus=1";
        std::string body;
        long code = 0;
        auto hdrs = buildHeaders();
        if (!httpGet(url, body, &code, hdrs) || code != 200) return "";
        try {
            auto j = json::parse(body);
            auto data = j.value("data", json::object());
            auto lrclist = data.value("lrclist", json::array());
            std::string lyrics;
            for (auto& line : lrclist) {
                double time = std::stod(line.value("time", "0"));
                int totalSec = static_cast<int>(time);
                int hh = totalSec / 3600;
                int mm = (totalSec % 3600) / 60;
                int ss = totalSec % 60;
                char ts[16];
                std::snprintf(ts, sizeof(ts), "%02d:%02d:%02d", hh, mm, ss);
                lyrics += "[" + std::string(ts) + "]" + line.value("lineLyric", "") + "\n";
            }
            return lyrics;
        } catch (const std::exception&) {
            return "";
        }
    }

private:
    /// 构建请求头（含 Cross 签名和 Cookie）
    std::vector<std::pair<std::string, std::string>> buildHeaders() {
        if (token_.empty()) token_ = generateToken();
        if (cross_.empty()) cross_ = computeCross(token_);
        return {
            {"User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36"},
            {"Referer", "http://www.kuwo.cn/"},
            {"Cross", cross_},
            {"Cookie", "Hm_token=" + token_},
        };
    }

    /// 生成 32 位随机 token
    static std::string generateToken() {
        static const char chars[] =
            "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
        std::string tok;
        tok.reserve(32);
        for (int i = 0; i < 32; ++i) {
            tok.push_back(chars[std::rand() % (sizeof(chars) - 1)]);
        }
        return tok;
    }

    static std::string computeCross(const std::string& token);

    std::string token_;
    std::string cross_;
};

/// 咪咕音乐客户端
class MiguClient : public ChineseMusicClientBase {
public:
    explicit MiguClient(const ScraperConfig& cfg) : ChineseMusicClientBase(cfg) {}

    std::vector<ChineseSong> searchTrack(const std::string& artist,
                                          const std::string& title) override {
        (void)artist;
        std::vector<ChineseSong> songs;
        std::string url = "https://m.music.migu.cn/migu/remoting/scr_search_tag"
                          "?rows=10&type=2&keyword=" +
                          urlEncode(title) + "&pgc=1";
        std::string body;
        long code = 0;
        std::vector<std::pair<std::string, std::string>> hdrs = {
            {"Referer", "https://m.music.migu.cn/"},
            {"User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:80.0) Gecko/20100101 Firefox/80.0"},
        };
        if (!httpGet(url, body, &code, hdrs) || code != 200) {
            std::cerr << "[scraper]   咪咕 API 失败: HTTP " << code << std::endl;
            return songs;
        }

        try {
            auto j = json::parse(body);
            for (auto& entry : j.value("musics", json::array())) {
                ChineseSong cs;
                cs.id = entry.value("copyrightId", "");
                cs.name = entry.value("songName", "");
                cs.artist = entry.value("singerName", "");
                cs.album = entry.value("albumName", "");
                cs.albumImg = entry.value("cover", "");
                cs.resource = "migu";
                songs.push_back(std::move(cs));
            }
            std::cerr << "[scraper]   咪咕返回 " << songs.size() << " 条结果"
                      << (songs.empty() ? "" : ", 首个albumImg=" + songs[0].albumImg)
                      << std::endl;
        } catch (const json::exception& e) {
            lastError_ = std::string("咪咕 JSON 解析失败: ") + e.what();
        }
        return songs;
    }

    /// 咪咕歌词获取
    std::string fetchLyrics(const std::string& copyrightId) override {
        if (copyrightId.empty()) return "";
        std::string url = "https://music.migu.cn/v3/api/music/audioPlayer/getLyric"
                          "?copyrightId=" + copyrightId;
        std::string body;
        long code = 0;
        std::vector<std::pair<std::string, std::string>> hdrs = {
            {"Referer", "https://m.music.migu.cn/"},
            {"User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:80.0) Gecko/20100101 Firefox/80.0"},
        };
        if (!httpGet(url, body, &code, hdrs) || code != 200) return "";
        try {
            auto j = json::parse(body);
            return j.value("lyric", "");
        } catch (const json::exception&) {
            return "";
        }
    }
};

/// 轻量级线程池（C++17）
/// 用于限制 MetadataResolver 内部多源查询的并发数，避免同时发起过多 HTTP 请求。
class ThreadPool {
public:
    explicit ThreadPool(size_t threads) : stop_(false) {
        for (size_t i = 0; i < threads; ++i) {
            workers_.emplace_back([this] {
                while (true) {
                    std::function<void()> task;
                    {
                        std::unique_lock<std::mutex> lock(queueMutex_);
                        cv_.wait(lock, [this] { return stop_ || !tasks_.empty(); });
                        if (stop_ && tasks_.empty()) return;
                        task = std::move(tasks_.front());
                        tasks_.pop();
                    }
                    task();
                }
            });
        }
    }

    ~ThreadPool() {
        {
            std::unique_lock<std::mutex> lock(queueMutex_);
            stop_ = true;
        }
        cv_.notify_all();
        for (auto& t : workers_) {
            if (t.joinable()) t.join();
        }
    }

    ThreadPool(const ThreadPool&) = delete;
    ThreadPool& operator=(const ThreadPool&) = delete;

    template <class F, class... Args>
    auto enqueue(F&& f, Args&&... args)
        -> std::future<std::invoke_result_t<F, Args...>> {
        using return_type = std::invoke_result_t<F, Args...>;
        auto task = std::make_shared<std::packaged_task<return_type()>>(
            std::bind(std::forward<F>(f), std::forward<Args>(args)...));
        std::future<return_type> res = task->get_future();
        {
            std::unique_lock<std::mutex> lock(queueMutex_);
            tasks_.emplace([task]() { (*task)(); });
        }
        cv_.notify_one();
        return res;
    }

private:
    std::vector<std::thread> workers_;
    std::queue<std::function<void()>> tasks_;
    std::mutex queueMutex_;
    std::condition_variable cv_;
    bool stop_;
};

/// 多源元数据解析器
/// 整合 MusicBrainz + Deezer + iTunes + Cover Art Archive + LRCLIB
/// 以及中文音乐源（网易云/QQ/酷狗/酷我/咪咕），多源并发查询
/// 支持 AcoustID 音频指纹回退（无标签文件识别）

// ============================================================================
// AcoustID 客户端 —— 音频指纹识别
// ============================================================================
// 参考 MusicBrainz Picard / Music Tag Web 的做法：
//   1. 使用 fpcalc (Chromaprint) 生成音频指纹
//   2. 通过 AcoustID API 查询指纹对应的 MusicBrainz Recording ID
//   3. 用 MBID 回退到 MusicBrainz 获取完整元数据
//
// 这解决了无标签或标签完全错误文件的识别问题：
// 即使文件名不包含任何有用信息，也可以通过音频内容识别歌曲。
// ============================================================================

/// 音频指纹结果
struct AcoustIDResult {
    std::string fingerprint;         ///< Chromaprint 指纹字符串
    int durationSec = 0;             ///< 音频时长（秒）
    std::string recordingId;         ///< 匹配的 MusicBrainz Recording ID
    std::string releaseGroupId;      ///< 匹配的 MusicBrainz Release Group ID
    double score = 0.0;              ///< 匹配得分（0~1）
    std::string title;               ///< AcoustID 返回的标题
    std::string artist;              ///< AcoustID 返回的艺术家
};

/// AcoustID 客户端
///
/// 音频指纹识别工作流：
///   1. 调用 fpcalc 子进程生成 Chromaprint 指纹和时长
///   2. POST 指纹到 AcoustID API 查询 Recording ID
///   3. 返回最佳匹配的 MBID
///
/// AcoustID API 限制：
///   - 免费 API key 每秒 1 次请求（与 MusicBrainz 共享限速）
///   - 指纹格式：Chromaprint compressed string
class AcoustIDClient {
public:
    explicit AcoustIDClient(const ScraperConfig& cfg) : cfg_(cfg) {
        curl_ = curl_easy_init();
        if (!curl_) throw std::runtime_error("curl_easy_init 失败");
    }
    ~AcoustIDClient() { if (curl_) curl_easy_cleanup(curl_); }

    AcoustIDClient(const AcoustIDClient&) = delete;
    AcoustIDClient& operator=(const AcoustIDClient&) = delete;

    /// 生成音频指纹（调用 fpcalc）
    /// @returns 指纹字符串，失败时返回空
    static std::string generateFingerprint(const std::string& filePath, int& outDurationSec) {
        outDurationSec = 0;
        // fpcalc -json -length 120 <file>
        // -length 120 表示只分析前 120 秒（足够识别，节省时间）
        // 重定向空设备：POSIX /dev/null，Windows NUL
#ifdef _WIN32
        std::string cmd = "fpcalc -json -length 120 \"" + filePath + "\" 2>NUL";
#else
        std::string cmd = "fpcalc -json -length 120 \"" + filePath + "\" 2>/dev/null";
#endif
        FILE* pipe = popen(cmd.c_str(), "r");
        if (!pipe) return "";

        std::string output;
        char buf[4096];
        while (fgets(buf, sizeof(buf), pipe)) output += buf;
        int rc = pclose(pipe);
        if (rc != 0 || output.empty()) return "";

        try {
            auto j = json::parse(output);
            if (j.contains("fingerprint") && j.contains("duration")) {
                outDurationSec = static_cast<int>(j["duration"].get<double>());
                return j["fingerprint"].get<std::string>();
            }
        } catch (const json::exception&) {}
        return "";
    }

    /// 通过 AcoustID API 查询指纹对应的 Recording
    ///
    /// API: POST https://api.acoustid.org/v2/lookup
    /// 参数：client, duration, fingerprint, meta=recordings+releasegroups
    ///
    /// @returns 匹配结果列表（按得分降序）
    std::vector<AcoustIDResult> lookup(const std::string& fingerprint, int durationSec) {
        std::vector<AcoustIDResult> results;
        if (fingerprint.empty() || durationSec <= 0) return results;

        rateLimit();

        std::string url = "https://api.acoustid.org/v2/lookup";
        std::string postData = "client=" + urlEncode(cfg_.acoustidApiKey) +
                               "&duration=" + std::to_string(durationSec) +
                               "&fingerprint=" + urlEncode(fingerprint) +
                               "&meta=recordings+releasegroups";

        std::string body;
        long code = 0;
        if (!httpPost(url, postData, "application/x-www-form-urlencoded", body, &code) || code != 200) {
            lastError_ = "AcoustID 查询失败: HTTP " + std::to_string(code);
            return results;
        }

        try {
            auto j = json::parse(body);
            if (j.contains("status") && j["status"].get<std::string>() != "ok") return results;
            if (!j.contains("results") || !j["results"].is_array()) return results;

            for (auto& r : j["results"]) {
                AcoustIDResult ar;
                ar.fingerprint = fingerprint;
                ar.durationSec = durationSec;
                ar.score = r.value("score", 0.0);

                if (r.contains("recordings") && !r["recordings"].empty()) {
                    auto& rec = r["recordings"][0];
                    if (rec.contains("id")) ar.recordingId = rec["id"].get<std::string>();
                    if (rec.contains("title")) ar.title = rec["title"].get<std::string>();
                    if (rec.contains("artists") && !rec["artists"].empty()) {
                        ar.artist = rec["artists"][0].value("name", "");
                    }
                    if (rec.contains("releasegroups") && !rec["releasegroups"].empty()) {
                        ar.releaseGroupId = rec["releasegroups"][0].value("id", "");
                    }
                }
                if (!ar.recordingId.empty()) results.push_back(std::move(ar));
            }

            // 按得分降序排列
            std::sort(results.begin(), results.end(),
                      [](const AcoustIDResult& a, const AcoustIDResult& b) {
                          return a.score > b.score;
                      });
        } catch (const json::exception& e) {
            lastError_ = std::string("AcoustID JSON 解析失败: ") + e.what();
        }

        return results;
    }

    const std::string& lastError() const { return lastError_; }

private:
    void rateLimit() {
        auto now = std::chrono::steady_clock::now();
        auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(now - lastReq_);
        if (elapsed.count() < cfg_.rateLimitMs) {
            std::this_thread::sleep_for(
                std::chrono::milliseconds(cfg_.rateLimitMs - elapsed.count()));
        }
        lastReq_ = std::chrono::steady_clock::now();
    }

    bool httpPost(const std::string& url, const std::string& data,
                  const std::string& contentType, std::string& body, long* code) {
        body.clear();
        curl_easy_setopt(curl_, CURLOPT_URL, url.c_str());
        curl_easy_setopt(curl_, CURLOPT_POSTFIELDS, data.c_str());
        curl_easy_setopt(curl_, CURLOPT_POSTFIELDSIZE, static_cast<long>(data.size()));
        curl_easy_setopt(curl_, CURLOPT_WRITEFUNCTION, ::archoera::scraper::writeCb);
        curl_easy_setopt(curl_, CURLOPT_WRITEDATA, &body);
        curl_easy_setopt(curl_, CURLOPT_USERAGENT, cfg_.userAgent.c_str());
        curl_easy_setopt(curl_, CURLOPT_TIMEOUT_MS, cfg_.requestTimeoutMs);
        curl_easy_setopt(curl_, CURLOPT_FOLLOWLOCATION, 1L);

        struct curl_slist* headers = nullptr;
        std::string ctHeader = "Content-Type: " + contentType;
        headers = curl_slist_append(headers, ctHeader.c_str());
        curl_easy_setopt(curl_, CURLOPT_HTTPHEADER, headers);

        CURLcode res = curl_easy_perform(curl_);
        if (code) curl_easy_getinfo(curl_, CURLINFO_RESPONSE_CODE, code);
        if (headers) curl_slist_free_all(headers);
        return res == CURLE_OK;
    }

    CURL* curl_ = nullptr;
    const ScraperConfig& cfg_;
    std::chrono::steady_clock::time_point lastReq_ = std::chrono::steady_clock::now();
    std::string lastError_;
};

class MetadataResolver {
public:
    explicit MetadataResolver(const ScraperConfig& cfg)
        : cfg_(cfg),
          pool_(static_cast<size_t>(std::max(1, cfg.concurrentWorkers))),
          mb_(cfg), dz_(cfg), it_(cfg), cover_(cfg), lyrics_(cfg),
          ne_(cfg), qq_(cfg), kg_(cfg), kw_(cfg), mg_(cfg),
          acoustid_(cfg) {

    }

    /// 解析单个曲目的完整元数据
    ///
    /// 多源并发策略：
    ///   1. 启动所有启用的数据源（MusicBrainz/Deezer/iTunes/网易云/QQ/酷狗/酷我/咪咕）
    ///      并发查询，使用 std::async + std::future
    ///   2. 等待所有 future 完成（带超时保护），收集每个源的结果
    ///   3. 按优先级合并：MusicBrainz（最权威）→ 西方源 → 中文源
    ///   4. 封面获取：Cover Art Archive → 各源提供的封面 URL
    ///   5. 歌词获取：LRCLIB → 中文源歌词
    ScrapeResult resolve(const TrackInfo& track) {
        ScrapeResult result;
        result.trackId = track.id;

        // ====================================================================
        // 阶段 1：并发查询所有启用的数据源
        // ====================================================================
        // 西方源 future（返回 ScrapeResult + 封面 URL）
        std::future<std::pair<ScrapeResult, std::string>> mbFuture, dzFuture, itFuture;
        // 中文源 future（返回候选列表）
        std::future<std::vector<ChineseSong>> neFuture, qqFuture, kgFuture, kwFuture, mgFuture;

        if (cfg_.useMusicBrainz) {
            mbFuture = pool_.enqueue([this, &track]() {
                std::string coverUrl;
                ScrapeResult r = mb_.queryRecording(track);
                return std::make_pair(r, coverUrl);
            });
        }
        if (cfg_.useDeezer) {
            dzFuture = pool_.enqueue([this, &track]() {
                std::string coverUrl;
                ScrapeResult r;
                dz_.searchTrack(track.artist, track.title, r, coverUrl);
                return std::make_pair(r, coverUrl);
            });
        }
        if (cfg_.useItunes) {
            itFuture = pool_.enqueue([this, &track]() {
                std::string coverUrl;
                ScrapeResult r;
                it_.searchTrack(track.artist, track.title, r, coverUrl);
                return std::make_pair(r, coverUrl);
            });
        }
        if (cfg_.useNetease) {
            neFuture = pool_.enqueue([this, &track]() {
                return ne_.searchTrack(track.artist, track.title);
            });
        }
        if (cfg_.useQQMusic) {
            qqFuture = pool_.enqueue([this, &track]() {
                return qq_.searchTrack(track.artist, track.title);
            });
        }
        if (cfg_.useKugou) {
            kgFuture = pool_.enqueue([this, &track]() {
                return kg_.searchTrack(track.artist, track.title);
            });
        }
        if (cfg_.useKuwo) {
            kwFuture = pool_.enqueue([this, &track]() {
                return kw_.searchTrack(track.artist, track.title);
            });
        }
        if (cfg_.useMigu) {
            mgFuture = pool_.enqueue([this, &track]() {
                return mg_.searchTrack(track.artist, track.title);
            });
        }

        // ====================================================================
        // 阶段 2：收集所有通过严格匹配的源，统一评分排序后合并
        // ====================================================================
        // scoredSource = { 结果, 来源名称, 匹配评分 (0-100) }
        struct ScoredSource {
            ScrapeResult sr;
            std::string source;
            int score;
        };
        std::vector<ScoredSource> scoredSources;

        // 封面/歌词辅助 URL
          std::string dzCoverUrl, itCoverUrl;
          std::string bestChineseSource;
          // 所有中文源封面候选（按评分降序，下载时逐个回退）
          struct ChineseCoverCandidate {
              std::string source;
              std::string url;
              int score;
          };
          std::vector<ChineseCoverCandidate> chineseCoverCandidates;

        // 2.1 MusicBrainz（永久最高评分 100，直接作为基础）
        //     MusicBrainz 内部已校验 isSimilar 双向匹配，不匹配会清空元数据
        if (mbFuture.valid()) {
            try {
                auto pair = mbFuture.get();
                result = pair.first;  // MB 是唯一可直接赋值的源
                scoredSources.push_back({result, "musicbrainz", 100});
            } catch (const std::exception& e) {
                lastError_ = std::string("MusicBrainz 失败: ") + e.what();
            }
        }

        // 2.1b AcoustID 音频指纹回退（MusicBrainz 未返回 MBID 时）
        // 参考 MusicBrainz Picard 的 Lookup 模式：
        // 当文本搜索无结果时，用音频指纹识别，再从 MBID 获取元数据
        if (cfg_.useAcoustID && !result.mbid && !track.filePath.empty()) {
            int durationSec = 0;
            std::string fp = AcoustIDClient::generateFingerprint(track.filePath, durationSec);
            if (!fp.empty()) {
                auto acoustResults = acoustid_.lookup(fp, durationSec);
                for (auto& ar : acoustResults) {
                    if (ar.score * 100.0 < cfg_.acoustidMinScore) continue;
                    // 用指纹返回的 MBID 回退 MusicBrainz 查询
                    result.mbid = ar.recordingId;
                    mb_.rateLimit();
                    std::string detailUrl = "https://musicbrainz.org/ws/2/recording/" +
                        *result.mbid + "?inc=genres+labels+artist-credits+releases+isrcs+artist-rels+recording-rels&fmt=json";
                    std::string detailBody;
                    long detailCode = 0;
                    if (mb_.httpGet(detailUrl, detailBody, &detailCode) && detailCode == 200) {
                        try {
                            auto j = json::parse(detailBody);
                            if (j.contains("title")) result.title = j["title"].get<std::string>();
                            if (j.contains("genres") && !j["genres"].empty())
                                result.genre = j["genres"][0]["name"].get<std::string>();
                            if (j.contains("releases") && !j["releases"].empty()) {
                                auto& rel = j["releases"][0];
                                if (rel.contains("date") && rel["date"].is_string()) {
                                    std::string ds = rel["date"].get<std::string>();
                                    if (ds.length() >= 4) {
                                        try { result.year = std::stoi(ds.substr(0, 4)); } catch (...) {}
                                    }
                                }
                                if (rel.contains("label-info") && !rel["label-info"].empty()) {
                                    if (rel["label-info"][0].contains("label") &&
                                        rel["label-info"][0]["label"].contains("name"))
                                        result.label = rel["label-info"][0]["label"]["name"].get<std::string>();
                                }
                                if (rel.contains("media") && rel["media"].is_array() && !rel["media"].empty()) {
                                    auto& m = rel["media"][0];
                                    if (m.contains("track-count")) result.trackTotal = m["track-count"].get<int>();
                                    if (m.contains("position")) result.discNumber = m["position"].get<int>();
                                    if (rel.contains("media") && rel["media"].is_array())
                                        result.discTotal = static_cast<int>(rel["media"].size());
                                }
                            }
                            if (j.contains("artist-credit") && !j["artist-credit"].empty()) {
                                if (j["artist-credit"][0].contains("name"))
                                    result.artist = j["artist-credit"][0]["name"].get<std::string>();
                                if (j["artist-credit"][0].contains("artist") &&
                                    j["artist-credit"][0]["artist"].contains("id"))
                                    result.artistMbid = j["artist-credit"][0]["artist"]["id"].get<std::string>();
                            }
                            result.scrapedSources.push_back("acoustid");
                            std::cerr << "[scraper]   🔍 音频指纹识别成功 (score="
                                      << static_cast<int>(ar.score * 100) << "%): "
                                      << result.artist.value_or("?") << " - "
                                      << result.title.value_or("?") << std::endl;
                            break;  // 找到第一个高分匹配即停止
                        } catch (const json::exception&) {}
                    }
                }
            }
        }

        // 2.2 Deezer
        if (dzFuture.valid()) {
            try {
                auto pair = dzFuture.get();
                if (pair.first.title || pair.first.artist) {
                    int s = scoreResult(pair.first, track);
                    scoredSources.push_back({pair.first, "deezer", s});
                }
                dzCoverUrl = pair.second;
            } catch (const std::exception& e) {
                lastError_ = std::string("Deezer 失败: ") + e.what();
            }
        }

        // 2.3 iTunes
        if (itFuture.valid()) {
            try {
                auto pair = itFuture.get();
                if (pair.first.title || pair.first.artist) {
                    int s = scoreResult(pair.first, track);
                    scoredSources.push_back({pair.first, "itunes", s});
                }
                itCoverUrl = pair.second;
            } catch (const std::exception& e) {
                lastError_ = std::string("iTunes 失败: ") + e.what();
            }
        }

        // 2.4-2.8 中文源：收集所有通过评分的候选，统一排序后合并
        // 源优先级仅用于同分 tie-break：网易云 > QQ > 酷狗 > 酷我 > 咪咕
        struct ChineseResult {
            std::vector<ChineseSong> songs;
            std::string name;
            int priority;
        };
        std::vector<ChineseResult> chineseResults;

        if (neFuture.valid()) {
            try { chineseResults.push_back({neFuture.get(), "netease", 5}); }
            catch (const std::exception&) {}
        }
        if (qqFuture.valid()) {
            try { chineseResults.push_back({qqFuture.get(), "qmusic", 4}); }
            catch (const std::exception&) {}
        }
        if (kgFuture.valid()) {
            try { chineseResults.push_back({kgFuture.get(), "kugou", 3}); }
            catch (const std::exception&) {}
        }
        if (kwFuture.valid()) {
            try { chineseResults.push_back({kwFuture.get(), "kuwo", 2}); }
            catch (const std::exception&) {}
        }
        if (mgFuture.valid()) {
            try { chineseResults.push_back({mgFuture.get(), "migu", 1}); }
            catch (const std::exception&) {}
        }

        static constexpr int CHINESE_MIN_SCORE = 2;
        int bestChineseScore = -1;  // 记录最高评分，用于选择最佳封面源
        int totalPassed = 0;        // 通过评分门槛的歌曲数
        for (const auto& cr : chineseResults) {
            int srcPassed = 0;
            for (const auto& song : cr.songs) {
                int rawScore = scoreChineseSong(song, track);
                if (rawScore < CHINESE_MIN_SCORE) continue;
                ++srcPassed; ++totalPassed;
                // 归一化到 0-100：原始分 0-14，乘 7 = 0-98，加源优先级（0-5）
                int score = rawScore * 7 + cr.priority;
                ScrapeResult sr;
                ChineseMusicClientBase::toScrapeResult(song, sr, cr.name);
                scoredSources.push_back({sr, cr.name, score});
                // 收集所有有封面的中文源候选（按评分降序回退）
                if (!song.albumImg.empty()) {
                    chineseCoverCandidates.push_back({cr.name, song.albumImg, score});
                }
                // 记住评分最高的中文源（用于歌词回退等）
                if (score > bestChineseScore) {
                    bestChineseScore = score;
                    bestChineseSource = cr.name;
                }
            }
            std::cerr << "[scraper]   " << cr.name << ": " << cr.songs.size()
                      << " 结果, " << srcPassed << " 通过评分" << std::endl;
        }

        // 按评分降序排序中文封面候选
        std::sort(chineseCoverCandidates.begin(), chineseCoverCandidates.end(),
            [](const ChineseCoverCandidate& a, const ChineseCoverCandidate& b) {
                return a.score > b.score;
            });

        if (!chineseCoverCandidates.empty()) {
            std::cerr << "[scraper]   中文源封面候选: " << chineseCoverCandidates.size() << " 个"
                      << " (最佳: " << chineseCoverCandidates[0].source
                      << " score=" << chineseCoverCandidates[0].score << ")" << std::endl;
        } else {
            std::cerr << "[scraper]   中文源未返回有效封面 URL（"
                      << chineseResults.size() << " 个源）" << std::endl;
        }

        // ====================================================================
        // 阶段 2.9：按评分降序排序，统一合并
        // ====================================================================
        std::sort(scoredSources.begin(), scoredSources.end(),
            [](const ScoredSource& a, const ScoredSource& b) { return a.score > b.score; });

        // 合并核心身份字段（title/artist/album/albumArtist/mbid）
        // 按评分遍历，取首个有实际身份数据的源
        // 避免 MusicBrainz 对中文歌返回空结果时阻塞中文源的身份字段
        for (const auto& ss : scoredSources) {
            if (ss.sr.title || ss.sr.artist || ss.sr.mbid) {
                mergeIdentity(result, ss.sr);
                break;
            }
        }

        // 所有通过严格匹配的源合并辅助字段（按评分顺序：高分优先）
        for (const auto& ss : scoredSources) {
            mergeBetter(result, ss.sr);
        }

        // ====================================================================
        // 阶段 3：封面获取（按优先级：Cover Art Archive → Deezer → iTunes → 中文源）
        // ====================================================================
        if (cfg_.embedCover && result.coverData.empty()) {
            std::cerr << "[scraper]   封面来源状态: albumMbid=" << (result.albumMbid ? *result.albumMbid : "(无)")
                      << ", dzCoverUrl=" << (dzCoverUrl.empty() ? "(空)" : dzCoverUrl)
                      << ", itCoverUrl=" << (itCoverUrl.empty() ? "(空)" : itCoverUrl)
                      << ", chineseCandidates=" << chineseCoverCandidates.size() << " 个"
                      << std::endl;
            bool gotCover = false;
            if (result.albumMbid) {
                gotCover = cover_.fetchCover(*result.albumMbid, result);
                if (!gotCover) {
                    std::cerr << "[scraper]   ⚠ Cover Art Archive 获取失败 (albumMbid=" << *result.albumMbid << ")" << std::endl;
                }
            }
            if (!gotCover && !dzCoverUrl.empty()) {
                std::cerr << "[scraper]   尝试 Deezer 封面: " << dzCoverUrl << std::endl;
                gotCover = dz_.fetchCover(dzCoverUrl, result);
                if (!gotCover) {
                    std::cerr << "[scraper]   ⚠ Deezer 封面下载失败" << std::endl;
                }
            }
            if (!gotCover && !itCoverUrl.empty()) {
                std::cerr << "[scraper]   尝试 iTunes 封面: " << itCoverUrl << std::endl;
                gotCover = it_.fetchCover(itCoverUrl, result);
                if (!gotCover) {
                    std::cerr << "[scraper]   ⚠ iTunes 封面下载失败" << std::endl;
                }
            }
            // 中文源：按评分降序逐个尝试，任一成功即停止
            for (const auto& cc : chineseCoverCandidates) {
                if (gotCover) break;
                std::cerr << "[scraper]   尝试 " << cc.source << " 封面 (score=" << cc.score << "): "
                          << cc.url.substr(0, 80) << (cc.url.size() > 80 ? "..." : "") << std::endl;
                gotCover = fetchChineseCover(cc.source, cc.url, result);
                if (!gotCover) {
                    std::cerr << "[scraper]   ⚠ " << cc.source << " 封面下载失败" << std::endl;
                }
            }
            if (!gotCover) {
                std::cerr << "[scraper]   ⚠ 未获取到封面（所有源均失败或 URL 为空）" << std::endl;
            }
        }

        // ====================================================================
        // 阶段 4：歌词获取（LRCLIB 优先，中文源补充）
        // ====================================================================
        if (cfg_.embedLyrics) {
            std::string artist = result.artist.value_or(track.artist);
            std::string title = result.title.value_or(track.title);
            std::string album = result.album.value_or(track.album);
            int durationSec = track.durationMs / 1000;
            bool gotLyrics = false;
            if (!artist.empty() && !title.empty()) {
                gotLyrics = lyrics_.fetchLyrics(artist, title, album, durationSec, result);
            }
            // LRCLIB 没拿到，尝试中文源歌词
            if (!gotLyrics && !bestChineseSource.empty() &&
                (!result.lyrics.has_value() || result.lyrics->empty())) {
                std::string songId = findChineseSongId(bestChineseSource, track);
                if (!songId.empty()) {
                    std::string lrc = fetchChineseLyrics(bestChineseSource, songId);
                    if (!lrc.empty()) {
                        result.lyrics = lrc;
                    }
                }
            }
        }

        return result;
    }

private:
    /// 核心身份字段：仅填补空值，不覆盖已有数据
    /// title / artist / album / albumArtist 决定整理路径，必须保守合并
    /// mbid / isrc 是唯一标识符，来自最权威源
    static void mergeIdentity(ScrapeResult& result, const ScrapeResult& src) {
        if (!result.title && src.title) result.title = src.title;
        if (!result.artist && src.artist) result.artist = src.artist;
        if (!result.album && src.album) result.album = src.album;
        if (!result.albumArtist && src.albumArtist) result.albumArtist = src.albumArtist;
        if (!result.mbid && src.mbid) result.mbid = src.mbid;
        if (!result.albumMbid && src.albumMbid) result.albumMbid = src.albumMbid;
        if (!result.artistMbid && src.artistMbid) result.artistMbid = src.artistMbid;
        if (!result.isrc && src.isrc) result.isrc = src.isrc;
        collectSources(result, src);
    }

    /// 辅助元数据字段：多源汇集，优质覆盖劣质
    /// 所有通过 artist+title 严格匹配的源均可贡献，不局限于先到先得
    static void mergeBetter(ScrapeResult& result, const ScrapeResult& src) {
        // 流派：拼接所有匹配源的不同流派（逗号分隔，自动去重）
        if (src.genre && !src.genre->empty()) {
            if (!result.genre || result.genre->empty()) {
                result.genre = src.genre;
            } else if (*result.genre != *src.genre &&
                       result.genre->find(*src.genre) == std::string::npos) {
                *result.genre += ", " + *src.genre;
            }
        }
        // 作曲家：优先取非空的
        if ((!result.composer || result.composer->empty()) &&
            src.composer && !src.composer->empty())
            result.composer = src.composer;
        // 唱片公司：同上
        if ((!result.label || result.label->empty()) &&
            src.label && !src.label->empty())
            result.label = src.label;
        // 年份：优先取非零值
        if ((!result.year || *result.year == 0) && src.year && *src.year > 0)
            result.year = src.year;
        // 曲目/碟片编号：取非空值
        if (!result.trackNumber && src.trackNumber) result.trackNumber = src.trackNumber;
        if (!result.trackTotal && src.trackTotal) result.trackTotal = src.trackTotal;
        if (!result.discNumber && src.discNumber) result.discNumber = src.discNumber;
        if (!result.discTotal && src.discTotal) result.discTotal = src.discTotal;
        collectSources(result, src);
    }

    /// 收敛 scrapedSources 去重
    static void collectSources(ScrapeResult& result, const ScrapeResult& src) {
        for (const auto& s : src.scrapedSources) {
            bool exists = false;
            for (const auto& existing : result.scrapedSources) {
                if (existing == s) { exists = true; break; }
            }
            if (!exists) result.scrapedSources.push_back(s);
        }
    }

    /// 统一评分：按文件名 artist+title 对任何 ScrapeResult 打分（0-100）
    /// artist 与 title 各自独立匹配，任一低于 0.5 视为不相关（返回 0）
    static int scoreResult(const ScrapeResult& r, const TrackInfo& track) {
        std::string rArtist = r.artist.value_or("");
        std::string rTitle = r.title.value_or("");
        if (rArtist.empty() || rTitle.empty()) return 0;
        double aSim = ::archoera::scraper::similarity(rArtist, track.artist);
        double tSim = ::archoera::scraper::similarity(rTitle, track.title);
        if (aSim < 0.5 || tSim < 0.5) return 0;  // 任一不匹配
        // artist 权重 40%，title 权重 60%（标题更能区分曲目）
        return static_cast<int>(aSim * 40 + tSim * 60);
    }

    /// 评分中文源候选
    ///
    /// 文件名优先匹配：artist 与 title 必须分别匹配（score >= 1），
    /// 任一不匹配则舍弃整个候选（返回 -1）。
    /// 通过双门槛后才计算加权总分用于同台竞技排序。
    ///
    /// @returns -1 表示舍弃，0-14 表示有效评分
    static int scoreChineseSong(const ChineseSong& song, const TrackInfo& track) {
        int titleScore = ChineseMusicClientBase::matchScore(song.name, track.title);
        // 当文件 artist 标签为空时，跳过 artist 匹配（常见于标签不完整的文件）
        int artistScore = track.artist.empty() ? 1 :
                          ChineseMusicClientBase::matchArtist(song.artist, track.artist);
        // 任一不匹配 → 舍弃（artist 空时仅要求 title 匹配）
        if (titleScore == 0 || artistScore == 0) return -1;
        int albumScore = track.album.empty() ? 0 :
                         ChineseMusicClientBase::matchScore(song.album, track.album);
        // 标题权重最高，艺术家次之，专辑最低
        return titleScore * 4 + artistScore * 2 + albumScore;
    }

    /// 根据源名称获取封面（带防盗链 Referer）
    bool fetchChineseCover(const std::string& source, const std::string& coverUrl,
                           ScrapeResult& result) {
        // 各中文源的 Referer 防盗链要求
        static const std::unordered_map<std::string, std::string> refererMap = {
            {"netease", "https://music.163.com"},
            {"qmusic", "https://y.qq.com"},
            {"kugou", "https://www.kugou.com"},
            {"kuwo", "http://www.kuwo.cn"},
            {"migu", "https://m.music.migu.cn"},
        };
        std::string referer;
        auto it = refererMap.find(source);
        if (it != refererMap.end()) referer = it->second;

        if (source == "netease") return ne_.fetchCover(coverUrl, result, referer);
        if (source == "qmusic") return qq_.fetchCover(coverUrl, result, referer);
        if (source == "kugou") return kg_.fetchCover(coverUrl, result, referer);
        if (source == "kuwo") return kw_.fetchCover(coverUrl, result, referer);
        if (source == "migu") return mg_.fetchCover(coverUrl, result, referer);
        return false;
    }

    /// 根据源名称获取歌词
    std::string fetchChineseLyrics(const std::string& source, const std::string& songId) {
        if (source == "netease") return ne_.fetchLyrics(songId);
        if (source == "qmusic") return qq_.fetchLyrics(songId);
        if (source == "kugou") return kg_.fetchLyrics(songId);
        if (source == "kuwo") return kw_.fetchLyrics(songId);
        if (source == "migu") return mg_.fetchLyrics(songId);
        return "";
    }

    /// 在指定源中重新搜索并返回最佳匹配的 songId（用于歌词获取）
    std::string findChineseSongId(const std::string& source, const TrackInfo& track) {
        std::vector<ChineseSong> songs;
        if (source == "netease") songs = ne_.searchTrack(track.artist, track.title);
        else if (source == "qmusic") songs = qq_.searchTrack(track.artist, track.title);
        else if (source == "kugou") songs = kg_.searchTrack(track.artist, track.title);
        else if (source == "kuwo") songs = kw_.searchTrack(track.artist, track.title);
        else if (source == "migu") songs = mg_.searchTrack(track.artist, track.title);

        const ChineseSong* best = nullptr;
        int bestScore = -1;
        for (const auto& s : songs) {
            int score = scoreChineseSong(s, track);
            if (score > bestScore) {
                bestScore = score;
                best = &s;
            }
        }
        return best ? best->id : "";
    }

    const ScraperConfig& cfg_;
    ThreadPool pool_;        ///< 限制多源查询并发数
    MusicBrainzClient mb_;
    DeezerClient dz_;
    ItunesClient it_;
    CoverArtArchiveClient cover_;
    LrclibClient lyrics_;
    NeteaseClient ne_;       ///< 网易云
    QQMusicClient qq_;       ///< QQ 音乐
    KugouClient kg_;         ///< 酷狗
    KuwoClient kw_;          ///< 酷我
    MiguClient mg_;          ///< 咪咕
    AcoustIDClient acoustid_; ///< 音频指纹识别
    std::string lastError_;
};

inline std::string KuwoClient::computeCross(const std::string& token) {
    // 酷我 Cross 头算法：
    //   1. SHA1(token) → 40 字符 hex 串
    //   2. MD5(hex串) → 32 字符 hex 串（即 Cross 值）
    unsigned char sha1Digest[EVP_MAX_MD_SIZE];
    unsigned int sha1Len = 0;
    EVP_Digest(token.c_str(), token.size(), sha1Digest, &sha1Len, EVP_sha1(), nullptr);

    // SHA1 结果转 hex
    std::string sha1Hex;
    for (unsigned int i = 0; i < sha1Len; ++i) {
        char buf[3];
        snprintf(buf, sizeof(buf), "%02x", sha1Digest[i]);
        sha1Hex += buf;
    }

    // MD5(sha1Hex)
    unsigned char md5Digest[EVP_MAX_MD_SIZE];
    unsigned int md5Len = 0;
    EVP_Digest(sha1Hex.c_str(), sha1Hex.size(), md5Digest, &md5Len, EVP_md5(), nullptr);

    std::string cross;
    for (unsigned int i = 0; i < md5Len; ++i) {
        char buf[3];
        snprintf(buf, sizeof(buf), "%02x", md5Digest[i]);
        cross += buf;
    }
    return cross;
}

} // namespace archoera::scraper

