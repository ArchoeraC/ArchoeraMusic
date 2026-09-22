// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! 10 段 Biquad 均衡器（docs/audio-kernel-zig.md §14；方向① 地基）
//!
//! 逐函数移植自 C 壳 `src/equalizer.c`（Audio EQ Cookbook peaking 公式）：
//!   - 固定 10 段 ISO 频点 31.25…16k Hz，Q = 1.414（√2），±12 dB；
//!   - 前级增益（preamp，dB，20·log10 线性换算）；
//!   - Direct Form I 状态机，逐段就地串联；全零直通短路。
//! 对外等价 `equalizer_*`，经 `zk_dsp_eq_*` C ABI 暴露；C 壳优先路由内核、
//! 失败回退 C 实现。
//!
//! 命名自有（era_ 前缀），不照搬 FFmpeg / SoX / Audio EQ Cookbook 等上游标识符。

const std = @import("std");
const math = @import("dspmath.zig");
const Stage = @import("stage.zig").Stage;

/// 频段数（与 C `EQ_BANDS` 一致，ABI 契约固定）。
pub const era_eq_band_count: usize = 10;

/// 固定 10 段 ISO 标准频点（Hz）——字面量与 C `EQ_FREQUENCIES` 逐字对齐。
pub const era_eq_band_freqs = [era_eq_band_count]f32{
    31.25,  62.5,   125.0,  250.0,  500.0,
    1000.0, 2000.0, 4000.0, 8000.0, 16000.0,
};

/// 标准带宽（√2），与 C `float Q = 1.414f` 一致。
const era_eq_q: f32 = 1.414;

/// 单个 Biquad（Direct Form I：系数 + 4 状态，逐声道独立）。
pub const EraBiquad = struct {
    b0: f32 = 0.0,
    b1: f32 = 0.0,
    b2: f32 = 0.0,
    a1: f32 = 0.0,
    a2: f32 = 0.0,
    x1: f32 = 0.0,
    x2: f32 = 0.0,
    y1: f32 = 0.0,
    y2: f32 = 0.0,
};

/// 均衡器实例（不透明于 C 侧 `ZkDspEq`）。
pub const EraEq = struct {
    allocator: std.mem.Allocator,
    sample_rate: u32,
    channels: u8,
    gains: [era_eq_band_count]f32 = [_]f32{0.0} ** era_eq_band_count,
    preamp_db: f32 = 0.0,
    /// `[band * channels + ch]`，长度 = band_count × channels。
    filters: []EraBiquad,
    /// 全零增益且 preamp=0：跳过整条链（对齐 C 直通）。
    passthrough: bool = true,

    fn allGainsZero(self: *const EraEq) bool {
        for (self.gains) |g| {
            if (g != 0.0) return false;
        }
        return true;
    }
};

/// 计算单段 peaking EQ 系数（对照 C `biquad_calc_peaking`）。
///
/// 注意：C 的 `w0 = 2.0f * M_PI * freq / sample_rate` 中 `M_PI` 为 **double**
/// 常量，整式以 double 计算后再落回 float；此处同样以 f64 计算后截断，
/// 保证与 C 逐位一致。
fn calcPeaking(f: *EraBiquad, freq: f32, gain_db: f32, q: f32, sample_rate: u32) void {
    const a_gain = math.gainFromDb(gain_db);
    const w0: f32 = @floatCast(
        2.0 * std.math.pi * @as(f64, freq) / @as(f64, @floatFromInt(sample_rate)),
    );
    const alpha = math.sinf(w0) / (2.0 * q);
    const cos_w0 = math.cosf(w0);

    const b0 = 1.0 + alpha * a_gain;
    const b1 = -2.0 * cos_w0;
    const b2 = 1.0 - alpha * a_gain;
    const a0 = 1.0 + alpha / a_gain;
    const a1 = -2.0 * cos_w0;
    const a2 = 1.0 - alpha / a_gain;

    f.b0 = b0 / a0;
    f.b1 = b1 / a0;
    f.b2 = b2 / a0;
    f.a1 = a1 / a0;
    f.a2 = a2 / a0;
}

/// 创建均衡器（对照 C `equalizer_create`；初始增益全 0 = 直通）。
pub fn era_eq_create(allocator: std.mem.Allocator, sample_rate: u32, channels: u8) !*EraEq {
    if (sample_rate == 0 or channels == 0) return error.InvalidArgument;
    const self = try allocator.create(EraEq);
    errdefer allocator.destroy(self);
    const filters = try allocator.alloc(EraBiquad, era_eq_band_count * @as(usize, channels));
    for (filters) |*f| f.* = .{};
    self.* = .{
        .allocator = allocator,
        .sample_rate = sample_rate,
        .channels = channels,
        .filters = filters,
    };
    return self;
}

/// 销毁均衡器（对照 C `equalizer_destroy`）。
pub fn era_eq_destroy(eq: *EraEq) void {
    const a = eq.allocator;
    a.free(eq.filters);
    a.destroy(eq);
}

/// 设置 10 段增益（dB）并重算全部系数（对照 C `equalizer_set_gains`）。
pub fn era_eq_set_gains(eq: *EraEq, gains: [era_eq_band_count]f32) void {
    eq.gains = gains;
    for (0..era_eq_band_count) |band| {
        const freq = era_eq_band_freqs[band];
        const gain = gains[band];
        for (0..eq.channels) |ch| {
            calcPeaking(
                &eq.filters[band * eq.channels + ch],
                freq,
                gain,
                era_eq_q,
                eq.sample_rate,
            );
        }
    }
    eq.passthrough = eq.allGainsZero() and eq.preamp_db == 0.0;
}

/// 设置前级增益（dB）（对照 C `equalizer_set_preamp`）。
pub fn era_eq_set_preamp(eq: *EraEq, preamp_db: f32) void {
    eq.preamp_db = preamp_db;
    eq.passthrough = eq.allGainsZero() and preamp_db == 0.0;
}

/// 就地处理交错 float32 PCM（对照 C `equalizer_process`）。
/// `pcm.len` 须为 `frames * channels`。
pub fn era_eq_process(eq: *EraEq, pcm: []f32, frames: usize) void {
    if (frames == 0) return;
    if (eq.passthrough) return;

    const ch: usize = eq.channels;
    const preamp = math.ampFromDb(eq.preamp_db);

    for (0..era_eq_band_count) |band| {
        if (eq.gains[band] == 0.0) continue;
        for (0..ch) |c| {
            const f = &eq.filters[band * ch + c];
            var i: usize = 0;
            while (i < frames) : (i += 1) {
                const x = pcm[i * ch + c];
                const y = f.b0 * x + f.b1 * f.x1 + f.b2 * f.x2 - f.a1 * f.y1 - f.a2 * f.y2;
                f.x2 = f.x1;
                f.x1 = x;
                f.y2 = f.y1;
                f.y1 = y;
                pcm[i * ch + c] = y;
            }
        }
    }

    if (preamp != 1.0) {
        const total = frames * ch;
        for (0..total) |i| pcm[i] *= preamp;
    }
}

/// 统一接口适配（见 `stage.zig`）。
pub fn era_eq_stage(eq: *EraEq) Stage {
    return .{ .ctx = @ptrCast(eq), .vtable = &vtable, .channels = eq.channels };
}

const vtable = Stage.VTable{ .process = processThunk };

fn processThunk(ctx: *anyopaque, pcm: []f32, frames: usize) void {
    const eq: *EraEq = @ptrCast(@alignCast(ctx));
    era_eq_process(eq, pcm, frames);
}

// ---------------------------------------------------------------------------
// 单元测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "era_eq: 全零增益 + preamp=0 为直通（逐位不变）" {
    const eq = try era_eq_create(testing.allocator, 48000, 2);
    defer era_eq_destroy(eq);

    var buf = [_]f32{ 0.1, -0.2, 1.0, -1.0, 0.0, 0.3 };
    const orig = buf;
    era_eq_process(eq, &buf, 3);
    try testing.expectEqualSlices(f32, &orig, &buf);
}

test "era_eq: 静音输入保持静音；非零增益不产生 NaN/Inf" {
    const eq = try era_eq_create(testing.allocator, 48000, 2);
    defer era_eq_destroy(eq);

    var silence = [_]f32{0.0} ** 64;
    era_eq_process(eq, &silence, 32);
    for (silence) |v| try testing.expectEqual(@as(f32, 0.0), v);

    era_eq_set_gains(eq, .{ 0, 0, 0, 0, 0, 3, 0, -6, 1.5, 0 });
    era_eq_set_preamp(eq, -3.0);

    var buf: [128]f32 = undefined;
    var seed: u32 = 0x1234_5678;
    for (&buf) |*v| {
        seed = seed *% 1664525 +% 1013904223;
        v.* = @as(f32, @floatFromInt(seed >> 8)) / 8388608.0 - 1.0;
    }
    era_eq_process(eq, &buf, 64);
    for (buf) |v| {
        try testing.expect(!std.math.isNan(v));
        try testing.expect(!std.math.isInf(v));
    }
}

test "era_eq: 单段 +6dB peaking 对 1kHz 附近能量有增益" {
    const eq = try era_eq_create(testing.allocator, 48000, 1);
    defer era_eq_destroy(eq);

    // 关闭 1k 段以外全部；输入 1kHz 正弦
    era_eq_set_gains(eq, .{ 0, 0, 0, 0, 0, 6, 0, 0, 0, 0 });

    const n = 4096;
    var buf: [n]f32 = undefined;
    const w = 2.0 * std.math.pi * 1000.0 / 48000.0;
    for (0..n) |i| buf[i] = @floatCast(@sin(w * @as(f64, @floatFromInt(i))));

    // 前 1024 样本含瞬态，统计稳态段 RMS
    era_eq_process(eq, &buf, n);
    var sum: f64 = 0.0;
    for (buf[2048..]) |v| sum += @as(f64, v) * @as(f64, v);
    const rms = @sqrt(sum / 2048.0);
    // +6dB ≈ ×2，稳态 RMS 应显著高于原 0.707 量级
    try testing.expect(rms > 0.9);
}

test "era_eq: stage 统一接口派发与直调一致（独立实例、同参数）" {
    const eq_a = try era_eq_create(testing.allocator, 48000, 2);
    defer era_eq_destroy(eq_a);
    const eq_b = try era_eq_create(testing.allocator, 48000, 2);
    defer era_eq_destroy(eq_b);
    era_eq_set_gains(eq_a, .{ 0, 0, 0, 0, 0, 2, 0, 0, 0, 0 });
    era_eq_set_gains(eq_b, .{ 0, 0, 0, 0, 0, 2, 0, 0, 0, 0 });

    var a: [64]f32 = undefined;
    var seed: u32 = 7;
    for (&a) |*v| {
        seed = seed *% 1664525 +% 1013904223;
        v.* = @as(f32, @floatFromInt(seed >> 9)) / 4194304.0 - 1.0;
    }
    var b = a;
    era_eq_process(eq_a, &a, 32);
    era_eq_stage(eq_b).process(&b, 32);
    try testing.expectEqualSlices(f32, &a, &b);
}
