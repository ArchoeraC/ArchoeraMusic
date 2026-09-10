#!/usr/bin/env python3
# ArchoeraMusic 统一能力检测入口（合并旧基准脚本）
#
# 用法：
#   python3 run_suite.py [--build] [--reps N] [--skip SCORECARD,POOL,SCANNER]
#
# 覆盖：
#   A. 内核单测（zig build test；含逐格式解码 e2e / 元数据 ABI 等）
#   B. 引擎 ctest（C 壳 / 池 seam / 内存 / seek / 限幅 / 等响 等）
#   C. 逐格式解码 scorecard（era vs FFmpeg=100，15 格式）
#   D. 内核池并发压力（bench_era_pool，1→128）
#   E. scanner 元数据吞吐（内核 probe-only vs TagLib）
#
# 产物：docs/test-suite-<date>.md（汇总报告）+ /tmp/opencode/suite_*.csv（原始数据）
import argparse, os, re, resource, subprocess, sys, time, threading, shutil, sqlite3

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", "..", "..", ".."))  # repo root
ENG = os.path.join(ROOT, "app", "core", "audio-engine")
SCANNER = os.path.join(ROOT, "app", "core", "scanner")
DATE = time.strftime("%Y-%m-%d")
OUT_MD = os.path.join(ROOT, "docs", f"test-suite-{DATE}.md")
TMP = "/tmp/opencode"


def sh(cmd, cwd=None, env=None, timeout=3600):
    t = time.monotonic()
    e = dict(os.environ)
    e.setdefault("LC_ALL", "C")
    if env: e.update(env)
    p = subprocess.run(cmd, cwd=cwd, env=e, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, timeout=timeout)
    return p.returncode, p.stdout.decode(errors="replace"), time.monotonic() - t


def child_cpu():
    r = resource.getrusage(resource.RUSAGE_CHILDREN)
    return r.ru_utime + r.ru_stime


def peak_rss(pid):
    try:
        with open(f"/proc/{pid}/status") as f:
            for l in f:
                if l.startswith("VmHWM:"):
                    return int(l.split()[1]) / 1024.0
    except Exception:
        pass
    return 0.0


def run_poll(argv, env=None, pin="0-15"):
    if pin and shutil.which("taskset"):
        argv = ["taskset", "-c", pin] + list(argv)
    peak = [0.0]; stop = threading.Event()
    t = time.monotonic()
    p = subprocess.Popen(argv, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    def poll():
        while not stop.is_set():
            r = peak_rss(p.pid)
            if r > peak[0]: peak[0] = r
            time.sleep(0.002)
    th = threading.Thread(target=poll, daemon=True); th.start()
    out, _ = p.communicate()
    stop.set(); th.join(timeout=0.2)
    return p.returncode, out.decode(errors="replace"), (time.monotonic() - t) * 1000, peak[0]


# ---- A. 内核单测 ----
def sec_kernel():
    rc, out, dt = sh(["zig", "build", "test", "--summary", "all"], cwd=ENG, timeout=3600)
    m = re.search(r"(\d+)/(\d+) tests passed", out) or re.search(r"(\d+) pass \(", out)
    passed = m.group(1) if m else "?"
    return {"rc": rc, "passed": passed, "sec": dt, "log": out[-2000:]}


# ---- B. ctest ----
def sec_ctest():
    rc, out, dt = sh(["ctest", "--test-dir", "build", "--output-on-failure"], cwd=ENG)
    m = re.search(r"(\d+)% tests passed out of (\d+)", out)
    total = m.group(2) if m else "?"
    pct = int(m.group(1)) if m else 0
    failed = "?" if not m else str(int(total) - round(pct * int(total) / 100))
    names = re.findall(r"Test\s+#\d+:\s+(\S+)", out)
    return {"rc": rc, "total": total, "failed": failed, "names": names, "sec": dt, "log": out[-2000:]}


# ---- C. 逐格式 scorecard ----
def sec_scorecard(reps):
    csv = f"{TMP}/suite_score.csv"; md = f"{TMP}/suite_score.md"
    corpus = f"{TMP}/sc"
    cmd = ["python3", os.path.join(HERE, "scorecard.py"), "--corpus", corpus,
           "--engine", os.path.join(ENG, "build", "archoera-audio-engine"),
           "--csv", csv, "--md", md, "--reps", str(reps), "--pin", "0-15",
           "--build-tag", f"suite-{DATE}"]
    rc, out, dt = sh(cmd, timeout=3600)
    rows = []
    if os.path.isfile(csv):
        import csv as _csv
        with open(csv) as f:
            for r in _csv.DictReader(f):
                if r.get("engine") in ("era", "stable", "ffmpeg"):
                    rows.append(r)
    avg = {}
    for eng in ("era", "stable", "ffmpeg"):
        vals = [float(r["total"]) for r in rows if r["engine"] == eng and r.get("total")]
        if vals:
            avg[eng] = round(sum(vals) / len(vals), 1)
    return {"rc": rc, "rows": rows, "sec": dt, "csv": csv, "avg": avg, "log": out[-1500:]}


# ---- D. 池并发压力 ----
def sec_pool():
    sh(["cmake", "--build", "build", "--target", "bench_era_pool"], cwd=ENG)
    bench = os.path.join(ENG, "build", "tests", "bench_era_pool")
    corpus = f"{TMP}/corpus"
    files = ["a.flac", "a.m4a", "a.mp3"]
    avail = [f for f in files if os.path.isfile(os.path.join(corpus, f))]
    if not os.path.isfile(bench) or not avail:
        return {"rc": 2, "rows": [], "log": "bench/corpus 缺失"}
    rows = []
    for n in [1, 2, 4, 8, 16, 32, 64, 128]:
        paths = [os.path.join(corpus, avail[i % len(avail)]) for i in range(n)]
        c0 = child_cpu()
        rc, out, wall, rss = run_poll([bench, "-streams", str(n), str(n)] + paths)
        cpu = child_cpu() - c0
        m = re.search(r"files_ok=(\d+)/(\d+) total_frames=(\d+) wall_ms=(\d+)", out)
        rows.append({"n": n, "wall": wall, "rss": rss, "cpu": cpu, "rc": rc, "cap": n,
                     "ok": f"{m.group(1)}/{m.group(2)}" if m else "?",
                     "frames": m.group(3) if m else "?"})
    # 对照：默认流上限 8（N=128 时大量 open 失败）
    cap8 = None
    if os.path.isfile(bench) and avail:
        paths = [os.path.join(corpus, avail[i % len(avail)]) for i in range(128)]
        rc, out, wall, rss = run_poll([bench, "-streams", "8", "128"] + paths)
        m = re.search(r"files_ok=(\d+)/(\d+)", out)
        cap8 = f"{m.group(1)}/{m.group(2)}" if m else "?"
    return {"rc": 0, "rows": rows, "cap8": cap8}


# ---- E. scanner 元数据 ----
def sec_scanner():
    dll = os.path.join(SCANNER, "bin", "Debug", "net10.0", "archoera-scanner.dll")
    kso = os.path.join(SCANNER, "bin", "Debug", "net10.0", "libarchoera_kernel.so")
    corpus = f"{TMP}/scan_corpus"
    if not os.path.isdir(corpus):
        return {"rc": 2, "rows": [], "log": "scan_corpus 缺失"}
    if not os.path.isfile(dll):
        sh(["dotnet", "build", os.path.join(SCANNER, "scanner.csproj"), "-v", "quiet", "-nologo"],
           cwd=SCANNER, timeout=1800)
    if not os.path.isfile(dll):
        return {"rc": 2, "rows": [], "log": "scanner 构建失败"}
    def tracks(db):
        try:
            c = sqlite3.connect(db)
            n = c.execute("select count(*) from tracks").fetchone()[0]
            sample = c.execute("select title,codec,duration,sample_rate,channels "
                               "from tracks order by path limit 50").fetchall()
            c.close()
            return n, sample
        except Exception:
            return -1, []

    rows = []
    for par in [1, 8, 32, 128]:
        for name, use_k in (("kernel", True), ("taglib", False)):
            if not use_k and os.path.exists(kso):
                shutil.move(kso, f"{TMP}/kh.suite")
            db = f"{TMP}/suite_scan_{name}_{par}.db"
            for suf in ("", "-wal", "-shm"):
                try: os.remove(db + suf)
                except OSError: pass
            env = dict(os.environ, ARCHOERA_DB_PATH=db,
                       ARCHOERA_DATA_DIR=f"{TMP}/suite_sd_{name}_{par}",
                       SCANNER_MAX_PARALLELISM=str(par))
            c0 = child_cpu()
            rc, out, wall, rss = run_poll(["dotnet", dll, "scan", "--dirs", corpus, "--full"], env=env)
            cpu = child_cpu() - c0
            if not use_k and os.path.exists(f"{TMP}/kh.suite"):
                shutil.move(f"{TMP}/kh.suite", kso)
            n, sample = tracks(db)
            rows.append({"par": par, "engine": name, "wall": wall, "rss": rss,
                         "cpu": cpu, "rc": rc, "tracks": n, "sample": sample})
    # 正确性对拍（par=8）：内核 vs TagLib 行数与字段一致
    cmp = {}
    for name in ("kernel", "taglib"):
        r = next((x for x in rows if x["par"] == 8 and x["engine"] == name), None)
        if r: cmp[name] = (r["tracks"], r["sample"])
    mism = None
    if cmp.get("kernel") and cmp.get("taglib"):
        mism = 0 if cmp["kernel"] == cmp["taglib"] else 1
    return {"rc": 0, "rows": rows, "cmp_mismatch": mism,
            "cmp_tracks": {k: v[0] for k, v in cmp.items()}}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--build", action="store_true")
    ap.add_argument("--reps", type=int, default=5, help="scorecard 每项采样次数（去极值）")
    ap.add_argument("--skip", default="")
    a = ap.parse_args()
    skip = set(x.strip().upper() for x in a.skip.split(",") if x.strip())
    os.makedirs(TMP, exist_ok=True)

    if a.build:
        sh(["zig", "build", "-Doptimize=ReleaseFast", "--prefix", "./zig-out"], cwd=ENG)
        sh(["cmake", "--build", "build"], cwd=ENG)

    res = {}
    if "KERNEL" not in skip: res["kernel"] = sec_kernel()
    if "CTEST" not in skip: res["ctest"] = sec_ctest()
    if "SCORECARD" not in skip: res["score"] = sec_scorecard(a.reps)
    if "POOL" not in skip: res["pool"] = sec_pool()
    if "SCANNER" not in skip: res["scan"] = sec_scanner()

    A = [f"# ArchoeraMusic 统一能力检测（{DATE}）", "",
         "> `run_suite.py` 合并旧基准脚本：内核单测 + 引擎 ctest + 逐格式 scorecard + "
         "池并发压力 + scanner 吞吐。数据可复现，跨机比相对值。", ""]
    if "kernel" in res:
        k = res["kernel"]
        A += [f"## A. 内核单测（zig build test）", "",
              f"- 结果：**{k['passed']} passed**（rc={k['rc']}，{k['sec']:.1f}s）", ""]
    if "ctest" in res:
        c = res["ctest"]
        A += [f"## B. 引擎 ctest", "",
              f"- 结果：**{c['total']} 项，失败 {c['failed']}**（rc={c['rc']}，{c['sec']:.1f}s）",
              f"- 用例：{', '.join(c['names'])}", ""]
    if "score" in res and res["score"].get("rows"):
        A += ["## C. 逐格式解码 scorecard（FFmpeg=100）", "",
              "| 格式 | era wall(s) | era CPU(s) | era RSS(MB) | stable wall(s) | stable CPU(s) | stable RSS(MB) | wall era/stable | era 得分 |",
              "|---|---|---|---|---|---|---|---|---|"]
        def cpu(r):
            try:
                return round(float(r.get("user_s", 0)) + float(r.get("sys_s", 0)), 3)
            except Exception:
                return "—"
        by = {}
        for r in res["score"]["rows"]:
            by.setdefault(r["format"], {})[r["engine"]] = r
        for fmt, d in by.items():
            e = d.get("era"); st = d.get("stable")
            if not e: continue
            ratio = "—"
            st_wall = st_cpu = st_rss = "—"
            if st:
                st_wall = st["wall_s"]; st_cpu = cpu(st)
                st_rss = f"{float(st['rss_kb'])/1024:.1f}"
                try:
                    ratio = f"{float(e['wall_s'])/float(st['wall_s']):.2f}"
                except Exception:
                    pass
            A.append(f"| {fmt} | {e['wall_s']} | {cpu(e)} | {float(e['rss_kb'])/1024:.1f} | "
                     f"{st_wall} | {st_cpu} | {st_rss} | {ratio} | {e['total']} |")
        A.append("")
        av = res["score"].get("avg", {})
        A.append(f"- 总体均分：**era {av.get('era','?')} vs stable {av.get('stable','?')} "
                 f"vs ffmpeg {av.get('ffmpeg','?')}**（FFmpeg 归一=100）")
        A.append("- 公平性：speed=40·min(1,R/50) 在本语料饱和（≥50×RT），总分差异实际来自 "
                 "memory/correctness；无损要求 era==stable==ffmpeg 逐位；每项 "
                 f"reps={a.reps} 去极值，核心 pin P 核（taskset 0-15）。")
        A.append("")
    if "pool" in res and res["pool"].get("rows"):
        A += ["## D. 内核池并发压力（bench_era_pool，流上限=并发）", "",
              "| N | 进程墙钟 ms | CPU(s) | 峰值 RSS MB | files_ok | 合计帧 |", "|---|---|---|---|---|---|"]
        for r in res["pool"]["rows"]:
            A.append(f"| {r['n']} | {r['wall']:.0f} | {r.get('cpu',0):.3f} | {r['rss']:.1f} | {r['ok']} | {r['frames']} |")
        A.append("")
        A.append(f"- 流上限=并发（`zk_engine_init_streams(...,N)`）；**对照默认流上限 8、N=128："
                 f"{res['pool'].get('cap8','?')}**（证明默认会限制并发）。")
        A.append("- 本节为 era 单侧能力/内存口径，**无 FFmpeg 基线**；核心 pin P 核（0-15）降噪。")
        A.append("")
    if "scan" in res and res["scan"].get("rows"):
        A += ["## E. scanner 元数据吞吐（1000 小文件）", "",
              "| 并行度 | 引擎 | wall ms | CPU(s) | 峰值 RSS MB | rc | tracks |", "|---|---|---|---|---|---|---|"]
        for r in res["scan"]["rows"]:
            A.append(f"| {r['par']} | {r['engine']} | {r['wall']:.0f} | {r.get('cpu',0):.3f} | "
                     f"{r['rss']:.1f} | {r['rc']} | {r.get('tracks','?')} |")
        A.append("")
        ct = res["scan"].get("cmp_tracks", {})
        mm = res["scan"].get("cmp_mismatch")
        A.append(f"- 正确性对拍（par=8）：tracks kernel={ct.get('kernel','?')} / "
                 f"taglib={ct.get('taglib','?')}；字段一致性：{'一致' if mm == 0 else ('不一致' if mm == 1 else '未测')}。")
        A.append("")
    A += ["## 说明", "",
          "- 逐格式 scorecard 语料为可复现音乐结构仿真；内核单测含逐格式解码 e2e（无损逐位/有损 corr 门）。",
          "- 池压力用 `zk_engine_init_streams(...,N)` 放开流上限（默认 8 会限制并发）。", ""]

    os.makedirs(os.path.dirname(OUT_MD), exist_ok=True)
    with open(OUT_MD, "w") as f:
        f.write("\n".join(A))
    print(f"written {OUT_MD}")
    for k, v in res.items():
        print(f"  {k}: rc={v.get('rc')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
