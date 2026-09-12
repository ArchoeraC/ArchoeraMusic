# ArchoeraMusic 平台能力原生桥接 —— CMake 构建
# Copyright (C) 2026 Archoera && BetaStudio2
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# 产物（Dart 经 dart:ffi 直调 apl_* C ABI）：
#   Windows: archoera_platform.dll（MSVC，WinRT 经 cppwinrt）
#   Linux  : libarchoera_platform.so（libdbus + X11）
#   macOS  : libarchoera_platform.dylib（ObjC++，MediaPlayer/AppKit）
#
# 各平台后端按平台二选一；未覆盖平台落 backend_stub.cpp。

cmake_minimum_required(VERSION 3.20)
project(archoera_platform LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

# 产物统一落 build/out/（屏蔽单/多配置生成器差异，供各 app 构建脚本固定路径引用）。
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/out")
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/out")
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/out")
foreach(CFG IN ITEMS DEBUG RELEASE RELWITHDEBINFO MINSIZEREL)
  set(CMAKE_RUNTIME_OUTPUT_DIRECTORY_${CFG} "${CMAKE_BINARY_DIR}/out")
  set(CMAKE_LIBRARY_OUTPUT_DIRECTORY_${CFG} "${CMAKE_BINARY_DIR}/out")
  set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY_${CFG} "${CMAKE_BINARY_DIR}/out")
endforeach()

set(ARCHOERA_SOURCES
  src/core.cpp
  src/apl.cpp
)

if(WIN32)
  list(APPEND ARCHOERA_SOURCES src/backend_windows.cpp)
elseif(APPLE)
  enable_language(OBJCXX)
  set(CMAKE_OBJCXX_STANDARD 20)
  list(APPEND ARCHOERA_SOURCES src/backend_macos.mm)
  set_source_files_properties(src/backend_macos.mm PROPERTIES
    COMPILE_OPTIONS "-fobjc-arc")
elseif(UNIX)
  list(APPEND ARCHOERA_SOURCES src/backend_linux.cpp)
else()
  list(APPEND ARCHOERA_SOURCES src/backend_stub.cpp)
endif()

add_library(archoera_platform SHARED ${ARCHOERA_SOURCES})
target_include_directories(archoera_platform PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/src"
)
# 导出宏：Windows 上 apl_* 需 __declspec(dllexport)（见 archoera_platform.h）。
target_compile_definitions(archoera_platform PRIVATE ARCHOERA_PLATFORM_BUILD)

if(MSVC)
  target_compile_options(archoera_platform PRIVATE /W3 /permissive- /Zc:__cplusplus /utf-8)
  target_compile_definitions(archoera_platform PRIVATE _WIN32_WINNT=0x0A00 WINVER=0x0A00)
endif()

if(WIN32)
  target_link_libraries(archoera_platform PRIVATE
    user32 powrprof advapi32 dwmapi windowsapp
    shell32 shlwapi propsys ole32 uuid)
  # C++/WinRT 头：优先 CMake 变量/缓存 -DCPPWINRT_INCLUDE=<dir>，其次 vcpkg 的
  # cppwinrt CONFIG 包。未提供时 backend_windows.cpp 自动降级（__has_include）。
  if(NOT CPPWINRT_INCLUDE)
    find_package(cppwinrt CONFIG QUIET)
    if(TARGET cppwinrt)
      target_link_libraries(archoera_platform PRIVATE cppwinrt)
    endif()
  endif()
  if(CPPWINRT_INCLUDE)
    target_include_directories(archoera_platform PRIVATE "${CPPWINRT_INCLUDE}")
  endif()
elseif(APPLE)
  target_link_libraries(archoera_platform PRIVATE
    "-framework Foundation"
    "-framework AppKit"
    "-framework MediaPlayer"
    "-framework UserNotifications"
    "-framework CoreFoundation")
elseif(UNIX)
  find_package(PkgConfig REQUIRED)
  pkg_check_modules(DBUS REQUIRED IMPORTED_TARGET dbus-1)
  target_link_libraries(archoera_platform PRIVATE PkgConfig::DBUS ${CMAKE_DL_LIBS})
endif()
