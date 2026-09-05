//! DTS（DCA Coherent Acoustics）core → PCM 解码（阶段二）
//!
//! 主线对照 FFmpeg dca_core.c 的 parse_frame_header / parse_coding_header /
//! parse_subframe_header / parse_subframe_audio / parse_frame_data（位级一致）+
//! filter_frame_fixed / ff_dca_core_filter_fixed（定点合成，整数逐句一致）。
//!
//! 位流：MSB-first，输入 frame 须为已还原的 BE16 字节（LE16 字交换在 lib 层完成）。
//! 输出：与 `ffmpeg -bitexact -f s32le` 对齐的 24-bit<<8 S32 平面
//! （声道序 = ffmpeg 默认 remap 序）。定点路径全部整数运算 → bit-exact。
//!
//! 范围：core 主声道（mono/stereo/3.0/2.1/3.1/2.2/5.0/5.1 + LFE 64x）+ CSS X96
//! （DTS 96/24：core 帧内 X96 扩展 64 子带数据 + 64-band 合成 → 96k 采样率；
//!   含 LFE 96k 二次插值）；X96 合成亦供 DTS-HD MA 192k XLL 残余上混使用
//!   （96k core 输入，见 lib.decodePayloadToS16）。
//! 附加声道：CSS XCH（DTS-ES 6.1：core 帧内 0x5A5A5A5A 扩展 + Cs，含 es_format
//!   嵌入 XCH 降混撤销）与 CSS/EXSS XXCH（speaker mask 声道组 + 附加声道
//!   dmix 撤销），以及 EXSS X96（parse_x96_frame_exss 多声道组）——对照
//!   dca_core.c parse_xch_frame / parse_xxch_frame / parse_x96_frame_exss 与
//!   ff_dca_core_parse_exss。LBR 未实现；LFE 128x 定点模式 FFmpeg 亦不支持。
//! 14-bit 打包与阶段一一致不支持。

const std = @import("std");
const BitReader = @import("../aac/bitreader.zig").BitReader;
const huff = @import("huff.zig");
const dsp = @import("dsp.zig");
const dt = @import("dca_tables.zig");
const t = @import("tables.zig");

pub const DCA_CHANNELS: usize = 7;
pub const DCA_SUBBANDS: usize = 32;
pub const DCA_SUBBANDS_X96: usize = 64;
pub const DCA_SUBFRAMES: usize = 16;
pub const DCA_LFE_HISTORY: usize = 8;
pub const DCA_ABITS_MAX: i32 = 26;
pub const CODE_BOOKS: usize = 10;
const ADPCM_COEFFS: usize = dsp.DCA_ADPCM_COEFFS;

pub const ext_audio_xch: u8 = 0;
pub const ext_audio_x96: u8 = 2;
pub const ext_audio_xxch: u8 = 6;

// ---- 扩展位掩码（dca.h DCA_CSS_* / DCA_EXSS_*，core 解码状态 ext_audio_mask）----
pub const css_core: u16 = 0x001;
pub const css_xxch: u16 = 0x002;
pub const css_x96: u16 = 0x004;
pub const css_xch: u16 = 0x008;
pub const exss_core: u16 = 0x010;
pub const exss_xbr: u16 = 0x020;
pub const exss_xxch: u16 = 0x040;
pub const exss_x96: u16 = 0x080;
pub const exss_lbr: u16 = 0x100;
pub const exss_xll: u16 = 0x200;

/// XXCH 声道组上限（dca_core.h DCA_XXCH_CHANNELS_MAX=2）与 dmix 数组尺寸
pub const xxch_channels_max: usize = 2;
pub const xxch_dmix_coeff_max: usize = xxch_channels_max * 6;

/// core 扩展声道编码头类型（dca_core.c HeaderType）
const HdrType = enum(u2) { core, xch, xxch };

/// 一个已解码帧的平面（值 = 定点 24bit 样本，即 ffmpeg 定点路径 clip23(sample)
/// 左移 8 位前的原始范围；输出时 ×256 即为 s32le）。平面缓冲属解码器所有，
/// 下次 decode 前有效。
pub const DecodedFrame = struct {
    /// 每声道样本数（npcmblocks × 32）
    nsamples: usize,
    /// 输出声道数
    nch: usize,
    /// 采样率
    sample_rate: u32,
    /// 每输出平面样本（nsamples 个 i32）
    planes: [8][]const i32,
    /// 每输出平面对应扬声器位（dca speaker 枚举位，见 tables.zig speaker_*）
    speaker: [8]u8,
};

pub const DcaDecoder = struct {
    alloc: std.mem.Allocator,

    // ---- 帧头（随帧更新）----
    npcmblocks: usize = 0,
    nsubframes: u8 = 0,
    nchannels: u8 = 0,
    audio_mode: u8 = 0,
    ch_mask: u32 = 0,
    sample_rate: u32 = 0,
    bit_rate: u32 = 0,
    lfe_present: u8 = 0,
    predictor_history: bool = false,
    filter_perfect: bool = false,
    sumdiff_front: bool = false,
    sumdiff_surround: bool = false,
    crc_present: bool = false,
    drc_present: bool = false,
    sync_ssf: bool = false,
    ext_audio_type: u8 = 0,
    ext_audio_present: bool = false,
    frame_size: usize = 0,
    source_pcm_res: u8 = 0,
    es_format: bool = false,

    // ---- core 帧内扩展（CSS）与 EXSS 附加声道状态 ----
    ext_audio_mask: u16 = 0,
    xch_pos: usize = 0,
    xxch_pos: usize = 0,
    xxch_crc_present: bool = false,
    xxch_mask_nbits: u8 = 0,
    xxch_core_mask: u32 = 0,
    xxch_spkr_mask: u32 = 0,
    xxch_dmix_embedded: bool = false,
    xxch_dmix_scale_inv: i32 = 0,
    xxch_dmix_mask: [xxch_channels_max]u32 = [_]u32{0} ** xxch_channels_max,
    xxch_dmix_coeff: [xxch_dmix_coeff_max]i32 = [_]i32{0} ** xxch_dmix_coeff_max,

    // ---- 主声道编码头 ----
    nsubbands: [DCA_CHANNELS]u8 = [_]u8{0} ** DCA_CHANNELS,
    subband_vq_start: [DCA_CHANNELS]u8 = [_]u8{0} ** DCA_CHANNELS,
    joint_intensity_index: [DCA_CHANNELS]u8 = [_]u8{0} ** DCA_CHANNELS,
    transition_mode_sel: [DCA_CHANNELS]u8 = [_]u8{0} ** DCA_CHANNELS,
    scale_factor_sel: [DCA_CHANNELS]u8 = [_]u8{0} ** DCA_CHANNELS,
    bit_allocation_sel: [DCA_CHANNELS]u8 = [_]u8{0} ** DCA_CHANNELS,
    quant_index_sel: [DCA_CHANNELS][CODE_BOOKS]u8 = [_][CODE_BOOKS]u8{[_]u8{0} ** CODE_BOOKS} ** DCA_CHANNELS,
    scale_factor_adj: [DCA_CHANNELS][CODE_BOOKS]i32 = [_][CODE_BOOKS]i32{[_]i32{0} ** CODE_BOOKS} ** DCA_CHANNELS,

    // ---- 子帧 side info ----
    nsubsubframes: [DCA_SUBFRAMES]u8 = [_]u8{0} ** DCA_SUBFRAMES,
    prediction_mode: [DCA_CHANNELS][DCA_SUBBANDS_X96]bool = undefined,
    prediction_vq_index: [DCA_CHANNELS][DCA_SUBBANDS_X96]u16 = undefined,
    bit_allocation: [DCA_CHANNELS][DCA_SUBBANDS_X96]i16 = undefined,
    transition_mode: [DCA_SUBFRAMES][DCA_CHANNELS][DCA_SUBBANDS]u8 = undefined,
    scale_factors: [DCA_CHANNELS][DCA_SUBBANDS][2]i32 = undefined,
    joint_scale_sel: [DCA_CHANNELS]u8 = [_]u8{0} ** DCA_CHANNELS,
    joint_scale_factors: [DCA_CHANNELS][DCA_SUBBANDS_X96]i32 = undefined,

    // ---- 子带样本缓冲（跨帧持久）----
    row_len: usize = 0,
    rows: []i32 = &.{},
    band: [DCA_CHANNELS][DCA_SUBBANDS][]i32 = undefined,
    lfe_rows: []i32 = &.{},

    // ---- X96（96k/192k core 合成）扩展子带缓冲（跨帧持久）----
    x96_row_len: usize = 0,
    x96_rows: []i32 = &.{},
    x96_band: [DCA_CHANNELS][DCA_SUBBANDS_X96][]i32 = undefined,

    // ---- 合成滤波器历史（跨帧持久）----
    hist1: [DCA_CHANNELS][1024]i32 = [_][1024]i32{[_]i32{0} ** 1024} ** DCA_CHANNELS,
    hist2: [DCA_CHANNELS][32]i32 = [_][32]i32{[_]i32{0} ** 32} ** DCA_CHANNELS,
    offset: [DCA_CHANNELS]u9 = [_]u9{0} ** DCA_CHANNELS,
    hist2_x96: [DCA_CHANNELS][64]i32 = [_][64]i32{[_]i32{0} ** 64} ** DCA_CHANNELS,
    offset_x96: [DCA_CHANNELS]u10 = [_]u10{0} ** DCA_CHANNELS,
    lfe_history_x96: i32 = 0,
    /// 上一帧合成模式（true = 64-band）；切换时清空 DSP 历史（对齐 ffmpeg）
    filter_x96_mode: bool = false,

    // ---- X96 扩展状态（随帧更新）----
    x96_pos: usize = 0,
    x96_rev_no: u8 = 0,
    x96_crc_present: bool = false,
    x96_high_res: bool = false,
    x96_subband_start: u8 = 0,
    x96_nchannels: u8 = 0,
    x96_rand: u32 = 1,
    /// 当前帧已成功解析 X96 子带数据
    x96_active: bool = false,

    // ---- 输出平面缓冲（跨帧复用）----
    outbuf: []i32 = &.{},
    /// 最近一帧按扬声器位的输出平面（内部 scratch，下次 decode 前有效）
    speaker_planes: [32]?[]const i32 = [_]?[]const i32{null} ** 32,

    pub fn init(alloc: std.mem.Allocator) DcaDecoder {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *DcaDecoder) void {
        if (self.rows.len != 0) self.alloc.free(self.rows);
        if (self.lfe_rows.len != 0) self.alloc.free(self.lfe_rows);
        if (self.x96_rows.len != 0) self.alloc.free(self.x96_rows);
        if (self.outbuf.len != 0) self.alloc.free(self.outbuf);
        self.rows = &.{};
        self.lfe_rows = &.{};
        self.x96_rows = &.{};
        self.outbuf = &.{};
    }

    fn refreshBandSlices(self: *DcaDecoder) void {
        for (0..DCA_CHANNELS) |ch| {
            for (0..DCA_SUBBANDS) |b| {
                const base = (ch * DCA_SUBBANDS + b) * self.row_len;
                self.band[ch][b] = self.rows[base .. base + self.row_len];
            }
        }
    }

    fn refreshX96BandSlices(self: *DcaDecoder) void {
        for (0..DCA_CHANNELS) |ch| {
            for (0..DCA_SUBBANDS_X96) |b| {
                const base = (ch * DCA_SUBBANDS_X96 + b) * self.x96_row_len;
                self.x96_band[ch][b] = self.x96_rows[base .. base + self.x96_row_len];
            }
        }
    }

    fn allocX96SampleBuffer(self: *DcaDecoder) !void {
        const new_row = ADPCM_COEFFS + self.npcmblocks;
        if (self.x96_rows.len == 0 or self.x96_row_len != new_row) {
            if (self.x96_rows.len != 0) self.alloc.free(self.x96_rows);
            self.x96_row_len = new_row;
            self.x96_rows = try self.alloc.alloc(i32, DCA_CHANNELS * DCA_SUBBANDS_X96 * new_row);
            @memset(self.x96_rows, 0);
            self.refreshX96BandSlices();
        }
    }

    fn allocSampleBuffer(self: *DcaDecoder) !void {
        const new_row = ADPCM_COEFFS + self.npcmblocks;
        if (self.rows.len == 0 or self.row_len != new_row) {
            if (self.rows.len != 0) self.alloc.free(self.rows);
            self.row_len = new_row;
            self.rows = try self.alloc.alloc(i32, DCA_CHANNELS * DCA_SUBBANDS * new_row);
            @memset(self.rows, 0);
            self.refreshBandSlices();
        }
        const nlf = DCA_LFE_HISTORY + self.npcmblocks / 2;
        if (self.lfe_rows.len != nlf) {
            if (self.lfe_rows.len != 0) self.alloc.free(self.lfe_rows);
            self.lfe_rows = try self.alloc.alloc(i32, nlf);
            @memset(self.lfe_rows, 0);
        }
        const need = 8 * self.npcmblocks * dsp.DCA_PCMBLOCK_SAMPLES;
        if (self.outbuf.len < need) {
            if (self.outbuf.len != 0) self.alloc.free(self.outbuf);
            self.outbuf = try self.alloc.alloc(i32, need);
        }
    }

    pub fn eraseAdpcmHistory(self: *DcaDecoder) void {
        for (0..DCA_CHANNELS) |ch| {
            for (0..DCA_SUBBANDS) |b| {
                @memset(self.band[ch][b][0..ADPCM_COEFFS], 0);
            }
        }
    }

    pub fn eraseX96AdpcmHistory(self: *DcaDecoder) void {
        for (0..DCA_CHANNELS) |ch| {
            for (0..DCA_SUBBANDS_X96) |b| {
                @memset(self.x96_band[ch][b][0..ADPCM_COEFFS], 0);
            }
        }
    }

    inline fn bandData(self: *DcaDecoder, ch: usize, band: usize) []i32 {
        const row = self.band[ch][band];
        return row[ADPCM_COEFFS .. ADPCM_COEFFS + self.npcmblocks];
    }

    inline fn x96BandData(self: *DcaDecoder, ch: usize, band: usize) []i32 {
        const row = self.x96_band[ch][band];
        return row[ADPCM_COEFFS .. ADPCM_COEFFS + self.npcmblocks];
    }

    /// 解码一帧（兼容路径 = parseCore + 可选 CSS X96/XCH/XXCH 解析 + 合成）。
    /// frame：该 core 帧完整字节（BE16，含 sync，长度=frame_size）。
    pub fn decode(self: *DcaDecoder, frame: []const u8, out: *DecodedFrame) !void {
        try self.parseCore(frame);
        try self.parseCoreExssXbr(frame, null, 0, 0, 0, 0, 0, 0, 0, false);
        try self.filter(out, self.x96_active);
    }

    /// 仅解析 core 帧（帧头 + 子帧数据 + 扩展 sync 定位），不合成。
    /// 供 DTS-HD 容器逐访问单元管线使用：先解析 core 与 XLL 帧，
    /// 再决定 X96 合成（core 96k 输入）后调用 filter()。
    pub fn parseCore(self: *DcaDecoder, frame: []const u8) !void {
        self.ext_audio_mask = 0;
        self.xch_pos = 0;
        self.xxch_pos = 0;
        self.x96_pos = 0;
        var br = BitReader.init(frame);
        try self.parseFrameHeader(&br);
        try self.allocSampleBuffer();
        if (!self.predictor_history) self.eraseAdpcmHistory();
        try self.parseFrameData(&br, .core, 0);
        try self.detectExtensions(frame, br.bit_pos);
    }

    // ======================================================================
    // 5.3.1 帧头（dca.c ff_dca_parse_core_frame_header）
    // ======================================================================
    fn parseFrameHeader(self: *DcaDecoder, br: *BitReader) !void {
        if ((try br.readBits(32)) != t.syncword_core_be) return error.Sync;
        _ = try br.readBits(1); // normal_frame
        if ((try br.readBits(5)) + 1 != t.pcmblock_samples) return error.Unsupported;

        self.crc_present = (try br.readBits(1)) != 0;
        self.npcmblocks = @intCast((try br.readBits(7)) + 1);
        self.frame_size = @as(usize, @intCast(try br.readBits(14))) + 1;
        self.audio_mode = @intCast(try br.readBits(6));
        const sr_code: u8 = @intCast(try br.readBits(4));
        self.sample_rate = t.sample_rates[sr_code];
        self.bit_rate = t.bit_rates[@intCast(try br.readBits(5))];
        _ = try br.readBits(1); // reserved
        self.drc_present = (try br.readBits(1)) != 0;
        _ = try br.readBits(1); // ts_present
        _ = try br.readBits(1); // aux_present
        _ = try br.readBits(1); // hdcd_master
        self.ext_audio_type = @intCast(try br.readBits(3));
        self.ext_audio_present = (try br.readBits(1)) != 0;
        self.sync_ssf = (try br.readBits(1)) != 0;
        self.lfe_present = @intCast(try br.readBits(2));
        self.predictor_history = (try br.readBits(1)) != 0;
        if (self.crc_present) _ = try br.readBits(16);
        self.filter_perfect = (try br.readBits(1)) != 0;
        _ = try br.readBits(4); // encoder_rev
        _ = try br.readBits(2); // copy_hist
        const pcmr_code: u8 = @intCast(try br.readBits(3));
        self.sumdiff_front = (try br.readBits(1)) != 0;
        self.sumdiff_surround = (try br.readBits(1)) != 0;
        _ = try br.readBits(4); // dn_code

        self.source_pcm_res = t.bits_per_sample[pcmr_code];
        self.es_format = pcmr_code & 1 != 0;

        self.ch_mask = audio_mode_ch_mask[self.audio_mode];
        if (self.lfe_present != 0) self.ch_mask |= t.speaker_lfe1;
    }

    // ======================================================================
    // 5.3.2 主声道编码头（parse_coding_header；HEADER_CORE / XCH / XXCH）
    // ======================================================================
    fn parseCodingHeader(self: *DcaDecoder, br: *BitReader, header: HdrType, xch_base: usize) !void {
        const header_pos = br.bit_pos;
        var header_size: usize = 0;

        switch (header) {
            .core => {
                self.nsubframes = @intCast((try br.readBits(4)) + 1);
                self.nchannels = @intCast((try br.readBits(3)) + 1);
                if (self.nchannels != t.channels_by_amode[self.audio_mode]) return error.Invalid;
                self.ch_mask = audio_mode_ch_mask[self.audio_mode];
                if (self.lfe_present != 0) self.ch_mask |= t.speaker_lfe1;
            },
            .xch => {
                self.nchannels = t.channels_by_amode[self.audio_mode] + 1;
                self.ch_mask |= t.speaker_cs;
            },
            .xxch => {
                // 声道组头长度
                header_size = @intCast((try br.readBits(7)) + 1);
                // 声道数（本组）
                const nch = @as(u8, @intCast(try br.readBits(3))) + 1;
                if (nch > xxch_channels_max) return error.Unsupported;
                self.nchannels = t.channels_by_amode[self.audio_mode] + nch;
                if (self.nchannels > DCA_CHANNELS) return error.Invalid;

                // 扬声器布局掩码（高位段，自 Cs 起）
                const mask: u32 = try br.readBits(@intCast(self.xxch_mask_nbits - 6));
                self.xxch_spkr_mask = mask << 6;
                if (popcount(self.xxch_spkr_mask) != nch) return error.Invalid;
                if (self.xxch_core_mask & self.xxch_spkr_mask != 0) return error.Invalid;
                self.ch_mask = self.xxch_core_mask | self.xxch_spkr_mask;

                // 流中已嵌 dmix 系数
                if ((try br.readBits(1)) != 0) {
                    self.xxch_dmix_embedded = (try br.readBits(1)) != 0;
                    const scale_code: u32 = try br.readBits(6);
                    const index: i64 = @as(i64, scale_code) * 4 - dt.FF_DCA_DMIXTABLE_OFFSET - 3;
                    if (index < 0 or index >= dt.FF_DCA_INV_DMIXTABLE_SIZE) return error.Invalid;
                    self.xxch_dmix_scale_inv = @intCast(dt.ff_dca_inv_dmixtable[@intCast(index)]);
                    for (0..nch) |ch| {
                        const m: u32 = try br.readBits(@intCast(self.xxch_mask_nbits));
                        if (m & ~self.xxch_core_mask != 0) return error.Invalid;
                        self.xxch_dmix_mask[ch] = m;
                    }
                    var ci: usize = 0;
                    for (0..nch) |ch| {
                        for (0..self.xxch_mask_nbits) |n| {
                            if (self.xxch_dmix_mask[ch] & (@as(u32, 1) << @intCast(n)) != 0) {
                                const code7: u32 = try br.readBits(7);
                                const sign: i32 = @as(i32, @intCast(code7 >> 6)) - 1;
                                const code: u32 = code7 & 63;
                                if (code != 0) {
                                    const di: usize = @intCast(code * 4 - 3);
                                    if (di >= dt.FF_DCA_DMIXTABLE_SIZE) return error.Invalid;
                                    const tval: i32 = @intCast(dt.ff_dca_dmixtable[di]);
                                    self.xxch_dmix_coeff[ci] = (tval ^ sign) -% sign;
                                } else {
                                    self.xxch_dmix_coeff[ci] = 0;
                                }
                                ci += 1;
                            }
                        }
                    }
                } else {
                    self.xxch_dmix_embedded = false;
                }
            },
        }

        for (xch_base..self.nchannels) |ch| {
            self.nsubbands[ch] = @intCast((try br.readBits(5)) + 2);
            if (self.nsubbands[ch] > DCA_SUBBANDS) return error.Invalid;
        }
        for (xch_base..self.nchannels) |ch| self.subband_vq_start[ch] = @intCast((try br.readBits(5)) + 1);
        for (xch_base..self.nchannels) |ch| {
            var n = try br.readBits(3);
            if (header == .xxch and n != 0) n += @intCast(xch_base - 1);
            if (n > self.nchannels) return error.Invalid;
            self.joint_intensity_index[ch] = @intCast(n);
        }
        for (xch_base..self.nchannels) |ch| self.transition_mode_sel[ch] = @intCast(try br.readBits(2));
        for (xch_base..self.nchannels) |ch| {
            self.scale_factor_sel[ch] = @intCast(try br.readBits(3));
            if (self.scale_factor_sel[ch] == 7) return error.Invalid;
        }
        for (xch_base..self.nchannels) |ch| {
            self.bit_allocation_sel[ch] = @intCast(try br.readBits(3));
            if (self.bit_allocation_sel[ch] == 7) return error.Invalid;
        }
        for (0..CODE_BOOKS) |n| {
            for (xch_base..self.nchannels) |ch| {
                self.quant_index_sel[ch][n] = @intCast(try br.readBits(@intCast(dt.ff_dca_quant_index_sel_nbits[n])));
            }
        }
        for (0..CODE_BOOKS) |n| {
            for (xch_base..self.nchannels) |ch| {
                if (self.quant_index_sel[ch][n] < dt.ff_dca_quant_index_group_size[n]) {
                    self.scale_factor_adj[ch][n] = @intCast(dt.ff_dca_scale_factor_adj[try br.readBits(2)]);
                }
            }
        }

        if (header == .xxch) {
            // Reserved + 字节对齐 + 声道组头 CRC16
            return self.seekBits(br, header_pos + header_size * 8);
        } else if (self.crc_present) {
            _ = try br.readBits(16); // 音频头 CRC 校验字
        }
    }

    fn seekBits(self: *DcaDecoder, br: *BitReader, bit_pos: usize) !void {
        _ = self;
        if (bit_pos < br.bit_pos) return error.Invalid;
        try br.skipBits(@intCast(bit_pos - br.bit_pos));
    }

    fn parseScale(self: *DcaDecoder, br: *BitReader, scale_index: *i32, sel: u8) !i32 {
        _ = self;
        const scale_table: []const u32 = if (sel > 5)
            &dt.ff_dca_scale_factor_quant7
        else
            &dt.ff_dca_scale_factor_quant6;
        var idx: i32 = undefined;
        if (sel < 5) {
            scale_index.* += @as(i32, try huff.decode(&huff.scalef_tables[sel], br));
            idx = scale_index.*;
        } else {
            idx = @intCast(try br.readBits(@intCast(sel + 1)));
            scale_index.* = idx;
        }
        if (idx < 0 or idx >= scale_table.len) return error.Invalid;
        return @intCast(scale_table[@intCast(idx)]);
    }

    fn parseJointScale(self: *DcaDecoder, br: *BitReader, sel: u8) !i32 {
        _ = self;
        var idx: i32 = undefined;
        if (sel < 5) {
            idx = @as(i32, try huff.decode(&huff.scalef_tables[sel], br));
        } else {
            idx = @intCast(try br.readBits(@intCast(sel + 1)));
        }
        idx += 64;
        if (idx < 0 or idx >= 129) return error.Invalid;
        return @intCast(dt.ff_dca_joint_scale_factors[@intCast(idx)]);
    }

    // ======================================================================
    // 5.4.1 子帧 side info（parse_subframe_header；header 参数控制 XCH/XXCH）
    // ======================================================================
    fn parseSubframeHeader(self: *DcaDecoder, br: *BitReader, sf: usize, header: HdrType, xch_base: usize) !void {
        if (header == .core) {
            self.nsubsubframes[sf] = @intCast((try br.readBits(2)) + 1);
            _ = try br.readBits(3); // 部分子子帧样本数（不解析）
        }

        for (xch_base..self.nchannels) |ch| {
            for (0..self.nsubbands[ch]) |band| {
                self.prediction_mode[ch][band] = (try br.readBits(1)) != 0;
            }
        }
        for (xch_base..self.nchannels) |ch| {
            for (0..self.nsubbands[ch]) |band| {
                if (self.prediction_mode[ch][band])
                    self.prediction_vq_index[ch][band] = @intCast(try br.readBits(12));
            }
        }

        for (xch_base..self.nchannels) |ch| {
            const sel = self.bit_allocation_sel[ch];
            for (0..self.subband_vq_start[ch]) |band| {
                var abits: i32 = undefined;
                if (sel < 5) {
                    abits = @as(i32, try huff.decode(&huff.bitalloc_tables[sel], br));
                } else {
                    abits = @intCast(try br.readBits(@intCast(sel - 1)));
                }
                if (abits > DCA_ABITS_MAX) return error.Invalid;
                self.bit_allocation[ch][band] = @intCast(abits);
            }
        }

        for (xch_base..self.nchannels) |ch| {
            @memset(&self.transition_mode[sf][ch], 0);
            if (self.nsubsubframes[sf] > 1) {
                const sel = self.transition_mode_sel[ch];
                for (0..self.subband_vq_start[ch]) |band| {
                    if (self.bit_allocation[ch][band] != 0)
                        self.transition_mode[sf][ch][band] = @intCast(try huff.decode(&huff.tmode_tables[sel], br));
                }
            }
        }

        for (xch_base..self.nchannels) |ch| {
            const sel = self.scale_factor_sel[ch];
            var scale_index: i32 = 0;
            for (0..self.subband_vq_start[ch]) |band| {
                if (self.bit_allocation[ch][band] != 0) {
                    self.scale_factors[ch][band][0] = try self.parseScale(br, &scale_index, sel);
                    if (self.transition_mode[sf][ch][band] != 0) {
                        self.scale_factors[ch][band][1] = try self.parseScale(br, &scale_index, sel);
                    }
                } else {
                    self.scale_factors[ch][band][0] = 0;
                }
            }
            for (self.subband_vq_start[ch]..self.nsubbands[ch]) |band| {
                self.scale_factors[ch][band][0] = try self.parseScale(br, &scale_index, sel);
            }
        }

        for (xch_base..self.nchannels) |ch| {
            if (self.joint_intensity_index[ch] != 0) {
                const jsel = try br.readBits(3);
                if (jsel == 7) return error.Invalid;
                self.joint_scale_sel[ch] = @intCast(jsel);
            }
        }
        for (xch_base..self.nchannels) |ch| {
            const src_ch_i: i32 = @as(i32, self.joint_intensity_index[ch]) - 1;
            if (src_ch_i >= 0) {
                const src_ch: usize = @intCast(src_ch_i);
                const sel = self.joint_scale_sel[ch];
                for (self.nsubbands[ch]..self.nsubbands[src_ch]) |band| {
                    self.joint_scale_factors[ch][band] = try self.parseJointScale(br, sel);
                }
            }
        }

        if (self.drc_present and header == .core) _ = try br.readBits(8);
        if (self.crc_present) _ = try br.readBits(16);
    }

    // ======================================================================
    // 5.5 音频数据
    // ======================================================================

    fn getSbits(br: *BitReader, n: u6) !i32 {
        const v = try br.readBits(n);
        if (n > 0) {
            const sign_bit: u32 = @as(u32, 1) << @intCast(n - 1);
            if (v & sign_bit != 0) return @as(i32, @bitCast(v)) - (@as(i32, 1) << @intCast(n));
        }
        return @intCast(v);
    }

    /// 返回 1 = Huffman（scale 需乘 adj），0 = 其它
    fn extractAudio(self: *DcaDecoder, br: *BitReader, audio: *[8]i32, abits: i32, ch: usize) !u1 {
        if (abits == 0) {
            @memset(audio, 0);
            return 0;
        }
        if (abits <= CODE_BOOKS) {
            const n: usize = @intCast(abits - 1);
            const sel = self.quant_index_sel[ch][n];
            if (sel < dt.ff_dca_quant_index_group_size[n]) {
                for (audio) |*v| v.* = @as(i32, try huff.decode(&huff.quant_tables[n][sel], br));
                return 1;
            }
            if (abits <= 7) return self.parseBlockCodes(br, audio, @intCast(abits));
        }
        for (audio) |*v| v.* = try getSbits(br, @intCast(abits - 3));
        return 0;
    }

    fn parseBlockCodes(self: *DcaDecoder, br: *BitReader, audio: *[8]i32, abits: i32) !u1 {
        _ = self;
        const nbits = block_code_nbits[@intCast(abits - 1)];
        const c1: u64 = try br.readBits(nbits);
        const c2: u64 = try br.readBits(nbits);
        const levels: u64 = dt.ff_dca_quant_levels[@intCast(abits)];
        const offset: i64 = @intCast((levels - 1) / 2);
        var code1: u64 = c1;
        var code2: u64 = c2;
        var n: usize = 0;
        while (n < 4) : (n += 1) {
            const div = code1 / levels;
            audio[n] = @intCast(@as(i64, @intCast(code1 - div * levels)) - offset);
            code1 = div;
        }
        while (n < 8) : (n += 1) {
            const div = code2 / levels;
            audio[n] = @intCast(@as(i64, @intCast(code2 - div * levels)) - offset);
            code2 = div;
        }
        if ((code1 | code2) != 0) return error.Invalid;
        return 0;
    }

    fn inverseAdpcm(self: *DcaDecoder, ch: usize, sb_start: usize, sb_end: usize, ofs: usize, len: usize) void {
        for (sb_start..sb_end) |band| {
            if (self.prediction_mode[ch][band]) {
                const pred_id = self.prediction_vq_index[ch][band];
                const row = self.band[ch][band];
                const coeff = dt.ff_dca_adpcm_vb[@as(usize, pred_id) * 4 ..][0..4];
                var j: usize = 0;
                while (j < len) : (j += 1) {
                    var pred: i64 = 0;
                    var c: usize = 0;
                    while (c < ADPCM_COEFFS) : (c += 1) {
                        // 全行缓冲（row[0..4) 为历史），数据起点 row[4+ofs+j]
                        pred += @as(i64, row[ADPCM_COEFFS + ofs + j - 1 - c]) * @as(i64, coeff[c]);
                    }
                    const x = dsp.clip23(dsp.norm13(pred));
                    row[ADPCM_COEFFS + ofs + j] = dsp.clip23(row[ADPCM_COEFFS + ofs + j] +% x);
                }
            }
        }
    }

    /// ff_dca_core_dequantize（residual=0）
    fn dequantize(self: *DcaDecoder, band_data: []i32, ofs: usize, audio: *const [8]i32, step_size: u32, scale: i32) void {
        _ = self;
        var step_scale: i64 = @as(i64, step_size) * scale;
        var shift: i32 = 0;
        if (step_scale > (1 << 23)) {
            const top: u64 = @intCast(step_scale >> 23);
            shift = @intCast(@as(u32, 63 - @clz(top)) + 1);
            step_scale >>= @intCast(shift);
        }
        for (audio, 0..) |av, k| {
            band_data[ofs + k] = dsp.clip23(dsp.norm__(@as(i64, av) * step_scale, 22 - shift));
        }
    }

    /// ff_dca_core_dequantize（residual=1）：XBR 残差加到既有子带样本上
    fn dequantizeResidual(self: *DcaDecoder, band_data: []i32, ofs: usize, audio: *const [8]i32, step_size: u32, scale: i32) void {
        _ = self;
        var step_scale: i64 = @as(i64, step_size) * scale;
        var shift: i32 = 0;
        if (step_scale > (1 << 23)) {
            const top: u64 = @intCast(step_scale >> 23);
            shift = @intCast(@as(u32, 63 - @clz(top)) + 1);
            step_scale >>= @intCast(shift);
        }
        for (audio, 0..) |av, k| {
            // ffmpeg: output[n] += clip23(norm__(...))（残差先 clip 再环绕相加）
            band_data[ofs + k] +%= dsp.clip23(dsp.norm__(@as(i64, av) * step_scale, 22 - shift));
        }
    }

    fn decodeHf(self: *DcaDecoder, ch: usize, vq_index: *const [DCA_SUBBANDS]u32, ofs: usize, len: usize) void {
        const hf = dt.ff_dca_high_freq_vq;
        for (self.subband_vq_start[ch]..self.nsubbands[ch]) |band| {
            const coeff: *const [32]i8 = @ptrCast(hf[@as(usize, vq_index[band]) * 32 ..][0..32]);
            const scale = self.scale_factors[ch][band][0];
            const data = self.bandData(ch, band);
            for (0..len) |j| {
                const v: i32 = coeff[j];
                data[ofs + j] = dsp.clip23((v * scale + (1 << 3)) >> 4);
            }
        }
    }

    fn parseSubframeAudio(self: *DcaDecoder, br: *BitReader, sf: usize, header: HdrType, xch_base: usize, sub_pos: *usize, lfe_pos: *usize) !void {
        const nsamples = @as(usize, self.nsubsubframes[sf]) * dsp.DCA_SUBBAND_SAMPLES;
        if (sub_pos.* + nsamples > self.npcmblocks) return error.Invalid;

        // VQ 子带
        for (xch_base..self.nchannels) |ch| {
            var vq_index: [DCA_SUBBANDS]u32 = undefined;
            for (self.subband_vq_start[ch]..self.nsubbands[ch]) |band| {
                vq_index[band] = try br.readBits(10);
            }
            if (self.subband_vq_start[ch] < self.nsubbands[ch]) {
                self.decodeHf(ch, &vq_index, sub_pos.*, nsamples);
            }
        }

        // LFE（仅 core 声道组）
        if (self.lfe_present != 0 and header == .core) {
            const nlfesamples = 2 * self.lfe_present * self.nsubsubframes[sf];
            var lfe_audio: [16]i32 = undefined;
            var nn: usize = 0;
            while (nn < nlfesamples) : (nn += 1) {
                const u = try br.readBits(8);
                // ffmpeg get_array() → get_sbits(8)：8-bit 带符号（补码）
                const s: i32 = if (u >= 0x80) @as(i32, @intCast(u)) - 256 else @intCast(u);
                lfe_audio[nn] = s;
            }
            const idx = try br.readBits(8);
            if (idx >= 128) return error.Invalid;
            const scale: i32 = @intCast(dt.ff_dca_scale_factor_quant7[idx]);
            const scale2: i32 = dsp.mul23(4697620, scale); // 0.035*(1<<27)
            var n: usize = 0;
            var ofs = lfe_pos.*;
            while (n < nlfesamples) : (n += 1) {
                self.lfe_rows[ofs] = dsp.clip23((lfe_audio[n] * scale2) >> 4);
                ofs += 1;
            }
            lfe_pos.* = ofs;
        }

        // 常规子带音频
        var ssf: usize = 0;
        var ofs = sub_pos.*;
        while (ssf < self.nsubsubframes[sf]) : (ssf += 1) {
            for (xch_base..self.nchannels) |ch| {
                for (0..self.subband_vq_start[ch]) |band| {
                    const abits = self.bit_allocation[ch][band];
                    var audio: [8]i32 = undefined;
                    const is_huff = try self.extractAudio(br, &audio, abits, ch);
                    const step_size: u32 = if (self.bit_rate == 3)
                        dt.ff_dca_lossless_quant[@intCast(abits)]
                    else
                        dt.ff_dca_lossy_quant[@intCast(abits)];

                    const trans_ssf = self.transition_mode[sf][ch][band];
                    var scale: i32 = undefined;
                    if (trans_ssf == 0 or ssf < trans_ssf) {
                        scale = self.scale_factors[ch][band][0];
                    } else {
                        scale = self.scale_factors[ch][band][1];
                    }
                    if (is_huff != 0) {
                        const adj = self.scale_factor_adj[ch][@intCast(abits - 1)];
                        scale = dsp.clip23(@intCast((@as(i64, adj) * scale) >> 22));
                    }
                    self.dequantize(self.bandData(ch, band), ofs, &audio, step_size, scale);
                }
            }
            // DSYNC
            if ((ssf == self.nsubsubframes[sf] - 1 or self.sync_ssf) and (try br.readBits(16)) != 0xffff) return error.Invalid;
            ofs += dsp.DCA_SUBBAND_SAMPLES;
        }

        // 逆 ADPCM
        for (xch_base..self.nchannels) |ch| {
            self.inverseAdpcm(ch, 0, self.nsubbands[ch], sub_pos.*, nsamples);
        }

        // 联合子带
        for (xch_base..self.nchannels) |ch| {
            const src_ch_i: i32 = @as(i32, self.joint_intensity_index[ch]) - 1;
            if (src_ch_i >= 0) {
                const src_ch: usize = @intCast(src_ch_i);
                for (self.nsubbands[ch]..self.nsubbands[src_ch]) |band| {
                    const scale = self.joint_scale_factors[ch][band];
                    const dst = self.bandData(ch, band);
                    const src_data = self.bandData(src_ch, band);
                    for (0..nsamples) |jj| {
                        dst[sub_pos.* + jj] = dsp.clip23(dsp.mul17(src_data[sub_pos.* + jj], scale));
                    }
                }
            }
        }

        sub_pos.* = ofs;
    }

    fn parseFrameData(self: *DcaDecoder, br: *BitReader, header: HdrType, xch_base: usize) !void {
        try self.parseCodingHeader(br, header, xch_base);
        var sub_pos: usize = 0;
        var lfe_pos: usize = DCA_LFE_HISTORY;
        for (0..self.nsubframes) |sf| {
            try self.parseSubframeHeader(br, sf, header, xch_base);
            try self.parseSubframeAudio(br, sf, header, xch_base, &sub_pos, &lfe_pos);
        }

        // 更新 ADPCM 历史 / 清空非活动子带
        for (xch_base..self.nchannels) |ch| {
            var nsubbands: usize = self.nsubbands[ch];
            if (self.joint_intensity_index[ch] != 0)
                nsubbands = @max(nsubbands, self.nsubbands[self.joint_intensity_index[ch] - 1]);
            for (0..nsubbands) |band| {
                const row = self.band[ch][band];
                // R[npcmblocks..npcmblocks+4) -> R[0..4)
                for (0..ADPCM_COEFFS) |c| row[c] = row[self.npcmblocks + c];
            }
            for (nsubbands..DCA_SUBBANDS) |band| {
                @memset(self.band[ch][band][0..self.row_len], 0);
            }
        }
    }

    // ======================================================================
    // core 帧内扩展（CSS）sync 定位（parse_optional_info；X96/XCH/XXCH）
    // ======================================================================
    fn detectExtensions(self: *DcaDecoder, frame: []const u8, consumed_bits: usize) !void {
        self.xch_pos = 0;
        self.xxch_pos = 0;
        self.x96_pos = 0;
        if (!self.ext_audio_present) return;

        const frame_size = @min(self.frame_size, frame.len);
        var sync_pos: isize = @intCast(@min(frame_size / 4, (frame.len * 8) / 32));
        sync_pos -= 1;
        const last_pos: isize = @intCast(consumed_bits / 32);
        var w1: u32 = 0;
        var w2: u32 = 0;
        while (sync_pos >= last_pos) : (sync_pos -= 1) {
            w1 = std.mem.readInt(u32, frame[@intCast(sync_pos * 4)..][0..4], .big);
            switch (self.ext_audio_type) {
                ext_audio_xch => {
                    if (w1 == t.syncword_xch) {
                        const size: usize = @intCast((w2 >> 22) + 1);
                        const dist: usize = frame_size - @as(usize, @intCast(sync_pos * 4));
                        if (size >= 96 and (size == dist or size - 1 == dist) and
                            (w2 >> 15 & 0x7f) == 0x08)
                        {
                            self.xch_pos = @intCast(sync_pos * 32 + 49);
                            return;
                        }
                    }
                },
                ext_audio_x96 => {
                    if (w1 == t.syncword_x96) {
                        const size: usize = @intCast((w2 >> 20) + 1);
                        const dist: usize = frame_size - @as(usize, @intCast(sync_pos * 4));
                        if (size >= 96 and size == dist) {
                            self.x96_pos = @intCast(sync_pos * 32 + 44);
                            return;
                        }
                    }
                },
                ext_audio_xxch => {
                    if (w1 == t.syncword_xxch) {
                        const size: usize = @intCast((w2 >> 26) + 1);
                        const dist: usize = frame.len - @as(usize, @intCast(sync_pos * 4));
                        if (size >= 11 and size <= dist and
                            crc16Ccitt(frame[@intCast((sync_pos + 1) * 4)..][0 .. size - 4]) == 0)
                        {
                            self.xxch_pos = @intCast(sync_pos * 32);
                            return;
                        }
                    }
                },
                else => {},
            }
            w2 = w1;
        }
    }

    fn crc16Ccitt(buf: []const u8) u16 {
        // FFmpeg av_crc(AV_CRC_16_CCITT, 0xffff, buf, len)：CRC-16/CCITT-FALSE，
        // 表驱动 crc = table[(crc ^ byte) & 0xff] ^ (crc >> 8)。
        var crc: u16 = 0xffff;
        for (buf) |b| {
            crc = @intCast((ccitt_table[@as(u8, @intCast((crc ^ b) & 0xff))] ^ (crc >> 8)) & 0xffff);
        }
        return crc;
    }

    const ccitt_table = blk: {
        @setEvalBranchQuota(10000);
        var table: [256]u16 = undefined;
        for (0..256) |i| {
            var v: u16 = @intCast(@as(u32, i) << 8);
            for (0..8) |_| {
                if (v & 0x8000 != 0) {
                    v = (v << 1) ^ 0x1021;
                } else {
                    v <<= 1;
                }
            }
            table[i] = v;
        }
        break :blk table;
    };

    /// 兼容入口：解析 core 帧内 XCH（CSS，ext_audio_type=XCH）。
    fn parseXchData(self: *DcaDecoder, frame: []const u8) !void {
        if (self.ch_mask & t.speaker_cs != 0) return error.Invalid;
        var br = BitReader.init(frame);
        try br.skipBits(@intCast(self.xch_pos));
        try self.parseFrameData(&br, .xch, self.nchannels);
        // 跳到 core 帧尾（不信任 XCH frame size）
        try self.seekBits(&br, self.frame_size * 8);
    }

    /// parse_xxch_frame（CSS 或 EXSS；br 已位于 XXCH 数据起点）
    fn parseXxchFrame(self: *DcaDecoder, br: *BitReader) !void {
        const header_pos = br.bit_pos;
        if ((try br.readBits(32)) != t.syncword_xxch) return error.Invalid;
        const header_size: usize = @intCast((try br.readBits(6)) + 1);
        self.xxch_crc_present = (try br.readBits(1)) != 0;
        self.xxch_mask_nbits = @intCast((try br.readBits(5)) + 1);
        if (self.xxch_mask_nbits <= 6) return error.Invalid;
        const nchsets = @as(usize, @intCast(try br.readBits(2))) + 1;
        if (nchsets > 1) return error.Unsupported;
        const xxch_frame_size: usize = @intCast((try br.readBits(14)) + 1);
        self.xxch_core_mask = try br.readBits(@intCast(self.xxch_mask_nbits));

        // 校验 core 掩码（Ls↔Lss / Rs↔Rss 重映射后须一致）
        var mask = self.ch_mask;
        if (mask & t.speaker_ls != 0 and self.xxch_core_mask & t.speaker_lss != 0)
            mask = (mask & ~t.speaker_ls) | t.speaker_lss;
        if (mask & t.speaker_rs != 0 and self.xxch_core_mask & t.speaker_rss != 0)
            mask = (mask & ~t.speaker_rs) | t.speaker_rss;
        if (mask != self.xxch_core_mask) return error.Invalid;

        // Reserved + 字节对齐 + XXCH 帧头 CRC16
        try self.seekBits(br, header_pos + header_size * 8);

        // 声道组 0
        try self.parseFrameData(br, .xxch, self.nchannels);
        try self.seekBits(br, header_pos + header_size * 8 + xxch_frame_size * 8);
    }

    // ======================================================================
    // XBR（EXSS 扩展码率，DTS-HD HRA）：parse_xbr_frame / parse_xbr_subframe
    // （dca_core.c）。XBR 对 core 已有声道子带样本写入残差（residual=1），
    // 使用 core 的 scale_factor_sel / transition_mode / nsubsubframes 状态。
    // ======================================================================
    fn parseXbrSubframe(
        self: *DcaDecoder,
        br: *BitReader,
        xbr_base_ch: usize,
        xbr_nchannels: usize,
        xbr_nsubbands: *const [4 * 8]u8,
        xbr_transition_mode: bool,
        sf: usize,
        sub_pos: *usize,
    ) !void {
        var xbr_nabits: [DCA_CHANNELS]i32 = undefined;
        var xbr_bit_allocation: [DCA_CHANNELS][DCA_SUBBANDS]i32 = undefined;
        var xbr_scale_nbits: [DCA_CHANNELS]u6 = undefined;
        var xbr_scale_factors: [DCA_CHANNELS][DCA_SUBBANDS][2]i32 = undefined;

        // 本子帧子带样本数
        const nsamples = @as(usize, self.nsubsubframes[sf]) * dsp.DCA_SUBBAND_SAMPLES;
        if (sub_pos.* + nsamples > self.npcmblocks) return error.Invalid;

        // XBR 比特分配索引位数
        for (xbr_base_ch..xbr_nchannels) |ch| {
            xbr_nabits[ch] = @as(i32, @intCast(try br.readBits(2))) + 2;
        }
        // XBR 比特分配索引
        for (xbr_base_ch..xbr_nchannels) |ch| {
            for (0..xbr_nsubbands[ch]) |band| {
                const ba: i32 = @intCast(try br.readBits(@intCast(xbr_nabits[ch])));
                if (ba > DCA_ABITS_MAX) return error.Invalid;
                xbr_bit_allocation[ch][band] = ba;
            }
        }
        // 尺度因子索引位数
        for (xbr_base_ch..xbr_nchannels) |ch| {
            const nbits: u6 = @intCast(try br.readBits(3));
            if (nbits == 0) return error.Invalid;
            xbr_scale_nbits[ch] = nbits;
        }
        // XBR 尺度因子（根方表：scale_factor_sel>5 → quant7，否则 quant6）
        for (xbr_base_ch..xbr_nchannels) |ch| {
            const scale_table: []const u32 = if (self.scale_factor_sel[ch] > 5)
                &dt.ff_dca_scale_factor_quant7
            else
                &dt.ff_dca_scale_factor_quant6;
            for (0..xbr_nsubbands[ch]) |band| {
                if (xbr_bit_allocation[ch][band] != 0) {
                    var scale_index: usize = @intCast(try br.readBits(xbr_scale_nbits[ch]));
                    if (scale_index >= scale_table.len) return error.Invalid;
                    xbr_scale_factors[ch][band][0] = @intCast(scale_table[scale_index]);
                    if (xbr_transition_mode and self.transition_mode[sf][ch][band] != 0) {
                        scale_index = @intCast(try br.readBits(xbr_scale_nbits[ch]));
                        if (scale_index >= scale_table.len) return error.Invalid;
                        xbr_scale_factors[ch][band][1] = @intCast(scale_table[scale_index]);
                    }
                }
            }
        }

        // 音频数据（残差）
        var ssf: usize = 0;
        var ofs = sub_pos.*;
        while (ssf < self.nsubsubframes[sf]) : (ssf += 1) {
            for (xbr_base_ch..xbr_nchannels) |ch| {
                for (0..xbr_nsubbands[ch]) |band| {
                    const abits = xbr_bit_allocation[ch][band];
                    var audio: [8]i32 = undefined;

                    if (abits > 7) {
                        // 无进一步编码（带符号定长）
                        for (&audio) |*v| v.* = try getSbits(br, @intCast(abits - 3));
                    } else if (abits > 0) {
                        // 块码
                        _ = try self.parseBlockCodes(br, &audio, abits);
                    } else {
                        continue;
                    }

                    const step_size: u32 = dt.ff_dca_lossless_quant[@intCast(abits)];
                    const trans_ssf: u8 = if (xbr_transition_mode) self.transition_mode[sf][ch][band] else 0;
                    const scale: i32 = if (trans_ssf == 0 or ssf < trans_ssf)
                        xbr_scale_factors[ch][band][0]
                    else
                        xbr_scale_factors[ch][band][1];

                    self.dequantizeResidual(self.bandData(ch, band), ofs, &audio, step_size, scale);
                }
            }
            // DSYNC
            if ((ssf == self.nsubsubframes[sf] - 1 or self.sync_ssf) and (try br.readBits(16)) != 0xffff) return error.Invalid;
            ofs += dsp.DCA_SUBBAND_SAMPLES;
        }

        sub_pos.* = ofs;
    }

    /// parse_xbr_frame：br 位于 XBR 分量起点（自 sync 0x655E315E 起）
    fn parseXbrFrame(self: *DcaDecoder, br: *BitReader) !void {
        var xbr_frame_size: [4]usize = undefined;
        var xbr_nchannels: [4]usize = undefined;
        // dca_core.c：xbr_nsubbands[DCA_EXSS_CHSETS_MAX * DCA_EXSS_CHANNELS_MAX]
        var xbr_nsubbands: [4 * 8]u8 = undefined;

        var header_pos = br.bit_pos;
        if ((try br.readBits(32)) != t.syncword_xbr) return error.Invalid;

        // XBR 帧头长度（CRC 不消费数据位，不校验）
        const header_size: usize = @intCast((try br.readBits(6)) + 1);

        // 声道组数
        const xbr_nchsets = @as(usize, @intCast(try br.readBits(2))) + 1;
        if (xbr_nchsets > 4) return error.Invalid;

        // 各声道组字节尺寸
        for (0..xbr_nchsets) |i| xbr_frame_size[i] = @intCast((try br.readBits(14)) + 1);

        // 瞬态标志
        const xbr_transition_mode = (try br.readBits(1)) != 0;

        // 声道组头
        var ch2: usize = 0;
        for (0..xbr_nchsets) |i| {
            xbr_nchannels[i] = @as(usize, @intCast(try br.readBits(3))) + 1;
            const xbr_band_nbits: u6 = @intCast((try br.readBits(2)) + 5);
            for (0..xbr_nchannels[i]) |_| {
                xbr_nsubbands[ch2] = @intCast((try br.readBits(xbr_band_nbits)) + 1);
                if (xbr_nsubbands[ch2] > DCA_SUBBANDS) return error.Invalid;
                ch2 += 1;
            }
        }

        // Reserved + 字节对齐 + XBR 帧头 CRC16
        try self.seekBits(br, header_pos + header_size * 8);

        // 声道组数据
        var xbr_base_ch: usize = 0;
        for (0..xbr_nchsets) |i| {
            header_pos = br.bit_pos;

            if (xbr_base_ch + xbr_nchannels[i] <= self.nchannels) {
                var sub_pos: usize = 0;
                for (0..self.nsubframes) |sf| {
                    try self.parseXbrSubframe(
                        br,
                        xbr_base_ch,
                        xbr_base_ch + xbr_nchannels[i],
                        &xbr_nsubbands,
                        xbr_transition_mode,
                        sf,
                        &sub_pos,
                    );
                }
            }

            xbr_base_ch += xbr_nchannels[i];
            try self.seekBits(br, header_pos + xbr_frame_size[i] * 8);
        }
    }

    // ======================================================================
    // ff_dca_core_parse_exss 等价：处理 core 帧内 CSS (X)XCH 与 EXSS 中
    // XXCH/X96 分量。exss_buf 为 EXSS 子流（可为空），extension_mask /
    // xxch_offset / x96_offset 来自该子流的 asset 描述。
    // ======================================================================
    pub fn parseCoreExss(
        self: *DcaDecoder,
        core_frame: []const u8,
        exss_buf: ?[]const u8,
        extension_mask: u16,
        xxch_offset: usize,
        xxch_size: usize,
        x96_offset: usize,
        x96_size: usize,
        xll_active: bool,
    ) !void {
        self.parseCoreExssXbr(core_frame, exss_buf, extension_mask, 0, 0, xxch_offset, xxch_size, x96_offset, x96_size, xll_active);
    }

    /// 完整版：含 XBR 分量偏移/尺寸（ff_dca_core_parse_exss 全序：
    /// (X)XCH → XBR → X96）
    pub fn parseCoreExssXbr(
        self: *DcaDecoder,
        core_frame: []const u8,
        exss_buf: ?[]const u8,
        extension_mask: u16,
        xbr_offset: usize,
        xbr_size: usize,
        xxch_offset: usize,
        xxch_size: usize,
        x96_offset: usize,
        x96_size: usize,
        xll_active: bool,
    ) !void {
        // 解析 (X)XCH（本实现不支持 request_channel_layout 降混）
        if (extension_mask & exss_xxch != 0) {
            const exss_data = exss_buf orelse return error.Corrupt;
            if (xxch_offset + xxch_size > exss_data.len) return error.Corrupt;
            var br = BitReader.init(exss_data[xxch_offset .. xxch_offset + xxch_size]);
            if (self.parseXxchFrame(&br)) |_| {
                self.ext_audio_mask |= exss_xxch;
            } else |_| {
                // 失败：回退到主声道组（对齐 ffmpeg 非 EXPLODE 语义）
                self.revertExssChannels();
            }
        } else if (self.xxch_pos != 0) {
            var br = BitReader.init(core_frame);
            try br.skipBits(@intCast(self.xxch_pos));
            if (self.parseXxchFrame(&br)) |_| {
                self.ext_audio_mask |= css_xxch;
            } else |_| {
                self.revertExssChannels();
            }
        } else if (self.xch_pos != 0) {
            if (self.parseXchData(core_frame)) |_| {
                self.ext_audio_mask |= css_xch;
            } else |_| {
                self.revertExssChannels();
            }
        }

        // XBR（解析失败忽略，对齐 ffmpeg 非 EXPLODE 语义）
        if (extension_mask & exss_xbr != 0) {
            const exss_data = exss_buf orelse return error.Corrupt;
            if (xbr_offset + xbr_size > exss_data.len) return error.Corrupt;
            var br = BitReader.init(exss_data[xbr_offset .. xbr_offset + xbr_size]);
            if (self.parseXbrFrame(&br)) |_| {
                self.ext_audio_mask |= exss_xbr;
            } else |_| {}
        }

        // X96（XLL 解码时跳过，对齐 ffmpeg DCA_PACKET_XLL）
        if (!xll_active) {
            if (extension_mask & exss_x96 != 0) {
                const exss_data = exss_buf orelse return error.Corrupt;
                if (x96_offset + x96_size > exss_data.len) return error.Corrupt;
                self.parseX96Exss(exss_data[x96_offset .. x96_offset + x96_size]) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {},
                };
            } else if (self.x96_pos != 0) {
                _ = self.parseX96Data(core_frame) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {},
                };
            }
        }
    }

    /// (X)XCH 解析失败时回退到主声道组（nchannels/ch_mask 复原）
    fn revertExssChannels(self: *DcaDecoder) void {
        self.nchannels = t.channels_by_amode[self.audio_mode];
        self.ch_mask = audio_mode_ch_mask[self.audio_mode];
        if (self.lfe_present != 0) self.ch_mask |= t.speaker_lfe1;
    }

    /// 解析 EXSS 中的 X96 分量（parse_x96_frame_exss）
    fn parseX96Exss(self: *DcaDecoder, data: []const u8) !void {
        var br = BitReader.init(data);
        const header_pos = br.bit_pos;
        if ((try br.readBits(32)) != t.syncword_x96) return error.Invalid;
        const header_size: usize = @intCast((try br.readBits(6)) + 1);
        self.x96_rev_no = @intCast(try br.readBits(4));
        if (self.x96_rev_no < 1 or self.x96_rev_no > 8) return error.Invalid;
        self.x96_crc_present = (try br.readBits(1)) != 0;
        const nchsets = @as(usize, @intCast(try br.readBits(2))) + 1;
        if (nchsets > 4) return error.Invalid;
        var frame_sizes: [4]usize = undefined;
        for (0..nchsets) |i| frame_sizes[i] = @intCast((try br.readBits(12)) + 1);
        var ch_nch: [4]u8 = undefined;
        for (0..nchsets) |i| ch_nch[i] = @intCast((try br.readBits(3)) + 1);

        // Reserved + 字节对齐 + X96 帧头 CRC16
        try self.seekBits(&br, header_pos + header_size * 8);
        try self.allocX96SampleBuffer();
        if (!self.predictor_history) self.eraseX96AdpcmHistory();

        self.x96_nchannels = 0;
        var base_ch: usize = 0;
        for (0..nchsets) |i| {
            const chset_pos = br.bit_pos;
            if (base_ch + ch_nch[i] <= self.nchannels) {
                self.x96_nchannels = @intCast(base_ch + ch_nch[i]);
                try self.parseX96FrameData(&br, true, base_ch);
            }
            base_ch += ch_nch[i];
            try self.seekBits(&br, chset_pos + frame_sizes[i] * 8);
        }
        self.x96_active = true;
        self.ext_audio_mask |= exss_x96;
    }

    // ======================================================================
    // X96 扩展（CSS / EXSS）解析：parse_x96_frame / parse_x96_frame_exss /
    // _frame_data / _coding_header / _subframe_header / _subframe_audio
    // ======================================================================
    fn randX96(self: *DcaDecoder) i32 {
        self.x96_rand = 1103515245 *% self.x96_rand +% 12345;
        return @intCast((self.x96_rand & 0x7fffffff) - 0x40000000);
    }

    /// 解析 core 帧内（CSS）X96（ext_audio_type=X96）。成功 → x96_active。
    pub fn parseX96Data(self: *DcaDecoder, frame: []const u8) !bool {
        if (self.x96_pos == 0) return false;
        var br = BitReader.init(frame);
        try br.skipBits(@intCast(self.x96_pos));
        self.x96_rev_no = @intCast(try br.readBits(4));
        if (self.x96_rev_no < 1 or self.x96_rev_no > 8) return error.Corrupt;
        self.x96_crc_present = false;
        self.x96_nchannels = self.nchannels;
        try self.allocX96SampleBuffer();
        if (!self.predictor_history) self.eraseX96AdpcmHistory();
        try self.parseX96FrameData(&br, false, 0);
        self.x96_active = true;
        self.ext_audio_mask |= css_x96;
        return true;
    }

    fn parseX96FrameData(self: *DcaDecoder, br: *BitReader, exss: bool, xch_base: usize) !void {
        try self.parseX96CodingHeader(br, exss, xch_base);
        var sub_pos: usize = 0;
        for (0..self.nsubframes) |sf| {
            try self.parseX96SubframeHeader(br, xch_base);
            try self.parseX96SubframeAudio(br, sf, xch_base, &sub_pos);
        }

        for (xch_base..self.x96_nchannels) |ch| {
            var nsubbands: usize = self.nsubbands[ch];
            if (self.joint_intensity_index[ch] != 0)
                nsubbands = @max(nsubbands, self.nsubbands[self.joint_intensity_index[ch] - 1]);
            for (0..DCA_SUBBANDS_X96) |band| {
                const row = self.x96_band[ch][band];
                if (band >= self.x96_subband_start and band < nsubbands) {
                    for (0..ADPCM_COEFFS) |c| row[c] = row[self.npcmblocks + c];
                } else {
                    @memset(row[0..self.row_len], 0);
                }
            }
        }
    }

    fn parseX96CodingHeader(self: *DcaDecoder, br: *BitReader, exss: bool, xch_base: usize) !void {
        const header_pos = br.bit_pos;
        var header_size: usize = 0;
        if (exss) {
            // 声道组头长度
            header_size = @intCast((try br.readBits(7)) + 1);
        }
        self.x96_high_res = (try br.readBits(1)) != 0;
        if (self.x96_rev_no < 8) {
            self.x96_subband_start = @intCast(try br.readBits(5));
            if (self.x96_subband_start > 27) return error.Invalid;
        } else {
            self.x96_subband_start = DCA_SUBBANDS;
        }
        for (xch_base..self.x96_nchannels) |ch| {
            self.nsubbands[ch] = @intCast((try br.readBits(6)) + 1);
            if (self.nsubbands[ch] < DCA_SUBBANDS) return error.Invalid;
        }
        for (xch_base..self.x96_nchannels) |ch| {
            var n = try br.readBits(3);
            if (xch_base != 0 and n != 0) n += @intCast(xch_base - 1);
            if (n > self.x96_nchannels) return error.Invalid;
            self.joint_intensity_index[ch] = @intCast(n);
        }
        for (xch_base..self.x96_nchannels) |ch| {
            self.scale_factor_sel[ch] = @intCast(try br.readBits(3));
            if (self.scale_factor_sel[ch] >= 6) return error.Invalid;
        }
        for (xch_base..self.x96_nchannels) |ch| self.bit_allocation_sel[ch] = @intCast(try br.readBits(3));
        const nbooks: usize = 6 + 4 * @as(usize, if (self.x96_high_res) 1 else 0);
        for (0..nbooks) |n| {
            for (xch_base..self.x96_nchannels) |ch| {
                self.quant_index_sel[ch][n] = @intCast(try br.readBits(@intCast(dt.ff_dca_quant_index_sel_nbits[n])));
            }
        }
        if (exss) {
            // Reserved + 字节对齐 + 声道组头 CRC16
            try self.seekBits(br, header_pos + header_size * 8);
        } else if (self.crc_present) {
            _ = try br.readBits(16);
        }
    }

    fn parseX96SubframeHeader(self: *DcaDecoder, br: *BitReader, xch_base: usize) !void {
        // 预测模式 / VQ 地址
        for (xch_base..self.x96_nchannels) |ch| {
            for (self.x96_subband_start..self.nsubbands[ch]) |band| {
                self.prediction_mode[ch][band] = (try br.readBits(1)) != 0;
            }
        }
        for (xch_base..self.x96_nchannels) |ch| {
            for (self.x96_subband_start..self.nsubbands[ch]) |band| {
                if (self.prediction_mode[ch][band])
                    self.prediction_vq_index[ch][band] = @intCast(try br.readBits(12));
            }
        }

        // 比特分配
        for (xch_base..self.x96_nchannels) |ch| {
            const sel = self.bit_allocation_sel[ch];
            var abits: i32 = 0;
            for (self.x96_subband_start..self.nsubbands[ch]) |band| {
                if (sel < 7) {
                    const book = 5 + 2 * @as(usize, if (self.x96_high_res) 1 else 0);
                    abits += @as(i32, try huff.decode(&huff.quant_tables[book][sel], br));
                } else {
                    abits = @intCast(try br.readBits(3 + @as(u6, if (self.x96_high_res) 1 else 0)));
                }
                const max_abits: i32 = 7 + 8 * @as(i32, if (self.x96_high_res) 1 else 0);
                if (abits < 0 or abits > max_abits) return error.Invalid;
                self.bit_allocation[ch][band] = @intCast(abits);
            }
        }

        // 尺度因子
        for (xch_base..self.x96_nchannels) |ch| {
            const sel = self.scale_factor_sel[ch];
            var scale_index: i32 = 0;
            for (self.x96_subband_start..self.nsubbands[ch]) |band| {
                const scale = try self.parseScale(br, &scale_index, sel);
                self.scale_factors[ch][band >> 1][band & 1] = scale;
            }
        }

        // 联合子带码书选择 / 尺度
        for (xch_base..self.x96_nchannels) |ch| {
            if (self.joint_intensity_index[ch] != 0) {
                const jsel = try br.readBits(3);
                if (jsel == 7) return error.Invalid;
                self.joint_scale_sel[ch] = @intCast(jsel);
            }
        }
        for (xch_base..self.x96_nchannels) |ch| {
            const src_ch_i: i32 = @as(i32, self.joint_intensity_index[ch]) - 1;
            if (src_ch_i >= 0) {
                const src_ch: usize = @intCast(src_ch_i);
                const sel = self.joint_scale_sel[ch];
                for (self.nsubbands[ch]..self.nsubbands[src_ch]) |band| {
                    self.joint_scale_factors[ch][band] = try self.parseJointScale(br, sel);
                }
            }
        }

        if (self.crc_present) _ = try br.readBits(16);
    }

    fn parseX96SubframeAudio(self: *DcaDecoder, br: *BitReader, sf: usize, xch_base: usize, sub_pos: *usize) !void {
        const nsamples = @as(usize, self.nsubsubframes[sf]) * dsp.DCA_SUBBAND_SAMPLES;
        if (sub_pos.* + nsamples > self.npcmblocks) return error.Invalid;

        // VQ 编码 / 未分配子带（abits 0/1）
        for (xch_base..self.x96_nchannels) |ch| {
            for (self.x96_subband_start..self.nsubbands[ch]) |band| {
                const row = self.x96_band[ch][band];
                const samples = row[ADPCM_COEFFS + sub_pos.* ..][0..nsamples];
                const scale = self.scale_factors[ch][band >> 1][band & 1];
                switch (self.bit_allocation[ch][band]) {
                    0 => {
                        if (scale <= 1) {
                            @memset(samples, 0);
                        } else {
                            for (samples) |*v| v.* = dsp.mul31(self.randX96(), scale);
                        }
                    },
                    1 => {
                        var ssf: usize = 0;
                        while (ssf < (self.nsubsubframes[sf] + 1) / 2) : (ssf += 1) {
                            const vq_addr = try br.readBits(10);
                            const coeff: *const [32]i8 = @ptrCast(dt.ff_dca_high_freq_vq[vq_addr * 32 ..][0..32]);
                            const n: usize = @min(nsamples - ssf * 16, 16);
                            for (0..n) |k| {
                                const v: i32 = coeff[k];
                                row[ADPCM_COEFFS + sub_pos.* + ssf * 16 + k] = dsp.clip23((v * scale + (1 << 3)) >> 4);
                            }
                        }
                    },
                    else => {},
                }
            }
        }

        // 常规音频数据（abits ≥ 2）
        var ssf: usize = 0;
        var ofs = sub_pos.*;
        while (ssf < self.nsubsubframes[sf]) : (ssf += 1) {
            for (xch_base..self.x96_nchannels) |ch| {
                for (self.x96_subband_start..self.nsubbands[ch]) |band| {
                    const abits = self.bit_allocation[ch][band] - 1;
                    if (abits < 1) continue;
                    var audio: [8]i32 = undefined;
                    const is_huff = try self.extractAudio(br, &audio, abits, ch);
                    _ = is_huff;
                    const step_size: u32 = if (self.bit_rate == 3)
                        dt.ff_dca_lossless_quant[@intCast(abits)]
                    else
                        dt.ff_dca_lossy_quant[@intCast(abits)];
                    const scale = self.scale_factors[ch][band >> 1][band & 1];
                    self.dequantize(self.x96BandData(ch, band), ofs, &audio, step_size, scale);
                }
            }
            if ((ssf == self.nsubsubframes[sf] - 1 or self.sync_ssf) and (try br.readBits(16)) != 0xffff)
                return error.Invalid;
            ofs += dsp.DCA_SUBBAND_SAMPLES;
        }

        // 逆 ADPCM
        for (xch_base..self.x96_nchannels) |ch| {
            self.inverseAdpcmX96(ch, self.x96_subband_start, self.nsubbands[ch], sub_pos.*, nsamples);
        }

        // 联合子带
        for (xch_base..self.x96_nchannels) |ch| {
            const src_ch_i: i32 = @as(i32, self.joint_intensity_index[ch]) - 1;
            if (src_ch_i >= 0) {
                const src_ch: usize = @intCast(src_ch_i);
                for (self.nsubbands[ch]..self.nsubbands[src_ch]) |band| {
                    const scale = self.joint_scale_factors[ch][band];
                    const dst = self.x96BandData(ch, band);
                    const src_data = self.x96BandData(src_ch, band);
                    for (0..nsamples) |jj| {
                        dst[sub_pos.* + jj] = dsp.clip23(dsp.mul17(src_data[sub_pos.* + jj], scale));
                    }
                }
            }
        }

        sub_pos.* = ofs;
    }

    fn inverseAdpcmX96(self: *DcaDecoder, ch: usize, sb_start: usize, sb_end: usize, ofs: usize, len: usize) void {
        for (sb_start..sb_end) |band| {
            if (self.prediction_mode[ch][band]) {
                const pred_id = self.prediction_vq_index[ch][band];
                const row = self.x96_band[ch][band];
                const coeff = dt.ff_dca_adpcm_vb[@as(usize, pred_id) * 4 ..][0..4];
                var j: usize = 0;
                while (j < len) : (j += 1) {
                    var pred: i64 = 0;
                    var c: usize = 0;
                    while (c < ADPCM_COEFFS) : (c += 1) {
                        pred += @as(i64, row[ADPCM_COEFFS + ofs + j - 1 - c]) * @as(i64, coeff[c]);
                    }
                    const x = dsp.clip23(dsp.norm13(pred));
                    row[ADPCM_COEFFS + ofs + j] = dsp.clip23(row[ADPCM_COEFFS + ofs + j] +% x);
                }
            }
        }
    }

    // ======================================================================
    // 定点合成（ff_dca_core_filter_fixed + filter_frame_fixed；core 32-band /
    // X96 64-band 共享）。x96_synth = 1 时 64-band 合成，采样率/样本数翻倍；
    // X96 子带数据已解析（x96_active）则合成使用 lo+hi，否则仅 32 个低子带
    // （DTS-HD MA 192k XLL 的 96k core 输入，XLL 残余上混场景）。
    // ======================================================================
    pub fn filter(self: *DcaDecoder, out: *DecodedFrame, x96_synth: bool) !void {
        if (x96_synth != self.filter_x96_mode) {
            // 切换 32/64-band：清空 DSP 历史（对齐 ffmpeg set_filter_mode）
            for (&self.hist1) |*h| h.* = [_]i32{0} ** 1024;
            for (&self.hist2) |*h| h.* = [_]i32{0} ** 32;
            for (&self.hist2_x96) |*h| h.* = [_]i32{0} ** 64;
            for (&self.offset) |*o| o.* = 0;
            for (&self.offset_x96) |*o| o.* = 0;
            self.lfe_history_x96 = 0;
            self.filter_x96_mode = x96_synth;
        }

        const nsamples = self.npcmblocks * dsp.DCA_PCMBLOCK_SAMPLES * @as(usize, if (x96_synth) 2 else 1);
        if (self.outbuf.len < 8 * nsamples) {
            if (self.outbuf.len != 0) self.alloc.free(self.outbuf);
            self.outbuf = try self.alloc.alloc(i32, 8 * nsamples);
        }

        var plane: [32]?[]i32 = [_]?[]i32{null} ** 32;
        var scratch = self.outbuf[0 .. 8 * nsamples];
        @memset(scratch, 0);
        var pi: usize = 0;
        for (0..32) |spkr| {
            if (self.ch_mask & (@as(u32, 1) << @intCast(spkr)) != 0) {
                plane[spkr] = scratch[pi * nsamples .. (pi + 1) * nsamples];
                pi += 1;
            }
        }
        if (pi > 8) return error.Unsupported;

        // 主声道
        if (x96_synth) {
            const window: *const [1024]i32 = &dt.ff_dca_fir_64bands_fixed;
            for (0..self.nchannels) |ch| {
                const spkr = self.mapPrmChToSpkr(ch) orelse return error.Unsupported;
                const pl = plane[spkr] orelse return error.Unsupported;
                self.subQmf64(pl, ch, window);
            }
        } else {
            const window: *const [512]i32 = if (self.filter_perfect)
                &dt.ff_dca_fir_32bands_perfect_fixed
            else
                &dt.ff_dca_fir_32bands_nonperfect_fixed;
            for (0..self.nchannels) |ch| {
                const spkr = self.mapPrmChToSpkr(ch) orelse return error.Unsupported;
                const pl = plane[spkr] orelse return error.Unsupported;
                try self.subQmf32(pl, ch, window);
            }
        }

        // LFE（64x 抽取；X96 96k 时二次插值至 2×）
        if (self.lfe_present == 2) {
            const pl = plane[5] orelse return error.Unsupported;
            if (x96_synth) {
                const mid = nsamples / 2;
                dsp.lfeFirFixed(pl[mid..nsamples], self.lfe_rows, &dt.ff_dca_lfe_fir_64_fixed, self.npcmblocks);
                dsp.lfeX96Fixed(pl, pl[mid..nsamples], &self.lfe_history_x96, mid);
            } else {
                dsp.lfeFirFixed(pl, self.lfe_rows, &dt.ff_dca_lfe_fir_64_fixed, self.npcmblocks);
            }
            const n = self.npcmblocks >> 1;
            for (0..DCA_LFE_HISTORY) |kk| {
                const ii = DCA_LFE_HISTORY - 1 - kk;
                self.lfe_rows[ii] = self.lfe_rows[n + ii];
            }
        } else if (self.lfe_present == 1) {
            return error.Unsupported; // LFF=128 定点路径 FFmpeg 也不支持
        }

        // 撤销嵌入的 XCH 降混（DTS-ES：Ls/Rs 含 -0.707·Cs）
        if (self.es_format and self.ext_audio_mask & css_xch != 0 and self.audio_mode >= 8) {
            const pls = plane[3].?;
            const prs = plane[4].?;
            const pcs = plane[6].?;
            for (0..nsamples) |i| {
                const cs: i32 = dsp.mul23(pcs[i], 5931520); // M_SQRT1_2*(1<<23)
                pls[i] -%= cs;
                prs[i] -%= cs;
            }
        }

        // 撤销嵌入的 XXCH 降混
        if (self.ext_audio_mask & (css_xxch | exss_xxch) != 0 and self.xxch_dmix_embedded) {
            const scale_inv = self.xxch_dmix_scale_inv;
            const ncore = t.channels_by_amode[self.audio_mode];
            // 撤销 core 降混预缩放
            for (0..self.xxch_mask_nbits) |spkr| {
                if (self.xxch_core_mask & (@as(u32, 1) << @intCast(spkr)) != 0) {
                    const p = plane[spkr].?;
                    for (0..nsamples) |i| p[i] = dsp.mul16(p[i], scale_inv);
                }
            }
            // 撤销降混
            var ci: usize = 0;
            for (ncore..self.nchannels) |ch| {
                const src_spkr = self.mapPrmChToSpkr(ch) orelse return error.Unsupported;
                for (0..self.xxch_mask_nbits) |spkr| {
                    if (self.xxch_dmix_mask[ch - ncore] & (@as(u32, 1) << @intCast(spkr)) != 0) {
                        const coeff = dsp.mul16(self.xxch_dmix_coeff[ci], scale_inv);
                        ci += 1;
                        if (coeff != 0) {
                            const dst = plane[spkr].?;
                            const src = plane[src_spkr].?;
                            for (0..nsamples) |i| dst[i] -%= dsp.mul15(src[i], coeff);
                        }
                    }
                }
            }
        }

        // 前/环绕 sum/diff 撤销（core-only，无 XCH/XXCH）
        if (self.ext_audio_mask & (css_xxch | css_xch | exss_xxch) == 0) {
            if ((self.sumdiff_front and self.audio_mode > 0) or self.audio_mode == 3) {
                butterflies(plane[1].?, plane[2].?);
            }
            if (self.sumdiff_surround and self.audio_mode >= 8) {
                butterflies(plane[3].?, plane[4].?);
            }
        }

        // 输出 remap 序
        var order: [8]u32 = undefined;
        const nch_out = remapOrder(self.ch_mask, &order);
        out.nsamples = nsamples;
        out.nch = nch_out;
        out.sample_rate = if (x96_synth) self.sample_rate << 1 else self.sample_rate;
        var ci: usize = 0;
        while (ci < nch_out) : (ci += 1) {
            out.speaker[ci] = @intCast(order[ci]);
            out.planes[ci] = plane[order[ci]].?;
        }
        while (ci < 8) : (ci += 1) {
            out.speaker[ci] = 0;
            out.planes[ci] = &.{};
        }
        for (plane, 0..) |pl, spkr| self.speaker_planes[spkr] = pl;
    }

    /// map_prm_ch_to_spkr：声道序号 → 扬声器位（处理 XCH/XXCH 时的重映射）
    fn mapPrmChToSpkr(self: *const DcaDecoder, ch: usize) ?usize {
        const pos = t.channels_by_amode[self.audio_mode];
        if (ch < pos) {
            const spkr = mapPrmChToSpkrStatic(self.audio_mode, ch);
            if (self.ext_audio_mask & (css_xxch | exss_xxch) != 0) {
                if (self.xxch_core_mask & (@as(u32, 1) << @intCast(spkr)) != 0) return spkr;
                if (spkr == 3 and self.xxch_core_mask & t.speaker_lss != 0) return 9; // Ls→Lss
                if (spkr == 4 and self.xxch_core_mask & t.speaker_rss != 0) return 10; // Rs→Rss
                return null;
            }
            return spkr;
        }
        if (self.ext_audio_mask & css_xch != 0 and ch == pos) return 6; // Cs
        if (self.ext_audio_mask & (css_xxch | exss_xxch) != 0) {
            var p = pos;
            for (6..self.xxch_mask_nbits) |spkr| {
                if (self.xxch_spkr_mask & (@as(u32, 1) << @intCast(spkr)) != 0) {
                    if (p == ch) return spkr;
                    p += 1;
                }
            }
        }
        return null;
    }

    /// 最近一帧某扬声器（dca speaker 位序）的平面（23-bit 值，nsamples 长）
    pub fn speakerPlane(self: *const DcaDecoder, spkr: usize) ?[]const i32 {
        return self.speaker_planes[spkr];
    }

    fn subQmf32(self: *DcaDecoder, pcm: []i32, ch: usize, window: *const [512]i32) !void {
        const npcm = self.npcmblocks;
        for (0..npcm) |j| {
            var in: [32]i32 = undefined;
            for (0..32) |i| in[i] = self.band[ch][i][ADPCM_COEFFS + j];
            var blk: [32]i32 = undefined;
            dsp.synthFilterFixed(&self.hist1[ch], &self.offset[ch], &self.hist2[ch], window, &blk, &in);
            @memcpy(pcm[j * 32 ..][0..32], &blk);
        }
    }

    /// 64-band QMF（sub_qmf64_fixed）：x96_active 且 ch 有 X96 数据时
    /// 低 32 子带 = core+X96，高 32 子带 = X96；否则仅低 32 子带（hi=NULL）。
    fn subQmf64(self: *DcaDecoder, pcm: []i32, ch: usize, window: *const [1024]i32) void {
        const npcm = self.npcmblocks;
        const use_hi = self.x96_active and ch < self.x96_nchannels;
        for (0..npcm) |j| {
            var input: [64]i32 = undefined;
            for (0..32) |i| {
                const lo: i32 = self.band[ch][i][ADPCM_COEFFS + j];
                input[i] = if (use_hi) lo + self.x96_band[ch][i][ADPCM_COEFFS + j] else lo;
            }
            if (use_hi) {
                for (32..64) |i| input[i] = self.x96_band[ch][i][ADPCM_COEFFS + j];
            } else {
                for (32..64) |i| input[i] = 0;
            }
            var blk: [64]i32 = undefined;
            dsp.synthFilterFixed64(&self.hist1[ch], &self.offset_x96[ch], &self.hist2_x96[ch], window, &blk, &input);
            @memcpy(pcm[j * 64 ..][0..64], &blk);
        }
    }
};

fn popcount(mask: u32) usize {
    var m = mask;
    var c: usize = 0;
    while (m != 0) {
        c += @intCast(m & 1);
        m >>= 1;
    }
    return c;
}

fn butterflies(a: []i32, b: []i32) void {
    for (0..a.len) |i| {
        const diff = a[i] -% b[i];
        a[i] +%= b[i];
        b[i] = diff;
    }
}

/// audio_mode → 主声道扬声器位（dca_core.c prm_ch_to_spkr_map，core-only）
const prm_ch_to_spkr = [10][5]i16{
    .{ 0, -1, -1, -1, -1 },
    .{ 1, 2, -1, -1, -1 },
    .{ 1, 2, -1, -1, -1 },
    .{ 1, 2, -1, -1, -1 },
    .{ 1, 2, -1, -1, -1 },
    .{ 0, 1, 2, -1, -1 },
    .{ 1, 2, 6, -1, -1 },
    .{ 0, 1, 2, 6, -1 },
    .{ 1, 2, 3, 4, -1 },
    .{ 0, 1, 2, 3, 4 },
};

const audio_mode_ch_mask = [10]u32{
    t.speaker_c,
    t.speaker_l | t.speaker_r,
    t.speaker_l | t.speaker_r,
    t.speaker_l | t.speaker_r,
    t.speaker_l | t.speaker_r,
    t.speaker_c | t.speaker_l | t.speaker_r,
    t.speaker_l | t.speaker_r | t.speaker_cs,
    t.speaker_c | t.speaker_l | t.speaker_r | t.speaker_cs,
    t.speaker_l | t.speaker_r | t.speaker_ls | t.speaker_rs,
    t.speaker_c | t.speaker_l | t.speaker_r | t.speaker_ls | t.speaker_rs,
};

const block_code_nbits = [7]u5{ 7, 10, 12, 13, 15, 17, 19 };

fn mapPrmChToSpkrStatic(audio_mode: u8, ch: usize) usize {
    const row = prm_ch_to_spkr[audio_mode];
    return @intCast(row[ch]);
}

/// ffmpeg ff_dca_set_channel_layout 默认通道序（CHANNEL_ORDER_DEFAULT）。
const dca2wav_norm = [28]u8{
    2,  0,  1, 9, 10, 3,  8,  4,  5,  9,  10, 6, 7, 12,
    13, 14, 3, 6, 7,  11, 12, 14, 16, 15, 17, 8, 4, 5,
};
const dca2wav_wide = [28]u8{
    2,  0,  1, 4, 5, 3,  8,  4,  5,  9,  10, 6, 7, 12,
    13, 14, 3, 6, 7, 11, 12, 14, 16, 15, 17, 8, 4, 5,
};

pub fn remapOrder(mask: u32, order: *[8]u32) usize {
    const wide = mask == 0x0001FFFE or mask == 0x0001FFFF; // 7.0/7.1 wide（本阶段不产生）
    const d2w = if (wide) dca2wav_wide else dca2wav_norm;
    var wav_mask: u32 = 0;
    var wav_map: [18]u32 = [_]u32{0} ** 18;
    var nout: usize = 0;
    for (0..28) |dca_ch| {
        if (mask & (@as(u32, 1) << @intCast(dca_ch)) != 0) {
            const wav_ch: u8 = d2w[dca_ch];
            if (wav_mask & (@as(u32, 1) << @intCast(wav_ch)) == 0) {
                wav_map[wav_ch] = @intCast(dca_ch);
                wav_mask |= @as(u32, 1) << @intCast(wav_ch);
            }
        }
    }
    for (0..18) |wav_ch| {
        if (wav_mask & (@as(u32, 1) << @intCast(wav_ch)) != 0) {
            order[nout] = wav_map[wav_ch];
            nout += 1;
        }
    }
    return nout;
}

test "dts core: remapOrder 声道序与 ffmpeg 一致" {
    var o: [8]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 2), remapOrder(t.speaker_l | t.speaker_r, &o));
    try std.testing.expectEqual(@as(u32, 1), o[0]);
    try std.testing.expectEqual(@as(u32, 2), o[1]);
    try std.testing.expectEqual(@as(usize, 1), remapOrder(t.speaker_c, &o));
    try std.testing.expectEqual(@as(u32, 0), o[0]);
    const mask51 = t.speaker_c | t.speaker_l | t.speaker_r | t.speaker_ls | t.speaker_rs | t.speaker_lfe1;
    try std.testing.expectEqual(@as(usize, 6), remapOrder(mask51, &o));
    try std.testing.expectEqual(@as(u32, 1), o[0]);
    try std.testing.expectEqual(@as(u32, 2), o[1]);
    try std.testing.expectEqual(@as(u32, 0), o[2]);
    try std.testing.expectEqual(@as(u32, 5), o[3]);
    try std.testing.expectEqual(@as(u32, 3), o[4]);
    try std.testing.expectEqual(@as(u32, 4), o[5]);
}

const golden_frame_48s = @embedFile("golden_48s_frame.bin");
const golden_pcm_48s = @embedFile("golden_48s_frame_pcm.bin");

test "dts core: 48k 立体声首帧 decode == ffmpeg bitexact s32" {
    var dec = DcaDecoder.init(std.testing.allocator);
    defer dec.deinit();
    var f: DecodedFrame = undefined;
    try dec.decode(golden_frame_48s, &f);
    try std.testing.expectEqual(@as(usize, 512), f.nsamples);
    try std.testing.expectEqual(@as(usize, 2), f.nch);
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    for (0..f.nsamples) |n| {
        for (0..f.nch) |ch| {
            const v = f.planes[ch][n];
            std.mem.writeInt(i32, buf[pos..][0..4], v << 8, .little);
            pos += 4;
        }
    }
    try std.testing.expectEqualSlices(u8, golden_pcm_48s, &buf);
}

// ---- 多帧内容样本回归（真实 5.1 24bit 48k，含 LFE 有符号 8bit 音频数据）----
// core_51_24_48_768_0：.dtshd STRMDATA 载荷 = 6 个连续 core 帧（每帧 1024B）。
// golden：ffmpeg -flags +bitexact -core_only -f s32le 输出（容器丢掉前 2 个
// 初始填充单元后 4 帧 = 2048 样本 × 6ch × 4B）。修复点：LFE 采样须按
// ffmpeg get_sbits(8) 有符号读取，此前误按无符号 → 真实内容帧 LFE 平面偏差。
const core51_content_payload = @embedFile("core51_24_48_768_payload.bin");
const core51_content_gt = @embedFile("core51_24_48_768_gt.s32.bin");

test "dts core: 5.1 24bit 内容多帧（含 LFE）== ffmpeg bitexact（丢 2 初始帧后）" {
    var dec = DcaDecoder.init(std.testing.allocator);
    defer dec.deinit();

    // 逐帧定位（载荷内 core 帧连续）
    var off: usize = 0;
    var frame_no: usize = 0;
    var cmp_buf: [49152]u8 = undefined;
    var pos: usize = 0;
    while (off + 4 <= core51_content_payload.len) {
        if (!std.mem.eql(u8, core51_content_payload[off .. off + 4], &[4]u8{ 0x7F, 0xFE, 0x80, 0x01 })) {
            off += 1;
            continue;
        }
        // frame_size 自 bit46（相对帧头 bit0 偏移 5+? 处）——直接解帧头
        var hbr = BitReader.init(core51_content_payload[off..]);
        if ((try hbr.readBits(32)) != t.syncword_core_be) return error.Sync;
        _ = try hbr.readBits(1);
        _ = try hbr.readBits(5);
        _ = try hbr.readBits(1);
        _ = try hbr.readBits(7);
        const fs = @as(usize, @intCast(try hbr.readBits(14))) + 1;
        const frame = core51_content_payload[off .. off + fs];

        var f: DecodedFrame = undefined;
        try dec.decode(frame, &f);
        try std.testing.expectEqual(@as(usize, 6), f.nch);
        try std.testing.expectEqual(@as(usize, 512), f.nsamples);
        if (frame_no >= 2) {
            // 仅对照 ffmpeg 输出的 4 帧（丢容器前 2 个初始填充单元）
            for (0..f.nsamples) |n| {
                for (0..f.nch) |ch| {
                    const v = f.planes[ch][n];
                    std.mem.writeInt(i32, cmp_buf[pos..][0..4], v << 8, .little);
                    pos += 4;
                }
            }
        }
        off += fs;
        frame_no += 1;
    }
    try std.testing.expectEqual(@as(usize, 6), frame_no);
    try std.testing.expectEqual(@as(usize, 49152), pos);
    try std.testing.expectEqualSlices(u8, core51_content_gt, &cmp_buf);
}
