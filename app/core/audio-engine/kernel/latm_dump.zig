//! LOAS/LATM（AAC LATM）解码对照导出工具：probe 识别（.latm → fmt/latm）
//! + 解码，按解码器输出契约（16-bit 交错小端 s16）写原始 PCM 到 stdout；
//! 信息打印到 stderr。
//!
//! 用法：zig build-exe kernel/latm_dump.zig -lc -O ReleaseSafe -femit-bin=./latm_dump
//!   ./latm_dump <file.latm> > out.pcm
//! 与参考 ffmpeg 的 `-f s16le` 输出逐字节比对即完成验收。

const std = @import("std");
const io = @import("io.zig");
const decoder = @import("decoder.zig");
const probe = @import("probe.zig");
const latm = @import("fmt/latm.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const args = try init.args.toSlice(arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: latm_dump <file.latm>\n", .{});
        return error.InvalidArgs;
    }

    var reader = try io.Reader.openPath(args[1]);
    errdefer reader.deinit();

    const fmt = try probe.probe(&reader);
    if (fmt != probe.Format.latm) return error.UnsupportedFormat;

    var info: decoder.Info = undefined;
    var dec = try latm.open(gpa, &reader, &info);
    defer dec.deinit();

    std.debug.print("-- metadata --\n", .{});
    std.debug.print("codec: {s}  container: {s}\n", .{ info.codec_name, info.format_name });
    std.debug.print("sample_rate: {d}  channels: {d}  bits_per_sample: {d}\n", .{
        info.sample_rate, info.channels, info.bits_per_sample,
    });

    const frame_bytes = @as(usize, info.channels) * info.bits_per_sample / 8;
    if (frame_bytes == 0) return error.Corrupt;
    var buf: [8192]u8 = undefined;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var ch: u8 = 0;
    while (true) {
        const max_samples = buf.len / frame_bytes;
        const n = try dec.read(&buf, max_samples, &ch);
        if (n == 0) break;
        try out.appendSlice(gpa, buf[0 .. n * frame_bytes]);
    }
    std.debug.print("-- dumped {d} bytes ({d} samples x {d} ch x {d} bit)\n", .{
        out.items.len, out.items.len / frame_bytes, info.channels, info.bits_per_sample,
    });
    var written: usize = 0;
    while (written < out.items.len) {
        const n = std.c.write(std.c.STDOUT_FILENO, out.items[written..].ptr, out.items.len - written);
        if (n < 0) return error.WriteFailed;
        written += @intCast(n);
    }
}
