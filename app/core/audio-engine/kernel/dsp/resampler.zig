// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! 重采样器——移植计划（本轮仅接口占位）
//!
//! 现状：C 壳 `src/resampler.c` 基于 FFmpeg `libswresample`。这是内核
//! 「去 FFmpeg 依赖」的最后几个模块之一，但**不能一次替换**——swr 的
//! dither/延迟/相位语义需要自研重采样核 + 逐块对拍。
//!
//! 移植计划（下一步）：
//!   1. 在 `kernel/dsp/resampler.zig` 实现整数比/任意比采样率转换核
//!      （候选：多相 FIR + 有理近似，或 sinc 窗插值），纯计算、可单测；
//!   2. 判定是否引入外部实现：须走 `audio-kernel-zig.md` §3.3「自研 vs
//!      引入」裁决并登记 `THIRD-PARTY-LICENSES.md`；
//!   3. 与 `libswresample` 对拍：`|corr| ≥ 0.999` 且 ±≤1 LSB（有损门禁，
//!      `decode-optimization.md` §4.2）；延迟（latency）语义须对齐，否则
//!      位置事件/seek 会漂移；
//!   4. C 壳 `resampler.c` 保留为回退（编译期/运行期），逐平台验收后移除。
//!
//! 本轮**不改 `src/resampler.c`、不新增 C ABI**。

const std = @import("std");

/// 移植计划锚点（编译期常量，供后续实现与测试引用）。
pub const Plan = struct {
    pub const c_source = "src/resampler.c";
    /// 现状依赖：FFmpeg libswresample（目标：去依赖）。
    pub const current_backend = "libswresample";
    /// 验收门禁（有损）：相关系数与样本误差界。
    pub const corr_min = 0.999;
    pub const max_sample_error_lsb = 1;
    /// 候选自研路线。
    pub const candidate_kernels = [_][]const u8{
        "polyphase_fir",
        "wsinc_interpolate",
        "integer_ratio_decimator",
    };
};

test "resampler placeholder: 门禁常量合理" {
    try std.testing.expect(Plan.corr_min >= 0.999);
    try std.testing.expectEqual(@as(usize, 1), Plan.max_sample_error_lsb);
    try std.testing.expect(Plan.candidate_kernels.len > 0);
}
