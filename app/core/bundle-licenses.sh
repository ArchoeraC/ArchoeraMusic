#!/usr/bin/env bash
# =====================================================================
#  把随包内嵌的第三方运行库许可文本收进 <bundle>/licenses/（LGPL 合规）。
#
#  覆盖：
#   - FFmpeg（自建最小纯 LGPL）→ 从自建 prefix 拷 COPYING.LGPLv2.1 / LICENSE.md
#   - TagLib（LGPL-2.1 / MPL-1.1）→ 各发行版放置位置不同，逐一探测；找不到时
#     依 FFmpeg 的 COPYING.LGPLv2.1（同一 LGPL-2.1 文本）覆盖
#   - THIRD-PARTY-NOTICES.md（根目录，聚合声明 + 源码/替换权）
#
#  用法: bundle-licenses.sh <bundle 目录>
#  环境: FFMPEG_PREFIX（默认 $HOME/.local/ffmpeg-minimal）
# =====================================================================
set -euo pipefail

bundle="${1:?用法: bundle-licenses.sh <bundle>}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
prefix="${FFMPEG_PREFIX:-$HOME/.local/ffmpeg-minimal}"
dest="$bundle/licenses"
mkdir -p "$dest"

# 1) 聚合声明
[[ -f "$root/THIRD-PARTY-NOTICES.md" ]] && cp -f "$root/THIRD-PARTY-NOTICES.md" "$dest/"

# 2) FFmpeg（自建最小纯 LGPL）：许可文本在我们自己的 prefix
ff_lic="$prefix/share/licenses/ffmpeg"
if [[ -d "$ff_lic" ]]; then
  cp -f "$ff_lic"/* "$dest/" 2>/dev/null || true
fi

# 3) TagLib：探测各发行版/Homebrew 的许可文件
tag_src=""
for p in \
  /usr/share/licenses/taglib/COPYING.LGPL \
  /usr/share/licenses/taglib/COPYING.MPL \
  /opt/homebrew/opt/taglib/COPYING.LGPL \
  /usr/local/opt/taglib/COPYING.LGPL \
  /usr/share/doc/libtag1v5/copyright \
  /usr/share/doc/libtag-dev/copyright \
  /usr/share/doc/taglib/copyright ; do
  [[ -f "$p" ]] || continue
  cp -f "$p" "$dest/TagLib-LICENSE.txt"
  tag_src="$p"
  break
done
if [[ -z "$tag_src" ]]; then
  # 兜底：同一 LGPL-2.1 文本（FFmpeg 的 COPYING.LGPLv2.1 即为标准 LGPL-2.1）
  if [[ -f "$dest/COPYING.LGPLv2.1" ]]; then
    {
      echo "TagLib（https://github.com/taglib/taglib）以 LGPL-2.1-or-later / MPL-1.1 双许可发布。"
      echo "本文件为 LGPL-2.1 标准文本（与 FFmpeg 同许可）。"
      echo "------------------------------------------------------------------------"
      cat "$dest/COPYING.LGPLv2.1"
    } > "$dest/TagLib-LICENSE.txt"
  else
    echo "[bundle-licenses] 警告: 未找到 TagLib 许可文本，且无 LGPL-2.1 兜底" >&2
  fi
fi

echo "[bundle-licenses] $dest:"
ls -1 "$dest"
