// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! MP3 bitstream reader（MSB-first，对齐 minimp3 bs_t）。
//!
//! 边界语义与 minimp3 get_bits 完全一致：若读取会越过 limit 返回 0，
//! 但 pos 仍已前进。跨字节缓存合并取 n 位。

pub const BitReader = struct {
    buf: []const u8,
    pos: usize = 0, // 位偏移
    limit: usize, // 位上限

    pub fn init(data: []const u8) BitReader {
        return .{ .buf = data, .pos = 0, .limit = data.len * 8 };
    }

    /// 读取 n 位（1<=n<=24，与 minimp3 实际使用一致）。越界返回 0（pos 仍前进）。
    pub fn getBits(self: *BitReader, n: u32) u32 {
        std.debug.assert(n >= 1 and n <= 24);
        var next: u32 = 0;
        var cache: u32 = 0;
        const s: u32 = @intCast(self.pos & 7);
        const shl0: u32 = n + s;
        const p0: usize = self.pos >> 3;
        self.pos += n;
        if (self.pos > self.limit) return 0;
        var p: usize = p0;
        next = self.buf[p] & (@as(u8, 0xff) >> @as(u3, @intCast(s)));
        p += 1;
        // 与原 C `while ((shl -= 8) > 0)` 一致：先减 8 再判。
        var shl: i32 = @intCast(shl0);
        while (true) {
            shl -= 8;
            if (shl <= 0) break;
            cache |= next << @as(u5, @intCast(shl));
            next = self.buf[p];
            p += 1;
        }
        return cache | (next >> @as(u5, @intCast(-shl)));
    }

    pub fn alignByte(self: *BitReader) void {
        self.pos = (self.pos + 7) & ~@as(usize, 7);
    }

    pub fn bytesRemaining(self: *const BitReader) usize {
        const bitrem = if (self.limit > self.pos) self.limit - self.pos else 0;
        return (bitrem + 7) / 8;
    }
};

const testing = std.testing;
const std = @import("std");

test "get_bits 基本读取" {
    const data = [_]u8{ 0xAB, 0xCD, 0xEF };
    var br = BitReader.init(&data);
    try testing.expectEqual(@as(u32, 0xA), br.getBits(4));
    try testing.expectEqual(@as(u32, 0xBC), br.getBits(8));
    try testing.expectEqual(@as(u32, 0xDE), br.getBits(8));
    try testing.expectEqual(@as(u32, 0xF), br.getBits(4));
    try testing.expectEqual(@as(usize, 24), br.pos);
}

test "get_bits 跨字节 & 24 位" {
    const data = [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x9A };
    var br = BitReader.init(&data);
    try testing.expectEqual(@as(u32, 0x123456), br.getBits(24));
    try testing.expectEqual(@as(u32, 0x789A), br.getBits(16));
}

test "get_bits 越界返回 0" {
    const data = [_]u8{ 0xFF, 0xFF };
    var br = BitReader.init(&data);
    try testing.expectEqual(@as(u32, 0xFFFF), br.getBits(16));
    try testing.expectEqual(@as(u32, 0), br.getBits(1)); // 越界
    try testing.expectEqual(@as(usize, 17), br.pos);
}

test "get_bits 非对齐起点" {
    const data = [_]u8{ 0xAA, 0xCC, 0xF0 };
    var br = BitReader.init(&data);
    _ = br.getBits(3); // pos=3
    try testing.expectEqual(@as(u32, 0b0101), br.getBits(4)); // 0xAA 低5位后4位
}
