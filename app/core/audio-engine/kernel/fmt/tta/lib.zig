// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! TTA (True Audio, .tta) 解码器接入层（fmt/tta）。
//!
//! 容器（libavformat/tta.c + tta.c 头解析）：
//!   22 字节 TTA1 头（魔数/format/channels/bits_per_sample/sample_rate/
//!   data_length(每声道样本总数)/头 CRC32）→ 每帧 4 字节大小的 seek 表 + 表 CRC
//!   → 帧体。data_length=0 / 头 CRC 不匹配按 ffmpeg 默认（非 CRCCHECK）语义容忍，
//!   结构损坏仍报 Corrupt。
//!
//! 解码语义（对齐 ffmpeg n9.0.1 native tta）：
//!   - 帧长 frame_len = 256×sample_rate/245；帧间无状态（滤波器/预测器/Rice 每帧
//!     归零），支持按帧随机访问 seek；
//!   - 输出对齐 ffmpeg 内部样本格式：8bit → u8(+0x80)、16bit → s16（=`-f s16le`）、
//!     24bit → int32<<8（=`-f s32le`）；Info.bits_per_sample 报 8/16/32
//!     （24bit 以 32bit 承载，与 wmalossless/flac/ALAC 输出语义一致）；
//!   - format=2（加密）及不支持位深 → UnsupportedFormat（回退 FFmpeg 主后端）。

const std = @import("std");
const Error = @import("../../error.zig").Error;
const io = @import("../../io.zig");
const decoder = @import("../../decoder.zig");
const core = @import("core.zig");
const id3 = @import("../mp3/id3.zig");

const Header = struct {
    format: u16,
    channels: u16,
    bits_per_sample: u16,
    sample_rate: u32,
    data_length: u32, // 每声道样本总数
};

/// 帧字节偏移（表尾后首帧偏移 0）
const Frames = struct {
    offsets: []u64, // nframes+1 前缀累计（offsets[n] = 第 n 帧起点）
    nframes: usize,
};

fn parseHeader(b: []const u8) Error!Header {
    if (b.len < 22) return error.Corrupt;
    if (!std.mem.eql(u8, b[0..4], "TTA1")) return error.Corrupt;
    const format = std.mem.readInt(u16, b[4..6], .little);
    if (format > 2) return error.Corrupt;
    if (format == 2) return error.UnsupportedFormat; // 加密流（ffmpeg 需 password）
    const channels = std.mem.readInt(u16, b[6..8], .little);
    const bits = std.mem.readInt(u16, b[8..10], .little);
    const sr = std.mem.readInt(u32, b[10..14], .little);
    const ns = std.mem.readInt(u32, b[14..18], .little);
    if (channels == 0 or channels > core.MAX_CHANNELS) return error.Corrupt;
    if (sr == 0 or sr > 1_000_000) return error.UnsupportedFormat; // demuxer 上限
    if (ns == 0) return error.Corrupt;
    const bps: u16 = (bits + 7) / 8;
    if (bps < 1 or bps > 3) return error.UnsupportedFormat; // ffmpeg: 8/16/24
    if (bits == 0) return error.Corrupt;
    return .{ .format = format, .channels = channels, .bits_per_sample = bits, .sample_rate = sr, .data_length = ns };
}

/// 解析 seek 表，返回帧字节偏移（相对整个文件）与帧数。
fn parseFrames(a: std.mem.Allocator, b: []const u8, hdr: *const Header) Error!Frames {
    const frame_len: usize = @as(usize, 256) * hdr.sample_rate / 245;
    if (frame_len == 0) return error.Corrupt;
    const dl: u64 = hdr.data_length;
    const last_partial = dl % frame_len;
    const nframes: usize = @intCast(dl / frame_len + (if (last_partial != 0) @as(u64, 1) else 0));
    if (nframes == 0) return error.Corrupt;

    const table_off: usize = 22;
    const need = table_off + nframes * 4 + 4;
    if (b.len < need) return error.Corrupt;

    const offs = a.alloc(u64, nframes + 1) catch return error.OutOfMemory;
    var acc: u64 = table_off + nframes * 4 + 4;
    offs[0] = acc;
    var i: usize = 0;
    while (i < nframes) : (i += 1) {
        const sz = std.mem.readInt(u32, b[table_off + i * 4 ..][0..4], .little);
        acc += sz;
        if (acc < offs[i]) return error.Corrupt; // 溢出
        offs[i + 1] = acc;
    }
    if (acc > b.len) return error.Corrupt;
    return .{ .offsets = offs, .nframes = nframes };
}

const DecoderCtx = struct {
    allocator: std.mem.Allocator,
    data: []u8, // 整文件（owned）
    frames: Frames, // offsets owned
    sample_rate: u32,
    channels: u8,
    bits_per_sample: u16,
    width: u8, // 输出每样本字节（1/2/4）
    total_samples: usize, // data_length
    frame_len: usize,
    frame_dec: core.FrameDecoder,
    // 游标
    cursor: usize = 0, // 绝对样本（每声道）位置
    queue: []u8, // 当前已解码帧的交错字节
    q_len: usize = 0, // queue 中本帧样本数
    q_pos: usize = 0, // 本帧内已消费样本
    have_queue: bool = false,

    fn ilv(self: *const DecoderCtx) usize {
        return @as(usize, self.channels) * self.width;
    }

    fn decodeFrameBytes(self: *DecoderCtx, fidx: usize) Error!void {
        const start = self.frames.offsets[fidx];
        const end = self.frames.offsets[fidx + 1];
        const frame_data = self.data[@intCast(start)..@intCast(end)];
        if (frame_data.len < 4) return error.Corrupt;
        const body = frame_data[0 .. frame_data.len - 4]; // 末 4 字节为帧 CRC
        const fs = @min(self.frame_len, self.total_samples - fidx * self.frame_len);
        var br = core.BitReader.init(body);
        self.frame_dec.decode(&br, @intCast((self.bits_per_sample + 7) / 8), fs, self.queue) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Corrupt,
        };
        self.q_len = fs;
        // cursor 可能落在帧中段（seek）：本帧内跳过的样本数 = cursor - fidx×frame_len
        const intra = self.cursor - fidx * self.frame_len;
        self.q_pos = @min(intra, fs);
        self.have_queue = true;
    }

    fn read(self: *DecoderCtx, out: []u8, max_samples: usize, out_channels: *u8) Error!usize {
        out_channels.* = self.channels;
        if (self.cursor >= self.total_samples) return 0;
        const avail_total = self.total_samples - self.cursor;
        const interleave = self.ilv();
        const want = @min(@min(max_samples, avail_total), out.len / interleave);
        if (want == 0 or out.len == 0) return 0;

        var produced: usize = 0;
        while (produced < want) {
            if (!self.have_queue) {
                const fidx = self.cursor / self.frame_len;
                if (fidx >= self.frames.nframes) return error.Corrupt;
                try self.decodeFrameBytes(fidx);
            }
            const take = @min(want - produced, self.q_len - self.q_pos);
            const dst = out[produced * interleave ..][0 .. take * interleave];
            const src = self.queue[self.q_pos * interleave ..][0 .. take * interleave];
            @memcpy(dst, src);
            self.q_pos += take;
            self.cursor += take;
            produced += take;
            if (self.q_pos >= self.q_len) self.have_queue = false;
        }
        return produced;
    }

    fn sampleToMs(samples: usize, sr: u32) i64 {
        return @intCast(@divTrunc(@as(i128, @intCast(samples)) * 1000, @as(i128, sr)));
    }
};

const vtable = decoder.Decoder.VTable{
    .read = read,
    .seek_ms = seekMs,
    .position_ms = positionMs,
    .deinit = deinit,
};

fn read(ctx: *anyopaque, out: []u8, max_samples: usize, out_channels: *u8) Error!usize {
    const self: *DecoderCtx = @ptrCast(@alignCast(ctx));
    return self.read(out, max_samples, out_channels);
}

fn seekMs(ctx: *anyopaque, ms: i64) Error!void {
    const self: *DecoderCtx = @ptrCast(@alignCast(ctx));
    const target: usize = if (ms <= 0)
        0
    else
        @min(@as(usize, @intCast(@divTrunc(@as(u128, @intCast(ms)) * self.sample_rate, 1000))), self.total_samples);
    self.cursor = target;
    self.have_queue = false;
    self.q_pos = 0;
}

fn positionMs(ctx: *anyopaque) i64 {
    const self: *DecoderCtx = @ptrCast(@alignCast(ctx));
    return DecoderCtx.sampleToMs(self.cursor, self.sample_rate);
}

fn deinit(ctx: *anyopaque) void {
    const self: *DecoderCtx = @ptrCast(@alignCast(ctx));
    const a = self.allocator;
    self.frame_dec.deinit();
    a.free(self.queue);
    a.free(self.frames.offsets);
    a.free(self.data);
    a.destroy(self);
}

fn widthOf(bits: u16) u8 {
    return switch ((bits + 7) / 8) {
        1 => 1,
        2 => 2,
        else => 4,
    };
}

pub fn open(allocator: std.mem.Allocator, reader: *io.Reader, info: *decoder.Info) Error!decoder.Decoder {
    const fsize = try reader.size();
    if (fsize < 22) return error.Corrupt;
    const data = try allocator.alloc(u8, @intCast(fsize));
    errdefer allocator.free(data);
    var got: usize = 0;
    while (got < fsize) {
        const n = reader.read(data[got..]) catch |e| switch (e) {
            error.Aborted => return error.Aborted,
            else => return error.IoError,
        };
        if (n == 0) break;
        got += n;
    }
    if (got < fsize) return error.Corrupt;

    const hdr = try parseHeader(data);
    if (hdr.format != 1) return error.UnsupportedFormat;
    const frames = parseFrames(allocator, data, &hdr) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Corrupt,
    };
    errdefer allocator.free(frames.offsets);

    const width = widthOf(hdr.bits_per_sample);
    const frame_len: usize = @as(usize, 256) * hdr.sample_rate / 245;
    // 单帧解码输出缓冲（交错字节）
    const qbytes = frame_len * @as(usize, hdr.channels) * width;
    const queue = try allocator.alloc(u8, qbytes);
    errdefer allocator.free(queue);

    var fd = core.FrameDecoder.init(allocator, hdr.channels, @intCast((hdr.bits_per_sample + 7) / 8)) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.UnsupportedFormat,
    };
    errdefer fd.deinit();

    const ctx = try allocator.create(DecoderCtx);
    ctx.* = .{
        .allocator = allocator,
        .data = data,
        .frames = frames,
        .sample_rate = hdr.sample_rate,
        .channels = @intCast(hdr.channels),
        .bits_per_sample = hdr.bits_per_sample,
        .width = width,
        .total_samples = hdr.data_length,
        .frame_len = frame_len,
        .frame_dec = fd,
        .queue = queue,
    };

    info.* = .{
        .sample_rate = hdr.sample_rate,
        .channels = @intCast(hdr.channels),
        .bits_per_sample = if (hdr.bits_per_sample <= 16) @intCast(hdr.bits_per_sample) else 32,
        .is_float = false,
        .duration_us = @intCast(@divTrunc(@as(u128, @intCast(ctx.total_samples)) * 1_000_000, hdr.sample_rate)),
        .duration_known = .exact,
        .codec_name = "tta",
        .format_name = "tta",
        .metadata = .{},
    };
    return .{ .vtable = &vtable, .ctx = ctx };
}

// ---------------------------------------------------------------------------
// 元数据专用快路径（probe-only，§8.4.2①）：整读后仅 parseHeader+parseFrames
// （seek 表，不解帧），音频终点定位尾部 ID3v2 + 末 128B ID3v1；不建 FrameDecoder。
// ---------------------------------------------------------------------------

const MetaCtx = struct {
    allocator: std.mem.Allocator,
    reader: io.Reader,
    data: []u8,
    offsets: []u64,
    meta: decoder.Metadata,
    pics: []decoder.Picture,
};

fn metaDeinit(p: *anyopaque) void {
    const ctx: *MetaCtx = @ptrCast(@alignCast(p));
    id3.freeMeta(ctx.allocator, &ctx.meta);
    id3.freePictures(ctx.allocator, &ctx.pics);
    ctx.allocator.free(ctx.offsets);
    ctx.allocator.free(ctx.data);
    ctx.reader.deinit();
    ctx.allocator.destroy(ctx);
}

pub fn openMeta(allocator: std.mem.Allocator, reader: *io.Reader, info: *decoder.Info) Error!decoder.MetadataSession {
    const fsize = try reader.size();
    if (fsize < 22) return error.Corrupt;
    const data = try allocator.alloc(u8, @intCast(fsize));
    errdefer allocator.free(data);
    var got: usize = 0;
    while (got < fsize) {
        const n = reader.read(data[got..]) catch |e| switch (e) {
            error.Aborted => return error.Aborted,
            else => return error.IoError,
        };
        if (n == 0) break;
        got += n;
    }
    if (got < fsize) return error.Corrupt;

    const hdr = try parseHeader(data);
    if (hdr.format != 1) return error.UnsupportedFormat;
    const frames = parseFrames(allocator, data, &hdr) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Corrupt,
    };
    errdefer allocator.free(frames.offsets);

    var meta: decoder.Metadata = .{};
    var pics: []decoder.Picture = &.{};
    var rg: decoder.ReplayGain = .{};
    errdefer {
        id3.freeMeta(allocator, &meta);
        id3.freePictures(allocator, &pics);
    }

    // 音频终点 = 末帧之后；其处若为 ID3v2（TTA 规范：尾置）则解析
    const audio_end = frames.offsets[frames.nframes];
    if (audio_end + 10 <= data.len and std.mem.eql(u8, data[@intCast(audio_end)..][0..3], "ID3")) {
        _ = id3.parseV2(reader, allocator, audio_end, &meta, &pics, &rg) catch {};
    }
    id3.parseV1(reader, allocator, fsize, &meta) catch {};

    const ctx = try allocator.create(MetaCtx);
    ctx.* = .{
        .allocator = allocator,
        .reader = reader.*,
        .data = data,
        .offsets = frames.offsets,
        .meta = meta,
        .pics = pics,
    };

    info.* = .{
        .sample_rate = hdr.sample_rate,
        .channels = @intCast(hdr.channels),
        .bits_per_sample = if (hdr.bits_per_sample <= 16) @intCast(hdr.bits_per_sample) else 32,
        .is_float = false,
        .duration_us = @intCast(@divTrunc(@as(u128, @intCast(hdr.data_length)) * 1_000_000, hdr.sample_rate)),
        .duration_known = .exact,
        .codec_name = "tta",
        .format_name = "tta",
        .metadata = meta,
        .pictures = pics,
        .replay_gain = rg,
    };
    return .{ .ctx = @ptrCast(ctx), .deinit_fn = metaDeinit };
}

// ---------------------------------------------------------------------------
// 回归测试（golden = ffmpeg n9.0.1 native tta 解码，逐字节）
// ---------------------------------------------------------------------------

const testing = std.testing;

const inside_tta = @embedFile("samples/inside.tta"); // FATE 44.1k 立体声 16bit
const inside_golden = @embedFile("samples/inside.s16");
const mono_tta = @embedFile("samples/mono.tta"); // ffmpeg 编码 44.1k 单声道 16bit
const mono_golden = @embedFile("samples/mono.s16");

fn runE2e(embedded: []const u8, golden: []const u8) !struct { sr: u32, ch: u8, bits: u8, bytes: usize, equal: usize } {
    const a = testing.allocator;
    var r = io.Reader.openMem(embedded);
    var info: decoder.Info = undefined;
    var d = try open(a, &r, &info);
    defer d.deinit();

    var out = std.ArrayList(u8).empty;
    defer out.deinit(a);
    var buf: [65536]u8 = undefined;
    while (true) {
        var ch: u8 = 0;
        const n = try d.read(&buf, 4096, &ch);
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
    std.debug.print("  sr={d} ch={d} bits={d} bytes mine={d} golden={d} equal={d}/{d} = {d:.6}%\n", .{ info.sample_rate, info.channels, info.bits_per_sample, ns, ng, equal, limit, 100.0 * @as(f64, @floatFromInt(equal)) / @as(f64, @floatFromInt(limit)) });
    return .{ .sr = info.sample_rate, .ch = info.channels, .bits = info.bits_per_sample, .bytes = ns, .equal = equal };
}

test "tta e2e: inside.tta (44.1k/16bit 2ch, 12 帧含 17397 尾帧) == ffmpeg s16le" {
    const r = try runE2e(inside_tta, inside_golden);
    try testing.expectEqual(@as(u32, 44100), r.sr);
    try testing.expectEqual(@as(u8, 2), r.ch);
    try testing.expectEqual(@as(u8, 16), r.bits);
    try testing.expectEqual(inside_golden.len, r.bytes);
    try testing.expectEqual(inside_golden.len, r.equal);
}

test "tta e2e: mono.tta (44.1k/16bit 1ch, ffmpeg 编码 3 帧) == ffmpeg s16le" {
    const r = try runE2e(mono_tta, mono_golden);
    try testing.expectEqual(@as(u32, 44100), r.sr);
    try testing.expectEqual(@as(u8, 1), r.ch);
    try testing.expectEqual(@as(u8, 16), r.bits);
    try testing.expectEqual(mono_golden.len, r.bytes);
    try testing.expectEqual(mono_golden.len, r.equal);
}

const bit24_tta = @embedFile("samples/bit24.tta"); // ffmpeg 编码 44.1k 立体声 24bit 粉噪
const bit24_golden = @embedFile("samples/bit24.s32");

test "tta e2e: bit24.tta (44.1k/24bit 2ch) == ffmpeg s32le（24bit<<8）" {
    const r = try runE2e(bit24_tta, bit24_golden);
    try testing.expectEqual(@as(u32, 44100), r.sr);
    try testing.expectEqual(@as(u8, 2), r.ch);
    try testing.expectEqual(@as(u8, 32), r.bits);
    try testing.expectEqual(bit24_golden.len, r.bytes);
    try testing.expectEqual(bit24_golden.len, r.equal);
}

const bit8_tta = @embedFile("samples/bit8.tta"); // ffmpeg 编码 48k 单声道 8bit
const bit8_golden = @embedFile("samples/bit8.u8");

test "tta e2e: bit8.tta (48k/8bit 1ch) == ffmpeg u8（样本+0x80）" {
    const r = try runE2e(bit8_tta, bit8_golden);
    try testing.expectEqual(@as(u32, 48000), r.sr);
    try testing.expectEqual(@as(u8, 1), r.ch);
    try testing.expectEqual(@as(u8, 8), r.bits);
    try testing.expectEqual(bit8_golden.len, r.bytes);
    try testing.expectEqual(bit8_golden.len, r.equal);
}

test "tta 结构: 头/帧表解析与帧独立 seek（7000ms → 帧 6 中段解码 == 全流同区段）" {
    const a = testing.allocator;
    var r = io.Reader.openMem(inside_tta);
    var info: decoder.Info = undefined;
    var d = try open(a, &r, &info);
    defer d.deinit();
    try testing.expectEqual(@as(u32, 44100), info.sample_rate);
    try testing.expectEqual(@as(u8, 2), info.channels);
    try testing.expectEqualStrings("tta", info.codec_name);
    try testing.expectEqualStrings("tta", info.format_name);
    try testing.expectEqual(@as(i64, 11_888_367), info.duration_us); // 524277/44100

    // 全流解码
    var all = std.ArrayList(u8).empty;
    defer all.deinit(a);
    var buf: [65536]u8 = undefined;
    while (true) {
        var ch: u8 = 0;
        const n = try d.read(&buf, 4096, &ch);
        if (n == 0) break;
        try all.appendSlice(a, buf[0 .. n * @as(usize, ch) * 2]);
    }
    try testing.expectEqual(inside_golden.len, all.items.len);

    // 随机访问帧边界：seek 7000ms → 样本 7000×44100/1000 = 308700（帧 6 内）
    try d.seekMs(7000);
    var seg = std.ArrayList(u8).empty;
    defer seg.deinit(a);
    while (true) {
        var ch: u8 = 0;
        const n = try d.read(&buf, 4096, &ch);
        if (n == 0) break;
        try seg.appendSlice(a, buf[0 .. n * @as(usize, ch) * 2]);
    }
    const target_sample: usize = 7000 * 44100 / 1000;
    try testing.expect(seg.items.len <= inside_golden.len - target_sample * 4);
    try testing.expectEqualSlices(u8, inside_golden[target_sample * 4 .. target_sample * 4 + seg.items.len], seg.items);
}

test "tta 健壮性: 截断/非法头 → Corrupt，format=2/非法位深 → UnsupportedFormat" {
    // 截断（不足 22 字节）
    var r0 = io.Reader.openMem(inside_tta[0..10]);
    var info: decoder.Info = undefined;
    try testing.expectError(error.Corrupt, open(testing.allocator, &r0, &info));

    // 帧表越过文件尾 → Corrupt（把 data_length 改到超大）
    var bad = [_]u8{0} ** 64;
    @memcpy(bad[0..4], "TTA1");
    std.mem.writeInt(u16, bad[4..6], 1, .little);
    std.mem.writeInt(u16, bad[6..8], 2, .little);
    std.mem.writeInt(u16, bad[8..10], 16, .little);
    std.mem.writeInt(u32, bad[10..14], 44100, .little);
    std.mem.writeInt(u32, bad[14..18], 0xFFFFFFFF, .little);
    var r1 = io.Reader.openMem(&bad);
    try testing.expectError(error.Corrupt, open(testing.allocator, &r1, &info));

    // format=2（加密）→ UnsupportedFormat
    var enc = [_]u8{0} ** 22;
    @memcpy(enc[0..4], "TTA1");
    std.mem.writeInt(u16, enc[4..6], 2, .little);
    std.mem.writeInt(u16, enc[6..8], 1, .little);
    std.mem.writeInt(u16, enc[8..10], 16, .little);
    std.mem.writeInt(u32, enc[10..14], 44100, .little);
    std.mem.writeInt(u32, enc[14..18], 44100, .little);
    var r2 = io.Reader.openMem(&enc);
    try testing.expectError(error.UnsupportedFormat, open(testing.allocator, &r2, &info));

    // 非法位深（32bit → bps 4，ffmpeg 不支持）→ UnsupportedFormat
    var b32 = [_]u8{0} ** 22;
    @memcpy(b32[0..4], "TTA1");
    std.mem.writeInt(u16, b32[4..6], 1, .little);
    std.mem.writeInt(u16, b32[6..8], 1, .little);
    std.mem.writeInt(u16, b32[8..10], 32, .little);
    std.mem.writeInt(u32, b32[10..14], 44100, .little);
    std.mem.writeInt(u32, b32[14..18], 44100, .little);
    var r3 = io.Reader.openMem(&b32);
    try testing.expectError(error.UnsupportedFormat, open(testing.allocator, &r3, &info));
}

test "tta 纯函数: 帧解码独立性与位深输出布局" {
    const a = testing.allocator;
    // mono.tta 首帧解码 == golden 前 46080×2 字节
    var fd = try core.FrameDecoder.init(a, 1, 2);
    defer fd.deinit();
    const mono_hdr = blk: {
        const hdr = try parseHeader(mono_tta);
        break :blk hdr;
    };
    const frames = try parseFrames(a, mono_tta, &mono_hdr);
    defer a.free(frames.offsets);
    const s = frames.offsets[0];
    const e = frames.offsets[1];
    const body = mono_tta[@intCast(s)..@intCast(e - 4)];
    const out = try a.alloc(u8, 46080 * 2);
    defer a.free(out);
    var br = core.BitReader.init(body);
    try fd.decode(&br, 2, 46080, out);
    try testing.expectEqualSlices(u8, mono_golden[0 .. 46080 * 2], out);
}
