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

# 内存播放（不落盘）模式回归（headless：不依赖音频设备；ARCHOERA_MEMORY_HEADLESS）。
# 直接编译 mediaengine_lib.c + tempo.c stub（与 test_mediaengine_wait 同法）。
add_executable(test_memory_mode test_memory_mode.c
    ${CMAKE_CURRENT_SOURCE_DIR}/../src/mediaengine_lib.c
    ${CMAKE_CURRENT_SOURCE_DIR}/../src/tempo.c
)
target_link_libraries(test_memory_mode PRIVATE audio_engine_static)
if(TARGET Threads::Threads)
    target_link_libraries(test_memory_mode PRIVATE Threads::Threads)
endif()
if(UNIX)
    target_link_libraries(test_memory_mode PRIVATE m)
endif()
target_include_directories(test_memory_mode PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../include
    ${CMAKE_CURRENT_SOURCE_DIR}/../src
)
add_test(NAME test_memory_mode COMMAND test_memory_mode)
set_tests_properties(test_memory_mode PROPERTIES
    PASS_REGULAR_EXPRESSION "ALL PASS")

# SegmentStore（在线纯内存源，M1，docs/audio-memory-source.md）：单调填充 +
# 阻塞 pread 对照 / 随机读 / EOF / abort 唤醒。编译 segstore.c 本体。
find_package(Threads QUIET)
add_executable(test_segstore test_segstore.c
    ${CMAKE_CURRENT_SOURCE_DIR}/../src/segstore.c
)
if(TARGET Threads::Threads)
    target_link_libraries(test_segstore PRIVATE Threads::Threads)
endif()
target_include_directories(test_segstore PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../include
    ${CMAKE_CURRENT_SOURCE_DIR}/../src
)
add_test(NAME test_segstore COMMAND test_segstore)
set_tests_properties(test_segstore PROPERTIES
    PASS_REGULAR_EXPRESSION "ALL PASS")

# M2.3 进程级段池：开启后 destroy→新会话复用旧段（跨会话免 malloc 碎片）。
add_executable(test_segpool test_segpool.c)
target_link_libraries(test_segpool PRIVATE audio_engine_static)
if(TARGET Threads::Threads)
    target_link_libraries(test_segpool PRIVATE Threads::Threads)
endif()
if(UNIX)
    target_link_libraries(test_segpool PRIVATE m)
endif()
target_include_directories(test_segpool PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../include
    ${CMAKE_CURRENT_SOURCE_DIR}/../src
)
add_test(NAME test_segpool COMMAND test_segpool)
set_tests_properties(test_segpool PROPERTIES
    PASS_REGULAR_EXPRESSION "ALL PASS")

# store→decoder 接线冒烟（M1，多格式矩阵）：对每个传入样本，SegStore 整曲
# 预填 → AVIO → decoder_open_mem，与磁盘 decoder_open 对拍帧数/采样率/声道/时长。
# fixture = 各封装/编码格式样本（flac/wav+mp3/opus/ogg）。
# segstore.c 已并入 audio_engine_static 主库（M2），测试不再单独编译。
add_executable(test_store_decode test_store_decode.c
)
target_link_libraries(test_store_decode PRIVATE audio_engine_static)
if(TARGET Threads::Threads)
    target_link_libraries(test_store_decode PRIVATE Threads::Threads)
endif()
if(UNIX)
    target_link_libraries(test_store_decode PRIVATE m)
endif()
target_include_directories(test_store_decode PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../include
    ${CMAKE_CURRENT_SOURCE_DIR}/../src
)
add_test(NAME test_store_decode
         COMMAND test_store_decode
                 ${CMAKE_CURRENT_SOURCE_DIR}/native_seek_fixture.flac
                 ${CMAKE_CURRENT_SOURCE_DIR}/../samples/aac/t48_m.wav
                 ${CMAKE_CURRENT_SOURCE_DIR}/../kernel/fmt/mp3/samples/noxing.mp3
                 ${CMAKE_CURRENT_SOURCE_DIR}/../kernel/fmt/opus/samples/tiny.opus
                 ${CMAKE_CURRENT_SOURCE_DIR}/../kernel/fmt/vorbis/tiny.ogg)
set_tests_properties(test_store_decode PROPERTIES
    PASS_REGULAR_EXPRESSION "ALL PASS")

# store→pipeline 冒烟（M1.5，docs/audio-memory-source.md §7）：同 fixture 预填
# SegStore → pipeline_create_store 走完整 DSP 链，与磁盘 pipeline_create 对拍
# pcm 流出帧数/采样率/声道。tempo.c 以无 HAS_TEMPO 的 stub 链接（pipeline 拉 tempo
# 符号，与 test_native_seek 同法）；segstore.c 来自 audio_engine_static 主库（M2）。
add_executable(test_store_pipeline test_store_pipeline.c
    ${CMAKE_CURRENT_SOURCE_DIR}/../src/tempo.c
)
target_link_libraries(test_store_pipeline PRIVATE audio_engine_static)
if(TARGET Threads::Threads)
    target_link_libraries(test_store_pipeline PRIVATE Threads::Threads)
endif()
if(UNIX)
    target_link_libraries(test_store_pipeline PRIVATE m)
endif()
target_include_directories(test_store_pipeline PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../include
    ${CMAKE_CURRENT_SOURCE_DIR}/../src
)
add_test(NAME test_store_pipeline
         COMMAND test_store_pipeline
                 ${CMAKE_CURRENT_SOURCE_DIR}/native_seek_fixture.flac)
set_tests_properties(test_store_pipeline PROPERTIES
    PASS_REGULAR_EXPRESSION "ALL PASS")

# EraAudio 纯内存源解码冒烟（docs/audio-memory-source.md §7）：fixture 连续内存 →
# native_decoder_open_mem → 与路径后端对拍帧数/采样率/声道。证明自研内核已接入
# 「纯内存源」，不再一律回退 FFmpeg。
add_executable(test_era_mem test_era_mem.c)
target_link_libraries(test_era_mem PRIVATE audio_engine_static)
if(TARGET Threads::Threads)
    target_link_libraries(test_era_mem PRIVATE Threads::Threads)
endif()
if(UNIX)
    target_link_libraries(test_era_mem PRIVATE m)
endif()
target_include_directories(test_era_mem PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../include
    ${CMAKE_CURRENT_SOURCE_DIR}/../src
)
add_test(NAME test_era_mem
         COMMAND test_era_mem
                 ${CMAKE_CURRENT_SOURCE_DIR}/native_seek_fixture.flac)
set_tests_properties(test_era_mem PROPERTIES
    PASS_REGULAR_EXPRESSION "ALL PASS")

# 集成测试（需要输入文件的跳过 CTEST，仅通过手动运行）
# add_engine_test(test_pipeline test_pipeline.c)

# 常驻内核接入 seam（zk_engine_*，§7 async 主干）对照回归：加法式，不触碰
# mediaengine_lib/pipeline/player/纯内存路径。池内解码 == sync zk_decoder 逐样本。
find_package(Threads QUIET)
add_executable(test_engine_pool test_engine_pool.c)
target_link_libraries(test_engine_pool PRIVATE audio_engine_static)
if(TARGET Threads::Threads)
    target_link_libraries(test_engine_pool PRIVATE Threads::Threads)
endif()
if(UNIX)
    target_link_libraries(test_engine_pool PRIVATE m)
endif()
target_include_directories(test_engine_pool PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../include
    ${CMAKE_CURRENT_SOURCE_DIR}/../src
)
add_test(NAME test_engine_pool COMMAND test_engine_pool)
set_tests_properties(test_engine_pool PROPERTIES
    PASS_REGULAR_EXPRESSION "ALL PASS")

# S1 常驻内核池（zk_engine 流式 seam）接线回归（headless）：同一 fixture 跑两遍
# headless 内存模式引擎（ARCHOERA_MEMORY_HEADLESS、engine_mode=1、无设备）——
# 一遍 ARCHOERA_ERA_POOL=1（池路径）、一遍不设（默认 zk_decoder 参照），断言
# 整曲 PCM 逐位一致 + 池 gating 确实执行（stream_opens 计数）。同 test_memory_mode：
# 直接编译 mediaengine_lib.c + tempo.c stub。
add_executable(test_pool_pipeline test_pool_pipeline.c
    ${CMAKE_CURRENT_SOURCE_DIR}/../src/mediaengine_lib.c
    ${CMAKE_CURRENT_SOURCE_DIR}/../src/tempo.c
)
target_link_libraries(test_pool_pipeline PRIVATE audio_engine_static)
if(TARGET Threads::Threads)
    target_link_libraries(test_pool_pipeline PRIVATE Threads::Threads)
endif()
if(UNIX)
    target_link_libraries(test_pool_pipeline PRIVATE m)
endif()
target_include_directories(test_pool_pipeline PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../include
    ${CMAKE_CURRENT_SOURCE_DIR}/../src
)
add_test(NAME test_pool_pipeline
         COMMAND test_pool_pipeline
                 ${CMAKE_CURRENT_SOURCE_DIR}/native_seek_fixture.flac
                 ${CMAKE_CURRENT_SOURCE_DIR}/fallback_pcm.mov)
set_tests_properties(test_pool_pipeline PROPERTIES
    PASS_REGULAR_EXPRESSION "ALL PASS")

# 元数据快路径 C ABI（zk_metadata_*，§8.4.2①；无 JSON 直桥 scanner）：
# probe+open 一次取回标量/全量 tags/首张封面（不解码 PCM），句柄释放后指针失效。
# fixture = 带 PICTURE + 标签的 FLAC。
add_executable(test_metadata_abi test_metadata_abi.c)
target_link_libraries(test_metadata_abi PRIVATE audio_engine_static)
if(UNIX)
    target_link_libraries(test_metadata_abi PRIVATE m)
endif()
target_include_directories(test_metadata_abi PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../include
    ${CMAKE_CURRENT_SOURCE_DIR}/../src
)
add_test(NAME test_metadata_abi
         COMMAND test_metadata_abi
                 ${CMAKE_CURRENT_SOURCE_DIR}/tagged_fixture.flac)
set_tests_properties(test_metadata_abi PROPERTIES
    PASS_REGULAR_EXPRESSION "ALL PASS")

# 音频流「随机跳转」回归：池化流式会话播放中反复随机 seek，输出与整曲解码
# 参考对拍（corr≥0.999，无损逐位）。headless，无设备。
add_executable(test_random_seek test_random_seek.c)
target_link_libraries(test_random_seek PRIVATE audio_engine_static)
if(TARGET Threads::Threads)
    target_link_libraries(test_random_seek PRIVATE Threads::Threads)
endif()
if(UNIX)
    target_link_libraries(test_random_seek PRIVATE m)
endif()
target_include_directories(test_random_seek PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../include
    ${CMAKE_CURRENT_SOURCE_DIR}/../src
)
add_test(NAME test_random_seek
         COMMAND test_random_seek
                 ${CMAKE_CURRENT_SOURCE_DIR}/native_seek_fixture.flac 300 12345 0)
set_tests_properties(test_random_seek PROPERTIES
    PASS_REGULAR_EXPRESSION "ALL PASS")
add_test(NAME test_random_seek_mp3
         COMMAND test_random_seek
                 ${CMAKE_CURRENT_SOURCE_DIR}/../kernel/fmt/mp3/samples/noxing.mp3 300 777 0)
set_tests_properties(test_random_seek_mp3 PROPERTIES
    PASS_REGULAR_EXPRESSION "ALL PASS")

# 损坏文件 / 恶意越界 健壮性：截断、错误魔数、头部 fuzz-lite、恶意 seek
# （INT64 极值/负值/远超时长）——只允许返回错误/EOF，不得崩溃/挂起。
add_executable(test_malformed test_malformed.c)
target_link_libraries(test_malformed PRIVATE audio_engine_static)
if(TARGET Threads::Threads)
    target_link_libraries(test_malformed PRIVATE Threads::Threads)
endif()
if(UNIX)
    target_link_libraries(test_malformed PRIVATE m)
endif()
target_include_directories(test_malformed PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../include
    ${CMAKE_CURRENT_SOURCE_DIR}/../src
)
add_test(NAME test_malformed
         COMMAND test_malformed
                 ${CMAKE_CURRENT_SOURCE_DIR}/native_seek_fixture.flac
                 ${CMAKE_CURRENT_SOURCE_DIR}/../kernel/fmt/mp3/samples/noxing.mp3
                 ${CMAKE_CURRENT_SOURCE_DIR}/../samples/aac/t48_m.m4a)
set_tests_properties(test_malformed PROPERTIES
    PASS_REGULAR_EXPRESSION "ALL PASS")

# C-Bench 工具：常驻内核池并发/首帧基准（headless；不入 ctest，手动运行）
add_executable(bench_era_pool bench/bench_era_pool.c)
target_link_libraries(bench_era_pool PRIVATE audio_engine_static)
if(TARGET Threads::Threads)
    target_link_libraries(bench_era_pool PRIVATE Threads::Threads)
endif()
if(UNIX)
    target_link_libraries(bench_era_pool PRIVATE m)
endif()
target_include_directories(bench_era_pool PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../include
    ${CMAKE_CURRENT_SOURCE_DIR}/../src
)
