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

/// 音质档位（对齐 SPlayer-Next 档位命名 lq/sq/hq/lossless/hi-res）
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Quality {
    Lq,
    Sq,
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
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SourcePlatform {
    Kugou,
    Netease,
}

impl SourcePlatform {
    pub fn as_str(&self) -> &'static str {
        match self {
            SourcePlatform::Kugou => "kugou",
            SourcePlatform::Netease => "netease",
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
#[derive(Debug, Clone, Serialize, Deserialize)]
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
    #[serde(default)]
    pub extra: TrackExtra,
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
