// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! AAC 静态结构表（采样率 / 声道 / swb 偏移 / TNS 上限）。
//! 数值取自 ISO/IEC 14496-3 规范表，与 FFmpeg n9.0.1 aactab.c/mpeg4audio.c 数值交叉核对。

pub const sample_rates = [13]u32{
    96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350,
};

pub const channels = [15]u8{
    0, 1, 2, 3, 4, 5, 6, 8, 0, 0, 0, 7, 8, 24, 8,
};

pub const num_swb_1024 = [13]u8{
    41, 41, 47, 49, 49, 51, 47, 47, 43, 43, 43, 40, 40,
};

pub const num_swb_128 = [13]u8{
    12, 12, 12, 14, 14, 14, 15, 15, 15, 15, 15, 15, 15,
};

pub const tns_max_bands_1024 = [13]u8{
    31, 31, 34, 40, 42, 51, 46, 46, 42, 42, 42, 39, 39,
};

pub const tns_max_bands_128 = [13]u8{
    9, 9, 10, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14,
};

pub const swb_offset_1024_16 = [44]u16{
    0,   8,   16,  24,  32,  40,  48,  56,  64,  72,  80,  88,   100, 112, 124, 136,
    148, 160, 172, 184, 196, 212, 228, 244, 260, 280, 300, 320,  344, 368, 396, 424,
    456, 492, 532, 572, 616, 664, 716, 772, 832, 896, 960, 1024,
};

pub const swb_offset_1024_24 = [48]u16{
    0,   4,   8,   12,  16,  20,  24,  28,  32,  36,  40,  44,  52,  60,  68,  76,
    84,  92,  100, 108, 116, 124, 136, 148, 160, 172, 188, 204, 220, 240, 260, 284,
    308, 336, 364, 396, 432, 468, 508, 552, 600, 652, 704, 768, 832, 896, 960, 1024,
};

pub const swb_offset_1024_32 = [52]u16{
    0,   4,   8,   12,   16,  20,  24,  28,  32,  36,  40,  48,  56,  64,  72,  80,
    88,  96,  108, 120,  132, 144, 160, 176, 196, 216, 240, 264, 292, 320, 352, 384,
    416, 448, 480, 512,  544, 576, 608, 640, 672, 704, 736, 768, 800, 832, 864, 896,
    928, 960, 992, 1024,
};

pub const swb_offset_1024_48 = [50]u16{
    0,   4,    8,   12,  16,  20,  24,  28,  32,  36,  40,  48,  56,  64,  72,  80,
    88,  96,   108, 120, 132, 144, 160, 176, 196, 216, 240, 264, 292, 320, 352, 384,
    416, 448,  480, 512, 544, 576, 608, 640, 672, 704, 736, 768, 800, 832, 864, 896,
    928, 1024,
};

pub const swb_offset_1024_64 = [48]u16{
    0,   4,   8,   12,  16,  20,  24,  28,  32,  36,  40,  44,  48,  52,  56,  64,
    72,  80,  88,  100, 112, 124, 140, 156, 172, 192, 216, 240, 268, 304, 344, 384,
    424, 464, 504, 544, 584, 624, 664, 704, 744, 784, 824, 864, 904, 944, 984, 1024,
};

pub const swb_offset_1024_8 = [41]u16{
    0,   12,  24,  36,  48,  60,  72,  84,  96,   108, 120, 132, 144, 156, 172, 188,
    204, 220, 236, 252, 268, 288, 308, 328, 348,  372, 396, 420, 448, 476, 508, 544,
    580, 620, 664, 712, 764, 820, 880, 944, 1024,
};

pub const swb_offset_1024_96 = [42]u16{
    0,   4,   8,   12,  16,  20,  24,  28,  32,  36,   40,  44,  48,  52,  56,  64,
    72,  80,  88,  96,  108, 120, 132, 144, 156, 172,  188, 212, 240, 276, 320, 384,
    448, 512, 576, 640, 704, 768, 832, 896, 960, 1024,
};

pub const swb_offset_128_16 = [16]u16{
    0, 4, 8, 12, 16, 20, 24, 28, 32, 40, 48, 60, 72, 88, 108, 128,
};

pub const swb_offset_128_24 = [16]u16{
    0, 4, 8, 12, 16, 20, 24, 28, 36, 44, 52, 64, 76, 92, 108, 128,
};

pub const swb_offset_128_48 = [15]u16{
    0, 4, 8, 12, 16, 20, 28, 36, 44, 56, 68, 80, 96, 112, 128,
};

pub const swb_offset_128_8 = [16]u16{
    0, 4, 8, 12, 16, 20, 24, 28, 36, 44, 52, 60, 72, 88, 108, 128,
};

pub const swb_offset_128_96 = [13]u16{
    0, 4, 8, 12, 16, 20, 24, 32, 40, 48, 64, 92, 128,
};

pub const swb_offset_1024 = [13][]const u16{
    &swb_offset_1024_96,
    &swb_offset_1024_96,
    &swb_offset_1024_64,
    &swb_offset_1024_48,
    &swb_offset_1024_48,
    &swb_offset_1024_32,
    &swb_offset_1024_24,
    &swb_offset_1024_24,
    &swb_offset_1024_16,
    &swb_offset_1024_16,
    &swb_offset_1024_16,
    &swb_offset_1024_8,
    &swb_offset_1024_8,
};

pub const swb_offset_128 = [13][]const u16{
    &swb_offset_128_96,
    &swb_offset_128_96,
    &swb_offset_128_96,
    &swb_offset_128_48,
    &swb_offset_128_48,
    &swb_offset_128_48,
    &swb_offset_128_24,
    &swb_offset_128_24,
    &swb_offset_128_16,
    &swb_offset_128_16,
    &swb_offset_128_16,
    &swb_offset_128_8,
    &swb_offset_128_8,
};

pub const tns_tmp2_map_0_3 = [8]f32{
    @bitCast(@as(u32, 0x00000000)), @bitCast(@as(u32, 0xBEDE2602)), @bitCast(@as(u32, 0xBF48261C)), @bitCast(@as(u32, 0xBF7994E0)), @bitCast(@as(u32, 0x3F7C1C5C)), @bitCast(@as(u32, 0x3F5DB3D7)), @bitCast(@as(u32, 0x3F248DBA)), @bitCast(@as(u32, 0x3EAF1D44)),
};
pub const tns_tmp2_map_0_4 = [16]f32{
    @bitCast(@as(u32, 0x00000000)), @bitCast(@as(u32, 0xBE54E6CE)), @bitCast(@as(u32, 0xBED03FC9)), @bitCast(@as(u32, 0xBF167918)), @bitCast(@as(u32, 0xBF3E3EBD)), @bitCast(@as(u32, 0xBF5DB3D7)), @bitCast(@as(u32, 0xBF737871)), @bitCast(@as(u32, 0xBF7E98FD)),
    @bitCast(@as(u32, 0x3F7EE86F)), @bitCast(@as(u32, 0x3F763A34)), @bitCast(@as(u32, 0x3F65296C)), @bitCast(@as(u32, 0x3F4C4ADB)), @bitCast(@as(u32, 0x3F2C7751)), @bitCast(@as(u32, 0x3F06C442)), @bitCast(@as(u32, 0x3EB8F4AB)), @bitCast(@as(u32, 0x3E3C28D5)),
};
pub const tns_tmp2_map_1_3 = [4]f32{
    @bitCast(@as(u32, 0x00000000)), @bitCast(@as(u32, 0xBEDE2602)), @bitCast(@as(u32, 0x3F248DBA)), @bitCast(@as(u32, 0x3EAF1D44)),
};
pub const tns_tmp2_map_1_4 = [8]f32{
    @bitCast(@as(u32, 0x00000000)), @bitCast(@as(u32, 0xBE54E6CE)), @bitCast(@as(u32, 0xBED03FC9)), @bitCast(@as(u32, 0xBF167918)), @bitCast(@as(u32, 0x3F2C7751)), @bitCast(@as(u32, 0x3F06C442)), @bitCast(@as(u32, 0x3EB8F4AB)), @bitCast(@as(u32, 0x3E3C28D5)),
};
pub const tns_tmp2_map = [4][]const f32{
    &tns_tmp2_map_0_3, &tns_tmp2_map_0_4, &tns_tmp2_map_1_3, &tns_tmp2_map_1_4,
};
