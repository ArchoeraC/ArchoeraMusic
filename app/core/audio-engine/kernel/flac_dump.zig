// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! FLAC bit-exact 对照导出工具：解码一个 FLAC 文件，按解码器输出契约
//! （bps≤16 → 16-bit 左移对齐；bps>16 → 32-bit 左移对齐；交错小端）写原始 PCM 到 stdout；
//! 元数据 / 全部标签条目 / REPLAYGAIN / 提示点 / PICTURE 封面摘要打印到 stderr
//! （对照 metaflac --list 核对）。
//!
//! 用法：zig build-exe kernel/flac_dump.zig -lc -O ReleaseSafe -femit-bin=./flac_dump
//!   ./flac_dump <file.flac> > out.pcm
//! 与 `ffmpeg -i <file.flac> -f s16le/s32le ref.pcm` 逐字节比对即完成验收。

const std = @import("std");
const decoder = @import("decoder.zig");

/// 打印元数据摘要到 stderr（对照 metaflac --list / ffprobe 人工核对；
/// stdout 保持纯 PCM，不破坏 bit-exact 比对）。
fn dumpMeta(info: *const decoder.Info) void {
    std.debug.print("-- metadata --\n", .{});
    inline for (.{
        .{ "title", info.metadata.title },
        .{ "artist", info.metadata.artist },
        .{ "album", info.metadata.album },
        .{ "date", info.metadata.date },
        .{ "genre", info.metadata.genre },
        .{ "comment", info.metadata.comment },
    }) |f| {
        if (f[1]) |s| std.debug.print("{s}: {s}\n", .{ f[0], s });
    }
    std.debug.print("cue_points: {d}\n", .{info.cue_points.len});
    for (info.cue_points) |c| {
        std.debug.print("  cue id={d} position={d}\n", .{ c.id, c.position });
    }
    // 全部 VORBIS 注释条目（含非标准键；对齐 metaflac --list 的标签区）
    std.debug.print("tags: {d}\n", .{info.metadata.tags.len});
    for (info.metadata.tags) |t| {
        std.debug.print("  {s}={s}\n", .{ t.key, t.value });
    }
    // REPLAYGAIN 增益（单位 0.001 dB / 0.00001）
    if (info.replay_gain.track_gain != null or info.replay_gain.track_peak != null or
        info.replay_gain.album_gain != null or info.replay_gain.album_peak != null)
    {
        std.debug.print("replay_gain:\n", .{});
        if (info.replay_gain.track_gain) |v| std.debug.print("  track_gain: {d:.3} dB\n", .{@as(f64, @floatFromInt(v)) / 1000.0});
        if (info.replay_gain.track_peak) |v| std.debug.print("  track_peak: {d:.5}\n", .{@as(f64, @floatFromInt(v)) / 100000.0});
        if (info.replay_gain.album_gain) |v| std.debug.print("  album_gain: {d:.3} dB\n", .{@as(f64, @floatFromInt(v)) / 1000.0});
        if (info.replay_gain.album_peak) |v| std.debug.print("  album_peak: {d:.5}\n", .{@as(f64, @floatFromInt(v)) / 100000.0});
    }
    std.debug.print("pictures: {d}\n", .{info.pictures.len});
    for (info.pictures) |p| {
        std.debug.print("  pic type={d} mime={s} desc={s} {d}x{d} depth={d} colors={d} data={d}B\n", .{
            p.picture_type, p.mime,     p.description,
            p.width,        p.height,   p.depth,
            p.colors,       p.data.len,
        });
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const args = try init.args.toSlice(arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: flac_dump <file.flac>\n", .{});
        return error.InvalidArgs;
    }

    var info: decoder.Info = undefined;
    var dec = try decoder.open(gpa, args[1], &info);
    defer dec.deinit();
    dumpMeta(&info);

    const frame_bytes = @as(usize, info.channels) * info.bits_per_sample / 8;
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
    var written: usize = 0;
    while (written < out.items.len) {
        const n = std.c.write(std.c.STDOUT_FILENO, out.items[written..].ptr, out.items.len - written);
        if (n < 0) return error.WriteFailed;
        written += @intCast(n);
    }
}
