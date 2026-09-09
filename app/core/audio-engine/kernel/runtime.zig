// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! 常驻内核 runtime：Master 停机/懒就绪协调 + 同质 worker 池（docs/engine-master-pool-design.md §9 ②）
//!
//! 范围（用户定 2026-09-09：先完整修好内部、测试层可测，不接生产线）：
//!   - `init(cfg)`：bootstrap 同步建 Master 事件线程；`min_workers>0` 同时建对应个
//!     同质 worker（播放档 eager），`min_workers=0` 为懒就绪（§3 启动预算：首个任务由
//!     **Master 事件线程** spawn——§3.1 能力 A：线程创建执行者 = Master async）；
//!   - worker：阻塞在自身 cv 等任务（完成即领），**不自建、不自杀**；
//!   - **弹性扩容（§5.5 骨架）**：backlog 压 worker 时 Master 补建至 `max_workers`（cap），
//!     低负载不扩；worker 状态注册表（tables.WorkerTable）接入：开工 busy/完工 idle 单写自格，
//!     Master/测试 `summarize` 读状态；
//!   - Master：等待「需要补 worker」/「停机」信号；停机时置 worker_shutdown + broadcast，
//!     驱动 worker 收尾；生命周期所有者 = Master；
//!   - `shutdown()`：请求 → join Master → join 全部可 join worker（先排空队列）。
//!
//! 原语（§3 Zig 0.16）：`std.Io` 的 Mutex/Condition *Uncancelable 变体（无取消点）；
//! io 暂取 `Io.Threaded.global_single_threaded`（futex 进程内安全）。每线程独立 Io 由
//! 使用方经 `decoder.openWithIo` 传入（Reader.io 已参数化，io.zig `openPathWith`）。
//! 任务切换只在完全空闲边界（§2.1 run-to-completion）。
//!
//! 边界（留接线期，见 §9 ③④/§5.5 完整调节器）：空闲**回收降容**（backlog 消退后扩出的
//! worker 回落 min_floor）涉及 retiring 协议 + Master join，须与 wait_event/会话接线一并落，
//! 避免本骨架引入稀发竞态。
//!
//! §5.2 层2 停滞兜底（`cfg.stall_timeout_ns > 0` 才启用，默认关 = 行为与纯事件版完全一致）：
//!   - worker 开工写 `started_ns[id]`（单调 ns），完工清零；
//!   - Master 空闲改为带超时 wait（`master_event` + `waitTimeout`，§5.1「零轮询」），超时到点
//!     做停滞扫描：busy 且开工超时的 worker → 判停滞 → **detach 线程句柄**（停机跳过其 join，
//!     绝不 join 卡死线程）+ 复位其 reg/started/inflight + `stall_count` 计数；停滞槽永不复用
//!     （卡死线程可能仍在跑，遗留 OS 线程数 = detach 数，单次可接受并文档化）。
//!   - 被放弃 worker 若任务自返（如 stop 标志任务）：走 workerMain 停滞分支，只销毁自取节点、
//!     置 exited 即退，**不再写任何共享簿记**（Master 已代为收尾）；`shutdown` 对停滞 worker
//!     有界等待其退出，真卡死（永不返）不阻塞、留给宿主 `kernel_shutdown_force` 兜底。

const std = @import("std");
const Thread = std.Thread;
const Io = std.Io;
const tables = @import("tables.zig");

/// runtime 配置
pub const Cfg = struct {
    /// 引导期同步建的 worker 数（>0 = eager；0 = 懒就绪，首任务由 Master spawn）
    min_workers: u16 = 1,
    /// worker 数量上限（定容；§5.4 cap，registry 表容量按此预分配）
    max_workers: u16 = 64,
    /// 每 worker 栈大小（显式设——m4a Debug 曾有约 60MB 栈帧史，勿信默认值）
    stack_size: usize = 16 * 1024 * 1024,
    /// 停滞判定阈值（§5.2 层2）：busy worker 开工超过该时长未完工 → 判停滞并 detach。
    /// 0 = 关闭（默认）：Master 保持纯事件 Condition 等待、零定时器，行为与既往完全一致。
    stall_timeout_ns: u64 = 0,
};

/// 任务（phase ② 通用可执行体；Task/句柄层见 kernel/task.zig，测试与批任务用）
pub const Job = struct {
    run: *const fn (ctx: *anyopaque) void,
    ctx: *anyopaque,
};

const Node = struct {
    job: Job,
    next: ?*Node = null,
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    io: Io,
    cfg: Cfg,

    // ---- 任务队列（worker 自取；完成即领）----
    mutex: Io.Mutex = .init,
    queue_head: ?*Node = null,
    queue_tail: ?*Node = null,
    jobs_avail: Io.Condition = .init,
    /// 在途任务计数（submit +1，worker 跑完 -1；waitIdle 用）
    inflight: usize = 0,
    idle_cv: Io.Condition = .init,

    // ---- Master 协调 ----
    master_mutex: Io.Mutex = .init,
    master_cv: Io.Condition = .init,
    shutdown_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// 请 Master 补建 worker（submit 在积压 > 现 worker 数时置位）
    need_worker: bool = false,
    /// Master 驱动 worker 退出（置位后 worker 收尾返回）
    worker_shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    workers: std.ArrayList(Thread) = .empty,
    master: ?Thread = null,

    /// worker 状态注册表（§5：每 worker 一格、单写者；Master 只读聚合）。
    /// 容量 = cfg.max_workers，init 定容预分配（§5.4 no-alloc）。
    reg: tables.WorkerTable = .{ .entries = &.{} },

    // ---- §5.2 层2 停滞兜底簿记（容量 = cfg.max_workers，init 定容）----
    /// 每 worker 开工时刻（单调 ns；0 = 空闲/未开工）。worker 自写（持锁），Master 扫描读。
    started_ns: []std.atomic.Value(u64) = &.{},
    /// 已被判停滞并 detach 的槽。**永不复用**（卡死线程可能仍在跑）；停机跳过其 join。
    /// 写：Master（scanStalled，持 mutex）；读：worker（持 mutex）/ shutdown（join 后）。
    stalled: []bool = &.{},
    /// worker 自退标记：停滞 worker 返回前置位（最后一条触碰 runtime 的操作）；
    /// `shutdown` 据此有界等待停滞 worker 退出，避免 deinit 后其返回路径碰已释放内存。
    exited: []std.atomic.Value(bool) = &.{},
    /// 停滞放弃计数（测试/可观测）。
    stall_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// Master 带超时兜底唤醒 latch（§5.1：`waitTimeout` + set/reset）。仅
    /// `stall_timeout_ns>0` 时被等待；只有 Master 线程 wait/reset。
    master_event: Io.Event = .unset,

    /// 引导阶段（bootstrap）：建 Master；`cfg.min_workers>0` 时同步建同质 worker。
    pub fn init(allocator: std.mem.Allocator, cfg: Cfg) !*Runtime {
        if (cfg.min_workers > cfg.max_workers) return error.InvalidCfg; // 接线不匹配提前拒
        const self = try allocator.create(Runtime);
        self.* = .{
            .allocator = allocator,
            .io = Io.Threaded.global_single_threaded.io(),
            .cfg = cfg,
        };
        self.workers = std.ArrayList(Thread).empty;
        errdefer {
            // 引导失败：驱动已建 worker 退出并 join（不自建不自杀的收尾）
            self.worker_shutdown.store(true, .release);
            self.ioLockedBroadcastWorkers();
            for (self.workers.items) |w| w.join();
            self.workers.deinit(allocator);
            self.reg.deinit(allocator);
            allocator.free(self.started_ns);
            allocator.free(self.stalled);
            allocator.free(self.exited);
            if (self.master) |m| m.join();
            allocator.destroy(self);
        }
        self.reg = try tables.WorkerTable.init(allocator, cfg.max_workers);
        self.started_ns = try allocator.alloc(std.atomic.Value(u64), cfg.max_workers);
        @memset(self.started_ns, std.atomic.Value(u64).init(0));
        self.stalled = try allocator.alloc(bool, cfg.max_workers);
        @memset(self.stalled, false);
        self.exited = try allocator.alloc(std.atomic.Value(bool), cfg.max_workers);
        @memset(self.exited, std.atomic.Value(bool).init(false));

        // Master 先建（此后线程生命周期归它）
        self.master = try Thread.spawn(.{
            .allocator = allocator,
            .stack_size = cfg.stack_size,
        }, masterMain, .{self});

        if (cfg.min_workers > 0) {
            var i: usize = 0;
            while (i < cfg.min_workers) : (i += 1) {
                try self.appendWorker();
            }
        }
        return self;
    }

    /// 由 Master 事件线程执行的 worker 创建（§3.1：spawn 执行者 = Master async）
    fn appendWorker(self: *Runtime) !void {
        if (self.workers.items.len >= self.cfg.max_workers) return error.OutOfMemory;
        const id = self.workers.items.len;
        const w = try Thread.spawn(.{
            .allocator = self.allocator,
            .stack_size = self.cfg.stack_size,
        }, workerMain, .{ self, id });
        try self.workers.append(self.allocator, w);
    }

    /// 提交任务（非阻塞；OOM 返回 false）。worker 被唤醒自取（完成即领，§5.1）。
    /// 停机后调用 → false（防停机后入队→无 worker→悬挂 inflight 的接线不匹配）。
    pub fn submit(self: *Runtime, job: Job) bool {
        if (self.shutdown_requested.load(.acquire)) return false;
        const node = self.allocator.create(Node) catch return false;
        node.* = .{ .job = job };
        self.mutex.lockUncancelable(self.io);
        // 二次检查（停机竞态窗口内到达也拒绝）
        if (self.shutdown_requested.load(.acquire)) {
            self.mutex.unlock(self.io);
            self.allocator.destroy(node);
            return false;
        }
        const tail = self.queue_tail;
        if (tail) |t| {
            t.next = node;
        } else {
            self.queue_head = node;
        }
        self.queue_tail = node;
        self.inflight += 1;
        const queued_est = self.inflight; // 排队+在途 ≈ backlog 压力
        self.mutex.unlock(self.io);

        // 扩容提示（§5.5 骨架）：未停机且积压 > 现 worker 数且未达上限 → 请 Master 补建
        self.master_mutex.lockUncancelable(self.io);
        const grow = !self.shutdown_requested.load(.acquire) and
            self.workers.items.len < self.cfg.max_workers and
            queued_est > self.workers.items.len;
        if (grow) self.need_worker = true;
        self.master_mutex.unlock(self.io);
        if (grow) {
            Io.Condition.broadcast(&self.master_cv, self.io);
            // timed 兜底模式（stall_timeout_ns>0）：Master 睡在 master_event 上而非 cv
            Io.Event.set(&self.master_event, self.io);
        }

        Io.Condition.signal(&self.jobs_avail, self.io);
        return true;
    }

    /// 阻塞直到在途任务全部完成（进程内等待形态；wait_event 推模式接线时取代）。
    /// worker 对 ctx/reg 的写先于其 `inflight -= 1`（持锁），本函数经同锁 acquire 读。
    pub fn waitIdle(self: *Runtime) void {
        self.mutex.lockUncancelable(self.io);
        while (self.inflight > 0) {
            Io.Condition.waitUncancelable(&self.idle_cv, self.io, &self.mutex);
        }
        self.mutex.unlock(self.io);
    }

    /// 停机：请求 → join Master → join 全部可 join worker。
    /// 停机期可阻塞 join（事件线程已无服务对象；§3.1 能力 A）。已提交任务先排空完成。
    /// §5.2 层2：停滞（已 detach）worker 跳过 join——绝不 join 卡死线程；先有界等待其自退
    /// （stop 标志任务会很快返回并置 exited），真卡死（永不返回）不阻塞、留给宿主
    /// `kernel_shutdown_force` / 进程退出兜底（文档化遗留 OS 线程）。
    pub fn shutdown(self: *Runtime) void {
        if (self.master == null) return;
        self.master_mutex.lockUncancelable(self.io);
        self.shutdown_requested.store(true, .release);
        self.master_mutex.unlock(self.io);
        Io.Condition.broadcast(&self.master_cv, self.io);
        Io.Event.set(&self.master_event, self.io); // timed 兜底模式下唤醒睡在 event 上的 Master
        if (self.master) |m| {
            m.join();
            self.master = null;
        }
        self.waitStalledExits();
        for (self.workers.items, 0..) |w, id| {
            if (self.stalled[id]) continue; // 已 detach：绝不 join
            w.join();
        }
        self.workers.deinit(self.allocator);
        self.workers = .empty; // ArrayList.deinit 不清 items.len，显式复位
    }

    /// 释放 runtime 本体（须在 shutdown 之后）
    pub fn deinit(self: *Runtime) void {
        std.debug.assert(self.master == null);
        std.debug.assert(self.workers.items.len == 0);
        self.reg.deinit(self.allocator);
        self.allocator.free(self.started_ns);
        self.allocator.free(self.stalled);
        self.allocator.free(self.exited);
        self.allocator.destroy(self);
    }

    // ---- Master / worker 线程函数 ----

    fn masterMain(self: *Runtime) void {
        while (true) {
            // —— 等待「补 worker」/停机；`stall_timeout_ns>0` 时退居带超时 wait（§5.1/
            // §5.2 层2）：超时到点做停滞扫描；否则保持纯事件、零定时器（行为不变）——
            var stall_tick = false;
            self.master_mutex.lockUncancelable(self.io);
            while (!self.shutdown_requested.load(.acquire) and !self.need_worker) {
                if (self.cfg.stall_timeout_ns == 0) {
                    Io.Condition.waitUncancelable(&self.master_cv, self.io, &self.master_mutex);
                } else {
                    // 带超时兜底：不得持 master_mutex 睡 Event → 先放锁再 wait
                    self.master_mutex.unlock(self.io);
                    const woke = waitEventTimeout(&self.master_event, self.io, self.scanPeriodNs());
                    self.master_mutex.lockUncancelable(self.io);
                    if (woke) {
                        Io.Event.reset(&self.master_event); // 消费 latch（仅 Master wait/reset）
                        continue; // 真实事件（submit 扩容 / 停机）→ 重查标志
                    }
                    stall_tick = true; // 纯超时到点（或罕见虚假唤醒）→ 本轮做停滞扫描
                    break;
                }
            }
            const shutting_down = self.shutdown_requested.load(.acquire);
            if (!shutting_down and !stall_tick) self.need_worker = false; // 消费 grow 请求
            self.master_mutex.unlock(self.io);

            if (shutting_down) break; // 停机优先

            if (stall_tick) {
                // 无待办工作且超时到点：§5.2 层2 停滞兜底扫描（低频，非周期热扫）。
                // 注意：此路径不清 need_worker——竞态 submit 可能刚置位（其 Event.set 在超时
                // 判定后才落），留到下一轮由主谓词消费，避免丢扩容请求。
                self.scanStalled();
                continue;
            }
            // 至此非停即需补 worker（!shutting_down && !stall_tick → need_worker 已被清）

            // 补建 worker（§3.1 能力 A：spawn 执行者 = Master；§5.5：积压 > 现 worker 则扩）。
            // spawn 失败不 panic（§5.4）：记日志即可，任务继续排队，下次 submit 再请求。
            self.appendWorker() catch {
                std.debug.print("runtime: worker spawn failed (OOM/线程配额/cap)\n", .{});
                continue;
            };
            // 仍积压且未达 cap → 再补一个（循环至 backlog 消化或到 max_workers）
            self.master_mutex.lockUncancelable(self.io);
            const still_backlogged = blk: {
                self.mutex.lockUncancelable(self.io);
                const more = self.inflight > self.workers.items.len;
                self.mutex.unlock(self.io);
                break :blk more;
            };
            if (still_backlogged and self.workers.items.len < self.cfg.max_workers) {
                self.need_worker = true;
            }
            self.master_mutex.unlock(self.io);
        }
        // Master 决定停机：置 worker_shutdown 并广播（worker 收尾返回，不自杀）
        self.worker_shutdown.store(true, .release);
        self.mutex.lockUncancelable(self.io);
        Io.Condition.broadcast(&self.jobs_avail, self.io);
        self.mutex.unlock(self.io);
    }

    fn workerMain(self: *Runtime, id: usize) void {
        const me = &self.reg.entries[id];
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (self.queue_head == null and !self.worker_shutdown.load(.acquire)) {
                Io.Condition.waitUncancelable(&self.jobs_avail, self.io, &self.mutex);
            }
            if (self.queue_head) |head| {
                // 完成即领：取一件（空闲边界换任务，§2.1 run-to-completion）
                self.queue_head = head.next;
                if (self.queue_head == null) self.queue_tail = null;
                me.markBusy(); // 状态先行（§5.1）：开工前自写 busy（持锁，Master 读同锁串行化）
                self.started_ns[id].store(self.nowNs(), .monotonic); // 停滞判定基准（§5.2 层2）
                self.mutex.unlock(self.io);

                head.job.run(head.job.ctx);

                // 收尾（持锁写 reg/inflight，Master 读同锁串行化）
                self.mutex.lockUncancelable(self.io);
                if (self.stalled[id]) {
                    // §5.2 层2：本 worker 已被 Master 判停滞并 detach——放弃本任务时 Master
                    // 已代为复位 reg/started/inflight。任务若自返（如 stop 标志任务），不得
                    // 再写任何共享簿记：只销毁自取节点、置 exited 即退（exited 是最后一条
                    // 触碰 runtime 的操作，shutdown 据此有界等待）。
                    self.mutex.unlock(self.io);
                    self.allocator.destroy(head);
                    self.exited[id].store(true, .release);
                    return;
                }
                self.started_ns[id].store(0, .monotonic);
                me.beginIdle(0); // idle_since 时钟源由接线层提供；此处仅维护状态
                self.inflight -= 1;
                self.mutex.unlock(self.io);
                Io.Condition.broadcast(&self.idle_cv, self.io);

                self.allocator.destroy(head);
                continue;
            }
            // 队列空且 worker_shutdown → 收尾返回（不自建不自杀；由 Master join）
            self.mutex.unlock(self.io);
            return;
        }
    }

    /// 单调纳秒（worker 开工时刻 / 停滞扫描用；同源同钟，差即有界）。
    fn nowNs(self: *const Runtime) u64 {
        return @intCast(Io.Timestamp.now(self.io, .awake).nanoseconds);
    }

    /// Master 带超时等待时长：stall_timeout_ns（下限 1ms，防病态小值高频空扫）。
    fn scanPeriodNs(self: *const Runtime) u64 {
        return @max(self.cfg.stall_timeout_ns, std.time.ns_per_ms);
    }

    /// §5.2 层2 停滞扫描（Master 带超时 wait 兜底，低频）。判定：busy worker 开工超过
    /// stall_timeout_ns 未完工 → 停滞。处理：detach 线程句柄（停机跳过 join）、复位
    /// reg/started/inflight、计 stall_count。停滞槽**永不复用**（卡死线程可能仍在跑，遗留
    /// OS 线程数 = detach 数，单次可接受、文档化）。锁内完成全部判写（与 worker 簿记互斥）。
    fn scanStalled(self: *Runtime) void {
        if (self.cfg.stall_timeout_ns == 0) return;
        const n = self.workers.items.len;
        if (n == 0) return;
        const now = self.nowNs();
        var abandoned = false;
        self.mutex.lockUncancelable(self.io);
        for (self.reg.entries[0..n], 0..n) |*e, id| {
            if (self.stalled[id]) continue;
            if (e.state != tables.WState.busy) continue;
            const started = self.started_ns[id].load(.monotonic);
            if (started == 0) continue;
            if (now -| started <= self.cfg.stall_timeout_ns) continue;
            // 停滞：放弃该 worker 与其在途任务（任务体若自返走 workerMain 停滞分支，只销毁
            // 自取节点即退，不再写任何共享簿记——此处已代为收尾）。
            self.stalled[id] = true;
            e.beginIdle(0);
            self.started_ns[id].store(0, .monotonic);
            if (self.inflight > 0) self.inflight -= 1; // 放弃任务视作已收尾
            self.workers.items[id].detach(); // detach 后绝不 join
            _ = self.stall_count.fetchAdd(1, .monotonic);
            abandoned = true;
        }
        self.mutex.unlock(self.io);
        if (abandoned) Io.Condition.broadcast(&self.idle_cv, self.io); // waitIdle 等待者据此复查
    }

    /// 有界等待停滞（已 detach）worker 自退：给 stop-标志任务退出窗口，避免 deinit 后其
    /// 返回路径触碰已释放 runtime。真卡死（永不返）在预算内不阻塞、直接放行（宿主/进程兜底）。
    fn waitStalledExits(self: *Runtime) void {
        const timeout = self.cfg.stall_timeout_ns;
        if (timeout == 0) return; // 无停滞可能
        var has_stalled = false;
        for (self.workers.items, 0..) |_, id| {
            if (self.stalled[id]) {
                has_stalled = true;
                break;
            }
        }
        if (!has_stalled) return;
        const budget = @min(@max(@as(u64, 20) * std.time.ns_per_ms, timeout), @as(u64, 200) * std.time.ns_per_ms);
        const step = 2 * std.time.ns_per_ms;
        const deadline = self.nowNs() + budget;
        while (true) {
            var all_done = true;
            for (self.workers.items, 0..) |_, id| {
                if (self.stalled[id] and !self.exited[id].load(.acquire)) {
                    all_done = false;
                    break;
                }
            }
            if (all_done) return;
            const now = self.nowNs();
            if (now >= deadline) return; // 真卡死：不悬挂，留给进程级兜底
            ioSleep(self.io, @min(step, deadline - now));
        }
    }

    fn ioLockedBroadcastWorkers(self: *Runtime) void {
        self.mutex.lockUncancelable(self.io);
        Io.Condition.broadcast(&self.jobs_avail, self.io);
        self.mutex.unlock(self.io);
    }
};

// ---------------------------------------------------------------------------
// Master 带超时兜底原语（§5.1/§5.2 层2；与 kernel/task.zig `waitEventTimeout` 同型）
// ---------------------------------------------------------------------------

/// 保证可用的带超时等待（Master 空闲兜底 / 低频扫描用；热路径不用）。
/// 事件在超时内被 set → true；超时/虚假唤醒 → false。
fn waitEventTimeout(event: *Io.Event, io: Io, timeout_ns: u64) bool {
    const dur = std.Io.Clock.Duration{
        .raw = .{ .nanoseconds = timeout_ns },
        .clock = .awake, // Linux CLOCK_MONOTONIC（单调，不含挂起）
    };
    Io.Event.waitTimeout(event, io, .{ .duration = dur }) catch |e| switch (e) {
        error.Timeout => return false,
        error.Canceled => return false,
    };
    return true;
}

/// 单调时长睡眠（shutdown 有界等待停滞 worker 自退用）。
fn ioSleep(io: Io, ns: u64) void {
    const dur = std.Io.Clock.Duration{
        .raw = .{ .nanoseconds = ns },
        .clock = .awake,
    };
    Io.Timeout.sleep(.{ .duration = dur }, io) catch {};
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

const TestCtx = struct {
    counter: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    fn bump(ctx: *anyopaque) void {
        const t: *TestCtx = @ptrCast(@alignCast(ctx));
        _ = t.counter.fetchAdd(1, .monotonic);
    }
};

test "runtime: init → submit N jobs → shutdown 排空且全 join（run-to-completion）" {
    var ctx = TestCtx{};
    const rt = try Runtime.init(std.heap.c_allocator, .{ .min_workers = 4 });
    defer rt.deinit();

    const n = 1000;
    var submitted: usize = 0;
    for (0..n) |_| {
        if (rt.submit(.{ .run = TestCtx.bump, .ctx = &ctx })) submitted += 1;
    }
    try testing.expectEqual(n, submitted);

    rt.shutdown(); // 排空队列并 join 全部线程后返回

    try testing.expectEqual(@as(u32, @intCast(submitted)), ctx.counter.load(.acquire));
    try testing.expect(rt.master == null);
    try testing.expectEqual(@as(usize, 0), rt.workers.items.len);
}

test "runtime: cfg 校验 min_workers > max_workers → InvalidCfg（不半初始化）" {
    try testing.expectError(error.InvalidCfg, Runtime.init(std.heap.c_allocator, .{ .min_workers = 8, .max_workers = 4 }));
}

test "runtime: shutdown with 0 jobs 立即干净退出" {
    const rt = try Runtime.init(std.heap.c_allocator, .{ .min_workers = 1 });
    defer rt.deinit();
    rt.shutdown();
}

test "runtime: 停机后 submit 被拒绝（不悬挂入队）" {
    var ctx = TestCtx{};
    const rt = try Runtime.init(std.heap.c_allocator, .{ .min_workers = 1 });
    defer rt.deinit();
    // 先跑一批确保正常路径
    _ = rt.submit(.{ .run = TestCtx.bump, .ctx = &ctx });
    rt.waitIdle();
    rt.shutdown();
    // 停机后提交：必须拒绝且不悬挂
    try testing.expect(!rt.submit(.{ .run = TestCtx.bump, .ctx = &ctx }));
    try testing.expectEqual(@as(usize, 0), rt.inflight);
    try testing.expect(rt.queue_head == null);
}

test "runtime: 大 batch（5000）× 懒就绪排空 + 停机（队列深度压力）" {
    var ctx = TestCtx{};
    const rt = try Runtime.init(std.heap.c_allocator, .{ .min_workers = 0 });
    defer {
        rt.shutdown();
        rt.deinit();
    }
    const n = 5000;
    var submitted: usize = 0;
    for (0..n) |_| {
        if (rt.submit(.{ .run = TestCtx.bump, .ctx = &ctx })) submitted += 1;
    }
    try testing.expectEqual(n, submitted);
    rt.waitIdle();
    try testing.expectEqual(@as(u32, @intCast(submitted)), ctx.counter.load(.acquire));
    rt.shutdown();
}

test "runtime: 懒就绪 min_workers=0 → 首任务由 Master spawn，排空后 shutdown" {
    var ctx = TestCtx{};
    const rt = try Runtime.init(std.heap.c_allocator, .{ .min_workers = 0 });
    defer rt.deinit();
    try testing.expectEqual(@as(usize, 0), rt.workers.items.len); // 引导期零 worker

    const n = 200;
    var submitted: usize = 0;
    for (0..n) |_| {
        if (rt.submit(.{ .run = TestCtx.bump, .ctx = &ctx })) submitted += 1;
    }
    try testing.expectEqual(n, submitted);

    rt.waitIdle(); // 首任务触发 Master spawn → worker 跑完
    try testing.expect(rt.workers.items.len >= 1);
    try testing.expectEqual(@as(u32, @intCast(submitted)), ctx.counter.load(.acquire));

    rt.shutdown();
}

test "runtime: 弹性扩容——积压大时 Master 补建至 cap，max 界住线程数" {
    var ctx = TestCtx{};
    const rt = try Runtime.init(std.heap.c_allocator, .{ .min_workers = 1, .max_workers = 8 });
    defer {
        rt.shutdown();
        rt.deinit();
    }
    try testing.expectEqual(@as(usize, 1), rt.workers.items.len); // eager 下限

    // 一次性压入 1000 任务 → Master 按 backlog 补建，最多到 8
    const n = 1000;
    var submitted: usize = 0;
    for (0..n) |_| {
        if (rt.submit(.{ .run = TestCtx.bump, .ctx = &ctx })) submitted += 1;
    }
    try testing.expectEqual(n, submitted);
    rt.waitIdle();

    const grew = rt.workers.items.len;
    try testing.expect(grew > 1); // 确曾扩容
    try testing.expect(grew <= 8); // 未越 cap
    try testing.expectEqual(@as(u32, @intCast(submitted)), ctx.counter.load(.acquire));
    rt.shutdown();
}

// ---- §5.2 层2：停滞检测（cfg.stall_timeout_ns>0 才启用；默认关 = 与既有行为一致）----

/// 停滞测试长转任务体：自旋 yield 并查 `stop` 标志（设为 true 即快速自返）；`budget_ns`
/// 为最迟自退预算（防检测失效时把测试挂死——届时仅断言失败而非悬挂）。
const StallJob = struct {
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    budget_ns: u64 = 0,

    fn run(ctx: *anyopaque) void {
        const s: *StallJob = @ptrCast(@alignCast(ctx));
        const ioinst = Io.Threaded.global_single_threaded.io();
        const deadline: i96 = if (s.budget_ns > 0)
            Io.Timestamp.now(ioinst, .awake).nanoseconds + @as(i96, @intCast(s.budget_ns))
        else
            0;
        while (!s.stop.load(.acquire)) {
            if (s.budget_ns > 0 and Io.Timestamp.now(ioinst, .awake).nanoseconds >= deadline) break;
            std.Thread.yield() catch {};
        }
    }
};

fn tSleepMs(ms: u64) void {
    const dur = std.Io.Clock.Duration{
        .raw = .{ .nanoseconds = ms * std.time.ns_per_ms },
        .clock = .awake,
    };
    Io.Timeout.sleep(.{ .duration = dur }, Io.Threaded.global_single_threaded.io()) catch {};
}

test "runtime: §5.2 层2 停滞——长转 worker 被 detach，池继续可用、停机干净" {
    var probe = StallJob{ .budget_ns = 3 * std.time.ns_per_s };
    var normal = TestCtx{};
    const rt = try Runtime.init(std.heap.c_allocator, .{
        .min_workers = 2,
        .max_workers = 4,
        .stall_timeout_ns = 50 * std.time.ns_per_ms,
    });
    defer {
        probe.stop.store(true, .release); // 无论走到哪都先放停靠标志，防滞留
        rt.shutdown();
        rt.deinit();
    }

    // 一个蓄意长转任务占住一个 worker（远大于 stall_timeout）
    try testing.expect(rt.submit(.{ .run = StallJob.run, .ctx = &probe }));
    // 若干正常任务由其余 worker 完成
    const n_normal: usize = 12;
    var submitted: usize = 0;
    for (0..n_normal) |_| {
        if (rt.submit(.{ .run = TestCtx.bump, .ctx = &normal })) submitted += 1;
    }
    try testing.expectEqual(n_normal, submitted);

    // 并发 waitIdle 等待者：随停滞任务被放弃（scan 代为 inflight-1 + broadcast idle_cv）
    // 而返回——验证等待者不被悬挂
    const Waiter = struct {
        rt: *Runtime,
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        fn run(self: *@This()) void {
            self.rt.waitIdle();
            self.done.store(true, .release);
        }
    };
    var waiter = Waiter{ .rt = rt };
    const wth = try std.Thread.spawn(.{ .allocator = std.heap.c_allocator }, Waiter.run, .{&waiter});

    // 有界轮询：停滞被检出（长转 worker 被 detach 并放弃其任务）
    var seen_stall = false;
    for (0..120) |_| {
        if (rt.stall_count.load(.acquire) >= 1) {
            seen_stall = true;
            break;
        }
        tSleepMs(5);
    }
    try testing.expect(seen_stall);

    // 正常任务全部完成（不能 waitIdle 阻塞：长转任务已被放弃、由 scan 计回 inflight）
    var done = false;
    for (0..120) |_| {
        if (normal.counter.load(.acquire) == @as(u32, @intCast(submitted))) {
            done = true;
            break;
        }
        tSleepMs(5);
    }
    try testing.expect(done);

    // waitIdle 等待者也已返回（停滞放弃触发 inflight→0 + idle_cv 广播）
    done = false;
    for (0..120) |_| {
        if (waiter.done.load(.acquire)) {
            done = true;
            break;
        }
        tSleepMs(5);
    }
    try testing.expect(done);
    wth.join();

    // 停掉长转任务 → 其自行退场（停滞分支：销毁自取节点、置 exited，不写任何簿记）；
    // 池仍可接受并完成新任务（shutdown 的停滞有界等待保证 deinit 前其已真正退出）
    probe.stop.store(true, .release);
    var after = TestCtx{};
    try testing.expect(rt.submit(.{ .run = TestCtx.bump, .ctx = &after }));
    done = false;
    for (0..120) |_| {
        if (after.counter.load(.acquire) == 1) {
            done = true;
            break;
        }
        tSleepMs(5);
    }
    try testing.expect(done);
    // defer 的 shutdown：跳过已 detach 停滞 worker 的 join，干净返回即证明无悬挂
}

test "runtime: stall 启用但无卡死任务 → 不误杀、stall_count 保持 0、停机干净" {
    var ctx = TestCtx{};
    const rt = try Runtime.init(std.heap.c_allocator, .{
        .min_workers = 2,
        .max_workers = 4,
        .stall_timeout_ns = 200 * std.time.ns_per_ms,
    });
    defer {
        rt.shutdown();
        rt.deinit();
    }
    const n = 300;
    var submitted: usize = 0;
    for (0..n) |_| {
        if (rt.submit(.{ .run = TestCtx.bump, .ctx = &ctx })) submitted += 1;
    }
    try testing.expectEqual(n, submitted);
    rt.waitIdle(); // 短任务全部瞬时完成，不应触发任何停滞判定
    try testing.expectEqual(@as(u32, @intCast(submitted)), ctx.counter.load(.acquire));
    try testing.expectEqual(@as(usize, 0), rt.stall_count.load(.acquire));
    rt.shutdown();
}

// ---- 并发解码验证（registry→池 worker；decode 首次跑在真实多线程上，不接生产线）----

const task_mod = @import("task.zig");
const decoder = @import("decoder.zig");

/// 任务体容器：task 作首字段，body 经 @fieldParentPtr 取回上下文
const DecHolder = struct {
    task: task_mod.Task,
    path: []const u8,
    expected: usize,
    got: usize = 0,
    ok: bool = false,
    expect_decode_error: bool = false,

    fn runFull(t: *task_mod.Task) void {
        const h: *DecHolder = @fieldParentPtr("task", t);
        var info: decoder.Info = undefined;
        var dec = decoder.open(std.heap.c_allocator, h.path, &info) catch {
            if (h.expect_decode_error) {
                t.fail(error.UnsupportedFormat);
            } else {
                t.fatal(); // 期望可解码却 open 失败 → 异常
            }
            return;
        };
        defer dec.deinit();
        var total: usize = 0;
        var buf: [65536]u8 = undefined;
        while (true) {
            var ch: u8 = 0;
            const n = dec.read(&buf, 4096, &ch) catch {
                if (h.expect_decode_error) {
                    t.fail(error.DecodeFailed);
                } else {
                    t.fatal();
                }
                return;
            };
            if (n == 0) break;
            total += n;
        }
        if (h.expect_decode_error) {
            t.fatal(); // 坏样本不应正常 decode 完
        } else {
            h.got = total;
            h.ok = total == h.expected;
        }
    }
};

test "pool: 并发 decode 各自实例与 sync 一致（实例隔离；懒就绪 spawn）" {
    // 造黄金 WAV（8kHz mono 8 帧，i16）
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(testing.allocator);
    try bytes.appendSlice(testing.allocator, "RIFF\x28\x00\x00\x00WAVE");
    try bytes.appendSlice(testing.allocator, "fmt ");
    try bytes.appendSlice(testing.allocator, &[_]u8{ 0x10, 0x00, 0x00, 0x00 });
    try bytes.appendSlice(testing.allocator, &[_]u8{ 0x01, 0x00, 0x01, 0x00, 0x40, 0x1F, 0x00, 0x00, 0x00, 0x3E, 0x00, 0x00, 0x02, 0x00, 0x10, 0x00 });
    try bytes.appendSlice(testing.allocator, "data");
    try bytes.appendSlice(testing.allocator, &[_]u8{ 0x10, 0x00, 0x00, 0x00 });
    var samples: [16]u8 = undefined;
    for (0..8) |i| std.mem.writeInt(i16, samples[2 * i ..][0..2], @as(i16, @intCast(i)), .little);
    try bytes.appendSlice(testing.allocator, &samples);
    const ioinst = Io.Threaded.global_single_threaded.io();
    const f = try tmp.dir.createFile(ioinst, "gold.wav", .{});
    try Io.File.writeStreamingAll(f, ioinst, bytes.items);
    Io.File.close(f, ioinst);
    const full = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "gold.wav" });
    defer testing.allocator.free(full);

    // 基线：sync 全帧数 = 8
    var info: decoder.Info = undefined;
    var sync = try decoder.open(std.heap.c_allocator, full, &info);
    var total: usize = 0;
    var buf: [4096]u8 = undefined;
    while (true) {
        var ch: u8 = 0;
        const n = try sync.read(&buf, 4096, &ch);
        if (n == 0) break;
        total += n;
    }
    sync.deinit();
    try testing.expectEqual(@as(usize, 8), total);

    // 池（懒就绪）：首任务触发 spawn，并发 decode 40 个独立实例
    const rt = try Runtime.init(std.heap.c_allocator, .{ .min_workers = 0 });
    defer {
        rt.shutdown();
        rt.deinit();
    }
    const batch = 40;
    var holders: [batch]DecHolder = undefined;
    var submitted: usize = 0;
    for (&holders) |*h| {
        h.* = .{ .task = .{ .run = DecHolder.runFull }, .path = full, .expected = total };
        if (task_mod.spawnInto(rt, &h.task)) submitted += 1;
    }
    try testing.expectEqual(batch, submitted);
    for (&holders) |*h| task_mod.wait(&h.task);
    for (&holders) |*h| {
        try testing.expect(h.ok);
        try testing.expectEqual(task_mod.Outcome.done, h.task.outcome);
    }
}

test "pool: worker 状态注册表维护（完工全 idle、可回收候选 = worker 数）" {
    var ctx = TestCtx{};
    const rt = try Runtime.init(std.heap.c_allocator, .{ .min_workers = 4, .max_workers = 4 });
    defer {
        rt.shutdown();
        rt.deinit();
    }
    const n = 256;
    for (0..n) |_| _ = rt.submit(.{ .run = TestCtx.bump, .ctx = &ctx });
    rt.waitIdle(); // reg 写先于 inflight 置零（经锁 release），此处安全聚合

    // 只统计活跃 worker 前缀（定容表其余格默认 idle，不计入）
    const active = rt.workers.items.len;
    var idle: usize = 0;
    var cand: usize = 0;
    for (rt.reg.entries[0..active]) |*e| {
        if (e.state == tables.WState.idle) idle += 1;
        if (e.isReclaimCandidate()) cand += 1;
    }
    try testing.expectEqual(@as(usize, 4), active);
    try testing.expectEqual(active, idle);
    try testing.expectEqual(@as(usize, 0), rt.reg.summarize().busy);
    try testing.expectEqual(active, cand);
}

test "pool: 畸形输入走 error（不 panic），池随后仍健康解码" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ioinst = Io.Threaded.global_single_threaded.io();
    const f0 = try tmp.dir.createFile(ioinst, "bad0.bin", .{});
    try Io.File.writeStreamingAll(f0, ioinst, "not-an-audio-file-at-all");
    Io.File.close(f0, ioinst);
    const p0 = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "bad0.bin" });
    defer testing.allocator.free(p0);

    const rt = try Runtime.init(std.heap.c_allocator, .{ .min_workers = 2 });
    defer {
        rt.shutdown();
        rt.deinit();
    }
    var h = DecHolder{ .task = .{ .run = DecHolder.runFull }, .path = p0, .expected = 0, .expect_decode_error = true };
    try testing.expect(task_mod.spawnInto(rt, &h.task));
    task_mod.wait(&h.task);
    try testing.expectEqual(task_mod.Outcome.failed, h.task.outcome); // 不可解码 → error 收尾

    // 池健康：随后正常解码成功（坏样本未污染 worker）
    var tmp2 = testing.tmpDir(.{});
    defer tmp2.cleanup();
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(testing.allocator);
    try bytes.appendSlice(testing.allocator, "RIFF\x28\x00\x00\x00WAVE");
    try bytes.appendSlice(testing.allocator, "fmt ");
    try bytes.appendSlice(testing.allocator, &[_]u8{ 0x10, 0x00, 0x00, 0x00 });
    try bytes.appendSlice(testing.allocator, &[_]u8{ 0x01, 0x00, 0x01, 0x00, 0x40, 0x1F, 0x00, 0x00, 0x00, 0x3E, 0x00, 0x00, 0x02, 0x00, 0x10, 0x00 });
    try bytes.appendSlice(testing.allocator, "data");
    try bytes.appendSlice(testing.allocator, &[_]u8{ 0x10, 0x00, 0x00, 0x00 });
    var samples: [16]u8 = undefined;
    for (0..8) |i| std.mem.writeInt(i16, samples[2 * i ..][0..2], @as(i16, @intCast(i)), .little);
    try bytes.appendSlice(testing.allocator, &samples);
    const f = try tmp2.dir.createFile(ioinst, "gold.wav", .{});
    try Io.File.writeStreamingAll(f, ioinst, bytes.items);
    Io.File.close(f, ioinst);
    const full = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", tmp2.sub_path[0..], "gold.wav" });
    defer testing.allocator.free(full);

    var h2 = DecHolder{ .task = .{ .run = DecHolder.runFull }, .path = full, .expected = 8 };
    try testing.expect(task_mod.spawnInto(rt, &h2.task));
    task_mod.wait(&h2.task);
    try testing.expect(h2.ok);
    try testing.expectEqual(task_mod.Outcome.done, h2.task.outcome);
}


// ---- 零 panic 纪律 fuzz-lite：截断扫描（只 error，绝不 panic/挂起）----

const SweepCtx = struct {
    task: task_mod.Task,
    path: []const u8,
    expected: usize,
    got: usize = 0,
    ok: bool = false,
    errored: bool = false,

    fn run(t: *task_mod.Task) void {
        const sc: *SweepCtx = @fieldParentPtr("task", t);
        var info: decoder.Info = undefined;
        var dec = decoder.open(std.heap.c_allocator, sc.path, &info) catch {
            sc.errored = true; // 截断开失败 = error（bridge 默认 done），不 panic
            return;
        };
        defer dec.deinit();
        var total: usize = 0;
        var buf: [65536]u8 = undefined;
        while (true) {
            var ch: u8 = 0;
            const n = dec.read(&buf, 4096, &ch) catch {
                sc.errored = true; // 中段截断解码 error，不 panic
                return;
            };
            if (n == 0) break;
            total += n;
        }
        sc.got = total;
        sc.ok = total == sc.expected;
    }
};

test "pool: 截断扫描解码只 error 不 panic（fuzz-lite，并发喂池）" {
    const sample = @embedFile("fmt/mka/samples/out_flac.mka");
    const full_frames: usize = 110250; // fmt/mka e2e：44100 mono 全量
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ioinst = Io.Threaded.global_single_threaded.io();

    const rt = try Runtime.init(std.heap.c_allocator, .{ .min_workers = 4, .max_workers = 8 });
    defer {
        rt.shutdown();
        rt.deinit();
    }

    const cuts = [_]usize{ 16, 64, 128, 256, 512, 1024, 2048, 4096, 8192, sample.len / 2, sample.len - 64, sample.len };
    // 托管路径生命周期：写文件 → 全部任务完成后再释放
    var paths: [cuts.len][]u8 = undefined;
    var holders: [cuts.len]SweepCtx = undefined;
    defer for (paths) |p| if (p.len > 0) std.heap.c_allocator.free(p);

    for (cuts, 0..) |cut, i| {
        const name = try std.fmt.allocPrint(std.heap.c_allocator, "c{d}.mka", .{i});
        const f = try tmp.dir.createFile(ioinst, name, .{});
        const n = @min(cut, sample.len);
        try Io.File.writeStreamingAll(f, ioinst, sample[0..n]);
        Io.File.close(f, ioinst);
        paths[i] = try std.fs.path.join(std.heap.c_allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], name });
        std.heap.c_allocator.free(name);
        holders[i] = .{
            .task = .{ .run = SweepCtx.run },
            .path = paths[i],
            .expected = full_frames,
        };
    }

    var submitted: usize = 0;
    for (&holders) |*h| {
        if (task_mod.spawnInto(rt, &h.task)) submitted += 1;
    }
    try testing.expectEqual(cuts.len, submitted);
    for (&holders) |*h| task_mod.wait(&h.task);

    // 全部有终态（无挂起）；任一截断不得 panic（任务正常返回即证明）
    for (&holders) |*h| try testing.expect(h.task.outcome != task_mod.Outcome.pending);
    // 完整长度：正常解到全量
    try testing.expect(holders[cuts.len - 1].ok);
    try testing.expect(!holders[cuts.len - 1].errored);
}

test "runtime: 停机与提交并发竞争不 panic、不悬挂" {
    const Runner = struct {
        rt: *Runtime,
        ctx: *TestCtx,
        running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
        accepted: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

        fn push(self: *@This()) void {
            while (self.running.load(.acquire)) {
                if (self.rt.submit(.{ .run = TestCtx.bump, .ctx = self.ctx })) {
                    _ = self.accepted.fetchAdd(1, .monotonic);
                }
                std.Thread.yield() catch {};
            }
        }
    };
    var ctx = TestCtx{};
    const rt = try Runtime.init(std.heap.c_allocator, .{ .min_workers = 2, .max_workers = 4 });
    defer {
        rt.shutdown();
        rt.deinit();
    }
    var runner = Runner{ .rt = rt, .ctx = &ctx };
    const th = try std.Thread.spawn(.{ .allocator = std.heap.c_allocator }, Runner.push, .{&runner});

    // 等压入一批后，边停提交边停机（停机与在途提交真实重叠）
    while (runner.accepted.load(.acquire) < 100) std.Thread.yield() catch {};
    runner.running.store(false, .release);
    rt.shutdown(); // 排空已接受任务并 join；此后提交一律拒绝
    th.join();

    try testing.expectEqual(
        @as(u32, @intCast(runner.accepted.load(.acquire))),
        ctx.counter.load(.acquire),
    );
}

test "pool: 128 路混合格式并发解码（mka/FLAC + LATM/AAC）实例隔离、零 panic" {
    const mka = @embedFile("fmt/mka/samples/out_flac.mka");
    const latm = @embedFile("fmt/latm_tiny_mono.latm");
    const mka_frames: usize = 110250;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ioinst = Io.Threaded.global_single_threaded.io();
    const fw = try tmp.dir.createFile(ioinst, "a.mka", .{});
    try Io.File.writeStreamingAll(fw, ioinst, mka);
    Io.File.close(fw, ioinst);
    const f2 = try tmp.dir.createFile(ioinst, "b.latm", .{});
    try Io.File.writeStreamingAll(f2, ioinst, latm);
    Io.File.close(f2, ioinst);
    const pa = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "a.mka" });
    const pb = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "b.latm" });
    defer testing.allocator.free(pa);
    defer testing.allocator.free(pb);

    const rt = try Runtime.init(std.heap.c_allocator, .{ .min_workers = 0, .max_workers = 16 });
    defer {
        rt.shutdown();
        rt.deinit();
    }

    const total: usize = 128;
    var holders: [total]SweepCtx = undefined;
    var submitted: usize = 0;
    for (&holders, 0..) |*h, i| {
        const is_mka = (i % 2) == 0;
        h.* = .{
            .task = .{ .run = SweepCtx.run },
            .path = if (is_mka) pa else pb,
            .expected = if (is_mka) mka_frames else 0, // latm 只验 >0 且不崩
        };
        if (task_mod.spawnInto(rt, &h.task)) submitted += 1;
    }
    try testing.expectEqual(total, submitted);
    for (&holders) |*h| task_mod.wait(&h.task);

    var mka_done: usize = 0;
    var latm_got: usize = 0;
    var latm_ok: usize = 0;
    for (&holders, 0..) |*h, i| {
        try testing.expect(h.task.outcome != task_mod.Outcome.pending); // 全部有终态
        if ((i % 2) == 0) {
            if (h.ok) mka_done += 1;
        } else {
            if (!h.errored and h.got > 0) latm_ok += 1;
            latm_got += h.got;
        }
    }
    // mka/FLAC 全部精确到全量；LATM 至少多数成功且有产出（格式间无相互污染）
    try testing.expectEqual(total / 2, mka_done);
    try testing.expect(latm_ok >= total / 4);
    try testing.expect(latm_got > 0);
}
