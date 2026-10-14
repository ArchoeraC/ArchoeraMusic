#!/usr/bin/env bash
# ArchoeraMusic — 本地曲库搜索索引器 P5 性能 harness 入口。
#
# 用真实产物（app/core/indexer 的 C# FTS5 索引器）量化全量/增量构建耗时、索引体积、
# 峰值内存与查询 P50/P95（A 含拼音 / B 无拼音，另可 --with-lrc 追加 .lrc 档），
# 对照设计文档 §2.2 预算判定 P5。
# 生成物落 bench/.work/（已 gitignore）；报告写 bench/REPORT.md。
#
# 用法：bash app/core/indexer/bench/run_bench.sh [额外 run_bench.py 参数]
# 可覆写环境变量：TRACKS / SEED / ROUNDS / REPEATS / WARMUP / QUERY_LIMITS /
#                INCREMENTAL_K / WITH_LRC / CONFIG / BENCH_WORK
set -euo pipefail
cd "$(dirname "$0")"

TRACKS="${TRACKS:-10000}"
SEED="${SEED:-20261013}"
ROUNDS="${ROUNDS:-2}"
REPEATS="${REPEATS:-60}"
WARMUP="${WARMUP:-5}"
QUERY_LIMITS="${QUERY_LIMITS:-50,10000}"
INCREMENTAL_K="${INCREMENTAL_K:-20,200}"
CONFIG="${CONFIG:-Release}"
WORK="${BENCH_WORK:-$(pwd)/.work}"

WITH_LRC_FLAG=()
if [ -n "${WITH_LRC:-}" ]; then WITH_LRC_FLAG=(--with-lrc); fi

command -v python3 >/dev/null 2>&1 || { echo "需要 python3（仅标准库）" >&2; exit 1; }
command -v dotnet  >/dev/null 2>&1 || { echo "需要 .NET 10 SDK（dotnet）" >&2; exit 1; }

exec python3 run_bench.py \
  --tracks "$TRACKS" --seed "$SEED" \
  --rounds "$ROUNDS" --repeats "$REPEATS" --warmup "$WARMUP" \
  --query-limits "$QUERY_LIMITS" \
  --incremental-k "$INCREMENTAL_K" --config "$CONFIG" --work "$WORK" "${WITH_LRC_FLAG[@]}" "$@"
