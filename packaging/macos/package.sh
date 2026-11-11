#!/usr/bin/env bash
# =====================================================================
#  ArchoeraMusic macOS 打包脚本（CI 与本机均可用，仅能在 macOS 上运行）。
#
#  产物（均带版本号，供 GitHub Release 直接分发）：
#    dist/macos/ArchoeraMusic-<版本>-macos-<arm64|x64>.dmg
#        拖拽安装镜像：内含 ArchoeraMusic.app + 「应用程序」快捷方式（即 /Applications）。
#        未做 Developer ID 签名/公证（无付费证书），首次打开需右键「打开」，
#        镜像内附「首次打开说明.txt」。
#    dist/macos/ArchoeraMusic-<版本>-macos-<arm64|x64>.zip
#        ditto 生成的归档（保留 .app 的符号链接、可执行位与扩展属性），
#        跨平台解压可用；发布侧同时对两者签 .sig1。
#
#  用法: bash packaging/macos/package.sh <archoera_music.app> <版本> <arch>
#        arch ∈ arm64 | x64
#        （位置参数；不要写成 "dmg ..."，格式由本脚本固定为 DMG + zip）
#  环境: SKIP_DMG=1 仅生成 zip（无 hdiutil 或仅需校验时）
# =====================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
APP_NAME="ArchoeraMusic"
BUNDLE_ID="com.archoera.archoeraMusic"
DIST="$ROOT/dist/macos"
WORK="$ROOT/packaging/macos/work"

app="${1:?用法: package.sh <archoera_music.app> <版本> <arch>}"
version="${2:?缺少版本号}"
arch="${3:?缺少架构（arm64 / x64）}"

[[ "$(uname -s)" == "Darwin" ]] || {
  echo "错误: macOS 打包只能在 macOS 上执行（需要 hdiutil / ditto / xcrun）" >&2
  exit 2
}
[[ -d "$app" ]] || { echo "错误: 找不到 .app: $app" >&2; exit 1; }
app="$(cd "$(dirname "$app")" && pwd)/$(basename "$app")"
case "$arch" in
  arm64|x64) ;;
  *) echo "错误: 未知架构 $arch（只支持 arm64 / x64）" >&2; exit 1 ;;
esac

mkdir -p "$DIST"
rm -rf "$WORK"
mkdir -p "$WORK"

base="$DIST/${APP_NAME}-${version}-macos-${arch}"
rm -f "$base.dmg" "$base.zip" "$base.dmg.sig1" "$base.zip.sig1"

# ───────────────────────── zip（便携分发）─────────────────────────
# ditto -c -k --sequesterRsrc --keepParent：保留符号链接与可执行位，
# 等价 Finder「压缩」，在 Linux/Windows 上解压也不会丢 Frameworks 链接。
ditto -c -k --sequesterRsrc --keepParent "$app" "$base.zip"
echo "[macOS 打包] zip: $base.zip ($(du -h "$base.zip" | cut -f1))"

# ───────────────────────── dmg（拖拽安装）─────────────────────────
if [[ "${SKIP_DMG:-0}" == "1" ]]; then
  echo "[macOS 打包] SKIP_DMG=1，跳过 DMG"
  exit 0
fi
if ! command -v hdiutil >/dev/null 2>&1; then
  echo "警告: 未找到 hdiutil，跳过 DMG" >&2
  exit 0
fi

stage="$WORK/stage"
mkdir -p "$stage"
# ditto 而非 cp -R：保留 .app 内的符号链接（FlutterMacOS.framework）与资源分支
ditto "$app" "$stage/$APP_NAME.app"
ln -s /Applications "$stage/应用程序"

cat > "$stage/首次打开说明.txt" <<'NOTE'
ArchoeraMusic（macOS）首次打开说明
==================================

本版本未使用 Apple Developer ID 签名与公证（项目未购买付费证书），
macOS Gatekeeper 首次运行会提示「无法验证开发者」。

正确打开方式（任选其一）：
  1. 在「访达 → 应用程序」中右键（或按住 Control 点击）ArchoeraMusic，
     选择「打开」，随后在弹窗中再次点「打开」；
  2. 或打开「系统设置 → 隐私与安全性」，在页面底部点「仍要打开」。

首次打开成功一次后，之后双击即可正常运行。

说明：若终端提示「已损坏，无法打开」（多见于下载后带隔离属性），可执行：
  xattr -dr com.apple.quarantine /Applications/ArchoeraMusic.app

架构：请确认与你的 Mac 匹配（Apple 芯片选 arm64，Intel 选 x64）。

项目主页：https://github.com/ArchoeraC/ArchoeraMusic
NOTE

# DMG 卷标限制 27 字符左右，保持简短可读。
volume="${APP_NAME} ${version}"
rm -f "$base.dmg"
hdiutil create \
  -volname "$volume" \
  -srcfolder "$stage" \
  -ov -format UDZO -fs HFS+ \
  -quiet "$base.dmg"

# 快速校验：能挂载并读到 .app 主二进制。
mnt="$WORK/mnt"
mkdir -p "$mnt"
if hdiutil attach "$base.dmg" -nobrowse -readonly -mountpoint "$mnt" -quiet; then
  if [[ ! -x "$mnt/$APP_NAME.app/Contents/MacOS/archoera_music" ]]; then
    hdiutil detach "$mnt" -quiet || true
    rm -rf "$WORK" "$base.dmg"
    echo "错误: DMG 内缺少可执行文件 $APP_NAME.app/Contents/MacOS/archoera_music" >&2
    exit 1
  fi
  hdiutil detach "$mnt" -quiet || true
else
  rm -rf "$WORK" "$base.dmg"
  echo "错误: DMG 无法挂载（hdiutil attach 失败）" >&2
  exit 1
fi

# 记录 bundle id，便于下游核对（DMG 与 zip 都来自同一 .app）。
printf 'bundle-id=%s\nversion=%s\narch=%s\n' "$BUNDLE_ID" "$version" "$arch" \
  > "$base.info.txt"

rm -rf "$WORK"
echo "[macOS 打包] dmg: $base.dmg ($(du -h "$base.dmg" | cut -f1))"
