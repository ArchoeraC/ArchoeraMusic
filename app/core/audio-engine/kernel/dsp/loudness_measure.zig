// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! 离线 EBU R128 / ITU-R BS.1770-4 集成响度 + 采样峰值**测量**
//! （docs/audio-kernel-zig.md §14；方向① D3/D6 扩张）。
//!
//! 与同目录 `loudness.zig`（静态增益补偿，`era_loudness_*` / `zk_dsp_loudness_*`）
//! **互不影响**：本模块只负责**测量**，供 scanner 离线分析本地文件，把集成响度 +
//! 线性采样峰值写入曲库（`loudness_lufs` / `loudness_peak`），作为无 ReplayGain
//! 标签文件的兜底归一化增益来源（真正应用由播放侧运行时命令完成）。
//!
//! 算法（BS.1770-4）：
//!   1. K 加权：两级 IIR（高频架 + RLB 高通），逐声道独立；L/R 权重 G=1.0，
//!      >2 声道按 `era_r128_channel_gain` 注释里的标准 G 权重处理（LFE 不参与）。
//!   2. 400 ms 块、75% 重叠：以 100 ms 子块为单位，每完成一个新子块即出一个
//!      400 ms 块（= 最近 4 个子块的能量均值）。
//!   3. 门限：绝对门 −70 LUFS；相对门 = 通过绝对门的块能量均值 − 10 LU；
//!      集成响度 = −0.691 + 10·log10(两道门内块能量均值)。
//!   4. 峰值：全声道最大 |样本|（**线性采样峰值**，非 true peak）。
//!
//! 内存纪律：只保留**每块能量**（约 10 块/秒），不保留整文件 PCM；解码输入按
//! 有界块喂入 `era_loudness_meter_push`。
//!
//! 命名自有（`era_` 前缀）；系数设计参数与门限常量来自规范（事实），不照搬
//! FFmpeg / libebur128 等上游标识符。规范锚点：立体声 1 kHz 满幅正弦 ≈ 0.0 LUFS
//! （ffmpeg `ebur128` 同源复核；−23 dBFS 立体声 1 kHz 正弦 ≈ −23.0 LUFS）。

const std = @import("std");
const Biquad = @import("biquad.zig").EraBiquadState;

/// 支持的声道数上限（与内核 1..8 声道契约一致）。
pub const era_r128_max_channels: usize = 8;

/// 集成响度偏移（BS.1770-4：−0.691 LU）。
pub const era_r128_offset_lufs: f64 = -0.691;
/// 绝对门限（LUFS）：低于该值的块不参与。
pub const era_r128_absolute_gate_lufs: f64 = -70.0;
/// 相对门限相对量（LU）：相对门 = 绝对门内块能量均值对应的响度 − 10 LU。
pub const era_r128_relative_gate_lu: f64 = 10.0;

// ── K 加权滤波器设计参数（BS.1770-4 原型；与参考实现同款常量）──────────────
/// 第一级高频架：中心频率（Hz）。
const era_r128_shelf_f0: f64 = 1681.974450955533;
/// 第一级高频架：高频增益（dB）。
const era_r128_shelf_gain_db: f64 = 3.999843853973347;
/// 第一级高频架：Q。
const era_r128_shelf_q: f64 = 0.7071752369554196;
/// 第一级高频架：中间增益指数（Vb = Vh^exp）。
const era_r128_shelf_vb_exp: f64 = 0.4996667741545416;
/// 第二级 RLB 高通：截止频率（Hz）。
const era_r128_rlb_f0: f64 = 38.13547087602444;
/// 第二级 RLB 高通：Q。
const era_r128_rlb_q: f64 = 0.5003270373238773;

/// 声道功率权重 G（BS.1770-4 表 3）：
///   - 单/双声道（1/2）：全部 1.0；
///   - ≥6 声道：按标准声道序 L R C LFE Ls Rs …，LFE（index 3）不参与，
///     环绕（index ≥4）取 +1.5 dB（≈1.41254）；
///   - 3..5 声道：声道序无法可靠判定 → 等权 1.0（避免误把非 LFE 声道当 LFE 静音）。
pub fn era_r128_channel_gain(ch: usize, channels: usize) f64 {
    if (channels <= 2) return 1.0;
    if (channels >= 6) {
        if (ch == 3) return 0.0;
        if (ch >= 4) return 1.4125375446227544; // +1.5 dB
    }
    return 1.0;
}

/// 第一级 K 加权（高频架，BS.1770-4）；写入 `EraBiquadState` 系数（a0 归一为 1）。
fn era_r128_prefilter(f: *Biquad, sample_rate: u32) void {
    const fs: f64 = @floatFromInt(sample_rate);
    const k = @tan(std.math.pi * era_r128_shelf_f0 / fs);
    const vh = std.math.pow(f64, 10.0, era_r128_shelf_gain_db / 20.0);
    const vb = std.math.pow(f64, vh, era_r128_shelf_vb_exp);
    const a0 = 1.0 + k / era_r128_shelf_q + k * k;
    f.b0 = @floatCast((vh + vb * k / era_r128_shelf_q + k * k) / a0);
    f.b1 = @floatCast(2.0 * (k * k - vh) / a0);
    f.b2 = @floatCast((vh - vb * k / era_r128_shelf_q + k * k) / a0);
    f.a1 = @floatCast(2.0 * (k * k - 1.0) / a0);
    f.a2 = @floatCast((1.0 - k / era_r128_shelf_q + k * k) / a0);
    f.x1 = 0.0;
    f.x2 = 0.0;
    f.y1 = 0.0;
    f.y2 = 0.0;
}

/// 第二级 K 加权（RLB 高通，BS.1770-4）：分子 [1, −2, 1]。
fn era_r128_rlb_highpass(f: *Biquad, sample_rate: u32) void {
    const fs: f64 = @floatFromInt(sample_rate);
    const k = @tan(std.math.pi * era_r128_rlb_f0 / fs);
    const den = 1.0 + k / era_r128_rlb_q + k * k;
    f.b0 = 1.0;
    f.b1 = -2.0;
    f.b2 = 1.0;
    f.a1 = @floatCast(2.0 * (k * k - 1.0) / den);
    f.a2 = @floatCast((1.0 - k / era_r128_rlb_q + k * k) / den);
    f.x1 = 0.0;
    f.x2 = 0.0;
    f.y1 = 0.0;
    f.y2 = 0.0;
}

/// 测量结果。`valid=false` 表示没有通过绝对门的 400 ms 块（如静音 / 时长不足），
/// 此时 `integrated_lufs` 无意义（保持 0.0）；`peak` 仍为全样本最大 |样本|。
pub const EraLoudnessResult = struct {
    integrated_lufs: f64 = 0.0,
    peak: f64 = 0.0,
    valid: bool = false,
};

/// 流式集成响度测量器（有界内存：仅累积每块能量）。
pub const EraLoudnessMeter = struct {
    allocator: std.mem.Allocator,
    sample_rate: u32,
    channels: usize,
    /// 100 ms 子块帧数（四舍五入，至少 1）。
    sub_frames: usize,
    /// 每声道两级 K 加权状态。
    filters: [era_r128_max_channels][2]Biquad,
    /// 每声道功率权重 G。
    channel_gain: [era_r128_max_channels]f64,
    /// 当前子块每声道的 K 加权平方和。
    sub_sum_sq: [era_r128_max_channels]f64,
    /// 最近 4 个已完成子块的每声道均方（环形缓冲）。
    sub_hist: [4][era_r128_max_channels]f64,
    sub_count: usize = 0,
    sub_write: usize = 0,
    sub_completed: usize = 0,
    /// 每个 400 ms 块的加权能量 z_j（仅保留块能量，不保留 PCM）。
    block_z: std.ArrayList(f64),
    peak: f64 = 0.0,
    oom: bool = false,

    pub fn deinit(self: *EraLoudnessMeter) void {
        self.block_z.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

/// 创建测量器（`channels` ∈ 1..=8，`sample_rate` > 0）。
pub fn era_loudness_meter_init(
    allocator: std.mem.Allocator,
    sample_rate: u32,
    channels: usize,
) !*EraLoudnessMeter {
    if (sample_rate == 0 or channels == 0 or channels > era_r128_max_channels)
        return error.InvalidArgument;
    const m = try allocator.create(EraLoudnessMeter);
    m.* = .{
        .allocator = allocator,
        .sample_rate = sample_rate,
        .channels = channels,
        .sub_frames = @max(1, @as(usize, (sample_rate + 5) / 10)),
        .filters = std.mem.zeroes([era_r128_max_channels][2]Biquad),
        .channel_gain = std.mem.zeroes([era_r128_max_channels]f64),
        .sub_sum_sq = std.mem.zeroes([era_r128_max_channels]f64),
        .sub_hist = std.mem.zeroes([4][era_r128_max_channels]f64),
        .block_z = .empty,
    };
    for (0..channels) |ch| {
        m.channel_gain[ch] = era_r128_channel_gain(ch, channels);
        era_r128_prefilter(&m.filters[ch][0], sample_rate);
        era_r128_rlb_highpass(&m.filters[ch][1], sample_rate);
    }
    return m;
}

/// 喂入交错 float32 PCM（`interleaved.len >= frames × channels`）。可多次调用。
pub fn era_loudness_meter_push(
    m: *EraLoudnessMeter,
    interleaved: []const f32,
    frames: usize,
) void {
    if (frames == 0) return;
    const ch_n = m.channels;
    var f: usize = 0;
    while (f < frames) : (f += 1) {
        const base = f * ch_n;
        var ch: usize = 0;
        while (ch < ch_n) : (ch += 1) {
            const x = interleaved[base + ch];
            const ax: f64 = @abs(@as(f64, x));
            if (ax > m.peak) m.peak = ax;
            const y0 = m.filters[ch][0].tick(x);
            const y1 = m.filters[ch][1].tick(y0);
            const y: f64 = y1;
            m.sub_sum_sq[ch] += y * y;
        }
        m.sub_count += 1;
        if (m.sub_count >= m.sub_frames) era_r128_finalize_sub(m);
    }
}

/// 收尾一个 100 ms 子块；每凑满 4 个子块即产出一个 400 ms 块的加权能量 z_j。
fn era_r128_finalize_sub(m: *EraLoudnessMeter) void {
    const n: f64 = @floatFromInt(m.sub_count);
    for (0..m.channels) |ch| {
        m.sub_hist[m.sub_write][ch] = m.sub_sum_sq[ch] / n;
        m.sub_sum_sq[ch] = 0.0;
    }
    m.sub_write = (m.sub_write + 1) % 4;
    m.sub_count = 0;
    m.sub_completed += 1;
    if (m.sub_completed < 4) return;

    var z: f64 = 0.0;
    for (0..m.channels) |ch| {
        var acc: f64 = 0.0;
        for (0..4) |k| acc += m.sub_hist[k][ch];
        z += m.channel_gain[ch] * (acc / 4.0);
    }
    m.block_z.append(m.allocator, z) catch {
        m.oom = true;
    };
}

/// 计算集成响度（含绝对 / 相对门限）并返回结果。结束后测量器仍可复用读取
/// （本调用不释放状态，仅计算）。
pub fn era_loudness_meter_finish(m: *EraLoudnessMeter) EraLoudnessResult {
    var res = EraLoudnessResult{ .peak = m.peak };
    if (m.oom) return res;
    if (era_r128_integrated_lufs(m.block_z.items)) |lufs| {
        res.integrated_lufs = lufs;
        res.valid = true;
    }
    return res;
}

/// 由 400 ms 块的加权能量 z_j 序列计算集成响度（BS.1770-4 门限）。
/// 返回 null = 无通过绝对门的块（静音 / 过短）。纯函数，便于确定性单测。
pub fn era_r128_integrated_lufs(blocks: []const f64) ?f64 {
    if (blocks.len == 0) return null;

    // 绝对门：块响度 > −70 LUFS 才参与。
    var sum_abs: f64 = 0.0;
    var cnt_abs: usize = 0;
    for (blocks) |z| {
        if (!(z > 0.0)) continue;
        const ls = era_r128_offset_lufs + 10.0 * @log10(z);
        if (ls > era_r128_absolute_gate_lufs) {
            sum_abs += z;
            cnt_abs += 1;
        }
    }
    if (cnt_abs == 0) return null;

    const mean_abs = sum_abs / @as(f64, @floatFromInt(cnt_abs));
    if (!(mean_abs > 0.0)) return null;
    const rel_gate =
        era_r128_offset_lufs + 10.0 * @log10(mean_abs) - era_r128_relative_gate_lu;

    // 同时通过绝对门与相对门的块。
    var sum_g: f64 = 0.0;
    var cnt_g: usize = 0;
    for (blocks) |z| {
        if (!(z > 0.0)) continue;
        const ls = era_r128_offset_lufs + 10.0 * @log10(z);
        if (ls > era_r128_absolute_gate_lufs and ls > rel_gate) {
            sum_g += z;
            cnt_g += 1;
        }
    }
    if (cnt_g == 0) return null;
    const mean_g = sum_g / @as(f64, @floatFromInt(cnt_g));
    if (!(mean_g > 0.0)) return null;

    return era_r128_offset_lufs + 10.0 * @log10(mean_g);
}

// ---------------------------------------------------------------------------
// 单元测试（确定性合成信号）
// ---------------------------------------------------------------------------

const testing = std.testing;

/// 用同相正弦填充交错缓冲（确定性；无随机、无等待）。
fn fillSine(buf: []f32, frames: usize, channels: usize, freq: f64, amp: f32, sample_rate: u32) void {
    const w = 2.0 * std.math.pi * freq / @as(f64, @floatFromInt(sample_rate));
    for (0..frames) |f| {
        const v = amp * @as(f32, @floatCast(@sin(w * @as(f64, @floatFromInt(f)))));
        for (0..channels) |ch| buf[f * channels + ch] = v;
    }
}

fn measureSine(
    allocator: std.mem.Allocator,
    sample_rate: u32,
    channels: usize,
    seconds: usize,
    freq: f64,
    amp: f32,
) !EraLoudnessResult {
    const frames = sample_rate * seconds;
    const buf = try allocator.alloc(f32, frames * channels);
    defer allocator.free(buf);
    fillSine(buf, frames, channels, freq, amp, sample_rate);
    const m = try era_loudness_meter_init(allocator, sample_rate, channels);
    defer m.deinit();
    era_loudness_meter_push(m, buf, frames);
    return era_loudness_meter_finish(m);
}

test "era_r128: 立体声 1kHz 满幅正弦 ≈ 0.0 LUFS（规范锚点；ffmpeg ebur128 复核）" {
    // 说明：规范校准为 −23 dBFS 立体声 1kHz 正弦 ≈ −23.0 LUFS，故满幅 ≈ 0.0 LUFS。
    const r = try measureSine(testing.allocator, 48000, 2, 2, 1000.0, 1.0);
    try testing.expect(r.valid);
    try testing.expectApproxEqAbs(@as(f64, 0.0), r.integrated_lufs, 0.15);
    try testing.expectApproxEqAbs(@as(f64, 1.0), r.peak, 1e-4);
}

test "era_r128: 立体声 0.5 幅 ≈ −6.02 LUFS（幅度减半 = −6.02 LU）" {
    const r = try measureSine(testing.allocator, 48000, 2, 2, 1000.0, 0.5);
    try testing.expect(r.valid);
    try testing.expectApproxEqAbs(@as(f64, -6.0206), r.integrated_lufs, 0.15);
    try testing.expectApproxEqAbs(@as(f64, 0.5), r.peak, 1e-4);
}

test "era_r128: 单声道与立体声相差 +3.01 LU（声道能量相加）" {
    const mono = try measureSine(testing.allocator, 48000, 1, 2, 1000.0, 0.5);
    const stereo = try measureSine(testing.allocator, 48000, 2, 2, 1000.0, 0.5);
    try testing.expect(mono.valid and stereo.valid);
    try testing.expectApproxEqAbs(mono.integrated_lufs + 3.0103, stereo.integrated_lufs, 0.05);
}

test "era_r128: 峰值取全声道最大 |样本|" {
    var buf = [_]f32{ 0.1, -0.7, 0.9, -0.2, 0.3, 0.0 };
    const m = try era_loudness_meter_init(testing.allocator, 48000, 2);
    defer m.deinit();
    era_loudness_meter_push(m, &buf, 3); // 3 帧 × 2 声道
    const r = era_loudness_meter_finish(m);
    try testing.expectApproxEqAbs(@as(f64, 0.9), r.peak, 1e-6);
    // 时长不足一个 400ms 块 → 无有效集成响度。
    try testing.expect(!r.valid);
}

test "era_r128 gating: 相对门剔除远低于主体的安静块（−40 LU）" {
    // 5 个响块（z=1）+ 5 个安静块（z=1e-4，−40 LUFS）：安静块低于相对门 → 仅响块参与。
    var blocks: [10]f64 = undefined;
    for (0..5) |i| blocks[i] = 1.0;
    for (5..10) |i| blocks[i] = 1e-4;
    const lufs = era_r128_integrated_lufs(&blocks) orelse return error.TestUnexpectedResult;
    try testing.expectApproxEqAbs(era_r128_offset_lufs, lufs, 1e-6);
}

test "era_r128 gating: 全部低于绝对门 → null；空块序列 → null" {
    var quiet = [_]f64{ 1e-8, 1e-9, 1e-10 }; // 全 < −70 LUFS
    try testing.expect(era_r128_integrated_lufs(&quiet) == null);
    try testing.expect(era_r128_integrated_lufs(&[_]f64{}) == null);
    var zero = [_]f64{ 0.0, 0.0 };
    try testing.expect(era_r128_integrated_lufs(&zero) == null);
}

test "era_r128 gating: 单独响块 → −0.691 + 10log10(z)" {
    var one = [_]f64{0.5};
    const lufs = era_r128_integrated_lufs(&one) orelse return error.TestUnexpectedResult;
    try testing.expectApproxEqAbs(era_r128_offset_lufs + 10.0 * @log10(0.5), lufs, 1e-9);
}

test "era_r128: 静音无通过门限的块 → valid=false，峰值为 0" {
    const frames = 48000;
    const buf = try testing.allocator.alloc(f32, frames * 2);
    defer testing.allocator.free(buf);
    @memset(buf, 0.0);
    const m = try era_loudness_meter_init(testing.allocator, 48000, 2);
    defer m.deinit();
    era_loudness_meter_push(m, buf, frames);
    const r = era_loudness_meter_finish(m);
    try testing.expect(!r.valid);
    try testing.expectEqual(@as(f64, 0.0), r.peak);
}

test "era_r128: 声道权重（>2ch 标准 G 表；LFE 不参与）" {
    try testing.expectEqual(@as(f64, 1.0), era_r128_channel_gain(0, 1));
    try testing.expectEqual(@as(f64, 1.0), era_r128_channel_gain(1, 2));
    // 5.1：LFE（index 3）为 0，环绕 +1.5dB
    try testing.expectEqual(@as(f64, 0.0), era_r128_channel_gain(3, 6));
    try testing.expectApproxEqRel(@as(f64, 1.4125375446227544), era_r128_channel_gain(4, 6), 1e-9);
    // 3..5 声道：等权
    try testing.expectEqual(@as(f64, 1.0), era_r128_channel_gain(3, 4));
}

test "era_r128: 参数非法（0 采样率 / 0 或超限声道）→ error" {
    try testing.expectError(error.InvalidArgument, era_loudness_meter_init(testing.allocator, 0, 2));
    try testing.expectError(error.InvalidArgument, era_loudness_meter_init(testing.allocator, 48000, 0));
    try testing.expectError(error.InvalidArgument, era_loudness_meter_init(testing.allocator, 48000, 9));
}
