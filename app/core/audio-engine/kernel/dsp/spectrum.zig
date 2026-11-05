// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! 频谱分析器 v3 —— VQT（可变 Q 变换）+ AGC / γ / 高频倾斜 / 峰值保持
//! （docs/spectrum-analyzer.md §4 / §9.1）
//!
//! 纯计算内核：不建线程、不做 I/O、不依赖 FFmpeg / C 壳。C 侧
//! `spectrum_service.c` 在独立频谱线程按「播放位置」取窗后调用
//! `era_spectrum_process`，结果经引擎事件推送。
//!
//! 算法要点：
//!   - 每个对数带一个**可变 Q 复解调器**（VQT）：中心频率
//!     `f_i = sqrt(f_lo·f_hi)`，窗长 `L_i = Q_i·sr/f_i`，Q 上限 20.9；
//!     低频用更长窗、高频用更短窗，等价于多分辨率 CQT 的实用近似；
//!   - Blackman 周期窗 + 窗和归一化，单边幅度 `2|X|/Σw`；
//!   - 显示量程采用常见的 `|X|/N` 口径：再乘 0.28，dB 映射
//!     `[-60, 0] → [0, 1]`；0dBFS 正弦约 0.82，顶部留余量；
//!   - AGC / `norm^γ` / 高频倾斜默认关闭，需要时可在配置中开启；
//!   - 峰值保持默认关闭，由 UI 设置经 `set_fft` 打开；
//!   - 节拍用对数幅度谱通量 + 最近 43 帧中位数自适应阈值 + 100ms 冷却；
//!   - 所有核/表在 create 时一次构建，每帧零分配；reset 只清状态。
//!
//! 命名自有（`era_` 前缀），不照搬 FFmpeg / librosa 等上游标识符。

const std = @import("std");
const Stage = @import("stage.zig").Stage;

/// 分析器配置。字段与 `kernel/kernel.zig` 的 C 桥接调用逐字对齐。
pub const EraSpectrumConfig = struct {
    sample_rate: u32 = 48000,
    bins: u32 = 128,
    min_hz: f32 = 40.0,
    max_hz: f32 = 16000.0,
    /// VQT 最长窗（样本）。低频受此上限约束，避免 40Hz 窗无限增长。
    max_window: u32 = 12288,
    /// VQT 最大 Q；14.8 band/oct 对应约 20.9。
    q_max: f32 = 20.9,
    /// 帧间隔（秒），用于 AGC 攻放/峰值衰减；引擎固定 50ms。
    frame_interval_s: f32 = 0.05,
    /// 慢 AGC（默认关；开启会抬高弱音，可能重新顶满）。
    agc_enabled: bool = false,
    agc_target_db: f32 = -24.0,
    agc_attack_s: f32 = 3.0,
    agc_release_s: f32 = 3.0,
    /// 显示 γ（默认 1.0；<1 提亮小信号，>1 压暗）。
    gamma: f32 = 1.0,
    /// 高频倾斜（dB/oct，相对 1kHz；默认 0，保持常见频谱量程）。
    tilt_db_per_oct: f32 = 0.0,
    /// 峰值保持（默认关；由 UI 设置通过 set_fft 打开）。
    peak_hold: bool = false,
    /// 峰值每秒衰减（归一化单位，默认 2.0/s）。
    peak_decay_per_s: f32 = 2.0,
};

/// dB 映射动态范围下界（-60dB → 0，与常见频谱一致）。
const era_db_floor: f32 = -60.0;

/// dB 映射上界（0dB → 1）。
const era_db_ceiling: f32 = 0.0;

/// 显示量程增益：常见频谱实现用 `|X|/N` 且不做相干增益补偿，
/// 满幅正弦约 0.27（-11.4dB）。我们的 VQT 已把满幅正弦归一到 1.0，
/// 这里乘 0.28，使 0dBFS → 约 0.82，顶部保留余量。
const era_display_gain: f32 = 0.28;

/// 软膝宽度（映射后归一化坐标的底部 6%）。
const era_soft_knee: f32 = 0.06;

/// 节拍通量历史长度（43 帧 ≈ 2.15s @20Hz）。
const era_flux_history_len: usize = 43;

/// 节拍冷却帧数（100ms ≈ 2 帧 @50ms）。
const era_beat_cooldown_frames: u8 = 2;

/// 单个 VQT 带的预计算核。
const EraVqtBand = struct {
    /// 中心频率（Hz）。
    freq: f32,
    /// 窗长（样本）。
    len: usize,
    /// Blackman 窗和（幅度归一化）。
    window_sum: f32,
    /// 预乘窗的 cos(2π f n / sr)。
    cos: []f32,
    /// 预乘窗的 sin(2π f n / sr)。
    sin: []f32,
    /// 高频倾斜线性增益（dB/oct → 幅度）。
    tilt_gain: f32,
};

/// 频谱分析器实例（不透明于 C 侧 `ZkSpectrum`）。
pub const EraSpectrum = struct {
    allocator: std.mem.Allocator,
    sample_rate: u32,
    bins: u32,
    min_hz: f32,
    max_hz: f32,
    max_window: u32,
    q_max: f32,
    frame_interval_s: f32,
    agc_enabled: bool,
    agc_target_db: f32,
    agc_attack_s: f32,
    agc_release_s: f32,
    gamma: f32,
    tilt_db_per_oct: f32,
    peak_hold: bool,
    peak_decay_per_s: f32,

    /// 对数带边界，长度 bins + 1（Hz）。
    edges: []f32,
    /// 每个输出带的 VQT 核，长度 bins。
    bands: []EraVqtBand,
    /// 上一帧 L/R 平均后的原始带幅度（节拍通量用）。
    prev_mag: []f32,
    /// 本帧左右声道原始带幅度暂存。
    band_l: []f32,
    band_r: []f32,
    /// 显示峰值（保持线），长度 bins。
    peak_l: []f32,
    peak_r: []f32,
    /// Stage 模式最近一帧的显示频谱（长度 bins）。
    frame_l: []f32,
    frame_r: []f32,

    /// Stage 模式：交错输入声道数（仅取前两声道；1 = 单声道镜像）。
    stage_channels: u8 = 2,
    /// Stage 模式最近一帧的节拍强度 0..1。
    stage_beat: f32 = 0.0,

    agc_gain: f32 = 1.0,
    has_prev: bool = false,
    flux_hist: [era_flux_history_len]f32 = @splat(0.0),
    flux_pos: usize = 0,
    flux_count: usize = 0,
    cooldown: u8 = 0,
};

// ---------------------------------------------------------------------------
// 配置 / 建表
// ---------------------------------------------------------------------------

fn eraValidateConfig(cfg: EraSpectrumConfig) !void {
    if (cfg.sample_rate == 0) return error.InvalidArgument;
    if (cfg.bins == 0 or cfg.bins > 1024) return error.InvalidArgument;
    if (!(cfg.min_hz > 0.0) or !(cfg.max_hz > cfg.min_hz)) return error.InvalidArgument;
    const nyquist = @as(f32, @floatFromInt(cfg.sample_rate)) * 0.5;
    if (cfg.max_hz >= nyquist) return error.InvalidArgument;
    if (cfg.max_window < 64 or cfg.max_window > 65536) return error.InvalidArgument;
    if (!(cfg.q_max >= 2.0)) return error.InvalidArgument;
    if (!(cfg.frame_interval_s > 0.0)) return error.InvalidArgument;
    if (!(cfg.agc_attack_s > 0.0) or !(cfg.agc_release_s > 0.0)) return error.InvalidArgument;
    if (!(cfg.gamma > 0.0)) return error.InvalidArgument;
    if (!(cfg.peak_decay_per_s >= 0.0)) return error.InvalidArgument;
}

fn eraBandCenter(min_hz: f64, max_hz: f64, bins: usize, i: usize) f64 {
    const r = max_hz / min_hz;
    const lo = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(bins));
    const hi = @as(f64, @floatFromInt(i + 1)) / @as(f64, @floatFromInt(bins));
    return @sqrt((min_hz * @exp(@log(r) * lo)) * (min_hz * @exp(@log(r) * hi)));
}

/// 高频倾斜线性增益（dB/oct，相对 1kHz）。
fn eraTiltGain(db_per_oct: f32, freq: f32) f32 {
    const tilt_db = @as(f64, db_per_oct) * @log2(@as(f64, freq) / 1000.0);
    return @floatCast(std.math.pow(f64, 10.0, tilt_db / 20.0));
}

/// 构建一个 VQT 带：窗长、Blackman 窗、复解调核、倾斜增益。
fn eraVqtBandInit(
    allocator: std.mem.Allocator,
    cfg: EraSpectrumConfig,
    fc: f64,
) !EraVqtBand {
    const sr: f64 = @floatFromInt(cfg.sample_rate);
    const max_window: f64 = @floatFromInt(cfg.max_window);

    // 可变 Q：低频受 max_window 限制，高频封顶 q_max。
    var q = @min(@as(f64, cfg.q_max), max_window * fc / sr);
    if (q < 2.0) q = 2.0;
    var len_f = @round(q * sr / fc);
    if (len_f < 32.0) len_f = 32.0;
    if (len_f > max_window) len_f = max_window;
    const len: usize = @intFromFloat(len_f);

    const cos = try allocator.alloc(f32, len);
    errdefer allocator.free(cos);
    const sin = try allocator.alloc(f32, len);
    errdefer allocator.free(sin);

    const nf: f64 = @floatFromInt(len);
    var wsum: f64 = 0.0;
    var n: usize = 0;
    while (n < len) : (n += 1) {
        const t = 2.0 * std.math.pi * @as(f64, @floatFromInt(n)) / nf;
        const w = 0.42 - 0.5 * @cos(t) + 0.08 * @cos(2.0 * t);
        const phase = 2.0 * std.math.pi * fc * @as(f64, @floatFromInt(n)) / sr;
        cos[n] = @floatCast(w * @cos(phase));
        sin[n] = @floatCast(w * @sin(phase));
        wsum += w;
    }
    if (wsum <= 0.0) return error.InvalidArgument;

    const tilt_gain: f32 = eraTiltGain(cfg.tilt_db_per_oct, @floatCast(fc));

    return .{
        .freq = @floatCast(fc),
        .len = len,
        .window_sum = @floatCast(wsum),
        .cos = cos,
        .sin = sin,
        .tilt_gain = tilt_gain,
    };
}

/// 创建频谱分析器（核/表一次建好；每帧零分配）。
pub fn era_spectrum_create(allocator: std.mem.Allocator, cfg: EraSpectrumConfig) !*EraSpectrum {
    try eraValidateConfig(cfg);

    const bins: usize = cfg.bins;
    const edges = try allocator.alloc(f32, bins + 1);
    errdefer allocator.free(edges);
    const bands = try allocator.alloc(EraVqtBand, bins);
    errdefer allocator.free(bands);

    const min_hz: f64 = cfg.min_hz;
    const max_hz: f64 = cfg.max_hz;
    const log_ratio = @log(max_hz / min_hz);
    for (0..bins + 1) |i| {
        const frac = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(bins));
        edges[i] = @floatCast(min_hz * @exp(log_ratio * frac));
    }

    var built: usize = 0;
    errdefer {
        for (bands[0..built]) |b| {
            allocator.free(b.cos);
            allocator.free(b.sin);
        }
    }
    for (0..bins) |i| {
        const fc = eraBandCenter(min_hz, max_hz, bins, i);
        bands[i] = try eraVqtBandInit(allocator, cfg, fc);
        built += 1;
    }

    const prev_mag = try allocator.alloc(f32, bins);
    errdefer allocator.free(prev_mag);
    const band_l = try allocator.alloc(f32, bins);
    errdefer allocator.free(band_l);
    const band_r = try allocator.alloc(f32, bins);
    errdefer allocator.free(band_r);
    const peak_l = try allocator.alloc(f32, bins);
    errdefer allocator.free(peak_l);
    const peak_r = try allocator.alloc(f32, bins);
    errdefer allocator.free(peak_r);
    const frame_l = try allocator.alloc(f32, bins);
    errdefer allocator.free(frame_l);
    const frame_r = try allocator.alloc(f32, bins);
    errdefer allocator.free(frame_r);

    @memset(prev_mag, 0.0);
    @memset(band_l, 0.0);
    @memset(band_r, 0.0);
    @memset(peak_l, 0.0);
    @memset(peak_r, 0.0);
    @memset(frame_l, 0.0);
    @memset(frame_r, 0.0);

    const self = try allocator.create(EraSpectrum);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .sample_rate = cfg.sample_rate,
        .bins = cfg.bins,
        .min_hz = cfg.min_hz,
        .max_hz = cfg.max_hz,
        .max_window = cfg.max_window,
        .q_max = cfg.q_max,
        .frame_interval_s = cfg.frame_interval_s,
        .agc_enabled = cfg.agc_enabled,
        .agc_target_db = cfg.agc_target_db,
        .agc_attack_s = cfg.agc_attack_s,
        .agc_release_s = cfg.agc_release_s,
        .gamma = cfg.gamma,
        .tilt_db_per_oct = cfg.tilt_db_per_oct,
        .peak_hold = cfg.peak_hold,
        .peak_decay_per_s = cfg.peak_decay_per_s,
        .edges = edges,
        .bands = bands,
        .prev_mag = prev_mag,
        .band_l = band_l,
        .band_r = band_r,
        .peak_l = peak_l,
        .peak_r = peak_r,
        .frame_l = frame_l,
        .frame_r = frame_r,
    };
    return self;
}

/// 销毁（核/表与每帧缓冲一并释放）。
pub fn era_spectrum_destroy(self: *EraSpectrum) void {
    const a = self.allocator;
    for (self.bands) |b| {
        a.free(b.cos);
        a.free(b.sin);
    }
    a.free(self.edges);
    a.free(self.bands);
    a.free(self.prev_mag);
    a.free(self.band_l);
    a.free(self.band_r);
    a.free(self.peak_l);
    a.free(self.peak_r);
    a.free(self.frame_l);
    a.free(self.frame_r);
    self.sample_rate = 0;
    a.destroy(self);
}

/// 清空帧间状态（seek / 切歌 / 会话重建）；核/表保留。
pub fn era_spectrum_reset(self: *EraSpectrum) void {
    @memset(self.prev_mag, 0.0);
    @memset(self.peak_l, 0.0);
    @memset(self.peak_r, 0.0);
    @memset(self.frame_l, 0.0);
    @memset(self.frame_r, 0.0);
    @memset(&self.flux_hist, 0.0);
    self.agc_gain = 1.0;
    self.flux_pos = 0;
    self.flux_count = 0;
    self.cooldown = 0;
    self.has_prev = false;
    self.stage_beat = 0.0;
}

/// 设置峰值保持开关；关闭时清空峰值，避免残留线。
pub fn era_spectrum_set_peak_hold(self: *EraSpectrum, enabled: bool) void {
    self.peak_hold = enabled;
    if (!enabled) {
        @memset(self.peak_l, 0.0);
        @memset(self.peak_r, 0.0);
    }
}

/// 运行时开关 AGC；关闭时把增益复位到 1.0。
pub fn era_spectrum_set_agc(self: *EraSpectrum, enabled: bool) void {
    self.agc_enabled = enabled;
    if (!enabled) self.agc_gain = 1.0;
}

/// 运行时设置 γ；非法值（<=0 / NaN / Inf）忽略，范围收敛到 [0.25, 4.0]。
pub fn era_spectrum_set_gamma(self: *EraSpectrum, gamma: f32) void {
    if (!std.math.isFinite(gamma) or gamma <= 0.0) return;
    self.gamma = std.math.clamp(gamma, 0.25, 4.0);
}

/// 运行时设置高频倾斜（dB/oct）；非法值忽略，范围收敛到 [-24, 24]。
pub fn era_spectrum_set_tilt(self: *EraSpectrum, db_per_oct: f32) void {
    if (!std.math.isFinite(db_per_oct)) return;
    const clamped = std.math.clamp(db_per_oct, -24.0, 24.0);
    self.tilt_db_per_oct = clamped;
    for (self.bands) |*band| {
        band.tilt_gain = eraTiltGain(clamped, band.freq);
    }
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
// VQT / dB / 节拍
// ---------------------------------------------------------------------------

/// 单带 VQT 幅度：窗口以 `frames - future_samples` 为中心。
///
/// `future_samples = 0` 时为传统因果窗口（窗口末端 = 最新样本，群延迟约
/// `len/2`）；服务层在源可读未来样本时传入 `max_window/2`，让每个带的
/// 窗口中心对准当前播放位置，消除低频长窗的群延迟。窗口越界部分前端补零。
///
/// 采样按 `src[frame * stride + offset]` 读取：平面缓冲传 `stride = 1`，
/// 交错缓冲直接传声道数与声道偏移，避免每帧拆平面（Stage 路径）。
fn eraVqtBandMag(
    band: *const EraVqtBand,
    src: []const f32,
    frames: usize,
    stride: usize,
    offset: usize,
    future_samples: usize,
) f32 {
    const len = band.len;
    const half = len / 2;

    // 窗口末端（开区间）：中心 = end - half = frames - future_samples。
    var end: usize = frames;
    if (future_samples > half) {
        const shift = future_samples - half;
        end = if (shift >= frames) 0 else frames - shift;
    }
    const available = @min(end, len);
    const pad = len - available;
    const start = end - available;

    var re: f32 = 0.0;
    var im: f32 = 0.0;
    var n: usize = 0;
    while (n < len) : (n += 1) {
        const x: f32 = if (n < pad) 0.0 else src[(start + (n - pad)) * stride + offset];
        re += x * band.cos[n];
        im += x * band.sin[n];
    }
    var m = 2.0 * @sqrt(re * re + im * im) / band.window_sum;
    if (!(m >= 0.0)) m = 0.0; // NaN
    if (m > 1.0) m = 1.0;
    return m;
}

/// dB → [0,1]，-60..0dB 线性映射，底部 6% smoothstep 软膝（不做硬清零）。
fn eraMapDb(amp: f32) f32 {
    const db = 20.0 * @log10(amp + 1e-12);
    var t = (db - era_db_floor) / (era_db_ceiling - era_db_floor);
    if (t < 0.0) t = 0.0;
    if (t > 1.0) t = 1.0;
    const gate = @min(t / era_soft_knee, 1.0);
    return t * gate * gate * (3.0 - 2.0 * gate);
}

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

/// 更新 AGC 增益（慢攻/放，目标 dB）。
fn eraAgcStep(self: *EraSpectrum, raw_l: []const f32, raw_r: []const f32) f32 {
    if (!self.agc_enabled) return 1.0;

    var sum: f32 = 0.0;
    for (raw_l, raw_r) |a, b| {
        const m = 0.5 * (a + b);
        sum += m * m;
    }
    const level = @sqrt(sum / @as(f32, @floatFromInt(raw_l.len)));
    var desired: f32 = 1.0;
    if (level > 1e-6) {
        const target = std.math.pow(f32, 10.0, self.agc_target_db / 20.0);
        desired = target / level;
        if (desired < 0.25) desired = 0.25;
        if (desired > 4.0) desired = 4.0;
    }
    const tau = if (desired > self.agc_gain) self.agc_attack_s else self.agc_release_s;
    const coef = 1.0 - @exp(-self.frame_interval_s / tau);
    self.agc_gain += (desired - self.agc_gain) * coef;
    if (self.agc_gain < 0.25) self.agc_gain = 0.25;
    if (self.agc_gain > 4.0) self.agc_gain = 4.0;
    return self.agc_gain;
}

/// 处理一帧（传统因果窗口）。
///
/// `l` / `r` 为最近 `frames` 个每声道样本（窗口终点 = 当前播放位置）；
/// 每个 VQT 带取自己最近的 `len` 个样本，不足部分在**前端补零**。
/// 低频长窗的群延迟约 `len/2`；需要对齐当前画面时用
/// [era_spectrum_process_centered] 传入未来样本偏移。
/// `out_l` / `out_r` / 峰值数组长度 = bins，写 [0,1]。
/// 返回本帧节拍强度 0..1。
pub fn era_spectrum_process(
    self: *EraSpectrum,
    l: []const f32,
    r: []const f32,
    out_l: []f32,
    out_r: []f32,
) f32 {
    return era_spectrum_process_centered(self, l, r, 0, out_l, out_r);
}

/// 处理一帧（窗口居中）。
///
/// `future_samples > 0` 时，`l`/`r` 的最后一个样本对应
/// `当前播放位置 + future_samples`；每个带把窗口中心对准当前播放位置，
/// 从而消除长窗群延迟。`future_samples = 0` 等价于因果窗口。
pub fn era_spectrum_process_centered(
    self: *EraSpectrum,
    l: []const f32,
    r: []const f32,
    future_samples: usize,
    out_l: []f32,
    out_r: []f32,
) f32 {
    return eraSpectrumFrame(self, l, 1, 0, r, 1, 0, future_samples, out_l, out_r);
}

/// 单帧计算核心：两个声道按任意步长/偏移读取。
///
/// 平面缓冲（C 壳 / 单元测试）传 `stride = 1, offset = 0`；
/// Stage 路径直接传交错声道数与声道偏移，省掉每帧拆平面的拷贝。
/// `l.len / l_stride` 与 `r.len / r_stride` 取小者为有效帧数。
fn eraSpectrumFrame(
    self: *EraSpectrum,
    l: []const f32,
    l_stride: usize,
    l_offset: usize,
    r: []const f32,
    r_stride: usize,
    r_offset: usize,
    future_samples: usize,
    out_l: []f32,
    out_r: []f32,
) f32 {
    const bins: usize = self.bins;
    if (out_l.len < bins or out_r.len < bins) return 0.0;

    const l_step = @max(l_stride, 1);
    const r_step = @max(r_stride, 1);
    const frames = @min(l.len / l_step, r.len / r_step);
    if (frames == 0) {
        @memset(out_l[0..bins], 0.0);
        @memset(out_r[0..bins], 0.0);
        return 0.0;
    }

    // 原始 VQT 带幅度（节拍/AGC 用）。
    for (self.bands, 0..) |*band, i| {
        self.band_l[i] = eraVqtBandMag(band, l, frames, l_step, l_offset, future_samples);
        self.band_r[i] = eraVqtBandMag(band, r, frames, r_step, r_offset, future_samples);
    }

    // 节拍通量：L/R 平均原始带幅度。
    const had_prev = self.has_prev;
    var flux: f32 = 0.0;
    for (0..bins) |i| {
        const comb = 0.5 * (self.band_l[i] + self.band_r[i]);
        if (had_prev) {
            const d = @log(1.0 + comb) - @log(1.0 + self.prev_mag[i]);
            if (d > 0.0) flux += d;
        }
        self.prev_mag[i] = comb;
    }
    self.has_prev = true;

    const agc = eraAgcStep(self, self.band_l, self.band_r);
    const decay = self.peak_decay_per_s * self.frame_interval_s;

    for (0..bins) |i| {
        const tilt = self.bands[i].tilt_gain;
        const gain = agc * tilt * era_display_gain;

        var v_l = eraMapDb(self.band_l[i] * gain);
        var v_r = eraMapDb(self.band_r[i] * gain);
        if (self.gamma != 1.0) {
            v_l = std.math.pow(f32, v_l, self.gamma);
            v_r = std.math.pow(f32, v_r, self.gamma);
        }
        if (!(v_l >= 0.0)) v_l = 0.0;
        if (!(v_r >= 0.0)) v_r = 0.0;
        if (v_l > 1.0) v_l = 1.0;
        if (v_r > 1.0) v_r = 1.0;
        out_l[i] = v_l;
        out_r[i] = v_r;

        if (self.peak_hold) {
            const floor_l = @max(self.peak_l[i] - decay, 0.0);
            const floor_r = @max(self.peak_r[i] - decay, 0.0);
            self.peak_l[i] = @max(v_l, floor_l);
            self.peak_r[i] = @max(v_r, floor_r);
        } else {
            self.peak_l[i] = v_l;
            self.peak_r[i] = v_r;
        }
    }

    return eraBeatStep(self, flux, had_prev);
}

/// 取当前峰值保持线；长度不足 bins 时截断。无峰值时写 0。
pub fn era_spectrum_peaks(self: *const EraSpectrum, out_l: []f32, out_r: []f32) void {
    const bins: usize = self.bins;
    const n = @min(@min(out_l.len, out_r.len), bins);
    @memcpy(out_l[0..n], self.peak_l[0..n]);
    @memcpy(out_r[0..n], self.peak_r[0..n]);
}

// ---------------------------------------------------------------------------
// 统一 DSP Stage 适配（docs/audio-kernel-zig.md §14）
// ---------------------------------------------------------------------------

/// 把分析器适配为内核统一 `Stage`（`dsp/stage.zig`）。
///
/// 输入是**交错** float32 PCM（`pcm.len == frames * channels`），只读不改，
/// 与 EQ / 限幅 / 响度同级可挂进主处理链。`channels == 1` 时左右镜像；
/// 其余声道布局只取前两声道（L/R），多声道下混由链路前级负责。
///
/// Stage 的 `process` 没有返回值，分析结果留在实例内，用
/// [era_spectrum_stage_frame]（128 带 + 节拍）与 [era_spectrum_peaks]
/// （峰值保持线）读取。每帧零分配；核/表仍在 create 时一次建好。
///
/// 声道数写在实例上：同一实例同一时刻只应存在一个 Stage（重新调用本函数
/// 会更新声道数，先前取出的 Stage 句柄随之按新声道数解释输入）。
pub fn era_spectrum_stage(self: *EraSpectrum, channels: u8) Stage {
    self.stage_channels = if (channels == 0) 1 else channels;
    return .{
        .ctx = @ptrCast(self),
        .vtable = &stage_vtable,
        .channels = self.stage_channels,
    };
}

const stage_vtable = Stage.VTable{ .process = stageProcessThunk };

fn stageProcessThunk(ctx: *anyopaque, pcm: []f32, frames: usize) void {
    const self: *EraSpectrum = @ptrCast(@alignCast(ctx));
    _ = era_spectrum_process_interleaved(self, pcm, frames);
}

/// Stage 路径的显式入口（不经 vtable；供测试与链内直调）。
///
/// 交错 float32 就地只读；返回本帧节拍强度 0..1。`frames == 0` 或缓冲
/// 长度不足为空操作（不清空上一帧结果）。
pub fn era_spectrum_process_interleaved(
    self: *EraSpectrum,
    pcm: []f32,
    frames: usize,
) f32 {
    const channels = @max(self.stage_channels, 1);
    const need = frames * @as(usize, channels);
    if (frames == 0 or need > pcm.len) return 0.0;

    const r_offset: usize = if (channels >= 2) 1 else 0;
    const beat = eraSpectrumFrame(
        self,
        pcm,
        channels,
        0,
        pcm,
        channels,
        r_offset,
        0,
        self.frame_l,
        self.frame_r,
    );
    self.stage_beat = beat;
    return beat;
}

/// 取 Stage 路径最近一帧的显示频谱（[0,1]，长度 bins，不足截断）。
///
/// 返回该帧节拍强度 0..1；从未处理过帧时输出全 0、返回 0。
pub fn era_spectrum_stage_frame(self: *const EraSpectrum, out_l: []f32, out_r: []f32) f32 {
    const bins: usize = self.bins;
    const n = @min(@min(out_l.len, out_r.len), bins);
    if (n > 0) {
        @memcpy(out_l[0..n], self.frame_l[0..n]);
        @memcpy(out_r[0..n], self.frame_r[0..n]);
    }
    return self.stage_beat;
}

// ---------------------------------------------------------------------------
// 单元测试
// ---------------------------------------------------------------------------

const testing = std.testing;

fn precisionConfig() EraSpectrumConfig {
    return .{
        .agc_enabled = false,
        .gamma = 1.0,
        .tilt_db_per_oct = 0.0,
        .peak_hold = false,
    };
}

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
    return eraBandCenter(cfg.min_hz, cfg.max_hz, cfg.bins, i);
}

test "era_spectrum: VQT 正弦峰值落在期望对数带 ±2" {
    const a = testing.allocator;
    const cfg = precisionConfig();
    const sp = try era_spectrum_create(a, cfg);
    defer era_spectrum_destroy(sp);

    const n: usize = cfg.max_window;
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
        try testing.expect(diff <= 2);
        try testing.expect(out_l[got] > 0.1);
    }
}

test "era_spectrum: 静音全 0；白噪声有限且非负" {
    const a = testing.allocator;
    const cfg = precisionConfig();
    const sp = try era_spectrum_create(a, cfg);
    defer era_spectrum_destroy(sp);

    const n: usize = cfg.max_window;
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
    const cfg = precisionConfig();
    const sp = try era_spectrum_create(a, cfg);
    defer era_spectrum_destroy(sp);

    const n: usize = cfg.max_window;
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

test "era_spectrum: 量程校准（0dBFS ≈ 0.82）" {
    const a = testing.allocator;
    const cfg = precisionConfig();
    const sp = try era_spectrum_create(a, cfg);
    defer era_spectrum_destroy(sp);

    const n: usize = cfg.max_window;
    const l = try a.alloc(f32, n);
    defer a.free(l);
    const out_l = try a.alloc(f32, cfg.bins);
    defer a.free(out_l);
    const out_r = try a.alloc(f32, cfg.bins);
    defer a.free(out_r);

    const idx = expectedBand(1000.0, cfg.min_hz, cfg.max_hz, cfg.bins);
    const f: f32 = @floatCast(bandCenter(cfg, idx));

    // 满幅正弦：|X|/N 口径约 0.27（-11.4dB），乘 0.28 后约 0.82。
    fillSine(l, f, cfg.sample_rate, 1.0);
    _ = era_spectrum_process(sp, l, l, out_l, out_r);
    const loud = out_l[idx];
    try testing.expectApproxEqAbs(@as(f32, 0.82), loud, 0.02);

    // -30dB：约 0.31，仍保留明显动态。
    era_spectrum_reset(sp);
    fillSine(l, f, cfg.sample_rate, 0.0316228);
    _ = era_spectrum_process(sp, l, l, out_l, out_r);
    try testing.expectApproxEqAbs(@as(f32, 0.31), out_l[idx], 0.03);

    // -60dB：低于 -60dB 下界，归零。
    era_spectrum_reset(sp);
    fillSine(l, f, cfg.sample_rate, 0.001);
    _ = era_spectrum_process(sp, l, l, out_l, out_r);
    try testing.expect(out_l[idx] < 0.01);
}

test "era_spectrum: 40–16k 扫频峰值带连续" {
    const a = testing.allocator;
    const cfg = precisionConfig();
    const sp = try era_spectrum_create(a, cfg);
    defer era_spectrum_destroy(sp);

    const n: usize = cfg.max_window;
    const l = try a.alloc(f32, n);
    defer a.free(l);
    const out_l = try a.alloc(f32, cfg.bins);
    defer a.free(out_l);
    const out_r = try a.alloc(f32, cfg.bins);
    defer a.free(out_r);

    const freqs = [_]f32{ 40.0, 80.0, 160.0, 320.0, 640.0, 1280.0, 2560.0, 5120.0, 10240.0, 16000.0 };
    var prev: ?usize = null;
    for (freqs) |f| {
        era_spectrum_reset(sp);
        fillSine(l, f, cfg.sample_rate, 1.0);
        _ = era_spectrum_process(sp, l, l, out_l, out_r);
        const got = peakBand(out_l);
        if (prev) |p| try testing.expect(got >= p);
        prev = got;
        try testing.expect(out_l[got] > 0.5);
    }
}

test "era_spectrum: 120BPM 点击触发、持续正弦基本不触发" {
    const a = testing.allocator;
    const cfg = precisionConfig();
    const sp = try era_spectrum_create(a, cfg);
    defer era_spectrum_destroy(sp);

    const frame_len: usize = 2400; // 50ms @48k
    const frames: usize = 120;
    const lead: usize = cfg.max_window;
    const total = lead + frames * frame_len + cfg.max_window;
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
        const win = sig[end - cfg.max_window .. end];
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
    const sine_len = cfg.max_window + 60 * frame_len;
    const sine = try a.alloc(f32, sine_len);
    defer a.free(sine);
    fillSine(sine, 440.0, cfg.sample_rate, 0.5);
    var sine_max: f32 = 0.0;
    t = 0;
    while (t < 60) : (t += 1) {
        const end = cfg.max_window + (t + 1) * frame_len;
        const win = sine[end - cfg.max_window .. end];
        const beat = era_spectrum_process(sp, win, win, out_l, out_r);
        if (beat > sine_max) sine_max = beat;
    }
    try testing.expect(sine_max < 0.1);
}

test "era_spectrum: 任意输入长度不崩溃/不越界" {
    const a = testing.allocator;
    const cfg = precisionConfig();
    const sp = try era_spectrum_create(a, cfg);
    defer era_spectrum_destroy(sp);

    const out_l = try a.alloc(f32, cfg.bins);
    defer a.free(out_l);
    const out_r = try a.alloc(f32, cfg.bins);
    defer a.free(out_r);

    const lens = [_]usize{ 0, 1, 7, 100, 1024, 2047, 2048, 2049, 4096, 8192, 12000, 12288 };
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

test "era_spectrum: 居中窗口消除长窗群延迟" {
    const a = testing.allocator;
    const cfg = precisionConfig();
    const sp = try era_spectrum_create(a, cfg);
    defer era_spectrum_destroy(sp);

    const band = &sp.bands[0];
    const len = band.len;
    const future = len / 2;
    const buf = try a.alloc(f32, len);
    defer a.free(buf);
    const out_l = try a.alloc(f32, cfg.bins);
    defer a.free(out_l);
    const out_r = try a.alloc(f32, cfg.bins);
    defer a.free(out_r);

    const f: f32 = @floatCast(bandCenter(cfg, 0));

    // 当前时刻之后才有 40Hz 信号：居中窗口立即看到，因果窗口只看到末端
    // 一个几乎被 Blackman 窗压到 0 的样本。
    @memset(buf, 0.0);
    fillSine(buf[len / 2 ..], f, cfg.sample_rate, 0.5);
    _ = era_spectrum_process_centered(sp, buf, buf, future, out_l, out_r);
    const centered = out_l[0];
    try testing.expect(centered > 0.05);

    @memset(buf, 0.0);
    _ = era_spectrum_process(sp, buf, buf, out_l, out_r);
    try testing.expect(out_l[0] < 0.01);
}

test "era_spectrum: 短窗前端补零与长窗尾部截取等价" {
    const a = testing.allocator;
    const cfg = precisionConfig();
    const sp = try era_spectrum_create(a, cfg);
    defer era_spectrum_destroy(sp);

    const out_a = try a.alloc(f32, cfg.bins);
    defer a.free(out_a);
    const out_b = try a.alloc(f32, cfg.bins);
    defer a.free(out_b);
    const out_r = try a.alloc(f32, cfg.bins);
    defer a.free(out_r);

    const short_len: usize = 2400;
    const short = try a.alloc(f32, short_len);
    defer a.free(short);
    fillSine(short, 1000.0, cfg.sample_rate, 1.0);

    const padded = try a.alloc(f32, cfg.max_window);
    defer a.free(padded);
    @memset(padded, 0.0);
    @memcpy(padded[cfg.max_window - short_len ..], short);

    era_spectrum_reset(sp);
    _ = era_spectrum_process(sp, short, short, out_a, out_r);
    era_spectrum_reset(sp);
    _ = era_spectrum_process(sp, padded, padded, out_b, out_r);
    try testing.expectEqualSlices(f32, out_a, out_b);

    const long_len: usize = 16000;
    const long = try a.alloc(f32, long_len);
    defer a.free(long);
    var seed: u32 = 0xdead_beef;
    for (long) |*v| {
        seed = seed *% 1664525 +% 1013904223;
        v.* = (@as(f32, @floatFromInt(seed >> 8)) / 8388608.0 - 1.0) * 0.2;
    }
    fillSine(long[long_len - cfg.max_window ..], 1000.0, cfg.sample_rate, 1.0);

    era_spectrum_reset(sp);
    _ = era_spectrum_process(sp, long, long, out_a, out_r);
    era_spectrum_reset(sp);
    _ = era_spectrum_process(sp, long[long_len - cfg.max_window ..], long[long_len - cfg.max_window ..], out_b, out_r);
    try testing.expectEqualSlices(f32, out_a, out_b);
}

test "era_spectrum: AGC / γ / 倾斜 / 峰值保持" {
    const a = testing.allocator;
    const n: usize = 12288;
    const l = try a.alloc(f32, n);
    defer a.free(l);
    const out_l = try a.alloc(f32, 128);
    defer a.free(out_l);
    const out_r = try a.alloc(f32, 128);
    defer a.free(out_r);
    const peak_l = try a.alloc(f32, 128);
    defer a.free(peak_l);
    const peak_r = try a.alloc(f32, 128);
    defer a.free(peak_r);

    // γ：同一 -30dB 输入，γ=0.5 的输出应高于 γ=1.0。
    const base = EraSpectrumConfig{ .agc_enabled = false, .gamma = 1.0, .tilt_db_per_oct = 0.0, .peak_hold = false };
    const sp1 = try era_spectrum_create(a, base);
    defer era_spectrum_destroy(sp1);
    const cfg2 = base;
    var cfg_gamma = cfg2;
    cfg_gamma.gamma = 0.5;
    const sp2 = try era_spectrum_create(a, cfg_gamma);
    defer era_spectrum_destroy(sp2);

    const idx = expectedBand(1000.0, base.min_hz, base.max_hz, base.bins);
    const f: f32 = @floatCast(bandCenter(base, idx));
    fillSine(l, f, base.sample_rate, 0.0316228);
    _ = era_spectrum_process(sp1, l, l, out_l, out_r);
    const raw = out_l[idx];
    _ = era_spectrum_process(sp2, l, l, out_l, out_r);
    try testing.expect(out_l[idx] > raw);

    // 高频倾斜：8kHz 在 +6dB/oct 下应高于 0dB/oct。
    var cfg_tilt = base;
    cfg_tilt.tilt_db_per_oct = 6.0;
    const sp3 = try era_spectrum_create(a, cfg_tilt);
    defer era_spectrum_destroy(sp3);
    fillSine(l, 8000.0, base.sample_rate, 0.1);
    _ = era_spectrum_process(sp1, l, l, out_l, out_r);
    const flat = out_l[peakBand(out_l)];
    _ = era_spectrum_process(sp3, l, l, out_l, out_r);
    try testing.expect(out_l[peakBand(out_l)] > flat);

    // 峰值保持：响帧后静音，峰值仍在；连续静音后衰减。
    var cfg_peak = base;
    cfg_peak.peak_hold = true;
    cfg_peak.peak_decay_per_s = 2.0;
    const sp4 = try era_spectrum_create(a, cfg_peak);
    defer era_spectrum_destroy(sp4);
    fillSine(l, f, base.sample_rate, 0.5);
    _ = era_spectrum_process(sp4, l, l, out_l, out_r);
    era_spectrum_peaks(sp4, peak_l, peak_r);
    const held = peak_l[idx];
    try testing.expect(held > 0.1);

    @memset(l, 0.0);
    _ = era_spectrum_process(sp4, l, l, out_l, out_r);
    era_spectrum_peaks(sp4, peak_l, peak_r);
    try testing.expect(peak_l[idx] > 0.0);
    try testing.expect(peak_l[idx] < held);

    var i: usize = 0;
    while (i < 40) : (i += 1) _ = era_spectrum_process(sp4, l, l, out_l, out_r);
    era_spectrum_peaks(sp4, peak_l, peak_r);
    try testing.expect(peak_l[idx] < 0.01);

    // AGC：弱音连续处理应逐步抬升（不改变 raw 节拍判定）。
    var cfg_agc = base;
    cfg_agc.agc_enabled = true;
    cfg_agc.agc_target_db = -20.0;
    const sp5 = try era_spectrum_create(a, cfg_agc);
    defer era_spectrum_destroy(sp5);
    fillSine(l, f, base.sample_rate, 0.01);
    _ = era_spectrum_process(sp5, l, l, out_l, out_r);
    const first = out_l[idx];
    i = 0;
    while (i < 80) : (i += 1) _ = era_spectrum_process(sp5, l, l, out_l, out_r);
    try testing.expect(out_l[idx] > first);
}

test "era_spectrum: 运行时开关 AGC / γ / 倾斜" {
    const a = testing.allocator;
    const cfg = precisionConfig();
    const sp = try era_spectrum_create(a, cfg);
    defer era_spectrum_destroy(sp);

    // γ：合法值写入，非法值忽略，越界收敛。
    era_spectrum_set_gamma(sp, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 0.5), sp.gamma, 1e-6);
    era_spectrum_set_gamma(sp, 0.0);
    try testing.expectApproxEqAbs(@as(f32, 0.5), sp.gamma, 1e-6);
    era_spectrum_set_gamma(sp, 99.0);
    try testing.expectApproxEqAbs(@as(f32, 4.0), sp.gamma, 1e-6);

    // 倾斜：重算全部带，8kHz 带增益应 > 1；越界收敛。
    era_spectrum_set_tilt(sp, 6.0);
    try testing.expectApproxEqAbs(@as(f32, 6.0), sp.tilt_db_per_oct, 1e-6);
    const idx8 = expectedBand(8000.0, cfg.min_hz, cfg.max_hz, cfg.bins);
    try testing.expect(sp.bands[idx8].tilt_gain > 1.0);
    era_spectrum_set_tilt(sp, 99.0);
    try testing.expectApproxEqAbs(@as(f32, 24.0), sp.tilt_db_per_oct, 1e-6);

    // AGC：开关切换，关闭时增益复位。
    era_spectrum_set_agc(sp, true);
    try testing.expect(sp.agc_enabled);
    sp.agc_gain = 2.0;
    era_spectrum_set_agc(sp, false);
    try testing.expect(!sp.agc_enabled);
    try testing.expectEqual(@as(f32, 1.0), sp.agc_gain);
}

test "era_spectrum: reset 清空峰值/AGC/节拍状态、参数 getter 正确" {
    const a = testing.allocator;
    const cfg = precisionConfig();
    var cfg2 = cfg;
    cfg2.sample_rate = 44100;
    cfg2.bins = 96;
    const sp = try era_spectrum_create(a, cfg2);
    defer era_spectrum_destroy(sp);

    try testing.expectEqual(@as(u32, 96), era_spectrum_bins(sp));
    try testing.expectEqual(@as(u32, 44100), era_spectrum_sample_rate(sp));

    const n: usize = cfg2.max_window;
    const l = try a.alloc(f32, n);
    defer a.free(l);
    const out_l = try a.alloc(f32, cfg2.bins);
    defer a.free(out_l);
    const out_r = try a.alloc(f32, cfg2.bins);
    defer a.free(out_r);
    const peak_l = try a.alloc(f32, cfg2.bins);
    defer a.free(peak_l);
    const peak_r = try a.alloc(f32, cfg2.bins);
    defer a.free(peak_r);

    fillSine(l, 440.0, cfg2.sample_rate, 1.0);
    _ = era_spectrum_process(sp, l, l, out_l, out_r);
    era_spectrum_peaks(sp, peak_l, peak_r);
    try testing.expect(peakBand(peak_l) < cfg2.bins);

    era_spectrum_reset(sp);
    era_spectrum_peaks(sp, peak_l, peak_r);
    for (peak_l) |v| try testing.expectEqual(@as(f32, 0.0), v);
    for (peak_r) |v| try testing.expectEqual(@as(f32, 0.0), v);
    try testing.expectEqual(@as(f32, 1.0), sp.agc_gain);
}

test "era_spectrum: 非法配置拒绝" {
    const a = testing.allocator;
    try testing.expectError(error.InvalidArgument, era_spectrum_create(a, .{ .sample_rate = 0 }));
    try testing.expectError(error.InvalidArgument, era_spectrum_create(a, .{ .bins = 0 }));
    try testing.expectError(error.InvalidArgument, era_spectrum_create(a, .{ .min_hz = 0 }));
    try testing.expectError(error.InvalidArgument, era_spectrum_create(a, .{ .max_hz = 24000 }));
    try testing.expectError(error.InvalidArgument, era_spectrum_create(a, .{ .max_window = 32 }));
    try testing.expectError(error.InvalidArgument, era_spectrum_create(a, .{ .gamma = 0 }));
}

// ---------------------------------------------------------------------------
// Stage 适配测试
// ---------------------------------------------------------------------------

// 交错缓冲（前两声道）与平面缓冲走同一核心，结果应逐带一致。
test "era_spectrum: Stage 交错立体声与平面路径一致" {
    const a = testing.allocator;
    var cfg = precisionConfig();
    cfg.max_window = 4096;
    const sp_stage = try era_spectrum_create(a, cfg);
    defer era_spectrum_destroy(sp_stage);
    const sp_planar = try era_spectrum_create(a, cfg);
    defer era_spectrum_destroy(sp_planar);

    const frames: usize = cfg.max_window;
    const l = try a.alloc(f32, frames);
    defer a.free(l);
    const r = try a.alloc(f32, frames);
    defer a.free(r);
    fillSine(l, 440.0, cfg.sample_rate, 0.8);
    fillSine(r, 1000.0, cfg.sample_rate, 0.4);

    const inter = try a.alloc(f32, frames * 2);
    defer a.free(inter);
    for (0..frames) |i| {
        inter[2 * i] = l[i];
        inter[2 * i + 1] = r[i];
    }

    const bins: usize = cfg.bins;
    const pl = try a.alloc(f32, bins);
    defer a.free(pl);
    const pr = try a.alloc(f32, bins);
    defer a.free(pr);
    const sl = try a.alloc(f32, bins);
    defer a.free(sl);
    const sr = try a.alloc(f32, bins);
    defer a.free(sr);

    _ = era_spectrum_process(sp_planar, l, r, pl, pr);

    const stage = era_spectrum_stage(sp_stage, 2);
    try testing.expectEqual(@as(u8, 2), stage.channels);
    stage.process(inter, frames);
    _ = era_spectrum_stage_frame(sp_stage, sl, sr);

    for (0..bins) |i| {
        try testing.expectApproxEqAbs(pl[i], sl[i], 1e-5);
        try testing.expectApproxEqAbs(pr[i], sr[i], 1e-5);
    }
    try testing.expectEqual(expectedBand(440.0, cfg.min_hz, cfg.max_hz, cfg.bins), peakBand(sl));
    try testing.expectEqual(expectedBand(1000.0, cfg.min_hz, cfg.max_hz, cfg.bins), peakBand(sr));
}

// 单声道输入左右镜像；峰值保持线与主路径共用同一状态。
test "era_spectrum: Stage 单声道左右镜像" {
    const a = testing.allocator;
    var cfg = precisionConfig();
    cfg.max_window = 4096;
    cfg.peak_hold = true;
    const sp = try era_spectrum_create(a, cfg);
    defer era_spectrum_destroy(sp);

    const frames: usize = cfg.max_window;
    const pcm = try a.alloc(f32, frames);
    defer a.free(pcm);
    fillSine(pcm, 440.0, cfg.sample_rate, 0.8);

    const stage = era_spectrum_stage(sp, 1);
    try testing.expectEqual(@as(u8, 1), stage.channels);
    stage.process(pcm, frames);

    const bins: usize = cfg.bins;
    const l = try a.alloc(f32, bins);
    defer a.free(l);
    const r = try a.alloc(f32, bins);
    defer a.free(r);
    _ = era_spectrum_stage_frame(sp, l, r);

    const band = expectedBand(440.0, cfg.min_hz, cfg.max_hz, cfg.bins);
    try testing.expect(l[band] > 0.3);
    for (0..bins) |i| try testing.expectApproxEqAbs(l[i], r[i], 1e-6);

    const peak_l = try a.alloc(f32, bins);
    defer a.free(peak_l);
    const peak_r = try a.alloc(f32, bins);
    defer a.free(peak_r);
    era_spectrum_peaks(sp, peak_l, peak_r);
    try testing.expectApproxEqAbs(l[band], peak_l[band], 1e-6);
    try testing.expectApproxEqAbs(r[band], peak_r[band], 1e-6);
}

// 空帧为无操作（保留上一帧），reset 清空输出与节拍。
test "era_spectrum: Stage 空帧与 reset" {
    const a = testing.allocator;
    var cfg = precisionConfig();
    cfg.max_window = 2048;
    const sp = try era_spectrum_create(a, cfg);
    defer era_spectrum_destroy(sp);

    const bins: usize = cfg.bins;
    const l = try a.alloc(f32, bins);
    defer a.free(l);
    const r = try a.alloc(f32, bins);
    defer a.free(r);

    // 从未处理：输出全 0。
    try testing.expectEqual(@as(f32, 0.0), era_spectrum_stage_frame(sp, l, r));
    for (l) |v| try testing.expectEqual(@as(f32, 0.0), v);

    const frames: usize = cfg.max_window;
    const pcm = try a.alloc(f32, frames * 2);
    defer a.free(pcm);
    // 交错双声道同信号：直接对整块填正弦会等效降采样（1kHz → 2kHz）。
    {
        const w = 2.0 * std.math.pi * 1000.0 / @as(f64, @floatFromInt(cfg.sample_rate));
        for (0..frames) |i| {
            const v: f32 = 0.8 * @as(f32, @floatCast(@sin(w * @as(f64, @floatFromInt(i)))));
            pcm[2 * i] = v;
            pcm[2 * i + 1] = v;
        }
    }
    const stage = era_spectrum_stage(sp, 2);
    stage.process(pcm, frames);
    _ = era_spectrum_stage_frame(sp, l, r);
    try testing.expect(l[expectedBand(1000.0, cfg.min_hz, cfg.max_hz, cfg.bins)] > 0.3);

    // 空帧不改变上一帧结果。
    stage.process(pcm[0..0], 0);
    const pl = try a.alloc(f32, bins);
    defer a.free(pl);
    const pr = try a.alloc(f32, bins);
    defer a.free(pr);
    _ = era_spectrum_stage_frame(sp, pl, pr);
    try testing.expectEqualSlices(f32, l, pl);

    era_spectrum_reset(sp);
    try testing.expectEqual(@as(f32, 0.0), era_spectrum_stage_frame(sp, l, r));
    for (l) |v| try testing.expectEqual(@as(f32, 0.0), v);
    for (r) |v| try testing.expectEqual(@as(f32, 0.0), v);
}
