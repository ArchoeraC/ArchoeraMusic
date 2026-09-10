// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! WMA（ASF→wmav1/wmav2）解码对照导出工具。
//!
//! 用法：zig build-exe kernel/wma_dump.zig -lc -O ReleaseSafe -femit-bin=./wma_dump
//!   ./wma_dump <file.wma> > out.s16     （s16 交错小端）
//!   ./wma_dump <file.wma> -f32 > out.f32（浮点原始，先比 corr 用）
//!
//! 输出契约对齐 FFmpeg `-f s16le`（AAC 同款）：float 经
//!   lrintf(x*32768) 后 clamp [-32768,32767] 转 s16。

const std = @import("std");
const io = @import("io.zig");
const asf = @import("fmt/wma/asf.zig");
const wmadec = @import("fmt/wma/wmadec.zig");
const packets = @import("fmt/wma/packets.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const args = try init.args.toSlice(arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: wma_dump <file.wma> [-f32]\n", .{});
        return error.InvalidArgs;
    }
    var want_f32 = false;
    if (args.len >= 3 and std.mem.eql(u8, args[2], "-f32")) want_f32 = true;

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

    const ch: usize = audio.channels;

    // 数据对象 → superframe 流
    const block_align: usize = audio.block_align;
    const max_objs: usize = (data.len / block_align) + 8;
    const objs = try gpa.alloc(u8, max_objs * block_align);
    defer gpa.free(objs);
    const nobj = try packets.demuxSuperframes(data, &hdr, objs);
    std.debug.print("-- packets: objects={d} block_align={d}\n", .{ nobj, block_align });
    if (nobj == 0) return error.Corrupt;

    const params = wmadec.Params{
        .version = if (audio.codec_tag == 0x0160) 1 else 2,
        .channels = audio.channels,
        .sample_rate = audio.sample_rate,
        .bit_rate = audio.avg_bytes * 8,
        .block_align = block_align,
        .flags2 = audio.flags2,
    };
    var dec = try wmadec.WmaDec.open(params);
    const fl = dec.samplesPerFrame();

    // 以块为单位收集全部输出帧
    const est_frames: usize = nobj + 1;
    const out_f32 = try gpa.alloc(f32, est_frames * fl * ch);
    defer gpa.free(out_f32);
    var nframes: usize = 0;
    var frame: [2 * 2048]f32 align(4) = undefined;
    var i: usize = 0;
    while (i < nobj) : (i += 1) {
        // 丢弃解码器前两个 priming superframe（对齐 ffmpeg 输出）
        if (i < 2) {
            _ = dec.decodeSuperframe(objs[i * block_align ..][0..block_align], &frame) catch {};
            continue;
        }
        _ = try dec.decodeSuperframe(objs[i * block_align ..][0..block_align], out_f32[nframes * fl * ch ..]);
        nframes += 1;
    }
    // EOF flush（重叠尾帧）
    _ = dec.flush(out_f32[nframes * fl * ch ..]);
    nframes += 1;

    const total_samples = nframes * fl * ch;
    std.debug.print("-- decoded {d} frames x {d} ch x {d} = {d} samples\n", .{ nframes, ch, fl, total_samples });

    if (want_f32) {
        // planar→交错
        const il = try gpa.alloc(f32, total_samples);
        defer gpa.free(il);
        for (0..nframes) |f| {
            const base = f * fl * ch;
            for (0..fl) |s| {
                for (0..ch) |c| il[base + s * ch + c] = out_f32[base + c * fl + s];
            }
        }
        var written: usize = 0;
        const bytes = std.mem.sliceAsBytes(il[0..total_samples]);
        while (written < bytes.len) {
            const n = std.c.write(std.c.STDOUT_FILENO, bytes[written..].ptr, bytes.len - written);
            if (n < 0) return error.WriteFailed;
            written += @intCast(n);
        }
        return;
    }

    // s16 交错小端：lrintf(x*32768) + clamp
    const s16buf = try gpa.alloc(u8, total_samples * 2);
    defer gpa.free(s16buf);
    for (0..nframes) |f| {
        const base = f * fl * ch;
        for (0..fl) |s| {
            for (0..ch) |c| {
                const idx = base + s * ch + c;
                const src = out_f32[base + c * fl + s];
                var v: f64 = @round(@as(f64, src) * 32768.0);
                if (v > 32767.0) v = 32767.0;
                if (v < -32768.0) v = -32768.0;
                const sv: i16 = @intFromFloat(v);
                std.mem.writeInt(i16, s16buf[idx * 2 ..][0..2], sv, .little);
            }
        }
    }
    var written: usize = 0;
    while (written < s16buf.len) {
        const n = std.c.write(std.c.STDOUT_FILENO, s16buf[written..].ptr, s16buf.len - written);
        if (n < 0) return error.WriteFailed;
        written += @intCast(n);
    }
}
