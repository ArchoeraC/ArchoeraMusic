// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! 极简 HTTP/1.1 客户端：仅用于回环 MCP REST（明文、无 TLS）。
//!
//! 不引入 reqwest/tokio，保持原生 CLI 体积与依赖最小。支持 `Content-Length`
//! 与 `Transfer-Encoding: chunked` 两种响应体。

use serde_json::Value;
use std::io::{Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::time::Duration;

#[derive(Clone)]
pub struct Target {
    pub host: String,
    pub port: u16,
    pub key: String,
}

impl Target {
    pub fn base(&self) -> String {
        format!("{}:{}", self.host, self.port)
    }

    /// 拼接 REST URL 路径（`/api/status` + 可选查询）。
    pub fn url(&self, path: &str, query: &[(String, String)]) -> String {
        if query.is_empty() {
            return path.to_string();
        }
        let mut s = String::from(path);
        s.push('?');
        for (i, (k, v)) in query.iter().enumerate() {
            if i > 0 {
                s.push('&');
            }
            s.push_str(&url_encode(k));
            s.push('=');
            s.push_str(&url_encode(v));
        }
        s
    }
}

pub struct Response {
    pub status: u16,
    pub body: Value,
}

#[derive(Debug)]
pub enum RequestError {
    Connect(String),
    Timeout,
    Io(String),
}

/// `text/plain` 场景（`--render`）返回原文；此处统一按 JSON 解析。
pub fn request(
    target: &Target,
    method: &str,
    path: &str,
    query: &[(String, String)],
    body: Option<&Value>,
) -> Result<Response, RequestError> {
    let full_path = target.url(path, query);
    let addr = (target.host.as_str(), target.port)
        .to_socket_addrs()
        .map_err(|e| RequestError::Connect(e.to_string()))?
        .next()
        .ok_or_else(|| RequestError::Connect("无法解析主机".to_string()))?;

    let stream = TcpStream::connect_timeout(&addr, Duration::from_secs(5))
        .map_err(|e| map_io(&e))?;
    let _ = stream.set_read_timeout(Some(Duration::from_secs(20)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(20)));

    let payload = body.map(|b| serde_json::to_vec(b).unwrap_or_default());
    let mut req = String::new();
    req.push_str(&format!("{method} {full_path} HTTP/1.1\r\n"));
    req.push_str(&format!("Host: {}\r\n", target.base()));
    req.push_str("Accept: application/json\r\n");
    if !target.key.is_empty() {
        req.push_str(&format!("X-Archoera-Key: {}\r\n", target.key));
    }
    req.push_str("Connection: close\r\n");
    if let Some(p) = &payload {
        req.push_str("Content-Type: application/json\r\n");
        req.push_str(&format!("Content-Length: {}\r\n", p.len()));
    }
    req.push_str("\r\n");

    let mut stream = stream;
    stream
        .write_all(req.as_bytes())
        .map_err(|e| map_io(&e))?;
    if let Some(p) = &payload {
        stream.write_all(p).map_err(|e| map_io(&e))?;
    }
    stream.flush().map_err(|e| map_io(&e))?;

    let mut raw = Vec::new();
    stream.read_to_end(&mut raw).map_err(|e| map_io(&e))?;

    parse_response(&raw)
}

fn map_io(e: &std::io::Error) -> RequestError {
    match e.kind() {
        std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock => RequestError::Timeout,
        _ => RequestError::Connect(e.to_string()),
    }
}

fn find_subslice(hay: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || hay.len() < needle.len() {
        return None;
    }
    hay.windows(needle.len()).position(|w| w == needle)
}

pub fn parse_response(raw: &[u8]) -> Result<Response, RequestError> {
    let sep = find_subslice(raw, b"\r\n\r\n")
        .ok_or_else(|| RequestError::Io("响应格式非法".to_string()))?;
    let head = String::from_utf8_lossy(&raw[..sep]);
    let mut lines = head.split("\r\n");
    let status_line = lines.next().unwrap_or("");
    let status = status_line
        .split_whitespace()
        .nth(1)
        .and_then(|s| s.parse::<u16>().ok())
        .unwrap_or(0);

    let mut chunked = false;
    let mut content_length: Option<usize> = None;
    for line in lines {
        let Some((name, value)) = line.split_once(':') else {
            continue;
        };
        let name = name.trim().to_ascii_lowercase();
        let value = value.trim();
        if name == "transfer-encoding" && value.to_ascii_lowercase().contains("chunked") {
            chunked = true;
        } else if name == "content-length" {
            content_length = value.parse::<usize>().ok();
        }
    }

    let body_bytes = &raw[sep + 4..];
    let decoded = if chunked {
        dechunk(body_bytes)
    } else if let Some(n) = content_length {
        body_bytes[..n.min(body_bytes.len())].to_vec()
    } else {
        body_bytes.to_vec()
    };

    let body = if decoded.is_empty() {
        Value::Null
    } else {
        match serde_json::from_slice::<Value>(&decoded) {
            Ok(v) => v,
            Err(_) => Value::String(String::from_utf8_lossy(&decoded).to_string()),
        }
    };
    Ok(Response { status, body })
}

/// 解析 `Transfer-Encoding: chunked` 正文。
fn dechunk(data: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < data.len() {
        // 行：十六进制块大小（可带 `;ext`）。
        let line_end = match find_subslice(&data[i..], b"\r\n") {
            Some(p) => i + p,
            None => break,
        };
        let size_str = String::from_utf8_lossy(&data[i..line_end]);
        let size_hex = size_str.split(';').next().unwrap_or("").trim();
        let size = usize::from_str_radix(size_hex, 16).unwrap_or(0);
        i = line_end + 2;
        if size == 0 {
            break;
        }
        let end = (i + size).min(data.len());
        out.extend_from_slice(&data[i..end]);
        i = end + 2; // 跳过块尾 CRLF
    }
    out
}

/// RFC 3986 组件编码（保留 `-._~` 与字母数字）。
pub fn url_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_content_length() {
        let raw = b"HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\n{\"ok\":true}\n\n";
        let r = parse_response(raw).unwrap();
        assert_eq!(r.status, 200);
        assert_eq!(r.body["ok"], Value::Bool(true));
    }

    #[test]
    fn decodes_chunked() {
        let raw = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\n{\"a\":\r\n4\r\n1}\r\n\r\n0\r\n\r\n";
        let r = parse_response(raw).unwrap();
        assert_eq!(r.status, 200);
        assert_eq!(r.body["a"], serde_json::json!(1));
    }

    #[test]
    fn builds_query_with_encoding() {
        let t = Target { host: "127.0.0.1".into(), port: 1, key: String::new() };
        let url = t.url("/api/search", &[("q".into(), "周杰伦".into())]);
        assert!(url.starts_with("/api/search?q=%E5%91%A8"));
    }
}
