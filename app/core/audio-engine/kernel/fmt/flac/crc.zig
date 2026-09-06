// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! 校验基础设施（FLAC 帧头 CRC-8 / 整帧与元数据块 CRC-16）
//!
//! 与 FFmpeg `libavutil/crc.c` 对齐（许可登记见 audio-engine/THIRD-PARTY-LICENSES.md）：
//!   - CRC-8 ATM（poly 0x07，MSB 优先，init 0，无反射 / 无最终异或）——
//!     帧头（含 CRC-8 字节本身）校验和应为 0；
//!   - CRC-16 ANSI（poly 0x8005，MSB 优先，init 0，无反射 / 无最终异或）——
//!     整帧（含 2 字节 CRC-16 尾部）与元数据块校验和应为 0。
//!
//! 逐字节增量接口供 `bitreader.zig` 滚动累加，无需缓存整帧。

const std = @import("std");

/// CRC-8（poly 0x07）：`crc ^ byte` 后按 MSB 依次移位异或
pub fn crc8Update(crc_: u8, byte: u8) u8 {
    var c = crc_ ^ byte;
    for (0..8) |_| {
        c = if (c & 0x80 != 0) (c << 1) ^ 0x07 else c << 1;
    }
    return c;
}

/// CRC-16（poly 0x8005）：字节异或到累加器高 8 位后按 MSB 依次移位异或
pub fn crc16Update(crc_: u16, byte: u8) u16 {
    var c = crc_ ^ (@as(u16, byte) << 8);
    for (0..8) |_| {
        c = if (c & 0x8000 != 0) (c << 1) ^ 0x8005 else c << 1;
    }
    return c;
}

/// 一次性 CRC-8（init 0）
pub fn crc8(bytes: []const u8) u8 {
    var c: u8 = 0;
    for (bytes) |b| c = crc8Update(c, b);
    return c;
}

/// 一次性 CRC-16（init 0）
pub fn crc16(bytes: []const u8) u16 {
    var c: u16 = 0;
    for (bytes) |b| c = crc16Update(c, b);
    return c;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "crc: CRC-8 ATM 标准校验向量（123456789 → 0xF4）" {
    try testing.expectEqual(@as(u8, 0xF4), crc8("123456789"));
}

test "crc: CRC-8 自反（含 CRC 字节校验和为 0）" {
    // 对任意数据：先算 crc，再补上 crc 字节整体校验 → 0
    const data = "flac-frame-header-bytes";
    var buf: [data.len + 1]u8 = undefined;
    @memcpy(buf[0..data.len], data);
    buf[data.len] = crc8(data);
    try testing.expectEqual(@as(u8, 0), crc8(&buf));
}

test "crc: CRC-16 ANSI 自反（含 CRC 字节校验和为 0）" {
    const data = "whole-frame-with-subframes-and-padding";
    var buf: [data.len + 2]u8 = undefined;
    @memcpy(buf[0..data.len], data);
    std.mem.writeInt(u16, buf[data.len..][0..2], crc16(data), .big);
    try testing.expectEqual(@as(u16, 0), crc16(&buf));
}

test "crc: 逐字节与一次性结果一致" {
    const data = "incremental-equivalence";
    var c: u8 = 0;
    var d: u16 = 0;
    for (data) |b| {
        c = crc8Update(c, b);
        d = crc16Update(d, b);
    }
    try testing.expectEqual(crc8(data), c);
    try testing.expectEqual(crc16(data), d);
}
