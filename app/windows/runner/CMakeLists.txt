cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# === ArchoeraMusic archoerashell：内嵌 cargo staticlib（一键构建）===
# 以 staticlib 形式链入 runner：wWinMain 检测到 `archoerashell` 子命令时直接调用
# Rust 入口，命令行调用完全不初始化 Flutter/Dart（见 app/core/shell）。
find_program(CARGO cargo REQUIRED)
set(SHELL_CRATE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../core/shell")
# 桌面端仅发布 Release；VS 多配置生成器下 CMAKE_BUILD_TYPE 为空，按 Release 处理。
if(CMAKE_BUILD_TYPE MATCHES "Debug")
  set(SHELL_TARGET_DIR "${SHELL_CRATE_DIR}/target/debug")
  set(SHELL_CARGO_FLAGS "")
else()
  set(SHELL_TARGET_DIR "${SHELL_CRATE_DIR}/target/release")
  set(SHELL_CARGO_FLAGS "--release")
endif()
set(SHELL_STATIC_LIB "${SHELL_TARGET_DIR}/archoera_shell.lib")
add_custom_target(shell_cargo ALL
  COMMAND "${CARGO}" build ${SHELL_CARGO_FLAGS}
  WORKING_DIRECTORY "${SHELL_CRATE_DIR}"
  COMMENT "cargo build archoera-shell"
  VERBATIM
)
add_dependencies(${BINARY_NAME} shell_cargo)
target_link_libraries(${BINARY_NAME} PRIVATE "${SHELL_STATIC_LIB}")
# Rust std 的 MSVC 系统依赖（staticlib 内已带 /DEFAULTLIB，此处显式补齐更稳）。
target_link_libraries(${BINARY_NAME} PRIVATE ntdll userenv ws2_32 dbghelp)

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
