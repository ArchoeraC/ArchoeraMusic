// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! 共享可移植 SIMD 辅助（当前仅 AAC 引用）。
//!
//! 纪律：只使用 Zig `@Vector` / `@shuffle` / `@splat` / `@bitCast`，**不引入任何平台
//! intrinsic**；`-Dtarget=x86_64-windows-gnu` 等基线目标同样可编译（无 AVX 时退化为多
//! 条 SSE/标量指令，语义不变）。
//!
//! 位级一致约定：调用方只把**相互独立**的 lane 打包进向量，且每 lane 的运算顺序与
//! 标量原实现逐条相同（不重结合、不引入 FMA）；这样输出与标量路径逐位相同。

pub const V4 = @Vector(4, f32);
pub const V8 = @Vector(8, f32);
pub const V16 = @Vector(16, f32);

pub inline fn load4(p: [*]const f32) V4 {
    return @bitCast(p[0..4].*);
}
pub inline fn store4(p: [*]f32, v: V4) void {
    p[0..4].* = @bitCast(v);
}

pub inline fn load8(p: [*]const f32) V8 {
    return @bitCast(p[0..8].*);
}
pub inline fn store8(p: [*]f32, v: V8) void {
    p[0..8].* = @bitCast(v);
}

/// 8 lane 反序：结果 lane k = 输入 lane (7-k)。
pub inline fn rev8(v: V8) V8 {
    return @shuffle(f32, v, v, [8]i32{ 7, 6, 5, 4, 3, 2, 1, 0 });
}

/// 4 lane 反序：结果 lane k = 输入 lane (3-k)。
pub inline fn rev4(v: V4) V4 {
    return @shuffle(f32, v, v, [4]i32{ 3, 2, 1, 0 });
}

pub const Deinterleaved8 = struct { re: V8, im: V8 };

/// 从交错 f32（[re0,im0,re1,im1,…]）取 8 个复数为 (re,im) 两个 V8。
pub inline fn loadDeinterleave8(p: [*]const f32) Deinterleaved8 {
    const a: V16 = @bitCast(p[0..16].*);
    return .{
        .re = @shuffle(f32, a, undefined, [8]i32{ 0, 2, 4, 6, 8, 10, 12, 14 }),
        .im = @shuffle(f32, a, undefined, [8]i32{ 1, 3, 5, 7, 9, 11, 13, 15 }),
    };
}

/// 把 (re,im) 两个 V8 交错写回 [re0,im0,re1,im1,…]。
pub inline fn storeInterleave8(p: [*]f32, re: V8, im: V8) void {
    const a: V16 = @shuffle(f32, re, im, [16]i32{
        0, -1, 1, -2, 2, -3, 3, -4, 4, -5, 5, -6, 6, -7, 7, -8,
    });
    p[0..16].* = @bitCast(a);
}
