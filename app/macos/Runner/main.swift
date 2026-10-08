import Cocoa
import Darwin

// 原生 `archoerashell` 入口（Rust staticlib，见 app/core/shell）。在 Flutter/AppKit
// 初始化之前拦截子命令：命令行调用完全不加载 Flutter 引擎。与 Linux/Windows
// runner 行为一致（argv 含 argv[0]，Rust 侧定位子命令）。
if CommandLine.arguments.dropFirst().contains("archoerashell") {
  exit(archoera_shell_main(CommandLine.argc, CommandLine.unsafeArgv))
}

_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
