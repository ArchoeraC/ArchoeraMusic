// ArchoeraMusic 平台能力原生桥接
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! 共享 Win32 C 导入（backend_windows 与 win_smtc 共用，保证类型一致）。
//!
//! 仅依赖 windows.h / powrprof.h（Zig 自带 any-windows-any 头，跨
//! windows-gnu/msvc 均可解析）。WinRT 相关（HSTRING / Ro* / interop IID）
//! 一律由 win_smtc.zig 手动声明 + 运行时 GetProcAddress，避免 @cImport 依赖
//! Windows SDK 的 roapi.h/hstring.h/systemmediatransportcontrolsinterop.h
//! （windows-msvc 目标下未必在 Zig 默认头搜索路径中 → C import failed）。
pub const c = @cImport({
    @cInclude("windows.h");
    @cInclude("powrprof.h");
});
