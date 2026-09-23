// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

//! 流式 Reader 缓冲策略 / 目标内存预算（docs/audio-kernel-expansion-plan.md §3 N4）
//!
//! 每路 callback Reader 持有一个 peek 缓冲；本模块把「每缓冲字节数」与「进程内
//! 所有 callback 缓冲的已用总字节」收口为**纯原子簿记**（无新同步原语、热路径无锁
//! 竞争点、零堆分配——alloc/free 仍由调用方完成）：
//!   - `usedBytes()`：当前已 acquire 未 release 的字节数（各 callback 缓冲之和）；
//!   - `setBudget()`：目标内存预算（0 = 不限，默认）；超预算 acquire 返回
//!     `error.OutOfMemory`，调用方据此拒绝打开（回退/上报），不静默超配；
//!   - `peekBytes()` / `setPeekBytes()`：每路缓冲目标大小（默认 16 KiB，夹取到
//!     [min_peek_bytes, max_peek_bytes]）——`io.Reader` 以 `buffer.len` 自持，
//!     故变长缓冲天然可用。
//!
//! **默认路径不变**：默认预算不限 + 16 KiB，与既有全局常量 `io.peek_buffer_size`
//! 逐字节一致（acquire 恒成功）。
//!
//! 接线点（三处 callback 缓冲 alloc/free，成对 acquire/release）：
//!   - `engine.zkOpenCallback`（sync 直通）/ `engine.zkClose`；
//!   - `session.createCallback` / `Session.destroy`（池内流式会话）；
//!   - `kernel.buildSource` cb 分支 / `SourceBuild.release`（结构化提交）。

const std = @import("std");
const Error = @import("error.zig").Error;

/// 每路 callback Reader 缓冲默认大小（= io.peek_buffer_size，保持默认逐字节一致）
pub const default_peek_bytes: usize = 16 * 1024;
/// 每路缓冲下限（低于此值失去 peek 意义，夹取到该值）
pub const min_peek_bytes: usize = 16 * 1024;
/// 每路缓冲上限（防误设巨量缓冲；夹取到该值）
pub const max_peek_bytes: usize = 64 * 1024;

/// 已用字节（进程内所有 callback 缓冲，原子累加）
var used_bytes = std.atomic.Value(usize).init(0);
/// 目标预算（0 = 不限；原子读）
var budget_bytes = std.atomic.Value(usize).init(0);
/// 每路缓冲目标大小（原子读；默认 16 KiB）
var peek_bytes = std.atomic.Value(usize).init(default_peek_bytes);

/// 当前已用字节（已 acquire 未 release 的 callback 缓冲之和）。
pub fn usedBytes() usize {
    return used_bytes.load(.acquire);
}

/// 设置目标内存预算；0 = 不限（默认）。仅影响之后的 acquire。
pub fn setBudget(bytes: u64) void {
    if (bytes == 0) {
        budget_bytes.store(0, .release); // 0 = 不限
    } else {
        budget_bytes.store(@intCast(bytes), .release);
    }
}

/// 当前目标内存预算（0 = 不限）。
pub fn budget() usize {
    return budget_bytes.load(.acquire);
}

/// 设置每路 callback 缓冲目标大小；夹取到 [min_peek_bytes, max_peek_bytes]。
/// 仅影响之后新分配的缓冲（已分配者按自身 len 记账/释放）。
pub fn setPeekBytes(bytes: u32) void {
    var v: usize = bytes;
    if (v < min_peek_bytes) v = min_peek_bytes;
    if (v > max_peek_bytes) v = max_peek_bytes;
    peek_bytes.store(v, .release);
}

/// 当前每路 callback 缓冲目标大小。
pub fn peek() usize {
    return peek_bytes.load(.acquire);
}

/// 申请 n 字节（原子累加；超预算回滚并返回 error.OutOfMemory）。
/// 预算为 0（不限）时恒成功。并发下允许瞬时竞态超配，回滚保证账目一致。
pub fn acquire(n: usize) Error!void {
    const prev = used_bytes.fetchAdd(n, .acq_rel);
    const cap = budget_bytes.load(.acquire);
    if (cap != 0 and prev + n > cap) {
        _ = used_bytes.fetchSub(n, .acq_rel);
        return error.OutOfMemory;
    }
}

/// 归还 n 字节（须与某次成功 acquire 的 n 成对）。
pub fn release(n: usize) void {
    if (n == 0) return;
    _ = used_bytes.fetchSub(n, .acq_rel);
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "streambuf: 默认预算不限 + 16 KiB；acquire/release 记账一致" {
    // 默认：预算不限、每路 16 KiB
    try testing.expectEqual(@as(usize, 0), budget());
    try testing.expectEqual(default_peek_bytes, peek());
    setPeekBytes(@intCast(default_peek_bytes)); // 复位（测试间隔离）
    defer {
        setBudget(0);
        setPeekBytes(@intCast(default_peek_bytes));
    }
    // 重新读取基线已用（本进程内其它测试可能已记账，取差值断言）
    const base = usedBytes();
    try acquire(1234);
    try testing.expectEqual(base + 1234, usedBytes());
    release(1234);
    try testing.expectEqual(base, usedBytes());
    // 释放 0 为空操作
    release(0);
    try testing.expectEqual(base, usedBytes());
}

test "streambuf: 预算为 0 = 不限（大额 acquire 成功）" {
    defer setBudget(0);
    setBudget(0);
    try acquire(1 << 20);
    release(1 << 20);
}

test "streambuf: 超预算 acquire 拒绝并回滚（不虚增已用）" {
    defer setBudget(0);
    setBudget(4096);
    const base = usedBytes();
    // 单次超额 → OutOfMemory，账目不变
    try testing.expectError(error.OutOfMemory, acquire(8192));
    try testing.expectEqual(base, usedBytes());
    // 恰好等于预算 → 成功
    try acquire(4096);
    try testing.expectEqual(base + 4096, usedBytes());
    // 预算已用满后再申请 → 拒绝
    try testing.expectError(error.OutOfMemory, acquire(1));
    try testing.expectEqual(base + 4096, usedBytes());
    release(4096);
    try testing.expectEqual(base, usedBytes());
}

test "streambuf: peek 大小夹取到 [16 KiB, 64 KiB]" {
    defer setPeekBytes(@intCast(default_peek_bytes));
    setPeekBytes(1024); // 低于下限 → 夹到下限
    try testing.expectEqual(min_peek_bytes, peek());
    setPeekBytes(1 << 20); // 高于上限 → 夹到上限
    try testing.expectEqual(max_peek_bytes, peek());
    setPeekBytes(32768); // 区间内原样
    try testing.expectEqual(@as(usize, 32768), peek());
}
