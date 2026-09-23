// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

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
pub const dsp = @import("dsp/lib.zig");

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

/// 从内存字节切片打开解码器（纯内存源，docs/audio-memory-source.md §7）。
/// 契约同 [zk_decoder_open]；`data` 所有权归调用方，须覆盖解码会话生命周期。
export fn zk_decoder_open_mem(
    data: [*]const u8,
    len: usize,
    info: *engine.ZkInfo,
    errbuf: [*]u8,
    errbuf_size: c_int,
) ?*engine.Engine {
    return engine.zkOpenMem(data, len, info, errbuf, errbuf_size);
}

/// 从 C 回调流打开解码器（在线流式源；宿主注入 read/seek，内核零网络栈）。
/// 契约同 [zk_decoder_open]；ctx 与回调生命周期归调用方，须覆盖解码会话。
export fn zk_decoder_open_cb(
    ctx: ?*anyopaque,
    on_read: ?engine.CReadFn,
    on_seek: ?engine.CSeekFn,
    size_hint: c_ulonglong,
    info: *engine.ZkInfo,
    errbuf: [*]u8,
    errbuf_size: c_int,
) ?*engine.Engine {
    const read_fn = on_read orelse {
        engine.fillErrBuf(errbuf, errbuf_size, error.OpenFailed);
        return null;
    };
    const seek_fn = on_seek orelse {
        engine.fillErrBuf(errbuf, errbuf_size, error.OpenFailed);
        return null;
    };
    return engine.zkOpenCallback(ctx, read_fn, seek_fn, @intCast(size_hint), info, errbuf, errbuf_size);
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
// DSP 下沉 FFI（docs/audio-kernel-zig.md §14；扩张计划方向① 地基）
//
// C 壳 equalizer.c / limiter.c / loudness.c 优先路由本内核实现；内核库缺失
// （C 侧 HAS_ARCHOERA_KERNEL 未定义）或 create 失败时回退 C 实现。
// 对外 C 头契约见 include/kernel_bridge.h；Dart 侧 libfft.so ABI 不受影响
// （fft/resampler/tempo 本轮仅内核侧接口占位，未导出任何符号）。
// ---------------------------------------------------------------------------

/// 均衡器句柄（C 侧 `ZkDspEq`）；非法参数 / OOM 返回 NULL（C 壳回退）。
export fn zk_dsp_eq_create(sample_rate: c_int, channels: c_int) ?*dsp.eq.EraEq {
    if (sample_rate <= 0 or channels <= 0 or channels > 64) return null;
    return dsp.eq.era_eq_create(
        std.heap.c_allocator,
        @intCast(sample_rate),
        @intCast(channels),
    ) catch null;
}

/// 设置 10 段增益（dB）；eq/gains 为 NULL 时空操作。
export fn zk_dsp_eq_set_gains(eq: ?*dsp.eq.EraEq, gains: ?[*]const f32) void {
    const e = eq orelse return;
    const g = gains orelse return;
    var arr: [dsp.eq.era_eq_band_count]f32 = undefined;
    for (&arr, 0..) |*v, i| v.* = g[i];
    dsp.eq.era_eq_set_gains(e, arr);
}

/// 设置前级增益（dB）。
export fn zk_dsp_eq_set_preamp(eq: ?*dsp.eq.EraEq, preamp_db: f32) void {
    const e = eq orelse return;
    dsp.eq.era_eq_set_preamp(e, preamp_db);
}

/// 就地处理交错 float32 PCM，samples = 每声道帧数（总样本 = samples×channels）。
export fn zk_dsp_eq_process(eq: ?*dsp.eq.EraEq, pcm: ?[*]f32, samples: c_int) void {
    const e = eq orelse return;
    const p = pcm orelse return;
    if (samples <= 0) return;
    const frames: usize = @intCast(samples);
    dsp.eq.era_eq_process(e, p[0 .. frames * @as(usize, e.channels)], frames);
}

/// 释放均衡器；eq 为 NULL 时空操作。
export fn zk_dsp_eq_destroy(eq: ?*dsp.eq.EraEq) void {
    const e = eq orelse return;
    dsp.eq.era_eq_destroy(e);
}

/// 限幅器句柄（C 侧 `ZkDspLimiter`）；非法参数 / OOM 返回 NULL。
export fn zk_dsp_limiter_create(sample_rate: c_int, channels: c_int) ?*dsp.limiter.EraLimiter {
    if (sample_rate <= 0 or channels <= 0 or channels > 64) return null;
    return dsp.limiter.era_limiter_create(
        std.heap.c_allocator,
        @intCast(sample_rate),
        @intCast(channels),
    ) catch null;
}

/// 启用（enabled != 0）/ 禁用。
export fn zk_dsp_limiter_set_enabled(lim: ?*dsp.limiter.EraLimiter, enabled: c_int) void {
    const l = lim orelse return;
    dsp.limiter.era_limiter_set_enabled(l, enabled != 0);
}

/// 设置阈值（dB）。
export fn zk_dsp_limiter_set_threshold(lim: ?*dsp.limiter.EraLimiter, threshold_db: f32) void {
    const l = lim orelse return;
    dsp.limiter.era_limiter_set_threshold(l, threshold_db);
}

/// 当前阈值（dB）；lim 为 NULL 时返回默认 −1dB。
export fn zk_dsp_limiter_get_threshold(lim: ?*const dsp.limiter.EraLimiter) f32 {
    const l = lim orelse return dsp.limiter.era_limiter_default_threshold_db;
    return dsp.limiter.era_limiter_get_threshold(l);
}

/// 就地处理交错 float32 PCM（samples = 每声道帧数）。
export fn zk_dsp_limiter_process(lim: ?*dsp.limiter.EraLimiter, pcm: ?[*]f32, samples: c_int) void {
    const l = lim orelse return;
    const p = pcm orelse return;
    if (samples <= 0) return;
    const frames: usize = @intCast(samples);
    dsp.limiter.era_limiter_process(l, p[0 .. frames * @as(usize, l.channels)], frames);
}

/// 释放限幅器；lim 为 NULL 时空操作。
export fn zk_dsp_limiter_destroy(lim: ?*dsp.limiter.EraLimiter) void {
    const l = lim orelse return;
    dsp.limiter.era_limiter_destroy(l);
}

/// 响度归一化句柄（C 侧 `ZkDspLoudness`）；非法参数 / OOM 返回 NULL。
export fn zk_dsp_loudness_create(sample_rate: c_int, channels: c_int) ?*dsp.loudness.EraLoudness {
    if (sample_rate <= 0 or channels <= 0 or channels > 64) return null;
    return dsp.loudness.era_loudness_create(
        std.heap.c_allocator,
        @intCast(sample_rate),
        @intCast(channels),
    ) catch null;
}

/// 启用（enabled != 0）/ 禁用。
export fn zk_dsp_loudness_set_enabled(l: ?*dsp.loudness.EraLoudness, enabled: c_int) void {
    const x = l orelse return;
    dsp.loudness.era_loudness_set_enabled(x, enabled != 0);
}

/// 设置目标响度（LUFS）。
export fn zk_dsp_loudness_set_target(l: ?*dsp.loudness.EraLoudness, target_lufs: f32) void {
    const x = l orelse return;
    dsp.loudness.era_loudness_set_target(x, target_lufs);
}

/// 设置预计算增益（dB）。
export fn zk_dsp_loudness_set_gain(l: ?*dsp.loudness.EraLoudness, gain_db: f32) void {
    const x = l orelse return;
    dsp.loudness.era_loudness_set_gain(x, gain_db);
}

/// 就地处理交错 float32 PCM（samples = 每声道帧数）。
export fn zk_dsp_loudness_process(l: ?*dsp.loudness.EraLoudness, pcm: ?[*]f32, samples: c_int) void {
    const x = l orelse return;
    const p = pcm orelse return;
    if (samples <= 0) return;
    const frames: usize = @intCast(samples);
    dsp.loudness.era_loudness_process(x, p[0 .. frames * @as(usize, x.channels)], frames);
}

/// 释放响度实例；l 为 NULL 时空操作。
export fn zk_dsp_loudness_destroy(l: ?*dsp.loudness.EraLoudness) void {
    const x = l orelse return;
    dsp.loudness.era_loudness_destroy(x);
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
        d.frames = decodeInto(d.path, d.out, d.cap_frames, d.info_out, &d.ch);
    }
};

/// 一次「open path → 解至多 cap_frames 帧 float32 交错到 out（含 info 最小字段）」的
/// 公共体：`zk_engine_decode_once`（表面同步）与 `zk_submit_decode`（异步句柄）共用，
/// 保证两路**返回语义/失败状态码单一来源**（§6.1 任务提交面与句柄）。
/// 返回 >=0 实际帧数（0 = EOF）/ <0 = -（enum ZkStatus）；`ch_out` 输出实际声道数。
fn decodeInto(
    path: []const u8,
    out: [*]f32,
    cap_frames: usize,
    info_out: ?*engine.ZkInfo,
    ch_out: *u8,
) isize {
    // path 源 + 空 cb 缓冲 → 与结构化面的 decodeIntoSource 单一实现（避免双份漂移）
    return decodeIntoSource(.{ .path = path }, &.{}, out, cap_frames, info_out, ch_out);
}

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
// 结构化任务提交面（§6.1 任务提交面与句柄；AS1 kind/source/format/hint）
//
// zk_submit（结构化，非阻塞）→ zk_task_wait 完工事件取结果 → zk_task_free。
//   - kind=decode：源 path/mem/cb，解至多 max_frames 帧 float32 交错到 out；
//   - kind=metadata：源 path，probe+open 填 *meta（tags 生命周期同句柄）。
// 复用 khost.Host.submit（定容任务槽，满即拒 = InstanceLimit）与 task.Task 完工
// 事件（**push，无轮询**：Io.Event 阻塞等待，而非轮询 outcome）。句柄 = C `ZkTask`。
// zk_submit_decode 为 kind=decode + source=path 的便捷包装（既有面语义不变）。
// 解码体与 zk_engine_decode_once 共用 decodeInto*（语义/失败状态码单一来源）。
// ---------------------------------------------------------------------------

const SubmitKind = enum(u8) { decode = 0, metadata = 1 };
const SubmitSourceKind = enum(u8) { path = 0, mem = 1, cb = 2 };

/// 与 include/kernel_bridge.h `ZkSubmitReq` 逐字段对齐（extern struct 保证 C ABI）
const CSubmitReq = extern struct {
    kind: c_int,
    source: c_int,
    format_hint: c_uint,
    flags: c_uint,
    path: ?[*:0]const u8,
    data: ?[*]const u8,
    len: usize,
    ctx: ?*anyopaque,
    on_read: ?engine.CReadFn,
    on_seek: ?engine.CSeekFn,
    size_hint: c_ulonglong,
    out: ?[*]f32,
    max_frames: usize,
    out_channels: ?*c_int,
    info: ?*engine.ZkInfo,
    meta: ?*engine.ZkMetaInfo,
    errbuf: ?[*]u8,
    errbuf_size: c_int,
};

/// 源构建结果：cb 源持有 peek 缓冲与适配器析构（任务 free 时 release）。
const SourceBuild = struct {
    source: session.Source = .{ .path = &.{} },
    cb_buffer: []u8 = &.{},
    cb_owner: ?session.CallbackOwner = null,

    fn release(self: *SourceBuild) void {
        if (self.cb_owner) |o| o.destroy(o.ctx, std.heap.c_allocator);
        if (self.cb_buffer.len > 0) std.heap.c_allocator.free(self.cb_buffer);
        self.cb_owner = null;
        self.cb_buffer = &.{};
    }
};

/// 按 source 构建解码源（path/mem/cb）；非法/分配失败返回 null。
fn buildSource(req: *const CSubmitReq) ?SourceBuild {
    switch (req.source) {
        0 => {
            const p = req.path orelse return null;
            return .{ .source = .{ .path = std.mem.span(p) } };
        },
        1 => {
            const d = req.data orelse return null;
            if (req.len == 0) return null;
            return .{ .source = .{ .mem = d[0..req.len] } };
        },
        2 => {
            const c = req.ctx orelse return null;
            const rd = req.on_read orelse return null;
            const sk = req.on_seek orelse return null;
            const adapter = std.heap.c_allocator.create(engine.CbAdapter) catch return null;
            adapter.* = .{ .ctx = c, .c_read = rd, .c_seek = sk };
            const buf = std.heap.c_allocator.alloc(u8, io.peek_buffer_size) catch {
                std.heap.c_allocator.destroy(adapter);
                return null;
            };
            return .{
                .source = .{ .cb = engine.cReaderCallback(adapter, @intCast(req.size_hint)) },
                .cb_buffer = buf,
                .cb_owner = .{ .ctx = @ptrCast(adapter), .destroy = engine.cAdapterDestroy },
            };
        },
        else => return null,
    }
}

/// 从任意源形态（path/mem/cb）打开解码器并解至多 cap_frames 帧到 out。
/// 与 `decodeInto` 共用同一解码/转换语义（返回 >=0 帧数 / <0 = -ZkStatus）。
fn decodeIntoSource(
    src: session.Source,
    cb_buf: []u8,
    out: [*]f32,
    cap_frames: usize,
    info_out: ?*engine.ZkInfo,
    ch_out: *u8,
) isize {
    var zinfo: decoder.Info = undefined;
    var dec: decoder.Decoder = switch (src) {
        .path => |p| decoder.open(std.heap.c_allocator, p, &zinfo) catch |e|
            return -@as(isize, @intFromEnum(err.statusOf(e))),
        .mem => |d| decoder.openMem(std.heap.c_allocator, d, &zinfo) catch |e|
            return -@as(isize, @intFromEnum(err.statusOf(e))),
        .cb => |cb| blk: {
            var reader = io.Reader.openCallback(cb, cb_buf);
            break :blk decoder.openReader(std.heap.c_allocator, &reader, &zinfo) catch |e|
                return -@as(isize, @intFromEnum(err.statusOf(e)));
        },
    };
    defer dec.deinit();

    if (info_out) |zi| fillZkInfoMinimal(zi, zinfo);

    const ch = zinfo.channels;
    const bytes_per = @as(usize, zinfo.bits_per_sample) / 8;
    ch_out.* = ch;
    if (ch == 0 or bytes_per == 0) return -@as(isize, @intFromEnum(err.Status.corrupt));
    const frame_bytes: usize = @as(usize, ch) * bytes_per;
    var raw: [65536]u8 = undefined;
    var produced: usize = 0;
    while (produced < cap_frames) {
        const room_frames = raw.len / frame_bytes;
        const chunk = @min(@min(room_frames, cap_frames - produced), @as(usize, 4096));
        if (chunk == 0) break;
        var c: u8 = 0;
        const n = dec.read(raw[0 .. chunk * frame_bytes], chunk, &c) catch |e|
            return -@as(isize, @intFromEnum(err.statusOf(e)));
        if (n == 0) break;
        const samples = n * @as(usize, c);
        _ = convert.toFloat(
            out[produced * @as(usize, ch) ..][0..samples],
            raw[0 .. n * frame_bytes],
            zinfo.bits_per_sample,
            zinfo.is_float,
            endianOfCodec(zinfo.codec_name),
        );
        produced += n;
        if (n < chunk) break; // EOF
    }
    return @intCast(produced);
}

/// 结构化任务句柄载体（C 侧 `ZkTask`）。生命周期：
/// `zk_submit` 分配（c_allocator）→ `zk_task_wait`（可重复，幂等）→ `zk_task_free`。
/// 源（path/mem/cb）与 out 只存引用，调用方须保证存活到 wait 返回（worker 异步读）。
const SubmitTask = struct {
    task: task.Task = .{ .run = run },
    kind: SubmitKind = .decode,
    build: SourceBuild = .{},
    // kind=decode
    out: [*]f32 = undefined,
    cap_frames: usize = 0,
    out_channels: ?*c_int = null,
    info_out: ?*engine.ZkInfo = null,
    ch: u8 = 0,
    frames: isize = 0,
    // kind=metadata
    meta_out: ?*engine.ZkMetaInfo = null,
    tags: []engine.ZkTag = &.{},
    opened: ?decoder.OpenedMeta = null,
    // 公共：负 ZkStatus（失败）/ 0（成功/进行中）
    status: c_int = 0,

    fn run(t: *task.Task) void {
        const d: *SubmitTask = @fieldParentPtr("task", t);
        switch (d.kind) {
            .decode => {
                d.frames = decodeIntoSource(
                    d.build.source,
                    d.build.cb_buffer,
                    d.out,
                    d.cap_frames,
                    d.info_out,
                    &d.ch,
                );
                if (d.out_channels) |oc| oc.* = @intCast(d.ch);
                if (d.frames < 0) {
                    d.status = @intCast(-d.frames); // 具体码保留，outcome 记 error
                    t.outcome = .failed;
                }
            },
            .metadata => d.runMetadata(t),
        }
    }

    fn runMetadata(self: *SubmitTask, t: *task.Task) void {
        const path = switch (self.build.source) {
            .path => |p| p,
            else => {
                self.status = @intFromEnum(err.Status.unsupported_format);
                t.outcome = .failed;
                return;
            },
        };
        var info: decoder.Info = undefined;
        var opened = engine.openMetadata(path, &info) catch |e| {
            self.status = @intFromEnum(err.statusOf(e));
            t.outcome = .failed;
            return;
        };
        const src = info.metadata.tags;
        const tags = std.heap.c_allocator.alloc(engine.ZkTag, src.len) catch {
            opened.deinit();
            self.status = @intFromEnum(err.Status.out_of_memory);
            t.outcome = .failed;
            return;
        };
        for (tags, src) |*zt, tag| {
            zt.* = .{
                .key = if (tag.key.len > 0) tag.key.ptr else null,
                .key_len = @intCast(tag.key.len),
                .value = if (tag.value.len > 0) tag.value.ptr else null,
                .value_len = @intCast(tag.value.len),
            };
        }
        self.tags = tags;
        self.opened = opened;
        if (self.info_out) |zi| fillZkInfoMinimal(zi, info);
        if (self.meta_out) |m| m.* = fillMetaInfo(info, tags);
    }
};

/// 结构化提交实现（decode/metadata 共用；失败返回 null 并尽力写 errbuf 状态码）。
fn zkSubmitImpl(h: ?*khost.Host, req: ?*const CSubmitReq) ?*SubmitTask {
    const host = h orelse return null;
    const r = req orelse return null;
    if (r.flags != 0) return null; // 保留位：非 0 视为非法
    const kind: SubmitKind = switch (r.kind) {
        0 => .decode,
        1 => .metadata,
        else => return null,
    };
    if (kind == .metadata and r.source != 0) return null; // 元数据仅支持 path 源
    if (kind == .decode) {
        if (r.out == null or r.max_frames == 0) return null;
    } else {
        if (r.meta == null) return null;
    }
    const build = buildSource(r) orelse {
        submitErrOut(r, @intFromEnum(err.Status.io_error));
        return null;
    };
    const d = std.heap.c_allocator.create(SubmitTask) catch {
        var b = build;
        b.release();
        submitErrOut(r, @intFromEnum(err.Status.out_of_memory));
        return null;
    };
    d.* = .{
        .task = .{ .run = SubmitTask.run },
        .kind = kind,
        .build = build,
        .out = r.out orelse undefined,
        .cap_frames = r.max_frames,
        .out_channels = r.out_channels,
        .info_out = r.info,
        .meta_out = r.meta,
    };
    if (host.submit(&d.task) == null) {
        // 池停机 / 任务槽满（满即拒，docs/engine-master-pool-design.md §5.4）
        d.build.release();
        std.heap.c_allocator.destroy(d);
        submitErrOut(r, @intFromEnum(err.Status.io_error));
        return null;
    }
    return d;
}

/// 失败时为提交请求写 errbuf[0..4] = LE ZkStatus（无 errbuf 则仅返回 null）。
fn submitErrOut(req: *const CSubmitReq, status: c_int) void {
    const eb = req.errbuf orelse return;
    if (req.errbuf_size <= 0) return;
    fillErrStatus(eb, @intCast(req.errbuf_size), status);
}

/// 结构化提交（见 include/kernel_bridge.h 契约）。非阻塞；失败返回 null。
export fn zk_submit(h: ?*khost.Host, req: ?*const CSubmitReq) ?*SubmitTask {
    return zkSubmitImpl(h, req);
}

/// 提交一次池内异步解码任务（kind=decode / source=path 的便捷包装，非阻塞；
/// 契约见 include/kernel_bridge.h）。立即返回句柄；失败（h/path/out 为空 /
/// max_frames==0 / 池停机 / 任务槽满 / OOM）返回 null。
export fn zk_submit_decode(
    h: ?*khost.Host,
    path: ?[*:0]const u8,
    out: ?[*]f32,
    max_frames: usize,
    info: ?*engine.ZkInfo,
) ?*SubmitTask {
    const r = CSubmitReq{
        .kind = 0,
        .source = 0,
        .format_hint = 0,
        .flags = 0,
        .path = path,
        .data = null,
        .len = 0,
        .ctx = null,
        .on_read = null,
        .on_seek = null,
        .size_hint = 0,
        .out = out,
        .max_frames = max_frames,
        .out_channels = null,
        .info = info,
        .meta = null,
        .errbuf = null,
        .errbuf_size = 0,
    };
    return zkSubmitImpl(h, &r);
}

/// 等待任务完工（阻塞、无轮询）。返回 >=0 实际帧数（0=EOF；metadata=0）/
/// <0 = -（enum ZkStatus）。完工事件保持置位 → 可重复调用（幂等）；
/// t 为 NULL 返回 -（ZK_IO_ERROR）。
export fn zk_task_wait(t: ?*SubmitTask) c_longlong {
    const d = t orelse return -@as(c_longlong, @intFromEnum(err.Status.io_error));
    task.wait(&d.task);
    return @intCast(d.frames);
}

/// 完工结果（enum ZkSubmitOutcome）；t 为 NULL → PENDING(0)。
export fn zk_task_outcome(t: ?*SubmitTask) c_int {
    const d = t orelse return 0;
    return switch (d.task.outcome) {
        .pending => 0,
        .done => 1,
        .failed => 2,
        .fatal => 3,
    };
}

/// 负 ZkStatus（失败）/ 0（成功或进行中）；t 为 NULL → -（ZK_IO_ERROR）。
export fn zk_task_status(t: ?*SubmitTask) c_int {
    const d = t orelse return -@as(c_int, @intFromEnum(err.Status.io_error));
    return d.status;
}

/// decode 帧数（0=EOF）；非 decode 任务返回 0。
export fn zk_task_frames(t: ?*SubmitTask) c_longlong {
    const d = t orelse return 0;
    return @intCast(d.frames);
}

/// 带超时 wait（毫秒）：1=已完工，0=超时；t 为 NULL → 0。
export fn zk_task_wait_timeout(t: ?*SubmitTask, timeout_ms: c_longlong) c_int {
    const d = t orelse return 0;
    const ms: u64 = if (timeout_ms < 0) 0 else @intCast(timeout_ms);
    const ns = ms * std.time.ns_per_ms;
    return if (task.waitEventTimeout(
        &d.task.event,
        std.Io.Threaded.global_single_threaded.io(),
        ns,
    )) 1 else 0;
}

/// 释放任务句柄（t 为 NULL 时空操作）。内部先 wait 收尾（幂等），未显式 wait 直接
/// free 也不悬垂。**同一句柄只可 free 一次**（重复 free 属未定义行为，契约明确）。
export fn zk_task_free(t: ?*SubmitTask) void {
    const d = t orelse return;
    task.wait(&d.task);
    if (d.opened) |*o| o.deinit();
    if (d.tags.len > 0) std.heap.c_allocator.free(d.tags);
    d.build.release();
    std.heap.c_allocator.destroy(d);
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
    return streamAdopt(host, sess, info, errbuf, errbuf_size, false);
}

/// AS2：打开**专属 worker（pinned 1:1）**流式会话（契约同 [zk_engine_open]）。
/// 会话所有步骤在该 worker 上串行执行、不进全局队列、不参与回收；无空闲 worker 时
/// 自动回退全局队列模式（行为/可用性不变）。`zk_engine_stream_pinned` 可查询是否命中。
export fn zk_engine_open_pinned(
    h: ?*khost.Host,
    path: [*:0]const u8,
    info: ?*engine.ZkInfo,
    errbuf: [*]u8,
    errbuf_size: usize,
) ?*Stream {
    const host = h orelse return null;
    if (!host.streamOpen()) return null;
    const sess = session.Session.create(std.heap.c_allocator, std.mem.span(path)) catch {
        host.streamClose();
        return null;
    };
    return streamAdopt(host, sess, info, errbuf, errbuf_size, true);
}

/// 打开**内存源**流式会话（契约同 [zk_engine_open]）；`data` 所有权归调用方，
/// 须覆盖会话生命周期。内存在池 worker 上经 `decoder.openMem` 解码。
export fn zk_engine_open_mem(
    h: ?*khost.Host,
    data: [*]const u8,
    len: usize,
    info: ?*engine.ZkInfo,
    errbuf: [*]u8,
    errbuf_size: usize,
) ?*Stream {
    const host = h orelse return null;
    if (!host.streamOpen()) return null;
    const sess = session.Session.createMem(std.heap.c_allocator, data[0..len]) catch {
        host.streamClose();
        return null;
    };
    return streamAdopt(host, sess, info, errbuf, errbuf_size, false);
}

/// 打开**宿主回调流**流式会话（契约同 [zk_engine_open]）。`ctx`/回调生命周期归
/// 调用方；内核自持 peek 缓冲，close 时释放（不触碰 ctx）。
export fn zk_engine_open_cb(
    h: ?*khost.Host,
    ctx: ?*anyopaque,
    on_read: ?engine.CReadFn,
    on_seek: ?engine.CSeekFn,
    size_hint: c_ulonglong,
    info: ?*engine.ZkInfo,
    errbuf: [*]u8,
    errbuf_size: usize,
) ?*Stream {
    const host = h orelse return null;
    const c = ctx orelse return null;
    const rd = on_read orelse return null;
    const sk = on_seek orelse return null;
    if (!host.streamOpen()) return null;
    const adapter = std.heap.c_allocator.create(engine.CbAdapter) catch {
        host.streamClose();
        return null;
    };
    adapter.* = .{ .ctx = c, .c_read = rd, .c_seek = sk };
    const sess = session.Session.createCallback(
        std.heap.c_allocator,
        engine.cReaderCallback(adapter, @intCast(size_hint)),
        .{ .ctx = @ptrCast(adapter), .destroy = engine.cAdapterDestroy },
    ) catch {
        std.heap.c_allocator.destroy(adapter);
        host.streamClose();
        return null;
    };
    return streamAdopt(host, sess, info, errbuf, errbuf_size, false);
}

/// 会话建成后的公共收尾：挂 Stream 壳 → 池内 start → 等完工 → info/errbuf。
/// `pinned=true`（AS2）先尝试专属 worker 1:1；无空闲 worker 自动回退全局队列模式，
/// 故默认路径/可用性不受影响。失败统一回补 stream 计数并释放会话壳。
fn streamAdopt(
    host: *khost.Host,
    sess: *session.Session,
    info: ?*engine.ZkInfo,
    errbuf: [*]u8,
    errbuf_size: usize,
    pinned: bool,
) ?*Stream {
    const st = std.heap.c_allocator.create(Stream) catch {
        sess.destroy();
        host.streamClose();
        return null;
    };
    st.* = .{ .host = host, .s = sess };
    var started = false;
    if (pinned) started = sess.startPinned(host.rt);
    if (!started) started = sess.start(host.rt);
    if (!started) {
        sess.destroy();
        std.heap.c_allocator.destroy(st);
        host.streamClose();
        return null;
    }
    task.wait(&sess.step);
    if (sess.state != session.SessState.playing) {
        sess.releasePin(host.rt); // AS2：pinned 启动失败时归还专属 worker
        if (info) |zi| {
            zi.* = std.mem.zeroes(engine.ZkInfo);
        }
        fillErrStatus(errbuf, errbuf_size, @intFromEnum(err.statusOf(sess.step.err orelse error.DecodeFailed)));
        sess.destroy();
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
    if (st.host.isStopping()) return -@as(isize, @intFromEnum(err.Status.io_error));
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
    if (s.host.isStopping()) return @intFromEnum(err.Status.io_error);
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

/// AS2：该流式会话是否命中专属 worker（pinned 1:1）；1 = 是，0 = 否/NULL。
/// 供接线层/测试观测「无空闲 worker 时自动回退全局队列」的命中情况。
export fn zk_engine_stream_pinned(st: ?*Stream) c_int {
    const s = st orelse return 0;
    return if (s.s.isPinned()) 1 else 0;
}

/// 关闭会话（池内释放实例并 join 收尾）；st 为 NULL 时空操作。
/// F9：归还打开时占用的流计数（`host.streamClose()`），须在销毁 Stream 前调用。
export fn zk_engine_close(st: ?*Stream) void {
    const s = st orelse return;
    if (s.host.isStopping()) {
        // 停机后 rt 已不可提交任务：直接释放解码器与会话壳（不再走池任务）
        s.s.releasePin(s.host.rt); // AS2：归还专属 worker（幂等）
        if (s.s.dec) |*d| d.deinit();
        s.s.dec = null;
        s.s.state = .closed;
    } else if (s.s.state == session.SessState.playing or s.s.state == session.SessState.new) {
        _ = s.s.close(s.host.rt);
        task.wait(&s.s.step);
    }
    s.s.deinit(); // Session.deinit 自释放会话壳
    s.host.streamClose(); // 最后一个流关闭时若停机待收尾 → 释放 host/rt
    std.heap.c_allocator.destroy(s);
}

// ---------------------------------------------------------------------------
// 能力扩张 export 扩展锚点（并行开发占位；各方向实现时替换属于自己的锚点）
// 说明：以下四行互不重叠，避免同一文件合并冲突；只替换自己那一个。
// ---------------------------------------------------------------------------
// __KERNEL_DSP_EXT__
// __KERNEL_STREAM_BUDGET__
// __KERNEL_TAKEOVER__
// __KERNEL_ENGINE_STATS__

// ---------------------------------------------------------------------------
// 结构化任务提交面测试（zk_submit_decode / zk_task_wait / zk_task_free）
// ---------------------------------------------------------------------------

const testing = std.testing;

test "zk_submit_decode: submit→wait 帧数/采样率与 sync 一致；重复 wait/free 安全" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_inst = std.Io.Threaded.global_single_threaded.io();
    const full = try engine.writeTestWav(&tmp, io_inst, "submit.wav");
    defer testing.allocator.free(full);

    const h = try khost.Host.init(std.heap.c_allocator, .{ .min_workers = 2, .max_workers = 4, .cap_tasks = 8 });
    defer {
        h.shutdown();
        h.deinit();
    }

    var out: [16]f32 = undefined;
    var info: engine.ZkInfo = undefined;
    const t = zk_submit_decode(h, full.ptr, &out, 8, &info);
    try testing.expect(t != null);
    const n = zk_task_wait(t);
    try testing.expectEqual(@as(c_longlong, 8), n);
    try testing.expectEqual(@as(c_int, 8000), info.sample_rate);
    try testing.expectEqual(@as(c_int, 1), info.channels);
    try testing.expectEqual(@as(c_int, 16), info.bits_per_sample);
    for (0..8) |i| {
        try testing.expectApproxEqAbs(
            @as(f32, @floatFromInt(@as(i16, @intCast(i)))) / 32768.0,
            out[i],
            1e-6,
        );
    }
    // 完工事件保持置位：重复 wait 幂等（与 zk_engine_decode_once 语义一致）
    try testing.expectEqual(@as(c_longlong, 8), zk_task_wait(t));
    zk_task_free(t);
    zk_task_free(null); // NULL 空操作
}

test "zk_submit_decode: 不存在的 path → 负状态码（与 decode_once 对齐）；未 wait 直接 free 安全" {
    const h = try khost.Host.init(std.heap.c_allocator, .{ .min_workers = 1, .max_workers = 2, .cap_tasks = 4 });
    defer {
        h.shutdown();
        h.deinit();
    }
    var out: [8]f32 = undefined;
    const t = zk_submit_decode(h, "/nonexistent/definitely-missing.wav", &out, 8, null);
    try testing.expect(t != null);
    const n = zk_task_wait(t);
    try testing.expectEqual(
        @as(c_longlong, -@as(c_longlong, @intFromEnum(err.Status.open_failed))),
        n,
    );
    zk_task_free(t);

    // 未 wait 直接 free：free 内兜底 wait 收尾，不悬垂
    const t2 = zk_submit_decode(h, "/nonexistent/definitely-missing-2.wav", &out, 8, null);
    try testing.expect(t2 != null);
    zk_task_free(t2);
}

test "zk_submit_decode: 参数非法（h/path/out 空、max_frames=0）→ null" {
    var out: [8]f32 = undefined;
    try testing.expect(zk_submit_decode(null, "x.wav", &out, 8, null) == null);
    const h = try khost.Host.init(std.heap.c_allocator, .{ .min_workers = 1, .max_workers = 1, .cap_tasks = 1 });
    defer {
        h.shutdown();
        h.deinit();
    }
    try testing.expect(zk_submit_decode(h, null, &out, 8, null) == null);
    try testing.expect(zk_submit_decode(h, "x.wav", null, 8, null) == null);
    try testing.expect(zk_submit_decode(h, "x.wav", &out, 0, null) == null);
}

test "zk_submit_decode: 任务槽满（cap=1）→ null（InstanceLimit）；释放后可再提交" {
    const h = try khost.Host.init(std.heap.c_allocator, .{ .min_workers = 1, .max_workers = 1, .cap_tasks = 1 });
    var gate = std.atomic.Value(bool).init(false);
    defer {
        gate.store(true, .release);
        h.shutdown();
        h.deinit();
    }
    // 阻塞任务占满唯一任务槽（完工前槽不释放）
    const Blocker = struct {
        task: task.Task,
        gate: *std.atomic.Value(bool),
        fn body(t: *task.Task) void {
            const self: *@This() = @fieldParentPtr("task", t);
            while (!self.gate.load(.acquire)) std.Thread.yield() catch {};
        }
    };
    var blocker = Blocker{ .task = .{ .run = Blocker.body }, .gate = &gate };
    try testing.expect(h.submit(&blocker.task) != null);

    var out: [8]f32 = undefined;
    // 槽满：zk_submit_decode 分配载体后 submit 失败 → NULL（path 不会被触碰）
    try testing.expect(zk_submit_decode(h, "/nonexistent/whatever.wav", &out, 8, null) == null);

    // 放行 → 槽自动释放 → active 回落 0
    gate.store(true, .release);
    task.wait(&blocker.task);
    try testing.expectEqual(@as(usize, 0), h.active());
}

// ---- AS1 结构化提交面（zk_submit kind/source/format/hint）----

/// 黄金 WAV 字节（8kHz mono i16 0..7，与 engine.writeTestWav 同源）：供 mem/cb 源复用。
fn goldWavBytes() [60]u8 {
    const hdr = [_]u8{
        'R', 'I', 'F', 'F', 0x28, 0, 0, 0, 'W', 'A', 'V', 'E',
        'f', 'm', 't', ' ', 0x10, 0, 0, 0,
        0x01, 0, 0x01, 0, 0x40, 0x1F, 0, 0, 0x00, 0x3E, 0, 0, 0x02, 0, 0x10, 0,
        'd', 'a', 't', 'a', 0x10, 0, 0, 0,
    };
    var b: [60]u8 = undefined;
    @memcpy(b[0..hdr.len], &hdr);
    for (0..8) |i| {
        std.mem.writeInt(i16, b[44 + 2 * i ..][0..2], @as(i16, @intCast(i)), .little);
    }
    return b;
}

/// C 回调源（callconv(.c)，与 zk_read_cb/zk_seek_cb 契约一致）
const SubmitCbCtx = struct {
    data: []const u8,
    pos: usize = 0,

    fn read(ctx: ?*anyopaque, buf: [*]u8, len: usize) callconv(.c) usize {
        const c: *SubmitCbCtx = @ptrCast(@alignCast(ctx.?));
        if (c.pos >= c.data.len) return 0;
        const n = @min(c.data.len - c.pos, len);
        @memcpy(buf[0..n], c.data[c.pos..][0..n]);
        c.pos += n;
        return n;
    }

    fn seek(ctx: ?*anyopaque, off: i64, whence: c_int, buffered: usize) callconv(.c) c_int {
        const c: *SubmitCbCtx = @ptrCast(@alignCast(ctx.?));
        const base: i64 = switch (whence) {
            0 => 0,
            1 => @as(i64, @intCast(c.pos)) - @as(i64, @intCast(buffered)),
            2 => @intCast(c.data.len),
            else => return 0,
        };
        const np = base + off;
        if (np < 0 or np > @as(i64, @intCast(c.data.len))) return 0;
        c.pos = @intCast(np);
        return 1;
    }
};

fn submitReq(comptime kind: c_int, comptime source: c_int) CSubmitReq {
    return .{
        .kind = kind,
        .source = source,
        .format_hint = 0,
        .flags = 0,
        .path = null,
        .data = null,
        .len = 0,
        .ctx = null,
        .on_read = null,
        .on_seek = null,
        .size_hint = 0,
        .out = null,
        .max_frames = 0,
        .out_channels = null,
        .info = null,
        .meta = null,
        .errbuf = null,
        .errbuf_size = 0,
    };
}

fn expectGold(pcm: []const f32) !void {
    for (0..8) |i| {
        try testing.expectApproxEqAbs(
            @as(f32, @floatFromInt(@as(i16, @intCast(i)))) / 32768.0,
            pcm[i],
            1e-6,
        );
    }
}

test "zk_submit: decode 三源（path/mem/cb）逐样本与 sync 一致；outcome/status/frames 对齐" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_inst = std.Io.Threaded.global_single_threaded.io();
    const full = try engine.writeTestWav(&tmp, io_inst, "submit3.wav");
    defer testing.allocator.free(full);
    const gold = goldWavBytes();

    const h = try khost.Host.init(std.heap.c_allocator, .{ .min_workers = 2, .max_workers = 4, .cap_tasks = 8 });
    defer {
        h.shutdown();
        h.deinit();
    }

    // path 源
    {
        var out: [16]f32 = undefined;
        var info: engine.ZkInfo = undefined;
        var oc: c_int = 0;
        var req = submitReq(0, 0);
        req.path = full.ptr;
        req.out = &out;
        req.max_frames = 8;
        req.out_channels = &oc;
        req.info = &info;
        req.format_hint = 0x21; // 仅携带/校验，不影响自动探测
        const t = zk_submit(h, &req);
        try testing.expect(t != null);
        try testing.expectEqual(@as(c_int, 0), zk_task_outcome(t)); // 未 wait → pending
        try testing.expectEqual(@as(c_longlong, 8), zk_task_wait(t));
        try testing.expectEqual(@as(c_int, 1), zk_task_outcome(t)); // done
        try testing.expectEqual(@as(c_int, 0), zk_task_status(t));
        try testing.expectEqual(@as(c_longlong, 8), zk_task_frames(t));
        try testing.expectEqual(@as(c_int, 1), oc);
        try testing.expectEqual(@as(c_int, 8000), info.sample_rate);
        try expectGold(&out);
        try testing.expectEqual(@as(c_int, 1), zk_task_wait_timeout(t, 1000)); // 已完工
        zk_task_free(t);
    }

    // mem 源
    {
        var out: [16]f32 = undefined;
        var req = submitReq(0, 1);
        req.data = &gold;
        req.len = gold.len;
        req.out = &out;
        req.max_frames = 8;
        const t = zk_submit(h, &req);
        try testing.expect(t != null);
        try testing.expectEqual(@as(c_longlong, 8), zk_task_wait(t));
        try testing.expectEqual(@as(c_int, 1), zk_task_outcome(t));
        try expectGold(&out);
        zk_task_free(t);
    }

    // cb 源
    {
        var out: [16]f32 = undefined;
        var cb = SubmitCbCtx{ .data = &gold };
        var req = submitReq(0, 2);
        req.ctx = @ptrCast(&cb);
        req.on_read = SubmitCbCtx.read;
        req.on_seek = SubmitCbCtx.seek;
        req.size_hint = gold.len;
        req.out = &out;
        req.max_frames = 8;
        const t = zk_submit(h, &req);
        try testing.expect(t != null);
        try testing.expectEqual(@as(c_longlong, 8), zk_task_wait(t));
        try testing.expectEqual(@as(c_int, 1), zk_task_outcome(t));
        try expectGold(&out);
        zk_task_free(t);
    }
}

test "zk_submit: metadata kind 池内 probe+open 填 ZkMetaInfo；参数非法 → null + errbuf 状态" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_inst = std.Io.Threaded.global_single_threaded.io();
    const full = try engine.writeTestWav(&tmp, io_inst, "submitmeta.wav");
    defer testing.allocator.free(full);

    const h = try khost.Host.init(std.heap.c_allocator, .{ .min_workers = 1, .max_workers = 2, .cap_tasks = 4 });
    defer {
        h.shutdown();
        h.deinit();
    }

    var meta: engine.ZkMetaInfo = std.mem.zeroes(engine.ZkMetaInfo);
    var info: engine.ZkInfo = undefined;
    var req = submitReq(1, 0);
    req.path = full.ptr;
    req.meta = &meta;
    req.info = &info;
    const t = zk_submit(h, &req);
    try testing.expect(t != null);
    try testing.expectEqual(@as(c_longlong, 0), zk_task_wait(t)); // metadata 无帧
    try testing.expectEqual(@as(c_int, 1), zk_task_outcome(t));
    try testing.expectEqual(@as(c_int, 0), zk_task_status(t));
    try testing.expectEqual(@as(c_int, 8000), meta.sample_rate);
    try testing.expectEqual(@as(c_int, 1), meta.channels);
    try testing.expectEqual(@as(c_int, 8000), info.sample_rate);
    zk_task_free(t);

    // 参数非法：metadata 仅 path 源
    var req_bad = submitReq(1, 1);
    req_bad.meta = &meta;
    try testing.expect(zk_submit(h, &req_bad) == null);
    // flags 非 0 视为非法
    var req_flags = submitReq(0, 0);
    req_flags.path = full.ptr;
    req_flags.out = undefined;
    req_flags.max_frames = 0; // 同时非法也在 flags 前拦下
    req_flags.flags = 1;
    try testing.expect(zk_submit(h, &req_flags) == null);
    // 非法 kind
    var req_kind = submitReq(9, 0);
    try testing.expect(zk_submit(h, &req_kind) == null);
    // 失败时 errbuf 写 LE ZkStatus（io_error=8）
    var req_eb = submitReq(0, 0);
    var eb: [8]u8 = undefined;
    @memset(&eb, 0);
    req_eb.out = null;
    req_eb.max_frames = 0;
    req_eb.errbuf = &eb;
    req_eb.errbuf_size = eb.len;
    // out 为空 → 参数非法（不写 errbuf；此处仅证明返回 null）
    try testing.expect(zk_submit(h, &req_eb) == null);
}

test "zk_submit: 未完工任务 wait_timeout 超时返回 0，放行后返回 1" {
    const h = try khost.Host.init(std.heap.c_allocator, .{ .min_workers = 1, .max_workers = 1, .cap_tasks = 2 });
    var gate = std.atomic.Value(bool).init(false);
    defer {
        gate.store(true, .release);
        h.shutdown();
        h.deinit();
    }
    const Blocker = struct {
        task: task.Task,
        gate: *std.atomic.Value(bool),
        fn body(t: *task.Task) void {
            const self: *@This() = @fieldParentPtr("task", t);
            while (!self.gate.load(.acquire)) std.Thread.yield() catch {};
        }
    };
    var blocker = Blocker{ .task = .{ .run = Blocker.body }, .gate = &gate };
    try testing.expect(h.submit(&blocker.task) != null);

    var out: [8]f32 = undefined;
    var req = submitReq(0, 0);
    req.path = "/nonexistent/queued.wav";
    req.out = &out;
    req.max_frames = 8;
    const t = zk_submit(h, &req);
    try testing.expect(t != null);
    // 唯一 worker 被占 → 短超时必须返回 0（未完工）
    try testing.expectEqual(@as(c_int, 0), zk_task_wait_timeout(t, 30));
    gate.store(true, .release);
    task.wait(&blocker.task);
    try testing.expectEqual(@as(c_int, 1), zk_task_wait_timeout(t, 5000));
    // 排队任务已完工（不存在的路径 → open_failed 负码）
    try testing.expectEqual(
        @as(c_longlong, -@as(c_longlong, @intFromEnum(err.Status.open_failed))),
        zk_task_frames(t),
    );
    try testing.expectEqual(@as(c_int, 2), zk_task_outcome(t)); // failed
    try testing.expectEqual(@as(c_int, @intFromEnum(err.Status.open_failed)), zk_task_status(t));
    zk_task_free(t);
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
    _ = @import("dsp/lib.zig");
}
