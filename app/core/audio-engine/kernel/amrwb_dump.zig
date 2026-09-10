// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! AMR-WB 解码导出工具（.awb raw `#!AMR-WB` / 3gp 单轨均可）。
//!
//! 用法：zig build-exe kernel/amrwb_dump.zig -lc -O ReleaseSafe -femit-bin=./amrwb_dump
//!   ./amrwb_dump <file.awb> > out.s16    （s16 交错小端，16000Hz 单声道）
//!   ./amrwb_dump <file.awb> -f32 > out.f32（原始浮点，比对 corr 用）
//!
//! 输出契约对齐 FFmpeg `-f s16le`：float 经 lrintf(x*32768)（round-half-even）
//! clamp [-32768,32767] 转 s16；解码核心 = fmt/amrwb（amrwbdec 浮点路径移植）。

const std = @import("std");
const io = @import("io.zig");
const decoder = @import("decoder.zig");
const amrwb = @import("fmt/amrwb/lib.zig");

fn readAll(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var reader = try io.Reader.openPath(path);
    defer reader.deinit();
    const sz = try reader.size();
    const buf = try allocator.alloc(u8, @intCast(sz));
    errdefer allocator.free(buf);
    var got: usize = 0;
    while (got < buf.len) {
        const n = try reader.read(buf[got..]);
        if (n == 0) break;
        got += n;
    }
    return buf[0..got];
}

fn writeFd(data: []const u8) !void {
    var written: usize = 0;
    while (written < data.len) {
        const n = std.c.write(std.c.STDOUT_FILENO, data.ptr + written, data.len - written);
        if (n < 0) return error.WriteFailed;
        written += @intCast(n);
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const args = try init.args.toSlice(arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: amrwb_dump <file.awb> [-f32]\n", .{});
        return error.InvalidArgs;
    }
    var want_f32 = false;
    if (args.len >= 3 and std.mem.eql(u8, args[2], "-f32")) want_f32 = true;

    const data = try readAll(gpa, args[1]);

    std.debug.print("-- amrwb: container=", .{});
    var info: decoder.Info = undefined;
    if (want_f32) {
        var f: []f32 = &.{};
        try amrwb.decodeAllF32(gpa, data, &f, &info);
        defer gpa.free(f);
        std.debug.print("{s} frames={d}\n", .{ info.format_name, f.len / 320 });
        try writeFd(std.mem.sliceAsBytes(f));
    } else {
        var pcm: []i16 = &.{};
        try amrwb.decodeAll(gpa, data, &pcm, &info);
        defer gpa.free(pcm);
        std.debug.print("{s} frames={d}\n", .{ info.format_name, pcm.len / 320 });
        try writeFd(std.mem.sliceAsBytes(pcm));
    }
}
