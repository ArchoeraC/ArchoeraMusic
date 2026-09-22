// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! DSP 地基（docs/audio-kernel-zig.md §14；`audio-kernel-expansion-plan.md`
//! 方向①「可听频段 DSP」地基：DSP 下沉 Zig）
//!
//! 本模块是内核 DSP 的聚合入口与统一接口所在地：
//!   - `stage.zig`    统一处理块接口（`Stage` vtable）
//!   - `dspmath.zig`  共享数学（与 C 同库 libm，位级对齐优先）
//!   - `eq.zig`       10 段 Biquad 均衡器（`era_eq_*`）
//!   - `limiter.zig`  输出限幅器（`era_limiter_*`）
//!   - `loudness.zig` 响度归一化（`era_loudness_*`）
//!   - `fft.zig` / `resampler.zig` / `tempo.zig`  移植计划占位（未导出）
//!
//! 已移植块经 `kernel/kernel.zig` 的 `zk_dsp_*` C ABI 暴露给 C 壳；
//! 命名自有（`era_` 前缀），不照搬 FFmpeg / SoX / 上游标识符。

const std = @import("std");

pub const stage = @import("stage.zig");
pub const Stage = stage.Stage;
pub const math = @import("dspmath.zig");
pub const eq = @import("eq.zig");
pub const limiter = @import("limiter.zig");
pub const loudness = @import("loudness.zig");

/// 未移植模块的接口占位与移植计划（本轮不导出 C ABI）。
pub const fft = @import("fft.zig");
pub const resampler = @import("resampler.zig");
pub const tempo = @import("tempo.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("stage.zig");
    _ = @import("dspmath.zig");
    _ = @import("eq.zig");
    _ = @import("limiter.zig");
    _ = @import("loudness.zig");
    _ = @import("fft.zig");
    _ = @import("resampler.zig");
    _ = @import("tempo.zig");
}
