// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Opus 解码器模块局部测试：`opus.open` + VTable `read` → s16 交错 PCM 到 stdout。
//!
//! 用法：./opus_vt <file.ogg> > out.pcm
//! 对照：ffmpeg -i file.ogg -c:a libopus -f s16le ref.pcm
const std = @import("std");
const io = @import("io.zig");
const decoder = @import("decoder.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const args = try init.args.toSlice(arena.allocator());
    if (args.len < 2) return error.InvalidArgs;

    var info: decoder.Info = undefined;
    var d = try decoder.open(gpa, args[1], &info);
    std.debug.print("-- sr={d} ch={d} bps={d} codec={s} fmt={s}\n", .{ info.sample_rate, info.channels, info.bits_per_sample, info.codec_name, info.format_name });

    const frame_bytes = @as(usize, info.channels) * 2;
    var pcm: [4096]u8 = undefined;
    var total: u64 = 0;
    var out_ch: u8 = 0;
    while (true) {
        const n = try d.read(&pcm, pcm.len / frame_bytes, &out_ch);
        if (n == 0) break;
        total += n;
        var written: usize = 0;
        while (written < n * frame_bytes) {
            const c = std.c.write(std.c.STDOUT_FILENO, pcm[written..].ptr, n * frame_bytes - written);
            if (c < 0) return error.WriteFailed;
            written += @intCast(c);
        }
    }
    std.debug.print("-- decoded {d} samples {d} ch\n", .{ total, info.channels });
    d.deinit();
}
