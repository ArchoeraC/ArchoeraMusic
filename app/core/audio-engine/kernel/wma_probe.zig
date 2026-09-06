// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! WMA(ASF) 头解析验证工具：打印 File Properties / Stream Properties 参数，
//! 对照 ffprobe（阶段 A 里程碑）。
//!
//! 用法：zig build-exe kernel/wma_probe.zig -lc -O ReleaseSafe -femit-bin=./wma_probe
//!   ./wma_probe <file.wma>

const std = @import("std");
const io = @import("io.zig");
const asf = @import("fmt/wma/asf.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const args = try init.args.toSlice(arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: wma_probe <file.wma>\n", .{});
        return error.InvalidArgs;
    }

    var reader = try io.Reader.openPath(args[1]);
    defer reader.deinit();

    var buf: [64 * 1024]u8 = undefined;
    var n: usize = 0;
    while (n < buf.len) { const m = try reader.read(buf[n..]); if (m == 0) break; n += m; }
    const hdr = try asf.parseHeader(buf[0..n]);
    const audio = hdr.audio.?;

    std.debug.print("-- ASF Header --\n", .{});
    std.debug.print("file_size: {d}  preroll_ms: {d}  play_ms: {d}\n", .{ hdr.file_size, hdr.preroll_ms, hdr.play_time_ms });
    std.debug.print("packet_size: {d}\n", .{ hdr.packet_size });
    std.debug.print("-- WMA audio stream --\n", .{});
    std.debug.print("codec_tag: 0x{X:0>4}  ({s})\n", .{ audio.codec_tag, if (audio.codec_tag == 0x0160) "wmav1" else "wmav2" });
    std.debug.print("channels: {d}  sample_rate: {d}  bits: {d}\n", .{ audio.channels, audio.sample_rate, audio.bits_per_sample });
    std.debug.print("avg_bytes/s: {d}  (~{d} kbps)  block_align: {d}\n", .{ audio.avg_bytes, audio.avg_bytes * 8 / 1000, audio.block_align });
    var hexbuf: [128]u8 = undefined;
    const hexlen = if (audio.extradata.len <= 64) audio.extradata.len else 64;
    const hexchars = "0123456789abcdef";
    for (0..hexlen) |k| { hexbuf[2*k] = hexchars[audio.extradata[k] >> 4]; hexbuf[2*k+1] = hexchars[audio.extradata[k] & 15]; }
    std.debug.print("extradata({d}): {s}\n", .{ audio.extradata.len, hexbuf[0 .. 2*hexlen] });
    std.debug.print("flags2: 0x{X:0>4}  exp_vlc={} bit_reservoir={} var_block_len={}\n", .{
        audio.flags2, audio.use_exp_vlc, audio.use_bit_reservoir, audio.use_variable_block_len,
    });
    const dp = asf.dataPacketsOffset(buf[0..n], hdr.data_offset) catch blk: {
        std.debug.print("data_offset: {d}（缓冲不足定位 Data 区，需要更多前缀）\n", .{hdr.data_offset});
        break :blk 0;
    };
    if (dp != 0) std.debug.print("data_offset: {d}  (首个数据包 @ {d})\n", .{ hdr.data_offset, dp });
}
