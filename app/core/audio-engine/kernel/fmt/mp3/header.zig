//! MPEG Audio 帧头解析（对齐 minimp3 hdr_* 宏语义）。
//!
//! 4 字节帧头：[sync 11][version 2][layer 2][protection 1][bitrate 4]
//!            [samplerate 2][padding 1][private 1][channel_mode 2][mode_ext 2][copyright 1][original 1][emphasis 2]
//!
//! 注意：layer 编号遵循 minimp3/libmad：Layer III=1, Layer II=2, Layer I=3。

const std = @import("std");

pub const LAYER_III: u8 = 1;
pub const LAYER_II: u8 = 2;
pub const LAYER_I: u8 = 3;

pub const MODE_MONO: u8 = 3;
pub const MODE_JOINT_STEREO: u8 = 1;

/// 采样率表（MPEG1 基率；MPEG2 减半；MPEG2.5 再减半）
const g_hz = [3]u32{ 44100, 48000, 32000 };

pub inline fn hdrIsLayer1(h: []const u8) bool {
    return (h[1] & 6) == 6;
}
pub inline fn hdrIsFrame576(h: []const u8) bool {
    return (h[1] & 14) == 2;
}
pub inline fn hdrFrameSamples(h: []const u8) usize {
    return if (hdrIsLayer1(h)) 384 else (@as(usize, 1152) >> @intFromBool(hdrIsFrame576(h)));
}

pub inline fn hdrTestMPEG1(h: []const u8) bool {
    return (h[1] & 0x8) != 0;
}
pub inline fn hdrTestNotMPEG25(h: []const u8) bool {
    return (h[1] & 0x10) != 0;
}
pub inline fn hdrIsFreeFormat(h: []const u8) bool {
    return (h[2] & 0xF0) == 0;
}
pub inline fn hdrTestPadding(h: []const u8) bool {
    return (h[2] & 0x2) != 0;
}
pub inline fn hdrIsMono(h: []const u8) bool {
    return (h[3] & 0xC0) == 0xC0;
}
pub inline fn hdrIsMS_Stereo(h: []const u8) bool {
    return (h[3] & 0xE0) == 0x60;
}
pub inline fn hdrIsIStereo(h: []const u8) bool {
    return (h[3] & 0x10) != 0;
}
pub inline fn hdrIsMsStereo(h: []const u8) bool {
    return (h[3] & 0x20) != 0;
}
pub inline fn hdrGetStereoMode(h: []const u8) u8 {
    return (h[3] >> 6) & 3;
}
pub inline fn hdrGetStereoModeExt(h: []const u8) u8 {
    return (h[3] >> 4) & 3;
}
pub inline fn hdrGetLayer(h: []const u8) u8 {
    return (h[1] >> 1) & 3;
}
pub inline fn hdrGetBitrate(h: []const u8) u8 {
    return h[2] >> 4;
}
pub inline fn hdrGetSampleRate(h: []const u8) u8 {
    return (h[2] >> 2) & 3;
}
/// 内部采样率索引 0..7（MPEG1:0-2, MPEG2:3-5, MPEG2.5:6-8 但映射到 0-7）
pub inline fn hdrGetMySampleRate(h: []const u8) u8 {
    return hdrGetSampleRate(h) + @as(u8, @intFromBool(hdrTestMPEG1(h))) * 3 + @as(u8, @intFromBool(hdrTestNotMPEG25(h))) * 3;
}

pub fn hdrValid(h: []const u8) bool {
    if (h.len < 4) return false;
    return h[0] == 0xff and
        ((h[1] & 0xF0) == 0xF0 or (h[1] & 0xFE) == 0xE2) and
        hdrGetLayer(h) != 0 and
        hdrGetBitrate(h) != 15 and
        hdrGetSampleRate(h) != 3;
}

pub fn hdrCompare(h1: []const u8, h2: []const u8) bool {
    if (h2.len < 4) return false;
    if (!hdrValid(h2)) return false;
    return ((h1[1] ^ h2[1]) & 0xFE) == 0 and
        ((h1[2] ^ h2[2]) & 0x0C) == 0 and
        !(hdrIsFreeFormat(h1) ^ hdrIsFreeFormat(h2));
}

/// 码率表（halfrate[MPEG1?][layer-1][bitrate_index]，×2 得 kbps）。
/// layer-1=0 → Layer III，1 → Layer II，2 → Layer I。
const halfrate = [2][3][15]u8{
    .{ // MPEG2 / 2.5 (lsf)
        .{ 0, 4, 8, 12, 16, 20, 24, 28, 32, 40, 48, 56, 64, 72, 80 }, // Layer III (×2=8..160)
        .{ 0, 4, 8, 12, 16, 20, 24, 28, 32, 40, 48, 56, 64, 72, 80 }, // Layer II
        .{ 0, 16, 24, 28, 32, 40, 48, 56, 64, 72, 80, 88, 96, 112, 128 }, // Layer I
    },
    .{ // MPEG1
        .{ 0, 16, 20, 24, 28, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160 }, // Layer III (×2=32..320)
        .{ 0, 16, 24, 28, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192 }, // Layer II
        .{ 0, 16, 32, 48, 64, 80, 96, 112, 128, 144, 160, 176, 192, 208, 224 }, // Layer I
    },
};

pub fn hdrBitrateKbps(h: []const u8) u32 {
    const mpeg1: usize = @intFromBool(hdrTestMPEG1(h));
    const layer: usize = @as(usize, hdrGetLayer(h)) - 1;
    const idx: usize = hdrGetBitrate(h);
    return 2 * @as(u32, halfrate[mpeg1][layer][idx]);
}

pub fn hdrSampleRateHz(h: []const u8) u32 {
    const s = hdrGetSampleRate(h);
    var r = g_hz[s];
    if (!hdrTestMPEG1(h)) r >>= 1;
    if (!hdrTestNotMPEG25(h)) r >>= 1;
    return r;
}

/// 帧字节数；free-format 时用调用者给的 frame_size
pub fn hdrFrameBytes(h: []const u8, free_format_size: usize) usize {
    var frame_bytes = hdrFrameSamples(h) * hdrBitrateKbps(h) * 125 / hdrSampleRateHz(h);
    if (hdrIsLayer1(h)) frame_bytes &= ~@as(usize, 3); // slot align
    return if (frame_bytes != 0) frame_bytes else free_format_size;
}

pub fn hdrPadding(h: []const u8) usize {
    if (!hdrTestPadding(h)) return 0;
    return if (hdrIsLayer1(h)) 4 else 1;
}

pub const FrameInfo = struct {
    frame_bytes: i32 = 0,
    frame_offset: i32 = 0,
    channels: i32 = 0,
    hz: i32 = 0,
    layer: i32 = 0,
    bitrate_kbps: i32 = 0,
};

const testing = std.testing;

test "MPEG1 Layer III 帧头解析" {
    const h = [_]u8{ 0xFF, 0xFB, 0x90, 0x00 }; // MPEG1, Layer III, 128kbps, 44100, stereo
    try testing.expect(hdrValid(&h));
    try testing.expect(hdrTestMPEG1(&h));
    try testing.expect(hdrTestNotMPEG25(&h));
    try testing.expectEqual(LAYER_III, hdrGetLayer(&h));
    try testing.expectEqual(@as(u32, 128), hdrBitrateKbps(&h));
    try testing.expectEqual(@as(u32, 44100), hdrSampleRateHz(&h));
    try testing.expectEqual(@as(usize, 1152), hdrFrameSamples(&h));
    try testing.expectEqual(@as(usize, 417), hdrFrameBytes(&h, 0));
    try testing.expect(!hdrIsMono(&h));
    try testing.expectEqual(@as(usize, 0), hdrPadding(&h));
}

test "MPEG2 Layer III 帧头解析" {
    const h = [_]u8{ 0xFF, 0xF3, 0x90, 0x00 }; // MPEG2, Layer III, 64kbps(?), 22050, stereo
    try testing.expect(hdrValid(&h));
    try testing.expect(!hdrTestMPEG1(&h));
    try testing.expect(hdrTestNotMPEG25(&h));
    // 0x90>>4 = 9, MPEG2 L3 表 [0][0][9]=40 → 80kbps
    try testing.expectEqual(@as(u32, 80), hdrBitrateKbps(&h));
    try testing.expectEqual(@as(u32, 22050), hdrSampleRateHz(&h));
    try testing.expectEqual(@as(usize, 576), hdrFrameSamples(&h));
}

test "MPEG2.5 Layer III 帧头解析" {
    const h = [_]u8{ 0xFF, 0xE3, 0x90, 0x00 }; // MPEG2.5, Layer III, 11025, stereo
    try testing.expect(hdrValid(&h));
    try testing.expect(!hdrTestMPEG1(&h));
    try testing.expect(!hdrTestNotMPEG25(&h));
    try testing.expectEqual(@as(u32, 11025), hdrSampleRateHz(&h));
    try testing.expectEqual(@as(usize, 576), hdrFrameSamples(&h));
}

test "MPEG1 Layer I 帧头" {
    const h = [_]u8{ 0xFF, 0xFE, 0xC0, 0x00 }; // MPEG1, Layer I, 384kbps, 44100
    try testing.expect(hdrValid(&h));
    try testing.expectEqual(LAYER_I, hdrGetLayer(&h));
    try testing.expectEqual(@as(u32, 384), hdrBitrateKbps(&h));
    try testing.expectEqual(@as(usize, 384), hdrFrameSamples(&h));
}

test "无效帧头拒绝" {
    const bad = [_]u8{ 0x41, 0x42, 0x43, 0x44 };
    try testing.expect(!hdrValid(&bad));
    const bad_rate = [_]u8{ 0xFF, 0xFB, 0xFC, 0x00 }; // bitrate=15 无效
    try testing.expect(!hdrValid(&bad_rate));
}
