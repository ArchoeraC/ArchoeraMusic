#ifndef RUNNER_BRIDGING_HEADER_H_
#define RUNNER_BRIDGING_HEADER_H_

// 原生 `archoerashell` 入口（Rust staticlib，见 app/core/shell）。main.swift 在
// Flutter 初始化前调用；返回进程退出码。
int archoera_shell_main(int argc, char **argv);

#endif  // RUNNER_BRIDGING_HEADER_H_
