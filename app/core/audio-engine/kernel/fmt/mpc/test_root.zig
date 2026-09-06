// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! fmt/mpc 独立测试根（不含 kernel 依赖，供快速单测）：
//!   zig test kernel/fmt/mpc/test_root.zig
//! 聚合回归仍走 `zig build test`（kernel.zig → lib.zig）。

test {
    _ = @import("tables.zig");
    _ = @import("vlc.zig");
    _ = @import("synth.zig");
    _ = @import("sv7.zig");
    _ = @import("sv8.zig");
}
