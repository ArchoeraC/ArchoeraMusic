// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Ogg-Speex（.spx）解码入口（Ogg 容器 + Speex CELP，mode 0/1/2 = NB/WB/UWB）。
//!
//! 对照移植 FFmpeg `libavcodec/speexdec.c`（n9.0.1 native `speex`，浮点路径）+
//! `libavformat/oggparsespeex.c`（容器映射）。核心解码见 `decode.zig`，码本见
//! `data.zig`（自 speexdata.h 逐值转录）。
//!
//! 语义要点：
//!   - 头两包：packet0 = SpeexHeader（魔数 "Speex   "，80 字节标准布局：
//!     rate@36 / mode@40 / bitstream_ver@44 / channels@48 / bitrate@52 /
//!     frame_size@56 / vbr@60 / frames_per_packet@64 / extra_headers@68），
//!     packet1 = Vorbis comment（标签元数据）；其后 extra_headers 个附加头包；
//!   - 每 Ogg packet 含 frames_per_packet 个 20ms 帧（位连续无字节对齐），
//!     包尾 terminator（m=15）；VBR 逐帧自描述 submode；
//!   - 输出 s16：f32 × (1/32768) → RINT 偶舍入 → 饱和（对齐 swresample 的
//!     cvtps2dq + packssdw SIMD 路径，即系统 ffmpeg `-f s16le` 实际走的路径）。
//!
//! probe/接线建议（供集成者）：
//!   - probe.zig `Format.spx`：`identifyOgg` 中首包 payload 以 `"Speex   "`
//!     （8 字节，S 大写 + 3 空格）开头 → `.ogg_speex`（OggS 页 + 27+nsegs 偏移，
//!     同 OpusHead 判定方式）；enabled() 接 formats.ogg 与独立 formats.speex 开关；
//!   - decoder.zig `open()` 分派：`.ogg_speex => spx.open(allocator, &reader, info)`。

const std = @import("std");
const Error = @import("../../error.zig").Error;
const io = @import("../../io.zig");
const decoder = @import("../../decoder.zig");
const ogg = @import("../ogg.zig");
const spx = @import("decode.zig");

const Allocator = std.mem.Allocator;

const vtable = decoder.Decoder.VTable{
    .read = readImpl,
    .seek_ms = seekMsImpl,
    .position_ms = positionMsImpl,
    .deinit = deinitImpl,
};

/// SpeexHeader（Ogg packet0，对照 libspeex header.h / oggparsespeex.c）
pub const SpeexHeader = struct {
    rate: i32,
    mode: i32,
    bitstream_version: i32,
    nb_channels: i32,
    bitrate: i32,
    frame_size: i32,
    vbr: bool,
    frames_per_packet: i32,
    extra_headers: i32,
};

const SPEEX_MAGIC = "Speex   "; // 5 字母 + 3 空格（8 字节）

fn rd32(p: []const u8, off: usize) i32 {
    return std.mem.readInt(i32, p[off..][0..4], .little);
}

/// 解析 SpeexHeader（对照 speexdec.c parse_speex_extradata + 其无 extradata
/// 回退路径；oggparsespeex.c 要求包 ≥ 68 字节）。
pub fn parseHeader(pkt: []const u8) Error!SpeexHeader {
    if (pkt.len < 68 or !std.mem.eql(u8, pkt[0..8], SPEEX_MAGIC)) return error.Corrupt;

    if (pkt.len >= 80) {
        const rate = rd32(pkt, 36);
        if (rate <= 0) return error.Corrupt;
        const mode = rd32(pkt, 40);
        if (mode < 0 or mode >= spx.SPEEX_NB_MODES) return error.Corrupt;
        const bitstream_version = rd32(pkt, 44);
        if (bitstream_version != 4) return error.Corrupt;
        const nb_channels = rd32(pkt, 48);
        if (nb_channels <= 0 or nb_channels > 2) return error.Corrupt;
        const frame_size = rd32(pkt, 56);
        const min_fs: i32 = if (mode > 1) spx.NB_FRAME_SIZE * 2 else spx.NB_FRAME_SIZE;
        if (frame_size < min_fs) return error.Corrupt;
        var fs = frame_size;
        if (mode > 1) {
            if (fs > std.math.maxInt(i32) >> 1) return error.Corrupt;
            fs <<= 1;
        }
        const cap_fs: i32 = switch (mode) {
            0 => spx.NB_FRAME_SIZE,
            1 => spx.NB_FRAME_SIZE * 2,
            else => spx.NB_FRAME_SIZE * 4,
        };
        fs = @min(fs, cap_fs);
        const frames_per_packet = rd32(pkt, 64);
        if (frames_per_packet <= 0 or frames_per_packet > 64 or
            frames_per_packet >= std.math.maxInt(i32) / @max(nb_channels, 1) / @max(fs, 1))
        {
            return error.Corrupt;
        }
        return .{
            .rate = rate,
            .mode = mode,
            .bitstream_version = bitstream_version,
            .nb_channels = nb_channels,
            .bitrate = rd32(pkt, 52),
            .frame_size = fs,
            .vbr = rd32(pkt, 60) != 0,
            .frames_per_packet = frames_per_packet,
            .extra_headers = rd32(pkt, 68),
        };
    }

    // 短头回退（speexdec.c 无 extradata 路径）：rate/channels 取自头，mode 按率推断
    const rate = rd32(pkt, 36);
    if (rate <= 0) return error.Corrupt;
    const nb_channels = rd32(pkt, 48);
    if (nb_channels <= 0 or nb_channels > 2) return error.Corrupt;
    const mode: i32 = switch (rate) {
        8000 => 0,
        16000 => 1,
        32000 => 2,
        else => 2,
    };
    return .{
        .rate = rate,
        .mode = mode,
        .bitstream_version = 4,
        .nb_channels = nb_channels,
        .bitrate = -1,
        .frame_size = switch (rate) {
            8000 => spx.NB_FRAME_SIZE,
            16000 => spx.NB_FRAME_SIZE * 2,
            else => spx.NB_FRAME_SIZE * 4,
        },
        .vbr = false,
        .frames_per_packet = 64,
        .extra_headers = 0,
    };
}

// ---------------------------------------------------------------------------
// 解码器上下文
// ---------------------------------------------------------------------------

const SpeexCtx = struct {
    allocator: Allocator,
    demux: ogg.Demux,
    hdr: SpeexHeader,
    fc: spx.FrameCtx,
    stereo: spx.StereoState = .{},

    /// 当前包解码输出（交错 s16 字节）
    pkt_s16: []u8 = &.{},
    pkt_pos: usize = 0,
    pkt_len: usize = 0,

    /// 单帧 f32 暂存（mono 解码域）与 stereo 展开暂存
    frame_f: []f32 = &.{},
    frame_s: []f32 = &.{},

    samples_done: u64 = 0,
    skip_left: u64 = 0, // seek 后丢弃样本数
    /// 开头待跳过的非音频包（reset 后头包重现；对照 oggparsespeex nb_header=2 + extra）
    header_pkts: usize = 0,
    meta: decoder.Metadata = .{},
    tags: std.ArrayList(decoder.Tag) = .empty,
    meta_strings: std.ArrayList([]u8) = .empty,

    fn deinitMeta(self: *SpeexCtx) void {
        if (self.meta.title) |v| self.allocator.free(v);
        if (self.meta.artist) |v| self.allocator.free(v);
        if (self.meta.album) |v| self.allocator.free(v);
        if (self.meta.date) |v| self.allocator.free(v);
        if (self.meta.genre) |v| self.allocator.free(v);
        if (self.meta.comment) |v| self.allocator.free(v);
        for (self.meta_strings.items) |s| self.allocator.free(s);
        self.meta_strings.deinit(self.allocator);
        self.tags.deinit(self.allocator);
        self.meta = .{};
    }
};

/// round-half-to-even（对齐 llrintf/cvtps2dq 的 RNE；x 为有限值）
fn rintEven(x: f32) f32 {
    if (@abs(x) >= 8388608.0) return x; // ≥2^23 已是整数域
    const t = @trunc(x);
    if (@abs(x - t) == 0.5) {
        // 平局：@round 远离零，取偶侧（trunc 与 round 奇偶必相异）
        const r = @round(x);
        if (@rem(r, 2.0) != 0) return t;
        return r;
    }
    return @round(x);
}

/// f32 → s16（swresample flt→s16 语义：llrintf 偶舍入 + packssdw 饱和；
/// ×2^-15、×2^15 为幂次精确运算，等价对原值偶舍入）
inline fn toS16(x: f32) i16 {
    const y = x * 3.0517578125e-05; // ×2^-15（精确）
    const v = y * 32768.0; // ×2^15（精确还原）
    if (std.math.isNan(v)) return -32768; // cvtps2dq: NaN → INT32_MIN
    const r = rintEven(v);
    if (!(r >= -2147483648.0 and r <= 2147483647.0)) return -32768;
    if (r >= 32767.0) return 32767; // packssdw 饱和
    if (r <= -32768.0) return -32768;
    return @intFromFloat(r);
}

/// speex_decode_stereo（单声道帧原位展开为立体声强度声道）
/// `data.len >= 2 * frame_size`；展开写 [0, 2*frame_size)
fn decodeStereo(data: []f32, frame_size: usize, stereo: *spx.StereoState) void {
    const balance = stereo.balance;
    const e_ratio = stereo.e_ratio;
    const e_right = 1.0 / @sqrt(e_ratio * (1.0 + balance));
    const e_left = @sqrt(balance) * e_right;

    var i: isize = @intCast(frame_size - 1);
    while (i >= 0) : (i -= 1) {
        const tmp = data[@intCast(i)];
        stereo.smooth_left = stereo.smooth_left * 0.98 + e_left * 0.02;
        stereo.smooth_right = stereo.smooth_right * 0.98 + e_right * 0.02;
        data[2 * @as(usize, @intCast(i))] = stereo.smooth_left * tmp;
        data[2 * @as(usize, @intCast(i)) + 1] = stereo.smooth_right * tmp;
    }
}

/// 解码单个 Ogg packet（frames_per_packet × 20ms 帧 → 交错 s16 缓冲）。
/// 返回产出样本帧数。错误帧对齐 ffmpeg CLI：跳过整包剩余（状态保留）。
fn decodePacket(f: *SpeexCtx, data: []const u8) Error!usize {
    const channels: usize = @intCast(f.hdr.nb_channels);
    const fs: usize = @intCast(f.hdr.frame_size);
    var gb = spx.BitReader.init(data);
    var nframes: usize = @intCast(f.hdr.frames_per_packet);

    for (0..@intCast(f.hdr.frames_per_packet)) |i| {
        const out = f.frame_f[i * fs ..][0..fs];
        spx.decodeLayer(&f.fc, &f.fc.st[@intCast(f.hdr.mode)], &gb, out, @intCast(@as(i64, @intCast(f.hdr.frames_per_packet)) - @as(i64, @intCast(i))), null) catch {
            return 0; // ffmpeg：帧解码错误 → 整包无输出，继续下一包
        };
        // 包尾 terminator 检查（剩余 <5 位或下 5 位 = 15）
        if (gb.left() < 5 or gb.showBits(5) == 15) {
            nframes = i + 1;
            break;
        }
    }

    // f32 ×(1/32768) → 交错 s16（stereo 逐帧展开）
    var w: usize = 0;
    for (0..nframes) |i| {
        if (channels == 2) {
            @memcpy(f.frame_s[0..fs], f.frame_f[i * fs ..][0..fs]);
            @memcpy(f.frame_s[fs..][0..fs], f.frame_f[i * fs ..][0..fs]);
            decodeStereo(f.frame_s, fs, &f.stereo);
            for (0..2 * fs) |k| {
                const v = toS16(f.frame_s[k]);
                std.mem.writeInt(i16, f.pkt_s16[w..][0..2], v, .little);
                w += 2;
            }
        } else {
            for (0..fs) |k| {
                const v = toS16(f.frame_f[i * fs + k]);
                std.mem.writeInt(i16, f.pkt_s16[w..][0..2], v, .little);
                w += 2;
            }
        }
    }
    return nframes * fs;
}

// ---------------------------------------------------------------------------
// Vorbis comment 标签（packet1，对照 ff_vorbis_stream_comment）
// ---------------------------------------------------------------------------

fn addTag(f: *SpeexCtx, key: []const u8, value: []const u8) Error!void {
    const kbuf = try f.allocator.dupe(u8, key);
    errdefer f.allocator.free(kbuf);
    const vbuf = try f.allocator.dupe(u8, std.mem.trim(u8, value, " \t"));
    errdefer f.allocator.free(vbuf);
    try f.meta_strings.append(f.allocator, kbuf);
    try f.meta_strings.append(f.allocator, vbuf);
    try f.tags.append(f.allocator, .{ .key = kbuf, .value = vbuf });

    const map = std.StaticStringMap(usize).initComptime(.{
        .{ "TITLE", 0 },
        .{ "ARTIST", 1 },
        .{ "ALBUM", 2 },
        .{ "DATE", 3 },
        .{ "GENRE", 4 },
        .{ "COMMENT", 5 },
        .{ "DESCRIPTION", 5 },
    });
    if (map.get(kbuf)) |slot| {
        const dup = try f.allocator.dupeZ(u8, vbuf);
        errdefer f.allocator.free(dup);
        try f.meta_strings.append(f.allocator, dup[0 .. dup.len]);
        const field: *?[:0]const u8 = switch (slot) {
            0 => &f.meta.title,
            1 => &f.meta.artist,
            2 => &f.meta.album,
            3 => &f.meta.date,
            4 => &f.meta.genre,
            else => &f.meta.comment,
        };
        if (field.*) |old| f.allocator.free(old);
        field.* = dup;
    }
}

fn parseComment(f: *SpeexCtx, data: []const u8) void {
    if (data.len < 8) return;
    var pos: usize = 0;
    const vlen: usize = @intCast(std.mem.readInt(u32, data[0..4], .little));
    pos = 4;
    if (pos + vlen > data.len) return;
    pos += vlen;
    if (pos + 4 > data.len) return;
    const count = std.mem.readInt(u32, data[pos..][0..4], .little);
    pos += 4;
    var n: usize = 0;
    while (n < count and n < 256) : (n += 1) {
        if (pos + 4 > data.len) return;
        const l = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;
        if (l > data.len - pos) return;
        const entry = data[pos .. pos + l];
        pos += l;
        if (std.mem.indexOfScalar(u8, entry, '=')) |eq| {
            addTag(f, entry[0..eq], entry[eq + 1 ..]) catch return;
        }
    }
}

// ---------------------------------------------------------------------------
// Decoder VTable 入口
// ---------------------------------------------------------------------------

pub fn open(allocator: Allocator, reader: *io.Reader, info: *decoder.Info) Error!decoder.Decoder {
    const f = try allocator.create(SpeexCtx);
    errdefer allocator.destroy(f);
    f.* = .{
        .allocator = allocator,
        .demux = undefined,
        .hdr = undefined,
        .fc = undefined,
    };
    f.demux = .{ .allocator = allocator, .reader = reader.* };
    errdefer f.demux.deinit();

    // packet0：SpeexHeader
    const head_pkt = (try f.demux.nextPacket()) orelse return error.Corrupt;
    if (head_pkt.continued) return error.Corrupt;
    f.hdr = try parseHeader(head_pkt.data);

    // packet1：Vorbis comment；其后 extra_headers 个附加头包（按 libspeex 语义跳过）
    if (try f.demux.nextPacket()) |cmt| {
        parseComment(f, cmt.data);
    }
    var extra: i32 = f.hdr.extra_headers;
    while (extra > 0) : (extra -= 1) {
        _ = (try f.demux.nextPacket()) orelse return error.Corrupt;
    }
    f.meta.tags = f.tags.items;

    // 解码器状态（mode 0..hdr.mode 逐层初始化；对照 decoder_init）
    f.fc = .{ .st = undefined, .stereo = &f.stereo, .container_frame_size = f.hdr.frame_size };
    var m: u32 = 0;
    while (m <= @as(u32, @intCast(f.hdr.mode))) : (m += 1) {
        f.fc.st[m].init(&spx.speex_modes[m]);
    }

    // 缓冲：帧解码域 + s16 输出（frames_per_packet × frame_size × ch × 2B）
    const fs: usize = @intCast(f.hdr.frame_size);
    const fpp: usize = @intCast(f.hdr.frames_per_packet);
    const ch: usize = @intCast(f.hdr.nb_channels);
    f.frame_f = try allocator.alloc(f32, fpp * fs);
    errdefer allocator.free(f.frame_f);
    if (ch == 2) {
        f.frame_s = try allocator.alloc(f32, 2 * fs);
        errdefer allocator.free(f.frame_s);
    }
    f.pkt_s16 = try allocator.alloc(u8, fpp * fs * ch * 2);
    errdefer allocator.free(f.pkt_s16);

    // 首音频包信息（对照 oggparsespeex.c speex_packet：first_pts = 首音频页
    // granule − packet_size × 该页包数。speexenc 的 granule 相对帧数有非对齐
    // 偏移，FFmpeg 以该修正对齐 pts；读一包后 reset，readImpl 经 header_pkts 跳头）
    var first_pts: ?i64 = null;
    if (try f.demux.nextPacket()) |pkt| {
        if (!pkt.continued) {
            if (f.demux.page) |pg| {
                if (pg.granule > 0) {
                    const packet_size: i64 =
                        @as(i64, f.hdr.frame_size) * f.hdr.frames_per_packet;
                    var npkts: i64 = 0;
                    for (pg.segments) |seg| {
                        if (seg < 255) npkts += 1;
                    }
                    first_pts = pg.granule - packet_size * npkts;
                }
            }
        }
    }
    try f.demux.reset();
    f.header_pkts = 2 + @as(usize, @intCast(@max(f.hdr.extra_headers, 0)));

    // 末页 granule → 时长（对照 oggparsespeex/ogg_get_length：容器时长 =
    // 末页 granule − first_pts，granule 单位 = 样本。EOS 页 → exact；EOS 页
    // 缺失/损坏 → 末音频页 granule 退 .estimate；不可 seek（callback 流）→
    // 回退整流预扫描（原有路径，仅 EOS 可得，保持 .estimate 语义）。
    var last_granule: i64 = 0;
    var eos_found = false;
    var granule_known = false;
    if ((ogg.scanTailPage(&f.demux.reader, f.demux.serial) catch null)) |tail| {
        if (tail.granule > 0) {
            last_granule = tail.granule;
            eos_found = tail.eos;
            granule_known = true;
        }
    }
    if (!granule_known) {
        var scanned: bool = false;
        while (true) {
            const p = f.demux.nextPacket() catch break orelse break;
            _ = p;
            scanned = true;
        }
        if (scanned and f.demux.final_granule > 0) {
            last_granule = f.demux.final_granule;
            eos_found = f.demux.eos;
            granule_known = true;
        }
        try f.demux.reset();
        f.header_pkts = 2 + @as(usize, @intCast(@max(f.hdr.extra_headers, 0)));
    }

    var duration_us: i64 = 0;
    var duration_known: decoder.DurationKnown = .unknown;
    if (granule_known) {
        const samples: i64 = if (first_pts) |fp| last_granule - fp else last_granule;
        const granule_max: i64 = @as(i64, @intCast(f.hdr.rate)) * 12 * 3600;
        if (samples > 0 and samples < granule_max) {
            // i128 中间量：samples×1e6 在病态大 rate 下防 i64 溢出（结果有界 ≤ 12h）
            duration_us = @intCast(@divTrunc(@as(i128, samples) * 1_000_000, f.hdr.rate));
            duration_known = if (eos_found) .exact else .estimate;
        }
    }

    info.* = .{
        .sample_rate = @intCast(f.hdr.rate),
        .channels = @intCast(f.hdr.nb_channels),
        .bits_per_sample = 16,
        .is_float = false,
        .duration_us = duration_us,
        .duration_known = duration_known,
        .codec_name = "speex",
        .format_name = "ogg",
        .metadata = f.meta,
    };
    return .{ .vtable = &vtable, .ctx = f };
}

fn readImpl(ctx: *anyopaque, out: []u8, max_samples: usize, out_channels: *u8) Error!usize {
    const f: *SpeexCtx = @ptrCast(@alignCast(ctx));
    out_channels.* = @intCast(f.hdr.nb_channels);
    if (max_samples == 0 or out.len == 0) return 0;

    const ch: usize = @intCast(f.hdr.nb_channels);
    const frame_bytes = ch * 2;
    const cap = @min(max_samples, out.len / frame_bytes);
    var produced: usize = 0;
    while (produced < cap) {
        if (f.pkt_pos >= f.pkt_len) {
            const pkt = (try f.demux.nextPacket()) orelse break; // EOF
            if (f.header_pkts > 0) {
                // 头部包（SpeexHeader / comment / extra_headers）不计音频
                f.header_pkts -= 1;
                continue;
            }
            const frames = try decodePacket(f, pkt.data);
            f.pkt_len = frames * ch * 2;
            f.pkt_pos = 0;
            if (f.pkt_len == 0) continue;
        }
        while (produced < cap and f.pkt_pos < f.pkt_len) {
            if (f.skip_left > 0) {
                // seek 起始丢弃：不计入 samples_done（位置保持在目标）
                f.skip_left -= 1;
                f.pkt_pos += frame_bytes;
                continue;
            }
            @memcpy(out[produced * frame_bytes ..][0..frame_bytes], f.pkt_s16[f.pkt_pos..][0..frame_bytes]);
            f.pkt_pos += frame_bytes;
            f.samples_done += 1;
            produced += 1;
        }
    }
    return produced;
}

fn seekMsImpl(ctx: *anyopaque, ms: i64) Error!void {
    const f: *SpeexCtx = @ptrCast(@alignCast(ctx));
    const target: i64 = @divTrunc(ms * f.hdr.rate, 1000);
    if (target < 0) return error.SeekFailed;
    // granule 定位页 + 解码器状态重建 + 起始样本丢弃（CELP 状态冷启，前几帧
    // 音质过渡，与 FFmpeg Ogg seek 重启解码一致）。位置按目标样本计（丢弃段不推进）。
    // 定位页起点 granule = prev；页起点到目标之间须丢弃 target - prev 个样本。
    const prev = try f.demux.seekToGranule(target);
    var m: u32 = 0;
    while (m <= @as(u32, @intCast(f.hdr.mode))) : (m += 1) {
        f.fc.st[m].init(&spx.speex_modes[m]);
    }
    f.stereo = .{};
    f.pkt_len = 0;
    f.pkt_pos = 0;
    f.samples_done = @intCast(@max(target, 0));
    f.skip_left = if (target > prev) @intCast(target - prev) else 0;
}

fn positionMsImpl(ctx: *anyopaque) i64 {
    const f: *SpeexCtx = @ptrCast(@alignCast(ctx));
    return @intCast(@divTrunc(@as(i64, @intCast(f.samples_done)) * 1000, f.hdr.rate));
}

fn deinitImpl(ctx: *anyopaque) void {
    const f: *SpeexCtx = @ptrCast(@alignCast(ctx));
    f.demux.deinit();
    if (f.frame_f.len > 0) f.allocator.free(f.frame_f);
    if (f.frame_s.len > 0) f.allocator.free(f.frame_s);
    if (f.pkt_s16.len > 0) f.allocator.free(f.pkt_s16);
    f.deinitMeta();
    f.allocator.destroy(f);
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

/// 末页（OggS）起始偏移（构造截断/损坏变体用）
fn lastPageStart(data: []const u8) usize {
    var last: usize = 0;
    var i: usize = 0;
    while (i + 4 <= data.len) : (i += 1) {
        if (std.mem.eql(u8, data[i..][0..4], "OggS")) last = i;
    }
    return last;
}

const q6_spx = @embedFile("samples/q6_8k.spx");
const q6_ref = @embedFile("samples/ref_q6_8k.s16");
const q8_spx = @embedFile("samples/q8_16k.spx");
const q8_ref = @embedFile("samples/ref_q8_16k.s16");
const q10_spx = @embedFile("samples/q10_32k.spx");
const q10_ref = @embedFile("samples/ref_q10_32k.s16");
const vbr_spx = @embedFile("samples/vbr3_16k.spx");
const vbr_ref = @embedFile("samples/ref_vbr3_16k.s16");
const st_spx = @embedFile("samples/st_q8.spx");
const st_ref = @embedFile("samples/ref_st_q8.s16");
const fpp4_spx = @embedFile("samples/fpp4_q6.spx");
const fpp4_ref = @embedFile("samples/ref_fpp4_q6.s16");

pub const CompareResult = struct {
    n: usize,
    equal: usize,
    max_abs: i32,
    corr: f64,
};

/// mine vs 参考 PCM 对拍（corr / max_abs / bit-exact；ref 为 s16le 字节流）
pub fn compare(mine: []const i16, ref: []const u8) CompareResult {
    const n = @min(mine.len, ref.len / 2);
    var equal: usize = 0;
    var max_abs: i32 = 0;
    var sxy: f64 = 0;
    var sx2: f64 = 0;
    var sy2: f64 = 0;
    for (0..n) |i| {
        const a: i32 = mine[i];
        const b: i32 = std.mem.readInt(i16, ref[i * 2 ..][0..2], .little);
        if (a == b) equal += 1;
        const d: i64 = @as(i64, a) - @as(i64, b);
        max_abs = @max(max_abs, @as(i32, @intCast(@abs(d))));
        const x: f64 = @floatFromInt(a);
        const y: f64 = @floatFromInt(b);
        sxy += x * y;
        sx2 += x * x;
        sy2 += y * y;
    }
    const corr = if (sx2 > 0 and sy2 > 0) sxy / @sqrt(sx2 * sy2) else 1.0;
    return .{ .n = n, .equal = equal, .max_abs = max_abs, .corr = corr };
}

fn decodeAll(allocator: Allocator, data: []const u8, out: *std.ArrayList(i16)) !decoder.Info {
    var info: decoder.Info = undefined;
    var reader = io.Reader.openMem(data);
    var dec = try open(allocator, &reader, &info);
    defer dec.deinit();
    var buf: [1 << 16]u8 = undefined;
    while (true) {
        var ch: u8 = 0;
        const n = try dec.read(&buf, buf.len / 4, &ch);
        if (n == 0) break;
        const samples = try out.addManyAsSlice(allocator, n * @as(usize, ch));
        for (0..n * @as(usize, ch)) |k| {
            samples[k] = std.mem.readInt(i16, buf[k * 2 ..][0..2], .little);
        }
    }
    return info;
}

fn goldenCase(allocator: Allocator, name: []const u8, data: []const u8, ref: []const u8, want_rate: u32, want_samples: usize) !void {
    var out = std.ArrayList(i16).empty;
    defer out.deinit(allocator);
    const info = try decodeAll(allocator, data, &out);
    try testing.expectEqual(want_rate, info.sample_rate);
    try testing.expectEqual(@as(u8, 1), info.channels);
    const ng = ref.len / 2;
    try testing.expectEqual(want_samples, ng);
    try testing.expectEqual(ng, out.items.len);
    const r = compare(out.items, ref);
    std.debug.print("  spx {s}: sr={d} n={d} corr={d:.8} max_abs={d} bit-exact {d}/{d} = {d:.4}%\n", .{
        name, info.sample_rate, r.n, r.corr, r.max_abs, r.equal, r.n,
        100.0 * @as(f64, @floatFromInt(r.equal)) / @as(f64, @floatFromInt(r.n)),
    });
    try testing.expect(r.corr >= 0.9999);
    try testing.expectEqual(r.n, r.equal); // 目标 bit-exact（-lc glibc libm）
}

test "spx golden: NB q6 8k（ffmpeg native speex 对拍）" {
    try goldenCase(testing.allocator, "q6_8k", q6_spx, q6_ref, 8000, 24160);
}

test "spx golden: WB q8 16k" {
    try goldenCase(testing.allocator, "q8_16k", q8_spx, q8_ref, 16000, 48320);
}

test "spx golden: UWB q10 32k（三层）" {
    try goldenCase(testing.allocator, "q10_32k", q10_spx, q10_ref, 32000, 64640);
}

test "spx golden: VBR vbr3 16k" {
    try goldenCase(testing.allocator, "vbr3_16k", vbr_spx, vbr_ref, 16000, 48320);
}

test "spx golden: WB 立体声（inband 强度立体声）" {
    var out = std.ArrayList(i16).empty;
    defer out.deinit(testing.allocator);
    const info = try decodeAll(testing.allocator, st_spx, &out);
    try testing.expectEqual(@as(u32, 16000), info.sample_rate);
    try testing.expectEqual(@as(u8, 2), info.channels);
    const r = compare(out.items, st_ref);
    std.debug.print("  spx st_q8: ch=2 n={d} corr={d:.8} max_abs={d} bit-exact {d}/{d} = {d:.4}%\n", .{
        r.n, r.corr, r.max_abs, r.equal, r.n,
        100.0 * @as(f64, @floatFromInt(r.equal)) / @as(f64, @floatFromInt(r.n)),
    });
    try testing.expect(r.corr >= 0.9999);
    try testing.expectEqual(r.n, r.equal);
}

test "spx golden: NB 4帧/包（terminator + 多帧包）" {
    var out = std.ArrayList(i16).empty;
    defer out.deinit(testing.allocator);
    const info = try decodeAll(testing.allocator, fpp4_spx, &out);
    try testing.expectEqual(@as(u32, 8000), info.sample_rate);
    const r = compare(out.items, fpp4_ref);
    std.debug.print("  spx fpp4_q6: n={d} corr={d:.8} max_abs={d} bit-exact {d}/{d} = {d:.4}%\n", .{
        r.n, r.corr, r.max_abs, r.equal, r.n,
        100.0 * @as(f64, @floatFromInt(r.equal)) / @as(f64, @floatFromInt(r.n)),
    });
    try testing.expect(r.corr >= 0.9999);
    try testing.expectEqual(r.n, r.equal);
}

test "spx: seek_ms 冒烟（granule 定位 + 状态重建 + 位置推进）" {
    var info: decoder.Info = undefined;
    var reader = io.Reader.openMem(q8_spx);
    var dec = try open(testing.allocator, &reader, &info);
    defer dec.deinit();
    try dec.seekMs(1500); // 1.5s
    try testing.expectEqual(@as(i64, 1500), dec.positionMs());
    var buf: [6400]u8 = undefined;
    var ch: u8 = 0;
    var total: usize = 0;
    while (true) {
        const n = try dec.read(&buf, 320, &ch);
        if (n == 0) break;
        total += n;
    }
    // 从 1.5s 解到 EOF（3s 素材 ≈ 1.5s 输出，允许 terminator/末帧误差）
    try testing.expect(total > 22000);
    try testing.expect(dec.positionMs() > 1500);
}

test "spx: SpeexHeader 解析（q6_8k 头）" {
    const h = try parseHeader(q6_spx[27 + 1 ..][0..80]);
    try testing.expectEqual(@as(i32, 8000), h.rate);
    try testing.expectEqual(@as(i32, 0), h.mode);
    try testing.expectEqual(@as(i32, 4), h.bitstream_version);
    try testing.expectEqual(@as(i32, 1), h.nb_channels);
    try testing.expectEqual(@as(i32, 160), h.frame_size);
    try testing.expectEqual(@as(i32, 1), h.frames_per_packet);
    try testing.expect(!h.vbr);
    // 魔数不符 / 过短 → Corrupt
    try testing.expectError(error.Corrupt, parseHeader(q6_spx[27 + 1 ..][0..67]));
    try testing.expectError(error.Corrupt, parseHeader("OggSxxxx" ++ "x" ** 72));
}

test "spx: 头部包与 comment 跳过后首帧可解（open 全链路 Info）" {
    var info: decoder.Info = undefined;
    var reader = io.Reader.openMem(q6_spx);
    var dec = try open(testing.allocator, &reader, &info);
    defer dec.deinit();
    try testing.expectEqualStrings("speex", info.codec_name);
    try testing.expectEqualStrings("ogg", info.format_name);
    // 末页 granule 24000 − first_pts(23480 − 160×147 = −40) = 24040 样本 @8k
    // = 3.005s（与 ffprobe 容器时长一致；EOS 页 → exact）
    try testing.expectEqual(decoder.DurationKnown.exact, info.duration_known);
    try testing.expectEqual(@as(i64, 3_005_000), info.duration_us);
    var buf: [640]u8 = undefined;
    var ch: u8 = 0;
    const n = try dec.read(&buf, 160, &ch);
    try testing.expectEqual(@as(usize, 160), n);
}

test "spx: EOS 页缺失 → estimate 降级（退前一音频页 granule）" {
    // 截掉末页（EOS）：前一音频页 granule 23480 → 23480 − first_pts(−40)
    // = 23520 样本 @8k = 2.94s
    const cut = lastPageStart(q6_spx);
    try testing.expect(cut > 100);
    var info: decoder.Info = undefined;
    var reader = io.Reader.openMem(q6_spx[0..cut]);
    var dec = try open(testing.allocator, &reader, &info);
    defer dec.deinit();
    try testing.expectEqual(decoder.DurationKnown.estimate, info.duration_known);
    try testing.expectEqual(@as(i64, 2_940_000), info.duration_us);
}

test "spx: 尾页损坏 → estimate 降级" {
    const corrupted = try testing.allocator.dupe(u8, q6_spx);
    defer testing.allocator.free(corrupted);
    corrupted[corrupted.len - 10] ^= 0xFF; // 破坏末页 CRC → parsePage 拒绝
    var info: decoder.Info = undefined;
    var reader = io.Reader.openMem(corrupted);
    var dec = try open(testing.allocator, &reader, &info);
    defer dec.deinit();
    try testing.expectEqual(decoder.DurationKnown.estimate, info.duration_known);
    try testing.expectEqual(@as(i64, 2_940_000), info.duration_us);
    // 解码路径不受影响
    var buf: [640]u8 = undefined;
    var ch: u8 = 0;
    const n = try dec.read(&buf, 160, &ch);
    try testing.expectEqual(@as(usize, 160), n);
}

test "spx: toS16 偶舍入与饱和（s16 域输入）" {
    try testing.expectEqual(@as(i16, 0), toS16(0));
    try testing.expectEqual(@as(i16, 1), toS16(1.0)); // s16 域原值还原
    try testing.expectEqual(@as(i16, -1), toS16(-1.0));
    try testing.expectEqual(@as(i16, 32767), toS16(32767.5)); // .5 偶舍入→32768→饱和
    try testing.expectEqual(@as(i16, 32766), toS16(32766.5)); // 偶舍入→32766
    try testing.expectEqual(@as(i16, -32768), toS16(-32767.5)); // 偶舍入→-32768
    try testing.expectEqual(@as(i16, 32767), toS16(1e9)); // int32 内 → packssdw 上饱和
    try testing.expectEqual(@as(i16, -32768), toS16(3e9)); // cvtps2dq 越界→INT32_MIN→-32768
    try testing.expectEqual(@as(i16, -32768), toS16(std.math.nan(f32)));
    try testing.expectEqual(@as(i16, 1), toS16(1.4));
    try testing.expectEqual(@as(i16, 2), toS16(1.5 + 1e-6));
    try testing.expectEqual(@as(i16, 2), toS16(2.5 - 1e-6));
}
