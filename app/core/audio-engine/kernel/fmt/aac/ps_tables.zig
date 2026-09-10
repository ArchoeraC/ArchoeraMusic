// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! PS（参数立体声）静态表 + 运行时生成表。
//! 静态数据来自 aacpsdata.c / aacps.c / aacps_tablegen.h；生成逻辑复刻
//! aacps_tablegen.h ps_tableinit（CONFIG_HARDCODED_TABLES=0 运行时生成路径）。

const std = @import("std");
const huff = @import("ps_huff.zig");

// ---------------- 常量 ----------------

pub const PS_MAX_NUM_ENV = 5;
pub const PS_MAX_NR_IIDICC = 34;
pub const PS_MAX_NR_IPDOPD = 17;
pub const PS_MAX_SSB = 91;
pub const PS_MAX_AP_BANDS = 50;
pub const PS_QMF_TIME_SLOTS = 32;
pub const PS_MAX_DELAY = 14;
pub const PS_AP_LINKS = 3;
pub const PS_MAX_AP_DELAY = 5;

pub const NR_PAR_BANDS = [_]usize{ 20, 34 };
pub const NR_IPDOPD_BANDS = [_]usize{ 11, 17 };
pub const NR_BANDS = [_]usize{ 71, 91 };
pub const DECAY_CUTOFF = [_]usize{ 10, 32 };
pub const NR_ALLPASS_BANDS = [_]usize{ 30, 50 };
pub const SHORT_DELAY_BAND = [_]usize{ 42, 62 };

/// DECAY_SLOPE（float 路径）
pub const DECAY_SLOPE: f32 = 0.05;

// ---------------- 静态小表 ----------------

pub const num_env_tab = [_][4]u8{ .{ 0, 1, 2, 4 }, .{ 1, 2, 3, 4 } };

pub const nr_iidicc_par_tab = [_]u8{ 10, 20, 34, 10, 20, 34 };
pub const nr_iidopd_par_tab = [_]u8{ 5, 11, 17, 5, 11, 17 };

/// VLC 表选择（huff_iid）
pub const huff_iid = [_]u8{ 2, 0, 3, 1 }; // df0, df1, dt0, dt1

// ---------------- k_to_i ----------------

pub const ff_k_to_i_20 = [_]i8{
    1, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 14, 15,
    15, 15, 16, 16, 16, 16, 17, 17, 17, 17, 17, 18, 18, 18, 18, 18, 18, 18, 18,
    18, 18, 18, 18, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19,
    19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19,
};

pub const ff_k_to_i_34 = [_]i8{
    0, 1, 2, 3, 4, 5, 6, 6, 7, 2, 1, 0, 10, 10, 4, 5, 6, 7, 8,
    9, 10, 11, 12, 9, 14, 11, 12, 13, 14, 15, 16, 13, 16, 17, 18, 19, 20, 21,
    22, 22, 23, 23, 24, 24, 25, 25, 26, 26, 27, 27, 27, 28, 28, 28, 29, 29, 29,
    30, 30, 30, 31, 31, 31, 31, 32, 32, 32, 32,
    33, 33, 33, 33, 33, 33, 33, 33, 33, 33, 33, 33, 33, 33, 33, 33, 33, 33, 33, 33, 33, 33, 33,
};

// ---------------- 原型滤波器（aacps_tablegen.h） ----------------

pub const g0_Q8 = [_]f32{
    0.00746082949812, 0.02270420949825, 0.04546865930473, 0.07266113929591,
    0.09885108575264, 0.11793710567217, 0.125,
};

pub const g0_Q12 = [_]f32{
    0.04081179924692, 0.03812810994926, 0.05144908135699, 0.06399831151592,
    0.07428313801106, 0.08100347892914, 0.08333333333333,
};

pub const g1_Q8 = [_]f32{
    0.01565675600122, 0.03752716391991, 0.05417891378782, 0.08417044116767,
    0.10307344158036, 0.12222452249753, 0.125,
};

pub const g2_Q4 = [_]f32{
    -0.05908211155639, -0.04871498374946, 0.0, 0.07778723915851,
    0.16486303567403, 0.23279856662996, 0.25,
};

/// g1_Q2（aacps.c，Q31 在 float 路径 = 原值）
pub const g1_Q2 = [_]f32{ 0.0, 0.01899487526049, 0.0, -0.07293139167538, 0.0, 0.30596630545168, 0.5 };

pub const f_center_20 = [_]i8{ -3, -1, 1, 3, 5, 7, 10, 14, 18, 22 };
pub const f_center_34 = [_]i8{
    2, 6, 10, 14, 18, 22, 26, 30,
    34, -10, -6, -2, 51, 57, 15, 21,
    27, 33, 39, 45, 54, 66, 78, 42,
    102, 66, 78, 90, 102, 114, 126, 90,
};

pub const fractional_delay_links = [_]f32{ 0.43, 0.75, 0.347 };
pub const fractional_delay_gain: f32 = 0.39;

pub const ipdopd_sin = [_]f32{ 0, 0.7071067811865476, 1, 0.7071067811865476, 0, -0.7071067811865476, -1, -0.7071067811865476 };
pub const ipdopd_cos = [_]f32{ 1, 0.7071067811865476, 0, -0.7071067811865476, -1, -0.7071067811865476, 0, 0.7071067811865476 };

pub const iid_par_dequant = [_]f32{
    // default
    0.05623413251903, 0.12589254117942, 0.19952623149689, 0.31622776601684,
    0.44668359215096, 0.63095734448019, 0.79432823472428, 1,
    1.25892541179417, 1.58489319246111, 2.23872113856834, 3.16227766016838,
    5.01187233627272, 7.94328234724282, 17.7827941003892,
    // fine
    0.00316227766017, 0.00562341325190, 0.01, 0.01778279410039,
    0.03162277660168, 0.05623413251903, 0.07943282347243, 0.11220184543020,
    0.15848931924611, 0.22387211385683, 0.31622776601684, 0.39810717055350,
    0.50118723362727, 0.63095734448019, 0.79432823472428, 1,
    1.25892541179417, 1.58489319246111, 1.99526231496888, 2.51188643150958,
    3.16227766016838, 4.46683592150963, 6.30957344480193, 8.91250938133745,
    12.5892541179417, 17.7827941003892, 31.6227766016838, 56.2341325190349,
    100, 177.827941003892, 316.227766016837,
};

pub const icc_invq = [_]f32{ 1, 0.937, 0.84118, 0.60092, 0.36764, 0, -0.589, -1 };
pub const acos_icc_invq = [_]f32{ 0, 0.35685527, 0.57133466, 0.92614472, 1.1943263, 1.5707963267948966, 2.2006171, 3.141592653589793 };

// ---------------- 生成表 ----------------

/// 混合分析原型滤波器（[bands][8][2] 复数）
pub const FilterBand = [8][2]f32;

pub var f20_0_8: [8]FilterBand = undefined;
pub var f34_0_12: [12]FilterBand = undefined;
pub var f34_1_8: [8]FilterBand = undefined;
pub var f34_2_4: [4]FilterBand = undefined;

/// H 矩阵 LUT（[46][8][4]）
pub var HA: [46][8][4]f32 = undefined;
pub var HB: [46][8][4]f32 = undefined;

/// 全通分数延迟（[2][50][3][2]）
pub var Q_fract_allpass: [2][PS_MAX_AP_BANDS][PS_AP_LINKS][2]f32 = undefined;
/// phi_fract（[2][50][2]）
pub var phi_fract: [2][PS_MAX_AP_BANDS][2]f32 = undefined;

/// ipd/opd 相位平滑表（[512][2]）
pub var pd_re_smooth: [512]f32 = undefined;
pub var pd_im_smooth: [512]f32 = undefined;

fn makeFiltersFromProto(comptime NB: usize, filter: *[NB][8][2]f32, proto: []const f32, bands: usize) void {
    var q: usize = 0;
    while (q < bands) : (q += 1) {
        var n: usize = 0;
        while (n < 7) : (n += 1) {
            const theta = 2 * std.math.pi * (@as(f64, @floatFromInt(q)) + 0.5) * (@as(f64, @floatFromInt(n)) - 6) / @as(f64, @floatFromInt(bands));
            filter.*[q][n][0] = @floatCast(proto[n] * @cos(theta));
            filter.*[q][n][1] = @floatCast(proto[n] * -@sin(theta));
        }
    }
}

/// 生成全部运行时表（对应 ps_tableinit）
pub fn psTableInit() void {
    // 相位平滑表
    var pd0: usize = 0;
    while (pd0 < 8) : (pd0 += 1) {
        const pd0_re = ipdopd_cos[pd0];
        const pd0_im = ipdopd_sin[pd0];
        var pd1: usize = 0;
        while (pd1 < 8) : (pd1 += 1) {
            const pd1_re = ipdopd_cos[pd1];
            const pd1_im = ipdopd_sin[pd1];
            var pd2: usize = 0;
            while (pd2 < 8) : (pd2 += 1) {
                const pd2_re = ipdopd_cos[pd2];
                const pd2_im = ipdopd_sin[pd2];
                const re_smooth: f32 = 0.25 * pd0_re + 0.5 * pd1_re + pd2_re;
                const im_smooth: f32 = 0.25 * pd0_im + 0.5 * pd1_im + pd2_im;
                const pd_mag: f32 = 1.0 / @sqrt(im_smooth * im_smooth + re_smooth * re_smooth);
                const idx = pd0 * 64 + pd1 * 8 + pd2;
                pd_re_smooth[idx] = re_smooth * pd_mag;
                pd_im_smooth[idx] = im_smooth * pd_mag;
            }
        }
    }

    // HA / HB
    var iid: usize = 0;
    while (iid < 46) : (iid += 1) {
        const c = iid_par_dequant[iid];
        const c1: f32 = 1.4142135623730951 / @sqrt(1.0 + c * c);
        const c2 = c * c1;
        var icc: usize = 0;
        while (icc < 8) : (icc += 1) {
            const alpha: f32 = 0.5 * acos_icc_invq[icc];
            const beta: f32 = alpha * (c1 - c2) * 0.7071067811865476;
            HA[iid][icc][0] = c2 * @cos(beta + alpha);
            HA[iid][icc][1] = c1 * @cos(beta - alpha);
            HA[iid][icc][2] = c2 * @sin(beta + alpha);
            HA[iid][icc][3] = c1 * @sin(beta - alpha);
            // HB
            const rho: f32 = @max(icc_invq[icc], 0.05);
            var alpha2: f32 = 0.5 * std.math.atan2(2.0 * c * rho, c * c - 1.0);
            var mu: f32 = c + 1.0 / c;
            mu = @sqrt(1 + (4 * rho * rho - 4) / (mu * mu));
            const gamma: f32 = std.math.atan(@sqrt((1.0 - mu) / (1.0 + mu)));
            if (alpha2 < 0) alpha2 += 1.5707963267948966;
            const alpha_c = @cos(alpha2);
            const alpha_s = @sin(alpha2);
            const gamma_c = @cos(gamma);
            const gamma_s = @sin(gamma);
            HB[iid][icc][0] = 1.4142135623730951 * alpha_c * gamma_c;
            HB[iid][icc][1] = 1.4142135623730951 * alpha_s * gamma_c;
            HB[iid][icc][2] = -1.4142135623730951 * alpha_s * gamma_s;
            HB[iid][icc][3] = 1.4142135623730951 * alpha_c * gamma_s;
        }
    }

    // Q_fract_allpass / phi_fract（20 带）
    var k: usize = 0;
    while (k < NR_ALLPASS_BANDS[0]) : (k += 1) {
        const f_center: f64 = if (k < f_center_20.len)
            @as(f64, @floatFromInt(f_center_20[k])) * 0.125
        else
            @as(f64, @floatFromInt(k)) - 6.5;
        var m: usize = 0;
        while (m < PS_AP_LINKS) : (m += 1) {
            const theta = -std.math.pi * @as(f64, fractional_delay_links[m]) * f_center;
            Q_fract_allpass[0][k][m][0] = @floatCast(@cos(theta));
            Q_fract_allpass[0][k][m][1] = @floatCast(@sin(theta));
        }
        const theta = -std.math.pi * @as(f64, fractional_delay_gain) * f_center;
        phi_fract[0][k][0] = @floatCast(@cos(theta));
        phi_fract[0][k][1] = @floatCast(@sin(theta));
    }
    // 34 带
    k = 0;
    while (k < NR_ALLPASS_BANDS[1]) : (k += 1) {
        const f_center: f64 = if (k < f_center_34.len)
            @as(f64, @floatFromInt(f_center_34[k])) / 24.0
        else
            @as(f64, @floatFromInt(k)) - 26.5;
        var m: usize = 0;
        while (m < PS_AP_LINKS) : (m += 1) {
            const theta = -std.math.pi * @as(f64, fractional_delay_links[m]) * f_center;
            Q_fract_allpass[1][k][m][0] = @floatCast(@cos(theta));
            Q_fract_allpass[1][k][m][1] = @floatCast(@sin(theta));
        }
        const theta = -std.math.pi * @as(f64, fractional_delay_gain) * f_center;
        phi_fract[1][k][0] = @floatCast(@cos(theta));
        phi_fract[1][k][1] = @floatCast(@sin(theta));
    }

    // 混合滤波器
    makeFiltersFromProto(8, &f20_0_8, &g0_Q8, 8);
    makeFiltersFromProto(12, &f34_0_12, &g0_Q12, 12);
    makeFiltersFromProto(8, &f34_1_8, &g1_Q8, 8);
    makeFiltersFromProto(4, &f34_2_4, &g2_Q4, 4);
}

test "ps table gen basics" {
    psTableInit();
    try std.testing.expect(HA[30][3][0] != 0);
    try std.testing.expect(f20_0_8[0][0][0] != 0);
}
