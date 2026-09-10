// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

const std = @import("std");
const silk = @import("fmt/opus/silk.zig");
pub fn main() !void {
    var rsm = silk.ResamplerState{};
    _ = silk.resamplerInit(&rsm, 16000, 48000);
    var out: [1000]i16 = undefined;
    var in16: [320]i16 = undefined;
    @memset(&in16, 0);
    in16[0] = 32767;
    _ = silk.resampler(&rsm, out[0..], in16[0..], 320);
    for (0..40) |i| std.debug.print("out[{d}]={d}\n", .{ i, out[i] });
}
