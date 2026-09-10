// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! libopus kiss_fft + clt_mdct_backward 浮点移植（CELT 合成 bit-exact，§9.2）
//!
//! 重构对照 libopus `celt/kiss_fft.c`（kf_factor / compute_bitrev_table /
//! compute_twiddles / kf_bfly2/3/4/5 / opus_fft_impl）与 `celt/mdct.c`
//! （clt_mdct_init / clt_mdct_backward_c）（许可登记见 audio-engine/THIRD-PARTY-LICENSES.md）。
//!
//! 浮点语义：全部按 libopus FLOAT 构建——S_MUL=普通乘、C_MUL=复数乘、
//! C_ADD/C_SUB=普通复数加减、HALF_OF=x*0.5、SHL32_ovflw(x,0)=PSHR32_ovflw(x,0)=x
//! （FLOAT 下 pre_shift=post_shift=fft_shift=0）。twiddle/trig 用 double cos/sin
//! 后截断 f32；运算顺序逐条对齐以保证位级一致。

const std = @import("std");
const stables = @import("static_tables.zig");

pub const Complex = struct { r: f32, i: f32 };

const MAX_FACTORS = 32;
const MAX_NFFT = 480; // 全带宽 20ms：MDCT N=1920，FFT 长 N/4=480

pub const FftState = struct {
    nfft: usize,
    scale: f32,
    factors: [MAX_FACTORS]u16 = undefined,
    bitrev: [MAX_NFFT]u16 = undefined,
    /// twiddles 表（base 全表复制；shift>0 状态共享 base 值，索引为 fstride<<shift）
    twiddles: [MAX_NFFT]Complex = undefined,
    /// shift>0 的状态共享 base（shift=0）的 twiddles 值，蝶形以 fstride<<shift 索引
    shift: usize = 0,
};

inline fn cmul(a: Complex, b: Complex) Complex {
    return .{ .r = a.r * b.r - a.i * b.i, .i = a.r * b.i + a.i * b.r };
}

inline fn cadd(a: Complex, b: Complex) Complex {
    return .{ .r = a.r + b.r, .i = a.i + b.i };
}

inline fn csub(a: Complex, b: Complex) Complex {
    return .{ .r = a.r - b.r, .i = a.i - b.i };
}

inline fn half(x: f32) f32 {
    return x * 0.5;
}

/// kf_factor：因子分解（p,m 对；含 radix4/2/3/5 与 p==2 特例、反转）。
fn kfFactor(n_in: i32, fac: *[MAX_FACTORS]u16) bool {
    var n: i32 = n_in;
    const nbak = n;
    var p: i32 = 4;
    var stages: usize = 0;
    while (true) {
        while (@rem(n, p) != 0) {
            switch (p) {
                4 => p = 2,
                2 => p = 3,
                else => p += 2,
            }
            if (p > 32000 or p * p > n) p = n;
        }
        n = @divTrunc(n, p);
        if (p > 5) return false;
        fac[2 * stages] = @intCast(p);
        if (p == 2 and stages > 1) {
            fac[2 * stages] = 4;
            fac[2] = 2;
        }
        stages += 1;
        if (n <= 1) break;
    }
    n = nbak;
    for (0..stages / 2) |j| {
        const tmp = fac[2 * j];
        fac[2 * j] = fac[2 * (stages - j - 1)];
        fac[2 * (stages - j - 1)] = tmp;
    }
    for (0..stages) |i| {
        n = @divTrunc(n, fac[2 * i]);
        fac[2 * i + 1] = @intCast(n);
    }
    return true;
}

/// compute_bitrev_table：递归位反转表（fout=0, fstride=1, in_stride=1）。
fn fillBitrev(fout: i32, f: []u16, fstride: usize, in_stride: usize, factors: []const u16) void {
    const p: i32 = factors[0];
    const m: i32 = factors[1];
    if (m == 1) {
        var j: i32 = 0;
        while (j < p) : (j += 1) {
            const idx: usize = @intCast(@as(i32, j * @as(i32, @intCast(fstride)) * @as(i32, @intCast(in_stride))));
            f[idx] = @intCast(fout + j);
        }
    } else {
        var fo = fout;
        var fr = f;
        var j: i32 = 0;
        while (j < p) : (j += 1) {
            fillBitrev(fo, fr, fstride * @as(usize, @intCast(p)), in_stride, factors[2..]);
            fr = fr[@as(usize, @intCast(fstride * in_stride))..];
            fo += m;
        }
    }
}

/// compute_twiddles（FLOAT）：twiddles[i] = (cos(φ), sin(φ))，φ = (-2π/nfft)·i。
fn computeTwiddles(nfft: usize, tw: []Complex) void {
    const pi: f64 = 3.141592653589793238462643383279502884;
    for (0..nfft) |i| {
        const phase: f64 = (-2.0 * pi / @as(f64, @floatFromInt(nfft))) * @as(f64, @floatFromInt(i));
        tw[i] = .{ .r = @floatCast(@cos(phase)), .i = @floatCast(@sin(phase)) };
    }
}

/// 构建 FFT 状态（float build，scale = 1/nfft）。
pub fn fftState(nfft: usize) FftState {
    var st = FftState{
        .nfft = nfft,
        .scale = 1.0 / @as(f32, @floatFromInt(nfft)),
    };
    _ = kfFactor(@intCast(nfft), &st.factors);
    computeTwiddles(nfft, st.twiddles[0..nfft]);
    fillBitrev(0, st.bitrev[0..nfft], 1, 1, st.factors[0..]);
    return st;
}

/// 构建共享 base twiddles 的 shift>0 状态（libopus opus_fft_alloc_twiddles 语义）。
pub fn fftStateShifted(nfft: usize, shift: usize, base: *const FftState) FftState {
    var st = FftState{
        .nfft = nfft,
        .scale = 1.0 / @as(f32, @floatFromInt(nfft)),
    };
    _ = kfFactor(@intCast(nfft), &st.factors);
    st.twiddles = base.twiddles; // 复制 base 全表（值语义安全）
    st.shift = shift;
    fillBitrev(0, st.bitrev[0..nfft], 1, 1, st.factors[0..]);
    return st;
}

/// 静态模式表构建 FFT 状态（libopus static_modes_float.h 预生成，位级权威）。
pub fn fftStateStatic(nfft: usize, shift: usize, base: *const FftState, bitrev: []const u16, factors: []const u16) FftState {
    var st = FftState{
        .nfft = nfft,
        .scale = 1.0 / @as(f32, @floatFromInt(nfft)),
        .shift = shift,
    };
    @memcpy(st.factors[0..factors.len], factors);
    st.twiddles = base.twiddles;
    @memcpy(st.bitrev[0..nfft], bitrev[0..nfft]);
    return st;
}

/// 48k 全带宽静态模式（n=1920，maxshift=3）：trig/bitrev/twiddles 用 libopus 静态表。
pub fn mdctInitStatic() MdctLookup {
    const n: usize = 1920;
    const maxshift: usize = 3;
    var l = MdctLookup{
        .n = n,
        .maxshift = maxshift,
        .shortMdctSize = n >> 4,
        .kfft = undefined,
        .trig = undefined,
        .trig_len = n - (n >> 1 >> @intCast(maxshift)),
    };
    // base kfft[0]（nfft=480）
    var base = FftState{
        .nfft = 480,
        .scale = 1.0 / 480.0,
        .shift = 0,
    };
    @memcpy(base.factors[0..16], &stables.fft_factors480);
    for (0..480) |i| base.twiddles[i] = .{ .r = stables.fft_twiddles48000_960[2 * i], .i = stables.fft_twiddles48000_960[2 * i + 1] };
    @memcpy(base.bitrev[0..480], &stables.fft_bitrev480);
    l.kfft[0] = base;
    l.kfft[1] = fftStateStatic(240, 1, &l.kfft[0], &stables.fft_bitrev240, &stables.fft_factors240);
    l.kfft[2] = fftStateStatic(120, 2, &l.kfft[0], &stables.fft_bitrev120, &stables.fft_factors120);
    l.kfft[3] = fftStateStatic(60, 3, &l.kfft[0], &stables.fft_bitrev60, &stables.fft_factors60);
    // trig：libopus 静态 mdct_twiddles960（1800 = 960+480+240+120，与计算版差 ≤1 ULP）
    @memcpy(l.trig[0..1800], &stables.mdct_twiddles960);
    return l;
}

/// kf_bfly2（FLOAT；m==1 退化分支 + m==4 标准分支）。
fn kfBfly2(fout: []Complex, m_in: usize, n: usize) void {
    if (m_in == 1) {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const base = 2 * i;
            const t = fout[base + 1];
            fout[base + 1] = csub(fout[base], t);
            fout[base] = cadd(fout[base], t);
        }
    } else {
        const tw: f32 = 0.7071067812;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const base = 8 * i;
            var t: Complex = fout[base + 4];
            fout[base + 4] = csub(fout[base], t);
            fout[base] = cadd(fout[base], t);
            t = .{ .r = (fout[base + 5].r + fout[base + 5].i) * tw, .i = (fout[base + 5].i - fout[base + 5].r) * tw };
            fout[base + 5] = csub(fout[base + 1], t);
            fout[base + 1] = cadd(fout[base + 1], t);
            t = .{ .r = fout[base + 6].i, .i = -fout[base + 6].r };
            fout[base + 6] = csub(fout[base + 2], t);
            fout[base + 2] = cadd(fout[base + 2], t);
            t = .{ .r = (fout[base + 7].i - fout[base + 7].r) * tw, .i = -(fout[base + 7].i + fout[base + 7].r) * tw };
            fout[base + 7] = csub(fout[base + 3], t);
            fout[base + 3] = cadd(fout[base + 3], t);
        }
    }
}

/// kf_bfly4（FLOAT；m==1 退化分支 + 一般分支）。
fn kfBfly4(fout: []Complex, fstride: usize, st: *const FftState, m_in: usize, n: usize, mm: usize) void {
    if (m_in == 1) {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const base = 4 * i;
            const scratch0 = csub(fout[base], fout[base + 2]);
            fout[base] = cadd(fout[base], fout[base + 2]);
            const scratch1a = cadd(fout[base + 1], fout[base + 3]);
            fout[base + 2] = csub(fout[base], scratch1a);
            fout[base] = cadd(fout[base], scratch1a);
            const scratch1b = csub(fout[base + 1], fout[base + 3]);
            fout[base + 1] = .{ .r = scratch0.r + scratch1b.i, .i = scratch0.i - scratch1b.r };
            fout[base + 3] = .{ .r = scratch0.r - scratch1b.i, .i = scratch0.i + scratch1b.r };
        }
    } else {
        const m = m_in;
        const m2 = 2 * m;
        const m3 = 3 * m;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const fb = i * mm;
            var j: usize = 0;
            while (j < m) : (j += 1) {
                const f0 = fb + j;
                const s0 = cmul(fout[f0 + m], st.twiddles[j * fstride]);
                const s1 = cmul(fout[f0 + m2], st.twiddles[2 * j * fstride]);
                const s2 = cmul(fout[f0 + m3], st.twiddles[3 * j * fstride]);
                const s5 = csub(fout[f0], s1);
                fout[f0] = cadd(fout[f0], s1);
                const s3 = cadd(s0, s2);
                const s4 = csub(s0, s2);
                fout[f0 + m2] = csub(fout[f0], s3);
                {
                    var b4: usize = 0;
                    if (b4 < 300) {
                        b4 += 1;
                    }
                }
                fout[f0] = cadd(fout[f0], s3);
                fout[f0 + m] = .{ .r = s5.r + s4.i, .i = s5.i - s4.r };
                fout[f0 + m3] = .{ .r = s5.r - s4.i, .i = s5.i + s4.r };
            }
        }
    }
}

/// kf_bfly3（FLOAT）。
fn kfBfly3(fout: []Complex, fstride: usize, st: *const FftState, m_in: usize, n: usize, mm: usize) void {
    const m = m_in;
    const m2 = 2 * m;
    const epi3_i = st.twiddles[fstride * m].i;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const fb = i * mm;
        var j: usize = 0;
        while (j < m) : (j += 1) {
            const f0 = fb + j;
            const s1 = cmul(fout[f0 + m], st.twiddles[j * fstride]);
            const s2 = cmul(fout[f0 + m2], st.twiddles[2 * j * fstride]);
            const s3 = cadd(s1, s2);
            const s0v = csub(s1, s2);
            fout[f0 + m] = .{ .r = fout[f0].r - half(s3.r), .i = fout[f0].i - half(s3.i) };
            const s0 = Complex{ .r = s0v.r * epi3_i, .i = s0v.i * epi3_i };
            fout[f0] = cadd(fout[f0], s3);
            fout[f0 + m2] = .{ .r = fout[f0 + m].r + s0.i, .i = fout[f0 + m].i - s0.r };
            fout[f0 + m].r -= s0.i;
            fout[f0 + m].i += s0.r;
        }
    }
}

/// kf_bfly5（FLOAT）。
fn kfBfly5(fout: []Complex, fstride: usize, st: *const FftState, m_in: usize, n: usize, mm: usize) void {
    const m = m_in;
    const ya = st.twiddles[fstride * m];
    const yb = st.twiddles[fstride * 2 * m];
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const fb = i * mm;
        var u: usize = 0;
        while (u < m) : (u += 1) {
            const f0 = fb + u;
            const s0 = fout[f0];
            const s1 = cmul(fout[f0 + m], st.twiddles[u * fstride]);
            const s2 = cmul(fout[f0 + 2 * m], st.twiddles[2 * u * fstride]);
            const s3 = cmul(fout[f0 + 3 * m], st.twiddles[3 * u * fstride]);
            const s4 = cmul(fout[f0 + 4 * m], st.twiddles[4 * u * fstride]);
            const s7 = cadd(s1, s4);
            const s10 = csub(s1, s4);
            const s8 = cadd(s2, s3);
            const s9 = csub(s2, s3);
            fout[f0].r += s7.r + s8.r;
            fout[f0].i += s7.i + s8.i;
            // 与 C 分组一致：s0.r + ((s7.r*ya.r) + (s8.r*yb.r))
            const s5 = Complex{ .r = s0.r + (s7.r * ya.r + s8.r * yb.r), .i = s0.i + (s7.i * ya.r + s8.i * yb.r) };
            const s6 = Complex{ .r = s10.i * ya.i + s9.i * yb.i, .i = -(s10.r * ya.i + s9.r * yb.i) };
            fout[f0 + m] = csub(s5, s6);
            fout[f0 + 4 * m] = cadd(s5, s6);
            const s11 = Complex{ .r = s0.r + (s7.r * yb.r + s8.r * ya.r), .i = s0.i + (s7.i * yb.r + s8.i * ya.r) };
            const s12 = Complex{ .r = s9.i * ya.i - s10.i * yb.i, .i = s10.r * yb.i - s9.r * ya.i };
            fout[f0 + 2 * m] = cadd(s11, s12);
            fout[f0 + 3 * m] = csub(s11, s12);
        }
    }
}

/// opus_fft_impl：按 factors 分解逐级蝶形。
pub fn opusFft(st: *const FftState, fout: []Complex) void {
    var fstride: [MAX_FACTORS]usize = undefined;
    const factors = st.factors;
    fstride[0] = 1;
    var l: usize = 0;
    var m: i32 = undefined;
    while (true) {
        const p = factors[2 * l];
        m = factors[2 * l + 1];
        fstride[l + 1] = fstride[l] * p;
        l += 1;
        if (m == 1) break;
    }
    m = factors[2 * l - 1];
    var li: i32 = @as(i32, @intCast(l)) - 1;
    while (li >= 0) : (li -= 1) {
        const i: usize = @intCast(li);
        const m2: i32 = if (i != 0) factors[2 * i - 1] else 1;
        const tw_stride = fstride[i] << @as(u6, @intCast(st.shift));
        switch (factors[2 * i]) {
            2 => kfBfly2(fout, @intCast(m), @intCast(fstride[i])),
            4 => kfBfly4(fout, tw_stride, st, @intCast(m), @intCast(fstride[i]), @intCast(m2)),
            3 => kfBfly3(fout, tw_stride, st, @intCast(m), @intCast(fstride[i]), @intCast(m2)),
            else => kfBfly5(fout, tw_stride, st, @intCast(m), @intCast(fstride[i]), @intCast(m2)),
        }
        m = m2;
    }
}

// ---------------------------------------------------------------------------
// MDCT lookup（clt_mdct_init 浮点）
// ---------------------------------------------------------------------------

 pub const MdctLookup = struct {
    n: usize, // MDCT 长度（l->n）
    maxshift: usize,
    shortMdctSize: usize, // 48k：120（= n>>4）
    kfft: [8]FftState, // kfft[shift]，FFT 长 = n/4 >> shift
    trig: [2048]f32, // trig 表（总长 N - (N2>>maxshift)）
    trig_len: usize,
};

pub fn mdctInit(n: usize, maxshift: usize) MdctLookup {
    var l = MdctLookup{
        .n = n,
        .maxshift = maxshift,
        .shortMdctSize = n >> 4,
        .kfft = undefined,
        .trig = undefined,
        .trig_len = n - (n >> 1 >> @intCast(maxshift)),
    };
    // kfft[0] 为独立状态，shift>0 共享其 twiddles（libopus 语义）
    l.kfft[0] = fftState(n >> 2);
    for (1..maxshift + 1) |s| l.kfft[s] = fftStateShifted(n >> 2 >> @as(u6, @intCast(s)), s, &l.kfft[0]);
    var trig_idx: usize = 0;
    var nn: usize = n;
    var n2: usize = n >> 1;
    const pi: f64 = std.math.pi;
    for (0..maxshift + 1) |_| {
        var i: usize = 0;
        while (i < n2) : (i += 1) {
            l.trig[trig_idx] = @floatCast(@cos(2.0 * pi * (@as(f64, @floatFromInt(i)) + 0.125) / @as(f64, @floatFromInt(nn))));
            trig_idx += 1;
        }
        n2 >>= 1;
        nn >>= 1;
    }
    return l;
}

/// clt_mdct_backward_c（FLOAT：pre_shift=post_shift=fft_shift=0）。
/// `in`：N2 个频域系数（stride 采样）；`out`：N 个时域样本（已含窗口 + TDAC）。
pub fn cltMdctBackward(
    l: *const MdctLookup,
    in_: []const f32,
    out: []f32,
    window: []const f32,
    overlap: usize,
    shift: usize,
    stride: usize,
) void {
    var n: usize = l.n;
    var trig_off: usize = 0;
    for (0..shift) |_| {
        n >>= 1;
        trig_off += n;
    }
    const n2 = n >> 1;
    const n4 = n >> 2;
    const trig = l.trig[trig_off .. trig_off + n2];
    const st = &l.kfft[shift];

    // 预旋转（bitrev 顺序写入 out+overlap/2）
    {
        const yp: usize = overlap >> 1;
        var i: usize = 0;
        while (i < n4) : (i += 1) {
            const rev = st.bitrev[i];
            const x1 = in_[2 * i * stride];
            const x2 = in_[stride * (n2 - 1 - 2 * i)];
            const yr = x2 * trig[i] + x1 * trig[n4 + i];
            const yi = x1 * trig[i] - x2 * trig[n4 + i];
            out[yp + 2 * rev + 1] = yr;
            out[yp + 2 * rev] = yi;
        }
        var pr0: usize = 0;
        if (pr0 < 2) {
            pr0 += 1;
        }
    }

    opusFft(st, @as([*]Complex, @ptrCast(out.ptr + (overlap >> 1)))[0..n4]);

    // 后旋转（两端同时就地）
    {
        var yp0: usize = overlap >> 1;
        var yp1: usize = (overlap >> 1) + n2 - 2;
        var i: usize = 0;
        while (i < (n4 + 1) >> 1) : (i += 1) {
            var re: f32 = out[yp0 + 1];
            var im: f32 = out[yp0];
            var t0 = trig[i];
            var t1 = trig[n4 + i];
            var yr = re * t0 + im * t1;
            var yi = re * t1 - im * t0;
            re = out[yp1 + 1];
            im = out[yp1];
            out[yp0] = yr;
            out[yp1 + 1] = yi;
            t0 = trig[n4 - i - 1];
            t1 = trig[n2 - i - 1];
            yr = re * t0 + im * t1;
            yi = re * t1 - im * t0;
            out[yp1] = yr;
            out[yp0 + 1] = yi;
            yp0 += 2;
            yp1 -= 2;
        }
    }

    // TDAC 镜像
    {
        var xp1: usize = overlap - 1;
        var yp1: usize = 0;
        var wp1: usize = 0;
        var wp2: usize = overlap - 1;
        var i: usize = 0;
        while (i < overlap / 2) : (i += 1) {
            const x1 = out[xp1];
            const x2 = out[yp1];
            out[yp1] = x2 * window[wp2] - x1 * window[wp1];
            out[xp1] = x2 * window[wp1] + x1 * window[wp2];
            wp1 += 1;
            wp2 -= 1;
            yp1 += 1;
            xp1 -= 1;
        }
    }
}

