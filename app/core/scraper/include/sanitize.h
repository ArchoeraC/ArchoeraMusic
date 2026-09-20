// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

#pragma once

/// Archoera 刮削器 —— 内置元数据广告清洗（header-only）。
///
/// 与下载引擎 `app/core/downloader/src/sanitize.rs` 和桌面端
/// `app/lib/services/lyrics/ad_filter.dart` **同规则**：第三方/直传来源的
/// 标签常夹带站点推广（「资源来自 XX 云音乐」「获取更多无损音乐 https://…」、
/// 公众号/群号等）。刮削写标签前统一清洗，保证所有端一致。
///
/// - 字段值整体命中广告 → 删除该字段；
/// - 歌词逐行命中广告 → 删除该行。
///
/// 只收录**强推广信号**，避免误伤正规歌词（含 URL 的行几乎必为推广）。

#include <algorithm>
#include <cctype>
#include <optional>
#include <sstream>
#include <string>
#include <vector>

#include "scraper.h"

namespace archoera::scraper::sanitize {

/// 广告/推广特征（小写包含匹配）。
inline const std::vector<std::string>& adMarkers() {
    static const std::vector<std::string> kMarkers = {
        "http://",
        "https://",
        "www.",
        "music.cnmsb.xin",
        "neko云音乐",
        "neko cloud music",
        "neko music",
        "资源来自",
        "获取更多无损音乐",
        "更多免费无损音乐",
        "关注公众号",
        "微信公众号",
        "扫码关注",
        "交流群",
        "qq群",
        "暂无歌词",
    };
    return kMarkers;
}

inline std::string toLowerAscii(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });
    return s;
}

inline bool isBlank(const std::string& s) {
    return s.find_first_not_of(" \t\r\n") == std::string::npos;
}

/// 文本是否为广告/推广内容（空文本不算）。
inline bool isAdText(const std::string& text) {
    if (isBlank(text)) return false;
    const std::string t = toLowerAscii(text);
    for (const auto& m : adMarkers()) {
        if (t.find(m) != std::string::npos) return true;
    }
    return false;
}

/// 单字段清洗：整体为广告 → 清空（删除该字段）。
inline void cleanField(std::optional<std::string>& field) {
    if (!field) return;
    if (isAdText(*field)) field.reset();
}

/// 歌词清洗：逐行删除广告行（保留其余行与时间戳）；全为广告/空 → 清空。
inline void cleanLyrics(std::optional<std::string>& lyrics) {
    if (!lyrics) return;
    std::istringstream ss(*lyrics);
    std::string line;
    std::string out;
    bool first = true;
    while (std::getline(ss, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (isBlank(line) || isAdText(line)) continue;
        if (!first) out.push_back('\n');
        out += line;
        first = false;
    }
    if (out.empty()) {
        lyrics.reset();
    } else {
        *lyrics = out;
    }
}

/// 对整个刮削结果执行广告清洗（字段 + 歌词）。
inline void sanitizeResult(ScrapeResult& r) {
    cleanField(r.title);
    cleanField(r.artist);
    cleanField(r.album);
    cleanField(r.albumArtist);
    cleanField(r.composer);
    cleanField(r.label);
    cleanLyrics(r.lyrics);
}

}  // namespace archoera::scraper::sanitize
