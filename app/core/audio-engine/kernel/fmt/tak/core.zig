// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! TAK (Tom's lossless Audio Kompressor, .tak) 帧解码核心（逐句对齐 FFmpeg
//! n9.0.1 libavcodec/takdec.c + tak.c）。纯整数定点，无浮点。
//!
//! 语义要点：
//!   - 位流为 **LSB-first**（BITSTREAM_READER_LE）；帧头 sync = 0xA0FF（盘上字节
//!     FF A0）；越界读 0（CACHED reader + AV_INPUT_BUFFER_PADDING 零填充语义）；
//!   - 帧结构：sync16/标志3/帧号21 [+ IS_LAST: 末帧样本14+2] [+ HAS_INFO:
//!     STREAMINFO 位段 + 可选 25 位字段 + 字节对齐] + 24-bit CRC（解码路径不校验，
//!     帧边界扫描时才校验）；
//!   - 通道模型：1 个种子样本 + nb_subframes 个子帧（预测阶 4..256、filter_quant
//!     移位自适应、量化反射系数经 tfilter 逆变换成滤波器抽头）；子帧残差用
//!     xcodes[50] 分段 Rice 码（模式自适应、多块模式），定点重建
//!     `out = (clip(pred>>fq,13) << dshift) - residual`；
//!   - 双声道联合去相关 dmode 1..7（L/S、S/R、S/M、缩放 S/L、S/R、8/16 抽头 FIR）；
//!     多声道（codec=4）mcdparams 链式去相关；
//!   - 帧末：整通道 lpc_mode（1/2/3 差分积分）+ sample_shift 左移还原；
//!   - 溢出/符号语义完全复刻 C：int16_t 存储回绕、乘加在 u32/i32 回绕域、
//!     算术右移、av_clip_intp2、544 元素 i16 残差滑动环。
//!
//! 输出布局对齐 ffmpeg 内部样本格式：8bit → u8(+0x80)、16bit → s16、
//! 24bit → int32<<8（=`-f s32le`）。

const std = @import("std");
const Error = @import("../../error.zig").Error;
const T = @import("tables.zig");

// ---- 流信息 / 帧头解析 ----

/// TAKStreamInfo（tak.h）等价。has_info = 帧头带 STREAMINFO。
pub const StreamInfo = struct {
    codec: u32 = 0,
    data_type: u32 = 0,
    sample_rate: u32 = 0,
    bps: u32 = 0,
    channels: u32 = 0,
    frame_num: u32 = 0,
    frame_samples: i32 = 0,
    last_frame_samples: i32 = 0,
    samples: i64 = 0,
    ch_layout: u64 = 0,
    has_info: bool = false,
};

/// LSB-first 位读取器（CACHED reader LE + 零填充越界语义）。
pub const BitReader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn init(data: []const u8) BitReader {
        return .{ .data = data };
    }

    pub fn bitsLeft(self: *const BitReader) i64 {
        return @as(i64, @intCast(self.data.len * 8)) - @as(i64, @intCast(self.pos));
    }

    /// get_bits1：越界返回 0（零填充），位置前进。
    pub fn readBit(self: *BitReader) u1 {
        const byte_idx = self.pos >> 3;
        const b: u8 = if (byte_idx < self.data.len) self.data[byte_idx] else 0;
        const v: u1 = @intCast((b >> @intCast(self.pos & 7)) & 1);
        self.pos += 1;
        return v;
    }

    /// get_bits（LE）：先读入的位在结果最低位。n ≤ 32。
    pub fn readBits(self: *BitReader, n: u32) u32 {
        var out: u32 = 0;
        var shift: u5 = 0;
        var need = n;
        while (need > 0) {
            const byte_idx = self.pos >> 3;
            const b: u8 = if (byte_idx < self.data.len) self.data[byte_idx] else 0;
            const bit_in: u3 = @intCast(self.pos & 7);
            const take: u32 = @min(need, 8 - @as(u32, bit_in));
            const chunk: u32 = (b >> @intCast(bit_in)) & ((@as(u32, 1) << @intCast(take)) - 1);
            out |= chunk << shift;
            shift += @intCast(take);
            self.pos += @intCast(take);
            need -= take;
        }
        return out;
    }

    /// get_bits64（TAK_SIZE_SAMPLES_NUM_BITS=35 用）
    pub fn readBits64(self: *BitReader, n: u32) u64 {
        var out: u64 = 0;
        var shift: u6 = 0;
        var need = n;
        while (need > 0) {
            const byte_idx = self.pos >> 3;
            const b: u8 = if (byte_idx < self.data.len) self.data[byte_idx] else 0;
            const bit_in: u3 = @intCast(self.pos & 7);
            const take: u32 = @min(need, 8 - @as(u32, bit_in));
            const chunk: u64 = (b >> @intCast(bit_in)) & ((@as(u32, 1) << @intCast(take)) - 1);
            out |= chunk << shift;
            shift += @intCast(take);
            self.pos += @intCast(take);
            need -= take;
        }
        return out;
    }

    /// get_sbits：读 n 位有符号（符号扩展）。
    pub fn readSbits(self: *BitReader, n: u32) i32 {
        if (n == 0) return 0;
        const v = self.readBits(n);
        const sign_shift: u5 = @intCast(32 - n);
        return @as(i32, @bitCast(v << sign_shift)) >> sign_shift;
    }

    /// align_get_bits：推进到下一个字节边界。
    pub fn alignByte(self: *BitReader) void {
        self.pos = (self.pos + 7) & ~@as(usize, 7);
    }

    /// get_unary(gb, stop=1, len)：数连续 0 直到 1（1 被消耗），上限 len。
    pub fn getUnaryStop1(self: *BitReader, len: u32) u32 {
        var i: u32 = 0;
        while (i < len) : (i += 1) {
            if (self.readBit() == 1) return i;
        }
        return len;
    }
};

/// get_bits_esc4（takdec.c）：1 位标志；0 → 0，否则 4 位 + 1。
fn getBitsEsc4(br: *BitReader) u32 {
    if (br.readBit() == 0) return 0;
    return br.readBits(4) + 1;
}

/// int16_t 参与乘加前的 C 提升：先符号扩展到 int，再转 unsigned。
inline fn ext16(v: i16) u32 {
    return @bitCast(@as(i32, v));
}

/// (int16)(unsigned)(int16) 乘积的低 32 位（= C 的 `residue * (unsigned)filter`）。
inline fn mul16(a: i16, b: i16) u32 {
    return ext16(a) *% ext16(b);
}

/// av_clip_intp2(v, p)：钳到 [-2^p, 2^p - 1]。
fn clipIntp2(v: i64, p: u5) i32 {
    const limit: i64 = @as(i64, 1) << @intCast(p);
    if (v > limit - 1) return @intCast(limit - 1);
    if (v < -limit) return @intCast(-limit);
    return @intCast(v);
}

/// scalarproduct_int16（audiodsp.c）：u32 回绕域点积。
fn scalarProductI16(v1: []const i16, v2: []const i16) u32 {
    var acc: u32 = 0;
    for (0..v1.len) |i| {
        acc +%= mul16(v1[i], v2[i]);
    }
    return acc;
}

/// tak_parse_streaminfo（tak.c）：从当前位置解析 STREAMINFO 位段。
pub fn parseStreamInfoBits(br: *BitReader, si: *StreamInfo) Error!void {
    si.codec = br.readBits(T.TAK_ENCODER_CODEC_BITS);
    _ = br.readBits(T.TAK_ENCODER_PROFILE_BITS); // profile
    const frame_type = br.readBits(T.TAK_SIZE_FRAME_DURATION_BITS);
    si.samples = @intCast(br.readBits64(T.TAK_SIZE_SAMPLES_NUM_BITS));
    si.data_type = br.readBits(T.TAK_FORMAT_DATA_TYPE_BITS);
    si.sample_rate = br.readBits(T.TAK_FORMAT_SAMPLE_RATE_BITS) + T.TAK_SAMPLE_RATE_MIN;
    si.bps = br.readBits(T.TAK_FORMAT_BPS_BITS) + T.TAK_BPS_MIN;
    si.channels = br.readBits(T.TAK_FORMAT_CHANNEL_BITS) + T.TAK_CHANNELS_MIN;

    si.ch_layout = 0;
    if (br.readBit() == 1) {
        _ = br.readBits(T.TAK_FORMAT_VALID_BITS);
        if (br.readBit() == 1) {
            for (0..si.channels) |_| {
                _ = br.readBits(T.TAK_FORMAT_CH_LAYOUT_BITS);
            }
        }
    }
    si.frame_samples = @intCast(try T.getNbSamples(si.sample_rate, frame_type));
}

/// ff_tak_decode_frame_header（tak.c）：解析帧头，返回 flags；
/// HAS_INFO 时把流信息并入 si。CRC 24 位被消耗但不校验（解码路径）。
pub fn parseFrameHeader(br: *BitReader, si: *StreamInfo) Error!u8 {
    if (br.readBits(T.TAK_FRAME_HEADER_SYNC_ID_BITS) != T.TAK_FRAME_HEADER_SYNC_ID)
        return error.Corrupt;
    const flags: u8 = @intCast(br.readBits(T.TAK_FRAME_HEADER_FLAGS_BITS));
    si.frame_num = br.readBits(T.TAK_FRAME_HEADER_NO_BITS);

    if (flags & T.TAK_FRAME_HEADER_FLAG_IS_LAST != 0) {
        si.last_frame_samples = @intCast(br.readBits(T.TAK_FRAME_HEADER_SAMPLE_COUNT_BITS) + 1);
        _ = br.readBits(2);
    } else {
        si.last_frame_samples = 0;
    }

    if (flags & T.TAK_FRAME_HEADER_FLAG_HAS_INFO != 0) {
        try parseStreamInfoBits(br, si);
        si.has_info = true;
        if (br.readBits(6) != 0) _ = br.readBits(25);
        br.alignByte();
    } else {
        si.has_info = false;
    }

    if (flags & T.TAK_FRAME_HEADER_FLAG_HAS_METADATA != 0) return error.Corrupt;
    if (br.bitsLeft() < T.TAK_CRC24_BITS) return error.Corrupt;
    _ = br.readBits(T.TAK_CRC24_BITS);
    return flags;
}

// ---- 帧解码上下文（TAKDecContext 等价）----

pub const MAX_CHANNELS: usize = T.TAK_MAX_CHANNELS;

const McdParam = struct {
    present: bool = false,
    index: u8 = 0,
    chan1: u8 = 0,
    chan2: u8 = 0,
};

/// decode_lpc（takdec.c）：预测系数 / 整通道差分积分的原地展开。
/// 输入 []i32，算术在 u32 回绕域。
pub fn decodeLpc(coeffs: []i32, mode: u32, length: usize) void {
    if (length < 2) return;

    if (mode == 1) {
        var a1: u32 = @bitCast(coeffs[0]);
        var idx: usize = 1;
        var i: usize = 0;
        while (i < (length - 1) >> 1) : (i += 1) {
            coeffs[idx] = @bitCast(@as(u32, @bitCast(coeffs[idx])) +% a1);
            coeffs[idx + 1] = @bitCast(@as(u32, @bitCast(coeffs[idx + 1])) +% @as(u32, @bitCast(coeffs[idx])));
            a1 = @bitCast(coeffs[idx + 1]);
            idx += 2;
        }
        if ((length - 1) & 1 != 0) {
            coeffs[idx] = @bitCast(@as(u32, @bitCast(coeffs[idx])) +% a1);
        }
    } else if (mode == 2) {
        var a1: u32 = @bitCast(coeffs[1]);
        var a2: u32 = a1 +% @as(u32, @bitCast(coeffs[0]));
        coeffs[1] = @bitCast(a2);
        if (length > 2) {
            var idx: usize = 2;
            var i: usize = 0;
            while (i < (length - 2) >> 1) : (i += 1) {
                const a3: u32 = @as(u32, @bitCast(coeffs[idx])) +% a1;
                const a4: u32 = a3 +% a2;
                coeffs[idx] = @bitCast(a4);
                a1 = @as(u32, @bitCast(coeffs[idx + 1])) +% a3;
                a2 = a1 +% a4;
                coeffs[idx + 1] = @bitCast(a2);
                idx += 2;
            }
            if (length & 1 != 0) {
                coeffs[idx] = @bitCast(@as(u32, @bitCast(coeffs[idx])) +% (a1 +% a2));
            }
        }
    } else if (mode == 3) {
        const a1: u32 = @bitCast(coeffs[1]);
        const a2: u32 = a1 +% @as(u32, @bitCast(coeffs[0]));
        coeffs[1] = @bitCast(a2);
        if (length > 2) {
            var a3: u32 = @bitCast(coeffs[2]);
            var a4: u32 = a3 +% a1;
            var a5: u32 = a4 +% a2;
            coeffs[2] = @bitCast(a5);
            var idx: usize = 3;
            var i: usize = 0;
            while (i < length - 3) : (i += 1) {
                a3 +%= @as(u32, @bitCast(coeffs[idx]));
                a4 +%= a3;
                a5 +%= a4;
                coeffs[idx] = @bitCast(a5);
                idx += 1;
            }
        }
    }
}

/// 帧解码上下文：每帧复用。跨帧只保留 <16 样本短帧路径所需的
/// lpc_mode/sample_shift 陈旧值语义（同 C），其余帧内状态逐帧覆写。
pub const Decoder = struct {
    a: std.mem.Allocator,
    channels: usize,
    bps: usize, // 每样本原始位（8/16/24）
    nb_samples: usize = 0,
    uval: usize = 0,
    subframe_scale: usize = 0,

    planes: [MAX_CHANNELS][]i32, // 每通道解码平面（长度 TAK_MAX_FRAME_SAMPLES）
    nb_subframes: usize = 0,
    dmode: u8 = 0,
    lpc_mode: [MAX_CHANNELS]i8 = undefined,
    sample_shift: [MAX_CHANNELS]i8 = undefined,
    predictors: [T.MAX_PREDICTORS]i16 = undefined,
    filter: [T.MAX_PREDICTORS]i16 = undefined,
    residues: [T.RESIDUES_RING]i16 = undefined,
    subframe_len: [T.MAX_SUBFRAMES]i32 = undefined,
    coding_mode: [128]u8 = undefined,
    mcdparams: [MAX_CHANNELS]McdParam = undefined,

    pub fn init(a: std.mem.Allocator) Error!Decoder {
        var planes: [MAX_CHANNELS][]i32 = undefined;
        for (0..MAX_CHANNELS) |c| {
            planes[c] = a.alloc(i32, T.TAK_MAX_FRAME_SAMPLES) catch return error.OutOfMemory;
        }
        return .{
            .a = a,
            .channels = 0,
            .bps = 0,
            .planes = planes,
        };
    }

    pub fn deinit(self: *Decoder) void {
        for (0..MAX_CHANNELS) |c| {
            self.a.free(self.planes[c]);
            self.planes[c] = &.{};
        }
    }

    /// set_sample_rate_params（takdec.c）
    pub fn setSampleRateParams(self: *Decoder, sample_rate: u32) void {
        const q: u32 = (sample_rate + 511) >> 9;
        const al: u32 = std.mem.alignForward(u32, q, 4);
        const shift: usize = if (sample_rate < 11025)
            3
        else if (sample_rate < 22050)
            2
        else if (sample_rate < 44100)
            1
        else
            0;
        self.uval = @as(usize, al) << @intCast(shift);
        self.subframe_scale = @as(usize, al) << 1;
    }

    // ---- decode_segment / decode_residues ----

    /// decode_segment（takdec.c）：Rice 分段写入 plane[start..start+len]。
    fn decodeSegment(br: *BitReader, plane: []i32, start: usize, mode: u8, len: usize) Error!void {
        if (mode == 0) {
            @memset(plane[start .. start + len], 0);
            return;
        }
        if (mode > T.xcodes.len) return error.Corrupt;
        const code = T.xcodes[mode - 1];

        for (0..len) |i| {
            var x: u32 = br.readBits(code.init);
            if (x >= code.escape and br.readBit() == 1) {
                x |= @as(u32, 1) << @intCast(code.init);
                if (x >= code.aescape) {
                    var scale: u32 = br.getUnaryStop1(9);
                    if (scale == 9) {
                        const sb0: u32 = br.readBits(3);
                        var sb = sb0;
                        if (sb > 0) {
                            if (sb == 7) {
                                sb += br.readBits(5);
                                if (sb > 29) return error.Corrupt;
                            }
                            scale = br.readBits(sb) + 1;
                            x +%= code.scale *% scale;
                        }
                        x +%= code.bias;
                    } else {
                        x +%= code.scale *% scale -% code.escape;
                    }
                } else {
                    x -%= code.escape;
                }
            }
            // (x >> 1) ^ -(x & 1)：u32 回绕域 zigzag → i32
            plane[start + i] = @bitCast((x >> 1) ^ (0 -% (x & 1)));
        }
    }

    /// decode_residues（takdec.c）
    fn decodeResidues(self: *Decoder, br: *BitReader, plane: []i32, start: usize, length: usize) Error!void {
        if (length > self.nb_samples) return error.Corrupt;

        var wlen: usize = undefined;
        var rval: usize = undefined;
        if (br.readBit() == 1) {
            wlen = length / self.uval;
            rval = length - (wlen * self.uval);

            if (rval < self.uval / 2)
                rval += self.uval
            else
                wlen += 1;

            if (wlen <= 1 or wlen > 128) return error.Corrupt;

            var mode: u32 = br.readBits(6);
            self.coding_mode[0] = @intCast(mode);
            for (1..wlen) |i| {
                const c = br.getUnaryStop1(6);
                switch (c) {
                    6 => mode = br.readBits(6),
                    5, 4, 3 => {
                        const sign: u32 = br.readBit();
                        // mode += (-sign ^ (c - 1)) + sign（u32 回绕）
                        mode +%= ((0 -% sign) ^ (c - 1)) +% sign;
                    },
                    2 => mode +%= 1,
                    1 => mode -%= 1,
                    else => {},
                }
                self.coding_mode[i] = @intCast(mode);
            }

            var i: usize = 0;
            var startp = start;
            while (i < wlen) {
                var seglen: usize = 0;
                const m: u8 = self.coding_mode[i];
                while (true) {
                    if (i >= wlen - 1)
                        seglen += rval
                    else
                        seglen += self.uval;
                    i += 1;
                    if (i == wlen) break;
                    if (self.coding_mode[i] != m) break;
                }
                try decodeSegment(br, plane, startp, m, seglen);
                startp += seglen;
            }
        } else {
            const mode: u8 = @intCast(br.readBits(6));
            try decodeSegment(br, plane, start, mode, length);
        }
    }

    // ---- decode_subframe ----

    /// decode_subframe（takdec.c）。plane 为整通道平面；start 为本子帧输出起点。
    /// 返回实际产出样本数（= subframe_size；前向延伸时额外覆写前子帧尾部）。
    fn decodeSubframe(
        self: *Decoder,
        br: *BitReader,
        plane: []i32,
        start: usize,
        subframe_size: usize,
        prev_subframe_size: usize,
    ) Error!void {
        var pos = start;
        var sfsize = subframe_size;
        var filter_order: usize = 0;

        if (br.readBit() == 0) {
            try self.decodeResidues(br, plane, pos, subframe_size);
            return;
        }

        filter_order = T.predictor_sizes[br.readBits(4)];

        if (prev_subframe_size > 0 and br.readBit() == 1) {
            if (filter_order > prev_subframe_size) return error.Corrupt;
            pos -= filter_order;
            sfsize += filter_order;
        } else {
            const lpc_mode: u32 = br.readBits(2);
            if (lpc_mode > 2) return error.Corrupt;
            try self.decodeResidues(br, plane, pos, filter_order);
            if (lpc_mode != 0) decodeLpc(plane[pos .. pos + filter_order], lpc_mode, filter_order);
        }

        const dshift: u32 = getBitsEsc4(br);
        const size: u32 = @as(u32, br.readBit()) + 6;
        const sizev: u32 = @intCast(size);
        var filter_quant: i32 = 10;
        if (br.readBit() == 1) {
            filter_quant -= @intCast(br.readBits(3) + 1);
            if (filter_quant < 3) return error.Corrupt;
        }
        if (br.bitsLeft() < @as(i64, 20) + 2 * @as(i64, sizev)) return error.Corrupt;

        var tfilter: [T.MAX_PREDICTORS]u32 = undefined;
        self.predictors[0] = @truncate(br.readSbits(10));
        self.predictors[1] = @truncate(br.readSbits(10));
        self.predictors[2] = @truncate(br.readSbits(sizev) * (@as(i32, 1) << @intCast(10 - sizev)));
        self.predictors[3] = @truncate(br.readSbits(sizev) * (@as(i32, 1) << @intCast(10 - sizev)));
        if (filter_order > 4) {
            const tmp: i32 = @as(i32, @intCast(sizev)) - @as(i32, br.readBit());
            var x: i32 = tmp;
            for (4..filter_order) |i| {
                if (i & 3 == 0) x = tmp - @as(i32, @intCast(br.readBits(2)));
                const nbits: u32 = @intCast(@max(x, 0));
                self.predictors[i] = @truncate(br.readSbits(nbits) * (@as(i32, 1) << @intCast(10 - sizev)));
            }
        }

        // 量化反射系数 → 滤波器抽头（tfilter 为 uint32 域）
        tfilter[0] = ext16(self.predictors[0]) *% 64;
        for (1..filter_order) |i| {
            const pc: u32 = ext16(self.predictors[i]);
            var p1: usize = 0;
            var p2: usize = i - 1;
            for (0..(i + 1) / 2) |_| {
                const av = tfilter[p1];
                const bv = tfilter[p2];
                const t1: u32 = pc *% bv +% 256;
                const t2: u32 = pc *% av +% 256;
                const xv: u32 = av +% @as(u32, @bitCast(@as(i32, @bitCast(t1)) >> 9));
                tfilter[p2] = bv +% @as(u32, @bitCast(@as(i32, @bitCast(t2)) >> 9));
                tfilter[p1] = xv;
                p1 += 1;
                p2 -%= 1;
            }
            tfilter[i] = pc *% 64;
        }

        const fq: u32 = @intCast(filter_quant);
        const base: i64 = @as(i64, 1) << @intCast(32 - (15 - @as(i32, @intCast(fq))));
        const half: i64 = @as(i64, 1) << @intCast((15 - @as(i32, @intCast(fq))) - 1);
        {
            var i: usize = 0;
            var j: usize = filter_order - 1;
            while (i < filter_order / 2) : ({
                i += 1;
                j -= 1;
            }) {
                const sh: u5 = @intCast(15 - fq);
                self.filter[j] = @truncate(base - ((@as(i64, tfilter[i]) + half) >> sh));
                self.filter[i] = @truncate(base - ((@as(i64, tfilter[j]) + half) >> sh));
            }
        }

        // 剩余残差 + 重建
        try self.decodeResidues(br, plane, pos + filter_order, sfsize - filter_order);

        for (0..filter_order) |k| {
            self.residues[k] = @truncate(plane[pos + k] >> @intCast(dshift));
        }

        const y: usize = T.RESIDUES_RING - filter_order;
        var xr: usize = sfsize - filter_order;
        var rpos: usize = pos + filter_order;
        const fq2: u5 = @intCast(filter_quant);
        while (xr > 0) {
            const tmp: usize = @min(y, xr);
            for (0..tmp) |k| {
                var v: u32 = @as(u32, 1) << @intCast(filter_quant - 1);
                const ord16: usize = filter_order & ~@as(usize, 15);
                if (ord16 != 0) {
                    v +%= scalarProductI16(self.residues[k .. k + ord16], self.filter[0..ord16]);
                }
                var jj: usize = ord16;
                while (jj < filter_order) : (jj += 4) {
                    v +%= mul16(self.residues[k + jj + 3], self.filter[jj + 3]);
                    v +%= mul16(self.residues[k + jj + 2], self.filter[jj + 2]);
                    v +%= mul16(self.residues[k + jj + 1], self.filter[jj + 1]);
                    v +%= mul16(self.residues[k + jj], self.filter[jj]);
                }
                // v(int) >> filter_quant 算术右移 → clip intp2 13 → << dshift → - 残差
                const vs: i32 = @as(i32, @bitCast(v)) >> @intCast(fq2);
                const clipped: i32 = clipIntp2(vs, 13);
                const prod: u32 = @as(u32, @bitCast(clipped)) << @intCast(dshift);
                const dv: u32 = @as(u32, @bitCast(plane[rpos]));
                const nv: u32 = prod -% dv;
                plane[rpos] = @bitCast(nv);
                self.residues[filter_order + k] = @truncate(@as(i32, @bitCast(nv)) >> @intCast(dshift));
                rpos += 1;
            }
            xr -= tmp;
            if (xr > 0) {
                var m: usize = 0;
                while (m < filter_order) : (m += 1) {
                    self.residues[m] = self.residues[y + m];
                }
            }
        }
    }

    // ---- decode_channel ----

    /// decode_channel（takdec.c）：解码第 chan 通道，平面 0..nb_samples-1。
    fn decodeChannel(self: *Decoder, br: *BitReader, chan: usize) Error!void {
        const plane = self.planes[chan];
        var pos: usize = 1;
        var left: i32 = @intCast(self.nb_samples - 1);
        var i: usize = 0;
        var prev: u32 = 0;

        const sh = getBitsEsc4(br);
        if (sh >= self.bps) return error.Corrupt;
        self.sample_shift[chan] = @intCast(sh);
        plane[0] = br.readSbits(@intCast(self.bps - sh));
        self.lpc_mode[chan] = @intCast(br.readBits(2));
        self.nb_subframes = br.readBits(3) + 1;

        if (self.nb_subframes > 1) {
            if (br.bitsLeft() < @as(i64, @intCast(self.nb_subframes - 1)) * 6) return error.Corrupt;
            while (i < self.nb_subframes - 1) : (i += 1) {
                const v = br.readBits(6);
                self.subframe_len[i] = @as(i32, @intCast(v -% prev)) * @as(i32, @intCast(self.subframe_scale));
                if (self.subframe_len[i] <= 0) return error.Corrupt;
                left -= self.subframe_len[i];
                prev = v;
            }
            if (left <= 0) return error.Corrupt;
        }
        self.subframe_len[i] = left;

        var prev_len: usize = 0;
        for (0..self.nb_subframes) |sf| {
            const len: usize = @intCast(self.subframe_len[sf]);
            try self.decodeSubframe(br, plane, pos, len, prev_len);
            pos += len;
            prev_len = len;
        }
    }

    // ---- decorrelate ----

    /// decorrelate（takdec.c）：对两平面已解码数据做联合去相关。
    fn decorrelate(self: *Decoder, br: *BitReader, c1: usize, c2: usize, length_in: usize) Error!void {
        const off: usize = if (self.dmode > 5) 1 else 0;
        const p1 = self.planes[c1];
        const p2 = self.planes[c2];
        const bp1: i32 = p1[off];
        const bp2: i32 = p2[off];
        const length: usize = length_in + @as(usize, if (self.dmode < 6) 1 else 0);

        switch (self.dmode) {
            1 => { // left/side：p2[i] = p1[i] + p2[i]
                for (0..length) |i| {
                    const a: u32 = @bitCast(p1[off + i]);
                    const b: u32 = @bitCast(p2[off + i]);
                    p2[off + i] = @bitCast(a +% b);
                }
            },
            2 => { // side/right：p1[i] = p2[i] - p1[i]
                for (0..length) |i| {
                    const a: u32 = @bitCast(p1[off + i]);
                    const b: u32 = @bitCast(p2[off + i]);
                    p1[off + i] = @bitCast(b -% a);
                }
            },
            3 => { // side/mid
                for (0..length) |i| {
                    var a: u32 = @bitCast(p1[off + i]);
                    const b: i32 = p2[off + i];
                    a -%= @as(u32, @bitCast(b >> 1));
                    p1[off + i] = @bitCast(a);
                    p2[off + i] = @bitCast(a +% @as(u32, @bitCast(b)));
                }
            },
            4, 5 => { // side/left(4) 或 side/right(5) 带缩放因子
                var pa = p1;
                var pb = p2;
                if (self.dmode == 4) {
                    const t = pa;
                    pa = pb;
                    pb = t;
                }
                const dshift: u32 = getBitsEsc4(br);
                const dfactor: i32 = br.readSbits(10);
                for (0..length) |i| {
                    const a: u32 = @bitCast(pa[off + i]);
                    const braw: i32 = pb[off + i];
                    const bs: u32 = @as(u32, @bitCast(braw)) >> @intCast(dshift);
                    const t: u32 = @as(u32, @bitCast(dfactor)) *% bs +% 128;
                    const ts: i32 = @as(i32, @bitCast(t)) >> 8;
                    const scaled: i32 = @bitCast(@as(u32, @bitCast(ts)) << @intCast(dshift));
                    pa[off + i] = @bitCast(@as(u32, @bitCast(scaled)) -% a);
                }
            },
            6, 7 => {
                var pa = p1;
                var pb = p2;
                if (self.dmode == 6) {
                    const t = pa;
                    pa = pb;
                    pb = t;
                }

                if (length < 256) return error.Corrupt;
                const dshift: u32 = getBitsEsc4(br);
                const filter_order: usize = @as(usize, 8) << @intCast(br.readBit());
                const dval1: u32 = br.readBit();
                const dval2: u32 = br.readBit();

                // C: `if(!(i&3)) code_size=14-get_bits(gb,3);`——code_size 为函数级
                // 变量，i%4!=0 时复用上一组的值（含跨组：i=5..7 沿用 i=4 读的值）。
                var code_size: u32 = 0;
                for (0..filter_order) |i| {
                    if (i & 3 == 0) code_size = 14 - br.readBits(3);
                    self.filter[i] = @truncate(br.readSbits(@intCast(code_size)));
                }

                const order_half: usize = filter_order / 2;
                const length2: usize = length - (filter_order - 1);

                if (dval1 != 0) {
                    for (0..order_half) |i| {
                        const a: u32 = @bitCast(pa[off + i]);
                        const b: u32 = @bitCast(pb[off + i]);
                        pa[off + i] = @bitCast(a +% b);
                    }
                }
                if (dval2 != 0) {
                    var ii: usize = length2 + order_half;
                    while (ii < length) : (ii += 1) {
                        const a: u32 = @bitCast(pa[off + ii]);
                        const b: u32 = @bitCast(pb[off + ii]);
                        pa[off + ii] = @bitCast(a +% b);
                    }
                }

                for (0..filter_order) |i| {
                    self.residues[i] = @truncate(pb[off + i] >> @intCast(dshift));
                }

                var pp: usize = filter_order;
                var outi: usize = order_half;
                var l2: usize = length2;
                while (l2 > 0) {
                    const tmp: usize = @min(l2, T.RESIDUES_RING - filter_order);
                    const readn: usize = tmp - @intFromBool(tmp == l2);
                    for (0..readn) |rn| {
                        self.residues[filter_order + rn] = @truncate(pb[off + pp] >> @intCast(dshift));
                        pp += 1;
                    }

                    for (0..tmp) |k| {
                        var v: u32 = @as(u32, 1) << 9;
                        if (filter_order == 16) {
                            v +%= scalarProductI16(self.residues[k .. k + 16], self.filter[0..16]);
                        } else {
                            v +%= mul16(self.residues[k + 7], self.filter[7]);
                            v +%= mul16(self.residues[k + 6], self.filter[6]);
                            v +%= mul16(self.residues[k + 5], self.filter[5]);
                            v +%= mul16(self.residues[k + 4], self.filter[4]);
                            v +%= mul16(self.residues[k + 3], self.filter[3]);
                            v +%= mul16(self.residues[k + 2], self.filter[2]);
                            v +%= mul16(self.residues[k + 1], self.filter[1]);
                            v +%= mul16(self.residues[k], self.filter[0]);
                        }
                        const vs: i32 = @as(i32, @bitCast(v)) >> 10;
                        const clipped: i32 = clipIntp2(vs, 13);
                        const prod: u32 = @as(u32, @bitCast(clipped)) << @intCast(dshift);
                        const dv: u32 = @as(u32, @bitCast(pa[off + outi]));
                        const nv: u32 = prod -% dv;
                        pa[off + outi] = @bitCast(nv);
                        // C 的 decorrelate 不会把重建样本写回 residues 环（仅 decode_subframe
                        // 的自动回归重建才写）；residues[filter_order+k] 保持块首读入的 pb 残差。
                        outi += 1;
                    }

                    l2 -= tmp;
                    if (l2 > 0) {
                        var m: usize = 0;
                        while (m < filter_order) : (m += 1) {
                            self.residues[m] = self.residues[tmp + m];
                        }
                    }
                }
            },
            else => {},
        }

        if (self.dmode > 0 and self.dmode < 6) {
            p1[off] = bp1;
            p2[off] = bp2;
        }
    }

    // ---- 整帧解码 ----

    /// 解码主体（tak_decode_frame 通道/输出段），交错写 out。
    pub fn decodeBody(
        self: *Decoder,
        br: *BitReader,
        si: *const StreamInfo,
        nb_samples: usize,
        out: []u8,
    ) Error!void {
        self.nb_samples = nb_samples;
        const channels: usize = @intCast(si.channels);
        const bps: usize = @intCast(si.bps);
        self.channels = channels;
        self.bps = bps;
        self.setSampleRateParams(si.sample_rate);

        const out_width: usize = if (bps == 8) 1 else if (bps == 16) 2 else 4;
        if (out.len < nb_samples * channels * out_width) return error.Corrupt;

        if (nb_samples < 16) {
            for (0..channels) |chan| {
                const plane = self.planes[chan];
                for (0..nb_samples) |i| {
                    plane[i] = br.readSbits(@intCast(bps));
                }
            }
        } else if (si.codec == T.TAK_CODEC_MONO_STEREO) {
            for (0..channels) |chan| {
                try self.decodeChannel(br, chan);
            }
            if (channels == 2) {
                self.nb_subframes = br.readBits(1) + 1;
                if (self.nb_subframes > 1) {
                    self.subframe_len[1] = @intCast(br.readBits(6));
                }
                self.dmode = @intCast(br.readBits(3));
                try self.decorrelate(br, 0, 1, nb_samples - 1);
            }
        } else if (si.codec == T.TAK_CODEC_MULTICHANNEL) {
            var npair: usize = 0;
            if (br.readBit() == 1) {
                var ch_mask: u32 = 0;
                const np0: usize = br.readBits(4) + 1;
                if (np0 > channels) return error.Corrupt;
                npair = np0;
                for (0..npair) |i| {
                    const nbit: usize = br.readBits(4);
                    if (nbit >= channels) return error.Corrupt;
                    if (ch_mask & (@as(u32, 1) << @intCast(nbit)) != 0) return error.Corrupt;
                    self.mcdparams[i].present = br.readBit() == 1;
                    if (self.mcdparams[i].present) {
                        self.mcdparams[i].index = @intCast(br.readBits(2));
                        self.mcdparams[i].chan2 = @intCast(br.readBits(4));
                        if (self.mcdparams[i].chan2 >= channels) return error.Corrupt;
                        if (self.mcdparams[i].index == 1) {
                            if (nbit == self.mcdparams[i].chan2 or
                                (ch_mask & (@as(u32, 1) << @intCast(self.mcdparams[i].chan2)) != 0))
                                return error.Corrupt;
                            ch_mask |= @as(u32, 1) << @intCast(self.mcdparams[i].chan2);
                        } else if (ch_mask & (@as(u32, 1) << @intCast(self.mcdparams[i].chan2)) == 0) {
                            return error.Corrupt;
                        }
                    }
                    self.mcdparams[i].chan1 = @intCast(nbit);
                    ch_mask |= @as(u32, 1) << @intCast(nbit);
                }
            } else {
                npair = channels;
                for (0..npair) |i| {
                    self.mcdparams[i].present = false;
                    self.mcdparams[i].chan1 = @intCast(i);
                }
            }

            for (0..npair) |i| {
                if (self.mcdparams[i].present and self.mcdparams[i].index == 1) {
                    try self.decodeChannel(br, self.mcdparams[i].chan2);
                }
                try self.decodeChannel(br, self.mcdparams[i].chan1);
                if (self.mcdparams[i].present) {
                    self.dmode = @intCast(T.mc_dmodes[self.mcdparams[i].index]);
                    try self.decorrelate(br, self.mcdparams[i].chan2, self.mcdparams[i].chan1, nb_samples - 1);
                }
            }
        } else {
            return error.UnsupportedFormat;
        }

        // 公共帧末：整通道差分积分 + 移位还原
        for (0..channels) |chan| {
            const plane = self.planes[chan];
            const lm: u8 = @intCast(self.lpc_mode[chan]);
            if (lm != 0) decodeLpc(plane[0..nb_samples], lm, nb_samples);
            const sh: u8 = @intCast(self.sample_shift[chan]);
            if (sh > 0) {
                const m: u32 = @as(u32, 1) << @intCast(sh);
                for (0..nb_samples) |i| {
                    plane[i] = @bitCast(@as(u32, @bitCast(plane[i])) *% m);
                }
            }
        }

        // 交错输出
        switch (out_width) {
            1 => {
                for (0..nb_samples) |i| {
                    for (0..channels) |c| {
                        const v: u32 = @as(u32, @bitCast(self.planes[c][i])) +% 0x80;
                        out[(i * channels + c)] = @truncate(v);
                    }
                }
            },
            2 => {
                for (0..nb_samples) |i| {
                    for (0..channels) |c| {
                        const v: i16 = @truncate(self.planes[c][i]);
                        std.mem.writeInt(i16, out[(i * channels + c) * 2 ..][0..2], v, .little);
                    }
                }
            },
            else => {
                for (0..nb_samples) |i| {
                    for (0..channels) |c| {
                        const v: i32 = self.planes[c][i] *% 256;
                        std.mem.writeInt(i32, out[(i * channels + c) * 4 ..][0..4], v, .little);
                    }
                }
            },
        }
    }
};
