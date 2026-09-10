//! Windows 后端（P3，docs/platform-native-bridge.md §4.2）。
//!
//! P3a（本文件当前）：防休眠抑制（SetThreadExecutionState，专用常驻线程）+
//! 熄屏检测（PowerSettingRegisterNotification DEVICE_NOTIFY_CALLBACK）+
//! 窗口状态（子类化 Flutter 顶层 WndProc）。
//! P3b（待做）：WinRT SMTC（COM vtable 直调）—— 本机无法真机验收，独立推进。
//!
//! 本文件仅在 `builtin.os.tag == .windows` 时被 backend.zig 引用（惰性分析）；
//! 其余目标不解析 @cImport(windows.h)。

const std = @import("std");
const core = @import("../core.zig");
const smtc = @import("win_smtc.zig");
const win = @import("win_common.zig").c;

const alloc = std.heap.c_allocator;

// mingw 头未定义（PowerSettingRegisterNotification 的 device-notify 模式）
const DEVICE_NOTIFY_CALLBACK: win.DWORD = 2;

// GUID_CONSOLE_DISPLAY_STATE {6fe69556-704a-47a0-8f24-c28d936fda47}
const GUID_CONSOLE_DISPLAY_STATE = win.GUID{
    .Data1 = 0x6fe69556,
    .Data2 = 0x704a,
    .Data3 = 0x47a0,
    .Data4 = .{ 0x8f, 0x24, 0xc2, 0x8d, 0x93, 0x6f, 0xda, 0x47 },
};

var g_lock = std.atomic.Value(bool).init(false);
fn lock() void {
    while (g_lock.swap(true, .acquire)) std.atomic.spinLoopHint();
}
fn unlock() void {
    g_lock.store(false, .release);
}

// ── 休眠抑制（ES_CONTINUOUS 按线程生效 → 专用常驻线程）──────────────

var g_inhibit_want = std.atomic.Value(bool).init(false);
var g_inhibit_run = std.atomic.Value(bool).init(false);
var g_inhibit_handle: win.HANDLE = null;

fn inhibitThread() void {
    var applied = false;
    while (g_inhibit_run.load(.acquire)) {
        const want = g_inhibit_want.load(.acquire);
        if (want != applied) {
            if (want) {
                _ = win.SetThreadExecutionState(win.ES_CONTINUOUS | win.ES_SYSTEM_REQUIRED);
            } else {
                _ = win.SetThreadExecutionState(win.ES_CONTINUOUS);
            }
            applied = want;
        }
        win.Sleep(200);
    }
    if (applied) _ = win.SetThreadExecutionState(win.ES_CONTINUOUS);
}

fn ensureInhibitThread() bool {
    if (g_inhibit_handle != null) return true;
    g_inhibit_run.store(true, .release);
    const h = win.CreateThread(null, 0, inhibitEntry, null, 0, null);
    if (h == null) {
        g_inhibit_run.store(false, .release);
        return false;
    }
    g_inhibit_handle = h;
    return true;
}

fn inhibitEntry(_: ?*anyopaque) callconv(.winapi) win.DWORD {
    inhibitThread();
    return 0;
}

// ── 熄屏检测（PowerSettingRegisterNotification + 回调）────────────

var g_screen_events = std.atomic.Value(bool).init(false);
var g_power_notify: win.HPOWERNOTIFY = null;

fn powerCallback(context: ?*anyopaque, ntype: win.ULONG, setting: ?*anyopaque) callconv(.winapi) win.ULONG {
    _ = context;
    _ = ntype;
    if (!g_screen_events.load(.acquire)) return 0;
    const raw = setting orelse return 0;
    const s: *align(1) PowerBroadcastSetting = @ptrCast(raw);
    if (s.data_len < 1) return 0;
    const on = s.data[0] != 0; // 0=关屏 1=开屏
    core.dispatch(.{
        .type = core.EVENT_SCREEN_STATE,
        .u = .{ .active = @intFromBool(!on) },
    });
    return 0;
}

const PowerBroadcastSetting = extern struct {
    power_setting: win.GUID,
    data_len: win.DWORD,
    data: [1]u8,
};

// 字段顺序对齐 Windows：DEVICE_NOTIFY_SUBSCRIBE_PARAMETERS { Callback; Context; }
const DeviceNotifySubscribeParams = extern struct {
    callback: *const fn (?*anyopaque, win.ULONG, ?*anyopaque) callconv(.winapi) win.ULONG,
    context: ?*anyopaque,
};

var g_subscribe = DeviceNotifySubscribeParams{
    .callback = powerCallback,
    .context = null,
};

fn registerScreen() i32 {
    if (g_power_notify != null) return core.OK;
    const rc = win.PowerSettingRegisterNotification(
        &GUID_CONSOLE_DISPLAY_STATE,
        DEVICE_NOTIFY_CALLBACK,
        &g_subscribe,
        &g_power_notify,
    );
    return if (rc == 0) core.OK else core.ERR_BACKEND;
}

fn unregisterScreen() void {
    if (g_power_notify) |h| {
        _ = win.PowerSettingUnregisterNotification(h);
        g_power_notify = null;
    }
}

// ── 窗口状态（子类化 Flutter 顶层 WndProc）─────────────────────────

var g_orig_wndproc: win.WNDPROC = null;
var g_hwnd: win.HWND = null;
var g_minimized = std.atomic.Value(bool).init(false);
var g_focused = std.atomic.Value(bool).init(true);
var g_window_events = std.atomic.Value(bool).init(false);

fn emitWindow() void {
    if (!g_window_events.load(.acquire)) return;
    core.dispatch(.{
        .type = core.EVENT_WINDOW_STATE,
        .u = .{ .window = .{
            .minimized = @intFromBool(g_minimized.load(.acquire)),
            .focused = @intFromBool(g_focused.load(.acquire)),
        } },
    });
}

fn wndProc(hwnd: win.HWND, msg: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) callconv(.winapi) win.LRESULT {
    switch (msg) {
        win.WM_SIZE => {
            g_minimized.store(wparam == win.SIZE_MINIMIZED, .release);
            emitWindow();
        },
        win.WM_ACTIVATE => {
            const low: usize = @intCast(wparam & 0xffff);
            g_focused.store(low != 0, .release); // 0 = WA_INACTIVE
            emitWindow();
        },
        win.WM_CLOSE => {
            g_minimized.store(true, .release);
            emitWindow();
        },
        else => {},
    }
    return win.CallWindowProcW(g_orig_wndproc, hwnd, msg, wparam, lparam);
}

const FindCtx = struct { pid: win.DWORD, hwnd: win.HWND = null };

// Flutter Windows 顶层窗口类名（win32_window.cpp）
const FLUTTER_CLASS = std.unicode.utf8ToUtf16LeStringLiteral("FLUTTER_RUNNER_WIN32_WINDOW");

fn findFlutterWindow() ?win.HWND {
    const hwnd = win.FindWindowW(@ptrCast(FLUTTER_CLASS), null);
    if (hwnd == null) return null;
    var pid: win.DWORD = 0;
    _ = win.GetWindowThreadProcessId(hwnd, &pid);
    if (pid != win.GetCurrentProcessId()) return null;
    return hwnd;
}

fn subclassWindow() i32 {
    if (g_hwnd != null) return core.OK;
    const hwnd = findFlutterWindow() orelse return core.ERR_BACKEND;
    const proc_addr: isize = @bitCast(@intFromPtr(&wndProc));
    const orig = win.SetWindowLongPtrW(hwnd, win.GWLP_WNDPROC, proc_addr);
    if (orig == 0) return core.ERR_BACKEND;
    g_orig_wndproc = @ptrFromInt(@as(usize, @bitCast(orig)));
    g_hwnd = hwnd;
    return core.OK;
}

fn unsubclassWindow() void {
    if (g_hwnd) |hwnd| {
        if (g_orig_wndproc != null) {
            const orig_addr: isize = @bitCast(@intFromPtr(g_orig_wndproc));
            _ = win.SetWindowLongPtrW(hwnd, win.GWLP_WNDPROC, orig_addr);
        }
    }
    g_hwnd = null;
    g_orig_wndproc = null;
}

// ── 后端接口（backend.zig 契约）──────────────────────────────────

pub fn caps() u32 {
    return core.CAP_POWER_INHIBIT | core.CAP_POWER_SCREEN_STATE | core.CAP_WINDOW_STATE |
        core.CAP_MEDIA_SESSION | core.CAP_APP_INSTANCE;
}

pub fn init() i32 {
    setAppUserModelId();
    return core.OK;
}

/// 设置显式 AppUserModelID（Win11 媒体浮出/任务栏分组更稳；失败忽略）。
fn setAppUserModelId() void {
    const h = win.LoadLibraryA("shell32.dll") orelse return;
    const p = win.GetProcAddress(h, "SetCurrentProcessExplicitAppUserModelID") orelse return;
    const f: *const fn ([*:0]const u16) callconv(.winapi) i32 = @ptrCast(@alignCast(p));
    _ = f(std.unicode.utf8ToUtf16LeStringLiteral("Archoera.ArchoeraMusic"));
}

pub fn shutdown() i32 {
    g_inhibit_want.store(false, .release);
    g_inhibit_run.store(false, .release);
    if (g_inhibit_handle) |h| {
        _ = win.WaitForSingleObject(h, 2_000);
        _ = win.CloseHandle(h);
        g_inhibit_handle = null;
    }
    unregisterScreen();
    unsubclassWindow();
    smtc.deinit();
    g_screen_events.store(false, .release);
    g_window_events.store(false, .release);
    return core.OK;
}

pub fn powerSetSleepInhibit(on: i32) i32 {
    if (!ensureInhibitThread()) return core.ERR_BACKEND;
    g_inhibit_want.store(on != 0, .release);
    return core.OK;
}

pub fn powerSetScreenEvents(on: i32) i32 {
    if (on != 0) {
        const rc = registerScreen();
        if (rc != core.OK) return rc;
        g_screen_events.store(true, .release);
    } else {
        g_screen_events.store(false, .release);
    }
    return core.OK;
}

pub fn windowSetEvents(on: i32) i32 {
    if (on != 0) {
        const rc = subclassWindow();
        if (rc != core.OK) return rc;
        g_window_events.store(true, .release);
        emitWindow(); // 立即给初值
    } else {
        g_window_events.store(false, .release);
    }
    return core.OK;
}

pub fn mediaSetTrack(meta: ?*const core.TrackMeta) i32 {
    if (smtc.init(&findFlutterWindow) != core.OK) return core.ERR_BACKEND;
    if (meta) |m| {
        smtc.setTrack(m.title.slice(), m.artist.slice(), m.art_url.slice(), m.duration_ms);
    } else {
        smtc.setTrack(null, null, null, -1);
    }
    return core.OK;
}

pub fn mediaSetPlayback(state: i32, position_ms: i64, speed: f64, volume: f64, loop: i32, shuffle: i32) i32 {
    _ = .{ speed, volume, loop, shuffle };
    if (smtc.init(&findFlutterWindow) != core.OK) return core.ERR_BACKEND;
    smtc.setPlayback(state, position_ms);
    return core.OK;
}

pub fn mediaSetWindow(win_: i64) i32 {
    // 窗口句柄由 Zig 侧 findFlutterWindow 自动发现（Dart 无需传）；
    // 保留 ABI 槽位，忽略入参。
    _ = win_;
    return core.OK;
}

// ── 单实例（Windows：命名互斥体待接）────────────────────────────────
// TODO: CreateMutexW("Global\\ArchoeraMusic") + ERROR_ALREADY_EXISTS → 0。
// 当前返回 1（不阻断启动）；Dart 侧另有单实例守卫兜底。
pub fn appInstanceAcquire() i32 {
    return 1;
}


// ── 系统提示：优先 WinRT Toast（Windows.UI.Notifications），兜底 MessageBoxW ──
// WinRT Toast 直接经 Windows Runtime 通知 API 弹出（Win10+ 原生横幅，非模态）。
// 以 PowerShell -EncodedCommand 调用（免 C++/WinRT 构建依赖；PowerShell 5.1 内置）。

extern "c" fn system(command: [*:0]const u8) c_int;

fn psQuote(buf: *std.ArrayList(u8), s: []const u8) void {
    buf.append(alloc, '\'') catch {};
    for (s) |ch| {
        if (ch == '\'') {
            buf.appendSlice(alloc, "''") catch {};
        } else {
            buf.append(alloc, ch) catch {};
        }
    }
    buf.append(alloc, '\'') catch {};
}

fn toastWinRT(title: []const u8, body: []const u8) bool {
    var ps = std.ArrayList(u8).empty;
    defer ps.deinit(alloc);
    const pre = "$ErrorActionPreference='Stop';" ++
        "[Windows.UI.Notifications.ToastNotificationManager,Windows.UI.Notifications,ContentType=WindowsRuntime]|Out-Null;" ++
        "$t=[Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent(" ++
        "[Windows.UI.Notifications.ToastTemplateType]::ToastText02);" ++
        "$x=$t.GetElementsByTagName('text');$x.Item(0).AppendChild($t.CreateTextNode(";
    const mid = "))|Out-Null;$x.Item(1).AppendChild($t.CreateTextNode(";
    const post = "))|Out-Null;" ++
        "$n=[Windows.UI.Notifications.ToastNotification]::new($t);" ++
        "[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('ArchoeraMusic').Show($n);";
    ps.appendSlice(alloc, pre) catch return false;
    psQuote(&ps, title);
    ps.appendSlice(alloc, mid) catch return false;
    psQuote(&ps, body);
    ps.appendSlice(alloc, post) catch return false;

    const wstr = std.unicode.utf8ToUtf16LeAlloc(alloc, ps.items) catch return false;
    defer alloc.free(wstr);
    const bytes = std.mem.sliceAsBytes(wstr);
    const enc = std.base64.standard.Encoder;
    const out = alloc.alloc(u8, enc.calcSize(bytes.len)) catch return false;
    defer alloc.free(out);
    const b64 = enc.encode(out, bytes);
    const cmd = std.fmt.allocPrintSentinel(alloc,
        "powershell -NoProfile -NonInteractive -EncodedCommand {s}", .{b64}, 0) catch
        return false;
    defer alloc.free(cmd);
    return system(cmd) == 0;
}

const user32 = struct {
    extern "user32" fn MessageBoxW(hwnd: ?*anyopaque, text: [*:0]const u16, caption: [*:0]const u16, flags: u32) callconv(.winapi) c_int;
};

pub fn notify(title: []const u8, body: []const u8) i32 {
    if (toastWinRT(title, body)) return core.OK;
    // 兜底：模态 MessageBox
    const t = std.unicode.utf8ToUtf16LeAllocZ(alloc, title) catch return core.ERR_BACKEND;
    defer alloc.free(t);
    const b = std.unicode.utf8ToUtf16LeAllocZ(alloc, body) catch return core.ERR_BACKEND;
    defer alloc.free(b);
    _ = user32.MessageBoxW(null, b.ptr, t.ptr, 0x40); // MB_ICONINFORMATION
    return core.OK;
}
