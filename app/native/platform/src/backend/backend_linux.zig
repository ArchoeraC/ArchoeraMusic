//! Linux 后端：自研 D-Bus 承载 SystemPower（P1）与 MPRIS（P2，待落地）。
//!
//! 能力位图恒置位 POWER_INHIBIT | POWER_SCREEN_STATE（bridge §3.3）；运行期
//! 缺服务（极简 WM 无 ScreenSaver）在调用时返回 ERR_BACKEND，由 Dart 显式
//! toast——与「平台无此能力」的 Noop 静默降级相区分。
//!
//! 线程模型（bridge §5）：首次 ensureConn 成功时拉起泵线程（空闲认领读取权
//! 分发信号）；Dart 调用经 Connection.call 同步认领读取权等回复。断连：
//! pump 失败 → 分发 BACKEND_STATE(lost) → 连接置空，下次调用重连。

const std = @import("std");
const core = @import("../core.zig");
const message = @import("../dbus/message.zig");
const transport = @import("../dbus/transport.zig");
const mpris = @import("../dbus/mpris.zig");
const linux_window = @import("linux_window.zig");

/// 会话类型（X11 / Wayland / 未知）——决定窗口探测模式；GTK/GDK 对两者
/// 均可用（GDK 已抽象），故统一走 GTK 模式，检测用于能力门控与日志。
const Session = enum { x11, wayland, unknown };
fn detectSession() Session {
    if (std.c.getenv("WAYLAND_DISPLAY")) |_| return .wayland;
    if (std.c.getenv("DISPLAY")) |_| return .x11;
    return .unknown;
}

// libc 已链（build.zig），c_allocator 线程安全可用
const alloc = std.heap.c_allocator;

const SS_FREEDESKTOP = "org.freedesktop.ScreenSaver";
const SS_FREEDESKTOP_PATH = "/org/freedesktop/ScreenSaver";
const SS_GNOME = "org.gnome.ScreenSaver";
const SS_GNOME_PATH = "/org/gnome/ScreenSaver";

// ── 全局状态（自旋锁保护；临界区极短）─────────────────────────────

var g_lock = std.atomic.Value(bool).init(false);
var g_conn: ?transport.Connection = null;
var g_running = std.atomic.Value(bool).init(false);
var g_thread: ?std.Thread = null;

var g_service: []const u8 = SS_FREEDESKTOP;
var g_path: []const u8 = SS_FREEDESKTOP_PATH;
var g_cookie: u32 = 0;
var g_inhibit_on: bool = false;
// 原子量：信号处理器（泵线程）据此过滤，且不得取 g_lock——否则与
// ensureConn 持锁期间的同步 D-Bus 调用互锁。
var g_screen_events = std.atomic.Value(bool).init(false);

fn lock() void {
    while (g_lock.swap(true, .acquire)) std.atomic.spinLoopHint();
}

fn unlock() void {
    g_lock.store(false, .release);
}

// ── 处理器：信号分发到 Dart ───────────────────────────────────────

var handler_ctx: u8 = 0;

fn onSignal(ctx: *anyopaque, conn: *transport.Connection, h: *const message.Header, body: []const u8) void {
    _ = ctx;
    _ = conn;
    if (!g_screen_events.load(.acquire)) return;
    const member = h.member orelse return;
    if (std.mem.eql(u8, member, "ActiveChanged")) {
        const vals = message.readBody(alloc, "b", body) catch return;
        defer alloc.free(vals);
        if (vals.len != 1) return;
        core.dispatch(.{
            .type = core.EVENT_SCREEN_STATE,
            .u = .{ .active = @intFromBool(vals[0].boolean) },
        });
        return;
    }
    // systemd-logind 会话锁屏/解锁（LockedHint 的简单信号形态，无参数）：
    // 作为 ScreenSaver.ActiveChanged 之外的**第二来源**，降低解锁复位丢失概率。
    if (std.mem.eql(u8, member, "Lock")) {
        core.dispatch(.{ .type = core.EVENT_SCREEN_STATE, .u = .{ .active = 1 } });
    } else if (std.mem.eql(u8, member, "Unlock")) {
        core.dispatch(.{ .type = core.EVENT_SCREEN_STATE, .u = .{ .active = 0 } });
    }
}

fn onMethodCall(ctx: *anyopaque, conn: *transport.Connection, h: *const message.Header, body: []const u8) void {
    _ = ctx;
    // P2：MPRIS 方法调用（Play/Pause/Next/Seek/属性读写）
    mpris.handleMethodCall(conn, h, body);
}

const handler = transport.Handler{
    .ctx = @ptrCast(&handler_ctx),
    .onSignalFn = onSignal,
    .onMethodCallFn = onMethodCall,
};

// ── 连接管理 ──────────────────────────────────────────────────────

/// 懒连接：未连则连（认证 + Hello + 探测 ScreenSaver + AddMatch）；
/// 成功即拉起泵线程（幂等）。null = 会话总线不可用。
fn ensureConn() ?*transport.Connection {
    lock();
    defer unlock();
    if (g_conn != null) return &g_conn.?;

    var conn = transport.Connection.connectSession(alloc) catch return null;
    conn.handler = &handler;
    pickScreensaver(&conn);
    addScreenMatch(&conn);
    // 先落全局（稳定地址），再让 mpris 持有其指针——否则 mpris 存的是局部
    // `conn` 的栈地址，ensureConn 返回后悬垂 → Metadata/PlaybackStatus 推送失效。
    g_conn = conn;
    _ = mpris.init(&g_conn.?); // P2：MPRIS 服务名（失败不影响 Power）

    if (!g_running.swap(true, .acquire)) {
        g_thread = std.Thread.spawn(.{}, pumpLoop, .{}) catch {
            g_running.store(false, .release);
            return &g_conn.?;
        };
    }
    return &g_conn.?;
}

/// 探测 ScreenSaver 服务归属（freedesktop 优先，GNOME 兜底）；
/// 均不存在保持 freedesktop 默认（Inhibit 调用时按 ERR_BACKEND 透出）。
fn pickScreensaver(conn: *transport.Connection) void {
    const candidates = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = SS_FREEDESKTOP, .path = SS_FREEDESKTOP_PATH },
        .{ .name = SS_GNOME, .path = SS_GNOME_PATH },
    };
    for (candidates) |c| {
        const args = [_]message.Value{.{ .string = c.name }};
        const r = conn.call(
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "GetNameOwner",
            "s",
            &args,
            3_000,
        ) catch continue;
        defer r.deinit();
        if (r.ok and r.values.len == 1) {
            g_service = c.name;
            g_path = c.path;
            return;
        }
    }
}

/// 订阅两套 ScreenSaver 的 ActiveChanged + systemd-logind 的 Lock/Unlock
/// （match 规则不要求服务存在，缺失时无信号、无副作用）。
fn addScreenMatch(conn: *transport.Connection) void {
    for ([_][]const u8{ SS_FREEDESKTOP, SS_GNOME }) |svc| {
        var rule_buf: [160]u8 = undefined;
        const rule = std.fmt.bufPrint(
            &rule_buf,
            "type='signal',interface='{s}',member='ActiveChanged'",
            .{svc},
        ) catch continue;
        const args = [_]message.Value{.{ .string = rule }};
        _ = conn.call(
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "AddMatch",
            "s",
            &args,
            3_000,
        ) catch continue;
    }
    // logind 会话锁屏/解锁（第二来源；非 systemd 环境无此信号，忽略）
    for ([_][]const u8{ "Lock", "Unlock" }) |m| {
        var rule_buf: [160]u8 = undefined;
        const rule = std.fmt.bufPrint(
            &rule_buf,
            "type='signal',interface='org.freedesktop.login1.Session',member='{s}'",
            .{m},
        ) catch continue;
        const args = [_]message.Value{.{ .string = rule }};
        _ = conn.call(
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "AddMatch",
            "s",
            &args,
            3_000,
        ) catch continue;
    }
}

/// 泵线程：空闲认领读取权分发信号；失败 → BACKEND_STATE(lost) → 置空重连。
fn pumpLoop() void {
    while (g_running.load(.acquire)) {
        lock();
        const has = g_conn != null;
        unlock();
        _ = &has;
        if (has) {
            var failed = false;
            lock();
            if (g_conn) |*c| {
                if (!c.pump()) {
                    c.deinit();
                    g_conn = null;
                    mpris.detach();
                    failed = true;
                }
            }
            unlock();
            if (failed) {
                core.dispatch(.{ .type = core.EVENT_BACKEND_STATE, .u = .{ .backend_lost = 1 } });
            }
            transport.sleepMs(30);
        } else {
            // 断连重连：仍需要信号（熄屏订阅）或抑制时，按退避重建连接并重订阅
            // （否则锁屏/解锁事件永久丢失 → Dart 侧卡在低帧率）。
            if (g_screen_events.load(.acquire) or g_inhibit_on) {
                _ = ensureConn();
            }
            transport.sleepMs(300);
        }
    }
}

// ── 后端接口（backend.zig 契约）──────────────────────────────────

pub fn caps() u32 {
    var c: u32 = core.CAP_POWER_INHIBIT | core.CAP_POWER_SCREEN_STATE |
        core.CAP_MEDIA_SESSION | core.CAP_MEDIA_SEEK | core.CAP_MEDIA_ARTWORK |
        core.CAP_APP_INSTANCE;
    // 有显示会话且 GTK 可用 → 窗口状态（X11/Wayland 统一 GTK 模式）
    if (detectSession() != .unknown and linux_window.available()) {
        c |= core.CAP_WINDOW_STATE;
    }
    return c;
}

pub fn init() i32 {
    return core.OK; // 连接懒建立；失败在调用时报 ERR_BACKEND
}

pub fn shutdown() i32 {
    g_running.store(false, .release);
    if (g_thread) |th| {
        th.join();
        g_thread = null;
    }
    lock();
    defer unlock();
    _ = linux_window.setEvents(false);
    if (g_conn) |*c| c.deinit();
    g_conn = null;
    mpris.detach();
    g_cookie = 0;
    g_inhibit_on = false;
    g_screen_events.store(false, .release);
    return core.OK;
}

pub fn powerSetSleepInhibit(on: i32) i32 {
    lock();
    const had = g_inhibit_on;
    const cookie = g_cookie;
    const svc = g_service;
    const path = g_path;
    unlock();

    if (on != 0) {
        if (had) return core.OK;
        const conn = ensureConn() orelse return core.ERR_BACKEND;
        const args = [_]message.Value{
            .{ .string = "ArchoeraMusic" },
            .{ .string = "playback" },
        };
        const r = conn.call(svc, path, svc, "Inhibit", "ss", &args, 5_000) catch
            return core.ERR_BACKEND;
        defer r.deinit();
        if (!r.ok or r.values.len != 1 or r.values[0].u32_ == 0) return core.ERR_BACKEND;
        lock();
        g_cookie = r.values[0].u32_;
        g_inhibit_on = true;
        unlock();
        return core.OK;
    } else {
        if (!had or cookie == 0) return core.OK;
        const conn = ensureConn() orelse return core.ERR_BACKEND;
        const args = [_]message.Value{.{ .u32_ = cookie }};
        const r = conn.call(svc, path, svc, "UnInhibit", "u", &args, 5_000) catch
            return core.ERR_BACKEND;
        defer r.deinit();
        if (!r.ok) return core.ERR_BACKEND;
        lock();
        g_cookie = 0;
        g_inhibit_on = false;
        unlock();
        return core.OK;
    }
}

pub fn powerSetScreenEvents(on: i32) i32 {
    _ = ensureConn() orelse return core.ERR_BACKEND;
    g_screen_events.store(on != 0, .release);
    return core.OK;
}

pub fn windowSetEvents(on: i32) i32 {
    return linux_window.setEvents(on != 0);
}

pub fn mediaSetTrack(meta: ?*const core.TrackMeta) i32 {
    mpris.setTrack(meta);
    return core.OK;
}

pub fn mediaSetPlayback(state: i32, position_ms: i64, speed: f64, volume: f64, loop: i32, shuffle: i32) i32 {
    mpris.setPlayback(state, position_ms, speed, volume, loop, shuffle);
    return core.OK;
}

pub fn mediaSetWindow(win: i64) i32 {
    _ = win;
    return core.OK;
}


// ── 单实例（文件锁）────────────────────────────────────────────────

var g_instance_fd: std.posix.fd_t = -1;

/// 1=首实例（持有锁至进程退出）；0=已有实例；<0=错误。
pub fn appInstanceAcquire() i32 {
    if (g_instance_fd >= 0) return 1; // 幂等
    const dir = if (std.c.getenv("XDG_RUNTIME_DIR")) |p| std.mem.span(p) else "/tmp";
    var buf: [512]u8 = undefined;
    const path = std.fmt.bufPrintZ(&buf, "{s}/archoera_music.lock", .{dir}) catch
        return core.ERR_BACKEND;
    const flags = std.posix.O{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true };
    const fd = std.posix.openatZ(std.posix.AT.FDCWD, path, flags, 0o600) catch
        return core.ERR_BACKEND;
    const rc = std.c.flock(fd, 2 | 4); // LOCK_EX | LOCK_NB
    if (rc != 0) {
        _ = std.c.close(fd);
        return 0; // 已被其它实例持有
    }
    g_instance_fd = fd;
    return 1;
}


// ── 系统提示（kdialog/zenity/xmessage/yad/notify-send 依次尝试）──────
// 用 libc system() 启动（桥接上下文的 std.Io 不支持 process spawn）。
extern "c" fn system(command: [*:0]const u8) c_int;
fn shellQuote(buf: *std.ArrayList(u8), s: []const u8) void {
    buf.append(alloc, '\'') catch {};
    for (s) |ch| {
        if (ch == '\'') {
            buf.appendSlice(alloc, "'\\''") catch {};
        } else {
            buf.append(alloc, ch) catch {};
        }
    }
    buf.append(alloc, '\'') catch {};
}

pub fn notify(title: []const u8, body: []const u8) i32 {
    const attempts = [_][]const []const u8{
        &.{ "kdialog", "--title", title, "--msgbox", body },
        &.{ "zenity", "--info", "--title", title, "--text", body },
        &.{ "xmessage", "-center", "-title", title, body },
        &.{ "yad", "--title", title, "--text", body, "--button=OK:0" },
        &.{ "notify-send", title, body },
    };
    std.debug.print("[platform] notify title={s} body={s}\n", .{ title, body });
    for (attempts) |argv| {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(alloc);
        for (argv, 0..) |a, i| {
            if (i > 0) buf.append(alloc, ' ') catch {};
            shellQuote(&buf, a);
        }
        const cmd = buf.toOwnedSliceSentinel(alloc, 0) catch return core.ERR_BACKEND;
        defer alloc.free(cmd);
        const rc = system(cmd);
        const code: u32 = @intCast((rc >> 8) & 0xff); // WEXITSTATUS
        if (rc != -1 and code != 127) { // 127 = 命令不存在 → 试下一个
            std.debug.print("[platform] notify via {s} rc={d}\n", .{ argv[0], rc });
            return core.OK;
        }
        std.debug.print("[platform] notify {s} skip (rc={d})\n", .{ argv[0], rc });
    }
    std.debug.print("[platform] notify: all attempts failed\n", .{});
    return core.ERR_BACKEND;
}
