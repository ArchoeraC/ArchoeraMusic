#!/usr/bin/env bash
# =====================================================================
#  ArchoeraMusic 启动冒烟（Linux bundle）
#
#  在临时 HOME / XDG 目录 + Xvfb 虚拟显示下启动发布包里的 archoera_music，
#  验证：
#    - 动态加载器能解析全部依赖（LD_BIND_NOW=1，缺失库/符号立刻失败）；
#    - 进程能实际进入事件循环并保持存活（不是启动即崩溃/退出）。
#
#  这是「发版后打不开」的最后一道闸：依赖守卫只做静态检查，这里实际跑一遍。
#
#  用法: smoke_start_linux.sh <bundle 目录 | 可执行文件>
#    - 目录：运行 <目录>/archoera_music（发布 bundle 布局）
#    - 文件：直接运行该可执行文件（如 AppImage）
#  环境:
#    ARCHOERA_SMOKE_SECONDS=15        存活秒数
#    ARCHOERA_SMOKE_ARGS=...          追加给可执行文件的参数（如 --appimage-extract-and-run）
#  依赖: xvfb（无 DISPLAY 时）、dbus-run-session（可选）
# =====================================================================
set -euo pipefail

target="${1:-}"
bin=""
if [[ -n "$target" && -d "$target" ]]; then
  bin="$(cd "$target" && pwd)/archoera_music"
elif [[ -n "$target" && -x "$target" ]]; then
  bin="$(cd "$(dirname "$target")" && pwd)/$(basename "$target")"
fi
if [[ -z "$bin" || ! -x "$bin" ]]; then
  echo "用法: $0 <bundle 目录 | 可执行文件>" >&2
  exit 2
fi

extra_args=()
if [[ -n "${ARCHOERA_SMOKE_ARGS:-}" ]]; then
  read -r -a extra_args <<<"$ARCHOERA_SMOKE_ARGS"
fi

seconds="${ARCHOERA_SMOKE_SECONDS:-15}"
if ! [[ "$seconds" =~ ^[0-9]+$ ]] || [[ "$seconds" -lt 3 ]]; then
  echo "错误: ARCHOERA_SMOKE_SECONDS 必须是 >=3 的整数" >&2
  exit 2
fi

command -v timeout >/dev/null 2>&1 || {
  echo "错误: 缺少 timeout（coreutils）" >&2
  exit 2
}

tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

mkdir -p "$tmp/home" "$tmp/data" "$tmp/config" "$tmp/cache" "$tmp/run"
chmod 700 "$tmp/run"

# 隔离用户数据：冒烟只测启动，不读写真实曲库/凭据/偏好。
export HOME="$tmp/home"
export XDG_DATA_HOME="$tmp/data"
export XDG_CONFIG_HOME="$tmp/config"
export XDG_CACHE_HOME="$tmp/cache"
export XDG_RUNTIME_DIR="$tmp/run"
export GDK_BACKEND=x11
export LIBGL_ALWAYS_SOFTWARE=1
export NO_AT_BRIDGE=1
# 立即解析所有动态符号：缺库/缺符号在启动阶段就暴露，而不是用到才崩。
export LD_BIND_NOW=1

launch=()
if [[ -z "${DISPLAY:-}" ]]; then
  if command -v xvfb-run >/dev/null 2>&1; then
    launch=(xvfb-run -a -s "-screen 0 1280x800x24")
  else
    echo "错误: 无 DISPLAY 且缺少 xvfb-run；请安装 xvfb 后重试" >&2
    exit 2
  fi
fi
if command -v dbus-run-session >/dev/null 2>&1; then
  launch=(dbus-run-session -- "${launch[@]}")
fi

log="$tmp/app.log"
set +e
timeout --signal=TERM --kill-after=5s "${seconds}s" \
  "${launch[@]}" "$bin" "${extra_args[@]}" >"$log" 2>&1
rc=$?
set -e

loader_error_re='error while loading shared libraries|cannot open shared object file|undefined symbol|symbol lookup error|GLIBCXX_[0-9.]+.*not found|GLIBC_[0-9.]+.*not found'
if grep -Eq "$loader_error_re" "$log"; then
  echo "启动冒烟失败：动态加载/符号解析错误" >&2
  grep -E "$loader_error_re" "$log" >&2 || true
  echo "--- 应用日志（尾部）---" >&2
  tail -80 "$log" >&2
  exit 1
fi

# timeout 主动结束（124）或 TERM 后仍存活被 KILL（137）都说明启动成功并进入事件循环。
if [[ $rc -eq 124 || $rc -eq 137 ]]; then
  echo "启动冒烟通过：archoera_music 在 ${seconds}s 内保持运行"
  exit 0
fi

echo "启动冒烟失败：进程提前退出（rc=$rc）" >&2
echo "--- 应用日志（尾部）---" >&2
tail -80 "$log" >&2
exit 1
