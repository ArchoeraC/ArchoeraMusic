// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! DTS Express（DCA-LBR，低码率扩展）解码器
//!
//! 逐函数对照 FFmpeg n9.0.1 dca_lbr.c / dcadsp.c（lbr_bank_c / lfe_iir_c）。
//! 位流为 LSB-first（BITSTREAM_READER_LE）；帧结构为字节块（chunk）流。
//!
//! 管线：EXSS asset 的 LBR 分量（sync 0x0A801921）→ 帧头（解码器初始化段：
//! 采样率/扬声器掩码/码率/带限）→ chunk 解析（LFE ADPCM、音调群、网格 1/2/3、
//! 高分辨率网格、时域样本）→ 子带域重建（随机填充/部分立体声/LPC 逆预测）→
//! 混合滤波器组（lbr_bank：短窗 + 8 点 MDCT + 高频混叠抵消）→ 音调合成 →
//! 全带 IMDCT（TDAC 长窗重叠相加）→ FLTP 平面；LFE 经 5 级双二阶 IIR 插值。
//!
//! 与 FFmpeg 的差异（公开渠道无 LBR 真实样本可对拍，见测试与交付报告）：
//!   - IMDCT 以直达公式（f64 累加）实现，数学定义与 av_tx FULL_IMDCT 一致
//!     （以 av_tx 参考向量验证），浮点舍入可差低序位；
//!   - lbr_bank / lfe_iir 与 FFmpeg C 实现输出逐位一致（参考向量测试）；
//!   - 其余运算顺序与 dca_lbr.c 逐句对应。
//!
//! 不支持（与 FFmpeg 一致地拒绝）：>48kHz、非 (无/1_2/1_4) 带限、
//! LBR_FLAG_DMIX_MULTI_CH、LBR 流版本非 0x08xx。

const std = @import("std");
const lt = @import("lbr_tables.zig");
const t = @import("tables.zig");
const dt = @import("dca_tables.zig");

pub const LBR_CHANNELS: usize = 6;
pub const LBR_CHANNELS_TOTAL: usize = 32;
pub const LBR_SUBBANDS: usize = 32;
pub const LBR_TONES: usize = 512;
pub const LBR_TIME_SAMPLES: usize = 128;
pub const LBR_TIME_HISTORY: usize = 8;
const amp_max: u32 = 56;

const header_sync_only: u8 = 1;
const header_decoder_init: u8 = 2;

// LBR_FLAG_*（dca_lbr.c）
const flag_lfe_present: u8 = 0x02;
const flag_band_limit_mask: u8 = 0x1c;
const flag_band_limit_1_2: u8 = 0x08;
const flag_band_limit_1_4: u8 = 0x10;
const flag_band_limit_none: u8 = 0x14;
const flag_dmix_stereo: u8 = 0x20;
const flag_dmix_multi_ch: u8 = 0x40;

// LBR_CHUNK_*（dca_lbr.c）
const chunk_frame: u8 = 0x04;
const chunk_frame_no_csum: u8 = 0x06;
const chunk_lfe: u8 = 0x0a;
const chunk_scf: u8 = 0x0e;
const chunk_tonal: u8 = 0x10;
const chunk_tonal_scf: u8 = 0x16;
const chunk_tonal_grp_base: u8 = 0x11; // 0x11..0x15 → group 0..4
const chunk_tonal_scf_grp_base: u8 = 0x17; // 0x17..0x1b → group 0..4
const chunk_res_grid_lr: u8 = 0x30;
const chunk_res_grid_hr: u8 = 0x40;
const chunk_res_ts_1: u8 = 0x50;
const chunk_res_ts_2: u8 = 0x60;

pub const LbrError = error{
    Invalid,
    Unsupported,
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// LSB-first 位读取器（BITSTREAM_READER_LE 的 get_bits 语义）
// ---------------------------------------------------------------------------
pub const BitReaderLE = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn init(data: []const u8) BitReaderLE {
        return .{ .data = data };
    }

    pub fn bitsLeft(self: *const BitReaderLE) i32 {
        const total = self.data.len * 8;
        if (self.pos >= total) return 0;
        return @intCast(total - self.pos);
    }

    fn readBit(self: *BitReaderLE) LbrError!u32 {
        if (self.pos >= self.data.len * 8) return error.Invalid;
        const byte = self.data[self.pos >> 3];
        const bit: u32 = (byte >> @intCast(self.pos & 7)) & 1;
        self.pos += 1;
        return bit;
    }

    /// get_bits(s, n)：首读位 = 结果最低位
    pub fn read(self: *BitReaderLE, n: u6) LbrError!u32 {
        if (self.bitsLeft() < n) return error.Invalid;
        var v: u32 = 0;
        var i: u6 = 0;
        while (i < n) : (i += 1) v |= (try self.readBit()) << @intCast(i);
        return v;
    }
};

// ---------------------------------------------------------------------------
// VLC：ff_vlc_init_from_lengths 增量码字 + entry_offset 符号偏移。
// parse_vlc 逃逸：存储符号 -1 → 先读 3 位得 n=值+1，再读 n 位返回原值。
// 树节点：child < 0 → 叶（存储符号 = -child - 2）；> 0 → 内部节点下标；0 → 空。
// ---------------------------------------------------------------------------
pub const Vlc = struct {
    /// 解码用树（tree_mem 前 nnodes*2 项）
    tree: []i32 = &.{},
    /// 完整分配（free 用，避免子切片 free）
    tree_mem: []i32 = &.{},
    alloc: std.mem.Allocator = undefined,

    pub const empty: Vlc = .{};

    /// 由 (符号, 码长) 表构建（表内顺序即码字增量顺序）
    pub fn init(alloc: std.mem.Allocator, syms: []const i16, lens: []const u8, offset: i32) LbrError!Vlc {
        std.debug.assert(syms.len == lens.len);
        const n = syms.len;
        const codes = try alloc.alloc(u32, n);
        defer alloc.free(codes);
        var code: u32 = 0;
        var ncodes: usize = 0;
        for (lens) |len| {
            if (len == 0 or len >= 32) return error.Invalid;
            if (code & ((@as(u32, 1) << @intCast(32 - len)) - 1) != 0) return error.Invalid;
            codes[ncodes] = code;
            ncodes += 1;
            code +%= @as(u32, 1) << @as(u5, @intCast(32 - @as(usize, len)));
        }
        if (code != 0) return error.Invalid; // 非完全前缀码

        var tree = try alloc.alloc(i32, 4 * ncodes);
        errdefer alloc.free(tree);
        @memset(tree, 0);
        var nnodes: usize = 1; // 根 = 0

        for (0..ncodes) |i| {
            var node: usize = 0;
            var bit: usize = 0;
            const len: usize = lens[i];
            while (bit + 1 < len) : (bit += 1) {
                const b: usize = (codes[i] >> @intCast(31 - bit)) & 1;
                const child = tree[node * 2 + b];
                if (child == 0) {
                    tree[node * 2 + b] = @intCast(nnodes);
                    node = nnodes;
                    nnodes += 1;
                } else if (child > 0) {
                    node = @intCast(child);
                } else {
                    return error.Invalid; // 前缀冲突
                }
            }
            const b: usize = (codes[i] >> @intCast(31 - bit)) & 1;
            if (tree[node * 2 + b] != 0) return error.Invalid;
            tree[node * 2 + b] = -(@as(i32, syms[i]) + offset) - 2;
        }

        return .{ .tree = tree[0 .. nnodes * 2], .tree_mem = tree, .alloc = alloc };
    }

    pub fn deinit(self: *Vlc) void {
        if (self.tree_mem.len != 0) self.alloc.free(self.tree_mem);
        self.tree = &.{};
        self.tree_mem = &.{};
    }

    /// parse_vlc（dca_lbr.c）：常规解码；存储符号 -1 → 逃逸
    pub fn decode(self: *const Vlc, br: *BitReaderLE) LbrError!i32 {
        var node: usize = 0;
        while (true) {
            const b = try br.read(1);
            const child = self.tree[node * 2 + b];
            if (child == 0) return error.Invalid; // 码字越界（合法流不出现）
            if (child < 0) {
                const sym = -child - 2;
                if (sym >= 0) return sym;
                // 罕见值逃逸：n = get_bits(3) + 1
                const n: u6 = @intCast((try br.read(3)) + 1);
                return @intCast(try br.read(n));
            }
            node = @intCast(child);
        }
    }
};

/// 全部 LBR VLC（ff_dca_init_vlcs 的 LBR 段；消费顺序一致）
pub const VlcSet = struct {
    tnl_grp: [5]Vlc = [_]Vlc{Vlc.empty} ** 5,
    tnl_scf: Vlc = Vlc.empty,
    damp: Vlc = Vlc.empty,
    dph: Vlc = Vlc.empty,
    fst_rsd_amp: Vlc = Vlc.empty,
    rsd_apprx: Vlc = Vlc.empty,
    rsd_amp: Vlc = Vlc.empty,
    avg_g3: Vlc = Vlc.empty,
    st_grid: Vlc = Vlc.empty,
    grid_2: Vlc = Vlc.empty,
    grid_3: Vlc = Vlc.empty,
    rsd: Vlc = Vlc.empty,

    pub fn deinitAll(self: *VlcSet) void {
        for (&self.tnl_grp) |*v| v.deinit();
        self.tnl_scf.deinit();
        self.damp.deinit();
        self.dph.deinit();
        self.fst_rsd_amp.deinit();
        self.rsd_apprx.deinit();
        self.rsd_amp.deinit();
        self.avg_g3.deinit();
        self.st_grid.deinit();
        self.grid_2.deinit();
        self.grid_3.deinit();
        self.rsd.deinit();
    }

    pub fn init(alloc: std.mem.Allocator) LbrError!VlcSet {
        const S = lt.vlc_src_lbr;
        var self: VlcSet = .{};
        errdefer self.deinitAll();
        self.tnl_grp[0] = try Vlc.init(alloc, &S.sym_tnl_grp_0, &S.len_tnl_grp_0, -1);
        self.tnl_grp[1] = try Vlc.init(alloc, &S.sym_tnl_grp_1, &S.len_tnl_grp_1, -1);
        self.tnl_grp[2] = try Vlc.init(alloc, &S.sym_tnl_grp_2, &S.len_tnl_grp_2, -1);
        self.tnl_grp[3] = try Vlc.init(alloc, &S.sym_tnl_grp_3, &S.len_tnl_grp_3, -1);
        self.tnl_grp[4] = try Vlc.init(alloc, &S.sym_tnl_grp_4, &S.len_tnl_grp_4, -1);
        self.tnl_scf = try Vlc.init(alloc, &S.sym_tnl_scf, &S.len_tnl_scf, -1);
        self.damp = try Vlc.init(alloc, &S.sym_damp, &S.len_damp, -1);
        self.dph = try Vlc.init(alloc, &S.sym_dph, &S.len_dph, -1);
        self.fst_rsd_amp = try Vlc.init(alloc, &S.sym_fst_rsd_amp, &S.len_fst_rsd_amp, -1);
        self.rsd_apprx = try Vlc.init(alloc, &S.sym_rsd_apprx, &S.len_rsd_apprx, -1);
        self.rsd_amp = try Vlc.init(alloc, &S.sym_rsd_amp, &S.len_rsd_amp, -1);
        self.avg_g3 = try Vlc.init(alloc, &S.sym_avg_g3, &S.len_avg_g3, -1);
        self.st_grid = try Vlc.init(alloc, &S.sym_st_grid, &S.len_st_grid, -1);
        self.grid_2 = try Vlc.init(alloc, &S.sym_grid_2, &S.len_grid_2, -1);
        self.grid_3 = try Vlc.init(alloc, &S.sym_grid_3, &S.len_grid_3, -1);
        self.rsd = try Vlc.init(alloc, &S.sym_rsd, &S.len_rsd, 0);
        return self;
    }
};

const Tone = struct {
    x_freq: u8 = 0,
    f_delt: u8 = 0,
    ph_rot: u8 = 0,
    amp: [LBR_CHANNELS]u8 = [_]u8{0} ** LBR_CHANNELS,
    phs: [LBR_CHANNELS]u8 = [_]u8{0} ** LBR_CHANNELS,
};

const Chunk = struct {
    id: u16 = 0,
    len: usize = 0,
    data: []const u8 = &.{},
};

/// cos_tab[i] = (float)cos(M_PI * i / 128)
const cos_tab: [256]f32 = blk: {
    @setEvalBranchQuota(20000);
    var tab: [256]f32 = undefined;
    for (0..256) |i| {
        tab[i] = @floatCast(@cos(std.math.pi * @as(f64, @floatFromInt(i)) / 128.0));
    }
    break :blk tab;
};

// ---------------------------------------------------------------------------
// DCALbrDecoder 移植
// ---------------------------------------------------------------------------
pub const LbrDecoder = struct {
    alloc: std.mem.Allocator,

    sample_rate: u32 = 0,
    ch_mask: u32 = 0,
    flags: u8 = 0,
    bit_rate_orig: u32 = 0,
    bit_rate_scaled: u32 = 0,

    nchannels: usize = 0,
    nchannels_total: usize = 0,
    freq_range: u8 = 0,
    band_limit: u8 = 0,
    limited_rate: u32 = 0,
    limited_range: i32 = 0,
    res_profile: u8 = 0,
    nsubbands: usize = 0,
    g3_avg_only_start_sb: usize = 0,
    min_mono_subband: usize = 0,
    max_mono_subband: usize = 0,

    framenum: u8 = 0,
    lbr_rand: u32 = 1,

    quant_levels: [LBR_CHANNELS / 2][LBR_SUBBANDS]u8 = [_][LBR_SUBBANDS]u8{[_]u8{0} ** LBR_SUBBANDS} ** (LBR_CHANNELS / 2),
    sb_indices: [LBR_SUBBANDS]u8 = [_]u8{0} ** LBR_SUBBANDS,
    sec_ch_sbms: [LBR_CHANNELS / 2][LBR_SUBBANDS]u8 = [_][LBR_SUBBANDS]u8{[_]u8{0} ** LBR_SUBBANDS} ** (LBR_CHANNELS / 2),
    sec_ch_lrms: [LBR_CHANNELS / 2][LBR_SUBBANDS]u8 = [_][LBR_SUBBANDS]u8{[_]u8{0} ** LBR_SUBBANDS} ** (LBR_CHANNELS / 2),
    ch_pres: [LBR_CHANNELS]u32 = [_]u32{0} ** LBR_CHANNELS,

    grid_1_scf: [LBR_CHANNELS][12][8]u8 = undefined,
    grid_2_scf: [LBR_CHANNELS][3][64]u8 = undefined,
    grid_3_avg: [LBR_CHANNELS][LBR_SUBBANDS - 4]i8 = undefined,
    grid_3_scf: [LBR_CHANNELS][LBR_SUBBANDS - 4][8]i8 = undefined,
    grid_3_pres: [LBR_CHANNELS]u32 = [_]u32{0} ** LBR_CHANNELS,
    high_res_scf: [LBR_CHANNELS][LBR_SUBBANDS][8]u8 = undefined,
    part_stereo: [LBR_CHANNELS][LBR_SUBBANDS / 4][5]u8 = undefined,
    part_stereo_pres: u32 = 0,

    lpc_coeff: [2][LBR_CHANNELS][3][2][8]f32 = undefined,

    sb_scf: [LBR_SUBBANDS]f32 = [_]f32{0} ** LBR_SUBBANDS,

    /// 时域样本缓冲：每 (ch,sb) 行 = 8 历史 + 128 样本 + 8 填充
    ts_buffer: []f32 = &.{},

    history: [LBR_CHANNELS][LBR_SUBBANDS * 4]f32 = [_][LBR_SUBBANDS * 4]f32{[_]f32{0} ** (LBR_SUBBANDS * 4)} ** LBR_CHANNELS,
    window: [LBR_SUBBANDS * 4]f32 = [_]f32{0} ** (LBR_SUBBANDS * 4),

    lfe_data: [64]f32 = [_]f32{0} ** 64,
    lfe_history: [5][2]f32 = [_][2]f32{[_]f32{0} ** 2} ** 5,
    lfe_scale: f32 = 0,

    tonal_scf: [6]u8 = [_]u8{0} ** 6,
    tonal_bounds: [5][32][2]u16 = [_][32][2]u16{[_][2]u16{[_]u16{0} ** 2} ** 32} ** 5,
    tones: [LBR_TONES]Tone = [_]Tone{.{}} ** LBR_TONES,
    ntones: usize = 0,

    /// IMDCT 余弦表：tab[j*n + i]（i<n/2）= cos_d(j,i)、tab[j*n + n/2 + i] = cos_u(j,i)
    mdct_tab: []f32 = &.{},
    mdct_h: []f32 = &.{},
    mdct_len: usize = 0,
    mdct_scale: f32 = 0,

    // 输出平面（帧内有效）：按 ffmpeg 帧声道序（AV_CH 规范序）
    out_planes: [8][]f32 = [_][]f32{&.{}} ** 8,
    out_buf: []f32 = &.{},
    out_nch: u8 = 0,

    vlc: ?VlcSet = null,
    /// 当前 chunk 位流（parse_tonal/grid/ts 系列共用；对齐 ffmpeg s->gb 复用）
    curr_gb: BitReaderLE = BitReaderLE.init(&.{}),

    pub fn init(alloc: std.mem.Allocator) LbrDecoder {
        return .{ .alloc = alloc, .lbr_rand = 1 };
    }

    pub fn deinit(self: *LbrDecoder) void {
        if (self.ts_buffer.len != 0) self.alloc.free(self.ts_buffer);
        self.ts_buffer = &.{};
        if (self.mdct_tab.len != 0) self.alloc.free(self.mdct_tab);
        self.mdct_tab = &.{};
        if (self.mdct_h.len != 0) self.alloc.free(self.mdct_h);
        self.mdct_h = &.{};
        if (self.out_buf.len != 0) self.alloc.free(self.out_buf);
        self.out_buf = &.{};
        if (self.vlc) |*v| v.deinitAll();
        self.vlc = null;
    }

    fn initVlcs(self: *LbrDecoder) LbrError!void {
        if (self.vlc == null) self.vlc = try VlcSet.init(self.alloc);
    }


    // -- lbr_rand（dca_lbr.c）：int32 环绕乘加，返回 int * float --
    inline fn lbrRand(self: *LbrDecoder, sb: usize) f32 {
        self.lbr_rand = 1103515245 *% self.lbr_rand +% 12345;
        return @as(f32, @floatFromInt(@as(i32, @bitCast(self.lbr_rand)))) * self.sb_scf[sb];
    }

    // ==========================================================================
    // ff_dca_lbr_parse：字节流层
    // ==========================================================================
    const ByteCursor = struct {
        data: []const u8,
        pos: usize = 0,

        fn left(self: *const ByteCursor) usize {
            return self.data.len - @min(self.pos, self.data.len);
        }
        fn byte(self: *ByteCursor) LbrError!u8 {
            if (self.pos >= self.data.len) return error.Invalid;
            const v = self.data[self.pos];
            self.pos += 1;
            return v;
        }
        fn le16(self: *ByteCursor) LbrError!u16 {
            const lo = try self.byte();
            const hi = try self.byte();
            return @as(u16, lo) | (@as(u16, hi) << 8);
        }
        fn be16(self: *ByteCursor) LbrError!u16 {
            const hi = try self.byte();
            const lo = try self.byte();
            return (@as(u16, hi) << 8) | lo;
        }
        fn be32(self: *ByteCursor) LbrError!u32 {
            const hi = try self.be16();
            const lo = try self.be16();
            return (@as(u32, hi) << 16) | lo;
        }
    };

    /// ff_dca_lbr_parse：data = EXSS 子流中 lbr_offset 起的 lbr_size 字节
    pub fn parse(self: *LbrDecoder, data: []const u8) LbrError!void {
        try self.initVlcs();

        var chunk_lfe_c: Chunk = .{};
        var chunk_tonal_c: Chunk = .{};
        var chunk_tonal_grp: [5]Chunk = [_]Chunk{.{}} ** 5;
        var chunk_grid1: [LBR_CHANNELS / 2]Chunk = [_]Chunk{.{}} ** (LBR_CHANNELS / 2);
        var chunk_hr_grid: [LBR_CHANNELS / 2]Chunk = [_]Chunk{.{}} ** (LBR_CHANNELS / 2);
        var chunk_ts1: [LBR_CHANNELS / 2]Chunk = [_]Chunk{.{}} ** (LBR_CHANNELS / 2);
        var chunk_ts2: [LBR_CHANNELS / 2]Chunk = [_]Chunk{.{}} ** (LBR_CHANNELS / 2);

        var gb = ByteCursor{ .data = data };

        // LBR sync word
        if ((try gb.be32()) != t.syncword_lbr) return error.Invalid;

        // LBR header type
        switch (try gb.byte()) {
            header_sync_only => {
                if (self.sample_rate == 0) return error.Invalid;
            },
            header_decoder_init => {
                self.parseDecoderInit(&gb) catch |e| {
                    self.sample_rate = 0;
                    return e;
                };
            },
            else => return error.Invalid,
        }

        // LBR frame chunk header
        var chunk_id = try gb.byte();
        var chunk_len: usize = if (chunk_id & 0x80 != 0) (try gb.be16()) else (try gb.byte());
        if (chunk_len > gb.left()) chunk_len = gb.left(); // 截断 → 继续（非 EXPLODE）

        var frame = ByteCursor{ .data = gb.data[gb.pos..][0..chunk_len] };

        switch (chunk_id & 0x7f) {
            chunk_frame => frame.pos = 2, // 校验和跳过（err_recognition 默认关闭）
            chunk_frame_no_csum => {},
            else => return error.Invalid,
        }

        // 清空当前帧状态
        self.quant_levels = [_][LBR_SUBBANDS]u8{[_]u8{0} ** LBR_SUBBANDS} ** (LBR_CHANNELS / 2);
        self.sb_indices = [_]u8{0xff} ** LBR_SUBBANDS;
        self.sec_ch_sbms = [_][LBR_SUBBANDS]u8{[_]u8{0} ** LBR_SUBBANDS} ** (LBR_CHANNELS / 2);
        self.sec_ch_lrms = [_][LBR_SUBBANDS]u8{[_]u8{0} ** LBR_SUBBANDS} ** (LBR_CHANNELS / 2);
        self.ch_pres = [_]u32{0} ** LBR_CHANNELS;
        self.grid_1_scf = [_][12][8]u8{[_][8]u8{[_]u8{0} ** 8} ** 12} ** LBR_CHANNELS;
        self.grid_2_scf = [_][3][64]u8{[_][64]u8{[_]u8{0} ** 64} ** 3} ** LBR_CHANNELS;
        self.grid_3_avg = [_][LBR_SUBBANDS - 4]i8{[_]i8{0} ** (LBR_SUBBANDS - 4)} ** LBR_CHANNELS;
        self.grid_3_scf = [_][LBR_SUBBANDS - 4][8]i8{[_][8]i8{[_]i8{0} ** 8} ** (LBR_SUBBANDS - 4)} ** LBR_CHANNELS;
        self.grid_3_pres = [_]u32{0} ** LBR_CHANNELS;
        self.tonal_scf = [_]u8{0} ** 6;
        self.lfe_data = [_]f32{0} ** 64;
        self.part_stereo_pres = 0;
        self.framenum = (self.framenum + 1) & 31;

        for (0..self.nchannels) |ch| {
            for (0..self.nsubbands / 4) |sb| {
                self.part_stereo[ch][sb][0] = self.part_stereo[ch][sb][4];
                self.part_stereo[ch][sb][4] = 16;
            }
        }

        self.lpc_coeff[self.framenum & 1] = zero_lpc: {
            break :zero_lpc [_][3][2][8]f32{[_][2][8]f32{[_][8]f32{[_]f32{0} ** 8} ** 2} ** 3} ** LBR_CHANNELS;
        };

        for (0..5) |group| {
            for (0..@as(usize, 1) << @intCast(group)) |sf| {
                const sf_idx: usize = ((@as(usize, self.framenum) << @intCast(group)) + sf) & 31;
                self.tonal_bounds[group][sf_idx][0] = @intCast(self.ntones);
                self.tonal_bounds[group][sf_idx][1] = @intCast(self.ntones);
            }
        }

        // chunk 头扫描
        while (frame.left() > 0) {
            chunk_id = try frame.byte();
            chunk_len = if (chunk_id & 0x80 != 0) (try frame.be16()) else (try frame.byte());
            chunk_id &= 0x7f;
            if (chunk_len > frame.left()) chunk_len = frame.left();
            const cdata = frame.data[frame.pos..][0..chunk_len];

            switch (chunk_id) {
                chunk_lfe => chunk_lfe_c = .{ .id = chunk_id, .len = chunk_len, .data = cdata },
                chunk_scf, chunk_tonal, chunk_tonal_scf => chunk_tonal_c = .{ .id = chunk_id, .len = chunk_len, .data = cdata },
                chunk_tonal_grp_base...chunk_tonal_grp_base + 4 => {
                    const i = chunk_id - chunk_tonal_grp_base;
                    chunk_tonal_grp[i] = .{ .id = i, .len = chunk_len, .data = cdata };
                },
                chunk_tonal_scf_grp_base...chunk_tonal_scf_grp_base + 4 => {
                    const i = chunk_id - chunk_tonal_scf_grp_base;
                    chunk_tonal_grp[i] = .{ .id = i, .len = chunk_len, .data = cdata };
                },
                chunk_res_grid_lr...chunk_res_grid_lr + 2 => {
                    const i = chunk_id - chunk_res_grid_lr;
                    chunk_grid1[i] = .{ .id = chunk_id, .len = chunk_len, .data = cdata };
                },
                chunk_res_grid_hr...chunk_res_grid_hr + 2 => {
                    const i = chunk_id - chunk_res_grid_hr;
                    chunk_hr_grid[i] = .{ .id = chunk_id, .len = chunk_len, .data = cdata };
                },
                chunk_res_ts_1...chunk_res_ts_1 + 2 => {
                    const i = chunk_id - chunk_res_ts_1;
                    chunk_ts1[i] = .{ .id = chunk_id, .len = chunk_len, .data = cdata };
                },
                chunk_res_ts_2...chunk_res_ts_2 + 2 => {
                    const i = chunk_id - chunk_res_ts_2;
                    chunk_ts2[i] = .{ .id = chunk_id, .len = chunk_len, .data = cdata };
                },
                else => {}, // 保留/扩展 id 忽略（对齐 ffmpeg）
            }

            frame.pos += chunk_len;
        }

        // 解析各 chunk（失败不致命；对齐 ffmpeg 非 EXPLODE 语义）
        self.parseLfeChunk(&chunk_lfe_c) catch {};
        self.parseTonalChunk(&chunk_tonal_c) catch {};
        for (0..5) |i| {
            self.parseTonalGroup(&chunk_tonal_grp[i]) catch {};
        }

        for (0..(self.nchannels + 1) / 2) |i| {
            const ch1 = i * 2;
            const ch2 = @min(ch1 + 1, self.nchannels - 1);

            var grid_ok = true;
            if (self.parseGrid1Chunk(&chunk_grid1[i], ch1, ch2)) |_| {
                if (self.parseHighResGrid(&chunk_hr_grid[i], ch1, ch2)) |_| {
                    grid_ok = true;
                } else |_| grid_ok = false;
            } else |_| grid_ok = false;
            if (!grid_ok) continue;

            if (chunk_grid1[i].len == 0 or chunk_hr_grid[i].len == 0 or chunk_ts1[i].len == 0)
                continue;

            self.parseTs1Chunk(&chunk_ts1[i], ch1, ch2) catch continue;
            self.parseTs2Chunk(&chunk_ts2[i], ch1, ch2) catch continue;
        }
    }

    // ==========================================================================
    // parse_decoder_init（dca_lbr.c）
    // ==========================================================================
    fn parseDecoderInit(self: *LbrDecoder, gb: *ByteCursor) LbrError!void {
        const old_rate = self.sample_rate;
        const old_band_limit = self.band_limit;
        const old_nchannels = self.nchannels;

        // 采样率。注意 LBR 帧头 sr_code 走 ff_dca_sampling_freqs（dca.c），
        // 与 core 子流的 ff_dca_sample_rate_tab（tables.zig sample_rates）是两张表。
        const sr_code = try gb.byte();
        if (sr_code >= dt.ff_dca_sampling_freqs.len) return error.Invalid;
        self.sample_rate = dt.ff_dca_sampling_freqs[sr_code];
        if (self.sample_rate > 48000) return error.Unsupported;

        // LBR 扬声器掩码（DCA_SPEAKER_PAIR 位布局：bit0=C bit1=LR bit2=LsRs bit3=LFE1...）
        self.ch_mask = try gb.le16();
        if (self.ch_mask & 0x7 == 0) return error.Unsupported;

        // 流版本
        const version = try gb.le16();
        if (version & 0xff00 != 0x0800) return error.Unsupported;

        // 初始化标志
        self.flags = try gb.byte();
        if (self.flags & flag_dmix_multi_ch != 0) return error.Unsupported;
        if (self.flags & flag_lfe_present != 0 and self.sample_rate != 48000)
            self.flags &= ~flag_lfe_present; // FFmpeg 同：警告后去除 LFE

        // 码率
        const bit_rate_hi = try gb.byte();
        self.bit_rate_orig = (try gb.le16()) | (@as(u32, bit_rate_hi & 0x0F) << 16);
        self.bit_rate_scaled = (try gb.le16()) | (@as(u32, bit_rate_hi & 0xF0) << 12);

        // 全带声道数
        self.nchannels_total = countChsForMask(self.ch_mask & ~@as(u32, 0x8));
        self.nchannels = @min(self.nchannels_total, LBR_CHANNELS);

        // 带限
        switch (self.flags & flag_band_limit_mask) {
            flag_band_limit_none => self.band_limit = 0,
            flag_band_limit_1_2 => self.band_limit = 1,
            flag_band_limit_1_4 => self.band_limit = 2,
            else => return error.Unsupported,
        }

        // 频率范围
        self.freq_range = lt.ff_dca_freq_ranges[sr_code];

        // 分辨率档
        if (self.bit_rate_orig >= 44000 * (self.nchannels_total + 2))
            self.res_profile = 2
        else if (self.bit_rate_orig >= 25000 * (self.nchannels_total + 2))
            self.res_profile = 1
        else
            self.res_profile = 0;

        // 有限采样率 / 子带数
        self.limited_rate = self.sample_rate >> @intCast(self.band_limit);
        self.limited_range = @as(i32, self.freq_range) - @as(i32, self.band_limit);
        if (self.limited_range < 0) return error.Invalid;
        // limited_range > 2 时上游 C 源存在多处缓冲区越界 UB（nsubbands=64>32、
        // 窗 256>128、IMDCT scale NaN）——合法流不会出现；此处拒绝以保证内存安全。
        if (self.limited_range > 2) return error.Unsupported;

        self.nsubbands = @as(usize, 8) << @intCast(self.limited_range);

        self.g3_avg_only_start_sb = @min(
            self.nsubbands * lt.ff_dca_avg_g3_freqs[self.res_profile] / (self.limited_rate / 2),
            self.nsubbands,
        );
        self.min_mono_subband = @min(self.nsubbands * 2000 / (self.limited_rate / 2), self.nsubbands);
        self.max_mono_subband = @min(self.nsubbands * 14000 / (self.limited_rate / 2), self.nsubbands);

        // 采样率/带限变化 → 重算窗与 IMDCT 表
        if (old_rate != self.sample_rate or old_band_limit != self.band_limit)
            try self.initSampleRate();

        // 立体声内嵌下混（FFmpeg：警告后仍按立体声重配）
        if (self.flags & flag_dmix_stereo != 0) {
            if (self.nchannels_total < 3 or self.nchannels_total > LBR_CHANNELS_TOTAL - 2)
                return error.Invalid;
            self.nchannels_total += 2;
            self.nchannels = 2;
            self.ch_mask = 0x2; // DCA_SPEAKER_PAIR_LR
            self.flags &= ~flag_lfe_present;
        }

        // 采样率或声道数变化 → 重分配样本缓冲 + flush
        if (old_rate != self.sample_rate or old_band_limit != self.band_limit or
            old_nchannels != self.nchannels)
        {
            try self.allocSampleBuffer();
            self.flush();
        }
    }

    /// ff_dca_count_chs_for_mask：popcount((mask & 0xffff) | ((mask & 0xae66) << 16))
    fn countChsForMask(mask: u32) usize {
        const m = (mask & 0xffff) | ((mask & 0xae66) << 16);
        return popcount32(m);
    }

    /// init_sample_rate：长窗、随机化尺度、LFE 尺度、IMDCT 余弦表
    fn initSampleRate(self: *LbrDecoder) LbrError!void {
        // C 源：sqrt(1 << (2 - limited_range))。limited_range > 2 时为 C 移位 UB，
        // GCC/x86 实际计算 1 << 31 = INT_MIN → sqrt → NaN（av_tx 参考向量证实）。
        // 为与 FFmpeg 输出一致，此处显式复现该行为。
        // limited_range ≤ 2（parse_decoder_init 保证）→ C 源 sqrt(1 << (2-lr)) 无 UB
        const imdct_scale: f64 = (-1.0 / @as(f64, 1 << 17)) *
            @sqrt(@as(f64, @floatFromInt(@as(i32, 1) << @intCast(2 - self.limited_range))));
        const scale_t: f32 = @floatCast(imdct_scale);

        const nwin = @as(usize, 32) << @intCast(self.freq_range);
        // 长窗按 freq_range 抽取（C 源：i << (2 - s->freq_range)，与 band_limit 无关）
        for (0..nwin) |i| {
            self.window[i] = lt.ff_dca_long_window[i << @intCast(2 - self.freq_range)];
        }

        var scale = imdct_scale;
        const br_per_ch = self.bit_rate_scaled / self.nchannels_total;
        if (br_per_ch < 14000)
            scale = 0.85
        else if (br_per_ch < 32000)
            scale = @as(f64, @floatFromInt(br_per_ch - 14000)) * (1.0 / 120000.0) + 0.85
        else
            scale = 1.0;
        scale *= 1.0 / @as(f64, std.math.maxInt(i32));

        for (0..self.nsubbands) |i| {
            if (i < 2)
                self.sb_scf[i] = 0
            else if (i < 5)
                self.sb_scf[i] = @floatCast(@as(f64, @floatFromInt(i - 1)) * 0.25 * 0.785 * scale)
            else
                self.sb_scf[i] = @floatCast(0.785 * scale);
        }

        self.lfe_scale = @floatCast(@as(f64, @floatFromInt(@as(i32, 16) << @intCast(self.freq_range))) * 0.0000078265894);

        // IMDCT 余弦表（av_tx naive 公式；N = 32<<freq_range）
        const n = nwin;
        if (self.mdct_len != n) {
            if (self.mdct_tab.len != 0) self.alloc.free(self.mdct_tab);
            if (self.mdct_h.len != 0) self.alloc.free(self.mdct_h);
            self.mdct_tab = try self.alloc.alloc(f32, n * n);
            self.mdct_h = try self.alloc.alloc(f32, n);
            self.mdct_len = n;
        }
        self.mdct_scale = scale_t;
        const half = n / 2;
        for (0..n) |j| {
            const a: f64 = 2.0 * @as(f64, @floatFromInt(j)) + 1.0;
            const phase = std.math.pi / (4.0 * @as(f64, @floatFromInt(n)));
            for (0..half) |i| {
                // av_tx naive：k_d = 4·(N/2) − 2i − 1 = 2N − 2i − 1
                //             k_u = 3·N + 2i + 1（len2 = N）
                const k_d: f64 = @floatFromInt(2 * n - 2 * i - 1);
                const k_u: f64 = @floatFromInt(3 * n + 2 * i + 1);
                self.mdct_tab[j * n + i] = @floatCast(@cos(a * phase * k_d));
                self.mdct_tab[j * n + half + i] = @floatCast(@cos(a * phase * k_u));
            }
        }
    }

    /// alloc_sample_buffer
    fn allocSampleBuffer(self: *LbrDecoder) LbrError!void {
        const nchsamples = LBR_TIME_SAMPLES + LBR_TIME_HISTORY * 2;
        const need = nchsamples * self.nchannels * self.nsubbands;
        if (self.ts_buffer.len < need) {
            if (self.ts_buffer.len != 0) self.alloc.free(self.ts_buffer);
            self.ts_buffer = try self.alloc.alloc(f32, need);
        }
        @memset(self.ts_buffer, 0);
    }

    /// 行切片：[0..8)=历史，[8..136)=数据（128 样本）
    inline fn timeSamples(self: *LbrDecoder, ch: usize, sb: usize) []f32 {
        const nchsamples = LBR_TIME_SAMPLES + LBR_TIME_HISTORY * 2;
        const base = (ch * self.nsubbands + sb) * nchsamples;
        return self.ts_buffer[base .. base + nchsamples];
    }

    /// ff_dca_lbr_flush
    pub fn flush(self: *LbrDecoder) void {
        if (self.sample_rate == 0) return;
        self.part_stereo = [_][LBR_SUBBANDS / 4][5]u8{[_][5]u8{[_]u8{16} ** 5} ** (LBR_SUBBANDS / 4)} ** LBR_CHANNELS;
        self.lpc_coeff = [_][LBR_CHANNELS][3][2][8]f32{[_][3][2][8]f32{[_][2][8]f32{[_][8]f32{[_]f32{0} ** 8} ** 2} ** 3} ** LBR_CHANNELS} ** 2;
        self.history = [_][LBR_SUBBANDS * 4]f32{[_]f32{0} ** (LBR_SUBBANDS * 4)} ** LBR_CHANNELS;
        self.tonal_bounds = [_][32][2]u16{[_][2]u16{[_]u16{0} ** 2} ** 32} ** 5;
        self.lfe_history = [_][2]f32{[_]f32{0} ** 2} ** 5;
        self.framenum = 0;
        self.ntones = 0;
        for (0..self.nchannels) |ch| {
            for (0..self.nsubbands) |sb| {
                @memset(self.timeSamples(ch, sb)[0..LBR_TIME_HISTORY], 0);
            }
        }
    }

    // ==========================================================================
    // LFE（parse_lfe_24 / parse_lfe_16 / parse_lfe_chunk）
    // ==========================================================================
    fn parseLfe24(self: *LbrDecoder, br: *BitReaderLE) LbrError!void {
        const step_max: i32 = lt.ff_dca_lfe_step_size_24.len - 1;

        const ps: u32 = try br.read(24);
        const si: i32 = @intCast(ps >> 23);
        const mag: i32 = @intCast(ps & 0x7fffff);
        var value: f32 = @as(f32, @floatFromInt((mag ^ -si) +% si)) * (1.0 / @as(f32, 0x7fffff));

        var step_i: i32 = @intCast(try br.read(8));
        if (step_i > step_max) return error.Invalid;

        var step = lt.ff_dca_lfe_step_size_24[@intCast(step_i)];

        for (0..64) |i| {
            const code = try br.read(6);

            var delta = step * 0.03125;
            if (code & 16 != 0) delta += step;
            if (code & 8 != 0) delta += step * 0.5;
            if (code & 4 != 0) delta += step * 0.25;
            if (code & 2 != 0) delta += step * 0.125;
            if (code & 1 != 0) delta += step * 0.0625;

            if (code & 32 != 0) {
                value -= delta;
                if (value < -3.0) value = -3.0;
            } else {
                value += delta;
                if (value > 3.0) value = 3.0;
            }

            step_i += lt.ff_dca_lfe_delta_index_24[code & 31];
            step_i = std.math.clamp(step_i, 0, step_max);

            step = lt.ff_dca_lfe_step_size_24[@intCast(step_i)];
            self.lfe_data[i] = value * self.lfe_scale;
        }
    }

    fn parseLfe16(self: *LbrDecoder, br: *BitReaderLE) LbrError!void {
        const step_max: i32 = lt.ff_dca_lfe_step_size_16.len - 1;

        const ps: u32 = try br.read(16);
        const si: i32 = @intCast(ps >> 15);
        const mag: i32 = @intCast(ps & 0x7fff);
        var value: f32 = @as(f32, @floatFromInt((mag ^ -si) +% si)) * (1.0 / @as(f32, 0x7fff));

        var step_i: i32 = @intCast(try br.read(8));
        if (step_i > step_max) return error.Invalid;

        var step = lt.ff_dca_lfe_step_size_16[@intCast(step_i)];

        for (0..64) |i| {
            const code = try br.read(4);

            var delta = step * 0.125;
            if (code & 4 != 0) delta += step;
            if (code & 2 != 0) delta += step * 0.5;
            if (code & 1 != 0) delta += step * 0.25;

            if (code & 8 != 0) {
                value -= delta;
                if (value < -3.0) value = -3.0;
            } else {
                value += delta;
                if (value > 3.0) value = 3.0;
            }

            step_i += lt.ff_dca_lfe_delta_index_16[code & 7];
            step_i = std.math.clamp(step_i, 0, step_max);

            step = lt.ff_dca_lfe_step_size_16[@intCast(step_i)];
            self.lfe_data[i] = value * self.lfe_scale;
        }
    }

    fn parseLfeChunk(self: *LbrDecoder, chunk: *const Chunk) LbrError!void {
        if (self.flags & flag_lfe_present == 0) return;
        if (chunk.len == 0) return;
        var br = BitReaderLE.init(chunk.data);
        if (chunk.len >= 52) return self.parseLfe24(&br);
        if (chunk.len >= 35) return self.parseLfe16(&br);
        return error.Invalid;
    }

    // ==========================================================================
    // 音调（parse_vlc / parse_tonal / parse_tonal_chunk / parse_tonal_group）
    // ==========================================================================
    fn parseVlc(self: *LbrDecoder, vlc: *const Vlc) LbrError!u32 {
        const v = try vlc.decode(&self.curr_gb);
        if (v < 0) return error.Invalid;
        return @intCast(v);
    }

    fn parseTonal(self: *LbrDecoder, group: usize) LbrError!void {
        const v = &(self.vlc.?);
        var amp: [LBR_CHANNELS_TOTAL]u32 = undefined;
        var phs: [LBR_CHANNELS_TOTAL]u32 = undefined;
        const ch_nbits: u6 = @intCast(ceilLog2(self.nchannels_total));

        var diff: u32 = 0;
        var sf: usize = 0;
        while (sf < @as(usize, 1) << @intCast(group)) : (sf += if (diff != 0) 8 else 1) {
            const sf_idx: usize = ((@as(usize, self.framenum) << @intCast(group)) + sf) & 31;
            self.tonal_bounds[group][sf_idx][0] = @intCast(self.ntones);

            var freq: usize = 1;
            while (true) : (freq += 1) {
                if (self.curr_gb.bitsLeft() < 1) return error.Invalid;

                diff = try self.parseVlc(&v.tnl_grp[group]);
                if (diff >= lt.ff_dca_fst_amp.len) return error.Invalid;

                diff = (try self.curr_gb.read(@intCast(diff >> 2))) + lt.ff_dca_fst_amp[diff];
                if (diff <= 1) break; // 子帧结束

                freq += diff - 2;
                if (freq >> @as(u6, @intCast(5 - group)) > self.nsubbands * 4 - 6) return error.Invalid;

                // 主声道
                const main_ch: usize = @intCast(try self.curr_gb.read(ch_nbits));
                var main_amp: u32 = try self.parseVlc(&v.tnl_scf);
                const sb_idx: usize = freq >> @as(u6, @intCast(7 - group));
                if (sb_idx >= lt.ff_dca_freq_to_sb.len) return error.Invalid;
                main_amp +%= lt.ff_dca_freq_to_sb[sb_idx];
                main_amp +%= @intCast(self.limited_range);
                main_amp -%= 2;
                amp[main_ch] = if (main_amp < amp_max) main_amp else 0;
                phs[main_ch] = try self.curr_gb.read(3);

                // 次声道
                for (0..self.nchannels_total) |ch| {
                    if (ch == main_ch) continue;
                    if ((try self.curr_gb.read(1)) != 0) {
                        amp[ch] = amp[main_ch] -% (try self.parseVlc(&v.damp));
                        phs[ch] = phs[main_ch] -% (try self.parseVlc(&v.dph));
                    } else {
                        amp[ch] = 0;
                        phs[ch] = 0;
                    }
                }

                if (amp[main_ch] != 0) {
                    // 分配新音调
                    const tp = &self.tones[self.ntones];
                    self.ntones = (self.ntones + 1) & (LBR_TONES - 1);

                    tp.x_freq = @intCast(freq >> @as(u6, @intCast(5 - group)));
                    tp.f_delt = @intCast((freq & ((@as(usize, 1) << @as(u6, @intCast(5 - group))) - 1)) << @as(u6, @intCast(group)));
                    const xf: i32 = @intCast(tp.x_freq & 1);
                    const fd: i32 = @intCast(tp.f_delt);
                    const ph_rot_i: i32 = @as(i32, 256) - xf * 128 - fd * 4;
                    tp.ph_rot = @truncate(@as(u32, @bitCast(ph_rot_i)));

                    const shift: i32 = @as(i32, lt.ff_dca_ph0_shift[(tp.x_freq & 3) * 2 + (freq & 1)]) -
                        ((@as(i32, @intCast(tp.ph_rot)) << @as(u5, @intCast(5 - group))) - @as(i32, @intCast(tp.ph_rot)));

                    for (0..self.nchannels) |ch| {
                        tp.amp[ch] = if (amp[ch] < amp_max) @intCast(amp[ch]) else 0;
                        const phs_i: i32 = @as(i32, 128) - @as(i32, @intCast(phs[ch])) * 32 + shift;
                        tp.phs[ch] = @truncate(@as(u32, @bitCast(phs_i)));
                    }
                }
            }

            self.tonal_bounds[group][sf_idx][1] = @intCast(self.ntones);
        }
    }

    fn parseTonalChunk(self: *LbrDecoder, chunk: *const Chunk) LbrError!void {
        if (chunk.len == 0) return;
        self.curr_gb = BitReaderLE.init(chunk.data);

        // 音调尺度因子（SCF / TONAL_SCF）
        if (chunk.id == chunk_scf or chunk.id == chunk_tonal_scf) {
            if (self.curr_gb.bitsLeft() < 36) return error.Invalid;
            for (0..6) |sb| self.tonal_scf[sb] = @intCast(try self.curr_gb.read(6));
        }

        // 音调群（TONAL / TONAL_SCF）
        if (chunk.id == chunk_tonal or chunk.id == chunk_tonal_scf) {
            for (0..5) |group| try self.parseTonal(group);
        }
    }

    fn parseTonalGroup(self: *LbrDecoder, chunk: *const Chunk) LbrError!void {
        if (chunk.len == 0) return;
        self.curr_gb = BitReaderLE.init(chunk.data);
        return self.parseTonal(chunk.id);
    }

    // ==========================================================================
    // 尺度因子 / 网格
    // ==========================================================================
    /// ensure_bits：不足 n 位 → 跳至末尾（返回 true 表示已截断）
    fn ensureBits(br: *BitReaderLE, n: i32) LbrError!bool {
        const left = br.bitsLeft();
        if (left < n) {
            br.pos = br.data.len * 8;
            return true;
        }
        return false;
    }

    fn parseScaleFactors(self: *LbrDecoder, scf: []u8) LbrError!void {
        const v = &(self.vlc.?);
        const br = &self.curr_gb;

        if (try ensureBits(br, 20)) return;

        var prev: i32 = @intCast(try self.parseVlc(&v.fst_rsd_amp));

        var sf: usize = 0;
        var dist: usize = 1;
        var next: i32 = prev;
        while (sf < 7) : (sf += dist) {
            scf[sf] = @intCast(prev);

            if (try ensureBits(br, 20)) return;

            dist = @as(usize, try self.parseVlc(&v.rsd_apprx)) + 1;
            if (dist > 7 - sf) return error.Invalid;

            if (try ensureBits(br, 20)) return;

            next = @intCast(try self.parseVlc(&v.rsd_amp));
            if (next & 1 != 0)
                next = prev + ((next + 1) >> 1)
            else
                next = prev - (next >> 1);

            switch (dist) {
                2 => {
                    if (next > prev)
                        scf[sf + 1] = @intCast(prev + ((next - prev) >> 1))
                    else
                        scf[sf + 1] = @intCast(prev - ((prev - next) >> 1));
                },
                4 => {
                    if (next > prev) {
                        scf[sf + 1] = @intCast(prev + ((next - prev) >> 2));
                        scf[sf + 2] = @intCast(prev + ((next - prev) >> 1));
                        scf[sf + 3] = @intCast(prev + (((next - prev) * 3) >> 2));
                    } else {
                        scf[sf + 1] = @intCast(prev - ((prev - next) >> 2));
                        scf[sf + 2] = @intCast(prev - ((prev - next) >> 1));
                        scf[sf + 3] = @intCast(prev - (((prev - next) * 3) >> 2));
                    }
                },
                else => {
                    var i: usize = 1;
                    while (i < dist) : (i += 1) {
                        scf[sf + i] = @intCast(prev + @divTrunc((next - prev) * @as(i32, @intCast(i)), @as(i32, @intCast(dist))));
                    }
                },
            }

            prev = next;
        }

        scf[sf] = @intCast(next);
    }

    fn parseStCode(self: *LbrDecoder, min_v: u32) LbrError!u32 {
        const v = &(self.vlc.?);
        var val: u32 = (try self.parseVlc(&v.st_grid)) +% min_v;

        if (val & 1 != 0)
            val = 16 + (val >> 1)
        else
            val = 16 -% (val >> 1);

        if (val >= lt.ff_dca_st_coeff.len) val = 16;
        return val;
    }

    fn parseGrid1Chunk(self: *LbrDecoder, chunk: *const Chunk, ch1: usize, ch2: usize) LbrError!void {
        if (chunk.len == 0) return;
        self.curr_gb = BitReaderLE.init(chunk.data);
        const br = &self.curr_gb;

        // 尺度因子
        const nscf = lt.ff_dca_scf_to_grid_1[self.nsubbands - 1] + 1;
        for (2..nscf) |sb| {
            try self.parseScaleFactors(&self.grid_1_scf[ch1][sb]);
            if (ch1 != ch2 and lt.ff_dca_grid_1_to_scf[sb] < self.min_mono_subband)
                try self.parseScaleFactors(&self.grid_1_scf[ch2][sb]);
        }

        if (br.bitsLeft() < 1) return;

        // 第三网格均值
        for (0..self.nsubbands - 4) |sb| {
            self.grid_3_avg[ch1][sb] = @intCast(@as(i32, @intCast(try self.parseVlc(&(self.vlc.?).avg_g3))) - 16);
            if (ch1 != ch2) {
                if (sb + 4 < self.min_mono_subband)
                    self.grid_3_avg[ch2][sb] = @intCast(@as(i32, @intCast(try self.parseVlc(&(self.vlc.?).avg_g3))) - 16)
                else
                    self.grid_3_avg[ch2][sb] = self.grid_3_avg[ch1][sb];
            }
        }

        if (br.bitsLeft() < 0) return error.Invalid;

        // 部分单声道模式立体声信息
        if (ch1 != ch2) {
            if (try ensureBits(br, 8)) return;

            const min_v: [2]u32 = .{ @intCast(try br.read(4)), @intCast(try br.read(4)) };

            const nps = (self.nsubbands - self.min_mono_subband + 3) / 4;
            for (0..nps) |sb| {
                var ch = ch1;
                while (ch <= ch2) : (ch += 1) {
                    for (1..5) |sf| {
                        self.part_stereo[ch][sb][sf] = @intCast(try self.parseStCode(min_v[ch - ch1]));
                    }
                }
            }

            if (br.bitsLeft() >= 0)
                self.part_stereo_pres |= @as(u32, 1) << @intCast(ch1);
        }
    }

    fn parseGrid1SecCh(self: *LbrDecoder, ch2: usize) LbrError!void {
        // 尺度因子
        const nscf = lt.ff_dca_scf_to_grid_1[self.nsubbands - 1] + 1;
        for (2..nscf) |sb| {
            if (lt.ff_dca_grid_1_to_scf[sb] >= self.min_mono_subband)
                try self.parseScaleFactors(&self.grid_1_scf[ch2][sb]);
        }

        // 第三网格均值
        for (0..self.nsubbands - 4) |sb| {
            if (sb + 4 >= self.min_mono_subband) {
                if (try ensureBits(&self.curr_gb, 20)) return;
                self.grid_3_avg[ch2][sb] = @intCast(@as(i32, @intCast(try self.parseVlc(&(self.vlc.?).avg_g3))) - 16);
            }
        }
    }

    fn parseGrid3(self: *LbrDecoder, ch1: usize, ch2: usize, sb: usize, flag: bool) LbrError!void {
        var ch = ch1;
        while (ch <= ch2) : (ch += 1) {
            if ((ch != ch1 and sb + 4 >= self.min_mono_subband) != flag) continue;
            if (self.grid_3_pres[ch] & (@as(u32, 1) << @intCast(sb)) != 0) continue;

            for (0..8) |i| {
                if (try ensureBits(&self.curr_gb, 20)) return;
                self.grid_3_scf[ch][sb][i] = @intCast(@as(i32, @intCast(try self.parseVlc(&(self.vlc.?).grid_3))) - 16);
            }

            self.grid_3_pres[ch] |= @as(u32, 1) << @intCast(sb);
        }
    }

    /// parse_ch：一个子带的时域样本（截断部分以随机数填充）
    fn parseCh(self: *LbrDecoder, ch: usize, sb: usize, quant_level: u8, flag: bool) LbrError!void {
        const samples = self.timeSamples(ch, sb)[LBR_TIME_HISTORY..];
        const br = &self.curr_gb;

        if (try ensureBits(br, 20)) return;

        const coding_method = (try br.read(1)) != 0;

        var i: usize = 0;
        switch (quant_level) {
            1 => {
                const nblocks: usize = @min(@as(usize, @intCast(br.bitsLeft())) / 8, LBR_TIME_SAMPLES / 8);
                for (0..nblocks) |blk| {
                    const code = try br.read(8);
                    const base = blk * 8;
                    for (0..8) |j| {
                        samples[base + j] = lt.ff_dca_rsd_level_2a[(code >> @intCast(j)) & 1];
                    }
                }
                i = nblocks * 8;
            },
            2 => {
                if (coding_method) {
                    while (i < LBR_TIME_SAMPLES and br.bitsLeft() >= 2) : (i += 1) {
                        if ((try br.read(1)) != 0)
                            samples[i] = lt.ff_dca_rsd_level_2b[try br.read(1)]
                        else
                            samples[i] = 0;
                    }
                } else {
                    const nblocks: usize = @min(@as(usize, @intCast(br.bitsLeft())) / 8, (LBR_TIME_SAMPLES + 4) / 5);
                    for (0..nblocks) |blk| {
                        const code = lt.ff_dca_rsd_pack_5_in_8[try br.read(8)];
                        const base = blk * 5;
                        for (0..5) |j| {
                            samples[base + j] = lt.ff_dca_rsd_level_3[(code >> @intCast(j * 2)) & 3];
                        }
                    }
                    i = nblocks * 5;
                }
            },
            3 => {
                const nblocks: usize = @min(@as(usize, @intCast(br.bitsLeft())) / 7, (LBR_TIME_SAMPLES + 2) / 3);
                for (0..nblocks) |blk| {
                    const code = try br.read(7);
                    const base = blk * 3;
                    for (0..3) |j| {
                        samples[base + j] = lt.ff_dca_rsd_level_5[lt.ff_dca_rsd_pack_3_in_7[code][j]];
                    }
                }
                i = nblocks * 3;
            },
            4 => {
                while (i < LBR_TIME_SAMPLES and br.bitsLeft() >= 6) : (i += 1) {
                    samples[i] = lt.ff_dca_rsd_level_8[try self.parseVlc(&(self.vlc.?).rsd)];
                }
            },
            5 => {
                const nblocks: usize = @min(@as(usize, @intCast(br.bitsLeft())) / 4, LBR_TIME_SAMPLES);
                for (0..nblocks) |blk| {
                    samples[blk] = lt.ff_dca_rsd_level_16[try br.read(4)];
                }
                i = nblocks;
            },
            else => return error.Invalid,
        }

        if (flag and br.bitsLeft() < 20) return; // 不完整单声道子带

        while (i < LBR_TIME_SAMPLES) : (i += 1) {
            samples[i] = self.lbrRand(sb);
        }

        self.ch_pres[ch] |= @as(u32, 1) << @intCast(sb);
    }

    fn parseTs(self: *LbrDecoder, ch1: usize, ch2: usize, start_sb: usize, end_sb: usize, flag: bool) LbrError!void {
        var sb = start_sb;
        while (sb < end_sb) : (sb += 1) {
            // 重排前子带号
            var sb_reorder: usize = undefined;
            if (sb < 6) {
                sb_reorder = sb;
            } else if (flag and sb < self.max_mono_subband) {
                sb_reorder = self.sb_indices[sb];
            } else {
                if (try ensureBits(&self.curr_gb, 28)) break;
                sb_reorder = @intCast(try self.curr_gb.read(@intCast(self.limited_range + 3)));
                if (sb_reorder < 6) sb_reorder = 6;
                self.sb_indices[sb] = @intCast(sb_reorder);
            }
            if (sb_reorder >= self.nsubbands) return error.Invalid;

            // 第三网格尺度因子
            if (sb == 12) {
                var sb_g3: usize = 0;
                while (sb_g3 < self.g3_avg_only_start_sb - 4) : (sb_g3 += 1) {
                    self.parseGrid3(ch1, ch2, sb_g3, flag) catch {};
                }
            } else if (sb < 12 and sb_reorder >= 4) {
                self.parseGrid3(ch1, ch2, sb_reorder - 4, flag) catch {};
            }

            // 次声道标志
            if (ch1 != ch2) {
                if (try ensureBits(&self.curr_gb, 20)) break;
                if (!flag or sb_reorder >= self.max_mono_subband)
                    self.sec_ch_sbms[ch1 / 2][sb_reorder] = @intCast(try self.curr_gb.read(8));
                if (flag and sb_reorder >= self.min_mono_subband)
                    self.sec_ch_lrms[ch1 / 2][sb_reorder] = @intCast(try self.curr_gb.read(8));
            }

            const quant_level = self.quant_levels[ch1 / 2][sb];
            if (quant_level == 0) return error.Invalid;

            // 一或两个声道的时域样本
            if (sb < self.max_mono_subband and sb_reorder >= self.min_mono_subband) {
                if (!flag)
                    try self.parseCh(ch1, sb_reorder, quant_level, false)
                else if (ch1 != ch2)
                    try self.parseCh(ch2, sb_reorder, quant_level, true);
            } else {
                try self.parseCh(ch1, sb_reorder, quant_level, false);
                if (ch1 != ch2)
                    try self.parseCh(ch2, sb_reorder, quant_level, false);
            }
        }
    }

    /// convert_lpc：反射系数 → 直接形式系数（float 递推，lpc_tab 溯源 dcadata.c）
    fn convertLpc(coeff: []f32, codes: *const [8]u8) void {
        const lpc_tab = [16]f32{
            -0.995734176295034521871191178905, -0.961825643172819070408796290732,
            -0.895163291355062322067016499754, -0.798017227280239503332805112796,
            -0.673695643646557211712691912426, -0.526432162877355800244607799141,
            -0.361241666187152948744714596184, -0.183749517816570331574408839621,
            0.0,                               0.207911690817759337101742284405,
            0.406736643075800207753985990341,  0.587785252292473129168705954639,
            0.743144825477394235014697048974,  0.866025403784438646763723170753,
            0.951056516295153572116439333379,  0.994521895368273336922691944981,
        };
        for (0..8) |i| {
            const rc = lpc_tab[codes[i]];
            for (0..(i + 1) / 2) |j| {
                const tmp1 = coeff[j];
                const tmp2 = coeff[i - j - 1];
                coeff[j] = tmp1 + rc * tmp2;
                coeff[i - j - 1] = tmp2 + rc * tmp1;
            }
            coeff[i] = rc;
        }
    }

    fn parseLpc(self: *LbrDecoder, ch1: usize, ch2: usize, start_sb: usize, end_sb: usize) LbrError!void {
        const f: usize = self.framenum & 1;
        for (start_sb..end_sb) |sb| {
            const ncodes = 8 * (1 + @as(usize, if (sb < 2) 1 else 0));
            for (ch1..ch2 + 1) |ch| {
                if (try ensureBits(&self.curr_gb, @intCast(4 * ncodes))) return;
                var codes: [16]u8 = undefined;
                for (0..ncodes) |i| codes[i] = @intCast(try self.curr_gb.read(4));
                for (0..ncodes / 8) |i| {
                    convertLpc(self.lpc_coeff[f][ch][sb][i][0..], codes[i * 8 ..][0..8]);
                }
            }
        }
    }

    fn parseHighResGrid(self: *LbrDecoder, chunk: *const Chunk, ch1: usize, ch2: usize) LbrError!void {
        if (chunk.len == 0) return;
        self.curr_gb = BitReaderLE.init(chunk.data);

        // 量化档
        const profile: u32 = try self.curr_gb.read(8);
        const ol: u32 = (profile >> 3) & 7;
        const st: u32 = profile >> 6;
        const max_sb: usize = @intCast(profile & 7);

        // 量化级
        var quant_levels: [LBR_SUBBANDS]u8 = undefined;
        for (0..self.nsubbands) |sb| {
            const f: i32 = @intCast(sb * self.limited_rate / self.nsubbands);
            const a: i32 = @divTrunc(@as(i32, 18000), @divTrunc(12 * f, 1000) + 100 + 40 * @as(i32, @intCast(st))) + 20 * @as(i32, @intCast(ol));
            quant_levels[sb] = if (a <= 95) 1 else if (a <= 140) 2 else if (a <= 180) 3 else if (a <= 230) 4 else 5;
        }

        // 低子带量化级重排
        for (0..8) |sb| self.quant_levels[ch1 / 2][sb] = quant_levels[lt.ff_dca_sb_reorder[max_sb][sb]];
        for (8..self.nsubbands) |sb| self.quant_levels[ch1 / 2][sb] = quant_levels[sb];

        // 前两子带 LPC
        try self.parseLpc(ch1, ch2, 0, 2);

        // 主声道前两子带时域样本
        try self.parseTs(ch1, ch2, 0, 2, false);

        // 第一网格前两带
        for (0..2) |sb| {
            for (ch1..ch2 + 1) |ch| {
                try self.parseScaleFactors(&self.grid_1_scf[ch][sb]);
            }
        }
    }

    fn parseGrid2(self: *LbrDecoder, ch1: usize, ch2: usize, start_sb: usize, end_sb: usize, flag: bool) LbrError!void {
        const nscf = lt.ff_dca_scf_to_grid_2[self.nsubbands - 1] + 1;
        const end = @min(end_sb, nscf);

        for (start_sb..end) |sb| {
            for (ch1..ch2 + 1) |ch| {
                const g2_scf = &self.grid_2_scf[ch][sb];

                if ((ch != ch1 and lt.ff_dca_grid_2_to_scf[sb] >= self.min_mono_subband) != flag) {
                    if (!flag) g2_scf.* = self.grid_2_scf[ch1][sb];
                    continue;
                }

                // 8 个一组
                grp: for (0..8) |grp| {
                    const base = grp * 8;
                    if (self.curr_gb.bitsLeft() < 1) {
                        @memset(g2_scf[base..64], 0);
                        break :grp;
                    }
                    if ((try self.curr_gb.read(1)) != 0) {
                        for (0..8) |j| {
                            if (try ensureBits(&self.curr_gb, 20)) break :grp;
                            g2_scf[base + j] = @intCast(try self.parseVlc(&(self.vlc.?).grid_2));
                        }
                    } else {
                        @memset(g2_scf[base .. base + 8], 0);
                    }
                }
            }
        }
    }

    fn parseTs1Chunk(self: *LbrDecoder, chunk: *const Chunk, ch1: usize, ch2: usize) LbrError!void {
        if (chunk.len == 0) return;
        self.curr_gb = BitReaderLE.init(chunk.data);
        try self.parseLpc(ch1, ch2, 2, 3);
        try self.parseTs(ch1, ch2, 2, 4, false);
        try self.parseGrid2(ch1, ch2, 0, 1, false);
        try self.parseTs(ch1, ch2, 4, 6, false);
    }

    fn parseTs2Chunk(self: *LbrDecoder, chunk: *const Chunk, ch1: usize, ch2: usize) LbrError!void {
        if (chunk.len == 0) return;
        self.curr_gb = BitReaderLE.init(chunk.data);
        try self.parseGrid2(ch1, ch2, 1, 3, false);
        try self.parseTs(ch1, ch2, 6, self.max_mono_subband, false);
        if (ch1 != ch2) {
            try self.parseGrid1SecCh(ch2);
            try self.parseGrid2(ch1, ch2, 0, 3, true);
        }
        try self.parseTs(ch1, ch2, self.min_mono_subband, self.nsubbands, true);
    }

    // ==========================================================================
    // 合成
    // ==========================================================================
    fn decodeGrid(self: *LbrDecoder, ch1: usize, ch2: usize) void {
        for (ch1..ch2 + 1) |ch| {
            for (0..self.nsubbands) |sb| {
                const g1_sb = lt.ff_dca_scf_to_grid_1[sb];
                const g1_scf_a = &self.grid_1_scf[ch][g1_sb];
                const g1_scf_b = &self.grid_1_scf[ch][g1_sb + 1];
                const w1: i32 = lt.ff_dca_grid_1_weights[g1_sb][sb];
                const w2: i32 = lt.ff_dca_grid_1_weights[g1_sb + 1][sb];
                const hr_scf = &self.high_res_scf[ch][sb];

                if (sb < 4) {
                    for (0..8) |i| {
                        const scf = w1 * @as(i32, g1_scf_a[i]) + w2 * @as(i32, g1_scf_b[i]);
                        hr_scf[i] = @intCast(scf >> 7);
                    }
                } else {
                    const g3_scf = &self.grid_3_scf[ch][sb - 4];
                    const g3_avg: i32 = self.grid_3_avg[ch][sb - 4];
                    for (0..8) |i| {
                        const scf = w1 * @as(i32, g1_scf_a[i]) + w2 * @as(i32, g1_scf_b[i]);
                        hr_scf[i] = @intCast((scf >> 7) - g3_avg - g3_scf[i]);
                    }
                }
            }
        }
    }

    fn randomTs(self: *LbrDecoder, ch1: usize, ch2: usize) void {
        for (ch1..ch2 + 1) |ch| {
            for (0..self.nsubbands) |sb| {
                const samples = self.timeSamples(ch, sb)[LBR_TIME_HISTORY..];

                if (self.ch_pres[ch] & (@as(u32, 1) << @intCast(sb)) != 0) continue;

                if (sb < 2) {
                    @memset(samples[0..LBR_TIME_SAMPLES], 0);
                } else if (sb < 10) {
                    for (0..LBR_TIME_SAMPLES) |i| samples[i] = self.lbrRand(sb);
                } else {
                    var blk: usize = 0;
                    while (blk < LBR_TIME_SAMPLES / 8) : (blk += 1) {
                        var accum: [8]f32 = .{0} ** 8;
                        const base = blk * 8;
                        for (2..6) |k| {
                            const other = self.timeSamples(ch, k)[LBR_TIME_HISTORY + base ..][0..8];
                            for (0..8) |j| accum[j] += @abs(other[j]);
                        }
                        for (0..8) |j| {
                            samples[base + j] = (accum[j] * 0.25 + 0.5) * self.lbrRand(sb);
                        }
                    }
                }
            }
        }
    }

    fn predict(samples: []f32, coeff: *const [8]f32, nsamples: usize) void {
        for (0..nsamples) |i| {
            var res: f32 = 0;
            for (0..8) |j| res += coeff[j] * samples[i - j - 1];
            samples[i] -= res;
        }
    }

    fn synthLpc(self: *LbrDecoder, ch1: usize, ch2: usize, sb: usize) void {
        const f: usize = self.framenum & 1;
        for (ch1..ch2 + 1) |ch| {
            const samples = self.timeSamples(ch, sb)[LBR_TIME_HISTORY..];
            if (self.ch_pres[ch] & (@as(u32, 1) << @intCast(sb)) == 0) continue;

            if (sb < 2) {
                predict(samples, &self.lpc_coeff[f ^ 1][ch][sb][1], 16);
                predict(samples[16..], &self.lpc_coeff[f][ch][sb][0], 64);
                predict(samples[80..], &self.lpc_coeff[f][ch][sb][1], 48);
            } else {
                predict(samples, &self.lpc_coeff[f ^ 1][ch][sb][0], 16);
                predict(samples[16..], &self.lpc_coeff[f][ch][sb][0], 112);
            }
        }
    }

    fn filterTs(self: *LbrDecoder, ch1: usize, ch2: usize) void {
        for (0..self.nsubbands) |sb| {
            // 尺度因子
            for (ch1..ch2 + 1) |ch| {
                const samples = self.timeSamples(ch, sb)[LBR_TIME_HISTORY..];
                const hr_scf = &self.high_res_scf[ch][sb];
                if (sb < 4) {
                    for (0..LBR_TIME_SAMPLES / 16) |i| {
                        var scf: u32 = hr_scf[i];
                        if (scf > amp_max) scf = amp_max;
                        const base = i * 16;
                        for (0..16) |j| samples[base + j] *= lt.ff_dca_quant_amp[scf];
                    }
                } else {
                    const g2_scf = &self.grid_2_scf[ch][lt.ff_dca_scf_to_grid_2[sb]];
                    for (0..LBR_TIME_SAMPLES / 2) |i| {
                        var scf: u32 = @as(u32, hr_scf[i / 8]) -% @as(u32, g2_scf[i]);
                        if (scf > amp_max) scf = amp_max;
                        const qa = lt.ff_dca_quant_amp[scf];
                        samples[i * 2] *= qa;
                        samples[i * 2 + 1] *= qa;
                    }
                }
            }

            // 中/边立体声
            if (ch1 != ch2) {
                const samples_l = self.timeSamples(ch1, sb)[LBR_TIME_HISTORY..];
                const samples_r = self.timeSamples(ch2, sb)[LBR_TIME_HISTORY..];
                const ch2_pres = self.ch_pres[ch2] & (@as(u32, 1) << @intCast(sb));

                for (0..LBR_TIME_SAMPLES / 16) |i| {
                    const sbms = (self.sec_ch_sbms[ch1 / 2][sb] >> @intCast(i)) & 1;
                    const lrms = (self.sec_ch_lrms[ch1 / 2][sb] >> @intCast(i)) & 1;
                    const base = i * 16;
                    const l = samples_l[base .. base + 16];
                    const r = samples_r[base .. base + 16];

                    if (sb >= self.min_mono_subband) {
                        if (lrms != 0 and ch2_pres != 0) {
                            if (sbms != 0) {
                                for (0..16) |j| {
                                    const tmp = l[j];
                                    l[j] = r[j];
                                    r[j] = -tmp;
                                }
                            } else {
                                for (0..16) |j| {
                                    const tmp = l[j];
                                    l[j] = r[j];
                                    r[j] = tmp;
                                }
                            }
                        } else if (ch2_pres == 0) {
                            if (sbms != 0 and (self.part_stereo_pres & (@as(u32, 1) << @intCast(ch1))) != 0) {
                                for (0..16) |j| r[j] = -l[j];
                            } else {
                                for (0..16) |j| r[j] = l[j];
                            }
                        }
                    } else if (sbms != 0 and ch2_pres != 0) {
                        for (0..16) |j| {
                            const tmp = l[j];
                            l[j] = (tmp + r[j]) * 0.5;
                            r[j] = (tmp - r[j]) * 0.5;
                        }
                    }
                }
            }

            // 逆预测
            if (sb < 3) self.synthLpc(ch1, ch2, sb);
        }
    }

    fn decodePartStereo(self: *LbrDecoder, ch1: usize, ch2: usize) void {
        for (ch1..ch2 + 1) |ch| {
            for (self.min_mono_subband..self.nsubbands) |sb| {
                const pt_st = &self.part_stereo[ch][(sb - self.min_mono_subband) / 4];
                const samples = self.timeSamples(ch, sb)[LBR_TIME_HISTORY..];

                if (self.ch_pres[ch2] & (@as(u32, 1) << @intCast(sb)) != 0) continue;

                for (1..5) |sf| {
                    const prev = lt.ff_dca_st_coeff[pt_st[sf - 1]];
                    const next = lt.ff_dca_st_coeff[pt_st[sf]];
                    const base = (sf - 1) * 32;
                    for (0..32) |i| {
                        samples[base + i] *= @as(f32, @floatFromInt(32 - @as(i32, @intCast(i)))) * prev + @as(f32, @floatFromInt(i)) * next;
                    }
                }
            }
        }
    }

    /// synth_tones（dca_lbr.c）：值位置 x_freq-5 .. x_freq+5，
    /// 负位置项丢弃（对齐 C 的 goto 跳转结构）
    fn synthTones(self: *LbrDecoder, ch: usize, values: *[LBR_SUBBANDS * 4]f32, group: usize, group_sf: usize, synth_idx: i32) void {
        if (synth_idx < 0) return;

        const start = self.tonal_bounds[group][group_sf][0];
        const count = (self.tonal_bounds[group][group_sf][1] -% start) & (LBR_TONES - 1);

        for (0..count) |i| {
            const tp = &self.tones[(start + i) & (LBR_TONES - 1)];

            if (tp.amp[ch] != 0) {
                const amp: f32 = lt.ff_dca_synth_env[@intCast(synth_idx)] * lt.ff_dca_quant_amp[tp.amp[ch]];
                const c = amp * cos_tab[tp.phs[ch] & 255];
                const s = amp * cos_tab[(@as(usize, tp.phs[ch]) + 64) & 255];
                const cf = &lt.ff_dca_corr_cf[tp.f_delt];
                const x_freq: i32 = tp.x_freq;

                const idx = [11]i32{ x_freq - 5, x_freq - 4, x_freq - 3, x_freq - 2, x_freq - 1, x_freq, x_freq + 1, x_freq + 2, x_freq + 3, x_freq + 4, x_freq + 5 };
                // 符号模式：-s, c, s, -c, -s, c, s, -c, -s, c, s
                if (idx[0] >= 0) values[@intCast(idx[0])] += cf[0] * -s;
                if (idx[1] >= 0) values[@intCast(idx[1])] += cf[1] * c;
                if (idx[2] >= 0) values[@intCast(idx[2])] += cf[2] * s;
                if (idx[3] >= 0) values[@intCast(idx[3])] += cf[3] * -c;
                if (idx[4] >= 0) values[@intCast(idx[4])] += cf[4] * -s;
                if (idx[5] >= 0) values[@intCast(idx[5])] += cf[5] * c;
                if (idx[6] >= 0) values[@intCast(idx[6])] += cf[6] * s;
                if (idx[7] >= 0) values[@intCast(idx[7])] += cf[7] * -c;
                if (idx[8] >= 0) values[@intCast(idx[8])] += cf[8] * -s;
                if (idx[9] >= 0) values[@intCast(idx[9])] += cf[9] * c;
                if (idx[10] >= 0) values[@intCast(idx[10])] += cf[10] * s;
            }

            tp.phs[ch] +%= tp.ph_rot;
        }
    }

    fn baseFuncSynth(self: *LbrDecoder, ch: usize, values: *[LBR_SUBBANDS * 4]f32, sf: usize) void {
        for (0..5) |group| {
            const group_sf: i32 = (@as(i32, self.framenum) << @intCast(group)) + ((@as(i32, @intCast(sf)) - 22) >> @intCast(5 - group));
            const synth_idx: i32 = ((((@as(i32, @intCast(sf)) - 22) & 31) << @intCast(group)) & 31) + (@as(i32, 1) << @intCast(group)) - 1;

            self.synthTones(ch, values, group, @intCast((group_sf - 1) & 31), 30 - synth_idx);
            self.synthTones(ch, values, group, @intCast(group_sf & 31), synth_idx);
        }
    }

    /// 全带 IMDCT：av_tx FULL_IMDCT 数学等价实现（f64 累加）。
    /// 半变换：h[i] = scale·Σ_j in[j]·cos(π/(4N)(2j+1)(2N−2i−1))
    ///        h[N/2+i] = −scale·Σ_j in[j]·cos(π/(4N)(2j+1)(3N/2+2i+1))
    /// 全展开：out[N/2..3N/2)=h；out[i]=−out[N−1−i]；out[2N−1−i]=out[N+i]。
    fn imdctFull(self: *LbrDecoder, out: []f32, in: []const f32) void {
        const n = self.mdct_len;
        const half = n / 2;
        const tab = self.mdct_tab;
        const h = self.mdct_h;
        const scale: f64 = self.mdct_scale;

        for (0..half) |i| {
            var sum_d: f64 = 0;
            var sum_u: f64 = 0;
            for (0..n) |j| {
                sum_d += @as(f64, tab[j * n + i]) * in[j];
                sum_u += @as(f64, tab[j * n + half + i]) * in[j];
            }
            h[i] = @floatCast(sum_d * scale);
            h[half + i] = @floatCast(-sum_u * scale);
        }

        // dst[N/2 .. N/2+N) = h
        for (0..n) |k| out[half + k] = h[k];
        // dst[i] = -dst[N-1-i]
        for (0..half) |i| out[i] = -out[n - 1 - i];
        // dst[2N-1-i] = dst[N+i]
        for (0..half) |i| out[2 * n - 1 - i] = out[n + i];
    }

    /// lbr_bank（dcadsp.c lbr_bank_c）— 短窗 + 8 点 MDCT + 混叠抵消
    fn lbrBank(self: *LbrDecoder, output: *[LBR_SUBBANDS * 4]f32, ch: usize, ofs: usize, len: usize) void {
        const coeff = lt.ff_dca_bank_coeff;
        const sw0 = coeff[0];
        const sw1 = coeff[1];
        const sw2 = coeff[2];
        const sw3 = coeff[3];
        const c1 = coeff[4];
        const c2 = coeff[5];
        const c3 = coeff[6];
        const c4 = coeff[7];
        const al1 = coeff[8];
        const al2 = coeff[9];

        for (0..len) |i| {
            const idx = self.rowBase(ch, i) + ofs;
            const src = self.ts_buffer;

            const a = src[idx - 4] * sw0 - src[idx - 1] * sw3;
            const b = src[idx - 3] * sw1 - src[idx - 2] * sw2;
            const c = src[idx + 2] * sw1 + src[idx + 1] * sw2;
            const d = src[idx + 3] * sw0 + src[idx + 0] * sw3;

            output[i * 4 + 0] = c1 * b - c2 * c + c4 * a - c3 * d;
            output[i * 4 + 1] = c1 * d - c2 * a - c4 * b - c3 * c;
            output[i * 4 + 2] = c3 * b + c2 * d - c4 * c + c1 * a;
            output[i * 4 + 3] = c3 * a - c2 * b + c4 * d - c1 * c;
        }

        // 高频混叠抵消（对齐 C：i 自 12 起、i < len-1；len ≤ 13 时无迭代）
        if (len > 13) {
            for (12..len - 1) |i| {
                var a = output[i * 4 + 3] * al1;
                var b = output[(i + 1) * 4 + 0] * al1;
                output[i * 4 + 3] += b - a;
                output[(i + 1) * 4 + 0] -= b + a;
                a = output[i * 4 + 2] * al2;
                b = output[(i + 1) * 4 + 1] * al2;
                output[i * 4 + 2] += b - a;
                output[(i + 1) * 4 + 1] -= b + a;
            }
        }
    }

    inline fn rowBase(self: *const LbrDecoder, ch: usize, sb: usize) usize {
        const nchsamples = LBR_TIME_SAMPLES + LBR_TIME_HISTORY * 2;
        return (ch * self.nsubbands + sb) * nchsamples + LBR_TIME_HISTORY;
    }

    fn transformChannel(self: *LbrDecoder, ch: usize, output: []f32) void {
        var values: [LBR_SUBBANDS * 4]f32 = undefined;
        var result: [LBR_SUBBANDS * 2 * 4]f32 = undefined;
        const nsubbands = self.nsubbands;
        const noutsubbands = @as(usize, 8) << @intCast(self.freq_range);
        const n = noutsubbands * 4;

        // 清空非活动子带
        if (nsubbands < noutsubbands) {
            @memset(values[nsubbands * 4 .. noutsubbands * 4], 0);
        }

        var op: usize = 0;
        for (0..LBR_TIME_SAMPLES / 4) |sf| {
            // 混合滤波器组
            self.lbrBank(&values, ch, sf * 4, nsubbands);

            self.baseFuncSynth(ch, &values, sf);

            self.imdctFull(&result, values[0..n]);

            // 长窗 + 重叠相加
            for (0..n) |i| {
                output[op + i] = result[i] * self.window[i] + self.history[ch][i];
            }
            for (0..n) |i| {
                self.history[ch][i] = result[2 * n - 1 - i] * self.window[i];
            }
            op += n;
        }

        // 更新 LPC / 前向 MDCT 历史：行尾 8 样本 → 行首历史
        for (0..nsubbands) |sb| {
            const row = self.timeSamples(ch, sb);
            std.mem.copyForwards(f32, row[0..LBR_TIME_HISTORY], row[LBR_TIME_HISTORY + LBR_TIME_SAMPLES ..][0..LBR_TIME_HISTORY]);
        }
    }

    // ==========================================================================
    // ff_dca_lbr_filter_frame：输出 FLTP 平面（AV_CH 规范序）
    // ==========================================================================
    const channel_reorder_nolfe = [7][5]i8{
        .{ 0, -1, -1, -1, -1 }, // C
        .{ 0,  1, -1, -1, -1 }, // LR
        .{ 0,  1,  2, -1, -1 }, // LR C
        .{ 0,  1, -1, -1, -1 }, // LsRs
        .{ 1,  2,  0, -1, -1 }, // LsRs C
        .{ 0,  1,  2,  3, -1 }, // LR LsRs
        .{ 0,  1,  3,  4,  2 }, // LR LsRs C
    };
    const channel_reorder_lfe = [7][5]i8{
        .{ 0, -1, -1, -1, -1 },
        .{ 0,  1, -1, -1, -1 },
        .{ 0,  1,  2, -1, -1 },
        .{ 1,  2, -1, -1, -1 },
        .{ 2,  3,  0, -1, -1 },
        .{ 0,  1,  3,  4, -1 },
        .{ 0,  1,  4,  5,  2 },
    };
    const lfe_index = [7]u8{ 1, 2, 3, 0, 1, 2, 3 };
    /// channel_layouts[7]（dca_lbr.c）：AV_CH 掩码
    const channel_layouts = [7]u32{
        0x0004, // MONO（FC）
        0x0003, // STEREO（FL|FR）
        0x0007, // SURROUND（FL|FR|FC）
        0x0600, // SL|SR
        0x0604, // FC|SL|SR
        0x0603, // 2_2（FL|FR|SL|SR）
        0x0607, // 5POINT0（FL|FR|FC|SL|SR）
    };

    /// 解码一帧并生成输出平面。
    pub fn filterFrame(self: *LbrDecoder) LbrError!void {
        try self.initVlcs();
        if (self.sample_rate == 0 or self.nchannels == 0) return error.Invalid;

        const ch_conf: usize = @intCast((self.ch_mask & 0x7) - 1);
        var channel_mask = channel_layouts[ch_conf];
        const reorder: *const [5]i8 = if (self.flags & flag_lfe_present != 0)
            &channel_reorder_lfe[ch_conf]
        else
            &channel_reorder_nolfe[ch_conf];

        if (self.flags & flag_lfe_present != 0) channel_mask |= 0x8; // AV_CH_LOW_FREQUENCY

        const nchannels_out: usize = popcount32(channel_mask);
        const nsamples: usize = @as(usize, 1024) << @intCast(self.freq_range);

        // 输出缓冲
        const need = nchannels_out * nsamples;
        if (self.out_buf.len < need) {
            if (self.out_buf.len != 0) self.alloc.free(self.out_buf);
            self.out_buf = try self.alloc.alloc(f32, need);
        }
        for (0..nchannels_out) |i| {
            self.out_planes[i] = self.out_buf[i * nsamples ..][0..nsamples];
        }
        self.out_nch = @intCast(nchannels_out);

        // 全带声道
        for (0..(self.nchannels + 1) / 2) |i| {
            const ch1 = i * 2;
            const ch2 = @min(ch1 + 1, self.nchannels - 1);

            self.decodeGrid(ch1, ch2);
            self.randomTs(ch1, ch2);
            self.filterTs(ch1, ch2);

            if (ch1 != ch2 and (self.part_stereo_pres & (@as(u32, 1) << @intCast(ch1))) != 0)
                self.decodePartStereo(ch1, ch2);

            if (ch1 < nchannels_out and ch1 < reorder.len)
                self.transformChannel(ch1, self.out_planes[@intCast(reorder[ch1])]);

            if (ch1 != ch2 and ch2 < nchannels_out and ch2 < reorder.len)
                self.transformChannel(ch2, self.out_planes[@intCast(reorder[ch2])]);
        }

        // LFE 插值
        if (self.flags & flag_lfe_present != 0) {
            self.lfeIir(self.out_planes[lfe_index[ch_conf]], &self.lfe_data, @as(usize, 16) << @intCast(self.freq_range));
        }
    }

    /// lfe_iir（dcadsp.c lfe_iir_c）：5 级双二阶级联插值
    fn lfeIir(self: *LbrDecoder, output: []f32, input: []const f32, factor: usize) void {
        const iir = lt.ff_dca_lfe_iir;
        var op: usize = 0;
        for (0..64) |i| {
            var res: f32 = input[i];
            for (0..factor) |_| {
                for (0..5) |k| {
                    const h0 = self.lfe_history[k][0];
                    const h1 = self.lfe_history[k][1];
                    const tmp = h0 * iir[k][0] + h1 * iir[k][1] + res;
                    res = h0 * iir[k][2] + h1 * iir[k][3] + tmp;
                    self.lfe_history[k][0] = h1;
                    self.lfe_history[k][1] = tmp;
                }
                output[op] = res;
                op += 1;
                res = 0;
            }
        }
    }

    // -- 输出访问 --
    pub fn outputNchannels(self: *const LbrDecoder) u8 {
        return self.out_nch;
    }
    pub fn outputNsamples(self: *const LbrDecoder) usize {
        if (self.out_nch == 0) return 0;
        return self.out_planes[0].len;
    }
    pub fn outputSampleRate(self: *const LbrDecoder) u32 {
        return self.sample_rate;
    }
    pub fn plane(self: *const LbrDecoder, ch: usize) ?[]const f32 {
        if (ch >= self.out_nch) return null;
        return self.out_planes[ch];
    }
};

/// 测试专用：以给定 freq_range 初始化 IMDCT 表（绕过 parse_decoder_init）
fn initSampleRateForTest(self: *LbrDecoder, freq_range: u8) LbrError!void {
    self.freq_range = freq_range;
    self.limited_range = freq_range;
    self.nsubbands = @as(usize, 8) << @intCast(freq_range);
    self.bit_rate_scaled = 96000 * 6;
    self.nchannels_total = 6;
    try self.initSampleRate();
}

fn popcount32(m: u32) usize {
    var v = m;
    var c: usize = 0;
    while (v != 0) : (v >>= 1) c += @intCast(v & 1);
    return c;
}

fn ceilLog2(v: usize) u6 {
    var n: u6 = 0;
    var p: usize = 1;
    while (p < v) : (p <<= 1) n += 1;
    return n;
}

// ---------------------------------------------------------------------------
// 测试：VLC 往返、参考向量（lbr_bank / lfe_iir / IMDCT vs FFmpeg）
// ---------------------------------------------------------------------------
const testing = std.testing;

// (符号, 码长) → 码字（增量算法），再经 VLC 解码往返验证
test "lbr vlc: 码书构建 + 解码往返（含逃逸）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 用真实表构建
    var set = try VlcSet.init(a);
    const S = lt.vlc_src_lbr;
    const cases = [_]struct { v: *const Vlc, syms: []const i16, lens: []const u8 }{
        .{ .v = &set.tnl_grp[0], .syms = &S.sym_tnl_grp_0, .lens = &S.len_tnl_grp_0 },
        .{ .v = &set.tnl_scf, .syms = &S.sym_tnl_scf, .lens = &S.len_tnl_scf },
        .{ .v = &set.damp, .syms = &S.sym_damp, .lens = &S.len_damp },
        .{ .v = &set.dph, .syms = &S.sym_dph, .lens = &S.len_dph },
        .{ .v = &set.fst_rsd_amp, .syms = &S.sym_fst_rsd_amp, .lens = &S.len_fst_rsd_amp },
        .{ .v = &set.rsd_apprx, .syms = &S.sym_rsd_apprx, .lens = &S.len_rsd_apprx },
        .{ .v = &set.rsd_amp, .syms = &S.sym_rsd_amp, .lens = &S.len_rsd_amp },
        .{ .v = &set.avg_g3, .syms = &S.sym_avg_g3, .lens = &S.len_avg_g3 },
        .{ .v = &set.st_grid, .syms = &S.sym_st_grid, .lens = &S.len_st_grid },
        .{ .v = &set.grid_2, .syms = &S.sym_grid_2, .lens = &S.len_grid_2 },
        .{ .v = &set.grid_3, .syms = &S.sym_grid_3, .lens = &S.len_grid_3 },
        .{ .v = &set.rsd, .syms = &S.sym_rsd, .lens = &S.len_rsd },
    };

    for (cases) |case| {
        const offset: i32 = if (case.v == &set.rsd) 0 else -1;
        // 增量码字重算 → 按码字（LE 位序）写位流 → 解码应得到同符号
        // （存储符号 -1 的表项 = 逃逸，另行单独验证）
        var code: u32 = 0;
        for (case.syms, case.lens) |sym, len| {
            defer code +%= @as(u32, 1) << @as(u5, @intCast(32 - @as(usize, len)));
            if (sym + offset == -1) continue;
            // 编码：码字最高位为首读位 → LE 位流中先写最高位对应的位流位
            var buf: [16]u8 = undefined;
            @memset(&buf, 0);
            var bw = BitWriterLE{ .data = &buf };
            var bit: usize = 0;
            while (bit < len) : (bit += 1) {
                const b: u1 = @intCast((code >> @intCast(31 - bit)) & 1);
                bw.write(b);
            }
            // entry_offset 修正
            var br = BitReaderLE.init(bw.bytes());
            var dec = Vlc{ .tree = case.v.tree, .alloc = a };
            const got = try dec.decode(&br);
            try testing.expectEqual(@as(i32, sym + offset), got);
        }
    }
}

/// LE 位写入器（测试用）
const BitWriterLE = struct {
    data: []u8,
    pos: usize = 0,

    fn write(self: *BitWriterLE, b: u1) void {
        if (b != 0)
            self.data[self.pos >> 3] |= @as(u8, 1) << @intCast(self.pos & 7);
        self.pos += 1;
    }

    fn bytes(self: *const BitWriterLE) []const u8 {
        return self.data[0 .. (self.pos + 7) / 8];
    }
};

test "lbr vlc: 逃逸路径（存储符号 -1 → 3+bits）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const set = try VlcSet.init(a);

    // damp 表中符号 0（offset -1 → 存储符号 -1）对应码长 6 → 逃逸
    const S = lt.vlc_src_lbr;
    var code: u32 = 0;
    var found: ?u32 = null;
    for (S.sym_damp, S.len_damp, 0..) |sym, len, i| {
        if (sym + -1 == -1) found = code;
        _ = i;
        code +%= @as(u32, 1) << @as(u5, @intCast(32 - @as(usize, len)));
    }
    try testing.expect(found != null);

    // 编码：码字 + 逃逸位（3 位 n-1，n 位值）
    var buf: [16]u8 = undefined;
    @memset(&buf, 0);
    var bw = BitWriterLE{ .data = &buf };
    const esc_code = found.?;
    const esc_len: u6 = 6;
    var bit: usize = 0;
    while (bit < esc_len) : (bit += 1) {
        bw.write(@intCast((esc_code >> @intCast(31 - bit)) & 1));
    }
    const want_val: u32 = 0x2A; // 6 位可容纳
    // 逃逸：get_bits(3)+1 = 位长 n → 值 < 256；写 n-1（3 位）再写 n 位值
    bw.write(1); bw.write(0); bw.write(1); // 3 位 = 0b001 → n = 2? 从低到高：001 → 值 4 → n=5
    // 注意 LE：read(3) 首位在最低位 → 写入 1,0,1 得值 0b101=5 → n=6
    var k: u6 = 0;
    while (k < 6) : (k += 1) bw.write(@intCast((want_val >> @intCast(k)) & 1));

    var br = BitReaderLE.init(bw.bytes());
    var dec = Vlc{ .tree = set.damp.tree, .alloc = a };
    const got = try dec.decode(&br);
    try testing.expectEqual(@as(i32, @intCast(want_val)), got);
}

// FFmpeg 参考向量（由 reference/FFmpeg 以 lbr_ref.c 采集）
const ref_vectors = @embedFile("lbr_ref_vectors.bin");

fn readRefVec(pos: *usize) struct { name: []const u8, n: usize, data: []const u8 } {
    var p = pos.*;
    const name_len = ref_vectors[p];
    p += 1;
    const name = ref_vectors[p .. p + name_len];
    p += name_len;
    const n = std.mem.readInt(u32, ref_vectors[p..][0..4], .little);
    p += 4;
    const data = ref_vectors[p .. p + n * 4];
    p += n * 4;
    pos.* = p;
    return .{ .name = name, .n = n, .data = data };
}

test "lbr dsp: lbr_bank / lfe_iir 与 FFmpeg C 实现逐位一致" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dec = LbrDecoder.init(a);

    // 复现 lbr_ref.c 的输入（ref：ts[i][0..136)，lbr_bank(in=ts[i], ofs=8) →
    // 访问 ts[i][4..136)。本实现行 = [0..8)历史 + [8..144)数据，数据起点 +ofs。
    // 对齐：row[8+j] = ref ts[i][j]（j∈[0,136)）→ idx-4 起点一致）
    var seed: u32 = 1;
    const nchsamples = LBR_TIME_SAMPLES + LBR_TIME_HISTORY * 2;
    dec.ts_buffer = try a.alloc(f32, LBR_SUBBANDS * nchsamples);
    for (0..LBR_SUBBANDS) |i| {
        for (0..136) |j| {
            seed = seed *% 1103515245 +% 12345;
            const v = @as(f32, @floatFromInt(@as(i32, @intCast(seed >> 16)))) / 4096.0 - 32768.0;
            dec.ts_buffer[i * nchsamples + 8 + j] = v;
        }
    }
    // lbrBank(ofs=8, len=32)
    var out: [LBR_SUBBANDS * 4]f32 = undefined;
    dec.nsubbands = LBR_SUBBANDS;
    dec.lbrBank(&out, 0, 8, LBR_SUBBANDS);

    var pos: usize = 0;
    const bank = readRefVec(&pos);
    try testing.expectEqualStrings("lbr_bank", bank.name);
    const bank_ref = std.mem.sliceAsBytes(std.mem.bytesAsSlice(f32, bank.data));
    try testing.expectEqualSlices(u8, bank_ref, std.mem.sliceAsBytes(out[0 .. LBR_SUBBANDS * 4]));

    // lfe_iir
    var lfe_in: [64]f32 = undefined;
    for (0..64) |i| {
        seed = seed *% 1103515245 +% 12345;
        lfe_in[i] = @as(f32, @floatFromInt(@as(i32, @intCast(seed >> 16)))) / 65536.0 - 1.0;
    }
    @memset(std.mem.asBytes(&dec.lfe_history), 0);
    var lfe_out: [1024]f32 = undefined;
    dec.lfeIir(&lfe_out, &lfe_in, 16);

    const iir = readRefVec(&pos);
    try testing.expectEqualStrings("lfe_iir", iir.name);
    const iir_ref = std.mem.sliceAsBytes(std.mem.bytesAsSlice(f32, iir.data));
    try testing.expectEqualSlices(u8, iir_ref, std.mem.sliceAsBytes(lfe_out[0..]));

    const hist = readRefVec(&pos);
    try testing.expectEqualStrings("lfe_hist", hist.name);
    const hist_ref = std.mem.sliceAsBytes(std.mem.bytesAsSlice(f32, hist.data));
    try testing.expectEqualSlices(u8, hist_ref, std.mem.sliceAsBytes(std.mem.asBytes(&dec.lfe_history)));
}

test "lbr dsp: 全带 IMDCT 与 av_tx FULL_IMDCT 参考一致（f64 累加容差内）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dec = LbrDecoder.init(a);

    var pos: usize = 0;
    var seed: u32 = 1;
    // 与 lbr_ref.c 相同输入流（顺次消费种子）：bank 32×136 + lfe 64 之后才是 IMDCT
    for (0..LBR_SUBBANDS * 136 + 64) |_| seed = seed *% 1103515245 +% 12345;
    // limited_range ≤ 2（上游在 limited_range=3 时为 UB，见 parse_decoder_init 注）
    for (0..3) |fr| {
        const n: usize = @as(usize, 32) << @intCast(fr);
        // 跳过前序向量直到对应 imdctN
        while (true) {
            const vec = readRefVec(&pos);
            const want_name = switch (fr) {
                0 => "imdct32",
                1 => "imdct64",
                2 => "imdct128",
                else => "imdct256",
            };
            if (std.mem.eql(u8, vec.name, want_name)) {
                // 重建输入
                const in = try a.alloc(f32, n);
                for (0..n) |idx| {
                    seed = seed *% 1103515245 +% 12345;
                    in[idx] = @as(f32, @floatFromInt(@as(i32, @intCast(seed >> 16)))) / 1024.0 - 32768.0;
                }
                // 初始化 mdct 表（fr 视作 freq_range；limited_range=fr）
                dec.band_limit = 0;
                dec.limited_range = @intCast(fr);
                try initSampleRateForTest(&dec, @intCast(fr));
                const out = try a.alloc(f32, 2 * n);
                @memset(out, 0xAA);
                dec.imdctFull(out, in);
                const ref = std.mem.bytesAsSlice(f32, vec.data);
                var max_diff: f32 = 0;
                var first_bad: usize = 0;
                for (0..2 * n) |k| {
                    const d = @abs(out[k] - ref[k]);
                    const scl = @max(@abs(ref[k]), 1.0);
                    if (d / scl > max_diff) {
                        max_diff = d / scl;
                        first_bad = k;
                    }
                }
                std.debug.print("imdct{d}: max_rel_diff={e} first_bad={d}\n", .{ n, max_diff, first_bad });
                try testing.expect(max_diff < 1e-5);
                break;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// 多声道 / 采样率验证（合成 decoder-init 帧 + FFmpeg C 参考锚定）
//
// 公开渠道无真实 LBR（DTS Express）多声道样本（fate-suite /dcadec-suite 均无
// LBR asset；samples.ffmpeg.org 亦无），故以合成 LBR 帧头驱动 parseDecoderInit +
// filterFrame，逐字段与 FFmpeg n9.0.1 语义对拍：
//   - 采样率表须用 ff_dca_sampling_freqs（dca.c），而非 core 的 sample_rate_tab；
//   - 声道掩码为 DCA_SPEAKER_PAIR 布局（bit0=C bit1=LR bit2=LsRs bit3=LFE1），
//     全带声道数由 ff_dca_count_chs_for_mask 给出，输出布局取低 3 位定出的
//     7 档（mono…5.0）+ 可选 LFE → ≤5.1；
//   - 期望的 sample_rate / 输出声道数 / 每帧样本数均用 in-repo reference
//     FFmpeg（no-asm 构建）实际解码锚定（ffprobe / f32 字节数）。
// 该矩阵同时回归以下已修正的路径差异：
//   - parse_decoder_init 采样率表错用 core 表（真实 48k LBR 会被误判 24k 且
//     LFE 被清除）；
//   - init_sample_rate 长窗抽取位移错用 limited_range（应为 freq_range），
//     带限 1/2 + 48k 会越界崩溃；
//   - filter_frame 对 >5 全带声道的掩码（如 0x17 带 Cs）曾越界 reorder 表
//     （FFmpeg C 此路同为 UB，此处以丢弃越界声道 + 结构一致替代）。
// ---------------------------------------------------------------------------

const TestInitCase = struct {
    sr_code: u8 = 0,
    mask: u16 = 0,
    flags: u8 = 0,
    bit_rate: u32 = 0,
    // parseDecoderInit 期望结果（错误 case 用 expect_parse_error）
    sr: u32 = 0,
    band_limit: u8 = 0,
    freq_range: u8 = 0,
    limited_range: i32 = 0,
    nsubbands: usize = 0,
    nch_total: usize = 0,
    nch: usize = 0,
    out_nch: u8 = 0,
    out_samples: usize = 0,
};

/// 构造一个「decoder_init + 空 frame chunk」的 LBR 帧（18 字节 + body）
fn buildLbrInitFrame(a: std.mem.Allocator, c: TestInitCase, body: []const u8) ![]u8 {
    const buf = try a.alloc(u8, 18 + body.len);
    @memset(buf, 0);
    var p: usize = 0;
    buf[p] = 0x0A;
    buf[p + 1] = 0x80;
    buf[p + 2] = 0x19;
    buf[p + 3] = 0x21; // sync（0x0A801921，BE）
    p += 4;
    buf[p] = header_decoder_init; // 2
    p += 1;
    buf[p] = c.sr_code;
    p += 1;
    std.mem.writeInt(u16, buf[p..][0..2], c.mask, .little);
    p += 2;
    std.mem.writeInt(u16, buf[p..][0..2], 0x0800, .little); // version
    p += 2;
    buf[p] = c.flags;
    p += 1;
    // bit_rate_hi：低 nibble = orig 的 bits 16..19；高 nibble = scaled 的 bits 16..19
    const hi: u8 = @intCast((c.bit_rate >> 16) & 0xF);
    buf[p] = hi | (hi << 4);
    p += 1;
    std.mem.writeInt(u16, buf[p..][0..2], @truncate(c.bit_rate), .little);
    p += 2;
    std.mem.writeInt(u16, buf[p..][0..2], @truncate(c.bit_rate), .little);
    p += 2;
    // frame chunk（NO_CSUM），body 空
    buf[p] = chunk_frame_no_csum;
    p += 1;
    buf[p] = @intCast(body.len & 0xFF);
    p += 1;
    @memcpy(buf[p .. p + body.len], body);
    return buf;
}

fn runLbrInitCase(c: TestInitCase) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const frame = try buildLbrInitFrame(a, c, &.{});
    var dec = LbrDecoder.init(a);
    defer dec.deinit();
    try dec.parse(frame);
    try dec.filterFrame();

    try testing.expectEqual(c.sr, dec.sample_rate);
    try testing.expectEqual(c.band_limit, dec.band_limit);
    try testing.expectEqual(c.freq_range, dec.freq_range);
    try testing.expectEqual(c.limited_range, dec.limited_range);
    try testing.expectEqual(c.nsubbands, dec.nsubbands);
    try testing.expectEqual(c.nch_total, dec.nchannels_total);
    try testing.expectEqual(c.nch, dec.nchannels);
    try testing.expectEqual(c.out_nch, dec.outputNchannels());
    try testing.expectEqual(c.out_samples, dec.outputNsamples());
}

// FFmpeg C 参考锚定矩阵（期望值由 in-repo no-asm reference FFmpeg 解码得出：
// ffprobe sample_rate/channels + f32 输出字节数 / 声道数）
test "lbr: 多声道 decoder_init 参数 vs FFmpeg C（mono→5.1、带限、LFE、掩码）" {
    const cases = [_]TestInitCase{
        // 8k mono（freq_range 0）
        .{ .sr_code = 0, .mask = 0x0001, .flags = 0x14, .bit_rate = 32000, .sr = 8000, .freq_range = 0, .limited_range = 0, .nsubbands = 8, .nch_total = 1, .nch = 1, .out_nch = 1, .out_samples = 1024 },
        // 32k stereo
        .{ .sr_code = 2, .mask = 0x0002, .flags = 0x14, .bit_rate = 64000, .sr = 32000, .freq_range = 2, .limited_range = 2, .nsubbands = 32, .nch_total = 2, .nch = 2, .out_nch = 2, .out_samples = 4096 },
        // 44.1k stereo
        .{ .sr_code = 6, .mask = 0x0002, .flags = 0x14, .bit_rate = 64000, .sr = 44100, .freq_range = 2, .limited_range = 2, .nsubbands = 32, .nch_total = 2, .nch = 2, .out_nch = 2, .out_samples = 4096 },
        // 48k LCR（mask 0x3）→ SURROUND 3 声道
        .{ .sr_code = 12, .mask = 0x0003, .flags = 0x14, .bit_rate = 96000, .sr = 48000, .freq_range = 2, .limited_range = 2, .nsubbands = 32, .nch_total = 3, .nch = 3, .out_nch = 3, .out_samples = 4096 },
        // 48k LR+LsRs + LFE（mask 0x6，2_2+LFE）→ 5 声道
        .{ .sr_code = 12, .mask = 0x0006, .flags = 0x16, .bit_rate = 128000, .sr = 48000, .freq_range = 2, .limited_range = 2, .nsubbands = 32, .nch_total = 4, .nch = 4, .out_nch = 5, .out_samples = 4096 },
        // 48k 5.1（mask 0x7 + LFE）→ 6 声道
        .{ .sr_code = 12, .mask = 0x0007, .flags = 0x16, .bit_rate = 192000, .sr = 48000, .freq_range = 2, .limited_range = 2, .nsubbands = 32, .nch_total = 5, .nch = 5, .out_nch = 6, .out_samples = 4096 },
        // 48k 5.0（无 LFE）→ 5 声道
        .{ .sr_code = 12, .mask = 0x0007, .flags = 0x14, .bit_rate = 192000, .sr = 48000, .freq_range = 2, .limited_range = 2, .nsubbands = 32, .nch_total = 5, .nch = 5, .out_nch = 5, .out_samples = 4096 },
        // 24k 5.1 掩码：LFE 仅在 48000 保留 → 被清除（flags 0x16 的 LFE 位无效）
        .{ .sr_code = 11, .mask = 0x0007, .flags = 0x16, .bit_rate = 192000, .sr = 24000, .freq_range = 1, .limited_range = 1, .nsubbands = 16, .nch_total = 5, .nch = 5, .out_nch = 5, .out_samples = 2048 },
        // 48k 5.1 带限 1/2（flags 0x0A = LFE + BAND_LIMIT_1_2）→ 帧长仍 4096
        .{ .sr_code = 12, .mask = 0x0007, .flags = 0x0A, .bit_rate = 192000, .sr = 48000, .band_limit = 1, .freq_range = 2, .limited_range = 1, .nsubbands = 16, .nch_total = 5, .nch = 5, .out_nch = 6, .out_samples = 4096 },
        // 立体声内嵌下混（dmix 0x20）5.1 源 → 输出 2 声道
        .{ .sr_code = 12, .mask = 0x0007, .flags = 0x36, .bit_rate = 192000, .sr = 48000, .freq_range = 2, .limited_range = 2, .nsubbands = 32, .nch_total = 7, .nch = 2, .out_nch = 2, .out_samples = 4096 },
    };
    for (cases) |c| try runLbrInitCase(c);
}

test "lbr: 超布局声道掩码（带 Cs/LwRw）仅做结构校验、不崩溃" {
    // FFmpeg C 对 ch_mask & 0xfff0（额外声道对）仅警告并继续，但 >5 全带声道
    // 在 filter_frame 会越界读 reorder 表（UB）；此处验证 mine 丢弃越界声道、
    // 输出仍为低 3 位定出的布局（5.1）且与 FFmpeg 结构一致（6ch × 4096）。
    const cases = [_]TestInitCase{
        .{ .sr_code = 12, .mask = 0x0017, .flags = 0x16, .bit_rate = 192000, .sr = 48000, .freq_range = 2, .limited_range = 2, .nsubbands = 32, .nch_total = 6, .nch = 6, .out_nch = 6, .out_samples = 4096 },
        .{ .sr_code = 12, .mask = 0x0407, .flags = 0x16, .bit_rate = 192000, .sr = 48000, .freq_range = 2, .limited_range = 2, .nsubbands = 32, .nch_total = 7, .nch = 6, .out_nch = 6, .out_samples = 4096 },
    };
    for (cases) |c| try runLbrInitCase(c);
}

test "lbr: 全部 ≤48k 采样率码经 ff_dca_sampling_freqs 正确映射" {
    // 回归：曾误用 core 的 ff_dca_sample_rate_tab（tables.zig sample_rates），
    // 使 sr_code 1(=16k)/12(=48k) 等被误判；此处逐码核对 dca.c 采样率表。
    const sr_codes = [_]u8{ 0, 1, 2, 5, 6, 10, 11, 12 };
    for (sr_codes) |code| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const frame = try buildLbrInitFrame(a, .{
            .sr_code = code,
            .mask = 0x0001,
            .flags = 0x14,
            .bit_rate = 96000,
        }, &.{});
        var dec = LbrDecoder.init(a);
        defer dec.deinit();
        try dec.parse(frame);
        try testing.expectEqual(dt.ff_dca_sampling_freqs[code], dec.sample_rate);
        try testing.expectEqual(lt.ff_dca_freq_ranges[code], dec.freq_range);
        try dec.filterFrame();
        try testing.expectEqual(@as(u8, 1), dec.outputNchannels());
    }
}

test "lbr: 非法掩码/非法 dmix 被拒绝（与 FFmpeg 一致）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 仅 LFE 位（低 3 位为空）→ 无有效前置布局
    {
        const frame = try buildLbrInitFrame(a, .{ .sr_code = 12, .mask = 0x0008, .flags = 0x16, .bit_rate = 192000 }, &.{});
        var dec = LbrDecoder.init(a);
        defer dec.deinit();
        try testing.expectError(error.Unsupported, dec.parse(frame));
    }
    // mono（nchannels_total=1）带 dmix_stereo → FFmpeg “Invalid number of channels
    // for LBR stereo downmix”（dca_lbr.c 同条件 AVERROR_INVALIDDATA）
    {
        const frame = try buildLbrInitFrame(a, .{ .sr_code = 12, .mask = 0x0001, .flags = 0x34, .bit_rate = 192000 }, &.{});
        var dec = LbrDecoder.init(a);
        defer dec.deinit();
        try testing.expectError(error.Invalid, dec.parse(frame));
    }
}
