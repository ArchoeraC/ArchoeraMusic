// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! WMA Voice 位读写器——复刻 FFmpeg GetBitContext / PutBitContext 语义。
//!
//! MSB-first（FFmpeg bitstream 序）。读取越过 `size_in_bits` 时按缓冲末尾零
//! 填充返回 0（FFmpeg 对每个 packet 缓冲零填充 AV_INPUT_BUFFER_PADDING_SIZE；
//! 本内核调用方保证传入 64 字节零填充的缓冲，等价）。PutBits 同序写出。

const std = @import("std");

/// 大端（MSB-first）bit reader。
pub const Bits = struct {
    buf: []const u8,
    size_in_bits: u32,
    index: u32 = 0, // 位游标（可越过 size_in_bits）

    pub fn init(buf: []const u8) Bits {
        return .{ .buf = buf, .size_in_bits = @intCast(buf.len * 8) };
    }
    pub fn initSizeBits(buf: []const u8, nbits: u32) Bits {
        return .{ .buf = buf, .size_in_bits = nbits };
    }
    pub fn count(self: *const Bits) u32 {
        return self.index;
    }
    pub fn left(self: *const Bits) i64 {
        return @as(i64, self.size_in_bits) - @as(i64, self.index);
    }
    pub fn data(self: *const Bits) []const u8 {
        return self.buf;
    }
    inline fn byteAt(self: *const Bits, idx: usize) u8 {
        return if (idx < self.buf.len) self.buf[idx] else 0;
    }

    /// 读 n（0..32）位，MSB-first。
    pub fn get(self: *Bits, n: u32) u32 {
        if (n == 0) return 0;
        const start = self.index;
        self.index += n;
        return self.readRange(start, n);
    }

    pub fn getBits(self: *Bits, n: u32) u32 {
        return self.get(n);
    }
    pub fn get1(self: *Bits) u32 {
        return self.get(1);
    }
    pub fn skip(self: *Bits, n: u32) void {
        self.index += n;
    }
    /// 读 n 位不进位（peek）。
    pub fn peek(self: *const Bits, n: u32) u32 {
        if (n == 0) return 0;
        return self.readRange(self.index, n);
    }

    fn readRange(self: *const Bits, start: u32, n: u32) u32 {
        var result: u32 = 0;
        var p: u32 = 0;
        while (p < n) : (p += 1) {
            const pos = start + p;
            const b = self.byteAt(pos >> 3);
            const bit: u32 = (b >> @intCast(7 - (pos & 7))) & 1;
            result = (result << 1) | bit;
        }
        return result;
    }
};

/// MSB-first bit writer（用于 sframe_cache spillover 拼接）。
pub const PutBits = struct {
    buf: []u8,
    bit_index: u32 = 0, // 已写位数

    pub fn init(buf: []u8) PutBits {
        return .{ .buf = buf };
    }
    pub fn put(self: *PutBits, nbits: u32, value: u32) void {
        if (nbits == 0) return;
        var idx = self.bit_index;
        const value_l: u64 = value;
        var n = nbits;
        while (n > 0) {
            const byte = idx >> 3;
            const off: u32 = idx & 7;
            const take: u32 = @min(n, 8 - off);
            const slice: u32 = @intCast((value_l >> @intCast(n - take)) & ((@as(u64, 1) << @intCast(take)) - 1));
            var k: u32 = 0;
            while (k < take) : (k += 1) {
                const bit: u8 = @intCast((slice >> @intCast(take - 1 - k)) & 1);
                const pos: u3 = @intCast(7 - off - k);
                const m: u8 = @as(u8, 1) << pos;
                self.buf[byte] = (self.buf[byte] & ~m) | (if (bit != 0) m else 0);
            }
            n -= take;
            idx += take;
        }
        self.bit_index = idx;
    }
    pub fn flush(self: *PutBits) void {
        _ = self;
    }
    pub fn count(self: *const PutBits) u32 {
        return self.bit_index;
    }
};

test "bitio roundtrip" {
    var store = [_]u8{ 0 } ** 8;
    var pb = PutBits.init(&store);
    pb.put(4, 0b1010);
    pb.put(4, 0b0101);
    pb.put(8, 0b01011010);
    pb.put(16, 0x0FF0);
    pb.flush();
    var br = Bits.init(&store);
    try std.testing.expectEqual(@as(u32, 0b1010), br.get(4));
    try std.testing.expectEqual(@as(u32, 0b0101), br.get(4));
    try std.testing.expectEqual(@as(u32, 0b01011010), br.get(8));
    try std.testing.expectEqual(@as(u32, 0x0FF0), br.get(16));
    // 32 bits 全零读满
    try std.testing.expectEqual(@as(u32, 0), br.get(32));
}

test "bitio skip bits in range" {
    var store = [_]u8{ 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA };
    var br = Bits.init(&store);
    br.skip(3);
    try std.testing.expectEqual(@as(u32, 0x2AAAAAAA), br.get(31));
}
