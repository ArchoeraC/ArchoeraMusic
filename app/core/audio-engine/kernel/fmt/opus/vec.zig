// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! Opus 解码可移植 SIMD 辅助（方向④ B 档：SIMD/浮点重排，仅限**有损**格式，
//! 见 docs/decode-optimization.md §4.2）。
//!
//! 纪律：只用 Zig `@Vector`/`@shuffle`/`@splat`/`@floatFromInt`/`@select`/`@truncate`，
//! **不引入任何平台 intrinsic**；基线目标（无 SSE4.1/AVX）下退化为多条 SSE/标量指令，
//! 语义不变。
//!
//! **位级一致约定**：调用方只把**相互独立**的 lane 打包进向量，且每 lane 的运算顺序
//! 与标量原实现逐条相同（不重结合、不引入 FMA）；因此输出与标量路径逐位相同。

const std = @import("std");

pub const V8 = @Vector(8, f32);
pub const V8i32 = @Vector(8, i32);
pub const V8i16 = @Vector(8, i16);
pub const V16i16 = @Vector(16, i16);

pub inline fn load8(p: [*]const f32) V8 {
    return p[0..8].*;
}

pub inline fn store8(p: [*]f32, v: V8) void {
    p[0..8].* = v;
}

/// 8×f32 → 8×i16，语义与 `lib.f32ToS16` 逐 lane 完全一致：
///   非有限 → 0；否则 `s = trunc(8388608·v)`，clamp 到 ±0x007fff00，再 `(s+128)>>8`。
/// 注意：先做有限性掩码、并在 **f32 域** clamp，避免对 inf/NaN 执行 `@intFromFloat`
/// （未定义/poison）；clamp 边界 0x007fff00 在 f32 精确可表示，故与标量整型 clamp 等价。
pub inline fn f32ToS16x8(v: V8) V8i16 {
    const mag = @abs(v);
    const finite = mag < @as(V8, @splat(std.math.inf(f32)));
    const scaled = v * @as(V8, @splat(8388608.0));
    const clamped = @min(@max(scaled, @as(V8, @splat(-0x007fff00.0))), @as(V8, @splat(0x007fff00.0)));
    const si: V8i32 = @intFromFloat(clamped);
    const sh = (si +% @as(V8i32, @splat(128))) >> @as(V8i32, @splat(8));
    const narrow: V8i16 = @truncate(sh);
    return @select(i16, finite, narrow, @as(V8i16, @splat(0)));
}

/// 两组 8×i16 交错为 16×i16（结果 lane 2k=l[k]，2k+1=r[k]）。
pub inline fn interleave8(l: V8i16, r: V8i16) V16i16 {
    return @shuffle(i16, l, r, [16]i32{ 0, -1, 1, -2, 2, -3, 3, -4, 4, -5, 5, -6, 6, -7, 7, -8 });
}

pub inline fn store16i16(p: [*]i16, v: V16i16) void {
    p[0..16].* = @bitCast(v);
}

/// 就地缩放：x[i] *= g（逐 lane 一次乘法，位级等同标量）。
pub inline fn scaleInPlace(x: []f32, g: f32) void {
    const vg: V8 = @splat(g);
    const p: [*]f32 = x.ptr;
    var i: usize = 0;
    while (i + 8 <= x.len) : (i += 8) {
        store8(p + i, load8(p + i) * vg);
    }
    while (i < x.len) : (i += 1) x[i] *= g;
}

/// dst[i] = g * src[i]（逐 lane 一次乘法，位级等同标量）。
pub inline fn scaleCopy(dst: []f32, src: []const f32, g: f32) void {
    const vg: V8 = @splat(g);
    const dp: [*]f32 = dst.ptr;
    const sp: [*]const f32 = src.ptr;
    var i: usize = 0;
    while (i + 8 <= dst.len) : (i += 8) {
        store8(dp + i, load8(sp + i) * vg);
    }
    while (i < dst.len) : (i += 1) dst[i] = g * src[i];
}

/// dst[i] = (dst[i] + src[i]) / 2（先加后乘 0.5；f32 下 /2 与 ×0.5 精确等价）。
pub inline fn avgHalfInPlace(dst: []f32, src: []const f32) void {
    const halfv: V8 = @splat(0.5);
    const dp: [*]f32 = dst.ptr;
    const sp: [*]const f32 = src.ptr;
    var i: usize = 0;
    while (i + 8 <= dst.len) : (i += 8) {
        store8(dp + i, (load8(dp + i) + load8(sp + i)) * halfv);
    }
    while (i < dst.len) : (i += 1) dst[i] = (dst[i] + src[i]) / 2;
}

/// dst[i] = g · f32(src[i])（逐 lane 精确 i32→f32，再一次乘法）。
pub inline fn intToFloatScale(src: []const i32, dst: []f32, g: f32) void {
    const vg: V8 = @splat(g);
    const sp: [*]const i32 = src.ptr;
    const dp: [*]f32 = dst.ptr;
    var i: usize = 0;
    while (i + 8 <= dst.len) : (i += 8) {
        const vi: V8i32 = sp[i..][0..8].*;
        store8(dp + i, @as(V8, @floatFromInt(vi)) * vg);
    }
    while (i < dst.len) : (i += 1) dst[i] = g * @as(f32, @floatFromInt(src[i]));
}

/// dst[0..len] = src[0..len]（**正向**块拷贝）。前置：`dst ≤ src` 且 `src-dst ≥ 8`，
/// 此时每个 8-lane 块先 load 后 store，任何块的读地址都落在更晚才写的位置，
/// 语义与逐元素正向 `memmove` 完全一致（CELT 的 `buf` 前移满足该前提）。
pub inline fn copyForwardsGap8(dst: [*]f32, src: [*]const f32, len: usize) void {
    var i: usize = 0;
    while (i + 8 <= len) : (i += 8) {
        store8(dst + i, load8(src + i));
    }
    while (i < len) : (i += 1) dst[i] = src[i];
}

// ---------------------------------------------------------------------------
// 测试：向量路径与标量参考**逐位一致**（B 档纪律）
// ---------------------------------------------------------------------------

const testing = std.testing;

/// lib.zig `f32ToS16` 的标量参考副本（限 |v| ≤ 255，避免标量侧 @intFromFloat 越界）。
fn refF32ToS16(v: f32) i16 {
    if (!std.math.isFinite(v)) return 0;
    var s: i32 = @intFromFloat(8388608.0 * v);
    if (s > 0x007fff00) s = 0x007fff00;
    if (s < -0x007fff00) s = -0x007fff00;
    return @intCast((s + 128) >> 8);
}

test "vec: f32ToS16x8 与标量逐位一致（含特殊值/边界）" {
    const specials = [_]f32{
        0.0,  -0.0, 1.0,  -1.0,                          std.math.inf(f32), -std.math.inf(f32),
        std.math.nan(f32), 0.5 / 8388608.0, -0.5 / 8388608.0, 1.5 / 8388608.0,
        8388352.0 / 8388608.0,      // 正饱和边界 0x007fff00
        -8388352.0 / 8388608.0,     // 负饱和边界
        (8388352.0 + 256.0) / 8388608.0, // 越过正饱和
        -(8388096.0) / 8388608.0,
        32767.0 / 32768.0, -32768.0 / 32768.0,
    };
    var prng = std.Random.DefaultPrng.init(0x51d0_0f17);
    const rnd = prng.random();
    var round: usize = 0;
    while (round < 40_000) : (round += 1) {
        var src: [8]f32 = undefined;
        for (0..8) |k| {
            src[k] = switch ((round + k) % 4) {
                0 => specials[(round + k) % specials.len],
                1 => rnd.float(f32) * 2.0 - 1.0,
                2 => (rnd.float(f32) * 2.0 - 1.0) * 255.0,
                else => rnd.float(f32) - 0.5,
            };
        }
        const got = f32ToS16x8(src[0..8].*);
        const got_arr: [8]i16 = got;
        for (0..8) |k| {
            try testing.expectEqual(refF32ToS16(src[k]), got_arr[k]);
        }
    }
}

test "vec: scaleInPlace/scaleCopy/avgHalf/intToFloat 与标量逐位一致" {
    var prng = std.Random.DefaultPrng.init(0xabcdef);
    const rnd = prng.random();
    var a: [64]f32 = undefined;
    var b: [64]f32 = undefined;
    for (0..64) |i| {
        a[i] = rnd.float(f32) * 4.0 - 2.0;
        b[i] = rnd.float(f32) * 4.0 - 2.0;
    }
    const g: f32 = rnd.float(f32) * 2.0 - 1.0;

    var a_ref: [64]f32 = a;
    for (0..64) |i| a_ref[i] *= g;
    var a_vec: [64]f32 = a;
    scaleInPlace(a_vec[0..], g);
    try testing.expectEqualSlices(f32, &a_ref, &a_vec);

    var c_ref: [64]f32 = undefined;
    for (0..64) |i| c_ref[i] = g * a[i];
    var c_vec: [64]f32 = undefined;
    scaleCopy(c_vec[0..], a[0..], g);
    try testing.expectEqualSlices(f32, &c_ref, &c_vec);

    var d_ref: [64]f32 = a;
    for (0..64) |i| d_ref[i] = (a[i] + b[i]) / 2;
    var d_vec: [64]f32 = a;
    avgHalfInPlace(d_vec[0..], b[0..]);
    try testing.expectEqualSlices(f32, &d_ref, &d_vec);

    var si: [64]i32 = undefined;
    for (0..64) |i| si[i] = @rem(rnd.int(i32), 100000);
    var f_ref: [64]f32 = undefined;
    for (0..64) |i| f_ref[i] = g * @as(f32, @floatFromInt(si[i]));
    var f_vec: [64]f32 = undefined;
    intToFloatScale(si[0..], f_vec[0..], g);
    try testing.expectEqualSlices(f32, &f_ref, &f_vec);
}

test "vec: copyForwardsGap8 与逐元素正向拷贝一致（gap ≥ 8）" {
    var buf: [256]f32 = undefined;
    for (0..256) |i| buf[i] = @floatFromInt(i);
    const expect: [256]f32 = buf;
    const gap: usize = 13;
    const len: usize = 40;
    var refv: [256]f32 = buf;
    for (0..len) |k| refv[k] = refv[k + gap];
    copyForwardsGap8(buf[0..].ptr, buf[gap..].ptr, len);
    try testing.expectEqualSlices(f32, refv[0..len], buf[0..len]);
    try testing.expectEqualSlices(f32, expect[len..], buf[len..]);
}
