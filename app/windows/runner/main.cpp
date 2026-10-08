#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <cstddef>
#include <cwchar>
#include <string>
#include <utility>
#include <vector>

#include "flutter_window.h"
#include "utils.h"

// SetCurrentProcessExplicitAppUserModelID（shell32；shobjidl_core.h 声明）。
extern "C" HRESULT __stdcall SetCurrentProcessExplicitAppUserModelID(PCWSTR app_id);

// 原生 `archoerashell` 入口（Rust staticlib，见 app/core/shell）。命令行调用完全
// 不初始化 Flutter 引擎：wWinMain 在此直接分派，控制台/UTF-8/ANSI 由 Rust 侧
// console 模块按需引导（标准流可能已被重定向，不可无条件接管）。
extern "C" int archoera_shell_main(int argc, const char* const* argv);

namespace {

// 命令行是否带 `archoerashell` 子命令（与 Rust 入口一致：扫描全部 argv）。
bool HasShellSubcommand() {
  int argc = 0;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (argv == nullptr) {
    return false;
  }
  bool found = false;
  for (int i = 1; i < argc && !found; i++) {
    found = std::wcscmp(argv[i], L"archoerashell") == 0;
  }
  ::LocalFree(argv);
  return found;
}

// 把完整 argv（含 argv[0]）转成 UTF-8 并调用原生 CLI，返回其退出码。
int RunNativeShell() {
  int argc = 0;
  wchar_t** wide = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (wide == nullptr || argc <= 0) {
    return 2;
  }
  std::vector<std::string> storage;
  storage.reserve(static_cast<std::size_t>(argc));
  for (int i = 0; i < argc; i++) {
    storage.push_back(Utf8FromUtf16(wide[i]));
  }
  ::LocalFree(wide);

  std::vector<const char*> argv;
  argv.reserve(storage.size() + 1);
  for (const std::string& arg : storage) {
    argv.push_back(arg.c_str());
  }
  argv.push_back(nullptr);
  return archoera_shell_main(argc, argv.data());
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // CLI 模式（archoerashell）：直接进原生 Rust 入口，不加载 Flutter/Dart。
  if (HasShellSubcommand()) {
    return RunNativeShell();
  }

  // 显式 AppUserModelID：Win11 媒体浮出/任务栏分组/媒体键（含蓝牙 AVRCP）
  // 路由更稳。须在创建任何窗口前设置。
  ::SetCurrentProcessExplicitAppUserModelID(L"Archoera.ArchoeraMusic");

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"archoera_music", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
