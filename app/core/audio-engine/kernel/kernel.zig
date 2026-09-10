// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! archoera_kernel — 自研音频解码内核（FFmpeg 渐进替换）
//!
//! 定位（docs/audio-kernel-zig.md v3）：
//!   FFmpeg 保持默认主引擎；本内核按格式逐项验收后接管解码。
//!   C 壳（audio-engine/src/*.c）通过 kernel_bridge.h（zk_* C ABI）调用本内核，
//!   Dart FFI 层零改动。
//!
//! 文件组织（后续步骤逐步引入）：
//!   error.zig     —— 统一错误类型与错误码 ↔ zk_* 状态码映射（e2）
//!   io.zig        —— 只读字节流 Reader 抽象（内存 / 文件 / 自定义 IO，e2）
//!   probe.zig     —— 魔数嗅探：识别容器/编码格式（e2）
//!   decoder.zig   —— 统一解码接口 + 格式工厂（e3）
//!   fmt/wav/      —— 自研 WAV 家族（RIFF/RIFX/RF64/W64/AIFF + Apple CAF + Sun AU，
//!                    未压缩 PCM 家族，e3，多模块：
//!                    chunk.zig 容器帧层 / decl.zig 格式声明 / g711.zig 编码）
//!   根文件         —— 聚合子模块 + 版本常量（本文件）

const std = @import("std");

pub const err = @import("error.zig");
pub const io = @import("io.zig");
pub const probe = @import("probe.zig");
pub const registry = @import("registry.zig");
pub const tables = @import("tables.zig");
pub const task = @import("task.zig");
pub const session = @import("session.zig");
pub const khost = @import("khost.zig");
pub const runtime = @import("runtime.zig");
pub const decoder = @import("decoder.zig");
pub const gsm = @import("fmt/wav/gsm.zig");
pub const mace = @import("fmt/wav/mace.zig");
pub const wav = @import("fmt/wav/lib.zig");
pub const convert = @import("pcm/convert.zig");
pub const engine = @import("engine.zig");

/// 内核版本（语义化版本，与 build.zig.zon 保持同步）
pub const version: std.SemanticVersion = .{ .major = 0, .minor = 1, .patch = 0 };

/// 内核版本字符串（"major.minor.patch"），供 C ABI 的 zk_version 查询使用
pub const version_string = "0.1.0";

// ---------------------------------------------------------------------------
// C ABI 桥接（docs/audio-kernel-zig.md §16.1，头契约：include/kernel_bridge.h）
// ---------------------------------------------------------------------------

/// 打开解码器。成功返回 `*engine.Engine`（C 侧 `ZkDecoder`）；
/// 失败返回 null 并写 errbuf（errbuf[0..4] = LE 状态码，其后 NUL 终止诊断消息）。
export fn zk_decoder_open(
    path: [*:0]const u8,
    info: *engine.ZkInfo,
    errbuf: [*]u8,
    errbuf_size: c_int,
) ?*engine.Engine {
    return engine.zkOpen(path, info, errbuf, errbuf_size);
}

/// 解码最多 max_frames 帧 float32 交错到 out。
/// 返回 >=0 帧数（0 = EOF）；错误返回负值（-err.Status，见 include/kernel_bridge.h）。
export fn zk_decoder_read(
    d: *engine.Engine,
    out: [*]f32,
    max_frames: usize,
    out_channels: *c_int,
) isize {
    return engine.zkRead(d, out, max_frames, out_channels);
}

/// 跳转毫秒位置；0 = 成功，非 0 = 稳定状态码。
export fn zk_decoder_seek_ms(d: *engine.Engine, ms: i64) c_int {
    return engine.zkSeekMs(d, ms);
}

/// 当前播放位置（毫秒，自文件开头计）。
export fn zk_decoder_position_ms(d: *engine.Engine) i64 {
    return engine.zkPositionMs(d);
}

/// 释放解码会话（含底层文件句柄与全部缓冲）；d 为 NULL 时为空操作（头契约）。
export fn zk_decoder_close(d: ?*engine.Engine) void {
    if (d) |e| engine.zkClose(e);
}

// ---------------------------------------------------------------------------
// 常驻内核接入 seam（§7 async 主干；加法式：不改 zk_decoder_* / C 壳现有会话）
//
// 表面同步、内里异步：C 壳阻塞调用 → 内核 Host 池并行解码 → 完工事件回程。
// 与现有引擎路径（mediaengine_lib/pipeline/player/纯内存源）完全隔离。
// ---------------------------------------------------------------------------

/// 一次性解码（池内执行）的载体
const DecOnce = struct {
    task: task.Task = .{ .run = run },
    path: []const u8,
    out: [*]f32,
    cap_frames: usize,
    info_out: ?*engine.ZkInfo = null,
    frames: isize = 0,
    ch: u8 = 0,

    fn run(t: *task.Task) void {
        const d: *DecOnce = @fieldParentPtr("task", t);
        var zinfo: decoder.Info = undefined;
        var dec = decoder.open(std.heap.c_allocator, d.path, &zinfo) catch |e| {
            d.frames = -@as(isize, @intFromEnum(err.statusOf(e)));
            return;
        };
        defer dec.deinit();

        if (d.info_out) |zi| fillZkInfoMinimal(zi, zinfo);

        const ch = zinfo.channels;
        const bytes_per = @as(usize, zinfo.bits_per_sample) / 8;
        d.ch = ch;
        if (ch == 0 or bytes_per == 0) {
            d.frames = -@as(isize, @intFromEnum(err.Status.corrupt));
            return;
        }
        const frame_bytes: usize = @as(usize, ch) * bytes_per;
        var raw: [65536]u8 = undefined;
        var produced: usize = 0;
        while (produced < d.cap_frames) {
            const room_frames = raw.len / frame_bytes;
            const chunk = @min(@min(room_frames, d.cap_frames - produced), @as(usize, 4096));
            if (chunk == 0) break;
            var c: u8 = 0;
            const n = dec.read(raw[0 .. chunk * frame_bytes], chunk, &c) catch |e| {
                d.frames = -@as(isize, @intFromEnum(err.statusOf(e)));
                return;
            };
            if (n == 0) break;
            const samples = n * @as(usize, c);
            _ = convert.toFloat(
                d.out[produced * @as(usize, ch) ..][0..samples],
                raw[0 .. n * frame_bytes],
                zinfo.bits_per_sample,
                zinfo.is_float,
                endianOfCodec(zinfo.codec_name),
            );
            produced += n;
            if (n < chunk) break; // EOF
        }
        d.frames = @intCast(produced);
    }
};

/// 由 codec_name（如 "pcm_s16be"）推断原生字节序（与 engine.endianOf 同语义）
fn endianOfCodec(codec_name: []const u8) std.builtin.Endian {
    if (codec_name.len >= 2 and std.mem.eql(u8, codec_name[codec_name.len - 2 ..], "be")) return .big;
    return .little;
}

/// 最小 ZkInfo 填充（decode_once 用；codec/format 为静态字面量，metadata 置空）
fn fillZkInfoMinimal(zi: *engine.ZkInfo, zinfo: decoder.Info) void {
    zi.* = .{
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
        .title = null,
        .artist = null,
        .album = null,
        .date = null,
        .genre = null,
        .comment = null,
    };
}

/// 初始化常驻内核（Host：池 + 定容任务槽）。返回不透明句柄；失败返回 null。
export fn zk_engine_init(min_workers: c_int, max_workers: c_int, cap_tasks: c_int) ?*khost.Host {
    return zkEngineInit(max_streams_default, min_workers, max_workers, cap_tasks);
}

/// 同 zk_engine_init，另指定流式会话并发上限 max_streams（§6.3 硬计数；缺省
/// zk_engine_init 用 khost.Cfg 默认 = 8）。测试/宿主显式约束流并发时用。
export fn zk_engine_init_streams(
    min_workers: c_int,
    max_workers: c_int,
    cap_tasks: c_int,
    max_streams: c_int,
) ?*khost.Host {
    return zkEngineInit(@intCast(@max(max_streams, 1)), min_workers, max_workers, cap_tasks);
}

const max_streams_default: u16 = 8;

fn zkEngineInit(max_streams: u16, min_workers: c_int, max_workers: c_int, cap_tasks: c_int) ?*khost.Host {
    if (min_workers < 0 or max_workers < 0 or cap_tasks < 0) return null;
    const cfg = khost.Cfg{
        .min_workers = @intCast(@max(min_workers, 1)),
        .max_workers = @intCast(@max(max_workers, 1)),
        .cap_tasks = @intCast(@max(cap_tasks, 1)),
        .max_streams = max_streams,
    };
    return khost.Host.init(std.heap.c_allocator, cfg) catch null;
}

/// 停机并释放常驻内核；h 为 NULL 时空操作。
export fn zk_engine_shutdown(h: ?*khost.Host) void {
    if (h) |x| {
        x.shutdown();
        x.deinit();
    }
}

/// 池内一次性解码到 out（float32 交错，最多 max_frames 帧）。
/// 表面同步：本调用阻塞至完工（内核池并行内部）。返回 >=0 实际帧数（0=EOF）；
/// <0 = -ZkStatus；out_channels 输出实际声道数。调用方保证 out 可容纳
/// max_frames × 最大声道（内核契约 ≤8）。
export fn zk_engine_decode_once(
    h: ?*khost.Host,
    path: [*:0]const u8,
    out: [*]f32,
    max_frames: usize,
    out_channels: *c_int,
    info: ?*engine.ZkInfo,
) isize {
    const host = h orelse return -@as(isize, @intFromEnum(err.Status.io_error));
    const holder = std.heap.c_allocator.create(DecOnce) catch
        return -@as(isize, @intFromEnum(err.Status.out_of_memory));
    holder.* = .{
        .path = std.mem.span(path),
        .out = out,
        .cap_frames = max_frames,
        .info_out = info,
    };
    if (host.submit(&holder.task) == null) {
        std.heap.c_allocator.destroy(holder);
        return -@as(isize, @intFromEnum(err.Status.io_error));
    }
    task.wait(&holder.task);
    const frames = holder.frames;
    out_channels.* = @intCast(holder.ch);
    std.heap.c_allocator.destroy(holder);
    return frames;
}

// ---------------------------------------------------------------------------
// 元数据快路径 FFI（docs/audio-kernel-zig.md §8.4.2①；结构化 C ABI，无 JSON）
// 直接桥接 scanner：probe+open（不触发 PCM 解码），一次性取标量/标签/封面。
// ---------------------------------------------------------------------------

/// metadata 句柄：probe-only 会话或回退解码器（§8.4.2①）+ tags 数组
const MetaHandle = struct {
    opened: decoder.OpenedMeta,
    tags: []engine.ZkTag,
};

/// scanner 依据自身指标（AdaptiveConcurrency/内存）协商的并发提示；
/// 供内核后续 metadata 池/限流使用（当前仅存储与回读，不改变单调用语义）。
var g_meta_concurrency: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

/// 由 decoder.Info 填充 ZkMetaInfo（tags/封面指针指向句柄生命周期内存）
fn fillMetaInfo(info: decoder.Info, tags: []engine.ZkTag) engine.ZkMetaInfo {
    const m = info.metadata;
    const cover = if (info.pictures.len > 0) info.pictures[0] else null;
    return .{
        .sample_rate = @intCast(info.sample_rate),
        .channels = @intCast(info.channels),
        .bits_per_sample = @intCast(info.bits_per_sample),
        .duration_us = info.duration_us,
        .duration_known = switch (info.duration_known) {
            .exact => 0,
            .estimate => 1,
            .unknown => 2,
        },
        .codec_name = info.codec_name.ptr,
        .format_name = info.format_name.ptr,
        .profile = if (info.profile) |p| p.ptr else null,
        .title = if (m.title) |s| s.ptr else null,
        .artist = if (m.artist) |s| s.ptr else null,
        .album = if (m.album) |s| s.ptr else null,
        .date = if (m.date) |s| s.ptr else null,
        .genre = if (m.genre) |s| s.ptr else null,
        .comment = if (m.comment) |s| s.ptr else null,
        .tags = if (tags.len > 0) tags.ptr else null,
        .tags_count = @intCast(tags.len),
        .cover_mime = if (cover) |c| (if (c.mime.len > 0) c.mime.ptr else null) else null,
        .cover_mime_len = if (cover) |c| @intCast(c.mime.len) else 0,
        .cover_data = if (cover) |c| (if (c.data.len > 0) c.data.ptr else null) else null,
        .cover_size = if (cover) |c| @intCast(c.data.len) else 0,
    };
}

/// 打开元数据句柄（probe+open，不解码 PCM）。失败返回 null 并写 errbuf 状态码。
export fn zk_metadata_open(
    path: [*:0]const u8,
    out: *engine.ZkMetaInfo,
    errbuf: [*]u8,
    errbuf_size: c_int,
) ?*MetaHandle {
    const gpa = std.heap.c_allocator;
    var info: decoder.Info = undefined;
    var opened = engine.openMetadata(std.mem.span(path), &info) catch |e| {
        engine.fillErrBuf(errbuf, errbuf_size, e);
        return null;
    };
    errdefer opened.deinit();

    const src = info.metadata.tags;
    const tags = gpa.alloc(engine.ZkTag, src.len) catch {
        fillErrStatus(errbuf, if (errbuf_size > 0) @intCast(errbuf_size) else 0, @intFromEnum(err.Status.out_of_memory));
        return null;
    };
    for (tags, src) |*zt, t| {
        zt.* = .{
            .key = if (t.key.len > 0) t.key.ptr else null,
            .key_len = @intCast(t.key.len),
            .value = if (t.value.len > 0) t.value.ptr else null,
            .value_len = @intCast(t.value.len),
        };
    }

    const h = gpa.create(MetaHandle) catch {
        gpa.free(tags);
        return null;
    };
    h.* = .{ .opened = opened, .tags = tags };
    out.* = fillMetaInfo(info, tags);
    return h;
}

/// 释放元数据句柄（含 probe-only 会话/回退解码器与 tags 数组）。
export fn zk_metadata_close(h: ?*MetaHandle) void {
    const x = h orelse return;
    if (x.tags.len > 0) std.heap.c_allocator.free(x.tags);
    x.opened.deinit();
    std.heap.c_allocator.destroy(x);
}

/// scanner 按自身指标协商并发提示（0 = 未设/自动）。
export fn zk_metadata_set_concurrency(n: c_int) void {
    g_meta_concurrency.store(if (n < 0) 0 else @intCast(n), .release);
}

/// 回读当前并发提示（scanner 校验/内核调试用）。
export fn zk_metadata_get_concurrency() c_int {
    return @intCast(g_meta_concurrency.load(.acquire));
}

// ---------------------------------------------------------------------------
// 流式会话 FFI（§6.3 朝播放迁池：句柄常驻、逐块拉取、池内执行、表面同步）
// ---------------------------------------------------------------------------

/// 流式会话句柄（host + 会话壳）
const Stream = struct {
    host: *khost.Host,
    s: *session.Session,
};

fn fillErrStatus(buf: [*]u8, buf_size: usize, status: c_int) void {
    if (buf_size < 4) return;
    std.mem.writeInt(c_int, @ptrCast(buf[0..4]), status, .little);
}

/// 打开流式会话（在池 worker 上 probe+open 一次）。失败返回 NULL 并写 errbuf。
/// F9：先经 `host.streamOpen()` 做 §6.3 max_streams 硬计数——已达上限直接返回 NULL
/// （不改 errbuf；语义等同 InstanceLimit）。此后任一失败路径都会 `streamClose()` 回补；
/// 成功返回的 Stream 持有一个计数，须由 `zk_engine_close` 归还。
/// worker 亲和（1 流 pinned 1 worker）与 ring 直推仍属 C 壳接线期（§6.3），此处为
/// 分块串行会话 + 硬计数簿记。
export fn zk_engine_open(
    h: ?*khost.Host,
    path: [*:0]const u8,
    info: ?*engine.ZkInfo,
    errbuf: [*]u8,
    errbuf_size: usize,
) ?*Stream {
    const host = h orelse return null;
    if (!host.streamOpen()) return null; // max_streams 满 → InstanceLimit（errbuf 语义不变）
    const sess = session.Session.create(std.heap.c_allocator, std.mem.span(path)) catch {
        host.streamClose();
        return null;
    };
    const st = std.heap.c_allocator.create(Stream) catch {
        std.heap.c_allocator.destroy(sess);
        host.streamClose();
        return null;
    };
    st.* = .{ .host = host, .s = sess };
    if (!sess.start(host.rt)) {
        std.heap.c_allocator.destroy(sess);
        std.heap.c_allocator.destroy(st);
        host.streamClose();
        return null;
    }
    task.wait(&sess.step);
    if (sess.state != session.SessState.playing) {
        if (info) |zi| {
            zi.* = std.mem.zeroes(engine.ZkInfo);
        }
        fillErrStatus(errbuf, errbuf_size, @intFromEnum(err.statusOf(sess.step.err orelse error.DecodeFailed)));
        std.heap.c_allocator.destroy(sess);
        std.heap.c_allocator.destroy(st);
        host.streamClose();
        return null;
    }
    if (info) |zi| fillZkInfoMinimal(zi, sess.info);
    return st;
}

/// 逐步拉块解码到 out（float32 交错，最多 max_frames 帧）。返回 >=0 帧数（0=EOF）；
/// <0 = -ZkStatus。
export fn zk_engine_read(
    h: ?*Stream,
    out: [*]f32,
    max_frames: usize,
    out_channels: *c_int,
) isize {
    const st = h orelse return -@as(isize, @intFromEnum(err.Status.io_error));
    const sess = st.s;
    const ch = sess.info.channels;
    out_channels.* = @intCast(ch);
    const bytes_per = @as(usize, sess.info.bits_per_sample) / 8;
    if (ch == 0 or bytes_per == 0) return -@as(isize, @intFromEnum(err.Status.corrupt));
    const frame_bytes: usize = @as(usize, ch) * bytes_per;

    var raw: [65536]u8 = undefined;
    var produced: usize = 0;
    while (produced < max_frames) {
        const room = raw.len / frame_bytes;
        const chunk = @min(@min(room, max_frames - produced), @as(usize, 4096));
        if (chunk == 0) break;
        if (!sess.read(st.host.rt, raw[0 .. chunk * frame_bytes], chunk)) {
            return -@as(isize, @intFromEnum(err.Status.io_error));
        }
        task.wait(&sess.step);
        if (sess.state != session.SessState.playing) {
            const code = @intFromEnum(err.statusOf(sess.step.err orelse error.DecodeFailed));
            return -@as(isize, code);
        }
        const n = sess.got_frames;
        if (n == 0) break;
        const samples = n * @as(usize, ch);
        _ = convert.toFloat(
            out[produced * @as(usize, ch) ..][0..samples],
            raw[0 .. n * frame_bytes],
            sess.info.bits_per_sample,
            sess.info.is_float,
            endianOfCodec(sess.info.codec_name),
        );
        produced += n;
        if (n < chunk) break; // EOF
    }
    return @intCast(produced);
}

/// 跳到毫秒位置；0 = 成功，非 0 = ZkStatus。
export fn zk_engine_seek_ms(st: ?*Stream, ms: i64) c_int {
    const s = (st orelse return @intFromEnum(err.Status.io_error));
    const sess = s.s;
    if (!sess.seekMs(s.host.rt, ms)) return @intFromEnum(err.Status.io_error);
    task.wait(&sess.step);
    if (sess.state != session.SessState.playing) {
        return @intFromEnum(err.statusOf(sess.step.err orelse error.DecodeFailed));
    }
    return 0;
}

/// 当前播放位置（毫秒）。
export fn zk_engine_position_ms(st: ?*Stream) i64 {
    const s = st orelse return 0;
    if (s.s.dec) |*d| return d.positionMs();
    return 0;
}

/// 关闭会话（池内释放实例并 join 收尾）；st 为 NULL 时空操作。
/// F9：归还打开时占用的流计数（`host.streamClose()`），须在销毁 Stream 前调用。
export fn zk_engine_close(st: ?*Stream) void {
    const s = st orelse return;
    if (s.s.state == session.SessState.playing or s.s.state == session.SessState.new) {
        _ = s.s.close(s.host.rt);
        task.wait(&s.s.step);
    }
    s.s.deinit(); // Session.deinit 自释放会话壳
    s.host.streamClose();
    std.heap.c_allocator.destroy(s);
}

test {
    // 聚合本文件与全部子模块的测试（decoder/fmt 随 e3 引入）
    std.testing.refAllDecls(@This());
    _ = @import("error.zig");
    _ = @import("io.zig");
    _ = @import("registry.zig");
    _ = @import("tables.zig");
    _ = @import("task.zig");
    _ = @import("session.zig");
    _ = @import("khost.zig");
    _ = @import("runtime.zig");
    _ = @import("probe.zig");
    _ = @import("decoder.zig");
    _ = @import("fmt/wav/gsm.zig");
    _ = @import("fmt/wav/mace.zig");
    _ = @import("fmt/wav/lib.zig");
    _ = @import("fmt/flac/crc.zig");
    _ = @import("fmt/flac/bitreader.zig");
    _ = @import("fmt/flac/streaminfo.zig");
    _ = @import("fmt/flac/frame.zig");
    _ = @import("fmt/flac/residual.zig");
    _ = @import("fmt/flac/subframe.zig");
    _ = @import("fmt/flac/lib.zig");
    _ = @import("fmt/alac/bitreader.zig");
    _ = @import("fmt/alac/lib.zig");
    _ = @import("fmt/m4a.zig");
    _ = @import("fmt/als/core.zig");
    _ = @import("fmt/als/tables.zig");
    _ = @import("fmt/als/lib.zig");
    _ = @import("fmt/mp3/layer12.zig");
    _ = @import("fmt/mp3/layer3_tables.zig");
    _ = @import("fmt/mp3/huffman_tables.zig");
    _ = @import("fmt/mp3/header.zig");
    _ = @import("fmt/mp3/bitreader.zig");
    _ = @import("fmt/mp3/id3.zig");
    _ = @import("fmt/aac/bitreader.zig");
    _ = @import("fmt/aac/tables.zig");
    _ = @import("fmt/aac/huffman_tables.zig");
    _ = @import("fmt/aac/rt_tables.zig");
    _ = @import("fmt/aac/asc.zig");
    _ = @import("fmt/aac/mdct_tables.zig");
    _ = @import("fmt/aac/mdct.zig");
    _ = @import("fmt/aac/sbr_tables.zig");
    _ = @import("fmt/aac/sbr_huff.zig");
    _ = @import("fmt/aac/ps_tables.zig");
    _ = @import("fmt/aac/ps_huff.zig");
    _ = @import("fmt/aac/ps.zig");
    _ = @import("fmt/aac/sbr.zig");
    _ = @import("fmt/aac/lib.zig");
    _ = @import("fmt/adts.zig");
    _ = @import("fmt/latm.zig");
    _ = @import("fmt/mp3/synth.zig");
    _ = @import("fmt/mp3/layer3.zig");
    _ = @import("fmt/mp3/lib.zig");
    _ = @import("fmt/wv/bitreader.zig");
    _ = @import("fmt/wv/lib.zig");
    _ = @import("fmt/ape/bitreader.zig");
    _ = @import("fmt/ape/rangecoder.zig");
    _ = @import("fmt/ape/predictor.zig");
    _ = @import("fmt/ape/container.zig");
    _ = @import("fmt/ape/lib.zig");
    _ = @import("fmt/ogg.zig");
    _ = @import("fmt/opus/header.zig");
    _ = @import("fmt/opus/packet.zig");
    _ = @import("fmt/opus/rc.zig");
    _ = @import("fmt/opus/fft.zig");
    _ = @import("fmt/opus/pvq.zig");
    _ = @import("fmt/opus/celt_tables.zig");
    _ = @import("fmt/opus/celt_types.zig");
    _ = @import("fmt/opus/celt.zig");
    _ = @import("fmt/ac3/tables.zig");
    _ = @import("fmt/ac3/ctx.zig");
    _ = @import("fmt/ac3/bitalloc.zig");
    _ = @import("fmt/ac3/exponents.zig");
    _ = @import("fmt/ac3/coupling.zig");
    _ = @import("fmt/ac3/mantissa.zig");
    _ = @import("fmt/ac3/downmix.zig");
    _ = @import("fmt/ac3/header.zig");
    _ = @import("fmt/ac3/kbdwin.zig");
    _ = @import("fmt/ac3/lib.zig");
    _ = @import("fmt/wma/asf.zig");
    _ = @import("fmt/wma/packets.zig");
    _ = @import("fmt/wma/wma_mdct_tables.zig");
    _ = @import("fmt/wma/wma_mdct.zig");
    _ = @import("fmt/wma/wmadata.zig");
    _ = @import("fmt/wma/wmadec.zig");
    _ = @import("fmt/wma/wmapro/mdct_tables.zig");
    _ = @import("fmt/wma/wmapro/mdct.zig");
    _ = @import("fmt/wma/wmapro/tables.zig");
    _ = @import("fmt/wma/wmapro/core.zig");
    _ = @import("fmt/wma/wmapro/lib.zig");
    _ = @import("fmt/wma/wmavoice/tables.zig");
    _ = @import("fmt/wma/wmavoice/bitio.zig");
    _ = @import("fmt/wma/wmavoice/tx.zig");
    _ = @import("fmt/wma/wmavoice/dsp.zig");
    _ = @import("fmt/wma/wmavoice/core.zig");
    _ = @import("fmt/wma/wmavoice/lib.zig");
    _ = @import("fmt/mlp/tables.zig");
    _ = @import("fmt/mlp/ctx.zig");
    _ = @import("fmt/mlp/lib.zig");
    _ = @import("fmt/dts/tables.zig");
    _ = @import("fmt/dts/header.zig");
    _ = @import("fmt/dts/dca_tables.zig");
    _ = @import("fmt/dts/huff_tables.zig");
    _ = @import("fmt/dts/huff.zig");
    _ = @import("fmt/dts/dsp.zig");
    _ = @import("fmt/dts/core.zig");
    _ = @import("fmt/dts/lib.zig");
    _ = @import("fmt/mka/ebml.zig");
    _ = @import("fmt/mka/lib.zig");
    _ = @import("fmt/mpc/tables.zig");
    _ = @import("fmt/mpc/vlc.zig");
    _ = @import("fmt/mpc/synth.zig");
    _ = @import("fmt/mpc/sv8.zig");
    _ = @import("fmt/mpc/sv7.zig");
    _ = @import("fmt/mpc/lib.zig");
    _ = @import("fmt/tta/core.zig");
    _ = @import("fmt/tta/lib.zig");
    _ = @import("fmt/spx/decode.zig");
    _ = @import("fmt/spx/data.zig");
    _ = @import("fmt/spx/lib.zig");
    _ = @import("fmt/shn/core.zig");
    _ = @import("fmt/shn/lib.zig");
    _ = @import("fmt/tak/tables.zig");
    _ = @import("fmt/tak/core.zig");
    _ = @import("fmt/tak/lib.zig");
    _ = @import("fmt/amrwb/tables.zig");
    _ = @import("fmt/amrwb/dsp.zig");
    _ = @import("fmt/amrwb/codec.zig");
    _ = @import("fmt/amrwb/lib.zig");
    _ = @import("pcm/convert.zig");
    _ = @import("engine.zig");
}
