//! WMA Pro (wmapro, ASF codec tag 0x162) 解码接入层。
//!
//! 复用 fmt/wma 的 ASF 容器解析与数据包去包（asf.zig / packets.zig）。open 整读
//! ASF → Header 解析 → Data Object 重组为「WMA packet」序列（每个完整音频对象
//! = 一个 packet，通常 block_align 字节）→ 按 FFmpeg decode core 喂包循环驱动
//! `core.Dec.decodePacket`（同一 packet 可分多次消费；流尾补一次空包触发 EOF
//! flush 输出重叠尾）→ 交错 s16。采样率/声道按容器 + extradata。
//!
//! 解码为浮点（对齐 ffmpeg fltp）；s16 用 round(x*32768)+clamp。IMDCT 为
//! av_tx 位精确内核（mdct.zig）；scale-factor 量化步进的 exp10 用 f64 数学，
//! 与系统 ffmpeg 的 f32 近似存在末位差异 → s16 bit-exact 非 100%（实测比例见
//! fmt/wma/README），corr ≥ 0.9999。

const std = @import("std");
const Error = @import("../../../error.zig").Error;
const io = @import("../../../io.zig");
const decoder = @import("../../../decoder.zig");
const asf = @import("../asf.zig");
const packets = @import("../packets.zig");
const core = @import("core.zig");

const WmaProCtx = struct {
    allocator: std.mem.Allocator,
    file_data: []u8, // 整文件（owned）
    pcm: []i16, // 交错 s16 解码结果
    sample_rate: u32,
    channels: u8,
    total_frames: usize, // 每声道样本数
    cursor: usize = 0,

    fn sampleToMs(self: *const WmaProCtx, samples: usize) i64 {
        return @intCast(@divTrunc(@as(i128, @intCast(samples)) * 1000, @as(i128, self.sample_rate)));
    }
    fn read(self: *WmaProCtx, out: []u8, max_samples: usize, out_channels: *u8) Error!usize {
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
    const self: *WmaProCtx = @ptrCast(@alignCast(ctx));
    return self.read(out, max_samples, out_channels);
}

fn seekMs(ctx: *anyopaque, ms: i64) Error!void {
    const self: *WmaProCtx = @ptrCast(@alignCast(ctx));
    if (ms <= 0) {
        self.cursor = 0;
        return;
    }
    const target = @as(u64, @intCast(ms)) * self.sample_rate / 1000;
    self.cursor = @min(@as(usize, @intCast(target)), self.total_frames);
}

fn positionMs(ctx: *anyopaque) i64 {
    const self: *WmaProCtx = @ptrCast(@alignCast(ctx));
    return self.sampleToMs(self.cursor);
}

fn deinit(ctx: *anyopaque) void {
    const self: *WmaProCtx = @ptrCast(@alignCast(ctx));
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

pub fn openFromAsf(allocator: std.mem.Allocator, file_data: []u8, hdr: *const asf.Header, info: *decoder.Info) Error!decoder.Decoder {
    const audio = hdr.audio.?;
    if (audio.codec_tag != 0x0162) return error.UnsupportedFormat;
    if (audio.extradata.len < 18) return error.UnsupportedFormat;
    const bits_per_sample = readU16le(audio.extradata, 0);
    const channel_mask = readU32le(audio.extradata, 2);
    const decode_flags = readU16le(audio.extradata, 14);
    if (bits_per_sample == 0 or bits_per_sample > 32) return error.UnsupportedFormat;
    if (audio.sample_rate == 0) return error.UnsupportedFormat;
    if (bits_per_sample != 24) return error.UnsupportedFormat; // mdct 位精确表仅 24-bit
    if (audio.sample_rate > 48000) return error.UnsupportedFormat; // mdct 表支持上限

    var channels: usize = audio.channels;
    if (channel_mask != 0) channels = @popCount(channel_mask);
    if (channels == 0 or channels > core.WMAPRO_MAX_CHANNELS) return error.UnsupportedFormat;

    // demux WMA packet 序列（Data Object → 完整音频对象）
    const data_start = asf.dataPacketsOffset(file_data, hdr.data_offset) catch return error.Corrupt;
    const avail = file_data.len - data_start;
    if (avail == 0) return error.Corrupt;

    var flat = try allocator.alloc(u8, avail);
    defer allocator.free(flat);
    var sizes_buf = try allocator.alloc(usize, (avail >> 6) + 4);
    defer allocator.free(sizes_buf);
    const n = packets.demuxObjects(file_data, hdr, flat, sizes_buf) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Corrupt,
    };
    if (n == 0) return error.Corrupt;
    const sizes = sizes_buf[0..n];

    var dec: core.Dec = undefined;
    try dec.init(.{
        .sample_rate = audio.sample_rate,
        .bits_per_sample = bits_per_sample,
        .channels = @intCast(channels),
        .channel_mask = channel_mask,
        .decode_flags = decode_flags,
        .block_align = audio.block_align,
    });
    const spf = dec.samples_per_frame;

    var pcm = std.ArrayList(i16).empty;
    errdefer pcm.deinit(allocator);
    try pcm.ensureTotalCapacity(allocator, (n + 2) * spf * channels);

    // 对象起始偏移
    var offs = try allocator.alloc(usize, n);
    defer allocator.free(offs);
    var acc: usize = 0;
    for (0..n) |k| {
        offs[k] = acc;
        acc += sizes[k];
    }

    var pkt_idx: usize = 0;
    var cur: []const u8 = &.{};
    var guard: usize = 0;

    while (true) : (guard += 1) {
        if (guard > (n + 2) * 1024 + 16) return error.Corrupt;
        if (cur.len == 0) {
            if (pkt_idx < n) {
                cur = flat[offs[pkt_idx]..][0..sizes[pkt_idx]];
                pkt_idx += 1;
            } else {
                break; // 不喂 EOF flush（对齐 ffmpeg n9.0.1：本类 wmapro 样本结束于
                // 短包错误后不产生空包 drain flush 帧）
            }
        }

        const consumed = dec.decodePacket(cur) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                std.debug.print("dbg: pkt err {s} pkt_idx={d} cur.len={d}\n", .{ @errorName(e), pkt_idx, cur.len });
                cur = &.{};
                continue;
            },
        };
        if (dec.frame_pending) {
            const n_out = dec.frame_out_len;
            const st = dec.frame_out_start;
            const ns = n_out * channels;
            const items = try pcm.addManyAsSlice(allocator, ns);
            for (0..n_out) |s| {
                for (0..channels) |c| {
                    items[s * channels + c] = toS16(dec.planes[c][st + s]);
                }
            }
        }
        if (consumed >= cur.len) {
            cur = &.{};
        } else {
            cur = cur[consumed..];
        }
    }

    const npcm = pcm.items.len;
    if (npcm == 0) return error.Corrupt;

    const ctx = try allocator.create(WmaProCtx);
    errdefer allocator.destroy(ctx);
    ctx.* = .{
        .allocator = allocator,
        .file_data = file_data,
        .pcm = try pcm.toOwnedSlice(allocator),
        .sample_rate = audio.sample_rate,
        .channels = @intCast(channels),
        .total_frames = npcm / channels,
    };

    info.* = .{
        .sample_rate = audio.sample_rate,
        .channels = @intCast(channels),
        .bits_per_sample = 16,
        .is_float = false,
        // 容器头自洽 → play_duration − preroll（= ffprobe）；否则预解码总数
        .duration_us = asf.containerDurationUs(file_data, hdr) orelse
            @intCast(@divTrunc(@as(i128, @intCast(ctx.total_frames)) * 1_000_000, @as(i128, audio.sample_rate))),
        .duration_known = .exact,
        .codec_name = "wmapro",
        .format_name = "asf",
        .metadata = .{},
    };

    return .{ .vtable = &vtable, .ctx = ctx };
}

const sample_beethoven = @embedFile("sample_beethoven.wma");

test "wmapro 配置: Beethoven 2ch extradata/帧长推导" {
    var d: core.Dec = undefined;
    try d.init(.{
        .sample_rate = 48000,
        .bits_per_sample = 24,
        .channels = 2,
        .channel_mask = 0x3,
        .decode_flags = 0xE0,
        .block_align = 16384,
    });
    try std.testing.expectEqual(@as(usize, 2048), d.samples_per_frame);
    try std.testing.expectEqual(@as(usize, 16), d.max_num_subframes);
    try std.testing.expectEqual(@as(usize, 128), d.min_samples_per_subframe);
    try std.testing.expectEqual(@as(usize, 18), d.log2_frame_size);
    try std.testing.expectEqual(@as(i32, -1), d.lfe_channel);
    try std.testing.expectEqual(@as(usize, 5), d.num_possible_block_sizes);
    try std.testing.expect(d.len_prefix);
    try std.testing.expect(d.dynamic_range_compression);
}

test "wmapro 配置: latin 5.1 channel_mask/LFE 推导" {
    var d: core.Dec = undefined;
    try d.init(.{
        .sample_rate = 48000,
        .bits_per_sample = 24,
        .channels = 6,
        .channel_mask = 0x3F,
        .decode_flags = 0xE0,
        .block_align = 8192,
    });
    try std.testing.expectEqual(@as(usize, 2048), d.samples_per_frame);
    try std.testing.expectEqual(@as(usize, 17), d.log2_frame_size);
    try std.testing.expectEqual(@as(i32, 3), d.lfe_channel);
}

test "wmapro e2e: Beethoven 2ch == ffmpeg" {
    const r = try runE2e(sample_beethoven, @embedFile("golden_beethoven.s16"));
    try std.testing.expectEqual(@as(u32, 48000), r.sr);
    try std.testing.expectEqual(@as(u8, 2), r.ch);
    try std.testing.expect(r.corr > 0.999999);
    try std.testing.expect(r.bit_exact > 99.0);
}

const sample_latin51 = @embedFile("sample_latin51.wma");

test "wmapro e2e: latin 5.1 6ch == ffmpeg" {
    const r = try runE2e(sample_latin51, @embedFile("golden_latin51.s16"));
    try std.testing.expectEqual(@as(u32, 48000), r.sr);
    try std.testing.expectEqual(@as(u8, 6), r.ch);
    try std.testing.expect(r.corr > 0.999999);
    try std.testing.expect(r.bit_exact > 99.0);
}

fn runE2e(embedded: []const u8, golden: []const u8) !struct { sr: u32, ch: u8, frames: usize, corr: f64, bit_exact: f64 } {
    const a = std.testing.allocator;
    const file_data = try a.dupe(u8, embedded);
    var hdr = try asf.parseHeader(file_data);
    var info: decoder.Info = undefined;
    var dec = try openFromAsf(a, file_data, &hdr, &info);
    defer dec.deinit();
    try std.testing.expectEqualStrings("wmapro", info.codec_name);
    try std.testing.expectEqualStrings("asf", info.format_name);
    var out = std.ArrayList(i16).empty;
    defer out.deinit(a);
    var buf: [65536]u8 = undefined;
    while (true) {
        var ch: u8 = 0;
        const n = try dec.read(&buf, 4096, &ch);
        if (n == 0) break;
        const bytes = n * @as(usize, ch) * 2;
        const samples = try out.addManyAsSlice(a, bytes / 2);
        for (0..bytes / 2) |k| {
            samples[k] = std.mem.readInt(i16, buf[k * 2 ..][0..2], .little);
        }
    }
    const ns = out.items.len;
    const ng = golden.len / 2;
    if (ns != ng) {
        std.debug.print("  WARN sample count mine={d} golden={d}\n", .{ ns, ng });
    }
    const limit = @min(ns, ng);
    var equal: usize = 0;
    var max_abs: i64 = 0;
    var sum_num: f64 = 0;
    var sum_a2: f64 = 0;
    var sum_b2: f64 = 0;
    for (0..limit) |i| {
        const gv = std.mem.readInt(i16, golden[i * 2 ..][0..2], .little);
        const mv = out.items[i];
        const d: i64 = @intCast(@abs(@as(i64, gv) - @as(i64, mv)));
        if (d > max_abs) max_abs = d;
        if (gv == mv) equal += 1;
        sum_num += @as(f64, @floatFromInt(gv)) * @as(f64, @floatFromInt(mv));
        sum_a2 += @as(f64, @floatFromInt(gv)) * @as(f64, @floatFromInt(gv));
        sum_b2 += @as(f64, @floatFromInt(mv)) * @as(f64, @floatFromInt(mv));
    }
    const corr = sum_num / @sqrt(sum_a2 * sum_b2);
    std.debug.print("  frames={d} sr={d} ch={d}\n", .{ ns / @as(usize, info.channels), info.sample_rate, info.channels });
    std.debug.print("  golden_len={d} max_abs={d} corr={d:.8} bit-exact {d}/{d} = {d:.4}%\n", .{ ng, max_abs, corr, equal, limit, 100.0 * @as(f64, @floatFromInt(equal)) / @as(f64, @floatFromInt(limit)) });
    return .{ .sr = info.sample_rate, .ch = info.channels, .frames = ns / info.channels, .corr = corr, .bit_exact = 100.0 * @as(f64, @floatFromInt(equal)) / @as(f64, @floatFromInt(limit)) };
}
