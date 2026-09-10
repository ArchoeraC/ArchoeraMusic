// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! 模块注册表（docs/engine-master-pool-design.md §1/§3：Registry = 只读 Module 能力表）
//!
//! 本文件收敛 `decoder.open()` 的硬编码 switch（原 decoder.zig:194-224）为一张
//! **comptime Module 描述符表 + 分派**，作为格式模块的唯一登记点（single source of
//! truth）：
//!   - `Module`：每格式只读能力描述——probe 标签 + `open` 工厂函数指针；
//!   - `modules`：comptime 表（进程内 1 份、只读、任意实例共享）；
//!   - `dispatch(fmt, …)`：按 probe 结果查表 → 调对应模块 open（未登记 = unsupported）。
//!
//! 性质（对齐设计不变量）：
//!   - **模块只读**：表中只有函数指针与标签，零可变成员；
//!   - **实例私有**：`open` 仍由各 fmt 构造私有 ctx（`decoder.Decoder` vtable+ctx），
//!     与注册表无共享可变态；
//!   - **探测在 worker / 调用方侧**：本文件不读文件、不做 probe，只做查表分派——
//!     可被 sync 直通调用线程或未来 Pool worker 驱动，不构成阻塞面；
//!   - **实例簿记（计数 / cap / fd·内存护栏）归 Master**（§5.4：`kernel_init` 定容、
//!     `InstanceLimit`），本步只落 Module 表与分派（纯结构，Phase G §9 ①）。
//!
//! 状态：2026-09-09 落地（decoder.open 巨型 switch → 本表），`zig build test` 全绿为准。

const std = @import("std");
const Error = @import("error.zig").Error;
const io = @import("io.zig");
const probe = @import("probe.zig");
const decoder = @import("decoder.zig");

// ---- 各格式模块（与 fmt/* 一一对应；flat 与 lib 形态统一收口于此）----

const wav = @import("fmt/wav/lib.zig");
const flac = @import("fmt/flac/lib.zig");
const m4a = @import("fmt/m4a.zig");
const mp3 = @import("fmt/mp3/lib.zig");
const wv = @import("fmt/wv/lib.zig");
const ape = @import("fmt/ape/lib.zig");
const opus = @import("fmt/opus/lib.zig");
const vorbis = @import("fmt/vorbis/lib.zig");
const oggflac = @import("fmt/oggflac.zig");
const dsd = @import("fmt/dsd.zig");
const amr = @import("fmt/amr.zig");
const amrwb = @import("fmt/amrwb/lib.zig");
const ac3 = @import("fmt/ac3/lib.zig");
const mlp = @import("fmt/mlp/lib.zig");
const adts = @import("fmt/adts.zig");
const latm = @import("fmt/latm.zig");
const wma = @import("fmt/wma/lib.zig");
const dts = @import("fmt/dts/lib.zig");
const mka = @import("fmt/mka/lib.zig");
const mpc = @import("fmt/mpc/lib.zig");
const spx = @import("fmt/spx/lib.zig");
const shn = @import("fmt/shn/lib.zig");
const tak = @import("fmt/tak/lib.zig");
const tta = @import("fmt/tta/lib.zig");

/// 统一 open 工厂签名（全格式同构：`(allocator, *io.Reader, *Info) → Decoder`）
pub const OpenFn = *const fn (
    allocator: std.mem.Allocator,
    reader: *io.Reader,
    info: *decoder.Info,
) Error!decoder.Decoder;

/// 模块只读能力描述（每格式进程内 1 份）
pub const Module = struct {
    /// probe 标签（probe.Format；同一模块可服务多个标签，如 mlp ↔ truehd）
    fmt: probe.Format,
    /// 工厂：构造该格式实例（实例私有，ctx 归各 fmt 持有）
    open: OpenFn,
    /// 元数据专用工厂（probe-only，§8.4.2①；null = 回退完整 `open`）。
    /// 只解析容器头/标签并持有其分配，不构造解码器状态。
    meta: ?decoder.MetaFn = null,
};

/// mlp.open 声明为推断错误集（未引 error.zig），在此以薄适配器收敛到内核 Error。
/// 若 mlp 实际产出 Error 之外的错误，编译期在此暴露——届时显式标注/分派处理。
fn mlpOpen(allocator: std.mem.Allocator, reader: *io.Reader, info: *decoder.Info) Error!decoder.Decoder {
    return mlp.open(allocator, reader, info);
}

/// 模块登记表（single source of truth，取代 decoder.open 巨型 switch）
pub const modules = [_]Module{
    .{ .fmt = .wav,       .open = wav.open },
    .{ .fmt = .flac,      .open = flac.open, .meta = flac.openMeta },
    .{ .fmt = .m4a,       .open = m4a.open },
    .{ .fmt = .mp3,       .open = mp3.open, .meta = mp3.openMeta },
    .{ .fmt = .wv,        .open = wv.open },
    .{ .fmt = .ape,       .open = ape.open },
    .{ .fmt = .ogg_opus,  .open = opus.open },
    .{ .fmt = .ogg_vorbis,.open = vorbis.open },
    .{ .fmt = .ogg_flac,  .open = oggflac.open },
    .{ .fmt = .ogg_speex, .open = spx.open },
    .{ .fmt = .dsd,       .open = dsd.open },
    .{ .fmt = .amr,       .open = amr.open },
    .{ .fmt = .amrwb,     .open = amrwb.open },
    .{ .fmt = .ac3,       .open = ac3.open },
    .{ .fmt = .mlp,       .open = mlpOpen },
    .{ .fmt = .truehd,    .open = mlpOpen },
    .{ .fmt = .aac,       .open = adts.open }, // ADTS 容器 → fmt/adts
    .{ .fmt = .latm,      .open = latm.open },
    .{ .fmt = .wma,       .open = wma.open },
    .{ .fmt = .dts,       .open = dts.open },
    .{ .fmt = .mka,       .open = mka.open },
    .{ .fmt = .mpc,       .open = mpc.open },
    .{ .fmt = .shn,       .open = shn.open },
    .{ .fmt = .tak,       .open = tak.open },
    .{ .fmt = .tta,       .open = tta.open },
};

/// 按 probe 结果查表分派到模块 open；未登记标签 → unsupported（当前仅 .unknown）。
/// probe 不在本路径（调用方已完成探测），本函数不读文件、不做任何可能阻塞的工作。
pub fn dispatch(
    fmt: probe.Format,
    allocator: std.mem.Allocator,
    reader: *io.Reader,
    info: *decoder.Info,
) Error!decoder.Decoder {
    inline for (modules) |m| {
        if (fmt == m.fmt) return m.open(allocator, reader, info);
    }
    return error.UnsupportedFormat;
}

/// 元数据分派结果：probe-only 会话（有 `meta` 工厂）或回退的完整解码器。
/// 两者均持有 `info` 所指内存；`deinit` 释放。
pub const MetaResult = union(enum) {
    session: decoder.MetadataSession,
    decoder: decoder.Decoder,

    pub fn deinit(self: *MetaResult) void {
        switch (self.*) {
            .session => |s| s.deinit(),
            .decoder => |*d| d.deinit(),
        }
    }
};

/// 元数据专用分派（§8.4.2①）：有 `meta` 工厂走 probe-only；否则回退完整
/// `open`（行为与 `dispatch` 一致，调用方立即释放）。
pub fn dispatchMeta(
    fmt: probe.Format,
    allocator: std.mem.Allocator,
    reader: *io.Reader,
    info: *decoder.Info,
) Error!MetaResult {
    inline for (modules) |m| {
        if (fmt == m.fmt) {
            if (m.meta) |mf| return .{ .session = try mf(allocator, reader, info) };
            return .{ .decoder = try m.open(allocator, reader, info) };
        }
    }
    return error.UnsupportedFormat;
}

test {
    std.testing.refAllDecls(@This());
}

const testing = std.testing;

test "registry: 未登记/未来标签分派安全返回 UnsupportedFormat（不 panic）" {
    // 覆盖 .unknown 及任何未来新增但未登记到 modules 的 Format 标签
    for (std.enums.values(probe.Format)) |f| {
        var dispatched = false;
        inline for (modules) |m| {
            if (f == m.fmt) dispatched = true;
        }
        if (dispatched) continue;
        // 未登记标签：用内存 Reader + 空 Info 走 dispatch，应 error.UnsupportedFormat
        var r = io.Reader.openMem("");
        var info: decoder.Info = undefined;
        try testing.expectError(
            error.UnsupportedFormat,
            dispatch(f, testing.allocator, &r, &info),
        );
    }
}
