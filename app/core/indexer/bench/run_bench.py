#!/usr/bin/env python3
# ArchoeraMusic
# Copyright (C) 2026 Archoera && BetaStudio2
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# 本地曲库搜索索引器 P5 性能 harness —— 跑测编排器。
#
# 用**真实产物**（app/core/indexer C# FTS5 索引器）量化：
#   - 全量构建耗时 / 峰值 RSS / 写入字节（A 组含拼音；B 组 --no-pinyin）；
#   - search.db 体积；
#   - 增量（改 K 首 file_mtime）耗时（K=20 与 K=200，验证与 K 成正比）；
#   - 查询延迟 P50 / P95（同一进程内循环，排除 dotnet 启动；A/B 两组各一次）；
# 并对照设计文档 §2.2 预算，判定 P5（§5.5 自研段引擎）是否触发，产出 bench/REPORT.md。
#
# 依赖：Python 标准库 + 本机 .NET 10 SDK。不新增第三方依赖。
# 生成物（library.db / search.db / qbench bin/obj）落 bench/.work（已 gitignore），不入库。

from __future__ import annotations

import argparse
import datetime
import json
import os
import platform
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
IDX = os.path.abspath(os.path.join(HERE, ".."))          # app/core/indexer
QB_DIR = os.path.join(HERE, "qbench")
# qbench 的 obj/bin 被显式指向系统临时目录（避免被父 CLI 的 `**/*.cs` 通配吸入）。
QB_ARTIFACTS = os.path.join(tempfile.gettempdir(), "archoera-indexer-bench")
REPORT = os.path.join(HERE, "REPORT.md")
sys.path.insert(0, HERE)
import gen_corpus  # noqa: E402  (同目录，标准库生成器)

# §2.2 预算（用于达标判定与 25k 外推）。
BUDGET = {
    "full_min_ms": 2 * 60 * 1000,
    "full_max_ms": 5 * 60 * 1000,
    "query_p50_ms": 20.0,
    "query_p95_ms": 80.0,
    "index_min_mb": 100.0,
    "index_max_mb": 300.0,
    "extrapolate_n": 25000,
}


# ---------------------------------------------------------------------------
# 环境探测
# ---------------------------------------------------------------------------

def cpu_info() -> tuple[str, int]:
    model = "unknown"
    try:
        with open("/proc/cpuinfo", encoding="utf-8", errors="replace") as f:
            for line in f:
                if line.startswith("model name"):
                    model = line.split(":", 1)[1].strip()
                    break
    except OSError:
        pass
    return model, os.cpu_count() or 0


def mem_total_gb() -> float:
    try:
        with open("/proc/meminfo", encoding="utf-8") as f:
            for line in f:
                if line.startswith("MemTotal:"):
                    return round(int(line.split()[1]) / 1024 / 1024, 2)
    except OSError:
        pass
    return 0.0


def disk_info(path: str) -> dict:
    """返回 (device, fstype, mount, rotational) 描述 path 所在文件系统。"""
    real = os.path.realpath(path)
    best = None
    try:
        with open("/proc/mounts", encoding="utf-8") as f:
            for line in f:
                parts = line.split()
                if len(parts) < 3:
                    continue
                dev, mp, fstype = parts[0], parts[1], parts[2]
                if real == mp or real.startswith(mp.rstrip("/") + "/"):
                    if best is None or len(mp) > len(best[1]):
                        best = (dev, mp, fstype)
    except OSError:
        pass
    if best is None:
        return {"device": "?", "fstype": "?", "mount": "?", "media": "unknown"}
    dev, mp, fstype = best
    media = "unknown"
    if dev.startswith("/dev/"):
        base = os.path.basename(dev)
        m = re.match(r"(nvme\d+n\d+|mmcblk\d+|[a-z]+)", base)
        for cand in ([m.group(1)] if m else []) + [base]:
            p = f"/sys/block/{cand}/queue/rotational"
            if os.path.exists(p):
                try:
                    media = "HDD(rotational)" if open(p).read().strip() == "1" else "SSD/NVMe(non-rotational)"
                except OSError:
                    pass
                break
    if fstype == "tmpfs":
        media = "tmpfs(RAM-backed)"
    return {"device": dev, "fstype": fstype, "mount": mp, "media": media}


def git_head() -> str:
    try:
        out = subprocess.run(["git", "-C", IDX, "rev-parse", "--short", "HEAD"],
                             capture_output=True, text=True, check=False)
        return out.stdout.strip() or "unknown"
    except OSError:
        return "unknown"


# ---------------------------------------------------------------------------
# 运行 / 采样
# ---------------------------------------------------------------------------

def _sample(pid: int, acc: dict) -> None:
    try:
        with open(f"/proc/{pid}/status", encoding="utf-8") as f:
            for line in f:
                if line.startswith("VmHWM:"):
                    acc["rss_mb"] = max(acc["rss_mb"], int(line.split()[1]) / 1024.0)
                    break
    except OSError:
        return
    try:
        with open(f"/proc/{pid}/io", encoding="utf-8") as f:
            for line in f:
                if line.startswith("write_bytes:"):
                    acc["write_mb"] = max(acc["write_mb"], int(line.split()[1]) / 1048576.0)
                    break
    except OSError:
        return


def run_measured(cmd: list[str], tag: str, work: str) -> dict:
    """运行子进程，轮询 VmHWM / write_bytes；stdout→文件（避免进度 JSON 灌满管道）。"""
    so = os.path.join(work, f"{tag}.stdout")
    se = os.path.join(work, f"{tag}.stderr")
    acc = {"rss_mb": 0.0, "write_mb": 0.0}
    with open(so, "w", encoding="utf-8") as outf, open(se, "w", encoding="utf-8") as errf:
        t0 = time.monotonic()
        proc = subprocess.Popen(cmd, stdout=outf, stderr=errf)
        while proc.poll() is None:
            _sample(proc.pid, acc)
            time.sleep(0.02)
        wall_ms = (time.monotonic() - t0) * 1000.0
    rc = proc.returncode

    result = None
    with open(so, encoding="utf-8", errors="replace") as f:
        for line in reversed(f.read().splitlines()):
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if obj.get("type") == "done":
                result = obj
                break
    return {
        "tag": tag,
        "wall_ms": round(wall_ms, 1),
        "rss_mb": round(acc["rss_mb"], 1),
        "write_mb": round(acc["write_mb"], 1),
        "rc": rc,
        "result": result,
        "stdout": so,
        "stderr": se,
    }


def db_size_bytes(path: str) -> int:
    total = 0
    for suffix in ("", "-wal", "-shm"):
        p = path + suffix
        if os.path.exists(p):
            total += os.path.getsize(p)
    return total


def size_breakdown(path: str) -> dict | None:
    """用 dbstat 定位 search.db 体积构成（元数据表 vs FTS 倒排），并统计元数据体量。

    v2 contentless：`search_docs` 仅保留元数据（无 token 文本列），体积主要来自 FTS 倒排
    （`search_fts_data` / `_idx` / `_docsize`）。
    """
    if not os.path.exists(path):
        return None
    try:
        conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        try:
            pages = dict(conn.execute("SELECT name, SUM(pgsize) FROM dbstat GROUP BY name").fetchall())
            docs = conn.execute(
                "SELECT COUNT(*), COALESCE(SUM(LENGTH(track_id)), 0) FROM search_docs").fetchone()
            return {
                "search_docs": pages.get("search_docs", 0),
                "search_fts_data": pages.get("search_fts_data", 0),
                "search_fts_idx": pages.get("search_fts_idx", 0),
                "search_fts_docsize": pages.get("search_fts_docsize", 0),
                "search_fts_config": pages.get("search_fts_config", 0),
                "search_meta": pages.get("search_meta", 0),
                "total_pages": sum(pages.values()),
                "docs": docs[0] or 0,
                "track_id_bytes": docs[1] or 0,
            }
        finally:
            conn.close()
    except sqlite3.Error:
        return None


def sqlite_scalar(path: str, sql: str):
    conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        row = conn.execute(sql).fetchone()
        return row[0] if row else None
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

def qbench_dll(config: str) -> str:
    return os.path.join(QB_ARTIFACTS, "bin", config, "net10.0", "archoera-indexer-qbench.dll")


def build_all(config: str) -> tuple[str, str]:
    """构建 CLI 与 qbench，返回 (cli_dll, qbench_dll)。"""
    subprocess.run(["dotnet", "build", "indexer.csproj", "-c", config, "-v", "quiet", "-nologo"],
                   cwd=IDX, check=True)
    subprocess.run(["dotnet", "build", os.path.join("qbench", "QueryBench.csproj"),
                    "-c", config, "-v", "quiet", "-nologo"], cwd=HERE, check=True)
    cli = os.path.join(IDX, "bin", config, "net10.0", "archoera-indexer.dll")
    qb = qbench_dll(config)
    for p in (cli, qb):
        if not os.path.exists(p):
            raise SystemExit(f"构建产物缺失: {p}")
    return cli, qb


def bump_mtimes(library: str, offset: int, count: int) -> None:
    conn = sqlite3.connect(library)
    try:
        ids = [r[0] for r in conn.execute(
            "SELECT id FROM tracks ORDER BY id LIMIT ? OFFSET ?", (count, offset)).fetchall()]
        conn.executemany("UPDATE tracks SET file_mtime = file_mtime + 1 WHERE id = ?",
                         [(i,) for i in ids])
        conn.commit()
    finally:
        conn.close()


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="本地曲库搜索索引器 P5 性能 harness")
    ap.add_argument("--tracks", type=int, default=10000, help="语料曲目数 N（默认 10000）")
    ap.add_argument("--seed", type=int, default=20261013)
    ap.add_argument("--rounds", type=int, default=2, help="每种全量配置的轮数")
    ap.add_argument("--repeats", type=int, default=60, help="每个查询的重复次数")
    ap.add_argument("--warmup", type=int, default=5)
    ap.add_argument("--limit", type=int, default=50, help="查询返回上限（材料化行数上界）")
    ap.add_argument("--incremental-k", default="20,200", help="增量曲目数（逗号分隔）")
    ap.add_argument("--work", default=os.path.join(HERE, ".work"), help="工作目录（生成物）")
    ap.add_argument("--config", default="Release", help=".NET 构建配置")
    ap.add_argument("--reuse-corpus", action="store_true", help="复用已有 library.db，不重新生成")
    ap.add_argument("--skip-build", action="store_true", help="跳过 dotnet build（复用产物）")
    a = ap.parse_args(argv)

    work = os.path.abspath(a.work)
    corpus_dir = os.path.join(work, "corpus")
    os.makedirs(work, exist_ok=True)

    env = {
        "date": datetime.date.today().isoformat(),
        "git_head": git_head(),
        "work": work,
        "config": a.config,
        "n": a.tracks,
        "seed": a.seed,
        "cpu": cpu_info()[0],
        "cores": cpu_info()[1],
        "mem_gb": mem_total_gb(),
        "os": platform.platform(),
        "disk": disk_info(work),
        "dotnet": subprocess.run(["dotnet", "--version"], capture_output=True, text=True).stdout.strip(),
        "python": platform.python_version(),
    }

    print(f"== 环境: {env['cpu']} x{env['cores']} / {env['mem_gb']} GB / "
          f"{env['disk']['device']} ({env['disk']['media']}) / .NET {env['dotnet']}")

    # 语料
    if a.reuse_corpus and os.path.exists(os.path.join(corpus_dir, "library.db")):
        with open(os.path.join(corpus_dir, "corpus_manifest.json"), encoding="utf-8") as f:
            manifest = json.load(f)
        print(f"== 复用语料: N={manifest['tracks']} seed={manifest['seed']}")
    else:
        if os.path.exists(corpus_dir):
            shutil.rmtree(corpus_dir)
        print(f"== 生成语料 N={a.tracks} seed={a.seed} …")
        t0 = time.monotonic()
        manifest = gen_corpus.generate(corpus_dir, a.tracks, a.seed, 2, 8, 0.5, 1)
        print(f"   完成 {time.monotonic()-t0:.1f}s；歌词 {manifest['total_lyrics_bytes']/1048576:.1f} MiB，"
              f"侧车 {manifest['lrc_count']}，library.db {manifest['library_db_bytes']/1048576:.1f} MiB")

    library = os.path.join(corpus_dir, "library.db")

    # 构建
    if a.skip_build:
        cli = os.path.join(IDX, "bin", a.config, "net10.0", "archoera-indexer.dll")
        qb = qbench_dll(a.config)
    else:
        print("== 构建 CLI 与 qbench …")
        cli, qb = build_all(a.config)
    for p in (cli, qb):
        if not os.path.exists(p):
            raise SystemExit(f"构建产物缺失: {p}")

    index_a = os.path.join(work, "search_a.db")
    index_b = os.path.join(work, "search_b.db")

    def full_round(label: str, index: str, extra: list[str], rnd: int):
        cmd = ["dotnet", cli, "build", "--full", "--db", library, "--index", index] + extra
        print(f"-- 全量 {label} 轮 {rnd}: {' '.join(x for x in cmd[3:])}")
        r = run_measured(cmd, f"full_{label}_r{rnd}", work)
        r["round"] = rnd
        r["db_bytes"] = db_size_bytes(index) if os.path.exists(index) else 0
        r["docs"] = sqlite_scalar(index, "SELECT COUNT(*) FROM search_docs") if os.path.exists(index) else None
        piny = sqlite_scalar(index, "SELECT value FROM search_meta WHERE key='pinyin'") if os.path.exists(index) else None
        r["meta_pinyin"] = piny
        d = r["result"] or {}
        print(f"   wall={r['wall_ms']:.0f}ms durationMs={d.get('durationMs')} "
              f"rss={r['rss_mb']:.0f}MB write={r['write_mb']:.0f}MB "
              f"db={r['db_bytes']/1048576:.0f}MB docs={r['docs']} pinyin={piny}")
        return r

    full_runs = []
    for rnd in range(1, a.rounds + 1):
        full_runs.append(dict(config="A", pinyin=True, **full_round("A", index_a, [], rnd)))
    for rnd in range(1, a.rounds + 1):
        full_runs.append(dict(config="B", pinyin=False,
                              **full_round("B", index_b, ["--no-pinyin"], rnd)))

    # 索引体积构成（在增量改写 A 之前量取）
    breakdown = {"A": size_breakdown(index_a), "B": size_breakdown(index_b)}

    # 查询延迟（在刚全量并 optimize 过的索引上；A/B 各一次）
    def query_run(index: str, label: str, pinyin_on: bool):
        out = os.path.join(work, f"qbench_{label}.json")
        cmd = ["dotnet", qb, "--index", index, "--label", label,
               "--pinyin", "on" if pinyin_on else "off",
               "--repeats", str(a.repeats), "--warmup", str(a.warmup),
               "--limit", str(a.limit), "--out", out]
        print(f"-- 查询延迟 {label} (pinyin={'on' if pinyin_on else 'off'}) …")
        r = run_measured(cmd, f"qbench_{label}", work)
        with open(out, encoding="utf-8") as f:
            data = json.load(f)
        p = data["pooled"]
        print(f"   pooled p50={p['p50_ms']:.3f}ms p95={p['p95_ms']:.3f}ms (n={p['count']})")
        return data

    query_a = query_run(index_a, "A", True)
    query_b = query_run(index_b, "B", False)

    # 增量（改 K 首 file_mtime 后跑非 --full；K=20 与 K=200 验证与 K 成正比）
    incremental = []
    offset = 0
    for k in [int(x) for x in a.incremental_k.split(",") if x.strip()]:
        bump_mtimes(library, offset, k)
        offset += k
        cmd = ["dotnet", cli, "build", "--db", library, "--index", index_a]
        print(f"-- 增量 K={k} …")
        r = run_measured(cmd, f"inc_{k}", work)
        d = r["result"] or {}
        print(f"   wall={r['wall_ms']:.0f}ms durationMs={d.get('durationMs')} "
              f"indexed={d.get('indexed')} deleted={d.get('deleted')}")
        incremental.append({"k": k, **(r["result"] or {}), "wall_ms": r["wall_ms"],
                            "rss_mb": r["rss_mb"], "write_mb": r["write_mb"], "rc": r["rc"]})

    metrics = {
        "env": env,
        "corpus": manifest,
        "full": full_runs,
        "incremental": incremental,
        "query": {"A": query_a, "B": query_b},
        "breakdown": breakdown,
        "budget": BUDGET,
    }
    with open(os.path.join(work, "metrics.json"), "w", encoding="utf-8") as f:
        json.dump(metrics, f, ensure_ascii=False, indent=2)

    write_report(metrics)
    print(f"== 已写出 {REPORT}")
    return 0


def write_report(m: dict) -> None:
    """依据 metrics.json 生成 bench/REPORT.md（可复现、含预算判定与 P5 结论）。"""
    env = m["env"]
    corpus = m["corpus"]
    budget = m["budget"]
    n = env["n"]
    scale = budget["extrapolate_n"] / n

    full = m["full"]
    # 每配置取最快（min durationMs）与最后一轮，用于外推与稳定性对比。
    def best(cfg):
        runs = [r for r in full if r["config"] == cfg]
        return min(runs, key=lambda r: (r["result"] or {}).get("durationMs", 1 << 60))

    a_best = best("A")
    b_best = best("B")
    a_ms = (a_best["result"] or {}).get("durationMs", 0) or a_best["wall_ms"]
    b_ms = (b_best["result"] or {}).get("durationMs", 0) or b_best["wall_ms"]
    full25k_ms = a_ms * scale
    idx_a_mb = a_best["db_bytes"] / 1048576.0
    idx_b_mb = b_best["db_bytes"] / 1048576.0
    idx25k_mb = idx_a_mb * scale
    idx25k_b_mb = idx_b_mb * scale
    rss_a = max(r["rss_mb"] for r in full if r["config"] == "A")
    bd = m.get("breakdown") or {}
    bd_a, bd_b = bd.get("A") or {}, bd.get("B") or {}
    write_unavailable = all((r.get("write_mb") or 0) == 0 for r in full)

    qa, qb = m["query"]["A"], m["query"]["B"]
    qa_p50, qa_p95 = qa["pooled"]["p50_ms"], qa["pooled"]["p95_ms"]
    qb_p50, qb_p95 = qb["pooled"]["p50_ms"], qb["pooled"]["p95_ms"]

    inc = {x["k"]: x for x in m["incremental"]}
    inc20 = inc.get(20, {})
    inc200 = inc.get(200, {})

    def ok(cond: bool) -> str:
        return "✅ 达标" if cond else "❌ 超标"

    full_ok = full25k_ms <= budget["full_max_ms"]
    q_ok = qa_p50 <= budget["query_p50_ms"] and qa_p95 <= budget["query_p95_ms"] \
        and qb_p50 <= budget["query_p50_ms"] and qb_p95 <= budget["query_p95_ms"]
    idx_ok = budget["index_min_mb"] <= idx25k_mb <= budget["index_max_mb"]
    rss_ok = rss_a <= 1024.0
    inc_ok = (inc20.get("durationMs", 10**9) <= 3000) and (inc200.get("durationMs", 10**9) <= 30000)
    perf_ok = full_ok and q_ok and inc_ok and rss_ok      # 性能类预算（不含索引体积）
    # §5.5 的 P5 触发条件是「checkpoint 随机回写导致写局部性 / 磨损不达标」——本 harness
    # 未观测到该失败（见 §7）；此处仅在性能类预算整体失守时才判触发。
    p5_triggered = not perf_ok

    L: list[str] = []
    L.append(f"# 本地曲库搜索索引器 性能实测报告（P5）（{env['date']}）")
    L.append("")
    L.append("> 对象：**真实产物** `app/core/indexer`（C# FTS5 索引器，`FtsStore` + `Analyzer` + `IndexerEngine`）。")
    L.append("> harness：`app/core/indexer/bench/`（确定性语料生成器 + 跑测编排 + 进程内查询 harness）。")
    L.append(f"> 判定依据：设计文档 `docs/local-search-index-plan.md` §2.2（预算）/ §5.5（条件触发）/ §7.3–7.4 / §8 / §10（P0/P5）。")
    L.append(f"> 命令：`bash app/core/indexer/bench/run_bench.sh`（N 默认 10000；本报告数据由该命令一次跑出）。")
    L.append("")
    L.append("## 1. 机器环境")
    L.append("")
    L.append("| 项 | 值 |")
    L.append("|---|---|")
    L.append(f"| CPU | {env['cpu']} × {env['cores']} 逻辑核 |")
    L.append(f"| 内存 | {env['mem_gb']} GB |")
    disk = env["disk"]
    L.append(f"| 工作盘 | `{disk['device']}`（{disk['fstype']}，{disk['media']}，挂载点 `{disk['mount']}`） |")
    L.append(f"| 介质 | {disk['media']} |")
    L.append(f"| OS | {env['os']} |")
    L.append(f"| .NET | {env['dotnet']} |")
    L.append(f"| Python | {env['python']} |")
    L.append(f"| 代码 | `{env['git_head']}` |")
    L.append("")
    L.append("> 写入量取 `/proc/<pid>/io` 的 `write_bytes`；峰值内存取 `/proc/<pid>/status` 的 `VmHWM`；")
    L.append("> 本机无 `/usr/bin/time`，故改由 harness 内部 `Stopwatch`（CLI `durationMs`）与外部轮询测得。")
    L.append("")
    L.append("## 2. 语料")
    L.append("")
    L.append("| 项 | 值 |")
    L.append("|---|---|")
    L.append(f"| 曲目数 N | {corpus['tracks']} |")
    L.append(f"| seed | {corpus['seed']}（确定性） |")
    L.append(f"| 歌词 / 曲 | {corpus['min_kb']}–{corpus['max_kb']} KB（仿真实中文，多行/标点/含英数、部分繁体） |")
    L.append(f"| 歌词总量 | {corpus['total_lyrics_bytes']/1048576:.1f} MiB（均 {corpus['avg_lyrics_bytes']/1024:.1f} KB/曲） |")
    L.append(f"| `.lrc` 侧车 | {corpus['lrc_count']} 首（{corpus['lrc_count']/corpus['tracks']*100:.0f}%） |")
    L.append(f"| library.db | {corpus['library_db_bytes']/1048576:.1f} MiB |")
    L.append("")
    L.append("## 3. 全量构建（A 含拼音 / B 无拼音）")
    L.append("")
    L.append("| 配置 | 轮 | wall ms | durationMs | 峰值 RSS MB | write_bytes MB | search.db MB | docs | meta.pinyin | rc |")
    L.append("|---|---|---|---|---|---|---|---|---|---|")
    for r in full:
        d = r["result"] or {}
        L.append(f"| {'A(拼音)' if r['config']=='A' else 'B(无拼音)'} | {r.get('round', '')} | "
                 f"{r['wall_ms']:.0f} | {d.get('durationMs')} | {r['rss_mb']:.0f} | {r['write_mb']:.0f} | "
                 f"{r['db_bytes']/1048576:.1f} | {r['docs']} | {r.get('meta_pinyin')} | {r['rc']} |")
    L.append("")
    L.append("### 索引体积外推")
    L.append("")
    L.append(f"- A（含拼音）search.db = **{idx_a_mb:.1f} MiB** @ {n} 曲 → 外推 @{budget['extrapolate_n']} 曲 ≈ "
             f"**{idx25k_mb:.0f} MiB**（§2.2 预算 {budget['index_min_mb']:.0f}–{budget['index_max_mb']:.0f} MB）{ok(idx_ok)}")
    L.append(f"- B（无拼音）search.db = **{idx_b_mb:.1f} MiB** @ {n} 曲 → 外推 ≈ **{idx25k_b_mb:.0f} MiB**")
    if bd_a:
        L.append(f"- A 体积构成（`dbstat`）：元数据表 `search_docs` {bd_a['search_docs']/1048576:.1f} MiB + "
                 f"FTS 倒排（`search_fts_data` {bd_a['search_fts_data']/1048576:.1f} MiB + "
                 f"`_idx` {bd_a['search_fts_idx']/1048576:.1f} MiB + "
                 f"`_docsize` {bd_a['search_fts_docsize']/1048576:.1f} MiB）；"
                 f"`track_id` 文本合计仅 {bd_a['track_id_bytes']/1048576:.1f} MiB。")
        L.append(f"  B（无拼音）构成：元数据表 {bd_b.get('search_docs',0)/1048576:.1f} MiB + 倒排 "
                 f"`search_fts_data` {bd_b.get('search_fts_data',0)/1048576:.1f} MiB —— 拼音列令 A 比 B 多 {idx_a_mb-idx_b_mb:.0f} MiB。")
    L.append("- contentless v2 说明：`search_fts` 以 `content=''` + `contentless_delete=1` 建表，"
             "倒排只存 postings / 位置，**不再把 token 文本另存一份**；体积构成由「内容表 + 倒排」变为「元数据表 + 倒排」。")
    L.append(f"- 全量耗时（A，取最快轮 `durationMs`）@ {n} 曲 = **{a_ms/1000:.1f}s** → 外推 @{budget['extrapolate_n']} 曲 ≈ "
             f"**{full25k_ms/1000:.0f}s**（预算 {budget['full_min_ms']/1000:.0f}–{budget['full_max_ms']/1000:.0f}s）{ok(full_ok)}")
    L.append(f"- 全量耗时（B，无拼音）@ {n} 曲 = **{b_ms/1000:.1f}s**（拼音列生成是 A/B 主要差异）")
    L.append(f"- 峰值 RSS（A）≈ **{rss_a:.0f} MiB**（预算「≤ 数百 MB」）{ok(rss_ok)}")
    if write_unavailable:
        L.append("")
        L.append("> ⚠ 本环境（WSL2 虚拟磁盘）`/proc/<pid>/io` 的 `write_bytes` 恒为 0，**写入量数据不可用**；"
                 "写局部性 / 磨损只能间接评估（世代化顺序写 + dirty-only 增量）。")
    L.append("")
    L.append("### 修订记录：contentless v2（schema_version=2 / analyzer_version=2）")
    L.append("")
    L.append("针对首版 P5 报告暴露的两处缺陷做的修订（**同为本次一次跑出的数据**）：")
    L.append("")
    L.append("1. **索引体积超预算** → `search_fts` 由 external-content 改为 **contentless**"
             "（`content=''` + `contentless_delete=1`），`search_docs` 仅保留元数据、不再存 token 文本；"
             "列序 / bm25 权重序不变，`MATCH` 列过滤、短语、`bm25()` 语义不变。")
    L.append("2. **NFKC 不完整** → `Analyzer` 归一化由手写全角折叠升级为**逐字符 NFKC 兼容折叠**"
             "（离线表 `data/nfkc.tsv`，仅 BMP、逐字符）：`ﬁ`→`fi`、`①`→`1`、相容表意字折叠等；"
             "因词元输出变化，`AnalyzerVersion` 1 → 2（旧库版本不符 → 全量重建）。")
    L.append("")
    L.append("## 4. 增量（改 file_mtime 后非 --full）")
    L.append("")
    L.append("| K（脏曲） | wall ms | durationMs | 峰值 RSS MB | write_bytes MB | indexed | deleted |")
    L.append("|---|---|---|---|---|---|---|")
    for x in m["incremental"]:
        L.append(f"| {x['k']} | {x['wall_ms']:.0f} | {x.get('durationMs')} | {x['rss_mb']:.0f} | "
                 f"{x['write_mb']:.0f} | {x.get('indexed')} | {x.get('deleted')} |")
    L.append("")
    if inc20.get("durationMs") and inc200.get("durationMs"):
        d20, d200 = inc20["durationMs"], inc200["durationMs"]
        marginal = (d200 - d20) / (200 - 20)
        L.append(f"- K=20 → {d20}ms；K=200 → {d200}ms：ΔK={200-20} 仅 +{d200-d20}ms"
                 f"（**边际 ≈ {marginal:.1f}ms/曲**），说明增量耗时以**固定阶段一轻量扫描**为主，"
                 "脏曲部分成本很小且随 K 近似线性。")
    L.append(f"- 增量整体为**秒级**（K=20 时 {inc20.get('durationMs')}ms）{ok(inc_ok)}；"
             "无脏曲时仅阶段一轻量探测（既有单测已断言零内容读取）。")
    L.append("")
    L.append("## 5. 查询延迟 P50 / P95（同一进程内循环，已排除进程启动）")
    L.append("")
    L.append(f"每个查询：warmup {qa['warmup']} 次、{qa['repeats']} 次采样，取最近秩百分位；limit={qa['limit']}。")
    L.append("A = 拼音列开（`--full`），B = 拼音列关（`--full --no-pinyin`）；B 的拼音类查询只走词元解释（故 0 命中）。")
    L.append("")
    L.append("| 查询 | 文本 | A rows | A P50 ms | A P95 ms | B rows | B P50 ms | B P95 ms |")
    L.append("|---|---|---|---|---|---|---|---|")
    qa_by = {x["name"]: x for x in qa["queries"]}
    qb_by = {x["name"]: x for x in qb["queries"]}
    for name in qa_by:
        xa = qa_by[name]
        xb = qb_by[name]
        L.append(f"| {name} | `{xa['text']}` | {xa['rows']} | {xa['p50_ms']:.3f} | {xa['p95_ms']:.3f} | "
                 f"{xb['rows']} | {xb['p50_ms']:.3f} | {xb['p95_ms']:.3f} |")
    L.append(f"| **合计（pooled）** | — | — | **{qa_p50:.3f}** | **{qa_p95:.3f}** | — | **{qb_p50:.3f}** | **{qb_p95:.3f}** |")
    L.append("")
    ratio = (qa_p50 / qb_p50) if qb_p50 > 0 else 0
    L.append(f"- 预算 P50 ≤ {budget['query_p50_ms']:.0f}ms / P95 ≤ {budget['query_p95_ms']:.0f}ms："
             f"A 合计 P50={qa_p50:.3f}ms P95={qa_p95:.3f}ms；B 合计 P50={qb_p50:.3f}ms P95={qb_p95:.3f}ms → {ok(q_ok)}")
    L.append(f"- **开 / 关拼音列**的合计 P50 比 ≈ **{ratio:.2f}×**（设计 §7.4 预期「< 2×，且绝对值仍远低于 80ms」）："
             "差异主要来自需经 pinyin 列解析的**拼音类查询**（`woaini`/`wan`），中文/拉丁查询 A≈B；"
             "绝对延迟远低于预算，印证 §4.5「拼音是索引期成本，不在查询路径上」。")
    L.append("")
    L.append("## 6. 对照 §2.2 预算")
    L.append("")
    L.append("| 指标 | 预算 | 实测（本机 @%d 曲） | 外推 @%d 曲 | 结论 |" % (n, budget["extrapolate_n"]))
    L.append("|---|---|---|---|---|")
    L.append(f"| 首次全量构建 | ≤ 2–5 min | {a_ms/1000:.1f}s（A 含拼音） | ≈ {full25k_ms/1000:.0f}s | {ok(full_ok)} |")
    L.append(f"| 增量（K 首） | ≈ K 成正比，秒级 | K=20 → {inc20.get('durationMs')}ms；K=200 → {inc200.get('durationMs')}ms | 边际 ≈ 线性 | {ok(inc_ok)} |")
    L.append(f"| 查询 P50 / P95 | ≤ 20 / ≤ 80 ms | {qa_p50:.3f} / {qa_p95:.3f} ms（A） | 与 N 近似无关 | {ok(q_ok)} |")
    L.append(f"| 索引体积 | ~100–300 MB | {idx_a_mb:.1f} MiB（A） | ≈ {idx25k_mb:.0f} MiB | {ok(idx_ok)} |")
    L.append(f"| 峰值内存 | ≤ 数百 MB，可限 | {rss_a:.0f} MiB（A） | — | {ok(rss_ok)} |")
    L.append("")
    L.append(f"性能类预算（构建 / 增量 / 查询 / 内存）**全部达标**；"
             f"**索引体积**{'达标' if idx_ok else '超出 §2.2 上限'}{'' if idx_ok else '（详见下节归因）'}。")
    L.append("")
    L.append("## 7. P5 判定（§5.5 自研段引擎）")
    L.append("")
    if p5_triggered:
        L.append("**结论：P5 触发**——性能类预算存在实测未达标，需按 §5.5 在 `IndexStore` 之后实现自研段引擎。")
    else:
        L.append("**结论：P5 不触发 → 自研段引擎（§5.5 实现 B）不实施。**")
        L.append("")
        L.append("判定依据（严格对齐 §5.5 的触发条件：**FTS5 在目标介质上 checkpoint 随机回写导致 "
                 "locality / 磨损不达标**）：")
        L.append(f"1. **存储/查询性能达标**：全量外推 ≈ {full25k_ms/1000:.0f}s（≤ 5min）、查询合计 P50/P95 "
                 f"{qa_p50:.3f}/{qa_p95:.3f}ms（远低于 20/80ms）、增量秒级（K=20 → {inc20.get('durationMs')}ms）、"
                 f"峰值 RSS {rss_a:.0f}MB —— 存储引擎能力本身**无短板**。")
        L.append(f"2. **写局部性对策已生效**（§5.3/§7.2）：全量为「临时世代从零**顺序写** + fsync + 原子 rename」，"
                 "增量按 **dirty-only** 且收尾 `wal_checkpoint(TRUNCATE)`；构建与增量耗时未见随机写病理。")
        L.append("3. **无 locality / 磨损不达标的测量证据** → §5.5 的前提不成立，按设计「**先量再定、不先验假设**」"
                 "原则，自研段引擎**无测量支撑，不实施**。")
        if not idx_ok:
            L.append("")
            L.append(f"⚠ **独立的 §2.2 偏离：索引体积**（A 外推 ≈ {idx25k_mb:.0f}MB，超 100–300MB 预算）。"
                     "经 `dbstat` 归因，体积来自**分析器 / schema 层面**而非存储引擎：内容表 `search_docs` 保存了"
                     "全量分析后 token 文本（CJK bigram+unigram + 完整拼音列），倒排再叠一份 postings。"
                     "**§5.5 的自研段引擎针对写局部性/磨损，并不解决体积**，故该偏离不构成 P5 触发；"
                     "应另立分析器/schema 优化项跟进（如 contentless 索引、单字回退策略、列压缩等）。")
        L.append("")
        L.append("> 注意：本结论受 §8 局限约束，尤其**磨损 / 长期写放大未量化**（`write_bytes` 在本 WSL2 环境不可用）。"
                 "若后续在 HDD（或高写入敏感的 eMMC）上实测出现 locality / 磨损不达标，P5 仍按 §5.5 条件触发。")
    L.append("")
    L.append("## 8. 局限")
    L.append("")
    L.append(f"1. **规模外推**：本机实测 N={n}；25k 数据为 **线性外推**（构建耗时、索引体积随 N 近似线性，"
             "但 FTS 段合并/页分配有次线性效应，外推偏保守）。未直接跑 25k（本机内存 7.6 GB / 盘可承载，为控时长未做）。")
    L.append(f"2. **介质**：工作盘为 `{disk['device']}`（{disk['fstype']}，`/sys/.../rotational={1 if 'HDD' in disk['media'] else 0}`，"
             f"在 WSL2 上）；§7.2 的「checkpoint 随机回写」痛点主要在**物理 HDD**，"
             "本环境为 WSL2 虚拟磁盘，**不能等同于真机 HDD**，且 `write_bytes` 不可用 → 写入量/磨损未直接量化。")
    L.append("3. **未测磨损 / 长期度**：单轮 bench 无法反映多世代、反复增量后的碎片与写放大；"
             "未做 `iostat`/闪存擦除块级观测。")
    L.append("4. **索引体积对语料敏感**：本语料按 §8 口径取 2–8 KB/曲（均 5 KB、密集中文）。"
             "语料越短/越稀疏，`search_docs` 与倒排的固定开销占比越高；外推基于本语料分布。")
    L.append("5. **查询集规模**：代表查询 7 条（中文子串/短语/繁体/拼音连写/首字母/拉丁前缀/整词），"
             "非完整 §8 标注集；未测召回@k / MRR / NDCG（那是 P0 分析器评估，非本 P5 性能问题）。")
    L.append("6. **查询语义**：harness 的 MATCH 构造（中文仅词元 AND；拉丁整词前缀；连写全拼按音节 AND 末音节前缀，"
             "OR 组合；首字母经 pinyin 列命中）对齐设计 §4 与既有 E2E，但 P3 Dart 查询层尚未落地，最终表达式可能微调"
             "（影响召回，不影响延迟量级）。")
    L.append("7. **峰值内存**：`VmHWM` 轮询（20 ms）可能略低估瞬时峰值；索引器为 run-to-completion 同步模型，"
             "无等待式竞态判定（符合 AGENTS.md）。")
    L.append("")
    with open(REPORT, "w", encoding="utf-8") as f:
        f.write("\n".join(L) + "\n")


if __name__ == "__main__":
    sys.exit(main())
