// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! MP3（MPEG Audio Layer I/II/III）解码对照导出工具：解码一个 mp3 文件，按解码器
//! 输出契约（16-bit 交错小端 s16）写原始 PCM 到 stdout；信息打印到 stderr。
//!
//! 用法：zig build-exe kernel/mp3_dump.zig -lc -O ReleaseSafe -femit-bin=./mp3_dump
//!   ./mp3_dump <file.mp3> > out.pcm
//! 与参考 ffmpeg 的 `-f s16le` 输出逐字节比对即完成验收。

const std = @import("std");
const io = @import("io.zig");
const decoder = @import("decoder.zig");
const mp3 = @import("fmt/mp3/lib.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const args = try init.args.toSlice(arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: mp3_dump <file.mp3>\n", .{});
        return error.InvalidArgs;
    }

    var reader = try io.Reader.openPath(args[1]);
    errdefer reader.deinit();

    var info: decoder.Info = undefined;
    var dec = try mp3.open(gpa, &reader, &info);
    defer dec.deinit();

    std.debug.print("-- metadata --\n", .{});
    std.debug.print("codec: {s}  container: {s}\n", .{ info.codec_name, info.format_name });
    std.debug.print("sample_rate: {d}  channels: {d}  bits_per_sample: {d}\n", .{
        info.sample_rate, info.channels, info.bits_per_sample,
    });
    std.debug.print("duration_us: {d}  duration_known: {s}\n", .{ info.duration_us, @tagName(info.duration_known) });

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
    std.debug.print("-- dumped {d} bytes ({d} frames x {d} ch x {d} bit)\n", .{
        out.items.len, out.items.len / frame_bytes, info.channels, info.bits_per_sample,
    });
    var written: usize = 0;
    while (written < out.items.len) {
        const n = std.c.write(std.c.STDOUT_FILENO, out.items[written..].ptr, out.items.len - written);
        if (n < 0) return error.WriteFailed;
        written += @intCast(n);
    }
}
