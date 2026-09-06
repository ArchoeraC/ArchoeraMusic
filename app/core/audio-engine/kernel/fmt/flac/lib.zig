// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! FLAC 解码器封装（open + VTable + 帧循环 + 去相关 + seek + 输出打包）
//!
//! 参考重构对照 flacdec.c flac_decode_frame / decode_frame / decorrelate_33bps /
//! flac_set_bps 与 flacdsp_template.c flac_decorrelate_*_c。
//!
//! 输出契约（对齐 FFmpeg 默认 S16/S32 输出，保证 f6 bit-exact 对照可逐字节比对）：
//!   - 流位深 ≤ 16 → 输出 16-bit（左移 16-bps 位对齐满幅）；
//!   - 流位深 > 16 → 输出 32-bit（左移 32-bps 位对齐满幅）；
//!   - 交错小端 PCM，`Info.bits_per_sample` = 16 / 32。
//!
//! 帧循环：
//!   - 每帧开新建 BitReader（帧边界恒为字节对齐，见 bitreader.zig 文件头）；
//!   - EOF 判定：剩余位 < 最小合法帧 80 位（FFmpeg FLAC_MIN_FRAME_SIZE=10B）→ 0；
//!   - STREAMINFO 一致性：声道数相等、blocksize ≤ max_blocksize、bps 一致；
//!     frame 采样率可覆写（FFmpeg 语义，不报错）；
//!   - 32 位流 + 立体声耦合 → 侧声道走 33 位宽式路径（decodeSubframeWide）；
//!   - 整帧 CRC-16 校验失败 → Corrupt（坏帧重同步：向后扫描合法帧起点跳过继续，
//!     §13.3 容错；无法恢复且无产出 → Corrupt 透出）。
//!
//! seek 语义：
//!   - 有 SEEKTABLE → 定位最近点后解码丢弃至目标样本（帧对齐）；
//!   - 无 SEEKTABLE → 按总样本比例估算字节偏移 + sync 扫描（CRC-8 校验防误判）
//!     定位真实帧边界，再解码丢弃至目标；落点样本号由帧头 UTF-8 编号推算
//!     （fixed-blocksize 流：编号×blocksize；variable-blocksize 流：编号即样本号）。

const std = @import("std");
const Error = @import("../../error.zig").Error;
const io = @import("../../io.zig");
const decoder = @import("../../decoder.zig");
const bitreader = @import("bitreader.zig");
const streaminfo = @import("streaminfo.zig");
const frame = @import("frame.zig");
const subframe = @import("subframe.zig");

const BitReader = bitreader.BitReader;
const VTable = decoder.Decoder.VTable;

/// 最小合法帧位长（FFmpeg FLAC_MIN_FRAME_SIZE = 10 字节）；剩余不足视为 EOF
const min_frame_bits: u64 = 80;

/// FLAC 解码上下文
const FlacCtx = struct {
    allocator: std.mem.Allocator,
    /// 按值持有（decoder.open 传入的 reader 拷贝，deinit 时关闭）
    reader: io.Reader,
    stream_info: streaminfo.StreamInfo,
    /// SEEKTABLE（parse 所有权转移至此，deinit 释放）
    seektable: std.ArrayList(streaminfo.SeekPoint),
    /// VORBIS_COMMENT 标签元数据（parse 所有权转移至此；deinit 释放）
    meta: decoder.Metadata,
    /// CUESHEET 提示点（parse 所有权转移至此；deinit 释放）
    cue_points: []decoder.CuePoint,
    /// PICTURE 附加图片（parse 所有权转移至此；deinit 释放）
    pictures: []decoder.Picture,
    /// REPLAYGAIN 增益（REPLAYGAIN_* 标签；纯值，随 ctx 传递）
    replay_gain: decoder.ReplayGain,
    /// 音频数据起点（第一个音频帧的字节偏移）
    audio_start: u64,
    channels: u8,
    sample_rate: u32,
    /// 输出位深（16 / 32）
    out_bps: u8,
    /// 输出左移位数（16-bps 或 32-bps，对齐 FFmpeg flac_set_bps）
    out_shift: u5,
    /// 每帧解码缓冲（单一连续块，按 max_blocksize×channels 分配）
    decoded_buf: []i32,
    /// 33 位宽式侧声道缓冲（max_blocksize×2 个 i64）
    decoded33_buf: []i64,
    /// 声道切片视图（decoded_buf 的划分）
    decoded: [8][]i32,
    decoded33: [2][]i64,
    /// 解码缓冲容量（样本数/声道，≥ max_blocksize）
    buf_len: usize,
    /// 当前已解码未输出帧：起点游标 / 总长
    frame_cursor: usize,
    cur_blocksize: usize,
    /// 已输出样本总数（自文件开头计，position_ms 依据）
    samples_done: u64,
};

/// 一帧解码结果
const FrameResult = struct {
    blocksize: usize,
    /// 本帧首样本编号（fixed-blocksize：帧号×blocksize；variable：编号即样本号）
    sample_index: u64,
};

const vtable = VTable{
    .read = readImpl,
    .seek_ms = seekMsImpl,
    .position_ms = positionMsImpl,
    .deinit = deinitImpl,
};

/// 从已打开 Reader 解析 FLAC（decoder.open 与测试共用入口）。
/// 成功时 Decoder 接管 `reader` 所有权（deinit 关闭）。
pub fn open(allocator: std.mem.Allocator, reader: *io.Reader, info: *decoder.Info) Error!decoder.Decoder {
    var parsed = try streaminfo.parse(reader, allocator);
    errdefer parsed.deinit();
    const si = parsed.info;
    const audio_start = reader.pos;

    const ctx = try allocator.create(FlacCtx);
    errdefer destroyCtx(ctx);
    errdefer allocator.destroy(ctx);
    ctx.* = .{
        .allocator = allocator,
        .reader = undefined,
        .stream_info = si,
        .seektable = parsed.seektable, // 转移所有权
        .meta = parsed.meta, // 转移所有权
        .cue_points = parsed.cue_points, // 转移所有权
        .pictures = parsed.pictures, // 转移所有权
        .replay_gain = parsed.replay_gain,
        .audio_start = audio_start,
        .channels = si.channels,
        .sample_rate = si.sample_rate,
        .out_bps = if (si.bits_per_sample <= 16) 16 else 32,
        .out_shift = if (si.bits_per_sample <= 16)
            @intCast(16 - si.bits_per_sample)
        else
            @intCast(32 - si.bits_per_sample),
        .decoded_buf = &.{},
        .decoded33_buf = &.{},
        .decoded = undefined,
        .decoded33 = undefined,
        .buf_len = 0,
        .frame_cursor = 0,
        .cur_blocksize = 0,
        .samples_done = 0,
    };
    parsed.seektable = .empty; // 所有权已转移，防 errdefer 重复释放
    parsed.meta = .{};
    parsed.cue_points = &.{};
    parsed.pictures = &.{};

    // 解码缓冲：max_blocksize 容量（streaminfo 保证 ≥ 16；帧超限在解码时判 Corrupt）
    const buf_len: usize = si.max_blocksize;
    ctx.buf_len = buf_len;
    const buf = try allocator.alloc(i32, buf_len * si.channels);
    ctx.decoded_buf = buf;
    for (0..si.channels) |c| ctx.decoded[c] = buf[c * buf_len ..][0..buf_len];
    const buf33 = try allocator.alloc(i64, 2 * buf_len);
    ctx.decoded33_buf = buf33;
    ctx.decoded33[0] = buf33[0..buf_len];
    ctx.decoded33[1] = buf33[buf_len..][0..buf_len];

    info.* = buildInfo(ctx);
    // 接管 reader（按值拷贝解析后状态）
    ctx.reader = reader.*;

    return .{ .vtable = &vtable, .ctx = @ptrCast(ctx) };
}

/// 释放 ctx 内已持有资源（open 错误路径与 deinit 共用；缓冲长度字段判定是否已分配）
fn destroyCtx(ctx: *FlacCtx) void {
    if (ctx.decoded_buf.len > 0) ctx.allocator.free(ctx.decoded_buf);
    if (ctx.decoded33_buf.len > 0) ctx.allocator.free(ctx.decoded33_buf);
    ctx.seektable.deinit(ctx.allocator);
    streaminfo.freeMeta(ctx.allocator, &ctx.meta);
    if (ctx.cue_points.len > 0) {
        ctx.allocator.free(ctx.cue_points);
        ctx.cue_points = &.{};
    }
    streaminfo.freePictures(ctx.allocator, &ctx.pictures);
}

// ---- Info ----

fn buildInfo(ctx: *FlacCtx) decoder.Info {
    const si = ctx.stream_info;
    var duration_us: i64 = 0;
    var known: decoder.DurationKnown = .unknown;
    if (si.total_samples > 0 and si.sample_rate > 0) {
        duration_us = @intCast((@as(u128, si.total_samples) * 1_000_000) / si.sample_rate);
        known = .exact;
    }
    return .{
        .sample_rate = si.sample_rate,
        .channels = si.channels,
        .bits_per_sample = ctx.out_bps,
        .is_float = false,
        .duration_us = duration_us,
        .duration_known = known,
        .codec_name = "flac",
        .format_name = "flac",
        .metadata = ctx.meta, // VORBIS_COMMENT 标签（open 解析；生命周期与 Decoder 一致）
        .pictures = ctx.pictures, // PICTURE 封面图（open 解析；生命周期与 Decoder 一致）
        .loops = &.{}, // FLAC 无采样器循环点（CUESHEET 为 CD 目录，见 cue_points）
        .cue_points = ctx.cue_points, // CUESHEET 提示点（index 样本偏移）
        .replay_gain = ctx.replay_gain, // REPLAYGAIN 增益（REPLAYGAIN_* 标签）
    };
}

// ---- VTable 实现 ----

fn readImpl(ctx: *anyopaque, out: []u8, max_samples: usize, out_channels: *u8) Error!usize {
    const f: *FlacCtx = @ptrCast(@alignCast(ctx));
    out_channels.* = f.channels;
    if (max_samples == 0 or out.len == 0) return 0;

    const frame_bytes = @as(usize, f.channels) * f.out_bps / 8;
    // 产出不超过缓冲区实际容量（至少容纳一帧样本）
    const cap = @min(max_samples, out.len / frame_bytes);
    var produced: usize = 0;
    while (produced < cap) {
        // 优先输出已解码帧的残余
        if (f.frame_cursor < f.cur_blocksize) {
            const avail = f.cur_blocksize - f.frame_cursor;
            const take = @min(avail, cap - produced);
            emitSamples(f, out[produced * frame_bytes ..], f.frame_cursor, take);
            f.frame_cursor += take;
            f.samples_done += take;
            produced += take;
        } else {
            // 解码下一帧；坏帧（Corrupt）→ 重同步跳过，继续后续帧
            // （§13.3 容错；对齐 FFmpeg flacdec 对损坏帧跳过继续）
            const r = decodeOneFrame(f) catch |err| switch (err) {
                error.Corrupt => {
                    if (!try resyncToNextFrame(f)) {
                        // 无法定位后续帧：已有产出先返回（下次读到 EOF），否则报 Corrupt
                        if (produced > 0) return produced;
                        return error.Corrupt;
                    }
                    continue;
                },
                else => return err,
            } orelse break;
            f.cur_blocksize = r.blocksize;
            f.frame_cursor = 0;
            f.cur_blocksize = r.blocksize;
            f.frame_cursor = 0;
        }
    }
    return produced;
}

fn seekMsImpl(ctx: *anyopaque, ms: i64) Error!void {
    const f: *FlacCtx = @ptrCast(@alignCast(ctx));
    if (f.sample_rate == 0) return; // 采样率未知，无法定位
    var target: u64 = 0;
    if (ms > 0) {
        target = @min((@as(u128, @intCast(ms)) * f.sample_rate) / 1000, f.stream_info.total_samples);
    }
    try seekToSample(f, target);
}

fn positionMsImpl(ctx: *anyopaque) i64 {
    const f: *FlacCtx = @ptrCast(@alignCast(ctx));
    if (f.sample_rate == 0) return 0;
    return @intCast((@as(u128, f.samples_done) * 1000) / f.sample_rate);
}

fn deinitImpl(ctx: *anyopaque) void {
    const f: *FlacCtx = @ptrCast(@alignCast(ctx));
    destroyCtx(f);
    f.reader.deinit();
    f.allocator.destroy(f);
}

// ---- 帧解码 ----

/// 解码一帧：帧头 → 一致性校验 → 逐声道子帧 → 对齐 → CRC-16 → 去相关。
/// 返回帧样本数与首样本编号；EOF（剩余不足一帧）→ null。
fn decodeOneFrame(f: *FlacCtx) Error!?FrameResult {
    var br = BitReader.init(&f.reader);
    const remaining = try br.remainingBits();
    if (remaining < min_frame_bits) return null;

    br.resetCrc();
    const hdr = try frame.parseHeader(&br);

    // 与 STREAMINFO 一致性校验（flacdec.c decode_frame 同款）
    if (hdr.channels != f.channels) return error.Corrupt;
    if (hdr.blocksize > f.stream_info.max_blocksize) return error.Corrupt;
    const eff_bps: u8 = if (hdr.bps == 0) f.stream_info.bits_per_sample else hdr.bps;
    if (eff_bps != f.stream_info.bits_per_sample) return error.Corrupt;
    // 采样率：帧头可覆写（FFmpeg 语义）；流未知时采纳帧头值供 position 计算
    if (hdr.sample_rate != 0) {
        if (f.sample_rate == 0) f.sample_rate = hdr.sample_rate;
    }

    const stream_bps = f.stream_info.bits_per_sample;
    // 33 位路径：32 位流 + 立体声耦合（侧声道 bps+1 = 33）
    const use_33 = stream_bps == 32 and hdr.ch_mode != .independent;

    for (0..hdr.channels) |i| {
        // decode_subframe 的每声道位深调整：right_side 时 ch0+1；left/mid_side 时 ch1+1
        var bps: u8 = stream_bps;
        if (i == 0) {
            if (hdr.ch_mode == .right_side) bps += 1;
        } else if (hdr.ch_mode == .left_side or hdr.ch_mode == .mid_side) {
            bps += 1;
        }
        if (bps == 33) {
            const side: usize = if (i == 0) 0 else 1;
            try subframe.decodeSubframeWide(&br, f.allocator, f.decoded33[side], hdr.blocksize);
        } else {
            try subframe.decodeSubframe(&br, f.decoded[i], hdr.blocksize, bps, stream_bps);
        }
    }

    // 字节对齐 + 整帧 CRC-16（含 CRC 尾部校验和应为 0）
    br.alignToByte();
    _ = try br.readBits(16);
    if (br.crc16 != 0) return error.Corrupt;

    // 去相关
    if (use_33) {
        decorrelate33(f, hdr.ch_mode, hdr.blocksize);
    } else {
        decorrelate(f, hdr.ch_mode, hdr.blocksize);
    }

    const sample_index: u64 = if (hdr.is_var_size)
        hdr.frame_or_sample_num
    else
        hdr.frame_or_sample_num * hdr.blocksize;
    return .{ .blocksize = hdr.blocksize, .sample_index = sample_index };
}

/// 32 位路径去相关（flacdsp_template.c flac_decorrelate_*_c，无符号环绕，shift=0）
fn decorrelate(f: *FlacCtx, ch_mode: frame.ChMode, blocksize: usize) void {
    const ch0 = f.decoded[0];
    switch (ch_mode) {
        .independent => {},
        .left_side => {
            const ch1 = f.decoded[1];
            for (0..blocksize) |i| {
                const a: u32 = @bitCast(ch0[i]);
                const b: u32 = @bitCast(ch1[i]);
                ch1[i] = @bitCast(a -% b);
            }
        },
        .right_side => {
            const ch1 = f.decoded[1];
            for (0..blocksize) |i| {
                const a: u32 = @bitCast(ch0[i]);
                const b: u32 = @bitCast(ch1[i]);
                ch0[i] = @bitCast(a +% b);
            }
        },
        .mid_side => {
            const ch1 = f.decoded[1];
            for (0..blocksize) |i| {
                var a: u32 = @bitCast(ch0[i]);
                const b: i32 = ch1[i];
                a -%= @bitCast(b >> 1); // a -= b>>1（算术移位）
                ch0[i] = @bitCast(a +% @as(u32, @bitCast(b)));
                ch1[i] = @bitCast(a);
            }
        },
    }
}

/// 33 位去相关（decorrelate_33bps）：侧声道存于 decoded33，结果写回 decoded[0..2]
fn decorrelate33(f: *FlacCtx, ch_mode: frame.ChMode, blocksize: usize) void {
    const ch0 = f.decoded[0];
    const ch1 = f.decoded[1];
    switch (ch_mode) {
        .left_side => {
            // R = L - side（u64 计算截断到 u32 ≡ u32 环绕）
            for (0..blocksize) |i| {
                const l: u32 = @bitCast(ch0[i]);
                const s: u32 = @truncate(@as(u64, @bitCast(f.decoded33[1][i])));
                ch1[i] = @bitCast(l -% s);
            }
        },
        .right_side => {
            // L = R + side
            for (0..blocksize) |i| {
                const r: u32 = @bitCast(ch1[i]);
                const s: u32 = @truncate(@as(u64, @bitCast(f.decoded33[0][i])));
                ch0[i] = @bitCast(r +% s);
            }
        },
        .mid_side => {
            for (0..blocksize) |i| {
                var a: u64 = @bitCast(@as(i64, ch0[i])); // int32 符号扩展
                const b: i64 = f.decoded33[1][i];
                a -%= @bitCast(b >> 1);
                ch0[i] = @bitCast(@as(u32, @truncate(a +% @as(u64, @bitCast(b)))));
                ch1[i] = @bitCast(@as(u32, @truncate(a)));
            }
        },
        .independent => unreachable,
    }
}

/// 输出交错 PCM：v << out_shift 后按 out_bps/8 字节小端写入
fn emitSamples(f: *FlacCtx, out: []u8, start: usize, count: usize) void {
    const shift: u5 = f.out_shift;
    var oi: usize = 0;
    for (0..count) |i| {
        for (0..f.channels) |c| {
            const v: u32 = @as(u32, @bitCast(f.decoded[c][start + i])) << shift;
            switch (f.out_bps) {
                16 => std.mem.writeInt(u16, @ptrCast(out[oi..][0..2]), @truncate(v), .little),
                32 => std.mem.writeInt(u32, @ptrCast(out[oi..][0..4]), v, .little),
                else => unreachable,
            }
            oi += f.out_bps / 8;
        }
    }
}

// ---- seek ----

/// 坏帧重同步：从当前位置向后扫描合法帧起点（0xFFF8 同步码 + 帧头 CRC-8/一致性校验，
/// 复用 scanForFrame）；找到 → reader 定位到该帧起点并返回 true。文件剩余不足以构成
/// 帧 → false（调用方按不可恢复处理）。FFmpeg flacdec 对损坏帧同样跳过继续（§13.3）。
fn resyncToNextFrame(f: *FlacCtx) Error!bool {
    f.frame_cursor = f.cur_blocksize; // 丢弃当前帧未输出残余
    const start = f.reader.pos;
    const file_size = try f.reader.size();
    if (start >= file_size) return false;
    const found = (try scanForFrame(f, start)) orelse return false;
    try f.reader.seek(@intCast(found), .start);
    return true;
}

/// 定位到 target 样本（帧对齐，允许落点在 target 之前/之后的最近帧边界）。
fn seekToSample(f: *FlacCtx, target: u64) Error!void {
    f.frame_cursor = f.cur_blocksize; // 丢弃任何未输出帧

    if (f.seektable.items.len > 0) {
        // SEEKTABLE：定位最近可用点（≤ target），解码丢弃至目标
        var pt: ?streaminfo.SeekPoint = null;
        for (f.seektable.items) |p| {
            if (p.sample_number == 0xFFFF_FFFF_FFFF_FFFF) continue; // 占位点
            if (p.sample_number > target) break; // 升序，其后皆超
            pt = p;
        }
        if (pt) |p| {
            const pos = (try seektableFrameStart(f, p.stream_offset)) orelse p.stream_offset;
            try f.reader.seek(@intCast(pos), .start);
            f.samples_done = p.sample_number;
        } else {
            try f.reader.seek(@intCast(f.audio_start), .start);
            f.samples_done = 0;
        }
    } else {
        // 无 SEEKTABLE：按总样本比例估算字节偏移 + sync 扫描定位真实帧边界
        const file_size = try f.reader.size();
        var est: u64 = f.audio_start;
        if (f.stream_info.total_samples > 0 and file_size > f.audio_start) {
            const est_abs = f.audio_start + (file_size - f.audio_start) * target / f.stream_info.total_samples;
            // 预留 10% 余量，避免落点越过目标
            est = f.audio_start + (est_abs - f.audio_start) * 9 / 10;
        }
        const pos = try scanForFrame(f, est) orelse f.audio_start;
        try f.reader.seek(@intCast(pos), .start);
        f.samples_done = 0; // 由解码帧头回填
    }

    // 解码丢弃至目标样本（坏帧 → 重同步跳过继续，与 readImpl 容错语义一致）
    while (f.samples_done < target) {
        const r = (decodeOneFrame(f) catch |err| switch (err) {
            error.Corrupt => {
                if (!try resyncToNextFrame(f)) break; // 无法定位后续帧：停在当前
                continue;
            },
            else => return err,
        }) orelse break;
        f.samples_done = r.sample_index + r.blocksize;
        f.cur_blocksize = r.blocksize;
    }
    f.frame_cursor = f.cur_blocksize;
}

/// SEEKTABLE 帧起点定位：seekpoint 的 stream_offset 依 FLAC 规范（§SEEKTABLE）
/// 为「相对首个音频帧」的偏移，但存在编码器/工具按文件绝对偏移写入，逐候选
/// 校验帧头（CRC-8 + 一致性），全部失败再从候选起点前向扫描兜底。
/// 返回真实帧起点；找不到返回 null。
fn seektableFrameStart(f: *FlacCtx, sp_off: u64) Error!?u64 {
    const file_size = try f.reader.size();
    // 候选 1：规范相对偏移（音频起点 + 表中偏移）
    const rel = f.audio_start +% sp_off;
    if (rel < file_size and isValidFrameStart(f, rel)) return rel;
    // 候选 2：绝对偏移（历史/容错兼容）
    if (sp_off < file_size and isValidFrameStart(f, sp_off)) return sp_off;
    // 兜底：从较早候选前向扫描定位真实帧边界（防落点越过目标，取较早者）
    const scan_from = if (rel < file_size) @min(rel, f.audio_start) else f.audio_start;
    return scanForFrame(f, scan_from);
}

/// 从 start 起逐块扫描 FLAC 帧同步（0xFF + 高 5 位 0xF8 模式），
/// 对候选做完整帧头解析（CRC-8 通过即基本可信）校验。
/// 返回真实帧起始偏移；未找到 → null。
fn scanForFrame(f: *FlacCtx, start: u64) Error!?u64 {
    const file_size = try f.reader.size();
    if (start >= file_size) return null;

    var pos = start;
    var overlap: u8 = 0; // 跨块边界保留 1 字节
    var buf: [1024]u8 = undefined;
    while (pos < file_size) {
        try f.reader.seek(@intCast(pos -| overlap), .start);
        const n = try f.reader.read(buf[0..]);
        if (n == 0) break;
        const span = buf[0..n];
        var k: usize = 0;
        while (k + 1 < span.len) : (k += 1) {
            if (span[k] == 0xFF and span[k + 1] & 0xFC == 0xF8) {
                const cand = pos -| overlap + k;
                if (isValidFrameStart(f, cand)) return cand;
            }
        }
        const adv = n - 1; // 保留最后 1 字节作 overlap
        pos += adv;
        overlap = 1;
        if (adv == 0) break;
    }
    return null;
}

/// 候选帧起点：seek 过去做完整帧头解析（CRC-8 + 一致性校验）
fn isValidFrameStart(f: *FlacCtx, cand: u64) bool {
    f.reader.seek(@intCast(cand), .start) catch return false;
    var br = BitReader.init(&f.reader);
    br.resetCrc();
    const hdr = frame.parseHeader(&br) catch return false;
    if (hdr.channels != f.channels) return false;
    if (hdr.blocksize > f.stream_info.max_blocksize) return false;
    return true;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;
const crc = @import("crc.zig");
const TestBits = @import("residual.zig").TestBits;

/// 构造 STREAMINFO（34 字节）：rate/channels/bps/total_samples/max_blocksize
fn makeStreamInfoBytes(rate: u32, channels: u8, bps: u8, total: u64, blocksize: u16) [34]u8 {
    var b = [_]u8{0} ** 34;
    std.mem.writeInt(u16, b[0..2], blocksize, .big);
    std.mem.writeInt(u16, b[2..4], blocksize, .big);
    // 字节 10-12（24 位）：samplerate(20) << 4 | (channels-1)(3) << 1 | (bps-1) 高位 1 位
    const word24: u24 = @intCast((rate << 4) | ((@as(u32, channels) - 1) << 1) | ((bps - 1) >> 4));
    std.mem.writeInt(u24, b[10..13], word24, .big);
    // 字节 13：(bps-1) 低位 4 位 << 4 | total_samples 高位 4 位
    b[13] = @as(u8, @intCast(bps - 1)) << 4 | @as(u8, @intCast((total >> 32) & 0x0F));
    std.mem.writeInt(u32, b[14..18], @intCast(total & 0xFFFFFFFF), .big);
    return b;
}

/// bps → 帧头 bps_code（sample_size_table 逆映射）
fn bpsCode(bps: u8) u3 {
    return switch (bps) {
        8 => 1,
        12 => 2,
        16 => 4,
        20 => 5,
        24 => 6,
        32 => 7,
        else => unreachable,
    };
}

/// 编码一帧帧头（含 CRC-8）到 w；返回帧首字节偏移。
/// blocksize ≤ 256 用 bs_code 6（8 位扩展），否则 bs_code 7（16 位扩展）。
fn writeFrameHeader(w: *TestBits, num: u64, blocksize: u16, ch_code: u4, bps: u8) !u64 {
    const start_byte = w.bytes.items.len;
    try w.appendBits(0x7FFC, 15);
    try w.appendBits(0, 1); // var_size = 0（fixed-blocksize）
    if (blocksize <= 256) {
        try w.appendBits(6, 4);
    } else {
        try w.appendBits(7, 4);
    }
    try w.appendBits(9, 4); // sr_code 9 → 44100
    try w.appendBits(ch_code, 4);
    try w.appendBits(bpsCode(bps), 3);
    try w.appendBits(0, 1); // reserved
    // UTF-8 帧号
    if (num < 0x80) {
        try w.appendBits(@intCast(num), 8);
    } else {
        try w.appendBits(@intCast(0xE0 | (num >> 12)), 8);
        try w.appendBits(@intCast(0x80 | ((num >> 6) & 0x3F)), 8);
        try w.appendBits(@intCast(0x80 | (num & 0x3F)), 8);
    }
    // blocksize 扩展位
    if (blocksize <= 256) {
        try w.appendBits(blocksize - 1, 8);
    } else {
        try w.appendBits(blocksize - 1, 16);
    }
    try w.padToByte();
    try w.bytes.append(testing.allocator, crc.crc8(w.bytes.items[start_byte..]));
    return start_byte;
}

/// 帧尾：字节对齐 + CRC-16（对整帧字节）
fn finishFrame(w: *TestBits, start_byte: u64) !void {
    try w.padToByte();
    const c = crc.crc16(w.bytes.items[start_byte..]);
    try w.bytes.append(testing.allocator, @intCast(c >> 8));
    try w.bytes.append(testing.allocator, @intCast(c & 0xFF));
}

/// 写一个 verbatim 子帧头 + 值（wasted=0）
fn writeVerbatimSubframe(w: *TestBits, values: []const i32, bps: u8) !void {
    try w.appendBits(0, 1); // padding
    try w.appendBits(1, 6); // verbatim
    try w.appendBits(0, 1); // wasted
    for (values) |v| {
        // appendBits 的位宽参数为 u5（上限 31），32 位值拆两次 16 位
        if (bps == 32) {
            const u: u32 = @bitCast(v);
            try w.appendBits(u >> 16, 16);
            try w.appendBits(u & 0xFFFF, 16);
        } else {
            try w.appendBits(@bitCast(v), @intCast(bps));
        }
    }
}

/// 打开内存 FLAC 并返回解码器
fn openMem(allocator: std.mem.Allocator, file: []const u8, info: *decoder.Info) Error!decoder.Decoder {
    var reader = io.Reader.openMem(file);
    return open(allocator, &reader, info);
}

/// 构造单帧 FLAC：fLaC + STREAMINFO + 1 帧 verbatim 全声道
fn buildSingleFrameFlac(
    allocator: std.mem.Allocator,
    ch: usize,
    bps: u8,
    values: []const i32, // 各声道样本按声道连续排列
    blocksize: u16,
    total: u64,
) ![]u8 {
    var stream = std.ArrayList(u8).empty;
    defer stream.deinit(allocator);
    try stream.appendSlice(allocator, "fLaC");
    try stream.appendSlice(allocator, &.{ 0x80, 0x00, 0x00, 0x22 }); // STREAMINFO + last
    const si = makeStreamInfoBytes(44100, @intCast(ch), bps, total, @max(blocksize, 16));
    try stream.appendSlice(allocator, &si);

    var w = TestBits.init();
    defer w.deinit();
    const start = try writeFrameHeader(&w, 0, blocksize, @intCast(ch - 1), bps);
    var ci: usize = 0;
    for (0..ch) |_| {
        try writeVerbatimSubframe(&w, values[ci..][0..blocksize], bps);
        ci += blocksize;
    }
    try finishFrame(&w, start);
    const frame_bytes = try w.toOwnedSlice();
    defer allocator.free(frame_bytes);
    try stream.appendSlice(allocator, frame_bytes);
    return stream.toOwnedSlice(allocator);
}

test "flac 集成: 单声道 verbatim 端到端（Info + read）" {
    const vals = [_]i32{ 100, 200, -300, -400 };
    const file = try buildSingleFrameFlac(testing.allocator, 1, 16, &vals, 4, 4);
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();

    try testing.expectEqual(@as(u32, 44100), info.sample_rate);
    try testing.expectEqual(@as(u8, 1), info.channels);
    try testing.expectEqual(@as(u8, 16), info.bits_per_sample);
    try testing.expectEqualStrings("flac", info.codec_name);
    try testing.expectEqual(@as(i64, 90), info.duration_us); // 4/44100 s
    try testing.expectEqual(decoder.DurationKnown.exact, info.duration_known);

    var out: [8]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectEqual(@as(usize, 4), try dec.read(&out, 8, &ch));
    const expect = [_]u8{ 0x64, 0x00, 0xC8, 0x00, 0xD4, 0xFE, 0x70, 0xFE }; // 100,200,-300,-400 LE
    try testing.expectEqualSlices(u8, &expect, &out);
    try testing.expectEqual(@as(usize, 0), try dec.read(&out, 8, &ch)); // EOF
}

test "flac 集成: 立体声独立 + 24bit → 32bit 输出左移 8" {
    const vals = [_]i32{ 1, 2, 3, 4, -1, -2, -3, -4 }; // L ×4, R ×4
    const file = try buildSingleFrameFlac(testing.allocator, 2, 24, &vals, 4, 4);
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();
    try testing.expectEqual(@as(u8, 32), info.bits_per_sample);

    var out: [32]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectEqual(@as(usize, 4), try dec.read(&out, 4, &ch));
    // 交错 L0 R0 L1 R1 ...：v<<8 LE
    const expect = [_]u8{
        0x00, 0x01, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, // 1<<8, -1<<8
        0x00, 0x02, 0x00, 0x00, 0x00, 0xFE, 0xFF, 0xFF, // 2<<8, -2<<8
        0x00, 0x03, 0x00, 0x00, 0x00, 0xFD, 0xFF, 0xFF,
        0x00, 0x04, 0x00, 0x00, 0x00, 0xFC, 0xFF, 0xFF,
    };
    try testing.expectEqualSlices(u8, &expect, &out);
}

test "flac 集成: mid_side 去相关端到端" {
    // mid=ch0, side=ch1（17 位）；解码 a=mid-(side>>1) → L=a+side, R=a
    // mid=0, side=2 → a=-1 → L=1, R=-1
    const vals = [_]i32{ 0, 0, 0, 0, 2, 2, 2, 2 }; // mid ×4, side ×4
    var stream = std.ArrayList(u8).empty;
    defer stream.deinit(testing.allocator);
    try stream.appendSlice(testing.allocator, "fLaC");
    try stream.appendSlice(testing.allocator, &.{ 0x80, 0x00, 0x00, 0x22 });
    const si = makeStreamInfoBytes(44100, 2, 16, 4, 16);
    try stream.appendSlice(testing.allocator, &si);

    var w = TestBits.init();
    defer w.deinit();
    const start = try writeFrameHeader(&w, 0, 4, 10, 16); // ch_code 10 = mid_side
    try writeVerbatimSubframe(&w, vals[0..4], 16); // mid
    try writeVerbatimSubframe(&w, vals[4..8], 17); // side（bps+1）
    try finishFrame(&w, start);
    const frame_bytes = try w.toOwnedSlice();
    defer testing.allocator.free(frame_bytes);
    try stream.appendSlice(testing.allocator, frame_bytes);
    const file = try stream.toOwnedSlice(testing.allocator);
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();

    var out: [16]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectEqual(@as(usize, 4), try dec.read(&out, 4, &ch));
    const expect = [_]u8{
        0x01, 0x00, 0xFF, 0xFF, // L=1, R=-1
        0x01, 0x00, 0xFF, 0xFF,
        0x01, 0x00, 0xFF, 0xFF,
        0x01, 0x00, 0xFF, 0xFF,
    };
    try testing.expectEqualSlices(u8, &expect, &out);
}

test "flac 集成: 整帧 CRC-16 损坏 → Corrupt" {
    const vals = [_]i32{ 1, 2, 3, 4 };
    const file = try buildSingleFrameFlac(testing.allocator, 1, 16, &vals, 4, 4);
    defer testing.allocator.free(file);
    file[file.len - 1] ^= 0x01; // 翻转 CRC 尾字节

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();
    var out: [8]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectError(error.Corrupt, dec.read(&out, 8, &ch));
}

test "flac 集成: 中间帧损坏 → 重同步跳过继续（坏帧不中断后续）" {
    // 3 帧 verbatim（blocksize 4），值 1..12；破坏第 2 帧 CRC-16 → 重同步跳过
    const bs: u16 = 4;
    var w = TestBits.init();
    defer w.deinit();
    var starts: [3]u64 = undefined;
    var v: i32 = 1;
    for (0..3) |fi| {
        starts[fi] = try writeFrameHeader(&w, fi, bs, 0, 16);
        var buf: [4]i32 = undefined;
        for (&buf) |*s| {
            s.* = v;
            v += 1;
        }
        try writeVerbatimSubframe(&w, &buf, 16);
        try finishFrame(&w, starts[fi]);
    }
    const frames = try w.toOwnedSlice();
    defer testing.allocator.free(frames);
    // 第 2 帧（帧号 1）CRC-16 尾字节 = 帧起点 + 帧长 - 1（须在 appendSlice 前破坏）
    const frame_len = starts[2] - starts[1];
    frames[starts[1] + frame_len - 1] ^= 0x01;

    var stream = std.ArrayList(u8).empty;
    defer stream.deinit(testing.allocator);
    try stream.appendSlice(testing.allocator, "fLaC");
    try stream.appendSlice(testing.allocator, &.{ 0x80, 0x00, 0x00, 0x22 });
    try stream.appendSlice(testing.allocator, &makeStreamInfoBytes(44100, 1, 16, 12, 16));
    try stream.appendSlice(testing.allocator, frames);
    const file = try stream.toOwnedSlice(testing.allocator);
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();
    var out: [24]u8 = undefined;
    var ch: u8 = 0;
    const n = try dec.read(&out, 12, &ch);
    // 帧 0（1..4）+ 帧 2（9..12）共 8 样本；帧 1（5..8）被跳过
    try testing.expectEqual(@as(usize, 8), n);
    const expect = [_]u8{
        0x01, 0x00, 0x02, 0x00, 0x03, 0x00, 0x04, 0x00, // 帧 0
        0x09, 0x00, 0x0A, 0x00, 0x0B, 0x00, 0x0C, 0x00, // 帧 2
    };
    try testing.expectEqualSlices(u8, &expect, out[0..16]);
    // 已无剩余 → EOF
    try testing.expectEqual(@as(usize, 0), try dec.read(&out, 12, &ch));
}

test "flac 集成: 帧头与 STREAMINFO 不一致（bps）→ Corrupt" {
    var stream = std.ArrayList(u8).empty;
    defer stream.deinit(testing.allocator);
    try stream.appendSlice(testing.allocator, "fLaC");
    try stream.appendSlice(testing.allocator, &.{ 0x80, 0x00, 0x00, 0x22 });
    const si = makeStreamInfoBytes(44100, 1, 16, 4, 16);
    try stream.appendSlice(testing.allocator, &si);

    var w = TestBits.init();
    defer w.deinit();
    const start = try writeFrameHeader(&w, 0, 4, 0, 32); // 帧头声明 32bit
    try writeVerbatimSubframe(&w, &[_]i32{ 1, 2, 3, 4 }, 32);
    try finishFrame(&w, start);
    const frame_bytes = try w.toOwnedSlice();
    defer testing.allocator.free(frame_bytes);
    try stream.appendSlice(testing.allocator, frame_bytes);
    const file = try stream.toOwnedSlice(testing.allocator);
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();
    var out: [8]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectError(error.Corrupt, dec.read(&out, 8, &ch));
}

test "flac 集成: 多帧顺序读取 + EOF + position" {
    // 6 帧 verbatim（blocksize 4096），值 1..24576，total=24576
    const bs: u16 = 4096;
    var stream = std.ArrayList(u8).empty;
    defer stream.deinit(testing.allocator);
    try stream.appendSlice(testing.allocator, "fLaC");
    try stream.appendSlice(testing.allocator, &.{ 0x80, 0x00, 0x00, 0x22 });
    const si = makeStreamInfoBytes(44100, 1, 16, 24576, bs);
    try stream.appendSlice(testing.allocator, &si);

    var w = TestBits.init();
    defer w.deinit();
    var v: i32 = 1;
    for (0..6) |fi| {
        const start = try writeFrameHeader(&w, fi, bs, 0, 16);
        var buf: [4096]i32 = undefined;
        for (&buf) |*s| {
            s.* = v;
            v += 1;
        }
        try writeVerbatimSubframe(&w, &buf, 16);
        try finishFrame(&w, start);
    }
    const frame_bytes = try w.toOwnedSlice();
    defer testing.allocator.free(frame_bytes);
    try stream.appendSlice(testing.allocator, frame_bytes);
    const file = try stream.toOwnedSlice(testing.allocator);
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();
    try testing.expectEqual(@as(i64, 557278), info.duration_us); // 24576/44100 s

    // 跨帧边界读 6 样本（帧 0 尾 + 帧 1 头）
    var out: [12]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectEqual(@as(usize, 6), try dec.read(&out, 6, &ch));
    const expect = [_]u8{
        0x01, 0x00, 0x02, 0x00, 0x03, 0x00, 0x04, 0x00, 0x05, 0x00, 0x06, 0x00,
    };
    try testing.expectEqualSlices(u8, &expect, &out);
    // 读满剩余 → EOF
    var total: usize = 6;
    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = try dec.read(&tmp, 4096, &ch);
        if (n == 0) break;
        total += n;
    }
    try testing.expectEqual(@as(usize, 24576), total);
    try testing.expectEqual(@as(i64, 557), dec.positionMs()); // 24576/44100 s
}

test "flac 集成: seektable 定位 + 帧对齐 seek" {
    // 6 帧 verbatim（blocksize 4096），值 1..24576；SEEKTABLE 每帧一点
    const bs: u16 = 4096;
    var w = TestBits.init();
    defer w.deinit();
    var v: i32 = 1;
    for (0..6) |fi| {
        const start = try writeFrameHeader(&w, fi, bs, 0, 16);
        var buf: [4096]i32 = undefined;
        for (&buf) |*s| {
            s.* = v;
            v += 1;
        }
        try writeVerbatimSubframe(&w, &buf, 16);
        try finishFrame(&w, start);
    }
    const frames = try w.toOwnedSlice();
    defer testing.allocator.free(frames);

    // 元数据尺寸：fLaC(4) + si 头(4+34) + seektable 头(4) + 6×18 点
    const seek_points_bytes = 6 * 18;
    const audio_start = 4 + 38 + 4 + seek_points_bytes;
    const frame_len: usize = frames.len / 6;

    var stream = std.ArrayList(u8).empty;
    defer stream.deinit(testing.allocator);
    try stream.appendSlice(testing.allocator, "fLaC");
    try stream.appendSlice(testing.allocator, &.{ 0x00, 0x00, 0x00, 0x22 }); // STREAMINFO（非最后）
    try stream.appendSlice(testing.allocator, &makeStreamInfoBytes(44100, 1, 16, 24576, bs));
    try stream.appendSlice(testing.allocator, &.{ 0x83, 0x00, 0x00, 0x6C }); // SEEKTABLE + last, 108B
    var pt: [6 * 18]u8 = undefined;
    for (0..6) |i| {
        std.mem.writeInt(u64, pt[i * 18 ..][0..8], i * bs, .big);
        std.mem.writeInt(u64, pt[i * 18 ..][8..16], audio_start + i * frame_len, .big);
        std.mem.writeInt(u16, pt[i * 18 ..][16..18], bs, .big);
    }
    try stream.appendSlice(testing.allocator, &pt);
    try stream.appendSlice(testing.allocator, frames);
    const file = try stream.toOwnedSlice(testing.allocator);
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();

    // seek 到样本 ~13979（≈317ms）→ 定位到帧 3（样本 12288）后解码丢弃，帧对齐落在帧 4（值 16385）
    try dec.seekMs(317);
    var out: [2]u8 = undefined;
    var ch: u8 = 0;
    const n = try dec.read(&out, 1, &ch);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x40 }, &out); // 16385 LE

    // seek 回开头
    try dec.seekMs(0);
    try testing.expectEqual(@as(i64, 0), dec.positionMs());
    const n2 = try dec.read(&out, 1, &ch);
    try testing.expectEqual(@as(usize, 1), n2);
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x00 }, &out); // 1
}

test "flac 集成: SEEKTABLE 规范相对偏移（音频起点 + 表中偏移）seek" {
    // 回归：seekpoint stream_offset 依 FLAC 规范为「相对首个音频帧」偏移（音频
    // 起点后常有 PICTURE/VORBIS_COMMENT 等大块元数据）；此前按文件绝对偏移 seek
    // 会落进元数据区 → Corrupt，导致 EraAudio 断点续播/播放中 seek 失败。
    // 6 帧 verbatim（blocksize 4096），值 1..24576；SEEKTABLE 每帧一点（相对偏移）。
    const bs: u16 = 4096;
    var w = TestBits.init();
    defer w.deinit();
    var v: i32 = 1;
    for (0..6) |fi| {
        const start = try writeFrameHeader(&w, fi, bs, 0, 16);
        var buf: [4096]i32 = undefined;
        for (&buf) |*s| {
            s.* = v;
            v += 1;
        }
        try writeVerbatimSubframe(&w, &buf, 16);
        try finishFrame(&w, start);
    }
    const frames = try w.toOwnedSlice();
    defer testing.allocator.free(frames);

    const seek_points_bytes = 6 * 18;
    const audio_start = 4 + 38 + 4 + seek_points_bytes;
    const frame_len: usize = frames.len / 6;

    var stream = std.ArrayList(u8).empty;
    defer stream.deinit(testing.allocator);
    try stream.appendSlice(testing.allocator, "fLaC");
    try stream.appendSlice(testing.allocator, &.{ 0x00, 0x00, 0x00, 0x22 });
    try stream.appendSlice(testing.allocator, &makeStreamInfoBytes(44100, 1, 16, 24576, bs));
    try stream.appendSlice(testing.allocator, &.{ 0x83, 0x00, 0x00, 0x6C });
    var pt: [6 * 18]u8 = undefined;
    for (0..6) |i| {
        std.mem.writeInt(u64, pt[i * 18 ..][0..8], i * bs, .big);
        std.mem.writeInt(u64, pt[i * 18 ..][8..16], i * frame_len, .big); // 相对音频起点
        std.mem.writeInt(u16, pt[i * 18 ..][16..18], bs, .big);
    }
    try stream.appendSlice(testing.allocator, &pt);
    try stream.appendSlice(testing.allocator, frames);
    const file = try stream.toOwnedSlice(testing.allocator);
    defer testing.allocator.free(file);
    try testing.expect(audio_start > 0);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();

    // seek ~317ms → 定位帧 3（样本 12288）后解码丢弃，帧对齐落在帧 4（值 16385）
    try dec.seekMs(317);
    var out: [2]u8 = undefined;
    var ch: u8 = 0;
    const n = try dec.read(&out, 1, &ch);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x40 }, &out); // 16385 LE（帧 4 起点）

    // seek 回开头 & 再跳 317ms（重复 seek 不漂移、不报 Corrupt）
    try dec.seekMs(0);
    const n0 = try dec.read(&out, 1, &ch);
    try testing.expectEqual(@as(usize, 1), n0);
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x00 }, &out); // 1
    try dec.seekMs(317);
    const n2 = try dec.read(&out, 1, &ch);
    try testing.expectEqual(@as(usize, 1), n2);
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x40 }, &out); // 16385 LE
}

test "flac 集成: 无 seektable 时估算 + sync 扫描 seek" {
    // 12 帧 verbatim（blocksize 4096），值 1..49152，total=49152；无 seektable
    const bs: u16 = 4096;
    var w = TestBits.init();
    defer w.deinit();
    var v: i32 = 1;
    for (0..12) |fi| {
        const start = try writeFrameHeader(&w, fi, bs, 0, 16);
        var buf: [4096]i32 = undefined;
        for (&buf) |*s| {
            s.* = v;
            v += 1;
        }
        try writeVerbatimSubframe(&w, &buf, 16);
        try finishFrame(&w, start);
    }
    const frames = try w.toOwnedSlice();
    defer testing.allocator.free(frames);

    var stream = std.ArrayList(u8).empty;
    defer stream.deinit(testing.allocator);
    try stream.appendSlice(testing.allocator, "fLaC");
    try stream.appendSlice(testing.allocator, &.{ 0x80, 0x00, 0x00, 0x22 });
    try stream.appendSlice(testing.allocator, &makeStreamInfoBytes(44100, 1, 16, 49152, bs));
    try stream.appendSlice(testing.allocator, frames);
    const file = try stream.toOwnedSlice(testing.allocator);
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();

    // seek 到 ~一半位置（样本 ~23990 ≈ 544ms）→ 估算落在帧 5 内，扫描定位到帧 6 起点
    try dec.seekMs(544);
    var out: [2]u8 = undefined;
    var ch: u8 = 0;
    const n = try dec.read(&out, 1, &ch);
    try testing.expectEqual(@as(usize, 1), n);
    // 落点应在帧 6..9（值 24577..40960），避免估算/扫描精度差异
    const v0: i16 = @bitCast(out[0..2].*);
    try testing.expect(v0 >= 24577 and v0 <= 40960);
}

test "flac 集成: 尾部垃圾不足一帧 → EOF" {
    const vals = [_]i32{ 1, 2, 3, 4 };
    const file = try buildSingleFrameFlac(testing.allocator, 1, 16, &vals, 4, 4);
    defer testing.allocator.free(file);
    var with_tail = std.ArrayList(u8).empty;
    defer with_tail.deinit(testing.allocator);
    try with_tail.appendSlice(testing.allocator, file);
    try with_tail.appendSlice(testing.allocator, "xyz");
    const bytes = try with_tail.toOwnedSlice(testing.allocator);
    defer testing.allocator.free(bytes);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, bytes, &info);
    defer dec.deinit();
    var out: [8]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectEqual(@as(usize, 4), try dec.read(&out, 8, &ch));
    try testing.expectEqual(@as(usize, 0), try dec.read(&out, 8, &ch)); // EOF（尾部忽略）
}

test "flac 集成: VORBIS_COMMENT + CUESHEET + PICTURE 端到端（Info 填充 + 解码不受影响）" {
    // 音频帧：1 帧 verbatim（值 100,200,-300,-400）
    const vals = [_]i32{ 100, 200, -300, -400 };
    var w = TestBits.init();
    defer w.deinit();
    const start = try writeFrameHeader(&w, 0, 4, 0, 16);
    try writeVerbatimSubframe(&w, &vals, 16);
    try finishFrame(&w, start);
    const frames = try w.toOwnedSlice();
    defer testing.allocator.free(frames);

    // VORBIS_COMMENT payload：vendor "FLAC" + 3 字段
    var vb = std.ArrayList(u8).empty;
    defer vb.deinit(testing.allocator);
    try vb.appendSlice(testing.allocator, &[_]u8{ 4, 0, 0, 0 }); // vendor_length "FLAC"
    try vb.appendSlice(testing.allocator, "FLAC");
    try vb.appendSlice(testing.allocator, &[_]u8{ 3, 0, 0, 0 }); // 3 字段
    try vb.appendSlice(testing.allocator, &[_]u8{ 10, 0, 0, 0 }); // "TITLE=Demo"
    try vb.appendSlice(testing.allocator, "TITLE=Demo");
    try vb.appendSlice(testing.allocator, &[_]u8{ 13, 0, 0, 0 }); // "ARTIST=Tester"
    try vb.appendSlice(testing.allocator, "ARTIST=Tester");
    try vb.appendSlice(testing.allocator, &[_]u8{ 12, 0, 0, 0 }); // "COMMENT=Nice"
    try vb.appendSlice(testing.allocator, "COMMENT=Nice");

    // CUESHEET payload：2 tracks × 1 index（offset 0 / 100）
    var cs = std.ArrayList(u8).empty;
    defer cs.deinit(testing.allocator);
    var hdr = [_]u8{0} ** 396;
    hdr[137] = 2;
    try cs.appendSlice(testing.allocator, &hdr);
    var t1 = [_]u8{0} ** 36;
    t1[22] = 1;
    try cs.appendSlice(testing.allocator, &t1);
    var idx1 = [_]u8{0} ** 12;
    std.mem.writeInt(u64, idx1[0..8], 0, .big);
    try cs.appendSlice(testing.allocator, &idx1);
    var t2 = [_]u8{0} ** 36;
    t2[22] = 1;
    try cs.appendSlice(testing.allocator, &t2);
    var idx2 = [_]u8{0} ** 12;
    std.mem.writeInt(u64, idx2[0..8], 100, .big);
    try cs.appendSlice(testing.allocator, &idx2);

    // 组装流：fLaC + STREAMINFO + VORBIS_COMMENT + CUESHEET(last) + frames
    var stream = std.ArrayList(u8).empty;
    defer stream.deinit(testing.allocator);
    try stream.appendSlice(testing.allocator, "fLaC");
    try stream.appendSlice(testing.allocator, &.{ 0x00, 0x00, 0x00, 0x22 });
    try stream.appendSlice(testing.allocator, &makeStreamInfoBytes(44100, 1, 16, 4, 16));
    var vb_hdr = [_]u8{ 0x04, 0x00, 0x00, 0x00 }; // VORBIS_COMMENT（非最后块）
    std.mem.writeInt(u24, vb_hdr[1..4], @intCast(vb.items.len), .big);
    try stream.appendSlice(testing.allocator, &vb_hdr);
    try stream.appendSlice(testing.allocator, vb.items);

    // PICTURE payload：front cover（type 3），jpeg 6 字节
    var pic = std.ArrayList(u8).empty;
    defer pic.deinit(testing.allocator);
    try pic.appendSlice(testing.allocator, &.{ 0x00, 0x00, 0x00, 0x03 }); // type = front cover
    try pic.appendSlice(testing.allocator, &.{ 0x00, 0x00, 0x00, 0x0A }); // mime_len 10
    try pic.appendSlice(testing.allocator, "image/jpeg");
    try pic.appendSlice(testing.allocator, &.{ 0x00, 0x00, 0x00, 0x05 }); // desc_len 5
    try pic.appendSlice(testing.allocator, "Cover");
    try pic.appendSlice(testing.allocator, &.{ 0x00, 0x00, 0x02, 0x80 }); // width 640
    try pic.appendSlice(testing.allocator, &.{ 0x00, 0x00, 0x01, 0xE0 }); // height 480
    try pic.appendSlice(testing.allocator, &.{ 0x00, 0x00, 0x00, 0x18 }); // depth 24
    try pic.appendSlice(testing.allocator, &.{ 0x00, 0x00, 0x00, 0x00 }); // colors 0
    try pic.appendSlice(testing.allocator, &.{ 0x00, 0x00, 0x00, 0x06 }); // data_len 6
    try pic.appendSlice(testing.allocator, &.{ 0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x01 });
    var pic_hdr = [_]u8{ 0x06, 0x00, 0x00, 0x00 }; // PICTURE（非最后块）
    std.mem.writeInt(u24, pic_hdr[1..4], @intCast(pic.items.len), .big);
    try stream.appendSlice(testing.allocator, &pic_hdr);
    try stream.appendSlice(testing.allocator, pic.items);

    var cs_hdr = [_]u8{ 0x85, 0x00, 0x00, 0x00 }; // CUESHEET（最后块，last=1）
    std.mem.writeInt(u24, cs_hdr[1..4], @intCast(cs.items.len), .big);
    try stream.appendSlice(testing.allocator, &cs_hdr);
    try stream.appendSlice(testing.allocator, cs.items);
    try stream.appendSlice(testing.allocator, frames);
    const file = try stream.toOwnedSlice(testing.allocator);
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();

    // VORBIS_COMMENT 标签
    try testing.expectEqualStrings("Demo", info.metadata.title.?);
    try testing.expectEqualStrings("Tester", info.metadata.artist.?);
    try testing.expectEqualStrings("Nice", info.metadata.comment.?);
    try testing.expect(info.metadata.album == null);
    // CUESHEET 提示点
    try testing.expectEqual(@as(usize, 2), info.cue_points.len);
    try testing.expectEqual(@as(u32, 0), info.cue_points[0].position);
    try testing.expectEqual(@as(u32, 100), info.cue_points[1].position);
    try testing.expectEqual(@as(usize, 0), info.loops.len);
    // PICTURE 封面图
    try testing.expectEqual(@as(usize, 1), info.pictures.len);
    try testing.expectEqual(@as(u32, 3), info.pictures[0].picture_type);
    try testing.expectEqualStrings("image/jpeg", info.pictures[0].mime);
    try testing.expectEqualStrings("Cover", info.pictures[0].description);
    try testing.expectEqual(@as(u32, 640), info.pictures[0].width);
    try testing.expectEqual(@as(u32, 480), info.pictures[0].height);
    try testing.expectEqual(@as(u32, 24), info.pictures[0].depth);
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x01 }, info.pictures[0].data);

    // 解码不受元数据影响
    var out: [8]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectEqual(@as(usize, 4), try dec.read(&out, 8, &ch));
    const expect = [_]u8{ 0x64, 0x00, 0xC8, 0x00, 0xD4, 0xFE, 0x70, 0xFE }; // 100,200,-300,-400 LE
    try testing.expectEqualSlices(u8, &expect, &out);
    try testing.expectEqual(@as(usize, 0), try dec.read(&out, 8, &ch)); // EOF
}
