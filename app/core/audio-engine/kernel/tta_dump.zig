// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! 开发对照 dump：解码 .tta → 原生位深交错 PCM，可选与 ffmpeg 参考 PCM 逐样本比对。
//! 用法：zig build-exe kernel/tta_dump.zig -lc -O ReleaseSafe -femit-bin=./tta_dump
//!   ./tta_dump <file.tta> [ref.pcm]
//!   （有 ref.pcm 时打印 corr / max_abs / bit-exact%）

const std = @import("std");
const io = @import("io.zig");
const decoder = @import("decoder.zig");
const tta = @import("fmt/tta/lib.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    const alloc = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const args = try init.args.toSlice(arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: tta_dump <file.tta> [ref.pcm]\n", .{});
        return error.InvalidArgs;
    }
    const path = args[1];
    const ref_path: ?[]const u8 = if (args.len > 2) args[2] else null;

    var reader = try io.Reader.openPath(path);
    defer reader.deinit();
    var info: decoder.Info = undefined;
    var d = try tta.open(alloc, &reader, &info);
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
    if (ref_path) |rp| try compare(alloc, out.items, info.bits_per_sample, rp);
    try writeAll(out.items);
}

fn writeAll(bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const n = std.c.write(std.c.STDOUT_FILENO, bytes[written..].ptr, bytes.len - written);
        if (n < 0) return error.WriteFailed;
        written += @intCast(n);
    }
}

fn compare(alloc: std.mem.Allocator, mine: []const u8, bits: u8, ref_path: []const u8) !void {
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
    const bytes_per: usize = bits / 8;
    const n = @min(ref.len, mine.len) / bytes_per;
    var equal: usize = 0;
    var sum_num: f64 = 0;
    var sum_a2: f64 = 0;
    var sum_b2: f64 = 0;
    var maxabs: i64 = 0;
    var first_diff: i64 = -1;
    for (0..n) |i| {
        const g = readSample(ref, i, bytes_per);
        const m = readSample(mine, i, bytes_per);
        if (g == m) {
            equal += 1;
        } else {
            const diff = @as(i64, g) - @as(i64, m);
            const ad = if (diff < 0) -diff else diff;
            if (ad > maxabs) maxabs = ad;
            if (first_diff < 0) first_diff = @intCast(i);
        }
        const gv = g;
        const mv = m;
        sum_num += @as(f64, @floatFromInt(gv)) * @as(f64, @floatFromInt(mv));
        sum_a2 += @as(f64, @floatFromInt(gv)) * @as(f64, @floatFromInt(gv));
        sum_b2 += @as(f64, @floatFromInt(mv)) * @as(f64, @floatFromInt(mv));
    }
    const corr = if (sum_a2 * sum_b2 > 0) sum_num / @sqrt(sum_a2 * sum_b2) else 1.0;
    std.debug.print("compare n={d} corr={d:.8} max_abs={d} bitexact={d:.4}% first_diff@{d} mine_len={d} ref_len={d}\n", .{
        n, corr, maxabs, 100.0 * @as(f64, @floatFromInt(equal)) / @as(f64, @floatFromInt(n)), first_diff, mine.len, ref.len,
    });
}

fn readSample(buf: []const u8, idx: usize, bytes_per: usize) i64 {
    const off = idx * bytes_per;
    if (bytes_per == 1) return buf[off];
    if (bytes_per == 2) return std.mem.readInt(i16, buf[off..][0..2], .little);
    return std.mem.readInt(i32, buf[off..][0..4], .little);
}
