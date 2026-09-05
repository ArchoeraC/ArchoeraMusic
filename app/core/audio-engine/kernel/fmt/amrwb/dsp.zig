//! AMR-WB 解码 DSP（浮点路径复刻 FFmpeg ACELP 族工具函数）
//!
//! 对照 FFmpeg libavcodec（LGPL-2.1+）：acelp_filters.c（acelp_interpolatef /
//! acelp_apply_order_2_transfer_function）、celp_filters.c（lp 合成滤波，
//! 含 4 路展开路径）、acelp_vectors.c（weighted sum / scale sum-of-squares /
//! circ_addf）、celp_math.c（float dot product）、libavutil/ffmath.h（ff_exp10）、
//! libavutil/lfg.c（Lagged Fibonacci PRNG）。运算顺序与类型逐句对齐，
//! 全部标量浮点（f32/f64 同 C），不触发任何融合乘加。
//!
//! 参考重构：FFmpeg 目标为准；数值表见 tables.zig。

const std = @import("std");
const T = @import("tables.zig");

pub const LP_ORDER = T.LP_ORDER;
pub const AMRWB_SFR_SIZE = T.AMRWB_SFR_SIZE;

// glibc libm（ffmpeg C 用 glibc cos/exp2/log10f；Zig @cos/@exp2/@log10 走
// compiler-rt，个别参数末位舍入与 glibc 不同 → 为逐位对齐 ffmpeg 直连 libm。
// 直接 extern 会被 Zig 链接的 compiler-rt 同名符号截获，故 Linux 下经
// dlopen/dlsym 取 glibc libm 实现；其他平台回退 extern（系统 libm）。
const builtin = @import("builtin");

const MathLib = struct {
    cos: *const fn (f64) callconv(.c) f64,
    exp2: *const fn (f64) callconv(.c) f64,
    log10f: *const fn (f32) callconv(.c) f32,
};
var math_lib: ?MathLib = null;
var math_resolved: bool = false;

fn mathLib() MathLib {
    if (math_resolved) return math_lib.?;
    math_resolved = true;
    var lib = MathLib{
        .cos = @extern(*const fn (f64) callconv(.c) f64, .{ .name = "cos" }),
        .exp2 = @extern(*const fn (f64) callconv(.c) f64, .{ .name = "exp2" }),
        .log10f = @extern(*const fn (f32) callconv(.c) f32, .{ .name = "log10f" }),
    };
    if (builtin.os.tag == .linux) {
        if (std.c.dlopen("libm.so.6", .{ .NOW = true })) |h| {
            if (std.c.dlsym(h, "cos")) |p| lib.cos = @ptrCast(@alignCast(p));
            if (std.c.dlsym(h, "exp2")) |p| lib.exp2 = @ptrCast(@alignCast(p));
            if (std.c.dlsym(h, "log10f")) |p| lib.log10f = @ptrCast(@alignCast(p));
        }
    }
    math_lib = lib;
    return lib;
}

/// 与 ff_scalarproduct_float_c 相同：严格从左到右累加（f32 累积）。
pub fn dotProductf(a: []const f32, b: []const f32, n: usize) f32 {
    var sum: f32 = 0.0;
    for (0..n) |i| sum += a[i] * b[i];
    return sum;
}

/// ff_weighted_vector_sumf：out[i] = wa*in_a[i] + wb*in_b[i]
pub fn weightedVectorSumf(out: []f32, in_a: []const f32, in_b: []const f32, wa: f32, wb: f32, n: usize) void {
    for (0..n) |i| out[i] = wa * in_a[i] + wb * in_b[i];
}

/// ff_scale_vector_to_given_sum_of_squares（sum_of_squares 目标能量，等长输入输出）
pub fn scaleVectorToGivenSumOfSquares(out: []f32, in: []const f32, sum_of_squares: f32, n: usize) void {
    var scalefactor: f32 = dotProductf(in[0..n], in[0..n], n);
    if (scalefactor != 0.0) scalefactor = @sqrt(sum_of_squares / scalefactor);
    for (0..n) |i| out[i] = in[i] * scalefactor;
}

/// ff_celp_circ_addf：out[k] = in[k] + fac * lagged[k-lag]（循环回绕）
pub fn circAddf(out: []f32, in: []const f32, lagged: []const f32, lag: usize, fac: f32, n: usize) void {
    var k: usize = 0;
    while (k < lag) : (k += 1) out[k] = in[k] + fac * lagged[n + k - lag];
    while (k < n) : (k += 1) out[k] = in[k] + fac * lagged[k - lag];
}

/// ff_acelp_interpolatef：分数位置激励内插。
/// `in` 为输入数据起始（含历史），`in_base` 为 C 语义的 in[0] 下标。
/// 读到 in[n+i]（前向）与 in[n-i]（后向历史）。
pub fn acelpInterpolatef(out: []f32, in: []const f32, in_base: isize, filter_coeffs: []const f32, precision: usize, frac_pos: usize, filter_length: usize, length: usize) void {
    for (0..length) |nn| {
        var idx: usize = 0;
        var v: f32 = 0.0;
        var i: usize = 0;
        while (i < filter_length) {
            v += in[@intCast(in_base + @as(isize, @intCast(nn)) + @as(isize, @intCast(i)))] * filter_coeffs[idx + frac_pos];
            idx += precision;
            i += 1;
            v += in[@intCast(in_base + @as(isize, @intCast(nn)) - @as(isize, @intCast(i)))] * filter_coeffs[idx - frac_pos];
        }
        out[nn] = v;
    }
}

/// ff_acelp_apply_order_2_transfer_function
pub fn applyOrder2TransferFunction(out: []f32, in: []const f32, zero_coeffs: []const f32, pole_coeffs: []const f32, gain: f32, mem: *[2]f32, n: usize) void {
    for (0..n) |i| {
        const tmp: f32 = gain * in[i] - pole_coeffs[0] * mem[0] - pole_coeffs[1] * mem[1];
        out[i] = tmp + zero_coeffs[0] * mem[0] + zero_coeffs[1] * mem[1];
        mem[1] = mem[0];
        mem[0] = tmp;
    }
}

/// ff_exp10（double）= exp2(M_LOG2_10 * x)，与 libavutil/ffmath.h 一致。
pub fn ffExp10(x: f64) f64 {
    return mathLib().exp2(3.32192809488736234787 * x);
}

fn ffExp10f(x: f32) f32 {
    return @floatCast(mathLib().exp2(3.32192809488736234787 * @as(f64, x)));
}

/// ff_amr_set_fixed_gain（acelp_pitch_delay.c；prediction_error 就地更新）
pub fn amrSetFixedGain(fixed_gain_factor: f32, fixed_mean_energy: f32, prediction_error: *[4]f32, energy_mean: f32, pred_table: []const f32) f32 {
    const arg: f64 = 0.05 * (@as(f64, @floatCast(dotProductf(pred_table, prediction_error, 4) + energy_mean)));
    const denom: f32 = @sqrt(if (fixed_mean_energy != 0.0) fixed_mean_energy else 1.0);
    const val: f32 = @floatCast((@as(f64, fixed_gain_factor) * ffExp10(arg)) / @as(f64, denom));
    std.mem.copyForwards(f32, prediction_error[0..3], prediction_error[1..4]);
    const l10: f32 = mathLib().log10f(fixed_gain_factor);
    prediction_error[3] = @floatCast(20.0 * @as(f64, l10)); // log10f
    return val;
}

/// ff_celp_lp_synthesis_filterf（celp_filters.c 4 路展开路径）。
/// `buf[0..order]` 为滤波器历史；输出写入 `buf[order..order+len]`（调用方保证）。
/// `in` 为激励信号。
pub fn lpSynthesisFilterf(buf: []f32, in: []const f32, coeffs: []const f32, order: usize, len: usize) void {
    const a: f32 = coeffs[0];
    var b: f32 = coeffs[1];
    var c: f32 = coeffs[2];
    b -= coeffs[0] * coeffs[0];
    c -= coeffs[1] * coeffs[0];
    c -= coeffs[0] * b;

    const off = order;
    var old_out0: f32 = buf[off - 4];
    var old_out1: f32 = buf[off - 3];
    var old_out2: f32 = buf[off - 2];
    var old_out3: f32 = buf[off - 1];

    var n: usize = 0;
    while (n <= len - 4) : (n += 4) {
        var tmp0: f32 = undefined;
        var tmp1: f32 = undefined;
        var tmp2: f32 = undefined;

        var out0: f32 = in[n];
        var out1: f32 = in[n + 1];
        var out2: f32 = in[n + 2];
        var out3: f32 = in[n + 3];

        out0 -= coeffs[2] * old_out1;
        out1 -= coeffs[2] * old_out2;
        out2 -= coeffs[2] * old_out3;

        out0 -= coeffs[1] * old_out2;
        out1 -= coeffs[1] * old_out3;

        out0 -= coeffs[0] * old_out3;

        const val0: f32 = coeffs[3];

        out0 -= val0 * old_out0;
        out1 -= val0 * old_out1;
        out2 -= val0 * old_out2;
        out3 -= val0 * old_out3;

        var i: usize = 5;
        while (i < order) : (i += 2) {
            old_out3 = buf[off + n - i];
            var val: f32 = coeffs[i - 1];

            out0 -= val * old_out3;
            out1 -= val * old_out0;
            out2 -= val * old_out1;
            out3 -= val * old_out2;

            old_out2 = buf[off + n - i - 1];

            val = coeffs[i];

            out0 -= val * old_out2;
            out1 -= val * old_out3;
            out2 -= val * old_out0;
            out3 -= val * old_out1;

            const sw = old_out0;
            old_out0 = old_out2;
            old_out2 = sw;
            old_out1 = old_out3;
        }

        tmp0 = out0;
        tmp1 = out1;
        tmp2 = out2;

        out3 -= a * tmp2;
        out2 -= a * tmp1;
        out1 -= a * tmp0;

        out3 -= b * tmp1;
        out2 -= b * tmp0;

        out3 -= c * tmp0;

        buf[off + n] = out0;
        buf[off + n + 1] = out1;
        buf[off + n + 2] = out2;
        buf[off + n + 3] = out3;

        old_out0 = out0;
        old_out1 = out1;
        old_out2 = out2;
        old_out3 = out3;
    }
    // 尾部（len 非 4 的倍数）标量路径；本例 len=64/80 恒为 4 的倍数，保留兼容。
    while (n < len) : (n += 1) {
        buf[off + n] = in[n];
        var i: usize = 1;
        while (i <= order) : (i += 1)
            buf[off + n] -= coeffs[i - 1] * buf[off + n - i];
    }
}

// ---------------------------------------------------------------------------
// Lagged Fibonacci PRNG（libavutil/lfg.c）——scaled_hb_excitation 白噪声
// ---------------------------------------------------------------------------

pub const Lfg = struct {
    state: [64]u32 = [_]u32{0} ** 64,
    index: u32 = 0,

    /// av_lfg_init(c, 1)：MD5(seed_LE32 ++ [i] ++ 上一轮摘要[5..16]) → state[i..i+4]
    /// （C 的 av_md5_sum 就地写回 tmp，故输入跨轮次“链式”依赖上一轮摘要，需逐轮复刻）
    pub fn initSeed(seed: u32) Lfg {
        var c = Lfg{};
        var tmp: [16]u8 = [_]u8{0} ** 16;
        var i: usize = 8;
        while (i < 64) : (i += 4) {
            std.mem.writeInt(u32, tmp[0..4], seed, .little);
            tmp[4] = @intCast(i);
            var digest: [16]u8 = undefined;
            std.crypto.hash.Md5.hash(&tmp, &digest, .{});
            tmp = digest;
            c.state[i] = std.mem.readInt(u32, tmp[0..4], .little);
            c.state[i + 1] = std.mem.readInt(u32, tmp[4..8], .little);
            c.state[i + 2] = std.mem.readInt(u32, tmp[8..12], .little);
            c.state[i + 3] = std.mem.readInt(u32, tmp[12..16], .little);
        }
        c.index = 0;
        return c;
    }

    /// av_lfg_get：state[idx] = state[idx+40 &63] + state[idx+9 &63]（对应 -24/-55 tap）
    pub fn get(c: *Lfg) u32 {
        const idx: usize = @intCast(c.index & 63);
        const tap24: usize = (idx + 40) & 63;
        const tap55: usize = (idx + 9) & 63;
        const a = c.state[tap24] +% c.state[tap55];
        c.state[idx] = a;
        c.index +%= 1;
        return a;
    }
};

// ---------------------------------------------------------------------------
// LSP/LSF（lsp.c：lsf2lspd / amrwb_lsp2lpc / set_min_dist_lsf）
// ---------------------------------------------------------------------------

pub const LSP_LEN_MAX = 20;

/// ff_set_min_dist_lsf
pub fn setMinDistLsf(lsf: []f32, min_spacing: f64, size: usize) void {
    var prev: f32 = 0.0;
    for (0..size) |i| {
        const lim: f64 = @as(f64, prev) + min_spacing;
        const v: f32 = if (@as(f64, lsf[i]) > lim) lsf[i] else @floatCast(lim);
        lsf[i] = v;
        prev = v;
    }
}

/// ff_acelp_lsf2lspd：lsp[i] = cos(2π lsf[i])（double；lsf float 提升）
pub fn lsf2lspd(lsp: []f64, lsf: []const f32, order: usize) void {
    for (0..order) |i| lsp[i] = mathLib().cos(2.0 * std.math.pi * @as(f64, lsf[i]));
}

/// lsp2polyf：多项式递推（f 为输出数组，长度 half+1；lsp 为 LSP cos 数组，
/// 访问 lsp[off + 2k] 固定步长子序列，起点 off（off=0 偶下标、off=1 奇下标））
fn lsp2polyf(f: []f64, lsp: []const f64, off: usize, half: usize) void {
    f[0] = 1.0;
    f[1] = -2.0 * lsp[off];
    for (2..half + 1) |i| {
        const val = -2.0 * lsp[off + 2 * (i - 1)];
        f[i] = val * f[i - 1] + 2.0 * f[i - 2];
        var j = i - 1;
        while (j > 1) : (j -= 1) f[j] += f[j - 1] * val + f[j - 2];
        f[1] += val;
    }
}

/// ff_amrwb_lsp2lpc：LSP（cosine）→ LP 系数（float 输出，LP_ORDER=16/20）
pub fn amrwbLsp2lpc(lsp: []const f64, lp: []f32, lp_order: usize) void {
    const half = lp_order >> 1;
    var pa: [LSP_LEN_MAX + 1]f64 = undefined;
    var buf: [LSP_LEN_MAX + 1]f64 = undefined; // qa = buf+1（buf[0] = qa[-1] = 0）

    lsp2polyf(pa[0..], lsp, 0, half); // pa[0..half]
    buf[0] = 0.0;
    lsp2polyf(buf[1 .. half + 1], lsp, 1, half - 1); // qa[0..half-1] = buf[1..half]

    var i: usize = 1;
    var j: usize = lp_order - 1;
    while (i < half) : ({
        i += 1;
        j -= 1;
    }) {
        const paf = pa[i] * (1.0 + lsp[lp_order - 1]);
        const qaf = (buf[i + 1] - buf[i - 1]) * (1.0 - lsp[lp_order - 1]);
        lp[i - 1] = @floatCast((paf + qaf) * 0.5);
        lp[j - 1] = @floatCast((paf - qaf) * 0.5);
    }
    lp[half - 1] = @floatCast((1.0 + lsp[lp_order - 1]) * pa[half] * 0.5);
    lp[lp_order - 1] = @floatCast(lsp[lp_order - 1]);
}

/// hb FIR（hb_fir_filter，amrwbdec.c）：15 阶 + 中心 = HB_FIR_SIZE+1 抽头
pub fn hbFirFilter(out: []f32, fir_coef: []const f32, mem: []f32, in: []const f32, in_len: usize) void {
    // data = mem (HB_FIR_SIZE) + in (in_len)
    var data: [T.HB_FIR_SIZE + 128]f32 = undefined;
    @memcpy(data[0..T.HB_FIR_SIZE], mem);
    @memcpy(data[T.HB_FIR_SIZE .. T.HB_FIR_SIZE + in_len], in[0..in_len]);
    const taps = T.HB_FIR_SIZE + 1;
    for (0..in_len) |i| {
        var acc: f32 = 0.0;
        for (0..taps) |j| acc += data[i + j] * fir_coef[j];
        out[i] = acc;
    }
    @memcpy(mem, data[in_len .. in_len + T.HB_FIR_SIZE]);
}

test "amr_set_fixed_gain 形状" {
    var pe: [4]f32 = .{ -14.0, -14.0, -14.0, -14.0 };
    const pred = [4]f32{ 0.2, 0.3, 0.4, 0.5 };
    const g = amrSetFixedGain(1.0, 0.0, &pe, 30.0, &pred);
    try std.testing.expect(g > 0);
    try std.testing.expect(std.math.isFinite(g));
}

test "Lfg: 确定性初值" {
    var a = Lfg.initSeed(1);
    var b = Lfg.initSeed(1);
    for (0..100) |_| try std.testing.expectEqual(a.get(), b.get());
}

test "lsp 往返：单位激励合成不致发散" {
    // 平凡用例：全 0.25 附近 ISF → LPC 有界
    var isf: [16]f32 = undefined;
    for (0..16) |i| isf[i] = @floatCast(0.02 + @as(f32, @floatFromInt(i)) * 0.03);
    var lsf: [16]f64 = undefined;
    lsf2lspd(&lsf, &isf, 16);
    var lp: [16]f32 = undefined;
    amrwbLsp2lpc(&lsf, &lp, 16);
    for (lp) |v| try std.testing.expect(std.math.isFinite(v));
}
