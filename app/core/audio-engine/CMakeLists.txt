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
set(TEMPO_LIB ${CMAKE_CURRENT_BINARY_DIR}/libaudio_tempo.a)

# 尝试查找 cargo
find_program(CARGO_EXE cargo)
if(CARGO_EXE)
    # 构建 Rust staticlib
    add_custom_command(
        OUTPUT ${TEMPO_LIB}
        COMMAND ${CARGO_EXE} build --release --target-dir ${CMAKE_CURRENT_BINARY_DIR}/tempo-target
        COMMAND ${CMAKE_COMMAND} -E copy
            ${CMAKE_CURRENT_BINARY_DIR}/tempo-target/release/libaudio_tempo.a
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

# ── CLI 二进制 ──────────────────────────────────────────────
add_executable(splayer-audio-engine
    src/main.c
    ${AUDIO_ENGINE_EXTRA_SOURCES}
)
target_link_libraries(splayer-audio-engine PRIVATE audio_engine_static)

# 如果 Rust tempo 可用，链接
if(TEMPO_AVAILABLE)
    add_dependencies(splayer-audio-engine tempo_lib)
    target_link_libraries(splayer-audio-engine PRIVATE ${TEMPO_LIB} stdc++)
    target_compile_definitions(splayer-audio-engine PRIVATE HAS_TEMPO=1)
endif()

# ── 安装目标 ────────────────────────────────────────────────
install(TARGETS splayer-audio-engine
    RUNTIME DESTINATION bin
)

# ── 共享库（Dart FFI 桌面端，替代进程 IPC；archoera_mediaengine）────────
find_package(Threads REQUIRED)
add_library(archoera_mediaengine SHARED src/mediaengine_lib.c src/tempo.c)
target_include_directories(archoera_mediaengine PRIVATE
    ${AUDIO_ENGINE_INCLUDES}
    ${FFMPEG_INCLUDE_DIRS}
)
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
    target_link_libraries(archoera_mediaengine PRIVATE ${TEMPO_LIB} stdc++)
    target_compile_definitions(archoera_mediaengine PRIVATE HAS_TEMPO=1)
endif()

# ── 测试 ────────────────────────────────────────────────────
enable_testing()
# tests/ 目录包含单元测试
if(EXISTS ${CMAKE_CURRENT_SOURCE_DIR}/tests/CMakeLists.txt)
    add_subdirectory(tests)
endif()
