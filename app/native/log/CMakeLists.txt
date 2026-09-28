# ArchoeraMusic 统一日志核心 —— CMake 构建
# Copyright (C) 2026 Archoera && BetaStudio2
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# 产物（Dart 经 dart:ffi 载入并调用，同时把 archoera_log_write 指针注入各原生组件）：
#   Windows: archoera_log.dll
#   Linux  : libarchoera_log.so
#   macOS  : libarchoera_log.dylib
#
# 纯 C11、零第三方依赖；线程原语按平台自选（POSIX pthread / Win32 SRWLOCK）。

cmake_minimum_required(VERSION 3.20)
project(archoera_log LANGUAGES C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

# 产物统一落 build/out/（供各 app 构建脚本固定路径引用，与 platform 桥一致）。
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/out")
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/out")
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/out")
foreach(CFG IN ITEMS DEBUG RELEASE RELWITHDEBINFO MINSIZEREL)
  set(CMAKE_RUNTIME_OUTPUT_DIRECTORY_${CFG} "${CMAKE_BINARY_DIR}/out")
  set(CMAKE_LIBRARY_OUTPUT_DIRECTORY_${CFG} "${CMAKE_BINARY_DIR}/out")
  set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY_${CFG} "${CMAKE_BINARY_DIR}/out")
endforeach()

add_library(archoera_log SHARED src/archoera_log.c)
target_include_directories(archoera_log PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_compile_definitions(archoera_log PRIVATE ARCHOERA_LOG_BUILD)

if(MSVC)
  target_compile_options(archoera_log PRIVATE /W3 /utf-8)
  # fopen 等 CRT “不安全”告警：本库仅追加写自有日志文件，无需 _s 变体。
  target_compile_definitions(archoera_log PRIVATE _CRT_SECURE_NO_WARNINGS)
else()
  target_compile_options(archoera_log PRIVATE -Wall -Wextra)
  # 路径缓冲区已按上限预留轮转后缀，GCC 无法证明不截断，按要求静默该告警。
  target_compile_options(archoera_log PRIVATE -Wno-format-truncation)
  # 严格 C11 下暴露 POSIX（fileno/localtime_r/mkdir/access/isatty）。
  target_compile_definitions(archoera_log PRIVATE _POSIX_C_SOURCE=200809L)
endif()

if(UNIX AND NOT APPLE)
  find_package(Threads REQUIRED)
  target_link_libraries(archoera_log PRIVATE Threads::Threads)
endif()

# ── 可选单测（-DARCHOERA_LOG_TESTS=ON）────────────────────────────
option(ARCHOERA_LOG_TESTS "Build archoera_log unit tests" OFF)
if(ARCHOERA_LOG_TESTS)
  enable_testing()
  add_executable(test_log tests/test_log.c)
  target_link_libraries(test_log PRIVATE archoera_log)
  if(NOT MSVC)
    target_compile_definitions(test_log PRIVATE _POSIX_C_SOURCE=200809L)
  endif()
  add_test(NAME test_log COMMAND $<TARGET_FILE:test_log>)
endif()
