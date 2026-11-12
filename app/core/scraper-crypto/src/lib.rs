// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! 刮削器的纯 Rust 加密后端（替换 C++ 侧对 `OpenSSL::Crypto` 的链接）。
//!
//! 只覆盖 `app/core/scraper` 实际用到的窄接口：
//! - AES-128-ECB / AES-128-CBC + PKCS7 填充（网易云 linuxapi / weapi）；
//! - RSA 裸模幂（网易云固定 modulus/exponent，不做密钥解析）；
//! - 随机字节（临时密钥 / UUID）；
//! - MD5 / SHA1 一次性摘要（酷狗签名、酷我 Cross、本地文件 id）。
//!
//! 所有导出函数走 C ABI（`era_crypto_*`），成功返回 [`ERA_CRYPTO_OK`]，失败返回
//! 负值。输出缓冲区由调用方提供；容量不足时返回 [`ERA_CRYPTO_ERR_BUFFER`] 并
//! 不写入部分数据。这样 scraper 不再依赖系统 `libcrypto.so.*`，发行版升级
//! OpenSSL soname 也不会影响运行。
//!
//! 纯 Rust 依赖：`aes` / `md-5` / `sha1` / `num-bigint` / `getrandom`，均为
//! MIT 或 Apache-2.0 双许可，可静态合并进 AGPL-3.0 产物。

use core::ffi::{c_char, c_int};
use core::ptr;
use std::slice;

mod http;

use aes::cipher::generic_array::GenericArray;
use aes::cipher::{BlockEncrypt, KeyInit};
use aes::Aes128;
use md5::Md5;
use num_bigint::BigUint;
use sha1::{Digest, Sha1};

/// 成功。
pub const ERA_CRYPTO_OK: c_int = 0;
/// 参数非法（空指针 / 密钥长度错误 / 非法 hex）。
pub const ERA_CRYPTO_ERR_INVALID: c_int = -1;
/// 输出缓冲区不足。
pub const ERA_CRYPTO_ERR_BUFFER: c_int = -2;
/// 系统随机源不可用。
pub const ERA_CRYPTO_ERR_RNG: c_int = -3;

const AES_BLOCK: usize = 16;
const AES_KEY_LEN: usize = 16;

// ============================================================================
// 纯函数实现（便于单元测试）
// ============================================================================

/// PKCS7 填充：`len % 16 == 0` 时追加完整 16 字节块。
fn pkcs7_pad(input: &[u8]) -> Vec<u8> {
    let pad = AES_BLOCK - input.len() % AES_BLOCK;
    let mut out = Vec::with_capacity(input.len() + pad);
    out.extend_from_slice(input);
    out.resize(input.len() + pad, pad as u8);
    out
}

/// AES-128-ECB 加密 + PKCS7 填充（无 IV）。
fn aes128_ecb_pkcs7(key: &[u8], input: &[u8]) -> Option<Vec<u8>> {
    if key.len() != AES_KEY_LEN {
        return None;
    }
    let cipher = Aes128::new(GenericArray::from_slice(key));
    let mut out = pkcs7_pad(input);
    for chunk in out.chunks_exact_mut(AES_BLOCK) {
        cipher.encrypt_block(GenericArray::from_mut_slice(chunk));
    }
    Some(out)
}

/// AES-128-CBC 加密 + PKCS7 填充。
fn aes128_cbc_pkcs7(key: &[u8], iv: &[u8], input: &[u8]) -> Option<Vec<u8>> {
    if key.len() != AES_KEY_LEN || iv.len() != AES_BLOCK {
        return None;
    }
    let cipher = Aes128::new(GenericArray::from_slice(key));
    let mut out = pkcs7_pad(input);
    let mut prev = [0u8; AES_BLOCK];
    prev.copy_from_slice(iv);
    for chunk in out.chunks_exact_mut(AES_BLOCK) {
        for (byte, chain) in chunk.iter_mut().zip(prev.iter()) {
            *byte ^= *chain;
        }
        cipher.encrypt_block(GenericArray::from_mut_slice(chunk));
        prev.copy_from_slice(chunk);
    }
    Some(out)
}

/// RSA 裸模幂，返回**小写、无前导零**的十六进制（与 `BN_bn2hex` 的上限对齐；
/// 定长补零由调用方负责，以保持与旧输出逐字节一致）。
fn rsa_modpow_hex(input_hex: &str, exponent_hex: &str, modulus_hex: &str) -> Option<String> {
    let base = BigUint::parse_bytes(input_hex.as_bytes(), 16)?;
    let exponent = BigUint::parse_bytes(exponent_hex.as_bytes(), 16)?;
    let modulus = BigUint::parse_bytes(modulus_hex.as_bytes(), 16)?;
    if modulus.bits() == 0 {
        return None;
    }
    Some(base.modpow(&exponent, &modulus).to_str_radix(16))
}

fn md5_digest(input: &[u8]) -> [u8; 16] {
    let digest = Md5::digest(input);
    let mut out = [0u8; 16];
    out.copy_from_slice(&digest);
    out
}

fn sha1_digest(input: &[u8]) -> [u8; 20] {
    let digest = Sha1::digest(input);
    let mut out = [0u8; 20];
    out.copy_from_slice(&digest);
    out
}

// ============================================================================
// C ABI
// ============================================================================

/// 把字节写入调用方缓冲区；容量不足时不产生部分写入。
unsafe fn write_bytes(
    data: &[u8],
    output: *mut u8,
    output_cap: usize,
    output_len: *mut usize,
) -> c_int {
    if output_len.is_null() {
        return ERA_CRYPTO_ERR_INVALID;
    }
    *output_len = 0;
    if data.len() > output_cap || (!data.is_empty() && output.is_null()) {
        return ERA_CRYPTO_ERR_BUFFER;
    }
    if !data.is_empty() {
        ptr::copy_nonoverlapping(data.as_ptr(), output, data.len());
    }
    *output_len = data.len();
    ERA_CRYPTO_OK
}

/// `ptr + len` → 切片；`len == 0` 允许空指针。
unsafe fn input_slice<'a>(ptr_in: *const u8, len: usize) -> Option<&'a [u8]> {
    if len == 0 {
        Some(&[])
    } else if ptr_in.is_null() {
        None
    } else {
        Some(slice::from_raw_parts(ptr_in, len))
    }
}

/// AES-128-ECB + PKCS7：输出长度 = `input_len + pad`（16..=31 字节填充）。
///
/// # Safety
/// `key` 必须指向 16 字节；`input`/`output` 的可用长度由参数声明。
#[no_mangle]
pub unsafe extern "C" fn era_crypto_aes128_ecb_pkcs7(
    key: *const u8,
    input: *const u8,
    input_len: usize,
    output: *mut u8,
    output_cap: usize,
    output_len: *mut usize,
) -> c_int {
    let key = match input_slice(key, AES_KEY_LEN) {
        Some(key) => key,
        None => return ERA_CRYPTO_ERR_INVALID,
    };
    let input = match input_slice(input, input_len) {
        Some(input) => input,
        None => return ERA_CRYPTO_ERR_INVALID,
    };
    match aes128_ecb_pkcs7(key, input) {
        Some(data) => write_bytes(&data, output, output_cap, output_len),
        None => ERA_CRYPTO_ERR_INVALID,
    }
}

/// AES-128-CBC + PKCS7（`iv` 固定 16 字节）。
///
/// # Safety
/// `key` / `iv` 必须各指向 16 字节；`input`/`output` 的可用长度由参数声明。
#[no_mangle]
pub unsafe extern "C" fn era_crypto_aes128_cbc_pkcs7(
    key: *const u8,
    iv: *const u8,
    input: *const u8,
    input_len: usize,
    output: *mut u8,
    output_cap: usize,
    output_len: *mut usize,
) -> c_int {
    let key = match input_slice(key, AES_KEY_LEN) {
        Some(key) => key,
        None => return ERA_CRYPTO_ERR_INVALID,
    };
    let iv = match input_slice(iv, AES_BLOCK) {
        Some(iv) => iv,
        None => return ERA_CRYPTO_ERR_INVALID,
    };
    let input = match input_slice(input, input_len) {
        Some(input) => input,
        None => return ERA_CRYPTO_ERR_INVALID,
    };
    match aes128_cbc_pkcs7(key, iv, input) {
        Some(data) => write_bytes(&data, output, output_cap, output_len),
        None => ERA_CRYPTO_ERR_INVALID,
    }
}

/// RSA 裸模幂：`input^exponent mod modulus`，输出小写 hex 字符串（NUL 结尾）。
///
/// # Safety
/// 三个入参为 NUL 结尾的 ASCII hex；`output` 至少 `output_cap` 字节。
#[no_mangle]
pub unsafe extern "C" fn era_crypto_rsa_modpow_hex(
    input_hex: *const c_char,
    exponent_hex: *const c_char,
    modulus_hex: *const c_char,
    output: *mut c_char,
    output_cap: usize,
    output_len: *mut usize,
) -> c_int {
    if input_hex.is_null() || exponent_hex.is_null() || modulus_hex.is_null() {
        return ERA_CRYPTO_ERR_INVALID;
    }
    let read = |p: *const c_char| match std::ffi::CStr::from_ptr(p).to_str() {
        Ok(s) => Some(s),
        Err(_) => None,
    };
    let (input, exponent, modulus) = match (read(input_hex), read(exponent_hex), read(modulus_hex))
    {
        (Some(a), Some(b), Some(c)) => (a, b, c),
        _ => return ERA_CRYPTO_ERR_INVALID,
    };
    let hex = match rsa_modpow_hex(input, exponent, modulus) {
        Some(hex) => hex,
        None => return ERA_CRYPTO_ERR_INVALID,
    };
    if output_len.is_null() {
        return ERA_CRYPTO_ERR_INVALID;
    }
    *output_len = 0;
    // 需要容纳 hex + NUL。
    if hex.len() + 1 > output_cap || output.is_null() {
        return ERA_CRYPTO_ERR_BUFFER;
    }
    ptr::copy_nonoverlapping(hex.as_ptr(), output as *mut u8, hex.len());
    *output.add(hex.len()) = 0;
    *output_len = hex.len();
    ERA_CRYPTO_OK
}

/// 填充调用方缓冲区为系统随机字节。
///
/// # Safety
/// `output` 必须至少有 `len` 字节可写。
#[no_mangle]
pub unsafe extern "C" fn era_crypto_random(output: *mut u8, len: usize) -> c_int {
    if len == 0 {
        return ERA_CRYPTO_OK;
    }
    if output.is_null() {
        return ERA_CRYPTO_ERR_INVALID;
    }
    match getrandom::getrandom(slice::from_raw_parts_mut(output, len)) {
        Ok(()) => ERA_CRYPTO_OK,
        Err(_) => ERA_CRYPTO_ERR_RNG,
    }
}

/// MD5 一次性摘要（16 字节）。
///
/// # Safety
/// `output` 必须至少有 16 字节可写。
#[no_mangle]
pub unsafe extern "C" fn era_crypto_md5(input: *const u8, input_len: usize, output: *mut u8) -> c_int {
    if output.is_null() {
        return ERA_CRYPTO_ERR_INVALID;
    }
    let input = match input_slice(input, input_len) {
        Some(input) => input,
        None => return ERA_CRYPTO_ERR_INVALID,
    };
    ptr::copy_nonoverlapping(md5_digest(input).as_ptr(), output, 16);
    ERA_CRYPTO_OK
}

/// SHA1 一次性摘要（20 字节）。
///
/// # Safety
/// `output` 必须至少有 20 字节可写。
#[no_mangle]
pub unsafe extern "C" fn era_crypto_sha1(
    input: *const u8,
    input_len: usize,
    output: *mut u8,
) -> c_int {
    if output.is_null() {
        return ERA_CRYPTO_ERR_INVALID;
    }
    let input = match input_slice(input, input_len) {
        Some(input) => input,
        None => return ERA_CRYPTO_ERR_INVALID,
    };
    ptr::copy_nonoverlapping(sha1_digest(input).as_ptr(), output, 20);
    ERA_CRYPTO_OK
}

// ============================================================================
// 单元测试
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    fn unhex(s: &str) -> Vec<u8> {
        (0..s.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
            .collect()
    }

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    }

    #[test]
    fn pkcs7_padding_matches_block_semantics() {
        // 不足一块补到 16；正好整块补完整一块。
        assert_eq!(pkcs7_pad(&[0u8; 0]).len(), 16);
        assert_eq!(pkcs7_pad(&[0u8; 15]).len(), 16);
        assert_eq!(pkcs7_pad(&[0u8; 16]).len(), 32);
        assert_eq!(*pkcs7_pad(&[0u8; 15]).last().unwrap(), 1);
        assert_eq!(*pkcs7_pad(&[0u8; 16]).last().unwrap(), 16);
    }

    #[test]
    fn aes128_ecb_matches_nist_vector() {
        // NIST SP 800-38A F.1.1（无填充的单块向量）：直接验证块加密本身。
        let key = unhex("000102030405060708090a0b0c0d0e0f");
        let plain = unhex("00112233445566778899aabbccddeeff");
        let cipher = Aes128::new(GenericArray::from_slice(&key));
        let mut block = GenericArray::clone_from_slice(&plain);
        cipher.encrypt_block(&mut block);
        assert_eq!(hex(&block), "69c4e0d86a7b0430d8cdb78070b4c55a");
    }

    #[test]
    fn aes128_ecb_pkcs7_prefix_is_vector_block() {
        let key = unhex("000102030405060708090a0b0c0d0e0f");
        let plain = unhex("00112233445566778899aabbccddeeff");
        let out = aes128_ecb_pkcs7(&key, &plain).unwrap();
        assert_eq!(out.len(), 32);
        assert_eq!(&hex(&out[..16]), "69c4e0d86a7b0430d8cdb78070b4c55a");
        // 第二个块是 16 字节的 0x10 填充再加密，只验证长度与可重复性。
        assert_eq!(out, aes128_ecb_pkcs7(&key, &plain).unwrap());
    }

    #[test]
    fn aes128_cbc_matches_nist_vector() {
        // NIST SP 800-38A F.2.1 第一块。
        let key = unhex("2b7e151628aed2a6abf7158809cf4f3c");
        let iv = unhex("000102030405060708090a0b0c0d0e0f");
        let plain = unhex("6bc1bee22e409f96e93d7e117393172a");
        let out = aes128_cbc_pkcs7(&key, &iv, &plain).unwrap();
        assert_eq!(&hex(&out[..16]), "7649abac8119b246cee98e9b12e9197d");
        assert_eq!(out.len(), 32);
    }

    #[test]
    fn rsa_modpow_matches_reference() {
        // 4^13 mod 497 = 445（经典示例）。
        assert_eq!(
            rsa_modpow_hex("04", "0d", "01f1").unwrap(),
            "1bd"
        );
        // 指数 0 → 1。
        assert_eq!(rsa_modpow_hex("04", "00", "01f1").unwrap(), "1");
        // 模数为 0 → 拒绝。
        assert!(rsa_modpow_hex("04", "0d", "00").is_none());
        // 非法 hex → 拒绝。
        assert!(rsa_modpow_hex("zz", "0d", "01f1").is_none());
    }

    #[test]
    fn digests_match_known_vectors() {
        assert_eq!(hex(&md5_digest(b"abc")), "900150983cd24fb0d6963f7d28e17f72");
        assert_eq!(
            hex(&sha1_digest(b"abc")),
            "a9993e364706816aba3e25717850c26c9cd0d89d"
        );
    }

    #[test]
    fn ffi_aes_ecb_roundtrip_and_buffer_guard() {
        let key = b"0123456789abcdef";
        let plain = b"hello scraper"; // 13 字节 → 补到 16
        let mut out = [0u8; 16];
        let mut out_len = 0usize;
        let rc = unsafe {
            era_crypto_aes128_ecb_pkcs7(
                key.as_ptr(),
                plain.as_ptr(),
                plain.len(),
                out.as_mut_ptr(),
                out.len(),
                &mut out_len,
            )
        };
        assert_eq!(rc, ERA_CRYPTO_OK);
        assert_eq!(out_len, 16);
        // 容量不足：不写部分数据，out_len 归零。
        let mut small = [0u8; 8];
        let mut small_len = 99usize;
        let rc = unsafe {
            era_crypto_aes128_ecb_pkcs7(
                key.as_ptr(),
                plain.as_ptr(),
                plain.len(),
                small.as_mut_ptr(),
                small.len(),
                &mut small_len,
            )
        };
        assert_eq!(rc, ERA_CRYPTO_ERR_BUFFER);
        assert_eq!(small_len, 0);
        assert_eq!(small, [0u8; 8]);
    }

    #[test]
    fn ffi_digest_and_random() {
        let mut digest = [0u8; 16];
        let rc = unsafe { era_crypto_md5(b"abc".as_ptr(), 3, digest.as_mut_ptr()) };
        assert_eq!(rc, ERA_CRYPTO_OK);
        assert_eq!(hex(&digest), "900150983cd24fb0d6963f7d28e17f72");

        let mut random = [0u8; 32];
        let rc = unsafe { era_crypto_random(random.as_mut_ptr(), random.len()) };
        assert_eq!(rc, ERA_CRYPTO_OK);
        assert_ne!(random, [0u8; 32]);
    }

    #[test]
    fn ffi_rsa_buffer_guard() {
        let input = std::ffi::CString::new("04").unwrap();
        let exp = std::ffi::CString::new("0d").unwrap();
        let modulus = std::ffi::CString::new("01f1").unwrap();
        let mut out = [0i8; 4];
        let mut out_len = 0usize;
        let rc = unsafe {
            era_crypto_rsa_modpow_hex(
                input.as_ptr(),
                exp.as_ptr(),
                modulus.as_ptr(),
                out.as_mut_ptr(),
                out.len(),
                &mut out_len,
            )
        };
        assert_eq!(rc, ERA_CRYPTO_OK);
        assert_eq!(out_len, 3);
        let text: String = out[..3].iter().map(|c| *c as u8 as char).collect();
        assert_eq!(text, "1bd");
    }
}
