#!/usr/bin/env bash
# ArchoeraMusic — 本地曲库搜索索引器 P5 性能 harness 入口。
#
# 用真实产物（app/core/indexer 的 C# FTS5 索引器）量化全量/增量构建耗时、索引体积、
# 峰值内存与查询 P50/P95（A 含拼音 / B 无拼音，另可 --with-lrc 追加 .lrc 档），
# 对照设计文档 §2.2 预算判定 P5。
# 生成物落 bench/.work/（已 gitignore）；报告写 bench/REPORT.md。
#
# 用法：bash app/core/indexer/bench/run_bench.sh [额外 run_bench.py 参数]
# 可覆写环境变量：PROFILE / TRACKS / SEED / ROUNDS / REPEATS / WARMUP / QUERY_LIMITS /
#                INCREMENTAL_K / WITH_LRC / CONFIG / BENCH_WORK / VOCAB
#
# 档位（PROFILE）：
#   full （默认）30000 曲 / 大词表 / 2 轮 —— 出**正式基线**，约 15 min、峰值磁盘 ~1.5 GB
#   quick        3000 曲 / 400 词 / 1 轮 —— 约 2 min，够判「排序/召回是否坏、有无明显回归」
#                                          **不得**用于写正式基线数字
# 单独覆写任一变量即覆盖档位（如 `PROFILE=quick TRACKS=8000`）。
#
# ⚠ full 档会持续满负载十余分钟：**散热受限的机器可能因此强制关机**。
#   故 full 需显式 `ALLOW_LONG_BENCH=1` 才放行；日常验证用 PROFILE=quick。
set -euo pipefail
cd "$(dirname "$0")"

PROFILE="${PROFILE:-full}"
case "$PROFILE" in
  quick)
    : "${TRACKS:=3000}"; : "${VOCAB:=400}"; : "${ROUNDS:=1}"
    : "${REPEATS:=20}"; : "${WARMUP:=2}"; : "${QUERY_LIMITS:=50}"
    ;;
  full)
    if [ "${ALLOW_LONG_BENCH:-0}" != "1" ]; then
      cat >&2 <<'EOF'
PROFILE=full 会持续满负载约 15 分钟（8 核编译 + 多轮全量构建 + 查询压测）。

⚠ 散热受限的机器长时间满负载可能触发**强制关机**。

  · 日常验证（推荐，~2 min）：PROFILE=quick bash run_bench.sh
  · 确实要出正式基线：ALLOW_LONG_BENCH=1 bash run_bench.sh
  · 只想刷新报告：已有 .work/metrics.json 时可直接重渲染 REPORT.md，无需重跑基准。
EOF
      exit 2
    fi
    : "${TRACKS:=30000}"; : "${VOCAB:=4000}"; : "${ROUNDS:=2}"
    : "${REPEATS:=60}"; : "${WARMUP:=5}"; : "${QUERY_LIMITS:=50,10000}"
    ;;
  *)
    echo "未知 PROFILE=$PROFILE（可用：full / quick）" >&2; exit 2 ;;
esac

: "${SEED:=20261013}"
: "${INCREMENTAL_K:=20,200}"
: "${CONFIG:=Release}"
WORK="${BENCH_WORK:-$(pwd)/.work}"
# VOCAB>0 使用大词表语料（真实命中率，作主判据）；默认 0 = 固定小词表（最坏上界）。
VOCAB="${VOCAB:-0}"

WITH_LRC_FLAG=()
if [ -n "${WITH_LRC:-}" ]; then WITH_LRC_FLAG=(--with-lrc); fi

command -v python3 >/dev/null 2>&1 || { echo "需要 python3（仅标准库）" >&2; exit 1; }
command -v dotnet  >/dev/null 2>&1 || { echo "需要 .NET 10 SDK（dotnet）" >&2; exit 1; }

exec python3 run_bench.py \
  --tracks "$TRACKS" --seed "$SEED" \
  --rounds "$ROUNDS" --repeats "$REPEATS" --warmup "$WARMUP" \
  --query-limits "$QUERY_LIMITS" \
  --incremental-k "$INCREMENTAL_K" --config "$CONFIG" --work "$WORK" \
  --vocab "$VOCAB" "${WITH_LRC_FLAG[@]}" "$@"
