// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// ============================================================
// §9.6 第 3 层防御：SourceResolver trait 抽象 + 注册表
//
// 戒律 13.2：Dart 绝不参与 URL 解析签名，全在 Rust 内部。
// 自研优先（§9.6 第 1 层）：Kugou/Netease 签名算法为 crate::crypto
// 全新实现，对照 Dart kugou_crypto.dart / netease crypto.dart 1:1 移植。
//
// v2 相对设计稿变更（2026-08-09）：因编译环境不得访问 GitHub，第三方 SDK
// 备胎（kugou_sdk / ncm-api-rs）已整体移除，仅保留自研实现 + trait 抽象
// （未来如需要 SDK 备胎，按同一 trait 新增 impl 即可，业务代码零改动）。
//
// 可插拔（2026-09）：音源 → 解析器经 [resolver_for] 注册表分发，
// 中央 match 仅按「有无自研解析」二分；新增自研音源只需新增 impl +
// 注册表加一条，业务代码（lib.rs）零改动。
// ============================================================

use std::collections::BTreeMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{anyhow, bail, Result};
use md5::{Digest, Md5};
use reqwest::header::{self, HeaderMap, HeaderValue};

use crate::crypto::kugou as kg;
use crate::crypto::netease as nm;
use crate::models::*;

// ============================================================
// trait 定义（第 3 层隔离）
// ============================================================

/// 音源 URL 解析器：把 enqueue 请求解析为可下载 URL。
///
/// 只有**具备 Rust 自研解析**的音源才实现本 trait；直传/预解析音源
/// （QQ、Streaming、未来未知音源）不在注册表中，调用方据此走
/// Dart 播放管线预解析 URL 回退（§12.1），行为与历史一致。
pub trait SourceResolver: Send + Sync {
    /// 解析可下载 URL；[cancel] 为任务取消标志（解析阶段也响应取消）。
    fn resolve_play_url<'a>(
        &'a self,
        request: &'a EnqueueRequest,
        cancel: &'a Arc<AtomicBool>,
    ) -> Pin<Box<dyn Future<Output = Result<ResolvedUrl>> + Send + 'a>>;
}

/// 兼容别名：§9.6 设计文档与既有探测示例沿用 `PlatformUrlResolver` 名称。
pub use self::SourceResolver as PlatformUrlResolver;

// ============================================================
// 注册表：音源 → 解析器
// ============================================================

/// Kugou 解析器进程级单例（trait object 引用需 `'static`）。
static KUGOU_RESOLVER: KugouResolver = KugouResolver;
/// Netease 解析器进程级单例。
static NETEASE_RESOLVER: NeteaseResolver = NeteaseResolver;
/// Bilibili 解析器进程级单例。
static BILIBILI_RESOLVER: BilibiliResolver = BilibiliResolver;

/// 按音源取自研 URL 解析器（`None` = 无 Rust 解析，走 Dart 预解析直链）。
///
/// 这是本模块唯一的音源分发点：新增自研音源只需 ① `impl SourceResolver`；
/// ② 在 [resolver_for_platform] 加一条匹配。业务侧无需改动中央 match。
///
/// - Kugou / Netease → `Some(..)`
/// - Qqmusic / Streaming 及未来未知音源 → `None`（行为不变）
pub fn resolver_for(source: &str) -> Option<&'static dyn SourceResolver> {
    resolver_for_platform(SourcePlatform::from_wire(source))
}

/// [resolver_for] 的强类型入口（已持有 [SourcePlatform] 时避免重复解析字符串）。
pub fn resolver_for_platform(source: SourcePlatform) -> Option<&'static dyn SourceResolver> {
    match source {
        SourcePlatform::Kugou => Some(&KUGOU_RESOLVER),
        SourcePlatform::Netease => Some(&NETEASE_RESOLVER),
        SourcePlatform::Bilibili => Some(&BILIBILI_RESOLVER),
        // QQ / Streaming / 未知：Rust 无自研解析 → Dart 预解析直链。
        SourcePlatform::Qqmusic | SourcePlatform::Streaming | SourcePlatform::Unknown => None,
    }
}

// ============================================================
// 默认实现 A1：Kugou 自研签名（register_dev + v5/url）
// ============================================================

#[derive(Default, Clone, Debug)]
pub struct KugouResolver;

const KG_SONG_URL: &str = "https://gateway.kugou.com/v5/url";
const KG_REGISTER_URL: &str = "https://userservice.kugou.com/risk/v2/r_register_dev";
const KG_ANDROID_UA: &str = "Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi";

/// v5/url 基础参数（对齐 Dart kugou_request.dart kgSongUrlBase）
fn kg_song_url_base() -> BTreeMap<String, String> {
    [
        ("album_id", "0"),
        ("area_code", "1"),
        ("ssa_flag", "is_fromtrack"),
        ("version", "11430"),
        ("page_id", "967177915"),
        ("album_audio_id", "0"),
        ("behavior", "play"),
        ("pid", "411"),
        ("cmd", "26"),
        ("pidversion", "3001"),
        ("IsFreePart", "0"),
        ("ppage_id", "356753938,823673182,967485191"),
        ("cdnBackup", "1"),
        ("module", ""),
        ("clientver", "11440"),
    ]
    .into_iter()
    .map(|(k, v)| (k.to_string(), v.to_string()))
    .collect()
}

/// register_dev 设备信息（对齐 Dart kugou_request.dart _kgDevice）
fn kg_device_json(guid: &str) -> serde_json::Value {
    let mut m = serde_json::Map::new();
    m.insert("availableRamSize".into(), 4983533568u64.into());
    m.insert("availableRomSize".into(), 48114719u64.into());
    m.insert("availableSDSize".into(), 48114717u64.into());
    m.insert("basebandVer".into(), "".into());
    m.insert("batteryLevel".into(), 100u64.into());
    m.insert("batteryStatus".into(), 3u64.into());
    m.insert("brand".into(), "Redmi".into());
    m.insert("buildSerial".into(), "unknown".into());
    m.insert("device".into(), "marble".into());
    m.insert("imei".into(), guid.into());
    m.insert("imsi".into(), "".into());
    m.insert("manufacturer".into(), "Xiaomi".into());
    m.insert("uuid".into(), guid.into());
    m.insert("accelerometer".into(), false.into());
    m.insert("accelerometerValue".into(), "".into());
    m.insert("gravity".into(), false.into());
    m.insert("gravityValue".into(), "".into());
    m.insert("gyroscope".into(), false.into());
    m.insert("gyroscopeValue".into(), "".into());
    m.insert("light".into(), false.into());
    m.insert("lightValue".into(), "".into());
    m.insert("magnetic".into(), false.into());
    m.insert("magneticValue".into(), "".into());
    m.insert("orientation".into(), false.into());
    m.insert("orientationValue".into(), "".into());
    m.insert("pressure".into(), false.into());
    m.insert("pressureValue".into(), "".into());
    m.insert("step_counter".into(), false.into());
    m.insert("step_counterValue".into(), "".into());
    m.insert("temperature".into(), false.into());
    m.insert("temperatureValue".into(), "".into());
    serde_json::Value::Object(m)
}

/// 按「签名原文」拼接 query：key=value，值不做 URL 编码
fn kg_query_string(params: &BTreeMap<String, String>) -> String {
    params
        .iter()
        .map(|(k, v)| format!("{k}={v}"))
        .collect::<Vec<_>>()
        .join("&")
}

fn now_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// kg-* 基础请求头（对齐 Dart kugou_request.dart _kgBaseHeaders）
fn kg_base_headers(mid: &str, ts: i64, x_router: Option<&str>) -> reqwest::header::HeaderMap {
    use reqwest::header::HeaderValue;
    let mut h = reqwest::header::HeaderMap::new();
    let mut set = |k: &str, v: String| {
        let Ok(name) = reqwest::header::HeaderName::from_bytes(k.as_bytes()) else {
            return;
        };
        if let Ok(val) = HeaderValue::from_str(&v) {
            h.insert(name, val);
        }
    };
    set("User-Agent", KG_ANDROID_UA.to_string());
    set("dfid", "-".to_string());
    set("clienttime", ts.to_string());
    set("mid", mid.to_string());
    set("kg-rc", "1".to_string());
    set("kg-thash", "5d816a0".to_string());
    set("kg-rec", "1".to_string());
    set("kg-rf", "B9EDA08A64250DEFFBCADDEE00F8F25F".to_string());
    if let Some(xr) = x_router {
        set("x-router", xr.to_string());
    }
    h
}

/// 注册设备 → 返回真实 dfid（v5/url 前置条件）
///
/// 对齐 Dart kugou_request.dart kgRegisterDevice：
/// AES-CBC 加密设备 JSON（密钥 6 位随机串）+ RSA-PKCS1 加密 {aes,uid,token}
/// （概念版 lite 公钥）+ android lite 签名，POST userservice.kugou.com
/// /risk/v2/r_register_dev，响应体为 AES 密文需解密取 data.dfid。
async fn kg_register_device(client: &reqwest::Client, mid: &str) -> Result<String> {
    let ts = now_secs();
    let guid = kg::kg_md5(&kg::kg_random_string(24));
    let device = kg_device_json(&guid);
    let secret_key = kg::kg_random_string(6).to_lowercase();
    let cipher = kg::kg_aes_encrypt_base64(&device.to_string(), &secret_key);
    let p = kg::kg_rsa_pkcs1_encrypt_hex(
        &format!(r#"{{"aes":"{secret_key}","uid":0,"token":""}}"#),
        kg::KG_LITE_PUBLIC_KEY_PEM,
    );

    let mut params = BTreeMap::new();
    params.insert("part".into(), "1".into());
    params.insert("platid".into(), "1".into());
    params.insert("p".into(), p);
    params.insert("dfid".into(), "-".into());
    params.insert("mid".into(), mid.to_string());
    params.insert("uuid".into(), "-".into());
    params.insert("appid".into(), kg::KG_LITE_APPID.to_string());
    params.insert("clientver".into(), kg::KG_LITE_CLIENTVER.to_string());
    params.insert("clienttime".into(), ts.to_string());
    let signature = kg::kg_signature(&params, &cipher, kg::KG_LITE_SIGN_SALT);
    params.insert("signature".into(), signature);

    let url = format!("{KG_REGISTER_URL}?{}", kg_query_string(&params));
    let mut headers = kg_base_headers(mid, ts, None);
    headers.insert(
        "Content-Type",
        reqwest::header::HeaderValue::from_static("text/plain;charset=utf-8"),
    );

    crate::request_pacing().await;
    let resp = match client.post(&url).headers(headers).body(cipher).send().await {
        Ok(r) => r,
        Err(e) => {
            crate::failure_backoff().await;
            return Err(anyhow!("register_dev HTTP 失败: {e}"));
        }
    };
    let bytes = match resp.bytes().await {
        Ok(b) => b,
        Err(e) => {
            crate::failure_backoff().await;
            return Err(anyhow!("register_dev 读响应失败: {e}"));
        }
    };

    use base64::Engine;
    let b64 = base64::engine::general_purpose::STANDARD.encode(&bytes);
    let text = kg::kg_aes_decrypt_string(&b64, &secret_key)
        .map_err(|e| anyhow!("register_dev 响应解密失败: {e}"))?;
    let body: serde_json::Value = serde_json::from_str(&text)
        .map_err(|e| anyhow!("register_dev 响应非 JSON: {e}"))?;

    let dfid = body
        .get("data")
        .and_then(|d| d.get("dfid"))
        .and_then(|v| v.as_str())
        .map(str::to_string);
    match dfid {
        Some(d) if !d.is_empty() => {
            crate::reset_failures();
            Ok(d)
        }
        _ => bail!("register_dev 未返回 dfid: {text}"),
    }
}

/// v5/url 单档请求。status=2（需验证）时返回 [KgUrlError::NeedsDfidRefresh]。
struct KgUrlError {
    needs_dfid_refresh: bool,
    /// true = 服务端返回付费墙（pay_block_tpl）：该档位需 VIP 权限，
    /// 换 dfid 无用，应立即降级下一档，不做无谓的 register_dev 重试。
    is_paywall: bool,
    msg: String,
}

impl std::fmt::Display for KgUrlError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.msg)
    }
}

async fn kg_song_url(
    client: &reqwest::Client,
    mid: &str,
    dfid: &str,
    hash: &str,
    quality_param: &str,
    userid: &str,
    token: &str,
) -> std::result::Result<ResolvedUrl, KgUrlError> {
    let ts = now_secs();
    let hash_lc = hash.to_lowercase();

    let mut params = kg_song_url_base();
    params.insert("dfid".into(), dfid.to_string());
    params.insert("mid".into(), mid.to_string());
    params.insert("uuid".into(), "-".into());
    params.insert("appid".into(), kg::KG_LITE_APPID.to_string());
    params.insert("clienttime".into(), ts.to_string());
    params.insert("hash".into(), hash_lc.clone());
    params.insert("quality".into(), quality_param.to_string());
    if !token.is_empty() {
        params.insert("token".into(), token.to_string());
    }
    if !userid.is_empty() && userid != "0" {
        params.insert("userid".into(), userid.to_string());
    }
    let key = kg::kg_sign_key(
        &hash_lc,
        mid,
        userid.parse::<i64>().unwrap_or(0),
        kg::KG_LITE_APPID,
        kg::KG_LITE_KEY_SALT,
    );
    params.insert("key".into(), key);
    let signature = kg::kg_signature(&params, "", kg::KG_LITE_SIGN_SALT);
    params.insert("signature".into(), signature);
    log::debug!(
        "Kugou v5/url 请求: hash={hash_lc} quality={quality_param} dfid={dfid} 登录态={}",
        if token.is_empty() && userid.is_empty() {
            "未注入"
        } else {
            "已注入"
        }
    );

    let url = format!("{KG_SONG_URL}?{}", kg_query_string(&params));
    let mut headers = kg_base_headers(mid, ts, Some("trackercdn.kugou.com"));
    headers.insert(
        "dfid",
        reqwest::header::HeaderValue::from_str(dfid)
            .unwrap_or_else(|_| reqwest::header::HeaderValue::from_static("-")),
    );

    crate::request_pacing().await;
    let resp = match client.get(&url).headers(headers).send().await {
        Ok(r) => r,
        Err(e) => {
            crate::failure_backoff().await;
            return Err(KgUrlError {
                needs_dfid_refresh: false,
                is_paywall: false,
                msg: format!("v5/url HTTP 失败: {e}"),
            });
        }
    };
    let status = resp.status();
    let text = match resp.text().await {
        Ok(t) => t,
        Err(e) => {
            crate::failure_backoff().await;
            return Err(KgUrlError {
                needs_dfid_refresh: false,
                is_paywall: false,
                msg: format!("v5/url 读响应失败: {e}"),
            });
        }
    };
    let body: serde_json::Value = match serde_json::from_str(&text) {
        Ok(v) => v,
        Err(e) => {
            crate::failure_backoff().await;
            return Err(KgUrlError {
                needs_dfid_refresh: false,
                is_paywall: false,
                msg: format!("v5/url 响应非 JSON (HTTP {status}): {e}"),
            });
        }
    };

    let code = body.get("status").and_then(|v| v.as_i64()).unwrap_or(0);
    match code {
        1 => {
            let first = body
                .get("url")
                .and_then(|v| v.as_array())
                .and_then(|a| a.first())
                .and_then(|v| v.as_str())
                .map(str::to_string)
                .unwrap_or_default();
            if first.is_empty() {
                return Err(KgUrlError { needs_dfid_refresh: false, is_paywall: false, msg: "v5/url status=1 但无 url".into() });
            }
            log::debug!(
                "Kugou v5/url status=1 命中: quality={quality_param} url={}...",
                first.chars().take(90).collect::<String>()
            );
            crate::reset_failures();
            Ok(ResolvedUrl {
                url: first,
                quality_key: quality_param_to_key(quality_param),
                file_ext: if quality_param == "flac" || quality_param == "high" { "flac" } else { "mp3" }.to_string(),
                file_size: None,
                extra_headers: vec![],
            })
        }
        2 => {
            // status=2 语义需区分（实测 2026-08：酷狗对无权限档位返回
            // trans_param.pay_block_tpl=1 付费墙模板，换 dfid 无法解锁）：
            // 付费墙 → 立即降级下一档；否则保持旧行为（SSA「需要验证」→
            // 换新 dfid 重试一次）。
            let is_paywall = body
                .get("trans_param")
                .and_then(|t| t.get("pay_block_tpl"))
                .and_then(|v| v.as_i64())
                .map(|v| v != 0)
                .unwrap_or(false);
            log::debug!(
                "Kugou v5/url status=2: quality={quality_param} 原因={}",
                if is_paywall { "付费墙→降级" } else { "需刷新 dfid" }
            );
            Err(KgUrlError {
                needs_dfid_refresh: !is_paywall,
                is_paywall,
                msg: if is_paywall {
                    "v5/url status=2 该档位需 VIP（付费墙），降级".into()
                } else {
                    "v5/url status=2 需要刷新 dfid".into()
                },
            })
        }
        3 => Err(KgUrlError { needs_dfid_refresh: false, is_paywall: false, msg: format!("v5/url status=3 VIP 限制: {}", text) }),
        other => Err(KgUrlError { needs_dfid_refresh: false, is_paywall: false, msg: format!("v5/url status={other}: {text}") }),
    }
}

/// quality 参数 → 品质 key（供 done 事件的 actualQuality 使用）
fn quality_param_to_key(qp: &str) -> String {
    match qp {
        "128" => "128k".to_string(),
        "320" => "320k".to_string(),
        "flac" => "flac".to_string(),
        "high" => "flac24bit".to_string(),
        _ => qp.to_string(),
    }
}

impl SourceResolver for KugouResolver {
    fn resolve_play_url<'a>(
        &'a self,
        request: &'a EnqueueRequest,
        cancel: &'a Arc<AtomicBool>,
    ) -> Pin<Box<dyn Future<Output = Result<ResolvedUrl>> + Send + 'a>> {
        Box::pin(async move {
            let client = crate::http_client();
            let mid = crate::kugou_mid();
            let (userid, token) = crate::kugou_session();

            for qk in request.quality.quality_chain() {
                if cancel.load(Ordering::Relaxed) {
                    bail!("已取消");
                }
                let Some(hash) = request.extra.hashes.get(*qk) else {
                    continue;
                };
                if hash.is_empty() {
                    continue;
                }
                let Some(qp) = kugou_quality_param(qk) else {
                    continue;
                };
                // status=2 → 清 dfid 重新 register 一次
                let mut tried_refresh = false;
                loop {
                    if cancel.load(Ordering::Relaxed) {
                        bail!("已取消");
                    }
                    let dfid = match crate::kugou_dfid() {
                        Some(d) => d,
                        None => match kg_register_device(&client, &mid).await {
                            Ok(d) => {
                                crate::set_kugou_dfid(Some(d.clone()));
                                d
                            }
                            Err(e) => {
                                // register 失败（风控频率限制等）→ 放弃本档位，走降级链
                                log::debug!("Kugou register_dev 失败: {e}");
                                break;
                            }
                        },
                    };
                    log::debug!("Kugou 尝试档位 {qk}: hash={hash}");
                    match kg_song_url(&client, &mid, &dfid, hash, qp, &userid, &token).await {
                        Ok(resolved) => return Ok(resolved),
                        Err(e) if e.needs_dfid_refresh && !tried_refresh => {
                            tried_refresh = true;
                            crate::set_kugou_dfid(None);
                            continue;
                        }
                        Err(e) => {
                            // 该档位失败 → 继续降级链
                            if e.is_paywall {
                                log::debug!("Kugou {qk} 档需 VIP（付费墙），降级");
                            } else {
                                log::debug!("Kugou {} 档失败: {}", qk, e.msg);
                            }
                            break;
                        }
                    }
                }
            }
            bail!("Kugou 所有音质档位均无法获取 URL")
        })
    }
}

/// 品质 key → v5/url quality 参数（对齐 KugouTrackInfo.qualityParam）
fn kugou_quality_param(key: &str) -> Option<&'static str> {
    match key {
        "128k" => Some("128"),
        "320k" => Some("320"),
        "flac" => Some("flac"),
        "flac24bit" => Some("high"),
        _ => None,
    }
}

// ============================================================
// 默认实现 A2：Netease 自研 weapi（song_download_url v1）
// ============================================================

#[derive(Default, Clone, Debug)]
pub struct NeteaseResolver;

const NM_WEAPI_URL: &str = "https://music.163.com/weapi/song/enhance/download/url/v1";
const NM_PLAYER_URL: &str = "https://music.163.com/weapi/song/enhance/player/url/v1";
pub(crate) const NM_DOMAIN: &str = "https://music.163.com";
pub(crate) const NM_WEAPI_UA: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36 Edg/124.0.0.0";

/// 品质 key → weapi level 参数（对齐 neteaseLevels）
fn netease_level_for_key(key: &str, quality: Quality) -> &'static str {
    match key {
        "128k" => "standard",
        "320k" => {
            if quality == Quality::Sq {
                "higher"
            } else {
                "exhigh"
            }
        }
        "flac" => "lossless",
        "flac24bit" => "hires",
        _ => "exhigh",
    }
}

/// 随机小写字母（WNMCID 前缀）
fn rand_letters(n: usize) -> String {
    use rand::RngExt;
    let mut rng = rand::rng();
    (0..n)
        .map(|_| (b'a' + rng.random_range(0..26)) as char)
        .collect()
}

/// 随机 hex 字节串（_ntes_nuid 等）
fn rand_hex_bytes(n: usize) -> String {
    use rand::RngExt;
    let mut rng = rand::rng();
    (0..n)
        .map(|_| format!("{:02x}", rng.random_range(0..=255u8)))
        .collect()
}

/// 对齐 Dart _processCookieObject：补齐 cookie 必备字段（跳过需网络注册的
/// MUSIC_A；匿名下载 URL 无需登录态）。metadata.rs（元数据拉取）复用。
pub(crate) fn build_netease_cookie(user_cookie: Option<&str>) -> String {
    use std::collections::HashMap;
    let mut c: HashMap<String, String> = HashMap::new();
    if let Some(uc) = user_cookie {
        for pair in uc.split(';') {
            if let Some((k, v)) = pair.trim().split_once('=') {
                c.insert(k.trim().to_string(), v.trim().to_string());
            }
        }
    }
    let now = now_secs() * 1000;
    // 设备指纹（Dart 注入）：优先注入值，其次用户 cookie，最后进程随机。
    // 对齐 downloader-identity-plan §3.1：同一用户指纹跨会话稳定。
    let ident = crate::downloader_identity();
    let ntes_nuid = c
        .get("_ntes_nuid")
        .cloned()
        .or(ident.nm_nuid)
        .unwrap_or_else(|| rand_hex_bytes(16));
    let ntes_nnid = c
        .get("_ntes_nnid")
        .cloned()
        .unwrap_or_else(|| format!("{ntes_nuid},{now}"));
    let wnmcid = c
        .get("WNMCID")
        .cloned()
        .unwrap_or_else(|| format!("{}.{now}.01.0", rand_letters(6)));
    let device_id = c.get("deviceId").cloned().or(ident.nm_device_id).unwrap_or_else(|| {
        use rand::RngExt;
        let mut rng = rand::rng();
        (0..26)
            .map(|_| format!("{:X}", rng.random_range(0..16)))
            .collect::<String>()
    });

    let mut out: Vec<(String, String)> = vec![
        ("__remember_me".into(), "true".into()),
        ("ntes_kaola_ad".into(), "1".into()),
        ("_ntes_nuid".into(), ntes_nuid),
        ("_ntes_nnid".into(), ntes_nnid),
        ("WNMCID".into(), wnmcid),
        ("WEVNSM".into(), "1.0.0".into()),
        // osver 优先用注入的真实系统版本（消除全用户共享「Win10 19045」群体指纹）
        (
            "osver".into(),
            ident
                .osver
                .unwrap_or_else(|| "Microsoft-Windows-10-Professional-build-19045-64bit".to_string()),
        ),
        ("deviceId".into(), device_id),
        ("os".into(), "pc".into()),
        ("channel".into(), "netease".into()),
        ("appver".into(), "3.1.17.204416".into()),
        ("NMTID".into(), rand_hex_bytes(8)),
    ];
    // 用户注入的 cookie 里已有的键（如 MUSIC_U）追加在末尾
    for (k, v) in c.iter() {
        if !out.iter().any(|(ok, _)| ok == k) {
            out.push((k.clone(), v.clone()));
        }
    }
    out.iter()
        .map(|(k, v)| format!("{k}={v}"))
        .collect::<Vec<_>>()
        .join("; ")
}

/// 单档 weapi 下载 URL 请求。服务端业务失败（code != 200 / 无 url）返回 Ok(None)
/// 由上层继续降级；网络/加密错误返回 Err。
async fn nm_download_url(
    client: &reqwest::Client,
    platform_id: &str,
    level: &str,
    cookie_header: &str,
) -> Result<Option<ResolvedUrl>> {
    let data = serde_json::json!({
        "id": platform_id,
        "level": level,
        "csrf_token": "",
        "e_r": false,
    });
    log::debug!("Netease download/url 请求: id={platform_id} level={level} 带cookie={}字符", cookie_header.len());
    let (params, enc_sec_key) = nm::weapi_encrypt(&data);

    crate::request_pacing().await;
    let resp = match client
        .post(NM_WEAPI_URL)
        .header("Referer", NM_DOMAIN)
        .header("User-Agent", NM_WEAPI_UA)
        .header("Cookie", cookie_header)
        .form(&[
            ("params", params.as_str()),
            ("encSecKey", enc_sec_key.as_str()),
        ])
        .send()
        .await
    {
        Ok(r) => r,
        Err(e) => {
            crate::failure_backoff().await;
            return Err(anyhow!("netease weapi HTTP 失败: {e}"));
        }
    };
    let status = resp.status();
    let body: serde_json::Value = match resp.json().await {
        Ok(v) => v,
        Err(e) => {
            crate::failure_backoff().await;
            return Err(anyhow!("netease weapi 响应解析失败 (HTTP {status}): {e}"));
        }
    };

    let code = body.get("code").and_then(|v| v.as_i64()).unwrap_or(-1);
    if code != 200 {
        return Ok(None);
    }
    let data = body.get("data");
    let Some(data) = data else { return Ok(None) };
    let url = data.get("url").and_then(|v| v.as_str()).map(str::to_string).unwrap_or_default();
    if url.is_empty() {
        return Ok(None);
    }
    let ext = data
        .get("type")
        .and_then(|v| v.as_str())
        .map(str::to_string)
        .unwrap_or_else(|| "mp3".to_string());
    let size = data.get("size").and_then(|v| v.as_u64());

    log::debug!(
        "Netease download/url 命中: level={level} ext={ext} size={:?} url={}...",
        size,
        url.chars().take(80).collect::<String>()
    );
    crate::reset_failures();
    Ok(Some(ResolvedUrl {
        url,
        quality_key: level_to_key(level),
        file_ext: ext,
        file_size: size,
        extra_headers: vec![
            ("Referer".to_string(), NM_DOMAIN.to_string()),
            ("User-Agent".to_string(), NM_WEAPI_UA.to_string()),
            ("Cookie".to_string(), cookie_header.to_string()),
        ],
    }))
}

/// level → 品质 key（供 done 事件的 actualQuality 使用）
fn level_to_key(level: &str) -> String {
    match level {
        "standard" => "128k".to_string(),
        "higher" | "exhigh" => "320k".to_string(),
        "lossless" => "flac".to_string(),
        "hires" => "flac24bit".to_string(),
        _ => level.to_string(),
    }
}

/// 单档播放 URL 请求（下载接口的回落，对齐原版 fetchNeteasePlaySource）。
///
/// 网易云 `download/url`（客户端下载接口）对未登录 / 无下载权限的歌曲经常
/// 返回 url=null（尤其无损档），而 `player/url`（播放接口）对免费曲仍能返回
/// 完整无损 URL。顺序为 download → 失败回落 player，
/// 本函数即该回落：data 为数组取首项，**freeTrialInfo（试听片段）视为不可用**。
async fn nm_player_url(
    client: &reqwest::Client,
    platform_id: &str,
    level: &str,
    cookie_header: &str,
) -> Result<Option<ResolvedUrl>> {
    let data = serde_json::json!({
        "ids": format!("[{}]", platform_id),
        "level": level,
        "encodeType": "flac",
        "e_r": true,
    });
    log::debug!("Netease player/url 请求: id={platform_id} level={level} 带cookie={}字符", cookie_header.len());
    let (params, enc_sec_key) = nm::weapi_encrypt(&data);

    crate::request_pacing().await;
    let resp = match client
        .post(NM_PLAYER_URL)
        .header("Referer", NM_DOMAIN)
        .header("User-Agent", NM_WEAPI_UA)
        .header("Cookie", cookie_header)
        .form(&[
            ("params", params.as_str()),
            ("encSecKey", enc_sec_key.as_str()),
        ])
        .send()
        .await
    {
        Ok(r) => r,
        Err(e) => {
            crate::failure_backoff().await;
            return Err(anyhow!("netease weapi 播放 URL HTTP 失败: {e}"));
        }
    };
    let status = resp.status();
    let body: serde_json::Value = match resp.json().await {
        Ok(v) => v,
        Err(e) => {
            crate::failure_backoff().await;
            return Err(anyhow!("netease weapi 播放 URL 响应解析失败 (HTTP {status}): {e}"));
        }
    };

    let code = body.get("code").and_then(|v| v.as_i64()).unwrap_or(-1);
    if code != 200 {
        return Ok(None);
    }
    // data 一般为数组（取首项）；个别接口返回单对象时也兼容
    let item = body.get("data").and_then(|d| match d {
        serde_json::Value::Array(a) => a.first(),
        serde_json::Value::Object(_) => Some(d),
        _ => None,
    });
    let Some(item) = item else { return Ok(None) };
    let url = item
        .get("url")
        .and_then(|v| v.as_str())
        .map(str::to_string)
        .unwrap_or_default();
    if url.is_empty() {
        return Ok(None);
    }
    // 试听片段（仅 30s）不能作为下载源
    if item.get("freeTrialInfo").is_some_and(|v| !v.is_null()) {
        return Ok(None);
    }
    let ext = item
        .get("type")
        .and_then(|v| v.as_str())
        .map(str::to_string)
        .unwrap_or_else(|| "mp3".to_string());
    let size = item.get("size").and_then(|v| v.as_u64());

    log::debug!(
        "Netease player/url 命中: level={level} ext={ext} size={:?} url={}...",
        size,
        url.chars().take(80).collect::<String>()
    );
    crate::reset_failures();
    Ok(Some(ResolvedUrl {
        url,
        quality_key: level_to_key(level),
        file_ext: ext,
        file_size: size,
        extra_headers: vec![
            ("Referer".to_string(), NM_DOMAIN.to_string()),
            ("User-Agent".to_string(), NM_WEAPI_UA.to_string()),
            ("Cookie".to_string(), cookie_header.to_string()),
        ],
    }))
}

impl SourceResolver for NeteaseResolver {
    fn resolve_play_url<'a>(
        &'a self,
        request: &'a EnqueueRequest,
        cancel: &'a Arc<AtomicBool>,
    ) -> Pin<Box<dyn Future<Output = Result<ResolvedUrl>> + Send + 'a>> {
        Box::pin(async move {
            let client = crate::http_client();
            let cookie_header = build_netease_cookie(crate::netease_cookie().as_deref());

            for qk in request.quality.quality_chain() {
                if cancel.load(Ordering::Relaxed) {
                    bail!("已取消");
                }
                let level = netease_level_for_key(qk, request.quality);
                // 官方下载接口优先；无权限/失败时回落播放接口（对齐原版
                // resolveNeteaseDownloadUrl：download → player），免费曲仍能
                // 拿到完整无损 URL，避免高音质被无条件降级。
                match nm_download_url(&client, &request.platform_id, level, &cookie_header).await {
                    Ok(Some(resolved)) => return Ok(resolved),
                    _ => {}
                }
                match nm_player_url(&client, &request.platform_id, level, &cookie_header).await {
                    Ok(Some(resolved)) => return Ok(resolved),
                    _ => {
                        // 服务端该档位不可用（无 url / 试听片段）→ 继续降级链
                    }
                }
            }
            bail!("Netease 所有音质档位均无法获取 URL")
        })
    }
}

// ============================================================
// 默认实现 A3：Bilibili 自研 WBI + DASH 音频（AAC/M4A）
// ============================================================

#[derive(Default, Clone, Debug)]
pub struct BilibiliResolver;

const BILI_API: &str = "https://api.bilibili.com";
const BILI_UA: &str = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36";
const BILI_REFERER: &str = "https://www.bilibili.com/";
const BILI_MIXIN: [usize; 32] = [
    46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49, 33, 9, 42, 19,
    29, 28, 14, 39, 12, 38, 41, 13,
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum BiliAudioKind {
    Aac,
    Flac,
    Dolby,
}

struct BiliAudio {
    id: u64,
    bandwidth: u64,
    urls: Vec<String>,
    size: Option<u64>,
    kind: BiliAudioKind,
}

/// 从 `dash.audio` / `dash.flac.audio` / `dash.dolby.audio` 收集候选音轨。
///
/// `flac.audio` 在接口里可能是对象（单条），其它为数组；两种都接受。
/// 只按编码过滤，权限由服务端下发结果决定。
fn bili_collect_audio(value: Option<&serde_json::Value>, kind: BiliAudioKind, out: &mut Vec<BiliAudio>) {
    let Some(value) = value else { return };
    let rows: Vec<&serde_json::Value> = match value {
        serde_json::Value::Array(items) => items.iter().collect(),
        serde_json::Value::Object(_) => vec![value],
        _ => return,
    };
    for row in rows {
        let codecs = row
            .get("codecs")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_ascii_lowercase();
        let matches = match kind {
            BiliAudioKind::Aac => codecs.starts_with("mp4a"),
            BiliAudioKind::Flac => codecs == "flac",
            BiliAudioKind::Dolby => {
                codecs.starts_with("ec-3")
                    || codecs.starts_with("eac3")
                    || codecs.starts_with("ac-3")
            }
        };
        if !matches {
            continue;
        }
        let urls = bili_audio_urls(row);
        if urls.is_empty() {
            continue;
        }
        out.push(BiliAudio {
            id: row.get("id").and_then(|v| v.as_u64()).unwrap_or(0),
            bandwidth: row.get("bandwidth").and_then(|v| v.as_u64()).unwrap_or(0),
            urls,
            size: row.get("size").and_then(|v| v.as_u64()),
            kind,
        });
    }
}

/// 按统一音质档挑选音轨：
/// - lq / sq / hq → AAC 对应档位（缺档时取不高于目标的最高档）；
/// - lossless / hi-res → FLAC → 杜比 → 192K AAC。
fn bili_select_audio(candidates: &[BiliAudio], quality: Quality) -> Option<&BiliAudio> {
    let mut premium: Vec<&BiliAudio> = candidates
        .iter()
        .filter(|c| c.kind != BiliAudioKind::Aac)
        .collect();
    premium.sort_by(|a, b| {
        if a.kind != b.kind {
            return if a.kind == BiliAudioKind::Flac {
                std::cmp::Ordering::Less
            } else {
                std::cmp::Ordering::Greater
            };
        }
        b.bandwidth.cmp(&a.bandwidth)
    });
    if matches!(quality, Quality::Lossless | Quality::HiRes) {
        if let Some(found) = premium.first() {
            return Some(*found);
        }
    }

    let target = match quality {
        Quality::Lq => 30216,
        Quality::Sq => 30232,
        _ => 30280,
    };
    let mut aac: Vec<&BiliAudio> = candidates
        .iter()
        .filter(|c| c.kind == BiliAudioKind::Aac && c.id <= target)
        .collect();
    aac.sort_by_key(|c| (c.id, c.bandwidth));
    if let Some(found) = aac.last() {
        return Some(*found);
    }
    candidates
        .iter()
        .filter(|c| c.kind == BiliAudioKind::Aac)
        .max_by_key(|c| c.bandwidth)
        .or_else(|| premium.first().copied())
}

impl SourceResolver for BilibiliResolver {
    fn resolve_play_url<'a>(
        &'a self,
        request: &'a EnqueueRequest,
        cancel: &'a Arc<AtomicBool>,
    ) -> Pin<Box<dyn Future<Output = Result<ResolvedUrl>> + Send + 'a>> {
        Box::pin(async move {
            if cancel.load(Ordering::Relaxed) {
                bail!("已取消");
            }
            let (bvid, cid) = bili_split_id(&request.platform_id);
            if !bili_valid_bvid(&bvid) {
                bail!("无效的 B 站 BV 号: {bvid}");
            }

            let client = crate::http_client();
            let cookie = crate::bilibili_cookie();
            let headers = bili_headers(cookie.as_deref());
            let cid = match cid {
                Some(cid) => cid,
                None => bili_view_cid(&client, &headers, &bvid).await?,
            };
            if cancel.load(Ordering::Relaxed) {
                bail!("已取消");
            }

            let (image_key, sub_key) = bili_wbi_keys(&client, &headers).await?;
            let mut params = BTreeMap::new();
            params.insert("bvid".to_string(), bvid.clone());
            params.insert("cid".to_string(), cid);
            // 272 = DASH(16) + 杜比音频(256)；只请求音频所需能力位，
            // 不请求 HDR / 4K / 8K / AV1 等视频档位，响应中的 dash.video 一律忽略。
            params.insert("fnval".to_string(), "272".to_string());
            params.insert("fnver".to_string(), "0".to_string());
            params.insert("fourk".to_string(), "0".to_string());
            let timestamp = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map_err(|e| anyhow!("系统时间异常: {e}"))?
                .as_secs();
            let query = bili_sign_query_at(&params, &image_key, &sub_key, timestamp)?;
            let url = format!("{BILI_API}/x/player/wbi/playurl?{query}");
            let value = bili_get_json(&client, &url, &headers).await?;
            let data = bili_check_code(&value)?;

            if data.get("is_preview").and_then(|v| v.as_i64()) == Some(1) {
                bail!("B 站仅提供预览");
            }
            let mut candidates = Vec::new();
            bili_collect_audio(data.pointer("/dash/audio"), BiliAudioKind::Aac, &mut candidates);
            bili_collect_audio(
                data.pointer("/dash/flac/audio"),
                BiliAudioKind::Flac,
                &mut candidates,
            );
            bili_collect_audio(
                data.pointer("/dash/dolby/audio"),
                BiliAudioKind::Dolby,
                &mut candidates,
            );
            if candidates.is_empty() {
                bail!("B 站无可用音频流");
            }
            let chosen = bili_select_audio(&candidates, request.quality)
                .ok_or_else(|| anyhow!("B 站无匹配音质档位的音频流"))?;
            let quality_key = match chosen.kind {
                BiliAudioKind::Aac => "aac",
                BiliAudioKind::Flac => "flac",
                BiliAudioKind::Dolby => "eac3",
            };
            log::debug!(
                "Bilibili 选择音轨 id={} bandwidth={} kind={:?} urls={}",
                chosen.id,
                chosen.bandwidth,
                chosen.kind,
                chosen.urls.len()
            );
            Ok(ResolvedUrl {
                url: chosen.urls[0].clone(),
                quality_key: quality_key.to_string(),
                file_ext: "m4a".to_string(),
                file_size: chosen.size,
                extra_headers: vec![
                    ("User-Agent".to_string(), BILI_UA.to_string()),
                    ("Referer".to_string(), BILI_REFERER.to_string()),
                ],
            })
        })
    }
}

fn bili_split_id(raw: &str) -> (String, Option<String>) {
    let mut parts = raw.splitn(2, ':');
    let bvid = parts.next().unwrap_or("").trim().to_string();
    let cid = parts
        .next()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string);
    (bvid, cid)
}

fn bili_valid_bvid(value: &str) -> bool {
    value.len() == 12
        && value.starts_with("BV")
        && value[2..].bytes().all(|b| b.is_ascii_alphanumeric())
}

fn bili_valid_wbi_key(value: &str) -> bool {
    value.len() == 32 && value.bytes().all(|b| b.is_ascii_hexdigit())
}

fn bili_percent_encode(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for byte in input.as_bytes() {
        if byte.is_ascii_alphanumeric() || matches!(*byte, b'-' | b'_' | b'.' | b'~') {
            out.push(*byte as char);
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

fn bili_sign_query_at(
    params: &BTreeMap<String, String>,
    image_key: &str,
    sub_key: &str,
    timestamp: u64,
) -> Result<String> {
    if !bili_valid_wbi_key(image_key) || !bili_valid_wbi_key(sub_key) {
        bail!("B 站 WBI key 非法");
    }
    let mut all = params.clone();
    all.insert("wts".to_string(), timestamp.to_string());
    let query = all
        .iter()
        .map(|(key, value)| {
            let cleaned: String = value
                .chars()
                .filter(|c| !matches!(c, '!' | '\'' | '(' | ')' | '*'))
                .collect();
            format!(
                "{}={}",
                bili_percent_encode(key),
                bili_percent_encode(&cleaned)
            )
        })
        .collect::<Vec<_>>()
        .join("&");
    let raw = format!("{image_key}{sub_key}");
    let mixin = BILI_MIXIN
        .iter()
        .map(|&index| raw.as_bytes().get(index).copied().map(char::from))
        .collect::<Option<String>>()
        .ok_or_else(|| anyhow!("B 站 WBI mixin key 越界"))?;
    let digest = hex::encode(Md5::digest(format!("{query}{mixin}").as_bytes()));
    Ok(format!("{query}&w_rid={digest}"))
}

fn bili_headers(cookie: Option<&str>) -> HeaderMap {
    let mut headers = HeaderMap::new();
    headers.insert(header::USER_AGENT, HeaderValue::from_static(BILI_UA));
    headers.insert(header::REFERER, HeaderValue::from_static(BILI_REFERER));
    headers.insert(header::ACCEPT, HeaderValue::from_static("application/json"));
    if let Some(cookie) = cookie {
        if let Ok(value) = HeaderValue::from_str(cookie) {
            headers.insert(header::COOKIE, value);
        }
    }
    headers
}

async fn bili_get_json(
    client: &reqwest::Client,
    url: &str,
    headers: &HeaderMap,
) -> Result<serde_json::Value> {
    crate::request_pacing().await;
    let response = client
        .get(url)
        .headers(headers.clone())
        .timeout(Duration::from_secs(15))
        .send()
        .await?;
    let status = response.status();
    if !status.is_success() {
        bail!("B 站 HTTP {status}");
    }
    let bytes = response.bytes().await?;
    if bytes.len() > 4 * 1024 * 1024 {
        bail!("B 站响应过大");
    }
    serde_json::from_slice(&bytes).map_err(|e| anyhow!("B 站响应不是有效 JSON: {e}"))
}

fn bili_check_code(value: &serde_json::Value) -> Result<&serde_json::Value> {
    let code = value.get("code").and_then(|v| v.as_i64()).unwrap_or(-1);
    if code != 0 {
        let message = value
            .get("message")
            .and_then(|v| v.as_str())
            .unwrap_or("B 站内容不可用");
        bail!("B 站 code={code}: {message}");
    }
    value
        .get("data")
        .ok_or_else(|| anyhow!("B 站响应缺少 data"))
}

fn bili_key_from_url(raw: &str) -> Option<String> {
    let url = reqwest::Url::parse(raw).ok()?;
    let name = url.path_segments()?.last()?;
    let stem = name.split('.').next().unwrap_or(name);
    bili_valid_wbi_key(stem).then(|| stem.to_string())
}

async fn bili_wbi_keys(
    client: &reqwest::Client,
    headers: &HeaderMap,
) -> Result<(String, String)> {
    let value = bili_get_json(
        client,
        &format!("{BILI_API}/x/web-interface/nav"),
        headers,
    )
    .await?;
    let image_key = value
        .pointer("/data/wbi_img/img_url")
        .and_then(|v| v.as_str())
        .and_then(bili_key_from_url)
        .ok_or_else(|| anyhow!("B 站未返回 WBI img key"))?;
    let sub_key = value
        .pointer("/data/wbi_img/sub_url")
        .and_then(|v| v.as_str())
        .and_then(bili_key_from_url)
        .ok_or_else(|| anyhow!("B 站未返回 WBI sub key"))?;
    Ok((image_key, sub_key))
}

async fn bili_view_cid(
    client: &reqwest::Client,
    headers: &HeaderMap,
    bvid: &str,
) -> Result<String> {
    let value = bili_get_json(
        client,
        &format!("{BILI_API}/x/web-interface/view?bvid={bvid}"),
        headers,
    )
    .await?;
    let data = bili_check_code(&value)?;
    let cid = data
        .pointer("/pages/0/cid")
        .and_then(|v| v.as_i64())
        .or_else(|| data.get("cid").and_then(|v| v.as_i64()))
        .ok_or_else(|| anyhow!("B 站视频缺少 cid"))?;
    if cid <= 0 {
        bail!("B 站视频 cid 非法");
    }
    Ok(cid.to_string())
}

fn bili_audio_urls(row: &serde_json::Value) -> Vec<String> {
    let mut urls = Vec::new();
    if let Some(url) = row.get("baseUrl").and_then(|v| v.as_str()) {
        urls.push(url.to_string());
    }
    if let Some(url) = row.get("base_url").and_then(|v| v.as_str()) {
        urls.push(url.to_string());
    }
    for key in ["backupUrl", "backup_url"] {
        if let Some(items) = row.get(key).and_then(|v| v.as_array()) {
            for item in items {
                if let Some(url) = item.as_str() {
                    urls.push(url.to_string());
                }
            }
        }
    }
    urls.retain(|url| {
        reqwest::Url::parse(url)
            .map(|u| u.scheme() == "https" && u.host_str().is_some() && u.username().is_empty())
            .unwrap_or(false)
    });
    urls.dedup();
    if let Some(index) = urls.iter().position(|url| {
        reqwest::Url::parse(url)
            .ok()
            .and_then(|u| u.host_str().map(str::to_ascii_lowercase))
            .map(|host| host.starts_with("upos-") && host.ends_with(".bilivideo.com"))
            .unwrap_or(false)
    }) {
        let preferred = urls.remove(index);
        urls.insert(0, preferred);
    }
    urls
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn registry_resolves_self_hosted_sources() {
        assert!(resolver_for("kugou").is_some());
        assert!(resolver_for("netease").is_some());
        assert!(resolver_for("bilibili").is_some());
        // 大小写不敏感（from_wire 归一）
        assert!(resolver_for("Kugou").is_some());
    }

    #[test]
    fn registry_returns_none_for_preresolved_and_unknown() {
        // 预解析/直链音源：无自研解析 → None（走 Dart 预解析 URL）。
        for s in ["qqmusic", "streaming"] {
            assert!(resolver_for(s).is_none(), "source={s} 应无注册解析器");
            assert!(resolver_for_platform(SourcePlatform::from_wire(s)).is_none());
        }
        // 未来未知音源同样 None，不再硬报错。
        assert!(resolver_for_platform(SourcePlatform::Unknown).is_none());
    }

    #[test]
    fn bilibili_wbi_matches_published_vector() {
        let mut params = BTreeMap::new();
        params.insert("foo".to_string(), "114".to_string());
        params.insert("bar".to_string(), "514".to_string());
        params.insert("zab".to_string(), "1919810".to_string());
        let query = bili_sign_query_at(
            &params,
            "7cd084941338484aae1ad9425b84077c",
            "4932caff0ff746eab6f01bf08b70ac45",
            1702204169,
        )
        .unwrap();
        assert_eq!(
            query,
            "bar=514&foo=114&wts=1702204169&zab=1919810&\
             w_rid=8f6f2b5b3d485fe1886cec6a0be8c5d4"
        );
    }

    #[test]
    fn bilibili_id_and_quality_helpers() {
        assert!(bili_valid_bvid("BV1Cjxy68EKv"));
        assert!(!bili_valid_bvid("BV123"));
        assert_eq!(
            bili_split_id("BV1Cjxy68EKv:123"),
            ("BV1Cjxy68EKv".to_string(), Some("123".to_string()))
        );
        assert_eq!(
            bili_split_id("BV1Cjxy68EKv"),
            ("BV1Cjxy68EKv".to_string(), None)
        );
    }

    fn audio(id: u64, bandwidth: u64, kind: BiliAudioKind) -> BiliAudio {
        BiliAudio {
            id,
            bandwidth,
            urls: vec![format!("https://upos-test.bilivideo.com/{id}.m4s")],
            size: None,
            kind,
        }
    }

    #[test]
    fn bilibili_audio_levels_fall_back_to_aac() {
        let candidates = vec![
            audio(30216, 65_000, BiliAudioKind::Aac),
            audio(30280, 192_000, BiliAudioKind::Aac),
        ];
        assert_eq!(
            bili_select_audio(&candidates, Quality::Lq).map(|c| c.id),
            Some(30216)
        );
        assert_eq!(
            bili_select_audio(&candidates, Quality::Hq).map(|c| c.id),
            Some(30280)
        );
        // 无 FLAC / 杜比：无损档回退到最高的 AAC。
        assert_eq!(
            bili_select_audio(&candidates, Quality::Lossless).map(|c| c.id),
            Some(30280)
        );
        assert_eq!(
            bili_select_audio(&candidates, Quality::HiRes).map(|c| c.id),
            Some(30280)
        );
    }

    #[test]
    fn bilibili_audio_prefers_flac_then_dolby() {
        let with_flac = vec![
            audio(30280, 192_000, BiliAudioKind::Aac),
            audio(30250, 448_000, BiliAudioKind::Dolby),
            audio(30251, 1_200_000, BiliAudioKind::Flac),
        ];
        let chosen = bili_select_audio(&with_flac, Quality::Lossless).unwrap();
        assert_eq!(chosen.kind, BiliAudioKind::Flac);
        assert_eq!(chosen.id, 30251);
        // 普通档不受无损音轨影响。
        assert_eq!(
            bili_select_audio(&with_flac, Quality::Hq).map(|c| c.id),
            Some(30280)
        );

        let dolby_only = vec![
            audio(30280, 192_000, BiliAudioKind::Aac),
            audio(30250, 448_000, BiliAudioKind::Dolby),
        ];
        let chosen = bili_select_audio(&dolby_only, Quality::HiRes).unwrap();
        assert_eq!(chosen.kind, BiliAudioKind::Dolby);
    }
}
