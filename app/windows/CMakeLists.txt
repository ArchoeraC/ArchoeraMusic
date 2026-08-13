# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(archoera_music LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "archoera_music")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Release" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Release")
  endif()
endif()
# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
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
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)

# === ArchoeraMusic 原生产物打包（与 linux/CMakeLists.txt 对齐）===
# 引擎模块位于 app/core/{audio-engine,scanner,scraper,subsonic}，产物由独立构建链
# 产出（CI workflow 在 flutter build 前显式构建）；install 统一装进 native/ 平铺
# （对齐 ffi-libs-layout 计划；NativeLibPaths 祖先链优先查 native/）：
#   Release/native/{archoera-audio-engine.exe,archoera_mediaengine.dll,fft.dll}
#   Release/native/{scanner-ffi.dll,e_sqlite3.dll}
#   Release/native/archoera_scraper.dll
#   Release/native/{libarchoera_subsonic.dll,archoera_transcoder.dll}
#   Release/native/archoera-vault.exe
#   Release/native/archoera_downloader.dll
# 源产物缺失时跳过（OPTIONAL），保证未构建原生模块时仍可跑 Flutter 构建。
set(ENGINE_SRC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../core/audio-engine/build")
set(SCANNER_SRC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../core/scanner/build")
set(SCRAPER_SRC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../core/scraper/build")
set(SUBSONIC_SRC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../core/subsonic/build")

install(PROGRAMS "${ENGINE_SRC_DIR}/archoera-audio-engine.exe"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/native" COMPONENT Runtime OPTIONAL)
install(FILES "${ENGINE_SRC_DIR}/archoera_mediaengine.dll"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/native" COMPONENT Runtime OPTIONAL)
install(FILES "${ENGINE_SRC_DIR}/fft.dll"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/native" COMPONENT Runtime OPTIONAL)
install(FILES "${SCANNER_SRC_DIR}/scanner-ffi.dll"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/native" COMPONENT Runtime OPTIONAL)
install(FILES "${SCANNER_SRC_DIR}/e_sqlite3.dll"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/native" COMPONENT Runtime OPTIONAL)
install(FILES "${SCRAPER_SRC_DIR}/archoera_scraper.dll"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/native" COMPONENT Runtime OPTIONAL)
install(FILES "${SUBSONIC_SRC_DIR}/libarchoera_subsonic.dll"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/native" COMPONENT Runtime OPTIONAL)
install(FILES "${SUBSONIC_SRC_DIR}/archoera_transcoder.dll"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/native" COMPONENT Runtime OPTIONAL)

# vault（凭据保险库）：NativeAOT 可执行（dotnet publish，见 core/vault/build.sh），
# 随包分发供 Dart 按需 spawn（凭据加解密 2-of-2；OS 授权份额存 DPAPI）。
set(VAULT_SRC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../core/vault/build")
install(PROGRAMS "${VAULT_SRC_DIR}/archoera-vault.exe"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/native" COMPONENT Runtime OPTIONAL)

# downloader：cargo 内嵌构建链产出 target/release/archoera_downloader.dll
#（download 目标为 ALL，flutter build 前已随 workflow 显式 cargo build）。
install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/../core/downloader/target/release/archoera_downloader.dll"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/native" COMPONENT Runtime)

# === vcpkg 运行时 DLL（FFmpeg 等动态依赖）===
# audio-engine（archoera_mediaengine.dll / scraper）经 vcpkg import libs 动态链接
# ffmpeg/taglib/curl 等（triplet x64-windows-release 为动态构建）；运行时必须把
# vcpkg_installed/<triplet>/bin/*.dll 一并分发到 exe 根目录——Windows 加载器按
# exe 目录解析 archoera_mediaengine.dll 的依赖，缺 FFmpeg DLL 会直接加载失败
#（表现为播放稳定跳过所有歌曲）。triplet 与 build_windows.bat 对齐。
if(NOT DEFINED VCPKG_TARGET_TRIPLET)
  set(VCPKG_TARGET_TRIPLET "$ENV{VCPKG_TARGET_TRIPLET}")
  if(NOT VCPKG_TARGET_TRIPLET)
    set(VCPKG_TARGET_TRIPLET "x64-windows-release")
  endif()
endif()
set(VCPKG_BIN_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../vcpkg_installed/${VCPKG_TARGET_TRIPLET}/bin")
file(GLOB VCPKG_RUNTIME_DLLS "${VCPKG_BIN_DIR}/*.dll")
if(VCPKG_RUNTIME_DLLS)
  install(FILES ${VCPKG_RUNTIME_DLLS}
    DESTINATION "${CMAKE_INSTALL_PREFIX}"
    COMPONENT Runtime)
endif()

# === mingw 运行时 DLL（subsonic Go c-shared 依赖）===
# libarchoera_subsonic.dll 由 mingw（gcc，cgo 必需）编译，动态依赖
# libgcc_s_seh-1.dll / libwinpthread-1.dll；scraper 内嵌的 mingw DLL
#（vcpkg 三角为 MSVC 构建，不含这两者）。Windows 加载器按 exe 目录解析
# 经绝对路径 open 的 subsonic DLL 的依赖，故须随包分发到 exe 根目录。
# 搜索 choco mingw 安装目录（CI）与本机 MINGW 根（如有），找不到时静默跳过
#（subsonic 模块缺失时不影响其余模块构建）。
set(MINGW_RUNTIME_SEARCH
  "$ENV{ChocolateyInstall}/lib/mingw/tools/install/mingw64/bin"
  "C:/ProgramData/chocolatey/lib/mingw/tools/install/mingw64/bin"
  "$ENV{MINGW_ROOT}/bin"
  "$ENV{MINGW64_ROOT}/bin"
)
find_file(MINGW_RT_GCC_DLL libgcc_s_seh-1.dll
  HINTS ${MINGW_RUNTIME_SEARCH} NO_DEFAULT_PATH)
find_file(MINGW_RT_PTHREAD_DLL libwinpthread-1.dll
  HINTS ${MINGW_RUNTIME_SEARCH} NO_DEFAULT_PATH)
find_file(MINGW_RT_STDCXX_DLL libstdc++-6.dll
  HINTS ${MINGW_RUNTIME_SEARCH} NO_DEFAULT_PATH)
set(MINGW_RUNTIME_DLLS "")
foreach(_d IN ITEMS MINGW_RT_GCC_DLL MINGW_RT_PTHREAD_DLL MINGW_RT_STDCXX_DLL)
  if(${_d})
    list(APPEND MINGW_RUNTIME_DLLS "${${_d}}")
  endif()
endforeach()
if(MINGW_RUNTIME_DLLS)
  install(FILES ${MINGW_RUNTIME_DLLS}
    DESTINATION "${CMAKE_INSTALL_PREFIX}"
    COMPONENT Runtime)
endif()
