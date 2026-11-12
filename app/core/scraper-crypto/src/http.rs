// ArchoeraMusic
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! 刮削器的同步 HTTP 后端（替换 C++ 侧对系统 `libcurl` 的链接）。
//!
//! 背景：scraper 原先链接 `libcurl.so.4`，而发行版 libcurl 又传递依赖系统
//! `libssl/libcrypto`；OpenSSL soname 升级（`.so.3 → .so.4`）会让已发布的
//! 二进制在用户机上加载失败。这里改用与 downloader 相同的 `reqwest + rustls`
//! 静态栈，产物不再需要任何系统 TLS/HTTP 库。
//!
//! 对外契约（`era_http_*`，C ABI）保持与原 libcurl 用法一致的语义：
//! - 同步阻塞，一次请求一次调用；
//! - 每次请求带 User-Agent；可附带自定义请求头（`Host` 按 URL 覆盖处理）；
//! - 跟随重定向（上限 50，同 curl）；
//! - 未显式指定 `Accept-Encoding` 时发送 `gzip`（同 curl）；
//! - 默认直连；设置 `http_proxy` / `https_proxy` 时走代理（`no_proxy` 生效）；
//! - 失败给出行文错误，由 C++ 侧拼进 `GET 失败: ...` 等既有文案。
//!
//! 线程：`reqwest::blocking` 自带运行时，调用方无需异步上下文
//! （scraper 的 worker 是同步 `std::thread`）。

use core::ffi::{c_char, c_int, c_long};
use std::ffi::CStr;
use std::time::Duration;

use reqwest::blocking::{Client, RequestBuilder};
use reqwest::header::{HeaderMap, HeaderName, HeaderValue, ACCEPT_ENCODING, USER_AGENT};
use reqwest::{Method, Url};

/// 成功。
pub const ERA_HTTP_OK: c_int = 0;
/// 参数非法（空指针 / 非 UTF-8 / 非法请求头）。
pub const ERA_HTTP_ERR_INVALID: c_int = -1;
/// 请求构造失败（URL 或方法不合法）。
pub const ERA_HTTP_ERR_REQUEST: c_int = -2;
/// 网络 / TLS / 超时 / 响应体读取失败。
pub const ERA_HTTP_ERR_TRANSPORT: c_int = -3;

/// 与 curl 默认 `CURLOPT_MAXREDIRS` 保持一致。
const MAX_REDIRECTS: usize = 50;
/// `timeout_ms <= 0` 时的兜底总超时。
const FALLBACK_TIMEOUT: Duration = Duration::from_secs(300);

/// 构建客户端。
///
/// `proxy_mode == 1` 且环境存在 `*_proxy` 时由 reqwest 自动接管（含 `no_proxy`），
/// 否则直连——与 curl 在未配置代理时的行为一致。不读桌面环境的系统代理设置：
/// scraper 只访问公网 API，误用本地代理在国内桌面环境很常见。
fn build_client(proxy_mode: c_int) -> Client {
    let builder = Client::builder().redirect(reqwest::redirect::Policy::limited(MAX_REDIRECTS));
    let builder = if proxy_mode == 1 {
        builder
    } else {
        builder.no_proxy()
    };
    builder.build().unwrap_or_else(|_| Client::new())
}

/// 收集自定义请求头，并单独取出 `Host`（reqwest 会忽略普通头里的 Host）。
fn build_headers(
    names: *const *const c_char,
    values: *const *const c_char,
    count: usize,
) -> Result<(HeaderMap, Option<String>), c_int> {
    let mut headers = HeaderMap::new();
    let mut host: Option<String> = None;
    if count == 0 {
        return Ok((headers, host));
    }
    if names.is_null() || values.is_null() {
        return Err(ERA_HTTP_ERR_INVALID);
    }
    for i in 0..count {
        let (name_ptr, value_ptr) = unsafe { (*names.add(i), *values.add(i)) };
        if name_ptr.is_null() || value_ptr.is_null() {
            return Err(ERA_HTTP_ERR_INVALID);
        }
        let name = unsafe { CStr::from_ptr(name_ptr) }
            .to_str()
            .map_err(|_| ERA_HTTP_ERR_INVALID)?;
        let value = unsafe { CStr::from_ptr(value_ptr) }
            .to_str()
            .map_err(|_| ERA_HTTP_ERR_INVALID)?;
        if name.eq_ignore_ascii_case("host") {
            host = Some(value.to_string());
        } else {
            let header_name =
                HeaderName::from_bytes(name.as_bytes()).map_err(|_| ERA_HTTP_ERR_INVALID)?;
            let header_value = HeaderValue::from_str(value).map_err(|_| ERA_HTTP_ERR_INVALID)?;
            headers.insert(header_name, header_value);
        }
    }
    Ok((headers, host))
}

/// 把 Rust 字符串转成调用方负责释放的 C 字符串。
///
/// 响应体可能含任意字节：这里按 C 语义截断到首个 NUL，而不是让整次请求失败。
fn into_c_string(s: &str) -> *mut c_char {
    let bytes = s.as_bytes();
    let len = bytes.iter().position(|&b| b == 0).unwrap_or(bytes.len());
    let layout = std::alloc::Layout::array::<u8>(len + 1).expect("era_http: 内存布局");
    unsafe {
        let ptr = std::alloc::alloc(layout) as *mut u8;
        if ptr.is_null() {
            std::alloc::handle_alloc_error(layout);
        }
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), ptr, len);
        *ptr.add(len) = 0;
        ptr.cast::<c_char>()
    }
}

/// Rust 侧一次请求的参数（避免 C ABI 函数签名过长）。
struct Request<'a> {
    method: &'a str,
    url: &'a str,
    user_agent: &'a str,
    timeout_ms: c_long,
    proxy_mode: c_int,
    headers: HeaderMap,
    host_override: Option<String>,
    body: Option<&'a [u8]>,
}

/// 执行请求，返回 (响应体, 状态码) 或 (错误码, 错误描述)。
fn execute(req: Request<'_>) -> Result<(String, c_long), (c_int, String)> {
    let mut url = Url::parse(req.url).map_err(|e| {
        (
            ERA_HTTP_ERR_REQUEST,
            format!("请求构造失败（URL 不合法）: {e}"),
        )
    })?;
    if let Some(host) = req.host_override.as_deref() {
        url.set_host(Some(host)).map_err(|e| {
            (
                ERA_HTTP_ERR_REQUEST,
                format!("请求构造失败（Host 不合法）: {e}"),
            )
        })?;
    }
    let method = Method::from_bytes(req.method.as_bytes()).map_err(|_| {
        (
            ERA_HTTP_ERR_REQUEST,
            format!("请求构造失败（方法不合法）: {}", req.method),
        )
    })?;

    let client = build_client(req.proxy_mode);

    let mut builder: RequestBuilder = client.request(method, url);
    if !req.headers.contains_key(USER_AGENT) && !req.user_agent.is_empty() {
        builder = builder.header(USER_AGENT, req.user_agent);
    }
    // 编码协商交给要求端：reqwest 只在请求携带 `Accept-Encoding` 时解压，
    // 而 curl 默认发送该头。服务器可能回 gzip 或 deflate（Cloudflare 常见），
    // 两者都声明才保险；调用方显式设置时不覆盖。
    if !req.headers.contains_key(ACCEPT_ENCODING) {
        builder = builder.header(ACCEPT_ENCODING, "gzip, deflate");
    }
    builder = builder.headers(req.headers);
    if let Some(body) = req.body {
        builder = builder.body(body.to_vec());
    }
    builder = builder.timeout(if req.timeout_ms > 0 {
        Duration::from_millis(req.timeout_ms as u64)
    } else {
        FALLBACK_TIMEOUT
    });

    // blocking 客户端自带运行时（在内部线程上执行），调用方无需异步上下文。
    let resp = builder
        .send()
        .map_err(|e| (ERA_HTTP_ERR_TRANSPORT, classify(e)))?;
    let status = resp.status().as_u16() as c_long;
    let text = resp
        .text()
        .map_err(|e| (ERA_HTTP_ERR_TRANSPORT, classify(e)))?;
    Ok((text, status))
}

/// 把 reqwest 错误拆成「可读原因」，并保留超时/连接/TLS 的关键字，方便日志排障。
fn classify(err: reqwest::Error) -> String {
    if err.is_timeout() {
        format!("超时: {err}")
    } else if err.is_connect() {
        format!("连接失败: {err}")
    } else if err.is_redirect() {
        format!("重定向失败: {err}")
    } else if err.is_builder() {
        format!("请求构造失败: {err}")
    } else {
        err.to_string()
    }
}

/// 一次同步 HTTP 请求（GET / POST / 任意方法，请求体可选）。
///
/// 参数：
/// - `method`：如 `"GET"` / `"POST"`；
/// - `url`：完整 URL（含 scheme）；
/// - `user_agent`：非空且请求头无 `User-Agent` 时使用；
/// - `timeout_ms`：整体超时（连接 + 传输），<=0 表示 300s；
/// - `proxy_mode`：1 = 使用 `*_proxy` 环境变量，0 = 强制直连；
/// - `header_names` / `header_values` / `header_count`：附加请求头（可为空）；
/// - `post_body` / `post_len`：请求体（`post_body` 为空表示无请求体）。
///
/// 输出：成功时填 `out_body` / `out_status`；失败时填 `out_err`。
/// 字符串均需 `era_http_free_string` 释放。
///
/// # Safety
/// 所有指针必须有效；字符串参数须为 NUL 结尾的 UTF-8。
#[no_mangle]
pub unsafe extern "C" fn era_http_request(
    out_body: *mut *mut c_char,
    out_status: *mut c_long,
    out_err: *mut *mut c_char,
    method: *const c_char,
    url: *const c_char,
    user_agent: *const c_char,
    timeout_ms: c_long,
    proxy_mode: c_int,
    header_names: *const *const c_char,
    header_values: *const *const c_char,
    header_count: usize,
    post_body: *const u8,
    post_len: usize,
) -> c_int {
    if out_body.is_null() || out_status.is_null() || out_err.is_null() {
        return ERA_HTTP_ERR_INVALID;
    }
    unsafe {
        *out_body = std::ptr::null_mut();
        *out_status = 0;
        *out_err = std::ptr::null_mut();
    }

    let outcome = (|| -> Result<(String, c_long), (c_int, String)> {
        if method.is_null() || url.is_null() {
            return Err((ERA_HTTP_ERR_INVALID, "参数非法: method/url 为空".into()));
        }
        let method = unsafe { CStr::from_ptr(method) }
            .to_str()
            .map_err(|_| (ERA_HTTP_ERR_INVALID, "method 不是 UTF-8".to_string()))?;
        let url = unsafe { CStr::from_ptr(url) }
            .to_str()
            .map_err(|_| (ERA_HTTP_ERR_INVALID, "url 不是 UTF-8".to_string()))?;
        let user_agent = if user_agent.is_null() {
            ""
        } else {
            unsafe { CStr::from_ptr(user_agent) }
                .to_str()
                .unwrap_or_default()
        };
        let (headers, host_override) = build_headers(header_names, header_values, header_count)
            .map_err(|code| (code, "请求头非法（名称或取值无效）".to_string()))?;
        let body = if post_body.is_null() {
            None
        } else {
            Some(unsafe { std::slice::from_raw_parts(post_body, post_len) })
        };
        execute(Request {
            method,
            url,
            user_agent,
            timeout_ms,
            proxy_mode,
            headers,
            host_override,
            body,
        })
    })();

    match outcome {
        Ok((body, status)) => {
            unsafe {
                *out_body = into_c_string(&body);
                *out_status = status;
            }
            ERA_HTTP_OK
        }
        Err((code, message)) => {
            unsafe {
                *out_err = into_c_string(&message);
            }
            code
        }
    }
}

/// 释放 [`era_http_request`] / [`era_http_escape`] 返回的字符串。
///
/// # Safety
/// `s` 必须是本模块返回的指针（或空指针）。
#[no_mangle]
pub unsafe extern "C" fn era_http_free_string(s: *mut c_char) {
    if s.is_null() {
        return;
    }
    let len = unsafe { CStr::from_ptr(s) }.to_bytes().len();
    let layout = std::alloc::Layout::array::<u8>(len + 1).expect("era_http: 内存布局");
    unsafe {
        std::alloc::dealloc(s.cast::<u8>(), layout);
    }
}

/// URL 百分号编码（等价 `curl_easy_escape`：保留 `A-Za-z0-9-._~`，
/// 其余按 UTF-8 字节输出 `%XX` 大写）。结果需 `era_http_free_string` 释放。
///
/// # Safety
/// `out` 不能为空；`input` 为 NUL 结尾字节串。
#[no_mangle]
pub unsafe extern "C" fn era_http_escape(out: *mut *mut c_char, input: *const c_char) -> c_int {
    if out.is_null() || input.is_null() {
        return ERA_HTTP_ERR_INVALID;
    }
    let raw = unsafe { CStr::from_ptr(input) }.to_bytes();
    let encoded = percent_encode(raw);
    unsafe {
        *out = into_c_string(&encoded);
    }
    ERA_HTTP_OK
}

fn percent_encode(raw: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789ABCDEF";
    let mut out = String::with_capacity(raw.len() * 3);
    for &b in raw {
        let unreserved = b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b'_' | b'~');
        if unreserved {
            out.push(b as char);
        } else {
            out.push('%');
            out.push(HEX[(b >> 4) as usize] as char);
            out.push(HEX[(b & 0x0F) as usize] as char);
        }
    }
    out
}
