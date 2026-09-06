// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! MLP / Dolby TrueHD 无损解码器（对照 FFmpeg mlpdec.c / mlp.c / mlpdsp.c）
//!
//! 位流为 LSB-first（FFmpeg GetBitContext 语义）；MLP 无损打包，
//! 输出按 FFmpeg 声道顺序交错 s16。

const std = @import("std");
const c = @import("ctx.zig");
const t = @import("tables.zig");
const decoder = @import("../../decoder.zig");
const io = @import("../../io.zig");

// ---------------------------------------------------------------------------
// LSB-first 位读取（FFmpeg GetBitContext 语义）
// ---------------------------------------------------------------------------

pub const BitReader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn init(data: []const u8) BitReader {
        return .{ .data = data };
    }

    /// FFmpeg UNCHECKED 位读取：越界读 padding（0），不报错（与 C get_bits 一致）。
    fn readBit(self: *BitReader) u1 {
        var b: u1 = 0;
        if (self.pos < self.data.len * 8) {
            b = @intCast((self.data[self.pos >> 3] >> @intCast(7 - (self.pos & 7))) & 1);
        }
        self.pos += 1;
        return @intCast(b);
    }

    /// 读 n 位（MSB-first，FFmpeg get_bits 语义），第一个读的位在结果高位。
    pub fn readBits(self: *BitReader, n: u6) u32 {
        if (n == 0) return 0;
        var out: u32 = 0;
        var i: u6 = 0;
        while (i < n) : (i += 1) {
            out = (out << 1) | @as(u32, self.readBit());
        }
        return out;
    }

    pub fn readBitsLong(self: *BitReader, n: usize) u32 {
        var out: u32 = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            out = (out << 1) | @as(u32, self.readBit());
        }
        return out;
    }

    pub fn readSBits(self: *BitReader, n: u6) i32 {
        const v = self.readBits(n);
        const sign: u32 = @as(u32, 1) << @as(u5, @intCast(n - 1));
        if ((v & sign) != 0) return @as(i32, @bitCast(v | (~@as(u32, 0) << @as(u5, @intCast(n)))));
        return @intCast(v);
    }

    pub fn skipBits(self: *BitReader, n: usize) void {
        self.pos += n;
    }

    pub fn bitsCount(self: *const BitReader) usize {
        return self.pos;
    }
};

// ---------------------------------------------------------------------------
// CRC / 校验（对照 mlp.c）
// ---------------------------------------------------------------------------

/// av_crc 表生成（FFmpeg av_crc_init，MSB-first：左移 + av_bswap32）。
fn crcTableMsb(bits: u8, poly: u32) [256]u32 {
    var ctx: [256]u32 = undefined;
    for (0..256) |i| {
        var cv: u32 = @as(u32, @intCast(i)) << 24;
        for (0..8) |_| {
            const mask: u32 = if ((cv & 0x80000000) != 0) (poly << @intCast(32 - bits)) else 0;
            cv = (cv << 1) ^ mask;
        }
        ctx[i] = @byteSwap(cv);
    }
    return ctx;
}

/// av_crc 查表（FFmpeg av_crc）。
fn avCrc(ctx: *const [256]u32, init: u32, data: []const u8) u32 {
    var crc = init;
    for (data) |b| {
        crc = ctx[(crc & 0xFF) ^ b] ^ (crc >> 8);
    }
    return crc;
}

/// CRC-8 多项式 0x63（FFmpeg av_crc，初始 0x3c 用于 checksum8）。
fn crc8_63(data: []const u8, len: usize, init: u8) u8 {
    const ctx = crcTableMsb(8, 0x63);
    return @intCast(avCrc(&ctx, init, data[0..len]) & 0xFF);
}

/// CRC-16 多项式 0x002D（FFmpeg av_crc）。
fn crc16_2d(data: []const u8, len: usize) u16 {
    const ctx = crcTableMsb(16, 0x002D);
    return @intCast(avCrc(&ctx, 0, data[0..len]) & 0xFFFF);
}

/// CRC-8 多项式 0x1D（AV_CRC_8_EBU），用于 restart_checksum。
fn crc8_1d(data: []const u8, len: usize, init: u8) u8 {
    const ctx = crcTableMsb(8, 0x1D);
    return @intCast(avCrc(&ctx, init, data[0..len]) & 0xFF);
}

fn checksum16(buf: []const u8, size: usize) u16 {
    const crc = crc16_2d(buf, size - 2);
    return crc ^ (@as(u16, buf[size - 2]) | (@as(u16, buf[size - 1]) << 8));
}

fn checksum8(buf: []const u8, size: usize) u8 {
    // crc_63[0xa2] == 0x3c 作为初值
    const checksum = crc8_63(buf, size - 1, 0x3c);
    return checksum ^ buf[size - 1];
}

fn restartChecksum(buf: []const u8, bit_size: usize) u8 {
    const num_bytes = (bit_size + 2) / 8;
    var crc = crc8_1d(buf, num_bytes - 1, buf[0] & 0xC0);
    crc ^= buf[num_bytes - 1];
    var i: usize = 0;
    while (i < ((bit_size + 2) & 7)) : (i += 1) {
        crc <<= 1;
        if ((crc & 0x100) != 0) crc ^= 0x11D;
        crc ^= (buf[num_bytes] >> @intCast(7 - i)) & 1;
    }
    return crc;
}

fn xor32To8(v: u32) u8 {
    var x = v;
    x ^= x >> 16;
    x ^= x >> 8;
    return @intCast(x);
}

fn calculateParity(buf: []const u8, size: usize) u8 {
    var scratch: u32 = 0;
    for (buf[0..size]) |b| scratch ^= b;
    return xor32To8(scratch);
}

// ---------------------------------------------------------------------------
// Huffman VLC 解码（对照 mlpdec.c get_vlc2 + ff_mlp_huffman_tables）
// 码字 MSB-first 累积；表 {code, bits}，code 左对齐。
// ---------------------------------------------------------------------------

fn decodeHuffman(br: *BitReader, codebook: usize) i32 {
    const tbl = &t.huffman_tables[codebook - 1];
    const nsyms = t.huff_syms[codebook - 1];
    var code: u32 = 0;
    var len: usize = 0;
    while (len < 9) : (len += 1) {
        code = (code << 1) | @as(u32, br.readBit());
        var s: usize = 0;
        while (s < nsyms) : (s += 1) {
            if (tbl[s][1] == len + 1 and tbl[s][0] == code) return @intCast(s);
        }
    }
    return -1;
}

// ---------------------------------------------------------------------------
// 解析：主同步 / 重启头 / 滤波 / 矩阵 / 声道 / 解码参数
// ---------------------------------------------------------------------------

const MLPHeaderInfo = struct {
    stream_type: u8 = 0,
    header_size: i32 = 0,
    group1_bits: u8 = 0,
    group2_bits: u8 = 0,
    group1_samplerate: i32 = 0,
    group2_samplerate: i32 = 0,
    channel_arrangement: i32 = 0,
    channels_mlp: i32 = 0,
    channels_thd_stream1: i32 = 0,
    channels_thd_stream2: i32 = 0,
    channel_layout_mlp: u64 = 0,
    channel_layout_thd_stream1: u64 = 0,
    channel_layout_thd_stream2: u64 = 0,
    access_unit_size: i32 = 0,
    access_unit_size_pow2: i32 = 0,
    is_vbr: u8 = 0,
    peak_bitrate: i32 = 0,
    num_substreams: i32 = 0,
    extended_substream_info: i32 = 0,
    substream_info: i32 = 0,
    channel_modifier_thd_stream0: i32 = 0,
    channel_modifier_thd_stream1: i32 = 0,
    channel_modifier_thd_stream2: i32 = 0,
};

fn mlpSamplerate(in: i32) i32 {
    if (in == 0xF) return 0;
    const base: i32 = if ((in & 8) != 0) 44100 else 48000;
    return base << @as(u5, @intCast(in & 7));
}

fn truehdChannels(chanmap: i32) i32 {
    var channels: i32 = 0;
    var i: usize = 0;
    while (i < 13) : (i += 1) {
        channels += @as(i32, t.thd_chancount[i]) * @intFromBool(((chanmap >> @intCast(i)) & 1) != 0);
    }
    return channels;
}

fn truehdLayout(chanmap: i32) u64 {
    var layout: u64 = 0;
    var i: usize = 0;
    while (i < 13) : (i += 1) {
        layout |= @as(u64, t.thd_layout[i]) * @intFromBool(((chanmap >> @intCast(i)) & 1) != 0);
    }
    return layout;
}

fn majorSyncSize(buf: []const u8) i32 {
    if (buf.len < 28) return -1;
    if (@as(u32, buf[0]) << 24 | @as(u32, buf[1]) << 16 | @as(u32, buf[2]) << 8 | buf[3] == 0xf8726fba) {
        const has_extension = buf[25] & 1;
        if (has_extension != 0) {
            const extensions = buf[26] >> 4;
            return 28 + 2 + @as(i32, extensions) * 2;
        }
    }
    return 28;
}

fn readMajorSync(s: *c.Ctx, br: *BitReader, buf: []const u8) !void {
    _ = buf;
    const ms = br.data;
    var mh: MLPHeaderInfo = .{};
    var ratebits: i32 = 0;
    const header_size = majorSyncSize(ms);
    if (header_size < 0 or ms.len < @as(usize, @intCast(header_size))) return error.Corrupt;

    const cksum = checksum16(ms, @intCast(header_size - 2));
    const stored = @as(u16, ms[@intCast(header_size - 2)]) | (@as(u16, ms[@intCast(header_size - 1)]) << 8);
    if (cksum != stored) return error.Corrupt;

    const sync = br.readBits(24);
    if (sync != 0xf8726f) return error.Corrupt;

    mh.stream_type = @intCast(br.readBits(8));
    mh.header_size = header_size;

    if (mh.stream_type == 0xbb) {
        mh.group1_bits = t.mlp_quants[br.readBits(4)];
        mh.group2_bits = t.mlp_quants[br.readBits(4)];
        ratebits = @intCast(br.readBits(4));
        mh.group1_samplerate = mlpSamplerate(ratebits);
        mh.group2_samplerate = mlpSamplerate(@intCast(br.readBits(4)));
        br.skipBits(11);
        mh.channel_arrangement = @intCast(br.readBits(5));
        mh.channels_mlp = t.mlp_channels[@intCast(mh.channel_arrangement)];
        mh.channel_layout_mlp = t.mlp_layout[@intCast(mh.channel_arrangement)];
    } else if (mh.stream_type == 0xba) {
        mh.group1_bits = 24;
        mh.group2_bits = 0;
        ratebits = @intCast(br.readBits(4));
        mh.group1_samplerate = mlpSamplerate(ratebits);
        mh.group2_samplerate = 0;
        br.skipBits(4);
        mh.channel_modifier_thd_stream0 = @intCast(br.readBits(2));
        mh.channel_modifier_thd_stream1 = @intCast(br.readBits(2));
        mh.channel_arrangement = @intCast(br.readBits(5));
        mh.channels_thd_stream1 = truehdChannels(mh.channel_arrangement);
        mh.channel_layout_thd_stream1 = truehdLayout(mh.channel_arrangement);
        mh.channel_modifier_thd_stream2 = @intCast(br.readBits(2));
        const ca2: i32 = @intCast(br.readBits(13));
        mh.channels_thd_stream2 = truehdChannels(ca2);
        mh.channel_layout_thd_stream2 = truehdLayout(ca2);
    } else return error.Corrupt;

    mh.access_unit_size = @as(i32, 40) << @as(u5, @intCast(ratebits & 7));
    mh.access_unit_size_pow2 = @as(i32, 64) << @as(u5, @intCast(ratebits & 7));
    br.skipBits(48);
    mh.is_vbr = @intCast(br.readBits(1));
    mh.peak_bitrate = (@as(i32, @intCast(br.readBits(15))) * mh.group1_samplerate + 8) >> 4;
    mh.num_substreams = @intCast(br.readBits(4));
    br.skipBits(2);
    mh.extended_substream_info = @intCast(br.readBits(2));
    mh.substream_info = @intCast(br.readBits(8));

    // 跳到主同步头末尾（C：skip_bits_long((header_size-18)*8)）
    br.skipBits((@as(usize, @intCast(header_size)) - 18) * 8);

    if (mh.group1_bits == 0) return error.Corrupt;
    if (mh.group1_samplerate == 0 or mh.group1_samplerate > 192000) return error.Corrupt;
    if (mh.access_unit_size > c.MAX_BLOCKSIZE) return error.Corrupt;
    if (mh.num_substreams == 0 or mh.num_substreams > c.MAX_SUBSTREAMS) return error.Corrupt;

    s.major_sync_header_size = mh.header_size;
    s.access_unit_size = mh.access_unit_size;
    s.access_unit_size_pow2 = mh.access_unit_size_pow2;
    s.num_substreams = @intCast(mh.num_substreams);
    s.extended_substream_info = @intCast(mh.extended_substream_info);
    s.substream_info = @intCast(mh.substream_info);
    s.max_decoded_substream = @min(@as(u8, @intCast(mh.num_substreams)) - 1, 2);
    s.group1_bits = mh.group1_bits;
    s.group1_samplerate = mh.group1_samplerate;
    s.sample_rate = mh.group1_samplerate;

    // 声道数（TrueHD 用 stream2 或 stream1 的声道布局计数）
    if (mh.stream_type == 0xba) {
        s.stream_type = 0xba;
        s.is_atmos = (s.num_substreams == 4 and s.substream_info >> 7 == 1);
        // 8-channel 优先，其次 6-channel
        if (mh.channels_thd_stream2 != 0) {
            s.channels = @intCast(mh.channels_thd_stream2);
        } else {
            s.channels = @intCast(mh.channels_thd_stream1);
        }
    } else {
        s.stream_type = 0xbb;
        s.channels = @intCast(mh.channels_mlp);
    }
    if (mh.stream_type == 0xba) {
        s.substream[1].mask = mh.channel_layout_thd_stream1;
        if (mh.num_substreams > 1) s.substream[0].mask = 0x3;
        if (mh.num_substreams > 2) {
            if (mh.channel_layout_thd_stream2 != 0) {
                s.substream[2].mask = mh.channel_layout_thd_stream2;
            } else {
                s.substream[2].mask = mh.channel_layout_thd_stream1;
            }
        }
    } else {
        if (mh.num_substreams > 1) s.substream[0].mask = 0x3;
        s.substream[0].mask = mh.channel_layout_mlp;
    }
    s.out_channels = s.channels;
    s.params_valid = 1;
}

fn thdExtractChannel(layout: u64, index_in: u32) i32 {
    var index = index_in;
    if (@popCount(layout) <= index) return -1;
    var i: usize = 0;
    while (i < t.thd_channel_order.len) : (i += 1) {
        const ch = t.thd_channel_order[i];
        if ((layout & (@as(u64, 1) << @as(u6, @intCast(ch)))) != 0) {
            if (index == 0) return ch;
            index -= 1;
        }
    }
    return -1;
}

fn channelIndexInMask(mask: u64, ch: u32) i32 {
    if (ch >= 64 or (mask & (@as(u64, 1) << @as(u6, @intCast(ch)))) == 0) return -1;
    return @popCount(mask & ((@as(u64, 1) << @as(u6, @intCast(ch))) - 1));
}

// ---------------------------------------------------------------------------
// 重启头 + 滤波/矩阵/声道/解码参数（对照 mlpdec.c read_*）
// ---------------------------------------------------------------------------

fn readRestartHeader(s: *c.Ctx, br: *BitReader, buf: []const u8, substr: usize) !void {
    _ = buf;
    const st = &s.substream[substr];
    const std_max_matrix_channel: u8 = if (s.stream_type == 0xbb) c.MAX_MATRIX_CHANNEL_MLP else c.MAX_MATRIX_CHANNEL_TRUEHD;

    const sync_word = br.readBits(13);
    if (sync_word != (0x31ea >> 1)) return error.Corrupt;

    const noise_type = br.readBits(1);
    if (s.stream_type == 0xbb and noise_type != 0) return error.Corrupt;

    br.skipBits(16); // output timestamp

    const min_channel: u8 = @intCast(br.readBits(4));
    const max_channel: u8 = @intCast(br.readBits(4));
    const max_matrix_channel: u8 = @intCast(br.readBits(4));

    if (max_matrix_channel > std_max_matrix_channel) return error.Corrupt;
    const ch_range: i32 = @as(i32, max_channel) - @as(i32, min_channel) + 1;
    if (ch_range < 1 or ch_range > 64 or @as(i32, max_channel) + 1 > c.MAX_CHANNELS) return error.Corrupt;

    st.min_channel = min_channel;
    st.max_channel = max_channel;
    st.coded_channels = ((@as(u64, 1) << @as(u6, @intCast(ch_range))) - 1) << @as(u6, @intCast(min_channel));
    st.max_matrix_channel = max_matrix_channel;
    st.noise_type = @intCast(noise_type);

    st.noise_shift = @intCast(br.readBits(4));
    st.noisegen_seed = br.readBits(23);
    br.skipBits(19);
    st.data_check_present = @intCast(br.readBits(1));

    const lossless_check = br.readBits(8);
    if (substr == s.max_decoded_substream and st.lossless_check_data != 0xffffffff) {
        _ = lossless_check;
    }
    br.skipBits(16);

    @memset(&st.ch_assign, 0);
    var ch: usize = 0;
    while (ch <= st.max_matrix_channel) : (ch += 1) {
        var ch_assign: u8 = @intCast(br.readBits(6));
        if (s.stream_type == 0xba) {
            const channel = thdExtractChannel(st.mask, ch_assign);
            if (channel < 0) return error.Corrupt;
            const mapped = channelIndexInMask(st.mask, @intCast(channel));
            if (mapped < 0) return error.Corrupt;
            ch_assign = @intCast(mapped);
        }
        if (ch_assign > st.max_matrix_channel) return error.Corrupt;
        st.ch_assign[ch_assign] = @intCast(ch);
    }

    _ = br.readBits(8); // restart header checksum（对照位宽计算略）

    st.param_presence_flags = 0xff;
    st.num_primitive_matrices = 0;
    st.blocksize = 8;
    st.lossless_check_data = 0;
    @memset(&st.output_shift, 0);
    @memset(&st.quant_step_size, 0);

    ch = st.min_channel;
    while (ch <= st.max_channel) : (ch += 1) {
        const cp = &st.channel_params[ch];
        cp.filter_params[c.FIR].order = 0;
        cp.filter_params[c.IIR].order = 0;
        cp.filter_params[c.FIR].shift = 0;
        cp.filter_params[c.IIR].shift = 0;
        cp.huff_offset = 0;
        cp.sign_huff_offset = -(1 << 23);
        cp.codebook = 0;
        cp.huff_lsbs = 24;
    }
}

fn readFilterParams(s: *c.Ctx, br: *BitReader, substr: usize, channel: usize, filter: usize) !void {
    const st = &s.substream[substr];
    const fp = &st.channel_params[channel].filter_params[filter];
    const max_order: u32 = if (filter != 0) c.MAX_IIR_ORDER else c.MAX_FIR_ORDER;

    if (s.filter_changed[channel][filter] > 1) return error.Corrupt;
    s.filter_changed[channel][filter] += 1;

    const order: u32 = br.readBits(4);
    if (order > max_order) return error.Corrupt;
    fp.order = @intCast(order);

    if (order > 0) {
        const fcoeff = &st.channel_params[channel].coeff[filter];
        fp.shift = @intCast(br.readBits(4));
        const coeff_bits: u32 = br.readBits(5);
        const coeff_shift: u32 = br.readBits(3);
        if (coeff_bits < 1 or coeff_bits > 16) return error.Corrupt;
        if (coeff_bits + coeff_shift > 16) return error.Corrupt;

        var i: usize = 0;
        while (i < order) : (i += 1) {
            fcoeff[i] = (br.readSBits(@intCast(coeff_bits))) * (@as(i32, 1) << @as(u5, @intCast(coeff_shift)));
        }

        if ((br.readBits(1)) != 0) {
            if (filter == c.FIR) return error.Corrupt;
            const state_bits: u32 = br.readBits(4);
            const state_shift: u32 = br.readBits(4);
            i = 0;
            while (i < order) : (i += 1) {
                fp.state[i] = if (state_bits != 0)
                    (br.readSBits(@intCast(state_bits))) * (@as(i32, 1) << @as(u5, @intCast(state_shift)))
                else 0;
            }
        }
    }
}

fn readMatrixParams(s: *c.Ctx, br: *BitReader, substr: usize) !void {
    const st = &s.substream[substr];
    const max_primitive_matrices: u32 = if (s.stream_type == 0xbb) c.MAX_MATRICES_MLP else c.MAX_MATRICES_TRUEHD;

    if (s.matrix_changed > 1) return error.Corrupt;
    s.matrix_changed += 1;

    st.num_primitive_matrices = @intCast(br.readBits(4));
    if (st.num_primitive_matrices > max_primitive_matrices) {
        st.num_primitive_matrices = 0;
        @memset(&st.matrix_out_ch, 0);
        return error.Corrupt;
    }

    var mat: usize = 0;
    while (mat < st.num_primitive_matrices) : (mat += 1) {
        st.matrix_out_ch[mat] = @intCast(br.readBits(4));
        const frac_bits: u32 = br.readBits(4);
        st.lsb_bypass[mat] = @intCast(br.readBits(1));

        if (st.matrix_out_ch[mat] > st.max_matrix_channel) {
            st.num_primitive_matrices = 0;
            @memset(&st.matrix_out_ch, 0);
            return error.Corrupt;
        }
        if (frac_bits > 14) {
            st.num_primitive_matrices = 0;
            @memset(&st.matrix_out_ch, 0);
            return error.Corrupt;
        }

        var max_chan: u32 = st.max_matrix_channel;
        if (st.noise_type == 0) max_chan += 2;

        var ch: usize = 0;
        while (ch <= max_chan) : (ch += 1) {
            var coeff_val: i32 = 0;
            if ((br.readBits(1)) != 0) {
                coeff_val = br.readSBits(@intCast(frac_bits + 2));
            }
            st.matrix_coeff[mat][ch] = coeff_val * (@as(i32, 1) << @as(u5, @intCast(14 - frac_bits)));
        }

        if (st.noise_type != 0)
            st.matrix_noise_shift[mat] = @intCast(br.readBits(4))
        else
            st.matrix_noise_shift[mat] = 0;
    }
}

fn readChannelParams(s: *c.Ctx, br: *BitReader, substr: usize, ch: usize) !void {
    const st = &s.substream[substr];
    const cp = &st.channel_params[ch];
    const fir = &cp.filter_params[c.FIR];
    const iir = &cp.filter_params[c.IIR];

    if ((st.param_presence_flags & c.PARAM_FIR) != 0) {
        const fp = br.readBits(1);
        if (fp != 0) try readFilterParams(s, br, substr, ch, c.FIR);
    }
    if ((st.param_presence_flags & c.PARAM_IIR) != 0) {
        if ((br.readBits(1)) != 0) try readFilterParams(s, br, substr, ch, c.IIR);
    }

    if (fir.order + iir.order > 8) return error.Corrupt;
    if (fir.order != 0 and iir.order != 0 and fir.shift != iir.shift) return error.Corrupt;
    if (fir.order == 0 and iir.order != 0) fir.shift = iir.shift;

    if ((st.param_presence_flags & c.PARAM_HUFFOFFSET) != 0) {
        if ((br.readBits(1)) != 0) cp.huff_offset = @intCast(br.readSBits(15));
    }

    cp.codebook = @intCast(br.readBits(2));
    cp.huff_lsbs = @intCast(br.readBits(5));
    if (cp.codebook > 0 and cp.huff_lsbs > 24) return error.Corrupt;
}

fn readDecodingParams(s: *c.Ctx, br: *BitReader, substr: usize) !void {
    const st = &s.substream[substr];
    var recompute_sho: u32 = 0;

    if ((st.param_presence_flags & c.PARAM_PRESENCE) != 0) {
        if ((br.readBits(1)) != 0) {
            st.param_presence_flags = @intCast(br.readBits(8));
        }
    }

    if ((st.param_presence_flags & c.PARAM_BLOCKSIZE) != 0) {
        if ((br.readBits(1)) != 0) {
            st.blocksize = @intCast(br.readBits(9));
            if (st.blocksize < 8 or st.blocksize > s.access_unit_size) return error.Corrupt;
        }
    }

    if ((st.param_presence_flags & c.PARAM_MATRIX) != 0) {
        if ((br.readBits(1)) != 0) try readMatrixParams(s, br, substr);
    }

    if ((st.param_presence_flags & c.PARAM_OUTSHIFT) != 0) {
        if ((br.readBits(1)) != 0) {
            var ch: usize = 0;
            while (ch <= st.max_matrix_channel) : (ch += 1) {
                st.output_shift[ch] = @intCast(br.readSBits(4));
                if (st.output_shift[ch] < 0) st.output_shift[ch] = 0;
            }
        }
    }

    if ((st.param_presence_flags & c.PARAM_QUANTSTEP) != 0) {
        if ((br.readBits(1)) != 0) {
            var ch: usize = 0;
            while (ch <= st.max_channel) : (ch += 1) {
                st.quant_step_size[ch] = @intCast(br.readBits(4));
                recompute_sho |= @as(u32, 1) << @as(u5, @intCast(ch));
            }
        }
    }

    var ch: usize = st.min_channel;
    while (ch <= st.max_channel) : (ch += 1) {
        if ((br.readBits(1)) != 0) {
            recompute_sho |= @as(u32, 1) << @as(u5, @intCast(ch));
            try readChannelParams(s, br, substr, ch);
        }
    }

    ch = 0;
    while (ch <= st.max_channel) : (ch += 1) {
        if ((recompute_sho & (@as(u32, 1) << @as(u5, @intCast(ch)))) != 0) {
            const cp = &st.channel_params[ch];
            if (cp.codebook > 0 and cp.huff_lsbs < st.quant_step_size[ch]) {
                st.quant_step_size[ch] = 0;
            }
            cp.sign_huff_offset = calculateSignHuff(s, substr, ch);
        }
    }
}

fn calculateSignHuff(s: *c.Ctx, substr: usize, ch: usize) i32 {
    const st = &s.substream[substr];
    const cp = &st.channel_params[ch];
    const lsb_bits: i32 = @as(i32, cp.huff_lsbs) - @as(i32, st.quant_step_size[ch]);
    const sign_shift: i32 = lsb_bits + (if (cp.codebook != 0) @as(i32, 2) - @as(i32, cp.codebook) else -1);
    var sign_huff_offset: i32 = cp.huff_offset;

    if (cp.codebook > 0) sign_huff_offset -= @as(i32, 7) << @as(u5, @intCast(lsb_bits));
    if (sign_shift >= 0) sign_huff_offset -= @as(i32, 1) << @as(u5, @intCast(sign_shift));

    return sign_huff_offset;
}

// ---------------------------------------------------------------------------
// 块数据 + 滤波 + 矩阵 + 输出（对照 mlpdec.c / mlpdsp.c）
// ---------------------------------------------------------------------------

fn readHuffChannels(s: *c.Ctx, br: *BitReader, substr: usize, pos: usize) !void {
    const st = &s.substream[substr];
    var mat: usize = 0;
    while (mat < st.num_primitive_matrices) : (mat += 1) {
        if (st.lsb_bypass[mat] != 0) {
            s.bypassed_lsbs[pos + st.blockpos][mat] = @intCast(br.readBits(1));
        }
    }

    var channel: usize = st.min_channel;
    while (channel <= st.max_channel) : (channel += 1) {
        const cp = &st.channel_params[channel];
        const codebook: u32 = cp.codebook;
        const quant_step_size: u32 = st.quant_step_size[channel];
        const lsb_bits: i32 = @as(i32, cp.huff_lsbs) - @as(i32, @intCast(quant_step_size));
        var result: i32 = 0;

        if (codebook > 0) {
            result = decodeHuffman(br, codebook);
        }

        if (lsb_bits > 0) {
            result = (result << @as(u5, @intCast(lsb_bits))) + @as(i32, @intCast(br.readBitsLong(@intCast(lsb_bits))));
        }

        result += cp.sign_huff_offset;
        result *%= @as(i32, 1) << @as(u5, @intCast(quant_step_size));

        s.sample_buffer[pos + st.blockpos][channel] = result;
    }
}

fn mlpFilterChannel(
    state: *[c.MAX_BLOCKSIZE + c.MAX_FIR_ORDER]i32,
    iirbuf: *[c.MAX_BLOCKSIZE + c.MAX_IIR_ORDER]i32,
    fircoeff: []const i32,
    iircoeff: []const i32,
    firorder: usize,
    iirorder: usize,
    filter_shift: u32,
    mask: i32,
    blocksize: usize,
    sample_buffer: *[c.MAX_BLOCKSIZE][c.MAX_CHANNELS]i32,
    channel: usize,
    blockpos: usize,
) void {
    var i: usize = 0;
    while (i < blocksize) : (i += 1) {
        const residual = sample_buffer[blockpos + i][channel];
        var accum: i64 = 0;
        var order: usize = 0;
        while (order < firorder) : (order += 1) accum += @as(i64, state[order]) * fircoeff[order];
        while (order < firorder + iirorder) : (order += 1) accum += @as(i64, iirbuf[order - firorder]) * iircoeff[order - firorder];

        accum = accum >> @intCast(filter_shift);
        const result = (@as(i32, @intCast(accum)) + residual) & mask;


        // 反向填充 firbuf/iirbuf（C：*--firbuf）
        var k: usize = c.MAX_FIR_ORDER - 1;
        while (k > 0) : (k -= 1) state[k] = state[k - 1];
        state[0] = result;

        var k2: usize = c.MAX_IIR_ORDER - 1;
        while (k2 > 0) : (k2 -= 1) iirbuf[k2] = iirbuf[k2 - 1];
        iirbuf[0] = result - @as(i32, @intCast(accum));

        sample_buffer[blockpos + i][channel] = result;
    }
}

fn filterChannel(s: *c.Ctx, substr: usize, channel: usize) void {
    const st = &s.substream[substr];
    const fircoeff = &st.channel_params[channel].coeff[c.FIR];
    const iircoeff = &st.channel_params[channel].coeff[c.IIR];
    var state_buffer: [c.MAX_BLOCKSIZE + c.MAX_FIR_ORDER]i32 = [_]i32{0} ** (c.MAX_BLOCKSIZE + c.MAX_FIR_ORDER);
    var iir_buf: [c.MAX_BLOCKSIZE + c.MAX_IIR_ORDER]i32 = [_]i32{0} ** (c.MAX_BLOCKSIZE + c.MAX_IIR_ORDER);
    const fir = &st.channel_params[channel].filter_params[c.FIR];
    const iir = &st.channel_params[channel].filter_params[c.IIR];
    const filter_shift: u32 = fir.shift;
    const mask = c.msbMask(st.quant_step_size[channel]);

    // 拷贝滤波器状态
    var i: usize = 0;
    while (i < c.MAX_FIR_ORDER) : (i += 1) state_buffer[i] = fir.state[i];
    i = 0;
    while (i < c.MAX_IIR_ORDER) : (i += 1) iir_buf[i] = iir.state[i];

    mlpFilterChannel(&state_buffer, &iir_buf, fircoeff, iircoeff, fir.order, iir.order, filter_shift, mask, st.blocksize, &s.sample_buffer, channel, st.blockpos);

    // 保存滤波器状态（滤波历史在 state_buffer[0..MAX_FIR_ORDER-1]）
    i = 0;
    while (i < c.MAX_FIR_ORDER) : (i += 1) fir.state[i] = state_buffer[i];
    i = 0;
    while (i < c.MAX_IIR_ORDER) : (i += 1) iir.state[i] = iir_buf[i];
}

fn readBlockData(s: *c.Ctx, br: *BitReader, substr: usize) !void {
    const st = &s.substream[substr];
    if (st.blockpos + st.blocksize > s.access_unit_size) return error.Corrupt;

    var i: usize = 0;
    while (i < st.blocksize) : (i += 1) {
        try readHuffChannels(s, br, substr, i);
    }

    var ch: usize = st.min_channel;
    while (ch <= st.max_channel) : (ch += 1) filterChannel(s, substr, ch);

    st.blockpos += st.blocksize;
}

fn generate2NoiseChannels(s: *c.Ctx, substr: usize) void {
    const st = &s.substream[substr];
    var seed: u32 = st.noisegen_seed;
    const maxchan: u32 = st.max_matrix_channel;
    var i: usize = 0;
    const nshift: u5 = @intCast(st.noise_shift);
    while (i < st.blockpos) : (i += 1) {
        const seed_shr7: u16 = @truncate(seed >> 7);
        const n1: i8 = @bitCast(@as(u8, @truncate(seed >> 15)));
        const n2: i8 = @bitCast(@as(u8, @truncate(seed_shr7)));
        s.sample_buffer[i][maxchan + 1] = @as(i32, n1) * (@as(i32, 1) << nshift);
        s.sample_buffer[i][maxchan + 2] = @as(i32, n2) * (@as(i32, 1) << nshift);
        seed = (seed << 16) ^ seed_shr7 ^ (@as(u32, seed_shr7) << 5);
    }
    st.noisegen_seed = seed;
}

fn fillNoiseBuffer(s: *c.Ctx, substr: usize) void {
    const st = &s.substream[substr];
    var seed: u32 = st.noisegen_seed;
    var i: usize = 0;
    while (i < @as(usize, @intCast(s.access_unit_size_pow2))) : (i += 1) {
        const seed_shr15: u8 = @truncate(seed >> 15);
        s.noise_buffer[i] = t.noise_table[seed_shr15];
        seed = (seed << 8) ^ seed_shr15 ^ (@as(u32, seed_shr15) << 5);
    }
    st.noisegen_seed = seed;
}

fn rematrixChannel(
    samples: *[c.MAX_BLOCKSIZE][c.MAX_CHANNELS]i32,
    coeffs: []const i32,
    bypassed_lsbs: *[c.MAX_BLOCKSIZE][c.MAX_CHANNELS]i8,
    noise_buffer: []const i8,
    index: usize,
    mat: usize,
    dest_ch: usize,
    blockpos: usize,
    maxchan: usize,
    matrix_noise_shift: u32,
    access_unit_size_pow2: usize,
    mask: i32,
) void {
    const index2: i32 = 2 * @as(i32, @intCast(index)) + 1;
    var idx: i32 = @intCast(index);
    var i: usize = 0;
    while (i < blockpos) : (i += 1) {
        var accum: i64 = 0;
        var src_ch: usize = 0;
        while (src_ch <= maxchan) : (src_ch += 1) {
            accum += @as(i64, samples[i][src_ch]) * coeffs[src_ch];
        }

        if (matrix_noise_shift != 0) {
            idx &= @as(i32, @intCast(access_unit_size_pow2)) - 1;
            accum += @as(i64, noise_buffer[@as(usize, @intCast(idx))]) * (@as(i64, 1) << @as(u6, @intCast(matrix_noise_shift + 7)));
            idx += index2;
        }

        samples[i][dest_ch] = (@as(i32, @truncate(accum >> 14)) & mask);
        samples[i][dest_ch] +%= @as(i32, bypassed_lsbs[i][mat]);
    }
}

fn packOutput(
    lossless_check_data: i32,
    blockpos: usize,
    sample_buffer: *[c.MAX_BLOCKSIZE][c.MAX_CHANNELS]i32,
    out: []i16,
    out_pos: *usize,
    ch_assign: []const u8,
    output_shift: []const i8,
    max_matrix_channel: usize,
) i32 {
    var lcd = lossless_check_data;
    var i: usize = 0;
    while (i < blockpos) : (i += 1) {
        var out_ch: usize = 0;
        while (out_ch <= max_matrix_channel) : (out_ch += 1) {
            const mat_ch = ch_assign[out_ch];
            const sample = sample_buffer[i][mat_ch] *% (@as(i32, 1) << @as(u5, @intCast(output_shift[mat_ch])));
            lcd ^= @bitCast((@as(u32, @bitCast(sample)) & 0xffffff) << @as(u5, @intCast(mat_ch)));
            out[out_pos.*] = @truncate(sample >> 8);
            out_pos.* += 1;
        }
    }
    return lcd;
}

fn outputData(s: *c.Ctx, substr: usize, out: []i16, out_pos: *usize) !void {
    const st = &s.substream[substr];
    if (st.blockpos == 0) return error.Corrupt;

    var maxchan: usize = st.max_matrix_channel;
    if (st.noise_type == 0) {
        generate2NoiseChannels(s, substr);
        maxchan += 2;
    } else {
        fillNoiseBuffer(s, substr);
    }

    var mat: usize = 0;
    while (mat < st.num_primitive_matrices) : (mat += 1) {
        const dest_ch: usize = st.matrix_out_ch[mat];
        rematrixChannel(
            &s.sample_buffer,
            &st.matrix_coeff[mat],
            &s.bypassed_lsbs,
            &s.noise_buffer,
            st.num_primitive_matrices - mat,
            mat,
            dest_ch,
            st.blockpos,
            maxchan,
            st.matrix_noise_shift[mat],
            @intCast(s.access_unit_size_pow2),
            c.msbMask(st.quant_step_size[dest_ch]),
        );
    }

    st.lossless_check_data = packOutput(
        st.lossless_check_data,
        st.blockpos,
        &s.sample_buffer,
        out,
        out_pos,
        &st.ch_assign,
        &st.output_shift,
        st.max_matrix_channel,
    );
}

// ---------------------------------------------------------------------------
// 访问单元（帧）解码
// ---------------------------------------------------------------------------

fn readAccessUnit(s: *c.Ctx, buf: []const u8, out: []i16, out_pos: *usize) !usize {
    if (buf.len < 4) return error.Corrupt;

    const length: usize = (@as(usize, buf[0]) << 8 | buf[1]) & 0xfff;
    const length2 = length * 2;
    if (length2 < 4 or length2 > buf.len) return error.Corrupt;

    var header_size: usize = 4;
    var br = BitReader.init(buf[4 .. 4 + (length2 - 4)]);

    s.is_major_sync_unit = 0;
    // 检查主同步（show 31 位）
    const saved_pos = br.pos;
    if (br.readBits(31) == (0xf8726fba >> 1)) {
        br.pos = saved_pos; // show 语义：主同步检查不消费位
        try readMajorSync(s, &br, buf);
        s.is_major_sync_unit = 1;
        header_size += @as(usize, @intCast(s.major_sync_header_size));
    } else {
        br.pos = saved_pos;
    }

    var substream_start: usize = 0;
    var substr_header_size: usize = 0;

    if (s.params_valid == 0) {
        return 0;
    }

    var substream_parity_present: [c.MAX_SUBSTREAMS]u8 = [_]u8{0} ** c.MAX_SUBSTREAMS;
    var substream_data_len: [c.MAX_SUBSTREAMS]u16 = [_]u16{0} ** c.MAX_SUBSTREAMS;

    var substr: usize = 0;
    while (substr < s.num_substreams) : (substr += 1) {
        const extraword_present = br.readBits(1);
        const nonrestart_substr = br.readBits(1);
        const checkdata_present = br.readBits(1);
        br.skipBits(1);
        const end: usize = @as(usize, br.readBits(12)) * 2;
        substr_header_size += 2;

        if (extraword_present != 0) {
            if (s.stream_type == 0xbb) return error.Corrupt;
            br.skipBits(16);
            substr_header_size += 2;
        }

        if (length2 < 4 + substr_header_size) return error.Corrupt;

        if ((nonrestart_substr ^ @as(u1, @intCast(s.is_major_sync_unit))) == 0) return error.Corrupt;

        substream_parity_present[substr] = @intCast(checkdata_present);
        if (end < substream_start) {
            return error.Corrupt;
        }
        substream_data_len[substr] = @intCast(end - substream_start);
        substream_start = end;
    }


    const parity_bits = calculateParity(buf, 4) ^ calculateParity(buf[header_size .. header_size + substr_header_size], substr_header_size);
    if ((((parity_bits >> 4) ^ parity_bits) & 0xF) != 0xF) return error.Corrupt;

    const data_start: usize = header_size + substr_header_size;
    var substream_buf_pos = data_start;

    substr = 0;
    while (substr <= s.max_decoded_substream) : (substr += 1) {
        const st = &s.substream[substr];
        const sub_len = substream_data_len[substr];
        if (sub_len == 0) continue;

        var sbr = BitReader.init(buf[substream_buf_pos .. substream_buf_pos + sub_len]);
    if (s.mlp_dbg < 30 and substr == 1 and s.frame_count >= 8 and s.frame_count <= 11) { for (0..1) |_| {} }
        s.matrix_changed = 0;
        s.filter_changed = [_][c.NUM_FILTERS]i32{[_]i32{0} ** c.NUM_FILTERS} ** c.MAX_CHANNELS;

        st.blockpos = 0;
        st.end_of_stream = 0;

        while (true) {
            if ((sbr.readBits(1)) != 0) {
                if ((sbr.readBits(1)) != 0) {
                    readRestartHeader(s, &sbr, buf[substream_buf_pos .. substream_buf_pos + sub_len], substr) catch break;
                    st.restart_seen = 1;
                }
                if (st.restart_seen == 0) break;
                readDecodingParams(s, &sbr, substr) catch break;
            }

            if (st.restart_seen == 0) break;

            // 声道重叠跳过（简化：仅当 substream 通道不重叠）
            if (substr != s.max_decoded_substream and
                (st.coded_channels & s.substream[s.max_decoded_substream].coded_channels) != 0)
            {
                break;
            }

            try readBlockData(s, &sbr, substr);
            if (sbr.bitsCount() >= sub_len * 8) break;

            if ((sbr.readBits(1)) != 0) break;
        }

        substream_buf_pos += sub_len;
    }

    try outputData(s, s.max_decoded_substream, out, out_pos);
    return length2;
}

// ---------------------------------------------------------------------------
// 解码器 VTable
// ---------------------------------------------------------------------------

const DecoderCtx = struct {
    allocator: std.mem.Allocator,
    reader: io.Reader,
    sample_rate: i32 = 0,
    channels: u8 = 0,
    ctx: c.Ctx = .{},

    frame_buf: [65536]u8 = undefined,
    out: [16384]i16 = undefined,
    out_len: usize = 0,
    out_pos: usize = 0,
    eof: bool = false,
    first: bool = true,
    total_samples: i64 = 0,
};

fn decodeFrame(f: *DecoderCtx) !bool {
    // 读 2 字节长度头
    var hdr: [4]u8 = undefined;
    var got: usize = 0;
    while (got < 4) {
        const m = try f.reader.read(hdr[got..]);
        if (m == 0) return false;
        got += m;
    }

    const length = (@as(usize, hdr[0]) << 8 | hdr[1]) & 0xfff;
    const length2 = length * 2;
    if (length2 < 4 or length2 > 65536) return error.Corrupt;

    f.frame_buf[0] = hdr[0];
    f.frame_buf[1] = hdr[1];
    f.frame_buf[2] = hdr[2];
    f.frame_buf[3] = hdr[3];

    if (length2 > 4) {
        const mr = try f.reader.read(f.frame_buf[4..length2]);
        if (mr < length2 - 4) return false;
    }

    var out_pos: usize = 0;
    f.out_len = 0;
    f.out_pos = 0;

    _ = try readAccessUnit(&f.ctx, f.frame_buf[0..length2], &f.out, &out_pos);

    f.out_len = out_pos;

    if (f.first) {
        f.sample_rate = f.ctx.sample_rate;
        f.channels = f.ctx.out_channels;
        f.first = false;
    }

    if (f.out_len == 0) {
        // 无输出（跳过帧或无效），尝试下一帧
        return true;
    }
    return true;
}

fn readImpl(ctx: *anyopaque, out: []u8, max_samples: usize, out_channels: *u8) !usize {
    const f: *DecoderCtx = @ptrCast(@alignCast(ctx));
    out_channels.* = f.channels;
    if (max_samples == 0 or out.len == 0) return 0;

    const frame_bytes = @as(usize, f.channels) * 2;
    if (frame_bytes == 0) return error.Corrupt;
    const cap = @min(max_samples, out.len / frame_bytes);
    var produced: usize = 0;

    while (produced < cap) {
        if (f.out_pos * f.channels >= f.out_len) {
            f.out_pos = 0;
            const ok = try decodeFrame(f);
            if (!ok) {
                if (produced == 0) return 0;
                break;
            }
            if (f.out_len == 0) continue;
            continue;
        }
        const avail = (f.out_len / f.channels) - f.out_pos;
        const take = @min(avail, cap - produced);
        f.total_samples += @as(i64, @intCast(take));
        const src_off = f.out_pos * f.channels;
        @memcpy(
            out[produced * frame_bytes ..][0 .. take * frame_bytes],
            std.mem.sliceAsBytes(f.out[src_off .. src_off + take * f.channels]),
        );
        f.out_pos += take;
        produced += take;
    }
    return produced;
}

fn seekMsImpl(ctx: *anyopaque, ms: i64) !void {
    const f: *DecoderCtx = @ptrCast(@alignCast(ctx));
    const sr = f.sample_rate;
    if (sr <= 0) return error.UnsupportedFormat;
    f.reader.seek(0, .start) catch return error.UnsupportedFormat;
    f.out_pos = 0;
    f.out_len = 0;
    f.eof = false;
    var n: i64 = 0;
    while (n < 100000) : (n += 1) {
        const ok = try decodeFrame(f);
        if (!ok) break;
        f.total_samples += @as(i64, @intCast(f.out_len / f.channels));
        if (@divTrunc(f.total_samples * 1000, @as(i64, sr)) >= ms) break;
    }
    f.out_pos = 0;
    f.out_len = 0;
}

fn positionMsImpl(ctx: *anyopaque) i64 {
    const f: *DecoderCtx = @ptrCast(@alignCast(ctx));
    if (f.sample_rate <= 0) return 0;
    return @divTrunc(f.total_samples * 1000, @as(i64, f.sample_rate));
}

fn deinitImpl(ctx: *anyopaque) void {
    const f: *DecoderCtx = @ptrCast(@alignCast(ctx));
    const allocator = f.allocator;
    f.reader.deinit();
    allocator.destroy(f);
}

const VTable = decoder.Decoder.VTable;
const vtable = VTable{
    .read = readImpl,
    .seek_ms = seekMsImpl,
    .position_ms = positionMsImpl,
    .deinit = deinitImpl,
};

pub fn open(allocator: std.mem.Allocator, reader: *io.Reader, info: *decoder.Info) !decoder.Decoder {
    const f = try allocator.create(DecoderCtx);
    errdefer allocator.destroy(f);
    f.* = .{ .allocator = allocator, .reader = reader.* };
    errdefer f.reader.deinit();

    // 预读首帧，解析主同步获取采样率/声道
    var buf: [256]u8 = undefined;
    const n = try f.reader.read(&buf);
    var sr: i32 = 0;
    var ch: u8 = 0;
    var aus2: i32 = 0;
    var ok = false;
    if (n >= 8) {
        const ms_off: usize = if (n >= 8 and (buf[4] == 0xf8 and buf[5] == 0x72 and buf[6] == 0x6f and buf[7] == 0xba)) 4 else if (n >= 4 and (buf[0] == 0xf8 and buf[1] == 0x72 and buf[2] == 0x6f and buf[3] == 0xba)) 0 else 999;
        if (ms_off != 999 and ms_off + 28 <= n) {
            var mh: MLPHeaderInfo = .{};
            var br = BitReader.init(buf[ms_off .. ms_off + @as(usize, @intCast(majorSyncSize(buf[ms_off..])))] );
            if (readMajorSyncInto(&br, &mh)) {
                sr = mh.group1_samplerate;
                if (mh.stream_type == 0xba) {
                    ch = if (mh.channels_thd_stream2 != 0) @intCast(mh.channels_thd_stream2) else @intCast(mh.channels_thd_stream1);
                } else {
                    ch = @intCast(mh.channels_mlp);
                }
                aus2 = mh.access_unit_size_pow2;
                ok = true;
            }
        }
    }
    // 回到起点（probe 已消费，这里也消费了 256 字节，seek 回 0）
    try f.reader.seek(0, .start);

    if (ok) {
        f.sample_rate = sr;
        f.channels = ch;
        f.ctx.sample_rate = sr;
        f.ctx.out_channels = ch;
        f.ctx.access_unit_size_pow2 = aus2;
        f.ctx.params_valid = 1;
    }

    info.* = .{
        .sample_rate = @intCast(f.sample_rate),
        .channels = f.channels,
        .bits_per_sample = 16,
        .is_float = false,
        .duration_us = 0,
        .duration_known = .unknown,
        .codec_name = "truehd",
        .format_name = "truehd",
        .metadata = .{},
    };

    return .{ .vtable = &vtable, .ctx = f };
}

fn readMajorSyncInto(br: *BitReader, mh: *MLPHeaderInfo) bool {
    br.pos = 0;
    _ = br.readBits(24); // sync
    mh.stream_type = @intCast(br.readBits(8));
    mh.header_size = 0;
    if (mh.stream_type == 0xbb) {
        mh.group1_bits = t.mlp_quants[@intCast(br.readBits(4))];
        mh.group2_bits = t.mlp_quants[@intCast(br.readBits(4))];
        const ratebits: i32 = @intCast(br.readBits(4));
        mh.group1_samplerate = mlpSamplerate(ratebits);
        mh.group2_samplerate = mlpSamplerate(@intCast(br.readBits(4)));
        mh.access_unit_size_pow2 = @as(i32, 64) << @as(u5, @intCast(ratebits & 7));
        br.skipBits(11);
        mh.channel_arrangement = @intCast(br.readBits(5));
        mh.channels_mlp = t.mlp_channels[@intCast(mh.channel_arrangement)];
        return true;
    } else if (mh.stream_type == 0xba) {
        mh.group1_bits = 24;
        mh.group2_bits = 0;
        const ratebits: i32 = @intCast(br.readBits(4));
        mh.group1_samplerate = mlpSamplerate(ratebits);
        mh.group2_samplerate = 0;
        mh.access_unit_size_pow2 = @as(i32, 64) << @as(u5, @intCast(ratebits & 7));
        br.skipBits(4);
        _ = br.readBits(2);
        _ = br.readBits(2);
        mh.channel_arrangement = @intCast(br.readBits(5));
        mh.channels_thd_stream1 = truehdChannels(mh.channel_arrangement);
        _ = br.readBits(2);
        const ca2: i32 = @intCast(br.readBits(13));
        mh.channels_thd_stream2 = truehdChannels(ca2);
        return true;
    }
    return false;
}
