//! 解码会话编排 + C ABI 桥接逻辑（docs/audio-kernel-zig.md §16.1）
//!
//! 本模块承载 `zk_*` 的全部实现（`kernel.zig` 只做 `export fn` 薄包装），
//! 管线：`decoder.open`（probe → 工厂）→ `pcm/convert.zig`（原生 → float32 交错）。
//!
//! 线程模型（§16.1）：本模块**不持线程**，纯函数式被 C 壳（mediaengine_lib.c
//! 引擎线程）调用；`Engine` 即 C 侧不透明指针 `ZkDecoder`。
//!
//! 内存：统一使用 `std.heap.c_allocator`（宿主 CRT 的 malloc/free），静态库
//! 被 C 壳链接时符号由最终链接器解析，跨 CRT 安全（§16.2）。

const std = @import("std");
const err = @import("error.zig");
const decoder = @import("decoder.zig");
const convert = @import("pcm/convert.zig");

const Allocator = std.mem.Allocator;

/// C ABI 解码信息（与 `include/kernel_bridge.h` 的 `ZkInfo` 逐字段对齐；
/// `codec_name`/`format_name` 指向内核静态字面量，`title`…`comment` 指向解码器
/// 上下文持有的分配，生命周期均与 Engine 一致，C 侧只读不释放）
pub const ZkInfo = extern struct {
    sample_rate: c_int,
    channels: c_int,
    bits_per_sample: c_int,
    duration_us: c_longlong,
    duration_known: c_int, // 0=exact 1=estimate 2=unknown
    codec_name: ?[*:0]const u8,
    format_name: ?[*:0]const u8,
    title: ?[*:0]const u8,
    artist: ?[*:0]const u8,
    album: ?[*:0]const u8,
    date: ?[*:0]const u8,
    genre: ?[*:0]const u8,
    comment: ?[*:0]const u8,
};

/// 解码会话（`zk_decoder_open` 成功返回 `*Engine`，即 C 侧 `ZkDecoder`）
pub const Engine = struct {
    allocator: Allocator,
    dec: decoder.Decoder,
    info: decoder.Info,
    /// 原生 → float32 转换的中间缓冲（按需增长，生命周期与 Engine 一致）
    raw: []u8,
};

/// errbuf 布局（kernel_bridge.h 契约）：
///   errbuf[0..4]  — LE c_int 稳定状态码（err.Status）
///   errbuf[4..]   — NUL 终止的人读诊断消息
const errbuf_status_size = 4;

// ---------------------------------------------------------------------------
// zk_* 实现
// ---------------------------------------------------------------------------

pub fn zkOpen(path: [*:0]const u8, info: *ZkInfo, errbuf: [*]u8, errbuf_size: c_int) ?*Engine {
    const gpa = std.heap.c_allocator;
    var zinfo: decoder.Info = undefined;
    var dec = decoder.open(gpa, std.mem.span(path), &zinfo) catch |e| {
        fillErrBuf(errbuf, errbuf_size, e);
        return null;
    };
    const eng = gpa.create(Engine) catch {
        dec.deinit();
        fillErrBuf(errbuf, errbuf_size, error.OutOfMemory);
        return null;
    };
    eng.* = .{
        .allocator = gpa,
        .dec = dec,
        .info = zinfo,
        .raw = &.{},
    };
    info.* = .{
        .sample_rate = @intCast(zinfo.sample_rate),
        .channels = @intCast(zinfo.channels),
        .bits_per_sample = @intCast(zinfo.bits_per_sample),
        .duration_us = zinfo.duration_us,
        .duration_known = switch (zinfo.duration_known) {
            .exact => 0,
            .estimate => 1,
            .unknown => 2,
        },
        .codec_name = zinfo.codec_name.ptr,
        .format_name = zinfo.format_name.ptr,
        .title = metaPtr(zinfo.metadata.title),
        .artist = metaPtr(zinfo.metadata.artist),
        .album = metaPtr(zinfo.metadata.album),
        .date = metaPtr(zinfo.metadata.date),
        .genre = metaPtr(zinfo.metadata.genre),
        .comment = metaPtr(zinfo.metadata.comment),
    };
    return eng;
}

/// 可空 NUL 终止切片 → C 指针（null 直传）
fn metaPtr(s: ?[:0]const u8) ?[*:0]const u8 {
    return if (s) |v| v.ptr else null;
}

/// 解码最多 `max_frames` 帧到 `out`（float32 交错），返回实际帧数。
/// 语义（对齐 include/kernel_bridge.h 契约，跨语言稳定）：
///   - >= 0：实际输出帧数；0 = EOF（正常文件尾）；
///   - < 0：解码错误，绝对值 = err.Status 稳定状态码
///     （如 -@intFromEnum(Status.corrupt) = -3），调用方应报错而非按 EOF 处理。
/// `out_channels` 输出本帧实际声道数（任何返回值下都有效）。
pub fn zkRead(d: *Engine, out: [*]f32, max_frames: usize, out_channels: *c_int) isize {
    const frame_bytes = @as(usize, d.info.channels) * (@as(usize, d.info.bits_per_sample) / 8);
    out_channels.* = @intCast(d.info.channels);
    if (max_frames == 0 or frame_bytes == 0) return 0;

    const want = max_frames * frame_bytes;
    if (d.raw.len < want) {
        d.raw = d.allocator.realloc(d.raw, want) catch {
            return -@as(isize, @intFromEnum(err.Status.out_of_memory));
        };
    }
    var ch: u8 = 0;
    const frames = d.dec.read(d.raw[0..want], max_frames, &ch) catch |e| {
        // 解码错误必须与 EOF 区分：错误经负状态码上报（EOF 是 read 返回 0 帧）。
        // 此前把错误吞成 0 = EOF，导致坏帧/损坏文件被静默截断输出。
        return -@as(isize, @intFromEnum(err.statusOf(e)));
    };
    out_channels.* = @intCast(ch);
    if (frames == 0) return 0;
    const samples = frames * ch;
    _ = convert.toFloat(
        out[0..samples],
        d.raw[0 .. frames * frame_bytes],
        d.info.bits_per_sample,
        d.info.is_float,
        endianOf(d.info),
    );
    return @intCast(frames);
}

/// 跳转到指定毫秒位置；返回 0 = 成功，非 0 = 稳定状态码（err.Status）
pub fn zkSeekMs(d: *Engine, ms: i64) c_int {
    d.dec.seekMs(ms) catch |e| return @intFromEnum(err.statusOf(e));
    return 0;
}

/// 当前播放位置（毫秒，自文件开头计）
pub fn zkPositionMs(d: *Engine) i64 {
    return d.dec.positionMs();
}

/// 释放会话全部资源（含 decoder 与 raw 缓冲）
pub fn zkClose(d: *Engine) void {
    const gpa = d.allocator;
    if (d.raw.len > 0) gpa.free(d.raw);
    d.dec.deinit();
    gpa.destroy(d);
}

// ---------------------------------------------------------------------------
// 内部
// ---------------------------------------------------------------------------

/// 从 codec_name（对齐 FFmpeg 命名，如 "pcm_s16be"）推断原生字节序。
/// 无字节序概念 / 无后缀的（"pcm_s8" 等）默认 little（单字节无影响）。
fn endianOf(info: decoder.Info) std.builtin.Endian {
    const n = info.codec_name;
    if (n.len >= 2 and std.mem.eql(u8, n[n.len - 2 ..], "be")) return .big;
    return .little;
}

/// 填充 errbuf（见文件头布局说明）。边界完整：任意 errbuf_size 下不越界、
/// 消息尽量保证 NUL 终止，诊断可读。
fn fillErrBuf(buf: [*]u8, buf_size: c_int, e: anyerror) void {
    if (buf_size <= 0) return;
    const size: usize = @intCast(buf_size);
    const status: c_int = @intFromEnum(err.statusOf(e));
    const msg = err.messageOf(e);

    if (size >= errbuf_status_size + 1) {
        // 状态码 + NUL 终止消息（消息截断到 room-1，末尾保留 1 字节写 0）
        std.mem.writeInt(c_int, @ptrCast(buf[0..4]), status, .little);
        const room = size - errbuf_status_size;
        const n = @min(msg.len, room - 1);
        if (n > 0) @memcpy(buf[errbuf_status_size .. errbuf_status_size + n], msg[0..n]);
        buf[errbuf_status_size + n] = 0;
    } else if (size >= errbuf_status_size) {
        // 恰好只放得下状态码
        std.mem.writeInt(c_int, @ptrCast(buf[0..4]), status, .little);
    } else {
        // buf 连状态码都放不下：退化仅写截断消息（尽力保证可读与 NUL）
        const n = @min(msg.len, size - 1);
        if (n > 0) @memcpy(buf[0..n], msg[0..n]);
        buf[n] = 0;
    }
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

/// 在 tmpDir 写一个 16-bit 单声道 WAV 文件，返回 NUL 终止的绝对路径（黄金样本）
fn writeTestWav(tmp: *testing.TmpDir, io: std.Io, name: []const u8) ![:0]u8 {
    // 黄金样本：i16 序列 0..7（8 帧，8000Hz）
    var samples: [16]u8 = undefined;
    for (0..8) |i| {
        std.mem.writeInt(i16, samples[2 * i ..][0..2], @as(i16, @intCast(i)), .little);
    }
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(testing.allocator);
    try bytes.appendSlice(testing.allocator, "RIFF\x28\x00\x00\x00WAVE"); // 8+16+8+16=48 → riffSize 40
    try bytes.appendSlice(testing.allocator, "fmt ");
    try bytes.appendSlice(testing.allocator, &[_]u8{ 0x10, 0x00, 0x00, 0x00 });
    try bytes.appendSlice(testing.allocator, &[_]u8{ 0x01, 0x00, 0x01, 0x00, 0x40, 0x1F, 0x00, 0x00, 0x00, 0x3E, 0x00, 0x00, 0x02, 0x00, 0x10, 0x00 });
    try bytes.appendSlice(testing.allocator, "data");
    try bytes.appendSlice(testing.allocator, &[_]u8{ 0x10, 0x00, 0x00, 0x00 });
    try bytes.appendSlice(testing.allocator, &samples);

    const f = try tmp.dir.createFile(io, name, .{});
    try std.Io.File.writeStreamingAll(f, io, bytes.items);
    std.Io.File.close(f, io);

    const rel = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], name });
    defer testing.allocator.free(rel);
    return testing.allocator.dupeZ(u8, rel);
}

test "zk: open 成功并填充 ZkInfo" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    const full = try writeTestWav(&tmp, io, "t.wav");
    defer testing.allocator.free(full);

    var info: ZkInfo = undefined;
    var errbuf: [64]u8 = undefined;
    const eng = zkOpen(full.ptr, &info, &errbuf, errbuf.len);
    try testing.expect(eng != null);
    defer zkClose(eng.?);

    try testing.expectEqual(@as(c_int, 8000), info.sample_rate);
    try testing.expectEqual(@as(c_int, 1), info.channels);
    try testing.expectEqual(@as(c_int, 16), info.bits_per_sample);
    try testing.expectEqual(@as(c_longlong, 1_000), info.duration_us); // 8 帧 / 8kHz = 1ms
    try testing.expectEqual(@as(c_int, 0), info.duration_known); // exact
    const cn = std.mem.span(info.codec_name.?);
    try testing.expectEqualStrings("pcm_s16le", cn);
    try testing.expectEqualStrings("wav", std.mem.span(info.format_name.?));
    // 无标签的 WAV：metadata 全为 NULL
    try testing.expect(info.title == null);
    try testing.expect(info.artist == null);
    try testing.expect(info.album == null);
}

test "zk: open 填充标签元数据（LIST-INFO）" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    // RIFF：fmt(16) + LIST-INFO(INAM "Test Song") + data(16)，riffSize 78
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(testing.allocator);
    try bytes.appendSlice(testing.allocator, "RIFF\x4E\x00\x00\x00WAVE");
    try bytes.appendSlice(testing.allocator, "fmt ");
    try bytes.appendSlice(testing.allocator, &[_]u8{ 0x10, 0x00, 0x00, 0x00 });
    try bytes.appendSlice(testing.allocator, &[_]u8{ 0x01, 0x00, 0x01, 0x00, 0x40, 0x1F, 0x00, 0x00, 0x00, 0x3E, 0x00, 0x00, 0x02, 0x00, 0x10, 0x00 });
    try bytes.appendSlice(testing.allocator, "LIST");
    try bytes.appendSlice(testing.allocator, &[_]u8{ 0x16, 0x00, 0x00, 0x00 }); // 22 = 4+4+4+9+1
    try bytes.appendSlice(testing.allocator, "INFO");
    try bytes.appendSlice(testing.allocator, "INAM");
    try bytes.appendSlice(testing.allocator, &[_]u8{ 0x09, 0x00, 0x00, 0x00 }); // "Test Song"(9)
    try bytes.appendSlice(testing.allocator, "Test Song");
    try bytes.appendSlice(testing.allocator, &[_]u8{0}); // pad
    try bytes.appendSlice(testing.allocator, "data");
    try bytes.appendSlice(testing.allocator, &[_]u8{ 0x10, 0x00, 0x00, 0x00 });
    var samples: [16]u8 = undefined;
    for (0..8) |i| {
        std.mem.writeInt(i16, samples[2 * i ..][0..2], @as(i16, @intCast(i)), .little);
    }
    try bytes.appendSlice(testing.allocator, &samples);

    const f = try tmp.dir.createFile(io, "meta.wav", .{});
    try std.Io.File.writeStreamingAll(f, io, bytes.items);
    std.Io.File.close(f, io);

    const rel = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "meta.wav" });
    defer testing.allocator.free(rel);
    const full = try testing.allocator.dupeZ(u8, rel);
    defer testing.allocator.free(full);

    var info: ZkInfo = undefined;
    var errbuf: [64]u8 = undefined;
    const eng = zkOpen(full.ptr, &info, &errbuf, errbuf.len);
    try testing.expect(eng != null);
    defer zkClose(eng.?);

    try testing.expectEqualStrings("Test Song", std.mem.span(info.title.?));
    try testing.expect(info.artist == null);
    try testing.expect(info.album == null);
    try testing.expectEqual(@as(c_longlong, 1_000), info.duration_us); // 解码不受影响
}

test "zk: read 输出 float32 交错" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    const full = try writeTestWav(&tmp, io, "t.wav");
    defer testing.allocator.free(full);

    var info: ZkInfo = undefined;
    var errbuf: [64]u8 = undefined;
    const eng = zkOpen(full.ptr, &info, &errbuf, errbuf.len).?;
    defer zkClose(eng);

    var out: [16]f32 = undefined;
    var ch: c_int = 0;
    const frames = zkRead(eng, &out, 8, &ch);
    try testing.expectEqual(@as(isize, 8), frames);
    try testing.expectEqual(@as(c_int, 1), ch);
    // i16 0..7 → /32768
    for (0..8) |i| {
        try testing.expectApproxEqAbs(@as(f32, @floatFromInt(@as(i16, @intCast(i)))) / 32768.0, out[i], 1e-6);
    }
    // EOF
    try testing.expectEqual(@as(isize, 0), zkRead(eng, &out, 8, &ch));
}

test "zk: seek/position 往返" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    const full = try writeTestWav(&tmp, io, "t.wav");
    defer testing.allocator.free(full);

    var info: ZkInfo = undefined;
    var errbuf: [64]u8 = undefined;
    const eng = zkOpen(full.ptr, &info, &errbuf, errbuf.len).?;
    defer zkClose(eng);

    try testing.expectEqual(@as(c_int, 0), zkSeekMs(eng, 0)); // 0 = ok
    var out: [16]f32 = undefined;
    var ch: c_int = 0;
    // 读满全部 8 帧 → position 1ms
    try testing.expectEqual(@as(isize, 8), zkRead(eng, &out, 8, &ch));
    try testing.expectEqual(@as(i64, 1), zkPositionMs(eng)); // 8/8000s = 1ms
    // EOF
    try testing.expectEqual(@as(isize, 0), zkRead(eng, &out, 8, &ch));
    // seek 回 0 → 从头再读满（max_frames=8 全量返回）
    try testing.expectEqual(@as(c_int, 0), zkSeekMs(eng, 0));
    try testing.expectEqual(@as(isize, 8), zkRead(eng, &out, 8, &ch));
    try testing.expectEqual(@as(i64, 1), zkPositionMs(eng)); // 8 帧 / 8kHz = 1ms
    // seek 到 1ms（= 8 帧 = 文件尾）→ 已到 EOF
    try testing.expectEqual(@as(c_int, 0), zkSeekMs(eng, 1));
    try testing.expectEqual(@as(isize, 0), zkRead(eng, &out, 8, &ch));
    try testing.expectEqual(@as(i64, 1), zkPositionMs(eng)); // 8 帧 / 8kHz = 1ms
}

test "zk: 不存在的文件 → null + 状态码 open_failed(2)" {
    var errbuf: [64]u8 = undefined;
    var info: ZkInfo = undefined;
    try testing.expect(zkOpen("/nonexistent/definitely-missing.wav", &info, &errbuf, errbuf.len) == null);
    const status = std.mem.readInt(c_int, @ptrCast(errbuf[0..4]), .little);
    try testing.expectEqual(@as(c_int, @intFromEnum(err.Status.open_failed)), status);
}

test "zk: 非 WAV 文件 → null + 状态码 unsupported(1)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    const f = try tmp.dir.createFile(io, "t.bin", .{});
    try std.Io.File.writeStreamingAll(f, io, "not-an-audio-file-at-all");
    std.Io.File.close(f, io);
    const rel = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "t.bin" });
    defer testing.allocator.free(rel);
    const full = try testing.allocator.dupeZ(u8, rel);
    defer testing.allocator.free(full);

    var errbuf: [64]u8 = undefined;
    var info: ZkInfo = undefined;
    try testing.expect(zkOpen(full.ptr, &info, &errbuf, errbuf.len) == null);
    const status = std.mem.readInt(c_int, @ptrCast(errbuf[0..4]), .little);
    try testing.expectEqual(@as(c_int, @intFromEnum(err.Status.unsupported_format)), status);
}

test "zk: errbuf 尺寸边界（0 / 2 / 4 / 5 字节）" {
    var info: ZkInfo = undefined;
    var b0: [0]u8 = undefined;
    _ = zkOpen("/nonexistent/x.wav", &info, &b0, 0); // 不应崩溃

    var b2: [2]u8 = undefined;
    _ = zkOpen("/nonexistent/x.wav", &info, &b2, 2);
    try testing.expectEqual(@as(u8, 'f'), b2[0]); // 截断消息 "failed..." 首字节

    var b4: [4]u8 = undefined;
    _ = zkOpen("/nonexistent/x.wav", &info, &b4, 4);
    try testing.expectEqual(@as(c_int, @intFromEnum(err.Status.open_failed)), std.mem.readInt(c_int, @ptrCast(b4[0..4]), .little));

    var b5: [5]u8 = undefined;
    _ = zkOpen("/nonexistent/x.wav", &info, &b5, 5);
    // size=5：状态码 + 消息截断到 0 字节 → buf[4] 为 NUL
    try testing.expectEqual(@as(u8, 0), b5[4]);

    var b8: [8]u8 = undefined;
    _ = zkOpen("/nonexistent/x.wav", &info, &b8, 8);
    try testing.expectEqual(@as(u8, 'f'), b8[4]); // 状态码 + 消息首字节
    try testing.expectEqual(@as(u8, 0), b8[7]); // 消息 "fai" + NUL
}
