// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

#pragma once

/// ArchoeraMusic 刮削器加密后端（Rust staticlib，C ABI）。
///
/// 历史实现直接链接系统 `OpenSSL::Crypto`；发行版升级 OpenSSL soname
/// （如 Arch 的 `libcrypto.so.3` → `.so.4`）会让已发布二进制无法加载。这里把
/// 刮削器实际用到的窄接口收敛到纯 Rust 静态库（`app/core/scraper-crypto`），
/// 静态合并进 `archoera_scraper`，运行期不再依赖系统 `libcrypto`。
///
/// 约定：成功返回 [`ERA_CRYPTO_OK`]；参数非法返回 `ERA_CRYPTO_ERR_INVALID`；
/// 输出缓冲区不足返回 `ERA_CRYPTO_ERR_BUFFER`（此时 `*out_len` 归零，不写部分
/// 数据）；随机源失败返回 `ERA_CRYPTO_ERR_RNG`。
///
/// AES 函数内部完成 PKCS7 填充，输出长度最多为 `input_len + 16`。

#include <cstddef>

enum EraCryptoStatus : int {
    ERA_CRYPTO_OK = 0,
    ERA_CRYPTO_ERR_INVALID = -1,
    ERA_CRYPTO_ERR_BUFFER = -2,
    ERA_CRYPTO_ERR_RNG = -3,
};

extern "C" {

/// AES-128-ECB 加密 + PKCS7 填充。`key` 必须 16 字节。
int era_crypto_aes128_ecb_pkcs7(const unsigned char* key,
                                const unsigned char* input,
                                std::size_t input_len,
                                unsigned char* output,
                                std::size_t output_cap,
                                std::size_t* output_len);

/// AES-128-CBC 加密 + PKCS7 填充。`key` / `iv` 必须各 16 字节。
int era_crypto_aes128_cbc_pkcs7(const unsigned char* key,
                                const unsigned char* iv,
                                const unsigned char* input,
                                std::size_t input_len,
                                unsigned char* output,
                                std::size_t output_cap,
                                std::size_t* output_len);

/// RSA 裸模幂 `input^exponent mod modulus`，输出小写 hex 字符串（NUL 结尾）。
/// 三个入参均为 NUL 结尾的 ASCII hex；不加前导零，定长补零由调用方决定。
int era_crypto_rsa_modpow_hex(const char* input_hex,
                              const char* exponent_hex,
                              const char* modulus_hex,
                              char* output,
                              std::size_t output_cap,
                              std::size_t* output_len);

/// 用系统随机源填充 `output`（`len` 字节）。
int era_crypto_random(unsigned char* output, std::size_t len);

/// MD5 一次性摘要，`output` 至少 16 字节。
int era_crypto_md5(const unsigned char* input,
                   std::size_t input_len,
                   unsigned char* output);

/// SHA1 一次性摘要，`output` 至少 20 字节。
int era_crypto_sha1(const unsigned char* input,
                    std::size_t input_len,
                    unsigned char* output);

} // extern "C"
