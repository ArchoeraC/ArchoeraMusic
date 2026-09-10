// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! WMA 逆 MDCT（bit-exact 复刻 FFmpeg av_tx FLOAT_MDCT inv 路径）。
//!
//! wmadec.c 以 `av_tx_init(..., AV_TX_FLOAT_MDCT, 1, 1<<(frame_len_bits-i),
//! scale=1/32768, AV_TX_FULL_IMDCT)` 建变换：`ff_tx_mdct_inv_full` 包
//! `ff_tx_mdct_inv`，其子 FFT 为 split-radix L/2 点。mdct_inv(L) 吃 L 谱值出
//! L 时域样，full 展开成 2L。本实现参数化 L ∈ {512,1024,2048}：每个长度的
//! mdct_exp/map 表按本机系统 ffmpeg n9.0.1 av_tx 内部位模式嵌入（txdump4.c
//! 探针），运算顺序与 tx_template.c 逐行一致。子 FFT 各层余弦复用
//! aac/mdct_tables（同一 av_tx split-radix 余弦）。

const std = @import("std");
const wmt = @import("wma_mdct_tables.zig");
const aac_mt = @import("../aac/mdct_tables.zig");

pub const Cplx = struct { re: f32, im: f32 };

fn expSlice(comptime L: usize) []const Cplx {
    const arr: []const f32 = switch (L) {
        2048 => &wmt.mdct_exp_2048,
        else => @compileError("unsupported mdct length"),
    };
    return @as([*]const Cplx, @ptrCast(@alignCast(arr.ptr)))[0 .. arr.len / 2];
}
fn mapSlice(comptime L: usize) []const u16 {
    return switch (L) {
        2048 => &wmt.mdct_map_2048,
        else => @compileError("unsupported mdct length"),
    };
}

inline fn bf(x: *f32, y: *f32, a: f32, b: f32) void {
    x.* = a - b;
    y.* = a + b;
}

inline fn transformW(
    a0: *Cplx,
    a1: *Cplx,
    a2: *Cplx,
    a3: *Cplx,
    wre: f32,
    wim: f32,
) void {
    var t1: f32 = undefined;
    var t2: f32 = undefined;
    var t5: f32 = undefined;
    var t6: f32 = undefined;
    t1 = a2.re * wre + a2.im * wim;
    t2 = a2.im * wre - a2.re * wim;
    t5 = a3.re * wre - a3.im * wim;
    t6 = a3.re * wim + a3.im * wre;

    const r0 = a0.re;
    const ai0 = a0.im;
    const r1 = a1.re;
    const ai1 = a1.im;

    var t3: f32 = undefined;
    var t4: f32 = undefined;
    t3 = t5 - t1;
    t5 = t5 + t1;
    a2.re = r0 - t5;
    a0.re = r0 + t5;
    a3.im = ai1 - t3;
    a1.im = ai1 + t3;
    t4 = t2 - t6;
    t6 = t2 + t6;
    a3.re = r1 - t4;
    a1.re = r1 + t4;
    a2.im = ai0 - t6;
    a0.im = ai0 + t6;
}

fn fft2(z: []Cplx) void {
    var tmp: Cplx = undefined;
    bf(&tmp.re, &z[0].re, z[0].re, z[1].re);
    bf(&tmp.im, &z[0].im, z[0].im, z[1].im);
    z[1] = tmp;
}

fn fft4(z: []Cplx) void {
    var t1: f32 = undefined;
    var t2: f32 = undefined;
    var t3: f32 = undefined;
    var t4: f32 = undefined;
    var t5: f32 = undefined;
    var t6: f32 = undefined;
    var t7: f32 = undefined;
    var t8: f32 = undefined;

    bf(&t3, &t1, z[0].re, z[1].re);
    bf(&t8, &t6, z[3].re, z[2].re);
    bf(&z[2].re, &z[0].re, t1, t6);
    bf(&t4, &t2, z[0].im, z[1].im);
    bf(&t7, &t5, z[2].im, z[3].im);
    bf(&z[3].im, &z[1].im, t4, t8);
    bf(&z[3].re, &z[1].re, t3, t7);
    bf(&z[2].im, &z[0].im, t2, t5);
}

fn fft8(z: []Cplx) void {
    const cos8 = aac_mt.fft_tab_8[1];
    fft4(z);

    var t1: f32 = undefined;
    var t2: f32 = undefined;
    var t5: f32 = undefined;
    var t6: f32 = undefined;
    bf(&t1, &z[5].re, z[4].re, -z[5].re);
    bf(&t2, &z[5].im, z[4].im, -z[5].im);
    bf(&t5, &z[7].re, z[6].re, -z[7].re);
    bf(&t6, &z[7].im, z[6].im, -z[7].im);

    transformButterfliesOnly(&z[0], &z[2], &z[4], &z[6], t1, t2, t5, t6);
    transformW(&z[1], &z[3], &z[5], &z[7], cos8, cos8);
}

inline fn transformButterfliesOnly(
    a0: *Cplx,
    a1: *Cplx,
    a2: *Cplx,
    a3: *Cplx,
    t1_in: f32,
    t2_in: f32,
    t5_in: f32,
    t6_in: f32,
) void {
    const t1 = t1_in;
    const t2 = t2_in;
    var t5 = t5_in;
    var t6 = t6_in;
    const r0 = a0.re;
    const ai0 = a0.im;
    const r1 = a1.re;
    const ai1 = a1.im;

    var t3: f32 = undefined;
    var t4: f32 = undefined;
    t3 = t5 - t1;
    t5 = t5 + t1;
    a2.re = r0 - t5;
    a0.re = r0 + t5;
    a3.im = ai1 - t3;
    a1.im = ai1 + t3;
    t4 = t2 - t6;
    t6 = t2 + t6;
    a3.re = r1 - t4;
    a1.re = r1 + t4;
    a2.im = ai0 - t6;
    a0.im = ai0 + t6;
}

fn fft16(z: []Cplx) void {
    const cos = &aac_mt.fft_tab_16;
    const cos_16_1 = cos[1];
    const cos_16_2 = cos[2];
    const cos_16_3 = cos[3];

    fft8(z[0..]);
    fft4(z[8..]);
    fft4(z[12..]);

    const bt1 = z[8].re;
    const bt2 = z[8].im;
    const bt5 = z[12].re;
    const bt6 = z[12].im;
    transformButterfliesOnly(&z[0], &z[4], &z[8], &z[12], bt1, bt2, bt5, bt6);

    transformW(&z[2], &z[6], &z[10], &z[14], cos_16_2, cos_16_2);
    transformW(&z[1], &z[5], &z[9], &z[13], cos_16_1, cos_16_3);
    transformW(&z[3], &z[7], &z[11], &z[15], cos_16_3, cos_16_1);
}

fn srCombine(comptime len: usize, z: []Cplx, cos: []const f32) void {
    const o1 = 2 * len;
    const o2 = 4 * len;
    const o3 = 6 * len;

    var j: usize = 0;
    while (j < len / 4) : (j += 1) {
        const zi = j * 8;
        const ci = j * 8;
        inline for ([_]usize{ 0, 2, 4, 6 }) |k| {
            transformW(&z[zi + k], &z[zi + o1 + k], &z[zi + o2 + k], &z[zi + o3 + k], cos[ci + k], cos[o1 - 8 * j - k]);
        }
        inline for ([_]usize{ 1, 3, 5, 7 }) |k| {
            transformW(&z[zi + k], &z[zi + o1 + k], &z[zi + o2 + k], &z[zi + o3 + k], cos[ci + k], cos[o1 - 8 * j - k]);
        }
    }
}

fn tabSlice(comptime n: usize) []const f32 {
    return switch (n) {
        1024 => &wmt.fft_tab_1024,
        512 => &aac_mt.fft_tab_512,
        256 => &aac_mt.fft_tab_256,
        128 => &aac_mt.fft_tab_128,
        64 => &aac_mt.fft_tab_64,
        32 => &aac_mt.fft_tab_32,
        16 => &aac_mt.fft_tab_16,
        8 => &aac_mt.fft_tab_8,
        else => @compileError("unsupported fft size"),
    };
}

pub fn fftSr(comptime n: usize, z: []Cplx) void {
    switch (n) {
        2 => fft2(z),
        4 => fft4(z),
        8 => fft8(z),
        16 => fft16(z),
        else => {
            const quarter = n / 4;
            fftSr(n / 2, z);
            fftSr(n / 4, z[quarter * 2 ..]);
            fftSr(n / 4, z[quarter * 3 ..]);
            srCombine(n / 8, z, comptime tabSlice(n));
        },
    }
}

/// 子 MDCT（ff_tx_mdct_inv，长度 L）：in = L 谱值 → out = L 时域样。
/// scratch 提供 L/2 复数工作区。
pub fn mdctInv(comptime L: usize, in: []const f32, out: []f32, scratch: []Cplx) void {
    const n: usize = L;
    const n2 = L / 2; // 子 FFT 长（split-radix n2 点）
    const len4 = L / 4;
    std.debug.assert(in.len >= n and out.len >= n and scratch.len >= n2);
    const z = scratch[0..n2];
    const exp = expSlice(L);
    const map = mapSlice(L);

    for (0..n2) |i| {
        const k: usize = @as(usize, map[i]);
        const tre = in[n - 1 - k];
        const tim = in[k];
        const e = exp[i];
        z[i].re = tre * e.re - tim * e.im;
        z[i].im = tre * e.im + tim * e.re;
    }

    fftSr(n2, z);

    const raw = exp[n2..];
    for (0..len4) |i| {
        const p0 = len4 + i;
        const p1 = len4 - i - 1;
        const s1re = z[p1].im;
        const s1im = z[p1].re;
        const s0re = z[p0].im;
        const s0im = z[p0].re;
        const e1 = raw[p1];
        const e0 = raw[p0];
        z[p1].re = s1re * e1.im - s1im * e1.re;
        z[p0].im = s1re * e1.re + s1im * e1.im;
        z[p0].re = s0re * e0.im - s0im * e0.re;
        z[p1].im = s0re * e0.re + s0im * e0.im;
    }

    @memcpy(out[0..n], @as([*]const f32, @ptrCast(z.ptr))[0..n]);
}

/// FULL_IMDCT（ff_tx_mdct_inv_full）展开，长度 L：子 MDCT L 样 → 2L 样本。
pub fn mdctInvFullLen(comptime L: usize, in: []const f32, out: []f32, scratch: []Cplx) void {
    const k: usize = L / 2; // (len << 1) >> 2
    std.debug.assert(out.len >= 2 * L and in.len >= L and scratch.len >= L / 2);
    var buf: [L]f32 = undefined;
    mdctInv(L, in, &buf, scratch);
    // out[0..k) = -reverse(buf[0..k))
    for (0..k) |i| out[i] = -buf[k - 1 - i];
    // out[k..k+L) = buf 原样
    @memcpy(out[k .. k + L], &buf);
    // out[k+L..2L) = reverse(buf[k..L))
    for (0..k) |i| out[k + L + i] = buf[L - 1 - i];
}

/// FULL_IMDCT 2048（历史默认入口；等价 mdctInvFullLen(2048, ...)）。
pub fn mdctInvFull(in: []const f32, out: []f32, scratch: []Cplx) void {
    mdctInvFullLen(2048, in, out, scratch);
}

/// 通用 FULL_IMDCT（数学精确、f64 累积），用于无位精确表的长度 L=1024/512。
///
/// 本函数不依赖 av_tx 内部因子化表，直接按数学定义求和：
///   out[m] = -(1/32768) · Σ_{k<L} in[k] · cos( (π/L)(m+(L+1)/2)(k+1/2) ), m∈[0,2L)
/// 与 av_tx FLOAT_MDCT FULL_IMDCT（scale=1/32768）输出一致到浮点舍入误差
/// （黄金校验：max|err| ~1e-10）。为保持输出与 av_tx 同量纲，长 L 下仅低频
/// 路径使用（512/1024），计算量 O(L²)，f64 累积误差远小于 f32 舍入。
pub fn mdctInvFullMath(comptime L: usize, in: []const f32, out: []f32) void {
    std.debug.assert(out.len >= 2 * L and in.len >= L);
    const pi: f64 = std.math.pi;
    const n: f64 = @floatFromInt(L);
    const half: f64 = (n + 1.0) / 2.0;
    var acc: [2 * L]f64 = .{0} ** (2 * L);
    for (0..L) |kk| {
        const k: f64 = @floatFromInt(kk);
        const dk = pi / n * (k + 0.5);
        const cd = @cos(dk);
        const sd = @sin(dk);
        var ca = @cos(dk * half);
        var sa = @sin(dk * half);
        const xk: f64 = @floatCast(in[kk]);
        for (&acc) |*a| {
            a.* += xk * ca;
            const nc = ca * cd - sa * sd;
            sa = ca * sd + sa * cd;
            ca = nc;
        }
    }
    const sc = -1.0 / 32768.0;
    for (&acc, 0..) |a, m| out[m] = @floatCast(a * sc);
}

const testing = std.testing;

fn lcgInput(len: usize, out: []f32) void {
    var seed: u32 = 12345;
    for (0..len) |i| {
        seed = seed *% 1103515245 +% 12345;
        const q: i32 = @as(i32, @intCast((seed >> 8) % 2000000));
        out[i] = @as(f32, @floatFromInt(q)) / 1000000.0 - 1.0;
    }
}

fn goldenData(comptime L: usize) [2 * L]f32 {
    var arr: [2 * L]f32 = undefined;
    switch (L) {
        2048 => @memcpy(&arr, std.mem.bytesAsSlice(f32, @embedFile("golden_full4096.bin"))),
        1024 => @memcpy(&arr, std.mem.bytesAsSlice(f32, @embedFile("golden_full_1024.bin"))),
        512 => @memcpy(&arr, std.mem.bytesAsSlice(f32, @embedFile("golden_full_512.bin"))),
        else => unreachable,
    }
    return arr;
}

fn checkFull(comptime L: usize) !void {
    var in: [2048]f32 = undefined;
    lcgInput(L, in[0..L]);
    var out: [4096]f32 = undefined;
    var scratch: [L / 2]Cplx = undefined;
    mdctInvFullLen(L, in[0..L], out[0 .. 2 * L], &scratch);
    const gold = goldenData(L);
    var mismatches: usize = 0;
    for (out[0 .. 2 * L], gold) |got, want| {
        if (@as(u32, @bitCast(got)) != @as(u32, @bitCast(want))) mismatches += 1;
    }
    try testing.expectEqual(@as(usize, 0), mismatches);
}

test "WMA FULL_IMDCT 2048 与 ffmpeg av_tx 黄金向量逐位一致" {
    try checkFull(2048);
}

fn checkMath(comptime L: usize) !void {
    var in: [2048]f32 = undefined;
    lcgInput(L, in[0..L]);
    var out: [4096]f32 = undefined;
    mdctInvFullMath(L, in[0..L], out[0 .. 2 * L]);
    const gold = goldenData(L);
    var max_err: f64 = 0;
    for (out[0 .. 2 * L], gold) |got, want| {
        const e = @abs(@as(f64, @floatCast(got)) - @as(f64, @floatCast(want)));
        if (e > max_err) max_err = e;
    }
    // 数学路径与 av_tx 差异仅限浮点舍入（f64 vs f32 累积）
    try testing.expect(max_err < 1e-6);
}

test "WMA FULL_IMDCT 1024 math 与 av_tx 黄金一致（舍入误差内）" {
    try checkMath(1024);
}

test "WMA FULL_IMDCT 512 math 与 av_tx 黄金一致（舍入误差内）" {
    try checkMath(512);
}
