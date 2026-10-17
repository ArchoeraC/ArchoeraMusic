#!/usr/bin/env bash
# =====================================================================
#  ArchoeraMusic 发布 SBOM 生成（CycloneDX JSON，SEC-25）
#
#  把「发布产物」与「各生态依赖清单（锁文件）」聚到一个暂存目录，交给 syft
#  一次扫描，再经 sbom_normalize.py 归一化：
#    · 产物侧：原生库（FFmpeg / OpenSSL / opus / taglib）、自家二进制、Go 模块；
#    · 源码侧：Rust（5× Cargo.lock）/ Dart（pubspec.lock）/ Go（go.mod+go.sum）/
#      .NET（scanner、indexer 的 packages.lock.json）。
#
#  为什么合并成一次扫描：SBOM 的「主体」是产品本身而不是某个目录；下游（发行版
#  打包 / SCA 工具）也希望**一份**清单就能回答「这版里有哪些 crate / NuGet 包 /
#  pub 包」。只扫产物目录时 syft 读不到锁文件 → Rust / NuGet 覆盖为 0。
#
#  用法：bash app/tool/gen_sbom.sh <artifacts_dir> <repo_root> <version> <out_file>
#    artifacts_dir  发布产物目录（release 作业里是 artifacts/）
#    repo_root      仓库根（用于定位锁文件）
#    version        版本号（= tag 去掉 v，如 1.0.1+1）
#    out_file       输出文件（如 assets/ARCHOERA-SBOM.cdx.json）
#
#  依赖：syft >= 1.54（CI 里按 pin 版本 + 校验和安装，见 build-all.yml）、
#        python3（归一化；ubuntu runner 自带）。
#
#  本地复现：
#    syft 从 https://github.com/anchore/syft/releases 取对应平台二进制放入 PATH，
#    然后 `bash app/tool/gen_sbom.sh artifacts . 1.0.1+1 /tmp/ARCHOERA-SBOM.cdx.json`
# =====================================================================
set -euo pipefail

ART="${1:?用法: gen_sbom.sh <artifacts_dir> <repo_root> <version> <out_file>}"
ROOT="${2:?缺少 repo_root}"
VER="${3:?缺少 version}"
OUT="${4:?缺少 out_file}"

[ -d "$ART" ] || { echo "产物目录不存在: $ART" >&2; exit 1; }
command -v syft >/dev/null 2>&1 || {
  echo "缺少 syft（>=1.54）：https://github.com/anchore/syft/releases" >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || { echo "缺少 python3（SBOM 归一化用）" >&2; exit 1; }

# 暂存目录放在产物同级（同一文件系统）→ 硬链接可用，避免复制数百 MB；
# 产物目录本身不会被改动（只读取）。
STAGE="$(mktemp -d "$(dirname "$ART")/.sbom-stage.XXXXXX")"
RAW="$(mktemp "${TMPDIR:-/tmp}/archoera-sbom-raw.XXXXXX.json")"
cleanup() { rm -rf "$STAGE" "$RAW"; }
trap cleanup EXIT

# ── 1) 发布产物 ──────────────────────────────────────────────────────
# 硬链接而非复制：产物有数百 MB，同文件系统下 `cp -al` 瞬时完成；跨文件系统
# （或非 GNU cp）回退为复制。
cp -al "$ART"/. "$STAGE"/ 2>/dev/null || cp -a "$ART"/. "$STAGE"/

# ── 2) 各生态锁文件（只取清单，不需要源码）──────────────────────────
mkdir -p "$STAGE/src"/{dart,rust/downloader,rust/shell,rust/vault,rust/tempo,rust/transcoder,go/subsonic,nuget/scanner,nuget/indexer}
copy_manifest() {
  local src="$1" dir="$2"
  if [ -f "$src" ]; then
    cp "$src" "$STAGE/src/$dir/"
  else
    # 缺失不致命，但要显式提示：对应生态会从 SBOM 里消失（回归信号）。
    echo "[gen_sbom] 提示：缺少依赖清单 $src（该生态将不出现在 SBOM）" >&2
  fi
}
copy_manifest "$ROOT/app/pubspec.lock"                            dart
copy_manifest "$ROOT/app/core/downloader/Cargo.lock"              rust/downloader
copy_manifest "$ROOT/app/core/shell/Cargo.lock"                   rust/shell
copy_manifest "$ROOT/app/core/vault-rs/Cargo.lock"                rust/vault
copy_manifest "$ROOT/app/core/audio-engine/tempo-rs/Cargo.lock"   rust/tempo
copy_manifest "$ROOT/app/core/subsonic/transcoder/Cargo.lock"     rust/transcoder
copy_manifest "$ROOT/app/core/subsonic/go.mod"                    go/subsonic
copy_manifest "$ROOT/app/core/subsonic/go.sum"                    go/subsonic
copy_manifest "$ROOT/app/core/scanner/packages.lock.json"         nuget/scanner
copy_manifest "$ROOT/app/core/indexer/packages.lock.json"         nuget/indexer

# ── 3) 扫描 + 归一化 ────────────────────────────────────────────────
# `--source-name/--source-version` 决定 SBOM 主体（metadata.component），
# 否则 syft 会把扫描目录名（如 artifacts）当成产品名、且没有版本。
echo "[gen_sbom] syft 扫描中（产物 + 锁文件）…"
syft scan "dir:$STAGE" \
  --source-name ArchoeraMusic \
  --source-version "$VER" \
  --output "cyclonedx-json=$RAW" \
  --quiet

python3 "$ROOT/app/tool/sbom_normalize.py" "$RAW" "$OUT" "$VER"
echo "[gen_sbom] 完成：$OUT"
