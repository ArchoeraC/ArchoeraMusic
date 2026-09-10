// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! MPEG-4 ALS 解码器封装（fmt/m4a 委托 inner 解码器；VTable）
//!
//! m4a 合成「原始 ALS 帧流」（mp4 sample 数据直拼，可为每包多帧）后经本模块打开：
//!   - 配置由 fmt/m4a 解析 stsd esds 得到（SpecificConfig，见 core.parseConfig）；
//!   - open 将整条流读入内存（含 64B 尾填充，对齐 ffmpeg 的
//!     AV_INPUT_BUFFER_PADDING_SIZE 语义），core.Decoder 逐帧解码；
//!   - 帧样本可能大于单次 read 请求量（如 frame_length 20480）：已解码帧保留，
//!     按游标分批输出，与 flac/ac3 委托 inner 同型。
//!
//! 输出：位深 ≤16 → 交错 s16（左移对齐满幅）；>16 → s32。与 ffmpeg 输出一致。

const std = @import("std");
const Error = @import("../../error.zig").Error;
const io = @import("../../io.zig");
const decoder = @import("../../decoder.zig");
const core = @import("core.zig");

const Allocator = std.mem.Allocator;
const VTable = decoder.Decoder.VTable;

pub const SpecificConfig = core.SpecificConfig;

/// 解析 stsd esds DecoderSpecificInfo → ALS 特定配置（无 ALS 特征返回 null）
pub fn tryParseConfig(dsi: []const u8) Error!?SpecificConfig {
    return core.parseConfig(dsi) catch |err| switch (err) {
        error.UnsupportedFormat => null,
        else => return err,
    };
}

pub fn parseConfig(dsi: []const u8) Error!SpecificConfig {
    return core.parseConfig(dsi);
}

const AlsCtx = struct {
    allocator: Allocator,
    cfg: core.SpecificConfig,
    /// 帧流（含 64B 零填充尾）
    stream: []u8,
    stream_len: usize,
    dec: core.Decoder,
    /// 输出参数
    sample_rate: u32,
    channels: u8,
    out_bps: u8,
    /// 当前帧输出游标
    cur_samples: usize = 0,
    emit_pos: usize = 0,
    /// 已输出样本总数（position）
    samples_done: u64 = 0,
};

pub fn open(allocator: Allocator, cfg: core.SpecificConfig, reader: *io.Reader, info: *decoder.Info) Error!decoder.Decoder {
    // 读整条流
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);
    var tmp: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try reader.read(&tmp);
        if (n == 0) break;
        try list.appendSlice(allocator, tmp[0..n]);
    }
    const stream_len = list.items.len;
    const padded = try allocator.alloc(u8, stream_len + 64);
    errdefer allocator.free(padded);
    @memcpy(padded[0..stream_len], list.items[0..stream_len]);
    @memset(padded[stream_len..], 0);

    const ctx = try allocator.create(AlsCtx);
    errdefer allocator.destroy(ctx);
    var dec = try core.Decoder.init(allocator, cfg, padded, stream_len);
    errdefer dec.deinit();

    ctx.* = .{
        .allocator = allocator,
        .cfg = cfg,
        .stream = padded,
        .stream_len = stream_len,
        .dec = dec,
        .sample_rate = cfg.sample_rate,
        .channels = @intCast(cfg.channels),
        .out_bps = if (cfg.bits_per_raw_sample <= 16) 16 else 32,
    };
    info.* = .{
        .sample_rate = cfg.sample_rate,
        .channels = @intCast(cfg.channels),
        .bits_per_sample = ctx.out_bps,
        .is_float = false,
        .duration_us = durationUs(cfg),
        .duration_known = if (cfg.samples != 0xFFFFFFFF) .exact else .estimate,
        .codec_name = "mp4als",
        .format_name = "m4a",
        .metadata = .{},
    };
    return .{ .vtable = &vtable, .ctx = @ptrCast(ctx) };
}

fn durationUs(cfg: core.SpecificConfig) i64 {
    if (cfg.samples == 0xFFFFFFFF or cfg.sample_rate == 0) return 0;
    return @intCast((@as(u128, cfg.samples) * 1_000_000) / cfg.sample_rate);
}

const vtable = VTable{
    .read = readImpl,
    .seek_ms = seekMsImpl,
    .position_ms = positionMsImpl,
    .deinit = deinitImpl,
};

fn readImpl(ctx: *anyopaque, out: []u8, max_samples: usize, out_channels: *u8) Error!usize {
    const f: *AlsCtx = @ptrCast(@alignCast(ctx));
    out_channels.* = f.channels;
    if (max_samples == 0 or out.len == 0) return 0;
    const frame_bytes = @as(usize, f.channels) * (f.out_bps / 8);
    if (frame_bytes == 0) return error.Corrupt;
    const cap = @min(max_samples, out.len / frame_bytes);
    var produced: usize = 0;
    while (produced < cap) {
        if (f.emit_pos < f.cur_samples) {
            const avail = f.cur_samples - f.emit_pos;
            const take = @min(avail, cap - produced);
            f.dec.interleaveOut(out[produced * frame_bytes ..], f.emit_pos, take);
            f.emit_pos += take;
            f.samples_done += take;
            produced += take;
        } else {
            const n = f.dec.decodeOne() catch |err| return err;
            if (n) |samples| {
                f.cur_samples = samples;
                f.emit_pos = 0;
            } else {
                break; // EOF
            }
        }
    }
    return produced;
}

fn seekMsImpl(ctx: *anyopaque, ms: i64) Error!void {
    const f: *AlsCtx = @ptrCast(@alignCast(ctx));
    if (ms <= 0) {
        try resetDecoder(f);
        return;
    }
    try resetDecoder(f);
    const target: u64 = @intCast((@as(u128, @intCast(ms)) * f.sample_rate) / 1000);
    const frame_bytes = @as(usize, f.channels) * (f.out_bps / 8);
    var scratch: [2048 * 2 * 4]u8 = undefined;
    var left = target;
    var guard: usize = 0;
    while (left > 0) {
        guard += 1;
        if (guard > 1_000_000_000) return error.SeekFailed;
        var ch: u8 = 0;
        const want: usize = @intCast(@min(left, @as(u64, scratch.len / frame_bytes)));
        const n = try readImpl(f, scratch[0 .. want * frame_bytes], want, &ch);
        if (n == 0) break;
        left -= @min(left, n);
    }
}

fn positionMsImpl(ctx: *anyopaque) i64 {
    const f: *AlsCtx = @ptrCast(@alignCast(ctx));
    if (f.sample_rate == 0) return 0;
    return @intCast((@as(u128, f.samples_done) * 1000) / f.sample_rate);
}

fn deinitImpl(ctx: *anyopaque) void {
    const f: *AlsCtx = @ptrCast(@alignCast(ctx));
    f.dec.deinit();
    f.allocator.free(f.stream);
    f.allocator.destroy(f);
}

fn resetDecoder(f: *AlsCtx) Error!void {
    f.dec.deinit();
    f.dec = try core.Decoder.init(f.allocator, f.cfg, f.stream, f.stream_len);
    f.cur_samples = 0;
    f.emit_pos = 0;
    f.samples_done = 0;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------
const testing = std.testing;

test "parseConfig: 识别非 ALS 数据返回 null" {
    // AOT = AAC-LC (2) 的 5 字节 DSI 形态
    const aac_dsi = [_]u8{ 0x11, 0x90, 0x00, 0x00, 0x00 };
    try testing.expectEqual(@as(?SpecificConfig, null), try tryParseConfig(&aac_dsi));
}
