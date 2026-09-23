// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! 参数化均衡器（docs/audio-kernel-zig.md §14；扩张计划方向① D1）
//!
//! 任意段数（≤ `era_peq_max_bands`）的 Biquad 均衡器：每段可配
//! {kind, freq, Q, gain_db, enabled}，kind ∈ {peak, low-shelf, high-shelf}，
//! 外加统一前级增益。系数计算复用 `biquad.zig`（与 C 壳 `equalizer.c` 同式）。
//!
//! 行为约定：
//!   - 未启用 / 无有效段 / 全零增益且 preamp=0：整链旁通（逐位不变）；
//!   - `set_band` 会令活动段数 = max(活动段数, index+1)；`clear` 复位段表与状态；
//!   - 非有限 freq/gain、非法 Q 一律夹取到安全范围（NaN 防护）。
//!
//! 对外经 `zk_dsp_peq_*` C ABI 暴露；C 壳优先路由内核、失败回退纯 C 实现。
//! 命名自有（`era_` 前缀），不照搬 FFmpeg / SoX / WebAudio 等上游标识符。

const std = @import("std");
const biquad = @import("biquad.zig");
const math = @import("dspmath.zig");
const Stage = @import("stage.zig").Stage;

/// 单实例最大段数（C ABI 契约；与 C 壳 `PEQ_MAX_BANDS` 一致）。
pub const era_peq_max_bands: usize = 16;

/// 段类型（数值与 C `enum ZkBandKind` 对齐）。
pub const EraBandKind = enum(u8) {
    peak = 0,
    low_shelf = 1,
    high_shelf = 2,
};

/// Q 夹取范围（sane Q；NaN/非正回落到默认值）。
pub const era_peq_min_q: f32 = 0.1;
pub const era_peq_max_q: f32 = 40.0;
pub const era_peq_default_q: f32 = 0.7071;

/// 频率下限（Hz）；上限为 Nyquist 的 0.999 倍。
pub const era_peq_min_freq: f32 = 1.0;

/// 单个参数段。
pub const EraBand = struct {
    kind: EraBandKind = .peak,
    freq: f32 = 1000.0,
    q: f32 = era_peq_default_q,
    gain_db: f32 = 0.0,
    enabled: bool = true,
};

/// 参数化 EQ 实例（不透明于 C 侧 `ZkDspPeq`）。
pub const EraParamEq = struct {
    allocator: std.mem.Allocator,
    sample_rate: u32,
    channels: u8,
    max_bands: usize,
    band_count: usize = 0,
    preamp_db: f32 = 0.0,
    enabled: bool = true,
    bands: []EraBand,
    /// `[band * channels + ch]`，长度 = max_bands × channels。
    filters: []biquad.EraBiquadState,
    /// 无有效段且 preamp=0：跳过整条链（对齐 C 直通）。
    passthrough: bool = true,

    fn recomputePassthrough(self: *EraParamEq) void {
        self.passthrough = self.preamp_db == 0.0 and self.allBandsZero();
    }

    fn allBandsZero(self: *const EraParamEq) bool {
        for (self.bands[0..self.band_count]) |b| {
            if (b.enabled and b.gain_db != 0.0) return false;
        }
        return true;
    }
};

/// 夹取频率到 (0, Nyquist)：NaN/非正 → 下限；超 Nyquist → 0.999·Nyquist。
pub fn era_peq_clamp_freq(freq: f32, sample_rate: u32) f32 {
    const sr: f32 = @floatFromInt(sample_rate);
    const nyq = sr * 0.5;
    const hi = nyq * 0.999;
    if (!(freq > 0.0)) return era_peq_min_freq; // 含 NaN
    if (freq < era_peq_min_freq) return era_peq_min_freq;
    if (freq > hi) return hi;
    return freq;
}

/// 夹取 Q：NaN/非正 → 默认；超上限 → 上限。
pub fn era_peq_clamp_q(q: f32) f32 {
    if (!(q >= era_peq_min_q)) return era_peq_default_q; // 含 NaN
    if (q > era_peq_max_q) return era_peq_max_q;
    return q;
}

/// 增益容错：非有限值 → 0 dB。
fn sanitizeGain(gain_db: f32) f32 {
    if (!std.math.isFinite(gain_db)) return 0.0;
    return gain_db;
}

/// 创建参数化 EQ（非法参数 / OOM 返回错误）。`max_bands` 夹取 [1, 16]。
pub fn era_peq_create(
    allocator: std.mem.Allocator,
    sample_rate: u32,
    channels: u8,
    max_bands: usize,
) !*EraParamEq {
    if (sample_rate == 0 or channels == 0) return error.InvalidArgument;
    const cap = std.math.clamp(max_bands, 1, era_peq_max_bands);
    const self = try allocator.create(EraParamEq);
    errdefer allocator.destroy(self);
    const bands = try allocator.alloc(EraBand, cap);
    for (bands) |*b| b.* = .{};
    const filters = try allocator.alloc(biquad.EraBiquadState, cap * @as(usize, channels));
    errdefer allocator.free(bands);
    for (filters) |*f| f.* = .{};
    self.* = .{
        .allocator = allocator,
        .sample_rate = sample_rate,
        .channels = channels,
        .max_bands = cap,
        .bands = bands,
        .filters = filters,
    };
    return self;
}

/// 销毁参数化 EQ（NULL 由 C 侧处理）。
pub fn era_peq_destroy(eq: *EraParamEq) void {
    const a = eq.allocator;
    a.free(eq.bands);
    a.free(eq.filters);
    a.destroy(eq);
}

/// 设置单段（index < max_bands）。非法 kind → 段置为禁用。
/// 会重算该段系数，并令活动段数 = max(活动段数, index+1)。
pub fn era_peq_set_band(
    eq: *EraParamEq,
    index: usize,
    kind_raw: u8,
    freq: f32,
    q: f32,
    gain_db: f32,
) void {
    if (index >= eq.max_bands) return;
    const kind: ?EraBandKind = switch (kind_raw) {
        0 => .peak,
        1 => .low_shelf,
        2 => .high_shelf,
        else => null,
    };
    if (kind == null) {
        eq.bands[index] = .{ .enabled = false };
        eq.recomputePassthrough();
        return;
    }
    const cf = era_peq_clamp_freq(freq, eq.sample_rate);
    const cq = era_peq_clamp_q(q);
    const cg = sanitizeGain(gain_db);
    eq.bands[index] = .{
        .kind = kind.?,
        .freq = cf,
        .q = cq,
        .gain_db = cg,
        .enabled = true,
    };
    recomputeBand(eq, index);
    if (eq.band_count < index + 1) eq.band_count = index + 1;
    eq.recomputePassthrough();
}

/// 重算某段全部声道的系数（不改动历史状态）。
fn recomputeBand(eq: *EraParamEq, index: usize) void {
    const b = eq.bands[index];
    const ch: usize = eq.channels;
    for (0..ch) |c| {
        const f = &eq.filters[index * ch + c];
        switch (b.kind) {
            .peak => biquad.era_biquad_peaking(f, b.freq, b.q, b.gain_db, eq.sample_rate),
            .low_shelf => biquad.era_biquad_low_shelf(f, b.freq, b.q, b.gain_db, eq.sample_rate),
            .high_shelf => biquad.era_biquad_high_shelf(f, b.freq, b.q, b.gain_db, eq.sample_rate),
        }
    }
}

/// 复位段表（活动段数归零）与全部滤波器状态；preamp 保留（单独设置）。
pub fn era_peq_clear(eq: *EraParamEq) void {
    eq.band_count = 0;
    for (eq.filters) |*f| f.reset();
    eq.passthrough = eq.preamp_db == 0.0;
}

/// 启用/禁用整链。
pub fn era_peq_set_enabled(eq: *EraParamEq, enabled: bool) void {
    eq.enabled = enabled;
}

/// 设置前级增益（dB）。
pub fn era_peq_set_preamp(eq: *EraParamEq, preamp_db: f32) void {
    eq.preamp_db = sanitizeGain(preamp_db);
    eq.recomputePassthrough();
}

/// 就地处理交错 float32 PCM（对照 C `parametric_eq_process`）。
/// `pcm.len == frames * channels`。
pub fn era_peq_process(eq: *EraParamEq, pcm: []f32, frames: usize) void {
    if (frames == 0) return;
    if (!eq.enabled) return;
    if (eq.passthrough) return;

    const ch: usize = eq.channels;
    const preamp = math.ampFromDb(eq.preamp_db);

    var band: usize = 0;
    while (band < eq.band_count) : (band += 1) {
        const b = eq.bands[band];
        if (!b.enabled or b.gain_db == 0.0) continue;
        for (0..ch) |c| {
            const f = &eq.filters[band * ch + c];
            var i: usize = 0;
            while (i < frames) : (i += 1) {
                pcm[i * ch + c] = f.tick(pcm[i * ch + c]);
            }
        }
    }

    if (preamp != 1.0) {
        const total = frames * ch;
        for (0..total) |i| pcm[i] *= preamp;
    }
}

/// 统一接口适配（见 `stage.zig`）。
pub fn era_peq_stage(eq: *EraParamEq) Stage {
    return .{ .ctx = @ptrCast(eq), .vtable = &vtable, .channels = eq.channels };
}

const vtable = Stage.VTable{ .process = processThunk };

fn processThunk(ctx: *anyopaque, pcm: []f32, frames: usize) void {
    const eq: *EraParamEq = @ptrCast(@alignCast(ctx));
    era_peq_process(eq, pcm, frames);
}

// ---------------------------------------------------------------------------
// 单元测试
// ---------------------------------------------------------------------------

const testing = std.testing;

fn fillRng(buf: []f32, seed_in: u32) void {
    var seed = seed_in;
    for (buf) |*v| {
        seed = seed *% 1664525 +% 1013904223;
        v.* = @as(f32, @floatFromInt(seed >> 8)) / 8388608.0 - 1.0;
    }
}

test "era_peq: 禁用 / 无段 / 全零增益为逐位直通" {
    const eq = try era_peq_create(testing.allocator, 48000, 2, 16);
    defer era_peq_destroy(eq);

    var buf: [128]f32 = undefined;
    fillRng(&buf, 0x11);
    const orig = buf;

    // 默认：无段 → 直通
    era_peq_process(eq, &buf, 64);
    try testing.expectEqualSlices(f32, &orig, &buf);

    // 有段但全零增益 → 仍直通
    era_peq_set_band(eq, 0, 0, 1000.0, 1.0, 0.0);
    era_peq_process(eq, &buf, 64);
    try testing.expectEqualSlices(f32, &orig, &buf);

    // 显式禁用 → 直通
    era_peq_set_band(eq, 0, 0, 1000.0, 1.0, 6.0);
    era_peq_set_enabled(eq, false);
    era_peq_process(eq, &buf, 64);
    try testing.expectEqualSlices(f32, &orig, &buf);
}

test "era_peq: +6dB peak 抬升所在频段能量，远离频段近似不变" {
    const eq = try era_peq_create(testing.allocator, 48000, 1, 16);
    defer era_peq_destroy(eq);
    era_peq_set_band(eq, 0, 0, 1000.0, 1.0, 6.0);

    const n = 8192;
    var near: [n]f32 = undefined;
    var far: [n]f32 = undefined;
    const w_near = 2.0 * std.math.pi * 1000.0 / 48000.0;
    const w_far = 2.0 * std.math.pi * 100.0 / 48000.0;
    for (0..n) |i| {
        near[i] = @floatCast(@sin(w_near * @as(f64, @floatFromInt(i))));
        far[i] = @floatCast(@sin(w_far * @as(f64, @floatFromInt(i))));
    }
    era_peq_process(eq, &near, n);
    era_peq_process(eq, &far, n);

    var sum_near: f64 = 0.0;
    var sum_far: f64 = 0.0;
    for (near[4096..]) |v| sum_near += @as(f64, v) * @as(f64, v);
    for (far[4096..]) |v| sum_far += @as(f64, v) * @as(f64, v);
    const rms_near = @sqrt(sum_near / 4096.0);
    const rms_far = @sqrt(sum_far / 4096.0);
    try testing.expect(rms_near > 1.1); // +6dB ≈ ×2（稳态）
    try testing.expect(rms_far > 0.6 and rms_far < 0.9); // 约 0.707，未明显改变
}

test "era_peq: low-shelf 抬升低频 / high-shelf 抬升高频" {
    const eq_l = try era_peq_create(testing.allocator, 48000, 1, 16);
    defer era_peq_destroy(eq_l);
    era_peq_set_band(eq_l, 0, 1, 200.0, 0.7071, 9.0); // low-shelf +9dB

    const eq_h = try era_peq_create(testing.allocator, 48000, 1, 16);
    defer era_peq_destroy(eq_h);
    era_peq_set_band(eq_h, 0, 2, 4000.0, 0.7071, 9.0); // high-shelf +9dB

    const n = 8192;
    const w = 2.0 * std.math.pi * 80.0 / 48000.0; // 低频
    var low: [n]f32 = undefined;
    var low_h: [n]f32 = undefined;
    for (0..n) |i| {
        const v: f32 = @floatCast(@sin(w * @as(f64, @floatFromInt(i))));
        low[i] = v;
        low_h[i] = v;
    }
    era_peq_process(eq_l, &low, n);
    era_peq_process(eq_h, &low_h, n);

    var sl: f64 = 0.0;
    var sh: f64 = 0.0;
    for (low[4096..]) |v| sl += @as(f64, v) * @as(f64, v);
    for (low_h[4096..]) |v| sh += @as(f64, v) * @as(f64, v);
    const rl = @sqrt(sl / 4096.0);
    const rh = @sqrt(sh / 4096.0);
    try testing.expect(rl > 1.2); // 低频被低架抬升
    try testing.expect(rh > 0.6 and rh < 0.85); // 高频对低架近似不变
}

test "era_peq: 非法参数（NaN/越界/非法 kind）不产生 NaN/Inf" {
    const eq = try era_peq_create(testing.allocator, 48000, 2, 16);
    defer era_peq_destroy(eq);

    era_peq_set_band(eq, 0, 0, std.math.nan(f32), 0.0, std.math.inf(f32));
    era_peq_set_band(eq, 1, 1, 1.0e9, -1.0, -1.0e9);
    era_peq_set_band(eq, 2, 7, 1000.0, 1.0, 6.0); // 非法 kind → 禁用
    era_peq_set_preamp(eq, std.math.nan(f32));

    var buf: [256]f32 = undefined;
    fillRng(&buf, 0x77);
    era_peq_process(eq, &buf, 128);
    for (buf) |v| {
        try testing.expect(std.math.isFinite(v));
    }
}

test "era_peq: clear 复位活动段并直通；stage 派发与直调一致" {
    const a = try era_peq_create(testing.allocator, 48000, 2, 16);
    defer era_peq_destroy(a);
    const b = try era_peq_create(testing.allocator, 48000, 2, 16);
    defer era_peq_destroy(b);

    era_peq_set_band(a, 0, 0, 500.0, 1.0, 4.0);
    era_peq_set_band(b, 0, 0, 500.0, 1.0, 4.0);

    var buf: [64]f32 = undefined;
    fillRng(&buf, 0x99);
    var buf2 = buf;
    era_peq_process(a, &buf, 32);
    era_peq_stage(b).process(&buf2, 32);
    try testing.expectEqualSlices(f32, &buf, &buf2);

    era_peq_clear(a);
    var again: [64]f32 = undefined;
    fillRng(&again, 0x99);
    const orig = again;
    era_peq_process(a, &again, 32);
    try testing.expectEqualSlices(f32, &orig, &again);
}

test "era_peq: create 参数夹取与非法参数" {
    try testing.expectError(error.InvalidArgument, era_peq_create(testing.allocator, 0, 2, 16));
    try testing.expectError(error.InvalidArgument, era_peq_create(testing.allocator, 48000, 0, 16));
    const eq = try era_peq_create(testing.allocator, 48000, 2, 1000);
    defer era_peq_destroy(eq);
    try testing.expectEqual(era_peq_max_bands, eq.max_bands);
}
