// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

const std = @import("std");
const decoder = @import("decoder.zig");
extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, nmemb: usize, f: *anyopaque) usize;
pub fn main(_: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    if (args.len < 3) return;
    var info: decoder.Info = undefined;
    var dc = try decoder.open(gpa, args[1], &info);
    defer dc.deinit();
    var buf: [16384]u8 = undefined;
    var ch: u8 = 0;
    var o = std.ArrayList(u8).empty;
    defer o.deinit(gpa);
    var tot: usize = 0;
    var reads: usize = 0;
    while (true) {
        const n = dc.read(&buf, 4096, &ch) catch |e| { std.debug.print("read err {s} tot={d}\n", .{@errorName(e), tot}); break; };
        if (n == 0) break;
        tot += n;
        reads += 1;
        if (reads > 1000) { std.debug.print("LIMIT\n", .{}); break; }
        try o.appendSlice(gpa, buf[0 .. n * ch * 2]);
    }
    const f = fopen(args[2], "wb");
    if (f) |fp| _ = fwrite(o.items.ptr, 1, o.items.len, fp);
    std.debug.print("samples={d} bytes={d}\n", .{ tot, o.items.len });
}
