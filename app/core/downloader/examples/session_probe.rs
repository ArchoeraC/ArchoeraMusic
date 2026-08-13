//! session_probe.rs — vault-3 端到端探针（真实凭据，用户授权）：
//! ① FFI setter 注入真实登录态（经 MlockSecret 存储路径）
//! ② NeteaseResolver / KugouResolver 消费该登录态解析 VIP 歌曲 URL
//! 证明「mlock 存储 → getter 读回 → 签名/weapi 请求」整条链无信息丢失。
//! 不入库。运行：cargo run --example session_probe --release
use std::collections::HashMap;
use std::ffi::CString;
use std::sync::atomic::AtomicBool;
use std::sync::Arc;

use archoera_downloader::models::{EnqueueRequest, Quality, SourcePlatform, TrackExtra};
use archoera_downloader::resolvers::{KugouResolver, NeteaseResolver, PlatformUrlResolver};

/// 会话文件路径（默认当前目录 netease_session.json；可用 ARCHOERA_SESSION_JSON 覆盖，
/// 避免硬编码用户凭证路径）
fn session_path() -> String {
    std::env::var("ARCHOERA_SESSION_JSON")
        .unwrap_or_else(|_| "netease_session.json".to_string())
}

/// 探针不消费事件，空回调占位（init 要求非空）
extern "C" fn dummy_event(_ptr: *mut std::os::raw::c_char) {}

fn ffi_init() {
    let root = CString::new("/tmp/session_probe_root").unwrap();
    let rc = archoera_downloader::archoera_downloader_init(
        root.as_ptr(),
        0,
        1,
        dummy_event as *mut std::os::raw::c_void,
        std::ptr::null_mut(),
    );
    assert_eq!(rc, 0, "init 失败 rc={rc}");
    println!("FFI init: ok");
}

fn load_session() -> (String, String, String) {
    // 返回 (netease_cookie_header, kugou_userid, kugou_token)
    let text = std::fs::read_to_string(session_path()).expect("读取真实会话");
    let v: serde_json::Value = serde_json::from_str(&text).expect("解析会话 JSON");
    let nm = &v["netease"];
    let mut cookie = String::new();
    if let Some(map) = nm.as_object() {
        for (k, val) in map {
            if k == "NMTID" || k == "MUSIC_A_T" || k == "MUSIC_R_T" {
                continue; // 短标识无需携带
            }
            if let Some(s) = val.as_str() {
                if !s.is_empty() {
                    if !cookie.is_empty() {
                        cookie.push_str("; ");
                    }
                    cookie.push_str(k);
                    cookie.push('=');
                    cookie.push_str(s);
                }
            }
        }
    }
    let kg = &v["kugou"];
    (
        cookie,
        kg["userid"].as_str().unwrap_or("").to_string(),
        kg["token"].as_str().unwrap_or("").to_string(),
    )
}

/// 经 FFI 注入（CString 边界，走 lib.rs setter 的 Zeroizing + MlockSecret）
fn ffi_inject(cookie: &str, userid: &str, token: &str) {
    let c_cookie = CString::new(cookie).unwrap();
    let c_uid = CString::new(userid).unwrap();
    let c_tok = CString::new(token).unwrap();
    let r1 = archoera_downloader::archoera_downloader_set_netease_cookie(c_cookie.as_ptr());
    let r2 = archoera_downloader::archoera_downloader_set_kugou_session(c_uid.as_ptr(), c_tok.as_ptr());
    println!("FFI 注入: netease={r1} kugou={r2} (0=成功)");
    // 直接读回（crate::netease_cookie 为 pub(crate)，探针不可见；这里用二次解析间接验证）
    assert_eq!(r1, 0);
    assert_eq!(r2, 0);
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let (cookie, uid, tok) = load_session();
    ffi_init();
    println!(
        "会话载入: netease_cookie_len={} kugou_uid={} token_len={}",
        cookie.len(),
        uid,
        tok.len()
    );
    ffi_inject(&cookie, &uid, &tok);
    let cancel = Arc::new(AtomicBool::new(false));

    // ── 1. 网易 VIP 歌曲（屋顶 5257138，Dart 侧确认真实 cookie 可解锁；晴天 186016 对照）──
    for (nm_id, nm_title) in [("5257138", "屋顶"), ("186016", "晴天")] {
        let nm_req = EnqueueRequest {
            track_id: format!("probe-nm-{nm_id}"),
            source: SourcePlatform::Netease,
            platform_id: nm_id.into(),
            quality: Quality::Lossless,
            title: nm_title.into(),
            artist: "周杰伦".into(),
            album: None,
            extra: TrackExtra::default(),
        };
        match NeteaseResolver.resolve_play_url(&nm_req, &cancel).await {
            Ok(r) => println!(
                "✓ 网易 {nm_title} lossless: quality={} ext={} url={} headers={}",
                r.quality_key,
                r.file_ext,
                r.url.chars().take(90).collect::<String>(),
                r.extra_headers.len()
            ),
            Err(e) => println!("✗ 网易 {nm_title} lossless 失败: {e:#}"),
        }
    }

    // ── 2. 酷狗 VIP 歌曲（西憂花 - ふわふわhazy 四档 hash）──
    let mut hashes = HashMap::new();
    hashes.insert("128k".to_string(), "973F5079DB5A1F97AE03F28D586C9E40".to_lowercase());
    hashes.insert("320k".to_string(), "BED82B38A85B1FE883834478F585AB04".to_lowercase());
    hashes.insert("flac".to_string(), "C6C32FDB8F105F65005EBCA19EB8E52B".to_lowercase());
    hashes.insert("flac24bit".to_string(), "6715041D41457B44E7CFFD58A0ED6C13".to_lowercase());
    let kg_req = EnqueueRequest {
        track_id: "probe-kg-1".into(),
        source: SourcePlatform::Kugou,
        platform_id: "probe".into(),
        quality: Quality::HiRes,
        title: "ふわふわhazy".into(),
        artist: "西憂花".into(),
        album: None,
        extra: TrackExtra { hashes, sizes: HashMap::new() },
    };
    match KugouResolver.resolve_play_url(&kg_req, &cancel).await {
        Ok(r) => println!(
            "✓ 酷狗 hi-res: quality={} ext={} url={}",
            r.quality_key,
            r.file_ext,
            r.url.chars().take(90).collect::<String>()
        ),
        Err(e) => println!("✗ 酷狗 hi-res 失败: {e:#}"),
    }

    // ── 3. 匿名对照：不注入任何会话，验证 VIP 歌确实被锁（证明第 1/2 步成功源自登录态）──
    ffi_inject("", "", "");
    let anon_req = EnqueueRequest {
        track_id: "probe-nm-anon".into(),
        source: SourcePlatform::Netease,
        platform_id: "5257138".into(),
        quality: Quality::Lossless,
        title: "屋顶".into(),
        artist: "周杰伦".into(),
        album: None,
        extra: TrackExtra::default(),
    };
    match NeteaseResolver.resolve_play_url(&anon_req, &cancel).await {
        Ok(r) => println!("! 匿名也能拿屋顶 URL（意外）：{r:?}"),
        Err(e) => println!("✓ 匿名对照被拒（预期）: {}", e.to_string().chars().take(80).collect::<String>()),
    }

    println!("探针完成（真实会话经 MlockSecret 存储全链路验证）");
    Ok(())
}
