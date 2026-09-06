// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Speex CELP 核心解码（对照移植 FFmpeg `libavcodec/speexdec.c`，n9.0.1 native
//! speex 解码器，浮点路径：全程 f32 与系统 ffmpeg 默认 native `speex` 一致）。
//!
//! 移植约定（保证与 C 实现位级一致）：
//!   - 所有浮点运算保持 C 源的求值顺序（Zig 严格浮点，无 FMA 收缩/重结合）；
//!   - `@exp`/`@cos`/`@sqrt` 链接 libc 时解析到与 ffmpeg 相同的 glibc libm；
//!   - 表数据自 reference/FFmpeg/libavcodec/speexdata.h 逐值转录（data.zig）；
//!   - exc_buf 以「基址 + 有符号偏移」访问，等价 C 的 exc 指针负回看。

const std = @import("std");
const builtin = @import("builtin");
const t = @import("data.zig");

// ---------------------------------------------------------------------------
// 常量（speexdec.c 头部宏）
// ---------------------------------------------------------------------------

pub const NB_ORDER = 10;
pub const NB_FRAME_SIZE = 160;
pub const NB_SUBMODES = 9;
pub const SB_SUBMODE_BITS = 3;
pub const NB_SUBFRAME_SIZE = 40;
pub const NB_NB_SUBFRAMES = 4;
pub const NB_PITCH_START = 17;
pub const NB_PITCH_END = 144;
pub const NB_DEC_BUFFER = NB_FRAME_SIZE + 2 * NB_PITCH_END + NB_SUBFRAME_SIZE + 12; // 500
pub const QMF_ORDER = 64;
pub const SPEEX_NB_MODES = 3;
pub const SPEEX_INBAND_STEREO = 9;

/// st->exc = exc_buf + 2*NB_PITCH_END + NB_SUBFRAME_SIZE + 6（C DecoderState）
pub const EXC_OFF: isize = 2 * NB_PITCH_END + NB_SUBFRAME_SIZE + 6; // 334

/// 帧移位长度（memmove 尾部长度）：2*NB_PITCH_END + NB_SUBFRAME_SIZE + 12
const SHIFT_LEN = 2 * NB_PITCH_END + NB_SUBFRAME_SIZE + 12; // 340

// ---------------------------------------------------------------------------
// 位读取器（FFmpeg get_bits 语义：MSB 先行；EOF 后读 0）
// ---------------------------------------------------------------------------

pub const BitReader = struct {
    data: []const u8,
    pos: usize = 0, // 绝对位位置

    pub fn init(data: []const u8) BitReader {
        return .{ .data = data };
    }

    /// 剩余位数（FFmpeg get_bits_left 可为负；本实现钳到下界防溢出）
    pub fn left(self: *const BitReader) i32 {
        const total: i64 = @as(i64, @intCast(self.data.len)) * 8;
        const r = total - @as(i64, @intCast(self.pos));
        return @intCast(@max(r, -(1 << 30)));
    }

    pub fn getBits(self: *BitReader, n: u5) u32 {
        var v: u32 = 0;
        var i: u5 = 0;
        while (i < n) : (i += 1) {
            const p = self.pos + i;
            const bit: u32 = if (p / 8 < self.data.len)
                @as(u32, (self.data[p / 8] >> @intCast(7 - (p % 8))) & 1)
            else
                0;
            v = (v << 1) | bit;
        }
        self.pos += n;
        return v;
    }

    pub fn getBits1(self: *BitReader) u1 {
        return @intCast(self.getBits(1));
    }

    /// 查看 n 位（不消耗；FFmpeg show_bits）
    pub fn showBits(self: *const BitReader, n: u5) u32 {
        var v: u32 = 0;
        var i: u5 = 0;
        while (i < n) : (i += 1) {
            const p = self.pos + i;
            const bit: u32 = if (p / 8 < self.data.len)
                @as(u32, (self.data[p / 8] >> @intCast(7 - (p % 8))) & 1)
            else
                0;
            v = (v << 1) | bit;
        }
        return v;
    }

    /// skip_bits_long
    pub fn skipLong(self: *BitReader, n: i64) void {
        if (n <= 0) return;
        self.pos += @intCast(n);
    }
};

// ---------------------------------------------------------------------------
// 小工具（av_clipf / gain_3tap_to_1tap / speex_rand 等）
// ---------------------------------------------------------------------------

inline fn clipf(x: f32, amin: f32, amax: f32) f32 {
    if (x < amin) return amin;
    if (x > amax) return amax;
    return x;
}

/// gain_3tap_to_1tap 宏
inline fn gain3tap1tap(g: *const [3]f32) f32 {
    return @abs(g[1]) + (if (g[0] > 0.0) g[0] else -0.5 * g[0]) +
        (if (g[2] > 0.0) g[2] else -0.5 * g[2]);
}

/// speex_rand（libspeex bits.c 同款 LCG，位级一致）
pub fn speexRand(std_dev: f32, seed: *u32) f32 {
    seed.* = 1664525 *% seed.* +% 1013904223;
    const ran: u32 = 0x3f800000 | (0x007fffff & seed.*);
    var fran: f32 = @bitCast(ran);
    fran -= 1.5;
    fran *= std_dev;
    return fran;
}

pub fn computeRms(x: []const f32) f32 {
    var sum: f32 = 0;
    for (x) |v| sum += v * v;
    return @sqrt(0.1 + sum / @as(f32, @floatFromInt(x.len)));
}

/// inner_prod：8 元素部分和逐个累加（保持 C 循环结构；调用点 len 均为 8 的倍数）
pub fn innerProd(x: []const f32, y: []const f32) f32 {
    var sum: f32 = 0;
    var i: usize = 0;
    while (i < x.len) : (i += 8) {
        var part: f32 = 0;
        inline for (0..8) |k| part += x[i + k] * y[i + k];
        sum += part;
    }
    return sum;
}

pub fn signalMul(x: []f32, scale: f32) void {
    for (x) |*v| v.* = scale * v.*;
}

/// sanitize_values（isnormal / |x|<1e-8 → 0，否则 clamp）
fn sanitizeValues(vec: []f32, min_val: f32, max_val: f32) void {
    for (vec) |*v| {
        if (!std.math.isNormal(v.*) or @abs(v.*) < 1e-8) {
            v.* = 0;
        } else {
            v.* = clipf(v.*, min_val, max_val);
        }
    }
}

/// exc_buf 元素访问（等价 C 的 exc[i] 指针运算，i 可为负）
inline fn eat(buf: *const [NB_DEC_BUFFER]f32, off: isize, i: isize) f32 {
    return buf[@intCast(off + i)];
}

inline fn eset(buf: *[NB_DEC_BUFFER]f32, off: isize, i: isize, v: f32) void {
    buf[@intCast(off + i)] = v;
}

// ---------------------------------------------------------------------------
// 滤波原语（bw_lpc / iir_mem / highpass）
// ---------------------------------------------------------------------------

fn bwLpc(gamma: f32, lpc_in: []const f32, lpc_out: []f32) void {
    var tmp = gamma;
    for (lpc_in, 0..) |v, i| {
        lpc_out[i] = tmp * v;
        tmp *= gamma;
    }
}

fn iirMem(x: []const f32, den: []const f32, y: []f32, mem: []f32, ord: usize) void {
    for (x, 0..) |xi, i| {
        const yi = xi + mem[0];
        const nyi = -yi;
        var j: usize = 0;
        while (j < ord - 1) : (j += 1) {
            mem[j] = mem[j + 1] + den[j] * nyi;
        }
        mem[ord - 1] = den[ord - 1] * nyi;
        y[i] = yi;
    }
}

pub fn highpass(x: []f32, y: []f32, mem: *[2]f32, wide: usize) void {
    const pcoef = [2][3]f32{
        .{ 1.00000, -1.92683, 0.93071 },
        .{ 1.00000, -1.97226, 0.97332 },
    };
    const zcoef = [2][3]f32{
        .{ 0.96446, -1.92879, 0.96446 },
        .{ 0.98645, -1.97277, 0.98645 },
    };
    const den = &pcoef[wide];
    const num = &zcoef[wide];
    for (x, 0..) |xi, i| {
        const yi = num[0] * xi + mem[0];
        mem[0] = mem[1] + num[1] * xi + -den[1] * yi;
        mem[1] = num[2] * xi + -den[2] * yi;
        y[i] = yi;
    }
}

// ---------------------------------------------------------------------------
// LSP 插值 / LSP → LPC
// ---------------------------------------------------------------------------

fn lspInterpolate(
    old_lsp: []const f32,
    new_lsp: []const f32,
    lsp: []f32,
    order: usize,
    subframe: usize,
    nb_subframes: usize,
    margin: f32,
) void {
    const tmp = (1.0 + @as(f32, @floatFromInt(subframe))) /
        @as(f32, @floatFromInt(nb_subframes));
    // C: av_clipf(lsp[i], margin, M_PI - margin) —— 上界以 double 计算 M_PI - margin
    // 后再舍入到 float（M_PI 为 double 常量），与 f32 直接相减可差 1 ulp
    const upper: f32 = @floatCast(@as(f64, std.math.pi) - @as(f64, margin));
    for (0..order) |i| {
        lsp[i] = (1.0 - tmp) * old_lsp[i] + tmp * new_lsp[i];
        lsp[i] = clipf(lsp[i], margin, upper);
    }
    var i: usize = 1;
    while (i + 1 < order) : (i += 1) {
        lsp[i] = @max(lsp[i], lsp[i - 1] + margin);
        if (lsp[i] > lsp[i + 1] - margin) {
            lsp[i] = 0.5 * (lsp[i] + lsp[i + 1] - margin);
        }
    }
}

/// lsp_to_lpc（C 原样：P/Q 级联二阶多项式重构）
/// `order` 显式传入（NB=10 / SB=8；数组实参可能大于 order）。
/// cosf 须与 ffmpeg 所链 libm 位级一致：Zig compiler_rt 自带 cosf 在个别输入上
/// 与 glibc 差 1 ulp，故经 dlsym(RTLD_NEXT) 取系统 cosf（dlsym 失败时回退 @cos）。
var cosf_ptr: ?*const fn (f32) callconv(.c) f32 = null;
var cosf_inited: bool = false;

extern "c" fn dlopen(filename: ?[*:0]const u8, flags: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;

fn cosfGlibc(x: f32) f32 {
    if (builtin.os.tag != .linux) return @cos(x); // 非 Linux（win/mac）直接用内置
    if (!cosf_inited) {
        cosf_inited = true;
        // 经 dlopen("libm.so.6"/"libm.so.0") 取系统 libm 的 cosf（与 ffmpeg 所链
        // libm 同一 ifunc 实现）；失败时回退 Zig @cos（个别输入可能差 1 ulp）。
        const RTLD_NOW: c_int = 2;
        const libm_names = [_][*:0]const u8{ "libm.so.6", "libm.so.0" };
        for (libm_names) |name| {
            if (dlopen(name, RTLD_NOW)) |h| {
                if (dlsym(h, "cosf")) |sym| {
                    cosf_ptr = @ptrCast(@alignCast(sym));
                    break;
                }
            }
        }
    }
    if (cosf_ptr) |f| return f(x);
    return @cos(x);
}

fn lspToLpc(freq: []const f32, order: usize, ak: []f32) void {
    var wp = [_]f32{0} ** (4 * NB_ORDER + 2);
    var x_freq: [NB_ORDER]f32 = undefined;
    const m = order >> 1;

    var xin1: f32 = 1;
    var xin2: f32 = 1;

    for (0..order) |i| x_freq[i] = -cosfGlibc(freq[i]);

    var n0: usize = 0; // pw 指针（pw + i*4）
    for (0..order + 1) |j| {
        var iw: usize = 0; // C: i2
        var i: usize = 0;
        while (i < m) : (i += 1) {
            n0 = i * 4;
            const xout1 = xin1 + 2.0 * x_freq[iw] * wp[n0] + wp[n0 + 1];
            const xout2 = xin2 + 2.0 * x_freq[iw + 1] * wp[n0 + 2] + wp[n0 + 3];
            wp[n0 + 1] = wp[n0];
            wp[n0 + 3] = wp[n0 + 2];
            wp[n0] = xin1;
            wp[n0 + 2] = xin2;
            xin1 = xout1;
            xin2 = xout2;
            iw += 2;
        }
        // 循环后 n0 = 4*(m-1)：n0[4] = wp[4m]，n0[5] = wp[4m+1]
        const xout1 = xin1 + wp[n0 + 4];
        const xout2 = xin2 - wp[n0 + 5];
        if (j > 0) ak[j - 1] = (xout1 + xout2) * 0.5;
        wp[n0 + 4] = xin1;
        wp[n0 + 5] = xin2;
        xin1 = 0;
        xin2 = 0;
    }
}

// ---------------------------------------------------------------------------
// LSP 反量化（lsp_unquant_lbr / _nb / _high）
// ---------------------------------------------------------------------------

fn lspUnquantLbr(lsp: []f32, order: usize, gb: *BitReader) void {
    for (0..order) |i| lsp[i] = 0.25 * @as(f32, @floatFromInt(i)) + 0.25;

    var id = gb.getBits(6);
    for (0..10) |i| lsp[i] += 0.00390625 * @as(f32, @floatFromInt(t.cdbk_nb[id * 10 + i]));

    id = gb.getBits(6);
    for (0..5) |i| lsp[i] += 0.001953125 * @as(f32, @floatFromInt(t.cdbk_nb_low1[id * 5 + i]));

    id = gb.getBits(6);
    for (0..5) |i| lsp[i + 5] += 0.001953125 * @as(f32, @floatFromInt(t.cdbk_nb_high1[id * 5 + i]));
}

fn lspUnquantNb(lsp: []f32, order: usize, gb: *BitReader) void {
    for (0..order) |i| lsp[i] = 0.25 * @as(f32, @floatFromInt(i)) + 0.25;

    var id = gb.getBits(6);
    for (0..10) |i| lsp[i] += 0.00390625 * @as(f32, @floatFromInt(t.cdbk_nb[id * 10 + i]));

    id = gb.getBits(6);
    for (0..5) |i| lsp[i] += 0.001953125 * @as(f32, @floatFromInt(t.cdbk_nb_low1[id * 5 + i]));

    id = gb.getBits(6);
    for (0..5) |i| lsp[i] += 0.0009765625 * @as(f32, @floatFromInt(t.cdbk_nb_low2[id * 5 + i]));

    id = gb.getBits(6);
    for (0..5) |i| lsp[i + 5] += 0.001953125 * @as(f32, @floatFromInt(t.cdbk_nb_high1[id * 5 + i]));

    id = gb.getBits(6);
    for (0..5) |i| lsp[i + 5] += 0.0009765625 * @as(f32, @floatFromInt(t.cdbk_nb_high2[id * 5 + i]));
}

fn lspUnquantHigh(lsp: []f32, order: usize, gb: *BitReader) void {
    for (0..order) |i| lsp[i] = 0.3125 * @as(f32, @floatFromInt(i)) + 0.75;

    var id = gb.getBits(6);
    for (0..order) |i| lsp[i] += 0.00390625 * @as(f32, @floatFromInt(t.high_lsp_cdbk[id * order + i]));

    id = gb.getBits(6);
    for (0..order) |i| lsp[i] += 0.001953125 * @as(f32, @floatFromInt(t.high_lsp_cdbk2[id * order + i]));
}

// ---------------------------------------------------------------------------
// 长期预测（pitch）反量化
// ---------------------------------------------------------------------------

pub const LtpParam = struct {
    gain_cdbk: []const i8,
    gain_bits: u5,
    pitch_bits: u5,
};

const ltp_params_vlbr = LtpParam{ .gain_cdbk = &t.gain_cdbk_lbr, .gain_bits = 5, .pitch_bits = 0 };
const ltp_params_lbr = LtpParam{ .gain_cdbk = &t.gain_cdbk_lbr, .gain_bits = 5, .pitch_bits = 7 };
const ltp_params_med = LtpParam{ .gain_cdbk = &t.gain_cdbk_lbr, .gain_bits = 5, .pitch_bits = 7 };
const ltp_params_nb = LtpParam{ .gain_cdbk = &t.gain_cdbk_nb, .gain_bits = 7, .pitch_bits = 7 };

const LtpUnquant = *const fn (
    exc_buf: *[NB_DEC_BUFFER]f32,
    exc_off: usize,
    exc_out: []f32,
    start: i32,
    end: i32,
    pitch_coef: f32,
    par: *const LtpParam,
    nsf: usize,
    pitch_val: *i32,
    gain_val: *[3]f32,
    gb: *BitReader,
    count_lost: i32,
    subframe_offset: i32,
    last_pitch_gain: f32,
    cdbk_offset: i32,
) void;

fn forcedPitchUnquant(
    exc_buf: *[NB_DEC_BUFFER]f32,
    exc_off: usize,
    exc_out: []f32,
    start: i32,
    end: i32,
    pitch_coef: f32,
    par: *const LtpParam,
    nsf: usize,
    pitch_val: *i32,
    gain_val: *[3]f32,
    gb: *BitReader,
    count_lost: i32,
    subframe_offset: i32,
    last_pitch_gain: f32,
    cdbk_offset: i32,
) void {
    _ = end;
    _ = par;
    _ = gb;
    _ = count_lost;
    _ = subframe_offset;
    _ = last_pitch_gain;
    _ = cdbk_offset;
    std.debug.assert(!std.math.isNan(pitch_coef));
    const pc = @min(pitch_coef, 0.99);
    for (0..nsf) |i| {
        const v = eat(exc_buf, @intCast(exc_off), @as(isize, @intCast(i)) - start) * pc;
        exc_out[i] = v;
        eset(exc_buf, @intCast(exc_off), @intCast(i), v);
    }
    pitch_val.* = start;
    gain_val[0] = 0.0;
    gain_val[2] = 0.0;
    gain_val[1] = pc;
}

fn pitchUnquant3tap(
    exc_buf: *[NB_DEC_BUFFER]f32,
    exc_off: usize,
    exc_out: []f32,
    start: i32,
    end: i32,
    pitch_coef: f32,
    par: *const LtpParam,
    nsf: usize,
    pitch_val: *i32,
    gain_val: *[3]f32,
    gb: *BitReader,
    count_lost: i32,
    subframe_offset: i32,
    last_pitch_gain: f32,
    cdbk_offset: i32,
) void {
    _ = end;
    _ = pitch_coef;

    const gain_cdbk_size = @as(usize, 1) << par.gain_bits;
    const base = 4 * gain_cdbk_size * @as(usize, @intCast(cdbk_offset));

    var pitch: i32 = @intCast(gb.getBits(par.pitch_bits));
    pitch += start;
    const gain_index = gb.getBits(par.gain_bits);
    var gain: [3]f32 = undefined;
    gain[0] = 0.015625 * @as(f32, @floatFromInt(par.gain_cdbk[base + gain_index * 4])) + 0.5;
    gain[1] = 0.015625 * @as(f32, @floatFromInt(par.gain_cdbk[base + gain_index * 4 + 1])) + 0.5;
    gain[2] = 0.015625 * @as(f32, @floatFromInt(par.gain_cdbk[base + gain_index * 4 + 2])) + 0.5;

    if (count_lost != 0 and pitch > subframe_offset) {
        var tmp: f32 = if (count_lost < 4) last_pitch_gain else 0.5 * last_pitch_gain;
        tmp = @min(tmp, 0.95);
        const gain_sum = gain3tap1tap(&gain);
        if (gain_sum > tmp and gain_sum > 0) {
            const fact = tmp / gain_sum;
            for (&gain) |*g| g.* *= fact;
        }
    }

    pitch_val.* = pitch;
    gain_val[0] = gain[0];
    gain_val[1] = gain[1];
    gain_val[2] = gain[2];
    @memset(exc_out, 0);

    for (0..3) |i| {
        const pp: isize = @as(isize, pitch) + 1 - @as(isize, @intCast(i));
        const tmp1: isize = @min(@as(isize, @intCast(nsf)), pp);
        var j: isize = 0;
        while (j < tmp1) : (j += 1) {
            exc_out[@intCast(j)] += gain[2 - i] * eat(exc_buf, @intCast(exc_off), j - pp);
        }
        const tmp3: isize = @min(@as(isize, @intCast(nsf)), pp + @as(isize, pitch));
        j = tmp1;
        while (j < tmp3) : (j += 1) {
            exc_out[@intCast(j)] += gain[2 - i] * eat(exc_buf, @intCast(exc_off), j - pp - @as(isize, pitch));
        }
    }
}

// ---------------------------------------------------------------------------
// 创新码本反量化
// ---------------------------------------------------------------------------

pub const SplitCbParams = struct {
    subvect_size: usize,
    nb_subvect: usize,
    shape_cb: []const i8,
    shape_bits: u5,
    have_sign: bool,
};

const split_cb_nb_ulbr = SplitCbParams{ .subvect_size = 20, .nb_subvect = 2, .shape_cb = &t.exc_20_32_table, .shape_bits = 5, .have_sign = false };
const split_cb_nb_vlbr = SplitCbParams{ .subvect_size = 10, .nb_subvect = 4, .shape_cb = &t.exc_10_16_table, .shape_bits = 4, .have_sign = false };
const split_cb_nb_lbr = SplitCbParams{ .subvect_size = 10, .nb_subvect = 4, .shape_cb = &t.exc_10_32_table, .shape_bits = 5, .have_sign = false };
const split_cb_nb_med = SplitCbParams{ .subvect_size = 8, .nb_subvect = 5, .shape_cb = &t.exc_8_128_table, .shape_bits = 7, .have_sign = false };
const split_cb_nb = SplitCbParams{ .subvect_size = 5, .nb_subvect = 8, .shape_cb = &t.exc_5_64_table, .shape_bits = 6, .have_sign = false };
const split_cb_sb = SplitCbParams{ .subvect_size = 5, .nb_subvect = 8, .shape_cb = &t.exc_5_256_table, .shape_bits = 8, .have_sign = false };
const split_cb_high = SplitCbParams{ .subvect_size = 8, .nb_subvect = 5, .shape_cb = &t.hexc_table, .shape_bits = 7, .have_sign = true };
const split_cb_high_lbr = SplitCbParams{ .subvect_size = 10, .nb_subvect = 4, .shape_cb = &t.hexc_10_32_table, .shape_bits = 5, .have_sign = false };

const InnovUnquant = *const fn (exc: []f32, par: *const SplitCbParams, nsf: usize, gb: *BitReader, seed: *u32) void;

fn noiseCodebookUnquant(exc: []f32, par: *const SplitCbParams, nsf: usize, gb: *BitReader, seed: *u32) void {
    _ = par;
    _ = gb;
    for (0..nsf) |i| exc[i] = speexRand(1.0, seed);
}

fn splitCbShapeSignUnquant(exc: []f32, par: *const SplitCbParams, nsf: usize, gb: *BitReader, seed: *u32) void {
    _ = nsf;
    _ = seed;
    var signs: [10]u32 = undefined;
    var ind: [10]u32 = undefined;
    for (0..par.nb_subvect) |i| {
        signs[i] = if (par.have_sign) gb.getBits1() else 0;
        ind[i] = gb.getBits(par.shape_bits);
    }
    for (0..par.nb_subvect) |i| {
        const s: f32 = if (signs[i] != 0) -1.0 else 1.0;
        for (0..par.subvect_size) |j| {
            exc[par.subvect_size * i + j] += s * 0.03125 *
                @as(f32, @floatFromInt(par.shape_cb[ind[i] * par.subvect_size + j]));
        }
    }
}

// ---------------------------------------------------------------------------
// 子模式 / 模式表（nb_submode* / wb_submode* / speex_modes）
// ---------------------------------------------------------------------------

pub const Submode = struct {
    lbr_pitch: i8,
    forced_pitch_gain: bool,
    have_subframe_gain: u8,
    double_codebook: bool,
    lsp_unquant: *const fn ([]f32, usize, *BitReader) void,
    ltp_unquant: ?LtpUnquant,
    LtpParam: ?*const LtpParam,
    innovation_unquant: ?InnovUnquant,
    innovation_params: ?*const SplitCbParams,
    comb_gain: f32,
};

/// 2150 bps "vocoder-like"（comfort noise / DTX）
const nb_submode1 = Submode{ .lbr_pitch = 0, .forced_pitch_gain = true, .have_subframe_gain = 0, .double_codebook = false, .lsp_unquant = lspUnquantLbr, .ltp_unquant = forcedPitchUnquant, .LtpParam = null, .innovation_unquant = noiseCodebookUnquant, .innovation_params = null, .comb_gain = -1.0 };
/// 5.95 kbps
const nb_submode2 = Submode{ .lbr_pitch = 0, .forced_pitch_gain = false, .have_subframe_gain = 0, .double_codebook = false, .lsp_unquant = lspUnquantLbr, .ltp_unquant = pitchUnquant3tap, .LtpParam = &ltp_params_vlbr, .innovation_unquant = splitCbShapeSignUnquant, .innovation_params = &split_cb_nb_vlbr, .comb_gain = 0.6 };
/// 8 kbps
const nb_submode3 = Submode{ .lbr_pitch = -1, .forced_pitch_gain = false, .have_subframe_gain = 1, .double_codebook = false, .lsp_unquant = lspUnquantLbr, .ltp_unquant = pitchUnquant3tap, .LtpParam = &ltp_params_lbr, .innovation_unquant = splitCbShapeSignUnquant, .innovation_params = &split_cb_nb_lbr, .comb_gain = 0.55 };
/// 11 kbps
const nb_submode4 = Submode{ .lbr_pitch = -1, .forced_pitch_gain = false, .have_subframe_gain = 1, .double_codebook = false, .lsp_unquant = lspUnquantLbr, .ltp_unquant = pitchUnquant3tap, .LtpParam = &ltp_params_med, .innovation_unquant = splitCbShapeSignUnquant, .innovation_params = &split_cb_nb_med, .comb_gain = 0.45 };
/// 15 kbps
const nb_submode5 = Submode{ .lbr_pitch = -1, .forced_pitch_gain = false, .have_subframe_gain = 3, .double_codebook = false, .lsp_unquant = lspUnquantNb, .ltp_unquant = pitchUnquant3tap, .LtpParam = &ltp_params_nb, .innovation_unquant = splitCbShapeSignUnquant, .innovation_params = &split_cb_nb, .comb_gain = 0.25 };
/// 18.2 kbps
const nb_submode6 = Submode{ .lbr_pitch = -1, .forced_pitch_gain = false, .have_subframe_gain = 3, .double_codebook = false, .lsp_unquant = lspUnquantNb, .ltp_unquant = pitchUnquant3tap, .LtpParam = &ltp_params_nb, .innovation_unquant = splitCbShapeSignUnquant, .innovation_params = &split_cb_sb, .comb_gain = 0.15 };
/// 24.6 kbps
const nb_submode7 = Submode{ .lbr_pitch = -1, .forced_pitch_gain = false, .have_subframe_gain = 3, .double_codebook = true, .lsp_unquant = lspUnquantNb, .ltp_unquant = pitchUnquant3tap, .LtpParam = &ltp_params_nb, .innovation_unquant = splitCbShapeSignUnquant, .innovation_params = &split_cb_nb, .comb_gain = 0.05 };
/// 3.95 kbps
const nb_submode8 = Submode{ .lbr_pitch = 0, .forced_pitch_gain = true, .have_subframe_gain = 0, .double_codebook = false, .lsp_unquant = lspUnquantLbr, .ltp_unquant = forcedPitchUnquant, .LtpParam = null, .innovation_unquant = noiseCodebookUnquant, .innovation_params = null, .comb_gain = 0.5 };

const wb_submode1 = Submode{ .lbr_pitch = 0, .forced_pitch_gain = false, .have_subframe_gain = 1, .double_codebook = false, .lsp_unquant = lspUnquantHigh, .ltp_unquant = null, .LtpParam = null, .innovation_unquant = null, .innovation_params = null, .comb_gain = -1.0 };
const wb_submode2 = Submode{ .lbr_pitch = 0, .forced_pitch_gain = false, .have_subframe_gain = 1, .double_codebook = false, .lsp_unquant = lspUnquantHigh, .ltp_unquant = null, .LtpParam = null, .innovation_unquant = splitCbShapeSignUnquant, .innovation_params = &split_cb_high_lbr, .comb_gain = -1.0 };
const wb_submode3 = Submode{ .lbr_pitch = 0, .forced_pitch_gain = false, .have_subframe_gain = 1, .double_codebook = false, .lsp_unquant = lspUnquantHigh, .ltp_unquant = null, .LtpParam = null, .innovation_unquant = splitCbShapeSignUnquant, .innovation_params = &split_cb_high, .comb_gain = -1.0 };
const wb_submode4 = Submode{ .lbr_pitch = 0, .forced_pitch_gain = false, .have_subframe_gain = 1, .double_codebook = true, .lsp_unquant = lspUnquantHigh, .ltp_unquant = null, .LtpParam = null, .innovation_unquant = splitCbShapeSignUnquant, .innovation_params = &split_cb_high, .comb_gain = -1.0 };

pub const SpeexMode = struct {
    modeID: u32,
    frame_size: usize,
    subframe_size: usize,
    lpc_size: usize,
    folding_gain: f32,
    submodes: *const [NB_SUBMODES]?*const Submode,
    default_submode: u32,
};

const nb_submodes = [NB_SUBMODES]?*const Submode{ null, &nb_submode1, &nb_submode2, &nb_submode3, &nb_submode4, &nb_submode5, &nb_submode6, &nb_submode7, &nb_submode8 };
const wb_submodes = [NB_SUBMODES]?*const Submode{ null, &wb_submode1, &wb_submode2, &wb_submode3, &wb_submode4, null, null, null, null };
const uhb_submodes = [NB_SUBMODES]?*const Submode{ null, &wb_submode1, null, null, null, null, null, null, null };

pub const speex_modes = [SPEEX_NB_MODES]SpeexMode{
    .{ .modeID = 0, .frame_size = NB_FRAME_SIZE, .subframe_size = NB_SUBFRAME_SIZE, .lpc_size = NB_ORDER, .folding_gain = 0, .submodes = &nb_submodes, .default_submode = 5 },
    .{ .modeID = 1, .frame_size = NB_FRAME_SIZE, .subframe_size = NB_SUBFRAME_SIZE, .lpc_size = 8, .folding_gain = 0.9, .submodes = &wb_submodes, .default_submode = 3 },
    .{ .modeID = 2, .frame_size = 320, .subframe_size = 80, .lpc_size = 8, .folding_gain = 0.7, .submodes = &uhb_submodes, .default_submode = 1 },
};

// ---------------------------------------------------------------------------
// 解码器状态（DecoderState）
// ---------------------------------------------------------------------------

pub const DecoderState = struct {
    mode: *const SpeexMode,
    modeID: u32,
    first: bool = true,
    full_frame_size: usize = 0,
    is_wideband: bool = false,
    count_lost: i32 = 0,
    frame_size: usize = 0,
    subframe_size: usize = 0,
    nb_subframes: usize = 0,
    lpc_size: usize = 0,
    last_ol_gain: f32 = 0,
    last_pitch: i32 = 40,
    last_pitch_gain: f32 = 0,
    seed: u32 = 1000,
    submodeID: u32 = 0,
    lpc_enh_enabled: bool = true,
    voc_m1: f32 = 0,
    voc_m2: f32 = 0,
    voc_mean: f32 = 0,
    voc_offset: i32 = 0,
    dtx_enabled: bool = false,
    highpass_enabled: bool = false,

    exc_buf: [NB_DEC_BUFFER]f32 = [_]f32{0} ** NB_DEC_BUFFER,
    mem_hp: [2]f32 = .{ 0, 0 },
    old_qlsp: [NB_ORDER]f32 = [_]f32{0} ** NB_ORDER,
    interp_qlpc: [NB_ORDER]f32 = [_]f32{0} ** NB_ORDER,
    mem_sp: [NB_ORDER]f32 = [_]f32{0} ** NB_ORDER,
    g0_mem: [QMF_ORDER]f32 = [_]f32{0} ** QMF_ORDER,
    g1_mem: [QMF_ORDER]f32 = [_]f32{0} ** QMF_ORDER,
    pi_gain: [NB_NB_SUBFRAMES]f32 = [_]f32{0} ** NB_NB_SUBFRAMES,
    exc_rms: [NB_NB_SUBFRAMES]f32 = [_]f32{0} ** NB_NB_SUBFRAMES,

    pub fn init(self: *DecoderState, mode: *const SpeexMode) void {
        self.* = .{ .mode = mode, .modeID = mode.modeID };
        self.is_wideband = mode.modeID > 0;
        self.submodeID = mode.default_submode;
        self.subframe_size = mode.subframe_size;
        self.lpc_size = mode.lpc_size;
        self.full_frame_size = (1 + @as(usize, if (mode.modeID > 0) 1 else 0)) * mode.frame_size;
        self.nb_subframes = mode.frame_size / mode.subframe_size;
        self.frame_size = mode.frame_size;
        self.lpc_enh_enabled = true;
        self.last_pitch = 40;
        self.count_lost = 0;
        self.seed = 1000;
        self.highpass_enabled = mode.modeID == 0;
    }
};

// ---------------------------------------------------------------------------
// in-band 处理（请求 / 立体声）
// ---------------------------------------------------------------------------

pub const StereoState = struct {
    balance: f32 = 1.0,
    e_ratio: f32 = 0.5,
    smooth_left: f32 = 1.0,
    smooth_right: f32 = 1.0,
};

pub const e_ratio_quant = [4]f32{ 0.25, 0.315, 0.397, 0.5 };

/// speex_std_stereo
fn stdStereo(gb: *BitReader, stereo: *StereoState) void {
    const sign: f32 = if (gb.getBits1() != 0) -1.0 else 1.0;
    // expf(sign*.25f*bits)：64 值查表（低 5 位幅度 + 符号位）
    const mag: u32 = gb.getBits(5);
    stereo.balance = t.exp_stereo_tab[mag | @as(u32, @intFromBool(sign < 0)) << 5];
    stereo.e_ratio = e_ratio_quant[gb.getBits(2)];
}

/// speex_inband_handler（返回 void：C 版错误仅来自 get_bits，位流读取此处不失败）
fn inbandHandler(gb: *BitReader, stereo: *StereoState) void {
    const id = gb.getBits(4);
    if (id == SPEEX_INBAND_STEREO) {
        stdStereo(gb, stereo);
    } else {
        const adv: i64 = if (id < 2) 1 else if (id < 8) 4 else if (id < 10) 8 else if (id < 12) 16 else if (id < 14) 32 else 64;
        gb.skipLong(adv);
    }
}

// ---------------------------------------------------------------------------
// 感知增强（multicomb / interp_pitch）
// ---------------------------------------------------------------------------

fn computeRms2(buf: *const [NB_DEC_BUFFER]f32, off: isize, len: usize) f32 {
    var sum: f32 = 0;
    for (0..len) |i| {
        const v = eat(buf, off, @intCast(i));
        sum += v * v;
    }
    return @sqrt(0.1 + sum / @as(f32, @floatFromInt(len)));
}

fn innerProd2(buf: *const [NB_DEC_BUFFER]f32, a_off: isize, b_off: isize, len: usize) f32 {
    var sum: f32 = 0;
    var i: usize = 0;
    while (i < len) : (i += 8) {
        var part: f32 = 0;
        inline for (0..8) |k| {
            part += eat(buf, a_off, @intCast(i + k)) * eat(buf, b_off, @intCast(i + k));
        }
        sum += part;
    }
    return sum;
}

/// inner_prod(局部数组 x, exc_buf[b_off..]) 混合内积
fn innerProdMix(x: []const f32, buf: *const [NB_DEC_BUFFER]f32, b_off: isize, len: usize) f32 {
    var sum: f32 = 0;
    var i: usize = 0;
    while (i < len) : (i += 8) {
        var part: f32 = 0;
        inline for (0..8) |k| {
            part += x[i + k] * eat(buf, b_off, @intCast(i + k));
        }
        sum += part;
    }
    return sum;
}

fn interpPitch(
    exc_buf: *const [NB_DEC_BUFFER]f32,
    exc_base: isize,
    interp: []f32,
    pitch: i32,
    len: usize,
) i32 {
    var corr: [4][7]f32 = undefined;
    for (0..7) |i| {
        corr[0][i] = innerProd2(exc_buf, exc_base, exc_base - @as(isize, pitch) - 3 + @as(isize, @intCast(i)), len);
    }
    for (0..3) |i| {
        for (0..7) |j| {
            var tmp: f32 = 0;
            var ia: isize = 3 - @as(isize, @intCast(j)); // C: i1
            if (ia < 0) ia = 0;
            var ib: isize = 10 - @as(isize, @intCast(j)); // C: i2
            if (ib > 7) ib = 7;
            var k = ia;
            while (k < ib) : (k += 1) {
                tmp += t.shift_filt[i][@intCast(k)] * corr[0][@intCast(@as(isize, @intCast(j)) + k - 3)];
            }
            corr[i + 1][j] = tmp;
        }
    }
    var maxi: usize = 0;
    var maxj: usize = 0;
    var maxcorr = corr[0][0];
    for (0..4) |i| {
        for (0..7) |j| {
            if (corr[i][j] > maxcorr) {
                maxcorr = corr[i][j];
                maxi = i;
                maxj = j;
            }
        }
    }
    for (0..len) |i| {
        var tmp: f32 = 0;
        if (maxi > 0) {
            for (0..7) |k| {
                tmp += eat(exc_buf, exc_base, @as(isize, @intCast(i)) -
                    (@as(isize, pitch) - @as(isize, @intCast(maxj)) + 3) +
                    @as(isize, @intCast(k)) - 3) * t.shift_filt[maxi - 1][k];
            }
        } else {
            tmp = eat(exc_buf, exc_base, @as(isize, @intCast(i)) -
                (@as(isize, pitch) - @as(isize, @intCast(maxj)) + 3));
        }
        interp[i] = tmp;
    }
    return pitch - @as(i32, @intCast(maxj)) + 3;
}

fn multicomb(
    exc_buf: *const [NB_DEC_BUFFER]f32,
    exc_base: isize,
    new_exc: []f32,
    nsf: usize,
    pitch: i32,
    max_pitch: i32,
    comb_gain: f32,
) void {
    var iexc: [4 * NB_SUBFRAME_SIZE]f32 = undefined;
    const corr_pitch = pitch;

    _ = interpPitch(exc_buf, exc_base, iexc[0..nsf], corr_pitch, 80);
    if (corr_pitch > max_pitch) {
        _ = interpPitch(exc_buf, exc_base, iexc[nsf .. 2 * nsf], 2 * corr_pitch, 80);
    } else {
        _ = interpPitch(exc_buf, exc_base, iexc[nsf .. 2 * nsf], -corr_pitch, 80);
    }

    const iexc0_mag = @sqrt(1000.0 + innerProd(iexc[0..nsf], iexc[0..nsf]));
    const iexc1_mag = @sqrt(1000.0 + innerProd(iexc[nsf .. 2 * nsf], iexc[nsf .. 2 * nsf]));
    const exc_mag = @sqrt(1.0 + innerProd2(exc_buf, exc_base, exc_base, nsf));
    const corr0 = innerProdMix(iexc[0..nsf], exc_buf, exc_base, nsf);
    const corr1 = innerProdMix(iexc[nsf .. 2 * nsf], exc_buf, exc_base, nsf);
    const pgain1: f32 = if (corr0 > iexc0_mag * exc_mag) 1.0 else (corr0 / exc_mag) / iexc0_mag;
    const pgain2: f32 = if (corr1 > iexc1_mag * exc_mag) 1.0 else (corr1 / exc_mag) / iexc1_mag;
    const gg1 = exc_mag / iexc0_mag;
    const gg2 = exc_mag / iexc1_mag;
    var c1: f32 = 0;
    var c2: f32 = 0;
    if (comb_gain > 0) {
        c1 = 0.4 * comb_gain + 0.07;
        c2 = 0.5 + 1.72 * (c1 - 0.07);
    }
    var g1 = 1.0 - c2 * pgain1 * pgain1;
    var g2 = 1.0 - c2 * pgain2 * pgain2;
    g1 = @max(g1, c1);
    g2 = @max(g2, c1);
    g1 = c1 / g1;
    g2 = c1 / g2;

    var gain0: f32 = undefined;
    var gain1: f32 = undefined;
    if (corr_pitch > max_pitch) {
        gain0 = 0.7 * g1 * gg1;
        gain1 = 0.3 * g2 * gg2;
    } else {
        gain0 = 0.6 * g1 * gg1;
        gain1 = 0.6 * g2 * gg2;
    }
    for (0..nsf) |i| {
        new_exc[i] = eat(exc_buf, exc_base, @intCast(i)) +
            (gain0 * iexc[i]) + (gain1 * iexc[i + nsf]);
    }
    var new_ener = computeRms(new_exc[0..nsf]);
    var old_ener = computeRms2(exc_buf, exc_base, nsf);

    old_ener = @max(old_ener, 1.0);
    new_ener = @max(new_ener, 1.0);
    old_ener = @min(old_ener, new_ener);
    const ngain = old_ener / new_ener;

    for (0..nsf) |i| new_exc[i] *= ngain;
}

// ---------------------------------------------------------------------------
// QMF 合成（sb 层 + 低带 → 全带；h0 为 64 阶原型滤波器）
// ---------------------------------------------------------------------------

fn qmfSynth(
    x1: []const f32,
    x2: []const f32,
    a: *const [QMF_ORDER]f32,
    y: []f32,
    n: usize,
    mem1: *[QMF_ORDER]f32,
    mem2: *[QMF_ORDER]f32,
) void {
    const m = QMF_ORDER;
    const m2 = m >> 1;
    const n2 = n >> 1;
    var xx1: [352]f32 = undefined;
    var xx2: [352]f32 = undefined;

    for (0..n2) |i| {
        xx1[i] = x1[n2 - 1 - i];
        xx2[i] = x2[n2 - 1 - i];
    }
    for (0..m2) |i| {
        xx1[n2 + i] = mem1[2 * i + 1];
        xx2[n2 + i] = mem2[2 * i + 1];
    }

    var i: usize = 0;
    while (i < n2) : (i += 2) {
        var y0: f32 = 0;
        var y1: f32 = 0;
        var y2: f32 = 0;
        var y3: f32 = 0;
        var x10 = xx1[n2 - 2 - i];
        var x20 = xx2[n2 - 2 - i];

        var j: usize = 0;
        while (j < m2) : (j += 2) {
            var a0 = a[2 * j];
            var a1 = a[2 * j + 1];
            const x11 = xx1[n2 - 1 + j - i];
            const x21 = xx2[n2 - 1 + j - i];

            y0 += a0 * (x11 - x21);
            y1 += a1 * (x11 + x21);
            y2 += a0 * (x10 - x20);
            y3 += a1 * (x10 + x20);
            a0 = a[2 * j + 2];
            a1 = a[2 * j + 3];
            x10 = xx1[n2 + j - i];
            x20 = xx2[n2 + j - i];

            y0 += a0 * (x10 - x20);
            y1 += a1 * (x10 + x20);
            y2 += a0 * (x11 - x21);
            y3 += a1 * (x11 + x21);
        }
        y[2 * i] = 2.0 * y0;
        y[2 * i + 1] = 2.0 * y1;
        y[2 * i + 2] = 2.0 * y2;
        y[2 * i + 3] = 2.0 * y3;
    }

    for (0..m2) |k| {
        mem1[2 * k + 1] = xx1[k];
        mem2[2 * k + 1] = xx2[k];
    }
}

// ---------------------------------------------------------------------------
// 帧解码（nb_decode / sb_decode）
// ---------------------------------------------------------------------------

pub const FrameCtx = struct {
    st: [SPEEX_NB_MODES]DecoderState,
    stereo: *StereoState,
    /// 容器级 frame_size（SpeexContext.frame_size，头域派生；sb 层数据量校验用）
    container_frame_size: i32 = 0,

    pub fn stAt(self: *FrameCtx, id: u32) *DecoderState {
        return &self.st[id];
    }
};

/// 顶层帧解码入口（speex_modes[s->mode].decode 分派）。
/// `out` 长度须 = 该层 full_frame_size（NB:160 / WB:320 / UWB:640）。
pub fn decodeLayer(
    fc: *FrameCtx,
    st: *DecoderState,
    gb: *BitReader,
    out: []f32,
    packets_left: i32,
    innov_save: ?[]f32,
) error{InvalidData}!void {
    if (st.modeID == 0) {
        return nbDecode(fc, st, gb, out, innov_save);
    }
    return sbDecode(fc, st, gb, out, packets_left, innov_save);
}

/// 窄带层解码（nb_decode）
fn nbDecode(
    fc: *FrameCtx,
    st: *DecoderState,
    gb: *BitReader,
    out: []f32,
    innov_save: ?[]f32,
) error{InvalidData}!void {
    var ol_gain: f32 = 0;
    var ol_pitch_coef: f32 = 0;
    var best_pitch_gain: f32 = 0;
    var pitch_average: f32 = 0;
    var pitch: i32 = 0;
    var ol_pitch: i32 = 0;
    var best_pitch: i32 = 40;
    var innov: [NB_SUBFRAME_SIZE]f32 = undefined;
    var exc32: [NB_SUBFRAME_SIZE]f32 = undefined;
    var interp_qlsp: [NB_ORDER]f32 = undefined;
    var qlsp: [NB_ORDER]f32 = undefined;
    var ak: [NB_ORDER]f32 = undefined;

    const exc_off: isize = EXC_OFF;

    // wideband 层跳过 + in-band 请求 + submode 读取（do-while 结构展开）
    {
        var m: u32 = 0;
        while (true) {
            if (gb.left() < 5) return error.InvalidData;
            var wideband = gb.getBits1();
            if (wideband != 0) {
                var submode = gb.getBits(SB_SUBMODE_BITS);
                var advance: i64 = @as(i64, t.wb_skip_table[submode]) - (SB_SUBMODE_BITS + 1);
                if (advance < 0) return error.InvalidData;
                gb.skipLong(advance);

                if (gb.left() < 5) return error.InvalidData;
                wideband = gb.getBits1();
                if (wideband != 0) {
                    submode = gb.getBits(SB_SUBMODE_BITS);
                    advance = @as(i64, t.wb_skip_table[submode]) - (SB_SUBMODE_BITS + 1);
                    if (advance < 0) return error.InvalidData;
                    gb.skipLong(advance);
                    wideband = gb.getBits1();
                    if (wideband != 0) return error.InvalidData; // >2 wideband 层
                }
            }
            if (gb.left() < 4) return error.InvalidData;
            m = gb.getBits(4);
            if (m == 15) return error.InvalidData; // terminator
            if (m == 14) {
                inbandHandler(gb, fc.stereo);
            } else if (m == 13) {
                const req_size = gb.getBits(4);
                gb.skipLong(5 + 8 * @as(i64, req_size));
            } else if (m > 8) {
                return error.InvalidData;
            }
            if (m <= 8) break;
        }
        st.submodeID = m;
    }

    // 帧移位（跨帧 pitch 历史；copyForwards = memmove 语义）
    std.mem.copyForwards(f32, st.exc_buf[0..SHIFT_LEN], st.exc_buf[NB_FRAME_SIZE..]);

    // null 模式（DTX / 未传输）：舒适噪声
    if (st.mode.submodes[st.submodeID] == null) {
        var lpc: [NB_ORDER]f32 = undefined;
        bwLpc(0.93, &st.interp_qlpc, &lpc);
        const innov_gain = computeRms2(&st.exc_buf, exc_off, NB_FRAME_SIZE);
        for (0..NB_FRAME_SIZE) |i| {
            eset(&st.exc_buf, exc_off, @intCast(i), speexRand(innov_gain, &st.seed));
        }
        iirMem(st.exc_buf[@intCast(exc_off)..][0..NB_FRAME_SIZE], &lpc, out, &st.mem_sp, NB_ORDER);
        st.count_lost = 0;
        return;
    }

    const sm = st.mode.submodes[st.submodeID].?;

    sm.lsp_unquant(&qlsp, NB_ORDER, gb);

    // 丢帧阻尼（顺序解码 count_lost 恒 0，保留 C 语义）
    if (st.count_lost != 0) {
        var lsp_dist: f32 = 0;
        for (0..NB_ORDER) |i| lsp_dist += @abs(st.old_qlsp[i] - qlsp[i]);
        const fact = 0.6 * @exp(-0.2 * lsp_dist); // 丢帧 PLC 路径（顺序解码不可达）
        for (0..NB_ORDER) |i| st.mem_sp[i] = fact * st.mem_sp[i];
    }

    if (st.first or st.count_lost != 0) {
        @memcpy(&st.old_qlsp, &qlsp);
    }

    // 开环 pitch（低码率 pitch 编码）
    if (sm.lbr_pitch != -1) {
        ol_pitch = NB_PITCH_START + @as(i32, @intCast(gb.getBits(7)));
    }

    if (sm.forced_pitch_gain) {
        ol_pitch_coef = 0.066667 * @as(f32, @floatFromInt(gb.getBits(4)));
    }

    // 全局激励增益
    ol_gain = t.exp_gain_tab[gb.getBits(5)]; // expf(k/3.5f)：32 值查表（glibc 位级）

    if (st.submodeID == 1) {
        st.dtx_enabled = gb.getBits(4) == 15;
    }
    if (st.submodeID > 1) {
        st.dtx_enabled = false;
    }

    for (0..NB_NB_SUBFRAMES) |sub| {
        const offset: usize = NB_SUBFRAME_SIZE * sub;
        const exc_e: isize = exc_off + @as(isize, @intCast(offset));

        @memset(st.exc_buf[@intCast(exc_e)..][0..NB_SUBFRAME_SIZE], 0);

        // pitch 约束
        var pit_min: i32 = undefined;
        var pit_max: i32 = undefined;
        if (sm.lbr_pitch != -1) {
            const margin: i32 = sm.lbr_pitch;
            if (margin != 0) {
                pit_min = @max(ol_pitch - margin + 1, NB_PITCH_START);
                pit_max = @min(ol_pitch + margin, NB_PITCH_START);
            } else {
                pit_min = ol_pitch;
                pit_max = ol_pitch;
            }
        } else {
            pit_min = NB_PITCH_START;
            pit_max = NB_PITCH_END;
        }

        var pitch_gain: [3]f32 = .{ 0, 0, 0 };
        sm.ltp_unquant.?(
            &st.exc_buf,
            @intCast(exc_e),
            &exc32,
            pit_min,
            pit_max,
            ol_pitch_coef,
            sm.LtpParam.?,
            NB_SUBFRAME_SIZE,
            &pitch,
            &pitch_gain,
            gb,
            st.count_lost,
            @intCast(offset),
            st.last_pitch_gain,
            0,
        );

        sanitizeValues(&exc32, -32000, 32000);

        const tmp = gain3tap1tap(&pitch_gain);
        pitch_average += tmp;
        if ((tmp > best_pitch_gain and
            @abs(2 * best_pitch - pitch) >= 3 and
            @abs(3 * best_pitch - pitch) >= 4 and
            @abs(4 * best_pitch - pitch) >= 5) or
            (tmp > 0.6 * best_pitch_gain and
                (@abs(best_pitch - 2 * pitch) < 3 or
                    @abs(best_pitch - 3 * pitch) < 4 or
                    @abs(best_pitch - 4 * pitch) < 5)) or
            ((0.67 * tmp) > best_pitch_gain and
                (@abs(2 * best_pitch - pitch) < 3 or
                    @abs(3 * best_pitch - pitch) < 4 or
                    @abs(4 * best_pitch - pitch) < 5)))
        {
            best_pitch = pitch;
            if (tmp > best_pitch_gain) best_pitch_gain = tmp;
        }

        @memset(&innov, 0);

        // 子帧增益校正
        var ener: f32 = undefined;
        if (sm.have_subframe_gain == 3) {
            const q_energy = gb.getBits(3);
            ener = t.exc_gain_quant_scal3[q_energy] * ol_gain;
        } else if (sm.have_subframe_gain == 1) {
            const q_energy = gb.getBits(1);
            ener = t.exc_gain_quant_scal1[q_energy] * ol_gain;
        } else {
            ener = ol_gain;
        }

        // 固定码本
        sm.innovation_unquant.?(&innov, sm.innovation_params.?, NB_SUBFRAME_SIZE, gb, &st.seed);
        signalMul(&innov, ener);

        // 二次码本（部分模式）
        if (sm.double_codebook) {
            var innov2 = [_]f32{0} ** NB_SUBFRAME_SIZE;
            sm.innovation_unquant.?(&innov2, sm.innovation_params.?, NB_SUBFRAME_SIZE, gb, &st.seed);
            signalMul(&innov2, 0.454545 * ener);
            for (0..NB_SUBFRAME_SIZE) |i| innov[i] += innov2[i];
        }
        for (0..NB_SUBFRAME_SIZE) |i| {
            eset(&st.exc_buf, exc_e, @intCast(i), exc32[i] + innov[i]);
        }
        if (innov_save) |iv| {
            @memcpy(iv[offset..][0..NB_SUBFRAME_SIZE], &innov);
        }

        // vocoder 模式（submode 1）
        if (st.submodeID == 1) {
            const g = clipf(1.5 * (ol_pitch_coef - 0.2), 0, 1);
            @memset(st.exc_buf[@intCast(exc_e)..][0..NB_SUBFRAME_SIZE], 0);
            while (st.voc_offset < NB_SUBFRAME_SIZE) {
                if (st.voc_offset >= 0) {
                    eset(&st.exc_buf, exc_e, st.voc_offset, @sqrt(2.0 * @as(f32, @floatFromInt(ol_pitch))) * (g * ol_gain));
                }
                st.voc_offset += ol_pitch;
            }
            st.voc_offset -= NB_SUBFRAME_SIZE;

            for (0..NB_SUBFRAME_SIZE) |i| {
                const exci = eat(&st.exc_buf, exc_e, @intCast(i));
                const nv = (0.7 * exci + 0.3 * st.voc_m1) +
                    ((1.0 - 0.85 * g) * innov[i]) - 0.15 * g * st.voc_m2;
                eset(&st.exc_buf, exc_e, @intCast(i), nv);
                st.voc_m1 = exci;
                st.voc_m2 = innov[i];
                st.voc_mean = 0.8 * st.voc_mean + 0.2 * eat(&st.exc_buf, exc_e, @intCast(i));
                eset(&st.exc_buf, exc_e, @intCast(i), eat(&st.exc_buf, exc_e, @intCast(i)) - st.voc_mean);
            }
        }
    }

    // 感知增强（multicomb）或直拷
    if (st.lpc_enh_enabled and sm.comb_gain > 0 and st.count_lost == 0) {
        multicomb(&st.exc_buf, exc_off - NB_SUBFRAME_SIZE, out[0 .. 2 * NB_SUBFRAME_SIZE], 2 * NB_SUBFRAME_SIZE, best_pitch, 40, sm.comb_gain);
        multicomb(&st.exc_buf, exc_off + NB_SUBFRAME_SIZE, out[2 * NB_SUBFRAME_SIZE .. NB_FRAME_SIZE], 2 * NB_SUBFRAME_SIZE, best_pitch, 40, sm.comb_gain);
    } else {
        for (0..NB_FRAME_SIZE) |k| {
            out[k] = eat(&st.exc_buf, exc_off, @as(isize, @intCast(k)) - NB_SUBFRAME_SIZE);
        }
    }

    // 丢帧重缩放（顺序解码不触发，保留 C 语义）
    if (st.count_lost != 0) {
        const exc_ener = computeRms2(&st.exc_buf, exc_off, NB_FRAME_SIZE);
        const gain = @min(ol_gain / (exc_ener + 1.0), 2.0);
        for (0..NB_FRAME_SIZE) |i| {
            const v = eat(&st.exc_buf, exc_off, @intCast(i)) * gain;
            eset(&st.exc_buf, exc_off, @intCast(i), v);
            out[i] = eat(&st.exc_buf, exc_off, @as(isize, @intCast(i)) - NB_SUBFRAME_SIZE);
        }
    }

    // LSP 插值 → LPC → 合成（逐子帧）
    for (0..NB_NB_SUBFRAMES) |sub| {
        const offset = NB_SUBFRAME_SIZE * sub;
        const sp = out[offset .. offset + NB_SUBFRAME_SIZE];

        lspInterpolate(&st.old_qlsp, &qlsp, &interp_qlsp, NB_ORDER, sub, NB_NB_SUBFRAMES, 0.002);
        lspToLpc(&interp_qlsp, NB_ORDER, &ak);

        var pi_g: f32 = 1.0;
        var i: usize = 0;
        while (i < NB_ORDER) : (i += 2) pi_g += ak[i + 1] - ak[i];
        st.pi_gain[sub] = pi_g;
        st.exc_rms[sub] = computeRms2(&st.exc_buf, exc_off + @as(isize, @intCast(offset)), NB_SUBFRAME_SIZE);

        iirMem(sp, &st.interp_qlpc, sp, &st.mem_sp, NB_ORDER);

        @memcpy(&st.interp_qlpc, &ak);
    }

    if (st.highpass_enabled) {
        // C: highpass(out, out, NB_FRAME_SIZE, ...) —— 仅窄带层自己的 160 样本
        // （out 可能是 WB/UWB 的全帧缓冲，多处理会破坏 mem_hp 与 innov 别名区）
        highpass(out[0..NB_FRAME_SIZE], out[0..NB_FRAME_SIZE], &st.mem_hp, @intFromBool(st.is_wideband));
    }

    @memcpy(&st.old_qlsp, &qlsp);

    st.count_lost = 0;
    st.last_pitch = best_pitch;
    st.last_pitch_gain = 0.25 * pitch_average;
    st.last_ol_gain = ol_gain;
    st.first = false;
}

/// subband 层解码（sb_decode；modeID>0 时先解码低层）
fn sbDecode(
    fc: *FrameCtx,
    st: *DecoderState,
    gb: *BitReader,
    out: []f32,
    packets_left: i32,
    innov_save: ?[]f32,
) error{InvalidData}!void {
    var interp_qlsp: [NB_ORDER]f32 = undefined;
    var qlsp: [NB_ORDER]f32 = undefined;
    var ak: [NB_ORDER]f32 = undefined;

    if (st.modeID > 0) {
        // C: packets_left * s->frame_size < 2*st->frame_size（s->frame_size 为容器级）
        if (@as(i64, packets_left) * @as(i64, fc.container_frame_size) <
            2 * @as(i64, @intCast(st.frame_size)))
        {
            return error.InvalidData;
        }
        const low = fc.stAt(st.modeID - 1);
        // low_innov_alias = out + st->frame_size（低层创新写入高层缓冲）
        const child_innov: ?[]f32 = out[st.frame_size..];
        try decodeLayer(fc, low, gb, out, packets_left, child_innov);
    }

    // "wideband bit"
    {
        const wideband: u32 = if (gb.left() > 0) gb.showBits(1) else 0;
        if (wideband != 0) {
            _ = gb.getBits1();
            st.submodeID = gb.getBits(SB_SUBMODE_BITS);
        } else {
            st.submodeID = 0;
        }
        if (st.submodeID != 0 and st.mode.submodes[st.submodeID] == null) {
            return error.InvalidData;
        }
    }

    const fs = st.frame_size;
    const hfs = st.full_frame_size;

    // null submode（纯低带帧）
    if (st.mode.submodes[st.submodeID] == null) {
        for (0..fs) |i| out[fs + i] = 1e-15;
        st.first = true;
        iirMem(out[fs..hfs], &st.interp_qlpc, out[fs..hfs], &st.mem_sp, st.lpc_size);
        qmfSynth(out[0..fs], out[fs..hfs], &t.h0, out[0..hfs], hfs, &st.g0_mem, &st.g1_mem);
        return;
    }

    const sm = st.mode.submodes[st.submodeID].?;
    const low_st = fc.stAt(st.modeID - 1);
    var low_pi_gain: [NB_NB_SUBFRAMES]f32 = undefined;
    var low_exc_rms: [NB_NB_SUBFRAMES]f32 = undefined;
    @memcpy(&low_pi_gain, &low_st.pi_gain);
    @memcpy(&low_exc_rms, &low_st.exc_rms);

    sm.lsp_unquant(&qlsp, st.lpc_size, gb);

    if (st.first) {
        @memcpy(&st.old_qlsp, &qlsp);
    }

    for (0..st.nb_subframes) |sub| {
        const offset = st.subframe_size * sub;
        const sp = out[fs + offset .. fs + offset + st.subframe_size];
        if (innov_save) |iv| {
            @memset(iv[2 * offset ..][0 .. 2 * st.subframe_size], 0);
        }

        lspInterpolate(&st.old_qlsp, &qlsp, &interp_qlsp, st.lpc_size, sub, st.nb_subframes, 0.05);
        lspToLpc(&interp_qlsp, st.lpc_size, &ak);

        // 4000Hz 处低/高带响应比
        st.pi_gain[sub] = 1.0;
        var rh: f32 = 1.0;
        var i: usize = 0;
        while (i < st.lpc_size) : (i += 2) {
            rh += ak[i + 1] - ak[i];
            st.pi_gain[sub] += ak[i] + ak[i + 1];
        }
        const rl = low_pi_gain[sub];
        const filter_ratio = (rl + 0.01) / (rh + 0.01);

        var exc = [_]f32{0} ** 80;
        if (sm.innovation_unquant == null) {
            // 折叠模式（wb_submode1）：低带创新谱折叠
            // C: g = expf(.125f * (x - 10)) / filter_ratio
            const x: i32 = @intCast(gb.getBits(5));
            const g = t.exp_fold_tab[@intCast(x)] / filter_ratio; // expf(.125f*(x-10))：32 值查表
            const alias_base = st.frame_size; // low_innov_alias 在 out 中
            var fi: usize = 0;
            while (fi < st.subframe_size) : (fi += 2) {
                exc[fi] = st.mode.folding_gain * out[alias_base + offset + fi] * g;
                exc[fi + 1] = -st.mode.folding_gain * out[alias_base + offset + fi + 1] * g;
            }
        } else {
            const el = low_exc_rms[sub];
            var gc: f32 = 0.87360 * t.gc_quant_bound[gb.getBits(4)];
            if (st.subframe_size == 80) {
                // M_SQRT2 为 double 常量：C 中 gc 先升 double 再回落 f32
                gc = @floatCast(@as(f64, gc) * 1.4142135623730951);
            }
            const scale = (gc * el) / filter_ratio;
            sm.innovation_unquant.?(exc[0..st.subframe_size], sm.innovation_params.?, st.subframe_size, gb, &st.seed);
            signalMul(exc[0..st.subframe_size], scale);
            if (sm.double_codebook) {
                var innov2 = [_]f32{0} ** 80;
                sm.innovation_unquant.?(innov2[0..st.subframe_size], sm.innovation_params.?, st.subframe_size, gb, &st.seed);
                signalMul(innov2[0..st.subframe_size], 0.4 * scale);
                for (0..st.subframe_size) |k| exc[k] += innov2[k];
            }
        }

        if (innov_save) |iv| {
            for (0..st.subframe_size) |k| {
                iv[2 * offset + 2 * k] = exc[k];
            }
        }

        // 注意（C 原样）：滤波对象是 st->exc_buf（上一子帧内容），随后才写入新 exc
        iirMem(st.exc_buf[0..st.subframe_size], &st.interp_qlpc, sp, &st.mem_sp, st.lpc_size);
        @memcpy(st.exc_buf[0..80], &exc);
        @memcpy(&st.interp_qlpc, &ak);
        st.exc_rms[sub] = computeRms(st.exc_buf[0..st.subframe_size]);
    }

    qmfSynth(out[0..fs], out[fs..hfs], &t.h0, out[0..hfs], hfs, &st.g0_mem, &st.g1_mem);
    @memcpy(&st.old_qlsp, &qlsp);

    st.first = false;
}
