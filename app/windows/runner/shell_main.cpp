// ArchoeraMusic UI
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

// 控制台子系统伴生程序 `archoerashell.exe`。
//
// 链接与主程序相同的 Rust staticlib（app/core/shell），但作为控制台子系统可执行
// 文件：cmd / PowerShell 会**等待其退出**，且它**独占**控制台输入——交互式 REPL
// 因此可用。主程序（GUI 子系统）的 `archoera_music archoerashell …` 子命令会与
// 调用方 shell 争抢同一控制台输入，仅适合一次性命令（见 docs/mcp.md）。

#include <windows.h>

#include <cstddef>
#include <cwchar>
#include <string>
#include <vector>

// 原生 `archoerashell` 入口（Rust staticlib，见 app/core/shell）。
extern "C" int archoera_shell_main(int argc, const char* const* argv);

namespace {

// UTF-16 → UTF-8（与 app/windows/runner/utils.cpp 同口径，但不依赖 Flutter）。
std::string Utf8FromWide(const wchar_t* wide) {
  if (wide == nullptr) {
    return std::string();
  }
  int len = static_cast<int>(std::wcslen(wide));
  int target = ::WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide, len,
                                     nullptr, 0, nullptr, nullptr);
  if (target <= 0) {
    return std::string();
  }
  std::string utf8(static_cast<std::size_t>(target), '\0');
  ::WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide, len, utf8.data(),
                        target, nullptr, nullptr);
  return utf8;
}

}  // namespace

int main() {
  int argc = 0;
  wchar_t** wide = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (wide == nullptr || argc <= 0) {
    return 2;
  }

  // 首个元素固定为 `archoerashell`：Rust 入口按该子命令定位其后的用户参数
  // （伴生程序本身就是该命令，无需用户再输入一次）。
  std::vector<std::string> storage;
  storage.reserve(static_cast<std::size_t>(argc));
  storage.emplace_back("archoerashell");
  for (int i = 1; i < argc; i++) {
    storage.push_back(Utf8FromWide(wide[i]));
  }
  ::LocalFree(wide);

  std::vector<const char*> argv;
  argv.reserve(storage.size() + 1);
  for (const std::string& arg : storage) {
    argv.push_back(arg.c_str());
  }
  argv.push_back(nullptr);
  return archoera_shell_main(static_cast<int>(storage.size()), argv.data());
}
