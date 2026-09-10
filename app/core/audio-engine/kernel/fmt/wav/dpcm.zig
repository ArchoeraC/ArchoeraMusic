// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! WAV 内 DPCM 解码（docs/audio-kernel-zig.md §9.1）
//!
//! 支持：
//!   - XAN DPCM（WAV tag 0x594A，codec "xan_dpcm"）：块式，每块开头每通道
//!     predictor(2B LE)，随后每字节 1 样本、声道交替输出；shift[2] 每块
//!     重置为 {4,4}（镜像 FFmpeg dpcm.c dpcm_decode_frame XAN 分支）。
//!
//! 算法与常量重构自 FFmpeg `libavcodec/dpcm.c`（reference/FFmpeg，
//! 参考实现非直接复制）。

const std = @import("std");

/// XAN DPCM 解码一块（block_align 字节：块头 2B/通道 predictor + 数据）。
/// `out` 容量须 >= (src.len - 2*channels) 个 s16（声道交替）。
/// 镜像 FFmpeg dpcm.c 339-369 行：每字节取低 2 位自适应 shift，
/// 高 6 位左移 8 后符号扩展为差分，predictor += diff>>shift 并 clip 到 int16。
pub fn decodeXan(src: []const u8, channels: usize, out: []i16) void {
    var predictor: [2]i32 = .{ 0, 0 };
    var shift: [2]i32 = .{ 4, 4 };
    var pos: usize = 0;
    // 块头：每通道 predictor（le16，符号扩展）
    var c: usize = 0;
    while (c < channels) : (c += 1) {
        predictor[c] = @as(i16, @bitCast(std.mem.readInt(u16, src[pos..][0..2], .little)));
        pos += 2;
    }
    const stereo: usize = channels - 1; // 0 = mono（ch 恒定），1 = 双声道交替
    var ch: usize = 0;
    var o: usize = 0;
    while (pos < src.len) : (pos += 1) {
        const byte = src[pos];
        const n: i32 = byte & 3;
        if (n == 3)
            shift[ch] += 1
        else
            shift[ch] -= 2 * n;
        // (byte & ~3) << 8，16 位符号扩展（镜像 sign_extend(diff &~ 3) << 8, 16）
        var diff: i32 = @as(i32, byte & 0xFC) << 8;
        if (diff & 0x8000 != 0) diff -= 0x10000;
        // av_clip_uintp2(shift, 5) = clamp(0, 31)
        shift[ch] = std.math.clamp(shift[ch], 0, 31);
        diff >>= @intCast(shift[ch]);
        predictor[ch] += diff;
        // av_clip_int16
        out[o] = @intCast(std.math.clamp(predictor[ch], -32768, 32767));
        o += 1;
        ch ^= stereo;
    }
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "dpcm: XAN 块解码（mono，含 shift 自适应）" {
    // 手工构造块：predictor = 100（LE），随后若干差分字节
    var src: [8]u8 = undefined;
    std.mem.writeInt(u16, src[0..2], 100, .little);
    src[2] = 0x04; // n=0 → shift 4；diff = 0x0400>>4 = 64 → pred 164
    src[3] = 0x83; // n=3 → shift 5；diff = 0x8000(负)>>5 = -1024 → pred -860
    src[4] = 0x7F; // n=3 → shift 6；diff = 0x7C00>>6 = 496 → pred -364
    src[5] = 0x3F; // n=3 → shift 7；diff = 0x3C00>>7 = 120 → pred -244
    src[6] = 0x1F; // n=3 → shift 8；diff = 0x1C00>>8 = 28 → pred -216
    src[7] = 0x0C; // n=0 → shift 保持 8；diff = 0x0C00>>8 = 12 → pred -204

    var out: [6]i16 = undefined;
    decodeXan(&src, 1, &out);
    const expect = [_]i16{ 164, -860, -364, -244, -216, -204 };
    try testing.expectEqualSlices(i16, &expect, &out);
}

test "dpcm: XAN 块解码（stereo 声道交替）" {
    // predictor L = -10, R = 20；数据字节交替 L/R
    var src: [8]u8 = undefined;
    std.mem.writeInt(u16, src[0..2], @bitCast(@as(i16, -10)), .little);
    std.mem.writeInt(u16, src[2..4], @bitCast(@as(i16, 20)), .little);
    src[4] = 0x04; // L: n=0 → shift 4 → diff 0x0400>>4 = 64 → pred 54
    src[5] = 0x80; // R: n=0 → shift 4 → diff 0x8000(负)>>4 = -2048 → pred -2028
    src[6] = 0x07; // L: n=3 → shift 5 → diff 0x0400>>5 = 32 → pred 86
    src[7] = 0x03; // R: n=3 → shift 5 → diff 0x0000>>5 = 0 → pred -2028

    var out: [4]i16 = undefined;
    decodeXan(&src, 2, &out);
    const expect = [_]i16{ 54, -2028, 86, -2028 };
    try testing.expectEqualSlices(i16, &expect, &out);
}
