// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! WMA Lossless (wmalossless, ASF codec_tag 0x163) 解码接入层。
//!
//! 复用 fmt/wma 的 ASF 容器解析与数据包去包（asf.zig / packets.zig）。open
//! 整读 ASF → Header 解析 → Data Object 重组为「WMA packet」序列（每个完整
//! 音频对象 = block_align 字节 = 一个 WMA packet）→ 按 FFmpeg decode core 喂包
//! 循环驱动 `core.Dec.decodePacket`（同一对象可分多次消费；对象耗尽后补空包
//! 触发 EOF flush 输出蓄存器中剩余帧）→ 交错样本。
//!
//! 输出语义对齐 ffmpeg native wmalossless 内部格式：
//!   - 16-bit：交错 s16（= ffmpeg S16P → `-f s16le`，逐位一致）
//!   - 24-bit：24bit 值左移 8 的 int32（= ffmpeg S32P / bits_per_raw_sample=24，
//!     即 `-f s32le`，逐位一致）；Info.bits_per_sample 报 32（与 m4a/ALAC 24bit
//!     输出语义一致）。
//! 解码为整数/无浮点，目标与 ffmpeg 输出逐位一致。

const std = @import("std");
const Error = @import("../../../error.zig").Error;
const io = @import("../../../io.zig");
const decoder = @import("../../../decoder.zig");
const asf = @import("../asf.zig");
const packets = @import("../packets.zig");
const core = @import("core.zig");

const WmaLosslessCtx = struct {
    allocator: std.mem.Allocator,
    file_data: []u8, // 整文件（owned）
    bps: u8, // 每样本字节（2 = s16，4 = s32 24bit<<8）
    pcm: []u8, // 交错样本字节（owned）
    sample_rate: u32,
    channels: u8,
    total_frames: usize, // 每声道样本数
    cursor: usize = 0,

    fn sampleToMs(self: *const WmaLosslessCtx, samples: usize) i64 {
        return @intCast(@divTrunc(@as(i128, @intCast(samples)) * 1000, @as(i128, self.sample_rate)));
    }
    fn read(self: *WmaLosslessCtx, out: []u8, max_samples: usize, out_channels: *u8) Error!usize {
        out_channels.* = self.channels;
        const n = @min(max_samples, self.total_frames - self.cursor);
        if (n == 0) return 0;
        const bytes = n * @as(usize, self.channels) * self.bps;
        if (out.len < bytes) return error.Corrupt;
        std.mem.copyForwards(u8, out[0..bytes], self.pcm[self.cursor * @as(usize, self.channels) * self.bps ..][0..bytes]);
        self.cursor += n;
        return n;
    }
};

const vtable = decoder.Decoder.VTable{
    .read = read,
    .seek_ms = seekMs,
    .position_ms = positionMs,
    .deinit = deinit,
};

fn read(ctx: *anyopaque, out: []u8, max_samples: usize, out_channels: *u8) Error!usize {
    const self: *WmaLosslessCtx = @ptrCast(@alignCast(ctx));
    return self.read(out, max_samples, out_channels);
}

fn seekMs(ctx: *anyopaque, ms: i64) Error!void {
    const self: *WmaLosslessCtx = @ptrCast(@alignCast(ctx));
    if (ms <= 0) {
        self.cursor = 0;
        return;
    }
    const target = @as(u64, @intCast(ms)) * self.sample_rate / 1000;
    self.cursor = @min(@as(usize, @intCast(target)), self.total_frames);
}

fn positionMs(ctx: *anyopaque) i64 {
    const self: *WmaLosslessCtx = @ptrCast(@alignCast(ctx));
    return self.sampleToMs(self.cursor);
}

fn deinit(ctx: *anyopaque) void {
    const self: *WmaLosslessCtx = @ptrCast(@alignCast(ctx));
    const a = self.allocator;
    a.free(self.file_data);
    a.free(self.pcm);
    a.destroy(self);
}

fn readU16le(b: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, b[off..][0..2], .little);
}
fn readU32le(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}

/// 解码全部音频对象（WMA packet 序列）为交错样本字节。
/// 16-bit → s16；24-bit → s32（24bit<<8，ffmpeg S32P 语义）。
pub fn decodeAll(a: std.mem.Allocator, file_data: []const u8, hdr: *const asf.Header) Error!struct { pcm: []u8, total_frames: usize } {
    const audio = hdr.audio.?;
    const bits_per_sample = readU16le(audio.extradata, 0);
    const channel_mask = readU32le(audio.extradata, 2);
    const decode_flags = readU16le(audio.extradata, 14);
    const bps: u8 = if (bits_per_sample == 16) 2 else 4;

    var channels: usize = audio.channels;
    if (channel_mask != 0 and @popCount(channel_mask) == audio.channels) channels = audio.channels;
    if (channels == 0 or channels > core.WMALL_MAX_CHANNELS) return error.UnsupportedFormat;

    const data_start = asf.dataPacketsOffset(file_data, hdr.data_offset) catch return error.Corrupt;
    const avail = file_data.len - data_start;
    if (avail == 0) return error.Corrupt;

    var flat = try a.alloc(u8, avail);
    defer a.free(flat);
    var sizes_buf = try a.alloc(usize, (avail >> 6) + 4);
    defer a.free(sizes_buf);
    const n = packets.demuxObjects(file_data, hdr, flat, sizes_buf) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Corrupt,
    };
    if (n == 0) return error.Corrupt;
    const sizes = sizes_buf[0..n];

    var dec = try core.Dec.init(a, .{
        .sample_rate = audio.sample_rate,
        .bits_per_sample = bits_per_sample,
        .channels = @intCast(channels),
        .channel_mask = channel_mask,
        .decode_flags = decode_flags,
        .block_align = audio.block_align,
    });
    defer dec.deinit();

    const spf = dec.samples_per_frame;
    const interleaved = @as(usize, channels) * bps;

    var pcm = std.ArrayList(u8).empty;
    errdefer pcm.deinit(a);
    // 容量估计：对象数 × 每对象约一帧
    try pcm.ensureTotalCapacity(a, (n + 4) * spf * interleaved);

    var offs = try a.alloc(usize, n);
    defer a.free(offs);
    var acc: usize = 0;
    for (0..n) |k| {
        offs[k] = acc;
        acc += sizes[k];
    }

    var pkt_idx: usize = 0;
    var cur: []const u8 = &.{};
    var guard: usize = 0;

    while (true) : (guard += 1) {
        if (guard > (n + 2) * 2048 + 16) return error.Corrupt;
        if (cur.len == 0) {
            if (pkt_idx < n) {
                cur = flat[offs[pkt_idx]..][0..sizes[pkt_idx]];
                pkt_idx += 1;
            } else {
                break;
            }
        }

        const consumed = dec.decodePacket(cur) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                // 与 ffmpeg decode core 一致：错误 → 丢弃本对象剩余部分
                cur = &.{};
                continue;
            },
        };
        if (dec.frame_pending) {
            const nb = dec.frame_nb_samples;
            const items = try pcm.addManyAsSlice(a, nb * interleaved);
            emitFrame(items, &dec, nb, channels, bps);
        }
        if (consumed >= cur.len) {
            cur = &.{};
        } else {
            cur = cur[consumed..];
        }
    }

    // EOF flush：蓄存器中剩余帧（对齐 ffmpeg drain）
    while (true) : (guard += 1) {
        if (guard > (n + 2) * 2048 + 16) return error.Corrupt;
        const consumed = dec.decodePacket(&.{}) catch break;
        _ = consumed;
        if (dec.frame_pending) {
            const nb = dec.frame_nb_samples;
            const items = try pcm.addManyAsSlice(a, nb * interleaved);
            emitFrame(items, &dec, nb, channels, bps);
        } else if (dec.num_saved_bits <= dec.gb.count()) {
            break;
        }
    }

    const out_bytes = pcm.items.len;
    if (out_bytes == 0) return error.Corrupt;
    const total_frames = out_bytes / interleaved;
    return .{ .pcm = try pcm.toOwnedSlice(a), .total_frames = total_frames };
}

/// 从解码器帧平面缓冲写出 nb×ch 交错样本（16bit s16 / 24bit<<8 s32）。
fn emitFrame(items: []u8, dec: *core.Dec, nb: usize, channels: usize, bps: u8) void {
    const spf = dec.samples_per_frame;
    if (bps == 2) {
        for (0..nb) |s| {
            for (0..channels) |c| {
                const v = dec.out_16[c * spf + s];
                std.mem.writeInt(i16, items[(s * channels + c) * 2 ..][0..2], v, .little);
            }
        }
    } else {
        for (0..nb) |s| {
            for (0..channels) |c| {
                const v = dec.out_32[c * spf + s];
                std.mem.writeInt(i32, items[(s * channels + c) * 4 ..][0..4], v, .little);
            }
        }
    }
}

pub fn openFromAsf(allocator: std.mem.Allocator, file_data: []u8, hdr: *const asf.Header, info: *decoder.Info) Error!decoder.Decoder {
    const audio = hdr.audio.?;
    if (audio.codec_tag != 0x0163) return error.UnsupportedFormat;
    if (audio.extradata.len < 18) return error.UnsupportedFormat;
    const bits_per_sample = readU16le(audio.extradata, 0);
    if (bits_per_sample != 16 and bits_per_sample != 24) return error.UnsupportedFormat;
    if (audio.sample_rate == 0) return error.UnsupportedFormat;
    // 帧长 = 1<<frame_len_bits ≤ 2^13（96k 及以下），超出回退 ffmpeg
    if (audio.sample_rate > 96000) return error.UnsupportedFormat;

    const r = try decodeAll(allocator, file_data, hdr);
    const out_bps: u8 = if (bits_per_sample == 16) 2 else 4;

    const ctx = try allocator.create(WmaLosslessCtx);
    errdefer allocator.destroy(ctx);
    ctx.* = .{
        .allocator = allocator,
        .file_data = file_data,
        .bps = out_bps,
        .pcm = r.pcm,
        .sample_rate = audio.sample_rate,
        .channels = audio.channels,
        .total_frames = r.total_frames,
    };

    info.* = .{
        .sample_rate = audio.sample_rate,
        .channels = audio.channels,
        .bits_per_sample = if (bits_per_sample == 16) 16 else 32,
        .is_float = false,
        // 容器头自洽 → play_duration − preroll（= ffprobe）；否则预解码总数
        .duration_us = asf.containerDurationUs(file_data, hdr) orelse
            @intCast(@divTrunc(@as(i128, @intCast(ctx.total_frames)) * 1_000_000, @as(i128, audio.sample_rate))),
        .duration_known = .exact,
        .codec_name = "wmalossless",
        .format_name = "asf",
        .metadata = .{},
    };

    return .{ .vtable = &vtable, .ctx = ctx };
}

// ---------------------------------------------------------------------------
// golden 回归（vs ffmpeg n9.0.1 native wmalossless，逐字节）
// ---------------------------------------------------------------------------

fn runE2e(embedded: []const u8, golden: []const u8) !struct { sr: u32, ch: u8, bytes: usize, equal: usize } {
    const a = std.testing.allocator;
    const file_data = try a.dupe(u8, embedded);
    var hdr = try asf.parseHeader(file_data);
    var info: decoder.Info = undefined;
    var dec = try openFromAsf(a, file_data, &hdr, &info);
    defer dec.deinit();
    try std.testing.expectEqualStrings("wmalossless", info.codec_name);
    try std.testing.expectEqualStrings("asf", info.format_name);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(a);
    var buf: [65536]u8 = undefined;
    while (true) {
        var ch: u8 = 0;
        const n = try dec.read(&buf, 4096, &ch);
        if (n == 0) break;
        const bytes = n * @as(usize, ch) * (info.bits_per_sample / 8);
        try out.appendSlice(a, buf[0..bytes]);
    }
    const ns = out.items.len;
    const ng = golden.len;
    if (ns != ng) {
        std.debug.print("  WARN byte count mine={d} golden={d}\n", .{ ns, ng });
    }
    const limit = @min(ns, ng);
    var equal: usize = 0;
    for (0..limit) |i| {
        if (out.items[i] == golden[i]) equal += 1;
    }
    std.debug.print("  sr={d} ch={d} bytes mine={d} golden={d} equal={d}/{d} = {d:.6}%\n", .{ info.sample_rate, info.channels, ns, ng, equal, limit, 100.0 * @as(f64, @floatFromInt(equal)) / @as(f64, @floatFromInt(limit)) });
    return .{ .sr = info.sample_rate, .ch = info.channels, .bytes = ns, .equal = equal };
}

const sample_lucky = @embedFile("sample_lucky.wma");
const golden_lucky = @embedFile("golden_lucky.s16");

test "wmalossless e2e: 44.1k/16bit 2ch（LMS+inter+ac filter，210 帧）== ffmpeg" {
    const r = try runE2e(sample_lucky, golden_lucky);
    try std.testing.expectEqual(@as(u32, 44100), r.sr);
    try std.testing.expectEqual(@as(u8, 2), r.ch);
    try std.testing.expectEqual(@as(usize, golden_lucky.len), r.bytes);
    try std.testing.expectEqual(@as(usize, golden_lucky.len), r.equal);
}

const sample_g2 = @embedFile("sample_g2.wma");
const golden_g2 = @embedFile("golden_g2.s32");

test "wmalossless e2e: 44.1k/24bit 2ch（rawpcm tile + 尾帧截断）== ffmpeg s32le" {
    const r = try runE2e(sample_g2, golden_g2);
    try std.testing.expectEqual(@as(u32, 44100), r.sr);
    try std.testing.expectEqual(@as(u8, 2), r.ch);
    try std.testing.expectEqual(@as(usize, golden_g2.len), r.bytes);
    try std.testing.expectEqual(@as(usize, golden_g2.len), r.equal);
}

const sample_master = @embedFile("sample_master.wma");
const golden_master = @embedFile("golden_master.s32");

test "wmalossless e2e: 48k/24bit 2ch（LMS 45 帧）== ffmpeg s32le" {
    const r = try runE2e(sample_master, golden_master);
    try std.testing.expectEqual(@as(u32, 48000), r.sr);
    try std.testing.expectEqual(@as(u8, 2), r.ch);
    try std.testing.expectEqual(@as(usize, golden_master.len), r.bytes);
    try std.testing.expectEqual(@as(usize, golden_master.len), r.equal);
}

const sample_mega = @embedFile("sample_mega.wma");
const golden_mega = @embedFile("golden_mega.s32");

test "wmalossless e2e: 48k/24bit 2ch（9 帧，末帧越界截断）== ffmpeg s32le" {
    const r = try runE2e(sample_mega, golden_mega);
    try std.testing.expectEqual(@as(u32, 48000), r.sr);
    try std.testing.expectEqual(@as(u8, 2), r.ch);
    try std.testing.expectEqual(@as(usize, golden_mega.len), r.bytes);
    try std.testing.expectEqual(@as(usize, golden_mega.len), r.equal);
}

test "wmalossless 配置: 各样本 extradata/帧长推导" {
    {
        var d = try core.Dec.init(std.testing.allocator, .{
            .sample_rate = 44100, .bits_per_sample = 16, .channels = 2,
            .channel_mask = 0x3, .decode_flags = 0x21, .block_align = 13375,
        });
        defer d.deinit();
        try std.testing.expectEqual(@as(usize, 2048), d.samples_per_frame);
        try std.testing.expectEqual(@as(usize, 16), d.max_num_subframes);
        try std.testing.expectEqual(@as(usize, 128), d.min_samples_per_subframe);
        try std.testing.expectEqual(@as(usize, 17), d.log2_frame_size);
        try std.testing.expect(!d.len_prefix);
        try std.testing.expect(!d.dynamic_range_compression);
        try std.testing.expect(!d.bV3RTM);
    }
    {
        var d = try core.Dec.init(std.testing.allocator, .{
            .sample_rate = 48000, .bits_per_sample = 24, .channels = 2,
            .channel_mask = 0x3, .decode_flags = 0x1a1, .block_align = 12288,
        });
        defer d.deinit();
        try std.testing.expectEqual(@as(usize, 2048), d.samples_per_frame);
        try std.testing.expect(d.len_prefix == false);
        try std.testing.expect(d.dynamic_range_compression);
        try std.testing.expect(d.bV3RTM);
    }
}
