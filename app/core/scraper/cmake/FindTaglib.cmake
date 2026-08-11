# FindTaglib.cmake — 通过 pkg-config 查找 Taglib（回退方案）
#
# 当系统 taglib 不提供 TaglibConfig.cmake（如 Alpine 3.19 taglib 1.13）时，
# CMake 会回退到此模块，通过 pkg-config 获取编译和链接参数。
#
# 导出目标: Taglib::tag
#
# 用法:
#   find_package(Taglib REQUIRED)
#   target_link_libraries(target PRIVATE Taglib::tag)

#[=======================================================================[.rst:
FindTaglib
----------

Finds the Taglib library using pkg-config as fallback.

Imported Targets
^^^^^^^^^^^^^^^^

This module defines the following :prop_tgt:`IMPORTED` targets:

``Taglib::tag``
  The Taglib library, if found.

Result Variables
^^^^^^^^^^^^^^^^

``Taglib_FOUND``
  True if Taglib was found.
``Taglib_VERSION``
  The version of Taglib found.
``Taglib_INCLUDE_DIRS``
  Include directories for Taglib.
``Taglib_LIBRARIES``
  Libraries to link against.

#]=======================================================================]

# Try config mode first (taglib 2.x provides TaglibConfig.cmake)
if(NOT TARGET Taglib::tag)
    find_package(PkgConfig QUIET)
    if(PkgConfig_FOUND)
        pkg_check_modules(PC_Taglib QUIET taglib)
        if(PC_Taglib_FOUND)
            set(Taglib_VERSION "${PC_Taglib_VERSION}")
            set(Taglib_INCLUDE_DIRS "${PC_Taglib_INCLUDE_DIRS}")
            set(Taglib_LIBRARIES "${PC_Taglib_LIBRARIES}")
        endif()
    endif()

    # 查找头文件（确认实际路径，即使 pkg-config 失败也尝试默认路径）
    find_path(Taglib_INCLUDE_DIR
        NAMES tag.h
        PATHS ${PC_Taglib_INCLUDE_DIRS}
        PATH_SUFFIXES taglib
    )

    # 查找库文件
    find_library(Taglib_LIBRARY
        NAMES tag tag_c
        PATHS ${PC_Taglib_LIBRARY_DIRS}
    )

    if(Taglib_INCLUDE_DIR AND Taglib_LIBRARY)
        set(Taglib_INCLUDE_DIRS "${Taglib_INCLUDE_DIR}")
        set(Taglib_LIBRARIES "${Taglib_LIBRARY}")

        if(NOT TARGET Taglib::tag)
            add_library(Taglib::tag UNKNOWN IMPORTED)
            set_target_properties(Taglib::tag PROPERTIES
                IMPORTED_LOCATION "${Taglib_LIBRARY}"
                INTERFACE_INCLUDE_DIRECTORIES "${Taglib_INCLUDE_DIR}"
            )
        endif()

        set(Taglib_FOUND TRUE)
        if(NOT Taglib_FIND_QUIETLY)
            message(STATUS "Found Taglib: ${Taglib_LIBRARY} (version ${Taglib_VERSION})")
        endif()
    endif()
endif()

# 给 CMake 提供 fallback 诊断信息
if(NOT TARGET Taglib::tag)
    if(NOT Taglib_FIND_QUIETLY)
        message(STATUS "Taglib not found via pkg-config either. "
                       "Install taglib development package:\n"
                       "  Alpine: apk add taglib-dev\n"
                       "  Arch:   pacman -S taglib\n"
                       "  Debian: apt install libtag1-dev\n"
                       "  macOS:  brew install taglib")
    endif()
    if(Taglib_FIND_REQUIRED)
        message(FATAL_ERROR "Could NOT find Taglib (required)")
    endif()
endif()

mark_as_advanced(Taglib_INCLUDE_DIR Taglib_LIBRARY)
