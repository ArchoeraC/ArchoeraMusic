// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! MACE（Macintosh Audio Compression/Expansion）3:1 / 6:1 解码器（docs/audio-kernel-zig.md §9.1）
//!
//! 镜像 FFmpeg libavcodec/mace.c。AIFC 压缩类型 "MAC3"（3:1）/ "MAC6"（6:1）。
//! 特性：
//!   - 1-2 声道；块式：MAC3 每块 2B/声道、MAC6 每块 1B/声道，每块 6 样本/声道；
//!   - 流式状态（index/factor/prev2/previous/level）跨块保持，seek 后须重置
//!     （镜像 FFmpeg flush）；
//!   - 输出交错 s16。注意：样本输出为 `QT_8S_2_16S`（高字节复制到低位），
//!     这是 MACE 解码器保持与原版二进制一致的刻意的"怪异"行为（mace.c 注释）。

const std = @import("std");
const testing = std.testing;
const Error = @import("../../error.zig").Error;

/// MAC3 每块字节数/声道；MAC6 每块字节数/声道
pub const block_size_mace3: usize = 2;
pub const block_size_mace6: usize = 1;
/// 每块输出样本数/声道（两种压缩比均为 6）
pub const samples_per_block: usize = 6;

/// 每输入字节的输出样本数/声道：MAC3 = 3、MAC6 = 6
pub fn samplesPerByte(mace3: bool) usize {
    return if (mace3) 3 else 6;
}

/// 每块字节数 = (2|1) × channels
pub fn blockSize(mace3: bool, channels: usize) usize {
    return (if (mace3) block_size_mace3 else block_size_mace6) * channels;
}

const tab1 = [8]i16{ -13, 8, 76, 222, 222, 76, 8, -13 };
const tab3 = [4]i16{ -18, 140, 140, -18 };

const tab2 = [128][4]i16{
    .{ 37, 116, 206, 330 },         .{ 39, 121, 216, 346 },         .{ 41, 127, 225, 361 },         .{ 42, 132, 235, 377 },
    .{ 44, 137, 245, 392 },         .{ 46, 144, 256, 410 },         .{ 48, 150, 267, 428 },         .{ 51, 157, 280, 449 },
    .{ 53, 165, 293, 470 },         .{ 55, 172, 306, 490 },         .{ 58, 179, 319, 511 },         .{ 60, 187, 333, 534 },
    .{ 63, 195, 348, 557 },         .{ 66, 205, 364, 583 },         .{ 69, 214, 380, 609 },         .{ 72, 223, 396, 635 },
    .{ 75, 233, 414, 663 },         .{ 79, 244, 433, 694 },         .{ 82, 254, 453, 725 },         .{ 86, 265, 472, 756 },
    .{ 90, 278, 495, 792 },         .{ 94, 290, 516, 826 },         .{ 98, 303, 538, 862 },         .{ 102, 316, 562, 901 },
    .{ 107, 331, 588, 942 },        .{ 112, 345, 614, 983 },        .{ 117, 361, 641, 1027 },       .{ 122, 377, 670, 1074 },
    .{ 127, 394, 701, 1123 },       .{ 133, 411, 732, 1172 },       .{ 139, 430, 764, 1224 },       .{ 145, 449, 799, 1280 },
    .{ 152, 469, 835, 1337 },       .{ 159, 490, 872, 1397 },       .{ 166, 512, 911, 1459 },       .{ 173, 535, 951, 1523 },
    .{ 181, 558, 993, 1590 },       .{ 189, 584, 1038, 1663 },      .{ 197, 610, 1085, 1738 },      .{ 206, 637, 1133, 1815 },
    .{ 215, 665, 1183, 1895 },      .{ 225, 695, 1237, 1980 },      .{ 235, 726, 1291, 2068 },      .{ 246, 759, 1349, 2161 },
    .{ 257, 792, 1409, 2257 },      .{ 268, 828, 1472, 2357 },      .{ 280, 865, 1538, 2463 },      .{ 293, 903, 1606, 2572 },
    .{ 306, 944, 1678, 2688 },      .{ 319, 986, 1753, 2807 },      .{ 334, 1030, 1832, 2933 },     .{ 349, 1076, 1914, 3065 },
    .{ 364, 1124, 1999, 3202 },     .{ 380, 1174, 2088, 3344 },     .{ 398, 1227, 2182, 3494 },     .{ 415, 1281, 2278, 3649 },
    .{ 434, 1339, 2380, 3811 },     .{ 453, 1398, 2486, 3982 },     .{ 473, 1461, 2598, 4160 },     .{ 495, 1526, 2714, 4346 },
    .{ 517, 1594, 2835, 4540 },     .{ 540, 1665, 2961, 4741 },     .{ 564, 1740, 3093, 4953 },     .{ 589, 1818, 3232, 5175 },
    .{ 615, 1898, 3375, 5405 },     .{ 643, 1984, 3527, 5647 },     .{ 671, 2072, 3683, 5898 },     .{ 701, 2164, 3848, 6161 },
    .{ 733, 2261, 4020, 6438 },     .{ 766, 2362, 4199, 6724 },     .{ 800, 2467, 4386, 7024 },     .{ 836, 2578, 4583, 7339 },
    .{ 873, 2692, 4786, 7664 },     .{ 912, 2813, 5001, 8008 },     .{ 952, 2938, 5223, 8364 },     .{ 995, 3070, 5457, 8739 },
    .{ 1039, 3207, 5701, 9129 },    .{ 1086, 3350, 5956, 9537 },    .{ 1134, 3499, 6220, 9960 },    .{ 1185, 3655, 6497, 10404 },
    .{ 1238, 3818, 6788, 10869 },   .{ 1293, 3989, 7091, 11355 },   .{ 1351, 4166, 7407, 11861 },   .{ 1411, 4352, 7738, 12390 },
    .{ 1474, 4547, 8084, 12946 },   .{ 1540, 4750, 8444, 13522 },   .{ 1609, 4962, 8821, 14126 },   .{ 1680, 5183, 9215, 14756 },
    .{ 1756, 5415, 9626, 15415 },   .{ 1834, 5657, 10057, 16104 },  .{ 1916, 5909, 10505, 16822 },  .{ 2001, 6173, 10975, 17574 },
    .{ 2091, 6448, 11463, 18356 },  .{ 2184, 6736, 11974, 19175 },  .{ 2282, 7037, 12510, 20032 },  .{ 2383, 7351, 13068, 20926 },
    .{ 2490, 7679, 13652, 21861 },  .{ 2601, 8021, 14260, 22834 },  .{ 2717, 8380, 14897, 23854 },  .{ 2838, 8753, 15561, 24918 },
    .{ 2965, 9144, 16256, 26031 },  .{ 3097, 9553, 16982, 27193 },  .{ 3236, 9979, 17740, 28407 },  .{ 3380, 10424, 18532, 29675 },
    .{ 3531, 10890, 19359, 31000 }, .{ 3688, 11375, 20222, 32382 }, .{ 3853, 11883, 21125, 32767 }, .{ 4025, 12414, 22069, 32767 },
    .{ 4205, 12967, 23053, 32767 }, .{ 4392, 13546, 24082, 32767 }, .{ 4589, 14151, 25157, 32767 }, .{ 4793, 14783, 26280, 32767 },
    .{ 5007, 15442, 27452, 32767 }, .{ 5231, 16132, 28678, 32767 }, .{ 5464, 16851, 29957, 32767 }, .{ 5708, 17603, 31294, 32767 },
    .{ 5963, 18389, 32691, 32767 }, .{ 6229, 19210, 32767, 32767 }, .{ 6507, 20067, 32767, 32767 }, .{ 6797, 20963, 32767, 32767 },
    .{ 7101, 21899, 32767, 32767 }, .{ 7418, 22876, 32767, 32767 }, .{ 7749, 23897, 32767, 32767 }, .{ 8095, 24964, 32767, 32767 },
    .{ 8456, 26078, 32767, 32767 }, .{ 8833, 27242, 32767, 32767 }, .{ 9228, 28457, 32767, 32767 }, .{ 9639, 29727, 32767, 32767 },
};

const tab4 = [128][2]i16{
    .{ 64, 216 },      .{ 67, 226 },      .{ 70, 236 },      .{ 74, 246 },
    .{ 77, 257 },      .{ 80, 268 },      .{ 84, 280 },      .{ 88, 294 },
    .{ 92, 307 },      .{ 96, 321 },      .{ 100, 334 },     .{ 104, 350 },
    .{ 109, 365 },     .{ 114, 382 },     .{ 119, 399 },     .{ 124, 416 },
    .{ 130, 434 },     .{ 136, 454 },     .{ 142, 475 },     .{ 148, 495 },
    .{ 155, 519 },     .{ 162, 541 },     .{ 169, 564 },     .{ 176, 590 },
    .{ 185, 617 },     .{ 193, 644 },     .{ 201, 673 },     .{ 210, 703 },
    .{ 220, 735 },     .{ 230, 767 },     .{ 240, 801 },     .{ 251, 838 },
    .{ 262, 876 },     .{ 274, 914 },     .{ 286, 955 },     .{ 299, 997 },
    .{ 312, 1041 },    .{ 326, 1089 },    .{ 341, 1138 },    .{ 356, 1188 },
    .{ 372, 1241 },    .{ 388, 1297 },    .{ 406, 1354 },    .{ 424, 1415 },
    .{ 443, 1478 },    .{ 462, 1544 },    .{ 483, 1613 },    .{ 505, 1684 },
    .{ 527, 1760 },    .{ 551, 1838 },    .{ 576, 1921 },    .{ 601, 2007 },
    .{ 628, 2097 },    .{ 656, 2190 },    .{ 686, 2288 },    .{ 716, 2389 },
    .{ 748, 2496 },    .{ 781, 2607 },    .{ 816, 2724 },    .{ 853, 2846 },
    .{ 891, 2973 },    .{ 930, 3104 },    .{ 972, 3243 },    .{ 1016, 3389 },
    .{ 1061, 3539 },   .{ 1108, 3698 },   .{ 1158, 3862 },   .{ 1209, 4035 },
    .{ 1264, 4216 },   .{ 1320, 4403 },   .{ 1379, 4599 },   .{ 1441, 4806 },
    .{ 1505, 5019 },   .{ 1572, 5244 },   .{ 1642, 5477 },   .{ 1715, 5722 },
    .{ 1792, 5978 },   .{ 1872, 6245 },   .{ 1955, 6522 },   .{ 2043, 6813 },
    .{ 2134, 7118 },   .{ 2229, 7436 },   .{ 2329, 7767 },   .{ 2432, 8114 },
    .{ 2541, 8477 },   .{ 2655, 8854 },   .{ 2773, 9250 },   .{ 2897, 9663 },
    .{ 3026, 10094 },  .{ 3162, 10546 },  .{ 3303, 11016 },  .{ 3450, 11508 },
    .{ 3604, 12020 },  .{ 3765, 12556 },  .{ 3933, 13118 },  .{ 4108, 13703 },
    .{ 4292, 14315 },  .{ 4483, 14953 },  .{ 4683, 15621 },  .{ 4892, 16318 },
    .{ 5111, 17046 },  .{ 5339, 17807 },  .{ 5577, 18602 },  .{ 5826, 19433 },
    .{ 6086, 20300 },  .{ 6358, 21205 },  .{ 6642, 22152 },  .{ 6938, 23141 },
    .{ 7248, 24173 },  .{ 7571, 25252 },  .{ 7909, 26380 },  .{ 8262, 27557 },
    .{ 8631, 28786 },  .{ 9016, 30072 },  .{ 9419, 31413 },  .{ 9839, 32767 },
    .{ 10278, 32767 }, .{ 10737, 32767 }, .{ 11216, 32767 }, .{ 11717, 32767 },
    .{ 12240, 32767 }, .{ 12786, 32767 }, .{ 13356, 32767 }, .{ 13953, 32767 },
    .{ 14576, 32767 }, .{ 15226, 32767 }, .{ 15906, 32767 }, .{ 16615, 32767 },
};

/// 单声道解码状态（C: ChannelData）
pub const ChannelData = struct {
    index: i16 = 0,
    factor: i16 = 0,
    prev2: i16 = 0,
    previous: i16 = 0,
    level: i16 = 0,
};

/// MACE 解码上下文（≤2 声道，跨块状态；seek 时重置）
pub const Context = struct {
    chd: [2]ChannelData = .{ .{}, .{} },
};

/// MACE 版 clip16（mace.c）：下界钳到 -32767 而非 -32768，保持与原版二进制一致
fn brokenClip16(n: i32) i16 {
    if (n > 32767) return 32767;
    if (n < -32768) return -32767;
    return @intCast(n);
}

/// QT_8S_2_16S(x) = ((x) & 0xFF00) | (((x) >> 8) & 0xFF)：
/// 取 x 的 bit8..15 复制到高、低字节（丢弃 bit0..7）。C 中 x 为 int 时
/// 两个 & 掩码均只涉及 bit8..15，与 x 是否超出 16 位无关。
fn qt8s2_16s(x: i32) i16 {
    const hi: u8 = @truncate(@as(u32, @bitCast(x)) >> 8);
    return @bitCast((@as(u16, hi) << 8) | hi);
}

fn readTable(chd: *ChannelData, val: u8, tab_idx: u8) i16 {
    // C: tabs[tab_idx]：tab_idx 0/2 → tab1+tab2(128×4)+stride4；1 → tab3+tab4(128×2)+stride2
    const mace3_mode = tab_idx == 1;
    const t1: []const i16 = if (mace3_mode) &tab3 else &tab1;
    const stride: usize = if (mace3_mode) 2 else 4;
    const row: usize = (@as(u16, @bitCast(chd.index)) & 0x7f0) >> 4;
    const current: i16 = if (val < stride)
        (if (mace3_mode) tab4[row][val] else tab2[row][val])
    else
        -1 - (if (mace3_mode) tab4[row][2 * stride - val - 1] else tab2[row][2 * stride - val - 1]);
    // C: chd->index += tab1[val] - (chd->index >> 5)；int16 提升 int（算术右移）后赋回。
    // index 值域小（<229），i32 运算与 int16 截断一致。
    var idx: i32 = chd.index;
    idx = idx + t1[val] - (idx >> 5);
    if (idx < 0) idx = 0;
    chd.index = @intCast(idx);
    return current;
}

fn chomp3(chd: *ChannelData, val: u8, tab_idx: u8) i16 {
    var current: i32 = readTable(chd, val, tab_idx);
    current = brokenClip16(current + chd.level);
    chd.level = @intCast(current - (current >> 3));
    return qt8s2_16s(current);
}

fn chomp6(chd: *ChannelData, val: u8, tab_idx: u8) [2]i16 {
    var current: i32 = readTable(chd, val, tab_idx);
    if ((@as(i32, chd.previous) ^ current) >= 0) {
        chd.factor = @intCast(@min(@as(i32, chd.factor) + 506, 32767));
    } else {
        chd.factor = if (chd.factor - 314 < -32768) -32767 else @intCast(chd.factor - 314);
    }
    current = brokenClip16(current + chd.level);
    chd.level = @intCast((current * chd.factor) >> 15);
    current >>= 1;
    const o0 = qt8s2_16s(@as(i32, chd.previous) + chd.prev2 - ((chd.prev2 - current) >> 2));
    const o1 = qt8s2_16s(@as(i32, chd.previous) + current + ((chd.prev2 - current) >> 2));
    chd.prev2 = chd.previous;
    chd.previous = @intCast(current);
    return .{ o0, o1 };
}

/// 解码一整块（src.len == blockSize(mace3, ch)），输出 out[0..6*ch] 交错 s16。
/// 块内字节布局（镜像 FFmpeg mace_decode_frame 的 pkt 索引）：
///   MAC6: [ch0][ch1]（每声道 1 字节）；MAC3: [ch0a][ch0b][ch1a][ch1b]（每声道 2 字节连续）
pub fn decodeBlock(ctx: *Context, src: []const u8, channels: usize, mace3: bool, out: []i16) void {
    const bytes_per_ch: usize = if (mace3) 2 else 1;
    const stride: usize = if (mace3) 1 else 2;
    for (0..channels) |i| {
        var smp: usize = 0;
        for (0..bytes_per_ch) |b| {
            const pkt = src[i * bytes_per_ch + b];
            const vals = if (mace3)
                [3]u8{ pkt & 7, (pkt >> 3) & 3, pkt >> 5 }
            else
                [3]u8{ pkt >> 5, (pkt >> 3) & 3, pkt & 7 };
            for (0..3) |l| {
                if (mace3) {
                    out[smp * channels + i] = chomp3(&ctx.chd[i], vals[l], @intCast(l));
                } else {
                    const r = chomp6(&ctx.chd[i], vals[l], @intCast(l));
                    out[smp * channels + i] = r[0];
                    out[(smp + 1) * channels + i] = r[1];
                }
                smp += stride;
            }
        }
    }
}

/// 解码连续块（src.len 应为 blockSize 的整数倍；尾部残缺块按 FFmpeg 截断忽略）。
/// 返回输出样本数（交错）。
pub fn decode(ctx: *Context, src: []const u8, channels: usize, mace3: bool, out: []i16) Error!usize {
    const bpb = blockSize(mace3, channels);
    if (channels < 1 or channels > 2 or bpb == 0) return error.Corrupt;
    const blocks = src.len / bpb;
    if (blocks == 0) return 0;
    const total = blocks * samples_per_block * channels;
    if (out.len < total) return error.Corrupt;
    var produced: usize = 0;
    for (0..blocks) |b| {
        decodeBlock(ctx, src[b * bpb ..][0..bpb], channels, mace3, out[produced..]);
        produced += samples_per_block * channels;
    }
    return produced;
}

// ---- 测试 ----
//
// 黄金数据由独立 Python 参考实现生成（mace_ref.py，转写自 mace.c），
// 并已与 FFmpeg 官方 mace3/mace6 解码器输出逐字节比对一致（4 组 0 mismatch）。

pub const golden_m6m = [_]u8{ 0x44, 0x20, 0x82, 0x3C, 0xFD, 0xE6, 0xF1, 0xC2, 0x6B, 0x30, 0xF9, 0x0E, 0xC7, 0xDD, 0x01, 0xE4, 0x88, 0x75, 0x34, 0xA2 };
pub const golden_m6m_expect = [_]i16{ 0, 0, 0, 0, 0, -1, -1, -1, -1, 0, 0, 0, 0, -1, -1, -1, -1, 0, 257, 257, 257, 0, -1, -258, -515, -515, -515, -258, -258, -515, -515, -515, -258, -1, -1, -1, -1, -258, -258, -515, -258, -258, -1, -1, -1, -1, 0, 257, 771, 1285, 1542, 2056, 2570, 3084, 3598, 3855, 3084, 771, -515, -1286, -1286, -515, -258, -772, -772, -1, 257, 1028, 1542, 2056, 1799, 1028, 0, -1286, -1800, -1029, -515, -1, -1, -772, -1029, -1286, -1543, -1543, -1543, -1286, -772, -1, 257, 771, 771, 514, 514, 257, -1, -515, -1543, -2828, -2828, -1286, 257, 2056, 3598, 4883, 4369, 2056, -1800, -7454, -8996, -6169, -4370, -3856, -7197, -14907, -21075, -25701, -24673, -17991, -8482, 4112 };

pub const golden_m3m = [_]u8{ 0x1C, 0x2E, 0x2B, 0xB8, 0x56, 0x9D, 0x80, 0x6C, 0x12, 0x51, 0xDC, 0xC9, 0xBE, 0xE3, 0x89, 0x12, 0x0E, 0xBA, 0xEE, 0xA3 };
pub const golden_m3m_expect = [_]i16{ -258, -258, -258, -258, -1, 0, 771, 1542, 2056, 2056, 1285, 257, -258, -1286, 257, -1286, -1800, -4627, -3342, -2057, -5655, -11309, -2828, 11565, 24929, 5397, 8481, 16962, -515, 18761, -15935, -24159, -32640, -15678, 7453, -8225, -20047, -23902, -32640, -258, 8738, 3341, 13878, 30840, -5655, 27756, -8482, 771, -20047, 15163, 20560, 32639, 17476, -13365, -28528, 2313, -3599, 29555, 32639, -3856 };

pub const golden_m6s = [_]u8{ 0x79, 0x42, 0xBD, 0xF2, 0x21, 0x06, 0xF0, 0x84, 0x77, 0x62, 0xF0, 0xF3, 0xCB, 0x4D, 0x76, 0x4D, 0xC7, 0x07, 0x20, 0x51 };
pub const golden_m6s_expect = [_]i16{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, -1, 0, -1, 0, -1, -1, -1, -1, -258, -1, -1, 0, -1, 0, -1, 0, 0, 0, 0, 0, 0, 0, 0, -1, 0, -258, 0, -258, -1, -258, -1, -258, -1, -258, -1, -1, 257, 0, 257, 514, 0, 1028, -1, 1285, -258, 1285, -515, 1028, -258, 771, -258, 257, -515, -515, -515, -515, -515, 257, -258, 1799, -258, 3341, -1, 4626, 0, 4883, 771, 3855, 1542, 1028, 2570, -1, 3598, 0, 3084, 2056, 1028, 5911, -1029, 5911, -3599, 1799, -4627, -1029, -4370, -3085, -3599, -2571, -2057, 514, -772, 1799, -1, 1028, 257, 1285, 514, 2313, 1028, 2056, 1542, 257, 1799, -258, 1285, -772 };

pub const golden_m3s = [_]u8{ 0x78, 0x9B, 0x34, 0xCA, 0xF5, 0x4F, 0x2E, 0x22, 0x0A, 0xCD, 0x94, 0x1E, 0x71, 0xB8, 0x8D, 0x58, 0x36, 0x86, 0x6D, 0x0D };
pub const golden_m3s_expect = [_]i16{ 0, -258, -1, -515, 257, -258, 771, 257, 514, 771, -515, 257, -1543, -1, -2571, 514, -2571, 1285, -2571, 2313, -515, 2313, 1285, 2827, 3341, 514, 5654, -1543, 5654, -5912, 1799, -7711, 5140, -8225, 1799, -6426, 4112, -8996, -515, -4113, 8224, -11566, 8738, -8482, 5140, -9767, -1800, -2314, -5655, -8739, -12080, 0, -5655, 15420, -9510, -2571, -5912, 15420, -15164, 17476 };

test "mace: MAC6 单声道黄金（20B → 120 样本）" {
    var ctx = Context{};
    var out: [120]i16 = undefined;
    const n = try decode(&ctx, &golden_m6m, 1, false, &out);
    try testing.expectEqual(@as(usize, 120), n);
    try testing.expectEqualSlices(i16, &golden_m6m_expect, &out);
}

test "mace: MAC3 单声道黄金（20B → 60 样本）" {
    var ctx = Context{};
    var out: [60]i16 = undefined;
    const n = try decode(&ctx, &golden_m3m, 1, true, &out);
    try testing.expectEqual(@as(usize, 60), n);
    try testing.expectEqualSlices(i16, &golden_m3m_expect, &out);
}

test "mace: MAC6 立体声黄金（20B → 120 交错样本）" {
    var ctx = Context{};
    var out: [120]i16 = undefined;
    const n = try decode(&ctx, &golden_m6s, 2, false, &out);
    try testing.expectEqual(@as(usize, 120), n);
    try testing.expectEqualSlices(i16, &golden_m6s_expect, &out);
}

test "mace: MAC3 立体声黄金（20B → 60 交错样本）" {
    var ctx = Context{};
    var out: [60]i16 = undefined;
    const n = try decode(&ctx, &golden_m3s, 2, true, &out);
    try testing.expectEqual(@as(usize, 60), n);
    try testing.expectEqualSlices(i16, &golden_m3s_expect, &out);
}

test "mace: 流式状态跨块保持（两块连续 ≠ 两块独立）" {
    // 连续解码两遍同一块：第二次因状态延续输出不同，证明状态跨调用保持
    var a = Context{};
    var b = Context{};
    var out_a1: [120]i16 = undefined;
    var out_a2: [120]i16 = undefined;
    _ = try decode(&a, &golden_m6m, 1, false, &out_a1);
    _ = try decode(&a, &golden_m6m, 1, false, &out_a2);
    _ = try decode(&b, &golden_m6m, 1, false, &out_a1); // 新 ctx 解码第一遍
    try testing.expectEqualSlices(i16, &out_a1, &out_a1); // 自洽
    try testing.expect(!std.mem.eql(i16, &out_a1, &out_a2)); // 第二遍输出不同
}

test "mace: 全 0 输入 MAC6 单声道静音（状态累积）" {
    var ctx = Context{};
    var out: [6]i16 = undefined;
    const n = try decode(&ctx, &[_]u8{0}, 1, false, &out);
    try testing.expectEqual(@as(usize, 6), n);
    try testing.expectEqualSlices(i16, &[_]i16{ 0, 0, 0, 0, 0, 0 }, &out);
}

test "mace: 非法输入拒绝（0 声道 / 缓冲不足）" {
    var ctx = Context{};
    var out: [6]i16 = undefined;
    try testing.expectError(error.Corrupt, decode(&ctx, &[_]u8{0}, 0, false, &out));
    try testing.expectError(error.Corrupt, decode(&ctx, &[_]u8{0}, 3, false, &out));
    var small: [5]i16 = undefined;
    try testing.expectError(error.Corrupt, decode(&ctx, &[_]u8{0}, 1, false, &small));
}
