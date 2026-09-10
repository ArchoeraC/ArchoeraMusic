// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! FLAC 子帧解码（constant / verbatim / fixed 0-4 / LPC + wasted bits）
//!
//! 参考重构对照 flacdec.c decode_subframe / *_fixed* / *_lpc* /
//! lpc_analyze_remodulate 与 flacdsp.c flac_lpc_*_c / flac_wasted_*_c。
//!
//! 位排布（decode_subframe）：
//!   padding(1)=0 + type(6) + wasted_flag(1)
//!   （wasted_flag=1 时）unary：wasted = 1 + 前缀 0 个数；
//!   type 分派：0 constant / 1 verbatim / 8+order fixed / 32+(order-1) lpc，
//!   其余非法 → error.Corrupt。
//!
//! 有效位宽 = 帧 bps（含侧声道 +1 调整，调用方算好）- wasted；
//! 校验 wasted < 有效位宽（FFmpeg 以 show_bits 探测保证样本位数 ≥ 1）。
//!
//! 重建语义：
//!   - fixed：warm-up 读 order 个有符号样本，残差后按 binomial 系数递推
//!     （DECODER_SUBFRAME_FIXED_WIDE；与窄式 int32 递推对有效流 bit-exact）；
//!   - lpc：warm-up + coeff_prec(4)+1（==16 非法）+ qlevel(5 位有符号，负非法)
//!     + 系数（逆序）→ i64 累加重建（= lpc32 语义）；
//!     FFmpeg 在走 lpc32 且流位深 ≤ 16 时附加 lpc_analyze_remodulate，
//!     复刻编码器 int32 环绕语义——本实现忠实复现；
//!   - wasted：解码后整体左移 wasted 位。
//!
//! 33 位路径（32 位流 + mid/side 侧声道，wasted 扣除后仍 33 位）：
//!   decodeSubframeWide 输出 []i64；wasted>0 时内容按 33-wasted 位解码进
//!   i32 临时区再左移（对应 flac_wasted_33_c）。

const std = @import("std");
const Error = @import("../../error.zig").Error;
const bitreader = @import("bitreader.zig");
const residual = @import("residual.zig");

const BitReader = bitreader.BitReader;

/// 子帧头（padding/type/wasted 已消费）
const Header = struct {
    type_bits: u6,
    wasted: u8,
};

/// 解析子帧头：padding(1)=0 + type(6) + wasted_flag(1) [+ unary]
fn parseHeader(br: *BitReader) Error!Header {
    if (try br.readBit() != 0) return error.Corrupt;
    const type_bits: u6 = @intCast(try br.readBits(6));
    var wasted: u8 = 0;
    if (try br.readBit() == 1) {
        // FFmpeg get_unary 上限为剩余位数；33 位深下 wasted 实际 ≤ 32
        wasted = 1 + try br.readUnary(1, 32);
    }
    return .{ .type_bits = type_bits, .wasted = wasted };
}

/// 解码单子帧（有效位宽 ≤ 32 路径），写入 out[0..blocksize)。
/// `bps` 为帧级位深 + 侧声道调整后的值（wasted 扣除前）；
/// `stream_bps` 为 STREAMINFO 位深（lpc_analyze_remodulate 判定用）。
pub fn decodeSubframe(
    br: *BitReader,
    out: []i32,
    blocksize: usize,
    bps: u8,
    stream_bps: u8,
) Error!void {
    const hdr = try parseHeader(br);
    if (hdr.wasted >= bps) return error.Corrupt;
    const bps2: u6 = @intCast(bps - hdr.wasted);

    try decodeContent(br, out, blocksize, bps2, stream_bps, hdr.type_bits);

    // wasted 移位：正常路径下 wasted+bps ≤ 32 ≠ 33 → 恒走 wasted32
    if (hdr.wasted > 0) {
        const shift: u5 = @intCast(hdr.wasted);
        for (out[0..blocksize]) |*s| s.* = @bitCast(@as(u32, @bitCast(s.*)) << shift);
    }
}

/// 33 位路径：输出 []i64（wasted 扣除前 bps 恒为 33）。
/// 需要 allocator 提供 blocksize 大小的 i32 临时残差/内容缓冲。
pub fn decodeSubframeWide(
    br: *BitReader,
    allocator: std.mem.Allocator,
    out: []i64,
    blocksize: usize,
) Error!void {
    const hdr = try parseHeader(br);
    if (hdr.wasted >= 33) return error.Corrupt;
    const bps2: u6 = @intCast(33 - hdr.wasted);

    if (bps2 == 33) {
        // 内容直接按 33 位解码进 i64
        try decodeContentWide(br, allocator, out, blocksize, hdr.type_bits);
        return;
    }

    // wasted>0：内容按 bps2 位解码进 i32 临时区，再左移进 i64
    const tmp = try allocator.alloc(i32, blocksize);
    defer allocator.free(tmp);
    try decodeContent(br, tmp, blocksize, bps2, 32, hdr.type_bits);
    const shift: u6 = @intCast(hdr.wasted);
    for (0..blocksize) |i| {
        // flac_wasted_33_c：(uint64)decoded[i] << wasted（符号扩展）
        const t: u64 = @bitCast(@as(i64, tmp[i]));
        out[i] = @as(i64, @bitCast(t << shift));
    }
}

/// 子帧内容分派（不含 wasted 移位；bps 为已扣除 wasted 的有效位宽）
fn decodeContent(
    br: *BitReader,
    out: []i32,
    blocksize: usize,
    bps: u6,
    stream_bps: u8,
    type_bits: u6,
) Error!void {
    if (type_bits == 0) {
        // constant：单个样本填充整帧
        const v = try br.readBitsSigned(bps);
        for (out[0..blocksize]) |*s| s.* = v;
    } else if (type_bits == 1) {
        // verbatim：逐样本原始值
        for (out[0..blocksize]) |*s| s.* = try br.readBitsSigned(bps);
    } else if (type_bits >= 8 and type_bits <= 12) {
        try decodeFixed(br, out, blocksize, type_bits - 8, bps);
    } else if (type_bits >= 32) {
        try decodeLpc(br, out, blocksize, type_bits - 31, bps, stream_bps);
    } else {
        return error.Corrupt;
    }
}

/// fixed 预测：warm-up + 残差 + binomial 递推（DECODER_SUBFRAME_FIXED_WIDE 语义）
fn decodeFixed(br: *BitReader, out: []i32, blocksize: usize, order: usize, bps: u6) Error!void {
    // warm-up samples
    for (out[0..order]) |*s| s.* = try br.readBitsSigned(bps);
    try residual.decodeResiduals(br, out, order, blocksize);

    var i: usize = order;
    while (i < blocksize) : (i += 1) {
        var sum: i64 = @as(i64, out[i]);
        switch (order) {
            0 => {},
            1 => sum +|= @as(i64, out[i - 1]),
            2 => sum +|= 2 * @as(i64, out[i - 1]) - @as(i64, out[i - 2]),
            3 => sum +|= 3 * @as(i64, out[i - 1]) - 3 * @as(i64, out[i - 2]) + @as(i64, out[i - 3]),
            4 => sum +|= 4 * @as(i64, out[i - 1]) - 6 * @as(i64, out[i - 2]) + 4 * @as(i64, out[i - 3]) - @as(i64, out[i - 4]),
            else => return error.Corrupt,
        }
        out[i] = @truncate(sum);
    }
}

/// LPC 预测：warm-up + 系数 + 残差 + i64 累加重建（= flac_lpc_32_c 语义）
fn decodeLpc(
    br: *BitReader,
    out: []i32,
    blocksize: usize,
    order: usize,
    bps: u6,
    stream_bps: u8,
) Error!void {
    // warm-up samples
    for (out[0..order]) |*s| s.* = try br.readBitsSigned(bps);

    const coeff_prec: u8 = @intCast((try br.readBits(4)) + 1); // 1..16
    if (coeff_prec == 16) return error.Corrupt;

    const qlevel_signed = try br.readBitsSigned(5);
    if (qlevel_signed < 0) return error.Corrupt;
    const qlevel: u6 = @intCast(qlevel_signed);

    var coeffs: [32]i32 = undefined;
    for (0..order) |i| coeffs[order - 1 - i] = try br.readBitsSigned(@intCast(coeff_prec));

    try residual.decodeResiduals(br, out, order, blocksize);

    // i64 累加重建（与 lpc32 一致；对有效流与 lpc16 结果等价）。
    // A 档微优化：滑动窗口切片 zip 遍历（免每轮下标算术）、i32 环绕直接 +%=。
    var i: usize = order;
    while (i < blocksize) : (i += 1) {
        const hist = out[i - order ..][0..order];
        var sum: i64 = 0;
        for (coeffs[0..order], hist) |c, smp| sum += @as(i64, c) * @as(i64, smp);
        out[i] +%= @intCast(sum >> qlevel);
    }

    // FFmpeg：走 lpc32（而非 lpc16）且流位深 ≤ 16 时重调制，
    // 复刻编码器 int32 环绕（lpc_analyze_remodulate）。
    const use_lpc32 = !(bps <= 16 and bps + coeff_prec + floorLog2(order) <= 32);
    if (use_lpc32 and stream_bps <= 16) {
        lpcAnalyzeRemodulate(out, &coeffs, order, qlevel, blocksize, bps);
    }
}

/// floor(log2(order))，order ≥ 1
fn floorLog2(x: usize) u8 {
    var n: u8 = 0;
    var v = x;
    while (v > 1) : (v >>= 1) n += 1;
    return n;
}

/// lpc_analyze_remodulate：sigma 判定是否全样本在有效位深内；
/// 否则反向去除预测、再按 int32 环绕语义正向加回（复刻编码器 lpc16）。
fn lpcAnalyzeRemodulate(
    decoded: []i32,
    coeffs: []const i32,
    order: usize,
    qlevel: u6,
    len: usize,
    bps: u8,
) void {
    const ebps: u32 = @as(u32, 1) << @intCast(bps - 1);
    var sigma: u32 = 0;
    for (decoded[order..len]) |d| sigma |= @as(u32, @bitCast(d)) +% ebps;
    if (sigma < (@as(u32, 1) << @intCast(bps))) return;

    // 反向：去除预测（i64 精确）
    var i: usize = len;
    while (i > order) {
        i -= 1;
        var p: i64 = 0;
        for (0..order) |j| p += @as(i64, coeffs[j]) * @as(i64, decoded[i - order + j]);
        const pred: i32 = @intCast(p >> qlevel);
        decoded[i] = @bitCast(@as(u32, @bitCast(decoded[i])) -% @as(u32, @bitCast(pred)));
    }
    // 正向：加回预测（int32 环绕，模拟编码器）
    var k: usize = order;
    while (k < len) : (k += 1) {
        var p: i32 = 0;
        for (0..order) |j| {
            const c: u32 = @bitCast(coeffs[j]);
            const d: u32 = @bitCast(decoded[k + j]);
            p +%= @as(i32, @bitCast(c *% d));
        }
        const pred: i32 = p >> @as(u5, @intCast(qlevel));
        decoded[k + order] = @bitCast(@as(u32, @bitCast(decoded[k + order])) +% @as(u32, @bitCast(pred)));
    }
}

/// 33 位内容分派（bps2 == 33）
fn decodeContentWide(
    br: *BitReader,
    allocator: std.mem.Allocator,
    out: []i64,
    blocksize: usize,
    type_bits: u6,
) Error!void {
    if (type_bits == 0) {
        const v = try br.readBitsSigned64(33);
        for (out[0..blocksize]) |*s| s.* = v;
    } else if (type_bits == 1) {
        for (out[0..blocksize]) |*s| s.* = try br.readBitsSigned64(33);
    } else if (type_bits >= 8 and type_bits <= 12) {
        try decodeFixedWide(br, allocator, out, blocksize, type_bits - 8);
    } else if (type_bits >= 32) {
        try decodeLpcWide(br, allocator, out, blocksize, type_bits - 31);
    } else {
        return error.Corrupt;
    }
}

/// 33 位 fixed：warm-up 33 位，残差进 i32 临时区，重建进 i64
fn decodeFixedWide(
    br: *BitReader,
    allocator: std.mem.Allocator,
    out: []i64,
    blocksize: usize,
    order: usize,
) Error!void {
    for (out[0..order]) |*s| s.* = try br.readBitsSigned64(33);

    const rbuf = try allocator.alloc(i32, blocksize);
    defer allocator.free(rbuf);
    try residual.decodeResiduals(br, rbuf, order, blocksize);

    var i: usize = order;
    while (i < blocksize) : (i += 1) {
        var sum: i64 = @as(i64, rbuf[i]);
        switch (order) {
            0 => {},
            1 => sum +|= @as(i64, out[i - 1]),
            2 => sum +|= 2 * @as(i64, out[i - 1]) - @as(i64, out[i - 2]),
            3 => sum +|= 3 * @as(i64, out[i - 1]) - 3 * @as(i64, out[i - 2]) + @as(i64, out[i - 3]),
            4 => sum +|= 4 * @as(i64, out[i - 1]) - 6 * @as(i64, out[i - 2]) + 4 * @as(i64, out[i - 3]) - @as(i64, out[i - 4]),
            else => return error.Corrupt,
        }
        out[i] = sum;
    }
}

/// 33 位 lpc：warm-up 33 位，残差进 i32 临时区，lpc33 重建
fn decodeLpcWide(
    br: *BitReader,
    allocator: std.mem.Allocator,
    out: []i64,
    blocksize: usize,
    order: usize,
) Error!void {
    for (out[0..order]) |*s| s.* = try br.readBitsSigned64(33);

    const coeff_prec: u8 = @intCast((try br.readBits(4)) + 1); // 1..16
    if (coeff_prec == 16) return error.Corrupt;

    const qlevel_signed = try br.readBitsSigned(5);
    if (qlevel_signed < 0) return error.Corrupt;
    const qlevel: u6 = @intCast(qlevel_signed);

    var coeffs: [32]i32 = undefined;
    for (0..order) |i| coeffs[order - 1 - i] = try br.readBitsSigned(@intCast(coeff_prec));

    const rbuf = try allocator.alloc(i32, blocksize);
    defer allocator.free(rbuf);
    try residual.decodeResiduals(br, rbuf, order, blocksize);

    // flac_lpc_33_c：sum += coeffs[j] * (uint64)decoded[j]；环绕乘法模拟无符号语义。
    // A 档微优化：滑动窗口切片 zip 遍历（免每轮下标算术）。
    var i: usize = order;
    while (i < blocksize) : (i += 1) {
        const hist = out[i - order ..][0..order];
        var sum: i64 = 0;
        for (coeffs[0..order], hist) |c, smp| sum +%= c *% smp;
        // (uint64)residual[i] + (uint64)(sum >> qlevel)，u64 环绕，按位存回 i64
        const ru: u64 = @bitCast(@as(i64, rbuf[i]));
        const pred: u64 = @bitCast(sum >> qlevel);
        out[i] = @as(i64, @bitCast(ru +% pred));
    }
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;
const io = @import("../../io.zig");

/// 测试用 MSB-first 位写入器（复用 residual 的编码辅助）
const TestBits = residual.TestBits;

fn decodeSubframeBytes(
    bytes: []const u8,
    blocksize: usize,
    bps: u8,
    stream_bps: u8,
) ![]i32 {
    var r = io.Reader.openMem(bytes);
    var br = BitReader.init(&r);
    const out = try testing.allocator.alloc(i32, blocksize);
    errdefer testing.allocator.free(out);
    try decodeSubframe(&br, out, blocksize, bps, stream_bps);
    return out;
}

fn decodeSubframeWideBytes(bytes: []const u8, blocksize: usize) ![]i64 {
    var r = io.Reader.openMem(bytes);
    var br = BitReader.init(&r);
    const out = try testing.allocator.alloc(i64, blocksize);
    errdefer testing.allocator.free(out);
    try decodeSubframeWide(&br, testing.allocator, out, blocksize);
    return out;
}

/// 写子帧头 + wasted（wasted=0 → 标志位 0；>0 → 标志位 1 + unary）
fn writeHeader(w: *TestBits, type_bits: u6, wasted: u8) !void {
    try w.appendBits(0, 1); // padding
    try w.appendBits(type_bits, 6);
    if (wasted == 0) {
        try w.appendBits(0, 1);
    } else {
        try w.appendBits(1, 1);
        try w.appendBits(0, @intCast(wasted - 1)); // wasted-1 个 0
        try w.appendBits(1, 1); // 停止位
    }
}

test "subframe: constant 单值填充" {
    var w = TestBits.init();
    defer w.deinit();
    try writeHeader(&w, 0, 0);
    try w.appendBits(0x1234, 16); // bps=16 值
    const bytes = try w.toOwnedSlice();
    defer testing.allocator.free(bytes);

    const out = try decodeSubframeBytes(bytes, 4, 16, 16);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(i32, &.{ 0x1234, 0x1234, 0x1234, 0x1234 }, out);
}

test "subframe: verbatim 逐样本" {
    var w = TestBits.init();
    defer w.deinit();
    try writeHeader(&w, 1, 0);
    for ([_]u32{ 0x0001, 0x8000, 0x7FFF, 0xFFFF }) |v| try w.appendBits(v, 16);
    const bytes = try w.toOwnedSlice();
    defer testing.allocator.free(bytes);

    const out = try decodeSubframeBytes(bytes, 4, 16, 16);
    defer testing.allocator.free(out);
    // 0x8000 → -32768；0xFFFF → -1
    try testing.expectEqualSlices(i32, &.{ 1, -32768, 32767, -1 }, out);
}

test "subframe: fixed order 1 递推" {
    // warm-up=100，残差 [1,2,3,-4] → 样本 [100,101,103,106,102]
    var w = TestBits.init();
    defer w.deinit();
    try writeHeader(&w, 9, 0); // fixed order 1
    try w.appendBits(100, 16); // warm-up
    try w.appendBits(0, 2); // method 0
    try w.appendBits(0, 4); // order 0 → 1 分区
    try w.appendBits(0, 4); // k=0
    for ([_]i32{ 1, 2, 3, -4 }) |res| try w.appendGolomb(0, res);
    const bytes = try w.toOwnedSlice();
    defer testing.allocator.free(bytes);

    const out = try decodeSubframeBytes(bytes, 5, 16, 16);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(i32, &.{ 100, 101, 103, 106, 102 }, out);
}

test "subframe: fixed order 4（bps+order 超 32 → 宽式）" {
    // bps=30, order=4 → 30+4=34 > 32 → fixed_wide；样本递推 out[i]=out[i-1]
    var w = TestBits.init();
    defer w.deinit();
    try writeHeader(&w, 12, 0); // fixed order 4
    for ([_]i32{ 1000, 2000, 3000, 4000 }) |v| try w.appendBits(@bitCast(v), 30); // warm-up
    try w.appendBits(0, 2);
    try w.appendBits(0, 4);
    try w.appendBits(0, 4); // k=0
    // 残差使递推为 out[i]=2*out[i-1]-out[i-2]（order4 需完整系数）
    for ([_]i32{ 0, 0, 0, 0, 0, 0 }) |res| try w.appendGolomb(0, res);
    const bytes = try w.toOwnedSlice();
    defer testing.allocator.free(bytes);

    const out = try decodeSubframeBytes(bytes, 10, 30, 30);
    defer testing.allocator.free(out);
    // 全 0 残差 + order4 递推 → 线性外推 1000,2000,3000,4000,5000,...
    try testing.expectEqualSlices(i32, &.{ 1000, 2000, 3000, 4000, 5000, 6000, 7000, 8000, 9000, 10000 }, out);
}

test "subframe: lpc order 1 重建" {
    // coeff=2, qlevel=1 → 预测 = (2*prev)>>1 = prev；残差 [1,2,3]
    var w = TestBits.init();
    defer w.deinit();
    try writeHeader(&w, 32, 0); // lpc order 1
    try w.appendBits(50, 16); // warm-up
    try w.appendBits(3, 4); // coeff_prec-1 = 3 → prec 4
    try w.appendBits(1, 5); // qlevel=1
    try w.appendBits(2, 4); // coeff=2（4 位有符号）
    try w.appendBits(0, 2);
    try w.appendBits(0, 4);
    try w.appendBits(0, 4); // k=0
    for ([_]i32{ 1, 2, 3 }) |res| try w.appendGolomb(0, res);
    const bytes = try w.toOwnedSlice();
    defer testing.allocator.free(bytes);

    const out = try decodeSubframeBytes(bytes, 4, 16, 16);
    defer testing.allocator.free(out);
    // out[i] = residual + (coeff*out[i-1])>>qlevel
    // 50；1 + 50 = 51；2 + 51 = 53；3 + 53 = 56
    try testing.expectEqualSlices(i32, &.{ 50, 51, 53, 56 }, out);
}

test "subframe: wasted bits 左移" {
    // bps=8, wasted=2 → 内容 6 位；值 0b001010=10 → 40
    var w = TestBits.init();
    defer w.deinit();
    try writeHeader(&w, 1, 2); // verbatim + wasted=2
    for ([_]u32{ 10, 20, 5, 15 }) |v| try w.appendBits(v, 6);
    const bytes = try w.toOwnedSlice();
    defer testing.allocator.free(bytes);

    const out = try decodeSubframeBytes(bytes, 4, 8, 8);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(i32, &.{ 40, 80, 20, 60 }, out);
}

test "subframe: 33 位 constant（wide 路径）" {
    // 33 位值 0x1_0000_0000 → -4294967296
    var w = TestBits.init();
    defer w.deinit();
    try writeHeader(&w, 0, 0);
    try w.appendBits(0x1, 1); // 符号位
    try w.appendBits(0, 16);
    try w.appendBits(0, 16);
    const bytes = try w.toOwnedSlice();
    defer testing.allocator.free(bytes);

    const out = try decodeSubframeWideBytes(bytes, 3);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(i64, &.{ -4294967296, -4294967296, -4294967296 }, out);
}

test "subframe: 33 位 fixed order 1（wide 路径）" {
    // warm-up 33 位 = 4294967295（0x7FFFFFFF + 1 位组合），残差 [1,2]
    var w = TestBits.init();
    defer w.deinit();
    try writeHeader(&w, 9, 0); // fixed order 1
    try w.appendBits(0x7FFF, 16);
    try w.appendBits(0xFFFF, 16); // 33 位：0xFFFFFFFF → 4294967295
    try w.appendBits(1, 1);
    try w.appendBits(0, 2);
    try w.appendBits(0, 4);
    try w.appendBits(0, 4); // k=0
    for ([_]i32{ 1, 2 }) |res| try w.appendGolomb(0, res);
    const bytes = try w.toOwnedSlice();
    defer testing.allocator.free(bytes);

    const out = try decodeSubframeWideBytes(bytes, 3);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(i64, &.{ 4294967295, 4294967296, 4294967298 }, out);
}

test "subframe: 非法输入 → Corrupt" {
    // padding=1
    var w1 = TestBits.init();
    defer w1.deinit();
    try w1.appendBits(1, 1);
    const b1 = try w1.toOwnedSlice();
    defer testing.allocator.free(b1);
    try testing.expectError(error.Corrupt, decodeSubframeBytes(b1, 4, 16, 16));

    // type=2（保留）→ Corrupt
    var w2 = TestBits.init();
    defer w2.deinit();
    try writeHeader(&w2, 2, 0);
    const b2 = try w2.toOwnedSlice();
    defer testing.allocator.free(b2);
    try testing.expectError(error.Corrupt, decodeSubframeBytes(b2, 4, 16, 16));

    // coeff_prec=16 → Corrupt
    var w3 = TestBits.init();
    defer w3.deinit();
    try writeHeader(&w3, 32, 0); // lpc order 1
    try w3.appendBits(0, 16); // warm-up
    try w3.appendBits(15, 4); // coeff_prec-1=15 → prec 16
    const b3 = try w3.toOwnedSlice();
    defer testing.allocator.free(b3);
    try testing.expectError(error.Corrupt, decodeSubframeBytes(b3, 4, 16, 16));

    // qlevel 负 → Corrupt
    var w4 = TestBits.init();
    defer w4.deinit();
    try writeHeader(&w4, 32, 0);
    try w4.appendBits(0, 16); // warm-up
    try w4.appendBits(3, 4); // prec 4
    try w4.appendBits(0b11111, 5); // qlevel=-1
    const b4 = try w4.toOwnedSlice();
    defer testing.allocator.free(b4);
    try testing.expectError(error.Corrupt, decodeSubframeBytes(b4, 4, 16, 16));

    // wasted ≥ bps → Corrupt（bps=8, wasted=8）
    var w5 = TestBits.init();
    defer w5.deinit();
    try writeHeader(&w5, 0, 8);
    const b5 = try w5.toOwnedSlice();
    defer testing.allocator.free(b5);
    try testing.expectError(error.Corrupt, decodeSubframeBytes(b5, 4, 8, 8));
}
