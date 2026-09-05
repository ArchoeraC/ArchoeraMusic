//! MPEG-4 ALS（Audio Lossless Coding）解码核心 —— 逐位移植 FFmpeg alsdec.c + bgmc.c
//!
//! 覆盖（对照 reference/FFmpeg/libavcodec/{alsdec.c,bgmc.c}）：
//!   - ALSSpecificConfig 解析（含 mp4 ASC 前置 config_offset 语义：ffmpeg 将 esds
//!     DecoderSpecificInfo 整段当 extradata，先按 mpeg4audio.c 跳过
//!     AudioSpecificConfig，再从 als_id 起读特定配置）；
//!   - 常量块 / 变量块；自适应 / 固定预测阶数；Rice 与 BGMC（块 Gilbert-Moore
//!     算术码）残差；LTP；块切换（block switching）；随机访问（RA）帧；
//!   - joint-stereo 配对、mc_coding 多声道相关（als_weighting /
//!     revert_channel_correlation）；跨帧 carryover 样本；
//!   - 输出交错 16/24/32 位整数（bit-exact 对齐 ffmpeg `-f s16le/s32le`）。
//!
//! 不实现（→ error.UnsupportedFormat，由 fmt/m4a 回退系统 ffmpeg）：
//!   浮点 ALS（floating）、RLSLMS、chan_sort 通道重排。
//!
//! 位流访问模型：整个 ALS 帧流为内存字节流，帧在字节边界起读、字节边界收尾
//! （每 block / 每声道数据后 align）。mp4 一包可含多帧（ffmpeg 语义同：帧长仅
//! 解码可知）。流末尾 64B 零填充模拟 ffmpeg AV_INPUT_BUFFER_PADDING_SIZE，
//! 越界位返回 0（不越界崩溃）。

const std = @import("std");
const tables = @import("tables.zig");

const Allocator = std.mem.Allocator;
const Error = @import("../../error.zig").Error;

const LUT_BITS: u32 = 14 - 8;
const LUT_SIZE: u32 = 1 << LUT_BITS;
const LUT_BUFF: u32 = 4;
const VALUE_BITS: u32 = 18;
const TOP_VALUE: u32 = (1 << VALUE_BITS) - 1;
const FIRST_QTR: u32 = TOP_VALUE / 4 + 1;
const HALF: u32 = 2 * FIRST_QTR;
const THIRD_QTR: u32 = 3 * FIRST_QTR;

pub const RaFlag = enum(u2) {
    none = 0,
    frames = 1,
    header = 2,
};

/// ALSSpecificConfig（对应 alsdec.c 结构 + mpeg4audio 得到的采样率/声道数）
pub const SpecificConfig = struct {
    samples: u32,
    resolution: u8,
    floating: bool,
    msb_first: bool,
    frame_length: u32,
    ra_distance: u8,
    ra_flag: RaFlag,
    adapt_order: bool,
    coef_table: u2,
    long_term_prediction: bool,
    max_order: u32,
    block_switching: u2,
    bgmc: bool,
    sb_part: bool,
    joint_stereo: bool,
    mc_coding: bool,
    chan_config: bool,
    chan_sort: bool,
    crc_enabled: bool,
    rlslms: bool,
    sample_rate: u32,
    channels: u32,
    bits_per_raw_sample: u8,
    s_max: u8,
    ltp_lag_length: u8,
};

/// 帧内位读取。data 为带尾部零填充的字节流；limit_bits 为真实数据位长。
pub const BitReader = struct {
    data: []const u8,
    limit_bits: u64,
    pos: u64 = 0,

    pub fn init(data: []const u8, limit_bits: u64) BitReader {
        return .{ .data = data, .limit_bits = limit_bits };
    }

    pub fn bitsLeft(self: *const BitReader) i64 {
        return @as(i64, @intCast(self.limit_bits)) - @as(i64, @intCast(self.pos));
    }

    inline fn bitAt(self: *const BitReader, bit: u64) u1 {
        if (bit >= self.limit_bits) return 0;
        return @intCast((self.data[bit >> 3] >> @intCast(7 - (bit & 7))) & 1);
    }

    pub fn readBit(self: *BitReader) u1 {
        const b = self.bitAt(self.pos);
        self.pos += 1;
        return b;
    }

    pub fn readBits(self: *BitReader, n: u6) u32 {
        var v: u32 = 0;
        var i: u6 = 0;
        while (i < n) : (i += 1) {
            v = (v << 1) | self.readBit();
        }
        return v;
    }

    pub fn readBitsLong(self: *BitReader, n: u32) u32 {
        var v: u32 = 0;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            v = (v << 1) | self.readBit();
        }
        return v;
    }

    pub fn skip(self: *BitReader, n: u64) void {
        self.pos += n;
    }

    pub fn alignByte(self: *BitReader) void {
        self.pos = (self.pos + 7) & ~@as(u64, 7);
    }

    pub fn showBits(self: *const BitReader, n: u6) u32 {
        var v: u32 = 0;
        var i: u6 = 0;
        while (i < n) : (i += 1) {
            v = (v << 1) | self.bitAt(self.pos + i);
        }
        return v;
    }
};

fn peek24(br: *const BitReader) u32 {
    return br.showBits(24);
}

/// av_ceil_log2
fn ceilLog2(x_in: u32) u32 {
    var x = x_in;
    if (x == 0) return 0;
    x -= 1;
    var r: u32 = 0;
    while (x != 0) : (x >>= 1) r += 1;
    return r;
}

/// Rice 解码（alsdec.c decode_rice + get_unary(gb, 0, max)）
fn decodeRice(br: *BitReader, k_in: u32) i32 {
    const k: i64 = @intCast(k_in);
    const max: i64 = @max(br.bitsLeft() - k, 0);
    var q: u32 = 0;
    var i: i64 = 0;
    while (i < max and br.readBit() == 1) : (i += 1) {}
    q = @intCast(i);
    const r: u1 = if (k_in != 0) br.readBit() else @intFromBool((q & 1) == 0);
    if (k_in > 1) {
        q <<= @intCast(k_in - 1);
        q += br.readBits(@intCast(k_in - 1));
    } else if (k_in == 0) {
        q >>= 1;
    }
    if (r == 1) return @bitCast(q);
    return @bitCast(~q);
}

/// get_sbits_long：读 n 位并符号扩展
fn readSigned(br: *BitReader, n: u32) i32 {
    if (n == 0) return 0;
    const raw = br.readBits(@intCast(n));
    const sign: u1 = @intCast((raw >> @intCast(n - 1)) & 1);
    if (sign == 1) {
        const ones: u32 = (~@as(u32, 0)) << @intCast(n);
        return @bitCast(raw | ones);
    }
    return @bitCast(raw);
}

const ChanData = struct {
    stop_flag: bool = false,
    master_channel: u32 = 0,
    time_diff_flag: bool = false,
    time_diff_sign: bool = false,
    time_diff_index: u32 = 0,
    weighting: [6]i32 = [_]i32{0} ** 6,
};

/// 解析 ALSSpecificConfig（dsi = mp4 esds DecoderSpecificInfo 原始字节）。
/// 便捷入口：实际实现在 Decoder.parseConfig。
pub fn parseConfig(dsi: []const u8) Error!SpecificConfig {
    return Decoder.parseConfig(dsi);
}

/// 声道工作区（对应 ctx 每声道/每 block 标量数组 + quant/lpc 缓冲）
const Slot = struct {
    const_block: bool = false,
    shift_lsbs: u32 = 0,
    opt_order: u32 = 0,
    store_prev: bool = false,
    use_ltp: bool = false,
    ltp_lag: u32 = 0,
};

/// 一个块的解码参数（块局部；标量经 slot 存于 ctx，镜像 C 指针式数组）
const Block = struct {
    block_length: u32 = 0,
    ra_block: bool = false,
    js_blocks: bool = false,
    /// 标量槽位（非 mc：0；mc：声道号）
    slot: usize = 0,
    /// 本块样本起始绝对基址（raw_buf）
    rab: usize = 0,
    /// js_blocks 时另一声道本块起始绝对基址（null = 无）
    other_rab: ?usize = null,
};

pub const Decoder = struct {
    allocator: Allocator,
    cfg: SpecificConfig,
    /// 整个帧流（含 64B 尾部零填充）
    stream: []u8,
    stream_len: usize,
    /// 下一帧字节起点
    stream_pos: usize = 0,

    channels: usize,
    channel_size: usize,
    num_buffers: usize,

    /// quant / lpc 系数（num_buffers × max_order）
    quant_cof: []i32 = &.{},
    lpc_cof: []i32 = &.{},
    /// 声道标量（num_buffers）
    slots: []Slot = &.{},
    ltp_gain_buf: []i32 = &.{},
    /// 声道原始样本（raw_buf，声道区含 carryover 头）
    raw_buf: []i32 = &.{},
    /// max_order：store_prev 暂存
    prev_raw: []i32 = &.{},

    /// mcc（num_buffers×num_buffers）
    chan_data_buf: []ChanData = &.{},
    chan_data: [][]ChanData = &.{},
    reverted: []bool = &.{},

    /// BGMC LUT
    bgmc_lut: []u8 = &.{},
    bgmc_lut_status: [LUT_BUFF]i32 = [_]i32{-1} ** LUT_BUFF,

    frame_id: u64 = 0,
    cur_frame_length: u32 = 0,
    num_blocks: u32 = 0,
    js_switch: bool = false,

    // ------------------------------------------------------------------
    pub fn init(allocator: Allocator, cfg: SpecificConfig, stream: []u8, stream_len: usize) Error!Decoder {
        var d = Decoder{
            .allocator = allocator,
            .cfg = cfg,
            .stream = stream,
            .stream_len = stream_len,
            .channels = cfg.channels,
            .channel_size = @as(usize, cfg.max_order) + @as(usize, cfg.frame_length),
            .num_buffers = if (cfg.mc_coding) @as(usize, cfg.channels) else 1,
        };
        errdefer d.deinit();
        const a = allocator;
        const mo = cfg.max_order;
        if (mo == 0) return error.UnsupportedFormat;
        d.quant_cof = try a.alloc(i32, d.num_buffers * mo);
        d.lpc_cof = try a.alloc(i32, d.num_buffers * mo);
        d.slots = try a.alloc(Slot, d.num_buffers);
        d.ltp_gain_buf = try a.alloc(i32, d.num_buffers * 5);
        d.prev_raw = try a.alloc(i32, mo);
        d.raw_buf = try a.alloc(i32, d.channels * d.channel_size);
        @memset(d.raw_buf, 0);
        if (cfg.mc_coding) {
            const n = d.num_buffers;
            d.chan_data_buf = try a.alloc(ChanData, n * n);
            d.chan_data = try a.alloc([]ChanData, n);
            d.reverted = try a.alloc(bool, n);
            var c: usize = 0;
            while (c < n) : (c += 1) d.chan_data[c] = d.chan_data_buf[c * n ..][0..n];
        }
        if (cfg.bgmc) {
            d.bgmc_lut = try a.alloc(u8, (LUT_BUFF * 16 * LUT_SIZE));
        }
        return d;
    }

    pub fn deinit(self: *Decoder) void {
        const a = self.allocator;
        if (self.quant_cof.len > 0) a.free(self.quant_cof);
        if (self.lpc_cof.len > 0) a.free(self.lpc_cof);
        if (self.slots.len > 0) a.free(self.slots);
        if (self.ltp_gain_buf.len > 0) a.free(self.ltp_gain_buf);
        if (self.raw_buf.len > 0) a.free(self.raw_buf);
        if (self.prev_raw.len > 0) a.free(self.prev_raw);
        if (self.chan_data_buf.len > 0) a.free(self.chan_data_buf);
        if (self.chan_data.len > 0) a.free(self.chan_data);
        if (self.reverted.len > 0) a.free(self.reverted);
        if (self.bgmc_lut.len > 0) a.free(self.bgmc_lut);
        self.* = undefined;
    }

    /// 声道 c 帧样本区绝对基址（帧样本 0 处；其前 max_order 为 carryover）
    inline fn chanBase(self: *const Decoder, c: usize) usize {
        return c * self.channel_size + @as(usize, self.cfg.max_order);
    }

    inline fn qcOf(self: *Decoder, slot: usize) []i32 {
        const mo = self.cfg.max_order;
        return self.quant_cof[slot * mo ..][0..mo];
    }
    inline fn lcOf(self: *Decoder, slot: usize) []i32 {
        const mo = self.cfg.max_order;
        return self.lpc_cof[slot * mo ..][0..mo];
    }
    inline fn ltpGainOf(self: *Decoder, slot: usize) []i32 {
        return self.ltp_gain_buf[slot * 5 ..][0..5];
    }

    // ------------------------------------------------------------------
    // ALSSpecificConfig 解析（dsi = mp4 esds DecoderSpecificInfo 原始字节）
    // ------------------------------------------------------------------
    pub fn parseConfig(dsi: []const u8) Error!SpecificConfig {
        if (dsi.len < 30) return error.UnsupportedFormat;
        var gb = BitReader.init(dsi, dsi.len * 8);
        var aot: u32 = gb.readBits(5);
        if (aot == 31) aot = 32 + gb.readBits(6);
        const sfi: u32 = gb.readBits(4);
        if (sfi == 0x0F) gb.skip(24); // explicit 采样率
        gb.skip(4); // channelConfiguration（ALS conformance 文件此处已损坏）
        if (aot != 36) return error.UnsupportedFormat; // AOT_ALS = 36
        gb.skip(5);
        // 若其后 24 位非 '\0ALS'（即 0x00414C53 高 24 位）则再跳 24（旧文件两套布局）
        if (peek24(&gb) != 0x414C53) gb.skip(24);
        const config_offset = gb.pos;

        var br = BitReader.init(dsi, dsi.len * 8);
        br.pos = config_offset;
        if (br.bitsLeft() < (30 << 3)) return error.UnsupportedFormat;

        if (br.readBits(32) != 0x414C5300) return error.UnsupportedFormat; // 'ALS\0'
        const als_sr = br.readBits(32);
        if (als_sr == 0) return error.UnsupportedFormat;
        const als_samples = br.readBits(32);
        const als_channels: u32 = br.readBits(16) + 1;
        if (als_channels == 0) return error.UnsupportedFormat;

        br.skip(3); // file_type
        const resolution: u32 = br.readBits(3);
        const floating = br.readBit() != 0;
        const msb_first = br.readBit() != 0;
        const frame_length: u32 = br.readBits(16) + 1;
        const ra_distance: u32 = br.readBits(8);
        const ra_flag: u32 = br.readBits(2);
        const adapt_order = br.readBit() != 0;
        const coef_table: u32 = br.readBits(2);
        const ltp = br.readBit() != 0;
        const max_order: u32 = br.readBits(10);
        const block_switching: u32 = br.readBits(2);
        const bgmc = br.readBit() != 0;
        const sb_part = br.readBit() != 0;
        const joint_stereo = br.readBit() != 0;
        const mc_coding = br.readBit() != 0;
        const chan_config = br.readBit() != 0;
        const chan_sort = br.readBit() != 0;
        const crc_enabled = br.readBit() != 0;
        const rlslms = br.readBit() != 0;
        br.skip(6); // 5 reserved + 1 aux_data_enabled

        if (chan_config) _ = br.readBits(16);

        if (floating or rlslms or chan_sort) return error.UnsupportedFormat;

        return SpecificConfig{
            .samples = als_samples,
            .resolution = @intCast(resolution),
            .floating = floating,
            .msb_first = msb_first,
            .frame_length = frame_length,
            .ra_distance = @intCast(ra_distance),
            .ra_flag = @enumFromInt(ra_flag),
            .adapt_order = adapt_order,
            .coef_table = @intCast(coef_table),
            .long_term_prediction = ltp,
            .max_order = max_order,
            .block_switching = @intCast(block_switching),
            .bgmc = bgmc,
            .sb_part = sb_part,
            .joint_stereo = joint_stereo,
            .mc_coding = mc_coding,
            .chan_config = chan_config,
            .chan_sort = chan_sort,
            .crc_enabled = crc_enabled,
            .rlslms = rlslms,
            .sample_rate = als_sr,
            .channels = als_channels,
            .bits_per_raw_sample = @intCast((resolution + 1) * 8),
            .s_max = if (resolution > 1) 31 else 15,
            .ltp_lag_length = 8 +
                (if (als_sr >= 96000) @as(u8, 1) else 0) +
                (if (als_sr >= 192000) @as(u8, 1) else 0),
        };
    }

    // ------------------------------------------------------------------
    // 块切换树（parse_bs_info / get_block_sizes）
    // ------------------------------------------------------------------
    fn parseBsInfo(self: *Decoder, bs_info: u32, n: u32, div: u32, div_blocks: []u32, num_blocks: *u32) void {
        if (n < 31 and ((bs_info << @intCast(n)) & 0x40000000) != 0) {
            parseBsInfo(self, bs_info, n * 2 + 1, div + 1, div_blocks, num_blocks);
            parseBsInfo(self, bs_info, n * 2 + 2, div + 1, div_blocks, num_blocks);
        } else {
            div_blocks[num_blocks.*] = div;
            num_blocks.* += 1;
        }
    }

    fn getBlockSizes(self: *Decoder, br: *BitReader, div_blocks: []u32, num_blocks: *u32, bs_info: *u32) void {
        const sconf = &self.cfg;
        if (sconf.block_switching != 0) {
            const nbits: u32 = @as(u32, 1) << @as(u5, @intCast(@as(u32, sconf.block_switching) + 2));
            bs_info.* = br.readBitsLong(nbits);
            if (nbits < 32) bs_info.* <<= @intCast(32 - nbits);
        }
        num_blocks.* = 0;
        self.parseBsInfo(bs_info.*, 0, 0, div_blocks, num_blocks);

        var b: u32 = 0;
        while (b < num_blocks.*) : (b += 1) {
            div_blocks[b] = sconf.frame_length >> @intCast(div_blocks[b]);
        }
        if (self.cur_frame_length != sconf.frame_length) {
            var remaining: u32 = self.cur_frame_length;
            b = 0;
            while (b < num_blocks.*) : (b += 1) {
                if (remaining <= div_blocks[b]) {
                    div_blocks[b] = remaining;
                    num_blocks.* = b + 1;
                    break;
                }
                remaining -= div_blocks[b];
            }
        }
    }

    // ------------------------------------------------------------------
    // 常量 / 变量块读取与解码
    // ------------------------------------------------------------------

    /// read_const_block_data：读首样本（常量值）到 raw[rab]
    fn readConstBlockData(self: *Decoder, br: *BitReader, bd: *Block) Error!void {
        const sconf = &self.cfg;
        if (bd.block_length == 0) return error.Corrupt;
        const val_const = br.readBit() != 0;
        bd.js_blocks = br.readBit() != 0;
        br.skip(5);
        var value: i32 = 0;
        if (val_const) {
            const nbits: u32 = if (sconf.floating) 24 else sconf.bits_per_raw_sample;
            value = readSigned(br, nbits);
        }
        self.slots[bd.slot].const_block = true;
        self.raw_buf[bd.rab] = value;
    }

    /// decode_const_block_data：填充整块
    fn decodeConstBlockData(self: *Decoder, bd: *const Block) void {
        const value = self.raw_buf[bd.rab];
        var p = bd.rab + 1;
        const end = bd.rab + bd.block_length;
        while (p < end) : (p += 1) self.raw_buf[p] = value;
    }

    /// read_var_block_data（残差写 raw_buf；标量写 slots[slot]）
    fn readVarBlockData(self: *Decoder, br: *BitReader, bd: *Block) Error!void {
        const sconf = &self.cfg;
        const slot = &self.slots[bd.slot];
        var k: u32 = 0;
        var s: [8]u32 = undefined;
        var sx: [8]u32 = undefined;

        slot.const_block = false;
        slot.opt_order = 1;
        bd.js_blocks = br.readBit() != 0;

        var log2_sub_blocks: u32 = 0;
        if (sconf.bgmc or sconf.sb_part) {
            if (sconf.bgmc and sconf.sb_part) {
                log2_sub_blocks = br.readBits(2);
            } else {
                log2_sub_blocks = 2 * br.readBits(1);
            }
        }
        const sub_blocks: u32 = @as(u32, 1) << @intCast(log2_sub_blocks);
        if ((bd.block_length & (sub_blocks - 1)) != 0 or bd.block_length == 0) return error.Corrupt;
        const sb_length: u32 = bd.block_length >> @intCast(log2_sub_blocks);

        if (sconf.bgmc) {
            s[0] = br.readBits(@intCast(@as(u32, 8) + @as(u32, @intFromBool(sconf.resolution > 1))));
            k = 1;
            while (k < sub_blocks) : (k += 1) {
                s[k] = s[k - 1] +% @as(u32, @bitCast(decodeRice(br, 2)));
            }
            k = 0;
            while (k < sub_blocks) : (k += 1) {
                sx[k] = s[k] & 0x0F;
                s[k] >>= 4;
            }
        } else {
            s[0] = br.readBits(@intCast(@as(u32, 4) + @as(u32, @intFromBool(sconf.resolution > 1))));
            k = 1;
            while (k < sub_blocks) : (k += 1) {
                s[k] = s[k - 1] +% @as(u32, @bitCast(decodeRice(br, 0)));
            }
        }
        k = 1;
        while (k < sub_blocks) : (k += 1) {
            if (s[k] > 32) return error.Corrupt;
        }

        var shift_lsbs: u32 = 0;
        if (br.readBit() != 0) shift_lsbs = br.readBits(4) + 1;
        slot.shift_lsbs = shift_lsbs;
        slot.store_prev = (bd.js_blocks and bd.other_rab != null) or shift_lsbs != 0;

        var opt_order: u32 = 0;
        const qc = self.qcOf(bd.slot);
        if (!sconf.rlslms) {
            if (sconf.adapt_order and sconf.max_order != 0) {
                const x: u32 = (bd.block_length >> 3) -% 1;
                const clipped = std.math.clamp(x, 2, sconf.max_order + 1);
                slot.opt_order = br.readBitsLong(ceilLog2(clipped));
                if (slot.opt_order > sconf.max_order) {
                    slot.opt_order = sconf.max_order;
                    return error.Corrupt;
                }
            } else {
                slot.opt_order = sconf.max_order;
            }
            opt_order = slot.opt_order;

            if (opt_order != 0) {
                if (sconf.coef_table == 3) {
                    qc[0] = 32 * @as(i32, tables.parcor_scaled_values[br.readBits(7)]);
                    if (opt_order > 1)
                        qc[1] = -32 * @as(i32, tables.parcor_scaled_values[br.readBits(7)]);
                    k = 2;
                    while (k < opt_order) : (k += 1) {
                        qc[k] = @bitCast(br.readBits(7));
                    }
                } else {
                    var k_max: u32 = @min(opt_order, 20);
                    k = 0;
                    while (k < k_max) : (k += 1) {
                        const rice_param: u32 = @intCast(tables.parcor_rice_table[sconf.coef_table][k][1]);
                        const offset: i32 = tables.parcor_rice_table[sconf.coef_table][k][0];
                        const qv = decodeRice(br, rice_param) + offset;
                        if (qv < -64 or qv > 63) return error.Corrupt;
                        qc[k] = qv;
                    }
                    k_max = @min(opt_order, 127);
                    while (k < k_max) : (k += 1) {
                        qc[k] = decodeRice(br, 2) + @as(i32, @intCast(k & 1));
                    }
                    while (k < opt_order) : (k += 1) {
                        qc[k] = decodeRice(br, 1);
                    }
                    const k0: usize = @intCast(@as(i64, qc[0]) + 64);
                    qc[0] = 32 * @as(i32, tables.parcor_scaled_values[k0]);
                    if (opt_order > 1) {
                        const k1: usize = @intCast(@as(i64, qc[1]) + 64);
                        qc[1] = -32 * @as(i32, tables.parcor_scaled_values[k1]);
                    }
                }
                k = 2;
                const add_base: u32 = if (sconf.coef_table == 3) 0x7F else 1;
                while (k < opt_order) : (k += 1) {
                    const v: u32 = @as(u32, @bitCast(qc[k])) *% (@as(u32, 1) << 14);
                    qc[k] = @bitCast(v +% (add_base << 13));
                }
            }
        }

        // ---- LTP ----
        if (sconf.long_term_prediction) {
            slot.use_ltp = br.readBit() != 0;
            if (slot.use_ltp) {
                const g = self.ltpGainOf(bd.slot);
                g[0] = decodeRice(br, 1) * 8;
                g[1] = decodeRice(br, 2) * 8;
                var r: u32 = 0;
                while (r < 4 and br.readBit() == 1) : (r += 1) {}
                const c: u32 = br.readBits(2);
                if (r >= 4) return error.Corrupt;
                g[2] = tables.ltp_gain_values[r][c];
                g[3] = decodeRice(br, 2) * 8;
                g[4] = decodeRice(br, 1) * 8;
                slot.ltp_lag = br.readBitsLong(self.cfg.ltp_lag_length);
                slot.ltp_lag += @max(4, opt_order + 1);
            }
        }

        // ---- 残差 ----
        var start: u32 = 0;
        if (bd.ra_block) {
            start = @min(opt_order, 3);
            if (sb_length <= start) return error.UnsupportedFormat;
            if (opt_order != 0)
                self.raw_buf[bd.rab] = decodeRice(br, sconf.bits_per_raw_sample - 4);
            if (opt_order > 1)
                self.raw_buf[bd.rab + 1] = decodeRice(br, @min(s[0] + 3, sconf.s_max));
            if (opt_order > 2)
                self.raw_buf[bd.rab + 2] = decodeRice(br, @min(s[0] + 1, sconf.s_max));
        }

        if (sconf.bgmc) {
            try self.readBgmcResidual(br, bd, sb_length, sub_blocks, start, s[0..8], sx[0..8]);
        } else {
            var cur = bd.rab + start;
            var sb: u32 = 0;
            while (sb < sub_blocks) : (sb += 1) {
                var st: u32 = if (sb == 0) start else 0;
                while (st < sb_length) : (st += 1) {
                    self.raw_buf[cur] = decodeRice(br, s[sb]);
                    cur += 1;
                }
            }
        }
    }

    /// BGMC 残差主体（ff_bgmc_decode 调用 + LSB/tail）
    fn readBgmcResidual(
        self: *Decoder,
        br: *BitReader,
        bd: *Block,
        sb_length: u32,
        sub_blocks: u32,
        start: u32,
        s: []const u32,
        sx: []const u32,
    ) Error!void {
        const b: u32 = std.math.clamp((ceilLog2(bd.block_length) -% 3) >> 1, 0, 5);
        if (br.bitsLeft() < VALUE_BITS) return error.Corrupt;
        var high: u32 = TOP_VALUE;
        var low: u32 = 0;
        var value: u32 = br.readBits(@intCast(VALUE_BITS));

        var cur_k: [8]u32 = undefined;
        var cur_delta: [8]u32 = undefined;
        var cur_sx: [8]u32 = undefined;

        var cur = bd.rab + start;
        var sb: u32 = 0;
        while (sb < sub_blocks) : (sb += 1) {
            const sb_len: u32 = sb_length - (if (sb == 0) start else 0);
            const kk: u32 = if (s[sb] > b) s[sb] - b else 0;
            const delta: u32 = (5 -% s[sb]) +% kk;
            cur_k[sb] = kk;
            cur_delta[sb] = delta;
            cur_sx[sb] = sx[sb];
            if (kk >= 32) return error.Corrupt;
            try self.bgmcDecode(br, sb_len, cur, delta, sx[sb], &high, &low, &value);
            cur += sb_len;
        }
        self.bgmcFinish(br);

        cur = bd.rab + start;
        sb = 0;
        while (sb < sub_blocks) : (sb += 1) {
            const cur_tail_code: u32 = tables.tail_code[cur_sx[sb]][cur_delta[sb]];
            const kk: u32 = cur_k[sb];
            var st: u32 = if (sb == 0) start else 0;
            while (st < sb_length) : (st += 1) {
                var res: i32 = self.raw_buf[cur];
                if (@as(u32, @bitCast(res)) == cur_tail_code) {
                    const max_msb: u32 = (2 + @as(u32, @intFromBool(cur_sx[sb] > 2)) + @as(u32, @intFromBool(cur_sx[sb] > 10))) << @intCast(5 - cur_delta[sb]);
                    res = decodeRice(br, s[sb]);
                    if (res >= 0) {
                        res +%= @as(i32, @bitCast(max_msb << @intCast(kk)));
                    } else {
                        res -%= @as(i32, @bitCast((max_msb - 1) << @intCast(kk)));
                    }
                } else {
                    if (res > @as(i32, @bitCast(cur_tail_code))) res -= 1;
                    if ((res & 1) != 0) res = -res;
                    res >>= 1;
                    if (kk != 0) {
                        res = @bitCast(@as(u32, @bitCast(res)) *% (@as(u32, 1) << @intCast(kk)));
                        res = @bitCast(@as(u32, @bitCast(res)) | br.readBits(@intCast(kk)));
                    }
                }
                self.raw_buf[cur] = res;
                cur += 1;
            }
        }
    }

    // ========================= BGMC（bgmc.c） =========================

    inline fn cfTableAt(sx: usize, symbol: usize) u16 {
        if (sx < 3) {
            return if (symbol < 129) tables.cf_tables_1[sx][symbol] else 0;
        } else if (sx < 11) {
            const i = sx - 3;
            return if (symbol < 193) tables.cf_tables_2[i][symbol] else 0;
        } else {
            const i = sx - 11;
            return if (symbol < 257) tables.cf_tables_3[i][symbol] else 0;
        }
    }

    fn bgmcLutFillp(self: *Decoder, lut: []u8, lut_status: *i32, delta: u32) void {
        _ = self;
        var sx: u32 = 0;
        while (sx < 16) : (sx += 1) {
            var i: u32 = 0;
            while (i < LUT_SIZE) : (i += 1) {
                const target: u32 = (i + 1) << (14 - LUT_BITS);
                var symbol: u32 = @as(u32, 1) << @intCast(delta);
                while (cfTableAt(sx, symbol) > target)
                    symbol += @as(u32, 1) << @intCast(delta);
                lut[@intCast(sx * LUT_SIZE + i)] = @intCast(symbol >> @intCast(delta));
            }
        }
        lut_status.* = @intCast(delta);
    }

    /// 取 delta 对应 LUT 段（必要时重建）
    fn bgmcLutGetp(self: *Decoder, delta_in: u32) []const u8 {
        const slot_idx: u32 = std.math.clamp(delta_in, 0, LUT_BUFF - 1);
        const slot = self.bgmc_lut[@intCast(slot_idx * 16 * LUT_SIZE)..][0 .. 16 * LUT_SIZE];
        const status = &self.bgmc_lut_status[slot_idx];
        if (status.* != @as(i32, @intCast(delta_in))) {
            self.bgmcLutFillp(self.bgmc_lut[@intCast(slot_idx * 16 * LUT_SIZE)..][0 .. 16 * LUT_SIZE], status, delta_in);
        }
        return slot;
    }

    fn bgmcDecode(
        self: *Decoder,
        br: *BitReader,
        num: u32,
        dst_start: usize,
        delta_in: u32,
        sx_in: u32,
        h: *u32,
        l: *u32,
        v: *u32,
    ) Error!void {
        const lut = self.bgmcLutGetp(delta_in);
        const sx: usize = sx_in;
        var high = h.*;
        var low = l.*;
        var value = v.*;
        const lut_row = lut[sx * LUT_SIZE ..];

        var i: u32 = 0;
        while (i < num) : (i += 1) {
            const range: u32 = high -% low +% 1;
            const target: u32 = ((((value -% low +% 1) << 14) -% 1) / range);
            var symbol: u32 = @as(u32, lut_row[target >> (14 - LUT_BITS)]) << @intCast(delta_in);
            while (cfTableAt(sx, symbol) > target)
                symbol += @as(u32, 1) << @intCast(delta_in);

            symbol = (symbol >> @intCast(delta_in)) -% 1;

            high = low +% ((range *% @as(u32, cfTableAt(sx, symbol << @intCast(delta_in))) -% (@as(u32, 1) << 14)) >> 14);
            low = low +% ((range *% @as(u32, cfTableAt(sx, (symbol + 1) << @intCast(delta_in)))) >> 14);

            while (true) {
                if (high >= HALF) {
                    if (low >= HALF) {
                        value -%= HALF;
                        low -%= HALF;
                        high -%= HALF;
                    } else if (low >= FIRST_QTR and high < THIRD_QTR) {
                        value -%= FIRST_QTR;
                        low -%= FIRST_QTR;
                        high -%= FIRST_QTR;
                    } else break;
                }
                low *%= 2;
                high = 2 *% high +% 1;
                value = 2 *% value +% br.readBit();
            }
            self.raw_buf[dst_start + i] = @bitCast(symbol);
        }
        h.* = high;
        l.* = low;
        v.* = value;
    }

    /// ff_bgmc_decode_end：位游标回退 (VALUE_BITS-2)
    fn bgmcFinish(self: *Decoder, br: *BitReader) void {
        _ = self;
        const n: i64 = @as(i64, VALUE_BITS) - 2;
        if (br.pos >= @as(u64, @intCast(n))) {
            br.pos -= @intCast(n);
        } else {
            br.pos = 0;
        }
    }

    // ========================= LPC / 重建 =========================

    /// parcor_to_lpc（k、par、cof；i32 中间乘用 i64）
    fn parcorToLpc(k_in: u32, par: []const i32, cof: []i32) void {
        const k: i32 = @intCast(k_in);
        var i: i32 = 0;
        var j: i32 = k - 1;
        while (i < j) : ({
            i += 1;
            j -= 1;
        }) {
            const tmp1: i32 = @intCast(((@as(i64, par[k_in]) * @as(i64, cof[@intCast(j)]) + (@as(i64, 1) << 19)) >> 20));
            cof[@intCast(j)] +%= @intCast(((@as(i64, par[k_in]) * @as(i64, cof[@intCast(i)]) + (@as(i64, 1) << 19)) >> 20));
            cof[@intCast(i)] +%= tmp1;
        }
        if (i == j) {
            cof[@intCast(i)] +%= @intCast(((@as(i64, par[k_in]) * @as(i64, cof[@intCast(j)]) + (@as(i64, 1) << 19)) >> 20));
        }
        cof[k_in] = par[k_in];
    }

    /// decode_var_block_data
    fn decodeVarBlockData(self: *Decoder, bd: *const Block) Error!void {
        const sconf = &self.cfg;
        const block_length = bd.block_length;
        const slot = &self.slots[bd.slot];
        const opt_order = slot.opt_order;
        const qc = self.qcOf(bd.slot);
        const lc = self.lcOf(bd.slot);
        const raw = self.raw_buf;

        // ---- 反向 LTP ----
        if (slot.use_ltp) {
            const g = self.ltpGainOf(bd.slot);
            var ltp_smp: i64 = @max(@as(i64, @intCast(slot.ltp_lag)) - 2, 0);
            while (ltp_smp < block_length) : (ltp_smp += 1) {
                const center = ltp_smp - @as(i64, @intCast(slot.ltp_lag));
                const begin = @max(@as(i64, 0), center - 2);
                const end = center + 3;
                var tab: i64 = 5 - (end - begin);
                var y: i64 = 1 << 6;
                var base = begin;
                while (base < end) : ({
                    base += 1;
                    tab += 1;
                }) {
                    y += @as(i64, g[@intCast(tab)]) * @as(i64, raw[bd.rab + @as(usize, @intCast(base))]);
                }
                const idx: usize = bd.rab + @as(usize, @intCast(ltp_smp));
                raw[idx] +%= @intCast(y >> 7);
            }
        }

        var smp: u32 = 0;
        if (bd.ra_block) {
            var p = bd.rab;
            const n_first = @min(opt_order, block_length);
            while (smp < n_first) : (smp += 1) {
                var y: i64 = 1 << 19;
                var sb: u32 = 0;
                while (sb < smp) : (sb += 1) {
                    y += @as(i64, lc[sb]) * @as(i64, raw[p - 1 - sb]);
                }
                raw[p] -%= @intCast(y >> 20);
                parcorToLpc(smp, qc, lc);
                p += 1;
            }
        } else {
            var k: u32 = 0;
            while (k < opt_order) : (k += 1) {
                parcorToLpc(k, qc, lc);
            }
            if (slot.store_prev) {
                const hist = bd.rab - @as(usize, sconf.max_order);
                @memcpy(self.prev_raw[0..sconf.max_order], raw[hist..][0..sconf.max_order]);
            }
            if (slot.store_prev and bd.js_blocks) {
                // 差分信号历史：D = R - L 写入本声道历史
                if (bd.other_rab) |other| {
                    const lo = @min(bd.rab, other);
                    const hi = @max(bd.rab, other);
                    var sb: u32 = 0;
                    while (sb < sconf.max_order) : (sb += 1) {
                        const hi_idx = hi - 1 - sb;
                        const lo_idx = lo - 1 - sb;
                        const d = raw[hi_idx] -% raw[lo_idx];
                        raw[bd.rab - 1 - sb] = d;
                    }
                }
            }
            if (slot.shift_lsbs != 0) {
                var sb: u32 = 0;
                while (sb < sconf.max_order) : (sb += 1) {
                    raw[bd.rab - 1 - sb] >>= @intCast(slot.shift_lsbs);
                }
            }
        }

        // ---- 主重建循环（-y>>20 减预测）----
        var p = bd.rab + smp;
        const endp = bd.rab + block_length;
        while (p < endp) : (p += 1) {
            var y: i64 = 1 << 19;
            var j: u32 = 0;
            while (j < opt_order) : (j += 1) {
                y += @as(i64, lc[j]) * @as(i64, raw[p - 1 - j]);
            }
            raw[p] -%= @intCast(y >> 20);
        }

        if (slot.store_prev) {
            const hist = bd.rab - @as(usize, sconf.max_order);
            @memcpy(raw[hist..][0..sconf.max_order], self.prev_raw[0..sconf.max_order]);
        }
    }

    /// decode_block（重建常量/变量块 + shift_lsbs 左移）
    fn decodeBlock(self: *Decoder, bd: *Block) Error!void {
        const slot = &self.slots[bd.slot];
        if (slot.const_block) {
            self.decodeConstBlockData(bd);
        } else {
            try self.decodeVarBlockData(bd);
        }
        if (slot.shift_lsbs != 0) {
            var p = bd.rab;
            const end = bd.rab + bd.block_length;
            while (p < end) : (p += 1) {
                self.raw_buf[p] = @bitCast(@as(u32, @bitCast(self.raw_buf[p])) << @intCast(slot.shift_lsbs));
            }
        }
    }

    // ========================= 逐块解码路径 =========================

    fn zeroRemaining(self: *Decoder, b: u32, b_max: u32, div_blocks: []const u32, rab: usize) void {
        var count: usize = 0;
        var i = b;
        while (i < b_max) : (i += 1) count += div_blocks[i];
        var p = rab;
        var n: usize = count;
        while (n != 0) : (n -= 1) {
            self.raw_buf[p] = 0;
            p += 1;
        }
    }

    /// 读一块（不重建；mc_coding 批量路径用）
    fn readBlock(self: *Decoder, br: *BitReader, bd: *Block) Error!void {
        const sconf = &self.cfg;
        const slot = &self.slots[bd.slot];
        slot.shift_lsbs = 0;
        if (br.bitsLeft() < 7) return error.Corrupt;
        const var_block = br.readBit() != 0;
        if (var_block) {
            try self.readVarBlockData(br, bd);
        } else {
            try self.readConstBlockData(br, bd);
        }
        if (!sconf.mc_coding or self.js_switch) br.alignByte();
    }

    /// 读 + 重建一块（独立/配对路径）
    fn readDecodeBlock(self: *Decoder, br: *BitReader, bd: *Block) Error!void {
        const sconf = &self.cfg;
        const slot = &self.slots[bd.slot];
        slot.shift_lsbs = 0;
        if (br.bitsLeft() < 7) return error.Corrupt;
        const var_block = br.readBit() != 0;
        if (var_block) {
            try self.readVarBlockData(br, bd);
        } else {
            try self.readConstBlockData(br, bd);
        }
        if (!sconf.mc_coding or self.js_switch) br.alignByte();
        try self.decodeBlock(bd);
    }

    /// decode_blocks_ind：单声道逐块解码
    fn decodeBlocksInd(self: *Decoder, br: *BitReader, ra_frame: bool, c: usize, div_blocks: []const u32) Error!void {
        var bd = Block{ .block_length = 0, .ra_block = ra_frame, .slot = 0, .rab = self.chanBase(c) };
        var offset: usize = 0;
        var b: u32 = 0;
        while (b < self.num_blocks) : (b += 1) {
            bd.block_length = div_blocks[b];
            bd.rab = self.chanBase(c) + offset;
            self.readDecodeBlock(br, &bd) catch |err| {
                self.zeroRemaining(b, self.num_blocks, div_blocks, bd.rab);
                return err;
            };
            offset += div_blocks[b];
            bd.ra_block = false;
        }
    }

    /// decode_blocks：joint-stereo 配对
    fn decodeBlocks(self: *Decoder, br: *BitReader, ra_frame: bool, c: usize, div_blocks: []const u32) Error!void {
        var bd0 = Block{ .block_length = 0, .ra_block = ra_frame, .slot = 0, .rab = 0 };
        var bd1 = Block{ .block_length = 0, .ra_block = ra_frame, .slot = 0, .rab = 0 };
        var offset: usize = 0;
        var b: u32 = 0;
        while (b < self.num_blocks) : (b += 1) {
            const bl = div_blocks[b];
            bd0.block_length = bl;
            bd1.block_length = bl;
            bd0.rab = self.chanBase(c) + offset;
            bd1.rab = self.chanBase(c + 1) + offset;
            bd0.other_rab = bd1.rab;
            bd1.other_rab = bd0.rab;
            self.readDecodeBlock(br, &bd0) catch |err| return self.failPair(err, b, div_blocks, bd0.rab, bd1.rab);
            self.readDecodeBlock(br, &bd1) catch |err| return self.failPair(err, b, div_blocks, bd0.rab, bd1.rab);
            if (bd0.js_blocks) {
                var s: u32 = 0;
                while (s < bl) : (s += 1) {
                    self.raw_buf[bd0.rab + s] = self.raw_buf[bd1.rab + s] -% self.raw_buf[bd0.rab + s];
                }
            } else if (bd1.js_blocks) {
                var s: u32 = 0;
                while (s < bl) : (s += 1) {
                    self.raw_buf[bd1.rab + s] = self.raw_buf[bd1.rab + s] +% self.raw_buf[bd0.rab + s];
                }
            }
            offset += bl;
            bd0.ra_block = false;
            bd1.ra_block = false;
        }
        // carryover（声道 c 在此；声道 c+1 由调用方）
        self.storeCarryover(c);
    }

    fn failPair(self: *Decoder, err: Error, b: u32, div_blocks: []const u32, rab0: usize, rab1: usize) Error {
        self.zeroRemaining(b, self.num_blocks, div_blocks, rab0);
        self.zeroRemaining(b, self.num_blocks, div_blocks, rab1);
        return err;
    }

    /// 帧末：当前帧最后 max_order 样本移入声道头部 carryover 区
    fn storeCarryover(self: *Decoder, c: usize) void {
        const mo = self.cfg.max_order;
        if (mo == 0) return;
        const base = self.chanBase(c);
        const fr = self.cur_frame_length;
        std.mem.copyForwards(
            i32,
            self.raw_buf[base - mo .. base],
            self.raw_buf[base + fr - mo ..][0..mo],
        );
    }

    // ========================= mc_coding 多声道 =========================

    fn alsWeighting(self: *Decoder, br: *BitReader, k: u32, off: i32) Error!i32 {
        _ = self;
        const idx_i: i64 = @as(i64, decodeRice(br, k)) + off;
        const idx = std.math.clamp(idx_i, 0, @as(i64, tables.mcc_weightings.len - 1));
        return tables.mcc_weightings[@intCast(idx)];
    }

    fn readChannelData(self: *Decoder, br: *BitReader, cd: []ChanData, c: usize) Error!void {
        const channels = self.channels;
        var current: usize = 0;
        while (current < channels) : (current += 1) {
            cd[current].stop_flag = br.readBit() != 0;
            if (cd[current].stop_flag) break;
            cd[current].master_channel = br.readBitsLong(ceilLog2(@as(u32, @intCast(channels))));
            if (cd[current].master_channel >= channels) return error.Corrupt;
            if (cd[current].master_channel != c) {
                cd[current].time_diff_flag = br.readBit() != 0;
                cd[current].weighting[0] = try self.alsWeighting(br, 1, 16);
                cd[current].weighting[1] = try self.alsWeighting(br, 2, 14);
                cd[current].weighting[2] = try self.alsWeighting(br, 1, 16);
                if (cd[current].time_diff_flag) {
                    cd[current].weighting[3] = try self.alsWeighting(br, 1, 16);
                    cd[current].weighting[4] = try self.alsWeighting(br, 1, 16);
                    cd[current].weighting[5] = try self.alsWeighting(br, 1, 16);
                    cd[current].time_diff_sign = br.readBit() != 0;
                    cd[current].time_diff_index = br.readBitsLong(self.cfg.ltp_lag_length - 3) + 3;
                }
            }
        }
        if (current == channels) return error.Corrupt;
        br.alignByte();
    }

    /// 对单声道 c 叠加其 master 声道加权（revert_channel_correlation 的尾部循环）
    fn applyChannelCorr(self: *Decoder, bd_block_length: u32, offset: usize, c: usize) Error!void {
        const raw = self.raw_buf;
        const ch = self.chan_data[c];
        const rab = self.chanBase(c) + offset;
        var dep: usize = 0;
        while (!ch[dep].stop_flag) : (dep += 1) {
            if (ch[dep].master_channel == c) continue;
            const mrab = self.chanBase(ch[dep].master_channel) + offset;
            var begin: i64 = 1;
            var end: i64 = @as(i64, @intCast(bd_block_length)) - 1;
            var t: i64 = 0;
            if (ch[dep].time_diff_flag) {
                t = @as(i64, @intCast(ch[dep].time_diff_index));
                if (ch[dep].time_diff_sign) {
                    t = -t;
                    if (begin < t) return error.Corrupt;
                    begin -= t;
                } else {
                    if (end < t) return error.Corrupt;
                    end -= t;
                }
            }
            const w = ch[dep].weighting;
            var smp: i64 = begin;
            if (ch[dep].time_diff_flag) {
                while (smp < end) : (smp += 1) {
                    var y: i64 = 1 << 6;
                    y += @as(i64, w[0]) * @as(i64, raw[@intCast(@as(i64, @intCast(mrab)) + smp - 1)]);
                    y += @as(i64, w[1]) * @as(i64, raw[@intCast(@as(i64, @intCast(mrab)) + smp)]);
                    y += @as(i64, w[2]) * @as(i64, raw[@intCast(@as(i64, @intCast(mrab)) + smp + 1)]);
                    y += @as(i64, w[3]) * @as(i64, raw[@intCast(@as(i64, @intCast(mrab)) + smp - 1 + t)]);
                    y += @as(i64, w[4]) * @as(i64, raw[@intCast(@as(i64, @intCast(mrab)) + smp + t)]);
                    y += @as(i64, w[5]) * @as(i64, raw[@intCast(@as(i64, @intCast(mrab)) + smp + 1 + t)]);
                    raw[@intCast(@as(i64, @intCast(rab)) + smp)] +%= @intCast(y >> 7);
                }
            } else {
                while (smp < end) : (smp += 1) {
                    var y: i64 = 1 << 6;
                    y += @as(i64, w[0]) * @as(i64, raw[@intCast(@as(i64, @intCast(mrab)) + smp - 1)]);
                    y += @as(i64, w[1]) * @as(i64, raw[@intCast(@as(i64, @intCast(mrab)) + smp)]);
                    y += @as(i64, w[2]) * @as(i64, raw[@intCast(@as(i64, @intCast(mrab)) + smp + 1)]);
                    raw[@intCast(@as(i64, @intCast(rab)) + smp)] +%= @intCast(y >> 7);
                }
            }
        }
    }

    fn revertChannelCorrelation(self: *Decoder, bd_block_length: u32, offset: usize, c_in: usize) Error!void {
        const channels = self.channels;
        // 显式调用栈模拟 C 递归 revert_channel_correlation：先处理 master（后序），
        // 再对本声道叠加各 master 加权（reverted 数组跨外层 c 循环保持，每块重置）。
        const Action = struct { c: u32, post: bool };
        var acts = std.ArrayList(Action).empty;
        defer acts.deinit(self.allocator);
        try acts.append(self.allocator, .{ .c = @intCast(c_in), .post = false });
        while (acts.pop()) |a| {
            if (a.post) {
                try self.applyChannelCorr(bd_block_length, offset, a.c);
                continue;
            }
            if (self.reverted[a.c]) continue;
            self.reverted[a.c] = true;
            const ch = self.chan_data[a.c];
            var dep: usize = 0;
            while (dep < channels and !ch[dep].stop_flag) : (dep += 1) {}
            if (dep == channels) return error.Corrupt;
            try acts.append(self.allocator, .{ .c = a.c, .post = true });
            var d: usize = dep;
            while (d > 0) {
                d -= 1;
                const mc = ch[d].master_channel;
                if (!self.reverted[mc]) try acts.append(self.allocator, .{ .c = mc, .post = false });
            }
        }
    }

    /// mc_coding 整帧路径（decode_blocks 前读全声道 + read_channel_data）
    fn decodeMcFrame(self: *Decoder, br: *BitReader, ra_frame: bool) Error!void {
        const channels = self.channels;
        var div_blocks: [32]u32 = undefined;
        var bs_info: u32 = 0;
        var bd = Block{ .block_length = 0, .ra_block = ra_frame, .rab = 0 };
        var offset: usize = 0;

        self.getBlockSizes(br, div_blocks[0..32], &self.num_blocks, &bs_info);

        var b: u32 = 0;
        while (b < self.num_blocks) : (b += 1) {
            bd.block_length = div_blocks[b];
            if (bd.block_length == 0) continue;
            @memset(self.reverted, false);
            var c: usize = 0;
            while (c < channels) : (c += 1) {
                bd.slot = c;
                bd.rab = self.chanBase(c) + offset;
                bd.other_rab = null;
                try self.readBlock(br, &bd);
                try self.readChannelData(br, self.chan_data[c], c);
            }
            for (0..channels) |cc| {
                try self.revertChannelCorrelation(bd.block_length, offset, cc);
            }
            for (0..channels) |cc| {
                bd.slot = cc;
                bd.rab = self.chanBase(cc) + offset;
                try self.decodeBlock(&bd);
            }
            offset += bd.block_length;
            bd.ra_block = false;
        }
        for (0..channels) |cc| self.storeCarryover(cc);
    }

    // ========================= 帧装配 =========================

    /// 解码一帧；返回本帧样本数（null = 流尾/样本耗尽）
    pub fn decodeOne(self: *Decoder) Error!?u32 {
        const sconf = &self.cfg;
        if (sconf.samples != 0xFFFFFFFF) {
            const done = self.frame_id * sconf.frame_length;
            if (done >= sconf.samples) return null;
            self.cur_frame_length = @intCast(@min(sconf.samples - done, sconf.frame_length));
        } else {
            self.cur_frame_length = sconf.frame_length;
        }

        const ra_frame = sconf.ra_distance != 0 and (self.frame_id % sconf.ra_distance) == 0;
        const remaining_bytes = self.stream_len - self.stream_pos;
        if (remaining_bytes == 0) return null;

        const pad = self.stream[self.stream_pos ..];
        var br = BitReader.init(pad, @as(u64, remaining_bytes) * 8);
        try self.readFrameData(&br, ra_frame);
        self.frame_id += 1;

        const consumed_bytes: usize = @intCast(@min((br.pos + 7) >> 3, remaining_bytes));
        self.stream_pos += consumed_bytes;
        return self.cur_frame_length;
    }

    fn readFrameData(self: *Decoder, br: *BitReader, ra_frame: bool) Error!void {
        const sconf = &self.cfg;
        var div_blocks: [32]u32 = undefined;
        var js_blocks: [2]u32 = .{ 0, 0 };
        var bs_info: u32 = 0;
        const channels = self.channels;

        if (sconf.ra_flag == .frames and ra_frame) br.skip(32);

        if (sconf.mc_coding and sconf.joint_stereo) {
            self.js_switch = br.readBit() != 0;
            br.alignByte();
        }

        if (!sconf.mc_coding or self.js_switch) {
            var independent_bs: u32 = if (sconf.joint_stereo) 0 else 1;
            var c: usize = 0;
            while (c < channels) : (c += 1) {
                js_blocks[0] = 0;
                js_blocks[1] = 0;
                self.getBlockSizes(br, div_blocks[0..32], &self.num_blocks, &bs_info);

                if (sconf.joint_stereo and sconf.block_switching != 0) {
                    if ((bs_info >> 31) != 0) independent_bs = 2;
                }
                if (c == channels - 1 or (c & 1) != 0) independent_bs = 1;

                if (independent_bs != 0) {
                    try self.decodeBlocksInd(br, ra_frame, c, div_blocks[0..self.num_blocks]);
                    independent_bs -= 1;
                } else {
                    try self.decodeBlocks(br, ra_frame, c, div_blocks[0..self.num_blocks]);
                    c += 1;
                }
                self.storeCarryover(c);
            }
        } else {
            try self.decodeMcFrame(br, ra_frame);
        }

        if (sconf.floating) return error.UnsupportedFormat;
        if (br.pos > br.limit_bits) return error.Corrupt;
    }

    /// 交错输出当前帧样本 [start_sample, start_sample+count) 到 out
    pub fn interleaveOut(self: *Decoder, out: []u8, start_sample: usize, count: usize) void {
        const sconf = &self.cfg;
        const channels = self.channels;
        const bps = sconf.bits_per_raw_sample;
        const shift: u5 = @intCast(if (bps <= 16) 16 - bps else 32 - bps);
        const base = self.chanBase(0);
        var o: usize = 0;
        if (bps <= 16) {
            var s: usize = 0;
            while (s < count) : (s += 1) {
                for (0..channels) |c| {
                    const idx = base + c * self.channel_size + start_sample + s;
                    const v: u32 = @as(u32, @bitCast(self.raw_buf[idx])) << shift;
                    std.mem.writeInt(u16, @ptrCast(out[o..][0..2]), @truncate(v), .little);
                    o += 2;
                }
            }
        } else {
            var s: usize = 0;
            while (s < count) : (s += 1) {
                for (0..channels) |c| {
                    const idx = base + c * self.channel_size + start_sample + s;
                    const v: u32 = @as(u32, @bitCast(self.raw_buf[idx])) << shift;
                    std.mem.writeInt(u32, @ptrCast(out[o..][0..4]), v, .little);
                    o += 4;
                }
            }
        }
    }
};

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------
const testing = std.testing;

test "parseConfig 拒绝非 ALS（AOT 非 36）" {
    const dsi = [_]u8{ 0x11, 0x90, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    try testing.expectError(error.UnsupportedFormat, parseConfig(&dsi));
}

// 512ch conformance（als_09）端到端 core 解码 == ffmpeg（整数无损，整轨 MD5 + 前缀逐字节）。
test "als core: 512ch（mcc+bgmc+块切换+RA）解码 == ffmpeg（bit-exact MD5+前缀）" {
    const dsi = @embedFile("samples/als09.dsi");
    const frames = @embedFile("samples/als09.frames");
    const pre = @embedFile("samples/als09_prefix.s16");
    const cfg = try parseConfig(dsi);
    try testing.expectEqual(@as(u32, 512), cfg.channels);
    try testing.expectEqual(@as(u32, 2000), cfg.sample_rate);
    try testing.expect(cfg.mc_coding and cfg.bgmc and cfg.joint_stereo);

    const alloc = testing.allocator;
    const padded = try alloc.alloc(u8, frames.len + 64);
    defer alloc.free(padded);
    @memcpy(padded[0..frames.len], frames);
    @memset(padded[frames.len..], 0);

    var dec = try Decoder.init(alloc, cfg, padded, frames.len);
    defer dec.deinit();

    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    while (true) {
        const n = try dec.decodeOne() orelse break;
        const start = out.items.len;
        try out.appendNTimes(alloc, 0, @as(usize, n) * cfg.channels * 2);
        dec.interleaveOut(out.items[start..], 0, n);
    }
    // 全轨 s16le 长度（ffmpeg golden）
    try testing.expectEqual(@as(usize, 3154944), out.items.len);

    // 全轨 MD5（ffmpeg golden：ac53ff89954a54d02c3f8d686f70c054）
    const md5 = @import("../ac3/md5.zig").Md5;
    var got: [16]u8 = undefined;
    md5.hash(out.items, &got, .{});
    try testing.expectEqualSlices(
        u8,
        &.{ 0xac, 0x53, 0xff, 0x89, 0x95, 0x4a, 0x54, 0xd0, 0x2c, 0x3f, 0x8d, 0x68, 0x6f, 0x70, 0xc0, 0x54 },
        &got,
    );
    // 前缀逐字节
    try testing.expectEqualSlices(u8, pre, out.items[0..pre.len]);
}

test "als core: parseConfig 短/空 dsi 返回 UnsupportedFormat（不 panic）" {
    try testing.expectError(error.UnsupportedFormat, parseConfig(""));
    try testing.expectError(error.UnsupportedFormat, parseConfig("ALS"));
}
