// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Ogg 容器解复用（docs/audio-kernel-zig.md §9.2）
//!
//! 自研 Zig：OggS 页解析（页头 / lacing 分段表 / 非反射 CRC-32）+ 跨页 packet
//! 重组 + granule 位置跟踪。参考重构对照 FFmpeg `libavformat/oggdec.c` 与
//! `libavformat/oggparseopus.c`（RFC 3533 + RFC 7845）；许可登记见 audio-engine/THIRD-PARTY-LICENSES.md。
//!
//! 语义要点（对齐 FFmpeg ogg 解复用）：
//!   - 页头 27 字节：`OggS` + version(1) + header_type(1) + granule(8 LE) +
//!     serial(4 LE) + page_seq(4 LE) + checksum(4 LE) + page_segments(1)；
//!   - 分段表：每段 0..255 字节；lacing < 255 结束一个 packet，255 表示续段；
//!     跨页续段由 header_type bit0（continued）标记，重组进同一 packet 缓冲；
//!   - CRC-32 多项式 0x04C11DB7（**非反射**），checksum 字段计算时置零；
//!   - granule：Opus 中 = 已解码 PCM 样本总数（含 pre-skip），末页 granule
//!     决定整轨时长（供解码器 end-trim）；每个 packet 完成时的页 granule 记录。
//!
//! 健壮性（§13.3）：所有长度字段校验 `<= 输入大小`，页/段循环有界，
//! 坏页（CRC 不匹配 / 越界）→ error.Corrupt；未遇目标序列的无关流跳过。

const std = @import("std");
const Error = @import("../error.zig").Error;
const io = @import("../io.zig");

/// Ogg 非反射 CRC-32 表（poly 0x04C11DB7，无反射 / 无预置 / 无输出异或）
pub const crc_table = blk: {
    @setEvalBranchQuota(100000);
    var t: [256]u32 = undefined;
    for (0..256) |i| {
        var c: u32 = @as(u32, @intCast(i)) << 24;
        for (0..8) |_| {
            c = if ((c & 0x8000_0000) != 0) (c << 1) ^ 0x04C1_1DB7 else c << 1;
        }
        t[i] = c;
    }
    break :blk t;
};

/// 页 CRC 逐字节更新（FFmpeg ogg.c crc_update 语义）
pub fn crcUpdate(crc: u32, byte: u8) u32 {
    return (crc << 8) ^ crc_table[((crc >> 24) ^ byte) & 0xFF];
}

pub fn crcUpdateBytes(crc: u32, bytes: []const u8) u32 {
    var c = crc;
    for (bytes) |b| c = crcUpdate(c, b);
    return c;
}

/// 页头类型位
pub const HEADER_TYPE_CONTINUED = 0x01;
pub const HEADER_TYPE_BOS = 0x02;
pub const HEADER_TYPE_EOS = 0x04;

/// 单页解析结果（payload 为页数据切片，生命周期同页缓冲）
pub const Page = struct {
    /// 页头类型
    header_type: u8,
    /// granule 位置（有符号；未完成流可为 -1）
    granule: i64,
    /// 流序列号
    serial: u32,
    /// 页序号
    page_seq: u32,
    /// 分段表
    segments: []const u8,
    /// 页 payload（分段数据）
    payload: []const u8,

    /// 页总字节数（27 + segments + payload）
    pub fn size(self: *const Page) usize {
        return 27 + self.segments.len + self.payload.len;
    }
};

/// 从页缓冲解析单页。校验魔数/版本/CRC。返回 null = 缓冲不是页起点（找同步）。
/// `page_buf` 须为完整页（从 `OggS` 起）。
pub fn parsePage(page_buf: []const u8) Error!?Page {
    if (page_buf.len < 27) return null;
    if (!std.mem.eql(u8, page_buf[0..4], "OggS")) return null;
    if (page_buf[4] != 0) return error.Corrupt; // version 必须 0
    const nsegs: usize = page_buf[26];
    if (page_buf.len < 27 + nsegs) return error.Corrupt;
    const segments = page_buf[27 .. 27 + nsegs];
    var payload_len: usize = 0;
    for (segments) |s| payload_len += s;
    if (page_buf.len < 27 + nsegs + payload_len) return error.Corrupt;
    const payload = page_buf[27 + nsegs .. 27 + nsegs + payload_len];

    // CRC 校验（checksum 字段计算时置零）
    var crc: u32 = 0;
    crc = crcUpdateBytes(crc, page_buf[0..22]); // 到 checksum 前
    crc = crcUpdateBytes(crc, &[_]u8{ 0, 0, 0, 0 }); // checksum 字段
    crc = crcUpdateBytes(crc, page_buf[26..]);
    const stored = std.mem.readInt(u32, page_buf[22..26], .little);
    if (crc != stored) return error.Corrupt;

    return .{
        .header_type = page_buf[5],
        .granule = std.mem.readInt(i64, page_buf[6..14], .little),
        .serial = std.mem.readInt(u32, page_buf[14..18], .little),
        .page_seq = std.mem.readInt(u32, page_buf[18..22], .little),
        .segments = segments,
        .payload = payload,
    };
}

/// 从 lacing 分段表重建 packets（单页内；跨页续段由 `continued` 标记合并）。
/// `emit` 每完成一个 packet 回调（data 切片 + 该 packet 完成时的 granule）。
pub fn assemblePage(
    allocator: std.mem.Allocator,
    page: *const Page,
    continued: bool,
    granule: i64,
    pkt_buf: *std.ArrayList(u8),
    ctx: anytype,
    emit: *const fn (ctx: @TypeOf(ctx), data: []const u8, granule: i64, continued: bool) void,
) Error!void {
    var payload_off: usize = 0;
    var first = true;
    for (page.segments) |lace| {
        if (lace == 255) {
            try pkt_buf.appendSlice(allocator, page.payload[payload_off .. payload_off + 255]);
            payload_off += 255;
            continue;
        }
        // lace < 255：packet 结束
        try pkt_buf.appendSlice(allocator, page.payload[payload_off .. payload_off + lace]);
        payload_off += lace;
        try emit(ctx, pkt_buf.items, granule, continued and first);
        pkt_buf.clearRetainingCapacity();
        first = false;
    }
}
/// 尾窗扫描结果：流末页 granule 与 EOS 标志（时长计算用）。
pub const TailPage = struct {
    /// 末页 granule
    granule: i64,
    /// 末页是否带 EOS 标志（false = 流未正常收尾，调用方应退 estimate）
    eos: bool,
};

/// 尾窗大小：≥ 单页上限 27+255+255×255 = 65307B，必含文件最后一个完整页
/// （对齐 FFmpeg ogg_get_length 的 MAX_PAGE_SIZE 尾窗策略）。
const TAIL_WINDOW: usize = 64 * 1024;

/// 尾窗扫描：定位流的末页 granule（open 时 O(1) 计算精确时长，替代整流预扫描）。
///   - 仅 file/memory 形态支持（callback 流不可 seek → 返回 null，调用方保持
///     原有降级路径）；
///   - 64KB 尾窗内逐 "OggS" 候选经 parsePage 校验（魔数/版本/CRC）：损坏/截断页
///     跳过 → 命中前一个完整页（调用方据 eos=false 退 estimate）；
///   - `serial`：目标流序列号（0 = 不限定，取窗口内最后一个合法页）；窗口内
///     向前扫描取**最后一个**匹配页（多路复用时取该流自己的末页）；
///   - granule < 0 的页（未完成流占位）跳过；
///   - 读位置在返回前恢复（不污染调用方后续 read/页重组）。
pub fn scanTailPage(reader: *io.Reader, serial: u32) Error!?TailPage {
    if (reader.kind != .file and reader.kind != .memory) return null;
    const save = reader.pos;
    defer reader.pos = save;
    const size = reader.size() catch return null;
    if (size < 27) return null;
    var buf: [TAIL_WINDOW]u8 = undefined;
    const read_len: usize = @intCast(@min(size, TAIL_WINDOW));
    reader.seek(@intCast(size - read_len), .start) catch return null;
    const got = reader.read(buf[0..read_len]) catch return null;
    if (got < 27) return null;

    var result: ?TailPage = null;
    var i: usize = 0;
    while (i + 4 <= got) {
        const idx = std.mem.indexOfPos(u8, buf[0..got], i, "OggS") orelse break;
        i = idx;
        // 先按页头界定页长（parsePage 的 CRC 覆盖整个切片尾，必须传入恰好一页）
        const hdr = buf[idx..got];
        if (hdr.len < 27 or hdr[4] != 0) {
            i = idx + 4;
            continue;
        }
        const nsegs: usize = hdr[26];
        if (27 + nsegs > hdr.len) {
            i = idx + 4;
            continue;
        }
        var payload_len: usize = 0;
        for (hdr[27 .. 27 + nsegs]) |s| payload_len += s;
        const page_len = 27 + nsegs + payload_len;
        if (page_len > hdr.len) {
            // 窗口内不完整（文件尾截断页）→ 跳过
            i = idx + 4;
            continue;
        }
        const maybe = parsePage(buf[idx .. idx + page_len]) catch {
            i = idx + 4; // 坏页起点：跳过魔数继续找
            continue;
        };
        if (maybe) |pg| {
            if ((serial == 0 or pg.serial == serial) and pg.granule >= 0) {
                result = .{
                    .granule = pg.granule,
                    .eos = (pg.header_type & HEADER_TYPE_EOS) != 0,
                };
            }
            i = idx + page_len; // 完整页：跳到下一页起点
            continue;
        }
        i = idx + 4;
    }
    return result;
}

/// 逐页读取并重组 packets 的解复用器。
/// 用法：`nextPacket()` 依次返回完整 packet（内部缓冲，调用方只读）；
/// 返回 null = 流结束；`final_granule` = 末页 granule。
pub const Demux = struct {
    allocator: std.mem.Allocator,
    reader: io.Reader,

    /// 目标流序列号（0 = 自动取首个遇到的有效流）
    serial: u32 = 0,
    serial_locked: bool = false,

    // 当前页状态
    page_buf: []u8 = &.{},
    page: ?Page = null,
    /// 当前页在文件中的起始偏移（供 seek 按 granule 定位）
    page_start: u64 = 0,
    seg_idx: usize = 0,
    payload_off: usize = 0,

    /// 重组缓冲
    pkt_buf: std.ArrayList(u8) = .empty,
    /// 当前 packet 是否跨页（页首续段）
    pkt_continued: bool = false,
    /// 当前 packet 完成时的 granule
    pkt_granule: i64 = 0,
    /// 有完整 packet 待取
    pkt_ready: bool = false,
    /// 已见流的最终 granule（EOS 页）
    final_granule: i64 = 0,
    /// 是否遇到 EOS
    eos: bool = false,

    pub fn deinit(self: *Demux) void {
        if (self.page_buf.len > 0) self.allocator.free(self.page_buf);
        self.pkt_buf.deinit(self.allocator);
        self.reader.deinit();
    }

    /// 回到流开头并清空重组状态（供 seek 重新解析）。
    pub fn reset(self: *Demux) Error!void {
        self.page = null;
        self.page_start = 0;
        self.seg_idx = 0;
        self.payload_off = 0;
        self.pkt_buf.clearRetainingCapacity();
        self.pkt_continued = false;
        self.pkt_granule = 0;
        self.pkt_ready = false;
        self.final_granule = 0;
        self.eos = false;
        try self.reader.seek(0, .start);
    }

    /// 定位 granule ≥ target 的页，seek reader 到该页起始并清空重组状态。
    /// 返回该页开始前已完成的 granule（该页第一个包起始的样本位置，含 pre-skip）。
    pub fn seekToGranule(self: *Demux, target: i64) Error!i64 {
        try self.reset();
        var prev_granule: i64 = 0;
        while (true) {
            if (!try self.loadPage()) return error.Corrupt;
            const g = self.page.?.granule;
            if (g >= target) {
                const start: i64 = @intCast(self.page_start);
                self.page = null;
                self.seg_idx = 0;
                self.payload_off = 0;
                self.pkt_buf.clearRetainingCapacity();
                self.pkt_continued = false;
                self.pkt_granule = 0;
                self.pkt_ready = false;
                self.eos = false;
                self.final_granule = 0;
                try self.reader.seek(start, .start);
                return prev_granule;
            }
            prev_granule = g;
        }
    }

    /// 读取并解析下一页。
    fn loadPage(self: *Demux) Error!bool {
        // 页头
        var head: [27]u8 = undefined;
        const n = try self.reader.peek(&head);
        if (n < 27) return false;
        if (!std.mem.eql(u8, head[0..4], "OggS")) {
            // 非页起点：逐字节扫描同步（跳过无关流/垃圾）
            var skip: u64 = 1;
            while (skip <= 27) : (skip += 1) {
                try self.reader.seek(@intCast(skip), .start);
                const m = try self.reader.peek(&head);
                if (m >= 4 and std.mem.eql(u8, head[0..4], "OggS")) break;
            }
            if (skip > 27) return error.Corrupt;
            _ = try self.reader.peek(&head);
        }
        const nsegs: usize = head[26];
        if (nsegs > 255) return error.Corrupt;
        // 页头 + 分段表（27+nsegs 字节）确定 payload 长度
        var hdr_buf: [27 + 255]u8 = undefined;
        const nh = try self.reader.peek(hdr_buf[0 .. 27 + nsegs]);
        if (nh < 27 + nsegs) return error.Corrupt;
        var payload_len: usize = 0;
        for (hdr_buf[27 .. 27 + nsegs]) |s| payload_len += s;
        const page_len = 27 + nsegs + payload_len;
        if (page_len > 16 * 1024 * 1024) return error.Corrupt;

        if (self.page_buf.len < page_len) {
            if (self.page_buf.len > 0) self.allocator.free(self.page_buf);
            self.page_buf = try self.allocator.alloc(u8, page_len);
        }
        self.page_start = self.reader.pos;
        const got = try self.reader.read(self.page_buf[0..page_len]);
        if (got < page_len) return error.Corrupt;
        self.page = try parsePage(self.page_buf[0..page_len]);
        self.seg_idx = 0;
        self.payload_off = 0;

        // 序列号锁定：首个 `OggS` 页即目标流（FFmpeg 以首个流为准）
        if (!self.serial_locked) {
            self.serial = self.page.?.serial;
            self.serial_locked = true;
        }
        if (self.page.?.serial != self.serial) return error.Corrupt; // 非预期流

        if (self.page.?.header_type & HEADER_TYPE_EOS != 0) {
            self.eos = true;
            self.final_granule = self.page.?.granule;
        }
        return true;
    }

    /// 取下一个完整 packet。返回 null = EOF。
    /// `data` 指向内部缓冲（下次调用前有效）；`granule` 为 packet 完成时的页
    /// granule；`continued` 标记是否跨页续段。
    pub fn nextPacket(self: *Demux) Error!?struct {
        data: []const u8,
        granule: i64,
        continued: bool,
    } {
        if (self.pkt_ready) {
            self.pkt_ready = false;
            self.pkt_buf.clearRetainingCapacity();
        }
        while (true) {
            if (self.page == null) {
                if (self.eos) return null;
                if (!try self.loadPage()) return null;
            }
            const pg = &self.page.?;
            if (self.seg_idx >= pg.segments.len) {
                // 页耗尽 → 释放并读下一页
                self.page = null;
                self.pkt_continued = false;
                continue;
            }
            const lace = pg.segments[self.seg_idx];
            self.seg_idx += 1;
            const start_of_page = self.seg_idx == 1;
            const start_of_pkt = self.pkt_buf.items.len == 0;
            if (start_of_page and start_of_pkt and (pg.header_type & HEADER_TYPE_CONTINUED) != 0) {
                // 页首续段：packet 自上一页开始（跨页）
                self.pkt_continued = true;
            }
            try self.pkt_buf.appendSlice(self.allocator, pg.payload[self.payload_off .. self.payload_off + lace]);
            self.payload_off += lace;
            if (lace < 255) {
                // packet 完成
                self.pkt_granule = pg.granule;
                self.pkt_ready = true;
                return .{
                    .data = self.pkt_buf.items,
                    .granule = self.pkt_granule,
                    .continued = self.pkt_continued,
                };
            }
        }
    }
};

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

fn buildPage(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    header_type: u8,
    granule: i64,
    serial: u32,
    page_seq: u32,
    lacing: []const u8,
    payload: []const u8,
) !void {
    buf.clearRetainingCapacity();
    try buf.appendSlice(allocator, "OggS");
    try buf.append(allocator, 0); // version
    try buf.append(allocator, header_type);
    var g: [8]u8 = undefined;
    std.mem.writeInt(i64, &g, granule, .little);
    try buf.appendSlice(allocator, &g);
    var s: [4]u8 = undefined;
    std.mem.writeInt(u32, &s, serial, .little);
    try buf.appendSlice(allocator, &s);
    std.mem.writeInt(u32, &s, page_seq, .little);
    try buf.appendSlice(allocator, &s);
    try buf.appendNTimes(allocator, 0, 4); // checksum 占位
    try buf.append(allocator, @intCast(lacing.len));
    try buf.appendSlice(allocator, lacing);
    try buf.appendSlice(allocator, payload);
    // 计算并回填 CRC
    var crc: u32 = 0;
    crc = crcUpdateBytes(crc, buf.items[0..22]);
    crc = crcUpdateBytes(crc, &[_]u8{ 0, 0, 0, 0 });
    crc = crcUpdateBytes(crc, buf.items[26..]);
    std.mem.writeInt(u32, buf.items[22..26], crc, .little);
}

test "ogg: CRC-32 非反射与已知向量" {
    // "123456789" 的 CRC-32/MPEG-2（poly 0x04C11DB7，init 0，无输出异或）= 0x0376E6E7
    var c: u32 = 0;
    for ("123456789") |b| c = crcUpdate(c, b);
    try testing.expectEqual(@as(u32, 0x89A1897F), c);
}

test "ogg: 页解析与 CRC 回填自洽" {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(testing.allocator);
    try buildPage(&buf, testing.allocator, HEADER_TYPE_BOS, 0, 0x1234, 0, &[_]u8{ 10, 5, 255, 3 }, &([_]u8{0} ** 273));
    const page = (try parsePage(buf.items)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 0x1234), page.serial);
    try testing.expectEqual(@as(u8, HEADER_TYPE_BOS), page.header_type);
    try testing.expectEqual(@as(usize, 4), page.segments.len);
    // 页损坏 → Corrupt
    buf.items[30] ^= 0xFF;
    try testing.expectError(error.Corrupt, parsePage(buf.items));
}

test "ogg: Demux 单页内 packet 重组（lacing 分段）" {
    var page_buf = std.ArrayList(u8).empty;
    defer page_buf.deinit(testing.allocator);
    // 三个 packet：5 字节 / 260 字节（255+5 跨段） / 3 字节
    const lacing = [_]u8{ 5, 255, 5, 3 };
    const payload = "ABCDE" ++ ("F" ** 255) ++ "GHIJK" ++ "XYZ";
    try buildPage(&page_buf, testing.allocator, HEADER_TYPE_EOS, 42, 1, 0, &lacing, payload);

    const reader = io.Reader.openMem(page_buf.items);
    var dmx = Demux{ .allocator = testing.allocator, .reader = reader };
    defer dmx.deinit();
    const p1 = (try dmx.nextPacket()).?;
    try testing.expectEqual(@as(usize, 5), p1.data.len);
    try testing.expectEqual(@as(i64, 42), p1.granule);
    const p2 = (try dmx.nextPacket()).?;
    try testing.expectEqual(@as(usize, 260), p2.data.len);
    const p3 = (try dmx.nextPacket()).?;
    try testing.expectEqual(@as(usize, 3), p3.data.len);
    try testing.expect((try dmx.nextPacket()) == null);
    try testing.expectEqual(@as(i64, 42), dmx.final_granule);
}

// ---------------------------------------------------------------------------
// 尾窗扫描（scanTailPage）
// ---------------------------------------------------------------------------

/// 构造多页内存流：p0 = BOS(granule 0) / p1(granule 100) / p2 = EOS(granule 500)
fn buildThreePages(allocator: std.mem.Allocator, serial: u32) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    errdefer buf.deinit(allocator);
    const payload = [_]u8{0} ** 40;
    try buildPage(&buf, allocator, HEADER_TYPE_BOS, 0, serial, 0, &[_]u8{payload.len}, &payload);
    var one = std.ArrayList(u8).empty;
    defer one.deinit(allocator);
    try one.appendSlice(allocator, buf.items);
    try buildPage(&buf, allocator, 0, 100, serial, 1, &[_]u8{payload.len}, &payload);
    try one.appendSlice(allocator, buf.items);
    try buildPage(&buf, allocator, HEADER_TYPE_EOS, 500, serial, 2, &[_]u8{payload.len}, &payload);
    try one.appendSlice(allocator, buf.items);
    return one.toOwnedSlice(allocator);
}

test "ogg: scanTailPage 命中末页 granule/EOS 并恢复读位置" {
    const serial: u32 = 0xDEADBEEF;
    const data = try buildThreePages(testing.allocator, serial);
    defer testing.allocator.free(data);
    var reader = io.Reader.openMem(data);
    reader.pos = 50; // 模拟调用方读至中途
    const tail = (try scanTailPage(&reader, serial)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i64, 500), tail.granule);
    try testing.expect(tail.eos);
    // 读位置不污染
    try testing.expectEqual(@as(u64, 50), reader.pos);
    // 序列号不匹配 → 不命中
    try testing.expect((try scanTailPage(&reader, 0x1234)) == null);
    // serial = 0 → 不限定
    try testing.expect((try scanTailPage(&reader, 0)) != null);
}

test "ogg: scanTailPage 末页截断/损坏 → 退前一页（无 EOS）" {
    const serial: u32 = 7;
    const data = try buildThreePages(testing.allocator, serial);
    defer testing.allocator.free(data);
    // 截断：砍掉末页（含 EOS）
    var reader = io.Reader.openMem(data[0 .. data.len - 67]);
    const tail = (try scanTailPage(&reader, serial)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i64, 100), tail.granule);
    try testing.expect(!tail.eos);
    // 损坏：翻转末页 payload 字节（CRC 不再匹配）
    var corrupted = try testing.allocator.dupe(u8, data);
    defer testing.allocator.free(corrupted);
    corrupted[corrupted.len - 5] ^= 0xFF;
    var reader2 = io.Reader.openMem(corrupted);
    const tail2 = (try scanTailPage(&reader2, serial)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i64, 100), tail2.granule);
    try testing.expect(!tail2.eos);
}

test "ogg: scanTailPage 过小输入与 callback 形态返回 null" {
    var reader = io.Reader.openMem("OggS");
    try testing.expect((try scanTailPage(&reader, 0)) == null);
    // callback 流不可 seek → 不扫描
    const Ctx = struct {
        fn readFn(_: *anyopaque, _: []u8) usize {
            return 0;
        }
    };
    var ctx: u8 = 0;
    var cb = io.Reader{
        .kind = .callback,
        .on_read = Ctx.readFn,
        .ctx = @ptrCast(&ctx),
        .size_hint = 1000,
        .buffer = try testing.allocator.alloc(u8, 16 * 1024),
    };
    defer testing.allocator.free(cb.buffer);
    try testing.expect((try scanTailPage(&cb, 0)) == null);
}
