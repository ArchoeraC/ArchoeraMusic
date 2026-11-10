cmake_minimum_required(VERSION 3.16)
project(archoera-scraper CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# ---------- 依赖 ----------
find_package(CURL REQUIRED)
find_package(SQLite3 REQUIRED)  # scraper-state.db 直写
# SQLite target 命名跨环境不一致：
#   - CMake 标准 FindSQLite3（≥3.14）与新版 vcpkg：SQLite3::SQLite3
#   - vcpkg 旧命名：SQLite::SQLite3（已废弃但部分工具链仍提供）
#   - 旧版 FindSQLite3 / 部分发行版：不定义 target，仅提供变量
if(TARGET SQLite3::SQLite3)
    set(SQLITE3_TARGET SQLite3::SQLite3)
elseif(TARGET SQLite::SQLite3)
    set(SQLITE3_TARGET SQLite::SQLite3)
else()
    set(SQLITE3_TARGET "")
endif()
# Taglib：优先 Config 模式（Arch Linux 自带 taglib-config.cmake）
# 失败后回退 FindTaglib.cmake（pkg-config 检测，适用 Alpine）
find_package(TagLib CONFIG QUIET)
if(NOT TARGET TagLib::tag)
    find_package(Taglib CONFIG QUIET)
endif()

if(TARGET TagLib::tag AND NOT TARGET Taglib::tag)
    add_library(Taglib::tag ALIAS TagLib::tag)
elseif(TARGET taglib::tag AND NOT TARGET Taglib::tag)
    add_library(Taglib::tag ALIAS taglib::tag)
endif()

if(NOT TARGET Taglib::tag)
    list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")
    find_package(Taglib REQUIRED)
endif()

# nlohmann/json：header-only，优先用系统包，否则 fetch（镜像可覆盖，如 GitHub Actions 传 -DNLOHMANN_JSON_REPO）
find_package(nlohmann_json 3.10.0 QUIET)
if(NOT nlohmann_json_FOUND)
    message(STATUS "nlohmann_json 未找到，从镜像仓库获取")
    set(NLOHMANN_JSON_REPO "https://gitee.com/mirrors/nlohmann-json.git" CACHE STRING "nlohmann/json git 镜像地址")
    include(FetchContent)
    FetchContent_Declare(
        nlohmann_json
        GIT_REPOSITORY ${NLOHMANN_JSON_REPO}
        GIT_TAG v3.11.3
        GIT_SHALLOW TRUE
    )
    FetchContent_MakeAvailable(nlohmann_json)
endif()

# ---------- Rust 加密后端（替代 OpenSSL::Crypto）----------
# AES / RSA 模幂 / MD5 / SHA1 / 随机数由 app/core/scraper-crypto（纯 Rust
# staticlib）提供，静态合并进 archoera_scraper；运行期不再依赖系统 libcrypto，
# 发行版 OpenSSL soname 升级（如 libcrypto.so.3 → .so.4）不影响已发布二进制。
find_program(CARGO_EXECUTABLE cargo REQUIRED)
set(SCRAPER_CRYPTO_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../scraper-crypto")
file(GLOB_RECURSE SCRAPER_CRYPTO_SOURCES CONFIGURE_DEPENDS
    "${SCRAPER_CRYPTO_DIR}/src/*.rs")
set(SCRAPER_CRYPTO_DEPENDS
    "${SCRAPER_CRYPTO_DIR}/Cargo.toml"
    "${SCRAPER_CRYPTO_DIR}/Cargo.lock"
    ${SCRAPER_CRYPTO_SOURCES})

if(CMAKE_BUILD_TYPE MATCHES "Debug")
    set(SCRAPER_CRYPTO_PROFILE "debug")
    set(SCRAPER_CRYPTO_CARGO_FLAGS "")
else()
    # VS 多配置生成器 CMAKE_BUILD_TYPE 为空；桌面发布一律按 Release。
    set(SCRAPER_CRYPTO_PROFILE "release")
    set(SCRAPER_CRYPTO_CARGO_FLAGS "--release")
endif()

if(WIN32)
    set(SCRAPER_CRYPTO_LIB_NAME "archoera_scraper_crypto.lib")
else()
    set(SCRAPER_CRYPTO_LIB_NAME "libarchoera_scraper_crypto.a")
endif()

# macOS 按 CMAKE_OSX_ARCHITECTURES 逐架构编译（build-macos.sh 传单架构），
# 多架构时 lipo 成 fat 库；其它平台按宿主 target 编译。
set(SCRAPER_CRYPTO_TARGETS "")
set(SCRAPER_CRYPTO_LIBS "")
if(APPLE AND CMAKE_OSX_ARCHITECTURES)
    foreach(_arch ${CMAKE_OSX_ARCHITECTURES})
        if(_arch STREQUAL "arm64")
            set(_triple aarch64-apple-darwin)
        elseif(_arch STREQUAL "x86_64")
            set(_triple x86_64-apple-darwin)
        else()
            message(FATAL_ERROR "scraper-crypto: 不支持的 macOS 架构 ${_arch}")
        endif()
        list(APPEND SCRAPER_CRYPTO_TARGETS "${_triple}")
    endforeach()
else()
    list(APPEND SCRAPER_CRYPTO_TARGETS "host")
endif()

foreach(_triple ${SCRAPER_CRYPTO_TARGETS})
    if(_triple STREQUAL "host")
        set(_crypto_dir "${SCRAPER_CRYPTO_DIR}/target/${SCRAPER_CRYPTO_PROFILE}")
        set(_cargo_target_args "")
        set(_label "host")
    else()
        set(_crypto_dir "${SCRAPER_CRYPTO_DIR}/target/${_triple}/${SCRAPER_CRYPTO_PROFILE}")
        set(_cargo_target_args --target "${_triple}")
        set(_label "${_triple}")
    endif()
    set(_lib "${_crypto_dir}/${SCRAPER_CRYPTO_LIB_NAME}")
    add_custom_command(
        OUTPUT "${_lib}"
        COMMAND "${CARGO_EXECUTABLE}" build ${SCRAPER_CRYPTO_CARGO_FLAGS}
                ${_cargo_target_args}
        WORKING_DIRECTORY "${SCRAPER_CRYPTO_DIR}"
        DEPENDS ${SCRAPER_CRYPTO_DEPENDS}
        COMMENT "cargo build archoera-scraper-crypto (${_label})"
        VERBATIM)
    list(APPEND SCRAPER_CRYPTO_LIBS "${_lib}")
endforeach()

list(LENGTH SCRAPER_CRYPTO_LIBS _crypto_lib_count)
if(_crypto_lib_count GREATER 1)
    set(SCRAPER_CRYPTO_LIB
        "${SCRAPER_CRYPTO_DIR}/target/universal/${SCRAPER_CRYPTO_PROFILE}/${SCRAPER_CRYPTO_LIB_NAME}")
    add_custom_command(
        OUTPUT "${SCRAPER_CRYPTO_LIB}"
        COMMAND lipo -create ${SCRAPER_CRYPTO_LIBS} -output "${SCRAPER_CRYPTO_LIB}"
        DEPENDS ${SCRAPER_CRYPTO_LIBS}
        COMMENT "lipo archoera-scraper-crypto"
        VERBATIM)
else()
    list(GET SCRAPER_CRYPTO_LIBS 0 SCRAPER_CRYPTO_LIB)
endif()

add_custom_target(scraper_crypto ALL DEPENDS "${SCRAPER_CRYPTO_LIB}")

# ---------- 编译选项 ----------
if(MSVC)
    # MSVC 不接受 -Wall/-Wextra 等 GCC 风格参数（D8021: invalid numeric argument）
    add_compile_options(/W3)
    # 源码为无 BOM 的 UTF-8，含中文字符串字面量：须显式声明 UTF-8，否则非 UTF-8
    # 代码页环境下 MSVC 报 C2001（与 app/native/platform、app/native/log 一致）。
    add_compile_options(/utf-8)
    # MSVC 更严格的检查导致的已知无害警告：
    #   C4267: size_t → int 截断（FFI 长度参数，值域远小于 2^31）
    #   C4996: getenv/popen 等 MSVC 视为 unsafe 的 CRT 函数（沿用 POSIX 名，功能正确）
    #   C4190: extern "C" 返回 std::string（跨平台 FFI 既有设计，Dart 侧按 C ABI 消费）
    add_compile_options(/wd4267 /wd4996 /wd4190)
else()
    add_compile_options(-Wall -Wextra -Wpedantic)
    if(CMAKE_BUILD_TYPE STREQUAL "Debug")
        add_compile_options(-g -O0)
    else()
        add_compile_options(-O2)
    endif()
endif()

# ---------- FFI 共享库 ----------
# 桌面端经 Dart FFI 直连（非进程 spawn、非本地端口、非 stdin/stdout）：
# 引擎在库内独立 pthread 执行，状态事件经事件队列 poll_event 轮询。
add_library(archoera_scraper SHARED
    src/scraper_lib.cpp
)

target_include_directories(archoera_scraper PRIVATE include)

# Windows VERSIONINFO（统一制作者 / 版本号）。
if(WIN32)
    enable_language(RC)
    include("${CMAKE_CURRENT_SOURCE_DIR}/../../cmake/archoera_version.cmake")
    archoera_configure_version_rc(
        "${CMAKE_CURRENT_BINARY_DIR}/archoera_scraper.rc"
        "${CMAKE_CURRENT_SOURCE_DIR}/../../pubspec.yaml"
        "archoera_scraper.dll"
        "ArchoeraMusic metadata scraper"
        "archoera_scraper"
        2)
    target_sources(archoera_scraper PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/archoera_scraper.rc")
endif()

target_link_libraries(archoera_scraper PRIVATE
    CURL::libcurl
    "${SCRAPER_CRYPTO_LIB}"
    nlohmann_json::nlohmann_json
    Taglib::tag
)
add_dependencies(archoera_scraper scraper_crypto)

# Rust staticlib 的系统依赖（std / getrandom / num-bigint）。
if(WIN32)
    target_link_libraries(archoera_scraper PRIVATE
        bcrypt advapi32 userenv ntdll ws2_32)
elseif(APPLE)
    # Rust std 在 macOS 上依赖 libiconv（CMake 3.16 的 find_library 无 REQUIRED）。
    find_library(ICONV_LIBRARY iconv)
    if(NOT ICONV_LIBRARY)
        message(FATAL_ERROR "scraper-crypto: macOS 上未找到 iconv（Rust std 依赖）")
    endif()
    target_link_libraries(archoera_scraper PRIVATE "${ICONV_LIBRARY}")
else()
    target_link_libraries(archoera_scraper PRIVATE pthread dl m)
    # 隐藏静态库（Rust std / crates）的导出符号，避免 .so 动态符号表膨胀，
    # 也避免与进程内其它 Rust 库发生符号插入。scraper 自己的 C++ 符号不受影响。
    target_link_options(archoera_scraper PRIVATE "LINKER:--exclude-libs,ALL")
endif()
if(SQLITE3_TARGET)
    target_link_libraries(archoera_scraper PRIVATE ${SQLITE3_TARGET})
else()
    # 无 IMPORTED target：直接用 find_package 探测到的库/头路径
    target_link_libraries(archoera_scraper PRIVATE ${SQLite3_LIBRARIES})
    target_include_directories(archoera_scraper PRIVATE ${SQLite3_INCLUDE_DIRS})
endif()

# 安装目标
install(TARGETS archoera_scraper LIBRARY DESTINATION lib)

# ---------- 单元测试 ----------
# wait_event 事件驱动契约测试：真实句柄验证阻塞/唤醒/超时/销毁唤醒/
# 多次 create-destroy（对齐 audio-engine tests/test_mediaengine_wait.c）。
# 仅 POSIX（测试用 pthread）；链接共享库本体的导出符号。
enable_testing()
if(NOT WIN32)
    enable_language(C)
    find_package(Threads QUIET)
    add_executable(test_scraper_wait tests/test_scraper_wait.c)
    target_link_libraries(test_scraper_wait PRIVATE archoera_scraper)
    if(TARGET Threads::Threads)
        target_link_libraries(test_scraper_wait PRIVATE Threads::Threads)
    endif()
    add_test(NAME test_scraper_wait COMMAND test_scraper_wait)

    # 内置广告清洗单测（header-only，直接编译源文件即可）。
    add_executable(test_sanitize tests/test_sanitize.cpp)
    target_include_directories(test_sanitize PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include)
    add_test(NAME test_sanitize COMMAND test_sanitize)

    # Rust 加密后端 C ABI 契约（AES/RSA/摘要/随机数固定向量）。
    # 直接链 staticlib：共享库已隐藏静态库符号（--exclude-libs,ALL）。
    add_executable(test_crypto tests/test_crypto.cpp)
    target_include_directories(test_crypto PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include)
    target_link_libraries(test_crypto PRIVATE "${SCRAPER_CRYPTO_LIB}")
    add_dependencies(test_crypto scraper_crypto)
    if(APPLE)
        target_link_libraries(test_crypto PRIVATE "${ICONV_LIBRARY}")
    else()
        target_link_libraries(test_crypto PRIVATE pthread dl m)
    endif()
    add_test(NAME test_crypto COMMAND test_crypto)
endif()
