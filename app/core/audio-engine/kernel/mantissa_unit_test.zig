// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! 聚合 mantissa.zig 内嵌单元测试（`zig test mantissa_unit_test.zig`）。
//! 独立模块测试入口，原因：`zig test fmt/ac3/mantissa.zig` 因 Zig 0.16
//! 模块路径限制无法向上 import ../aac/bitreader.zig。

test {
    _ = @import("fmt/ac3/mantissa.zig");
}
