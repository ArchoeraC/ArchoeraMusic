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

namespace {

// 按 Windows 命令行规则给单个参数加引号/转义（CreateProcessW 需要可回读的串）。
std::wstring QuoteArg(const std::wstring& arg) {
  if (arg.empty()) {
    return L"\"\"";
  }
  if (arg.find_first_of(L" \t\n\v\"") == std::wstring::npos) {
    return arg;
  }
  std::wstring quoted = L"\"";
  for (std::size_t i = 0;; ++i) {
    std::size_t backslashes = 0;
    while (i < arg.size() && arg[i] == L'\\') {
      ++i;
      ++backslashes;
    }
    if (i == arg.size()) {
      quoted.append(backslashes * 2, L'\\');
      quoted.push_back(L'"');
      break;
    }
    if (arg[i] == L'"') {
      quoted.append(backslashes * 2 + 1, L'\\');
      quoted.push_back(L'"');
    } else {
      quoted.append(backslashes, L'\\');
      quoted.push_back(arg[i]);
    }
  }
  return quoted;
}

// 把 `archoera_music archoerashell …` 转到同目录的控制台伴生程序
// `archoerashell.exe`，保留标准输入/输出（含管道/重定向）并返回其退出码。
//
// **不**在主 GUI 进程里静态链接 Rust CLI：Rust std 会带入
// `IsDebuggerPresent`/`RtlCaptureContext`/`dbghelp`/`WS2_32` 等导入，未签名
// GUI 程序带这些特征极易被 AV 的 ML 判为 loader（本函数只依赖 CreateProcessW）。
// 返回 -1 表示命令行里没有 `archoerashell` 子命令。
int RunCompanionShell() {
  int argc = 0;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (argv == nullptr || argc <= 0) {
    return -1;  // 解析失败按「无子命令」处理，继续正常启动 GUI
  }

  int shell_index = -1;
  for (int i = 1; i < argc; i++) {
    if (std::wcscmp(argv[i], L"archoerashell") == 0) {
      shell_index = i;
      break;
    }
  }
  if (shell_index < 0) {
    ::LocalFree(argv);
    return -1;
  }

  wchar_t self[MAX_PATH];
  const DWORD self_len = ::GetModuleFileNameW(nullptr, self, MAX_PATH);
  if (self_len == 0 || self_len >= MAX_PATH) {
    ::LocalFree(argv);
    return 2;
  }
  std::wstring exe(self, self_len);
  const std::size_t slash = exe.find_last_of(L"\\/");
  exe = (slash == std::wstring::npos ? std::wstring() : exe.substr(0, slash + 1)) +
        L"archoerashell.exe";
  if (::GetFileAttributesW(exe.c_str()) == INVALID_FILE_ATTRIBUTES) {
    ::LocalFree(argv);
    return 127;  // 伴生程序缺失（打包不完整）
  }

  std::wstring cmd = QuoteArg(exe);
  for (int i = shell_index + 1; i < argc; i++) {
    cmd.push_back(L' ');
    cmd += QuoteArg(argv[i]);
  }
  ::LocalFree(argv);

  // 从终端启动时附着父控制台，让控制台子进程复用同一窗口与标准流；
  // 从资源管理器启动（无控制台）时子进程会自建控制台，不影响使用。
  const bool attached = ::AttachConsole(ATTACH_PARENT_PROCESS) != FALSE;
  STARTUPINFOW si{};
  si.cb = sizeof(si);
  if (attached) {
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = ::GetStdHandle(STD_INPUT_HANDLE);
    si.hStdOutput = ::GetStdHandle(STD_OUTPUT_HANDLE);
    si.hStdError = ::GetStdHandle(STD_ERROR_HANDLE);
  }

  std::vector<wchar_t> mutable_cmd(cmd.begin(), cmd.end());
  mutable_cmd.push_back(L'\0');
  PROCESS_INFORMATION pi{};
  if (!::CreateProcessW(exe.c_str(), mutable_cmd.data(), nullptr, nullptr,
                        attached ? TRUE : FALSE, 0, nullptr, nullptr, &si, &pi)) {
    return 1;
  }
  ::WaitForSingleObject(pi.hProcess, INFINITE);
  DWORD exit_code = 1;
  ::GetExitCodeProcess(pi.hProcess, &exit_code);
  ::CloseHandle(pi.hThread);
  ::CloseHandle(pi.hProcess);
  return static_cast<int>(exit_code);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // CLI 模式（archoerashell）：转到控制台伴生程序，不加载 Flutter/Dart。
  // GUI 进程不再静态链接 Rust CLI（见 RunCompanionShell 注释）。
  const int shell_exit = RunCompanionShell();
  if (shell_exit >= 0) {
    return shell_exit;
  }

  // Release 不附着/创建控制台：GUI 用户的日志走文件 sink；去掉
  // AttachConsole/IsDebuggerPresent/AllocConsole 这些「调试器/控制台」特征。
#ifndef NDEBUG
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }
#endif

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
