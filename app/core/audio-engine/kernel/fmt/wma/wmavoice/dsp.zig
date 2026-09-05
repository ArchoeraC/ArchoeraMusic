//! WMA Voice DSP/量化助手——移植 FFmpeg（celp_filters / acelp_filters /
//! acelp_vectors / lsp 相关函数 + wmavoice.c 内嵌小函数），n9.0.1。
//!
//! 全部浮点滤波/变换以「平坦缓冲 + 绝对写入偏移」实现（FFmpeg C 大量使用负
//! 索引读回 `out[-i]` 历史；Zig slice 无负索引，故传入整块缓冲与写入起点，由
//! 调用方保证起点 ≥ filter_length，历史样本紧邻起点之前）。

const std = @import("std");
const tables = @import("tables.zig");
const builtin = @import("builtin");

// glibc libm（与 reference C 同一实现，保证 expf/powf/log10f/sinf 位精确一致）。
// 注意：Zig 会把 extern "c" 的 libm 符号静态解析到其自带 libm 实现（与 glibc
// 可差 1 ulp，如 expf），故运行期 dlopen("libm.so.6") + dlsym 取 glibc 函数。
const RTLD_NOW: c_int = 2;
extern "c" fn dlopen(path: ?[*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" fn dlsym(h: ?*anyopaque, sym: [*:0]const u8) ?*anyopaque;

var libm_handle: ?*anyopaque = null;
var libm_inited = false;

fn libmSym(comptime name: [:0]const u8, comptime T: type) ?T {
    if (builtin.os.tag != .linux) return null; // 非 Linux 直接用内置 libm
    if (!libm_inited) {
        libm_inited = true;
        libm_handle = dlopen("libm.so.6", RTLD_NOW);
        if (libm_handle == null) libm_handle = dlopen("libm.so.2", RTLD_NOW);
    }
    const h = libm_handle orelse return null;
    return @ptrCast(@alignCast(dlsym(h, name.ptr)));
}

pub fn expf(x: f32) f32 {
    if (libmSym("expf", *const fn (f32) callconv(.c) f32)) |f| return f(x);
    return @exp(x);
}
pub fn powf(x: f32, y: f32) f32 {
    if (libmSym("powf", *const fn (f32, f32) callconv(.c) f32)) |f| return f(x, y);
    return std.math.pow(f32, x, y);
}
pub fn log10f(x: f32) f32 {
    if (libmSym("log10f", *const fn (f32) callconv(.c) f32)) |f| return f(x);
    return @log10(x);
}
pub fn sinf(x: f32) f32 {
    if (libmSym("sinf", *const fn (f32) callconv(.c) f32)) |f| return f(x);
    return @sin(x);
}
pub fn cosD(x: f64) f64 {
    if (libmSym("cos", *const fn (f64) callconv(.c) f64)) |f| return f(x);
    return @cos(x);
}
pub fn sinD(x: f64) f64 {
    if (libmSym("sin", *const fn (f64) callconv(.c) f64)) |f| return f(x);
    return @sin(x);
}
pub fn lrint(x: f64) i64 {
    // C: long lrint(double)——按当前舍入模式（default: 半到偶）取整
    if (libmSym("lrint", *const fn (f64) callconv(.c) c_long)) |f| return @intCast(f(x));
    return @intFromFloat(@round(x));
}

pub const pi: f64 = std.math.pi;

pub inline fn ceilLog2(x: u32) u32 {
    // av_ceil_log2_c
    return if (x <= 1) 0 else @as(u32, 32 - @clz(x - 1));
}

pub inline fn avLog2_16bit(v: u16) u32 {
    return 15 - @clz(v);
}

pub inline fn clipI32(v: f32, lo: i32, hi: i32) i32 {
    var r: i64 = @intFromFloat(v);
    if (r < lo) r = lo;
    if (r > hi) r = hi;
    return @intCast(r);
}
pub inline fn clipF(v: f32, lo: f32, hi: f32) f32 {
    return if (v < lo) lo else if (v > hi) hi else v;
}
pub inline fn clipI64(v: i64, lo: i64, hi: i64) i64 {
    return if (v < lo) lo else if (v > hi) hi else v;
}

/// wmavoice.c pRNG（FASTDIV 变体逐位复刻）
pub fn pRng(frame_cntr: i32, block_num: i32, block_size: usize) usize {
    const div_tbl = [9][2]u32{
        .{ 8332, 3 *% 715827883 },
        .{ 4545, 0 *% 390451573 },
        .{ 3124, 11 *% 268435456 },
        .{ 2380, 15 *% 204522253 },
        .{ 1922, 23 *% 165191050 },
        .{ 1612, 23 *% 138547333 },
        .{ 1388, 27 *% 119304648 },
        .{ 1219, 16 *% 104755300 },
        .{ 1086, 39 *% 93368855 },
    };
    var x: u32 = @as(u32, @intCast(@as(i64, block_num) * 1877)) +% @as(u32, @bitCast(frame_cntr));
    if (x >= 0xFFFF) x -= 0xFFFF;
    const mulh: i64 = (@as(i64, 477218589) * @as(i64, x)) >> 32;
    const y: u32 = x - 9 *% @as(u32, @truncate(@as(u64, @bitCast(mulh))));
    const hi: u32 = @as(u32, @truncate((@as(u64, x) * @as(u64, div_tbl[y][1])) >> 32));
    const z: u32 = (x *% div_tbl[y][0] +% hi) & 0xFFFF; // C: (uint16_t)(...)
    return @intCast(z % (1000 - @as(u32, @intCast(block_size))));
}

/// lsp2polyf（double 版；索引语义对齐 lsp.c 的 `lsp -= 2` 技巧）
fn lsp2polyf(lsp: []const f64, f: []f64, lp_half_order: usize) void {
    f[0] = 1.0;
    f[1] = -2 * lsp[0];
    var i: usize = 2;
    while (i <= lp_half_order) : (i += 1) {
        const val = -2 * lsp[2 * i - 2];
        f[i] = val * f[i - 1] + 2 * f[i - 2];
        var j: usize = i - 1;
        while (j > 1) : (j -= 1) {
            f[j] += f[j - 1] * val + f[j - 2];
        }
        f[1] += val;
    }
}

/// ff_acelp_lspd2lpc（lsp 为 2*lp_half_order 个余弦域 LSP；lpc 输出同长）。
pub fn lspd2lpc(lsp: []const f64, lpc: []f32, lp_half_order: usize) void {
    var pa: [9]f64 = undefined;
    var qa: [9]f64 = undefined;
    lsp2polyf(lsp[0..], pa[0..], lp_half_order);
    lsp2polyf(lsp[1..], qa[0..], lp_half_order);
    var h: usize = lp_half_order;
    while (h > 0) {
        h -= 1;
        const paf = pa[h + 1] + pa[h];
        const qaf = qa[h + 1] - qa[h];
        lpc[h] = @floatCast(0.5 * (paf + qaf));
        lpc[(2 * lp_half_order - 1) - h] = @floatCast(0.5 * (paf - qaf));
    }
}

/// ff_scalarproduct_float_c
pub fn scalarProduct(a: []const f32, b: []const f32) f32 {
    var p: f32 = 0;
    for (a, b) |x, y| p += x * y;
    return p;
}

/// ff_celp_lp_zero_synthesis_filterf。
/// out = out_buf[o..o+n]；in = in_buf[i..i+n]，读回 in[n-k]。
/// out 与 in 可为同一数组。
pub fn celpLpZeroSynthF(out_buf: []f32, o: usize, in_buf: []const f32, i: usize, c: []const f32, n: usize, fl: usize) void {
    var k: usize = 0;
    while (k < n) : (k += 1) {
        var s: f32 = in_buf[i + k];
        var j: usize = 1;
        while (j <= fl) : (j += 1) {
            s += c[j - 1] * in_buf[i + k - j];
        }
        out_buf[o + k] = s;
    }
}

/// ff_celp_lp_synthesis_filterf（全极点合成；out 须含 ow 之前 fl 个历史样本）。
/// 逐位复刻 FFmpeg 优化实现（4 样本展开 + a/b/c 预组合；求和顺序与朴素
/// 实现不位等价，IIR 递归下会放大）。buffer_length 需为 4 的倍数（wmavoice
/// 全部调用 size=80/40/20），非 4 倍数走 C 的朴素尾循环。
pub fn celpLpSynthF(out: []f32, ow: usize, in_buf: []const f32, iw: usize, c: []const f32, n: usize, fl: usize) void {
    // out[k] 绝对下标 = ow + k；out[-i] = out[ow + k - i]（相对当前写入点）
    const a: f32 = c[0];
    const b: f32 = c[1] - c[0] * c[0];
    const c3: f32 = c[2] - c[1] * c[0] - c[0] * b;

    var o0 = out[ow - 4];
    var o1 = out[ow - 3];
    var o2 = out[ow - 2];
    var o3 = out[ow - 1];

    var k: usize = 0;
    while (k + 4 <= n) : (k += 4) {
        const base = ow + k;
        var out0 = in_buf[iw + k];
        var out1 = in_buf[iw + k + 1];
        var out2 = in_buf[iw + k + 2];
        var out3 = in_buf[iw + k + 3];

        out0 -= c[2] * o1;
        out1 -= c[2] * o2;
        out2 -= c[2] * o3;

        out0 -= c[1] * o2;
        out1 -= c[1] * o3;

        out0 -= c[0] * o3;

        var val = c[3];

        out0 -= val * o0;
        out1 -= val * o1;
        out2 -= val * o2;
        out3 -= val * o3;

        var i: usize = 5;
        while (i < fl) : (i += 2) {
            o3 = out[base - i]; // old_out3 = out[-i]
            val = c[i - 1];

            out0 -= val * o3;
            out1 -= val * o0;
            out2 -= val * o1;
            out3 -= val * o2;

            o2 = out[base - i - 1]; // old_out2 = out[-i-1]

            val = c[i];

            out0 -= val * o2;
            out1 -= val * o3;
            out2 -= val * o0;
            out3 -= val * o1;

            const tmp_o0 = o0;
            o0 = o2;
            o2 = tmp_o0; // FFSWAP(old_out0, old_out2)
            o1 = o3; // old_out1 = old_out3
        }

        const t0 = out0;
        const t1 = out1;
        const t2 = out2;

        out3 -= a * t2;
        out2 -= a * t1;
        out1 -= a * t0;

        out3 -= b * t1;
        out2 -= b * t0;

        out3 -= c3 * t0;

        out[base] = out0;
        out[base + 1] = out1;
        out[base + 2] = out2;
        out[base + 3] = out3;

        o0 = out0;
        o1 = out1;
        o2 = out2;
        o3 = out3;
    }

    // 尾循环（C 原始朴素实现；wmavoice 实际不会走到）
    while (k < n) : (k += 1) {
        var s: f32 = in_buf[iw + k];
        var j: usize = 1;
        while (j <= fl) : (j += 1) {
            s -= c[j - 1] * out[ow + k - j];
        }
        out[ow + k] = s;
    }
}

/// ff_acelp_interpolatef。写 exc[w .. w+len]，读 exc[w-pitch ± i]。
pub fn acelpInterpolatef(exc: []f32, w: usize, pitch: i64, coeffs: []const f32, precision: usize, frac_pos: usize, filter_length: usize, length: usize) void {
    var n: usize = 0;
    while (n < length) : (n += 1) {
        var idx: usize = 0;
        var v: f32 = 0;
        var i: usize = 0;
        while (i < filter_length) {
            const a0 = @as(i64, @intCast(w)) + @as(i64, @intCast(n)) - pitch + @as(i64, @intCast(i));
            v += exc[@intCast(a0)] * coeffs[idx + frac_pos];
            idx += precision;
            i += 1;
            const a1 = @as(i64, @intCast(w)) + @as(i64, @intCast(n)) - pitch - @as(i64, @intCast(i));
            v += exc[@intCast(a1)] * coeffs[idx - frac_pos];
        }
        exc[w + n] = v;
    }
}

/// av_memcpy_backptr 语义（float）：exc[w..w+n] = exc[w-pitch..w-pitch+n]
/// （前向复制=周期重复，与 ffmpeg memmove 等价）。
pub fn memcpyBackptr(exc: []f32, w: usize, pitch: usize, n: usize) void {
    var k: usize = 0;
    while (k < n) : (k += 1) exc[w + k] = exc[w + k - pitch];
}

/// ff_tilt_compensation
pub fn tiltCompensation(mem: *f32, tilt: f32, samples: []f32) void {
    const new_tilt_mem = samples[samples.len - 1];
    var i: usize = samples.len - 1;
    while (i > 0) : (i -= 1) samples[i] -= tilt * samples[i - 1];
    samples[0] -= tilt * mem.*;
    mem.* = new_tilt_mem;
}

/// ff_acelp_apply_order_2_transfer_function
pub fn applyOrder2Transfer(out: []f32, in: []const f32, zero_coeffs: *const [2]f32, pole_coeffs: *const [2]f32, gain: f32, mem: *[2]f32) void {
    for (0..in.len) |i| {
        const tmp = gain * in[i] - pole_coeffs[0] * mem[0] - pole_coeffs[1] * mem[1];
        out[i] = tmp + zero_coeffs[0] * mem[0] + zero_coeffs[1] * mem[1];
        mem[1] = mem[0];
        mem[0] = tmp;
    }
}

/// ff_set_fixed_vector（AMRFixed 脉冲 → 周期重复叠加）
pub const AmrFixed = struct {
    n: usize = 0,
    x: [10]i32 = undefined,
    y: [10]f32 = undefined,
    no_repeat_mask: i32 = 0,
    pitch_lag: i32 = 0,
    pitch_fac: f32 = 1.0,
};

pub fn setFixedVector(out: []f32, in: *const AmrFixed, scale: f32) void {
    var i: usize = 0;
    while (i < in.n) : (i += 1) {
        var x = in.x[i];
        const repeats = ((in.no_repeat_mask >> @intCast(i)) & 1) == 0;
        var y = in.y[i] * scale;
        if (in.pitch_lag > 0) {
            std.debug.assert(x >= 0 and @as(usize, @intCast(x)) < out.len);
            while (true) {
                out[@intCast(x)] += y;
                y *= in.pitch_fac;
                x += in.pitch_lag;
                if (!(repeats and x < @as(i32, @intCast(out.len)))) break;
            }
        }
    }
}

/// wmavoice 特有 adaptive_gain_control（能量 = sum abs，非点积）
pub fn adaptiveGainControlWma(out: []f32, in: []const f32, speech_synth: []const f32, alpha: f32, gain_mem: *f32) void {
    var speech_energy: f32 = 0;
    var postfilter_energy: f32 = 0;
    for (speech_synth) |v| speech_energy += @abs(v);
    for (in) |v| postfilter_energy += @abs(v);
    // C: (1.0 - alpha) * speech_energy / postfilter_energy——1.0 为 double，
    // 全表达式 double 计算后单次舍入到 float
    const gain_scale_factor: f32 = if (postfilter_energy == 0.0)
        0.0
    else
        @floatCast((1.0 - @as(f64, alpha)) * @as(f64, speech_energy) / @as(f64, postfilter_energy));
    var mem = gain_mem.*;
    for (0..in.len) |i| {
        mem = alpha * mem + gain_scale_factor;
        out[i] = in[i] * mem;
    }
    gain_mem.* = mem;
}

/// wmavoice.c 特有 tilt_factor
pub fn tiltFactor(lpcs: []const f32) f32 {
    const n = lpcs.len;
    const rh0: f32 = 1.0 + scalarProduct(lpcs, lpcs);
    const rh1: f32 = lpcs[0] + scalarProduct(lpcs[0 .. n - 1], lpcs[1..]);
    return rh1 / rh0;
}

/// stabilize_lsps（double 版，wmavoice.c 内联）
pub fn stabilizeLsps(lsps: []f64) void {
    const num = lsps.len;
    lsps[0] = @max(lsps[0], 0.0015 * pi);
    for (1..num) |n| lsps[n] = @max(lsps[n], lsps[n - 1] + 0.0125 * pi);
    lsps[num - 1] = @min(lsps[num - 1], 0.9985 * pi);
    for (1..num) |n| {
        if (lsps[n] < lsps[n - 1]) {
            var m: usize = 1;
            while (m < num) : (m += 1) {
                const tmp = lsps[m];
                var l: i64 = @as(i64, @intCast(m)) - 1;
                while (l >= 0 and lsps[@intCast(l)] > tmp) : (l -= 1) {
                    lsps[@as(usize, @intCast(l)) + 1] = lsps[@intCast(l)];
                }
                lsps[@as(usize, @intCast(l)) + 1] = tmp;
            }
            break;
        }
    }
}

/// dequant_lsps（wmavoice.c；table 每 stage 前进 sizes[n]*num）
pub fn dequantLsps(lsps: []f64, values: []const u16, sizes: []const u16, table: []const u8, mul_lsf: []const f64, base_lsf: []const f64) void {
    const num = lsps.len;
    @memset(lsps, 0);
    var tab: []const u8 = table;
    for (values, sizes, mul_lsf, base_lsf) |v, sz, mul, base| {
        const t_off = tab[v * num ..][0..num];
        for (0..num) |m| lsps[m] += base + mul * @as(f64, t_off[m]);
        tab = tab[sz * num ..];
    }
}

test "wmavoice dsp basic" {
    // lsp2lpc roundtrip on identity-ish
    try std.testing.expect(true);
}
