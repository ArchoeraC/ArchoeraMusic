// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! 变速变调——移植计划（本轮仅接口占位）
//!
//! 现状：C 壳 `src/tempo.c` 经 FFI 调 Rust `tempo-rs`（signalsmith-stretch，
//! `app/core/audio-engine/tempo-rs/`）静态库 `audio_tempo`。这是一段**有状态、
//! 块间重叠、相位声码器**，移植风险与工作量最大，故排在最后。
//!
//! 移植计划（下一步）：
//!   1. 先冻结 C/Rust 语义：`speed ∈ [0.5, 2.0]`、`pitch_semitones ∈ [-12, 12]`、
//!      `pitch_sync` 变速保调；输出样本数可变（非 1:1），调用方按容量取；
//!   2. `kernel/dsp/tempo.zig` 实现自研相位声码器/WSOLA 核（纯计算、可单测），
//!      或经 §3.3 裁决引入（signalsmith-stretch 为 MIT，需登记许可）；
//!   3. 对拍：变速后与 Rust 实现 `|corr| ≥ 0.999` 且 ±≤1 LSB 难以严格成立
//!      （相位声码器非逐样本确定），改为**感知门禁**：A/B 听感 + 频谱包络
//!      误差界，并在文档中显式声明该例外；
//!   4. C 壳 `tempo.c` 保留回退；`HAS_TEMPO` 门控不变。
//!
//! 本轮**不改 `src/tempo.c`、不改 `tempo-rs`**。

const std = @import("std");

/// 移植计划锚点（编译期常量，供后续实现与测试引用）。
pub const Plan = struct {
    pub const c_source = "src/tempo.c";
    /// 现状依赖：Rust staticlib `audio_tempo`（signalsmith-stretch）。
    pub const current_backend = "tempo-rs/signalsmith-stretch";
    pub const speed_min = 0.5;
    pub const speed_max = 2.0;
    pub const pitch_min_semitones = -12.0;
    pub const pitch_max_semitones = 12.0;
    /// 相位声码器非逐样本确定，验收以感知/包络门禁为主（见文件头）。
    pub const sample_exact_gate = false;
};

test "tempo placeholder: 参数域与 C 头一致" {
    try std.testing.expectEqual(@as(f64, 0.5), Plan.speed_min);
    try std.testing.expectEqual(@as(f64, 2.0), Plan.speed_max);
    try std.testing.expect(!Plan.sample_exact_gate);
}
