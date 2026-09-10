// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! AAC SBR（频谱带复制）解码器（bit-exact 移植 FFmpeg n9.0.1 浮点路径）。
//!
//! 复刻对象：libavcodec/{aacsbr_template.c,aacsbr.c,sbrdsp_template.c,sbrdsp.c}
//! （非 USAC 路径）+ libavcodec/aacsbrdata.h 表。数值路径逐一对齐：
//!   - QMF 分析/合成：64 点逆向 MDCT（av_tx inv=1 半长）+ 多相窗口折叠；
//!   - HF 重建：逆滤波 / chirp / 包络-噪声-正弦增益 / 平滑；
//!   - 去量化：exp2fi（IEEE 指数位构造 2^x）。
//!
//! 数据流：时域 L/R → QMF 分析(W) → X_low → HF 生成(X_high) → 增益/噪声/正弦
//! → Y → X → QMF 合成 → 时域输出（可 2× 下采样，HE-AAC 输出原采样率）。

const std = @import("std");
const Error = @import("../../error.zig").Error;
const BitReader = @import("bitreader.zig").BitReader;
const mdct_mod = @import("mdct.zig");
const st = @import("sbr_tables.zig");
const psmod = @import("ps.zig");
const huff = @import("sbr_huff.zig");

/// ENVELOPE_ADJUSTMENT_OFFSET（HF 生成滤波 2 抽头延迟）
const ENV_OFF = 2;
/// NOISE_FLOOR_OFFSET（噪声去量化偏移）
const NOISE_FLOOR_OFFSET = 6;
/// SBR 合成缓冲大小
const SYN_BUF_SIZE = 2304; // (1280-128)*2
/// 分析缓冲大小
const ANA_BUF_SIZE = 1312;
/// 每帧 QMF 时间槽（16 或 15）
const MAX_SLOTS = 32; // 16*2

/// 频谱参数（sbr_reset 触发判定）
pub const SpectrumParameters = struct {
    bs_start_freq: u8 = 0,
    bs_stop_freq: u8 = 0,
    bs_xover_band: u8 = 0,
    bs_freq_scale: u8 = 0,
    bs_alter_scale: u8 = 0,
    bs_noise_bands: u8 = 0,
};

/// 每通道 SBR 数据（sbr.h SBRData）
const SbrData = struct {
    bs_frame_class: u32 = 0,
    bs_add_harmonic_flag: u32 = 0,
    bs_num_env: u32 = 0,
    bs_freq_res: [9]u8 = [_]u8{0} ** 9,
    bs_num_noise: u32 = 0,
    bs_df_env: [9]u8 = [_]u8{0} ** 9,
    bs_df_noise: [2]u8 = [_]u8{0} ** 2,
    bs_invf_mode: [2][5]u8 = [_][5]u8{[_]u8{0} ** 5} ** 2,
    bs_add_harmonic: [48]u8 = [_]u8{0} ** 48,
    bs_amp_res: u32 = 0,

    synthesis_filterbank_samples: [SYN_BUF_SIZE]f32 = [_]f32{0} ** SYN_BUF_SIZE,
    analysis_filterbank_samples: [ANA_BUF_SIZE]f32 = [_]f32{0} ** ANA_BUF_SIZE,
    synthesis_filterbank_samples_offset: i32 = 0,
    e_a: [2]i32 = .{ -1, -1 },
    bw_array: [5]f32 = [_]f32{0} ** 5,
    W: [2][32][32][2]f32 = [_][32][32][2]f32{[_][32][2]f32{[_][2]f32{[_]f32{0} ** 2} ** 32} ** 32} ** 2,
    Ypos: i32 = 0,
    Y: [2][38][64][2]f32 = [_][38][64][2]f32{[_][64][2]f32{[_][2]f32{[_]f32{0} ** 2} ** 64} ** 38} ** 2,
    g_temp: [42][48]f32 = [_][48]f32{[_]f32{0} ** 48} ** 42,
    q_temp: [42][48]f32 = [_][48]f32{[_]f32{0} ** 48} ** 42,
    s_indexmapped: [9][48]u8 = [_][48]u8{[_]u8{0} ** 48} ** 9,
    env_facs_q: [9][48]u8 = [_][48]u8{[_]u8{0} ** 48} ** 9,
    env_facs: [9][48]f32 = [_][48]f32{[_]f32{0} ** 48} ** 9,
    noise_facs_q: [3][5]u8 = [_][5]u8{[_]u8{0} ** 5} ** 3,
    noise_facs: [3][5]f32 = [_][5]f32{[_]f32{0} ** 5} ** 3,
    t_env: [9]u8 = [_]u8{0} ** 9,
    t_env_num_env_old: u8 = 0,
    t_q: [3]u8 = [_]u8{0} ** 3,
    f_indexnoise: u32 = 0,
    f_indexsine: u32 = 0,
};

pub const Sbr = struct {
    sample_rate: i32 = 0,
    start: i32 = 0,
    ready_for_dequant: i32 = 0,
    id_aac: i32 = 0,
    reset: i32 = 0,
    spectrum_params: SpectrumParameters = .{},
    bs_amp_res_header: i32 = 0,
    bs_limiter_bands: u32 = 0,
    bs_limiter_gains: u32 = 0,
    bs_interpol_freq: u32 = 0,
    bs_smoothing_mode: u32 = 0,
    bs_coupling: u32 = 0,
    k: [5]u32 = [_]u32{0} ** 5,
    kx: [2]u32 = [_]u32{0} ** 2,
    m: [2]u32 = [_]u32{0} ** 2,
    kx_and_m_pushed: u32 = 0,
    n_master: u32 = 0,
    data: [2]SbrData = .{ .{}, .{} },
    n: [2]u32 = [_]u32{0} ** 2,
    n_q: u32 = 0,
    n_lim: u32 = 0,
    f_master: [49]u16 = [_]u16{0} ** 49,
    f_tablelow: [25]u16 = [_]u16{0} ** 25,
    f_tablehigh: [49]u16 = [_]u16{0} ** 49,
    f_tablenoise: [6]u16 = [_]u16{0} ** 6,
    f_tablelim: [30]u16 = [_]u16{0} ** 30,
    num_patches: u32 = 0,
    patch_num_subbands: [6]u8 = [_]u8{0} ** 6,
    patch_start_subband: [6]u8 = [_]u8{0} ** 6,
    X_low: [32][40][2]f32 = [_][40][2]f32{[_][2]f32{[_]f32{0} ** 2} ** 40} ** 32,
    X_high: [64][40][2]f32 = [_][40][2]f32{[_][2]f32{[_]f32{0} ** 2} ** 40} ** 64,
    X: [2][2][38][64]f32 = [_][2][38][64]f32{[_][38][64]f32{[_][64]f32{[_]f32{0} ** 64} ** 38} ** 2} ** 2,
    alpha0: [64][2]f32 = [_][2]f32{[_]f32{0} ** 2} ** 64,
    alpha1: [64][2]f32 = [_][2]f32{[_]f32{0} ** 2} ** 64,
    e_origmapped: [8][48]f32 = [_][48]f32{[_]f32{0} ** 48} ** 8,
    q_mapped: [8][48]f32 = [_][48]f32{[_]f32{0} ** 48} ** 8,
    s_mapped: [8][48]u8 = [_][48]u8{[_]u8{0} ** 48} ** 8,
    e_curr: [8][48]f32 = [_][48]f32{[_]f32{0} ** 48} ** 8,
    q_m: [8][48]f32 = [_][48]f32{[_]f32{0} ** 48} ** 8,
    s_m: [8][48]f32 = [_][48]f32{[_]f32{0} ** 48} ** 8,
    gain: [8][48]f32 = [_][48]f32{[_]f32{0} ** 48} ** 8,
    qmf_filter_scratch: [5][64]f32 = [_][64]f32{[_]f32{0} ** 64} ** 5,
    mdct_ana: mdct_mod.Mdct(f32),
    mdct: mdct_mod.Mdct(f32),

    /// 每帧解码后的音频（输出到 lib.zig 的 output 缓冲）
    out_l: [2048]f32 = [_]f32{0} ** 2048,
    out_r: [2048]f32 = [_]f32{0} ** 2048,
    /// PS（参数立体声）状态
    ps: psmod.PSCtx = undefined,
    ps_enabled: bool = false,
    /// 每声道重建子带（PS 需要 L/R 都生成后处理）
    X_saved: [2][2][38][64]f32 = [_][2][38][64]f32{[_][38][64]f32{[_][64]f32{[_]f32{0} ** 64} ** 38} ** 2} ** 2,

    pub fn init() Sbr {
        return .{
            .mdct_ana = mdct_mod.Mdct(f32).initSbr(.analysis),
            .mdct = mdct_mod.Mdct(f32).initSbr(.synthesis),
            // synthesis_filterbank_samples_offset 初始 = 2304 - 1152（ff_aac_sbr_ctx_alloc_init）
            .data = .{
                .{ .synthesis_filterbank_samples_offset = SYN_BUF_SIZE - 1152, .t_env_num_env_old = 0, .t_env = .{0} ** 9 },
                .{ .synthesis_filterbank_samples_offset = SYN_BUF_SIZE - 1152, .t_env_num_env_old = 0, .t_env = .{0} ** 9 },
            },
        };
    }

    pub fn deinit(self: *Sbr) void {
        _ = self;
    }

    /// 清零全部未定义状态缓冲（对齐 FFmpeg av_mallocz：calloc 零初始化）
    pub fn zeroState(self: *Sbr) void {
        const bytes: [*]u8 = @ptrCast(self);
        @memset(bytes[0..@sizeOf(Sbr)], 0);
        // 恢复 init 设的非零字段
        self.data[0].synthesis_filterbank_samples_offset = SYN_BUF_SIZE - 1152;
        self.data[1].synthesis_filterbank_samples_offset = SYN_BUF_SIZE - 1152;
        self.mdct_ana = mdct_mod.Mdct(f32).initSbr(.analysis);
        self.mdct = mdct_mod.Mdct(f32).initSbr(.synthesis);
        // PS 状态初始化（表生成）
        psmod.psInit(&self.ps);
    }

    // ---------------- 工具 ----------------

    fn turnoff(self: *Sbr) void {
        self.start = 0;
        self.ready_for_dequant = 0;
        self.kx[1] = 32;
        self.m[1] = 0;
        self.data[0].e_a[1] = -1;
        self.data[1].e_a[1] = -1;
        self.spectrum_params.bs_start_freq = 0xFF;
        self.spectrum_params.bs_stop_freq = 0xFF;
        self.spectrum_params.bs_xover_band = 0xFF;
        self.spectrum_params.bs_freq_scale = 0xFF;
        self.spectrum_params.bs_alter_scale = 0xFF;
        self.spectrum_params.bs_noise_bands = 0xFF;
    }

    // ---------------- sbr_offset ----------------

    fn sbrOffsetPtr(sample_rate: i32) ?[]const i8 {
        return switch (sample_rate) {
            16000 => &sbr_offset_rows[0],
            22050 => &sbr_offset_rows[1],
            24000 => &sbr_offset_rows[2],
            32000 => &sbr_offset_rows[3],
            44100, 48000, 64000 => &sbr_offset_rows[4],
            88200, 96000, 128000, 176400, 192000 => &sbr_offset_rows[5],
            else => null,
        };
    }
};

// exp2fi：IEEE 指数位构造 2^x（精确 float）
fn exp2fi(x: i32) f32 {
    if (x >= -126 and x <= 128) {
        const bits: u32 = @bitCast(@as(i32, x + 127) << 23);
        return @bitCast(bits);
    } else if (x > 128) {
        return std.math.inf(f32);
    } else if (x > -150) {
        const bits: u32 = @as(u32, 1) << @intCast(x + 149);
        return @bitCast(bits);
    } else {
        return 0;
    }
}

// ---------------- 表 ----------------

const sbr_offset_rows = [_][16]i8{
    .{ -8, -7, -6, -5, -4, -3, -2, -1, 0, 1, 2, 3, 4, 5, 6, 7 },
    .{ -5, -4, -3, -2, -1, 0, 1, 2, 3, 4, 5, 6, 7, 9, 11, 13 },
    .{ -5, -3, -2, -1, 0, 1, 2, 3, 4, 5, 6, 7, 9, 11, 13, 16 },
    .{ -6, -4, -2, -1, 0, 1, 2, 3, 4, 5, 6, 7, 9, 11, 13, 16 },
    .{ -4, -2, -1, 0, 1, 2, 3, 4, 5, 6, 7, 9, 11, 13, 16, 20 },
    .{ -2, -1, 0, 1, 2, 3, 4, 5, 6, 7, 9, 11, 13, 16, 20, 24 },
};

/// ceil_log2（read_sbr_grid 用，索引 = bs_num_env）
const ceil_log2 = [_]i8{ 0, 1, 2, 2, 3, 3 };

/// bands_warped（sbr_make_f_tablelim）
const bands_warped = [_]f32{ 1.32715174233856803909, 1.18509277094158210129, 1.11987160404675912501 };

/// bw_tab（sbr_chirp）
const bw_tab = [_]f32{ 0.0, 0.75, 0.9, 0.98 };

/// limgain（sbr_gain_calc）
const limgain = [_]f32{ 0.70795, 1.0, 1.41254, 10000000000.0 };

/// h_smooth（sbr_hf_assemble）
const h_smooth = [_]f32{ 0.33333333333333, 0.30150283239582, 0.21816949906249, 0.11516383427084, 0.03183050093751 };

/// exp2_tab（sbr_dequant）
const exp2_tab = [_]f32{ 1.0, 1.41421356 };

fn qsortInt16(items: []u16) void {
    std.mem.sort(u16, items, {}, std.sort.asc(u16));
}

fn inTableInt16(table: []const u16, needle: u16) bool {
    for (table) |t| if (t == needle) return true;
    return false;
}

fn arrayMinInt16(items: []const u16) u16 {
    var min = items[0];
    for (items[1..]) |v| min = @min(min, v);
    return min;
}

/// make_bands（对数等分频带，输出增量）
fn makeBands(bands: []i16, start: i32, stop: i32, num_bands: usize) void {
    const base = @as(f32, @floatFromInt(stop)) / @as(f32, @floatFromInt(start));
    const base_pow = std.math.pow(f32, base, 1.0 / @as(f32, @floatFromInt(num_bands)));
    var prod: f32 = @floatFromInt(start);
    var previous: i32 = start;
    var k: usize = 0;
    while (k < num_bands - 1) : (k += 1) {
        prod *= base_pow;
        const present: i32 = @intFromFloat(@round(prod));
        bands[k] = @intCast(present - previous);
        previous = present;
    }
    bands[num_bands - 1] = @intCast(stop - previous);
}

// ---------------- 语法解析 ----------------

/// sbr_make_f_tablelim
fn makeFTablelim(self: *Sbr) void {
    if (self.bs_limiter_bands > 0) {
        const lim_bands_per_octave_warped = bands_warped[@intCast(self.bs_limiter_bands - 1)];
        var patch_borders: [7]u16 = undefined;
        patch_borders[0] = @intCast(self.kx[1]);
        var k: usize = 1;
        while (k <= self.num_patches) : (k += 1) {
            patch_borders[k] = patch_borders[k - 1] + self.patch_num_subbands[k - 1];
        }
        // f_tablelim ← f_tablelow (n[0]+1)，再并入 patch 边界，排序
        var f_tablelim_tmp: [30]u16 = undefined;
        const n0: usize = self.n[0] + 1;
        @memcpy(f_tablelim_tmp[0..n0], self.f_tablelow[0..n0]);
        var cnt = n0;
        if (self.num_patches > 1) {
            const num = self.num_patches - 1;
            for (0..num) |i| f_tablelim_tmp[cnt + i] = patch_borders[i + 1];
            cnt += num;
        }
        qsortInt16(f_tablelim_tmp[0..cnt]);
        var n_lim: usize = self.n[0] + self.num_patches - 1;
        var in_idx: usize = 1;
        var out_idx: usize = 0;
        while (out_idx < n_lim) {
            if (in_idx >= cnt) break;
            const in_val = f_tablelim_tmp[in_idx];
            if (@as(f32, @floatFromInt(in_val)) >= @as(f32, @floatFromInt(f_tablelim_tmp[out_idx])) * lim_bands_per_octave_warped) {
                out_idx += 1;
                f_tablelim_tmp[out_idx] = in_val;
                in_idx += 1;
            } else if (in_val == f_tablelim_tmp[out_idx] or !inTableInt16(patch_borders[0..self.num_patches + 1], in_val)) {
                in_idx += 1;
                n_lim -= 1;
            } else if (!inTableInt16(patch_borders[0..self.num_patches + 1], f_tablelim_tmp[out_idx])) {
                f_tablelim_tmp[out_idx] = in_val;
                in_idx += 1;
                n_lim -= 1;
            } else {
                out_idx += 1;
                f_tablelim_tmp[out_idx] = in_val;
                in_idx += 1;
            }
        }
        @memcpy(self.f_tablelim[0 .. n_lim + 1], f_tablelim_tmp[0 .. n_lim + 1]);
        self.n_lim = @intCast(n_lim);
    } else {
        self.f_tablelim[0] = self.f_tablelow[0];
        self.f_tablelim[1] = self.f_tablelow[self.n[0]];
        self.n_lim = 1;
    }
}

/// sbr_hf_calc_npatches
fn hfCalcNpatches(self: *Sbr) bool {
    var msb: i32 = @intCast(self.k[0]);
    var usb: i32 = @intCast(self.kx[1]);
    const goal_sb: i32 = @divTrunc((@as(i32, 1000) << 11) + (self.sample_rate >> 1), self.sample_rate);
    self.num_patches = 0;
    var k: usize = 0;
    if (goal_sb < @as(i32, @intCast(self.kx[1] + self.m[1]))) {
        while (self.f_master[k] < goal_sb) k += 1;
    } else {
        k = self.n_master;
    }
    var odd: i32 = 0;
    var sb: i32 = 0;
    while (true) {
        var i: usize = k;
        sb = 0;
        while (i == k or sb > (self.k[0] - 1 + @as(u32, @intCast(msb)) - @as(u32, @intCast(odd)))) {
            sb = @intCast(self.f_master[i]);
            odd = (sb + @as(i32, @intCast(self.k[0]))) & 1;
            if (i == 0) break;
            i -= 1;
        }
        if (self.num_patches > 5) return false;
        const pw: i32 = @max(sb - usb, 0);
        self.patch_num_subbands[self.num_patches] = @intCast(pw);
        self.patch_start_subband[self.num_patches] = @intCast(self.k[0] - @as(u32, @intCast(odd)) - @as(u32, @intCast(pw)));
        if (self.patch_num_subbands[self.num_patches] > 0) {
            usb = sb;
            msb = sb;
            self.num_patches += 1;
        } else {
            msb = @intCast(self.kx[1]);
        }
        if (self.f_master[k] - @as(u16, @intCast(sb)) < 3) k = self.n_master;
        if (sb == @as(i32, @intCast(self.kx[1] + self.m[1]))) break;
    }
    if (self.num_patches > 1 and self.patch_num_subbands[self.num_patches - 1] < 3) {
        self.num_patches -= 1;
    }
    return true;
}

/// sbr_make_f_derived
fn makeFDerived(self: *Sbr) bool {
    const n1: u32 = self.n_master - @as(u32, self.spectrum_params.bs_xover_band);
    self.n[1] = n1;
    self.n[0] = (n1 + 1) >> 1;
    @memcpy(self.f_tablehigh[0 .. n1 + 1], self.f_master[self.spectrum_params.bs_xover_band ..][0 .. n1 + 1]);
    self.m[1] = self.f_tablehigh[n1] - self.f_tablehigh[0];
    self.kx[1] = self.f_tablehigh[0];
    if (self.kx[1] + self.m[1] > 64) return false;
    if (self.kx[1] > 32) return false;

    self.f_tablelow[0] = self.f_tablehigh[0];
    const temp: u32 = n1 & 1;
    var k: usize = 1;
    while (k <= self.n[0]) : (k += 1) {
        self.f_tablelow[k] = self.f_tablehigh[2 * k - temp];
    }

    self.n_q = @max(1, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(self.spectrum_params.bs_noise_bands)) * std.math.log2(@as(f32, @floatFromInt(self.k[2])) / @as(f32, @floatFromInt(self.kx[1])))))));
    if (self.n_q > 5) {
        self.n_q = 1;
        return false;
    }

    self.f_tablenoise[0] = self.f_tablelow[0];
    var temp2: u32 = 0;
    k = 1;
    while (k <= self.n_q) : (k += 1) {
        temp2 += @as(u32, @intCast(@as(i64, self.n[0]) - @as(i64, temp2))) / @as(u32, @intCast(self.n_q + 1 - @as(u32, @intCast(k))));
        self.f_tablenoise[k] = self.f_tablelow[temp2];
    }
    if (!hfCalcNpatches(self, )) return false;
    makeFTablelim(self, );
    self.data[0].f_indexnoise = 0;
    self.data[1].f_indexnoise = 0;
    return true;
}

/// sbr_make_f_master
fn makeFMaster(self: *Sbr) bool {
    var max_qmf_subbands: u32 = 0;
    var start_min: u32 = 0;
    var stop_min: u32 = 0;
    const sbr_offset_ptr = Sbr.sbrOffsetPtr(self.sample_rate) orelse return false;
    const temp: u32 = if (self.sample_rate < 32000)
        3000
    else if (self.sample_rate < 64000)
        4000
    else
        5000;
    start_min = ((@as(u32, temp) << 7) + @as(u32, @intCast(self.sample_rate >> 1))) / @as(u32, @intCast(self.sample_rate));
    stop_min = ((@as(u32, temp) << 8) + @as(u32, @intCast(self.sample_rate >> 1))) / @as(u32, @intCast(self.sample_rate));

    // 偏移为有符号（负值表示起始频率前移）；用 i32 计算防 u32 溢出（ffmpeg 同款）
    const k0: i32 = @as(i32, @intCast(start_min)) + @as(i32, sbr_offset_ptr[self.spectrum_params.bs_start_freq]);
    if (k0 < 0) return false;
    self.k[0] = @intCast(k0);

    if (self.spectrum_params.bs_stop_freq < 14) {
        var stop_dk: [13]i16 = undefined;
        self.k[2] = stop_min;
        makeBands(&stop_dk, @intCast(stop_min), 64, 13);
        // qsort u16 视图
        var sortbuf: [13]u16 = undefined;
        for (0..13) |i| sortbuf[i] = @intCast(stop_dk[i]);
        qsortInt16(&sortbuf);
        var k2: usize = 0;
        while (k2 < self.spectrum_params.bs_stop_freq) : (k2 += 1) {
            self.k[2] += sortbuf[k2];
        }
    } else if (self.spectrum_params.bs_stop_freq == 14) {
        self.k[2] = 2 * self.k[0];
    } else if (self.spectrum_params.bs_stop_freq == 15) {
        self.k[2] = 3 * self.k[0];
    } else {
        return false;
    }
    self.k[2] = @min(64, self.k[2]);

    if (self.sample_rate <= 32000) {
        max_qmf_subbands = 48;
    } else if (self.sample_rate == 44100) {
        max_qmf_subbands = 35;
    } else {
        max_qmf_subbands = 32;
    }
    if (self.k[2] - self.k[0] > max_qmf_subbands) return false;

    if (self.spectrum_params.bs_freq_scale == 0) {
        const dk: u32 = self.spectrum_params.bs_alter_scale + 1;
        self.n_master = ((self.k[2] - self.k[0] + (dk & 2)) >> @intCast(dk)) << 1;
        if (self.n_master <= 0 or self.spectrum_params.bs_xover_band >= self.n_master) return false;
        var k: usize = 1;
        while (k <= self.n_master) : (k += 1) self.f_master[k] = @intCast(dk);
        const k2diff: i32 = @as(i32, @intCast(self.k[2] - self.k[0])) - @as(i32, @intCast(self.n_master * dk));
        if (k2diff < 0) {
            self.f_master[1] -= 1;
            if (k2diff < -1) self.f_master[2] -= 1;
        } else if (k2diff > 0) {
            self.f_master[self.n_master] += @intCast(k2diff);
        }
        self.f_master[0] = @intCast(self.k[0]);
        k = 1;
        while (k <= self.n_master) : (k += 1) self.f_master[k] += self.f_master[k - 1];
    } else {
        const half_bands: u32 = 7 - self.spectrum_params.bs_freq_scale;
        var two_regions: bool = undefined;
        if (49 * self.k[2] > 110 * self.k[0]) {
            two_regions = true;
            self.k[1] = 2 * self.k[0];
        } else {
            two_regions = false;
            self.k[1] = self.k[2];
        }
        const num_bands_0: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(half_bands)) * std.math.log2(@as(f32, @floatFromInt(self.k[1])) / @as(f32, @floatFromInt(self.k[0])))) * 2);
        if (num_bands_0 <= 0) return false;
        var vk0: [49]i16 = undefined;
        vk0[0] = 0;
        makeBands(vk0[1..], @intCast(self.k[0]), @intCast(self.k[1]), @intCast(num_bands_0));
        var vk0_sort: [49]u16 = undefined;
        for (0..@as(usize, @intCast(num_bands_0))) |i| vk0_sort[i] = @intCast(vk0[i + 1]);
        qsortInt16(vk0_sort[0..@as(usize, @intCast(num_bands_0))]);
        const vdk0_max: u16 = vk0_sort[@as(usize, @intCast(num_bands_0 - 1))];
        vk0[0] = @intCast(self.k[0]);
        var k: usize = 1;
        while (k <= @as(usize, @intCast(num_bands_0))) : (k += 1) {
            if (vk0_sort[k - 1] <= 0) return false;
            vk0[k] = @intCast(@as(i32, vk0_sort[k - 1]) + @as(i32, vk0[k - 1]));
        }

        if (two_regions) {
            const invwarp: f32 = if (self.spectrum_params.bs_alter_scale != 0) 0.76923076923076923077 else 1.0;
            const num_bands_1: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(half_bands)) * invwarp * std.math.log2(@as(f32, @floatFromInt(self.k[2])) / @as(f32, @floatFromInt(self.k[1])))) * 2);
            var vk1: [49]i16 = undefined;
            makeBands(vk1[1..], @intCast(self.k[1]), @intCast(self.k[2]), @intCast(num_bands_1));
            var vk1_vals: [49]u16 = undefined;
            for (0..@as(usize, @intCast(num_bands_1))) |i| vk1_vals[i] = @intCast(vk1[i + 1]);
            const vdk1_min = arrayMinInt16(vk1_vals[0..@as(usize, @intCast(num_bands_1))]);
            if (vdk1_min < vdk0_max) {
                qsortInt16(vk1_vals[0..@as(usize, @intCast(num_bands_1))]);
                const change: u16 = @min(vdk0_max - vk1_vals[0], (vk1_vals[@as(usize, @intCast(num_bands_1 - 1))] - vk1_vals[0]) >> 1);
                vk1_vals[0] += change;
                vk1_vals[@as(usize, @intCast(num_bands_1 - 1))] -= change;
            }
            qsortInt16(vk1_vals[0..@as(usize, @intCast(num_bands_1))]);
            vk1[0] = @intCast(self.k[1]);
            k = 1;
            while (k <= @as(usize, @intCast(num_bands_1))) : (k += 1) {
                if (vk1_vals[k - 1] <= 0) return false;
                vk1[k] = @intCast(@as(i32, vk1_vals[k - 1]) + @as(i32, vk1[k - 1]));
            }
            self.n_master = @as(u32, @intCast(num_bands_0)) + @as(u32, @intCast(num_bands_1));
            if (self.n_master <= 0 or self.spectrum_params.bs_xover_band >= self.n_master) return false;
            @memcpy(self.f_master[0 .. @as(usize, @intCast(num_bands_0)) + 1], @as([*]const u16, @ptrCast(&vk0))[0 .. @as(usize, @intCast(num_bands_0)) + 1]);
            @memcpy(self.f_master[@as(usize, @intCast(num_bands_0)) + 1 ..][0..@as(usize, @intCast(num_bands_1))], @as([*]const u16, @ptrCast(&vk1))[1 .. @as(usize, @intCast(num_bands_1)) + 1]);
        } else {
            self.n_master = @intCast(num_bands_0);
            if (self.n_master <= 0 or self.spectrum_params.bs_xover_band >= self.n_master) return false;
            @memcpy(self.f_master[0 .. @as(usize, @intCast(num_bands_0)) + 1], @as([*]const u16, @ptrCast(&vk0))[0 .. @as(usize, @intCast(num_bands_0)) + 1]);
        }
    }
    return true;
}

/// sbr_reset
fn sbrReset(self: *Sbr) void {
    if (!makeFMaster(self, )) {
        self.turnoff();
        return;
    }
    if (!makeFDerived(self, )) {
        self.turnoff();
        return;
    }
}

// ---------------- 主入口：sbr_decode_extension ----------------

/// 解析 SBR 扩展数据（FIL 元素）。
pub fn decodeExtension(self: *Sbr, br: *BitReader, cnt: usize, id_aac: i32) !void {
    self.reset = 0;
    if (self.sample_rate == 0) self.sample_rate = 2 * 44100;

    // 保存上帧 kx/m（apply 时 push 到 kx[0]/m[0]）
    self.kx[0] = self.kx[1];
    self.m[0] = self.m[1];
    self.kx_and_m_pushed = 1;

    var gb = br.*;
    const has_header = gb.readBits(1) catch return error.Corrupt;
    if (has_header != 0) {
        try readHeader(self, &gb);
    }
    if (self.reset != 0) sbrReset(self);
    if (self.start != 0) {
        try readData(self, &gb, id_aac);
    }
    // 推进主位流：SBR 数据占 cnt 字节（含已读的 extension_type 4bit）
    br.skipBits(@intCast(cnt * 8 - 4)) catch return error.Corrupt;
}

fn readHeader(self: *Sbr, gb: *BitReader) !void {
    const old_spectrum_params = self.spectrum_params;
    self.start = 1;
    self.ready_for_dequant = 0;
    self.bs_amp_res_header = @intCast(gb.readBits(1) catch return error.Corrupt);
    self.spectrum_params.bs_start_freq = @intCast(gb.readBits(4) catch return error.Corrupt);
    self.spectrum_params.bs_stop_freq = @intCast(gb.readBits(4) catch return error.Corrupt);
    self.spectrum_params.bs_xover_band = @intCast(gb.readBits(3) catch return error.Corrupt);
    _ = gb.readBits(2) catch return error.Corrupt; // bs_reserved
    const bs_header_extra_1 = gb.readBits(1) catch return error.Corrupt;
    const bs_header_extra_2 = gb.readBits(1) catch return error.Corrupt;
    if (bs_header_extra_1 != 0) {
        self.spectrum_params.bs_freq_scale = @intCast(gb.readBits(2) catch return error.Corrupt);
        self.spectrum_params.bs_alter_scale = @intCast(gb.readBits(1) catch return error.Corrupt);
        self.spectrum_params.bs_noise_bands = @intCast(gb.readBits(2) catch return error.Corrupt);
    } else {
        self.spectrum_params.bs_freq_scale = 2;
        self.spectrum_params.bs_alter_scale = 1;
        self.spectrum_params.bs_noise_bands = 2;
    }
    // 比较 spectrum 参数变化 → reset
    const old = old_spectrum_params;
    const cur = self.spectrum_params;
    if (!(old.bs_start_freq == cur.bs_start_freq and old.bs_stop_freq == cur.bs_stop_freq and old.bs_xover_band == cur.bs_xover_band and old.bs_freq_scale == cur.bs_freq_scale and old.bs_alter_scale == cur.bs_alter_scale and old.bs_noise_bands == cur.bs_noise_bands)) {
        self.reset = 1;
    }
    const old_bs_limiter_bands = self.bs_limiter_bands;
    if (bs_header_extra_2 != 0) {
        self.bs_limiter_bands = gb.readBits(2) catch return error.Corrupt;
        self.bs_limiter_gains = gb.readBits(2) catch return error.Corrupt;
        self.bs_interpol_freq = gb.readBits(1) catch return error.Corrupt;
        self.bs_smoothing_mode = gb.readBits(1) catch return error.Corrupt;
    } else {
        self.bs_limiter_bands = 2;
        self.bs_limiter_gains = 2;
        self.bs_interpol_freq = 1;
        self.bs_smoothing_mode = 1;
    }
    if (self.bs_limiter_bands != old_bs_limiter_bands and self.reset == 0) {
        makeFTablelim(self, );
    }
}

fn readGrid(self: *Sbr, ch_data: *SbrData, gb: *BitReader, num_time_slots: u32) !bool {
    var abs_bord_trail: u32 = num_time_slots;
    const bs_num_env_old = ch_data.bs_num_env;
    ch_data.bs_freq_res[0] = ch_data.bs_freq_res[ch_data.bs_num_env];
    ch_data.bs_amp_res = @intCast(self.bs_amp_res_header);
    ch_data.t_env_num_env_old = ch_data.t_env[ch_data.bs_num_env];

    const bs_frame_class = gb.readBits(2) catch return error.Corrupt;
    var bs_num_env: u32 = 0;
    var bs_num_noise: u32 = 0;
    var bs_pointer: u32 = 0;

    if (bs_frame_class == 0) { // FIXFIX
        bs_num_env = @as(u32, 1) << @intCast(gb.readBits(2) catch return error.Corrupt);
        if (bs_num_env > 5) return false;
        ch_data.bs_num_env = bs_num_env;
        const num_rel_lead: u32 = bs_num_env - 1;
        if (bs_num_env == 1) ch_data.bs_amp_res = 0;
        ch_data.t_env[0] = 0;
        ch_data.t_env[bs_num_env] = @as(u8, @intCast(abs_bord_trail));
        abs_bord_trail = (abs_bord_trail + (bs_num_env >> 1)) / bs_num_env;
        var i: usize = 0;
        while (i < num_rel_lead) : (i += 1) {
            ch_data.t_env[i + 1] = ch_data.t_env[i] + @as(u8, @intCast(abs_bord_trail));
        }
        ch_data.bs_freq_res[1] = @intCast(gb.readBits(1) catch return error.Corrupt);
        i = 1;
        while (i < bs_num_env) : (i += 1) ch_data.bs_freq_res[i + 1] = ch_data.bs_freq_res[1];
    } else if (bs_frame_class == 1) { // FIXVAR
        abs_bord_trail += gb.readBits(2) catch return error.Corrupt;
        const num_rel_trail: u32 = gb.readBits(2) catch return error.Corrupt;
        bs_num_env = num_rel_trail + 1;
        ch_data.t_env[0] = 0;
        ch_data.t_env[bs_num_env] = @as(u8, @intCast(abs_bord_trail));
        var i: u32 = 0;
        while (i < num_rel_trail) : (i += 1) {
            ch_data.t_env[bs_num_env - 1 - @as(usize, i)] = @as(u8, @intCast(@as(i32, ch_data.t_env[bs_num_env - @as(usize, i)]) - @as(i32, @intCast(2 * (gb.readBits(2) catch return error.Corrupt))) - 2));
        }
        bs_pointer = gb.readBits(@intCast(ceil_log2[bs_num_env])) catch return error.Corrupt;
        i = 0;
        while (i < bs_num_env) : (i += 1) ch_data.bs_freq_res[bs_num_env - @as(usize, i)] = @intCast(gb.readBits(1) catch return error.Corrupt);
    } else if (bs_frame_class == 2) { // VARFIX
        ch_data.t_env[0] = @intCast(gb.readBits(2) catch return error.Corrupt);
        const num_rel_lead: u32 = gb.readBits(2) catch return error.Corrupt;
        bs_num_env = num_rel_lead + 1;
        ch_data.t_env[bs_num_env] = @as(u8, @intCast(abs_bord_trail));
        var i: u32 = 0;
        while (i < num_rel_lead) : (i += 1) {
            ch_data.t_env[i + 1] = @as(u8, @intCast(@as(i32, ch_data.t_env[i]) + @as(i32, @intCast(2 * (gb.readBits(2) catch return error.Corrupt))) + 2));
        }
        bs_pointer = gb.readBits(@intCast(ceil_log2[bs_num_env])) catch return error.Corrupt;
        i = 1;
        while (i <= bs_num_env) : (i += 1) ch_data.bs_freq_res[i] = @intCast(gb.readBits(1) catch return error.Corrupt);
    } else { // VARVAR
        ch_data.t_env[0] = @intCast(gb.readBits(2) catch return error.Corrupt);
        abs_bord_trail += gb.readBits(2) catch return error.Corrupt;
        const num_rel_lead: u32 = gb.readBits(2) catch return error.Corrupt;
        const num_rel_trail: u32 = gb.readBits(2) catch return error.Corrupt;
        bs_num_env = num_rel_lead + num_rel_trail + 1;
        if (bs_num_env > 5) return false;
        ch_data.t_env[bs_num_env] = @as(u8, @intCast(abs_bord_trail));
        var i: u32 = 0;
        while (i < num_rel_lead) : (i += 1) {
            ch_data.t_env[i + 1] = @as(u8, @intCast(@as(i32, ch_data.t_env[i]) + @as(i32, @intCast(2 * (gb.readBits(2) catch return error.Corrupt))) + 2));
        }
        i = 0;
        while (i < num_rel_trail) : (i += 1) {
            ch_data.t_env[bs_num_env - 1 - @as(usize, i)] = @as(u8, @intCast(@as(i32, ch_data.t_env[bs_num_env - @as(usize, i)]) - @as(i32, @intCast(2 * (gb.readBits(2) catch return error.Corrupt))) - 2));
        }
        bs_pointer = gb.readBits(@intCast(ceil_log2[bs_num_env])) catch return error.Corrupt;
        i = 1;
        while (i <= bs_num_env) : (i += 1) ch_data.bs_freq_res[i] = @intCast(gb.readBits(1) catch return error.Corrupt);
    }

    ch_data.bs_frame_class = bs_frame_class;
    // 校验 t_env 严格递增
    var i: usize = 0;
    while (i < bs_num_env) : (i += 1) {
        if (ch_data.t_env[i] >= ch_data.t_env[i + 1]) return false;
    }
    if (bs_pointer > bs_num_env + 1) return false;

    bs_num_noise = if (bs_num_env > 1) 2 else 1;
    ch_data.bs_num_noise = bs_num_noise;
    ch_data.t_q[0] = ch_data.t_env[0];
    ch_data.t_q[bs_num_noise] = ch_data.t_env[bs_num_env];
    if (bs_num_noise > 1) {
        var idx: u32 = 0;
        if (bs_frame_class == 0) {
            idx = bs_num_env >> 1;
        } else if ((bs_frame_class & 1) != 0) {
            idx = bs_num_env - @max(bs_pointer - 1, 1);
        } else {
            if (bs_pointer == 0) {
                idx = 1;
            } else if (bs_pointer == 1) {
                idx = bs_num_env - 1;
            } else {
                idx = bs_pointer - 1;
            }
        }
        ch_data.t_q[1] = ch_data.t_env[idx];
    }
    ch_data.e_a[0] = -@as(i32, @intFromBool(ch_data.e_a[1] != bs_num_env_old));
    ch_data.e_a[1] = -1;
    if ((bs_frame_class & 1) != 0 and bs_pointer != 0) {
        ch_data.e_a[1] = @as(i32, @intCast(bs_num_env)) + 1 - @as(i32, @intCast(bs_pointer));
    } else if (bs_frame_class == 2 and bs_pointer > 1) {
        ch_data.e_a[1] = @as(i32, @intCast(bs_pointer)) - 1;
    }
    ch_data.bs_num_env = bs_num_env;
    return true;
}

fn copySbrGrid(dst: *SbrData, src: *const SbrData) void {
    dst.bs_freq_res[0] = dst.bs_freq_res[dst.bs_num_env];
    dst.t_env_num_env_old = dst.t_env[dst.bs_num_env];
    dst.e_a[0] = -@as(i32, @intFromBool(dst.e_a[1] != dst.bs_num_env));
    @memcpy(dst.bs_freq_res[1..], src.bs_freq_res[1..]);
    @memcpy(dst.t_env[0..9], src.t_env[0..9]);
    @memcpy(dst.t_q[0..3], src.t_q[0..3]);
    dst.bs_num_env = src.bs_num_env;
    dst.bs_amp_res = src.bs_amp_res;
    dst.bs_num_noise = src.bs_num_noise;
    dst.bs_frame_class = src.bs_frame_class;
    dst.e_a[1] = src.e_a[1];
}

fn readDtdf(ch_data: *SbrData, gb: *BitReader) !void {
    var i: u32 = 0;
    while (i < ch_data.bs_num_env) : (i += 1) {
        ch_data.bs_df_env[i] = @intCast(gb.readBits(1) catch return error.Corrupt);
    }
    i = 0;
    while (i < ch_data.bs_num_noise) : (i += 1) {
        ch_data.bs_df_noise[i] = @intCast(gb.readBits(1) catch return error.Corrupt);
    }
}

fn readInvf(self: *Sbr, ch_data: *SbrData, gb: *BitReader) !void {
    @memcpy(ch_data.bs_invf_mode[1][0..5], ch_data.bs_invf_mode[0][0..5]);
    var i: u32 = 0;
    while (i < self.n_q) : (i += 1) {
        ch_data.bs_invf_mode[0][i] = @intCast(gb.readBits(2) catch return error.Corrupt);
    }
}

/// VLC 解码（规范哈夫曼，逐位匹配）。码字按 ff_vlc_init_from_lengths 算法
/// 即时生成：(len, symbol) 升序，code 左对齐累加。
fn getVlc(gb: *BitReader, table_idx: usize) Error!i32 {
    const nb = huff.sbr_huff_nb_codes[table_idx];
    const offset = huff.sbr_vlc_offsets[table_idx];
    // 累计偏移（各表大小不同）
    var base: usize = 0;
    for (0..table_idx) |t| base += huff.sbr_huff_nb_codes[t];
    var acc: u32 = 0;
    var len: usize = 1;
    while (len <= huff.sbr_vlc_max_len) : (len += 1) {
        const bit = gb.readBits(1) catch return error.Corrupt;        acc = (acc << 1) | bit;
        // 遍历表项，计算每个匹配 len 的项的规范码字
        var code: u64 = 0;
        var i: usize = 0;
        while (i < nb) : (i += 1) {
            const l = huff.sbr_huff_lengths[base + i];
            if (l == 0) continue;
            if (l == len) {
                // code 是 32 位左对齐码字，acc 是 len 位；比较码字高 len 位
                const c_hi = @as(u32, @intCast(code >> @intCast(32 - len)));
                if (c_hi == acc) {
                    return @as(i32, huff.sbr_huff_symbols[base + i]) + offset;
                }
            }
            code += @as(u64, 1) << @intCast(32 - @as(u6, @intCast(l)));
        }
    }
    return error.Corrupt;
}

fn readEnvelope(self: *Sbr, ch_data: *SbrData, gb: *BitReader, ch: u32, is_coupling: u32) !bool {
    var env: u32 = 0;
    const delta: u32 = @as(u32, @intFromBool(ch == 1 and is_coupling == 1)) + 1;
    const odd: u32 = self.n[1] & 1;

    // 表选择
    // 索引：0=t_env_1_5dB, 1=f_env_1_5dB, 2=t_env_bal_1_5dB, 3=f_env_bal_1_5dB,
    //      4=t_env_3_0dB, 5=f_env_3_0dB, 6=t_env_bal_3_0dB, 7=f_env_bal_3_0dB
    const is_bal = (ch == 1 and is_coupling == 1);
    const t_huff_base: usize = if (is_bal) (if (ch_data.bs_amp_res != 0) 6 else 2) else (if (ch_data.bs_amp_res != 0) 4 else 0);
    const f_huff_base: usize = t_huff_base + 1;
    const start_bits: u5 = if (is_bal) (if (ch_data.bs_amp_res != 0) 5 else 6) else (if (ch_data.bs_amp_res != 0) 6 else 7);

    while (env < ch_data.bs_num_env) : (env += 1) {
        if (ch_data.bs_df_env[env] != 0) {
            if (ch_data.bs_freq_res[env + 1] == ch_data.bs_freq_res[env]) {
                var j: u32 = 0;
                while (j < self.n[ch_data.bs_freq_res[env + 1]]) : (j += 1) {
                    const dv = try getVlc(gb, t_huff_base);
                    const nv: i32 = @as(i32, ch_data.env_facs_q[env][j]) + @as(i32, @intCast(delta)) * dv;
                    if (nv < 0 or nv > 127) return false;
                    ch_data.env_facs_q[env + 1][j] = @intCast(nv);
                }
            } else if (ch_data.bs_freq_res[env + 1] == 1) {
                var j: u32 = 0;
                while (j < self.n[1]) : (j += 1) {
                    const k = (j + odd) >> 1;
                    const dv = try getVlc(gb, t_huff_base);
                    const nv: i32 = @as(i32, ch_data.env_facs_q[env][k]) + @as(i32, @intCast(delta)) * dv;
                    if (nv < 0 or nv > 127) return false;
                    ch_data.env_facs_q[env + 1][j] = @intCast(nv);
                }
            } else {
                var j: u32 = 0;
                while (j < self.n[0]) : (j += 1) {
                    const k: u32 = if (j != 0) 2 * j - odd else 0;
                    const dv = try getVlc(gb, t_huff_base);
                    const nv: i32 = @as(i32, ch_data.env_facs_q[env][k]) + @as(i32, @intCast(delta)) * dv;
                    if (nv < 0 or nv > 127) return false;
                    ch_data.env_facs_q[env + 1][j] = @intCast(nv);
                }
            }
        } else {
            const start_val = try gb.readBits(start_bits);
            const nv: i32 = @as(i32, @intCast(delta)) * @as(i32, @intCast(start_val));
            if (nv < 0 or nv > 127) return false;
            ch_data.env_facs_q[env + 1][0] = @intCast(nv);
            var j: u32 = 1;
            while (j < self.n[ch_data.bs_freq_res[env + 1]]) : (j += 1) {
                const dv = try getVlc(gb, f_huff_base);
                const vv: i32 = @as(i32, ch_data.env_facs_q[env + 1][j - 1]) + @as(i32, @intCast(delta)) * dv;
                if (vv < 0 or vv > 127) return false;
                ch_data.env_facs_q[env + 1][j] = @intCast(vv);
            }
        }
    }
    @memcpy(ch_data.env_facs_q[0][0..48], ch_data.env_facs_q[ch_data.bs_num_env][0..48]);
    return true;
}

fn readNoise(self: *Sbr, ch_data: *SbrData, gb: *BitReader, ch: u32, is_coupling: u32) !bool {
    var noise: u32 = 0;
    const delta: u32 = @as(u32, @intFromBool(ch == 1 and is_coupling == 1)) + 1;
    const is_bal = (ch == 1 and is_coupling == 1);
    const t_huff_base: usize = if (is_bal) 9 else 8;
    const f_huff_base: usize = if (is_bal) 3 else 5;

    while (noise < ch_data.bs_num_noise) : (noise += 1) {
        if (ch_data.bs_df_noise[noise] != 0) {
            var j: u32 = 0;
            while (j < self.n_q) : (j += 1) {
                const dv = try getVlc(gb, t_huff_base);
                const nv: i32 = @as(i32, ch_data.noise_facs_q[noise][j]) + @as(i32, @intCast(delta)) * dv;
                if (nv < 0 or nv > 30) return false;
                ch_data.noise_facs_q[noise + 1][j] = @intCast(nv);
            }
        } else {
            const start_val = try gb.readBits(5);
            const nv: i32 = @as(i32, @intCast(delta)) * @as(i32, @intCast(start_val));
            if (nv < 0 or nv > 30) return false;
            ch_data.noise_facs_q[noise + 1][0] = @intCast(nv);
            var j: u32 = 1;
            while (j < self.n_q) : (j += 1) {
                const dv = try getVlc(gb, f_huff_base);
                const vv: i32 = @as(i32, ch_data.noise_facs_q[noise + 1][j - 1]) + @as(i32, @intCast(delta)) * dv;
                if (vv < 0 or vv > 30) return false;
                ch_data.noise_facs_q[noise + 1][j] = @intCast(vv);
            }
        }
    }
    @memcpy(ch_data.noise_facs_q[0][0..5], ch_data.noise_facs_q[ch_data.bs_num_noise][0..5]);
    return true;
}

fn readSingleChannelElement(self: *Sbr, gb: *BitReader, num_time_slots: u32) !bool {
    if ((gb.readBits(1) catch return error.Corrupt) != 0) {
        _ = gb.readBits(4) catch return error.Corrupt; // bs_reserved
    }
    if (!try readGrid(self, &self.data[0], gb, num_time_slots)) return false;
    try readDtdf(&self.data[0], gb);
    try readInvf(self, &self.data[0], gb);
    if (!try readEnvelope(self, &self.data[0], gb, 0, 0)) return false;
    if (!try readNoise(self, &self.data[0], gb, 0, 0)) return false;
    self.data[0].bs_add_harmonic_flag = gb.readBits(1) catch return error.Corrupt;
    if (self.data[0].bs_add_harmonic_flag != 0) {
        var i: u32 = 0;
        while (i < self.n[1]) : (i += 1) {
            self.data[0].bs_add_harmonic[i] = @intCast(gb.readBits(1) catch return error.Corrupt);
        }
    }
    return true;
}

fn readChannelPairElement(self: *Sbr, gb: *BitReader, num_time_slots: u32) !bool {
    if ((gb.readBits(1) catch return error.Corrupt) != 0) {
        _ = gb.readBits(8) catch return error.Corrupt; // bs_reserved
    }
    self.bs_coupling = gb.readBits(1) catch return error.Corrupt;
    if (self.bs_coupling != 0) {
        if (!try readGrid(self, &self.data[0], gb, num_time_slots)) return false;
        copySbrGrid(&self.data[1], &self.data[0]);
        try readDtdf(&self.data[0], gb);
        try readDtdf(&self.data[1], gb);
        try readInvf(self, &self.data[0], gb);
        @memcpy(self.data[1].bs_invf_mode[1][0..5], self.data[1].bs_invf_mode[0][0..5]);
        @memcpy(self.data[1].bs_invf_mode[0][0..5], self.data[0].bs_invf_mode[0][0..5]);
        if (!try readEnvelope(self, &self.data[0], gb, 0, 0)) return false;
        if (!try readNoise(self, &self.data[0], gb, 0, 0)) return false;
        if (!try readEnvelope(self, &self.data[1], gb, 1, 1)) return false;
        if (!try readNoise(self, &self.data[1], gb, 1, 1)) return false;
        var i: u32 = 0;
        while (i < 2) : (i += 1) {
            self.data[i].bs_add_harmonic_flag = gb.readBits(1) catch return error.Corrupt;
            if (self.data[i].bs_add_harmonic_flag != 0) {
                var j: u32 = 0;
                while (j < self.n[1]) : (j += 1) {
                    self.data[i].bs_add_harmonic[j] = @intCast(gb.readBits(1) catch return error.Corrupt);
                }
            }
        }
    } else {
        if (!try readGrid(self, &self.data[0], gb, num_time_slots)) return false;
        if (!try readGrid(self, &self.data[1], gb, num_time_slots)) return false;
        try readDtdf(&self.data[0], gb);
        try readDtdf(&self.data[1], gb);
        try readInvf(self, &self.data[0], gb);
        try readInvf(self, &self.data[1], gb);
        if (!try readEnvelope(self, &self.data[0], gb, 0, 0)) return false;
        if (!try readEnvelope(self, &self.data[1], gb, 1, 0)) return false;
        if (!try readNoise(self, &self.data[0], gb, 0, 0)) return false;
        if (!try readNoise(self, &self.data[1], gb, 1, 0)) return false;
        var i: u32 = 0;
        while (i < 2) : (i += 1) {
            self.data[i].bs_add_harmonic_flag = gb.readBits(1) catch return error.Corrupt;
            if (self.data[i].bs_add_harmonic_flag != 0) {
                var j: u32 = 0;
                while (j < self.n[1]) : (j += 1) {
                    self.data[i].bs_add_harmonic[j] = @intCast(gb.readBits(1) catch return error.Corrupt);
                }
            }
        }
    }
    return true;
}

fn readData(self: *Sbr, gb: *BitReader, id_aac: i32) !void {
    self.id_aac = id_aac;
    self.ready_for_dequant = 1;
    const num_time_slots: u32 = 16;
    const ok = switch (id_aac) {
        0 => try readSingleChannelElement(self, gb, num_time_slots),
        1 => try readChannelPairElement(self, gb, num_time_slots),
        else => false,
    };
    if (!ok) {
        self.turnoff();
        return;
    }
    // bs_extended_data（PS 等）
    if ((gb.readBits(1) catch return error.Corrupt) != 0) {
        var num_bits_left: i32 = @intCast(gb.readBits(4) catch return error.Corrupt);
        if (num_bits_left == 15) num_bits_left += @intCast(gb.readBits(8) catch return error.Corrupt);
        num_bits_left <<= 3;
        while (num_bits_left > 7) {
            num_bits_left -= 2;
            const bs_extension_id = gb.readBits(2) catch return error.Corrupt;
            if (bs_extension_id == 2) {
                // EXTENSION_ID_PS：解析参数立体声；返回消费位数，剩余填充位跳过（对齐 ffmpeg）
                const before = gb.bit_pos;
                const consumed = psmod.psReadData(gb, &self.ps.common) catch {
                    gb.bit_pos = before;
                    gb.skipBits(@intCast(num_bits_left)) catch return error.Corrupt;
                    num_bits_left = 0;
                    return;
                };
                num_bits_left -= @as(i32, @intCast(consumed));
                if (num_bits_left > 0) gb.skipBits(@intCast(num_bits_left)) catch return error.Corrupt;
                num_bits_left = 0;
                self.ps_enabled = true;
            } else {
                gb.skipBits(@intCast(num_bits_left)) catch return error.Corrupt;
                num_bits_left = 0;
            }
        }
        if (num_bits_left > 0) _ = gb.readBits(@intCast(num_bits_left)) catch return error.Corrupt;
    }
}

// ---------------- 去量化与合成 ----------------

/// sbr_dequant
fn sbrDequant(self: *Sbr, id_aac: i32) void {
    if (id_aac == 1 and self.bs_coupling != 0) {
        const pan_offset: i32 = if (self.data[0].bs_amp_res != 0) 12 else 24;
        var e: u32 = 1;
        while (e <= self.data[0].bs_num_env) : (e += 1) {
            var k: u32 = 0;
            while (k < self.n[self.data[0].bs_freq_res[e]]) : (k += 1) {
                var temp1: f32 = undefined;
                var temp2: f32 = undefined;
                if (self.data[0].bs_amp_res != 0) {
                    temp1 = exp2fi(@as(i32, self.data[0].env_facs_q[e][k]) + 7);
                    temp2 = exp2fi(pan_offset - @as(i32, self.data[1].env_facs_q[e][k]));
                } else {
                    temp1 = exp2fi(@as(i32, @intCast(self.data[0].env_facs_q[e][k] >> 1)) + 7) * exp2_tab[self.data[0].env_facs_q[e][k] & 1];
                    temp2 = exp2fi(@as(i32, @intCast((pan_offset - @as(i32, self.data[1].env_facs_q[e][k])) >> 1))) * exp2_tab[@as(usize, @intCast((pan_offset - @as(i32, self.data[1].env_facs_q[e][k])) & 1))];
                }
                if (temp1 > 1e20) temp1 = 1;
                const fac = temp1 / (1.0 + temp2);
                self.data[0].env_facs[e][k] = fac;
                self.data[1].env_facs[e][k] = fac * temp2;
            }
        }
        e = 1;
        while (e <= self.data[0].bs_num_noise) : (e += 1) {
            var k: u32 = 0;
            while (k < self.n_q) : (k += 1) {
                const temp1 = exp2fi(NOISE_FLOOR_OFFSET - @as(i32, self.data[0].noise_facs_q[e][k]) + 1);
                const temp2 = exp2fi(12 - @as(i32, self.data[1].noise_facs_q[e][k]));
                const fac = temp1 / (1.0 + temp2);
                self.data[0].noise_facs[e][k] = fac;
                self.data[1].noise_facs[e][k] = fac * temp2;
            }
        }
    } else {
        const nch: usize = if (id_aac == 1) 2 else 1;
        var ch: usize = 0;
        while (ch < nch) : (ch += 1) {
            var e: u32 = 1;
            while (e <= self.data[ch].bs_num_env) : (e += 1) {
                var k: u32 = 0;
                while (k < self.n[self.data[ch].bs_freq_res[e]]) : (k += 1) {
                    if (self.data[ch].bs_amp_res != 0) {
                        self.data[ch].env_facs[e][k] = exp2fi(@as(i32, self.data[ch].env_facs_q[e][k]) + 6);
                    } else {
                        self.data[ch].env_facs[e][k] = exp2fi(@as(i32, @intCast(self.data[ch].env_facs_q[e][k] >> 1)) + 6) * exp2_tab[self.data[ch].env_facs_q[e][k] & 1];
                    }
                    if (self.data[ch].env_facs[e][k] > 1e20) self.data[ch].env_facs[e][k] = 1;
                }
            }
            e = 1;
            while (e <= self.data[ch].bs_num_noise) : (e += 1) {
                var k: u32 = 0;
                while (k < self.n_q) : (k += 1) {
                    self.data[ch].noise_facs[e][k] = exp2fi(NOISE_FLOOR_OFFSET - @as(i32, self.data[ch].noise_facs_q[e][k]));
                }
            }
        }
    }
}

/// sbr_hf_inverse_filter
fn hfInverseFilter(self: *Sbr, k0: u32) void {
    var k: u32 = 0;
    while (k < k0) : (k += 1) {
        var phi: [3][2][2]f32 = undefined;
        autocorrelate(self, k, &phi);
        const dk = phi[2][1][0] * phi[1][0][0] - (phi[1][1][0] * phi[1][1][0] + phi[1][1][1] * phi[1][1][1]) / 1.000001;
        if (dk == 0) {
            self.alpha1[k][0] = 0;
            self.alpha1[k][1] = 0;
        } else {
            const temp_real = phi[0][0][0] * phi[1][1][0] - phi[0][0][1] * phi[1][1][1] - phi[0][1][0] * phi[1][0][0];
            const temp_im = phi[0][0][0] * phi[1][1][1] + phi[0][0][1] * phi[1][1][0] - phi[0][1][1] * phi[1][0][0];
            self.alpha1[k][0] = temp_real / dk;
            self.alpha1[k][1] = temp_im / dk;
        }
        if (phi[1][0][0] == 0) {
            self.alpha0[k][0] = 0;
            self.alpha0[k][1] = 0;
        } else {
            const temp_real = phi[0][0][0] + self.alpha1[k][0] * phi[1][1][0] + self.alpha1[k][1] * phi[1][1][1];
            const temp_im = phi[0][0][1] + self.alpha1[k][1] * phi[1][1][0] - self.alpha1[k][0] * phi[1][1][1];
            self.alpha0[k][0] = -temp_real / phi[1][0][0];
            self.alpha0[k][1] = -temp_im / phi[1][0][0];
        }
        if (self.alpha1[k][0] * self.alpha1[k][0] + self.alpha1[k][1] * self.alpha1[k][1] >= 16.0 or
            self.alpha0[k][0] * self.alpha0[k][0] + self.alpha0[k][1] * self.alpha0[k][1] >= 16.0)
        {
            self.alpha1[k][0] = 0;
            self.alpha1[k][1] = 0;
            self.alpha0[k][0] = 0;
            self.alpha0[k][1] = 0;
        }
    }
}

fn autocorrelate(self: *Sbr, k: u32, phi: *[3][2][2]f32) void {
    const x: *const [40][2]f32 = &self.X_low[k];
    var real_sum2 = x[0][0] * x[2][0] + x[0][1] * x[2][1];
    var imag_sum2 = x[0][0] * x[2][1] - x[0][1] * x[2][0];
    var real_sum0: f32 = 0;
    var real_sum1: f32 = 0;
    var imag_sum1: f32 = 0;
    var i: usize = 1;
    while (i < 38) : (i += 1) {
        real_sum0 += x[i][0] * x[i][0] + x[i][1] * x[i][1];
        real_sum1 += x[i][0] * x[i + 1][0] + x[i][1] * x[i + 1][1];
        imag_sum1 += x[i][0] * x[i + 1][1] - x[i][1] * x[i + 1][0];
        real_sum2 += x[i][0] * x[i + 2][0] + x[i][1] * x[i + 2][1];
        imag_sum2 += x[i][0] * x[i + 2][1] - x[i][1] * x[i + 2][0];
    }
    phi.*[0][1][0] = real_sum2;
    phi.*[0][1][1] = imag_sum2;
    phi.*[2][1][0] = real_sum0 + x[0][0] * x[0][0] + x[0][1] * x[0][1];
    phi.*[1][0][0] = real_sum0 + x[38][0] * x[38][0] + x[38][1] * x[38][1];
    phi.*[1][1][0] = real_sum1 + x[0][0] * x[1][0] + x[0][1] * x[1][1];
    phi.*[1][1][1] = imag_sum1 + x[0][0] * x[1][1] - x[0][1] * x[1][0];
    phi.*[0][0][0] = real_sum1 + x[38][0] * x[39][0] + x[38][1] * x[39][1];
    phi.*[0][0][1] = imag_sum1 + x[38][0] * x[39][1] - x[38][1] * x[39][0];
}

/// sbr_chirp
fn sbrChirp(self: *Sbr, ch_data: *SbrData) void {
    var i: u32 = 0;
    while (i < self.n_q) : (i += 1) {
        var new_bw: f32 = undefined;
        if (ch_data.bs_invf_mode[0][i] + ch_data.bs_invf_mode[1][i] == 1) {
            new_bw = 0.6;
        } else {
            new_bw = bw_tab[ch_data.bs_invf_mode[0][i]];
        }
        if (new_bw < ch_data.bw_array[i]) {
            new_bw = 0.75 * new_bw + 0.25 * ch_data.bw_array[i];
        } else {
            new_bw = 0.90625 * new_bw + 0.09375 * ch_data.bw_array[i];
        }
        ch_data.bw_array[i] = if (new_bw < 0.015625) 0.0 else new_bw;
    }
}

/// sbr_hf_gen（HF 高频生成）
fn sbrHfGen(self: *Sbr, ch_data: *SbrData, t_env: *const [9]u8, bs_num_env: u32) void {
    var g: i32 = 0;
    var k: u32 = self.kx[1];
    var j: u32 = 0;
    while (j < self.num_patches) : (j += 1) {
        var x: u32 = 0;
        while (x < self.patch_num_subbands[j]) : (x += 1) {
            const p = self.patch_start_subband[j] + x;
            while (g <= self.n_q and k >= self.f_tablenoise[@intCast(g)]) g += 1;
            g -= 1;
            hfGen(self, ch_data, k, p, @intCast(g), 2 * t_env[0], 2 * t_env[bs_num_env]);
            k += 1;
        }
    }
    if (k < self.m[1] + self.kx[1]) {
        const n = self.m[1] + self.kx[1] - k;
        for (0..n) |i| {
            for (0..40) |t| {
                self.X_high[k + i][t][0] = 0;
                self.X_high[k + i][t][1] = 0;
            }
        }
    }
}

/// sbrdsp hf_gen（单个高带生成）
fn hfGen(self: *Sbr, ch_data: *SbrData, out_idx: u32, in_idx: u32, g: u32, start: u32, end: u32) void {
    const bw = ch_data.bw_array[g];
    const alpha1 = self.alpha1[in_idx];
    const alpha0 = self.alpha0[in_idx];
    const a0 = alpha1[0] * bw * bw;
    const a1 = alpha1[1] * bw * bw;
    const a2 = alpha0[0] * bw;
    const a3 = alpha0[1] * bw;
    const X_low = self.X_low[in_idx];
    var X_high: *[40][2]f32 = &self.X_high[out_idx];
    // C 传入的是预偏移 ENV_OFF 的指针：完整数组索引 = i + ENV_OFF
    var i: i32 = @intCast(start);
    while (i < @as(i32, @intCast(end))) : (i += 1) {
        const j = @as(usize, @intCast(i + ENV_OFF));
        const j1 = @as(usize, @intCast(i + ENV_OFF - 1));
        const j2 = @as(usize, @intCast(i + ENV_OFF - 2));
        X_high[j][0] = X_low[j2][0] * a0 - X_low[j2][1] * a1 + X_low[j1][0] * a2 - X_low[j1][1] * a3 + X_low[j][0];
        X_high[j][1] = X_low[j2][1] * a0 + X_low[j2][0] * a1 + X_low[j1][1] * a2 + X_low[j1][0] * a3 + X_low[j][1];
    }
}


// ---------------- DSP：QMF 分析/合成与 HF 处理 ----------------

/// vector_fmul_reverse：z[i] = a[i] * b[n-1-i]
fn vecFmulReverse(z: []f32, a: []const f32, b: []const f32, n: usize) void {
    var i: usize = 0;
    while (i < n) : (i += 1) z[i] = a[i] * b[n - 1 - i];
}

/// vector_fmul：z[i] = a[i] * b[i]
fn vecFmul(z: []f32, a: []const f32, b: []const f32, n: usize) void {
    var i: usize = 0;
    while (i < n) : (i += 1) z[i] = a[i] * b[i];
}

/// vector_fmul_add：z[i] = a[i] * b[i] + c[i]
fn vecFmulAdd(z: []f32, a: []const f32, b: []const f32, c: []const f32, n: usize) void {
    var i: usize = 0;
    while (i < n) : (i += 1) z[i] = a[i] * b[i] + c[i];
}

/// sbr_sum64x5：z[k] = Σ_{s=0..4} z[k+64*s]
fn sum64x5(z: []f32) void {
    var k: usize = 0;
    while (k < 64) : (k += 1) {
        z[k] = z[k] + z[k + 64] + z[k + 128] + z[k + 192] + z[k + 256];
    }
}

/// sbr_qmf_pre_shuffle（分析：64→128）
fn qmfPreShuffle(z: []f32) void {
    z[64] = z[0];
    z[65] = z[1];
    var k: usize = 1;
    while (k < 31) : (k += 2) {
        z[64 + 2 * k + 0] = -z[64 - k];
        z[64 + 2 * k + 1] = z[k + 1];
        z[64 + 2 * k + 2] = -z[63 - k];
        z[64 + 2 * k + 3] = z[k + 2];
    }
    z[64 + 62] = -z[33];
    z[64 + 63] = z[32];
}

/// sbr_qmf_post_shuffle（分析：64 float 平铺 → W[32][2] 复数）
/// C 版把 W[32][2] 按 64 个 float 平铺访问 Wi[2k..2k+3]。
fn qmfPostShuffle(W: *[32][2]f32, z: []const f32) void {
    const Wi: [*]f32 = @ptrCast(W);
    var k: usize = 0;
    while (k < 32) : (k += 2) {
        Wi[2 * k + 0] = -z[63 - k];
        Wi[2 * k + 1] = z[k + 0];
        Wi[2 * k + 2] = -z[62 - k];
        Wi[2 * k + 3] = z[k + 1];
    }
}

/// sbr_neg_odd_64（合成全速率：虚部奇序取负）
fn negOdd64(x: []f32) void {
    var i: usize = 1;
    while (i < 64) : (i += 4) {
        x[i] *= -1;
        x[i + 2] *= -1;
    }
}

/// sbr_qmf_deint_bfly（合成全速率：128 输出）
fn qmfDeintBfly(v: []f32, src0: []const f32, src1: []const f32) void {
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        v[i] = src0[i] - src1[63 - i];
        v[127 - i] = src0[i] + src1[63 - i];
    }
}

/// sbr_qmf_deint_neg（合成下采样：64 输出）
fn qmfDeintNeg(v: []f32, src: []const f32) void {
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        v[i] = src[63 - 2 * i];
        v[63 - i] = -src[63 - 2 * i - 1];
    }
}

/// sbr_sum_square：复数能量（n 必须偶数）。累加顺序对齐 ffmpeg
/// sbr_sum_square_c：sum0 逐个累加实部（i、i+1 分两次 +=），sum1 累加虚部。
fn sumSquare(x: []const f32, n: usize) f32 {
    var sum0: f32 = 0;
    var sum1: f32 = 0;
    var i: usize = 0;
    while (i < n) : (i += 2) {
        sum0 += x[2 * i] * x[2 * i];
        sum1 += x[2 * i + 1] * x[2 * i + 1];
        sum0 += x[2 * (i + 1)] * x[2 * (i + 1)];
        sum1 += x[2 * (i + 1) + 1] * x[2 * (i + 1) + 1];
    }
    return sum0 + sum1;
}

/// sbr_lf_gen
fn sbrLfGen(self: *Sbr, ch_data: *SbrData, buf_idx: usize, num_time_slots: u32) void {
    const t_hfgen: usize = 8;
    const i_f = num_time_slots * 2;
    @memset(@as([*]u8, @ptrCast(&self.X_low))[0 .. 32 * 40 * 2 * 4], 0);
    var k: u32 = 0;
    while (k < self.kx[1]) : (k += 1) {
        var i: usize = t_hfgen;
        while (i < i_f + t_hfgen) : (i += 1) {
            self.X_low[k][i][0] = ch_data.W[buf_idx][i - t_hfgen][k][0];
            self.X_low[k][i][1] = ch_data.W[buf_idx][i - t_hfgen][k][1];
        }
    }
    const prev_idx: usize = 1 - buf_idx;
    k = 0;
    while (k < self.kx[0]) : (k += 1) {
        var i: usize = 0;
        while (i < t_hfgen) : (i += 1) {
            self.X_low[k][i][0] = ch_data.W[prev_idx][i + i_f - t_hfgen][k][0];
            self.X_low[k][i][1] = ch_data.W[prev_idx][i + i_f - t_hfgen][k][1];
        }
    }
}

/// QMF 分析（时域 → W）
fn qmfAnalysis(self: *Sbr, in: []const f32, ch_data: *SbrData, num_time_slots: u32) void {
    const nb = num_time_slots * 64;
    // x 缓冲右移 288
    std.mem.copyForwards(f32, ch_data.analysis_filterbank_samples[0 .. ANA_BUF_SIZE - nb], ch_data.analysis_filterbank_samples[nb..ANA_BUF_SIZE]);
    @memcpy(ch_data.analysis_filterbank_samples[288 .. 288 + nb], in[0..nb]);
    var x_off: usize = 0;
    var i: usize = 0;
    while (i < num_time_slots * 2) : (i += 1) {
        var z: [320]f32 = undefined;
        var zz: [320]f32 = undefined;
        // vector_fmul_reverse(z, window, x, 320)：z[k]=window[k]*x[319-k]
        const xbuf = ch_data.analysis_filterbank_samples[x_off .. x_off + 320];
        vecFmulReverse(&zz, &st.sbr_qmf_window_ds, xbuf, 320);
        @memcpy(z[0..320], zz[0..320]);
        sum64x5(&z);
        qmfPreShuffle(&z);
        // MDCT：输入 z[64..128]，输出 z[0..64]
        var out: [64]f32 = undefined;
        var scratch: [32]mdct_mod.Mdct(f32).Cplx = undefined;
        self.mdct_ana.transform(&out, z[64..128], &scratch);
        @memcpy(z[0..64], out[0..64]);
        qmfPostShuffle(&ch_data.W[@intCast(ch_data.Ypos)][i], z[0..64]);
        x_off += 32;
    }
}

/// QMF 合成（X → 时域）
fn qmfSynthesis(self: *Sbr, out: []f32, X: *const [2][38][64]f32, ch_data: *SbrData, num_time_slots: u32, div: u32) void {
    const window: []const f32 = if (div != 0) &st.sbr_qmf_window_ds else &st.sbr_qmf_window_us;
    const step: usize = @as(usize, 128) >> @intCast(div);
    var v_off: i32 = ch_data.synthesis_filterbank_samples_offset;
    var out_off: usize = 0;
    var i: usize = 0;
    while (i < num_time_slots * 2) : (i += 1) {
        var v0 = &ch_data.synthesis_filterbank_samples;
        if (v_off < @as(i32, @intCast(step))) {
            const saved_samples: usize = @as(usize, 1280 - 128) >> @intCast(div);
            @memcpy(v0[SYN_BUF_SIZE - saved_samples ..][0..saved_samples], v0[0..saved_samples]);
            v_off = @as(i32, @intCast(SYN_BUF_SIZE - saved_samples - step));
        } else {
            v_off -= @as(i32, @intCast(step));
        }
        const voff: usize = @intCast(v_off);
        var mdct_buf: [2][64]f32 = undefined;
        if (div != 0) {
            var Xrow: [64]f32 = undefined;
            for (0..32) |n| {
                Xrow[n] = -X[0][i][n];
                Xrow[32 + n] = X[1][i][31 - n];
            }
            var scratch: [32]mdct_mod.Mdct(f32).Cplx = undefined;
            self.mdct.transform(mdct_buf[0][0..64], &Xrow, &scratch);
            qmfDeintNeg(v0[voff..][0..64], &mdct_buf[0]);
        } else {
            var X1: [64]f32 = undefined;
            @memcpy(X1[0..64], X[1][i][0..64]);
            negOdd64(&X1);
            var scratch: [32]mdct_mod.Mdct(f32).Cplx = undefined;
            self.mdct.transform(mdct_buf[0][0..64], X[0][i][0..64], &scratch);
            self.mdct.transform(mdct_buf[1][0..64], X1[0..64], &scratch);
            qmfDeintBfly(v0[voff..][0..128], &mdct_buf[1], &mdct_buf[0]);
        }
        // 10 段窗口累加
        const n: usize = @as(usize, 64) >> @intCast(div);
        var o: [64]f32 = undefined;
        vecFmul(o[0..n], v0[voff..][0..n], window[0..n], n);
        vecFmulAdd(o[0..n], v0[voff + (@as(usize, 192) >> @intCast(div))..][0..n], window[(@as(usize, 64) >> @intCast(div))..][0..n], o[0..n], n);
        vecFmulAdd(o[0..n], v0[voff + (@as(usize, 256) >> @intCast(div))..][0..n], window[(@as(usize, 128) >> @intCast(div))..][0..n], o[0..n], n);
        vecFmulAdd(o[0..n], v0[voff + (@as(usize, 448) >> @intCast(div))..][0..n], window[(@as(usize, 192) >> @intCast(div))..][0..n], o[0..n], n);
        vecFmulAdd(o[0..n], v0[voff + (@as(usize, 512) >> @intCast(div))..][0..n], window[(@as(usize, 256) >> @intCast(div))..][0..n], o[0..n], n);
        vecFmulAdd(o[0..n], v0[voff + (@as(usize, 704) >> @intCast(div))..][0..n], window[(@as(usize, 320) >> @intCast(div))..][0..n], o[0..n], n);
        vecFmulAdd(o[0..n], v0[voff + (@as(usize, 768) >> @intCast(div))..][0..n], window[(@as(usize, 384) >> @intCast(div))..][0..n], o[0..n], n);
        vecFmulAdd(o[0..n], v0[voff + (@as(usize, 960) >> @intCast(div))..][0..n], window[(@as(usize, 448) >> @intCast(div))..][0..n], o[0..n], n);
        vecFmulAdd(o[0..n], v0[voff + (@as(usize, 1024) >> @intCast(div))..][0..n], window[(@as(usize, 512) >> @intCast(div))..][0..n], o[0..n], n);
        vecFmulAdd(o[0..n], v0[voff + (@as(usize, 1216) >> @intCast(div))..][0..n], window[(@as(usize, 576) >> @intCast(div))..][0..n], o[0..n], n);
        @memcpy(out[out_off .. out_off + n], o[0..n]);
        out_off += n;
    }
    ch_data.synthesis_filterbank_samples_offset = v_off;
}

/// sbr_mapping
fn sbrMapping(self: *Sbr, ch_data: *SbrData, e_a: *const [2]i32) bool {
    @memset(ch_data.s_indexmapped[1][0..7], 0);
    var e: u32 = 0;
    while (e < ch_data.bs_num_env) : (e += 1) {
        const ilim = self.n[ch_data.bs_freq_res[e + 1]];
        const table: []const u16 = if (ch_data.bs_freq_res[e + 1] != 0) &self.f_tablehigh else &self.f_tablelow;
        if (self.kx[1] != table[0]) {
            self.turnoff();
            return false;
        }
        var i: u32 = 0;
        while (i < ilim) : (i += 1) {
            var m: u32 = table[i];
            while (m < table[i + 1]) : (m += 1) {
                self.e_origmapped[e][m - self.kx[1]] = ch_data.env_facs[e + 1][i];
            }
        }
        const k: u32 = @intFromBool(ch_data.bs_num_noise > 1 and ch_data.t_env[e] >= ch_data.t_q[1]);
        i = 0;
        while (i < self.n_q) : (i += 1) {
            var m: u32 = self.f_tablenoise[i];
            while (m < self.f_tablenoise[i + 1]) : (m += 1) {
                self.q_mapped[e][m - self.kx[1]] = ch_data.noise_facs[k + 1][i];
            }
        }
        i = 0;
        while (i < self.n[1]) : (i += 1) {
            if (ch_data.bs_add_harmonic_flag != 0) {
                const m_midpoint = (self.f_tablehigh[i] + self.f_tablehigh[i + 1]) >> 1;
                const idx = m_midpoint - self.kx[1];
                const prev_cond: u32 = @as(u32, @intFromBool(@as(i32, @intCast(e)) >= e_a[1] or ch_data.s_indexmapped[0][idx] == 1));
                ch_data.s_indexmapped[e + 1][idx] = ch_data.bs_add_harmonic[i] * @as(u8, @intCast(prev_cond));
            }
        }
        i = 0;
        while (i < ilim) : (i += 1) {
            var additional_sinusoid_present: u8 = 0;
            var m: u32 = table[i];
            while (m < table[i + 1]) : (m += 1) {
                if (ch_data.s_indexmapped[e + 1][m - self.kx[1]] != 0) {
                    additional_sinusoid_present = 1;
                    break;
                }
            }
            @memset(self.s_mapped[e][table[i] - self.kx[1] ..][0 .. table[i + 1] - table[i]], additional_sinusoid_present);
        }
    }
    @memcpy(ch_data.s_indexmapped[0][0..48], ch_data.s_indexmapped[ch_data.bs_num_env][0..48]);
    return true;
}

/// sbr_env_estimate
fn sbrEnvEstimate(self: *Sbr, ch_data: *SbrData) void {
    const kx1 = self.kx[1];
    if (self.bs_interpol_freq != 0) {
        var e: u32 = 0;
        while (e < ch_data.bs_num_env) : (e += 1) {
            const recip_env_size: f32 = 0.5 / @as(f32, @floatFromInt(ch_data.t_env[e + 1] - ch_data.t_env[e]));
            const ilb: usize = @as(usize, ch_data.t_env[e]) * 2 + ENV_OFF;
            const iub: usize = @as(usize, ch_data.t_env[e + 1]) * 2 + ENV_OFF;
            if (ilb >= 40) return;
            var m: u32 = 0;
            while (m < self.m[1]) : (m += 1) {
                // 对齐 ffmpeg sbr_env_estimate：用 sum_square（特定累加顺序）
                const seg: []const f32 = @as([*]const f32, @ptrCast(&self.X_high[m + kx1][ilb][0]))[0 .. 2 * (iub - ilb)];
                const sum: f32 = sumSquare(seg, iub - ilb);
                self.e_curr[e][m] = sum * recip_env_size;
            }
        }
    } else {
        var e: u32 = 0;
        while (e < ch_data.bs_num_env) : (e += 1) {
            const env_size = 2 * (ch_data.t_env[e + 1] - ch_data.t_env[e]);
            const ilb: usize = @as(usize, ch_data.t_env[e]) * 2 + ENV_OFF;
            const iub: usize = @as(usize, ch_data.t_env[e + 1]) * 2 + ENV_OFF;
            if (ilb >= 40) return;
            const table: []const u16 = if (ch_data.bs_freq_res[e + 1] != 0) &self.f_tablehigh else &self.f_tablelow;
            var p: u32 = 0;
            while (p < self.n[ch_data.bs_freq_res[e + 1]]) : (p += 1) {
                var sum: f32 = 0;
                const den = env_size * (table[p + 1] - table[p]);
                var k: u32 = table[p];
                while (k < table[p + 1]) : (k += 1) {
                    var t: usize = ilb;
                    while (t < iub) : (t += 1) {
                        const re = self.X_high[k][t][0];
                        const im = self.X_high[k][t][1];
                        sum += re * re + im * im;
                    }
                }
                sum /= @as(f32, @floatFromInt(den));
                k = table[p];
                while (k < table[p + 1]) : (k += 1) {
                    self.e_curr[e][k - kx1] = sum;
                }
            }
        }
    }
}

/// sbr_gain_calc
fn sbrGainCalc(self: *Sbr, ch_data: *SbrData, e_a: *const [2]i32) void {
    var e: u32 = 0;
    while (e < ch_data.bs_num_env) : (e += 1) {
        const delta: u32 = @as(u32, @intFromBool(!(@as(i32, @intCast(e)) == e_a[1] or @as(i32, @intCast(e)) == e_a[0])));
        var k: u32 = 0;
        while (k < self.n_lim) : (k += 1) {
            var sum: [2]f32 = .{ 0, 0 };
            var m: u32 = self.f_tablelim[k] - self.kx[1];
            while (m < self.f_tablelim[k + 1] - self.kx[1]) : (m += 1) {
                const temp = self.e_origmapped[e][m] / (1.0 + self.q_mapped[e][m]);
                self.q_m[e][m] = @sqrt(temp * self.q_mapped[e][m]);
                self.s_m[e][m] = @sqrt(temp * @as(f32, @floatFromInt(ch_data.s_indexmapped[e + 1][m])));
                if (self.s_mapped[e][m] == 0) {
                    self.gain[e][m] = @sqrt(self.e_origmapped[e][m] / ((1.0 + self.e_curr[e][m]) * (1.0 + self.q_mapped[e][m] * @as(f32, @floatFromInt(delta)))));
                } else {
                    self.gain[e][m] = @sqrt(self.e_origmapped[e][m] * self.q_mapped[e][m] / ((1.0 + self.e_curr[e][m]) * (1.0 + self.q_mapped[e][m])));
                }
                self.gain[e][m] += 1.1754943508222875e-38;
            }
            m = self.f_tablelim[k] - self.kx[1];
            while (m < self.f_tablelim[k + 1] - self.kx[1]) : (m += 1) {
                sum[0] += self.e_origmapped[e][m];
                sum[1] += self.e_curr[e][m];
            }
            var gain_max = limgain[self.bs_limiter_gains] * @sqrt((1.1920928955078125e-07 + sum[0]) / (1.1920928955078125e-07 + sum[1]));
            gain_max = @min(100000.0, gain_max);
            m = self.f_tablelim[k] - self.kx[1];
            while (m < self.f_tablelim[k + 1] - self.kx[1]) : (m += 1) {
                const q_m_max = self.q_m[e][m] * gain_max / self.gain[e][m];
                self.q_m[e][m] = @min(self.q_m[e][m], q_m_max);
                self.gain[e][m] = @min(self.gain[e][m], gain_max);
            }
            sum[0] = 0;
            sum[1] = 0;
            m = self.f_tablelim[k] - self.kx[1];
            while (m < self.f_tablelim[k + 1] - self.kx[1]) : (m += 1) {
                sum[0] += self.e_origmapped[e][m];
                sum[1] += self.e_curr[e][m] * self.gain[e][m] * self.gain[e][m] + self.s_m[e][m] * self.s_m[e][m] + @as(f32, @floatFromInt(@intFromBool(delta != 0 and self.s_m[e][m] == 0))) * self.q_m[e][m] * self.q_m[e][m];
            }
            var gain_boost = @sqrt((1.1920928955078125e-07 + sum[0]) / (1.1920928955078125e-07 + sum[1]));
            gain_boost = @min(1.584893192, gain_boost);
            m = self.f_tablelim[k] - self.kx[1];
            while (m < self.f_tablelim[k + 1] - self.kx[1]) : (m += 1) {
                self.gain[e][m] *= gain_boost;
                self.q_m[e][m] *= gain_boost;
                self.s_m[e][m] *= gain_boost;
            }
        }
    }
}

/// sbr_hf_apply_noise（4 变体）。noise 为调用方（sbrHfAssemble）的
/// 运行噪声索引（每时隙 +m_max 推进），本函数内部仅推进局部副本，
/// 不写回 ch_data（对齐 ffmpeg hf_apply_noise 语义）。
fn hfApplyNoise(self: *Sbr, ch_data: *SbrData, e: u32, i: usize, kx: u32, m_max: u32, indexsine: u32, noise_in: u32, q_filt_in: []const f32) void {
    const s_m = &self.s_m[e];
    const q_filt = q_filt_in;
    const phi_sign0: f32 = switch (indexsine) {
        0 => 1.0,
        1 => 0.0,
        2 => -1.0,
        else => 0.0,
    };
    // 变体 1/3 的虚部符号基线 = 1 - 2*(kx&1)
    const phi_base: f32 = 1.0 - 2.0 * @as(f32, @floatFromInt(kx & 1));
    const phi_sign1_init: f32 = switch (indexsine) {
        0 => 0.0,
        1 => phi_base,
        2 => 0.0,
        else => -phi_base,
    };
    var noise: u32 = noise_in;
    const Y = &ch_data.Y[@intCast(ch_data.Ypos)];
    var m: u32 = 0;
    var phi_sign1: f32 = phi_sign1_init;
    while (m < m_max) : (m += 1) {
        noise = (noise + 1) & 0x1ff;
        const y0 = Y[i][kx + m][0];
        const y1 = Y[i][kx + m][1];
        var ny0 = y0;
        var ny1 = y1;
        if (s_m[m] != 0) {
            ny0 += s_m[m] * phi_sign0;
            ny1 += s_m[m] * phi_sign1;
        } else {
            ny0 += q_filt[m] * st.sbr_noise_table[2 * noise];
            ny1 += q_filt[m] * st.sbr_noise_table[2 * noise + 1];
        }
        Y[i][kx + m][0] = ny0;
        Y[i][kx + m][1] = ny1;
        phi_sign1 = -phi_sign1;
    }
}

/// sbr_hf_g_filt
fn hfGFilt(self: *Sbr, ch_data: *SbrData, i: usize, kx: u32, m_max: u32, ixh: usize, g_filt: []const f32) void {
    const Y = &ch_data.Y[@intCast(ch_data.Ypos)];
    const Xh = self.X_high;
    var m: u32 = 0;
    while (m < m_max) : (m += 1) {
        Y[i][kx + m][0] = Xh[kx + m][ixh][0] * g_filt[m];
        Y[i][kx + m][1] = Xh[kx + m][ixh][1] * g_filt[m];
    }
}

/// sbr_hf_assemble
fn sbrHfAssemble(self: *Sbr, ch_data: *SbrData, e_a: *const [2]i32) void {
    const h_SL: usize = 4 * @as(usize, @intFromBool(self.bs_smoothing_mode == 0));
    const kx = self.kx[1];
    const m_max = self.m[1];
    var indexnoise = ch_data.f_indexnoise;
    var indexsine = ch_data.f_indexsine;

    if (self.reset != 0) {
        var i: usize = 0;
        while (i < h_SL) : (i += 1) {
            const dst = i + 2 * ch_data.t_env[0];
            @memcpy(ch_data.g_temp[dst][0..@intCast(m_max)], self.gain[0][0..@intCast(m_max)]);
            @memcpy(ch_data.q_temp[dst][0..@intCast(m_max)], self.q_m[0][0..@intCast(m_max)]);
        }
    } else if (h_SL != 0) {
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            const dst = i + 2 * ch_data.t_env[0];
            const src = i + 2 * ch_data.t_env_num_env_old;
            @memcpy(ch_data.g_temp[dst][0..48], ch_data.g_temp[src][0..48]);
            @memcpy(ch_data.q_temp[dst][0..48], ch_data.q_temp[src][0..48]);
        }
    }
    var e: u32 = 0;
    while (e < ch_data.bs_num_env) : (e += 1) {
        var i: usize = 2 * ch_data.t_env[e];
        while (i < 2 * ch_data.t_env[e + 1]) : (i += 1) {
            @memcpy(ch_data.g_temp[h_SL + i][0..@intCast(m_max)], self.gain[e][0..@intCast(m_max)]);
            @memcpy(ch_data.q_temp[h_SL + i][0..@intCast(m_max)], self.q_m[e][0..@intCast(m_max)]);
        }
    }
    e = 0;
    while (e < ch_data.bs_num_env) : (e += 1) {
        var i: usize = 2 * ch_data.t_env[e];
        while (i < 2 * ch_data.t_env[e + 1]) : (i += 1) {
            var g_filt_tab: [48]f32 = undefined;
            var q_filt_tab: [48]f32 = undefined;
            var g_filt: []const f32 = undefined;
            var q_filt: []const f32 = undefined;
            if (h_SL != 0 and @as(i32, @intCast(e)) != e_a[0] and @as(i32, @intCast(e)) != e_a[1]) {
                const idx1 = i + h_SL;
                var m: usize = 0;
                while (m < m_max) : (m += 1) {
                    g_filt_tab[m] = 0;
                    q_filt_tab[m] = 0;
                    var j: usize = 0;
                    while (j <= h_SL) : (j += 1) {
                        g_filt_tab[m] += ch_data.g_temp[idx1 - j][m] * h_smooth[j];
                        q_filt_tab[m] += ch_data.q_temp[idx1 - j][m] * h_smooth[j];
                    }
                }
                g_filt = &g_filt_tab;
                q_filt = &q_filt_tab;
            } else {
                g_filt = ch_data.g_temp[i + h_SL][0..48];
                q_filt = ch_data.q_temp[i][0..48];
            }
            hfGFilt(self, ch_data, i, kx, m_max, i + ENV_OFF, g_filt);
            if (@as(i32, @intCast(e)) != e_a[0] and @as(i32, @intCast(e)) != e_a[1]) {
                hfApplyNoise(self, ch_data, e, i, kx, m_max, indexsine, indexnoise, q_filt);
            } else {
                const idx: usize = indexsine & 1;
                const A: i32 = @intCast(1 - @as(i32, @intCast((indexsine + (kx & 1)) & 2)));
                const B = (A ^ -@as(i32, @intCast(idx))) + @as(i32, @intCast(idx));
                const out = &ch_data.Y[@intCast(ch_data.Ypos)];
                const in_arr = self.s_m[e];
                var m: usize = 0;
                while (m + 1 < m_max) : (m += 2) {
                    out[i][kx + m][idx] += in_arr[m] * @as(f32, @floatFromInt(A));
                    out[i][kx + m + 1][idx] += in_arr[m + 1] * @as(f32, @floatFromInt(B));
                }
                if (m_max & 1 != 0) {
                    out[i][kx + m][idx] += in_arr[m] * @as(f32, @floatFromInt(A));
                }
            }
            indexnoise = (indexnoise + m_max) & 0x1ff;
            indexsine = (indexsine + 1) & 3;
        }
    }
    ch_data.f_indexnoise = indexnoise;
    ch_data.f_indexsine = indexsine;
}

/// sbr_x_gen
fn sbrXGen(self: *Sbr, X: *[2][38][64]f32, ch: u32, num_time_slots: u32) void {
    const ch_data = &self.data[ch];
    const i_f = num_time_slots * 2;
    const i_temp: usize = @intCast(@max(2 * @as(i32, ch_data.t_env_num_env_old) - @as(i32, @intCast(i_f)), 0));
    @memset(@as([*]f32, @ptrCast(X))[0 .. 2 * 38 * 64], 0);
    var k: u32 = 0;
    while (k < self.kx[0]) : (k += 1) {
        var i: usize = 0;
        while (i < i_temp) : (i += 1) {
            X[0][i][k] = self.X_low[k][i + ENV_OFF][0];
            X[1][i][k] = self.X_low[k][i + ENV_OFF][1];
        }
    }
    while (k < self.kx[0] + self.m[0]) : (k += 1) {
        var i: usize = 0;
        while (i < i_temp) : (i += 1) {
            X[0][i][k] = ch_data.Y[1 - @as(usize, @intCast(ch_data.Ypos))][i + i_f][k][0];
            X[1][i][k] = ch_data.Y[1 - @as(usize, @intCast(ch_data.Ypos))][i + i_f][k][1];
        }
    }
    k = 0;
    while (k < self.kx[1]) : (k += 1) {
        var i: usize = i_temp;
        while (i < 38) : (i += 1) {
            X[0][i][k] = self.X_low[k][i + ENV_OFF][0];
            X[1][i][k] = self.X_low[k][i + ENV_OFF][1];
        }
    }
    while (k < self.kx[1] + self.m[1]) : (k += 1) {
        var i: usize = i_temp;
        while (i < i_f) : (i += 1) {
            X[0][i][k] = ch_data.Y[@intCast(ch_data.Ypos)][i][k][0];
            X[1][i][k] = ch_data.Y[@intCast(ch_data.Ypos)][i][k][1];
        }
    }
}

/// 主入口：ff_aac_sbr_apply
pub fn apply(self: *Sbr, id_aac: i32, L: []f32, R: []f32, num_time_slots: u32, out_l: []f32, out_r: []f32) !void {
    if (self.start == 0) {
        // 纯上采样路径：QMF 分析 + 合成（跳过 HF）
        const nch: usize = if (id_aac == 1) 2 else 1;
        var ch: usize = 0;
        while (ch < nch) : (ch += 1) {
            const in_sig = if (ch == 0) L else R;
            const ch_data = &self.data[ch];
            qmfAnalysis(self, in_sig, ch_data, num_time_slots);
            sbrLfGen(self, ch_data, @intCast(ch_data.Ypos), num_time_slots);
            ch_data.Ypos ^= 1;
            var X: [2][38][64]f32 = undefined;
            sbrXGen(self, &X, @intCast(ch), num_time_slots);
            const out_sig = if (ch == 0) out_l else out_r;
            const div: u32 = 0;
            qmfSynthesis(self, out_sig, &X, ch_data, num_time_slots, div);
        }
        return;
    }

    if (id_aac != self.id_aac) {
        self.turnoff();
    }
    if (self.start != 0 and self.ready_for_dequant == 0) {
        self.turnoff();
    }
    if (self.kx_and_m_pushed == 0) {
        self.kx[0] = self.kx[1];
        self.m[0] = self.m[1];
    } else {
        self.kx_and_m_pushed = 0;
    }
    if (self.start != 0) {
        sbrDequant(self, id_aac);
        self.ready_for_dequant = 0;
    }
    const nch: usize = if (id_aac == 1) 2 else 1;
    var ch: usize = 0;
    while (ch < nch) : (ch += 1) {
        const in_sig = if (ch == 0) L else R;
        const ch_data = &self.data[ch];
        qmfAnalysis(self, in_sig, ch_data, num_time_slots);
        sbrLfGen(self, ch_data, @intCast(ch_data.Ypos), num_time_slots);
        ch_data.Ypos ^= 1;
        if (self.start != 0) {
            hfInverseFilter(self, self.k[0]);
            sbrChirp(self, ch_data);
            if (ch_data.bs_num_env > 0) {
                sbrHfGen(self, ch_data, &ch_data.t_env, ch_data.bs_num_env);
                if (sbrMapping(self, ch_data, &ch_data.e_a)) {
                    sbrEnvEstimate(self, ch_data);
                    sbrGainCalc(self, ch_data, &ch_data.e_a);
                    sbrHfAssemble(self, ch_data, &ch_data.e_a);
                }
            }
        }
        sbrXGen(self, &self.X_saved[ch], @intCast(ch), num_time_slots);
    }

    // PS（参数立体声）：HE-AAC v2 单声道 core → 立体声
    var out_nch = nch;
    if (self.ps_enabled and nch == 1) {
        if (self.ps.common.start != 0) {
            psmod.psApply(&self.ps, &self.X_saved[0], &self.X_saved[1], self.kx[1] + self.m[1]);
        } else {
            @memcpy(&self.X_saved[1], &self.X_saved[0]);
        }
        out_nch = 2;
    }

    // 合成（每声道）
    ch = 0;
    while (ch < out_nch) : (ch += 1) {
        const out_sig = if (ch == 0) out_l else out_r;
        const ch_data = &self.data[ch];
        const div: u32 = 0;
        qmfSynthesis(self, out_sig, &self.X_saved[ch], ch_data, num_time_slots, div);
    }
    if (out_nch == 1) {
        @memcpy(out_r[0..num_time_slots * 64], out_l[0..num_time_slots * 64]);
    }
}

test "sbr basics" {
    var s = Sbr.init();
    defer s.deinit();
    try std.testing.expectEqual(@as(u32, 0), s.n[0]);
}
