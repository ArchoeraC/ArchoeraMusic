// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! AC-3 解码器（Dolby Digital；参考 FFmpeg ac3dec.c，float 路径）
//!
//! 文档：Dolby AC-3（ATSC A/52）。帧 = 同步字 + 头 + 6 个音频块（每块 256 样本）。
//! 处理链：帧同步/头解析（header.zig）→ 每块 decode_audio_block（指数/位分配/尾数/
//! 耦合/重矩阵/缩放）→ IMDCT（256/128 点 + KBD 窗）→ 重叠相加 → s16 输出。
//!
//! 模块拆分：tables.zig（表）/ bitalloc.zig（位分配）/ exponents.zig（指数）/
//! coupling.zig（耦合）/ mantissa.zig（尾数+变换系数）/ downmix.zig（重矩阵+下混）。

const std = @import("std");

const Error = @import("../../error.zig").Error;
const io = @import("../../io.zig");
const decoder = @import("../../decoder.zig");

const c = @import("ctx.zig");
const t = @import("tables.zig");
const ba = @import("bitalloc.zig");
const ex = @import("exponents.zig");
const cp = @import("coupling.zig");
const mn = @import("mantissa.zig");
const dm = @import("downmix.zig");
const hdr = @import("header.zig");
const kb = @import("kbdwin.zig");
const mdct = @import("../aac/mdct.zig");

const BitReader = @import("../aac/bitreader.zig").BitReader;

/// 2^-exp 缩放（表 7.19 附近；指数 0..24）
const scale_factors = [25]f32{
    1.0, 0.5, 0.25, 0.125, 0.0625, 0.03125, 0.015625, 0.0078125,
    0.00390625, 0.001953125, 0.0009765625, 0.00048828125, 0.000244140625,
    0.0001220703125, 6.103515625e-05, 3.0517578125e-05, 1.52587890625e-05,
    7.62939453125e-06, 3.814697265625e-06, 1.9073486328125e-06, 9.5367431640625e-07,
    4.76837158203125e-07, 2.384185791015625e-07, 1.1920928955078125e-07, 5.960464477539063e-08,
};

/// 动态范围表（§7.7.1；运行时生成）
var dynamic_range_tab: [256]f32 = undefined;
var heavy_dynamic_range_tab: [256]f32 = undefined;

/// 声道重映射表（channel_mode × lfe，6 项）
const channel_map_tab = [8][2][6]u8{
    .{ .{ 0, 1, 0, 0, 0, 0 }, .{ 0, 1, 2, 0, 0, 0 } },
    .{ .{ 0, 0, 0, 0, 0, 0 }, .{ 0, 1, 0, 0, 0, 0 } },
    .{ .{ 0, 1, 0, 0, 0, 0 }, .{ 0, 1, 2, 0, 0, 0 } },
    .{ .{ 0, 2, 1, 0, 0, 0 }, .{ 0, 2, 1, 3, 0, 0 } },
    .{ .{ 0, 1, 2, 0, 0, 0 }, .{ 0, 1, 3, 2, 0, 0 } },
    .{ .{ 0, 2, 1, 3, 0, 0 }, .{ 0, 2, 1, 4, 3, 0 } },
    .{ .{ 0, 1, 2, 3, 0, 0 }, .{ 0, 1, 4, 2, 3, 0 } },
    .{ .{ 0, 2, 1, 3, 4, 0 }, .{ 0, 2, 1, 5, 3, 4 } },
};

const DecoderCtx = struct {
    allocator: std.mem.Allocator,
    reader: io.Reader,
    s: c.Ctx = .{},

    /// 帧缓冲（含填充防越界）
    frame_buf: [4096]u8 = [_]u8{0} ** 4096,
    sample_rate: u32 = 0,
    channels: u8 = 0,

    /// 输出缓冲（s16 交错，解码后填入；帧输出上限 6×256×8）
    out: [16384]i16 = undefined,
    out_len: usize = 0,
    out_pos: usize = 0,
    eof: bool = false,

    mdct_256: mdct.Mdct(f32) = undefined,
    mdct_128: mdct.Mdct(f32) = undefined,
    scratch: [128]mdct.Mdct(f32).Cplx = undefined,


    frames_done: u64 = 0,
};

fn initTables() void {
    for (0..256) |i| {
        const v: i32 = @as(i32, @intCast(i >> 5)) - (@as(i32, @intCast(i >> 7)) << 3) - 5;
        dynamic_range_tab[i] = std.math.pow(f32, 2.0, @as(f32, @floatFromInt(v))) * @as(f32, @floatFromInt((i & 0x1F) | 0x20));
    }
    for (0..256) |i| {
        const v: i32 = @as(i32, @intCast(i >> 4)) - (@as(i32, @intCast(i >> 7)) << 4) - 4;
        heavy_dynamic_range_tab[i] = std.math.pow(f32, 2.0, @floatFromInt(v)) * @as(f32, @floatFromInt((i & 0xF) | 0x10));
    }
    t.initStatic();
}

pub fn open(allocator: std.mem.Allocator, reader: *io.Reader, info: *decoder.Info) Error!decoder.Decoder {
    const f = try allocator.create(DecoderCtx);
    errdefer allocator.destroy(f);
    f.* = .{ .allocator = allocator, .reader = reader.* };
    errdefer f.reader.deinit();
    initTables();
    f.mdct_256 = mdct.Mdct(f32).init(256);
    f.mdct_128 = mdct.Mdct(f32).init(128);

    // 预读帧头获取采样率/声道
    var buf: [64]u8 = undefined;
    const n = try f.reader.read(&buf);
    if (n < 8) return error.Corrupt;
    var sync_off: usize = 0;
    var found = false;
    for (0..n - 1) |i| {
        if (buf[i] == 0x0B and buf[i + 1] == 0x77) {
            sync_off = i;
            found = true;
            break;
        }
    }
    if (!found) return error.Corrupt;
    const h = hdr.parse(buf[sync_off..n]) catch return error.Corrupt;
    f.reader.seek(-@as(i64, @intCast(n)), .current) catch {};
    f.sample_rate = h.sample_rate;
    f.channels = @intCast(h.channels);

    // 时长：AC-3 帧计数需全扫（open 不做），按首访问单元「字节/样本」比率
    // 外推（estimate，与 ffprobe 码率估算同级且对 CBR 几乎精确）。E-AC-3
    // 访问单元 = 独立帧 + 其依赖帧（依赖帧不产样本，计字节不计样本）。
    var duration_us: i64 = -1;
    var known: decoder.DurationKnown = .unknown;
    const file_size = f.reader.size() catch 0;
    if (file_size > 0 and h.frame_size >= 2 and h.sample_rate > 0) {
        if (accessUnitRatio(f, sync_off)) |ratio| {
            const total_samples = file_size * ratio.samples / ratio.bytes;
            if (total_samples > 0) {
                duration_us = @intCast(total_samples * 1_000_000 / h.sample_rate);
                known = .estimate;
            }
        }
        // 恢复读位置（比率扫描仅 peek，seek 会移动 pos；解码从 sync_off 起）
        f.reader.seek(@intCast(sync_off), .start) catch {};
    }

    info.* = .{
        .sample_rate = h.sample_rate,
        .channels = h.channels,
        .bits_per_sample = 16,
        .is_float = false,
        .duration_us = duration_us,
        .duration_known = known,
        .codec_name = "ac3",
        .format_name = "ac3",
        .metadata = .{},
    };
    return .{ .vtable = &vtable, .ctx = f };
}

/// 访问单元「字节/样本」比率（最多扫 8 个访问单元取均值；bounded 小读，
/// 不全扫）。返回 null = 头解析失败（时长 unknown）。
fn accessUnitRatio(f: *DecoderCtx, start_off: usize) ?struct { bytes: u64, samples: u64 } {
    var buf: [64]u8 = undefined;
    var pos: usize = start_off;
    var bytes: u64 = 0;
    var samples: u64 = 0;
    var aus: usize = 0;
    while (aus < 8) {
        f.reader.seek(@intCast(pos), .start) catch break;
        const n = f.reader.peek(&buf) catch break;
        if (n < 8) break;
        if (buf[0] != 0x0B or buf[1] != 0x77) break;
        const h = hdr.parse(buf[0..n]) catch break;
        if (h.frame_size < 2) break;
        bytes += h.frame_size;
        if (h.frame_type != 1) { // 非 E-AC-3 依赖帧：样本按本帧计
            samples += @as(u64, @intCast(h.num_blocks)) * 256;
            aus += 1;
        }
        pos += h.frame_size;
    }
    if (bytes == 0 or samples == 0) return null;
    return .{ .bytes = bytes, .samples = samples };
}

const VTable = decoder.Decoder.VTable;
const vtable = VTable{
    .read = readImpl,
    .seek_ms = seekMsImpl,
    .position_ms = positionMsImpl,
    .deinit = deinitImpl,
};

fn readImpl(ctx: *anyopaque, out: []u8, max_samples: usize, out_channels: *u8) Error!usize {
    const f: *DecoderCtx = @ptrCast(@alignCast(ctx));
    out_channels.* = f.channels;
    if (max_samples == 0 or out.len == 0) return 0;
    if (f.eof) return 0;

    const frame_bytes = @as(usize, f.channels) * 2;
    const cap = @min(max_samples, out.len / frame_bytes);
    var produced: usize = 0;
    while (produced < cap) {
        if (f.out_pos * f.channels >= f.out_len) {
            f.out_pos = 0;
            const df_ok = try decodeFrame(f);
            if (!df_ok) { f.eof = true; break; }
            continue;
        }
        const avail = (f.out_len / f.channels) - f.out_pos;
        const take = @min(avail, cap - produced);
        const src_off = f.out_pos * f.channels;
        @memcpy(out[produced * frame_bytes ..][0 .. take * frame_bytes], std.mem.sliceAsBytes(f.out[src_off .. src_off + take * f.channels]));
        f.out_pos += take;
        produced += take;
    }
    return produced;
}

/// 同步 + 解码一帧 → f.out（s16 交错）
fn decodeFrame(f: *DecoderCtx) Error!bool {
    var dfc: usize = 0;
    while (true) {
        dfc += 1;
        if (dfc > 100) return false;
        // 找同步字（含尝试上限防伪同步卡死）
        var sync_found = false;
        var attempts: usize = 0;
        while (!sync_found) {
            attempts += 1;
            if (attempts > 100_000) return false;
            var hb: [2]u8 = undefined;
            const m = f.reader.read(&hb) catch return error.Corrupt;
            if (m < 2) return false; // EOF
            if (hb[0] == 0x0B and hb[1] == 0x77) {
                sync_found = true;
            } else {
                f.reader.seek(-1, .current) catch {};
            }
        }
        // 预读 64 字节解析帧头（bsi 可能超过 8 字节）
        @memset(f.frame_buf[0..64], 0);
        f.frame_buf[0] = 0x0B;
        f.frame_buf[1] = 0x77;
        const mr = f.reader.read(f.frame_buf[2..64]) catch return error.Corrupt;
        if (mr < 30) return false; // EOF / 数据不足
        const h = hdr.parse(f.frame_buf[0 .. 2 + mr]) catch {
            // 无效帧头（伪同步）：回退到 sync+2，继续找下一个同步
            f.reader.seek(-@as(i64, @intCast(mr)), .current) catch {};
            continue;
        };
        if (h.frame_size > 4000 or h.frame_size < 2 + mr) {
            f.reader.seek(-@as(i64, @intCast(mr)), .current) catch {};
            continue;
        }
        const head_bits = h.consumed_bits;

        // 读整帧（帧头已读 2+mr 字节，补读剩余）
        const got = 2 + mr;
        const fsz: usize = @intCast(h.frame_size);
        if (fsz > got) {
            const rem = try f.reader.read(f.frame_buf[got..fsz]);
            if (rem < fsz - got) return false; // 不完整帧
        }
    // 帧缓冲尾部填充 8 字节防越界
    @memset(f.frame_buf[fsz .. fsz + 8], 0);

    // 解码（Ctx 跨帧保留：CPL 指数/坐标/动态范围等状态需持久化，仅刷新帧头字段）
    const s = &f.s;
    s.gb = BitReader.init(f.frame_buf[0 .. fsz + 8]);
    s.gb.bit_pos = head_bits;
    try parseHeaderInto(s, &h);
    if (s.num_blocks <= 0 or s.num_blocks > 6 or s.channels <= 0 or s.channels > 8) return error.Corrupt;
    f.sample_rate = @intCast(s.sample_rate);
    f.channels = @intCast(s.channels);
    if (s.eac3 != 0) {
        try parseEac3Frame(s);
    }
    // 块循环
    const blk_count: usize = @min(@as(usize, @intCast(s.num_blocks)), 6);
    const oc: usize = @min(@as(usize, @intCast(s.out_channels)), 8);
    if (oc == 0) return error.Corrupt;
    const blk_out = try f.allocator.alloc(f32, t.AC3_BLOCK_SIZE * blk_count * oc);
    defer f.allocator.free(blk_out);

    var bit_alloc_stages = [_]u8{0} ** t.AC3_MAX_CHANNELS;

    var blk: usize = 0;
    while (blk < blk_count) : (blk += 1) {
        const off = blk * t.AC3_BLOCK_SIZE;
        const ret = decodeAudioBlock(f, s, @intCast(blk), 0, &bit_alloc_stages) catch {
            return error.Corrupt;
        };
        if (ret != 0) {
            // 块解码失败：静音
            for (0..oc) |ch| {
                @memset(blk_out[ch * t.AC3_FRAME_SIZE + off ..][0..t.AC3_BLOCK_SIZE], 0);
            }
        } else {
            for (0..oc) |ch| {
                const map: usize = channel_map_tab[@as(usize, @intCast(s.output_mode & 7))][@intCast(s.lfe_on)][ch];
                @memcpy(blk_out[ch * t.AC3_FRAME_SIZE + off ..][0..t.AC3_BLOCK_SIZE], s.output[map][0..t.AC3_BLOCK_SIZE]);
            }
        }
    }

    // 转 s16 交错
    const nch = f.channels;
    if (nch == 0 or nch > 8 or s.num_blocks <= 0 or s.num_blocks > 6) return error.Corrupt;
    const total_samples = blk_count * t.AC3_BLOCK_SIZE;
    if (total_samples * nch > f.out.len) return error.Corrupt;
    for (0..total_samples) |i| {
        for (0..nch) |ch| {
            const v: f32 = blk_out[ch * t.AC3_FRAME_SIZE + i];
            const iv: i32 = @intFromFloat(std.math.clamp(v, -1.0, 1.0) * 32767.0);
            f.out[i * nch + ch] = @intCast(iv);
        }
    }
    f.out_len = total_samples * nch;
    f.frames_done += 1;

    return true;
    }
}

fn parseHeaderInto(s: *c.Ctx, h: *const hdr.Header) Error!void {
    s.bit_alloc_params.sr_code = h.sr_code;
    s.bit_alloc_params.sr_shift = h.sr_shift;
    s.frame_type = h.frame_type;
    s.substreamid = h.substreamid;
    s.frame_size = h.frame_size;
    s.bit_rate = @intCast(h.bit_rate);
    s.sample_rate = @intCast(h.sample_rate);
    s.num_blocks = h.num_blocks;
    s.bitstream_id = h.bitstream_id;
    s.bitstream_mode = h.bitstream_mode;
    s.channel_mode = h.channel_mode;
    s.lfe_on = h.lfe_on;
    s.center_mix_level = h.center_mix_level;
    s.surround_mix_level = h.surround_mix_level;
    s.channels = h.channels;
    s.fbw_channels = s.channels - s.lfe_on;
    s.lfe_ch = s.fbw_channels + 1;
    s.out_channels = s.channels;
    s.output_mode = s.channel_mode;
    if (s.lfe_on != 0) s.output_mode |= c.AC3_OUTPUT_LFEON;
    if (h.bitstream_id <= 10) {
        s.eac3 = 0;
        s.snr_offset_strategy = 2;
        s.block_switch_syntax = 1;
        s.dither_flag_syntax = 1;
        s.bit_allocation_syntax = 1;
        s.fast_gain_syntax = 0;
        s.first_cpl_leak = 0;
        s.dba_syntax = 1;
        s.skip_syntax = 1;
    } else {
        s.eac3 = 1;
        s.first_cpl_leak = 1;
    }
    if (s.channels != s.out_channels) dm.setDownmixCoeffs(s);
}

/// 解码一个音频块（对照 C decode_audio_block）
fn decodeAudioBlock(f: *DecoderCtx, s: *c.Ctx, blk: i32, offset: i32, bit_alloc_stages: *[t.AC3_MAX_CHANNELS]u8) Error!u8 {
    const gb = &s.gb;
    var different_transforms: i32 = 0;
    if (blk == 0) @memset(bit_alloc_stages, 0);

    // block switch flags
    if (s.block_switch_syntax != 0) {
        var ch: usize = 1;
        while (ch <= @as(usize, @intCast(s.fbw_channels))) : (ch += 1) {
            s.block_switch[ch] = @intCast(gb.readBits(1) catch return 1);
            if (ch > 1 and s.block_switch[ch] != s.block_switch[1]) different_transforms = 1;
        }
    }
    // dither flags
    if (s.dither_flag_syntax != 0) {
        var ch: usize = 1;
        while (ch <= @as(usize, @intCast(s.fbw_channels))) : (ch += 1) {
            s.dither_flag[ch] = @intCast(gb.readBits(1) catch return 1);
        }
    }
    // dynamic range
    var i: usize = if (s.channel_mode != 0) 0 else 1;
    while (true) {
        if ((gb.readBits(1) catch return 1) != 0) {
            const range_bits: usize = @intCast(gb.readBits(8) catch return 1);

            const range: f32 = dynamic_range_tab[range_bits];
            if (range_bits <= 127 or s.drc_scale <= 1.0) {
                s.dynamic_range[i] = std.math.pow(f32, range, s.drc_scale);
            } else {
                s.dynamic_range[i] = range;
            }
        } else if (blk == 0) {
            s.dynamic_range[i] = 1.0;
        }
        if (i == 0) break;
        i -= 1;
    }

    // spectral extension strategy (E-AC-3)
    if (s.eac3 != 0 and (blk == 0 or (gb.readBits(1) catch return 1) != 0)) {
        s.spx_in_use = @intCast(gb.readBits(1) catch return 1);
        if (s.spx_in_use != 0) {
            if (spxStrategy(s, blk)) return 1;
        }
    }
    if (s.eac3 == 0 or s.spx_in_use == 0) {
        s.spx_in_use = 0;
        var spx_ch: usize = 1;
        while (spx_ch <= @as(usize, @intCast(s.fbw_channels))) : (spx_ch += 1) {
            s.channel_uses_spx[spx_ch] = 0;
            s.first_spx_coords[spx_ch] = 1;
        }
    }
    if (s.spx_in_use != 0) {
        if (spxCoordinates(s)) return 1;
    }

    // coupling strategy（对照 C decode_audio_block：E-AC-3 无 cpl_strategy 时不做任何事）
    var cpl_in_use: i32 = 0;
    if (s.eac3 != 0) {
        if (s.cpl_strategy_exists[@intCast(blk)] != 0) {
            if (cp.couplingStrategy(s, blk, bit_alloc_stages)) return 1;
        }
    } else {
        if ((gb.readBits(1) catch return 1) != 0) {
            if (cp.couplingStrategy(s, blk, bit_alloc_stages)) return 1;
        } else if (blk == 0) {
            return 1;
        } else {
            s.cpl_in_use[@intCast(blk)] = s.cpl_in_use[@intCast(blk - 1)];
        }
    }
    cpl_in_use = s.cpl_in_use[@intCast(blk)];

    // coupling coordinates
    if (cpl_in_use != 0) {
        if (cp.couplingCoordinates(s, blk)) return 1;
    }

    // rematrixing flags
    if (s.channel_mode == t.AC3_CHMODE_STEREO) {
        if ((s.eac3 != 0 and blk == 0) or (gb.readBits(1) catch return 1) != 0) {
            s.num_rematrixing_bands = 4;
            if (cpl_in_use != 0 and s.start_freq[t.CPL_CH] <= 61) {
                s.num_rematrixing_bands -= 1 + @as(i32, @intFromBool(s.start_freq[t.CPL_CH] == 37));
            } else if (s.spx_in_use != 0 and s.spx_src_start_freq <= 61) {
                s.num_rematrixing_bands -= 1;
            }
            for (0..@as(usize, @intCast(s.num_rematrixing_bands))) |bnd| {
                s.rematrixing_flags[bnd] = @intCast(gb.readBits(1) catch return 1);
            }
        } else if (blk == 0) {
            s.num_rematrixing_bands = 0;
        }
    }

    // exponent strategies
    var ch: usize = if (cpl_in_use != 0) 0 else 1;
    while (ch <= @as(usize, @intCast(s.channels))) : (ch += 1) {
        if (s.eac3 == 0) {
            s.exp_strategy[@intCast(blk)][ch] = @intCast(gb.readBits(if (ch == @as(usize, @intCast(s.lfe_ch))) 2 else 2) catch return 1);
        }
        if (s.exp_strategy[@intCast(blk)][ch] != t.EXP_REUSE) bit_alloc_stages[ch] = 3;
    }

    // channel bandwidth
    ch = 1;
    while (ch <= @as(usize, @intCast(s.fbw_channels))) : (ch += 1) {
        s.start_freq[ch] = 0;
        if (s.exp_strategy[@intCast(blk)][ch] != t.EXP_REUSE) {
            const prev = s.end_freq[ch];
            if (s.channel_in_cpl[ch] != 0) {
                s.end_freq[ch] = s.start_freq[t.CPL_CH];
            } else if (s.channel_uses_spx[ch] != 0) {
                s.end_freq[ch] = s.spx_src_start_freq;
            } else {
                const bandwidth_code: usize = @intCast(gb.readBits(6) catch return 1);
                if (bandwidth_code > 60) return 1;
                s.end_freq[ch] = @intCast(bandwidth_code * 3 + 73);
            }
            const group_size: i32 = @as(i32, 3) << @as(u5, @intCast(@as(u32, @intCast(s.exp_strategy[@intCast(blk)][ch] - 1))));
            s.num_exp_groups[ch] = @intCast(@divTrunc(s.end_freq[ch] + group_size - 4, group_size));
            if (blk > 0 and s.end_freq[ch] != prev) {
                for (0..t.AC3_MAX_CHANNELS) |k| bit_alloc_stages[k] = 3;
            }
        }
    }
    if (cpl_in_use != 0 and s.exp_strategy[@intCast(blk)][t.CPL_CH] != t.EXP_REUSE) {
        s.num_exp_groups[t.CPL_CH] = @intCast(@divTrunc(s.end_freq[t.CPL_CH] - s.start_freq[t.CPL_CH],
            @as(i32, 3) << @as(u5, @intCast(@as(u32, @intCast(s.exp_strategy[@intCast(blk)][t.CPL_CH] - 1))))));
    }
    // LFE 带宽（对照 C parse_frame_header：每帧 end_freq=7, ngrp=2）
    if (s.lfe_on != 0) {
        s.start_freq[@as(usize, @intCast(s.lfe_ch))] = 0;
        s.end_freq[@as(usize, @intCast(s.lfe_ch))] = 7;
        s.num_exp_groups[@as(usize, @intCast(s.lfe_ch))] = 2;
    }

    // decode exponents
    ch = if (cpl_in_use != 0) 0 else 1;
    while (ch <= @as(usize, @intCast(s.channels))) : (ch += 1) {
        if (s.exp_strategy[@intCast(blk)][ch] != t.EXP_REUSE) {
            const exp1: i32 = @as(i32, @intCast(gb.readBits(4) catch return 1)) << @intFromBool(ch == 0);
            const strategy: u8 = @intCast(s.exp_strategy[@intCast(blk)][ch]);
            const ngrp: i32 = s.num_exp_groups[ch];
            const start: usize = @as(usize, @intCast(s.start_freq[ch])) + @intFromBool(ch != 0);
            s.dexps[ch][0] = @intCast(exp1);
            if (ex.decodeExponents(s, strategy, ngrp, exp1, s.dexps[ch][start..])) return 1;
            if (ch != t.CPL_CH and ch != @as(usize, @intCast(s.lfe_ch))) {
                _ = gb.readBits(2) catch return 1; // gainrng
            }
        }
    }

    // bit allocation info
    if (s.bit_allocation_syntax != 0) {
        if ((gb.readBits(1) catch return 1) != 0) {
            s.bit_alloc_params.slow_decay = @as(i32, t.slow_decay_tab[gb.readBits(2) catch return 1]) >> @intCast(s.bit_alloc_params.sr_shift);
            s.bit_alloc_params.fast_decay = @as(i32, t.fast_decay_tab[gb.readBits(2) catch return 1]) >> @intCast(s.bit_alloc_params.sr_shift);
            s.bit_alloc_params.slow_gain = t.slow_gain_tab[gb.readBits(2) catch return 1];
            s.bit_alloc_params.db_per_bit = t.db_per_bit_tab[gb.readBits(2) catch return 1];
            s.bit_alloc_params.floor = t.floor_tab[gb.readBits(3) catch return 1];
            ch = if (cpl_in_use != 0) 0 else 1;
            while (ch <= @as(usize, @intCast(s.channels))) : (ch += 1) {
                bit_alloc_stages[ch] = @max(bit_alloc_stages[ch], 2);
            }
        } else if (blk == 0) {
            return 1;
        }
    }

    // snr offsets / fast gain
    if (s.eac3 == 0) {
        if (s.snr_offset_strategy != 0 and (gb.readBits(1) catch return 1) != 0) {
            var snr: i32 = 0;
            const csnr: i32 = (@as(i32, @intCast(gb.readBits(6) catch return 1)) - 15) << 4;
            i = if (cpl_in_use != 0) 0 else 1;
            ch = i;
            while (ch <= @as(usize, @intCast(s.channels))) : (ch += 1) {
                if (ch == i or s.snr_offset_strategy == 2) {
                    snr = (csnr + @as(i32, @intCast(gb.readBits(4) catch return 1))) << 2;
                }
                if (blk != 0 and s.snr_offset[ch] != snr) bit_alloc_stages[ch] = @max(bit_alloc_stages[ch], 1);
                s.snr_offset[ch] = snr;
                const prev = s.fast_gain[ch];
                s.fast_gain[ch] = t.fast_gain_tab[gb.readBits(3) catch return 1];
                if (blk != 0 and prev != s.fast_gain[ch]) bit_alloc_stages[ch] = @max(bit_alloc_stages[ch], 2);
            }
        } else if (blk == 0) {
            return 1;
        }
    }

    // fast gain (E-AC-3 only)
    if (s.fast_gain_syntax != 0 and (gb.readBits(1) catch return 1) != 0) {
        ch = if (cpl_in_use != 0) 0 else 1;
        while (ch <= @as(usize, @intCast(s.channels))) : (ch += 1) {
            const prev = s.fast_gain[ch];
            s.fast_gain[ch] = t.fast_gain_tab[gb.readBits(3) catch return 1];
            if (blk != 0 and prev != s.fast_gain[ch]) bit_alloc_stages[ch] = @max(bit_alloc_stages[ch], 2);
        }
    } else if (s.eac3 != 0 and blk == 0) {
        ch = if (cpl_in_use != 0) 0 else 1;
        while (ch <= @as(usize, @intCast(s.channels))) : (ch += 1) s.fast_gain[ch] = t.fast_gain_tab[4];
    }

    // E-AC-3 转换器 SNR offset
    if (s.frame_type == t.EAC3_FRAME_TYPE_INDEPENDENT and (gb.readBits(1) catch return 1) != 0) {
        _ = gb.skipBits(10) catch return 1;
    }

    // coupling leak
    if (cpl_in_use != 0) {
        if (s.first_cpl_leak != 0 or (gb.readBits(1) catch return 1) != 0) {
            const fl: i32 = @intCast(gb.readBits(3) catch return 1);
            const sl: i32 = @intCast(gb.readBits(3) catch return 1);
            if (blk != 0 and (fl != s.bit_alloc_params.cpl_fast_leak or sl != s.bit_alloc_params.cpl_slow_leak)) {
                bit_alloc_stages[t.CPL_CH] = @max(bit_alloc_stages[t.CPL_CH], 2);
            }
            s.bit_alloc_params.cpl_fast_leak = fl;
            s.bit_alloc_params.cpl_slow_leak = sl;
        } else if (blk == 0) {
            return 1;
        }
        s.first_cpl_leak = 0;
    }

    // delta bit allocation
    if (s.dba_syntax != 0 and (gb.readBits(1) catch return 1) != 0) {
        ch = if (cpl_in_use != 0) 0 else 1;
        while (ch <= @as(usize, @intCast(s.fbw_channels))) : (ch += 1) {
            s.dba_mode[ch] = @intCast(gb.readBits(2) catch return 1);
            if (s.dba_mode[ch] == t.DBA_RESERVED) return 1;
            bit_alloc_stages[ch] = @max(bit_alloc_stages[ch], 2);
        }
        ch = if (cpl_in_use != 0) 0 else 1;
        while (ch <= @as(usize, @intCast(s.fbw_channels))) : (ch += 1) {
            if (s.dba_mode[ch] == t.DBA_NEW) {
                s.dba_nsegs[ch] = @as(i32, @intCast(gb.readBits(3) catch return 1)) + 1;
                var seg: usize = 0;
                while (seg < @as(usize, @intCast(s.dba_nsegs[ch]))) : (seg += 1) {
                    s.dba_offsets[ch][seg] = @intCast(gb.readBits(5) catch return 1);
                    s.dba_lengths[ch][seg] = @intCast(gb.readBits(4) catch return 1);
                    s.dba_values[ch][seg] = @intCast(gb.readBits(3) catch return 1);
                }
                bit_alloc_stages[ch] = @max(bit_alloc_stages[ch], 2);
            }
        }
    } else if (blk == 0) {
        for (0..t.AC3_MAX_CHANNELS) |kk| s.dba_mode[kk] = t.DBA_NONE;
    }

    // bit allocation
    ch = if (cpl_in_use != 0) 0 else 1;
    while (ch <= @as(usize, @intCast(s.channels))) : (ch += 1) {
        if (bit_alloc_stages[ch] > 2) {
            ba.bitAllocCalcPsd(&s.dexps[ch], @intCast(s.start_freq[ch]), @intCast(s.end_freq[ch]), &s.psd[ch], &s.band_psd[ch]);
        }
        if (bit_alloc_stages[ch] > 1) {
            if (ba.bitAllocCalcMask(&s.bit_alloc_params, &s.band_psd[ch], @intCast(s.start_freq[ch]), @intCast(s.end_freq[ch]), s.fast_gain[ch], ch == @as(usize, @intCast(s.lfe_ch)), @intCast(s.dba_mode[ch]), @intCast(s.dba_nsegs[ch]), &s.dba_offsets[ch], &s.dba_lengths[ch], &s.dba_values[ch], &s.mask[ch])) return 1;
        }
        if (bit_alloc_stages[ch] > 0) {
            const bap_tab = if (s.channel_uses_aht[ch] != 0) &t.eac3_hebap_tab else &t.bap_tab;
            ba.bitAllocCalcBap(&s.mask[ch], &s.psd[ch], @intCast(s.start_freq[ch]), @intCast(s.end_freq[ch]), s.snr_offset[ch], s.bit_alloc_params.floor, bap_tab, &s.bap[ch]);
        }
    }

    // skip
    if (s.skip_syntax != 0 and (gb.readBits(1) catch return 1) != 0) {
        const skipl: u32 = @intCast(gb.readBits(9) catch return 1);
        gb.skipBits(skipl * 8) catch return 1;
    }

    if (mn.decodeTransformCoeffs(s, blk)) return 1;

    // scaling（对照 C：先对 coeffs 缩放写入 transform_coeffs，再 rematrixing）
    ch = 1;
    while (ch <= @as(usize, @intCast(s.channels))) : (ch += 1) {
        var audio_channel: usize = 0;
        if (s.channel_mode == t.AC3_CHMODE_DUALMONO and ch <= 2) audio_channel = 2 - ch;
        var gain: f32 = s.dynamic_range[audio_channel];
        if (s.target_level != 0) gain *= s.level_gain[audio_channel];
        gain *= 1.0 / 4194304.0;
        for (0..t.AC3_BLOCK_SIZE) |bin| {
            s.transform_coeffs[ch][bin] = s.coeffs[ch][bin] * gain;
        }
    }

    // rematrixing（线性，作用于缩放后的 transform_coeffs）
    if (s.channel_mode == t.AC3_CHMODE_STEREO) {
        dm.doRematrixing(s);
    }

    // 谱扩展（E-AC-3：高频系数重建，作用于缩放后的 transform_coeffs）
    if (s.spx_in_use != 0) {
        applySpectralExtension(s);
    }

    // downmix + IMDCT
    doImdct(f, s, @as(usize, @intCast(s.channels)), @intCast(offset));
    return 0;
}

/// IMDCT + KBD 窗 + 重叠相加（对照 C do_imdct）
fn doImdct(f: *DecoderCtx, s: *c.Ctx, channels: usize, offset: i32) void {
    var ch: usize = 1;
    while (ch <= channels) : (ch += 1) {
        const dch = ch - 1 + @as(usize, @intCast(offset));
        if (s.block_switch[ch] != 0) {
            // 短块：256 点变换拆成两个 128 点 IMDCT（偶/奇系数）
            for (0..128) |i| {
                s.tmp_output[i + 128] = s.transform_coeffs[ch][2 * i];
            }
            f.mdct_128.transform(&s.tmp_output, s.tmp_output[128..256], &f.scratch);
            vectorFmulWindow(s.output[ch - 1][0..], s.delay[dch][0..128], s.tmp_output[0..128], &kb.window_256);
            for (0..128) |i| {
                s.tmp_output[i + 128] = s.transform_coeffs[ch][2 * i + 1];
            }
            f.mdct_128.transform(&s.delay[dch], s.tmp_output[128..256], &f.scratch);
        } else {
            // 长块：256 点 IMDCT
            f.mdct_256.transform(&s.tmp_output, &s.transform_coeffs[ch], &f.scratch);
            vectorFmulWindow(s.output[ch - 1][0..], s.delay[dch][0..128], s.tmp_output[0..128], &kb.window_256);
            @memcpy(s.delay[dch][0..128], s.tmp_output[128..256]);
        }
    }
}

/// 窗函数重叠相加（对照 FFmpeg float_dsp vector_fmul_window，len=128 → 256 输出）
/// 输出为镜像对：dst[k] 与 dst[2len-1-k] 由 src0[k] 与 src1[len-1-k] 合成。
fn vectorFmulWindow(dst: []f32, src0: []const f32, src1: []const f32, win: *const [256]f32) void {
    const len = src0.len;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        dst[i] = src0[i] * win[2 * len - 1 - i] - src1[len - 1 - i] * win[i];
        dst[2 * len - 1 - i] = src0[i] * win[i] + src1[len - 1 - i] * win[2 * len - 1 - i];
    }
}

fn positionMsImpl(ctx: *anyopaque) i64 {
    const f: *DecoderCtx = @ptrCast(@alignCast(ctx));
    if (f.sample_rate == 0) return 0;
    const ms = @divTrunc(@as(i128, @intCast(f.frames_done)) * t.AC3_FRAME_SIZE * 1000, @as(i128, f.sample_rate));
    return @intCast(ms);
}

fn seekMsImpl(ctx: *anyopaque, ms_arg: i64) Error!void {
    const f: *DecoderCtx = @ptrCast(@alignCast(ctx));
    const ms: i64 = if (ms_arg < 0) 0 else ms_arg;
    if (f.sample_rate == 0) return error.Corrupt;
    const target_frames: u64 = @intCast((@as(u128, @intCast(ms)) * f.sample_rate) / (1000 * t.AC3_FRAME_SIZE));
    // 重置解码状态
    f.eof = false;
    f.out_pos = 0;
    f.out_len = 0;
    f.frames_done = 0;
    try f.reader.seek(0, .start);
    // 逐帧解码跳过（解码出的帧全部丢弃；readImpl 从目标帧重新解码）
    var guard: usize = 0;
    while (f.frames_done < target_frames) : (guard += 1) {
        if (guard > 2_000_000) return error.Corrupt;
        if (!try decodeFrame(f)) return error.Corrupt;
    }
    f.out_pos = 0;
    f.out_len = 0;
}

fn deinitImpl(ctx: *anyopaque) void {
    const f: *DecoderCtx = @ptrCast(@alignCast(ctx));
    f.reader.deinit();
    f.allocator.destroy(f);
}

/// E-AC-3 帧级解析（对照 ff_eac3_parse_header；在块循环前调用一次）
/// 谱扩展坐标（对照 C `spx_coordinates`）。读每带 blend 坐标 → noise/signal blend 表。
fn spxCoordinates(s: *c.Ctx) bool {
    const gb = &s.gb;
    var ch: usize = 1;
    while (ch <= @as(usize, @intCast(s.fbw_channels))) : (ch += 1) {
        if (s.channel_uses_spx[ch] != 0) {
            if (s.first_spx_coords[ch] != 0 or (gb.readBits(1) catch return true) != 0) {
                s.first_spx_coords[ch] = 0;
                const spx_blend: f32 = @as(f32, @floatFromInt(gb.readBits(5) catch return true)) / 32.0;
                const master_spx_coord: i32 = 3 * @as(i32, @intCast(gb.readBits(2) catch return true));
                var bin: i32 = s.spx_src_start_freq;
                var bnd: usize = 0;
                while (bnd < @as(usize, @intCast(s.num_spx_bands))) : (bnd += 1) {
                    const bandsize: f32 = @floatFromInt(s.spx_band_sizes[bnd]);
                    var nratio: f32 = (@as(f32, @floatFromInt(bin)) + bandsize * 0.5) /
                        @as(f32, @floatFromInt(s.spx_dst_end_freq)) - spx_blend;
                    nratio = std.math.clamp(nratio, 0.0, 1.0);
                    const nblend: f32 = @sqrt(3.0 * nratio);
                    const sblend: f32 = @sqrt(1.0 - nratio);
                    bin += @as(i32, @intCast(s.spx_band_sizes[bnd]));
                    const spx_coord_exp: i32 = @intCast(gb.readBits(4) catch return true);
                    var spx_coord_mant: i32 = @intCast(gb.readBits(2) catch return true);
                    if (spx_coord_exp == 15) spx_coord_mant <<= 1 else spx_coord_mant += 4;
                    const shift: i32 = 25 - spx_coord_exp - master_spx_coord;
                    if (shift >= 0)
                        spx_coord_mant <<= @intCast(shift)
                    else
                        spx_coord_mant >>= @intCast(-shift);
                    const spx_coord: f32 = @as(f32, @floatFromInt(spx_coord_mant)) * (1.0 / 8388608.0);
                    s.spx_noise_blend[ch][bnd] = nblend * spx_coord;
                    s.spx_signal_blend[ch][bnd] = sblend * spx_coord;
                }
            }
        } else {
            s.first_spx_coords[ch] = 1;
        }
    }
    return false;
}

/// 应用谱扩展（对照 C `ff_eac3_apply_spectral_extension`）。将低频系数拷贝到
/// 高频扩展区，按 band 计算 RMS，做 notch 衰减与噪声/信号混合。
fn applySpectralExtension(s: *c.Ctx) void {
    var wrapflag = [_]u8{0} ** 17;
    wrapflag[0] = 1;
    var copy_sizes: [17]i32 = [_]i32{0} ** 17;
    var num_copy_sections: usize = 0;
    var bin: i32 = s.spx_dst_start_freq;
    var bnd: usize = 0;
    while (bnd < @as(usize, @intCast(s.num_spx_bands))) : (bnd += 1) {
        const bandsize: i32 = s.spx_band_sizes[bnd];
        if (bin + bandsize > s.spx_src_start_freq) {
            copy_sizes[num_copy_sections] = bin - s.spx_dst_start_freq;
            num_copy_sections += 1;
            bin = s.spx_dst_start_freq;
            wrapflag[bnd] = 1;
        }
        var i: i32 = 0;
        while (i < bandsize) {
            if (bin == s.spx_src_start_freq) {
                copy_sizes[num_copy_sections] = bin - s.spx_dst_start_freq;
                num_copy_sections += 1;
                bin = s.spx_dst_start_freq;
            }
            const copysize: i32 = @min(bandsize - i, s.spx_src_start_freq - bin);
            bin += copysize;
            i += copysize;
        }
    }
    copy_sizes[num_copy_sections] = bin - s.spx_dst_start_freq;
    num_copy_sections += 1;

    var ch: usize = 1;
    while (ch <= @as(usize, @intCast(s.fbw_channels))) : (ch += 1) {
        if (s.channel_uses_spx[ch] == 0) continue;

        // 拷贝低频系数到扩展区（每节源固定为 spx_dst_start_freq；
        // 逐元素拷贝避免 @memcpy 重叠 UB——wrap 节与源区重叠时须按 C memcpy 语义）
        bin = s.spx_src_start_freq;
        for (0..num_copy_sections) |i| {
            const n: usize = @intCast(copy_sizes[i]);
            const dst_i: usize = @intCast(bin);
            const src_i: usize = @intCast(s.spx_dst_start_freq);
            for (0..n) |k| s.transform_coeffs[ch][dst_i + k] = s.transform_coeffs[ch][src_i + k];
            bin += copy_sizes[i];
        }

        // 每带 RMS 能量
        var rms_energy: [17]f32 = undefined;
        bin = s.spx_src_start_freq;
        bnd = 0;
        while (bnd < @as(usize, @intCast(s.num_spx_bands))) : (bnd += 1) {
            const bandsize: usize = s.spx_band_sizes[bnd];
            var accum: f32 = 0.0;
            for (0..bandsize) |_| {
                const cv = s.transform_coeffs[ch][@as(usize, @intCast(bin))];
                accum += cv * cv;
                bin += 1;
            }
            rms_energy[bnd] = @sqrt(accum / @as(f32, @floatFromInt(bandsize)));
        }

        // notch 衰减（normal→extension 过渡 + wrap 点）
        if (s.spx_atten_code[ch] >= 0) {
            const atten_tab = &t.eac3_spx_atten_tab[@as(usize, @intCast(s.spx_atten_code[ch]))];
            bin = s.spx_src_start_freq - 2;
            bnd = 0;
            while (bnd < @as(usize, @intCast(s.num_spx_bands))) : (bnd += 1) {
                if (wrapflag[bnd] != 0) {
                    const co = s.transform_coeffs[ch][@as(usize, @intCast(bin))..][0..5];
                    co[0] *= atten_tab[0];
                    co[1] *= atten_tab[1];
                    co[2] *= atten_tab[2];
                    co[3] *= atten_tab[1];
                    co[4] *= atten_tab[0];
                }
                bin += @as(i32, @intCast(s.spx_band_sizes[bnd]));
            }
        }

        // 噪声混合
        bin = s.spx_src_start_freq;
        bnd = 0;
        while (bnd < @as(usize, @intCast(s.num_spx_bands))) : (bnd += 1) {
            const bandsize: usize = s.spx_band_sizes[bnd];
            const nscale: f32 = s.spx_noise_blend[ch][bnd] * rms_energy[bnd] * (1.0 / -2147483648.0);
            const sscale: f32 = s.spx_signal_blend[ch][bnd];
            for (0..bandsize) |_| {
                const noise: f32 = nscale * @as(f32, @floatFromInt(@as(i32, @bitCast(mn.nextDith()))));
                s.transform_coeffs[ch][@as(usize, @intCast(bin))] =
                    s.transform_coeffs[ch][@as(usize, @intCast(bin))] * sscale + noise;
                bin += 1;
            }
        }
    }
}

fn spxStrategy(s: *c.Ctx, blk: i32) bool {
    const gb = &s.gb;
    const fbw_channels = s.fbw_channels;
    if (s.channel_mode == @as(i32, t.AC3_CHMODE_MONO)) {
        s.channel_uses_spx[1] = 1;
    } else {
        const cu: u32 = gb.readBits(@intCast(fbw_channels)) catch return true;
        var ch2: usize = @intCast(fbw_channels);
        while (ch2 >= 1) : (ch2 -= 1) {
            s.channel_uses_spx[ch2] = @intCast((cu >> @intCast(fbw_channels - @as(i32, @intCast(ch2)))) & 1);
        }
    }
    const dst_start_freq: i32 = @intCast(gb.readBits(2) catch return true);
    var start_subband: i32 = @as(i32, @intCast(gb.readBits(3) catch return true)) + 2;
    if (start_subband > 7) start_subband += start_subband - 7;
    var end_subband: i32 = @as(i32, @intCast(gb.readBits(3) catch return true)) + 5;
    if (end_subband > 7) end_subband += end_subband - 7;
    const dst_start: i32 = dst_start_freq * 12 + 25;
    const src_start: i32 = start_subband * 12 + 25;
    const dst_end: i32 = end_subband * 12 + 25;
    if (start_subband >= end_subband) return true;
    if (dst_start >= src_start) return true;
    s.spx_dst_start_freq = dst_start;
    s.spx_src_start_freq = src_start;
    s.spx_dst_end_freq = dst_end;
    s.num_spx_bands = cp.decodeBandStructureInner(
        gb,
        blk,
        s.eac3,
        0,
        start_subband,
        end_subband,
        &t.eac3_default_spx_band_struct,
        &s.spx_band_struct,
        &s.spx_band_sizes,
    ) catch return true;
    return false;
}

fn parseEac3Frame(s: *c.Ctx) Error!void {
    const gb = &s.gb;
    var ch: usize = 0;
    var blk: usize = 0;
    var ac3_exponent_strategy: u8 = 0;
    var parse_aht_info: u8 = 0;

    if (s.num_blocks == 6) {
        ac3_exponent_strategy = @intCast(gb.readBits(1) catch return error.Corrupt);
        parse_aht_info = @intCast(gb.readBits(1) catch return error.Corrupt);
    } else {
        ac3_exponent_strategy = 1;
        parse_aht_info = 0;
    }

    s.snr_offset_strategy = @intCast(gb.readBits(2) catch return error.Corrupt);
    const parse_transient_proc_info: u8 = @intCast(gb.readBits(1) catch return error.Corrupt);

    s.block_switch_syntax = @intCast(gb.readBits(1) catch return error.Corrupt);
    if (s.block_switch_syntax == 0) {
        @memset(&s.block_switch, 0);
    }

    s.dither_flag_syntax = @intCast(gb.readBits(1) catch return error.Corrupt);
    if (s.dither_flag_syntax == 0) {
        ch = 1;
        while (ch <= @as(usize, @intCast(s.fbw_channels))) : (ch += 1) s.dither_flag[ch] = 1;
    }
    s.dither_flag[0] = 0;
    s.dither_flag[@as(usize, @intCast(s.lfe_ch))] = 0;

    s.bit_allocation_syntax = @intCast(gb.readBits(1) catch return error.Corrupt);
    if (s.bit_allocation_syntax == 0) {
        s.bit_alloc_params.slow_decay = t.slow_decay_tab[2];
        s.bit_alloc_params.fast_decay = t.fast_decay_tab[1];
        s.bit_alloc_params.slow_gain = t.slow_gain_tab[1];
        s.bit_alloc_params.db_per_bit = t.db_per_bit_tab[2];
        s.bit_alloc_params.floor = -2048;
    }

    s.fast_gain_syntax = @intCast(gb.readBits(1) catch return error.Corrupt);
    s.dba_syntax = @intCast(gb.readBits(1) catch return error.Corrupt);
    s.skip_syntax = @intCast(gb.readBits(1) catch return error.Corrupt);
    const parse_spx_atten_data: u8 = @intCast(gb.readBits(1) catch return error.Corrupt);

    // 耦合策略存在位 + 每块耦合使用
    var num_cpl_blocks: i32 = 0;
    if (s.channel_mode > 1) {
        blk = 0;
        while (blk < @as(usize, @intCast(s.num_blocks))) : (blk += 1) {
            s.cpl_strategy_exists[blk] = if (blk == 0) 1 else @intCast(gb.readBits(1) catch return error.Corrupt);
            if (s.cpl_strategy_exists[blk] != 0) {
                s.cpl_in_use[blk] = @intCast(gb.readBits(1) catch return error.Corrupt);
            } else {
                s.cpl_in_use[blk] = s.cpl_in_use[blk - 1];
            }
            num_cpl_blocks += s.cpl_in_use[blk];
        }
    } else {
        for (0..t.AC3_MAX_BLOCKS) |b| s.cpl_in_use[b] = 0;
    }

    // 指数策略
    if (ac3_exponent_strategy != 0) {
        blk = 0;
        while (blk < @as(usize, @intCast(s.num_blocks))) : (blk += 1) {
            ch = if (s.cpl_in_use[blk] != 0) 0 else 1;
            while (ch <= @as(usize, @intCast(s.fbw_channels))) : (ch += 1) {
                s.exp_strategy[blk][ch] = @intCast(gb.readBits(2) catch return error.Corrupt);
            }
        }
    } else {
        ch = if (s.channel_mode > 1 and num_cpl_blocks > 0) 0 else 1;
        while (ch <= @as(usize, @intCast(s.fbw_channels))) : (ch += 1) {
            const frmchexpstr: usize = @intCast(gb.readBits(5) catch return error.Corrupt);
            blk = 0;
            while (blk < 6) : (blk += 1) {
                s.exp_strategy[blk][ch] = t.eac3_frm_expstr[frmchexpstr][blk];
            }
        }
    }
    // LFE 指数策略
    if (s.lfe_on != 0) {
        blk = 0;
        while (blk < @as(usize, @intCast(s.num_blocks))) : (blk += 1) {
            s.exp_strategy[blk][@as(usize, @intCast(s.lfe_ch))] = @intCast(gb.readBits(1) catch return error.Corrupt);
        }
    }
    // AC-3 转换流的原始指数策略
    if (s.frame_type == t.EAC3_FRAME_TYPE_INDEPENDENT and
        (s.num_blocks == 6 or (gb.readBits(1) catch return error.Corrupt) != 0))
    {
        _ = gb.skipBits(@intCast(5 * s.fbw_channels)) catch return error.Corrupt;
    }

    // AHT 使用
    if (parse_aht_info != 0) {
        s.channel_uses_aht[0] = 0;
        ch = if (num_cpl_blocks != 6) 1 else 0;
        while (ch <= @as(usize, @intCast(s.channels))) : (ch += 1) {
            var use_aht: u8 = 1;
            blk = 1;
            while (blk < 6) : (blk += 1) {
                if (s.exp_strategy[blk][ch] != t.EXP_REUSE or
                    (ch == 0 and s.cpl_strategy_exists[blk] != 0))
                {
                    use_aht = 0;
                    break;
                }
            }
            s.channel_uses_aht[ch] = if (use_aht != 0) @intCast(gb.readBits(1) catch return error.Corrupt) else 0;
        }
    } else {
        for (0..t.AC3_MAX_CHANNELS) |c2| s.channel_uses_aht[c2] = 0;
    }

    // 帧级 SNR offset
    if (s.snr_offset_strategy == 0) {
        const csnroffst: i32 = (@as(i32, @intCast(gb.readBits(6) catch return error.Corrupt)) - 15) << 4;
        const snroffst: i32 = (csnroffst + @as(i32, @intCast(gb.readBits(4) catch return error.Corrupt))) << 2;
        ch = 0;
        while (ch <= @as(usize, @intCast(s.channels))) : (ch += 1) s.snr_offset[ch] = snroffst;
    }

    // 瞬态预噪声处理数据
    if (parse_transient_proc_info != 0) {
        ch = 1;
        while (ch <= @as(usize, @intCast(s.fbw_channels))) : (ch += 1) {
            if ((gb.readBits(1) catch return error.Corrupt) != 0) {
                _ = gb.skipBits(18) catch return error.Corrupt;
            }
        }
    }

    // SPX 衰减
    ch = 1;
    while (ch <= @as(usize, @intCast(s.fbw_channels))) : (ch += 1) {
        if (parse_spx_atten_data != 0 and (gb.readBits(1) catch return error.Corrupt) != 0) {
            s.spx_atten_code[ch] = @intCast(gb.readBits(5) catch return error.Corrupt);
        } else {
            s.spx_atten_code[ch] = -1;
        }
    }

    // 块起始信息
    if (s.num_blocks > 1 and (gb.readBits(1) catch return error.Corrupt) != 0) {
        const block_start_bits = (@as(usize, @intCast(s.num_blocks)) - 1) * (4 + std.math.log2_int(u64, @max(s.frame_size - 2, 1)));
        _ = gb.skipBits(@intCast(block_start_bits)) catch return error.Corrupt;
    }

    // 语法状态初始化
    ch = 1;
    while (ch <= @as(usize, @intCast(s.fbw_channels))) : (ch += 1) {
        s.first_spx_coords[ch] = 1;
        s.first_cpl_coords[ch] = 1;
    }
    s.first_cpl_leak = 1;
}
