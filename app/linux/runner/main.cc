#include "my_application.h"

#include <cstring>

// 原生 `archoerashell` 入口（Rust staticlib，见 app/core/shell）。
// 在 GTK/Flutter 初始化之前拦截子命令：命令行调用完全不加载 Flutter 引擎。
extern "C" int archoera_shell_main(int argc, char** argv);

static bool has_shell_subcommand(int argc, char** argv) {
  for (int i = 1; i < argc; i++) {
    if (std::strcmp(argv[i], "archoerashell") == 0) return true;
  }
  return false;
}

int main(int argc, char** argv) {
  if (has_shell_subcommand(argc, argv)) {
    return archoera_shell_main(argc, argv);
  }
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
