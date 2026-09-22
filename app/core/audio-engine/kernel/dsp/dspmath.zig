// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! DSP 共享数学工具（docs/audio-kernel-zig.md §14，方向① 地基）
//!
//! 关键纪律：**与 C 实现位级对齐**。C 壳的 `equalizer.c` / `limiter.c` /
//! `loudness.c` 经 `powf` / `sinf` / `cosf`（单精度 libm）计算系数；本模块
//! 同样直接声明并调用宿主 libm 的同名符号，避免 Zig compiler_rt 自带实现
//! 在个别输入上差 1 ulp（对照 `kernel/fmt/spx/decode.zig` 的 cosf 处理）。
//!
//! 命名自有：`era_` 前缀 / 本文件自有符号，不照搬 FFmpeg / SoX 等上游标识符。

const std = @import("std");

/// 宿主 libm 单精度函数（与 C 壳所链 libm 同一实现）。
pub extern fn powf(x: f32, y: f32) f32;
pub extern fn sinf(x: f32) f32;
pub extern fn cosf(x: f32) f32;

/// dB → 幅度线性增益（20·log10）：`powf(10, db/20)`。
/// 与 C `powf(10.0f, db / 20.0f)` 同库同式。
pub inline fn ampFromDb(db: f32) f32 {
    return powf(10.0, db / 20.0);
}

/// dB → 滤波器振幅系数（40·log10）：`powf(10, db/40)`。
/// 与 C `powf(10.0f, gain_db / 40.0f)` 同库同式。
pub inline fn gainFromDb(db: f32) f32 {
    return powf(10.0, db / 40.0);
}

test "dspmath: ampFromDb 与增益互逆（0dB→1，±20dB→×10/÷10）" {
    try std.testing.expectEqual(@as(f32, 1.0), ampFromDb(0.0));
    try std.testing.expectApproxEqRel(@as(f32, 10.0), ampFromDb(20.0), 1e-6);
    try std.testing.expectApproxEqRel(@as(f32, 0.1), ampFromDb(-20.0), 1e-6);
    // 与 C 同式：gainFromDb(0)=1
    try std.testing.expectEqual(@as(f32, 1.0), gainFromDb(0.0));
}
