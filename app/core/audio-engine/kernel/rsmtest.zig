// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const silk = @import("fmt/opus/silk.zig");
pub fn main() !void {
    var rsm = silk.ResamplerState{};
    _ = silk.resamplerInit(&rsm, 16000, 48000);
    var in16: [320]i16 = undefined;
    var out: [960]i16 = undefined;
    for (0..3) |frame| {
        for (0..320) |i| in16[i] = @intCast((i*2 + @as(usize, frame) * 5) & 0x7FFF);
        _ = silk.resampler(&rsm, out[0..], in16[0..], 320);
        std.debug.print("F{d}:", .{frame});
        var i: usize = 0;
        while (i < 960) : (i += 8) std.debug.print(" {d}", .{out[i]});
        std.debug.print("\n", .{});
    }
}
