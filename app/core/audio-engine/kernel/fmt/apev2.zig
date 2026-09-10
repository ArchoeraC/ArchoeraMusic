// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! APEv2 标签解析（APE / WavPack / Musepack 共用）。
//!
//! 结构（tag 位于文件尾，footer 32B）：
//!   "APETAGEX" | version(4 LE) | tag_size(4 LE) | item_count(4 LE) |
//!   flags(4 LE) | reserved(8)
//! flags bit31 = 含 header、bit30 = 本块是 header。item：
//!   value_size(4 LE) | item_flags(4 LE) | key(NUL 终止) | value(value_size)
//! item type = (flags>>1)&3：0=UTF-8 文本、1=二进制、2=外部定位（仅文本映射标准字段）。
//!
//! 生命周期：`Tags` 持有全部分配，`deinit` 释放。

const std = @import("std");
const io = @import("../io.zig");
const decoder = @import("../decoder.zig");
const Error = @import("../error.zig").Error;

const magic = "APETAGEX";
const max_tag_bytes: usize = 16 * 1024 * 1024;

pub const Tags = struct {
    meta: decoder.Metadata = .{},
    tags: []decoder.Tag = &.{},

    pub fn deinit(self: *Tags, allocator: std.mem.Allocator) void {
        inline for (.{ &self.meta.title, &self.meta.artist, &self.meta.album, &self.meta.date, &self.meta.genre, &self.meta.comment }) |p| {
            if (p.*) |s| {
                allocator.free(s);
                p.* = null;
            }
        }
        for (self.tags) |t| {
            allocator.free(t.key);
            allocator.free(t.value);
        }
        if (self.tags.len > 0) allocator.free(self.tags);
        self.tags = &.{};
        self.meta = .{};
    }
};

const field_map = std.StaticStringMap(usize).initComptime(.{
    .{ "TITLE", 0 },
    .{ "ARTIST", 1 },
    .{ "ALBUM", 2 },
    .{ "YEAR", 3 },
    .{ "DATE", 3 },
    .{ "GENRE", 4 },
    .{ "COMMENT", 5 },
});

fn readAt(reader: *io.Reader, off: u64, dst: []u8) Error!void {
    try reader.seek(@intCast(off), .start);
    const n = try reader.read(dst);
    if (n != dst.len) return error.Corrupt;
}

/// 解析文件尾的 APEv2 标签；无标签返回空 `Tags`（非错误）。
pub fn parse(allocator: std.mem.Allocator, reader: *io.Reader, file_size: u64) Error!Tags {
    var out = Tags{};
    if (file_size < 32) return out;

    var foot: [32]u8 = undefined;
    try readAt(reader, file_size - 32, &foot);
    if (!std.mem.eql(u8, foot[0..8], magic)) return out;

    const tag_size: u64 = std.mem.readInt(u32, foot[12..16], .little);
    const count: u32 = std.mem.readInt(u32, foot[16..20], .little);
    const flags: u32 = std.mem.readInt(u32, foot[20..24], .little);
    const has_header = (flags & (@as(u32, 1) << 31)) != 0;
    const is_header = (flags & (@as(u32, 1) << 30)) != 0;
    if (is_header or tag_size < 32 or count == 0) return out;

    const footer_off = file_size - 32;
    const items_start: u64 = if (has_header)
        (footer_off + 32) -| tag_size
    else
        footer_off -| tag_size;
    if (items_start >= footer_off) return out;
    const len: usize = @intCast(footer_off - items_start);
    if (len > max_tag_bytes) return out;

    const buf = try allocator.alloc(u8, len);
    defer allocator.free(buf);
    try readAt(reader, items_start, buf);

    var tags: std.ArrayList(decoder.Tag) = .empty;
    errdefer {
        for (tags.items) |t| {
            allocator.free(t.key);
            allocator.free(t.value);
        }
        tags.deinit(allocator);
    }

    var pos: usize = 0;
    var i: u32 = 0;
    while (i < count and pos + 8 <= len) : (i += 1) {
        const vsize: usize = std.mem.readInt(u32, buf[pos..][0..4], .little);
        const iflags: u32 = std.mem.readInt(u32, buf[pos + 4 ..][0..4], .little);
        pos += 8;
        const kend = std.mem.indexOfScalar(u8, buf[pos..], 0) orelse break;
        const key = buf[pos .. pos + kend];
        pos += kend + 1;
        if (vsize > len - pos) break;
        const value = buf[pos .. pos + vsize];
        pos += vsize;
        if (key.len == 0) continue;

        const k = try allocator.dupe(u8, key);
        errdefer allocator.free(k);
        const v = try allocator.dupe(u8, value);
        errdefer allocator.free(v);
        try tags.append(allocator, .{ .key = k, .value = v });

        const item_type = (iflags >> 1) & 3;
        if (item_type != 0) continue; // 仅 UTF-8 文本映射标准字段
        var upper: [64]u8 = undefined;
        if (key.len > upper.len) continue;
        for (key, 0..) |ch, idx| upper[idx] = std.ascii.toUpper(ch);
        const slot = field_map.get(upper[0..key.len]) orelse continue;
        const s = try allocator.dupeZ(u8, value);
        switch (slot) {
            0 => out.meta.title = s,
            1 => out.meta.artist = s,
            2 => out.meta.album = s,
            3 => out.meta.date = s,
            4 => out.meta.genre = s,
            else => out.meta.comment = s,
        }
    }

    out.tags = try tags.toOwnedSlice(allocator);
    out.meta.tags = out.tags;
    return out;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "apev2: 解析尾部标签（文本项映射标准字段 + 全量 tags）" {
    var buf: [512]u8 = undefined;
    var n: usize = 0;
    const items = [_]struct { k: []const u8, v: []const u8 }{
        .{ .k = "Title", .v = "Hello" },
        .{ .k = "Artist", .v = "World" },
        .{ .k = "Track", .v = "7" },
    };
    for (items) |it| {
        std.mem.writeInt(u32, buf[n..][0..4], @intCast(it.v.len), .little);
        n += 4;
        std.mem.writeInt(u32, buf[n..][0..4], 0, .little); // item flags: UTF-8 text
        n += 4;
        @memcpy(buf[n .. n + it.k.len], it.k);
        n += it.k.len;
        buf[n] = 0;
        n += 1;
        @memcpy(buf[n .. n + it.v.len], it.v);
        n += it.v.len;
    }
    const items_len = n;
    // footer（无 header）：tag_size = items + 32
    const tag_size: u32 = @intCast(items_len + 32);
    @memcpy(buf[n .. n + 8], magic);
    n += 8;
    std.mem.writeInt(u32, buf[n..][0..4], 2000, .little);
    n += 4;
    std.mem.writeInt(u32, buf[n..][0..4], tag_size, .little);
    n += 4;
    std.mem.writeInt(u32, buf[n..][0..4], @intCast(items.len), .little);
    n += 4;
    std.mem.writeInt(u32, buf[n..][0..4], 0, .little); // flags: 无 header、本块是 footer
    n += 4;
    @memset(buf[n .. n + 8], 0);
    n += 8;
    const total = n;

    var reader = io.Reader.openMem(buf[0..total]);
    var tags = try parse(testing.allocator, &reader, total);
    defer tags.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), tags.tags.len);
    try testing.expectEqualStrings("Hello", tags.meta.title.?);
    try testing.expectEqualStrings("World", tags.meta.artist.?);
    try testing.expect(tags.meta.album == null);
    try testing.expectEqualStrings("Title", tags.tags[0].key);
    try testing.expectEqualStrings("Hello", tags.tags[0].value);
}

test "apev2: 非 APE 尾返回空（非错误）" {
    var buf = [_]u8{0} ** 64;
    var reader = io.Reader.openMem(&buf);
    var tags = try parse(testing.allocator, &reader, buf.len);
    defer tags.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), tags.tags.len);
    try testing.expect(tags.meta.title == null);
}
