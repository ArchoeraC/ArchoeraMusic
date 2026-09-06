// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! AAC 位流读取（MSB-first）+ Huffman（VLC）解码。
//!
//! 与 flac/alac 位读取的区别：
//!   - AAC 频谱/scalefactor 用非规范序 Huffman 码表（ISO 14496-3 Table 4.6.x，
//!     码字分配非按长度递增排列），不能走"canonical 首码差值"解码，
//!     须按 (长度, 码字) 精确匹配——Vlc 把码表整理为按长度分组的有序列表；
//!   - FFmpeg 的 VLC 语义：首传位 = 码值最高有效位（code 左对齐后取顶位建表，
//!     参考 aacdec_tab.c ff_vlc_init_tables_sparse），故累积 `acc = (acc<<1)|bit`
//!     与 len 位码值直接比较；
//!   - sparse 表（频谱码本）解码返回打包 idx 符号（低 nibble 序 = 值索引，
//!     高字节 = 非零计数/掩码），scalefactor 表返回 0..120 直接索引。
//!
//! 健壮性（§13.3）：所有读取校验剩余位数，越界 → error.Corrupt；
//! VLC 无匹配（码流损坏/截断）→ error.Corrupt。

const std = @import("std");
const Error = @import("../../error.zig").Error;

pub const BitReader = struct {
    data: []const u8,
    /// 已消费位数（字节内偏移 = bit_pos & 7）
    bit_pos: usize = 0,

    pub fn init(data: []const u8) BitReader {
        return .{ .data = data };
    }

    pub fn remainingBits(self: *const BitReader) usize {
        if (self.bit_pos >= self.data.len * 8) return 0;
        return self.data.len * 8 - self.bit_pos;
    }

    /// 读取 n 位（0..=32），MSB-first 组装为无符号整数。剩余不足 → error.Corrupt。
    pub fn readBits(self: *BitReader, n: u6) Error!u32 {
        if (self.bit_pos + n > self.data.len * 8) return error.Corrupt;
        var out: u32 = 0;
        var need: u32 = n;
        while (need > 0) {
            const byte: u8 = self.data[self.bit_pos >> 3];
            const bit_in_byte: u3 = @intCast(self.bit_pos & 7);
            const take: u5 = @intCast(@min(need, @as(u32, 8) - bit_in_byte));
            const shift: u3 = @intCast(@as(u8, 8) - bit_in_byte - take);
            const mask: u8 = if (take == 8) 0xFF else @as(u8, @intCast((@as(u32, 1) << @intCast(take)) - 1));
            const v: u8 = (byte >> shift) & mask;
            out = (out << @intCast(take)) | v;
            self.bit_pos += take;
            need -= take;
        }
        return out;
    }

    /// 查看 n 位（1..=32）但不消耗。
    pub fn showBits(self: *BitReader, n: u6) Error!u32 {
        const saved = self.bit_pos;
        defer self.bit_pos = saved;
        return self.readBits(n);
    }

    /// 跳过 n 位（越界 → error.Corrupt）。
    pub fn skipBits(self: *BitReader, n: u32) Error!void {
        if (self.bit_pos + n > self.data.len * 8) return error.Corrupt;
        self.bit_pos += n;
    }

    pub fn alignToByte(self: *BitReader) void {
        self.bit_pos = (self.bit_pos + 7) & ~@as(usize, 7);
    }

    pub fn byteAligned(self: *const BitReader) bool {
        return self.bit_pos % 8 == 0;
    }
};

/// 非规范序 Huffman 码表的精确匹配解码器。
/// 条目按 (bits, code) 升序整理；decode 逐位累积并按当前长度二分查找。
pub const Vlc = struct {
    pub const Entry = packed struct { code: u32, bits: u8, sym: u16 };

    /// 容量上限：scalefactor 121 / 最大频谱码本 289
    pub const max_entries = 289;

    entries: [max_entries]Entry = undefined,
    /// start[len]/count[len]：长度为 len 的码在 entries 中的区间（len 0 未用）
    start: [20]u16 = [_]u16{0} ** 20,
    count: [20]u16 = [_]u16{0} ** 20,
    max_len: u8 = 0,
    size: u16 = 0,

    /// 由平行数组构建（codes[k]/bits[k] → symbols[k]，symbols 为 null 时取索引 k）。
    /// codes 元素 u16/u32 均可；bits[k]==0 的占位项跳过。构建后须保证前缀无歧义（测试覆盖）。
    pub fn build(
        self: *Vlc,
        codes: anytype,
        bits: []const u8,
        symbols: ?[]const u16,
    ) void {
        std.debug.assert(codes.len == bits.len and codes.len <= max_entries);
        std.debug.assert(symbols == null or symbols.?.len == codes.len);
        self.size = 0;
        self.max_len = 0;
        for (codes, bits, 0..) |c_in, b, k| {
            if (b == 0) continue; // FFmpeg 表允许 0 位占位项（未使用符号）
            const c: u32 = c_in;
            std.debug.assert(b <= 19);
            self.entries[self.size] = .{
                .code = c,
                .bits = b,
                .sym = if (symbols) |s| s[k] else @intCast(k),
            };
            self.size += 1;
            if (b > self.max_len) self.max_len = b;
        }
        // 插入排序：(bits, code) 升序
        var i: u16 = 1;
        while (i < self.size) : (i += 1) {
            const e = self.entries[i];
            var j: u16 = i;
            while (j > 0) {
                const p = self.entries[j - 1];
                const less = p.bits < e.bits or (p.bits == e.bits and p.code < e.code);
                if (less) break;
                self.entries[j] = p;
                j -= 1;
            }
            self.entries[j] = e;
        }
        // 按长度分组：先计数，再前缀和
        @memset(&self.start, 0);
        @memset(&self.count, 0);
        for (self.entries[0..self.size]) |e| self.count[e.bits] += 1;
        var acc: u16 = 0;
        var len: usize = 0;
        while (len <= 19) : (len += 1) {
            self.start[len] = acc;
            acc += self.count[len];
        }
    }

    /// 解码一个符号。无匹配/越界 → error.Corrupt。
    pub fn decode(self: *const Vlc, br: *BitReader) Error!u16 {
        var acc: u32 = 0;
        var len: usize = 1;
        while (len <= self.max_len) : (len += 1) {
            const bit = try br.readBits(1);
            acc = (acc << 1) | bit;
            const s = self.start[len];
            const e = s + self.count[len];
            var lo = s;
            var hi = e;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                if (self.entries[mid].code < acc) lo = mid + 1 else hi = mid;
            }
            if (lo < e and self.entries[lo].code == acc) return self.entries[lo].sym;
        }
        return error.Corrupt;
    }
};

// ---------------- 测试 ----------------

const h = @import("huffman_tables.zig");
const t = @import("tables.zig");

fn bitPattern(comptime code: u32, comptime len: u6) []const u1 {
    comptime var out: [len]u1 = undefined;
    comptime var k = 0;
    comptime while (k < len) : (k += 1) {
        out[len - 1 - k] = @intCast((code >> k) & 1);
    };
    return &out;
}

test "BitReader 基础" {
    var br = BitReader.init(&.{ 0b1011_0010, 0b0100_0000 });
    try std.testing.expectEqual(@as(u32, 0b101), try br.readBits(3));
    try std.testing.expectEqual(@as(u32, 0b100100), try br.showBits(6)); // 剩余 6 位
    try std.testing.expectEqual(@as(u32, 0b100100), try br.showBits(6)); // 不消耗
    try std.testing.expectEqual(@as(u32, 0), try br.readBits(0));
    br.alignToByte();
    try std.testing.expectEqual(@as(usize, 8), br.bit_pos);
    try std.testing.expectEqual(@as(u32, 0b01), try br.readBits(2));
}

test "Vlc 构建与解码（scalefactor 表）" {
    var vlc: Vlc = .{};
    vlc.build(&h.scalefactor_code, &h.scalefactor_bits, null);
    // 已知锚点：code=0x00000 len=1 是符号 60（SCALE_DIFF_ZERO，最常见）
    var buf: [4]u8 = .{ 0, 0, 0, 0 };
    var br = BitReader.init(&buf); // 全 0 → 首 1 位 0 → 符号 60
    try std.testing.expectEqual(@as(u16, 60), try vlc.decode(&br));
}

test "Vlc 解码往返：全表逐符号编码回读" {
    var vlc: Vlc = .{};
    vlc.build(&h.scalefactor_code, &h.scalefactor_bits, null);

    for (h.scalefactor_code, h.scalefactor_bits, 0..) |c, b, sym| {
        if (b == 0) continue;
        var bytes: [4]u8 = .{ 0, 0, 0, 0 };
        // 写入 MSB-first 位模式
        var pos: usize = 0;
        var k: u5 = @intCast(b);
        while (k > 0) {
            k -= 1;
            const bit: u1 = @intCast((c >> k) & 1);
            if (bit == 1) bytes[pos >> 3] |= @as(u8, 1) << @intCast(7 - (pos & 7));
            pos += 1;
        }
        var br = BitReader.init(&bytes);
        try std.testing.expectEqual(@as(u16, @intCast(sym)), try vlc.decode(&br));
        try std.testing.expectEqual(@as(usize, b), br.bit_pos);
    }
}

test "频谱码本往返（book 11 抽样）" {
    var vlc: Vlc = .{};
    vlc.build(h.spectral_codes[10], h.spectral_bits[10], h.spectral_idx[10]);
    var checked: usize = 0;
    for (h.spectral_codes[10], h.spectral_bits[10], h.spectral_idx[10], 0..) |c, b, s, k| {
        if (b == 0 or (k % 17 != 0)) continue; // 抽样
        var bytes: [4]u8 = .{ 0, 0, 0, 0 };
        var pos: usize = 0;
        var kk: u5 = @intCast(b);
        while (kk > 0) {
            kk -= 1;
            const cw: u32 = c;
            const bit: u1 = @intCast((cw >> kk) & 1);
            if (bit == 1) bytes[pos >> 3] |= @as(u8, 1) << @intCast(7 - (pos & 7));
            pos += 1;
        }
        var br = BitReader.init(&bytes);
        try std.testing.expectEqual(s, try vlc.decode(&br));
        checked += 1;
    }
    try std.testing.expect(checked >= 15);
}
