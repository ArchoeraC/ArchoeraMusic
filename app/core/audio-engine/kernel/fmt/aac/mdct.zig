//! 逆 MDCT（bit-exact 复刻 FFmpeg av_tx 浮点路径，支持 f32/f64）。
//!
//! 复刻对象：libavutil/tx_template.c `ff_tx_mdct_inv` + 单块 split-radix
//! FFT codelet（fft512_ns…fft8_ns）+ `ff_tx_fft_sr_combine`，运算顺序、
//! 宏展开（CMUL/BF/BUTTERFLIES/TRANSFORM）、表布局逐一对齐：
//!   - fold：z[i] = CMUL({in[len-1-2m], in[2m]}, exp_permuted[i])，
//!     m = gather revtab（split_radix_permutation, inv=1）；
//!   - exp 表布局 [permuted(n2) | raw(n2)]，由 mdct_tables*.zig 以位模式嵌入
//!     （double 精度 cos/sin → T 截断的舍入顺序敏感，故不在 Zig 内计算）；
//!   - FFT：n2 点单块 split-radix（递归至手写 fft16/8/4 基例）；
//!   - post-twiddle 与交错输出。
//!
//! scale = 1/N/32768 已折入 exp 表；f32 表输出与 ffmpeg CLI 逐位一致
//! （mdct_golden_* 黄金向量校验）；f64 表由 f32 源值精确提升。

const std = @import("std");
const Error = @import("../../error.zig").Error;

/// 泛型 MDCT（T = f32 / f64）。f32 用 f32 表（黄金向量位模式），
/// f64 用提升表；蝶形/FFT 全程 T 精度。
pub fn Mdct(comptime T: type) type {
    const mt = if (T == f32) @import("mdct_tables.zig") else @import("mdct_tables_f64.zig");
    return struct {
        const Self = @This();
        pub const Cplx = struct { re: T, im: T };

        /// 帧长 N（1024/256/128/64）；窗口长为 2N
        len: u16,
        n2: u16,
        exp: []const Cplx, // mdct_exp_N：[permuted(N/2) | raw(N/2)]
        map: []const u16, // mdct_map_N（gather，未翻倍）

        fn tabSlice(comptime m: usize) []const T {
            return switch (m) {
                512 => &mt.fft_tab_512,
                256 => &mt.fft_tab_256,
                128 => &mt.fft_tab_128,
                64 => &mt.fft_tab_64,
                32 => &mt.fft_tab_32,
                16 => &mt.fft_tab_16,
                8 => &mt.fft_tab_8,
                else => @compileError("unsupported fft size"),
            };
        }

        inline fn bf(x: *T, y: *T, a: T, b: T) void {
            // BF(x, y, a, b): x = a - b; y = a + b
            x.* = a - b;
            y.* = a + b;
        }

        /// TRANSFORM + BUTTERFLIES（tx_template.c 宏展开）
        inline fn transformW(
            a0: *Cplx,
            a1: *Cplx,
            a2: *Cplx,
            a3: *Cplx,
            wre: T,
            wim: T,
        ) void {
            var t1: T = undefined;
            var t2: T = undefined;
            var t5: T = undefined;
            var t6: T = undefined;
            // CMUL(t1,t2, a2.re,a2.im, wre,-wim)
            t1 = a2.re * wre + a2.im * wim;
            t2 = a2.im * wre - a2.re * wim;
            // CMUL(t5,t6, a3.re,a3.im, wre,wim)
            t5 = a3.re * wre - a3.im * wim;
            t6 = a3.re * wim + a3.im * wre;

            const r0 = a0.re;
            const ai0 = a0.im;
            const r1 = a1.re;
            const ai1 = a1.im;

            var t3: T = undefined;
            var t4: T = undefined;
            // BF(t3, t5, t5, t1)
            t3 = t5 - t1;
            t5 = t5 + t1;
            // BF(a2.re, a0.re, r0, t5)
            a2.re = r0 - t5;
            a0.re = r0 + t5;
            // BF(a3.im, a1.im, i1, t3)
            a3.im = ai1 - t3;
            a1.im = ai1 + t3;
            // BF(t4, t6, t2, t6)
            t4 = t2 - t6;
            t6 = t2 + t6;
            // BF(a3.re, a1.re, r1, t4)
            a3.re = r1 - t4;
            a1.re = r1 + t4;
            // BF(a2.im, a0.im, i0, t6)
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
            // 与 tx_template.c ff_tx_fft4_ns 逐行对齐（dst == src，原地）
            var t1: T = undefined;
            var t2: T = undefined;
            var t3: T = undefined;
            var t4: T = undefined;
            var t5: T = undefined;
            var t6: T = undefined;
            var t7: T = undefined;
            var t8: T = undefined;

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
            const cos8 = mt.fft_tab_8[1];
            fft4(z);

            var t1: T = undefined;
            var t2: T = undefined;
            var t5: T = undefined;
            var t6: T = undefined;
            // BF(t1, dst[5].re, src[4].re, -src[5].re) 等（原地 src==dst）
            bf(&t1, &z[5].re, z[4].re, -z[5].re);
            bf(&t2, &z[5].im, z[4].im, -z[5].im);
            bf(&t5, &z[7].re, z[6].re, -z[7].re);
            bf(&t6, &z[7].im, z[6].im, -z[7].im);

            transformButterfliesOnly(&z[0], &z[2], &z[4], &z[6], t1, t2, t5, t6);
            transformW(&z[1], &z[3], &z[5], &z[7], cos8, cos8);
        }

        /// 仅 BUTTERFLIES 部分（t1/t2/t5/t6 由调用方按 fft8/fft16 特殊路径给出）
        inline fn transformButterfliesOnly(
            a0: *Cplx,
            a1: *Cplx,
            a2: *Cplx,
            a3: *Cplx,
            t1_in: T,
            t2_in: T,
            t5_in: T,
            t6_in: T,
        ) void {
            const t1 = t1_in;
            const t2 = t2_in;
            var t5 = t5_in;
            var t6 = t6_in;
            const r0 = a0.re;
            const ai0 = a0.im;
            const r1 = a1.re;
            const ai1 = a1.im;

            var t3: T = undefined;
            var t4: T = undefined;
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
            const cos = &mt.fft_tab_16;
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

        /// sr_combine（tx_template.c ff_tx_fft_sr_combine），len = n/8
        fn srCombine(comptime len: usize, z: []Cplx, cos: []const T) void {
            const o1 = 2 * len;
            const o2 = 4 * len;
            const o3 = 6 * len;

            // C 版用递减指针 wim（可越过表基址，仅相对读取）；此处换算为绝对索引
            // 第 j 轮：cos 正向 ci=8j；wim 绝对索引 = o1 - 8j - k
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

        pub fn fftSr(comptime n: usize, z: []Cplx) void {
            switch (n) {
                2 => fft2(z),
                4 => fft4(z),
                8 => fft8(z),
                16 => fft16(z),
                else => {
                    const n4 = n / 4;
                    fftSr(n / 2, z);
                    fftSr(n / 4, z[n4 * 2 ..]);
                    fftSr(n / 4, z[n4 * 3 ..]);
                    srCombine(n / 8, z, comptime tabSlice(n));
                },
            }
        }

        fn castExp(tab: []const T) []const Cplx {
            return @as([*]const Cplx, @ptrCast(tab.ptr))[0 .. tab.len / 2];
        }

        pub fn init(comptime len: u16) Self {
            return switch (len) {
                1024 => .{
                    .len = 1024,
                    .n2 = 512,
                    .exp = castExp(&mt.mdct_exp_1024),
                    .map = &mt.mdct_map_1024,
                },
                128 => .{
                    .len = 128,
                    .n2 = 64,
                    .exp = castExp(&mt.mdct_exp_128),
                    .map = &mt.mdct_map_128,
                },
                256 => .{
                    .len = 256,
                    .n2 = 128,
                    .exp = castExp(&mt.mdct_exp_256),
                    .map = &mt.mdct_map_256,
                },
                else => @compileError("unsupported mdct length"),
            };
        }

        /// LTP 专用：1024 点前向 MDCT（av_tx inv=0，ff_tx_mdct_fwd）。
        /// 缩放 -65536 已折入表内（mdct_exp_ltp_fwd：×2·32768）；
        /// 折叠经 scatter map（mdct_map_ltp_fwd）写回 z[map[i]]。
        pub fn initLtp() Self {
            return .{
                .len = 1024,
                .n2 = 512,
                .exp = castExp(&mt.mdct_exp_ltp_fwd),
                .map = &mt.mdct_map_ltp_fwd,
            };
        }

        /// 前向 MDCT：in = 2N（2048）个时域样本，out = N（1024）个频谱系数（交错）。
        /// 复刻 ff_tx_mdct_fwd：scatter 折叠 + split-radix FFT + post-twiddle（bit-exact）。
        pub fn transformFwd(
            self: *const Self,
            out: []T,
            in: []const T,
            scratch: []Cplx,
        ) void {
            std.debug.assert(in.len >= 2 * self.len and out.len >= self.len and scratch.len >= self.n2);
            const n2: usize = self.n2;
            const n3: usize = 3 * n2; // 1536
            const n5: usize = 5 * n2; // 2560
            const n4: usize = n2 >> 1; // 256
            const z = scratch[0..n2];

            // ---- fold（FOLD = 加；写回 z[map[i]]，scatter）----
            for (0..n2) |i| {
                const j: usize = self.map[i];
                const k = 2 * i;
                const e = self.exp[i];
                var tre: T = undefined;
                var tim: T = undefined;
                if (k < n2) {
                    tre = -in[n2 + k] + in[n2 - 1 - k];
                    tim = -in[n3 + k] - in[n3 - 1 - k];
                } else {
                    tre = -in[n2 + k] - in[n5 - 1 - k];
                    tim = in[k - n2] - in[n3 - 1 - k];
                }
                // CMUL(z[idx].im, z[idx].re, tmp.re, tmp.im, exp[i].re, exp[i].im)
                z[j].im = tre * e.re - tim * e.im;
                z[j].re = tre * e.im + tim * e.re;
            }

            // ---- n2 点 split-radix FFT（原地）----
            switch (n2) {
                512 => fftSr(512, z),
                else => unreachable,
            }

            // ---- post-twiddle（输出交错，CMUL dst 为 (re,im) 对）----
            for (0..n4) |i| {
                const p0 = n4 + i;
                const p1 = n4 - i - 1;
                const s1re = z[p1].re;
                const s1im = z[p1].im;
                const s0re = z[p0].re;
                const s0im = z[p0].im;
                const e1 = self.exp[p1];
                const e0 = self.exp[p0];
                out[2 * p1 + 1] = s0re * e0.im - s0im * e0.re;
                out[2 * p0] = s0re * e0.re + s0im * e0.im;
                out[2 * p0 + 1] = s1re * e1.im - s1im * e1.re;
                out[2 * p1] = s1re * e1.re + s1im * e1.im;
            }
        }

        /// SBR 专用：64 点逆向 MDCT（av_tx inv=1 半长，64 入 → 64 出）。
        /// 缩放已折入表内（mdct_exp_sbr_ana：×(-2·32768)；mdct_exp_sbr_syn：×1/(64·32768)）。
        pub fn initSbr(comptime scale: enum { analysis, synthesis }) Self {
            return switch (scale) {
                .analysis => .{
                    .len = 64,
                    .n2 = 32,
                    .exp = castExp(&mt.mdct_exp_sbr_ana),
                    .map = &mt.mdct_map_64,
                },
                .synthesis => .{
                    .len = 64,
                    .n2 = 32,
                    .exp = castExp(&mt.mdct_exp_sbr_syn),
                    .map = &mt.mdct_map_64,
                },
            };
        }

        /// 逆 MDCT：in = N 个频谱系数（T），out = N 个时域样本（交错写入）。
        /// scratch 为调用方提供的 N/2 复数工作区（跨声道可复用，无状态依赖）。
        pub fn transform(
            self: *const Self,
            out: []T,
            in: []const T,
            scratch: []Cplx,
        ) void {
            std.debug.assert(out.len >= self.len and in.len >= self.len and scratch.len >= self.n2);
            const n = self.len;
            const n2: usize = self.n2;
            const n4: usize = n2 >> 1;
            const z = scratch[0..n2];

            // ---- fold（ff_tx_mdct_inv 折叠循环，map 翻倍）----
            for (0..n2) |i| {
                const k: usize = @as(usize, self.map[i]) << 1;
                const tre = in[n - 1 - k];
                const tim = in[k];
                const e = self.exp[i]; // permuted 段
                z[i].re = tre * e.re - tim * e.im;
                z[i].im = tre * e.im + tim * e.re;
            }

            // ---- n2 点 split-radix FFT（原地）----
            switch (n2) {
                512 => fftSr(512, z),
                128 => fftSr(128, z),
                64 => fftSr(64, z),
                32 => fftSr(32, z),
                else => unreachable,
            }

            // ---- post-twiddle（exp += n2 后的 raw 段）----
            const raw = self.exp[n2..];
            for (0..n4) |i| {
                const p0 = n4 + i;
                const p1 = n4 - i - 1;
                // C 版先快照 src1/src0 再写回（存在别名，顺序敏感）
                const s1re = z[p1].im;
                const s1im = z[p1].re;
                const s0re = z[p0].im;
                const s0im = z[p0].re;
                const e1 = raw[p1];
                const e0 = raw[p0];
                // CMUL(z[i1].re, z[i0].im, src1.re, src1.im, E.im, E.re)
                z[p1].re = s1re * e1.im - s1im * e1.re;
                z[p0].im = s1re * e1.re + s1im * e1.im;
                // CMUL(z[i0].re, z[i1].im, src0.re, src0.im, F.im, F.re)
                z[p0].re = s0re * e0.im - s0im * e0.re;
                z[p1].im = s0re * e0.re + s0im * e0.im;
            }

            // ---- 交错输出（z 的 re/im 即连续 T）----
            @memcpy(out[0..n], @as([*]const T, @ptrCast(z.ptr))[0..n]);
        }
    };
}

// ---------------- 测试 ----------------

const testing = std.testing;

fn lcgInput(comptime T: type, len: usize, out: []T) void {
    var seed: u32 = 0x1f2e3d4c;
    for (0..len) |i| {
        seed = seed *% 1664525 +% 1013904223;
        out[i] = @as(T, @floatFromInt(@as(i32, @bitCast(seed)) >> 8));
        out[i] /= @as(T, @floatFromInt(1 << 22));
    }
}

test "MDCT 1024 前向（LTP）与 ffmpeg 黄金向量逐位一致" {
    const M = Mdct(f32);
    const m = M.initLtp();
    var in: [2048]f32 = undefined;
    var out: [1024]f32 = undefined;
    var scratch: [512]M.Cplx = undefined;
    lcgInput(f32, in.len, &in);
    m.transformFwd(&out, &in, &scratch);
    var mismatches: usize = 0;
    for (out, mt_golden.mdct_golden_fwd_1024) |got, want| {
        if (@as(u32, @bitCast(got)) != want) mismatches += 1;
    }
    if (mismatches != 0) {
        std.debug.print("\nMDCT1024FWD mismatch: {}/1024\n", .{mismatches});
        return error.TestExpectedEqual;
    }
}

test "MDCT 1024 与 ffmpeg 黄金向量逐位一致" {
    const M = Mdct(f32);
    const m = M.init(1024);
    var in: [1024]f32 = undefined;
    var out: [1024]f32 = undefined;
    var scratch: [512]M.Cplx = undefined;
    lcgInput(f32, in.len, &in);
    m.transform(&out, &in, &scratch);
    var mismatches: usize = 0;
    for (out, mt_golden.mdct_golden_1024) |got, want| {
        if (@as(u32, @bitCast(got)) != want) mismatches += 1;
    }
    if (mismatches != 0) {
        std.debug.print("\nMDCT1024 mismatch: {}/1024\n", .{mismatches});
        return error.TestExpectedEqual;
    }
}

test "MDCT 128 与 ffmpeg 黄金向量逐位一致" {
    const M = Mdct(f32);
    const m = M.init(128);
    var in: [128]f32 = undefined;
    var out: [128]f32 = undefined;
    var scratch: [64]M.Cplx = undefined;
    lcgInput(f32, in.len, &in);
    m.transform(&out, &in, &scratch);
    var mismatches: usize = 0;
    for (out, mt_golden.mdct_golden_128) |got, want| {
        if (@as(u32, @bitCast(got)) != want) mismatches += 1;
    }
    if (mismatches != 0) {
        std.debug.print("\nMDCT128 mismatch: {}/128\n", .{mismatches});
        return error.TestExpectedEqual;
    }
}

const mt_golden = @import("mdct_tables.zig");
