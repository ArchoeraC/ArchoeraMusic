# Project-level configuration.
cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "archoera_music")
# The unique GTK application identifier for this application. See:
# https://wiki.gnome.org/HowDoI/ChooseApplicationID
set(APPLICATION_ID "com.archoera.archoera_music")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(SET CMP0063 NEW)

# Load bundled libraries from the lib/ directory relative to the binary.
set(CMAKE_INSTALL_RPATH "$ORIGIN/lib")

# Root filesystem for cross-building.
if(FLUTTER_TARGET_PLATFORM_SYSROOT)
  set(CMAKE_SYSROOT ${FLUTTER_TARGET_PLATFORM_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH ${CMAKE_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
  set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
endif()

# Define build configuration options.
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE "Debug" CACHE
    STRING "Flutter build mode" FORCE)
  set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
    "Debug" "Profile" "Release")
endif()

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_14)
  # -Wno-deprecated-declarations：tray_manager 调用的 appindicator 新 API 在
  # 新版 libayatana-appindicator 中被整体标记 G_GNUC_DEPRECATED，-Werror 会
  # 把该弃用告警升级为错误，这里显式关闭该告警类（不影响其它告警）。
  target_compile_options(${TARGET} PRIVATE -Wall -Werror -Wno-deprecated-declarations)
  target_compile_options(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:-O3>")
  target_compile_definitions(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:NDEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# System-level dependencies.
find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK REQUIRED IMPORTED_TARGET gtk+-3.0)

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")

# === ArchoeraMusic downloader：内嵌 cargo 编译链（一键构建）===
# flutter build / flutter run 时自动调用 cargo 产出 libarchoera_downloader.{so,dylib,dll}
# 并镜像进 bundle，无需手动先 cargo build。cargo 自身增量编译，无变更时仅 ~0.1s。
# 构建模式与 Flutter 对齐：Debug → target/debug（cargo build），
# Release/Profile → target/release（cargo build --release）。
find_program(CARGO cargo REQUIRED)
set(DOWNLOADER_CRATE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../core/downloader")
if(CMAKE_BUILD_TYPE MATCHES "Debug")
  set(DOWNLOADER_TARGET_DIR "${DOWNLOADER_CRATE_DIR}/target/debug")
  set(DOWNLOADER_MODE_DIR "debug")
  set(DOWNLOADER_CARGO_FLAGS "")
else()
  set(DOWNLOADER_TARGET_DIR "${DOWNLOADER_CRATE_DIR}/target/release")
  set(DOWNLOADER_MODE_DIR "release")
  set(DOWNLOADER_CARGO_FLAGS "--release")
endif()
if(WIN32)
  set(DOWNLOADER_LIB_NAME "archoera_downloader.dll")
elseif(APPLE)
  set(DOWNLOADER_LIB_NAME "libarchoera_downloader.dylib")
else()
  set(DOWNLOADER_LIB_NAME "libarchoera_downloader.so")
endif()
# 每次都执行 cargo（其自身增量），保证 Rust 源码变更后 flutter build 自动重编。
add_custom_target(downloader_cargo ALL
  COMMAND ${CARGO} build ${DOWNLOADER_CARGO_FLAGS}
  WORKING_DIRECTORY "${DOWNLOADER_CRATE_DIR}"
  COMMENT "cargo build archoera-downloader"
  VERBATIM
)
# 二进制 target 构建/安装前先完成 Rust 编译。
add_dependencies(${BINARY_NAME} downloader_cargo)

# === ArchoeraMusic subsonic：内嵌 Go + cargo 构建链（一键构建）===
# flutter build / flutter run 时自动调用 build.sh（cargo cdylib 转码器 +
# go build -buildmode=c-shared 服务端库 + 产物拷贝到 subsonic/build/），
# 与 downloader 一致，无需手动预构建；go/cargo 自身增量，无变更时仅 ~0.1s。
# 产物路径固定 subsonic/build/（Go c-shared 不分构建模式），供下方 OPTIONAL
# install 拷贝进 bundle（subsonic_bindings.dart 按 exe 祖先链 dlopen）。
# GO 缺失时跳过自动构建，保持原 OPTIONAL 语义（现成产物仍可打包）。
find_program(GO go)
find_program(BASH bash REQUIRED)
set(SUBSONIC_BUILD_SCRIPT "${CMAKE_CURRENT_SOURCE_DIR}/../core/subsonic/build.sh")
if(GO)
  add_custom_target(subsonic_go ALL
    COMMAND ${BASH} "${SUBSONIC_BUILD_SCRIPT}"
    COMMENT "build archoera-subsonic (cargo transcoder + go c-shared)"
    VERBATIM
  )
  add_dependencies(${BINARY_NAME} subsonic_go)
endif()

# === ArchoeraMusic audio-engine：内嵌 CMake 构建链（一键构建）===
# flutter build / flutter run 时自动调用 cmake 产出 libfft.so /
# libarchoera_mediaengine.so / archoera-audio-engine 到 audio-engine/build/
#（与下方 OPTIONAL install 路径一致），无需手动 cmake 预构建。
# cmake 自身增量编译，无变更时仅 ~0.1s。依赖系统 ffmpeg-devel
#（pkg-config libavformat/libavcodec/libavutil/libswresample）与 cargo
#（tempo 变速变调，缺失时仅告警降级）。构建产物固定 Release（audio-engine
# 内部 Rust tempo 亦仅 release 构建），与 Flutter 构建模式解耦。
find_program(AUDIO_ENGINE_CMAKE cmake REQUIRED)
set(AUDIO_ENGINE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../core/audio-engine")
set(AUDIO_ENGINE_BUILD_DIR "${AUDIO_ENGINE_DIR}/build")
add_custom_target(audio_engine_cmake ALL
  COMMAND ${AUDIO_ENGINE_CMAKE} -S "${AUDIO_ENGINE_DIR}" -B "${AUDIO_ENGINE_BUILD_DIR}" -DCMAKE_BUILD_TYPE=Release
  COMMAND ${AUDIO_ENGINE_CMAKE} --build "${AUDIO_ENGINE_BUILD_DIR}" -j
  COMMENT "cmake build archoera-audio-engine (libfft + mediaengine)"
  VERBATIM
)
add_dependencies(${BINARY_NAME} audio_engine_cmake)

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# Only the install-generated bundle's copy of the executable will launch
# correctly, since the resources must in the right relative locations. To avoid
# people trying to run the unbundled copy, put it in a subdirectory instead of
# the default top-level location.
set_target_properties(${BINARY_NAME}
  PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/intermediates_do_not_run"
)


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# By default, "installing" just makes a relocatable bundle in the build
# directory.
set(BUILD_BUNDLE_DIR "${PROJECT_BINARY_DIR}/bundle")
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

# Start with a clean build bundle directory every time.
install(CODE "
  file(REMOVE_RECURSE \"${BUILD_BUNDLE_DIR}/\")
  " COMPONENT Runtime)

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}/lib")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

# 应用图标（窗口/任务栏用；由 my_application.cc 按可执行文件相对路径加载）。
install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/runner/resources/app_icon.png"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

foreach(bundled_library ${PLUGIN_BUNDLED_LIBRARIES})
  install(FILES "${bundled_library}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endforeach(bundled_library)

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/linux/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
if(NOT CMAKE_BUILD_TYPE MATCHES "Debug")
  install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# === ArchoeraMusic 原生产物打包（FFI 直连，降低运行时依赖）===
# 引擎模块位于 app/core/{audio-engine,scanner,scraper,subsonic}（app 内部，路径关系固定，
# 可随 app 独立部署），产物直接引用模块自身 build 目录，无需 cp：
#   bundle/audio-engine/build/{archoera-audio-engine,libarchoera_mediaengine.so,libfft.so}
#   bundle/scanner/build/{scanner-ffi.so,libe_sqlite3.so}
#   bundle/scraper/build/{libarchoera_scraper.so}
#   bundle/subsonic/build/{libarchoera_subsonic.so,libarchoera_transcoder.so}
#   bundle/core/downloader/target/{release,debug}/libarchoera_downloader.so
#     （downloader 为 cargo crate，按 target 目录镜像安装；downloader_ffi.dart
#       从可执行文件父目录沿 core/downloader/target/{release,debug} 逐级查找）
# 产物由独立构建链产出（audio-engine/scraper: cmake; scanner: dotnet publish;
# subsonic: build.sh 即 cargo + go）。
# OPTIONAL：源产物缺失时跳过（如未构建 subsonic 仍可跑 Flutter 构建）。
set(ENGINE_SRC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../core/audio-engine/build")
set(SCANNER_SRC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../core/scanner/build")
set(SCRAPER_SRC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../core/scraper/build")
set(SUBSONIC_SRC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../core/subsonic/build")

install(PROGRAMS "${ENGINE_SRC_DIR}/archoera-audio-engine"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/audio-engine/build" COMPONENT Runtime OPTIONAL)
install(FILES "${ENGINE_SRC_DIR}/libarchoera_mediaengine.so"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/audio-engine/build" COMPONENT Runtime OPTIONAL)
install(FILES "${ENGINE_SRC_DIR}/libfft.so"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/audio-engine/build" COMPONENT Runtime OPTIONAL)
install(FILES "${SCANNER_SRC_DIR}/scanner-ffi.so"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/scanner/build" COMPONENT Runtime OPTIONAL)
install(FILES "${SCANNER_SRC_DIR}/libe_sqlite3.so"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/scanner/build" COMPONENT Runtime OPTIONAL)
install(FILES "${SCRAPER_SRC_DIR}/libarchoera_scraper.so"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/scraper/build" COMPONENT Runtime OPTIONAL)
install(FILES "${SUBSONIC_SRC_DIR}/libarchoera_subsonic.so"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/subsonic/build" COMPONENT Runtime OPTIONAL)
install(FILES "${SUBSONIC_SRC_DIR}/libarchoera_transcoder.so"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/subsonic/build" COMPONENT Runtime OPTIONAL)

# downloader：产物由上方内嵌 cargo 构建链保证产出，镜像进 bundle 的
# core/downloader/target/{debug|release}（路径对齐 downloader_ffi.dart 的
# ancestors 查找：release 优先、debug 兜底，bundle 每次 install 前清空，
# 因此 bundle 内只存在本次构建模式的目录，FFI 查找必然命中）。
install(FILES "${DOWNLOADER_TARGET_DIR}/${DOWNLOADER_LIB_NAME}"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/core/downloader/target/${DOWNLOADER_MODE_DIR}"
  COMPONENT Runtime)
