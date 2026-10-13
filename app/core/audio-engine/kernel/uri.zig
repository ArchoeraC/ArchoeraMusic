// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! 本地文件 URI（`file:`）解析（docs/audio-kernel-zig.md §6.1 输入抽象）。
//!
//! 目的：让内核**原生**接受 `file:` URI 形式的本地源（此前本地源只认裸路径，
//! `file://…` 会被当作字面文件名 → 打开失败、无谓回退 FFmpeg）。支持：
//!   - `file:///abs/path`            → `/abs/path`
//!   - `file://localhost/abs/path`   → `/abs/path`（其它 host 视为 Windows UNC `//host/path`）
//!   - `file://C:/x`  /  `file:/C:/x` / `file:///C:/x` → `C:/x`（盘符，去多余前导 `/`）
//!   - `%XX` 百分号解码（UTF-8；非法 `%XX` 原样保留）
//!
//! 命名：自有实现（`era_`/无前缀自有符号），不照搬上游标识符；不引入 `std.Uri`
//! 以保持解码行为可控且零依赖。

const std = @import("std");
const Error = @import("error.zig").Error;

/// 是否为 `file:` URI（scheme 大小写不敏感）。
pub fn isFileUri(s: []const u8) bool {
    return s.len >= "file:".len and std.ascii.eqlIgnoreCase(s[0.."file:".len], "file:");
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// `file:` URI → 本地绝对路径（分配；调用方释放）。非 `file:` / 空路径 → `error.OpenFailed`。
pub fn fileUriToPath(allocator: std.mem.Allocator, uri: []const u8) Error![]u8 {
    if (!isFileUri(uri)) return error.OpenFailed;
    const rest = uri["file:".len..];

    var host: []const u8 = "";
    var path: []const u8 = rest;
    if (std.mem.startsWith(u8, rest, "//")) {
        const after = rest[2..];
        const auth_end = std.mem.indexOfAny(u8, after, "/?#") orelse after.len;
        host = after[0..auth_end];
        path = after[auth_end..];
    }
    // 丢弃 fragment（`#` 之后）。
    if (std.mem.indexOfScalar(u8, path, '#')) |h| path = path[0..h];

    const is_localhost = host.len == 0 or std.ascii.eqlIgnoreCase(host, "localhost");
    const is_drive = host.len == 2 and host[1] == ':' and std.ascii.isAlphabetic(host[0]);

    var raw = std.ArrayList(u8).empty;
    defer raw.deinit(allocator);

    if (host.len > 0 and !is_localhost and !is_drive) {
        // 非本机 host：按 Windows UNC 形式拼接（POSIX 下不存在 → OpenFailed）。
        try raw.appendSlice(allocator, "//");
        try raw.appendSlice(allocator, host);
        try raw.appendSlice(allocator, path);
    } else if (is_drive) {
        try raw.append(allocator, std.ascii.toUpper(host[0]));
        try raw.appendSlice(allocator, ":");
        if (path.len > 0 and path[0] != '/') try raw.append(allocator, '/');
        try raw.appendSlice(allocator, path);
    } else {
        try raw.appendSlice(allocator, path);
    }

    var s = raw.items;
    // `file:///C:/x` → `/C:/x`：盘符前多余的前导 `/` 去掉。
    if (s.len >= 3 and s[0] == '/' and s[2] == ':' and std.ascii.isAlphabetic(s[1])) s = s[1..];
    // 盘符统一大写（Windows 不区分大小写；规范化便于比对/缓存）。
    if (s.len >= 2 and s[1] == ':' and std.ascii.isAlphabetic(s[0])) {
        s[0] = std.ascii.toUpper(s[0]);
    }
    if (s.len == 0) return error.OpenFailed;

    // 百分号解码（UTF-8）；非法 `%XX` 原样保留。
    const out = try allocator.alloc(u8, s.len);
    errdefer allocator.free(out);
    var o: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%' and i + 2 < s.len) {
            if (hexVal(s[i + 1])) |hi| {
                if (hexVal(s[i + 2])) |lo| {
                    out[o] = (hi << 4) | lo;
                    o += 1;
                    i += 3;
                    continue;
                }
            }
        }
        out[o] = s[i];
        o += 1;
        i += 1;
    }
    if (o == 0) {
        allocator.free(out);
        return error.OpenFailed;
    }
    return try allocator.realloc(out, o);
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectPath(expected: []const u8, uri: []const u8) !void {
    const got = try fileUriToPath(testing.allocator, uri);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "isFileUri：大小写与边界" {
    try testing.expect(isFileUri("file:///x"));
    try testing.expect(isFileUri("FILE:///x"));
    try testing.expect(isFileUri("File:/x"));
    try testing.expect(!isFileUri("files:///x"));
    try testing.expect(!isFileUri("/x"));
    try testing.expect(!isFileUri("http://x"));
    try testing.expect(!isFileUri(""));
}

test "fileUriToPath：POSIX 绝对路径 / localhost / 百分号解码" {
    try expectPath("/home/u/a.mp3", "file:///home/u/a.mp3");
    try expectPath("/home/u/a.mp3", "file://localhost/home/u/a.mp3");
    try expectPath("/home/u/a b.mp3", "file:///home/u/a%20b.mp3");
    try expectPath("/home/u/ü.mp3", "file:///home/u/%C3%BC.mp3");
    // 非法 %XX 原样保留
    try expectPath("/x/%zz.mp3", "file:///x/%zz.mp3");
    // fragment 丢弃
    try expectPath("/x/a.mp3", "file:///x/a.mp3#frag");
}

test "fileUriToPath：Windows 盘符各写法" {
    try expectPath("C:/Music/a.mp3", "file:///C:/Music/a.mp3");
    try expectPath("C:/Music/a.mp3", "file://C:/Music/a.mp3");
    try expectPath("C:/Music/a.mp3", "file:C:/Music/a.mp3");
    try expectPath("C:/Music/a b.mp3", "file:///C:/Music/a%20b.mp3");
    // 小写盘符规范为大写
    try expectPath("D:/x", "file:///d:/x");
}

test "fileUriToPath：UNC / 非法输入" {
    try expectPath("//server/share/a.mp3", "file://server/share/a.mp3");
    try testing.expectError(error.OpenFailed, fileUriToPath(testing.allocator, "http://x/y"));
    try testing.expectError(error.OpenFailed, fileUriToPath(testing.allocator, "file:"));
    try testing.expectError(error.OpenFailed, fileUriToPath(testing.allocator, "file://"));
}

test "fileUriToPath：与裸路径解耦（不含 scheme 时不做转换）" {
    // isFileUri 为假时调用方应直接走 openPath，不经此处。
    try testing.expect(!isFileUri("/plain/path.mp3"));
}
