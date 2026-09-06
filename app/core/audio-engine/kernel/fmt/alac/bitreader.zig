// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! ALAC 帧内位读取（MSB-first，内存缓冲）
//!
//! 与 flac/bitreader.zig 的区别：
//!   - FLAC 位流经 io.Reader 逐字节取用（支持滚动 CRC）；ALAC 帧为 M4A
//!     sample table 中的独立连续缓冲（大小已知），直接内存读取，零分配；
//!   - 需要 `showBits`（peek 不前进）与 `skipBits`（decode_scalar 的
//!     extrabits 分支按值决定跳过 k 或 k-1 位），flac 版没有这两个原语；
//!   - 字节边界与帧边界一致（m4a sample 即完整 ALAC 帧），无需跨帧语义。
//!
//! 位读取原语（语义为格式既定行为；许可登记见 audio-engine/THIRD-PARTY-LICENSES.md）：
//!   readBits    —— 读 n 位无符号（MSB-first 组装，n ≤ 32）
//!   showBits    —— 查看 n 位但不消耗
//!   skipBits    —— 仅前进 n 位
//!   readSigned  —— 读 n 位并符号扩展为 i32
//!   readUnary0  —— unary 前缀：数连续 1 直到首个 0（stop=0）
//!   alignToByte —— 丢弃不足一字节的残留位，对齐到字节边界
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

    /// 读取 n 位（0..=32），MSB-first 组装为无符号整数。
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
            const shift: u3 = @intCast(@as(u8, 8) - bit_in_byte - take);
            const v: u32 = (byte >> shift) & ((@as(u32, 1) << @intCast(take)) - 1);
            out = (out << @as(u5, @intCast(take))) | v;
            self.bit_pos += take;
            need -= take;
        }
        return out;
    }

    /// 查看 n 位（1..=32）但不消耗。剩余不足 → error.Corrupt。
    pub fn showBits(self: *BitReader, n: u6) Error!u32 {
        if (n == 0) return 0;
        if (n > 32) return error.Corrupt;
        if (self.bit_pos + n > self.data.len * 8) return error.Corrupt;
        var out: u32 = 0;
        var need: u6 = n;
        var pos: usize = self.bit_pos;
        while (need > 0) {
            const byte: u8 = self.data[pos >> 3];
            const bit_in_byte: u3 = @intCast(pos & 7);
            const take: u6 = @intCast(@min(@as(u6, need), @as(u6, 8) - bit_in_byte));
            const shift: u3 = @intCast(@as(u8, 8) - bit_in_byte - take);
            const v: u32 = (byte >> shift) & ((@as(u32, 1) << @intCast(take)) - 1);
            out = (out << @as(u5, @intCast(take))) | v;
            pos += take;
            need -= take;
        }
        return out;
    }

    /// 跳过 n 位（不校验内容；越界 → error.Corrupt）
    pub fn skipBits(self: *BitReader, n: u6) Error!void {
        if (self.bit_pos + n > self.data.len * 8) return error.Corrupt;
        self.bit_pos += n;
    }

    /// 读取 n 位（1..=32）并符号扩展为 i32（LPC 系数 / 未压缩样本用）
    pub fn readSigned(self: *BitReader, n: u6) Error!i32 {
        if (n == 0) return 0;
        const v = try self.readBits(n);
        const shift: u5 = @intCast(32 - n); // 1..=32 → 31..=0
        return @as(i32, @bitCast(v << shift)) >> shift;
    }

    /// unary：数连续 1 位直到首个 0（0 被消耗），无 0 时消耗 max 位并返回 max。
    /// stop 位为 0；max 为读取上限（超限即返回 max 且不报错）。
    pub fn readUnary0(self: *BitReader, max: u8) Error!u32 {
        var count: u32 = 0;
        while (count < max) : (count += 1) {
            if (try self.readBits(1) == 0) break;
        }
        return count;
    }

    /// 丢弃不足一个字节的残留位，对齐到下一字节边界
    pub fn alignToByte(self: *BitReader) void {
        self.bit_pos = (self.bit_pos + 7) & ~@as(usize, 7);
    }
};

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "alac bitreader: MSB-first 位序 + 跨字节读取" {
    // 0xB1 = 0b10110001, 0x6C = 0b01101100
    var br = BitReader.init(&.{ 0xB1, 0x6C });
    try testing.expectEqual(@as(u32, 0b101), try br.readBits(3));
    try testing.expectEqual(@as(u32, 0b10001), try br.readBits(5));
    try testing.expectEqual(@as(u32, 0b01101100), try br.readBits(8));
    try testing.expectEqual(@as(usize, 0), br.remainingBits());
}

test "alac bitreader: readBits 越界 → Corrupt" {
    var br = BitReader.init(&.{ 0xFF, 0xFF });
    _ = try br.readBits(16);
    try testing.expectError(error.Corrupt, br.readBits(1));
    try testing.expectError(error.Corrupt, br.readBits(33));
}

test "alac bitreader: showBits 不消耗 + 与 readBits 一致" {
    // 0xAB 0x00 = 0b10101011 00000000
    var br = BitReader.init(&.{ 0xAB, 0x00 });
    try testing.expectEqual(@as(u32, 0b10101011), try br.showBits(8));
    try testing.expectEqual(@as(usize, 0), br.bit_pos); // 未消耗
    _ = try br.readBits(3);
    try testing.expectEqual(@as(u32, 0b01011), try br.showBits(5));
    try testing.expectEqual(@as(u32, 0b01011), try br.readBits(5));
    try testing.expectEqual(@as(u32, 0b0), try br.readBits(1));
}

test "alac bitreader: readSigned 符号扩展" {
    // 0x87 = 0b1000 0111
    var br = BitReader.init(&.{0x87});
    try testing.expectEqual(@as(i32, -8), try br.readSigned(4)); // 0b1000
    try testing.expectEqual(@as(i32, 7), try br.readSigned(4)); // 0b0111
    // 全 32 位：0xFFFFFFFF → -1
    var br32 = BitReader.init(&.{ 0xFF, 0xFF, 0xFF, 0xFF });
    try testing.expectEqual(@as(i32, -1), try br32.readSigned(32));
}

test "alac bitreader: readUnary0（stop=0）语义" {
    // 0x30 = 0b0011 0000
    var br = BitReader.init(&.{0x30});
    try testing.expectEqual(@as(u32, 0), try br.readUnary0(9)); // 首 bit 0 → 0
    try testing.expectEqual(@as(u32, 0), try br.readUnary0(9)); // 次 bit 0 → 0
    try testing.expectEqual(@as(u32, 2), try br.readUnary0(9)); // 110 → 两个 1 后遇 0 → 2
    // 全 1 流：max 内未遇 0 → 消耗 max 位并返回 max
    var br1 = BitReader.init(&.{ 0xFF, 0xFF });
    try testing.expectEqual(@as(u32, 9), try br1.readUnary0(9));
    try testing.expectEqual(@as(usize, 7), br1.remainingBits()); // 16 - 9
}

test "alac bitreader: skipBits / alignToByte" {
    // 0xF5 = 0b1111 0101
    var br = BitReader.init(&.{ 0xF5, 0xA5 });
    try br.skipBits(3);
    try testing.expectEqual(@as(u32, 0b101), try br.readBits(3));
    try br.skipBits(2);
    try testing.expectEqual(@as(usize, 8), br.bit_pos);
    br.alignToByte(); // 已在字节边界，无变化
    try testing.expectEqual(@as(u32, 0xA5), try br.readBits(8));
    // 非字节边界对齐
    var br2 = BitReader.init(&.{ 0xF5, 0xA5 });
    _ = try br2.readBits(3);
    br2.alignToByte();
    try testing.expectEqual(@as(usize, 8), br2.bit_pos);
    try testing.expectEqual(@as(u32, 0xA5), try br2.readBits(8));
}
