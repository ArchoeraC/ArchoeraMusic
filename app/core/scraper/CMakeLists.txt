cmake_minimum_required(VERSION 3.16)
project(archoera-scraper CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# ---------- 依赖 ----------
find_package(CURL REQUIRED)
find_package(OpenSSL REQUIRED)  # HTTPS + SHA1
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

# ---------- 编译选项 ----------
if(MSVC)
    # MSVC 不接受 -Wall/-Wextra 等 GCC 风格参数（D8021: invalid numeric argument）
    add_compile_options(/W3)
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

target_link_libraries(archoera_scraper PRIVATE
    CURL::libcurl
    OpenSSL::Crypto
    nlohmann_json::nlohmann_json
    Taglib::tag
)
if(SQLITE3_TARGET)
    target_link_libraries(archoera_scraper PRIVATE ${SQLITE3_TARGET})
else()
    # 无 IMPORTED target：直接用 find_package 探测到的库/头路径
    target_link_libraries(archoera_scraper PRIVATE ${SQLite3_LIBRARIES})
    target_include_directories(archoera_scraper PRIVATE ${SQLite3_INCLUDE_DIRS})
endif()

# 安装目标
install(TARGETS archoera_scraper LIBRARY DESTINATION lib)
