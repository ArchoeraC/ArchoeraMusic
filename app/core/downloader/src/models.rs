// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// ============================================================
// §3.2 / §12 enqueue JSON 协议模型（Dart 纯数据传递 → Rust 唯一真相）
//
// Dart 侧构造的 request JSON：
//   {
//     "trackId":   "本地 Track 主键",
//     "source":    "kugou" | "netease",
//     "platformId":"平台歌曲 ID",
//     "quality":   "lq" | "sq" | "hq" | "lossless" | "hi-res",
//     "title":     "晴天",
//     "artist":    "周杰伦",
//     "album":     "叶惠美",            // v2 写标签用，可空
//     "extra": {
//       "hashes": {"128k":"..","320k":"..","flac":"..","flac24bit":".."},  // kugou
//       "sizes":  {"128k":4321000, ...}                                    // kugou（netease 空）
//     }
//   }
//
// 戒律 13.2：Dart 不传 pre-resolved URL；URL 解析/路径计算/去重全在 Rust。
// ============================================================

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

/// 音质档位（lq/sq/hq/lossless/hi-res）
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "kebab-case")]
pub enum Quality {
    Lq,
    Sq,
    #[default]
    Hq,
    Lossless,
    HiRes,
}

impl Quality {
    pub fn as_str(&self) -> &'static str {
        match self {
            Quality::Lq => "lq",
            Quality::Sq => "sq",
            Quality::Hq => "hq",
            Quality::Lossless => "lossless",
            Quality::HiRes => "hi-res",
        }
    }

    /// 猜测文件扩展名（v1：mp3 / flac）
    pub fn guess_ext(&self) -> &'static str {
        match self {
            Quality::Lq | Quality::Sq | Quality::Hq => "mp3",
            Quality::Lossless | Quality::HiRes => "flac",
        }
    }

    /// 品质 key 降级链（对齐 Dart kugou_api chains / netease track _levelChain）
    pub fn quality_chain(&self) -> &'static [&'static str] {
        match self {
            Quality::Lq => &["128k"],
            Quality::Sq | Quality::Hq => &["320k", "128k"],
            Quality::Lossless => &["flac", "320k", "128k"],
            Quality::HiRes => &["flac24bit", "flac", "320k", "128k"],
        }
    }
}

/// 平台来源
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum SourcePlatform {
    #[default]
    Kugou,
    Netease,
    Qqmusic,
    /// 实验性第三方音源 NekoMusic（直传，无音质档；Rust 无自研解析，
    /// 恒走 Dart 播放管线回退预解析 URL；元数据依赖 enqueue 传入 + 兜底源）。
    Neko,
    /// 流媒体（Subsonic/Jellyfin 等）：直链由 Dart 侧带鉴权生成
    /// （`/rest/stream?format=raw`，原文件）。Rust 无自研解析，
    /// 恒走 Dart 播放管线回退预解析 URL。
    Streaming,
}

impl SourcePlatform {
    pub fn as_str(&self) -> &'static str {
        match self {
            SourcePlatform::Kugou => "kugou",
            SourcePlatform::Netease => "netease",
            SourcePlatform::Qqmusic => "qqmusic",
            SourcePlatform::Neko => "neko",
            SourcePlatform::Streaming => "streaming",
        }
    }
}

/// extra 平台专用信息（kugou：hashes/sizes；netease：空）
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TrackExtra {
    #[serde(default)]
    pub hashes: HashMap<String, String>,
    #[serde(default)]
    pub sizes: HashMap<String, u64>,
}

/// enqueue 请求（§12 协议）
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct EnqueueRequest {
    pub track_id: String,
    pub source: SourcePlatform,
    pub platform_id: String,
    pub quality: Quality,
    pub title: String,
    pub artist: String,
    #[serde(default)]
    pub album: Option<String>,
    /// 强制重写歌词（标准 LRC 文本）。非空时在元数据合并中**优先于内嵌/平台
    /// 歌词**——Neko 等直传源在入队前由 Dart 取标准源歌词注入（其内嵌/平台
    /// 歌词常为站点广告或非标准格式，不可信）。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lyrics: Option<String>,
    #[serde(default)]
    pub extra: TrackExtra,

    // ---- §12.1 下载回退：Dart 播放管线预解析 URL（正常路径全为 None）----
    /// 正常路径为 None，URL 由 Rust 内部解析（戒律 13.2）。
    /// 仅当 Rust 解析失败后，Dart 复用播放管线解析出 URL，经
    /// `archoera_downloader_retry_with_url` 注入本字段（回退路径）。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pre_resolved_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pre_resolved_quality_key: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pre_resolved_ext: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pre_resolved_size: Option<u64>,
    /// 下载请求附加头（网易 CDN 需 Referer/Cookie/UA；酷狗通常为空）。
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub pre_resolved_headers: Vec<(String, String)>,
}

impl EnqueueRequest {
    /// 剥离回退路径注入的预解析 URL 及其 headers（可能含 Cookie）。
    ///
    /// 历史持久化 / 重启恢复用：避免把带凭据的临时 URL 落盘，也避免重启后
    /// 复用已失效的 URL（恢复时重新走 Rust 解析 / Dart 回退）。
    pub fn without_pre_resolved(mut self) -> Self {
        self.pre_resolved_url = None;
        self.pre_resolved_quality_key = None;
        self.pre_resolved_ext = None;
        self.pre_resolved_size = None;
        self.pre_resolved_headers.clear();
        self
    }
}

/// 下载回退：Dart 播放管线预解析出的 URL（§12.1）。
///
/// 由 `archoera_downloader_retry_with_url` 解析后写入任务 request 的
/// `pre_resolved_*` 字段。headers 为 `[["k","v"], ...]`。
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PreResolvedUrl {
    pub url: String,
    #[serde(default)]
    pub quality_key: Option<String>,
    #[serde(default)]
    pub file_ext: Option<String>,
    #[serde(default)]
    pub size: Option<u64>,
    #[serde(default)]
    pub headers: Vec<(String, String)>,
}

/// URL 解析结果（resolver 产出 → 下载阶段消费）
#[derive(Debug, Clone)]
pub struct ResolvedUrl {
    pub url: String,
    /// 实际拿到的品质 key（'128k'/'320k'/'flac'/'flac24bit'）
    pub quality_key: String,
    /// 文件扩展名（mp3 / flac）
    pub file_ext: String,
    /// 服务端/声明大小（None 则下载阶段取 content-length）
    pub file_size: Option<u64>,
    /// 下载请求需要带的 headers（Kugou 无；Netease 带 Cookie/Referer）
    pub extra_headers: Vec<(String, String)>,
}
