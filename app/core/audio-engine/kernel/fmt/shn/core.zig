// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Shorten (.shn, 无损) 解码核心（逐句对齐 FFmpeg n9.0.1 libavcodec/shorten.c）。
//!
//! 语义要点（纯整数、无浮点）：
//!   - 位流为 **MSB-first**（GetBitContext 默认大端位序，与 TTA 的 LE 相反）；
//!   - Rice 码用 get_ur_golomb_jpegls(limit=INT_MAX, esc_len=0) 语义：
//!     unary 前缀（数 0 直到 1，1 被消耗）+ k 位二进制后缀（MSB-first）；
//!     符号版 get_sr_golomb_shorten 用 k+1 位参数 + zigzag 映射
//!     （(u>>1) ^ -(u&1)，uint32 回绕域）；
//!   - 固定预测（FN_DIFF0..3，阶 0-3）与 FN_QLPC（系数 get_sr_golomb_shorten
//!     (LPCQUANT=5) 定点量化，qshift=5，v2+ 预测加 lpcqoffset=32）；
//!   - 溢出/符号语义完全复刻 C：int32/uint32 回绕、算术右移、
//!     coffset/means 的混合 unsigned 加法 + 有符号除法向零取整；
//!   - 命令流：每命令 get_ur_golomb_shorten(FNSIZE=2) 读函数码；
//!     is_audio_command = {1,1,1,1,0,0,0,1,1,0}；块 = channels 个音频命令
//!     （每命令一通道）→ 输出一帧交错 PCM；未知命令 = 本块中止复位重来
//!     （与 ffmpeg 分包 decode 调用语义逐位等价，见 nextBlock）。
//!
//! EOF 边界：越界读按零填充（GetBitContext 缓冲零填充语义），
//! bit_pos 可越过 size_in_bits（get_bits_left 可为负，与 C 一致）。

const std = @import("std");
const Error = @import("../../error.zig").Error;

// ---- shorten.c 常量 ----

pub const MAX_CHANNELS: usize = 8;
pub const MAX_BLOCKSIZE: usize = 65535;

const ULONGSIZE: u32 = 2;
const WAVE_FORMAT_PCM: u16 = 0x0001;
const DEFAULT_BLOCK_SIZE: usize = 256;

const TYPESIZE: u32 = 4;
const CHANSIZE: u32 = 0;
const LPCQSIZE: u32 = 2;
const ENERGYSIZE: u32 = 3;
const BITSHIFTSIZE: u32 = 2;

const TYPE_U8: u32 = 2;
const TYPE_S16HL: u32 = 3;
const TYPE_S16LH: u32 = 5;

const NWRAP: usize = 3;
const NSKIPSIZE: u32 = 1;
const LPCQUANT: u5 = 5;
const V2LPCQOFFSET: i32 = 1 << LPCQUANT;

const FNSIZE: u32 = 2;
const FN_DIFF0: u32 = 0;
const FN_DIFF1: u32 = 1;
const FN_DIFF2: u32 = 2;
const FN_DIFF3: u32 = 3;
const FN_QUIT: u32 = 4;
const FN_BLOCKSIZE: u32 = 5;
const FN_BITSHIFT: u32 = 6;
const FN_QLPC: u32 = 7;
const FN_ZERO: u32 = 8;
const FN_VERBATIM: u32 = 9;

/// indicates if the FN_* command is audio or non-audio（shorten.c 静态表）
const is_audio_command = [10]u1{ 1, 1, 1, 1, 0, 0, 0, 1, 1, 0 };

const VERBATIM_CKSIZE_SIZE: u32 = 5;
const VERBATIM_BYTE_SIZE: u32 = 8;
const CANONICAL_HEADER_SIZE: usize = 44;
const OUT_BUFFER_SIZE: usize = 16384;

/// fixed_coeffs[4][3]（shorten.c 静态表：阶 0-3 固定预测系数）
const fixed_coeffs = [4][3]i32{
    .{ 0, 0, 0 },
    .{ 1, 0, 0 },
    .{ 2, -1, 0 },
    .{ 3, -3, 1 },
};

// ---- MSB-first 位读取（GetBitContext 语义）----

/// MSB-first 位读取器。越界（超过 data 末尾）读 0（零填充语义），
/// bit_pos 继续前进（get_bits_left 可为负，复刻 C）。
pub const BitReader = struct {
    data: []const u8,
    bit_pos: u64 = 0,

    pub fn init(data: []const u8) BitReader {
        return .{ .data = data };
    }

    pub fn totalBits(self: *const BitReader) u64 {
        return self.data.len * 8;
    }

    /// get_bits_left：可为负（越界后）。
    pub fn bitsLeft(self: *const BitReader) i64 {
        return @as(i64, @intCast(self.totalBits())) - @as(i64, @intCast(self.bit_pos));
    }

    /// get_bits1：越界返回 0（零填充），位置继续前进。
    pub fn readBit(self: *BitReader) u1 {
        const byte_idx = self.bit_pos >> 3;
        const b: u8 = if (byte_idx < self.data.len) self.data[byte_idx] else 0;
        const bit: u1 = @intCast((b >> @intCast(7 - (self.bit_pos & 7))) & 1);
        self.bit_pos += 1;
        return bit;
    }

    /// get_bits_long（0..=32），MSB-first。越界读 0。
    pub fn readBits(self: *BitReader, k: u32) u32 {
        var out: u32 = 0;
        var i: u32 = 0;
        while (i < k) : (i += 1) {
            out = (out << 1) | self.readBit();
        }
        return out;
    }

    /// get_ur_golomb_jpegls(gb, k, INT_MAX, 0) 的慢路径语义：
    /// 数连续 0 直到首个 1（1 被消耗）；若位流耗尽（bits_left ≤ 0）停止；
    /// 之后读 k 位后缀。返回 (i << k) + suffix（uint32 回绕域）。
    pub fn getURJpegLS(self: *BitReader, k: u32) u32 {
        var i: u32 = 0;
        while (true) {
            // limit = INT_MAX：i < limit 恒真
            const bit = self.readBit();
            if (bit == 1) break;
            if (self.bitsLeft() <= 0) break;
            i += 1;
        }
        const suffix = self.readBits(k);
        return (i << @intCast(k)) +% suffix;
    }

    /// get_ur_golomb_shorten(gb, k) = get_ur_golomb_jpegls(k, INT_MAX, 0)
    pub fn getURShorten(self: *BitReader, k: u32) u32 {
        return self.getURJpegLS(k);
    }

    /// get_sr_golomb_shorten(gb, k)：
    ///   uvar = get_ur_golomb_jpegls(k + 1, INT_MAX, 0);
    ///   return (uvar >> 1) ^ -(uvar & 1);   // zigzag（uint32 回绕域）
    pub fn getSRShorten(self: *BitReader, k: u32) i32 {
        const uvar = self.getURJpegLS(k + 1);
        const neg: u32 = 0 -% (uvar & 1);
        return @bitCast((uvar >> 1) ^ neg);
    }
};

// ---- 输出样本类型 ----

pub const SampleType = enum {
    /// TYPE_U8：u8（av_clip_uint8）
    u8,
    /// TYPE_S16HL / TYPE_S16LH：s16（av_clip_int16；AIFF-C swap 为值字节交换）
    s16,
};

/// 解码器（流式状态机；seek = 重建实例后快进，见 lib.zig）。
pub const Decoder = struct {
    a: std.mem.Allocator,
    data: []const u8, // 借用：整个文件
    br: BitReader,

    // ShortenContext 等价状态
    channels: usize = 0,
    version: i32 = 0,
    internal_ftype: u32 = 0,
    nmean: i32 = -1,
    nwrap: usize = NWRAP,
    blocksize: usize = DEFAULT_BLOCK_SIZE,
    bitshift: i32 = 0,
    cur_chan: usize = 0,
    lpcqoffset: i32 = 0,
    got_header: bool = false,
    got_quit_command: bool = false,
    swap: bool = false,
    sample_type: SampleType = .s16,
    sample_rate: u32 = 0,

    decoded_base: [MAX_CHANNELS]?[]i32 = [_]?[]i32{null} ** MAX_CHANNELS,
    offset: [MAX_CHANNELS]?[]i32 = [_]?[]i32{null} ** MAX_CHANNELS,
    coeffs: []i32 = &.{},

    phase: enum { need_header, decoding, done, failed } = .need_header,

    pub fn init(a: std.mem.Allocator, data: []const u8) Decoder {
        return .{ .a = a, .data = data, .br = BitReader.init(data) };
    }

    /// 仅解析流头（read_header）；open 时即时调用以填充 Info。
    pub fn parseHeader(self: *Decoder) Error!void {
        if (self.phase == .need_header) {
            self.readHeader() catch |e| {
                self.phase = .failed;
                return e;
            };
        }
    }

    pub fn deinit(self: *Decoder) void {
        for (&self.decoded_base) |*d| {
            if (d.*) |buf| self.a.free(buf);
            d.* = null;
        }
        for (&self.offset) |*o| {
            if (o.*) |buf| self.a.free(buf);
            o.* = null;
        }
        if (self.coeffs.len > 0) self.a.free(self.coeffs);
        self.coeffs = &.{};
        self.phase = .failed;
    }

    /// get_uint（shorten.c）：version != 0 时 k 先以 ULONGSIZE 位从流读出
    /// （k > 31 → AVERROR_INVALIDDATA；下游范围检查亦必失败，归 Corrupt）。
    fn getUint(self: *Decoder, k: u32) Error!u32 {
        var kk = k;
        if (self.version != 0) {
            kk = self.br.getURShorten(ULONGSIZE);
            if (kk > 31) return error.Corrupt;
        }
        return self.br.getURShorten(kk);
    }

    /// allocate_buffers（shorten.c；blocksize 经 FN_BLOCKSIZE 只缩不增，
    /// 按头内初始 blocksize 分配一次）
    fn allocateBuffers(self: *Decoder) Error!void {
        const nblock: usize = @intCast(@max(1, self.nmean));
        for (0..self.channels) |chan| {
            if (self.decoded_base[chan] == null) {
                self.decoded_base[chan] = self.a.alloc(i32, self.blocksize + self.nwrap) catch return error.OutOfMemory;
                @memset(self.decoded_base[chan].?[0..self.nwrap], 0);
            }
            if (self.offset[chan] == null) {
                self.offset[chan] = self.a.alloc(i32, nblock) catch return error.OutOfMemory;
            }
        }
        if (self.coeffs.len == 0) {
            self.coeffs = self.a.alloc(i32, self.nwrap) catch return error.OutOfMemory;
        }
    }

    /// init_offset（shorten.c）：均值初始化 + 样本类型判定
    fn initOffset(self: *Decoder) Error!void {
        var mean: i32 = 0;
        switch (self.internal_ftype) {
            TYPE_U8 => {
                self.sample_type = .u8;
                mean = 0x80;
            },
            TYPE_S16HL, TYPE_S16LH => {
                self.sample_type = .s16;
            },
            else => return error.UnsupportedFormat, // "unknown audio type"（PATCHWELCOME）
        }
        const nblock: usize = @intCast(@max(1, self.nmean));
        for (0..self.channels) |chan| {
            const off = self.offset[chan].?;
            for (0..nblock) |i| off[i] = mean;
        }
    }

    /// fix_bitshift（shorten.c）：buffer[i] *= 1U << bitshift（uint32 回绕域）
    fn fixBitshift(self: *Decoder, buffer: []i32) void {
        if (self.bitshift == 32) {
            for (0..self.blocksize) |i| buffer[i] = 0;
        } else if (self.bitshift != 0) {
            const m: u32 = @as(u32, 1) << @intCast(self.bitshift);
            for (0..self.blocksize) |i|
                buffer[i] = @bitCast(@as(u32, @bitCast(buffer[i])) *% m);
        }
    }

    /// decode_aiff_header（shorten.c；bytestream2 越界读 0 语义以内联
    /// 长度检查等价实现——canonical 头（≥44 字节）路径逐位一致）
    fn decodeAiffHeader(self: *Decoder, header: []const u8) Error!void {
        var gb = header;
        if (gb.len < 4) return error.Corrupt;
        if (readLe32(&gb) != mktag("FORM")) return error.Corrupt; // missing FORM tag
        if (gb.len < 4) return error.Corrupt;
        gb = gb[4..]; // chunk size

        const tag_val = readLe32(&gb);
        const aiff_tag = mktag("AIFF");
        const aifc_tag = mktag("AIFC");
        if (tag_val != aiff_tag and tag_val != aifc_tag) return error.Corrupt; // missing AIFF tag

        const comm_tag = mktag("COMM");
        while (true) {
            if (gb.len < 4) return error.Corrupt; // no COMM chunk found
            const t = readLe32(&gb);
            if (t == comm_tag) break;
            const len = readBe32s(&gb);
            if (len < 0 or gb.len < 18 + @as(usize, @intCast(len)) + (@as(usize, @intCast(len)) & 1))
                return error.Corrupt; // no COMM chunk found
            gb = gb[(@as(usize, @intCast(len)) + (@as(usize, @intCast(len)) & 1))..];
        }
        if (gb.len < 4) return error.Corrupt;
        const len = readBe32s(&gb);
        if (len < 18) return error.Corrupt; // COMM chunk was too short

        if (gb.len < 6 + 2 + 8) return error.Corrupt;
        gb = gb[6..]; // skip numChannels/numSampleFrames 高位（C 只 skip 6 后读 bps）
        const bps = std.mem.readInt(u16, gb[0..2], .big);
        gb = gb[2..];
        self.swap = tag_val == aifc_tag;
        if (bps != 16 and bps != 8) return error.UnsupportedFormat; // ENOSYS

        const exp_raw = std.mem.readInt(u16, gb[0..2], .big);
        gb = gb[2..];
        const val = std.mem.readInt(u64, gb[0..8], .big);
        gb = gb[8..];
        const exp: i32 = @as(i32, exp_raw) - 16383 - 63;
        if (exp < -63 or exp > 63) return error.Corrupt; // exp out of range
        if (exp >= 0)
            self.sample_rate = @truncate(val << @intCast(exp))
        else
            self.sample_rate = @truncate((val +% (@as(u64, 1) << @intCast(-exp - 1))) >> @intCast(-exp));
    }

    /// decode_wave_header（shorten.c）
    fn decodeWaveHeader(self: *Decoder, header: []const u8) Error!void {
        var gb = header;
        if (gb.len < 4) return error.Corrupt;
        if (readLe32(&gb) != mktag("RIFF")) return error.Corrupt; // missing RIFF tag
        if (gb.len < 4) return error.Corrupt;
        gb = gb[4..]; // chunk size
        if (gb.len < 4) return error.Corrupt;
        if (readLe32(&gb) != mktag("WAVE")) return error.Corrupt; // missing WAVE tag

        const fmt_tag = mktag("fmt ");
        while (true) {
            if (gb.len < 4) return error.Corrupt; // no fmt chunk found
            const t = readLe32(&gb);
            if (t == fmt_tag) break;
            if (gb.len < 4) return error.Corrupt;
            const len: i32 = @bitCast(readLe32(&gb));
            // bytestream2_skip 先执行（size 为 unsigned，负值钳制到末尾），再检查
            const skip: usize = if (len < 0) gb.len else @min(gb.len, @as(usize, @intCast(len)));
            gb = gb[skip..];
            if (len < 0 or gb.len < 16) return error.Corrupt; // no fmt chunk found
        }
        const len: i32 = @bitCast(readLe32(&gb));
        if (len < 16) return error.Corrupt; // fmt chunk was too short
        if (gb.len < 2 + 2 + 4 + 4 + 2 + 2) return error.Corrupt;
        const wave_format = std.mem.readInt(u16, gb[0..2], .little);
        gb = gb[2..]; // wave_format
        if (wave_format != WAVE_FORMAT_PCM) return error.UnsupportedFormat; // unsupported wave format
        gb = gb[2..]; // skip channels（已从 shorten 头取得）
        self.sample_rate = std.mem.readInt(u32, gb[0..4], .little);
        gb = gb[4..]; // sample_rate
        gb = gb[4..]; // skip bit rate（原始未压缩码率）
        gb = gb[2..]; // skip block align
        const bps = std.mem.readInt(u16, gb[0..2], .little);
        gb = gb[2..];
        if (bps != 16 and bps != 8) return error.UnsupportedFormat; // ENOSYS
    }

    /// read_header（shorten.c）
    fn readHeader(self: *Decoder) Error!void {
        // shorten signature（get_bits_long(32) != AV_RB32("ajkg")）
        if (self.br.readBits(32) != std.mem.readInt(u32, "ajkg", .big))
            return error.Corrupt; // missing shorten magic 'ajkg'

        self.lpcqoffset = 0;
        self.blocksize = DEFAULT_BLOCK_SIZE;
        self.nmean = -1;
        self.version = @bitCast(self.br.readBits(8));
        self.internal_ftype = try self.getUint(TYPESIZE);

        self.channels = try self.getUint(CHANSIZE);
        if (self.channels == 0) return error.Corrupt; // No channels reported
        if (self.channels > MAX_CHANNELS) return error.Corrupt; // too many channels

        // get blocksize if version > 0
        var maxnlpc: usize = 0;
        if (self.version > 0) {
            const blocksize = try self.getUint(avLog2(DEFAULT_BLOCK_SIZE));
            if (blocksize == 0 or blocksize > MAX_BLOCKSIZE) return error.Corrupt; // invalid block size
            self.blocksize = blocksize;

            maxnlpc = try self.getUint(LPCQSIZE);
            if (maxnlpc > 1024) return error.Corrupt; // maxnlpc too large
            self.nmean = @bitCast(try self.getUint(0));
            // C: if (s->nmean > 32768U) —— int 提升为 unsigned 比较
            if (@as(u32, @bitCast(self.nmean)) > 32768) return error.Corrupt; // nmean too large

            const skip_bytes = try self.getUint(NSKIPSIZE);
            // C: (unsigned)skip_bytes > FFMAX(get_bits_left, 0)/8
            if (@as(u64, skip_bytes) > (self.br.totalBits() -| self.br.bit_pos) / 8)
                return error.Corrupt; // invalid skip_bytes
            self.br.bit_pos += @as(u64, skip_bytes) * 8;
        }
        self.nwrap = @max(NWRAP, maxnlpc);

        if (self.version > 1)
            self.lpcqoffset = V2LPCQOFFSET;

        // verbatim section at beginning of stream
        if (self.br.getURShorten(FNSIZE) != FN_VERBATIM)
            return error.Corrupt; // missing verbatim section

        const header_size = self.br.getURShorten(VERBATIM_CKSIZE_SIZE);
        if (header_size >= OUT_BUFFER_SIZE or header_size < CANONICAL_HEADER_SIZE)
            return error.Corrupt; // header is wrong size

        var header: [OUT_BUFFER_SIZE]u8 = undefined;
        for (0..header_size) |i|
            header[i] = @truncate(self.br.getURShorten(VERBATIM_BYTE_SIZE));

        const hdr = header[0..header_size];
        // C: AV_RL32(s->header) == MKTAG('R','I','F','F')（内存序 LE 比较）
        if (std.mem.eql(u8, hdr[0..4], "RIFF")) {
            try self.decodeWaveHeader(hdr);
        } else if (std.mem.eql(u8, hdr[0..4], "FORM")) {
            try self.decodeAiffHeader(hdr);
        } else {
            return error.UnsupportedFormat; // unsupported bit packing
        }

        try self.allocateBuffers();
        try self.initOffset();

        self.cur_chan = 0;
        self.bitshift = 0;
        self.got_header = true;
        self.phase = .decoding;
    }

    /// decode_subframe_lpc（shorten.c）
    fn decodeSubframeLpc(self: *Decoder, command: u32, channel: usize, residual_size: u32, coffset: i32) Error!void {
        var pred_order: usize = 0;
        var qshift: u5 = 0;
        var coeffs: []const i32 = &.{};
        var coeffs_buf: [3]i32 = undefined;

        if (command == FN_QLPC) {
            // read/validate prediction order
            const po = self.br.getURShorten(LPCQSIZE);
            if (po > self.nwrap) return error.Corrupt; // invalid pred_order
            pred_order = po;
            // read LPC coefficients
            for (0..pred_order) |i|
                self.coeffs[i] = self.br.getSRShorten(LPCQUANT);
            coeffs = self.coeffs[0..pred_order];
            qshift = LPCQUANT;
        } else {
            // fixed LPC coeffs
            pred_order = command;
            if (pred_order >= fixed_coeffs.len) return error.Corrupt; // invalid pred_order
            coeffs_buf[0] = fixed_coeffs[pred_order][0];
            coeffs_buf[1] = fixed_coeffs[pred_order][1];
            coeffs_buf[2] = fixed_coeffs[pred_order][2];
            coeffs = coeffs_buf[0..pred_order];
            qshift = 0;
        }

        const dec = self.decoded_base[channel].?; // decoded = base + nwrap
        const nwrap = self.nwrap;
        const coffset_u: u32 = @bitCast(coffset);

        // subtract offset from previous samples to use in prediction
        // C: for (i = -pred_order; i < 0; i++) decoded[i] -= (unsigned)coffset
        if (command == FN_QLPC and coffset != 0) {
            var i: usize = nwrap - pred_order;
            while (i < nwrap) : (i += 1)
                dec[i] = @bitCast(@as(u32, @bitCast(dec[i])) -% coffset_u);
        }

        // decode residual and do LPC prediction
        // init_sum = pred_order ? (QLPC ? lpcqoffset : 0) : coffset
        const init_sum: i32 = if (pred_order != 0)
            (if (command == FN_QLPC) self.lpcqoffset else 0)
        else
            coffset;
        var i: usize = 0;
        while (i < self.blocksize) : (i += 1) {
            // sum += coeffs[j] * (unsigned)decoded[i-j-1]：uint32 回绕域
            var sum: u32 = @bitCast(init_sum);
            for (0..pred_order) |j|
                sum = sum +% @as(u32, @bitCast(coeffs[j])) *% @as(u32, @bitCast(dec[nwrap + i - j - 1]));
            const residual = self.br.getSRShorten(residual_size);
            // decoded[i] = residual + (unsigned)(sum >> qshift)：
            // sum 为 int32_t，`sum >> qshift` 是**算术**右移（负和符号扩展），
            // 再转 unsigned 与 residual 回绕相加
            const sum_i: i32 = @bitCast(sum);
            dec[nwrap + i] = @bitCast(@as(u32, @bitCast(residual)) +% @as(u32, @bitCast(sum_i >> qshift)));
        }

        // add offset to current samples
        // C: for (i = 0; i < blocksize; i++) decoded[i] += (unsigned)coffset
        if (command == FN_QLPC and coffset != 0) {
            for (0..self.blocksize) |k|
                dec[nwrap + k] = @bitCast(@as(u32, @bitCast(dec[nwrap + k])) +% coffset_u);
        }
    }

    /// 解码下一个完整块（channels 个音频命令），交错写入 out。
    /// out 长度必须 ≥ 初始 blocksize * channels * sampleWidth。
    /// 返回 true = 输出一块；false = 流结束（QUIT / 位流耗尽）。
    /// 致命错误（ffmpeg 中止解码的情形）以 Error 返回。
    ///
    /// 与 ffmpeg 分包语义的等价性：ffmpeg 每次 decode 调用复位 cur_chan=0
    /// 并处理命令直到帧完成/位不足；未知命令只中止本块（位置已推进），
    /// 下一次调用复位后继续。整文件缓冲下逐位等价于本循环：
    /// 未知命令 → cur_chan=0 后继续读下一命令。
    pub fn nextBlock(self: *Decoder, out: []u8) Error!bool {
        try self.parseHeader();
        if (self.phase != .decoding)
            return false;

        while (self.cur_chan < self.channels) {
            if (self.br.bitsLeft() < 3 + FNSIZE) {
                // 位流耗尽且块不完整 → 无更多输出（EOF）
                self.phase = .done;
                return false;
            }

            const cmd = self.br.getURShorten(FNSIZE);

            if (cmd > FN_VERBATIM) {
                // unknown shorten function：本块中止，复位通道重来
                self.cur_chan = 0;
                continue;
            }

            if (is_audio_command[cmd] == 0) {
                // process non-audio command
                switch (cmd) {
                    FN_VERBATIM => {
                        const len = self.br.getURShorten(VERBATIM_CKSIZE_SIZE);
                        // C: len < 0 || len > get_bits_left（BITS）
                        if (@as(i64, len) > self.br.bitsLeft()) return error.Corrupt; // verbatim length invalid
                        var n = len;
                        while (n > 0) : (n -= 1)
                            _ = self.br.getURShorten(VERBATIM_BYTE_SIZE);
                    },
                    FN_BITSHIFT => {
                        const bs = self.br.getURShorten(BITSHIFTSIZE);
                        if (bs > 32) return error.Corrupt; // bitshift invalid
                        self.bitshift = @bitCast(bs);
                    },
                    FN_BLOCKSIZE => {
                        const bs = try self.getUint(avLog2(self.blocksize));
                        if (bs > self.blocksize)
                            return error.UnsupportedFormat; // Increasing blocksize（missing feature）
                        if (bs == 0 or bs > MAX_BLOCKSIZE) return error.Corrupt; // invalid block size
                        self.blocksize = bs;
                    },
                    FN_QUIT => {
                        self.got_quit_command = true;
                    },
                    else => {},
                }
                if (cmd == FN_QUIT) {
                    self.phase = .done;
                    return false;
                }
            } else {
                // process audio command
                var residual_size: u32 = 0;
                const channel = self.cur_chan;
                var coffset: i32 = undefined;

                // get Rice code parameter for residual decoding
                if (cmd != FN_ZERO) {
                    residual_size = self.br.getURShorten(ENERGYSIZE);
                    // version 0 的 get_sr_golomb_shorten 定义差异 hack
                    if (self.version == 0) residual_size -%= 1;
                    if (residual_size > 30) return error.Corrupt; // residual size unsupported
                }

                // calculate sample offset using means from previous blocks
                if (self.nmean == 0) {
                    coffset = self.offset[channel].?[0];
                } else {
                    // sum 为 int32：unsigned 加法回绕
                    var sum: i32 = if (self.version < 2) 0 else @divTrunc(self.nmean, 2);
                    const off = self.offset[channel].?;
                    var mi: usize = 0;
                    while (mi < self.nmean) : (mi += 1)
                        sum = @bitCast(@as(u32, @bitCast(sum)) +% @as(u32, @bitCast(off[mi])));
                    coffset = @divTrunc(sum, self.nmean);
                    if (self.version >= 2) {
                        // C: coffset = bitshift == 0 ? coffset : coffset >> bitshift-1 >> 1
                        if (self.bitshift != 0) {
                            const sh: u5 = @intCast(self.bitshift - 1);
                            coffset = coffset >> sh >> 1;
                        }
                    }
                }

                // decode samples for this channel
                if (cmd == FN_ZERO) {
                    const dec = self.decoded_base[channel].?;
                    @memset(dec[self.nwrap .. self.nwrap + self.blocksize], 0);
                } else {
                    try self.decodeSubframeLpc(cmd, channel, residual_size, coffset);
                }

                // update means with info from the current block
                if (self.nmean > 0) {
                    var sum: i64 = if (self.version < 2) 0 else @as(i64, @intCast(self.blocksize / 2));
                    const dec = self.decoded_base[channel].?;
                    for (0..self.blocksize) |si|
                        sum += dec[self.nwrap + si];

                    const off = self.offset[channel].?;
                    var mi: usize = 1;
                    while (mi < self.nmean) : (mi += 1)
                        off[mi - 1] = off[mi];

                    if (self.version < 2) {
                        off[@intCast(self.nmean - 1)] = @truncate(@divTrunc(sum, @as(i64, @intCast(self.blocksize))));
                    } else {
                        // C: (sum / blocksize) * (1LL << bitshift)，bitshift==32 → 0
                        off[@intCast(self.nmean - 1)] = if (self.bitshift == 32)
                            0
                        else
                            @truncate(@divTrunc(sum, @as(i64, @intCast(self.blocksize))) * (@as(i64, 1) << @intCast(self.bitshift)));
                    }
                }

                // copy wrap samples for use with next block
                // C: for (i = -nwrap; i < 0; i++) decoded[i] = decoded[i + blocksize]
                //   即 base[i] = base[blocksize + i]（升序，源索引恒大于目标）
                {
                    const dec = self.decoded_base[channel].?;
                    for (0..self.nwrap) |wi|
                        dec[wi] = dec[self.blocksize + wi];
                }

                // shift samples to add in unused zero bits
                self.fixBitshift(self.decoded_base[channel].?[self.nwrap..]);

                // if this is the last channel in the block, output the samples
                self.cur_chan += 1;
                if (self.cur_chan == self.channels) {
                    self.emitFrame(out);
                    self.cur_chan = 0; // 下一「decode 调用」复位
                    return true;
                }
            }
        }
        return false;
    }

    /// 输出一帧（planar → 交错、clip、AIFF-C swap），对齐 ffmpeg
    /// s16p/u8p frame → `-f s16le` / `-f u8`（planar→packed）输出。
    fn emitFrame(self: *Decoder, out: []u8) void {
        const chs = self.channels;
        const bs = self.blocksize;
        switch (self.sample_type) {
            .u8 => {
                for (0..bs) |i| {
                    for (0..chs) |chan| {
                        const v = self.decoded_base[chan].?[self.nwrap + i];
                        out[i * chs + chan] = clipU8(v);
                    }
                }
            },
            .s16 => {
                for (0..bs) |i| {
                    for (0..chs) |chan| {
                        const v = clipS16(self.decoded_base[chan].?[self.nwrap + i]);
                        const sv: u16 = if (self.swap) @byteSwap(@as(u16, @bitCast(v))) else @bitCast(v);
                        std.mem.writeInt(u16, out[(i * chs + chan) * 2 ..][0..2], sv, .little);
                    }
                }
            },
        }
    }

    /// 每样本字节数（1 = u8，2 = s16）
    pub fn sampleWidth(self: *const Decoder) usize {
        return switch (self.sample_type) {
            .u8 => 1,
            .s16 => 2,
        };
    }
};

/// MKTAG(a,b,c,d)（bytestream2 le32 标签比较值）
fn mktag(s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .little);
}

fn readLe32(g: *[]const u8) u32 {
    const v = std.mem.readInt(u32, g.*[0..4], .little);
    g.* = g.*[4..];
    return v;
}

fn readBe32s(g: *[]const u8) i32 {
    const v = std.mem.readInt(u32, g.*[0..4], .big);
    g.* = g.*[4..];
    return @bitCast(v);
}

pub fn clipU8(v: i32) u8 {
    if (v < 0) return 0;
    if (v > 255) return 255;
    return @intCast(v);
}

pub fn clipS16(v: i32) i16 {
    if (v < -32768) return -32768;
    if (v > 32767) return 32767;
    return @intCast(v);
}

/// av_log2（非零输入；C 对 0 返回 0）
pub fn avLog2(v: usize) u32 {
    if (v == 0) return 0;
    return 31 - @as(u32, @clz(@as(u32, @intCast(v))));
}

// ---------------------------------------------------------------------------
// 单元测试（golomb/位读取对齐 ffmpeg 语义）
// ---------------------------------------------------------------------------

const testing = std.testing;

test "BitReader: MSB-first 读位/读多位" {
    var br = BitReader.init(&[_]u8{ 0b10110001, 0b11110000 });
    try testing.expectEqual(@as(u1, 1), br.readBit());
    try testing.expectEqual(@as(u1, 0), br.readBit());
    try testing.expectEqual(@as(u32, 0b110001111), br.readBits(9));
    try testing.expectEqual(@as(u32, 0b1), br.readBits(1));
    try testing.expectEqual(@as(u32, 0), br.readBits(0));
}

test "BitReader: getURJpegLS Rice 码（unary + k 位后缀）" {
    // k=0：值 n 编码为 n 个 0 + 终止 1；0x20 = 00 1 00000 → 值 2
    var br = BitReader.init(&[_]u8{0b00100000});
    try testing.expectEqual(@as(u32, 2), br.getURJpegLS(0));
    // k=2：0x60 = 0 1 10 → i=1, suffix=0b10=2 → (1<<2)+2 = 6
    var br2 = BitReader.init(&[_]u8{0b01100000});
    try testing.expectEqual(@as(u32, 6), br2.getURJpegLS(2));
    // k=2：0xF8 = 1 11 → i=0, suffix=0b11=3 → 3
    var br3 = BitReader.init(&[_]u8{0b11111000});
    try testing.expectEqual(@as(u32, 3), br3.getURJpegLS(2));
    // k=2：跨字节 0x04 0x80 = 000001 00 1... → i=5, suffix=0b00 → (5<<2)+0 = 20
    var br4 = BitReader.init(&[_]u8{ 0x04, 0x80 });
    try testing.expectEqual(@as(u32, 20), br4.getURJpegLS(2));
}

test "BitReader: getSRShorten zigzag（(u>>1) ^ -(u&1)，k+1 位参数）" {
    // k=0：uvar = getUR(1)。
    // uvar=0 → 0：位 1（终止）+ 后缀 0 → 0x80
    var br0 = BitReader.init(&[_]u8{0b10000000});
    try testing.expectEqual(@as(i32, 0), br0.getSRShorten(0));
    // uvar=1 → -1：位 1 + 后缀 1 → 0xC0
    var br1 = BitReader.init(&[_]u8{0b11000000});
    try testing.expectEqual(@as(i32, -1), br1.getSRShorten(0));
    // uvar=2 → +1：位 0 1 + 后缀 0 → 0x40
    var br2 = BitReader.init(&[_]u8{0b01000000});
    try testing.expectEqual(@as(i32, 1), br2.getSRShorten(0));
    // uvar=3 → -2：位 0 1 + 后缀 1 → 0x60
    var br3 = BitReader.init(&[_]u8{0b01100000});
    try testing.expectEqual(@as(i32, -2), br3.getSRShorten(0));
    // uvar=4 → +2：位 0 0 1 + 后缀 0 → 0x20
    var br4 = BitReader.init(&[_]u8{0b00100000});
    try testing.expectEqual(@as(i32, 2), br4.getSRShorten(0));
    // uvar=5 → -3：位 0 0 1 + 后缀 1 → 0x30
    var br5 = BitReader.init(&[_]u8{0b00110000});
    try testing.expectEqual(@as(i32, -3), br5.getSRShorten(0));
    // k=1：uvar = getUR(2)；0xF8 = 1 + 后缀 11 → uvar=3 → -2
    var br6 = BitReader.init(&[_]u8{0b11111000});
    try testing.expectEqual(@as(i32, -2), br6.getSRShorten(1));
}

test "BitReader: EOF 零填充语义（越界读 0，bits_left 为负）" {
    var br = BitReader.init(&[_]u8{0b10000000});
    // 终止 1 立即出现：i=0，后缀 0 位 → 值 0
    try testing.expectEqual(@as(u32, 0), br.getURJpegLS(0));
    try testing.expectEqual(@as(i64, 7), br.bitsLeft());
    // 越界：读 0
    _ = br.readBits(10);
    try testing.expectEqual(@as(i64, -3), br.bitsLeft());
    try testing.expectEqual(@as(u32, 0), br.getURJpegLS(0)); // 全 0 → bits_left ≤ 0 停止，i=0
}

test "avLog2 对齐 ffmpeg" {
    try testing.expectEqual(@as(u32, 8), avLog2(256));
    try testing.expectEqual(@as(u32, 0), avLog2(0));
    try testing.expectEqual(@as(u32, 0), avLog2(1));
    try testing.expectEqual(@as(u32, 5), avLog2(32));
    try testing.expectEqual(@as(u32, 5), avLog2(63));
}

test "clip 对齐 av_clip_uint8 / av_clip_int16" {
    try testing.expectEqual(@as(u8, 0), clipU8(-1));
    try testing.expectEqual(@as(u8, 255), clipU8(300));
    try testing.expectEqual(@as(u8, 128), clipU8(128));
    try testing.expectEqual(@as(i16, -32768), clipS16(-40000));
    try testing.expectEqual(@as(i16, 32767), clipS16(40000));
    try testing.expectEqual(@as(i16, -1), clipS16(-1));
}
