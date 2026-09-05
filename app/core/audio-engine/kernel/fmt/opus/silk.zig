//! SILK 解码器（libopus 1.6.1 silk/ 固定点移植）。
//! 依赖：rc.zig 的 ec_dec（SILK 与 CELT 共用同一 range coder）、silk_tables.zig。
//! 状态：基础框架 + decode_frame/decode_indices 已完成；decode_pulses/decode_parameters/
//!       decode_core/dec_API/滤波器组 待移植。
const std = @import("std");
const rcmod = @import("rc.zig");
const st = @import("silk_tables.zig");

pub const MAX_FRAMES_PER_PACKET = 3;
pub const TYPE_UNVOICED = 1;
pub const TYPE_VOICED = 2;
pub const CODE_INDEPENDENTLY = 0;
pub const CODE_CONDITIONALLY = 2;
pub const MAX_NB_SUBFR = 4;
pub const MAX_FRAME_LENGTH = 768;
pub const MAX_SUB_FRAME_LENGTH = 192;
pub const MAX_DELTA_GAIN_QUANT = 36;
pub const MIN_DELTA_GAIN_QUANT = -4;
pub const QUANT_LEVEL_ADJUST_Q10 = 80;
pub const MAX_LPC_ORDER = 16;
pub const LTP_ORDER = 5;
pub const SHELL_CODEC_FRAME_LENGTH = 16;
pub const NLSF_QUANT_MAX_AMPLITUDE = 4;
pub const NLSF_QUANT_MAX_AMPLITUDE_EXT = 10;

/// SideInfoIndices：一帧的量化索引
pub const SideInfoIndices = struct {
    gains_indices: [MAX_NB_SUBFR]i8 = undefined,
    ltp_index: [MAX_NB_SUBFR]i8 = undefined,
    nlsf_indices: [MAX_LPC_ORDER + 1]i8 = undefined,
    lag_index: i16 = 0,
    contour_index: i8 = 0,
    signal_type: i8 = 0,
    quant_offset_type: i8 = 0,
    nlsf_interp_coef_q2: i8 = 0,
    per_index: i8 = 0,
    ltp_scale_index: i8 = 0,
    seed: i8 = 0,
};

/// silk_decoder_control：预测与编码参数
pub const DecoderControl = struct {
    pitch_l: [MAX_NB_SUBFR]i32 = undefined,
    gains_q16: [MAX_NB_SUBFR]i32 = undefined,
    pred_coef_q12: [2][MAX_LPC_ORDER]i16 = undefined,
    ltp_coef_q14: [LTP_ORDER * MAX_NB_SUBFR]i16 = undefined,
    ltp_scale_q14: i32 = 0,
};

/// silk_decoder_state：解码器跨帧状态
pub const DecoderState = struct {
    prev_gain_q16: i32 = 0,
    exc_q14: [MAX_FRAME_LENGTH]i32 = undefined,
    s_lpc_q14_buf: [MAX_LPC_ORDER]i32 = undefined,
    out_buf: [MAX_FRAME_LENGTH + 2 * MAX_SUB_FRAME_LENGTH]i16 = undefined,
    lag_prev: i32 = 0,
    last_gain_index: i8 = 0,
    fs_khz: i32 = 0,
    fs_api_hz: i32 = 0,
    nb_subfr: i32 = 0,
    frame_length: i32 = 0,
    subfr_length: i32 = 0,
    ltp_mem_length: i32 = 0,
    lpc_order: i32 = 0,
    prev_nlsf_q15: [MAX_LPC_ORDER]i16 = undefined,
    first_frame_after_reset: i32 = 0,
    pitch_lag_low_bits_icdf: []const u8 = &.{},
    pitch_contour_icdf: []const u8 = &.{},
    n_frames_decoded: i32 = 0,
    n_frames_per_packet: i32 = 0,
    ec_prev_signal_type: i32 = 0,
    ec_prev_lag_index: i16 = 0,
    vad_flags: [MAX_FRAMES_PER_PACKET]i32 = undefined,
    lbrr_flag: i32 = 0,
    lbrr_flags: [MAX_FRAMES_PER_PACKET]i32 = undefined,
    ps_nlsf_cb: *const st.NlsfCb = undefined,
    indices: SideInfoIndices = .{},
    loss_cnt: i32 = 0,
    prev_signal_type: i32 = 0,
    s_plc: PlcState = .{},
    s_cng: CngState = .{},
};

inline fn RSHIFT(a: anytype, b: anytype) i32 {
    return @as(i32, @intCast(a)) >> @intCast(b);
}

inline fn LSHIFT(a: anytype, b: anytype) i32 {
    return @as(i32, @intCast(a)) << @intCast(b);
}

// ---- 定点辅助（silk macros）----
inline fn SMULBB(a: i32, b: i32) i32 {
    return @as(i32, @truncate(a)) * @as(i32, @truncate(b));
}
inline fn SMULWB(a: i32, b: i32) i32 {
    return @as(i32, @truncate((@as(i64, a) * @as(i32, @truncate(b))) >> 16));
}
inline fn SMLAWB(a: i32, b: i32, c: i32) i32 {
    return @as(i32, @truncate(@as(i64, a) + ((@as(i64, b) * @as(i32, @truncate(c))) >> 16)));
}
inline fn SMULWW(a: i32, b: i32) i32 {
    return @as(i32, @truncate((@as(i64, a) * b) >> 16));
}
inline fn MUL(a: i32, b: i32) i32 {
    return a * b;
}
inline fn RSHIFT_ROUND(a: i32, shift: u32) i32 {
    if (shift == 1) return (a >> 1) + (a & 1);
    return ((a >> @intCast(shift - 1)) + 1) >> 1;
}
inline fn RSHIFT_ROUND64(a: i64, shift: u32) i64 {
    if (shift == 1) return (a >> 1) + (a & 1);
    return ((a >> @intCast(shift - 1)) + 1) >> 1;
}
inline fn DIV32(a: i32, b: i32) i32 {
    return @divTrunc(a, b);
}
inline fn DIV32_16(a: i32, b: i32) i32 {
    return @divTrunc(a, b);
}
inline fn ADD_LSHIFT32(a: i32, b: i32, s: u5) i32 {
    return a + LSHIFT(b, s);
}
inline fn ADD_RSHIFT32(a: i32, b: i32, s: u5) i32 {
    return a + RSHIFT(b, s);
}
inline fn LIMIT(a: i32, l1: i32, l2: i32) i32 {
    if (l1 > l2) {
        return if (a > l1) l1 else (if (a < l2) l2 else a);
    }
    return if (a > l2) l2 else (if (a < l1) l1 else a);
}
inline fn silkMin(a: i32, b: i32) i32 {
    return if (a < b) a else b;
}
inline fn silkMax(a: i32, b: i32) i32 {
    return if (a > b) a else b;
}
inline fn SMLABB(a: i32, b: i32, c: i32) i32 {
    return a + SMULBB(b, c);
}
inline fn MLA(a: i32, b: i32, c: i32) i32 {
    return a + b * c;
}

/// silk_NLSF_unpack：解出 LSF 预测值与熵表索引
pub fn nlsfUnpack(ec_ix: *[MAX_LPC_ORDER]i16, pred_q8: *[MAX_LPC_ORDER]u8, cb: *const st.NlsfCb, cb1_index: i32) void {
    const order: usize = @intCast(cb.order);
    const ec_sel = cb.ec_sel[@as(usize, @intCast(cb1_index)) * order / 2 ..];
    var i: usize = 0;
    while (i < order) : (i += 2) {
        const entry = ec_sel[i / 2];
        ec_ix[i] = @intCast(@as(i32, @intCast(RSHIFT(@as(u32, entry), 1) & 7)) * (2 * NLSF_QUANT_MAX_AMPLITUDE + 1));
        pred_q8[i] = cb.pred_q8[i + @as(usize, entry & 1) * (order - 1)];
        ec_ix[i + 1] = @intCast(@as(i32, @intCast(RSHIFT(@as(u32, entry), 5) & 7)) * (2 * NLSF_QUANT_MAX_AMPLITUDE + 1));
        pred_q8[i + 1] = cb.pred_q8[i + @as(usize, @intCast(RSHIFT(@as(u32, entry), 4) & 1)) * (order - 1) + 1];
    }
}

/// silk_decode_indices：解码旁路信息（信号类型/增益/NLSF/音高/LTP）
pub fn decodeIndices(psDec: *DecoderState, rc: *rcmod.Rc, frame_index: i32, decode_lbrr: i32, cond_coding: i32) void {
    var i: usize = 0;
    var k: usize = 0;
    var ix: i32 = 0;

    // 信号类型与量化器偏移
    if (decode_lbrr != 0 or psDec.vad_flags[@intCast(frame_index)] != 0) {
        ix = @as(i32, @intCast(rc.decIcdf(&st.silk_type_offset_VAD_iCDF, 8))) + 2;
    } else {
        ix = @as(i32, @intCast(rc.decIcdf(&st.silk_type_offset_no_VAD_iCDF, 8)));
    }
    psDec.indices.signal_type = @intCast(RSHIFT(ix, 1));
    psDec.indices.quant_offset_type = @intCast(ix & 1);

    // 增益：首子帧
    if (cond_coding == CODE_CONDITIONALLY) {
        psDec.indices.gains_indices[0] = @intCast(rc.decIcdf(&st.silk_delta_gain_iCDF, 8));
    } else {
        psDec.indices.gains_indices[0] = @intCast(LSHIFT(@as(i32, @intCast(rc.decIcdf(st.silk_gain_iCDF[@as(usize, @intCast(psDec.indices.signal_type)) * 8 ..], 8))), 3));
        psDec.indices.gains_indices[0] += @intCast(rc.decIcdf(&st.silk_uniform8_iCDF, 8));
    }
    // 剩余子帧
    i = 1;
    while (i < @as(usize, @intCast(psDec.nb_subfr))) : (i += 1) {
        psDec.indices.gains_indices[i] = @intCast(rc.decIcdf(&st.silk_delta_gain_iCDF, 8));
    }

    // NLSF 索引
    var ec_ix: [MAX_LPC_ORDER]i16 = undefined;
    var pred_q8: [MAX_LPC_ORDER]u8 = undefined;
    const cb = psDec.ps_nlsf_cb;
    psDec.indices.nlsf_indices[0] = @intCast(rc.decIcdf(cb.cb1_icdf[@as(usize, @intCast(RSHIFT(@as(i32, psDec.indices.signal_type), 1))) * @as(usize, @intCast(cb.n_vectors)) ..], 8));
    nlsfUnpack(&ec_ix, &pred_q8, cb, psDec.indices.nlsf_indices[0]);
    i = 0;
    while (i < @as(usize, @intCast(cb.order))) : (i += 1) {
        ix = @intCast(rc.decIcdf(cb.ec_icdf[@as(usize, @intCast(ec_ix[i])) ..], 8));
        if (ix == 0) {
            ix -= @intCast(rc.decIcdf(&st.silk_NLSF_EXT_iCDF, 8));
        } else if (ix == 2 * NLSF_QUANT_MAX_AMPLITUDE) {
            ix += @intCast(rc.decIcdf(&st.silk_NLSF_EXT_iCDF, 8));
        }
        psDec.indices.nlsf_indices[i + 1] = @intCast(ix - NLSF_QUANT_MAX_AMPLITUDE);
    }

    // NLSF 插值系数
    if (psDec.nb_subfr == MAX_NB_SUBFR) {
        psDec.indices.nlsf_interp_coef_q2 = @intCast(rc.decIcdf(&st.silk_NLSF_interpolation_factor_iCDF, 8));
    } else {
        psDec.indices.nlsf_interp_coef_q2 = 4;
    }

    if (psDec.indices.signal_type == TYPE_VOICED) {
        // 音高滞后
        var decode_absolute_lag_index: i32 = 1;
        if (cond_coding == CODE_CONDITIONALLY and psDec.ec_prev_signal_type == TYPE_VOICED) {
            var delta_lag_index: i32 = @intCast(rc.decIcdf(&st.silk_pitch_delta_iCDF, 8));
            if (delta_lag_index > 0) {
                delta_lag_index -= 9;
                psDec.indices.lag_index = @intCast(psDec.ec_prev_lag_index + delta_lag_index);
                decode_absolute_lag_index = 0;
            }
        }
        if (decode_absolute_lag_index != 0) {
            psDec.indices.lag_index = @intCast(@as(i32, @intCast(rc.decIcdf(&st.silk_pitch_lag_iCDF, 8))) * RSHIFT(psDec.fs_khz, 1));
            psDec.indices.lag_index += @intCast(rc.decIcdf(psDec.pitch_lag_low_bits_icdf, 8));
        }
        psDec.ec_prev_lag_index = psDec.indices.lag_index;

        // 音高轮廓
        psDec.indices.contour_index = @intCast(rc.decIcdf(psDec.pitch_contour_icdf, 8));

        // LTP 增益
        psDec.indices.per_index = @intCast(rc.decIcdf(&st.silk_LTP_per_index_iCDF, 8));
        k = 0;
        while (k < @as(usize, @intCast(psDec.nb_subfr))) : (k += 1) {
            psDec.indices.ltp_index[k] = @intCast(rc.decIcdf(st.LTP_gain_iCDF_ptrs[@as(usize, @intCast(psDec.indices.per_index))], 8));
        }

        // LTP 缩放
        if (cond_coding == CODE_INDEPENDENTLY) {
            psDec.indices.ltp_scale_index = @intCast(rc.decIcdf(&st.silk_LTPscale_iCDF, 8));
        } else {
            psDec.indices.ltp_scale_index = 0;
        }
    }
    psDec.ec_prev_signal_type = psDec.indices.signal_type;

    // 种子
    psDec.indices.seed = @intCast(rc.decIcdf(&st.silk_uniform4_iCDF, 8));
}

/// silk_log2lin：近似 2^x
fn log2lin(in_log_q7: i32) i32 {
    if (in_log_q7 < 0) return 0;
    if (in_log_q7 >= 3967) return std.math.maxInt(i32);
    var out: i32 = LSHIFT(@as(i32, 1), RSHIFT(in_log_q7, 7));
    const frac_q7 = in_log_q7 & 0x7F;
    if (in_log_q7 < 2048) {
        out = @intCast(ADD_RSHIFT32(out, MUL(out, SMLAWB(frac_q7, SMULBB(frac_q7, 128 - frac_q7), -174)), 7));
    } else {
        out = MLA(out, RSHIFT(out, 7), SMLAWB(frac_q7, SMULBB(frac_q7, 128 - frac_q7), -174));
    }
    return out;
}

const MIN_QGAIN_DB = 2;
const MAX_QGAIN_DB = 88;
const N_LEVELS_QGAIN = 64;
const OFFSET = (MIN_QGAIN_DB * 128) / 6 + 16 * 128;
const SCALE_Q16 = (65536 * (N_LEVELS_QGAIN - 1)) / (((MAX_QGAIN_DB - MIN_QGAIN_DB) * 128) / 6);
const INV_SCALE_Q16 = (65536 * (((MAX_QGAIN_DB - MIN_QGAIN_DB) * 128) / 6)) / (N_LEVELS_QGAIN - 1);

/// silk_gains_dequant：增益反量化
pub fn gainsDequant(gain_q16: *[MAX_NB_SUBFR]i32, ind: []const i8, prev_ind: *i8, conditional: bool, nb_subfr: i32) void {
    var k: i32 = 0;
    while (k < nb_subfr) : (k += 1) {
        const idx: usize = @intCast(k);
        if (k == 0 and !conditional) {
            prev_ind.* = @intCast(silkMax(ind[idx], @as(i32, prev_ind.*) - 16));
        } else {
            const ind_tmp: i32 = ind[idx] + MIN_DELTA_GAIN_QUANT;
            const dstep = 2 * MAX_DELTA_GAIN_QUANT - N_LEVELS_QGAIN + prev_ind.*;
            if (ind_tmp > dstep) {
                prev_ind.* = @intCast(@as(i32, prev_ind.*) + LSHIFT(ind_tmp, 1) - dstep);
            } else {
                prev_ind.* = @intCast(@as(i32, prev_ind.*) + ind_tmp);
            }
        }
        prev_ind.* = @intCast(LIMIT(prev_ind.*, 0, N_LEVELS_QGAIN - 1));
        gain_q16[idx] = log2lin(silkMin(SMULWB(INV_SCALE_Q16, prev_ind.*) + OFFSET, 3967));
    }
}

/// silk_bwexpander：带宽扩展 AR 滤波器
fn bwexpander(ar: []i16, d: i32, chirp_q16: i32) void {
    var chirp: i32 = chirp_q16;
    const chirp_minus_one_q16 = chirp_q16 - 65536;
    var i: usize = 0;
    while (i < @as(usize, @intCast(d - 1))) : (i += 1) {
        ar[i] = @intCast(RSHIFT_ROUND(MUL(chirp, ar[i]), 16));
        chirp += RSHIFT_ROUND(MUL(chirp, chirp_minus_one_q16), 16);
    }
    ar[@intCast(d - 1)] = @intCast(RSHIFT_ROUND(MUL(chirp, ar[@intCast(d - 1)]), 16));
}

/// silk_NLSF_stabilize：NLSF 稳定化
fn nlsfStabilize(nlsf_q15: []i16, n_delta_min_q15: []const i16, l: i32) void {
    const max_loops = 20;
    var loops: i32 = 0;
    while (loops < max_loops) : (loops += 1) {
        var min_diff_q15: i32 = nlsf_q15[0] - n_delta_min_q15[0];
        var i_idx: i32 = 0;
        var i: i32 = 1;
        while (i <= l - 1) : (i += 1) {
            const diff_q15: i32 = nlsf_q15[@intCast(i)] - (nlsf_q15[@intCast(i - 1)] + n_delta_min_q15[@intCast(i)]);
            if (diff_q15 < min_diff_q15) {
                min_diff_q15 = diff_q15;
                i_idx = i;
            }
        }
        const diff_last: i32 = (@as(i32, 1) << 15) - (nlsf_q15[@intCast(l - 1)] +% n_delta_min_q15[@intCast(l)]);
        if (diff_last < min_diff_q15) {
            min_diff_q15 = diff_last;
            i_idx = l;
        }
        if (min_diff_q15 >= 0) return;

        if (i_idx == 0) {
            nlsf_q15[0] = n_delta_min_q15[0];
        } else if (i_idx == l) {
            nlsf_q15[@intCast(l - 1)] = @intCast((@as(i32, 1) << 15) - n_delta_min_q15[@intCast(l)]);
        } else {
            const ii: usize = @intCast(i_idx);
            var min_center_q15: i32 = 0;
            var kk: i32 = 0;
            while (kk < i_idx) : (kk += 1) min_center_q15 += n_delta_min_q15[@intCast(kk)];
            min_center_q15 += RSHIFT(n_delta_min_q15[@intCast(i_idx)], 1);
            var max_center_q15: i32 = 1 << 15;
            kk = l;
            while (kk > i_idx) : (kk -= 1) max_center_q15 -= n_delta_min_q15[@intCast(kk)];
            max_center_q15 -= RSHIFT(n_delta_min_q15[@intCast(i_idx)], 1);
            const center_freq_q15: i32 = LIMIT(RSHIFT_ROUND(@as(i32, nlsf_q15[ii - 1]) + @as(i32, nlsf_q15[ii]), 1), min_center_q15, max_center_q15);
            nlsf_q15[ii - 1] = @intCast(center_freq_q15 - RSHIFT(n_delta_min_q15[@intCast(i_idx)], 1));
            nlsf_q15[ii] = @intCast(@as(i32, nlsf_q15[ii - 1]) + n_delta_min_q15[@intCast(i_idx)]);
        }
    }
}

const NLSF_QUANT_LEVEL_ADJ = 0.1;

/// silk_NLSF_residual_dequant：NLSF 残差反量化
fn nlsfResidualDequant(x_q10: []i16, indices: []const i8, pred_coef_q8: []const u8, quant_step_size_q16: i32, order: i32) void {
    var out_q10: i32 = 0;
    var i: i32 = order - 1;
    while (i >= 0) : (i -= 1) {
        const pred_q10: i32 = RSHIFT(SMULBB(out_q10, pred_coef_q8[@intCast(i)]), 8);
        var out_q10v: i32 = @as(i32, indices[@intCast(i)]) << 10;
        if (out_q10v > 0) {
            out_q10v -= @as(i32, @intFromFloat(NLSF_QUANT_LEVEL_ADJ * 1024.0));
        } else if (out_q10v < 0) {
            out_q10v += @as(i32, @intFromFloat(NLSF_QUANT_LEVEL_ADJ * 1024.0));
        }
        out_q10 = SMLAWB(pred_q10, out_q10v, quant_step_size_q16);
        x_q10[@intCast(i)] = @intCast(out_q10);
    }
}

/// silk_NLSF_decode：NLSF 向量解码
pub fn nlsfDecode(p_nlsf_q15: []i16, nlsf_indices: []const i8, cb: *const st.NlsfCb) void {
    var pred_q8: [MAX_LPC_ORDER]u8 = undefined;
    var ec_ix: [MAX_LPC_ORDER]i16 = undefined;
    var res_q10: [MAX_LPC_ORDER]i16 = undefined;
    nlsfUnpack(&ec_ix, &pred_q8, cb, nlsf_indices[0]);
    nlsfResidualDequant(&res_q10, nlsf_indices[1..], &pred_q8, cb.quant_step_size_q16, cb.order);
    const order: usize = @intCast(cb.order);
    const cb_element = cb.cb1_nlsf_q8[@as(usize, @intCast(nlsf_indices[0])) * order ..];
    const cb_wght = cb.cb1_wght_q9[@as(usize, @intCast(nlsf_indices[0])) * order ..];
    var i: usize = 0;
    while (i < order) : (i += 1) {
        const tmp: i32 = ADD_LSHIFT32(DIV32_16(LSHIFT(@as(i32, res_q10[i]), 14), cb_wght[i]), cb_element[i], 7);
        p_nlsf_q15[i] = @intCast(LIMIT(tmp, 0, 32767));
    }
    nlsfStabilize(p_nlsf_q15[0..order], cb.delta_min_q15, cb.order);
}

/// silk_decode_pitch：解码音高滞后
pub fn decodePitch(lag_index: i16, contour_index: i8, pitch_lags: *[MAX_NB_SUBFR]i32, fs_khz: i32, nb_subfr: i32) void {
    const lag_cb: []const i8 = if (fs_khz == 8)
        (if (nb_subfr == 4) &st.silk_CB_lags_stage2 else &st.silk_CB_lags_stage2_10_ms)
    else
        (if (nb_subfr == 4) &st.silk_CB_lags_stage3 else &st.silk_CB_lags_stage3_10_ms);
    const cbk_size: i32 = if (fs_khz == 8)
        (if (nb_subfr == 4) 11 else 3)
    else
        (if (nb_subfr == 4) 34 else 12);
    const min_lag: i32 = SMULBB(2, fs_khz);
    const max_lag: i32 = SMULBB(18, fs_khz);
    const lag: i32 = min_lag + lag_index;
    var k: i32 = 0;
    while (k < nb_subfr) : (k += 1) {
        pitch_lags[@intCast(k)] = lag + lag_cb[@as(usize, @intCast(k * cbk_size + contour_index))];
        pitch_lags[@intCast(k)] = LIMIT(pitch_lags[@intCast(k)], min_lag, max_lag);
    }
}

/// silk_decode_parameters：解码预测参数
pub fn decodeParameters(psDec: *DecoderState, ctrl: *DecoderControl, cond_coding: i32) void {
    var p_nlsf_q15: [MAX_LPC_ORDER]i16 = undefined;
    var p_nlsf0_q15: [MAX_LPC_ORDER]i16 = undefined;

    // 增益反量化
    gainsDequant(&ctrl.gains_q16, &psDec.indices.gains_indices, &psDec.last_gain_index, cond_coding == CODE_CONDITIONALLY, psDec.nb_subfr);

    // NLSF 解码
    nlsfDecode(&p_nlsf_q15, &psDec.indices.nlsf_indices, psDec.ps_nlsf_cb);
    nlsf2a(ctrl.pred_coef_q12[1][0..], &p_nlsf_q15, psDec.lpc_order);

    if (psDec.first_frame_after_reset == 1) {
        psDec.indices.nlsf_interp_coef_q2 = 4;
    }

    if (psDec.indices.nlsf_interp_coef_q2 < 4) {
        var i: usize = 0;
        while (i < @as(usize, @intCast(psDec.lpc_order))) : (i += 1) {
            p_nlsf0_q15[i] = @intCast(@as(i32, psDec.prev_nlsf_q15[i]) + RSHIFT(MUL(psDec.indices.nlsf_interp_coef_q2, @as(i32, p_nlsf_q15[i]) - psDec.prev_nlsf_q15[i]), 2));
        }
        nlsf2a(ctrl.pred_coef_q12[0][0..], &p_nlsf0_q15, psDec.lpc_order);
    } else {
        @memcpy(ctrl.pred_coef_q12[0][0..@as(usize, @intCast(psDec.lpc_order))], ctrl.pred_coef_q12[1][0..@as(usize, @intCast(psDec.lpc_order))]);
    }
    @memcpy(psDec.prev_nlsf_q15[0..@as(usize, @intCast(psDec.lpc_order))], p_nlsf_q15[0..@as(usize, @intCast(psDec.lpc_order))]);

    if (psDec.loss_cnt != 0) {
        bwexpander(ctrl.pred_coef_q12[0][0..@as(usize, @intCast(psDec.lpc_order))], psDec.lpc_order, 63570);
        bwexpander(ctrl.pred_coef_q12[1][0..@as(usize, @intCast(psDec.lpc_order))], psDec.lpc_order, 63570);
    }

    if (psDec.indices.signal_type == TYPE_VOICED) {
        decodePitch(psDec.indices.lag_index, psDec.indices.contour_index, &ctrl.pitch_l, psDec.fs_khz, psDec.nb_subfr);
        const cbk_ptr = switch (psDec.indices.per_index) {
            0 => &st.silk_LTP_gain_vq_0,
            1 => &st.silk_LTP_gain_vq_1,
            else => &st.silk_LTP_gain_vq_2,
        };
        var k: usize = 0;
        while (k < @as(usize, @intCast(psDec.nb_subfr))) : (k += 1) {
            const ix = @as(usize, @intCast(psDec.indices.ltp_index[k]));
            var i: usize = 0;
            while (i < LTP_ORDER) : (i += 1) {
                ctrl.ltp_coef_q14[k * LTP_ORDER + i] = @intCast(LSHIFT(@as(i32, cbk_ptr[ix * LTP_ORDER + i]), 7));
            }
        }
        ctrl.ltp_scale_q14 = st.silk_LTPScales_table_Q14[@intCast(psDec.indices.ltp_scale_index)];
    } else {
        @memset(ctrl.pitch_l[0..@as(usize, @intCast(psDec.nb_subfr))], 0);
        @memset(ctrl.ltp_coef_q14[0 .. LTP_ORDER * @as(usize, @intCast(psDec.nb_subfr))], 0);
        psDec.indices.per_index = 0;
        ctrl.ltp_scale_q14 = 0;
    }
}

inline fn SMULL(a: i32, b: i32) i64 {
    return @as(i64, a) * b;
}
inline fn SMMUL(a: i32, b: i32) i32 {
    return @intCast(SMULL(a, b) >> 32);
}
inline fn SUB_SAT32(a: i32, b: i32) i32 {
    const au = @as(u32, @bitCast(a));
    const bu = @as(u32, @bitCast(b));
    const diff = au -% bu;
    if ((diff & 0x8000_0000) == 0) {
        if ((au & (bu ^ 0x8000_0000) & 0x8000_0000) != 0) return std.math.minInt(i32);
        return a - b;
    } else {
        if (((au ^ 0x8000_0000) & bu & 0x8000_0000) != 0) return std.math.maxInt(i32);
        return a - b;
    }
}
inline fn abs32(a: i32) i32 {
    return if (a > 0) a else -a;
}
inline fn CLZ32(a: i32) u6 {
    return @clz(@as(u32, @bitCast(a)));
}
inline fn ADD_SAT32(a: i32, b: i32) i32 {
    const r = @as(i64, a) + b;
    return @intCast(@min(@max(r, std.math.minInt(i32)), std.math.maxInt(i32)));
}
inline fn LSHIFT_SAT32(a: i32, shift: i32) i32 {
    const r = @as(i64, a) << @intCast(shift);
    return @intCast(@min(@max(r, std.math.minInt(i32)), std.math.maxInt(i32)));
}
inline fn SMLAWW(a: i32, b: i32, c: i32) i32 {
    return @intCast(@as(i64, a) + ((@as(i64, b) * c) >> 16));
}

const QA_NLSF = 24;
const A_LIMIT: i32 = @intFromFloat(0.99975 * 16777216.0);
const MAX_PREDICTION_POWER_GAIN: i32 = 10000;

fn MUL32_FRAC_Q(a: i32, b: i32, q: u32) i32 {
    return @intCast(RSHIFT_ROUND64(SMULL(a, b), q));
}

fn lpcInversePredGainQa(a_qa: []i32, order: i32) i32 {
    var inv_gain_q30: i32 = @intCast(@as(i64, 1) << 30);
    var k: i32 = order - 1;
    while (k > 0) : (k -= 1) {
        const ki: usize = @intCast(k);
        if ((a_qa[ki] > A_LIMIT) or (a_qa[ki] < -A_LIMIT)) { return 0; }
        const rc_q31: i32 = -(LSHIFT(a_qa[ki], 31 - QA_NLSF));
        const rc_mult1_q30: i32 = (@as(i32, 1) << 30) - SMMUL(rc_q31, rc_q31);
        inv_gain_q30 = LSHIFT(SMMUL(inv_gain_q30, rc_mult1_q30), 2);
        if (inv_gain_q30 < @as(i32, @intCast(@as(i64, 1) << 30)) / MAX_PREDICTION_POWER_GAIN) return 0;
        const mult2q: i32 = 32 - @as(i32, CLZ32(abs32(rc_mult1_q30)));
        const rc_mult2: i32 = inverse32VarQ(rc_mult1_q30, mult2q + 30);
        var n: i32 = 0;
        while (n < (k + 1) >> 1) : (n += 1) {
            const tmp1 = a_qa[@intCast(n)];
            const tmp2 = a_qa[@intCast(k - n - 1)];
            var tmp64 = RSHIFT_ROUND64(SMULL(SUB_SAT32(tmp1, MUL32_FRAC_Q(tmp2, rc_q31, 31)), rc_mult2), @intCast(mult2q));
            if (tmp64 > std.math.maxInt(i32) or tmp64 < std.math.minInt(i32)) return 0;
            a_qa[@intCast(n)] = @intCast(tmp64);
            tmp64 = RSHIFT_ROUND64(SMULL(SUB_SAT32(tmp2, MUL32_FRAC_Q(tmp1, rc_q31, 31)), rc_mult2), @intCast(mult2q));
            if (tmp64 > std.math.maxInt(i32) or tmp64 < std.math.minInt(i32)) return 0;
            a_qa[@intCast(k - n - 1)] = @intCast(tmp64);
        }
    }
    if ((a_qa[0] > A_LIMIT) or (a_qa[0] < -A_LIMIT)) return 0;
    const rc_q31_0: i32 = -(LSHIFT(a_qa[0], 31 - QA_NLSF));
    const rc_mult1_q30_0: i32 = (@as(i32, 1) << 30) - SMMUL(rc_q31_0, rc_q31_0);
    inv_gain_q30 = LSHIFT(SMMUL(inv_gain_q30, rc_mult1_q30_0), 2);
    if (inv_gain_q30 < @as(i32, @intCast(@as(i64, 1) << 30)) / MAX_PREDICTION_POWER_GAIN) return 0;
    return inv_gain_q30;
}

fn lpcInversePredGain(a_q12: []const i16, order: i32) i32 {
    var atmp_qa: [16]i32 = undefined;
    var dc_resp: i32 = 0;
    var k: i32 = 0;
    while (k < order) : (k += 1) {
        dc_resp += a_q12[@intCast(k)];
        atmp_qa[@intCast(k)] = LSHIFT(a_q12[@intCast(k)], QA_NLSF - 12);
    }
    if (dc_resp >= 4096) return 0;
    return lpcInversePredGainQa(&atmp_qa, order);
}

const MAX_LPC_STABILIZE_ITERATIONS = 16;

fn bwexpander32(ar: []i32, d: i32, chirp_q16_in: i32) void {
    var chirp_q16: i32 = chirp_q16_in;
    const chirp_minus_one_q16 = chirp_q16 - 65536;
    var i: i32 = 0;
    while (i < d - 1) : (i += 1) {
        ar[@intCast(i)] = SMULWW(chirp_q16, ar[@intCast(i)]);
        chirp_q16 += RSHIFT_ROUND(MUL(chirp_q16, chirp_minus_one_q16), 16);
    }
    ar[@intCast(d - 1)] = SMULWW(chirp_q16, ar[@intCast(d - 1)]);
}

fn lpcFit(a_qout: []i16, a_qin: []i32, qout: i32, qin: i32, d: i32) void {
    var i: i32 = 0;
    while (i < 10) : (i += 1) {
        var maxabs: i32 = 0;
        var idx: usize = 0;
        var k: i32 = 0;
        while (k < d) : (k += 1) {
            const absval = abs32(a_qin[@intCast(k)]);
            if (absval > maxabs) {
                maxabs = absval;
                idx = @intCast(k);
            }
        }
        maxabs = RSHIFT_ROUND(maxabs, @intCast(qin - qout));
        if (maxabs > std.math.maxInt(i16)) {
            maxabs = silkMin(maxabs, 163838);
            const chirp_q16: i32 = @as(i32, @intFromFloat(0.999 * 65536.0)) - @divTrunc(LSHIFT(maxabs - std.math.maxInt(i16), 14), RSHIFT(MUL(maxabs, @as(i32, @intCast(idx)) + 1), 2));
            bwexpander32(a_qin, d, chirp_q16);
        } else {
            break;
        }
    }
    var k: i32 = 0;
    while (k < d) : (k += 1) {
        a_qout[@intCast(k)] = @as(i16, @truncate(RSHIFT_ROUND(a_qin[@intCast(k)], @intCast(qin - qout))));
    }
}

/// silk_NLSF2A：NLSF → AR 系数（Q12）
fn nlsf2a(a_q12: []i16, nlsf: []const i16, d: i32) void {
    const ordering16 = [_]u8{ 0, 15, 8, 7, 4, 11, 12, 3, 2, 13, 10, 5, 6, 9, 14, 1 };
    const ordering10 = [_]u8{ 0, 9, 6, 3, 4, 5, 8, 1, 2, 7 };
    const ordering = if (d == 16) &ordering16 else &ordering10;
    var cos_lsf_qa: [16]i32 = undefined;
    var k: i32 = 0;
    while (k < d) : (k += 1) {
        const f_int: i32 = RSHIFT(nlsf[@intCast(k)], 15 - 7);
        const f_frac: i32 = nlsf[@intCast(k)] - LSHIFT(f_int, 15 - 7);
        const cos_val: i32 = st.silk_LSFCosTab_FIX_Q12[@intCast(f_int)];
        const delta: i32 = st.silk_LSFCosTab_FIX_Q12[@intCast(f_int + 1)] - cos_val;
        cos_lsf_qa[ordering[@intCast(k)]] = RSHIFT_ROUND(LSHIFT(cos_val, 8) + MUL(delta, f_frac), 20 - 16);
    }
    const dd: i32 = RSHIFT(d, 1);
    var p: [9]i32 = undefined;
    var q: [9]i32 = undefined;
    nlsf2aFindPoly(&p, cos_lsf_qa[0..], dd);
    nlsf2aFindPoly(&q, cos_lsf_qa[1..], dd);
    var a32_qa1: [16]i32 = undefined;
    k = 0;
    while (k < dd) : (k += 1) {
        const p_tmp = p[@intCast(k + 1)] + p[@intCast(k)];
        const q_tmp = q[@intCast(k + 1)] - q[@intCast(k)];
        a32_qa1[@intCast(k)] = -q_tmp - p_tmp;
        a32_qa1[@intCast(d - k - 1)] = q_tmp - p_tmp;
    }
    lpcFit(a_q12, &a32_qa1, 12, 17, d);
    var iter: i32 = 0;
    while (lpcInversePredGain(a_q12, d) == 0 and iter < MAX_LPC_STABILIZE_ITERATIONS) : (iter += 1) {
        bwexpander32(&a32_qa1, d, 65536 - LSHIFT(@as(i32, 2), iter));
        k = 0;
        while (k < d) : (k += 1) {
            a_q12[@intCast(k)] = @as(i16, @truncate(RSHIFT_ROUND(a32_qa1[@intCast(k)], 17 - 12)));
        }
    }
}

/// silk_NLSF2A_find_poly
fn nlsf2aFindPoly(out: *[9]i32, c_lsf: []const i32, dd: i32) void {
    out[0] = LSHIFT(@as(i32, 1), 16);
    out[1] = -c_lsf[0];
    var k: i32 = 1;
    while (k < dd) : (k += 1) {
        const ftmp = c_lsf[@intCast(2 * k)];
        out[@intCast(k + 1)] = LSHIFT(out[@intCast(k - 1)], 1) - @as(i32, @intCast(RSHIFT_ROUND64(SMULL(ftmp, out[@intCast(k)]), 16)));
        var n: i32 = k;
        while (n > 1) : (n -= 1) {
            out[@intCast(n)] += out[@intCast(n - 2)] - @as(i32, @intCast(RSHIFT_ROUND64(SMULL(ftmp, out[@intCast(n - 1)]), 16)));
        }
        out[1] -= ftmp;
    }
}

/// silk_INVERSE32_varQ
fn inverse32VarQ(b32_in: i32, qres: i32) i32 {
    const b_headrm: u6 = CLZ32(abs32(b32_in)) - 1;
    const b32_nrm: i32 = LSHIFT(b32_in, b_headrm);
    const b32_inv: i32 = DIV32_16(std.math.maxInt(i32) >> 2, RSHIFT(b32_nrm, 16));
    var result: i32 = LSHIFT(b32_inv, 16);
    const err_q32: i32 = LSHIFT((@as(i32, 1) << 29) - SMULWB(b32_nrm, b32_inv), 3);
    result = SMLAWW(result, err_q32, b32_inv);
    const lshift: i32 = 61 - @as(i32, b_headrm) - qres;
    if (lshift <= 0) {
        return LSHIFT_SAT32(result, @intCast(-@as(i32, @intCast(lshift))));
    } else {
        if (lshift < 32) return RSHIFT(result, @as(u5, @intCast(lshift)));
        return 0;
    }
}

const RAND_MULTIPLIER: i32 = 196314165;
const RAND_INCREMENT: i32 = 907633515;

inline fn MLA_ovflw(a: i32, b: i32, c: i32) i32 {
    return a +% @as(i32, @bitCast(@as(u32, @bitCast(b)) *% @as(u32, @bitCast(c))));
}
inline fn SUB32_ovflw(a: i32, b: i32) i32 {
    return a -% b;
}
inline fn LSHIFT_ovflw(a: i32, s: u5) i32 {
    return @bitCast(@as(u32, @bitCast(a)) << s);
}
inline fn SAT16(a: i32) i32 {
    return @min(@max(a, std.math.minInt(i16)), std.math.maxInt(i16));
}

fn DIV32_varQ(a32_in: i32, b32_in: i32, qres: i32) i32 {
    const a_headrm: u6 = CLZ32(abs32(a32_in)) - 1;
    var a32_nrm: i32 = LSHIFT(a32_in, a_headrm);
    const b_headrm: u6 = CLZ32(abs32(b32_in)) - 1;
    const b32_nrm: i32 = LSHIFT(b32_in, b_headrm);
    const b32_inv: i32 = DIV32_16(std.math.maxInt(i32) >> 2, RSHIFT(b32_nrm, 16));
    var result: i32 = SMULWB(a32_nrm, b32_inv);
    a32_nrm = SUB32_ovflw(a32_nrm, LSHIFT_ovflw(SMMUL(b32_nrm, result), 3));
    result = SMLAWB(result, a32_nrm, b32_inv);
    const lshift: i32 = 29 + @as(i32, a_headrm) - @as(i32, b_headrm) - qres;
    if (lshift < 0) return LSHIFT_SAT32(result, @intCast(-@as(i32, @intCast(lshift))));
    if (lshift < 32) return RSHIFT(result, @as(u5, @intCast(lshift)));
    return 0;
}

/// silk_LPC_analysis_filter：LPC 分析滤波（重白化用）
fn lpcAnalysisFilter(out: []i16, in_: []const i16, b: []const i16, len: i32, d: i32) void {
    var ix: i32 = d;
    while (ix < len) : (ix += 1) {
        var out32_q12: i32 = SMULBB(in_[@intCast(ix - 1)], b[0]);
        out32_q12 = MLA_ovflw(out32_q12, in_[@intCast(ix - 2)], b[1]);
        out32_q12 = MLA_ovflw(out32_q12, in_[@intCast(ix - 3)], b[2]);
        out32_q12 = MLA_ovflw(out32_q12, in_[@intCast(ix - 4)], b[3]);
        out32_q12 = MLA_ovflw(out32_q12, in_[@intCast(ix - 5)], b[4]);
        out32_q12 = MLA_ovflw(out32_q12, in_[@intCast(ix - 6)], b[5]);
        var j: i32 = 6;
        while (j < d) : (j += 2) {
            out32_q12 = MLA_ovflw(out32_q12, in_[@intCast(ix - j - 1)], b[@intCast(j)]);
            out32_q12 = MLA_ovflw(out32_q12, in_[@intCast(ix - j - 2)], b[@intCast(j + 1)]);
        }
        out32_q12 = SUB32_ovflw(LSHIFT(in_[@intCast(ix)], 12), out32_q12);
        out[@intCast(ix)] = @intCast(SAT16(RSHIFT_ROUND(out32_q12, 12)));
    }
    @memset(out[0..@intCast(d)], 0);
}

/// silk_decode_core：逆 NSQ（LTP + LPC 综合）
pub fn decodeCore(psDec: *DecoderState, ctrl: *DecoderControl, xq: []i16, pulses: []const i16) void {
    var s_lpc_q14: [MAX_LPC_ORDER + 768]i32 = undefined;
    var s_ltp: [1024]i16 = undefined;
    var s_ltp_q15: [1024 + 768]i32 = undefined;
    var res_q14: [MAX_SUB_FRAME_LENGTH]i32 = undefined;

    const offset_q10 = st.silk_Quantization_Offsets_Q10[@as(usize, @intCast(RSHIFT(@as(i32, psDec.indices.signal_type), 1))) * 2 + @as(usize, @intCast(psDec.indices.quant_offset_type))];
    const nlsf_interp_flag: i32 = if (psDec.indices.nlsf_interp_coef_q2 < (1 << 2)) 1 else 0;



    // 解码激励
    var rand_seed: i32 = psDec.indices.seed;
    var i: usize = 0;
    while (i < @as(usize, @intCast(psDec.frame_length))) : (i += 1) {
        rand_seed = MLA_ovflw(RAND_INCREMENT, rand_seed, RAND_MULTIPLIER);
        var exc: i32 = LSHIFT(@as(i32, pulses[i]), 14);
        if (exc > 0) {
            exc -= QUANT_LEVEL_ADJUST_Q10 << 4;
        } else if (exc < 0) {
            exc += QUANT_LEVEL_ADJUST_Q10 << 4;
        }
        exc += offset_q10 << 4;
        if (rand_seed < 0) exc = -exc;
        psDec.exc_q14[i] = exc;
        rand_seed += pulses[i];
    }

    @memcpy(s_lpc_q14[0..MAX_LPC_ORDER], psDec.s_lpc_q14_buf[0..MAX_LPC_ORDER]);
    const ltp_mem_length: usize = @intCast(psDec.ltp_mem_length);
    const frame_length: usize = @intCast(psDec.frame_length);
    const subfr_length: usize = @intCast(psDec.subfr_length);
    const lpc_order: usize = @intCast(psDec.lpc_order);

    var s_ltp_buf_idx: usize = ltp_mem_length;
    var k: usize = 0;
    while (k < @as(usize, @intCast(psDec.nb_subfr))) : (k += 1) {
        var a_q12_tmp: [MAX_LPC_ORDER]i16 = undefined;
        @memcpy(a_q12_tmp[0..lpc_order], ctrl.pred_coef_q12[k >> 1][0..lpc_order]);
        const b_q14 = ctrl.ltp_coef_q14[k * LTP_ORDER ..];
        var signal_type: i32 = psDec.indices.signal_type;
        const gain_q10: i32 = RSHIFT(ctrl.gains_q16[k], 6);
        var inv_gain_q31: i32 = inverse32VarQ(ctrl.gains_q16[k], 47);

        var gain_adj_q16: i32 = undefined;
        if (ctrl.gains_q16[k] != psDec.prev_gain_q16) {
            gain_adj_q16 = DIV32_varQ(psDec.prev_gain_q16, ctrl.gains_q16[k], 16);
            var ii: usize = 0;
            while (ii < MAX_LPC_ORDER) : (ii += 1) s_lpc_q14[ii] = SMULWW(gain_adj_q16, s_lpc_q14[ii]);
        } else {
            gain_adj_q16 = @as(i32, 1) << 16;
        }
        psDec.prev_gain_q16 = ctrl.gains_q16[k];

        if (psDec.loss_cnt != 0 and psDec.prev_signal_type == TYPE_VOICED and psDec.indices.signal_type != TYPE_VOICED and k < MAX_NB_SUBFR / 2) {
            @memset(b_q14[0..LTP_ORDER], 0);
            b_q14[LTP_ORDER / 2] = @intFromFloat(0.25 * 16384.0);
            signal_type = TYPE_VOICED;
            ctrl.pitch_l[k] = psDec.lag_prev;
        }

        if (signal_type == TYPE_VOICED) {
            const lag: i32 = ctrl.pitch_l[k];
            if (k == 0 or (k == 2 and nlsf_interp_flag != 0)) {
                const start_idx: i32 = @as(i32, @intCast(ltp_mem_length)) - lag - @as(i32, @intCast(lpc_order)) - @as(i32, LTP_ORDER / 2);
                if (k == 2) {
                    @memcpy(psDec.out_buf[ltp_mem_length .. ltp_mem_length + 2 * subfr_length], xq[0 .. 2 * subfr_length]);
                }
                lpcAnalysisFilter(s_ltp[@intCast(start_idx) ..], psDec.out_buf[@as(usize, @intCast(start_idx)) + k * subfr_length ..], a_q12_tmp[0..lpc_order], @as(i32, @intCast(ltp_mem_length)) - start_idx, @intCast(lpc_order));
                if (k == 0) {
                    inv_gain_q31 = LSHIFT(SMULWB(inv_gain_q31, ctrl.ltp_scale_q14), 2);
                }
                var ii: i32 = 0;
                while (ii < lag + LTP_ORDER / 2) : (ii += 1) {
                    s_ltp_q15[s_ltp_buf_idx - @as(usize, @intCast(ii)) - 1] = SMULWB(inv_gain_q31, s_ltp[ltp_mem_length - @as(usize, @intCast(ii)) - 1]);
                }
            } else if (gain_adj_q16 != (@as(i32, 1) << 16)) {
                var ii: i32 = 0;
                while (ii < lag + LTP_ORDER / 2) : (ii += 1) {
                    s_ltp_q15[s_ltp_buf_idx - @as(usize, @intCast(ii)) - 1] = SMULWW(gain_adj_q16, s_ltp_q15[s_ltp_buf_idx - @as(usize, @intCast(ii)) - 1]);
                }
            }
        }

        const exc_idx: usize = k * subfr_length;
        if (signal_type == TYPE_VOICED) {
            const lag: usize = @intCast(ctrl.pitch_l[k]);
            var pred_lag_ptr: usize = s_ltp_buf_idx - lag + LTP_ORDER / 2;
            var si: usize = 0;
            while (si < subfr_length) : (si += 1) {
                var ltp_pred_q13: i32 = 2;
                ltp_pred_q13 = SMLAWB(ltp_pred_q13, s_ltp_q15[pred_lag_ptr], b_q14[0]);
                ltp_pred_q13 = SMLAWB(ltp_pred_q13, s_ltp_q15[pred_lag_ptr - 1], b_q14[1]);
                ltp_pred_q13 = SMLAWB(ltp_pred_q13, s_ltp_q15[pred_lag_ptr - 2], b_q14[2]);
                ltp_pred_q13 = SMLAWB(ltp_pred_q13, s_ltp_q15[pred_lag_ptr - 3], b_q14[3]);
                ltp_pred_q13 = SMLAWB(ltp_pred_q13, s_ltp_q15[pred_lag_ptr - 4], b_q14[4]);
                pred_lag_ptr += 1;
                res_q14[si] = ADD_LSHIFT32(psDec.exc_q14[exc_idx + si], ltp_pred_q13, 1);
                s_ltp_q15[s_ltp_buf_idx] = LSHIFT(res_q14[si], 1);
                s_ltp_buf_idx += 1;
            }
        } else {
            @memcpy(res_q14[0..subfr_length], psDec.exc_q14[exc_idx .. exc_idx + subfr_length]);
        }

        var si: usize = 0;
        while (si < subfr_length) : (si += 1) {
            var lpc_pred_q10: i32 = RSHIFT(@as(i32, @intCast(lpc_order)), 1);
            var j: usize = 1;
            while (j <= lpc_order) : (j += 1) {
                lpc_pred_q10 = SMLAWB(lpc_pred_q10, s_lpc_q14[MAX_LPC_ORDER + si - j], a_q12_tmp[j - 1]);
            }
            s_lpc_q14[MAX_LPC_ORDER + si] = ADD_SAT32(res_q14[si], LSHIFT_SAT32(lpc_pred_q10, 4));
            xq[k * subfr_length + si] = @intCast(SAT16(RSHIFT_ROUND(SMULWW(s_lpc_q14[MAX_LPC_ORDER + si], gain_q10), 8)));
        }

        // 更新 LPC 状态
        @memcpy(s_lpc_q14[0..MAX_LPC_ORDER], s_lpc_q14[subfr_length .. subfr_length + MAX_LPC_ORDER]);
    }

    @memcpy(psDec.s_lpc_q14_buf[0..MAX_LPC_ORDER], s_lpc_q14[0..MAX_LPC_ORDER]);
    // 更新 outBuf
    const mv_len = ltp_mem_length - frame_length;
    var oi: usize = 0;
    while (oi < mv_len) : (oi += 1) psDec.out_buf[oi] = psDec.out_buf[oi + frame_length];
    @memcpy(psDec.out_buf[mv_len .. mv_len + frame_length], xq[0..frame_length]);
}

/// silk_decode_frame（框架）：后续阶段由 decode_pulses / decode_parameters /
/// decode_core 补齐后接入。
pub fn decodeFrame(psDec: *DecoderState, rc: *rcmod.Rc, out: []i16) void {
    const frame_length: usize = @intCast(psDec.frame_length);
    var pulses: [768]i16 = undefined;
    var ctrl: DecoderControl = .{};
    const cond_coding: i32 = if (psDec.n_frames_decoded <= 0) CODE_INDEPENDENTLY else CODE_CONDITIONALLY;
    decodeIndices(psDec, rc, psDec.n_frames_decoded, 0, cond_coding);
    decodePulses(rc, pulses[0..frame_length], psDec.indices.signal_type, psDec.indices.quant_offset_type, psDec.frame_length);
    decodeParameters(psDec, &ctrl, cond_coding);
    decodeCore(psDec, &ctrl, out, pulses[0..frame_length]);
    plc(psDec, &ctrl, out, 0); // 好帧：更新 PLC 状态
    psDec.loss_cnt = 0;
    cng(psDec, &ctrl, out, psDec.frame_length);
    glueFrames(psDec, out, psDec.frame_length);
    psDec.first_frame_after_reset = 0;
    psDec.n_frames_decoded += 1;
}

/// 一包解码入口（dec_API 帧前导 + 逐帧 decodeFrame）
pub fn decodePacket(psDec: *DecoderState, rc: *rcmod.Rc, out: []i16) void {
    decodePreamble(psDec, rc);
    decodeFrame(psDec, rc, out);
}

/// 丢包隐藏帧（dec_API lostFlag=FLAG_PACKET_LOST → silk_PLC lost=1）。
/// 生成一帧 16k s16 到 out，并更新 decoder 状态（out_buf / s_lpc / loss_cnt）。
pub fn decodeLostFrame(psDec: *DecoderState, out: []i16) void {
    var ctrl: DecoderControl = .{};
    ctrl.ltp_scale_q14 = 0;
    plc(psDec, &ctrl, out, 1);
    cng(psDec, &ctrl, out, psDec.frame_length);
    glueFrames(psDec, out, psDec.frame_length);
    // 更新输出缓冲（对齐 decode_frame 丢包路径）
    const frame_length: usize = @intCast(psDec.frame_length);
    const mv_len: usize = @as(usize, @intCast(psDec.ltp_mem_length)) - frame_length;
    var oi: usize = 0;
    while (oi < mv_len) : (oi += 1) psDec.out_buf[oi] = psDec.out_buf[oi + frame_length];
    @memcpy(psDec.out_buf[mv_len .. mv_len + frame_length], out[0..frame_length]);
    psDec.first_frame_after_reset = 0;
    psDec.lag_prev = ctrl.pitch_l[@intCast(psDec.nb_subfr - 1)];
}


/// 立体声丢包隐藏帧：mid/side 各自 PLC conceal → MS→LR（pred = pred_prev）。
/// 输出写 out_l[0..fl+2] / out_r[0..fl+2]（+2 偏移，MS_to_LR 语义）。
pub fn decodeLostFrameStereo(psDec0: *DecoderState, psDec1: *DecoderState, sStereo: *StereoDecState, out_l: []i16, out_r: []i16) void {
    const fl: usize = @intCast(psDec0.frame_length);
    var ctrl0: DecoderControl = .{};
    ctrl0.ltp_scale_q14 = 0;
    plc(psDec0, &ctrl0, out_l[2 .. fl + 2], 1);
    cng(psDec0, &ctrl0, out_l[2 .. fl + 2], psDec0.frame_length);
    glueFrames(psDec0, out_l[2 .. fl + 2], psDec0.frame_length);
    var ctrl1: DecoderControl = .{};
    ctrl1.ltp_scale_q14 = 0;
    if (sStereo.prev_decode_only_middle == 0) {
        plc(psDec1, &ctrl1, out_r[2 .. fl + 2], 1);
        cng(psDec1, &ctrl1, out_r[2 .. fl + 2], psDec1.frame_length);
        glueFrames(psDec1, out_r[2 .. fl + 2], psDec1.frame_length);
    } else {
        @memset(out_r[2 .. fl + 2], 0);
    }
    // 更新输出缓冲（对齐 decode_frame 丢包路径）
    for (0..2) |n| {
        const psDec = if (n == 0) psDec0 else psDec1;
        const out = if (n == 0) out_l else out_r;
        const frame_length: usize = @intCast(psDec.frame_length);
        const mv_len: usize = @as(usize, @intCast(psDec.ltp_mem_length)) - frame_length;
        var oi: usize = 0;
        while (oi < mv_len) : (oi += 1) psDec.out_buf[oi] = psDec.out_buf[oi + frame_length];
        @memcpy(psDec.out_buf[mv_len .. mv_len + frame_length], out[2 .. 2 + frame_length]);
        psDec.first_frame_after_reset = 0;
    }
    // MS→LR（丢包时 MS_pred = pred_prev_Q13）
    var ms_pred: [2]i32 = .{ sStereo.pred_prev_q13[0], sStereo.pred_prev_q13[1] };
    stereoMsToLR(sStereo, out_l[0 .. fl + 2], out_r[0 .. fl + 2], &ms_pred, psDec0.fs_khz, psDec0.frame_length);
}

/// 立体声一包解码：MS 预测 + 双通道 + MS→LR
pub fn decodePacketStereo(psDec0: *DecoderState, psDec1: *DecoderState, sStereo: *StereoDecState, rc: *rcmod.Rc, out_l: []i16, out_r: []i16) void {
    decodePreamble(psDec0, rc);
    decodePreamble(psDec1, rc);
    var ms_pred: [2]i32 = .{ 0, 0 };
    var decode_only_middle: i32 = 0;
    stereoDecodePred(rc, &ms_pred);
    {
        const fi: usize = @intCast(psDec0.n_frames_decoded);
        if (psDec0.lbrr_flag == 0 or psDec1.lbrr_flags[fi] == 1) {
            if (psDec1.vad_flags[fi] == 0) {
                decode_only_middle = stereoDecodeMidOnly(rc);
            } else {
                decode_only_middle = 0;
            }
        }
    }

    const fl: usize = @intCast(psDec0.frame_length);
    decodeFrame(psDec0, rc, out_l[2 .. fl + 2]);
    if (decode_only_middle == 0) {
        decodeFrame(psDec1, rc, out_r[2 .. fl + 2]);
    } else {
        @memset(out_r[2 .. fl + 2], 0);
    }
    stereoMsToLR(sStereo, out_l[0 .. fl + 2], out_r[0 .. fl + 2], &ms_pred, psDec0.fs_khz, psDec0.frame_length);
    psDec1.n_frames_decoded = psDec0.n_frames_decoded;
    sStereo.prev_decode_only_middle = decode_only_middle;
}

/// dec_API 帧前导：VAD/LBRR 位（单声道）
pub fn decodePreamble(psDec: *DecoderState, rc: *rcmod.Rc) void {
    if (psDec.n_frames_decoded == 0) {
        // VAD flags（每帧 1 位）
        var i: usize = 0;
        while (i < @as(usize, @intCast(psDec.n_frames_per_packet))) : (i += 1) {
            psDec.vad_flags[i] = @intCast(rc.decLog(1));
        }
        // LBRR flag
        psDec.lbrr_flag = @intCast(rc.decLog(1));
        @memset(&psDec.lbrr_flags, 0);
        if (psDec.lbrr_flag != 0) {
            if (psDec.n_frames_per_packet == 1) {
                psDec.lbrr_flags[0] = 1;
            } else {
                const lbrr_symbol: i32 = @as(i32, @intCast(rc.decIcdf(&st.silk_LBRR_flags_3_iCDF, 8))) + 1;
                i = 0;
                while (i < @as(usize, @intCast(psDec.n_frames_per_packet))) : (i += 1) {
                    psDec.lbrr_flags[i] = @intCast(RSHIFT(lbrr_symbol, @as(u5, @intCast(i))) & 1);
                }
            }
        }
        // 跳过 LBRR 数据
        i = 0;
        while (i < @as(usize, @intCast(psDec.n_frames_per_packet))) : (i += 1) {
            if (psDec.lbrr_flags[i] != 0) {
                const cond_coding: i32 = if (i > 0 and psDec.lbrr_flags[i - 1] != 0) CODE_CONDITIONALLY else CODE_INDEPENDENTLY;
                decodeIndices(psDec, rc, @intCast(i), 1, cond_coding);
                var pulses: [768]i16 = undefined;
                decodePulses(rc, pulses[0..@intCast(psDec.frame_length)], psDec.indices.signal_type, psDec.indices.quant_offset_type, psDec.frame_length);
            }
        }
    }
}

const SUB_FRAME_LENGTH_MS = 5;
const LTP_MEM_LENGTH_MS = 20;
const MIN_LPC_ORDER = 10;
const TYPE_NO_VOICE_ACTIVITY = 0;
const STEREO_QUANT_SUB_STEPS: i32 = 5;
const STEREO_INTERP_LEN_MS: i32 = 8;

// ---- Comfort Noise Generation（silk/CNG.c 移植）----
const CNG_GAIN_SMTH_Q16: i32 = 4634;
const CNG_GAIN_SMTH_THRESHOLD_Q16: i32 = 46396;
const CNG_NLSF_SMTH_Q16: i32 = 16348;
const CNG_BUF_MASK_MAX: i32 = 255;

/// CNG 状态（silk_CNG_struct）
pub const CngState = struct {
    cng_exc_buf_q14: [MAX_FRAME_LENGTH]i32 = undefined,
    cng_smth_nlsf_q15: [MAX_LPC_ORDER]i16 = undefined,
    cng_synth_state: [MAX_LPC_ORDER]i32 = undefined,
    cng_smth_gain_q16: i32 = 0,
    rand_seed: i32 = 0,
    fs_khz: i32 = 0,
};

inline fn SMULTT(a: i32, b: i32) i32 {
    return (a >> 16) * (b >> 16);
}

pub fn cngReset(psDec: *DecoderState) void {
    @memset(&psDec.s_cng.cng_exc_buf_q14, 0);
    @memset(&psDec.s_cng.cng_smth_nlsf_q15, 0);
    @memset(&psDec.s_cng.cng_synth_state, 0);
    psDec.s_cng.cng_smth_gain_q16 = 0;
    psDec.s_cng.rand_seed = 0;
}

/// silk_CNG_exc：随机激励
fn cngExc(exc_q14: []i32, exc_buf_q14: []const i32, length: usize, rand_seed: *i32) void {
    var seed: i32 = rand_seed.*;
    var exc_mask: i32 = CNG_BUF_MASK_MAX;
    while (exc_mask > length) exc_mask = RSHIFT(exc_mask, 1);
    for (0..length) |i| {
        seed = MLA_ovflw(RAND_INCREMENT, seed, RAND_MULTIPLIER);
        const idx: usize = @intCast(RSHIFT(seed, 24) & exc_mask);
        exc_q14[i] = exc_buf_q14[idx];
    }
    rand_seed.* = seed;
}

/// silk_CNG：丢包时加舒适噪声；无音段好帧更新参数。
pub fn cng(psDec: *DecoderState, ctrl: *const DecoderControl, frame: []i16, length: i32) void {
    const ps_cng = &psDec.s_cng;
    if (psDec.fs_khz != ps_cng.fs_khz) {
        cngReset(psDec);
        ps_cng.fs_khz = psDec.fs_khz;
    }
    if (psDec.loss_cnt == 0 and psDec.prev_signal_type == TYPE_NO_VOICE_ACTIVITY) {
        for (0..@intCast(psDec.lpc_order)) |i| {
            ps_cng.cng_smth_nlsf_q15[i] = @intCast(@as(i32, ps_cng.cng_smth_nlsf_q15[i]) + SMULWB(@as(i32, psDec.prev_nlsf_q15[i]) - @as(i32, ps_cng.cng_smth_nlsf_q15[i]), CNG_NLSF_SMTH_Q16));
        }
        var max_gain_q16: i32 = 0;
        var subfr: usize = 0;
        for (0..@intCast(psDec.nb_subfr)) |i| {
            if (ctrl.gains_q16[i] > max_gain_q16) {
                max_gain_q16 = ctrl.gains_q16[i];
                subfr = i;
            }
        }
        var k: usize = 0;
        while (k < ps_cng.cng_exc_buf_q14.len - @as(usize, @intCast(psDec.subfr_length))) : (k += 1) {
            ps_cng.cng_exc_buf_q14[k + @as(usize, @intCast(psDec.subfr_length))] = ps_cng.cng_exc_buf_q14[k];
        }
        @memcpy(ps_cng.cng_exc_buf_q14[0..@intCast(psDec.subfr_length)], psDec.exc_q14[subfr * @as(usize, @intCast(psDec.subfr_length)) ..][0..@intCast(psDec.subfr_length)]);
        for (0..@intCast(psDec.nb_subfr)) |i| {
            ps_cng.cng_smth_gain_q16 += SMULWB(ctrl.gains_q16[i] - ps_cng.cng_smth_gain_q16, CNG_GAIN_SMTH_Q16);
            if (SMULWW(ps_cng.cng_smth_gain_q16, CNG_GAIN_SMTH_THRESHOLD_Q16) > ctrl.gains_q16[i]) {
                ps_cng.cng_smth_gain_q16 = ctrl.gains_q16[i];
            }
        }
    }
    if (psDec.loss_cnt != 0) {
        const ulen: usize = @intCast(length);
        var cng_sig_q14: [MAX_FRAME_LENGTH + MAX_LPC_ORDER]i32 = undefined;
        var gain_q16: i32 = SMULWW(psDec.s_plc.rand_scale_q14, psDec.s_plc.prev_gain_q16[1]);
        if (gain_q16 >= (@as(i32, 1) << 21) or ps_cng.cng_smth_gain_q16 > (@as(i32, 1) << 23)) {
            gain_q16 = SMULTT(gain_q16, gain_q16);
            gain_q16 = SUB32_ovflw(SMULTT(ps_cng.cng_smth_gain_q16, ps_cng.cng_smth_gain_q16), LSHIFT(gain_q16, 5));
            gain_q16 = LSHIFT(sqrtApprox(gain_q16), 16);
        } else {
            gain_q16 = SMULWW(gain_q16, gain_q16);
            gain_q16 = SUB32_ovflw(SMULWW(ps_cng.cng_smth_gain_q16, ps_cng.cng_smth_gain_q16), LSHIFT(gain_q16, 5));
            gain_q16 = LSHIFT(sqrtApprox(gain_q16), 8);
        }
        const gain_q10: i32 = RSHIFT(gain_q16, 6);
        cngExc(cng_sig_q14[MAX_LPC_ORDER ..][0..ulen], ps_cng.cng_exc_buf_q14[0..], ulen, &ps_cng.rand_seed);
        var a_q12: [MAX_LPC_ORDER]i16 = undefined;
        nlsf2a(a_q12[0..@intCast(psDec.lpc_order)], ps_cng.cng_smth_nlsf_q15[0..@intCast(psDec.lpc_order)], psDec.lpc_order);
        @memcpy(cng_sig_q14[0..MAX_LPC_ORDER], ps_cng.cng_synth_state[0..MAX_LPC_ORDER]);
        const lo: usize = @intCast(psDec.lpc_order);
        for (0..ulen) |i| {
            var lpc_pred_q10: i32 = RSHIFT(psDec.lpc_order, 1);
            var j: usize = 1;
            while (j <= lo) : (j += 1) {
                lpc_pred_q10 = SMLAWB(lpc_pred_q10, cng_sig_q14[MAX_LPC_ORDER + i - j], a_q12[j - 1]);
            }
            cng_sig_q14[MAX_LPC_ORDER + i] = ADD_SAT32(cng_sig_q14[MAX_LPC_ORDER + i], LSHIFT_SAT32(lpc_pred_q10, 4));
            const add: i32 = SAT16(RSHIFT_ROUND(SMULWW(cng_sig_q14[MAX_LPC_ORDER + i], gain_q10), 8));
            frame[i] = @intCast(SAT16(@as(i32, frame[i]) + add));
        }
        @memcpy(ps_cng.cng_synth_state[0..MAX_LPC_ORDER], cng_sig_q14[ulen .. ulen + MAX_LPC_ORDER]);
    } else {
        @memset(ps_cng.cng_synth_state[0..@intCast(psDec.lpc_order)], 0);
    }
}

// ---- Packet Loss Concealment（silk/PLC.c 移植）----
inline fn SMLAWB_w(a: i32, b: i32, c: i32) i32 {
    return @as(i32, @truncate(@as(i64, a) + ((@as(i64, b) * @as(i32, @truncate(c))) >> 16)));
}
const PLC_BWE_COEF_Q16: i32 = @intFromFloat(0.99 * 65536.0 + 0.5);
const PLC_V_PITCH_GAIN_START_MIN_Q14: i32 = 11469;
const PLC_V_PITCH_GAIN_START_MAX_Q14: i32 = 15565;
const PLC_MAX_PITCH_LAG_MS: i32 = 18;
const PLC_RAND_BUF_SIZE: i32 = 128;
const PLC_RAND_BUF_MASK: i32 = PLC_RAND_BUF_SIZE - 1;
const PLC_LOG2_INV_LPC_GAIN_HIGH_THRES: i32 = 3;
const PLC_LOG2_INV_LPC_GAIN_LOW_THRES: i32 = 8;
const PLC_PITCH_DRIFT_FAC_Q16: i32 = 655;
const PLC_NB_ATT: usize = 2;
const PLC_HARM_ATT_Q15 = [PLC_NB_ATT]i16{ 32440, 31130 };
const PLC_RAND_ATTENUATE_V_Q15 = [PLC_NB_ATT]i16{ 31130, 26214 };
const PLC_RAND_ATTENUATE_UV_Q15 = [PLC_NB_ATT]i16{ 32440, 29491 };

/// PLC 状态（silk_PLC_struct）
pub const PlcState = struct {
    pitch_l_q8: i32 = 0,
    ltp_coef_q14: [LTP_ORDER]i16 = undefined,
    prev_lpc_q12: [MAX_LPC_ORDER]i16 = undefined,
    last_frame_lost: i32 = 0,
    rand_seed: i32 = 0,
    rand_scale_q14: i16 = 0,
    conc_energy: i32 = 0,
    conc_energy_shift: i32 = 0,
    prev_ltp_scale_q14: i16 = 0,
    prev_gain_q16: [2]i32 = undefined,
    fs_khz: i32 = 0,
    nb_subfr: i32 = 0,
    subfr_length: i32 = 0,
};

fn plcSumSqrShift(energy: *i32, shift: *i32, x: []const i16, len: i32) void {
    var shft: i32 = 31 - @as(i32, CLZ32(len));
    var nrg: i32 = len;
    var i: usize = 0;
    while (i + 1 < @as(usize, @intCast(len))) : (i += 2) {
        var nrg_tmp: u32 = @intCast(SMULBB(x[i], x[i]));
        nrg_tmp +%= @intCast(SMULBB(x[i + 1], x[i + 1]));
        nrg = @intCast(@as(u64, @intCast(@as(u32, @bitCast(nrg)))) + (@as(u64, nrg_tmp) >> @intCast(shft)));
    }
    if (i < @as(usize, @intCast(len))) {
        const nrg_tmp: u32 = @intCast(SMULBB(x[i], x[i]));
        nrg = @intCast(@as(u64, @intCast(@as(u32, @bitCast(nrg)))) + (@as(u64, nrg_tmp) >> @intCast(shft)));
    }
    shft = @max(0, shft + 3 - @as(i32, CLZ32(nrg)));
    nrg = 0;
    i = 0;
    while (i + 1 < @as(usize, @intCast(len))) : (i += 2) {
        var nrg_tmp: u32 = @intCast(SMULBB(x[i], x[i]));
        nrg_tmp +%= @intCast(SMULBB(x[i + 1], x[i + 1]));
        nrg = @intCast(@as(u64, @intCast(@as(u32, @bitCast(nrg)))) + (@as(u64, nrg_tmp) >> @intCast(shft)));
    }
    if (i < @as(usize, @intCast(len))) {
        const nrg_tmp: u32 = @intCast(SMULBB(x[i], x[i]));
        nrg = @intCast(@as(u64, @intCast(@as(u32, @bitCast(nrg)))) + (@as(u64, nrg_tmp) >> @intCast(shft)));
    }
    shift.* = shft;
    energy.* = nrg;
}

/// silk_PLC_Reset
pub fn plcReset(psDec: *DecoderState) void {
    psDec.s_plc.pitch_l_q8 = LSHIFT(psDec.frame_length, 8 - 1);
    psDec.s_plc.prev_gain_q16[0] = @as(i32, 1) << 16;
    psDec.s_plc.prev_gain_q16[1] = @as(i32, 1) << 16;
    psDec.s_plc.subfr_length = 20;
    psDec.s_plc.nb_subfr = 2;
}

/// silk_PLC_update：好帧后更新 PLC 状态
pub fn plcUpdate(psDec: *DecoderState, ctrl: *const DecoderControl) void {
    const ps_plc = &psDec.s_plc;
    psDec.prev_signal_type = psDec.indices.signal_type;
    var ltp_gain_q14: i32 = 0;
    if (psDec.indices.signal_type == TYPE_VOICED) {
        var j: usize = 0;
        while (j * @as(usize, @intCast(psDec.subfr_length)) < @as(usize, @intCast(ctrl.pitch_l[@intCast(psDec.nb_subfr - 1)]))) : (j += 1) {
            if (j == @as(usize, @intCast(psDec.nb_subfr))) break;
            var temp_ltp_gain_q14: i32 = 0;
            for (0..LTP_ORDER) |i| {
                temp_ltp_gain_q14 += @as(i32, ctrl.ltp_coef_q14[@as(usize, @intCast((psDec.nb_subfr - 1 - @as(i32, @intCast(j))) * LTP_ORDER)) + i]);
            }
            if (temp_ltp_gain_q14 > ltp_gain_q14) {
                ltp_gain_q14 = temp_ltp_gain_q14;
                const src_idx = @as(usize, @intCast((psDec.nb_subfr - 1 - @as(i32, @intCast(j))) * LTP_ORDER));
                @memcpy(ps_plc.ltp_coef_q14[0..LTP_ORDER], ctrl.ltp_coef_q14[src_idx .. src_idx + LTP_ORDER]);
                ps_plc.pitch_l_q8 = LSHIFT(ctrl.pitch_l[@intCast(psDec.nb_subfr - 1 - @as(i32, @intCast(j)))], 8);
            }
        }
        @memset(&ps_plc.ltp_coef_q14, 0);
        ps_plc.ltp_coef_q14[LTP_ORDER / 2] = @intCast(ltp_gain_q14);
        if (ltp_gain_q14 < PLC_V_PITCH_GAIN_START_MIN_Q14) {
            const tmp: i32 = LSHIFT(PLC_V_PITCH_GAIN_START_MIN_Q14, 10);
            const scale_q10: i32 = DIV32(tmp, @max(ltp_gain_q14, 1));
            for (0..LTP_ORDER) |i| {
                ps_plc.ltp_coef_q14[i] = @intCast(RSHIFT(SMULBB(ps_plc.ltp_coef_q14[i], scale_q10), 10));
            }
        } else if (ltp_gain_q14 > PLC_V_PITCH_GAIN_START_MAX_Q14) {
            const tmp: i32 = LSHIFT(PLC_V_PITCH_GAIN_START_MAX_Q14, 14);
            const scale_q14: i32 = DIV32(tmp, @max(ltp_gain_q14, 1));
            for (0..LTP_ORDER) |i| {
                ps_plc.ltp_coef_q14[i] = @intCast(RSHIFT(SMULBB(ps_plc.ltp_coef_q14[i], scale_q14), 14));
            }
        }
    } else {
        ps_plc.pitch_l_q8 = LSHIFT(SMULBB(psDec.fs_khz, 18), 8);
        @memset(&ps_plc.ltp_coef_q14, 0);
    }
    @memcpy(ps_plc.prev_lpc_q12[0..@intCast(psDec.lpc_order)], ctrl.pred_coef_q12[1][0..@intCast(psDec.lpc_order)]);
    ps_plc.prev_ltp_scale_q14 = @intCast(ctrl.ltp_scale_q14);
    @memcpy(ps_plc.prev_gain_q16[0..2], ctrl.gains_q16[@intCast(psDec.nb_subfr - 2) ..][0..2]);
    ps_plc.subfr_length = psDec.subfr_length;
    ps_plc.nb_subfr = psDec.nb_subfr;
}

/// silk_PLC_conceal：丢包隐藏帧合成
pub fn plcConceal(psDec: *DecoderState, ctrl: *DecoderControl, frame: []i16) void {
    const ps_plc = &psDec.s_plc;
    var s_ltp_q14: [MAX_FRAME_LENGTH + 2 * MAX_SUB_FRAME_LENGTH + MAX_FRAME_LENGTH]i32 = undefined;
    var s_ltp: [MAX_FRAME_LENGTH + 2 * MAX_SUB_FRAME_LENGTH]i16 = undefined;
    const prev_gain_q10: [2]i32 = .{ RSHIFT(ps_plc.prev_gain_q16[0], 6), RSHIFT(ps_plc.prev_gain_q16[1], 6) };

    if (psDec.first_frame_after_reset != 0) {
        @memset(&ps_plc.prev_lpc_q12, 0);
    }

    // 随机噪声分量能量
    var exc_buf: [2 * MAX_SUB_FRAME_LENGTH]i16 = undefined;
    var k: usize = 0;
    while (k < 2) : (k += 1) {
        for (0..@intCast(psDec.subfr_length)) |i| {
            exc_buf[k * @as(usize, @intCast(psDec.subfr_length)) + i] = @intCast(SAT16(RSHIFT(SMULWW(psDec.exc_q14[i + (k + @as(usize, @intCast(psDec.nb_subfr)) - 2) * @as(usize, @intCast(psDec.subfr_length))], prev_gain_q10[k]), 8)));
        }
    }
    var energy1: i32 = 0;
    var energy2: i32 = 0;
    var shift1: i32 = 0;
    var shift2: i32 = 0;
    plcSumSqrShift(&energy1, &shift1, exc_buf[0..@intCast(psDec.subfr_length)], psDec.subfr_length);
    plcSumSqrShift(&energy2, &shift2, exc_buf[@intCast(psDec.subfr_length) .. @intCast(2 * psDec.subfr_length)], psDec.subfr_length);

    var rand_ptr: usize = undefined;
    if (RSHIFT(energy1, shift2) < RSHIFT(energy2, shift1)) {
        rand_ptr = @max(0, (ps_plc.nb_subfr - 1) * ps_plc.subfr_length - PLC_RAND_BUF_SIZE);
    } else {
        rand_ptr = @max(0, ps_plc.nb_subfr * ps_plc.subfr_length - PLC_RAND_BUF_SIZE);
    }

    var b_q14 = &ps_plc.ltp_coef_q14;
    var rand_scale_q14: i32 = ps_plc.rand_scale_q14;

    const att_idx: usize = @intCast(@min(PLC_NB_ATT - 1, @as(usize, @intCast(psDec.loss_cnt))));
    const harm_gain_q15: i32 = PLC_HARM_ATT_Q15[att_idx];
    var rand_gain_q15: i32 = if (psDec.prev_signal_type == TYPE_VOICED) PLC_RAND_ATTENUATE_V_Q15[att_idx] else PLC_RAND_ATTENUATE_UV_Q15[att_idx];

    // LPC 隐藏：对上一 LPC 做 BWE
    bwexpander(ps_plc.prev_lpc_q12[0..@intCast(psDec.lpc_order)], psDec.lpc_order, PLC_BWE_COEF_Q16);
    var a_q12: [MAX_LPC_ORDER]i16 = undefined;
    @memcpy(a_q12[0..@intCast(psDec.lpc_order)], ps_plc.prev_lpc_q12[0..@intCast(psDec.lpc_order)]);

    if (psDec.loss_cnt == 0) {
        rand_scale_q14 = 1 << 14;
        if (psDec.prev_signal_type == TYPE_VOICED) {
            for (0..LTP_ORDER) |i| rand_scale_q14 -= @as(i32, b_q14[i]);
            rand_scale_q14 = @max(3277, rand_scale_q14);
            rand_scale_q14 = RSHIFT(SMULBB(@intCast(rand_scale_q14), ps_plc.prev_ltp_scale_q14), 14);
        } else {
            const inv_gain_q30 = lpcInversePredGain(ps_plc.prev_lpc_q12[0..@intCast(psDec.lpc_order)], psDec.lpc_order);
            var down_scale_q30: i32 = @min(RSHIFT(@as(i32, 1) << 30, PLC_LOG2_INV_LPC_GAIN_HIGH_THRES), inv_gain_q30);
            down_scale_q30 = @max(RSHIFT(@as(i32, 1) << 30, PLC_LOG2_INV_LPC_GAIN_LOW_THRES), down_scale_q30);
            down_scale_q30 = LSHIFT(down_scale_q30, PLC_LOG2_INV_LPC_GAIN_HIGH_THRES);
            rand_gain_q15 = RSHIFT(SMULWB(down_scale_q30, rand_gain_q15), 14);
        }
    }

    var rand_seed: i32 = ps_plc.rand_seed;
    var lag: i32 = RSHIFT_ROUND(ps_plc.pitch_l_q8, 8);
    var s_ltp_buf_idx: usize = @intCast(psDec.ltp_mem_length);

    // LTP 重白化
    const idx: i32 = psDec.ltp_mem_length - lag - psDec.lpc_order - @as(i32, LTP_ORDER) / 2;
    lpcAnalysisFilter(s_ltp[@intCast(idx)..], psDec.out_buf[@intCast(idx)..], a_q12[0..@intCast(psDec.lpc_order)], psDec.ltp_mem_length - idx, psDec.lpc_order);
    const inv_gain_q30: i32 = @min(inverse32VarQ(ps_plc.prev_gain_q16[1], 46), std.math.maxInt(i32) >> 1);
    for (@as(usize, @intCast(idx + psDec.lpc_order))..@as(usize, @intCast(psDec.ltp_mem_length))) |i| {
        s_ltp_q14[i] = SMULWB(inv_gain_q30, s_ltp[i]);
    }

    // LTP 合成滤波
    k = 0;
    while (k < @as(usize, @intCast(psDec.nb_subfr))) : (k += 1) {
        var pred_lag_ptr: usize = s_ltp_buf_idx - @as(usize, @intCast(lag)) + LTP_ORDER / 2;
        for (0..@intCast(psDec.subfr_length)) |_| {
            var ltp_pred_q12: i32 = 2;
            ltp_pred_q12 = SMLAWB_w(ltp_pred_q12, s_ltp_q14[pred_lag_ptr], b_q14[0]);
            ltp_pred_q12 = SMLAWB_w(ltp_pred_q12, s_ltp_q14[pred_lag_ptr - 1], b_q14[1]);
            ltp_pred_q12 = SMLAWB_w(ltp_pred_q12, s_ltp_q14[pred_lag_ptr - 2], b_q14[2]);
            ltp_pred_q12 = SMLAWB_w(ltp_pred_q12, s_ltp_q14[pred_lag_ptr - 3], b_q14[3]);
            ltp_pred_q12 = SMLAWB_w(ltp_pred_q12, s_ltp_q14[pred_lag_ptr - 4], b_q14[4]);
            pred_lag_ptr += 1;
            rand_seed = MLA_ovflw(RAND_INCREMENT, rand_seed, RAND_MULTIPLIER);
            const ridx: usize = @intCast(RSHIFT(rand_seed, 25) & PLC_RAND_BUF_MASK);
            s_ltp_q14[s_ltp_buf_idx] = LSHIFT(SMLAWB_w(ltp_pred_q12, psDec.exc_q14[rand_ptr + ridx], rand_scale_q14), 2);
            s_ltp_buf_idx += 1;
        }
        for (0..LTP_ORDER) |j| b_q14[j] = @intCast(RSHIFT(SMULBB(harm_gain_q15, b_q14[j]), 15));
        rand_scale_q14 = RSHIFT(SMULBB(rand_scale_q14, rand_gain_q15), 15);
        ps_plc.pitch_l_q8 = SMLAWB_w(ps_plc.pitch_l_q8, ps_plc.pitch_l_q8, PLC_PITCH_DRIFT_FAC_Q16);
        ps_plc.pitch_l_q8 = @min(ps_plc.pitch_l_q8, LSHIFT(SMULBB(PLC_MAX_PITCH_LAG_MS, psDec.fs_khz), 8));
        lag = RSHIFT_ROUND(ps_plc.pitch_l_q8, 8);
    }

    // LPC 合成滤波
    const s_lpc_q14_ptr: usize = @intCast(psDec.ltp_mem_length - MAX_LPC_ORDER);
    @memcpy(s_ltp_q14[s_lpc_q14_ptr .. s_lpc_q14_ptr + MAX_LPC_ORDER], psDec.s_lpc_q14_buf[0..MAX_LPC_ORDER]);
    for (0..@intCast(psDec.frame_length)) |i| {
        var lpc_pred_q10: i32 = RSHIFT(psDec.lpc_order, 1);
        var j: usize = 1;
        while (j <= @as(usize, @intCast(psDec.lpc_order))) : (j += 1) {
            lpc_pred_q10 = SMLAWB_w(lpc_pred_q10, s_ltp_q14[s_lpc_q14_ptr + MAX_LPC_ORDER + i - j], a_q12[j - 1]);
        }
        s_ltp_q14[s_lpc_q14_ptr + MAX_LPC_ORDER + i] = ADD_SAT32(s_ltp_q14[s_lpc_q14_ptr + MAX_LPC_ORDER + i], LSHIFT_SAT32(lpc_pred_q10, 4));
        frame[i] = @intCast(SAT16(RSHIFT_ROUND(SMULWW(s_ltp_q14[s_lpc_q14_ptr + MAX_LPC_ORDER + i], prev_gain_q10[1]), 8)));
    }

    const lpc_copy_start: usize = s_lpc_q14_ptr + @as(usize, @intCast(psDec.frame_length));
    @memcpy(psDec.s_lpc_q14_buf[0..MAX_LPC_ORDER], s_ltp_q14[lpc_copy_start .. lpc_copy_start + MAX_LPC_ORDER]);

    ps_plc.rand_seed = rand_seed;
    ps_plc.rand_scale_q14 = @intCast(rand_scale_q14);
    for (0..@as(usize, @intCast(psDec.nb_subfr))) |i| ctrl.pitch_l[i] = lag;
}

/// silk_SQRT_APPROX + CLZ_FRAC
fn sqrtApprox(x: i32) i32 {
    if (x <= 0) return 0;
    const lz: u32 = @intCast(CLZ32(x));
    const ror_n: u5 = @intCast((24 - @as(i32, @intCast(lz))) & 31);
    const xbits: u32 = @bitCast(x);
    const ror: u32 = (xbits >> ror_n) | (xbits << @as(u5, @intCast((32 - @as(u32, ror_n)) & 31)));
    const frac_q7: i32 = @as(i32, @bitCast(ror)) & 0x7f;
    var y: i32 = if ((lz & 1) != 0) 32768 else 46214;
    y >>= @intCast(lz / 2);
    y = SMLAWB(y, y, SMULBB(213, frac_q7));
    return y;
}

/// silk_PLC_glue_frames：丢失→正常边界能量淡入
fn glueFrames(psDec: *DecoderState, frame: []i16, length: i32) void {
    const ps_plc = &psDec.s_plc;
    if (psDec.loss_cnt != 0) {
        plcSumSqrShift(&ps_plc.conc_energy, &ps_plc.conc_energy_shift, frame[0..@intCast(length)], length);
        ps_plc.last_frame_lost = 1;
    } else {
        if (ps_plc.last_frame_lost != 0) {
            var energy: i32 = 0;
            var energy_shift: i32 = 0;
            plcSumSqrShift(&energy, &energy_shift, frame[0..@intCast(length)], length);
            if (energy_shift > ps_plc.conc_energy_shift) {
                ps_plc.conc_energy = RSHIFT(ps_plc.conc_energy, energy_shift - ps_plc.conc_energy_shift);
            } else if (energy_shift < ps_plc.conc_energy_shift) {
                energy = RSHIFT(energy, ps_plc.conc_energy_shift - energy_shift);
            }
            if (energy > ps_plc.conc_energy) {
                const lz: i32 = CLZ32(ps_plc.conc_energy) - 1;
                ps_plc.conc_energy = LSHIFT(ps_plc.conc_energy, lz);
                energy = RSHIFT(energy, @max(24 - lz, 0));
                const frac_q24: i32 = DIV32(ps_plc.conc_energy, @max(energy, 1));
                var gain_q16: i32 = LSHIFT(sqrtApprox(frac_q24), 4);
                const slope_q16: i32 = LSHIFT(DIV32_16((@as(i32, 1) << 16) - gain_q16, length), 2);
                var i: i32 = 0;
                while (i < length) : (i += 1) {
                    frame[@intCast(i)] = @intCast(SMULWB(gain_q16, frame[@intCast(i)]));
                    gain_q16 += slope_q16;
                    if (gain_q16 > @as(i32, 1) << 16) break;
                }
            }
        }
        ps_plc.last_frame_lost = 0;
    }
}

/// silk_PLC：丢包/正常调度
pub fn plc(psDec: *DecoderState, ctrl: *DecoderControl, frame: []i16, lost: i32) void {
    if (psDec.fs_khz != psDec.s_plc.fs_khz) {
        plcReset(psDec);
        psDec.s_plc.fs_khz = psDec.fs_khz;
    }
    if (lost != 0) {
        plcConceal(psDec, ctrl, frame);
        psDec.loss_cnt += 1;
    } else {
        plcUpdate(psDec, ctrl);
    }
}


const RESAMPLER_MAX_BATCH_SIZE_MS = 10;
const RESAMPLER_ORDER_FIR_12 = 8;
const RESAMPLER_DOWN_ORDER_FIR0 = 18;
const RESAMPLER_DOWN_ORDER_FIR1 = 24;
const RESAMPLER_DOWN_ORDER_FIR2 = 36;

pub const ResamplerState = struct {
    s_iir: [6]i32 = undefined,
    s_fir: [36]i16 = undefined,
    delay_buf: [96]i16 = undefined,
    resampler_function: i32 = 0,
    batch_size: i32 = 0,
    inv_ratio_q16: i32 = 0,
    fir_order: i32 = 0,
    fir_fracs: i32 = 0,
    fs_in_khz: i32 = 0,
    fs_out_khz: i32 = 0,
    input_delay: i32 = 0,
};

fn rateID(r: i32) usize {
    const v: i32 = (((r >> 12) - @intFromBool(r > 16000)) >> @intFromBool(r > 24000)) - 1;
    return @intCast(@min(v, 5));
}

pub fn resamplerInit(s: *ResamplerState, fs_hz_in: i32, fs_hz_out: i32) i32 {
    @memset(&s.s_iir, 0);
    @memset(&s.s_fir, 0);
    @memset(&s.delay_buf, 0);
    const delay_matrix_dec = [3][6]i8{
        .{ 4, 0, 2, 0, 0, 0 },
        .{ 0, 9, 4, 7, 4, 4 },
        .{ 0, 3, 12, 7, 7, 7 },
    };
    s.input_delay = delay_matrix_dec[rateID(fs_hz_in)][rateID(fs_hz_out)];
    s.fs_in_khz = @divTrunc(fs_hz_in, 1000);
    s.fs_out_khz = @divTrunc(fs_hz_out, 1000);
    s.batch_size = s.fs_in_khz * RESAMPLER_MAX_BATCH_SIZE_MS;

    var up2x: i32 = 0;
    if (fs_hz_out > fs_hz_in) {
        if (fs_hz_out == fs_hz_in * 2) {
            s.resampler_function = 1; // up2_HQ
        } else {
            s.resampler_function = 2; // IIR_FIR
            up2x = 1;
        }
    } else if (fs_hz_out < fs_hz_in) {
        s.resampler_function = 3; // down_FIR
        if (fs_hz_out * 4 == fs_hz_in * 3) {
            s.fir_fracs = 3;
            s.fir_order = RESAMPLER_DOWN_ORDER_FIR0;

        } else if (fs_hz_out * 3 == fs_hz_in * 2) {
            s.fir_fracs = 2;
            s.fir_order = RESAMPLER_DOWN_ORDER_FIR0;

        } else if (fs_hz_out * 2 == fs_hz_in) {
            s.fir_fracs = 1;
            s.fir_order = RESAMPLER_DOWN_ORDER_FIR1;

        } else if (fs_hz_out * 3 == fs_hz_in) {
            s.fir_fracs = 1;
            s.fir_order = RESAMPLER_DOWN_ORDER_FIR2;

        } else if (fs_hz_out * 4 == fs_hz_in) {
            s.fir_fracs = 1;
            s.fir_order = RESAMPLER_DOWN_ORDER_FIR2;

        } else {
            s.fir_fracs = 1;
            s.fir_order = RESAMPLER_DOWN_ORDER_FIR2;

        }
    } else {
        s.resampler_function = 0;
    }
    s.inv_ratio_q16 = LSHIFT(DIV32(LSHIFT(fs_hz_in, 14 + up2x), fs_hz_out), 2);
    while (SMULWW(s.inv_ratio_q16, fs_hz_out) < LSHIFT(fs_hz_in, up2x)) {
        s.inv_ratio_q16 += 1;
    }
    return 0;
}

fn up2HQ(s: *[6]i32, out: []i16, in_: []const i16, len: i32) void {
    var k: i32 = 0;
    while (k < len) : (k += 1) {
        const in32: i32 = LSHIFT(@as(i32, in_[@intCast(k)]), 10);
        var y: i32 = undefined;
        var x: i32 = undefined;
        var out1: i32 = undefined;
        var out2: i32 = undefined;

        y = in32 - s[0];
        x = SMULWB(y, st.silk_resampler_up2_hq_0[0]);
        out1 = s[0] + x;
        s[0] = in32 + x;
        y = out1 - s[1];
        x = SMULWB(y, st.silk_resampler_up2_hq_0[1]);
        out2 = s[1] + x;
        s[1] = out1 + x;
        y = out2 - s[2];
        x = SMLAWB(y, y, st.silk_resampler_up2_hq_0[2]);
        out1 = s[2] + x;
        s[2] = out2 + x;
        out[@intCast(2 * k)] = @intCast(SAT16(RSHIFT_ROUND(out1, 10)));

        y = in32 - s[3];
        x = SMULWB(y, st.silk_resampler_up2_hq_1[0]);
        out1 = s[3] + x;
        s[3] = in32 + x;
        y = out1 - s[4];
        x = SMULWB(y, st.silk_resampler_up2_hq_1[1]);
        out2 = s[4] + x;
        s[4] = out1 + x;
        y = out2 - s[5];
        x = SMLAWB(y, y, st.silk_resampler_up2_hq_1[2]);
        out1 = s[5] + x;
        s[5] = out2 + x;
        out[@intCast(2 * k + 1)] = @intCast(SAT16(RSHIFT_ROUND(out1, 10)));
    }
}

fn iirFirInterpol(out: []i16, buf: []const i16, max_index_q16: i32, index_increment_q16: i32) usize {
    var idx: usize = 0;
    var index_q16: i32 = 0;
    while (index_q16 < max_index_q16) : (index_q16 += index_increment_q16) {
        const table_index: usize = @intCast(SMULWB(@as(i32, @bitCast(index_q16)) & 0xFFFF, 12));
        const buf_idx: usize = @intCast(index_q16 >> 16);
        var res_q15: i32 = SMULBB(buf[buf_idx], st.silk_resampler_frac_FIR_12[table_index * 4 + 0]);
        res_q15 = SMLABB(res_q15, buf[buf_idx + 1], st.silk_resampler_frac_FIR_12[table_index * 4 + 1]);
        res_q15 = SMLABB(res_q15, buf[buf_idx + 2], st.silk_resampler_frac_FIR_12[table_index * 4 + 2]);
        res_q15 = SMLABB(res_q15, buf[buf_idx + 3], st.silk_resampler_frac_FIR_12[table_index * 4 + 3]);
        res_q15 = SMLABB(res_q15, buf[buf_idx + 4], st.silk_resampler_frac_FIR_12[(11 - table_index) * 4 + 3]);
        res_q15 = SMLABB(res_q15, buf[buf_idx + 5], st.silk_resampler_frac_FIR_12[(11 - table_index) * 4 + 2]);
        res_q15 = SMLABB(res_q15, buf[buf_idx + 6], st.silk_resampler_frac_FIR_12[(11 - table_index) * 4 + 1]);
        res_q15 = SMLABB(res_q15, buf[buf_idx + 7], st.silk_resampler_frac_FIR_12[(11 - table_index) * 4 + 0]);
        out[idx] = @intCast(SAT16(RSHIFT_ROUND(res_q15, 15)));
        idx += 1;
    }
    return idx;
}

fn iirFir(s: *ResamplerState, out: []i16, in_: []const i16, in_len: i32) void {
    var buf: [2 * 10 * 16 + RESAMPLER_ORDER_FIR_12]i16 = undefined;
    @memcpy(buf[0..RESAMPLER_ORDER_FIR_12], s.s_fir[0..RESAMPLER_ORDER_FIR_12]);
    const index_increment_q16 = s.inv_ratio_q16;
    var in_rem = in_len;
    var out_idx: usize = 0;
    var in_idx: usize = 0;
    while (true) {
        const n_samples_in: i32 = @min(in_rem, s.batch_size);
        up2HQ(&s.s_iir, buf[RESAMPLER_ORDER_FIR_12 ..], in_[in_idx .. in_idx + @as(usize, @intCast(n_samples_in))], n_samples_in);
        const max_index_q16 = LSHIFT(n_samples_in, 17);
        out_idx += iirFirInterpol(out[out_idx..], buf[0..], max_index_q16, index_increment_q16);
        in_idx += @as(usize, @intCast(n_samples_in));
        in_rem -= n_samples_in;
        if (in_rem > 0) {
            const src: usize = @intCast(n_samples_in << 1);
            @memcpy(buf[0..RESAMPLER_ORDER_FIR_12], buf[src .. src + RESAMPLER_ORDER_FIR_12]);
        } else break;
    }
    const src: usize = @intCast(n_samples_in_after(in_len, s.batch_size));
    @memcpy(s.s_fir[0..RESAMPLER_ORDER_FIR_12], buf[src .. src + RESAMPLER_ORDER_FIR_12]);
}

fn n_samples_in_after(in_len: i32, batch: i32) i32 {
    var rem = in_len;
    while (rem > batch) rem -= batch;
    return rem << 1;
}

pub fn resampler(s: *ResamplerState, out: []i16, in_: []const i16, in_len: i32) void {
    const n_samples: i32 = s.fs_in_khz - s.input_delay;
    @memcpy(s.delay_buf[@intCast(s.input_delay) .. @intCast(s.input_delay + n_samples)], in_[0..@intCast(n_samples)]);
    switch (s.resampler_function) {
        2 => { // IIR_FIR
            iirFir(s, out[0..], s.delay_buf[0..], s.fs_in_khz);
            iirFir(s, out[@intCast(s.fs_out_khz) ..], in_[@intCast(n_samples) .. @intCast(in_len)], in_len - s.fs_in_khz);
        },
        1 => { // up2_HQ wrapper
            up2HQ(&s.s_iir, out[0..], s.delay_buf[0..], s.fs_in_khz);
            up2HQ(&s.s_iir, out[@intCast(s.fs_out_khz) ..], in_[@intCast(n_samples) .. @intCast(in_len)], in_len - s.fs_in_khz);
        },
        0 => { // copy
            @memcpy(out[0..@intCast(s.fs_in_khz)], s.delay_buf[0..@intCast(s.fs_in_khz)]);
            @memcpy(out[@intCast(s.fs_out_khz) .. @intCast(s.fs_out_khz + (in_len - s.fs_in_khz))], in_[@intCast(n_samples) .. @intCast(in_len)]);
        },
        else => {},
    }
    @memcpy(s.delay_buf[0..@intCast(s.input_delay)], in_[@intCast(in_len - s.input_delay) .. @intCast(in_len)]);
}

/// stereo_dec_state
pub const StereoDecState = struct {
    pred_prev_q13: [2]i32 = .{ 0, 0 },
    s_mid: [2]i16 = .{ 0, 0 },
    s_side: [2]i16 = .{ 0, 0 },
    prev_decode_only_middle: i32 = 0,
};

/// silk_stereo_decode_pred：解码 MS 预测系数
pub fn stereoDecodePred(rc: *rcmod.Rc, pred_q13: *[2]i32) void {
    var ix: [2][3]i32 = undefined;
    const n: i32 = @intCast(rc.decIcdf(&st.silk_stereo_pred_joint_iCDF, 8));
    ix[0][2] = DIV32_16(n, 5);
    ix[1][2] = n - 5 * ix[0][2];
    var c: i32 = 0;
    while (c < 2) : (c += 1) {
        ix[@intCast(c)][0] = @intCast(rc.decIcdf(&st.silk_uniform3_iCDF, 8));
        ix[@intCast(c)][1] = @intCast(rc.decIcdf(&st.silk_uniform5_iCDF, 8));
    }
    c = 0;
    while (c < 2) : (c += 1) {
        ix[@intCast(c)][0] += 3 * ix[@intCast(c)][2];
        const low_q13: i32 = st.silk_stereo_pred_quant_Q13[@intCast(ix[@intCast(c)][0])];
        const step_q13: i32 = SMULWB(st.silk_stereo_pred_quant_Q13[@intCast(ix[@intCast(c)][0] + 1)] - low_q13, @as(i32, @intFromFloat(0.5 / @as(f64, @floatFromInt(STEREO_QUANT_SUB_STEPS)) * 65536.0 + 0.5)));
        pred_q13[@intCast(c)] = @intCast(SMLABB(low_q13, step_q13, 2 * ix[@intCast(c)][1] + 1));
    }
    pred_q13[0] -= pred_q13[1];
}

/// silk_stereo_decode_mid_only
pub fn stereoDecodeMidOnly(rc: *rcmod.Rc) i32 {
    return @intCast(rc.decIcdf(&st.silk_stereo_only_code_mid_iCDF, 8));
}

/// silk_stereo_MS_to_LR：MS → LR 转换
pub fn stereoMsToLR(state: *StereoDecState, x1: []i16, x2: []i16, pred_q13: []const i32, fs_khz: i32, frame_length: i32) void {
    const fl: usize = @intCast(frame_length);
    const interp_len: usize = @intCast(STEREO_INTERP_LEN_MS * fs_khz);
    // 缓冲
    x1[0] = state.s_mid[0];
    x1[1] = state.s_mid[1];
    x2[0] = state.s_side[0];
    x2[1] = state.s_side[1];
    state.s_mid[0] = x1[fl];
    state.s_mid[1] = x1[fl + 1];
    state.s_side[0] = x2[fl];
    state.s_side[1] = x2[fl + 1];

    var pred0_q13: i32 = state.pred_prev_q13[0];
    var pred1_q13: i32 = state.pred_prev_q13[1];
    const denom_q16: i32 = DIV32_16(@as(i32, 1) << 16, STEREO_INTERP_LEN_MS * fs_khz);
    const delta0_q13: i32 = RSHIFT_ROUND(SMULBB(pred_q13[0] - state.pred_prev_q13[0], denom_q16), 16);
    const delta1_q13: i32 = RSHIFT_ROUND(SMULBB(pred_q13[1] - state.pred_prev_q13[1], denom_q16), 16);
    var n: usize = 0;
    while (n < interp_len) : (n += 1) {
        pred0_q13 += delta0_q13;
        pred1_q13 += delta1_q13;
        var sum: i32 = LSHIFT(ADD_LSHIFT32(@as(i32, x1[n]) + @as(i32, x1[n + 2]), x1[n + 1], 1), 9);
        sum = SMLAWB(LSHIFT(@as(i32, x2[n + 1]), 8), sum, pred0_q13);
        sum = SMLAWB(sum, LSHIFT(@as(i32, x1[n + 1]), 11), pred1_q13);
        x2[n + 1] = @intCast(SAT16(RSHIFT_ROUND(sum, 8)));
    }
    pred0_q13 = pred_q13[0];
    pred1_q13 = pred_q13[1];
    n = interp_len;
    while (n < fl) : (n += 1) {
        var sum: i32 = LSHIFT(ADD_LSHIFT32(@as(i32, x1[n]) + @as(i32, x1[n + 2]), x1[n + 1], 1), 9);
        sum = SMLAWB(LSHIFT(@as(i32, x2[n + 1]), 8), sum, pred0_q13);
        sum = SMLAWB(sum, LSHIFT(@as(i32, x1[n + 1]), 11), pred1_q13);
        x2[n + 1] = @intCast(SAT16(RSHIFT_ROUND(sum, 8)));
    }
    state.pred_prev_q13[0] = pred_q13[0];
    state.pred_prev_q13[1] = pred_q13[1];

    n = 0;
    while (n < fl) : (n += 1) {
        const sum: i32 = @as(i32, x1[n + 1]) + @as(i32, x2[n + 1]);
        const diff: i32 = @as(i32, x1[n + 1]) - @as(i32, x2[n + 1]);
        x1[n + 1] = @intCast(SAT16(sum));
        x2[n + 1] = @intCast(SAT16(diff));
    }
}

/// silk_decoder_set_fs：设置内部采样率并初始化状态
pub fn decoderSetFs(psDec: *DecoderState, fs_khz: i32, fs_api_hz: i32) i32 {
    psDec.subfr_length = SMULBB(SUB_FRAME_LENGTH_MS, fs_khz);
    const frame_length = SMULBB(psDec.nb_subfr, psDec.subfr_length);

    if (psDec.fs_khz != fs_khz or psDec.fs_api_hz != fs_api_hz) {
        psDec.fs_api_hz = fs_api_hz;
    }

    if (psDec.fs_khz != fs_khz or frame_length != psDec.frame_length) {
        if (fs_khz == 8) {
            psDec.pitch_contour_icdf = if (psDec.nb_subfr == MAX_NB_SUBFR) &st.silk_pitch_contour_NB_iCDF else &st.silk_pitch_contour_10_ms_NB_iCDF;
        } else {
            psDec.pitch_contour_icdf = if (psDec.nb_subfr == MAX_NB_SUBFR) &st.silk_pitch_contour_iCDF else &st.silk_pitch_contour_10_ms_iCDF;
        }
        if (psDec.fs_khz != fs_khz) {
            psDec.ltp_mem_length = SMULBB(LTP_MEM_LENGTH_MS, fs_khz);
            if (fs_khz == 8 or fs_khz == 12) {
                psDec.lpc_order = MIN_LPC_ORDER;
                psDec.ps_nlsf_cb = &st.silk_NLSF_CB_NB_MB;
            } else {
                psDec.lpc_order = MAX_LPC_ORDER;
                psDec.ps_nlsf_cb = &st.silk_NLSF_CB_WB;
            }
            psDec.pitch_lag_low_bits_icdf = if (fs_khz == 16)
                &st.silk_uniform8_iCDF
            else if (fs_khz == 12)
                &st.silk_uniform6_iCDF
            else
                &st.silk_uniform4_iCDF;
            psDec.first_frame_after_reset = 1;
            psDec.lag_prev = 100;
            psDec.last_gain_index = 10;
            psDec.prev_signal_type = TYPE_NO_VOICE_ACTIVITY;
            @memset(&psDec.out_buf, 0);
            @memset(&psDec.s_lpc_q14_buf, 0);
        }
        psDec.fs_khz = fs_khz;
        psDec.frame_length = frame_length;
    }
    return 0;
}

const LOG2_SHELL_CODEC_FRAME_LENGTH = 4;
const MAX_NB_SHELL_BLOCKS = MAX_FRAME_LENGTH / SHELL_CODEC_FRAME_LENGTH;
const N_RATE_LEVELS = 10;
const SILK_MAX_PULSES = 16;

/// decode_split：把一个 shell 块的脉冲数分裂为两半
fn decodeSplit(p_child1: *i16, p_child2: *i16, rc: *rcmod.Rc, p: i32, shell_table: []const u8) void {
    if (p > 0) {
        p_child1.* = @intCast(rc.decIcdf(shell_table[st.silk_shell_code_table_offsets[@intCast(p)] ..], 8));
        p_child2.* = @intCast(p - @as(i32, p_child1.*));
    } else {
        p_child1.* = 0;
        p_child2.* = 0;
    }
}

/// silk_shell_decoder：16 采样 shell 块解码
fn shellDecoder(pulses0: *[16]i16, rc: *rcmod.Rc, pulses4: i32) void {
    var pulses1: [8]i16 = undefined;
    var pulses2: [4]i16 = undefined;
    var pulses3: [2]i16 = undefined;

    decodeSplit(&pulses3[0], &pulses3[1], rc, pulses4, &st.silk_shell_code_table3);

    decodeSplit(&pulses2[0], &pulses2[1], rc, pulses3[0], &st.silk_shell_code_table2);

    decodeSplit(&pulses1[0], &pulses1[1], rc, pulses2[0], &st.silk_shell_code_table1);
    decodeSplit(&pulses0[0], &pulses0[1], rc, pulses1[0], &st.silk_shell_code_table0);
    decodeSplit(&pulses0[2], &pulses0[3], rc, pulses1[1], &st.silk_shell_code_table0);

    decodeSplit(&pulses1[2], &pulses1[3], rc, pulses2[1], &st.silk_shell_code_table1);
    decodeSplit(&pulses0[4], &pulses0[5], rc, pulses1[2], &st.silk_shell_code_table0);
    decodeSplit(&pulses0[6], &pulses0[7], rc, pulses1[3], &st.silk_shell_code_table0);

    decodeSplit(&pulses2[2], &pulses2[3], rc, pulses3[1], &st.silk_shell_code_table2);

    decodeSplit(&pulses1[4], &pulses1[5], rc, pulses2[2], &st.silk_shell_code_table1);
    decodeSplit(&pulses0[8], &pulses0[9], rc, pulses1[4], &st.silk_shell_code_table0);
    decodeSplit(&pulses0[10], &pulses0[11], rc, pulses1[5], &st.silk_shell_code_table0);

    decodeSplit(&pulses1[6], &pulses1[7], rc, pulses2[3], &st.silk_shell_code_table1);
    decodeSplit(&pulses0[12], &pulses0[13], rc, pulses1[6], &st.silk_shell_code_table0);
    decodeSplit(&pulses0[14], &pulses0[15], rc, pulses1[7], &st.silk_shell_code_table0);
}

/// silk_decode_signs：为脉冲附加符号
fn decodeSigns(rc: *rcmod.Rc, pulses: []i16, length: i32, signal_type: i32, quant_offset_type: i32, sum_pulses: []const i32) void {
    var icdf: [2]u8 = undefined;
    icdf[1] = 0;
    var q_ptr: usize = 0;
    const s_idx = 7 * (quant_offset_type + (signal_type << 1));
    const icdf_ptr = st.silk_sign_iCDF[@as(usize, @intCast(s_idx)) ..];
    const nblocks = @as(usize, @intCast(RSHIFT(length + SHELL_CODEC_FRAME_LENGTH / 2, LOG2_SHELL_CODEC_FRAME_LENGTH)));
    var bi: usize = 0;
    while (bi < nblocks) : (bi += 1) {
        const p = sum_pulses[bi];
        if (p > 0) {
            icdf[0] = icdf_ptr[@min(@as(usize, @intCast(p & 0x1F)), 6)];
            var j: usize = 0;
            while (j < SHELL_CODEC_FRAME_LENGTH) : (j += 1) {
                if (pulses[q_ptr + j] > 0) {
                    pulses[q_ptr + j] *= @intCast(@as(i32, @intCast(rc.decIcdf(&icdf, 8))) * 2 - 1);
                }
            }
        }
        q_ptr += SHELL_CODEC_FRAME_LENGTH;
    }
}

/// silk_decode_pulses：解码激励脉冲
pub fn decodePulses(rc: *rcmod.Rc, pulses: []i16, signal_type: i32, quant_offset_type: i32, frame_length: i32) void {
    var sum_pulses: [MAX_NB_SHELL_BLOCKS]i32 = undefined;
    var n_lshifts: [MAX_NB_SHELL_BLOCKS]i32 = undefined;

    const rate_level_index: i32 = @intCast(rc.decIcdf(st.silk_rate_levels_iCDF[@as(usize, @intCast(RSHIFT(signal_type, 1))) * 9 ..], 8));

    var iter: i32 = RSHIFT(frame_length, LOG2_SHELL_CODEC_FRAME_LENGTH);
    if (iter * SHELL_CODEC_FRAME_LENGTH < frame_length) iter += 1;

    const cdf_ptr = st.silk_pulses_per_block_iCDF[@as(usize, @intCast(rate_level_index)) * 18 ..];
    var i: usize = 0;
    while (i < @as(usize, @intCast(iter))) : (i += 1) {
        n_lshifts[i] = 0;
        sum_pulses[i] = @intCast(rc.decIcdf(cdf_ptr, 8));
        while (sum_pulses[i] == SILK_MAX_PULSES + 1) {
            n_lshifts[i] += 1;
            const shift: usize = if (n_lshifts[i] == 10) 1 else 0;
            sum_pulses[i] = @intCast(rc.decIcdf(st.silk_pulses_per_block_iCDF[(N_RATE_LEVELS - 1) * 18 + shift ..], 8));
        }
    }

    // shell 解码
    i = 0;
    while (i < @as(usize, @intCast(iter))) : (i += 1) {
        const off = i * SHELL_CODEC_FRAME_LENGTH;
        if (sum_pulses[i] > 0) {
            const frame: *[16]i16 = @ptrCast(@alignCast(&pulses[off]));
            shellDecoder(frame, rc, sum_pulses[i]);
        } else {
            @memset(pulses[off .. off + SHELL_CODEC_FRAME_LENGTH], 0);
        }
    }

    // LSB 解码
    i = 0;
    while (i < @as(usize, @intCast(iter))) : (i += 1) {
        if (n_lshifts[i] > 0) {
            const n_ls = n_lshifts[i];
            var k: usize = 0;
            while (k < SHELL_CODEC_FRAME_LENGTH) : (k += 1) {
                var abs_q: i32 = pulses[i * SHELL_CODEC_FRAME_LENGTH + k];
                var j: i32 = 0;
                while (j < n_ls) : (j += 1) {
                    abs_q = LSHIFT(abs_q, 1);
                    abs_q += @intCast(rc.decIcdf(&st.silk_lsb_iCDF, 8));
                }
                pulses[i * SHELL_CODEC_FRAME_LENGTH + k] = @intCast(abs_q);
            }
            sum_pulses[i] |= n_ls << 5;
        }
    }

    // 符号解码
    decodeSigns(rc, pulses, frame_length, signal_type, quant_offset_type, &sum_pulses);
}
