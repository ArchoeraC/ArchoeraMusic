// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! WMA Voice postfilter 变换——复刻 FFmpeg av_tx float RDFT/DCT-I/DST-I 语义
//! （reference libavutil/tx_template.c n9.0.1）。
//!
//! wmavoice 后处理所需：
//!   - RDFT-128 forward（r2c）与 inverse（c2r），scale=1
//!   - DCT-I-64 / DST-I-64 forward，scale=1/64（内部经 RDFT half r2r/r2i_mod2 len 126）
//! 内部复数 FFT 用 f64 朴素 DFT（与 av_tx split-radix/PFA 输出差 ~1e-7）；RDFT/
//! DCT/DST 的运算次序与组合系数按 tx_template.c 逐行复刻。

const std = @import("std");
const dsp = @import("dsp.zig");

const pi: f64 = std.math.pi;

/// 元素 = 复数（re/im 交错 f32）。2k/k 处即为 k 号复元素。
const Cpx = struct {
    buf: []f32,
    fn at(self: Cpx, k: usize) *f32 {
        _ = self;
        _ = k;
        unreachable;
    }
};

fn re(p: []f32, k: usize) f32 {
    return p[2 * k];
}
fn im(p: []f32, k: usize) f32 {
    return p[2 * k + 1];
}

/// naive forward complex DFT（X[k]=Σ x[n] e^{-2πi kn/N}，f64 累积 → f32）。
/// in/out 为复数平面数组：out[2k], out[2k+1] = re,im。
pub fn fftFwd(comptime N: usize, src: []const f32, out: []f32) void {
    std.debug.assert(src.len >= 2 * N and out.len >= 2 * N);
    var k: usize = 0;
    while (k < N) : (k += 1) {
        var rea: f64 = 0;
        var ima: f64 = 0;
        var n: usize = 0;
        while (n < N) : (n += 1) {
            const ph = -2.0 * pi * @as(f64, @floatFromInt(k * n)) / @as(f64, @floatFromInt(N));
            const c = dsp.cosD(ph);
            const s = dsp.sinD(ph);
            const xr = src[2 * n];
            const xi = src[2 * n + 1];
            rea += @as(f64, xr) * c - @as(f64, xi) * s;
            ima += @as(f64, xr) * s + @as(f64, xi) * c;
        }
        out[2 * k] = @floatCast(rea);
        out[2 * k + 1] = @floatCast(ima);
    }
}

/// naive inverse complex DFT（f64）。
pub fn fftInv(comptime N: usize, src: []const f32, out: []f32) void {
    std.debug.assert(src.len >= 2 * N and out.len >= 2 * N);
    var k: usize = 0;
    while (k < N) : (k += 1) {
        var rea: f64 = 0;
        var ima: f64 = 0;
        var n: usize = 0;
        while (n < N) : (n += 1) {
            const ph = 2.0 * pi * @as(f64, @floatFromInt(k * n)) / @as(f64, @floatFromInt(N));
            const c = dsp.cosD(ph);
            const s = dsp.sinD(ph);
            const xr = src[2 * n];
            const xi = src[2 * n + 1];
            rea += @as(f64, xr) * c - @as(f64, xi) * s;
            ima += @as(f64, xr) * s + @as(f64, xi) * c;
        }
        out[2 * k] = @floatCast(rea);
        out[2 * k + 1] = @floatCast(ima);
    }
}

/// RDFT 上下文（ff_tx_rdft_init 各常数，按调用参数生算）。
const RdftCtx = struct {
    len: usize,
    inv: bool,
    r2r: bool,
    scale_f: f32,
    m: f32,
    f: f64,

    fn init(len: usize, inv: bool, r2r: bool, scale_f: f32) RdftCtx {
        return .{ .len = len, .inv = inv, .r2r = r2r, .scale_f = scale_f, .m = if (inv) 2.0 * scale_f else scale_f, .f = 2.0 * pi / @as(f64, @floatFromInt(len)) };
    }
    fn fact(self: *const RdftCtx, idx: usize) f32 {
        // ff_tx_rdft_init tab 顺序
        return switch (idx) {
            0, 1 => if (self.inv) @floatCast(0.5 * @as(f64, self.m)) else self.m,
            2 => self.m,
            3 => -self.m,
            4 => @floatCast(0.5 * @as(f64, self.m)),
            5 => if (self.r2r) 1.0 / self.scale_f else @floatCast(-0.5 * @as(f64, self.m)),
            6, 7 => blk: {
                const hv: f32 = @floatCast((0.5 - @as(f64, if (self.inv) 1.0 else 0.0)) * @as(f64, self.m));
                break :blk if (idx == 6) hv else -hv;
            },
            else => unreachable,
        };
    }
    fn tcos(self: *const RdftCtx, i: usize) f32 {
        return @floatCast(dsp.cosD(@as(f64, @floatFromInt(i)) * self.f));
    }
    fn tsin(self: *const RdftCtx, i: usize) f32 {
        const ang = (@as(f64, @floatFromInt(self.len - i * 4)) / 4.0) * self.f;
        const v = dsp.cosD(ang);
        return @floatCast(if (self.inv) v else -v);
    }
};

inline fn cmul(a_re: f32, a_im: f32, b_re: f32, b_im: f32, out: *[2]f32) void {
    out[0] = a_re * b_re - a_im * b_im;
    out[1] = a_re * b_im + a_im * b_re;
}

/// DECL_RDFT(r2c/c2r) 共享的频谱重组（128）。
/// 输入 data（130 float，complex[0..64]），原地重组。
fn rdftRecombine(data: *[130]f32, ctx: *const RdftCtx) void {
    const len2: usize = 64;
    const len4: usize = 32;
    const d = data;
    const f = ctx;
    // DC
    const t0: f32 = d[0];
    const d0im = d[1];
    d[0] = t0 + d0im;
    d[1] = t0 - d0im;
    d[0] *= f.fact(0);
    d[1] *= f.fact(1);
    d[2 * len4] *= f.fact(2);
    d[2 * len4 + 1] *= f.fact(3);
    var i: usize = 1;
    while (i < len4) : (i += 1) {
        const x = 2 * i;
        const y = 2 * (len2 - i);
        const t0r: f32 = f.fact(4) * (d[x] + d[y]);
        const t0i: f32 = f.fact(5) * (d[x + 1] - d[y + 1]);
        const t1r: f32 = f.fact(6) * (d[x + 1] + d[y + 1]);
        const t1i: f32 = f.fact(7) * (d[x] - d[y]);
        var t2: [2]f32 = undefined;
        cmul(t1r, t1i, f.tcos(i), f.tsin(i), &t2);
        d[x] = t0r + t2[0];
        d[x + 1] = t2[1] - t0i;
        d[y] = t0r - t2[0];
        d[y + 1] = t2[1] + t0i;
    }
}

// ---------------------------------------------------------------------------
// 位精确 f32 内核：与 FFmpeg av_tx 的 generic-C codelet（tx_template.c /
// tx.c n9.0.1，无 x86 asm 后端时的执行路径）逐位一致。
// ---------------------------------------------------------------------------

fn srpFft(i: i32, len: i32, inv: bool) i32 {
    const l2 = len >> 1;
    if (l2 <= 1) return i & 1;
    if ((i & l2) == 0) return srpFft(i, l2, inv) * 2;
    const l3 = l2 >> 1;
    return srpFft(i, l3, inv) * 4 + 1 - 2 * @as(i32, @intFromBool(((i & l3) == 0) != inv));
}

inline fn tabCosF(comptime len: i32, comptime idx: i32) f32 {
    return @floatCast(@cos(2.0 * std.math.pi * @as(f64, @floatFromInt(idx)) / @as(f64, @floatFromInt(len))));
}

fn tabCosFR(len: i32, idx: usize) f32 {
    return @floatCast(dsp.cosD(2.0 * std.math.pi * @as(f64, @floatFromInt(idx)) / @as(f64, @floatFromInt(len))));
}

inline fn butterflies(z: []f32, a0: usize, a1: usize, a2: usize, a3: usize, t1: f32, t2: f32, t5: f32, t6: f32) void {
    const r0 = z[2 * a0];
    const im0 = z[2 * a0 + 1];
    const r1 = z[2 * a1];
    const im1 = z[2 * a1 + 1];
    const t3 = t5 - t1;
    const nt5 = t5 + t1;
    z[2 * a2] = r0 - nt5;
    z[2 * a0] = r0 + nt5;
    z[2 * a3 + 1] = im1 - t3;
    z[2 * a1 + 1] = im1 + t3;
    const t4 = t2 - t6;
    const nt6 = t2 + t6;
    z[2 * a3] = r1 - t4;
    z[2 * a1] = r1 + t4;
    z[2 * a2 + 1] = im0 - nt6;
    z[2 * a0 + 1] = im0 + nt6;
}

inline fn transformC(z: []f32, a0: usize, a1: usize, a2: usize, a3: usize, wre: f32, wim: f32) void {
    const a2r = z[2 * a2];
    const a2i = z[2 * a2 + 1];
    const a3r = z[2 * a3];
    const a3i = z[2 * a3 + 1];
    const t1 = a2r * wre - a2i * (-wim);
    const t2 = a2r * (-wim) + a2i * wre;
    const t5 = a3r * wre - a3i * wim;
    const t6 = a3r * wim + a3i * wre;
    butterflies(z, a0, a1, a2, a3, t1, t2, t5, t6);
}

fn fft2NsZ(dst: []f32, src: []const f32) void {
    const tr = src[0] - src[2];
    const ti = src[1] - src[3];
    dst[0] = src[0] + src[2];
    dst[1] = src[1] + src[3];
    dst[2] = tr;
    dst[3] = ti;
}

fn fft4NsZ(dst: []f32, src: []const f32) void {
    const s = src[0..8];
    const t3 = s[0] - s[2];
    const t1 = s[0] + s[2];
    const t8 = s[6] - s[4];
    const t6 = s[6] + s[4];
    dst[4] = t1 - t6;
    dst[0] = t1 + t6;
    const t4 = s[1] - s[3];
    const t2 = s[1] + s[3];
    const t7 = s[5] - s[7];
    const t5 = s[5] + s[7];
    dst[7] = t4 - t8;
    dst[3] = t4 + t8;
    dst[6] = t3 - t7;
    dst[2] = t3 + t7;
    dst[5] = t2 - t5;
    dst[1] = t2 + t5;
}

fn fft8NsZ(dst: []f32, src: []const f32) void {
    const cos: f32 = 0.707106769084930419921875;
    fft4NsZ(dst[0..8], src[0..8]);
    const s = src;
    const t1 = s[8] + s[10];
    dst[10] = s[8] - s[10];
    const t2 = s[9] + s[11];
    dst[11] = s[9] - s[11];
    const t5 = s[12] + s[14];
    dst[14] = s[12] - s[14];
    const t6 = s[13] + s[15];
    dst[15] = s[13] - s[15];
    butterflies(dst, 0, 2, 4, 6, t1, t2, t5, t6);
    transformC(dst, 1, 3, 5, 7, cos, cos);
}

fn fft16NsZ(dst: []f32, src: []const f32) void {
    const c1: f32 = 0.92387950420379638671875;
    const c2: f32 = 0.707106769084930419921875;
    const c3: f32 = 0.3826834261417388916015625;
    fft8NsZ(dst[0..], src[0..]);
    fft4NsZ(dst[16..], src[16..]);
    fft4NsZ(dst[24..], src[24..]);
    const t1 = dst[16];
    const t2 = dst[17];
    const t5 = dst[24];
    const t6 = dst[25];
    butterflies(dst, 0, 4, 8, 12, t1, t2, t5, t6);
    transformC(dst, 2, 6, 10, 14, c2, c2);
    transformC(dst, 1, 5, 9, 13, c1, c3);
    transformC(dst, 3, 7, 11, 15, c3, c1);
}

fn srCombineZ(z: []f32, cos: []const f32, len: usize) void {
    const o1 = 2 * len;
    const o2 = 4 * len;
    const o3 = 6 * len;
    const wim0: i64 = @intCast(o1 - 7);
    var zo: usize = 0;
    var co: usize = 0;
    var wo: i64 = wim0;
    var i: usize = 0;
    while (i < len) : (i += 4) {
        transformC(z, zo + 0, zo + o1 + 0, zo + o2 + 0, zo + o3 + 0, cos[co + 0], cos[@intCast(wo + 7)]);
        transformC(z, zo + 2, zo + o1 + 2, zo + o2 + 2, zo + o3 + 2, cos[co + 2], cos[@intCast(wo + 5)]);
        transformC(z, zo + 4, zo + o1 + 4, zo + o2 + 4, zo + o3 + 4, cos[co + 4], cos[@intCast(wo + 3)]);
        transformC(z, zo + 6, zo + o1 + 6, zo + o2 + 6, zo + o3 + 6, cos[co + 6], cos[@intCast(wo + 1)]);
        transformC(z, zo + 1, zo + o1 + 1, zo + o2 + 1, zo + o3 + 1, cos[co + 1], cos[@intCast(wo + 6)]);
        transformC(z, zo + 3, zo + o1 + 3, zo + o2 + 3, zo + o3 + 3, cos[co + 3], cos[@intCast(wo + 4)]);
        transformC(z, zo + 5, zo + o1 + 5, zo + o2 + 5, zo + o3 + 5, cos[co + 5], cos[@intCast(wo + 2)]);
        transformC(z, zo + 7, zo + o1 + 7, zo + o2 + 7, zo + o3 + 7, cos[co + 7], cos[@intCast(wo + 0)]);
        zo += 8;
        co += 8;
        wo -= 8;
    }
}

var tab32_c: [9]f32 = undefined;
var tab32_c_ready = false;
fn tab32C() *const [9]f32 {
    if (!tab32_c_ready) {
        for (0..9) |k| tab32_c[k] = tabCosFR(32, k);
        tab32_c_ready = true;
    }
    return &tab32_c;
}
var tab64_c: [17]f32 = undefined;
var tab64_c_ready = false;
fn tab64C() *const [17]f32 {
    if (!tab64_c_ready) {
        for (0..17) |k| tab64_c[k] = tabCosFR(64, k);
        tab64_c_ready = true;
    }
    return &tab64_c;
}

fn fft32NsZ(dst: []f32) void {
    fft16NsZ(dst[0..], dst[0..]);
    fft8NsZ(dst[32..], dst[32..]);
    fft8NsZ(dst[48..], dst[48..]);
    srCombineZ(dst, tab32C(), 4);
}

fn fft64NsZ(buf: []f32) void {
    fft32NsZ(buf[0..]);
    fft16NsZ(buf[64..], buf[64..]);
    fft16NsZ(buf[96..], buf[96..]);
    srCombineZ(buf, tab64C(), 8);
}

/// 通用 C 路径 complex FFT-64（ff_tx_fft driver + fft64_ns，见 reference tx.c /
/// tx_template.c）：src 64 complex → dst 64 complex（128 floats）。
pub fn fft64C(in: []const f32, inv: bool, out: []f32) void {
    var map: [64]i32 = undefined;
    for (0..64) |i| map[i] = -srpFft(@intCast(i), 64, inv) & 63;
    var buf: [128]f32 = undefined;
    for (0..64) |i| {
        const mi: usize = @intCast(map[i]);
        buf[2 * i] = in[2 * mi];
        buf[2 * i + 1] = in[2 * mi + 1];
    }
    fft64NsZ(&buf);
    @memcpy(out[0..128], &buf);
}

/// RDFT-128 forward（r2c）：src 128 real → dst 130 floats = complex X[0..64]。
/// 复元素 k 在 dst[2k],dst[2k+1]；X0 re/im、Nyquist(re=X64) 亦在其中（见 probe）。
pub fn rdftR2C(dst: []f32, src: []const f32) void {
    var ctx = RdftCtx.init(128, false, false, 1.0);
    // subtx complex FFT-64 of z[i]=(src[2i], src[2i+1])（generic C 路径）
    var data: [130]f32 = undefined;
    fft64C(src[0..128], false, data[0..128]);
    data[128] = 0;
    data[129] = 0;
    rdftRecombine(&data, &ctx);
    // fwd: 把 data[0].im（=Nyquist 实数）搬到 data[64]（complex index 64）
    data[2 * 64] = data[1];
    data[1] = 0;
    data[2 * 64 + 1] = 0;
    @memcpy(dst[0..130], &data);
}

/// RDFT-128 inverse（c2r）：src 130 floats complex X[0..64] → dst 128 real。
pub fn rdftC2R(dst: []f32, src: []const f32) void {
    var ctx = RdftCtx.init(128, true, false, 1.0);
    var data: [130]f32 = undefined;
    @memcpy(data[0..130], src[0..130]);
    // inv: data[0].im = data[len2].re（Nyquist 已放于 complex[64].re）
    data[1] = data[2 * 64];
    rdftRecombine(&data, &ctx);
    var z: [128]f32 = undefined;
    for (0..64) |i| {
        z[2 * i] = data[2 * i];
        z[2 * i + 1] = data[2 * i + 1];
    }
    fft64C(&z, true, dst[0..128]);
}

/// DECL_RDFT_HALF（r2r_mod2 / r2i_mod2）——DCT/DST-I 内部（len=126/130）。
/// src 为 len 个 real（作为 len/2 复数的 PFA-FFT 输入），dst 输出 len floats。
fn rdftHalfMod2(dst: []f32, src: []const f32, comptime r2r: bool, comptime len: usize) void {
    const len2: usize = len >> 1;
    const len4: usize = len >> 2;
    const f = RdftCtx.init(len, false, r2r, 1.0 / 64.0);

    // subtx FFT（PFA，63/65 复数）原地于 dst
    if (len == 126) fftPfa63(dst[0 .. 2 * len2], src[0 .. 2 * len2]) else fftPfa65(dst[0 .. 2 * len2], src[0 .. 2 * len2]);

    var tmp_dc: f32 = dst[0];
    dst[0] = tmp_dc + dst[1];
    tmp_dc = tmp_dc - dst[1];

    dst[0] *= f.fact(0);
    tmp_dc *= f.fact(1);
    dst[2 * len4] *= f.fact(2);

    var tmp_mid: f32 = undefined;
    {
        const sf_re = dst[2 * len4];
        const sf_im = dst[2 * len4 + 1];
        const sl_re = dst[2 * (len4 + 1)];
        const sl_im = dst[2 * (len4 + 1) + 1];
        var tmp: [4]f32 = undefined;
        if (r2r) {
            tmp[0] = f.fact(4) * (sf_re + sl_re);
        } else {
            tmp[0] = f.fact(5) * (sf_im - sl_im);
        }
        tmp[1] = f.fact(6) * (sf_im + sl_im);
        tmp[2] = f.fact(7) * (sf_re - sl_re);

        if (r2r) {
            tmp[3] = tmp[1] * f.tcos(len4) - tmp[2] * f.tsin(len4);
            tmp_mid = tmp[0] - tmp[3];
        } else {
            tmp[3] = tmp[1] * f.tsin(len4) + tmp[2] * f.tcos(len4);
            tmp_mid = tmp[0] + tmp[3];
        }
    }

    var i: usize = 1;
    while (i <= len4) : (i += 1) {
        const x = 2 * i;
        const y = 2 * (len2 - i);
        const sf_r = dst[x];
        const sf_i = dst[x + 1];
        const sl_r = dst[y];
        const sl_i = dst[y + 1];
        if (r2r) {
            const tt0: f32 = f.fact(4) * (sf_r + sl_r);
            const tt1: f32 = f.fact(6) * (sf_i + sl_i);
            const tt2: f32 = f.fact(7) * (sf_r - sl_r);
            const tt3: f32 = tt1 * f.tcos(i) - tt2 * f.tsin(i);
            dst[i] = tt0 + tt3;
            dst[len - i] = tt0 - tt3;
        } else {
            const tt0: f32 = f.fact(5) * (sf_i - sl_i);
            const tt1: f32 = f.fact(6) * (sf_i + sl_i);
            const tt2: f32 = f.fact(7) * (sf_r - sl_r);
            const tt3: f32 = tt1 * f.tsin(i) + tt2 * f.tcos(i);
            dst[i - 1] = tt3 - tt0;
            dst[len - i - 1] = tt0 + tt3;
        }
    }

    // 对称回填
    if (r2r) {
        var ii: usize = 1;
        while (ii < len4) : (ii += 1) dst[len2 - ii] = dst[len - ii];
        dst[len2] = tmp_dc;
        dst[len4 + 1] = tmp_mid * f.fact(5);
    } else {
        var ii: usize = 1;
        while (ii < len4 + 1) : (ii += 1) dst[len2 - ii] = dst[len - ii];
        dst[len4] = tmp_mid;
    }
}

/// DCT-I-64 forward（av_tx AV_TX_FLOAT_DCT_I fwd，len 64，scale 1/64）逐位复刻：
/// dctI wrapper（镜像 tmp）→ rdft_r2r_mod2(126) → fft_pfa(63) → fft7_ns/fft9_ns。
pub fn dctIFwd(dst: []f32, src: []const f32) void {
    var tmp: [130]f32 = undefined;
    const n: usize = 63;
    for (0..n) |i| {
        tmp[i] = src[i];
        tmp[2 * n - i] = src[i];
    }
    tmp[n] = src[n];
    @memset(tmp[127..], 0);
    rdftHalfMod2(dst, tmp[0..126], true, 126);
}

/// DST-I-64 forward（av_tx AV_TX_FLOAT_DST_I fwd，len 64，scale 1/64）逐位复刻：
/// dstI wrapper（反对称 tmp）→ rdft_r2i_mod2(130) → fft_pfa(65) → naive13/fft5_ns。
pub fn dstIFwd(dst: []f32, src: []const f32) void {
    var tmp: [132]f32 = undefined;
    const n: usize = 65;
    tmp[0] = 0;
    for (1..n) |i| {
        const a = src[i - 1];
        tmp[i] = -a;
        tmp[2 * n - i] = a;
    }
    tmp[n] = 0;
    @memset(tmp[131..], 0);
    rdftHalfMod2(dst, tmp[0..130], false, 130);
}

// ---------------------------------------------------------------------------
// PFA 复合 FFT（逐位复刻 av_tx fft_pfa + fft7_ns/fft9_ns/fft5_ns/
// fft_naive_small codelet，tx_template.c n9.0.1）
// ---------------------------------------------------------------------------

fn mulinv(x: u32, m: u32) u32 {
    const nn = x % m;
    var v: u32 = 1;
    while (v < m) : (v += 1) {
        if ((nn * v) % m == 1) return v;
    }
    return 0;
}

// tab_53 / tab_7 / tab_9（C：double cos/sin → f32；此处经 glibc cos/sin）
var tab53: [12]f32 = undefined;
var tab7: [6]f32 = undefined;
var tab9: [8]f32 = undefined;
var tabs_ready = false;
fn initTabs() void {
    if (tabs_ready) return;
    tabs_ready = true;
    tab53[0] = @floatCast(dsp.cosD(2.0 * pi / 5.0));
    tab53[1] = tab53[0];
    tab53[2] = @floatCast(dsp.cosD(2.0 * pi / 10.0));
    tab53[3] = tab53[2];
    tab53[4] = @floatCast(dsp.sinD(2.0 * pi / 5.0));
    tab53[5] = tab53[4];
    tab53[6] = @floatCast(dsp.sinD(2.0 * pi / 10.0));
    tab53[7] = tab53[6];
    tab53[8] = @floatCast(dsp.cosD(2.0 * pi / 12.0));
    tab53[9] = tab53[8];
    tab53[10] = @floatCast(dsp.cosD(2.0 * pi / 6.0));
    tab53[11] = @floatCast(dsp.cosD(8.0 * pi / 6.0));

    tab7[0] = @floatCast(dsp.cosD(2.0 * pi / 7.0));
    tab7[1] = @floatCast(dsp.sinD(2.0 * pi / 7.0));
    tab7[2] = @floatCast(dsp.sinD(2.0 * pi / 28.0));
    tab7[3] = @floatCast(dsp.cosD(2.0 * pi / 28.0));
    tab7[4] = @floatCast(dsp.cosD(2.0 * pi / 14.0));
    tab7[5] = @floatCast(dsp.sinD(2.0 * pi / 14.0));

    tab9[0] = @floatCast(dsp.cosD(2.0 * pi / 3.0));
    tab9[1] = @floatCast(dsp.sinD(2.0 * pi / 3.0));
    tab9[2] = @floatCast(dsp.cosD(2.0 * pi / 9.0));
    tab9[3] = @floatCast(dsp.sinD(2.0 * pi / 9.0));
    tab9[4] = @floatCast(dsp.cosD(2.0 * pi / 36.0));
    tab9[5] = @floatCast(dsp.sinD(2.0 * pi / 36.0));
    tab9[6] = tab9[2] + tab9[5];
    tab9[7] = tab9[3] - tab9[4];
}

inline fn bf(x: *f32, y: *f32, a: f32, b: f32) void {
    x.* = a - b;
    y.* = a + b;
}

/// fft7_ns：in 7 复数（连续 f32 对），out[k*out_stride] 复数写。
fn fft7Ns(out: []f32, out_off: usize, out_stride: usize, in: []const f32) void {
    initTabs();
    var t: [6][2]f32 = undefined;
    var z: [3][2]f32 = undefined;
    const dc = [2]f32{ in[0], in[1] };

    bf(&t[1][0], &t[0][0], in[2], in[12]);
    bf(&t[1][1], &t[0][1], in[3], in[13]);
    bf(&t[3][0], &t[2][0], in[4], in[10]);
    bf(&t[3][1], &t[2][1], in[5], in[11]);
    bf(&t[5][0], &t[4][0], in[6], in[8]);
    bf(&t[5][1], &t[4][1], in[7], in[9]);

    out[out_off] = dc[0] + t[0][0] + t[2][0] + t[4][0];
    out[out_off + 1] = dc[1] + t[0][1] + t[2][1] + t[4][1];

    z[0][0] = tab7[0] * t[0][0] - tab7[4] * t[4][0] - tab7[2] * t[2][0];
    z[1][0] = tab7[0] * t[4][0] - tab7[2] * t[0][0] - tab7[4] * t[2][0];
    z[2][0] = tab7[0] * t[2][0] - tab7[4] * t[0][0] - tab7[2] * t[4][0];
    z[0][1] = tab7[0] * t[0][1] - tab7[2] * t[2][1] - tab7[4] * t[4][1];
    z[1][1] = tab7[0] * t[4][1] - tab7[2] * t[0][1] - tab7[4] * t[2][1];
    z[2][1] = tab7[0] * t[2][1] - tab7[4] * t[0][1] - tab7[2] * t[4][1];

    t[0][0] = tab7[5] * t[1][1] + tab7[3] * t[5][1] - tab7[1] * t[3][1];
    t[2][0] = tab7[1] * t[5][1] + tab7[5] * t[3][1] - tab7[3] * t[1][1];
    t[4][0] = tab7[5] * t[5][1] + tab7[3] * t[3][1] + tab7[1] * t[1][1];
    t[0][1] = tab7[1] * t[1][0] + tab7[3] * t[3][0] + tab7[5] * t[5][0];
    t[2][1] = tab7[5] * t[3][0] + tab7[1] * t[5][0] - tab7[3] * t[1][0];
    t[4][1] = tab7[5] * t[1][0] + tab7[3] * t[5][0] - tab7[1] * t[3][0];

    bf(&t[1][0], &z[0][0], z[0][0], t[4][0]);
    bf(&t[3][0], &z[1][0], z[1][0], t[2][0]);
    bf(&t[5][0], &z[2][0], z[2][0], t[0][0]);
    bf(&t[1][1], &z[0][1], z[0][1], t[0][1]);
    bf(&t[3][1], &z[1][1], z[1][1], t[2][1]);
    bf(&t[5][1], &z[2][1], z[2][1], t[4][1]);

    const s = out_stride * 2;
    out[out_off + s] = dc[0] + z[0][0];
    out[out_off + s + 1] = dc[1] + t[1][1];
    out[out_off + 2 * s] = dc[0] + t[3][0];
    out[out_off + 2 * s + 1] = dc[1] + z[1][1];
    out[out_off + 3 * s] = dc[0] + z[2][0];
    out[out_off + 3 * s + 1] = dc[1] + t[5][1];
    out[out_off + 4 * s] = dc[0] + t[5][0];
    out[out_off + 4 * s + 1] = dc[1] + z[2][1];
    out[out_off + 5 * s] = dc[0] + z[1][0];
    out[out_off + 5 * s + 1] = dc[1] + t[3][1];
    out[out_off + 6 * s] = dc[0] + t[1][0];
    out[out_off + 6 * s + 1] = dc[1] + z[0][1];
}

/// fft9_ns
fn fft9Ns(out: []f32, out_off: usize, out_stride: usize, in: []const f32) void {
    initTabs();
    var t: [8][2]f32 = undefined;
    var w: [4][2]f32 = undefined;
    var x: [5][2]f32 = undefined;
    var y: [5][2]f32 = undefined;
    var z: [2][2]f32 = undefined;

    const dc = [2]f32{ in[0], in[1] };
    bf(&t[1][0], &t[0][0], in[2], in[16]);
    bf(&t[1][1], &t[0][1], in[3], in[17]);
    bf(&t[3][0], &t[2][0], in[4], in[14]);
    bf(&t[3][1], &t[2][1], in[5], in[15]);
    bf(&t[5][0], &t[4][0], in[6], in[12]);
    bf(&t[5][1], &t[4][1], in[7], in[13]);
    bf(&t[7][0], &t[6][0], in[8], in[10]);
    bf(&t[7][1], &t[6][1], in[9], in[11]);

    w[0][0] = t[0][0] - t[6][0];
    w[0][1] = t[0][1] - t[6][1];
    w[1][0] = t[2][0] - t[6][0];
    w[1][1] = t[2][1] - t[6][1];
    w[2][0] = t[1][0] - t[7][0];
    w[2][1] = t[1][1] - t[7][1];
    w[3][0] = t[3][0] + t[7][0];
    w[3][1] = t[3][1] + t[7][1];

    z[0][0] = dc[0] + t[4][0];
    z[0][1] = dc[1] + t[4][1];
    z[1][0] = t[0][0] + t[2][0] + t[6][0];
    z[1][1] = t[0][1] + t[2][1] + t[6][1];

    out[out_off] = z[0][0] + z[1][0];
    out[out_off + 1] = z[0][1] + z[1][1];

    y[3][0] = tab9[1] * (t[1][0] - t[3][0] + t[7][0]);
    y[3][1] = tab9[1] * (t[1][1] - t[3][1] + t[7][1]);

    x[3][0] = z[0][0] + tab9[0] * z[1][0];
    x[3][1] = z[0][1] + tab9[0] * z[1][1];
    z[0][0] = dc[0] + tab9[0] * t[4][0];
    z[0][1] = dc[1] + tab9[0] * t[4][1];

    x[1][0] = tab9[2] * w[0][0] + tab9[5] * w[1][0];
    x[1][1] = tab9[2] * w[0][1] + tab9[5] * w[1][1];
    x[2][0] = tab9[5] * w[0][0] - tab9[6] * w[1][0];
    x[2][1] = tab9[5] * w[0][1] - tab9[6] * w[1][1];
    y[1][0] = tab9[3] * w[2][0] + tab9[4] * w[3][0];
    y[1][1] = tab9[3] * w[2][1] + tab9[4] * w[3][1];
    y[2][0] = tab9[4] * w[2][0] - tab9[7] * w[3][0];
    y[2][1] = tab9[4] * w[2][1] - tab9[7] * w[3][1];

    y[0][0] = tab9[1] * t[5][0];
    y[0][1] = tab9[1] * t[5][1];

    x[4][0] = x[1][0] + x[2][0];
    x[4][1] = x[1][1] + x[2][1];
    y[4][0] = y[1][0] - y[2][0];
    y[4][1] = y[1][1] - y[2][1];
    x[1][0] = z[0][0] + x[1][0];
    x[1][1] = z[0][1] + x[1][1];
    y[1][0] = y[0][0] + y[1][0];
    y[1][1] = y[0][1] + y[1][1];
    x[2][0] = z[0][0] + x[2][0];
    x[2][1] = z[0][1] + x[2][1];
    y[2][0] = y[2][0] - y[0][0];
    y[2][1] = y[2][1] - y[0][1];
    x[4][0] = z[0][0] - x[4][0];
    x[4][1] = z[0][1] - x[4][1];
    y[4][0] = y[0][0] - y[4][0];
    y[4][1] = y[0][1] - y[4][1];

    const st = out_stride * 2;
    out[out_off + st] = x[1][0] + y[1][1];
    out[out_off + st + 1] = x[1][1] - y[1][0];
    out[out_off + 2 * st] = x[2][0] + y[2][1];
    out[out_off + 2 * st + 1] = x[2][1] - y[2][0];
    out[out_off + 3 * st] = x[3][0] + y[3][1];
    out[out_off + 3 * st + 1] = x[3][1] - y[3][0];
    out[out_off + 4 * st] = x[4][0] + y[4][1];
    out[out_off + 4 * st + 1] = x[4][1] - y[4][0];
    out[out_off + 5 * st] = x[4][0] - y[4][1];
    out[out_off + 5 * st + 1] = x[4][1] + y[4][0];
    out[out_off + 6 * st] = x[3][0] - y[3][1];
    out[out_off + 6 * st + 1] = x[3][1] + y[3][0];
    out[out_off + 7 * st] = x[2][0] - y[2][1];
    out[out_off + 7 * st + 1] = x[2][1] + y[2][0];
    out[out_off + 8 * st] = x[1][0] - y[1][1];
    out[out_off + 8 * st + 1] = x[1][1] + y[1][0];
}

/// fft5（identity）
fn fft5Ns(out: []f32, out_off: usize, out_stride: usize, in: []const f32) void {
    initTabs();
    var z0: [4][2]f32 = undefined;
    var t: [6][2]f32 = undefined;
    const dc = [2]f32{ in[0], in[1] };

    bf(&t[1][1], &t[0][0], in[2], in[8]);
    bf(&t[1][0], &t[0][1], in[3], in[9]);
    bf(&t[3][1], &t[2][0], in[4], in[6]);
    bf(&t[3][0], &t[2][1], in[5], in[7]);

    out[out_off] = dc[0] + t[0][0] + t[2][0];
    out[out_off + 1] = dc[1] + t[0][1] + t[2][1];

    // SMUL(t[4].re, t[0].re, tab[0], tab[2], t[2].re, t[0].re)
    t[4][0] = tab53[0] * t[2][0] - tab53[2] * t[0][0];
    t[0][0] = tab53[0] * t[0][0] - tab53[2] * t[2][0];
    // SMUL(t[4].im, t[0].im, tab[0], tab[2], t[2].im, t[0].im)
    t[4][1] = tab53[0] * t[2][1] - tab53[2] * t[0][1];
    t[0][1] = tab53[0] * t[0][1] - tab53[2] * t[2][1];
    // CMUL(t[5].re, t[1].re, tab[4], tab[6], t[3].re, t[1].re)
    t[5][0] = tab53[4] * t[3][0] - tab53[6] * t[1][0];
    t[1][0] = tab53[4] * t[1][0] + tab53[6] * t[3][0];
    // CMUL(t[5].im, t[1].im, tab[4], tab[6], t[3].im, t[1].im)
    t[5][1] = tab53[4] * t[3][1] - tab53[6] * t[1][1];
    t[1][1] = tab53[4] * t[1][1] + tab53[6] * t[3][1];

    bf(&z0[0][0], &z0[3][0], t[0][0], t[1][0]);
    bf(&z0[0][1], &z0[3][1], t[0][1], t[1][1]);
    bf(&z0[2][0], &z0[1][0], t[4][0], t[5][0]);
    bf(&z0[2][1], &z0[1][1], t[4][1], t[5][1]);

    const st = out_stride * 2;
    out[out_off + st] = dc[0] + z0[3][0];
    out[out_off + st + 1] = dc[1] + z0[0][1];
    out[out_off + 2 * st] = dc[0] + z0[2][0];
    out[out_off + 2 * st + 1] = dc[1] + z0[1][1];
    out[out_off + 3 * st] = dc[0] + z0[1][0];
    out[out_off + 3 * st + 1] = dc[1] + z0[2][1];
    out[out_off + 4 * st] = dc[0] + z0[0][0];
    out[out_off + 4 * st + 1] = dc[1] + z0[3][1];
}

/// fft_naive_small（len 13，fwd，exp 表）
var naive13_exp: [169][2]f32 = undefined;
var naive13_ready = false;
fn fftNaive13(out: []f32, out_off: usize, out_stride: usize, in: []const f32) void {
    if (!naive13_ready) {
        naive13_ready = true;
        const phase: f64 = -2.0 * pi / 13.0;
        for (0..13) |i| {
            for (0..13) |j| {
                const factor = phase * @as(f64, @floatFromInt(i * j));
                naive13_exp[i * j][0] = @floatCast(dsp.cosD(factor));
                naive13_exp[i * j][1] = @floatCast(dsp.sinD(factor));
            }
        }
    }
    const st = out_stride * 2;
    for (0..13) |i| {
        var tmp_re: f32 = 0;
        var tmp_im: f32 = 0;
        for (0..13) |j| {
            const sr = in[2 * j];
            const si = in[2 * j + 1];
            const m = naive13_exp[i * j];
            tmp_re += sr * m[0] - si * m[1];
            tmp_im += sr * m[1] + si * m[0];
        }
        out[out_off + i * st] = tmp_re;
        out[out_off + i * st + 1] = tmp_im;
    }
}

fn fftPfa63(dst: []f32, src: []const f32) void {
    initTabs();
    const n: usize = 7;
    const m: usize = 9;
    const l: usize = 63;
    const m_inv: u32 = mulinv(9, 7);
    const n_inv: u32 = mulinv(7, 9);
    var in_map: [63]u32 = undefined;
    var out_map: [63]u32 = undefined;
    for (0..m) |j| {
        for (0..n) |i| {
            in_map[j * n + i] = @intCast((i * m + j * n) % l);
            out_map[@intCast((i * m * m_inv + j * n * n_inv) % l)] = @intCast(i * m + j);
        }
    }
    var expb: [14]f32 = undefined;
    var tmp: [126]f32 = undefined;
    var tmp1: [126]f32 = undefined;
    for (0..m) |i| {
        for (0..n) |j| {
            expb[2 * j] = src[2 * in_map[i * n + j]];
            expb[2 * j + 1] = src[2 * in_map[i * n + j] + 1];
        }
        fft7Ns(&tmp, 2 * i, m, &expb);
    }
    for (0..n) |i| {
        fft9Ns(&tmp1, 2 * m * i, 1, tmp[2 * m * i .. 2 * m * i + 18]);
    }
    for (0..l) |i| {
        dst[2 * i] = tmp1[2 * out_map[i]];
        dst[2 * i + 1] = tmp1[2 * out_map[i] + 1];
    }
}

fn fftPfa65(dst: []f32, src: []const f32) void {
    initTabs();
    const n: usize = 13;
    const m: usize = 5;
    const l: usize = 65;
    const m_inv: u32 = mulinv(5, 13);
    const n_inv: u32 = mulinv(13, 5);
    var in_map: [65]u32 = undefined;
    var out_map: [65]u32 = undefined;
    for (0..m) |j| {
        for (0..n) |i| {
            in_map[j * n + i] = @intCast((i * m + j * n) % l);
            out_map[@intCast((i * m * m_inv + j * n * n_inv) % l)] = @intCast(i * m + j);
        }
    }
    var expb: [26]f32 = undefined;
    var tmp: [130]f32 = undefined;
    var tmp1: [130]f32 = undefined;
    for (0..m) |i| {
        for (0..n) |j| {
            expb[2 * j] = src[2 * in_map[i * n + j]];
            expb[2 * j + 1] = src[2 * in_map[i * n + j] + 1];
        }
        fftNaive13(&tmp, 2 * i, m, &expb);
    }
    for (0..n) |i| {
        fft5Ns(&tmp1, 2 * m * i, 1, tmp[2 * m * i .. 2 * m * i + 10]);
    }
    for (0..l) |i| {
        dst[2 * i] = tmp1[2 * out_map[i]];
        dst[2 * i + 1] = tmp1[2 * out_map[i] + 1];
    }
}

pub fn testFft63(dst: []f32, src: []const f32) void {
    fftPfa63(dst, src);
}
pub fn testFft65(dst: []f32, src: []const f32) void {
    fftPfa65(dst, src);
}

pub fn testFft7(out: []f32, out_off: usize, out_stride: usize, in: []const f32) void {
    fft7Ns(out, out_off, out_stride, in);
}

pub fn testFft9(out: []f32, out_off: usize, out_stride: usize, in: []const f32) void {
    fft9Ns(out, out_off, out_stride, in);
}
