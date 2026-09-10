// ArchoeraMusic 平台能力原生桥接
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! 共享 Win32 声明（backend_windows 与 win_smtc 共用，保证类型一致）。
//!
//! **不依赖 `@cImport`**：windows-msvc 目标下 Zig 的 translate-c 对 Windows
//! SDK 头（windows.h/powrprof.h）翻译不稳定（CI 实测 exit 1），故与项目其余
//! Windows 代码（backend_windows 的 MessageBoxW 等）一致，改为手动声明所需的
//! 类型/常量/`extern "lib" fn`。WinRT（HSTRING/Ro*/interop IID）亦全手动 +
//! 运行时 GetProcAddress（见 win_smtc.zig）。
pub const c = struct {
    // ── 基础类型 ──────────────────────────────────────────────────
    pub const HANDLE = ?*anyopaque;
    pub const HMODULE = ?*anyopaque;
    pub const HWND = ?*anyopaque;
    pub const HPOWERNOTIFY = ?*anyopaque;
    pub const DWORD = u32;
    pub const ULONG = u32;
    pub const UINT = c_uint;
    pub const WPARAM = usize;
    pub const LPARAM = isize;
    pub const LRESULT = isize;

    pub const GUID = extern struct {
        Data1: u32,
        Data2: u16,
        Data3: u16,
        Data4: [8]u8,
    };

    pub const WNDPROC = ?*const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;

    // ── 常量 ──────────────────────────────────────────────────────
    pub const ES_CONTINUOUS: DWORD = 0x80000000;
    pub const ES_SYSTEM_REQUIRED: DWORD = 0x00000001;

    pub const WM_SIZE: UINT = 0x0005;
    pub const WM_ACTIVATE: UINT = 0x0006;
    pub const WM_CLOSE: UINT = 0x0010;
    pub const SIZE_MINIMIZED: WPARAM = 1;
    pub const GWLP_WNDPROC: c_int = -4;

    // ── kernel32 ──────────────────────────────────────────────────
    pub extern "kernel32" fn LoadLibraryA(lpLibFileName: [*:0]const u8) callconv(.winapi) HMODULE;
    pub extern "kernel32" fn GetProcAddress(hModule: HMODULE, lpProcName: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    pub extern "kernel32" fn CreateThread(
        lpThreadAttributes: ?*anyopaque,
        dwStackSize: usize,
        lpStartAddress: ?*const fn (?*anyopaque) callconv(.winapi) DWORD,
        lpParameter: ?*anyopaque,
        dwCreationFlags: DWORD,
        lpThreadId: ?*DWORD,
    ) callconv(.winapi) HANDLE;
    pub extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) i32;
    pub extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD) callconv(.winapi) DWORD;
    pub extern "kernel32" fn Sleep(dwMilliseconds: DWORD) callconv(.winapi) void;
    pub extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
    pub extern "kernel32" fn SetThreadExecutionState(esFlags: DWORD) callconv(.winapi) DWORD;
    pub extern "kernel32" fn OutputDebugStringA(lpOutputString: [*:0]const u8) callconv(.winapi) void;

    // ── user32 ────────────────────────────────────────────────────
    pub extern "user32" fn FindWindowW(lpClassName: ?[*:0]const u16, lpWindowName: ?[*:0]const u16) callconv(.winapi) HWND;
    pub extern "user32" fn GetWindowThreadProcessId(hWnd: HWND, lpdwProcessId: ?*DWORD) callconv(.winapi) DWORD;
    pub extern "user32" fn SetWindowLongPtrW(hWnd: HWND, nIndex: c_int, dwNewLong: isize) callconv(.winapi) isize;
    pub extern "user32" fn CallWindowProcW(lpPrevWndFunc: WNDPROC, hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;

    // ── powrprof ──────────────────────────────────────────────────
    pub extern "powrprof" fn PowerSettingRegisterNotification(
        SettingGuid: *const GUID,
        Flags: DWORD,
        Recipient: ?*anyopaque,
        RegistrationHandle: *HPOWERNOTIFY,
    ) callconv(.winapi) DWORD;
    pub extern "powrprof" fn PowerSettingUnregisterNotification(RegistrationHandle: HPOWERNOTIFY) callconv(.winapi) DWORD;
};
