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

# 集成测试（需要输入文件的跳过 CTEST，仅通过手动运行）
# add_engine_test(test_pipeline test_pipeline.c)
