// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! FLAC 残差解码（分区 Rice 编码，参考重构对照 flacdec.c decode_residuals）
//!
//! 位排布：
//!   method_type(2) + rice_order(4) + 每分区参数 k(rice_bits) +
//!   每样本 Rice 码 / escape 原始值
//!
//! 语义：
//!   - `samples = blocksize >> rice_order`，分区数 = 1 << rice_order；
//!   - `rice_bits = 4 + method_type`（0→4 位 k，1→5 位 k），
//!     `rice_esc = (1 << rice_bits) - 1`（k == rice_esc → escape：跟 5 位原始
//!     位宽，读 `samples` 个有符号原始值）；
//!   - 正常路径：前缀 `i` 个 0 + 1 停止位 + k 位尾部，`u = (i << k) | tail`，
//!     符号折叠 `(u>>1) ^ -(u&1)`（golomb.h get_sr_golomb_flac）：
//!       u 偶 → 正 u/2；u 奇 → 负 -(u+1)/2；
//!   - **第一分区**样本循环从 `pred_order` 起（前 pred_order 个为 warm-up），
//!     其后各分区从 0 起（flacdec.c 的 `i = 0` 复位）；
//!   - 非法输入：method_type > 1、blocksize 不能整除分区数、
//!     pred_order > samples、前缀超界 → error.Corrupt。

const std = @import("std");
const Error = @import("../../error.zig").Error;
const bitreader = @import("bitreader.zig");

const BitReader = bitreader.BitReader;

/// 解码单个 FLAC Rice 码（有符号）。
/// k ∈ 0..30（rice_esc 已在外层排除）。
pub fn readGolombFlac(br: *BitReader, k: u8) Error!i32 {
    // 前缀：i 个 0 后跟 1 停止位（缓存内批量数零；逐位一致）
    const i: u32 = try br.readUnary1(63);
    if (i > 63) return error.Corrupt; // 恶意长前缀上限
    const kk: u5 = @intCast(k); // k ≤ 30（rice_esc 已排除）
    var value: u32 = 0;
    if (k > 0) value = try br.readBits(kk);
    // 防 (i << k) 溢出 u32
    if (i > (@as(u32, 0xFFFFFFFF) >> kk)) return error.Corrupt;
    value |= i << kk;
    // 符号折叠（golomb.h）：(v >> 1) ^ -(v & 1)
    const neg: i32 = if (value & 1 != 0) -1 else 0;
    return @as(i32, @intCast(value >> 1)) ^ neg;
}

/// 解码一帧全部残差到 `out[0..blocksize]`。
/// warm-up 样本由调用方（subframe.zig）先行写入 out[0..pred_order]。
pub fn decodeResiduals(
    br: *BitReader,
    out: []i32,
    pred_order: usize,
    blocksize: usize,
) Error!void {
    const method_type: u2 = @intCast(try br.readBits(2));
    const rice_order: u4 = @intCast(try br.readBits(4));
    if (method_type > 1) return error.Corrupt;

    const partition_count: usize = @as(usize, 1) << rice_order;
    if (blocksize % partition_count != 0) return error.Corrupt;
    const samples = blocksize >> rice_order;
    if (pred_order > samples) return error.Corrupt;

    const rice_bits: u5 = 4 + @as(u5, method_type);
    const rice_esc: u32 = (@as(u32, 1) << rice_bits) - 1;

    // 写入位置连续推进：warm-up 占 out[0..pred_order)，残差从 out[pred_order] 起。
    // 分区 0 写 samples-pred_order 个，其后各分区写 samples 个（flacdec.c）。
    var pos: usize = pred_order;
    var partition: usize = 0;
    while (partition < partition_count) : (partition += 1) {
        const k = try br.readBits(rice_bits);
        const count = if (partition == 0) samples - pred_order else samples;
        if (k == rice_esc) {
            // escape：5 位原始位宽，读 count 个有符号原始值
            const raw_bits: u5 = @intCast(try br.readBits(5));
            var j: usize = 0;
            while (j < count) : (j += 1) {
                out[pos + j] = try br.readBitsSigned(raw_bits);
            }
        } else {
            const kk: u8 = @intCast(k);
            var j: usize = 0;
            while (j < count) : (j += 1) {
                out[pos + j] = try readGolombFlac(br, kk);
            }
        }
        pos += count;
    }
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;
const io = @import("../../io.zig");

/// 测试用 MSB-first 位写入器（pub 供 subframe.zig 测试复用）
pub const TestBits = struct {
    bytes: std.ArrayList(u8),
    cache: u8 = 0,
    nbits: u8 = 0,

    pub fn init() TestBits {
        return .{ .bytes = .empty };
    }
    pub fn deinit(self: *TestBits) void {
        self.bytes.deinit(testing.allocator);
    }
    pub fn appendBits(self: *TestBits, value: u32, n: u5) !void {
        var i: u6 = 0; // u6：n 最大 32，i 递增到 32 需越出 u5
        while (i < n) : (i += 1) {
            const bit: u1 = @intCast((value >> @intCast(n - 1 - i)) & 1);
            self.cache = (self.cache << 1) | bit;
            self.nbits += 1;
            if (self.nbits == 8) {
                try self.bytes.append(testing.allocator, self.cache);
                self.cache = 0;
                self.nbits = 0;
            }
        }
    }
    /// Rice 编码一个残差：zigzag(u) → q 个 0 + 1 + k 位尾部
    pub fn appendGolomb(self: *TestBits, k: u5, residual: i32) !void {
        const u: u32 = if (residual >= 0)
            @as(u32, @intCast(residual)) * 2
        else
            @as(u32, @intCast(-residual)) * 2 - 1;
        const q = u >> k;
        const tail = u & ((@as(u32, 1) << k) - 1);
        try self.appendBits(0, @intCast(q)); // 前缀 q 个 0
        try self.appendBits(1, 1); // 停止位
        if (k > 0) try self.appendBits(tail, k);
    }
    pub fn padToByte(self: *TestBits) !void {
        while (self.nbits != 0) try self.appendBits(0, 1);
    }
    pub fn toOwnedSlice(self: *TestBits) ![]u8 {
        try self.padToByte();
        return self.bytes.toOwnedSlice(testing.allocator);
    }
};

fn decodeResidualsBytes(bytes: []const u8, pred_order: usize, blocksize: usize) ![]i32 {
    var r = io.Reader.openMem(bytes);
    var br = BitReader.init(&r);
    const out = try testing.allocator.alloc(i32, blocksize);
    errdefer testing.allocator.free(out);
    try decodeResiduals(&br, out, pred_order, blocksize);
    return out;
}

test "residual: k=0 基本解码与符号折叠" {
    // 残差 [0,1,-1,2,-2,3,-3,0] → u=[0,2,1,4,3,6,5,0]（k=0：q=u，无尾部）
    var w = TestBits.init();
    defer w.deinit();
    try w.appendBits(0, 2); // method 0
    try w.appendBits(0, 4); // rice_order 0 → 1 分区，samples=8
    try w.appendBits(0, 4); // 分区 k=0
    for ([_]i32{ 0, 1, -1, 2, -2, 3, -3, 0 }) |res| try w.appendGolomb(0, res);
    const bytes = try w.toOwnedSlice();
    defer testing.allocator.free(bytes);

    const out = try decodeResidualsBytes(bytes, 0, 8);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(i32, &.{ 0, 1, -1, 2, -2, 3, -3, 0 }, out);
}

test "residual: k=1 带尾部解码" {
    // 残差 [0,1,-1,2] → u=[0,2,1,4]（k=1：q=u>>1）
    var w = TestBits.init();
    defer w.deinit();
    try w.appendBits(0, 2);
    try w.appendBits(0, 4); // samples=4
    try w.appendBits(1, 4); // 分区 k=1
    for ([_]i32{ 0, 1, -1, 2 }) |res| try w.appendGolomb(1, res);
    const bytes = try w.toOwnedSlice();
    defer testing.allocator.free(bytes);

    const out = try decodeResidualsBytes(bytes, 0, 4);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(i32, &.{ 0, 1, -1, 2 }, out);
}

test "residual: 多分区（rice_order=1，两分区各 samples）" {
    // blocksize=8，rice_order=1 → 2 分区 × 4 样本
    var w = TestBits.init();
    defer w.deinit();
    try w.appendBits(0, 2); // method 0
    try w.appendBits(1, 4); // rice_order 1
    try w.appendBits(0, 4); // 分区 0 的 k=0
    for ([_]i32{ 0, 1, -1, 2 }) |res| try w.appendGolomb(0, res);
    try w.appendBits(0, 4); // 分区 1 的 k=0
    for ([_]i32{ 3, -3, 4, -4 }) |res| try w.appendGolomb(0, res);
    const bytes = try w.toOwnedSlice();
    defer testing.allocator.free(bytes);

    const out = try decodeResidualsBytes(bytes, 0, 8);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(i32, &.{ 0, 1, -1, 2, 3, -3, 4, -4 }, out);
}

test "residual: 第一分区跳过 pred_order 个 warm-up" {
    // blocksize=8，pred_order=2：warm-up 占 out[0..2)，
    // 分区 0 写 out[2..4)（samples-pred_order=2），分区 1 写 out[4..8)
    var w = TestBits.init();
    defer w.deinit();
    try w.appendBits(0, 2); // method 0
    try w.appendBits(1, 4); // rice_order 1 → 2 分区 × 4
    try w.appendBits(0, 4); // 分区 0 k=0：写 out[2..4)
    for ([_]i32{ 10, 11 }) |res| try w.appendGolomb(0, res);
    try w.appendBits(0, 4); // 分区 1 k=0：写 out[4..8)
    for ([_]i32{ 1, 2, 3, 4 }) |res| try w.appendGolomb(0, res);
    const bytes = try w.toOwnedSlice();
    defer testing.allocator.free(bytes);

    // 真实用法：warm-up 样本由 subframe 先行写入 out[0..pred_order)
    var r = io.Reader.openMem(bytes);
    var br = BitReader.init(&r);
    const out = try testing.allocator.alloc(i32, 8);
    defer testing.allocator.free(out);
    out[0] = 5;
    out[1] = 6;
    try decodeResiduals(&br, out, 2, 8);
    try testing.expectEqualSlices(i32, &.{ 5, 6, 10, 11, 1, 2, 3, 4 }, out);
}

test "residual: escape 编码（原始有符号位宽）" {
    // method 0, order 0, k=rice_esc=15，raw_bits=4，4 个 4 位有符号值
    var w = TestBits.init();
    defer w.deinit();
    try w.appendBits(0, 2); // method 0
    try w.appendBits(0, 4); // order 0 → samples=4
    try w.appendBits(15, 4); // k == rice_esc
    try w.appendBits(4, 5); // raw_bits = 4
    for ([_]i32{ -8, 7, -1, 0 }) |v| try w.appendBits(@bitCast(v), 4);
    const bytes = try w.toOwnedSlice();
    defer testing.allocator.free(bytes);

    const out = try decodeResidualsBytes(bytes, 0, 4);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(i32, &.{ -8, 7, -1, 0 }, out);
}

test "residual: 非法输入 → Corrupt" {
    // method_type = 3
    var w1 = TestBits.init();
    defer w1.deinit();
    try w1.appendBits(3, 2);
    const b1 = try w1.toOwnedSlice();
    defer testing.allocator.free(b1);
    try testing.expectError(error.Corrupt, decodeResidualsBytes(b1, 0, 8));

    // blocksize=8, rice_order=2（4 分区）无法整除 → Corrupt
    var w2 = TestBits.init();
    defer w2.deinit();
    try w2.appendBits(0, 2);
    try w2.appendBits(2, 4);
    const b2 = try w2.toOwnedSlice();
    defer testing.allocator.free(b2);
    try testing.expectError(error.Corrupt, decodeResidualsBytes(b2, 0, 8));

    // pred_order > samples（blocksize=8, order=0 → samples=8, pred_order=9）
    var w3 = TestBits.init();
    defer w3.deinit();
    try w3.appendBits(0, 2);
    try w3.appendBits(0, 4);
    const b3 = try w3.toOwnedSlice();
    defer testing.allocator.free(b3);
    try testing.expectError(error.Corrupt, decodeResidualsBytes(b3, 9, 8));

    // 前缀超过 63 个 0（无停止位）→ Corrupt
    var w4 = TestBits.init();
    defer w4.deinit();
    try w4.appendBits(0, 2);
    try w4.appendBits(0, 4);
    try w4.appendBits(0, 4); // 分区 k=0
    try w4.appendBits(0, 16); // 70 个 0，无停止位（触发前缀上限 → Corrupt）
    try w4.appendBits(0, 16);
    try w4.appendBits(0, 16);
    try w4.appendBits(0, 16);
    try w4.appendBits(0, 6);
    const b4 = try w4.toOwnedSlice();
    defer testing.allocator.free(b4);
    try testing.expectError(error.Corrupt, decodeResidualsBytes(b4, 0, 8));
}
