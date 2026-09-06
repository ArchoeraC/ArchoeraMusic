// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! 自研 WAV 解码器（docs/audio-kernel-zig.md §9.1）
//!
//! 容器（全部接管，probe 归并为 Format.wav 家族）：
//!   - RIFF / RIFX（big-endian）/ RF64（ds64 扩展）—— `fmt `/`data`/`fact` chunk；
//!   - W64（Sony Wave64，GUID 容器，支持多 `data` 段拼接）；
//!   - AIFF / AIFF-C（`COMM`/`SSND`/`FVER`，80-bit extended 采样率）；
//!   - CAF（Apple Core Audio，`caff` + `desc` 头，PCM `lpcm` 分支）；
//!   - AU / Sun（`.snd` 固定头，encoding 2..7 = 未压缩 PCM）。
//!
//! 编码：
//!   - PCM 整数（8/16/24/32/64 位；WAV 8-bit 为无符号 pcm_u8，AIFF 为有符号 pcm_s8，
//!     AIFC-"raw " 无符号，CAF/AU 8-bit 有符号 pcm_s8）、IEEE float（32/64 位，
//!     RIFX/AIFF/CAF/AU 大端，AIFC-"sowt" 小端，CAF 由 desc flags 决定 LE/BE）；
//!   - A-LAW / mu-LAW（G.711，解码为 16-bit 线性 s16 输出，小端）；
//!   - ADPCM（4-bit，输出 s16）：IMA WAV（tag 0x11）+ MS ADPCM（tag 2），块解码见 adpcm.zig；
//!   - WAVEFORMATEXTENSIBLE（0xFFFE，SubFormat GUID 判定子格式）；
//!   - 其余编码（GSM、CAF 内嵌 alac/aac/lpcm 可变包、AU mulaw/alaw 等）→
//!     error.UnsupportedFormat → 引擎回退 FFmpeg（§8.3）。
//!
//! 输出：原生位深交错 PCM（alaw/mulaw/adpcm 为 s16），由上层 pcm/* 统一转换。
//! 健壮性（§13.3）：chunk 循环有界、长度 clamp、字段范围校验、多 data 段越界保护。

const std = @import("std");
const Error = @import("../../error.zig").Error;
const io = @import("../../io.zig");
const decoder = @import("../../decoder.zig");
const chunk = @import("chunk.zig");
const decl = @import("decl.zig");
const g711 = @import("g711.zig");
const adpcm = @import("adpcm.zig");
const gsm = @import("gsm.zig");
const mace = @import("mace.zig");
const dpcm = @import("dpcm.zig");

const VTable = decoder.Decoder.VTable;
const Container = chunk.Container;

/// 数据段（W64 多 data / AIFF SSND；RIFF 单段）
const DataSeg = struct {
    /// 数据在文件中的绝对偏移
    offset: u64,
    size: u64,
};

/// WAV 上下文
const WavCtx = struct {
    allocator: std.mem.Allocator,
    /// 按值持有（decoder.open 传入的 reader 拷贝到本字段，避免悬垂指针）
    reader: io.Reader,
    container: Container,
    /// 样本字节序（RIFX/AIFF 大端；AIFC-"sowt" 覆盖为小端）
    endian: std.builtin.Endian,
    codec: decl.Codec,
    channels: u8,
    sample_rate: u32,
    /// 解码输出位深（alaw/mulaw = 16，其余为原生位深）
    bits_per_sample: u8,
    /// 流内一帧字节数（PCM: ch*bits/8；alaw/mulaw: ch）
    block_align: usize,
    /// 数据段（连续拼接为逻辑数据区）
    data: std.ArrayList(DataSeg),
    data_bytes: u64,
    /// 当前已读字节（相对数据区起点）
    position_bytes: u64,
    /// G.711 解码中间缓冲（G.711 输入 / ADPCM 解码输出）
    dec_buf: []u8,
    /// ADPCM 压缩块输入缓冲（须与解码输出分离，避免原地覆盖）
    blk_buf: []u8,
    /// 连续流 ADPCM（OKI/Yamaha/CT）跨 read 调用的解码状态；seek 时重置
    cont: adpcm.ContState,
    /// SANYO ADPCM 每块每通道样本数（fmt 扩展区 LE16；open 时从 fmt.extradata 读取）
    sanyo_samples_per_block: usize = 0,
    /// SANYO ADPCM 编码位深（fmt bits = 3/4/5，决定 expand 变体；与输出位深 16 不同）
    sanyo_bits: u8 = 0,
    /// SWF ADPCM 位深（数据区首字节高 2 位 + 2，2..5；open 时读取，adpcm.c 1377）
    swf_nbits: u8 = 0,
    /// SWF 位流游标：已消费位数（数据区起点起算，含首 2-bit nbits 字段）
    swf_bitpos: u64 = 0,
    /// SWF 当前块已输出样本数（每通道；0 = 位于块边界）
    swf_block_count: u32 = 0,
    /// SWF 已输出帧数（绝对，用于 position_ms）
    swf_frames: u64 = 0,
    /// G.726 解码状态（连续位流，跨 read 保持；seek 时重置）
    g726: adpcm.G726State,
    /// G.722 解码状态（连续流，跨 read 保持；seek 时重置）
    g722: adpcm.G722State,
    /// GSM 解码状态（ref_buf/v/lar/msr 跨块保持）；seek 时重置
    gsm_ctx: gsm.Context,
    /// MACE 解码状态（index/factor/level 等跨块保持）；seek 时重置
    mace_ctx: mace.Context,
    /// fact chunk 声明的帧数（存在且 >0 时优先于字节推算）
    fact_frames: ?u64,
    /// AIFF-C 压缩类型（非 AIFF 容器恒为 "NONE"）
    aiff_tag: [4]u8,
    /// 标签元数据（LIST/INFO、AIFF NAME/AUTH/ANNO 解析结果；deinit 时释放）
    meta: decoder.Metadata,
    /// 采样器循环点（`smpl` chunk；deinit 时释放）
    loops: []decoder.LoopPoint,
    /// 提示点（`cue ` chunk；deinit 时释放）
    cue_points: []decoder.CuePoint,
};

const vtable = VTable{
    .read = readImpl,
    .seek_ms = seekMsImpl,
    .position_ms = positionMsImpl,
    .deinit = deinitImpl,
};

/// chunk 循环上界（§13.3 防 DoS）
const max_chunks: u32 = 512;

/// 从已打开的 Reader 解析 WAV（decoder.open 与测试共用入口）。
/// 成功时 Decoder 接管 `reader` 的所有权（deinit 时关闭）。
pub fn open(allocator: std.mem.Allocator, reader: *io.Reader, info: *decoder.Info) Error!decoder.Decoder {
    // ---- 容器探测（peek 不消费，64 字节窗口覆盖 riff GUID）----
    var window: [64]u8 = undefined;
    const n = try reader.peek(&window);
    const head = window[0..n];

    const container, const init_endian, const is_aifc = try detectContainer(head);
    var ctx = try allocator.create(WavCtx);
    errdefer allocator.destroy(ctx);
    ctx.* = .{
        .allocator = allocator,
        .reader = undefined,
        .container = container,
        .endian = init_endian,
        .codec = .pcm_int,
        .channels = 0,
        .sample_rate = 0,
        .bits_per_sample = 0,
        .block_align = 0,
        .data = std.ArrayList(DataSeg).empty,
        .data_bytes = 0,
        .position_bytes = 0,
        .dec_buf = &.{},
        .blk_buf = &.{},
        .cont = .{},
        .g726 = .{},
        .g722 = .{},
        .gsm_ctx = .{},
        .mace_ctx = .{},
        .fact_frames = null,
        .aiff_tag = "NONE".*,
        .meta = .{},
        .loops = &.{},
        .cue_points = &.{},
    };
    errdefer ctx.data.deinit(allocator);
    errdefer if (ctx.dec_buf.len > 0) allocator.free(ctx.dec_buf);
    errdefer if (ctx.blk_buf.len > 0) allocator.free(ctx.blk_buf);
    errdefer freeMeta(allocator, &ctx.meta);
    errdefer freeLoops(allocator, &ctx.loops, &ctx.cue_points);

    // ---- CAF / AU：独立容器解析（其余 RIFF 家族走统一 chunk 扫描）----
    switch (container) {
        .caf => return openCaf(ctx, reader, info),
        .au => return openAu(ctx, reader, info),
        else => {},
    }

    // ---- 消费容器头 ----
    switch (container) {
        .riff => {
            var h: [12]u8 = undefined;
            if (!try readExact(reader, &h)) return error.Corrupt;
            if (!std.mem.eql(u8, h[8..12], "WAVE")) return error.Corrupt;
        },
        .w64 => {
            if (!try chunk.checkW64Header(reader)) return error.Corrupt;
        },
        .aiff => {
            const ok = try chunk.checkAiffHeader(reader);
            if (ok == null) return error.Corrupt;
        },
        // CAF / AU 已在上方独立解析返回，不可达
        .caf, .au => unreachable,
    }

    // ---- chunk 遍历（有界，§13.3）----
    var fmt_opt: ?decl.WavFmt = null;
    var ds64_data_size: ?u64 = null;
    var data_found = false;
    var chunks_seen: u32 = 0;

    while (chunks_seen < max_chunks) : (chunks_seen += 1) {
        const c = (try chunk.nextChunk(reader, container, ctx.endian)) orelse break;
        const id = c.id;

        switch (container) {
            .riff => {
                if (std.mem.eql(u8, &id, "fmt ")) {
                    fmt_opt = try decl.parseWavFmt(reader, c.size, ctx.endian);
                    try skipRest(reader, c.size, c, .riff);
                } else if (std.mem.eql(u8, &id, "ds64")) {
                    var ds: [24]u8 = undefined;
                    if (!try readExact(reader, &ds)) return error.Corrupt;
                    ds64_data_size = readU64(ds[8..16], .little); // dataSize
                    try skipRest(reader, 24, c, .riff);
                } else if (std.mem.eql(u8, &id, "data")) {
                    const data_size: u64 = if (c.size == 0xFFFFFFFF)
                        ds64_data_size orelse return error.Corrupt
                    else
                        c.size;
                    try addSeg(ctx, reader.pos, data_size);
                    data_found = true;
                    try chunk.skipChunk(reader, c, .riff);
                } else if (std.mem.eql(u8, &id, "fact")) {
                    var f: [4]u8 = undefined;
                    if (!try readExact(reader, &f)) return error.Corrupt;
                    const samples = readU32(f[0..4], ctx.endian);
                    if (samples > 0) ctx.fact_frames = samples;
                    try skipRest(reader, 4, c, .riff);
                } else if (std.mem.eql(u8, &id, "LIST")) {
                    // RIFF LIST：仅解析 INFO 子列表（标签元数据），其余原样跳过
                    if (c.size >= 4) {
                        var lst: [4]u8 = undefined;
                        if (!try readExact(reader, &lst)) return error.Corrupt;
                        if (std.mem.eql(u8, &lst, "INFO")) {
                            try parseInfoList(ctx, reader, c.size - 4);
                            try skipRest(reader, c.size, c, .riff); // 已消费全部 payload
                        } else {
                            try skipRest(reader, 4, c, .riff);
                        }
                    } else {
                        try chunk.skipChunk(reader, c, .riff);
                    }
                } else if (std.mem.eql(u8, &id, "smpl")) {
                    // 采样器循环点（标准 sampler chunk）
                    try parseSmpl(ctx, reader, c);
                } else if (std.mem.eql(u8, &id, "cue ")) {
                    // 提示点
                    try parseCue(ctx, reader, c);
                } else {
                    try chunk.skipChunk(reader, c, .riff);
                }
            },
            .w64 => {
                if (std.mem.eql(u8, &id, "fmt ")) {
                    fmt_opt = try decl.parseWavFmt(reader, c.size, .little);
                    try skipRest(reader, c.size, c, .w64);
                } else if (std.mem.eql(u8, &id, "fact")) {
                    var f: [8]u8 = undefined;
                    if (!try readExact(reader, &f)) return error.Corrupt;
                    const samples = readU64(f[0..8], .little);
                    if (samples > 0) ctx.fact_frames = samples;
                    try skipRest(reader, 8, c, .w64);
                } else if (std.mem.eql(u8, &id, "data")) {
                    try addSeg(ctx, reader.pos, c.size);
                    data_found = true;
                    try chunk.skipChunk(reader, c, .w64);
                } else {
                    try chunk.skipChunk(reader, c, .w64);
                }
            },
            .aiff => {
                if (std.mem.eql(u8, &id, "COMM")) {
                    const comm = try decl.parseAiffComm(reader, c.size, is_aifc);
                    fmt_opt = comm.fmt;
                    ctx.aiff_tag = comm.tag;
                    // AIFC-"sowt"（小端 PCM）覆盖容器默认大端；其余保持大端
                    if (std.mem.eql(u8, &comm.tag, "sowt")) ctx.endian = .little;
                    try skipRest(reader, c.size, c, .aiff);
                } else if (std.mem.eql(u8, &id, "SSND")) {
                    if (c.size < 8) return error.Corrupt;
                    var so: [8]u8 = undefined;
                    if (!try readExact(reader, &so)) return error.Corrupt;
                    const offset_field = readU32(so[0..4], .big);
                    const abs_offset = reader.pos + offset_field;
                    const data_size = c.size - 8 - offset_field;
                    try addSeg(ctx, abs_offset, data_size);
                    data_found = true;
                    try skipRest(reader, 8, c, .aiff);
                } else if (std.mem.eql(u8, &id, "NAME") or
                    std.mem.eql(u8, &id, "AUTH") or
                    std.mem.eql(u8, &id, "ANNO"))
                {
                    // AIFF 标签：pascal 字符串（1 字节 len + 文本）
                    if (c.size >= 1) {
                        var lb: [1]u8 = undefined;
                        if (!try readExact(reader, &lb)) return error.Corrupt;
                        const len = @min(@as(u64, lb[0]), c.size - 1);
                        try readTextField(ctx, aiffFieldOf(id), reader, len);
                        try skipRest(reader, 1 + len, c, .aiff);
                    } else {
                        try chunk.skipChunk(reader, c, .aiff);
                    }
                } else {
                    try chunk.skipChunk(reader, c, .aiff);
                }
            },
            // CAF / AU 已在上方独立解析返回，不可达
            .caf, .au => unreachable,
        }
    }

    const fmt = fmt_opt orelse return error.Corrupt;
    ctx.codec = fmt.codec;
    ctx.channels = @intCast(fmt.channels);
    ctx.sample_rate = fmt.sample_rate;
    ctx.block_align = fmt.block_align;
    // 解码输出位深：G.711 / ADPCM / GSM / MACE / XAN 为 s16，其余为原生位深
    ctx.bits_per_sample = switch (fmt.codec) {
        .alaw, .mulaw, .adpcm_ms, .adpcm_ima, .adpcm_ima_qt, .adpcm_oki, .adpcm_yamaha, .adpcm_ct, .adpcm_dk4, .adpcm_dk3, .adpcm_xbox, .adpcm_sanyo, .gsm, .mace3, .mace6, .xan, .adpcm_zork, .adpcm_swf, .adpcm_g722, .adpcm_g726 => 16,
        // F16/F24：4 字节槽位解码为 f32（缩放后），输出位深恒 32
        .pcm_f16, .pcm_f24 => 32,
        else => @intCast(fmt.bits),
    };
    // SANYO 每块样本数存于 fmt 扩展区（LE16）；validate 已保证 extradata_len == 2
    if (fmt.codec == .adpcm_sanyo) {
        ctx.sanyo_samples_per_block = adpcm.sanyoSamplesPerBlock(fmt.extradata[0..fmt.extradata_len]) catch return error.Corrupt;
        ctx.sanyo_bits = @intCast(fmt.bits);
    }
    // Creative CT 连续流初始步长 511（镜像 FFmpeg adpcm_init，adpcm.c 2916-2918）
    if (fmt.codec == .adpcm_ct) adpcm.resetCont(&ctx.cont, true);
    // G.726：code_size = fmt.bits（decl 已按 byte_rate/sample_rate 覆盖，
    // riffdec.c 254-256），并初始化解码状态（镜像 g726_decode_init → g726_reset）
    if (fmt.codec == .adpcm_g726) {
        ctx.g726.code_size = @intCast(fmt.bits);
        adpcm.g726Reset(&ctx.g726);
    }
    // 无数据段：空数据（duration 0，read 返回 EOF）
    if (!data_found) {
        ctx.data_bytes = 0;
    }

    // ---- data 段 clamp 到文件尾（§13.3）----
    if (ctx.data.items.len > 0) {
        const file_size = try reader.size();
        for (ctx.data.items) |*seg| {
            if (seg.offset + seg.size > file_size) seg.size = file_size -| seg.offset;
        }
        ctx.data_bytes = 0;
        for (ctx.data.items) |seg| ctx.data_bytes += seg.size;
    }

    // 接管 reader（此后 readData 等按 ctx.reader 定位读取）
    ctx.reader = reader.*;

    // SWF：nbits = 数据区首字节高 2 位 + 2（adpcm.c 1377），blockFrames 依赖，
    // 须在 buildInfo 前读取（position_bytes 此时为 0）
    if (fmt.codec == .adpcm_swf and ctx.data_bytes > 0) {
        var fb: [1]u8 = undefined;
        const rn = try readData(ctx, &fb);
        if (rn == 0) return error.Corrupt;
        ctx.swf_nbits = (fb[0] >> 6) + 2;
        // 位流游标从首 2-bit nbits 字段之后起算（adpcm.c 1376-1377）
        ctx.swf_bitpos = 2;
    }

    // ---- Info ----
    info.* = buildInfo(ctx);

    return .{ .vtable = &vtable, .ctx = @ptrCast(ctx) };
}

/// 容器探测：返回 (容器, 样本字节序, is_aifc)。
/// `aiff` 时的字节序在 COMM 解析后可能被 "sowt" 覆盖；`caf` 样本字节序在
/// `desc` 解析后可能被 lpcm flags 0x2（little-endian）覆盖。
fn detectContainer(head: []const u8) Error!struct { Container, std.builtin.Endian, bool } {
    if (head.len >= 4) {
        if (std.mem.eql(u8, head[0..4], "caff")) return .{ .caf, .big, false };
        if (std.mem.eql(u8, head[0..4], ".snd")) return .{ .au, .big, false };
        if (std.mem.eql(u8, head[0..4], "RIFF") or
            std.mem.eql(u8, head[0..4], "RF64"))
        {
            return .{ .riff, .little, false };
        }
        if (std.mem.eql(u8, head[0..4], "RIFX")) return .{ .riff, .big, false };
        if (head.len >= 16 and std.mem.eql(u8, head[0..16], &chunk.riff_guid)) return .{ .w64, .little, false };
        if (std.mem.eql(u8, head[0..4], "FORM")) {
            if (head.len >= 12 and std.mem.eql(u8, head[8..12], "AIFF")) return .{ .aiff, .big, false };
            if (head.len >= 12 and std.mem.eql(u8, head[8..12], "AIFC")) return .{ .aiff, .big, true };
        }
    }
    return error.UnsupportedFormat;
}

// ---- Apple CAF / Sun AU（未压缩 PCM 容器，与 RIFF 家族共用 readPcm/DataSeg）----

/// CAF 未压缩 PCM（'lpcm'）帧头信息：样本字节序由 desc format flags 决定。
const CafPcm = struct {
    fmt: decl.WavFmt,
    /// 容器 `data` chunk 内的 4 字节 edit count 之后即原始样本
    is_le: bool,
};

/// CAF 魔数后 8 字节：version u16 BE（须 1）+ file flags u16 BE。
/// 随后 chunk 须为 `desc`（size == 32），逐字段镜像 FFmpeg cafdec.c read_desc_chunk：
///   mSampleRate    f64（8 字节 IEEE754 大端）
///   mFormatID      4 字符码（文件内按大端顺序，"lpcm"）
///   mFormatFlags   u32 BE（0x1 = float，0x2 = little-endian，0x4 = signed integer）
///   mBytesPerPacket / mFramesPerPacket / mChannelsPerFrame / mBitsPerChannel（均 u32 BE）
/// 仅支持 `lpcm` 定长包（frames_per_packet == 1）整数/float；其余 codec → UnsupportedFormat。
fn parseCafDesc(reader: *io.Reader) Error!CafPcm {
    var d: [32]u8 = undefined;
    if (!try readExact(reader, &d)) return error.Corrupt;

    // mSampleRate：u64 BE 位模式 → f64（av_int2double 语义）
    const rate_f: f64 = @bitCast(readU64(d[0..8], .big));
    if (!(rate_f > 0.0) or rate_f > 4_000_000.0) return error.Corrupt;
    const sample_rate: u32 = @intFromFloat(rate_f);

    if (!std.mem.eql(u8, d[8..12], "lpcm")) return error.UnsupportedFormat;
    const flags = readU32(d[12..16], .big);
    const bytes_per_packet = readU32(d[16..20], .big);
    const frames_per_packet = readU32(d[20..24], .big);
    const channels = readU32(d[24..28], .big);
    const bits = readU32(d[28..32], .big);

    // 未压缩 lpcm 恒为定长包（帧 = 1 样本/声道）；0/可变 → 需 pakt 表（压缩/复杂）
    if (bytes_per_packet == 0 or frames_per_packet != 1) return error.UnsupportedFormat;
    if (channels < 1 or channels > 8) return error.Corrupt;
    if (bits > 64 or (bits != 8 and bits != 16 and bits != 24 and bits != 32 and bits != 64)) {
        return error.UnsupportedFormat;
    }

    const is_le = (flags & 0x2) != 0;
    const is_float = (flags & 0x1) != 0;
    // 镜像 ffmpeg：CAF lpcm 整数恒按有符号解码（cafdec.c (flags ^ 0x2) | 0x4）
    const codec: decl.Codec = if (is_float)
        switch (bits) {
            32, 64 => .pcm_float,
            else => return error.UnsupportedFormat,
        }
    else switch (bits) {
        8, 16, 24, 32, 64 => .pcm_int,
        else => return error.UnsupportedFormat,
    };

    const fmt = decl.WavFmt{
        .codec = codec,
        .channels = @intCast(channels),
        .sample_rate = sample_rate,
        .bits = @intCast(bits),
        // 帧字节 = 样本宽 × 声道（ffmpeg cafenc 写入的 bytes_per_packet 即此值）
        .block_align = @as(usize, @intCast(channels)) * @as(usize, bits / 8),
    };
    try decl.validate(fmt);
    return .{ .fmt = fmt, .is_le = is_le };
}

/// 打开 Apple CAF：文件头 8B + `desc`(强制首 chunk) + 其余 chunk 扫描至 `data`。
/// `desc` 之后为 chan/info/kuki/pakt/free 等，逐一按 id(4)+size(8 BE) 无 pad 跳过。
fn openCaf(
    ctx: *WavCtx,
    reader: *io.Reader,
    info: *decoder.Info,
) Error!decoder.Decoder {
    var fh: [8]u8 = undefined;
    if (!try readExact(reader, &fh)) return error.Corrupt;
    if (!std.mem.eql(u8, fh[0..4], "caff")) return error.Corrupt;

    // desc 必须紧随文件头（镜像 FFmpeg cafdec read_header）
    var dh: [12]u8 = undefined;
    if (!try readExact(reader, &dh)) return error.Corrupt;
    if (!std.mem.eql(u8, dh[0..4], "desc")) return error.Corrupt;
    if (readU64(dh[4..12], .big) != 32) return error.Corrupt;
    const pcm = try parseCafDesc(reader);
    if (pcm.is_le) ctx.endian = .little;

    // 扫描剩余 chunk 直至 `data`（含 4B edit count 后为原始样本）
    var found = false;
    var seen: u32 = 0;
    while (seen < max_chunks) : (seen += 1) {
        var h: [12]u8 = undefined;
        if (!try readExact(reader, &h)) break; // 截断/EOF（已拿到 desc）
        const id = h[0..4].*;
        const size = readU64(h[4..12], .big);
        if (std.mem.eql(u8, &id, "data")) {
            if (size < 4) return error.Corrupt;
            var ec: [4]u8 = undefined;
            if (!try readExact(reader, &ec)) return error.Corrupt;
            // data chunk：edit count(4) + 原始样本；size 未知（-1）时由文件尾 clamp
            const data_size: u64 = if (size == 0xFFFF_FFFF_FFFF_FFFF)
                (try reader.size()) -| reader.pos
            else
                size - 4;
            try addSeg(ctx, reader.pos, data_size);
            found = true;
            break;
        }
        // chan / info / pakt / free 等：跳过 payload（CAF 无对齐 pad）
        try reader.seek(@intCast(size), .current);
    }

    return finishPcm(ctx, reader, pcm.fmt, found, info);
}

/// AU 未压缩 PCM encoding（镜像 FFmpeg au.c codec_au_tags；非 PCM → Unsupported）
const AuCodec = struct { codec: decl.Codec, bits: u16 };

fn auCodec(encoding: u32) Error!AuCodec {
    return switch (encoding) {
        2 => .{ .codec = .pcm_int, .bits = 8 }, // PCM_S8
        3 => .{ .codec = .pcm_int, .bits = 16 }, // PCM_S16BE
        4 => .{ .codec = .pcm_int, .bits = 24 }, // PCM_S24BE
        5 => .{ .codec = .pcm_int, .bits = 32 }, // PCM_S32BE
        6 => .{ .codec = .pcm_float, .bits = 32 }, // PCM_F32BE
        7 => .{ .codec = .pcm_float, .bits = 64 }, // PCM_F64BE
        // 1 = mu-law、27 = A-LAW、23..26 = G.726 等非未压缩 PCM → FFmpeg
        else => error.UnsupportedFormat,
    };
}

/// 打开 Sun AU：`.snd` + 固定头（24B 字段）→ 数据定位于 data_offset。
/// 镜像 FFmpeg au.c au_read_header：data_size 可为 0xFFFFFFFF（未知，取至文件尾）。
fn openAu(
    ctx: *WavCtx,
    reader: *io.Reader,
    info: *decoder.Info,
) Error!decoder.Decoder {
    var hdr: [24]u8 = undefined;
    if (!try readExact(reader, &hdr)) return error.Corrupt;
    if (!std.mem.eql(u8, hdr[0..4], ".snd")) return error.Corrupt;

    const data_offset = readU32(hdr[4..8], .big);
    const data_size = readU32(hdr[8..12], .big);
    const encoding = readU32(hdr[12..16], .big);
    const rate = readU32(hdr[16..20], .big);
    const channels = readU32(hdr[20..24], .big);

    if (data_offset < 24) return error.Corrupt;
    if (channels < 1 or channels > 8) return error.Corrupt;
    if (rate < 1 or rate > 4_000_000) return error.Corrupt;

    const ac = try auCodec(encoding);
    const block_align: usize = @as(usize, channels) * @as(usize, ac.bits / 8);
    const fmt = decl.WavFmt{
        .codec = ac.codec,
        .channels = @intCast(channels),
        .sample_rate = rate,
        .bits = ac.bits,
        .block_align = block_align,
    };
    try decl.validate(fmt);

    // 数据定位：data_offset（= 24B 头 + annotation，8 对齐）；越界由尾部 clamp
    const dsize: u64 = if (data_size == 0xFFFF_FFFF)
        (try reader.size()) -| data_offset
    else
        data_size;
    try addSeg(ctx, data_offset, dsize);

    return finishPcm(ctx, reader, fmt, dsize > 0, info);
}

/// CAF/AU 共用收尾：无 chunk 扫描的 PCM 容器（定长帧、无压缩），
/// 设置 codec 字段 → data 段 clamp → 接管 reader → buildInfo。
fn finishPcm(
    ctx: *WavCtx,
    reader: *io.Reader,
    fmt: decl.WavFmt,
    data_found: bool,
    info: *decoder.Info,
) Error!decoder.Decoder {
    ctx.codec = fmt.codec;
    ctx.channels = @intCast(fmt.channels);
    ctx.sample_rate = fmt.sample_rate;
    ctx.block_align = fmt.block_align;
    // 原生位深（未压缩 PCM 直出；float 亦保持 32/64）
    ctx.bits_per_sample = @intCast(fmt.bits);
    if (!data_found) ctx.data_bytes = 0;

    // data 段 clamp 到文件尾（§13.3）
    if (ctx.data.items.len > 0) {
        const file_size = try reader.size();
        for (ctx.data.items) |*seg| {
            if (seg.offset + seg.size > file_size) seg.size = file_size -| seg.offset;
        }
        ctx.data_bytes = 0;
        for (ctx.data.items) |seg| ctx.data_bytes += seg.size;
    }

    ctx.reader = reader.*;
    info.* = buildInfo(ctx);
    return .{ .vtable = &vtable, .ctx = @ptrCast(ctx) };
}

/// 追加数据段（size == 0 忽略）
fn addSeg(w: *WavCtx, offset: u64, size: u64) Error!void {
    if (size == 0) return;
    try w.data.append(w.allocator, .{ .offset = offset, .size = size });
    w.data_bytes += size;
}

// ---- Info ----

/// 连续流 codec：无块头，每字节 2 帧（2 样本/通道），解码状态跨调用保持（seek 时重置）
fn isContinuous(ctx: *WavCtx) bool {
    return switch (ctx.codec) {
        .adpcm_oki, .adpcm_yamaha, .adpcm_ct, .adpcm_g722 => true,
        else => false,
    };
}

/// 每块样本数（PCM/G.711 = 1 帧/块；块式 ADPCM = 块内样本数；连续流 = 每字节 2 帧；
/// GSM = WAV GSM_MS 每块 2 帧 320 样本 / AIFF 纯 GSM 每块 1 帧 160 样本）
fn samplesPerBlock(ctx: *WavCtx) usize {
    return switch (ctx.codec) {
        .adpcm_ms => adpcm.msSamplesPerBlock(ctx.block_align, ctx.channels),
        .adpcm_ima => adpcm.imaSamplesPerBlock(ctx.block_align, ctx.channels),
        .adpcm_dk4 => adpcm.dk4SamplesPerBlock(ctx.block_align, ctx.channels),
        .adpcm_dk3 => adpcm.dk3SamplesPerBlock(ctx.block_align, ctx.channels),
        .adpcm_xbox => adpcm.xboxSamplesPerBlock(ctx.block_align, ctx.channels),
        .adpcm_sanyo => ctx.sanyo_samples_per_block,
        .adpcm_ima_qt => 64,
        .adpcm_oki, .adpcm_yamaha, .adpcm_ct => 2, // 每字节 2 帧
        .adpcm_g722 => 2, // 每字节 2 帧（mono）
        .adpcm_g726 => 8 / ctx.g726.code_size, // 每字节样本数（mono，整字节）
        // XAN：每块 block_align 字节 = 2B/通道头 + (block_align - 2*ch) 交错样本
        .xan => (ctx.block_align - 2 * ctx.channels) / ctx.channels,
        .gsm => if (ctx.container == .aiff) gsm.frame_size else gsm.ms_frame_size,
        .mace3, .mace6 => mace.samples_per_block, // 每块 6 样本/声道（两种压缩比一致）
        else => 1,
    };
}

/// 数据区总帧数（对齐块/帧；尾部不完整块忽略；连续流 = 字节数×2/声道数）
fn blockFrames(ctx: *WavCtx) u64 {
    // ZORK：每字节 1 交错样本 → 每帧 channels 字节（adpcm.c 1425-1427）
    if (ctx.codec == .adpcm_zork) return ctx.data_bytes / ctx.channels;
    // SWF：位流样本数公式（adpcm.c 1374-1385，nbits 已由 open 读取）
    if (ctx.codec == .adpcm_swf) return adpcm.swfNbSamples(ctx.data_bytes, ctx.channels, ctx.swf_nbits);
    // G.726：每样本 code_size 位（riffdec.c 254-256；包尾残位忽略）
    if (ctx.codec == .adpcm_g726) return ctx.data_bytes * 8 / ctx.g726.code_size;
    if (isContinuous(ctx)) return ctx.data_bytes * 2 / ctx.channels;
    const blocks = ctx.data_bytes / ctx.block_align;
    return @as(u64, blocks) * samplesPerBlock(ctx);
}

fn buildInfo(ctx: *WavCtx) decoder.Info {
    // fact 帧数优先（压缩类文件常用），否则按字节/块推算
    const frames: u64 = if (ctx.fact_frames) |ff|
        if (ff > 0) ff else blockFrames(ctx)
    else
        blockFrames(ctx);
    const duration_us: i64 = @intCast((@as(u128, frames) * 1_000_000) / ctx.sample_rate);
    return .{
        .sample_rate = ctx.sample_rate,
        .channels = ctx.channels,
        .bits_per_sample = ctx.bits_per_sample,
        .is_float = ctx.codec == .pcm_float or ctx.codec == .pcm_f16 or ctx.codec == .pcm_f24,
        .duration_us = duration_us,
        .duration_known = .exact,
        .codec_name = codecName(ctx),
        .format_name = formatName(ctx.container),
        .metadata = ctx.meta,
        .loops = ctx.loops,
        .cue_points = ctx.cue_points,
    };
}

/// 容器名（供 Info.format_name 与 C ABI）
pub fn formatName(container: Container) [:0]const u8 {
    return switch (container) {
        .riff => "wav",
        .w64 => "w64",
        .aiff => "aiff",
        .caf => "caf",
        .au => "au",
    };
}

/// 编码器名（对齐 FFmpeg 命名）。8-bit 语义依容器/tag：
///   WAV/W64 8-bit = unsigned（pcm_u8）；AIFF "NONE"/"in24"… = signed（pcm_s8）；
///   AIFC "raw " = unsigned；CAF / AU 8-bit = signed（pcm_s8，镜像 FFmpeg cafdec/au）。
fn codecName(ctx: *WavCtx) [:0]const u8 {
    const be = ctx.endian == .big;
    switch (ctx.codec) {
        .alaw => return "pcm_alaw",
        .mulaw => return "pcm_mulaw",
        .adpcm_ms => return "adpcm_ms",
        .adpcm_ima => return "adpcm_ima_wav",
        .adpcm_ima_qt => return "adpcm_ima_qt",
        .adpcm_oki => return "adpcm_ima_oki",
        .adpcm_yamaha => return "adpcm_yamaha",
        .adpcm_ct => return "adpcm_ct",
        .adpcm_dk4 => return "adpcm_ima_dk4",
        .adpcm_dk3 => return "adpcm_ima_dk3",
        .adpcm_xbox => return "adpcm_ima_xbox",
        .adpcm_sanyo => return "adpcm_sanyo",
        .xan => return "xan_dpcm",
        .adpcm_zork => return "adpcm_zork",
        .adpcm_swf => return "adpcm_swf",
        .adpcm_g722 => return "adpcm_g722",
        .adpcm_g726 => return "adpcm_g726",
        .gsm => return if (ctx.container == .aiff) "gsm" else "gsm_ms",
        .mace3 => return "mace3",
        .mace6 => return "mace6",
        .pcm_float => return switch (ctx.bits_per_sample) {
            16 => if (be) "pcm_f16be" else "pcm_f16le",
            32 => if (be) "pcm_f32be" else "pcm_f32le",
            64 => if (be) "pcm_f64be" else "pcm_f64le",
            else => "pcm_float",
        },
        // F16LE/F24LE（4 字节槽位变体，仅 little-endian；镜像 FFmpeg 命名）
        .pcm_f16 => return "pcm_f16le",
        .pcm_f24 => return "pcm_f24le",
        .pcm_int => {
            if (ctx.bits_per_sample == 8) {
                // AIFF 非 "raw "、CAF、AU 的 8-bit 为有符号；WAV/W64、AIFC-"raw " 无符号
                const unsigned = switch (ctx.container) {
                    .riff, .w64 => true,
                    .aiff => std.mem.eql(u8, &ctx.aiff_tag, "raw "),
                    .caf, .au => false,
                };
                return if (unsigned) "pcm_u8" else "pcm_s8";
            }
            const b = ctx.bits_per_sample;
            return switch (b) {
                16 => if (be) "pcm_s16be" else "pcm_s16le",
                24 => if (be) "pcm_s24be" else "pcm_s24le",
                32 => if (be) "pcm_s32be" else "pcm_s32le",
                64 => if (be) "pcm_s64be" else "pcm_s64le",
                else => "pcm",
            };
        },
    }
}

// ---- VTable 实现 ----

fn readImpl(ctx: *anyopaque, out: []u8, max_samples: usize, out_channels: *u8) Error!usize {
    const w: *WavCtx = @ptrCast(@alignCast(ctx));
    out_channels.* = w.channels;
    if (max_samples == 0 or out.len == 0) return 0;
    return switch (w.codec) {
        .alaw, .mulaw => readG711(w, out, max_samples),
        .adpcm_ms, .adpcm_ima, .adpcm_ima_qt, .adpcm_dk4, .adpcm_dk3, .adpcm_xbox, .adpcm_sanyo => readAdpcm(w, out, max_samples),
        .adpcm_oki, .adpcm_yamaha, .adpcm_ct => readContinuous(w, out, max_samples),
        .adpcm_zork => readZork(w, out, max_samples),
        .adpcm_swf => readSwf(w, out, max_samples),
        .adpcm_g722 => readG722(w, out, max_samples),
        .adpcm_g726 => readG726(w, out, max_samples),
        .gsm => readGsm(w, out, max_samples),
        .mace3, .mace6 => readMace(w, out, max_samples),
        .xan => readXan(w, out, max_samples),
        else => readPcm(w, out, max_samples),
    };
}

fn readPcm(w: *WavCtx, out: []u8, max_samples: usize) Error!usize {
    const max_bytes = @min(out.len, max_samples * w.block_align);
    const remaining = w.data_bytes -| w.position_bytes;
    // 对齐到整帧（尾部不完整帧忽略）
    const want = @min(max_bytes, remaining) / w.block_align * w.block_align;
    if (want == 0) return 0;
    const n = try readData(w, out[0..want]);
    w.position_bytes += n;
    // F16/F24：4 字节槽位 le32（float32 位模式）× 2^-(bits-1)，原地转换
    // （镜像 FFmpeg pcm.c DECODE(32, le32) + vector_fmul_scalar，613-619 行）
    if (w.codec == .pcm_f16 or w.codec == .pcm_f24) {
        const coded_bits: u8 = if (w.codec == .pcm_f16) 16 else 24;
        const scale: f32 = 1.0 / @as(f32, @floatFromInt(@as(i32, 1) << @intCast(coded_bits - 1)));
        const samples = n / 4;
        for (0..samples) |i| {
            const v: f32 = @bitCast(std.mem.readInt(u32, out[i * 4 ..][0..4], .little));
            std.mem.writeInt(u32, out[i * 4 ..][0..4], @bitCast(v * scale), .little);
        }
    }
    return n / w.block_align;
}

fn readG711(w: *WavCtx, out: []u8, max_samples: usize) Error!usize {
    // 输出 s16（LE）：每输入字节 → 1 个 s16；帧 = channels 字节
    const out_cap = (out.len / 2) / w.channels * w.channels; // 输出样本数对齐到整帧
    const max_bytes = @min(max_samples * w.block_align, out_cap);
    const remaining = w.data_bytes -| w.position_bytes;
    const want = @min(max_bytes, remaining) / w.block_align * w.block_align;
    if (want == 0) return 0;

    if (w.dec_buf.len < want) {
        w.dec_buf = w.allocator.realloc(w.dec_buf, want) catch return error.OutOfMemory;
    }
    const n = try readData(w, w.dec_buf[0..want]);
    w.position_bytes += n;

    const samples = n / w.channels;
    for (0..n) |i| {
        const v: i16 = switch (w.codec) {
            .alaw => g711.alawDecode(w.dec_buf[i]),
            .mulaw => g711.mulawDecode(w.dec_buf[i]),
            else => unreachable,
        };
        std.mem.writeInt(i16, @ptrCast(&out[2 * i]), v, .little);
    }
    return samples;
}

fn readAdpcm(w: *WavCtx, out: []u8, max_samples: usize) Error!usize {
    const spb = samplesPerBlock(w); // 每通道每块样本数
    const block_samples = spb * w.channels; // 交错样本数
    const block_out_bytes = block_samples * 2;
    const max_bytes = @min(out.len, max_samples * 2 * w.channels);
    const remaining = w.data_bytes -| w.position_bytes;
    const blocks = remaining / w.block_align;
    if (blocks == 0 or max_bytes == 0) return 0;
    // 输出按整块对齐（尾部不完整块忽略）
    const out_blocks = @min(blocks, max_bytes / block_out_bytes);
    if (out_blocks == 0) return 0;

    if (w.dec_buf.len < block_out_bytes) {
        w.dec_buf = w.allocator.realloc(w.dec_buf, block_out_bytes) catch return error.OutOfMemory;
    }
    if (w.blk_buf.len < w.block_align) {
        w.blk_buf = w.allocator.realloc(w.blk_buf, w.block_align) catch return error.OutOfMemory;
    }
    const raw: []i16 = @ptrCast(@alignCast(w.dec_buf[0..block_out_bytes]));

    var produced: usize = 0;
    var blk: usize = 0;
    while (blk < out_blocks) : (blk += 1) {
        const n = try readData(w, w.blk_buf[0..w.block_align]);
        if (n < w.block_align) break; // 尾部残缺块：忽略
        w.position_bytes += n;
        switch (w.codec) {
            .adpcm_ms => try adpcm.decodeMs(w.blk_buf[0..n], w.channels, spb, raw),
            .adpcm_ima => try adpcm.decodeImaWav(w.blk_buf[0..n], w.channels, spb, raw),
            .adpcm_ima_qt => try adpcm.decodeImaQt(&w.cont, w.blk_buf[0..n], w.channels, raw),
            .adpcm_dk4 => try adpcm.decodeDk4(w.blk_buf[0..n], w.channels, spb, raw),
            .adpcm_dk3 => try adpcm.decodeDk3(w.blk_buf[0..n], w.channels, spb, raw),
            .adpcm_xbox => try adpcm.decodeXbox(w.blk_buf[0..n], w.channels, spb, raw),
            .adpcm_sanyo => try adpcm.decodeSanyo(&w.cont, w.blk_buf[0..n], w.channels, w.sanyo_bits, spb, raw),
            else => unreachable,
        }
        @memcpy(out[produced .. produced + block_out_bytes], w.dec_buf[0..block_out_bytes]);
        produced += block_out_bytes;
    }
    return produced / (2 * w.channels);
}

/// GSM 块式解码（仿 readAdpcm 的整块循环）：
///   WAV GSM_MS（tag 0x31/0x32/0x1500）：每块 block_align(41..65) 字节 → 320 样本；
///   AIFF-C "GSM "：每块 33 字节 → 160 样本。
/// 解码状态 w.gsm_ctx 跨块/跨 read 调用保持（ref_buf 滞后回溯依赖前帧尾）。
fn readGsm(w: *WavCtx, out: []u8, max_samples: usize) Error!usize {
    const block_samples = samplesPerBlock(w); // 每块交错样本数（mono）
    const block_out_bytes = block_samples * 2;
    const max_bytes = @min(out.len, max_samples * 2 * w.channels);
    const remaining = w.data_bytes -| w.position_bytes;
    const blocks = remaining / w.block_align;
    if (blocks == 0 or max_bytes == 0) return 0;
    // 输出按整块对齐（尾部不完整块忽略）
    const out_blocks = @min(blocks, max_bytes / block_out_bytes);
    if (out_blocks == 0) return 0;

    if (w.dec_buf.len < block_out_bytes) {
        w.dec_buf = w.allocator.realloc(w.dec_buf, block_out_bytes) catch return error.OutOfMemory;
    }
    if (w.blk_buf.len < w.block_align) {
        w.blk_buf = w.allocator.realloc(w.blk_buf, w.block_align) catch return error.OutOfMemory;
    }
    const raw: []i16 = @ptrCast(@alignCast(w.dec_buf[0..block_out_bytes]));

    var produced: usize = 0;
    var blk: usize = 0;
    while (blk < out_blocks) : (blk += 1) {
        const n = try readData(w, w.blk_buf[0..w.block_align]);
        if (n < w.block_align) break; // 尾部残缺块：忽略
        w.position_bytes += n;
        if (w.container == .aiff) {
            try gsm.decodeGsm(&w.gsm_ctx, w.blk_buf[0..n], raw);
        } else {
            try gsm.decodeGsmMs(&w.gsm_ctx, w.blk_buf[0..n], raw);
        }
        @memcpy(out[produced .. produced + block_out_bytes], w.dec_buf[0..block_out_bytes]);
        produced += block_out_bytes;
    }
    return produced / (2 * w.channels);
}

fn readMace(w: *WavCtx, out: []u8, max_samples: usize) Error!usize {
    const block_samples = samplesPerBlock(w); // 6 样本/声道
    const block_out_bytes = block_samples * 2 * w.channels;
    const max_bytes = @min(out.len, max_samples * 2 * w.channels);
    const remaining = w.data_bytes -| w.position_bytes;
    const blocks = remaining / w.block_align;
    if (blocks == 0 or max_bytes == 0) return 0;
    // 输出按整块对齐（尾部不完整块忽略）
    const out_blocks = @min(blocks, max_bytes / block_out_bytes);
    if (out_blocks == 0) return 0;

    if (w.dec_buf.len < block_out_bytes) {
        w.dec_buf = w.allocator.realloc(w.dec_buf, block_out_bytes) catch return error.OutOfMemory;
    }
    if (w.blk_buf.len < w.block_align) {
        w.blk_buf = w.allocator.realloc(w.blk_buf, w.block_align) catch return error.OutOfMemory;
    }
    const raw: []i16 = @ptrCast(@alignCast(w.dec_buf[0..block_out_bytes]));

    var produced: usize = 0;
    var blk: usize = 0;
    while (blk < out_blocks) : (blk += 1) {
        const n = try readData(w, w.blk_buf[0..w.block_align]);
        if (n < w.block_align) break; // 尾部残缺块：忽略
        w.position_bytes += n;
        mace.decodeBlock(&w.mace_ctx, w.blk_buf[0..n], w.channels, w.codec == .mace3, raw);
        @memcpy(out[produced .. produced + block_out_bytes], w.dec_buf[0..block_out_bytes]);
        produced += block_out_bytes;
    }
    return produced / (2 * w.channels);
}

/// XAN DPCM 块式解码（仿 readAdpcm 的整块循环）：
///   每块 block_align 字节 = 2B/通道 predictor 头 + 每字节 1 交错样本，
///   解码状态不跨块（shift 每块重置 {4,4}，镜像 FFmpeg dpcm.c）。
fn readXan(w: *WavCtx, out: []u8, max_samples: usize) Error!usize {
    const block_samples = samplesPerBlock(w) * w.channels; // 每块交错样本数
    const block_out_bytes = block_samples * 2;
    const max_bytes = @min(out.len, max_samples * 2 * w.channels);
    const remaining = w.data_bytes -| w.position_bytes;
    const blocks = remaining / w.block_align;
    if (blocks == 0 or max_bytes == 0) return 0;
    // 输出按整块对齐（尾部不完整块忽略）
    const out_blocks = @min(blocks, max_bytes / block_out_bytes);
    if (out_blocks == 0) return 0;

    if (w.dec_buf.len < block_out_bytes) {
        w.dec_buf = w.allocator.realloc(w.dec_buf, block_out_bytes) catch return error.OutOfMemory;
    }
    if (w.blk_buf.len < w.block_align) {
        w.blk_buf = w.allocator.realloc(w.blk_buf, w.block_align) catch return error.OutOfMemory;
    }
    const raw: []i16 = @ptrCast(@alignCast(w.dec_buf[0..block_out_bytes]));

    var produced: usize = 0;
    var blk: usize = 0;
    while (blk < out_blocks) : (blk += 1) {
        const n = try readData(w, w.blk_buf[0..w.block_align]);
        if (n < w.block_align) break; // 尾部残缺块：忽略
        w.position_bytes += n;
        dpcm.decodeXan(w.blk_buf[0..n], w.channels, raw);
        @memcpy(out[produced .. produced + block_out_bytes], w.dec_buf[0..block_out_bytes]);
        produced += block_out_bytes;
    }
    return produced / (2 * w.channels);
}

fn readContinuous(w: *WavCtx, out: []u8, max_samples: usize) Error!usize {
    // 连续流（OKI/Yamaha/CT）：无块头，每字节 → 2 交错样本（channels 声道交错输出）。
    // 每字节帧数 = 2 / channels（mono 2 帧、stereo 1 帧）；输出 s16 LE。
    // 解码状态 w.cont 跨调用保持。
    const out_cap = (out.len / 2) / w.channels * w.channels; // 输出样本数对齐整帧
    const max_frames = @min(max_samples, out_cap / w.channels);
    const remaining_frames = (w.data_bytes -| w.position_bytes) * 2 / w.channels;
    // 对齐字节边界：每字节 channels/2 帧，字节数 = 帧数×channels/2
    const want_bytes = @min(max_frames, remaining_frames) * w.channels / 2;
    if (want_bytes == 0) return 0;

    if (w.blk_buf.len < want_bytes) {
        w.blk_buf = w.allocator.realloc(w.blk_buf, want_bytes) catch return error.OutOfMemory;
    }
    const n = try readData(w, w.blk_buf[0..want_bytes]);
    w.position_bytes += n;
    if (n == 0) return 0;

    const frames = n * 2 / w.channels;
    const out_bytes = frames * w.channels * 2; // = n * 4
    if (w.dec_buf.len < out_bytes) {
        w.dec_buf = w.allocator.realloc(w.dec_buf, out_bytes) catch return error.OutOfMemory;
    }
    const raw: []i16 = @ptrCast(@alignCast(w.dec_buf[0..out_bytes]));
    switch (w.codec) {
        .adpcm_oki => adpcm.decodeOki(&w.cont, w.blk_buf[0..n], w.channels, raw),
        .adpcm_yamaha => adpcm.decodeYamaha(&w.cont, w.blk_buf[0..n], w.channels, raw),
        .adpcm_ct => adpcm.decodeCt(&w.cont, w.blk_buf[0..n], w.channels, raw),
        else => unreachable,
    }
    @memcpy(out[0..out_bytes], w.dec_buf[0..out_bytes]);
    return frames;
}

/// ZORK DPCM 连续流读取：每字节 → 1 交错样本（帧 = channels 字节），输出 s16 LE。
/// 解码状态 w.cont 跨 read 调用保持（seek 时重置）。
fn readZork(w: *WavCtx, out: []u8, max_samples: usize) Error!usize {
    const out_cap = (out.len / 2) / w.channels * w.channels; // 输出样本数对齐整帧
    const max_frames = @min(max_samples, out_cap / w.channels);
    const remaining_frames = (w.data_bytes -| w.position_bytes) / w.channels;
    const want_bytes = @min(max_frames, remaining_frames) * w.channels;
    if (want_bytes == 0) return 0;

    if (w.blk_buf.len < want_bytes) {
        w.blk_buf = w.allocator.realloc(w.blk_buf, want_bytes) catch return error.OutOfMemory;
    }
    const n = try readData(w, w.blk_buf[0..want_bytes]);
    w.position_bytes += n;
    if (n == 0) return 0;

    const out_bytes = n * 2; // n 样本 → n × s16
    if (w.dec_buf.len < out_bytes) {
        w.dec_buf = w.allocator.realloc(w.dec_buf, out_bytes) catch return error.OutOfMemory;
    }
    const raw: []i16 = @ptrCast(@alignCast(w.dec_buf[0..out_bytes]));
    adpcm.decodeZork(&w.cont, w.blk_buf[0..n], w.channels, raw);
    @memcpy(out[0..out_bytes], w.dec_buf[0..out_bytes]);
    return n / w.channels; // 帧数
}

/// SWF 位流按位读取（MSB-first，镜像 FFmpeg GetBitContext get_bits）：
/// 按需读取覆盖字节（position_bytes 每次读前定位）；越界补 0 不消费真实数据。
/// 消耗后推进 w.swf_bitpos（数据区起点起算的绝对位游标）。
fn readSwfBits(w: *WavCtx, n: u8) Error!u32 {
    var v: u32 = 0;
    var cached: u8 = 0;
    var cached_idx: u64 = std.math.maxInt(u64);
    for (0..n) |i| {
        const bit_abs = w.swf_bitpos + i;
        const byte_idx = bit_abs / 8;
        const bit_off: u3 = @intCast(7 - (bit_abs % 8)); // MSB-first
        if (byte_idx != cached_idx) {
            w.position_bytes = byte_idx;
            var b: [1]u8 = undefined;
            const r = try readData(w, &b);
            cached = if (r > 0) b[0] else 0;
            cached_idx = byte_idx;
        }
        v = (v << 1) | @as(u32, (cached >> bit_off) & 1);
    }
    w.swf_bitpos += n;
    return v;
}

/// SWF ADPCM 位流解码：数据区整体作为一条位流（首 2 bit = nbits 字段，随后循环
/// 块 = 22*ch bits 块头 + 至多 4095 轮 × nbits*ch bits 数据，每轮每通道 1 样本）。
/// 状态（w.cont + w.swf_*）跨 read 调用保持；输出 s16 LE；帧数 = 每通道样本数。
fn readSwf(w: *WavCtx, out: []u8, max_samples: usize) Error!usize {
    const ch = w.channels;
    const nbits = w.swf_nbits;
    if (nbits < 2 or nbits > 5 or w.data_bytes == 0) return 0;
    // 位流总位数（含首 2-bit nbits 字段，镜像 FFmpeg size = buf_size*8，adpcm.c 918）
    const data_bits = w.data_bytes * 8;

    const out_cap = (out.len / 2) / ch * ch; // 输出样本数对齐整帧
    const max_frames = @min(max_samples, out_cap / ch);
    if (max_frames == 0) return 0;

    const out_bytes = max_frames * ch * 2;
    if (w.dec_buf.len < out_bytes) {
        w.dec_buf = w.allocator.realloc(w.dec_buf, out_bytes) catch return error.OutOfMemory;
    }
    const raw: []i16 = @ptrCast(@alignCast(w.dec_buf[0..out_bytes]));

    var frame: usize = 0;
    while (frame < max_frames) {
        if (w.swf_block_count == 0) {
            // 块边界：剩余不足一块头（22*ch bits）则流结束
            if (data_bits -| w.swf_bitpos < 22 * ch) break;
            // 块头：每通道 16-bit 有符号 predictor + 6-bit step_index（即该块首样本）
            for (0..ch) |c| {
                const pred_u = try readSwfBits(w, 16);
                const pred: i16 = @bitCast(@as(u16, @intCast(pred_u)));
                const idx: i32 = @intCast(try readSwfBits(w, 6));
                w.cont.predictor[c] = pred;
                w.cont.step_index[c] = idx;
                raw[frame * ch + c] = pred;
            }
            w.swf_block_count = 1;
        } else {
            // 块内数据：剩余不足一轮（nbits*ch）或已达 4095 数据样本 → 块结束
            if (data_bits -| w.swf_bitpos < @as(u64, nbits) * ch or
                w.swf_block_count - 1 >= 4095)
            {
                w.swf_block_count = 0;
                continue;
            }
            for (0..ch) |c| {
                const delta = try readSwfBits(w, nbits);
                raw[frame * ch + c] = adpcm.swfExpandSample(&w.cont, c, delta, nbits);
            }
            w.swf_block_count += 1;
        }
        frame += 1;
    }

    w.swf_frames += frame;
    const produced = frame * ch * 2;
    @memcpy(out[0..produced], w.dec_buf[0..produced]);
    return frame;
}

/// G.722 连续流读取：每字节 → 2 帧（mono），输出 s16 LE。
/// 解码状态 w.g722 跨 read 调用保持（seek 时重置）。每字节独立解析
/// （高 2 位 ihigh + 低 6 位 ilow），不跨字节。
fn readG722(w: *WavCtx, out: []u8, max_samples: usize) Error!usize {
    const out_cap = (out.len / 2) / w.channels * w.channels; // 输出样本数对齐整帧（mono）
    const max_frames = @min(max_samples, out_cap / w.channels);
    const remaining_frames = (w.data_bytes -| w.position_bytes) * 2 / w.channels; // 每字节 2 帧
    const want_bytes = @min(max_frames, remaining_frames) * w.channels / 2;
    if (want_bytes == 0) return 0;

    if (w.blk_buf.len < want_bytes) {
        w.blk_buf = w.allocator.realloc(w.blk_buf, want_bytes) catch return error.OutOfMemory;
    }
    const n = try readData(w, w.blk_buf[0..want_bytes]);
    w.position_bytes += n;
    if (n == 0) return 0;

    const frames = n * 2 / w.channels;
    const out_bytes = frames * w.channels * 2;
    if (w.dec_buf.len < out_bytes) {
        w.dec_buf = w.allocator.realloc(w.dec_buf, out_bytes) catch return error.OutOfMemory;
    }
    const raw: []i16 = @ptrCast(@alignCast(w.dec_buf[0..out_bytes]));
    _ = adpcm.decodeG722(&w.g722, w.blk_buf[0..n], raw);
    @memcpy(out[0..out_bytes], w.dec_buf[0..out_bytes]);
    return frames;
}

/// G.726 连续位流读取：每样本 code_size 位 → 1 帧（mono），输出 s16 LE。
/// 解码状态 w.g726 跨 read 调用保持（seek 时重置）。按字节边界切包，包尾
/// 剩余不足 code_size 的残位丢弃（镜像 FFmpeg 每包独立 get_bits，g726.c 455-486）。
fn readG726(w: *WavCtx, out: []u8, max_samples: usize) Error!usize {
    const cs: u64 = w.g726.code_size; // 2..5（validate 保证）
    const out_cap = (out.len / 2) / w.channels * w.channels; // mono
    const max_frames = @min(max_samples, out_cap / w.channels);
    const remaining = w.data_bytes -| w.position_bytes;
    // 至多 max_frames 帧所需字节数（下取整保证 made <= max_frames，不越界）
    const want_bytes = @min(max_frames * cs / 8, remaining);
    if (want_bytes == 0) return 0;

    if (w.blk_buf.len < want_bytes) {
        w.blk_buf = w.allocator.realloc(w.blk_buf, want_bytes) catch return error.OutOfMemory;
    }
    const n = try readData(w, w.blk_buf[0..want_bytes]);
    w.position_bytes += n;
    if (n == 0) return 0;

    const frames = (n * 8) / cs; // 本包可解帧数（mono，包尾残位丢弃）
    const out_bytes = frames * 2;
    if (w.dec_buf.len < out_bytes) {
        w.dec_buf = w.allocator.realloc(w.dec_buf, out_bytes) catch return error.OutOfMemory;
    }
    const raw: []i16 = @ptrCast(@alignCast(w.dec_buf[0..out_bytes]));
    _ = adpcm.decodeG726(&w.g726, w.blk_buf[0..n], raw);
    @memcpy(out[0..out_bytes], w.dec_buf[0..out_bytes]);
    return frames;
}

fn seekMsImpl(ctx: *anyopaque, ms: i64) Error!void {
    const w: *WavCtx = @ptrCast(@alignCast(ctx));
    const total_frames = blockFrames(w);
    const frames: u64 = if (ms <= 0)
        0
    else
        @min((@as(u128, @intCast(ms)) * w.sample_rate) / 1000, total_frames);
    if (isContinuous(w)) {
        // 连续流：无块头、无法从中间跳入（状态须从头重训练）。
        // 镜像 FFmpeg flush+seek 语义：跳转到字节位置并重置解码状态。
        adpcm.resetCont(&w.cont, w.codec == .adpcm_ct);
        if (w.codec == .adpcm_g722) w.g722 = .{};
        w.position_bytes = frames * w.channels / 2; // 每字节 channels/2 帧
        return;
    }
    // G.726 连续位流：状态须从头重训练（镜像 FFmpeg g726_decode_flush）；
    // 字节位置按 code_size 位折算（包尾残位丢弃）
    if (w.codec == .adpcm_g726) {
        adpcm.g726Reset(&w.g726);
        w.position_bytes = frames * w.g726.code_size / 8;
        return;
    }
    // ZORK 连续流：每字节 1 样本（channels 字节/帧），状态跨调用保持，seek 后重置
    if (w.codec == .adpcm_zork) {
        adpcm.resetCont(&w.cont, false);
        w.position_bytes = frames * w.channels;
        return;
    }
    // SWF 位流：仅能定位到块边界（每块 4096 帧/通道），重置位流状态
    if (w.codec == .adpcm_swf) {
        const block_size: u64 = 22 * w.channels + @as(u64, w.swf_nbits) * w.channels * 4095;
        const blocks = frames / 4096;
        adpcm.resetCont(&w.cont, false);
        w.swf_bitpos = 2 + blocks * block_size;
        w.swf_block_count = 0;
        w.swf_frames = blocks * 4096;
        return;
    }
    // 对齐到块边界（PCM/G.711 每块 1 帧；ADPCM 按块样本数）
    const blocks = frames / samplesPerBlock(w);
    w.position_bytes = blocks * w.block_align;
    // IMA QT 启发式依赖上一块展开状态：seek 后须重置（镜像 FFmpeg flush）
    if (w.codec == .adpcm_ima_qt) adpcm.resetCont(&w.cont, false);
    // GSM 的 ref_buf/lar/msr 为流式状态：seek 后须清空（镜像 FFmpeg flush）
    if (w.codec == .gsm) w.gsm_ctx = .{};
    // MACE 的 index/factor/level 为流式状态：seek 后须清空（镜像 FFmpeg flush）
    if (w.codec == .mace3 or w.codec == .mace6) w.mace_ctx = .{};
    // Reader 位置无需同步：readData 每次读取前自行 seek
}

fn positionMsImpl(ctx: *anyopaque) i64 {
    const w: *WavCtx = @ptrCast(@alignCast(ctx));
    const frames: u64 = if (w.codec == .adpcm_swf)
        w.swf_frames
    else if (w.codec == .adpcm_zork)
        w.position_bytes / w.channels // 每字节 1 样本
    else if (isContinuous(w))
        w.position_bytes * 2 / w.channels // 每字节 2 样本
    else if (w.codec == .adpcm_g726)
        w.position_bytes * 8 / w.g726.code_size // 每样本 code_size 位
    else
        (w.position_bytes / w.block_align) * samplesPerBlock(w);
    return @intCast((@as(u128, frames) * 1000) / w.sample_rate);
}

fn deinitImpl(ctx: *anyopaque) void {
    const w: *WavCtx = @ptrCast(@alignCast(ctx));
    if (w.dec_buf.len > 0) w.allocator.free(w.dec_buf);
    if (w.blk_buf.len > 0) w.allocator.free(w.blk_buf);
    freeMeta(w.allocator, &w.meta);
    freeLoops(w.allocator, &w.loops, &w.cue_points);
    w.data.deinit(w.allocator);
    w.reader.deinit();
    w.allocator.destroy(w);
}

// ---- 标签元数据（LIST/INFO、AIFF NAME/AUTH/ANNO）----

/// 元数据字段（映射到 decoder.Metadata）
const MetaField = enum { title, artist, album, date, genre, comment };

/// 单字段文本上限（防畸形超大分配；标签正常远小于此）
const max_meta_text: u64 = 4096;

/// WAV LIST-INFO 子 chunk id → 元数据字段
fn infoFieldOf(id: [4]u8) ?MetaField {
    if (std.mem.eql(u8, &id, "INAM")) return .title;
    if (std.mem.eql(u8, &id, "IART")) return .artist;
    if (std.mem.eql(u8, &id, "IPRD")) return .album;
    if (std.mem.eql(u8, &id, "ICRD")) return .date;
    if (std.mem.eql(u8, &id, "IGNR")) return .genre;
    if (std.mem.eql(u8, &id, "ICMT")) return .comment;
    return null;
}

/// AIFF 标签 chunk id → 元数据字段
fn aiffFieldOf(id: [4]u8) ?MetaField {
    if (std.mem.eql(u8, &id, "NAME")) return .title;
    if (std.mem.eql(u8, &id, "AUTH")) return .artist;
    if (std.mem.eql(u8, &id, "ANNO")) return .comment;
    return null;
}

/// 解析 RIFF LIST-INFO 子列表（`total` = 不含 "INFO" 类型的 payload 字节数）。
/// 子 chunk = id(4) + size(4 LE) + payload + 奇对齐 pad；精确消费 `total` 字节
/// （截断/畸形时 seek 跳过剩余，保持 chunk 游标正确）。
fn parseInfoList(ctx: *WavCtx, reader: *io.Reader, total: u64) Error!void {
    var remaining = total;
    while (remaining >= 8) {
        // 容错读取子 chunk 头：文件截断时跳过剩余并停止（不报 Corrupt）
        var h: [8]u8 = [_]u8{0} ** 8;
        var got: usize = 0;
        while (got < 8) {
            const r = try reader.read(h[got..]);
            if (r == 0) break;
            got += r;
        }
        if (got < 8) {
            if (remaining > got) try reader.seek(@intCast(remaining - got), .current);
            return;
        }
        remaining -= 8;
        const size = readU32(h[4..8], .little);
        const payload = @min(@as(u64, size), remaining);
        try readTextField(ctx, infoFieldOf(h[0..4].*), reader, payload);
        remaining -= payload;
        // pad 仅当子 chunk 完整（payload == size）且 size 为奇数时物理存在
        if (payload == size and remaining > 0 and (size & 1) == 1) {
            try reader.seek(1, .current);
            remaining -= 1;
        }
    }
    // 尾部不足一个子 chunk 头：跳过（seek 越界无害，保持游标在 LIST 末尾）
    if (remaining > 0) try reader.seek(@intCast(remaining), .current);
}

/// 读取 `len` 字节文本写入元数据字段（长度 clamp、尾部清理、首字段优先）。
/// 精确消费 `len` 字节：超 `max_meta_text` 部分 seek 跳过。
fn readTextField(ctx: *WavCtx, field: ?MetaField, reader: *io.Reader, len: u64) Error!void {
    const n: usize = @intCast(@min(len, max_meta_text));
    if (field == null or n == 0) {
        if (len > 0) try reader.seek(@intCast(len), .current);
        return;
    }
    const buf = ctx.allocator.alloc(u8, n) catch return error.OutOfMemory;
    defer ctx.allocator.free(buf);
    var got: usize = 0;
    while (got < n) {
        const r = try reader.read(buf[got..]);
        if (r == 0) break;
        got += r;
    }
    if (len > got) try reader.seek(@intCast(len - got), .current);
    const trimmed = std.mem.trim(u8, buf[0..got], " \t\r\n\x00");
    if (trimmed.len == 0) return;
    const s = ctx.allocator.dupeZ(u8, trimmed) catch return error.OutOfMemory;
    setMeta(ctx, field.?, s);
}

/// 首次遇到才写入（同字段多出现时取第一个）
fn setMeta(ctx: *WavCtx, field: MetaField, s: [:0]const u8) void {
    switch (field) {
        .title => if (ctx.meta.title == null) {
            ctx.meta.title = s;
        },
        .artist => if (ctx.meta.artist == null) {
            ctx.meta.artist = s;
        },
        .album => if (ctx.meta.album == null) {
            ctx.meta.album = s;
        },
        .date => if (ctx.meta.date == null) {
            ctx.meta.date = s;
        },
        .genre => if (ctx.meta.genre == null) {
            ctx.meta.genre = s;
        },
        .comment => if (ctx.meta.comment == null) {
            ctx.meta.comment = s;
        },
    }
}

/// 释放 metadata 全部字段（open 失败 errdefer 与 deinit 共用）
fn freeMeta(allocator: std.mem.Allocator, meta: *decoder.Metadata) void {
    inline for (.{ &meta.title, &meta.artist, &meta.album, &meta.date, &meta.genre, &meta.comment }) |f| {
        if (f.*) |s| {
            allocator.free(s);
            f.* = null;
        }
    }
}

/// 释放采样循环点 / 提示点数组（open 失败 errdefer 与 deinit 共用）
fn freeLoops(allocator: std.mem.Allocator, loops: *[]decoder.LoopPoint, cues: *[]decoder.CuePoint) void {
    if (loops.len > 0) {
        allocator.free(loops.*);
        loops.* = &.{};
    }
    if (cues.len > 0) {
        allocator.free(cues.*);
        cues.* = &.{};
    }
}

/// 解析 RIFF `smpl` chunk（采样器循环点）。头 36B + 每循环 24B；
/// 条目数 clamp 到 chunk 实际承载（§13.3），文件截断时保留已解析条目。
fn parseSmpl(ctx: *WavCtx, reader: *io.Reader, c: chunk.Chunk) Error!void {
    if (c.size < 36) return skipRest(reader, c.size, c, .riff);
    var h: [36]u8 = undefined;
    if (!try readExact(reader, &h)) return error.Corrupt;
    const num_loops = readU32(h[28..32], ctx.endian); // numSampleLoops
    const avail: u64 = c.size - 36;
    const n: usize = @intCast(@min(@as(u64, num_loops), avail / 24));
    if (n > 0) {
        const loops = ctx.allocator.alloc(decoder.LoopPoint, n) catch return error.OutOfMemory;
        var got: usize = 0;
        while (got < n) : (got += 1) {
            var l: [24]u8 = undefined;
            if (!try readExact(reader, &l)) break; // 截断：保留已解析条目
            loops[got] = .{
                .type = readU32(l[4..8], ctx.endian),
                .start = readU32(l[8..12], ctx.endian),
                .end = readU32(l[12..16], ctx.endian),
                .play_count = readU32(l[20..24], ctx.endian),
            };
        }
        if (got < n) {
            ctx.loops = try ctx.allocator.realloc(loops, got);
        } else {
            ctx.loops = loops;
        }
    }
    try skipRest(reader, 36 + n * 24, c, .riff);
}

/// 解析 RIFF `cue ` chunk（提示点）。头 4B 计数 + 每点 24B；
/// 计数 clamp 到实际承载（§13.3），截断时保留已解析点。
fn parseCue(ctx: *WavCtx, reader: *io.Reader, c: chunk.Chunk) Error!void {
    if (c.size < 4) return skipRest(reader, c.size, c, .riff);
    var cnt_buf: [4]u8 = undefined;
    if (!try readExact(reader, &cnt_buf)) return error.Corrupt;
    const num = readU32(&cnt_buf, ctx.endian);
    const avail: u64 = c.size - 4;
    const n: usize = @intCast(@min(@as(u64, num), avail / 24));
    if (n > 0) {
        const cues = ctx.allocator.alloc(decoder.CuePoint, n) catch return error.OutOfMemory;
        var got: usize = 0;
        while (got < n) : (got += 1) {
            var p: [24]u8 = undefined;
            if (!try readExact(reader, &p)) break; // 截断：保留已解析点
            cues[got] = .{
                .id = readU32(p[0..4], ctx.endian),
                // position = 样本偏移（相对 data chunk 起点），即 cue 的 position 字段
                .position = readU32(p[4..8], ctx.endian),
            };
        }
        if (got < n) {
            ctx.cue_points = try ctx.allocator.realloc(cues, got);
        } else {
            ctx.cue_points = cues;
        }
    }
    try skipRest(reader, 4 + n * 24, c, .riff);
}

/// 从逻辑数据区读取（可能跨段），返回实际读到的字节数。
/// 每次读前 seek 到段内目标位置（positional read 无隐式状态，跨段安全）。
fn readData(w: *WavCtx, buf: []u8) Error!usize {
    var got: usize = 0;
    while (got < buf.len) {
        const loc = locateSeg(w, w.position_bytes + got);
        if (loc.avail == 0) break;
        const n = @min(buf.len - got, loc.avail);
        try w.reader.seek(@intCast(loc.offset + loc.rel), .start);
        const r = w.reader.read(buf[got .. got + n]) catch return error.IoError;
        if (r == 0) break;
        got += r;
    }
    return got;
}

const SegLoc = struct { offset: u64, rel: u64, avail: u64 };

/// 定位逻辑位置 pos 所在段及段内相对位置/剩余
fn locateSeg(w: *WavCtx, pos: u64) SegLoc {
    var acc: u64 = 0;
    for (w.data.items) |seg| {
        if (pos < acc + seg.size) return .{ .offset = seg.offset, .rel = pos - acc, .avail = seg.size - (pos - acc) };
        acc += seg.size;
    }
    // pos 越界（>= data_bytes）：返回空
    const last = w.data.items[w.data.items.len - 1];
    return .{ .offset = last.offset, .rel = last.size, .avail = 0 };
}

// ---- 基础 IO ----

fn readExact(reader: *io.Reader, buf: []u8) Error!bool {
    var got: usize = 0;
    while (got < buf.len) {
        const n = try reader.read(buf[got..]);
        if (n == 0) return false;
        got += n;
    }
    return true;
}

/// 解析函数已消费 `consumed` 字节 payload 后，跳过剩余 payload 与对齐 pad
/// （替代 `chunk.skipChunk` —— 后者会重复跳过整个 payload 造成错位）。
fn skipRest(reader: *io.Reader, consumed: u64, c: chunk.Chunk, container: Container) Error!void {
    const rest = c.size -| consumed;
    if (rest > 0) try reader.seek(@intCast(rest), .current);
    const pad: u64 = switch (container) {
        .riff, .aiff => c.size & 1,
        .w64 => (8 - (c.size % 8)) % 8,
        // CAF 无 pad（AU 无 chunk，不调用本函数）
        .caf, .au => 0,
    };
    if (pad > 0) try reader.seek(@intCast(pad), .current);
}

inline fn readU32(b: []const u8, endian: std.builtin.Endian) u32 {
    return std.mem.readInt(u32, b[0..4], endian);
}

inline fn readU64(b: []const u8, endian: std.builtin.Endian) u64 {
    return std.mem.readInt(u64, b[0..8], endian);
}

// ---------------------------------------------------------------------------
// 集成测试：open → read → 黄金样本（w5）
// ---------------------------------------------------------------------------
//
// 构造内存镜像（buildRiff / buildW64 / buildAiff），经 `open` 完整走
// 容器探测 → chunk 遍历 → Info 填充 → VTable read，逐字节比对输出。
// 覆盖：RIFF(u8/s16/f32) · RF64(ds64) · W64(多 data 段跨段读) ·
//       AIFF(大端 + 80-bit 采样率) · AIFC("sowt" 小端覆盖 / "ulaw" G.711) ·
//       seek/position · 畸形（未知 tag / AVI / 截断 data clamp / 缺 fmt）。

const testing = std.testing;

const RiffChunk = struct { id: [4]u8, payload: []const u8, size: ?u32 = null };

/// 构造 RIFF / RIFX / RF64 镜像：id + 4 字节 size（自动回填，`size` 可覆写）+ "WAVE"
fn buildRiff(allocator: std.mem.Allocator, riff_id: []const u8, endian: std.builtin.Endian, chunks: []const RiffChunk) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, riff_id);
    const size_pos = buf.items.len;
    try buf.appendSlice(allocator, &[_]u8{0} ** 4);
    try buf.appendSlice(allocator, "WAVE");
    for (chunks) |c| {
        try buf.appendSlice(allocator, &c.id);
        var sz: [4]u8 = undefined;
        std.mem.writeInt(u32, sz[0..4], c.size orelse @intCast(c.payload.len), endian);
        try buf.appendSlice(allocator, &sz);
        try buf.appendSlice(allocator, c.payload);
        if (c.payload.len & 1 == 1) try buf.appendSlice(allocator, &[_]u8{0});
    }
    std.mem.writeInt(u32, buf.items[size_pos..][0..4], @intCast(buf.items.len - 8), endian);
    return buf.toOwnedSlice(allocator);
}

const AiffChunk = struct { id: [4]u8, payload: []const u8 };

/// 构造 AIFF / AIFF-C 镜像（FORM + 大端 size 自动回填）
fn buildAiff(allocator: std.mem.Allocator, is_aifc: bool, chunks: []const AiffChunk) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "FORM");
    const size_pos = buf.items.len;
    try buf.appendSlice(allocator, &[_]u8{0} ** 4);
    try buf.appendSlice(allocator, if (is_aifc) "AIFC" else "AIFF");
    for (chunks) |c| {
        try buf.appendSlice(allocator, &c.id);
        var sz: [4]u8 = undefined;
        std.mem.writeInt(u32, sz[0..4], @intCast(c.payload.len), .big);
        try buf.appendSlice(allocator, &sz);
        try buf.appendSlice(allocator, c.payload);
        if (c.payload.len & 1 == 1) try buf.appendSlice(allocator, &[_]u8{0});
    }
    std.mem.writeInt(u32, buf.items[size_pos..][0..4], @intCast(buf.items.len - 8), .big);
    return buf.toOwnedSlice(allocator);
}

const W64Chunk = struct { guid: [16]u8, payload: []const u8 };

/// 构造 Sony Wave64 镜像（riff/wave GUID + 8 字节 size 含 24 头 + payload 8 对齐）
fn buildW64(allocator: std.mem.Allocator, chunks: []const W64Chunk) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, &chunk.riff_guid);
    const size_pos = buf.items.len;
    try buf.appendSlice(allocator, &[_]u8{0} ** 8);
    try buf.appendSlice(allocator, &chunk.wave_guid);
    for (chunks) |c| {
        try buf.appendSlice(allocator, &c.guid);
        var sz: [8]u8 = undefined;
        std.mem.writeInt(u64, sz[0..8], 24 + c.payload.len, .little);
        try buf.appendSlice(allocator, &sz);
        try buf.appendSlice(allocator, c.payload);
        const pad: usize = (8 - (c.payload.len % 8)) % 8;
        if (pad > 0) try buf.appendSlice(allocator, (&[_]u8{0} ** 7)[0..pad]);
    }
    std.mem.writeInt(u64, buf.items[size_pos..][0..8], @intCast(buf.items.len - 16), .little);
    return buf.toOwnedSlice(allocator);
}

/// 16 字节 WAVEFORMATEX
fn testFmt(tag: u16, channels: u16, rate: u32, byte_rate: u32, block_align: u16, bits: u16, endian: std.builtin.Endian) [16]u8 {
    var f: [16]u8 = undefined;
    std.mem.writeInt(u16, f[0..2], tag, endian);
    std.mem.writeInt(u16, f[2..4], channels, endian);
    std.mem.writeInt(u32, f[4..8], rate, endian);
    std.mem.writeInt(u32, f[8..12], byte_rate, endian);
    std.mem.writeInt(u16, f[12..14], block_align, endian);
    std.mem.writeInt(u16, f[14..16], bits, endian);
    return f;
}

/// 80-bit extended 采样率（BE）：V = mantissa << (63 - (e - 16383))
fn extended80(rate: u32) [10]u8 {
    var b: [10]u8 = undefined;
    var e: u6 = 0;
    while (@as(u64, 1) << e <= rate) : (e += 1) {}
    e -= 1; // 最高位指数
    std.mem.writeInt(u16, b[0..2], @as(u16, 16383) + e, .big);
    std.mem.writeInt(u64, b[2..10], @as(u64, rate) << (63 - e), .big);
    return b;
}

/// 打开内存镜像并返回解码器（调用方负责 deinit 与 free(file)）
fn openMem(allocator: std.mem.Allocator, file: []const u8, info: *decoder.Info) Error!decoder.Decoder {
    var reader = io.Reader.openMem(file);
    return open(allocator, &reader, info);
}

test "wav 集成: RIFF PCM s16 立体声" {
    const fmt = testFmt(1, 2, 44100, 176400, 4, 16, .little);
    var pcm: [16]u8 = undefined;
    const vals = [_]i16{ 1000, -1000, 2000, -2000, 3000, -3000, 4000, -4000 };
    for (vals, 0..) |v, i| std.mem.writeInt(i16, pcm[2 * i ..][0..2], v, .little);

    const file = try buildRiff(testing.allocator, "RIFF", .little, &.{
        .{ .id = "fmt ".*, .payload = &fmt },
        .{ .id = "data".*, .payload = &pcm },
    });
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();

    try testing.expectEqual(@as(u32, 44100), info.sample_rate);
    try testing.expectEqual(@as(u8, 2), info.channels);
    try testing.expectEqual(@as(u8, 16), info.bits_per_sample);
    try testing.expectEqual(false, info.is_float);
    try testing.expectEqualStrings("pcm_s16le", info.codec_name);
    try testing.expectEqualStrings("wav", info.format_name);
    try testing.expectEqual(@as(i64, 90), info.duration_us); // 4 帧 * 1e6 / 44100

    var out: [16]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectEqual(@as(usize, 2), try dec.read(&out, 2, &ch));
    try testing.expectEqual(@as(u8, 2), ch);
    try testing.expectEqualSlices(u8, pcm[0..8], out[0..8]);
    try testing.expectEqual(@as(usize, 2), try dec.read(&out, 2, &ch));
    try testing.expectEqualSlices(u8, pcm[8..16], out[0..8]);
    try testing.expectEqual(@as(usize, 0), try dec.read(&out, 2, &ch)); // EOF
}

test "wav 集成: RIFF PCM u8（8-bit 无符号）" {
    const fmt = testFmt(1, 1, 8000, 8000, 1, 8, .little);
    const pcm = [_]u8{ 128, 0, 255, 64 };
    const file = try buildRiff(testing.allocator, "RIFF", .little, &.{
        .{ .id = "fmt ".*, .payload = &fmt },
        .{ .id = "data".*, .payload = &pcm },
    });
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();
    try testing.expectEqualStrings("pcm_u8", info.codec_name);
    try testing.expectEqual(@as(i64, 500), info.duration_us); // 4 帧 @ 8kHz

    var out: [8]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectEqual(@as(usize, 4), try dec.read(&out, 8, &ch));
    try testing.expectEqualSlices(u8, &pcm, out[0..4]);
}

test "wav 集成: RIFF IEEE float f32 立体声" {
    const fmt = testFmt(3, 2, 48000, 384000, 8, 32, .little);
    var pcm: [16]u8 = undefined;
    const vals = [_]f32{ 0.5, -0.25, 1.0, -1.0 };
    for (vals, 0..) |v, i| std.mem.writeInt(u32, pcm[4 * i ..][0..4], @bitCast(v), .little);

    const file = try buildRiff(testing.allocator, "RIFF", .little, &.{
        .{ .id = "fmt ".*, .payload = &fmt },
        .{ .id = "data".*, .payload = &pcm },
    });
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();
    try testing.expectEqual(true, info.is_float);
    try testing.expectEqualStrings("pcm_f32le", info.codec_name);

    var out: [16]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectEqual(@as(usize, 1), try dec.read(&out, 1, &ch));
    try testing.expectEqualSlices(u8, pcm[0..8], out[0..8]);
    try testing.expectEqual(@as(usize, 1), try dec.read(&out, 1, &ch));
    try testing.expectEqualSlices(u8, pcm[8..16], out[0..8]);
    try testing.expectEqual(@as(usize, 0), try dec.read(&out, 1, &ch));
}

test "wav 集成: F24LE 解码（tag 1 + bits 24 + 4B 槽位 → f32 × 2^-23）" {
    // fmt: PCM tag 1 + bits 24 + block_align ch*4（F24LE 判定，镜像 wavdec 671-674）
    const fmt = testFmt(1, 2, 48000, 384000, 8, 24, .little);
    var pcm: [16]u8 = undefined;
    const raw = [_]u32{ 0x3F800000, 0x00000000, 0x40400000, 0xC0000000 }; // 1.0, 0.0, 3.0, -2.0
    for (raw, 0..) |v, i| std.mem.writeInt(u32, pcm[4 * i ..][0..4], v, .little);

    const file = try buildRiff(testing.allocator, "RIFF", .little, &.{
        .{ .id = "fmt ".*, .payload = &fmt },
        .{ .id = "data".*, .payload = &pcm },
    });
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();
    try testing.expectEqual(true, info.is_float);
    try testing.expectEqual(@as(u8, 32), info.bits_per_sample); // 输出 f32
    try testing.expectEqualStrings("pcm_f24le", info.codec_name);

    var out: [16]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectEqual(@as(usize, 2), try dec.read(&out, 2, &ch));
    // 期望：le32 × 2^-23（f32 原地缩放）
    var expect: [16]u8 = undefined;
    const scale: f32 = 1.0 / 8388608.0;
    for (raw, 0..) |v, i| {
        const x: f32 = @as(f32, @bitCast(v)) * scale;
        std.mem.writeInt(u32, expect[4 * i ..][0..4], @bitCast(x), .little);
    }
    try testing.expectEqualSlices(u8, &expect, &out);
    try testing.expectEqual(@as(usize, 0), try dec.read(&out, 2, &ch));
}

test "wav 集成: F16LE 解码（tag 1 + bits 32 + extradata [01 00] → f32 × 2^-15）" {
    // fmt: PCM tag 1 + bits 32 + block_align ch*4 + cbSize 2 + extradata [01 00]
    var fbuf: [20]u8 = undefined;
    const base = testFmt(1, 1, 48000, 192000, 4, 32, .little);
    @memcpy(fbuf[0..16], &base);
    std.mem.writeInt(u16, fbuf[16..18], 2, .little);
    @memcpy(fbuf[18..20], &[_]u8{ 1, 0 });
    var pcm: [8]u8 = undefined;
    const raw = [_]u32{ 0x3F800000, 0xC0000000 }; // 1.0, -2.0
    for (raw, 0..) |v, i| std.mem.writeInt(u32, pcm[4 * i ..][0..4], v, .little);

    const file = try buildRiff(testing.allocator, "RIFF", .little, &.{
        .{ .id = "fmt ".*, .payload = &fbuf },
        .{ .id = "data".*, .payload = &pcm },
    });
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();
    try testing.expectEqual(true, info.is_float);
    try testing.expectEqual(@as(u8, 32), info.bits_per_sample);
    try testing.expectEqualStrings("pcm_f16le", info.codec_name);

    var out: [8]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectEqual(@as(usize, 2), try dec.read(&out, 2, &ch));
    var expect: [8]u8 = undefined;
    const scale: f32 = 1.0 / 32768.0;
    for (raw, 0..) |v, i| {
        const x: f32 = @as(f32, @bitCast(v)) * scale;
        std.mem.writeInt(u32, expect[4 * i ..][0..4], @bitCast(x), .little);
    }
    try testing.expectEqualSlices(u8, &expect, &out);
    try testing.expectEqual(@as(usize, 0), try dec.read(&out, 2, &ch));
}

test "wav 集成: XAN DPCM 块解码（tag 0x594A）" {
    // fmt: tag 0x594A, mono, 8k, block_align 4（2B predictor 头 + 2B 数据）
    const fmt = testFmt(0x594A, 1, 8000, 16000, 4, 16, .little);
    // 块 1：predictor 100，数据 0x04, 0x83 → 164, -860
    // 块 2：predictor 0，数据 0x04, 0x04 → 64, 128
    var data: [8]u8 = undefined;
    std.mem.writeInt(u16, data[0..2], 100, .little);
    data[2] = 0x04;
    data[3] = 0x83;
    std.mem.writeInt(u16, data[4..6], 0, .little);
    data[6] = 0x04;
    data[7] = 0x04;

    const file = try buildRiff(testing.allocator, "RIFF", .little, &.{
        .{ .id = "fmt ".*, .payload = &fmt },
        .{ .id = "data".*, .payload = &data },
    });
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();
    try testing.expectEqual(@as(u8, 16), info.bits_per_sample);
    try testing.expectEqual(false, info.is_float);
    try testing.expectEqualStrings("xan_dpcm", info.codec_name);
    try testing.expectEqual(@as(i64, 500), info.duration_us); // 4 帧 @ 8kHz

    var out: [8]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectEqual(@as(usize, 4), try dec.read(&out, 4, &ch));
    var expect: [8]u8 = undefined;
    const vals = [_]i16{ 164, -860, 64, 128 };
    for (vals, 0..) |v, i| std.mem.writeInt(i16, expect[2 * i ..][0..2], v, .little);
    try testing.expectEqualSlices(u8, &expect, &out);
    try testing.expectEqual(@as(usize, 0), try dec.read(&out, 4, &ch));
}

test "wav 集成: W64 双 data 段跨段拼接读取" {
    const fmt = testFmt(1, 1, 8000, 16000, 2, 16, .little);
    var d1: [4]u8 = undefined; // 段 1：2 帧
    std.mem.writeInt(i16, d1[0..2], 100, .little);
    std.mem.writeInt(i16, d1[2..4], -200, .little);
    var d2: [4]u8 = undefined; // 段 2：2 帧
    std.mem.writeInt(i16, d2[0..2], 300, .little);
    std.mem.writeInt(i16, d2[2..4], -400, .little);

    const file = try buildW64(testing.allocator, &.{
        .{ .guid = chunk.fmt_guid, .payload = &fmt },
        .{ .guid = chunk.data_guid, .payload = &d1 },
        .{ .guid = chunk.data_guid, .payload = &d2 },
    });
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();
    try testing.expectEqualStrings("w64", info.format_name);
    try testing.expectEqualStrings("pcm_s16le", info.codec_name);
    try testing.expectEqual(@as(i64, 500), info.duration_us); // 4 帧 @ 8kHz

    // 一次读 3 帧：跨段（段 1 剩 2 帧 + 段 2 首 1 帧）
    var out: [6]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectEqual(@as(usize, 3), try dec.read(&out, 3, &ch));
    const expect1 = [_]u8{ 0x64, 0x00, 0x38, 0xFF, 0x2C, 0x01 }; // 100, -200, 300
    try testing.expectEqualSlices(u8, &expect1, &out);
    // 再读 1 帧：段 2 余量（read 仅写入返回帧数对应的字节）
    try testing.expectEqual(@as(usize, 1), try dec.read(&out, 3, &ch));
    const expect2 = [_]u8{ 0x70, 0xFE }; // -400
    try testing.expectEqualSlices(u8, &expect2, out[0..2]);
    try testing.expectEqual(@as(usize, 0), try dec.read(&out, 3, &ch));
}

test "wav 集成: RF64 ds64 大文件头" {
    const fmt = testFmt(1, 1, 8000, 16000, 2, 16, .little);
    var ds: [24]u8 = undefined; // riffSize(0) + dataSize(8) + sampleCount(4)
    std.mem.writeInt(u64, ds[0..8], 0, .little);
    std.mem.writeInt(u64, ds[8..16], 8, .little);
    std.mem.writeInt(u64, ds[16..24], 4, .little);
    var pcm: [8]u8 = undefined;
    std.mem.writeInt(i16, pcm[0..2], 100, .little);
    std.mem.writeInt(i16, pcm[2..4], -200, .little);
    std.mem.writeInt(i16, pcm[4..6], 300, .little);
    std.mem.writeInt(i16, pcm[6..8], -400, .little);

    const file = try buildRiff(testing.allocator, "RF64", .little, &.{
        .{ .id = "ds64".*, .payload = &ds },
        .{ .id = "fmt ".*, .payload = &fmt },
        .{ .id = "data".*, .payload = &pcm, .size = 0xFFFFFFFF }, // 用 ds64.dataSize
    });
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();
    try testing.expectEqual(@as(i64, 500), info.duration_us); // 4 帧 @ 8kHz

    var out: [8]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectEqual(@as(usize, 4), try dec.read(&out, 4, &ch));
    try testing.expectEqualSlices(u8, &pcm, &out);
}

test "wav 集成: AIFF 大端 PCM s16 + 80-bit 采样率" {
    var comm: [18]u8 = undefined;
    std.mem.writeInt(u16, comm[0..2], 1, .big); // channels
    std.mem.writeInt(u32, comm[2..6], 2, .big); // frames
    std.mem.writeInt(u16, comm[6..8], 16, .big); // bits
    const r80 = extended80(8000);
    @memcpy(comm[8..18], &r80);

    var ssnd: [12]u8 = undefined; // offset(0) + blockSize(0) + 2 帧 s16 BE
    std.mem.writeInt(u32, ssnd[0..4], 0, .big);
    std.mem.writeInt(u32, ssnd[4..8], 0, .big);
    std.mem.writeInt(i16, ssnd[8..10], 100, .big);
    std.mem.writeInt(i16, ssnd[10..12], -200, .big);

    const file = try buildAiff(testing.allocator, false, &.{
        .{ .id = "COMM".*, .payload = &comm },
        .{ .id = "SSND".*, .payload = &ssnd },
    });
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();
    try testing.expectEqual(@as(u32, 8000), info.sample_rate);
    try testing.expectEqualStrings("aiff", info.format_name);
    try testing.expectEqualStrings("pcm_s16be", info.codec_name);
    try testing.expectEqual(@as(i64, 250), info.duration_us); // 2 帧 @ 8kHz

    var out: [4]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectEqual(@as(usize, 2), try dec.read(&out, 2, &ch));
    try testing.expectEqualSlices(u8, ssnd[8..12], &out); // 大端原始字节
}

test "wav 集成: AIFC sowt（小端覆盖）" {
    var comm: [22]u8 = undefined; // 18 + compressionType "sowt"
    std.mem.writeInt(u16, comm[0..2], 1, .big);
    std.mem.writeInt(u32, comm[2..6], 2, .big);
    std.mem.writeInt(u16, comm[6..8], 16, .big);
    @memcpy(comm[8..18], &extended80(8000));
    @memcpy(comm[18..22], "sowt");

    var ssnd: [12]u8 = undefined;
    std.mem.writeInt(u32, ssnd[0..4], 0, .big);
    std.mem.writeInt(u32, ssnd[4..8], 0, .big);
    std.mem.writeInt(i16, ssnd[8..10], 100, .little); // 小端样本
    std.mem.writeInt(i16, ssnd[10..12], -200, .little);

    const file = try buildAiff(testing.allocator, true, &.{
        .{ .id = "COMM".*, .payload = &comm },
        .{ .id = "SSND".*, .payload = &ssnd },
    });
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();
    try testing.expectEqualStrings("pcm_s16le", info.codec_name); // sowt → LE

    var out: [4]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectEqual(@as(usize, 2), try dec.read(&out, 2, &ch));
    try testing.expectEqualSlices(u8, ssnd[8..12], &out);
}

test "wav 集成: AIFC ulaw（G.711 端到端）" {
    var comm: [22]u8 = undefined; // 18 + compressionType "ulaw"
    std.mem.writeInt(u16, comm[0..2], 1, .big);
    std.mem.writeInt(u32, comm[2..6], 4, .big);
    std.mem.writeInt(u16, comm[6..8], 8, .big);
    @memcpy(comm[8..18], &extended80(8000));
    @memcpy(comm[18..22], "ulaw");

    // 4 个 ulaw 码：0xFF→0, 0x7F→0, 0x80→32124, 0x00→-32124
    const ulaw_bytes = [_]u8{ 0xFF, 0x7F, 0x80, 0x00 };
    var ssnd: [12]u8 = undefined;
    std.mem.writeInt(u32, ssnd[0..4], 0, .big);
    std.mem.writeInt(u32, ssnd[4..8], 0, .big);
    @memcpy(ssnd[8..12], &ulaw_bytes);

    const file = try buildAiff(testing.allocator, true, &.{
        .{ .id = "COMM".*, .payload = &comm },
        .{ .id = "SSND".*, .payload = &ssnd },
    });
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();
    try testing.expectEqual(@as(u8, 16), info.bits_per_sample); // 解码输出 s16
    try testing.expectEqualStrings("pcm_mulaw", info.codec_name);
    try testing.expectEqual(@as(i64, 500), info.duration_us); // 4 帧 @ 8kHz

    var out: [8]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectEqual(@as(usize, 4), try dec.read(&out, 4, &ch));
    // 期望 s16 LE：0, 0, 32124(0x7D7C), -32124(0x8284)
    const expect = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x7C, 0x7D, 0x84, 0x82 };
    try testing.expectEqualSlices(u8, &expect, &out);
}

test "wav 集成: seek 与 position_ms" {
    // 8000 帧（1 秒）静音，8000 Hz mono s16
    const frames: usize = 8000;
    const pcm = try testing.allocator.alloc(u8, frames * 2);
    defer testing.allocator.free(pcm);
    @memset(pcm, 0);

    const fmt = testFmt(1, 1, 8000, 16000, 2, 16, .little);
    const file = try buildRiff(testing.allocator, "RIFF", .little, &.{
        .{ .id = "fmt ".*, .payload = &fmt },
        .{ .id = "data".*, .payload = pcm },
    });
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();
    try testing.expectEqual(@as(i64, 1_000_000), info.duration_us); // 1 秒

    try testing.expectEqual(@as(i64, 0), dec.positionMs());
    try dec.seekMs(500);
    try testing.expectEqual(@as(i64, 500), dec.positionMs());

    var out: [200]u8 = undefined; // 100 帧
    var ch: u8 = 0;
    const n = try dec.read(&out, 100, &ch);
    try testing.expectEqual(@as(usize, 100), n); // 500ms → 4000 帧处继续

    // 负值/0 → 跳到开头
    try dec.seekMs(0);
    try testing.expectEqual(@as(i64, 0), dec.positionMs());
}

test "wav 畸形: 未知 fmt tag（ADPCM 0x0050）→ UnsupportedFormat" {
    const fmt = testFmt(0x0050, 1, 8000, 8000, 1, 8, .little);
    const pcm = [_]u8{ 0, 0 };
    const file = try buildRiff(testing.allocator, "RIFF", .little, &.{
        .{ .id = "fmt ".*, .payload = &fmt },
        .{ .id = "data".*, .payload = &pcm },
    });
    defer testing.allocator.free(file);
    var info: decoder.Info = undefined;
    try testing.expectError(error.UnsupportedFormat, openMem(testing.allocator, file, &info));
}

test "wav 畸形: RIFF 非 WAVE → Corrupt" {
    const file = try buildRiff(testing.allocator, "RIFF", .little, &.{});
    defer testing.allocator.free(file);
    // 覆写 "WAVE" 为 "AVI "
    @memcpy(file[8..12], "AVI ");
    var info: decoder.Info = undefined;
    try testing.expectError(error.Corrupt, openMem(testing.allocator, file, &info));
}

test "wav 畸形: data 段越界 → clamp 到文件尾" {
    const fmt = testFmt(1, 1, 8000, 16000, 2, 16, .little);
    const pcm = [_]u8{ 0x64, 0x00, 0x38, 0xFF, 0x2C, 0x01, 0x70, 0xFE }; // 4 帧
    // 声明 100 字节但文件只有 8 字节 payload
    const file = try buildRiff(testing.allocator, "RIFF", .little, &.{
        .{ .id = "fmt ".*, .payload = &fmt },
        .{ .id = "data".*, .payload = &pcm, .size = 100 },
    });
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();
    try testing.expectEqual(@as(i64, 500), info.duration_us); // clamp 后 4 帧

    var out: [8]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectEqual(@as(usize, 4), try dec.read(&out, 8, &ch));
    try testing.expectEqualSlices(u8, &pcm, &out);
    try testing.expectEqual(@as(usize, 0), try dec.read(&out, 8, &ch));
}

test "wav 畸形: 缺 fmt chunk → Corrupt" {
    const junk = [_]u8{0} ** 4;
    const file = try buildRiff(testing.allocator, "RIFF", .little, &.{
        .{ .id = "JUNK".*, .payload = &junk },
        .{ .id = "data".*, .payload = &junk },
    });
    defer testing.allocator.free(file);
    var info: decoder.Info = undefined;
    try testing.expectError(error.Corrupt, openMem(testing.allocator, file, &info));
}

/// 构造 IMA ADPCM 块（mono：4B 头 + n 字节 nibble 数据）
fn imaMonoBlock(idelta: i16, idx: u8, data: []const u8) []u8 {
    const blk = testing.allocator.alloc(u8, 4 + data.len) catch unreachable;
    std.mem.writeInt(i16, blk[0..2], idelta, .little);
    blk[2] = idx;
    blk[3] = 0; // reserved
    @memcpy(blk[4..], data);
    return blk;
}

/// 构造 MS ADPCM 立体声块（14B 头按通道交错 + 8B nibble 数据）
fn msStereoBlock(d0: i16, d1: i16, data: []const u8) []u8 {
    const blk = testing.allocator.alloc(u8, 14 + data.len) catch unreachable;
    blk[0] = 0; // pred0
    blk[1] = 1; // pred1
    std.mem.writeInt(i16, blk[2..4], d0, .little);
    std.mem.writeInt(i16, blk[4..6], d1, .little);
    std.mem.writeInt(i16, blk[6..8], 1000, .little); // sample1 ch0
    std.mem.writeInt(i16, blk[8..10], -1000, .little); // sample1 ch1
    std.mem.writeInt(i16, blk[10..12], 2000, .little); // sample2 ch0
    std.mem.writeInt(i16, blk[12..14], -2000, .little); // sample2 ch1
    @memcpy(blk[14..], data);
    return blk;
}

test "wav 集成: IMA ADPCM（tag 0x11）块边界解码" {
    const d1 = [_]u8{ 0x12, 0x34, 0x56, 0x78 };
    const d2 = [_]u8{ 0x01, 0x23, 0x45, 0x67 };
    const b1 = imaMonoBlock(0, 0, &d1);
    defer testing.allocator.free(b1);
    const b2 = imaMonoBlock(-100, 40, &d2);
    defer testing.allocator.free(b2);
    const data = try testing.allocator.alloc(u8, b1.len + b2.len);
    defer testing.allocator.free(data);
    @memcpy(data[0..b1.len], b1);
    @memcpy(data[b1.len..], b2);

    // mono：block_align=8 → 每块 9 样本
    const fmt = testFmt(0x11, 1, 8000, 16000, 8, 4, .little);
    const file = try buildRiff(testing.allocator, "RIFF", .little, &.{
        .{ .id = "fmt ".*, .payload = &fmt },
        .{ .id = "data".*, .payload = data },
    });
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();
    try testing.expectEqualStrings("adpcm_ima_wav", info.codec_name);
    try testing.expectEqual(@as(u8, 16), info.bits_per_sample);
    try testing.expectEqual(@as(i64, 2250), info.duration_us); // 18 帧 @ 8kHz

    // 期望值：由已验证的块解码器独立计算
    var expect: [18]i16 = undefined;
    try adpcm.decodeImaWav(b1, 1, 9, expect[0..9]);
    try adpcm.decodeImaWav(b2, 1, 9, expect[9..18]);

    var out: [64]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectEqual(@as(usize, 18), try dec.read(&out, 64, &ch));
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expect[0..18]), out[0..36]);
    try testing.expectEqual(@as(usize, 0), try dec.read(&out, 64, &ch)); // EOF
}

test "wav 集成: MS ADPCM（tag 2）立体声 + seek 对齐块边界" {
    const d1 = [_]u8{ 0x0F, 0xE0, 0x55, 0xAA, 0x10, 0x2F, 0x80, 0xFF };
    const d2 = [_]u8{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77 };
    const b1 = msStereoBlock(100, 50, &d1);
    defer testing.allocator.free(b1);
    const b2 = msStereoBlock(30, 200, &d2);
    defer testing.allocator.free(b2);
    const data = try testing.allocator.alloc(u8, b1.len + b2.len);
    defer testing.allocator.free(data);
    @memcpy(data[0..b1.len], b1);
    @memcpy(data[b1.len..], b2);

    // stereo：block_align=22 → 每通道 10 样本（20 交错帧）
    const fmt = testFmt(2, 2, 8000, 32000, 22, 4, .little);
    const file = try buildRiff(testing.allocator, "RIFF", .little, &.{
        .{ .id = "fmt ".*, .payload = &fmt },
        .{ .id = "data".*, .payload = data },
    });
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();
    try testing.expectEqualStrings("adpcm_ms", info.codec_name);
    try testing.expectEqual(@as(u8, 2), info.channels);
    try testing.expectEqual(@as(i64, 2500), info.duration_us); // 20 帧 @ 8kHz

    var expect: [40]i16 = undefined;
    try adpcm.decodeMs(b1, 2, 10, expect[0..20]);
    try adpcm.decodeMs(b2, 2, 10, expect[20..40]);

    // 读全部
    var out: [128]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectEqual(@as(usize, 20), try dec.read(&out, 128, &ch));
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expect[0..20]), out[0..40]);
    try testing.expectEqual(@as(usize, 0), try dec.read(&out, 128, &ch));

    // seek 到块 1 起点（2ms → 16 帧 → 1 块 = 10 帧），读取应与第 2 块一致
    try dec.seekMs(2);
    try testing.expectEqual(@as(i64, 1), dec.positionMs()); // 10 帧 @ 8kHz
    try testing.expectEqual(@as(usize, 10), try dec.read(&out, 128, &ch));
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expect[20..30]), out[0..20]);
}

test "wav 集成: AIFC ima4（ADPCM IMA QT）端到端" {
    var comm: [22]u8 = undefined; // 18 + compressionType "ima4"
    std.mem.writeInt(u16, comm[0..2], 1, .big); // channels
    std.mem.writeInt(u32, comm[2..6], 64, .big); // frames
    std.mem.writeInt(u16, comm[6..8], 4, .big); // bits（4-bit）
    @memcpy(comm[8..18], &extended80(8000));
    @memcpy(comm[18..22], "ima4");

    // SSND：1 块 34B（2B BE 头 predictor=0/step=0 + 32B 数据全 0）→ 64 样本/通道
    var ssnd: [44]u8 = [_]u8{0} ** 44; // offset(4)+blockSize(4)+块(34)+pad(2 对齐)
    std.mem.writeInt(u32, ssnd[0..4], 0, .big);
    std.mem.writeInt(u32, ssnd[4..8], 0, .big);

    const file = try buildAiff(testing.allocator, true, &.{
        .{ .id = "COMM".*, .payload = &comm },
        .{ .id = "SSND".*, .payload = ssnd[0..42] }, // 块+1 pad
    });
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();
    try testing.expectEqualStrings("adpcm_ima_qt", info.codec_name);
    try testing.expectEqual(@as(u8, 1), info.channels);
    try testing.expectEqual(@as(i64, 8000), info.duration_us); // 64 帧 @ 8kHz

    var out: [128]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectEqual(@as(usize, 64), try dec.read(&out, 64, &ch));
    for (out[0..128]) |b| try testing.expectEqual(@as(u8, 0), b); // 静音块 → 全 0
    try testing.expectEqual(@as(usize, 0), try dec.read(&out, 64, &ch)); // EOF
}

test "wav 集成: IMA DK4（tag 0x61）块边界解码 mono + stereo" {
    // mono：两块，每块 4B hdr + 4B data = 8B → spb = 1+8/1 = 9
    const d1 = [_]u8{ 0x12, 0x34, 0x56, 0x78 };
    const d2 = [_]u8{ 0x01, 0x23, 0x45, 0x67 };
    const b1 = testing.allocator.alloc(u8, 8) catch unreachable;
    defer testing.allocator.free(b1);
    std.mem.writeInt(i16, b1[0..2], 100, .little);
    std.mem.writeInt(i16, b1[2..4], 20, .little);
    @memcpy(b1[4..8], &d1);
    const b2 = testing.allocator.alloc(u8, 8) catch unreachable;
    defer testing.allocator.free(b2);
    std.mem.writeInt(i16, b2[0..2], -100, .little);
    std.mem.writeInt(i16, b2[2..4], 40, .little);
    @memcpy(b2[4..8], &d2);
    const data = try testing.allocator.alloc(u8, 16);
    defer testing.allocator.free(data);
    @memcpy(data[0..8], b1);
    @memcpy(data[8..16], b2);

    const fmt = testFmt(0x61, 1, 8000, 16000, 8, 4, .little);
    const file = try buildRiff(testing.allocator, "RIFF", .little, &.{
        .{ .id = "fmt ".*, .payload = &fmt },
        .{ .id = "data".*, .payload = data },
    });
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();
    try testing.expectEqualStrings("adpcm_ima_dk4", info.codec_name);
    try testing.expectEqual(@as(u8, 16), info.bits_per_sample);
    try testing.expectEqual(@as(i64, 2250), info.duration_us); // 18 帧 @ 8kHz

    var expect: [18]i16 = undefined;
    try adpcm.decodeDk4(b1, 1, 9, expect[0..9]);
    try adpcm.decodeDk4(b2, 1, 9, expect[9..18]);

    var out: [64]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectEqual(@as(usize, 18), try dec.read(&out, 64, &ch));
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expect[0..18]), out[0..36]);
    try testing.expectEqual(@as(usize, 0), try dec.read(&out, 64, &ch)); // EOF

    // stereo：块 8B hdr + 2B data = 10B → spb = 1+4/2 = 3
    const sb = testing.allocator.alloc(u8, 10) catch unreachable;
    defer testing.allocator.free(sb);
    std.mem.writeInt(i16, sb[0..2], 100, .little);
    std.mem.writeInt(i16, sb[2..4], 5, .little);
    std.mem.writeInt(i16, sb[4..6], -100, .little);
    std.mem.writeInt(i16, sb[6..8], 8, .little);
    sb[8] = 0xAB;
    sb[9] = 0xCD;
    const fmt2 = testFmt(0x61, 2, 8000, 16000, 10, 4, .little);
    const file2 = try buildRiff(testing.allocator, "RIFF", .little, &.{
        .{ .id = "fmt ".*, .payload = &fmt2 },
        .{ .id = "data".*, .payload = sb },
    });
    defer testing.allocator.free(file2);
    var info2: decoder.Info = undefined;
    var dec2 = try openMem(testing.allocator, file2, &info2);
    defer dec2.deinit();
    try testing.expectEqual(@as(u8, 2), info2.channels);
    var expect2: [6]i16 = undefined;
    try adpcm.decodeDk4(sb, 2, 3, &expect2);
    var out2: [32]u8 = undefined;
    try testing.expectEqual(@as(usize, 3), try dec2.read(&out2, 32, &ch));
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expect2[0..6]), out2[0..12]);
}

// 黄金样本通用解码器：构建 RIFF → 全量读取 → 与期望 PCM 逐字节比对
fn checkGolden(
    comptime fmt: []const u8,
    comptime data: []const u8,
    comptime expect: []const u8,
    comptime codec: []const u8,
    sample_rate: u32,
    channels: u8,
    duration_us: i64,
) !void {
    const file = try buildRiff(testing.allocator, "RIFF", .little, &.{
        .{ .id = "fmt ".*, .payload = fmt },
        .{ .id = "data".*, .payload = data },
    });
    defer testing.allocator.free(file);
    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();
    try testing.expectEqualStrings(codec, info.codec_name);
    try testing.expectEqual(@as(u8, 16), info.bits_per_sample);
    try testing.expectEqual(channels, info.channels);
    try testing.expectEqual(sample_rate, info.sample_rate);
    try testing.expectEqual(duration_us, info.duration_us);

    const got = try testing.allocator.alloc(u8, expect.len);
    defer testing.allocator.free(got);
    var off: usize = 0;
    var buf: [256]u8 = undefined;
    var ch0: u8 = 0;
    while (off < expect.len) {
        const n = try dec.read(&buf, 256, &ch0); // 返回帧数（含全部声道）
        if (n == 0) break;
        const nbytes = n * channels * 2; // s16
        @memcpy(got[off .. off + nbytes], buf[0..nbytes]);
        off += nbytes;
    }
    try testing.expectEqual(@as(usize, expect.len), off);
    try testing.expectEqualSlices(u8, expect, got);
}

test "wav 集成: DK3（tag 0x62）黄金样本 bit-exact（FFmpeg 对照）" {
    try checkGolden(&adpcm.golden_dk3_fmt, &adpcm.golden_dk3_data, &adpcm.golden_dk3_expect, "adpcm_ima_dk3", 22050, 2, 3537);
}

test "wav 集成: XBOX（tag 0x69）黄金样本 bit-exact（FFmpeg 对照）" {
    try checkGolden(&adpcm.golden_xbox_fmt, &adpcm.golden_xbox_data, &adpcm.golden_xbox_expect, "adpcm_ima_xbox", 48000, 2, 1000);
}

test "wav 集成: SANYO 3-bit（tag 0x125）黄金样本 bit-exact（FFmpeg 对照）" {
    try checkGolden(&adpcm.golden_sanyo_m3_fmt, &adpcm.golden_sanyo_m3_data, &adpcm.golden_sanyo_m3_expect, "adpcm_sanyo", 8000, 1, 30000);
}

test "wav 集成: SANYO 5-bit（tag 0x125）黄金样本 bit-exact（FFmpeg 对照）" {
    try checkGolden(&adpcm.golden_sanyo_s5_fmt, &adpcm.golden_sanyo_s5_data, &adpcm.golden_sanyo_s5_expect, "adpcm_sanyo", 8000, 2, 16000);
}

test "wav 集成: ZORK（tag 0x11 + bits 8）黄金样本 bit-exact（FFmpeg 对照）" {
    try checkGolden(&adpcm.golden_zork_fmt, &adpcm.golden_zork_data, &adpcm.golden_zork_expect, "adpcm_zork", 8000, 2, 25000);
}

test "wav 集成: SWF mono（tag 0x5346）黄金样本 bit-exact（FFmpeg 对照）" {
    try checkGolden(&adpcm.golden_swf_mono_fmt, &adpcm.golden_swf_mono_data, &adpcm.golden_swf_mono_expect, "adpcm_swf", 8000, 1, 12625);
}

test "wav 集成: SWF stereo（tag 0x5346）黄金样本 bit-exact（FFmpeg 对照）" {
    try checkGolden(&adpcm.golden_swf_stereo_fmt, &adpcm.golden_swf_stereo_data, &adpcm.golden_swf_stereo_expect, "adpcm_swf", 8000, 2, 8125);
}

test "wav 集成: G.722（tag 0x028F）黄金样本 bit-exact（FFmpeg 对照）" {
    try checkGolden(&adpcm.golden_g722_mono_fmt, &adpcm.golden_g722_mono_data, &adpcm.golden_g722_mono_expect, "adpcm_g722", 16000, 1, 1000000);
}

test "wav 集成: G.726（tag 0x0045）code_size 2 黄金样本 bit-exact（FFmpeg 对照）" {
    try checkGolden(&adpcm.golden_g726_2_fmt, &adpcm.golden_g726_2_data, &adpcm.golden_g726_2_expect, "adpcm_g726", 8000, 1, 1000000);
}

test "wav 集成: G.726（tag 0x0045）code_size 3 黄金样本 bit-exact（FFmpeg 对照）" {
    try checkGolden(&adpcm.golden_g726_3_fmt, &adpcm.golden_g726_3_data, &adpcm.golden_g726_3_expect, "adpcm_g726", 8000, 1, 1000000);
}

test "wav 集成: G.726（tag 0x0045）code_size 4 黄金样本 bit-exact（FFmpeg 对照）" {
    try checkGolden(&adpcm.golden_g726_4_fmt, &adpcm.golden_g726_4_data, &adpcm.golden_g726_4_expect, "adpcm_g726", 8000, 1, 1000000);
}

test "wav 集成: G.726（tag 0x0045）code_size 5 黄金样本 bit-exact（FFmpeg 对照）" {
    try checkGolden(&adpcm.golden_g726_5_fmt, &adpcm.golden_g726_5_data, &adpcm.golden_g726_5_expect, "adpcm_g726", 8000, 1, 1000000);
}

test "wav 集成: OKI ADPCM（tag 0x10）连续流 mono" {
    const data = [_]u8{ 0x00, 0x00, 0x00, 0x00 }; // 每字节 2 帧 → 8 帧
    // mono：block_align=1（每帧 1 字节）
    const fmt = testFmt(0x10, 1, 8000, 8000, 1, 4, .little);
    const file = try buildRiff(testing.allocator, "RIFF", .little, &.{
        .{ .id = "fmt ".*, .payload = &fmt },
        .{ .id = "data".*, .payload = &data },
    });
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();
    try testing.expectEqualStrings("adpcm_ima_oki", info.codec_name);
    try testing.expectEqual(@as(i64, 1000), info.duration_us); // 8 帧 @ 8kHz

    // 期望：由已验证的连续流解码器独立计算
    var expect: [8]i16 = undefined;
    var st = adpcm.ContState{};
    adpcm.decodeOki(&st, &data, 1, &expect);

    var out: [64]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectEqual(@as(usize, 8), try dec.read(&out, 64, &ch));
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expect[0..8]), out[0..16]);
    try testing.expectEqual(@as(usize, 0), try dec.read(&out, 64, &ch));
}

test "wav 集成: Yamaha ADPCM（tag 0x20）连续流 stereo + seek 重置状态" {
    const data = [_]u8{ 0x12, 0x34, 0x56, 0x78 }; // 每字节 1 帧（stereo）→ 4 帧
    // stereo：block_align=2（每帧 2 字节）
    const fmt = testFmt(0x20, 2, 8000, 16000, 2, 4, .little);
    const file = try buildRiff(testing.allocator, "RIFF", .little, &.{
        .{ .id = "fmt ".*, .payload = &fmt },
        .{ .id = "data".*, .payload = &data },
    });
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();
    try testing.expectEqualStrings("adpcm_yamaha", info.codec_name);
    try testing.expectEqual(@as(u8, 2), info.channels);
    try testing.expectEqual(@as(i64, 500), info.duration_us); // 4 帧 @ 8kHz

    var expect: [8]i16 = undefined;
    var st = adpcm.ContState{};
    adpcm.decodeYamaha(&st, &data, 2, &expect);

    var out: [128]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectEqual(@as(usize, 4), try dec.read(&out, 128, &ch));
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expect[0..8]), out[0..16]);

    // 连续流 seek：无块头，重置状态 + 定位字节。seek 到起点后从头重新解码。
    try dec.seekMs(0);
    try testing.expectEqual(@as(usize, 4), try dec.read(&out, 128, &ch));
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expect[0..8]), out[0..16]);
}

test "wav 集成: Creative CT（tag 0x200）连续流 mono（open 时 step=511 初始化）" {
    const data = [_]u8{ 0x00, 0x00, 0x00, 0x00 }; // 每字节 2 帧 → 8 帧
    const fmt = testFmt(0x200, 1, 8000, 8000, 1, 4, .little);
    const file = try buildRiff(testing.allocator, "RIFF", .little, &.{
        .{ .id = "fmt ".*, .payload = &fmt },
        .{ .id = "data".*, .payload = &data },
    });
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();
    try testing.expectEqualStrings("adpcm_ct", info.codec_name);
    try testing.expectEqual(@as(i64, 1000), info.duration_us); // 8 帧 @ 8kHz

    var out: [64]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectEqual(@as(usize, 8), try dec.read(&out, 64, &ch));
    // step 初始 511、predictor 0，nibble 全 0：
    // diff=(1*511)>>3=63；predictor 递推：63, 63*254>>8=62+63=125,
    // 125*254>>8=124+63=187, 187*254>>8=185+63=248, 248*254>>8=246+63=309,
    // 309*254>>8=306+63=369, 369*254>>8=366+63=429, 429*254>>8=425+63=488
    const expect = [_]i16{ 63, 125, 187, 248, 309, 369, 429, 488 };
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expect[0..8]), out[0..16]);
}

test "wav 集成: OKI ADPCM（tag 0x10）连续流 stereo 交错" {
    const data = [_]u8{ 0x01, 0x02, 0x03, 0x04 }; // 每字节 1 帧（stereo）→ 4 帧
    const fmt = testFmt(0x10, 2, 8000, 16000, 2, 4, .little);
    const file = try buildRiff(testing.allocator, "RIFF", .little, &.{
        .{ .id = "fmt ".*, .payload = &fmt },
        .{ .id = "data".*, .payload = &data },
    });
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();
    try testing.expectEqualStrings("adpcm_ima_oki", info.codec_name);
    try testing.expectEqual(@as(u8, 2), info.channels);
    try testing.expectEqual(@as(i64, 500), info.duration_us); // 4 帧 @ 8kHz

    // 期望：由已验证的连续流解码器独立计算（验证接线与声道交错）
    var expect: [8]i16 = undefined;
    var st = adpcm.ContState{};
    adpcm.decodeOki(&st, &data, 2, &expect);

    var out: [64]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectEqual(@as(usize, 4), try dec.read(&out, 64, &ch));
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expect[0..8]), out[0..16]);
    try testing.expectEqual(@as(usize, 0), try dec.read(&out, 64, &ch));
}

/// 追加一个 LIST-INFO 子 chunk（id + size LE + text + 奇对齐 pad）
fn appendInfoField(list: *std.ArrayList(u8), id: [4]u8, text: []const u8) !void {
    try list.appendSlice(testing.allocator, &id);
    var sz: [4]u8 = undefined;
    std.mem.writeInt(u32, sz[0..4], @intCast(text.len), .little);
    try list.appendSlice(testing.allocator, &sz);
    try list.appendSlice(testing.allocator, text);
    if (text.len & 1 == 1) try list.appendSlice(testing.allocator, &[_]u8{0});
}

test "wav 集成: RIFF LIST-INFO 标签元数据" {
    const fmt = testFmt(1, 1, 8000, 16000, 2, 16, .little);
    const pcm = [_]u8{ 0x64, 0x00, 0x38, 0xFF }; // 2 帧

    var list = std.ArrayList(u8).empty;
    defer list.deinit(testing.allocator);
    try list.appendSlice(testing.allocator, "INFO");
    try appendInfoField(&list, "INAM".*, "My Title");
    try appendInfoField(&list, "IART".*, "Artist");
    try appendInfoField(&list, "IPRD".*, "Album");
    try appendInfoField(&list, "ICRD".*, "2024");
    try appendInfoField(&list, "IGNR".*, "Pop");
    try appendInfoField(&list, "ICMT".*, "Great!");

    const file = try buildRiff(testing.allocator, "RIFF", .little, &.{
        .{ .id = "fmt ".*, .payload = &fmt },
        .{ .id = "LIST".*, .payload = list.items },
        .{ .id = "data".*, .payload = &pcm },
    });
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();
    try testing.expectEqualStrings("My Title", info.metadata.title.?);
    try testing.expectEqualStrings("Artist", info.metadata.artist.?);
    try testing.expectEqualStrings("Album", info.metadata.album.?);
    try testing.expectEqualStrings("2024", info.metadata.date.?);
    try testing.expectEqualStrings("Pop", info.metadata.genre.?);
    try testing.expectEqualStrings("Great!", info.metadata.comment.?);

    // 元数据解析不影响解码
    var out: [8]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectEqual(@as(usize, 2), try dec.read(&out, 8, &ch));
    try testing.expectEqualSlices(u8, &pcm, out[0..4]);
}

test "wav 集成: AIFF NAME/AUTH/ANNO 标签元数据" {
    var comm: [18]u8 = undefined;
    std.mem.writeInt(u16, comm[0..2], 1, .big);
    std.mem.writeInt(u32, comm[2..6], 2, .big);
    std.mem.writeInt(u16, comm[6..8], 16, .big);
    @memcpy(comm[8..18], &extended80(8000));

    // pascal 字符串 payload：len(1) + 文本
    var name: [8]u8 = undefined; // 1 + "My Song"(7)
    name[0] = 7;
    @memcpy(name[1..], "My Song");
    var auth: [7]u8 = undefined; // 1 + "Singer"(6)
    auth[0] = 6;
    @memcpy(auth[1..], "Singer");
    var anno: [6]u8 = undefined; // 1 + "Great"(5)
    anno[0] = 5;
    @memcpy(anno[1..], "Great");

    var ssnd: [12]u8 = undefined;
    std.mem.writeInt(u32, ssnd[0..4], 0, .big);
    std.mem.writeInt(u32, ssnd[4..8], 0, .big);
    std.mem.writeInt(i16, ssnd[8..10], 100, .big);
    std.mem.writeInt(i16, ssnd[10..12], -200, .big);

    const file = try buildAiff(testing.allocator, false, &.{
        .{ .id = "COMM".*, .payload = &comm },
        .{ .id = "NAME".*, .payload = &name },
        .{ .id = "AUTH".*, .payload = &auth },
        .{ .id = "ANNO".*, .payload = &anno },
        .{ .id = "SSND".*, .payload = &ssnd },
    });
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();
    try testing.expectEqualStrings("My Song", info.metadata.title.?);
    try testing.expectEqualStrings("Singer", info.metadata.artist.?);
    try testing.expectEqualStrings("Great", info.metadata.comment.?);

    var out: [4]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectEqual(@as(usize, 2), try dec.read(&out, 2, &ch));
    try testing.expectEqualSlices(u8, ssnd[8..12], &out);
}

test "wav 集成: RIFF LIST 非 INFO（adtl）跳过" {
    const fmt = testFmt(1, 1, 8000, 16000, 2, 16, .little);
    const pcm = [_]u8{ 0x64, 0x00, 0x38, 0xFF };
    const adtl = [_]u8{ 'a', 'd', 't', 'l', 0x01, 0x02, 0x03, 0x04 }; // LIST adtl

    const file = try buildRiff(testing.allocator, "RIFF", .little, &.{
        .{ .id = "fmt ".*, .payload = &fmt },
        .{ .id = "LIST".*, .payload = &adtl },
        .{ .id = "data".*, .payload = &pcm },
    });
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();
    try testing.expect(info.metadata.title == null);
    var out: [8]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectEqual(@as(usize, 2), try dec.read(&out, 8, &ch));
}

test "wav 畸形: LIST-INFO 声明超长 → 截断不崩溃" {
    const fmt = testFmt(1, 1, 8000, 16000, 2, 16, .little);
    const pcm = [_]u8{ 0x64, 0x00, 0x38, 0xFF };
    // LIST 声明 0xFFFF 字节但实际只有 "INFO" + 一个截断字段（text 16B 声明 / 2B 实际）
    var list = std.ArrayList(u8).empty;
    defer list.deinit(testing.allocator);
    try list.appendSlice(testing.allocator, "INFO");
    try list.appendSlice(testing.allocator, "INAM");
    const sz: [4]u8 = .{ 0x10, 0x00, 0x00, 0x00 };
    try list.appendSlice(testing.allocator, &sz);
    try list.appendSlice(testing.allocator, "Hi");

    const file = try buildRiff(testing.allocator, "RIFF", .little, &.{
        .{ .id = "fmt ".*, .payload = &fmt },
        .{ .id = "data".*, .payload = &pcm },
        .{ .id = "LIST".*, .payload = list.items, .size = 0xFFFF },
    });
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();
    try testing.expectEqualStrings("Hi", info.metadata.title.?);
    var out: [8]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectEqual(@as(usize, 2), try dec.read(&out, 8, &ch));
}

test "wav 集成: GSM_MS（tag 0x31）端到端黄金 + seek 块对齐" {
    // 真实数据：libgsm_ms 编码 960 样本 440Hz 正弦（/tmp/gsm_ref.wav data 区，3 块 × 65B），
    // 解码期望与 FFmpeg 原生输出逐字节一致（gsm.zig 已锚定黄金）。
    const data = [_]u8{
        0x88, 0xDD, 0xE1, 0x1A, 0x85, 0xC2, 0xF3, 0x16, 0x40, 0x9B, 0xD2, 0x8A,
        0x02, 0xEB, 0x1C, 0xDB, 0x69, 0x24, 0x57, 0xA5, 0x64, 0x44, 0xFA, 0x2F,
        0x59, 0x8B, 0xC7, 0x04, 0xF1, 0xBF, 0x64, 0x2D, 0x85, 0xD8, 0x3D, 0xEE,
        0x51, 0x78, 0x10, 0xC4, 0x25, 0xB3, 0x87, 0xF0, 0xEE, 0x0A, 0x96, 0xCC,
        0x66, 0xB0, 0x9A, 0xB6, 0x0C, 0x22, 0xDA, 0x8B, 0x68, 0x2F, 0xED, 0x08,
        0x34, 0x9B, 0xC9, 0x7C, 0x2A, 0x88, 0xDD, 0xE1, 0x1A, 0x65, 0x33, 0xA0,
        0xF7, 0x92, 0xFD, 0x04, 0xB4, 0x35, 0xE0, 0x4D, 0xD4, 0x5B, 0x50, 0x9D,
        0x54, 0x60, 0x08, 0xEF, 0x25, 0xB4, 0xB7, 0x55, 0x00, 0xAA, 0x3B, 0x84,
        0xB7, 0x80, 0xDC, 0x1D, 0xAA, 0x51, 0x37, 0x01, 0x34, 0x9B, 0xD2, 0x5C,
        0x6E, 0x49, 0x01, 0xB4, 0x96, 0xD3, 0x58, 0x6E, 0x5C, 0x03, 0xC6, 0x91,
        0xE5, 0xA4, 0x91, 0x6D, 0x05, 0x3A, 0x69, 0xAD, 0xB2, 0x96, 0x88, 0xDD,
        0xE3, 0x1E, 0xD5, 0x3E, 0x60, 0x23, 0x39, 0x89, 0x6D, 0x62, 0x3B, 0x40,
        0x7D, 0x15, 0xD5, 0x9D, 0x74, 0xD3, 0xC0, 0xA5, 0xC4, 0x76, 0xD2, 0x9A,
        0x34, 0xE0, 0x0C, 0xE6, 0x53, 0x59, 0x8F, 0xE0, 0x1D, 0xAA, 0x51, 0xB7,
        0x0C, 0x16, 0x8D, 0xE5, 0xB6, 0x91, 0xDD, 0x02, 0x38, 0x8D, 0xE5, 0x34,
        0x96, 0xEF, 0x06, 0x34, 0x96, 0x13, 0xD9, 0x6E, 0x49, 0x05, 0xD8, 0x52,
        0x5B, 0x4B, 0x69,
    };
    var fact: [4]u8 = undefined;
    std.mem.writeInt(u32, fact[0..4], 960, .little); // fact 帧数（真实 gsm_ref.wav 亦带 fact）
    // 真实头字段：tag 0x31、mono、8000Hz、byte_rate 1625、align 65、bits 2
    const fmt = testFmt(0x31, 1, 8000, 1625, 65, 2, .little);
    const file = try buildRiff(testing.allocator, "RIFF", .little, &.{
        .{ .id = "fmt ".*, .payload = &fmt },
        .{ .id = "fact".*, .payload = &fact },
        .{ .id = "data".*, .payload = &data },
    });
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();
    try testing.expectEqualStrings("gsm_ms", info.codec_name);
    try testing.expectEqual(@as(u8, 16), info.bits_per_sample);
    try testing.expectEqual(@as(u8, 1), info.channels);
    try testing.expectEqual(@as(i64, 120_000), info.duration_us); // 960 帧 @ 8kHz

    // 期望：由已验证的 GSM 解码器独立计算（gsm.zig 黄金锚定）
    var expect: [960]i16 = undefined;
    var ctx = gsm.Context{};
    var pos: usize = 0;
    for (0..3) |i| {
        try gsm.decodeGsmMs(&ctx, data[i * 65 ..][0..65], expect[pos..][0..320]);
        pos += 320;
    }

    var out: [2048]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectEqual(@as(usize, 960), try dec.read(&out, 960, &ch));
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expect[0..960]), out[0..1920]);
    try testing.expectEqual(@as(usize, 0), try dec.read(&out, 960, &ch)); // EOF

    // seek 61ms → 488 帧 → 1 块 = 320 帧 → position 40ms；从第 2 块起读
    try dec.seekMs(61);
    try testing.expectEqual(@as(i64, 40), dec.positionMs());
    try testing.expectEqual(@as(usize, 640), try dec.read(&out, 640, &ch));
    // GSM 为流式状态解码：seek 后内部状态被 flush（镜像 FFmpeg），块 1 起以全新
    // 状态解码，输出与未 seek 的连续解码（expect[320..]，依赖块 0 状态）不同。
    // 因此期望改为 seek 后以全新 ctx 从块 1 起重新解码。
    var ctx_seek = gsm.Context{};
    var expect_seek: [640]i16 = undefined;
    try gsm.decodeGsmMs(&ctx_seek, data[65..130], expect_seek[0..320]);
    try gsm.decodeGsmMs(&ctx_seek, data[130..195], expect_seek[320..640]);
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expect_seek[0..640]), out[0..1280]);
}

test "wav 集成: AIFC GSM（'GSM '）端到端" {
    // 与 GSM_MS 同源音频的纯 GSM 封装（198B = 6 帧 × 33B，MSB 位序）
    var comm: [22]u8 = undefined; // 18 + compressionType "GSM "
    std.mem.writeInt(u16, comm[0..2], 1, .big); // channels
    std.mem.writeInt(u32, comm[2..6], 960, .big); // frames
    std.mem.writeInt(u16, comm[6..8], 0, .big); // bits（压缩类型下无效）
    @memcpy(comm[8..18], &extended80(8000));
    @memcpy(comm[18..22], "GSM ");

    const data = [_]u8{
        0xD2, 0x36, 0xEC, 0x2D, 0xA2, 0x50, 0x53, 0xFC, 0x80, 0x9B, 0x44, 0x9D,
        0x50, 0x0B, 0x78, 0xE5, 0xAD, 0x39, 0x23, 0xAA, 0x24, 0xB8, 0x0D, 0xFD,
        0x92, 0xED, 0xF0, 0x44, 0x83, 0xBF, 0x64, 0xBB, 0x62, 0xD2, 0x36, 0xEC,
        0x6D, 0xE2, 0xF0, 0x01, 0x28, 0xC9, 0x7B, 0x30, 0x67, 0xDC, 0xA0, 0xB2,
        0x5E, 0xD0, 0x87, 0x74, 0x6C, 0xC0, 0x95, 0x36, 0x65, 0x4D, 0x99, 0xDA,
        0x80, 0xA7, 0xB4, 0x25, 0xEF, 0x11, 0xD2, 0x36, 0xEC, 0x2D, 0xA2, 0x6D,
        0x20, 0x5F, 0x99, 0x2F, 0xF8, 0x02, 0xB7, 0x20, 0x7A, 0x4A, 0xBF, 0x20,
        0xAE, 0x93, 0x40, 0x30, 0x67, 0xCC, 0x99, 0xB3, 0xB7, 0x40, 0x05, 0x75,
        0x60, 0xCF, 0x90, 0xD2, 0x37, 0xEC, 0x29, 0xA2, 0x6F, 0x00, 0x27, 0xB4,
        0x49, 0xEB, 0x1B, 0x93, 0x00, 0x27, 0x6C, 0x69, 0xCB, 0x1B, 0xB9, 0x20,
        0x38, 0xE4, 0xB1, 0xA4, 0xE4, 0xDB, 0x40, 0x56, 0x93, 0xB5, 0x17, 0x6C,
        0xD2, 0x36, 0xEC, 0x6D, 0xE2, 0xDB, 0xA0, 0x37, 0x24, 0x69, 0x4B, 0x49,
        0x6D, 0xA0, 0x2B, 0xEA, 0x2A, 0xEA, 0xD2, 0x6F, 0x40, 0xEB, 0x12, 0x96,
        0xB4, 0x9D, 0x93, 0x20, 0x78, 0x43, 0xDE, 0x22, 0xEF, 0xD2, 0x38, 0xEC,
        0x29, 0xA2, 0x6E, 0xC0, 0xB2, 0x9C, 0xB1, 0xB6, 0xE4, 0xBA, 0xA0, 0x46,
        0x9C, 0xB1, 0xA7, 0x2C, 0xDE, 0xE0, 0x27, 0x2C, 0x6A, 0x4B, 0x5B, 0x93,
        0x40, 0x4B, 0x62, 0x6E, 0xD8, 0x93,
    };
    var ssnd: [8 + 198]u8 = undefined;
    std.mem.writeInt(u32, ssnd[0..4], 0, .big); // offset
    std.mem.writeInt(u32, ssnd[4..8], 0, .big); // blockSize
    @memcpy(ssnd[8..], &data);

    const file = try buildAiff(testing.allocator, true, &.{
        .{ .id = "COMM".*, .payload = &comm },
        .{ .id = "SSND".*, .payload = &ssnd },
    });
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();
    try testing.expectEqualStrings("gsm", info.codec_name);
    try testing.expectEqual(@as(u8, 16), info.bits_per_sample);
    try testing.expectEqual(@as(i64, 120_000), info.duration_us); // 6 块 × 160 帧 @ 8kHz

    var expect: [960]i16 = undefined;
    var ctx = gsm.Context{};
    var pos: usize = 0;
    for (0..6) |i| {
        try gsm.decodeGsm(&ctx, data[i * 33 ..][0..33], expect[pos..][0..160]);
        pos += 160;
    }

    var out: [2048]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectEqual(@as(usize, 960), try dec.read(&out, 960, &ch));
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expect[0..960]), out[0..1920]);
    try testing.expectEqual(@as(usize, 0), try dec.read(&out, 960, &ch)); // EOF
}

test "wav 集成: AIFC MAC6（'MAC6'）mono 端到端黄金 + seek 块对齐" {
    // 黄金数据（mace.zig）由独立 Python 参考实现生成，并已与 FFmpeg 官方 mace6 解码器逐样本一致
    const data = mace.golden_m6m;
    var comm: [22]u8 = undefined; // 18 + compressionType "MAC6"
    std.mem.writeInt(u16, comm[0..2], 1, .big); // channels
    std.mem.writeInt(u32, comm[2..6], 120, .big); // frames
    std.mem.writeInt(u16, comm[6..8], 0, .big); // bits（压缩类型下无效）
    @memcpy(comm[8..18], &extended80(22050));
    @memcpy(comm[18..22], "MAC6");
    var ssnd: [8 + 20]u8 = undefined;
    std.mem.writeInt(u32, ssnd[0..4], 0, .big); // offset
    std.mem.writeInt(u32, ssnd[4..8], 0, .big); // blockSize
    @memcpy(ssnd[8..], &data);

    const file = try buildAiff(testing.allocator, true, &.{
        .{ .id = "COMM".*, .payload = &comm },
        .{ .id = "SSND".*, .payload = &ssnd },
    });
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();
    try testing.expectEqualStrings("mace6", info.codec_name);
    try testing.expectEqual(@as(u8, 16), info.bits_per_sample);
    try testing.expectEqual(@as(u8, 1), info.channels);
    try testing.expectEqual(@as(i64, 5442), info.duration_us); // 120 帧 @ 22050

    var out: [256]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectEqual(@as(usize, 120), try dec.read(&out, 120, &ch));
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&mace.golden_m6m_expect), out[0..240]);
    try testing.expectEqual(@as(usize, 0), try dec.read(&out, 120, &ch)); // EOF

    // seek 2ms → 44 帧 → 7 块 = 42 帧 → position 1ms；从第 8 块起读（13 块 = 78 帧）
    try dec.seekMs(2);
    try testing.expectEqual(@as(i64, 1), dec.positionMs());
    try testing.expectEqual(@as(usize, 78), try dec.read(&out, 78, &ch));
    // MACE 为流式状态：seek 后 ctx 被 flush（镜像 FFmpeg），期望以全新 ctx 从块 7 起解码
    var ctx = mace.Context{};
    var expect_seek: [78]i16 = undefined;
    _ = try mace.decode(&ctx, data[7..], 1, false, &expect_seek);
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&expect_seek), out[0..156]);
}

test "wav 集成: AIFC MAC3（'MAC3'）mono 端到端黄金" {
    const data = mace.golden_m3m;
    var comm: [22]u8 = undefined;
    std.mem.writeInt(u16, comm[0..2], 1, .big);
    std.mem.writeInt(u32, comm[2..6], 60, .big); // frames
    std.mem.writeInt(u16, comm[6..8], 0, .big);
    @memcpy(comm[8..18], &extended80(22050));
    @memcpy(comm[18..22], "MAC3");
    var ssnd: [8 + 20]u8 = undefined;
    std.mem.writeInt(u32, ssnd[0..4], 0, .big);
    std.mem.writeInt(u32, ssnd[4..8], 0, .big);
    @memcpy(ssnd[8..], &data);

    const file = try buildAiff(testing.allocator, true, &.{
        .{ .id = "COMM".*, .payload = &comm },
        .{ .id = "SSND".*, .payload = &ssnd },
    });
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();
    try testing.expectEqualStrings("mace3", info.codec_name);
    try testing.expectEqual(@as(u8, 16), info.bits_per_sample);
    try testing.expectEqual(@as(i64, 2721), info.duration_us); // 60 帧 @ 22050

    var out: [256]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectEqual(@as(usize, 60), try dec.read(&out, 60, &ch));
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&mace.golden_m3m_expect), out[0..120]);
    try testing.expectEqual(@as(usize, 0), try dec.read(&out, 60, &ch)); // EOF
}

test "wav 集成: AIFC MAC6（'MAC6'）立体声端到端" {
    const data = mace.golden_m6s;
    var comm: [22]u8 = undefined;
    std.mem.writeInt(u16, comm[0..2], 2, .big); // channels
    std.mem.writeInt(u32, comm[2..6], 60, .big); // frames（每声道）
    std.mem.writeInt(u16, comm[6..8], 0, .big);
    @memcpy(comm[8..18], &extended80(22050));
    @memcpy(comm[18..22], "MAC6");
    var ssnd: [8 + 20]u8 = undefined;
    std.mem.writeInt(u32, ssnd[0..4], 0, .big);
    std.mem.writeInt(u32, ssnd[4..8], 0, .big);
    @memcpy(ssnd[8..], &data);

    const file = try buildAiff(testing.allocator, true, &.{
        .{ .id = "COMM".*, .payload = &comm },
        .{ .id = "SSND".*, .payload = &ssnd },
    });
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();
    try testing.expectEqualStrings("mace6", info.codec_name);
    try testing.expectEqual(@as(u8, 2), info.channels);
    try testing.expectEqual(@as(i64, 2721), info.duration_us); // 60 帧（每声道）@ 22050

    var out: [256]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectEqual(@as(usize, 60), try dec.read(&out, 60, &ch));
    // 交错输出：120 个交错样本 = 60 帧
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&mace.golden_m6s_expect), out[0..240]);
    try testing.expectEqual(@as(usize, 0), try dec.read(&out, 60, &ch)); // EOF
}

test "wav 集成: RIFF smpl + cue 解析（循环点/提示点）" {
    const fmt = testFmt(1, 2, 44100, 176400, 4, 16, .little);
    const pcm = [_]u8{ 0x64, 0x00, 0x38, 0xFF, 0x00, 0x01, 0xFE, 0xFF }; // 2 帧交错（8B）

    // smpl：36B 头 + 2 个循环点（各 24B）
    var smpl: [36 + 2 * 24]u8 = [_]u8{0} ** (36 + 2 * 24);
    std.mem.writeInt(u32, smpl[28..32], 2, .little); // numSampleLoops
    // loop 0：type=0 forward, start=0, end=2, playCount=0（无限）
    std.mem.writeInt(u32, smpl[36 + 4 ..][0..4], 0, .little);
    std.mem.writeInt(u32, smpl[36 + 8 ..][0..4], 0, .little);
    std.mem.writeInt(u32, smpl[36 + 12 ..][0..4], 2, .little);
    std.mem.writeInt(u32, smpl[36 + 20 ..][0..4], 0, .little);
    // loop 1：type=1 alternating, start=3, end=5, playCount=4
    std.mem.writeInt(u32, smpl[36 + 24 + 4 ..][0..4], 1, .little);
    std.mem.writeInt(u32, smpl[36 + 24 + 8 ..][0..4], 3, .little);
    std.mem.writeInt(u32, smpl[36 + 24 + 12 ..][0..4], 5, .little);
    std.mem.writeInt(u32, smpl[36 + 24 + 20 ..][0..4], 4, .little);

    // cue：4B 计数 + 2 个点（各 24B）
    var cue: [4 + 2 * 24]u8 = [_]u8{0} ** (4 + 2 * 24);
    std.mem.writeInt(u32, cue[0..4], 2, .little);
    std.mem.writeInt(u32, cue[4..8], 1001, .little); // id 1
    std.mem.writeInt(u32, cue[8..12], 7, .little); // position
    std.mem.writeInt(u32, cue[4 + 24 ..][0..4], 1002, .little); // id 2
    std.mem.writeInt(u32, cue[4 + 24 + 4 ..][0..4], 9, .little); // position

    const file = try buildRiff(testing.allocator, "RIFF", .little, &.{
        .{ .id = "fmt ".*, .payload = &fmt },
        .{ .id = "cue ".*, .payload = &cue },
        .{ .id = "smpl".*, .payload = &smpl },
        .{ .id = "data".*, .payload = &pcm },
    });
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();

    try testing.expectEqual(@as(usize, 2), info.loops.len);
    try testing.expectEqual(@as(u32, 0), info.loops[0].type);
    try testing.expectEqual(@as(u32, 0), info.loops[0].start);
    try testing.expectEqual(@as(u32, 2), info.loops[0].end);
    try testing.expectEqual(@as(u32, 0), info.loops[0].play_count);
    try testing.expectEqual(@as(u32, 1), info.loops[1].type);
    try testing.expectEqual(@as(u32, 3), info.loops[1].start);
    try testing.expectEqual(@as(u32, 5), info.loops[1].end);
    try testing.expectEqual(@as(u32, 4), info.loops[1].play_count);

    try testing.expectEqual(@as(usize, 2), info.cue_points.len);
    try testing.expectEqual(@as(u32, 1001), info.cue_points[0].id);
    try testing.expectEqual(@as(u32, 7), info.cue_points[0].position);
    try testing.expectEqual(@as(u32, 1002), info.cue_points[1].id);
    try testing.expectEqual(@as(u32, 9), info.cue_points[1].position);

    // 正常解码不受影响
    var out: [16]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectEqual(@as(usize, 2), try dec.read(&out, 2, &ch));
    try testing.expectEqualSlices(u8, &pcm, out[0..8]);
}

test "wav 畸形: smpl/cue 计数超载 → clamp 保留已解析条目" {
    const fmt = testFmt(1, 1, 8000, 16000, 2, 16, .little);
    const pcm = [_]u8{ 0x64, 0x00, 0x38, 0xFF };

    // smpl 声明 1000 个循环，但实际只有 1 个（头 36B + 1×24B）
    var smpl: [36 + 24]u8 = [_]u8{0} ** (36 + 24);
    std.mem.writeInt(u32, smpl[28..32], 1000, .little);
    std.mem.writeInt(u32, smpl[36 + 4 ..][0..4], 1, .little); // type
    std.mem.writeInt(u32, smpl[36 + 8 ..][0..4], 10, .little); // start
    std.mem.writeInt(u32, smpl[36 + 12 ..][0..4], 20, .little); // end

    // cue 声明 500 点，实际 0 点（只有 4B 计数）
    const cue = [_]u8{ 0xF4, 0x01, 0x00, 0x00 }; // 500

    const file = try buildRiff(testing.allocator, "RIFF", .little, &.{
        .{ .id = "fmt ".*, .payload = &fmt },
        .{ .id = "smpl".*, .payload = &smpl },
        .{ .id = "cue ".*, .payload = &cue },
        .{ .id = "data".*, .payload = &pcm },
    });
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();

    // smpl：声明 1000 → 实际承载 (36+24-36)/24 = 1 → 保留 1 条
    try testing.expectEqual(@as(usize, 1), info.loops.len);
    try testing.expectEqual(@as(u32, 10), info.loops[0].start);
    try testing.expectEqual(@as(u32, 20), info.loops[0].end);
    // cue：声明 500 → 实际承载 0 → 空
    try testing.expectEqual(@as(usize, 0), info.cue_points.len);
}

test "wav 集成: RIFX（大端）smpl/cue 解析" {
    // 大端字段验证：ctx.endian 应用于 smpl/cue 的字段读取
    var smpl: [36 + 24]u8 = [_]u8{0} ** (36 + 24);
    std.mem.writeInt(u32, smpl[28..32], 1, .big);
    std.mem.writeInt(u32, smpl[36 + 4 ..][0..4], 2, .big); // type=2 backward
    std.mem.writeInt(u32, smpl[36 + 8 ..][0..4], 4, .big); // start
    std.mem.writeInt(u32, smpl[36 + 12 ..][0..4], 8, .big); // end
    std.mem.writeInt(u32, smpl[36 + 20 ..][0..4], 3, .big); // playCount

    var cue: [4 + 24]u8 = [_]u8{0} ** (4 + 24);
    std.mem.writeInt(u32, cue[0..4], 1, .big);
    std.mem.writeInt(u32, cue[4..8], 77, .big); // id
    std.mem.writeInt(u32, cue[8..12], 12, .big); // position

    const fmt = testFmt(1, 1, 8000, 16000, 2, 16, .big);
    const pcm = [_]u8{ 0x64, 0x00, 0x38, 0xFF };

    const file = try buildRiff(testing.allocator, "RIFX", .big, &.{
        .{ .id = "fmt ".*, .payload = &fmt },
        .{ .id = "smpl".*, .payload = &smpl },
        .{ .id = "cue ".*, .payload = &cue },
        .{ .id = "data".*, .payload = &pcm },
    });
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();

    try testing.expectEqual(@as(usize, 1), info.loops.len);
    try testing.expectEqual(@as(u32, 2), info.loops[0].type);
    try testing.expectEqual(@as(u32, 4), info.loops[0].start);
    try testing.expectEqual(@as(u32, 8), info.loops[0].end);
    try testing.expectEqual(@as(u32, 3), info.loops[0].play_count);
    try testing.expectEqual(@as(usize, 1), info.cue_points.len);
    try testing.expectEqual(@as(u32, 77), info.cue_points[0].id);
    try testing.expectEqual(@as(u32, 12), info.cue_points[0].position);
}

// ---------------------------------------------------------------------------
// CAF / AU 容器（未压缩 PCM）集成测试
// ---------------------------------------------------------------------------

/// 32 字节 CAF `desc` payload：采样率 double BE + format_id + 5 个 u32 BE 字段
fn cafDescPayload(rate: f64, format_id: [4]u8, flags: u32, bytes_per_packet: u32, frames_per_packet: u32, channels: u32, bits: u32) [32]u8 {
    var d: [32]u8 = undefined;
    std.mem.writeInt(u64, d[0..8], @bitCast(rate), .big);
    @memcpy(d[8..12], &format_id);
    std.mem.writeInt(u32, d[12..16], flags, .big);
    std.mem.writeInt(u32, d[16..20], bytes_per_packet, .big);
    std.mem.writeInt(u32, d[20..24], frames_per_packet, .big);
    std.mem.writeInt(u32, d[24..28], channels, .big);
    std.mem.writeInt(u32, d[28..32], bits, .big);
    return d;
}

const CafChunk = struct { id: [4]u8, payload: []const u8 };

/// 构造 CAF 镜像：caff + ver/flags + 任意 chunk 序列（id + size(8 BE) + payload，无 pad）
fn buildCaf(allocator: std.mem.Allocator, chunks: []const CafChunk) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "caff");
    try buf.appendSlice(allocator, &[_]u8{ 0x00, 0x01, 0x00, 0x00 }); // version 1, flags 0
    for (chunks) |c| {
        try buf.appendSlice(allocator, &c.id);
        var sz: [8]u8 = undefined;
        std.mem.writeInt(u64, sz[0..8], c.payload.len, .big);
        try buf.appendSlice(allocator, &sz);
        try buf.appendSlice(allocator, c.payload);
    }
    return buf.toOwnedSlice(allocator);
}

/// 构造 AU 镜像：.snd + 24B 字段 + annotation（data_offset - 24）+ PCM
fn buildAu(allocator: std.mem.Allocator, encoding: u32, rate: u32, channels: u32, annotation: []const u8, data: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, ".snd");
    const data_offset: u32 = 24 + @as(u32, @intCast(annotation.len));
    var f: [4]u8 = undefined;
    std.mem.writeInt(u32, f[0..4], data_offset, .big);
    try buf.appendSlice(allocator, &f);
    std.mem.writeInt(u32, f[0..4], @intCast(data.len), .big);
    try buf.appendSlice(allocator, &f);
    std.mem.writeInt(u32, f[0..4], encoding, .big);
    try buf.appendSlice(allocator, &f);
    std.mem.writeInt(u32, f[0..4], rate, .big);
    try buf.appendSlice(allocator, &f);
    std.mem.writeInt(u32, f[0..4], channels, .big);
    try buf.appendSlice(allocator, &f);
    try buf.appendSlice(allocator, annotation);
    try buf.appendSlice(allocator, data);
    return buf.toOwnedSlice(allocator);
}

test "caf 集成: lpcm s16le mono（镜像 ffmpeg 布局：desc + chan + info + data）" {
    // data：4 帧 s16 LE
    var pcm: [8]u8 = undefined;
    const vals = [_]i16{ 1000, -1000, 2000, -2000 };
    for (vals, 0..) |v, i| std.mem.writeInt(i16, pcm[2 * i ..][0..2], v, .little);

    // desc payload：flags 0x2（LE）、bytes_per_packet 2、fpp 1、ch 1、bits 16
    const desc = cafDescPayload(44100.0, "lpcm".*, 0x2, 2, 1, 1, 16);
    var edit: [4]u8 = [_]u8{0} ** 4; // edit count 0
    const data_chunk = try std.mem.concat(testing.allocator, u8, &.{ &edit, &pcm });
    defer testing.allocator.free(data_chunk);

    const file = try buildCaf(testing.allocator, &.{
        .{ .id = "desc".*, .payload = &desc },
        .{ .id = "chan".*, .payload = &[_]u8{0} ** 12 },
        .{ .id = "info".*, .payload = &[_]u8{0} ** 16 },
        .{ .id = "data".*, .payload = data_chunk },
    });
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();

    try testing.expectEqual(@as(u32, 44100), info.sample_rate);
    try testing.expectEqual(@as(u8, 1), info.channels);
    try testing.expectEqual(@as(u8, 16), info.bits_per_sample);
    try testing.expectEqual(false, info.is_float);
    try testing.expectEqualStrings("pcm_s16le", info.codec_name);
    try testing.expectEqualStrings("caf", info.format_name);
    try testing.expectEqual(@as(i64, 90), info.duration_us); // 4 帧 @ 44100

    var out: [16]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectEqual(@as(usize, 4), try dec.read(&out, 4, &ch));
    try testing.expectEqualSlices(u8, &pcm, out[0..8]);
    try testing.expectEqual(@as(usize, 0), try dec.read(&out, 4, &ch)); // EOF
}

test "caf 集成: lpcm s16be stereo（chan 后置跳过 + 大端直出）" {
    var pcm: [8]u8 = undefined;
    const vals = [_]i16{ 1000, -1000, 2000, -2000 };
    for (vals, 0..) |v, i| std.mem.writeInt(i16, pcm[2 * i ..][0..2], v, .big);

    const desc = cafDescPayload(48000.0, "lpcm".*, 0x0, 4, 1, 2, 16);
    var edit: [4]u8 = [_]u8{0} ** 4;
    const data_chunk = try std.mem.concat(testing.allocator, u8, &.{ &edit, &pcm });
    defer testing.allocator.free(data_chunk);

    const file = try buildCaf(testing.allocator, &.{
        .{ .id = "desc".*, .payload = &desc },
        .{ .id = "data".*, .payload = data_chunk },
        .{ .id = "chan".*, .payload = &[_]u8{0} ** 12 }, // data 后仍有 chunk → 读到即停
    });
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();
    try testing.expectEqualStrings("pcm_s16be", info.codec_name);
    try testing.expectEqual(@as(u8, 2), info.channels);
    try testing.expectEqual(@as(u32, 48000), info.sample_rate);

    var out: [16]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectEqual(@as(usize, 2), try dec.read(&out, 4, &ch));
    try testing.expectEqualSlices(u8, &pcm, out[0..8]);
    try testing.expectEqual(@as(usize, 0), try dec.read(&out, 4, &ch));
}

test "caf 集成: lpcm f32le（flags 0x3 = float|LE）与 f64be（flags 0x1）" {
    // f32le mono：2 样本
    var p32: [8]u8 = undefined;
    const f32v = [_]f32{ 0.5, -1.25 };
    for (f32v, 0..) |v, i| std.mem.writeInt(u32, p32[4 * i ..][0..4], @bitCast(v), .little);
    const desc32 = cafDescPayload(8000.0, "lpcm".*, 0x3, 4, 1, 1, 32);
    var edit: [4]u8 = [_]u8{0} ** 4;
    const dc32 = try std.mem.concat(testing.allocator, u8, &.{ &edit, &p32 });
    defer testing.allocator.free(dc32);
    const file32 = try buildCaf(testing.allocator, &.{
        .{ .id = "desc".*, .payload = &desc32 },
        .{ .id = "data".*, .payload = dc32 },
    });
    defer testing.allocator.free(file32);

    var info32: decoder.Info = undefined;
    var dec32 = try openMem(testing.allocator, file32, &info32);
    defer dec32.deinit();
    try testing.expectEqual(true, info32.is_float);
    try testing.expectEqualStrings("pcm_f32le", info32.codec_name);

    var out: [8]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectEqual(@as(usize, 2), try dec32.read(&out, 2, &ch));
    try testing.expectEqualSlices(u8, &p32, &out);

    // f64be stereo：flags 0x1（float BE），bits 64
    var p64: [32]u8 = undefined;
    const f64v = [_]f64{ 0.25, -1.0, 3.0, -2.0 };
    for (f64v, 0..) |v, i| std.mem.writeInt(u64, p64[8 * i ..][0..8], @bitCast(v), .big);
    const desc64 = cafDescPayload(96000.0, "lpcm".*, 0x1, 16, 1, 2, 64);
    const dc64 = try std.mem.concat(testing.allocator, u8, &.{ &edit, &p64 });
    defer testing.allocator.free(dc64);
    const file64 = try buildCaf(testing.allocator, &.{
        .{ .id = "desc".*, .payload = &desc64 },
        .{ .id = "data".*, .payload = dc64 },
    });
    defer testing.allocator.free(file64);

    var info64: decoder.Info = undefined;
    var dec64 = try openMem(testing.allocator, file64, &info64);
    defer dec64.deinit();
    try testing.expectEqual(true, info64.is_float);
    try testing.expectEqualStrings("pcm_f64be", info64.codec_name);
    try testing.expectEqual(@as(u8, 2), info64.channels);

    var out64: [32]u8 = undefined;
    try testing.expectEqual(@as(usize, 2), try dec64.read(&out64, 4, &ch));
    try testing.expectEqualSlices(u8, p64[0..32], out64[0..32]);
}

test "caf 畸形: 非 lpcm codec（alac）→ UnsupportedFormat" {
    const desc = cafDescPayload(44100.0, "alac".*, 0, 0, 0, 2, 0);
    const file = try buildCaf(testing.allocator, &.{.{ .id = "desc".*, .payload = &desc }});
    defer testing.allocator.free(file);
    var info: decoder.Info = undefined;
    try testing.expectError(error.UnsupportedFormat, openMem(testing.allocator, file, &info));
}

test "caf 畸形: desc 可变包（fpp 0）→ UnsupportedFormat；缺 desc → Corrupt" {
    // lpcm + frames_per_packet 0（可变 → 需 pakt）
    const desc = cafDescPayload(44100.0, "lpcm".*, 0x2, 2, 0, 1, 16);
    const file = try buildCaf(testing.allocator, &.{.{ .id = "desc".*, .payload = &desc }});
    defer testing.allocator.free(file);
    var info: decoder.Info = undefined;
    try testing.expectError(error.UnsupportedFormat, openMem(testing.allocator, file, &info));

    // 首 chunk 非 desc → Corrupt
    const file2 = try buildCaf(testing.allocator, &.{.{ .id = "free".*, .payload = &[_]u8{0} ** 8 }});
    defer testing.allocator.free(file2);
    try testing.expectError(error.Corrupt, openMem(testing.allocator, file2, &info));
}

test "au 集成: s16be mono + s24be stereo（大端 PCM 直出，annotation 跳过）" {
    // s16be mono 4 帧
    var p16: [8]u8 = undefined;
    const v16 = [_]i16{ 1000, -2000, 3000, -4000 };
    for (v16, 0..) |v, i| std.mem.writeInt(i16, p16[2 * i ..][0..2], v, .big);
    const file = try buildAu(testing.allocator, 3, 44100, 1, &[_]u8{0} ** 8, &p16);
    defer testing.allocator.free(file);

    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();
    try testing.expectEqual(@as(u32, 44100), info.sample_rate);
    try testing.expectEqualStrings("pcm_s16be", info.codec_name);
    try testing.expectEqualStrings("au", info.format_name);
    try testing.expectEqual(@as(i64, 90), info.duration_us);

    var out: [8]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectEqual(@as(usize, 4), try dec.read(&out, 8, &ch));
    try testing.expectEqualSlices(u8, &p16, &out);
    try testing.expectEqual(@as(usize, 0), try dec.read(&out, 8, &ch));

    // s24be stereo 2 帧（帧字节 6）
    var p24: [12]u8 = undefined;
    const raw24 = [_]u32{ 0x123456, 0xFFFFFF, 0x007FFF, 0x800000 };
    for (raw24, 0..) |v, i| {
        p24[3 * i] = @intCast(v >> 16);
        p24[3 * i + 1] = @intCast((v >> 8) & 0xFF);
        p24[3 * i + 2] = @intCast(v & 0xFF);
    }
    const file24 = try buildAu(testing.allocator, 4, 8000, 2, &.{}, &p24);
    defer testing.allocator.free(file24);
    var info24: decoder.Info = undefined;
    var dec24 = try openMem(testing.allocator, file24, &info24);
    defer dec24.deinit();
    try testing.expectEqualStrings("pcm_s24be", info24.codec_name);
    try testing.expectEqual(@as(u8, 24), info24.bits_per_sample);
    try testing.expectEqual(@as(u8, 2), info24.channels);
    try testing.expectEqual(@as(i64, 250), info24.duration_us); // 2 帧 @ 8kHz

    var out24: [12]u8 = undefined;
    try testing.expectEqual(@as(usize, 2), try dec24.read(&out24, 8, &ch));
    try testing.expectEqualSlices(u8, &p24, &out24);
}

test "au 集成: f32be + f64be float 直通；s8 有符号 codec" {
    var pf: [8]u8 = undefined;
    const f32v = [_]f32{ 0.5, -0.25 };
    for (f32v, 0..) |v, i| std.mem.writeInt(u32, pf[4 * i ..][0..4], @bitCast(v), .big);
    const file = try buildAu(testing.allocator, 6, 48000, 1, &.{}, &pf);
    defer testing.allocator.free(file);
    var info: decoder.Info = undefined;
    var dec = try openMem(testing.allocator, file, &info);
    defer dec.deinit();
    try testing.expectEqual(true, info.is_float);
    try testing.expectEqualStrings("pcm_f32be", info.codec_name);
    var out: [8]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectEqual(@as(usize, 2), try dec.read(&out, 8, &ch));
    try testing.expectEqualSlices(u8, &pf, &out);

    // s8（encoding 2）→ pcm_s8
    const s8 = [_]u8{ 0x00, 0x7F, 0x80, 0xFF };
    const file8 = try buildAu(testing.allocator, 2, 8000, 1, &.{}, &s8);
    defer testing.allocator.free(file8);
    var info8: decoder.Info = undefined;
    var dec8 = try openMem(testing.allocator, file8, &info8);
    defer dec8.deinit();
    try testing.expectEqualStrings("pcm_s8", info8.codec_name);
    try testing.expectEqual(@as(u8, 1), info8.channels);
    var out8: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 4), try dec8.read(&out8, 8, &ch));
    try testing.expectEqualSlices(u8, &s8, out8[0..4]);
}

test "au 畸形: encoding 1（mulaw）→ UnsupportedFormat；data_size 未知 0xFFFFFFFF" {
    var p16: [4]u8 = undefined;
    std.mem.writeInt(i16, p16[0..2], 100, .big);
    std.mem.writeInt(i16, p16[2..4], -100, .big);
    const file = try buildAu(testing.allocator, 1, 8000, 1, &.{}, &p16);
    defer testing.allocator.free(file);
    var info: decoder.Info = undefined;
    try testing.expectError(error.UnsupportedFormat, openMem(testing.allocator, file, &info));

    // 手工构造 data_size = 0xFFFFFFFF（未知 → 取至文件尾）
    const file2 = try std.mem.concat(testing.allocator, u8, &.{
        ".snd\x00\x00\x00\x18\xff\xff\xff\xff\x00\x00\x00\x03\x00\x00\x1f\x40\x00\x00\x00\x01",
        &p16,
    });
    defer testing.allocator.free(file2);
    var info2: decoder.Info = undefined;
    var dec2 = try openMem(testing.allocator, file2, &info2);
    defer dec2.deinit();
    try testing.expectEqualStrings("pcm_s16be", info2.codec_name);
    var out: [8]u8 = undefined;
    var ch: u8 = 0;
    try testing.expectEqual(@as(usize, 2), try dec2.read(&out, 8, &ch));
    try testing.expectEqualSlices(u8, &p16, out[0..4]);
}
