// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! APE bit-exact 对照导出工具：解码一个 .ape 文件，按解码器输出契约
//! （bps 8 → u8；16 → s16；24 → s32 顶对齐；交错小端）写原始 PCM 到 stdout；
//! 解码信息摘要打印到 stderr（对照 ffprobe 核对）。
//!
//! 用法：zig build-exe kernel/ape_dump.zig -lc -O ReleaseSafe -femit-bin=./ape_dump
//!   ./ape_dump <file.ape> [max_samples] > out.pcm
//! 与 `ffmpeg -i <file.ape> -f s16le/s32le/u8 ref.pcm` 逐字节比对即完成验收；
//! 截断样本（如 FATE luckynight-mac*，帧表存在但文件只含前若干帧）可用
//! max_samples 限定输出样本数，与 `-af atrim=end_sample=<n>` 参考对齐。
//!
//! 直连 fmt/ape/lib.zig（不经 decoder.open）：对照工具验证的是真实解码路径本身，
//! 与 probe 开关无关（§9.10）。

const std = @import("std");
const io = @import("io.zig");
const decoder = @import("decoder.zig");
const ape = @import("fmt/ape/lib.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const args = try init.args.toSlice(arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: ape_dump <file.ape> [max_samples]\n", .{});
        return error.InvalidArgs;
    }
    const max_samples: usize = if (args.len >= 3) std.fmt.parseInt(usize, args[2], 10) catch return error.InvalidArgs else std.math.maxInt(usize);

    var reader = try io.Reader.openPath(args[1]);
    errdefer reader.deinit();

    var info: decoder.Info = undefined;
    var dec = try ape.open(gpa, &reader, &info);
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
    var done: usize = 0;
    while (done < max_samples) {
        const want = @min(buf.len / frame_bytes, max_samples - done);
        const n = dec.read(&buf, want, &ch) catch |e| {
            std.debug.print("-- stopped early at {d} samples ({s})\n", .{ done, @errorName(e) });
            break;
        };
        if (n == 0) break;
        try out.appendSlice(gpa, buf[0 .. n * frame_bytes]);
        done += n;
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
