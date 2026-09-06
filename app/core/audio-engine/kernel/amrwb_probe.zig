// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! AMR-WB 帧扫描工具（阶段一：mode 序列 / 帧数 / 时长）
//!
//! 用法：zig build-exe kernel/amrwb_probe.zig -lc -O ReleaseSafe -femit-bin=./amrwb_probe
//!   ./amrwb_probe <file.awb>          # raw `#!AMR-WB` 或 3gp/mp4 单轨
//!   ./amrwb_probe <file.awb> -all     # 打印完整 mode 序列
//!
//! 每帧 20ms @16kHz；mode 0..8 = 6k60..23k85，9 = SID，15 = NO_DATA。

const std = @import("std");
const io = @import("io.zig");
const amrwb = @import("fmt/amrwb/lib.zig");

fn readAll(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var reader = try io.Reader.openPath(path);
    defer reader.deinit();
    const sz = try reader.size();
    const buf = try allocator.alloc(u8, @intCast(sz));
    errdefer allocator.free(buf);
    var got: usize = 0;
    while (got < buf.len) {
        const n = try reader.read(buf[got..]);
        if (n == 0) break;
        got += n;
    }
    return buf[0..got];
}

const mode_names = [_][]const u8{ "6k60", "8k85", "12k65", "14k25", "15k85", "18k25", "19k85", "23k05", "23k85", "SID", "r10", "r11", "r12", "r13", "SP-LOST", "NO-DATA" };

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const args = try init.args.toSlice(arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: amrwb_probe <file.awb> [-all]\n", .{});
        return error.InvalidArgs;
    }
    const all = args.len >= 3 and std.mem.eql(u8, args[2], "-all");
    const data = try readAll(gpa, args[1]);

    var scanner: amrwb.FrameScanner = undefined;
    var container: []const u8 = "raw-no-header";
    if (data.len >= 9 and std.mem.eql(u8, data[0..9], "#!AMR-WB\n")) {
        scanner = amrwb.FrameScanner.init(data);
        container = "raw";
    } else if (amrwb.findMdat(data)) |m| {
        scanner = amrwb.FrameScanner.initRange(data, m.start, m.end);
        container = "3gp/mp4(mdat)";
    } else {
        scanner = amrwb.FrameScanner.init(data);
    }

    var counts: [16]usize = [_]usize{0} ** 16;
    var seq = std.ArrayList(u8).empty;
    defer seq.deinit(gpa);
    var n: usize = 0;
    while (scanner.next()) |fr| {
        counts[fr.mode] += 1;
        if (all or n < 64) try seq.append(gpa, @intCast(fr.mode));
        n += 1;
    }

    std.debug.print("container={s}\n", .{container});
    std.debug.print("frames={d}\n", .{n});
    std.debug.print("duration_ms={d}\n", .{n * 20});
    std.debug.print("duration_us={d}\n", .{n * 20_000});
    std.debug.print("modes:", .{});
    for (0..16) |m| {
        if (counts[m] != 0) std.debug.print(" {s}({d})", .{ mode_names[m], counts[m] });
    }
    std.debug.print("\n", .{});

    if (all or n <= 64) {
        std.debug.print("seq=", .{});
        for (seq.items, 0..) |m, i| {
            if (i != 0) std.debug.print(",", .{});
            std.debug.print("{s}", .{mode_names[m]});
        }
        std.debug.print("\n", .{});
    }
}
