// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

const std = @import("std");
const decoder = @import("decoder.zig");
extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, nmemb: usize, f: *anyopaque) usize;
pub fn main(init: std.process.Init.Minimal) !void {
    _ = init;
    const gpa = std.heap.page_allocator;
    var info: decoder.Info = undefined;
    var dc = try decoder.open(gpa, "/tmp/eac3_48k.eac3", &info);
    defer dc.deinit();
    std.debug.print("sr={d} ch={d}\n", .{ info.sample_rate, info.channels });
    var buf: [16384]u8 = undefined;
    var ch: u8 = 0;
    var o = std.ArrayList(u8).empty;
    defer o.deinit(gpa);
    var total: usize = 0;
    while (true) {
        const n = dc.read(&buf, 4096, &ch) catch |e| { std.debug.print("read err {s} total={d}\n", .{@errorName(e), total}); break; };
        if (n == 0) break;
        total += n;
        try o.appendSlice(gpa, buf[0 .. n * ch * 2]);
    }
    const f = fopen("/tmp/eac3_48k_mine.pcm", "wb");
    if (f) |fp| _ = fwrite(o.items.ptr, 1, o.items.len, fp);
    std.debug.print("samples={d} ch={d}\n", .{ total, ch });
}
