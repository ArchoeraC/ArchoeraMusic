// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! 采样格式转换（docs/audio-kernel-zig.md §10.1）
//!
//! 原生交错 PCM（s8/s16/s24/s32/f32/f64 + f16）→ float32 交错。
//! 位深提升 + 归一化（s16 → /32768，s24 → /8388608，s32 → /2³¹），
//! 逐样本、无滤波器、无状态——成本接近 memcpy。
//!
//! 约定：
//!   - 8-bit PCM 为**无符号**（0..255，中心 128）；
//!   - 16/24/32/64-bit 整数为二进制补码有符号；float 为 IEEE-754
//!     （16-bit float 为 IEEE half，2 字节/样本）；
//!   - `endian` 显式传入（WAV/RIFX 等大端变体依赖此，见 fmt/wav/）；
//!   - `bits` 仅接受 8/16/24/32/64（`fmt/wav/` 的 decl 解析已保证，
//!     桥接层不得对其它值调用本函数）。
//!
//! 尺寸语义：`src.len` 不必是 `frames*channels*bytes_per` 的精确整数倍，
//! 返回实际转换的样本数（不足一整个样本的尾部忽略）。

const std = @import("std");
const builtin = @import("builtin");

/// 将原生交错 PCM 转换为 float32 交错，返回写入 `out` 的样本数。
/// 调用方保证 `out.len >= src.len / (bits/8)`。
pub fn toFloat(
    out: []f32,
    src: []const u8,
    bits: u8,
    is_float: bool,
    endian: std.builtin.Endian,
) usize {
    const bytes_per = @as(usize, bits) / 8;
    const n = @min(out.len, src.len / bytes_per);
    switch (bits) {
        8 => {
            // 无符号 PCM：0..255 → [-1, +1)
            for (0..n) |i| {
                out[i] = @as(f32, @floatFromInt(@as(i32, src[i]) - 128)) * (1.0 / 128.0);
            }
        },
        16 => {
            if (is_float) {
                // IEEE half（f16）→ float32（半精度转单精度）
                for (0..n) |i| {
                    const v = std.mem.readInt(u16, src[i * 2 ..][0..2], endian);
                    out[i] = @floatCast(@as(f16, @bitCast(v)));
                }
            } else {
                const inv = 1.0 / 32768.0;
                for (0..n) |i| {
                    const v = std.mem.readInt(i16, src[i * 2 ..][0..2], endian);
                    out[i] = @as(f32, @floatFromInt(v)) * inv;
                }
            }
        },
        24 => {
            const inv = 1.0 / 8388608.0;
            for (0..n) |i| {
                out[i] = @as(f32, @floatFromInt(readI24(src[i * 3 ..][0..3], endian))) * inv;
            }
        },
        32 => {
            if (is_float) {
                // IEEE float32：逐位直通（0 拷贝）
                for (0..n) |i| {
                    out[i] = @bitCast(std.mem.readInt(u32, src[i * 4 ..][0..4], endian));
                }
            } else {
                const inv = 1.0 / 2147483648.0; // 2^31
                for (0..n) |i| {
                    const v = std.mem.readInt(i32, src[i * 4 ..][0..4], endian);
                    out[i] = @as(f32, @floatFromInt(v)) * inv;
                }
            }
        },
        64 => {
            if (is_float) {
                // IEEE float64 → float32
                for (0..n) |i| {
                    const v = std.mem.readInt(u64, src[i * 8 ..][0..8], endian);
                    out[i] = @floatCast(@as(f64, @bitCast(v)));
                }
            } else {
                const inv = 1.0 / 9223372036854775808.0; // 2^63
                for (0..n) |i| {
                    const v = std.mem.readInt(i64, src[i * 8 ..][0..8], endian);
                    out[i] = @as(f32, @floatFromInt(v)) * inv;
                }
            }
        },
        else => {
            // 契约外位深：测试/安全检查档抓到违约（unreachable），ReleaseFast 绝不 panic
            // （生产由 zkRead 位深护栏/调用方拦截先行；此处兜底为不转换）。
            if (comptime builtin.mode == .Debug or builtin.mode == .ReleaseSafe) unreachable;
            return 0;
        },
    }
    return n;
}

/// 读 24 位有符号整数（符号扩展到 i32）
fn readI24(b: []const u8, endian: std.builtin.Endian) i32 {
    var v: u32 = switch (endian) {
        .little => @as(u32, b[0]) | (@as(u32, b[1]) << 8) | (@as(u32, b[2]) << 16),
        .big => (@as(u32, b[0]) << 16) | (@as(u32, b[1]) << 8) | @as(u32, b[2]),
    };
    // 符号扩展：bit 23 置位则高位填 1
    if (v & 0x80_0000 != 0) v |= 0xFF00_0000;
    return @bitCast(v);
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "convert: 16-bit LE 归一化" {
    var src: [4]u8 = undefined;
    std.mem.writeInt(i16, src[0..2], 32767, .little); // → ≈ 0.99997
    std.mem.writeInt(i16, src[2..4], -32768, .little); // → -1.0
    var out: [2]f32 = undefined;
    const n = toFloat(&out, &src, 16, false, .little);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectApproxEqAbs(@as(f32, 32767.0 / 32768.0), out[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -1.0), out[1], 1e-6);
}

test "convert: 16-bit BE 与 LE 对照" {
    var src: [4]u8 = undefined;
    std.mem.writeInt(i16, src[0..2], 1000, .little);
    std.mem.writeInt(i16, src[2..4], 1000, .big);
    var out: [2]f32 = undefined;
    _ = toFloat(&out, &src, 16, false, .little);
    _ = toFloat(out[1..], src[2..4], 16, false, .big);
    try testing.expectApproxEqAbs(out[0], out[1], 1e-9);
}

test "convert: 24-bit 符号扩展" {
    // -1（0xFF 0xFF 0xFF）与 -8388608（0x80 0x00 0x00）
    const src = [_]u8{ 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x80 };
    var out: [2]f32 = undefined;
    const n = toFloat(&out, &src, 24, false, .little);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectApproxEqAbs(@as(f32, -1.0 / 8388608.0), out[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f32, -1.0), out[1], 1e-6);
}

test "convert: 32-bit 整数" {
    var src: [8]u8 = undefined;
    std.mem.writeInt(i32, src[0..4], 2147483647, .little);
    std.mem.writeInt(i32, src[4..8], -2147483648, .little);
    var out: [2]f32 = undefined;
    _ = toFloat(&out, &src, 32, false, .little);
    try testing.expectApproxEqAbs(@as(f32, 2147483647.0 / 2147483648.0), out[0], 1e-7);
    try testing.expectApproxEqAbs(@as(f32, -1.0), out[1], 1e-7);
}

test "convert: 32-bit float 直通" {
    const vals = [_]f32{ 0.5, -1.25, 3.0 };
    var src: [12]u8 = undefined;
    for (vals, 0..) |v, i| {
        std.mem.writeInt(u32, src[i * 4 ..][0..4], @bitCast(v), .little);
    }
    var out: [3]f32 = undefined;
    const n = toFloat(&out, &src, 32, true, .little);
    try testing.expectEqual(@as(usize, 3), n);
    for (vals, 0..) |v, i| {
        try testing.expectApproxEqAbs(v, out[i], 0.0);
    }
}

test "convert: 64-bit float 降为 f32" {
    var src: [16]u8 = undefined;
    const vals = [_]f64{ 0.25, -1.0 };
    for (vals, 0..) |v, i| {
        std.mem.writeInt(u64, src[i * 8 ..][0..8], @bitCast(v), .big);
    }
    var out: [2]f32 = undefined;
    const n = toFloat(&out, &src, 64, true, .big);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectApproxEqAbs(@as(f32, 0.25), out[0], 1e-7);
    try testing.expectApproxEqAbs(@as(f32, -1.0), out[1], 1e-7);
}

test "convert: 8-bit 无符号（中心 128）" {
    const src = [_]u8{ 128, 255, 0 };
    var out: [3]f32 = undefined;
    const n = toFloat(&out, &src, 8, false, .little);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectApproxEqAbs(@as(f32, 0.0), out[0], 1e-7);
    try testing.expectApproxEqAbs(@as(f32, 127.0 / 128.0), out[1], 1e-7);
    try testing.expectApproxEqAbs(@as(f32, -1.0), out[2], 1e-7);
}

test "convert: 尾部不足一个样本时截断" {
    const src = [_]u8{ 0, 1, 2 }; // 3 字节，16-bit 只有 1.5 样本
    var out: [2]f32 = undefined;
    const n = toFloat(&out, &src, 16, false, .little);
    try testing.expectEqual(@as(usize, 1), n);
}

test "convert: 16-bit IEEE half → f32（LE）" {
    // 1.0 = 0x3C00；-2.0 = 0xC000
    var src: [4]u8 = undefined;
    std.mem.writeInt(u16, src[0..2], 0x3C00, .little);
    std.mem.writeInt(u16, src[2..4], 0xC000, .little);
    var out: [2]f32 = undefined;
    const n = toFloat(&out, &src, 16, true, .little);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectApproxEqAbs(@as(f32, 1.0), out[0], 1e-7);
    try testing.expectApproxEqAbs(@as(f32, -2.0), out[1], 1e-7);
}

test "convert: 16-bit IEEE half BE 与 LE 对照" {
    const vals = [_]f16{ 0.5, -1.25, 1.5 };
    var le: [6]u8 = undefined;
    var be: [6]u8 = undefined;
    for (vals, 0..) |v, i| {
        std.mem.writeInt(u16, le[2 * i ..][0..2], @bitCast(v), .little);
        std.mem.writeInt(u16, be[2 * i ..][0..2], @bitCast(v), .big);
    }
    var out_le: [3]f32 = undefined;
    var out_be: [3]f32 = undefined;
    _ = toFloat(&out_le, &le, 16, true, .little);
    _ = toFloat(&out_be, &be, 16, true, .big);
    for (vals, 0..) |v, i| {
        try testing.expectApproxEqAbs(@as(f32, v), out_le[i], 1e-6);
        try testing.expectApproxEqAbs(@as(f32, v), out_be[i], 1e-6);
    }
}
