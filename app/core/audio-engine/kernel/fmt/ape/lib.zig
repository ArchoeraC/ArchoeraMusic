//! APE（Monkey's Audio）解码器（docs/audio-kernel-zig.md §9.10）
//!
//! 全自研 Zig（AGPL），不依赖 Monkey's Audio 官方 SDK；参考重构对照
//! FFmpeg libavcodec/apedec.c + libavformat/ape.c（reference/FFmpeg，n9.0.1），
//! 逐位复刻保证 bit-exact 对照验收（§17.2）；参考对照非复制（§3.3）。
//!
//! 解码流程（对齐 ape_decode_frame / ape_unpack_* / init_frame_decoder）：
//!   1. 帧数据 → 4 字节字级 bswap（大端帧数据 → 主机序）+ buf_size 零填充
//!      （< 3950 额外 +2 字节，对齐参考实现 overread）；
//!   2. nblocks/offset 头 → init_entropy_decoder（CRC / frameflags / rice /
//!      区间或位流初始化）→ init_predictor_decoder → init_filter（每帧重置）；
//!   3. 每帧按 blocks_per_loop=4608 分块（< 3930 整帧一块）：
//!      熵解码（按版本 0000/3860/3900/3990）→ 终级滤波（>= 3930）→ 预测
//!      （3800/3930/3950）→ 立体声去相关 → 输出打包 + CRC 累计；
//!   4. 帧末 CRC-32/MPEG 比对（>= 3900）定位损坏帧。
//!
//! 输出契约（对齐 FFmpeg ape 解码器输出，保证 bit-exact 逐字节比对）：
//!   - bps 8  → u8（decoded+0x80 & 0xff）；bps 16 → s16；
//!   - bps 24 → s32（decoded*256，顶对齐）；
//!   - 交错小端 PCM，`Info.bits_per_sample` = 8 / 16 / 32。
//!
//! 范围与容错（§9.10 / §13.3）：
//!   - 仅 mono / stereo（FFmpeg 同限）；bps ∈ {8,16,24}；
//!   - 版本 3800-3990；压缩级别须为 1000 的倍数且 ≤ 5000（< 3930 禁 insane）；
//!   - 帧数据越界 / 区间越界 / CRC 不匹配 / 位流耗尽 → error.Corrupt；
//!   - seek 按帧重解（每帧独立状态），目标超出文件尾 → EOF。

const std = @import("std");
const Error = @import("../../error.zig").Error;
const io = @import("../../io.zig");
const decoder = @import("../../decoder.zig");
const bitreader = @import("bitreader.zig");
const rangecoder = @import("rangecoder.zig");
const predictor = @import("predictor.zig");
const container = @import("container.zig");

const BitReader = bitreader.BitReader;
const RangeCtx = rangecoder.Ctx;
const VTable = decoder.Decoder.VTable;

/// 每块最多解码样本数（对齐 FFmpeg blocks_per_loop 默认 4608）
const BLOCKS_PER_LOOP = 4608;

/// 单帧原始数据合理上限（压缩帧不可能超过原始 PCM 大小）
const frame_data_cap = 64 * 1024 * 1024;

/// 帧解码状态（数据为每帧重建）
const ApeCtx = struct {
    allocator: std.mem.Allocator,
    reader: io.Reader,
    header: container.Header,

    /// 输出位深（8 / 16 / 32）
    out_bps: u8,
    /// 当前待输出帧索引（< header.totalframes 时有帧待解）
    current_frame: usize = 0,

    // 熵解码状态（每帧重建）
    rc: RangeCtx = undefined,
    frameflags: u32 = 0,
    frame_crc: u32 = 0,
    crc_state: u32 = 0,

    // 预测器状态（每帧 init）
    predictor: predictor.Predictor = .{},
    predictor64: predictor.Predictor64 = .{},
    filters: predictor.Filters = .{},
    /// 24-bit interim 双趟模式：open 时按 bps 设 -1 / 0，帧间保持（对齐 FFmpeg）
    interim_mode: i32 = 0,

    // 块解码缓冲
    decoded0: []i32 = &.{},
    decoded1: []i32 = &.{},
    interim0: []i32 = &.{},
    interim1: []i32 = &.{},

    // 帧数据缓冲（原始 + bswapped）
    frame_buf: []u8 = &.{},
    data_buf: []u8 = &.{},

    // 帧输出缓冲（整帧交错 PCM）
    out_buf: []u8 = &.{},
    out_len: usize = 0,
    out_cursor: usize = 0,

    /// 已输出样本数（position 依据；seek 重置）
    samples_done: u64 = 0,
};

const vtable = VTable{
    .read = readImpl,
    .seek_ms = seekMsImpl,
    .position_ms = positionMsImpl,
    .deinit = deinitImpl,
};

/// CRC-32/MPEG（IEEE 反射表，poly 0xEDB88320），对齐 FFmpeg av_crc(AV_CRC_32_IEEE_LE)
const crc32_table = blk: {
    @setEvalBranchQuota(100000);
    var t: [256]u32 = undefined;
    for (0..256) |i| {
        var c: u32 = @intCast(i);
        for (0..8) |_| {
            c = if ((c & 1) != 0) (0xEDB88320 ^ (c >> 1)) else (c >> 1);
        }
        t[i] = c;
    }
    break :blk t;
};

inline fn crcUpdate(crc: u32, b: u8) u32 {
    return crc32_table[(crc ^ b) & 0xFF] ^ (crc >> 8);
}

fn crcUpdateBytes(crc: u32, bytes: []const u8) u32 {
    var c = crc;
    for (bytes) |b| c = crcUpdate(c, b);
    return c;
}

// ---------------------------------------------------------------------------
// 帧解码
// ---------------------------------------------------------------------------

/// 读帧数据 → bswapped 缓冲 → 熵/预测/滤波初始化（对齐 init_frame_decoder）。
/// 截断帧（文件尾数据不足）按 FFmpeg 语义处理：读入可用前缀继续解码，
/// 熵解码将在数据耗尽处置 rc.err（decodeFrame 保留已成功块输出）。
/// 返回 false = 帧位置无任何数据（EOF，视为播放结束）。
fn initFrame(ctx: *ApeCtx, frame_idx: usize) Error!bool {
    const f = &ctx.header.frames[frame_idx];
    if (f.nblocks == 0) return error.Corrupt;
    const need: usize = @intCast(f.size);
    if (need > frame_data_cap) return error.Corrupt;
    if (need > ctx.frame_buf.len) return error.Corrupt;

    try ctx.reader.seek(@intCast(f.pos), .start);
    const got = try ctx.reader.read(ctx.frame_buf[0..need]);
    if (got == 0) return false;

    // 组装 packet（nblocks LE + skip LE + 帧数据）→ bswap 字
    const packet_len = got + 8;
    var buf_size = packet_len & ~@as(usize, 3);
    if (ctx.header.fileversion < 3950) buf_size += 2;
    if (buf_size > ctx.data_buf.len) return error.Corrupt;
    const data = ctx.data_buf[0..buf_size];
    @memset(data, 0);
    std.mem.writeInt(u32, data[0..4], f.nblocks, .little);
    std.mem.writeInt(u32, data[4..8], f.skip, .little);
    // 对齐 FFmpeg：仅复制 buf_size 字节（截断帧的尾部不足 4 字节被丢弃，参考 bswap_buf）
    @memcpy(data[8..buf_size], ctx.frame_buf[0 .. buf_size - 8]);
    var wi: usize = 0;
    while (wi < (buf_size >> 2)) : (wi += 1) {
        const w = std.mem.readInt(u32, data[wi * 4 ..][0..4], .little);
        std.mem.writeInt(u32, data[wi * 4 ..][0..4], @byteSwap(w), .little);
    }

    ctx.rc = RangeCtx.init(data, ctx.header.fileversion);
    ctx.rc.ptr = 8;
    const offset = f.skip;
    if (ctx.header.fileversion >= 3900) {
        if (offset > 3) return error.Corrupt;
        ctx.rc.ptr += @intCast(offset);
    }

    // init_entropy_decoder
    if (ctx.header.fileversion >= 3900) {
        ctx.frame_crc = try ctx.rc.readBe32();
    } else {
        ctx.rc.gb = BitReader.init(data[8..buf_size]);
        ctx.rc.gb_active = true;
        if (ctx.header.fileversion > 3800) {
            ctx.rc.gb.skipBits(@as(usize, offset) * 8);
        } else {
            ctx.rc.gb.skipBits(offset);
        }
        ctx.frame_crc = try ctx.rc.gb.readBits(32);
    }
    ctx.frameflags = 0;
    ctx.crc_state = 0xFFFFFFFF;
    if (ctx.header.fileversion > 3820 and (ctx.frame_crc & 0x80000000) != 0) {
        ctx.frame_crc &= ~@as(u32, 0x80000000);
        ctx.frameflags = try ctx.rc.readBe32();
    }
    ctx.rc.riceX = .{};
    ctx.rc.riceY = .{};
    if (ctx.header.fileversion >= 3900) {
        _ = try ctx.rc.readByte(); // 前 8 位忽略
        try ctx.rc.rangeStart();
    }

    // init_predictor_decoder + init_filter（每帧重置）
    ctx.predictor.init(ctx.header.fileversion, ctx.header.compression_level);
    ctx.predictor64.init();
    ctx.filters.reset();
    return true;
}

/// 预测器分派（按版本）
fn predictorDecodeStereo(ctx: *ApeCtx, count: usize) void {
    if (ctx.header.fileversion < 3930) {
        predictor.predictStereo3800(&ctx.predictor, ctx.decoded0[0..count], ctx.decoded1[0..count], ctx.header.compression_level, ctx.header.fileversion, count);
    } else if (ctx.header.fileversion < 3950) {
        predictor.applyFilters(&ctx.filters, ctx.decoded0[0..count], ctx.decoded1[0..count], count, ctx.header.fileversion);
        predictor.predictStereo3930(&ctx.predictor, ctx.decoded0[0..count], ctx.decoded1[0..count], count);
    } else {
        predictor.applyFilters(&ctx.filters, ctx.decoded0[0..count], ctx.decoded1[0..count], count, ctx.header.fileversion);
        predictor.predictStereo3950(&ctx.predictor64, &ctx.interim_mode, ctx.decoded0[0..count], ctx.decoded1[0..count], ctx.interim0, ctx.interim1, count);
    }
}

fn predictorDecodeMono(ctx: *ApeCtx, count: usize) void {
    if (ctx.header.fileversion < 3930) {
        predictor.predictMono3800(&ctx.predictor, ctx.decoded0[0..count], ctx.header.compression_level, ctx.header.fileversion, count);
    } else if (ctx.header.fileversion < 3950) {
        predictor.applyFilters(&ctx.filters, ctx.decoded0[0..count], null, count, ctx.header.fileversion);
        predictor.predictMono3930(&ctx.predictor, ctx.decoded0[0..count], count);
    } else {
        predictor.applyFilters(&ctx.filters, ctx.decoded0[0..count], null, count, ctx.header.fileversion);
        predictor.predictMono3950(&ctx.predictor64, ctx.decoded0[0..count], count);
    }
}

/// ape_unpack_mono（frameflags & 3 非零 = 纯静音）
fn unpackMono(ctx: *ApeCtx, count: usize) Error!void {
    if ((ctx.frameflags & 3) != 0) return;
    try ctx.rc.entropyMono(ctx.decoded0[0..count], count);
    predictorDecodeMono(ctx, count);
    if (ctx.header.channels == 2) {
        @memcpy(ctx.decoded1[0..count], ctx.decoded0[0..count]);
    }
}

/// ape_unpack_stereo（frameflags & 3 == 3 = 纯静音；预测后去相关）
fn unpackStereo(ctx: *ApeCtx, count: usize) Error!void {
    if ((ctx.frameflags & 3) == 3) return;
    try ctx.rc.entropyStereo(ctx.decoded0[0..count], ctx.decoded1[0..count], count);
    predictorDecodeStereo(ctx, count);
    for (0..count) |i| {
        const d0 = ctx.decoded0[i];
        const d1 = ctx.decoded1[i];
        const left: i32 = d1 -% @divTrunc(d0, 2);
        const right: i32 = left +% d0;
        ctx.decoded0[i] = left;
        ctx.decoded1[i] = right;
    }
}

/// 输出打包：逐样本写交错 PCM（对齐 FFmpeg bps 转换）
fn packChunk(ctx: *ApeCtx, base_off: usize, count: usize) void {
    const bps = ctx.out_bps;
    var off = base_off;
    for (0..count) |i| {
        off += writeOne(ctx.out_buf[off..], ctx.decoded0[i], bps);
        if (ctx.header.channels == 2) off += writeOne(ctx.out_buf[off..], ctx.decoded1[i], bps);
    }
}

fn writeOne(buf: []u8, v: i32, bps: u8) usize {
    switch (bps) {
        8 => {
            buf[0] = @truncate(@as(u32, @bitCast(v)) +% 0x80);
            return 1;
        },
        16 => {
            std.mem.writeInt(i16, buf[0..2], @truncate(v), .little);
            return 2;
        },
        32 => {
            std.mem.writeInt(i32, buf[0..4], @bitCast(@as(u32, @bitCast(v)) *% 256), .little);
            return 4;
        },
        else => return 0,
    }
}

/// 帧 CRC 累计（对齐 ape_decode_frame 的 AV_EF_CRCCHECK 路径）
fn crcChunk(ctx: *ApeCtx, crc: u32, count: usize) u32 {
    const bps = ctx.header.bps;
    var c = crc;
    var tmp: [4]u8 = undefined;
    for (0..count) |i| {
        c = crcSample(c, &tmp, ctx.decoded0[i], bps);
        if (ctx.header.channels == 2) c = crcSample(c, &tmp, ctx.decoded1[i], bps);
    }
    return c;
}

fn crcSample(crc: u32, tmp: *[4]u8, v: i32, bps: u32) u32 {
    switch (bps) {
        8 => return crcUpdate(crc, @truncate(@as(u32, @bitCast(v)) +% 0x80)),
        16 => {
            std.mem.writeInt(i16, tmp[0..2], @truncate(v), .little);
            return crcUpdateBytes(crc, tmp[0..2]);
        },
        24 => {
            std.mem.writeInt(u32, tmp[0..4], @as(u32, @bitCast(v)) *% 256, .little);
            return crcUpdateBytes(crc, tmp[1..4]);
        },
        else => return crc,
    }
}

/// 解码整帧到 out_buf；帧末做 CRC 校验（>= 3900）。
/// 截断/损坏帧（熵解码数据耗尽置 rc.err）：保留已成功块输出、跳过 CRC、
/// 置 EOF（对齐 FFmpeg：失败块整体丢弃，先前块正常输出）。
/// 返回后 current_frame 前进；EOF 后调用不产生帧。
fn decodeFrame(ctx: *ApeCtx, frame_idx: usize) Error!void {
    if (!try initFrame(ctx, frame_idx)) {
        // 帧位置无数据（截断文件 / 越界 seek）→ EOF
        ctx.current_frame = ctx.header.totalframes;
        ctx.out_len = 0;
        ctx.out_cursor = 0;
        return;
    }
    const f = &ctx.header.frames[frame_idx];
    const frame_bytes = @as(usize, ctx.header.channels) * (ctx.out_bps / 8);
    ctx.out_len = 0;
    ctx.out_cursor = 0;
    ctx.crc_state = 0xFFFFFFFF;

    const mono_mode = (ctx.header.channels == 1) or (ctx.frameflags & 4) != 0;
    var remaining: usize = f.nblocks;
    var truncated = false;
    while (remaining > 0) {
        const count: usize = if (ctx.header.fileversion < 3930) remaining else @min(BLOCKS_PER_LOOP, remaining);
        @memset(ctx.decoded0[0..count], 0);
        @memset(ctx.decoded1[0..count], 0);
        if (mono_mode) {
            try unpackMono(ctx, count);
        } else {
            try unpackStereo(ctx, count);
        }
        if (ctx.rc.err) {
            truncated = true;
            break;
        }
        const base_off = (f.nblocks - remaining) * frame_bytes;
        packChunk(ctx, base_off, count);
        ctx.crc_state = crcChunk(ctx, ctx.crc_state, count);
        remaining -= count;
    }

    ctx.out_len = (f.nblocks - remaining) * frame_bytes;
    if (truncated) {
        // 帧未完整：数据耗尽，置 EOF（不再有后续帧输出）
        ctx.current_frame = ctx.header.totalframes;
        return;
    }

    if (ctx.header.fileversion >= 3900) {
        if (((~ctx.crc_state >> 1) ^ ctx.frame_crc) != 0) return error.Corrupt;
    }
    ctx.current_frame = frame_idx + 1;
}

// ---------------------------------------------------------------------------
// VTable + 入口
// ---------------------------------------------------------------------------

fn readImpl(ctx: *anyopaque, out: []u8, max_samples: usize, out_channels: *u8) Error!usize {
    const a: *ApeCtx = @ptrCast(@alignCast(ctx));
    out_channels.* = @intCast(a.header.channels);
    const frame_bytes = @as(usize, a.header.channels) * (a.out_bps / 8);
    if (a.header.channels == 0 or max_samples == 0 or out.len == 0) return 0;
    const cap = @min(max_samples, out.len / frame_bytes);
    var produced: usize = 0;
    while (produced < cap) {
        if (a.out_cursor < a.out_len) {
            const avail = a.out_len - a.out_cursor;
            const take = @min(avail, (cap - produced) * frame_bytes);
            @memcpy(out[produced * frame_bytes ..][0..take], a.out_buf[a.out_cursor..][0..take]);
            a.out_cursor += take;
            produced += take / frame_bytes;
            a.samples_done += take / frame_bytes;
        } else if (a.current_frame < a.header.totalframes) {
            try decodeFrame(a, a.current_frame);
        } else {
            break; // EOF
        }
    }
    return produced;
}

fn seekMsImpl(ctx: *anyopaque, ms: i64) Error!void {
    const a: *ApeCtx = @ptrCast(@alignCast(ctx));
    var target: u64 = if (ms <= 0)
        0
    else
        @intCast((@as(u128, @intCast(ms)) * a.header.samplerate) / 1000);
    if (a.header.total_samples > 0 and target > a.header.total_samples) target = a.header.total_samples;
    const bpf = a.header.blocksperframe;
    const last_idx = a.header.totalframes - 1;
    var frame_idx: usize = if (bpf > 0) target / bpf else 0;
    if (frame_idx > last_idx) frame_idx = last_idx;
    const frame_start: u64 = if (frame_idx == last_idx)
        a.header.total_samples -% a.header.finalframeblocks
    else
        @as(u64, frame_idx) * bpf;
    try decodeFrame(a, frame_idx);
    const frame_bytes = frameBytesOf(a);
    const frame_samples: u64 = @intCast(a.out_len / frame_bytes);
    const skip = @min(target -% frame_start, frame_samples);
    a.out_cursor = @intCast(skip * frame_bytes);
    a.samples_done = target;
}

inline fn frameBytesOf(a: *const ApeCtx) usize {
    return @as(usize, a.header.channels) * (a.out_bps / 8);
}

fn positionMsImpl(ctx: *anyopaque) i64 {
    const a: *ApeCtx = @ptrCast(@alignCast(ctx));
    if (a.header.samplerate == 0) return 0;
    return @intCast((a.samples_done * 1000) / a.header.samplerate);
}

fn deinitImpl(ctx: *anyopaque) void {
    const a: *ApeCtx = @ptrCast(@alignCast(ctx));
    a.allocator.free(a.header.frames);
    a.filters.deinit(a.allocator);
    if (a.decoded0.len > 0) a.allocator.free(a.decoded0);
    if (a.decoded1.len > 0) a.allocator.free(a.decoded1);
    if (a.interim0.len > 0) a.allocator.free(a.interim0);
    if (a.interim1.len > 0) a.allocator.free(a.interim1);
    if (a.frame_buf.len > 0) a.allocator.free(a.frame_buf);
    if (a.data_buf.len > 0) a.allocator.free(a.data_buf);
    if (a.out_buf.len > 0) a.allocator.free(a.out_buf);
    a.reader.deinit();
    a.allocator.destroy(a);
}

fn buildInfo(a: *ApeCtx) decoder.Info {
    var duration_us: i64 = 0;
    var known: decoder.DurationKnown = .unknown;
    if (a.header.total_samples > 0 and a.header.samplerate > 0) {
        // 四舍五入到 µs（对齐 ffprobe 的 duration 舍入显示）
        const sr: u128 = a.header.samplerate;
        duration_us = @intCast((@as(u128, a.header.total_samples) * 1_000_000 + sr / 2) / sr);
        known = .exact;
    }
    return .{
        .sample_rate = a.header.samplerate,
        .channels = @intCast(a.header.channels),
        .bits_per_sample = a.out_bps,
        .is_float = false,
        .duration_us = duration_us,
        .duration_known = known,
        .codec_name = "ape",
        .format_name = "ape",
        .metadata = .{},
    };
}

/// 打开 APE：解析容器 → 校验版本/位深/声道/压缩级别 → 分配缓冲 → 填 Info。
pub fn open(allocator: std.mem.Allocator, reader: *io.Reader, info: *decoder.Info) Error!decoder.Decoder {
    const header = try container.parse(allocator, reader);
    errdefer allocator.free(header.frames);

    if (header.bps != 8 and header.bps != 16 and header.bps != 24) return error.UnsupportedFormat;
    if (header.channels == 0 or header.channels > 2) return error.UnsupportedFormat;
    const cl = header.compression_level;
    if (cl % 1000 != 0 or cl > predictor.COMPRESSION_LEVEL_INSANE or cl == 0) return error.UnsupportedFormat;
    if (header.fileversion < 3930 and cl == predictor.COMPRESSION_LEVEL_INSANE) return error.UnsupportedFormat;
    const fset = cl / 1000 - 1;

    const ctx = try allocator.create(ApeCtx);
    errdefer allocator.destroy(ctx);
    ctx.* = .{
        .allocator = allocator,
        .reader = reader.*,
        .header = header,
        .out_bps = if (header.bps == 24) 32 else @intCast(header.bps),
        .interim_mode = if (header.bps == 24) -1 else 0,
    };
    errdefer deinitCtxBuffers(ctx);

    try ctx.filters.init(allocator, fset);
    errdefer ctx.filters.deinit(allocator);

    const max_samples = @as(usize, header.blocksperframe);
    if (max_samples == 0) return error.Corrupt;
    ctx.decoded0 = try allocator.alloc(i32, max_samples);
    ctx.decoded1 = try allocator.alloc(i32, max_samples);
    errdefer {
        allocator.free(ctx.decoded0);
        allocator.free(ctx.decoded1);
    }
    if (header.bps == 24) {
        ctx.interim0 = try allocator.alloc(i32, BLOCKS_PER_LOOP);
        ctx.interim1 = try allocator.alloc(i32, BLOCKS_PER_LOOP);
        errdefer {
            allocator.free(ctx.interim0);
            allocator.free(ctx.interim1);
        }
    }

    const frame_cap = @min(frame_data_cap, max_samples * @as(usize, header.channels) * 4 + 16);
    ctx.frame_buf = try allocator.alloc(u8, frame_cap);
    ctx.data_buf = try allocator.alloc(u8, frame_cap + 16);
    ctx.out_buf = try allocator.alloc(u8, max_samples * @as(usize, header.channels) * (ctx.out_bps / 8));
    errdefer deinitCtxBuffers(ctx);

    info.* = buildInfo(ctx);
    return .{ .vtable = &vtable, .ctx = @ptrCast(ctx) };
}

/// 释放 ctx 缓冲（open 错误路径与 deinit 共用；filters 单独处理）
fn deinitCtxBuffers(ctx: *ApeCtx) void {
    if (ctx.decoded0.len > 0) ctx.allocator.free(ctx.decoded0);
    if (ctx.decoded1.len > 0) ctx.allocator.free(ctx.decoded1);
    if (ctx.interim0.len > 0) ctx.allocator.free(ctx.interim0);
    if (ctx.interim1.len > 0) ctx.allocator.free(ctx.interim1);
    if (ctx.frame_buf.len > 0) ctx.allocator.free(ctx.frame_buf);
    if (ctx.data_buf.len > 0) ctx.allocator.free(ctx.data_buf);
    if (ctx.out_buf.len > 0) ctx.allocator.free(ctx.out_buf);
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "ape: crc32 反射表与已知向量" {
    // CRC-32 标准向量（"123456789" → 0xCBF43926，反射多项式，init 0xFFFFFFFF 初值）
    var c: u32 = 0xFFFFFFFF;
    for ("123456789") |b| c = crcUpdate(c, b);
    try testing.expectEqual(@as(u32, 0xCBF43926), ~c);
}

test "ape: zigzag 符号解码" {
    // x=0 → 0；x=1 → 1；x=2 → -1；x=3 → 2；x=4 → -2
    try testing.expectEqual(@as(i32, 0), rangecoder.zigzag(0));
    try testing.expectEqual(@as(i32, 1), rangecoder.zigzag(1));
    try testing.expectEqual(@as(i32, -1), rangecoder.zigzag(2));
    try testing.expectEqual(@as(i32, 2), rangecoder.zigzag(3));
    try testing.expectEqual(@as(i32, -2), rangecoder.zigzag(4));
}

test "ape: APESIGN 逆符号" {
    try testing.expectEqual(@as(i32, 1), predictor.apeSign(-5));
    try testing.expectEqual(@as(i32, -1), predictor.apeSign(5));
    try testing.expectEqual(@as(i32, 0), predictor.apeSign(0));
}

test "ape: getK（ceil(log2(x+1))）" {
    try testing.expectEqual(@as(u32, 0), rangecoder.getK(0));
    try testing.expectEqual(@as(u32, 1), rangecoder.getK(1));
    try testing.expectEqual(@as(u32, 2), rangecoder.getK(2));
    try testing.expectEqual(@as(u32, 2), rangecoder.getK(3));
    try testing.expectEqual(@as(u32, 3), rangecoder.getK(4));
}

test "ape: update_rice 自适应收敛" {
    var r: rangecoder.Rice = .{};
    const k0 = r.k;
    const ksum0 = r.ksum;
    // 大幅 x → ksum 上升 → k 上调
    rangecoder.updateRice(&r, 1 << 18);
    try testing.expect(r.k > k0);
    try testing.expect(r.ksum > ksum0);
}

test "ape: bitreader MSB-first 与 unaryStop" {
    // 0xA5 = 1010 0101：readBits(4) = 0b1010 = 10
    var br = BitReader.init(&[_]u8{0xA5});
    try testing.expectEqual(@as(u32, 10), try br.readBits(4));
    try testing.expectEqual(@as(u32, 5), try br.readBits(4));
    // unaryStop(1)：0xC0 = 1100 0000 → 首位即 stop → 0
    var br2 = BitReader.init(&[_]u8{0xC0});
    try testing.expectEqual(@as(usize, 0), br2.unaryStop(1, 8));
    // 0x3C = 0011 1100 → 两个 0 后 stop → 2
    var br3 = BitReader.init(&[_]u8{0x3C});
    try testing.expectEqual(@as(usize, 2), br3.unaryStop(1, 8));
}

test "ape: 容器解析 3800 老格式头（构造最小合法头）" {
    // 手工构造：MAC + 3800 + 老格式头 + seektable(1 项) + bittable(1 字节)
    var data = std.ArrayList(u8).empty;
    defer data.deinit(testing.allocator);
    try data.appendSlice(testing.allocator, "MAC ");
    try data.appendSlice(testing.allocator, &.{ 0xD8, 0x0E }); // 3800
    try data.appendSlice(testing.allocator, &.{ 0xD0, 0x07 }); // compression 2000
    try data.appendSlice(testing.allocator, &.{ 0x00, 0x00 }); // formatflags 0
    try data.appendSlice(testing.allocator, &.{ 0x02, 0x00 }); // channels 2
    try data.appendSlice(testing.allocator, &.{ 0x44, 0xAC, 0x00, 0x00 }); // 44100
    try data.appendSlice(testing.allocator, &.{ 0x00, 0x00, 0x00, 0x00 }); // wavheader 0
    try data.appendSlice(testing.allocator, &.{ 0x00, 0x00, 0x00, 0x00 }); // wavtail 0
    try data.appendSlice(testing.allocator, &.{ 0x01, 0x00, 0x00, 0x00 }); // totalframes 1
    try data.appendSlice(testing.allocator, &.{ 0x10, 0x00, 0x00, 0x00 }); // finalframeblocks 16
    try data.appendSlice(testing.allocator, &.{ 0x00, 0x00, 0x00, 0x00 }); // seektable[0]
    try data.appendSlice(testing.allocator, &.{ 0x00 }); // bittable[0]
    // 帧数据（20 字节，nblocks=16 → 4 字）
    try data.appendNTimes(testing.allocator, 0, 20);

    var r = io.Reader.openMem(data.items);
    const header = try container.parse(testing.allocator, &r);
    defer testing.allocator.free(header.frames);
    try testing.expectEqual(@as(u32, 3800), header.fileversion);
    try testing.expectEqual(@as(u32, 2000), header.compression_level);
    try testing.expectEqual(@as(u32, 2), header.channels);
    try testing.expectEqual(@as(u32, 44100), header.samplerate);
    try testing.expectEqual(@as(u32, 16), header.bps);
    try testing.expectEqual(@as(u32, 1), header.totalframes);
    try testing.expectEqual(@as(u32, 9216), header.blocksperframe);
    try testing.expectEqual(@as(u64, 16), header.total_samples);
    // firstframe = 32 + seektable(4) + bittable(1) = 37
    try testing.expectEqual(@as(u64, 37), header.frames[0].pos);
}

test "ape: 容器解析 3990 描述符头 + 内嵌 WAV 头位于 seektable 之前" {
    var data = std.ArrayList(u8).empty;
    defer data.deinit(testing.allocator);
    try data.appendSlice(testing.allocator, "MAC ");
    try data.appendSlice(testing.allocator, &.{ 0x96, 0x0F }); // 3990
    try data.appendSlice(testing.allocator, &.{ 0x00, 0x00 }); // padding1
    try data.appendSlice(testing.allocator, &.{ 0x34, 0x00, 0x00, 0x00 }); // descriptorlength 52
    try data.appendSlice(testing.allocator, &.{ 0x18, 0x00, 0x00, 0x00 }); // headerlength 24
    try data.appendSlice(testing.allocator, &.{ 0x08, 0x00, 0x00, 0x00 }); // seektablelength 8 (2 帧)
    try data.appendSlice(testing.allocator, &.{ 0x2C, 0x00, 0x00, 0x00 }); // wavheaderlength 44
    try data.appendSlice(testing.allocator, &.{ 0x00, 0x00, 0x00, 0x00 }); // audiodatalength
    try data.appendSlice(testing.allocator, &.{ 0x00, 0x00, 0x00, 0x00 }); // audiodatalength_high
    try data.appendSlice(testing.allocator, &.{ 0x00, 0x00, 0x00, 0x00 }); // wavtaillength
    try data.appendNTimes(testing.allocator, 0, 16); // md5
    // 头部（offset 52）
    try data.appendSlice(testing.allocator, &.{ 0xD0, 0x07 }); // compression 2000
    try data.appendSlice(testing.allocator, &.{ 0x00, 0x00 }); // formatflags 0
    try data.appendSlice(testing.allocator, &.{ 0x00, 0x20, 0x01, 0x00 }); // blocksperframe 73728
    try data.appendSlice(testing.allocator, &.{ 0x10, 0x00, 0x00, 0x00 }); // finalframeblocks 16
    try data.appendSlice(testing.allocator, &.{ 0x02, 0x00, 0x00, 0x00 }); // totalframes 2
    try data.appendSlice(testing.allocator, &.{ 0x10, 0x00 }); // bps 16
    try data.appendSlice(testing.allocator, &.{ 0x02, 0x00 }); // channels 2
    try data.appendSlice(testing.allocator, &.{ 0x44, 0xAC, 0x00, 0x00 }); // 44100
    // seektable（offset 76）：首项丢弃，第二项 = 帧 1 绝对偏移
    try data.appendSlice(testing.allocator, &.{ 0x00, 0x00, 0x00, 0x00 }); // seektable[0]
    try data.appendSlice(testing.allocator, &.{ 0x00, 0x04, 0x00, 0x00 }); // seektable[1] = 0x400
    // 内嵌 WAV 头（44 字节，位于 seektable 之后、首帧之前）
    try data.appendNTimes(testing.allocator, 0xAB, 44);

    var r = io.Reader.openMem(data.items);
    const header = try container.parse(testing.allocator, &r);
    defer testing.allocator.free(header.frames);
    try testing.expectEqual(@as(u32, 3990), header.fileversion);
    try testing.expectEqual(@as(u32, 2), header.totalframes);
    try testing.expectEqual(@as(u32, 73728), header.blocksperframe);
    try testing.expectEqual(@as(u64, 73744), header.total_samples);
    // firstframe = 52 + 24 + 8 + 44 = 128；帧 0 size = 0x400 - 128
    try testing.expectEqual(@as(u64, 128), header.frames[0].pos);
    try testing.expectEqual(@as(u64, 0x400 - 128), header.frames[0].size);
    try testing.expectEqual(@as(u64, 0x400), header.frames[1].pos);
    try testing.expectEqual(@as(u32, 16), header.frames[1].nblocks);
    // 帧 1 位置 0x400 与首帧差 896 → & 3 = 0
    try testing.expectEqual(@as(u32, 0), header.frames[1].skip);
}

test "ape: 容器解析 peak level 偏移（3800 + HAS_PEAK_LEVEL）" {
    var data = std.ArrayList(u8).empty;
    defer data.deinit(testing.allocator);
    try data.appendSlice(testing.allocator, "MAC ");
    try data.appendSlice(testing.allocator, &.{ 0xD8, 0x0E }); // 3800
    try data.appendSlice(testing.allocator, &.{ 0xD0, 0x07 }); // compression 2000
    try data.appendSlice(testing.allocator, &.{ 0x06, 0x00 }); // formatflags = CRC|HAS_PEAK_LEVEL
    try data.appendSlice(testing.allocator, &.{ 0x02, 0x00 }); // channels 2
    try data.appendSlice(testing.allocator, &.{ 0x44, 0xAC, 0x00, 0x00 }); // 44100
    try data.appendSlice(testing.allocator, &.{ 0x00, 0x00, 0x00, 0x00 }); // wavheader 0
    try data.appendSlice(testing.allocator, &.{ 0x00, 0x00, 0x00, 0x00 }); // wavtail 0
    try data.appendSlice(testing.allocator, &.{ 0x01, 0x00, 0x00, 0x00 }); // totalframes 1
    try data.appendSlice(testing.allocator, &.{ 0x10, 0x00, 0x00, 0x00 }); // finalframeblocks 16
    try data.appendSlice(testing.allocator, &.{ 0x15, 0x7D, 0x00, 0x00 }); // peak level
    try data.appendSlice(testing.allocator, &.{ 0x00, 0x00, 0x00, 0x00 }); // seektable[0]
    try data.appendSlice(testing.allocator, &.{ 0x00 }); // bittable[0]

    var r = io.Reader.openMem(data.items);
    const header = try container.parse(testing.allocator, &r);
    defer testing.allocator.free(header.frames);
    // firstframe = 32 + peak(4) + seektable(4) + bittable(1) = 41
    try testing.expectEqual(@as(u64, 41), header.frames[0].pos);
    try testing.expectEqual(@as(u32, 16), header.bps);
}
