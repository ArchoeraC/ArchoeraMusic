# ArchoeraMusic
# Copyright (C) 2026 Archoera && BetaStudio2
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# archoera_scraper 依赖守卫：产物不得出现 libcurl / libssl / libcrypto 的
# DT_NEEDED。HTTP 由 scraper-crypto（reqwest + rustls）静态提供；一旦有人把
# 系统 curl/OpenSSL 加回来，这里会在构建期直接失败。

if(NOT EXISTS "${LIBRARY}")
  message(FATAL_ERROR "check_http_deps: 找不到产物 ${LIBRARY}")
endif()

execute_process(
  COMMAND "${READELF}" -d "${LIBRARY}"
  OUTPUT_VARIABLE _dyn
  ERROR_VARIABLE _err
  RESULT_VARIABLE _rc)
if(NOT _rc EQUAL 0)
  message(FATAL_ERROR "check_http_deps: readelf 失败: ${_err}")
endif()

string(REGEX MATCHALL "\\(NEEDED\\)[^[]*\\[([^]]+)\\]" _needed "${_dyn}")
foreach(_entry IN LISTS _needed)
  string(REGEX REPLACE ".*\\[([^]]+)\\]$" "\\1" _soname "${_entry}")
  if(_soname MATCHES "^lib(curl|ssl|crypto)\\.so")
    message(FATAL_ERROR
      "archoera_scraper 直接依赖 ${_soname}：HTTP 必须走 scraper-crypto（rustls），"
      "不得重新引入系统 libcurl/OpenSSL（发行版 soname 升级会让产物无法启动）。")
  endif()
endforeach()
