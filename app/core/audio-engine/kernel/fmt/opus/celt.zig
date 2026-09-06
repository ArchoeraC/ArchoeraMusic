// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! CELT 解码器编排（docs/audio-kernel-zig.md §9.2，P2）
//!
//! 参考重构对照 FFmpeg `libavcodec/opus/celt.c`（ff_celt_bitalloc /
//! ff_celt_quant_bands）与 `libavcodec/opus/dec_celt.c`（ff_celt_decode_frame /
//! 能量解码 / tf / 后滤波 / 去加重）+ `dsp.c`（许可登记见 audio-engine/THIRD-PARTY-LICENSES.md）。
//!
//! 帧解码流程：静音 → 后滤波参数 → transient → coarse energy → tf_changes →
//! bitalloc → fine energy → quant_bands（PVQ）→ anticollapse → final energy →
//! anticollapse/denormalize → 逆 MDCT + 重叠相加 → 后滤波 → 去加重 →
//! prev_energy 更新。

const std = @import("std");
const rcmod = @import("rc.zig");
const pvqmod = @import("pvq.zig");
const kiss = @import("kissfft.zig");
const tables = @import("celt_tables.zig");
const ct = @import("celt_types.zig");

const Rc = rcmod.Rc;
const Pvq = pvqmod.Pvq;
const CeltFrame = ct.CeltFrame;
const CeltBlock = ct.CeltBlock;
const CELT_MAX_BANDS = ct.CELT_MAX_BANDS;
const CELT_MAX_FRAME_SIZE = ct.CELT_MAX_FRAME_SIZE;
const CELT_VECTORS = ct.CELT_VECTORS;
const CELT_ALLOC_STEPS = ct.CELT_ALLOC_STEPS;
const CELT_FINE_OFFSET = ct.CELT_FINE_OFFSET;
const CELT_MAX_FINE_BITS = ct.CELT_MAX_FINE_BITS;
const CELT_QTHETA_OFFSET = ct.CELT_QTHETA_OFFSET;
const CELT_QTHETA_OFFSET_TWOPHASE = ct.CELT_QTHETA_OFFSET_TWOPHASE;
const CELT_POSTFILTER_MINPERIOD = ct.CELT_POSTFILTER_MINPERIOD;
const CELT_ENERGY_SILENCE = ct.CELT_ENERGY_SILENCE;
const FLT_EPSILON = ct.FLT_EPSILON;
const SPREAD_AGGRESSIVE = ct.SPREAD_AGGRESSIVE;
const CELT_SHORT_BLOCKSIZE = ct.CELT_SHORT_BLOCKSIZE;
const CELT_OVERLAP = ct.CELT_OVERLAP;
const CELT_NORM_SCALE = ct.CELT_NORM_SCALE;
const M_SQRT2: f64 = 1.41421356237309504880;

const Error = @import("../../error.zig").Error;

// ---------------------------------------------------------------------------
// 后滤波参数（parse_postfilter）
// ---------------------------------------------------------------------------

fn parsePostfilter(f: *CeltFrame, rc: *Rc, consumed_in: u32) u32 {
    var consumed = consumed_in;
    for (0..2) |i| {
        const block = &f.block[i];
        block.pf_period_new = 0;
        block.pf_gain_new = 0;
        block.pf_tapset_new = 0;
        block.pf_gains_new = .{ 0, 0, 0 };
    }

    if (f.start_band == 0 and consumed + 16 <= @as(u32, @intCast(f.framebits))) {
        const pfbit = rc.decLog(1);

        const has_postfilter = pfbit != 0;

        if (has_postfilter) {
            const octave = rc.decUint(6);
            const rawoct = rc.getRaw(4 + octave);
            const rawq = rc.getRaw(3);

            const period = (@as(i32, @intCast(16)) << @intCast(octave)) + @as(i32, @bitCast(rawoct)) - 1;
            const gain = 0.09375 * (@as(f32, @floatFromInt(rawq)) + 1.0);
            var tapset: i32 = 0;
            if (rc.tell() + 2 <= @as(u32, @intCast(f.framebits))) {
                tapset = @intCast(rc.decCdf(&tables.ff_celt_model_tapset));
            }
            for (0..2) |i| {
                const block = &f.block[i];
                block.pf_period_new = @max(period, CELT_POSTFILTER_MINPERIOD);
                block.pf_tapset_new = tapset;
                block.pf_gain_new = gain;
                block.pf_gains_new[0] = gain * tables.ff_celt_postfilter_taps[@as(usize, @intCast(tapset)) * 3 + 0];
                block.pf_gains_new[1] = gain * tables.ff_celt_postfilter_taps[@as(usize, @intCast(tapset)) * 3 + 1];
                block.pf_gains_new[2] = gain * tables.ff_celt_postfilter_taps[@as(usize, @intCast(tapset)) * 3 + 2];
            }
        }
        consumed = rc.tell();
    }
    return consumed;
}

// ---------------------------------------------------------------------------
// 能量解码
// ---------------------------------------------------------------------------

 fn decodeCoarseEnergy(f: *CeltFrame, rc: *Rc) void {
    var prev: [2]f32 = .{ 0, 0 };
    var alpha = tables.ff_celt_alpha_coef[@intCast(f.size)];
    const beta_int: [4]i32 = .{ 30147, 22282, 12124, 6554 };
    var beta: f32 = @floatFromInt(beta_int[@intCast(f.size)]);
    beta = beta / 32768.0;
    var model = tables.ff_celt_coarse_energy_dist[@as(usize, @intCast(f.size)) * 84 + 0 ..];

    if (rc.tell() + 3 <= @as(u32, @intCast(f.framebits)) and rc.decLog(3) != 0) {
        alpha = 0.0;
        beta = 4915.0 / 32768.0;
        model = tables.ff_celt_coarse_energy_dist[@as(usize, @intCast(f.size)) * 84 + 42 ..];
    }

    for (0..CELT_MAX_BANDS) |i| {
        for (0..@intCast(f.channels)) |j| {
            const block = &f.block[j];
            var value: f32 = 0;
            if (i < f.start_band or i >= f.end_band) {
                block.energy[i] = 0.0;
                continue;
            }
            const available = f.framebits - @as(i32, @bitCast(rc.tell()));
            if (available >= 15) {
                const mband = if (i > 20) 20 else i;
                const k = mband << 1;
                const symbol = @as(u32, model[k]) << 7;
                const decay = @as(u32, model[k + 1]) << 6;
                const sym = rc.decLaplace(symbol, decay);
                value = @floatFromInt(sym);
            } else if (available >= 2) {
                const x: i32 = @intCast(rc.decCdf(&tables.ff_celt_model_tapset));
                value = @floatFromInt((x >> 1) ^ -(x & 1));
            } else if (available >= 1) {
                value = -@as(f32, @floatFromInt(rc.decLog(1)));
            } else {
                value = -1;
            }
            const tmp = @max(-9.0, block.energy[i]) * alpha + prev[j] + value;
            block.energy[i] = tmp;
            prev[j] = prev[j] + value - beta * value;        }
    }
}

fn decodeTfChanges(f: *CeltFrame, rc: *Rc) void {
    var diff: i32 = 0;
    var tf_select = false;
    var tf_changed: i32 = 0;
    var bits: i32 = if (f.transient) 2 else 4;

    const consumed0 = rc.tell();
    const tf_select_bit = f.size != 0 and consumed0 + @as(u32, @intCast(bits)) + 1 <= @as(u32, @intCast(f.framebits));

    var i = f.start_band;
    while (i < f.end_band) : (i += 1) {
        if (rc.tell() + @as(u32, @intCast(bits)) + @intFromBool(tf_select_bit) <= @as(u32, @intCast(f.framebits))) {
            diff ^= @as(i32, @bitCast(rc.decLog(@intCast(bits))));
            tf_changed |= diff;
        }
        f.tf_change[i] = diff;
        bits = if (f.transient) 4 else 5;
    }

    if (tf_select_bit and
        tables.ff_celt_tf_select[@as(usize, @intCast(f.size)) * 8 + @as(usize, @intFromBool(f.transient)) * 4 + 0 * 2 + @as(usize, @intCast(tf_changed))] !=
        tables.ff_celt_tf_select[@as(usize, @intCast(f.size)) * 8 + @as(usize, @intFromBool(f.transient)) * 4 + 1 * 2 + @as(usize, @intCast(tf_changed))])
    {
        tf_select = rc.decLog(1) != 0;
    }

    for (f.start_band..f.end_band) |j| {
        f.tf_change[j] = tables.ff_celt_tf_select[@as(usize, @intCast(f.size)) * 8 + @as(usize, @intFromBool(f.transient)) * 4 + @as(usize, @intFromBool(tf_select)) * 2 + @as(usize, @intCast(f.tf_change[j]))];
    }
}

fn decodeFineEnergy(f: *CeltFrame, rc: *Rc) void {
    for (f.start_band..f.end_band) |i| {
        if (f.fine_bits[i] == 0) continue;
        for (0..@intCast(f.channels)) |j| {
            const block = &f.block[j];
            const q2 = rc.getRaw(@intCast(f.fine_bits[i]));
            const offset = (@as(f32, @floatFromInt(q2)) + 0.5) *
                @as(f32, @floatFromInt(@as(u32, 1) << @intCast(14 - f.fine_bits[i]))) * (1.0 / 16384.0) - 0.5;
            block.energy[i] += offset;
        }
    }
}

fn decodeFinalEnergy(f: *CeltFrame, rc: *Rc) void {
    var bits_left = f.framebits - @as(i32, @bitCast(rc.tell()));
    var priority: usize = 0;
    while (priority < 2) : (priority += 1) {
        var i = f.start_band;
        while (i < f.end_band and bits_left >= f.channels) : (i += 1) {
            if (f.fine_priority[i] != (priority == 1) or f.fine_bits[i] >= CELT_MAX_FINE_BITS) continue;
            for (0..@intCast(f.channels)) |j| {
                const block = &f.block[j];
                const q2 = rc.getRaw(1);
                const offset = (@as(f32, @floatFromInt(q2)) - 0.5) *
                    @as(f32, @floatFromInt(@as(u32, 1) << @intCast(14 - f.fine_bits[i] - 1))) * (1.0 / 16384.0);
                block.energy[i] += offset;
                bits_left -= 1;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// 位分配（ff_celt_bitalloc）
// ---------------------------------------------------------------------------

fn normc(bits: i32, channels: i32, size: i32) i32 {
    return @as(i32, bits) << @intCast(channels - 1 + size) >> 2;
}

fn bitalloc(f: *CeltFrame, rc: *Rc) void {
    var i: usize = 0;
    var low: i32 = 0;
    var high: i32 = 0;
    var total: i32 = 0;
    var done: i32 = 0;
    var bandbits: i32 = 0;
    var remaining: i32 = 0;
    var tbits_8ths: i32 = 0;
    var skip_startband = f.start_band;
    var skip_bit: i32 = 0;
    var intensitystereo_bit: i32 = 0;
    var dualstereo_bit: i32 = 0;
    var dynalloc: i32 = 6;
    var extrabits: i32 = 0;

    var boost = [_]i32{0} ** CELT_MAX_BANDS;
    var trim_offset = [_]i32{0} ** CELT_MAX_BANDS;
    var threshold = [_]i32{0} ** CELT_MAX_BANDS;
    var bits1 = [_]i32{0} ** CELT_MAX_BANDS;
    var bits2 = [_]i32{0} ** CELT_MAX_BANDS;

    // Spread
    if (rc.tell() + 4 <= @as(u32, @intCast(f.framebits))) {
        f.spread = @intCast(rc.decCdf(&tables.ff_celt_model_spread));
    } else {
        f.spread = ct.SPREAD_NORMAL;
    }

    // caps
    for (0..CELT_MAX_BANDS) |b| {
        f.caps[b] = normc((@as(i32, tables.ff_celt_static_caps[@as(usize, @intCast(f.size)) * 42 + (@as(usize, @intCast(f.channels)) - 1) * 21 + b]) + 64) * @as(i32, tables.ff_celt_freq_range[b]), f.channels, f.size);
    }

    // Band boosts
    tbits_8ths = f.framebits << 3;
    i = f.start_band;
    while (i < f.end_band) : (i += 1) {
        const quanta = @as(i32, tables.ff_celt_freq_range[i]) << @intCast(f.channels - 1 + f.size);
        var b_dynalloc = dynalloc;
        const boost_amount = f.alloc_boost[i];
        const q = @min(quanta << 3, @max(6 << 3, quanta));
        while (rc.tellFrac() + @as(u32, @bitCast(b_dynalloc << 3)) < @as(u32, @bitCast(tbits_8ths)) and boost[i] < f.caps[i]) {
            const is_boost: i32 = if (boost_amount - 1 >= 0) 1 else 0;
            const is_boost_dec = rc.decLog(@intCast(b_dynalloc));
            _ = is_boost;
            if (is_boost_dec == 0) break;
            boost[i] += q;
            tbits_8ths -= q;
            b_dynalloc = 1;
        }
        if (boost[i] != 0) dynalloc = @max(dynalloc - 1, 2);
    }

    // Allocation trim
    f.alloc_trim = 5;
    if (rc.tellFrac() + (6 << 3) <= @as(u32, @bitCast(tbits_8ths))) {
        f.alloc_trim = @intCast(rc.decCdf(&tables.ff_celt_model_alloc_trim));
    }

    // Anti-collapse bit reservation
    tbits_8ths = (f.framebits << 3) - @as(i32, @bitCast(rc.tellFrac())) - 1;
    f.anticollapse_needed = 0;
    if (f.transient and f.size >= 2 and tbits_8ths >= ((f.size + 2) << 3)) {
        f.anticollapse_needed = 1 << 3;
    }
    tbits_8ths -= f.anticollapse_needed;

    // Band skip bit reservation
    if (tbits_8ths >= 1 << 3) skip_bit = 1 << 3;
    tbits_8ths -= skip_bit;

    // Intensity/dual stereo bit reservation
    if (f.channels == 2) {
        intensitystereo_bit = tables.ff_celt_log2_frac[f.end_band - f.start_band];
        if (intensitystereo_bit <= tbits_8ths) {
            tbits_8ths -= intensitystereo_bit;
            if (tbits_8ths >= 1 << 3) {
                dualstereo_bit = 1 << 3;
                tbits_8ths -= 1 << 3;
            }
        } else {
            intensitystereo_bit = 0;
        }
    }

    // Trim offsets
    for (f.start_band..f.end_band) |b| {
        const trim = f.alloc_trim - 5 - f.size;
        const band = @as(i32, tables.ff_celt_freq_range[b]) * @as(i32, @intCast(f.end_band - b - 1));
        const duration = f.size + 3;
        const scale = duration + f.channels - 1;
        threshold[b] = @max(3 * @as(i32, tables.ff_celt_freq_range[b]) << @intCast(duration) >> 4, f.channels << 3);
        trim_offset[b] = (trim * (band << @intCast(scale))) >> 6; // 算术右移（C 语义）
        if (@as(i32, tables.ff_celt_freq_range[b]) << @intCast(f.size) == 1) {
            trim_offset[b] -= f.channels << 3;
        }
    }

    // 三分法
    low = 1;
    high = CELT_VECTORS - 1;
    while (low <= high) {
        const center = (low + high) >> 1;
        done = 0;
        total = 0;
        var j = f.end_band;
        while (j > f.start_band) {
            j -= 1;
            bandbits = normc(@as(i32, tables.ff_celt_freq_range[j]) * @as(i32, tables.ff_celt_static_alloc[@as(usize, @intCast(center)) * CELT_MAX_BANDS + j]), f.channels, f.size);
            if (bandbits != 0) bandbits = @max(bandbits + trim_offset[j], 0);
            bandbits += boost[j];
            if (bandbits >= threshold[j] or done != 0) {
                done = 1;
                total += @min(bandbits, f.caps[j]);
            } else if (bandbits >= f.channels << 3) {
                total += f.channels << 3;
            }
        }
        if (total > tbits_8ths) {
            high = center - 1;
        } else {
            low = center + 1;
        }
    }
    // C 语义：high = low--（high 取旧 low，low 减一）
    high = low;
    low = high - 1;

    // 第二分法
    for (f.start_band..f.end_band) |b| {
        bits1[b] = normc(@as(i32, tables.ff_celt_freq_range[b]) * @as(i32, tables.ff_celt_static_alloc[@as(usize, @intCast(low)) * CELT_MAX_BANDS + b]), f.channels, f.size);
        bits2[b] = if (high >= CELT_VECTORS)
            f.caps[b]
        else
            normc(@as(i32, tables.ff_celt_freq_range[b]) * @as(i32, tables.ff_celt_static_alloc[@as(usize, @intCast(high)) * CELT_MAX_BANDS + b]), f.channels, f.size);

        if (bits1[b] != 0) bits1[b] = @max(bits1[b] + trim_offset[b], 0);
        if (bits2[b] != 0) bits2[b] = @max(bits2[b] + trim_offset[b], 0);

        if (low != 0) bits1[b] += boost[b];
        bits2[b] += boost[b];

        if (boost[b] != 0) skip_startband = b;
        bits2[b] = @max(bits2[b] - bits1[b], 0);
    }

    // 第三分法
    low = 0;
    high = 1 << CELT_ALLOC_STEPS;
    for (0..CELT_ALLOC_STEPS) |_| {
        const center = (low + high) >> 1;
        done = 0;
        total = 0;
        var j = f.end_band;
        while (j > f.start_band) {
            j -= 1;
            bandbits = bits1[j] + (@divTrunc(center * bits2[j], 1 << CELT_ALLOC_STEPS));
            if (bandbits >= threshold[j] or done != 0) {
                done = 1;
                total += @min(bandbits, f.caps[j]);
            } else if (bandbits >= f.channels << 3) {
                total += f.channels << 3;
            }
        }
        if (total > tbits_8ths) {
            high = center;
        } else {
            low = center;
        }
    }

    // 最终分配
    done = 0;
    total = 0;
    var j = f.end_band;
    while (j > f.start_band) {
        j -= 1;
        bandbits = bits1[j] + (@divTrunc(low * bits2[j], 1 << CELT_ALLOC_STEPS));
        if (bandbits >= threshold[j] or done != 0) {
            done = 1;
        } else {
            bandbits = if (bandbits >= f.channels << 3) f.channels << 3 else 0;
        }
        bandbits = @min(bandbits, f.caps[j]);
        f.pulses[j] = bandbits;
        total += bandbits;
    }

    // Band skipping
    f.coded_bands = f.end_band;
    while (true) {
        var allocation: i32 = 0;
        j = f.coded_bands - 1;
        if (j == skip_startband) {
            tbits_8ths += skip_bit;
            break;
        }
        remaining = tbits_8ths - total;
        bandbits = @divTrunc(remaining, @as(i32, @intCast(tables.ff_celt_freq_bands[j + 1] - tables.ff_celt_freq_bands[f.start_band])));
        remaining -= bandbits * @as(i32, @intCast(tables.ff_celt_freq_bands[j + 1] - tables.ff_celt_freq_bands[f.start_band]));
        allocation = f.pulses[j] + bandbits * @as(i32, tables.ff_celt_freq_range[j]);
        allocation += @max(remaining - @as(i32, @intCast(tables.ff_celt_freq_bands[j] - tables.ff_celt_freq_bands[f.start_band])), 0);

        if (allocation >= @max(threshold[j], (f.channels + 1) << 3)) {
            const do_not_skip = rc.decLog(1) != 0;
            if (do_not_skip) break;
            total += 1 << 3;
            allocation -= 1 << 3;
        }
        total -= f.pulses[j];
        if (intensitystereo_bit != 0) {
            total -= intensitystereo_bit;
            intensitystereo_bit = tables.ff_celt_log2_frac[j - f.start_band];
            total += intensitystereo_bit;
        }
        f.pulses[j] = if (allocation >= f.channels << 3) f.channels << 3 else 0;
        total += f.pulses[j];
        f.coded_bands -= 1;
        if (f.coded_bands == 0) break;
    }

    // IS start band
    f.intensity_stereo = 0;
    f.dual_stereo = false;
    if (intensitystereo_bit != 0) {
        f.intensity_stereo = f.start_band + @as(usize, rc.decUint(@as(u32, @intCast(f.coded_bands + 1 - f.start_band))));
    }

    // DS flag
    if (f.intensity_stereo <= f.start_band) {
        tbits_8ths += dualstereo_bit;
    } else if (dualstereo_bit != 0) {
        f.dual_stereo = rc.decLog(1) != 0;
    }

    // 剩余位分配给低带
    remaining = tbits_8ths - total;
    bandbits = @divTrunc(remaining, @as(i32, @intCast(tables.ff_celt_freq_bands[f.coded_bands] - tables.ff_celt_freq_bands[f.start_band])));
    remaining -= bandbits * @as(i32, @intCast(tables.ff_celt_freq_bands[f.coded_bands] - tables.ff_celt_freq_bands[f.start_band]));
    for (f.start_band..f.coded_bands) |b| {
        const bits = @min(remaining, @as(i32, tables.ff_celt_freq_range[b]));
        f.pulses[b] += bits + bandbits * @as(i32, tables.ff_celt_freq_range[b]);
        remaining -= bits;
    }

    // 最终确定分配
    i = f.start_band;
    while (i < f.coded_bands) : (i += 1) {
        const N = @as(i32, tables.ff_celt_freq_range[i]) << @intCast(f.size);
        const prev_extra = extrabits;
        f.pulses[i] += extrabits;

        if (N > 1) {
            var dof: i32 = 0;
            var temp: i32 = 0;
            var fine_bits: i32 = 0;
            var max_bits: i32 = 0;
            var offset: i32 = 0;

            extrabits = @max(f.pulses[i] - f.caps[i], 0);
            f.pulses[i] -= extrabits;

            dof = N * f.channels + @intFromBool(f.channels == 2 and N > 2 and !f.dual_stereo and i < f.intensity_stereo);
            temp = dof * (@as(i32, tables.ff_celt_log_freq_range[i]) + (f.size << 3));
            offset = @divTrunc(temp, 2) - dof * CELT_FINE_OFFSET;
            if (N == 2) offset += dof << 1;

            if (f.pulses[i] + offset < 2 * (dof << 3)) {
                offset += temp >> 2;
            } else if (f.pulses[i] + offset < 3 * (dof << 3)) {
                offset += temp >> 3;
            }

            fine_bits = @divTrunc(f.pulses[i] + offset + (dof << 2), dof << 3);
            max_bits = @min(@divTrunc(f.pulses[i] >> 3, @as(i32, 1) << @intCast(f.channels - 1)), CELT_MAX_FINE_BITS);
            max_bits = @max(max_bits, 0);
            f.fine_bits[i] = @max(@min(fine_bits, max_bits), 0);

            f.fine_priority[i] = (f.fine_bits[i] * (dof << 3) >= f.pulses[i] + offset);
            f.pulses[i] -= f.fine_bits[i] << @intCast(f.channels - 1) << 3;
        } else {
            extrabits = @max(f.pulses[i] - (f.channels << 3), 0);
            f.pulses[i] -= extrabits;
            f.fine_bits[i] = 0;
            f.fine_priority[i] = true;
        }

        if (extrabits > 0) {
            var fineextra = @min(extrabits >> @intCast(f.channels + 2), CELT_MAX_FINE_BITS - f.fine_bits[i]);
            f.fine_bits[i] += fineextra;
            fineextra = fineextra << @intCast(f.channels + 2);
            f.fine_priority[i] = (fineextra >= extrabits - prev_extra);
            extrabits -= fineextra;
        }
    }
    f.remaining = extrabits;

    // 跳过的带全部用于 fine energy
    i = f.coded_bands;
    while (i < f.end_band) : (i += 1) {
        f.fine_bits[i] = @divTrunc(f.pulses[i], @as(i32, 1) << @intCast(f.channels - 1) << 3);
        f.pulses[i] = 0;
        f.fine_priority[i] = f.fine_bits[i] < 1;
    }
}

// ---------------------------------------------------------------------------
// quant_bands（ff_celt_quant_bands）
// ---------------------------------------------------------------------------

fn quantBands(f: *CeltFrame, pvq: *Pvq, rc: *Rc) void {
    var norm1: [2 * 8 * 100]f32 = undefined;
    const norm2 = norm1[8 * 100..];

    const totalbits = (f.framebits << 3) - f.anticollapse_needed;
    var update_lowband = true;
    var lowband_offset: usize = 0;

    var i: usize = f.start_band;
    while (i < f.end_band) : (i += 1) {
        var cm: [2]u32 = .{ (@as(u32, 1) << @intCast(f.blocks)) - 1, (@as(u32, 1) << @intCast(f.blocks)) - 1 };
        const band_offset = @as(usize, tables.ff_celt_freq_bands[i]) << @intCast(f.size);
        const band_size = @as(usize, tables.ff_celt_freq_range[i]) << @intCast(f.size);
        const X = f.block[0].coeffs[band_offset..][0..band_size];
        const Y = if (f.channels == 2) f.block[1].coeffs[band_offset..][0..band_size] else null;

        const consumed = rc.tellFrac();
        var effective_lowband: i32 = -1;
        var b: i32 = 0;

        if (i != f.start_band) f.remaining -= @intCast(consumed);
        f.remaining2 = totalbits - @as(i32, @intCast(consumed)) - 1;
        if (i <= f.coded_bands - 1) {
            const curr_balance = @divTrunc(f.remaining, @min(3, @as(i32, @intCast(f.coded_bands - i))));
            b = @min(f.remaining2 + 1, f.pulses[i] + curr_balance);
            b = @min(b, (1 << 14) - 1);
        }

        if ((tables.ff_celt_freq_bands[i] -% tables.ff_celt_freq_range[i] >= tables.ff_celt_freq_bands[f.start_band] or
            i == f.start_band + 1) and (update_lowband or lowband_offset == 0))
        {
            lowband_offset = i;
        }

        if (i == f.start_band + 1) {
            // Hybrid Folding（RFC 8251 §9）
            const count = (@as(usize, tables.ff_celt_freq_range[i]) - @as(usize, tables.ff_celt_freq_range[i - 1])) << @intCast(f.size);
            @memcpy(norm1[band_offset..][0..count], norm1[band_offset - count ..][0..count]);
            if (f.channels == 2) @memcpy(norm2[band_offset..][0..count], norm2[band_offset - count ..][0..count]);
        }

        var norm_loc1: ?[]const f32 = null;
        var norm_loc2: ?[]const f32 = null;
        if (lowband_offset != 0 and (f.spread != SPREAD_AGGRESSIVE or f.blocks > 1 or f.tf_change[i] < 0)) {
            const efl = @max(@as(i32, tables.ff_celt_freq_bands[f.start_band]),
                @as(i32, tables.ff_celt_freq_bands[lowband_offset]) - @as(i32, tables.ff_celt_freq_range[i]));
            var foldstart = lowband_offset;
            while (true) {
                foldstart -= 1;
                if (@as(i32, tables.ff_celt_freq_bands[foldstart]) <= efl) break;
            }
            var foldend = lowband_offset - 1;
            while (foldend + 1 < i and @as(i32, tables.ff_celt_freq_bands[foldend + 1]) < efl + @as(i32, tables.ff_celt_freq_range[i])) foldend += 1;

            cm[0] = 0;
            cm[1] = 0;
            var j = foldstart;
            while (j < foldend + 1) : (j += 1) {
                cm[0] |= f.block[0].collapse_masks[j];
                cm[1] |= f.block[@intCast(f.channels - 1)].collapse_masks[j];
            }
            effective_lowband = @intCast(efl);
            norm_loc1 = norm1[@as(usize, @intCast(efl)) << @intCast(f.size) ..];
            norm_loc2 = if (f.channels == 2) norm2[@as(usize, @intCast(efl)) << @intCast(f.size) ..] else null;
        }

        if (f.dual_stereo and i == f.intensity_stereo) {
            f.dual_stereo = false;
            var j = @as(usize, tables.ff_celt_freq_bands[f.start_band]) << @intCast(f.size);
            while (j < band_offset) : (j += 1) {
                norm1[j] = (norm1[j] + norm2[j]) / 2;
            }
        }

        const norm_loc1_slice = if (effective_lowband != -1) norm_loc1 else null;
        const norm_loc2_slice = if (effective_lowband != -1) norm_loc2 else null;

        if (f.dual_stereo) {
            cm[0] = pvqmod.quantBand(pvq, f, rc, i, X, null, band_size, b >> 1, f.blocks, norm_loc1_slice, @intCast(f.size), norm1[band_offset..], 0, 1.0, cm[0]);
            cm[1] = pvqmod.quantBand(pvq, f, rc, i, Y.?, null, band_size, b >> 1, f.blocks, norm_loc2_slice, @intCast(f.size), norm2[band_offset..], 0, 1.0, cm[1]);
        } else {
            cm[0] = pvqmod.quantBand(pvq, f, rc, i, X, Y, band_size, b, f.blocks, norm_loc1_slice, @intCast(f.size), norm1[band_offset..], 0, 1.0, cm[0] | cm[1]);
            cm[1] = cm[0];
        }

        f.block[0].collapse_masks[i] = @truncate(cm[0]);
        f.block[@intCast(f.channels - 1)].collapse_masks[i] = @truncate(cm[1]);
        f.remaining += f.pulses[i] + @as(i32, @intCast(consumed));

        update_lowband = (b > @as(i32, @intCast(band_size << 3)));
    }
}

// ---------------------------------------------------------------------------
// anticollapse / denormalize
// ---------------------------------------------------------------------------

fn processAnticollapse(f: *CeltFrame) void {
    for (f.start_band..f.end_band) |i| {
        const n = @as(usize, tables.ff_celt_freq_range[i]) << @intCast(f.size);
        const depth = @divTrunc(1 + f.pulses[i], @as(i32, @intCast(n)));
        const thresh: f32 = @floatCast(@exp2(-1.0 - 0.125 * @as(f64, @floatFromInt(depth))));
        const sqrt_1: f32 = 1.0 / @sqrt(@as(f32, @floatFromInt(n)));
        for (0..@intCast(f.channels)) |c| {
            const block = &f.block[c];
            var renormalize = false;
            const xptr = block.coeffs[@as(usize, tables.ff_celt_freq_bands[i]) << @intCast(f.size) ..][0..n];
            var prev: [2]f32 = .{ block.prev_energy[0][i], block.prev_energy[1][i] };
            if (f.channels == 1) {
                const block1 = &f.block[1];
                prev[0] = @max(prev[0], block1.prev_energy[0][i]);
                prev[1] = @max(prev[1], block1.prev_energy[1][i]);
            }
            var ediff = block.energy[i] - @min(prev[0], prev[1]);
            ediff = @max(0, ediff);
            var r: f32 = @floatCast(@exp2(1.0 - @as(f64, ediff)));
            if (f.size == 3) r *= @floatCast(M_SQRT2);
            r = @min(thresh, r) * sqrt_1;
            for (0..@as(usize, 1) << @intCast(f.size)) |k| {
                if ((block.collapse_masks[i] & (@as(u8, 1) << @intCast(k))) == 0) {
                    for (0..@as(usize, tables.ff_celt_freq_range[i])) |j| {
                        xptr[(j << @intCast(f.size)) + k] = if ((ct.celtRng(f) & 0x8000) != 0) r else -r;
                    }
                    renormalize = true;
                }
            }
            if (renormalize) ct.renormalizeVector(xptr, 1.0);
        }
    }
}

fn denormalize(f: *CeltFrame, block: *CeltBlock, data: []f32) void {
    for (f.start_band..f.end_band) |i| {
        const dst = data[@as(usize, tables.ff_celt_freq_bands[i]) << @intCast(f.size) ..];
        const log_norm = block.energy[i] + tables.ff_celt_mean_energy[i];
        // libopus FLOAT celt_exp2_db：celt_exp2(PSHR32(x, DB_SHIFT-10))，float 下 PSHR32=恒等，
        // celt_exp2(x)=exp(0.6931471805599453094·x)（double 计算后截断 f32）。
        const norm: f32 = @floatCast(@exp(0.6931471805599453094 * @as(f64, @min(log_norm, 32.0))));
        for (0..@as(usize, tables.ff_celt_freq_range[i]) << @intCast(f.size)) |j| {
            dst[j] *= norm;
        }
    }
}

// ---------------------------------------------------------------------------
// 后滤波（celt_postfilter + transition + comb）
// ---------------------------------------------------------------------------

/// libopus comb_filter_const：稳态梳状滤波，顺序累加匹配 MAC16_16
fn combFilterConst(buf: []f32, base: usize, t: i32, n: usize, g10: f32, g11: f32, g12: f32) void {
    const tu: usize = @intCast(t);
    var x4 = buf[base - tu - 2];
    var x3 = buf[base - tu - 1];
    var x2 = buf[base - tu];
    var x1 = buf[base - tu + 1];
    for (0..n) |i| {
        const x0 = buf[base + i - tu + 2];
        // MAC16_16 顺序：x[i] + g10*x2 → + g11*(x1+x3) → + g12*(x0+x4)
        var tmp = buf[base + i] + g10 * x2;
        tmp += g11 * (x1 + x3);
        tmp += g12 * (x0 + x4);
        if (i == 0 or i == 3) {}
        buf[base + i] = tmp;
        x4 = x3;
        x3 = x2;
        x2 = x1;
        x1 = x0;
    }
}

/// libopus comb_filter：跃迁 + 常量两段
fn combFilter(buf: []f32, base: usize, t0_in: i32, t1_in: i32, n: usize, g0: f32, g1: f32, tapset0: i32, tapset1: i32, overlap: usize) void {
    if (g0 == 0.0 and g1 == 0.0) return; // x==y 时 OPUS_MOVE 为 no-op
    const t0: i32 = @max(t0_in, CELT_POSTFILTER_MINPERIOD);
    const t1: i32 = @max(t1_in, CELT_POSTFILTER_MINPERIOD);
    const g00 = g0 * tables.ff_celt_postfilter_taps[@as(usize, @intCast(tapset0)) * 3 + 0];
    const g01 = g0 * tables.ff_celt_postfilter_taps[@as(usize, @intCast(tapset0)) * 3 + 1];
    const g02 = g0 * tables.ff_celt_postfilter_taps[@as(usize, @intCast(tapset0)) * 3 + 2];
    const g10 = g1 * tables.ff_celt_postfilter_taps[@as(usize, @intCast(tapset1)) * 3 + 0];
    const g11 = g1 * tables.ff_celt_postfilter_taps[@as(usize, @intCast(tapset1)) * 3 + 1];
    const g12 = g1 * tables.ff_celt_postfilter_taps[@as(usize, @intCast(tapset1)) * 3 + 2];

    const t1u: usize = @intCast(t1);
    const t0u: usize = @intCast(t0);
    var x1 = buf[base + 1 - t1u];
    var x2 = buf[base - t1u];
    var x3 = buf[base - 1 - t1u];
    var x4 = buf[base - 2 - t1u];
    // 若滤波器未变化则无需 overlap
    var ov = overlap;
    if (g0 == g1 and t0 == t1 and tapset0 == tapset1) ov = 0;
    for (0..ov) |i| {
        // f = window[i]²（f32 运行时乘法，与 libopus MULT_COEF 一致）
        const f = tables.ff_celt_window[i] * tables.ff_celt_window[i];
        const x0 = buf[base + i + 2 - t1u];
        const d = buf[base + i];
        // MULT_COEF_32(MULT_COEF((1-f),g0*),x[...]) 顺序
        buf[base + i] = d +
            (1.0 - f) * g00 * buf[base + i - t0u] +
            (1.0 - f) * g01 * (buf[base + i + 1 - t0u] + buf[base + i - 1 - t0u]) +
            (1.0 - f) * g02 * (buf[base + i + 2 - t0u] + buf[base + i - 2 - t0u]) +
            f * g10 * x2 +
            f * g11 * (x1 + x3) +
            f * g12 * (x0 + x4);
        x4 = x3;
        x3 = x2;
        x2 = x1;
        x1 = x0;
    }
    if (g1 == 0) return; // x==y 时 OPUS_MOVE 为 no-op
    combFilterConst(buf, base + ov, t1, n - ov, g10, g11, g12);
}

/// celt_synthesis 后滤波（libopus 两次 comb_filter + out_syn 状态机）
fn postfilterApply(f: *CeltFrame, block: *CeltBlock, out_syn: usize) void {
    const len = f.blocksize * f.blocks;
    const short = @as(usize, @intCast(f.mdct.shortMdctSize));
    const overlap = CELT_OVERLAP;

    // 第一次：N=shortMdctSize，old → current
    combFilter(&block.buf, out_syn, block.pf_period_old, block.pf_period, short, block.pf_gain_old, block.pf_gain, block.pf_tapset_old, block.pf_tapset, overlap);
    if (f.size != 0) {
        // 第二次：N-shortMdctSize，current → new（LM!=0）
        combFilter(&block.buf, out_syn + short, block.pf_period, block.pf_period_new, len - short, block.pf_gain, block.pf_gain_new, block.pf_tapset, block.pf_tapset_new, overlap);
    }
    // 状态更新（libopus）
    block.pf_period_old = block.pf_period;
    block.pf_gain_old = block.pf_gain;
    block.pf_tapset_old = block.pf_tapset;
    block.pf_period = block.pf_period_new;
    block.pf_gain = block.pf_gain_new;
    block.pf_tapset = block.pf_tapset_new;
    if (f.size != 0) {
        block.pf_period_old = block.pf_period;
        block.pf_gain_old = block.pf_gain;
        block.pf_tapset_old = block.pf_tapset;
    }
}

// ---------------------------------------------------------------------------
// 去加重
// ---------------------------------------------------------------------------

fn deemphasis(y: []f32, x: []const f32, coeff_in: f32, len: usize, accum: bool) f32 {
    var mem = coeff_in;
    const c = 0.850006103515625; // libopus float build coef0 = QCONST16(0.850006103515625,15)
    for (0..len) |i| {
        // libopus deemphasis_stereo_simple (float)：tmp = x + VERY_SMALL + m
        const tmp = x[i] + 1e-30 + mem;
        mem = c * tmp;
        if (accum) {
            // accum=1：SIG2RES(tmp)=(1/32768)*tmp，float 域累加（不量化）
            y[i] += (1.0 / 32768.0) * tmp;
        } else {
            // accum=0：参考输出 SIG2RES(tmp)，RES2INT24=lrintf(8388608*sig)
            const sig = (1.0 / 32768.0) * tmp;
            const r: i32 = lrintf(sig * 8388608.0);
            y[i] = @as(f32, @floatFromInt(r)) / 8388608.0;
        }
    }
    return mem;
}

/// C99 lrintf：round-to-nearest-even（Zig @round 是 ties-away，需修正）
fn lrintf(x: f32) i32 {
    const t: i32 = @intFromFloat(@trunc(x));
    const frac = x - @trunc(x);
    const sign: i32 = if (x < 0) -1 else 1;
    var r = t;
    if (@abs(frac) > 0.5) {
        r += sign;
    } else if (@abs(frac) == 0.5) {
        if (@mod(@abs(t), 2) != 0) r += sign;
    }
    return r;
}

// ---------------------------------------------------------------------------
// 帧解码（ff_celt_decode_frame）
// ---------------------------------------------------------------------------

/// 解码一帧 CELT（频谱 → 时域）。`output` 各声道浮点缓冲（长度 = frame_size）。
/// `data` 为帧数据（rawbits 尾部需 decRawInit 已设置）。返回声道输出数。
pub fn decodeFrame(
    f: *CeltFrame,
    rc: *Rc,
    output: [2][]f32,
    channels: i32,
    frame_size: usize,
    start_band: usize,
    end_band: usize,
    accum: bool,
) Error!usize {
    var pvq = Pvq{};
    if (channels != 1 and channels != 2) return error.Corrupt;
    if (start_band > end_band or end_band > CELT_MAX_BANDS) return error.Corrupt;

    f.silence = false;
    f.transient = false;
    f.anticollapse = false;
    f.flushed = false;
    f.channels = channels;
    f.start_band = start_band;
    f.end_band = end_band;
    f.framebits = @intCast(rc.rb.bytes * 8);

    const size = std.math.log2_int(usize, frame_size / CELT_SHORT_BLOCKSIZE);
    if (size > ct.CELT_MAX_LOG_BLOCKS or frame_size != CELT_SHORT_BLOCKSIZE * (@as(usize, 1) << size)) {
        return error.Corrupt;
    }
    f.size = @intCast(size);

    if (f.output_channels == 0) f.output_channels = channels;

    for (0..@intCast(f.channels)) |i| {
        @memset(&f.block[i].coeffs, 0);
        @memset(&f.block[i].collapse_masks, 0);
    }

    var consumed = rc.tell();
    // 静音标志
    if (consumed >= @as(u32, @bitCast(f.framebits))) {
        f.silence = true;
    } else if (consumed == 1) {
        f.silence = rc.decLog(15) != 0;
    }
    if (f.silence) {
        consumed = @intCast(f.framebits);
        rc.total_bits += @as(u32, @intCast(f.framebits)) - rc.tell();
    }

    if (start_band == 0) {
        consumed = parsePostfilter(f, rc, consumed);
    }

    if (f.size != 0 and consumed + 3 <= @as(u32, @bitCast(f.framebits))) {
        f.transient = rc.decLog(3) != 0;
    }
    f.blocks = if (f.transient) @as(u32, 1) << @intCast(f.size) else 1;
    f.blocksize = frame_size / f.blocks;

    if (channels == 1) {
        for (0..CELT_MAX_BANDS) |i| {
            f.block[0].energy[i] = @max(f.block[0].energy[i], f.block[1].energy[i]);
        }
    }

    decodeCoarseEnergy(f, rc);

    decodeTfChanges(f, rc);
    bitalloc(f, rc);
    decodeFineEnergy(f, rc);

    quantBands(f, &pvq, rc);

    if (f.anticollapse_needed != 0) f.anticollapse = rc.getRaw(1) != 0;

    decodeFinalEnergy(f, rc);

    if (f.anticollapse) processAnticollapse(f);

    for (0..@intCast(f.channels)) |i| {
        const block = &f.block[i];
        denormalize(f, block, block.coeffs[0..]);
    }

// stereo → mono downmix / mono → stereo upmix（libopus celt_synthesis C/CC 语义）
if (f.output_channels < f.channels) {
    // CC==1&&C==2：freq[i] = 0.5*freq[i] + 0.5*freq2[i]
    for (0..frame_size) |i| f.block[0].coeffs[i] = 0.5 * f.block[0].coeffs[i] + 0.5 * f.block[1].coeffs[i];
} else if (f.output_channels > f.channels) {
    @memcpy(f.block[1].coeffs[0..frame_size], f.block[0].coeffs[0..frame_size]);
}

if (f.silence) {
    for (0..2) |bi| {
        const block = &f.block[bi];
        for (0..CELT_MAX_BANDS) |j| block.energy[j] = CELT_ENERGY_SILENCE;
        @memset(&block.coeffs, 0);
    }
}
// 逆 MDCT + 重叠相加 + 后滤波 + 去加重（libopus out_syn 模型）
for (0..@intCast(f.output_channels)) |i| {
    const block = &f.block[i];
    // OPUS_MOVE(decode_mem, decode_mem+N, 2048-N+overlap)
    for (0..2048 - frame_size + CELT_OVERLAP) |k| block.buf[k] = block.buf[k + frame_size];
    const out_syn = 2048 - frame_size;
    var j: usize = 0;
    while (j < f.blocks) : (j += 1) {
        const dst_off = out_syn + j * f.blocksize;
        const shift: usize = if (f.transient) ct.CELT_MAX_LOG_BLOCKS else @as(usize, @intCast(ct.CELT_MAX_LOG_BLOCKS - f.size));
        const stride: usize = if (f.transient) f.blocks else 1;
        kiss.cltMdctBackward(&f.mdct, block.coeffs[j .. frame_size], block.buf[dst_off .. dst_off + f.blocksize + CELT_OVERLAP], &tables.ff_celt_window, CELT_OVERLAP, shift, stride);
    }

    // 后滤波（作用于 out_syn）
    postfilterApply(f, block, out_syn);

    // 去加重（读 out_syn[0..N]）
    block.emph_coeff = deemphasis(output[i][0..frame_size], block.buf[out_syn .. out_syn + frame_size], block.emph_coeff, frame_size, accum);

    // isnormal 语义：非有限 / 次正规 / 0 → 置 0
    if (!(std.math.isFinite(block.emph_coeff) and @abs(block.emph_coeff) >= std.math.floatMin(f32) and block.emph_coeff != 0)) {
        block.emph_coeff = 0.0;
    }
}

if (channels == 1) {
    @memcpy(f.block[1].energy[0..CELT_MAX_BANDS], f.block[0].energy[0..CELT_MAX_BANDS]);
}

for (0..2) |bi| {
    const block = &f.block[bi];
    if (!f.transient) {
        @memcpy(block.prev_energy[1][0..CELT_MAX_BANDS], block.prev_energy[0][0..CELT_MAX_BANDS]);
        @memcpy(block.prev_energy[0][0..CELT_MAX_BANDS], block.energy[0..CELT_MAX_BANDS]);
    } else {
        for (0..CELT_MAX_BANDS) |j| {
            block.prev_energy[0][j] = @min(block.prev_energy[0][j], block.energy[j]);
        }
    }
    for (0..f.start_band) |j| {
        block.prev_energy[0][j] = CELT_ENERGY_SILENCE;
        block.energy[j] = 0.0;
    }
    for (f.end_band..CELT_MAX_BANDS) |j| {
        block.prev_energy[0][j] = CELT_ENERGY_SILENCE;
        block.energy[j] = 0.0;
    }
}

f.seed = rc.range;
return @intCast(f.output_channels);
}
