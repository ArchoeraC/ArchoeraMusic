// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! TAK (Tom's lossless Audio Kompressor) 静态表 + CRC-24（对齐 FFmpeg n9.0.1）。
//!
//! 来源：libavcodec/takdec.c、libavcodec/tak.c、libavutil/crc.c
//!   - predictor_sizes：filter_order 索引表（16 项，末项 0）；
//!   - xcodes[50]：decode_segment 分段 Rice 码参数（CParam{init,escape,scale,aescape,bias}）；
//!   - mc_dmodes：多声道去相关类型表（索引 → 去相关 dmode）；
//!   - frame_duration_type_quants + tak_get_nb_samples：帧样本数换算；
//!   - CRC-24/IEEE（av_crc AV_CRC_24_IEEE，le=0 表，init 0xCE04B7）逐句复刻。

const std = @import("std");

// ---- tak.h 常量 ----

pub const TAK_MAX_CHANNELS: usize = 16;
pub const TAK_FRAME_HEADER_SYNC_ID: u32 = 0xA0FF;
pub const TAK_FRAME_HEADER_SYNC_ID_BITS: u32 = 16;
pub const TAK_FRAME_HEADER_FLAGS_BITS: u32 = 3;
pub const TAK_FRAME_HEADER_NO_BITS: u32 = 21;
pub const TAK_FRAME_HEADER_SAMPLE_COUNT_BITS: u32 = 14;
pub const TAK_FRAME_HEADER_FLAG_IS_LAST: u8 = 0x1;
pub const TAK_FRAME_HEADER_FLAG_HAS_INFO: u8 = 0x2;
pub const TAK_FRAME_HEADER_FLAG_HAS_METADATA: u8 = 0x4;
pub const TAK_CRC24_BITS: u32 = 24;

pub const TAK_FORMAT_DATA_TYPE_BITS: u32 = 3;
pub const TAK_FORMAT_SAMPLE_RATE_BITS: u32 = 18;
pub const TAK_FORMAT_BPS_BITS: u32 = 5;
pub const TAK_FORMAT_CHANNEL_BITS: u32 = 4;
pub const TAK_FORMAT_VALID_BITS: u32 = 5;
pub const TAK_FORMAT_CH_LAYOUT_BITS: u32 = 6;
pub const TAK_SIZE_FRAME_DURATION_BITS: u32 = 4;
pub const TAK_SIZE_SAMPLES_NUM_BITS: u32 = 35;
pub const TAK_ENCODER_CODEC_BITS: u32 = 6;
pub const TAK_ENCODER_PROFILE_BITS: u32 = 4;
pub const TAK_LAST_FRAME_POS_BITS: u32 = 40;
pub const TAK_LAST_FRAME_SIZE_BITS: u32 = 24;
pub const TAK_SAMPLE_RATE_MIN: u32 = 6000;
pub const TAK_CHANNELS_MIN: u32 = 1;
pub const TAK_BPS_MIN: u32 = 8;
pub const TAK_FRAME_DURATION_QUANT_SHIFT: u32 = 5;

pub const TAK_CODEC_MONO_STEREO: u32 = 2;
pub const TAK_CODEC_MULTICHANNEL: u32 = 4;

/// 元数据类型（libavformat/takdec.c enum TAKMetaDataType）
pub const TAK_METADATA_END: u8 = 0;
pub const TAK_METADATA_STREAMINFO: u8 = 1;
pub const TAK_METADATA_ENCODER: u8 = 4;
pub const TAK_METADATA_MD5: u8 = 6;
pub const TAK_METADATA_LAST_FRAME: u8 = 7;

/// TAK 每帧最大样本数（tak_get_nb_samples 上限）
pub const TAK_MAX_FRAME_SAMPLES: usize = 16384;
/// subframe 残差环形缓冲（takdec.c DECLARE_ALIGNED residues[544]）
pub const RESIDUES_RING: usize = 544;
/// 最大预测阶（takdec.c MAX_PREDICTORS）
pub const MAX_PREDICTORS: usize = 256;
/// 最大子帧数（takdec.c MAX_SUBFRAMES）
pub const MAX_SUBFRAMES: usize = 8;

// ---- takdec.c 静态表 ----

/// mc_dmodes[]（多声道去相关类型）
pub const mc_dmodes = [4]i8{ 1, 3, 4, 6 };

/// predictor_sizes[]：filter_order 索引 → 阶数
pub const predictor_sizes = [16]u16{
    4, 8, 12, 16, 24, 32, 48, 64, 80, 96, 128, 160, 192, 224, 256, 0,
};

/// xcodes[50]（CParam{init,escape,scale,aescape,bias}）
pub const XCode = struct {
    init: u32,
    escape: u32,
    scale: u32,
    aescape: u32,
    bias: u32,
};
pub const xcodes = [50]XCode{
    .{ .init = 0x01, .escape = 0x0000001, .scale = 0x0000001, .aescape = 0x0000003, .bias = 0x0000008 },
    .{ .init = 0x02, .escape = 0x0000003, .scale = 0x0000001, .aescape = 0x0000007, .bias = 0x0000006 },
    .{ .init = 0x03, .escape = 0x0000005, .scale = 0x0000002, .aescape = 0x000000E, .bias = 0x000000D },
    .{ .init = 0x03, .escape = 0x0000003, .scale = 0x0000003, .aescape = 0x000000D, .bias = 0x0000018 },
    .{ .init = 0x04, .escape = 0x000000B, .scale = 0x0000004, .aescape = 0x000001C, .bias = 0x0000019 },
    .{ .init = 0x04, .escape = 0x0000006, .scale = 0x0000006, .aescape = 0x000001A, .bias = 0x0000030 },
    .{ .init = 0x05, .escape = 0x0000016, .scale = 0x0000008, .aescape = 0x0000038, .bias = 0x0000032 },
    .{ .init = 0x05, .escape = 0x000000C, .scale = 0x000000C, .aescape = 0x0000034, .bias = 0x0000060 },
    .{ .init = 0x06, .escape = 0x000002C, .scale = 0x0000010, .aescape = 0x0000070, .bias = 0x0000064 },
    .{ .init = 0x06, .escape = 0x0000018, .scale = 0x0000018, .aescape = 0x0000068, .bias = 0x00000C0 },
    .{ .init = 0x07, .escape = 0x0000058, .scale = 0x0000020, .aescape = 0x00000E0, .bias = 0x00000C8 },
    .{ .init = 0x07, .escape = 0x0000030, .scale = 0x0000030, .aescape = 0x00000D0, .bias = 0x0000180 },
    .{ .init = 0x08, .escape = 0x00000B0, .scale = 0x0000040, .aescape = 0x00001C0, .bias = 0x0000190 },
    .{ .init = 0x08, .escape = 0x0000060, .scale = 0x0000060, .aescape = 0x00001A0, .bias = 0x0000300 },
    .{ .init = 0x09, .escape = 0x0000160, .scale = 0x0000080, .aescape = 0x0000380, .bias = 0x0000320 },
    .{ .init = 0x09, .escape = 0x00000C0, .scale = 0x00000C0, .aescape = 0x0000340, .bias = 0x0000600 },
    .{ .init = 0x0A, .escape = 0x00002C0, .scale = 0x0000100, .aescape = 0x0000700, .bias = 0x0000640 },
    .{ .init = 0x0A, .escape = 0x0000180, .scale = 0x0000180, .aescape = 0x0000680, .bias = 0x0000C00 },
    .{ .init = 0x0B, .escape = 0x0000580, .scale = 0x0000200, .aescape = 0x0000E00, .bias = 0x0000C80 },
    .{ .init = 0x0B, .escape = 0x0000300, .scale = 0x0000300, .aescape = 0x0000D00, .bias = 0x0001800 },
    .{ .init = 0x0C, .escape = 0x0000B00, .scale = 0x0000400, .aescape = 0x0001C00, .bias = 0x0001900 },
    .{ .init = 0x0C, .escape = 0x0000600, .scale = 0x0000600, .aescape = 0x0001A00, .bias = 0x0003000 },
    .{ .init = 0x0D, .escape = 0x0001600, .scale = 0x0000800, .aescape = 0x0003800, .bias = 0x0003200 },
    .{ .init = 0x0D, .escape = 0x0000C00, .scale = 0x0000C00, .aescape = 0x0003400, .bias = 0x0006000 },
    .{ .init = 0x0E, .escape = 0x0002C00, .scale = 0x0001000, .aescape = 0x0007000, .bias = 0x0006400 },
    .{ .init = 0x0E, .escape = 0x0001800, .scale = 0x0001800, .aescape = 0x0006800, .bias = 0x000C000 },
    .{ .init = 0x0F, .escape = 0x0005800, .scale = 0x0002000, .aescape = 0x000E000, .bias = 0x000C800 },
    .{ .init = 0x0F, .escape = 0x0003000, .scale = 0x0003000, .aescape = 0x000D000, .bias = 0x0018000 },
    .{ .init = 0x10, .escape = 0x000B000, .scale = 0x0004000, .aescape = 0x001C000, .bias = 0x0019000 },
    .{ .init = 0x10, .escape = 0x0006000, .scale = 0x0006000, .aescape = 0x001A000, .bias = 0x0030000 },
    .{ .init = 0x11, .escape = 0x0016000, .scale = 0x0008000, .aescape = 0x0038000, .bias = 0x0032000 },
    .{ .init = 0x11, .escape = 0x000C000, .scale = 0x000C000, .aescape = 0x0034000, .bias = 0x0060000 },
    .{ .init = 0x12, .escape = 0x002C000, .scale = 0x0010000, .aescape = 0x0070000, .bias = 0x0064000 },
    .{ .init = 0x12, .escape = 0x0018000, .scale = 0x0018000, .aescape = 0x0068000, .bias = 0x00C0000 },
    .{ .init = 0x13, .escape = 0x0058000, .scale = 0x0020000, .aescape = 0x00E0000, .bias = 0x00C8000 },
    .{ .init = 0x13, .escape = 0x0030000, .scale = 0x0030000, .aescape = 0x00D0000, .bias = 0x0180000 },
    .{ .init = 0x14, .escape = 0x00B0000, .scale = 0x0040000, .aescape = 0x01C0000, .bias = 0x0190000 },
    .{ .init = 0x14, .escape = 0x0060000, .scale = 0x0060000, .aescape = 0x01A0000, .bias = 0x0300000 },
    .{ .init = 0x15, .escape = 0x0160000, .scale = 0x0080000, .aescape = 0x0380000, .bias = 0x0320000 },
    .{ .init = 0x15, .escape = 0x00C0000, .scale = 0x00C0000, .aescape = 0x0340000, .bias = 0x0600000 },
    .{ .init = 0x16, .escape = 0x02C0000, .scale = 0x0100000, .aescape = 0x0700000, .bias = 0x0640000 },
    .{ .init = 0x16, .escape = 0x0180000, .scale = 0x0180000, .aescape = 0x0680000, .bias = 0x0C00000 },
    .{ .init = 0x17, .escape = 0x0580000, .scale = 0x0200000, .aescape = 0x0E00000, .bias = 0x0C80000 },
    .{ .init = 0x17, .escape = 0x0300000, .scale = 0x0300000, .aescape = 0x0D00000, .bias = 0x1800000 },
    .{ .init = 0x18, .escape = 0x0B00000, .scale = 0x0400000, .aescape = 0x1C00000, .bias = 0x1900000 },
    .{ .init = 0x18, .escape = 0x0600000, .scale = 0x0600000, .aescape = 0x1A00000, .bias = 0x3000000 },
    .{ .init = 0x19, .escape = 0x1600000, .scale = 0x0800000, .aescape = 0x3800000, .bias = 0x3200000 },
    .{ .init = 0x19, .escape = 0x0C00000, .scale = 0x0C00000, .aescape = 0x3400000, .bias = 0x6000000 },
    .{ .init = 0x1A, .escape = 0x2C00000, .scale = 0x1000000, .aescape = 0x7000000, .bias = 0x6400000 },
    .{ .init = 0x1A, .escape = 0x1800000, .scale = 0x1800000, .aescape = 0x6800000, .bias = 0xC000000 },
};

/// frame_duration_type_quants[]（libavformat 帧时长量化）
pub const frame_quants = [10]u32{ 3, 4, 6, 8, 4096, 8192, 16384, 512, 1024, 2048 };

/// tak_get_nb_samples（tak.c）：按采样率与 frame_type 求每帧样本数；
/// 非法 → error.Corrupt。
pub fn getNbSamples(sample_rate: u32, ftype: u32) Error!u32 {
    const nb_samples: u64 = if (ftype <= 3)
        @as(u64, sample_rate) * frame_quants[ftype] >> TAK_FRAME_DURATION_QUANT_SHIFT
    else if (ftype < 10)
        frame_quants[ftype]
    else
        return error.Corrupt;
    if (ftype <= 3) {
        // max_nb_samples = 16384
        if (nb_samples == 0 or nb_samples > TAK_MAX_FRAME_SAMPLES) return error.Corrupt;
    } else {
        const max_nb: u64 = @as(u64, sample_rate) * frame_quants[3] >> TAK_FRAME_DURATION_QUANT_SHIFT;
        if (nb_samples == 0 or nb_samples > max_nb) return error.Corrupt;
    }
    return @intCast(nb_samples);
}

// ---- CRC-24 / IEEE（av_crc AV_CRC_24_IEEE，le=0）----

/// 复刻 av_crc_init(le=0, bits=24, poly=0x864CFB) 的表项。
/// ctx[i] = av_bswap32(c)，其中 c 按 MSB 无反射多项式累加 8 位。
fn buildCrcTable() [256]u32 {
    @setEvalBranchQuota(100_000);
    const poly_shifted: u32 = 0x864CFB00; // poly << (32 - 24)
    var ctx: [256]u32 = undefined;
    for (0..256) |i| {
        var c: u32 = @intCast(i << 24);
        for (0..8) |_| {
            const sign: u1 = @truncate(c >> 31);
            c = (c << 1) ^ (if (sign == 1) poly_shifted else 0);
        }
        ctx[i] = @byteSwap(c);
    }
    return ctx;
}

const crc_table = buildCrcTable();

/// av_crc(ctx, crc, buffer, length)：逐字节 CRC 更新（32-bit 域）。
pub fn crc24Update(crc: u32, data: []const u8) u32 {
    var c = crc;
    for (data) |b| {
        c = crc_table[(c ^ b) & 0xFF] ^ (c >> 8);
    }
    return c & 0xFFFFFF;
}

/// ff_tak_check_crc(buf, buf_size)：末 3 字节（BE）为存储 CRC；
/// 对前 (buf_size-3) 字节以 init 0xCE04B7 校验。返回 true = 匹配。
pub fn checkCrc(buf: []const u8, buf_size: usize) bool {
    if (buf_size < 4) return false;
    const n = buf_size - 3;
    const stored: u32 = (@as(u32, buf[n]) << 16) | (@as(u32, buf[n + 1]) << 8) | buf[n + 2];
    return crc24Update(0xCE04B7, buf[0..n]) == stored;
}

/// 元数据块校验（payload + 3 字节 BE CRC）
pub fn checkMetaCrc(buf: []const u8) bool {
    if (buf.len < 3) return false;
    const n = buf.len - 3;
    const stored: u32 = (@as(u32, buf[n]) << 16) | (@as(u32, buf[n + 1]) << 8) | buf[n + 2];
    return crc24Update(0xCE04B7, buf[0..n]) == stored;
}

const Error = @import("../../error.zig").Error;

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "tables: predictor_sizes / xcodes 长度" {
    try testing.expectEqual(@as(usize, 16), predictor_sizes.len);
    try testing.expectEqual(@as(usize, 50), xcodes.len);
    try testing.expectEqual(@as(u16, 0), predictor_sizes[15]);
    try testing.expectEqual(@as(u32, 1), xcodes[0].init);
    try testing.expectEqual(@as(u32, 0xC000000), xcodes[49].bias);
}

test "tables: tak_get_nb_samples（44.1k ftype=3 → 11025；8k ftype=3 → 2000）" {
    try testing.expectEqual(@as(u32, 11025), try getNbSamples(44100, 3));
    try testing.expectEqual(@as(u32, 2000), try getNbSamples(8000, 3));
    // 固定样本数型（ftype>3）：上限 = rate*fq[ftype3]>>5（44.1k→11025、96k→24000）
    try testing.expectEqual(@as(u32, 4096), try getNbSamples(44100, 4));
    try testing.expectEqual(@as(u32, 512), try getNbSamples(44100, 7));
    try testing.expectEqual(@as(u32, 16384), try getNbSamples(96000, 6)); // 96k 上限 24000 ≥ 16384
    try testing.expectError(error.Corrupt, getNbSamples(44100, 6)); // 44.1k 上限 11025 < 16384
    // 非法 frame type
    try testing.expectError(error.Corrupt, getNbSamples(44100, 10));
}

test "tables: CRC-24 与真实 luckynight 元数据块吻合" {
    // luckynight-partial.tak：STREAMINFO 块 payload（10 字节）+ BE CRC cd 59 b8
    const si = [_]u8{ 0x02, 0x8D, 0x21, 0x99, 0x01, 0x00, 0x40, 0x4D, 0x09, 0x0A, 0xCD, 0x59, 0xB8 };
    try testing.expect(checkMetaCrc(&si));
    try testing.expect(!checkMetaCrc(si[0..12])); // CRC 字段被截 → 不匹配
    // LAST_FRAME payload 8B + CRC cf 31 54
    const lf = [_]u8{ 0x72, 0xFB, 0x0E, 0x00, 0x00, 0xBA, 0x6E, 0x00, 0xCF, 0x31, 0x54 };
    try testing.expect(checkMetaCrc(&lf));
    // 逐字节破坏 → 不匹配
    var bad = lf;
    bad[3] ^= 0xFF;
    try testing.expect(!checkMetaCrc(&bad));
}

test "tables: 帧头 CRC 校验（luckynight 首帧 19 字节头，尾 3 字节 CRC）" {
    const tak = @embedFile("samples/luckynight-partial.tak");
    // 帧区起点 = 110；首帧头 19 字节
    const hdr = tak[110 .. 110 + 19];
    try testing.expect(checkCrc(hdr, hdr.len));
    try testing.expect(!checkCrc(tak[110 .. 110 + 18], 18)); // 覆盖不足 CRC 长度
}
