// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! 输出限幅器（docs/audio-kernel-zig.md §14；方向① 地基）
//!
//! 逐函数移植自 C 壳 `src/limiter.c`：软膝压缩（4:1）+ 1.0 硬上限，
//! 阈值默认 −1 dB（留余量）。对外等价 `limiter_*`，经 `zk_dsp_limiter_*`
//! C ABI 暴露；C 壳优先路由内核、失败回退 C 实现。
//!
//! 命名自有（era_ 前缀），不照搬 FFmpeg / SoX 等上游标识符。

const std = @import("std");
const math = @import("dspmath.zig");
const Stage = @import("stage.zig").Stage;

/// 默认阈值（dB），与 C `-1.0f` 一致。
pub const era_limiter_default_threshold_db: f32 = -1.0;

/// 超过阈值部分的压缩比（4:1 → ×0.25），与 C 一致。
const era_limiter_makeup_ratio: f32 = 0.25;

/// 限幅器实例（不透明于 C 侧 `ZkDspLimiter`）。
pub const EraLimiter = struct {
    allocator: std.mem.Allocator,
    sample_rate: u32,
    channels: u8,
    enabled: bool = true,
    threshold_db: f32 = era_limiter_default_threshold_db,
    threshold_linear: f32,
};

/// 创建限幅器（对照 C `limiter_create`；默认启用、阈值 −1 dB）。
pub fn era_limiter_create(
    allocator: std.mem.Allocator,
    sample_rate: u32,
    channels: u8,
) !*EraLimiter {
    if (sample_rate == 0 or channels == 0) return error.InvalidArgument;
    const self = try allocator.create(EraLimiter);
    self.* = .{
        .allocator = allocator,
        .sample_rate = sample_rate,
        .channels = channels,
        .threshold_linear = math.ampFromDb(era_limiter_default_threshold_db),
    };
    return self;
}

/// 销毁（对照 C `limiter_destroy`）。
pub fn era_limiter_destroy(lim: *EraLimiter) void {
    const a = lim.allocator;
    lim.sample_rate = 0; // 显式失效，防误用
    a.destroy(lim);
}

/// 启用/禁用（对照 C `limiter_set_enabled`）。
pub fn era_limiter_set_enabled(lim: *EraLimiter, enabled: bool) void {
    lim.enabled = enabled;
}

/// 设置阈值（dB）（对照 C `limiter_set_threshold`）。
pub fn era_limiter_set_threshold(lim: *EraLimiter, threshold_db: f32) void {
    lim.threshold_db = threshold_db;
    lim.threshold_linear = math.ampFromDb(threshold_db);
}

/// 当前阈值（dB）（对照 C `limiter_get_threshold`）。
pub fn era_limiter_get_threshold(lim: *const EraLimiter) f32 {
    return lim.threshold_db;
}

/// 就地处理交错 float32 PCM（对照 C `limiter_process`）。
/// `pcm.len == frames * channels`。
pub fn era_limiter_process(lim: *EraLimiter, pcm: []f32, frames: usize) void {
    if (frames == 0) return;
    if (!lim.enabled) return;

    const threshold = lim.threshold_linear;
    const total = frames * @as(usize, lim.channels);
    for (pcm[0..total]) |*pv| {
        const x = pv.*;
        const ax = @abs(x);
        if (ax > threshold) {
            const sign: f32 = if (x >= 0.0) 1.0 else -1.0;
            const excess = ax - threshold;
            var compressed = threshold + excess * era_limiter_makeup_ratio;
            if (compressed > 1.0) compressed = 1.0;
            pv.* = sign * compressed;
        }
    }
}

/// 统一接口适配（见 `stage.zig`）。
pub fn era_limiter_stage(lim: *EraLimiter) Stage {
    return .{ .ctx = @ptrCast(lim), .vtable = &vtable, .channels = lim.channels };
}

const vtable = Stage.VTable{ .process = processThunk };

fn processThunk(ctx: *anyopaque, pcm: []f32, frames: usize) void {
    const lim: *EraLimiter = @ptrCast(@alignCast(ctx));
    era_limiter_process(lim, pcm, frames);
}

// ---------------------------------------------------------------------------
// 单元测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "era_limiter: 默认阈值 -1dB，阈值以下逐位不变" {
    const lim = try era_limiter_create(testing.allocator, 48000, 2);
    defer era_limiter_destroy(lim);
    try testing.expectApproxEqAbs(@as(f32, -1.0), era_limiter_get_threshold(lim), 1e-6);

    var pcm = [_]f32{ 0.5, -0.5, 0.3, -0.3 };
    const orig = pcm;
    era_limiter_process(lim, &pcm, 2);
    try testing.expectEqualSlices(f32, &orig, &pcm);
}

test "era_limiter: 超阈值按 4:1 软膝压缩且不超 1.0" {
    const lim = try era_limiter_create(testing.allocator, 48000, 1);
    defer era_limiter_destroy(lim);

    const t = math.ampFromDb(-1.0);
    var pcm = [_]f32{ 2.0, -2.0, 1.5, -1.5 };
    era_limiter_process(lim, &pcm, 4);
    for (pcm) |v| try testing.expect(@abs(v) <= 1.0);
    // 正半轴解析值：t + (2 - t)*0.25
    const expect_pos = @min(t + (2.0 - t) * 0.25, 1.0);
    try testing.expectApproxEqAbs(expect_pos, pcm[0], 1e-6);
    try testing.expectApproxEqAbs(-expect_pos, pcm[1], 1e-6);
}

test "era_limiter: 禁用时逐位直通；重设阈值生效" {
    const lim = try era_limiter_create(testing.allocator, 48000, 1);
    defer era_limiter_destroy(lim);

    era_limiter_set_enabled(lim, false);
    var pcm = [_]f32{ 2.0, -2.0 };
    era_limiter_process(lim, &pcm, 2);
    try testing.expectEqualSlices(f32, &[_]f32{ 2.0, -2.0 }, &pcm);

    era_limiter_set_enabled(lim, true);
    era_limiter_set_threshold(lim, -6.0);
    try testing.expectApproxEqAbs(@as(f32, -6.0), era_limiter_get_threshold(lim), 1e-6);
    var hc = [_]f32{ 0.9, 0.3 };
    era_limiter_process(lim, &hc, 2);
    try testing.expect(hc[0] < 0.9);
    try testing.expectApproxEqAbs(@as(f32, 0.3), hc[1], 1e-6);
}

test "era_limiter: stage 统一接口派发与直调一致" {
    const a = try era_limiter_create(testing.allocator, 48000, 2);
    defer era_limiter_destroy(a);
    const b = try era_limiter_create(testing.allocator, 48000, 2);
    defer era_limiter_destroy(b);

    var pcm_a = [_]f32{ 1.7, -1.7, 0.2, -0.2 };
    var pcm_b = pcm_a;
    era_limiter_process(a, &pcm_a, 2);
    era_limiter_stage(b).process(&pcm_b, 2);
    try testing.expectEqualSlices(f32, &pcm_a, &pcm_b);
}
