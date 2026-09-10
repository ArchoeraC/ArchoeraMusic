// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! CELT PVQ 解码（docs/audio-kernel-zig.md §9.2，P2）
//!
//! 参考重构对照 FFmpeg `libavcodec/opus/pvq.c`（pvq_decode_band 全路径 +
//! celt_cwrsi / celt_alg_unquant / celt_exp_rotation / celt_haar1 /
//! celt_stereo_merge / 数学原语）（许可登记见 audio-engine/THIRD-PARTY-LICENSES.md）。
//!
//! 语义要点（保证 bit-exact）：
//!   - U(N,K) 组合数表（`ff_celt_pvq_u_row`，满足
//!     U(n,k)=U(n,k-1)+U(n-1,k-1)+U(n-1,k)），V(N,K)=U(N,K)+U(N,K+1)；
//!   - `celt_cwrsi`：PVQ 索引 → 脉冲向量（带符号），u64 norm → f32 舍入；
//!   - `celt_exp_rotation`：theta 用 double（M_PI），cosf/sinf；
//!   - `celt_haar1`：M_SQRT1_2 用 double 乘后再舍入 f32；
//!   - collapse mask 位运算与 `remaining2` 8ths 位预算精确一致。

const std = @import("std");
const rcmod = @import("rc.zig");
const tables = @import("celt_tables.zig");
const celt_types = @import("celt_types.zig");

const CeltFrame = celt_types.CeltFrame;

const Rc = rcmod.Rc;
const CELT_MAX_BANDS = 21;
const CELT_MAX_FRAME_SIZE = 960;
const CELT_NORM_SCALE = 16384;
const CELT_QTHETA_OFFSET = 4;
const CELT_QTHETA_OFFSET_TWOPHASE = 16;
const M_SQRT1_2: f64 = 0.707106781186547524401;
const CELT_PVQ_U_MAX = 22;

/// U(N,K)（表访问；N,K ≤ 14 内有效，行按 K 直接索引，K ≥ N）
inline fn u(n: usize, k: usize) u32 {
    const min_nk = @min(n, k);
    const max_nk = @max(n, k);
    return tables.celt_pvq_u[tables.ff_celt_pvq_u_row_offsets[min_nk] + max_nk];
}

/// V(N,K) = U(N,K) + U(N,K+1)
inline fn v(n: usize, k: usize) u32 {
    return u(n, k) + u(n, k + 1);
}

/// celt_cos：Q15 定点余弦（输入 0..16384）
fn celtCos(x: i32) i32 {
    var xx = @divTrunc(x * x + 4096, 8192); // (x²+4096)>>13
    xx = (32767 - xx) + roundMul16(xx, -7651 + roundMul16(xx, 8277 + roundMul16(-626, xx)));
    return xx + 1;
}

inline fn roundMul16(a: i32, b: i32) i32 {
    // C 语义：(a*b + 16384) >> 15 为算术右移（负数向 -inf，即 floor）
    return @as(i32, a * b + 16384) >> 15;
}

/// celt_log2tan：Q11 log2(isin/icos)
fn celtLog2tan(isin: i32, icos: i32) i32 {
    const lc = opusIlog(@as(u32, @intCast(icos)));
    const ls = opusIlog(@as(u32, @intCast(isin)));
    const ic = icos << @intCast(15 - lc);
    const is = isin << @intCast(15 - ls);
    return (ls << 11) - (lc << 11) +
        roundMul16(is, roundMul16(is, -2597) + 7932) -
        roundMul16(ic, roundMul16(ic, -2597) + 7932);
}

inline fn opusIlog(i: u32) i32 {
    if (i == 0) return 0;
    return @intCast(32 - @clz(i));
}

/// celt_compute_qn：PVQ 量化级数
fn computeQn(n: i32, b: i32, offset: i32, pulse_cap: i32, stereo: bool) i32 {
    const n2 = 2 * n - 1 - @intFromBool(stereo and n == 2);
    const qb: i32 = @min(@min(b - pulse_cap - (4 << 3), @divTrunc(b + n2 * offset, n2)), 8 << 3);
    if (qb < (1 << 3 >> 1)) return 1;
    const exp2 = tables.ff_celt_qn_exp2[@intCast(qb & 0x7)];
    const qn = @divTrunc(exp2, @as(u16, 1) << @intCast(14 - (qb >> 3)));
    return @divTrunc(qn + 1, 2) * 2;
}

/// celt_bits2pulses：缓存二分查脉冲数
fn bits2pulses(cache: []const u8, bits_in: i32) i32 {
    var low: i32 = 0;
    var high: i32 = @intCast(cache[0]);
    const bits = bits_in - 1;
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        const center = @divTrunc(low + high + 1, 2);
        if (cache[@intCast(center)] >= bits) {
            high = center;
        } else {
            low = center;
        }
    }
    const c0: i32 = if (low == 0) -1 else cache[@intCast(low)];
    const c1: i32 = cache[@intCast(high)];
    return if (bits - c0 <= c1 - bits) low else high;
}

/// celt_pulses2bits
inline fn pulses2bits(cache: []const u8, pulses: i32) i32 {
    if (pulses == 0) return 0;
    return @as(i32, cache[@intCast(pulses)]) + 1;
}

/// celt_cwrsi：PVQ 索引 → 脉冲向量 y[N]，返回 f32 norm
/// libopus float：yy=MAC16_16(yy,val,val)=yy+val·val（f32 顺序累加，非精确整数和）
fn cwrsi(n_in: u32, k_in: u32, i_in: u32, y: []i32) f32 {
    var N = n_in;
    var K = k_in;
    var i = i_in;
    var norm: f32 = 0.0;
    var idx: usize = 0;

    while (N > 2) {
        var s: u32 = 0;
        var val: i32 = 0;
        if (K >= N) {
            // Lots of pulses case
            const p: u32 = u(N, K + 1);
            s = if (i >= p) 0xFFFFFFFF else 0;
            i -%= p & s;
            const k0 = K;
            const q = u(N, N);
            if (q > i) {
                // do { p = u_row[--K][N]; } while (p > i)：先减后判
                K = N;
                K -%= 1;
                while (u(K, N) > i) K -%= 1;
            } else {
                while (u(K, N) > i) K -%= 1;
            }
            const p2: u32 = u(K, N);
            i -%= p2;
            val = @bitCast((k0 -% K +% s) ^ s);
            norm += @as(f32, @floatFromInt(val)) * @as(f32, @floatFromInt(val));
            y[idx] = val;
            idx += 1;
        } else {
            // Lots of dimensions case
            const p: u32 = u(K, N);
            const q: u32 = u(K + 1, N);
            if (p <= i and i < q) {
                i -= p;
                y[idx] = 0;
                idx += 1;
            } else {
                s = if (i >= q) 0xFFFFFFFF else 0;
                i -%= q & s;
                const k0 = K;
                K -%= 1;
                while (u(K, N) > i) K -%= 1;
                const p2: u32 = u(K, N);
                i -%= p2;
                val = @bitCast((k0 -% K +% s) ^ s);
                norm += @as(f32, @floatFromInt(val)) * @as(f32, @floatFromInt(val));
                y[idx] = val;
                idx += 1;
            }
        }
        N -= 1;
    }

    // N == 2
    {
        const p: u32 = 2 * K + 1;
        const s2: u32 = if (i >= p) 0xFFFFFFFF else 0;
        i -%= p & s2;
        const k0 = K;
        K = @divTrunc(i + 1, 2);
        if (K != 0) i -%= 2 * K - 1;
        const val: i32 = @bitCast((k0 -% K +% s2) ^ s2);
        norm += @as(f32, @floatFromInt(val)) * @as(f32, @floatFromInt(val));
        y[idx] = val;
        idx += 1;
    }
    // N == 1
    {
        const s = 0 -% i;
        const val: i32 = @bitCast((K +% s) ^ s);
        norm += @as(f32, @floatFromInt(val)) * @as(f32, @floatFromInt(val));
        y[idx] = val;
    }
    return norm;
}

/// celt_haar1
fn haar1(x: []f32, n0: usize, stride: usize) void {
    const n0h = n0 >> 1;
    // libopus：tmp1 = QCONST32(.70710678f,31)*X[a]; tmp2 = 同*X[b];
    // X[a]=tmp1+tmp2; X[b]=tmp1-tmp2（f32 乘后加减，非先和后乘）
    const s: f32 = 0.70710678;
    for (0..n0h) |i| {
        for (0..stride) |j| {
            const tmp1 = s * x[stride * (2 * i) + j];
            const tmp2 = s * x[stride * (2 * i + 1) + j];
            x[stride * (2 * i) + j] = tmp1 + tmp2;
            x[stride * (2 * i + 1) + j] = tmp1 - tmp2;
        }
    }
}

/// celt_exp_rotation_impl
fn expRotationImpl(x: []f32, len: usize, stride: usize, c: f32, s: f32) void {
    var xptr: usize = 0;
    var i: usize = 0;
    while (i + 1 < len - stride + 1) : (i += 1) {
        const x1 = x[xptr];
        const x2 = x[xptr + stride];
        x[xptr + stride] = c * x2 + s * x1;
        x[xptr] = c * x1 - s * x2;
        xptr += 1;
    }
    // 参考语义：Xptr = &X[len-2*stride-1]；len < 2*stride+1 时该循环为空
    // （C 仅计算指针，循环不执行），此处用 i64 避免 usize 下溢
    var back: i64 = @as(i64, @intCast(len)) - 2 * @as(i64, @intCast(stride)) - 1;
    while (back >= 0) : (back -= 1) {
        const b: usize = @intCast(back);
        const x1 = x[b];
        const x2 = x[b + stride];
        x[b + stride] = c * x2 + s * x1;
        x[b] = c * x1 - s * x2;
    }
}

/// celt_exp_rotation（解码路径）
fn expRotation(x: []f32, len: usize, stride: usize, k: u32, spread: u8) void {
    if (2 * k >= len or spread == 0) return;
    const denom: i32 = @as(i32, @intCast(len)) + (20 - 5 * @as(i32, @intCast(spread))) * @as(i32, @intCast(k));
    // libopus float：
    //   gain = (opus_val32)(Q15_ONE*len) / (opus_val32)(len+factor*K)  → f32 除法
    //   theta = HALF16(MULT16_16_Q15(gain,gain)) = 0.5f*(gain*gain)    → f32
    //   c = celt_cos_norm(theta) = (float)cos((0.5f*PI)*theta)         → double cos
    //   s = celt_cos_norm(Q15ONE-theta) = (float)cos((0.5f*PI)*(1.0f-theta))
    const gain: f32 = @as(f32, @floatFromInt(len)) / @as(f32, @floatFromInt(denom));
    const theta: f32 = 0.5 * gain * gain;
    const pi_half: f64 = 1.57079632679489661923;
    const c: f32 = @floatCast(@cos(pi_half * @as(f64, theta)));
    const s: f32 = @floatCast(@cos(pi_half * @as(f64, 1.0 - theta)));
    var stride2: usize = 0;
    if (len >= stride << 3) {
        while ((stride2 * stride2 + stride2) * stride + (stride >> 2) < len) stride2 += 1;
    }
    const l = len / stride;
    var i: usize = 0;
    while (i < stride) : (i += 1) {
        if (stride2 != 0) expRotationImpl(x[i * l ..][0..l], l, stride2, s, c);
        expRotationImpl(x[i * l ..][0..l], l, 1, c, s);
    }
}

/// celt_interleave_hadamard
fn interleaveHadamard(tmp: []f32, x: []f32, n0: usize, stride: usize, hadamard: bool) void {
    const order = if (hadamard) tables.ff_celt_hadamard_order[stride - 2 ..] else tables.ff_celt_hadamard_order[30 .. 30 + stride];
    for (0..stride) |i| {
        for (0..n0) |j| tmp[order[i] * n0 + j] = x[j * stride + i];
    }
    @memcpy(x[0 .. n0 * stride], tmp[0 .. n0 * stride]);
}

/// celt_deinterleave_hadamard
fn deinterleaveHadamard(tmp: []f32, x: []f32, n0: usize, stride: usize, hadamard: bool) void {
    const order = if (hadamard) tables.ff_celt_hadamard_order[stride - 2 ..] else tables.ff_celt_hadamard_order[30 .. 30 + stride];
    for (0..stride) |i| {
        for (0..n0) |j| tmp[j * stride + i] = x[order[i] * n0 + j];
    }
    @memcpy(x[0 .. n0 * stride], tmp[0 .. n0 * stride]);
}

/// celt_stereo_merge
fn stereoMerge(x: []f32, y: []f32, mid_in: f32, n: usize) void {
    var xp: f32 = 0;
    var side: f32 = 0;
    for (0..n) |i| {
        xp += x[i] * y[i];
        side += y[i] * y[i];
    }
    const mid = mid_in;
    xp *= mid;
    const e0 = mid * mid + side - 2 * xp;
    const e1 = mid * mid + side + 2 * xp;
    if (e0 < 6e-4 or e1 < 6e-4) {
        @memcpy(y[0..n], x[0..n]);
        return;
    }
    const g0: f32 = 1.0 / @sqrt(e0);
    const g1: f32 = 1.0 / @sqrt(e1);
    for (0..n) |i| {
        const v0 = mid * x[i];
        const v1 = y[i];
        x[i] = g0 * (v0 - v1);
        y[i] = g1 * (v0 + v1);
    }
}

/// celt_extract_collapse_mask
fn extractCollapseMask(y: []const i32, n: usize, b: usize) u32 {
    var collapse_mask: u32 = 0;
    if (b <= 1) return 1;
    const n0 = n / b;
    for (0..b) |i| {
        for (0..n0) |j| {
            collapse_mask |= @as(u32, @intFromBool(y[i * n0 + j] != 0)) << @as(u5, @intCast(i));
        }
    }
    return collapse_mask;
}

/// celt_decode_pulses：均匀区间解码 PVQ 索引 → 脉冲向量（norm 为 f32 顺序累加）
fn decodePulses(rc: *Rc, y: []i32, n: u32, k: u32) f32 {
    const idx = rc.decUint(v(n, k));
    return cwrsi(n, k, idx, y);
}

/// celt_alg_unquant
fn algUnquant(rc: *Rc, x: []f32, n: usize, k: u32, spread: u8, blocks: u32, gain: f32, pvq_scratch: *[256]i32) u32 {
    const norm = decodePulses(rc, pvq_scratch[0..n], @intCast(n), k);
    // libopus：g = MULT32_32_Q31(celt_rsqrt_norm32(Ryy), gain) = (1/sqrt(Ryy))*gain
    const g = (1.0 / @sqrt(norm)) * gain;
    for (0..n) |i| x[i] = g * @as(f32, @floatFromInt(pvq_scratch[i]));
    expRotation(x, n, blocks, k, spread);
    return extractCollapseMask(pvq_scratch[0..n], n, @intCast(blocks));
}

/// 归一化（celt_renormalize_vector）
fn renormalizeVector(x: []f32, gain: f32) void {
    var s: f32 = 0;
    for (x) |vv| s += vv * vv;
    const e = 1e-15 + s;
    const g = (1.0 / @sqrt(e)) * gain;
    for (x) |*vv| vv.* = g * vv.*;
}

pub const Pvq = struct {
    qcoeff: [256]i32 = undefined,
    hadamard_tmp: [256]f32 = undefined,
    lowband_scratch: [8 * 22]f32 = undefined,
    norm: [2 * 8 * 100]f32 = undefined,
};

/// 主 quant_band（解码路径，quant=0）。返回 collapse mask。
pub fn quantBand(
    pvq: *Pvq,
    f: *CeltFrame,
    rc: *Rc,
    band: usize,
    x_in: []f32,
    y_in: ?[]f32,
    n_in: usize,
    b_in: i32,
    blocks_in: u32,
    lowband_in: ?[]const f32,
    duration_in: i32,
    lowband_out: ?[]f32,
    level_in: i32,
    gain_in: f32,
    fill_in: u32,
) u32 {
    var n = n_in;
    var b = b_in;
    var x = x_in;
    var y = y_in orelse x_in[n..][0..0]; // mono：无 Y
    const stereo = y_in != null;
    var blocks = blocks_in;
    var duration = duration_in;
    const level = level_in;
    const gain = gain_in;
    var fill = fill_in;
    var lowband = lowband_in;

    var imid: i32 = 0;
    var iside: i32 = 0;
    var mid: f32 = 0;
    var side: f32 = 0;
    const n0 = n;
    var n_b = n / blocks;
    var n_b0 = n_b;
    var b0 = blocks;
    var time_divide: usize = 0;
    var recombine: usize = 0;
    var inv: bool = false;
    const longblocks = b0 == 1;
    var cm: u32 = 0;

    if (n == 1) {
        var xp = x;
        for (0..@as(usize, 1) + @intFromBool(stereo)) |_| {
            var sign: i32 = 0;
            if (f.remaining2 >= 1 << 3) {
                sign = @intCast(rc.getRaw(1));
                f.remaining2 -= 1 << 3;
            }
            xp[0] = 1.0 - 2.0 * @as(f32, @floatFromInt(sign));
            if (stereo) xp = y;
        }
        if (lowband_out) |lo| lo[0] = x[0];
        return 1;
    }

    // 时/频域变换（mono 且 level==0）
    if (!stereo and level == 0) {
        const tf_change = f.tf_change[band];
        if (tf_change > 0) recombine = @intCast(tf_change);
        if (lowband != null and (recombine != 0 or ((n_b & 1) == 0 and tf_change < 0) or b0 > 1)) {
            for (0..n) |i| pvq.lowband_scratch[i] = lowband.?[i];
            lowband = pvq.lowband_scratch[0..n];
        }
        var k: usize = 0;
        while (k < recombine) : (k += 1) {
            if (lowband) |lb| haar1(@constCast(lb), n >> @as(u6, @intCast(k)), @as(usize, 1) << @as(u6, @intCast(k)));
            fill = @as(u32, tables.ff_celt_bit_interleave[fill & 0xF]) |
                (@as(u32, tables.ff_celt_bit_interleave[fill >> 4]) << 2);
        }
        blocks >>= @intCast(recombine);
        n_b <<= @intCast(recombine);

        var tf = tf_change;
        while ((n_b & 1) == 0 and tf < 0) {
            if (lowband) |lb| haar1(@constCast(lb), n_b, blocks);
            fill |= fill << @as(u5, @intCast(blocks));
            blocks <<= 1;
            n_b >>= 1;
            time_divide += 1;
            tf += 1;
        }
        b0 = blocks;
        n_b0 = n_b;
        if (b0 > 1) {
            interleaveHadamard(pvq.hadamard_tmp[0..256], x, n_b >> @intCast(recombine), b0 << @intCast(recombine), longblocks);
            if (lowband) |lb| interleaveHadamard(pvq.hadamard_tmp[0..256], @constCast(lb), n_b >> @intCast(recombine), b0 << @intCast(recombine), longblocks);
        }
    }

    // 拆分决策（mono）
    // 参考语义：cache 无条件指向表（duration ≥ 0 时 index 恒有效；
    // duration=-1 且 band<8 时 index=-1，参考实现读取表前字节，此处空切片兜底
    // 且拆分条件不满足，与参考行为一致）
    // 参考语义：cache 无条件指向表（duration ∈ -1..3 时 (duration+1)*21+band ≤ 104
    // 恒在表内；值为 -1 时参考实现读取表前字节，此处空切片兜底且拆分条件不满足）
    var cache: []const u8 = &.{};
    const cache_idx = tables.ff_celt_cache_index[@as(usize, @intCast(duration + 1)) * CELT_MAX_BANDS + band];
    if (cache_idx >= 0) cache = tables.ff_celt_cache_bits[@intCast(cache_idx)..];
    var split = stereo;
    if (!stereo and duration >= 0 and n > 2 and cache.len > 0 and b > @as(i32, @intCast(cache[cache[0]])) + 12) {
        n >>= 1;
        y = x[n..];
        split = true;
        duration -= 1;
        if (blocks == 1) fill = (fill & 1) | (fill << 1);
        blocks = (blocks + 1) >> 1;
    }

    if (split) {
        // θ 解码
        const pulse_cap = @as(i32, tables.ff_celt_log_freq_range[band]) + duration * 8;
        const offset = (pulse_cap >> 1) - (if (stereo and n == 2) @as(i32, CELT_QTHETA_OFFSET_TWOPHASE) else CELT_QTHETA_OFFSET);
        const qn: i32 = if (stereo and band >= f.intensity_stereo) 1 else computeQn(@intCast(n), b, offset, pulse_cap, stereo);
        const tell = rc.tellFrac();
        var itheta: i32 = 0;
        if (qn != 1) {
            if (stereo and n > 2) {
                itheta = @intCast(rc.decUintStep(@intCast(@divTrunc(qn, 2))));
            } else if (stereo or b0 > 1) {
                itheta = @intCast(rc.decUint(@intCast(qn + 1)));
            } else {
                itheta = @intCast(rc.decUintTri(qn));
            }
            itheta = @divTrunc(itheta * 16384, qn);
        } else if (stereo) {
            inv = (b > 2 << 3 and f.remaining2 > 2 << 3);
            if (inv) {
                inv = rc.decLog(2) != 0;
            }
            inv = inv and f.apply_phase_inv != 0;
            itheta = 0;
        }
        const qalloc = rc.tellFrac() - tell;
        b -= @intCast(qalloc);

        // imid / iside / delta
        var delta: i32 = 0;
        if (itheta == 0) {
            imid = 32767;
            iside = 0;
            fill &= (@as(u32, 1) << @intCast(blocks)) - 1;
            delta = -16384;
        } else if (itheta == 16384) {
            imid = 0;
            iside = 32767;
            fill &= ((@as(u32, 1) << @intCast(blocks)) - 1) << @intCast(blocks);
            delta = 16384;
        } else {
            imid = celtCos(itheta);
            iside = celtCos(16384 - itheta);
            delta = roundMul16((@as(i32, @intCast(n)) - 1) << 7, celtLog2tan(iside, imid));
        }
        mid = @as(f32, @floatFromInt(imid)) / 32768.0;
        side = @as(f32, @floatFromInt(iside)) / 32768.0;

        if (n == 2 and stereo) {
            // N==2 正交 mid/side 特例
            var mbits = b;
            const sbits: i32 = if (itheta != 0 and itheta != 16384) 1 << 3 else 0;
            mbits -= sbits;
            const c = itheta > 8192;
            f.remaining2 -= @intCast(qalloc + @as(u32, @intCast(sbits)));
            var x2: []f32 = undefined;
            var y2: []f32 = undefined;
            if (c) {
                x2 = y;
                y2 = x;
            } else {
                x2 = x;
                y2 = y;
            }
            var sign: i32 = 0;
            if (sbits != 0) sign = @intCast(rc.getRaw(1));
            sign = 1 - 2 * sign;
            cm = quantBand(pvq, f, rc, band, x2, null, n, mbits, blocks, lowband, duration, lowband_out, level, gain, fill_in);
            y2[0] = -@as(f32, @floatFromInt(sign)) * x2[1];
            y2[1] = @as(f32, @floatFromInt(sign)) * x2[0];
            x[0] *= mid;
            x[1] *= mid;
            y[0] *= side;
            y[1] *= side;
            const tmp0 = x[0];
            x[0] = tmp0 - y[0];
            y[0] = tmp0 + y[0];
            const tmp1 = x[1];
            x[1] = tmp1 - y[1];
            y[1] = tmp1 + y[1];
        } else {
            // 常规拆分
            var next_lowband2: ?[]f32 = null;
            var next_lowband_out1: ?[]f32 = null;
            var next_level = level;
            var rebalance: i32 = 0;

            if (b0 > 1 and !stereo and (itheta & 0x3fff) != 0) {
                if (itheta > 8192) {
                    delta -= delta >> @intCast(4 - duration);
                } else {
                    delta = @min(0, delta + @as(i32, @intCast(n << 3 >> @intCast(5 - duration))));
                }
            }
            var mbits: i32 = @max(@min(@divTrunc(b - delta, 2), b), 0);
            var sbits: i32 = b - mbits;
            f.remaining2 -= @intCast(qalloc);

            if (lowband != null and !stereo) next_lowband2 = @constCast(lowband.?[n..]);
            if (stereo) next_lowband_out1 = lowband_out else next_level = level + 1;

            rebalance = f.remaining2;
            const sh0: u32 = @bitCast(@as(i32, @intCast(b0 >> 1)) & (@as(i32, @intFromBool(stereo)) - 1));
            if (mbits >= sbits) {
                cm = quantBand(pvq, f, rc, band, x, null, n, mbits, blocks, lowband, duration, next_lowband_out1, next_level, if (stereo) 1.0 else gain * mid, fill);
                rebalance = mbits - (rebalance - f.remaining2);
                if (rebalance > 3 << 3 and itheta != 0) sbits += rebalance - (3 << 3);
                const cmt = quantBand(pvq, f, rc, band, y, null, n, sbits, blocks, next_lowband2, duration, null, next_level, gain * side, fill >> @as(u5, @intCast(blocks)));
                cm |= cmt << @as(u5, @intCast(sh0));
            } else {
                cm = quantBand(pvq, f, rc, band, y, null, n, sbits, blocks, next_lowband2, duration, null, next_level, gain * side, fill >> @as(u5, @intCast(blocks)));
                cm <<= @as(u5, @intCast(sh0));
                rebalance = sbits - (rebalance - f.remaining2);
                if (rebalance > 3 << 3 and itheta != 16384) mbits += rebalance - (3 << 3);
                cm |= quantBand(pvq, f, rc, band, x, null, n, mbits, blocks, lowband, duration, next_lowband_out1, next_level, if (stereo) 1.0 else gain * mid, fill);
            }
        }
    } else {
        // 无拆分 mono
        var q = bits2pulses(cache, b);
        var curr_bits = pulses2bits(cache, q);
        f.remaining2 -= @intCast(curr_bits);
        while (f.remaining2 < 0 and q > 0) {
            f.remaining2 += @intCast(curr_bits);
            q -= 1;
            curr_bits = pulses2bits(cache, q);
            f.remaining2 -= @intCast(curr_bits);
        }
        if (q != 0) {
            const k_eff: u32 = if (q < 8)
                @intCast(q)
            else
                @as(u32, @intCast((8 + (q & 7)))) << @intCast((q >> 3) - 1);
            cm = algUnquant(rc, x, n, k_eff, f.spread, blocks, gain, &pvq.qcoeff);
        } else {
            const cm_mask = (@as(u32, 1) << @intCast(blocks)) - 1;
            fill &= cm_mask;
            if (fill != 0) {
                if (lowband == null) {
                    // Noise
                    for (0..n) |i| {
                        const r = celt_types.celtRng(f);
                        x[i] = @floatFromInt(@as(i32, @bitCast(r)) >> 20);
                    }
                    cm = cm_mask;
                } else {
                    // Folded spectrum
                    for (0..n) |i| {
                        const r = celt_types.celtRng(f);
                        x[i] = lowband.?[i] + (if ((r & 0x8000) != 0) @as(f32, 1.0) / 256.0 else @as(f32, -1.0) / 256.0);
                    }
                    cm = fill;
                }
                renormalizeVector(x[0..n], gain);
            } else {
                @memset(x[0..n], 0);
            }
        }
    }

    // 尾部
    if (stereo) {
        if (n > 2) stereoMerge(x, y, mid, n);
        if (inv) {
            for (0..n) |i| y[i] *= -1.0;
        }
    } else if (level == 0) {
        if (b0 > 1) deinterleaveHadamard(pvq.hadamard_tmp[0..256], x, n_b >> @intCast(recombine), b0 << @intCast(recombine), longblocks);
        n_b = n_b0;
        blocks = b0;
        var k: usize = 0;
        while (k < time_divide) : (k += 1) {
            blocks >>= 1;
            n_b <<= 1;
            cm |= cm >> @as(u5, @intCast(blocks));
            haar1(x, n_b, blocks);
        }
        k = 0;
        while (k < recombine) : (k += 1) {
            cm = @as(u32, tables.ff_celt_bit_deinterleave[@intCast(cm & 0xF)]) |
                (@as(u32, tables.ff_celt_bit_deinterleave[cm >> 4 & 0xF]) << 2) |
                (@as(u32, tables.ff_celt_bit_deinterleave[cm >> 8 & 0xF]) << 4) |
                (@as(u32, tables.ff_celt_bit_deinterleave[cm >> 12 & 0xF]) << 6);
            haar1(x, n0 >> @as(u6, @intCast(k)), @as(usize, 1) << @as(u6, @intCast(k)));
        }
        blocks <<= @intCast(recombine);
        if (lowband_out) |lo| {
            const s: f32 = @floatCast(@sqrt(@as(f64, @floatFromInt(n0))));
            for (0..n0) |i| lo[i] = s * x[i];
        }
        cm &= (@as(u32, 1) << @intCast(blocks)) - 1;
    }
    return cm;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "pvq: U(N,K) 递推校验（表一致性）" {
    // U(n,k) = U(n,k-1) + U(n-1,k-1) + U(n-1,k)
    for (1..14) |n| {
        for (@as(usize, n)..13) |k| {
            const lhs = u(n, k);
            const rhs = u(n, k - 1) + u(n - 1, k - 1) + u(n - 1, k);
            try testing.expectEqual(rhs, lhs);
        }
    }
}

test "pvq: celt_cos 定点值" {
    try testing.expectEqual(@as(i32, 32768), celtCos(0)); // cos 0
    try testing.expectEqual(@as(i32, 23171), celtCos(8192)); // cos(pi/4)·32768
    try testing.expectEqual(@as(i32, 0), celtCos(16384)); // cos(pi/2)
    try testing.expectEqual(@as(i32, 32768), celtCos(16384 - 16384)); // cos 0
}

test "pvq: cwrsi 索引解码 round-trip（小规模）" {
    // 对 N=3, K=2：V(3,2)=U(3,2)+U(3,3)=25+13=38 个向量
    const N: u32 = 3;
    const K: u32 = 2;
    const total = v(N, K);
    var seen: [38][3]i32 = undefined;
    for (0..total) |i| {
        var y: [4]i32 = undefined;
        _ = cwrsi(N, K, @intCast(i), &y);
        // 校验 L1 范数 = K
        var sum: u32 = 0;
        for (0..N) |j| sum += @intCast(@abs(y[j]));
        try testing.expectEqual(K, sum);
        // 唯一性：与所有已解码向量比较
        for (0..i) |p| {
            var same = true;
            for (0..N) |j| {
                if (seen[p][j] != y[j]) {
                    same = false;
                    break;
                }
            }
            try testing.expect(!same);
        }
        for (0..N) |j| seen[i][j] = y[j];
    }
}
