// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! LOAS/LATM（AAC 音频传输流，`.latm`/`.loas`）容器：逐 LOAS 帧定位 +
//! AudioMuxElement/StreamMuxConfig/PayloadLengthInfo 解析，提取 raw AAC
//! 帧复用 fmt/aac/lib.zig（AAC-LC 自研解码核心），与 ADTS 同一解码核心/同一
//! 输出契约（s16 交错小端）。语义对照 FFmpeg n9.0.1 libavformat/loasdec.c +
//! libavcodec/aac/aacdec_latm.h（参考对照；许可登记见 audio-engine/THIRD-PARTY-LICENSES.md）。
//!
//! LOAS 帧：11-bit 同步字 0x2B7（24-bit 前缀 0x56E000）+ 13-bit
//! audioMuxLengthBytes（不含 3 字节帧头）；整帧 = 3 + audioMuxLengthBytes。
//! 帧内是 AudioMuxElement：
//!   - useSameStreamMux(1)；0 → 紧跟 StreamMuxConfig（音频流配置，约每 N 帧重复）；
//!   - StreamMuxConfig（audio_mux_version=0/1，AudioMuxVersionA=0）：含
//!     AudioSpecificConfig（AAC-LC/Main/LTP，直接位读取）+ frameLengthType
//!     （AAC 用 0=变长 / 1=定长）+ latmBufferFullness 等；
//!   - PayloadLengthInfo（变长字节计数，每字节值 255 续传）→ PayloadMux 载荷；
//!     AAC 载荷 = 原始 raw AAC 帧（raw_data_block，通常字节对齐，但 LATM 内
//!     起始位可不按字节对齐 → 位拷贝回对齐缓冲后喂内核）。
//!
//! 支持范围（对齐 ffmpeg aac_latm）：audio_mux_version 0/1（非 A）；
//! numProgram==0 / numLayer==0（单节目单层；多节目/多流 → UnsupportedFormat）；
//! 每元素仅解码第一个子帧（numSubFrames 后续子帧丢弃，与 ffmpeg 逐包
//! aac_decode_frame 语义一致）；frameLengthType 0（变长）/1（定长）。
//! AAC-LC/Main/LTP（AOT 1/2/4）帧复用内核；ASC 内 PCE（chan_config=0）布局、
//! ER/ELD、AudioMuxVersionA → UnsupportedFormat（回退 FFmpeg 主后端 §8.3）。
//! 采样率/声道来自 StreamMuxConfig 内 AudioSpecificConfig（与 ffprobe 一致）。
//!
//! Seek：按 LOAS 帧头顺序跳过（每元素固定 1 音频帧，1024/960 样本），无需
//! 解码即可定位；时长：LOAS 帧头跳帧计数（帧数 × 每帧样本 = exact；
//! 扫描区上限 128 MiB / 重同步失败 → 回落首帧平均帧长估算 estimate）。

const std = @import("std");
const Error = @import("../error.zig").Error;
const io = @import("../io.zig");
const decoder = @import("../decoder.zig");
const asc = @import("aac/asc.zig");
const aacmod = @import("aac/lib.zig");
const BitReader = @import("aac/bitreader.zig").BitReader;

/// audioMuxLengthBytes（13 位）上限
const max_mux_length: usize = 0x1fff;
/// 整 LOAS 帧字节上限（3 字节头 + 元素）
const max_loas_frame: usize = 3 + max_mux_length;
/// raw AAC 帧（载荷）字节上限
const max_payload: usize = max_mux_length;
/// 帧数扫描区上限（超出 → 平均帧长估算；典型 LATM 文件远小于此）
const scan_bytes_cap: u64 = 128 * 1024 * 1024;
/// 位拷贝/解码工作区（含零填充供 ESC showBits(32) 越过结尾使用）
const pad = 64;

pub const LatmCtx = struct {
    allocator: std.mem.Allocator,
    reader: io.Reader,
    aac: aacmod.Aac,

    /// 未消费的输入缓冲（跨 LOAS 帧残留）
    pending: std.ArrayList(u8),
    /// 输入是否已到 EOF
    input_eof: bool = false,

    /// 文件大小（估算时长用）
    file_size: u64 = 0,
    /// 平均每帧位数（估算时长用）
    avg_bits_per_frame: u64 = 0,

    /// 整 LOAS 帧缓冲（含零填充）
    frame_buf: [max_loas_frame + pad]u8 = undefined,
    /// raw AAC 帧载荷缓冲（位拷贝回字节对齐 + 零填充）
    payload_buf: [max_payload + pad]u8 = undefined,

    /// AAC 解码核心是否已按 SMC 配置初始化
    configured: bool = false,
    /// 最近一个 StreamMuxConfig 内的 AudioSpecificConfig
    cfg: asc.M4ACfg = .{},
    /// frameLengthType（0=变长 1=定长；AAC 只用这两种）
    frame_length_type: u8 = 0,
    /// frameLengthType==1 时的定长帧长（9 位，单位字节）
    fixed_frame_length: u16 = 0,

    /// 连续解码失败计数（超过上限放弃）
    consecutive_errors: u32 = 0,
    /// 累计跳过的坏 LOAS 帧
    skipped_frames: u64 = 0,

    pub fn deinitSelf(self: *LatmCtx) void {
        self.pending.deinit(self.allocator);
        if (self.configured) {
            self.aac.deinit(); // AAC 元素槽位/SBR 堆分配状态（out_buf 见下）
            self.aac.out_buf.deinit(self.aac.gpa);
        }
        self.reader.deinit();
        self.allocator.destroy(self);
    }
};

// ---------------- LOAS 帧头 / 定位 ----------------

/// 解析 3 字节 LOAS 帧头：同步字 0x2B7（11 位）→ audioMuxLengthBytes（13 位）。
/// 返回整帧字节数（含 3 字节头）；非法同步/长度 → null。
fn loasFrameTotal(buf: []const u8) ?usize {
    if (buf.len < 3) return null;
    const w: u24 = @intCast((@as(u32, buf[0]) << 16) | (@as(u32, buf[1]) << 8) | buf[2]);
    if ((w & 0xFFE000) != 0x56E000) return null; // 0x2B7 << 13
    const len: usize = w & 0x1FFF;
    // ffmpeg loas_probe：帧长 = len + 3 ≥ 7（len ≥ 4）才判合法
    if (len < 4) return null;
    return len + 3;
}

/// 在 buf[off..] 查找下一个 LOAS 同步帧头，返回其偏移（未找到返回 null）。
fn findLoasSync(buf: []const u8, off: usize) ?usize {
    var i = off;
    while (i + 3 <= buf.len) : (i += 1) {
        if (loasFrameTotal(buf[i..])) |_| return i;
    }
    return null;
}

const FrameInfo = struct {
    /// 整帧字节数（3 + audioMuxLengthBytes）
    total: usize,
};

/// 前移 pending 1 字节（丢弃伪同步/垃圾）
fn dropOneByte(ctx: *LatmCtx) void {
    const items = ctx.pending.items;
    if (items.len > 1) std.mem.copyForwards(u8, items[0 .. items.len - 1], items[1..]);
    ctx.pending.shrinkRetainingCapacity(ctx.pending.items.len - 1);
}

/// 消耗 fi（从 pending 头移除整帧）
fn consumeFrame(ctx: *LatmCtx, fi: FrameInfo) void {
    const items = ctx.pending.items;
    const total = fi.total;
    if (total >= items.len) {
        ctx.pending.clearRetainingCapacity();
        return;
    }
    std.mem.copyForwards(u8, items[0 .. items.len - total], items[total..]);
    ctx.pending.shrinkRetainingCapacity(ctx.pending.items.len - total);
}

/// 确保缓冲内有一个完整 LOAS 帧（相对 pending 头）；返回帧信息或 null（EOF）。
fn fillNextFrame(ctx: *LatmCtx) Error!?FrameInfo {
    while (true) {
        if (ctx.pending.items.len >= 3) {
            if (loasFrameTotal(ctx.pending.items[0..3])) |total| {
                if (total > max_loas_frame) return error.Corrupt; // 不可能（13 位）
                if (ctx.pending.items.len >= total) return .{ .total = total };
            } else {
                // 头 3 字节非法 → 伪同步/垃圾：前移 1 字节重找
                dropOneByte(ctx);
                continue;
            }
        }
        // 补读数据
        if (!ctx.input_eof) {
            var tmp: [16 * 1024]u8 = undefined;
            const n = ctx.reader.read(&tmp) catch |e| switch (e) {
                error.Aborted => return e,
                else => 0,
            };
            if (n == 0) {
                ctx.input_eof = true;
                if (findLoasSync(ctx.pending.items, 0) == null) return null;
                continue;
            }
            try ctx.pending.appendSlice(ctx.allocator, tmp[0..n]);
            continue;
        }
        return null;
    }
}

// ---------------- StreamMuxConfig / PayloadLengthInfo ----------------

/// ISO 14496-3 §1.7.3.2.5 latm_get_value：2 位长度头 + (len+1)*8 位值。
fn latmGetValue(br: *BitReader) Error!u32 {
    const length = try br.readBits(2);
    return br.readBits(@intCast((length + 1) * 8));
}

/// 支持的 AAC AOT（内核：LC/Main/LTP）
fn supportedObjectType(ot: u8) bool {
    return ot == asc.AOT_AAC_LC or ot == asc.AOT_AAC_MAIN or ot == asc.AOT_AAC_LTP;
}

/// 校验解析出的 ASC 配置（对象类型 + chan_config 需内核可解码）
fn validateCfg(cfg: asc.M4ACfg) Error!void {
    if (!supportedObjectType(cfg.object_type)) return error.UnsupportedFormat;
    // chan_config==0：布局由 ASC 内 PCE 定义（LATM 的 GA 特定配置含 PCE）。
    // 内核仅支持 chan_config 非 0 的 ASC 配置 → 回退 FFmpeg。
    if (cfg.chan_config == 0) return error.UnsupportedFormat;
}

/// 读取 audio_mux_version==1 时带长度前缀的 ASC：位拷贝 asclen 字节到对齐
/// 缓冲后用 asc.parseAsc（sync_extension=1，对齐 ffmpeg asclen>0 分支）。
fn parseAscBounded(ctx: *LatmCtx, br: *BitReader, asclen: u32) Error!void {
    var tmp: [512]u8 = undefined;
    if (asclen == 0 or asclen > tmp.len) return error.UnsupportedFormat;
    for (0..asclen) |i| {
        tmp[i] = @intCast(try br.readBits(8));
    }
    const r = try asc.parseAsc(tmp[0..asclen], true);
    ctx.cfg = r.cfg;
}

/// 解析 StreamMuxConfig（br 位于 audio_mux_version 位）。语义对照
/// ffmpeg read_stream_mux_config：audio_mux_version / version_A、
/// taraFullness（v1）、allStreamsSameTimeFraming、numSubFrames、numProgram
/// （≠0 → 不支持）、numLayer（≠0 → 不支持）、AudioSpecificConfig、
/// frameLengthType、latmBufferFullness / 定长、otherData、config_crc。
fn parseStreamMuxConfig(ctx: *LatmCtx, br: *BitReader) Error!void {
    const ver = (try br.readBits(1)) != 0;
    var ver_a = false;
    if (ver) ver_a = (try br.readBits(1)) != 0;
    // AudioMuxVersionA（MuxConfigPresent 变体）不在此解码（对齐 ffmpeg）
    if (ver_a) return error.UnsupportedFormat;
    if (ver) _ = try latmGetValue(br); // taraFullness

    _ = try br.readBits(1); // allStreamsSameTimeFraming
    _ = try br.readBits(6); // numSubFrames（仅解首个子帧，对齐 ffmpeg）
    const num_program = try br.readBits(4);
    if (num_program != 0) return error.UnsupportedFormat; // 多节目
    const num_layer = try br.readBits(3);
    if (num_layer != 0) return error.UnsupportedFormat; // 多层

    if (!ver) {
        // audio_mux_version==0：ASC 无长度前缀、无 sync_extension 扫描
        // （对齐 ffmpeg asclen==0 → sync_extension=0），按 GA 特配置结束即止
        const r = try asc.parseAscBr(br, false);
        ctx.cfg = r.cfg;
    } else {
        const asclen = try latmGetValue(br);
        try parseAscBounded(ctx, br, asclen);
    }
    try validateCfg(ctx.cfg);

    ctx.frame_length_type = @intCast(try br.readBits(3));
    switch (ctx.frame_length_type) {
        0 => _ = try br.readBits(8), // latmBufferFullness
        1 => ctx.fixed_frame_length = @intCast(try br.readBits(9)),
        // 3..7 为 CELP/HVXC 等非 AAC 码流；frameLengthType 2 未用
        else => return error.UnsupportedFormat,
    }

    if ((try br.readBits(1)) != 0) { // other data present
        if (ver) {
            _ = try latmGetValue(br); // other_data_bits
        } else {
            var guard: u32 = 0;
            while (true) {
                guard += 1;
                if (guard > 64 or br.remainingBits() < 9) return error.Corrupt;
                const esc = try br.readBits(1);
                _ = try br.readBits(8);
                if (esc == 0) break;
            }
        }
    }
    if ((try br.readBits(1)) != 0) _ = try br.readBits(8); // config_crc
}

/// PayloadLengthInfo → mux_slot_length_bytes（本元素首子帧 AAC 载荷字节数）。
/// frameLengthType 0：逐 8 位字节求和直到字节 ≠ 255（255 续传）。
/// frameLengthType 1：定长。语义对照 ffmpeg read_payload_length_info。
fn readPayloadLengthInfo(ctx: *LatmCtx, br: *BitReader) Error!u32 {
    if (ctx.frame_length_type == 0) {
        var mux_slot_length: u32 = 0;
        while (true) {
            const tmp = try br.readBits(8);
            mux_slot_length += tmp;
            if (tmp != 255) break;
            if (mux_slot_length > max_payload) return error.Corrupt;
        }
        if (mux_slot_length > max_payload) return error.Corrupt;
        return mux_slot_length;
    } else {
        return ctx.fixed_frame_length;
    }
}

// ---------------- 元素解析 + 解码 ----------------

/// 比较两次 SMC 配置是否一致（内核解码关心的字段）
fn cfgChanged(a: asc.M4ACfg, b: asc.M4ACfg) bool {
    return a.object_type != b.object_type or
        a.sample_rate != b.sample_rate or
        a.sampling_index != b.sampling_index or
        a.chan_config != b.chan_config or
        a.frame_length_short != b.frame_length_short;
}

/// 以新配置（重）初始化 AAC 内核；已配置时保留已解码输出缓冲（跨配置变更不丢）。
fn initAac(ctx: *LatmCtx, cfg: asc.M4ACfg) Error!void {
    const aac = &ctx.aac;
    const was_configured = ctx.configured;
    var out_buf: std.ArrayList(u8) = .empty;
    var out_pos: usize = 0;
    var pos_samples: u64 = 0;
    if (was_configured) {
        out_buf = aac.out_buf;
        out_pos = aac.out_pos;
        pos_samples = aac.pos_samples;
    }
    aac.initCommon(ctx.allocator, cfg) catch |e| {
        if (was_configured) {
            aac.out_buf = out_buf;
            aac.out_pos = out_pos;
        }
        return e;
    };
    aac.out_buf = out_buf;
    aac.out_pos = out_pos;
    aac.pos_samples = pos_samples;
    ctx.configured = true;
}

/// 处理一个已就位（frame_buf + br@bit24）的 AudioMuxElement。
/// `decoded` 输出本元素是否产出了音频（含配置不齐时跳过）。
fn processElement(ctx: *LatmCtx, br: *BitReader, decoded: *bool) Error!void {
    const use_same_mux = (try br.readBits(1)) != 0;
    if (!use_same_mux) {
        // 本元素携带 StreamMuxConfig
        try parseStreamMuxConfig(ctx, br);
        if (ctx.configured) {
            // 配置重复/变更：一致则不动；变更则按新配置重初始化
            if (cfgChanged(ctx.cfg, ctx.aac.cfg)) try initAac(ctx, ctx.cfg);
        } else {
            try initAac(ctx, ctx.cfg);
        }
    } else if (!ctx.configured) {
        // use_same_mux=1 但尚无配置（mid-stream 起播）：跳过本元素（不产输出）
        return;
    }

    // PayloadLengthInfo → 首子帧载荷字节数
    const mux_bytes = try readPayloadLengthInfo(ctx, br);
    if (mux_bytes == 0 or mux_bytes > max_payload) return error.Corrupt;

    // 位拷贝 AAC 载荷回字节对齐缓冲（LATM 内载荷起始位可不按字节对齐）
    var i: usize = 0;
    while (i < mux_bytes) : (i += 1) {
        ctx.payload_buf[i] = @intCast(try br.readBits(8));
    }
    @memset(ctx.payload_buf[mux_bytes .. mux_bytes + pad], 0);

    var br2 = BitReader.init(ctx.payload_buf[0 .. mux_bytes + pad]);
    try ctx.aac.decodeFrame(&br2);
    decoded.* = true;
}

/// 解码一帧（一个 LOAS 帧）。返回 false = EOF。坏帧计数上限内吞掉继续。
fn decodeOneFrame(ctx: *LatmCtx) Error!bool {
    const fi = (try fillNextFrame(ctx)) orelse return false;
    defer consumeFrame(ctx, fi);

    const src = ctx.pending.items[0..fi.total];
    @memcpy(ctx.frame_buf[0..fi.total], src);
    @memset(ctx.frame_buf[fi.total .. fi.total + pad], 0);

    var br = BitReader.init(ctx.frame_buf[0 .. fi.total + pad]);
    _ = try br.readBits(24); // LOAS 帧头（同步字 + audioMuxLengthBytes）

    var decoded = false;
    processElement(ctx, &br, &decoded) catch |e| switch (e) {
        error.Aborted, error.OutOfMemory => return e,
        else => {
            // 坏帧：丢弃输出、保留容器状态，跳到下一帧（对齐 ADTS §13.3）；
            // 连续失败超限才上报
            ctx.aac.out_pos = 0;
            ctx.aac.out_buf.clearRetainingCapacity();
            ctx.skipped_frames += 1;
            ctx.consecutive_errors += 1;
            if (ctx.consecutive_errors > 16) return e;
        },
    };
    ctx.consecutive_errors = 0;
    return true;
}

// ---------------- VTable ----------------

fn readImpl(opaque_ctx: *anyopaque, out: []u8, max_samples: usize, out_channels: *u8) Error!usize {
    const ctx: *LatmCtx = @ptrCast(@alignCast(opaque_ctx));
    out_channels.* = ctx.aac.channels;
    if (max_samples == 0 or out.len == 0) return 0;

    var produced: usize = 0;
    var dst_off: usize = 0;
    var frame_bytes: usize = @as(usize, ctx.aac.channels) * 2;

    while (produced < max_samples) {
        const avail_bytes = ctx.aac.out_buf.items.len - ctx.aac.out_pos;
        if (avail_bytes == 0) {
            ctx.aac.out_pos = 0;
            ctx.aac.out_buf.clearRetainingCapacity();
            if (!try decodeOneFrame(ctx)) break; // EOF
            if (@as(usize, ctx.aac.channels) * 2 != frame_bytes) {
                frame_bytes = @as(usize, ctx.aac.channels) * 2;
                out_channels.* = ctx.aac.channels;
            }
            continue;
        }
        if (frame_bytes == 0) break;
        const want_frames = @min(
            (out.len - dst_off) / frame_bytes,
            max_samples - produced,
        );
        if (want_frames == 0) break;
        const take_bytes = @min(avail_bytes, want_frames * frame_bytes);
        @memcpy(out[dst_off .. dst_off + take_bytes], ctx.aac.out_buf.items[ctx.aac.out_pos .. ctx.aac.out_pos + take_bytes]);
        ctx.aac.out_pos += take_bytes;
        dst_off += take_bytes;
        produced += take_bytes / frame_bytes;
    }
    return produced;
}

fn positionMsImpl(opaque_ctx: *anyopaque) i64 {
    const ctx: *LatmCtx = @ptrCast(@alignCast(opaque_ctx));
    if (ctx.aac.sample_rate == 0) return 0;
    const ms = @divTrunc(@as(i128, @intCast(ctx.aac.pos_samples)) * 1000, @as(i128, ctx.aac.sample_rate));
    return @intCast(ms);
}

fn seekMsImpl(opaque_ctx: *anyopaque, ms: i64) Error!void {
    const ctx: *LatmCtx = @ptrCast(@alignCast(opaque_ctx));
    if (ms <= 0) {
        ctx.reader.seek(0, .start) catch {};
        ctx.pending.clearRetainingCapacity();
        ctx.input_eof = false;
        ctx.aac.pos_samples = 0;
        ctx.aac.out_pos = 0;
        ctx.aac.out_buf.clearRetainingCapacity();
        return;
    }

    const target_sample: u128 = @intCast(@divTrunc(@as(i128, ms) * ctx.aac.sample_rate, 1000));
    const cur: u128 = ctx.aac.pos_samples;
    if (target_sample <= cur) {
        ctx.reader.seek(0, .start) catch {};
        ctx.pending.clearRetainingCapacity();
        ctx.input_eof = false;
        ctx.aac.pos_samples = 0;
        ctx.aac.out_pos = 0;
        ctx.aac.out_buf.clearRetainingCapacity();
    }

    // 逐 LOAS 帧头推进到目标帧边界（每元素固定 1 音频帧）
    var guard: u32 = 0;
    while (@as(u128, ctx.aac.pos_samples) < target_sample) {
        guard += 1;
        if (guard > 10_000_000) return error.SeekFailed;
        const fi = (try fillNextFrame(ctx)) orelse break;
        consumeFrame(ctx, fi);
        ctx.aac.pos_samples += ctx.aac.frame_samples;
    }

    ctx.aac.out_pos = 0;
    ctx.aac.out_buf.clearRetainingCapacity();
}

fn deinitImpl(opaque_ctx: *anyopaque) void {
    const ctx: *LatmCtx = @ptrCast(@alignCast(opaque_ctx));
    ctx.deinitSelf();
}

const vtable = decoder.Decoder.VTable{
    .read = readImpl,
    .seek_ms = seekMsImpl,
    .position_ms = positionMsImpl,
    .deinit = deinitImpl,
};

// ---------------- 打开 ----------------

/// 扫描 pending 中连续完整 LOAS 帧，估算平均每帧位数（0 = 样本不足）。
fn estimateBitsPerFrame(ctx: *LatmCtx) u64 {
    var off: usize = 0;
    var frames: u32 = 0;
    var bytes: u64 = 0;
    while (frames < 64 and off + 3 <= ctx.pending.items.len) : (frames += 1) {
        const total = loasFrameTotal(ctx.pending.items[off..]) orelse break;
        if (ctx.pending.items.len < off + total) break;
        off += total;
        bytes += total;
    }
    if (frames == 0) return 0;
    return bytes * 8 / frames;
}

pub fn open(allocator: std.mem.Allocator, reader: *io.Reader, info: *decoder.Info) Error!decoder.Decoder {
    const ctx = try allocator.create(LatmCtx);
    errdefer allocator.destroy(ctx);
    ctx.* = .{
        .allocator = allocator,
        .reader = reader.*,
        .pending = .empty,
        .aac = .{}, // 定义基线：重型状态指针为 null（initCommon 前 deinit 安全）
    };
    errdefer ctx.pending.deinit(allocator);
    ctx.file_size = reader.size() catch 0;

    // 预扫：逐 LOAS 帧找首个 StreamMuxConfig（use_same_mux=0），提取 ASC
    // 初始化内核。正常文件配置在首帧；mid-stream 起播可后移若干帧。
    var guard: u32 = 0;
    var found = false;
    while (true) {
        const fi = (try fillNextFrame(ctx)) orelse break; // EOF，无配置
        guard += 1;
        if (guard > 2048) break;

        const src = ctx.pending.items[0..fi.total];
        @memcpy(ctx.frame_buf[0..fi.total], src);
        @memset(ctx.frame_buf[fi.total .. fi.total + pad], 0);
        var br = BitReader.init(ctx.frame_buf[0 .. fi.total + pad]);
        _ = try br.readBits(24);
        const use_same_mux = (try br.readBits(1)) != 0;
        if (!use_same_mux) {
            // 不支持/损坏的首个配置 → 明确回退（open 即失败，FFmpeg 主后端）
            try parseStreamMuxConfig(ctx, &br);
            found = true;
            break;
        }
        // 无配置元素：跳到下一帧继续找
        consumeFrame(ctx, fi);
    }
    if (!found) return error.UnsupportedFormat;

    ctx.avg_bits_per_frame = estimateBitsPerFrame(ctx);
    try initAac(ctx, ctx.cfg);

    // 重绕：解码从头开始（预扫可能已跨过若干无配置帧/前导垃圾）
    ctx.reader.seek(0, .start) catch {};
    ctx.pending.clearRetainingCapacity();
    ctx.input_eof = false;
    ctx.aac.out_pos = 0;
    ctx.aac.out_buf.clearRetainingCapacity();

    // 时长：LOAS 跳帧计数（每元素解码输出 1 个 AAC 帧 = frame_samples 样本
    // —— numSubFrames>1 的后续子帧按 ffmpeg 语义丢弃）。扫描不可靠时回落
    // 平均帧长估算。SBR 下输出样本数与采样率同时 ×2，时长不变。
    var duration_us: i64 = -1;
    var known: decoder.DurationKnown = .unknown;
    var frames: ?u64 = null;
    if (ctx.file_size > 0 and ctx.file_size <= scan_bytes_cap and ctx.aac.frame_samples > 0) {
        frames = countLoasFrames(&ctx.reader, ctx.reader.pos, ctx.file_size);
    }
    if (frames) |nf| {
        duration_us = @intCast(nf * @as(u64, ctx.aac.frame_samples) * 1_000_000 / ctx.aac.sample_rate);
        known = .exact;
    } else {
        // 时长估算：平均帧长 × 采样率/帧样本
        ctx.avg_bits_per_frame = estimateBitsPerFrame(ctx);
        if (ctx.file_size > 0 and ctx.avg_bits_per_frame > 0 and ctx.aac.sample_rate > 0) {
            const frame_samples: u64 = ctx.aac.frame_samples;
            // bytes*8 每帧 bit → 帧数 = file_size/avg_bytes；样本数 = 帧数*frame_samples
            const total_samples = ctx.file_size * frame_samples * 8 / ctx.avg_bits_per_frame;
            if (total_samples > 0) {
                duration_us = @intCast(total_samples * 1_000_000 / ctx.aac.sample_rate);
                known = .estimate;
            }
        }
    }

    info.* = .{
        .sample_rate = if (ctx.aac.sbr_enabled) ctx.aac.sample_rate * 2 else ctx.aac.sample_rate,
        .channels = ctx.aac.channels,
        .bits_per_sample = 16,
        .is_float = false,
        .duration_us = duration_us,
        .duration_known = known,
        .codec_name = "aac",
        .format_name = "latm",
        .metadata = .{},
    };
    return .{ .vtable = &vtable, .ctx = @ptrCast(ctx) };
}

/// LOAS 跳帧计数（chunked 顺序扫描；伪同步重同步；截断尾帧不计，与解码
/// 路径一致）。成功/失败均恢复读位置到 start_pos；不可靠 → null。
fn countLoasFrames(reader: *io.Reader, start_pos: u64, file_size: u64) ?u64 {
    var buf: [64 * 1024]u8 = undefined;
    var have: usize = 0; // buf[0..have] = 文件偏移 scan_pos 起的未消费字节
    var scan_pos: u64 = start_pos;
    var frames: u64 = 0;
    while (true) {
        if (have == 0) {
            if (scan_pos >= file_size) break;
            reader.seek(@intCast(scan_pos), .start) catch return null;
            have = reader.read(&buf) catch return null;
            if (have == 0) break; // EOF
        }
        const total = loasFrameTotal(buf[0..have]) orelse {
            // 伪同步/垃圾：窗口内找下一 LOAS 同步；找不到 → 放弃扫描
            const off = findLoasSync(buf[0..have], 1) orelse return null;
            scan_pos += off;
            std.mem.copyForwards(u8, buf[0 .. have - off], buf[off..have]);
            have -= off;
            continue;
        };
        if (@as(u64, total) > @as(u64, have)) {
            // 跨块补读一次；EOF 仍不完整 → 尾帧不计（与解码路径一致）
            reader.seek(@intCast(scan_pos + have), .start) catch return null;
            const n = reader.read(buf[have..]) catch return null;
            if (n == 0) break;
            have += n;
            if (@as(u64, total) > @as(u64, have)) break;
        }
        frames += 1;
        scan_pos += total;
        std.mem.copyForwards(u8, buf[0 .. have - total], buf[total..have]);
        have -= total;
    }
    reader.seek(@intCast(start_pos), .start) catch return null;
    return frames;
}

// ---------------- 测试 ----------------

const testing = std.testing;

/// 测试用 MSB-first 位写入器
const BitWriter = struct {
    buf: [4096]u8 = [_]u8{0} ** 4096,
    pos: usize = 0,

    fn put(self: *BitWriter, value: u64, n: u8) void {
        var k: u8 = n;
        while (k > 0) {
            k -= 1;
            const bit: u1 = @intCast((value >> @intCast(k)) & 1);
            if (bit == 1) self.buf[self.pos >> 3] |= @as(u8, 1) << @intCast(7 - (self.pos & 7));
            self.pos += 1;
        }
    }

    fn bytes(self: *const BitWriter) []const u8 {
        return self.buf[0 .. (self.pos + 7) / 8];
    }
};

/// 合成一个 audio_mux_version=0 的 StreamMuxConfig + 变长 PayloadLengthInfo，
/// 返回字节切片（写入 w.buf）。
fn synthSmcPayload(w: *BitWriter, payload_len: usize) void {
    w.put(0, 1); // use_same_mux=0
    w.put(0, 1); // audio_mux_version=0
    w.put(1, 1); // allStreamsSameTimeFraming
    w.put(0, 6); // numSubFrames
    w.put(0, 4); // numProgram
    w.put(0, 3); // numLayer
    // ASC：AAC-LC 44.1kHz 立体声（object_type 5b=2, sf_idx 4b=4, chan 4b=2,
    // frameShort 1b=0, depends 1b=0, ext 1b=0）
    w.put(2, 5);
    w.put(4, 4);
    w.put(2, 4);
    w.put(0, 1);
    w.put(0, 1);
    w.put(0, 1);
    w.put(0, 3); // frameLengthType=0
    w.put(0xff, 8); // latmBufferFullness
    w.put(0, 1); // otherDataPresent
    w.put(0, 1); // crcCheckPresent
    // PayloadLengthInfo（变长）
    var rem = payload_len;
    while (rem >= 255) : (rem -= 255) w.put(255, 8);
    w.put(rem, 8);
    // 末尾补几个零字节作为 AAC 载荷占位（供解析测试确认位对齐）
    w.put(0, 32);
}

test "LOAS 帧头: 同步字 + audioMuxLengthBytes 解析" {
    // 0x2B7<<13 | 0x0140 → 56 E1 40；整帧 = 3 + 0x140 = 323
    const hdr = [_]u8{ 0x56, 0xe1, 0x40 };
    try testing.expectEqual(@as(?usize, 323), loasFrameTotal(&hdr));
    // 同步字错位 / 长度过小 → null
    try testing.expectEqual(@as(?usize, null), loasFrameTotal("\x57\xe1\x40"));
    try testing.expectEqual(@as(?usize, null), loasFrameTotal("\x56\xe0\x00"));
    // 找同步（垃圾前缀）
    var data: [4 + 3]u8 = undefined;
    @memcpy(data[0..4], "JUNK");
    @memcpy(data[4..7], &hdr);
    try testing.expectEqual(@as(?usize, 4), findLoasSync(&data, 0));
}

test "SMC 解析: 合成 StreamMuxConfig + PayloadLengthInfo 位对齐" {
    var w: BitWriter = .{};
    synthSmcPayload(&w, 235);

    // 从位流中解析出配置：构造 ctx（仅 cfg/frame_length_type 字段被 parse 使用）
    var ctx: LatmCtx = undefined;
    ctx.frame_length_type = 0;
    ctx.fixed_frame_length = 0;
    var br = BitReader.init(w.bytes());
    try testing.expectEqual(@as(u32, 0), try br.readBits(1)); // use_same_mux
    try parseStreamMuxConfig(&ctx, &br);

    try testing.expectEqual(@as(u8, asc.AOT_AAC_LC), ctx.cfg.object_type);
    try testing.expectEqual(@as(u32, 44100), ctx.cfg.sample_rate);
    try testing.expectEqual(@as(u4, 2), ctx.cfg.chan_config);
    try testing.expectEqual(@as(u16, 1024), ctx.cfg.frame_length);
    try testing.expectEqual(@as(u8, 0), ctx.frame_length_type);

    const len = try readPayloadLengthInfo(&ctx, &br);
    try testing.expectEqual(@as(u32, 235), len);
    // 已精确消费：之后位即 AAC 载荷首字节（全 0 合成）
    try testing.expectEqual(@as(u32, 0), try br.readBits(8));
}

test "SMC 解析: 变长 PayloadLengthInfo 跨 255 续传" {
    // payload_len = 700 = 255 + 255 + 190
    var w: BitWriter = .{};
    synthSmcPayload(&w, 700);
    var ctx: LatmCtx = undefined;
    ctx.frame_length_type = 0;
    ctx.fixed_frame_length = 0;
    var br = BitReader.init(w.bytes());
    _ = try br.readBits(1);
    try parseStreamMuxConfig(&ctx, &br);
    try testing.expectEqual(@as(u32, 700), try readPayloadLengthInfo(&ctx, &br));
}

test "SMC 解析: 多节目/多层/变体 → UnsupportedFormat" {
    // numProgram = 1 → 拒绝
    var w: BitWriter = .{};
    w.put(0, 1); // use_same
    w.put(0, 1); // version
    w.put(1, 1); // sameTime
    w.put(0, 6); // nsf
    w.put(1, 4); // numProgram != 0
    var br = BitReader.init(w.bytes());
    var ctx: LatmCtx = undefined;
    try testing.expectError(error.UnsupportedFormat, parseStreamMuxConfig(&ctx, &br));
}

// ---------------- 端到端（真实样本，golden 来自系统 ffmpeg n9.0.1） ----------------

const e2e_mono = @embedFile("latm_tiny_mono.latm");
const e2e_mono_golden = @embedFile("latm_tiny_mono.s16");
const e2e_stereo = @embedFile("latm_tiny_stereo.latm");
const e2e_stereo_golden = @embedFile("latm_tiny_stereo.s16");

const E2e = struct { sr: u32, ch: u8, samples: usize, corr: f64, bit_exact: f64 };

fn runE2e(input: []const u8, golden: []const u8) !E2e {
    var info: decoder.Info = undefined;
    var reader = io.Reader.openMem(input);
    var dec = try open(testing.allocator, &reader, &info);
    defer dec.deinit();

    var mine = std.ArrayList(i16).empty;
    defer mine.deinit(testing.allocator);
    var buf: [65536]u8 = undefined;
    while (true) {
        var ch: u8 = 0;
        const n = try dec.read(&buf, 4096, &ch);
        if (n == 0) break;
        const bytes = n * @as(usize, ch) * 2;
        const samples = try mine.addManyAsSlice(testing.allocator, bytes / 2);
        for (0..bytes / 2) |k| {
            samples[k] = std.mem.readInt(i16, buf[k * 2 ..][0..2], .little);
        }
    }
    const ns = mine.items.len;
    const ng = golden.len / 2;
    const limit = @min(ns, ng);
    var equal: usize = 0;
    var sum_num: f64 = 0;
    var sum_a2: f64 = 0;
    var sum_b2: f64 = 0;
    for (0..limit) |i| {
        const gv = std.mem.readInt(i16, golden[i * 2 ..][0..2], .little);
        const mv = mine.items[i];
        if (gv == mv) equal += 1;
        sum_num += @as(f64, @floatFromInt(gv)) * @as(f64, @floatFromInt(mv));
        sum_a2 += @as(f64, @floatFromInt(gv)) * @as(f64, @floatFromInt(gv));
        sum_b2 += @as(f64, @floatFromInt(mv)) * @as(f64, @floatFromInt(mv));
    }
    const corr = if (sum_a2 > 0 and sum_b2 > 0) sum_num / @sqrt(sum_a2 * sum_b2) else 1.0;
    return .{
        .sr = info.sample_rate,
        .ch = info.channels,
        .samples = ns,
        .corr = corr,
        .bit_exact = 100.0 * @as(f64, @floatFromInt(equal)) / @as(f64, @floatFromInt(limit)),
    };
}

test "latm e2e: mono 44.1kHz == ffmpeg（含重复 StreamMuxConfig）" {
    const r = try runE2e(e2e_mono, e2e_mono_golden);
    try std.testing.expectEqual(@as(u32, 44100), r.sr);
    try std.testing.expectEqual(@as(u8, 1), r.ch);
    try testing.expect(r.corr > 0.999999);
    try testing.expect(r.bit_exact > 99.9);
}

test "latm e2e: stereo 48kHz == ffmpeg" {
    const r = try runE2e(e2e_stereo, e2e_stereo_golden);
    try std.testing.expectEqual(@as(u32, 48000), r.sr);
    try std.testing.expectEqual(@as(u8, 2), r.ch);
    try testing.expect(r.corr > 0.999999);
    try testing.expect(r.bit_exact > 99.9);
}

test "latm e2e: probe 识别 + Info 元数据" {
    var info: decoder.Info = undefined;
    var reader = io.Reader.openMem(e2e_mono);
    var dec = try open(testing.allocator, &reader, &info);
    defer dec.deinit();
    try testing.expectEqualStrings("aac", info.codec_name);
    try testing.expectEqualStrings("latm", info.format_name);
    try testing.expectEqual(@as(u8, 16), info.bits_per_sample);
    try testing.expectEqual(false, info.is_float);
    // 时长 exact：跳帧计数 = 28 帧 × 1024 = 28672 样本 → 650158µs（28672e6/44100）
    try testing.expectEqual(decoder.DurationKnown.exact, info.duration_known);
    try testing.expectEqual(@as(i64, 650_158), info.duration_us);
}

test "latm e2e: seek 300ms → 余量解码 ≈ 未 seek 全量 − 目标" {
    const total = blk: {
        var info: decoder.Info = undefined;
        var reader = io.Reader.openMem(e2e_mono);
        var dec = try open(testing.allocator, &reader, &info);
        defer dec.deinit();
        var buf: [4096]u8 = undefined;
        var sum: usize = 0;
        while (true) {
            var ch: u8 = 0;
            const n = try dec.read(&buf, 2048, &ch);
            if (n == 0) break;
            sum += n;
        }
        break :blk sum;
    };
    try testing.expectEqual(@as(usize, 28672), total);

    var info: decoder.Info = undefined;
    var reader = io.Reader.openMem(e2e_mono);
    var dec = try open(testing.allocator, &reader, &info);
    defer dec.deinit();

    try dec.seekMs(300);
    const pos = dec.positionMs();
    try testing.expect(pos >= 250 and pos <= 320);

    var buf: [4096]u8 = undefined;
    var sum: usize = 0;
    while (true) {
        var ch: u8 = 0;
        const n = try dec.read(&buf, 2048, &ch);
        if (n == 0) break;
        sum += n;
    }
    // 300ms @ 44.1kHz ≈ 13230 样本 → 剩余 ≈ 15442（帧对齐后 ±1 帧 1024）
    const s: i64 = @intCast(sum);
    var rem_diff: i64 = s - 15442;
    if (rem_diff < 0) rem_diff = -rem_diff;
    try testing.expect(rem_diff <= 1024);
    // 读完应到达文件末（position ≈ 650ms ±40ms）
    const end_pos = dec.positionMs();
    try testing.expect(end_pos > 600 and end_pos < 690);
}
