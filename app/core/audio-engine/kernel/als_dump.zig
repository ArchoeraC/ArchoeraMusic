// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! 开发对照 dump：解码 .mp4/.m4a 内 MPEG-4 ALS（mp4als）轨 → s16le，
//! 可选与 ffmpeg 参考 PCM（`ffmpeg -i x.mp4 -f s16le -`）逐字节比对。
//! 用法：zig build-exe kernel/als_dump.zig -lc -O ReleaseSafe -femit-bin=./als_dump
//!   ./als_dump <file.mp4> [ref.pcm]

const std = @import("std");
const io = @import("io.zig");
const decoder = @import("decoder.zig");
const m4a = @import("fmt/m4a.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    const alloc = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try init.args.toSlice(a);
    if (args.len < 2) {
        std.debug.print("usage: als_dump <file.mp4> [ref.pcm]\n", .{});
        return error.InvalidArgs;
    }
    const path = args[1];
    const ref_path: ?[]const u8 = if (args.len > 2) args[2] else null;

    var reader = try io.Reader.openPath(path);
    defer reader.deinit();
    var info: decoder.Info = undefined;
    var d = m4a.open(alloc, &reader, &info) catch |e| {
        std.debug.print("open error: {s}（>255 声道等超引擎管道样本回退系统 ffmpeg）\n", .{@errorName(e)});
        return e;
    };
    defer d.deinit();
    std.debug.print("sr={d} ch={d} bps={d} codec={s} fmt={s} dur_us={d}\n", .{ info.sample_rate, info.channels, info.bits_per_sample, info.codec_name, info.format_name, info.duration_us });

    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    var buf: [65536]u8 = undefined;
    while (true) {
        var ch: u8 = 0;
        const n = try d.read(&buf, 4096, &ch);
        if (n == 0) break;
        const bytes = n * @as(usize, ch) * (info.bits_per_sample / 8);
        try out.appendSlice(alloc, buf[0..bytes]);
    }
    std.debug.print("decoded bytes={d} samples/frame={d}\n", .{ out.items.len, out.items.len / (@as(usize, info.channels) * info.bits_per_sample / 8) });

    if (ref_path) |rp| {
        var rr = try io.Reader.openPath(rp);
        defer rr.deinit();
        const rsize = try rr.size();
        const ref = try a.alloc(u8, @intCast(rsize));
        var got: usize = 0;
        while (got < ref.len) {
            const m = try rr.read(ref[got..]);
            if (m == 0) break;
            got += m;
        }
        const n = @min(out.items.len, ref.len);
        var eq: usize = 0;
        var first_mismatch: usize = 0;
        var has_mismatch = false;
        for (0..n) |i| {
            if (out.items[i] == ref[i]) {
                eq += 1;
            } else if (!has_mismatch) {
                has_mismatch = true;
                first_mismatch = i;
            }
        }
        std.debug.print("compare: mine={d} ref={d} equal {d}/{d} = {d:.4}% (first mism @ {d})\n", .{
            out.items.len, ref.len, eq, n, 100.0 * @as(f64, @floatFromInt(eq)) / @as(f64, @floatFromInt(n)), first_mismatch,
        });
    }
}
