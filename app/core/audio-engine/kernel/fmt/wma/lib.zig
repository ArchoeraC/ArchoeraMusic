// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! WMA（ASF → wmav1/wmav2/wmapro/wmalossless/wmavoice）解码器正式接入层。
//!
//! open：整读 ASF 文件 → 头解析 → Data 包重组 → 按 codec_tag 分派：
//!   0x160/161 → wmadec（本文件 wmav1/wmav2，s16 输出）
//!   0x162 → wmapro/lib.zig（S16P）
//!   0x163 → wmalossless/lib.zig（s16 / 24bit<<8 s32，与 ffmpeg 逐位一致）
//!   0x000A → wmavoice/lib.zig（WMA Voice，s16；内部 float 合成滤波+APF）
//! 其余见各自子模块头部说明。wmav1/wmav2 支持采样率 8k–48k、单/双声道、
//! 帧长 512/1024/2048，LSP/exp-VLC 指数与低码率噪声编码；bit_reservoir /
//! variable_block_len 等 ffmpeg 编码器不置位的 flag → error.UnsupportedFormat
//! （引擎回退 FFmpeg）。

const std = @import("std");
const Error = @import("../../error.zig").Error;
const io = @import("../../io.zig");
const decoder = @import("../../decoder.zig");
const asf = @import("asf.zig");
const packets = @import("packets.zig");
const wmadec = @import("wmadec.zig");
const wmapro = @import("wmapro/lib.zig");
const wmalossless = @import("wmalossless/lib.zig");
const wmavoice = @import("wmavoice/lib.zig");

const WmaCtx = struct {
    allocator: std.mem.Allocator,
    file_data: []u8, // 整文件（owned）
    objs: []u8, // superframe 缓冲（owned）
    pcm: []i16, // 交错 s16（解码结果）
    sample_rate: u32,
    channels: u8,
    total_frames: usize, // 每声道样本数
    cursor: usize = 0, // 已输出交错样本（= 每声道样本计数）

    fn sampleToMs(self: *const WmaCtx, samples: usize) i64 {
        return @intCast(@divTrunc(@as(i128, @intCast(samples)) * 1000, @as(i128, self.sample_rate)));
    }
    fn read(self: *WmaCtx, out: []u8, max_samples: usize, out_channels: *u8) Error!usize {
        out_channels.* = self.channels;
        const n = @min(max_samples, self.total_frames - self.cursor);
        if (n == 0) return 0;
        const bytes = n * @as(usize, self.channels) * 2;
        if (out.len < bytes) return error.Corrupt;
        std.mem.copyForwards(u8, out[0..bytes], std.mem.sliceAsBytes(self.pcm[self.cursor * self.channels ..][0 .. n * self.channels]));
        self.cursor += n;
        return n;
    }
};

fn toS16(x: f32) i16 {
    var v: f64 = @round(@as(f64, x) * 32768.0);
    if (v > 32767.0) v = 32767.0;
    if (v < -32768.0) v = -32768.0;
    return @intFromFloat(v);
}

const vtable = decoder.Decoder.VTable{
    .read = read,
    .seek_ms = seekMs,
    .position_ms = positionMs,
    .deinit = deinit,
};

fn read(ctx: *anyopaque, out: []u8, max_samples: usize, out_channels: *u8) Error!usize {
    const self: *WmaCtx = @ptrCast(@alignCast(ctx));
    return self.read(out, max_samples, out_channels);
}

fn seekMs(ctx: *anyopaque, ms: i64) Error!void {
    const self: *WmaCtx = @ptrCast(@alignCast(ctx));
    if (ms <= 0) {
        self.cursor = 0;
        return;
    }
    const target = @as(u64, @intCast(ms)) * self.sample_rate / 1000;
    self.cursor = @min(@as(usize, @intCast(target)), self.total_frames);
}

fn positionMs(ctx: *anyopaque) i64 {
    const self: *WmaCtx = @ptrCast(@alignCast(ctx));
    return self.sampleToMs(self.cursor);
}

fn deinit(ctx: *anyopaque) void {
    const self: *WmaCtx = @ptrCast(@alignCast(ctx));
    const a = self.allocator;
    a.free(self.file_data);
    a.free(self.objs);
    a.free(self.pcm);
    a.destroy(self);
}

/// 解码 .wma（ASF）整文件；成功时 Decoder 接管 `reader` 所有权（deinit 关闭）。
pub fn open(allocator: std.mem.Allocator, reader: *io.Reader, info: *decoder.Info) Error!decoder.Decoder {
    const sz = reader.size() catch return error.Corrupt;
    if (sz <= 0 or sz > 256 * 1024 * 1024) return error.UnsupportedFormat;
    const file_data = try allocator.alloc(u8, @intCast(sz));
    errdefer allocator.free(file_data);
    var got: usize = 0;
    while (got < file_data.len) {
        const n = try reader.read(file_data[got..]);
        if (n == 0) break;
        got += n;
    }
    const data: []const u8 = file_data[0..got];
    const hdr = try asf.parseHeader(data);
    const audio = hdr.audio.?;

    // wmapro（0x162）/ wmalossless（0x163）/ wmavoice（0x000A）由独立子模块处理
    // （同一 ASF 容器、不同 bitstream）。
    if (audio.codec_tag == 0x0162) {
        return wmapro.openFromAsf(allocator, file_data, &hdr, info);
    }
    if (audio.codec_tag == 0x0163) {
        return wmalossless.openFromAsf(allocator, file_data, &hdr, info);
    }
    if (audio.codec_tag == 0x000A) {
        return wmavoice.openFromAsf(allocator, file_data, &hdr, info);
    }

    if (audio.channels == 0 or audio.channels > 2) return error.UnsupportedFormat;
    if (audio.sample_rate > 48000 or audio.sample_rate < 8000) return error.UnsupportedFormat;

    const ctx = try allocator.create(WmaCtx);
    errdefer allocator.destroy(ctx);
    ctx.* = .{
        .allocator = allocator,
        .file_data = file_data,
        .objs = &.{},
        .pcm = &.{},
        .sample_rate = audio.sample_rate,
        .channels = audio.channels,
        .total_frames = 0,
    };

    const block_align: usize = audio.block_align;
    if (block_align == 0) return error.Corrupt;
    const max_objs: usize = (data.len / block_align) + 8;
    const objs = try allocator.alloc(u8, max_objs * block_align);
    errdefer allocator.free(objs);
    const nobj = try packets.demuxSuperframes(data, &hdr, objs);
    if (nobj == 0) return error.Corrupt;
    ctx.objs = objs[0 .. nobj * block_align];

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

    // 容量：解码帧数 ≤ nobj（丢弃前 2 个 priming）＋ flush 尾帧
    const cap_frames: usize = if (nobj > 2) nobj - 2 + 1 else 1;
    const pcm_cap = try allocator.alloc(i16, cap_frames * fl * audio.channels);
    errdefer allocator.free(pcm_cap);
    var nframes: usize = 0;
    var frame: [2 * 2048]f32 align(4) = undefined;
    var i: usize = 0;
    while (i < nobj) : (i += 1) {
        if (i < 2) { // 丢弃解码器前两个 priming superframe（对齐 ffmpeg 输出）
            _ = dec.decodeSuperframe(ctx.objs[i * block_align ..][0..block_align], &frame) catch {};
            continue;
        }
        _ = try dec.decodeSuperframe(ctx.objs[i * block_align ..][0..block_align], frame[0 .. fl * audio.channels]);
        for (0..fl) |s| {
            for (0..audio.channels) |c| {
                const idx = nframes * fl * audio.channels + s * audio.channels + c;
                pcm_cap[idx] = toS16(frame[c * fl + s]);
            }
        }
        nframes += 1;
    }
    // EOF flush（重叠尾帧）
    dec.flush(frame[0 .. fl * audio.channels]);
    for (0..fl) |s| {
        for (0..audio.channels) |c| {
            const idx = nframes * fl * audio.channels + s * audio.channels + c;
            pcm_cap[idx] = toS16(frame[c * fl + s]);
        }
    }
    nframes += 1;

    ctx.pcm = pcm_cap[0 .. nframes * fl * audio.channels];
    ctx.total_frames = nframes * fl;

    // 时长：容器头自洽 → play_duration − preroll（= ffprobe format duration，
    // 含编码器 priming）；截断等自洽性不满足 → 预解码样本总数（实际可播时长）。
    // 两者均为 exact（预解码即全量输出，无估算）。
    const container_us = asf.containerDurationUs(file_data, &hdr);
    const decoded_us: i64 = @intCast(@divTrunc(@as(i128, @intCast(ctx.total_frames)) * 1_000_000, @as(i128, audio.sample_rate)));

    info.* = .{
        .sample_rate = audio.sample_rate,
        .channels = audio.channels,
        .bits_per_sample = 16,
        .is_float = false,
        .duration_us = container_us orelse decoded_us,
        .duration_known = .exact,
        .codec_name = if (params.version == 1) "wmav1" else "wmav2",
        .format_name = "asf",
        .metadata = .{},
    };

    return .{ .vtable = &vtable, .ctx = ctx };
}
