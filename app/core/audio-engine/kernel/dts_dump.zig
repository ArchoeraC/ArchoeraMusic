// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! DTS core 帧解析验证工具（阶段一）：逐帧打印 core 帧参数并统计，
//! 与系统 ffmpeg `-f dts`/ffprobe 对照（采样率/声道/位率/帧数/时长）。
//!
//! 用法：zig build-exe kernel/dts_dump.zig -lc -O ReleaseSafe -femit-bin=./dts_dump
//!   ./dts_dump <file.dts> [first_n]   # 默认打印前 3 帧
//!
//! 阶段一覆盖：16-bit core 子流（BE 与每 16-bit 字交换 LE）；
//! 14-bit 打包（旧式）与 DTS-HD EXSS/XLL 仅标记，不做 PCM 解码。

const std = @import("std");
const dts = @import("fmt/dts/lib.zig");
const t = @import("fmt/dts/tables.zig");
const io = @import("io.zig");

const alloc = std.heap.page_allocator;

/// ch_mask → 扬声器字母串（"L R" / "C L R Ls Rs LFE"）
fn speakerList(buf: []u8, mask: u32) []const u8 {
    var pos: usize = 0;
    var bit: u6 = 0;
    var m = mask;
    var first = true;
    while (m != 0 and bit < t.speaker_names.len) : (bit += 1) {
        if (m & 1 == 0) {
            m >>= 1;
            continue;
        }
        const name = t.speaker_names[bit];
        const gap: usize = if (first) 0 else 1;
        if (!first and pos < buf.len) buf[pos] = ' ';
        if (pos + gap + name.len > buf.len) break;
        if (!first) pos += 1;
        @memcpy(buf[pos .. pos + name.len], name);
        pos += name.len;
        first = false;
        m >>= 1;
    }
    return buf[0..pos];
}

fn bitRateStr(h: *const dts.Header, buf: []u8) []const u8 {
    return switch (h.br_code) {
        t.br_open => "open(br)",
        t.br_variable => "variable",
        t.br_lossless => "lossless",
        else => std.fmt.bufPrint(buf, "{d}", .{h.bit_rate}) catch "?",
    };
}

pub fn main(init: std.process.Init.Minimal) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const args = try init.args.toSlice(a);
    if (args.len < 2) {
        std.debug.print("usage: dts_dump <file.dts> [first_n]\n", .{});
        return error.InvalidArgs;
    }
    const first_n: usize = if (args.len >= 3) std.fmt.parseInt(usize, args[2], 10) catch 3 else 3;

    const data = blk: {
        var reader = try io.Reader.openPath(args[1]);
        defer reader.deinit();
        const sz = try reader.size();
        const buf = try a.alloc(u8, @intCast(sz));
        var got: usize = 0;
        while (got < buf.len) {
            const m = try reader.read(buf[got..]);
            if (m == 0) break;
            got += m;
        }
        break :blk buf[0..got];
    };

    // 位流形态：文件头 4 字节优先；否则在文件内扫描首个 core sync
    const ord = dts.detectOrder(data[0..@min(data.len, 4)]) orelse (try findFirstSync(data)) orelse {
        std.debug.print("{s}: 未找到 DTS core sync（14-bit/EXSS-only 或非 DTS 文件？）\n", .{args[1]});
        return error.InvalidData;
    };
    if (ord == .b14_be or ord == .b14_le) {
        std.debug.print("{s}: 14-bit 打包 DTS（旧式），阶段一仅识别不解析\n", .{args[1]});
        return error.InvalidData;
    }

    std.debug.print("-- {s}  order={s}\n", .{ args[1], @tagName(ord) });

    var it = dts.Iterator.init(data, ord);

    // 首帧参数（对照 ffprobe stream 行）
    if (it.next()) |f0| {
        const h = &f0.header;
        const cc = dts.channelConfig(h);
        var brbuf: [24]u8 = undefined;
        var spk: [96]u8 = undefined;
        std.debug.print("first_frame: sr={d}  bitrate={s}b/s  channels={d}  speakers={s}  frame_samples={d}\n", .{
            h.sample_rate,
            bitRateStr(h, &brbuf),
            cc.channels,
            speakerList(&spk, cc.ch_mask),
            dts.frameSamples(h),
        });
        std.debug.print("  amode={d}({s})  lfe={d}  nsubframes={d}  npcmblocks={d}  nchannels={d}{s}  frame_size={d}B  bits_per_sample={d}{s}\n", .{
            h.audio_mode, t.amode_names[h.audio_mode], h.lfe_present,
            h.nsubframes, h.npcmblocks, h.nchannels,
            if (h.nchannels_mismatch) "(!)" else "",
            h.frame_size, h.source_pcm_res,
            if (h.ext_audio_present) (switch (h.ext_audio_type) {
                t.ext_xch => "  [XCH]",
                t.ext_x96 => "  [X96]",
                t.ext_xxch => "  [XXCH]",
                else => "  [ext]",
            }) else "",
        });
    } else {
        std.debug.print("{s}: 无有效 core 帧\n", .{args[1]});
        return error.InvalidData;
    }
    // 复位（重扫前先归零：重新建迭代器）
    it = dts.Iterator.init(data, ord);

    std.debug.print("-- frames (offset/size/sr/bitrate/amode/ch/frame_samples) --\n", .{});
    var n: usize = 0;
    var summary: dts.Stats = .{ .order = ord };
    var sample_rate: u32 = 0;
    while (it.next()) |f| {
        const h = &f.header;
        summary.frames = it.stats.frames;
        summary.core_bytes = it.stats.core_bytes;
        summary.skipped_bytes = it.stats.skipped_bytes;
        summary.total_samples = it.stats.total_samples;
        summary.sample_rate = it.stats.sample_rate;
        summary.frame_samples_first = it.stats.frame_samples_first;
        summary.sample_rates_differ = it.stats.sample_rates_differ;
        summary.errors = it.stats.errors;
        summary.truncated = it.stats.truncated;
        sample_rate = it.stats.sample_rate;

        if (n < first_n) {
            var brbuf: [24]u8 = undefined;
            const cc = dts.channelConfig(h);
            std.debug.print("  {d:>6}: off={d:>8} size={d:>5} sr={d:>6} br={s:>7} amode={d} ch={d} fsamples={d}\n", .{
                n + 1,
                f.offset,
                h.frame_size,
                h.sample_rate,
                bitRateStr(h, &brbuf),
                h.audio_mode,
                cc.channels,
                dts.frameSamples(h),
            });
        }
        n += 1;
    }
    summary.residual_bytes = it.stats.residual_bytes;

    std.debug.print("-- summary --\n", .{});
    std.debug.print("  frames={d}  core_bytes={d}  skipped={d}  residual={d}\n", .{
        summary.frames, summary.core_bytes, summary.skipped_bytes, summary.residual_bytes,
    });
    std.debug.print("  total_samples={d}  (frame_samples first={d})  sr={d}\n", .{
        summary.total_samples, summary.frame_samples_first, sample_rate,
    });
    if (summary.sample_rate != 0) {
        std.debug.print("  duration_s={d:.6}  (total_samples/{d})\n", .{ summary.durationSec(), sample_rate });
    }
    std.debug.print("  byte_residual_ok={s}\n", .{if (summary.residual_bytes == 0 and summary.skipped_bytes == 0 and !summary.truncated) "yes(纯 core 无缝)" else "no(存在 EXSS/填充或截断)"});
    if (summary.truncated) std.debug.print("  truncated=yes（末尾帧跨 EOF，文件不完整）\n", .{});
    if (summary.errors != 0) std.debug.print("  errors(resync)={d}\n", .{summary.errors});
}

fn findFirstSync(data: []const u8) !?dts.ByteOrder {
    var be = dts.Iterator.init(data, .be16);
    if (be.next() != null) return .be16;
    var le = dts.Iterator.init(data, .le16);
    if (le.next() != null) return .le16;
    // 14-bit 形态（仅识别）
    if (data.len >= 4) {
        const w = std.mem.readInt(u32, data[0..4], .big);
        if (w == t.syncword_core_14b_be) return .b14_be;
        if (w == t.syncword_core_14b_le) return .b14_le;
    }
    return null;
}
