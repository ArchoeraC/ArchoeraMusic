// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! DSD 解码器（DSF/DFF 容器 + DSD→PCM）
//!
//! 文档（docs/audio-kernel-zig.md §9.11）：DSF（`DSD ` 头 + chunk 表）/ DFF
//! （`FRM8`）容器自研，DSD→PCM 走 1-bit 抽取 + 低通（对照 FFmpeg `dsddec.c` /
//! `dsd.c`，后者基于 Sebastian Gesemann 的 BSD dsd2pcm）。
//!
//! 处理链：
//!   1) 容器解析 → 声道数 / DSD 位率 / 位序（LSBF/MSBF）/ 块布局；
//!   2) dsd2pcm 转译：每 DSD 字节（8 个 1-bit 样本）经 96 抽头对称低通 FIR
//!      （查表 ctables）输出 1 个 f64，采样率 = DSD 位率/8；
//!   3) 8× 抽取：窗函数 sinc 低通（截止 ~20kHz，对齐 44.1k 倍率输出）→ s16。
//!
//! 输出契约：原生 16-bit、交错 PCM，采样率 = DSD 位率/64（DSD64→44.1k、
//! DSD128→88.2k、DSD256→176.4k）。DSD 为 1-bit 有损转换（"软 DSD"路径），
//! 对照 ffmpeg dsddec 以波形相关/频谱验证（非 bit-exact）。
//!
//! DFF-DST（SACD 镜像常用 DST 压缩 DSD）：'FRM8' form 'DSD '/'DST ' + PROP
//! （FS/CHNL/CMPR='DST '）→ 'DST ' chunk 内含 FRTE 帧表与一串 'DSTF' 帧；
//! 每 DSTF 帧为独立 DST 压缩单元，经 dst/dst.zig（FFmpeg dstdec.c 逐句移植）
//! 重建每声道 DSD 位流（fate dst-64fs44-2ch 与 ffmpeg f32 输出逐位一致），
//! 再复用本文件的 dsd2pcm + 8× 抽取路径输出 PCM。dst2pcm 状态按 ffmpeg
//! decode_init 以 0x69 初始化 fifo。

const std = @import("std");
const Error = @import("../error.zig").Error;
const io = @import("../io.zig");
const decoder = @import("../decoder.zig");
const dstcodec = @import("dst/dst.zig");
const id3 = @import("mp3/id3.zig");

// ---- dsd2pcm 常量（FFmpeg dsd.c / Gesemann BSD dsd2pcm） ----

const HTAPS: usize = 48;
const CTABLES: usize = (HTAPS + 7) / 8; // 6
const FIFOSIZE: usize = 16;

/// 96 抽头对称低通滤波器的后半（48 系数）
const htaps = [HTAPS]f64{
    0.09950731974056658, 0.09562845727714668, 0.08819647126516944,
    0.07782552527068175, 0.06534876523171299, 0.05172629311427257,
    0.0379429484910187,  0.02490921351762261, 0.0133774746265897,
    0.003883043418804416, -0.003284703416210726, -0.008080250212687497,
    -0.01067241812471033, -0.01139427235000863, -0.0106813877974587,
    -0.009007905078766049, -0.006828859761015335, -0.004535184322001496,
    -0.002425035959059578, -0.0006922187080790708, 0.0005700762133516592,
    0.001353838005269448, 0.001713709169690937, 0.001742046839472948,
    0.001545601648013235, 0.001226696225277855, 0.0008704322683580222,
    0.0005381636200535649, 0.000266446345425276, 7.002968738383528e-05,
    -5.279407053811266e-05, -0.0001140625650874684, -0.0001304796361231895,
    -0.0001189970287491285, -9.396247155265073e-05, -6.577634378272832e-05,
    -4.07492895872535e-05, -2.17407957554587e-05, -9.163058931391722e-06,
    -2.017460145032201e-06, 1.249721855219005e-06, 2.166655190537392e-06,
    1.930520892991082e-06, 1.319400334374195e-06, 7.410039764949091e-07,
    3.423230509967409e-07, 1.244182214744588e-07, 3.130441005359396e-08,
};

fn bitReverse(b: u8) u8 {
    var v: u8 = b;
    var r: u8 = 0;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        r = (r << 1) | (v & 1);
        v >>= 1;
    }
    return r;
}
const ff_reverse = blk: {
    @setEvalBranchQuota(100000);
    var t: [256]u8 = undefined;
    for (0..256) |i| t[i] = bitReverse(@intCast(i));
    break :blk t;
};

const ctables_msbf = blk: {
    @setEvalBranchQuota(1000000);
    var t: [CTABLES][256]f64 = undefined;
    for (0..256) |e| {
        var acc: [CTABLES]f64 = [_]f64{0} ** CTABLES;
        for (0..8) |m| {
            const sign: f64 = if (((e >> (7 - m)) & 1) != 0) 1.0 else -1.0;
            for (0..CTABLES) |t2| acc[t2] += sign * htaps[t2 * 8 + m];
        }
        for (0..CTABLES) |t2| t[CTABLES - 1 - t2][e] = acc[t2];
    }
    break :blk t;
};
const ctables_lsbf = blk: {
    @setEvalBranchQuota(1000000);
    var t: [CTABLES][256]f64 = undefined;
    for (0..256) |e| {
        var acc: [CTABLES]f64 = [_]f64{0} ** CTABLES;
        for (0..8) |m| {
            const sign: f64 = if (((e >> (7 - m)) & 1) != 0) 1.0 else -1.0;
            for (0..CTABLES) |t2| acc[t2] += sign * htaps[t2 * 8 + m];
        }
        for (0..CTABLES) |t2| t[CTABLES - 1 - t2][ff_reverse[e]] = acc[t2];
    }
    break :blk t;
};

/// dsd2pcm 转译：每输入字节 → 1 个 f64 样本（DSD 位率/8）。
fn dsd2pcmTranslate(fifo: *[FIFOSIZE]u8, pos: *u8, lsbf: bool, src: []const u8, dst: []f64) void {
    const ctables: *const [CTABLES][256]f64 = if (lsbf) &ctables_lsbf else &ctables_msbf;
    var p: usize = pos.*;
    for (src, 0..) |b, i_out| {
        fifo[p] = b;
        const rp = (p -% 6) & (FIFOSIZE - 1);
        fifo[rp] = ff_reverse[fifo[rp]];
        var sum: f64 = 0;
        for (0..CTABLES) |i| {
            const a = fifo[(p -% i) & (FIFOSIZE - 1)];
            const b2 = fifo[(p -% (CTABLES * 2 - 1) +% i) & (FIFOSIZE - 1)];
            sum += ctables[i][a] + ctables[i][b2];
        }
        dst[i_out] = sum;
        p = (p + 1) & (FIFOSIZE - 1);
    }
    pos.* = @intCast(p);
}

// ---- 8× 抽取低通（窗函数 sinc） ----

const FIR_TAPS: usize = 256;
const DECIM: usize = 8;

fn makeLowpass(comptime L: usize, fc_norm: f64) [L]f64 {
    const M: f64 = @floatFromInt(L - 1);
    var h: [L]f64 = undefined;
    for (0..L) |n| {
        const xn: f64 = @floatFromInt(n);
        const x = xn - M / 2.0;
        const s: f64 = if (x == 0)
            2 * fc_norm
        else
            @sin(2 * std.math.pi * fc_norm * x) / (std.math.pi * x);
        const w = 0.54 - 0.46 * @cos(2 * std.math.pi * xn / M);
        h[n] = s * w;
    }
    // 归一化 DC 增益 = 1
    var dc: f64 = 0;
    for (h) |v| dc += v;
    for (&h) |*v| v.* /= dc;
    return h;
}
const fir_coeffs = makeLowpass(FIR_TAPS, 20000.0 / 352800.0);

/// 每声道 8× 抽取状态：维护 FIR 环 + 8 个计数。
const DecimState = struct {
    buf: [FIR_TAPS]f64 = [_]f64{0} ** FIR_TAPS,
    pos: usize = 0,
    pending: usize = 0,
    started: bool = false,
    warmup_left: usize = 0,

    /// 喂入一个 dsd2pcm f64 样本；每 8 个产出一个抽取样本（null = 未到）。
    fn push(self: *DecimState, x: f64) ?f64 {
        self.buf[self.pos] = x;
        self.pos = (self.pos + 1) % FIR_TAPS;
        self.pending += 1;
        if (self.pending < DECIM) return null;
        self.pending = 0;
        if (!self.started) {
            // 丢弃前 (FIR_TAPS/DECIM) 个（滤波器预热）
            self.started = true;
            self.warmup_left = FIR_TAPS / DECIM;
        }
        if (self.warmup_left > 0) {
            self.warmup_left -= 1;
            return null;
        }
        var sum: f64 = 0;
        for (0..FIR_TAPS) |k| {
            const idx = (self.pos + FIR_TAPS - 1 -% k) % FIR_TAPS;
            sum += fir_coeffs[k] * self.buf[idx];
        }
        return sum;
    }
};

// ---- 容器解析 ----

const Ctx = struct {
    allocator: std.mem.Allocator,
    reader: io.Reader,

    channels: u8 = 0,
    /// DSD 位率（如 DSD64 = 2822400）
    dsd_rate: u32 = 0,
    /// 输出采样率 = dsd_rate / 64
    out_rate: u32 = 0,
    lsbf: bool = false,
    /// 块大小（字节/声道，DSF block_size 字段为字节数）
    block_bytes: usize = 4096,
    /// 数据起始偏移
    data_off: u64 = 0,
    /// 每声道数据字节数
    ch_bytes: u64 = 0,
    /// DFF 是否字节交错
    interleaved: bool = false,
    /// DFF 是否 DST 压缩（PROP/CMPR = 'DST ' 且存在 'DST ' 帧 chunk）
    compressed: bool = false,
    /// DFF 容器名（info.format_name：dff / dsf）
    is_dff: bool = false,

    /// DFF-DST：DSTF 帧的绝对文件偏移 / 载荷长度（parse 时分配，deinit 释放）
    frame_off: []u64 = &.{},
    frame_size: []u32 = &.{},
    frame_count: usize = 0,
    /// 当前 DST 帧游标（每帧 = samples_per_frame 位/声道）
    frame_index: usize = 0,
    /// 每帧每声道产生的 DSD 字节数（= samples_per_frame / 8）
    dst_frame_bytes: usize = 0,
    /// DST 帧解码器（压缩时分配）
    dst_dec: ?*dstcodec.Decoder = null,

    /// DSD 数据读取游标（每声道字节偏移；DST 不使用）
    ch_read: [16]u64 = [_]u64{0} ** 16,
    eof: bool = false,
    total_done: u64 = 0,

    /// 每声道 DSP 状态
    fifo: [16][FIFOSIZE]u8 = [_][FIFOSIZE]u8{[_]u8{0} ** FIFOSIZE} ** 16,
    fifo_pos: [16]u8 = [_]u8{0} ** 16,
    decim: [16]DecimState = [_]DecimState{.{}} ** 16,

    /// 解码输出缓冲（交错 s16）
    pcm: std.ArrayList(i16) = .empty,
    pcm_pos: usize = 0,
};

pub fn open(allocator: std.mem.Allocator, reader: *io.Reader, info: *decoder.Info) Error!decoder.Decoder {
    const f = try allocator.create(Ctx);
    errdefer allocator.destroy(f);
    f.* = .{ .allocator = allocator, .reader = reader.* };
    errdefer f.reader.deinit();
    errdefer freeState(f);
    try parseContainer(f);

    info.* = .{
        .sample_rate = f.out_rate,
        .channels = f.channels,
        .bits_per_sample = 16,
        .is_float = false,
        .duration_us = if (f.out_rate > 0)
            // 四舍五入到 µs（对齐 ffprobe 显示）
            @intCast((@as(u128, f.ch_bytes * 8) * 1_000_000 + f.dsd_rate / 2) / f.dsd_rate)
        else
            0,
        .duration_known = if (f.out_rate > 0) .exact else .unknown,
        .codec_name = "dsd",
        .format_name = if (f.is_dff) "dff" else "dsf",
        .metadata = .{},
    };
    return .{ .vtable = &vtable, .ctx = f };
}

// ---------------------------------------------------------------------------
// 元数据专用快路径（probe-only，§8.4.2①）：容器头 + 尾部/内嵌 ID3v2，不建解码状态。
// ---------------------------------------------------------------------------

const MetaCtx = struct {
    allocator: std.mem.Allocator,
    f: *Ctx,
    meta: decoder.Metadata,
    pics: []decoder.Picture,
};

fn metaDeinit(p: *anyopaque) void {
    const ctx: *MetaCtx = @ptrCast(@alignCast(p));
    id3.freeMeta(ctx.allocator, &ctx.meta);
    id3.freePictures(ctx.allocator, &ctx.pics);
    freeState(ctx.f);
    ctx.allocator.destroy(ctx.f);
    ctx.allocator.destroy(ctx);
}

/// DSF：头偏移 20 处 u64 LE = ID3v2 标签起点（0 = 无）。
/// DFF：chunk 流中 `ID3 ` chunk 内即 ID3v2。
fn parseDsdTags(
    f: *Ctx,
    allocator: std.mem.Allocator,
    meta: *decoder.Metadata,
    pics: *[]decoder.Picture,
    rg: *decoder.ReplayGain,
) Error!void {
    if (f.is_dff) {
        var h: [16]u8 = undefined;
        try f.reader.seek(0, .start);
        const n = try f.reader.read(&h);
        if (n < 16) return;
        const frm_size = std.mem.readInt(u64, h[4..12], .big);
        const frm_end = 12 + frm_size;
        var off: u64 = 16;
        while (off + 12 <= frm_end) {
            var ch: [12]u8 = undefined;
            try f.reader.seek(@intCast(off), .start);
            const m = try f.reader.read(&ch);
            if (m < 12) break;
            const size = std.mem.readInt(u64, ch[4..12], .big);
            if (std.mem.eql(u8, ch[0..4], "ID3 ")) {
                _ = try id3.parseV2(&f.reader, allocator, off + 12, meta, pics, rg);
                break;
            }
            off += 12 + size + (size & 1);
        }
        return;
    }
    // DSF
    try f.reader.seek(20, .start);
    var b: [8]u8 = undefined;
    const n = try f.reader.read(&b);
    if (n < 8) return;
    const off = std.mem.readInt(u64, b[0..8], .little);
    if (off == 0) return;
    const fsize = f.reader.size() catch return;
    if (off >= fsize) return;
    _ = try id3.parseV2(&f.reader, allocator, off, meta, pics, rg);
}

pub fn openMeta(allocator: std.mem.Allocator, reader: *io.Reader, info: *decoder.Info) Error!decoder.MetadataSession {
    const f = try allocator.create(Ctx);
    errdefer allocator.destroy(f);
    f.* = .{ .allocator = allocator, .reader = reader.* };
    errdefer f.reader.deinit();
    errdefer freeState(f);
    try parseContainer(f);

    var meta: decoder.Metadata = .{};
    var pics: []decoder.Picture = &.{};
    var rg: decoder.ReplayGain = .{};
    errdefer {
        id3.freeMeta(allocator, &meta);
        id3.freePictures(allocator, &pics);
    }
    parseDsdTags(f, allocator, &meta, &pics, &rg) catch {};

    const ctx = try allocator.create(MetaCtx);
    ctx.* = .{ .allocator = allocator, .f = f, .meta = meta, .pics = pics };

    info.* = .{
        .sample_rate = f.out_rate,
        .channels = f.channels,
        .bits_per_sample = 16,
        .is_float = false,
        .duration_us = if (f.out_rate > 0)
            @intCast((@as(u128, f.ch_bytes * 8) * 1_000_000 + f.dsd_rate / 2) / f.dsd_rate)
        else
            0,
        .duration_known = if (f.out_rate > 0) .exact else .unknown,
        .codec_name = "dsd",
        .format_name = if (f.is_dff) "dff" else "dsf",
        .metadata = meta,
        .pictures = pics,
        .replay_gain = rg,
    };
    return .{ .ctx = @ptrCast(ctx), .deinit_fn = metaDeinit };
}

fn parseContainer(f: *Ctx) Error!void {    var hdr: [12]u8 = undefined;
    const n = try f.reader.peek(&hdr);
    if (n < 12) return error.Corrupt;
    if (std.mem.eql(u8, hdr[0..4], "DSD ")) {
        try parseDsf(f);
    } else if (std.mem.eql(u8, hdr[0..4], "FRM8")) {
        try parseDff(f);
    } else {
        return error.Corrupt;
    }
    if (f.channels == 0 or f.channels > 16 or f.dsd_rate == 0 or f.ch_bytes == 0) return error.Corrupt;
    f.out_rate = f.dsd_rate / 64;
    if (f.out_rate == 0) return error.Corrupt;
}

fn parseDsf(f: *Ctx) Error!void {
    // 头（28 字节）+ fmt chunk（52 字节）固定在文件首
    var buf: [92]u8 = undefined;
    const got = try f.reader.read(&buf);
    if (got < 92) return error.Corrupt;
    if (!std.mem.eql(u8, buf[0..4], "DSD ")) return error.Corrupt;
    if (!std.mem.eql(u8, buf[28..32], "fmt ")) return error.Corrupt;
    const channels = std.mem.readInt(u32, buf[52..56], .little);
    const dsd_rate = std.mem.readInt(u32, buf[56..60], .little);
    const bits_per_sample = std.mem.readInt(u32, buf[60..64], .little);
    const sample_count = std.mem.readInt(u64, buf[64..72], .little);
    const block_size_bits = std.mem.readInt(u32, buf[72..76], .little);

    f.channels = @intCast(channels);
    f.dsd_rate = dsd_rate;
    f.lsbf = (bits_per_sample == 1);
    // DSF block_size 字段 = 每声道每块的字节数（DSD64 典型 4096）
    f.block_bytes = block_size_bits;
    if (f.block_bytes == 0) return error.Corrupt;
    f.ch_bytes = sample_count / 8;
    f.data_off = 92;
    f.interleaved = false;
    // 时长对齐 ffprobe（dsfdec）：按 Data 区实际可用字节整块取整，不信任
    // sample_count 元数据字段（截断/手工文件的 sample_count 可能与数据不符）。
    // 整块取整后与解码路径一致（解码按块读取）。size 不可得时保留声明值。
    if (f.reader.size()) |avail_total| {
        if (avail_total > f.data_off) {
            const per_ch = (avail_total - f.data_off) / f.channels;
            const whole_blocks = per_ch / f.block_bytes;
            if (whole_blocks > 0) f.ch_bytes = whole_blocks * f.block_bytes;
        }
    } else |_| {}
}

fn parseDff(f: *Ctx) Error!void {
    f.is_dff = true;
    // FRM8 大小端为 BE。容器结构（对齐 FFmpeg libavformat/iff.c）：
    //   'FRM8' + size(8BE) + form_type('DSD '/'DST ') + chunks
    //   PROP chunk data = 'SND '(无 size) + 属性表（每项 tag+size(8BE)+data）
    //     —— FS  = DSD 位率、CHNL = 通道数 + 通道代码、CMPR = 压缩码（'DSD '/'DST '）
    //   未压缩：顶层 'DSD ' chunk 即字节交错 DSD 数据；
    //   压缩：顶层 'DST ' chunk 内含 'FRTE'（帧数）与一串 'DSTF' 帧。
    var tag_buf: [16]u8 = undefined;
    const got = try f.reader.read(&tag_buf);
    if (got < 16) return error.Corrupt;
    if (!std.mem.eql(u8, tag_buf[0..4], "FRM8")) return error.Corrupt;
    if (!std.mem.eql(u8, tag_buf[12..16], "DSD ") and !std.mem.eql(u8, tag_buf[12..16], "DST ")) return error.Corrupt;
    const frm_size = std.mem.readInt(u64, tag_buf[4..12], .big);
    const frm_end = 12 + frm_size;
    // FRM8 头 = 'FRM8'(4) + size(8) + form_type(4)；chunk 从偏移 16 开始
    var off: u64 = 16;
    var found_data = false;
    var raw_size: u64 = 0;
    while (off + 12 <= frm_end) {
        var ch: [12]u8 = undefined;
        try f.reader.seek(@intCast(off), .start);
        const m = try f.reader.read(&ch);
        if (m < 12) break;
        const tag = ch[0..4];
        const size = std.mem.readInt(u64, ch[4..12], .big);
        if (std.mem.eql(u8, tag, "DSD ")) {
            // 未压缩 DSD 数据：从 off+12 开始，字节交错
            f.data_off = off + 12;
            f.interleaved = true;
            found_data = true;
            raw_size = size;
        } else if (std.mem.eql(u8, tag, "PROP")) {
            try parseDffProp(f, off + 12, off + 12 + size);
        } else if (std.mem.eql(u8, tag, "DST ")) {
            try parseDstChunk(f, off + 12, off + 12 + size);
        }
        off += 12 + size + (size & 1);
    }
    if (f.compressed) {
        const fb = dstFrameBytes(f.dsd_rate) orelse return error.UnsupportedFormat;
        if (f.frame_count == 0) return error.Corrupt;
        if (f.channels == 0 or f.channels > dstcodec.max_channels) return error.UnsupportedFormat;
        f.dst_frame_bytes = fb;
        f.ch_bytes = @as(u64, f.frame_count) * fb;
        const dec = try f.allocator.create(dstcodec.Decoder);
        dec.* = .{};
        f.dst_dec = dec;
        // ffmpeg dst decode_init：dsd2pcm FIFO 以 0x69 填充
        for (0..f.channels) |ch| f.fifo[ch] = [_]u8{0x69} ** FIFOSIZE;
    } else {
        if (!found_data or f.channels == 0) return error.Corrupt;
        f.ch_bytes = raw_size / f.channels;
    }
}

fn parseDffProp(f: *Ctx, start: u64, end: u64) Error!void {
    // PROP data = 'SND '(4cc，无 size) + 属性条目
    var snd: [4]u8 = undefined;
    try f.reader.seek(@intCast(start), .start);
    const sm = try f.reader.read(&snd);
    if (sm < 4 or !std.mem.eql(u8, &snd, "SND ")) return error.Corrupt;
    var off: u64 = start + 4;
    while (off + 12 <= end) {
        var ch: [12]u8 = undefined;
        try f.reader.seek(@intCast(off), .start);
        const m = try f.reader.read(&ch);
        if (m < 12) break;
        const tag = ch[0..4];
        const size = std.mem.readInt(u64, ch[4..12], .big);
        if (std.mem.eql(u8, tag, "FS  ") and size >= 4) {
            var v: [4]u8 = undefined;
            _ = try f.reader.read(&v);
            f.dsd_rate = std.mem.readInt(u32, &v, .big);
        } else if (std.mem.eql(u8, tag, "CHNL") and size >= 2) {
            var v: [2]u8 = undefined;
            _ = try f.reader.read(&v);
            f.channels = @intCast(std.mem.readInt(u16, &v, .big));
        } else if (std.mem.eql(u8, tag, "CMPR") and size >= 4) {
            var v: [4]u8 = undefined;
            _ = try f.reader.read(&v);
            // 压缩码 'DST ' → 需走 DST 帧解码；'DSD ' 为未压缩
            f.compressed = std.mem.eql(u8, &v, "DST ");
        }
        off += 12 + size + (size & 1);
    }
}

/// 解析 'DST ' chunk：跳过元 chunk（FRTE/DSTC 等），收集全部 DSTF 帧
/// （每帧载荷为一个 DST 压缩单元）。两遍扫描：先计数后填充偏移表。
/// 帧参数（dst_frame_bytes / 解码器）在 parseDff 全表扫描后统一校验，
/// 以容忍 PROP（提供 dsd_rate）出现在 'DST ' chunk 之后。
fn parseDstChunk(f: *Ctx, start: u64, end: u64) Error!void {
    var off = start;
    var count: usize = 0;
    while (off + 12 <= end) {
        var ch: [12]u8 = undefined;
        try f.reader.seek(@intCast(off), .start);
        const m = try f.reader.read(&ch);
        if (m < 12) break;
        const tag = ch[0..4];
        const size = std.mem.readInt(u64, ch[4..12], .big);
        if (std.mem.eql(u8, tag, "DSTF")) count += 1;
        off += 12 + size + (size & 1);
    }
    if (count == 0) return error.Corrupt;

    const frame_off = try f.allocator.alloc(u64, count);
    errdefer f.allocator.free(frame_off);
    const frame_size = try f.allocator.alloc(u32, count);
    errdefer f.allocator.free(frame_size);

    off = start;
    var idx: usize = 0;
    while (off + 12 <= end and idx < count) {
        var ch: [12]u8 = undefined;
        try f.reader.seek(@intCast(off), .start);
        const m = try f.reader.read(&ch);
        if (m < 12) break;
        const tag = ch[0..4];
        const size = std.mem.readInt(u64, ch[4..12], .big);
        if (std.mem.eql(u8, tag, "DSTF")) {
            if (size == 0 or size > std.math.maxInt(u32)) return error.Corrupt;
            frame_off[idx] = off + 12;
            frame_size[idx] = @intCast(size);
            idx += 1;
        }
        off += 12 + size + (size & 1);
    }
    if (idx != count) return error.Corrupt;

    f.frame_off = frame_off;
    f.frame_size = frame_size;
    f.frame_count = count;
    f.compressed = true;
}

/// 每帧每声道 DSD 字节数（DST_SAMPLES_PER_FRAME = 588×(rate/44100)，%8==0）
fn dstFrameBytes(dsd_rate: u32) ?usize {
    if (dsd_rate == 0 or dsd_rate % 44100 != 0) return null;
    const mult = dsd_rate / 44100;
    const samples = @as(u64, 588) * mult;
    if (samples & 7 != 0) return null;
    return @intCast(samples / 8);
}

// ---- 解码 ----

const VTable = decoder.Decoder.VTable;
const vtable = VTable{
    .read = readImpl,
    .seek_ms = seekMsImpl,
    .position_ms = positionMsImpl,
    .deinit = deinitImpl,
};

fn readImpl(ctx: *anyopaque, out: []u8, max_samples: usize, out_channels: *u8) Error!usize {
    const f: *Ctx = @ptrCast(@alignCast(ctx));
    out_channels.* = f.channels;
    if (max_samples == 0 or out.len == 0) return 0;

    const frame_bytes = @as(usize, f.channels) * 2;
    const cap = @min(max_samples, out.len / frame_bytes);
    var produced: usize = 0;
    while (produced < cap) {
        if (f.pcm_pos * f.channels >= f.pcm.items.len) {
            f.pcm.clearRetainingCapacity();
            f.pcm_pos = 0;
            if (!try decodeMore(f)) break;
            continue;
        }
        const avail = (f.pcm.items.len / f.channels) - f.pcm_pos;
        const take = @min(avail, cap - produced);
        const src_off = f.pcm_pos * frame_bytes;
        @memcpy(out[produced * frame_bytes ..][0 .. take * frame_bytes], std.mem.sliceAsBytes(f.pcm.items)[src_off .. src_off + take * frame_bytes]);
        f.pcm_pos += take;
        produced += take;
    }
    return produced;
}

/// 读入一个 DSD 块 → dsd2pcm → 8× 抽取 → s16 交错输出到 pcm。
/// 每调用处理一个块（每声道 block_bytes），推进全部声道游标。
fn decodeMore(f: *Ctx) Error!bool {
    if (f.compressed) return decodeMoreDst(f);
    if (f.channels == 0 or f.ch_read[0] >= f.ch_bytes) return false;
    const block_idx = f.ch_read[0] / f.block_bytes;
    const in_blk: usize = @intCast(f.ch_read[0] % f.block_bytes);
    const take: usize = @intCast(@min(@as(u64, f.block_bytes) - in_blk, f.ch_bytes - f.ch_read[0]));
    if (take == 0) return false;
    const blk_total: usize = @as(usize, f.channels) * f.block_bytes;

    const ibuf = try f.allocator.alloc(u8, blk_total);
    defer f.allocator.free(ibuf);

    // 每声道：读一块 → dsd2pcm → 8× 抽取，收集该块产生的抽取样本
    var ch_out: [16]std.ArrayList(f64) = undefined;
    for (0..f.channels) |ch| ch_out[ch] = .empty;
    defer for (0..f.channels) |ch| ch_out[ch].deinit(f.allocator);

    if (f.interleaved) {
        // DFF：字节交错块 = channels × take
        const block_off = f.data_off + block_idx * f.block_bytes * f.channels + in_blk * f.channels;
        try f.reader.seek(@intCast(block_off), .start);
        const m = try f.reader.read(ibuf[0 .. take * f.channels]);
        if (m == 0) return false;
        const nbytes: usize = m / f.channels;
        for (0..f.channels) |ch| {
            var seg: [8192]u8 = undefined;
            const src: []u8 = if (nbytes > seg.len) try f.allocator.alloc(u8, nbytes) else seg[0..nbytes];
            defer if (nbytes > seg.len) f.allocator.free(src);
            for (0..nbytes) |k| src[k] = ibuf[k * f.channels + ch];
            try processChannel(f, ch, src[0..nbytes], &ch_out[ch]);
            f.ch_read[ch] = block_idx * f.block_bytes + in_blk + nbytes;
        }
    } else {
        // DSF：平面块布局，每声道连续
        for (0..f.channels) |ch| {
            const off = f.data_off + block_idx * blk_total + ch * f.block_bytes + in_blk;
            try f.reader.seek(@intCast(off), .start);
            const m = try f.reader.read(ibuf[0..take]);
            if (m == 0) continue;
            try processChannel(f, ch, ibuf[0..m], &ch_out[ch]);
            f.ch_read[ch] = block_idx * f.block_bytes + in_blk + m;
        }
    }

    // 交错：每声道各取一个样本 → [ch0, ch1, ...] 帧
    try appendInterleaved(f, &ch_out);
    return true;
}

/// DFF-DST：解码一个 DSTF 帧 → 逐声道 DSD 字节 → dsd2pcm → 8× 抽取 → 交错。
fn decodeMoreDst(f: *Ctx) Error!bool {
    if (f.frame_index >= f.frame_count) return false;
    const dec = f.dst_dec orelse return error.DecodeFailed;
    const channels: usize = f.channels;
    const nb = f.dst_frame_bytes;

    const size = f.frame_size[f.frame_index];
    const payload = try f.allocator.alloc(u8, size);
    defer f.allocator.free(payload);
    try f.reader.seek(@intCast(f.frame_off[f.frame_index]), .start);
    const m = try f.reader.read(payload);
    if (m < size) return error.Corrupt;

    const out_dsd = try f.allocator.alloc(u8, nb * channels);
    defer f.allocator.free(out_dsd);
    try dec.decodeFrame(payload, channels, nb, out_dsd);

    // 每声道：解交错 → dsd2pcm → 8× 抽取
    var ch_out: [16]std.ArrayList(f64) = undefined;
    for (0..channels) |ch| ch_out[ch] = .empty;
    defer for (0..channels) |ch| ch_out[ch].deinit(f.allocator);

    const plane = try f.allocator.alloc(u8, nb);
    defer f.allocator.free(plane);
    for (0..channels) |ch| {
        for (0..nb) |s| plane[s] = out_dsd[s * channels + ch];
        try processChannel(f, ch, plane, &ch_out[ch]);
    }
    f.frame_index += 1;

    try appendInterleaved(f, &ch_out);
    return true;
}

/// 将各声道抽取样本按帧交错成 s16 追加到 pcm（声道不等长时以 0 补足）。
fn appendInterleaved(f: *Ctx, ch_out: *const [16]std.ArrayList(f64)) Error!void {
    var n: usize = 0;
    while (true) {
        var has = false;
        for (0..f.channels) |ch| {
            if (n < ch_out[ch].items.len) has = true;
        }
        if (!has) break;
        for (0..f.channels) |ch| {
            if (n < ch_out[ch].items.len) {
                const y: f32 = @floatCast(ch_out[ch].items[n]);
                var iv: i32 = @intFromFloat(y * 32767.0);
                if (iv < -32768) iv = -32768;
                if (iv > 32767) iv = 32767;
                try f.pcm.append(f.allocator, @intCast(iv));
            } else {
                try f.pcm.append(f.allocator, 0);
            }
        }
        n += 1;
    }
}

/// 单声道 DSD 字节 → dsd2pcm → 8× 抽取 → 追加到该声道抽取样本。
fn processChannel(f: *Ctx, ch: usize, src: []const u8, out: *std.ArrayList(f64)) Error!void {
    var tmp: [8192]f64 = undefined;
    const dst: []f64 = if (src.len > tmp.len) try f.allocator.alloc(f64, src.len) else tmp[0..src.len];
    defer if (src.len > tmp.len) f.allocator.free(dst);
    dsd2pcmTranslate(&f.fifo[ch], &f.fifo_pos[ch], f.lsbf, src, dst);
    for (dst) |x| {
        if (f.decim[ch].push(x)) |y| try out.append(f.allocator, y);
    }
}

fn positionMsImpl(ctx: *anyopaque) i64 {
    const f: *Ctx = @ptrCast(@alignCast(ctx));
    if (f.out_rate == 0) return 0;
    if (f.compressed) {
        // 已解码完的 DST 帧数 → 位
        const done: u64 = @as(u64, f.frame_index) * f.dst_frame_bytes * 8;
        return @intCast((@as(u128, done) * 1000) / f.dsd_rate);
    }
    const done: u64 = if (f.channels > 0) f.ch_read[0] * 8 else 0;
    return @intCast((@as(u128, done) * 1000) / f.dsd_rate);
}

fn seekMsImpl(ctx: *anyopaque, ms: i64) Error!void {
    const f: *Ctx = @ptrCast(@alignCast(ctx));
    if (f.out_rate == 0) return error.UnsupportedFormat;
    // 重置 DSP 状态（DSD 为内嵌抽取，seek 后需重建滤波状态）
    if (f.compressed) {
        const bits_per_frame: u64 = @as(u64, f.dst_frame_bytes) * 8;
        const target_frame: usize = if (ms <= 0 or bits_per_frame == 0)
            0
        else
            @intCast(@min(
                @as(u64, f.frame_count),
                @divTrunc(@as(u128, @intCast(ms)) * f.dsd_rate, 1000) / bits_per_frame,
            ));
        f.frame_index = target_frame;
        for (0..f.channels) |ch| {
            f.fifo[ch] = [_]u8{0x69} ** FIFOSIZE;
            f.fifo_pos[ch] = 0;
            f.decim[ch] = .{};
        }
    } else {
        const target_bits: u64 = if (ms <= 0)
            0
        else
            @intCast(@divTrunc(@as(u128, @intCast(ms)) * f.dsd_rate, 1000));
        const target_byte: u64 = @min(target_bits / 8, f.ch_bytes);
        for (0..f.channels) |ch| {
            f.ch_read[ch] = target_byte;
            f.fifo[ch] = [_]u8{0} ** FIFOSIZE;
            f.fifo_pos[ch] = 0;
            f.decim[ch] = .{};
        }
    }
    f.total_done = 0;
    f.pcm.clearRetainingCapacity();
    f.pcm_pos = 0;
}

/// 释放容器/解码期间分配的 Ctx 资源（不含 reader/deinit 本身）。
fn freeState(f: *Ctx) void {
    if (f.frame_off.len > 0) f.allocator.free(f.frame_off);
    if (f.frame_size.len > 0) f.allocator.free(f.frame_size);
    if (f.dst_dec) |d| f.allocator.destroy(d);
    f.frame_off = &.{};
    f.frame_size = &.{};
    f.dst_dec = null;
}

fn deinitImpl(ctx: *anyopaque) void {
    const f: *Ctx = @ptrCast(@alignCast(ctx));
    f.pcm.deinit(f.allocator);
    freeState(f);
    f.reader.deinit();
    f.allocator.destroy(f);
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

test "dsd: DFF-DST seek（帧边界）后再解码" {
    var reader = io.Reader.openMem(dst_sample);
    var info: decoder.Info = undefined;
    var dc = try open(std.testing.allocator, &reader, &info);
    defer dc.deinit();
    try dc.seekMs(0);
    try std.testing.expectEqual(@as(i64, 0), dc.positionMs());

    var buf: [65536]u8 = undefined;
    var ch: u8 = 0;
    // 跳到 ~80ms（≈6 帧边界）
    try dc.seekMs(80);
    const pos = dc.positionMs();
    // 位置应在 80ms ± 1 帧（13.3ms）
    try std.testing.expect(pos >= 66 and pos <= 100);
    var total: usize = 0;
    while (true) {
        const n = try dc.read(&buf, 4096, &ch);
        if (n == 0) break;
        total += n;
        if (total > 1 << 22) break;
    }
    // 剩余 4 帧左右：每声道 4×588 − 重建 32 ≈ 2320
    try std.testing.expect(total > 2000);
    try std.testing.expectEqual(@as(u8, 2), ch);
}

test "dsd: DSF 集成解码（open + 读取 + 时长）" {
    const data = @embedFile("dsd_tiny.dsf");
    var reader = io.Reader.openMem(data);
    var info: decoder.Info = undefined;
    var dc = try open(std.testing.allocator, &reader, &info);
    defer dc.deinit();
    try std.testing.expectEqual(@as(u8, 1), info.channels);
    try std.testing.expectEqual(@as(u32, 44100), info.sample_rate);
    try std.testing.expect(info.duration_us > 0);

    var buf: [8192]u8 = undefined;
    var ch: u8 = 0;
    var total: usize = 0;
    while (true) {
        const n = try dc.read(&buf, 2048, &ch);
        if (n == 0) break;
        total += n * ch * 2;
        if (total > 1024 * 1024) break;
    }
    try std.testing.expect(total > 0);
    try std.testing.expectEqual(@as(u8, 1), ch);
}

/// FATE `dst/dst-64fs44-2ch.dff`：DSD64 立体声，10 DSTF 帧，压缩载荷 DST。
const dst_sample = @embedFile("dst/samples/dst-64fs44-2ch.dff");
/// 参考：系统 ffmpeg `dst` 解码器直接输出（f32le 交错 352800Hz），
/// 即 ffmpeg dstdec + dsd.c（fifo 0x69 初值）逐帧译码的 float 结果。
const dst_golden_f32 = @embedFile("dst/samples/dst-64fs44-2ch.f32");

test "dsd: DFF-DST（FATE dst-64fs44-2ch）open + 全量读取" {
    var reader = io.Reader.openMem(dst_sample);
    var info: decoder.Info = undefined;
    var dc = try open(std.testing.allocator, &reader, &info);
    defer dc.deinit();
    try std.testing.expectEqual(@as(u8, 2), info.channels);
    try std.testing.expectEqual(@as(u32, 44100), info.sample_rate);
    try std.testing.expectEqualStrings("dsd", info.codec_name);
    try std.testing.expectEqualStrings("dff", info.format_name);
    // 10 帧 × (588×64 位/8)/声道 = 47040 位/声道 → 4704×10 DSD 字节/声道
    try std.testing.expectEqual(@as(i64, 133333), info.duration_us);

    var total: usize = 0;
    var buf: [65536]u8 = undefined;
    var ch: u8 = 0;
    while (true) {
        const n = try dc.read(&buf, 4096, &ch);
        if (n == 0) break;
        total += n;
        if (total > 1 << 22) break;
    }
    // 每声道 10×588 − FIR 预热 32 ≈ 5848 输出帧
    try std.testing.expect(total > 5800);
    try std.testing.expectEqual(@as(u8, 2), ch);
}

test "dsd: DFF-DST → DSD 重建 + dsd2pcm f32 与 ffmpeg 逐位一致（全 10 帧）" {
    const reader = io.Reader.openMem(dst_sample);
    var f: Ctx = .{ .allocator = std.testing.allocator, .reader = reader };
    defer f.pcm.deinit(std.testing.allocator);
    defer freeState(&f);
    try parseContainer(&f);
    try std.testing.expect(f.compressed);
    const channels: usize = f.channels;
    const nb = f.dst_frame_bytes;
    try std.testing.expectEqual(@as(usize, 2), channels);
    try std.testing.expectEqual(@as(usize, 4704), nb);
    try std.testing.expectEqual(@as(usize, 10), f.frame_count);
    const dec = f.dst_dec.?;

    // dsd2pcm 状态：ffmpeg dst decode_init 以 0x69 填 FIFO
    var g_fifo: [16][FIFOSIZE]u8 = [_][FIFOSIZE]u8{[_]u8{0x69} ** FIFOSIZE} ** 16;
    var g_pos: [16]u8 = [_]u8{0} ** 16;

    var got = std.ArrayList(u8).empty;
    defer got.deinit(std.testing.allocator);

    const out_dsd = try std.testing.allocator.alloc(u8, nb * channels);
    defer std.testing.allocator.free(out_dsd);
    const plane = try std.testing.allocator.alloc(u8, nb);
    defer std.testing.allocator.free(plane);
    var f64buf: [9408]f64 = undefined;
    // 帧内交错顺序：样本 s 逐声道 → 与 golden（s*channels+ch）一致
    var per_ch = std.ArrayList(f32).empty;
    defer per_ch.deinit(std.testing.allocator);

    for (0..f.frame_count) |fi| {
        const size = f.frame_size[fi];
        const payload = try std.testing.allocator.alloc(u8, size);
        defer std.testing.allocator.free(payload);
        try f.reader.seek(@intCast(f.frame_off[fi]), .start);
        const got_bytes = try f.reader.read(payload[0..size]);
        try std.testing.expectEqual(size, got_bytes);
        try dec.decodeFrame(payload[0..size], channels, nb, out_dsd);

        per_ch.clearRetainingCapacity();
        for (0..channels) |ch| {
            for (0..nb) |s| plane[s] = out_dsd[s * channels + ch];
            const dst_f64: []f64 = if (nb > f64buf.len) f64buf[0..nb] else f64buf[0..nb];
            dsd2pcmTranslate(&g_fifo[ch], &g_pos[ch], false, plane, dst_f64);
            for (dst_f64) |x| try per_ch.append(std.testing.allocator, @floatCast(x));
        }
        // per_ch 布局 = ch-major（每声道 nb 个连续 f32）；golden 为交错 s×channels+ch
        for (0..nb) |s| {
            for (0..channels) |ch| {
                const v = per_ch.items[ch * nb + s];
                try got.appendSlice(std.testing.allocator, std.mem.asBytes(&v));
            }
        }
    }
    try std.testing.expectEqual(dst_golden_f32.len, got.items.len);
    try std.testing.expectEqualSlices(u8, dst_golden_f32, got.items);
}
