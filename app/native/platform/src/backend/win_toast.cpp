// ArchoeraMusic — Windows 原生 C++/WinRT Toast 通知
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// 供 Zig 平台桥接（backend_windows.notify）调用：apl_win_toast(title, body)。
// 直接使用 Windows Runtime `Windows.UI.Notifications` 弹原生 Toast（Win10+）。
//
// 构建：仅 Windows 目标编译；需 C++/WinRT 头（vcpkg `cppwinrt` 或
// `Microsoft.Windows.CppWinRT`），并以 `-Dcppwinrt-include=<path>`（或环境变量
// CPPWINRT_INCLUDE）提供包含路径；未提供时跳过本文件，Zig 侧走弱符号兜底
// （PowerShell 调 WinRT / MessageBox）。

#include <windows.h>

#include <string_view>

#include <winrt/base.h>
#include <winrt/Windows.Data.Xml.Dom.h>
#include <winrt/Windows.UI.Notifications.h>

extern "C" int apl_win_toast(const char* title, const char* body) {
    try {
        using namespace winrt::Windows::UI::Notifications;
        using namespace winrt::Windows::Data::Xml::Dom;

        // 幂等初始化（多线程套间；重复调用返回 RPC_E_CHANGED_MODE，忽略）
        try {
            winrt::init_apartment(winrt::apartment_type::multi_threaded);
        } catch (...) {
        }

        const std::string_view t = title ? title : "";
        const std::string_view b = body ? body : "";

        auto tmpl = ToastNotificationManager::GetTemplateContent(
            ToastTemplateType::ToastText02);
        auto texts = tmpl.GetElementsByTagName(L"text");
        texts.Item(0).AppendChild(tmpl.CreateTextNode(winrt::to_hstring(t)));
        texts.Item(1).AppendChild(tmpl.CreateTextNode(winrt::to_hstring(b)));

        ToastNotificationManager::CreateToastNotifier(L"ArchoeraMusic")
            .Show(ToastNotification(tmpl));
        return 0;
    } catch (...) {
        return -1;
    }
}
