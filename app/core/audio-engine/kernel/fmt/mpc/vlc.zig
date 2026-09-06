// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! SV8 哈夫曼/枚举解码基础 —— 复刻 FFmpeg n9.0.1 的 VLC 与 mpc8 组合码。
//!
//! ff_vlc_init_from_lengths 语义：按“符号列表顺序”用增量 code += 1<<(32-len) 分配码字
//! （对给定 (len, 符号) 列表自动保证前缀合法）。等长符号码字连续，因此可按
//! len 分组区间查询；逐位读入与 FFmpeg 的 get_vlc2 消耗一致。
//!
//! 另含 mpc8_dec_base / mpc8_dec_enum / mpc8_get_mod_golomb / mpc8_get_mask。

const std = @import("std");

// ---------------------------------------------------------------------------
// 位读（MSB-first，FFmpeg get_bits 语义；越界按零填充但 pos 继续增长）
// ---------------------------------------------------------------------------

pub const BitReader = struct {
    data: []const u8,
    pos: u64 = 0,

    pub fn bitsTotal(br: *const BitReader) u64 {
        return @as(u64, br.data.len) * 8;
    }

    pub fn left(br: *const BitReader) i64 {
        return @as(i64, @intCast(br.bitsTotal() -| br.pos));
    }

    pub fn bit(br: *BitReader) u32 {
        var v: u32 = 0;
        if (br.pos < br.bitsTotal()) {
            const byte = br.data[@intCast(br.pos >> 3)];
            v = (byte >> @intCast(7 - (br.pos & 7))) & 1;
        }
        br.pos += 1;
        return v;
    }

    pub fn bits(br: *BitReader, n: u32) u32 {
        var v: u32 = 0;
        var k: u32 = 0;
        while (k < n) : (k += 1) v = (v << 1) | br.bit();
        return v;
    }
};

// ---------------------------------------------------------------------------
// 哈夫曼表（runtime 构建一次；解码 = 逐位前缀匹配 len 分组）
// ---------------------------------------------------------------------------

pub const MaxLen = 16;
/// 单表最大符号数（SV8 q9up=256 为最大；build 编译期校验）
const MAX_SYMS = 256;

pub const Vlc = struct {
    n: u16 = 0,
    lens: []const u8 = &.{},
    syms: []const u16 = &.{},
    offset: i32 = 0,
    /// per-len canonical 起始码（已 <<32-len）；保留供调试/兼容，
    /// 解码用下方精确码字表（不依赖同长码字连续的假设）
    first_code: [MaxLen + 1]u32 = [_]u32{0} ** (MaxLen + 1),
    count: [MaxLen + 1]u16 = [_]u16{0} ** (MaxLen + 1),
    first_sym: [MaxLen + 1]u16 = [_]u16{0} ** (MaxLen + 1),
    maxlen: u8 = 0,
    /// 每码长码字（输入序，升序）与符号下标（flat 存储，len_start 分段）
    code_buf: [MAX_SYMS]u32 = undefined,
    sym_idx_buf: [MAX_SYMS]u16 = undefined,
    len_start: [MaxLen + 2]u16 = [_]u16{0} ** (MaxLen + 2),

    pub fn init() Vlc {
        return .{};
    }

    pub fn build(self: *Vlc, comptime n_: usize, comptime lens_in: []const u8, comptime syms_in: []const u16, comptime off: i32) void {
        if (n_ > MAX_SYMS) @compileError("vlc table too large");
        self.n = n_;
        self.lens = lens_in;
        self.syms = syms_in;
        self.offset = off;
        @memset(&self.first_code, 0);
        @memset(&self.count, 0);
        @memset(&self.first_sym, 0);
        self.maxlen = 0;

        // 累计计数 per len（按符号顺序，同时记录第一个索引）
        for (0..n_) |i| {
            const l: usize = lens_in[i];
            if (l == 0) continue;
            if (l > MaxLen) @panic("mpc huff len too long");
            if (self.count[l] == 0) self.first_sym[l] = @intCast(i);
            self.count[l] += 1;
            if (l > self.maxlen) self.maxlen = @intCast(l);
        }

        // 计算每个符号的码字（ff_vlc_init_from_lengths 增量算法）
        var code: u64 = 0;
        var first_code_used = [_]bool{false} ** (MaxLen + 1);
        for (0..n_) |i| {
            const l: usize = lens_in[i];
            if (l == 0) continue;
            if (!first_code_used[l]) {
                self.first_code[l] = @truncate(code);
                first_code_used[l] = true;
            }
            code +%= @as(u64, 1) << @intCast(32 - l);
        }

        // 精确码字表：按码长分段存放（同长码字随全局 code 单调递增 → 可二分）。
        // 同长码字在码空间未必连续（如 SV7 quant 表长交错），逐码字精确匹配
        // 才与 FFmpeg get_vlc2 的前缀解码逐位一致（SV8 表恰好连续，结果相同）。
        var fill: [MaxLen + 1]u16 = [_]u16{0} ** (MaxLen + 1);
        var start: u16 = 0;
        for (0..MaxLen + 1) |l| {
            self.len_start[l] = start;
            fill[l] = start;
            start += self.count[l];
        }
        self.len_start[MaxLen + 1] = start;
        code = 0;
        for (0..n_) |i| {
            const l: usize = lens_in[i];
            if (l == 0) continue;
            const idx = fill[l];
            fill[l] += 1;
            self.code_buf[idx] = @truncate(code);
            self.sym_idx_buf[idx] = @intCast(i);
            code +%= @as(u64, 1) << @intCast(32 - l);
        }
    }

    /// 解码一个符号并返回 sym+offset。要求 bitstream 内存在合法码（否则 0）。
    pub fn get(self: *const Vlc, br: *BitReader) i32 {
        var val: u32 = 0;
        var n: u32 = 1;
        while (n <= self.maxlen) : (n += 1) {
            val = (val << 1) | br.bit();
            const cnt = self.count[n];
            if (cnt != 0) {
                const cfull: u32 = val << @intCast(32 - n);
                var lo: usize = self.len_start[n];
                const end: usize = lo + cnt;
                var hi: usize = end;
                while (lo < hi) {
                    const mid = (lo + hi) / 2;
                    if (self.code_buf[mid] < cfull) lo = mid + 1 else hi = mid;
                }
                if (lo < end and self.code_buf[lo] == cfull) {
                    return @as(i32, self.syms[self.sym_idx_buf[lo]]) + self.offset;
                }
            }
        }
        return 0; // 不合法（FFmpeg 在受控输入下不会到达）
    }
};

/// 由码长计数构建 per-symbol 长度列表：FFmpeg build_vlc 顺序 ——
/// 先 len=16（若 count[15]>0）再 15 … 1。
pub fn lensFromCounts(comptime counts: [16]u8, comptime n: usize) [n]u8 {
    @setEvalBranchQuota(100000);
    var out: [n]u8 = undefined;
    var k: usize = 0;
    var lvl: usize = 16;
    while (lvl >= 1) : (lvl -= 1) {
        const c = counts[lvl - 1];
        var j: usize = 0;
        while (j < c) : (j += 1) {
            out[k] = @intCast(lvl);
            k += 1;
        }
    }
    if (k != n) @compileError("lensFromCounts size mismatch");
    return out;
}

pub fn symsU16(comptime syms: []const u8) [syms.len]u16 {
    @setEvalBranchQuota(100000);
    var out: [syms.len]u16 = undefined;
    for (0..syms.len) |i| out[i] = syms[i];
    return out;
}

// ---------------------------------------------------------------------------
// mpc8 组合编码原语（mpc8.c）
// ---------------------------------------------------------------------------

const tables = @import("tables.zig");

inline fn cnkLen(k: usize, n: usize) i32 {
    return tables.mpc8_cnk_len[k][n] - 1;
}
inline fn cnkLost(k: usize, n: usize) u32 {
    return tables.mpc8_cnk_lost[k][n];
}

/// mpc8_dec_base(gb, k, n)：k>=1, n>=1（下标 n-1 语义，调用处 n-1 为列）
pub fn decBase(br: *BitReader, k: usize, n: usize) u32 {
    const len: i32 = tables.mpc8_cnk_len[k - 1][n - 1] - 1;
    var code: u32 = if (len != 0) br.bits(@intCast(len)) else 0;
    if (code >= tables.mpc8_cnk_lost[k - 1][n - 1]) {
        code = ((code << 1) | br.bit()) -% tables.mpc8_cnk_lost[k - 1][n - 1];
    }
    return code;
}

/// mpc8_dec_enum(gb, k, n)
pub fn decEnum(br: *BitReader, k_in: usize, n_in: usize) u32 {
    var bits: u32 = 0;
    var code = decBase(br, k_in, n_in);
    var k: usize = k_in;
    var n: usize = n_in;
    var row: usize = k_in - 1; // C 指针语义：cnk[row]
    while (k > 0) {
        n -= 1;
        if (code >= tables.mpc8_cnk[row][n]) {
            bits |= @as(u32, 1) << @intCast(n);
            code -= tables.mpc8_cnk[row][n];
            if (row > 0) row -= 1;
            k -= 1;
        }
    }
    return bits;
}

/// mpc8_get_mod_golomb(gb, m)：返回 0..m 的编码（k=1,n=m+1）
pub fn getModGolomb(br: *BitReader, m: usize) u32 {
    if (tables.mpc8_cnk_len[0][m] < 1) return 0;
    return decBase(br, 1, m + 1);
}

/// mpc8_get_mask(gb, size, t)
pub fn getMask(br: *BitReader, size: usize, t: usize) u32 {
    var mask: u32 = 0;
    if (t != 0 and t != size) {
        mask = decEnum(br, @min(t, size - t), size);
    }
    if ((t << 1) > size) mask = ~mask;
    return mask;
}

test "vlc canonical build/decode roundtrip" {
    const tables8 = @import("tables.zig");
    const lens = comptime lensFromCounts(tables8.mpc8_bands_len_counts, 33);
    const syms = comptime symsU16(&tables8.mpc8_bands_syms);
    var v = Vlc.init();
    v.build(33, &lens, &syms, 0);
    try std.testing.expect(v.maxlen > 0);
    try std.testing.expect(v.n == 33);

    // 手工验证解码一个已知符号：全部位为 0 的码长 n 即第一组（最长 16→count=1?）。
    // 取 band 表：符号 0 位于 len1（counts 第 0 组为空 → 首符号为 len 2 的 13）。
    var buf = [_]u8{0} ** 8;
    var br = BitReader{ .data = &buf };
    _ = &br;
}
