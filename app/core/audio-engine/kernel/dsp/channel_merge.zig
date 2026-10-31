// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! 多声道合并（设备只有单侧声道时的兜底）
//!
//! 把交错 PCM 的所有声道按等功率（1/√N）求和为单声道，再复制到每一个
//! 输出声道。用于「设备实际只有左/右一侧发声、立体声内容会漏掉另一侧」的
//! 场景：合并后任意一侧都能听到完整内容。
//!
//! 行为约定：
//!   - 整块默认禁用（逐位旁通）；`set_enabled(true)` 后才处理；
//!   - 单声道输入（channels == 1）为空操作；
//!   - 只做线性混合，不做限幅；调用方应在合并后接限幅器（管线顺序已保证）。
//!
//! 对外经 `zk_dsp_channel_merge_*` C ABI 暴露；C 壳优先路由内核，失败回退
//! 纯 C 实现。命名自有（`era_` 前缀），不照搬上游标识符。

const std = @import("std");
const Stage = @import("stage.zig").Stage;

/// 多声道合并实例（不透明于 C 侧 `ZkDspChannelMerge`）。
pub const EraChannelMerge = struct {
    allocator: std.mem.Allocator,
    channels: u8,
    /// 总开关（默认关 = 逐位旁通）。
    enabled: bool = false,
    /// 等功率合并增益 1/√channels（channels == 1 时为 1）。
    gain: f32,
};

fn mergeGain(channels: u8) f32 {
    if (channels <= 1) return 1.0;
    const n: f32 = @floatFromInt(channels);
    return 1.0 / @sqrt(n);
}

/// 创建多声道合并块（非法参数 / OOM 返回错误）。
pub fn era_channel_merge_create(
    allocator: std.mem.Allocator,
    channels: u8,
) !*EraChannelMerge {
    if (channels == 0) return error.InvalidArgument;
    const self = try allocator.create(EraChannelMerge);
    self.* = .{
        .allocator = allocator,
        .channels = channels,
        .gain = mergeGain(channels),
    };
    return self;
}

/// 销毁（NULL 由 C 侧处理）。
pub fn era_channel_merge_destroy(cm: *EraChannelMerge) void {
    const a = cm.allocator;
    a.destroy(cm);
}

/// 整块启用/禁用。
pub fn era_channel_merge_set_enabled(cm: *EraChannelMerge, enabled: bool) void {
    cm.enabled = enabled;
}

/// 就地合并交错 float32 PCM（对照 C `channel_merge_process`）。
pub fn era_channel_merge_process(cm: *EraChannelMerge, pcm: []f32, frames: usize) void {
    if (!cm.enabled or cm.channels <= 1 or frames == 0) return;

    const ch: usize = cm.channels;
    const gain = cm.gain;
    var i: usize = 0;
    while (i < frames) : (i += 1) {
        const base = i * ch;
        var sum: f32 = 0.0;
        var c: usize = 0;
        while (c < ch) : (c += 1) sum += pcm[base + c];
        const mono = sum * gain;
        c = 0;
        while (c < ch) : (c += 1) pcm[base + c] = mono;
    }
}

/// 统一接口适配（见 `stage.zig`）。
pub fn era_channel_merge_stage(cm: *EraChannelMerge) Stage {
    return .{ .ctx = @ptrCast(cm), .vtable = &vtable, .channels = cm.channels };
}

const vtable = Stage.VTable{ .process = processThunk };

fn processThunk(ctx: *anyopaque, pcm: []f32, frames: usize) void {
    const cm: *EraChannelMerge = @ptrCast(@alignCast(ctx));
    era_channel_merge_process(cm, pcm, frames);
}

// ---------------------------------------------------------------------------
// 单元测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "era_channel_merge: 默认禁用为逐位旁通" {
    const cm = try era_channel_merge_create(testing.allocator, 2);
    defer era_channel_merge_destroy(cm);

    var buf = [_]f32{ 0.25, -0.5, 0.75, -1.0 };
    const orig = buf;
    era_channel_merge_process(cm, &buf, 2);
    try testing.expectEqualSlices(f32, &orig, &buf);
}

test "era_channel_merge: 单声道输入为空操作" {
    const cm = try era_channel_merge_create(testing.allocator, 1);
    defer era_channel_merge_destroy(cm);
    era_channel_merge_set_enabled(cm, true);

    var buf = [_]f32{ 0.25, -0.5, 0.75 };
    const orig = buf;
    era_channel_merge_process(cm, &buf, 3);
    try testing.expectEqualSlices(f32, &orig, &buf);
}

test "era_channel_merge: 立体声等功率合并到两侧" {
    const cm = try era_channel_merge_create(testing.allocator, 2);
    defer era_channel_merge_destroy(cm);
    era_channel_merge_set_enabled(cm, true);

    var buf = [_]f32{ 0.5, 0.1, -0.2, 0.4 };
    era_channel_merge_process(cm, &buf, 2);

    const g: f32 = 1.0 / @sqrt(@as(f32, 2.0));
    const m0 = (0.5 + 0.1) * g;
    const m1 = (-0.2 + 0.4) * g;
    try testing.expectApproxEqAbs(m0, buf[0], 1e-6);
    try testing.expectApproxEqAbs(m0, buf[1], 1e-6);
    try testing.expectApproxEqAbs(m1, buf[2], 1e-6);
    try testing.expectApproxEqAbs(m1, buf[3], 1e-6);
}

test "era_channel_merge: 多声道按 1/√N 合并" {
    const cm = try era_channel_merge_create(testing.allocator, 4);
    defer era_channel_merge_destroy(cm);
    era_channel_merge_set_enabled(cm, true);

    var buf = [_]f32{ 0.1, 0.2, 0.3, 0.4 };
    era_channel_merge_process(cm, &buf, 1);

    const g: f32 = 1.0 / @sqrt(@as(f32, 4.0));
    const m = (0.1 + 0.2 + 0.3 + 0.4) * g;
    for (buf) |v| try testing.expectApproxEqAbs(m, v, 1e-6);
}
