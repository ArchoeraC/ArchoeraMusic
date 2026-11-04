// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! 频谱分析器 v2 —— 多分辨率 FFT + 对数频带 + dB 软膝 + 频谱通量节拍
//! （docs/spectrum-analyzer.md §4 / §9.1）
//!
//! 纯计算内核：不建线程、不做 I/O、不依赖 FFmpeg / C 壳。C 侧
//! `spectrum_service.c` 在独立频谱线程按「播放位置」取窗后调用
//! `era_spectrum_process`，结果经引擎事件推送。
//!
//! 算法要点：
//!   - 低频 40–crossover 用 `fft_low`（默认 8192）点 FFT，高频
//!     crossover–max 用 `fft_high`（默认 2048）点；交叉区做线性 crossfade；
//!   - Blackman 周期窗 + 相干增益 CG = 0.42，单边幅度 `2|X|/(N·CG)`；
//!   - `bins` 个对数带，带内平均功率开方；带窄于一个 bin 时在 log 频率轴
//!     对相邻 bin 功率插值；
//!   - dB 映射 `[-72, 0] → [0, 1]`，底部 6% smoothstep 软膝；
//!   - 节拍用对数幅度谱通量 + 最近 43 帧中位数自适应阈值 + 100ms 冷却；
//!   - 所有表在 create 时一次构建，每帧零分配；reset 只清状态。
//!
//! 命名自有（`era_` 前缀），不照搬 FFmpeg / librosa 等上游标识符。

const std = @import("std");

/// 分析器配置。字段与 `kernel/kernel.zig` 的 C 桥接调用逐字对齐。
pub const EraSpectrumConfig = struct {
    sample_rate: u32 = 48000,
    bins: u32 = 128,
    min_hz: f32 = 40.0,
    max_hz: f32 = 16000.0,
    fft_low: u32 = 8192,
    fft_high: u32 = 2048,
    crossover_hz: f32 = 300.0,
};

/// Blackman 周期窗相干增益（窗和 / N）。
const era_window_coherent_gain: f32 = 0.42;

/// dB 映射动态范围下界（-72dB → 0）。
const era_db_floor: f32 = -72.0;

/// 软膝宽度（映射后归一化坐标的底部 6%）。
const era_soft_knee: f32 = 0.06;

/// 节拍通量历史长度（43 帧 ≈ 2.15s @20Hz）。
const era_flux_history_len: usize = 43;

/// 节拍冷却帧数（100ms ≈ 2 帧 @50ms）。
const era_beat_cooldown_frames: u8 = 2;

/// 交叉区半宽（Hz）：crossover ± 50Hz 做线性 crossfade。
const era_crossover_half_width: f32 = 50.0;

/// 带内 bin 数不超过此值时用峰值功率，避免纯音被主瓣外的平均稀释。
///
/// 说明：严格按「平均功率」聚合时，一个 0dBFS 纯音若落在 2–3 个 bin 的窄带
/// 里，峰值会被平均拉到 ~0.88（约 -1.1dB），达不到 §9.1「0dBFS 正弦峰值
/// ≈ 1.0」的验收；而宽带若取峰值又会让白噪声随带宽抬升。折中：窄带取峰值
/// （纯音保真），宽带取平均功率（抑制带宽偏差）。
const era_narrow_band_bins: usize = 3;

/// 频带聚合方式。
const EraAggKind = enum {
    /// 带内 bin 中心数 > era_narrow_band_bins：平均功率。
    mean,
    /// 带内 bin 中心数 1..=era_narrow_band_bins：峰值功率（纯音保真）。
    peak,
    /// 带比一个 bin 还窄：相邻 bin 功率在 log 频率轴插值。
    interp,
};

/// 单个分辨率下的频带聚合计划（create 时一次算好）。
const EraBandAgg = struct {
    kind: EraAggKind = .interp,
    /// mean / peak：首个 bin；interp：下侧相邻 bin。
    k0: u32 = 1,
    /// mean / peak：末个 bin（含）。
    k1: u32 = 1,
    /// interp：频带中心在 k0..k0+1 之间的 log 频率位置 0..1。
    frac: f32 = 0.0,
};

/// 一个对数带的完整计划。
const EraBand = struct {
    low: EraBandAgg = .{},
    high: EraBandAgg = .{},
    /// 低频/高频估计的 crossfade 权重，w_low + w_high = 1。
    w_low: f32 = 1.0,
    w_high: f32 = 0.0,
};

/// 单分辨率 FFT 计划：表 + 每帧复用的工作区。
///
/// 表（bitrev / twiddle / window）在 create 时构建一次；re/im/mag 是每帧
/// 复用的缓冲，process 期间零分配。两个声道顺序复用同一份工作区。
const EraFftPlan = struct {
    n: usize,
    half: usize,
    bitrev: []u32,
    /// cos(-2πk/N)，k < N/2。
    cos_tab: []f32,
    /// sin(-2πk/N)，k < N/2（前向 FFT 的负号已并入）。
    sin_tab: []f32,
    window: []f32,
    re: []f32,
    im: []f32,
    /// 单边幅度谱，长度 N/2 + 1。
    mag: []f32,
};

/// 频谱分析器实例（不透明于 C 侧 `ZkSpectrum`）。
pub const EraSpectrum = struct {
    allocator: std.mem.Allocator,
    sample_rate: u32,
    bins: u32,
    min_hz: f32,
    max_hz: f32,
    crossover_hz: f32,
    fft_low: u32,
    fft_high: u32,
    low: EraFftPlan,
    high: EraFftPlan,
    /// 对数带边界，长度 bins + 1（Hz）。
    edges: []f32,
    /// 每个输出带的聚合计划，长度 bins。
    bands: []EraBand,
    /// 上一帧 L/R 平均后的带幅度（节拍通量用），长度 bins。
    prev_mag: []f32,
    /// 本帧左右声道带幅度暂存，长度 bins。
    band_l: []f32,
    band_r: []f32,
    has_prev: bool = false,
    flux_hist: [era_flux_history_len]f32 = @splat(0.0),
    flux_pos: usize = 0,
    flux_count: usize = 0,
    cooldown: u8 = 0,
};

// ---------------------------------------------------------------------------
// FFT 计划：建表 / 装窗 / 基 2 Cooley-Tukey / 单边幅度
// ---------------------------------------------------------------------------

fn eraIsPowerOfTwo(v: u32) bool {
    return v >= 2 and (v & (v - 1)) == 0;
}

fn eraLog2Int(v: usize) usize {
    var bits: usize = 0;
    var t = v;
    while (t > 1) : (t >>= 1) bits += 1;
    return bits;
}

fn eraFloorToUsize(x: f64) usize {
    if (x <= 0.0) return 0;
    return @intFromFloat(@floor(x));
}

fn eraPlanInit(allocator: std.mem.Allocator, n: usize) !EraFftPlan {
    if (n < 16 or !eraIsPowerOfTwo(@intCast(n))) return error.InvalidArgument;
    const half = n / 2;

    const bitrev = try allocator.alloc(u32, n);
    errdefer allocator.free(bitrev);
    const cos_tab = try allocator.alloc(f32, half);
    errdefer allocator.free(cos_tab);
    const sin_tab = try allocator.alloc(f32, half);
    errdefer allocator.free(sin_tab);
    const window = try allocator.alloc(f32, n);
    errdefer allocator.free(window);
    const re = try allocator.alloc(f32, n);
    errdefer allocator.free(re);
    const im = try allocator.alloc(f32, n);
    errdefer allocator.free(im);
    const mag = try allocator.alloc(f32, half + 1);
    errdefer allocator.free(mag);

    const bits = eraLog2Int(n);
    for (0..n) |i| {
        var r: u32 = 0;
        var v = i;
        var b: usize = 0;
        while (b < bits) : (b += 1) {
            r = (r << 1) | @as(u32, @intCast(v & 1));
            v >>= 1;
        }
        bitrev[i] = r;
    }

    const nf: f64 = @floatFromInt(n);
    for (0..half) |k| {
        const angle = -2.0 * std.math.pi * @as(f64, @floatFromInt(k)) / nf;
        cos_tab[k] = @floatCast(@cos(angle));
        sin_tab[k] = @floatCast(@sin(angle));
    }

    // Blackman 周期窗：0.42 - 0.5cos(2πn/N) + 0.08cos(4πn/N)。
    for (0..n) |i| {
        const t = 2.0 * std.math.pi * @as(f64, @floatFromInt(i)) / nf;
        window[i] = @floatCast(0.42 - 0.5 * @cos(t) + 0.08 * @cos(2.0 * t));
    }

    @memset(re, 0.0);
    @memset(im, 0.0);
    @memset(mag, 0.0);

    return .{
        .n = n,
        .half = half,
        .bitrev = bitrev,
        .cos_tab = cos_tab,
        .sin_tab = sin_tab,
        .window = window,
        .re = re,
        .im = im,
        .mag = mag,
    };
}

fn eraPlanDeinit(plan: *EraFftPlan, allocator: std.mem.Allocator) void {
    allocator.free(plan.bitrev);
    allocator.free(plan.cos_tab);
    allocator.free(plan.sin_tab);
    allocator.free(plan.window);
    allocator.free(plan.re);
    allocator.free(plan.im);
    allocator.free(plan.mag);
    plan.n = 0;
    plan.half = 0;
}

/// 把 `src` 装进 N 点窗口：取最近 min(src.len, N) 个样本，不足部分前端补零。
fn eraPlanLoad(plan: *EraFftPlan, src: []const f32) void {
    const n = plan.n;
    const re = plan.re;
    const im = plan.im;
    const win = plan.window;

    const copy = @min(src.len, n);
    const pad = n - copy;
    @memset(re[0..pad], 0.0);
    @memset(im[0..pad], 0.0);
    const start = src.len - copy;
    var j: usize = 0;
    while (j < copy) : (j += 1) {
        const idx = pad + j;
        re[idx] = src[start + j] * win[idx];
        im[idx] = 0.0;
    }
}

/// 原地基 2 Cooley-Tukey 前向 FFT（查表位反转 + 查表旋转因子）。
fn eraPlanForward(plan: *EraFftPlan) void {
    const n = plan.n;
    const re = plan.re;
    const im = plan.im;

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const j = plan.bitrev[i];
        if (j > i) {
            const tr = re[i];
            re[i] = re[j];
            re[j] = tr;
            const ti = im[i];
            im[i] = im[j];
            im[j] = ti;
        }
    }

    var len: usize = 2;
    while (len <= n) : (len *= 2) {
        const half = len / 2;
        const stride = n / len;
        var start: usize = 0;
        while (start < n) : (start += len) {
            var k: usize = 0;
            while (k < half) : (k += 1) {
                const tw = k * stride;
                const wr = plan.cos_tab[tw];
                const wi = plan.sin_tab[tw];
                const a = start + k;
                const b = a + half;
                const xr = re[b] * wr - im[b] * wi;
                const xi = re[b] * wi + im[b] * wr;
                re[b] = re[a] - xr;
                im[b] = im[a] - xi;
                re[a] += xr;
                im[a] += xi;
            }
        }
    }
}

/// 由复谱计算单边幅度：`2|X|/(N·CG)`，0dBFS 正弦（bin 中心）≈ 1.0。
/// 峰值夹到 [0, 1]；NaN/Inf 兜底为 0/1，绝不把脏值传下去。
fn eraPlanMagnitude(plan: *EraFftPlan) void {
    const n = plan.n;
    const half = plan.half;
    const nf: f32 = @floatFromInt(n);
    const base = 2.0 / (nf * era_window_coherent_gain);
    var k: usize = 0;
    while (k <= half) : (k += 1) {
        const p = plan.re[k] * plan.re[k] + plan.im[k] * plan.im[k];
        var m = base * @sqrt(p);
        // DC 与 Nyquist 只有单边，单边系数应为 1（频带不会用到，保守处理）。
        if (k == 0 or k == half) m *= 0.5;
        if (!(m >= 0.0)) m = 0.0; // NaN
        if (m > 1.0) m = 1.0;
        plan.mag[k] = m;
    }
}

// ---------------------------------------------------------------------------
// 频带聚合 / dB 映射
// ---------------------------------------------------------------------------

/// 构建一个分辨率下的频带聚合计划。
///
/// - 带内至少一个 bin 中心：1..=era_narrow_band_bins 取峰值，更宽取平均功率；
/// - 带比一个 bin 还窄：在 log 频率轴上对相邻 bin 功率插值。
fn eraBuildAgg(bin_hz: f64, half: usize, f_lo: f64, f_hi: f64) EraBandAgg {
    if (bin_hz <= 0.0 or half < 2) {
        return .{ .kind = .interp, .k0 = 1, .k1 = 1, .frac = 0.0 };
    }

    var k_lo: usize = 1;
    const klo_f = @ceil(f_lo / bin_hz);
    if (klo_f > 1.0) k_lo = eraFloorToUsize(klo_f);
    if (k_lo < 1) k_lo = 1;

    var k_hi: usize = 0;
    const khi_f = @floor(f_hi / bin_hz);
    if (khi_f > 0.0) k_hi = eraFloorToUsize(khi_f);
    if (k_hi > half) k_hi = half;

    if (k_lo <= k_hi) {
        const count = k_hi - k_lo + 1;
        const kind: EraAggKind = if (count <= era_narrow_band_bins) .peak else .mean;
        return .{
            .kind = kind,
            .k0 = @intCast(k_lo),
            .k1 = @intCast(k_hi),
            .frac = 0.0,
        };
    }

    // 带内没有 bin 中心：取频带几何中心，在相邻 bin 的 log 频率间插值功率。
    const fc = @sqrt(f_lo * f_hi);
    var k0: usize = 1;
    const k0f = @floor(fc / bin_hz);
    if (k0f > 1.0) k0 = eraFloorToUsize(k0f);
    if (k0 >= half) k0 = half - 1;
    if (k0 < 1) k0 = 1;

    const f0 = @as(f64, @floatFromInt(k0)) * bin_hz;
    const f1 = @as(f64, @floatFromInt(k0 + 1)) * bin_hz;
    var frac: f64 = 0.0;
    if (f1 > f0 and fc > 0.0) {
        frac = (@log(fc) - @log(f0)) / (@log(f1) - @log(f0));
    }
    if (frac < 0.0) frac = 0.0;
    if (frac > 1.0) frac = 1.0;

    return .{
        .kind = .interp,
        .k0 = @intCast(k0),
        .k1 = @intCast(k0),
        .frac = @floatCast(frac),
    };
}

/// 按计划从单边幅度谱取一个带值（线性幅度）。
fn eraAggValue(agg: EraBandAgg, mags: []const f32) f32 {
    switch (agg.kind) {
        .mean => {
            var sum: f32 = 0.0;
            var k = agg.k0;
            while (k <= agg.k1) : (k += 1) {
                const m = mags[k];
                sum += m * m;
            }
            const count: f32 = @floatFromInt(agg.k1 - agg.k0 + 1);
            return @sqrt(sum / count);
        },
        .peak => {
            var best: f32 = 0.0;
            var k = agg.k0;
            while (k <= agg.k1) : (k += 1) {
                if (mags[k] > best) best = mags[k];
            }
            return best;
        },
        .interp => {
            const m0 = mags[agg.k0];
            const m1 = mags[agg.k0 + 1];
            const p0 = m0 * m0;
            const p1 = m1 * m1;
            const p = p0 + (p1 - p0) * agg.frac;
            return @sqrt(@max(p, 0.0));
        },
    }
}

fn eraBandValue(band: *const EraBand, low_mag: []const f32, high_mag: []const f32) f32 {
    var v: f32 = 0.0;
    if (band.w_low > 0.0) v += band.w_low * eraAggValue(band.low, low_mag);
    if (band.w_high > 0.0) v += band.w_high * eraAggValue(band.high, high_mag);
    if (v < 0.0) v = 0.0;
    if (v > 1.0) v = 1.0;
    return v;
}

/// dB → [0,1]，底部 6% smoothstep 软膝（不做硬清零）。
fn eraMapDb(amp: f32) f32 {
    const db = 20.0 * @log10(amp + 1e-12);
    var t = (db - era_db_floor) / (0.0 - era_db_floor);
    if (t < 0.0) t = 0.0;
    if (t > 1.0) t = 1.0;
    const gate = @min(t / era_soft_knee, 1.0);
    return t * gate * gate * (3.0 - 2.0 * gate);
}

// ---------------------------------------------------------------------------
// 生命周期
// ---------------------------------------------------------------------------

fn eraValidateConfig(cfg: EraSpectrumConfig) !void {
    if (cfg.sample_rate == 0) return error.InvalidArgument;
    if (cfg.bins == 0 or cfg.bins > 1024) return error.InvalidArgument;
    if (!(cfg.min_hz > 0.0) or !(cfg.max_hz > cfg.min_hz)) return error.InvalidArgument;
    const nyquist = @as(f32, @floatFromInt(cfg.sample_rate)) * 0.5;
    if (cfg.max_hz >= nyquist) return error.InvalidArgument;
    if (!eraIsPowerOfTwo(cfg.fft_low) or cfg.fft_low < 16) return error.InvalidArgument;
    if (!eraIsPowerOfTwo(cfg.fft_high) or cfg.fft_high < 16) return error.InvalidArgument;
    if (!(cfg.crossover_hz > 0.0)) return error.InvalidArgument;
}

/// 创建频谱分析器（表一次建好；每帧零分配）。
pub fn era_spectrum_create(allocator: std.mem.Allocator, cfg: EraSpectrumConfig) !*EraSpectrum {
    try eraValidateConfig(cfg);

    const bins: usize = cfg.bins;
    const n_low: usize = cfg.fft_low;
    const n_high: usize = cfg.fft_high;

    var low = try eraPlanInit(allocator, n_low);
    errdefer eraPlanDeinit(&low, allocator);
    var high = try eraPlanInit(allocator, n_high);
    errdefer eraPlanDeinit(&high, allocator);

    const edges = try allocator.alloc(f32, bins + 1);
    errdefer allocator.free(edges);
    const bands = try allocator.alloc(EraBand, bins);
    errdefer allocator.free(bands);
    const prev_mag = try allocator.alloc(f32, bins);
    errdefer allocator.free(prev_mag);
    const band_l = try allocator.alloc(f32, bins);
    errdefer allocator.free(band_l);
    const band_r = try allocator.alloc(f32, bins);
    errdefer allocator.free(band_r);

    const min_hz: f64 = cfg.min_hz;
    const max_hz: f64 = cfg.max_hz;
    const log_ratio = @log(max_hz / min_hz);
    for (0..bins + 1) |i| {
        const frac = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(bins));
        edges[i] = @floatCast(min_hz * @exp(log_ratio * frac));
    }

    const sample_rate: f64 = @floatFromInt(cfg.sample_rate);
    const bin_hz_low = sample_rate / @as(f64, @floatFromInt(n_low));
    const bin_hz_high = sample_rate / @as(f64, @floatFromInt(n_high));

    var crossover = cfg.crossover_hz;
    if (crossover < cfg.min_hz) crossover = cfg.min_hz;
    if (crossover > cfg.max_hz) crossover = cfg.max_hz;
    var fade_lo = crossover - era_crossover_half_width;
    var fade_hi = crossover + era_crossover_half_width;
    if (fade_lo < cfg.min_hz) fade_lo = cfg.min_hz;
    if (fade_hi > cfg.max_hz) fade_hi = cfg.max_hz;

    for (0..bins) |i| {
        const f_lo: f64 = edges[i];
        const f_hi: f64 = edges[i + 1];
        const fc = @sqrt(f_lo * f_hi);

        var w_high: f32 = 0.0;
        if (fade_hi > fade_lo) {
            const w = (fc - fade_lo) / (fade_hi - fade_lo);
            w_high = @floatCast(@min(@max(w, 0.0), 1.0));
        } else if (fc >= crossover) {
            w_high = 1.0;
        }

        bands[i] = .{
            .low = eraBuildAgg(bin_hz_low, n_low / 2, f_lo, f_hi),
            .high = eraBuildAgg(bin_hz_high, n_high / 2, f_lo, f_hi),
            .w_low = 1.0 - w_high,
            .w_high = w_high,
        };
    }

    @memset(prev_mag, 0.0);
    @memset(band_l, 0.0);
    @memset(band_r, 0.0);

    const self = try allocator.create(EraSpectrum);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .sample_rate = cfg.sample_rate,
        .bins = cfg.bins,
        .min_hz = cfg.min_hz,
        .max_hz = cfg.max_hz,
        .crossover_hz = crossover,
        .fft_low = cfg.fft_low,
        .fft_high = cfg.fft_high,
        .low = low,
        .high = high,
        .edges = edges,
        .bands = bands,
        .prev_mag = prev_mag,
        .band_l = band_l,
        .band_r = band_r,
    };
    return self;
}

/// 销毁（表与每帧缓冲一并释放）。
pub fn era_spectrum_destroy(self: *EraSpectrum) void {
    const a = self.allocator;
    eraPlanDeinit(&self.low, a);
    eraPlanDeinit(&self.high, a);
    a.free(self.edges);
    a.free(self.bands);
    a.free(self.prev_mag);
    a.free(self.band_l);
    a.free(self.band_r);
    self.sample_rate = 0;
    a.destroy(self);
}

/// 清空帧间状态（seek / 切歌 / 会话重建）；表保留。
pub fn era_spectrum_reset(self: *EraSpectrum) void {
    @memset(self.prev_mag, 0.0);
    @memset(&self.flux_hist, 0.0);
    self.flux_pos = 0;
    self.flux_count = 0;
    self.cooldown = 0;
    self.has_prev = false;
}

/// 输出频段数。
pub fn era_spectrum_bins(self: *const EraSpectrum) u32 {
    return self.bins;
}

/// 分析器采样率。
pub fn era_spectrum_sample_rate(self: *const EraSpectrum) u32 {
    return self.sample_rate;
}

// ---------------------------------------------------------------------------
// 每帧处理
// ---------------------------------------------------------------------------

/// 节拍状态更新：把本帧通量推进历史，返回 0..1 脉冲强度。
///
/// 阈值 = 最近 43 帧中位数 × 1.5 + 0.02；强度按窗口内峰值归一化；
/// 冷却 2 帧（100ms @50ms 帧）。首帧（reset 后）只建立基线，不触发。
fn eraBeatStep(self: *EraSpectrum, flux: f32, had_prev: bool) f32 {
    self.flux_hist[self.flux_pos] = flux;
    self.flux_pos = (self.flux_pos + 1) % era_flux_history_len;
    if (self.flux_count < era_flux_history_len) self.flux_count += 1;

    if (!had_prev) return 0.0;

    var sorted: [era_flux_history_len]f32 = undefined;
    const count = self.flux_count;
    var i: usize = 0;
    while (i < count) : (i += 1) sorted[i] = self.flux_hist[i];

    // 43 项插入排序：固定小数组，避免引入排序器依赖。
    var a: usize = 1;
    while (a < count) : (a += 1) {
        const v = sorted[a];
        var b = a;
        while (b > 0 and sorted[b - 1] > v) : (b -= 1) {
            sorted[b] = sorted[b - 1];
        }
        sorted[b] = v;
    }

    const median = sorted[count / 2];
    const threshold = median * 1.5 + 0.02;
    var peak = threshold;
    for (sorted[0..count]) |v| {
        if (v > peak) peak = v;
    }

    if (self.cooldown > 0) {
        self.cooldown -= 1;
        return 0.0;
    }
    if (flux <= threshold) return 0.0;

    self.cooldown = era_beat_cooldown_frames;
    const span = peak - threshold;
    if (span <= 0.0) return 0.0;
    var strength = (flux - threshold) / span;
    if (strength < 0.0) strength = 0.0;
    if (strength > 1.0) strength = 1.0;
    return strength;
}

/// 处理一帧。
///
/// `l` / `r` 为最近 `frames` 个每声道样本（窗口终点 = 当前播放位置），
/// `frames` 可小于 `fft_low`，不足部分在**前端补零**；超过 `fft_low` 时取
/// 最近 `fft_low` 个。`out_l` / `out_r` 长度 = bins，写 [0,1]。
/// 返回本帧节拍强度 0..1。
pub fn era_spectrum_process(
    self: *EraSpectrum,
    l: []const f32,
    r: []const f32,
    out_l: []f32,
    out_r: []f32,
) f32 {
    const bins: usize = self.bins;
    if (out_l.len < bins or out_r.len < bins) return 0.0;

    if (l.len == 0 or r.len == 0) {
        @memset(out_l[0..bins], 0.0);
        @memset(out_r[0..bins], 0.0);
        return 0.0;
    }
    const frames = @min(l.len, r.len);

    // 左声道：低频 / 高频两套 FFT（顺序复用工作区）。
    eraPlanLoad(&self.low, l[0..frames]);
    eraPlanForward(&self.low);
    eraPlanMagnitude(&self.low);
    eraPlanLoad(&self.high, l[0..frames]);
    eraPlanForward(&self.high);
    eraPlanMagnitude(&self.high);
    for (self.bands, 0..) |*band, i| {
        self.band_l[i] = eraBandValue(band, self.low.mag, self.high.mag);
    }

    // 右声道。
    eraPlanLoad(&self.low, r[0..frames]);
    eraPlanForward(&self.low);
    eraPlanMagnitude(&self.low);
    eraPlanLoad(&self.high, r[0..frames]);
    eraPlanForward(&self.high);
    eraPlanMagnitude(&self.high);
    for (self.bands, 0..) |*band, i| {
        self.band_r[i] = eraBandValue(band, self.low.mag, self.high.mag);
    }

    // 通量（L/R 平均带幅度）+ dB 映射输出。
    const had_prev = self.has_prev;
    var flux: f32 = 0.0;
    for (0..bins) |i| {
        const a = self.band_l[i];
        const b = self.band_r[i];
        const comb = 0.5 * (a + b);
        if (had_prev) {
            const d = @log(1.0 + comb) - @log(1.0 + self.prev_mag[i]);
            if (d > 0.0) flux += d;
        }
        self.prev_mag[i] = comb;
        out_l[i] = eraMapDb(a);
        out_r[i] = eraMapDb(b);
    }
    self.has_prev = true;

    return eraBeatStep(self, flux, had_prev);
}

// ---------------------------------------------------------------------------
// 单元测试
// ---------------------------------------------------------------------------

const testing = std.testing;

fn fillSine(buf: []f32, freq: f32, sample_rate: u32, amplitude: f32) void {
    const w = 2.0 * std.math.pi * @as(f64, freq) / @as(f64, @floatFromInt(sample_rate));
    for (buf, 0..) |*v, i| {
        v.* = amplitude * @as(f32, @floatCast(@sin(w * @as(f64, @floatFromInt(i)))));
    }
}

fn expectedBand(freq: f32, min_hz: f32, max_hz: f32, bins: u32) usize {
    const ratio = @log(@as(f64, freq) / @as(f64, min_hz)) /
        @log(@as(f64, max_hz) / @as(f64, min_hz));
    const raw = @floor(ratio * @as(f64, @floatFromInt(bins)));
    if (raw < 0.0) return 0;
    const idx: usize = @intFromFloat(raw);
    return @min(idx, @as(usize, bins - 1));
}

fn peakBand(vals: []const f32) usize {
    var best: usize = 0;
    for (vals, 0..) |v, i| {
        if (v > vals[best]) best = i;
    }
    return best;
}

fn bandCenter(cfg: EraSpectrumConfig, i: usize) f64 {
    const min_hz: f64 = cfg.min_hz;
    const max_hz: f64 = cfg.max_hz;
    const lo = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(cfg.bins));
    const hi = @as(f64, @floatFromInt(i + 1)) / @as(f64, @floatFromInt(cfg.bins));
    const r = max_hz / min_hz;
    return @sqrt((min_hz * @exp(@log(r) * lo)) * (min_hz * @exp(@log(r) * hi)));
}

test "era_spectrum: 正弦峰值落在期望对数带 ±1" {
    const a = testing.allocator;
    const cfg = EraSpectrumConfig{};
    const sp = try era_spectrum_create(a, cfg);
    defer era_spectrum_destroy(sp);

    const n: usize = 8192;
    const l = try a.alloc(f32, n);
    defer a.free(l);
    const out_l = try a.alloc(f32, cfg.bins);
    defer a.free(out_l);
    const out_r = try a.alloc(f32, cfg.bins);
    defer a.free(out_r);

    const freqs = [_]f32{ 40.0, 80.0, 440.0, 1000.0, 4000.0, 8000.0, 16000.0 };
    for (freqs) |f| {
        era_spectrum_reset(sp);
        fillSine(l, f, cfg.sample_rate, 1.0);
        _ = era_spectrum_process(sp, l, l, out_l, out_r);

        const exp = expectedBand(f, cfg.min_hz, cfg.max_hz, cfg.bins);
        const got = peakBand(out_l);
        const diff = if (got > exp) got - exp else exp - got;
        try testing.expect(diff <= 1);
        try testing.expect(out_l[got] > 0.1);
    }
}

test "era_spectrum: 静音全 0；白噪声有限且非负" {
    const a = testing.allocator;
    const cfg = EraSpectrumConfig{};
    const sp = try era_spectrum_create(a, cfg);
    defer era_spectrum_destroy(sp);

    const n: usize = 8192;
    const l = try a.alloc(f32, n);
    defer a.free(l);
    const out_l = try a.alloc(f32, cfg.bins);
    defer a.free(out_l);
    const out_r = try a.alloc(f32, cfg.bins);
    defer a.free(out_r);

    @memset(l, 0.0);
    const beat = era_spectrum_process(sp, l, l, out_l, out_r);
    try testing.expectEqual(@as(f32, 0.0), beat);
    for (out_l) |v| try testing.expectEqual(@as(f32, 0.0), v);
    for (out_r) |v| try testing.expectEqual(@as(f32, 0.0), v);

    var seed: u32 = 0x1234_5678;
    for (l) |*v| {
        seed = seed *% 1664525 +% 1013904223;
        v.* = (@as(f32, @floatFromInt(seed >> 8)) / 8388608.0 - 1.0) * 0.3;
    }
    era_spectrum_reset(sp);
    _ = era_spectrum_process(sp, l, l, out_l, out_r);
    for (out_l) |v| {
        try testing.expect(!std.math.isNan(v));
        try testing.expect(!std.math.isInf(v));
        try testing.expect(v >= 0.0 and v <= 1.0);
    }
    for (out_r) |v| {
        try testing.expect(!std.math.isNan(v));
        try testing.expect(!std.math.isInf(v));
        try testing.expect(v >= 0.0 and v <= 1.0);
    }
}

test "era_spectrum: 左右分离（仅 L 有信号 → R 全 0）" {
    const a = testing.allocator;
    const cfg = EraSpectrumConfig{};
    const sp = try era_spectrum_create(a, cfg);
    defer era_spectrum_destroy(sp);

    const n: usize = 8192;
    const l = try a.alloc(f32, n);
    defer a.free(l);
    const r = try a.alloc(f32, n);
    defer a.free(r);
    const out_l = try a.alloc(f32, cfg.bins);
    defer a.free(out_l);
    const out_r = try a.alloc(f32, cfg.bins);
    defer a.free(out_r);

    fillSine(l, 1000.0, cfg.sample_rate, 1.0);
    @memset(r, 0.0);
    _ = era_spectrum_process(sp, l, r, out_l, out_r);

    for (out_r) |v| try testing.expectEqual(@as(f32, 0.0), v);
    try testing.expect(out_l[peakBand(out_l)] > 0.5);
}

test "era_spectrum: 0dBFS 1kHz ≈ 1.0；-60dB ≈ 0.17" {
    const a = testing.allocator;
    const cfg = EraSpectrumConfig{};
    const sp = try era_spectrum_create(a, cfg);
    defer era_spectrum_destroy(sp);

    const n: usize = 8192;
    const l = try a.alloc(f32, n);
    defer a.free(l);
    const out_l = try a.alloc(f32, cfg.bins);
    defer a.free(out_l);
    const out_r = try a.alloc(f32, cfg.bins);
    defer a.free(out_r);

    fillSine(l, 1000.0, cfg.sample_rate, 1.0);
    _ = era_spectrum_process(sp, l, l, out_l, out_r);
    const loud = out_l[peakBand(out_l)];
    try testing.expect(loud > 0.9);
    try testing.expect(loud <= 1.0);

    era_spectrum_reset(sp);
    fillSine(l, 1000.0, cfg.sample_rate, 0.001);
    _ = era_spectrum_process(sp, l, l, out_l, out_r);
    const quiet = out_l[peakBand(out_l)];
    try testing.expectApproxEqAbs(@as(f32, 0.17), quiet, 0.05);
}

test "era_spectrum: 250–350Hz 交叉区无凹口/台阶" {
    const a = testing.allocator;
    const cfg = EraSpectrumConfig{};
    const sp = try era_spectrum_create(a, cfg);
    defer era_spectrum_destroy(sp);

    const n: usize = 8192;
    const l = try a.alloc(f32, n);
    defer a.free(l);
    const out_l = try a.alloc(f32, cfg.bins);
    defer a.free(out_l);
    const out_r = try a.alloc(f32, cfg.bins);
    defer a.free(out_r);

    var prev_peak: ?usize = null;
    var f: f32 = 250.0;
    while (f <= 350.001) : (f += 2.0) {
        era_spectrum_reset(sp);
        fillSine(l, f, cfg.sample_rate, 1.0);
        _ = era_spectrum_process(sp, l, l, out_l, out_r);

        var max_v: f32 = 0.0;
        var max_i: usize = 0;
        for (0..cfg.bins) |i| {
            const center = bandCenter(cfg, i);
            if (center >= 240.0 and center <= 360.0 and out_l[i] > max_v) {
                max_v = out_l[i];
                max_i = i;
            }
        }
        try testing.expect(max_v > 0.75);
        if (prev_peak) |pb| {
            const d = if (max_i > pb) max_i - pb else pb - max_i;
            try testing.expect(d <= 2);
        }
        prev_peak = max_i;
    }
}

test "era_spectrum: 120BPM 点击触发、持续正弦基本不触发" {
    const a = testing.allocator;
    const cfg = EraSpectrumConfig{};
    const sp = try era_spectrum_create(a, cfg);
    defer era_spectrum_destroy(sp);

    const frame_len: usize = 2400; // 50ms @48k
    const frames: usize = 120;
    const lead: usize = 8192;
    const total = lead + frames * frame_len + 8192;
    const sig = try a.alloc(f32, total);
    defer a.free(sig);
    @memset(sig, 0.0);

    // 点击轨：每 0.5s（120BPM）一个 2kHz 衰减噪声脉冲。
    var k: usize = 0;
    while (k < 8) : (k += 1) {
        const t_ms: usize = 1000 + k * 500;
        const start = lead + t_ms * 48; // 48 样本/ms
        var seed: u32 = 0x9e37_79b9 +% @as(u32, @intCast(k));
        var j: usize = 0;
        while (j < 400 and start + j < total) : (j += 1) {
            seed = seed *% 1664525 +% 1013904223;
            const noise = @as(f32, @floatFromInt(seed >> 8)) / 8388608.0 - 1.0;
            const env = @exp(-@as(f32, @floatFromInt(j)) / 80.0);
            sig[start + j] += 0.8 * noise * env;
        }
    }

    const out_l = try a.alloc(f32, cfg.bins);
    defer a.free(out_l);
    const out_r = try a.alloc(f32, cfg.bins);
    defer a.free(out_r);

    var max_beat: f32 = 0.0;
    var hits: usize = 0;
    var t: usize = 0;
    while (t < frames) : (t += 1) {
        const end = lead + (t + 1) * frame_len;
        const win = sig[end - 8192 .. end];
        const beat = era_spectrum_process(sp, win, win, out_l, out_r);
        try testing.expect(!std.math.isNan(beat));
        try testing.expect(beat >= 0.0 and beat <= 1.0);
        if (beat > max_beat) max_beat = beat;
        if (beat > 0.05) hits += 1;
    }
    try testing.expect(max_beat > 0.2);
    try testing.expect(hits >= 4);

    // 持续正弦：重置后连续 60 帧（滑动窗口、相位连续）不应误触发。
    era_spectrum_reset(sp);
    const sine_len = 8192 + 60 * frame_len;
    const sine = try a.alloc(f32, sine_len);
    defer a.free(sine);
    fillSine(sine, 440.0, cfg.sample_rate, 0.5);
    var sine_max: f32 = 0.0;
    t = 0;
    while (t < 60) : (t += 1) {
        const end = 8192 + (t + 1) * frame_len;
        const win = sine[end - 8192 .. end];
        const beat = era_spectrum_process(sp, win, win, out_l, out_r);
        if (beat > sine_max) sine_max = beat;
    }
    try testing.expect(sine_max < 0.1);
}

test "era_spectrum: 任意输入长度（含 < fft_low）不崩溃/不越界" {
    const a = testing.allocator;
    const cfg = EraSpectrumConfig{};
    const sp = try era_spectrum_create(a, cfg);
    defer era_spectrum_destroy(sp);

    const out_l = try a.alloc(f32, cfg.bins);
    defer a.free(out_l);
    const out_r = try a.alloc(f32, cfg.bins);
    defer a.free(out_r);

    const lens = [_]usize{ 0, 1, 7, 100, 1024, 2047, 2048, 2049, 4096, 8192, 12000 };
    for (lens) |n| {
        era_spectrum_reset(sp);
        const buf = try a.alloc(f32, n);
        fillSine(buf, 440.0, cfg.sample_rate, 0.5);
        const beat = era_spectrum_process(sp, buf, buf, out_l, out_r);
        a.free(buf);

        try testing.expect(!std.math.isNan(beat));
        for (out_l) |v| {
            try testing.expect(!std.math.isNan(v));
            try testing.expect(v >= 0.0 and v <= 1.0);
        }
        for (out_r) |v| {
            try testing.expect(!std.math.isNan(v));
            try testing.expect(v >= 0.0 and v <= 1.0);
        }
    }
}

test "era_spectrum: 前端补零与尾部截取语义" {
    const a = testing.allocator;
    const cfg = EraSpectrumConfig{};
    const sp = try era_spectrum_create(a, cfg);
    defer era_spectrum_destroy(sp);

    const out_a = try a.alloc(f32, cfg.bins);
    defer a.free(out_a);
    const out_b = try a.alloc(f32, cfg.bins);
    defer a.free(out_b);
    const out_r = try a.alloc(f32, cfg.bins);
    defer a.free(out_r);

    // 短窗（2400 样本）应等价于前端补零到 fft_low 的长窗。
    const short_len: usize = 2400;
    const short = try a.alloc(f32, short_len);
    defer a.free(short);
    fillSine(short, 1000.0, cfg.sample_rate, 1.0);

    const padded = try a.alloc(f32, cfg.fft_low);
    defer a.free(padded);
    @memset(padded, 0.0);
    @memcpy(padded[cfg.fft_low - short_len ..], short);

    era_spectrum_reset(sp);
    _ = era_spectrum_process(sp, short, short, out_a, out_r);
    era_spectrum_reset(sp);
    _ = era_spectrum_process(sp, padded, padded, out_b, out_r);
    try testing.expectEqualSlices(f32, out_a, out_b);

    // 超长输入（12000 样本）只取最近 fft_low 个样本。
    const long_len: usize = 12000;
    const long = try a.alloc(f32, long_len);
    defer a.free(long);
    var seed: u32 = 0xdead_beef;
    for (long) |*v| {
        seed = seed *% 1664525 +% 1013904223;
        v.* = (@as(f32, @floatFromInt(seed >> 8)) / 8388608.0 - 1.0) * 0.2;
    }
    fillSine(long[long_len - cfg.fft_low ..], 1000.0, cfg.sample_rate, 1.0);

    era_spectrum_reset(sp);
    _ = era_spectrum_process(sp, long, long, out_a, out_r);
    era_spectrum_reset(sp);
    _ = era_spectrum_process(sp, long[long_len - cfg.fft_low ..], long[long_len - cfg.fft_low ..], out_b, out_r);
    try testing.expectEqualSlices(f32, out_a, out_b);
}

test "era_spectrum: reset 清空状态、参数 getter 正确" {
    const a = testing.allocator;
    const cfg = EraSpectrumConfig{ .sample_rate = 44100, .bins = 96 };
    const sp = try era_spectrum_create(a, cfg);
    defer era_spectrum_destroy(sp);

    try testing.expectEqual(@as(u32, 96), era_spectrum_bins(sp));
    try testing.expectEqual(@as(u32, 44100), era_spectrum_sample_rate(sp));

    const n: usize = 4096;
    const l = try a.alloc(f32, n);
    defer a.free(l);
    const out_l = try a.alloc(f32, cfg.bins);
    defer a.free(out_l);
    const out_r = try a.alloc(f32, cfg.bins);
    defer a.free(out_r);

    fillSine(l, 1000.0, cfg.sample_rate, 1.0);
    _ = era_spectrum_process(sp, l, l, out_l, out_r);
    era_spectrum_reset(sp);

    @memset(l, 0.0);
    const beat = era_spectrum_process(sp, l, l, out_l, out_r);
    try testing.expectEqual(@as(f32, 0.0), beat);
    for (out_l) |v| try testing.expectEqual(@as(f32, 0.0), v);
}

test "era_spectrum: 非法配置被拒绝" {
    const a = testing.allocator;
    try testing.expectError(error.InvalidArgument, era_spectrum_create(a, .{ .sample_rate = 0 }));
    try testing.expectError(error.InvalidArgument, era_spectrum_create(a, .{ .bins = 0 }));
    try testing.expectError(error.InvalidArgument, era_spectrum_create(a, .{ .min_hz = 0.0 }));
    try testing.expectError(error.InvalidArgument, era_spectrum_create(a, .{ .min_hz = 16000.0, .max_hz = 40.0 }));
    try testing.expectError(error.InvalidArgument, era_spectrum_create(a, .{ .max_hz = 24000.0 }));
    try testing.expectError(error.InvalidArgument, era_spectrum_create(a, .{ .fft_low = 8000 }));
    try testing.expectError(error.InvalidArgument, era_spectrum_create(a, .{ .fft_high = 1000 }));
}
