#!/usr/bin/env bash
# =====================================================================
#  ArchoeraMusic macOS 发布打包（**macOS 专用**，从零到发布资产一条龙）
#
#  设计原则：macOS 有自己的工具链 / 架构 / 签名语义，不与 Linux 脚本混用，
#  也不依赖 CI 里的内联 bash 片段。本脚本只允许在 macOS 上运行，只使用
#  macOS 自带工具（Xcode CLT 的 otool / install_name_tool / codesign /
#  lipo / hdiutil / ditto / xcrun）与 Homebrew 的 dylibbundler。
#
#  shell：macOS 自带 /bin/bash 永远是 3.2（Apple 因 GPLv3 不升级），因此
#  本脚本只用 3.2 语法：无 mapfile / 关联数组 / ${v^^}，且不在 set -u 下
#  展开可能为空的数组。CI 里也显式用 bash（= /bin/bash 3.2）执行。
#
#  步骤：
#    bundle    .app 组装：拷入 native/、dylibbundler 收拢 FFmpeg/TagLib、
#              install_name 归一化为 @loader_path、许可文本、公钥、ad-hoc 重签、
#              生成原生完整性清单
#    verify    依赖守卫（架构单一 / 无构建机绝对路径 / 无 OpenSSL·libcurl /
#              @loader_path·@rpath 可解析 / 清单齐全）+ dyld 实际 dlopen 每个
#              FFI 库 + `archoerashell --version`
#    package   DMG（拖拽安装，含「应用程序」链接与首次打开说明）+ zip（ditto）
#    all       bundle → verify → package；**任一步失败即整体失败**
#
#  注意：不使用 `do_bundle; do_verify; do_package` 这种分号序列——最后一条
#  命令的退出码会掩盖前面步骤的失败。
#
#  用法:
#    bash packaging/macos/build-release.sh bundle  --arch arm64 [--app <path>]
#    bash packaging/macos/build-release.sh verify  --arch x86_64 [--app <path>]
#    bash packaging/macos/build-release.sh package --arch arm64 [--version 1.0.6]
#    bash packaging/macos/build-release.sh all     --arch arm64
#
#  环境:
#    ARCH --app <path>   .app 路径（默认 Flutter Release 输出）
#    --version <ver>     版本号（默认取 app/pubspec.yaml 主版本段）
#    SKIP_DMG=1          package 阶段只出 zip
#    ARCHOERA_SKIP_DLOPEN=1  verify 跳过 dyld 实际加载（仅静态检查）
#
#  退出码: 0 成功；1 检查/打包失败；2 用法错误或不在 macOS 上。
# =====================================================================
set -euo pipefail

APP_NAME="ArchoeraMusic"
BIN="archoera_music"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "错误: 本脚本只能在 macOS 上运行（需要 otool / codesign / hdiutil 等）" >&2
  exit 2
fi

# packaging/macos/ → 仓库根
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

usage() {
  sed -n '/^#  用法:/,/^#  环境:/p' "${BASH_SOURCE[0]}" | sed 's/^#  \{0,2\}//'
  exit 2
}

step="${1:-}"
[ -n "$step" ] || usage
shift

app=""
arch=""
version=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --app) [ "$#" -ge 2 ] || usage; app="$2"; shift 2 ;;
    --arch) [ "$#" -ge 2 ] || usage; arch="$2"; shift 2 ;;
    --version) [ "$#" -ge 2 ] || usage; version="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "未知参数: $1" >&2; usage ;;
  esac
done

[ -n "$app" ] || app="$ROOT/app/build/macos/Build/Products/Release/$BIN.app"

default_arch() {
  case "$(uname -m)" in
    arm64) echo "arm64" ;;
    x86_64) echo "x86_64" ;;
    *) echo "arm64" ;;
  esac
}
[ -n "$arch" ] || arch="$(default_arch)"
case "$arch" in
  arm64|x86_64) ;;
  *) echo "错误: --arch 只支持 arm64 / x86_64（收到 $arch）" >&2; exit 2 ;;
esac

if [ -z "$version" ]; then
  version="$(grep '^version:' "$ROOT/app/pubspec.yaml" | awk '{print $2}' | cut -d+ -f1)"
fi

log() { echo "[macos] $*"; }
die() { echo "::error::$*" >&2; exit 1; }

require_tools() {
  missing=""
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
  done
  [ -z "$missing" ] || die "缺少工具:$missing（Xcode Command Line Tools / Homebrew）"
}

# 单一架构名（arm64 / x86_64）；非单架构时原样返回（供报错展示）。
macho_arch() {
  got="$(lipo -archs "$1" 2>/dev/null || true)"
  if [ -z "$got" ]; then
    # lipo 不可用时退回 file(1)
    desc="$(file -b "$1" 2>/dev/null || true)"
    case "$desc" in
      *universal*|*"fat file"*) got="universal" ;;
      *arm64*) got="arm64" ;;
      *x86_64*) got="x86_64" ;;
    esac
  fi
  printf '%s' "$got"
}

app_paths() {
  native="$app/Contents/native"
  exe="$app/Contents/MacOS/$BIN"
}

# ─────────────────── install_name 归一化（内置）───────────────────
# dylibbundler 只处理 -x 指定的库；downloader / transcoder / log / platform /
# scanner / indexer 等模块的 install_name 仍带构建机路径，用户机加载必失败。
# 统一把 LC_ID_DYLIB 与同目录可解析的 LC_LOAD_DYLIB 改写为 @loader_path/<name>。
normalize_loadpaths() {
  native_dir="$1"
  nerrors=0
  nchanged=0

  is_build_path() {
    case "$1" in
      @*) return 1 ;;
      /usr/lib/* | /System/Library/* | /System/iOSSupport/* | /bin/*) return 1 ;;
      /*) return 0 ;;
      *) return 1 ;;
    esac
  }

  for dylib in "$native_dir"/*.dylib; do
    [ -e "$dylib" ] || continue
    file -b "$dylib" 2>/dev/null | grep -q 'Mach-O' || continue
    base="$(basename "$dylib")"

    cur_id="$(otool -D "$dylib" 2>/dev/null | tail -n +2 | head -1 || true)"
    want_id="@loader_path/$base"
    if [ -n "$cur_id" ] && [ "$cur_id" != "$want_id" ]; then
      case "$cur_id" in
        @rpath/* | @executable_path/* | /*)
          if is_build_path "$cur_id" || [ "${cur_id#@rpath/}" != "$cur_id" ] || [ "${cur_id#@executable_path/}" != "$cur_id" ]; then
            install_name_tool -id "$want_id" "$dylib"
            echo "  id   $base: $cur_id → $want_id"
            nchanged=$((nchanged + 1))
          fi
          ;;
      esac
    fi

    while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      [ "$ref" = "$cur_id" ] && continue
      case "$ref" in
        @loader_path/* | @executable_path/*) continue ;;
        /usr/lib/* | /System/Library/* | /System/iOSSupport/*) continue ;;
      esac

      dep_base="$(basename "$ref")"
      if is_build_path "$ref"; then
        if [ -e "$native_dir/$dep_base" ]; then
          install_name_tool -change "$ref" "@loader_path/$dep_base" "$dylib"
          echo "  dep  $base: $ref → @loader_path/$dep_base"
          nchanged=$((nchanged + 1))
        else
          echo "::error::$base: 依赖 $ref 不在 native/ 内（需先 dylibbundler 收拢或补内嵌）" >&2
          nerrors=$((nerrors + 1))
        fi
        continue
      fi

      if [ "${ref#@}" = "$ref" ] && [ -e "$native_dir/$dep_base" ]; then
        install_name_tool -change "$ref" "@loader_path/$dep_base" "$dylib"
        echo "  dep  $base: $ref → @loader_path/$dep_base"
        nchanged=$((nchanged + 1))
      fi
    done < <(otool -L "$dylib" 2>/dev/null | tail -n +2 | awk '{print $1}')
  done

  [ "$nerrors" -eq 0 ] || die "install_name 归一化失败：$nerrors 项错误"
  log "install_name 归一化完成：$nchanged 处改写"
}

# ──────────────────── Mach-O 依赖守卫（内置）────────────────────
# 1) 每个 LC_LOAD_DYLIB 必须是系统库 / @loader_path·@executable_path 相对路径
#    （且目标存在）/ 同目录内嵌库 / 自身 install_name；
# 2) 禁止构建机绝对路径（/Users/…、/opt/homebrew/…、/usr/local/…）；
# 3) 禁止包内出现 libssl/libcrypto/libcurl（含 libcrypto.N.dylib 改名副本）；
# 4) @rpath 必须能解析到包内；5) native/ 下每个 Mach-O 只允许目标架构；
# 6) 关键文件齐全且原生清单覆盖全部 dylib。
verify_deps() {
  app="$(cd "$(dirname "$app")" && pwd)/$(basename "$app")"
  app_paths
  errors=0
  system_refs=()

  fail() {
    echo "::error::$*" >&2
    errors=$((errors + 1))
  }
  is_macho() { file -b "$1" 2>/dev/null | grep -q 'Mach-O'; }
  is_system_path() {
    case "$1" in
      /usr/lib/* | /System/Library/* | /System/iOSSupport/* | /bin/*) return 0 ;;
      *) return 1 ;;
    esac
  }
  is_build_path() {
    case "$1" in
      @*) return 1 ;;
      /*) return 0 ;;
      *) return 1 ;;
    esac
  }
  is_forbidden() {
    case "$(basename "$1")" in
      libssl* | libcrypto* | libcurl*) return 0 ;;
      *) return 1 ;;
    esac
  }
  macho_arch() {
    got="$(lipo -archs "$1" 2>/dev/null || true)"
    if [ -z "$got" ]; then
      desc="$(file -b "$1" 2>/dev/null || true)"
      case "$desc" in
        *universal* | *"fat file"*) got="universal" ;;
        *arm64*) got="arm64" ;;
        *x86_64*) got="x86_64" ;;
      esac
    fi
    printf '%s' "$got"
  }
  id_name() { otool -D "$1" 2>/dev/null | tail -n +2 | head -1; }
  rpaths_of() {
    otool -l "$1" 2>/dev/null | awk '
      /cmd LC_RPATH/ { want=1; next }
      want && /path / { print $2; want=0 }'
  }
  resolve_refs() {
    rdir="$1"
    rref="$2"
    robj="$3"
    case "$rref" in
      @loader_path/*) printf '%s\n' "$rdir/${rref#@loader_path/}" ;;
      @executable_path/*) printf '%s\n' "$app/Contents/MacOS/${rref#@executable_path/}" ;;
      @rpath/*)
        while IFS= read -r rp; do
          [ -n "$rp" ] || continue
          case "$rp" in
            @loader_path*) printf '%s\n' "$rdir/${rp#@loader_path}/${rref#@rpath/}" ;;
            @executable_path)
              printf '%s\n' "$app/Contents/MacOS/${rref#@rpath/}"
              ;;
            @executable_path/*)
              printf '%s\n' "$app/Contents/MacOS/${rp#@executable_path}/${rref#@rpath/}"
              ;;
          esac
        done < <(rpaths_of "$robj")
        ;;
      /*) printf '%s\n' "$rref" ;;
      *) printf '%s\n' "$rdir/$rref" ;;
    esac
  }

  require_file() { [ -e "$1" ] || fail "缺少发布必需文件：${1#"$app"/}"; }
  require_file "$exe"
  require_file "$native/archoera-audio-engine"
  require_file "$native/archoera-vault"
  require_file "$native/libarchoera_mediaengine.dylib"
  require_file "$native/libarchoera_scraper.dylib"
  require_file "$native/scanner-ffi.dylib"
  require_file "$native/indexer-ffi.dylib"
  require_file "$native/libe_sqlite3.dylib"
  require_file "$native/ARCHOERA-NATIVE-MANIFEST.txt"

  file_list="$(mktemp "${TMPDIR:-/tmp}/archoera-macos-guard.XXXXXX")"
  trap 'rm -f "$file_list"' EXIT
  find "$app/Contents/MacOS" "$native" -type f 2>/dev/null | LC_ALL=C sort > "$file_list" || true

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    is_macho "$f" || continue
    rel="${f#"$app"/}"
    fdir="$(dirname "$f")"

    bundled_forbidden=0
    if is_forbidden "$f"; then
      fail "$rel: 包内出现 $(basename "$f")（加密/HTTP 已是内嵌 Rust 静态栈，不应内嵌 OpenSSL/libcurl）"
      bundled_forbidden=1
    fi

    archs="$(macho_arch "$f")"
    if [ -n "$arch" ] && [ "$archs" != "$arch" ]; then
      fail "$rel: 架构为 '${archs:-<未知>}'，期望 '$arch'"
    fi

    self_id="$(id_name "$f")"

    while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      dep_base="$(basename "$ref")"

      if [ "$bundled_forbidden" -eq 1 ]; then
        continue    # 自身副本已按「包内出现」报过
      fi
      if is_forbidden "$ref"; then
        fail "$rel: 禁止依赖 $ref（OpenSSL/libcurl 必须是内嵌 Rust 静态栈）"
        continue
      fi

      [ -n "$self_id" ] && [ "$ref" = "$self_id" ] && continue
      if [ "${ref#@}" = "$ref" ] && [ "${ref#/}" = "$ref" ] && [ "$dep_base" = "$(basename "$f")" ]; then
        continue    # 裸名指向自己
      fi

      if is_system_path "$ref"; then
        system_refs+=("$dep_base")
        continue
      fi
      if is_build_path "$ref"; then
        fail "$rel: 含构建机绝对路径 $ref（用户机不存在；需改写为 @loader_path 或内嵌）"
        continue
      fi

      cands="$(resolve_refs "$fdir" "$ref" "$f")"
      if [ -z "$cands" ]; then
        fail "$rel: @rpath 引用 $ref 无法解析（dylib 缺 LC_RPATH 或 rpath 指向构建机）"
        continue
      fi
      found=0
      first=""
      while IFS= read -r c; do
        [ -n "$c" ] || continue
        [ -z "$first" ] && first="$c"
        if [ -e "$c" ]; then
          found=1
          break
        fi
      done <<CANDLIST
$cands
CANDLIST
      if [ "$found" -eq 0 ]; then
        fail "$rel: 依赖 $ref 无法解析（bundle 内缺少 ${first#"$app"/}）"
      fi
    done < <(otool -L "$f" 2>/dev/null | tail -n +2 | awk '{print $1}')
  done < "$file_list"

  manifest="$native/ARCHOERA-NATIVE-MANIFEST.txt"
  if [ -f "$manifest" ]; then
    for f in "$native"/*.dylib; do
      [ -e "$f" ] || continue
      grep -q "  $(basename "$f")\$" "$manifest" \
        || fail "原生清单缺少 $(basename "$f")（清单未覆盖）"
    done
  fi

  [ "$errors" -eq 0 ] || die "macOS 依赖守卫失败：$errors 项错误"

  sysdeps="$app/Contents/ARCHOERA-SYSTEM-DEPS.txt"
  if [ "${#system_refs[@]}" -gt 0 ]; then
    printf '%s\n' "${system_refs[@]}" | sed '/^$/d' | LC_ALL=C sort -u > "$sysdeps"
  else
    : > "$sysdeps"
  fi
  log "依赖守卫通过：$(grep -c . "$sysdeps" 2>/dev/null || echo 0) 个系统库引用，架构 $arch"
}

# ───────────────────────────── bundle ─────────────────────────────
do_bundle() {
  require_tools otool install_name_tool codesign lipo dylibbundler file
  [ -d "$app" ] || die "找不到 .app: $app（先跑 flutter build macos --release）"
  app="$(cd "$(dirname "$app")" && pwd)/$(basename "$app")"
  app_paths

  log "bundle: $app（$arch）"
  mkdir -p "$native"

  copy_optional() {
    # $1 = 源路径通配；无匹配时跳过而不报错（部分模块在特定配置下不产出）
    for f in $1; do
      [ -e "$f" ] || continue
      cp -R "$f" "$native/"
    done
  }

  copy_optional "$ROOT/app/core/audio-engine/build/archoera-audio-engine"
  copy_optional "$ROOT/app/core/audio-engine/build/*.dylib"
  copy_optional "$ROOT/app/core/scanner/build/*.dylib"
  copy_optional "$ROOT/app/core/indexer/build/indexer-ffi.dylib"
  copy_optional "$ROOT/app/core/scraper/build/*.dylib"
  copy_optional "$ROOT/app/core/subsonic/build/*.dylib"
  copy_optional "$ROOT/app/core/vault-rs/build/archoera-vault"
  # libe_sqlite3：scanner 通常会带，缺失时由 indexer 兜底（同名同版本）
  if [ ! -f "$native/libe_sqlite3.dylib" ]; then
    copy_optional "$ROOT/app/core/indexer/build/libe_sqlite3.dylib"
  fi

  # 收拢运行库：引擎 FFmpeg / scraper TagLib / 引擎子进程的公共库
  for lib in libarchoera_mediaengine.dylib libarchoera_scraper.dylib; do
    [ -f "$native/$lib" ] || continue
    log "dylibbundler: $lib"
    dylibbundler -of -b -x "$native/$lib" -d "$native" -p @loader_path
  done
  if [ -f "$native/archoera-audio-engine" ]; then
    log "dylibbundler: archoera-audio-engine（自建最小 FFmpeg）"
    dylibbundler -of -b -x "$native/archoera-audio-engine" -d "$native" -p @loader_path
    codesign --force --sign - "$native/archoera-audio-engine"
  fi
  [ -f "$native/archoera-vault" ] && codesign --force --sign - "$native/archoera-vault"

  # install_name 归一化：dylibbundler 只覆盖上面几个库，其余模块
  # （downloader / transcoder / log / platform / scanner / indexer …）的
  # install_name 仍带 /Users/... 构建机路径，用户机加载必失败。
  log "install_name 归一化"
  normalize_loadpaths "$native"

  # LGPL 合规：FFmpeg / TagLib 许可文本 + 聚合声明
  bash "$ROOT/app/core/bundle-licenses.sh" "$app/Contents"

  # 防伪公钥随包分发（私钥绝不入库/入包）
  mkdir -p "$app/Contents/Resources"
  cp "$ROOT/app/tool/watermark_pub.pem" "$app/Contents/Resources/ARCHOERA_PUBKEY.pem"

  # 新增/改写 dylib 使原 ad-hoc 签名失效（Apple Silicon 拒载未签名 dylib）→ 重签整包
  log "codesign --deep --sign -"
  codesign --force --deep --sign - "$app"

  # 完整性清单必须在 dylibbundler + codesign **之后**生成（二者改写字节）
  sh "$ROOT/app/tool/gen_native_manifest.sh" "$native" "$exe"
  log "bundle 完成"
}

# ───────────────────────────── verify ─────────────────────────────
do_verify() {
  app_paths
  [ -d "$app" ] || die "找不到 .app: $app"
  app="$(cd "$(dirname "$app")" && pwd)/$(basename "$app")"
  app_paths

  log "verify: 依赖守卫（--arch $arch）"
  verify_deps

  require_tools lipo otool
  fail=0

  # 单架构：主程序 / Flutter 引擎 / 全部 native 产物
  check_arch() {
    f="$1"
    if [ ! -f "$f" ]; then
      echo "::error::缺少文件：${f#"$app"/}"
      fail=1
      return 0
    fi
    got="$(macho_arch "$f")"
    if [ "$got" != "$arch" ]; then
      echo "::error::${f#"$app"/} 架构为 '$got'，期望 '$arch'"
      fail=1
    fi
  }
  check_arch "$exe"
  check_arch "$app/Contents/Frameworks/FlutterMacOS.framework/Versions/A/FlutterMacOS"
  for f in "$native/archoera-audio-engine" "$native/archoera-vault"; do
    [ -e "$f" ] && check_arch "$f"
  done
  for f in "$native"/*.dylib; do
    [ -e "$f" ] || continue
    check_arch "$f"
  done
  [ "$fail" -eq 0 ] || die "架构检查未通过"

  # dyld 实际加载：验证 @loader_path 依赖、install_name 与 SQLite 伴随库
  if [ "${ARCHOERA_SKIP_DLOPEN:-0}" != "1" ]; then
    log "dyld 加载每个 FFI 库"
    python3 - "$native" <<'PY' || die "有 FFI 库无法加载"
import ctypes
import os
import sys

native = sys.argv[1]
failed = []
for name in sorted(os.listdir(native)):
    if not name.endswith(".dylib"):
        continue
    try:
        ctypes.CDLL(os.path.join(native, name))
    except OSError as exc:
        failed.append("%s: %s" % (name, exc))
if failed:
    print("::error::以下 FFI 库加载失败：")
    for item in failed:
        print(item)
    sys.exit(1)
PY
  fi

  # 关键伴随库：NativeAOT 的 indexer/scanner 按名 dlopen libe_sqlite3
  for f in indexer-ffi.dylib scanner-ffi.dylib libe_sqlite3.dylib; do
    [ -f "$native/$f" ] || die "native/$f 未打入包（见 bundle 阶段的模块输出）"
  done
  grep -q 'indexer-ffi.dylib' "$native/ARCHOERA-NATIVE-MANIFEST.txt" \
    || die "完整性清单缺 indexer-ffi.dylib"

  # 内嵌 CLI：覆盖 Rust staticlib 链入 + 参数分派
  log "archoerashell --version"
  "$exe" archoerashell --version

  log "verify 完成（$arch）"
}

# ───────────────────────────── package ────────────────────────────
do_package() {
  require_tools ditto hdiutil
  [ -d "$app" ] || die "找不到 .app: $app"
  app="$(cd "$(dirname "$app")" && pwd)/$(basename "$app")"

  dist="$ROOT/dist/macos"
  mkdir -p "$dist"
  base="$dist/$APP_NAME-$version-macos-$arch"
  rm -f "$base.dmg" "$base.zip" "$base.dmg.sig1" "$base.zip.sig1" "$base.info.txt"

  log "zip（ditto，保留符号链接与可执行位）"
  ditto -c -k --sequesterRsrc --keepParent "$app" "$base.zip"
  log "zip: $base.zip ($(du -h "$base.zip" | cut -f1 | tr -d ' '))"

  printf 'bundle-id=com.archoera.archoeraMusic\nversion=%s\narch=%s\n' \
    "$version" "$arch" > "$base.info.txt"

  if [ "${SKIP_DMG:-0}" = "1" ]; then
    log "SKIP_DMG=1，跳过 DMG"
    return 0
  fi

  work="$(mktemp -d "${TMPDIR:-/tmp}/archoera-dmg.XXXXXX")"
  stage="$work/stage"
  mkdir -p "$stage"
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
  2. 打开「系统设置 → 隐私与安全性」，在页面底部点「仍要打开」。

首次打开成功一次后，之后双击即可正常运行。

若提示「已损坏，无法打开」（多见于下载后带隔离属性），可执行：
  xattr -dr com.apple.quarantine /Applications/ArchoeraMusic.app

架构：请确认与你的 Mac 匹配（Apple 芯片选 arm64，Intel 选 x64）。

项目主页：https://github.com/ArchoeraC/ArchoeraMusic
NOTE

  log "hdiutil 生成 DMG"
  hdiutil create \
    -volname "$APP_NAME $version" \
    -srcfolder "$stage" \
    -ov -format UDZO -fs HFS+ \
    -quiet "$base.dmg"

  # 挂载回读：确认镜像里真有可执行的 .app
  mnt="$work/mnt"
  mkdir -p "$mnt"
  if ! hdiutil attach "$base.dmg" -nobrowse -readonly -mountpoint "$mnt" -quiet; then
    rm -rf "$work" "$base.dmg"
    die "DMG 无法挂载（hdiutil attach 失败）"
  fi
  if [ ! -x "$mnt/$APP_NAME.app/Contents/MacOS/$BIN" ]; then
    hdiutil detach "$mnt" -quiet || true
    rm -rf "$work" "$base.dmg"
    die "DMG 内缺少可执行文件 $APP_NAME.app/Contents/MacOS/$BIN"
  fi
  hdiutil detach "$mnt" -quiet || true
  rm -rf "$work"

  log "dmg: $base.dmg ($(du -h "$base.dmg" | cut -f1 | tr -d ' '))"
}

case "$step" in
  bundle) do_bundle ;;
  verify) do_verify ;;
  package) do_package ;;
  all)
    # 显式串行 + 逐步失败即退出（不能用分号序列，退出码会被最后一个命令覆盖）
    do_bundle
    do_verify
    do_package
    ;;
  *) usage ;;
esac
