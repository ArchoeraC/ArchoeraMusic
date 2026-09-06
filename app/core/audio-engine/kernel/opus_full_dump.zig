// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Opus 完整解码 dump：走 decoder.open → lib.zig VTable（SILK/CELT/HYBRID 全模式）。
//! 输出：s16 交错 PCM 到 stdout（可选 --f32 输出 float32）。

const std = @import("std");
const io = @import("io.zig");
const decoder = @import("decoder.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const args = try init.args.toSlice(gpa);
    if (args.len < 2) return error.InvalidArgs;
    const do_f32 = args.len >= 3 and std.mem.eql(u8, args[2], "--f32");

    var info: decoder.Info = undefined;
    var d = try decoder.open(gpa, args[1], &info);
    defer d.deinit();

    var out: [8192]u8 = undefined;
    var buf: [2048 * 2 * 2]u8 = undefined;
    var n_ch: u8 = 0;
    while (true) {
        const n = try d.read(buf[0..], 2048, &n_ch);
        if (n == 0) break;
        const fb: usize = @as(usize, n_ch) * 2;
        var produced: usize = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            for (0..n_ch) |c| {
                const sample = std.mem.readInt(i16, buf[i * fb + c * 2 ..][0..2], .little);
                const v: f32 = @as(f32, @floatFromInt(sample)) / 32768.0;
                if (do_f32) {
                    std.mem.writeInt(u32, out[produced..][0..4], @bitCast(v), .little);
                    produced += 4;
                } else {
                    std.mem.writeInt(i16, out[produced..][0..2], sample, .little);
                    produced += 2;
                }
            }
        }
        var written: usize = 0;
        while (written < produced) {
            const w = std.c.write(std.c.STDOUT_FILENO, out[written..].ptr, produced - written);
            if (w < 0) return error.WriteFailed;
            written += @intCast(w);
        }
    }
}
