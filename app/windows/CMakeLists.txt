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
# 产出（CI workflow 在 flutter build 前显式构建）；install 拷贝进 bundle：
#   Release/audio-engine/build/{archoera-audio-engine.exe,archoera_mediaengine.dll,fft.dll}
#   Release/scanner/build/{scanner-ffi.dll,libe_sqlite3.dll}
#   Release/scraper/build/archoera_scraper.dll
#   Release/subsonic/build/{libarchoera_subsonic.dll,archoera_transcoder.dll}
#   Release/core/downloader/target/release/archoera_downloader.dll
# 路径对齐各 FFI 绑定的「exe 祖先链向上找 X/build/」约定；源产物缺失时跳过
#（OPTIONAL），保证未构建原生模块时仍可跑 Flutter 构建。
set(ENGINE_SRC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../core/audio-engine/build")
set(SCANNER_SRC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../core/scanner/build")
set(SCRAPER_SRC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../core/scraper/build")
set(SUBSONIC_SRC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../core/subsonic/build")

install(PROGRAMS "${ENGINE_SRC_DIR}/archoera-audio-engine.exe"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/audio-engine/build" COMPONENT Runtime OPTIONAL)
install(FILES "${ENGINE_SRC_DIR}/archoera_mediaengine.dll"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/audio-engine/build" COMPONENT Runtime OPTIONAL)
install(FILES "${ENGINE_SRC_DIR}/fft.dll"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/audio-engine/build" COMPONENT Runtime OPTIONAL)
install(FILES "${SCANNER_SRC_DIR}/scanner-ffi.dll"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/scanner/build" COMPONENT Runtime OPTIONAL)
install(FILES "${SCANNER_SRC_DIR}/e_sqlite3.dll"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/scanner/build" COMPONENT Runtime OPTIONAL)
install(FILES "${SCRAPER_SRC_DIR}/archoera_scraper.dll"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/scraper/build" COMPONENT Runtime OPTIONAL)
install(FILES "${SUBSONIC_SRC_DIR}/libarchoera_subsonic.dll"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/subsonic/build" COMPONENT Runtime OPTIONAL)
install(FILES "${SUBSONIC_SRC_DIR}/archoera_transcoder.dll"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/subsonic/build" COMPONENT Runtime OPTIONAL)

# downloader：cargo 内嵌构建链产出 target/release/archoera_downloader.dll
#（download 目标为 ALL，flutter build 前已随 workflow 显式 cargo build）。
install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/../core/downloader/target/release/archoera_downloader.dll"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/core/downloader/target/release" COMPONENT Runtime)
