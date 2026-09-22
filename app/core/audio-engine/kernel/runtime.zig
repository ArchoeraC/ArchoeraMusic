// ArchoeraMusic Audio Framework
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
// EraSync — ArchoeraMusic 自研音频内核

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
//! §5.5 目标容量调节器（完整化）：`desired = min(running + ceil(backlog/load_factor) + spare,
//! max_workers)`；排空回落 = `max(min_workers, min(并发达峰, max_workers))` + 滞后死区
//! `keep_watermark` + 收步长 `shrink_step`；`grow_step` 限每事件扩建；`idle_timeout_ns>0`
//! 时空闲 elastic 超时降容（retiring + 锁外 join 复用槽）。**默认常量复刻既有 F1 纯事件
//! 行为**（load_factor=1 / spare=0 / 步长=0 / 死区=0 / idle=0），新能力按需显式开启。
//!
//! §5.2 层2 停滞兜底（`cfg.stall_timeout_ns > 0` 才启用，默认关 = 行为与纯事件版完全一致）：
//!   - worker 开工写 `started_ns[id]`（单调 ns），完工清零；
//!   - Master 空闲改为带超时 wait（`master_event` + `waitTimeout`，§5.1「零轮询」），超时到点
//!     做停滞扫描：busy 且开工超时的 worker → 判停滞 → **detach 线程句柄**（停机跳过其 join，
//!     绝不 join 卡死线程）+ 复位其 reg/started/inflight + `stall_count` 计数；卡死（永不返）
//!     的槽持续退役（遗留 OS 线程数 = detach 数，单次可接受并文档化）。
//!   - 被放弃 worker 若任务自返（如 stop 标志任务）：走 workerMain 停滞分支，只销毁自取节点、
//!     置 exited 即退，**不再写任何共享簿记**（Master 已代为收尾）；`shutdown` 对停滞 worker
//!     有界等待其退出，真卡死（永不返）不阻塞、留给宿主 `kernel_shutdown_force` 兜底。
//! F3（槽位容量恢复，2026-09-09）：停滞线程若随后自返（置 `exited[id]`），Master 在超时
//! 兜底 tick（`respawnRetired`）与 `appendWorker` 复用扫描中把该槽**重新拉起**：新线程覆写
//! 已 detach 句柄（**绝不 join**）、复位 reg/stalled/exited/started_ns，池恢复满编；真正卡死
//! （永不退出）的槽仍退役。公开 `busyCount()` 记账在役（reg busy）worker 数。
//! F1（hybrid 纯事件回落，2026-09-09）：worker 完工把 `inflight` 减到 0（排空）后向 Master
//! 发回收事件（唯一回收触发，正确性不依赖定时器）。Master `maybeReclaim` 只在此刻评估：
//! 目标容量 `target = max(min_workers, min(本波并发达峰, max_workers))`——**并发达峰**而非
//! 队列深度（波次真实需要的并行度；微小任务风暴即使排起长队，同时 busy 的 worker 峰值也低
//! → 排空后回落；真需要 N 路并行才保留 N）。盈余（服役数 > target）→ 对**最老空闲的**
//! worker 置 `retire[id]` 并广播唤醒；worker 在空闲边界执行 Master 命令：二次确认队列仍空
//! 后置 `retiring`/`exited` 即退（不自杀）。**防 churn**：被 retire 标记的 worker 若因新队列
//! 转忙则自清 retire（重新有用），Master 只在下个排空事件重估；退役只在排空（无任务在途）
//! 后发起 → 波次中途绝无退出→再扩容抖动。退役槽复用：`retire && exited` 锁外 join 后覆写
//! 句柄（绝不持锁 join）；`stalled && exited` 已 detach 绝不 join。`active`（原子）记账
//! 「可服役」worker 数（非 `workers.items.len`——该表从不收缩，含退役/停滞槽），submit 增长
//! 与回收判断都按它读一致容量；stall_timeout_ns==0 且无退役场景时行为与既往字节一致。

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

    // ---- §5.5 目标容量调节器常量（默认与既有 F1 纯事件行为逐字节兼容）----
    /// 排队任务 → 弹性需求折算：每 `load_factor` 个积压需要 1 个 worker（0/1 = 一对一）
    load_factor: u16 = 1,
    /// 预留安全垫（§5.3；空闲 elastic 保留数，提前建供应领先需求）。0 = 不留
    spare: u16 = 0,
    /// 建步长：每事件（submit 补建轮）至多新建数；0 = 不限（既有一次性补建）
    grow_step: u16 = 0,
    /// 收步长：每事件至多标 retire 数；0 = 不限（既有整波回落）
    shrink_step: u16 = 0,
    /// 滞后死区上水位：`serving > target + keep_watermark` 才回收，防「建一个收一个」抖振。
    /// 0 = 无死区（既有行为）
    keep_watermark: u16 = 0,
    /// 空闲回收降容（§5.1 next_check / §5.5 兜底）：>0 时 Master 带超时唤醒，
    /// 空闲 elastic worker 闲置超过该时长且在役数 > min_workers → 标 retiring 收尾。
    /// 0 = 关闭（默认）：纯事件、零定时器，回收仍由排空事件触发（既有行为）。
    idle_timeout_ns: u64 = 0,
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

/// §5.5 排空回落裁决（纯函数，确定性可测）：给定 `serving`（在役数）、`target`（本波
/// 目标容量）、`keep`（滞后死区上水位）与 `shrink_step`（收步长），返回本事件应回收的
/// worker 数。`serving <= target + keep` → 0（死区内不动作，防「建一个收一个」抖振）；
/// 否则回收 `serving - target` 的盈余，受 `shrink_step` 封顶（0 = 不限）。不做任何簿记，
/// 仅裁决数量——实际标记由 `markOldestIdleLocked` 在锁内完成。
fn reclaimBudget(serving: usize, target: usize, keep: usize, shrink_step: usize) usize {
    if (serving <= target + keep) return 0; // 滞后死区
    var over = serving - target;
    if (shrink_step > 0) over = @min(over, shrink_step);
    return over;
}

/// 任务节点自由表容量上限（P3 实例内存池，§8.4.2 #4）。节点仅 ~24B，128 并发下
/// 每路至多 1 个在途节点，512 已含 4× 余量；突发超出者回退 malloc，自由表**不无限驻留**
/// （上限 512×24B ≈ 12KB，进程生命周期内只读复用）。
const node_pool_cap: usize = 512;

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
    /// 任务节点自由表（P3 实例内存池）：worker 完工把节点归还而非销毁，submit 优先复用，
    /// 消除「每任务一次 malloc/free」——128 并发流式播放/批量 tag 每 chunk 一次的抖动。
    /// 容量有界 `node_pool_cap`，超出销毁。**与任务队列同一 mutex 保护**（acquire/release
    /// 均在已持锁的 submit / worker 收尾临界区内），不引入新的同步原语。
    free_nodes: ?*Node = null,
    free_count: usize = 0,

    // ---- Master 协调 ----
    master_mutex: Io.Mutex = .init,
    master_cv: Io.Condition = .init,
    shutdown_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// 请 Master 补建 worker（submit 在积压 > 现 worker 数时置位）
    need_worker: bool = false,
    /// 请 Master 评估回收（worker 完工把 inflight 减到 0 = 排空事件时置位；唯一回收触发）。
    /// 与 need_worker 同受 master_mutex 保护、由 Master 消费清零。
    need_reclaim: bool = false,
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
    /// 已被判停滞并 detach 的槽。停机跳过其 join（已 detach 绝不 join）；旧线程自退
    /// （exited）后该槽可复用（F3：Master respawnInto 复位本标志并覆写句柄）。卡死
    /// （永不退出）槽持续退役，遗留 OS 线程数 = detach 数。
    /// 写：Master（scanStalled / respawnInto，均持 mutex）；读：worker（持 mutex）/
    /// shutdown（join 后）/ busyCount（持 mutex）。
    stalled: []bool = &.{},
    /// worker 自退标记：停滞 worker 返回前置位（最后一条触碰 runtime 的操作）；
    /// `shutdown` 据此有界等待停滞 worker 退出，避免 deinit 后其返回路径碰已释放内存。
    /// F3：Master 据此确认旧线程已离开后方可复用该槽（置位后该槽 reg/stalled 才能复位）。
    exited: []std.atomic.Value(bool) = &.{},
    // ---- F1 hybrid 回收簿记（容量 = cfg.max_workers，init 定容）----
    /// 退役标记：Master 在排空事件后对「盈余空闲」worker 置位，worker 在空闲边界执行
    /// （队列仍空则置 exiting 退出；期间来了任务则转忙并**自清**本标记——防 churn）。
    /// 写：Master（maybeReclaim）/ worker（转忙自清 / 退出清），均持 mutex；
    /// 读：worker（持 mutex 空闲谓词）/ appendWorker 复用扫描 / shutdown join 前判 ex/stall。
    /// 槽复用（`retire && exited`，正常退役）或停滞复用（`respawnInto`）时复位。
    retire: []bool = &.{},
    // ---- AS2 长流池化：worker 亲和 pinned 1:1（§6.3；默认关，会话显式 startPinned）----
    /// 会话 pinned 槽：true = 该 worker 专属于一个长流会话，只接该会话步骤（pinned_job）、
    /// 不进全局队列、不参与回收（class=pinned）。会话关闭 releasePinned 复位回 elastic。
    /// 写：Master 路径（acquire/submit/release，均持 mutex）；读：worker（持 mutex）。
    pinned: []bool = &.{},
    /// pinned 槽的待执行步骤（单槽；会话步骤**串行 await**，故无需队列）。null = 无。
    pinned_job: []?Job = &.{},
    /// 可服役（在役）worker 计数：线程活着且未停滞/未 exited（含已标 retire 但尚未退出的
    /// worker——它们仍是真实容量，新队列来了会留下服役）。退役 -1（worker 实际退出）、
    /// 复用/新建 +1（Master）；停滞 detach -1、停滞槽 respawn +1。submit 增长与 maybeReclaim
    /// 都按它判断容量（`workers.items.len` 从不收缩，含退役/停滞槽，不能用）。
    active: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// 当前并发在跑任务数（worker 开工 +1 / 完工 -1；== 服役中 busy worker 数，run-to-completion）。
    /// 与 `inflight`（排队+在途）互补；全在 mutex 内维护。停滞 abandon 也 -1。
    running: usize = 0,
    /// 本波并发达峰：worker 开工时 `running > busy_peak` 则更新；排空后 maybeReclaim 读后清零
    /// （新波次开始）。target 的容量依据（用户定 2026-09-09：峰值=实际并发度，非队列深度）。
    busy_peak: usize = 0,
    /// 停滞放弃计数（测试/可观测）。
    stall_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// spawn/respawn 失败计数（测试/可观测；真失败（OOM/线程配额/cap）才允许出现，且不得风暴）。
    spawn_failed_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// 累计成功创建的 worker 线程数（append 新格 + 复用槽 respawn）。压测里若远超「首波
    /// 扩容 + 复用」的量级 → churn（波波重建）复现，据此断言有界。
    spawn_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// Master 带超时兜底唤醒 latch（§5.1：`waitTimeout` + set/reset）。仅
    /// `stall_timeout_ns>0` 时被等待；只有 Master 线程 wait/reset。
    master_event: Io.Event = .unset,
    /// AS2：pinned worker 专属条件变量。`submitPinned` signal 它、`releasePinned`
    /// broadcast 它，pinnedLoop 等它——避免唤醒共享 `jobs_avail` 上的 elastic 等待者
    /// （唤醒丢失：signal 只叫醒一名等待者，可能不是目标 pinned worker）。
    pinned_cv: Io.Condition = .init,

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
            allocator.free(self.retire);
            allocator.free(self.pinned);
            allocator.free(self.pinned_job);
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
        self.retire = try allocator.alloc(bool, cfg.max_workers);
        @memset(self.retire, false);
        self.pinned = try allocator.alloc(bool, cfg.max_workers);
        @memset(self.pinned, false);
        self.pinned_job = try allocator.alloc(?Job, cfg.max_workers);
        @memset(self.pinned_job, null);

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

    /// 由 Master 事件线程执行的 worker 创建（§3.1：spawn 执行者 = Master async）。
    /// F1/F3 统一复用扫描，两类退役槽都能重新拉起（扫描在 mutex 下完成——stalled/retire 为
    /// 普通内存、与 worker 写互斥）：
    ///   - `stalled[id] && exited[id]`：旧线程已 **detach**（停滞）→ **绝不 join**，直接以新
    ///     线程句柄覆写（`respawnInto`）；
    ///   - `retire[id] && exited[id]`（正常退役）：旧线程已返回（exited 保证已离开 workerMain）
    ///     → **锁外 join** 后覆写（绝不持锁 join——死锁根因）；
    /// 无复用槽且未达 cap 才追加新格；满 cap 且无复用槽返回 `error.NoCapacity`（Master 静默
    /// 跳过——任务由服役 worker 自取消化，不是可上报的 spawn 失败）。
    fn appendWorker(self: *Runtime) !void {
        self.mutex.lockUncancelable(self.io);
        var reuse_id: ?usize = null;
        var must_join = false;
        for (self.workers.items, 0..) |_, id| {
            if (self.stalled[id] and self.exited[id].load(.acquire)) {
                reuse_id = id; // 停滞复用：detach 句柄，绝不 join
                must_join = false;
                break;
            }
        }
        if (reuse_id == null) {
            for (self.workers.items, 0..) |_, id| {
                if (self.retire[id] and self.exited[id].load(.acquire)) {
                    reuse_id = id; // 正常退役复用：须锁外 join
                    must_join = true;
                    break;
                }
            }
        }
        self.mutex.unlock(self.io);

        if (reuse_id) |id| {
            if (must_join) self.workers.items[id].join(); // 锁外 join（旧线程已返回，立即返回）
            try self.respawnInto(id);
            return;
        }
        if (self.workers.items.len >= self.cfg.max_workers) return error.NoCapacity;
        const id = self.workers.items.len;
        const w = try Thread.spawn(.{
            .allocator = self.allocator,
            .stack_size = self.cfg.stack_size,
        }, workerMain, .{ self, id });
        try self.workers.append(self.allocator, w);
        _ = self.active.fetchAdd(1, .monotonic); // 新增在役 worker
        _ = self.spawn_count.fetchAdd(1, .monotonic);
    }

    /// F1/F3：把已退役/停滞槽（旧线程已 exited 确认离开）重新拉起为服役 worker。旧线程
    /// 已不再触碰共享簿记：停滞槽句柄早已 detach（**绝不 join**），正常退役槽由 appendWorker
    /// 在锁外 join 后才进入本函数——本函数只以新线程句柄覆写 `workers.items[id]`。
    /// 先持 mutex 复位槽簿记（reg/retire/stalled/exited/started），后 spawn（新 worker 进场即
    /// 读写自身槽格，须见复位态）；spawn 失败回滚为仍退役/停滞，留待下轮 tick/扩容重试。
    fn respawnInto(self: *Runtime, id: usize) !void {
        self.mutex.lockUncancelable(self.io);
        const was_stalled = self.stalled[id]; // 失败回滚按原退役类型还原（停滞/正常退役）
        const was_retire = self.retire[id];
        self.reg.entries[id] = .{}; // 复位为默认 idle（reclaimable / elastic）
        self.started_ns[id].store(0, .monotonic);
        self.exited[id].store(false, .release);
        self.stalled[id] = false;
        self.retire[id] = false;
        self.pinned[id] = false; // 复用槽必定非 pinned（pinned 槽不退役，除非会话已释放）
        self.pinned_job[id] = null;
        self.mutex.unlock(self.io);
        errdefer {
            self.mutex.lockUncancelable(self.io);
            self.stalled[id] = was_stalled; // 回滚为原退役态（复用失败不虚增容量）
            self.retire[id] = was_retire;
            self.exited[id].store(true, .release);
            self.mutex.unlock(self.io);
        }
        const w = try Thread.spawn(.{
            .allocator = self.allocator,
            .stack_size = self.cfg.stack_size,
        }, workerMain, .{ self, id });
        self.workers.items[id] = w;
        _ = self.active.fetchAdd(1, .monotonic); // 槽复活为在役 worker
        _ = self.spawn_count.fetchAdd(1, .monotonic);
    }

    /// F3：Master 超时兜底 tick 里逐槽恢复——停滞且旧线程已 exited 的槽重新拉起
    /// （自返任务释放后池可恢复满编；无停滞/无退出槽为空操作）。每 tick 至多恢复一个，
    /// 低频不引发 spawn 风暴；调用者须在 `stall_timeout_ns>0` 路径内。
    fn respawnRetired(self: *Runtime) void {
        if (self.cfg.stall_timeout_ns == 0) return;
        const n = self.workers.items.len;
        for (0..n) |id| {
            if (self.stalled[id] and self.exited[id].load(.acquire)) {
                self.respawnInto(id) catch {
                    _ = self.spawn_failed_count.fetchAdd(1, .monotonic);
                    std.debug.print("runtime: worker respawn failed (OOM/线程配额/cap)\n", .{});
                };
                return; // 低频逐个恢复
            }
        }
    }

    /// 是否还存在可复用退役槽（停滞已自退 / 正常退役已退出）。**调用方须已持 mutex**——
    /// stalled/retire 为普通内存、仅 mutex 下写读（本函数读 exited 原子）。未到 cap 时追加
    /// 新格即可；已满 cap 时只有复用槽存在才可能补 worker，据此避免「满 cap 还反复请求
    /// spawn → spawn-failed 风暴」（症状 A）。
    fn hasReusableSlotLocked(self: *const Runtime) bool {
        for (self.workers.items, 0..) |_, id| {
            if (self.exited[id].load(.acquire) and (self.stalled[id] or self.retire[id])) {
                return true;
            }
        }
        return false;
    }

    /// 还有没有补 worker 的空间（cap 未满或有可复用退役槽）。可持 master_mutex 调用（未满
    /// 时只近似读 items.len，与既有 submit/masterMain 风格一致；已满才持 mutex 精确扫描）。
    fn canSpawn(self: *Runtime) bool {
        if (self.workers.items.len < self.cfg.max_workers) return true;
        self.mutex.lockUncancelable(self.io);
        const reusable = self.hasReusableSlotLocked();
        self.mutex.unlock(self.io);
        return reusable;
    }

    /// 取一个任务节点（P3 池化；调用方须持 mutex）：优先复用自由表，空则分配。
    fn acquireNodeLocked(self: *Runtime) !*Node {
        if (self.free_nodes) |n| {
            self.free_nodes = n.next;
            self.free_count -= 1;
            return n;
        }
        return self.allocator.create(Node);
    }

    /// 归还任务节点（P3 池化；调用方须持 mutex）：容量内入自由表复用，超出销毁。
    fn releaseNodeLocked(self: *Runtime, n: *Node) void {
        if (self.free_count < node_pool_cap) {
            n.next = self.free_nodes;
            self.free_nodes = n;
            self.free_count += 1;
        } else {
            self.allocator.destroy(n);
        }
    }

    /// 提交任务（非阻塞；OOM 返回 false）。worker 被唤醒自取（完成即领，§5.1）。
    /// 停机后调用 → false（防停机后入队→无 worker→悬挂 inflight 的接线不匹配）。
    pub fn submit(self: *Runtime, job: Job) bool {
        if (self.shutdown_requested.load(.acquire)) return false;
        self.mutex.lockUncancelable(self.io);
        // 二次检查（停机竞态窗口内到达也拒绝）
        if (self.shutdown_requested.load(.acquire)) {
            self.mutex.unlock(self.io);
            return false;
        }
        // 节点取自池（同临界区，见 free_nodes 注释）；分配失败须在改队列前回滚。
        const node = self.acquireNodeLocked() catch {
            self.mutex.unlock(self.io);
            return false;
        };
        node.* = .{ .job = job };
        const tail = self.queue_tail;
        if (tail) |t| {
            t.next = node;
        } else {
            self.queue_head = node;
        }
        self.queue_tail = node;
        // 新波次边界：上一波已排空（inflight==0）后的首个 submit 重开一「波」——并发达峰
        // 重新起算。否则两波紧邻（排空→回收尚未跑、新任务已入队）会合并成一个峰、永不回落。
        if (self.inflight == 0) self.busy_peak = 0;
        self.inflight += 1;
        const queued_est = self.inflight; // 排队+在途 ≈ backlog 压力
        self.mutex.unlock(self.io);

        // 扩容提示（F1：容量按 `active` 可服役数，不是从不收缩的 workers.items.len）：
        // 积压 > 可服役数 且还有可建容量（未达 cap 或存在可复用退役槽）→ 请 Master 补建。
        // 热路径优化：先用纯原子读判「是否可能积压」（单流常态 queued_est ≤ active → 免锁
        // master_mutex）；确有积压才取锁查容量，避免每次 submit 都付一次 master_mutex。
        const maybe_grow = !self.shutdown_requested.load(.acquire) and
            queued_est > self.active.load(.acquire);
        if (maybe_grow) {
            self.master_mutex.lockUncancelable(self.io);
            const grow = !self.shutdown_requested.load(.acquire) and
                queued_est > self.active.load(.acquire) and
                self.canSpawn();
            if (grow) self.need_worker = true;
            self.master_mutex.unlock(self.io);
            if (grow) {
                Io.Condition.broadcast(&self.master_cv, self.io);
                // timed 兜底模式（stall_timeout_ns>0）：Master 睡在 master_event 上而非 cv
                Io.Event.set(&self.master_event, self.io);
            }
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

    /// F3 in-use 记账：服役中 worker 数（reg 状态 == busy，且槽未停滞/未自退）。
    /// 停滞（detach 退役）与已退出（exited）槽不计；未启用的定容后缀格恒 idle 亦不计。
    /// 与在途**运行中**任务数一致（排队任务不算）。持 mutex 读——reg/stalled 的写都在
    /// 该锁下（respawnInto/scanStalled/workerMain），exited 为原子。
    pub fn busyCount(self: *Runtime) usize {
        self.mutex.lockUncancelable(self.io);
        var n: usize = 0;
        for (self.reg.entries, 0..) |*e, id| {
            if (self.stalled[id]) continue;
            if (self.exited[id].load(.acquire)) continue;
            if (e.state == tables.WState.busy) n += 1;
        }
        self.mutex.unlock(self.io);
        return n;
    }

    // ---- AS2 长流池化：worker 亲和 pinned 1:1（§6.3）----

    /// 为一个长流会话预留一个空闲 worker（1 流 : 1 pinned worker）。成功返回 worker id；
    /// 无空闲/全 pinned 返回 null（调用方回退全局队列）。持 mutex 判定并置位，使该 worker
    /// 之后的空闲谓词只等本会话步骤、进全局队列分支被跳过（与「自领」在同一临界区消解）。
    /// pinned 槽 class=pinned：不参与 §5.5 回收候选、不被 elastic 伸缩挤兑。
    pub fn acquirePinned(self: *Runtime) ?usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.shutdown_requested.load(.acquire)) return null;
        for (self.workers.items, 0..) |_, id| {
            if (self.pinned[id]) continue;
            if (self.stalled[id]) continue;
            if (self.exited[id].load(.acquire)) continue;
            if (self.retire[id]) continue;
            const e = &self.reg.entries[id];
            if (e.state != .idle) continue; // 只取完全空闲 worker（run-to-completion 边界）
            self.pinned[id] = true;
            e.class = .pinned;
            e.waiting = true; // pinned 会话的合法消费等待（§5.2 停滞判定排除）
            self.pinned_job[id] = null;
            // 唤醒可能正睡在共享 jobs_avail 上的该 worker，使其转向 pinnedLoop
            // （否则首个 submitPinned 的 pinned_cv 唤醒会落空）。
            Io.Condition.broadcast(&self.jobs_avail, self.io);
            return id;
        }
        return null;
    }

    /// 把会话步骤下发到 pinned worker（单槽；步骤串行 await，无队列）。返回 false =
    /// 该槽已不可用（已退役/停机/非 pinned），调用方回退全局队列或报错。
    pub fn submitPinned(self: *Runtime, id: usize, job: Job) bool {
        if (id >= self.pinned_job.len) return false;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.pinned[id]) return false;
        if (self.stalled[id] or self.exited[id].load(.acquire) or self.retire[id]) return false;
        if (self.shutdown_requested.load(.acquire)) return false;
        if (self.pinned_job[id] != null) return false; // 单槽：上一步未取走（调用方须串行）
        // 与 submit 同一波次/在途记账：pinned 步骤也计入 inflight（waitIdle/排空回收依赖）。
        if (self.inflight == 0) self.busy_peak = 0;
        self.inflight += 1;
        self.pinned_job[id] = job;
        self.reg.entries[id].waiting = false; // 有活干：不再处于消费等待
        Io.Condition.signal(&self.pinned_cv, self.io); // 只唤醒 pinned worker
        return true;
    }

    /// 会话关闭：释放 pinned 槽（回 elastic 空闲，可被全局队列/回收复用）。
    pub fn releasePinned(self: *Runtime, id: usize) void {
        if (id >= self.pinned_job.len) return;
        self.mutex.lockUncancelable(self.io);
        self.pinned[id] = false;
        self.pinned_job[id] = null;
        if (!self.stalled[id] and !self.exited[id].load(.acquire)) {
            self.reg.entries[id].class = .elastic;
            self.reg.entries[id].waiting = false;
        }
        self.mutex.unlock(self.io);
        Io.Condition.broadcast(&self.pinned_cv, self.io); // 唤醒该 worker 回全局队列
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
        // P3：释放自由表全部驻留节点（须在 shutdown 排空、无并发 submit/release 后）
        while (self.free_nodes) |n| {
            self.free_nodes = n.next;
            self.allocator.destroy(n);
        }
        self.free_count = 0;
        self.reg.deinit(self.allocator);
        self.allocator.free(self.started_ns);
        self.allocator.free(self.stalled);
        self.allocator.free(self.exited);
        self.allocator.free(self.retire);
        self.allocator.free(self.pinned);
        self.allocator.free(self.pinned_job);
        self.allocator.destroy(self);
    }

    // ---- Master / worker 线程函数 ----

    fn masterMain(self: *Runtime) void {
        while (true) {
            // —— 等待「补 worker」/「评估回收」/停机；`stall_timeout_ns>0` 时退居带超时
            // wait（§5.1/§5.2 层2）：超时到点做停滞扫描；否则保持纯事件、零定时器——
            var stall_tick = false;
            self.master_mutex.lockUncancelable(self.io);
            while (!self.shutdown_requested.load(.acquire) and !self.need_worker and !self.need_reclaim) {
                if (!self.hasTimedTick()) {
                    Io.Condition.waitUncancelable(&self.master_cv, self.io, &self.master_mutex);
                } else {
                    // 带超时兜底：不得持 master_mutex 睡 Event → 先放锁再 wait
                    self.master_mutex.unlock(self.io);
                    const woke = waitEventTimeout(&self.master_event, self.io, self.scanPeriodNs());
                    self.master_mutex.lockUncancelable(self.io);
                    if (woke) {
                        Io.Event.reset(&self.master_event); // 消费 latch（仅 Master wait/reset）
                        continue; // 真实事件（submit 扩容 / 排空回收 / 停机）→ 重查标志
                    }
                    stall_tick = true; // 纯超时到点（或罕见虚假唤醒）→ 本轮做停滞扫描
                    break;
                }
            }
            const shutting_down = self.shutdown_requested.load(.acquire);
            var do_grow = false;
            var do_reclaim = false;
            if (!shutting_down and !stall_tick) {
                do_grow = self.need_worker; // 消费 grow / reclaim 请求（两者可同时置位）
                self.need_worker = false;
                do_reclaim = self.need_reclaim;
                self.need_reclaim = false;
            }
            self.master_mutex.unlock(self.io);

            if (shutting_down) break; // 停机优先

            if (stall_tick) {
                // 无待办工作且超时到点：§5.2 层2 停滞兜底扫描（低频，非周期热扫）。
                // 注意：此路径不清 need_worker/need_reclaim——竞态 submit/排空可能刚置位
                //（其 Event.set 在超时判定后才落），留到下一轮由主谓词消费，避免丢请求。
                self.scanStalled();
                self.respawnRetired(); // F3：自返停滞线程的槽重新拉起，池恢复满编
                self.maybeReclaim(); // 排空后也收敛容量（停滞放弃可能把 inflight 降到 0）
                self.reclaimIdle(); // §5.5 空闲回收降容（idle_timeout_ns>0 时生效）
                continue;
            }

            // 非停非超时：处理排空回收事件（先收后扩——同轮两者并存时以此刻状态为准）。
            if (do_reclaim) self.maybeReclaim();

            if (do_grow) {
                // 补建 worker（§3.1 能力 A：spawn 执行者 = Master；容量 = active 可服役数）。
                // submit 只发「提示」，Master 在此实时判容量循环补建（过期/重叠请求不会在
                // cap 上空转）：无容量（满 cap 且无复用槽）静默跳过——任务由服役 worker 自取
                // 消化，不是可上报失败；真 spawn 失败（线程配额等）才计数 + 日志。
                // §5.5：`grow_step>0` 时限每事件至多扩建 step 个（防高并发大起大落）。
                var built: usize = 0;
                const grow_step = @as(usize, self.cfg.grow_step);
                while (self.canSpawn()) {
                    if (grow_step > 0 and built >= grow_step) break;
                    self.appendWorker() catch |e| switch (e) {
                        error.NoCapacity => break, // 竞态中被并发回收/复用耗尽 → 下轮再评估
                        else => {
                            _ = self.spawn_failed_count.fetchAdd(1, .monotonic);
                            std.debug.print("runtime: worker spawn failed (OOM/线程配额)\n", .{});
                            break;
                        },
                    };
                    built += 1;
                    // §5.5 调节器：active 仍低于 desired（running + ceil(backlog/load_factor) + spare）
                    // → 继续补建至积压消化或容量耗尽。默认常量等价既有 `inflight > active`。
                    self.master_mutex.lockUncancelable(self.io);
                    const still_backlogged = blk: {
                        self.mutex.lockUncancelable(self.io);
                        const more = self.needsMoreLocked();
                        self.mutex.unlock(self.io);
                        break :blk more;
                    };
                    self.master_mutex.unlock(self.io);
                    if (!still_backlogged) break;
                }
            }
        }
        // Master 决定停机：置 worker_shutdown 并广播（worker 收尾返回，不自杀）
        self.worker_shutdown.store(true, .release);
        self.mutex.lockUncancelable(self.io);
        Io.Condition.broadcast(&self.jobs_avail, self.io);
        Io.Condition.broadcast(&self.pinned_cv, self.io); // AS2：pinned worker 也须收尾
        self.mutex.unlock(self.io);
    }

    fn workerMain(self: *Runtime, id: usize) void {
        const me = &self.reg.entries[id];
        while (true) {
            self.mutex.lockUncancelable(self.io);
            // AS2：本 worker 已 pinned（会话专属）→ 走 pinned 循环，不进全局队列。
            if (self.pinned[id]) {
                self.mutex.unlock(self.io);
                if (self.pinnedLoop(id)) return;
                continue;
            }
            // 空闲阻塞：队列空 且 未停机 且 未被 Master 标记退役 才睡。醒因三类：
            // 有新任务（自领）/ worker_shutdown / retire[id]（Master 排空后发的退役命令）；
            // AS2：被 acquirePinned 置 pinned 时也醒（外层路由到 pinnedLoop）。
            while (self.queue_head == null and
                !self.worker_shutdown.load(.acquire) and
                !self.retire[id] and
                !self.pinned[id])
            {
                // §5.5 idle_since：首次进入空闲时记录（空闲回收判定基准；0 = 未记录）。
                if (me.idle_since_us == 0) me.idle_since_us = self.nowUs();
                Io.Condition.waitUncancelable(&self.jobs_avail, self.io, &self.mutex);
            }
            // AS2：等待期间被 acquirePinned → 不回全局队列，外层进 pinnedLoop（
            // 与「自领」在同一临界区消解：此判定持锁，优先级高于取全局任务）。
            if (self.pinned[id]) {
                self.mutex.unlock(self.io);
                continue;
            }
            if (self.queue_head) |head| {
                // 完成即领：取一件（空闲边界换任务，§2.1 run-to-completion）
                self.queue_head = head.next;
                if (self.queue_head == null) self.queue_tail = null;
                me.markBusy(); // 状态先行（§5.1）：开工前自写 busy（持锁，Master 读同锁串行化）
                self.started_ns[id].store(self.nowNs(), .monotonic); // 停滞判定基准（§5.2 层2）
                self.retire[id] = false; // 防 churn：转忙即清退役标记（重新有用，Master 下个排空重估）
                self.running += 1;
                if (self.running > self.busy_peak) self.busy_peak = self.running;
                self.mutex.unlock(self.io);

                head.job.run(head.job.ctx);

                // 收尾（持锁写 reg/running/inflight，Master 读同锁串行化）
                self.mutex.lockUncancelable(self.io);
                if (self.stalled[id]) {
                    // §5.2 层2：本 worker 已被 Master 判停滞并 detach——放弃本任务时 Master
                    // 已代为复位 reg/started/running/inflight。任务若自返（如 stop 标志任务），
                    // 不得再写任何共享簿记（含 P3 自由表——停滞是低频异常路径，不池化）：
                    // 只销毁自取节点、置 exited 即退（exited 是最后一条触碰 runtime 的操作，
                    // shutdown 据此有界等待）。
                    self.mutex.unlock(self.io);
                    self.allocator.destroy(head);
                    self.exited[id].store(true, .release);
                    return;
                }
                self.started_ns[id].store(0, .monotonic);
                me.beginIdle(self.nowUs()); // §5.5 idle_since（回收判定基准；state→idle）
                self.running -= 1;
                self.inflight -= 1;
                self.releaseNodeLocked(head); // P3：节点在解锁前归池复用（替代 per-task free）
                const drained = (self.inflight == 0); // 排空事件 → 唯一回收触发
                // 热路径优化：仅当存在弹性超额（active > min_workers）时才可能回收；单流等
                // active==min_workers 时 Master 的 maybeReclaim 必为 `serving<=target` 空操作，
                // 故免去每次排空的 Master 唤醒（少一次 master_mutex 锁 + cv broadcast + 线程调度）。
                // 正确性：target = max(min_workers, min(peak,max)) ≥ min_workers ≥ active ⇒ 不回收。
                const might_reclaim = drained and
                    self.active.load(.acquire) > @as(usize, self.cfg.min_workers);
                self.mutex.unlock(self.io);
                Io.Condition.broadcast(&self.idle_cv, self.io);

                if (might_reclaim) self.requestReclaim(); // 排空后唤醒 Master 评估回收
                continue;
            }
            // 队列空：shutdown 或 retire 命令。退出前二次确认在**同锁**内完成（queue_head==null
            // 已证——期间来了任务必被取走并转 busy 自清 retire，此处不会误退丢任务）。
            // 决定退出：置 retiring（Master 只读状态可见收尾中）、exited（最后触碰）、
            // active -1（槽退役）。不自建不自杀——这是执行 Master 的命令。
            // 注意：**不**清 retire[id]——退役槽必须保留标记到复用（appendWorker 凭
            // `retire && exited` 识别可复用槽，锁外 join 后覆写）；槽复活由 respawnInto 复位。
            me.beginRetiring();
            self.started_ns[id].store(0, .monotonic);
            self.exited[id].store(true, .release);
            _ = self.active.fetchSub(1, .monotonic);
            self.mutex.unlock(self.io);
            return;
        }
    }

    /// AS2：pinned worker 主循环（§6.3 长流会话 1:1 亲和）。只接本会话步骤（pinned_job），
    /// **绝不进全局队列**；空闲时阻塞等本会话下一步并置 `waiting=true`（合法消费等待，
    /// §5.2 停滞判定排除）。返回 true = 线程应退出（退役/停机），false = pinned 被释放
    /// （会话关闭）→ 回全局队列（外层 workerMain 继续）。
    fn pinnedLoop(self: *Runtime, id: usize) bool {
        const me = &self.reg.entries[id];
        while (true) {
            self.mutex.lockUncancelable(self.io);
            if (!self.pinned[id]) { // releasePinned → 回全局队列
                self.mutex.unlock(self.io);
                return false;
            }
            if (self.pinned_job[id]) |job| {
                self.pinned_job[id] = null;
                me.markBusy(); // 状态先行（§5.1）
                self.started_ns[id].store(self.nowNs(), .monotonic);
                self.running += 1;
                if (self.running > self.busy_peak) self.busy_peak = self.running;
                self.mutex.unlock(self.io);

                job.run(job.ctx);

                self.mutex.lockUncancelable(self.io);
                if (self.stalled[id]) {
                    // 被 Master 判停滞并 detach：不再写共享簿记（同 workerMain 停滞分支）
                    self.mutex.unlock(self.io);
                    self.exited[id].store(true, .release);
                    return true;
                }
                self.started_ns[id].store(0, .monotonic);
                me.beginIdle(self.nowUs());
                me.class = .pinned; // beginIdle 回落 elastic；pinned 槽保持类
                me.waiting = true;
                self.running -= 1;
                self.inflight -= 1;
                const drained = (self.inflight == 0);
                self.mutex.unlock(self.io);
                Io.Condition.broadcast(&self.idle_cv, self.io);
                if (drained and self.active.load(.acquire) > @as(usize, self.cfg.min_workers)) {
                    self.requestReclaim();
                }
                continue;
            }
            if (self.retire[id] or self.worker_shutdown.load(.acquire)) {
                // 退役/停机：清 pinned 语义，收尾返回（Master 锁外 join 复用槽）
                self.pinned[id] = false;
                me.beginRetiring();
                self.started_ns[id].store(0, .monotonic);
                self.exited[id].store(true, .release);
                _ = self.active.fetchSub(1, .monotonic);
                self.mutex.unlock(self.io);
                return true;
            }
            // 合法消费等待：等本会话下一步（不接全局任务、不被回收——class=pinned）。
            // 用独立 pinned_cv：submitPinned 只唤醒 pinned worker，不惊扰 elastic 等待者。
            me.waiting = true;
            if (me.idle_since_us == 0) me.idle_since_us = self.nowUs();
            Io.Condition.waitUncancelable(&self.pinned_cv, self.io, &self.mutex);
            self.mutex.unlock(self.io); // wait 返回时已持有锁；解锁后回顶部重新判定
        }
    }

    /// 单调纳秒（worker 开工时刻 / 停滞扫描用；同源同钟，差即有界）。
    fn nowNs(self: *const Runtime) u64 {
        return @intCast(Io.Timestamp.now(self.io, .awake).nanoseconds);
    }

    /// 单调微秒（worker 空闲起点 idle_since_us / 空闲回收判定用；同源同钟）。
    fn nowUs(self: *const Runtime) u64 {
        return @intCast(@divTrunc(Io.Timestamp.now(self.io, .awake).nanoseconds, std.time.ns_per_us));
    }

    /// §5.5 目标容量调节器：在役数是否仍不足以消化积压（供 Master 补建循环）。
    /// `desired = min(running + ceil(backlog / load_factor) + spare, max_workers)`——
    /// 供应领先需求；默认 load_factor=1 / spare=0 时等价既有 `inflight > active`。
    /// 调用方持 mutex。
    fn needsMoreLocked(self: *Runtime) bool {
        const backlog = self.inflight -| self.running; // 排队（inflight = 排队 + 在途）
        const lf = @max(@as(usize, self.cfg.load_factor), 1);
        const demand = (backlog + lf - 1) / lf;
        const desired = @min(
            self.running + demand + @as(usize, self.cfg.spare),
            @as(usize, self.cfg.max_workers),
        );
        return self.active.load(.monotonic) < desired;
    }

    /// §5.5 回收候选：持 mutex 把「最老空闲的 elastic worker」标 `retire`，
    /// 至多 `max_mark` 个，且不使在役数跌破 `floor`（min_workers 总量下限）。
    /// `min_age_us > 0` 时只挑空闲已满该时长者（空闲回收）；0 = 任意空闲（排空回落）。
    /// 返回标记数；只挑选 `workers.items` 范围内的活槽（未启用后缀格不参与）。
    /// 调用方负责广播唤醒（锁外）。
    fn markOldestIdleLocked(
        self: *Runtime,
        floor: usize,
        max_mark: usize,
        min_age_us: u64,
        now_us: u64,
    ) usize {
        var serving = self.active.load(.monotonic);
        // 已标 retire、尚未退出的槽是「pending 退役」，终将离开，不能计入可留容量，
        // 否则 maybeReclaim 与 reclaimIdle 先后裁决时会把 floor 之下的也标掉（实测 active=0）。
        for (self.workers.items, 0..) |_, id| {
            if (self.stalled[id]) continue;
            if (self.retire[id] and !self.exited[id].load(.acquire)) serving -|= 1;
        }
        var marked: usize = 0;
        while (marked < max_mark and serving > floor) {
            var pick: ?usize = null;
            var best: u64 = std.math.maxInt(u64);
            for (self.workers.items, 0..) |_, id| {
                if (self.stalled[id]) continue;
                if (self.exited[id].load(.acquire)) continue;
                if (self.retire[id]) continue;
                const e = &self.reg.entries[id];
                if (e.state != tables.WState.idle) continue;
                if (e.class == .pinned) continue; // pinned 长流永不入回收候选
                if (min_age_us > 0) {
                    if (e.idle_since_us == 0) continue;
                    if (now_us -| e.idle_since_us < min_age_us) continue;
                }
                // idle_since_us == 0 = 尚未记录空闲起点（新槽 / 复用后未入等）→ 视为**最新**，
                // 不作为最老候选（否则刚 respawn 的槽会被优先误收，破坏槽位容量恢复）。
                const since = if (e.idle_since_us != 0) e.idle_since_us else std.math.maxInt(u64);
                if (since < best) {
                    best = since;
                    pick = id;
                }
            }
            const id = pick orelse break;
            self.retire[id] = true;
            serving -= 1;
            marked += 1;
        }
        return marked;
    }

    /// §5.5 空闲回收降容（`idle_timeout_ns>0` 时由 Master 兜底 tick 调用）：
    /// 最老空闲 elastic 闲置超时且在役数 > min_workers → 标 retiring（worker 在空闲
    /// 边界自退，Master 锁外 join 复用槽）。步长受 `shrink_step` 限（0=不限）。
    fn reclaimIdle(self: *Runtime) void {
        if (self.cfg.idle_timeout_ns == 0) return;
        const timeout_us = self.cfg.idle_timeout_ns / std.time.ns_per_us;
        const now_us = self.nowUs();
        const floor = @as(usize, self.cfg.min_workers);
        const max_mark = if (self.cfg.shrink_step > 0)
            @as(usize, self.cfg.shrink_step)
        else
            std.math.maxInt(usize);
        self.mutex.lockUncancelable(self.io);
        const marked = self.markOldestIdleLocked(floor, max_mark, timeout_us, now_us);
        self.mutex.unlock(self.io);
        if (marked > 0) Io.Condition.broadcast(&self.jobs_avail, self.io);
    }

    /// §5.5/F1：排空事件后的容量收敛（Master 唯一回收触发，纯事件、零定时器依赖）。
    /// 目标 = max(min_workers, min(本波并发达峰 busy_peak, max_workers))——并发峰值是真实
    /// 需要的并行度：微小任务风暴即使排起长队、同时 busy 峰值也低 → 排空后可回落；真需要
    /// N 路并行才保留 N。盈余（可服役 > target）→ 对**最老空闲的 elastic** worker 置
    /// retire 并广播唤醒（worker 空闲边界自退；期间来了任务则转忙自清，绝不中途误退）。
    /// §5.5 完整化：滞后死区 `keep_watermark`（serving ≤ target+keep 不动作，防抖振）+
    /// 收步长 `shrink_step`（每事件至多收 step 个，0=整波回落）。默认常量与既往一致。
    fn maybeReclaim(self: *Runtime) void {
        self.mutex.lockUncancelable(self.io);
        if (self.inflight != 0) {
            // 排空请求到达时已有新任务入队 → 波次未真正结束：保留峰，下个真排空再评估
            self.mutex.unlock(self.io);
            return;
        }
        const peak = self.busy_peak;
        self.busy_peak = 0; // 读后清零：此后为下一波次的并发达峰
        const target = @max(
            @as(usize, self.cfg.min_workers),
            @min(peak, @as(usize, self.cfg.max_workers)),
        );
        const serving = self.active.load(.monotonic); // 同锁下与 worker 退出互斥
        self.mutex.unlock(self.io);

        // §5.5 滞后死区 + 收步长：纯裁决原语（确定性可测），返回本事件回收数（0 = 不动作）
        const keep = @as(usize, self.cfg.keep_watermark);
        const over = reclaimBudget(serving, target, keep, @as(usize, self.cfg.shrink_step));
        if (over == 0) return;

        // 标最老空闲的 elastic 在役 worker（reg idle、非 stalled/exited/已在 retire、非 pinned）。
        // 锁内判写（与 worker 忙/闲、退出、转忙自清互斥）；busy/pinned 永不入候选。
        self.mutex.lockUncancelable(self.io);
        const marked = self.markOldestIdleLocked(target, over, 0, 0);
        self.mutex.unlock(self.io);
        if (marked > 0) Io.Condition.broadcast(&self.jobs_avail, self.io); // 唤醒被标记者收尾
    }

    /// F1：worker 完工把 `inflight` 减到 0（排空事件）后、锁外请求 Master 评估回收。
    /// 唯一回收触发——正确性不依赖定时器（stall_timeout_ns==0 的纯事件模式同样收敛）。
    fn requestReclaim(self: *Runtime) void {
        self.master_mutex.lockUncancelable(self.io);
        if (!self.shutdown_requested.load(.acquire)) self.need_reclaim = true;
        self.master_mutex.unlock(self.io);
        Io.Condition.broadcast(&self.master_cv, self.io);
        if (self.hasTimedTick()) Io.Event.set(&self.master_event, self.io); // timed 兜底模式
    }

    /// Master 带超时等待时长：stall / idle 两个兜底阈值的较小正值（下限 1ms，防病态小值高频空扫）。
    fn scanPeriodNs(self: *const Runtime) u64 {
        var p: u64 = 0;
        if (self.cfg.stall_timeout_ns > 0) p = self.cfg.stall_timeout_ns;
        if (self.cfg.idle_timeout_ns > 0) {
            p = if (p == 0) self.cfg.idle_timeout_ns else @min(p, self.cfg.idle_timeout_ns);
        }
        return @max(p, std.time.ns_per_ms);
    }

    /// 是否需要 Master 带超时兜底 tick（停滞扫描 / 空闲回收任一启用）。
    /// 两者皆 0 = 纯事件模式：Master 睡 Condition，零定时器，行为与既往一致。
    fn hasTimedTick(self: *const Runtime) bool {
        return self.cfg.stall_timeout_ns > 0 or self.cfg.idle_timeout_ns > 0;
    }

    /// §5.2 层2 停滞扫描（Master 带超时 wait 兜底，低频）。判定：busy worker 开工超过
    /// stall_timeout_ns 未完工 → 停滞。处理：detach 线程句柄（停机跳过 join）、复位
    /// reg/started/inflight、计 stall_count。卡死（永不退出）槽退役（遗留 OS 线程 =
    /// detach 数）；任务若自返（置 exited），槽由 F3 `respawnRetired`/`appendWorker` 复用
    /// 恢复（见上）。锁内完成全部判写（与 worker 簿记互斥）。
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
            if (self.running > 0) self.running -= 1; // 该 worker 的在跑任务同样放弃
            _ = self.active.fetchSub(1, .monotonic); // 槽退役（不复活前不计入可服役数）
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
        Io.Condition.broadcast(&self.pinned_cv, self.io); // AS2：pinned worker 也须被叫醒
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

test "runtime: 弹性扩容——积压驱动补建至 cap，max 界住线程数（确定性）" {
    const rt = try Runtime.init(std.heap.c_allocator, .{ .min_workers = 1, .max_workers = 8 });
    defer {
        rt.shutdown();
        rt.deinit();
    }
    try testing.expectEqual(@as(usize, 1), rt.workers.items.len); // eager 下限

    // 确定性构造积压：直接置 inflight=100 / running=0（不投真实任务），令
    // desired = min(running + ceil(backlog/load_factor) + spare, max_workers) = 8。
    // 不依赖「单个 eager worker 何时把 1000 个琐碎任务排空」的调度时序——旧写法正是
    // 此竞态：worker 抢在 Master 补建前排空队列 → workers.items.len==1 偶发失败（CI）。
    rt.mutex.lockUncancelable(rt.io);
    rt.inflight = 100;
    rt.running = 0;
    try testing.expect(rt.needsMoreLocked()); // active(1) < desired(8)：确需补建
    rt.mutex.unlock(rt.io);

    // 以 Master 角色就地补建：逐次 appendWorker（= masterMain do_grow 的 spawn 原语）
    // 直至满即拒（NoCapacity）；每次都不越 max_workers，达 cap 后不再补建。
    var built: usize = 0;
    while (true) {
        rt.appendWorker() catch |e| switch (e) {
            error.NoCapacity => break, // 满 cap：满即拒（§5.4），绝不扩容
            else => return e,
        };
        built += 1;
        try testing.expect(rt.workers.items.len <= 8);
    }
    try testing.expectEqual(@as(usize, 7), built); // 1 → 8
    try testing.expectEqual(@as(usize, 8), rt.workers.items.len);
    try testing.expectError(error.NoCapacity, rt.appendWorker()); // 满后再调，仍不越界

    // 容量已足：调节器目标被 max_workers 夹住，不再要求补建
    rt.mutex.lockUncancelable(rt.io);
    const more = rt.needsMoreLocked();
    rt.mutex.unlock(rt.io);
    try testing.expect(!more);

    // 清理构造的假积压（inflight 仅簿记；真实队列为空，worker 空闲等待，shutdown 干净）
    rt.mutex.lockUncancelable(rt.io);
    rt.inflight = 0;
    rt.mutex.unlock(rt.io);
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

// ---- F3：停滞槽复用 + in-use 记账（detach 后池可恢复满编）----

/// 短占用任务体：睡 `ms` 毫秒保持 worker busy（可观测），随后计数 +1。
/// 时长须 < stall_timeout，避免被停滞扫描误杀（Master 只在空闲超时 tick 扫）。
const SleepJob = struct {
    ms: u32,
    done: *std.atomic.Value(u32),

    fn run(ctx: *anyopaque) void {
        const sj: *SleepJob = @ptrCast(@alignCast(ctx));
        tSleepMs(sj.ms);
        _ = sj.done.fetchAdd(1, .monotonic);
    }
};

/// 汇聚任务（**确定性同步点**）：自旋至本波 `started >= want` 才完工。N 个此类任务必须
/// N 个 worker 才能全部开工 → 强制 Master 补建到 N，不依赖「谁先被调度 / 任务多快排空」。
/// 有界预算（超时即放行）避免真失败时把测试挂死；断言仍以确定状态为准。
const BarrierJob = struct {
    started: *std.atomic.Value(usize),
    done: *std.atomic.Value(u32),
    want: usize,
    budget_ns: u64 = 5 * std.time.ns_per_s,

    fn run(ctx: *anyopaque) void {
        const b: *BarrierJob = @ptrCast(@alignCast(ctx));
        _ = b.started.fetchAdd(1, .acq_rel);
        const ioinst = Io.Threaded.global_single_threaded.io();
        const deadline = Io.Timestamp.now(ioinst, .awake).nanoseconds + @as(i96, @intCast(b.budget_ns));
        while (b.started.load(.acquire) < b.want) {
            if (Io.Timestamp.now(ioinst, .awake).nanoseconds >= deadline) break;
            std.Thread.yield() catch {};
        }
        _ = b.done.fetchAdd(1, .monotonic);
    }
};

/// 有界轮询 `rt.busyCount() == want`（want=0 亦精确匹配）；超时返回 false（防挂死）。
fn pollBusy(rt: *Runtime, want: usize, iter: usize, ms: u64) bool {
    var i: usize = 0;
    while (i < iter) : (i += 1) {
        if (rt.busyCount() == want) return true;
        tSleepMs(ms);
    }
    return rt.busyCount() == want;
}

/// 有界轮询：`done` 计数达 want 且池已空（busyCount==0）；超时返回 false。
fn pollDrained(rt: *Runtime, done: *const std.atomic.Value(u32), want: u32, iter: usize, ms: u64) bool {
    var i: usize = 0;
    while (i < iter) : (i += 1) {
        if (done.load(.acquire) == want and rt.busyCount() == 0) return true;
        tSleepMs(ms);
    }
    return done.load(.acquire) == want and rt.busyCount() == 0;
}

test "runtime: F3 in-use 记账——停滞 detach 后 busyCount 只算服役 worker，不误计已放弃格（确定性）" {
    var probe = StallJob{ .budget_ns = 60 * std.time.ns_per_s };
    const rt = try Runtime.init(std.heap.c_allocator, .{
        .min_workers = 1,
        .max_workers = 4,
        .stall_timeout_ns = 120 * std.time.ns_per_ms,
    });
    defer {
        probe.stop.store(true, .release);
        rt.shutdown();
        rt.deinit();
    }

    // id0（唯一引导 worker）先占住长转任务（确定性：min=1 时只有它能接）
    try testing.expect(rt.submit(.{ .run = StallJob.run, .ctx = &probe }));

    // 汇聚任务强制补建到 max_workers=4：3 个任务必须 3 个空闲 worker 才能全部开工
    //（id0 被长转占住）→ 确定性满编，不依赖调度顺序/任务完成速度。
    var started = std.atomic.Value(usize).init(0);
    var done = std.atomic.Value(u32).init(0);
    var bars: [3]BarrierJob = undefined;
    for (&bars) |*b| b.* = .{ .started = &started, .done = &done, .want = 3 };
    for (&bars) |*b| try testing.expect(rt.submit(.{ .run = BarrierJob.run, .ctx = b }));
    var grew = false;
    for (0..2000) |_| { // 有界；确定条件：补建到 cap
        if (rt.workers.items.len == 4) {
            grew = true;
            break;
        }
        tSleepMs(2);
    }
    try testing.expect(grew);
    rt.waitIdle();
    try testing.expectEqual(@as(u32, 3), done.load(.acquire));

    // 确定性 detach：把 id0 的开工时刻置为「很久以前」，直接触发停滞扫描
    //（不等 120ms 真实时钟 / Master tick；扫描只认 now-started 关系）。
    rt.mutex.lockUncancelable(rt.io);
    rt.started_ns[0].store(1, .monotonic);
    rt.mutex.unlock(rt.io);
    rt.scanStalled();
    try testing.expectEqual(@as(usize, 1), rt.stall_count.load(.acquire));
    try testing.expect(rt.stalled[0]);
    try testing.expect(!rt.exited[0].load(.acquire)); // 长转任务仍在跑，尚未自退

    // busyCount 记账：把「已停滞的 id0」与 3 个服役槽都标 busy；stalled 槽必须被排除
    // → 恰 3（若误计 id0 则为 4）。窗口内临时 inflight=1 使 Master 的空闲回收裁决退避。
    rt.mutex.lockUncancelable(rt.io);
    rt.inflight = 1;
    rt.reg.entries[0].state = .busy; // id0：stalled=true → 不得计入
    rt.reg.entries[1].markBusy();
    rt.reg.entries[2].markBusy();
    rt.reg.entries[3].markBusy();
    rt.mutex.unlock(rt.io);
    try testing.expectEqual(@as(usize, 3), rt.busyCount());

    // 还原簿记（真实 worker 仍空闲等待；shutdown 会置 worker_shutdown 收尾）
    rt.mutex.lockUncancelable(rt.io);
    rt.reg.entries[0].beginIdle(0);
    rt.reg.entries[1].beginIdle(0);
    rt.reg.entries[2].beginIdle(0);
    rt.reg.entries[3].beginIdle(0);
    rt.inflight = 0;
    rt.mutex.unlock(rt.io);
}

test "runtime: F3 槽位容量恢复——停滞自返后槽复用，二次突发可再达 max_workers 满编" {
    var probe = StallJob{ .budget_ns = 60 * std.time.ns_per_s };
    const rt = try Runtime.init(std.heap.c_allocator, .{
        .min_workers = 1,
        .max_workers = 4,
        .stall_timeout_ns = 100 * std.time.ns_per_ms,
    });
    defer {
        probe.stop.store(true, .release);
        rt.shutdown();
        rt.deinit();
    }

    // 与上一测试相同的前戏：id0 wedged → detach，池扩到 4（3 服役 + 1 退役）
    try testing.expect(rt.submit(.{ .run = StallJob.run, .ctx = &probe }));
    var done0 = std.atomic.Value(u32).init(0);
    var w0: [5]SleepJob = undefined;
    for (&w0) |*j| j.* = .{ .ms = 40, .done = &done0 };
    for (&w0) |*j| try testing.expect(rt.submit(.{ .run = SleepJob.run, .ctx = j }));
    var stalled = false;
    for (0..600) |_| {
        if (rt.stall_count.load(.acquire) >= 1 and rt.workers.items.len == 4) {
            stalled = true;
            break;
        }
        tSleepMs(10);
    }
    try testing.expect(stalled);
    try testing.expect(rt.stalled[0]);

    // 满编但仅 3 服役：4 路并发无法全忙（此时忙得上限 = 3，容量已损失 1）
    var doneB = std.atomic.Value(u32).init(0);
    var wb: [4]SleepJob = undefined;
    for (&wb) |*j| j.* = .{ .ms = 40, .done = &doneB };
    for (&wb) |*j| try testing.expect(rt.submit(.{ .run = SleepJob.run, .ctx = j }));
    try testing.expect(pollBusy(rt, 3, 200, 3));
    try testing.expect(pollDrained(rt, &doneB, 4, 300, 10));

    // 放停靠标志 → wedged 线程自返（置 exited[0]）→ Master 超时 tick 复用槽（respawnInto）。
    // 注：exited[0] 中间态可能极短（下一 tick 即被复用复位），只轮询稳定的终态——复用后
    // stalled/exited 均为 false（复用是清这两个标志的唯一路径，此前 stalled[0] 已确认为 true）。
    probe.stop.store(true, .release);
    var respawned = false;
    for (0..600) |_| {
        if (!rt.stalled[0] and !rt.exited[0].load(.acquire)) {
            respawned = true;
            break;
        }
        tSleepMs(20);
    }
    try testing.expect(respawned);

    // 容量恢复：4 个短占用任务 → 4 路全忙（busyCount == 4 = max_workers），停机干净
    var doneC = std.atomic.Value(u32).init(0);
    var wc: [4]SleepJob = undefined;
    for (&wc) |*j| j.* = .{ .ms = 40, .done = &doneC };
    for (&wc) |*j| try testing.expect(rt.submit(.{ .run = SleepJob.run, .ctx = j }));
    try testing.expect(pollBusy(rt, 4, 200, 3));
    try testing.expect(pollDrained(rt, &doneC, 4, 300, 10));
    // defer 的 shutdown：复用后的新线程照常 join——干净返回即证明无悬挂
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

// ---- F1 hybrid 纯事件回收：排空事件回落（用户定 2026-09-09：目标 = max(min, min(并发达峰, max))）----

/// 有界轮询 `rt.active == want`（在役可服役 worker 数；want=0 亦精确匹配）。
fn pollActive(rt: *Runtime, want: usize, iter: usize, ms: u64) bool {
    var i: usize = 0;
    while (i < iter) : (i += 1) {
        if (rt.active.load(.acquire) == want) return true;
        tSleepMs(ms);
    }
    return rt.active.load(.acquire) == want;
}

fn nsNow() i96 {
    return Io.Timestamp.now(Io.Threaded.global_single_threaded.io(), .awake).nanoseconds;
}

test "runtime: F1 shrink——大并发波撑满后，小并发波排空回落至 min_workers（确定性同步点）" {
    // 用「汇聚任务」强制 Master 补建到 max_workers：12 个任务必须 8 个 worker 才能全部
    // 开工（并发达峰=8）→ 不依赖任务完成速度/调度顺序；再以单任务波（峰=1）回落 min=1。
    var done = std.atomic.Value(u32).init(0);
    var started = std.atomic.Value(usize).init(0);
    var jobs: [12]BarrierJob = undefined;
    for (&jobs) |*j| j.* = .{ .started = &started, .done = &done, .want = 8 };
    const rt = try Runtime.init(std.heap.c_allocator, .{ .min_workers = 1, .max_workers = 8 });
    defer {
        rt.shutdown();
        rt.deinit();
    }

    // 波 1：12 个汇聚任务（want=8）→ 必须补建到 cap 才能全部开工
    for (&jobs) |*j| try testing.expect(rt.submit(.{ .run = BarrierJob.run, .ctx = j }));
    var reached_max = false;
    for (0..2000) |_| { // 有界（真失败不悬挂）；确定条件：8 worker 就绪
        if (rt.workers.items.len == 8) {
            reached_max = true;
            break;
        }
        tSleepMs(2);
    }
    try testing.expect(reached_max); // 确曾用到满编并行（否则无从回落）
    rt.waitIdle();
    try testing.expectEqual(@as(u32, 12), done.load(.acquire));
    // 排空后保留本波并发达峰（8），不回落（背靠背大波不再重建 → 防 churn）
    try testing.expectEqual(@as(usize, 8), rt.active.load(.acquire));

    // 波 2：单任务（并发达峰=1）排空 → maybeReclaim 回落至 min_workers=1
    var one = std.atomic.Value(u32).init(0);
    var one_job = SleepJob{ .ms = 5, .done = &one };
    try testing.expect(rt.submit(.{ .run = SleepJob.run, .ctx = &one_job }));
    rt.waitIdle();
    try testing.expect(pollActive(rt, 1, 1000, 5));
    // 全程无 spawn 失败、计数精确（12 + 1）
    try testing.expectEqual(@as(usize, 0), rt.spawn_failed_count.load(.acquire));
    try testing.expectEqual(@as(u32, 1), one.load(.acquire));
}

test "runtime: F1 100×500 同尺寸波——容量有界、无 spawn 失败风暴、计数精确" {
    var ctx = TestCtx{};
    const rt = try Runtime.init(std.heap.c_allocator, .{ .min_workers = 1, .max_workers = 8 });
    defer {
        rt.shutdown();
        rt.deinit();
    }
    const waves: usize = 100;
    const per_wave: usize = 500;
    const t0 = nsNow();
    var accepted: usize = 0;
    for (0..waves) |_| {
        var i: usize = 0;
        while (i < per_wave) : (i += 1) {
            if (rt.submit(.{ .run = TestCtx.bump, .ctx = &ctx })) accepted += 1;
        }
        rt.waitIdle();
    }
    const dt_ms = @divTrunc(@as(i64, @intCast(nsNow() - t0)), std.time.ns_per_ms);
    std.debug.print("f1: 100x500 waves done in {d}ms len={d} active={d} spawns={d} spawnfail={d}\n", .{
        dt_ms,                         rt.workers.items.len,                 rt.active.load(.acquire),
        rt.spawn_count.load(.acquire), rt.spawn_failed_count.load(.acquire),
    });
    try testing.expectEqual(per_wave * waves, accepted); // 计数精确
    try testing.expectEqual(@as(u32, @intCast(accepted)), ctx.counter.load(.acquire)); // 已执行 == 已提交
    try testing.expect(rt.workers.items.len <= 8); // 容量有界 ≤ max_workers
    try testing.expectEqual(@as(usize, 0), rt.spawn_failed_count.load(.acquire)); // 无 spawn 失败风暴
}

test "runtime: F1 lazy min_workers=0——大并发波保留容量、小波回落后可再扩容无死锁（确定性同步点）" {
    // 纯事件语义：池按「上一波真实并发需求」保留容量（min_workers=0 也不在干活时撤到 0）。
    // 大波用汇聚任务**强制补建**（≥4 worker 才能全部开工）；随后单任务小波把容量收敛回 1；
    // 再次大波可复用退役槽扩容（无死锁/无 spawn 失败/计数精确）。
    var done = std.atomic.Value(u32).init(0);
    var started = std.atomic.Value(usize).init(0);
    var big: [12]BarrierJob = undefined;
    for (&big) |*j| j.* = .{ .started = &started, .done = &done, .want = 4 };
    const rt = try Runtime.init(std.heap.c_allocator, .{ .min_workers = 0, .max_workers = 8 });
    defer {
        rt.shutdown();
        rt.deinit();
    }
    try testing.expectEqual(@as(usize, 0), rt.workers.items.len); // 懒就绪：引导期零 worker

    // 波 1（大）：懒就绪首任务触发 spawn；汇聚任务强制补建（≥4 worker 才能全部开工）
    for (&big) |*j| try testing.expect(rt.submit(.{ .run = BarrierJob.run, .ctx = j }));
    var grew = false;
    for (0..2000) |_| { // 有界；确定条件：至少 4 个 worker 就绪
        if (rt.active.load(.acquire) >= 4) {
            grew = true;
            break;
        }
        tSleepMs(2);
    }
    try testing.expect(grew);
    rt.waitIdle();
    try testing.expectEqual(@as(u32, 12), done.load(.acquire));

    // 波 2（小）：单任务 → 并发达峰=1 → 排空后容量收敛（回落），不残留满编空闲
    var one = std.atomic.Value(u32).init(0);
    var one_job = SleepJob{ .ms = 5, .done = &one };
    try testing.expect(rt.submit(.{ .run = SleepJob.run, .ctx = &one_job }));
    rt.waitIdle();
    try testing.expect(pollActive(rt, 1, 1000, 5));

    // 波 3（再大）：复用退役槽扩容（无 deadlock、无 spawn 失败、计数精确）
    var done2 = std.atomic.Value(u32).init(0);
    var big2: [8]SleepJob = undefined;
    for (&big2) |*j| j.* = .{ .ms = 20, .done = &done2 };
    for (&big2) |*j| try testing.expect(rt.submit(.{ .run = SleepJob.run, .ctx = j }));
    rt.waitIdle();
    try testing.expectEqual(@as(u32, 8), done2.load(.acquire));
    try testing.expectEqual(@as(u32, 1), one.load(.acquire));
    try testing.expectEqual(@as(usize, 0), rt.spawn_failed_count.load(.acquire));
    try testing.expect(rt.workers.items.len <= 8);
}

test "runtime: F1 400 波(每波 1000 + 每 5 波追加 8 小)——快速终止、计数精确、spawn-failed≈0" {
    // 曾复现 churn/挂起的确切波形：大批波次后接小任务。要求快速终止（无挂起/无 churn 抖动）、
    // 已执行 == 已提交、spawn 失败≈0。
    var ctx = TestCtx{};
    const rt = try Runtime.init(std.heap.c_allocator, .{ .min_workers = 1, .max_workers = 8 });
    defer {
        rt.shutdown();
        rt.deinit();
    }
    const waves: usize = 400;
    const per_wave: usize = 1000;
    const extra: usize = 8; // 每 5 波在排空前追加
    const expected_extra = (waves / 5) * extra;
    const t0 = nsNow();
    var accepted: usize = 0;
    var wi: usize = 0;
    while (wi < waves) : (wi += 1) {
        var i: usize = 0;
        while (i < per_wave) : (i += 1) {
            if (rt.submit(.{ .run = TestCtx.bump, .ctx = &ctx })) accepted += 1;
        }
        if (wi % 5 == 0) {
            var j: usize = 0;
            while (j < extra) : (j += 1) {
                if (rt.submit(.{ .run = TestCtx.bump, .ctx = &ctx })) accepted += 1;
            }
        }
        rt.waitIdle();
    }
    const dt_ms = @divTrunc(@as(i64, @intCast(nsNow() - t0)), std.time.ns_per_ms);
    std.debug.print("f1: 400x1000(+8/5) waves done in {d}ms accepted={d} spawns={d} spawnfail={d}\n", .{
        dt_ms, accepted, rt.spawn_count.load(.acquire), rt.spawn_failed_count.load(.acquire),
    });
    try testing.expectEqual(waves * per_wave + expected_extra, accepted);
    try testing.expectEqual(@as(u32, @intCast(accepted)), ctx.counter.load(.acquire)); // 已执行 == 已提交
    try testing.expect(rt.workers.items.len <= 8);
    try testing.expectEqual(@as(usize, 0), rt.spawn_failed_count.load(.acquire));
    try testing.expect(dt_ms < 120_000); // 快速终止（非挂起量级）；数值仅作报告口径
}

// ---- AS3 容量调节器：目标容量 / 空闲回收降容 / 最老优先 + floor + pinned 排除 ----

test "runtime: AS3 调节器目标容量——load_factor 折算 + spare 安全垫（确定性）" {
    const rt = try Runtime.init(std.heap.c_allocator, .{
        .min_workers = 0,
        .max_workers = 16,
        .load_factor = 4,
        .spare = 2,
    });
    defer {
        rt.shutdown();
        rt.deinit();
    }

    rt.mutex.lockUncancelable(rt.io);
    rt.inflight = 10; // 排队 + 在途
    rt.running = 2; // 在途；backlog = 8
    // demand = ceil(backlog/load_factor) = ceil(8/4) = 2；desired = running + demand + spare = 6
    try testing.expect(rt.needsMoreLocked()); // active 0 < 6
    rt.active.store(5, .monotonic);
    try testing.expect(rt.needsMoreLocked()); // 5 < 6
    rt.active.store(6, .monotonic);
    try testing.expect(!rt.needsMoreLocked()); // 6 == 6 容量已足
    rt.inflight = 0;
    rt.running = 0;
    rt.active.store(0, .monotonic);
    rt.mutex.unlock(rt.io);
}

test "runtime: AS3 markOldestIdleLocked——最老优先 + floor 下限 + pinned 排除（确定性）" {
    var done = std.atomic.Value(u32).init(0);
    var jobs: [4]SleepJob = undefined;
    for (&jobs) |*j| j.* = .{ .ms = 5, .done = &done };
    // min==max==4 ⇒ active==min，排空不触发 requestReclaim → Master 不并发裁决，
    // 本测试的直调裁决与簿记是确定性的（避免与排空回收竞争）。
    const rt = try Runtime.init(std.heap.c_allocator, .{ .min_workers = 4, .max_workers = 4 });
    defer {
        rt.shutdown();
        rt.deinit();
    }
    for (&jobs) |*j| try testing.expect(rt.submit(.{ .run = SleepJob.run, .ctx = j }));
    rt.waitIdle();
    try testing.expectEqual(@as(usize, 4), rt.active.load(.acquire));

    // 造确定性空闲序：id1 最老、id0 次之、id3 再次、id2 pinned（不参与回收）
    rt.mutex.lockUncancelable(rt.io);
    rt.reg.entries[0].beginIdle(100);
    rt.reg.entries[1].beginIdle(50);
    rt.reg.entries[2].beginIdle(200);
    rt.reg.entries[2].class = .pinned;
    rt.reg.entries[3].beginIdle(150);
    // floor=1、不限步长：绕过 pinned 收最老三个（1/0/3）→ 在役降至 1
    const n = rt.markOldestIdleLocked(1, 4, 0, 0);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expect(rt.retire[1] and rt.retire[0] and rt.retire[3]);
    try testing.expect(!rt.retire[2]); // pinned 永不入候选
    // 再标：可选中仅剩 pinned → 0（pinned 不被回收）
    try testing.expectEqual(@as(usize, 0), rt.markOldestIdleLocked(1, 4, 0, 0));
    rt.mutex.unlock(rt.io);
}

test "runtime: AS3 调节器参数——收步长上限 + 空闲年龄过滤（markOldestIdleLocked）" {
    var done = std.atomic.Value(u32).init(0);
    var jobs: [4]SleepJob = undefined;
    for (&jobs) |*j| j.* = .{ .ms = 5, .done = &done };
    // min==max==4 ⇒ active==min，排空不触发 requestReclaim（Master 不并发裁决）。
    const rt = try Runtime.init(std.heap.c_allocator, .{ .min_workers = 4, .max_workers = 4 });
    defer {
        rt.shutdown();
        rt.deinit();
    }
    for (&jobs) |*j| try testing.expect(rt.submit(.{ .run = SleepJob.run, .ctx = j }));
    rt.waitIdle();

    rt.mutex.lockUncancelable(rt.io);
    rt.reg.entries[0].beginIdle(1000);
    rt.reg.entries[1].beginIdle(2000);
    rt.reg.entries[2].beginIdle(3000);
    rt.reg.entries[3].beginIdle(4000);
    // 收步长：max_mark=1、floor=0 → 只标最老 id0，其余原样
    try testing.expectEqual(@as(usize, 1), rt.markOldestIdleLocked(0, 1, 0, 0));
    try testing.expect(rt.retire[0] and !rt.retire[1] and !rt.retire[2] and !rt.retire[3]);
    // 空闲年龄过滤：now=3500 / min_age=2000 → id1(age1500)/id2(500)/id3(0) 均不足，
    // 且 id0 已 retire → 无合格者
    try testing.expectEqual(@as(usize, 0), rt.markOldestIdleLocked(0, 4, 2000, 3500));
    // 放宽到 min_age=1000：仅 id1(age1500) 合格
    try testing.expectEqual(@as(usize, 1), rt.markOldestIdleLocked(0, 4, 1000, 3500));
    try testing.expect(rt.retire[1]);
    rt.mutex.unlock(rt.io);
}

// ---- AS2 长流池化：worker 亲和 pinned 1:1（§6.3）----

const As2Ctx = struct {
    tid: std.Thread.Id = undefined,
    done: Io.Event = .unset,

    fn run(ctx: *anyopaque) void {
        const c: *As2Ctx = @ptrCast(@alignCast(ctx));
        c.tid = std.Thread.getCurrentId();
        Io.Event.set(&c.done, Io.Threaded.global_single_threaded.io());
    }
};

test "runtime: AS2 pinned 1:1——定向步骤同线程执行；全局任务不占 pinned worker" {
    const io_inst = Io.Threaded.global_single_threaded.io();
    const rt = try Runtime.init(std.heap.c_allocator, .{ .min_workers = 2, .max_workers = 4 });
    defer {
        rt.shutdown();
        rt.deinit();
    }
    const id = rt.acquirePinned() orelse return error.SkipZigTest;
    try testing.expect(rt.pinned[id]);
    try testing.expectEqual(tables.Class.pinned, rt.reg.entries[id].class);

    var p1 = As2Ctx{};
    var p2 = As2Ctx{};
    try testing.expect(rt.submitPinned(id, .{ .run = As2Ctx.run, .ctx = &p1 }));
    Io.Event.waitUncancelable(&p1.done, io_inst);
    try testing.expect(rt.submitPinned(id, .{ .run = As2Ctx.run, .ctx = &p2 }));
    Io.Event.waitUncancelable(&p2.done, io_inst);
    try testing.expectEqual(p1.tid, p2.tid); // 1:1 亲和：两步同线程

    // 全局任务不得落到 pinned worker（由另一 worker 处理）
    var g = As2Ctx{};
    try testing.expect(rt.submit(.{ .run = As2Ctx.run, .ctx = &g }));
    Io.Event.waitUncancelable(&g.done, io_inst);
    try testing.expect(g.tid != p1.tid);

    // 释放后回 elastic（可被全局队列/回收复用）
    rt.releasePinned(id);
    try testing.expect(!rt.pinned[id]);
    try testing.expectEqual(tables.Class.elastic, rt.reg.entries[id].class);
}

test "runtime: AS3 滞后死区——serving 在 target+keep 内不回收，越过才收（确定性）" {
    // 1) 纯裁决原语 reclaimBudget：不做簿记、不依赖线程/时钟
    try testing.expectEqual(@as(usize, 0), reclaimBudget(4, 2, 2, 0)); // 4 <= 2+2 → 死区
    try testing.expectEqual(@as(usize, 0), reclaimBudget(5, 2, 3, 0)); // 5 <= 5 → 死区边界
    try testing.expectEqual(@as(usize, 4), reclaimBudget(6, 2, 3, 0)); // 刚越死区：收全部盈余
    try testing.expectEqual(@as(usize, 1), reclaimBudget(6, 2, 3, 1)); // 刚越死区 + 步长封顶
    try testing.expectEqual(@as(usize, 2), reclaimBudget(4, 2, 0, 0)); // 无死区：收全部盈余
    try testing.expectEqual(@as(usize, 1), reclaimBudget(4, 2, 0, 1)); // 收步长封顶
    try testing.expectEqual(@as(usize, 3), reclaimBudget(10, 2, 0, 3)); // 步长封顶（盈余 8）
    try testing.expectEqual(@as(usize, 0), reclaimBudget(2, 2, 0, 0)); // 无盈余
    try testing.expectEqual(@as(usize, 0), reclaimBudget(1, 3, 0, 0)); // serving < target 不下溢

    // 2) 组合：把裁决预算交给 markOldestIdleLocked 在锁内标记（构造确定状态）。
    //    min==max==4 ⇒ 排空事件不触发 requestReclaim（active==min），Master 保持纯事件
    //    睡眠，不会并发调用 maybeReclaim——消除「直调裁决 vs 排空回收」的测试竞态。
    var done = std.atomic.Value(u32).init(0);
    var jobs: [4]SleepJob = undefined;
    for (&jobs) |*j| j.* = .{ .ms = 5, .done = &done };
    const rt = try Runtime.init(std.heap.c_allocator, .{ .min_workers = 4, .max_workers = 4 });
    defer {
        rt.shutdown();
        rt.deinit();
    }
    for (&jobs) |*j| try testing.expect(rt.submit(.{ .run = SleepJob.run, .ctx = j }));
    rt.waitIdle();
    try testing.expectEqual(@as(usize, 4), rt.active.load(.acquire));

    const Count = struct {
        fn retired(r: *Runtime) usize {
            var n: usize = 0;
            for (r.workers.items, 0..) |_, id| {
                if (r.retire[id]) n += 1;
            }
            return n;
        }
    };

    // 死区：serving=4, target=2, keep=2 → budget 0 → 不回收（断言前后均无 retire）
    rt.mutex.lockUncancelable(rt.io);
    const budget_keep = reclaimBudget(4, 2, 2, 0);
    const marked_keep = rt.markOldestIdleLocked(2, budget_keep, 0, 0);
    rt.mutex.unlock(rt.io);
    try testing.expectEqual(@as(usize, 0), budget_keep);
    try testing.expectEqual(@as(usize, 0), marked_keep);
    try testing.expectEqual(@as(usize, 0), Count.retired(rt));

    // 越过死区且 keep=0：serving=4, target=2 → budget 2 → 恰好收 2（最老空闲优先）
    rt.mutex.lockUncancelable(rt.io);
    const budget_pass = reclaimBudget(4, 2, 0, 0);
    const marked_pass = rt.markOldestIdleLocked(2, budget_pass, 0, 0);
    rt.mutex.unlock(rt.io);
    try testing.expectEqual(@as(usize, 2), budget_pass);
    try testing.expectEqual(@as(usize, 2), marked_pass);
    try testing.expectEqual(@as(usize, 2), Count.retired(rt));
}

test "runtime: AS3 空闲回收降容——大波撑满后无新事件也回落 min_workers（idle_timeout）" {
    var done = std.atomic.Value(u32).init(0);
    var jobs: [12]SleepJob = undefined;
    for (&jobs) |*j| j.* = .{ .ms = 25, .done = &done };
    const rt = try Runtime.init(std.heap.c_allocator, .{
        .min_workers = 1,
        .max_workers = 8,
        .idle_timeout_ns = 40 * std.time.ns_per_ms,
    });
    defer {
        rt.shutdown();
        rt.deinit();
    }

    // 波：12 路并发 → 扩容并保留峰值（排空回落 target=peak，不立即退）
    for (&jobs) |*j| try testing.expect(rt.submit(.{ .run = SleepJob.run, .ctx = j }));
    var grew = false;
    for (0..400) |_| {
        if (rt.active.load(.acquire) >= 6 and done.load(.acquire) == 12) {
            grew = true;
            break;
        }
        tSleepMs(10);
    }
    try testing.expect(grew);
    rt.waitIdle();

    // 无新事件：Master 空闲 tick（idle_timeout）触发降容，最终收敛回 min_workers=1
    try testing.expect(pollActive(rt, 1, 800, 10));
    try testing.expectEqual(@as(u32, 12), done.load(.acquire));
    try testing.expectEqual(@as(usize, 0), rt.spawn_failed_count.load(.acquire));
}

test "runtime: P3 任务节点池——串行 submit 复用节点，自由表有界" {
    const rt = try Runtime.init(std.heap.c_allocator, .{ .min_workers = 1, .max_workers = 2 });
    defer {
        rt.shutdown();
        rt.deinit();
    }
    var dummy: u8 = 0;
    const Body = struct {
        fn run(_: *anyopaque) void {}
    };
    // 串行提交 200 次：每次完工节点应回到自由表，下一次 submit 复用（而非再 malloc）。
    // 若 free_count 恒 >=1 则证明复用路径被走通（无池时 release 直接 destroy，恒为 0）。
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        try testing.expect(rt.submit(.{ .run = Body.run, .ctx = @ptrCast(&dummy) }));
        rt.waitIdle();
        try testing.expect(rt.free_count >= 1);
    }
    // 自由表容量恒有界：不随提交次数增长（避免无限驻留）。
    try testing.expect(rt.free_count <= node_pool_cap);
}
