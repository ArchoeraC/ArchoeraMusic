// ArchoeraMusic 平台能力原生桥接
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Windows 后端（P3，docs/platform-native-bridge.md §4.2）。
//!
//! P3a（本文件当前）：防休眠抑制（SetThreadExecutionState，专用常驻线程）+
//! 熄屏检测（PowerSettingRegisterNotification DEVICE_NOTIFY_CALLBACK）+
//! 窗口状态（子类化 Flutter 顶层 WndProc）。
//! P3b（待做）：WinRT SMTC（COM vtable 直调）—— 本机无法真机验收，独立推进。
//!
//! 本文件仅在 `builtin.os.tag == .windows` 时被 backend.zig 引用（惰性分析）。
//! Win32 声明全部手动（win_common.zig），不依赖 @cImport/Windows SDK 头。

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

// ── 媒体键兜底（WM_APPCOMMAND）────────────────────────────────────
// 现代 Windows 把媒体键（含蓝牙 AVRCP）经 SMTC 派发；但当 SMTC 非当前会话 /
// 仅前台时，系统退化为 WM_APPCOMMAND（GET_APPCOMMAND_LPARAM = HIWORD & 0x0FFF）。
// 二者通常互斥（SMTC 已消费则不再发 APPCOMMAND），故并列处理不产生双触发。
const APPCOMMAND_MEDIA_NEXTTRACK: u16 = 11;
const APPCOMMAND_MEDIA_PREVIOUSTRACK: u16 = 12;
const APPCOMMAND_MEDIA_STOP: u16 = 13;
const APPCOMMAND_MEDIA_PLAY_PAUSE: u16 = 14;
const APPCOMMAND_MEDIA_PLAY: u16 = 46;
const APPCOMMAND_MEDIA_PAUSE: u16 = 47;

fn dispatchAppCommand(lparam: win.LPARAM) bool {
    const raw: usize = @bitCast(lparam);
    const app: u16 = @intCast((raw >> 16) & 0x0FFF);
    const cmd: i32 = switch (app) {
        APPCOMMAND_MEDIA_NEXTTRACK => core.CMD_NEXT,
        APPCOMMAND_MEDIA_PREVIOUSTRACK => core.CMD_PREV,
        APPCOMMAND_MEDIA_STOP => core.CMD_STOP,
        APPCOMMAND_MEDIA_PLAY_PAUSE => core.CMD_TOGGLE,
        APPCOMMAND_MEDIA_PLAY => core.CMD_PLAY,
        APPCOMMAND_MEDIA_PAUSE => core.CMD_PAUSE,
        else => return false,
    };
    core.dispatch(.{ .type = core.EVENT_MEDIA_COMMAND, .u = .{ .command = cmd } });
    return true;
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
        win.WM_APPCOMMAND => {
            if (dispatchAppCommand(lparam)) return 1; // 已消费，不再下传
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
        core.CAP_MEDIA_SESSION | core.CAP_APP_INSTANCE | core.CAP_SYSTEM_ACCENT;
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
    if (g_instance_mutex) |h| {
        _ = win.CloseHandle(h);
        g_instance_mutex = null;
    }
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
        smtc.setTrack(m.title.slice(), m.artist.slice(), m.art_url.slice(), m.duration_ms, m.art_bytes.slice());
    } else {
        smtc.setTrack(null, null, null, -1, null);
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

// ── 单实例（Windows：命名互斥体）──────────────────────────────────
// 进程级命名互斥体（Local\ 会话命名空间 = 每登录会话一个实例，与 Linux
// XDG_RUNTIME_DIR / macOS 文件锁语义对齐）。CreateMutexW 不会因已存在而失败：
// 返回句柄 + ERROR_ALREADY_EXISTS 表示已有实例；此时关闭本地句柄返回 0。
// 句柄须持有至进程退出（关闭即释放单实例）。
var g_instance_mutex: win.HANDLE = null;

pub fn appInstanceAcquire() i32 {
    if (g_instance_mutex != null) return 1; // 幂等
    const name = std.unicode.utf8ToUtf16LeStringLiteral("Local\\ArchoeraMusic.SingleInstance");
    const h = win.CreateMutexW(null, 0, name);
    if (h == null) return core.ERR_BACKEND;
    if (win.GetLastError() == win.ERROR_ALREADY_EXISTS) {
        _ = win.CloseHandle(h);
        return 0; // 已有实例持有
    }
    g_instance_mutex = h;
    return 1;
}


// ── 系统提示：优先 C++/WinRT 原生 Toast，其次 PowerShell 调 WinRT，兜底 MessageBoxW ──
// 1) apl_win_toast（win_toast.cpp，Windows.UI.Notifications，原生横幅）；
//    未编译该文件时由本文件弱符号兜底返回 -1。
// 2) PowerShell -EncodedCommand 调 WinRT Toast（免 C++/WinRT 构建依赖）。
// 3) MessageBoxW（模态兜底）。

extern "c" fn apl_win_toast(title: ?[*:0]const u8, body: ?[*:0]const u8) c_int;

/// 未编译 win_toast.cpp 时的弱兜底（强符号存在时被覆盖）。
fn winToastFallback(title: ?[*:0]const u8, body: ?[*:0]const u8) callconv(.c) c_int {
    _ = title;
    _ = body;
    return -1;
}
comptime {
    @export(&winToastFallback, .{ .name = "apl_win_toast", .linkage = .weak });
}

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
    // 1) 原生 C++/WinRT Toast（win_toast.cpp）
    const tz = alloc.dupeZ(u8, title) catch return core.ERR_BACKEND;
    defer alloc.free(tz);
    const bz = alloc.dupeZ(u8, body) catch return core.ERR_BACKEND;
    defer alloc.free(bz);
    if (apl_win_toast(tz.ptr, bz.ptr) == 0) return core.OK;
    // 2) PowerShell 调 WinRT
    if (toastWinRT(title, body)) return core.OK;
    // 兜底：模态 MessageBox
    const t = std.unicode.utf8ToUtf16LeAllocZ(alloc, title) catch return core.ERR_BACKEND;
    defer alloc.free(t);
    const b = std.unicode.utf8ToUtf16LeAllocZ(alloc, body) catch return core.ERR_BACKEND;
    defer alloc.free(b);
    _ = user32.MessageBoxW(null, b.ptr, t.ptr, 0x40); // MB_ICONINFORMATION
    return core.OK;
}

// ── 系统主题色：HKCU\...\DWM\AccentColor（ABGR DWORD）→ DwmGetColorizationColor ──
// 不依赖 C++/WinRT：仅 advapi32 + dwmapi（系统自带）。
extern "advapi32" fn RegGetValueW(
    hkey: ?*anyopaque,
    subkey: [*:0]const u16,
    value: [*:0]const u16,
    flags: u32,
    ptype: ?*u32,
    pvdata: ?*anyopaque,
    pcbdata: ?*u32,
) callconv(.winapi) c_int;
extern "dwmapi" fn DwmGetColorizationColor(pcr: *u32, opaque_blend: *i32) callconv(.winapi) c_int;

// 预定义注册表句柄：64 位 Windows 上 HKEY_CURRENT_USER = 0xFFFFFFFF80000001
// （C 宏 (HKEY)(ULONG_PTR)((LONG)0x80000001) 的符号扩展）。此前写成 0x80000001，
// 在 64 位下是非法句柄 → RegGetValueW/RegOpenKeyExW 全失败 → 主题色恒读不到。
const HKEY_CURRENT_USER: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -0x7FFFFFFF))));
const RRF_RT_REG_DWORD: u32 = 0x00000010;

fn readDwmDword(value: [*:0]const u16) ?u32 {
    var v: u32 = 0;
    var sz: u32 = @sizeOf(u32);
    const key = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\DWM");
    if (RegGetValueW(HKEY_CURRENT_USER, key, value, RRF_RT_REG_DWORD, null, &v, &sz) != 0) return null;
    return v;
}

pub fn systemAccent() ?[3]u8 {
    // 1) DWM\AccentColor：DWORD 按 ABGR 存（0xAABBGGRR）→ R=低字节
    if (readDwmDword(std.unicode.utf8ToUtf16LeStringLiteral("AccentColor"))) |v| {
        return .{ @intCast(v & 0xFF), @intCast((v >> 8) & 0xFF), @intCast((v >> 16) & 0xFF) };
    }
    // 2) 回退：DWM 着色色（0xAARRGGBB）
    var c: u32 = 0;
    var blend: i32 = 0;
    if (DwmGetColorizationColor(&c, &blend) == 0 and c != 0) {
        return .{ @intCast((c >> 16) & 0xFF), @intCast((c >> 8) & 0xFF), @intCast(c & 0xFF) };
    }
    return null;
}

// ── 系统主题色变更：注册表 DWM 键 RegNotifyChangeKeyValue（后台线程）──
var g_accent_on = std.atomic.Value(bool).init(false);
var g_accent_thread: ?std.Thread = null;

extern "advapi32" fn RegOpenKeyExW(hkey: ?*anyopaque, subkey: [*:0]const u16, opt: u32, sam: u32, phk: *?*anyopaque) callconv(.winapi) c_int;
extern "advapi32" fn RegNotifyChangeKeyValue(hkey: ?*anyopaque, subtree: i32, filter: u32, event: ?*anyopaque, async: i32) callconv(.winapi) c_int;
extern "advapi32" fn RegCloseKey(hkey: ?*anyopaque) callconv(.winapi) c_int;
extern "kernel32" fn CreateEventW(attr: ?*anyopaque, manual: i32, init: i32, name: ?[*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn WaitForSingleObject(h: ?*anyopaque, ms: u32) callconv(.winapi) u32;
extern "kernel32" fn CloseHandle(h: ?*anyopaque) callconv(.winapi) c_int;

const KEY_NOTIFY: u32 = 0x0010;
const REG_NOTIFY_CHANGE_LAST_SET: u32 = 0x00000004;
const WAIT_OBJECT_0: u32 = 0;

fn accentThread() void {
    const key = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\DWM");
    var hkey: ?*anyopaque = null;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, key, 0, KEY_NOTIFY, &hkey) != 0) return;
    defer _ = RegCloseKey(hkey);
    const ev = CreateEventW(null, 0, 0, null);
    if (ev == null) return;
    defer _ = CloseHandle(ev);
    while (g_accent_on.load(.acquire)) {
        if (RegNotifyChangeKeyValue(hkey, 0, REG_NOTIFY_CHANGE_LAST_SET, ev, 1) != 0) break;
        // 500ms 轮询退出标志（RegNotifyChangeKeyValue 阻塞不可取消）
        if (WaitForSingleObject(ev, 500) == WAIT_OBJECT_0 and g_accent_on.load(.acquire)) {
            core.dispatch(.{ .type = core.EVENT_SYSTEM_ACCENT, .u = .{ .active = 1 } });
        }
    }
}

pub fn systemAccentSetEvents(on: i32) i32 {
    const want = on != 0;
    const was = g_accent_on.swap(want, .acquire);
    if (want and !was) {
        g_accent_thread = std.Thread.spawn(.{}, accentThread, .{}) catch {
            g_accent_on.store(false, .release);
            return core.ERR_BACKEND;
        };
    }
    return core.OK;
}
