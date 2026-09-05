//! Speex 解码 dump/对拍工具：解码 .spx → s16le 写 stdout，stderr 打印 Info 摘要。
//!
//! 用法（fmt/spx 内文件不能作独立根上溯 import，须以 kernel/ 为模块根构建，
//! 例如经副本树根转发：`pub const main = @import("kernel/fmt/spx/dump.zig").main;`）：
//!   zig build-exe dumproot.zig -O ReleaseSafe -lc -femit-bin=dump
//!   ./dump <file.spx> > mine.s16
//! 与 `ffmpeg -i <file.spx> -f s16le ref.s16` 逐字节比对即完成验收。

const std = @import("std");
const io = @import("../../io.zig");
const decoder = @import("../../decoder.zig");
const spx = @import("lib.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const args = try init.args.toSlice(arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: dump <file.spx> > out.s16\n", .{});
        return error.InvalidArgs;
    }

    var reader = try io.Reader.openPath(args[1]);
    errdefer reader.deinit();

    var info: decoder.Info = undefined;
    var dec = try spx.open(gpa, &reader, &info);
    defer dec.deinit();

    const known = switch (info.duration_known) {
        .exact => "exact",
        .estimate => "estimate",
        .unknown => "unknown",
    };
    std.debug.print("codec={s} fmt={s} sr={d} ch={d} bits={d} dur_us={d} known={s}\n", .{
        info.codec_name, info.format_name, info.sample_rate,
        info.channels,   info.bits_per_sample, info.duration_us, known,
    });

    const frame_bytes = @as(usize, info.channels) * 2;
    var buf: [8192]u8 = undefined;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var ch: u8 = 0;
    while (true) {
        const n = try dec.read(&buf, buf.len / frame_bytes, &ch);
        if (n == 0) break;
        try out.appendSlice(gpa, buf[0 .. n * frame_bytes]);
    }
    std.debug.print("-- dumped {d} bytes ({d} samples x {d} ch)\n", .{
        out.items.len, out.items.len / frame_bytes, info.channels,
    });

    var written: usize = 0;
    while (written < out.items.len) {
        const n = std.c.write(std.c.STDOUT_FILENO, out.items[written..].ptr, out.items.len - written);
        if (n < 0) return error.WriteFailed;
        written += @intCast(n);
    }
}
