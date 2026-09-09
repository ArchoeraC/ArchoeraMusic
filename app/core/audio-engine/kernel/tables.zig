// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! 调度簿记内部表（docs/engine-master-pool-design.md §5 / §6.2）
//!
//! 两套"格子"的分工（§5，避免混淆）：
//!   - `WorkerTable`（worker 状态注册表，键 = worker/线程）：state / idle_since /
//!     reclaimable / task_ref / class / waiting。**该 worker 独占写**（单写者），Master
//!     只读聚合 → 回收决策与空闲集合查询；
//!   - `SlotTable`（槽位表，键 = 任务执行位）：{task_ref, epoch}。槽位固定、线程可换 →
//!     派发与重派（换线程不换槽，§6.2）。
//!
//! 范围（用户定 2026-09-09）：**数据结构 + 单测，不接调度**。字段当前为普通内存——
//! 生产接线时按 §5「每格自写 + Master 读」改为单写者原子/无锁语义，并并入 kernel_init
//! 定容预分配（§5.4 no-alloc）。本文件固定容量由调用方 allocator 提供。

const std = @import("std");

/// worker 当前状态（§5 记录字段草案）
pub const WState = enum(u8) {
    idle,
    busy,
    retiring,
};

/// worker 任务类（§5.5：pinned = 挂着长流/播放；elastic = 短任务或空闲，参与伸缩）
pub const Class = enum(u8) {
    pinned,
    elastic,
};

/// worker 状态注册表一格（§5：该 worker 独占写，Master 只读聚合）
pub const WorkerEntry = struct {
    state: WState = .idle,
    /// 进入 idle 的时刻（µs 时钟源由调用方定；回收判据之一，§5.1 兜底）
    idle_since_us: u64 = 0,
    /// 是否可回收（pinned 及总量 ≤ min_floor 之下为 false）
    reclaimable: bool = true,
    /// 当前绑定任务（句柄；长流会话常驻）
    task_ref: ?u32 = null,
    /// pinned = 长流/播放会话；elastic = 短任务或空闲
    class: Class = .elastic,
    /// pinned 会话在合法消费等待/暂停中置位（§5.2 层2：停滞判定须排除）
    waiting: bool = false,

    /// worker 自提交：开工（§5.1 state 先行更新——先 busy 再执行）
    pub fn beginBusy(self: *WorkerEntry, task_ref: u32, class: Class) void {
        self.state = .busy;
        self.task_ref = task_ref;
        self.class = class;
        self.waiting = false;
    }

    /// worker 自提交：开工但未绑定任务句柄（runtime 通用 Job 层用；task 接线后走 beginBusy）
    pub fn markBusy(self: *WorkerEntry) void {
        self.state = .busy;
        self.waiting = false;
    }

    /// worker 自提交：转空闲（§5.1：先置 idle + idle_since 再进 cv）
    pub fn beginIdle(self: *WorkerEntry, now_us: u64) void {
        self.state = .idle;
        self.idle_since_us = now_us;
        self.task_ref = null;
        self.class = .elastic;
        self.waiting = false;
    }

    /// worker 自提交：将退役（收尾后从线程函数返回，不自杀；Master join）
    pub fn beginRetiring(self: *WorkerEntry) void {
        self.state = .retiring;
        self.reclaimable = false;
    }

    /// Master 只读判定：是否进入回收候选（state==idle 且可回收，busy/pinned 永不入）
    pub fn isReclaimCandidate(self: *const WorkerEntry) bool {
        return self.state == .idle and self.reclaimable;
    }
};

/// 聚合摘要（Master 每次事件唤醒/带超时到点时的 O(1) 读，§5.5 调节器输入）
pub const Summary = struct {
    idle: usize = 0,
    busy: usize = 0,
    retiring: usize = 0,
    pinned: usize = 0,
    /// 最老空闲 worker 下标（无空闲 = null）
    oldest_idle: ?usize = null,
};

/// worker 状态注册表：集中一块，每 worker 一格
pub const WorkerTable = struct {
    entries: []WorkerEntry,

    pub fn init(allocator: std.mem.Allocator, cap: usize) !WorkerTable {
        const entries = try allocator.alloc(WorkerEntry, cap);
        @memset(entries, .{});
        return .{ .entries = entries };
    }

    pub fn deinit(self: *WorkerTable, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        self.entries = &.{};
    }

    pub fn len(self: *const WorkerTable) usize {
        return self.entries.len;
    }

    /// 只读聚合（原子读/位图语义生产接线时落；骨架为单线程确定性扫描）
    pub fn summarize(self: *const WorkerTable) Summary {
        var s = Summary{};
        for (self.entries, 0..) |*e, i| {
            switch (e.state) {
                .idle => {
                    s.idle += 1;
                    if (s.oldest_idle == null or e.idle_since_us < self.entries[s.oldest_idle.?].idle_since_us) {
                        s.oldest_idle = i;
                    }
                },
                .busy => s.busy += 1,
                .retiring => s.retiring += 1,
            }
            if (e.class == .pinned) s.pinned += 1;
        }
        return s;
    }
};

/// 槽位一格（任务执行位；槽固定、线程可换，§6.2）
pub const SlotEntry = struct {
    task_ref: ?u32 = null,
    /// 世代号：换线程不换槽时递增，旧线程凭 epoch 检测自己被解绑（§6.2 一致性）
    epoch: u32 = 0,
    /// 是否已被占用（acquire 预留即置位；未绑任务 = 保留位，满即拒面计数）
    occupied: bool = false,
};

/// 槽位表：固定任务位，容量即并发上限（§5.5 S = max_streams + max_cap_elastic）
pub const SlotTable = struct {
    slots: []SlotEntry,

    pub fn init(allocator: std.mem.Allocator, cap: usize) !SlotTable {
        const slots = try allocator.alloc(SlotEntry, cap);
        @memset(slots, .{});
        return .{ .slots = slots };
    }

    pub fn deinit(self: *SlotTable, allocator: std.mem.Allocator) void {
        allocator.free(self.slots);
        self.slots = &.{};
    }

    /// 取一个空闲槽并**预留**（确定性：最低空闲位；满 = null → InstanceLimit 面，§5.4 满即拒）。
    /// 预留后须在临界区立即 bind(task_ref) 或 unbind 归还。
    pub fn acquire(self: *SlotTable) ?usize {
        for (self.slots, 0..) |*sl, i| {
            if (!sl.occupied) {
                sl.occupied = true;
                return i;
            }
        }
        return null;
    }

    /// 绑定任务到已预留槽（Master 写），返回新 epoch（线程开工前先写槽再写自身 busy，§6.2）
    pub fn bind(self: *SlotTable, idx: usize, task_ref: u32) u32 {
        std.debug.assert(self.slots[idx].occupied);
        const sl = &self.slots[idx];
        sl.task_ref = task_ref;
        sl.epoch +%= 1;
        return sl.epoch;
    }

    /// 归还槽（卡死重派/任务完成：清 task_ref、释放预留，槽空可再 acquire，§6.2）
    pub fn unbind(self: *SlotTable, idx: usize) ?u32 {
        const sl = &self.slots[idx];
        const t = sl.task_ref;
        sl.task_ref = null;
        sl.occupied = false;
        return t;
    }

    pub fn isBound(self: *const SlotTable, idx: usize) bool {
        return self.slots[idx].task_ref != null;
    }

    pub fn isOccupied(self: *const SlotTable, idx: usize) bool {
        return self.slots[idx].occupied;
    }
};

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "tables: worker 生命周期过渡与聚合（busy/idle/retiring/pinned）" {
    var wt = try WorkerTable.init(testing.allocator, 4);
    defer wt.deinit(testing.allocator);

    // 初始全 idle（reclaimable）
    var s = wt.summarize();
    try testing.expectEqual(@as(usize, 4), s.idle);
    try testing.expectEqual(@as(usize, 0), s.busy);

    // 2 个开工（elastic 短任务），1 个变 pinned 长流
    wt.entries[0].beginBusy(10, .elastic);
    wt.entries[1].beginBusy(11, .elastic);
    wt.entries[2].beginBusy(12, .pinned);
    // busy 永不入回收候选
    try testing.expect(!wt.entries[0].isReclaimCandidate());

    s = wt.summarize();
    try testing.expectEqual(@as(usize, 1), s.idle);
    try testing.expectEqual(@as(usize, 3), s.busy);
    try testing.expectEqual(@as(usize, 1), s.pinned);

    // pinned 完工回 idle（§5.5：class 回落 elastic）
    wt.entries[2].beginIdle(1000);
    try testing.expectEqual(@as(usize, 0), wt.summarize().pinned);
    try testing.expect(wt.entries[2].isReclaimCandidate());

    // 一个转 retiring（Master 决定回收后）
    wt.entries[0].beginRetiring();
    s = wt.summarize();
    try testing.expectEqual(@as(usize, 1), s.retiring);
    try testing.expect(!wt.entries[0].isReclaimCandidate());

    // oldest_idle 指向最老空闲
    wt.entries[1].beginIdle(5000); // 比 entries[2] 的 1000 更晚
    wt.entries[3].beginIdle(50);
    try testing.expectEqual(@as(?usize, 3), wt.summarize().oldest_idle);
}

test "tables: 槽位 acquire/bind/epoch/unbind 与满即拒" {
    var st = try SlotTable.init(testing.allocator, 3);
    defer st.deinit(testing.allocator);

    _ = st.acquire().?;
    const a = st.acquire().?;
    _ = st.acquire().?;
    try testing.expect(st.acquire() == null); // 满（3/3 已取）

    const e1 = st.bind(a, 101);
    try testing.expect(st.isBound(a));
    // 换线程不换槽：同槽重派（epoch 递增，旧线程可检测解绑）
    const e2 = st.bind(a, 102);
    try testing.expect(e2 != e1);
    try testing.expectEqual(@as(?u32, 102), st.slots[a].task_ref);

    // 卡死重派：解绑 → 槽空 → 可再 acquire
    try testing.expectEqual(@as(?u32, 102), st.unbind(a));
    try testing.expect(!st.isBound(a));
    _ = st.acquire().?;
}
