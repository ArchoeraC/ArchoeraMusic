//! kugou_probe.rs — 临时探针：真实调用 register_dev + v5/url，验证各音质档签名。
//! 不入库，仅用于排查酷狗高音质下载问题。
use std::collections::BTreeMap;

use archoera_downloader::crypto::kugou as kg;

const KG_SONG_URL: &str = "https://gateway.kugou.com/v5/url";
const KG_REGISTER_URL: &str = "https://userservice.kugou.com/risk/v2/r_register_dev";
const KG_ANDROID_UA: &str = "Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi";

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

fn kg_base_headers(mid: &str, ts: i64) -> reqwest::header::HeaderMap {
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
    h
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let client = reqwest::Client::new();
    let ts = now_secs();
    let guid = kg::kg_md5(&kg::kg_random_string(24));
    let mid = kg::kg_calc_mid(&guid);

    // ── 1. register_dev → 真实 dfid ──
    let secret_key = kg::kg_random_string(6).to_lowercase();
    let device = kg_device_json(&guid);
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
    params.insert("mid".into(), mid.clone());
    params.insert("uuid".into(), "-".into());
    params.insert("appid".into(), kg::KG_LITE_APPID.to_string());
    params.insert("clientver".into(), kg::KG_LITE_CLIENTVER.to_string());
    params.insert("clienttime".into(), ts.to_string());
    let signature = kg::kg_signature(&params, &cipher, kg::KG_LITE_SIGN_SALT);
    params.insert("signature".into(), signature);

    let url = format!("{KG_REGISTER_URL}?{}", kg_query_string(&params));
    let mut headers = kg_base_headers(&mid, ts);
    headers.insert(
        "Content-Type",
        reqwest::header::HeaderValue::from_static("text/plain;charset=utf-8"),
    );
    let resp = client.post(&url).headers(headers).body(cipher).send().await?;
    let bytes = resp.bytes().await?;
    use base64::Engine;
    let b64 = base64::engine::general_purpose::STANDARD.encode(&bytes);
    let text = kg::kg_aes_decrypt_string(&b64, &secret_key)?;
    println!("register_dev 解密响应: {text}");
    let body: serde_json::Value = serde_json::from_str(&text)?;
    let dfid = body
        .get("data")
        .and_then(|d| d.get("dfid"))
        .and_then(|v| v.as_str())
        .unwrap_or("-")
        .to_string();
    println!("mid={mid}\ndfid={dfid}\n");

    // ── 2. v5/url 逐档测试 ──
    // 西憂花 - ふわふわhazy（搜索拿到的真实 hash 族）
    let hashes: BTreeMap<&str, &str> = BTreeMap::from([
        ("128k", "973F5079DB5A1F97AE03F28D586C9E40"),
        ("320k", "BED82B38A85B1FE883834478F585AB04"),
        ("flac", "C6C32FDB8F105F65005EBCA19EB8E52B"),
        ("flac24bit", "6715041D41457B44E7CFFD58A0ED6C13"),
    ]);
    for (key, hash) in &hashes {
        let qp = match *key {
            "128k" => "128",
            "320k" => "320",
            "flac" => "flac",
            "flac24bit" => "high",
            _ => "320",
        };
        let ts2 = now_secs();
        let hash_lc = hash.to_lowercase();
        let mut q = kg_song_url_base();
        q.insert("dfid".into(), dfid.clone());
        q.insert("mid".into(), mid.clone());
        q.insert("uuid".into(), "-".into());
        q.insert("appid".into(), kg::KG_LITE_APPID.to_string());
        q.insert("clienttime".into(), ts2.to_string());
        q.insert("hash".into(), hash_lc.clone());
        q.insert("quality".into(), qp.to_string());
        let key_sig = kg::kg_sign_key(
            &hash_lc,
            &mid,
            0,
            kg::KG_LITE_APPID,
            kg::KG_LITE_KEY_SALT,
        );
        q.insert("key".into(), key_sig);
        let sig = kg::kg_signature(&q, "", kg::KG_LITE_SIGN_SALT);
        q.insert("signature".into(), sig);

        let url = format!("{KG_SONG_URL}?{}", kg_query_string(&q));
        let mut h = kg_base_headers(&mid, ts2);
        h.insert(
            "x-router",
            reqwest::header::HeaderValue::from_static("trackercdn.kugou.com"),
        );
        h.insert(
            "dfid",
            reqwest::header::HeaderValue::from_str(&dfid).unwrap_or_else(|_| reqwest::header::HeaderValue::from_static("-")),
        );
        let resp = client.get(&url).headers(h).send().await?;
        let status = resp.status();
        // 打印关键响应头（排查 ssa-code / 风控标识）
        for hn in ["ssa-code", "SSA-CODE", "ssa_code", "x-router"] {
            if let Some(v) = resp.headers().get(hn) {
                if let Ok(s) = v.to_str() {
                    println!("    header {hn}: {s}");
                }
            }
        }
        let body_text = resp.text().await?;
        let body: serde_json::Value = serde_json::from_str(&body_text).unwrap_or(serde_json::Value::Null);
        let code = body.get("status").and_then(|v| v.as_i64()).unwrap_or(-1);
        let first_url = body
            .get("url")
            .and_then(|v| v.as_array())
            .and_then(|a| a.first())
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        println!(
            "[{key:9}] quality={qp:5} hash={hash_lc} HTTP={status} status={code} url={}",
            if first_url.is_empty() { "(无 URL)" } else { &first_url[..first_url.len().min(80)] }
        );
        if first_url.is_empty() {
            println!("    raw: {}", &body_text[..body_text.len().min(300)]);
        }
    }

    // ── 3. 参照 KuGouMusicApi song_url.js：notSign（无 signature）+ 随机 dfid + clientver 11430 ──
    println!("\n── 参照实现（无签名 + 随机 dfid + clientver=11430）──");
    for (key, hash) in &hashes {
        let qp = match *key {
            "128k" => "128",
            "320k" => "320",
            "flac" => "flac",
            "flac24bit" => "high",
            _ => "320",
        };
        if *key == "128k" {
            continue; // 128k 已知可用，跳过
        }
        let ts2 = now_secs();
        let hash_lc = hash.to_lowercase();
        let rand_dfid = kg::kg_random_string(24);
        let mut q = BTreeMap::new();
        for (k, v) in kg_song_url_base() {
            q.insert(k, v);
        }
        q.insert("clientver".into(), "11430".into()); // 参照实现 clientver
        q.insert("dfid".into(), rand_dfid.clone());
        q.insert("mid".into(), mid.clone());
        q.insert("uuid".into(), "-".into());
        q.insert("appid".into(), kg::KG_LITE_APPID.to_string());
        q.insert("clienttime".into(), ts2.to_string());
        q.insert("hash".into(), hash_lc.clone());
        q.insert("quality".into(), qp.to_string());
        let key_sig = kg::kg_sign_key(
            &hash_lc,
            &mid,
            0,
            kg::KG_LITE_APPID,
            kg::KG_LITE_KEY_SALT,
        );
        q.insert("key".into(), key_sig);
        // 参照实现 notSign=true：不生成 signature

        let url = format!("{KG_SONG_URL}?{}", kg_query_string(&q));
        let mut h = kg_base_headers(&mid, ts2);
        h.insert(
            "x-router",
            reqwest::header::HeaderValue::from_static("trackercdn.kugou.com"),
        );
        h.insert(
            "dfid",
            reqwest::header::HeaderValue::from_str(&rand_dfid).unwrap_or_else(|_| reqwest::header::HeaderValue::from_static("-")),
        );
        let resp = client.get(&url).headers(h).send().await?;
        let body_text = resp.text().await?;
        let body: serde_json::Value = serde_json::from_str(&body_text).unwrap_or(serde_json::Value::Null);
        let code = body.get("status").and_then(|v| v.as_i64()).unwrap_or(-1);
        let first_url = body
            .get("url")
            .and_then(|v| v.as_array())
            .and_then(|a| a.first())
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        println!(
            "[{key:9}] quality={qp:5} status={code} url={}",
            if first_url.is_empty() { "(无 URL)" } else { &first_url[..first_url.len().min(80)] }
        );
        if first_url.is_empty() {
            println!("    raw: {}", &body_text[..body_text.len().min(200)]);
        }
    }

    // ── 4. 对照：卡农 (经典钢琴版) dylanf（独立音乐人，通常免费） ──
    println!("\n── 对照（卡农 经典钢琴版 dylanf，现有签名 + 真实 dfid）──");
    let free_hashes: BTreeMap<&str, &str> = BTreeMap::from([
        ("128k", "B8E17E20BDDDEFCD81B90B8A35FD7C1"),
        ("320k", "1D486CED39809DFE0EB5BB3F50F06029"),
        ("flac", "276C2999FD9FBC5C00A33638686DE1D2"),
    ]);
    for (key, hash) in &free_hashes {
        let qp = match *key {
            "128k" => "128",
            "320k" => "320",
            _ => "flac",
        };
        let ts2 = now_secs();
        let hash_lc = hash.to_lowercase();
        let mut q = kg_song_url_base();
        q.insert("dfid".into(), dfid.clone());
        q.insert("mid".into(), mid.clone());
        q.insert("uuid".into(), "-".into());
        q.insert("appid".into(), kg::KG_LITE_APPID.to_string());
        q.insert("clienttime".into(), ts2.to_string());
        q.insert("hash".into(), hash_lc.clone());
        q.insert("quality".into(), qp.to_string());
        let key_sig = kg::kg_sign_key(&hash_lc, &mid, 0, kg::KG_LITE_APPID, kg::KG_LITE_KEY_SALT);
        q.insert("key".into(), key_sig);
        let sig = kg::kg_signature(&q, "", kg::KG_LITE_SIGN_SALT);
        q.insert("signature".into(), sig);

        let url = format!("{KG_SONG_URL}?{}", kg_query_string(&q));
        let mut h = kg_base_headers(&mid, ts2);
        h.insert(
            "x-router",
            reqwest::header::HeaderValue::from_static("trackercdn.kugou.com"),
        );
        h.insert(
            "dfid",
            reqwest::header::HeaderValue::from_str(&dfid).unwrap_or_else(|_| reqwest::header::HeaderValue::from_static("-")),
        );
        let resp = client.get(&url).headers(h).send().await?;
        let body_text = resp.text().await?;
        let body: serde_json::Value = serde_json::from_str(&body_text).unwrap_or(serde_json::Value::Null);
        let code = body.get("status").and_then(|v| v.as_i64()).unwrap_or(-1);
        let first_url = body
            .get("url")
            .and_then(|v| v.as_array())
            .and_then(|a| a.first())
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let block = body.get("trans_param").and_then(|t| t.get("pay_block_tpl")).map(|v| v.to_string()).unwrap_or_default();
        println!(
            "[{key:9}] quality={qp:5} status={code} pay_block={block} url={}",
            if first_url.is_empty() { "(无 URL)" } else { &first_url[..first_url.len().min(80)] }
        );
        if first_url.is_empty() {
            println!("    raw: {}", &body_text[..body_text.len().min(400)]);
        }
    }

    // ── 5. 标准版 appid=1005：register_dev（标准盐/公钥）+ v5/url 标准签名 ──
    println!("\n── 标准版（appid=1005, clientver=20489, 标准盐/公钥）──");
    let guid2 = kg::kg_md5(&kg::kg_random_string(24));
    let mid2 = kg::kg_calc_mid(&guid2);
    let secret2 = kg::kg_random_string(6).to_lowercase();
    let device2 = kg_device_json(&guid2);
    let cipher2 = kg::kg_aes_encrypt_base64(&device2.to_string(), &secret2);
    let p2 = kg::kg_rsa_pkcs1_encrypt_hex(
        &format!(r#"{{"aes":"{secret2}","uid":0,"token":""}}"#),
        kg::KG_PUBLIC_KEY_PEM,
    );
    let mut rp = BTreeMap::new();
    rp.insert("part".into(), "1".into());
    rp.insert("platid".into(), "1".into());
    rp.insert("p".into(), p2);
    rp.insert("dfid".into(), "-".into());
    rp.insert("mid".into(), mid2.clone());
    rp.insert("uuid".into(), "-".into());
    rp.insert("appid".into(), "1005".into());
    rp.insert("clientver".into(), "20489".into());
    rp.insert("clienttime".into(), now_secs().to_string());
    let sig2 = kg::kg_signature(&rp, &cipher2, kg::KG_SIGN_SALT);
    rp.insert("signature".into(), sig2);
    let rurl = format!("{KG_REGISTER_URL}?{}", kg_query_string(&rp));
    let mut rh = kg_base_headers(&mid2, now_secs());
    rh.insert("Content-Type", reqwest::header::HeaderValue::from_static("text/plain;charset=utf-8"));
    let rresp = client.post(&rurl).headers(rh).body(cipher2).send().await?;
    let rbytes = rresp.bytes().await?;
    let rb64 = base64::engine::general_purpose::STANDARD.encode(&rbytes);
    let rtext = kg::kg_aes_decrypt_string(&rb64, &secret2)?;
    let rbody: serde_json::Value = serde_json::from_str(&rtext)?;
    let dfid2 = rbody
        .get("data").and_then(|d| d.get("dfid")).and_then(|v| v.as_str()).unwrap_or("-").to_string();
    println!("std register: status={} dfid={dfid2} text={}", rbody.get("status").map(|v| v.to_string()).unwrap_or_default(), &rtext[..rtext.len().min(120)]);

    for (key, hash) in [("320k", "BED82B38A85B1FE883834478F585AB04"), ("flac", "C6C32FDB8F105F65005EBCA19EB8E52B")] {
        let qp = if key == "320k" { "320" } else { "flac" };
        let ts3 = now_secs();
        let hash_lc = hash.to_lowercase();
        let mut q = kg_song_url_base();
        q.insert("dfid".into(), dfid2.clone());
        q.insert("mid".into(), mid2.clone());
        q.insert("uuid".into(), "-".into());
        q.insert("appid".into(), "1005".into());
        q.insert("clienttime".into(), ts3.to_string());
        q.insert("clientver".into(), "20489".into());
        q.insert("hash".into(), hash_lc.clone());
        q.insert("quality".into(), qp.to_string());
        let key_sig = kg::kg_sign_key(&hash_lc, &mid2, 0, 1005, kg::KG_KEY_SALT);
        q.insert("key".into(), key_sig);
        let sig3 = kg::kg_signature(&q, "", kg::KG_SIGN_SALT);
        q.insert("signature".into(), sig3);
        let url = format!("{KG_SONG_URL}?{}", kg_query_string(&q));
        let mut h = kg_base_headers(&mid2, ts3);
        h.insert("x-router", reqwest::header::HeaderValue::from_static("trackercdn.kugou.com"));
        h.insert("dfid", reqwest::header::HeaderValue::from_str(&dfid2).unwrap_or_else(|_| reqwest::header::HeaderValue::from_static("-")));
        let resp = client.get(&url).headers(h).send().await?;
        let body_text = resp.text().await?;
        let body: serde_json::Value = serde_json::from_str(&body_text).unwrap_or(serde_json::Value::Null);
        let code = body.get("status").and_then(|v| v.as_i64()).unwrap_or(-1);
        let first_url = body.get("url").and_then(|v| v.as_array()).and_then(|a| a.first()).and_then(|v| v.as_str()).unwrap_or("").to_string();
        println!("[std {key:9}] quality={qp:5} status={code} url={}", if first_url.is_empty() { "(无 URL)" } else { &first_url[..first_url.len().min(80)] });
        if first_url.is_empty() {
            println!("    raw: {}", &body_text[..body_text.len().min(220)]);
        }
    }
    Ok(())
}
