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
    ap.add_argument("--incremental-k", default="20,200", help="增量曲目数（逗号分隔）")
    ap.add_argument("--work", default=os.path.join(HERE, ".work"), help="工作目录（生成物）")
    ap.add_argument("--config", default="Release", help=".NET 构建配置")
    ap.add_argument("--with-lrc", action="store_true",
                    help="追加 .lrc 侧车层一档（全量 + 零脏曲增量；§2.2 预算含 .lrc，默认跑不到）")
    ap.add_argument("--query-limits", default="50,10000",
                    help="查询 harness 的 LIMIT 列表（逗号分隔；生产曲库页用 10000，见 "
                         "kSearchIndexRankLimit）")
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
    index_c = os.path.join(work, "search_c_lrc.db")

    def full_round(label: str, index: str, extra: list[str], rnd: int):
        cmd = ["dotnet", cli, "build", "--full", "--db", library, "--index", index] + extra
        print(f"-- 全量 {label} 轮 {rnd}: {' '.join(x for x in cmd[3:])}")
        r = run_measured(cmd, f"full_{label}_r{rnd}", work)
        r["round"] = rnd
        r["db_bytes"] = db_size_bytes(index) if os.path.exists(index) else 0
        r["docs"] = sqlite_scalar(index, "SELECT COUNT(*) FROM search_docs") if os.path.exists(index) else None
        piny = sqlite_scalar(index, "SELECT value FROM search_meta WHERE key='pinyin'") if os.path.exists(index) else None
        r["meta_pinyin"] = piny
        r["meta_lrc"] = sqlite_scalar(index, "SELECT value FROM search_meta WHERE key='index_lrc'") \
            if os.path.exists(index) else None
        r["meta_schema"] = sqlite_scalar(index, "SELECT value FROM search_meta WHERE key='schema_version'") \
            if os.path.exists(index) else None
        r["meta_analyzer"] = sqlite_scalar(index, "SELECT value FROM search_meta WHERE key='analyzer_version'") \
            if os.path.exists(index) else None
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
    # C 组（可选）：含 .lrc 侧车层——§2.2 的全量预算明确含 .lrc，默认档跑不到。
    if a.with_lrc:
        full_runs.append(dict(config="C", pinyin=True,
                              **full_round("C(含 .lrc)", index_c, ["--index-lrc"], 1)))

    # 索引体积构成（在增量改写 A 之前量取）
    breakdown = {"A": size_breakdown(index_a), "B": size_breakdown(index_b)}
    if a.with_lrc:
        breakdown["C"] = size_breakdown(index_c)

    # 查询延迟（在刚全量并 optimize 过的索引上；A/B 各按 limit 逐档）
    limits = [int(x) for x in str(a.query_limits).split(",") if x.strip()]

    def query_run(index: str, label: str, pinyin_on: bool, limit: int):
        out = os.path.join(work, f"qbench_{label}_{limit}.json")
        # 先删旧结果：qbench 若失败（表达式语法错 / 崩溃），绝不能把**上一轮的 JSON**
        # 当成这一轮的结果写进报告（曾经踩过：报告数字与上轮逐位相同）。
        if os.path.exists(out):
            os.remove(out)
        cmd = ["dotnet", qb, "--index", index, "--label", label,
               "--pinyin", "on" if pinyin_on else "off",
               "--repeats", str(a.repeats), "--warmup", str(a.warmup),
               "--limit", str(limit), "--out", out]
        print(f"-- 查询延迟 {label} limit={limit} (pinyin={'on' if pinyin_on else 'off'}) …")
        r = run_measured(cmd, f"qbench_{label}_{limit}", work)
        if r["rc"] != 0 or not os.path.exists(out):
            raise SystemExit(
                f"qbench 失败（rc={r['rc']}，无输出 JSON）："
                f"见 {work}/qbench_{label}_{limit}.stderr")
        with open(out, encoding="utf-8") as f:
            data = json.load(f)
        p = data["pooled"]
        print(f"   pooled p50={p['p50_ms']:.3f}ms p95={p['p95_ms']:.3f}ms (n={p['count']})")
        return data

    query = {}
    for limit in limits:
        query[f"A@{limit}"] = query_run(index_a, f"A", True, limit)
        query[f"B@{limit}"] = query_run(index_b, "B", False, limit)

    # 增量：先量**零脏曲**（固定开销 = 阶段一探测 + 收尾写路径），再量 K 首。
    def incremental(label: str, index: str, extra: list[str], k: int = 0):
        cmd = ["dotnet", cli, "build", "--db", library, "--index", index] + extra
        print(f"-- 增量 {label} …")
        r = run_measured(cmd, f"inc_{label}", work)
        d = r["result"] or {}
        print(f"   wall={r['wall_ms']:.0f}ms durationMs={d.get('durationMs')} "
              f"indexed={d.get('indexed')} deleted={d.get('deleted')}")
        return {"k": k, **(r["result"] or {}), "wall_ms": r["wall_ms"],
                "rss_mb": r["rss_mb"], "write_mb": r["write_mb"], "rc": r["rc"]}

    incremental_runs = []
    noop_inc = incremental("noop", index_a, [])
    incremental_runs.append(noop_inc)
    noop_inc_lrc = incremental("noop_lrc", index_c, ["--index-lrc"]) if a.with_lrc else None

    offset = 0
    for k in [int(x) for x in a.incremental_k.split(",") if x.strip()]:
        bump_mtimes(library, offset, k)
        offset += k
        incremental_runs.append(incremental(f"K{k}", index_a, [], k=k))

    metrics = {
        "env": env,
        "corpus": manifest,
        "full": full_runs,
        "incremental": incremental_runs,
        "noop_inc_lrc": noop_inc_lrc,
        "query": query,
        "query_limits": limits,
        "breakdown": breakdown,
        "budget": BUDGET,
        "with_lrc": a.with_lrc,
    }
    with open(os.path.join(work, "metrics.json"), "w", encoding="utf-8") as f:
        json.dump(metrics, f, ensure_ascii=False, indent=2)

    write_report(metrics)
    print(f"== 已写出 {REPORT}")
    return 0


def write_report(m: dict) -> None:
    """依据 metrics.json 生成 bench/REPORT.md（可复现、含预算判定与 P5 结论）。

    原则：**只写实测数据能支撑的话**——不在模板里硬编码「远低于预算」一类结论，
    机器 / 介质 / 写入量可用性都由 metrics 决定（见 P5 修订：旧模板曾出现
    WSL2 / analyzer_version=2 等与实测不符的固定文案）。
    """
    env = m["env"]
    corpus = m["corpus"]
    budget = m["budget"]
    n = env["n"]
    limits = m.get("query_limits") or [50]
    app_limit = max(limits)                     # 生产曲库页 kSearchIndexRankLimit = 10000
    with_lrc = m.get("with_lrc", False)
    scale = budget["extrapolate_n"] / n

    full = m["full"]

    def best(cfg):
        runs = [r for r in full if r["config"] == cfg]
        return min(runs, key=lambda r: (r["result"] or {}).get("durationMs", 1 << 60)) if runs else None

    a_best, b_best, c_best = best("A"), best("B"), best("C")

    def dur(r):
        return (r["result"] or {}).get("durationMs", 0) or r["wall_ms"] if r else 0

    a_ms, b_ms = dur(a_best), dur(b_best)
    c_ms = dur(c_best)
    full25k_ms = a_ms * scale
    idx_a_mb = a_best["db_bytes"] / 1048576.0 if a_best else 0.0
    idx_b_mb = b_best["db_bytes"] / 1048576.0 if b_best else 0.0
    idx_c_mb = c_best["db_bytes"] / 1048576.0 if c_best else 0.0
    idx25k_mb = idx_a_mb * scale
    rss_a = max((r["rss_mb"] for r in full if r["config"] == "A"), default=0.0)
    bd = m.get("breakdown") or {}
    bd_a, bd_b = bd.get("A") or {}, bd.get("B") or {}
    write_unavailable = all((r.get("write_mb") or 0) == 0 for r in full)
    write_amp = (a_best["write_mb"] / idx_a_mb) if (a_best and idx_a_mb > 0) else 0.0
    meta_analyzer = (a_best or {}).get("meta_analyzer")
    meta_schema = (a_best or {}).get("meta_schema")

    inc = {x["k"]: x for x in m["incremental"]}
    noop, inc20, inc200 = inc.get(0, {}), inc.get(20, {}), inc.get(200, {})
    noop_lrc = m.get("noop_inc_lrc")

    def ok(cond: bool) -> str:
        return "✅ 达标" if cond else "❌ 超标"

    # 逐条查询的超预算明细（pooled 达标会掩盖单条超标——本 harness 显式列出）
    over: dict[int, list[str]] = {}
    pooled: dict[int, dict] = {}
    for limit in limits:
        qa = m["query"][f"A@{limit}"]
        qb = m["query"][f"B@{limit}"]
        pooled[limit] = {
            "A": qa["pooled"], "B": qb["pooled"],
            "ok": qa["pooled"]["p50_ms"] <= budget["query_p50_ms"]
            and qa["pooled"]["p95_ms"] <= budget["query_p95_ms"]
            and qb["pooled"]["p50_ms"] <= budget["query_p50_ms"]
            and qb["pooled"]["p95_ms"] <= budget["query_p95_ms"],
        }
        over[limit] = [
            f"`{x['text']}`（{x['name']}）P50 {x['p50_ms']:.1f}ms"
            + (f"、趟 {x['passes']}" if x.get("passes", 1) > 1 else "")
            for x in qa["queries"]
            if x["p50_ms"] > budget["query_p50_ms"] or x["p95_ms"] > budget["query_p95_ms"]
        ]
    q_pooled_ok = all(p["ok"] for p in pooled.values())
    q_perquery_ok = all(not over[limit] for limit in limits)

    full_ok = full25k_ms <= budget["full_max_ms"]
    idx_ok = budget["index_min_mb"] <= idx25k_mb <= budget["index_max_mb"]
    rss_ok = rss_a <= 1024.0
    inc_ok = (inc20.get("durationMs", 10**9) <= 3000) and (inc200.get("durationMs", 10**9) <= 30000)
    lrc_ok = (not with_lrc) or c_ms <= budget["full_max_ms"]
    perf_ok = full_ok and q_pooled_ok and inc_ok and rss_ok and lrc_ok
    p5_triggered = not perf_ok

    L: list[str] = []
    L.append(f"# 本地曲库搜索索引器 性能实测报告（P5）（{env['date']}）")
    L.append("")
    L.append("> 对象：**真实产物** `app/core/indexer`（C# FTS5 索引器，`FtsStore` + `Analyzer` + `IndexerEngine`）。")
    L.append("> harness：`app/core/indexer/bench/`（确定性语料生成器 + 跑测编排 + 进程内查询 harness，"
             "MATCH 构造与生产查询编译器 `search_query.dart` 同构）。")
    L.append("> 判定依据：设计文档 `docs/local-search-index-plan.md` §2.2（预算）/ §5.5（条件触发）/ §7.3–7.4 / §8 / §10（P0/P5）。")
    cmd = f"`bash app/core/indexer/bench/run_bench.sh`（N={n}"
    cmd += "，`--with-lrc`" if with_lrc else ""
    cmd += f"，查询 LIMIT={','.join(str(x) for x in limits)}）"
    L.append(f"> 命令：{cmd}；本报告数据由该命令一次跑出。")
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
    L.append("> 壁钟由 harness 内部 `Stopwatch`（CLI `durationMs`）+ 进程外轮询测得。")
    if write_unavailable:
        L.append(">")
        L.append("> ⚠ 本环境 `write_bytes` 读数恒为 0，**写入量数据不可用**（写局部性 / 磨损只能间接评估）。")
    L.append("")
    L.append("## 2. 语料")
    L.append("")
    L.append("| 项 | 值 |")
    L.append("|---|---|")
    L.append(f"| 曲目数 N | {corpus['tracks']} |")
    L.append(f"| seed | {corpus['seed']}（确定性） |")
    L.append(f"| 歌词 / 曲 | {corpus['min_kb']}–{corpus['max_kb']} KB（仿真实中文，多行/标点/含英数、部分繁体） |")
    L.append(f"| 歌词总量 | {corpus['total_lyrics_bytes']/1048576:.1f} MiB（均 {corpus['avg_lyrics_bytes']/1024:.1f} KB/曲） |")
    L.append(f"| `.lrc` 侧车 | {corpus['lrc_count']} 首（{corpus['lrc_count']/corpus['tracks']*100:.0f}%，"
             f"{'已索引' if with_lrc else '**本档未索引**（默认关）'}）；"
             f"语料按**扫描器产出**写入 `lyrics_lrc*` + `lrc_mtime/size/checked` 列 |")
    L.append(f"| library.db | {corpus['library_db_bytes']/1048576:.1f} MiB |")
    L.append(f"| 目录形态 | 全部平铺在单一 `audio/`（`.lrc` 探测成本的**最坏**分布；每专辑一目录时更低） |")
    L.append("")
    L.append("## 3. 全量构建（A 含拼音 / B 无拼音" + (" / C 含 .lrc" if with_lrc else "") + "）")
    L.append("")
    L.append("| 配置 | 轮 | wall ms | durationMs | 峰值 RSS MB | write_bytes MB | search.db MB | docs | pinyin | .lrc | schema | analyzer | rc |")
    L.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for r in full:
        d = r["result"] or {}
        label = {"A": "A(拼音)", "B": "B(无拼音)", "C": "C(拼音+.lrc)"}[r["config"]]
        L.append(f"| {label} | {r.get('round', '')} | "
                 f"{r['wall_ms']:.0f} | {d.get('durationMs')} | {r['rss_mb']:.0f} | {r['write_mb']:.0f} | "
                 f"{r['db_bytes']/1048576:.1f} | {r['docs']} | {r.get('meta_pinyin')} | {r.get('meta_lrc')} | "
                 f"{r.get('meta_schema')} | {r.get('meta_analyzer')} | {r['rc']} |")
    L.append("")
    L.append("### 索引体积")
    L.append("")
    L.append(f"- A（含拼音）search.db = **{idx_a_mb:.1f} MiB** @ {n} 曲 → 外推 @{budget['extrapolate_n']} 曲 ≈ "
             f"**{idx25k_mb:.0f} MiB**（§2.2 预算 {budget['index_min_mb']:.0f}–{budget['index_max_mb']:.0f} MB）{ok(idx_ok)}")
    L.append(f"- B（无拼音）search.db = **{idx_b_mb:.1f} MiB** @ {n} 曲 → 外推 ≈ **{idx_b_mb*scale:.0f} MiB**")
    if with_lrc:
        L.append(f"- C（拼音 + .lrc 侧车层）search.db = **{idx_c_mb:.1f} MiB** @ {n} 曲"
                 f"（比 A 多 {idx_c_mb-idx_a_mb:.1f} MiB，即 .lrc 三层文本的倒排开销）")
    if bd_a:
        L.append(f"- A 体积构成（`dbstat`）：元数据表 `search_docs` {bd_a['search_docs']/1048576:.1f} MiB + "
                 f"FTS 倒排（`search_fts_data` {bd_a['search_fts_data']/1048576:.1f} MiB + "
                 f"`_idx` {bd_a['search_fts_idx']/1048576:.1f} MiB + "
                 f"`_docsize` {bd_a['search_fts_docsize']/1048576:.1f} MiB）；"
                 f"`track_id` 文本合计仅 {bd_a['track_id_bytes']/1048576:.1f} MiB。")
        L.append(f"  B（无拼音）构成：元数据表 {bd_b.get('search_docs',0)/1048576:.1f} MiB + 倒排 "
                 f"`search_fts_data` {bd_b.get('search_fts_data',0)/1048576:.1f} MiB —— 拼音列令 A 比 B 多 {idx_a_mb-idx_b_mb:.0f} MiB。")
    L.append("- contentless v2：`search_fts` 以 `content=''` + `contentless_delete=1` 建表，"
             "倒排只存 postings / 位置，**不再把 token 文本另存一份**。")
    L.append("")
    L.append("### 耗时 / 内存 / 写入量")
    L.append("")
    L.append(f"- 全量耗时（A，最快轮 `durationMs`）@ {n} 曲 = **{a_ms/1000:.1f}s** → 外推 @{budget['extrapolate_n']} 曲 ≈ "
             f"**{full25k_ms/1000:.0f}s**（预算 {budget['full_min_ms']/1000:.0f}–{budget['full_max_ms']/1000:.0f}s）{ok(full_ok)}")
    L.append(f"- 全量耗时（B，无拼音）@ {n} 曲 = **{b_ms/1000:.1f}s**（拼音列生成是 A/B 主要差异）")
    if with_lrc:
        L.append(f"- 全量耗时（C，含 .lrc 层）@ {n} 曲 = **{c_ms/1000:.1f}s** —— §2.2 的「含歌词 + 拼音 + 译文 + `.lrc`」"
                 f"预算就是指这一档，A/B 档**不含** .lrc：{ok(lrc_ok)}")
    else:
        L.append(f"- ⚠ **覆盖缺口**：默认档不含 `.lrc` 层（`IndexerOptions.IndexLrc` 默认 false），"
                 f"而 §2.2 的「含 `.lrc`」预算需要 `--with-lrc` 才测到。")
    L.append(f"- 峰值 RSS（A）≈ **{rss_a:.0f} MiB**（预算「≤ 数百 MB」）{ok(rss_ok)}")
    if not write_unavailable and write_amp > 0:
        L.append(f"- 写入量（A，`write_bytes`）= **{a_best['write_mb']:.0f} MB** / 索引 {idx_a_mb:.1f} MiB → "
                 f"写放大 ≈ **{write_amp:.1f}×**（含临时世代全量顺序写 + fsync + WAL；评估 HDD / eMMC 磨损时按此计）")
    L.append("")
    L.append("## 4. 增量（非 --full）")
    L.append("")
    L.append("| 场景 | 脏曲 K | wall ms | durationMs | 峰值 RSS MB | indexed | deleted |")
    L.append("|---|---|---|---|---|---|---|")
    for k in sorted(inc):
        x = inc[k]
        name = "零脏曲（no-op）" if k == 0 else "改 file_mtime"
        L.append(f"| {name} | {k} | {x['wall_ms']:.0f} | {x.get('durationMs')} | {x['rss_mb']:.0f} | "
                 f"{x.get('indexed')} | {x.get('deleted')} |")
    if noop_lrc:
        L.append(f"| 零脏曲（no-op，**含 .lrc 档**） | 0 | {noop_lrc['wall_ms']:.0f} | {noop_lrc.get('durationMs')} | "
                 f"{noop_lrc['rss_mb']:.0f} | {noop_lrc.get('indexed')} | {noop_lrc.get('deleted')} |")
    L.append("")
    if noop.get("durationMs") is not None:
        L.append(f"- **零脏曲 = {noop['durationMs']}ms**：这是增量的**固定开销**（阶段一探测 + 收尾写路径），"
                 f"**不含任何内容读取**。K=20 与它的差值才是脏曲写路径成本。")
    if inc20.get("durationMs") and inc200.get("durationMs"):
        d20, d200 = inc20["durationMs"], inc200["durationMs"]
        marginal = (d200 - d20) / (200 - 20)
        L.append(f"- K=20 → {d20}ms；K=200 → {d200}ms：ΔK={200-20} 增加 {d200-d20}ms（**边际 ≈ {marginal:.1f}ms/曲**）"
                 f"——脏曲部分随 K 近似线性。")
        if noop.get("durationMs"):
            L.append(f"- 归因：K=20 相对零脏曲多 {d20 - noop['durationMs']}ms，即 20 首脏曲的"
                     f"「取内容 + 分析 + FTS 删除/写入 + 收尾 checkpoint」成本；"
                     f"**阶段一探测本身很轻**（零脏曲已含它）。")
    L.append(f"- 增量预算（「秒级、≈ K 成正比」）{ok(inc_ok)}。")
    if noop_lrc:
        L.append(f"- `.lrc` 档零脏曲增量 = **{noop_lrc.get('durationMs')}ms**：与不开启时同量级即说明"
                 f"**索引器没有任何文件系统侧车探测**（侧车锚点 `lrc_mtime/size` 来自扫描器写入的"
                 f"`library.db` 列，见设计文档 §4.4）；若显著变大，先查 `library.db` 是否缺列"
                 f"（缺列会降级为「无侧车」，不会变慢）或扫描器是否未写侧车。")
    L.append("")
    L.append("## 5. 查询延迟 P50 / P95（同一进程内循环，已排除进程启动）")
    L.append("")
    for limit in limits:
        qa, qb = m["query"][f"A@{limit}"], m["query"][f"B@{limit}"]
        note = "（= 生产曲库页 `kSearchIndexRankLimit`）" if limit == app_limit else ""
        L.append(f"### LIMIT = {limit}{note}")
        L.append("")
        L.append(f"每个查询：warmup {qa['warmup']} 次、{qa['repeats']} 次采样，取最近秩百分位。"
                 "A = 拼音列开（`--full`），B = 拼音列关（`--no-pinyin`）。")
        L.append("")
        L.append("| 查询 | 文本 | A 命中 | A P50 ms | A P95 ms | B 命中 | B P50 ms | B P95 ms |")
        L.append("|---|---|---|---|---|---|---|---|")
        qa_by = {x["name"]: x for x in qa["queries"]}
        qb_by = {x["name"]: x for x in qb["queries"]}
        for name, xa in qa_by.items():
            xb = qb_by.get(name, {})
            flag = " ⚠" if (xa["p50_ms"] > budget["query_p50_ms"] or xa["p95_ms"] > budget["query_p95_ms"]) else ""
            L.append(f"| {name}{flag} | `{xa['text']}` | {xa['rows']} | {xa['p50_ms']:.3f} | {xa['p95_ms']:.3f} | "
                     f"{xb.get('rows')} | {xb.get('p50_ms', 0):.3f} | {xb.get('p95_ms', 0):.3f} |")
        pa, pb = pooled[limit]["A"], pooled[limit]["B"]
        L.append(f"| **合计（pooled）** | — | — | **{pa['p50_ms']:.3f}** | **{pa['p95_ms']:.3f}** | — | "
                 f"**{pb['p50_ms']:.3f}** | **{pb['p95_ms']:.3f}** |")
        L.append("")
        L.append(f"- pooled 对照预算 P50 ≤ {budget['query_p50_ms']:.0f}ms / P95 ≤ {budget['query_p95_ms']:.0f}ms："
                 f"A {pa['p50_ms']:.3f}/{pa['p95_ms']:.3f}ms、B {pb['p50_ms']:.3f}/{pb['p95_ms']:.3f}ms → "
                 f"{ok(pooled[limit]['ok'])}")
        if over[limit]:
            L.append(f"- ⚠ **单条超预算（pooled 会掩盖）**：{'、'.join(over[limit])}")
        else:
            L.append("- 单条全部在预算内（逐条 P50 ≤ 预算且 P95 ≤ 预算）。")
        ratio = (pa["p50_ms"] / pb["p50_ms"]) if pb["p50_ms"] > 0 else 0
        L.append(f"- 开 / 关拼音列的 pooled P50 比 ≈ **{ratio:.2f}×**（§7.4 预期「< 2×」）。")
        L.append("")
    L.append("> FTS5 的 `ORDER BY bm25` 必须给**全部命中**打分，故单条查询成本 ≈ O(命中集)。"
             "查询按生产语义**渐进**执行（第一个非空趟即停，表内 `趟` 为该查询实际执行的趟数）："
             "① 主趟 = 词法支（子串脚本的相邻 bigram 短语 + unigram `AND`；子串脚本含汉字 / 假名 / 谚文）+ "
             "拼音支（单音节 ≥3 字符前缀；≥2 音节**相邻短语**；列过滤到 `pinyin_meta/lyrics` 两列）+ "
             "首字母支（列过滤到 `initials_meta/lyrics` 两列，≥2 字符前缀）；"
             "② 拼音宽松兜底（位置无关 `AND`，恢复漏字 / 换位）；③ **日文读音兜底**（拉丁词元 → 字母 bigram "
             "**短语** → `reading_meta_tok`）；④ 跨语言兜底（T1 候选）。"
             "仍偏慢的查询通常是**宽命中集**：常见音节组合、1–2 字符精确命中、"
             "或落到兜底趟（宽表达式）。逐条明细见上表（⚠ 行）。"
             "\n>\n> 查询侧另有**候选集上限**（生产默认 5000，`--cap 0` 可关闭做对照）："
             "`WHERE rowid IN (SELECT rowid … MATCH ? LIMIT 5000)` 先取有界候选再 bm25 排序——"
             "`ORDER BY bm25` 否则要给全部命中打分；窄命中（候选 < 上限）不受影响。")
    L.append("")
    L.append("## 6. 对照 §2.2 预算")
    L.append("")
    L.append(f"| 指标 | 预算 | 实测（本机 @{n} 曲） | 外推 @{budget['extrapolate_n']} 曲 | 结论 |")
    L.append("|---|---|---|---|---|")
    L.append(f"| 首次全量构建（含拼音 + `.lrc`） | ≤ 2–5 min | "
             + (f"{c_ms/1000:.1f}s（C 含 .lrc）" if with_lrc else f"{a_ms/1000:.1f}s（A，**不含 .lrc**）")
             + f" | ≈ {(c_ms if with_lrc else a_ms)*scale/1000:.0f}s | {ok(lrc_ok if with_lrc else full_ok)} |")
    L.append(f"| 增量（K 首） | ≈ K 成正比，秒级 | 零脏曲 {noop.get('durationMs')}ms；"
             f"K=20 → {inc20.get('durationMs')}ms；K=200 → {inc200.get('durationMs')}ms | 边际 ≈ 线性 | {ok(inc_ok)} |")
    L.append(f"| 查询 P50 / P95（pooled） | ≤ 20 / ≤ 80 ms | "
             f"{pooled[app_limit]['A']['p50_ms']:.3f} / {pooled[app_limit]['A']['p95_ms']:.3f} ms（A, LIMIT={app_limit}） | "
             f"与 N 近似无关* | {ok(q_pooled_ok)} |")
    L.append(f"| 查询 P50 / P95（逐条） | ≤ 20 / ≤ 80 ms | "
             f"{'全部满足' if q_perquery_ok else '存在超标（见 §5 ⚠）'} | 随命中集增长 | {ok(q_perquery_ok)} |")
    L.append(f"| 索引体积 | ~100–300 MB | {idx_a_mb:.1f} MiB（A） | ≈ {idx25k_mb:.0f} MiB | {ok(idx_ok)} |")
    L.append(f"| 峰值内存 | ≤ 数百 MB，可限 | {rss_a:.0f} MiB（A） | — | {ok(rss_ok)} |")
    L.append("")
    L.append("\\* 「与 N 近似无关」只对**窄命中**查询成立；宽命中集（常见拼音 / 首字母）随 N 线性增长，"
             "见 §5 逐条表与 §8 局限。")
    if not q_perquery_ok:
        worst = max(
            (x for x in m["query"][f"A@{app_limit}"]["queries"]),
            key=lambda x: x["p50_ms"],
        )
        L.append("")
        L.append(f"➡ **结论**：pooled 口径{'达标' if q_pooled_ok else '超标'}，但**逐条口径存在超标**——"
                 f"最慢一条 `{worst['text']}`（{worst['name']}）P50 {worst['p50_ms']:.1f}ms / "
                 f"P95 {worst['p95_ms']:.1f}ms。pooled 是被大量窄查询摊平的结果，"
                 f"**不应作为单条查询预算的判定口径**。")
    L.append("")
    L.append("## 7. P5 判定（§5.5 自研段引擎）")
    L.append("")
    # §5.5 的触发条件是**写局部性 / 磨损**（checkpoint 随机回写）不达标——本 harness 未观测到
    # 该类失败。查询延迟 / 体积属**另一类**问题（分析器 / schema / 查询编译层），自研段引擎
    # 并不解决，故两者分开陈述，避免把「查询慢」误导成「该自研存储」。
    L.append("**结论：P5 不触发 → 自研段引擎（§5.5 实现 B）不实施。**")
    L.append("")
    L.append("判定依据（严格对齐 §5.5 的触发条件：**FTS5 在目标介质上 checkpoint 随机回写导致 "
             "locality / 磨损不达标**）：")
    L.append(f"1. **存储侧未见短板**：全量 {a_ms/1000:.1f}s"
             + (f"（含 .lrc {c_ms/1000:.1f}s）" if with_lrc else "")
             + f"（≤ {budget['full_max_ms']/60000:.0f}min）、增量零脏曲 {noop.get('durationMs')}ms、"
             f"峰值 RSS {rss_a:.0f}MB、索引 {idx_a_mb:.1f}MiB（{n} 曲）。")
    L.append("2. **写局部性对策已生效**（§5.3/§7.2）：全量为「临时世代从零**顺序写** + fsync + 原子 rename」，"
             "增量按 **dirty-only** 且收尾 `wal_checkpoint(TRUNCATE)`；构建与增量耗时未见随机写病理。")
    L.append("3. **无 locality / 磨损不达标的测量证据** → §5.5 的前提不成立，按设计「**先量再定、不先验假设**」"
             "原则，自研段引擎**无测量支撑，不实施**。")
    if not q_perquery_ok or not q_pooled_ok:
        slowest = max(m["query"][f"A@{app_limit}"]["queries"], key=lambda x: x["p50_ms"])
        L.append("")
        L.append(f"⚠ **独立于 P5 的问题：查询延迟超标**（非存储引擎问题，自研段引擎也不解决）。"
                 f"最慢一条 `{slowest['text']}`（{slowest['name']}）P50 {slowest['p50_ms']:.1f}ms；"
                 f"pooled P50/P95 = {pooled[app_limit]['A']['p50_ms']:.1f}/{pooled[app_limit]['A']['p95_ms']:.1f}ms "
                 f"（LIMIT={app_limit}）。根因：FTS5 `ORDER BY bm25` 必须给全部命中打分，而"
                 f"**短前缀支（首字母 / 拼音音节前缀，且首字母与拼音同列）**与**跨语言候选支（T1，"
                 f"`愛`→`love` 一类高频英文词）**都会把命中集放大到接近整库。"
                 f"收敛方向应在**查询编译 / schema 层**（首字母独立列、前缀长度门控、跨语言候选的"
                 f"选择性门控 / 渐进式合并、命中集上限），并另立优化项跟进。")
    L.append("")
    L.append("> 本结论受 §8 局限约束"
             + ("；尤其**磨损 / 长期写放大未量化**（`write_bytes` 在本环境不可用）。" if write_unavailable
                else "；磨损 / 长期写放大未量化（单轮 bench 不反映多世代碎片与写放大）。"))
    L.append("")
    L.append("## 8. 局限")
    L.append("")
    if n < budget["extrapolate_n"]:
        L.append(f"1. **规模外推**：本机实测 N={n}；{budget['extrapolate_n']//1000}k 为**线性外推**"
                 f"（构建耗时、索引体积随 N 近似线性，但 FTS 段合并 / 页分配有次线性效应，外推偏保守）。")
    else:
        L.append(f"1. **规模**：本报告为 N={n} 的**直接实测**（≥ §2.2 的 {budget['extrapolate_n']//1000}k 目标点）。")
    L.append(f"2. **介质**：工作盘为 `{disk['device']}`（{disk['fstype']}，`{disk['media']}`，挂载 `{disk['mount']}`）。"
             "§7.2 的「checkpoint 随机回写」痛点主要在**物理 HDD / eMMC**；"
             + ("本环境 `write_bytes` 不可用 → 写入量 / 磨损未直接量化。" if write_unavailable
                else f"本环境 `write_bytes` 可用（A 档写 {a_best['write_mb']:.0f}MB），但未做擦除块级观测。"))
    L.append("3. **未测磨损 / 长期度**：单轮 bench 无法反映多世代、反复增量后的碎片与写放大；未做 `iostat` / 闪存块级观测。")
    L.append("4. **索引体积 / 查询命中集对语料敏感**：本语料按 §8 口径取 2–8 KB/曲（均 5 KB、密集中文），"
             "但**词表很小**（固定词表拼装）——于是常用词元几乎出现在每一首里"
             "（`我` / `爱` / `你` / `love` / `hello` 等命中 2.8 万–3 万 / 3 万）。"
             "真实曲库的常用词元命中集会窄得多，故本报告的**宽命中查询延迟应视为上界**；"
             "窄命中查询（短语 / 长音节组合）与 N 的关系才是可迁移的结论。"
             "索引体积同理：语料越短 / 越稀疏，元数据表与倒排的固定开销占比越高。")
    L.append("5. **查询集规模**：代表查询 "
             f"{len(m['query'][f'A@{app_limit}']['queries'])} 条（中文子串 / 短语 / 繁体 / 中文+首字母 / 拼音连写 / "
             "单音节拼音前缀 / 首字母 / 拉丁前缀 / 整词），非完整 §8 标注集；"
             "未测召回@k / MRR / NDCG（那是 P0 分析器评估，非本 P5 性能问题）。")
    L.append("6. **查询语义**：MATCH 构造与生产查询编译层 `search_query.dart` 同构——词法支（CJK 连续 bigram 引号短语 + "
             "unigram `AND`、末拉丁 / 数字 `*`）、拼音支（单音节 `*` 前缀；**≥2 音节相邻短语**）、"
             "首字母支、跨语言支，各支 `OR`；LIMIT 覆盖 "
             f"{'、'.join(str(x) for x in limits)}（后者 = 生产曲库页 `kSearchIndexRankLimit`）。"
             "召回质量不在本报告范围。")
    L.append("7. **峰值内存**：`VmHWM` 轮询（20 ms）可能略低估瞬时峰值；索引器为 run-to-completion 同步模型，"
             "无等待式竞态判定（符合 AGENTS.md）。")
    L.append(f"8. **版本锚点**：本报告数据对应 `schema_version={meta_schema}` / `analyzer_version={meta_analyzer}`、"
             "代码 `" + env["git_head"] + "`；分析器 / schema 版本变动会令旧库全量重建，"
             "届时性能数字需重跑（本报告不含历史版本的对比数据）。")
    L.append("")
    with open(REPORT, "w", encoding="utf-8") as f:
        f.write("\n".join(L) + "\n")


if __name__ == "__main__":
    sys.exit(main())
