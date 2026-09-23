// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! 共享 Biquad 系数工具（docs/audio-kernel-zig.md §14；扩张计划方向① D1/D2）
//!
//! 提供参数化 EQ / 次声低频管理共用的 Direct-Form-I 状态机与系数计算：
//!   - peaking / low-shelf / high-shelf / high-pass / low-pass（Audio EQ Cookbook 公式）；
//!   - 一阶高通（双线性变换，K = tan(w0/2)）。
//!
//! 精度纪律：`w0` 以 f64 计算后落回 f32，与既有 `kernel/dsp/eq.zig` 的
//! `calcPeaking` 完全一致（逐位对齐 C 壳 `equalizer.c`）；三角函数/幂函数
//! 直接调用宿主 libm（`dspmath.zig`），避免 Zig compiler_rt 自带实现的 ulp 差异。
//!
//! 命名自有（`era_` 前缀），biquad/peaking/shelf 等为通用 DSP 术语，
//! 不照搬 FFmpeg / SoX / WebAudio 等上游标识符。

const std = @import("std");
const math = @import("dspmath.zig");

/// Direct-Form-I 二阶 IIR 状态机（系数 + 四状态；逐声道独立使用）。
pub const EraBiquadState = struct {
    b0: f32 = 1.0,
    b1: f32 = 0.0,
    b2: f32 = 0.0,
    a1: f32 = 0.0,
    a2: f32 = 0.0,
    x1: f32 = 0.0,
    x2: f32 = 0.0,
    y1: f32 = 0.0,
    y2: f32 = 0.0,

    /// 清空历史状态（系数保留）。
    pub inline fn reset(self: *EraBiquadState) void {
        self.x1 = 0.0;
        self.x2 = 0.0;
        self.y1 = 0.0;
        self.y2 = 0.0;
    }

    /// 处理一个样本并推进状态（Direct Form I）。
    pub inline fn tick(self: *EraBiquadState, x: f32) f32 {
        const y = self.b0 * x + self.b1 * self.x1 + self.b2 * self.x2 -
            self.a1 * self.y1 - self.a2 * self.y2;
        self.x2 = self.x1;
        self.x1 = x;
        self.y2 = self.y1;
        self.y1 = y;
        return y;
    }
};

/// 归一化后写入系数（a0 恒为 1）。
fn storeNormalized(
    f: *EraBiquadState,
    b0: f32,
    b1: f32,
    b2: f32,
    a0: f32,
    a1: f32,
    a2: f32,
) void {
    f.b0 = b0 / a0;
    f.b1 = b1 / a0;
    f.b2 = b2 / a0;
    f.a1 = a1 / a0;
    f.a2 = a2 / a0;
}

/// 归一化角频率 w0 = 2π·freq/sample_rate（与 `eq.zig` 一致：f64 计算后截断）。
pub inline fn omega0(freq: f32, sample_rate: u32) f32 {
    return @floatCast(
        2.0 * std.math.pi * @as(f64, freq) / @as(f64, @floatFromInt(sample_rate)),
    );
}

/// 峰值（peaking）EQ（对照 Audio EQ Cookbook / C 壳 `biquad_calc_peaking`）。
pub fn era_biquad_peaking(
    f: *EraBiquadState,
    freq: f32,
    q: f32,
    gain_db: f32,
    sample_rate: u32,
) void {
    const a_gain = math.gainFromDb(gain_db);
    const w0 = omega0(freq, sample_rate);
    const alpha = math.sinf(w0) / (2.0 * q);
    const cos_w0 = math.cosf(w0);

    const b0 = 1.0 + alpha * a_gain;
    const b1 = -2.0 * cos_w0;
    const b2 = 1.0 - alpha * a_gain;
    const a0 = 1.0 + alpha / a_gain;
    const a1 = -2.0 * cos_w0;
    const a2 = 1.0 - alpha / a_gain;
    storeNormalized(f, b0, b1, b2, a0, a1, a2);
}

/// 低架（low-shelf）EQ（RBJ 公式；alpha = sin(w0)/(2Q)，Q=1/√2 即 S=1 斜率）。
pub fn era_biquad_low_shelf(
    f: *EraBiquadState,
    freq: f32,
    q: f32,
    gain_db: f32,
    sample_rate: u32,
) void {
    const a_gain = math.gainFromDb(gain_db);
    const w0 = omega0(freq, sample_rate);
    const alpha = math.sinf(w0) / (2.0 * q);
    const cos_w0 = math.cosf(w0);
    const sqrt_a = @sqrt(a_gain);
    const two_sqrt_a_alpha = 2.0 * sqrt_a * alpha;

    const ap1 = a_gain + 1.0;
    const am1 = a_gain - 1.0;
    const b0 = a_gain * (ap1 - am1 * cos_w0 + two_sqrt_a_alpha);
    const b1 = 2.0 * a_gain * (am1 - ap1 * cos_w0);
    const b2 = a_gain * (ap1 - am1 * cos_w0 - two_sqrt_a_alpha);
    const a0 = ap1 + am1 * cos_w0 + two_sqrt_a_alpha;
    const a1 = -2.0 * (am1 + ap1 * cos_w0);
    const a2 = ap1 + am1 * cos_w0 - two_sqrt_a_alpha;
    storeNormalized(f, b0, b1, b2, a0, a1, a2);
}

/// 高架（high-shelf）EQ（RBJ 公式）。
pub fn era_biquad_high_shelf(
    f: *EraBiquadState,
    freq: f32,
    q: f32,
    gain_db: f32,
    sample_rate: u32,
) void {
    const a_gain = math.gainFromDb(gain_db);
    const w0 = omega0(freq, sample_rate);
    const alpha = math.sinf(w0) / (2.0 * q);
    const cos_w0 = math.cosf(w0);
    const sqrt_a = @sqrt(a_gain);
    const two_sqrt_a_alpha = 2.0 * sqrt_a * alpha;

    const ap1 = a_gain + 1.0;
    const am1 = a_gain - 1.0;
    const b0 = a_gain * (ap1 + am1 * cos_w0 + two_sqrt_a_alpha);
    const b1 = -2.0 * a_gain * (am1 + ap1 * cos_w0);
    const b2 = a_gain * (ap1 + am1 * cos_w0 - two_sqrt_a_alpha);
    const a0 = ap1 - am1 * cos_w0 + two_sqrt_a_alpha;
    const a1 = 2.0 * (am1 - ap1 * cos_w0);
    const a2 = ap1 - am1 * cos_w0 - two_sqrt_a_alpha;
    storeNormalized(f, b0, b1, b2, a0, a1, a2);
}

/// 二阶高通（RBJ HPF；Q=1/√2 为 Butterworth）。
pub fn era_biquad_high_pass(
    f: *EraBiquadState,
    freq: f32,
    q: f32,
    sample_rate: u32,
) void {
    const w0 = omega0(freq, sample_rate);
    const alpha = math.sinf(w0) / (2.0 * q);
    const cos_w0 = math.cosf(w0);

    const b0 = (1.0 + cos_w0) / 2.0;
    const b1 = -(1.0 + cos_w0);
    const b2 = (1.0 + cos_w0) / 2.0;
    const a0 = 1.0 + alpha;
    const a1 = -2.0 * cos_w0;
    const a2 = 1.0 - alpha;
    storeNormalized(f, b0, b1, b2, a0, a1, a2);
}

/// 二阶低通（RBJ LPF；Q=1/√2 为 Butterworth）。
pub fn era_biquad_low_pass(
    f: *EraBiquadState,
    freq: f32,
    q: f32,
    sample_rate: u32,
) void {
    const w0 = omega0(freq, sample_rate);
    const alpha = math.sinf(w0) / (2.0 * q);
    const cos_w0 = math.cosf(w0);

    const b0 = (1.0 - cos_w0) / 2.0;
    const b1 = 1.0 - cos_w0;
    const b2 = (1.0 - cos_w0) / 2.0;
    const a0 = 1.0 + alpha;
    const a1 = -2.0 * cos_w0;
    const a2 = 1.0 - alpha;
    storeNormalized(f, b0, b1, b2, a0, a1, a2);
}

/// 一阶高通（双线性变换：K = tan(w0/2) = sin(w0/2)/cos(w0/2)，
/// `b0 = K/(1+K) = 1/(1+K)` 形式的对偶；`b1 = -b0`，`a1 = (K-1)/(K+1)`）。
/// 用 sinf/cosf 相除代替 tanf，保证与 C 回退实现同式同库。
pub fn era_biquad_first_order_high_pass(
    f: *EraBiquadState,
    freq: f32,
    sample_rate: u32,
) void {
    const w0 = omega0(freq, sample_rate);
    const half = w0 / 2.0;
    const k = math.sinf(half) / math.cosf(half);
    const norm = 1.0 / (1.0 + k);
    f.b0 = norm;
    f.b1 = -norm;
    f.b2 = 0.0;
    f.a1 = (k - 1.0) * norm;
    f.a2 = 0.0;
}

// ---------------------------------------------------------------------------
// 单元测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "biquad: peaking 与 eq.zig 同式（+6dB@1k 幅频增益有界）" {
    var f = EraBiquadState{};
    era_biquad_peaking(&f, 1000.0, 1.414, 6.0, 48000);
    try testing.expect(std.math.isFinite(f.b0));
    try testing.expect(std.math.isFinite(f.a1));
    try testing.expect(f.b0 > 1.0); // +6dB 峰值 → b0 抬升
}

test "biquad: 0dB shelf/high-pass 系数有限且状态可复位" {
    var f = EraBiquadState{};
    era_biquad_low_shelf(&f, 100.0, 0.7071, 0.0, 48000);
    try testing.expectApproxEqAbs(@as(f32, 1.0), f.b0, 1e-6);
    era_biquad_high_pass(&f, 20.0, 0.7071, 48000);
    _ = f.tick(0.5);
    f.reset();
    try testing.expectEqual(@as(f32, 0.0), f.x1);
    try testing.expectEqual(@as(f32, 0.0), f.y1);
}

test "biquad: 一阶高通 DC 增益为 0（稳态输出趋 0）" {
    var f = EraBiquadState{};
    era_biquad_first_order_high_pass(&f, 20.0, 48000);
    var y: f32 = 0.0;
    for (0..8000) |_| y = f.tick(1.0);
    try testing.expect(@abs(y) < 1e-3);
}
