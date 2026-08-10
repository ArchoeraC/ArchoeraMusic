// ============================================================
// §9.6 第 3 层防御：PlatformUrlResolver trait 抽象
//
// 戒律 13.2：Dart 绝不参与 URL 解析签名，全在 Rust 内部。
// 自研优先（§9.6 第 1 层）：Kugou/Netease 签名算法为 crate::crypto
// 全新实现，对照 Dart kugou_crypto.dart / netease crypto.dart 1:1 移植。
//
// v2 相对设计稿变更（2026-08-09）：因编译环境不得访问 GitHub，第三方 SDK
// 备胎（kugou_sdk / ncm-api-rs）已整体移除，仅保留自研实现 + trait 抽象
// （未来如需要 SDK 备胎，按同一 trait 新增 impl 即可，业务代码零改动）。
// ============================================================

use std::collections::BTreeMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use anyhow::{anyhow, bail, Result};

use crate::crypto::kugou as kg;
use crate::crypto::netease as nm;
use crate::models::*;

// ============================================================
// trait 定义（第 3 层隔离）
// ============================================================

pub trait PlatformUrlResolver: Send + Sync {
    /// 解析可下载 URL；[cancel] 为任务取消标志（解析阶段也响应取消）。
    fn resolve_play_url<'a>(
        &'a self,
        request: &'a EnqueueRequest,
        cancel: &'a Arc<AtomicBool>,
    ) -> Pin<Box<dyn Future<Output = Result<ResolvedUrl>> + Send + 'a>>;
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

    let resp = client
        .post(&url)
        .headers(headers)
        .body(cipher)
        .send()
        .await
        .map_err(|e| anyhow!("register_dev HTTP 失败: {e}"))?;
    let bytes = resp.bytes().await.map_err(|e| anyhow!("register_dev 读响应失败: {e}"))?;

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
        Some(d) if !d.is_empty() => Ok(d),
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

    let resp = client
        .get(&url)
        .headers(headers)
        .send()
        .await
        .map_err(|e| KgUrlError { needs_dfid_refresh: false, is_paywall: false, msg: format!("v5/url HTTP 失败: {e}") })?;
    let status = resp.status();
    let text = resp
        .text()
        .await
        .map_err(|e| KgUrlError { needs_dfid_refresh: false, is_paywall: false, msg: format!("v5/url 读响应失败: {e}") })?;
    let body: serde_json::Value = serde_json::from_str(&text)
        .map_err(|e| KgUrlError { needs_dfid_refresh: false, is_paywall: false, msg: format!("v5/url 响应非 JSON (HTTP {status}): {e}") })?;

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

impl PlatformUrlResolver for KugouResolver {
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
    use rand::Rng;
    let mut rng = rand::thread_rng();
    (0..n).map(|_| (b'a' + rng.gen_range(0..26)) as char).collect()
}

/// 随机 hex 字节串（_ntes_nuid 等）
fn rand_hex_bytes(n: usize) -> String {
    use rand::Rng;
    let mut rng = rand::thread_rng();
    (0..n).map(|_| format!("{:02x}", rng.gen_range(0..=255u8))).collect()
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
    let ntes_nuid = c
        .get("_ntes_nuid")
        .cloned()
        .unwrap_or_else(|| rand_hex_bytes(16));
    let ntes_nnid = c
        .get("_ntes_nnid")
        .cloned()
        .unwrap_or_else(|| format!("{ntes_nuid},{now}"));
    let wnmcid = c
        .get("WNMCID")
        .cloned()
        .unwrap_or_else(|| format!("{}.{now}.01.0", rand_letters(6)));
    let device_id = c.get("deviceId").cloned().unwrap_or_else(|| {
        use rand::Rng;
        let mut rng = rand::thread_rng();
        (0..26)
            .map(|_| format!("{:X}", rng.gen_range(0..16)))
            .collect::<String>()
    });

    let mut out: Vec<(String, String)> = vec![
        ("__remember_me".into(), "true".into()),
        ("ntes_kaola_ad".into(), "1".into()),
        ("_ntes_nuid".into(), ntes_nuid),
        ("_ntes_nnid".into(), ntes_nnid),
        ("WNMCID".into(), wnmcid),
        ("WEVNSM".into(), "1.0.0".into()),
        ("osver".into(), "Microsoft-Windows-10-Professional-build-19045-64bit".into()),
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

    let resp = client
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
        .map_err(|e| anyhow!("netease weapi HTTP 失败: {e}"))?;
    let status = resp.status();
    let body: serde_json::Value = resp
        .json()
        .await
        .map_err(|e| anyhow!("netease weapi 响应解析失败 (HTTP {status}): {e}"))?;

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
/// 完整无损 URL。原版 SPlayer-Next 的顺序是 download → 失败回落 player，
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

    let resp = client
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
        .map_err(|e| anyhow!("netease weapi 播放 URL HTTP 失败: {e}"))?;
    let status = resp.status();
    let body: serde_json::Value = resp
        .json()
        .await
        .map_err(|e| anyhow!("netease weapi 播放 URL 响应解析失败 (HTTP {status}): {e}"))?;

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

impl PlatformUrlResolver for NeteaseResolver {
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
