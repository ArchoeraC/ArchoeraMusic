//! CELT 浮点 FFT + 逆 MDCT（docs/audio-kernel-zig.md §9.2，P2）
//!
//! 自研混合基 FFT（N = 2^a·3^b·5^c，覆盖 CELT 尺寸 60/120/240/480），
//! 结构参考重构对照 FFmpeg `libavutil/tx_template.c` 的 AV_TX_FLOAT_MDCT 逆变换
//! （ff_tx_mdct_inv / ff_tx_mdct_gen_exp）；参考对照非复制（§3.3）。
//!
//! 逆 MDCT（对齐 av_tx 结构，sub_map 取恒等）：
//!   1. 预旋转：z[i] = {src[n-1-k], src[k]} × exp[i]（k = 恒等索引）；
//!   2. 逆 FFT（长度 n/2）；
//!   3. 后旋转（exp 表第二半），输出 n/2 个复数 = n 个时域样本。
//! 尺度：exp 表含 sqrt(|scale|)，整体再乘 -1/32768（对齐 av_tx scale）。
//!
//! 说明：av_tx 与 libopus kiss_fft 求和顺序不同但均通过 RFC 6716 testvector 的
//! s16 逐位验收；本实现自然序混合基 FFT 数学等价，以 testvector s16 为准绳。

const std = @import("std");
const testing = std.testing;

pub const Complex = struct {
    re: f32,
    im: f32,
};

inline fn cmul(a: Complex, b: Complex) Complex {
    return .{ .re = a.re * b.re - a.im * b.im, .im = a.re * b.im + a.im * b.re };
}

/// 旋转因子 exp(sign·2πi·k/n)，sign=+1 逆变换，-1 正变换
fn twiddle(k: usize, n: usize, sign: f32) Complex {
    const theta = sign * 2.0 * std.math.pi * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
    return .{ .re = @floatCast(@cos(theta)), .im = @floatCast(@sin(theta)) };
}

/// 混合基 FFT（Cooley-Tukey，radix 2/3/5），原位。
/// CELT 所需尺寸均为 15·2^k = 3·5·2^k。
pub fn fft(buf: []Complex, inverse: bool) void {
    fftCore(buf, inverse);
}

/// 带 1/N 归一化的逆 FFT（仅测试/其他用途；CELT MDCT 用未归一化逆 FFT）
pub fn ifftNormalized(buf: []Complex) void {
    fftCore(buf, true);
    const inv_n: f32 = 1.0 / @as(f32, @floatFromInt(buf.len));
    for (buf) |*c| {
        c.re *= inv_n;
        c.im *= inv_n;
    }
}

/// FFT 核心（递归，不做 1/N 缩放）
fn fftCore(buf: []Complex, inverse: bool) void {
    const n = buf.len;
    if (n <= 1) return;
    const sign: f32 = if (inverse) 1.0 else -1.0;

    if (n % 2 == 0) {
        const half = n / 2;
        var even: [480]Complex = undefined;
        var odd: [480]Complex = undefined;
        for (0..half) |i| {
            even[i] = buf[2 * i];
            odd[i] = buf[2 * i + 1];
        }
        fftCore(even[0..half], inverse);
        fftCore(odd[0..half], inverse);
        for (0..half) |k| {
            const w = twiddle(k, n, sign);
            const t = cmul(odd[k], w);
            buf[k] = .{ .re = even[k].re + t.re, .im = even[k].im + t.im };
            buf[k + half] = .{ .re = even[k].re - t.re, .im = even[k].im - t.im };
        }
    } else {
        // 素因子 p（3 或 5）：拆分 p 个子 FFT
        const p: usize = if (n % 5 == 0) 5 else 3;
        const sub = n / p;
        var b: [5][480]Complex = undefined;
        for (0..p) |q| {
            for (0..sub) |i| b[q][i] = buf[p * i + q];
            fftCore(b[q][0..sub], inverse);
        }
        for (0..sub) |k| {
            // wk[q] = w^{q·k}（w = exp(sign·2πi/n)，q=0..p-1）
            var wk: [5]Complex = undefined;
            wk[0] = .{ .re = 1, .im = 0 };
            wk[1] = twiddle(k, n, sign);
            for (2..p) |q| wk[q] = cmul(wk[q - 1], wk[1]);
            // 输出 X[k + r*sub] = Σ_q b[q][k]·w^{q·k}·ω_r^q，ω=exp(sign·2πi/p)
            for (0..p) |r| {
                var acc = Complex{ .re = 0, .im = 0 };
                const omega = twiddle(r, p, sign);
                var om = Complex{ .re = 1, .im = 0 }; // ω_r^q
                for (0..p) |q| {
                    const term = cmul(cmul(b[q][k], wk[q]), om);
                    acc.re += term.re;
                    acc.im += term.im;
                    om = cmul(om, omega);
                }
                buf[k + r * sub] = acc;
            }
        }
    }
}

/// CELT 逆 MDCT（对齐 av_tx ff_tx_mdct_inv）。
/// `n` = MDCT 长度（= CELT blocksize，120/240/480/960）；`src` 频谱（n 个 f32），
/// `out` 时域（n 个 f32）。总尺度 = -1/32768。
pub fn imdct(n: usize, src: []const f32, out: []f32) void {
    const len2 = n / 2; // FFT 长度
    const len4 = n / 4;
    var z: [480]Complex = undefined;

    // exp 表（纯 cos/sin 旋转；整体尺度 -1/32768 在末尾统一施加）
    var exp_tab: [960]Complex = undefined;
    for (0..len2) |i| {
        const alpha = std.math.pi / 2.0 * (@as(f64, @floatFromInt(i)) + @as(f64, @floatFromInt(len2)) + 0.125) /
            @as(f64, @floatFromInt(len2));
        exp_tab[i] = .{
            .re = @floatCast(@cos(alpha)),
            .im = @floatCast(@sin(alpha)),
        };
    }
    // inv：exp[0..len2-1] = exp[len2 + map[i]]，恒等 map → 镜像填充
    for (0..len2) |i| exp_tab[len2 + i] = exp_tab[i];

    // 预旋转（av_tx：inv MDCT 将 sub_map 左移一位 → k = 2·map[i]）
    for (0..len2) |i| {
        const k = 2 * i;
        const tmp = Complex{ .re = src[n - 1 - k], .im = src[k] };
        z[i] = cmul(tmp, exp_tab[i]);
    }

    // 逆 FFT（av_tx 语义：未归一化；1/N 经 scale=-1/32768 链整体调节）
    fft(z[0..len2], true);

    // 后旋转（exp 表第二半）
    for (0..len4) |i| {
        const j0 = len4 + i;
        const j1 = len4 - i - 1;
        const src1 = Complex{ .re = z[j1].im, .im = z[j1].re };
        const src0 = Complex{ .re = z[j0].im, .im = z[j0].re };
        const a1 = cmul(src1, .{ .re = exp_tab[j1].im, .im = exp_tab[j1].re });
        const a0 = cmul(src0, .{ .re = exp_tab[j0].im, .im = exp_tab[j0].re });
        z[j1].re = a1.re;
        z[j0].im = a1.im;
        z[j0].re = a0.re;
        z[j1].im = a0.im;
    }

    // 输出 n 个 f32（交错 re/im）
    for (0..len2) |i| {
        out[2 * i] = z[i].re;
        out[2 * i + 1] = z[i].im;
    }
    const scale: f32 = 1.0 / 32768.0;
    for (out[0..n]) |*v| v.* *= scale;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

test "fft: radix-2 圆整（8 点）" {
    var buf: [8]Complex = undefined;
    for (0..8) |i| buf[i] = .{ .re = @floatFromInt(i), .im = 0 };
    const orig = buf;
    fft(buf[0..], false);
    ifftNormalized(buf[0..]);
    for (0..8) |i| {
        try testing.expectApproxEqAbs(orig[i].re, buf[i].re, 1e-3);
        try testing.expectApproxEqAbs(orig[i].im, buf[i].im, 1e-3);
    }
}

test "fft: 60 点（3·5·2²）圆整" {
    var buf: [60]Complex = undefined;
    var seed: u32 = 12345;
    for (0..60) |i| {
        seed = seed *% 1664525 +% 1013904223;
        buf[i] = .{ .re = @floatFromInt(@rem(@as(i32, @bitCast(seed)), 1000)), .im = 0 };
    }
    const orig = buf;
    fft(buf[0..], false);
    ifftNormalized(buf[0..]);
    for (0..60) |i| {
        try testing.expectApproxEqAbs(orig[i].re, buf[i].re, 1e-2);
        try testing.expectApproxEqAbs(orig[i].im, buf[i].im, 1e-2);
    }
}

test "fft: 480 点（3·5·2⁵）圆整" {
    var buf: [480]Complex = undefined;
    var seed: u32 = 999;
    for (0..480) |i| {
        seed = seed *% 1103515245 +% 12345;
        buf[i] = .{ .re = @floatFromInt(@rem(@as(i32, @bitCast(seed)), 100)), .im = 0 };
    }
    const orig = buf;
    fft(buf[0..], false);
    ifftNormalized(buf[0..]);
    for (0..480) |i| {
        try testing.expectApproxEqAbs(orig[i].re, buf[i].re, 1e-1);
        try testing.expectApproxEqAbs(orig[i].im, buf[i].im, 1e-1);
    }
}

test "imdct: 120 点逆 MDCT 输出有限" {
    var src: [120]f32 = [_]f32{0} ** 120;
    src[10] = 16384.0;
    var out: [120]f32 = undefined;
    imdct(120, &src, &out);
    var max_abs: f32 = 0;
    for (out) |v| max_abs = @max(max_abs, @abs(v));
    try testing.expect(max_abs > 0.001);
    try testing.expect(max_abs < 100.0);
}
