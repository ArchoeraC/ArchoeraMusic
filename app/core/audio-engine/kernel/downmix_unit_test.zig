//! 聚合 downmix.zig 内嵌单元测试（`zig test downmix_unit_test.zig`）。
//! 独立模块测试入口，原因：`zig test fmt/ac3/downmix.zig` 因 Zig 0.16
//! 模块路径限制无法向上 import ../aac/bitreader.zig。

test {
    _ = @import("fmt/ac3/downmix.zig");
}
