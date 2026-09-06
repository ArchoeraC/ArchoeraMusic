// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! 容器帧层（docs/audio-kernel-zig.md §9.1 的 RIFF 家族统一 framing）
//!
//! 三种（+CAF）容器的 chunk 头布局不同，统一抽象为 `Chunk{id, size}`：
//!   - RIFF / RIFX / RF64：`id(4) + size(4, 容器字节序)`，payload = size，pad 到 2；
//!   - W64（Sony Wave64）：`GUID(16) + size(8, LE)`，payload = size - 24，pad 到 8，
//!     id 取 GUID 前 4 字节（四字符码）；
//!   - AIFF / AIFF-C：`id(4) + size(4, BE)`，payload = size，pad 到 2；
//!   - CAF（Apple Core Audio）：`id(4) + size(8, BE)`，payload = size，**无对齐 pad**。
//!
//! AU（Sun）无 chunk 结构（固定 24 字节头 + annotation），由 lib.zig 单独解析，
//! 本模块的 nextChunk/skipChunk 不对其开放。
//!
//! 对齐（§13.3）：chunk size 均来自文件、可能畸形，`skipChunk` 保守截断到输入边界。

const std = @import("std");
const Error = @import("../../error.zig").Error;
const io = @import("../../io.zig");

/// 容器类型（open() 探测头后选定）
pub const Container = enum {
    riff, // RIFF / RIFX / RF64（RIFX 为 big-endian）
    w64, // Sony Wave64（全小端）
    aiff, // AIFF / AIFF-C（大端）
    caf, // Apple CAF：文件头 caff + id(4)+size(8 BE) chunk，无 pad；样本字节序由 desc flags 决定
    au, // Sun AU：固定头 .snd + 24B 字段，无 chunk 结构（数据定位于 data_offset）
};

/// W64 GUID（FFmpeg w64.h 定义；前 4 字节为四字符码，其余为按小端存储的
/// GUID 尾段 —— 直接逐字节比对，不做字节序换算）
pub const riff_guid: [16]u8 = .{ 'r', 'i', 'f', 'f', 0x2E, 0x91, 0xCF, 0x11, 0xA5, 0xD6, 0x28, 0xDB, 0x04, 0xC1, 0x00, 0x00 };
pub const wave_guid: [16]u8 = .{ 'w', 'a', 'v', 'e', 0xF3, 0xAC, 0xD3, 0x11, 0x8C, 0xD1, 0x00, 0xC0, 0x4F, 0x8E, 0xDB, 0x8A };
pub const fmt_guid: [16]u8 = .{ 'f', 'm', 't', ' ', 0xF3, 0xAC, 0xD3, 0x11, 0x8C, 0xD1, 0x00, 0xC0, 0x4F, 0x8E, 0xDB, 0x8A };
pub const fact_guid: [16]u8 = .{ 'f', 'a', 'c', 't', 0xF3, 0xAC, 0xD3, 0x11, 0x8C, 0xD1, 0x00, 0xC0, 0x4F, 0x8E, 0xDB, 0x8A };
pub const data_guid: [16]u8 = .{ 'd', 'a', 't', 'a', 0xF3, 0xAC, 0xD3, 0x11, 0x8C, 0xD1, 0x00, 0xC0, 0x4F, 0x8E, 0xDB, 0x8A };
pub const summary_guid: [16]u8 = .{ 0xBC, 0x94, 0x5F, 0x92, 0x5A, 0x52, 0xD2, 0x11, 0x86, 0xDC, 0x00, 0xC0, 0x4F, 0x8E, 0xDB, 0x8A };

/// W64 data GUID 的大端变体（data_be，少数文件使用；FFmpeg 亦识别）
pub const data_be_guid: [16]u8 = .{ 'd', 'a', 't', 'a', 0xF3, 0xAC, 0xD3, 0x11, 0x8C, 0xD1, 0x00, 0xC0, 0x4F, 0x8E, 0xDB, 0x8A };

/// 一个 chunk 头。`size` 为 payload 字节数（W64 已减 24）。
pub const Chunk = struct {
    /// 四字符码（W64 取 GUID 前 4 字节）
    id: [4]u8,
    size: u64,
};

/// 读下一个 chunk 头；干净 EOF（不足一个头）返回 null。
/// W64 的 GUID 前 4 字节即四字符码（"fmt "/"data"/"fact"…）。
/// RIFF 变体的 chunk size 字节序与样本一致（RIFX 为大端），故由调用方传入。
pub fn nextChunk(reader: *io.Reader, container: Container, endian: std.builtin.Endian) Error!?Chunk {
    switch (container) {
        .riff => {
            var h: [8]u8 = undefined;
            if (!try readExact(reader, &h)) return null;
            return .{ .id = h[0..4].*, .size = readU32(h[4..8], endian) };
        },
        .aiff => {
            var h: [8]u8 = undefined;
            if (!try readExact(reader, &h)) return null;
            return .{ .id = h[0..4].*, .size = readU32(h[4..8], .big) };
        },
        .w64 => {
            var h: [24]u8 = undefined;
            if (!try readExact(reader, &h)) return null;
            const size = readU64(h[16..24], .little);
            // W64 chunk size 含自身 24 字节头；payload = size - 24
            if (size <= 24) return error.Corrupt;
            return .{ .id = h[0..4].*, .size = size - 24 };
        },
        .caf => {
            // CAF chunk：id(4) + size(8, BE)，无对齐 pad（镜像 FFmpeg cafdec）
            var h: [12]u8 = undefined;
            if (!try readExact(reader, &h)) return null;
            return .{ .id = h[0..4].*, .size = readU64(h[4..12], .big) };
        },
        // AU 无 chunk 结构（lib.zig 固定头解析），此路径不可达
        .au => unreachable,
    }
}

/// 跳过 chunk payload（含对齐 pad）。payload 可能越过输入边界，`seek` 越界无害
/// （positional read 返回 EOF），无需额外 clamp。
pub fn skipChunk(reader: *io.Reader, chunk: Chunk, container: Container) Error!void {
    const payload = chunk.size;
    const pad: u64 = switch (container) {
        .riff, .aiff => payload & 1,
        .w64 => (8 - (payload % 8)) % 8,
        // CAF 无对齐 pad（AU 无 chunk，不可达）
        .caf, .au => 0,
    };
    try reader.seek(@intCast(payload + pad), .current);
}

/// W64 容器头校验：riff GUID(16) + filesize(8) + wave GUID(16) = 40 字节。
/// 返回 true 表示头部匹配；filesize 仅校验最小值（镜像 FFmpeg 行为）。
pub fn checkW64Header(reader: *io.Reader) Error!bool {
    var h: [40]u8 = undefined;
    if (!try readExact(reader, &h)) return false;
    if (!std.mem.eql(u8, h[0..16], &riff_guid)) return false;
    const filesize = readU64(h[16..24], .little);
    if (filesize < 16 + 8 + 16 + 8 + 16 + 8) return error.Corrupt;
    if (!std.mem.eql(u8, h[24..40], &wave_guid)) return false;
    return true;
}

/// AIFF 容器头：FORM(4) + size(4 BE) + "AIFF"/"AIFC"(4)。
/// 返回 form 类型（`true` = AIFC）。头部不匹配返回 null。
pub fn checkAiffHeader(reader: *io.Reader) Error!?bool {
    var h: [12]u8 = undefined;
    if (!try readExact(reader, &h)) return null;
    if (!std.mem.eql(u8, h[0..4], "FORM")) return null;
    if (std.mem.eql(u8, h[8..12], "AIFF")) return false;
    if (std.mem.eql(u8, h[8..12], "AIFC")) return true;
    return null;
}

fn readExact(reader: *io.Reader, buf: []u8) Error!bool {
    var got: usize = 0;
    while (got < buf.len) {
        const n = try reader.read(buf[got..]);
        if (n == 0) return false;
        got += n;
    }
    return true;
}

inline fn readU32(b: []const u8, endian: std.builtin.Endian) u32 {
    return std.mem.readInt(u32, b[0..4], endian);
}

inline fn readU64(b: []const u8, endian: std.builtin.Endian) u64 {
    return std.mem.readInt(u64, b[0..8], endian);
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "chunk: GUID 常量长度与唯一性" {
    try testing.expectEqual(@as(usize, 16), riff_guid.len);
    try testing.expect(std.mem.eql(u8, &fmt_guid, &data_guid) == false);
    try testing.expectEqual(@as(u8, 'f'), fmt_guid[0]);
    try testing.expectEqual(@as(u8, 'd'), data_guid[0]);
}

test "chunk: RIFF 头读取与跳过（含奇对齐）" {
    // "fmt " size=16 + payload 16 + "JUNK" size=5 + payload 5 + pad
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(testing.allocator);
    try bytes.appendSlice(testing.allocator, "fmt \x10\x00\x00\x00");
    try bytes.appendSlice(testing.allocator, &[_]u8{0} ** 16);
    try bytes.appendSlice(testing.allocator, "JUNK\x05\x00\x00\x00");
    try bytes.appendSlice(testing.allocator, "hello");
    try bytes.appendSlice(testing.allocator, &[_]u8{0}); // pad

    var reader = io.Reader.openMem(bytes.items);
    const c1 = (try nextChunk(&reader, .riff, .little)).?;
    try testing.expectEqualStrings("fmt ", &c1.id);
    try testing.expectEqual(@as(u64, 16), c1.size);
    try skipChunk(&reader, c1, .riff);
    const c2 = (try nextChunk(&reader, .riff, .little)).?;
    try testing.expectEqualStrings("JUNK", &c2.id);
    try testing.expectEqual(@as(u64, 5), c2.size);
    try skipChunk(&reader, c2, .riff);
    // EOF
    try testing.expect((try nextChunk(&reader, .riff, .little)) == null);
}

test "chunk: W64 头与 8 字节对齐" {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(testing.allocator);
    // riff GUID + filesize + wave GUID
    try bytes.appendSlice(testing.allocator, &riff_guid);
    var sz: [8]u8 = undefined;
    std.mem.writeInt(u64, @ptrCast(&sz), 0x100, .little);
    try bytes.appendSlice(testing.allocator, &sz);
    try bytes.appendSlice(testing.allocator, &wave_guid);
    // fmt GUID + size(24+16=40) + payload 16
    try bytes.appendSlice(testing.allocator, &fmt_guid);
    std.mem.writeInt(u64, @ptrCast(&sz), 40, .little);
    try bytes.appendSlice(testing.allocator, &sz);
    try bytes.appendSlice(testing.allocator, &[_]u8{0} ** 16);

    var reader = io.Reader.openMem(bytes.items);
    try testing.expect(try checkW64Header(&reader));
    const c = (try nextChunk(&reader, .w64, .little)).?;
    try testing.expectEqualStrings("fmt ", &c.id);
    try testing.expectEqual(@as(u64, 16), c.size); // 40 - 24
    try skipChunk(&reader, c, .w64);
    try testing.expect((try nextChunk(&reader, .w64, .little)) == null);
}

test "chunk: AIFF 头与奇对齐" {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(testing.allocator);
    try bytes.appendSlice(testing.allocator, "FORM\x00\x00\x00\x20AIFF");
    try bytes.appendSlice(testing.allocator, "COMM\x00\x00\x00\x12"); // 18 字节
    try bytes.appendSlice(testing.allocator, &[_]u8{0} ** 18);
    try bytes.appendSlice(testing.allocator, &[_]u8{0}); // pad

    var reader = io.Reader.openMem(bytes.items);
    try testing.expectEqual(false, (try checkAiffHeader(&reader)).?);
    const c = (try nextChunk(&reader, .aiff, .big)).?;
    try testing.expectEqualStrings("COMM", &c.id);
    try testing.expectEqual(@as(u64, 18), c.size);
    try skipChunk(&reader, c, .aiff);
    try testing.expect((try nextChunk(&reader, .aiff, .big)) == null);
}
