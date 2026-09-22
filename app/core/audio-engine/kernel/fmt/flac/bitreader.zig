// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! 位级读取（FLAC 音频帧 MSB-first 位流）
//!
//! 设计要点（FL-1：u64 位缓存 + peek 批量 refill + 懒 CRC + 帧末 drain）：
//!   - 基于 `io.Reader` 的 MSB-first 位读取（FLAC 位流约定），
//!     对应 FFmpeg `GetBitContext`（许可登记见 audio-engine/THIRD-PARTY-LICENSES.md）；
//!   - **u64 位缓存**：一次可容纳 64 位，`readBits` 不再逐字节拼装；
//!   - **peek 批量 refill**：`reader.peek(win[0..16])` 预读一块（**不推进 `pos`**），
//!     字节按需 append 进 `cache`——复用 `io.Reader` 既有 16 KiB 缓冲，**零新增缓冲**；
//!   - **懒 CRC**：CRC-8/CRC-16 只在字节**载入位流顺序**时累加（`loadByte`）。位流
//!     按需最小取字节（只在 `bits_avail < n` 时补），有效帧绝不会载入下一帧字节，
//!     故预读的下一帧字节不会计入 CRC；
//!   - **帧末 drain**：把已消费字节数用 `read`（≤16B 栈 scratch）推进底层 `pos`，
//!     `reader.pos` 与消费字节一致；预读未消费字节仍留在流中（peek 不消费），
//!     不预读下一帧、错误恢复不越界；
//!   - 元数据块为字节对齐读取，无位操作，由 streaminfo.zig 直接经 io.Reader 读取——
//!     本模块仅服务音频帧。

const std = @import("std");
const Error = @import("../../error.zig").Error;
const io = @import("../../io.zig");
const crc = @import("crc.zig");

pub const BitReader = struct {
    /// 底层字节流（借用；生命周期由拥有者保证）
    reader: *io.Reader,
    /// 位缓存：低 `bits_avail` 位为未消费位，下一位在 bit `bits_avail-1`（MSB-first）
    cache: u64 = 0,
    /// 缓存中未消费位数（0..64）
    bits_avail: u7 = 0,
    /// 滚动 CRC-8（帧头校验：含 CRC-8 字节后应 == 0）
    crc8: u8 = 0,
    /// 滚动 CRC-16（整帧校验：含 CRC-16 尾部后应 == 0）
    crc16: u16 = 0,

    /// 已 append 进 cache 的字节总数（已按位流顺序计入 CRC）
    loaded: usize = 0,
    /// 已从底层 `read`（reader.pos 已前移）的字节数
    drained: usize = 0,

    /// peek 窗口：win[0] 为帧内第 `win_base` 字节（peek 不消费 pos，故需自持一块）
    win: [16]u8 = undefined,
    win_base: usize = 0,
    win_len: u8 = 0,

    pub fn init(reader: *io.Reader) BitReader {
        return .{ .reader = reader };
    }

    /// 重置滚动 CRC（每帧开头调用）
    pub fn resetCrc(self: *BitReader) void {
        self.crc8 = 0;
        self.crc16 = 0;
    }

    /// (1<<n)-1 掩码表（comptime；n∈0..64，n=64 为全 1）
    const MASKS: [65]u64 = blk: {
        var m: [65]u64 = undefined;
        for (0..64) |i| m[i] = (@as(u64, 1) << @intCast(i)) - 1;
        m[64] = ~@as(u64, 0);
        break :blk m;
    };

    /// 已消费位数（loaded*8 − 缓存中未消费位）
    inline fn consumedBits(self: *const BitReader) u64 {
        return @as(u64, self.loaded) * 8 - self.bits_avail;
    }

    inline fn consumeBits(self: *BitReader, n: u7) void {
        self.bits_avail -= n;
    }

    /// 用 `read` 把底层 `pos` 推进到 target 字节（数据已在 peek 缓冲/前瞻缓存中，无新 I/O）
    fn drainTo(self: *BitReader, target: usize) Error!void {
        while (self.drained < target) {
            var scratch: [16]u8 = undefined;
            const want: usize = @min(target - self.drained, scratch.len);
            const n = try self.reader.read(scratch[0..want]);
            if (n == 0) return error.Corrupt;
            self.drained += n;
        }
    }

    /// 加载一字节到 cache（必要时 refill peek 窗口）。EOF/截断 → false。
    /// 字节在此处（位流顺序）计入滚动 CRC（懒 CRC）。
    fn loadByte(self: *BitReader) Error!bool {
        if (self.loaded - self.win_base >= self.win_len) {
            // 窗口耗尽：先把已消费字节推进底层 pos，再 peek 新窗口
            const passed: usize = @intCast(self.consumedBits() >> 3);
            try self.drainTo(passed);
            const n = try self.reader.peek(&self.win);
            self.win_base = passed; // 新窗口起点 = 已消费字节（已 drain 到此处）
            self.win_len = @intCast(n);
        }
        const idx = self.loaded - self.win_base;
        if (idx >= self.win_len) return false; // 截断
        const b = self.win[idx];
        self.crc8 = crc.crc8Update(self.crc8, b);
        self.crc16 = crc.crc16Update(self.crc16, b);
        self.cache = (self.cache << 8) | b;
        self.bits_avail += 8;
        self.loaded += 1;
        return true;
    }

    /// 把位游标已消费的字节推进底层 `reader.pos`（帧末/错误路径调用）。
    /// 预读但未消费的字节仍留在底层流中（peek 不消费），不预读下一帧。
    pub fn drain(self: *BitReader) Error!void {
        try self.drainTo(@intCast(self.consumedBits() >> 3));
    }

    /// 读取 n 位（0..=32），MSB-first 组装为无符号整数。
    /// 流截断（不足 n 位）→ error.Corrupt。
    pub fn readBits(self: *BitReader, n: u6) Error!u32 {
        if (n == 0) return 0;
        if (n > 32) return error.Corrupt;

        if (n > self.bits_avail) {
            while (self.bits_avail < n) {
                if (!try self.loadByte()) return error.Corrupt;
            }
        }
        self.bits_avail -= n;
        const sh: u6 = @intCast(self.bits_avail); // 消费后 ≤ 63
        return @intCast((self.cache >> sh) & MASKS[n]);
    }

    /// 读取 1 位（Huffman / unary 高频路径）
    pub fn readBit(self: *BitReader) Error!u1 {
        if (self.bits_avail == 0) {
            if (!try self.loadByte()) return error.Corrupt;
        }
        self.bits_avail -= 1;
        const sh: u6 = @intCast(self.bits_avail); // 消费后 ≤ 63
        return @intCast((self.cache >> sh) & 1);
    }

    /// 读取 n 位（1..=32）并符号扩展为 i32（warm-up / LPC 系数用）
    pub fn readBitsSigned(self: *BitReader, n: u6) Error!i32 {
        if (n == 0) return 0;
        const v = try self.readBits(n);
        const shift: u5 = @intCast(32 - n); // 1..=32 → 0..=31
        return @as(i32, @bitCast(v << shift)) >> shift;
    }

    /// 读取 n 位（1..=64）并符号扩展为 i64（33 位子帧样本用）。
    /// n ≤ 32 复用 32 位路径，避免位组合冗余。
    pub fn readBitsSigned64(self: *BitReader, n: u8) Error!i64 {
        if (n == 0) return 0;
        if (n <= 32) return @as(i64, try self.readBitsSigned(@intCast(n)));
        // 高 n-32 位 + 低 32 位拼接后统一符号扩展
        const hi: u32 = try self.readBits(@intCast(n - 32));
        const lo: u32 = try self.readBits(32);
        const v: u64 = (@as(u64, hi) << 32) | lo;
        const shift: u6 = @intCast(@as(u8, 64) - n); // 33..=64 → 31..=0
        return @as(i64, @bitCast(v << shift)) >> shift;
    }

    /// unary 编码：逐位读取直到出现 stop 位，返回 stop 之前的位数。
    /// 与 FFmpeg `get_unary` 语义一致：max 位内未遇 stop 时返回 max，
    /// 是否非法由调用方按上下文校验（wasted bits ≤ 30 等）。
    pub fn readUnary(self: *BitReader, stop: u1, max: u8) Error!u8 {
        var count: u8 = 0;
        while (count < max) : (count += 1) {
            if (try self.readBit() == stop) break;
        }
        return count;
    }

    /// 批量数一元前缀（stop=1）：在 **u64 位缓存**内一次数出前导零，缓存不足时补字节
    /// （懒 CRC：未消费字节不计）。返回首个 1 之前的 0 个数；超过 `max` 时返回 >max 的
    /// 计数（由调用方判 Corrupt）。Rice 残差热路径专用。
    pub fn readUnary1(self: *BitReader, max: u32) Error!u32 {
        var count: u32 = 0;
        while (true) {
            if (self.bits_avail == 0) {
                if (!try self.loadByte()) return error.Corrupt;
            }
            const avail: u7 = self.bits_avail;
            const bits: u64 = self.cache & MASKS[avail];
            if (bits == 0) {
                count +%= @intCast(avail);
                self.bits_avail = 0;
                if (count > max) return count;
                continue;
            }
            const hb: u8 = @intCast(63 - @as(u32, @clz(bits))); // 首个被读到的 1（最高置位）
            count += @as(u32, @intCast(avail)) - 1 - hb;
            self.bits_avail = @intCast(hb); // 消费 0…0 + 停止位，余下 hb 位
            return count;
        }
    }

    /// FLAC 帧号 / 样本号 UTF-8 变长整数（RFC 3629）。
    /// 非法首字节（0xFE/0xFF 开头）或非法续字节 → error.Corrupt。
    pub fn readUtf8(self: *BitReader) Error!u64 {
        const first = try self.readBits(8);
        var value: u64 = undefined;
        var nbytes: u8 = undefined;
        if (first & 0x80 == 0) {
            value = first;
            nbytes = 1;
        } else if (first & 0xE0 == 0xC0) {
            value = first & 0x1F;
            nbytes = 2;
        } else if (first & 0xF0 == 0xE0) {
            value = first & 0x0F;
            nbytes = 3;
        } else if (first & 0xF8 == 0xF0) {
            value = first & 0x07;
            nbytes = 4;
        } else if (first & 0xFC == 0xF8) {
            value = first & 0x03;
            nbytes = 5;
        } else if (first & 0xFE == 0xFC) {
            value = first & 0x01;
            nbytes = 6;
        } else {
            return error.Corrupt;
        }
        for (0..nbytes - 1) |_| {
            const b = try self.readBits(8);
            if (b & 0xC0 != 0x80) return error.Corrupt;
            value = (value << 6) | (b & 0x3F);
        }
        return value;
    }

    /// 丢弃缓存中不足一个字节的位，对齐到下一字节边界。
    /// 这些位属于当前字节（该字节载入时已计入 CRC），只把游标补到字节边界。
    pub fn alignToByte(self: *BitReader) void {
        self.bits_avail -= self.bits_avail & 7;
    }

    /// 剩余可读位数估算（基于 reader.size 与已消费字节数，含缓存位）。
    /// 供帧循环开头的"是否还剩完整帧"检查。
    pub fn remainingBits(self: *BitReader) Error!u64 {
        const total = try self.reader.size();
        // reader.pos 在帧内只在 drain 时前移：还原帧起点 + 已消费字节 = 逻辑位游标位置
        const consumed_bytes: u64 = self.consumedBits() >> 3;
        const pos_effective = self.reader.pos - self.drained + consumed_bytes;
        return (total -| pos_effective) * 8 + (self.bits_avail & 7);
    }
};

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "bitreader: MSB-first 位序 + 跨字节读取" {
    // 0xB1 = 0b10110001, 0x6C = 0b01101100
    var r = io.Reader.openMem(&.{ 0xB1, 0x6C });
    var br = BitReader.init(&r);
    try testing.expectEqual(@as(u32, 0b101), try br.readBits(3));
    try testing.expectEqual(@as(u32, 0b10001), try br.readBits(5));
    try testing.expectEqual(@as(u32, 0b01101100), try br.readBits(8));
    try testing.expectError(error.Corrupt, br.readBit()); // 越界 → Corrupt
}

test "bitreader: readBitsSigned 符号扩展" {
    // 0x87 = 0b1000 0111
    var r = io.Reader.openMem(&.{0x87});
    var br = BitReader.init(&r);
    try testing.expectEqual(@as(i32, -8), try br.readBitsSigned(4)); // 0b1000
    try testing.expectEqual(@as(i32, 7), try br.readBitsSigned(4)); // 0b0111
    // 全 32 位：0xFFFFFFFF → -1
    var r32 = io.Reader.openMem(&.{ 0xFF, 0xFF, 0xFF, 0xFF });
    var br32 = BitReader.init(&r32);
    try testing.expectEqual(@as(i32, -1), try br32.readBitsSigned(32));
}

test "bitreader: readBitsSigned64 33/64 位符号扩展" {
    // 33 位：0x1_0000_0000 → 最高位为 1 → -4294967296
    var r1 = io.Reader.openMem(&.{ 0x80, 0x00, 0x00, 0x00, 0x00 });
    var br1 = BitReader.init(&r1);
    try testing.expectEqual(@as(i64, -4294967296), try br1.readBitsSigned64(33));
    // 33 位：0x0_FFFF_FFFF → 2147483647 上界内
    var r2 = io.Reader.openMem(&.{ 0x7F, 0xFF, 0xFF, 0xFF, 0xFF });
    var br2 = BitReader.init(&r2);
    try testing.expectEqual(@as(i64, 4294967295), try br2.readBitsSigned64(33));
    // 64 位：全 1 → -1
    var r3 = io.Reader.openMem(&.{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF });
    var br3 = BitReader.init(&r3);
    try testing.expectEqual(@as(i64, -1), try br3.readBitsSigned64(64));
    // ≤32 位路径等价于 readBitsSigned
    var r4 = io.Reader.openMem(&.{0xA5});
    var br4 = BitReader.init(&r4);
    try testing.expectEqual(@as(i64, -91), try br4.readBitsSigned64(8)); // 0xA5
}

test "bitreader: readUnary 语义（stop 前的位数）" {
    // 0x2C = 0b0010 1100
    var r = io.Reader.openMem(&.{0x2C});
    var br = BitReader.init(&r);
    try testing.expectEqual(@as(u8, 2), try br.readUnary(1, 8)); // 00 1 → 2
    try testing.expectEqual(@as(u8, 1), try br.readUnary(1, 8)); // 0 1 → 1
    try testing.expectEqual(@as(u8, 0), try br.readUnary(1, 8)); // 1 → 0
    // 全 0 流：max 内未遇 stop → 返回 max
    var r0 = io.Reader.openMem(&.{0x00});
    var br0 = BitReader.init(&r0);
    try testing.expectEqual(@as(u8, 5), try br0.readUnary(1, 5));
}

test "bitreader: readUnary1 跨字节长前缀（u64 缓存）" {
    // 0x00 0x00 0x00 0x01 = 23 个 0 后 1，再 8 个 0
    var r = io.Reader.openMem(&.{ 0x00, 0x00, 0x01, 0x00 });
    var br = BitReader.init(&r);
    try testing.expectEqual(@as(u32, 23), try br.readUnary1(63));
    // 停位后剩 8 位，读满后 EOF
    try testing.expectEqual(@as(u32, 0), try br.readBit());
    try testing.expectEqual(@as(u32, 0), try br.readBits(7));
    try testing.expectError(error.Corrupt, br.readBit());
}

test "bitreader: readUtf8 各长度边界" {
    // 1 字节：0x7F
    try expectUtf8(&.{0x7F}, 0x7F);
    // 2 字节：0x80 → C2 80；0x7FF → DF BF
    try expectUtf8(&.{ 0xC2, 0x80 }, 0x80);
    try expectUtf8(&.{ 0xDF, 0xBF }, 0x7FF);
    // 3 字节：0xFFFF → EF BF BF
    try expectUtf8(&.{ 0xEF, 0xBF, 0xBF }, 0xFFFF);
    // 4 字节：0x10000 → F0 90 80 80
    try expectUtf8(&.{ 0xF0, 0x90, 0x80, 0x80 }, 0x10000);
    // 5 字节：0x200000 → F8 88 80 80 80
    try expectUtf8(&.{ 0xF8, 0x88, 0x80, 0x80, 0x80 }, 0x200000);
    // 6 字节：0x4000000 → FC 84 80 80 80 80
    try expectUtf8(&.{ 0xFC, 0x84, 0x80, 0x80, 0x80, 0x80 }, 0x4000000);
}

test "bitreader: readUtf8 非法输入 → Corrupt" {
    // 0xFF 开头非法
    var r1 = io.Reader.openMem(&.{ 0xFF, 0x80 });
    var br1 = BitReader.init(&r1);
    try testing.expectError(error.Corrupt, br1.readUtf8());
    // 续字节非 10xxxxxx
    var r2 = io.Reader.openMem(&.{ 0xC2, 0x00 });
    var br2 = BitReader.init(&r2);
    try testing.expectError(error.Corrupt, br2.readUtf8());
    // 截断（声明 2 字节但只有 1 字节）
    var r3 = io.Reader.openMem(&.{0xC2});
    var br3 = BitReader.init(&r3);
    try testing.expectError(error.Corrupt, br3.readUtf8());
}

test "bitreader: alignToByte 丢弃尾部残余位" {
    // 0xF5 = 0b1111 0101
    var r = io.Reader.openMem(&.{ 0xF5, 0xA5 });
    var br = BitReader.init(&r);
    try testing.expectEqual(@as(u32, 0b111), try br.readBits(3));
    br.alignToByte();
    try testing.expectEqual(@as(u32, 0xA5), try br.readBits(8));
    try br.drain();
    try testing.expectEqual(@as(u64, 2), r.pos);
}

test "bitreader: 帧头 CRC-8 即时校验为 0" {
    const hdr = "hdr";
    var data: [hdr.len + 1]u8 = undefined;
    @memcpy(data[0..hdr.len], hdr);
    data[hdr.len] = crc.crc8(hdr);
    var r = io.Reader.openMem(&data);
    var br = BitReader.init(&r);
    // 不整齐的位宽读完全部 4 字节（7+9+11+5 = 32 位）
    _ = try br.readBits(7);
    _ = try br.readBits(9);
    _ = try br.readBits(11);
    _ = try br.readBits(5);
    try testing.expectEqual(@as(u8, 0), br.crc8);
}

test "bitreader: 整帧 CRC-16 为 0 且不预读下一帧" {
    const body = "frame-body-with-subframes-and-padding";
    var tail: [3]u8 = .{ 0x11, 0x22, 0x33 }; // 下一帧开头（不应被读入）
    var data: [body.len + 2 + tail.len]u8 = undefined;
    @memcpy(data[0..body.len], body);
    std.mem.writeInt(u16, data[body.len..][0..2], crc.crc16(body), .big);
    @memcpy(data[body.len + 2 ..], &tail);

    var r = io.Reader.openMem(&data);
    var br = BitReader.init(&r);
    // 混合位宽读 body，尾部留 3 位模拟 subframe 尾的 padding
    var consumed: usize = 0;
    const total_bits: usize = body.len * 8;
    while (total_bits - consumed > 3) {
        const take: u6 = @intCast(@min(@as(usize, 7), total_bits - consumed - 3));
        _ = try br.readBits(take);
        consumed += take;
    }
    br.alignToByte(); // 丢弃 3 位 padding
    _ = try br.readBits(16); // CRC-16
    try testing.expectEqual(@as(u16, 0), br.crc16);
    try br.drain(); // 帧末把消费字节推进 pos
    // 关键：恰好读入帧内字节，未预读下一帧
    try testing.expectEqual(@as(usize, body.len + 2), r.pos);
}

test "bitreader: 懒 CRC 不把预读的下一帧字节计入" {
    // 首帧：4 字节 body + CRC-16；随后是下一帧数据
    const body = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    var data: [body.len + 2 + 8]u8 = undefined;
    @memcpy(data[0..body.len], &body);
    std.mem.writeInt(u16, data[body.len..][0..2], crc.crc16(&body), .big);
    @memset(data[body.len + 2 ..], 0xAA); // 下一帧（若被计入 CRC 将非 0）
    var r = io.Reader.openMem(&data);
    var br = BitReader.init(&r);
    _ = try br.readBits(32); // body
    br.alignToByte();
    _ = try br.readBits(16); // CRC-16
    try testing.expectEqual(@as(u16, 0), br.crc16);
    try br.drain();
    try testing.expectEqual(@as(usize, body.len + 2), r.pos);
}

/// 辅助：以整字节喂入并断言 readUtf8 结果
fn expectUtf8(bytes: []const u8, expected: u64) !void {
    var r = io.Reader.openMem(bytes);
    var br = BitReader.init(&r);
    try testing.expectEqual(expected, try br.readUtf8());
}
