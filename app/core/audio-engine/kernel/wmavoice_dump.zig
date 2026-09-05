//! WMA Voice 解码器 f32/s16 对照导出工具（复用 fmt/wma/wmavoice/lib.zig）。
//!
//! 用法：zig build-exe kernel/wmavoice_dump.zig -O ReleaseSafe -femit-bin=./wmavoice_dump
//!   ./wmavoice_dump <file.wma> > out.f32
//!   ./wmavoice_dump <file.wma> -s16 > out.s16
//! 输出 = 解码器内部 float（mono 顺序=ffmpeg `-f f32le`）或 clip(round(x*32768)) s16。

const std = @import("std");
const asf = @import("fmt/wma/asf.zig");
const wmavoice = @import("fmt/wma/wmavoice/lib.zig");
const io = @import("io.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const args = try init.args.toSlice(arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: wmavoice_dump <file.wma> [-s16]\n", .{});
        return error.InvalidArgs;
    }
    var want_s16 = false;
    if (args.len >= 3 and std.mem.eql(u8, args[2], "-s16")) want_s16 = true;

    var reader = try io.Reader.openPath(args[1]);
    defer reader.deinit();
    const sz = try reader.size();
    const file_data = try arena.allocator().alloc(u8, @intCast(sz));
    var got: usize = 0;
    while (got < file_data.len) {
        const n = try reader.read(file_data[got..]);
        if (n == 0) break;
        got += n;
    }

    var hdr = try asf.parseHeader(file_data);
    const flt = try wmavoice.decodeF32(arena.allocator(), file_data[0..got], &hdr);
    std.debug.print("-- wmavoice samples={d} sr={d}\n", .{ flt.len, hdr.audio.?.sample_rate });

    var out = std.ArrayList(u8).empty;
    defer out.deinit(arena.allocator());
    if (want_s16) {
        const s16 = try wmavoice.quantize(arena.allocator(), flt);
        defer arena.allocator().free(s16);
        const bytes = std.mem.sliceAsBytes(s16);
        try out.appendSlice(arena.allocator(), bytes);
    } else {
        const bytes = std.mem.sliceAsBytes(flt);
        try out.appendSlice(arena.allocator(), bytes);
    }
    var written: usize = 0;
    while (written < out.items.len) {
        const n = std.c.write(std.c.STDOUT_FILENO, out.items.ptr + written, out.items.len - written);
        if (n < 0) return error.WriteFailed;
        written += @intCast(n);
    }
}
