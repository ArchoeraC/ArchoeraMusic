// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Rust 加密后端（scraper-crypto）C ABI 契约测试。
///
/// 只验证 C++ 侧调用约定与固定测试向量：AES-128-ECB/CBC + PKCS7、RSA 裸模幂、
/// MD5/SHA1、随机源。向量来源：NIST SP 800-38A、RFC 1321、FIPS 180-1，以及用
/// Python `pow()` 对NT 公开 modulus 计算的模幂结果。

#include "scraper_crypto.h"

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace {

int failures = 0;

void check(bool ok, const char* expr, int line) {
    if (!ok) {
        std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, line, expr);
        ++failures;
    }
}

#define CHECK(expr) check((expr), #expr, __LINE__)

std::vector<unsigned char> unhex(const char* text) {
    const std::size_t len = std::strlen(text);
    std::vector<unsigned char> out;
    out.reserve(len / 2);
    for (std::size_t i = 0; i + 1 < len; i += 2) {
        unsigned int byte = 0;
        std::sscanf(text + i, "%2x", &byte);
        out.push_back(static_cast<unsigned char>(byte));
    }
    return out;
}

std::string hex(const unsigned char* data, std::size_t len) {
    static const char digits[] = "0123456789abcdef";
    std::string out;
    out.reserve(len * 2);
    for (std::size_t i = 0; i < len; ++i) {
        out.push_back(digits[data[i] >> 4]);
        out.push_back(digits[data[i] & 0x0F]);
    }
    return out;
}

/// 调用方（api_client.h）的 PKCS7 补块：CBC 路径会先手动补块，再由 Rust 后端
/// 补第二块（历史双填充行为，保持字节兼容）。
std::vector<unsigned char> pkcs7_pad(const std::vector<unsigned char>& data) {
    const std::size_t pad = 16 - data.size() % 16;
    std::vector<unsigned char> out = data;
    out.insert(out.end(), pad, static_cast<unsigned char>(pad));
    return out;
}

/// AES + PKCS7，返回小写 hex；失败返回 "ERR:<rc>"。
std::string aes_hex(bool cbc, const char* key_hex, const char* iv_hex,
                    const std::vector<unsigned char>& raw_input) {
    const auto key = unhex(key_hex);
    // CBC 与生产调用一致：先手动补块，Rust 再补一块（双填充）。
    const auto input = cbc ? pkcs7_pad(raw_input) : raw_input;
    std::vector<unsigned char> out(input.size() + 16);
    std::size_t out_len = 0;
    int rc;
    if (cbc) {
        const auto iv = unhex(iv_hex);
        rc = era_crypto_aes128_cbc_pkcs7(key.data(), iv.data(), input.data(),
                                         input.size(), out.data(), out.size(),
                                         &out_len);
    } else {
        rc = era_crypto_aes128_ecb_pkcs7(key.data(), input.data(), input.size(),
                                         out.data(), out.size(), &out_len);
    }
    if (rc != ERA_CRYPTO_OK) return "ERR:" + std::to_string(rc);
    return hex(out.data(), out_len);
}

std::vector<unsigned char> bytes(const char* text) {
    const auto* data = reinterpret_cast<const unsigned char*>(text);
    return std::vector<unsigned char>(data, data + std::strlen(text));
}

void test_aes() {
    // NIST SP 800-38A F.1.1（首块）+ PKCS7 补出的第二块（0x10 * 16）。
    const std::vector<unsigned char> nist_block = unhex(
        "00112233445566778899aabbccddeeff");
    CHECK(aes_hex(false, "000102030405060708090a0b0c0d0e0f", nullptr,
                  nist_block) ==
          "69c4e0d86a7b0430d8cdb78070b4c55a"
          "954f64f2e4e86e9eee82d20216684899");

    // CBC 生产调用 = 手动 PKCS7 + Rust PKCS7（双填充，保持历史字节）：
    // "hello scraper"（13B → 手动 16B → 再补 16B）→ 32 字节密文。
    CHECK(aes_hex(true, "2b7e151628aed2a6abf7158809cf4f3c",
                  "000102030405060708090a0b0c0d0e0f", bytes("hello scraper")) ==
          "d850fdf88cd375151bd5ef9c66a1b981"
          "4a8d40f45644297bd63f55dfb85af91e");
    // NIST SP 800-38A F.2.1 首块；16B 明文 → 手动 32B → 再补 16B → 48 字节。
    CHECK(aes_hex(true, "2b7e151628aed2a6abf7158809cf4f3c",
                  "000102030405060708090a0b0c0d0e0f",
                  unhex("6bc1bee22e409f96e93d7e117393172a")) ==
          "7649abac8119b246cee98e9b12e9197d"
          "8964e0b149c10b7b682e6e39aaeb731c"
          "1bfb6cb370dae8824d65c4d8c0d42d43");

    // 容量不足：返回 BUFFER 且不写部分数据。
    unsigned char key[16] = {0};
    unsigned char small[4] = {0xAA, 0xAA, 0xAA, 0xAA};
    std::size_t out_len = 123;
    const int rc = era_crypto_aes128_ecb_pkcs7(
        key, reinterpret_cast<const unsigned char*>("x"), 1, small,
        sizeof(small), &out_len);
    CHECK(rc == ERA_CRYPTO_ERR_BUFFER);
    CHECK(out_len == 0);
    CHECK(small[0] == 0xAA && small[3] == 0xAA);

    // 空指针 + 非零长度：拒绝。
    CHECK(era_crypto_aes128_ecb_pkcs7(key, nullptr, 1, small, sizeof(small),
                                      &out_len) == ERA_CRYPTO_ERR_INVALID);
}

void test_rsa() {
    static const char* kModulus =
        "00e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7"
        "b725152b3ab17a876aea8a5aa76d2e417629ec4ee341f56135fccf695280"
        "104e0312ecbda92557c93870114af6c9d05c4f7f0c3685b7a46bee255932"
        "575cce10b424d813cfe4875d3e82047b97ddef52741d546b8e289dc6935b"
        "3ece0462db0a22b8e7";
    char out[512] = {0};
    std::size_t out_len = 0;
    CHECK(era_crypto_rsa_modpow_hex("0c0d0e0f10111213", "010001", kModulus, out,
                                    sizeof(out), &out_len) == ERA_CRYPTO_OK);
    // 与 Python pow(0x0c0d0e0f10111213, 0x10001, modulus) 一致（256 个 hex）；
    // 生产调用会转大写（旧 BN_bn2hex 语义），这里同样处理以锁字节一致。
    std::string result(out, out_len);
    for (char& ch : result) {
        if (ch >= 'a' && ch <= 'f') ch = static_cast<char>(ch - 'a' + 'A');
    }
    while (result.size() < 256) result.insert(result.begin(), '0');
    CHECK(result ==
          "82E967E4E0D5C533FB23E1192FFAFDD454E76AAC344771FF1D0F38756F446A1A"
          "25E0BD3C7CD7BC7175B6AEFF35C5A47887C9D8F12450DF0F0AFDE47BA37AA575"
          "447B4B422332DC1C86068703D769867C4E2C30046E1F5B6709093D7110C963CA"
          "B8017128AE5B653F29950E929B1587563E6138D64DDA99151DD0FB05A8D95B2B");

    // 输出缓冲区不足：BUFFER，且不写越界。
    char tiny[8] = {0};
    std::size_t tiny_len = 0;
    CHECK(era_crypto_rsa_modpow_hex("0c0d0e0f10111213", "010001", kModulus, tiny,
                                    sizeof(tiny), &tiny_len) ==
          ERA_CRYPTO_ERR_BUFFER);
    CHECK(tiny_len == 0);
    CHECK(tiny[0] == 0 && tiny[7] == 0);
}

void test_digests_and_random() {
    unsigned char md5[16];
    CHECK(era_crypto_md5(reinterpret_cast<const unsigned char*>("abc"), 3, md5) ==
          ERA_CRYPTO_OK);
    CHECK(hex(md5, sizeof(md5)) == "900150983cd24fb0d6963f7d28e17f72");

    unsigned char sha1[20];
    CHECK(era_crypto_sha1(reinterpret_cast<const unsigned char*>("abc"), 3, sha1) ==
          ERA_CRYPTO_OK);
    CHECK(hex(sha1, sizeof(sha1)) ==
          "a9993e364706816aba3e25717850c26c9cd0d89d");

    // 酷我 Cross = MD5(SHA1(token).hex)
    const char* token = "NMTID=abc123xyz";
    unsigned char token_sha1[20];
    CHECK(era_crypto_sha1(reinterpret_cast<const unsigned char*>(token),
                          std::strlen(token), token_sha1) == ERA_CRYPTO_OK);
    const std::string token_hex = hex(token_sha1, sizeof(token_sha1));
    CHECK(token_hex == "b263781ef29eeb80163897ca177bcf6502be6f4f");
    unsigned char cross[16];
    CHECK(era_crypto_md5(reinterpret_cast<const unsigned char*>(token_hex.data()),
                         token_hex.size(), cross) == ERA_CRYPTO_OK);
    CHECK(hex(cross, sizeof(cross)) == "88eecb3460ba90793cbb8061fb29375e");

    // 随机源：非全零（概率上不可能）；len = 0 合法。
    unsigned char random[32] = {0};
    CHECK(era_crypto_random(random, sizeof(random)) == ERA_CRYPTO_OK);
    bool all_zero = true;
    for (unsigned char byte : random) all_zero = all_zero && byte == 0;
    CHECK(!all_zero);
    CHECK(era_crypto_random(random, 0) == ERA_CRYPTO_OK);
}

} // namespace

int main() {
    test_aes();
    test_rsa();
    test_digests_and_random();
    if (failures == 0) {
        std::printf("scraper-crypto: all checks passed\n");
        return 0;
    }
    std::fprintf(stderr, "scraper-crypto: %d check(s) failed\n", failures);
    return 1;
}
