// ============================================================
// §9.6 第 1 层防御：平台业务签名算法自研（对照 Dart 现有实现 1:1 移植）
// 自研边界（戒律 §9.6 自研边界表）：
//   ✅ 业务级签名（kgMd5/kgCalcMid/kgAes/.../weapi params/encSecKey）→ 自研
//   ❌ 原语级（AES-CBC/MD5/RSA/PKCS7/BigInt）→ aes/cbc/md-5/rsa/num-bigint crate
//
// 对拍基准：tool/gen_crypto_vectors.dart（Dart 真实实现输出）→
//   tests/crypto_roundtrip.rs 硬编码为期望值（字节级一致）。
// 注意：RSA-PKCS1v1.5 输出带随机填充，无法跨语言逐字节对拍，
//   测试只验证结构（长度/可解密/格式）；确定性函数（md5/calcMid/aes/
//   signature/signKey/rawRsa）必须逐字符一致。
// ============================================================

use aes::Aes128;
use cbc::cipher::{block_padding::Pkcs7, BlockDecryptMut, BlockEncryptMut, KeyIvInit};
use cbc::{Decryptor, Encryptor};
use md5::{Digest, Md5};
use rsa::pkcs8::DecodePublicKey;
use rsa::traits::PublicKeyParts;
use rsa::{BigUint, Pkcs1v15Encrypt, RsaPublicKey};

type Aes128CbcEnc = Encryptor<Aes128>;
type Aes128CbcDec = Decryptor<Aes128>;

fn b64_encode(bytes: &[u8]) -> String {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

fn b64_decode(s: &str) -> Result<Vec<u8>, base64::DecodeError> {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.decode(s)
}

/// AES-128-CBC + PKCS7 padding → base64
fn aes_cbc_encrypt_base64(plain: &[u8], key: &[u8], iv: &[u8]) -> String {
    let cipher = Aes128CbcEnc::new_from_slices(key, iv).expect("key/iv 长度必须为 16");
    b64_encode(&cipher.encrypt_padded_vec_mut::<Pkcs7>(plain))
}

/// AES-128-CBC + PKCS7 padding 解密
fn aes_cbc_decrypt_string(cipher_b64: &str, key: &[u8], iv: &[u8]) -> Result<String, anyhow::Error> {
    let cipher = Aes128CbcDec::new_from_slices(key, iv).expect("key/iv 长度必须为 16");
    let bytes = b64_decode(cipher_b64)?;
    let dec = cipher
        .decrypt_padded_vec_mut::<Pkcs7>(&bytes)
        .map_err(|e| anyhow::anyhow!("AES 解密失败: {e:?}"))?;
    Ok(String::from_utf8_lossy(&dec).into_owned())
}

pub mod kugou {
    // ============================================================
    // Kugou 签名函数（对照 Dart kugou_crypto.dart 1:1 移植）
    // 签名盐值 / PEM / appid 常量与 Dart 文件逐字符一致
    // ============================================================

    use super::*;
    use std::collections::BTreeMap;

    /// android 签名盐值（signatureAndroidParams 标准版）
    pub const KG_SIGN_SALT: &str = "OIlwieks28dk2k092lksi2UIkp";
    /// /v5/url 的 key 签名盐值（signKey 标准版）
    pub const KG_KEY_SALT: &str = "57ae12eb6890223e355ccfcb74edf70d";
    /// android 签名盐值（signatureAndroidParams 概念版 lite）
    pub const KG_LITE_SIGN_SALT: &str = "LnT6xpN3khm36zse0QzvmgTZ3waWdRSA";
    /// /v5/url 的 key 签名盐值（signKey 概念版 lite）
    pub const KG_LITE_KEY_SALT: &str = "185672dd44712f60bb1736df5a377e82";
    /// 概念版 lite 的 appid / clientver（MoeKoeMusic --platform=lite）
    pub const KG_LITE_APPID: i64 = 3116;
    pub const KG_LITE_CLIENTVER: i64 = 11440;
    /// 来源 appid（扫码登录必需，KuGouMusicApi config.json srcappid=2919）
    pub const KG_SRC_APPID: i64 = 2919;
    /// web 版签名盐值（signatureWebParams，扫码登录等 web 接口）
    pub const KG_WEB_SIGN_SALT: &str = "NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt";

    /// register_dev RSA 公钥（标准版，1024bit，SPKI PEM；base64 每行 64 字符）
    pub const KG_PUBLIC_KEY_PEM: &str = "-----BEGIN PUBLIC KEY-----\nMIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDIAG7QOELSYoIJvTFJhMpe1s/g\nbjDJX51HBNnEl5HXqTW6lQ7LC8jr9fWZTwusknp+sVGzwd40MwP6U5yDE27M/X1+\nUR4tvOGOqp94TJtQ1EPnWGWXngpeIW5GxoQGao1rmYWAu6oi1z9XkChrsUdC6DJE\n5E221wf/4WLFxwAtRQIDAQAB\n-----END PUBLIC KEY-----";

    /// register_dev RSA 公钥（概念版 lite，1024bit，SPKI PEM；base64 每行 64 字符）
    pub const KG_LITE_PUBLIC_KEY_PEM: &str = "-----BEGIN PUBLIC KEY-----\nMIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDECi0Np2UR87scwrvTr72L6oO0\n1rBbbBPriSDFPxr3Z5syug0O24QyQO8bg27+0+4kBzTBTBOZ/WWU0WryL1JSXRTX\nLgFVxtzIY41Pe7lPOgsfTCn5kZcvKhYKJesKnnJDNr5/abvTGf+rHG3YRwsCHcQ0\n8/q6ifSioBszvb3QiwIDAQAB\n-----END PUBLIC KEY-----";

    /// 随机字符串字符池（1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ）
    const KG_POOL: &[u8] = b"1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ";

    /// 生成随机字符串（dfid 24 位、device uuid 等），对齐 Dart kgRandomString
    pub fn kg_random_string(len: usize) -> String {
        use rand::Rng;
        let mut rng = rand::thread_rng();
        (0..len)
            .map(|_| KG_POOL[rng.gen_range(0..KG_POOL.len())] as char)
            .collect()
    }

    /// MD5 hex（小写），对齐 Dart kgMd5
    pub fn kg_md5(data: &str) -> String {
        hex::encode(Md5::digest(data.as_bytes()))
    }

    /// 计算设备 MID：md5(guid) hex 视作 16 进制大整数 → 十进制字符串
    /// 对齐 Dart kgCalcMid（KuGouMusicApi util.calculateMid）
    pub fn kg_calc_mid(guid: &str) -> String {
        let hex = kg_md5(guid);
        BigUint::parse_bytes(hex.as_bytes(), 16)
            .expect("md5 hex 合法")
            .to_string()
    }

    /// 由 secretKey 派生 (key, iv)：md5 后各取 16 字符（ASCII 字节）。
    /// 对齐 Dart kgAesKeyIv（playlistAes 系列）。
    pub fn kg_aes_key_iv(secret_key: &str) -> (String, String) {
        let digest = kg_md5(secret_key);
        (digest[0..16].to_string(), digest[16..32].to_string())
    }

    /// AES-128-CBC 加密：key = md5(secretKey) 前 16 字符，iv = 后 16 字符，
    /// 返回 base64 密文。对齐 Dart kgAesEncryptBase64。
    pub fn kg_aes_encrypt_base64(plain: &str, secret_key: &str) -> String {
        let (key, iv) = kg_aes_key_iv(secret_key);
        aes_cbc_encrypt_base64(plain.as_bytes(), key.as_bytes(), iv.as_bytes())
    }

    /// AES-128-CBC 解密 → utf8 文本。对齐 Dart kgAesDecryptString。
    pub fn kg_aes_decrypt_string(cipher_b64: &str, secret_key: &str) -> Result<String, anyhow::Error> {
        let (key, iv) = kg_aes_key_iv(secret_key);
        aes_cbc_decrypt_string(cipher_b64, key.as_bytes(), iv.as_bytes())
    }

    /// 解析 SPKI PEM 提取 RSA (n, e)
    fn parse_rsa_key(pem: &str) -> anyhow::Result<(BigUint, BigUint)> {
        let key = RsaPublicKey::from_public_key_pem(pem)?;
        Ok((key.n().clone(), key.e().clone()))
    }

    /// RSA-PKCS1v1.5 加密 → 小写 hex。对齐 Dart kgRsaPkcs1EncryptHex
    /// （node-forge 默认 padding；注意输出带随机填充，不可逐字节对拍）。
    pub fn kg_rsa_pkcs1_encrypt_hex(json_str: &str, public_key_pem: &str) -> String {
        use rand::rngs::OsRng;
        let key = RsaPublicKey::from_public_key_pem(public_key_pem)
            .expect("SPKI PEM 解析失败");
        let enc = key
            .encrypt(&mut OsRng, Pkcs1v15Encrypt, json_str.as_bytes())
            .expect("RSA PKCS1v1.5 加密失败");
        hex::encode(enc)
    }

    /// raw RSA 加密（零填充）→ 大写 hex，数据左对齐补 0 到模长 128 字节。
    /// 对齐 Dart kgRsaRawEncryptHex（cryptoRSAEncrypt + rsaRawEncrypt，
    /// user_detail/get_my_info 用，勿与 PKCS1 混用）。
    pub fn kg_rsa_raw_encrypt_hex(json_str: &str, public_key_pem: &str) -> String {
        let (n, e) = parse_rsa_key(public_key_pem).expect("SPKI PEM 解析失败");
        let data = json_str.as_bytes();
        let mut padded = vec![0u8; 128];
        padded[..data.len()].copy_from_slice(data);
        let m = BigUint::from_bytes_be(&padded);
        let c = m.modpow(&e, &n);
        format!("{:0>256}", c.to_str_radix(16)).to_uppercase()
    }

    /// android 签名：md5(salt + 排序 key=value 串 + data + salt)。
    /// [params] 为按 key 排序的 BTreeMap（值已字符串化），[data] 为 POST body
    /// （register_dev 传 AES 密文；GET 为空），[salt] 默认标准版，可传 lite。
    /// 对齐 Dart kgSignature。
    pub fn kg_signature(params: &BTreeMap<String, String>, data: &str, salt: &str) -> String {
        let mut buf = String::new();
        for (k, v) in params {
            buf.push_str(k);
            buf.push('=');
            buf.push_str(v);
        }
        kg_md5(&format!("{salt}{buf}{data}{salt}"))
    }

    /// /v5/url 的 key 参数：md5(hash + keySalt + appid + mid + userid)。
    /// 对齐 Dart kgSignKey（注意拼接顺序 hash+salt+appid+mid+userid）。
    pub fn kg_sign_key(hash: &str, mid: &str, userid: i64, appid: i64, salt: &str) -> String {
        kg_md5(&format!("{hash}{salt}{appid}{mid}{userid}"))
    }

    /// web 签名：md5(salt + 排序 key=value 串 + salt)。
    /// 对齐 Dart kgSignatureWeb（扫码登录等 web 接口，不含 body data）。
    pub fn kg_signature_web(params: &BTreeMap<String, String>) -> String {
        let mut buf = String::new();
        for (k, v) in params {
            buf.push_str(k);
            buf.push('=');
            buf.push_str(v);
        }
        kg_md5(&format!("{}{}{}", KG_WEB_SIGN_SALT, buf, KG_WEB_SIGN_SALT))
    }

    /// 参数密钥签名（signParamsKey）：md5(appid + 盐 + clientver + data)。
    /// 对齐 Dart kgSignParamsKey（top_playlist / artist_audios 等模块）。
    pub fn kg_sign_params_key(
        data: &str,
        appid: i64,
        clientver: i64,
        salt: &str,
    ) -> String {
        kg_md5(&format!("{appid}{salt}{clientver}{data}"))
    }
}

pub mod netease {
    // ============================================================
    // Netease weapi 签名（对照 Dart netease/crypto.dart 1:1 移植）
    // 常量与 Dart apis/netease/core/config.dart 逐字符一致
    // ============================================================

    use super::*;

    /// AES-CBC 初始向量
    pub const NM_IV: &str = "0102030405060708";
    /// weapi 第一层 AES 预设密钥
    pub const NM_PRESET_KEY: &str = "0CoJUm6Qyw8W8jud";
    /// linuxapi AES 密钥
    pub const NM_LINUX_API_KEY: &str = "rFgB&h#%2?^eDg:Q";
    /// eapi AES 密钥
    pub const NM_EAPI_KEY: &str = "e82ckenh8dichen8";
    /// weapi 随机 secretKey 字符集
    pub const NM_BASE62: &str = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    /// weapi RSA 公钥（1024bit，SPKI PEM；base64 每行 64 字符）
    pub const NM_PUBLIC_KEY: &str = "-----BEGIN PUBLIC KEY-----\nMIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDgtQn2JZ34ZC28NWYpAUd98iZ3\n7BUrX/aKzmFbt7clFSs6sXqHauqKWqdtLkF2KexO40H1YTX8z2lSgBBOAxLsvakl\nV8k4cBFK9snQXE9/DDaFt6Rr7iVZMldczhC0JNgTz+SHXT6CBHuX3e9SdB1Ua44o\nncaTWz7OBGLbCiK45wIDAQAB\n-----END PUBLIC KEY-----";

    /// 生成 16 字节随机字符串（base62），对齐 Dart nmWeapi 内 secretKey
    pub fn create_secret_key() -> String {
        use rand::Rng;
        let mut rng = rand::thread_rng();
        let pool = NM_BASE62.as_bytes();
        (0..16)
            .map(|_| pool[rng.gen_range(0..pool.len())] as char)
            .collect()
    }

    /// AES-128-CBC 加密 → base64（key/iv 均为 16 字节字符串 UTF-8）
    pub fn nm_aes_cbc_base64(text: &str, key: &str) -> String {
        aes_cbc_encrypt_base64(text.as_bytes(), key.as_bytes(), NM_IV.as_bytes())
    }

    /// RSA 裸加密：明文右侧对齐补 0 到 128 字节（对齐 node RSA_NO_PADDING），
    /// 整体模幂，输出 256 位小写 hex。对齐 Dart nmRsaEncrypt。
    pub fn nm_rsa_encrypt(str: &str) -> String {
        let key = RsaPublicKey::from_public_key_pem(NM_PUBLIC_KEY).expect("SPKI PEM 解析失败");
        let (n, e) = (key.n().clone(), key.e().clone());
        let data = str.as_bytes();
        let mut padded = vec![0u8; 128];
        padded[128 - data.len()..].copy_from_slice(data);
        let m = BigUint::from_bytes_be(&padded);
        let c = m.modpow(&e, &n);
        format!("{:0>256}", c.to_str_radix(16))
    }

    /// weapi 加密（secretKey 随机）→ (params: base64, encSecKey: hex)。
    /// 对齐 Dart nmWeapi：双次 AES-CBC + RSA(反转 secretKey)。
    pub fn weapi_encrypt(json_object: &serde_json::Value) -> (String, String) {
        let secret_key = create_secret_key();
        weapi_encrypt_with_secret(json_object, &secret_key)
    }

    /// weapi 加密（secretKey 固定，供字节级对拍单测使用）
    pub fn weapi_encrypt_with_secret(
        json_object: &serde_json::Value,
        secret_key: &str,
    ) -> (String, String) {
        let text = json_object.to_string();
        let first = nm_aes_cbc_base64(&text, NM_PRESET_KEY);
        let params = nm_aes_cbc_base64(&first, secret_key);
        let reversed: String = secret_key.chars().rev().collect();
        let enc_sec_key = nm_rsa_encrypt(&reversed);
        (params, enc_sec_key)
    }
}
