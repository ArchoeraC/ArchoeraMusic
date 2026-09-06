// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! WMA Voice（wmavoice，ASF codec_tag 0x000A）解码核心——逐函数移植 FFmpeg
//! libavcodec/wmavoice.c（reference n9.0.1，LGPL v2.1+）。
//!
//! 帧结构（对齐 wmavoice.c）：
//!   - 每个 codec packet（block_align 字节，其自身携带 4bit 序号 + 1bit
//!     has_residual_lsps + 6bit×n superframe 计数 + spillover_bitsize bit
//!     spillover 位数）后接 1..n 个 superframe；
//!   - superframe：1bit 语音/音乐 +（可选 1bit+12bit 样本数）+（可选全局残差
//!     LSP）+ 3×frame（每帧 160 样本）；frame 头 VLC（帧型 0..16）+ 基音 +
//!     激励（ACB + 固定码本 / 硬编码 / 噪声），随后合成滤波；
//!   - do_apf=1 时每半帧（80 样本）做 APF 后处理：零输入合成 → Kalman 平滑
//!     → 重合成 → 迭代 Wiener 去噪（RDFT/DCT-I/DST-I，见 tx.zig）→ 自适应
//!     增益 → DC 滤波。
//!
//! 位读全走 bitio.zig；变换走 tx.zig；DSP 助手（滤波/lsp/插值）走 dsp.zig。
//! 输出 = 解码器内部 float（AV_SAMPLE_FMT_FLT），由接入层（lib.zig）转 s16。

const std = @import("std");
const bitio = @import("bitio.zig");
const trace = @import("trace.zig");
const tx = @import("tx.zig");
const tables = @import("tables.zig");
const dsp = @import("dsp.zig");

pub const MAX_BLOCKS = 8;
pub const MAX_LSPS = 16;
pub const MAX_FRAMES = 3;
pub const MAX_FRAMESIZE = 160;
pub const MAX_SIGNAL_HISTORY = 416;
pub const MAX_SFRAMESIZE = MAX_FRAMESIZE * MAX_FRAMES;
pub const SFRAME_CACHE_MAXSIZE = 256;

const pi: f64 = std.math.pi;

const AcbType = enum(u8) { none = 0, asymmetric = 1, hamming = 2 };
const FcbType = enum(u8) { silence = 0, hardcoded = 1, aw_pulses = 2, exc_pulses = 3 };

const FrameDesc = struct {
    n_blocks: u8,
    log_n_blocks: u8,
    acb: AcbType,
    fcb: FcbType,
    dbl_pulses: u8,
};

const frame_descs = [17]FrameDesc{
    .{ .n_blocks = 1, .log_n_blocks = 0, .acb = .none, .fcb = .silence, .dbl_pulses = 0 },
    .{ .n_blocks = 2, .log_n_blocks = 1, .acb = .none, .fcb = .hardcoded, .dbl_pulses = 0 },
    .{ .n_blocks = 2, .log_n_blocks = 1, .acb = .asymmetric, .fcb = .aw_pulses, .dbl_pulses = 0 },
    .{ .n_blocks = 2, .log_n_blocks = 1, .acb = .asymmetric, .fcb = .exc_pulses, .dbl_pulses = 2 },
    .{ .n_blocks = 2, .log_n_blocks = 1, .acb = .asymmetric, .fcb = .exc_pulses, .dbl_pulses = 5 },
    .{ .n_blocks = 4, .log_n_blocks = 2, .acb = .asymmetric, .fcb = .exc_pulses, .dbl_pulses = 0 },
    .{ .n_blocks = 4, .log_n_blocks = 2, .acb = .asymmetric, .fcb = .exc_pulses, .dbl_pulses = 2 },
    .{ .n_blocks = 4, .log_n_blocks = 2, .acb = .asymmetric, .fcb = .exc_pulses, .dbl_pulses = 5 },
    .{ .n_blocks = 2, .log_n_blocks = 1, .acb = .hamming, .fcb = .exc_pulses, .dbl_pulses = 0 },
    .{ .n_blocks = 2, .log_n_blocks = 1, .acb = .hamming, .fcb = .exc_pulses, .dbl_pulses = 2 },
    .{ .n_blocks = 2, .log_n_blocks = 1, .acb = .hamming, .fcb = .exc_pulses, .dbl_pulses = 5 },
    .{ .n_blocks = 4, .log_n_blocks = 2, .acb = .hamming, .fcb = .exc_pulses, .dbl_pulses = 0 },
    .{ .n_blocks = 4, .log_n_blocks = 2, .acb = .hamming, .fcb = .exc_pulses, .dbl_pulses = 2 },
    .{ .n_blocks = 4, .log_n_blocks = 2, .acb = .hamming, .fcb = .exc_pulses, .dbl_pulses = 5 },
    .{ .n_blocks = 8, .log_n_blocks = 3, .acb = .hamming, .fcb = .exc_pulses, .dbl_pulses = 0 },
    .{ .n_blocks = 8, .log_n_blocks = 3, .acb = .hamming, .fcb = .exc_pulses, .dbl_pulses = 2 },
    .{ .n_blocks = 8, .log_n_blocks = 3, .acb = .hamming, .fcb = .exc_pulses, .dbl_pulses = 5 },
};

/// frame_type VLC 码长（22 条）；canonical MSB 对齐分配（ff_vlc_init_from_lengths）。
const frame_type_bits = [_]u8{ 2, 2, 2, 4, 4, 4, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 14 };

const FrameVlc = struct {
    syms: [22]struct { code: u32, len: u8 },
    fn init() FrameVlc {
        var out: FrameVlc = undefined;
        var code: u64 = 0;
        for (frame_type_bits, 0..) |len, i| {
            out.syms[i].len = len;
            out.syms[i].code = @intCast(code >> (32 - len));
            code += @as(u64, 1) << @intCast(32 - len);
        }
        return out;
    }
    fn getVlc(self: *const FrameVlc, gb: *bitio.Bits) i32 {
        const maxlen: u32 = 14;
        const peeked = gb.peek(maxlen);
        var best: i32 = -1;
        var best_len: u32 = 100;
        for (&self.syms, 0..) |s, i| {
            const len: u32 = s.len;
            if (len < best_len and (peeked >> @intCast(maxlen - len)) == s.code) {
                best = @intCast(i);
                best_len = len;
            }
        }
        if (best >= 0) gb.skip(best_len);
        return best;
    }
};

const frame_vlc = FrameVlc.init();

pub const Config = struct {
    extradata: []const u8,
    sample_rate: u32,
    block_align: u32,
};

pub const Dec = struct {
    // ---- 流级参数（initCfg 期确定）----
    vbm_tree: [25]i8 = undefined,
    spillover_bitsize: u32 = 0,
    history_nsamples: usize = 0,
    do_apf: bool = false,
    denoise_strength: u32 = 0,
    denoise_tilt_corr: bool = false,
    dc_level: u32 = 0,
    lsps: usize = 0,
    lsp_q_mode: bool = false,
    lsp_def_mode: bool = false,
    min_pitch_val: i32 = 0,
    max_pitch_val: i32 = 0,
    pitch_nbits: u32 = 0,
    block_pitch_nbits: u32 = 0,
    block_pitch_range: i32 = 0,
    block_delta_pitch_nbits: u32 = 0,
    block_delta_pitch_hrange: i32 = 0,
    block_conv_table: [4]u16 = undefined,
    sample_rate: u32 = 0,
    block_align: usize = 0,

    // ---- packet 级状态 ----
    spillover_nbits: u32 = 0,
    has_residual_lsps: bool = false,
    skip_bits_next: u32 = 0,
    sframe_cache: [SFRAME_CACHE_MAXSIZE + 64]u8 = undefined,
    sframe_cache_size: i32 = 0, // bit
    nb_superframes: i32 = 0,

    // ---- 帧/superframe 级状态 ----
    prev_lsps: [MAX_LSPS]f64 = undefined,
    last_pitch_val: i32 = 0,
    last_acb_type: AcbType = .none,
    pitch_diff_sh16: i32 = 0,
    silence_gain: f32 = 0,
    aw_idx_is_ext: bool = false,
    aw_pulse_range: i32 = 0,
    aw_n_pulses: [2]i32 = undefined,
    aw_first_pulse_off: [2]i32 = undefined,
    aw_next_pulse_off_cache: i32 = 0,
    frame_cntr: i32 = 0,
    gain_pred_err: [6]f32 = undefined,
    excitation_history: [MAX_SIGNAL_HISTORY]f32 = undefined,
    synth_history: [MAX_LSPS]f32 = undefined,

    // ---- 后处理状态 ----
    sin_tab: [511]f32 = undefined,
    cos_tab: [511]f32 = undefined,
    postfilter_agc: f32 = 0,
    dcf_mem: [2]f32 = undefined,
    zero_exc_pf: [MAX_SIGNAL_HISTORY + MAX_SFRAMESIZE]f32 = undefined,
    denoise_filter_cache: [MAX_FRAMESIZE]f32 = undefined,
    denoise_filter_cache_size: i32 = 0,
    tilted_lpcs_pf: [0x82]f32 = undefined,
    denoise_coeffs_pf: [0x82]f32 = undefined,
    synth_filter_out_buf: [0x80 + MAX_LSPS]f32 = undefined,

    // ---- 输出 ----
    out_buf: [MAX_SFRAMESIZE]f32 = undefined,
    out_len: usize = 0,
    pending: bool = false,

    pub fn init(cfg: Config) Dec {
        var d = Dec{};
        d.initCfg(cfg);
        return d;
    }

    fn initCfg(self: *Dec, cfg: Config) void {
        std.debug.assert(cfg.extradata.len == 46);
        self.sample_rate = cfg.sample_rate;
        self.block_align = @intCast(cfg.block_align);
        const flags: u32 = std.mem.readInt(u32, cfg.extradata[18..22], .little);
        self.spillover_bitsize = 3 + dsp.ceilLog2(cfg.block_align);
        self.do_apf = (flags & 0x1) != 0;
        if (self.do_apf) {
            // C: ff_sine_window_init → cos[i] = sinf((i + 0.5) * (M_PI / (2.0*n)))，
            // 参数为 double 表达式先舍入到 float 再调 sinf（glibc）
            for (0..256) |i| {
                const arg: f64 = (@as(f64, @floatFromInt(i)) + 0.5) * (pi / 512.0);
                self.cos_tab[i] = dsp.sinf(@floatCast(arg));
            }
            @memcpy(self.sin_tab[255 .. 255 + 256], self.cos_tab[0..256]);
            for (0..255) |n| {
                self.sin_tab[n] = -self.sin_tab[510 - n];
                self.cos_tab[510 - n] = self.cos_tab[n];
            }
        }
        self.denoise_strength = (flags >> 2) & 0xF;
        std.debug.assert(self.denoise_strength < 12);
        self.denoise_tilt_corr = (flags & 0x40) != 0;
        self.dc_level = (flags >> 7) & 0xF;
        self.lsp_q_mode = (flags & 0x2000) != 0;
        self.lsp_def_mode = (flags & 0x4000) != 0;
        self.lsps = if ((flags & 0x1000) != 0) 16 else 10;
        for (0..self.lsps) |n| {
            self.prev_lsps[n] = pi * @as(f64, @floatFromInt(n + 1)) / @as(f64, @floatFromInt(self.lsps + 1));
        }
        @memset(self.vbm_tree[0..25], -1);
        var gb = bitio.Bits.init(cfg.extradata[22..]);
        var cntr: [8]u8 = .{0} ** 8;
        for (0..17) |n| {
            const res: usize = @intCast(gb.get(3));
            self.vbm_tree[res * 3 + cntr[res]] = @intCast(n);
            cntr[res] += 1;
        }
        self.min_pitch_val = @intCast(@divTrunc((@as(i64, self.sample_rate) << 8), 400) + 50 >> 8);
        self.max_pitch_val = @intCast(@divTrunc((@as(i64, self.sample_rate) << 8) * 37, 2000) + 50 >> 8);
        const pitch_range = self.max_pitch_val - self.min_pitch_val;
        self.pitch_nbits = dsp.ceilLog2(@intCast(@max(pitch_range, 1)));
        self.last_pitch_val = 40;
        self.last_acb_type = .none;
        self.history_nsamples = @intCast(self.max_pitch_val + 8);
        std.debug.assert(self.history_nsamples <= MAX_SIGNAL_HISTORY);
        self.block_conv_table[0] = @intCast(self.min_pitch_val);
        self.block_conv_table[1] = @intCast((pitch_range * 25) >> 6);
        self.block_conv_table[2] = @intCast((pitch_range * 44) >> 6);
        self.block_conv_table[3] = @intCast(self.max_pitch_val - 1);
        self.block_delta_pitch_hrange = (pitch_range >> 3) & ~@as(i32, 0xF);
        self.block_delta_pitch_nbits = 1 + dsp.ceilLog2(@intCast(@max(self.block_delta_pitch_hrange, 1)));
        self.block_pitch_range = self.block_conv_table[2] + self.block_conv_table[3] + 1 + 2 * (self.block_conv_table[1] - 2 * self.min_pitch_val);
        self.block_pitch_nbits = dsp.ceilLog2(@intCast(self.block_pitch_range));
        self.flush();
        trace.init();
    }

    pub fn flush(self: *Dec) void {
        self.postfilter_agc = 0;
        self.sframe_cache_size = 0;
        self.skip_bits_next = 0;
        for (0..self.lsps) |n| {
            self.prev_lsps[n] = pi * @as(f64, @floatFromInt(n + 1)) / @as(f64, @floatFromInt(self.lsps + 1));
        }
        @memset(self.excitation_history[0..MAX_SIGNAL_HISTORY], 0);
        @memset(self.synth_history[0..MAX_LSPS], 0);
        @memset(self.gain_pred_err[0..6], 0);
        if (self.do_apf) {
            const st = MAX_LSPS - self.lsps;
            @memset(self.synth_filter_out_buf[st .. st + self.lsps], 0);
            @memset(self.dcf_mem[0..2], 0);
            @memset(self.zero_exc_pf[0..self.history_nsamples], 0);
            @memset(self.denoise_filter_cache[0..MAX_FRAMESIZE], 0);
        }
        self.pending = false;
        self.out_len = 0;
    }

    // ------------------------------------------------------------------
    // 包（codec packet）解码状态机 —— 逐分支复刻 wmavoice_decode_packet。
    // 返回消费字节数（>=0）或错误码（<0）。输出帧挂 self.pending / out_buf。
    // ------------------------------------------------------------------
    pub fn decodePacket(self: *Dec, data: []const u8) i32 {
        const pkt_size: usize = data.len;
        var size: usize = pkt_size;
        while (size > self.block_align) size -= self.block_align;
        if (size == 0) {
            self.spillover_nbits = 0;
            self.nb_superframes = 0;
        }
        const sl = size;
        var gb = bitio.Bits.init(data[0..sl]);
        self.pending = false;
        self.out_len = 0;

        if (sl % self.block_align == 0) { // new codec packet
            if (sl != 0) {
                const r = self.parsePacketHeader(&gb);
                if (r < 0) return r;
                self.nb_superframes = r;
            }
            if (self.sframe_cache_size > 0) {
                var cnt: u32 = gb.count();
                if (@as(u64, cnt) + @as(u64, self.spillover_nbits) > @as(u64, pkt_size) * 8) {
                    self.spillover_nbits = @as(u32, @intCast(@as(u64, pkt_size) * 8 - @as(u64, cnt)));
                }
                self.cacheAppendBits(&gb, self.spillover_nbits);
                self.sframe_cache_size += @intCast(self.spillover_nbits);
                const res = self.synthCached();
                if (res == 0 and self.pending) {
                    cnt += self.spillover_nbits;
                    self.skip_bits_next = cnt & 7;
                    return @intCast(cnt >> 3);
                } else {
                    // resync：C 用 skip_bits_long(gb, spillover - cnt + gb.count())；
                    // 我们逐位读已前进了 spillover，故再跳 spillover 大致等效（出错路径）
                    gb.skip(self.spillover_nbits);
                }
            } else if (self.spillover_nbits > 0) {
                gb.skip(self.spillover_nbits);
            }
        } else if (self.skip_bits_next > 0) {
            gb.skip(self.skip_bits_next);
        }

        self.sframe_cache_size = 0;
        self.skip_bits_next = 0;
        @memset(self.sframe_cache[0..], 0); // 跨包缓存每次重建（C put_bits 覆盖整字节）
        const pos: i64 = gb.left();
        if (self.nb_superframes == 0) {
            self.nb_superframes -= 1;
            return @intCast(size);
        }
        self.nb_superframes -= 1;
        if (self.nb_superframes > 0) {
            const res = self.synthSuperframeGb(&gb);
            if (res < 0) return res;
            if (self.pending) {
                const cnt = gb.count();
                self.skip_bits_next = cnt & 7;
                return @intCast(cnt >> 3);
            }
        } else if (pos > 0) {
            self.sframe_cache_size = 0;
            self.cacheAppendBits(&gb, @intCast(pos));
            self.sframe_cache_size = @intCast(pos);
        }
        return @intCast(size);
    }

    fn parsePacketHeader(self: *Dec, gb: *bitio.Bits) i32 {
        gb.skip(4);
        self.has_residual_lsps = gb.get1() != 0;
        var n_superframes: u32 = 0;
        while (true) {
            if (gb.left() < @as(i64, 6) + @as(i64, self.spillover_bitsize)) return -1;
            const res = gb.get(6);
            n_superframes += res;
            if (res != 0x3F) break;
        }
        self.spillover_nbits = gb.get(self.spillover_bitsize);
        return if (gb.left() >= 0) @intCast(n_superframes) else -1;
    }

    fn cacheAppendBits(self: *Dec, gb: *bitio.Bits, nbits: u32) void {
        var n: u32 = nbits;
        while (n > 0) : (n -= 1) {
            if (self.sframe_cache_size >= SFRAME_CACHE_MAXSIZE * 8) return;
            const byte: usize = @intCast(@as(u64, @intCast(self.sframe_cache_size)) >> 3);
            const off: u3 = @intCast(self.sframe_cache_size & 7);
            const bit = gb.get(1);
            if (bit != 0) {
                self.sframe_cache[byte] |= @as(u8, 1) << @intCast(7 - @as(u3, off));
            }
            self.sframe_cache_size += 1;
        }
    }

    fn synthCached(self: *Dec) i32 {
        const nbits: u32 = @intCast(@max(self.sframe_cache_size, 0));
        var gb = bitio.Bits.initSizeBits(&self.sframe_cache, nbits);
        self.sframe_cache_size = 0;
        return self.synthSuperframeFrom(&gb);
    }
    fn synthSuperframeGb(self: *Dec, gb: *bitio.Bits) i32 {
        return self.synthSuperframeFrom(gb);
    }

    // ------------------------------------------------------------------
    // synth_superframe
    // ------------------------------------------------------------------
    fn synthSuperframeFrom(self: *Dec, gb: *bitio.Bits) i32 {
        var n_samples: usize = MAX_SFRAMESIZE;
        const mean_mode = if (self.lsp_def_mode) @as(usize, 1) else 0;
        var lsps: [MAX_FRAMES][MAX_LSPS]f64 = undefined;
        var excitation: [MAX_SIGNAL_HISTORY + MAX_SFRAMESIZE + 12]f32 = undefined;
        var synth: [MAX_LSPS + MAX_SFRAMESIZE]f32 = undefined;

        @memcpy(synth[0..self.lsps], self.synth_history[0..self.lsps]);
        @memcpy(excitation[0..self.history_nsamples], self.excitation_history[0..self.history_nsamples]);

        if (gb.get1() == 0) return -2; // WMAPro-in-WMAVoice（不支持）
        if (gb.get1() != 0) {
            const n = gb.get(12);
            if (n > MAX_SFRAMESIZE) return -1;
            n_samples = n;
        }

        if (self.has_residual_lsps) {
            var prev: [MAX_LSPS]f64 = undefined;
            var a1: [MAX_LSPS * 2]f64 = undefined;
            var a2: [MAX_LSPS * 2]f64 = undefined;
            const mean = if (self.lsps == 16) dsp_mean_lsf16(mean_mode) else dsp_mean_lsf10(mean_mode);
            for (0..self.lsps) |n| prev[n] = self.prev_lsps[n] - mean[n];
            if (self.lsps == 10) {
                var f0: [MAX_LSPS]f64 = undefined;
                self.dequantLsp10r(gb, f0[0..10], &prev, &a1, &a2, self.lsp_q_mode);
                for (0..10) |n| {
                    lsps[0][n] = mean[n] + (a1[n] - a2[n * 2]);
                    lsps[1][n] = mean[n] + (a1[10 + n] - a2[n * 2 + 1]);
                    lsps[2][n] = f0[n] + mean[n];
                }
            } else {
                var f0: [MAX_LSPS]f64 = undefined;
                self.dequantLsp16r(gb, f0[0..16], &prev, &a1, &a2, self.lsp_q_mode);
                for (0..16) |n| {
                    lsps[0][n] = mean[n] + (a1[n] - a2[n * 2]);
                    lsps[1][n] = mean[n] + (a1[16 + n] - a2[n * 2 + 1]);
                    lsps[2][n] = f0[n] + mean[n];
                }
            }
            for (0..3) |nf| dsp.stabilizeLsps(lsps[nf][0..self.lsps]);
        }

        for (0..3) |n| {
            const mean = if (self.lsps == 16) dsp_mean_lsf16(mean_mode) else dsp_mean_lsf10(mean_mode);
            if (!self.has_residual_lsps) {
                if (self.lsps == 10) {
                    self.dequantLsp10i(gb, lsps[n][0..10]);
                } else {
                    self.dequantLsp16i(gb, lsps[n][0..16]);
                }
                for (0..self.lsps) |m| lsps[n][m] += mean[m];
                dsp.stabilizeLsps(lsps[n][0..self.lsps]);
            }
            const prev: []const f64 = if (n == 0) self.prev_lsps[0..self.lsps] else lsps[n - 1][0..self.lsps];
            trace.f64s(trace.lsp_tag, lsps[n][0..self.lsps]);
            const res = self.synthFrame(gb, n, lsps[n][0..self.lsps], prev, &excitation, &synth);
            if (res != 0) {
                self.pending = false;
                return res;
            }
        }

        if (gb.get1() != 0) {
            const r = gb.get(4);
            gb.skip(10 * (r + 1));
        }
        if (gb.left() < 0) {
            self.flush();
            return -1;
        }

        @memcpy(self.prev_lsps[0..self.lsps], lsps[2][0..self.lsps]);
        @memcpy(self.synth_history[0..self.lsps], synth[MAX_SFRAMESIZE .. MAX_SFRAMESIZE + self.lsps]);
        @memcpy(self.excitation_history[0..self.history_nsamples], excitation[MAX_SFRAMESIZE .. MAX_SFRAMESIZE + self.history_nsamples]);
        if (self.do_apf) {
            std.mem.copyForwards(f32, self.zero_exc_pf[0..self.history_nsamples], self.zero_exc_pf[MAX_SFRAMESIZE .. MAX_SFRAMESIZE + self.history_nsamples]);
        }
        self.out_len = n_samples;
        self.pending = true;
        return 0;
    }

    fn synthFrame(self: *Dec, gb: *bitio.Bits, frame_idx: usize, lsps: []const f64, prev_lsps: []const f64, excitation: []f32, synth: []f32) i32 {
        var pitch: [MAX_BLOCKS]i32 = undefined;
        var cur_pitch_val: i32 = 0;
        var last_block_pitch: i32 = 0;
        const exc_base = self.history_nsamples + frame_idx * MAX_FRAMESIZE;
        const syn_base = self.lsps + frame_idx * MAX_FRAMESIZE;

        const vlc_sym = frame_vlc.getVlc(gb);
        if (vlc_sym < 0) return -1;
        const vbm = self.vbm_tree[@intCast(vlc_sym)];
        if (vbm < 0) return -1;
        const fd = frame_descs[@intCast(vbm)];
        const block_nsamples: usize = MAX_FRAMESIZE / fd.n_blocks;
        pitch[0] = std.math.maxInt(i32);

        if (fd.acb == .asymmetric) {
            const n_blocks_x2: i32 = @as(i32, fd.n_blocks) << 1;
            const log_n_blocks_x2: u32 = @as(u32, fd.log_n_blocks) + 1;
            cur_pitch_val = self.min_pitch_val + @as(i32, @intCast(gb.get(self.pitch_nbits)));
            cur_pitch_val = @min(cur_pitch_val, self.max_pitch_val - 1);
            if (self.last_acb_type == .none or
                20 * @abs(cur_pitch_val - self.last_pitch_val) > (cur_pitch_val + self.last_pitch_val))
            {
                self.last_pitch_val = cur_pitch_val;
            }
            for (0..fd.n_blocks) |nn| {
                const fac: i32 = @intCast(nn * 2 + 1);
                pitch[nn] = (fac * cur_pitch_val + (n_blocks_x2 - fac) * self.last_pitch_val + @as(i32, fd.n_blocks)) >> @intCast(log_n_blocks_x2);
            }
            self.pitch_diff_sh16 = @divTrunc((cur_pitch_val - self.last_pitch_val) * (1 << 16), @as(i32, MAX_FRAMESIZE));
        }

        switch (fd.fcb) {
            .silence => {
                self.silence_gain = tables.wmavoice_gain_silence[gb.get(8)];
            },
            .aw_pulses => {
                self.awParseCoords(gb, &pitch);
            },
            else => {},
        }

        for (0..fd.n_blocks) |nn| {
            var bl_pitch_sh2: i32 = 0;
            switch (fd.acb) {
                .hamming => {
                    const t1 = (@as(i32, self.block_conv_table[1]) - @as(i32, self.block_conv_table[0])) << 2;
                    const t2 = (@as(i32, self.block_conv_table[2]) - @as(i32, self.block_conv_table[1])) << 1;
                    const t3 = @as(i32, self.block_conv_table[3]) - @as(i32, self.block_conv_table[2]) + 1;
                    var block_pitch: i32 = undefined;
                    if (nn == 0) {
                        block_pitch = @intCast(gb.get(self.block_pitch_nbits));
                    } else {
                        block_pitch = last_block_pitch - self.block_delta_pitch_hrange + @as(i32, @intCast(gb.get(self.block_delta_pitch_nbits)));
                    }
                    last_block_pitch = dsp.clipI32(@floatFromInt(block_pitch), self.block_delta_pitch_hrange, self.block_pitch_range - self.block_delta_pitch_hrange);
                    if (block_pitch < t1) {
                        bl_pitch_sh2 = (@as(i32, self.block_conv_table[0]) << 2) + block_pitch;
                    } else {
                        block_pitch -= t1;
                        if (block_pitch < t2) {
                            bl_pitch_sh2 = (@as(i32, self.block_conv_table[1]) << 2) + (block_pitch << 1);
                        } else {
                            block_pitch -= t2;
                            if (block_pitch < t3) {
                                bl_pitch_sh2 = (@as(i32, self.block_conv_table[2]) + block_pitch) << 2;
                            } else {
                                bl_pitch_sh2 = @as(i32, self.block_conv_table[3]) << 2;
                            }
                        }
                    }
                    pitch[nn] = bl_pitch_sh2 >> 2;
                },
                .asymmetric => {
                    bl_pitch_sh2 = pitch[nn] << 2;
                },
                .none => bl_pitch_sh2 = 0,
            }
            const blk_exc = exc_base + nn * block_nsamples;
            const blk_syn = syn_base + nn * block_nsamples;
            self.synthBlock(gb, @intCast(nn), block_nsamples, bl_pitch_sh2, lsps, prev_lsps, &fd, excitation, blk_exc, synth, blk_syn);
        }

        const samples_base = frame_idx * MAX_FRAMESIZE;
        if (self.do_apf) {
            var i_lsps: [MAX_LSPS]f64 = undefined;
            var lpcs: [MAX_LSPS]f32 = undefined;
            if (fd.fcb != .silence and fd.fcb != .hardcoded and pitch[0] == std.math.maxInt(i32)) return -1;
            for (0..self.lsps) |nn| i_lsps[nn] = dsp.cosD(0.5 * (prev_lsps[nn] + lsps[nn]));
            lspd2lpcInto(&i_lsps, &lpcs, self.lsps);
            self.postfilter(synth, syn_base, samples_base, 80, &lpcs, fd.fcb, pitch[0]);
            for (0..self.lsps) |nn| i_lsps[nn] = dsp.cosD(lsps[nn]);
            lspd2lpcInto(&i_lsps, &lpcs, self.lsps);
            self.postfilter(synth, syn_base + 80, samples_base + 80, 80, &lpcs, fd.fcb, pitch[0]);
        } else {
            @memcpy(self.out_buf[samples_base .. samples_base + MAX_FRAMESIZE], synth[syn_base .. syn_base + MAX_FRAMESIZE]);
        }

        self.frame_cntr += 1;
        if (self.frame_cntr >= 0xFFFF) self.frame_cntr -= 0xFFFF;
        self.last_acb_type = fd.acb;
        switch (fd.acb) {
            .none => self.last_pitch_val = 0,
            .asymmetric => self.last_pitch_val = cur_pitch_val,
            .hamming => self.last_pitch_val = pitch[fd.n_blocks - 1],
        }
        return 0;
    }

    fn synthBlock(self: *Dec, gb: *bitio.Bits, block_idx: i32, size: usize, block_pitch_sh2: i32, lsps: []const f64, prev_lsps: []const f64, fd: *const FrameDesc, excitation: []f32, blk_exc: usize, synth: []f32, blk_syn: usize) void {
        var i_lsps: [MAX_LSPS]f64 = undefined;
        var lpcs: [MAX_LSPS]f32 = undefined;
        if (fd.acb == .none) {
            self.synthBlockHardcoded(gb, block_idx, size, fd, excitation, blk_exc);
        } else {
            self.synthBlockFcbAcb(gb, block_idx, size, block_pitch_sh2, fd, excitation, blk_exc);
        }
        const fac = (@as(f64, @floatFromInt(block_idx)) + 0.5) / @as(f64, @floatFromInt(fd.n_blocks));
        for (0..self.lsps) |nn| i_lsps[nn] = dsp.cosD(prev_lsps[nn] + fac * (lsps[nn] - prev_lsps[nn]));
        lspd2lpcInto(&i_lsps, &lpcs, self.lsps);
        trace.f32s(trace.lpcs_tag, lpcs[0..self.lsps]);
        trace.f32s(trace.exc_tag, excitation[blk_exc .. blk_exc + size]);
        dsp.celpLpSynthF(synth, blk_syn, excitation, blk_exc, lpcs[0..self.lsps], size, self.lsps);
        trace.f32s(trace.synth_tag, synth[blk_syn .. blk_syn + size]);
    }

    fn synthBlockHardcoded(self: *Dec, gb: *bitio.Bits, block_idx: i32, size: usize, fd: *const FrameDesc, excitation: []f32, blk: usize) void {
        var r_idx: usize = 0;
        var gain: f32 = 0;
        if (fd.fcb == .silence) {
            r_idx = dsp.pRng(self.frame_cntr, block_idx, size);
            gain = self.silence_gain;
        } else {
            r_idx = gb.get(8);
            gain = tables.wmavoice_gain_universal[gb.get(6)];
        }
        @memset(self.gain_pred_err[0..6], 0);
        for (0..size) |nn| excitation[blk + nn] = tables.wmavoice_std_codebook[r_idx + nn] * gain;
    }

    fn synthBlockFcbAcb(self: *Dec, gb: *bitio.Bits, block_idx: i32, size: usize, block_pitch_sh2: i32, fd: *const FrameDesc, excitation: []f32, blk: usize) void {
        const gain_coeff = [6]f32{ 0.8169, -0.06545, 0.1726, 0.0185, -0.0359, 0.0458 };
        var pulses: [MAX_FRAMESIZE / 2]f32 = undefined;
        @memset(pulses[0..size], 0);
        var fcb = dsp.AmrFixed{};
        fcb.pitch_lag = block_pitch_sh2 >> 2;
        fcb.pitch_fac = 1.0;
        fcb.no_repeat_mask = 0;

        if (fd.fcb == .aw_pulses) {
            self.awPulseSet1(gb, block_idx, &fcb);
            if (self.awPulseSet2(gb, block_idx, &fcb) != 0) {
                const r_idx = dsp.pRng(self.frame_cntr, block_idx, size);
                for (0..size) |nn| excitation[blk + nn] = tables.wmavoice_std_codebook[r_idx + nn] * self.silence_gain;
                gb.skip(8);
                return;
            }
        } else {
            const offset_nbits: u32 = 5 - fd.log_n_blocks;
            fcb.no_repeat_mask = -1;
            var n: usize = 0;
            while (n < 5) : (n += 1) {
                const sign: f32 = if (gb.get1() != 0) 1.0 else -1.0;
                const pos1: i32 = @intCast(gb.get(offset_nbits));
                fcb.x[fcb.n] = @as(i32, @intCast(n)) + 5 * pos1;
                fcb.y[fcb.n] = sign;
                fcb.n += 1;
                if (n < fd.dbl_pulses) {
                    const pos2: i32 = @intCast(gb.get(offset_nbits));
                    fcb.x[fcb.n] = @as(i32, @intCast(n)) + 5 * pos2;
                    fcb.y[fcb.n] = if (pos1 < pos2) -sign else sign;
                    fcb.n += 1;
                }
            }
        }
        dsp.setFixedVector(pulses[0..size], &fcb, 1.0);

        const idx = gb.get(7);
        var pred_err: f32 = undefined;
        var dot: f32 = 0;
        for (0..6) |k| dot += self.gain_pred_err[k] * gain_coeff[k];
        // C: expf(dot - 5.2409161640 + tbl[idx])——常量为 double，整个表达式
        // 以 double 计算后再转 float 传入 expf
        const arg: f64 = @as(f64, dot) - 5.2409161640 + @as(f64, tables.wmavoice_gain_codebook_fcb[idx]);
        trace.f64s(114, &.{arg});
        const fcb_gain = dsp.expf(@floatCast(arg));
        trace.f32s(115, &.{fcb_gain});
        const acb_gain = tables.wmavoice_gain_codebook_acb[idx];
        pred_err = dsp.clipF(tables.wmavoice_gain_codebook_fcb[idx], -2.9957322736, 1.6094379124);
        const gain_weight: usize = @as(u16, 8) >> @as(u4, @intCast(fd.log_n_blocks));
        std.mem.copyBackwards(f32, self.gain_pred_err[gain_weight .. gain_weight + (6 - gain_weight)], self.gain_pred_err[0 .. 6 - gain_weight]);
        for (0..gain_weight) |nn| self.gain_pred_err[nn] = pred_err;

        if (fd.acb == .asymmetric) {
            var n: usize = 0;
            while (n < size) {
                var next_idx_sh16: i32 = 0;
                const abs_idx = block_idx * @as(i32, @intCast(size)) + @as(i32, @intCast(n));
                const pitch_sh16 = (self.last_pitch_val << 16) + self.pitch_diff_sh16 * abs_idx;
                const pitch: i64 = (@as(i64, pitch_sh16) + 0x6FFF) >> 16;
                const idx_sh16 = ((@as(i64, pitch) << 16) - @as(i64, pitch_sh16)) * 8 + 0x58000;
                const fidx: i32 = @intCast(idx_sh16 >> 16);
                var len: usize = undefined;
                if (self.pitch_diff_sh16 != 0) {
                    if (self.pitch_diff_sh16 > 0) {
                        next_idx_sh16 = @intCast(idx_sh16 & ~@as(i64, 0xFFFF));
                    } else {
                        next_idx_sh16 = @intCast((idx_sh16 + 0x10000) & ~@as(i64, 0xFFFF));
                    }
                    const diff = @divTrunc(idx_sh16 - @as(i64, next_idx_sh16), @as(i64, self.pitch_diff_sh16) * 8);
                    len = @intCast(dsp.clipI64(diff, 1, @intCast(size - n)));
                } else {
                    len = size - n;
                }
                const w = blk + n;
                dsp.acelpInterpolatef(excitation, w, pitch, tables.wmavoice_ipol1_coeffs[0..], 17, @intCast(fidx), 9, len);
                n += len;
            }
        } else {
            const block_pitch = block_pitch_sh2 >> 2;
            const fidx = block_pitch_sh2 & 3;
            if (fidx != 0) {
                dsp.acelpInterpolatef(excitation, blk, block_pitch, tables.wmavoice_ipol2_coeffs[0..], 4, @intCast(fidx), 8, size);
            } else {
                dsp.memcpyBackptr(excitation, blk, @intCast(block_pitch), size);
            }
        }
        trace.f32s(111, excitation[blk .. blk + size]);
        trace.f32s(112, pulses[0..size]);
        trace.f32s(113, &.{acb_gain});
        trace.f32s(113, &.{fcb_gain});
        for (0..size) |nn| excitation[blk + nn] = acb_gain * excitation[blk + nn] + fcb_gain * pulses[nn];
    }

    // ---- LSP 解码 ----
    fn dequantLsp10i(self: *Dec, gb: *bitio.Bits, lsps: []f64) void {
        _ = self;
        const vec_sizes = [4]u16{ 256, 64, 32, 32 };
        const mul_lsf = [4]f64{ 5.2187144800e-3, 1.4626986422e-3, 9.6179549166e-4, 1.1325736225e-3 };
        const base_lsf = [4]f64{ pi * -2.15522e-1, pi * -6.1646e-2, pi * -3.3486e-2, pi * -5.7408e-2 };
        var v: [4]u16 = undefined;
        v[0] = @intCast(gb.get(8));
        v[1] = @intCast(gb.get(6));
        v[2] = @intCast(gb.get(5));
        v[3] = @intCast(gb.get(5));
        dsp.dequantLsps(lsps, &v, &vec_sizes, tables.wmavoice_dq_lsp10i[0..], &mul_lsf, &base_lsf);
    }

    fn dequantLsp16i(self: *Dec, gb: *bitio.Bits, lsps: []f64) void {
        _ = self;
        const mul_lsf = [5]f64{ 3.3439586280e-3, 6.9908173703e-4, 3.3216608306e-3, 1.0334960326e-3, 3.1899104283e-3 };
        const base_lsf = [5]f64{ pi * -1.27576e-1, pi * -2.4292e-2, pi * -1.28094e-1, pi * -3.2128e-2, pi * -1.29816e-1 };
        var v: [5]u16 = undefined;
        v[0] = @intCast(gb.get(8));
        v[1] = @intCast(gb.get(6));
        v[2] = @intCast(gb.get(7));
        v[3] = @intCast(gb.get(6));
        v[4] = @intCast(gb.get(7));
        const sz1 = [2]u16{ 256, 64 };
        dsp.dequantLsps(lsps[0..5], v[0..2], &sz1, tables.wmavoice_dq_lsp16i1[0..], mul_lsf[0..2], base_lsf[0..2]);
        const sz2 = [2]u16{ 128, 64 };
        dsp.dequantLsps(lsps[5..10], v[2..4], &sz2, tables.wmavoice_dq_lsp16i2[0..], mul_lsf[2..4], base_lsf[2..4]);
        const sz3 = [1]u16{128};
        dsp.dequantLsps(lsps[10..16], v[4..5], &sz3, tables.wmavoice_dq_lsp16i3[0..], mul_lsf[4..5], base_lsf[4..5]);
    }

    fn dequantLsp10r(self: *Dec, gb: *bitio.Bits, i_lsps: []f64, prev: *const [MAX_LSPS]f64, a1: *[MAX_LSPS * 2]f64, a2: *[MAX_LSPS * 2]f64, q_mode: bool) void {
        _ = q_mode;
        const ipol = if (self.lsp_q_mode) tables.wmavoice_lsp10_intercoeff_b else tables.wmavoice_lsp10_intercoeff_a;
        const vec_sizes = [3]u16{ 128, 64, 64 };
        const mul_lsf = [3]f64{ 2.5807601174e-3, 1.2354460219e-3, 1.1763821673e-3 };
        const base_lsf = [3]f64{ pi * -1.07448e-1, pi * -5.2706e-2, pi * -5.1634e-2 };
        self.dequantLsp10i(gb, i_lsps);
        const interpol = gb.get(5);
        var v: [3]u16 = undefined;
        v[0] = @intCast(gb.get(7));
        v[1] = @intCast(gb.get(6));
        v[2] = @intCast(gb.get(6));
        for (0..10) |n| {
            const delta = prev[n] - i_lsps[n];
            a1[n] = @as(f64, ipol[interpol * 20 + n]) * delta + i_lsps[n];
            a1[10 + n] = @as(f64, ipol[interpol * 20 + 10 + n]) * delta + i_lsps[n];
        }
        dsp.dequantLsps(a2[0..20], &v, &vec_sizes, tables.wmavoice_dq_lsp10r[0..], &mul_lsf, &base_lsf);
    }

    fn dequantLsp16r(self: *Dec, gb: *bitio.Bits, i_lsps: []f64, prev: *const [MAX_LSPS]f64, a1: *[MAX_LSPS * 2]f64, a2: *[MAX_LSPS * 2]f64, q_mode: bool) void {
        _ = q_mode;
        const ipol = if (self.lsp_q_mode) tables.wmavoice_lsp16_intercoeff_b else tables.wmavoice_lsp16_intercoeff_a;
        const mul_lsf = [3]f64{ 1.2232979501e-3, 1.4062241527e-3, 1.6114744851e-3 };
        const base_lsf = [3]f64{ pi * -5.5830e-2, pi * -5.2908e-2, pi * -5.4776e-2 };
        self.dequantLsp16i(gb, i_lsps);
        const interpol = gb.get(5);
        var v: [3]u16 = undefined;
        v[0] = @intCast(gb.get(7));
        v[1] = @intCast(gb.get(7));
        v[2] = @intCast(gb.get(7));
        for (0..16) |n| {
            const delta = prev[n] - i_lsps[n];
            a1[n] = @as(f64, ipol[interpol * 32 + n]) * delta + i_lsps[n];
            a1[16 + n] = @as(f64, ipol[interpol * 32 + 16 + n]) * delta + i_lsps[n];
        }
        const sz1 = [1]u16{128};
        dsp.dequantLsps(a2[0..10], v[0..1], &sz1, tables.wmavoice_dq_lsp16r1[0..], mul_lsf[0..1], base_lsf[0..1]);
        dsp.dequantLsps(a2[10..20], v[1..2], &sz1, tables.wmavoice_dq_lsp16r2[0..], mul_lsf[1..2], base_lsf[1..2]);
        dsp.dequantLsps(a2[20..32], v[2..3], &sz1, tables.wmavoice_dq_lsp16r3[0..], mul_lsf[2..3], base_lsf[2..3]);
    }

    // ---- AW（pitch-adaptive window）码 ----
    fn awParseCoords(self: *Dec, gb: *bitio.Bits, pitch: *const [MAX_BLOCKS]i32) void {
        const start_offset = [94]i16{
            -11, -9,  -7,  -5,  -3,  -1,  1,   3,   5,   7,   9,   11,  13,  15, 18, 17, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 35, 37, 39, 41, 43, 45, 47, 49, 51, 53, 55, 57, 59, 61, 63, 65, 67, 69, 71, 73, 75, 77, 79, 81, 83, 85, 87, 89, 91, 93, 95, 97, 99, 101, 103, 105, 107, 109, 111, 113, 115, 117, 119, 121, 123, 125, 127, 129, 131, 133, 135, 137, 139, 141, 143, 145, 147, 149, 151, 153, 155, 157, 159,
        };
        self.aw_idx_is_ext = false;
        var bits: i32 = @intCast(gb.get(6));
        if (bits >= 54) {
            self.aw_idx_is_ext = true;
            bits += (bits - 54) * 3 + @as(i32, @intCast(gb.get(2)));
        }
        self.aw_pulse_range = if (@min(pitch[0], pitch[1]) > 32) 24 else 16;
        var offset: i32 = start_offset[@intCast(bits)];
        while (offset < 0) offset += pitch[0];
        self.aw_n_pulses[0] = @divTrunc(pitch[0] - 1 + @as(i32, @intCast(MAX_FRAMESIZE / 2)) - offset, pitch[0]);
        self.aw_first_pulse_off[0] = offset - @divTrunc(self.aw_pulse_range, 2);
        offset += self.aw_n_pulses[0] * pitch[0];
        self.aw_n_pulses[1] = @divTrunc(pitch[1] - 1 + @as(i32, @intCast(MAX_FRAMESIZE)) - offset, pitch[1]);
        self.aw_first_pulse_off[1] = offset - @divTrunc(@as(i32, @intCast(MAX_FRAMESIZE)) + self.aw_pulse_range, 2);
        if (start_offset[@intCast(bits)] < MAX_FRAMESIZE / 2) {
            while (self.aw_first_pulse_off[1] - pitch[1] + self.aw_pulse_range > 0) {
                self.aw_first_pulse_off[1] -= pitch[1];
            }
            if (start_offset[@intCast(bits)] < 0) {
                while (self.aw_first_pulse_off[0] - pitch[0] + self.aw_pulse_range > 0) {
                    self.aw_first_pulse_off[0] -= pitch[0];
                }
            }
        }
    }

    fn awPulseSet1(self: *Dec, gb: *bitio.Bits, block_idx: i32, fcb: *dsp.AmrFixed) void {
        const nbits: u32 = if (self.aw_idx_is_ext and block_idx == 0) 10 else 12;
        const val: i32 = @intCast(gb.get(nbits));
        const bi: usize = @intCast(block_idx);
        if (self.aw_n_pulses[bi] > 0) {
            var n_pulses: i32 = undefined;
            var v_mask: i32 = undefined;
            var i_mask: i32 = undefined;
            var sh: u32 = undefined;
            if (self.aw_pulse_range == 24) {
                n_pulses = 3;
                v_mask = 8;
                i_mask = 7;
                sh = 4;
            } else {
                n_pulses = 4;
                v_mask = 4;
                i_mask = 3;
                sh = 3;
            }
            var vv: i32 = val;
            var n: i32 = n_pulses;
            while (n > 0) {
                n -= 1;
                fcb.y[fcb.n] = if ((vv & v_mask) != 0) -1.0 else 1.0;
                fcb.x[fcb.n] = (vv & i_mask) * n_pulses + n + self.aw_first_pulse_off[bi];
                while (fcb.x[fcb.n] < 0) fcb.x[fcb.n] += fcb.pitch_lag;
                if (fcb.x[fcb.n] < MAX_FRAMESIZE / 2) fcb.n += 1;
                vv >>= @intCast(sh);
            }
        } else {
            const num2 = (val & 0x1FF) >> 1;
            var delta: i32 = undefined;
            var idx: i32 = undefined;
            if (num2 < 1 * 79) {
                delta = 1;
                idx = num2 + 1;
            } else if (num2 < 2 * 78) {
                delta = 3;
                idx = num2 + 1 - 1 * 77;
            } else if (num2 < 3 * 77) {
                delta = 5;
                idx = num2 + 1 - 2 * 76;
            } else {
                delta = 7;
                idx = num2 + 1 - 3 * 75;
            }
            const v: f32 = if ((val & 0x200) != 0) -1.0 else 1.0;
            const ni = fcb.n;
            fcb.no_repeat_mask |= @as(i32, 3) << @as(u5, @intCast(ni));
            fcb.x[ni] = idx - delta;
            fcb.y[ni] = v;
            fcb.x[ni + 1] = idx;
            fcb.y[ni + 1] = if ((val & 1) != 0) -v else v;
            fcb.n += 2;
        }
    }

    fn awPulseSet2(self: *Dec, gb: *bitio.Bits, block_idx: i32, fcb: *dsp.AmrFixed) i32 {
        // C：uint16_t use_mask_mem[9]; use_mask = use_mask_mem + 2（可负索引至 -2）
        var mem: [9]u16 = undefined;
        const bi: usize = @intCast(block_idx);
        var pulse_off: i32 = self.aw_first_pulse_off[bi];
        var pulse_start: i32 = undefined;
        var idx: i32 = undefined;
        var range: i32 = undefined;
        var aidx: i32 = undefined;
        var start_off: i32 = 0;

        if (self.aw_n_pulses[bi] > 0) {
            while (pulse_off + self.aw_pulse_range < 1) pulse_off += fcb.pitch_lag;
        }
        if (self.aw_n_pulses[0] > 0) {
            if (block_idx == 0) {
                range = 32;
            } else {
                range = 8;
                if (self.aw_n_pulses[bi] > 0) pulse_off = self.aw_next_pulse_off_cache;
            }
        } else {
            range = 16;
        }
        pulse_start = if (self.aw_n_pulses[bi] > 0) pulse_off - @divTrunc(range, 2) else 0;

        @memset(mem[0..2], 0); // use_mask[-2..0]
        for (mem[2..7]) |*m| m.* = 0xFFFF; // use_mask[0..5]
        @memset(mem[7..9], 0); // use_mask[5..7]
        if (self.aw_n_pulses[bi] > 0) {
            idx = pulse_off;
            while (idx < MAX_FRAMESIZE / 2) {
                const excl_range = self.aw_pulse_range;
                const um_idx: i32 = idx >> 4; // C 算术移位（负 idx → -1/-2）
                const first_sh: u32 = 16 - @as(u32, @intCast(idx & 15));
                // C：0xFFFFu << first_sh（first_sh==16 时 int 提升得 0xFFFF0000 → 截断 0）
                const m: u32 = if (first_sh >= 16) 0 else (@as(u32, 0xFFFF) << @as(u5, @intCast(first_sh))) & 0xFFFF;
                mem[@as(usize, @intCast(um_idx + 2))] &= @intCast(m);
                const rem = excl_range - @as(i32, @intCast(first_sh));
                if (rem >= 16) {
                    mem[@as(usize, @intCast(um_idx + 3))] = 0;
                    const m2: u32 = if (rem - 16 >= 16) 0 else (@as(u32, 0xFFFF) >> @as(u5, @intCast(rem - 16))) & 0xFFFF;
                    mem[@as(usize, @intCast(um_idx + 4))] &= @intCast(m2);
                } else {
                    mem[@as(usize, @intCast(um_idx + 3))] &= @as(u16, 0xFFFF) >> @intCast(rem);
                }
                idx += fcb.pitch_lag;
            }
        }

        aidx = @intCast(gb.get(if (self.aw_n_pulses[0] > 0) @as(u32, 5 - 2 * @as(u32, @intCast(block_idx))) else 4));
        var n: i32 = 0;
        while (n <= aidx) {
            var iidx: i32 = pulse_start;
            while (iidx < 0) iidx += fcb.pitch_lag;
            if (iidx >= MAX_FRAMESIZE / 2) {
                if (mem[2] != 0) {
                    iidx = 0x0F;
                } else if (mem[3] != 0) {
                    iidx = 0x1F;
                } else if (mem[4] != 0) {
                    iidx = 0x2F;
                } else if (mem[5] != 0) {
                    iidx = 0x3F;
                } else if (mem[6] != 0) {
                    iidx = 0x4F;
                } else {
                    return -1;
                }
                iidx -= @intCast(dsp.avLog2_16bit(mem[@as(usize, @intCast((iidx >> 4) + 2))]));
            }
            const mi: usize = @as(usize, @intCast((iidx >> 4) + 2));
            const umi: u16 = mem[mi];
            if ((umi & (@as(u16, 0x8000) >> @intCast(iidx & 15))) != 0) {
                mem[mi] = umi & ~(@as(u16, 0x8000) >> @intCast(iidx & 15));
                n += 1;
                start_off = iidx;
            }
            pulse_start += 1;
        }
        fcb.x[fcb.n] = start_off;
        fcb.y[fcb.n] = if (gb.get1() != 0) -1.0 else 1.0;
        fcb.n += 1;
        const nn: i32 = @rem(@as(i32, @intCast(MAX_FRAMESIZE / 2)) - start_off, fcb.pitch_lag);
        self.aw_next_pulse_off_cache = if (nn != 0) fcb.pitch_lag - nn else 0;
        return 0;
    }

    // ------------------------------------------------------------------
    // 后处理（APF）
    // ------------------------------------------------------------------
    fn postfilter(self: *Dec, synth: []f32, syn_abs: usize, sample_abs: usize, size: usize, lpcs: *const [MAX_LSPS]f32, fcb_type: FcbType, pitch: i32) void {
        var synth_filter_in_buf: [MAX_FRAMESIZE / 2]f32 = undefined;
        const zoff = self.history_nsamples + sample_abs;
        var in_buf: []const f32 = self.zero_exc_pf[0..];
        var in_off: usize = zoff;
        dsp.celpLpZeroSynthF(self.zero_exc_pf[0..], zoff, synth, syn_abs, lpcs[0..self.lsps], size, self.lsps);
        trace.f32s(trace.zero_tag, self.zero_exc_pf[zoff .. zoff + size]);

        if (@intFromEnum(fcb_type) >= @intFromEnum(FcbType.aw_pulses)) {
            if (!self.kalmanSmoothen(pitch, zoff, synth_filter_in_buf[0..size], size)) {
                in_buf = synth_filter_in_buf[0..size];
                in_off = 0;
                trace.f32s(trace.kalman_tag, synth_filter_in_buf[0..size]);
            }
        }
        trace.i32s(trace.kflag_tag, &.{if (in_off == 0) 1 else -1});
        dsp.celpLpSynthF(self.synth_filter_out_buf[0..], MAX_LSPS, in_buf, in_off, lpcs[0..self.lsps], size, self.lsps);
        std.mem.copyForwards(f32, self.synth_filter_out_buf[MAX_LSPS - self.lsps ..][0..self.lsps], self.synth_filter_out_buf[MAX_LSPS + size - self.lsps .. MAX_LSPS + size]);
        const synth_pf = self.synth_filter_out_buf[MAX_LSPS..];
        trace.f32s(trace.resyn_tag, synth_pf[0..size]);
        self.wienerDenoise(fcb_type, synth_pf[0..128], size, lpcs);
        trace.f32s(trace.wiener_tag, synth_pf[0..size]);
        dsp.adaptiveGainControlWma(self.out_buf[sample_abs .. sample_abs + size], synth_pf[0..size], synth[syn_abs .. syn_abs + size], 0.99, &self.postfilter_agc);
        trace.f32s(trace.agc_tag, self.out_buf[sample_abs .. sample_abs + size]);
        if (self.dc_level > 8) {
            dsp.applyOrder2Transfer(self.out_buf[sample_abs .. sample_abs + size], self.out_buf[sample_abs .. sample_abs + size], &[2]f32{ -1.99997, 1.0 }, &[2]f32{ -1.9330735188, 0.93589198496 }, 0.93980580475, &self.dcf_mem);
        }
    }

    fn kalmanSmoothen(self: *Dec, pitch: i32, zoff: usize, out: []f32, size: usize) bool {
        var optimal_gain: f32 = 0;
        var dot: f32 = 0;
        const d_lo: i32 = @max(self.min_pitch_val, pitch - 3);
        const d_hi: i32 = @min(self.max_pitch_val, pitch + 3);
        var best_hist: i32 = 0;
        var d: i32 = d_lo;
        while (d <= d_hi) : (d += 1) {
            dot = dsp.scalarProduct(self.zero_exc_pf[zoff .. zoff + size], self.zero_exc_pf[zoff - @as(usize, @intCast(d)) ..][0..size]);
            if (dot > optimal_gain) {
                optimal_gain = dot;
                best_hist = d;
            }
        }
        if (optimal_gain <= 0) return true;
        dot = dsp.scalarProduct(self.zero_exc_pf[zoff - @as(usize, @intCast(best_hist)) ..][0..size], self.zero_exc_pf[zoff - @as(usize, @intCast(best_hist)) ..][0..size]);
        if (dot <= 0) return true;
        // C: dot = dot / (dot + 0.6 * optimal_gain)——0.6 为 double，全程 double
        if (optimal_gain <= dot) {
            dot = @floatCast(@as(f64, dot) / (@as(f64, dot) + 0.6 * @as(f64, optimal_gain)));
        } else {
            dot = 0.625;
        }
        const hist = self.zero_exc_pf[zoff - @as(usize, @intCast(best_hist)) ..];
        for (0..size) |n| out[n] = hist[n] + dot * (self.zero_exc_pf[zoff + n] - hist[n]);
        return false;
    }

    fn wienerDenoise(self: *Dec, fcb_type: FcbType, synth_pf: []f32, size: usize, lpcs: *const [MAX_LSPS]f32) void {
        var coeffs_f: [0x82]f32 = undefined;
        var synth_f: [0x82]f32 = undefined;
        var remainder: usize = 0;
        if (fcb_type != .silence) {
            const tilted_lpcs: []f32 = &self.tilted_lpcs_pf;
            const coeffs: []f32 = &self.denoise_coeffs_pf;
            var tilt_mem: f32 = 0;
            tilted_lpcs[0] = 1.0;
            @memcpy(tilted_lpcs[1 .. 1 + self.lsps], lpcs[0..self.lsps]);
            @memset(tilted_lpcs[self.lsps + 1 .. 128], 0);
            dsp.tiltCompensation(&tilt_mem, @floatCast(0.7 * @as(f64, dsp.tiltFactor(lpcs[0..self.lsps]))), tilted_lpcs[0 .. self.lsps + 2]);
            remainder = @min(127 - size, size - 1);
            self.calcInputResponse(fcb_type, tilted_lpcs[0..], coeffs[0..], remainder);
            @memset(synth_pf[size .. 128], 0);
            tx.rdftR2C(synth_f[0..], synth_pf[0..128]);
            trace.f32s(123, synth_f[0..130]);
            tx.rdftR2C(coeffs_f[0..], coeffs[0..128]);
            trace.f32s(124, coeffs_f[0..130]);
            synth_f[0] *= coeffs_f[0];
            synth_f[1] *= coeffs_f[1];
            for (1..65) |n| {
                const v1 = synth_f[n * 2];
                const v2 = synth_f[n * 2 + 1];
                synth_f[n * 2] = v1 * coeffs_f[n * 2] - v2 * coeffs_f[n * 2 + 1];
                synth_f[n * 2 + 1] = v2 * coeffs_f[n * 2] + v1 * coeffs_f[n * 2 + 1];
            }
            trace.f32s(121, synth_f[0..130]);
            tx.rdftC2R(synth_pf[0..128], synth_f[0..]);
            trace.f32s(122, synth_pf[0..128]);
        }
        if (self.denoise_filter_cache_size > 0) {
            const lim = @min(@as(usize, @intCast(self.denoise_filter_cache_size)), size);
            for (0..lim) |nn| synth_pf[nn] += self.denoise_filter_cache[nn];
            self.denoise_filter_cache_size -= @intCast(lim);
            std.mem.copyForwards(f32, self.denoise_filter_cache[0..@intCast(self.denoise_filter_cache_size)], self.denoise_filter_cache[size .. size + @as(usize, @intCast(self.denoise_filter_cache_size))]);
        }
        if (fcb_type != .silence) {
            const lim = @min(remainder, @as(usize, @intCast(self.denoise_filter_cache_size)));
            for (0..lim) |nn| self.denoise_filter_cache[nn] += synth_pf[size + nn];
            if (lim < remainder) {
                @memcpy(self.denoise_filter_cache[lim..remainder], synth_pf[size + lim .. size + remainder]);
                self.denoise_filter_cache_size = @intCast(remainder);
            }
        }
    }

    fn calcInputResponse(self: *Dec, fcb_type: FcbType, lpcs_src: []f32, coeffs_dst: []f32, remainder: usize) void {
        var coeffs: [0x82]f32 = undefined;
        var lpcs: [0x82]f32 = undefined;
        var lpcs_dct: [0x82]f32 = undefined;
        var last_coeff: f32 = 0;
        var min_: f32 = 15.0;
        var max_: f32 = -15.0;
        @memcpy(coeffs[0..0x82], coeffs_dst[0..0x82]);

        tx.rdftR2C(lpcs[0..], lpcs_src[0..128]);
        var v: f32 = dsp.log10f(lpcs[64] * lpcs[64]);
        last_coeff = v;
        max_ = @max(max_, v);
        min_ = @min(min_, v);
        for (1..64) |nn| {
            v = dsp.log10f(lpcs[nn * 2] * lpcs[nn * 2] + lpcs[nn * 2 + 1] * lpcs[nn * 2 + 1]);
            lpcs[nn] = v;
            max_ = @max(max_, v);
            min_ = @min(min_, v);
        }
        v = dsp.log10f(lpcs[0] * lpcs[0]);
        lpcs[0] = v;
        max_ = @max(max_, v);
        min_ = @min(min_, v);
        const range = max_ - min_;
        lpcs[64] = last_coeff;
        trace.f32s(125, lpcs[0..65]);
        // C：irange/gain_mul/angle_mul 均为 float 变量 = double 表达式单次舍入
        const irange: f32 = @floatCast(64.0 / @as(f64, range));
        const gm: f64 = @as(f64, range) * (if (fcb_type == .hardcoded) @as(f64, 5.0) / 13.0 else @as(f64, 5.0) / 14.7);
        const gain_mul: f32 = @floatCast(gm);
        const ln10_c: f64 = std.math.ln10;
        const angle_mul: f32 = @floatCast(@as(f64, gain_mul) * ((@as(f64, 8.0) * ln10_c) / std.math.pi));
        for (0..65) |nn| {
            var pwr: f32 = undefined;
            // C: idx = lrint(...)——四舍六入五成双（round-half-even）
            var iidx: i64 = @intCast(dsp.lrint((max_ - lpcs[nn]) * irange - 1.0));
            if (iidx < 0) iidx = 0;
            pwr = tables.wmavoice_denoise_power_table[self.denoise_strength * 64 + @as(usize, @intCast(iidx))];
            lpcs[nn] = angle_mul * pwr;
            // C: idx = av_clipd((pwr * gain_mul - 0.0295) * 70.570526123, 0, INT_MAX/2)
            //   （赋值给 int 截断），随后按整型比较/查表/powf
            var didx: f64 = @as(f64, pwr * gain_mul) - 0.0295;
            didx = didx * 70.570526123;
            if (didx < 0) didx = 0;
            if (didx > 1073741823.0) didx = 1073741823.0;
            const idx2: i32 = @intFromFloat(didx);
            if (idx2 > 127) {
                coeffs[nn] = tables.wmavoice_energy_table[127] * dsp.powf(1.0331663, @floatFromInt(idx2 - 127));
            } else {
                coeffs[nn] = tables.wmavoice_energy_table[@intCast(@max(0, idx2))];
            }
        }
        trace.f32s(126, lpcs[0..65]);
        tx.dctIFwd(lpcs_dct[0..], lpcs[0..64]);
        trace.f32s(127, lpcs_dct[0..64]);
        tx.dstIFwd(lpcs[0..], lpcs_dct[0..64]);
        trace.f32s(128, lpcs[0..64]);
        var aidx: i32 = 255 + dsp.clipI32(lpcs[64], -255, 255);
        coeffs[0] = coeffs[0] * self.cos_tab[@intCast(aidx)];
        aidx = 255 + dsp.clipI32(lpcs[64] - 2 * lpcs[63], -255, 255);
        last_coeff = coeffs[64] * self.cos_tab[@intCast(aidx)];
        var n: i32 = 63;
        while (true) : (n -= 1) {
            aidx = 255 + dsp.clipI32(-lpcs[64] - 2 * lpcs[@intCast(n - 1)], -255, 255);
            coeffs[@intCast(n * 2 + 1)] = coeffs[@intCast(n)] * self.sin_tab[@intCast(aidx)];
            coeffs[@intCast(n * 2)] = coeffs[@intCast(n)] * self.cos_tab[@intCast(aidx)];
            n -= 1;
            if (n == 0) break;
            aidx = 255 + dsp.clipI32(lpcs[64] - 2 * lpcs[@intCast(n - 1)], -255, 255);
            coeffs[@intCast(n * 2 + 1)] = coeffs[@intCast(n)] * self.sin_tab[@intCast(aidx)];
            coeffs[@intCast(n * 2)] = coeffs[@intCast(n)] * self.cos_tab[@intCast(aidx)];
        }
        coeffs[64] = last_coeff;
        tx.rdftC2R(coeffs_dst[0..128], coeffs[0..]);
        @memset(coeffs_dst[remainder..128], 0);
        if (self.denoise_tilt_corr) {
            var tilt_mem: f32 = 0;
            coeffs_dst[remainder - 1] = 0;
            dsp.tiltCompensation(&tilt_mem, @floatCast(-1.8 * @as(f64, dsp.tiltFactor(coeffs_dst[0 .. remainder - 1]))), coeffs_dst[0..remainder]);
        }
        var dot: f32 = 0;
        for (0..remainder) |nn| dot += coeffs_dst[nn] * coeffs_dst[nn];
        const sq: f32 = (1.0 / 64.0) * @sqrt(1.0 / dot);
        for (0..remainder) |nn| coeffs_dst[nn] *= sq;
        trace.f32s(120, coeffs_dst[0..128]);
    }
};

fn lspd2lpcInto(i_lsps: *const [MAX_LSPS]f64, lpcs: *[MAX_LSPS]f32, count: usize) void {
    dsp.lspd2lpc(i_lsps[0..count], lpcs[0..count], count >> 1);
}

fn dsp_mean_lsf10(mode: usize) *const [10]f64 {
    return tables.wmavoice_mean_lsf10[mode * 10 ..][0..10];
}
fn dsp_mean_lsf16(mode: usize) *const [16]f64 {
    return tables.wmavoice_mean_lsf16[mode * 16 ..][0..16];
}
