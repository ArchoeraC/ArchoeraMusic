// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! 次声 / 低频管理（docs/audio-kernel-zig.md §14；扩张计划方向① D2）
//!
//! 方向① 的「打底」低频链：
//!   - 高通（subsonic HPF，默认 20 Hz，order 1 或 2，Butterworth Q=0.7071）去隆隆声；
//!   - 低架（low-shelf）bass boost（gain_db / freq）。
//!
//! 行为约定：
//!   - 整块默认禁用（逐位旁通）；`set_enabled(true)` 后按 HPF/bass 各自使能生效；
//!   - `set_hpf(freq<=0, ...)` 关闭 HPF；非有限 freq/gain 夹取到安全范围（NaN 防护）。
//!
//! 系数计算复用 `biquad.zig`。对外经 `zk_dsp_lowfreq_*` C ABI 暴露；C 壳优先
//! 路由内核、失败回退纯 C 实现。命名自有（`era_` 前缀），不照搬上游标识符。

const std = @import("std");
const biquad = @import("biquad.zig");
const Stage = @import("stage.zig").Stage;

/// Butterworth 品质因数（阶数 2 高通 / 低架斜率 S=1）。
pub const era_lowfreq_butter_q: f32 = 0.7071;

/// 默认 HPF 截止频率（Hz）。
pub const era_lowfreq_default_hpf_freq: f32 = 20.0;

/// 默认 bass shelf 转折频率（Hz）。
pub const era_lowfreq_default_bass_freq: f32 = 100.0;

/// 次声低频管理实例（不透明于 C 侧 `ZkDspLowFreq`）。
pub const EraLowFreq = struct {
    allocator: std.mem.Allocator,
    sample_rate: u32,
    channels: u8,
    /// 整块总开关（默认关 = 逐位旁通）。
    enabled: bool = false,
    hpf_enabled: bool = false,
    hpf_freq: f32 = era_lowfreq_default_hpf_freq,
    hpf_order: u8 = 2,
    bass_gain_db: f32 = 0.0,
    bass_freq: f32 = era_lowfreq_default_bass_freq,
    /// 一阶/二阶 HPF 每声道状态（按 hpf_order 选用其一）。
    hpf1: []biquad.EraBiquadState,
    hpf2: []biquad.EraBiquadState,
    /// bass shelf 每声道状态。
    bass: []biquad.EraBiquadState,
};

fn sanitizeGain(gain_db: f32) f32 {
    if (!std.math.isFinite(gain_db)) return 0.0;
    return gain_db;
}

fn clampFreq(freq: f32, sample_rate: u32) f32 {
    const sr: f32 = @floatFromInt(sample_rate);
    const hi = sr * 0.5 * 0.999;
    if (!(freq > 0.0)) return 1.0;
    if (freq < 1.0) return 1.0;
    if (freq > hi) return hi;
    return freq;
}

/// 创建次声低频管理块（非法参数 / OOM 返回错误）。
pub fn era_lowfreq_create(
    allocator: std.mem.Allocator,
    sample_rate: u32,
    channels: u8,
) !*EraLowFreq {
    if (sample_rate == 0 or channels == 0) return error.InvalidArgument;
    const ch: usize = channels;
    const self = try allocator.create(EraLowFreq);
    errdefer allocator.destroy(self);
    const hpf1 = try allocator.alloc(biquad.EraBiquadState, ch);
    errdefer allocator.free(hpf1);
    const hpf2 = try allocator.alloc(biquad.EraBiquadState, ch);
    errdefer allocator.free(hpf2);
    const bass = try allocator.alloc(biquad.EraBiquadState, ch);
    for (hpf1) |*f| f.* = .{};
    for (hpf2) |*f| f.* = .{};
    for (bass) |*f| f.* = .{};
    self.* = .{
        .allocator = allocator,
        .sample_rate = sample_rate,
        .channels = channels,
        .hpf1 = hpf1,
        .hpf2 = hpf2,
        .bass = bass,
    };
    return self;
}

/// 销毁（NULL 由 C 侧处理）。
pub fn era_lowfreq_destroy(lf: *EraLowFreq) void {
    const a = lf.allocator;
    a.free(lf.hpf1);
    a.free(lf.hpf2);
    a.free(lf.bass);
    a.destroy(lf);
}

/// 整块启用/禁用。
pub fn era_lowfreq_set_enabled(lf: *EraLowFreq, enabled: bool) void {
    lf.enabled = enabled;
}

/// 设置 HPF（freq<=0 或非有限 → 关闭）。order 夹取到 1 / 2。
pub fn era_lowfreq_set_hpf(lf: *EraLowFreq, freq: f32, order: i32) void {
    if (!(freq > 0.0) or !std.math.isFinite(freq)) {
        lf.hpf_enabled = false;
        return;
    }
    lf.hpf_enabled = true;
    lf.hpf_order = if (order <= 1) 1 else 2;
    lf.hpf_freq = clampFreq(freq, lf.sample_rate);
    recomputeHpf(lf);
}

/// 设置 bass shelf；gain_db 为 0 时不改变（自然旁通）。
pub fn era_lowfreq_set_bass(lf: *EraLowFreq, gain_db: f32, freq: f32) void {
    lf.bass_gain_db = sanitizeGain(gain_db);
    lf.bass_freq = clampFreq(freq, lf.sample_rate);
    for (0..lf.channels) |c| {
        biquad.era_biquad_low_shelf(
            &lf.bass[c],
            lf.bass_freq,
            era_lowfreq_butter_q,
            lf.bass_gain_db,
            lf.sample_rate,
        );
    }
}

fn recomputeHpf(lf: *EraLowFreq) void {
    for (0..lf.channels) |c| {
        if (lf.hpf_order == 1) {
            biquad.era_biquad_first_order_high_pass(&lf.hpf1[c], lf.hpf_freq, lf.sample_rate);
            lf.hpf1[c].reset();
        } else {
            biquad.era_biquad_high_pass(
                &lf.hpf2[c],
                lf.hpf_freq,
                era_lowfreq_butter_q,
                lf.sample_rate,
            );
            lf.hpf2[c].reset();
        }
    }
}

/// 就地处理交错 float32 PCM（对照 C `lowfreq_process`）。
pub fn era_lowfreq_process(lf: *EraLowFreq, pcm: []f32, frames: usize) void {
    if (frames == 0) return;
    if (!lf.enabled) return;

    const ch: usize = lf.channels;
    const hpf_active = lf.hpf_enabled;
    const bass_active = lf.bass_gain_db != 0.0;
    if (!hpf_active and !bass_active) return;

    for (0..ch) |c| {
        const hf: *biquad.EraBiquadState = if (lf.hpf_order == 1) &lf.hpf1[c] else &lf.hpf2[c];
        const bf = &lf.bass[c];
        var i: usize = 0;
        while (i < frames) : (i += 1) {
            var x = pcm[i * ch + c];
            if (hpf_active) x = hf.tick(x);
            if (bass_active) x = bf.tick(x);
            pcm[i * ch + c] = x;
        }
    }
}

/// 统一接口适配（见 `stage.zig`）。
pub fn era_lowfreq_stage(lf: *EraLowFreq) Stage {
    return .{ .ctx = @ptrCast(lf), .vtable = &vtable, .channels = lf.channels };
}

const vtable = Stage.VTable{ .process = processThunk };

fn processThunk(ctx: *anyopaque, pcm: []f32, frames: usize) void {
    const lf: *EraLowFreq = @ptrCast(@alignCast(ctx));
    era_lowfreq_process(lf, pcm, frames);
}

// ---------------------------------------------------------------------------
// 单元测试
// ---------------------------------------------------------------------------

const testing = std.testing;

fn synthSine(buf: []f32, freq: f64, rate: f64) void {
    const w = 2.0 * std.math.pi * freq / rate;
    for (buf, 0..) |*v, i| v.* = @floatCast(@sin(w * @as(f64, @floatFromInt(i))));
}

fn rmsOf(buf: []const f32) f64 {
    var s: f64 = 0.0;
    for (buf) |v| s += @as(f64, v) * @as(f64, v);
    return @sqrt(s / @as(f64, @floatFromInt(buf.len)));
}

test "era_lowfreq: 默认禁用为逐位旁通" {
    const lf = try era_lowfreq_create(testing.allocator, 48000, 2);
    defer era_lowfreq_destroy(lf);

    var buf: [64]f32 = undefined;
    for (&buf, 0..) |*v, i| v.* = @as(f32, @floatFromInt(i % 7)) - 3.0;
    const orig = buf;
    era_lowfreq_process(lf, &buf, 32);
    try testing.expectEqualSlices(f32, &orig, &buf);
}

test "era_lowfreq: HPF 衰减 DC/10Hz，1kHz 近似不变" {
    const lf = try era_lowfreq_create(testing.allocator, 48000, 1);
    defer era_lowfreq_destroy(lf);
    era_lowfreq_set_hpf(lf, 20.0, 2);
    era_lowfreq_set_enabled(lf, true);

    const n = 16384;
    var dc: [n]f32 = undefined;
    for (&dc) |*v| v.* = 1.0;
    era_lowfreq_process(lf, &dc, n);
    try testing.expect(@abs(dc[n - 1]) < 1e-3); // DC 稳态趋 0

    const lf2 = try era_lowfreq_create(testing.allocator, 48000, 1);
    defer era_lowfreq_destroy(lf2);
    era_lowfreq_set_hpf(lf2, 20.0, 2);
    era_lowfreq_set_enabled(lf2, true);

    var tone: [n]f32 = undefined;
    synthSine(&tone, 1000.0, 48000.0);
    era_lowfreq_process(lf2, &tone, n);
    const r = rmsOf(tone[n / 2 ..]);
    try testing.expect(r > 0.65 and r < 0.75); // ≈0.707，未明显衰减
}

test "era_lowfreq: bass shelf 抬升低频；一阶 HPF 亦衰减 DC" {
    const lf = try era_lowfreq_create(testing.allocator, 48000, 1);
    defer era_lowfreq_destroy(lf);
    era_lowfreq_set_bass(lf, 9.0, 100.0);
    era_lowfreq_set_enabled(lf, true);

    const n = 16384;
    var tone: [n]f32 = undefined;
    synthSine(&tone, 50.0, 48000.0);
    era_lowfreq_process(lf, &tone, n);
    try testing.expect(rmsOf(tone[n / 2 ..]) > 1.2); // 低频被抬升

    const lf1 = try era_lowfreq_create(testing.allocator, 48000, 1);
    defer era_lowfreq_destroy(lf1);
    era_lowfreq_set_hpf(lf1, 20.0, 1);
    era_lowfreq_set_enabled(lf1, true);
    var dc: [n]f32 = undefined;
    for (&dc) |*v| v.* = 1.0;
    era_lowfreq_process(lf1, &dc, n);
    try testing.expect(@abs(dc[n - 1]) < 1e-3);
}

test "era_lowfreq: 非法参数（NaN/负数/越界）不产生 NaN/Inf" {
    const lf = try era_lowfreq_create(testing.allocator, 48000, 2);
    defer era_lowfreq_destroy(lf);
    era_lowfreq_set_hpf(lf, std.math.nan(f32), 9);
    era_lowfreq_set_bass(lf, std.math.inf(f32), -5.0);
    era_lowfreq_set_enabled(lf, true);

    const n = 512;
    var buf: [n]f32 = undefined;
    var seed: u32 = 0x33;
    for (&buf) |*v| {
        seed = seed *% 1664525 +% 1013904223;
        v.* = @as(f32, @floatFromInt(seed >> 8)) / 8388608.0 - 1.0;
    }
    era_lowfreq_process(lf, &buf, n / 2);
    for (buf) |v| try testing.expect(std.math.isFinite(v));
}

test "era_lowfreq: stage 派发与直调一致" {
    const a = try era_lowfreq_create(testing.allocator, 48000, 2);
    defer era_lowfreq_destroy(a);
    const b = try era_lowfreq_create(testing.allocator, 48000, 2);
    defer era_lowfreq_destroy(b);
    era_lowfreq_set_hpf(a, 30.0, 2);
    era_lowfreq_set_hpf(b, 30.0, 2);
    era_lowfreq_set_bass(a, 4.0, 120.0);
    era_lowfreq_set_bass(b, 4.0, 120.0);
    era_lowfreq_set_enabled(a, true);
    era_lowfreq_set_enabled(b, true);

    var x: [64]f32 = undefined;
    synthSine(&x, 100.0, 48000.0);
    var y = x;
    era_lowfreq_process(a, &x, 32);
    era_lowfreq_stage(b).process(&y, 32);
    try testing.expectEqualSlices(f32, &x, &y);
}
