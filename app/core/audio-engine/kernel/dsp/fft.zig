// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! FFT / 频谱分析——移植计划（本轮仅接口占位）
//!
//! 现状：C 壳 `src/fft.c`（自实现 Cooley-Tukey 基 2 + 窗 + 平滑 + 峰值 +
//! 节拍检测 + 多声道下混）。Dart 经 `libfft.so` 直接加载 `fft_*` C 符号
//! （`app/lib/services/fft_bindings.dart`）。
//!
//! **硬约束（P5）**：`libfft.so` 的 Dart ABI 零改动——`fft_create` /
//! `fft_set_enabled` / `fft_process_multi` / `fft_get_spectrum_norm_stereo`
//! 等导出名、结构语义、返回约定全部不变。移植只能「导出名不变、内部实现
//! 换 Zig」，且必须逐位对齐。
//!
//! 移植计划（下一步）：
//!   1. 新建 `kernel/dsp/fft_core.zig`：纯计算内核（位反转表 / 旋转因子表 /
//!      蝶形 / 幅度 / 平滑 / 峰值 / 下混），无 C ABI、可独立单测；
//!   2. 新建 `kernel/dsp/fft_abi.zig`：以 `export fn` 复刻 `fft_*` C ABI
//!      （`callconv(.c)`），链接为 `libfft.so` 替换 `src/fft.c`；
//!   3. 对照 `tests/test_fft.c` 黄金断言 + 与 C 实现逐块对拍（谱幅度
//!      corr ≥ 0.999，归一化谱 ±1 LSB）；
//!   4. `fft_bindings.dart` 不动，`EnginePaths.libfftPath` 不动。
//!
//! 本轮**不导出任何符号、不改 `src/fft.c`**，避免触碰 ABI。

const std = @import("std");

/// 移植计划锚点（编译期常量，供后续实现与测试引用）。
pub const Plan = struct {
    /// 目标 C 源（过渡期保留为回退）。
    pub const c_source = "src/fft.c";
    /// Dart 侧绑定（零改动）。
    pub const dart_binding = "app/lib/services/fft_bindings.dart";
    /// 必须逐名复刻的导出（libfft.so ABI）。
    pub const abi_exports = [_][]const u8{
        "fft_create",
        "fft_destroy",
        "fft_set_enabled",
        "fft_process",
        "fft_process_stereo",
        "fft_process_multi",
        "fft_process_frame",
        "fft_get_spectrum",
        "fft_get_spectrum_stereo",
        "fft_get_spectrum_db",
        "fft_get_spectrum_db_stereo",
        "fft_get_spectrum_norm_stereo",
        "fft_get_peak_spectrum",
        "fft_get_peak_spectrum_stereo",
        "fft_reset_peak",
        "fft_set_smoothing",
        "fft_set_peak_decay",
        "fft_get_size",
        "fft_get_sample_rate",
        "fft_get_processed_seconds",
        "fft_take_beat",
        "fft_take_beat_strength",
        "fft_set_frame_cb",
    };
};

test "fft placeholder: ABI 清单非空且含关键导出" {
    try std.testing.expect(Plan.abi_exports.len > 0);
    try std.testing.expectEqualStrings("fft_create", Plan.abi_exports[0]);
    try std.testing.expectEqualStrings(
        "fft_get_spectrum_norm_stereo",
        Plan.abi_exports[11],
    );
}
