// ArchoeraMusic 平台能力原生桥接
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! 共享 WinRT/Win32 C 导入（backend_windows 与 win_smtc 共用，保证类型一致）。
pub const c = @cImport({
    @cInclude("windows.h");
    @cInclude("powrprof.h");
    @cInclude("roapi.h");
    @cInclude("hstring.h");
    @cInclude("systemmediatransportcontrolsinterop.h");
});
