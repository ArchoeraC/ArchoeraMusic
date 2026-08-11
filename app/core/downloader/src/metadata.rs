// ============================================================
// v2.1 增强：下载引擎自主寻找音乐元数据（标签 / 封面 / 歌词）
//
// 戒律 13.4（硬约束）：元数据一律引擎自取，**不依赖**外部 scraper 进程。
// 路径（全部 best-effort，任何一步失败都静默降级为缺省字段，不阻断下载）：
//   ① 内嵌标签提取：下载流自带 ID3v2 / Vorbis Comment（含封面）直接读；
//   ② 平台 API：Kugou → mobilecdn 搜索（按 hash 精确匹配，注入登录态
//      token/userid 尝试解锁 VIP 歌词）+ lyrics 两步走（fmt=lrc 直接解码，
//      fmt=krc 逐字歌词按非完全加密态解密：XOR + zlib inflate）；Netease →
//      weapi song/detail + song/lyric（复用现有加密与登录 cookie）；
//   ③ 兜底源（对齐 SPlayer-Next 刮削器多源思路）：平台/内嵌均缺标题或歌手
//      （西方歌曲平台常匹配失败）→ MusicBrainz recording 搜索取权威元数据；
//      平台歌词失败 → LRCLIB；平台封面缺失 → Cover Art Archive（按 MB
//      release MBID）。MusicBrainz / CAA 共享 1 req/s 限速，全局节流。
//   ④ 封面下载：文件无内嵌封面时，依次平台封面 URL / CAA（限 4MB）。
//
// 登录态传递（下载是登录功能，元数据同样带登录态尝试）：Kugou 走
// crate::kugou_session()（setKugouSession 注入的 token/userid），Netease 走
// crate::netease_cookie()（setNeteaseCookie 注入）。无登录态时退化为匿名请求。
// ============================================================

use std::io::Read;
use std::path::Path;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use futures::StreamExt;
use lofty::prelude::*;
use lofty::probe::Probe;
use lofty::tag::Accessor;

use crate::crypto::netease as nm;
use crate::models::{EnqueueRequest, SourcePlatform};

/// 最大封面字节数（防恶意大图拖慢任务完成）
const MAX_COVER_BYTES: u64 = 4 * 1024 * 1024;

/// 歌曲元数据（引擎自主寻找的结果；缺失字段为空串 / None）
#[derive(Debug, Clone, Default)]
pub struct TrackMetadata {
    pub title: String,
    pub artist: String,
    pub album: String,
    pub cover_url: Option<String>,
    pub lyrics: Option<String>,
}

impl TrackMetadata {
    /// 用 [other] 填充自身空字段（自身已有值优先）
    pub fn fill_from(&mut self, other: &TrackMetadata) {
        if self.title.is_empty() {
            self.title = other.title.clone();
        }
        if self.artist.is_empty() {
            self.artist = other.artist.clone();
        }
        if self.album.is_empty() {
            self.album = other.album.clone();
        }
        if self.cover_url.is_none() {
            self.cover_url = other.cover_url.clone();
        }
        if self.lyrics.is_none() {
            self.lyrics = other.lyrics.clone();
        }
    }
}

/// 内嵌标签提取结果：元数据 + 是否已带封面（有内嵌封面则跳过平台封面下载）
pub struct EmbeddedMeta {
    pub meta: TrackMetadata,
    pub has_cover: bool,
}

/// 引擎丰富后的最终标签内容（供 [crate::tag::write_tags] 消费）
pub struct EnrichedMetadata {
    pub title: String,
    pub artist: String,
    pub album: String,
    pub lyrics: Option<String>,
    /// (图片字节, mime)
    pub cover: Option<(Vec<u8>, String)>,
}

/// 下载完成后的元数据增强入口（lib.rs run_task 调用）。
///
/// 合并优先级：enqueue 传入 > 平台 API > 文件内嵌（封面/歌词 enqueue 没有，
/// 自然落到平台）。平台/内嵌都缺时走兜底源：MusicBrainz 元数据 + CAA 封面 +
/// LRCLIB 歌词。封面仅在内嵌缺失时下载（平台 URL → CAA）。
pub async fn enrich_file(
    client: &reqwest::Client,
    request: &EnqueueRequest,
    path: &Path,
) -> EnrichedMetadata {
    let embedded = extract_embedded(path);

    // 平台信息（标题/歌手/专辑/封面 URL）与歌词并行拉取
    let (platform, lyrics) = tokio::join!(
        fetch_platform_info(client, request),
        fetch_platform_lyrics(client, request),
    );

    let mut meta = TrackMetadata {
        title: request.title.clone(),
        artist: request.artist.clone(),
        album: request.album.clone().unwrap_or_default(),
        cover_url: None,
        lyrics: None,
    };
    meta.fill_from(&platform);
    meta.fill_from(&embedded.meta);
    if meta.lyrics.is_none() {
        meta.lyrics = lyrics;
    }

    // 兜底源（尤其西方歌曲，平台搜索常匹配失败）：title/artist 均缺 → MusicBrainz
    let mb_hit = if meta.title.is_empty() || meta.artist.is_empty() {
        fetch_musicbrainz(client, request).await
    } else {
        None
    };
    if let Some(hit) = &mb_hit {
        meta.fill_from(&TrackMetadata {
            title: hit.title.clone(),
            artist: hit.artist.clone(),
            album: hit.album.clone(),
            cover_url: None,
            lyrics: None,
        });
    }

    // 歌词：平台失败 → LRCLIB（用填充后的 title/artist 匹配）
    if meta.lyrics.is_none() {
        if let Some(l) = fetch_lrclib_lyrics(client, &meta).await {
            meta.lyrics = Some(l);
        }
    }

    let cover = if embedded.has_cover {
        None
    } else if let Some(url) = &meta.cover_url {
        download_cover(client, url).await
    } else if let Some(hit) = &mb_hit {
        match &hit.release_mbid {
            Some(rid) => fetch_caa_cover(client, rid).await,
            None => None,
        }
    } else {
        None
    };

    EnrichedMetadata {
        title: meta.title,
        artist: meta.artist,
        album: meta.album,
        lyrics: meta.lyrics,
        cover,
    }
}

/// ① 提取下载文件内嵌标签（ID3v2 / Vorbis Comment / MP4 ilst）。
/// 读取失败视为无元数据（不阻断）。
pub fn extract_embedded(path: &Path) -> EmbeddedMeta {
    let mut meta = TrackMetadata::default();
    let mut has_cover = false;
    if let Ok(tagged) = Probe::open(path).and_then(|p| p.read()) {
        if let Some(tag) = tagged.primary_tag() {
            meta.title = tag.title().unwrap_or_default().to_string();
            meta.artist = tag.artist().unwrap_or_default().to_string();
            meta.album = tag.album().unwrap_or_default().to_string();
            has_cover = !tag.pictures().is_empty();
        }
    }
    // 带 ID3v2 前缀的 FLAC（Netease 残留）：写标签时会字节级剥离前缀，内嵌
    // 封面若只存在于前缀内则会被丢掉。此时不信任内嵌封面，强制走平台封面
    // 下载补充，避免剥离后文件变成无封面。
    if has_cover && crate::tag::flac_has_id3v2_prefix(path) {
        has_cover = false;
    }
    EmbeddedMeta { meta, has_cover }
}

/// ② 平台信息拉取（分发）
pub async fn fetch_platform_info(
    client: &reqwest::Client,
    request: &EnqueueRequest,
) -> TrackMetadata {
    match request.source {
        SourcePlatform::Kugou => kugou_info(client, request).await,
        SourcePlatform::Netease => netease_info(client, request).await,
    }
}

/// ② 平台歌词拉取（分发）
pub async fn fetch_platform_lyrics(
    client: &reqwest::Client,
    request: &EnqueueRequest,
) -> Option<String> {
    match request.source {
        SourcePlatform::Kugou => kugou_lyrics(client, request).await,
        SourcePlatform::Netease => netease_lyrics(client, request).await,
    }
}

// ============================================================
// Kugou：mobilecdn 搜索（无鉴权）+ lyrics 两步走
// ============================================================

const KG_MOBILE_SEARCH: &str = "http://mobilecdn.kugou.com/api/v3/search/song";
const KG_LYRIC_SEARCH: &str = "http://lyrics.kugou.com/search";
const KG_LYRIC_DOWNLOAD: &str = "http://lyrics.kugou.com/download";

/// 歌词接口需要的伪装 headers（对齐 Dart kugou_request.dart kgLyricHeaders）
const KG_LYRIC_HEADERS: [(&str, &str); 3] = [
    ("KG-RC", "1"),
    ("KG-THash", "expand_search_manager.cpp:852736169:451"),
    ("User-Agent", "KuGou2012-9020-ExpandSearchManager"),
];

/// 登录态 query 片段（`&token=...&userid=...`）；酷狗搜索/歌词接口本无鉴权，
/// 但带 token/userid 可尝试解锁 VIP 歌词等受限内容。best-effort：
/// 未登录（空 / "0"）不注入，保持匿名请求。
fn kg_auth_query() -> String {
    let (userid, token) = crate::kugou_session();
    let mut q = String::new();
    if !token.is_empty() {
        q.push_str(&format!("&token={}", urlencode(&token)));
    }
    if !userid.is_empty() && userid != "0" {
        q.push_str(&format!("&userid={}", urlencode(&userid)));
    }
    q
}

async fn kugou_info(client: &reqwest::Client, request: &EnqueueRequest) -> TrackMetadata {
    let keyword = request.title.trim();
    if keyword.is_empty() {
        return TrackMetadata::default();
    }
    let uri = format!(
        "{KG_MOBILE_SEARCH}?keyword={}&page=1&pagesize=5&format=json&showtype=1{}",
        urlencode(keyword),
        kg_auth_query()
    );
    let body = get_json(client, &uri, &[]).await.unwrap_or_default();
    let Some(info) = body
        .get("data")
        .and_then(|d| d.get("info"))
        .and_then(|v| v.as_array())
    else {
        return TrackMetadata::default();
    };
    if info.is_empty() {
        return TrackMetadata::default();
    }

    // 优先精确匹配 hash（同名不同版本不抓错）；无匹配时取第一条
    let wanted: Vec<String> = request
        .extra
        .hashes
        .values()
        .map(|h| h.to_lowercase())
        .collect();
    let mut picked: Option<&serde_json::Value> = None;
    for item in info {
        let hit = ["hash", "320hash", "sqhash", "hires_hash", "reshash"]
            .iter()
            .any(|k| {
                item.get(*k)
                    .and_then(|v| v.as_str())
                    .map(|h| wanted.contains(&h.to_lowercase()))
                    .unwrap_or(false)
            });
        if hit {
            picked = Some(item);
            break;
        }
    }
    let item = picked.unwrap_or(&info[0]);

    TrackMetadata {
        title: decode_kg_name(
            item.get("songname")
                .and_then(|v| v.as_str())
                .unwrap_or_default(),
        ),
        artist: item
            .get("singername")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string(),
        album: decode_kg_name(
            item.get("album_name")
                .and_then(|v| v.as_str())
                .unwrap_or_default(),
        ),
        cover_url: item
            .get("trans_param")
            .and_then(|t| t.get("union_cover"))
            .and_then(|v| v.as_str())
            .map(|s| s.replace("{size}", "300"))
            .filter(|s| !s.is_empty()),
        lyrics: None,
    }
}

async fn kugou_lyrics(client: &reqwest::Client, request: &EnqueueRequest) -> Option<String> {
    let name = request.title.trim();
    let hash = request.extra.hashes.get("128k").map(String::as_str).unwrap_or_default();
    if name.is_empty() || hash.is_empty() {
        return None;
    }
    let search_uri = format!(
        "{KG_LYRIC_SEARCH}?ver=1&man=yes&client=pc&lrctxt=1&keyword={}&hash={}&timelength=0{}",
        urlencode(name),
        hash,
        kg_auth_query()
    );
    let body = get_json(client, &search_uri, &KG_LYRIC_HEADERS).await?;
    let cand = body
        .get("candidates")
        .and_then(|c| c.as_array())
        .and_then(|a| a.first())?;
    let id = cand.get("id")?.as_str()?;
    let accesskey = cand.get("accesskey")?.as_str()?;
    if id.is_empty() || accesskey.is_empty() {
        return None;
    }
    // fmt 选择：krc 为逐字歌词（非完全加密，可解：base64 去头 4 字节 →
    // 16 字节定 key 循环 XOR → zlib inflate）；lrc 为行级纯文本。
    let krctype = cand.get("krctype").and_then(|v| v.as_i64()).unwrap_or(0);
    let contenttype = cand.get("contenttype").and_then(|v| v.as_i64()).unwrap_or(0);
    let fmt = if krctype == 1 && contenttype != 1 {
        "krc"
    } else {
        "lrc"
    };
    let dl_uri = format!(
        "{KG_LYRIC_DOWNLOAD}?ver=1&client=pc&charset=utf8&id={id}&accesskey={accesskey}&fmt={fmt}{}",
        kg_auth_query()
    );
    let body = get_json(client, &dl_uri, &KG_LYRIC_HEADERS).await?;
    let content = body.get("content")?.as_str()?;
    if content.is_empty() {
        return None;
    }
    if fmt == "krc" {
        let text = decrypt_krc(content)?;
        let parsed = parse_krc(&text);
        // 主歌词 + 翻译交错合并（罗马音暂不写入标签）
        let merged = merge_lrc_translation(&parsed.lrc, &parsed.trans);
        return if merged.is_empty() { None } else { Some(merged) };
    }
    use base64::Engine;
    let bytes = base64::engine::general_purpose::STANDARD.decode(content).ok()?;
    Some(String::from_utf8_lossy(&bytes).into_owned())
}

// ============================================================
// KRC 歌词解密与解析（对齐 SPlayer-Next electron/main/apis/kugou/core/krc.ts
// 与 Dart apis/kugou/core/krc.dart，输出主 LRC / 翻译 / 罗马音三份）
//
// 加密：base64(content) 去头 4 字节 → 与 16 字节定 key 循环 XOR → zlib inflate
// → UTF-8 文本。文本格式示例：[285,3800]<0,120,0>字<120,200,0>字...
//   - 行首 [start_ms, duration_ms]（时长不用，只取 start_ms 转 LRC 时间标签）
//   - 行内 <offset_ms, duration_ms, 0> 每字时间（逐字歌词，LRC 不保留）
//   - [id:$...]/[ar:]/[ti:] 等 10 种元数据行整体移除
//   - [language:base64(json)] 嵌入翻译(type=1)与罗马音(type=0)纯文本行，
//     按主歌词行索引对齐补时间头
// ============================================================

const KRC_KEY: [u8; 16] = [
    0x40, 0x47, 0x61, 0x77, 0x5e, 0x32, 0x74, 0x47, 0x51, 0x36, 0x31, 0x2d, 0xce, 0xd2, 0x6e, 0x69,
];

/// KRC 解析结果（均带 `MM:SS.xxx` 时间戳，行级 LRC）
struct KrcLyrics {
    lrc: String,
    trans: String,
    /// 罗马音：当前不写入标签（主歌词+翻译已足够），保留解析输出供未来使用
    #[allow(dead_code)]
    roma: String,
}

/// 解密一段 KRC base64 内容 → UTF-8 原始文本
fn decrypt_krc(b64: &str) -> Option<String> {
    use base64::Engine;
    let mut buf = base64::engine::general_purpose::STANDARD.decode(b64).ok()?;
    if buf.len() <= 4 {
        return None;
    }
    // 跳过前 4 字节，余下与定 key 循环 XOR（对齐 krc.ts 逐字节 ^= KEY[i % 16]）
    for (i, b) in buf[4..].iter_mut().enumerate() {
        *b ^= KRC_KEY[i % 16];
    }
    let mut out = Vec::new();
    flate2::read::ZlibDecoder::new(&buf[4..])
        .read_to_end(&mut out)
        .ok()?;
    Some(String::from_utf8_lossy(&out).into_owned())
}

/// 毫秒 → `MM:SS.xxx` LRC 时间标签
fn ms_to_time_tag(ms: i64) -> String {
    let m = ms / 60000;
    let s = (ms % 60000) / 1000;
    let x = ms % 1000;
    format!("{m:02}:{s:02}.{x:03}")
}

/// 解析解密后的 KRC 文本 → 主 LRC + 翻译 + 罗马音（对齐 Dart _parseKrc）
fn parse_krc(raw: &str) -> KrcLyrics {
    // 主歌词行（start_ms, 文本）；翻译/罗马音为纯文本行（无时间戳）
    let mut main: Vec<(i64, String)> = Vec::new();
    let mut trans_lines: Vec<String> = Vec::new();
    let mut roma_lines: Vec<String> = Vec::new();

    for line in raw.replace('\r', "").lines() {
        let line = line.trim_end();
        if line.is_empty() || is_meta_line(line) {
            continue;
        }
        if let Some(b64) = parse_language_line(line) {
            if let Some((t, r)) = parse_language_b64(b64) {
                trans_lines = t;
                roma_lines = r;
            }
            continue;
        }
        if let Some((start_ms, body)) = parse_line_time(line) {
            main.push((start_ms, strip_word_tags(body)));
        }
        // 无时间标签的裸文本行：丢弃（krc 正文行均带时间标签）
    }

    let mut lrc = String::new();
    let mut trans = String::new();
    let mut roma = String::new();
    for (i, (start_ms, text)) in main.iter().enumerate() {
        let tag = ms_to_time_tag(*start_ms);
        lrc.push('[');
        lrc.push_str(&tag);
        lrc.push_str("]");
        lrc.push_str(text);
        lrc.push('\n');
        // 翻译/罗马音按主歌词行索引对齐补时间头（与 Dart _parseKrc 一致）
        if let Some(t) = trans_lines.get(i) {
            trans.push('[');
            trans.push_str(&tag);
            trans.push_str("]");
            trans.push_str(t);
            trans.push('\n');
        }
        if let Some(r) = roma_lines.get(i) {
            roma.push('[');
            roma.push_str(&tag);
            roma.push_str("]");
            roma.push_str(r);
            roma.push('\n');
        }
    }
    KrcLyrics { lrc, trans, roma }
}

/// KRC 元数据行前缀（[id:$...]/[ar:]/[ti:]/[al:]/[by:]/[hash:]/[sign:]/
/// [qq:]/[total:]/[offset:]）——非歌词正文，整体移除（对齐 Dart _metaLineReg）
fn is_meta_line(line: &str) -> bool {
    const PREFIXES: [&str; 10] = [
        "[id:$", "[ar:", "[ti:", "[al:", "[by:", "[hash:", "[sign:", "[qq:", "[total:", "[offset:",
    ];
    PREFIXES.iter().any(|p| line.starts_with(p))
}

/// 提取 `[language:base64]` 块 → base64 内容
fn parse_language_line(line: &str) -> Option<&str> {
    let rest = line.strip_prefix("[language:")?;
    let end = rest.find(']')?;
    Some(&rest[..end])
}

/// 解析 [language:] 的 base64(json) → (翻译行, 罗马音行)；失败返回 None
fn parse_language_b64(b64: &str) -> Option<(Vec<String>, Vec<String>)> {
    use base64::Engine;
    let json: serde_json::Value =
        serde_json::from_slice(&base64::engine::general_purpose::STANDARD.decode(b64).ok()?).ok()?;
    let content = json.get("content")?.as_array()?;
    let mut trans = Vec::new();
    let mut roma = Vec::new();
    for item in content {
        let typ = item.get("type").and_then(|v| v.as_i64()).unwrap_or(-1);
        let Some(lines) = item.get("lyricContent").and_then(|v| v.as_array()) else {
            continue;
        };
        let texts: Vec<String> = lines
            .iter()
            .filter_map(|arr| arr.as_array())
            .map(|arr| arr.iter().filter_map(|s| s.as_str()).collect::<String>())
            .collect();
        match typ {
            0 => roma = texts,
            1 => trans = texts,
            _ => {}
        }
    }
    Some((trans, roma))
}

/// 主歌词与翻译交错合并（逐行：主行后紧跟同时间戳翻译行）。
/// 翻译行数不足时仅合并前 N 行；翻译为空时原样返回主歌词。
fn merge_lrc_translation(main: &str, trans: &str) -> String {
    if trans.is_empty() {
        return main.to_string();
    }
    let m: Vec<&str> = main.lines().collect();
    let t: Vec<&str> = trans.lines().collect();
    let mut out = String::with_capacity(main.len() + trans.len() + 16);
    for (i, ml) in m.iter().enumerate() {
        out.push_str(ml);
        out.push('\n');
        if let Some(tl) = t.get(i) {
            out.push_str(tl);
            out.push('\n');
        }
    }
    out
}

/// 提取行首 `[start_ms,dur_ms]` 时间标签 → (start_ms, 标签后剩余文本)
fn parse_line_time(line: &str) -> Option<(i64, &str)> {
    if !line.starts_with('[') {
        return None;
    }
    let close = line.find(']')?;
    let tag = &line[1..close];
    let start = tag.split_once(',')?.0.trim();
    let start_ms = start.parse::<i64>().ok()?;
    Some((start_ms, &line[close + 1..]))
}

/// 剥离逐字时间标签 `<offset_ms,dur_ms,0>` / `<offset_ms,dur_ms>`（仅保留文字）
fn strip_word_tags(body: &str) -> String {
    let mut out = String::with_capacity(body.len());
    let mut depth = 0u32;
    for c in body.chars() {
        match c {
            '<' => depth += 1,
            '>' if depth > 0 => depth -= 1,
            c if depth == 0 => out.push(c),
            _ => {}
        }
    }
    out
}

// ============================================================
// Netease：weapi song/detail + song/lyric（复用现有加密与登录态）
// ============================================================

async fn netease_info(client: &reqwest::Client, request: &EnqueueRequest) -> TrackMetadata {
    let id = request.platform_id.trim();
    if id.is_empty() || !id.chars().all(|c| c.is_ascii_digit()) {
        return TrackMetadata::default();
    }
    let data = serde_json::json!({ "c": format!("[{{\"id\":{id}}}]") });
    let Some(body) = nm_weapi_post(client, "/weapi/v3/song/detail", data).await else {
        return TrackMetadata::default();
    };
    let Some(song) = body
        .get("songs")
        .and_then(|s| s.as_array())
        .and_then(|a| a.first())
    else {
        return TrackMetadata::default();
    };
    let artist = song
        .get("ar")
        .and_then(|v| v.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|a| a.get("name").and_then(|n| n.as_str()))
                .collect::<Vec<_>>()
                .join(" / ")
        })
        .unwrap_or_default();
    TrackMetadata {
        title: song
            .get("name")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string(),
        artist,
        album: song
            .get("al")
            .and_then(|al| al.get("name"))
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string(),
        cover_url: song
            .get("al")
            .and_then(|al| al.get("picUrl"))
            .and_then(|v| v.as_str())
            .map(str::to_string),
        lyrics: None,
    }
}

async fn netease_lyrics(client: &reqwest::Client, request: &EnqueueRequest) -> Option<String> {
    let id = request.platform_id.trim();
    if id.is_empty() || !id.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    let data = serde_json::json!({
        "id": id.parse::<i64>().unwrap_or(0),
        "tv": -1,
        "lv": -1,
        "rv": -1,
        "kv": -1,
        "_nmclfl": 1,
    });
    let body = nm_weapi_post(client, "/weapi/song/lyric", data).await?;
    let lrc = body
        .get("lrc")
        .and_then(|l| l.get("lyric"))
        .and_then(|v| v.as_str())
        .unwrap_or_default();
    if lrc.is_empty() {
        return None;
    }
    // 翻译（tlyric）合并：网易云翻译行与主歌词行序对应，交错写入
    let tlyric = body
        .get("tlyric")
        .and_then(|l| l.get("lyric"))
        .and_then(|v| v.as_str())
        .unwrap_or_default();
    Some(merge_lrc_translation(lrc, tlyric))
}

/// ③ 封面下载：GET 封面 URL（限 4MB），返回 (字节, mime)
pub async fn download_cover(
    client: &reqwest::Client,
    url: &str,
) -> Option<(Vec<u8>, String)> {
    let resp = client.get(url).timeout(Duration::from_secs(8)).send().await.ok()?;
    if !resp.status().is_success() {
        return None;
    }
    let mime = resp
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .map(|s| s.split(';').next().unwrap_or("").trim().to_string())
        .filter(|s| !s.is_empty());

    let mut bytes = Vec::new();
    let mut stream = resp.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let Ok(c) = chunk else { return None };
        if bytes.len() as u64 + c.len() as u64 > MAX_COVER_BYTES {
            return None;
        }
        bytes.extend_from_slice(&c);
    }
    if bytes.len() < 8 {
        return None;
    }
    let mime = mime.unwrap_or_else(|| guess_image_mime(&bytes));
    Some((bytes, mime))
}

// ============================================================
// 兜底源：MusicBrainz（权威元数据 + CAA 封面）/ LRCLIB（歌词）
// 对齐 SPlayer-Next 刮削器多源思路，用于平台 API 命中差的场景
// （尤其西方音乐）。MusicBrainz API 要求 UA 且限速 1 req/s
// （CAA 同域同限），两处共用全局节流。
// ============================================================

const MB_UA: &str = "ArchoeraMusicDownloader/1.0 (https://github.com/ArchoeraMusic)";
const MB_SEARCH: &str = "https://musicbrainz.org/ws/2/recording/";
const CAA_FRONT: &str = "https://coverartarchive.org/release/";
const LRCLIB_GET: &str = "https://lrclib.net/api/get";

/// MusicBrainz / CAA 请求间全局节流（≥1s），串行放行
static MB_LAST_REQ: OnceLock<Mutex<Instant>> = OnceLock::new();
fn mb_throttle() {
    let mut last = MB_LAST_REQ
        .get_or_init(|| Mutex::new(Instant::now() - Duration::from_secs(2)))
        .lock()
        .unwrap();
    let elapsed = last.elapsed();
    if elapsed < Duration::from_secs(1) {
        std::thread::sleep(Duration::from_secs(1) - elapsed);
    }
    *last = Instant::now();
}

/// MusicBrainz recording 搜索命中（title/artist/album + release MBID 供 CAA 用）
struct MusicBrainzHit {
    title: String,
    artist: String,
    album: String,
    release_mbid: Option<String>,
}

/// MusicBrainz recording 搜索（按 artist + title 精确查询）→ 权威元数据。
/// score < 70 视为不匹配（参考 SPlayer-Next 的相似度校验阈值）。
async fn fetch_musicbrainz(
    client: &reqwest::Client,
    request: &EnqueueRequest,
) -> Option<MusicBrainzHit> {
    if request.title.is_empty() || request.artist.is_empty() {
        return None;
    }
    mb_throttle();
    let query = format!(
        "recording:\"{}\" AND artist:\"{}\"",
        request.title, request.artist
    );
    let uri = format!(
        "{MB_SEARCH}?query={}&fmt=json&limit=1",
        urlencode(&query)
    );
    let json = get_json(client, &uri, &[("User-Agent", MB_UA)]).await?;
    let rec = json.get("recordings")?.as_array()?.first()?;
    let score = rec.get("score").and_then(|v| v.as_i64()).unwrap_or(0);
    if score < 70 {
        return None;
    }
    let title = rec
        .get("title")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let artist = rec
        .get("artist-credit")?
        .as_array()?
        .first()?
        .get("name")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let mut album = String::new();
    let mut release_mbid = None;
    if let Some(rel) = rec.get("releases").and_then(|r| r.as_array()).and_then(|a| a.first()) {
        release_mbid = rel
            .get("id")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string());
        album = rel
            .get("title")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
    }
    Some(MusicBrainzHit {
        title,
        artist,
        album,
        release_mbid,
    })
}

/// LRCLIB 歌词（无鉴权 REST）：优先同步 LRC，无同步时退化为纯文本。
/// artist/track/album 用填充后的最终 meta（更准）。
async fn fetch_lrclib_lyrics(
    client: &reqwest::Client,
    meta: &TrackMetadata,
) -> Option<String> {
    if meta.title.is_empty() || meta.artist.is_empty() {
        return None;
    }
    let mut uri = format!(
        "{LRCLIB_GET}?artist_name={}&track_name={}",
        urlencode(&meta.artist),
        urlencode(&meta.title)
    );
    if !meta.album.is_empty() {
        uri.push_str(&format!("&album_name={}", urlencode(&meta.album)));
    }
    let json = get_json(client, &uri, &[("User-Agent", MB_UA)]).await?;
    let synced = json
        .get("syncedLyrics")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    if !synced.is_empty() {
        return Some(synced.to_string());
    }
    let plain = json
        .get("plainLyrics")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    if plain.is_empty() {
        None
    } else {
        Some(plain.to_string())
    }
}

/// 按 MB release MBID 从 Cover Art Archive 取 500px 封面（302 → 图片流）
async fn fetch_caa_cover(
    client: &reqwest::Client,
    release_mbid: &str,
) -> Option<(Vec<u8>, String)> {
    mb_throttle();
    download_cover(client, &format!("{CAA_FRONT}{release_mbid}/front-500")).await
}

// ============================================================
// 内部工具
// ============================================================

/// 一次 GET + JSON 解析（可带 headers）；非 2xx / 解析失败返回 None
async fn get_json(
    client: &reqwest::Client,
    url: &str,
    headers: &[(&str, &str)],
) -> Option<serde_json::Value> {
    let mut req = client.get(url).timeout(Duration::from_secs(8));
    for (k, v) in headers {
        req = req.header(*k, *v);
    }
    let resp = req.send().await.ok()?;
    if !resp.status().is_success() {
        return None;
    }
    resp.json().await.ok()
}

/// 网易 weapi POST（对齐 resolvers.rs nm_download_url 的请求形态）
async fn nm_weapi_post(
    client: &reqwest::Client,
    path: &str,
    data: serde_json::Value,
) -> Option<serde_json::Value> {
    let cookie_header = crate::resolvers::build_netease_cookie(crate::netease_cookie().as_deref());
    let (params, enc_sec_key) = nm::weapi_encrypt(&data);
    let resp = client
        .post(format!("{}{path}", crate::resolvers::NM_DOMAIN))
        .header("Referer", crate::resolvers::NM_DOMAIN)
        .header("User-Agent", crate::resolvers::NM_WEAPI_UA)
        .header("Cookie", cookie_header)
        .form(&[("params", params.as_str()), ("encSecKey", enc_sec_key.as_str())])
        .timeout(Duration::from_secs(8))
        .send()
        .await
        .ok()?;
    if !resp.status().is_success() {
        return None;
    }
    resp.json().await.ok()
}

/// 简单 URL 编码（仅对非安全字符做 %XX，中文歌名等）
fn urlencode(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 8);
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// KG 搜索结果 HTML 实体反转义（对齐 Dart kgDecodeName）
fn decode_kg_name(s: &str) -> String {
    if s.is_empty() {
        return String::new();
    }
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    loop {
        match rest.find('&') {
            None => {
                out.push_str(rest);
                break;
            }
            Some(amp) => {
                out.push_str(&rest[..amp]);
                let after = &rest[amp..];
                match after.find(';') {
                    None => {
                        out.push_str(after);
                        break;
                    }
                    Some(semi) => {
                        let entity = &after[..semi + 1];
                        let decoded = match entity {
                            "&nbsp;" => " ",
                            "&amp;" => "&",
                            "&lt;" => "<",
                            "&gt;" => ">",
                            "&quot;" => "\"",
                            "&apos;" => "'",
                            "&#039;" => "'",
                            _ => entity,
                        };
                        out.push_str(decoded);
                        rest = &after[semi + 1..];
                    }
                }
            }
        }
    }
    out
}

/// 魔数猜测图片 mime（响应头缺失时兜底）
fn guess_image_mime(bytes: &[u8]) -> String {
    if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
        "image/jpeg".to_string()
    } else if bytes.starts_with(&[0x89, 0x50, 0x4E, 0x47]) {
        "image/png".to_string()
    } else if bytes.starts_with(b"GIF8") {
        "image/gif".to_string()
    } else if bytes.starts_with(b"BM") {
        "image/bmp".to_string()
    } else {
        "image/jpeg".to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::Engine;
    use flate2::write::ZlibEncoder;
    use flate2::Compression;
    use std::io::Write;

    /// 反向构造 KRC 密文（明文 → zlib → 前置 4 字节明文头 → 仅头后内容 XOR → base64），
    /// 验证 decrypt_krc 与酷狗加密流程互逆。
    fn build_krc_base64(plain: &str) -> String {
        let mut enc = ZlibEncoder::new(Vec::new(), Compression::default());
        enc.write_all(plain.as_bytes()).unwrap();
        let z = enc.finish().unwrap();
        let mut payload = vec![0u8; 4];
        payload.extend_from_slice(&z);
        // 头 4 字节不参与 XOR（对齐 decrypt_krc 的 buf[4..]）
        for (i, b) in payload[4..].iter_mut().enumerate() {
            *b ^= KRC_KEY[i % 16];
        }
        base64::engine::general_purpose::STANDARD.encode(payload)
    }

    #[test]
    fn krc_decrypt_roundtrip() {
        let plain = "[id:$00000000]\n[language:eyJjb250ZW50IjpbXX0=]\n[1000,500]<0,120,0>你<120,200,0>好\n[2000,300]<0,100,0>世<100,200,0>界\n";
        let b64 = build_krc_base64(plain);
        assert_eq!(decrypt_krc(&b64).as_deref(), Some(plain));
    }

    #[test]
    fn krc_to_lrc_parses_lines_and_strips_word_tags() {
        let raw = "[id:$00000000]\n\
                   [ar:测试歌手]\n\
                   [ti:测试歌曲]\n\
                   [total:3]\n\
                   [language:eyJjb250ZW50IjpbXX0=]\n\
                   [1000,500]<0,120,0>你<120,200,0>好\n\
                   [2000,300]<0,100,0>世<100,200,0>界\n";
        let parsed = parse_krc(raw);
        assert_eq!(parsed.lrc, "[00:01.000]你好\n[00:02.000]世界\n");
        assert_eq!(parsed.trans, "");
        assert_eq!(parsed.roma, "");
    }

    #[test]
    fn parse_krc_extracts_trans_and_roma() {
        // [language:] base64(json)：type=1 翻译（Hello/World），type=0 罗马音（ni hao/shi jie）
        let raw = "[id:$00000000]\n\
                   [language:eyJjb250ZW50IjpbeyJ0eXBlIjoxLCJseXJpY0NvbnRlbnQiOltbIkhlbGxvIl0sWyJXb3JsZCJdXX0seyJ0eXBlIjowLCJseXJpY0NvbnRlbnQiOltbIm5pIGhhbyJdLFsic2hpIGppZSJdXX1dfQ==]\n\
                   [1000,500]<0,120,0>你<120,200,0>好\n\
                   [2000,300]<0,100,0>世<100,200,0>界\n";
        let parsed = parse_krc(raw);
        assert_eq!(parsed.lrc, "[00:01.000]你好\n[00:02.000]世界\n");
        assert_eq!(parsed.trans, "[00:01.000]Hello\n[00:02.000]World\n");
        assert_eq!(parsed.roma, "[00:01.000]ni hao\n[00:02.000]shi jie\n");
    }

    #[test]
    fn merge_lrc_translation_interleaves_lines() {
        let main = "[00:01.000]你好\n[00:02.000]世界\n";
        let trans = "[00:01.000]Hello\n[00:02.000]World\n";
        assert_eq!(
            merge_lrc_translation(main, trans),
            "[00:01.000]你好\n[00:01.000]Hello\n[00:02.000]世界\n[00:02.000]World\n"
        );
        // 无翻译时原样返回主歌词
        assert_eq!(merge_lrc_translation(main, ""), main);
        // 翻译行不足时仅合并前 N 行
        assert_eq!(
            merge_lrc_translation(main, "[00:01.000]Hello\n"),
            "[00:01.000]你好\n[00:01.000]Hello\n[00:02.000]世界\n"
        );
    }

    #[test]
    fn ms_to_time_tag_formats() {
        assert_eq!(ms_to_time_tag(0), "00:00.000");
        assert_eq!(ms_to_time_tag(61_500), "01:01.500");
    }

    #[test]
    fn strip_word_tags_keeps_bare_text() {
        assert_eq!(strip_word_tags("纯文本"), "纯文本");
        assert_eq!(strip_word_tags(""), "");
    }

    #[test]
    fn mb_throttle_enforces_one_second_gap() {
        // 首次调用立即通过；第二次与首次间隔须 ≥1s（MB 限速）
        mb_throttle();
        let t0 = Instant::now();
        mb_throttle();
        assert!(t0.elapsed() >= Duration::from_millis(950));
    }
}
