# server/audio-engine/CMakeLists.txt
#
# Phase 4：FFmpeg 解码 + swresample 重采样 + EQ + loudness + limiter
#          + tempo (Rust signalsmith-stretch) + FFT + Opus 编码 + OGG 封装
#
# 构建：
#   cmake -B build -DCMAKE_BUILD_TYPE=Release
#   cmake --build build -j$(nproc)
#
# 产物：
#   build/splayer-audio-engine  (独立 CLI 二进制)
#
# 依赖（Fedora 42）：
#   dnf install ffmpeg-devel gcc cmake cargo rustc

cmake_minimum_required(VERSION 3.16)

project(splayer-audio-engine
    VERSION 0.3.0
    LANGUAGES C
)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

# ── 编译选项 ────────────────────────────────────────────────
if(CMAKE_C_COMPILER_ID MATCHES "GNU|Clang")
    add_compile_options(
        -Wall -Wextra -Wno-unused-parameter
        -O2
        -fvisibility=hidden
    )
endif()

# ── FFmpeg 依赖（pkg-config 查找）────────────────────────────
find_package(PkgConfig REQUIRED)
pkg_check_modules(FFMPEG REQUIRED
    libavformat
    libavcodec
    libavutil
    libswresample
)

# ── Rust tempo 库 ──────────────────────────────────────────
set(TEMPO_RS_DIR ${CMAKE_CURRENT_SOURCE_DIR}/tempo-rs)
# Rust staticlib 命名：MSVC 输出 `.lib`（链接需 MSVC 格式），其余平台 `.a`。
# 若实际产物名不同（如 MSVC 下 audio_tempo.lib），CI 中先归一化为下面的期望名。
if(MSVC)
    set(TEMPO_LIB ${CMAKE_CURRENT_BINARY_DIR}/libaudio_tempo.lib)
    set(TEMPO_RUST_SRC libaudio_tempo.lib)
else()
    set(TEMPO_LIB ${CMAKE_CURRENT_BINARY_DIR}/libaudio_tempo.a)
    set(TEMPO_RUST_SRC libaudio_tempo.a)
endif()

# 尝试查找 cargo
find_program(CARGO_EXE cargo)
if(CARGO_EXE)
    # 构建 Rust staticlib
    add_custom_command(
        OUTPUT ${TEMPO_LIB}
        COMMAND ${CARGO_EXE} build --release --target-dir ${CMAKE_CURRENT_BINARY_DIR}/tempo-target
        COMMAND ${CMAKE_COMMAND} -E copy
            ${CMAKE_CURRENT_BINARY_DIR}/tempo-target/release/${TEMPO_RUST_SRC}
            ${TEMPO_LIB}
        WORKING_DIRECTORY ${TEMPO_RS_DIR}
        COMMENT "Building Rust tempo library (audio_tempo)"
        VERBATIM
    )
    add_custom_target(tempo_lib DEPENDS ${TEMPO_LIB})
    set(TEMPO_AVAILABLE TRUE)
else()
    message(WARNING "cargo not found — tempo (变速变调) 功能将不可用，请在构建环境安装 Rust")
    set(TEMPO_AVAILABLE FALSE)
endif()

# ── 源文件 ──────────────────────────────────────────────────
set(AUDIO_ENGINE_SOURCES
    src/decoder.c
    src/resampler.c
    src/encoder.c
    src/equalizer.c
    src/loudness.c
    src/limiter.c
    src/fft.c
    src/pipeline.c
    src/pcm_uds.c
    src/player.c
)

set(AUDIO_ENGINE_EXTRA_SOURCES
    src/tempo.c
)

set(AUDIO_ENGINE_INCLUDES
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/src
)

# ── 数学库 ──────────────────────────────────────────────────
find_library(MATH_LIBRARY m)

# ── 静态库（供测试和其他程序复用）────────────────────────────
add_library(audio_engine_static STATIC ${AUDIO_ENGINE_SOURCES})
set_target_properties(audio_engine_static PROPERTIES POSITION_INDEPENDENT_CODE ON)
target_include_directories(audio_engine_static PUBLIC
    ${AUDIO_ENGINE_INCLUDES}
    ${FFMPEG_INCLUDE_DIRS}
)
target_link_libraries(audio_engine_static PUBLIC ${FFMPEG_LIBRARIES})
if(MATH_LIBRARY)
    target_link_libraries(audio_engine_static PUBLIC ${MATH_LIBRARY})
endif()
target_link_directories(audio_engine_static PUBLIC ${FFMPEG_LIBRARY_DIRS})
target_compile_options(audio_engine_static PUBLIC ${FFMPEG_CFLAGS_OTHER})

# ── FFT 共享库（Dart FFI 客户端频谱分析；EnginePaths.libfftPath）──────────
# 独立编译 src/fft.c（无外部依赖，仅 libm）。注意全局 -fvisibility=hidden
# 会隐藏所有导出符号，此目标需恢复 default 可见性，否则 Dart 侧
# DynamicLibrary.lookup('fft_create') 等将找不到符号。
add_library(fft SHARED src/fft.c)
set_target_properties(fft PROPERTIES C_VISIBILITY_PRESET default)
# 全局 add_compile_options(-fvisibility=hidden) 位于编译参数末尾，会覆盖
# C_VISIBILITY_PRESET；需在此目标显式追加 default（GCC/Clang 后者生效）。
if(CMAKE_C_COMPILER_ID MATCHES "GNU|Clang")
    target_compile_options(fft PRIVATE -fvisibility=default)
endif()
target_include_directories(fft PRIVATE ${AUDIO_ENGINE_INCLUDES})
if(MATH_LIBRARY)
    target_link_libraries(fft PRIVATE ${MATH_LIBRARY})
endif()

# ── CLI 二进制（Windows/MSVC 跳过：main.c 深度依赖 POSIX——
#    unistd/fcntl/getopt_long/clock_gettime 等，且桌面端 FFI 库
#    archoera_mediaengine 已覆盖 Windows 用途，CLI 仅为调试/独立运行）──────
if(NOT MSVC)
add_executable(splayer-audio-engine
    src/main.c
    ${AUDIO_ENGINE_EXTRA_SOURCES}
)
target_link_libraries(splayer-audio-engine PRIVATE audio_engine_static)

# 如果 Rust tempo 可用，链接
if(TEMPO_AVAILABLE)
    add_dependencies(splayer-audio-engine tempo_lib)
    # C++ 运行时按平台：MSVC 用默认 CRT / AppleClang 用 libc++ / GCC 用 stdc++
    if(MSVC)
        target_link_libraries(splayer-audio-engine PRIVATE ${TEMPO_LIB})
    elseif(APPLE)
        target_link_libraries(splayer-audio-engine PRIVATE ${TEMPO_LIB} c++)
    else()
        target_link_libraries(splayer-audio-engine PRIVATE ${TEMPO_LIB} stdc++)
    endif()
    target_compile_definitions(splayer-audio-engine PRIVATE HAS_TEMPO=1)
endif()

# ── 安装目标 ────────────────────────────────────────────────
install(TARGETS splayer-audio-engine
    RUNTIME DESTINATION bin
)
endif()

# ── 共享库（Dart FFI 桌面端，替代进程 IPC；archoera_mediaengine）────────
find_package(Threads REQUIRED)
add_library(archoera_mediaengine SHARED src/mediaengine_lib.c src/tempo.c)
target_include_directories(archoera_mediaengine PRIVATE
    ${AUDIO_ENGINE_INCLUDES}
    ${FFMPEG_INCLUDE_DIRS}
)
if(MSVC)
    # MSVC 无系统 pthread.h：include/compat 提供最小 pthread 兼容层，
    # 覆盖 mediaengine_lib.c 用到的 mutex/cond/thread/nanosleep
    target_include_directories(archoera_mediaengine PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/include/compat)
endif()
target_link_libraries(archoera_mediaengine PRIVATE
    audio_engine_static
    ${FFMPEG_LIBRARIES}
    Threads::Threads
)
if(MATH_LIBRARY)
    target_link_libraries(archoera_mediaengine PRIVATE ${MATH_LIBRARY})
endif()
target_link_directories(archoera_mediaengine PRIVATE ${FFMPEG_LIBRARY_DIRS})
target_compile_options(archoera_mediaengine PRIVATE ${FFMPEG_CFLAGS_OTHER})
if(TEMPO_AVAILABLE)
    add_dependencies(archoera_mediaengine tempo_lib)
    if(MSVC)
        target_link_libraries(archoera_mediaengine PRIVATE ${TEMPO_LIB})
    elseif(APPLE)
        target_link_libraries(archoera_mediaengine PRIVATE ${TEMPO_LIB} c++)
    else()
        target_link_libraries(archoera_mediaengine PRIVATE ${TEMPO_LIB} stdc++)
    endif()
    target_compile_definitions(archoera_mediaengine PRIVATE HAS_TEMPO=1)
endif()

# ── 测试 ────────────────────────────────────────────────────
enable_testing()
# tests/ 目录包含单元测试
if(EXISTS ${CMAKE_CURRENT_SOURCE_DIR}/tests/CMakeLists.txt)
    add_subdirectory(tests)
endif()
