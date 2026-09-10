// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! WMA v1/v2 解码核心——逐位移植 FFmpeg libavcodec wmadec.c + wma.c（n9.0.1）。
//!
//! 覆盖：flags2 仅允许固定块长路径（bit_reservoir=0x2 / use_variable_block_len
//! =0x4 拒绝，ffmpeg 编码器从不置位，见 encode_init flags2=1）；指数可用
//! LSP（exp_vlc=0，历史文件 t.wma）或 AAC 标度因子 VLC（exp_vlc=1，ffmpeg 编码
//! 器恒为 1）；`use_noise_coding` 由 sample_rate1/bps 依 wma.c 规则导出（低码率
//! ffmpeg 可触发，本实现含噪声带/噪声表全路径）；frame_len 依
//! ff_wma_get_frame_len_bits(sr, version) 取 512/1024/2048。
//!
//! 喂入：block_align 字节 superframe；输出：每 superframe 一帧 frame_len 采样
//! × 声道（f32 交错，由调用方排布）。frame_len 2048 用 av_tx 位精确 IMDCT；
//! 1024/512 用通用数学路径（f64，误差 <1e-6，见 wma_mdct.mdctInvFullMath）。

const std = @import("std");
const Error = @import("../../error.zig").Error;
const tab = @import("wmadata.zig");
const wma_mdct = @import("wma_mdct.zig");

const BLOCK_MIN_BITS: usize = 7;
const BLOCK_MAX_BITS: usize = 11;
const BLOCK_MAX_SIZE: usize = 1 << BLOCK_MAX_BITS; // 2048
const NB_LSP_COEFS: usize = 10;
const NOISE_TAB_SIZE: usize = 8192;
const HIGH_BAND_MAX: usize = 16;

pub const Params = struct {
    version: u8, // 1|2
    channels: u8,
    sample_rate: u32,
    bit_rate: u32,
    block_align: usize,
    flags2: u16,
};

/// MSB-first 位读取（对齐 ffmpeg get_bits）
const GetBits = struct {
    buf: []const u8,
    index: usize = 0,

    fn peek(self: *const GetBits, n: usize) u32 {
        var val: u32 = 0;
        for (0..n) |bit| {
            const pos = self.index + bit;
            const byte = pos >> 3;
            const b: u32 = if (byte < self.buf.len) (self.buf[byte] >> @intCast(7 - (pos & 7))) & 1 else 0;
            val = (val << 1) | b;
        }
        return val;
    }
    fn get(self: *GetBits, n: usize) u32 {
        const v = self.peek(n);
        self.index += n;
        return v;
    }
    fn get1(self: *GetBits) u1 {
        return @intCast(self.get(1));
    }
    fn bitsLeft(self: *const GetBits) usize {
        return self.buf.len * 8 -% self.index;
    }
    fn alignToByte(self: *GetBits) void {
        self.index = (self.index + 7) & ~@as(usize, 7);
    }
};

const VlcEntry = struct { code: u32, orig: u16, bits: u8 };

const Vlc = struct {
    // 按 (bits, code) 排序
    list: []const VlcEntry,
    // len_ofs[len] = 该长度起点；len_ofs[len+1]-len_ofs[len] 为该长度条数
    len_ofs: [24]u16,

    fn build(codes: []const u32, bits: []const u8, work: *[4096]VlcEntry) Vlc {
        const n = codes.len;
        for (0..n) |i| work[i] = .{ .code = codes[i], .orig = @intCast(i), .bits = bits[i] };
        const list = work[0..n];
        std.mem.sort(VlcEntry, list, {}, struct {
            fn lt(_: void, a: VlcEntry, b: VlcEntry) bool {
                if (a.bits != b.bits) return a.bits < b.bits;
                return a.code < b.code;
            }
        }.lt);
        var len_ofs: [24]u16 = .{0} ** 24;
        var idx: usize = 0;
        var l: usize = 1;
        while (l <= 22) : (l += 1) {
            len_ofs[l] = @intCast(idx);
            while (idx < n and list[idx].bits == l) : (idx += 1) {}
        }
        len_ofs[23] = @intCast(idx);
        return .{ .list = list, .len_ofs = len_ofs };
    }
};

fn totalGainToBits(total_gain: i32) u5 {
    return if (total_gain < 15)
        13
    else if (total_gain < 32)
        12
    else if (total_gain < 40)
        11
    else if (total_gain < 45)
        10
    else
        9;
}

/// ff_wma_get_frame_len_bits：由采样率与版本决定帧长（wma_common.c）。
/// ffmpeg 编码器不置 var_block 等 decode_flags，故不传 flags。
fn frameLenBits(sr: u32, version: u8) u8 {
    if (sr <= 16000)
        return 9;
    if (sr <= 22050 or (sr <= 32000 and version == 1))
        return 10;
    return 11; // sr <= 48000（编码器上限）；version<3 一律不超 11
}

pub const WmaDec = struct {
    params: Params,
    channels: usize,
    version: u8,
    use_exp_vlc: bool = false,
    use_noise_coding: bool = false,
    noise_mult: f32 = 0.02,
    frame_len_bits: u8 = 11,
    frame_len: usize = 2048,
    block_len: usize = 2048,
    coefs_start: usize = 0,
    coefs_end: usize = 0, // = (frame_len - frame_len*9/100)
    // 指数带（固定块长单块，数组按块长 k=0 存放）
    exponent_bands: [25]usize = .{0} ** 25,
    exponent_sizes: usize = 0,
    high_band_start: usize = 0,
    exponent_high_bands: [HIGH_BAND_MAX]usize = .{0} ** HIGH_BAND_MAX,
    exponent_high_sizes: usize = 0,

    // 状态
    ms_stereo: bool = false,
    channel_coded: [2]bool = .{ false, false },
    high_band_coded: [2][HIGH_BAND_MAX]bool = .{.{false} ** HIGH_BAND_MAX} ** 2,
    high_band_values: [2][HIGH_BAND_MAX]i32 = .{.{0} ** HIGH_BAND_MAX} ** 2,
    exponents: [2][BLOCK_MAX_SIZE]f32 = .{.{0} ** BLOCK_MAX_SIZE} ** 2,
    max_exponent: [2]f32 = .{ 1.0, 1.0 },
    exponents_initialized: [2]bool = .{ false, false },
    coefs1: [2][BLOCK_MAX_SIZE]f32 = .{.{0} ** BLOCK_MAX_SIZE} ** 2,
    coefs: [2][BLOCK_MAX_SIZE]f32 = .{.{0} ** BLOCK_MAX_SIZE} ** 2,
    output: [2 * BLOCK_MAX_SIZE]f32 = .{0} ** (2 * BLOCK_MAX_SIZE),
    frame_out: [2][2 * BLOCK_MAX_SIZE]f32 = .{.{0} ** (2 * BLOCK_MAX_SIZE)} ** 2,
    mdct_scratch: [1024]wma_mdct.Cplx = undefined,

    windows: [BLOCK_MAX_SIZE]f32 = undefined,
    lsp_cos_table: [BLOCK_MAX_SIZE]f32 = undefined,
    lsp_pow_e_table: [256]f32 = undefined,
    lsp_pow_m_table1: [128]f32 = undefined,
    lsp_pow_m_table2: [128]f32 = undefined,

    noise_table: [NOISE_TAB_SIZE]f32 = undefined,
    noise_index: usize = 0,

    // run/level 查找表（按 huffman 原索引），2 组
    run_table: [2][4096]u16 = .{.{0} ** 4096} ** 2,
    level_table: [2][4096]f32 = .{.{0} ** 4096} ** 2,

    vlc_work: [2][4096]VlcEntry = undefined,
    vlc: [2]Vlc = undefined,
    expvlc_work: [4096]VlcEntry = undefined,
    expvlc: Vlc = undefined,
    pow_tab: [156]f32 = undefined,

    pub fn open(p: Params) Error!WmaDec {
        if (p.sample_rate > 50000 or p.channels > 2 or p.channels == 0) return error.UnsupportedFormat;
        if (p.sample_rate < 8000) return error.UnsupportedFormat;
        if (p.flags2 & 0x6 != 0) return error.UnsupportedFormat; // 限 reservoir/varlen 关
        if (p.bit_rate == 0) return error.UnsupportedFormat;
        var d = WmaDec{ .params = p, .channels = p.channels, .version = p.version };
        d.use_exp_vlc = (p.flags2 & 0x1) != 0;
        const flb: u8 = frameLenBits(p.sample_rate, p.version);
        d.frame_len_bits = flb;
        d.frame_len = @as(usize, 1) << @intCast(flb);
        d.block_len = d.frame_len;
        d.coefs_start = if (p.version == 1) 3 else 0;
        d.coefs_end = d.frame_len - (d.frame_len * 9) / 100;
        d.initRateParams(); // use_noise_coding/high_freq/noise_table
        d.initBands();
        d.initCoefVlc();
        d.initExpVlc();
        d.initWindow();
        d.initLsp();
        return d;
    }

    /// wma.c ff_wma_init 的采样率相关部分：use_noise_coding、high_freq、噪声表。
    fn initRateParams(self: *WmaDec) void {
        const p = self.params;
        // sample_rate1：仅 version 2 归一化（用于 high_freq/noise 判定）
        var sample_rate1 = p.sample_rate;
        if (self.version == 2) {
            if (sample_rate1 >= 44100)
                sample_rate1 = 44100
            else if (sample_rate1 >= 22050)
                sample_rate1 = 22050
            else if (sample_rate1 >= 16000)
                sample_rate1 = 16000
            else if (sample_rate1 >= 11025)
                sample_rate1 = 11025
            else
                sample_rate1 = 8000;
        }
        var high_freq: f64 = @as(f64, @floatFromInt(p.sample_rate)) * 0.5;
        const bps: f64 = @as(f64, @floatFromInt(p.bit_rate)) / @as(f64, @floatFromInt(p.channels * p.sample_rate));
        var bps1 = bps;
        if (p.channels == 2) bps1 = bps * 1.6;

        var use_noise: bool = true;
        if (sample_rate1 == 44100) {
            if (bps1 >= 0.61)
                use_noise = false
            else
                high_freq *= 0.4;
        } else if (sample_rate1 == 22050) {
            if (bps1 >= 1.16)
                use_noise = false
            else if (bps1 >= 0.72)
                high_freq *= 0.7
            else
                high_freq *= 0.6;
        } else if (sample_rate1 == 16000) {
            if (bps > 0.5)
                high_freq *= 0.5
            else
                high_freq *= 0.3;
        } else if (sample_rate1 == 11025) {
            high_freq *= 0.7;
        } else if (sample_rate1 == 8000) {
            if (bps <= 0.625)
                high_freq *= 0.5
            else if (bps > 0.75)
                use_noise = false
            else
                high_freq *= 0.65;
        } else {
            // version 1 未归一化的 32000/48000/… 等落入 else（wma.c 无此分支特化）
            if (bps >= 0.8)
                high_freq *= 0.75
            else if (bps >= 0.6)
                high_freq *= 0.6
            else
                high_freq *= 0.5;
        }
        self.use_noise_coding = use_noise;

        // high_band_start[k]（固定单块 k=0）
        const bl = self.block_len;
        self.high_band_start = @intFromFloat(@round((@as(f64, @floatFromInt(bl)) * 2.0 * high_freq) / @as(f64, @floatFromInt(p.sample_rate))));

        if (use_noise) {
            self.noise_mult = if (self.use_exp_vlc) 0.02 else 0.04;
            const norm: f64 = (1.0 / @as(f64, @floatFromInt(@as(u64, 1) << 31))) * @sqrt(3.0) * self.noise_mult;
            var seed: u32 = 1;
            for (&self.noise_table) |*nt| {
                seed = seed *% 314159 +% 1;
                const signed: i32 = @bitCast(seed);
                nt.* = @floatCast(@as(f64, @floatFromInt(signed)) * norm);
            }
        }
    }

    fn initBands(self: *WmaDec) void {
        const p = self.params;
        const frame_len: usize = self.frame_len;
        const block_len = frame_len;
        const sr = p.sample_rate;

        if (self.version == 1) {
            // wma.c version==1：直接由临界频带计算（写 exponent_bands[0]）
            var lpos: usize = 0;
            var i: usize = 0;
            while (i < 25) : (i += 1) {
                const cf: usize = tab.ff_wma_critical_freqs[i];
                const pos: usize = ((block_len * 2 * cf) + (sr >> 1)) / sr;
                var posc = pos;
                if (posc > block_len) posc = block_len;
                self.exponent_bands[i] = posc - lpos;
                if (posc >= block_len) {
                    i += 1;
                    break;
                }
                lpos = posc;
            }
            self.exponent_sizes = i;
        } else {
            // v2：优先硬编码表（a<3 且 sr 足够高），否则临界频带 fallback
            const a: i32 = @as(i32, @intCast(self.frame_len_bits)) - @as(i32, @intCast(BLOCK_MIN_BITS));
            var used = false;
            if (a < 3) {
                if (sr >= 44100) {
                    const counts = &tab.exponent_band_count_44100;
                    const rows = &tab.exponent_band_44100;
                    if (counts[@intCast(a)] > 0) {
                        const n = counts[@intCast(a)];
                        for (0..n) |i| self.exponent_bands[i] = rows[@intCast(a)][i];
                        self.exponent_sizes = n;
                        used = true;
                    }
                } else if (sr >= 32000) {
                    const counts = &tab.exponent_band_count_32000;
                    const rows = &tab.exponent_band_32000;
                    const n = counts[@intCast(a)];
                    for (0..n) |i| self.exponent_bands[i] = rows[@intCast(a)][i];
                    self.exponent_sizes = n;
                    used = true;
                } else if (sr >= 22050) {
                    const counts = &tab.exponent_band_count_22050;
                    const rows = &tab.exponent_band_22050;
                    const n = counts[@intCast(a)];
                    for (0..n) |i| self.exponent_bands[i] = rows[@intCast(a)][i];
                    self.exponent_sizes = n;
                    used = true;
                }
            }
            if (!used) {
                var j: usize = 0;
                var lpos: usize = 0;
                for (0..25) |i| {
                    const cf: usize = tab.ff_wma_critical_freqs[i];
                    const pos0 = ((block_len * 2 * cf) + (sr << 1)) / (4 * sr);
                    var pos = pos0 << 2;
                    if (pos > block_len) pos = block_len;
                    if (pos > lpos) {
                        self.exponent_bands[j] = pos - lpos;
                        j += 1;
                    }
                    if (pos >= block_len) break;
                    lpos = pos;
                }
                self.exponent_sizes = j;
            }
        }

        // high band 覆盖（wma.c：start/end 夹到 [high_band_start, coefs_end]）
        var jj: usize = 0;
        var pos2: usize = 0;
        for (0..self.exponent_sizes) |i| {
            var start = pos2;
            pos2 += self.exponent_bands[i];
            var end = pos2;
            if (start < self.high_band_start) start = self.high_band_start;
            if (end > self.coefs_end) end = self.coefs_end;
            if (end > start) {
                self.exponent_high_bands[jj] = end - start;
                jj += 1;
            }
        }
        self.exponent_high_sizes = jj;
    }

    fn initExpVlc(self: *WmaDec) void {
        self.expvlc = Vlc.build(&tab.ff_aac_scalefactor_code, &tab.ff_aac_scalefactor_bits, &self.expvlc_work);
        for (tab.pow_tab_bits, 0..) |bitsv, i| self.pow_tab[i] = @bitCast(bitsv);
    }

    // 注意：ff_wma_hgain_hufftab 只含 {symbol,length} 无码字；ffmpeg 编码器从不置
    // 高带噪声编码位（encode_block 恒写 high_band_coded=0），因此本实现遇到高带被
    // 噪声编码即 UnsupportedFormat（不实现 hgain VLC 也能对 ffmpeg 产物保持同步）。

    /// 谱系数 Huffman VLC 与 run/level 表统一按 coef_vlc_table 选择（wma.c）：
    /// ms=false → coef[2T]，ms=true → coef[2T+1]（VLC 码字与 run/level 同源）。
    fn initCoefVlc(self: *WmaDec) void {
        const sr = self.params.sample_rate;
        const ch: usize = self.channels;
        const bps: f32 = @as(f32, @floatFromInt(self.params.bit_rate)) / @as(f32, @floatFromInt(ch * sr));
        var bps1 = bps;
        if (ch == 2) bps1 = bps * 1.6;
        var coef_vlc_table: usize = 2;
        if (sr >= 32000) {
            if (bps1 < 0.72)
                coef_vlc_table = 0
            else if (bps1 < 1.16)
                coef_vlc_table = 1;
        }
        const bits_of = [6][]const u8{
            &tab.coef0_huffbits, &tab.coef1_huffbits, &tab.coef2_huffbits,
            &tab.coef3_huffbits, &tab.coef4_huffbits, &tab.coef5_huffbits,
        };
        const codes_of = [6][]const u32{
            &tab.coef0_huffcodes, &tab.coef1_huffcodes, &tab.coef2_huffcodes,
            &tab.coef3_huffcodes, &tab.coef4_huffcodes, &tab.coef5_huffcodes,
        };
        for (0..2) |msidx| {
            const tbl: usize = 2 * coef_vlc_table + msidx;
            self.vlc[msidx] = Vlc.build(codes_of[tbl], bits_of[tbl], &self.vlc_work[msidx]);
            self.buildRunLevelOne(msidx, tbl);
        }
    }

    fn buildRunLevelOne(self: *WmaDec, idx: usize, tbl: usize) void {
        const codes = switch (tbl) {
            0 => &tab.coef0_huffcodes,
            1 => &tab.coef1_huffcodes,
            2 => &tab.coef2_huffcodes,
            3 => &tab.coef3_huffcodes,
            4 => &tab.coef4_huffcodes,
            5 => &tab.coef5_huffcodes,
            else => unreachable,
        };
        const levels = switch (tbl) {
            0 => &tab.levels0,
            1 => &tab.levels1,
            2 => &tab.levels2,
            3 => &tab.levels3,
            4 => &tab.levels4,
            5 => &tab.levels5,
            else => unreachable,
        };
        const n = codes.len;
        var i: usize = 2;
        var level: i32 = 1;
        var k: usize = 0;
        while (i < n) {
            const l = levels[k];
            k += 1;
            for (0..l) |j| {
                if (i >= n) break;
                self.run_table[idx][i] = @intCast(j);
                self.level_table[idx][i] = @floatFromInt(level);
                i += 1;
            }
            level += 1;
        }
    }

    fn initWindow(self: *WmaDec) void {
        const n: usize = self.frame_len;
        for (0..n) |i| {
            const arg: f32 = @floatCast((@as(f64, @floatFromInt(i)) + 0.5) * (std.math.pi / (2.0 * @as(f64, @floatFromInt(n)))));
            self.windows[i] = @sin(arg);
        }
    }

    fn initLsp(self: *WmaDec) void {
        const n: usize = self.frame_len;
        const wdel: f32 = @floatCast(std.math.pi / @as(f64, @floatFromInt(n)));
        for (0..n) |i| {
            const arg: f64 = @as(f64, @floatCast(wdel * @as(f32, @floatFromInt(i))));
            self.lsp_cos_table[i] = @floatCast(2.0 * @cos(arg));
        }
        for (0..256) |i| {
            const e: i32 = @as(i32, @intCast(i)) - 126;
            self.lsp_pow_e_table[i] = std.math.exp2(@as(f32, @floatCast(@as(f64, @floatFromInt(e)) * -0.25)));
        }
        var b: f64 = 1.0;
        var ii: i32 = 127;
        while (ii >= 0) : (ii -= 1) {
            const m: f64 = @floatFromInt(128 + ii);
            var a: f64 = m * (0.5 / 128.0);
            a = 1.0 / @sqrt(@sqrt(a));
            self.lsp_pow_m_table1[@intCast(ii)] = @floatCast(2.0 * a - b);
            self.lsp_pow_m_table2[@intCast(ii)] = @floatCast(b - a);
            b = a;
        }
    }

    fn powM14(self: *const WmaDec, x: f32) f32 {
        const u: u32 = @bitCast(x);
        const e: usize = u >> 23;
        const m: usize = (u >> (23 - 7)) & ((1 << 7) - 1);
        const t: u32 = ((u << 7) & ((1 << 23) - 1)) | (127 << 23);
        const a = self.lsp_pow_m_table1[m];
        const b = self.lsp_pow_m_table2[m];
        return self.lsp_pow_e_table[e] * (a + b * @as(f32, @bitCast(t)));
    }

    fn decodeExpLsp(self: *WmaDec, gb: *GetBits, ch: usize) void {
        var lsp: [NB_LSP_COEFS]f32 = undefined;
        for (0..NB_LSP_COEFS) |i| {
            const nbits: usize = if (i == 0 or i >= 8) 3 else 4;
            const val = gb.get(nbits);
            lsp[i] = @bitCast(tab.ff_wma_lsp_codebook[i][val]);
        }
        const n = self.block_len;
        var val_max: f32 = 0;
        for (0..n) |i| {
            var p: f32 = 0.5;
            var q: f32 = 0.5;
            const w = self.lsp_cos_table[i];
            var j: usize = 1;
            while (j < NB_LSP_COEFS) : (j += 2) {
                q *= w - lsp[j - 1];
                p *= w - lsp[j];
            }
            p *= p * (2.0 - w);
            q *= q * (2.0 + w);
            const v = p + q;
            const o = self.powM14(v);
            if (o > val_max) val_max = o;
            self.exponents[ch][i] = o;
        }
        self.max_exponent[ch] = val_max;
    }

    fn decodeExpVlc(self: *WmaDec, gb: *GetBits, ch: usize) Error!void {
        var last_exp: i32 = 36;
        var q: usize = 0;
        var max_scale: f32 = 0;
        var band: usize = 0;
        if (self.version == 1) {
            // 首个带的绝对值：get_bits(5)+10（wma.c encode_exp_vlc 镜像）
            last_exp = @as(i32, @intCast(gb.get(5))) + 10;
            const idx: i32 = last_exp + 60;
            if (idx < 0 or idx >= 156) return error.Corrupt;
            const v = self.pow_tab[@intCast(idx)];
            max_scale = v;
            const n = if (band < self.exponent_sizes) self.exponent_bands[band] else 0;
            band += 1;
            var cnt = n;
            while (cnt > 0) : (cnt -= 1) {
                self.exponents[ch][q] = v;
                q += 1;
            }
        }
        while (q < self.block_len) {
            const code: i32 = @intCast(try self.decodeExpVlcCode(gb));
            last_exp += code - 60;
            const idx: i32 = last_exp + 60;
            if (idx < 0 or idx >= 156) return error.Corrupt;
            const v = self.pow_tab[@intCast(idx)];
            if (v > max_scale) max_scale = v;
            const n: usize = if (band < self.exponent_sizes) self.exponent_bands[band] else 0;
            band += 1;
            var cnt = n;
            while (cnt > 0) : (cnt -= 1) {
                self.exponents[ch][q] = v;
                q += 1;
            }
        }
        self.max_exponent[ch] = max_scale;
    }

    fn decodeVlc(self: *WmaDec, gb: *GetBits, ms: bool) Error!usize {
        return decodeVlcT(&self.vlc[@intFromBool(ms)], gb);
    }
    fn decodeExpVlcCode(self: *WmaDec, gb: *GetBits) Error!usize {
        return decodeVlcT(&self.expvlc, gb);
    }
    fn decodeVlcT(vl: *const Vlc, gb: *GetBits) Error!usize {
        var l: usize = 1;
        while (l <= 22) : (l += 1) {
            const start: usize = vl.len_ofs[l];
            const end: usize = vl.len_ofs[l + 1];
            if (start == end) continue;
            const val = gb.peek(l);
            var lo = start;
            var hi = end;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                if (vl.list[mid].code < val)
                    lo = mid + 1
                else
                    hi = mid;
            }
            if (lo < end and vl.list[lo].code == val) {
                gb.index += l;
                return vl.list[lo].orig;
            }
        }
        return error.Corrupt;
    }

    fn runLevelDecode(self: *WmaDec, gb: *GetBits, ms: bool, ch: usize, num_coefs: usize, coef_nb_bits: u5) Error!void {
        const block_len = self.block_len;
        const coef_mask = block_len - 1;
        const ti: usize = @intFromBool(ms); // C tindex = (ch == 1 && ms_stereo)
        var offset: usize = 0;
        while (offset < num_coefs) {
            const code = self.decodeVlc(gb, ms) catch return error.Corrupt;
            if (code > 1) {
                offset += self.run_table[ti][code];
                const signbit = gb.get1();
                const lv: u32 = @bitCast(self.level_table[ti][code]);
                const mask: u32 = if (signbit == 1) 0 else 0x80000000;
                self.coefs1[ch][offset & coef_mask] = @bitCast(lv ^ mask);
            } else if (code == 1) {
                break;
            } else {
                // escape（ff_wma_run_level_decode version==0）
                const level: i32 = @intCast(gb.get(coef_nb_bits));
                offset += gb.get(self.frame_len_bits);
                const signbit = gb.get1();
                const neg: i32 = if (signbit == 1) 0 else -1;
                self.coefs1[ch][offset & coef_mask] = @as(f32, @floatFromInt((level ^ neg) - neg));
            }
            offset += 1; // C for 循环的递增
        }
        if (offset > num_coefs) return error.Corrupt;
    }

    fn totalGainLoop(gb: *GetBits) Error!i32 {
        var total_gain: i32 = 1;
        while (true) {
            if (gb.bitsLeft() < 7) return error.Corrupt;
            const a: i32 = @intCast(gb.get(7));
            total_gain += a;
            if (a != 127) break;
        }
        return total_gain;
    }

    /// wmadec.c wma_decode_block：固定块长（block_len_bits==frame_len_bits）。
    fn decodeBlock(self: *WmaDec, gb: *GetBits) Error!void {
        const channels = self.channels;
        self.block_len = self.frame_len;
        const block_len = self.block_len;

        if (channels == 2) self.ms_stereo = (gb.get1() != 0);
        var any_coded: bool = false;
        for (0..channels) |ch| {
            const a = (gb.get1() != 0);
            self.channel_coded[ch] = a;
            any_coded = any_coded or a;
        }

        var nb_coefs: [2]usize = .{ 0, 0 };
        var total_gain: i32 = 1;
        if (any_coded) {
            total_gain = try totalGainLoop(gb);
            const coef_nb_bits: u5 = totalGainToBits(total_gain);
            for (0..channels) |ch| nb_coefs[ch] = self.coefs_end - self.coefs_start;

            // 噪声编码：高带标志 + 增益（wma.c use_noise_coding 分支）。
            // ffmpeg 编码器恒写 high_band_coded=0（噪声只加在解码侧低位）；若文件
            // 确有高带被噪声编码（需 hgain VLC），本实现不支持 → UnsupportedFormat。
            if (self.use_noise_coding) {
                var any_hb_coded = false;
                for (0..channels) |ch| {
                    if (self.channel_coded[ch]) {
                        const n = self.exponent_high_sizes;
                        for (0..n) |i| {
                            const a = (gb.get1() != 0);
                            self.high_band_coded[ch][i] = a;
                            if (a) {
                                nb_coefs[ch] -= self.exponent_high_bands[i];
                                any_hb_coded = true;
                            }
                        }
                    }
                }
                if (any_hb_coded) return error.UnsupportedFormat;
            }

            // 指数（固定块长 → 总是重解：block_len_bits==frame_len_bits）
            for (0..channels) |ch| {
                if (self.channel_coded[ch]) {
                    if (self.use_exp_vlc) {
                        try self.decodeExpVlc(gb, ch);
                    } else {
                        self.decodeExpLsp(gb, ch);
                    }
                    self.exponents_initialized[ch] = true;
                }
            }

            // 谱系数：RLE
            for (0..channels) |ch| {
                if (self.channel_coded[ch]) {
                    const ms = (ch == 1 and self.ms_stereo);
                    @memset(self.coefs1[ch][0..block_len], 0.0);
                    try self.runLevelDecode(gb, ms, ch, nb_coefs[ch], coef_nb_bits);
                }
                if (self.version == 1 and channels >= 2) gb.alignToByte();
            }

            // 归一化：mdct_norm = 1/(block_len/2)；v1 乘 sqrt(block_len/2)
            const n4: f32 = @as(f32, @floatFromInt(block_len / 2));
            var mdct_norm: f32 = 1.0 / n4;
            if (self.version == 1) mdct_norm *= @sqrt(n4);

            for (0..channels) |ch| {
                if (self.channel_coded[ch]) {
                    self.computeCoefs(ch, total_gain, mdct_norm, nb_coefs[ch]);
                }
            }

            if (self.ms_stereo and channels == 2 and self.channel_coded[1]) {
                if (!self.channel_coded[0]) {
                    @memset(self.coefs[0][0..block_len], 0.0);
                    self.channel_coded[0] = true;
                }
                for (0..block_len) |i| {
                    const a = self.coefs[0][i];
                    const b = self.coefs[1][i];
                    self.coefs[0][i] = a + b;
                    self.coefs[1][i] = a - b;
                }
            }
        }

        // imdct + 加窗
        for (0..channels) |ch| {
            const bl = self.block_len;
            if (self.channel_coded[ch]) {
                switch (bl) {
                    2048 => wma_mdct.mdctInvFullLen(2048, &self.coefs[ch], &self.output, &self.mdct_scratch),
                    1024 => wma_mdct.mdctInvFullMath(1024, &self.coefs[ch], &self.output),
                    512 => wma_mdct.mdctInvFullMath(512, &self.coefs[ch], &self.output),
                    else => unreachable,
                }
            } else if (!(self.ms_stereo and ch == 1)) {
                @memset(&self.output, 0.0);
            }
            const index = self.frame_len / 2 - bl / 2;
            self.wmaWindow(ch, index);
        }
    }

    /// 由 coefs1 + exponents 归一化出频谱系数（含 use_noise_coding 路径）。
    /// ffmpeg 编码文件的高带恒未噪声编码，故此处只走“噪声加在编码值上”分支
    /// （与 wmadec.c 全部 uncoded 等价：极低频噪声、主频/高带 coded+noise、
    /// 极高频纯噪声）。
    fn computeCoefs(self: *WmaDec, ch: usize, total_gain: i32, mdct_norm: f32, nb_coefs: usize) void {
        const block_len = self.block_len;
        const mult_base: f32 = @as(f32, @floatCast(@exp2(@log2(10.0) * (@as(f64, @floatFromInt(total_gain)) * 0.05)))) / self.max_exponent[ch];
        const mult = mult_base * mdct_norm;
        var out: usize = 0;

        if (self.use_noise_coding) {
            // wmadec.c 噪声路径（全部高带 uncoded 时）：极低频噪声 →
            // 主频段 [coefs_start,high_band_start) + 各高带“编码值+小噪声”→ 极高频纯噪声
            for (0..self.coefs_start) |i| {
                self.coefs[ch][out] = self.noise_table[self.noise_index & (NOISE_TAB_SIZE - 1)] * self.exponents[ch][i] * mult;
                self.noise_index = (self.noise_index + 1) & (NOISE_TAB_SIZE - 1);
                out += 1;
            }
            const n1 = self.exponent_high_sizes;
            var eptr = self.coefs_start;
            var cptr: usize = 0;
            var j: i32 = -1;
            while (j < n1) : (j += 1) {
                const n: usize = if (j < 0) self.high_band_start - self.coefs_start else self.exponent_high_bands[@intCast(j)];
                for (0..n) |i| {
                    const noise = self.noise_table[self.noise_index & (NOISE_TAB_SIZE - 1)];
                    self.noise_index = (self.noise_index + 1) & (NOISE_TAB_SIZE - 1);
                    self.coefs[ch][out] = (self.coefs1[ch][cptr] + noise) * self.exponents[ch][eptr + i] * mult;
                    cptr += 1;
                    out += 1;
                }
                eptr += n;
            }
            // 极高频 [coefs_end, block_len)：纯噪声（mult × exp[eptr-1]）
            const n_tail = block_len - self.coefs_end;
            const mult_tail = mult * self.exponents[ch][eptr -% 1];
            for (0..n_tail) |i| {
                _ = i;
                self.coefs[ch][out] = self.noise_table[self.noise_index & (NOISE_TAB_SIZE - 1)] * mult_tail;
                self.noise_index = (self.noise_index + 1) & (NOISE_TAB_SIZE - 1);
                out += 1;
            }
            return;
        }

        // 无噪声：coefs1 × exp × mult（经典路径；谱位置从 coefs_start 起）
        for (0..self.coefs_start) |i| self.coefs[ch][i] = 0.0;
        for (0..nb_coefs) |i| {
            self.coefs[ch][self.coefs_start + i] = self.coefs1[ch][i] * self.exponents[ch][i] * mult;
        }
        const tail = block_len - self.coefs_end;
        for (0..tail) |i| self.coefs[ch][self.coefs_end + i] = 0.0;
    }

    /// wma_window(s, out=frame_out[ch]+index)；固定块长单块。
    fn wmaWindow(self: *WmaDec, ch: usize, index: usize) void {
        const block_len = self.block_len;
        const out = &self.frame_out[ch];
        for (0..block_len) |i| {
            out[index + i] = self.output[i] * self.windows[i] + out[index + i];
        }
        for (0..block_len) |i| {
            out[index + block_len + i] = self.output[block_len + i] * self.windows[block_len - 1 - i];
        }
    }

    /// 每声道每帧样本数（frame_len）。
    pub fn samplesPerFrame(self: *const WmaDec) usize {
        return self.frame_len;
    }

    /// 解码 1 个 superframe → 1 帧（frame_len 采样/声道），写入交错 out。
    /// out 容量须 ≥ channels*frame_len。
    pub fn decodeSuperframe(self: *WmaDec, buf: []const u8, out: []f32) Error!usize {
        if (buf.len < self.params.block_align) return error.Corrupt;
        const size = self.params.block_align;
        const fl = self.frame_len;
        var padded: [2 * BLOCK_MAX_SIZE + 64]u8 = undefined;
        const n = @min(size, padded.len);
        @memcpy(padded[0..n], buf[0..n]);
        @memset(padded[n..], 0);
        var gb = GetBits{ .buf = padded[0..n] };

        self.channel_coded = .{ false, false };
        self.exponents_initialized = .{ false, false };
        self.ms_stereo = false;

        try self.decodeBlock(&gb);

        for (0..self.channels) |ch| {
            @memcpy(out[ch * fl ..][0..fl], self.frame_out[ch][0..fl]);
            std.mem.copyForwards(f32, self.frame_out[ch][0..fl], self.frame_out[ch][fl .. 2 * fl]);
        }
        return fl * self.channels;
    }

    /// EOF：输出 frame_out 剩余（重叠尾）
    pub fn flush(self: *WmaDec, out: []f32) void {
        const fl = self.frame_len;
        for (0..self.channels) |ch| {
            @memcpy(out[ch * fl ..][0..fl], self.frame_out[ch][0..fl]);
        }
    }
};

const testing = std.testing;

fn mkParams(v: u8, ch: u8, sr: u32, kbps: u32) Params {
    // block_align 取约值即可（open 不解析内容）
    const br = kbps * 1000;
    const ba: usize = @max(64, (br * 2048) / (sr * 8));
    return .{ .version = v, .channels = ch, .sample_rate = sr, .bit_rate = br, .block_align = ba, .flags2 = 1 };
}

test "frameLenBits 依采样率/版本（ff_wma_get_frame_len_bits）" {
    // wmav2
    try testing.expectEqual(@as(u8, 11), frameLenBits(48000, 2));
    try testing.expectEqual(@as(u8, 11), frameLenBits(44100, 2));
    try testing.expectEqual(@as(u8, 11), frameLenBits(32000, 2));
    try testing.expectEqual(@as(u8, 10), frameLenBits(22050, 2));
    try testing.expectEqual(@as(u8, 9), frameLenBits(16000, 2));
    try testing.expectEqual(@as(u8, 9), frameLenBits(11025, 2));
    try testing.expectEqual(@as(u8, 9), frameLenBits(8000, 2));
    // wmav1（32000/22050 → 10）
    try testing.expectEqual(@as(u8, 11), frameLenBits(44100, 1));
    try testing.expectEqual(@as(u8, 10), frameLenBits(32000, 1));
    try testing.expectEqual(@as(u8, 10), frameLenBits(22050, 1));
    try testing.expectEqual(@as(u8, 9), frameLenBits(16000, 1));
}

test "use_noise_coding 依 sample_rate1/bps 规则（wma.c）" {
    const cases = [_]struct { v: u8, ch: u8, sr: u32, kbps: u32, fl: usize, noise: bool }{
        // wmav2（sample_rate1 归一化）
        .{ .v = 2, .ch = 1, .sr = 44100, .kbps = 48, .fl = 2048, .noise = false },
        .{ .v = 2, .ch = 1, .sr = 44100, .kbps = 24, .fl = 2048, .noise = true },
        .{ .v = 2, .ch = 1, .sr = 48000, .kbps = 96, .fl = 2048, .noise = false },
        .{ .v = 2, .ch = 2, .sr = 44100, .kbps = 32, .fl = 2048, .noise = true },
        .{ .v = 2, .ch = 1, .sr = 22050, .kbps = 24, .fl = 1024, .noise = true },
        .{ .v = 2, .ch = 1, .sr = 22050, .kbps = 64, .fl = 1024, .noise = false },
        .{ .v = 2, .ch = 1, .sr = 32000, .kbps = 24, .fl = 2048, .noise = true },
        .{ .v = 2, .ch = 1, .sr = 16000, .kbps = 96, .fl = 512, .noise = true },
        .{ .v = 2, .ch = 1, .sr = 11025, .kbps = 48, .fl = 512, .noise = true },
        .{ .v = 2, .ch = 1, .sr = 8000, .kbps = 48, .fl = 512, .noise = false },
        // wmav1（sample_rate1 不归一化；else 分支恒噪声）
        .{ .v = 1, .ch = 1, .sr = 48000, .kbps = 64, .fl = 2048, .noise = true },
        .{ .v = 1, .ch = 1, .sr = 44100, .kbps = 64, .fl = 2048, .noise = false },
        .{ .v = 1, .ch = 1, .sr = 44100, .kbps = 24, .fl = 2048, .noise = true },
        .{ .v = 1, .ch = 1, .sr = 32000, .kbps = 96, .fl = 1024, .noise = true },
        .{ .v = 1, .ch = 1, .sr = 8000, .kbps = 96, .fl = 512, .noise = false },
    };
    for (cases) |c| {
        const d = try WmaDec.open(mkParams(c.v, c.ch, c.sr, c.kbps));
        try testing.expectEqual(c.fl, d.frame_len);
        try testing.expectEqual(c.noise, d.use_noise_coding);
    }
}

test "bit_reservoir / variable_block_len flag 保持拒绝" {
    var p = mkParams(2, 1, 44100, 128);
    p.flags2 = 0x2; // use_bit_reservoir
    try testing.expectError(error.UnsupportedFormat, WmaDec.open(p));
    p.flags2 = 0x4; // use_variable_block_len
    try testing.expectError(error.UnsupportedFormat, WmaDec.open(p));
    p.flags2 = 0x1;
    _ = try WmaDec.open(p);
}
