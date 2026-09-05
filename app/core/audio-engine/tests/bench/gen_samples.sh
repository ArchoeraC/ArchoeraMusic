#!/usr/bin/env bash
# gen_samples.sh — 生成基准语料补充样本（放 /tmp/eng；不进入源码树）。
#
# 用途：
#   - big300.wv / big300.mka           ：>15MB 整读复查用（FLAC→WavPack / mka 封装）
#   - big600.{flac,wv,mka}             ：60MB+ 级整读趋势验证
#   - mk_*.mka（opus/flac/ac3/ec3/pcm/mp3 内轨，2s） ：mka 容器格式接管矩阵
#   - x.m4a / x.wv / x.ape             ：补充小样本（含 ape；m4a 别名）
#
# 输出到 /tmp/eng；本脚本可重复执行（-y 覆盖）。
set -euo pipefail
E=/tmp/eng
SRC=$E/big300.flac
[ -f "$SRC" ] || { echo "缺少源 $SRC" >&2; exit 1; }

echo "[gen] big300.wv (FLAC→WavPack, 300s)"
ffmpeg -y -loglevel error -i "$SRC" -c:a wavpack -compression_level 2 "$E/big300.wv"

echo "[gen] big300.mka (FLAC 轨封装 mka, 300s)"
ffmpeg -y -loglevel error -i "$SRC" -c:a flac -f matroska "$E/big300.mka"

echo "[gen] big600.flac (concat 2x big300 → 600s)"
ffmpeg -y -loglevel error -i "$SRC" -i "$SRC" \
  -filter_complex "[0:a][1:a]concat=n=2:v=0:a=1[a]" -map "[a]" -c:a flac "$E/big600.flac"

if [ -f "$E/big600.flac" ]; then
  echo "[gen] big600.wv / big600.mka"
  ffmpeg -y -loglevel error -i "$E/big600.flac" -c:a wavpack -compression_level 2 "$E/big600.wv"
  ffmpeg -y -loglevel error -i "$E/big600.flac" -c:a flac -f matroska "$E/big600.mka"
fi

echo "[gen] mk_*.mka 小样本（mka 内轨接管矩阵）"
for spec in opus flac ac3 ec3 pcm mp3 vorbis; do
  case "$spec" in
    opus)   src=$E/x.flac; ac="-c:a libopus";;
    flac)   src=$E/x.flac; ac="-c:a flac";;
    ac3)    src=$E/x.flac; ac="-c:a ac3 -b:a 192k";;
    ec3)    src=$E/x.flac; ac="-c:a eac3 -b:a 256k";;
    pcm)    src=$E/x.wav;  ac="-c:a pcm_s16le";;
    mp3)    src=$E/x.flac; ac="-c:a libmp3lame -b:a 192k";;
    vorbis) src=$E/x.flac; ac="-c:a libvorbis";;
  esac
  ffmpeg -y -loglevel error -i "$src" $ac -f matroska "$E/mk.$spec.mka"
done

echo "[gen] 完成:"
ls -la "$E"/big300.wv "$E"/big300.mka "$E"/big600.* "$E"/mk.*.mka 2>/dev/null
