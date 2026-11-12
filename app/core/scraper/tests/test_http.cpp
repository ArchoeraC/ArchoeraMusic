// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Rust HTTP 后端（scraper-crypto）C ABI 契约测试。
///
/// 覆盖：
///  - URL 百分号编码与 curl_easy_escape 一致（保留 A-Za-z0-9-._~，其余 %XX 大写）；
///  - 参数校验（空指针 / 非法 URL / 非法方法）；
///  - 真实 HTTPS GET（rustls + 系统 CA）、自定义请求头、POST 请求体、HTTP 状态码；
///  - 失败路径返回负错误码并给出可读错误。
///
/// 真实网络用例默认跳过；用 ARCHOERA_ONLINE_TEST=1 显式启用（与 Dart 侧一致）。

#include "scraper_http.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

namespace {

int failures = 0;

void check(bool ok, const char* expr, int line) {
    if (!ok) {
        std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, line, expr);
        ++failures;
    }
}

#define CHECK(expr) check((expr), #expr, __LINE__)

bool onlineEnabled() {
    const char* v = std::getenv("ARCHOERA_ONLINE_TEST");
    return v && std::strcmp(v, "1") == 0;
}

struct Response {
    std::string body;
    std::string error;
    long status = -1;
    int rc = 0;
};

Response request(const std::string& method, const std::string& url,
                 const std::string& ua = "ArchoeraMusic-test/1.0",
                 long timeoutMs = 15000,
                 const std::vector<std::string>& headers = {},
                 const std::string* body = nullptr) {
    std::vector<const char*> names;
    std::vector<const char*> values;
    for (size_t i = 0; i + 1 < headers.size(); i += 2) {
        names.push_back(headers[i].c_str());
        values.push_back(headers[i + 1].c_str());
    }
    char* outBody = nullptr;
    char* outErr = nullptr;
    long status = 0;
    Response r;
    r.rc = era_http_request(
        &outBody, &status, &outErr, method.c_str(), url.c_str(),
        ua.empty() ? nullptr : ua.c_str(), timeoutMs, 0,
        names.empty() ? nullptr : names.data(),
        values.empty() ? nullptr : values.data(), names.size(),
        body ? reinterpret_cast<const uint8_t*>(body->data()) : nullptr,
        body ? body->size() : 0);
    if (outBody) {
        r.body = outBody;
        era_http_free_string(outBody);
    }
    if (outErr) {
        r.error = outErr;
        era_http_free_string(outErr);
    }
    r.status = status;
    return r;
}

void testEscape() {
    auto escape = [](const std::string& in) {
        char* out = nullptr;
        if (era_http_escape(&out, in.c_str()) != ERA_HTTP_OK || !out) return std::string();
        std::string s(out);
        era_http_free_string(out);
        return s;
    };
    // curl_easy_escape 的保留集：字母数字 + - . _ ~
    CHECK(escape("abcXYZ019-._~") == "abcXYZ019-._~");
    CHECK(escape("a b") == "a%20b");
    CHECK(escape("周杰伦") == "%E5%91%A8%E6%9D%B0%E4%BC%A6");
    CHECK(escape("a&b=c?d") == "a%26b%3Dc%3Fd");
    CHECK(escape("") == "");

    // 空指针必须失败且不崩溃
    CHECK(era_http_escape(nullptr, "x") == ERA_HTTP_ERR_INVALID);
    char* out = nullptr;
    CHECK(era_http_escape(&out, nullptr) == ERA_HTTP_ERR_INVALID);
}

void testInvalidArguments() {
    char* body = nullptr;
    char* err = nullptr;
    long status = 0;
    CHECK(era_http_request(nullptr, &status, &err, "GET", "https://example.com",
                           nullptr, 1000, 0, nullptr, nullptr, 0, nullptr, 0) ==
          ERA_HTTP_ERR_INVALID);
    CHECK(era_http_request(&body, &status, &err, nullptr, "https://example.com",
                           nullptr, 1000, 0, nullptr, nullptr, 0, nullptr, 0) ==
          ERA_HTTP_ERR_INVALID);

    Response bad = request("GET", "not-a-url");
    CHECK(bad.rc == ERA_HTTP_ERR_REQUEST);
    CHECK(!bad.error.empty());

    Response badMethod = request("G ET", "https://example.com");
    CHECK(badMethod.rc == ERA_HTTP_ERR_REQUEST);
    CHECK(!badMethod.error.empty());
}

void testTransportError() {
    // 保留端口不可达：必须返回传输错误而不是挂起/崩溃。
    Response r = request("GET", "http://127.0.0.1:1/", "", 2000);
    CHECK(r.rc == ERA_HTTP_ERR_TRANSPORT);
    CHECK(!r.error.empty());
}

void testOnline() {
    // HTTPS + 系统 CA：与 libcurl 行为一致（rustls-platform-verifier）。
    Response r = request("GET", "https://api.github.com/zen");
    CHECK(r.rc == ERA_HTTP_OK);
    CHECK(r.status == 200);
    CHECK(!r.body.empty());

    // 自定义请求头 + 跟随重定向。
    Response hdrs = request("GET", "https://httpbin.org/headers",
                            "ArchoeraMusic-test/1.0", 20000,
                            {"X-Archoera-Test", "1"});
    CHECK(hdrs.rc == ERA_HTTP_OK);
    CHECK(hdrs.status == 200);
    CHECK(hdrs.body.find("X-Archoera-Test") != std::string::npos);

    // POST 请求体 + Content-Type。
    const std::string payload = "{\"hello\":\"world\"}";
    Response post = request("POST", "https://httpbin.org/post",
                            "ArchoeraMusic-test/1.0", 20000,
                            {"Content-Type", "application/json"}, &payload);
    CHECK(post.rc == ERA_HTTP_OK);
    CHECK(post.status == 200);
    CHECK(post.body.find("hello") != std::string::npos);
}

} // namespace

int main() {
    testEscape();
    testInvalidArguments();
    testTransportError();
    if (onlineEnabled()) {
        testOnline();
    } else {
        std::printf("[skip] 网络用例：设置 ARCHOERA_ONLINE_TEST=1 启用\n");
    }
    if (failures != 0) {
        std::fprintf(stderr, "test_http: %d 项失败\n", failures);
        return 1;
    }
    std::printf("test_http: 全部通过\n");
    return 0;
}
