// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! WMA Lossless (wmalossless, ASF codec_tag 0x163) 整数解码核心。
//!
//! 逐函数移植 FFmpeg libavcodec/wmalosslessdec.c（整数 / 无浮点）。结构：
//!   packet（=ASF 音频对象，通常 block_align 字节；末个可更短）→ 帧重组
//!   （跨包位蓄存器 save_bits / frame_data）→ frame → 子帧 → 熵解
//!   （Rice/指数-Golomb zigzag）→ 级联自回归 LMS（cdlms：use_high/use_normal
//!   两档更新 + lms 更新衰减）→ 多声道 LMS（mclms）/ 声道对去相关
//!   （revert_inter_ch_decorr）/ AC 滤波（revert_acfilter）→ 样本。本编解码为
//!   无损整数路径（无浮点舍入）；本模块与 ffmpeg native wmalossless 输出逐位
//!   一致（s16 / 24bit<<8 s32 均经实测 bit-exact）。
//!
//! 位流/数组语义（全部对齐 C，经 4 样本逐字节比对）：
//!   - MSB-first 位读（get_bits.h）。Bits 按「safe bitstream reader」语义把
//!     index 夹在 cap+8 内、越过 cap 的位读 frame_data 物理陈旧字节（与 ffmpeg
//!     缓存读一致）；越过物理缓冲读 0（AV_INPUT_BUFFER_PADDING）。
//!   - frame_data 为持久物理缓冲：save_bits 每写一段前缀，末尾 `flush_put_bits`
//!     副本把滞留的尾部位补 0 落盘 → [0,ceil(num_saved/8)) 逐字节与 ffmpeg 相同；
//!     未覆盖区保留旧内容。BitWriter = put_bits/ff_copy_bits 逐字移植。
//!   - decode_channel_residues 位耗尽返回 -1 但被 decode_subframe 忽略（C 语义），
//!     截断帧仍按部分残差 + LMS 重建输出 → 文件截断尾帧与 ffmpeg 一致。
//!   - cdlms 的 scalarproduct_and_madd 按 C 参考实现（无 SIMD）：SSE2/SSE4 只改
//!     模加顺序，结果逐位相同；迭代长度用 FFALIGN(order,16|8) 使系数 pad/环形
//!     缓冲陈旧内容与 C 完全一致。recent 每 icoef 重读（lms_update 递减它）。
//!   - 不支持：算术编码（do_arith_coding，ffmpeg 同样 request_sample 拒绝）、
//!     LPC 逆滤波（ffmpeg 只读参数不实现，输出与其对齐）、>8 声道、非 16/24bit。

const std = @import("std");
const Error = @import("../../../error.zig").Error;

pub const WMALL_MAX_CHANNELS = 8;
pub const MAX_SUBFRAMES = 32;
pub const MAX_FRAMESIZE = 32768; // 最大压缩帧（每声道字节）
pub const MAX_ORDER = 256;
pub const WMALL_BLOCK_MAX_SIZE = 1 << 14;
pub const COEF_PAD_ELEMS = 8; // WMALL_COEFF_PAD_SIZE(16B)/2
const WMALL_COEFF_PAD_SIZE: usize = 16; // FFmpeg 系数 pad（字节）

// ---------------- 位读 / 位写（对齐 get_bits.h / put_bits.h） ----------------

pub const Bits = struct {
    /// 物理字节（持久 frame_data 或对象切片）；越过 buf 读 = 0
    buf: []const u8,
    /// 逻辑位数（num_saved_bits 等）；index 读到此 +8 处夹住（safe reader）
    cap: usize = 0,
    index: usize = 0,

    fn peek(self: *const Bits, n: usize) u32 {
        var val: u32 = 0;
        for (0..n) |bit| {
            const pos = self.index + bit;
            const byte = pos >> 3;
            const b: u32 = if (byte < self.buf.len) (@as(u32, self.buf[byte]) >> @intCast(7 - (pos & 7))) & 1 else 0;
            val = (val << 1) | b;
        }
        return val;
    }
    pub fn get(self: *Bits, n: usize) u32 {
        const v = self.peek(n);
        self.index += n;
        if (self.cap > 0 and self.index > self.cap + 8) self.index = self.cap + 8;
        return v;
    }
    pub fn get1(self: *Bits) u32 {
        return self.get(1);
    }
    pub fn bitsLeft(self: *const Bits) usize {
        return self.cap -% self.index;
    }
    pub fn count(self: *const Bits) usize {
        return self.index;
    }
    pub fn skip(self: *Bits, n: usize) void {
        self.index += n;
        if (self.cap > 0 and self.index > self.cap + 8) self.index = self.cap + 8;
    }
};

pub fn getSignedBits(gb: *Bits, n: usize) i32 {
    if (n == 0) return 0;
    const v = gb.get(n);
    if (n == 32) return @bitCast(v);
    const sign: u32 = @as(u32, 1) << @intCast(n - 1);
    if (v & sign != 0) return @intCast(@as(i64, @intCast(v)) - @as(i64, @intCast(sign << 1)));
    return @intCast(v);
}

/// av_log2（floor log2，v==0 → 0）
pub fn avLog2(v: u32) u32 {
    if (v == 0) return 0;
    return 31 - @clz(v);
}
/// av_ceil_log2_c(x) = av_log2((x - 1U) << 1)
pub fn avCeilLog2(x: u32) u32 {
    return avLog2((x -% 1) << 1);
}
/// WMASIGN
inline fn wmaSign(x: i32) i32 {
    const p: i32 = @intFromBool(x > 0);
    const n: i32 = @intFromBool(x < 0);
    return p - n;
}
inline fn clipI(a: i32, amin: i32, amax: i32) i32 {
    return if (a < amin) amin else if (a > amax) amax else a;
}
inline fn maxI(a: i32, b: i32) i32 {
    return if (a > b) a else b;
}
/// FFALIGN(a, m)（m 为 2 的幂）
inline fn fAlign(a: usize, m: usize) usize {
    return (a + m - 1) & ~(m - 1);
}
inline fn fAlignI(a: i32, m: usize) i32 {
    return @intCast(fAlign(@intCast(a), m));
}

/// 位写器（逐函数移植 ffmpeg put_bits.h / ff_copy_bits：BE，BitBuf=u32、
/// BUF_BITS=32，满 32 位才落 4 字节大端字，尾部不足一字的位留在 bit_buf 中
/// 不物理写盘 → 解码器越过 num_saved 读到的陈旧字节与 ffmpeg 物理缓冲一致。
const BitWriter = struct {
    buf: []u8,
    buf_ptr: usize = 0,
    bit_buf: u32 = 0,
    bit_left: i32 = 32,

    /// init_put_bits
    fn reset(self: *BitWriter) void {
        self.buf_ptr = 0;
        self.bit_buf = 0;
        self.bit_left = 32;
    }
    fn count(self: *const BitWriter) usize {
        return self.buf_ptr * 8 + @as(usize, @intCast(@max(0, 32 - self.bit_left)));
    }
    fn left(self: *const BitWriter) usize {
        return self.buf.len * 8 -% self.count();
    }
    /// put_bits（BE），value < 2^n，n ≤ 31
    fn write(self: *BitWriter, n: usize, value: u32) void {
        if (n == 0) return;
        var bit_buf = self.bit_buf;
        var bit_left: i32 = self.bit_left;
        const nn: i32 = @intCast(n);
        if (nn < bit_left) {
            bit_buf = (bit_buf << @intCast(n)) | value;
            bit_left -= nn;
        } else {
            bit_buf <<= @intCast(bit_left);
            bit_buf |= value >> @intCast(nn - bit_left);
            if (self.buf_ptr + 4 <= self.buf.len) {
                std.mem.writeInt(u32, self.buf[self.buf_ptr..][0..4], bit_buf, .big);
                self.buf_ptr += 4;
            }
            bit_left += 32 - nn;
            bit_buf = value;
        }
        self.bit_buf = bit_buf;
        self.bit_left = bit_left;
    }
    /// flush_put_bits（BE；向字节边界补 0）
    fn flush(self: *BitWriter) void {
        if (self.bit_left < 32) self.bit_buf <<= @intCast(self.bit_left);
        while (self.bit_left < 32) {
            if (self.buf_ptr < self.buf.len) {
                self.buf[self.buf_ptr] = @truncate(self.bit_buf >> 24);
                self.buf_ptr += 1;
            }
            self.bit_buf <<= 8;
            self.bit_left += 8;
        }
    }
    fn rb16(src: []const u8, off: usize) u32 {
        var b: [2]u8 = .{ 0, 0 };
        for (0..2) |k| {
            if (off + k < src.len) b[k] = src[off + k];
        }
        return (@as(u32, b[0]) << 8) | @as(u32, b[1]);
    }
    /// ff_copy_bits（CONFIG_SMALL=0）
    fn copyBits(self: *BitWriter, src: []const u8, length: usize) void {
        if (length == 0) return;
        const words = length >> 4;
        const bits = length & 15;
        if (words < 16 or (self.count() & 7) != 0) {
            for (0..words) |i| {
                self.write(16, rb16(src, i * 2));
            }
            if (bits > 0) {
                const v = rb16(src, words * 2);
                self.write(bits, v >> @intCast(16 - bits));
            }
        } else {
            var i: usize = 0;
            while ((self.count() & 31) != 0) : (i += 1) {
                self.write(8, if (i < src.len) src[i] else 0);
            }
            self.flush();
            const nb = 2 * words - i;
            if (self.buf_ptr + nb <= self.buf.len and i + nb <= src.len) {
                @memcpy(self.buf[self.buf_ptr .. self.buf_ptr + nb], src[i .. i + nb]);
            } else {
                for (0..nb) |k| {
                    const byte = if (i + k < src.len) src[i + k] else 0;
                    if (self.buf_ptr + k < self.buf.len) self.buf[self.buf_ptr + k] = byte;
                }
            }
            self.buf_ptr += nb;
            if (bits > 0) {
                const v = rb16(src, words * 2);
                self.write(bits, v >> @intCast(16 - bits));
            }
        }
    }
};

// ---------------- 解码上下文 ----------------

const WmallChannelCtx = struct {
    prev_block_len: i32 = 0,
    num_subframes: u8 = 0,
    subframe_len: [MAX_SUBFRAMES]u16 = undefined,
    subframe_offsets: [MAX_SUBFRAMES]u16 = undefined,
    cur_subframe: u8 = 0,
    decoded_samples: u16 = 0,
    quant_step: i32 = 0,
    transient_counter: i32 = 0,
};

/// 单个级联 LMS（cdlms[i][ilms]）
const Cdlms = struct {
    order: i32 = 0,
    scaling: i32 = 0,
    coefsend: i32 = 0,
    bitsend: i32 = 0,
    /// 系数 + pad（MAX_ORDER + 8 个 i16；ffmpeg 数组为
    /// MAX_ORDER + WMALL_COEFF_PAD_SIZE/2）
    coefs: [MAX_ORDER + COEF_PAD_ELEMS]i16 = undefined,
    /// 历史样本延迟线（环形 + 备份区）。16-bit 流用 i16 视图、24-bit 用 i32；
    /// 物理长度 2*MAX_ORDER + pad（C: int32[2*MAX_ORDER+8]；i16 视图更长，
    /// 但本实现按位深分数组且读写范围一致）
    lms_prevvalues_16: [2 * MAX_ORDER + COEF_PAD_ELEMS]i16 = undefined,
    lms_prevvalues_32: [2 * MAX_ORDER + COEF_PAD_ELEMS]i32 = undefined,
    lms_updates: [2 * MAX_ORDER + COEF_PAD_ELEMS]i16 = undefined,
    recent: i32 = 0,
};

pub const DecodeConfig = struct {
    sample_rate: u32,
    bits_per_sample: u16,
    channels: u8,
    channel_mask: u32,
    decode_flags: u16,
    block_align: u32,
};

const CdlmsArr = [WMALL_MAX_CHANNELS][9]Cdlms;

pub const Dec = struct {
    a: std.mem.Allocator,

    bits_per_sample: u8,
    num_channels: usize,
    samples_per_frame: usize,
    max_num_subframes: usize,
    min_samples_per_subframe: usize,
    log2_frame_size: usize,
    len_prefix: bool,
    dynamic_range_compression: bool,
    bV3RTM: bool,
    block_align: usize,
    max_frame_size: usize,

    // ---- 帧 / packet 状态 ----
    frame_data: []u8, // 位蓄存器（max_frame_size + 64，持久）
    pb: BitWriter,
    gb: Bits,
    pgb: Bits,
    buf_bit_size: usize = 0,
    num_saved_bits: usize = 0,
    frame_offset: usize = 0,
    packet_offset: usize = 0,
    next_packet_start: usize = 0,
    packet_done: bool = false,
    packet_loss: bool = true,
    packet_sequence_number: usize = 0,
    frame_num: u32 = 0,
    drc_gain: u32 = 0,

    // ---- 帧 / 子帧状态 ----
    parsed_all_subframes: bool = false,
    channels_for_cur_subframe: usize = 0,
    channel_indexes_for_cur_subframe: [WMALL_MAX_CHANNELS]u8 = undefined,
    channel: [WMALL_MAX_CHANNELS]WmallChannelCtx = undefined,

    // ---- wmalossless 工具 ----
    do_arith_coding: u8 = 0,
    do_ac_filter: u8 = 0,
    do_inter_ch_decorr: u8 = 0,
    do_mclms: u8 = 0,
    do_lpc: u8 = 0,

    acfilter_order: i32 = 0,
    acfilter_scaling: i32 = 0,
    acfilter_coeffs: [16]i16 = undefined,
    acfilter_prevvalues: [WMALL_MAX_CHANNELS][16]i32 = undefined,

    mclms_order: i32 = 0,
    mclms_scaling: i32 = 0,
    mclms_coeffs: [WMALL_MAX_CHANNELS * WMALL_MAX_CHANNELS * 32]i16 = undefined,
    mclms_coeffs_cur: [WMALL_MAX_CHANNELS * WMALL_MAX_CHANNELS]i16 = undefined,
    mclms_prevvalues: [WMALL_MAX_CHANNELS * 2 * 32]i32 = undefined,
    mclms_updates: [WMALL_MAX_CHANNELS * 2 * 32]i32 = undefined,
    mclms_recent: i32 = 0,

    movave_scaling: i32 = 0,
    quant_stepsize: i32 = 0,

    cdlms: CdlmsArr = undefined,
    cdlms_ttl: [WMALL_MAX_CHANNELS]u8 = undefined,

    is_channel_coded: [WMALL_MAX_CHANNELS]i32 = undefined,
    update_speed: [WMALL_MAX_CHANNELS]i32 = undefined,
    transient: [WMALL_MAX_CHANNELS]i32 = undefined,
    transient_pos: [WMALL_MAX_CHANNELS]i32 = undefined,
    ave_sum: [WMALL_MAX_CHANNELS]u32 = undefined,
    seekable_tile: bool = false,

    lpc_coefs: [WMALL_MAX_CHANNELS][40]i32 = undefined,
    lpc_order: i32 = 0,
    lpc_scaling: i32 = 0,
    lpc_intbits: i32 = 0,

    // ---- 工作缓冲（按 nch × samples_per_frame）----
    channel_residues: []i32 = &.{},
    out_16: []i16 = &.{},
    out_32: []i32 = &.{},
    out_pos: [WMALL_MAX_CHANNELS]usize = undefined,

    // ---- 帧输出 ----
    frame_pending: bool = false,
    frame_nb_samples: usize = 0,

    pub fn init(a: std.mem.Allocator, p: DecodeConfig) Error!Dec {
        if (p.channels == 0 or p.channels > WMALL_MAX_CHANNELS) return error.UnsupportedFormat;
        if (p.bits_per_sample != 16 and p.bits_per_sample != 24) return error.UnsupportedFormat;
        if (p.block_align <= 0 or p.block_align > (1 << 21)) return error.UnsupportedFormat;
        if (p.sample_rate == 0) return error.UnsupportedFormat;

        // 基础校验通过后再申请缓冲（部分错误集路径避免提前分配）
        const frame_len_bits = wmaFrameLenBits(p.sample_rate, p.decode_flags);
        const samples_per_frame: usize = @as(usize, 1) << @intCast(frame_len_bits);
        if (samples_per_frame > WMALL_BLOCK_MAX_SIZE) return error.UnsupportedFormat;
        const log2_max_num_subframes = (p.decode_flags & 0x38) >> 3;
        const max_num_subframes: usize = @as(usize, 1) << @intCast(log2_max_num_subframes);
        if (max_num_subframes > MAX_SUBFRAMES) return error.UnsupportedFormat;
        const min_samples_per_subframe = samples_per_frame / max_num_subframes;
        if (min_samples_per_subframe == 0) return error.UnsupportedFormat;
        const max_frame_size = MAX_FRAMESIZE * @as(usize, p.channels);

        // 帧数据蓄存器（av_mallocz 语义：全 0；容量 max_frame_size + 64 padding）
        const frame_data = try a.alloc(u8, max_frame_size + 64);
        errdefer a.free(frame_data);
        @memset(frame_data, 0);

        var d: Dec = .{
            .a = a,
            .bits_per_sample = @intCast(p.bits_per_sample),
            .num_channels = p.channels,
            .samples_per_frame = samples_per_frame,
            .max_num_subframes = max_num_subframes,
            .min_samples_per_subframe = min_samples_per_subframe,
            .log2_frame_size = avLog2(p.block_align) + 4,
            .len_prefix = (p.decode_flags & 0x40) != 0,
            .dynamic_range_compression = (p.decode_flags & 0x80) != 0,
            .bV3RTM = (p.decode_flags & 0x100) != 0,
            .block_align = p.block_align,
            .max_frame_size = max_frame_size,
            .frame_data = frame_data,
            .pb = .{ .buf = frame_data },
            .gb = .{ .buf = frame_data, .cap = 0, .index = 0 },
            .pgb = .{ .buf = &.{}, .cap = 0, .index = 0 },
        };
        // 未显式列出的字段：C 语义 = priv_data av_mallocz（全 0）后 decode_init
        // 覆写子集；上述 `.{}` 已把声明含默认值的字段置默认。这里补齐需要
        // 非默认初值的 packet 状态。
        d.packet_loss = true;

        d.channel = std.mem.zeroes([WMALL_MAX_CHANNELS]WmallChannelCtx);
        for (0..d.num_channels) |i| {
            d.channel[i].prev_block_len = @intCast(d.samples_per_frame);
        }
        d.cdlms = std.mem.zeroes(CdlmsArr);
        d.acfilter_coeffs = @splat(0);
        d.acfilter_prevvalues = @splat(@splat(0));
        d.mclms_coeffs = @splat(0);
        d.mclms_coeffs_cur = @splat(0);
        d.mclms_prevvalues = @splat(0);
        d.mclms_updates = @splat(0);
        d.lpc_coefs = @splat(@splat(0));
        d.cdlms_ttl = @splat(0);
        d.is_channel_coded = @splat(1);
        d.update_speed = @splat(0);
        d.transient = @splat(0);
        d.transient_pos = @splat(0);
        d.ave_sum = @splat(0);
        d.out_pos = @splat(0);

        d.channel_residues = try a.alloc(i32, d.num_channels * d.samples_per_frame);
        errdefer a.free(d.channel_residues);
        @memset(d.channel_residues, 0);
        d.out_16 = try a.alloc(i16, d.num_channels * d.samples_per_frame);
        errdefer a.free(d.out_16);
        @memset(d.out_16, 0);
        d.out_32 = try a.alloc(i32, d.num_channels * d.samples_per_frame);
        errdefer a.free(d.out_32);
        @memset(d.out_32, 0);

        return d;
    }

    pub fn deinit(self: *Dec) void {
        self.a.free(self.frame_data);
        self.a.free(self.channel_residues);
        self.a.free(self.out_16);
        self.a.free(self.out_32);
    }

    // ================= 帧内工具（decode_*.c 逐函数） =================

    /// decode_subframe_length
    fn decodeSubframeLength(self: *Dec, offset: usize) anyerror!usize {
        if (offset == self.samples_per_frame - self.min_samples_per_subframe)
            return self.min_samples_per_subframe;
        const len = avLog2(@intCast(self.max_num_subframes - 1)) + 1;
        const frame_len_ratio = self.gb.get(len);
        const subframe_len = self.min_samples_per_subframe * (frame_len_ratio + 1);
        if (subframe_len < self.min_samples_per_subframe or subframe_len > self.samples_per_frame)
            return error.Corrupt;
        return subframe_len;
    }

    /// decode_tilehdr
    fn decodeTilehdr(self: *Dec) anyerror!void {
        var num_samples: [WMALL_MAX_CHANNELS]u32 = @splat(0);
        var contains_subframe: [WMALL_MAX_CHANNELS]u8 = undefined;
        var channels_for_cur_subframe: usize = self.num_channels;
        var fixed_channel_layout: usize = 0;
        var min_channel_len: u32 = 0;

        for (0..self.num_channels) |c| self.channel[c].num_subframes = 0;

        const tile_aligned = self.gb.get1();
        if (self.max_num_subframes == 1 or tile_aligned != 0) fixed_channel_layout = 1;

        while (true) {
            var in_use: usize = 0;
            for (0..self.num_channels) |c| {
                if (num_samples[c] == min_channel_len) {
                    if (fixed_channel_layout != 0 or channels_for_cur_subframe == 1 or
                        min_channel_len == self.samples_per_frame - self.min_samples_per_subframe)
                    {
                        contains_subframe[c] = 1;
                    } else {
                        contains_subframe[c] = @intCast(self.gb.get1());
                    }
                    in_use |= contains_subframe[c];
                } else {
                    contains_subframe[c] = 0;
                }
            }
            if (in_use == 0) return error.Corrupt;

            const subframe_len = try self.decodeSubframeLength(min_channel_len);
            min_channel_len += @intCast(subframe_len);
            for (0..self.num_channels) |c| {
                const chan = &self.channel[c];
                if (contains_subframe[c] != 0) {
                    if (chan.num_subframes >= MAX_SUBFRAMES) return error.Corrupt;
                    chan.subframe_len[chan.num_subframes] = @intCast(subframe_len);
                    num_samples[c] += @intCast(subframe_len);
                    chan.num_subframes += 1;
                    if (num_samples[c] > self.samples_per_frame) return error.Corrupt;
                } else if (num_samples[c] <= min_channel_len) {
                    if (num_samples[c] < min_channel_len) {
                        channels_for_cur_subframe = 0;
                        min_channel_len = num_samples[c];
                    }
                    channels_for_cur_subframe += 1;
                }
            }
            if (min_channel_len >= self.samples_per_frame) break;
        }

        for (0..self.num_channels) |c| {
            var offset: usize = 0;
            for (0..self.channel[c].num_subframes) |i| {
                self.channel[c].subframe_offsets[i] = @intCast(offset);
                offset += self.channel[c].subframe_len[i];
            }
        }
    }

    fn decodeAcFilter(self: *Dec) void {
        self.acfilter_order = @intCast(self.gb.get(4) + 1);
        self.acfilter_scaling = @intCast(self.gb.get(4));
        for (0..@intCast(self.acfilter_order)) |i| {
            const v = self.gb.get(@intCast(self.acfilter_scaling));
            self.acfilter_coeffs[i] = @truncate(@as(i32, @intCast(v)) + 1);
        }
    }

    fn decodeMclms(self: *Dec) void {
        self.mclms_order = @intCast((self.gb.get(4) + 1) * 2);
        self.mclms_scaling = @intCast(self.gb.get(4));
        if (self.gb.get1() != 0) {
            var cbits = avLog2(@intCast(self.mclms_scaling + 1));
            if (@as(u32, 1) << @intCast(cbits) < @as(u32, @intCast(self.mclms_scaling + 1))) cbits += 1;
            const send_coef_bits = self.gb.get(cbits) + 2;
            const n: usize = @intCast(@as(i64, self.mclms_order) * @as(i64, @intCast(self.num_channels)) * @as(i64, @intCast(self.num_channels)));
            for (0..n) |i| {
                self.mclms_coeffs[i] = @as(i16, @bitCast(@as(u16, @truncate(self.gb.get(@intCast(send_coef_bits))))));
            }
            for (0..self.num_channels) |i| {
                for (0..i) |c| {
                    self.mclms_coeffs_cur[i * self.num_channels + c] = @as(i16, @bitCast(@as(u16, @truncate(self.gb.get(@intCast(send_coef_bits))))));
                }
            }
        }
    }

    fn decodeCdlms(self: *Dec) anyerror!void {
        const cdlms_send_coef = self.gb.get1();
        for (0..self.num_channels) |c| {
            self.cdlms_ttl[c] = @intCast(self.gb.get(3) + 1);
            for (0..self.cdlms_ttl[c]) |i| {
                self.cdlms[c][i].order = @intCast((self.gb.get(7) + 1) * 8);
                if (self.cdlms[c][i].order > MAX_ORDER) {
                    self.cdlms[0][0].order = 0;
                    return error.Corrupt;
                }
            }
            for (0..self.cdlms_ttl[c]) |i| {
                self.cdlms[c][i].scaling = @intCast(self.gb.get(4));
            }
            if (cdlms_send_coef != 0) {
                for (0..self.cdlms_ttl[c]) |i| {
                    var cbits = avLog2(@intCast(self.cdlms[c][i].order));
                    if (@as(u32, 1) << @intCast(cbits) < @as(u32, @intCast(self.cdlms[c][i].order))) cbits += 1;
                    self.cdlms[c][i].coefsend = @as(i32, @intCast(self.gb.get(cbits))) + 1;

                    cbits = avLog2(@intCast(self.cdlms[c][i].scaling + 1));
                    if (@as(u32, 1) << @intCast(cbits) < @as(u32, @intCast(self.cdlms[c][i].scaling + 1))) cbits += 1;
                    self.cdlms[c][i].bitsend = @as(i32, @intCast(self.gb.get(cbits))) + 2;

                    const shift_l: u32 = 32 -% @as(u32, @intCast(self.cdlms[c][i].bitsend));
                    const shift_r: u32 = 32 -% @as(u32, @intCast(self.cdlms[c][i].scaling)) -% 2;
                    for (0..@intCast(self.cdlms[c][i].coefsend)) |j| {
                        const v = self.gb.get(@intCast(self.cdlms[c][i].bitsend));
                        const cval = (v << @intCast(shift_l)) >> @intCast(shift_r);
                        self.cdlms[c][i].coefs[j] = @as(i16, @bitCast(@as(u16, @truncate(cval))));
                    }
                }
            }
            for (0..self.cdlms_ttl[c]) |i| {
                // memset(coefs + order, 0, WMALL_COEFF_PAD_SIZE)
                const ord: usize = @intCast(self.cdlms[c][i].order);
                for (0..COEF_PAD_ELEMS) |k| {
                    self.cdlms[c][i].coefs[ord + k] = 0;
                }
            }
        }
    }

    fn decodeLpc(self: *Dec) void {
        self.lpc_order = @intCast(self.gb.get(5) + 1);
        self.lpc_scaling = @intCast(self.gb.get(4));
        self.lpc_intbits = @intCast(self.gb.get(3) + 1);
        const cbits: usize = @intCast(self.lpc_scaling + self.lpc_intbits);
        for (0..self.num_channels) |ch| {
            for (0..@intCast(self.lpc_order)) |i| {
                self.lpc_coefs[ch][i] = getSignedBits(&self.gb, cbits);
            }
        }
    }

    fn clearCodecBuffers(self: *Dec) void {
        self.acfilter_coeffs = @splat(0);
        self.acfilter_prevvalues = @splat(@splat(0));
        self.lpc_coefs = @splat(@splat(0));
        self.mclms_coeffs = @splat(0);
        self.mclms_coeffs_cur = @splat(0);
        self.mclms_prevvalues = @splat(0);
        self.mclms_updates = @splat(0);
        for (0..self.num_channels) |ich| {
            for (0..self.cdlms_ttl[ich]) |ilms| {
                self.cdlms[ich][ilms].coefs = @splat(0);
                self.cdlms[ich][ilms].lms_prevvalues_16 = @splat(0);
                self.cdlms[ich][ilms].lms_prevvalues_32 = @splat(0);
                self.cdlms[ich][ilms].lms_updates = @splat(0);
            }
            self.ave_sum[ich] = 0;
        }
    }

    fn resetCodec(self: *Dec) void {
        self.mclms_recent = self.mclms_order * @as(i32, @intCast(self.num_channels));
        for (0..self.num_channels) |ich| {
            for (0..self.cdlms_ttl[ich]) |ilms| {
                self.cdlms[ich][ilms].recent = self.cdlms[ich][ilms].order;
            }
            self.channel[ich].transient_counter = @intCast(self.samples_per_frame);
            self.transient[ich] = 1;
            self.transient_pos[ich] = 0;
        }
    }

    fn mclmsUpdate(self: *Dec, icoef: usize, pred: *const [WMALL_MAX_CHANNELS]i32) void {
        const order = self.mclms_order;
        const num_channels: i32 = @intCast(self.num_channels);
        const range: i32 = @as(i32, 1) << @intCast(self.bits_per_sample - 1);
        const spf = self.samples_per_frame;

        for (0..self.num_channels) |ich0| {
            const ich: i32 = @intCast(ich0);
            const resid = self.channel_residues[@as(usize, @intCast(ich)) * spf + icoef];
            // pred_error = residue - (unsigned)pred[ich]（u32 模减 → i32 位）
            const pred_error: i32 = @bitCast(@as(u32, @bitCast(resid)) -% @as(u32, @bitCast(pred[ich0])));
            if (pred_error > 0) {
                for (0..@intCast(order * num_channels)) |i| {
                    const cf_i = @as(usize, @intCast(ich * order * num_channels)) + i;
                    self.mclms_coeffs[cf_i] = @truncate(@as(i32, self.mclms_coeffs[cf_i]) +% self.mclms_updates[@intCast(self.mclms_recent + @as(i32, @intCast(i)))]);
                }
                for (0..@intCast(ich)) |j| {
                    const cc_i = @as(usize, @intCast(ich * num_channels)) + j;
                    self.mclms_coeffs_cur[cc_i] = @truncate(@as(i32, self.mclms_coeffs_cur[cc_i]) +% wmaSign(self.channel_residues[j * spf + icoef]));
                }
            } else if (pred_error < 0) {
                for (0..@intCast(order * num_channels)) |i| {
                    const cf_i = @as(usize, @intCast(ich * order * num_channels)) + i;
                    self.mclms_coeffs[cf_i] = @truncate(@as(i32, self.mclms_coeffs[cf_i]) -% self.mclms_updates[@intCast(self.mclms_recent + @as(i32, @intCast(i)))]);
                }
                for (0..@intCast(ich)) |j| {
                    const cc_i = @as(usize, @intCast(ich * num_channels)) + j;
                    self.mclms_coeffs_cur[cc_i] = @truncate(@as(i32, self.mclms_coeffs_cur[cc_i]) -% wmaSign(self.channel_residues[j * spf + icoef]));
                }
            }
        }

        var ich: i32 = num_channels - 1;
        while (ich >= 0) : (ich -= 1) {
            self.mclms_recent -= 1;
            const resid = self.channel_residues[@as(usize, @intCast(ich)) * spf + icoef];
            self.mclms_prevvalues[@as(usize, @intCast(self.mclms_recent))] = clipI(resid, -range, range - 1);
            self.mclms_updates[@as(usize, @intCast(self.mclms_recent))] = wmaSign(resid);
        }

        if (self.mclms_recent == 0) {
            const n: usize = @intCast(order * num_channels);
            std.mem.copyForwards(i32, self.mclms_prevvalues[n .. 2 * n], self.mclms_prevvalues[0..n]);
            std.mem.copyForwards(i32, self.mclms_updates[n .. 2 * n], self.mclms_updates[0..n]);
            self.mclms_recent = num_channels * order;
        }
    }

    fn mclmsPredict(self: *Dec, icoef: usize, pred: *[WMALL_MAX_CHANNELS]i32) void {
        const order = self.mclms_order;
        const num_channels: i32 = @intCast(self.num_channels);
        const spf = self.samples_per_frame;

        for (0..self.num_channels) |ich0| {
            pred[ich0] = 0;
            if (self.is_channel_coded[ich0] == 0) continue;
            const ich: i32 = @intCast(ich0);
            var acc: u32 = 0;
            for (0..@intCast(order * num_channels)) |i| {
                const pv: u32 = @bitCast(self.mclms_prevvalues[@intCast(self.mclms_recent + @as(i32, @intCast(i)))]);
                const cf: u32 = @bitCast(@as(i32, self.mclms_coeffs[@as(usize, @intCast(i)) + @as(usize, @intCast(order * num_channels * ich))]));
                acc +%= pv *% cf;
            }
            for (0..@intCast(ich)) |i| {
                const rv: u32 = @bitCast(self.channel_residues[i * spf + icoef]);
                const cf: u32 = @bitCast(@as(i32, self.mclms_coeffs_cur[i + @as(usize, @intCast(num_channels * ich))]));
                acc +%= rv *% cf;
            }
            // pred[ich] += (1U << scaling) >> 1;  pred[ich] >>= scaling（算术）
            var pr: u32 = acc;
            pr +%= (@as(u32, 1) << @intCast(self.mclms_scaling)) >> 1;
            var pr_i: i32 = @bitCast(pr);
            if (self.mclms_scaling > 0) {
                pr_i >>= @intCast(self.mclms_scaling);
            }
            pred[ich0] = pr_i;
            const cur = self.channel_residues[ich0 * spf + icoef];
            self.channel_residues[ich0 * spf + icoef] = @bitCast(@as(u32, @bitCast(cur)) +% @as(u32, @bitCast(pr_i)));
        }
    }

    fn useHighUpdateSpeed(self: *Dec, ich: usize) void {
        if (self.update_speed[ich] == 16) return;
        var ilms: i32 = @intCast(self.cdlms_ttl[ich] - 1);
        while (ilms >= 0) : (ilms -= 1) {
            const k: usize = @intCast(ilms);
            const recent: usize = @intCast(self.cdlms[ich][k].recent);
            const order: usize = @intCast(self.cdlms[ich][k].order);
            if (self.bV3RTM) {
                for (0..order) |icoef| {
                    self.cdlms[ich][k].lms_updates[icoef + recent] *%= 2;
                }
            } else {
                for (0..order) |icoef| {
                    self.cdlms[ich][k].lms_updates[icoef] *%= 2;
                }
            }
        }
        self.update_speed[ich] = 16;
    }

    fn useNormalUpdateSpeed(self: *Dec, ich: usize) void {
        if (self.update_speed[ich] == 8) return;
        var ilms: i32 = @intCast(self.cdlms_ttl[ich] - 1);
        while (ilms >= 0) : (ilms -= 1) {
            const k: usize = @intCast(ilms);
            const recent: usize = @intCast(self.cdlms[ich][k].recent);
            const order: usize = @intCast(self.cdlms[ich][k].order);
            if (self.bV3RTM) {
                for (0..order) |icoef| {
                    self.cdlms[ich][k].lms_updates[icoef + recent] = @divTrunc(self.cdlms[ich][k].lms_updates[icoef + recent], 2);
                }
            } else {
                for (0..order) |icoef| {
                    self.cdlms[ich][k].lms_updates[icoef] = @divTrunc(self.cdlms[ich][k].lms_updates[icoef], 2);
                }
            }
        }
        self.update_speed[ich] = 8;
    }

    /// lms_update（CD_LMS 宏；16/24-bit 仅历史样本存储类型不同）
    fn lmsUpdate(self: *Dec, ich: usize, ilms: usize, input: i32) void {
        const range: i32 = @as(i32, 1) << @intCast(self.bits_per_sample - 1);
        const c = &self.cdlms[ich][ilms];
        const order: usize = @intCast(c.order);
        var recent: i32 = c.recent;

        if (recent != 0) {
            recent -= 1;
        } else {
            // memcpy(prev + order, prev, (bits/8)*order) → 相应类型 order 个
            if (self.bits_per_sample == 16) {
                std.mem.copyForwards(i16, c.lms_prevvalues_16[order .. 2 * order], c.lms_prevvalues_16[0..order]);
            } else {
                std.mem.copyForwards(i32, c.lms_prevvalues_32[order .. 2 * order], c.lms_prevvalues_32[0..order]);
            }
            std.mem.copyForwards(i16, c.lms_updates[order .. 2 * order], c.lms_updates[0..order]);
            recent = @intCast(order - 1);
        }
        const ridx: usize = @intCast(recent);

        const clipv = clipI(input, -range, range - 1);
        if (self.bits_per_sample == 16) {
            c.lms_prevvalues_16[ridx] = @truncate(clipv);
        } else {
            c.lms_prevvalues_32[ridx] = clipv;
        }
        c.lms_updates[ridx] = @truncate(wmaSign(input) * self.update_speed[ich]);

        c.lms_updates[ridx + (order >> 4)] >>= 2;
        c.lms_updates[ridx + (order >> 3)] >>= 1;

        c.recent = recent;
        // memset(lms_updates + recent + order, 0, 整个数组剩余)
        const zstart = @as(usize, @intCast(recent)) + order;
        @memset(c.lms_updates[zstart..], 0);
    }

    /// revert_cdlms（CD_LMS 宏；对齐迭代使系数 pad 陈旧值与 C 一致）
    fn revertCdlms(self: *Dec, ch: usize, coef_begin: usize, coef_end: usize) void {
        const num_lms = self.cdlms_ttl[ch];
        var ilms: i32 = @intCast(num_lms - 1);
        while (ilms >= 0) : (ilms -= 1) {
            const k: usize = @intCast(ilms);
            const c = &self.cdlms[ch][k];
            const scaling: i32 = c.scaling;
            const mul_base: usize = if (self.bits_per_sample == 16)
                fAlign(@intCast(c.order), WMALL_COEFF_PAD_SIZE)
            else
                fAlign(@intCast(c.order), 8);

            var icoef = coef_begin;
            while (icoef < coef_end) : (icoef += 1) {
                var pred: u32 = (@as(u32, 1) << @intCast(scaling)) >> 1;
                const residue = self.channel_residues[ch * self.samples_per_frame + icoef];
                const mul: i32 = wmaSign(residue);
                // recent 随每次 lms_update 递减 → 每 icoef 重新读取（对齐 C）
                const recent: usize = @intCast(c.recent);

                var acc: u32 = 0;
                if (self.bits_per_sample == 16) {
                    for (0..mul_base) |i| {
                        const v1s: i32 = c.coefs[i];
                        const v2: i32 = c.lms_prevvalues_16[recent + i];
                        acc = acc +% @as(u32, @bitCast(v1s *% v2));
                        const upd: i32 = c.lms_updates[recent + i];
                        c.coefs[i] = @truncate(v1s +% mul *% upd);
                    }
                } else {
                    for (0..mul_base) |i| {
                        const v1s: i32 = c.coefs[i];
                        const v2: u32 = @bitCast(c.lms_prevvalues_32[recent + i]);
                        acc = acc +% (@as(u32, @bitCast(v1s)) *% v2);
                        const upd: i32 = c.lms_updates[recent + i];
                        c.coefs[i] = @truncate(v1s +% mul *% upd);
                    }
                }
                pred +%= acc;
                // input = residue + (unsigned)((int)pred >> scaling)（算术）
                var shr: i32 = @bitCast(pred);
                if (scaling > 0) shr >>= @intCast(scaling);
                const input: i32 = @bitCast(@as(u32, @bitCast(residue)) +% @as(u32, @bitCast(shr)));
                self.lmsUpdate(ch, k, input);
                self.channel_residues[ch * self.samples_per_frame + icoef] = input;
            }
        }
    }

    fn decodeChannelResidues(self: *Dec, ch: usize, tile_size: usize) anyerror!void {
        var i: usize = 0;
        self.transient[ch] = @intCast(self.gb.get1());
        if (self.transient[ch] != 0) {
            self.transient_pos[ch] = @intCast(self.gb.get(avLog2(@intCast(tile_size))));
            if (self.transient_pos[ch] != 0) self.transient[ch] = 0;
            self.channel[ch].transient_counter = maxI(self.channel[ch].transient_counter, @intCast(self.samples_per_frame / 2));
        } else if (self.channel[ch].transient_counter != 0) {
            self.transient[ch] = 1;
        }

        if (self.seekable_tile) {
            const ave_mean = self.gb.get(self.bits_per_sample);
            self.ave_sum[ch] = @as(u32, @intCast(ave_mean)) << @intCast(self.movave_scaling + 1);
        }
        if (self.seekable_tile) {
            if (self.do_inter_ch_decorr != 0)
                self.channel_residues[ch * self.samples_per_frame] = getSignedBits(&self.gb, self.bits_per_sample + 1)
            else
                self.channel_residues[ch * self.samples_per_frame] = getSignedBits(&self.gb, self.bits_per_sample);
            i = 1;
        }

        const movave: usize = @intCast(self.movave_scaling);
        while (i < tile_size) : (i += 1) {
            var quo: u32 = 0;
            while (self.gb.get1() != 0) {
                quo +%= 1;
                if (self.gb.index >= self.gb.cap) return error.ResidueOverrun;
            }
            if (quo >= 32) {
                const extra = self.gb.get(5) + 1;
                quo +%= self.gb.get(@intCast(extra));
            }
            const ave_mean = (self.ave_sum[ch] +% (@as(u32, 1) << @intCast(movave))) >> @intCast(movave + 1);
            var residue: u32 = 0;
            if (ave_mean <= 1) {
                residue = quo;
            } else {
                const rem_bits = avCeilLog2(ave_mean);
                const rem = self.gb.get(@intCast(rem_bits));
                residue = (quo << @intCast(rem_bits)) +% rem;
            }
            self.ave_sum[ch] = residue +% self.ave_sum[ch] -% (self.ave_sum[ch] >> @intCast(movave));
            residue = (residue >> 1) ^ (0 -% (residue & 1));
            self.channel_residues[ch * self.samples_per_frame + i] = @bitCast(residue);
        }
    }

    fn revertInterChDecorr(self: *Dec, tile_size: usize) void {
        if (self.num_channels != 2) return;
        if (self.is_channel_coded[0] != 0 or self.is_channel_coded[1] != 0) {
            const spf = self.samples_per_frame;
            for (0..tile_size) |icoef| {
                const r1 = self.channel_residues[spf + icoef];
                const r0 = self.channel_residues[icoef];
                var sh: i32 = r1;
                if (self.bits_per_sample >= 2) sh >>= 1;
                self.channel_residues[icoef] = @bitCast(@as(u32, @bitCast(r0)) -% @as(u32, @bitCast(sh)));
                const n0 = self.channel_residues[icoef];
                self.channel_residues[spf + icoef] = @bitCast(@as(u32, @bitCast(r1)) +% @as(u32, @bitCast(n0)));
            }
        }
    }

    fn revertAcFilter(self: *Dec, tile_size: usize) void {
        const order: usize = @intCast(self.acfilter_order);
        const scaling: usize = @intCast(self.acfilter_scaling);
        const spf = self.samples_per_frame;
        for (0..self.num_channels) |ich| {
            const prevvalues = &self.acfilter_prevvalues[ich];
            for (0..order) |i| {
                var pred: u32 = 0;
                for (0..order) |j| {
                    const cv: u32 = @bitCast(@as(i32, self.acfilter_coeffs[j]));
                    if (i <= j) {
                        pred +%= cv *% @as(u32, @bitCast(prevvalues[j - i]));
                    } else {
                        pred +%= cv *% @as(u32, @bitCast(self.channel_residues[ich * spf + (i - j - 1)]));
                    }
                }
                var shr: i32 = @bitCast(pred);
                if (scaling > 0) shr >>= @intCast(scaling);
                const cur = self.channel_residues[ich * spf + i];
                self.channel_residues[ich * spf + i] = @bitCast(@as(u32, @bitCast(cur)) +% @as(u32, @bitCast(shr)));
            }
            for (order..tile_size) |i| {
                var pred: u32 = 0;
                for (0..order) |j| {
                    const cv: u32 = @bitCast(@as(i32, self.acfilter_coeffs[j]));
                    pred +%= cv *% @as(u32, @bitCast(self.channel_residues[ich * spf + (i - j - 1)]));
                }
                var shr: i32 = @bitCast(pred);
                if (scaling > 0) shr >>= @intCast(scaling);
                const cur = self.channel_residues[ich * spf + i];
                self.channel_residues[ich * spf + i] = @bitCast(@as(u32, @bitCast(cur)) +% @as(u32, @bitCast(shr)));
            }
            var j: i32 = @intCast(order - 1);
            while (j >= 0) : (j -= 1) {
                const jj: usize = @intCast(j);
                if (tile_size <= jj) {
                    prevvalues[jj] = prevvalues[jj - tile_size];
                } else {
                    prevvalues[jj] = self.channel_residues[ich * spf + (tile_size - jj - 1)];
                }
            }
        }
    }

    fn revertMclms(self: *Dec, tile_size: usize) void {
        var pred: [WMALL_MAX_CHANNELS]i32 = @splat(0);
        for (0..tile_size) |icoef| {
            self.mclmsPredict(icoef, &pred);
            self.mclmsUpdate(icoef, &pred);
        }
    }

    // ================= 子帧 / 帧 / 包 =================

    fn decodeSubframe(self: *Dec) anyerror!void {
        var offset: usize = self.samples_per_frame;
        var subframe_len: usize = self.samples_per_frame;
        var total_samples: usize = self.samples_per_frame * self.num_channels;

        for (0..self.num_channels) |i| {
            if (offset > self.channel[i].decoded_samples) {
                offset = self.channel[i].decoded_samples;
                subframe_len = self.channel[i].subframe_len[self.channel[i].cur_subframe];
            }
        }

        self.channels_for_cur_subframe = 0;
        for (0..self.num_channels) |i| {
            const cur_subframe = self.channel[i].cur_subframe;
            total_samples -= self.channel[i].decoded_samples;
            if (offset == self.channel[i].decoded_samples and
                subframe_len == self.channel[i].subframe_len[cur_subframe])
            {
                total_samples -= self.channel[i].subframe_len[cur_subframe];
                self.channel[i].decoded_samples += self.channel[i].subframe_len[cur_subframe];
                self.channel_indexes_for_cur_subframe[self.channels_for_cur_subframe] = @intCast(i);
                self.channels_for_cur_subframe += 1;
            }
        }

        if (total_samples == 0) self.parsed_all_subframes = true;

        self.seekable_tile = self.gb.get1() != 0;
        if (self.seekable_tile) {
            self.clearCodecBuffers();
            self.do_arith_coding = @intCast(self.gb.get1());
            if (self.do_arith_coding != 0) return error.UnsupportedFormat;
            self.do_ac_filter = @intCast(self.gb.get1());
            self.do_inter_ch_decorr = @intCast(self.gb.get1());
            self.do_mclms = @intCast(self.gb.get1());

            if (self.do_ac_filter != 0) self.decodeAcFilter();
            if (self.do_mclms != 0) self.decodeMclms();

            try self.decodeCdlms();
            self.movave_scaling = @intCast(self.gb.get(3));
            self.quant_stepsize = @as(i32, @intCast(self.gb.get(8))) + 1;
            self.resetCodec();
        }

        const rawpcm_tile = self.gb.get1() != 0;

        if (!rawpcm_tile and self.cdlms[0][0].order == 0) {
            return error.WaitingForSeekableTile;
        }

        for (0..self.num_channels) |i| self.is_channel_coded[i] = 1;

        if (!rawpcm_tile) {
            for (0..self.num_channels) |i| {
                self.is_channel_coded[i] = @intCast(self.gb.get1());
            }
            if (self.bV3RTM) {
                self.do_lpc = @intCast(self.gb.get1());
                if (self.do_lpc != 0) {
                    self.decodeLpc();
                }
            } else {
                self.do_lpc = 0;
            }
        }

        var padding_zeroes: u32 = 0;
        if (self.gb.bitsLeft() < 1) return error.Corrupt;
        if (self.gb.get1() != 0) padding_zeroes = self.gb.get(5);

        if (rawpcm_tile) {
            const bits: u32 = @as(u32, self.bits_per_sample) -% padding_zeroes;
            if (bits == 0 or bits > 32) return error.Corrupt;
            for (0..self.num_channels) |i| {
                for (0..subframe_len) |j| {
                    self.channel_residues[i * self.samples_per_frame + j] = getSignedBits(&self.gb, @intCast(bits));
                }
            }
        } else {
            if (@as(u32, self.bits_per_sample) < padding_zeroes) return error.Corrupt;
            for (0..self.num_channels) |i| {
                if (self.is_channel_coded[i] != 0) {
                    // C 中 decode_channel_residues 的返回被忽略（位耗尽时只解出
                    // 部分残差，仍继续 revert_cdlms——对齐截断帧的 ffmpeg 输出）
                    self.decodeChannelResidues(i, subframe_len) catch {};
                    if (self.seekable_tile)
                        self.useHighUpdateSpeed(i)
                    else
                        self.useNormalUpdateSpeed(i);
                    self.revertCdlms(i, 0, subframe_len);
                } else {
                    @memset(self.channel_residues[i * self.samples_per_frame ..][0..subframe_len], 0);
                }
            }
            if (self.do_mclms != 0) self.revertMclms(subframe_len);
            if (self.do_inter_ch_decorr != 0) self.revertInterChDecorr(subframe_len);
            if (self.do_ac_filter != 0) self.revertAcFilter(subframe_len);

            if (self.quant_stepsize != 1) {
                for (0..self.num_channels) |i| {
                    for (0..subframe_len) |j| {
                        const v = &self.channel_residues[i * self.samples_per_frame + j];
                        v.* *%= self.quant_stepsize;
                    }
                }
            }
        }

        // 写入帧输出缓冲（16-bit: (int16)residue*(1<<pad)；24-bit: residue*(256U<<pad)）
        for (0..self.channels_for_cur_subframe) |i| {
            const c = self.channel_indexes_for_cur_subframe[i];
            const clen = self.channel[c].subframe_len[self.channel[c].cur_subframe];
            const pos = self.out_pos[c];
            if (self.bits_per_sample == 16) {
                const sh: u4 = @truncate(padding_zeroes);
                for (0..clen) |j| {
                    const v: i16 = @truncate(self.channel_residues[c * self.samples_per_frame + j]);
                    self.out_16[c * self.samples_per_frame + pos + j] = v << sh;
                }
            } else {
                const sh: u5 = @intCast(padding_zeroes + 8);
                for (0..clen) |j| {
                    const v = self.channel_residues[c * self.samples_per_frame + j];
                    self.out_32[c * self.samples_per_frame + pos + j] = @bitCast(@as(u32, @bitCast(v)) << sh);
                }
            }
        }

        for (0..self.channels_for_cur_subframe) |i| {
            const c = self.channel_indexes_for_cur_subframe[i];
            if (self.channel[c].cur_subframe >= self.channel[c].num_subframes) return error.Corrupt;
            const clen = self.channel[c].subframe_len[self.channel[c].cur_subframe];
            self.out_pos[c] += clen;
            self.channel[c].cur_subframe += 1;
        }
    }

    /// 解码一帧。返回：1=蓄存器还有帧（more_frames）、0=本帧为尾帧、-1=出错。
    fn decodeFrame(self: *Dec) i2 {
        var len: usize = 0;
        if (self.len_prefix) len = @intCast(self.gb.get(self.log2_frame_size));
        for (0..self.num_channels) |c| self.out_pos[c] = 0;
        self.decodeTilehdr() catch {
            self.packet_loss = true;
            self.frame_pending = false;
            return -1;
        };

        if (self.dynamic_range_compression) self.drc_gain = self.gb.get(8);

        var nb_samples: usize = self.samples_per_frame;
        const skip_log = avLog2(@intCast(self.samples_per_frame * 2));
        if (self.gb.get1() != 0) {
            if (self.gb.get1() != 0) {
                _ = self.gb.get(skip_log);
            }
            if (self.gb.get1() != 0) {
                const skip = self.gb.get(skip_log);
                if (nb_samples <= skip) return -1;
                nb_samples -= skip;
            }
        }

        self.parsed_all_subframes = false;
        for (0..self.num_channels) |i| {
            self.channel[i].decoded_samples = 0;
            self.channel[i].cur_subframe = 0;
        }

        while (!self.parsed_all_subframes) {
            const decoded_samples = self.channel[0].decoded_samples;
            self.decodeSubframe() catch |err| {
                self.packet_loss = true;
                if (err == error.WaitingForSeekableTile) {
                    // decode_subframe: av_frame_unref → 帧丢弃（0 样本）
                    self.frame_pending = false;
                } else {
                    if (nb_samples != 0) nb_samples = decoded_samples;
                    if (nb_samples == 0) {
                        self.frame_pending = false;
                    } else {
                        self.frame_pending = true;
                        self.frame_nb_samples = nb_samples;
                    }
                }
                return -1;
            };
        }

        if (self.len_prefix) {
            if (len != (self.gb.count() - self.frame_offset) + 2) {
                self.packet_loss = true;
                self.frame_pending = false;
                return -1;
            }
            const skip_bits = len - (self.gb.count() - self.frame_offset) - 1;
            self.gb.skip(skip_bits);
        }

        const more_frames = self.gb.get1();
        self.frame_num += 1;

        if (nb_samples == 0) {
            self.frame_pending = false;
        } else {
            self.frame_pending = true;
            self.frame_nb_samples = nb_samples;
        }
        const fr: i2 = if (more_frames != 0) 1 else 0;
        return fr;
    }

    fn remainingBits(self: *Dec, gb: *Bits) usize {
        return self.buf_bit_size -% gb.count();
    }

    fn saveBits(self: *Dec, gb: *Bits, len0: usize, append: bool) void {
        var len = len0;
        if (len == 0) return;
        if (len > self.max_frame_size * 8) {
            self.packet_loss = true;
            self.num_saved_bits = 0;
            return;
        }
        var buflen: usize = undefined;
        if (!append) {
            self.frame_offset = gb.count() & 7;
            self.num_saved_bits = self.frame_offset;
            self.pb.reset();
            buflen = (self.num_saved_bits + len + 8) >> 3;
        } else {
            buflen = (self.pb.count() + len + 8) >> 3;
        }
        if (len <= 0 or buflen > self.max_frame_size) {
            self.packet_loss = true;
            self.num_saved_bits = 0;
            return;
        }
        self.num_saved_bits += len;
        if (!append) {
            self.pb.copyBits(gb.buf[gb.count() >> 3 ..], self.num_saved_bits);
        } else {
            var nalign = 8 - (gb.count() & 7);
            if (nalign > len) nalign = len;
            self.pb.write(nalign, gb.get(nalign));
            len -= nalign;
            self.pb.copyBits(gb.buf[gb.count() >> 3 ..], len);
        }
        gb.skip(len);
        // 对齐 ffmpeg save_bits 尾部 `tmp = s->pb; flush_put_bits(&tmp);`：
        // 通过副本把滞留的尾部位补 0 落盘到物理缓冲（不改动持久 pb 状态）。
        {
            var tmp = self.pb;
            tmp.flush();
        }
        self.gb = .{ .buf = self.frame_data, .cap = self.num_saved_bits, .index = 0 };
        self.gb.skip(self.frame_offset);
    }

    /// 处理一个 WMA packet（对齐 decode_packet）。返回消费字节数。
    /// frame_pending 置位表示有输出帧（frame_nb_samples）。
    pub fn decodePacket(self: *Dec, buf_in: []const u8) Error!usize {
        self.frame_pending = false;
        const buf_size_all = buf_in.len;
        var buf = buf_in;

        if (buf_size_all == 0) {
            self.packet_done = false;
            if (self.num_saved_bits <= self.gb.count()) return 0;
            const r = self.decodeFrame();
            if (r == 0) self.num_saved_bits = 0;
        } else if (self.packet_done or self.packet_loss) {
            self.packet_done = false;
            // WMA packet 取「末尾 block_align 字节」；最后一个 ASF 对象常短于
            // block_align（文件截止的残尾），按实际长度处理（对齐 ffmpeg
            // decode_packet：无最小长度限制）。
            self.next_packet_start = buf_size_all - @min(self.block_align, buf_size_all);
            const wsize: usize = @min(self.block_align, buf_size_all);
            buf = buf_in[0..wsize];
            self.buf_bit_size = wsize << 3;
            self.pgb = .{ .buf = buf, .cap = self.buf_bit_size, .index = 0 };

            const packet_sequence_number = @as(usize, self.pgb.get(4));
            self.pgb.skip(1); // seekable_frame_in_packet
            const spliced_packet = self.pgb.get1();
            _ = spliced_packet;
            var num_bits_prev_frame = @as(usize, self.pgb.get(self.log2_frame_size));

            if (!self.packet_loss and ((self.packet_sequence_number + 1) & 0xF) != packet_sequence_number) {
                self.packet_loss = true;
            }
            self.packet_sequence_number = packet_sequence_number;

            if (num_bits_prev_frame > 0) {
                const remaining_packet_bits = self.buf_bit_size - self.pgb.count();
                if (num_bits_prev_frame >= remaining_packet_bits) {
                    num_bits_prev_frame = remaining_packet_bits;
                    self.packet_done = true;
                }
                self.saveBits(&self.pgb, num_bits_prev_frame, true);
                if (!self.packet_loss) {
                    _ = self.decodeFrame();
                }
            } else if (self.num_saved_bits - self.frame_offset > 0) {
                // 忽略之前未解码的已保存位
            }

            if (self.packet_loss) {
                self.num_saved_bits = 0;
                self.packet_loss = false;
            }
        } else {
            if (buf_size_all < self.next_packet_start) {
                self.packet_loss = true;
                return 0;
            }
            const wsize = buf_size_all - self.next_packet_start;
            self.buf_bit_size = wsize << 3;
            buf = buf_in[0..wsize];
            self.pgb = .{ .buf = buf, .cap = self.buf_bit_size, .index = 0 };
            self.pgb.skip(self.packet_offset);

            if (self.len_prefix and self.remainingBits(&self.pgb) > self.log2_frame_size) {
                const frame_size = @as(usize, self.pgb.peek(self.log2_frame_size));
                if (frame_size != 0 and frame_size <= self.remainingBits(&self.pgb)) {
                    self.saveBits(&self.pgb, frame_size, false);
                    if (!self.packet_loss) {
                        const more = self.decodeFrame();
                        self.packet_done = more == 0;
                    } else {
                        self.packet_done = true;
                    }
                } else {
                    self.packet_done = true;
                }
            } else if (!self.len_prefix and self.num_saved_bits > self.gb.count()) {
                const more = self.decodeFrame();
                self.packet_done = more == 0;
            } else {
                self.packet_done = true;
            }
        }

        if (self.remainingBits(&self.pgb) < 0) {
            self.packet_loss = true;
        }

        if (self.packet_done and !self.packet_loss and self.remainingBits(&self.pgb) > 0) {
            self.saveBits(&self.pgb, @intCast(self.remainingBits(&self.pgb)), false);
        }

        self.packet_offset = self.pgb.count() & 7;
        if (self.packet_loss) return error.Corrupt;

        return self.pgb.count() >> 3;
    }
};

/// ff_wma_get_frame_len_bits(sample_rate, version=3, decode_flags)
pub fn wmaFrameLenBits(sample_rate: u32, decode_flags: u16) u32 {
    var frame_len_bits: u32 = if (sample_rate <= 16000)
        9
    else if (sample_rate <= 22050)
        10
    else if (sample_rate <= 48000)
        11
    else if (sample_rate <= 96000)
        12
    else
        13;
    const tmp = decode_flags & 0x6;
    if (tmp == 0x2) {
        frame_len_bits += 1;
    } else if (tmp == 0x4) {
        frame_len_bits -= 1;
    } else if (tmp == 0x6) {
        frame_len_bits -= 2;
    }
    return frame_len_bits;
}

test "wmalossless frame_len_bits v3" {
    try std.testing.expectEqual(@as(u32, 11), wmaFrameLenBits(44100, 0x21));
    try std.testing.expectEqual(@as(u32, 11), wmaFrameLenBits(48000, 0x1a1));
    try std.testing.expectEqual(@as(u32, 12), wmaFrameLenBits(96000, 0));
}

test "wmalossless math helpers" {
    try std.testing.expectEqual(@as(u32, 3), avCeilLog2(8));
    try std.testing.expectEqual(@as(u32, 4), avCeilLog2(9));
    try std.testing.expectEqual(@as(u32, 0), avCeilLog2(1));
    try std.testing.expectEqual(@as(i32, 1), wmaSign(5));
    try std.testing.expectEqual(@as(i32, -1), wmaSign(-5));
    try std.testing.expectEqual(@as(i32, 0), wmaSign(0));
    try std.testing.expectEqual(@as(usize, 16), fAlign(8, 16));
    try std.testing.expectEqual(@as(usize, 256), fAlign(256, 16));
}
