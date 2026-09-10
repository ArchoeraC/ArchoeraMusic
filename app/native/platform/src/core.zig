//! 平台能力桥接 core：错误码 / 事件结构 / 回调注册与分发。
//!
//! 线程模型（docs/platform-native-bridge.md §5）：后端可在任意 OS 线程调
//! [dispatch]；回调指针注册走互斥锁（注册与注销线程安全），分发时取快照后
//! 在锁外调用，避免回调重入死锁。Dart 侧回调必须用 NativeCallable.listener。

const std = @import("std");

// ── 错误码（对齐 include/archoera_platform.h）─────────────────────
pub const OK: i32 = 0;
pub const ERR_UNSUPPORTED: i32 = -1;
pub const ERR_BACKEND: i32 = -2;
pub const ERR_STATE: i32 = -3;

// ── 能力位图 ──────────────────────────────────────────────────────
pub const CAP_POWER_INHIBIT: u32 = 1 << 0;
pub const CAP_POWER_SCREEN_STATE: u32 = 1 << 1;
pub const CAP_MEDIA_SESSION: u32 = 1 << 2;
pub const CAP_MEDIA_SEEK: u32 = 1 << 3;
pub const CAP_MEDIA_ARTWORK: u32 = 1 << 4;
pub const CAP_WINDOW_STATE: u32 = 1 << 5;
pub const CAP_APP_INSTANCE: u32 = 1 << 6;

// ── 事件类型 / 命令 ───────────────────────────────────────────────
pub const EVENT_MEDIA_COMMAND: i32 = 1;
pub const EVENT_MEDIA_SEEK: i32 = 2;
pub const EVENT_SCREEN_STATE: i32 = 3;
pub const EVENT_WINDOW_STATE: i32 = 4;
pub const EVENT_BACKEND_STATE: i32 = 5;

pub const CMD_PLAY: i32 = 0;
pub const CMD_PAUSE: i32 = 1;
pub const CMD_TOGGLE: i32 = 2;
pub const CMD_STOP: i32 = 3;
pub const CMD_NEXT: i32 = 4;
pub const CMD_PREV: i32 = 5;

/// D-Bus/WinRT/ObjC 侧字符串视图（borrowed，仅调用期间有效）。
pub const AplString = extern struct {
    data: ?[*]const u8,
    len: usize,

    pub fn slice(self: AplString) ?[]const u8 {
        const p = self.data orelse return null;
        if (self.len == 0) return "";
        return p[0..self.len];
    }
};

pub const TrackMeta = extern struct {
    title: AplString,
    artist: AplString,
    album: AplString,
    duration_ms: i64,
    art_url: AplString,
};

pub const Event = extern struct {
    type: i32,
    _pad: i32 = 0,
    u: extern union {
        command: i32,
        seek: extern struct { rel_ms: i64, abs_ms: i64 },
        active: i32,
        window: extern struct { minimized: i32, focused: i32 },
        backend_lost: i32,
    },
};

pub const Callback = *const fn (event: *const Event, user_data: ?*anyopaque) callconv(.c) void;

// ── 全局状态 ──────────────────────────────────────────────────────
// Zig 0.16 无 std.Thread.Mutex（已并入 std.Io 异步面）；本模块临界区仅
// 「读回调快照 / 写两指针」，原子自旋锁足够且零依赖（P1 IO 线程同样适用）。
var g_lock = std.atomic.Value(bool).init(false);
var g_initialized = std.atomic.Value(bool).init(false);
var g_callback = std.atomic.Value(usize).init(0);
var g_user_data = std.atomic.Value(usize).init(0);

fn lock() void {
    while (g_lock.swap(true, .acquire)) std.atomic.spinLoopHint();
}

fn unlock() void {
    g_lock.store(false, .release);
}

pub fn isInitialized() bool {
    return g_initialized.load(.acquire);
}

pub fn setInitialized(v: bool) void {
    g_initialized.store(v, .release);
}

/// 注册/注销（NULL）事件回调；幂等。
pub fn setEventCallback(cb: ?Callback, user_data: ?*anyopaque) void {
    lock();
    g_callback.store(@intFromPtr(cb orelse null), .release);
    g_user_data.store(@intFromPtr(user_data orelse null), .release);
    unlock();
}

/// 把事件投递给 Dart 回调（任意线程可调；回调期间不持锁）。
/// 无回调 / 未注册时静默丢弃（Noop 语义）。
/// 事件环：dispatch 入队后仅用回调「唤醒」Dart，Dart 经 pollEvent 取走副本。
/// （不能把栈上 Event 指针交给异步 NativeCallable.listener——Dart 稍后读取时
///  栈已被覆盖 → 事件随机丢失。）
var g_ring: [64]Event = undefined;
var g_ring_len: usize = 0;
var g_ring_pos: usize = 0;

pub fn dispatch(event: Event) void {
    lock();
    if (g_ring_len == g_ring.len) { // 满：丢最旧
        g_ring_pos = (g_ring_pos + 1) % g_ring.len;
        g_ring_len -= 1;
    }
    g_ring[(g_ring_pos + g_ring_len) % g_ring.len] = event;
    g_ring_len += 1;
    const cb_raw = g_callback.load(.acquire);
    const user = g_user_data.load(.acquire);
    unlock();
    if (cb_raw == 0) return;
    const cb: Callback = @ptrFromInt(cb_raw);
    cb(&g_ring[0], @ptrFromInt(user)); // 指针仅为唤醒占位，Dart 忽略其内容
}

/// 取出一条事件（副本）。true=有事件，false=空。线程安全。
pub fn pollEvent(out: *Event) bool {
    lock();
    if (g_ring_len == 0) {
        unlock();
        return false;
    }
    out.* = g_ring[g_ring_pos];
    g_ring_pos = (g_ring_pos + 1) % g_ring.len;
    g_ring_len -= 1;
    unlock();
    return true;
}

// ── 测试 ──────────────────────────────────────────────────────────
const TestSink = struct {
    events: [8]Event = undefined,
    count: usize = 0,

    fn cb(event: *const Event, user: ?*anyopaque) callconv(.c) void {
        const sink: *TestSink = @ptrCast(@alignCast(user.?));
        if (sink.count < sink.events.len) {
            sink.events[sink.count] = event.*;
            sink.count += 1;
        }
    }
};

test "dispatch delivers registered callback and noop without" {
    var sink = TestSink{};

    // 未注册：不崩、不投递
    dispatch(.{ .type = EVENT_SCREEN_STATE, .u = .{ .active = 1 } });
    try std.testing.expectEqual(@as(usize, 0), sink.count);

    setEventCallback(TestSink.cb, &sink);
    dispatch(.{ .type = EVENT_SCREEN_STATE, .u = .{ .active = 1 } });
    dispatch(.{ .type = EVENT_MEDIA_COMMAND, .u = .{ .command = CMD_NEXT } });
    setEventCallback(null, null);
    dispatch(.{ .type = EVENT_WINDOW_STATE, .u = .{ .window = .{ .minimized = 1, .focused = 0 } } });

    try std.testing.expectEqual(@as(usize, 2), sink.count);
    try std.testing.expectEqual(EVENT_SCREEN_STATE, sink.events[0].type);
    try std.testing.expectEqual(@as(i32, 1), sink.events[0].u.active);
    try std.testing.expectEqual(EVENT_MEDIA_COMMAND, sink.events[1].type);
    try std.testing.expectEqual(CMD_NEXT, sink.events[1].u.command);
}

test "event layout matches C ABI" {
    // union 最大成员 seek（2×i64）决定对齐 8、体积 16；事件总体积 = 8 + 16
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(@TypeOf(@as(Event, undefined).u)));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(Event));
}

test "AplString slice" {
    const s = AplString{ .data = "abc", .len = 3 };
    try std.testing.expectEqualStrings("abc", s.slice().?);
    const missing = AplString{ .data = null, .len = 0 };
    try std.testing.expect(missing.slice() == null);
    const empty = AplString{ .data = "x", .len = 0 };
    try std.testing.expectEqual(@as(usize, 0), empty.slice().?.len);
}
