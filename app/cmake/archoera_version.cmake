# ArchoeraMusic — Windows VERSIONINFO 统一生成
# Copyright (C) 2026 Archoera && BetaStudio2
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# 所有自有 Windows PE（exe/dll）使用同一个制作者标识与版本来源：
#   - CompanyName / 安装器 AppPublisher：io.awa.archoera.betastudio2
#   - 版本：app/pubspec.yaml 的 `version: x.y.z+build`
#
# 用法（调用方项目目录需能通过 PUBSPEC 找到 app/pubspec.yaml）：
#   include("${CMAKE_CURRENT_SOURCE_DIR}/../../cmake/archoera_version.cmake")
#   archoera_configure_version_rc(
#     "${CMAKE_CURRENT_BINARY_DIR}/archoera_xxx.rc"
#     "${CMAKE_CURRENT_SOURCE_DIR}/../../pubspec.yaml"
#     "archoera_xxx.dll" "ArchoeraMusic xxx" "archoera_xxx" 2)
#   target_sources(archoera_xxx PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/archoera_xxx.rc")
#
# FILETYPE: 1 = EXE，2 = DLL。

set(ARCHOERA_COMPANY "io.awa.archoera.betastudio2")
set(ARCHOERA_PRODUCT "ArchoeraMusic")
set(ARCHOERA_COPYRIGHT "Copyright (C) 2026 io.awa.archoera.betastudio2")
set(ARCHOERA_HOMEPAGE "https://github.com/ArchoeraC/ArchoeraMusic")
set(ARCHOERA_VERSION_RC_TEMPLATE "${CMAKE_CURRENT_LIST_DIR}/archoera_version.rc.in")

function(archoera_configure_version_rc OUT_RC PUBSPEC ORIGINAL_FILENAME FILE_DESCRIPTION INTERNAL_NAME FILETYPE)
  # pubspec.yaml 变更时让 CMake 重新配置（否则只有 .rc 模板变更才刷新）。
  set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${PUBSPEC}")
  set(_line "version: 0.0.0+0")
  if(EXISTS "${PUBSPEC}")
    file(STRINGS "${PUBSPEC}" _version_lines REGEX "^version:")
    list(LENGTH _version_lines _count)
    if(_count GREATER 0)
      list(GET _version_lines 0 _line)
    endif()
  endif()

  string(REGEX MATCH "version:[ \t]*([0-9]+)\\.([0-9]+)\\.([0-9]+)(\\+([0-9]+))?" _match "${_line}")
  if(CMAKE_MATCH_1)
    set(_major "${CMAKE_MATCH_1}")
    set(_minor "${CMAKE_MATCH_2}")
    set(_patch "${CMAKE_MATCH_3}")
    if(CMAKE_MATCH_5)
      set(_build "${CMAKE_MATCH_5}")
    else()
      set(_build "0")
    endif()
  else()
    set(_major "0")
    set(_minor "0")
    set(_patch "0")
    set(_build "0")
  endif()

  set(ARCHOERA_VERSION_STRING "${_major}.${_minor}.${_patch}+${_build}")
  set(ARCHOERA_VERSION_COMMA "${_major},${_minor},${_patch},${_build}")
  set(ARCHOERA_ORIGINAL_FILENAME "${ORIGINAL_FILENAME}")
  set(ARCHOERA_FILE_DESCRIPTION "${FILE_DESCRIPTION}")
  set(ARCHOERA_INTERNAL_NAME "${INTERNAL_NAME}")
  set(ARCHOERA_FILETYPE "${FILETYPE}")

  configure_file("${ARCHOERA_VERSION_RC_TEMPLATE}" "${OUT_RC}" @ONLY)
endfunction()
