// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! DSP 处理块的**统一接口**（docs/audio-kernel-zig.md §14，方向① 地基）
//!
//! 每个处理块（EQ / 限幅 / 响度）自持状态与声道布局，经 `Stage` 暴露单一
//! 就地处理入口（交错 float32 帧）。后续方向① 新处理块（参数化 EQ / 次声
//! 高通 / DRC / crossfeed / M-S / 等响度）同样实现本接口，即可被管线按序
//! 串联，无需改动调用方。
//!
//! 约定：
//!   - `pcm.len == frames * channels`（交错 float32），就地修改；
//!   - `frames == 0` 或未启用时为空操作；
//!   - 块内不分配内存（分配只发生在 create/set 路径）。

const std = @import("std");

/// 单个 DSP 处理块的类型擦除句柄。
pub const Stage = struct {
    ctx: *anyopaque,
    vtable: *const VTable,
    channels: u8,

    pub const VTable = struct {
        process: *const fn (ctx: *anyopaque, pcm: []f32, frames: usize) void,
    };

    /// 就地处理交错 float32 PCM（`pcm.len == frames * channels`）。
    pub fn process(self: Stage, pcm: []f32, frames: usize) void {
        self.vtable.process(self.ctx, pcm, frames);
    }
};

/// 测试用直通块（验证统一接口可被任意块实现）。
pub const Passthrough = struct {
    channels: u8,

    fn processThunk(ctx: *anyopaque, pcm: []f32, frames: usize) void {
        _ = ctx;
        _ = pcm;
        _ = frames;
    }

    const vtable = Stage.VTable{ .process = processThunk };

    pub fn stage(self: *Passthrough) Stage {
        return .{ .ctx = @ptrCast(self), .vtable = &vtable, .channels = self.channels };
    }
};

test "stage: 统一接口可经 vtable 派发" {
    var p = Passthrough{ .channels = 2 };
    const s = p.stage();
    var buf = [_]f32{ 1.0, -1.0, 0.5, -0.5 };
    s.process(&buf, 2);
    try std.testing.expectEqual(@as(u8, 2), s.channels);
    try std.testing.expectEqual(@as(f32, 1.0), buf[0]);
}
