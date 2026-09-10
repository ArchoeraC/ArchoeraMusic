// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! 开发对照 dump：解码 .mpc（SV8/SV7）→ s16le 交错，可选与 ffmpeg 参考 PCM 逐样本比对。
//! 用法：zig build-exe kernel/mpc_dump.zig -lc -O ReleaseSafe -femit-bin=./mpcn
//!   ./mpcn <file.mpc> [ref.pcm]
//!   （有 ref.pcm 时打印 corr / max_abs / bit-exact%）

const std = @import("std");
const sv8 = @import("fmt/mpc/sv8.zig");
const sv7 = @import("fmt/mpc/sv7.zig");
const io = @import("io.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    const alloc = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const args = try init.args.toSlice(arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: mpcn <file.mpc> [ref.pcm]\n", .{});
        return error.InvalidArgs;
    }
    const path = args[1];
    const ref_path: ?[]const u8 = if (args.len > 2) args[2] else null;

    var reader = try io.Reader.openPath(path);
    defer reader.deinit();
    const fsize = try reader.size();
    var data = try alloc.alloc(u8, @intCast(fsize));
    defer alloc.free(data);
    var got: usize = 0;
    while (got < data.len) {
        const n = try reader.read(data[got..]);
        if (n == 0) break;
        got += n;
    }

    var planar: [2][1152]i16 = undefined;

    if (data.len >= 4 and std.mem.eql(u8, data[0..4], "MPCK")) {
        var d = try sv8.Decoder8.init(alloc, data);
        defer d.deinit();
        var n: usize = 0;
        var out = std.ArrayList(u8).empty;
        defer out.deinit(alloc);
        while (d.next(&planar)) {
            const ch = d.parsed.cfg.channels;
            const chl: usize = ch;
            var buf: [1152 * 2 * 2]u8 = undefined;
            for (0..1152) |s| {
                for (0..chl) |c| {
                    std.mem.writeInt(i16, buf[(s * chl + c) * 2 ..][0..2], planar[c][s], .little);
                }
            }
            try out.appendSlice(alloc, buf[0 .. 1152 * chl * 2]);
            n += 1;
        }
        std.debug.print("SV8 frames={d} sr={d} ch={d}\n", .{ n, d.parsed.cfg.sample_rate, d.parsed.cfg.channels });
        if (ref_path) |rp| try compare(alloc, out.items, rp);
        try writeAll(out.items);
    } else {
        var d = try sv7.Decoder7.init(alloc, data);
        defer d.deinit();
        var n: usize = 0;
        var out = std.ArrayList(u8).empty;
        defer out.deinit(alloc);
        while (d.next(&planar)) {
            var buf: [1152 * 2 * 2]u8 = undefined;
            for (0..1152) |s| {
                for (0..2) |c| {
                    std.mem.writeInt(i16, buf[(s * 2 + c) * 2 ..][0..2], planar[c][s], .little);
                }
            }
            try out.appendSlice(alloc, buf[0 .. 1152 * 2 * 2]);
            n += 1;
        }
        std.debug.print("SV7 frames={d}\n", .{n});
        if (ref_path) |rp| try compare(alloc, out.items, rp);
        try writeAll(out.items);
    }
}

fn writeAll(bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const n = std.c.write(std.c.STDOUT_FILENO, bytes[written..].ptr, bytes.len - written);
        if (n < 0) return error.WriteFailed;
        written += @intCast(n);
    }
}

fn compare(alloc: std.mem.Allocator, mine: []const u8, ref_path: []const u8) !void {
    var r = try io.Reader.openPath(ref_path);
    defer r.deinit();
    const rsize = try r.size();
    const ref = try alloc.alloc(u8, @intCast(rsize));
    defer alloc.free(ref);
    var got: usize = 0;
    while (got < ref.len) {
        const n = try r.read(ref[got..]);
        if (n == 0) break;
        got += n;
    }
    const n = @min(ref.len, mine.len) / 2;
    var equal: usize = 0;
    var sum_num: f64 = 0;
    var sum_a2: f64 = 0;
    var sum_b2: f64 = 0;
    var maxabs: i64 = 0;
    var first_diff: i64 = -1;
    for (0..n) |i| {
        const g: i16 = std.mem.readInt(i16, ref[i * 2 ..][0..2], .little);
        const m: i16 = std.mem.readInt(i16, mine[i * 2 ..][0..2], .little);
        if (g == m) {
            equal += 1;
        } else {
            const d2 = @abs(@as(i32, g) - @as(i32, m));
            if (d2 > maxabs) maxabs = d2;
            if (first_diff < 0) first_diff = @intCast(i);
        }
        sum_num += @as(f64, g) * @as(f64, m);
        sum_a2 += @as(f64, g) * @as(f64, g);
        sum_b2 += @as(f64, m) * @as(f64, m);
    }
    const corr = if (sum_a2 * sum_b2 > 0) sum_num / @sqrt(sum_a2 * sum_b2) else 1.0;
    std.debug.print("compare n={d} corr={d:.8} max_abs={d} bitexact={d:.4}% first_diff@{d} mine_len={d} ref_len={d}\n", .{
        n, corr, maxabs, 100.0 * @as(f64, @floatFromInt(equal)) / @as(f64, @floatFromInt(n)), first_diff, mine.len, ref.len,
    });
}
