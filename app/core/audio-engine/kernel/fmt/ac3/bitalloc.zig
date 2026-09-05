//! AC-3 位分配（对照 FFmpeg ac3.c / ac3dsp.c）
//!
//! PSD（功率谱密度）计算、掩蔽曲线、逐 bin 位分配（bap）。

const t = @import("tables.zig");

pub const BitAllocParams = struct {
    sr_code: i32 = 0,
    sr_shift: i32 = 0,
    slow_decay: i32 = 0,
    fast_decay: i32 = 0,
    slow_gain: i32 = 0,
    db_per_bit: i32 = 0,
    floor: i32 = 0,
    cpl_fast_leak: i32 = 0,
    cpl_slow_leak: i32 = 0,
};

fn max(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    return if (a > b) a else b;
}
fn min(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    return if (a < b) a else b;
}

inline fn calcLowcomp1(a: i32, b0: i32, b1: i32, c: i32) i32 {
    var na = a;
    if ((b0 + 256) == b1) {
        na = c;
    } else if (b0 > b1) {
        na = max(na - 64, 0);
    }
    return na;
}

inline fn calcLowcomp(a: i32, b0: i32, b1: i32, bin: i32) i32 {
    if (bin < 7) {
        return calcLowcomp1(a, b0, b1, 384);
    } else if (bin < 20) {
        return calcLowcomp1(a, b0, b1, 320);
    } else {
        return max(a - 128, 0);
    }
}

/// 指数 → PSD + PSD 积分
pub fn bitAllocCalcPsd(exp: *const [t.AC3_MAX_COEFS]i8, start: usize, end: usize, psd: *[t.AC3_MAX_COEFS]i16, band_psd: *[t.AC3_CRITICAL_BANDS]i16) void {
    var bin: usize = start;
    while (bin < end) : (bin += 1) {
        psd[bin] = @intCast(3072 - (@as(i32, exp[bin]) << 7));
    }
    bin = start;
    var band: usize = t.bin_to_band_tab[start];
    while (true) {
        var v: i32 = psd[bin];
        bin += 1;
        const band_end: usize = min(@as(usize, t.band_start_tab[band + 1]), end);
        while (bin < band_end) : (bin += 1) {
            const mx: i32 = max(v, psd[bin]);
            const adr: usize = @intCast(min(mx - ((v + @as(i32, psd[bin]) + 1) >> 1), 255));
            v = mx + @as(i32, t.log_add_tab[adr]);
        }
        band_psd[band] = @intCast(v);
        band += 1;
        if (!(end > @as(usize, t.band_start_tab[band]))) break;
    }
}

/// 计算掩蔽曲线 + delta 位分配
pub fn bitAllocCalcMask(s: *const BitAllocParams, band_psd: *const [t.AC3_CRITICAL_BANDS]i16, start: usize, end: usize, fast_gain: i32, is_lfe: bool, dba_mode: u8, dba_nsegs: usize, dba_offsets: *const [8]u8, dba_lengths: *const [8]u8, dba_values: *const [8]u8, mask: *[t.AC3_CRITICAL_BANDS]i16) bool {
    if (end <= 0) return true;

    var excite: [t.AC3_CRITICAL_BANDS]i32 = undefined;
    const band_start: usize = t.bin_to_band_tab[start];
    const band_end: usize = t.bin_to_band_tab[end - 1] + 1;

    var band: usize = 0;
    var band_begin: usize = 0;
    var lowcomp: i32 = 0;
    var fastleak: i32 = 0;
    var slowleak: i32 = 0;

    if (band_start == 0) {
        lowcomp = calcLowcomp1(lowcomp, band_psd[0], band_psd[1], 384);
        excite[0] = band_psd[0] - fast_gain - lowcomp;
        lowcomp = calcLowcomp1(lowcomp, band_psd[1], band_psd[2], 384);
        excite[1] = band_psd[1] - fast_gain - lowcomp;
        var begin: usize = 7;
        band = 2;
        while (band < 7) : (band += 1) {
            if (!(is_lfe and band == 6)) {
                lowcomp = calcLowcomp1(lowcomp, band_psd[band], band_psd[band + 1], 384);
            }
            fastleak = band_psd[band] - fast_gain;
            slowleak = band_psd[band] - s.slow_gain;
            excite[band] = fastleak - lowcomp;
            if (!(is_lfe and band == 6)) {
                if (band_psd[band] <= band_psd[band + 1]) {
                    begin = band + 1;
                    break;
                }
            }
        }
        const end1: usize = min(band_end, 22);
        band = begin;
        while (band < end1) : (band += 1) {
            if (!(is_lfe and band == 6)) {
                lowcomp = calcLowcomp(lowcomp, band_psd[band], band_psd[band + 1], @intCast(band));
            }
            fastleak = max(fastleak - s.fast_decay, band_psd[band] - fast_gain);
            slowleak = max(slowleak - s.slow_decay, band_psd[band] - s.slow_gain);
            excite[band] = max(fastleak - lowcomp, slowleak);
        }
        band_begin = 22;
    } else {
        band_begin = band_start;
        fastleak = (s.cpl_fast_leak << 8) + 768;
        slowleak = (s.cpl_slow_leak << 8) + 768;
    }

    band = band_begin;
    while (band < band_end) : (band += 1) {
        fastleak = max(fastleak - s.fast_decay, band_psd[band] - fast_gain);
        slowleak = max(slowleak - s.slow_decay, band_psd[band] - s.slow_gain);
        excite[band] = max(fastleak, slowleak);
    }

    // 掩蔽曲线
    band = band_start;
    while (band < band_end) : (band += 1) {
        const tmp = s.db_per_bit - band_psd[band];
        if (tmp > 0) excite[band] += @intCast(tmp >> 2);
        mask[band] = @intCast(max(@as(i32, t.hearing_threshold_tab[band >> @intCast(s.sr_shift)][@intCast(s.sr_code)]), excite[band]));
    }

    // delta 位分配
    if (dba_mode == t.DBA_REUSE or dba_mode == t.DBA_NEW) {
        if (dba_nsegs > 8) return true;
        var b: usize = band_start;
        var seg: usize = 0;
        while (seg < dba_nsegs) : (seg += 1) {
            b += dba_offsets[seg];
            if (b >= t.AC3_CRITICAL_BANDS or dba_lengths[seg] > t.AC3_CRITICAL_BANDS - b) return true;
            const delta: i32 = if (dba_values[seg] >= 4) (@as(i32, dba_values[seg]) - 3) * 128 else (@as(i32, dba_values[seg]) - 4) * 128;
            var i: usize = 0;
            while (i < dba_lengths[seg]) : (i += 1) {
                mask[b] = @intCast(@as(i32, mask[b]) + delta);
                b += 1;
            }
        }
    }
    return false;
}

/// 逐 bin 计算 bap（位分配指针）
pub fn bitAllocCalcBap(mask: *const [t.AC3_CRITICAL_BANDS]i16, psd: *const [t.AC3_MAX_COEFS]i16, start: usize, end: usize, snr_offset: i32, floor: i32, bap_tab: *const [64]u8, bap: *[t.AC3_MAX_COEFS]u8) void {
    if (snr_offset == -960) {
        @memset(bap, 0);
        return;
    }
    var bin: usize = start;
    var band: usize = t.bin_to_band_tab[start];
    while (true) {
        const m: i32 = (max(mask[band] - snr_offset - floor, 0) & 0x1FE0) + floor;
        const band_end: usize = min(@as(usize, t.band_start_tab[band + 1]), end);
        band += 1;
        while (bin < band_end) : (bin += 1) {
            const addr: usize = @intCast(clampUint2(@intCast((psd[bin] - m) >> 5), 6));
            bap[bin] = bap_tab[addr];
        }
        if (!(end > band_end)) break;
    }
}

fn clampUint2(a: i32, n: i32) i32 {
    const m: i32 = (@as(i32, 1) << @as(u5, @intCast(n))) - 1;
    if (a < 0) return 0;
    if (a > m) return m;
    return a;
}

// ---------------------------------------------------------------------------
// 单元测试
// ---------------------------------------------------------------------------
const std = @import("std");

test "psd 映射：exp→psd = 3072 - exp<<7" {
    t.initStatic();
    var exp: [t.AC3_MAX_COEFS]i8 = [_]i8{0} ** t.AC3_MAX_COEFS;
    exp[0] = 0;
    exp[1] = 8;
    exp[2] = 24;
    var psd: [t.AC3_MAX_COEFS]i16 = undefined;
    var band_psd: [t.AC3_CRITICAL_BANDS]i16 = undefined;
    bitAllocCalcPsd(&exp, 0, 3, &psd, &band_psd);
    try std.testing.expectEqual(@as(i16, 3072), psd[0]);
    try std.testing.expectEqual(@as(i16, 3072 - 8 * 128), psd[1]);
    try std.testing.expectEqual(@as(i16, 3072 - 24 * 128), psd[2]);
}

test "bap：强信号高 bap，弱信号低 bap" {
    t.initStatic();
    var mask: [t.AC3_CRITICAL_BANDS]i16 = [_]i16{0} ** t.AC3_CRITICAL_BANDS;
    var psd: [t.AC3_MAX_COEFS]i16 = [_]i16{0} ** t.AC3_MAX_COEFS;
    var bap: [t.AC3_MAX_COEFS]u8 = undefined;
    psd[0] = 2816; // 强（exp=2）
    psd[1] = 512;  // 弱（exp=20）
    // mask=0, snr_offset 小 → 强信号 addr 高 → bap 大
    bitAllocCalcBap(&mask, &psd, 0, 2, 0, 0, &t.bap_tab, &bap);
    try std.testing.expect(bap[0] > bap[1]);
}
