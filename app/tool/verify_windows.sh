#!/usr/bin/env bash
# =====================================================================
#  ArchoeraMusic 平台桥接 —— Windows 端本地编译验证（Linux 主机）
#
#  用 msvc-wine（MSVC cl.exe + Wine）编译并链接 Windows 桥接
#  （core.cpp / apl.cpp / backend_windows.cpp → archoera_platform.dll），
#  确认可通过 MSVC 编译与链接（能发现 LNK2019 之类的符号缺失）。
#  CI 仍在 Windows runner 原生构建。
#
#  依赖：
#    - msvc-wine：默认 /opt/msvc（可用 MSVC_INSTALL_DIR 指定）
#    - wine
#  可选：cppwinrt 头（存在则一并编译 WinRT/SMTC/Toast 分支；缺省自动降级）。
#
#  用法：
#    bash app/tool/verify_windows.sh
#    MSVC_INSTALL_DIR=/opt/msvc bash app/tool/verify_windows.sh
#
#  退出码：0 = 编译成功；非 0 = 失败。
# =====================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PLATFORM_DIR="$ROOT/app/native/platform"

MSVC_INSTALL_DIR="${MSVC_INSTALL_DIR:-/opt/msvc}"
CL_DIR="$MSVC_INSTALL_DIR/bin/x64"

[ -x "$CL_DIR/cl" ] || { echo "找不到 msvc-wine cl：$CL_DIR/cl（设 MSVC_INSTALL_DIR）" >&2; exit 1; }
command -v wine >/dev/null 2>&1 || { echo "缺少 wine" >&2; exit 1; }

# cppwinrt 头目录：优先 CPPWINRT_INCLUDE，其次 msvc-wine SDK 内自带。
CPPWINRT_INCLUDE="${CPPWINRT_INCLUDE:-}"
if [ -z "$CPPWINRT_INCLUDE" ]; then
  CPPWINRT_INCLUDE="$(find "$MSVC_INSTALL_DIR" -maxdepth 6 -type d -path '*Include*' -name cppwinrt 2>/dev/null | sort | tail -1 || true)"
fi

BUILD_DIR="${ARCHOERA_VERIFY_BUILD:-$(mktemp -d /tmp/archoera-win-verify.XXXXXX)}"
mkdir -p "$BUILD_DIR"

export PATH="$CL_DIR:$PATH"
export WINEDEBUG="${WINEDEBUG:--all}"

echo "msvc-wine : $CL_DIR"
echo "cppwinrt  : ${CPPWINRT_INCLUDE:-<无（WinRT 分支自动降级）>}"
echo "OUT       : $BUILD_DIR"
echo

# 项目同款标志（见 app/native/platform/CMakeLists.txt）：/utf-8 必需——
# 否则 MSVC 在 936 代码页下会把 UTF-8 中文注释解析错乱（C4819）。
incs=(-I "$PLATFORM_DIR/include" -I "$PLATFORM_DIR/src")
if [ -n "$CPPWINRT_INCLUDE" ]; then incs+=("-I$CPPWINRT_INCLUDE"); fi

set +e
cl /nologo /std:c++20 /EHsc /O2 /W3 /permissive- /Zc:__cplusplus /utf-8 \
   /DARCHOERA_PLATFORM_BUILD "${incs[@]}" \
   /LD \
   "$PLATFORM_DIR/src/core.cpp" \
   "$PLATFORM_DIR/src/apl.cpp" \
   "$PLATFORM_DIR/src/backend_windows.cpp" \
   "/Fe$BUILD_DIR/archoera_platform.dll" \
   /link user32.lib powrprof.lib advapi32.lib dwmapi.lib windowsapp.lib \
         shell32.lib shlwapi.lib propsys.lib ole32.lib uuid.lib
rc=$?
set -e

echo
if [ $rc -eq 0 ]; then
  echo "✅ Windows 端编译+链接通过"
  ls -l "$BUILD_DIR"/archoera_platform.*
else
  echo "❌ Windows 端编译/链接失败" >&2
fi
exit $rc
