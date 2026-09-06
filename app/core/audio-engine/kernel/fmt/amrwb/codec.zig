// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! AMR-WB 解码主路径（浮点，逐句对齐 FFmpeg amrwbdec.c）
//!
//! 对照 FFmpeg libavcodec/amrwbdec.c + amr.h（ff_amr_bit_reorder）：
//! 帧头 MIME 解析 → 位重排（order_MODE_*）→ ISF 量化解码/预测/最小间距 →
//! ISF→ISP→每子帧内插→LPC → 逐子帧 ACELP 解码（自适应码本分数基音、
//! 代数码本 4-track、增益 VQ、基音锐化/去稀疏/噪声增强/基音增强）→
//! LPC 合成 → 去加重 → 31Hz HPF → 5/4 上采样 → 高频带（噪声激励 + 20 阶
//! LPC + 6-7kHz BPF，23k85 额外 7k LPF）→ 求和 → 浮点样本。
//!
//! 帧输入：含 1 字节 MIME 头（mode/quality）的整帧字节。
//! 帧输出：320 个 f32 样本（16kHz 单声道）。

const std = @import("std");
const T = @import("tables.zig");
const dsp = @import("dsp.zig");

pub const LP_ORDER = T.LP_ORDER;
pub const LP_ORDER_16k = T.LP_ORDER_16k;
pub const HB_FIR_SIZE = T.HB_FIR_SIZE;
pub const UPS_MEM_SIZE = T.UPS_MEM_SIZE;
pub const AMRWB_SFR_SIZE = T.AMRWB_SFR_SIZE;
pub const AMRWB_SFR_SIZE_16k = T.AMRWB_SFR_SIZE_16k;
pub const FRAME_SAMPLES = 4 * AMRWB_SFR_SIZE_16k;

pub const Mode = enum(u8) {
    m6k60 = 0,
    m8k85,
    m12k65,
    m14k25,
    m15k85,
    m18k25,
    m19k85,
    m23k05,
    m23k85,
    sid = 9,
    sp_lost = 14,
    no_data = 15,
};

/// AMRWBFrame：全部字段 u16（位重排按 u16 字写入；字段布局同 C，见 tables 生成脚本）
pub const Frame = struct {
    vad: u16,
    isp_id: [7]u16,
    subframe: [4]SubFrame,

    pub const SubFrame = struct {
        adap: u16,
        ltp: u16,
        vq_gain: u16,
        hb_gain: u16,
        pul_ih: [4]u16,
        pul_il: [4]u16,
    };
};

const EXC_PRE: usize = T.AMRWB_P_DELAY_MAX + LP_ORDER + 1; // 248
const EXC_BUF_LEN: usize = T.AMRWB_P_DELAY_MAX + LP_ORDER + 2 + AMRWB_SFR_SIZE; // 313

const hpf_zeros = [2]f32{ -2.0, 1.0 };
const hpf_31_poles = [2]f32{ -1.978881836, 0.979125977 };
const hpf_31_gain: f32 = 0.989501953;
const hpf_400_poles = [2]f32{ -1.787109375, 0.864257812 };
const hpf_400_gain: f32 = 0.893554687;
const ir_filters: [2][]const f32 = .{ &T.ir_filter_str, &T.ir_filter_mid };
const one_over_1sh15: f32 = 1.0 / 32768.0;
const one_over_1sh14: f32 = 1.0 / 16384.0;
const one_over_1sh11: f32 = 1.0 / 2048.0;

pub const Decoder = struct {
    fr_cur_mode: u8 = 0,
    fr_quality: bool = false,
    isf_cur: [LP_ORDER]f32 = undefined,
    isf_q_past: [LP_ORDER]f32 = [_]f32{0} ** LP_ORDER,
    isf_past_final: [LP_ORDER]f32 = undefined,
    isp: [4][LP_ORDER]f64 = undefined,
    isp_sub4_past: [LP_ORDER]f64 = [_]f64{0} ** LP_ORDER,
    lp_coef: [4][LP_ORDER]f32 = undefined,

    base_pitch_lag: u8 = 0,
    pitch_lag_int: i32 = 0,

    excitation_buf: [EXC_BUF_LEN]f32 = [_]f32{0} ** EXC_BUF_LEN,

    pitch_vector: [AMRWB_SFR_SIZE]f32 = undefined,
    fixed_vector: [AMRWB_SFR_SIZE]f32 = undefined,
    spare_vector: [AMRWB_SFR_SIZE]f32 = undefined,
    synth_exc: [AMRWB_SFR_SIZE]f32 = undefined,

    prediction_error: [4]f32 = undefined,
    pitch_gain: [6]f32 = undefined,
    fixed_gain: [2]f32 = undefined,

    tilt_coef: f32 = 0.0,
    prev_ir_filter_nr: u8 = 0,
    prev_tr_gain: f32 = 0.0,

    samples_az: [LP_ORDER + AMRWB_SFR_SIZE]f32 = [_]f32{0} ** (LP_ORDER + AMRWB_SFR_SIZE),
    samples_up: [UPS_MEM_SIZE + AMRWB_SFR_SIZE]f32 = [_]f32{0} ** (UPS_MEM_SIZE + AMRWB_SFR_SIZE),
    samples_hb: [LP_ORDER_16k + AMRWB_SFR_SIZE_16k]f32 = [_]f32{0} ** (LP_ORDER_16k + AMRWB_SFR_SIZE_16k),

    hpf_31_mem: [2]f32 = [_]f32{0} ** 2,
    hpf_400_mem: [2]f32 = [_]f32{0} ** 2,
    demph_mem: [1]f32 = [_]f32{0} ** 1,
    bpf_6_7_mem: [HB_FIR_SIZE]f32 = [_]f32{0} ** HB_FIR_SIZE,
    lpf_7_mem: [HB_FIR_SIZE]f32 = [_]f32{0} ** HB_FIR_SIZE,

    prng: dsp.Lfg = undefined,
    first_frame: bool = true,

    /// 初始化（对齐 amrwb_decode_init 单声道）
    pub fn init() Decoder {
        var d = Decoder{};
        for (0..LP_ORDER) |i|
            d.isf_past_final[i] = @as(f32, @floatFromInt(T.isf_init[i])) * one_over_1sh15;
        for (0..4) |i| d.prediction_error[i] = T.MIN_ENERGY;
        d.prng = dsp.Lfg.initSeed(1);
        return d;
    }

    /// 解码一整帧（含 1 字节 MIME 头）。NO_DATA/坏帧输出静音；SID/保留 → 0。
    /// 返回样本数：FRAME_SAMPLES=320 正常/静音；0 = 该帧无可输出。
    pub fn decodeFrame(self: *Decoder, frame_data: []const u8, out: []f32) usize {
        const mode: u8 = frame_data[0] >> 3 & 0xF;
        const quality: bool = (frame_data[0] & 0x4) == 0x4;
        self.fr_cur_mode = mode;
        self.fr_quality = quality;

        if (mode == @intFromEnum(Mode.no_data) or !quality) {
            @memset(out[0..FRAME_SAMPLES], 0);
            return FRAME_SAMPLES;
        }
        if (mode > @intFromEnum(Mode.sid)) {
            @memset(out[0..FRAME_SAMPLES], 0);
            return FRAME_SAMPLES; // 保留 / SP_LOST
        }
        if (mode == @intFromEnum(Mode.sid)) {
            @memset(out[0..FRAME_SAMPLES], 0);
            return FRAME_SAMPLES; // SID：DTX/comfort 后置（先静音占位）
        }

        var frame: Frame = undefined;
        const words: []u16 = std.mem.bytesAsSlice(u16, std.mem.asBytes(&frame));
        @memset(words, 0);
        bitReorder(words, frame_data[1..], T.amr_bit_orderings_by_mode[mode]);

        self.decodeIsf(&frame);

        // 主环路（逐子帧）
        var hb_samples: [AMRWB_SFR_SIZE_16k]f32 = undefined;
        var hb_exc: [AMRWB_SFR_SIZE_16k]f32 = undefined;
        var sub_buf = out[0..FRAME_SAMPLES];
        for (0..4) |sub| {
            const cur: *const Frame.SubFrame = &frame.subframe[sub];
            const dst = sub_buf[sub * AMRWB_SFR_SIZE_16k ..][0..AMRWB_SFR_SIZE_16k];

            self.decodePitchVector(cur, sub);
            decodeFixedVector(&self.fixed_vector, &cur.pul_ih, &cur.pul_il, self.fr_cur_mode);
            pitchSharpening(self, &self.fixed_vector);

            var fixed_gain_factor: f32 = undefined;
            decodeGains(@intCast(cur.vq_gain & 0xFF), self.fr_cur_mode, &fixed_gain_factor, &self.pitch_gain[0]);

            self.fixed_gain[0] = dsp.amrSetFixedGain(
                fixed_gain_factor,
                dsp.dotProductf(&self.fixed_vector, &self.fixed_vector, AMRWB_SFR_SIZE) / @as(f32, AMRWB_SFR_SIZE),
                &self.prediction_error,
                T.ENERGY_MEAN,
                &T.energy_pred_fac,
            );

            const voice_fac = voiceFactor(&self.pitch_vector, self.pitch_gain[0], &self.fixed_vector, self.fixed_gain[0]);
            self.tilt_coef = voice_fac * 0.25 + 0.25;

            // 构造当前激励
            const exc: []f32 = self.excitation_buf[EXC_PRE..][0..AMRWB_SFR_SIZE];
            for (0..AMRWB_SFR_SIZE) |i| {
                exc[i] *= self.pitch_gain[0];
                exc[i] += self.fixed_gain[0] * self.fixed_vector[i];
                exc[i] = @trunc(exc[i]);
            }

            const stab_fac = stabilityFactor(&self.isf_cur, &self.isf_past_final);
            const synth_fixed_gain = noiseEnhancer(self.fixed_gain[0], &self.prev_tr_gain, voice_fac, stab_fac);
            const synth_fixed_vector = antiSparseness(self, &self.fixed_vector, &self.spare_vector);
            pitchEnhancer(synth_fixed_vector, voice_fac);

            self.synthesis(sub, &self.synth_exc, synth_fixed_gain, synth_fixed_vector);

            // 后处理
            deEmphasis(self, self.samples_up[UPS_MEM_SIZE .. UPS_MEM_SIZE + AMRWB_SFR_SIZE]);
            dsp.applyOrder2TransferFunction(
                self.samples_up[UPS_MEM_SIZE .. UPS_MEM_SIZE + AMRWB_SFR_SIZE],
                self.samples_up[UPS_MEM_SIZE .. UPS_MEM_SIZE + AMRWB_SFR_SIZE],
                &hpf_zeros,
                &hpf_31_poles,
                hpf_31_gain,
                &self.hpf_31_mem,
                AMRWB_SFR_SIZE,
            );

            upsample54(dst, &self.samples_up, T.UPS_FIR_SIZE);

            // 高频带
            dsp.applyOrder2TransferFunction(
                &hb_samples,
                self.samples_up[UPS_MEM_SIZE .. UPS_MEM_SIZE + AMRWB_SFR_SIZE],
                &hpf_zeros,
                &hpf_400_poles,
                hpf_400_gain,
                &self.hpf_400_mem,
                AMRWB_SFR_SIZE,
            );

            const hb_gain = findHbGain(self, &hb_samples, cur.hb_gain, frame.vad);
            scaledHbExcitation(self, &hb_exc, &self.synth_exc, hb_gain);

            hbSynthesis(self, sub, self.samples_hb[LP_ORDER_16k .. LP_ORDER_16k + AMRWB_SFR_SIZE_16k], &hb_exc, &self.isf_cur, &self.isf_past_final);

            dsp.hbFirFilter(&hb_samples, &T.bpf_6_7_coef, &self.bpf_6_7_mem, self.samples_hb[LP_ORDER_16k .. LP_ORDER_16k + AMRWB_SFR_SIZE_16k], AMRWB_SFR_SIZE_16k);
            if (self.fr_cur_mode == @intFromEnum(Mode.m23k85)) {
                dsp.hbFirFilter(&hb_samples, &T.lpf_7_coef, &self.lpf_7_mem, &hb_samples, AMRWB_SFR_SIZE_16k);
            }

            for (0..AMRWB_SFR_SIZE_16k) |i| dst[i] = (dst[i] + hb_samples[i]) * one_over_1sh15;


            self.updateSubState();
        }

        // 帧末状态
        self.isp_sub4_past = self.isp[3];
        self.isf_past_final = self.isf_cur;
        return FRAME_SAMPLES;
    }

    // ---- 帧级辅助 ----

    fn decodeIsf(self: *Decoder, frame: *Frame) void {
        if (self.fr_cur_mode == @intFromEnum(Mode.m6k60)) {
            decodeIsfIndices36b(&frame.isp_id, &self.isf_cur);
        } else {
            decodeIsfIndices46b(&frame.isp_id, &self.isf_cur);
        }
        isfAddMeanAndPast(&self.isf_cur, &self.isf_q_past);
        dsp.setMinDistLsf(&self.isf_cur, T.MIN_ISF_SPACING, LP_ORDER - 1);

        self.isf_cur[LP_ORDER - 1] *= 2.0;
        dsp.lsf2lspd(&self.isp[3], &self.isf_cur, LP_ORDER);
        if (self.first_frame) {
            self.first_frame = false;
            self.isp_sub4_past = self.isp[3];
        }
        interpolateIsp(&self.isp, &self.isp_sub4_past);
        for (0..4) |sf| dsp.amrwbLsp2lpc(&self.isp[sf], &self.lp_coef[sf], LP_ORDER);
    }

    fn synthesis(self: *Decoder, sub: usize, excitation: []f32, fixed_gain: f32, fixed_vector: []const f32) void {
        dsp.weightedVectorSumf(excitation, &self.pitch_vector, fixed_vector, self.pitch_gain[0], fixed_gain, AMRWB_SFR_SIZE);

        if (self.pitch_gain[0] > 0.5 and self.fr_cur_mode <= @intFromEnum(Mode.m8k85)) {
            const energy = dsp.dotProductf(excitation, excitation, AMRWB_SFR_SIZE);
            const pitch_factor = 0.25 * self.pitch_gain[0] * self.pitch_gain[0];
            for (0..AMRWB_SFR_SIZE) |i| excitation[i] += pitch_factor * self.pitch_vector[i];
            dsp.scaleVectorToGivenSumOfSquares(excitation, excitation, energy, AMRWB_SFR_SIZE);
        }

        // 合成滤波（samples_az[LP_ORDER..] 输出，历史在 [0..LP_ORDER)）
        const out_start = LP_ORDER;
        const out = self.samples_az[out_start .. out_start + AMRWB_SFR_SIZE];
        var work: [LP_ORDER + AMRWB_SFR_SIZE]f32 = undefined;
        @memcpy(work[0..LP_ORDER], self.samples_az[0..LP_ORDER]);
        dsp.lpSynthesisFilterf(&work, excitation, &self.lp_coef[sub], LP_ORDER, AMRWB_SFR_SIZE);
        @memcpy(out, work[LP_ORDER .. LP_ORDER + AMRWB_SFR_SIZE]);
    }

    fn updateSubState(self: *Decoder) void {
        std.mem.copyForwards(f32, self.excitation_buf[0..EXC_PRE], self.excitation_buf[AMRWB_SFR_SIZE .. AMRWB_SFR_SIZE + EXC_PRE]);
        std.mem.copyBackwards(f32, self.pitch_gain[1..6], self.pitch_gain[0..5]);
        std.mem.copyBackwards(f32, self.fixed_gain[1..2], self.fixed_gain[0..1]);
        std.mem.copyForwards(f32, self.samples_az[0..LP_ORDER], self.samples_az[AMRWB_SFR_SIZE .. AMRWB_SFR_SIZE + LP_ORDER]);
        std.mem.copyForwards(f32, self.samples_up[0..UPS_MEM_SIZE], self.samples_up[AMRWB_SFR_SIZE .. AMRWB_SFR_SIZE + UPS_MEM_SIZE]);
        std.mem.copyForwards(f32, self.samples_hb[0..LP_ORDER_16k], self.samples_hb[AMRWB_SFR_SIZE_16k .. AMRWB_SFR_SIZE_16k + LP_ORDER_16k]);
    }

    // ---- 基音 ----

    fn decodePitchVector(self: *Decoder, amr_subframe: *const Frame.SubFrame, subframe: usize) void {
        var pitch_lag_int: i32 = undefined;
        var pitch_lag_frac: i32 = undefined;
        const mode = self.fr_cur_mode;
        if (mode <= @intFromEnum(Mode.m8k85)) {
            decodePitchLagLow(&pitch_lag_int, &pitch_lag_frac, amr_subframe.adap, &self.base_pitch_lag, subframe, mode);
        } else {
            decodePitchLagHigh(&pitch_lag_int, &pitch_lag_frac, amr_subframe.adap, &self.base_pitch_lag, subframe);
        }
        self.pitch_lag_int = pitch_lag_int;
        if (pitch_lag_frac > 0) pitch_lag_int += 1;

        const base_in: i32 = @as(i32, @intCast(EXC_PRE + 1)) - pitch_lag_int;
        var frac_pos: i32 = pitch_lag_frac;
        if (!(frac_pos > 0)) frac_pos += 4;

        const out: []f32 = self.excitation_buf[EXC_PRE .. EXC_PRE + AMRWB_SFR_SIZE + 1];
        dsp.acelpInterpolatef(out, &self.excitation_buf, base_in, &T.ac_inter, 4, @intCast(frac_pos), LP_ORDER, AMRWB_SFR_SIZE + 1);

        if (amr_subframe.ltp != 0) {
            std.mem.copyForwards(f32, &self.pitch_vector, self.excitation_buf[EXC_PRE .. EXC_PRE + AMRWB_SFR_SIZE]);
        } else {
            for (0..AMRWB_SFR_SIZE) |i| {
                const v: f64 = 0.18 * @as(f64, self.excitation_buf[EXC_PRE + i - 1]) +
                    0.64 * @as(f64, self.excitation_buf[EXC_PRE + i]) +
                    0.18 * @as(f64, self.excitation_buf[EXC_PRE + i + 1]);
                self.pitch_vector[i] = @floatCast(v);
            }
            std.mem.copyForwards(f32, self.excitation_buf[EXC_PRE .. EXC_PRE + AMRWB_SFR_SIZE], &self.pitch_vector);
        }
    }
};

// ---------------------------------------------------------------------------
// 位重排（ffmpeg amr.h）
// ---------------------------------------------------------------------------

/// ff_amr_bit_reorder（out_words 为 Frame 的 u16 视图）
fn bitReorder(out_words: []u16, data: []const u8, ord: []const u16) void {
    var o: usize = 0;
    while (true) {
        const nbits: u32 = ord[o];
        o += 1;
        if (nbits == 0) break;
        const offset: u32 = ord[o];
        o += 1;
        var field: u32 = 0;
        var b: u32 = 0;
        while (b < nbits) : (b += 1) {
            const bit: u32 = ord[o];
            o += 1;
            field <<= 1;
            field |= (data[@intCast(bit >> 3)] >> @as(u3, @intCast(bit & 7))) & 1;
        }
        out_words[@intCast(offset >> 1)] = @intCast(field);
    }
}

// ---------------------------------------------------------------------------
// ISF
// ---------------------------------------------------------------------------

fn decodeIsfIndices36b(ind: []const u16, isf_q: []f32) void {
    var i: usize = 0;
    while (i < 9) : (i += 1) isf_q[i] = @as(f32, @floatFromInt(T.dico1_isf[ind[0]][i])) * one_over_1sh15;
    while (i < 16) : (i += 1) isf_q[i] = @as(f32, @floatFromInt(T.dico2_isf[ind[1]][i - 9])) * one_over_1sh15;
    i = 0;
    while (i < 5) : (i += 1) isf_q[i] += @as(f32, @floatFromInt(T.dico21_isf_36b[ind[2]][i])) * one_over_1sh15;
    i = 0;
    while (i < 4) : (i += 1) isf_q[i + 5] += @as(f32, @floatFromInt(T.dico22_isf_36b[ind[3]][i])) * one_over_1sh15;
    i = 0;
    while (i < 7) : (i += 1) isf_q[i + 9] += @as(f32, @floatFromInt(T.dico23_isf_36b[ind[4]][i])) * one_over_1sh15;
}

fn decodeIsfIndices46b(ind: []const u16, isf_q: []f32) void {
    var i: usize = 0;
    while (i < 9) : (i += 1) isf_q[i] = @as(f32, @floatFromInt(T.dico1_isf[ind[0]][i])) * one_over_1sh15;
    while (i < 16) : (i += 1) isf_q[i] = @as(f32, @floatFromInt(T.dico2_isf[ind[1]][i - 9])) * one_over_1sh15;
    i = 0;
    while (i < 3) : (i += 1) isf_q[i] += @as(f32, @floatFromInt(T.dico21_isf[ind[2]][i])) * one_over_1sh15;
    i = 0;
    while (i < 3) : (i += 1) isf_q[i + 3] += @as(f32, @floatFromInt(T.dico22_isf[ind[3]][i])) * one_over_1sh15;
    i = 0;
    while (i < 3) : (i += 1) isf_q[i + 6] += @as(f32, @floatFromInt(T.dico23_isf[ind[4]][i])) * one_over_1sh15;
    i = 0;
    while (i < 3) : (i += 1) isf_q[i + 9] += @as(f32, @floatFromInt(T.dico24_isf[ind[5]][i])) * one_over_1sh15;
    i = 0;
    while (i < 4) : (i += 1) isf_q[i + 12] += @as(f32, @floatFromInt(T.dico25_isf[ind[6]][i])) * one_over_1sh15;
}

/// isf_add_mean_and_past
fn isfAddMeanAndPast(isf_q: []f32, isf_past: []f32) void {
    for (0..LP_ORDER) |i| {
        const tmp = isf_q[i];
        isf_q[i] += @as(f32, @floatFromInt(T.isf_mean[i])) * one_over_1sh15;
        isf_q[i] = @floatCast(@as(f64, isf_q[i]) + (1.0 / 3.0) * @as(f64, isf_past[i]));
        isf_past[i] = tmp;
    }
}

/// interpolate_isp
fn interpolateIsp(isp_q: *[4][LP_ORDER]f64, isp4_past: *const [LP_ORDER]f64) void {
    for (0..3) |k| {
        const c: f64 = T.isfp_inter[k];
        for (0..LP_ORDER) |i| isp_q[k][i] = (1.0 - c) * isp4_past[i] + c * isp_q[3][i];
    }
}

// ---------------------------------------------------------------------------
// 基音延迟
// ---------------------------------------------------------------------------

fn decodePitchLagHigh(lag_int: *i32, lag_frac: *i32, pitch_index_arg: u16, base_lag_int: *u8, subframe: usize) void {
    const pitch_index: i32 = pitch_index_arg;
    if (subframe == 0 or subframe == 2) {
        if (pitch_index < 376) {
            lag_int.* = (pitch_index + 137) >> 2;
            lag_frac.* = pitch_index - (lag_int.* << 2) + 136;
        } else if (pitch_index < 440) {
            lag_int.* = (pitch_index + 257 - 376) >> 1;
            lag_frac.* = (pitch_index - (lag_int.* << 1) + 256 - 376) * 2;
        } else {
            lag_int.* = pitch_index - 280;
            lag_frac.* = 0;
        }
        base_lag_int.* = @intCast(std.math.clamp(lag_int.* - 8 - @as(i32, @intFromBool(lag_frac.* < 0)), T.AMRWB_P_DELAY_MIN, T.AMRWB_P_DELAY_MAX - 15));
    } else {
        lag_int.* = (pitch_index + 1) >> 2;
        lag_frac.* = pitch_index - (lag_int.* << 2);
        lag_int.* += base_lag_int.*;
    }
}

fn decodePitchLagLow(lag_int: *i32, lag_frac: *i32, pitch_index_arg: u16, base_lag_int: *u8, subframe: usize, mode: u8) void {
    const pitch_index: i32 = pitch_index_arg;
    if (subframe == 0 or (subframe == 2 and mode != @intFromEnum(Mode.m6k60))) {
        if (pitch_index < 116) {
            lag_int.* = (pitch_index + 69) >> 1;
            lag_frac.* = (pitch_index - (lag_int.* << 1) + 68) * 2;
        } else {
            lag_int.* = pitch_index - 24;
            lag_frac.* = 0;
        }
        base_lag_int.* = @intCast(std.math.clamp(lag_int.* - 8 - @as(i32, @intFromBool(lag_frac.* < 0)), T.AMRWB_P_DELAY_MIN, T.AMRWB_P_DELAY_MAX - 15));
    } else {
        lag_int.* = (pitch_index + 1) >> 1;
        lag_frac.* = (pitch_index - (lag_int.* << 1)) * 2;
        lag_int.* += base_lag_int.*;
    }
}

// ---------------------------------------------------------------------------
// 代数脉冲码本解码（TS 26.190 §5.8.2，ffmpeg decode_?p_track）
// ---------------------------------------------------------------------------

fn decode1pTrack(out: []i32, code_in: i32, m: usize, off: i32) void {
    const mask: i32 = (@as(i32, 1) << @intCast(m)) - 1;
    const pos = (code_in & mask) + off;
    out[0] = if ((code_in >> @intCast(m)) & 1 != 0) -pos else pos;
}

fn decode2pTrack(out: []i32, code_in: i32, m: usize, off: i32) void {
    var pos0: i32 = (code_in >> @intCast(m)) & ((@as(i32, 1) << @intCast(m)) - 1);
    var pos1: i32 = code_in & ((@as(i32, 1) << @intCast(m)) - 1);
    pos0 += off;
    pos1 += off;
    var s0: i32 = pos0;
    var s1: i32 = pos1;
    if ((code_in >> @intCast(2 * m)) & 1 != 0) {
        s0 = -pos0;
        s1 = -pos1;
    }
    out[0] = s0;
    if (pos0 > pos1) s1 = -s1;
    out[1] = s1;
}

fn decode3pTrack(out: []i32, code_in: i32, m: usize, off: i32) void {
    const half_2p: i32 = ((code_in >> @intCast(2 * m - 1)) & 1) << @intCast(m - 1);
    var sub: [2]i32 = undefined;
    decode2pTrack(&sub, code_in & ((@as(i32, 1) << @intCast(2 * m - 1)) - 1), m - 1, off + half_2p);
    out[0] = sub[0];
    out[1] = sub[1];
    decode1pTrack(out[2..], code_in >> @intCast(2 * m), m, off);
}

fn decode4pTrack(out: []i32, code_in: i32, m: usize, off: i32) void {
    const b_offset: i32 = @as(i32, 1) << @intCast(m - 1);
    const case_id: i32 = (code_in >> @intCast(4 * m - 2)) & 0x3;
    switch (case_id) {
        0 => {
            const half_4p: i32 = ((code_in >> @intCast(4 * m - 3)) & 1) << @intCast(m - 1);
            const subhalf_2p: i32 = ((code_in >> @intCast(2 * m - 3)) & 1) << @intCast(m - 2);
            var sub: [2]i32 = undefined;
            decode2pTrack(&sub, code_in & ((@as(i32, 1) << @intCast(2 * m - 3)) - 1), m - 2, off + half_4p + subhalf_2p);
            out[0] = sub[0];
            out[1] = sub[1];
            var sub2: [2]i32 = undefined;
            decode2pTrack(&sub2, (code_in >> @intCast(2 * m - 2)) & ((@as(i32, 1) << @intCast(2 * m - 1)) - 1), m - 1, off + half_4p);
            out[2] = sub2[0];
            out[3] = sub2[1];
        },
        1 => {
            var sub: [1]i32 = undefined;
            decode1pTrack(&sub, (code_in >> @intCast(3 * m - 2)) & ((@as(i32, 1) << @intCast(m)) - 1), m - 1, off);
            out[0] = sub[0];
            var sub2: [3]i32 = undefined;
            decode3pTrack(&sub2, code_in & ((@as(i32, 1) << @intCast(3 * m - 2)) - 1), m - 1, off + b_offset);
            out[1] = sub2[0];
            out[2] = sub2[1];
            out[3] = sub2[2];
        },
        2 => {
            var sub: [2]i32 = undefined;
            decode2pTrack(&sub, (code_in >> @intCast(2 * m - 1)) & ((@as(i32, 1) << @intCast(2 * m - 1)) - 1), m - 1, off);
            out[0] = sub[0];
            out[1] = sub[1];
            var sub2: [2]i32 = undefined;
            decode2pTrack(&sub2, code_in & ((@as(i32, 1) << @intCast(2 * m - 1)) - 1), m - 1, off + b_offset);
            out[2] = sub2[0];
            out[3] = sub2[1];
        },
        else => {
            var sub: [3]i32 = undefined;
            decode3pTrack(&sub, (code_in >> @intCast(m)) & ((@as(i32, 1) << @intCast(3 * m - 2)) - 1), m - 1, off);
            out[0] = sub[0];
            out[1] = sub[1];
            out[2] = sub[2];
            var sub2: [1]i32 = undefined;
            decode1pTrack(&sub2, code_in & ((@as(i32, 1) << @intCast(m)) - 1), m - 1, off + b_offset);
            out[3] = sub2[0];
        },
    }
}

fn decode5pTrack(out: []i32, code_in: i32, m: usize, off: i32) void {
    const half_3p: i32 = ((code_in >> @intCast(5 * m - 1)) & 1) << @intCast(m - 1);
    var sub: [3]i32 = undefined;
    decode3pTrack(&sub, (code_in >> @intCast(2 * m + 1)) & ((@as(i32, 1) << @intCast(3 * m - 2)) - 1), m - 1, off + half_3p);
    out[0] = sub[0];
    out[1] = sub[1];
    out[2] = sub[2];
    var sub2: [2]i32 = undefined;
    decode2pTrack(&sub2, code_in & ((@as(i32, 1) << @intCast(2 * m + 1)) - 1), m, off);
    out[3] = sub2[0];
    out[4] = sub2[1];
}

fn decode6pTrack(out: []i32, code_in: i32, m: usize, off: i32) void {
    const b_offset: i32 = @as(i32, 1) << @intCast(m - 1);
    const half_more: i32 = ((code_in >> @intCast(6 * m - 5)) & 1) << @intCast(m - 1);
    const half_other: i32 = b_offset - half_more;
    switch ((code_in >> @intCast(6 * m - 4)) & 0x3) {
        0 => {
            var s1: [1]i32 = undefined;
            decode1pTrack(&s1, code_in & ((@as(i32, 1) << @intCast(m)) - 1), m - 1, off + half_more);
            out[0] = s1[0];
            var s5: [5]i32 = undefined;
            decode5pTrack(&s5, (code_in >> @intCast(m)) & ((@as(i32, 1) << @intCast(5 * m - 5)) - 1), m - 1, off + half_more);
            out[1] = s5[0];
            out[2] = s5[1];
            out[3] = s5[2];
            out[4] = s5[3];
            out[5] = s5[4];
        },
        1 => {
            var s1: [1]i32 = undefined;
            decode1pTrack(&s1, code_in & ((@as(i32, 1) << @intCast(m)) - 1), m - 1, off + half_other);
            out[0] = s1[0];
            var s5: [5]i32 = undefined;
            decode5pTrack(&s5, (code_in >> @intCast(m)) & ((@as(i32, 1) << @intCast(5 * m - 5)) - 1), m - 1, off + half_more);
            out[1] = s5[0];
            out[2] = s5[1];
            out[3] = s5[2];
            out[4] = s5[3];
            out[5] = s5[4];
        },
        2 => {
            var s2: [2]i32 = undefined;
            decode2pTrack(&s2, code_in & ((@as(i32, 1) << @intCast(2 * m - 1)) - 1), m - 1, off + half_other);
            out[0] = s2[0];
            out[1] = s2[1];
            var s4: [4]i32 = undefined;
            decode4pTrack(&s4, (code_in >> @intCast(2 * m - 1)) & ((@as(i32, 1) << @intCast(4 * m - 4)) - 1), m - 1, off + half_more);
            out[2] = s4[0];
            out[3] = s4[1];
            out[4] = s4[2];
            out[5] = s4[3];
        },
        else => {
            var s3a: [3]i32 = undefined;
            decode3pTrack(&s3a, (code_in >> @intCast(3 * m - 2)) & ((@as(i32, 1) << @intCast(3 * m - 2)) - 1), m - 1, off);
            out[0] = s3a[0];
            out[1] = s3a[1];
            out[2] = s3a[2];
            var s3b: [3]i32 = undefined;
            decode3pTrack(&s3b, code_in & ((@as(i32, 1) << @intCast(3 * m - 2)) - 1), m - 1, off + b_offset);
            out[3] = s3b[0];
            out[4] = s3b[1];
            out[5] = s3b[2];
        },
    }
}

/// decode_fixed_vector
fn decodeFixedVector(fixed_vector: []f32, pulse_hi: []const u16, pulse_lo: []const u16, mode: u8) void {
    var sig_pos: [4][6]i32 = undefined;
    const spacing: usize = if (mode == @intFromEnum(Mode.m6k60)) 2 else 4;

    switch (mode) {
        @intFromEnum(Mode.m6k60) => {
            for (0..2) |i| {
                var s: [1]i32 = undefined;
                decode1pTrack(&s, pulse_lo[i], 5, 1);
                sig_pos[i][0] = s[0];
            }
        },
        @intFromEnum(Mode.m8k85) => {
            for (0..4) |i| {
                var s: [1]i32 = undefined;
                decode1pTrack(&s, pulse_lo[i], 4, 1);
                sig_pos[i][0] = s[0];
            }
        },
        @intFromEnum(Mode.m12k65) => {
            for (0..4) |i| {
                var s: [2]i32 = undefined;
                decode2pTrack(&s, pulse_lo[i], 4, 1);
                sig_pos[i][0] = s[0];
                sig_pos[i][1] = s[1];
            }
        },
        @intFromEnum(Mode.m14k25) => {
            for (0..2) |i| {
                var s: [3]i32 = undefined;
                decode3pTrack(&s, pulse_lo[i], 4, 1);
                sig_pos[i][0] = s[0];
                sig_pos[i][1] = s[1];
                sig_pos[i][2] = s[2];
            }
            for (2..4) |i| {
                var s: [2]i32 = undefined;
                decode2pTrack(&s, pulse_lo[i], 4, 1);
                sig_pos[i][0] = s[0];
                sig_pos[i][1] = s[1];
            }
        },
        @intFromEnum(Mode.m15k85) => {
            for (0..4) |i| {
                var s: [3]i32 = undefined;
                decode3pTrack(&s, pulse_lo[i], 4, 1);
                sig_pos[i][0] = s[0];
                sig_pos[i][1] = s[1];
                sig_pos[i][2] = s[2];
            }
        },
        @intFromEnum(Mode.m18k25) => {
            for (0..4) |i| {
                const code: i32 = @as(i32, pulse_lo[i]) + (@as(i32, pulse_hi[i]) << 14);
                var s: [4]i32 = undefined;
                decode4pTrack(&s, code, 4, 1);
                for (0..4) |j| sig_pos[i][j] = s[j];
            }
        },
        @intFromEnum(Mode.m19k85) => {
            for (0..2) |i| {
                const code: i32 = @as(i32, pulse_lo[i]) + (@as(i32, pulse_hi[i]) << 10);
                var s: [5]i32 = undefined;
                decode5pTrack(&s, code, 4, 1);
                for (0..5) |j| sig_pos[i][j] = s[j];
            }
            for (2..4) |i| {
                const code: i32 = @as(i32, pulse_lo[i]) + (@as(i32, pulse_hi[i]) << 14);
                var s: [4]i32 = undefined;
                decode4pTrack(&s, code, 4, 1);
                for (0..4) |j| sig_pos[i][j] = s[j];
            }
        },
        else => { // 23k05 / 23k85
            for (0..4) |i| {
                const code: i32 = @as(i32, pulse_lo[i]) + (@as(i32, pulse_hi[i]) << 11);
                var s: [6]i32 = undefined;
                decode6pTrack(&s, code, 4, 1);
                for (0..6) |j| sig_pos[i][j] = s[j];
            }
        },
    }

    @memset(fixed_vector[0..AMRWB_SFR_SIZE], 0);
    for (0..4) |i| {
        const n: usize = T.pulses_nb_per_mode_tr[mode][i];
        for (0..n) |j| {
            const abs: i32 = if (sig_pos[i][j] < 0) -sig_pos[i][j] else sig_pos[i][j];
            const pos: usize = (@as(usize, @intCast(abs)) - 1) * spacing + i;
            if (pos >= AMRWB_SFR_SIZE) return; // 防御（正常位流不会触发）
            fixed_vector[pos] += if (sig_pos[i][j] < 0) -1.0 else 1.0;
        }
    }
}

// ---------------------------------------------------------------------------
// 增益
// ---------------------------------------------------------------------------

/// decode_gains：pitch_gain Q14、fixed_gain_factor Q11
fn decodeGains(vq_gain: u8, mode: u8, fixed_gain_factor: *f32, pitch_gain: *f32) void {
    if (mode <= @intFromEnum(Mode.m8k85)) {
        pitch_gain.* = @as(f32, @floatFromInt(T.qua_gain_6b[vq_gain][0])) * one_over_1sh14;
        fixed_gain_factor.* = @as(f32, @floatFromInt(T.qua_gain_6b[vq_gain][1])) * one_over_1sh11;
    } else {
        pitch_gain.* = @as(f32, @floatFromInt(T.qua_gain_7b[vq_gain][0])) * one_over_1sh14;
        fixed_gain_factor.* = @as(f32, @floatFromInt(T.qua_gain_7b[vq_gain][1])) * one_over_1sh11;
    }
}

// ---------------------------------------------------------------------------
// 子帧级信号处理
// ---------------------------------------------------------------------------

/// pitch_sharpening
fn pitchSharpening(ctx: *Decoder, fixed_vector: []f32) void {
    var i: i32 = AMRWB_SFR_SIZE - 1;
    while (i != 0) : (i -= 1)
        fixed_vector[@intCast(i)] -= fixed_vector[@intCast(i - 1)] * ctx.tilt_coef;

    var j: usize = @intCast(ctx.pitch_lag_int);
    while (j < AMRWB_SFR_SIZE) : (j += 1)
        fixed_vector[j] = @floatCast(@as(f64, fixed_vector[j]) + 0.85 * @as(f64, fixed_vector[j - @as(usize, @intCast(ctx.pitch_lag_int))]));
}

/// voice_factor（p/f 能量用 double，同 C）
fn voiceFactor(p_vector: []const f32, p_gain: f32, f_vector: []const f32, f_gain: f32) f32 {
    const p_ener: f64 = @as(f64, dsp.dotProductf(p_vector, p_vector, AMRWB_SFR_SIZE)) * p_gain * p_gain;
    const f_ener: f64 = @as(f64, dsp.dotProductf(f_vector, f_vector, AMRWB_SFR_SIZE)) * f_gain * f_gain;
    return @floatCast((p_ener - f_ener) / (p_ener + f_ener + 0.01));
}

/// stability_factor
fn stabilityFactor(isf: []const f32, isf_past: []const f32) f32 {
    var acc: f32 = 0.0;
    for (0..LP_ORDER - 1) |i| {
        const d = isf[i] - isf_past[i];
        acc += d * d;
    }
    const v: f64 = 1.25 - @as(f64, @floatCast(acc)) * 0.8 * 512;
    return if (v < 0.0) 0.0 else @floatCast(v);
}

/// anti_sparseness（ir_filters_lookup 强/中滤波）
fn antiSparseness(ctx: *Decoder, fixed_vector: []f32, buf: []f32) []f32 {
    if (ctx.fr_cur_mode > @intFromEnum(Mode.m8k85)) return fixed_vector;
    var ir_filter_nr: i32 = undefined;
    if (ctx.pitch_gain[0] < 0.6) {
        ir_filter_nr = 0;
    } else if (ctx.pitch_gain[0] < 0.9) {
        ir_filter_nr = 1;
    } else {
        ir_filter_nr = 2;
    }

    if (ctx.fixed_gain[0] > 3.0 * ctx.fixed_gain[1]) {
        if (ir_filter_nr < 2) ir_filter_nr += 1;
    } else {
        var count: usize = 0;
        for (0..6) |i| {
            if (ctx.pitch_gain[i] < 0.6) count += 1;
        }
        if (count > 2) ir_filter_nr = 0;
        if (ir_filter_nr > @as(i32, ctx.prev_ir_filter_nr) + 1) ir_filter_nr -= 1;
    }
    ctx.prev_ir_filter_nr = @intCast(ir_filter_nr);

    ir_filter_nr += @intFromBool(ctx.fr_cur_mode == @intFromEnum(Mode.m8k85));

    if (ir_filter_nr < 2) {
        const coef: []const f32 = ir_filters[@intCast(ir_filter_nr)];
        @memset(buf[0..AMRWB_SFR_SIZE], 0);
        for (0..AMRWB_SFR_SIZE) |i| {
            if (fixed_vector[i] != 0.0) {
                dsp.circAddf(buf, buf, coef, i, fixed_vector[i], AMRWB_SFR_SIZE);
            }
        }
        return buf[0..AMRWB_SFR_SIZE];
    }
    return fixed_vector[0..AMRWB_SFR_SIZE];
}

/// noise_enhancer
fn noiseEnhancer(fixed_gain: f32, prev_tr_gain: *f32, voice_fac: f32, stab_fac: f32) f32 {
    const sm_fac = 0.5 * (1 - voice_fac) * stab_fac;
    var g0: f32 = undefined;
    if (fixed_gain < prev_tr_gain.*) {
        g0 = @min(prev_tr_gain.*, fixed_gain + fixed_gain * (6226.0 * one_over_1sh15));
    } else {
        g0 = @max(prev_tr_gain.*, fixed_gain * (27536.0 * one_over_1sh15));
    }
    prev_tr_gain.* = g0;
    return sm_fac * g0 + (1 - sm_fac) * fixed_gain;
}

/// pitch_enhancer
fn pitchEnhancer(fixed_vector: []f32, voice_fac: f32) void {
    const cpe = 0.125 * (1 + voice_fac);
    var last = fixed_vector[0];
    fixed_vector[0] -= cpe * fixed_vector[1];
    for (1..AMRWB_SFR_SIZE - 1) |i| {
        const cur = fixed_vector[i];
        fixed_vector[i] -= cpe * (last + fixed_vector[i + 1]);
        last = cur;
    }
    fixed_vector[AMRWB_SFR_SIZE - 1] -= cpe * last;
}

/// de_emphasis（输出写 samples_up[UPS_MEM_SIZE..]）
fn deEmphasis(ctx: *Decoder, out: []f32) void {
    out[0] = ctx.samples_az[LP_ORDER] + T.PREEMPH_FAC * ctx.demph_mem[0];
    for (1..AMRWB_SFR_SIZE) |i| out[i] = ctx.samples_az[LP_ORDER + i] + T.PREEMPH_FAC * out[i - 1];
    ctx.demph_mem[0] = out[AMRWB_SFR_SIZE - 1];
}

/// upsample_5_4：in_base = samples_up 中当前输入起始（=UPS_FIR_SIZE）
fn upsample54(out: []f32, in: []const f32, in_base: usize) void {
    const in0_base: isize = @as(isize, @intCast(in_base)) - (T.UPS_FIR_SIZE - 1);
    var int_part: usize = 0;
    var i: usize = 0;
    for (0..AMRWB_SFR_SIZE_16k / 5) |_| {
        out[i] = in[in_base + int_part];
        var frac_part: i32 = 4;
        i += 1;
        for (1..5) |_| {
            var acc: f32 = 0.0;
            const row: []const f32 = T.upsample_fir[@as(usize, @intCast(4 - frac_part))][0..];
            const b: isize = in0_base + @as(isize, @intCast(int_part));
            for (0..UPS_MEM_SIZE) |k| acc += in[@intCast(b + @as(isize, @intCast(k)))] * row[k];
            out[i] = acc;
            int_part += 1;
            frac_part -= 1;
            i += 1;
        }
    }
}

/// find_hb_gain
fn findHbGain(ctx: *Decoder, synth: []const f32, hb_idx: u16, vad: u16) f32 {
    if (ctx.fr_cur_mode == @intFromEnum(Mode.m23k85))
        return @as(f32, @floatFromInt(T.qua_hb_gain[hb_idx])) * one_over_1sh14;

    const wsp: f32 = @floatFromInt(@intFromBool(vad > 0));
    const tmp: f32 = dsp.dotProductf(synth[0 .. AMRWB_SFR_SIZE - 1], synth[1..], AMRWB_SFR_SIZE - 1);
    var tilt: f32 = 0.0;
    if (tmp > 0) {
        tilt = tmp / dsp.dotProductf(synth[0..AMRWB_SFR_SIZE], synth[0..AMRWB_SFR_SIZE], AMRWB_SFR_SIZE);
    }
    const v: f64 = (1.0 - @as(f64, tilt)) * (1.25 - 0.25 * @as(f64, wsp));
    return @floatCast(std.math.clamp(v, 0.1, 1.0));
}

/// scaled_hb_excitation
fn scaledHbExcitation(ctx: *Decoder, hb_exc: []f32, synth_exc: []const f32, hb_gain: f32) void {
    const energy = dsp.dotProductf(synth_exc, synth_exc, AMRWB_SFR_SIZE);
    for (0..AMRWB_SFR_SIZE_16k) |i| {
        const r: u16 = @intCast(ctx.prng.get() & 0xffff);
        hb_exc[i] = 32768.0 - @as(f32, @floatFromInt(r));
    }
    const target: f32 = energy * hb_gain * hb_gain;
    dsp.scaleVectorToGivenSumOfSquares(hb_exc, hb_exc, target, AMRWB_SFR_SIZE_16k);
}

/// hb_synthesis
fn hbSynthesis(ctx: *Decoder, subframe: usize, samples: []f32, exc: []const f32, isf: []const f32, isf_past: []const f32) void {
    if (ctx.fr_cur_mode == @intFromEnum(Mode.m6k60)) {
        var e_isf: [LP_ORDER_16k]f32 = undefined;
        dsp.weightedVectorSumf(
            e_isf[0..LP_ORDER],
            isf_past,
            isf,
            T.isfp_inter[subframe],
            @floatCast(1.0 - @as(f64, T.isfp_inter[subframe])),
            LP_ORDER,
        );
        extrapolateIsf(&e_isf);
        e_isf[LP_ORDER_16k - 1] *= 2.0;
        var e_isp: [LP_ORDER_16k]f64 = undefined;
        dsp.lsf2lspd(&e_isp, &e_isf, LP_ORDER_16k);
        var hb_lpc: [LP_ORDER_16k]f32 = undefined;
        dsp.amrwbLsp2lpc(&e_isp, &hb_lpc, LP_ORDER_16k);
        lpcWeighting(&hb_lpc, &hb_lpc, 0.9, LP_ORDER_16k);

        var work: [LP_ORDER_16k + AMRWB_SFR_SIZE_16k]f32 = undefined;
        @memcpy(work[0..LP_ORDER_16k], ctx.samples_hb[0..LP_ORDER_16k]);
        dsp.lpSynthesisFilterf(&work, exc, &hb_lpc, LP_ORDER_16k, AMRWB_SFR_SIZE_16k);
        @memcpy(samples, work[LP_ORDER_16k .. LP_ORDER_16k + AMRWB_SFR_SIZE_16k]);
    } else {
        var hb_lpc: [LP_ORDER_16k]f32 = undefined;
        lpcWeighting(&hb_lpc, &ctx.lp_coef[subframe], 0.6, LP_ORDER);
        var work: [LP_ORDER + AMRWB_SFR_SIZE_16k]f32 = undefined;
        @memcpy(work[0..LP_ORDER], ctx.samples_hb[LP_ORDER_16k - LP_ORDER .. LP_ORDER_16k]);
        dsp.lpSynthesisFilterf(&work, exc, &hb_lpc, LP_ORDER, AMRWB_SFR_SIZE_16k);
        @memcpy(samples, work[LP_ORDER .. LP_ORDER + AMRWB_SFR_SIZE_16k]);
    }
}

/// extrapolate_isf（6k60 高频 16→20 阶 ISF 外推）
fn extrapolateIsf(isf: []f32) void {
    var diff_isf: [LP_ORDER - 2]f32 = undefined;
    var corr_lag: [3]f32 = undefined;
    isf[LP_ORDER_16k - 1] = isf[LP_ORDER - 1];

    for (0..LP_ORDER - 2) |i| diff_isf[i] = isf[i + 1] - isf[i];

    var diff_mean: f32 = 0.0;
    for (2..LP_ORDER - 2) |i| diff_mean += diff_isf[i] * (@as(f32, 1.0) / @as(f32, LP_ORDER - 4));

    var i_max_corr: usize = 0;
    for (0..3) |i| {
        corr_lag[i] = autoCorrelation(&diff_isf, diff_mean, i + 2);
        if (corr_lag[i] > corr_lag[i_max_corr]) i_max_corr = i;
    }
    i_max_corr += 1;

    for (LP_ORDER - 1..LP_ORDER_16k - 1) |i|
        isf[i] = isf[i - 1] + isf[i - 1 - i_max_corr] - isf[i - 2 - i_max_corr];

    const est: f32 = @floatCast(7965.0 + @as(f64, isf[2] - isf[3] - isf[4]) / 6.0);
    const scale: f32 = @floatCast(0.5 * (@min(@as(f64, est), 7600.0) - @as(f64, isf[LP_ORDER - 2])) /
        @as(f64, isf[LP_ORDER_16k - 2] - isf[LP_ORDER - 2]));

    {
        var idx: usize = LP_ORDER - 1;
        var jj: usize = 0;
        while (idx < LP_ORDER_16k - 1) : ({
            idx += 1;
            jj += 1;
        }) {
            diff_isf[jj] = scale * (isf[idx] - isf[idx - 1]);
        }
    }

    for (1..LP_ORDER_16k - LP_ORDER) |i| {
        if (diff_isf[i] + diff_isf[i - 1] < 5.0) {
            if (diff_isf[i] > diff_isf[i - 1]) {
                diff_isf[i - 1] = @floatCast(5.0 - @as(f64, diff_isf[i]));
            } else {
                diff_isf[i] = @floatCast(5.0 - @as(f64, diff_isf[i - 1]));
            }
        }
    }

    {
        var idx: usize = LP_ORDER - 1;
        var jj: usize = 0;
        while (idx < LP_ORDER_16k - 1) : ({
            idx += 1;
            jj += 1;
        }) {
            isf[idx] = isf[idx - 1] + diff_isf[jj] * one_over_1sh15;
        }
    }

    for (0..LP_ORDER_16k - 1) |i| isf[i] = @floatCast(@as(f64, isf[i]) * 0.8);
}

/// auto_correlation
fn autoCorrelation(diff_isf: []const f32, mean: f32, lag: usize) f32 {
    var sum: f32 = 0.0;
    for (7..LP_ORDER - 2) |i| {
        const prod = (diff_isf[i] - mean) * (diff_isf[i - lag] - mean);
        sum += prod * prod;
    }
    return sum;
}

/// lpc_weighting
fn lpcWeighting(out: []f32, lpc: []const f32, gamma: f32, size: usize) void {
    var fac = gamma;
    for (0..size) |i| {
        out[i] = lpc[i] * fac;
        fac *= gamma;
    }
}
