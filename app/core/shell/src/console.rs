// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Windows 控制台引导（仅在 `cfg(windows)` 下编译）。
//!
//! Windows runner 是 GUI 子系统可执行文件：被终端以 `archoera_music archoerashell …`
//! 调用时不会自动继承调用方的标准流。本模块在进入 CLI 前接管父控制台（必要时新建），
//! 补齐缺失的标准句柄、切到 UTF-8 输出/输入并打开 ANSI 转义，使原生 CLI 与 Unix 端
//! 观感一致。
//!
//! **不无条件覆盖既有句柄**：标准流可能已被重定向到管道/文件（如
//! `echo status | archoera_music archoerashell`），此时必须保留调用方句柄。

use std::os::raw::{c_int, c_void};

const STD_INPUT_HANDLE: u32 = -10i32 as u32;
const STD_OUTPUT_HANDLE: u32 = -11i32 as u32;
const STD_ERROR_HANDLE: u32 = -12i32 as u32;
const ATTACH_PARENT_PROCESS: u32 = 0xFFFF_FFFF;

const GENERIC_READ: u32 = 0x8000_0000;
const GENERIC_WRITE: u32 = 0x4000_0000;
const FILE_SHARE_READ: u32 = 0x1;
const FILE_SHARE_WRITE: u32 = 0x2;
const OPEN_EXISTING: u32 = 3;
const INVALID_HANDLE_VALUE: isize = -1;

const ENABLE_VIRTUAL_TERMINAL_PROCESSING: u32 = 0x0004;
const CP_UTF8: u32 = 65001;

#[repr(C)]
struct Coord {
    x: i16,
    y: i16,
}

#[repr(C)]
struct SmallRect {
    left: i16,
    top: i16,
    right: i16,
    bottom: i16,
}

#[repr(C)]
struct ConsoleScreenBufferInfo {
    size: Coord,
    cursor: Coord,
    attributes: u16,
    window: SmallRect,
    maximum_window_size: Coord,
}

#[link(name = "kernel32")]
extern "system" {
    fn AttachConsole(process_id: u32) -> c_int;
    fn AllocConsole() -> c_int;
    fn GetStdHandle(which: u32) -> *mut c_void;
    fn SetStdHandle(which: u32, handle: *mut c_void) -> c_int;
    fn CreateFileW(
        name: *const u16,
        access: u32,
        share: u32,
        security: *mut c_void,
        disposition: u32,
        flags: u32,
        template: *mut c_void,
    ) -> *mut c_void;
    fn GetConsoleMode(handle: *mut c_void, mode: *mut u32) -> c_int;
    fn SetConsoleMode(handle: *mut c_void, mode: u32) -> c_int;
    fn GetConsoleScreenBufferInfo(handle: *mut c_void, info: *mut ConsoleScreenBufferInfo)
        -> c_int;
    fn GetConsoleOutputCP() -> u32;
    fn SetConsoleOutputCP(cp: u32) -> c_int;
    fn GetConsoleCP() -> u32;
    fn SetConsoleCP(cp: u32) -> c_int;
}

fn is_valid(handle: *mut c_void) -> bool {
    !handle.is_null() && handle as isize != INVALID_HANDLE_VALUE
}

/// 以读写方式打开控制台设备（`CONOUT$` / `CONIN$`）；失败返回空句柄。
fn open_device(name: &str) -> *mut c_void {
    let mut wide: Vec<u16> = name.encode_utf16().collect();
    wide.push(0);
    unsafe {
        CreateFileW(
            wide.as_ptr(),
            GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            std::ptr::null_mut(),
            OPEN_EXISTING,
            0,
            std::ptr::null_mut(),
        )
    }
}

unsafe fn set_handle_if_opened(which: u32, handle: *mut c_void) {
    if is_valid(handle) {
        SetStdHandle(which, handle);
    }
}

/// 控制台引导结果：记录被改写的代码页，供 [`restore`] 复位（未改写则为 0）。
pub struct ConsoleState {
    output_cp: u32,
    input_cp: u32,
}

/// 让 CLI 的标准流可用，并打开 UTF-8 / ANSI。
///
/// 句柄已被重定向时保持原样；仅有缺失的句柄才去接管/新建控制台。
pub fn ensure() -> ConsoleState {
    unsafe {
        let has_out = is_valid(GetStdHandle(STD_OUTPUT_HANDLE));
        let has_err = is_valid(GetStdHandle(STD_ERROR_HANDLE));
        let has_in = is_valid(GetStdHandle(STD_INPUT_HANDLE));

        if !(has_out && has_err && has_in) {
            // 已附着时两个调用都会失败（无副作用）；无控制台时新建一个。
            if AttachConsole(ATTACH_PARENT_PROCESS) == 0 {
                AllocConsole();
            }
            if !has_out {
                set_handle_if_opened(STD_OUTPUT_HANDLE, open_device("CONOUT$"));
            }
            if !has_err {
                set_handle_if_opened(STD_ERROR_HANDLE, open_device("CONOUT$"));
            }
            if !has_in {
                set_handle_if_opened(STD_INPUT_HANDLE, open_device("CONIN$"));
            }
        }

        let out = GetStdHandle(STD_OUTPUT_HANDLE);
        let mut mode: u32 = 0;
        if GetConsoleMode(out, &mut mode) == 0 {
            // 输出不是控制台（重定向到管道/文件）：不做代码页/VT 改动。
            return ConsoleState {
                output_cp: 0,
                input_cp: 0,
            };
        }

        let mut state = ConsoleState {
            output_cp: 0,
            input_cp: 0,
        };
        let ocp = GetConsoleOutputCP();
        if ocp != 0 && ocp != CP_UTF8 {
            SetConsoleOutputCP(CP_UTF8);
            state.output_cp = ocp;
        }
        let icp = GetConsoleCP();
        if icp != 0 && icp != CP_UTF8 {
            SetConsoleCP(CP_UTF8);
            state.input_cp = icp;
        }
        if mode & ENABLE_VIRTUAL_TERMINAL_PROCESSING == 0 {
            SetConsoleMode(out, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
        }
        state
    }
}

/// 复位 [`ensure`] 改写的控制台代码页（保持调用方终端状态不变）。
pub fn restore(state: ConsoleState) {
    unsafe {
        if state.output_cp != 0 {
            SetConsoleOutputCP(state.output_cp);
        }
        if state.input_cp != 0 {
            SetConsoleCP(state.input_cp);
        }
    }
}

/// 控制台窗口列数；无控制台（重定向/未附着）返回 `None`。
pub fn columns() -> Option<usize> {
    unsafe {
        let out = GetStdHandle(STD_OUTPUT_HANDLE);
        let mut info: ConsoleScreenBufferInfo = std::mem::zeroed();
        if GetConsoleScreenBufferInfo(out, &mut info) != 0 {
            // i16 窗口坐标先在 i32 中相减，避免溢出/负值强转 usize。
            let cols = info.window.right as i32 - info.window.left as i32 + 1;
            if cols > 0 {
                return Some(cols as usize);
            }
        }
        None
    }
}
