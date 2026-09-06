// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Opus packet 解析（docs/audio-kernel-zig.md §9.2）
//!
//! RFC 6716 §3：TOC 字节（config 7-3 / stereo 2 / code 1-0）+ 帧计数 + 帧尺寸
//! 分割。参考重构对照 FFmpeg `libavcodec/opus/parse.c`（ff_opus_parse_packet，
//! 非自定界形态）与 RFC 6716 Table 2（许可登记见 audio-engine/THIRD-PARTY-LICENSES.md）。
//!
//! 语义要点（对齐参考实现，保证 bit-exact）：
//!   - Table 2：config 0-11 SILK-only（NB/MB/WB，10/20/40/60ms）、
//!     12-15 Hybrid（SWB/FB，10/20ms）、16-31 CELT-only（NB/WB/SWB/FB，
//!     2.5/5/10/20ms）；每档内 (config&3) / (config&1) 决定帧时长；
//!   - code 0 = 单帧；1 = 两帧等长（剩余须为偶数）；2 = 两帧变长（首帧 1-2
//!     字节长度）；3 = 任意帧数（帧数 6 位 / padding 标志 bit6 / VBR 标志 bit7，
//!     padding 长度走 xiph lacing，VBR 时 M-1 个 1-2 字节帧长）；
//!   - 采样率恒 48kHz。

const std = @import("std");
const Error = @import("../../error.zig").Error;

pub const MODE_SILK = 0;
pub const MODE_HYBRID = 1;
pub const MODE_CELT = 2;

/// 音频带宽（影响 SILK 重采样与 CELT 频带分配）
pub const Bandwidth = enum { nb, mb, wb, swb, fb };

/// 单帧切片（引用输入缓冲）
pub const Frame = struct {
    data: []const u8,
};

/// 解析后的 packet 视图
pub const Packet = struct {
    toc: u8,
    /// config（toc>>3，0..31）
    config: u8,
    /// 模式：SILK / HYBRID / CELT
    mode: u8,
    /// 带宽
    bandwidth: Bandwidth,
    /// 立体声标志
    stereo: bool,
    /// 帧大小（样本，48kHz）
    frame_size: u32,
    /// 帧数（1..48）
    count: usize,
    /// 帧尺寸（字节）[0..count)
    sizes: [48]u16 = undefined,
    /// 帧切片（data 缓冲内顺序）[0..count)
    frames: [48]Frame = undefined,
    /// 填充字节数
    padding: usize = 0,
    /// code 3 VBR 标志
    vbr: bool = false,
};

/// 每帧样本数（RFC 6716 Table 2；采样率恒 48kHz）
pub fn samplesPerFrame(toc: u8) u32 {
    const config = toc >> 3;
    if (config < 12) {
        // SILK-only：10/20/40/60ms（{1,2,4,6}×480，60ms=2880 非 2 幂）
        return switch (config & 3) {
            0 => 480,
            1 => 960,
            2 => 1920,
            else => 2880,
        };
    }
    if (config < 16) {
        // Hybrid：10/20ms
        return if ((config & 1) != 0) 960 else 480;
    }
    // CELT-only：2.5/5/10/20ms
    return @as(u32, 120) << @intCast(config & 3);
}

/// 模式判定（config → mode）
pub fn modeOf(toc: u8) u8 {
    const config = toc >> 3;
    if (config < 12) return MODE_SILK;
    if (config < 16) return MODE_HYBRID;
    return MODE_CELT;
}

/// 带宽判定（RFC 6716 Table 2）
pub fn bandwidthOf(toc: u8) Bandwidth {
    const config = toc >> 3;
    if (config < 4) return .nb;
    if (config < 8) return .mb;
    if (config < 12) return .wb;
    if (config < 14) return .swb;
    if (config < 16) return .fb;
    if (config < 20) return .nb;
    if (config < 24) return .wb;
    if (config < 28) return .swb;
    return .fb;
}

/// xiph_lacing_16bit：1-2 字节长度（值 ≥252 时需第二字节）
fn lacing16(data: []const u8, ptr: *usize) ?usize {
    if (ptr.* >= data.len) return null;
    var val: usize = data[ptr.*];
    ptr.* += 1;
    if (val >= 252) {
        if (ptr.* >= data.len) return null;
        val += 4 * data[ptr.*];
        ptr.* += 1;
    }
    return val;
}

/// xiph_lacing_full：多字节长度（padding 大小）
fn lacingFull(data: []const u8, ptr: *usize) ?usize {
    var val: usize = 0;
    while (true) {
        if (ptr.* >= data.len or val > 0xFFFFFF) return null;
        const next = data[ptr.*];
        ptr.* += 1;
        val += next;
        if (next < 255) break;
        val -%= 1;
    }
    return val;
}

/// 解析 packet：TOC + 帧分割（FFmpeg ff_opus_parse_packet 语义，非自定界）。
/// 非法 packet → error.Corrupt。
pub fn parse(data: []const u8) Error!Packet {
    if (data.len == 0) return error.Corrupt;
    var pkt = Packet{
        .toc = data[0],
        .config = data[0] >> 3,
        .mode = modeOf(data[0]),
        .bandwidth = bandwidthOf(data[0]),
        .stereo = (data[0] & 0x04) != 0,
        .frame_size = samplesPerFrame(data[0]),
        .count = 0,
    };

    var ptr: usize = 1;
    const end = data.len;

    // 帧数（RFC 6716 §3.2）
    const code = data[0] & 0x03;
    switch (code) {
        0 => pkt.count = 1,
        1 => pkt.count = 2,
        2 => pkt.count = 2,
        else => {
            if (ptr >= end) return error.Corrupt;
            const i = data[ptr];
            ptr += 1;
            pkt.count = i & 0x3F;
            if (pkt.count == 0 or pkt.count > 48) return error.Corrupt;
            const padding_flag = (i >> 6) & 0x01;
            pkt.vbr = (i >> 7) & 0x01 != 0;
            if (padding_flag != 0) {
                pkt.padding = lacingFull(data, &ptr) orelse return error.Corrupt;
            }
        },
    }
    if (pkt.count > 48) return error.Corrupt;

    // 帧尺寸
    switch (code) {
        0 => {
            pkt.sizes[0] = @intCast(end - ptr);
        },
        1 => {
            // 两帧等长（CBR）：剩余须为偶数 [R3]
            const avail = end - ptr;
            if (avail % 2 != 0) return error.Corrupt;
            const half: usize = avail / 2;
            if (half > std.math.maxInt(u16)) return error.Corrupt;
            pkt.sizes[0] = @intCast(half);
            pkt.sizes[1] = @intCast(half);
        },
        2 => {
            // 两帧变长：首帧长度 1-2 字节 [R4]
            const n1 = lacing16(data, &ptr) orelse return error.Corrupt;
            if (n1 > end - ptr) return error.Corrupt;
            pkt.sizes[0] = @intCast(n1);
            const n2 = end - ptr - n1;
            pkt.sizes[1] = @intCast(n2);
        },
        else => {
            // code 3：VBR / CBR
            if (pkt.vbr) {
                // VBR：M-1 个 1-2 字节长度，末帧取剩余
                var total: usize = 0;
                var i: usize = 0;
                while (i < pkt.count - 1) : (i += 1) {
                    const sz = lacing16(data, &ptr) orelse return error.Corrupt;
                    pkt.sizes[i] = @intCast(sz);
                    total += sz;
                }
                const rem = end - ptr;
                if (rem < pkt.padding or total > rem - pkt.padding) return error.Corrupt;
                pkt.sizes[pkt.count - 1] = @intCast(rem - pkt.padding - total);
            } else {
                // CBR：剩余 / M（须整除）
                const rem = end - ptr;
                if (rem < pkt.padding) return error.Corrupt;
                const avail = rem - pkt.padding;
                if (avail % pkt.count != 0) return error.Corrupt;
                const each = avail / pkt.count;
                if (each > std.math.maxInt(u16)) return error.Corrupt;
                for (0..pkt.count) |i| pkt.sizes[i] = @intCast(each);
            }
        },
    }

    // 帧切片（帧数据自头部之后开始；code 2/3 头部含长度/计数/填充字节）
    var off: usize = ptr;
    for (0..pkt.count) |i| {
        const sz: usize = pkt.sizes[i];
        if (off + sz > data.len) return error.Corrupt;
        pkt.frames[i] = .{ .data = data[off .. off + sz] };
        off += sz;
    }
    return pkt;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "opus packet: samplesPerFrame（RFC 6716 Table 2）" {
    // config 0-11 SILK：10/20/40/60ms（档内 (config&3)）
    try testing.expectEqual(@as(u32, 480), samplesPerFrame(0 << 3));
    try testing.expectEqual(@as(u32, 960), samplesPerFrame(1 << 3));
    try testing.expectEqual(@as(u32, 1920), samplesPerFrame(2 << 3));
    try testing.expectEqual(@as(u32, 2880), samplesPerFrame(3 << 3));
    try testing.expectEqual(@as(u32, 480), samplesPerFrame(4 << 3));
    try testing.expectEqual(@as(u32, 2880), samplesPerFrame(11 << 3));
    // config 12-15 Hybrid：10/20ms
    try testing.expectEqual(@as(u32, 480), samplesPerFrame(12 << 3));
    try testing.expectEqual(@as(u32, 960), samplesPerFrame(13 << 3));
    try testing.expectEqual(@as(u32, 480), samplesPerFrame(14 << 3));
    try testing.expectEqual(@as(u32, 960), samplesPerFrame(15 << 3));
    // config 16-31 CELT：2.5/5/10/20ms
    try testing.expectEqual(@as(u32, 120), samplesPerFrame(16 << 3));
    try testing.expectEqual(@as(u32, 240), samplesPerFrame(17 << 3));
    try testing.expectEqual(@as(u32, 480), samplesPerFrame(18 << 3));
    try testing.expectEqual(@as(u32, 960), samplesPerFrame(19 << 3));
    try testing.expectEqual(@as(u32, 120), samplesPerFrame(28 << 3));
    try testing.expectEqual(@as(u32, 960), samplesPerFrame(31 << 3));
}

test "opus packet: 模式 / 带宽判定" {
    try testing.expectEqual(MODE_SILK, modeOf(0 << 3));
    try testing.expectEqual(MODE_SILK, modeOf(11 << 3));
    try testing.expectEqual(MODE_HYBRID, modeOf(12 << 3));
    try testing.expectEqual(MODE_HYBRID, modeOf(15 << 3));
    try testing.expectEqual(MODE_CELT, modeOf(16 << 3));
    try testing.expectEqual(MODE_CELT, modeOf(31 << 3));

    try testing.expectEqual(Bandwidth.nb, bandwidthOf(0 << 3));
    try testing.expectEqual(Bandwidth.wb, bandwidthOf(11 << 3));
    try testing.expectEqual(Bandwidth.swb, bandwidthOf(12 << 3));
    try testing.expectEqual(Bandwidth.fb, bandwidthOf(15 << 3));
    try testing.expectEqual(Bandwidth.nb, bandwidthOf(16 << 3));
    try testing.expectEqual(Bandwidth.fb, bandwidthOf(31 << 3));
}

test "opus packet: 单帧 / 两帧等长 / 两帧变长 / 任意帧数" {
    // 单帧（code=0）：config 28（CELT FB 2.5ms），stereo，1 帧 = 全部数据
    const p1 = try parse(&[_]u8{ (28 << 3) | 0x04, 1, 2, 3, 4 });
    try testing.expectEqual(@as(usize, 1), p1.count);
    try testing.expectEqual(@as(usize, 4), p1.sizes[0]);
    try testing.expect(p1.stereo);
    try testing.expectEqual(@as(u32, 120), p1.frame_size);

    // 两帧等长（code=1）：10 字节数据 → 每帧 5
    const p2 = try parse(&[_]u8{ (28 << 3) | 0x01, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 });
    try testing.expectEqual(@as(usize, 2), p2.count);
    try testing.expectEqual(@as(usize, 5), p2.sizes[0]);
    try testing.expectEqual(@as(usize, 5), p2.sizes[1]);

    // 两帧变长（code=2）：首帧 3 字节，其余 7
    const p3 = try parse(&[_]u8{ (28 << 3) | 0x02, 3, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 });
    try testing.expectEqual(@as(usize, 2), p3.count);
    try testing.expectEqual(@as(usize, 3), p3.sizes[0]);
    try testing.expectEqual(@as(usize, 7), p3.sizes[1]);

    // 任意帧数（code=3）CBR：count=4，尺寸各 2
    const p4 = try parse(&[_]u8{ (28 << 3) | 0x03, 4, 9, 9, 9, 9, 9, 9, 9, 9 });
    try testing.expectEqual(@as(usize, 4), p4.count);
    try testing.expectEqual(@as(usize, 2), p4.sizes[0]);
    try testing.expectEqual(@as(usize, 2), p4.sizes[1]);
    try testing.expectEqual(@as(usize, 2), p4.sizes[2]);
    try testing.expectEqual(@as(usize, 2), p4.sizes[3]);

    // 任意帧数（code=3）VBR：byte2 高位 VBR=1，count=3，帧长 1,2，末帧剩余
    const p5 = try parse(&[_]u8{ (28 << 3) | 0x03, 0x83, 1, 2, 9, 9, 9, 9 });
    try testing.expectEqual(@as(usize, 3), p5.count);
    try testing.expectEqual(@as(usize, 1), p5.sizes[0]);
    try testing.expectEqual(@as(usize, 2), p5.sizes[1]);
    try testing.expectEqual(@as(usize, 1), p5.sizes[2]);
}

test "opus packet: 非法输入" {
    try testing.expectError(error.Corrupt, parse(&[_]u8{}));
    // code=3 count=0 → Corrupt
    try testing.expectError(error.Corrupt, parse(&[_]u8{ (28 << 3) | 0x03, 0, 1 }));
    // code=2 首帧长度越界 → Corrupt
    try testing.expectError(error.Corrupt, parse(&[_]u8{ (28 << 3) | 0x02, 99, 1, 2 }));
    // code=1 剩余为奇数 → Corrupt
    try testing.expectError(error.Corrupt, parse(&[_]u8{ (28 << 3) | 0x01, 1, 2, 3 }));
}
