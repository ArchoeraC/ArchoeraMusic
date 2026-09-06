// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! WMA Lossless（ASF 0x163）解码对照导出工具。
//!
//! 用法：zig build-exe kernel/wmalossless_dump.zig -lc -O ReleaseSafe -femit-bin=./wmalossless_dump
//!   ./wmalossless_dump <file.wma> > out.pcm
//!
//! 输出语义 = ffmpeg native wmalossless 内部样本：
//!   16-bit → s16le 交错；24-bit → s32le 交错（24bit 值左移 8）。

const std = @import("std");
const io = @import("io.zig");
const asf = @import("fmt/wma/asf.zig");
const wl = @import("fmt/wma/wmalossless/lib.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const args = try init.args.toSlice(arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: wmalossless_dump <file.wma>\n", .{});
        return error.InvalidArgs;
    }

    var reader = try io.Reader.openPath(args[1]);
    defer reader.deinit();
    const sz = try reader.size();
    const file_buf = try gpa.alloc(u8, @intCast(sz));
    defer gpa.free(file_buf);
    var got: usize = 0;
    while (got < file_buf.len) {
        const n = try reader.read(file_buf[got..]);
        if (n == 0) break;
        got += n;
    }
    const data: []const u8 = file_buf[0..got];

    var hdr = try asf.parseHeader(data);
    const audio = hdr.audio.?;
    std.debug.print("-- codec 0x{X:0>4} ch={d} sr={d} block_align={d} extrabits={d}\n", .{ audio.codec_tag, audio.channels, audio.sample_rate, audio.block_align, std.mem.readInt(u16, audio.extradata[0..2], .little) });

    const r = try wl.decodeAll(gpa, data, &hdr);
    defer gpa.free(r.pcm);
    std.debug.print("-- decoded frames={d} bytes={d}\n", .{ r.total_frames, r.pcm.len });

    var written: usize = 0;
    while (written < r.pcm.len) {
        const n = std.c.write(std.c.STDOUT_FILENO, r.pcm.ptr + written, r.pcm.len - written);
        if (n < 0) return error.WriteFailed;
        written += @intCast(n);
    }
}
