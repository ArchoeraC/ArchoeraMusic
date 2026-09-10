// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! WavPack 帧内位读取（LSB-first，内存缓冲）
//!
//! 与 flac/alac bitreader 的区别：
//!   - WavPack 的 DATA 位流为 **LSB-first**（逐字节低位在前），与
//!     FLAC/ALAC 的 MSB-first 相反，故独立实现；
//!   - 需要 `readUnary0_33`（unary 前缀上限 33）与按位读取，均在
//!     熵解码（wv_get_value 的 zigzag 区间分段）中使用；
//!   - 位流独立于字节边界（块内 metadata 与 DATA 各占独立区域）。
//!
//! 健壮性（§13.3）：所有读取先校验剩余位数，越界 → error.Corrupt，
//! 不产生越界读；调用方保证帧缓冲只读不修改。

const std = @import("std");
const Error = @import("../../error.zig").Error;

pub const BitReader = struct {
    data: []const u8,
    /// 已消费位数（字节内偏移 = bit_pos & 7）
    bit_pos: usize = 0,

    pub fn init(data: []const u8) BitReader {
        return .{ .data = data };
    }

    /// 剩余可读位数
    pub fn remainingBits(self: *const BitReader) usize {
        return self.data.len * 8 - self.bit_pos;
    }

    /// 读 1 位（LSB-first）
    pub fn readBit(self: *BitReader) Error!u1 {
        if (self.bit_pos >= self.data.len * 8) return error.Corrupt;
        const v: u1 = @intCast((self.data[self.bit_pos >> 3] >> @intCast(self.bit_pos & 7)) & 1);
        self.bit_pos += 1;
        return v;
    }

    /// 读 n 位（0..=32），LSB-first 组装为无符号整数。
    /// 剩余不足 → error.Corrupt。
    pub fn readBits(self: *BitReader, n: u6) Error!u32 {
        if (n > 32) return error.Corrupt;
        if (self.bit_pos + n > self.data.len * 8) return error.Corrupt;
        var out: u32 = 0;
        var need: u6 = n;
        while (need > 0) {
            const byte: u8 = self.data[self.bit_pos >> 3];
            const bit_in_byte: u3 = @intCast(self.bit_pos & 7);
            const take: u6 = @intCast(@min(@as(u6, need), @as(u6, 8) - bit_in_byte));
            const v: u32 = (byte >> bit_in_byte) & ((@as(u32, 1) << @intCast(take)) - 1);
            out |= v << @intCast(n - need);
            self.bit_pos += take;
            need -= take;
        }
        return out;
    }

    /// unary：数连续 1 位直到首个 0（0 被消耗）；无 0 时消耗 max 位并返回 max。
    /// stop 位为 0；max 为读取上限（超限即返回 max 且不报错）。
    pub fn readUnary0(self: *BitReader, max: u8) Error!u32 {
        var count: u32 = 0;
        while (count < max) : (count += 1) {
            if (try self.readBit() == 0) break;
        }
        return count;
    }
};

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "wv bitreader: LSB-first 位序 + 跨字节读取" {
    // 0x6C = 0b01101100（bit0..7 = 0,0,1,1,0,1,1,0）
    var br = BitReader.init(&.{ 0x6C, 0xB1 });
    try testing.expectEqual(@as(u32, 0b100), try br.readBits(3)); // bit0..2 = 0,0,1
    try testing.expectEqual(@as(u32, 0b01101), try br.readBits(5)); // bit3..7 = 1,0,1,1,0
    // 0xB1 = 0b10110001（bit0..7 = 1,0,0,0,1,1,0,1）→ LSB 组装 = 0xB1 = 177
    try testing.expectEqual(@as(u32, 177), try br.readBits(8));
    try testing.expectEqual(@as(usize, 0), br.remainingBits());
}

test "wv bitreader: readBits 越界 → Corrupt" {
    var br = BitReader.init(&.{ 0xFF, 0xFF });
    _ = try br.readBits(16);
    try testing.expectError(error.Corrupt, br.readBits(1));
    try testing.expectError(error.Corrupt, br.readBits(33));
}

test "wv bitreader: readBit 逐位（LSB-first）" {
    // 0x1B = 0b00011011 → 位序：1,1,0,1,1,0,0,0
    var br = BitReader.init(&.{0x1B});
    const expect = [_]u1{ 1, 1, 0, 1, 1, 0, 0, 0 };
    for (expect) |e| {
        try testing.expectEqual(e, try br.readBit());
    }
}

test "wv bitreader: readUnary0（stop=0）语义" {
    // 0x13 = 0b00010011：LSB 起 1,1,0 → unary = 2；随后 bit3=0 → unary = 0
    var br = BitReader.init(&.{0x13});
    try testing.expectEqual(@as(u32, 2), try br.readUnary0(33));
    try testing.expectEqual(@as(u32, 0), try br.readUnary0(33));
    // 全 1 流：max 内未遇 0 → 消耗 max 位并返回 max
    var br1 = BitReader.init(&.{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF });
    try testing.expectEqual(@as(u32, 33), try br1.readUnary0(33));
    try testing.expectEqual(@as(usize, 7), br1.remainingBits()); // 40 - 33
}
