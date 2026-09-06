// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Matroska/EBML 最小解析（内存切片，零分配）
//!
//! Matroska 是 EBML 树。本模块只提供解析所需原语：
//!   - vint 长度判定（首字节前导零计数 +1，上限 8；§EBML spec）；
//!   - 元素遍历（id vint + size vint + payload）。
//!
//! 已知元素 id（MATROSKA_ID_*，libavformat/matroskadec.c matroska_ebml_elements）：
//!   0x1A45DFA3 EBML 头 / 0x18538067 Segment / 0x114D9B74 SeekHead /
//!   0x1549A966 Info / 0x1654AE6B Tracks / 0x1254C367 Tags / 0x1C53BB6B Cues /
//!   0x1F43B675 Cluster / 0xA3 SimpleBlock / 0xA0 BlockGroup / 0xA1 Block /
//!   0xEC Void / 0xBF CRC-32。
//!
//! 语义（参考重构，对照 matroskadec.c matroska_ebmlnum 系列）：
//!   - vint 值 = 整段按 BE 大整数去掉 marker 位后剩余位；
//!     首字节 b0 前导零 z → 总长 L=z+1，值有效位 = L*8-(z+1)（恒 ≤ 56，u64 安全）；
//!   - id 同样按前导零定长（1..4 字节），保留 marker 位为 id 的一部分；
//!   - 所有越界读返回 null，由调用方按 Corrupt 处理（§13.3 有界）。

const std = @import("std");

/// vint 长度 = 首字节前导零计数 + 1（1..8；0x00 非法但按 1 处理由调用方判定）
pub fn vintLength(b0: u8) u8 {
    var z: u8 = 0;
    while (z < 7 and (b0 & (@as(u8, 0x80) >> @intCast(z))) == 0) : (z += 1) {}
    return z + 1;
}

/// 解析 off 处 vint 的字节长度与值（marker 位不计入值）。非法/越界 → null。
pub const Vint = struct {
    len: u8,
    value: u64,
};

pub fn readVint(data: []const u8, off: usize) ?Vint {
    if (off >= data.len) return null;
    const b0 = data[off];
    var z: u8 = 0;
    while (z < 7 and (b0 & (@as(u8, 0x80) >> @intCast(z))) == 0) : (z += 1) {}
    const L: u8 = z + 1;
    if (off + L > data.len) return null;
    const value_bits: u6 = @intCast(@as(u16, L) * 8 - (@as(u16, z) + 1));
    var v: u64 = 0;
    for (0..L) |i| v = (v << 8) | data[off + i];
    if (value_bits == 64) return null; // 不可能（≤56）
    v &= (@as(u64, 1) << @intCast(value_bits)) - 1;
    return .{ .len = L, .value = v };
}

/// 顶层/嵌套元素视图：id 字节 + payload + 下一个元素偏移。
pub const Elem = struct {
    id: []const u8,
    payload: []const u8,
    /// 本元素之后的下一个元素偏移
    next: usize,
    /// payload 是否被 end 截断（数据不足）
    truncated: bool = false,

    /// id 等值判断
    pub fn is(self: *const Elem, comptime bytes: []const u8) bool {
        return std.mem.eql(u8, self.id, bytes);
    }
};

/// 解析 off 处的元素。off ≥ end → null（无更多元素）。
/// id 定长（1..4）+ size vint；payload 截到 end 上限。
pub fn elem(data: []const u8, off: usize, end: usize) ?Elem {
    if (off >= end or off >= data.len) return null;
    const il = vintLength(data[off]);
    if (il > 4 or off + il > end or off + il > data.len) return null;
    const id = data[off .. off + il];
    const sz = readVint(data, off + il) orelse return null;
    if (sz.len > 8) return null;
    const ps = off + il + sz.len;
    if (ps > end or ps > data.len) return null;
    var pe = ps + @as(usize, @intCast(sz.value));
    var truncated = false;
    if (pe > end) {
        pe = end;
        truncated = true;
    }
    if (pe > data.len) {
        pe = data.len;
        truncated = true;
    }
    return .{
        .id = id,
        .payload = data[ps..pe],
        .next = ps + @as(usize, @intCast(sz.value)),
        .truncated = truncated,
    };
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "ebml: vint 长度与值" {
    // 1 字节：0xA3 → len1 值 0x23
    const v1 = readVint(&[_]u8{ 0xA3, 0xFF }, 0).?;
    try testing.expectEqual(@as(u8, 1), v1.len);
    try testing.expectEqual(@as(u64, 0x23), v1.value);
    // 2 字节：0x40 0xA3 → 值 0xA3
    const v2 = readVint(&[_]u8{ 0x40, 0xA3 }, 0).?;
    try testing.expectEqual(@as(u8, 2), v2.len);
    try testing.expectEqual(@as(u64, 0xA3), v2.value);
    // 8 字节 segment size：0x01 00..7C43 → 0x7C43
    const v8 = readVint(&[_]u8{ 0x01, 0, 0, 0, 0, 0, 0x7C, 0x43 }, 0).?;
    try testing.expectEqual(@as(u8, 8), v8.len);
    try testing.expectEqual(@as(u64, 0x7C43), v8.value);
    // 越界（2 字节 vint 只给 1 字节）→ null
    try testing.expect(readVint(&[_]u8{0x40}, 0) == null);
    try testing.expect(readVint(&[_]u8{}, 0) == null);
}

test "ebml: 元素遍历（EBML 头样例）" {
    // 1A45DFA3 | 8F | 4286 81 01 | 4282 86 'matroska'
    const data = [_]u8{
        0x1A, 0x45, 0xDF, 0xA3, 0x8F, // EBML 头 id + size=15
        0x42, 0x86, 0x81, 0x01, // EBMLVersion 1
        0x42, 0x82, 0x88, 'm', 'a', 't', 'r', 'o', 's', 'k', 'a', // DocType
    };
    const e0 = elem(&data, 0, data.len).?;
    try testing.expectEqualSlices(u8, &[_]u8{ 0x1A, 0x45, 0xDF, 0xA3 }, e0.id);
    // 子元素在 e0.payload 内
    const e1 = elem(e0.payload, 0, e0.payload.len).?;
    try testing.expectEqualSlices(u8, &[_]u8{ 0x42, 0x86 }, e1.id);
    try testing.expectEqual(@as(u64, 1), e1.payload[0]);
    const e2 = elem(e0.payload, e1.next, e0.payload.len).?;
    try testing.expectEqualSlices(u8, "matroska", e2.payload);
    try testing.expectEqual(@as(usize, e0.payload.len), e2.next);
}

test "ebml: end 截断 → truncated" {
    // 声明 payload 10 字节，end 只给 4
    const data = [_]u8{ 0xA3, 0x8A, 1, 2, 3, 4 }; // SimpleBlock size=10
    const e = elem(&data, 0, 6).?;
    try testing.expect(e.truncated);
    try testing.expectEqual(@as(usize, 4), e.payload.len);
    try testing.expectEqual(@as(usize, 12), e.next);
}
