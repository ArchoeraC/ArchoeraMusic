// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! 统一错误模型（docs/audio-kernel-zig.md §13.2）
//!
//! 设计要点：
//!   - `Error` 错误集合与设计稿逐字对齐，所有内核模块（io/probe/decoder/fmt/*）
//!     统一使用，保证 FFI 边界（zk_* C ABI，§16）错误映射单一来源；
//!   - `Status` 是稳定数值码（C ABI 返回值），与 `Error` 一一对应，
//!     由 `statusOf` / `errorOf` 双向映射——错误码是跨语言契约，禁止随意改号。

const std = @import("std");

/// 内核统一错误集合（设计稿 §13.2 原文）
pub const Error = error{
    /// 探测失败 / 格式不支持（probe 返回 unsupported → 交由 FFmpeg 主后端，§8.3）
    UnsupportedFormat,
    /// 输入打开失败（文件不存在 / 无权限等）
    OpenFailed,
    /// 容器 / 帧损坏（解析器长度、魔数、校验失败）
    Corrupt,
    /// 解码失败（解码器内部错误）
    DecodeFailed,
    /// 中断：Reader.abort() 被置位（替代 AVIOInterruptCB，§13.1）
    Aborted,
    /// 定位失败
    SeekFailed,
    /// 内存分配失败
    OutOfMemory,
    /// 底层 IO 失败
    IoError,
};

/// 稳定状态码（跨语言契约：`include/kernel_bridge.h` 的 zk_* 返回值，
/// 以及 FFI 层错误上报共用此数值表，禁止随意重排）。
pub const Status = enum(c_int) {
    ok = 0,
    unsupported_format = 1,
    open_failed = 2,
    corrupt = 3,
    decode_failed = 4,
    aborted = 5,
    seek_failed = 6,
    out_of_memory = 7,
    io_error = 8,
};

/// 将 Zig 错误映射为稳定状态码（未在 Error 集合内的错误按 io_error 处理）
pub fn statusOf(err: anyerror) Status {
    return switch (err) {
        error.UnsupportedFormat => .unsupported_format,
        error.OpenFailed => .open_failed,
        error.Corrupt => .corrupt,
        error.DecodeFailed => .decode_failed,
        error.Aborted => .aborted,
        error.SeekFailed => .seek_failed,
        error.OutOfMemory => .out_of_memory,
        error.IoError => .io_error,
        // std 底层错误（AccessDenied/FileNotFound/Unexpected 等）统一归为 io_error，
        // FFI 层只感知聚合后的语义，不泄露底层细节。
        else => .io_error,
    };
}

/// 将稳定状态码映射回 Zig 错误（主要用于读取 C ABI 结果 / 测试往返）
pub fn errorOf(status: Status) Error {
    return switch (status) {
        .ok => unreachable,
        .unsupported_format => error.UnsupportedFormat,
        .open_failed => error.OpenFailed,
        .corrupt => error.Corrupt,
        .decode_failed => error.DecodeFailed,
        .aborted => error.Aborted,
        .seek_failed => error.SeekFailed,
        .out_of_memory => error.OutOfMemory,
        .io_error => error.IoError,
    };
}

/// 人类可读错误消息（供 zk_decoder_open 的 errbuf 诊断，§16.1）
pub fn messageOf(e: anyerror) []const u8 {
    return switch (e) {
        error.UnsupportedFormat => "unsupported or disabled format",
        error.OpenFailed => "failed to open input",
        error.Corrupt => "corrupt container/frame",
        error.DecodeFailed => "decode failed",
        error.Aborted => "operation aborted",
        error.SeekFailed => "seek failed",
        error.OutOfMemory => "out of memory",
        error.IoError => "io error",
        // 底层 std 错误聚合为 io_error（与 statusOf 语义一致）
        else => "io error",
    };
}

test "错误 → 状态码 → 错误 往返一致" {
    const all = [_]Error{
        error.UnsupportedFormat,
        error.OpenFailed,
        error.Corrupt,
        error.DecodeFailed,
        error.Aborted,
        error.SeekFailed,
        error.OutOfMemory,
        error.IoError,
    };
    for (all) |err| {
        try std.testing.expectEqual(err, errorOf(statusOf(err)));
    }
}

test "未知错误聚合为 io_error" {
    try std.testing.expectEqual(Status.io_error, statusOf(error.FileNotFound));
    try std.testing.expectEqual(Status.io_error, statusOf(error.AccessDenied));
}
