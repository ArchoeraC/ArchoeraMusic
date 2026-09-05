# server/audio-engine/tests/CMakeLists.txt
# 单元测试

cmake_minimum_required(VERSION 3.16)

# 利用 C 标准库的 assert, 用 CMake/CTest 运行
enable_testing()

# 测试辅助：链接主库 + 测试源文件
macro(add_engine_test name source)
    add_executable(${name} ${source})
    target_link_libraries(${name} PRIVATE audio_engine_static)
    target_include_directories(${name} PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/../include
        ${CMAKE_CURRENT_SOURCE_DIR}/../src
    )
    add_test(NAME ${name} COMMAND ${name})
endmacro()

# 各模块单元测试
add_engine_test(test_equalizer test_equalizer.c)
add_engine_test(test_limiter test_limiter.c)
add_engine_test(test_fft test_fft.c)
add_engine_test(test_loudness test_loudness.c)

# wait_event 事件驱动契约测试：直接编译 mediaengine_lib.c 本体（与
# libarchoera_mediaengine.so 同源），真实引擎句柄验证阻塞/唤醒/超时/
# 销毁唤醒/多次 create-destroy。tempo.c 以无 HAS_TEMPO 的 stub 链接。
find_package(Threads QUIET)
add_executable(test_mediaengine_wait
    test_mediaengine_wait.c
    ${CMAKE_CURRENT_SOURCE_DIR}/../src/mediaengine_lib.c
    ${CMAKE_CURRENT_SOURCE_DIR}/../src/tempo.c
)
target_link_libraries(test_mediaengine_wait PRIVATE audio_engine_static)
if(TARGET Threads::Threads)
    target_link_libraries(test_mediaengine_wait PRIVATE Threads::Threads)
endif()
target_include_directories(test_mediaengine_wait PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../include
    ${CMAKE_CURRENT_SOURCE_DIR}/../src
)
add_test(NAME test_mediaengine_wait
         COMMAND test_mediaengine_wait
                 ${CMAKE_CURRENT_SOURCE_DIR}/../samples/aac/t48_m.wav)

# EraAudio 原生内核 offset/seek 回归（headless：无音频设备依赖）。
# fixture = 带 SEEKTABLE + PICTURE 的 FLAC（seekpoint 偏移为规范相对音频起点）；
# 旧实现按绝对偏移 seek 落进元数据区 → Corrupt → 断点续播/seek 失败。
# tempo.c 以无 HAS_TEMPO 的 stub 链接（与 test_mediaengine_wait 同法）。
add_executable(test_native_seek test_native_seek.c
    ${CMAKE_CURRENT_SOURCE_DIR}/../src/tempo.c
)
target_link_libraries(test_native_seek PRIVATE audio_engine_static)
target_include_directories(test_native_seek PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../include
    ${CMAKE_CURRENT_SOURCE_DIR}/../src
)
add_test(NAME test_native_seek
         COMMAND test_native_seek
                 ${CMAKE_CURRENT_SOURCE_DIR}/native_seek_fixture.flac)
set_tests_properties(test_native_seek PROPERTIES
    PASS_REGULAR_EXPRESSION "ALL PASS")

# 集成测试（需要输入文件的跳过 CTEST，仅通过手动运行）
# add_engine_test(test_pipeline test_pipeline.c)
