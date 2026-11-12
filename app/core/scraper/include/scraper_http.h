// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! 刮削器专用的同步 HTTP 客户端（C++ 薄封装，header-only）。
//!
//! 实现由 `app/core/scraper-crypto`（纯 Rust 静态库）提供，底层是
//! `reqwest + rustls`，**不再链接系统 `libcurl`**，从而让发布产物的
//! OpenSSL 使用路径彻底消失（发行版 libcurl 会传递依赖 libssl/libcrypto）。
//!
//! 语义保持原 libcurl 实现：
//! - 同步阻塞，一次请求一个句柄；
//! - 自动跟随重定向；
//! - 请求头 `Host` 走 URL 覆盖（避免 reqwest 把它当普通头丢弃）；
//! - 未显式设置 `Accept-Encoding` 时按 curl 默认发送 `gzip`；
//! - 失败消息保持 `GET 失败: ...` / `POST 失败: ...` 形式（日志与 lastError
//!   文案不变）。

#pragma once

#include <cstdint>
#include <cstdlib>
#include <string>
#include <utility>
#include <vector>

extern "C" {

/// C ABI 错误码（与 Rust 侧 `ERA_HTTP_*` 对齐）。
#define ERA_HTTP_OK 0
#define ERA_HTTP_ERR_INVALID (-1)
#define ERA_HTTP_ERR_REQUEST (-2)
#define ERA_HTTP_ERR_TRANSPORT (-3)
#define ERA_HTTP_ERR_HEADER (-4)

/// 一次同步 HTTP 请求。成功返回 0 并填充 `out_body` / `out_status`；
/// 失败返回负值并填充 `out_err`。字符串均需 `era_http_free_string` 释放。
int era_http_request(char** out_body, long* out_status, char** out_err,
                     const char* method, const char* url, const char* user_agent,
                     long timeout_ms, int proxy_mode,
                     const char* const* header_names,
                     const char* const* header_values, size_t header_count,
                     const uint8_t* post_body, size_t post_len);

/// 释放本模块返回的字符串。
void era_http_free_string(char* s);

/// URL 百分号编码（保留 `A-Za-z0-9-._~`）。
int era_http_escape(char** out, const char* input);

/// 底层 TLS 后端名（诊断用，恒为 "rustls"）。
const char* era_http_tls_backend(void);
}

namespace archoera::scraper {

using HeaderList = std::vector<std::pair<std::string, std::string>>;

/// 同步 HTTP 客户端：替代原先的 `CURL*` 句柄。
///
/// 句柄本身不含状态，保留构造/析构只是为了让各客户端的
/// `curl_ = curl_easy_init()` 迁移保持最小改动。
class HttpClient {
public:
    HttpClient() = default;

    /// 构造失败时有意义（对齐原 curl_easy_init 失败抛异常的行为）。
    explicit HttpClient(bool /*reserve*/) {}

    HttpClient(const HttpClient&) = delete;
    HttpClient& operator=(const HttpClient&) = delete;

    /// 是否可用（Rust 后端始终可用）。
    bool valid() const { return true; }

    /// 发送请求（内部入口）。
    ///
    /// 对齐 libcurl：直连为默认；设置了 `http_proxy` / `https_proxy` 环境变量时
    /// 才走代理（no_proxy 由 reqwest 处理）。scraper 面向公网 API，不做系统级
    /// 代理探测——避免在国内桌面环境下把直连流量错误地转发到本地代理。
    bool perform(const std::string& method, const std::string& url,
                 const std::string& userAgent, long timeoutMs,
                 const HeaderList& headers, const std::string* postBody,
                 std::string& body, long* status, std::string& error) {
        body.clear();
        status = 0;
        std::vector<const char*> names;
        std::vector<const char*> values;
        names.reserve(headers.size());
        values.reserve(headers.size());
        for (const auto& h : headers) {
            names.push_back(h.first.c_str());
            values.push_back(h.second.c_str());
        }
        char* outBody = nullptr;
        char* outErr = nullptr;
        long outStatus = 0;
        const int rc = era_http_request(
            &outBody, &outStatus, &outErr, method.c_str(), url.c_str(),
            userAgent.empty() ? nullptr : userAgent.c_str(), timeoutMs, 0,
            names.empty() ? nullptr : names.data(),
            values.empty() ? nullptr : values.data(), headers.size(),
            postBody ? reinterpret_cast<const uint8_t*>(postBody->data()) : nullptr,
            postBody ? postBody->size() : 0);
        if (outBody) {
            body.assign(outBody);
            era_http_free_string(outBody);
        }
        error.clear();
        if (outErr) {
            error.assign(outErr);
            era_http_free_string(outErr);
        }
        if (status) *status = outStatus;
        return rc == ERA_HTTP_OK;
    }
};

/// URL 编码（替代 curl_easy_escape）。
inline std::string urlEncode(const std::string& raw) {
    char* out = nullptr;
    if (era_http_escape(&out, raw.c_str()) != ERA_HTTP_OK || !out) return raw;
    std::string result(out);
    era_http_free_string(out);
    return result;
}

} // namespace archoera::scraper
