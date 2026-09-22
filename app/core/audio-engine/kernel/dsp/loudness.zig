// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! 响度归一化（docs/audio-kernel-zig.md §14；方向① 地基）
//!
//! 逐函数移植自 C 壳 `src/loudness.c`。现状 C 实现为**静态增益补偿**
//! （不做实时动态归一化，避免延迟）：扫描模式预计算 gain_db → 应用模式
//! 乘线性增益。本模块保持同语义（EBU R128 集成响度的真正测量属方向①
//! D3/D6 扩张范围，见 `docs/audio-kernel-expansion-plan.md` §2.3）。
//!
//! 对外等价 `loudness_*`，经 `zk_dsp_loudness_*` C ABI 暴露；C 壳优先路由
//! 内核、失败回退 C 实现。命名自有（era_ 前缀）。

const std = @import("std");
const math = @import("dspmath.zig");
const Stage = @import("stage.zig").Stage;

/// 默认目标响度（LUFS），与 C `-14.0f` 一致。
pub const era_loudness_default_target_lufs: f32 = -14.0;

/// 响度归一化实例（不透明于 C 侧 `ZkDspLoudness`）。
pub const EraLoudness = struct {
    allocator: std.mem.Allocator,
    sample_rate: u32,
    channels: u8,
    enabled: bool = false,
    target_lufs: f32 = era_loudness_default_target_lufs,
    gain_db: f32 = 0.0,
    gain_linear: f32 = 1.0,
};

/// 创建（对照 C `loudness_create`；默认禁用、目标 −14 LUFS、增益 0dB）。
pub fn era_loudness_create(
    allocator: std.mem.Allocator,
    sample_rate: u32,
    channels: u8,
) !*EraLoudness {
    if (sample_rate == 0 or channels == 0) return error.InvalidArgument;
    const self = try allocator.create(EraLoudness);
    self.* = .{
        .allocator = allocator,
        .sample_rate = sample_rate,
        .channels = channels,
    };
    return self;
}

/// 销毁（对照 C `loudness_destroy`）。
pub fn era_loudness_destroy(l: *EraLoudness) void {
    const a = l.allocator;
    a.destroy(l);
}

/// 启用/禁用（对照 C `loudness_set_enabled`）。
pub fn era_loudness_set_enabled(l: *EraLoudness, enabled: bool) void {
    l.enabled = enabled;
}

/// 设置目标响度（LUFS）（对照 C `loudness_set_target`）。
pub fn era_loudness_set_target(l: *EraLoudness, target_lufs: f32) void {
    l.target_lufs = target_lufs;
}

/// 设置预计算增益（dB）（对照 C `loudness_set_gain`）。
pub fn era_loudness_set_gain(l: *EraLoudness, gain_db: f32) void {
    l.gain_db = gain_db;
    l.gain_linear = math.ampFromDb(gain_db);
}

/// 就地处理交错 float32 PCM（对照 C `loudness_process`）。
/// `pcm.len == frames * channels`。
pub fn era_loudness_process(l: *EraLoudness, pcm: []f32, frames: usize) void {
    if (frames == 0) return;
    if (!l.enabled) return;
    if (l.gain_linear == 1.0) return;

    const total = frames * @as(usize, l.channels);
    for (pcm[0..total]) |*v| v.* *= l.gain_linear;
}

/// 统一接口适配（见 `stage.zig`）。
pub fn era_loudness_stage(l: *EraLoudness) Stage {
    return .{ .ctx = @ptrCast(l), .vtable = &vtable, .channels = l.channels };
}

const vtable = Stage.VTable{ .process = processThunk };

fn processThunk(ctx: *anyopaque, pcm: []f32, frames: usize) void {
    const l: *EraLoudness = @ptrCast(@alignCast(ctx));
    era_loudness_process(l, pcm, frames);
}

// ---------------------------------------------------------------------------
// 单元测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "era_loudness: 默认禁用为直通；启用后按增益线性放大" {
    const l = try era_loudness_create(testing.allocator, 48000, 2);
    defer era_loudness_destroy(l);

    var pcm = [_]f32{ 0.1, -0.1, 0.2, -0.2 };
    const orig = pcm;
    era_loudness_process(l, &pcm, 2); // 默认禁用
    try testing.expectEqualSlices(f32, &orig, &pcm);

    era_loudness_set_enabled(l, true);
    era_loudness_set_gain(l, 3.0);
    era_loudness_process(l, &pcm, 2);
    const g = math.ampFromDb(3.0);
    try testing.expectApproxEqAbs(0.1 * g, pcm[0], 1e-6);
    try testing.expectApproxEqAbs(-0.2 * g, pcm[3], 1e-6);
}

test "era_loudness: 禁用后还原；gain=0 时逐位直通" {
    const l = try era_loudness_create(testing.allocator, 48000, 1);
    defer era_loudness_destroy(l);

    era_loudness_set_enabled(l, true);
    era_loudness_set_gain(l, 0.0);
    var pcm = [_]f32{ 0.5, -0.5, 1.0 };
    const orig = pcm;
    era_loudness_process(l, &pcm, 3);
    try testing.expectEqualSlices(f32, &orig, &pcm);

    era_loudness_set_enabled(l, false);
    var pcm2 = [_]f32{ 0.5, -0.5, 1.0 };
    era_loudness_process(l, &pcm2, 3);
    try testing.expectEqualSlices(f32, &orig, &pcm2);
}

test "era_loudness: stage 统一接口派发与直调一致" {
    const a = try era_loudness_create(testing.allocator, 48000, 2);
    defer era_loudness_destroy(a);
    const b = try era_loudness_create(testing.allocator, 48000, 2);
    defer era_loudness_destroy(b);
    era_loudness_set_enabled(a, true);
    era_loudness_set_gain(a, 4.0);
    era_loudness_set_enabled(b, true);
    era_loudness_set_gain(b, 4.0);

    var pcm_a = [_]f32{ 0.3, -0.3, 0.4, -0.4 };
    var pcm_b = pcm_a;
    era_loudness_process(a, &pcm_a, 2);
    era_loudness_stage(b).process(&pcm_b, 2);
    try std.testing.expectEqualSlices(f32, &pcm_a, &pcm_b);
}
