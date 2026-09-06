// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! DCA core 解码对照导出工具（阶段二）：解码 .dts core 帧为原始 PCM。
//!
//! 默认输出与 `ffmpeg -flags +bitexact -f s32le` 对齐的 S32LE（24bit<<8，交错，
//! 声道序 = ffmpeg 默认 remap）；`-s16` 输出 16-bit。原始字节到 stdout，信息到 stderr。
//!
//! 用法：zig build-exe kernel/dca_dump.zig -lc -O ReleaseSafe -femit-bin=./dca_dump
//!   ./dca_dump <file.dts> [-s16] > out.s32

const std = @import("std");
const io = @import("io.zig");
const dts = @import("fmt/dts/lib.zig");
const coremod = @import("fmt/dts/core.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const args = try init.args.toSlice(a);
    if (args.len < 2) {
        std.debug.print("usage: dca_dump <file.dts> [-s16]\n", .{});
        return error.InvalidArgs;
    }
    const out_s16 = args.len >= 3 and std.mem.eql(u8, args[2], "-s16");

    var reader = try io.Reader.openPath(args[1]);
    defer reader.deinit();
    const sz = try reader.size();
    const data = try a.alloc(u8, @intCast(sz));
    var got: usize = 0;
    while (got < data.len) {
        const m = try reader.read(data[got..]);
        if (m == 0) break;
        got += m;
    }

    // 位流形态：LE16 先把整帧每 16-bit 字交换成 BE（解码器要求 BE 字节）
    const ord = dts.detectOrder(data[0..@min(data.len, 4)]) orelse return error.InvalidData;
    if (ord == .b14_be or ord == .b14_le) return error.Unsupported14Bit;
    const swap_words = ord == .le16;

    var dec = coremod.DcaDecoder.init(gpa);
    defer dec.deinit();

    var it = dts.Iterator.init(data, ord);
    var nframes: usize = 0;
    var total_samples: u64 = 0;
    var out_buf: [65536]u8 = undefined;
    var frame: coremod.DecodedFrame = undefined;
    var write_ok = true;

    var first = true;
    while (it.next()) |f| {
        const frame_size = f.header.frame_size;
        var frame_buf = data[f.offset .. f.offset + frame_size];
        if (swap_words) {
            const tmp = try a.alloc(u8, frame_size);
            var i: usize = 0;
            while (i + 1 < frame_size) : (i += 2) {
                tmp[i] = frame_buf[i + 1];
                tmp[i + 1] = frame_buf[i];
            }
            frame_buf = tmp;
        }
        dec.decode(frame_buf, &frame) catch |err| {
            std.debug.print("frame {d} decode error: {s}\n", .{ nframes + 1, @errorName(err) });
            return err;
        };
        if (first) {
            std.debug.print("-- dca core: sr={d}  ch={d}  frame_samples={d}  s16={}\n", .{
                frame.sample_rate, frame.nch, frame.nsamples, out_s16,
            });
            first = false;
        }
        total_samples += frame.nsamples;

        var pos: usize = 0;
        for (0..frame.nsamples) |n| {
            for (0..frame.nch) |ch| {
                const v = frame.planes[ch][n];
                if (out_s16) {
                    std.mem.writeInt(i16, out_buf[pos..][0..2], @intCast(v >> 8), .little);
                    pos += 2;
                } else {
                    std.mem.writeInt(i32, out_buf[pos..][0..4], v << 8, .little);
                    pos += 4;
                }
            }
        }
        writeStdout(out_buf[0..pos]) catch {
            write_ok = false;
            break;
        };
        nframes += 1;
    }

    std.debug.print("-- frames={d}  total_samples/ch={d}  order={s}\n", .{
        nframes, total_samples, @tagName(ord),
    });
    _ = &write_ok;
}

fn writeStdout(buf: []const u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = std.c.write(std.c.STDOUT_FILENO, buf[off..].ptr, buf.len - off);
        if (n < 0) return error.WriteFailed;
        off += @intCast(n);
    }
}
