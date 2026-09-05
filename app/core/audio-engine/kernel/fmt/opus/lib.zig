//! Opus 解码器封装（open + VTable + Ogg 解复用 + SILK/CELT/HYBRID + 重采样 + 输出）
//!
//! 输出契约：48kHz、s16、交错 PCM（opus 原生位深 16），与 FFmpeg `-c:a libopus -f s16le`
//! 对照（±1 LSB 容差，见 docs/audio-kernel-zig.md §9.2）。
//!
//! 帧循环语义（对齐 libopus `opus_decoder.c` / `silk/dec_API.c`）：
//!   - 每帧新建区间解码器（SILK 帧 / CELT 帧独立 `ec_dec`），hybrid 的 CELT 在同一
//!     `ec_dec` 上续解；
//!   - SILK：内部 8/12/16k 解码 → 固定 resampler 升采样到 48k；喂入采用 dec_API
//!     `&samplesOut1_tmp[n][1]` 语义（首样本 = 上一帧末样本 sMid/sSide[1]，丢弃本帧末样本）；
//!   - HYBRID：SILK 升采样到 48k 后，同一 `ec_dec` 续解 CELT HP（start_band=17）
//!     以定点 `ADD_RES(pcm, SIG2RES(celt_sig))` 语义累加（±1 LSB）；
//!   - CELT：直接 48k f32 输出 → s16。
//!   - 冗余位（opus_decoder.c:501-528）：`dec_log(12)` + celt_to_silk + `dec_uint(256)`
//!     + `dec.storage -= redundancy_bytes`（`BitReader.limit` / `RawBits.bytes` 收缩）。
//!
//! pre-skip / end-trim：OpusHead.pre_skip 起始丢弃；末页 granule（含 pre_skip）决定
//! 整轨样本数，超出的尾样本丢弃。输出增益（Q7.8）按 libopus `celt_exp2` 浮点公式应用。

const std = @import("std");
const Error = @import("../../error.zig").Error;
const io = @import("../../io.zig");
const decoder = @import("../../decoder.zig");
const ogg = @import("../ogg.zig");
const opus_header = @import("header.zig");
const opus_packet = @import("packet.zig");
const rcmod = @import("rc.zig");
const silk = @import("silk.zig");
const celt = @import("celt.zig");
const celt_types = @import("celt_types.zig");
const tables = @import("celt_tables.zig");

const VTable = decoder.Decoder.VTable;
const OpusHead = opus_header.Head;

/// 单包最大交错样本（CELT 2.5ms×48 帧×2ch = 11520）
const PCM_MAX = 48 * 120 * 2;
/// SILK 内部单帧最大样本（16k 60ms = 960）
const SILK_MAX_FRAME = 960;
/// 单帧 48k 单声道最大样本（60ms = 2880）
const CH48_MAX = 2880;

/// Opus 解码上下文
const OpusCtx = struct {
    allocator: std.mem.Allocator,
    demux: ogg.Demux,
    head: OpusHead,
    channels: u8,
    /// 已输出样本总数（自文件开头计，position_ms 依据）
    samples_done: u64 = 0,
    /// pre-skip 剩余待丢弃样本
    pre_skip_left: u64 = 0,
    /// 整轨有效样本数（final_granule - pre_skip；EOS 后确定，0 = 未知）
    total_valid: u64 = 0,
    eos: bool = false,
    /// 上一帧 SILK 末样本（dec_API sMid[1] / sSide[1] 喂入）
    dec0: silk.DecoderState = .{},
    dec1: silk.DecoderState = .{},
    sst: silk.StereoDecState = .{},
    rsm: [2]silk.ResamplerState = undefined,
    celt_f: celt_types.CeltFrame = undefined,
    /// 标签元数据（OpusTags 解析；deinit 释放）
    meta: decoder.Metadata = .{},
    prev_mode: u8 = 255,
    prev_redundancy: bool = false,
    prev_frame_size: u32 = 960,
    prev_stereo: bool = false,
    cur_red_info: RedundancyInfo = .{},
    /// 当前包解码缓冲（交错 s16）
    pcm_buf: [PCM_MAX]i16 = undefined,
    pcm_len: usize = 0,
    pcm_pos: usize = 0,
    /// 单帧 48k 单声道缓冲（SILK/HYBRID 通道升采样暂存）
    ch48: [2][CH48_MAX]i16 = undefined,
    /// 当前帧内部 SILK 采样率（kHz）
    silk_fs_khz: i32 = 16,
    frame_size: u32 = 960,
    /// 当前包 config（toc>>3）
    config: u8 = 9,
    stereo: bool = false,
    prev_last: i16 = 0,
    side_inited: bool = false,
    pkt_counter: usize = 0,
    lost_at: usize = 0,
    lost_count: usize = 1,
    decoded_any: bool = false,
    dbgRsm: usize = 0,
    dbHy: usize = 0,
};

/// 测试辅助：设置丢包帧号（SILK 包，1 基）。0 = 不丢包。
pub fn setLostAt(ctx: *anyopaque, n: usize) void {
    const f: *OpusCtx = @ptrCast(@alignCast(ctx));
    f.lost_at = n;
}

/// 测试辅助：设置连续丢包数（默认 1）。
pub fn setLostCount(ctx: *anyopaque, n: usize) void {
    const f: *OpusCtx = @ptrCast(@alignCast(ctx));
    f.lost_count = n;
}

/// 打开 Opus 解码器（Ogg 容器）。reader 按值持有（deinit 关闭）。
pub fn open(allocator: std.mem.Allocator, reader: *io.Reader, info: *decoder.Info) Error!decoder.Decoder {
    const f = try allocator.create(OpusCtx);
    errdefer allocator.destroy(f);
    f.* = .{
        .allocator = allocator,
        .demux = undefined,
        .head = undefined,
        .channels = 1,
    };
    f.demux = .{ .allocator = allocator, .reader = reader.* };
    errdefer f.demux.deinit();

    const head_pkt = (try f.demux.nextPacket()) orelse return error.Corrupt;
    if (head_pkt.continued) return error.Corrupt;
    f.head = try opus_header.parseHead(head_pkt.data);
    // OpusTags（RFC 7845 §5.2：vendor + N×"KEY=value"，Vorbis comment 布局）
    if (try f.demux.nextPacket()) |tags_pkt| {
        parseOpusTags(f, allocator, tags_pkt.data) catch {};
    }

    for (0..2) |i| _ = silk.resamplerInit(&f.rsm[i], 16000, 48000);
    f.celt_f.flush();
    f.celt_f.output_channels = @intCast(f.head.channels);
    f.channels = f.head.channels;
    f.pre_skip_left = f.head.pre_skip;

    // 时长：尾窗扫描末页 granule（对齐 FFmpeg ogg_get_length 的尾窗策略；
    // seek 不可用（callback 流）→ 保持 unknown）。granule 含 pre-skip
    // （RFC 7845 §4：granule = 已解码 PCM 样本总数），有效时长 =
    // granule − pre_skip；末页带 EOS → exact，EOS 页缺失/损坏（尾窗内
    // 只有非 EOS 完整页）→ 退末页 granule 估计（.estimate）。
    // 极短流（单音频页首末同页）天然命中该页。granule 上限防伪页误匹配。
    var duration_us: i64 = 0;
    var duration_known: decoder.DurationKnown = .unknown;
    if ((ogg.scanTailPage(&f.demux.reader, f.demux.serial) catch null)) |tail| {
        if (tail.granule > 0) {
            // 时长取 granule（含 pre-skip 区间）以对齐 ffprobe/ffmpeg 的容器时长
            // 语义与 Stable 引擎显示；有效样本数（granule−pre_skip）仍由
            // pre_skip_left 在解码侧消费，二者职责分离。
            if (tail.granule < 48000 * 12 * 3600) {
                const g: u64 = @intCast(tail.granule);
                duration_us = @intCast((@as(u128, g) * 1_000_000) / 48000);
                duration_known = if (tail.eos) .exact else .estimate;
            }
        }
    }

    info.* = .{
        .sample_rate = 48000,
        .channels = f.head.channels,
        .bits_per_sample = 16,
        .is_float = false,
        .duration_us = duration_us,
        .duration_known = duration_known,
        .codec_name = "opus",
        .format_name = "ogg",
        .metadata = f.meta,
    };
    return .{ .vtable = &vtable, .ctx = f };
}

const vtable = VTable{
    .read = readImpl,
    .seek_ms = seekMsImpl,
    .position_ms = positionMsImpl,
    .deinit = deinitImpl,
};

// ---- VTable 实现 ----

fn readImpl(ctx: *anyopaque, out: []u8, max_samples: usize, out_channels: *u8) Error!usize {
    const f: *OpusCtx = @ptrCast(@alignCast(ctx));
    out_channels.* = f.channels;
    if (max_samples == 0 or out.len == 0) return 0;

    const frame_bytes = @as(usize, f.channels) * 2;
    const cap = @min(max_samples, out.len / frame_bytes);
    var produced: usize = 0;
    while (produced < cap) {
        if (f.pcm_pos >= f.pcm_len) {
            if (!try decodeNextPacket(f)) break;
        }
        while (produced < cap and f.pcm_pos < f.pcm_len) {
            if (f.pre_skip_left > 0) {
                f.pre_skip_left -= 1;
                f.pcm_pos += 1;
                continue;
            }
            if (f.total_valid != 0 and f.samples_done >= f.total_valid) {
                f.pcm_pos = f.pcm_len;
                break;
            }
            const si = f.pcm_pos * @as(usize, f.channels);

            const dst = out[produced * frame_bytes ..][0..frame_bytes];
            @memcpy(dst, std.mem.sliceAsBytes(f.pcm_buf[si .. si + f.channels]));
            f.pcm_pos += 1;
            f.samples_done += 1;
            produced += 1;
        }
    }
    return produced;
}

/// 解码下一个包到 pcm_buf（交错 s16）。EOF → false。
fn decodeNextPacket(f: *OpusCtx) Error!bool {
    const pkt = (try f.demux.nextPacket()) orelse {
        if (!f.eos) {
            f.eos = true;
        }
        f.total_valid = satSub(f.demux.final_granule, f.head.pre_skip);
        return false;
    };
    if (pkt.continued) return error.Corrupt;
    if (f.demux.eos) {
        f.eos = true;
        f.total_valid = satSub(f.demux.final_granule, f.head.pre_skip);
    }
    if (pkt.data.len >= 8 and std.mem.eql(u8, pkt.data[0..8], opus_header.HEAD_MAGIC)) return true;
    if (pkt.data.len >= 8 and std.mem.eql(u8, pkt.data[0..8], opus_header.TAGS_MAGIC)) return true;

    const pp = try opus_packet.parse(pkt.data);

    f.frame_size = pp.frame_size;
    f.config = pp.config;
    f.stereo = pp.stereo;
    f.pcm_len = 0;
    f.pcm_pos = 0;

    switch (pp.mode) {
        opus_packet.MODE_SILK => {
            f.pkt_counter += 1;
            if (f.lost_at != 0 and f.pkt_counter >= f.lost_at and f.pkt_counter < f.lost_at + f.lost_count) {
                const save_stereo = f.stereo;
                f.stereo = f.prev_stereo;
                try prepSilk(f, f.prev_frame_size, 16);
                try decodeLostFrame(f);
                f.stereo = save_stereo;
            } else {
                try decodeSilkPacket(f, &pp);
                f.decoded_any = true;
            }
        },
        opus_packet.MODE_HYBRID => {
            try decodeHybridPacket(f, &pp);
            f.decoded_any = true;
        },
        else => {
            try decodeCeltPacket(f, &pp);
            f.decoded_any = true;
        },
    }
    f.prev_mode = pp.mode;
    if (pp.mode == opus_packet.MODE_HYBRID or pp.mode == opus_packet.MODE_SILK) {
        f.prev_redundancy = f.cur_red_info.has and !f.cur_red_info.celt_to_silk;
    } else {
        f.prev_redundancy = false;
    }
    const lost_this = f.lost_at != 0 and f.pkt_counter >= f.lost_at and f.pkt_counter < f.lost_at + f.lost_count;
    if (!lost_this) {
        f.prev_frame_size = pp.frame_size;
        f.prev_stereo = f.stereo;
    }
    if (f.pcm_len != 0) applyGain(f, f.pcm_buf[0..f.pcm_len]);
    return true;
}

/// SILK-only：内部 fs 依带宽（NB 8k / MB 12k / WB 16k），逐帧解码 + 逐帧升采样。
fn decodeSilkPacket(f: *OpusCtx, pp: *const opus_packet.Packet) Error!void {
    const fs_khz: i32 = switch (pp.bandwidth) {
        .nb => 8,
        .mb => 12,
        else => 16,
    };
    try prepSilk(f, pp.frame_size, fs_khz);
    for (0..pp.count) |fi| {
        try decodeSilkFrame(f, pp.frames[fi].data, false);
    }
}

/// HYBRID：SILK LP 升采样到 48k，再在同一 ec_dec 上续解 CELT HP 并累加。
fn decodeHybridPacket(f: *OpusCtx, pp: *const opus_packet.Packet) Error!void {
    try prepSilk(f, pp.frame_size, 16);
    for (0..pp.count) |fi| {
        try decodeSilkFrame(f, pp.frames[fi].data, true);
    }
}

/// SILK 帧：解码 16k → 逐声道升采样到 ch48（48k）。
/// `hybrid`：先暂存不发射（等 CELT 累加后 interleave）；否则直接 interleave 到 pcm_buf。
fn decodeSilkFrame(f: *OpusCtx, data: []const u8, hybrid: bool) Error!void {
    var rc = rcmod.Rc.decInit(data);
    rc.decRawInit(data, @intCast(data.len));
    const fl: usize = @intCast(f.dec0.frame_length);
    const nfpp: usize = @intCast(f.dec0.n_frames_per_packet);
    const per_out = fl * (48 / @as(usize, @intCast(f.silk_fs_khz))); // 每子帧 48k 输出样本
    var total_out: usize = 0;
    for (0..nfpp) |_| {
        var out_l: [SILK_MAX_FRAME + 2]i16 = undefined;
        var out_r: [SILK_MAX_FRAME + 2]i16 = undefined;
        if (f.stereo) {
            silk.decodePacketStereo(&f.dec0, &f.dec1, &f.sst, &rc, out_l[0 .. fl + 2], out_r[0 .. fl + 2]);
            _ = try resampleChannelInto(f, 0, total_out, out_l[1 .. fl + 1]);
            _ = try resampleChannelInto(f, 1, total_out, out_r[1 .. fl + 1]);
        } else {
            silk.decodePacket(&f.dec0, &rc, out_l[0..fl]);
            var rsm_in: [SILK_MAX_FRAME]i16 = undefined;
            rsm_in[0] = f.prev_last;
            @memcpy(rsm_in[1..fl], out_l[0 .. fl - 1]);
            f.prev_last = out_l[fl - 1];
            f.sst.s_mid[0] = out_l[fl - 2];
            f.sst.s_mid[1] = out_l[fl - 1];
            _ = try resampleChannelInto(f, 0, total_out, rsm_in[0..fl]);
        }
        total_out += per_out;
    }
    const out_len = total_out;
    if (hybrid) {
        // 冗余位（opus_decoder.c:501-528）后在同一 ec_dec 上续解 CELT HP
        const red_info = decodeRedundancy(f, &rc, data.len);
        f.cur_red_info = red_info;

        const end_band = celtEndBand(f.config);
        var out_f: [2][960]f32 = undefined;

        const n_ch = celt.decodeFrame(&f.celt_f, &rc, .{ out_f[0][0..f.frame_size], out_f[1][0..f.frame_size] }, @intCast(@as(usize, 1) + @intFromBool(f.stereo)), f.frame_size, 17, end_band, true) catch |e| return e;

        for (0..@intCast(n_ch)) |c| {
            for (0..out_len) |i| {
                const sum_f = @as(f32, @floatFromInt(f.ch48[c][i])) * (1.0 / 32768.0) + out_f[c][i];
                f.ch48[c][i] = f32ToS16(sum_f);
            }
        }
        if (red_info.has and !red_info.celt_to_silk) {
            try decodeSilkToCeltRedundant(f, data, red_info);
        }
        interleaveOut(f, out_len);
    } else {
        interleaveOut(f, out_len);
    }
}

/// 丢包隐藏帧：silk.PLC 生成 16k → 升采样到 48k → 发射。
/// 首个包即丢（尚无前帧，libopus prev_mode==0）→ 输出全零帧。
fn decodeLostFrame(f: *OpusCtx) Error!void {
    const fl: usize = @intCast(f.dec0.frame_length);
    const nfpp: usize = @intCast(f.dec0.n_frames_per_packet);
    const per_out = fl * (48 / @as(usize, @intCast(f.silk_fs_khz)));
    if (!f.decoded_any) {
        // 首包即丢（libopus prev_mode==0）：opus_demo 用 last_packet_duration=0
        // 调用 → 输出 0 样本，不产生 PLC 帧。
        f.decoded_any = true;
        interleaveOut(f, 0);
        return;
    }
    var total_out: usize = 0;
    for (0..nfpp) |_| {
        var out_l: [SILK_MAX_FRAME + 2]i16 = undefined;
        var out_r: [SILK_MAX_FRAME + 2]i16 = undefined;
        if (f.stereo) {
            if (f.decoded_any) {
                silk.decodeLostFrameStereo(&f.dec0, &f.dec1, &f.sst, out_l[0 .. fl + 2], out_r[0 .. fl + 2]);
            } else {
                @memset(out_l[0 .. fl + 2], 0);
                @memset(out_r[0 .. fl + 2], 0);
            }
            f.decoded_any = true;
            _ = try resampleChannelInto(f, 0, total_out, out_l[1 .. fl + 1]);
            _ = try resampleChannelInto(f, 1, total_out, out_r[1 .. fl + 1]);
        } else {
            if (!f.decoded_any) {
                @memset(out_l[0..fl], 0);
            } else {
                silk.decodeLostFrame(&f.dec0, out_l[0..fl]);
            }
            f.decoded_any = true;
            var rsm_in: [SILK_MAX_FRAME]i16 = undefined;
            rsm_in[0] = f.prev_last;
            @memcpy(rsm_in[1..fl], out_l[0 .. fl - 1]);
            f.prev_last = out_l[fl - 1];
            f.sst.s_mid[0] = out_l[fl - 2];
            f.sst.s_mid[1] = out_l[fl - 1];
            _ = try resampleChannelInto(f, 0, total_out, rsm_in[0..fl]);
        }
        total_out += per_out;
    }
    interleaveOut(f, total_out);
}

/// 逐声道升采样。silk16 为 dec_API `&samplesOut1_tmp[n][1]` 的 320 输入
/// （mono：{decoded[319]_prev, decoded[0..318]}；stereo：{x1[1], L[0..318]}）。
fn resampleChannelInto(f: *OpusCtx, ch: usize, dst_off: usize, silk16: []const i16) Error!usize {
    const fl = silk16.len;
    var rsm_buf: [SILK_MAX_FRAME]i16 = undefined;
    @memcpy(rsm_buf[0..fl], silk16);
    const out_len = fl * (48 / @as(usize, @intCast(f.silk_fs_khz)));
    _ = silk.resampler(&f.rsm[ch], f.ch48[ch][dst_off .. dst_off + out_len], rsm_buf[0..fl], @intCast(fl));
    return out_len;
}

/// 冗余位（opus_decoder.c:501-528）：`dec_log(12)` + celt_to_silk + `dec_uint(256)`
/// + storage 收缩。
const RedundancyInfo = struct {
    has: bool = false,
    celt_to_silk: bool = false,
    bytes: usize = 0,
};

fn decodeRedundancy(_: *OpusCtx, rc: *rcmod.Rc, frame_bytes: usize) RedundancyInfo {
    var info = RedundancyInfo{};
    const total = @as(i32, @intCast(frame_bytes * 8));
    if (@as(i32, @intCast(rc.tell())) + 17 + 20 <= total) {
        const redundancy = @as(i32, @intCast(rc.decLog(12)));
        if (redundancy != 0) {
            const celt_to_silk = @as(i32, @intCast(rc.decLog(1)));
            const rb = @as(i32, @intCast(rc.decUint(256))) + 2;
            rc.gb.limit = (frame_bytes - @as(usize, @intCast(rb))) * 8;
            rc.rb.bytes -%= @intCast(rb);
            info.has = true;
            info.celt_to_silk = celt_to_silk != 0;
            info.bytes = @intCast(rb);

        }
    }
    return info;
}

/// SILK→CELT 转换的 5ms 冗余帧（libopus opus_decoder.c "5 ms redundant frame for SILK->CELT"）：
/// RESET CELT + start_band=0 解码冗余字节，smooth_fade 混合进 pcm 尾部，
/// 并留下 CELT 状态供下一帧（prev_redundancy 抑制 reset）使用。
fn decodeSilkToCeltRedundant(f: *OpusCtx, data: []const u8, info: RedundancyInfo) Error!void {
    const red_data = data[data.len - info.bytes ..];
    f.celt_f.flush();
    f.celt_f.output_channels = @intCast(f.channels);
    var rrc = rcmod.Rc.decInit(red_data);
    rrc.decRawInit(red_data, @intCast(red_data.len));
    const end_band = celtEndBand(f.config);
    var red_f: [2][240]f32 = undefined;
    const n_ch = celt.decodeFrame(&f.celt_f, &rrc, .{ red_f[0][0..240], red_f[1][0..240] }, @intCast(@as(usize, 1) + @intFromBool(f.stereo)), 240, 0, end_band, false) catch |e| return e;

    const out_len: usize = 960;
    const f2_5: usize = 120;
    for (0..@intCast(n_ch)) |c| {
        for (0..f2_5) |i| {
            const w = tables.ff_celt_window[i] * tables.ff_celt_window[i];
            const idx = out_len - f2_5 + i;
            const a = @as(f32, @floatFromInt(f.ch48[c][idx])) * (1.0 / 32768.0);
            const b = red_f[c][f2_5 + i];
            const v = w * b + (1.0 - w) * a;

            f.ch48[c][idx] = f32ToS16(v);
        }
    }
}

/// CELT-only：逐帧 48k f32 → s16。
fn decodeCeltPacket(f: *OpusCtx, pp: *const opus_packet.Packet) Error!void {
    if (f.prev_mode != opus_packet.MODE_CELT and !f.prev_redundancy) {
        f.celt_f.flush();
        f.celt_f.output_channels = @intCast(f.channels);
    }
    const end_band = celtEndBand(pp.config);
    var written: usize = 0;
    for (0..pp.count) |fi| {
        var rc = rcmod.Rc.decInit(pp.frames[fi].data);
        rc.decRawInit(pp.frames[fi].data, @intCast(pp.frames[fi].data.len));
        var out_f: [2][960]f32 = undefined;
        const n_ch = celt.decodeFrame(&f.celt_f, &rc, .{ out_f[0][0..pp.frame_size], out_f[1][0..pp.frame_size] }, @intCast(@as(usize, 1) + @intFromBool(pp.stereo)), pp.frame_size, 0, end_band, false) catch |e| return e;

        for (0..pp.frame_size) |i| {
            for (0..f.channels) |c| {
                const src: usize = if (c < n_ch) c else 0;
                f.pcm_buf[(written + i) * f.channels + c] = f32ToS16(out_f[src][i]);
            }
        }

        written += pp.frame_size;
    }
    f.pcm_len = written;

}
/// 当前帧 interleave：ch48 各声道 → pcm_buf 交错追加。
/// 输出声道 = f.channels（OpusHead）；流为 mono（stereo=false）时复制 ch0 到全部输出声道。
fn interleaveOut(f: *OpusCtx, out_len: usize) void {
    const nch: usize = if (f.stereo) 2 else 1;
    for (0..out_len) |i| {
        for (0..f.channels) |c| {
            const src: usize = if (c < nch) c else 0;
            f.pcm_buf[f.pcm_len * f.channels + i * f.channels + c] = f.ch48[src][i];
        }
    }
    f.pcm_len += out_len;
}

/// SILK 帧前导（对齐 dec_API 每包一次）：帧数/子帧数/内部采样率。
fn prepSilk(f: *OpusCtx, frame_size: u32, fs_khz: i32) Error!void {
    f.dec0.n_frames_decoded = 0;
    // libopus opus_decode_frame：payloadSize_ms = IMAX(10, 1000*frame_size/Fs)，
    // silk_Decode 按 20ms 子帧循环（nFramesPerPacket = frame_size/960，10ms 帧 1 个 nb=2）。
    const nfpp: i32 = switch (frame_size) {
        480 => 1, // 10ms：nb_subfr=2
        960 => 1, // 20ms
        1920 => 2, // 40ms
        else => 3, // 60ms
    };
    const nb_subfr: i32 = if (frame_size == 480) 2 else 4;
    f.dec0.n_frames_per_packet = nfpp;
    f.dec0.nb_subfr = nb_subfr;
    if (f.silk_fs_khz != fs_khz) {
        f.silk_fs_khz = fs_khz;
        for (0..2) |i| _ = silk.resamplerInit(&f.rsm[i], fs_khz * 1000, 48000);
    }
    _ = silk.decoderSetFs(&f.dec0, fs_khz, 48000);
    if (f.stereo) {
        if (!f.side_inited) {
            f.dec1 = .{};
            f.rsm[1] = f.rsm[0];
            f.side_inited = true;
        }
        f.dec1.n_frames_decoded = 0;
        f.dec1.n_frames_per_packet = nfpp;
        f.dec1.nb_subfr = nb_subfr;
        _ = silk.decoderSetFs(&f.dec1, fs_khz, 48000);
    }
}

/// 输出增益（Q7.8，libopus celt_exp2 浮点公式）。
fn applyGain(f: *OpusCtx, pcm: []i16) void {
    if (f.head.output_gain == 0) return;
    const g = std.math.pow(f32, 2.0, 6.48814081e-4 * @as(f32, f.head.output_gain) / 32768.0);
    for (pcm) |*v| {
        const x = @as(f32, v.*) * g;
        v.* = if (x > 32767.0) 32767 else if (x < -32768.0) -32768 else @intFromFloat(x);
    }
}

fn f32ToS16(v: f32) i16 {
    if (!std.math.isFinite(v)) return 0;
    // libopus s16 链：RES2INT24(v)=float2int(8388608*v)（截断）→ clamp ±0x007fff00 → (s+128)>>8
    var s: i32 = @intFromFloat(8388608.0 * v);
    if (s > 0x007fff00) s = 0x007fff00;
    if (s < -0x007fff00) s = -0x007fff00;
    return @intCast((s + 128) >> 8);
}

fn satSub(granule: i64, pre_skip: u16) u64 {
    const g: i64 = @max(granule - @as(i64, pre_skip), 0);
    return @intCast(g);
}

fn seekMsImpl(ctx: *anyopaque, ms_arg: i64) Error!void {
    const f: *OpusCtx = @ptrCast(@alignCast(ctx));
    const ms: i64 = if (ms_arg < 0) 0 else ms_arg;
    const target_samples: u64 = @intCast((@as(u128, @intCast(ms)) * 48000) / 1000);

    // 重置解码器状态
    f.dec0 = .{};
    f.dec1 = .{};
    f.pcm_pos = 0;
    f.pcm_len = 0;
    f.eos = false;
    f.total_valid = 0;

    // 页定位：granule ≥ 目标的页（granule 含 pre-skip）
    const target_granule: i64 = @as(i64, @intCast(target_samples)) + @as(i64, @intCast(f.head.pre_skip));
    const prev_granule = try f.demux.seekToGranule(target_granule);
    const ps: i64 = @as(i64, @intCast(f.head.pre_skip));
    // 该页起始输出样本（不含 pre-skip；可能为负 = 页仍在 pre-skip 内）
    const start_out: i64 = prev_granule - ps;
    const start_out_u: u64 = if (start_out >= 0) @intCast(start_out) else 0;
    f.pre_skip_left = if (prev_granule < ps) @intCast(ps - prev_granule) else 0;
    f.samples_done = start_out_u;

    // 从该页解码跳过到目标样本
    var skip: i64 = @as(i64, @intCast(target_samples)) - @as(i64, @intCast(start_out_u));
    if (skip < 0) skip = 0;
    var guard: usize = 0;
    while (skip > 0) : (guard += 1) {
        if (guard > 2_000_000) return error.Corrupt;
        if (!try decodeNextPacket(f)) break;
        while (f.pcm_pos < f.pcm_len and skip > 0) {
            if (f.pre_skip_left > 0) {
                f.pre_skip_left -= 1;
            } else {
                f.samples_done += 1;
                skip -= 1;
            }
            f.pcm_pos += 1;
        }
    }
}

fn positionMsImpl(ctx: *anyopaque) i64 {
    const f: *OpusCtx = @ptrCast(@alignCast(ctx));
    return @intCast((@as(u128, f.samples_done) * 1000) / 48000);
}

fn deinitImpl(ctx: *anyopaque) void {
    const f: *OpusCtx = @ptrCast(@alignCast(ctx));
    freeMeta(f.allocator, &f.meta);
    f.demux.deinit();
    f.allocator.destroy(f);
}

// ---------------------------------------------------------------------------
// OpusTags（RFC 7845 §5.2）：vendor + N × "KEY=value"（Vorbis comment 布局 LE）
// ---------------------------------------------------------------------------

const MetaField = enum { title, artist, album, date, genre, comment };

fn commentFieldOf(key: []const u8) ?MetaField {
    if (std.ascii.eqlIgnoreCase(key, "TITLE")) return .title;
    if (std.ascii.eqlIgnoreCase(key, "ARTIST")) return .artist;
    if (std.ascii.eqlIgnoreCase(key, "ALBUM")) return .album;
    if (std.ascii.eqlIgnoreCase(key, "DATE")) return .date;
    if (std.ascii.eqlIgnoreCase(key, "GENRE")) return .genre;
    if (std.ascii.eqlIgnoreCase(key, "COMMENT")) return .comment;
    if (std.ascii.eqlIgnoreCase(key, "DESCRIPTION")) return .comment;
    return null;
}

fn setMetaField(meta: *decoder.Metadata, field: MetaField, s: [:0]const u8) bool {
    switch (field) {
        .title => {
            if (meta.title != null) return false;
            meta.title = s;
        },
        .artist => {
            if (meta.artist != null) return false;
            meta.artist = s;
        },
        .album => {
            if (meta.album != null) return false;
            meta.album = s;
        },
        .date => {
            if (meta.date != null) return false;
            meta.date = s;
        },
        .genre => {
            if (meta.genre != null) return false;
            meta.genre = s;
        },
        .comment => {
            if (meta.comment != null) return false;
            meta.comment = s;
        },
    }
    return true;
}

fn freeMeta(allocator: std.mem.Allocator, meta: *decoder.Metadata) void {
    inline for (.{ &meta.title, &meta.artist, &meta.album, &meta.date, &meta.genre, &meta.comment }) |f| {
        if (f.*) |s| {
            allocator.free(s);
            f.* = null;
        }
    }
    if (meta.tags.len > 0) {
        for (meta.tags) |t| {
            allocator.free(t.key);
            allocator.free(t.value);
        }
        allocator.free(meta.tags);
        meta.tags = &.{};
    }
}

/// 解析 OpusTags 包（容错：越界/畸形 → 保留已解析部分，不报 Corrupt）。
fn parseOpusTags(f: *OpusCtx, allocator: std.mem.Allocator, data: []const u8) Error!void {
    if (data.len < 8 or !std.mem.eql(u8, data[0..8], "OpusTags")) return;
    var pos: usize = 8;
    if (pos + 4 > data.len) return;
    const vendor_len: usize = std.mem.readInt(u32, data[pos..][0..4], .little);
    pos += 4;
    pos += @min(vendor_len, data.len -| pos);
    if (pos + 4 > data.len) return;
    const list_len: u32 = std.mem.readInt(u32, data[pos..][0..4], .little);
    pos += 4;

    var tags: std.ArrayList(decoder.Tag) = .empty;
    errdefer {
        for (tags.items) |t| {
            allocator.free(t.key);
            allocator.free(t.value);
        }
        tags.deinit(allocator);
    }
    var i: u32 = 0;
    while (i < list_len) : (i += 1) {
        if (pos + 4 > data.len) break;
        const slen: usize = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;
        if (slen > data.len -| pos) break;
        const entry = data[pos .. pos + slen];
        pos += slen;
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (eq == 0) continue;
        const key = entry[0..eq];
        const value = std.mem.trim(u8, entry[eq + 1 ..], " \t\r\n\x00");
        if (value.len == 0) continue;

        const k = try allocator.dupe(u8, key);
        errdefer allocator.free(k);
        const v = try allocator.dupe(u8, value);
        errdefer allocator.free(v);
        try tags.append(allocator, .{ .key = k, .value = v });

        const field = commentFieldOf(key) orelse continue;
        const s = try allocator.dupeZ(u8, value);
        if (!setMetaField(&f.meta, field, s)) allocator.free(s);
    }
    f.meta.tags = try tags.toOwnedSlice(allocator);
}

/// CELT end band（hybrid config 12-15 与 CELT-only 16-31 共用映射）
fn celtEndBand(config: u8) usize {
    if (config < 14) return 19;
    if (config < 16) return 21;
    if (config < 20) return 13;
    if (config < 24) return 17;
    if (config < 28) return 19;
    return 21;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

/// ffmpeg libopus 生成（0.5s 440Hz 正弦 48k mono，32kbps）：3 页
/// （OpusHead / OpusTags / 单音频 EOS 页 granule 24312，pre_skip 312）
/// —— 单音频页首末同页的极短流形态。
const tiny_opus = @embedFile("samples/tiny.opus");

/// ffmpeg libopus 生成（2.013s 440Hz 正弦 48k mono）：5 页（头/标签/3 音频页，
/// 末页 EOS granule 96936，pre_skip 312）—— 常规多页流形态。
const multi_opus = @embedFile("samples/multi.opus");

/// 末页（OggS）起始偏移（测试构造截断/损坏变体用）
fn lastPageStart(data: []const u8) usize {
    var last: usize = 0;
    var i: usize = 0;
    while (i + 4 <= data.len) : (i += 1) {
        if (std.mem.eql(u8, data[i..][0..4], "OggS")) last = i;
    }
    return last;
}

fn openInfo(data: []const u8, info: *decoder.Info) Error!decoder.Decoder {
    var reader = io.Reader.openMem(data);
    return open(testing.allocator, &reader, info);
}

test "opus: open Info 时长（尾页 granule（含 pre-skip，对齐 ffprobe），EOS exact）" {
    var info: decoder.Info = undefined;
    var dc = try openInfo(tiny_opus, &info);
    defer dc.deinit();
    try testing.expectEqual(decoder.DurationKnown.exact, info.duration_known);
    // granule 24312 − pre_skip 312 = 24000 样本 @48k = 0.5s
    try testing.expectEqual(@as(i64, 506_500), info.duration_us);
    // 扫描不污染读取：open 后解码正常产出
    var buf: [9600]u8 = undefined;
    var ch: u8 = 0;
    var total: usize = 0;
    while (true) {
        const n = try dc.read(&buf, buf.len / 2 / 2, &ch);
        if (n == 0) break;
        total += n;
        if (total > 48000 * 10) break;
    }
    try testing.expect(total > 20000); // ≈0.5s 单声道

    // 多页流：granule 96936 − pre_skip 312 = 96624 @48k = 2.013s
    var info2: decoder.Info = undefined;
    var dc2 = try openInfo(multi_opus, &info2);
    defer dc2.deinit();
    try testing.expectEqual(decoder.DurationKnown.exact, info2.duration_known);
    try testing.expectEqual(@as(i64, 2_019_500), info2.duration_us);
}

test "opus: EOS 页缺失 → estimate 降级且时长非零" {
    const cut = lastPageStart(multi_opus); // 砍掉 EOS 音频页
    try testing.expect(cut > 100);
    var info: decoder.Info = undefined;
    var dc = try openInfo(multi_opus[0..cut], &info);
    defer dc.deinit();
    // 前一音频页 granule 仍可用 → estimate
    try testing.expectEqual(decoder.DurationKnown.estimate, info.duration_known);
    try testing.expect(info.duration_us > 0 and info.duration_us < 2_013_000);
}

test "opus: 尾页损坏 → estimate 降级（退前一音频页）" {
    const corrupted = try testing.allocator.dupe(u8, multi_opus);
    defer testing.allocator.free(corrupted);
    corrupted[corrupted.len - 10] ^= 0xFF; // 破坏末页 CRC → parsePage 拒绝
    var info: decoder.Info = undefined;
    var dc = try openInfo(corrupted, &info);
    defer dc.deinit();
    try testing.expectEqual(decoder.DurationKnown.estimate, info.duration_known);
    try testing.expect(info.duration_us > 0);
}

test "opus: 极短流尾页损坏且无音频页可退 → unknown 不破坏 open" {
    const corrupted = try testing.allocator.dupe(u8, tiny_opus);
    defer testing.allocator.free(corrupted);
    corrupted[corrupted.len - 10] ^= 0xFF;
    var info: decoder.Info = undefined;
    var dc = try openInfo(corrupted, &info);
    defer dc.deinit();
    // 单音频页即 EOS 页：损坏后无可退音频页（前页 granule=0）→ unknown
    try testing.expectEqual(decoder.DurationKnown.unknown, info.duration_known);
    try testing.expectEqual(@as(i64, 0), info.duration_us);
}
