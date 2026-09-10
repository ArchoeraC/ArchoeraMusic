// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! WMA Voice (wmavoice, ASF codec_tag 0x000A) 解码接入层。
//!
//! 复用 fmt/wma 的 ASF 容器解析与数据包去包（asf.zig / packets.zig）。每个
//! ASF 音频对象（obj_size 通常为 block_align 的倍数，内含若干 codec packet；
//! 每个 codec packet 有自己的 4bit+…+spillover 头）逐一 feed 到
//! `core.Dec.decodePacket`——对象可能跨多次调用消费（decode 一次至多吐一帧
//! superframe 480 样本）；对象耗尽后按 ffmpeg drain 语义补空包触发剩余缓存
//! superframe 输出。
//!
//! 输出：解码器内部 float 样本经 clip(round(x*32768)) 转交错 s16（mono），
//! 对齐 ffmpeg `-f s16le`（s16 语义 = round+clip，见上层验证）。

const std = @import("std");
const Error = @import("../../../error.zig").Error;
const io = @import("../../../io.zig");
const decoder = @import("../../../decoder.zig");
const asf = @import("../asf.zig");
const packets = @import("../packets.zig");
const core = @import("core.zig");

const WmaVoiceCtx = struct {
    allocator: std.mem.Allocator,
    file_data: []u8, // 整文件（owned）
    pcm: []i16, // 交错 s16（owned；mono）
    sample_rate: u32,
    channels: u8,
    total_frames: usize,
    cursor: usize = 0,

    fn sampleToMs(self: *const WmaVoiceCtx, samples: usize) i64 {
        return @intCast(@divTrunc(@as(i128, @intCast(samples)) * 1000, @as(i128, self.sample_rate)));
    }
    fn read(self: *WmaVoiceCtx, out: []u8, max_samples: usize, out_channels: *u8) Error!usize {
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

const vtable = decoder.Decoder.VTable{
    .read = read,
    .seek_ms = seekMs,
    .position_ms = positionMs,
    .deinit = deinit,
};

fn read(ctx: *anyopaque, out: []u8, max_samples: usize, out_channels: *u8) Error!usize {
    const self: *WmaVoiceCtx = @ptrCast(@alignCast(ctx));
    return self.read(out, max_samples, out_channels);
}
fn seekMs(ctx: *anyopaque, ms: i64) Error!void {
    const self: *WmaVoiceCtx = @ptrCast(@alignCast(ctx));
    if (ms <= 0) {
        self.cursor = 0;
        return;
    }
    const target = @as(u64, @intCast(ms)) * self.sample_rate / 1000;
    self.cursor = @min(@as(usize, @intCast(target)), self.total_frames);
}
fn positionMs(ctx: *anyopaque) i64 {
    const self: *WmaVoiceCtx = @ptrCast(@alignCast(ctx));
    return self.sampleToMs(self.cursor);
}
fn deinit(ctx: *anyopaque) void {
    const self: *WmaVoiceCtx = @ptrCast(@alignCast(ctx));
    const a = self.allocator;
    a.free(self.file_data);
    a.free(self.pcm);
    a.destroy(self);
}

/// toS16：ffmpeg FLT→s16（`-f s16le`）语义 = round(clip(x*32768))。
fn toS16(x: f32) i16 {
    var v: f64 = @round(@as(f64, x) * 32768.0);
    if (v > 32767.0) v = 32767.0;
    if (v < -32768.0) v = -32768.0;
    return @intFromFloat(v);
}

/// 解码全部音频对象为解码器内部 float 样本（mono）。
pub fn decodeF32(a: std.mem.Allocator, file_data: []const u8, hdr: *const asf.Header) Error![]f32 {
    const audio = hdr.audio.?;
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

    var dec = core.Dec.init(.{
        .extradata = audio.extradata,
        .sample_rate = audio.sample_rate,
        .block_align = audio.block_align,
    });
    defer dec.flush();

    var offs = try a.alloc(usize, n);
    defer a.free(offs);
    var acc: usize = 0;
    for (0..n) |k| {
        offs[k] = acc;
        acc += sizes[k];
    }

    var samples = std.ArrayList(f32).empty;
    errdefer samples.deinit(a);
    try samples.ensureTotalCapacity(a, (n + 2) * core.MAX_SFRAMESIZE);

    var pkt_idx: usize = 0;
    var cur: []const u8 = &.{};
    var guard: usize = 0;
    const max_guard = (n + 2) * 2048 + 64;

    // 正常对象循环（对齐 ffmpeg decode_simple_internal：每次消费后继续剩余，
    // 对象耗尽才取下一个；最后一个对象同样须循环到 cur 空为止）
    while (true) : (guard += 1) {
        if (guard > max_guard) return error.Corrupt;
        if (cur.len == 0) {
            if (pkt_idx >= n) break;
            cur = flat[offs[pkt_idx]..][0..sizes[pkt_idx]];
            pkt_idx += 1;
        }
        const consumed = dec.decodePacket(cur);
        if (consumed < 0) {
            // ffmpeg：解码错误 → 丢弃本对象剩余
            cur = &.{};
            continue;
        }
        if (dec.pending) {
            const items = try samples.addManyAsSlice(a, dec.out_len);
            @memcpy(items, dec.out_buf[0..dec.out_len]);
        }
        const c: usize = @intCast(consumed);
        if (c >= cur.len) {
            cur = &.{};
        } else {
            cur = cur[c..];
        }
    }

    // drain：补空包直到不再产生帧（对齐 ffmpeg flush）
    while (true) : (guard += 1) {
        if (guard > max_guard) return error.Corrupt;
        const consumed = dec.decodePacket(&.{});
        if (consumed < 0) break;
        if (dec.pending) {
            const items = try samples.addManyAsSlice(a, dec.out_len);
            @memcpy(items, dec.out_buf[0..dec.out_len]);
        } else break;
    }

    if (samples.items.len == 0) return error.Corrupt;
    return try samples.toOwnedSlice(a);
}

pub fn quantize(a: std.mem.Allocator, flt: []const f32) Error![]i16 {
    const out = try a.alloc(i16, flt.len);
    for (flt, 0..) |v, i| out[i] = toS16(v);
    return out;
}

pub fn openFromAsf(allocator: std.mem.Allocator, file_data: []u8, hdr: *const asf.Header, info: *decoder.Info) Error!decoder.Decoder {
    const audio = hdr.audio.?;
    if (audio.codec_tag != 0x000A) return error.UnsupportedFormat;
    if (audio.extradata.len != 46) return error.UnsupportedFormat;
    // ffmpeg 支持 322–22097 Hz（pitch/history 范围约束）；其余回退主后端
    if (audio.sample_rate < 322 or audio.sample_rate > 22097) return error.UnsupportedFormat;
    if (audio.block_align == 0 or audio.block_align > (1 << 22)) return error.UnsupportedFormat;

    const r = try decodeF32(allocator, file_data, hdr);
    errdefer allocator.free(r);
    const pcm = try quantize(allocator, r);
    allocator.free(r);

    const ctx = try allocator.create(WmaVoiceCtx);
    errdefer allocator.destroy(ctx);
    ctx.* = .{
        .allocator = allocator,
        .file_data = file_data,
        .pcm = pcm,
        .sample_rate = audio.sample_rate,
        .channels = 1,
        .total_frames = pcm.len,
    };

    info.* = .{
        .sample_rate = audio.sample_rate,
        .channels = 1,
        .bits_per_sample = 16,
        .is_float = false,
        // 容器头自洽 → play_duration − preroll（= ffprobe）；否则预解码总数
        .duration_us = asf.containerDurationUs(file_data, hdr) orelse
            @intCast(@divTrunc(@as(i128, @intCast(ctx.total_frames)) * 1_000_000, @as(i128, audio.sample_rate))),
        .duration_known = .exact,
        .codec_name = "wmavoice",
        .format_name = "asf",
        .metadata = .{},
    };

    return .{ .vtable = &vtable, .ctx = ctx };
}

// ---------------------------------------------------------------------------
// golden 回归（vs ffmpeg n9.0.1 内部 float 输出；.f32 = `-f f32le`）
// ---------------------------------------------------------------------------

fn corrF(a: []const f32, b: []const f32) f64 {
    var sa: f64 = 0;
    var sb: f64 = 0;
    var sab: f64 = 0;
    const n = @min(a.len, b.len);
    for (0..n) |i| {
        const x = @as(f64, a[i]);
        const y = @as(f64, b[i]);
        sa += x * x;
        sb += y * y;
        sab += x * y;
    }
    if (sa == 0 or sb == 0) return 0;
    return sab / @sqrt(sa * sb);
}

fn runGolden(sample_embed: []const u8, golden_embed: []const u8, want_sr: u32) !void {
    const a = std.testing.allocator;
    const file_data = try a.dupe(u8, sample_embed);
    defer a.free(file_data);
    var hdr = try asf.parseHeader(file_data);
    const r = try decodeF32(a, file_data, &hdr);
    defer a.free(r);
    const ref = try a.alloc(f32, golden_embed.len / 4);
    defer a.free(ref);
    @memcpy(std.mem.sliceAsBytes(ref), golden_embed);
    try std.testing.expectEqual(ref.len, r.len);
    // golden = reference no-asm（generic C）构建的内部 float 输出；逐位断言
    var exact: usize = 0;
    for (r, ref) |x, y| {
        if (x == y) exact += 1;
    }
    const c = corrF(r, ref);
    std.debug.print("  wmavoice golden: sr={d} samples={d} bit-exact {d}/{d} corr={d:.6}\n", .{ want_sr, r.len, exact, r.len, c });
    try std.testing.expectEqual(r.len, exact);
}

const s7 = @embedFile("embed_cbr7.wma");
const g7 = @embedFile("embed_cbr7.f32");
const s11 = @embedFile("embed_cbr11.wma");
const g11 = @embedFile("embed_cbr11.f32");
const s19 = @embedFile("embed_cbr19.wma");
const g19 = @embedFile("embed_cbr19.f32");

/// 对拍 dump 工具：WMAVOICE_DUMP_F32=<前缀> 时把三个样本的内部 float 输出
/// 写到 <前缀>7/11/19.f32（与 no-asm reference 构建输出直接逐位比对用）。
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;
extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn fwrite(ptr: [*]const u8, sz: usize, n: usize, f: *anyopaque) usize;
extern "c" fn fclose(f: *anyopaque) i32;

fn dumpIfRequested(a: std.mem.Allocator) !void {
    const prefix_z = getenv("WMAVOICE_DUMP_F32") orelse return;
    const prefix = std.mem.span(prefix_z);
    const samples = [_][]const u8{ s7, s11, s19 };
    const tags = [_][]const u8{ "7", "11", "19" };
    for (samples, tags) |sdata, tag| {
        const file_data = try a.dupe(u8, sdata);
        defer a.free(file_data);
        var hdr = try asf.parseHeader(file_data);
        const r = try decodeF32(a, file_data, &hdr);
        defer a.free(r);
        const path = try std.mem.concat(a, u8, &.{ prefix, tag, ".f32" });
        defer a.free(path);
        const path_z = try a.dupeZ(u8, path);
        defer a.free(path_z);
        const f = fopen(path_z.ptr, "wb") orelse return error.Corrupt;
        _ = fwrite(std.mem.sliceAsBytes(r).ptr, 1, std.mem.sliceAsBytes(r).len, f);
        _ = fclose(f);
        try dumpObj(a, file_data, &hdr, prefix, tag);
    }
}

/// 写 reference C 驱动（wmvdrv）可吃的 obj 文件：
/// [u32 n][u32 sr][u32 block_align][u32 edlen][ed][u32 sizes × n][payload]
fn dumpObj(a: std.mem.Allocator, file_data: []const u8, hdr: *const asf.Header, prefix: []const u8, tag: []const u8) !void {
    const audio = hdr.audio.?;
    const data_start = try asf.dataPacketsOffset(file_data, hdr.data_offset);
    const avail = file_data.len - data_start;
    const flat = try a.alloc(u8, avail);
    defer a.free(flat);
    const sizes_buf = try a.alloc(usize, (avail >> 6) + 4);
    defer a.free(sizes_buf);
    const n = packets.demuxObjects(file_data, hdr, flat, sizes_buf) catch return error.Corrupt;
    const path = try std.mem.concat(a, u8, &.{ prefix, tag, ".obj" });
    defer a.free(path);
    const path_z = try a.dupeZ(u8, path);
    defer a.free(path_z);
    const f = fopen(path_z.ptr, "wb") orelse return error.Corrupt;
    defer _ = fclose(f);
    var u: [4]u8 = undefined;
    _ = &u;
    const put = struct {
        fn wr(ff: *anyopaque, v: anytype) void {
            var b: [@sizeOf(@TypeOf(v))]u8 = undefined;
            inline for (0..b.len) |i| b[i] = @truncate(@as(u64, @bitCast(@as(i64, v))) >> @intCast(8 * i));
            _ = fwrite(&b, 1, b.len, ff);
        }
    };
    put.wr(f, @as(u32, @intCast(n)));
    put.wr(f, @as(u32, audio.sample_rate));
    put.wr(f, @as(u32, audio.block_align));
    put.wr(f, @as(u32, @intCast(audio.extradata.len)));
    _ = fwrite(audio.extradata.ptr, 1, audio.extradata.len, f);
    for (sizes_buf[0..n]) |sz| put.wr(f, @as(u32, @intCast(sz)));
    _ = fwrite(flat.ptr, 1, totalLen(sizes_buf[0..n]), f);
}
fn totalLen(xs: []const usize) usize {
    var v: usize = 0;
    for (xs) |x| v += x;
    return v;
}

test "wmavoice dump f32 (env-gated)" {
    if (getenv("WMAVOICE_DUMP_F32") != null) {
        const a = std.testing.allocator;
        try dumpIfRequested(a);
    }
}

test "wmavoice golden: 8kHz 7kbps（lsp10，ds=9）float 逐位 vs ffmpeg no-asm" {
    try runGolden(s7, g7, 8000);
}
test "wmavoice golden: 8kHz 11kbps（lsp10，ds=3，tilt_corr）float 逐位 vs ffmpeg no-asm" {
    try runGolden(s11, g11, 8000);
}
test "wmavoice golden: 16kHz 19kbps（lsp16，ds=3）float 逐位 vs ffmpeg no-asm" {
    try runGolden(s19, g19, 16000);
}

// e2e 解码视图（read 接口 + Info），验证 s16 量化输出可读
test "wmavoice e2e decode view: 7K" {
    const a = std.testing.allocator;
    const file_data = try a.dupe(u8, s7);
    var hdr = try asf.parseHeader(file_data);
    var info: decoder.Info = undefined;
    var dec = try openFromAsf(a, file_data, &hdr, &info);
    defer dec.deinit();
    try std.testing.expectEqualStrings("wmavoice", info.codec_name);
    try std.testing.expectEqualStrings("asf", info.format_name);
    try std.testing.expectEqual(@as(u32, 8000), info.sample_rate);
    try std.testing.expectEqual(@as(u8, 1), info.channels);
    var out = std.ArrayList(u8).empty;
    defer out.deinit(a);
    var buf: [8192]u8 = undefined;
    while (true) {
        var ch: u8 = 0;
        const n = try dec.read(&buf, 4096, &ch);
        if (n == 0) break;
        try out.appendSlice(a, buf[0 .. n * @as(usize, ch) * 2]);
    }
    try std.testing.expectEqual(@as(usize, 132007), out.items.len / 2);
}
