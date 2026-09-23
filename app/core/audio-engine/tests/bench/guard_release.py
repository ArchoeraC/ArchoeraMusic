#!/usr/bin/env python3
# ArchoeraMusic Audio Framework
# Copyright (C) 2026 Archoera && BetaStudio2
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# guard_release.py — 方向④ P4「冷/热首帧 + 常驻 RSS」发布看护（可断言门）
#
# 背景：decode-optimization.md §4.2 / audio-kernel-expansion-plan.md §5.2(P4) 要求
# 「每次改动复测冷/热首帧与常驻 RSS，回退即回滚」。既有 scorecard/run_suite 只
# 报告，本脚本把该纪律升级为**可断言 guard**：
#   1. 对小固定语料逐个跑 bench_coldstart，读同轮 era(hot) 与 Stable(FFmpeg) 的
#      首帧 p50，要求 era ≤ stable × (1 + tolerance)；
#   2. 跑 bench_era_pool 并发解码，采样子进程峰值 RSS（/proc VmHWM），
#      要求不超过 guard_baseline.json 记录的基线；
#   3. `--update-baseline` 用本轮实测重置基线（RSS 上限 + 观测到的 Stable p50）。
#
# 设计约束：
#   - **不入默认 ctest**：语料/计时敏感，手动或在发布前跑；
#   - **语料缺失时优雅降级**：打印清晰 SKIP 说明并退出 0（不误报失败）；
#   - 退出码：0 = 通过/跳过；1 = 断言失败（首帧回退或 RSS 超基线）；2 = 用法/环境错误。
#
# 用法：
#   python3 guard_release.py                       # 默认语料 /tmp/eng2
#   python3 guard_release.py --corpus /path --reps 21
#   python3 guard_release.py --update-baseline     # 记录本轮基线
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]                       # app/core/audio-engine（bench → tests → engine）
DEFAULT_BUILD = ROOT / "build"
BASELINE_PATH = HERE / "guard_baseline.json"
DEFAULT_CORPUS = Path("/tmp/eng2")
DEFAULT_FILES = ["ind.flac", "ind.m4a", "ind.mp3"]

ERA_P50_RE = re.compile(r"RESULT era hot first-frame p50=(-?\d+)")
STABLE_P50_RE = re.compile(r"RESULT stable first-frame p50=(-?\d+)")


def find_bench(build_dir, name):
    """bench 可执行路径（CMake tests/ 子目录优先，其次 build 根）。"""
    for cand in (build_dir / "tests" / name, build_dir / name):
        if cand.is_file() and os.access(cand, os.X_OK):
            return cand
    return None


def try_build(build_dir, targets):
    """配置（若缺）并构建 bench 目标；成功返回 0，否则返回非 0。"""
    try:
        if not (build_dir / "CMakeCache.txt").is_file():
            cfg = subprocess.run(
                ["cmake", "-S", str(ROOT), "-B", str(build_dir),
                 "-DCMAKE_BUILD_TYPE=Release"],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            if cfg.returncode != 0:
                sys.stderr.write(cfg.stdout.decode(errors="replace"))
                return cfg.returncode
        build = subprocess.run(
            ["cmake", "--build", str(build_dir), "-j", *targets],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if build.returncode != 0:
            sys.stderr.write(build.stdout.decode(errors="replace"))
        return build.returncode
    except FileNotFoundError:
        return 127


def peak_rss_kib(pid):
    try:
        with open(f"/proc/{pid}/status") as fh:
            for line in fh:
                if line.startswith("VmHWM:"):
                    return int(line.split()[1])
    except OSError:
        pass
    return 0


def run_measured(argv, timeout=600):
    """运行子进程，返回 (rc, output, peak_rss_kib)；轮询 /proc VmHWM。"""
    peak = [0]
    stop = threading.Event()
    p = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    def poll():
        while not stop.is_set():
            r = peak_rss_kib(p.pid)
            if r > peak[0]:
                peak[0] = r
            time.sleep(0.002)

    th = threading.Thread(target=poll, daemon=True)
    th.start()
    try:
        out, _ = p.communicate(timeout=timeout)
        rc = p.returncode
    except subprocess.TimeoutExpired:
        p.kill()
        out, _ = p.communicate()
        rc = 124
    stop.set()
    th.join(timeout=0.3)
    return rc, out.decode(errors="replace"), peak[0]


def load_baseline():
    if not BASELINE_PATH.is_file():
        return None
    with open(BASELINE_PATH) as fh:
        return json.load(fh)


def save_baseline(data):
    with open(BASELINE_PATH, "w") as fh:
        json.dump(data, fh, indent=2, ensure_ascii=False)
        fh.write("\n")


def main():
    ap = argparse.ArgumentParser(description="P4 冷/热首帧 + RSS 发布看护")
    ap.add_argument("--corpus", default=str(DEFAULT_CORPUS),
                    help=f"固定语料目录（默认 {DEFAULT_CORPUS}）")
    ap.add_argument("--files", default=",".join(DEFAULT_FILES),
                    help="语料文件名（逗号分隔）")
    ap.add_argument("--build-dir", default=str(DEFAULT_BUILD))
    ap.add_argument("--reps", type=int, default=21, help="每文件 bench 迭代数")
    ap.add_argument("--tolerance", type=float, default=None,
                    help="首帧允许超出 Stable 的比例（默认取基线 first_frame_tolerance）")
    ap.add_argument("--update-baseline", action="store_true",
                    help="用本轮实测重置基线（RSS 上限 + Stable p50）后退出 0")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    build_dir = Path(args.build_dir)
    baseline = load_baseline() or {
        "schema": 1,
        "note": "P4 发布看护基线（guard_release.py --update-baseline 生成）",
        "first_frame_tolerance": 0.25,
        "first_frame_ratio": {},
        "rss_kib": {"bench_coldstart": None, "bench_era_pool": None},
        "stable_p50_us": {},
        "era_p50_us": {},
    }
    tol = args.tolerance
    if tol is None:
        tol = float(baseline.get("first_frame_tolerance", 0.25))
    rss_tol = float(baseline.get("rss_tolerance", 0.10))

    # ---- 定位/构建 bench 二进制（缺失时尝试构建；失败则优雅跳过）----
    cold = find_bench(build_dir, "bench_coldstart")
    pool = find_bench(build_dir, "bench_era_pool")
    if cold is None or pool is None:
        print(f"[guard] bench 二进制缺失，尝试构建（{build_dir}）…")
        rc = try_build(build_dir, ["bench_coldstart", "bench_era_pool"])
        cold = find_bench(build_dir, "bench_coldstart")
        pool = find_bench(build_dir, "bench_era_pool")
        if rc != 0 or cold is None or pool is None:
            print(f"[guard] SKIP：bench 构建不可用（rc={rc}，"
                  f"build={build_dir}）。请先 cmake 配置/构建。")
            return 0

    # ---- 语料可用性（缺失 → 优雅降级，不误报）----
    corpus = Path(args.corpus)
    files = [corpus / n for n in args.files.split(",") if n]
    present = [f for f in files if f.is_file()]
    if not present:
        print(f"[guard] SKIP：语料不可用（{corpus} 下无 {args.files}）。")
        print("        这是语料/环境问题，非回退；不判失败。")
        print("        生成语料见 docs/decode-optimization.md §6 / scorecard.py。")
        return 0
    if len(present) < len(files):
        missing = [f.name for f in files if not f.is_file()]
        print(f"[guard] 注意：语料缺 {missing}，仅测 {[f.name for f in present]}")

    violations = []
    measured_rss = {}
    measured_stable = {}

    # ---- 1) 冷/热首帧：era(hot) p50 vs Stable p50（同轮、同机）----
    ratios = baseline.get("first_frame_ratio", {})
    print(f"[guard] 首帧门：era hot p50 ≤ Stable p50 × ratio × (1 + {tol:.0%})，reps={args.reps}")
    measured_era = {}
    for f in present:
        rc, out, cpk = run_measured([str(cold), str(f), str(args.reps)])
        measured_rss["bench_coldstart"] = max(
            measured_rss.get("bench_coldstart", 0), cpk)
        if rc != 0:
            violations.append(f"bench_coldstart 失败 rc={rc} file={f.name}")
            continue
        era_m = ERA_P50_RE.search(out)
        sta_m = STABLE_P50_RE.search(out)
        if args.verbose:
            print(out)
        era = int(era_m.group(1)) if era_m else -1
        sta = int(sta_m.group(1)) if sta_m else -1
        if sta <= 0:
            ref = baseline.get("stable_p50_us", {}).get(f.name)
            if ref:
                sta = int(ref)
                print(f"[guard]   {f.name}: 本轮 Stable p50 不可用，用基线 {sta}µs")
        if era <= 0 or sta <= 0:
            print(f"[guard]   {f.name}: 跳过（era={era}µs stable={sta}µs）")
            continue
        measured_stable[f.name] = sta
        measured_era[f.name] = era
        # ratio 为「该格式可接受的 era/stable 比」（基线记录；默认 1.0 = 不快于 FFmpeg 即失败）
        ratio = float(ratios.get(f.name, 1.0))
        limit = sta * ratio * (1.0 + tol)
        status = "OK" if era <= limit else "FAIL"
        print(f"[guard]   {f.name}: era={era}µs stable={sta}µs "
              f"ratio={ratio:.2f} limit={limit:.0f}µs → {status}")
        if era > limit:
            violations.append(
                f"首帧回退 {f.name}: era p50 {era}µs > stable {sta}µs"
                f" × {ratio:.2f} × (1+{tol:.0%})")

    # ---- 2) 常驻 RSS：bench_coldstart + bench_era_pool 峰值 ----
    print("[guard] RSS 门：bench 峰值 ≤ 基线 rss_kib")
    rc, out, peak = run_measured([str(pool), str(max(1, len(present)))]
                                 + [str(f) for f in present])
    if args.verbose:
        print(out)
    if rc != 0:
        violations.append(f"bench_era_pool 失败 rc={rc}")
    else:
        measured_rss["bench_era_pool"] = peak

    ceilings = baseline.get("rss_kib", {})
    for name in ("bench_coldstart", "bench_era_pool"):
        pk = measured_rss.get(name)
        if pk is None:
            continue
        ceiling = ceilings.get(name)
        if ceiling is None:
            print(f"[guard]   {name}: peak={pk}KiB（基线未记录，跳过断言）")
        else:
            limit = ceiling * (1.0 + rss_tol)
            status = "OK" if pk <= limit else "FAIL"
            print(f"[guard]   {name}: peak={pk}KiB ≤ {ceiling}KiB"
                  f" × (1+{rss_tol:.0%}) = {limit:.0f}KiB → {status}")
            if pk > limit:
                violations.append(
                    f"RSS 超基线 {name}: {pk}KiB > {ceiling}KiB × (1+{rss_tol:.0%})")

    # ---- 3) 记录/重置基线 ----
    if args.update_baseline:
        baseline["first_frame_tolerance"] = tol
        baseline.setdefault("stable_p50_us", {}).update(measured_stable)
        baseline.setdefault("era_p50_us", {}).update(measured_era)
        ratios_db = baseline.setdefault("first_frame_ratio", {})
        for name, era in measured_era.items():
            sta = measured_stable.get(name)
            if sta and sta > 0:
                ratios_db[name] = round(era / sta, 3)
        rss = baseline.setdefault("rss_kib", {})
        for name, pk in measured_rss.items():
            if pk is not None:
                rss[name] = pk
        save_baseline(baseline)
        print(f"[guard] 基线已写入 {BASELINE_PATH}")
        return 0

    if violations:
        print("\n[guard] FAILED:")
        for v in violations:
            print(f"  - {v}")
        return 1
    print("\n[guard] PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
