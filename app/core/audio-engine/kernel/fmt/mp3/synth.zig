// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! 合成滤波器组（DCT-II + 多相滤波），对标 minimp3 标量路径（CC0）。

const std = @import("std");
const vec = @import("vec.zig");

const g_sec = [24]f32{
    10.19000816, 0.50060302, 0.50241929, 3.40760851, 0.50547093, 0.52249861, 2.05778098, 0.51544732, 0.56694406, 1.48416460, 0.53104258, 0.64682180, 1.16943991, 0.55310392, 0.78815460, 0.97256821, 0.58293498, 1.06067765, 0.83934963, 0.62250412, 1.72244716, 0.74453628, 0.67480832, 5.10114861,
};

/// 8 点 DCT 核（对标 minimp3 mp3d_DCT_II 内层蝶形）。
/// 输入的 4 个「行」相互独立 → 用 V4 逐 lane 并行；每 lane 的运算顺序与标量完全一致，
/// 不重组浮点、不引入 FMA → 位级一致（B 档手法但无精度风险）。
inline fn dctRows8(in: [8]V4) [8]V4 {
    var v0 = in[0];
    var v1 = in[1];
    var v2 = in[2];
    var v3 = in[3];
    const v4 = in[4];
    const v5 = in[5];
    const v6 = in[6];
    const v7 = in[7];
    var xt = v0 - v7;
    v0 += v7;
    var w7 = v1 - v6;
    v1 += v6;
    var w6 = v2 - v5;
    v2 += v5;
    var w5 = v3 - v4;
    v3 += v4;
    const w4 = v0 - v3;
    v0 += v3;
    var w3 = v1 - v2;
    v1 += v2;
    var out: [8]V4 = undefined;
    out[0] = v0 + v1;
    out[4] = (v0 - v1) * @as(V4, @splat(0.70710677));
    w5 = w5 + w6;
    w6 = (w6 + w7) * @as(V4, @splat(0.70710677));
    w7 = w7 + xt;
    w3 = (w3 + w4) * @as(V4, @splat(0.70710677));
    w5 -= w7 * @as(V4, @splat(0.198912367));
    w7 += w5 * @as(V4, @splat(0.382683432));
    w5 -= w7 * @as(V4, @splat(0.198912367));
    const c0 = xt - w6;
    xt += w6;
    out[1] = (xt + w7) * @as(V4, @splat(0.50979561));
    out[2] = (w4 + w3) * @as(V4, @splat(0.54119611));
    out[3] = (c0 - w5) * @as(V4, @splat(0.60134488));
    out[5] = (c0 + w5) * @as(V4, @splat(0.89997619));
    out[6] = (w4 - w3) * @as(V4, @splat(1.30656302));
    out[7] = (xt - w7) * @as(V4, @splat(2.56291556));
    return out;
}

/// DCT-II，对标 minimp3 mp3d_DCT_II 标量路径（n 频带）。
/// 采集阶段直接产出「列向量」tv[i]（lane = t[0..3][i]），蝶形阶段以 V4 并行 4 行。
pub fn dctII(grbuf: []f32, n: usize) void {
    var k: usize = 0;
    while (k < n) : (k += 1) {
        const y = grbuf[k..];
        var tv: [8]V4 = undefined;
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            const x0 = y[i * 18];
            const x1 = y[(15 - i) * 18];
            const x2 = y[(16 + i) * 18];
            const x3 = y[(31 - i) * 18];
            const tt0 = x0 + x3;
            const tt1 = x1 + x2;
            const tt2 = (x1 - x2) * g_sec[3 * i + 0];
            const tt3 = (x0 - x3) * g_sec[3 * i + 1];
            const s2 = g_sec[3 * i + 2];
            tv[i] = .{ tt0 + tt1, (tt0 - tt1) * s2, tt3 + tt2, (tt3 - tt2) * s2 };
        }
        const rows = dctRows8(tv);
        var yy: []f32 = y;
        var ic: usize = 0;
        while (ic < 7) : (ic += 1) {
            yy[0 * 18] = rows[ic][0];
            yy[1 * 18] = rows[ic][2] + rows[ic][3] + rows[ic + 1][3];
            yy[2 * 18] = rows[ic][1] + rows[ic + 1][1];
            yy[3 * 18] = rows[ic + 1][2] + rows[ic][3] + rows[ic + 1][3];
            yy = yy[4 * 18 ..];
        }
        yy[0 * 18] = rows[7][0];
        yy[1 * 18] = rows[7][2] + rows[7][3];
        yy[2 * 18] = rows[7][1];
        yy[3 * 18] = rows[7][3];
    }
}

fn scalePcm(sample: f32) f32 {
    return sample * (1.0 / 32768.0);
}

const g_win = [240]f32{
    -1, 26, -31, 208, 218, 401, -519, 2063, 2000, 4788, -5517, 7134, 5959, 35640, -39336, 74992,
    -1, 24, -35, 202, 222, 347, -581, 2080, 1952, 4425, -5879, 7640, 5288, 33791, -41176, 74856,
    -1, 21, -38, 196, 225, 294, -645, 2087, 1893, 4063, -6237, 8092, 4561, 31947, -43006, 74630,
    -1, 19, -41, 190, 227, 244, -711, 2085, 1822, 3705, -6589, 8492, 3776, 30112, -44821, 74313,
    -1, 17, -45, 183, 228, 197, -779, 2075, 1739, 3351, -6935, 8840, 2935, 28289, -46617, 73908,
    -1, 16, -49, 176, 228, 153, -848, 2057, 1644, 3004, -7271, 9139, 2037, 26482, -48390, 73415,
    -2, 14, -53, 169, 227, 111, -919, 2032, 1535, 2663, -7597, 9389, 1082, 24694, -50137, 72835,
    -2, 13, -58, 161, 224, 72, -991, 2001, 1414, 2330, -7910, 9592, 70, 22929, -51853, 72169,
    -2, 11, -63, 154, 221, 36, -1064, 1962, 1280, 2006, -8209, 9750, -998, 21189, -53534, 71420,
    -2, 10, -68, 147, 215, 2, -1137, 1919, 1131, 1692, -8491, 9863, -2122, 19478, -55178, 70590,
    -3, 9, -73, 139, 208, -29, -1210, 1870, 970, 1388, -8755, 9935, -3300, 17799, -56778, 69679,
    -3, 8, -79, 132, 200, -57, -1283, 1817, 794, 1095, -8998, 9966, -4533, 16155, -58333, 68692,
    -4, 7, -85, 125, 189, -83, -1356, 1759, 605, 814, -9219, 9959, -5818, 14548, -59838, 67629,
    -4, 7, -91, 117, 177, -106, -1428, 1698, 402, 545, -9416, 9916, -7154, 12980, -61289, 66494,
    -5, 6, -97, 111, 163, -127, -1498, 1634, 185, 288, -9585, 9838, -8540, 11455, -62684, 65290,
};

fn synthPair(pcm: [*]f32, nch: usize, z: [*]const f32) void {
    var a: f32 = 0;
    a = (z[14 * 64] - z[0]) * 29;
    a += (z[1 * 64] + z[13 * 64]) * 213;
    a += (z[12 * 64] - z[2 * 64]) * 459;
    a += (z[3 * 64] + z[11 * 64]) * 2037;
    a += (z[10 * 64] - z[4 * 64]) * 5153;
    a += (z[5 * 64] + z[9 * 64]) * 6574;
    a += (z[8 * 64] - z[6 * 64]) * 37489;
    a += z[7 * 64] * 75038;
    pcm[0] = scalePcm(a);

    a = 0;
    const z2 = z + 2;
    a = z2[14 * 64] * 104;
    a += z2[12 * 64] * 1567;
    a += z2[10 * 64] * 9727;
    a += z2[8 * 64] * 64019;
    a += z2[6 * 64] * -9975;
    a += z2[4 * 64] * -45;
    a += z2[2 * 64] * 146;
    a += z2[0 * 64] * -5;
    pcm[16 * nch] = scalePcm(a);
}

/// 单条多相抽头的 4 路并行向量（vz/vy 各 4 个连续 f32）。
/// 4 个「相位样本」相互独立，逐 lane 运算顺序与标量完全一致 → 位级一致（B 档但无精度风险）。
const V4 = vec.V4;

fn synth(xl: [*]const f32, dstl: [*]f32, nch: usize, lins: [*]f32) void {
    const xr = xl + 576 * (nch - 1);
    const dstr = dstl + (nch - 1);
    const zlin: [*]f32 = lins + 15 * 64;
    const w = &g_win;

    zlin[4 * 15] = xl[18 * 16];
    zlin[4 * 15 + 1] = xr[18 * 16];
    zlin[4 * 15 + 2] = xl[0];
    zlin[4 * 15 + 3] = xr[0];

    zlin[4 * 31] = xl[1 + 18 * 16];
    zlin[4 * 31 + 1] = xr[1 + 18 * 16];
    zlin[4 * 31 + 2] = xl[1];
    zlin[4 * 31 + 3] = xr[1];

    synthPair(dstr, nch, lins + 4 * 15 + 1);
    synthPair(dstr + 32 * nch, nch, lins + 4 * 15 + 64 + 1);
    synthPair(dstl, nch, lins + 4 * 15);
    synthPair(dstl + 32 * nch, nch, lins + 4 * 15 + 64);

    var wi: usize = 0;
    var i: i32 = 14;
    while (i >= 0) : (i -= 1) {
        const ii: usize = @intCast(i);
        zlin[4 * ii] = xl[18 * (31 - ii)];
        zlin[4 * ii + 1] = xr[18 * (31 - ii)];
        zlin[4 * ii + 2] = xl[1 + 18 * (31 - ii)];
        zlin[4 * ii + 3] = xr[1 + 18 * (31 - ii)];
        zlin[4 * (ii + 16)] = xl[1 + 18 * (1 + ii)];
        zlin[4 * (ii + 16) + 1] = xr[1 + 18 * (1 + ii)];
        lins[15 * 64 + 4 * ii - 64 + 2] = xl[18 * (1 + ii)];
        lins[15 * 64 + 4 * ii - 64 + 3] = xr[18 * (1 + ii)];
        // S0(0) S2(1) S1(2) S2(3) S1(4) S2(5) S1(6) S2(7)
        var a: V4 = undefined;
        var b: V4 = undefined;
        var k: usize = 0;
        while (k < 8) : (k += 1) {
            const w0: V4 = @splat(w[wi]);
            const w1: V4 = @splat(w[wi + 1]);
            wi += 2;
            const vz = vec.load4(zlin + 4 * ii - 64 * k);
            const vy = vec.load4(zlin + 4 * ii - 64 * (15 - k));
            if (k == 0) {
                b = vz * w1 + vy * w0;
                a = vz * w0 - vy * w1;
            } else {
                b += vz * w1 + vy * w0;
                if (k & 1 != 0) {
                    a += vy * w1 - vz * w0;
                } else {
                    a += vz * w0 - vy * w1;
                }
            }
        }

        const sc: V4 = @splat(1.0 / 32768.0);
        const as = a * sc;
        const bs = b * sc;
        dstr[(15 - ii) * nch] = as[1];
        dstr[(17 + ii) * nch] = bs[1];
        dstl[(15 - ii) * nch] = as[0];
        dstl[(17 + ii) * nch] = bs[0];
        dstr[(47 - ii) * nch] = as[3];
        dstr[(49 + ii) * nch] = bs[3];
        dstl[(47 - ii) * nch] = as[2];
        dstl[(49 + ii) * nch] = bs[2];
    }
}

pub fn synthGranule(qmf_state: []f32, grbuf: []f32, nbands: usize, nch: usize, pcm: []f32, lins: []f32) void {
    var i: usize = 0;
    while (i < nch) : (i += 1) {
        dctII(grbuf[576 * i ..][0..576], nbands);
    }
    @memcpy(lins[0 .. 15 * 64], qmf_state[0 .. 15 * 64]);

    var b: usize = 0;
    while (b < nbands) : (b += 2) {
        synth(grbuf[b..].ptr, pcm[32 * nch * b ..].ptr, nch, lins[b * 64 ..].ptr);
    }

    if (nch == 1) {
        for (0..15 * 64 / 2) |half| {
            qmf_state[2 * half] = lins[nbands * 64 + 2 * half];
        }
    } else {
        @memcpy(qmf_state[0 .. 15 * 64], lins[nbands * 64 ..][0 .. 15 * 64]);
    }
}
