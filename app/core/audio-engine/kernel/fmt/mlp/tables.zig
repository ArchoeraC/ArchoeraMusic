// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! MLP/TrueHD 表（对照 FFmpeg mlp.c / mlp_parse.c / mlpdec.c / mlp_parse.h）

/// 每表的符号数（表 0/1/2 分别 18/16/15 个）
pub const huff_syms = [3]usize{ 18, 16, 15 };
pub const huffman_tables = [3][18][2]u8{
    .{
        .{ 0x01, 9 },
        .{ 0x01, 8 },
        .{ 0x01, 7 },
        .{ 0x01, 6 },
        .{ 0x01, 5 },
        .{ 0x01, 4 },
        .{ 0x01, 3 },
        .{ 0x04, 3 },
        .{ 0x05, 3 },
        .{ 0x06, 3 },
        .{ 0x07, 3 },
        .{ 0x03, 3 },
        .{ 0x05, 4 },
        .{ 0x09, 5 },
        .{ 0x11, 6 },
        .{ 0x21, 7 },
        .{ 0x41, 8 },
        .{ 0x81, 9 },
    },
    .{
        .{ 0x01, 9 },
        .{ 0x01, 8 },
        .{ 0x01, 7 },
        .{ 0x01, 6 },
        .{ 0x01, 5 },
        .{ 0x01, 4 },
        .{ 0x01, 3 },
        .{ 0x02, 2 },
        .{ 0x03, 2 },
        .{ 0x03, 3 },
        .{ 0x05, 4 },
        .{ 0x09, 5 },
        .{ 0x11, 6 },
        .{ 0x21, 7 },
        .{ 0x41, 8 },
        .{ 0x81, 9 },
        .{ 0, 0 },
        .{ 0, 0 },
    },
    .{
        .{ 0x01, 9 },
        .{ 0x01, 8 },
        .{ 0x01, 7 },
        .{ 0x01, 6 },
        .{ 0x01, 5 },
        .{ 0x01, 4 },
        .{ 0x01, 3 },
        .{ 0x01, 1 },
        .{ 0x03, 3 },
        .{ 0x05, 4 },
        .{ 0x09, 5 },
        .{ 0x11, 6 },
        .{ 0x21, 7 },
        .{ 0x41, 8 },
        .{ 0x81, 9 },
        .{ 0, 0 },
        .{ 0, 0 },
        .{ 0, 0 },
    },
};

pub const ChannelInfo = struct { occupancy: u8, group1: u8, group2: u8, summary: u8 };
pub const ch_info = [21]ChannelInfo{
    .{ .occupancy = 0x01, .group1 = 0x01, .group2 = 0x00, .summary = 0x1f },
    .{ .occupancy = 0x03, .group1 = 0x02, .group2 = 0x00, .summary = 0x1b },
    .{ .occupancy = 0x07, .group1 = 0x02, .group2 = 0x01, .summary = 0x1f },
    .{ .occupancy = 0x0F, .group1 = 0x02, .group2 = 0x02, .summary = 0x19 },
    .{ .occupancy = 0x07, .group1 = 0x02, .group2 = 0x01, .summary = 0x03 },
    .{ .occupancy = 0x0F, .group1 = 0x02, .group2 = 0x02, .summary = 0x1f },
    .{ .occupancy = 0x1F, .group1 = 0x02, .group2 = 0x03, .summary = 0x01 },
    .{ .occupancy = 0x07, .group1 = 0x02, .group2 = 0x01, .summary = 0x1a },
    .{ .occupancy = 0x0F, .group1 = 0x02, .group2 = 0x02, .summary = 0x1f },
    .{ .occupancy = 0x1F, .group1 = 0x02, .group2 = 0x03, .summary = 0x18 },
    .{ .occupancy = 0x0F, .group1 = 0x02, .group2 = 0x02, .summary = 0x02 },
    .{ .occupancy = 0x1F, .group1 = 0x02, .group2 = 0x03, .summary = 0x1f },
    .{ .occupancy = 0x3F, .group1 = 0x02, .group2 = 0x04, .summary = 0x00 },
    .{ .occupancy = 0x0F, .group1 = 0x03, .group2 = 0x01, .summary = 0x1f },
    .{ .occupancy = 0x1F, .group1 = 0x03, .group2 = 0x02, .summary = 0x18 },
    .{ .occupancy = 0x0F, .group1 = 0x03, .group2 = 0x01, .summary = 0x02 },
    .{ .occupancy = 0x1F, .group1 = 0x03, .group2 = 0x02, .summary = 0x1f },
    .{ .occupancy = 0x3F, .group1 = 0x03, .group2 = 0x03, .summary = 0x00 },
    .{ .occupancy = 0x1F, .group1 = 0x04, .group2 = 0x01, .summary = 0x01 },
    .{ .occupancy = 0x1F, .group1 = 0x04, .group2 = 0x01, .summary = 0x18 },
    .{ .occupancy = 0x3F, .group1 = 0x04, .group2 = 0x02, .summary = 0x00 },
};

pub const noise_table = [256]i8{
    30, 51, 22, 54, 3, 7, -4, 38, 14, 55, 46, 81, 22, 58, -3, 2, 52, 31, -7, 51, 15, 44, 74, 30, 85, -17, 10, 33, 18, 80, 28, 62, 10, 32, 23, 69, 72, 26, 35, 17, 73, 60, 8, 56, 2, 6, -2, -5, 51, 4, 11, 50, 66, 76, 21, 44, 33, 47, 1, 26, 64, 48, 57, 40, 38, 16, -10, -28, 92, 22, -18, 29, -10, 5, -13, 49, 19, 24, 70, 34, 61, 48, 30, 14, -6, 25, 58, 33, 42, 60, 67, 17, 54, 17, 22, 30, 67, 44, -9, 50, -11, 43, 40, 32, 59, 82, 13, 49, -14, 55, 60, 36, 48, 49, 31, 47, 15, 12, 4, 65, 1, 23, 29, 39, 45, -2, 84, 69, 0, 72, 37, 57, 27, 41, -15, -16, 35, 31, 14, 61, 24, 0, 27, 24, 16, 41, 55, 34, 53, 9, 56, 12, 25, 29, 53, 5, 20, -20, -8, 20, 13, 28, -3, 78, 38, 16, 11, 62, 46, 29, 21, 24, 46, 65, 43, -23, 89, 18, 74, 21, 38, -12, 19, 12, -19, 8, 15, 33, 4, 57, 9, -8, 36, 35, 26, 28, 7, 83, 63, 79, 75, 11, 3, 87, 37, 47, 34, 40, 39, 19, 20, 42, 27, 34, 39, 77, 13, 42, 59, 64, 45, -1, 32, 37, 45, -5, 53, -6, 7, 36, 50, 23, 6, 32, 9, -21, 18, 71, 27, 52, -25, 31, 35, 42, -1, 68, 63, 52, 26, 43, 66, 37, 41, 25, 40, 70
};

pub const mlp_quants = [16]u8{ 16, 20, 24, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
pub const mlp_channels = [32]u8{ 1,2,3,4,3,4,5,3,4,5,4,5,6,4,5,4,5,6,5,5,6, 0,0,0,0,0,0,0,0,0,0,0 };
pub const mlp_layout = [32]u32{0x1, 0x3, 0x103, 0x33, 0xb, 0x10b, 0x3b, 0x103, 0x133, 0x37, 0x10b, 0x13b, 0x3f, 0x133, 0x37, 0x10b, 0x13b, 0x3f, 0x3b, 0x37, 0x3f, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0 };
pub const thd_layout = [13]u32{0x3, 0x4, 0x8, 0x600, 0x5000, 0xc0, 0x30, 0x100, 0x800, 0x300000, 0xc0000, 0x2000, 0x400000 };
pub const thd_chancount = [13]u8{ 2, 1, 1, 2, 2, 2, 2, 1, 1, 2, 2, 1, 1 };
// 声道 enum：FL=0 FR=1 FC=2 LFE=3 BL=4 BR=5 TFC=6 BC=8 SL=10 SR=11 TC=13 TFL=14 TFR=15 FLOC=16 FROC=17 WL=18 WR=19 SDL=20 SDR=21 LFE2=22
pub const thd_channel_order = [20]u8{ 0, 1, 2, 3, 9, 10, 12, 14, 6, 7, 4, 5, 8, 11, 22, 23, 20, 21, 13, 24 };