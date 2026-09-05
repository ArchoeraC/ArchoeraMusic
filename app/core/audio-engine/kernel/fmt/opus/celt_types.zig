//! CELT 共享类型与常量（docs/audio-kernel-zig.md §9.2，P2）
//!
//! celt.zig（编排）与 pvq.zig（PVQ）共同引用，避免循环导入。

const std = @import("std");
const tables = @import("celt_tables.zig");
const opus = @import("kissfft.zig");

pub const CELT_SHORT_BLOCKSIZE = 120;
pub const CELT_OVERLAP = 120;
pub const CELT_MAX_LOG_BLOCKS = 3;
pub const CELT_MAX_FRAME_SIZE = 960;
pub const CELT_MAX_BANDS = 21;
pub const CELT_VECTORS = 11;
pub const CELT_ALLOC_STEPS = 6;
pub const CELT_FINE_OFFSET = 21;
pub const CELT_MAX_FINE_BITS = 8;
pub const CELT_NORM_SCALE = 16384;
pub const CELT_QTHETA_OFFSET = 4;
pub const CELT_QTHETA_OFFSET_TWOPHASE = 16;
pub const CELT_POSTFILTER_MINPERIOD = 15;
pub const CELT_ENERGY_SILENCE = -28.0;
pub const FLT_EPSILON = 1.1920929e-07;

pub const SPREAD_NONE: u8 = 0;
pub const SPREAD_LIGHT: u8 = 1;
pub const SPREAD_NORMAL: u8 = 2;
pub const SPREAD_AGGRESSIVE: u8 = 3;

/// 单声道块状态（跨帧保持）
pub const CeltBlock = struct {
    energy: [CELT_MAX_BANDS]f32 = undefined,
    lin_energy: [CELT_MAX_BANDS]f32 = undefined,
    error_energy: [CELT_MAX_BANDS]f32 = undefined,
    prev_energy: [2][CELT_MAX_BANDS]f32 = undefined,
    collapse_masks: [CELT_MAX_BANDS]u8 = undefined,
    buf: [2048 + CELT_OVERLAP]f32 = undefined,
    coeffs: [CELT_MAX_FRAME_SIZE]f32 = undefined,
    pf_period_new: i32 = 0,
    pf_gain_new: f32 = 0,
    pf_gains_new: [3]f32 = undefined,
    pf_tapset_new: i32 = 0,
    pf_period: i32 = 0,
    pf_gain: f32 = 0,
    pf_gains: [3]f32 = undefined,
    pf_tapset: i32 = 0,
    pf_period_old: i32 = 0,
    pf_gain_old: f32 = 0,
    pf_gains_old: [3]f32 = undefined,
    pf_tapset_old: i32 = 0,
    emph_coeff: f32 = 0,

    pub fn reset(self: *CeltBlock) void {
        for (0..CELT_MAX_BANDS) |j| {
            self.prev_energy[0][j] = CELT_ENERGY_SILENCE;
            self.prev_energy[1][j] = CELT_ENERGY_SILENCE;
            self.energy[j] = 0;
        }
        @memset(&self.buf, 0);
        @memset(&self.pf_gains, 0);
        @memset(&self.pf_gains_old, 0);
        @memset(&self.pf_gains_new, 0);
        self.pf_period = 0;
        self.pf_period_old = 0;
        self.pf_period_new = 0;
        self.pf_tapset = 0;
        self.pf_tapset_old = 0;
        self.pf_tapset_new = 0;
        // FFmpeg flush 语义：emph_coeff = 0 / deemph_weights[0]
        self.emph_coeff = 0.0 / tables.ff_opus_deemph_weights[0];
    }
};

/// CELT 帧上下文（跨帧保持块状态与种子）
pub const CeltFrame = struct {
    // 常量
    output_channels: i32 = 2,
    apply_phase_inv: i32 = 1,

    block: [2]CeltBlock = .{ .{}, .{} },
    /// libopus mdct lookup（48k：n=1920，maxshift=maxLM=3）
    mdct: opus.MdctLookup = undefined,
    channels: i32 = 0,
    size: i32 = 0,
    start_band: usize = 0,
    end_band: usize = CELT_MAX_BANDS,
    coded_bands: usize = 0,
    transient: bool = false,
    pfilter: bool = false,
    skip_band_floor: usize = 0,
    tf_select: bool = false,
    alloc_trim: i32 = 0,
    alloc_boost: [CELT_MAX_BANDS]i32 = undefined,
    blocks: u32 = 1,
    blocksize: usize = 0,
    silence: bool = false,
    anticollapse_needed: i32 = 0,
    anticollapse: bool = false,
    intensity_stereo: usize = 0,
    dual_stereo: bool = false,
    flushed: bool = false,
    seed: u32 = 0,

    spread: u8 = SPREAD_NORMAL,

    framebits: i32 = 0,
    remaining: i32 = 0,
    remaining2: i32 = 0,
    caps: [CELT_MAX_BANDS]i32 = undefined,
    fine_bits: [CELT_MAX_BANDS]i32 = undefined,
    fine_priority: [CELT_MAX_BANDS]bool = undefined,
    pulses: [CELT_MAX_BANDS]i32 = undefined,
    tf_change: [CELT_MAX_BANDS]i32 = undefined,

    pub fn flush(self: *CeltFrame) void {
        self.block[0].reset();
        self.block[1].reset();
        self.seed = 0;
        self.flushed = true;
        // 48k 全带宽模式：mdct n=1920，maxshift=maxLM=3（静态表位级权威）
        self.mdct = opus.mdctInitStatic();
    }
};

/// celt_rng：LCG 噪声（对齐 celt.h celt_rng）
pub fn celtRng(f: *CeltFrame) u32 {
    f.seed = 1664525 *% f.seed +% 1013904223;
    return f.seed;
}
/// celt_renormalize_vector
pub fn renormalizeVector(x: []f32, gain: f32) void {
    // libopus float：E = EPSILON + inner_prod(x,x)；t=VSHR32(E,...)=E；
    // g = MULT32_32_Q31(celt_rsqrt_norm32(t), gain) = (1/sqrt(E))*gain
    var s: f32 = 0;
    for (x) |v| s += v * v;
    const e = 1e-15 + s;
    const g = (1.0 / @sqrt(e)) * gain;
    for (x) |*v| v.* = g * v.*;
}
