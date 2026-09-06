// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! DTS core Huffman（VLC）解码（阶段二）
//!
//! FFmpeg dcahuff.c 的码表以 (符号, 码长) 给出，码字由 ff_vlc_init_from_lengths
//! 按"表序累加"分配：code_0 = 0；对每条正长码：取当前 code，随后
//! code += 1 << (32 - len)（MSB 左对齐）。此处 mk() 以同一规则派生码字，
//! 再按 (bits, code) 排序分组解码 → 位级消费与 FFmpeg 的 get_vlc2 一致。
//!
//! 与 fmt/aac/bitreader.zig 的 Vlc 思路同源：逐位累积 acc，每长度分组内
//! 二分精确匹配；匹配即返回（前缀码唯一）。

const std = @import("std");
const BitReader = @import("../aac/bitreader.zig").BitReader;
const hft = @import("huff_tables.zig");

pub const Entry = struct { code: u32, bits: u8, sym: i16 };

pub const max_entries = 129;

/// 单张 VLC：最多 129 条（码长 ≤ 16）。
pub const Huff = struct {
    entries: [max_entries]Entry = [_]Entry{.{ .code = 0, .bits = 0, .sym = 0 }} ** max_entries,
    start: [32]u16 = [_]u16{0} ** 32,
    count: [32]u16 = [_]u16{0} ** 32,
    size: u16 = 0,
    max_len: u8 = 0,

    pub fn isReady(self: *const Huff) bool {
        return self.size != 0;
    }
};

/// 由 (sym, len) 平行数组构建（comptime）。len==0 项跳过。
pub fn mk(comptime sym: []const i16, comptime len: []const u8, comptime off: i16) Huff {
    @setEvalBranchQuota(1_000_000);
    var h: Huff = .{};
    var code: u64 = 0;
    var n: usize = 0;
    for (sym, len) |s, l| {
        if (l == 0) continue;
        std.debug.assert(l <= 16);
        std.debug.assert(n < max_entries);
        h.entries[n] = .{ .code = @intCast(code), .bits = l, .sym = s + off };
        code += @as(u64, 1) << @intCast(32 - l);
        n += 1;
        if (l > h.max_len) h.max_len = l;
    }
    h.size = @intCast(n);
    // 插入排序：(bits, code) 升序
    var i: usize = 1;
    while (i < n) : (i += 1) {
        const e = h.entries[i];
        var j: usize = i;
        while (j > 0) {
            const p = h.entries[j - 1];
            const less = p.bits < e.bits or (p.bits == e.bits and p.code < e.code);
            if (less) break;
            h.entries[j] = p;
            j -= 1;
        }
        h.entries[j] = e;
    }
    // 按码长分组
    for (h.entries[0..n]) |e| h.count[e.bits] += 1;
    var acc: u16 = 0;
    var b: usize = 0;
    while (b < 32) : (b += 1) {
        h.start[b] = acc;
        acc += h.count[b];
    }
    return h;
}

/// 解一个符号（含偏移后的值）。无匹配 / 越界 → error.Corrupt。
pub fn decode(h: *const Huff, br: *BitReader) !i16 {
    var acc: u32 = 0;
    var len: usize = 1;
    while (len <= h.max_len) : (len += 1) {
        const bit = try br.readBits(1);
        acc = (acc << 1) | bit;
        const s = h.start[len];
        const e = s + h.count[len];
        var lo = s;
        var hi = e;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            // 码字 MSB 左对齐：取其前 len 位与 acc 比较
            const norm = h.entries[mid].code >> @intCast(32 - len);
            if (norm < acc) lo = mid + 1 else hi = mid;
        }
        if (lo < e and (h.entries[lo].code >> @intCast(32 - len)) == acc) return h.entries[lo].sym;
    }
    return error.Corrupt;
}

const empty_huff: Huff = .{};
pub const quant_tables: [10][7]Huff = .{
    .{ mk(&hft.quant_0_0_sym, &hft.quant_0_0_len, -1), empty_huff, empty_huff, empty_huff, empty_huff, empty_huff, empty_huff },
    .{ mk(&hft.quant_1_0_sym, &hft.quant_1_0_len, -2), mk(&hft.quant_1_1_sym, &hft.quant_1_1_len, -2), mk(&hft.quant_1_2_sym, &hft.quant_1_2_len, -2), empty_huff, empty_huff, empty_huff, empty_huff },
    .{ mk(&hft.quant_2_0_sym, &hft.quant_2_0_len, -3), mk(&hft.quant_2_1_sym, &hft.quant_2_1_len, -3), mk(&hft.quant_2_2_sym, &hft.quant_2_2_len, -3), empty_huff, empty_huff, empty_huff, empty_huff },
    .{ mk(&hft.quant_3_0_sym, &hft.quant_3_0_len, -4), mk(&hft.quant_3_1_sym, &hft.quant_3_1_len, -4), mk(&hft.quant_3_2_sym, &hft.quant_3_2_len, -4), empty_huff, empty_huff, empty_huff, empty_huff },
    .{ mk(&hft.quant_4_0_sym, &hft.quant_4_0_len, -6), mk(&hft.quant_4_1_sym, &hft.quant_4_1_len, -6), mk(&hft.quant_4_2_sym, &hft.quant_4_2_len, -6), empty_huff, empty_huff, empty_huff, empty_huff },
    .{ mk(&hft.quant_5_0_sym, &hft.quant_5_0_len, -8), mk(&hft.quant_5_1_sym, &hft.quant_5_1_len, -8), mk(&hft.quant_5_2_sym, &hft.quant_5_2_len, -8), mk(&hft.quant_5_3_sym, &hft.quant_5_3_len, -8), mk(&hft.quant_5_4_sym, &hft.quant_5_4_len, -8), mk(&hft.quant_5_5_sym, &hft.quant_5_5_len, -8), mk(&hft.quant_5_6_sym, &hft.quant_5_6_len, -8) },
    .{ mk(&hft.quant_6_0_sym, &hft.quant_6_0_len, -12), mk(&hft.quant_6_1_sym, &hft.quant_6_1_len, -12), mk(&hft.quant_6_2_sym, &hft.quant_6_2_len, -12), mk(&hft.quant_6_3_sym, &hft.quant_6_3_len, -12), mk(&hft.quant_6_4_sym, &hft.quant_6_4_len, -12), mk(&hft.quant_6_5_sym, &hft.quant_6_5_len, -12), mk(&hft.quant_6_6_sym, &hft.quant_6_6_len, -12) },
    .{ mk(&hft.quant_7_0_sym, &hft.quant_7_0_len, -16), mk(&hft.quant_7_1_sym, &hft.quant_7_1_len, -16), mk(&hft.quant_7_2_sym, &hft.quant_7_2_len, -16), mk(&hft.quant_7_3_sym, &hft.quant_7_3_len, -16), mk(&hft.quant_7_4_sym, &hft.quant_7_4_len, -16), mk(&hft.quant_7_5_sym, &hft.quant_7_5_len, -16), mk(&hft.quant_7_6_sym, &hft.quant_7_6_len, -16) },
    .{ mk(&hft.quant_8_0_sym, &hft.quant_8_0_len, -32), mk(&hft.quant_8_1_sym, &hft.quant_8_1_len, -32), mk(&hft.quant_8_2_sym, &hft.quant_8_2_len, -32), mk(&hft.quant_8_3_sym, &hft.quant_8_3_len, -32), mk(&hft.quant_8_4_sym, &hft.quant_8_4_len, -32), mk(&hft.quant_8_5_sym, &hft.quant_8_5_len, -32), mk(&hft.quant_8_6_sym, &hft.quant_8_6_len, -32) },
    .{ mk(&hft.quant_9_0_sym, &hft.quant_9_0_len, -64), mk(&hft.quant_9_1_sym, &hft.quant_9_1_len, -64), mk(&hft.quant_9_2_sym, &hft.quant_9_2_len, -64), mk(&hft.quant_9_3_sym, &hft.quant_9_3_len, -64), mk(&hft.quant_9_4_sym, &hft.quant_9_4_len, -64), mk(&hft.quant_9_5_sym, &hft.quant_9_5_len, -64), mk(&hft.quant_9_6_sym, &hft.quant_9_6_len, -64) },
};
pub const bitalloc_tables: [5]Huff = .{ mk(&hft.bitalloc_0_sym, &hft.bitalloc_0_len, 1), mk(&hft.bitalloc_1_sym, &hft.bitalloc_1_len, 1), mk(&hft.bitalloc_2_sym, &hft.bitalloc_2_len, 1), mk(&hft.bitalloc_3_sym, &hft.bitalloc_3_len, 1), mk(&hft.bitalloc_4_sym, &hft.bitalloc_4_len, 1) };
pub const scalef_tables: [5]Huff = .{ mk(&hft.scalef_0_sym, &hft.scalef_0_len, -64), mk(&hft.scalef_1_sym, &hft.scalef_1_len, -64), mk(&hft.scalef_2_sym, &hft.scalef_2_len, -64), mk(&hft.scalef_3_sym, &hft.scalef_3_len, -64), mk(&hft.scalef_4_sym, &hft.scalef_4_len, -64) };
pub const tmode_tables: [4]Huff = .{ mk(&hft.tmode_0_sym, &hft.tmode_0_len, 0), mk(&hft.tmode_1_sym, &hft.tmode_1_len, 0), mk(&hft.tmode_2_sym, &hft.tmode_2_len, 0), mk(&hft.tmode_3_sym, &hft.tmode_3_len, 0) };

test "dts huff: 码书派生一致性（前缀无冲突/码长正）" {
    // 逐表：较短的码不得是较长码的前缀（前缀码性质）
    for (&quant_tables) |*book| {
        for (book) |*tbl| {
            if (tbl.size == 0) continue;
            for (tbl.entries[0..tbl.size], 0..) |a, i| {
                for (tbl.entries[0..tbl.size], 0..) |b, j| {
                    if (i == j) continue;
                    if (a.bits < b.bits) {
                        const ah = a.code >> @intCast(32 - a.bits);
                        const bh = b.code >> @intCast(32 - a.bits);
                        try std.testing.expect(ah != bh);
                    }
                }
            }
        }
    }
    for (scalef_tables) |t| try std.testing.expectEqual(@as(u16, 129), t.size);
    for (bitalloc_tables) |t| try std.testing.expectEqual(@as(u16, 12), t.size);
    for (tmode_tables) |t| try std.testing.expectEqual(@as(u16, 4), t.size);
}

test "dts huff: 逐符号编解码往返" {
    // 对每个表每一条：把 len 位码字写入字节流并回读
    const tables = [_][]const Huff{
        &.{quant_tables[0][0]},
        &.{scalef_tables[2]},
        &.{bitalloc_tables[0]},
        &.{tmode_tables[1]},
    };
    for (tables) |list| {
        for (list) |*tbl| {
            for (tbl.entries[0..tbl.size]) |e| {
                var bytes: [4]u8 = .{ 0, 0, 0, 0 };
                var bpos: usize = 0;
                while (bpos < e.bits) : (bpos += 1) {
                    const bit: u1 = @intCast((e.code >> @intCast(31 - bpos)) & 1);
                    if (bit == 1) bytes[bpos >> 3] |= @as(u8, 1) << @intCast(7 - (bpos & 7));
                }
                var br = BitReader.init(&bytes);
                const got = try decode(tbl, &br);
                try std.testing.expectEqual(e.sym, got);
                try std.testing.expectEqual(@as(usize, e.bits), br.bit_pos);
            }
        }
    }
}
