// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! WMA Pro (wmapro) 解码核心——逐函数移植 FFmpeg libavcodec/wmaprodec.c
//! (n9.0.1) 的 WMAPRO 路径（不含 XMA）。bit reservoir / packet / frame /
//! subframe / 声道组 / DPCM+runlevel scale factors / 矢量+runlevel 谱系数 /
//! IMDCT（av_tx 位精确内核，见 mdct.zig）/ 窗重叠结构一致；解码为浮点（对齐
//! ffmpeg fltp）。量化步进用 ff_exp10(exp/20)（f64→f32 舍入），与系统 ffmpeg
//! f32 exp10 有末位差异，s16 输出非 100% bit-exact（报告见 wmapro/lib.zig）。
//!
//! 本文件不含容器解析。`Dec.decodePacket` 一次处理一个 WMA packet（通常
//! block_align 字节），由 lib.zig 按 ffmpeg decode core 喂包循环驱动：同一
//! avpkt 可能被多次 decodePacket 直到消费完毕；文件尾再喂一次空包触发 eof
//! flush 输出重叠尾。

const std = @import("std");
const Error = @import("../../../error.zig").Error;
const T = @import("tables.zig");
const wmdct = @import("mdct.zig");

pub const WMAPRO_MAX_CHANNELS: usize = 8;
const MAX_SUBFRAMES: usize = 32;
const MAX_BANDS: usize = 29;
const MAX_FRAMESIZE: usize = 32768;
const BLOCK_MIN_BITS: usize = 6;
const BLOCK_MAX_BITS: usize = 13;
const BLOCK_SIZES: usize = BLOCK_MAX_BITS - BLOCK_MIN_BITS + 1;

pub const FRAME_CAP: usize = 2048; // 支持帧长上限（spf≤2048）
const OUT_CAP: usize = FRAME_CAP * 2;
const CH_CAP: usize = WMAPRO_MAX_CHANNELS;

const FvalTab = [_]u32{
    0x00000000, 0x3f800000, 0x40000000, 0x40400000,
    0x40800000, 0x40a00000, 0x40c00000, 0x40e00000,
    0x41000000, 0x41100000, 0x41200000, 0x41300000,
    0x41400000, 0x41500000, 0x41600000, 0x41700000,
};

pub fn avLog2(v: usize) usize {
    if (v == 0) return 0;
    return @as(usize, 63) - @as(usize, @clz(v));
}

fn minV(a: usize, b: usize) usize {
    return if (a < b) a else b;
}

pub const Bits = struct {
    buf: []const u8,
    cap: usize,
    index: usize = 0,

    fn peek(self: *const Bits, n: usize) u32 {
        var val: u32 = 0;
        for (0..n) |bit| {
            const pos = self.index + bit;
            const byte = pos >> 3;
            const b: u32 = if (byte < self.buf.len) (self.buf[byte] >> @intCast(7 - (pos & 7))) & 1 else 0;
            val = (val << 1) | b;
        }
        return val;
    }
    pub fn get(self: *Bits, n: usize) u32 {
        const v = self.peek(n);
        self.index += n;
        return v;
    }
    pub fn get1(self: *Bits) u32 {
        return self.get(1);
    }
    fn bitsLeft(self: *const Bits) usize {
        return self.cap -% self.index;
    }
    fn count(self: *const Bits) usize {
        return self.index;
    }
    fn skip(self: *Bits, n: usize) void {
        self.index += n;
    }
};

const BitWriter = struct {
    buf: []u8,
    index: usize = 0,

    fn write(self: *BitWriter, n: usize, value: u32) void {
        const v = value;
        var i: usize = n;
        while (i > 0) {
            i -= 1;
            const bit: u32 = (v >> @intCast(i)) & 1;
            const byte = self.index >> 3;
            if (byte < self.buf.len) {
                const sh: u3 = @intCast(7 - (self.index & 7));
                self.buf[byte] |= @as(u8, @intCast(bit)) << sh;
            }
            self.index += 1;
        }
    }
    fn count(self: *const BitWriter) usize {
        return self.index;
    }
    fn left(self: *const BitWriter) usize {
        return self.buf.len * 8 - self.index;
    }
    fn reset(self: *BitWriter) void {
        self.index = 0;
        @memset(self.buf, 0);
    }
};

fn copyBits(dst: *BitWriter, src: []const u8, length: usize) void {
    if (length == 0) return;
    var words = length >> 4;
    const bits = length & 15;
    var i: usize = 0;
    while (words > 0) : (words -= 1) {
        const w = readBe16Pad(src, i * 2);
        dst.write(16, w);
        i += 1;
    }
    if (bits > 0) {
        const w = readBe16Pad(src, i * 2);
        dst.write(bits, w >> @intCast(16 - bits));
    }
}

/// BE16 读取，越过源尾按 0（对齐 ffmpeg AV_INPUT_BUFFER_PADDING 语义）
fn readBe16Pad(src: []const u8, off: usize) u32 {
    var b: [2]u8 = .{ 0, 0 };
    for (0..2) |k| {
        if (off + k < src.len) b[k] = src[off + k];
    }
    return @as(u32, b[0]) << 8 | @as(u32, b[1]);
}

// ---------------- canonical Huffman --------------------------------------

const VlcEntry = struct { sym: i32, bits: u16, code: u32 };

const Vlc = struct {
    entries: []const VlcEntry,
    maxbits: u16,
};

var vlc_store: [272 + 272 + 244 + 121 + 120 + 127 + 137 + 101 + 8]VlcEntry = undefined;

const VlcTables = struct {
    sf: Vlc,
    sf_rl: Vlc,
    vec4: Vlc,
    vec2: Vlc,
    vec1: Vlc,
    coef0: Vlc,
    coef1: Vlc,
};

fn lowerByBits(vl: Vlc, b: u16) usize {
    var lo: usize = 0;
    var hi: usize = vl.entries.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (vl.entries[mid].bits < b) lo = mid + 1 else hi = mid;
    }
    return lo;
}

inline fn getVlc(gb: *Bits, vl: Vlc) Error!i32 {
    var l: u16 = 1;
    while (l <= vl.maxbits) : (l += 1) {
        const lo0 = lowerByBits(vl, l);
        const hi0 = lowerByBits(vl, l + 1);
        if (lo0 == hi0) continue;
        const val = gb.peek(l);
        var lo = lo0;
        var hi = hi0;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (vl.entries[mid].code < val) lo = mid + 1 else hi = mid;
        }
        if (lo < hi0 and vl.entries[lo].code == val) {
            gb.index += l;
            return vl.entries[lo].sym;
        }
    }
    return error.Corrupt;
}

fn buildVlc(comptime count: usize, comptime lenf: fn (usize) u8, comptime symf: fn (usize) i32, comptime offset: i32, work: []VlcEntry) Vlc {
    var code: u64 = 0;
    var n: usize = 0;
    var maxb: u16 = 0;
    for (0..count) |i| {
        const len = lenf(i);
        if (len == 0) continue;
        work[n] = .{ .sym = symf(i) + offset, .bits = len, .code = @truncate(code >> @intCast(32 - len)) };
        code += @as(u64, 1) << @intCast(32 - len);
        if (len > maxb) maxb = len;
        n += 1;
    }
    const list = work[0..n];
    std.mem.sort(VlcEntry, list, {}, struct {
        fn lt(_: void, a: VlcEntry, b: VlcEntry) bool {
            if (a.bits != b.bits) return a.bits < b.bits;
            return a.code < b.code;
        }
    }.lt);
    return .{ .entries = list, .maxbits = maxb };
}

pub fn initVlc() VlcTables {
    const Ls = struct {
        fn len(i: usize) u8 {
            return T.scale_table[i * 2 + 1];
        }
        fn sym(i: usize) i32 {
            return T.scale_table[i * 2];
        }
    };
    const Lr = struct {
        fn len(i: usize) u8 {
            return T.scale_rl_table[i * 2 + 1];
        }
        fn sym(i: usize) i32 {
            return T.scale_rl_table[i * 2];
        }
    };
    const Lv4 = struct {
        fn len(i: usize) u8 {
            return T.vec4_lens[i];
        }
        fn sym(i: usize) i32 {
            return T.vec4_syms[i];
        }
    };
    const Lv2 = struct {
        fn len(i: usize) u8 {
            return T.vec2_table[i * 2 + 1];
        }
        fn sym(i: usize) i32 {
            return T.vec2_table[i * 2];
        }
    };
    const Lv1 = struct {
        fn len(i: usize) u8 {
            return T.vec1_table[i * 2 + 1];
        }
        fn sym(i: usize) i32 {
            return T.vec1_table[i * 2];
        }
    };
    const Lc0 = struct {
        fn len(i: usize) u8 {
            return T.coef0_lens[i];
        }
        fn sym(i: usize) i32 {
            return T.coef0_syms[i];
        }
    };
    const Lc1 = struct {
        fn len(i: usize) u8 {
            return T.coef1_table[i * 2 + 1];
        }
        fn sym(i: usize) i32 {
            return T.coef1_table[i * 2];
        }
    };
    var w = &vlc_store;
    return .{
        .sf = buildVlc(121, Ls.len, Ls.sym, -60, w[0..121]),
        .sf_rl = buildVlc(120, Lr.len, Lr.sym, 0, w[121..241]),
        .vec4 = buildVlc(127, Lv4.len, Lv4.sym, -1, w[241..368]),
        .vec2 = buildVlc(137, Lv2.len, Lv2.sym, -1, w[368..505]),
        .vec1 = buildVlc(101, Lv1.len, Lv1.sym, 0, w[505..606]),
        .coef0 = buildVlc(272, Lc0.len, Lc0.sym, 0, w[606..878]),
        .coef1 = buildVlc(244, Lc1.len, Lc1.sym, 0, w[878..1122]),
    };
}

// ---------------- 上下文 ------------------------------------------------

const ScaleBuf = [MAX_BANDS]i32;

pub const ChannelCtx = struct {
    prev_block_len: usize = 0,
    transmit_coefs: bool = false,
    num_subframes: usize = 0,
    subframe_len: [MAX_SUBFRAMES]usize = .{0} ** MAX_SUBFRAMES,
    subframe_offset: [MAX_SUBFRAMES]usize = .{0} ** MAX_SUBFRAMES,
    cur_subframe: usize = 0,
    decoded_samples: usize = 0,
    grouped: bool = false,
    quant_step: i32 = 0,
    reuse_sf: bool = false,
    scale_factor_step: i32 = 0,
    max_scale_factor: i32 = 0,
    saved_scale_factors: [2]ScaleBuf = .{.{0} ** MAX_BANDS} ** 2,
    scale_factor_idx: usize = 0,
    /// 当前量化使用的 scale factor 缓冲（= 本 subframe 的 chan.scale_factors）
    cur_scale: usize = 0,
    table_idx: usize = 0,
    /// 当前 subframe 谱系数区相对 out 的偏移
    coeff_off: usize = 0,
    num_vec_coeffs: usize = 0,
    out: [OUT_CAP]f32 = undefined,
};

pub const ChanGroup = struct {
    num_channels: usize = 0,
    transform: bool = false,
    transform_band: [MAX_BANDS]bool = .{false} ** MAX_BANDS,
    decorrelation_matrix: [CH_CAP * CH_CAP]f32 = .{0} ** (CH_CAP * CH_CAP),
    /// 组内声道序号（decode_coeffs 等按此访问各自 out）
    channel_data: [CH_CAP]usize = .{0} ** CH_CAP,
};

pub const Params = struct {
    sample_rate: u32,
    bits_per_sample: u16,
    channels: u8,
    channel_mask: u32,
    decode_flags: u16,
    block_align: usize,
};

const FRAME_CAP_BITS = avLog2(FRAME_CAP); // 11

pub const Dec = struct {
    p: Params,
    channels: usize,
    vlc: VlcTables,

    len_prefix: bool = false,
    dynamic_range_compression: bool = false,
    samples_per_frame: usize = 0,
    log2_frame_size: usize = 0,
    lfe_channel: i32 = -1,
    max_num_subframes: usize = 0,
    subframe_len_bits: usize = 0,
    max_subframe_len_bit: bool = false,
    min_samples_per_subframe: usize = 0,
    num_possible_block_sizes: usize = 0,

    num_sfb: [BLOCK_SIZES]i32 = .{0} ** BLOCK_SIZES,
    sfb_offsets: [BLOCK_SIZES][MAX_BANDS]u16 = .{.{0} ** MAX_BANDS} ** BLOCK_SIZES,
    sf_offsets: [BLOCK_SIZES][BLOCK_SIZES][MAX_BANDS]u8 = .{.{.{0} ** MAX_BANDS} ** BLOCK_SIZES} ** BLOCK_SIZES,
    subwoofer_cutoffs: [BLOCK_SIZES]usize = .{0} ** BLOCK_SIZES,

    window_storage: [FRAME_CAP * 2]f32 = undefined,
    win_slices: [BLOCK_SIZES][]const f32 = .{&.{}} ** BLOCK_SIZES,
    sin64: [33]f32 = undefined,

    // packet 状态
    next_packet_start: usize = 0,
    packet_offset: usize = 0,
    packet_sequence_number: usize = 0,
    num_saved_bits: usize = 0,
    frame_offset: usize = 0,
    packet_loss: bool = true,
    packet_done: bool = false,
    eof_done: bool = false,
    skip_frame: bool = true,
    frame_num: usize = 0,
    frame_data: [MAX_FRAMESIZE + 64]u8 = undefined,
    pb: BitWriter = undefined,
    gb: Bits = undefined,
    pgb: Bits = undefined,
    buf_bit_size: usize = 0,

    // frame 解码状态
    drc_gain: usize = 0,
    parsed_all_subframes: bool = false,
    trim_start: usize = 0,
    trim_end: usize = 0,

    // subframe 状态
    subframe_len: usize = 0,
    channels_for_cur_subframe: usize = 0,
    channel_indexes_for_cur_subframe: [CH_CAP]usize = .{0} ** CH_CAP,
    num_bands: usize = 0,
    transmit_num_vec_coeffs: bool = false,
    cur_sfb_offsets: []const u16 = &.{},
    table_idx: usize = 0,
    esc_len: usize = 0,
    cur_subwoofer_cutoff: usize = 0,
    num_chgroups: usize = 0,
    chgroup: [CH_CAP]ChanGroup = @splat(ChanGroup{}),
    channel: [CH_CAP]ChannelCtx = @splat(ChannelCtx{}),
    tmp: [FRAME_CAP * 2]f32 = undefined,
    mdct_scratch: [FRAME_CAP]wmdct.Cplx = undefined,

    /// 输出帧平面（帧样本在左移前先拷出）
    planes: [CH_CAP][FRAME_CAP]f32 = undefined,
    frame_pending: bool = false,
    frame_out_len: usize = 0,
    frame_out_start: usize = 0,

    coef_tab_idx: usize = 0,

    pub fn init(self: *Dec, p: Params) Error!void {
        if (p.channels == 0 or p.channels > CH_CAP) return error.UnsupportedFormat;
        if (p.block_align == 0) return error.Corrupt;
        const flags = p.decode_flags;
        self.* = .{
            .p = p,
            .channels = p.channels,
            .vlc = initVlc(),
            .log2_frame_size = avLog2(p.block_align) + 4,
        };
        const d = self;
        if (d.log2_frame_size > 25) return error.UnsupportedFormat;
        d.len_prefix = (flags & 0x40) != 0;
        d.dynamic_range_compression = (flags & 0x80) != 0;

        const bits = ffWmaGetFrameLenBits(p.sample_rate, 3, flags);
        if (bits > FRAME_CAP_BITS) return error.UnsupportedFormat; // mdct 表仅到 2048
        d.samples_per_frame = @as(usize, 1) << @as(u6, @intCast(bits));

        const l2max = (flags & 0x38) >> 3;
        d.max_num_subframes = @as(usize, 1) << @as(u6, @intCast(l2max));
        if (d.max_num_subframes == 16 or d.max_num_subframes == 4) d.max_subframe_len_bit = true;
        d.subframe_len_bits = avLog2(l2max) + 1;
        d.num_possible_block_sizes = l2max + 1;
        d.min_samples_per_subframe = d.samples_per_frame / d.max_num_subframes;
        if (d.max_num_subframes > MAX_SUBFRAMES) return error.Corrupt;
        if (d.min_samples_per_subframe < (1 << BLOCK_MIN_BITS)) return error.Corrupt;

        for (0..d.channels) |i| d.channel[i].prev_block_len = d.samples_per_frame;

        if (p.channel_mask & 8 != 0) {
            var mask: u32 = 1;
            var idx: i32 = -1;
            while (mask < 16) : (mask <<= 1) {
                if (p.channel_mask & mask != 0) idx += 1;
            }
            d.lfe_channel = idx;
        }

        const rate = getRate(p.sample_rate);
        for (0..d.num_possible_block_sizes) |i| {
            const sub_len: i32 = @intCast(d.samples_per_frame >> @as(u6, @intCast(i)));
            var band: usize = 1;
            d.sfb_offsets[i][0] = 0;
            var x: usize = 0;
            while (x < MAX_BANDS - 1 and d.sfb_offsets[i][band - 1] < sub_len) : (x += 1) {
                var offset: i32 = @divTrunc(sub_len * 2 * @as(i32, T.critical_freq[x]), @as(i32, @intCast(rate))) + 2;
                offset &= ~@as(i32, 3);
                if (offset > d.sfb_offsets[i][band - 1]) {
                    d.sfb_offsets[i][band] = @intCast(offset);
                    band += 1;
                }
                if (offset >= sub_len) break;
            }
            d.sfb_offsets[i][band - 1] = @intCast(sub_len);
            d.num_sfb[i] = @intCast(band - 1);
            if (d.num_sfb[i] <= 0) return error.Corrupt;
        }

        for (0..d.num_possible_block_sizes) |i| {
            for (0..@as(usize, @intCast(d.num_sfb[i]))) |b| {
                const offset = ((@as(usize, d.sfb_offsets[i][b]) + @as(usize, d.sfb_offsets[i][b + 1]) - 1) << @as(u6, @intCast(i))) >> 1;
                for (0..d.num_possible_block_sizes) |x| {
                    var v: usize = 0;
                    while ((d.sfb_offsets[x][v + 1] << @intCast(x)) < offset) : (v += 1) {
                        if (v >= MAX_BANDS) return error.Corrupt;
                    }
                    d.sf_offsets[i][x][b] = @intCast(v);
                }
            }
        }

        for (0..d.num_possible_block_sizes) |i| {
            const block_size: i64 = @intCast(d.samples_per_frame >> @as(u6, @intCast(i)));
            const cutoff: i64 = @divTrunc(440 * block_size + 3 * @as(i64, p.sample_rate >> 1) - 1, @as(i64, p.sample_rate));
            var c: i64 = cutoff;
            const bs: i64 = block_size;
            if (c > bs) c = bs;
            if (c < 4) c = 4;
            d.subwoofer_cutoffs[i] = @intCast(c);
        }

        // 正弦窗：长度 n=2^b（b=6..log2 spf）窗长 n（=子块长），w[i]=sin((i+.5)π/(2n))
        // 各长度连续存放（cumulative 偏移），避免互相覆盖
        const maxw = d.samples_per_frame;
        var n: usize = 1 << BLOCK_MIN_BITS;
        var bi: usize = 0;
        var winbase: usize = 0;
        while (n <= maxw) : ({
            winbase += n;
            bi += 1;
            n <<= 1;
        }) {
            for (0..n) |i| {
                const argf: f32 = @as(f32, @floatFromInt(i)) + 0.5;
                const ar = argf * (@as(f32, std.math.pi) / @as(f32, @floatFromInt(2 * n)));
                d.window_storage[winbase + i] = @sin(ar);
            }
            d.win_slices[bi] = d.window_storage[winbase .. winbase + n];
        }

        // sin64（decorrelation 旋转查表：sin(i·π/64)）
        for (0..33) |i| {
            d.sin64[i] = @floatCast(@sin(@as(f64, @floatFromInt(i)) * std.math.pi / 64.0));
        }
        d.resetState();
    }

    pub fn resetState(self: *Dec) void {
        self.packet_offset = 0;
        self.packet_sequence_number = 0;
        self.num_saved_bits = 0;
        self.frame_offset = 0;
        self.packet_loss = true;
        self.packet_done = false;
        self.eof_done = false;
        self.skip_frame = true;
        self.frame_num = 0;
        self.frame_pending = false;
        self.pb = .{ .buf = self.frame_data[0 .. MAX_FRAMESIZE + 64] };
        self.pb.reset();
        self.gb = .{ .buf = self.frame_data[0 .. MAX_FRAMESIZE + 64], .cap = 0 };
        for (0..self.channels) |i| {
            self.channel[i].prev_block_len = self.samples_per_frame;
            @memset(self.channel[i].out[0..self.samples_per_frame], 0);
        }
    }

    // ---------------- 工具 ---------------
    fn windowOf(self: *Dec, winlen: usize) []const f32 {
        return self.win_slices[avLog2(winlen) - BLOCK_MIN_BITS];
    }

    fn coefRun(self: *Dec, code: usize) usize {
        return if (self.coef_tab_idx == 0) T.coef0_run[code] else T.coef1_run[code];
    }
    fn coefLevelU32(self: *Dec, code: usize) u32 {
        const lv: f32 = if (self.coef_tab_idx == 0) T.coef0_level[code] else T.coef1_level[code];
        return @bitCast(lv);
    }

    fn getLargeVal(self: *Dec) u32 {
        var n_bits: usize = 8;
        if (self.gb.get1() != 0) {
            n_bits += 8;
            if (self.gb.get1() != 0) {
                n_bits += 8;
                if (self.gb.get1() != 0) n_bits += 7;
            }
        }
        return self.gb.get(n_bits);
    }

    /// ff_exp10(x) = exp2(M_LOG2_10·x)（对齐 ffmpeg ffmath.h，f64 转 f32）
    fn ffExp10(self: *Dec, x: f64) f32 {
        _ = self;
        const m_log2_10 = 3.321928094887362347870319429489390175864831393024580612054756395; // log2(10)
        return @floatCast(std.math.exp2(m_log2_10 * x));
    }

    // ---- 子帧长度 / tile ----
    fn decodeSubframeLength(self: *Dec, offset: usize) Error!usize {
        if (offset == self.samples_per_frame - self.min_samples_per_subframe)
            return self.min_samples_per_subframe;

        if (self.gb.bitsLeft() < 1) return error.Corrupt;

        var frame_len_shift: usize = 0;
        if (self.max_subframe_len_bit) {
            if (self.gb.get1() != 0) {
                frame_len_shift = 1 + @as(usize, self.gb.get(self.subframe_len_bits - 1));
            }
        } else {
            frame_len_shift = @as(usize, self.gb.get(self.subframe_len_bits));
        }
        const subframe_len = self.samples_per_frame >> @as(u6, @intCast(frame_len_shift));
        if (subframe_len < self.min_samples_per_subframe or subframe_len > self.samples_per_frame)
            return error.Corrupt;
        return subframe_len;
    }

    fn decodeTilehdr(self: *Dec) Error!void {
        var num_samples: [CH_CAP]usize = .{0} ** CH_CAP;
        var contains_subframe: [CH_CAP]bool = .{false} ** CH_CAP;
        var channels_for_cur_subframe: usize = self.channels;
        var fixed_channel_layout = false;
        var min_channel_len: usize = 0;
        const ch = self.channels;

        for (0..ch) |c| self.channel[c].num_subframes = 0;

        if (self.max_num_subframes == 1 or self.gb.get1() != 0) fixed_channel_layout = true;

        var guard: usize = 0;
        while (min_channel_len < self.samples_per_frame) : (guard += 1) {
            if (guard > 4000) return error.Corrupt;
            for (0..ch) |c| {
                if (num_samples[c] == min_channel_len) {
                    if (fixed_channel_layout or channels_for_cur_subframe == 1 or
                        min_channel_len == self.samples_per_frame - self.min_samples_per_subframe)
                    {
                        contains_subframe[c] = true;
                    } else {
                        contains_subframe[c] = self.gb.get1() != 0;
                    }
                } else {
                    contains_subframe[c] = false;
                }
            }

            const subframe_len = try self.decodeSubframeLength(min_channel_len);

            min_channel_len += subframe_len;
            for (0..ch) |c| {
                const chan = &self.channel[c];
                if (contains_subframe[c]) {
                    if (chan.num_subframes >= MAX_SUBFRAMES) return error.Corrupt;
                    chan.subframe_len[chan.num_subframes] = subframe_len;
                    num_samples[c] += subframe_len;
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
        }

        for (0..ch) |c| {
            var offset: usize = 0;
            for (0..self.channel[c].num_subframes) |i| {
                self.channel[c].subframe_offset[i] = offset;
                offset += self.channel[c].subframe_len[i];
            }
        }
    }

    // ---- 声道变换 ----
    fn decodeDecorrelationMatrix(self: *Dec, g: *ChanGroup) void {
        const n = g.num_channels;
        var rotation_offset: [CH_CAP * CH_CAP]u8 = .{0} ** (CH_CAP * CH_CAP);
        @memset(g.decorrelation_matrix[0 .. n * n], 0);
        var i: usize = 0;
        while (i < (n * (n - 1)) >> 1) : (i += 1) {
            rotation_offset[i] = @intCast(self.gb.get(6));
        }
        for (0..n) |ii| {
            g.decorrelation_matrix[n * ii + ii] = if (self.gb.get1() != 0) 1.0 else -1.0;
        }
        var ii: usize = 1;
        var offset: usize = 0;
        while (ii < n) : (ii += 1) {
            var x: usize = 0;
            while (x < ii) : (x += 1) {
                const ro: usize = rotation_offset[offset + x];
                const idx: usize = if (ro < 32) ro else 64 - ro;
                const sn = self.sin64[idx];
                const cs: f32 = if (ro < 32)
                    self.sin64[32 - ro]
                else
                    -self.sin64[ro - 32];
                var y: usize = 0;
                while (y < ii + 1) : (y += 1) {
                    const v1 = g.decorrelation_matrix[x * n + y];
                    const v2 = g.decorrelation_matrix[ii * n + y];
                    g.decorrelation_matrix[y + x * n] = (v1 * sn) - (v2 * cs);
                    g.decorrelation_matrix[y + ii * n] = (v1 * cs) + (v2 * sn);
                }
            }
            offset += ii;
        }
    }

    fn decodeChannelTransform(self: *Dec) Error!void {
        self.num_chgroups = 0;
        if (self.channels > 1) {
            var remaining_channels: i32 = @intCast(self.channels_for_cur_subframe);
            if (self.gb.get1() != 0) return error.UnsupportedFormat;

            while (remaining_channels != 0 and self.num_chgroups < self.channels_for_cur_subframe) {
                const g = &self.chgroup[self.num_chgroups];
                g.num_channels = 0;
                g.transform = false;
                var cidx: usize = 0;
                if (remaining_channels > 2) {
                    for (0..self.channels_for_cur_subframe) |j| {
                        const c = self.channel_indexes_for_cur_subframe[j];
                        if (!self.channel[c].grouped and self.gb.get1() != 0) {
                            g.channel_data[g.num_channels] = c;
                            g.num_channels += 1;
                            self.channel[c].grouped = true;
                        }
                    }
                } else {
                    g.num_channels = @intCast(remaining_channels);
                    for (0..self.channels_for_cur_subframe) |j| {
                        const c = self.channel_indexes_for_cur_subframe[j];
                        if (!self.channel[c].grouped) {
                            g.channel_data[cidx] = c;
                            cidx += 1;
                        }
                        self.channel[c].grouped = true;
                    }
                }

                if (g.num_channels == 2) {
                    if (self.gb.get1() != 0) {
                        if (self.gb.get1() != 0) return error.UnsupportedFormat;
                    } else {
                        g.transform = true;
                        if (self.channels == 2) {
                            g.decorrelation_matrix[0] = 1.0;
                            g.decorrelation_matrix[1] = -1.0;
                            g.decorrelation_matrix[2] = 1.0;
                            g.decorrelation_matrix[3] = 1.0;
                        } else {
                            g.decorrelation_matrix[0] = 0.70703125;
                            g.decorrelation_matrix[1] = -0.70703125;
                            g.decorrelation_matrix[2] = 0.70703125;
                            g.decorrelation_matrix[3] = 0.70703125;
                        }
                    }
                } else if (g.num_channels > 2) {
                    if (self.gb.get1() != 0) {
                        g.transform = true;
                        if (self.gb.get1() != 0) {
                            self.decodeDecorrelationMatrix(g);
                        } else {
                            if (g.num_channels > 6) return error.UnsupportedFormat;
                            const off = T.decorr_off[g.num_channels];
                            for (0..g.num_channels * g.num_channels) |k| {
                                g.decorrelation_matrix[k] = @floatCast(T.decorr_flat[off + k]);
                            }
                        }
                    }
                }

                if (g.transform) {
                    if (self.gb.get1() == 0) {
                        for (0..self.num_bands) |bi| {
                            g.transform_band[bi] = self.gb.get1() != 0;
                        }
                    } else {
                        @memset(g.transform_band[0..self.num_bands], true);
                    }
                }
                remaining_channels -= @intCast(g.num_channels);
                self.num_chgroups += 1;
            }
        }
    }

    // ---- 谱系数 ----
    fn runLevelDecode(self: *Dec, vlc: Vlc, c: usize, offset0: usize, num_coefs: usize) Error!void {
        const ch = &self.channel[c];
        const coef_mask = self.subframe_len - 1;
        var offset: usize = offset0;
        while (offset < num_coefs) : (offset += 1) {
            const code = try getVlc(&self.gb, vlc);
            if (code > 1) {
                const u: usize = @intCast(code);
                offset += self.coefRun(u);
                const sign: u32 = self.gb.get1() -% 1;
                const bits = self.coefLevelU32(u) ^ (sign & 0x80000000);
                ch.out[ch.coeff_off + (offset & coef_mask)] = @bitCast(bits);
            } else if (code == 1) {
                break;
            } else {
                const level: i32 = @bitCast(self.getLargeVal());
                if (self.gb.get1() != 0) {
                    if (self.gb.get1() != 0) {
                        if (self.gb.get1() != 0) return error.Corrupt;
                        offset += @as(usize, self.gb.get(self.esc_len)) + 4;
                    } else {
                        offset += @as(usize, self.gb.get(2)) + 1;
                    }
                }
                const sign: i32 = @bitCast(self.gb.get1() -% 1);
                const v: i32 = (level ^ sign) - sign;
                ch.out[ch.coeff_off + (offset & coef_mask)] = @floatFromInt(v);
            }
        }
        if (offset > num_coefs) return error.Corrupt;
    }

    fn decodeCoeffs(self: *Dec, c: usize) Error!void {
        const ci = &self.channel[c];
        const sub_len = self.subframe_len;
        const vlctable = self.gb.get1();
        const vlc: Vlc = if (vlctable != 0) self.vlc.coef1 else self.vlc.coef0;
        self.coef_tab_idx = if (vlctable != 0) 1 else 0;

        var rl_mode = false;
        var cur_coeff: usize = 0;
        var num_zeros: usize = 0;
        const transmit = self.transmit_num_vec_coeffs;

        while ((transmit or !rl_mode) and (cur_coeff + 3 < ci.num_vec_coeffs)) {
            var vals: [4]u32 = undefined;
            var idx = getVlc(&self.gb, self.vlc.vec4) catch return error.Corrupt;
            if (idx < 0) {
                var i: usize = 0;
                while (i < 4) : (i += 2) {
                    idx = getVlc(&self.gb, self.vlc.vec2) catch return error.Corrupt;
                    if (idx < 0) {
                        var v0: u32 = @intCast(getVlc(&self.gb, self.vlc.vec1) catch return error.Corrupt);
                        if (v0 == T.vec1_n - 1) v0 += self.getLargeVal();
                        var v1: u32 = @intCast(getVlc(&self.gb, self.vlc.vec1) catch return error.Corrupt);
                        if (v1 == T.vec1_n - 1) v1 += self.getLargeVal();
                        vals[i] = @bitCast(@as(f32, @floatFromInt(v0)));
                        vals[i + 1] = @bitCast(@as(f32, @floatFromInt(v1)));
                    } else {
                        const u: u32 = @intCast(idx);
                        vals[i] = FvalTab[u >> 4];
                        vals[i + 1] = FvalTab[u & 0xF];
                    }
                }
            } else {
                const u: u32 = @intCast(idx);
                vals[0] = FvalTab[u >> 12];
                vals[1] = FvalTab[(u >> 8) & 0xF];
                vals[2] = FvalTab[(u >> 4) & 0xF];
                vals[3] = FvalTab[u & 0xF];
            }

            for (0..4) |k| {
                if (vals[k] != 0) {
                    const sign: u32 = self.gb.get1() -% 1;
                    const bts = vals[k] ^ (sign << 31);
                    ci.out[ci.coeff_off + cur_coeff] = @bitCast(bts);
                    num_zeros = 0;
                } else {
                    ci.out[ci.coeff_off + cur_coeff] = 0;
                    num_zeros += 1;
                    if (num_zeros > sub_len >> 8) rl_mode = true;
                }
                cur_coeff += 1;
            }
        }

        if (cur_coeff < sub_len) {
            for (cur_coeff..sub_len) |i| ci.out[ci.coeff_off + i] = 0;
            try self.runLevelDecode(vlc, c, cur_coeff, sub_len);
        }
    }

    // ---- scale factors ----
    fn decodeScaleFactors(self: *Dec) Error!void {
        for (0..self.channels_for_cur_subframe) |i| {
            const c = self.channel_indexes_for_cur_subframe[i];
            const ch = &self.channel[c];
            const target = 1 - ch.scale_factor_idx;
            const src = ch.scale_factor_idx;

            if (ch.reuse_sf) {
                const sfo = &self.sf_offsets[self.table_idx][ch.table_idx];
                for (0..self.num_bands) |b| {
                    ch.saved_scale_factors[target][b] = ch.saved_scale_factors[src][sfo[b]];
                }
            }

            if (ch.cur_subframe == 0 or self.gb.get1() != 0) {
                if (!ch.reuse_sf) {
                    ch.scale_factor_step = @as(i32, @intCast(self.gb.get(2))) + 1;
                    var val: i32 = @divTrunc(@as(i32, 45), ch.scale_factor_step);
                    for (0..self.num_bands) |b| {
                        val += getVlc(&self.gb, self.vlc.sf) catch return error.Corrupt;
                        ch.saved_scale_factors[target][b] = val;
                    }
                } else {
                    var k: usize = 0;
                    while (k < self.num_bands) : (k += 1) {
                        const idx = getVlc(&self.gb, self.vlc.sf_rl) catch return error.Corrupt;
                        var val: i32 = 0;
                        var skip: usize = 0;
                        var sign: i32 = 0;
                        if (idx == 0) {
                            const code = self.gb.get(14);
                            val = @intCast(code >> 6);
                            sign = @as(i32, @bitCast(@as(u32, code & 1))) - 1;
                            skip = @as(usize, (code & 0x3f) >> 1);
                        } else if (idx == 1) {
                            break;
                        } else {
                            const u: usize = @intCast(idx);
                            skip = T.scale_rl_run[u];
                            val = T.scale_rl_level[u];
                            sign = @as(i32, @intCast(self.gb.get1())) - 1;
                        }
                        k += skip;
                        if (k >= self.num_bands) return error.Corrupt;
                        ch.saved_scale_factors[target][k] += (val ^ sign) - sign;
                    }
                }
                ch.scale_factor_idx = target;
                ch.table_idx = self.table_idx;
                ch.reuse_sf = true;
            }

            ch.cur_scale = target;
            var mf = ch.saved_scale_factors[target][0];
            for (1..self.num_bands) |b| {
                if (ch.saved_scale_factors[target][b] > mf) mf = ch.saved_scale_factors[target][b];
            }
            ch.max_scale_factor = mf;
        }
    }

    // ---- 逆声道变换 ----
    fn inverseChannelTransform(self: *Dec) void {
        for (0..self.num_chgroups) |gi| {
            const g = &self.chgroup[gi];
            if (g.transform) {
                const nc = g.num_channels;
                var sfb: usize = 0;
                while (sfb < self.num_bands) : (sfb += 1) {
                    if (g.transform_band[sfb]) {
                        const start = self.cur_sfb_offsets[sfb];
                        const end = minV(self.cur_sfb_offsets[sfb + 1], self.subframe_len);
                        var y = start;
                        while (y < end) : (y += 1) {
                            var data: [CH_CAP]f32 = undefined;
                            for (0..nc) |k| {
                                const cc = g.channel_data[k];
                                data[k] = self.channel[cc].out[self.channel[cc].coeff_off + y];
                            }
                            for (0..nc) |k| {
                                var sum: f32 = 0;
                                for (0..nc) |m| {
                                    sum += data[m] * g.decorrelation_matrix[k * nc + m];
                                }
                                const cc = g.channel_data[k];
                                self.channel[cc].out[self.channel[cc].coeff_off + y] = sum;
                            }
                        }
                    } else if (self.channels == 2) {
                        const start = self.cur_sfb_offsets[sfb];
                        const end = minV(self.cur_sfb_offsets[sfb + 1], self.subframe_len);
                        const mul: f32 = 181.0 / 128.0;
                        for (0..2) |k| {
                            const cc = g.channel_data[k];
                            const co = self.channel[cc].coeff_off;
                            for (start..end) |y| {
                                self.channel[cc].out[co + y] = self.channel[cc].out[co + y] * mul;
                            }
                        }
                    }
                }
            }
        }
    }

    // ---- 窗/重叠 ----
    fn vecFmulWindow(self: *Dec, c: usize, start: i64, len: usize, window: []const f32) void {
        const dst = &self.channel[c].out;
        const sstart: i64 = start;
        const slen: i64 = @intCast(len);
        for (0..len) |u| {
            // FFmpeg：for (i=-len, j=len-1; i<0; i++, j--)
            const i: i64 = @as(i64, @intCast(u)) - slen;
            const j: i64 = slen - 1 - @as(i64, @intCast(u)); // len-1..0
            const aA: usize = @intCast(sstart + slen + i);
            const aB: usize = @intCast(sstart + slen + j);
            const s0 = dst[aA];
            const s1 = dst[aB];
            const wi = window[@intCast(i + slen)];
            const wj = window[len + @as(usize, @intCast(j))];
            dst[aA] = s0 * wj - s1 * wi;
            dst[aB] = s0 * wi + s1 * wj;
        }
    }

    fn wmaproWindow(self: *Dec) void {
        for (0..self.channels_for_cur_subframe) |i| {
            const c = self.channel_indexes_for_cur_subframe[i];
            const ch = &self.channel[c];
            var winlen = ch.prev_block_len;
            var start: i64 = @as(i64, @intCast(ch.coeff_off)) - @as(i64, @intCast(winlen >> 1));

            if (self.subframe_len < winlen) {
                start += @as(i64, @intCast((winlen - self.subframe_len) >> 1));
                winlen = self.subframe_len;
            }
            const window = self.windowOf(winlen);
            winlen >>= 1;
            self.vecFmulWindow(c, start, winlen, window);
            ch.prev_block_len = self.subframe_len;
        }
    }

    // ---- 子帧 ----
    fn decodeSubframe(self: *Dec) Error!void {
        var offset: usize = self.samples_per_frame;
        var subframe_len: usize = self.samples_per_frame;
        var total_samples: usize = self.samples_per_frame * self.channels;
        var transmit_coeffs = false;

        for (0..self.channels) |i| {
            self.channel[i].grouped = false;
            if (offset > self.channel[i].decoded_samples) {
                offset = self.channel[i].decoded_samples;
                subframe_len = self.channel[i].subframe_len[self.channel[i].cur_subframe];
            }
        }

        self.channels_for_cur_subframe = 0;
        for (0..self.channels) |i| {
            const cur_subframe = self.channel[i].cur_subframe;
            total_samples -= self.channel[i].decoded_samples;
            if (offset == self.channel[i].decoded_samples and
                subframe_len == self.channel[i].subframe_len[cur_subframe])
            {
                total_samples -= self.channel[i].subframe_len[cur_subframe];
                self.channel[i].decoded_samples += self.channel[i].subframe_len[cur_subframe];
                self.channel_indexes_for_cur_subframe[self.channels_for_cur_subframe] = i;
                self.channels_for_cur_subframe += 1;
            }
        }
        if (total_samples == 0) self.parsed_all_subframes = true;

        self.table_idx = avLog2(self.samples_per_frame / subframe_len);
        self.num_bands = @intCast(self.num_sfb[self.table_idx]);
        self.cur_sfb_offsets = self.sfb_offsets[self.table_idx][0..];
        self.cur_subwoofer_cutoff = self.subwoofer_cutoffs[self.table_idx];

        offset += self.samples_per_frame >> 1;
        for (0..self.channels_for_cur_subframe) |i| {
            const c = self.channel_indexes_for_cur_subframe[i];
            self.channel[c].coeff_off = offset;
        }

        self.subframe_len = subframe_len;
        self.esc_len = avLog2(subframe_len - 1) + 1;

        // 扩展头（fill bits）
        if (self.gb.get1() != 0) {
            var num_fill_bits: usize = 0;
            const tmp2 = self.gb.get(2);
            if (tmp2 == 0) {
                const len = self.gb.get(4);
                num_fill_bits = @as(usize, self.gb.get(len)) + 1;
            } else {
                num_fill_bits = tmp2;
            }
            if (num_fill_bits != 0) {
                if (self.gb.count() + num_fill_bits > self.num_saved_bits) return error.Corrupt;
                self.gb.skip(num_fill_bits);
            }
        }

        if (self.gb.get1() != 0) return error.UnsupportedFormat;

        try self.decodeChannelTransform();

        for (0..self.channels_for_cur_subframe) |i| {
            const c = self.channel_indexes_for_cur_subframe[i];
            const tc = self.gb.get1() != 0;
            self.channel[c].transmit_coefs = tc;
            if (tc) transmit_coeffs = true;
        }

        if (transmit_coeffs) {
            var quant_step: i32 = 90 * @as(i32, self.p.bits_per_sample) >> 4;

            const tv = self.gb.get1() != 0;
            self.transmit_num_vec_coeffs = tv;
            if (tv) {
                const num_bits = avLog2((subframe_len + 3) / 4) + 1;
                for (0..self.channels_for_cur_subframe) |i| {
                    const c = self.channel_indexes_for_cur_subframe[i];
                    const num_vec_coeffs = @as(usize, self.gb.get(num_bits)) << 2;
                    if (num_vec_coeffs > subframe_len) return error.Corrupt;
                    self.channel[c].num_vec_coeffs = num_vec_coeffs;
                }
            } else {
                for (0..self.channels_for_cur_subframe) |i| {
                    const c = self.channel_indexes_for_cur_subframe[i];
                    self.channel[c].num_vec_coeffs = subframe_len;
                }
            }

            // 量化步进（6-bit 有符号 + escape）
            var step: i32 = getSignedBits(&self.gb, 6);
            quant_step += step;
            if (step == -32 or step == 31) {
                const sign: i32 = if (step == 31) 0 else -1;
                var quant: i32 = 0;
                while (self.gb.count() + 5 < self.num_saved_bits) {
                    const s: i32 = @intCast(self.gb.get(5));
                    step = s;
                    if (s != 31) break;
                    quant += 31;
                }
                quant_step += ((quant + step) ^ sign) - sign;
            }

            if (self.channels_for_cur_subframe == 1) {
                self.channel[self.channel_indexes_for_cur_subframe[0]].quant_step = quant_step;
            } else {
                const modifier_len = @as(usize, self.gb.get(3));
                for (0..self.channels_for_cur_subframe) |i| {
                    const c = self.channel_indexes_for_cur_subframe[i];
                    self.channel[c].quant_step = quant_step;
                    if (self.gb.get1() != 0) {
                        if (modifier_len != 0) {
                            self.channel[c].quant_step += @as(i32, @intCast(self.gb.get(modifier_len))) + 1;
                        } else {
                            self.channel[c].quant_step += 1;
                        }
                    }
                }
            }

            try self.decodeScaleFactors();
        }

        // 谱系数
        for (0..self.channels_for_cur_subframe) |i| {
            const c = self.channel_indexes_for_cur_subframe[i];
            if (self.channel[c].transmit_coefs and self.gb.count() < self.num_saved_bits) {
                try self.decodeCoeffs(c);
            } else {
                for (0..subframe_len) |k| {
                    self.channel[c].out[self.channel[c].coeff_off + k] = 0;
                }
            }
        }

        if (transmit_coeffs) {
            self.inverseChannelTransform();
            // 每个声道：逆量化+缩放 → IMDCT
            const bl = avLog2(subframe_len);
            if (bl < BLOCK_MIN_BITS or bl > 11) return error.UnsupportedFormat;
            for (0..self.channels_for_cur_subframe) |i| {
                const c = self.channel_indexes_for_cur_subframe[i];
                const ch = &self.channel[c];
                const sf = ch.cur_scale;
                const max_sf = ch.max_scale_factor;
                const qstep = ch.quant_step;
                const stepv = ch.scale_factor_step;

                if (c == @as(usize, @intCast(@max(self.lfe_channel, 0))) and self.lfe_channel >= 0) {
                    for (self.cur_subwoofer_cutoff..subframe_len) |k| {
                        self.tmp[k] = 0;
                    }
                }
                for (0..self.num_bands) |b| {
                    const end = minV(self.cur_sfb_offsets[b + 1], subframe_len);
                    const exp: i32 = qstep - (max_sf - ch.saved_scale_factors[sf][b]) * stepv;
                    const quant = self.ffExp10(@as(f64, @floatFromInt(exp)) / 20.0);
                    const start = self.cur_sfb_offsets[b];
                    for (start..end) |k| {
                        self.tmp[k] = ch.out[ch.coeff_off + k] * quant;
                    }
                }
                switch (subframe_len) {
                    64 => wmdct.imdctInv(64, self.tmp[0..64], ch.out[ch.coeff_off..][0..64], &self.mdct_scratch),
                    128 => wmdct.imdctInv(128, self.tmp[0..128], ch.out[ch.coeff_off..][0..128], &self.mdct_scratch),
                    256 => wmdct.imdctInv(256, self.tmp[0..256], ch.out[ch.coeff_off..][0..256], &self.mdct_scratch),
                    512 => wmdct.imdctInv(512, self.tmp[0..512], ch.out[ch.coeff_off..][0..512], &self.mdct_scratch),
                    1024 => wmdct.imdctInv(1024, self.tmp[0..1024], ch.out[ch.coeff_off..][0..1024], &self.mdct_scratch),
                    2048 => wmdct.imdctInv(2048, self.tmp[0..2048], ch.out[ch.coeff_off..][0..2048], &self.mdct_scratch),
                    else => return error.UnsupportedFormat,
                }
            }
        }

        self.wmaproWindow();
        for (0..self.channels_for_cur_subframe) |i| {
            const c = self.channel_indexes_for_cur_subframe[i];
            if (self.channel[c].cur_subframe >= self.channel[c].num_subframes) return error.Corrupt;
            self.channel[c].cur_subframe += 1;
        }
    }

    // ---- 帧 ----
    /// 返回 true=还有帧，false=尾帧（含错误时返回 false 视作丢帧）
    fn decodeFrame(self: *Dec) bool {
        // 帧长（len_prefix）
        var len: usize = 0;
        if (self.len_prefix) len = @as(usize, self.gb.get(self.log2_frame_size));

        if (self.decodeTilehdr()) |_| {} else |_| {
            self.packet_loss = true;
            return false;
        }

        // postproc transform
        if (self.channels > 1 and self.gb.get1() != 0) {
            if (self.gb.get1() != 0) {
                for (0..self.channels * self.channels) |_| {
                    self.gb.skip(4);
                }
            }
        }

        if (self.dynamic_range_compression) {
            self.drc_gain = @intCast(self.gb.get(8));
        }

        if (self.gb.get1() != 0) {
            if (self.gb.get1() != 0) {
                self.trim_start = @intCast(self.gb.get(avLog2(self.samples_per_frame * 2)));
            }
            if (self.gb.get1() != 0) {
                self.trim_end = @intCast(self.gb.get(avLog2(self.samples_per_frame * 2)));
            }
        } else {
            self.trim_start = 0;
            self.trim_end = 0;
        }

        self.parsed_all_subframes = false;
        for (0..self.channels) |i| {
            self.channel[i].decoded_samples = 0;
            self.channel[i].cur_subframe = 0;
            self.channel[i].reuse_sf = false;
        }

        var i: usize = 0;
        while (!self.parsed_all_subframes) : (i += 1) {
            if (i > 64) {
                self.packet_loss = true;
                return false;
            }
            if (self.decodeSubframe()) |_| {} else |_| {
                self.packet_loss = true;
                return false;
            }
        }

        // 输出样本：先拷入 planes（帧内容），再做 second-half 左移复用
        var got_frame = true;
        for (0..self.channels) |cc| {
            @memcpy(self.planes[cc][0..self.samples_per_frame], self.channel[cc].out[0..self.samples_per_frame]);
            std.mem.copyForwards(f32, self.channel[cc].out[0 .. self.samples_per_frame / 2], self.channel[cc].out[self.samples_per_frame..][0 .. self.samples_per_frame / 2]);
        }

        if (self.skip_frame) {
            self.skip_frame = false;
            got_frame = false;
        }

        if (self.len_prefix) {
            if (len != (self.gb.count() - self.frame_offset) + 2) {
                self.packet_loss = true;
                return false;
            }
            const skip_bits = len - (self.gb.count() - self.frame_offset) - 1;
            if (self.gb.index + skip_bits > self.gb.cap) {
                self.packet_loss = true;
                return false;
            }
            self.gb.skip(skip_bits);
        } else {
            while (self.gb.count() < self.num_saved_bits and self.gb.get1() == 0) {}
        }

        const more_frames = self.gb.get1();
        self.frame_num += 1;

        if (got_frame) {
            self.frame_pending = true;
            self.frame_out_len = self.samples_per_frame;
            self.frame_out_start = 0;
        }
        return more_frames != 0;
    }

    // ---- packet ----
    /// 处理一个 WMA packet；成功返回消费字节数。frame_pending 置位表示有输出帧。
    pub fn decodePacket(self: *Dec, buf_in: []const u8) Error!usize {
        self.frame_pending = false;
        const buf_size_all = buf_in.len;
        var buf = buf_in;

        if (buf_size_all == 0) {
            // EOF flush：输出已解出的后半（重叠尾），其余补 0
            self.packet_done = false;
            if (self.eof_done) return 0;
            for (0..self.channels) |c| {
                @memset(self.planes[c][0..self.samples_per_frame], 0);
                @memcpy(self.planes[c][0 .. self.samples_per_frame / 2], self.channel[c].out[0 .. self.samples_per_frame / 2]);
            }
            self.eof_done = true;
            self.packet_done = true;
            self.frame_pending = true;
            self.frame_out_len = self.samples_per_frame;
            self.frame_out_start = 0;
            return 0;
        } else if (self.packet_done or self.packet_loss) {
            self.packet_done = false;
            if (self.p.bits_per_sample == 0) unreachable;
            if (buf_size_all < self.p.block_align) {
                self.packet_loss = true;
                return error.Corrupt;
            }
            self.next_packet_start = buf_size_all - self.p.block_align;
            const wsize = self.p.block_align;
            buf = buf_in[0..wsize];
            self.buf_bit_size = wsize << 3;
            self.pgb = .{ .buf = buf, .cap = wsize << 3 };

            const packet_sequence_number = @as(usize, self.pgb.get(4));
            self.pgb.skip(2);
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
                // 忽略未解码的已保存位
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
            self.pgb = .{ .buf = buf, .cap = wsize << 3 };
            self.pgb.skip(self.packet_offset);

            if (self.len_prefix and self.remainingBits(&self.pgb) > self.log2_frame_size) {
                const frame_size = @as(usize, self.pgb.peek(self.log2_frame_size));
                if (frame_size != 0 and frame_size <= self.remainingBits(&self.pgb)) {
                    self.saveBits(&self.pgb, frame_size, false);
                    if (!self.packet_loss) {
                        const more = self.decodeFrame();
                        self.packet_done = !more;
                    } else {
                        self.packet_done = true;
                    }
                } else {
                    self.packet_done = true;
                }
            } else if (!self.len_prefix and self.num_saved_bits > self.gb.count()) {
                const more = self.decodeFrame();
                self.packet_done = !more;
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

        // trim（只对刚产出的帧生效一次）
        if (self.frame_pending and self.trim_start != 0) {
            if (self.trim_start < self.frame_out_len) {
                self.frame_out_start += self.trim_start;
                self.frame_out_len -= self.trim_start;
            } else {
                self.frame_pending = false;
            }
            self.trim_start = 0;
        }
        if (self.frame_pending and self.trim_end != 0) {
            if (self.trim_end < self.frame_out_len) {
                self.frame_out_len -= self.trim_end;
            } else {
                self.frame_pending = false;
            }
            self.trim_end = 0;
        }

        return self.pgb.count() >> 3;
    }

    fn remainingBits(self: *Dec, gb: *Bits) usize {
        return self.buf_bit_size -% gb.count();
    }

    fn saveBits(self: *Dec, gb: *Bits, len0: usize, append: bool) void {
        var len = len0;
        if (len == 0) return;
        if (len > MAX_FRAMESIZE * 8) {
            self.packet_loss = true;
            return;
        }
        var buflen: usize = undefined;
        if (!append) {
            self.frame_offset = gb.count() & 7;
            self.num_saved_bits = self.frame_offset;
            self.pb.reset();
            buflen = (self.num_saved_bits + len + 7) >> 3;
        } else {
            buflen = (self.pb.count() + len + 7) >> 3;
        }
        if (buflen > MAX_FRAMESIZE) {
            self.packet_loss = true;
            return;
        }
        std.debug.assert(len <= self.pb.left());

        self.num_saved_bits += len;
        if (!append) {
            copyBits(&self.pb, gb.buf[gb.count() >> 3 ..], self.num_saved_bits);
        } else {
            var nalign = 8 - (gb.count() & 7);
            if (nalign > len) nalign = len;
            self.pb.write(nalign, gb.get(nalign));
            len -= nalign;
            copyBits(&self.pb, gb.buf[gb.count() >> 3 ..], len);
        }
        gb.skip(len);
        self.gb = .{ .buf = self.frame_data[0 .. MAX_FRAMESIZE + 64], .cap = self.num_saved_bits };
        self.gb.skip(self.frame_offset);
    }
};

fn getRate(sample_rate: u32) u32 {
    if (sample_rate > 44100) return 48000 else if (sample_rate > 32000) return 44100 else if (sample_rate > 24000) return 32000;
    return 24000;
}

pub fn ffWmaGetFrameLenBits(sample_rate: u32, comptime version: u32, decode_flags: u16) usize {
    var frame_len_bits: usize = if (sample_rate <= 16000)
        9
    else if (sample_rate <= 22050 or (sample_rate <= 32000 and version == 1))
        10
    else if (sample_rate <= 48000 or version < 3)
        11
    else if (sample_rate <= 96000)
        12
    else
        13;
    if (version == 3) {
        const tmp = decode_flags & 0x6;
        if (tmp == 0x2) frame_len_bits += 1 else if (tmp == 0x4) frame_len_bits -= 1 else if (tmp == 0x6) frame_len_bits -= 2;
    }
    return frame_len_bits;
}

pub fn getSignedBits(gb: *Bits, n: usize) i32 {
    const v = gb.get(n);
    if (n == 0) return 0;
    if (n == 32) return @bitCast(v);
    const sign: u32 = @as(u32, 1) << @intCast(n - 1);
    if (v & sign != 0) {
        return @intCast(@as(i64, @intCast(v)) - @as(i64, @intCast(sign << 1)));
    }
    return @intCast(v);
}

test "getSignedBits 符号扩展" {
    var buf = [1]u8{0} ** 4;
    var w = BitWriter{ .buf = &buf };
    w.write(6, 0x20); // -32
    var b = Bits{ .buf = &buf, .cap = 6 };
    try std.testing.expectEqual(@as(i32, -32), getSignedBits(&b, 6));
    var buf2 = [1]u8{0} ** 4;
    var w2 = BitWriter{ .buf = &buf2 };
    w2.write(6, 0x1F); // 31
    var b2 = Bits{ .buf = &buf2, .cap = 6 };
    try std.testing.expectEqual(@as(i32, 31), getSignedBits(&b2, 6));
}

test "avLog2" {
    try std.testing.expectEqual(@as(usize, 14), avLog2(16384));
    try std.testing.expectEqual(@as(usize, 0), avLog2(1));
    try std.testing.expectEqual(@as(usize, 11), avLog2(2048));
}
