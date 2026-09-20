// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// ============================================================
// 内置元数据广告清洗（**强内置、全音源、全端一致**）
//
// 第三方/直传音源的标签里常夹带站点推广：歌词首行「资源来自 XX 云音乐」
// 「获取更多无损音乐 https://…」、COMMENT/LABEL/PUBLISHER 里的公众号/群号等。
// 这些既不是歌曲信息也不是歌词，属于元数据污染。
//
// 本模块提供统一判定与清洗，下载引擎在**写标签前**对全部来源执行：
//   - 字段值整体命中广告 → 删除该字段（`sanitize_field` → None）；
//   - 歌词逐行命中广告 → 删除该行（`sanitize_lyrics`）。
// 判定规则同时被 Dart 端（应用内展示）复刻，保证所有端行为一致。
// ============================================================

/// 广告/推广内容特征（小写包含匹配）。命中即视为广告。
///
/// 只收录**强推广信号**（站点域名、公众号/群号话术、占位词），避免误伤
/// 正规歌词/歌名：含 URL 的行几乎必为推广，故直接作为特征。
const AD_MARKERS: &[&str] = &[
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
];

/// 文本是否为广告/推广内容（空文本不算）。
pub fn is_ad_text(text: &str) -> bool {
    let t = text.trim().to_lowercase();
    if t.is_empty() {
        return false;
    }
    AD_MARKERS.iter().any(|m| t.contains(m))
}

/// 清洗单个标签字段：整体为广告 → None（删除该字段）；否则保留去除首尾空白。
pub fn sanitize_field(value: &str) -> Option<String> {
    let v = value.trim();
    if v.is_empty() || is_ad_text(v) {
        None
    } else {
        Some(v.to_string())
    }
}

/// 清洗歌词：逐行删除广告行（保留其余行顺序与时间戳）；全为广告/空 → None。
pub fn sanitize_lyrics(text: &str) -> Option<String> {
    let kept: Vec<&str> = text
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !is_ad_text(l))
        .collect();
    if kept.is_empty() {
        None
    } else {
        Some(kept.join("\n"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_promo_text() {
        assert!(is_ad_text("资源来自Neko云音乐 Resources from Neko Cloud Music"));
        assert!(is_ad_text("获取更多无损音乐https://music.cnmsb.xin/"));
        assert!(is_ad_text("更多免费无损音乐就来Neko云音乐"));
        assert!(is_ad_text("关注公众号：xxx"));
        assert!(!is_ad_text("[00:12.34]晴天"));
        assert!(!is_ad_text(""));
    }

    #[test]
    fn lyrics_keep_real_lines_drop_ads() {
        let raw = "[00:00.05]资源来自Neko云音乐 Resources from Neko Cloud Music\n\
                   [00:00.10]获取更多无损音乐https://music.cnmsb.xin/\n\
                   [00:12.34]故事的小黄花\n\
                   [00:15.00]从出生那年就飘着";
        let out = sanitize_lyrics(raw).unwrap();
        assert_eq!(out, "[00:12.34]故事的小黄花\n[00:15.00]从出生那年就飘着");
    }

    #[test]
    fn lyrics_all_ads_yields_none() {
        let raw = "资源来自Neko云音乐\n更多免费无损音乐https://music.cnmsb.xin";
        assert!(sanitize_lyrics(raw).is_none());
    }

    #[test]
    fn field_ad_removed_clean_kept() {
        assert!(sanitize_field("更多免费无损音乐就来Neko云音乐 https://music.cnmsb.xin").is_none());
        assert!(sanitize_field("Neko Music").is_none());
        assert!(sanitize_field("music.cnmsb.xin").is_none());
        assert_eq!(sanitize_field("  三拜红尘凉 ").as_deref(), Some("三拜红尘凉"));
        assert_eq!(sanitize_field("尹昔眠").as_deref(), Some("尹昔眠"));
    }
}
