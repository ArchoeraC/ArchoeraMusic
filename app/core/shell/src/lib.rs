// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! ArchoeraMusic 内嵌原生命令行客户端（`archoerashell`）。
//!
//! 以 `staticlib` 形式链入各平台 runner 的主可执行文件：runner 在初始化
//! Flutter/Dart **之前**检测到 `archoerashell` 子命令即调用 [`archoera_shell_main`]，
//! 从而在命令行调用时完全不加载 Flutter 引擎。

mod cli;
#[cfg(windows)]
mod console;
mod http;
mod l10n;
mod prefs;
mod render;
mod style;
mod term;
mod width;

use std::ffi::CStr;
use std::os::raw::{c_char, c_int};

/// 收集 `argv`（跳过 `argv[0]`）。
unsafe fn collect_args(argc: c_int, argv: *const *const c_char) -> Vec<String> {
    let mut out = Vec::new();
    if argv.is_null() {
        return out;
    }
    for i in 0..argc {
        let p = *argv.add(i as usize);
        if p.is_null() {
            break;
        }
        out.push(CStr::from_ptr(p).to_string_lossy().into_owned());
    }
    out
}

/// 主可执行文件被以 `archoerashell …` 调用时进入此入口。
///
/// 返回进程退出码（0 成功 / 1 运行期错误 / 2 用法错误）。捕获 panic，避免
/// unwinding 跨越 FFI 边界。
///
/// # Safety
/// `argv` 须为合法的以 NUL 结尾的 C 字符串数组，长度 `argc`。
#[no_mangle]
pub unsafe extern "C" fn archoera_shell_main(
    argc: c_int,
    argv: *const *const c_char,
) -> c_int {
    let args = collect_args(argc, argv);
    let sub: Vec<String> = match args.iter().position(|a| a == "archoerashell") {
        Some(i) => args[i + 1..].to_vec(),
        None => return 2,
    };
    // Windows：GUI 子系统进程被终端调用时接管/补齐标准流与 UTF-8/ANSI。
    #[cfg(windows)]
    let console_state = console::ensure();
    let code =
        std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| cli::run(sub))).unwrap_or(70);
    // 复位被改写的控制台代码页，保持调用方终端状态。
    #[cfg(windows)]
    console::restore(console_state);
    code
}

/// 供集成测试/嵌入调用的纯 Rust 入口。
pub fn run(args: Vec<String>) -> i32 {
    cli::run(args)
}
