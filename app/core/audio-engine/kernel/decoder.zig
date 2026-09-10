// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! 解码层统一接口（docs/audio-kernel-zig.md §8.1）
//!
//! `Decoder` 是格式无关的解码视图：`open` 负责 probe → 工厂分发，
//! 各 `fmt/*.zig` 实现 VTable，输出**原生位深交错 PCM**（保留位深，
//! 采样转换由后续 pcm/* 层统一处理，与现状 resampler 延迟初始化语义对齐）。
//!
//! 与 FFmpeg 主后端衔接（§8.3）：
//!   - `open` 对未接管 / 未开启的格式返回 error.UnsupportedFormat，
//!     由引擎回退 FFmpeg 主后端重试（默认主，`-Duse-ffmpeg` 默认开）。

const std = @import("std");
const Error = @import("error.zig").Error;
const io = @import("io.zig");
const probe = @import("probe.zig");
const registry = @import("registry.zig");

/// 时长精确度（§8.1）
pub const DurationKnown = enum { exact, estimate, unknown };

/// 标签元数据（open 时尽力解析；字段为可空 NUL 终止字符串）。
/// 内存归属解码器上下文（open 时分配、deinit 时释放），生命周期与 Decoder 一致，
/// 调用方只读不释放（与 codec_name 相同的指针契约）。
pub const Metadata = struct {
    title: ?[:0]const u8 = null,
    artist: ?[:0]const u8 = null,
    album: ?[:0]const u8 = null,
    date: ?[:0]const u8 = null,
    genre: ?[:0]const u8 = null,
    comment: ?[:0]const u8 = null,
    /// 全部 VORBIS 注释条目（含 6 个标准字段；key 原样保留大小写，value 已 trim；
    /// 与标准字段各自持有独立分配。生命周期与 Decoder 一致，只读不释放）
    tags: []const Tag = &.{},
};

/// VORBIS 注释通用键值对（未映射标准字段的原始条目：TRACKNUMBER / ALBUMARTIST /
/// REPLAYGAIN_* 等全部保留，对齐 FFmpeg av_dict 语义；重复键全部保留）
pub const Tag = struct {
    key: []const u8,
    value: []const u8,
};

/// 音量归一化增益（REPLAYGAIN_* 标签；单位对齐 FFmpeg AVReplayGain：
/// gain 为 0.001 dB、peak 为 0.00001；null = 缺失）
pub const ReplayGain = struct {
    track_gain: ?i32 = null,
    track_peak: ?u32 = null,
    album_gain: ?i32 = null,
    album_peak: ?u32 = null,
};

/// 附加图片（封面等；来自 FLAC PICTURE 块，ID3v2 APIC 语义）。
/// 字符串与 data 均为解码器上下文分配的堆内存（deinit 时释放，只读不释放）；
/// 空字段为无分配的零长 slice。
pub const Picture = struct {
    /// 图片类型（ID3v2 APIC：0 other / 2 其它文件图标 / 3 封面(front) / 4 封底(back) /
    /// 6 媒体标签 / 7 主唱 / 8 艺人 / 18 插图 / 19 乐队标志 …）
    picture_type: u32 = 0,
    /// MIME 类型（如 "image/jpeg"；空 = 未知）
    mime: []const u8 = &.{},
    /// 描述（UTF-8；可能为空）
    description: []const u8 = &.{},
    /// 像素宽度（0 = 未知）
    width: u32 = 0,
    /// 像素高度（0 = 未知）
    height: u32 = 0,
    /// 每像素位数（0 = 未知）
    depth: u32 = 0,
    /// 索引色数量（非索引色图片 = 0）
    colors: u32 = 0,
    /// 图片原始编码数据（按 mime 解释；生命周期与 Decoder 一致）
    data: []const u8 = &.{},
};

/// 采样器循环点（来自 WAV `smpl` chunk；帧为单位）
pub const LoopPoint = struct {
    /// 循环类型：0 = forward（向前）、1 = alternating（往返）、2 = backward（向后）
    type: u32,
    /// 起始帧（含）
    start: u32,
    /// 结束帧（含）
    end: u32,
    /// 播放次数（0 = 无限循环）
    play_count: u32,
};

/// 提示点（来自 WAV `cue ` chunk；帧为单位，相对 data 区起点）
pub const CuePoint = struct {
    id: u32,
    /// 样本偏移（相对 data chunk 起点）
    position: u32,
};

/// 解码源信息（open 时填充，采样转换器可提前构建）
pub const Info = struct {
    sample_rate: u32,
    channels: u8,
    /// 原生位深（8/16/24/32/64）
    bits_per_sample: u8,
    /// 原生是否 IEEE float
    is_float: bool,
    /// 时长（微秒）；精确度见 duration_known
    duration_us: i64,
    duration_known: DurationKnown,
    /// 编码器名（对齐 FFmpeg 命名，如 "pcm_s16le"；静态字面量，sentinel 终止，
    /// 供 C ABI（zk_decoder_open 的 ZkInfo.codec_name）直接取指针）
    codec_name: [:0]const u8,
    /// 容器名（如 "wav"）
    format_name: [:0]const u8,
    /// 编码 profile 名（对齐 FFmpeg 命名，如 DTS 的 "DTS" / "DTS-ES" /
    /// "DTS 96/24" / "DTS-HD MA"；静态字面量，null = 无/未细分）
    profile: ?[:0]const u8 = null,
    /// 标签元数据（可空字符串；生命周期与 Decoder 一致，见 `Metadata`）
    metadata: Metadata,
    /// 附加图片（封面等；FLAC PICTURE 块；生命周期与 Decoder 一致，只读不释放）
    pictures: []const Picture = &.{},
    /// 采样器循环点（`smpl` chunk；帧单位；生命周期与 Decoder 一致，只读不释放）
    loops: []const LoopPoint = &.{},
    /// 提示点（`cue ` chunk；帧单位；生命周期与 Decoder 一致，只读不释放）
    cue_points: []const CuePoint = &.{},
    /// 音量增益（REPLAYGAIN_* 标签；null = 缺失，见 `ReplayGain`）
    replay_gain: ReplayGain = .{},
};

/// 统一解码器（VTable + 不透明上下文）
pub const Decoder = struct {
    vtable: *const VTable,
    ctx: *anyopaque,

    pub const VTable = struct {
        /// 解码最多 max_samples 帧交错 PCM 到 out（字节缓冲）。
        /// 返回实际帧数；out_channels 输出实际声道数。0 = EOF。
        read: *const fn (ctx: *anyopaque, out: []u8, max_samples: usize, out_channels: *u8) Error!usize,
        /// 跳转到指定毫秒位置（最近可用帧边界）
        seek_ms: *const fn (ctx: *anyopaque, ms: i64) Error!void,
        /// 当前播放位置（毫秒，自文件开头计）
        position_ms: *const fn (ctx: *anyopaque) i64,
        /// 释放全部资源
        deinit: *const fn (ctx: *anyopaque) void,
    };

    pub inline fn read(self: *Decoder, out: []u8, max_samples: usize, out_channels: *u8) Error!usize {
        return self.vtable.read(self.ctx, out, max_samples, out_channels);
    }

    pub inline fn seekMs(self: *Decoder, ms: i64) Error!void {
        return self.vtable.seek_ms(self.ctx, ms);
    }

    pub inline fn positionMs(self: *Decoder) i64 {
        return self.vtable.position_ms(self.ctx);
    }

    pub inline fn deinit(self: *Decoder) void {
        self.vtable.deinit(self.ctx);
    }
};

/// 元数据专用会话（probe-only，§8.4.2①）：只解析容器头/标签并持有其分配，
/// **不构造解码器状态**（无 PCM/帧缓冲）。`info` 指向的内存归本会话所有，
/// 生命周期与会话一致；`deinit` 释放全部。
pub const MetadataSession = struct {
    ctx: *anyopaque,
    deinit_fn: *const fn (*anyopaque) void,

    pub inline fn deinit(self: MetadataSession) void {
        self.deinit_fn(self.ctx);
    }
};

/// 元数据工厂签名（可选；未提供者由 registry 回退完整 `open`）。
pub const MetaFn = *const fn (
    allocator: std.mem.Allocator,
    reader: *io.Reader,
    info: *Info,
) Error!MetadataSession;

/// 打开解码器：probe 嗅探 → Registry 分派（§8.2；格式工厂登记于 registry.zig）。
/// 未接管 / 未开启的格式 → error.UnsupportedFormat（引擎回退 FFmpeg，§8.3）。
///
/// `allocator` 供各格式模块分配上下文（当前 wav 为无分配路径，后续
/// flac/ogg 等经此传入，见 §8.1「allocator：engine.zig 传入」）。
pub fn open(allocator: std.mem.Allocator, path: []const u8, info: *Info) Error!Decoder {
    return openWithIo(std.Io.Threaded.global_single_threaded.io(), allocator, path, info);
}

/// 带显式 Io 的 open（Pool worker 用各自每线程 Io 打开文件，见 §3 Zig 0.16 原语修订）
pub fn openWithIo(io_inst: std.Io, allocator: std.mem.Allocator, path: []const u8, info: *Info) Error!Decoder {
    var reader = try io.Reader.openPathWith(io_inst, path);
    errdefer reader.deinit();
    const fmt = try probe.probe(&reader);
    return registry.dispatch(fmt, allocator, &reader, info);
}

/// 元数据打开结果：优先 probe-only 会话（§8.4.2①），无 `meta` 工厂的格式回退完整
/// 解码器。两者均持有 `info` 指向内存；`deinit` 释放。
pub const OpenedMeta = struct {
    session: ?MetadataSession = null,
    dec: ?Decoder = null,

    pub fn deinit(self: *OpenedMeta) void {
        if (self.session) |s| s.deinit();
        if (self.dec) |*d| d.deinit();
    }
};

/// 元数据专用 open（sync 直通；不构造解码器状态，除非该格式未提供 `meta` 工厂）。
pub fn openMeta(allocator: std.mem.Allocator, path: []const u8, info: *Info) Error!OpenedMeta {
    return openMetaWithIo(std.Io.Threaded.global_single_threaded.io(), allocator, path, info);
}

pub fn openMetaWithIo(io_inst: std.Io, allocator: std.mem.Allocator, path: []const u8, info: *Info) Error!OpenedMeta {
    var reader = try io.Reader.openPathWith(io_inst, path);
    errdefer reader.deinit();
    const fmt = try probe.probe(&reader);
    const r = try registry.dispatchMeta(fmt, allocator, &reader, info);
    return switch (r) {
        .session => |s| .{ .session = s },
        .decoder => |d| .{ .dec = d },
    };
}

// ---------------- 集成测试 ----------------

const testing = std.testing;

/// LOAS/LATM 真实样本 + ffmpeg 参考 PCM（fmt/latm 端到端 golden）
const latm_tiny = @embedFile("fmt/latm_tiny_mono.latm");
const latm_tiny_golden = @embedFile("fmt/latm_tiny_mono.s16");

const mka_flac_tiny = @embedFile("fmt/mka/samples/out_flac.mka");

test "open: .latm 经 probe → 工厂分发（decoder.open 全链路）端到端" {
    // 写临时文件（decoder.open 走文件路径）
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ioinst = std.Io.Threaded.global_single_threaded.io();
    const f = try tmp.dir.createFile(ioinst, "t.latm", .{});
    try std.Io.File.writeStreamingAll(f, ioinst, latm_tiny);
    std.Io.File.close(f, ioinst);
    const full = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "t.latm" });
    defer testing.allocator.free(full);

    var info: Info = undefined;
    var dec = try open(testing.allocator, full, &info);
    defer dec.deinit();

    try testing.expectEqual(@as(u32, 44100), info.sample_rate);
    try testing.expectEqual(@as(u8, 1), info.channels);
    try testing.expectEqualStrings("aac", info.codec_name);
    try testing.expectEqualStrings("latm", info.format_name);

    // 与 golden 样本比对（corr/bit-exact 阈值同 fmt/latm e2e）
    var out = std.ArrayList(i16).empty;
    defer out.deinit(testing.allocator);
    var buf: [65536]u8 = undefined;
    while (true) {
        var ch: u8 = 0;
        const n = try dec.read(&buf, 4096, &ch);
        if (n == 0) break;
        const samples = try out.addManyAsSlice(testing.allocator, n * @as(usize, ch));
        for (0..n * @as(usize, ch)) |k| {
            samples[k] = std.mem.readInt(i16, buf[k * 2 ..][0..2], .little);
        }
    }
    const ns = out.items.len;
    const ng = latm_tiny_golden.len / 2;
    try testing.expectEqual(ng, ns);
    var equal: usize = 0;
    var sum_num: f64 = 0;
    var sum_a2: f64 = 0;
    var sum_b2: f64 = 0;
    for (0..ns) |i| {
        const gv = std.mem.readInt(i16, latm_tiny_golden[i * 2 ..][0..2], .little);
        const mv = out.items[i];
        if (gv == mv) equal += 1;
        sum_num += @as(f64, @floatFromInt(gv)) * @as(f64, @floatFromInt(mv));
        sum_a2 += @as(f64, @floatFromInt(gv)) * @as(f64, @floatFromInt(gv));
        sum_b2 += @as(f64, @floatFromInt(mv)) * @as(f64, @floatFromInt(mv));
    }
    const corr = sum_num / @sqrt(sum_a2 * sum_b2);
    try testing.expect(corr > 0.999999);
    try testing.expect(100.0 * @as(f64, @floatFromInt(equal)) / @as(f64, @floatFromInt(ns)) > 99.9);
}

test "open: .mka 经 probe → 工厂分发（decoder.open 全链路）端到端" {
    // 写临时文件（decoder.open 走文件路径）
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ioinst = std.Io.Threaded.global_single_threaded.io();
    const f = try tmp.dir.createFile(ioinst, "t.mka", .{});
    try std.Io.File.writeStreamingAll(f, ioinst, mka_flac_tiny);
    std.Io.File.close(f, ioinst);
    const full = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "t.mka" });
    defer testing.allocator.free(full);

    var info: Info = undefined;
    var dec = try open(testing.allocator, full, &info);
    defer dec.deinit();
    try testing.expectEqual(@as(u32, 44100), info.sample_rate);
    try testing.expectEqual(@as(u8, 1), info.channels);
    try testing.expectEqualStrings("flac", info.codec_name);
    try testing.expectEqualStrings("matroska", info.format_name);

    // 读取解码（flac 输出 = STREAMINFO total = 110250 样本）
    var total: usize = 0;
    var buf: [65536]u8 = undefined;
    while (true) {
        var ch: u8 = 0;
        const n = try dec.read(&buf, 4096, &ch);
        if (n == 0) break;
        total += n;
    }
    try testing.expectEqual(@as(usize, 110250), total);
}

/// Musepack SV8 FATE（44.1k 立体声 456 帧）+ ffmpeg 参考 PCM（decoder.open 全链路 e2e）
const mpc_mp8 = @embedFile("fmt/mpc/samples/inside-mp8.mpc");
const mpc_mp8_s16 = @embedFile("fmt/mpc/samples/inside-mp8.s16");
/// SV7 FATE（44.1k 立体声 456 帧）：open 全接管，首 1s 与 ffmpeg 逐位一致
const mpc_mp7 = @embedFile("fmt/mpc/samples/inside-mp7.mpc");
const mpc_mp7_first1s = @embedFile("fmt/mpc/samples/inside-mp7.first1s.s16");

test "open: .mpc(SV8) 经 probe → 工厂分发端到端（逐位对齐 ffmpeg 参考）" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ioinst = std.Io.Threaded.global_single_threaded.io();
    const f = try tmp.dir.createFile(ioinst, "t.mpc", .{});
    try std.Io.File.writeStreamingAll(f, ioinst, mpc_mp8);
    std.Io.File.close(f, ioinst);
    const full = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "t.mpc" });
    defer testing.allocator.free(full);

    var info: Info = undefined;
    var dec = try open(testing.allocator, full, &info);
    defer dec.deinit();

    try testing.expectEqual(@as(u32, 44100), info.sample_rate);
    try testing.expectEqual(@as(u8, 2), info.channels);
    try testing.expectEqualStrings("mpc8", info.codec_name);
    try testing.expectEqualStrings("mpc8", info.format_name);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(testing.allocator);
    var buf: [65536]u8 = undefined;
    while (true) {
        var ch: u8 = 0;
        const n = try dec.read(&buf, 4096, &ch);
        if (n == 0) break;
        try out.appendSlice(testing.allocator, buf[0 .. n * @as(usize, ch) * 2]);
    }
    try testing.expectEqual(mpc_mp8_s16.len, out.items.len);
    try testing.expectEqualSlices(u8, mpc_mp8_s16, out.items);
}

/// Ogg-Speex（NB q6 mono）+ Shorten（FATE luckynight）e2e：probe → dispatch → 解码
const spx_q6 = @embedFile("fmt/spx/samples/q6_8k.spx");
const spx_q6_ref = @embedFile("fmt/spx/samples/ref_q6_8k.s16");
const shn_lucky = @embedFile("fmt/shn/samples/luckynight-partial.shn");
const tak_lucky = @embedFile("fmt/tak/samples/luckynight-partial.tak");
const tak_lucky_ref = @embedFile("fmt/tak/samples/luckynight-partial.s16");
const shn_lucky_ref = @embedFile("fmt/shn/samples/luckynight-partial.s16");

fn e2eDecodeFull(comptime name: []const u8, comptime payload: []const u8) ![]u8 {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ioinst = std.Io.Threaded.global_single_threaded.io();
    const f = try tmp.dir.createFile(ioinst, name, .{});
    try std.Io.File.writeStreamingAll(f, ioinst, payload);
    std.Io.File.close(f, ioinst);
    const full = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], name });
    defer testing.allocator.free(full);
    var info: Info = undefined;
    var dec = try open(testing.allocator, full, &info);
    defer dec.deinit();
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(testing.allocator);
    var buf: [65536]u8 = undefined;
    while (true) {
        var ch: u8 = 0;
        const n = try dec.read(&buf, 4096, &ch);
        if (n == 0) break;
        try out.appendSlice(testing.allocator, buf[0 .. n * @as(usize, ch) * 2]);
    }
    return out.toOwnedSlice(testing.allocator);
}

test "open: .spx(Ogg-Speex NB q6) 经 probe → 工厂分发端到端（逐位对齐 ffmpeg 参考）" {
    const out = try e2eDecodeFull("t.spx", spx_q6);
    defer testing.allocator.free(out);
    try testing.expectEqual(spx_q6_ref.len, out.len);
    try testing.expectEqualSlices(u8, spx_q6_ref, out);
}


test "open: .tak(FATE luckynight) 经 probe → 工厂分发端到端（逐位对齐 ffmpeg 参考）" {
    const out = try e2eDecodeFull("t.tak", tak_lucky);
    defer testing.allocator.free(out);
    try testing.expectEqual(tak_lucky_ref.len, out.len);
    try testing.expectEqualSlices(u8, tak_lucky_ref, out);
}


test "open: .shn(FATE luckynight) 经 probe → 工厂分发端到端（逐位对齐 ffmpeg 参考）" {
    const out = try e2eDecodeFull("t.shn", shn_lucky);
    defer testing.allocator.free(out);
    try testing.expectEqual(shn_lucky_ref.len, out.len);
    try testing.expectEqualSlices(u8, shn_lucky_ref, out);
}

test "open: .mpc(SV7) 经 probe → 工厂分发端到端（首 1s 逐位对齐 ffmpeg 参考）" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ioinst = std.Io.Threaded.global_single_threaded.io();
    const f = try tmp.dir.createFile(ioinst, "t7.mpc", .{});
    try std.Io.File.writeStreamingAll(f, ioinst, mpc_mp7);
    std.Io.File.close(f, ioinst);
    const full = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "t7.mpc" });
    defer testing.allocator.free(full);

    var info: Info = undefined;
    var dec = try open(testing.allocator, full, &info);
    defer dec.deinit();

    try testing.expectEqual(@as(u32, 44100), info.sample_rate);
    try testing.expectEqual(@as(u8, 2), info.channels);
    try testing.expectEqualStrings("mpc7", info.codec_name);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(testing.allocator);
    var buf: [65536]u8 = undefined;
    while (out.items.len < mpc_mp7_first1s.len) {
        var ch: u8 = 0;
        const n = try dec.read(&buf, 4096, &ch);
        if (n == 0) break;
        try out.appendSlice(testing.allocator, buf[0 .. n * @as(usize, ch) * 2]);
    }
    try testing.expect(out.items.len >= mpc_mp7_first1s.len);
    try testing.expectEqualSlices(u8, mpc_mp7_first1s, out.items[0..mpc_mp7_first1s.len]);
}

/// TTA 真实样本（FATE inside.tta / ffmpeg 编码 mono.tta）+ ffmpeg 参考 PCM
const tta_inside = @embedFile("fmt/tta/samples/inside.tta");
const tta_inside_s16 = @embedFile("fmt/tta/samples/inside.s16");
const tta_mono = @embedFile("fmt/tta/samples/mono.tta");
const tta_mono_s16 = @embedFile("fmt/tta/samples/mono.s16");

test "open: .tta(FATE inside) 经 probe → 工厂分发端到端（逐位对齐 ffmpeg s16le）" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ioinst = std.Io.Threaded.global_single_threaded.io();
    const f = try tmp.dir.createFile(ioinst, "t.tta", .{});
    try std.Io.File.writeStreamingAll(f, ioinst, tta_inside);
    std.Io.File.close(f, ioinst);
    const full = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "t.tta" });
    defer testing.allocator.free(full);

    var info: Info = undefined;
    var dec = try open(testing.allocator, full, &info);
    defer dec.deinit();

    try testing.expectEqual(@as(u32, 44100), info.sample_rate);
    try testing.expectEqual(@as(u8, 2), info.channels);
    try testing.expectEqualStrings("tta", info.codec_name);
    try testing.expectEqualStrings("tta", info.format_name);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(testing.allocator);
    var buf: [65536]u8 = undefined;
    while (true) {
        var ch: u8 = 0;
        const n = try dec.read(&buf, 4096, &ch);
        if (n == 0) break;
        try out.appendSlice(testing.allocator, buf[0 .. n * @as(usize, ch) * 2]);
    }
    try testing.expectEqual(tta_inside_s16.len, out.items.len);
    try testing.expectEqualSlices(u8, tta_inside_s16, out.items);
}

test "open: .tta(mono 44.1k) 经 probe → 工厂分发端到端（逐位对齐 ffmpeg s16le）" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ioinst = std.Io.Threaded.global_single_threaded.io();
    const f = try tmp.dir.createFile(ioinst, "t.tta", .{});
    try std.Io.File.writeStreamingAll(f, ioinst, tta_mono);
    std.Io.File.close(f, ioinst);
    const full = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "t.tta" });
    defer testing.allocator.free(full);

    var info: Info = undefined;
    var dec = try open(testing.allocator, full, &info);
    defer dec.deinit();

    try testing.expectEqual(@as(u32, 44100), info.sample_rate);
    try testing.expectEqual(@as(u8, 1), info.channels);
    try testing.expectEqualStrings("tta", info.codec_name);
    try testing.expectEqualStrings("tta", info.format_name);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(testing.allocator);
    var buf: [65536]u8 = undefined;
    while (true) {
        var ch: u8 = 0;
        const n = try dec.read(&buf, 4096, &ch);
        if (n == 0) break;
        try out.appendSlice(testing.allocator, buf[0 .. n * @as(usize, ch) * 2]);
    }
    try testing.expectEqual(tta_mono_s16.len, out.items.len);
    try testing.expectEqualSlices(u8, tta_mono_s16, out.items);
}
