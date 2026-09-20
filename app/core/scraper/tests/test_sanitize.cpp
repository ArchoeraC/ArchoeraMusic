// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// 刮削器内置广告清洗单测：字段整体命中广告 → 删除；歌词逐行删除广告行。

#include "sanitize.h"

#include <cassert>
#include <iostream>
#include <string>

using archoera::scraper::ScrapeResult;
using namespace archoera::scraper::sanitize;

int main() {
    // 1) 判定：命中站点推广，放过正规歌词。
    assert(isAdText("资源来自Neko云音乐 Resources from Neko Cloud Music"));
    assert(isAdText("获取更多无损音乐https://music.cnmsb.xin/"));
    assert(isAdText("更多免费无损音乐就来Neko云音乐"));
    assert(isAdText("关注公众号：xxx"));
    assert(!isAdText("[00:12.34]晴天"));
    assert(!isAdText("故事的小黄花"));
    assert(!isAdText(""));

    // 2) 字段清洗：广告字段删除，正规字段保留。
    ScrapeResult r;
    r.title = "三拜红尘凉";
    r.artist = "尹昔眠";
    r.album = "更多免费无损音乐就来Neko云音乐 https://music.cnmsb.xin";
    r.label = "Neko Music";
    r.lyrics = std::string(
        "[00:00.05]资源来自Neko云音乐 Resources from Neko Cloud Music\n"
        "[00:00.10]获取更多无损音乐https://music.cnmsb.xin/\n"
        "[00:12.34]故事的小黄花\n"
        "[00:15.00]从出生那年就飘着");
    sanitizeResult(r);

    assert(r.title.has_value() && *r.title == "三拜红尘凉");
    assert(r.artist.has_value() && *r.artist == "尹昔眠");
    assert(!r.album.has_value());   // 整体广告 → 删除
    assert(!r.label.has_value());   // Neko Music → 删除
    assert(r.lyrics.has_value());
    assert(*r.lyrics == "[00:12.34]故事的小黄花\n[00:15.00]从出生那年就飘着");

    // 3) 全为广告的歌词 → 删除。
    ScrapeResult onlyAds;
    onlyAds.lyrics = std::string("资源来自Neko云音乐\n更多免费无损音乐https://music.cnmsb.xin");
    sanitizeResult(onlyAds);
    assert(!onlyAds.lyrics.has_value());

    std::cout << "sanitize 广告清洗：全部通过\n";
    return 0;
}
