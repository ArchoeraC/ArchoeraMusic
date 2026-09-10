// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! ALAC bit-exact 对照导出工具：解码一个 M4A（ALAC）文件，按解码器输出契约
//! （bps≤16 → 16-bit；20/24/32 → 32-bit 左移 32-sample_size；交错小端）写原始
//! PCM 到 stdout；解码信息摘要打印到 stderr（对照 ffprobe 核对）。
//!
//! 用法：zig build-exe kernel/alac_dump.zig -lc -O ReleaseSafe -femit-bin=./alac_dump
//!   ./alac_dump <file.m4a> > out.pcm
//! 与 `ffmpeg -i <file.m4a> -f s16le/s32le ref.pcm` 逐字节比对即完成验收。
//!
//! 直连 fmt/m4a.zig（不经 decoder.open）：对照工具验证的是真实解码路径本身，
//! 与 probe 开关无关（m4a 已接管，probe.formats.m4a = true，§17.2）。

const std = @import("std");
const io = @import("io.zig");
const decoder = @import("decoder.zig");
const m4a = @import("fmt/m4a.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const args = try init.args.toSlice(arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: alac_dump <file.m4a>\n", .{});
        return error.InvalidArgs;
    }

    var reader = try io.Reader.openPath(args[1]);
    errdefer reader.deinit();

    var info: decoder.Info = undefined;
    var dec = try m4a.open(gpa, &reader, &info);
    defer dec.deinit();

    std.debug.print("-- metadata --\n", .{});
    std.debug.print("codec: {s}  container: {s}\n", .{ info.codec_name, info.format_name });
    std.debug.print("sample_rate: {d}  channels: {d}  bits_per_sample: {d}  float: {}\n", .{
        info.sample_rate, info.channels, info.bits_per_sample, info.is_float,
    });
    const known = switch (info.duration_known) {
        .exact => "exact",
        .estimate => "estimate",
        .unknown => "unknown",
    };
    std.debug.print("duration_us: {d}  known: {s}\n", .{ info.duration_us, known });

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
