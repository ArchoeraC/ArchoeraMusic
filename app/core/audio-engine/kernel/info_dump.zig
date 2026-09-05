//! Info 审查工具：经 decoder.open（probe → 工厂分发）打印 Info.duration_us /
//! duration_known 与基本流信息；不写 PCM。用于 duration 覆盖审查。
//!
//! 用法：zig build-exe kernel/info_dump.zig -lc -O ReleaseSafe -femit-bin=./info_dump
//!   ./info_dump <file> [<file>...]

const std = @import("std");
const decoder = @import("decoder.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const args = try init.args.toSlice(arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: info_dump <file> [...]\n", .{});
        return error.InvalidArgs;
    }

    for (args[1..]) |path| {
        var info: decoder.Info = undefined;
        var dec = decoder.open(gpa, path, &info) catch |e| {
            std.debug.print("{s}: OPEN-ERR {s}\n", .{ path, @errorName(e) });
            continue;
        };
        dec.deinit();
        const known = switch (info.duration_known) {
            .exact => "exact",
            .estimate => "estimate",
            .unknown => "unknown",
        };
        const sec: f64 = @as(f64, @floatFromInt(info.duration_us)) / 1_000_000.0;
        std.debug.print("{s}: fmt={s} codec={s} sr={d} ch={d} bps={d} duration_us={d} ({d:.6}s) known={s}\n", .{
            path, info.format_name, info.codec_name, info.sample_rate, info.channels,
            info.bits_per_sample, info.duration_us, sec, known,
        });
    }
}
