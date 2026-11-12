// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

#pragma once

/// Archoera 刮削器 —— 曲目元数据读取客户端（header-only）
///
/// 两种取数途径（provider 优先，非端口化）：
///   - TrackProvider：FFI 宿主注入的内存曲目表（Dart 直连，无本地端口）
///   - HTTP 兜底：GET /api/db/tracks/:id（仅 Web 兼容模式，apiUrl 非空时）
///
/// 队列操作已改为直写 scraper-state.db（ScraperDb），不再走 HTTP。
/// 刮削结果写入音频文件标签后由 C# Scanner 接管入库，也无需 HTTP。

#include "scraper.h"
#include "scraper_http.h"
#include <nlohmann/json.hpp>
#include <functional>
#include <stdexcept>

namespace archoera::scraper {

using json = nlohmann::json;

class DbClient {
public:
    /// 曲目提供者：入参 trackId，返回与 /api/db/tracks/:id 同构的 JSON 字符串；
    /// 返回空串表示未找到。由 FFI 宿主注入，避免本地 HTTP 端口。
    using TrackProvider = std::function<std::string(const std::string& trackId)>;

    DbClient(const std::string& apiUrl, const std::string& proxyKey)
        : apiUrl_(apiUrl), proxyKey_(proxyKey)
    {
        if (apiUrl_.empty()) return;  // 纯 provider 模式不使用 HTTP
        headers_ = {
            {"x-proxy-key", proxyKey_},
            {"Content-Type", "application/json"},
        };
    }

    ~DbClient() = default;

    DbClient(const DbClient&) = delete;
    DbClient& operator=(const DbClient&) = delete;

    void setTrackProvider(TrackProvider fn) { provider_ = std::move(fn); }

    /// 获取曲目元数据（provider 优先，HTTP 兜底）
    std::optional<TrackInfo> getTrack(const std::string& trackId) {
        if (provider_) {
            auto body = provider_(trackId);
            if (body.empty()) {
                lastError_ = "track not provided: " + trackId;
                return std::nullopt;
            }
            return parseTrack(body, trackId);
        }

        if (apiUrl_.empty()) {
            lastError_ = "no track provider and no apiUrl";
            return std::nullopt;
        }

        std::string url = apiUrl_ + "/api/db/tracks/" + trackId;
        std::string body;
        if (!httpGet(url, body)) return std::nullopt;
        return parseTrack(body, trackId);
    }

    const std::string& lastError() const { return lastError_; }

private:
    std::optional<TrackInfo> parseTrack(const std::string& body, const std::string& trackId) {
        try {
            auto j = json::parse(body);
            TrackInfo t;
            t.id = j.value("id", trackId);
            t.title = j.value("title", "");
            t.artist = j.value("artist", "");
            t.album = j.value("album", "");
            t.albumArtist = j.value("album_artist", "");
            t.composer = j.value("composer", "");
            t.trackNumber = j.value("track", 0);
            t.discNumber = j.value("disc", 0);
            t.durationMs = j.value("duration", 0);
            t.filePath = j.value("path", "");
            t.mbid = j.value("mbid", "");
            t.albumMbid = j.value("album_mbid", "");
            t.artistMbid = j.value("artist_mbid", "");
            t.isrc = j.value("isrc", "");
            return t;
        } catch (const json::exception& e) {
            lastError_ = std::string("曲目解析失败: ") + e.what();
            return std::nullopt;
        }
    }

    bool httpGet(const std::string& url, std::string& body) {
        body.clear();
        std::string err;
        long code = 0;
        if (!http_.perform("GET", url, std::string(), 10000L, headers_, nullptr,
                           body, &code, err)) {
            lastError_ = "GET 失败: " + err;
            return false;
        }
        return true;
    }

    HttpClient http_;
    HeaderList headers_;
    std::string apiUrl_;
    std::string proxyKey_;
    std::string lastError_;
    TrackProvider provider_;
};

} // namespace archoera::scraper
