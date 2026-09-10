// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

const std = @import("std");
pub fn main() !void {
    const tmp: f32 = @bitCast(@as(u32, 0x44a64b10));
    const sig = (1.0 / 32768.0) * tmp;
    const prod = sig * 8388608.0;
    const r: i32 = @intFromFloat(@round(prod));
    std.debug.print("tmp={x:0>8} sig={x:0>8} prod={x:0>8} r={d} prod_f={d:.9}\n", .{
        @as(u32, @bitCast(tmp)), @as(u32, @bitCast(sig)), @as(u32, @bitCast(prod)), r, prod,
    });
}
