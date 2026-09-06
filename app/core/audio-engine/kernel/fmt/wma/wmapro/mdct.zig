// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! WMA Pro 逆 MDCT（plain inv-MDCT，bit-exact 复刻 FFmpeg n9.0.1 av_tx
//! AV_TX_FLOAT_MDCT inv，非 FULL）。长度 L ∈ {64…2048} 幂次。
//!
//! av_tx mdct_inv(L)：读 L 谱值 → 写 L 时域样，scale 折叠进 exp 表
//! （ff_tx_mdct_gen_exp：exp = RESCALE(cos/sin(alpha)·√|scale|)，alpha 由
//! 长度与 1/8 相位决定）。本模块 exp/map 表为系统 av_tx n9.0.1 位模式转储
//! （mdct_tables.zig，bps=24 scale）；子 FFT 复用 wma_mdct.fftSr（split-radix，
//! 各层余弦取 wma/aac 同源 av_tx 表）。

const std = @import("std");
const wmt = @import("../wma_mdct.zig");
const mt = @import("mdct_tables.zig");

pub const Cplx = wmt.Cplx;

fn expSlice(comptime L: usize) []const Cplx {
    const a: []const f32 = switch (L) {
        64 => &mt.mdct_exp_64,
        128 => &mt.mdct_exp_128,
        256 => &mt.mdct_exp_256,
        512 => &mt.mdct_exp_512,
        1024 => &mt.mdct_exp_1024,
        2048 => &mt.mdct_exp_2048,
        else => @compileError("unsupported mdct length"),
    };
    return @as([*]const Cplx, @ptrCast(@alignCast(a.ptr)))[0 .. a.len / 2];
}

fn mapSlice(comptime L: usize) []const u16 {
    return switch (L) {
        64 => &mt.mdct_map_64,
        128 => &mt.mdct_map_128,
        256 => &mt.mdct_map_256,
        512 => &mt.mdct_map_512,
        1024 => &mt.mdct_map_1024,
        2048 => &mt.mdct_map_2048,
        else => @compileError("unsupported mdct length"),
    };
}

/// plain inv-MDCT，长度 L：in = L 谱值 → out = L 时域样。
/// scratch 提供 L/2 复数工作区。
pub fn imdctInv(comptime L: usize, in: []const f32, out: []f32, scratch: []Cplx) void {
    const n: usize = L;
    const n2 = L / 2;
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

    wmt.fftSr(n2, z);

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

const testing = std.testing;

fn sineInput(comptime L: usize) [L]f32 {
    var arr: [L]f32 = undefined;
    const bin = switch (L) {
        64 => @embedFile("golden_mdct_in_64.bin"),
        128 => @embedFile("golden_mdct_in_128.bin"),
        256 => @embedFile("golden_mdct_in_256.bin"),
        512 => @embedFile("golden_mdct_in_512.bin"),
        1024 => @embedFile("golden_mdct_in_1024.bin"),
        2048 => @embedFile("golden_mdct_in_2048.bin"),
        else => @compileError("unsupported mdct length"),
    };
    @memcpy(&arr, std.mem.bytesAsSlice(f32, bin));
    return arr;
}

fn goldenData(comptime L: usize) [L]f32 {
    var arr: [L]f32 = undefined;
    const bin = switch (L) {
        64 => @embedFile("golden_mdct_64.bin"),
        128 => @embedFile("golden_mdct_128.bin"),
        256 => @embedFile("golden_mdct_256.bin"),
        512 => @embedFile("golden_mdct_512.bin"),
        1024 => @embedFile("golden_mdct_1024.bin"),
        2048 => @embedFile("golden_mdct_2048.bin"),
        else => @compileError("unsupported mdct length"),
    };
    @memcpy(&arr, std.mem.bytesAsSlice(f32, bin));
    return arr;
}

fn checkL(comptime L: usize) !void {
    const in = sineInput(L);
    var out: [L]f32 = undefined;
    var scratch: [L / 2]Cplx = undefined;
    imdctInv(L, &in, &out, &scratch);
    const gold = goldenData(L);
    var mismatches: usize = 0;
    for (out, gold) |got, want| {
        if (@as(u32, @bitCast(got)) != @as(u32, @bitCast(want))) mismatches += 1;
    }
    try testing.expectEqual(@as(usize, 0), mismatches);
}

test "WMA Pro inv-MDCT 2048 == av_tx 位精确" {
    try checkL(2048);
}
test "WMA Pro inv-MDCT 1024 == av_tx 位精确" {
    try checkL(1024);
}
test "WMA Pro inv-MDCT 512 == av_tx 位精确" {
    try checkL(512);
}
test "WMA Pro inv-MDCT 256 == av_tx 位精确" {
    try checkL(256);
}
test "WMA Pro inv-MDCT 128 == av_tx 位精确" {
    try checkL(128);
}
test "WMA Pro inv-MDCT 64 == av_tx 位精确" {
    try checkL(64);
}
