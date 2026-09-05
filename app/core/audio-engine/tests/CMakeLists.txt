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

# 集成测试（需要输入文件的跳过 CTEST，仅通过手动运行）
# add_engine_test(test_pipeline test_pipeline.c)
