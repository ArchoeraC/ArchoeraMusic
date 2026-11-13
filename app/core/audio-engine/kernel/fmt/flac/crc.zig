// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: LGPL-2.1-or-later
// EraSync — ArchoeraMusic 音频内核
//
// ⚠ 衍生作品：移植 / 转录自 FFmpeg（LGPL-2.1-or-later）对应源文件。
// 上游版权归 FFmpeg 作者所有；本文件中移植部分及本项目改动均按
// LGPL-2.1-or-later 分发，逐文件溯源见 audio-engine/THIRD-PARTY-LICENSES.md。

const std = @import("std");

/// CRC-8 查表（poly 0x07，MSB 优先）：表项 = 以该字节为初值的 8 次逐位更新
const era_crc8_table: [256]u8 = blk: {
    @setEvalBranchQuota(20000);
    var t: [256]u8 = undefined;
    for (0..256) |i| {
        var c: u8 = @intCast(i);
        for (0..8) |_| c = if (c & 0x80 != 0) (c << 1) ^ 0x07 else c << 1;
        t[i] = c;
    }
    break :blk t;
};

/// CRC-16 查表（poly 0x8005，MSB 优先）：表项 = 以 (byte<<8) 为初值的 8 次逐位更新
const era_crc16_table: [256]u16 = blk: {
    @setEvalBranchQuota(20000);
    var t: [256]u16 = undefined;
    for (0..256) |i| {
        var c: u16 = @as(u16, @intCast(i)) << 8;
        for (0..8) |_| c = if (c & 0x8000 != 0) (c << 1) ^ 0x8005 else c << 1;
        t[i] = c;
    }
    break :blk t;
};

/// CRC-8（poly 0x07）：`crc ^ byte` 查表
pub inline fn crc8Update(crc_: u8, byte: u8) u8 {
    return era_crc8_table[crc_ ^ byte];
}

/// CRC-16（poly 0x8005）：字节异或到累加器高 8 位后查表
pub inline fn crc16Update(crc_: u16, byte: u8) u16 {
    return (crc_ *% 256) ^ era_crc16_table[@as(u8, @truncate(crc_ >> 8)) ^ byte];
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

/// word 级 unrolled：连续 4 字节更新（减少调用/循环开销；ILP 更友好）。
/// 语义与逐字节完全相同。
pub inline fn crc8Update4(crc_: u8, b: *const [4]u8) u8 {
    return crc8Update(crc8Update(crc8Update(crc8Update(crc_, b[0]), b[1]), b[2]), b[3]);
}

pub inline fn crc16Update4(crc_: u16, b: *const [4]u8) u16 {
    return crc16Update(crc16Update(crc16Update(crc16Update(crc_, b[0]), b[1]), b[2]), b[3]);
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

test "crc: word 级 unrolled 与逐字节一致 + 逐位参考对照" {
    const data = "0102030405060708090a0b";
    var c: u8 = 0;
    var d: u16 = 0;
    var i: usize = 0;
    while (i + 4 <= data.len) : (i += 4) {
        c = crc8Update4(c, data[i..][0..4]);
        d = crc16Update4(d, data[i..][0..4]);
    }
    while (i < data.len) : (i += 1) {
        c = crc8Update(c, data[i]);
        d = crc16Update(d, data[i]);
    }
    try testing.expectEqual(crc8(data), c);
    try testing.expectEqual(crc16(data), d);

    // 逐位参考（poly 0x07 / 0x8005）独立重算，证明表值正确
    var ref8: u8 = 0;
    var ref16: u16 = 0;
    for (data) |b| {
        var c8 = ref8 ^ b;
        for (0..8) |_| c8 = if (c8 & 0x80 != 0) (c8 << 1) ^ 0x07 else c8 << 1;
        ref8 = c8;
        var c16 = ref16 ^ (@as(u16, b) << 8);
        for (0..8) |_| c16 = if (c16 & 0x8000 != 0) (c16 << 1) ^ 0x8005 else c16 << 1;
        ref16 = c16;
    }
    try testing.expectEqual(ref8, c);
    try testing.expectEqual(ref16, d);
}
