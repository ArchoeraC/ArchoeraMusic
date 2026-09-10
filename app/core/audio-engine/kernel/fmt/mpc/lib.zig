// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Musepack 解码器接入层（fmt/mpc）—— SV7/SV8 均已 bit-exact（对照 ffmpeg n9.0.1）。
//!
//! 容器：SV8 = MPCK chunk 流（SH 头 + AP 音频包），SV7 = MP+ 打包帧。
//! 本层把整个输入读入内存后交给 fmt/mpc/sv8.zig / sv7.zig。输出原生 16-bit
//! 交错 PCM。
//!
//! 支持面：SV7/SV8 44100/48000/37800/32000、立体声（SV7 恒 2 声道）、
//! 已用 FATE inside-mp7.mpc / inside-mp8.mpc 全流逐位对齐 ffmpeg `-f s16le`。

const std = @import("std");

const Error = @import("../../error.zig").Error;
const io = @import("../../io.zig");
const decoder = @import("../../decoder.zig");

const sv7 = @import("sv7.zig");
const sv8 = @import("sv8.zig");
const apev2 = @import("../apev2.zig");

/// 每音频帧每声道样本数（MPC_FRAME_SIZE，36 子带时间 × 32）
const SAMPLES_PER_FRAME = 1152;

/// SV7/SV8 解码器分派
const DecUnion = union(enum) {
    v7: sv7.Decoder7,
    v8: sv8.Decoder8,

    fn next(d: *DecUnion, out: *[2][SAMPLES_PER_FRAME]i16) bool {
        return switch (d.*) {
            inline else => |*impl| impl.next(out),
        };
    }

    fn deinit(d: *DecUnion) void {
        switch (d.*) {
            inline else => |*impl| impl.deinit(),
        }
    }
};

const DecoderCtx = struct {
    allocator: std.mem.Allocator,
    reader: io.Reader,
    /// 整个输入文件（生命周期覆盖解码；deinit 释放）
    data: []u8,
    dec: DecUnion,
    channels: u8 = 2,
    sample_rate: u32 = 44100,

    /// 已解码待输出的当前帧平面缓冲
    queued: [2][SAMPLES_PER_FRAME]i16 = undefined,
    /// 当前帧内已输出的样本起始偏移（seek 后可能非 0）
    queued_pos: usize = SAMPLES_PER_FRAME,
    have_queued: bool = false,
    eof: bool = false,
    /// 已输出（含 seek 跳过）的样本帧计数（每声道）
    samples_done: u64 = 0,
};

pub fn open(allocator: std.mem.Allocator, reader: *io.Reader, info: *decoder.Info) Error!decoder.Decoder {
    // 读入整个文件（SV7 帧链/SV8 跨 chunk 帧间状态均需随机访问）
    const fsize: usize = @intCast(try reader.size());
    if (fsize < 8) return error.Corrupt;
    const data = try allocator.alloc(u8, fsize);
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

    // SV8（MPCK chunk 流）
    if (std.mem.eql(u8, data[0..4], "MPCK")) {
        const ctx = try allocator.create(DecoderCtx);
        errdefer allocator.destroy(ctx);
        ctx.* = .{ .allocator = allocator, .reader = reader.*, .data = data, .dec = undefined };
        ctx.dec = .{ .v8 = try sv8.Decoder8.init(allocator, data) };
        errdefer ctx.dec.deinit();
        const cfg = &ctx.dec.v8.parsed.cfg;
        ctx.channels = cfg.channels;
        ctx.sample_rate = cfg.sample_rate;
        if (cfg.channels == 0 or cfg.channels > 2) return error.Corrupt;

        // SH 声明样本总数 → 时长（SV8 尾部可能补整帧，实际略长于声明）
        const dur_us: i64 = @intCast((@as(u128, @intCast(cfg.total_samples)) * 1_000_000) / cfg.sample_rate);
        info.* = .{
            .sample_rate = cfg.sample_rate,
            .channels = cfg.channels,
            .bits_per_sample = 16,
            .is_float = false,
            .duration_us = dur_us,
            .duration_known = .exact,
            .codec_name = "mpc8",
            .format_name = "mpc8",
            .metadata = .{},
        };
        return .{ .vtable = &vtable, .ctx = ctx };
    }

    // SV7（MP+ 打包帧流）
    if (std.mem.eql(u8, data[0..3], "MP+")) {
        const ctx = try allocator.create(DecoderCtx);
        errdefer allocator.destroy(ctx);
        ctx.* = .{ .allocator = allocator, .reader = reader.*, .data = data, .dec = undefined };
        ctx.dec = .{ .v7 = try sv7.Decoder7.init(allocator, data) };
        errdefer ctx.dec.deinit();
        const cfg = &ctx.dec.v7.parsed.cfg;
        ctx.channels = 2; // SV7 恒立体声（mpc7.c AV_CHANNEL_LAYOUT_STEREO）
        ctx.sample_rate = cfg.sample_rate;

        // 时长按实际可解出的整帧数（等于 ffmpeg 输出帧数；见 sv7.zig
        // 模块注释——末帧截断路径经 demux 不可达，输出恒为整帧）
        const total_frames: u64 = ctx.dec.v7.parsed.frames.len;
        const dur_us: i64 = @intCast((total_frames * SAMPLES_PER_FRAME * 1_000_000) / cfg.sample_rate);
        info.* = .{
            .sample_rate = cfg.sample_rate,
            .channels = 2,
            .bits_per_sample = 16,
            .is_float = false,
            .duration_us = dur_us,
            .duration_known = .exact,
            .codec_name = "mpc7",
            .format_name = "mpc7",
            .metadata = .{},
        };
        return .{ .vtable = &vtable, .ctx = ctx };
    }

    return error.Corrupt;
}

const VTable = decoder.Decoder.VTable;
const vtable = VTable{
    .read = readImpl,
    .seek_ms = seekMsImpl,
    .position_ms = positionMsImpl,
    .deinit = deinitImpl,
};

// ---------------------------------------------------------------------------
// 元数据专用快路径（probe-only，§8.4.2①）：整读文件后仅调 sv7/sv8 `parse`
// （头 + 帧表/AP 列表，不解音频），尾部 APEv2 标签；不构造 VLC/合成器状态。
// ---------------------------------------------------------------------------

const Parsed = union(enum) {
    v7: sv7.Parsed,
    v8: sv8.Parsed,

    fn deinit(self: *Parsed) void {
        switch (self.*) {
            .v7 => |*p| p.deinit(),
            .v8 => |*p| p.deinit(),
        }
    }
};

const MetaCtx = struct {
    allocator: std.mem.Allocator,
    reader: io.Reader,
    data: []u8,
    parsed: Parsed,
    tags: apev2.Tags = .{},
};

fn metaDeinit(p: *anyopaque) void {
    const ctx: *MetaCtx = @ptrCast(@alignCast(p));
    ctx.tags.deinit(ctx.allocator);
    ctx.parsed.deinit();
    ctx.allocator.free(ctx.data);
    ctx.reader.deinit();
    ctx.allocator.destroy(ctx);
}

pub fn openMeta(allocator: std.mem.Allocator, reader: *io.Reader, info: *decoder.Info) Error!decoder.MetadataSession {
    const fsize: usize = @intCast(try reader.size());
    if (fsize < 8) return error.Corrupt;
    const data = try allocator.alloc(u8, fsize);
    errdefer allocator.free(data);
    var got: usize = 0;
    while (got < fsize) {
        const n = reader.read(data[got..]) catch return error.IoError;
        if (n == 0) break;
        got += n;
    }
    if (got < fsize) return error.Corrupt;

    var sample_rate: u32 = 0;
    var channels: u8 = 0;
    var codec_name: [:0]const u8 = "";
    var duration_us: i64 = 0;
    var duration_known: decoder.DurationKnown = .exact;
    var parsed: Parsed = undefined;

    if (std.mem.eql(u8, data[0..4], "MPCK")) {
        var p8 = try sv8.parse(data, allocator);
        errdefer p8.deinit();
        sample_rate = p8.cfg.sample_rate;
        channels = p8.cfg.channels;
        codec_name = "mpc8";
        if (p8.cfg.total_samples > 0 and sample_rate > 0) {
            duration_us = @intCast((@as(u128, @intCast(p8.cfg.total_samples)) * 1_000_000) / sample_rate);
        } else {
            duration_known = .unknown;
        }
        parsed = .{ .v8 = p8 };
    } else if (std.mem.eql(u8, data[0..3], "MP+")) {
        var p7 = try sv7.parse(data, allocator);
        errdefer p7.deinit();
        sample_rate = p7.cfg.sample_rate;
        channels = 2; // SV7 恒立体声
        codec_name = "mpc7";
        const total_frames: u64 = p7.frames.len;
        if (sample_rate > 0) {
            duration_us = @intCast((total_frames * SAMPLES_PER_FRAME * 1_000_000) / sample_rate);
        } else {
            duration_known = .unknown;
        }
        parsed = .{ .v7 = p7 };
    } else {
        return error.Corrupt;
    }

    const ctx = try allocator.create(MetaCtx);
    errdefer allocator.destroy(ctx);
    ctx.* = .{ .allocator = allocator, .reader = reader.*, .data = data, .parsed = parsed };
    errdefer ctx.tags.deinit(allocator);

    const fsize64 = try reader.size();
    ctx.tags = apev2.parse(allocator, reader, fsize64) catch .{};

    info.* = .{
        .sample_rate = sample_rate,
        .channels = channels,
        .bits_per_sample = 16,
        .is_float = false,
        .duration_us = duration_us,
        .duration_known = duration_known,
        .codec_name = codec_name,
        .format_name = codec_name,
        .metadata = ctx.tags.meta,
    };
    return .{ .ctx = @ptrCast(ctx), .deinit_fn = metaDeinit };
}

fn readImpl(ctx: *anyopaque, out: []u8, max_samples: usize, out_channels: *u8) Error!usize {
    const f: *DecoderCtx = @ptrCast(@alignCast(ctx));
    out_channels.* = f.channels;
    if (max_samples == 0 or out.len == 0) return 0;
    if (f.eof) return 0;

    const frame_bytes = @as(usize, f.channels) * 2;
    const cap = @min(max_samples, out.len / frame_bytes);
    var produced: usize = 0;
    while (produced < cap) {
        if (!f.have_queued) {
            if (!f.dec.next(&f.queued)) {
                f.eof = true;
                break;
            }
            f.queued_pos = 0;
            f.have_queued = true;
        }
        const avail = SAMPLES_PER_FRAME - f.queued_pos;
        const take = @min(avail, cap - produced);
        const dst = out[produced * frame_bytes ..][0 .. take * frame_bytes];
        for (0..take) |s| {
            const src = f.queued_pos + s;
            for (0..f.channels) |c| {
                std.mem.writeInt(i16, dst[(s * f.channels + c) * 2 ..][0..2], f.queued[c][src], .little);
            }
        }
        f.queued_pos += take;
        if (f.queued_pos >= SAMPLES_PER_FRAME) f.have_queued = false;
        produced += take;
    }
    f.samples_done += produced;
    return produced;
}

fn seekMsImpl(ctx: *anyopaque, ms: i64) Error!void {
    const f: *DecoderCtx = @ptrCast(@alignCast(ctx));
    if (f.sample_rate == 0) return;
    const target: u64 = if (ms <= 0) 0 else @intCast((@as(u128, @intCast(ms)) * f.sample_rate) / 1000);

    const intra = target % SAMPLES_PER_FRAME;
    switch (f.dec) {
        .v8 => |*d| {
            // 无 seek 表：SV8 帧间合成滤波状态跨帧持续，需自文件头解码重建。
            // 丢弃到目标前的整帧，保留含目标的帧并从其中间开始输出。
            const frames_to_skip = target / SAMPLES_PER_FRAME;
            const fresh = try sv8.Decoder8.init(f.allocator, f.data);
            d.deinit();
            d.* = fresh;

            var n: usize = 0;
            while (n < frames_to_skip) : (n += 1) {
                if (!d.next(&f.queued)) break;
            }
            if (n < frames_to_skip) {
                // seek 越过流末尾：置 EOF，停在末尾
                f.eof = true;
                f.have_queued = false;
                f.queued_pos = SAMPLES_PER_FRAME;
                f.samples_done = @intCast(n * SAMPLES_PER_FRAME + intra);
                return;
            }
            if (d.next(&f.queued)) {
                f.queued_pos = @intCast(intra);
                f.have_queued = true;
                f.eof = false;
                f.samples_done = target;
            } else {
                f.eof = true;
                f.have_queued = false;
                f.queued_pos = SAMPLES_PER_FRAME;
                f.samples_done = target;
            }
        },
        .v7 => |*d| {
            // FFmpeg mpc seek 语义（libavformat/mpc.c DELAY_FRAMES + mpc7.c
            // decode_flush）：oldDSCF 清零、自 max(frame-32, 0) 起解码并丢弃
            // 输出（预热重建状态），自目标帧起输出。已验证与
            // `ffmpeg -ss x -i in.mpc`（in-seek）输出逐位一致（见 sv7.zig）。
            // 差异：帧号 < 32 时本实现预热 min(32, frame) 帧（FFmpeg 会把目标
            // 帧一并丢弃，输出从第 32 帧开始——CLI 边缘缺陷，此处不从）。
            // 另：目标落在帧中间时本实现自该样本精确起播（ffmpeg in-seek 按
            // 整帧对齐，属 CLI 丢弃逻辑，非解码器语义）。
            const frame_idx = target / SAMPLES_PER_FRAME;
            const fresh = try sv7.Decoder7.init(f.allocator, f.data);
            d.deinit();
            d.* = fresh;
            const warmup: u64 = @min(frame_idx, sv7.DELAY_FRAMES);
            // 直接跳到预热起点帧（不解码之前的内容：LFG/oldDSCF 状态按
            // "全新会话 + flush" 语义重建，与 ffmpeg -ss 一致）
            d.resetTo(@intCast(frame_idx - warmup));

            var k: u64 = frame_idx - warmup;
            while (k < frame_idx) : (k += 1) {
                if (!d.next(&f.queued)) break;
            }
            if (k == frame_idx and d.next(&f.queued)) {
                f.queued_pos = @intCast(intra);
                f.have_queued = true;
                f.eof = false;
                f.samples_done = target;
            } else {
                // seek 越过流末尾：置 EOF，停在末尾
                f.eof = true;
                f.have_queued = false;
                f.queued_pos = SAMPLES_PER_FRAME;
                f.samples_done = target;
            }
        },
    }
}

fn positionMsImpl(ctx: *anyopaque) i64 {
    const f: *DecoderCtx = @ptrCast(@alignCast(ctx));
    if (f.sample_rate == 0) return 0;
    return @intCast((@as(u128, f.samples_done) * 1000) / f.sample_rate);
}

fn deinitImpl(ctx: *anyopaque) void {
    const f: *DecoderCtx = @ptrCast(@alignCast(ctx));
    f.dec.deinit();
    f.reader.deinit();
    f.allocator.free(f.data);
    f.allocator.destroy(f);
}

// ---------------------------------------------------------------------------
// 单测
// ---------------------------------------------------------------------------

const testing = std.testing;

/// FATE SV8（44.1k 双声道，456 帧）+ ffmpeg `-f s16le` 参考 PCM
const inside_mp8 = @embedFile("samples/inside-mp8.mpc");
const inside_mp8_s16 = @embedFile("samples/inside-mp8.s16");
/// FATE SV7（44.1k 双声道，456 帧）+ ffmpeg `-f s16le` 参考 PCM（截段）
const inside_mp7 = @embedFile("samples/inside-mp7.mpc");
/// ffmpeg 参考前 1 秒（44100 样本 ×2ch×2B；md5 9a0438306ba1ff379e609af17bcee3ef）
const inside_mp7_first1s = @embedFile("samples/inside-mp7.first1s.s16");
/// ffmpeg `-ss 5.016 -i`（in-seek）参考自样本 221205（帧 192+21）起 1 秒
const inside_mp7_seek5s = @embedFile("samples/inside-mp7.seek5s.s16");
/// ffmpeg 全流参考 PCM md5（2101248 字节 = 456 帧 × 1152 × 2ch × 2B）
const inside_mp7_full_md5 = "80ff10b054d4ae77aee0461758a6cd6e";

test "sv8: inside-mp8 全流解码 → 与 ffmpeg 参考 PCM 逐位一致" {
    const alloc = testing.allocator;
    var r = io.Reader.openMem(inside_mp8);
    var info: decoder.Info = undefined;
    var d = try open(alloc, &r, &info);
    defer d.deinit();

    try testing.expectEqual(@as(u32, 44100), info.sample_rate);
    try testing.expectEqual(@as(u8, 2), info.channels);
    try testing.expectEqualStrings("mpc8", info.codec_name);
    try testing.expectEqualStrings("mpc8", info.format_name);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    var buf: [65536]u8 = undefined;
    while (true) {
        var ch: u8 = 0;
        const n = try d.read(&buf, 4096, &ch);
        if (n == 0) break;
        try out.appendSlice(alloc, buf[0 .. n * @as(usize, ch) * 2]);
    }
    try testing.expectEqual(inside_mp8_s16.len, out.items.len);
    try testing.expectEqualSlices(u8, inside_mp8_s16, out.items);
}

test "sv8: seek 到中段后解码（与参考 PCM 中段一致）" {
    const alloc = testing.allocator;
    var r = io.Reader.openMem(inside_mp8);
    var info: decoder.Info = undefined;
    var d = try open(alloc, &r, &info);
    defer d.deinit();

    // 定位到 5.0 s 处（44100 Hz → 目标样本 220500，越过 chunk/keyframe 边界）
    const target_sample: u64 = (5000 * 44100) / 1000;
    try d.seekMs(5000);
    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    var buf: [65536]u8 = undefined;
    while (true) {
        var ch: u8 = 0;
        const n = try d.read(&buf, 4096, &ch);
        if (n == 0) break;
        try out.appendSlice(alloc, buf[0 .. n * @as(usize, ch) * 2]);
    }
    // 参考 PCM 对应偏移（目标样本 ×2ch×2B）
    const want_off = @as(usize, @intCast(target_sample)) * 4;
    try testing.expect(want_off + out.items.len <= inside_mp8_s16.len);
    try testing.expectEqualSlices(u8, inside_mp8_s16[want_off .. want_off + out.items.len], out.items);
}

test "sv7: Info 头部解析（44.1k 立体声 / 时长）" {
    const alloc = testing.allocator;
    var r = io.Reader.openMem(inside_mp7);
    var info: decoder.Info = undefined;
    var d = try open(alloc, &r, &info);
    defer d.deinit();

    try testing.expectEqual(@as(u32, 44100), info.sample_rate);
    try testing.expectEqual(@as(u8, 2), info.channels);
    try testing.expectEqual(@as(u8, 16), info.bits_per_sample);
    try testing.expectEqual(false, info.is_float);
    try testing.expectEqualStrings("mpc7", info.codec_name);
    try testing.expectEqualStrings("mpc7", info.format_name);
    try testing.expectEqual(decoder.DurationKnown.exact, info.duration_known);
    // 456 帧 × 1152 样本 @44100 = 11.911655 s
    try testing.expectEqual(@as(i64, 456 * 1152 * 1_000_000 / 44100), info.duration_us);
}

test "sv7: inside-mp7 全流解码 → 与 ffmpeg 参考 PCM 逐位一致" {
    const alloc = testing.allocator;
    var r = io.Reader.openMem(inside_mp7);
    var info: decoder.Info = undefined;
    var d = try open(alloc, &r, &info);
    defer d.deinit();

    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    var buf: [65536]u8 = undefined;
    while (true) {
        var ch: u8 = 0;
        const n = try d.read(&buf, 4096, &ch);
        if (n == 0) break;
        try out.appendSlice(alloc, buf[0 .. n * @as(usize, ch) * 2]);
    }
    // 首段逐字节比对
    try testing.expect(out.items.len >= inside_mp7_first1s.len);
    try testing.expectEqualSlices(u8, inside_mp7_first1s, out.items[0..inside_mp7_first1s.len]);
    // 全流 md5（对拍 ffmpeg n9.0.1 `-f s16le`）
    var md5: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(out.items, &md5, .{});
    var hex: [32]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{&md5}) catch unreachable;
    try testing.expectEqualStrings(inside_mp7_full_md5, &hex);
}

test "sv7: seek(5016ms) → 与 ffmpeg in-seek 参考（帧 192+21 样本）逐位一致" {
    const alloc = testing.allocator;
    var r = io.Reader.openMem(inside_mp7);
    var info: decoder.Info = undefined;
    var d = try open(alloc, &r, &info);
    defer d.deinit();

    // 5016 ms → 样本 221205（= 192×1152 + 21，即帧 192 内偏移 21）
    try d.seekMs(5016);
    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    var buf: [65536]u8 = undefined;
    while (true) {
        var ch: u8 = 0;
        const n = try d.read(&buf, 4096, &ch);
        if (n == 0) break;
        try out.appendSlice(alloc, buf[0 .. n * @as(usize, ch) * 2]);
    }
    // 参考：ffmpeg `-ss 5.016 -i` 全量输出（帧 192 起）截取自样本 221205 的 1 秒
    try testing.expect(out.items.len >= inside_mp7_seek5s.len);
    try testing.expectEqualSlices(u8, inside_mp7_seek5s, out.items[0..inside_mp7_seek5s.len]);
    // 输出长度 = 总样本 - 目标样本（末帧不截断）
    try testing.expectEqual(@as(usize, 456 * 1152 - 221205), out.items.len / 4);
}

test "sv7: seek 越界 → EOF；seek(0) 回到起点重新解码一致" {
    const alloc = testing.allocator;
    var r = io.Reader.openMem(inside_mp7);
    var info: decoder.Info = undefined;
    var d = try open(alloc, &r, &info);
    defer d.deinit();

    // 越界（> 全长 11.91 s）：置 EOF，read 返回 0
    try d.seekMs(60_000);
    var ch: u8 = 0;
    var buf: [4096]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), try d.read(&buf, 1024, &ch));

    // 回到起点：完整重解，首段仍与参考一致
    try d.seekMs(0);
    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    while (true) {
        const n = try d.read(&buf, 1024, &ch);
        if (n == 0) break;
        try out.appendSlice(alloc, buf[0 .. n * @as(usize, ch) * 2]);
    }
    try testing.expectEqual(@as(usize, 456 * 1152 * 4), out.items.len);
    try testing.expectEqualSlices(u8, inside_mp7_first1s, out.items[0..inside_mp7_first1s.len]);
}

test "sv7: seek(8000ms) → 与 ffmpeg in-seek 参考逐位一致（md5，第二校验点）" {
    const alloc = testing.allocator;
    var r = io.Reader.openMem(inside_mp7);
    var info: decoder.Info = undefined;
    var d = try open(alloc, &r, &info);
    defer d.deinit();

    // 8000 ms → 样本 352800（帧 306 内偏移 288）。ffmpeg `-ss 8 -i` 输出
    // 自帧 306 起且与连续解码逐位一致，故参考 md5 可由全流参考 PCM 截取计算。
    try d.seekMs(8000);
    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    var buf: [65536]u8 = undefined;
    while (true) {
        var ch: u8 = 0;
        const n = try d.read(&buf, 4096, &ch);
        if (n == 0) break;
        try out.appendSlice(alloc, buf[0 .. n * @as(usize, ch) * 2]);
    }
    var md5: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(out.items, &md5, .{});
    var hex: [32]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{&md5}) catch unreachable;
    try testing.expectEqualStrings("6968d4b1e510e7629c13860b6cf8d26b", &hex);
}
