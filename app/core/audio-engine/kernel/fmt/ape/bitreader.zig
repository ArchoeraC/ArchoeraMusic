// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! APE 位读取（GetBitContext 等价，MSB-first，内存缓冲）
//!
//! 供 fileversion < 3900 的熵解码路径使用（decode_array_0000 /
//! ape_decode_value_3860 / init_entropy_decoder 的 32-bit CRC 读取）。
//! 参考重构对照 FFmpeg get_bits.h 的读取语义（许可登记见 audio-engine/THIRD-PARTY-LICENSES.md）。
//!
//! 语义要点（与 FFmpeg GetBitContext 对齐）：
//!   - 字节内 **MSB-first**：第一个读出的是字节的 bit7；
//!   - `unaryStop(stop, len)`：计数直到读到等于 stop 的位，返回 stop 位之前的
//!     连续非 stop 位数（最多 len）；若 len 内未找到 stop 位，消费 len 位并返回 len；
//!   - 越界读返回 error.Corrupt（数据缓冲已由帧解码器按 buf_size 零填充，
//!     合法帧不会越界；FFmpeg 的零填充缓存在此语义等价）。

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

    /// 前进 n 位（对齐 FFmpeg skip_bits_long：无边界校验，越界由后续读取报错）。
    pub fn skipBits(self: *BitReader, n: usize) void {
        self.bit_pos +%= n;
    }

    /// 计数直到读到等于 `stop` 的位（FFmpeg get_unary 语义）。
    /// 返回 stop 位之前连续的非 stop 位数；len 内未命中则消费 len 位并返回 len。
    /// 越界读取按零填充处理（FFmpeg 零填充缓存等价），不报错。
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
