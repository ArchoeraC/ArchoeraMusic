// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! G.711 A-LAW / mu-LAW 解码（docs/audio-kernel-zig.md §9.1：WAV/AIFF 编码扩展）
//!
//! 以 ITU-T G.711 定义直接公式展开（不自带 FFmpeg 查表，避免版权依赖，
//! 结果与 FFmpeg alaw.c/mulaw.c 逐值一致——标准定义下的唯一正确解）。
//! 输入 8-bit 压缩样本 → 16-bit 线性 PCM（s16）。

const std = @import("std");

/// A-LAW 8-bit → 线性 s16（0x00 → -5504，0x55 → 0，0xFF → 5503）
pub fn alawDecode(a: u8) i16 {
    const x = a ^ 0x55; // 奇偶位翻转（ITU 定义）
    var t: i32 = @as(i32, x & 0x0F) << 4;
    const seg: u32 = (x & 0x70) >> 4;
    switch (seg) {
        0 => t += 8,
        1 => t += 0x108,
        else => {
            t += 0x108;
            t <<= @intCast(seg - 1);
        },
    }
    const v: i32 = if (x & 0x80 != 0) t else -t;
    return @intCast(v);
}

/// mu-LAW 8-bit → 线性 s16（0xFF → 0 静音，0x80 → -32124，0x7F → 32124）
pub fn mulawDecode(u: u8) i16 {
    const x = ~u;
    var t: i32 = (@as(i32, x & 0x0F) << 3) + 0x84;
    t <<= @intCast((x & 0x70) >> 4);
    const v: i32 = if (x & 0x80 != 0) 0x84 - t else t - 0x84;
    return @intCast(v);
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "g711: A-LAW 标准锚点值（16-bit 尺度，ITU-T G.711 表）" {
    // 对照 ITU 表 / FFmpeg alaw2linear（输出为 16-bit 尺度，max = ±32256 = 4032*8）：
    //   - A-law 为"中平"量化：无精确 0，静音码 0x55 解码为 -8；
    //   - 最小码 0x00 → -5504，最大正 0xAA → +32256，最大负 0x2A → -32256。
    try testing.expectEqual(@as(i16, -5504), alawDecode(0x00));
    try testing.expectEqual(@as(i16, -8), alawDecode(0x55));
    try testing.expectEqual(@as(i16, 8), alawDecode(0xD5));
    try testing.expectEqual(@as(i16, 848), alawDecode(0xFF));
    try testing.expectEqual(@as(i16, 32256), alawDecode(0xAA));
    try testing.expectEqual(@as(i16, -32256), alawDecode(0x2A));
}

test "g711: mu-LAW 标准锚点值（16-bit 尺度）" {
    // 对照 ITU 表 / FFmpeg ulaw2linear：
    //   - mu-law 为"中阶"量化：0xFF 与 0x7F 都解码为 0（静音死区）；
    //   - 最小码 0x00 → -32124（最大负），0x80 → +32124（最大正）。
    try testing.expectEqual(@as(i16, 0), mulawDecode(0xFF));
    try testing.expectEqual(@as(i16, 0), mulawDecode(0x7F));
    try testing.expectEqual(@as(i16, -32124), mulawDecode(0x00));
    try testing.expectEqual(@as(i16, 32124), mulawDecode(0x80));
    try testing.expectEqual(@as(i16, 8), mulawDecode(0xFE));
    try testing.expectEqual(@as(i16, -8), mulawDecode(0x7E));
}

test "g711: 符号对称（码值 XOR 0x80 互为相反数）" {
    // 两编码的符号位都在码值 bit7；翻转 bit7 仅取反输出（幅度不变）。
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        const a = @as(u8, @intCast(i));
        try testing.expectEqual(-alawDecode(a), alawDecode(a ^ 0x80));
        try testing.expectEqual(-mulawDecode(a), mulawDecode(a ^ 0x80));
    }
}

test "g711: 全表单调（排序后无逆序；mu-law 恰有一对静音重复）" {
    // A-law 为双射：256 码值 → 256 个互异输出，排序后必须严格递增。
    // mu-law 为"中阶"量化：0xFF 与 0x7F 都解码为 0，其余 254 个互异 ——
    // 排序后非递减，且相等相邻对恰好 1 个（静音死区）。
    var alaw: [256]i16 = undefined;
    var mulaw: [256]i16 = undefined;
    for (0..256) |i| {
        alaw[i] = alawDecode(@intCast(i));
        mulaw[i] = mulawDecode(@intCast(i));
    }
    std.mem.sort(i16, &alaw, {}, std.sort.asc(i16));
    std.mem.sort(i16, &mulaw, {}, std.sort.asc(i16));

    for (1..256) |i| try testing.expect(alaw[i - 1] < alaw[i]);

    var dup_mu: usize = 0;
    for (1..256) |i| {
        try testing.expect(mulaw[i - 1] <= mulaw[i]);
        if (mulaw[i - 1] == mulaw[i]) dup_mu += 1;
    }
    try testing.expectEqual(@as(usize, 1), dup_mu);
}
