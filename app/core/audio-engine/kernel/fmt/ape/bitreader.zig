// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: LGPL-2.1-or-later
// EraSync — ArchoeraMusic 音频内核
//
// ⚠ 衍生作品：移植 / 转录自 FFmpeg（LGPL-2.1-or-later）对应源文件。
// 上游版权归 FFmpeg 作者所有；本文件中移植部分及本项目改动均按
// LGPL-2.1-or-later 分发，逐文件溯源见 audio-engine/THIRD-PARTY-LICENSES.md。

const std = @import("std");
const Error = @import("../../error.zig").Error;

pub const BitReader = struct {
    data: []const u8,
    bit_pos: usize = 0,

    pub fn init(data: []const u8) BitReader {
        return .{ .data = data };
    }

    /// 剩余可读位数
    pub fn remainingBits(self: *const BitReader) usize {
        return self.data.len * 8 -% self.bit_pos;
    }

    /// 读取 n 位（0..=32），MSB-first 组装。剩余不足 → error.Corrupt。
    pub fn readBits(self: *BitReader, n: u6) Error!u32 {
        if (n == 0) return 0;
        if (self.bit_pos + n > self.data.len * 8) return error.Corrupt;
        var v: u32 = 0;
        var i: u6 = 0;
        while (i < n) : (i += 1) {
            const byte = self.data[self.bit_pos >> 3];
            v = (v << 1) | @as(u32, @intCast((byte >> @intCast(7 - (self.bit_pos & 7))) & 1));
            self.bit_pos += 1;
        }
        return v;
    }

    /// 读取 1 位。剩余不足 → error.Corrupt。
    pub fn readBit(self: *BitReader) Error!u1 {
        if (self.bit_pos >= self.data.len * 8) return error.Corrupt;
        const byte = self.data[self.bit_pos >> 3];
        const bit: u1 = @truncate((byte >> @intCast(7 - (self.bit_pos & 7))) & 1);
        self.bit_pos += 1;
        return bit;
    }

    /// 前进 n 位（对齐 验收基准 skip_bits_long：无边界校验，越界由后续读取报错）。
    pub fn skipBits(self: *BitReader, n: usize) void {
        self.bit_pos +%= n;
    }

    /// 计数直到读到等于 `stop` 的位（验收基准 get_unary 语义）。
    /// 返回 stop 位之前连续的非 stop 位数；len 内未命中则消费 len 位并返回 len。
    /// 越界读取按零填充处理（验收基准 零填充缓存等价），不报错。
    pub fn unaryStop(self: *BitReader, stop: u1, len: usize) usize {
        var i: usize = 0;
        while (i < len) : (i += 1) {
            const b = self.readBit() catch 0;
            if (b == stop) break;
        }
        return i;
    }

    /// 读 32 位（CRC 用）
    pub fn readBitsLong32(self: *BitReader) Error!u32 {
        return self.readBits(32);
    }
};
