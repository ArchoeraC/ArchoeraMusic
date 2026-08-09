cmake_minimum_required(VERSION 3.16)
project(archoera-scraper CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# ---------- 依赖 ----------
find_package(CURL REQUIRED)
find_package(OpenSSL REQUIRED)  # HTTPS + SHA1
find_package(SQLite3 REQUIRED)  # scraper-state.db 直写
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
add_compile_options(-Wall -Wextra -Wpedantic)
if(CMAKE_BUILD_TYPE STREQUAL "Debug")
    add_compile_options(-g -O0)
else()
    add_compile_options(-O2)
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
    SQLite::SQLite3
    nlohmann_json::nlohmann_json
    Taglib::tag
)

# 安装目标
install(TARGETS archoera_scraper LIBRARY DESTINATION lib)
