// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! MPEG Audio（MP3：Layer I/II/III）解码封装 —— 自研 Zig
//!
//! 帧解码由 layer3.zig（含 Layer III 完整管线）与 layer12.zig（Layer I/II）
//! 承担，本模块提供项目统一解码视图（VTable，见 decoder.zig §8）：
//!   - open：跳过 ID3v2 前导 → 解析首个有效帧头 → 填充 Info；
//!   - read：按帧读取 → 逐 granule 解码 → 输出 16-bit 交错小端 PCM
//!     （MPEG 音频原生 16 位；浮点中间态由 layer3/layer12 内部转换）；
//!   - seek_ms：按帧速率估算字节偏移 + 同步扫描定位最近帧边界，
//!     重置解码状态后跳转（MP3 无 seek 表，对齐 minimp3 语义）。
//!
//! gapless（Xing/Info + LAME/Lavf/Lavc，语义对齐 ffmpeg libavformat/mp3dec.c）：
//!   - 首帧含 Xing/Info（仅 Layer III）时整体跳过该帧（其为 VBR/CBR 元数据帧，
//!     不含可听样本；ffmpeg demuxer 同样 seek 越过 vbr tag frame 后解码）；
//!   - 若其后带 LAME/Lavf/Lavc 编码扩展（encoder 短名后固定 36B 布局，
//!     24-bit = (encoder_delay<<12)|padding），则解码流头丢 encoder_delay+529
//!     样本（ffmpeg start_skip_samples），输出截至于 frames×spf−(padding−529)
//!     （即总输出 = frames×spf − delay − padding），Info.duration_us 同式。
//!   - 无 Xing / 无上述编码扩展的文件不裁剪（对齐 ffmpeg 实测），保证不误裁。
//! 解码输出与 ffmpeg mp3 解码按样本流对齐：长度一致、内容按 0 偏移相关
//! （codec 层 ffmpeg 定点 vs minimp3 浮点有 ±1 LSB 舍入差，不作逐位断言）。
//!
//! 与 minimp3 参考逐位对齐（CC0 移植），经 minimp3_test 全部 Layer I/II/III
//! 向量与真实样本验证（PCM 精确一致）。

const std = @import("std");
const builtin = @import("builtin");
const Error = @import("../../error.zig").Error;
const io = @import("../../io.zig");
const decoder = @import("../../decoder.zig");
const layer3 = @import("layer3.zig");
const header = @import("header.zig");
const id3 = @import("id3.zig");

const Allocator = std.mem.Allocator;
const VTable = decoder.Decoder.VTable;
const Reader = io.Reader;

/// 单帧最大解码样本（Layer III MPEG1 立体声 1152×2 = 2304）
const max_frame_samples = 1152 * 2;
/// 单帧最大字节（320kbps MPEG1 128k 帧 417B；此处留足余量）
const max_frame_bytes = 8192;
/// 帧索引扫描块大小（64KiB：块内解析多个帧头，避免逐帧 seek+read 系统调用）
const scan_chunk_bytes = 64 * 1024;

const Ctx = struct {
    allocator: Allocator,
    reader: Reader,
    dec: layer3.DecoderState = .{},
    /// 帧字节缓冲（seek 到帧起点后读入）
    frame_buf: [max_frame_bytes]u8 = undefined,
    /// 解码 PCM 缓冲（交错 f32，一帧上限）
    pcm: [max_frame_samples]f32 = undefined,
    /// 下一帧在文件中的偏移（自音频数据起点计）
    next_offset: u64 = 0,
    /// 已解码样本数（position_ms 用）
    samples_done: u64 = 0,
    /// 跨 read 调用保留：解码帧尾未写入 out 的交错残余样本。
    /// read 按 max_samples 分块时，一帧可能横跨两次调用的边界；
    /// 残余必须跨调用保留，否则每块末尾的帧尾样本会被丢弃（输出偏短）。
    tail: [max_frame_samples]f32 = undefined,
    tail_frames: usize = 0,
    tail_off: usize = 0,
    /// Info 字段（open 时解析，read 阶段可更新采样率等）
    channels: u8 = 0,
    sample_rate: u32 = 0,
    /// 音频数据起点（ID3 之后）
    audio_start: u64 = 0,
    /// 文件总大小
    file_size: u64 = 0,
    /// 首帧参数（open 解析，seek/时长估算用）
    frame_bytes: usize = 0,
    frame_samples: usize = 0,
    /// Xing/Info header 提供的精确总帧数（无 = 0，时长用首帧参数估算）
    total_frames: u64 = 0,
    /// Xing/Info `bytes` 字段（音频数据总字节；精确字节寻址/估算用，无 = 0）
    xing_bytes: u64 = 0,
    /// Xing/Info TOC（100 字节，8-bit 量化）。保留供粗略定位/诊断；**不用于
    /// 精确帧寻址**——8-bit 量化误差可达 file_size/512 字节（多帧），无法唯一
    /// 确定落点帧号，故精确索引走分块帧头扫描（见 `frames`）。
    toc: [100]u8 = [_]u8{0} ** 100,
    has_toc: bool = false,
    /// Xing 提供的总样本数（无 = 0）
    total_samples_xing: u64 = 0,
    /// 解码起点偏移（= 首帧或其后一帧；Xing 首帧整体跳过，对齐 ffmpeg mp3dec）
    stream_start: u64 = 0,
    /// LAME/Lavf/Lavc 扩展（Xing 后 36B 内 24-bit delay/padding 语义）：
    /// 头部应丢弃的解码流样本数 = encoder_delay + 529（ffmpeg start_skip_samples）
    gapless_skip: u64 = 0,
    /// 解码输出上限（trim 后总样本数 = Xing frames×spf − delay − padding；maxInt = 不限）
    out_limit: u64 = std.math.maxInt(u64),
    /// 当前尚待丢弃的解码流头部样本（open / seek(0) 后填充，跨帧丢弃后归零）
    drop_rem: u64 = 0,
    /// seek 回退前导段标志：为 true 时，解码失败帧按标称帧长计入 drop_rem
    /// （保持绝对样本记账；open / seek(0) 的顺序解码为 false）。
    seek_lead: bool = false,
    /// 标签元数据（open 解析；生命周期与 Decoder 一致）
    meta: decoder.Metadata = .{},
    /// 附加图片（ID3v2 APIC）
    pictures: []decoder.Picture = &.{},
    /// 音量增益（REPLAYGAIN_* 标签）
    replay_gain: decoder.ReplayGain = .{},
    /// 精确帧索引（帧号 → 绝对字节偏移）：`frames.items[i]` = 自 stream_start 起
    /// 第 i 个可解码帧的绝对字节起点。惰性按需构建：顺序分块扫描帧头，精确适配
    /// VBR / MPEG2-LSF / 无 Xing（比例估算在 VBR 下不可靠、且无法给出精确帧号）。
    /// 首次 seek 可能扫描至目标帧（上限 O(总帧数)，块级读取），此后每次 seek O(1)。
    frames: std.ArrayList(u64) = .empty,
    /// 帧扫描下一块的读取偏移（EOF 后 = file_size）
    scan_byte: u64 = 0,
    /// 扫描已到文件尾（无更多帧）
    scan_eof: bool = false,
    /// 顺序回放增量建索引：从 stream_start 连续解码时同步记录帧起点，后续 seek
    /// 可直接命中（无需从头扫描）；遇 seek/重同步即停（idx_ok=false）。
    idx_ok: bool = true,
    idx_next: u64 = 0,
    /// 帧扫描块缓冲（64KiB；避免逐帧 seek+read）
    scan_buf: [scan_chunk_bytes]u8 = undefined,
    eof: bool = false,
};

const vtable = VTable{
    .read = readImpl,
    .seek_ms = seekMsImpl,
    .position_ms = positionMsImpl,
    .position_samples = positionSamplesImpl,
    .deinit = deinitImpl,
};

/// 元数据专用轻量上下文（probe-only，§8.4.2①）：只保留解析头部/标签所需字段，
/// **不含**解码器状态（`dec: layer3.DecoderState`）、帧/PCM 缓冲。
const MetaCtx = struct {
    allocator: Allocator,
    reader: Reader,
    meta: decoder.Metadata = .{},
    pictures: []decoder.Picture = &.{},
    replay_gain: decoder.ReplayGain = .{},
    channels: u8 = 0,
    sample_rate: u32 = 0,
    audio_start: u64 = 0,
    file_size: u64 = 0,
    frame_bytes: usize = 0,
    frame_samples: usize = 0,
    total_frames: u64 = 0,
    stream_start: u64 = 0,
    out_limit: u64 = std.math.maxInt(u64),
};

/// 从 off 处读取 4 字节帧头。不足 → null。
fn readHdr(reader: *Reader, off: u64) Error!?[4]u8 {
    try reader.seek(@intCast(off), .start);
    var h: [4]u8 = undefined;
    const n = try reader.read(&h);
    if (n < 4) return null;
    return h;
}

/// 读 4/3 字节大端整数（Xing/LAME 字段；slice 无对齐要求）
inline fn be32(b: []const u8) u32 {
    return (@as(u32, b[0]) << 24) | (@as(u32, b[1]) << 16) | (@as(u32, b[2]) << 8) | @as(u32, b[3]);
}
inline fn be24(b: []const u8) u32 {
    return (@as(u32, b[0]) << 16) | (@as(u32, b[1]) << 8) | @as(u32, b[2]);
}

/// 首帧内 Xing/Info VBR 头 + LAME/Lavf/Lavc 扩展的解析结果。
/// 语义对齐 ffmpeg libavformat/mp3dec.c 的 mp3_parse_vbr_tags / mp3_parse_info_tag：
///   - Xing/Info 标记位于 Layer III 首帧「帧头 + side_info」处
///     （xing_offtbl[mpeg_lsf][mono]：MPEG1 stereo 32 / mono 17，LSF stereo 17 / mono 9）；
///   - 标记后 flags(4) → frames(4) → bytes(4) → TOC(100) → qscale(4)（按 flags 位存在与否）；
///   - 其后 LAME 扩展：encoder 短名(9) → rev(1) → lowpass(1) → replaygain(8) →
///     enc_flags(1) → abr(1) → 24-bit (delay<<12)|padding（LAME 标签 36B 布局）。
const Xing = struct {
    /// 总帧数（不含 Xing 帧自身；无 frames 位 = 0）
    frames: u64 = 0,
    /// Xing `bytes` 字段（音频数据总字节，无 bytes 位 = 0）
    bytes: u64 = 0,
    /// 是否含 LAME/Lavf/Lavc 编码扩展（其 delay/padding 具 gapless 语义）
    has_enc: bool = false,
    /// encoder_delay（样本）
    delay: u32 = 0,
    /// encoder_padding（样本）
    padding: u32 = 0,
    /// 100 字节 TOC（存在 = has_toc；值经 8-bit 量化，仅作粗略定位提示）
    toc: [100]u8 = [_]u8{0} ** 100,
    has_toc: bool = false,
};

/// 解析首帧内的 Xing/Info header。无 Xing → null（时长用首帧参数估算）。
fn parseXing(reader: *Reader, first: u64, h: *const [4]u8, frame_bytes: usize) Error!?Xing {
    if (header.hdrGetLayer(h) != header.LAYER_III) return null; // Xing 仅 Layer III
    const lsf = !header.hdrTestMPEG1(h); // MPEG2/2.5
    const xing_off: usize = if (header.hdrIsMono(h))
        (if (lsf) @as(usize, 9) else @as(usize, 17))
    else
        (if (lsf) @as(usize, 17) else @as(usize, 32));
    const min_len = 4 + xing_off + 4;
    if (frame_bytes < min_len) return null;

    // 读入首帧 payload 前缀（Xing + LAME 扩展所需 ≤176B）
    try reader.seek(@intCast(first + 4), .start);
    var buf: [512]u8 = undefined;
    const want = @min(frame_bytes - 4, buf.len);
    const n = try reader.read(buf[0..want]);
    if (n < min_len) return null;
    const data = buf[0..n];

    const m = data[xing_off .. xing_off + 4];
    if (!(std.mem.eql(u8, m, "Xing") or std.mem.eql(u8, m, "Info"))) return null;

    const flags = be32(data[xing_off + 4 .. xing_off + 8]);
    var p: usize = xing_off + 8;
    var xing = Xing{};
    if (flags & 0x1 != 0) { // frames
        if (p + 4 > data.len) return null;
        xing.frames = be32(data[p .. p + 4]);
        p += 4;
    }
    if (flags & 0x2 != 0) { // bytes
        if (p + 4 > data.len) return null;
        xing.bytes = be32(data[p .. p + 4]);
        p += 4;
    }
    if (flags & 0x4 != 0) { // TOC
        if (p + 100 > data.len) return null;
        @memcpy(&xing.toc, data[p .. p + 100]);
        xing.has_toc = true;
        p += 100;
    }
    if (flags & 0x8 != 0) { // VBR scale
        if (p + 4 > data.len) return null;
        p += 4;
    }

    // LAME/Lavf/Lavc 扩展（encoder 短名后固定字段，24-bit delay/padding 距短名 +21）
    if (p + 4 > data.len) return xing;
    const magic = data[p .. p + 4];
    if (!(std.mem.eql(u8, magic, "LAME") or
        std.mem.eql(u8, magic, "Lavf") or
        std.mem.eql(u8, magic, "Lavc"))) return xing;
    if (p + 24 > data.len) return xing;
    const v = be24(data[p + 21 .. p + 24]);
    xing.has_enc = true;
    xing.delay = v >> 12;
    xing.padding = v & 0xFFF;
    return xing;
}

/// 扫描同步：自 off 起找第一个有效 MPEG 帧头。返回帧头偏移；未找到 → null。
fn findFrameSync(reader: *Reader, off: u64, limit: u64) Error!?u64 {
    var pos = off;
    var buf: [4096]u8 = undefined;
    while (pos < limit) {
        try reader.seek(@intCast(pos), .start);
        const n = try reader.read(buf[0..]);
        if (n == 0) break;
        const span = buf[0..n];
        var i: usize = 0;
        while (i + 4 <= span.len) : (i += 1) {
            const h = span[i .. i + 4];
            if (header.hdrValid(h)) return pos + @as(u64, i);
        }
        // 尾部不足 4 字节：不可能再有帧头 → 结束（否则 span.len-3 可能为 0 → 死循环）
        if (span.len < 4) break;
        // 无命中：前进到跨度末尾 - 3（保留重叠）
        pos += span.len - 3;
    }
    return null;
}

pub fn open(allocator: Allocator, reader: *Reader, info: *decoder.Info) Error!decoder.Decoder {
    const file_size = try reader.size();
    const ctx = try allocator.create(Ctx);
    ctx.* = .{ .allocator = allocator, .reader = reader.*, .file_size = file_size };

    // 解析 ID3v2 标签（若存在）→ 元数据 + 图片 + 增益；返回音频起点
    ctx.audio_start = id3.parseV2(&ctx.reader, allocator, 0, &ctx.meta, &ctx.pictures, &ctx.replay_gain) catch blk: {
        // 标签损坏 → 忽略，从头部重新扫描音频
        id3.freeMeta(allocator, &ctx.meta);
        id3.freePictures(allocator, &ctx.pictures);
        break :blk 0;
    };
    if (ctx.audio_start == 0) {
        // 无 ID3v2，直接从 0 扫描
        ctx.audio_start = 0;
    }
    errdefer destroyCtx(ctx);

    // 扫描首个有效帧
    const first = (try findFrameSync(&ctx.reader, ctx.audio_start, file_size)) orelse
        return error.Corrupt;
    const h = (try readHdr(&ctx.reader, first)) orelse return error.Corrupt;
    if (!header.hdrValid(&h)) return error.Corrupt;

    ctx.channels = if (header.hdrIsMono(&h)) 1 else 2;
    ctx.sample_rate = @intCast(header.hdrSampleRateHz(&h));
    ctx.frame_bytes = header.hdrFrameBytes(&h, 0) + header.hdrPadding(&h);
    ctx.frame_samples = header.hdrFrameSamples(&h);
    // 解析 Xing/Info header（VBR 精确帧数 + LAME/Lavf/Lavc gapless 扩展）
    var xing: ?Xing = null;
    if (ctx.frame_bytes > 0) {
        xing = try parseXing(&ctx.reader, first, &h, ctx.frame_bytes);
        if (xing) |xg| {
            ctx.total_frames = xg.frames;
            ctx.xing_bytes = xg.bytes;
            ctx.toc = xg.toc;
            ctx.has_toc = xg.has_toc;
            // ffmpeg mp3dec：存在 Xing/Info 且含 frames/bytes → 首帧（Xing 帧）整体跳过
            ctx.stream_start = first + @as(u64, @intCast(ctx.frame_bytes));
            if (xg.has_enc) {
                // LAME/Lavf/Lavc：解码流头丢 encoder_delay+529 样本；
                // 输出上限 = frames×spf − delay − padding（ffmpeg duration 同式）
                ctx.gapless_skip = @as(u64, xg.delay) + 529;
                if (ctx.total_frames > 0 and ctx.frame_samples > 0) {
                    const raw = @as(u128, ctx.total_frames) * ctx.frame_samples;
                    const trim = @as(u128, xg.delay) + xg.padding;
                    ctx.out_limit = if (raw > trim)
                        @intCast(raw - trim)
                    else
                        std.math.maxInt(u64);
                }
            }
        }
    }
    if (ctx.stream_start == 0) ctx.stream_start = first;
    ctx.next_offset = ctx.stream_start;
    ctx.scan_byte = ctx.stream_start;
    ctx.idx_next = ctx.stream_start;
    ctx.drop_rem = ctx.gapless_skip;

    // 解析 ID3v1 文件尾（补齐未覆盖的标准字段）
    if (file_size >= 128) {
        id3.parseV1(&ctx.reader, allocator, file_size, &ctx.meta) catch {};
    }

    info.* = buildInfo(ctx);
    return .{ .vtable = &vtable, .ctx = ctx };
}

/// 元数据专用入口（probe-only，§8.4.2①）：解析 ID3v2/v1 + 首帧 + Xing（时长），
/// 持有标签/图片分配，**不构造 layer3 解码状态、不分配帧/PCM 缓冲**。
pub fn openMeta(allocator: Allocator, reader: *Reader, info: *decoder.Info) Error!decoder.MetadataSession {
    const file_size = try reader.size();
    const ctx = try allocator.create(MetaCtx);
    errdefer allocator.destroy(ctx);
    ctx.* = .{ .allocator = allocator, .reader = reader.*, .file_size = file_size };

    ctx.audio_start = id3.parseV2(&ctx.reader, allocator, 0, &ctx.meta, &ctx.pictures, &ctx.replay_gain) catch blk: {
        id3.freeMeta(allocator, &ctx.meta);
        id3.freePictures(allocator, &ctx.pictures);
        break :blk 0;
    };
    if (ctx.audio_start == 0) ctx.audio_start = 0;
    errdefer destroyMetaCtx(ctx);

    const first = (try findFrameSync(&ctx.reader, ctx.audio_start, file_size)) orelse
        return error.Corrupt;
    const h = (try readHdr(&ctx.reader, first)) orelse return error.Corrupt;
    if (!header.hdrValid(&h)) return error.Corrupt;

    ctx.channels = if (header.hdrIsMono(&h)) 1 else 2;
    ctx.sample_rate = @intCast(header.hdrSampleRateHz(&h));
    ctx.frame_bytes = header.hdrFrameBytes(&h, 0) + header.hdrPadding(&h);
    ctx.frame_samples = header.hdrFrameSamples(&h);
    if (ctx.frame_bytes > 0) {
        if (try parseXing(&ctx.reader, first, &h, ctx.frame_bytes)) |xg| {
            ctx.total_frames = xg.frames;
            ctx.stream_start = first + @as(u64, @intCast(ctx.frame_bytes));
            if (xg.has_enc and ctx.total_frames > 0 and ctx.frame_samples > 0) {
                const raw = @as(u128, ctx.total_frames) * ctx.frame_samples;
                const trim = @as(u128, xg.delay) + xg.padding;
                ctx.out_limit = if (raw > trim) @intCast(raw - trim) else std.math.maxInt(u64);
            }
        }
    }
    if (ctx.stream_start == 0) ctx.stream_start = first;

    if (file_size >= 128) {
        id3.parseV1(&ctx.reader, allocator, file_size, &ctx.meta) catch {};
    }

    info.* = buildInfo(ctx);
    return .{ .ctx = @ptrCast(ctx), .deinit_fn = metaDeinit };
}

fn destroyMetaCtx(ctx: *MetaCtx) void {
    id3.freeMeta(ctx.allocator, &ctx.meta);
    id3.freePictures(ctx.allocator, &ctx.pictures);
}

fn metaDeinit(p: *anyopaque) void {
    const ctx: *MetaCtx = @ptrCast(@alignCast(p));
    destroyMetaCtx(ctx);
    ctx.allocator.destroy(ctx);
}

fn buildInfo(ctx: anytype) decoder.Info {
    var duration_us: i64 = 0;
    var known: decoder.DurationKnown = .estimate;
    if (ctx.sample_rate > 0 and ctx.frame_samples > 0) {
        if (ctx.total_frames > 0) {
            // Xing/Info 提供精确总帧数 → 精确时长（gapless 扣 encoder delay/padding，
            // 对齐 ffmpeg mp3dec：duration = (frames×spf − delay − padding)/rate）
            const total_samples: u128 = if (ctx.out_limit != std.math.maxInt(u64))
                ctx.out_limit // 已按 trim 后总样本截断
            else
                @as(u128, ctx.total_frames) * ctx.frame_samples;
            duration_us = @intCast((total_samples * 1_000_000) / ctx.sample_rate);
            known = .exact;
        } else if (ctx.file_size > ctx.audio_start and ctx.frame_bytes > 0) {
            // 无 Xing：按首帧参数估算总帧数
            const frames_total = (ctx.file_size - ctx.audio_start) / ctx.frame_bytes;
            duration_us = @intCast((@as(u128, frames_total) * ctx.frame_samples * 1_000_000) / ctx.sample_rate);
        }
    }
    return .{
        .sample_rate = ctx.sample_rate,
        .channels = ctx.channels,
        .bits_per_sample = 16,
        .is_float = false,
        .duration_us = duration_us,
        .duration_known = known,
        .codec_name = "mp3",
        .format_name = "mp3",
        .metadata = ctx.meta, // ID3v2/v1 标签（open 解析；生命周期与 Decoder 一致）
        .pictures = ctx.pictures, // ID3v2 APIC 封面图（生命周期与 Decoder 一致）
        .loops = &.{}, // MP3 无采样器循环点
        .cue_points = &.{}, // MP3 无提示点
        .replay_gain = ctx.replay_gain, // REPLAYGAIN_* 增益（TXXX 标签）
    };
}

fn destroyCtx(ctx: *Ctx) void {
    id3.freeMeta(ctx.allocator, &ctx.meta);
    id3.freePictures(ctx.allocator, &ctx.pictures);
    ctx.frames.deinit(ctx.allocator);
    ctx.allocator.destroy(ctx);
}

// ---- VTable 实现 ----

/// 与旧 readImpl 逐样本一致的量化（f32 →×32768(f64) →截断→钳位 i16）。
inline fn quantS16(v: f32) i16 {
    var s: i32 = @intFromFloat(@as(f64, v) * 32768.0);
    s = @max(@min(s, 32767), -32768);
    return @intCast(s);
}

const I16x8 = @Vector(8, i16);

/// 8 路并行量化：逐 lane 与 `quantS16` 同序（f32→f64 精确扩展、×32768 为 2 的幂、
/// 截断/钳位一致）→ 位级一致。仅用于 ch=1/2 的连续样本段。
/// 截断目标用 i32（与标量 `quantS16` 一致；AVX2 上 f64→i32 比 f64→i64 廉价得多）。
inline fn quantS16x8(v: @Vector(8, f32)) I16x8 {
    const d: @Vector(8, f64) = @floatCast(v);
    const i: @Vector(8, i32) = @intFromFloat(d * @as(@Vector(8, f64), @splat(32768.0)));
    const c = @min(@max(i, @as(@Vector(8, i32), @splat(-32768))), @as(@Vector(8, i32), @splat(32767)));
    return @truncate(c);
}

/// 写 8 个交错 i16（小端）；大端目标按 `@byteSwap` 校正后整体落盘。
inline fn storeS16x8(out: []u8, oi: usize, v: I16x8) void {
    var arr: [8]i16 = @bitCast(v);
    if (builtin.cpu.arch.endian() == .little) {
        out[oi..][0..16].* = @bitCast(arr);
    } else {
        for (&arr) |*x| x.* = @byteSwap(x.*);
        out[oi..][0..16].* = @bitCast(arr);
    }
}

/// 把 pcm 的 `frames` 帧交错样本量化写入 out[oi0..]。
/// ch=2 按 4 帧（8 样本）一批做 8 路并行量化，尾帧走标量；ch=1 同理。
/// 其余声道数走通用标量路径（无每样本整除，算术与旧实现同序 → 位级一致）。
inline fn quantWrite(out: []u8, oi0: usize, pcm: []const f32, frames: usize, channels: usize, frame_bytes: usize) void {
    if (channels == 2) {
        var oi = oi0;
        var k: usize = 0;
        while (k + 4 <= frames) : (k += 4) {
            const vf: @Vector(8, f32) = @bitCast((pcm.ptr + k * 2)[0..8].*);
            storeS16x8(out, oi, quantS16x8(vf));
            oi += 16;
        }
        while (k < frames) : (k += 1) {
            const pi = k * 2;
            std.mem.writeInt(i16, out[oi..][0..2], quantS16(pcm[pi]), .little);
            std.mem.writeInt(i16, out[oi + 2 ..][0..2], quantS16(pcm[pi + 1]), .little);
            oi += 4;
        }
    } else if (channels == 1) {
        var oi = oi0;
        var k: usize = 0;
        while (k + 8 <= frames) : (k += 8) {
            const vf: @Vector(8, f32) = @bitCast((pcm.ptr + k)[0..8].*);
            storeS16x8(out, oi, quantS16x8(vf));
            oi += 16;
        }
        while (k < frames) : (k += 1) {
            std.mem.writeInt(i16, out[oi..][0..2], quantS16(pcm[k]), .little);
            oi += 2;
        }
    } else {
        var oi = oi0;
        var ci: usize = 0;
        var i: usize = 0;
        while (i < frames * channels) : (i += 1) {
            std.mem.writeInt(i16, out[oi..][0..2], quantS16(pcm[i]), .little);
            ci += 1;
            if (ci == channels) {
                ci = 0;
                oi += frame_bytes;
            } else {
                oi += 2;
            }
        }
    }
}

fn readImpl(ctx: *anyopaque, out: []u8, max_samples: usize, out_channels: *u8) Error!usize {
    const f: *Ctx = @ptrCast(@alignCast(ctx));
    out_channels.* = f.channels;
    if (max_samples == 0 or out.len == 0) return 0;
    if (f.eof) return 0;

    const frame_bytes = @as(usize, f.channels) * 2; // 16-bit 交错
    const cap = @min(max_samples, out.len / frame_bytes);
    const limited = f.out_limit != std.math.maxInt(u64);
    if (limited and f.samples_done >= f.out_limit) {
        // gapless trim 后总样本已发完（尾部 padding 截断）
        f.eof = true;
        return 0;
    }
    var produced: usize = 0;

    // 1) 先输出上次调用残留的帧尾样本（保持输出样本流连续，见 tail 注释）
    while (produced < cap and f.tail_frames > 0) {
        var give = @min(f.tail_frames, cap - produced);
        if (limited) {
            const rem = f.out_limit -| f.samples_done;
            if (rem == 0) {
                f.eof = true;
                break;
            }
            give = @min(give, @as(usize, @intCast(@min(rem, std.math.maxInt(usize)))));
        }
        const base = f.tail_off * f.channels;
        quantWrite(out, produced * frame_bytes, f.tail[base..], give, f.channels, frame_bytes);
        produced += give;
        f.samples_done += give;
        f.tail_off += give;
        f.tail_frames -= give;
    }
    if (limited and f.samples_done >= f.out_limit) {
        f.eof = true;
        return produced;
    }

    while (produced < cap) {
        // 读取下一帧字节
        try f.reader.seek(@intCast(f.next_offset), .start);
        const n = try f.reader.read(f.frame_buf[0..]);
        if (n < 4) {
            f.eof = true;
            break;
        }
        // 顺序回放增量建索引（几乎零成本）：帧头有效且与预期衔接时记录帧起点，
        // 并把 scan_byte 推进到下一帧，使后续 seek 的惰性扫描从此处续接，而不是
        // 每次都从头扫前缀。遇 seek（next_offset 跳变）或重同步（帧头无效）即停。
        if (f.idx_ok) {
            const hb: usize = if (header.hdrValid(f.frame_buf[0..4]))
                header.hdrFrameBytes(f.frame_buf[0..4], 0)
            else
                0;
            if (hb == 0 or f.next_offset != f.idx_next or
                f.frames.items.len >= 1_048_576)
            {
                f.idx_ok = false;
            } else {
                try f.frames.append(f.allocator, f.next_offset);
                f.idx_next = f.next_offset +
                    @as(u64, hb + header.hdrPadding(f.frame_buf[0..4]));
                f.scan_byte = f.idx_next;
            }
        }
        var info: layer3.FrameInfo = .{};
        const samples = layer3.decodeFrame(&f.dec, f.frame_buf[0..n], &f.pcm, &info);
        if (samples == 0) {
            // 本帧不可解码：前进一帧继续（对齐 minimp3 重同步语义）。
            // seek 回退前导段：起点 reservoir 为空时首帧（可能数帧）会解码失败，
            // 它们仍占据标称 `frame_samples` 的绝对样本位。按标称帧长计入
            // drop_rem，否则失败帧会使其后首个成功帧整体后移（拼接处整帧顿挫）。
            if (f.seek_lead and f.drop_rem > 0) {
                const d: u64 = @min(f.drop_rem, @as(u64, @intCast(f.frame_samples)));
                f.drop_rem -= d;
            }
            if (info.frame_bytes > 0) {
                f.next_offset += @intCast(info.frame_bytes);
            } else {
                f.next_offset += 1;
            }
            continue;
        }
        const frames = samples;
        // gapless 头部丢弃（Xing/LAME encoder_delay+529）：整帧或半帧跨帧丢弃
        var fstart: usize = 0;
        if (f.drop_rem > 0) {
            const d: usize = @intCast(@min(f.drop_rem, frames));
            f.drop_rem -= d;
            if (d == frames) {
                if (info.frame_bytes > 0) {
                    f.next_offset += @intCast(info.frame_bytes);
                } else {
                    f.next_offset += 1;
                }
                continue;
            }
            fstart = d;
        }
        const leftover = frames - fstart; // 本帧剩余待发样本（已含头部跳过）
        var allowed: usize = leftover;
        if (limited) {
            const rem = f.out_limit -| f.samples_done;
            allowed = @min(allowed, @as(usize, @intCast(@min(rem, std.math.maxInt(usize)))));
            if (allowed == 0) {
                f.eof = true;
                break;
            }
        }
        const avail = @min(allowed, cap - produced);
        quantWrite(out, produced * frame_bytes, f.pcm[fstart * f.channels ..], avail, f.channels, frame_bytes);
        produced += avail;
        f.samples_done += avail;
        if (info.frame_bytes > 0) {
            f.next_offset += @intCast(info.frame_bytes);
        } else {
            f.next_offset += 1;
        }
        if (avail < allowed) {
            // out 缓冲满：本帧 allowed 内余下样本存 tail（下次调用继续发；无限定时 allowed==leftover）
            const rem = allowed - avail;
            const rbase = (fstart + avail) * f.channels;
            @memcpy(f.tail[0 .. rem * f.channels], f.pcm[rbase .. rbase + rem * @as(usize, f.channels)]);
            f.tail_frames = rem;
            f.tail_off = 0;
            break; // 输出缓冲满
        }
        if (allowed < leftover) {
            // 已达 out_limit（trim 尾 padding）：帧内超出 allowed 的样本整体丢弃
            f.eof = true;
            break;
        }
        if (limited and f.samples_done >= f.out_limit) {
            f.eof = true;
            break;
        }
    }
    return produced;
}

/// 构建精确帧索引至第 `target` 帧（含）。返回 false = 文件提前结束或无法索引
/// （free-format 无固定帧长）。惰性增量：自上次扫描停止处分块续扫，块内解析多个
/// 帧头（避免逐帧 seek+read）。精确适配 VBR / MPEG2-LSF / 无 Xing。
fn indexToFrame(f: *Ctx, target: u64) Error!bool {
    if (f.frames.items.len > target) return true;
    while (f.frames.items.len <= target) {
        if (f.scan_eof) return false;
        try f.reader.seek(@intCast(f.scan_byte), .start);
        const n = try f.reader.read(f.scan_buf[0..]);
        if (n < 4) {
            f.scan_eof = true;
            break;
        }
        var i: usize = 0;
        while (i + 4 <= n) {
            const h = f.scan_buf[i .. i + 4];
            if (!header.hdrValid(h)) {
                i += 1; // 重同步：跳过无效字节（对齐解码器 findFrame 语义）
                continue;
            }
            const fb = header.hdrFrameBytes(h, 0);
            if (fb == 0) return false; // free-format：无固定帧长，索引不可用
            try f.frames.append(f.allocator, f.scan_byte + i);
            i += fb + header.hdrPadding(h);
            if (f.frames.items.len > target) {
                f.scan_byte += i;
                return true;
            }
        }
        if (i == 0) {
            f.scan_eof = true;
            break;
        }
        f.scan_byte += i;
    }
    return f.frames.items.len > target;
}

/// 帧号 → 绝对字节偏移（帧 0 = stream_start）。越界 / 无法索引（free-format）→ null。
fn frameByteOffset(f: *Ctx, frame: u64) Error!?u64 {
    if (frame == 0) return f.stream_start;
    if (!try indexToFrame(f, frame)) return null;
    return f.frames.items[@intCast(frame)];
}

fn seekMsImpl(ctx: *anyopaque, ms: i64) Error!void {
    const f: *Ctx = @ptrCast(@alignCast(ctx));
    if (f.sample_rate == 0) return;
    f.idx_ok = false; // seek 后回放不再顺序衔接，停止增量建索引
    if (ms <= 0) {
        // 回到开头：重置解码状态（含 Xing 首帧跳过与 gapless 头丢，重新从流起点解码）
        f.dec = .{};
        f.next_offset = f.stream_start;
        f.samples_done = 0;
        f.eof = false;
        f.tail_frames = 0;
        f.tail_off = 0;
        f.drop_rem = f.gapless_skip;
        f.seek_lead = false;
        return;
    }
    const target_sample: u64 = @intCast((@as(u128, @intCast(ms)) * f.sample_rate) / 1000);
    if (f.frame_bytes == 0 or f.frame_samples == 0) return;
    const audio_bytes = f.file_size -| f.audio_start;
    const frames_total: u128 = if (f.total_frames > 0) f.total_frames else audio_bytes / f.frame_bytes;
    const total_samples: u128 = frames_total * f.frame_samples;
    // 越界 seek：目标样本 ≥ 总输出样本 → 直接置流尾（避免病态扫描/挂起）
    const total_out: u128 = if (f.out_limit != std.math.maxInt(u64))
        f.out_limit
    else
        total_samples;
    if (target_sample >= total_out) {
        f.dec = .{};
        f.next_offset = f.file_size;
        f.samples_done = @intCast(total_out);
        f.drop_rem = 0;
        f.eof = false;
        f.tail_frames = 0;
        f.tail_off = 0;
        f.seek_lead = false;
        return;
    }

    // 样本级对齐（对齐 FLAC/ADTS 设计）：目标输出样本 T 对应解码位置
    // d0 = T + gapless_skip；其所在帧 j = d0 / fs。回退 back_frames 帧到
    // 更早帧边界解码（重建 bit reservoir + 合成滤波历史），再丢弃 back..d0 的
    // 解码样本。这样首个输出样本恰为 T（samples_done = T），position_samples
    // 报告真实落点，C 壳无需（也不应）再做前向裁剪。
    const fs: u64 = f.frame_samples;
    const d0: u64 = target_sample + f.gapless_skip;
    const j: u64 = d0 / fs;
    // 回退帧数须同时满足：(a) 重建 bit reservoir（≤511 字节主数据，低码率下可达
    // ~10 帧）；(b) 重建合成多相滤波历史（qmf_state 为 15 个 granule；MPEG1 每帧
    // 2 granule（≈8 帧），MPEG2/LSF 每帧 1 granule（≈15 帧））。回退段起始
    // reservoir 为空、若干帧会解码失败（失败帧不推进 qmf_state），故再留余量。
    // 32 帧对最低码率 LSF 仍覆盖（≤10 失败 + 15 成功 granule）。
    const back_frames: u64 = 32;
    const back: u64 = if (j > back_frames) j - back_frames else 0;
    if (try frameByteOffset(f, back)) |off| {
        f.dec = .{}; // 重置解码状态（帧间 bit reservoir 从回退点重建）
        f.next_offset = off;
        f.samples_done = target_sample;
        f.drop_rem = d0 - back * fs;
        f.eof = false;
        f.tail_frames = 0;
        f.tail_off = 0;
        f.seek_lead = true;
        return;
    }

    // 兜底（free-format 等无法建立精确帧索引）：比例估算 + 同步扫描。
    // 无法保证样本级精确，仅保证不晚于目标（C 壳按 position_samples 裁剪前导）。
    if (audio_bytes == 0) return;
    var est_rel: u128 = 0;
    if (total_samples > 0) est_rel = @as(u128, audio_bytes) * target_sample / total_samples;
    const est = f.audio_start + @min(@as(u64, @intCast(est_rel)), audio_bytes);
    const scan_from = est -| f.frame_bytes;
    var pos = (try findFrameSync(&f.reader, scan_from, f.file_size)) orelse f.audio_start;
    pos = @max(pos, f.stream_start);
    const back_bytes = @min(f.frame_bytes * back_frames, pos - f.stream_start);
    var bpos = pos;
    if (back_bytes > 0) {
        bpos = (try findFrameSync(&f.reader, pos - back_bytes, f.file_size)) orelse pos;
        if (bpos < f.stream_start) bpos = f.stream_start;
        if (bpos > pos) bpos = pos;
    }
    f.dec = .{};
    f.next_offset = bpos;
    f.samples_done = target_sample;
    f.drop_rem = d0 -| back * fs;
    f.eof = false;
    f.tail_frames = 0;
    f.tail_off = 0;
    f.seek_lead = true;
}

fn positionMsImpl(ctx: *anyopaque) i64 {
    const f: *Ctx = @ptrCast(@alignCast(ctx));
    if (f.sample_rate == 0) return 0;
    return @intCast((@as(u128, f.samples_done) * 1000) / f.sample_rate);
}

/// 样本级位置：seek 后为首个待输出样本号（精确 = seek 目标样本 T，因为 seek 已
/// 在解码流中丢弃 back..d0 的前导样本；目标落在帧内时也已按样本偏移丢弃）。
/// 顺序读取时 = 已输出样本数。供 C 壳校验/对齐（此处 trim 应为 0）。
fn positionSamplesImpl(ctx: *anyopaque) i64 {
    const f: *Ctx = @ptrCast(@alignCast(ctx));
    return @intCast(f.samples_done);
}

fn deinitImpl(ctx: *anyopaque) void {
    const f: *Ctx = @ptrCast(@alignCast(ctx));
    f.reader.deinit();
    id3.freeMeta(f.allocator, &f.meta);
    id3.freePictures(f.allocator, &f.pictures);
    f.frames.deinit(f.allocator);
    f.allocator.destroy(f);
}

// ---------------------------------------------------------------------------
// 单测：Xing/Info + LAME/Lavf/Lavc 解析与 gapless trim（与 ffmpeg -f s16le 对拍）
// ---------------------------------------------------------------------------

const testing = std.testing;

/// 解码一个 mp3 内存样本（read 每轮最多 chunk 帧），返回解码器 Info 与全部 PCM 字节。
fn decodeMemSample(
    allocator: Allocator,
    file: []const u8,
    chunk: usize,
) !struct { info: decoder.Info, bytes: []u8 } {
    var reader = io.Reader.openMem(file);
    var info: decoder.Info = undefined;
    var dec = try open(allocator, &reader, &info);
    defer dec.deinit();
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    const fb: usize = @as(usize, info.channels) * 2;
    var tmp: [65536]u8 = undefined;
    while (true) {
        var ch: u8 = 0;
        const n = try dec.read(&tmp, chunk, &ch);
        if (n == 0) break;
        try out.appendSlice(allocator, tmp[0 .. n * fb]);
    }
    return .{ .info = info, .bytes = try allocator.dupe(u8, out.items) };
}

const PcmCmp = struct {
    equal: usize,
    n: usize,
    max_abs: i32,
    corr: f64,
};

fn comparePcm(mine: []const u8, ref: []const u8) PcmCmp {
    const n = @min(mine.len, ref.len) / 2;
    var equal: usize = 0;
    var max_abs: i32 = 0;
    var sum_num: f64 = 0;
    var sum_a2: f64 = 0;
    var sum_b2: f64 = 0;
    for (0..n) |i| {
        const a = std.mem.readInt(i16, mine[i * 2 ..][0..2], .little);
        const b = std.mem.readInt(i16, ref[i * 2 ..][0..2], .little);
        if (a == b) equal += 1;
        const diff = @as(i32, @intCast(@as(i32, a) - @as(i32, b)));
        const d: i32 = if (diff < 0) -diff else diff;
        if (d > max_abs) max_abs = d;
        sum_num += @as(f64, @floatFromInt(a)) * @as(f64, @floatFromInt(b));
        sum_a2 += @as(f64, @floatFromInt(a)) * @as(f64, @floatFromInt(a));
        sum_b2 += @as(f64, @floatFromInt(b)) * @as(f64, @floatFromInt(b));
    }
    return .{ .equal = equal, .n = n, .max_abs = max_abs, .corr = sum_num / @sqrt(sum_a2 * sum_b2) };
}

const s_cbr_mono = @embedFile("samples/cbr_mono.mp3");
const s_cbr_mono_s16 = @embedFile("samples/cbr_mono.s16");
const s_lame_mono = @embedFile("samples/lame_mono.mp3");
const s_lame_mono_s16 = @embedFile("samples/lame_mono.s16");
const s_lame_lsf = @embedFile("samples/lame_lsf.mp3");
const s_lame_lsf_s16 = @embedFile("samples/lame_lsf.s16");
const s_noxing = @embedFile("samples/noxing.mp3");
const s_noxing_s16 = @embedFile("samples/noxing.s16");

/// gapless 样本与 ffmpeg `-f s16le` 逐样本对拍：
/// 长度（样本数）严格相等 + 内容按 0 偏移相关（mp3 codec 层 ±1 LSB 舍入，不作逐位断言）
fn expectGaplessMatch(
    label: []const u8,
    file: []const u8,
    golden: []const u8,
    chunk: usize,
    rate: u32,
    ch: u8,
    known: decoder.DurationKnown,
) !void {
    const got = try decodeMemSample(testing.allocator, file, chunk);
    defer testing.allocator.free(got.bytes);
    try testing.expectEqualStrings("mp3", got.info.codec_name);
    try testing.expectEqual(rate, got.info.sample_rate);
    try testing.expectEqual(ch, got.info.channels);
    try testing.expectEqual(@as(u16, 16), got.info.bits_per_sample);
    try testing.expectEqual(known, got.info.duration_known);
    // gapless 裁剪后总输出 = ffmpeg 解码样本流（长度一致，含起/末裁剪点）
    try testing.expectEqual(golden.len, got.bytes.len);
    const c = comparePcm(got.bytes, golden);
    // mp3 codec 层与 ffmpeg 为固定点 vs 浮点舍入差（±1 LSB）；相关性需 >0.9999
    try testing.expect(c.corr > 0.9999);
    try testing.expect(c.max_abs <= 1);
    std.debug.print("mp3 gapless {s}: ch={d} bytes mine={d} golden={d} corr={d:.6} max_abs={d} equal {d}/{d}\n", .{
        label, ch, got.bytes.len, golden.len, c.corr, c.max_abs, c.equal, c.n,
    });
}

test "mp3 gapless: CBR Lavc/Info mono 44.1k → 与 ffmpeg 长度与内容对齐（chunk 大）" {
    try expectGaplessMatch("cbr_mono/big", s_cbr_mono, s_cbr_mono_s16, 65536 / 2, 44100, 1, .exact);
}

test "mp3 gapless: CBR Lavc/Info mono 44.1k → 与 ffmpeg 长度与内容对齐（chunk 小/跨帧）" {
    // 小 chunk 强制帧尾残余（tail）与裁剪点跨 read 边界，输出必须与整块一致
    try expectGaplessMatch("cbr_mono/small", s_cbr_mono, s_cbr_mono_s16, 37, 44100, 1, .exact);
}

test "mp3 gapless: LAME CBR mono 44.1k（真 LAME 标签）→ 与 ffmpeg 对齐" {
    try expectGaplessMatch("lame_mono/big", s_lame_mono, s_lame_mono_s16, 65536 / 2, 44100, 1, .exact);
}

test "mp3 gapless: LAME CBR stereo 22.05k（MPEG2/LSF）→ 与 ffmpeg 对齐" {
    try expectGaplessMatch("lame_lsf/big", s_lame_lsf, s_lame_lsf_s16, 65536 / 4, 22050, 2, .exact);
}

test "mp3 无 Xing：全帧解码不裁剪，与 ffmpeg 对齐" {
    // 无 Xing → ffmpeg 不裁 delay/padding（全物理帧解码），mine 须一致；
    // 无精确帧数 → duration 为按首帧参数估算（estimate）
    try expectGaplessMatch("noxing/big", s_noxing, s_noxing_s16, 65536 / 4, 44100, 2, .estimate);
}

// ---- seek 样本级对齐（byteOffsetOfFrame + 回退 reservoir + 精确丢弃）----

/// 对每个目标毫秒：seek 后首个输出样本必须 == 整曲顺序解码在目标样本处的样本，
/// 且 position_samples == 目标样本（seek 后无需上层裁剪）。maxdiff 断言 ≤1 LSB。
fn expectSeekMatch(label: []const u8, file: []const u8, rate: u32, ch: u8, targets_ms: []const i64) !void {
    const ref = try decodeMemSample(testing.allocator, file, 4096);
    defer testing.allocator.free(ref.bytes);
    const fb: usize = @as(usize, ch) * 2;
    const probe_frames: usize = 512;

    for (targets_ms) |ms| {
        const target: u64 = @intCast((@as(u128, @intCast(ms)) * rate) / 1000);
        var reader = io.Reader.openMem(file);
        var info: decoder.Info = undefined;
        var dec = try open(testing.allocator, &reader, &info);
        defer dec.deinit();
        try dec.seekMs(ms);
        try testing.expectEqual(@as(i64, @intCast(target)), dec.positionSamples());

        var out: [probe_frames * 2 * 2]u8 = undefined;
        var oc: u8 = 0;
        const n = try dec.read(&out, probe_frames, &oc);
        try testing.expectEqual(@as(usize, probe_frames), n);
        const got = out[0 .. n * fb];
        const want = ref.bytes[@as(usize, @intCast(target)) * fb ..][0 .. n * fb];
        var maxd: i32 = 0;
        for (0..n * ch) |i| {
            const a = std.mem.readInt(i16, got[i * 2 ..][0..2], .little);
            const b = std.mem.readInt(i16, want[i * 2 ..][0..2], .little);
            const d: i32 = @as(i32, a) - @as(i32, b);
            const ad: i32 = if (d < 0) -d else d;
            if (ad > maxd) maxd = ad;
        }
        std.debug.print("mp3 seek {s}: ms={d} target={d} landing={d} maxdiff={d}\n", .{
            label, ms, target, dec.positionSamples() - probe_frames, maxd,
        });
        try testing.expect(maxd <= 1);
    }
}

test "mp3 seek 样本级对齐: Info/CBR mono 44.1k" {
    try expectSeekMatch("cbr_mono", s_cbr_mono, 44100, 1, &.{ 120, 300, 480, 1500 });
}

test "mp3 seek 样本级对齐: LAME mono 44.1k" {
    try expectSeekMatch("lame_mono", s_lame_mono, 44100, 1, &.{ 120, 300, 480, 4000 });
}

test "mp3 seek 样本级对齐: LAME MPEG2/LSF stereo 22.05k" {
    try expectSeekMatch("lame_lsf", s_lame_lsf, 22050, 2, &.{ 120, 300, 480, 4000 });
}

test "mp3 seek 样本级对齐: 无 Xing（VBR 扫描路径）stereo 44.1k" {
    try expectSeekMatch("noxing", s_noxing, 44100, 2, &.{ 120, 300, 480, 4000 });
}

// ---- byteOffsetOfFrame（精确帧索引）----

test "mp3 帧索引: 帧 0 = stream_start 且相邻帧偏移差 = 帧字节数" {
    const cases = [_]struct { file: []const u8, sr: u32, frames: u64 }{
        .{ .file = s_cbr_mono, .sr = 44100, .frames = 78 },
        .{ .file = s_lame_mono, .sr = 44100, .frames = 193 },
        .{ .file = s_lame_lsf, .sr = 22050, .frames = 194 },
        .{ .file = s_noxing, .sr = 44100, .frames = 193 },
    };
    for (cases) |c| {
        var reader = io.Reader.openMem(c.file);
        var info: decoder.Info = undefined;
        var dec = try open(testing.allocator, &reader, &info);
        defer dec.deinit();
        const f: *Ctx = @ptrCast(@alignCast(dec.ctx));
        try testing.expectEqual(f.stream_start, (try frameByteOffset(f, 0)).?);
        // 扫描全量并在每个索引处校验帧头有效、偏移单调、与头内帧长一致
        var prev: u64 = 0;
        var i: u64 = 0;
        while (i < c.frames) : (i += 1) {
            const off = (try frameByteOffset(f, i)) orelse return error.TestUnexpectedResult;
            if (i > 0) try testing.expect(off > prev);
            prev = off;
            var h: [4]u8 = undefined;
            try f.reader.seek(@intCast(off), .start);
            _ = try f.reader.read(&h);
            try testing.expect(header.hdrValid(&h));
            if (i + 1 < c.frames) {
                const next = (try frameByteOffset(f, i + 1)).?;
                const fb = header.hdrFrameBytes(&h, 0) + header.hdrPadding(&h);
                try testing.expectEqual(off + fb, next);
            }
        }
        try testing.expect((try frameByteOffset(f, c.frames)) == null); // 越界
    }
}

// ---- parseXing（Xing/Info 结构 + LAME/Lavf/Lavc 24-bit delay/padding）----

/// 构造一帧含 Xing/Info 标记与编码扩展的 synthetic 首帧（MPEG1 L3 44100 st，
/// frame_bytes=417；frame 内各字段按 ffmpeg mp3dec 顺序排布）
fn buildXingFrame(marker: [4]u8, magic: [4]u8, delay: u32, padding: u32) [417]u8 {
    var b = [_]u8{0} ** 417;
    @memcpy(b[0..4], &[_]u8{ 0xFF, 0xFB, 0x90, 0x00 }); // MPEG1 L3 128k 44100 stereo
    const x = 4 + 32; // side info（stereo MPEG1）=32
    @memcpy(b[x..][0..4], &marker);
    @memcpy(b[x + 4 .. x + 8], &[_]u8{ 0x00, 0x00, 0x00, 0x0F }); // flags: frames|bytes|toc|qscale
    var p: usize = x + 8;
    @memcpy(b[p..][0..4], &[_]u8{ 0x00, 0x00, 0x11, 0xF3 }); // frames = 4595
    p += 4;
    @memcpy(b[p..][0..4], &[_]u8{ 0x00, 0xBC, 0x61, 0x4E }); // bytes
    p += 4 + 100; // TOC
    p += 4; // VBR scale
    @memcpy(b[p..][0..4], &magic);
    const v24: u32 = (delay << 12) | padding;
    b[p + 21] = @truncate(v24 >> 16);
    b[p + 22] = @truncate(v24 >> 8);
    b[p + 23] = @truncate(v24);
    return b;
}

fn parseXingOf(buf: *const [417]u8) !?Xing {
    const h: [4]u8 = .{ 0xFF, 0xFB, 0x90, 0x00 };
    var reader = io.Reader.openMem(buf[0..]);
    return parseXing(&reader, 0, &h, 417);
}

test "parseXing: Info(Lavc) CBR → frames + encoder delay/padding" {
    const buf = buildXingFrame(.{ 'I', 'n', 'f', 'o' }, .{ 'L', 'a', 'v', 'c' }, 576, 864);
    const xing = (try parseXingOf(&buf)).?;
    try testing.expectEqual(@as(u64, 4595), xing.frames);
    try testing.expectEqual(@as(u64, 0x00BC614E), xing.bytes); // bytes 字段已解析
    try testing.expect(xing.has_toc); // TOC 位存在 → 100B 已存入（synthetic 全 0）
    try testing.expect(xing.has_enc);
    try testing.expectEqual(@as(u32, 576), xing.delay);
    try testing.expectEqual(@as(u32, 864), xing.padding);
}

test "parseXing: Xing(LAME) VBR → frames + encoder delay/padding" {
    const buf = buildXingFrame(.{ 'X', 'i', 'n', 'g' }, .{ 'L', 'A', 'M', 'E' }, 576, 1260);
    const xing = (try parseXingOf(&buf)).?;
    try testing.expectEqual(@as(u64, 4595), xing.frames);
    try testing.expect(xing.has_enc);
    try testing.expectEqual(@as(u32, 576), xing.delay);
    try testing.expectEqual(@as(u32, 1260), xing.padding);
}

test "parseXing: 编码扩展非 LAME/Lavf/Lavc → 无 gapless 语义" {
    const buf = buildXingFrame(.{ 'I', 'n', 'f', 'o' }, .{ 'F', 'r', 'a', 'c' }, 576, 864);
    const xing = (try parseXingOf(&buf)).?;
    try testing.expectEqual(@as(u64, 4595), xing.frames);
    try testing.expect(!xing.has_enc);
}

test "parseXing: 首帧无 Xing 标记 → null" {
    const buf = buildXingFrame(.{ 'Z', 'Z', 'Z', 'Z' }, .{ 'L', 'a', 'v', 'c' }, 576, 864);
    try testing.expect((try parseXingOf(&buf)) == null);
}
