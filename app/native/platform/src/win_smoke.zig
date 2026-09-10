//! Windows 后端真机冒烟（仅 x86_64-windows-gnu；WSL 下经 interop 运行）。
//!
//! 验证：能力位图、休眠抑制、熄屏注册、窗口子类化、SMTC（创建真实窗口 →
//! mediaSetTrack/mediaSetPlayback → 读回 PlaybackStatus/IsEnabled 校验 vtable）。
//! 用法：`zig build win-smoke -Dtarget=x86_64-windows-gnu` 后
//! `./zig-out/bin/win_smoke.exe`。

const std = @import("std");
const core = @import("core.zig");
const backend = @import("backend/backend_windows.zig");
const smtc = @import("backend/win_smtc.zig");
const win = @import("backend/win_common.zig").c;

var g_events: u32 = 0;

fn onEvent(e: *const core.Event, user: ?*anyopaque) callconv(.c) void {
    _ = user;
    g_events += 1;
    std.debug.print("[event] type={d} active={d} focused={d}\n", .{
        e.type, e.u.active, e.u.window.focused,
    });
}

fn wndProc(hwnd: win.HWND, msg: win.UINT, wp: win.WPARAM, lp: win.LPARAM) callconv(.winapi) win.LRESULT {
    return win.DefWindowProcW(hwnd, msg, wp, lp);
}

/// 建一个类名与 Flutter 一致的顶层窗口，供窗口状态与 SMTC 使用。
fn createWindow() ?win.HWND {
    const cls = std.unicode.utf8ToUtf16LeStringLiteral("FLUTTER_RUNNER_WIN32_WINDOW");
    var wc: win.WNDCLASSW = std.mem.zeroes(win.WNDCLASSW);
    wc.lpfnWndProc = wndProc;
    wc.hInstance = win.GetModuleHandleW(null);
    wc.lpszClassName = cls;
    _ = win.RegisterClassW(&wc);
    const title = std.unicode.utf8ToUtf16LeStringLiteral("smoke");
    return win.CreateWindowExW(
        0,
        cls,
        title,
        win.WS_OVERLAPPEDWINDOW,
        100,
        100,
        400,
        300,
        null,
        null,
        wc.hInstance,
        null,
    );
}

fn s(data: []const u8) core.AplString {
    return .{ .data = data.ptr, .len = data.len };
}

pub fn main() void {
    std.debug.print("caps=0x{x}\n", .{backend.caps()});
    _ = backend.init();
    core.setEventCallback(onEvent, null);

    const inh_on = backend.powerSetSleepInhibit(1);
    const inh_off = backend.powerSetSleepInhibit(0);
    std.debug.print("inhibit on={d} off={d}\n", .{ inh_on, inh_off });

    const scr = backend.powerSetScreenEvents(1);
    _ = backend.powerSetScreenEvents(0);
    std.debug.print("screen_events={d}\n", .{scr});

    const hwnd = createWindow();

    const win_on = backend.windowSetEvents(1);
    std.debug.print("window_events={d}\n", .{win_on});

    const t = "Smoke Title";
    const a = "Smoke Artist";
    const al = "Smoke Album";
    var meta = core.TrackMeta{
        .title = s(t),
        .artist = s(a),
        .album = s(al),
        .duration_ms = 1000,
        .art_url = .{ .data = null, .len = 0 },
    };
    std.debug.print("set_track={d}\n", .{backend.mediaSetTrack(&meta)});
    std.debug.print("set_playback={d}\n", .{backend.mediaSetPlayback(1, 0, 1.0, 1.0, 0, 0)});

    // 读回校验 vtable 槽位（Playing=3，IsEnabled=1）
    std.debug.print("readback status={d} is_enabled={d}\n", .{
        smtc.debugGetPlaybackStatus(),
        smtc.debugGetIsEnabled(),
    });

    _ = backend.windowSetEvents(0);
    _ = backend.shutdown();
    if (hwnd) |h| _ = win.DestroyWindow(h);
    std.debug.print("events_seen={d}\n", .{g_events});
    std.debug.print("WIN_SMOKE_DONE\n", .{});
}
